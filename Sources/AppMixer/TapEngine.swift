import CoreAudio
import Foundation

/// Core engine: per-app process taps -> tap-only aggregates -> rings -> output mixer.
/// - One CATapMutedWhenTapped tap per audible app silences its direct path while we read it.
///   If we quit/crash/stall, macOS un-mutes the app so audio keeps playing (crash-safe).
/// - Each tap lives in its own private tap-only aggregate (no output subdevice).
/// - A single output IOProc on the real default output device mixes rings additively:
///   outputData (system mix of untapped apps) is preserved, tapped audio is added back
///   with per-app gain. Non-tapped apps flow through unchanged.
final class TapEngine {
    static let shared = TapEngine()

    private let queue = DispatchQueue(label: "com.karthikvavilala.appmixer.engine")
    private var slots: [pid_t: TapSlot] = [:]
    private var outputDevice: AudioObjectID = kAudioObjectUnknown
    private var outputIOProc: AudioDeviceIOProcID?
    private var outputRunning = false

    var onError: ((String) -> Void)?
    var onPermissionNeeded: (() -> Void)?

    private var userGains: [String: Float] = [:]
    private var userMutes: [String: Bool] = [:]
    private var masterGain: Float = 1.0
    private var masterMuted: Bool = false
    private var duckAmount: Float = 0.5
    private var duckEnabled: Bool = true
    private var currentBundleByPID: [pid_t: String?] = [:]

    private var snapshot: [TapSlot] = []
    private let snapshotLock = NSLock()

    private let commBundleHints = [
        "us.zoom", "zoom", "microsoft.teams", "teams",
        "slack", "discord", "webex",
        "facetime", "skype", "meet.google", "chime"
    ]

    private init() {
        loadPersisted()
        queue.async { [weak self] in
            self?.refreshOutputDevice()
            self?.installDeviceChangeListener()
        }
    }

    // MARK: - persistence

    private func keyFor(bundleID: String?, pid: pid_t) -> String {
        if let b = bundleID { return "bid:\(b)" }
        return "pid:\(pid)"
    }

    private func loadPersisted() {
        let d = UserDefaults.standard
        userGains = ((d.dictionary(forKey: "appmixer.gains") as? [String: Double])?.mapValues { Float(min(max($0, 0), 1.0)) } ?? [:])
        userMutes = (d.dictionary(forKey: "appmixer.mutes") as? [String: Bool]) ?? [:]
        masterGain = d.object(forKey: "appmixer.master") as? Float ?? 1.0
        duckAmount = d.object(forKey: "appmixer.duck") as? Float ?? 0.5
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(userGains.mapValues { Double($0) }, forKey: "appmixer.gains")
        d.set(userMutes, forKey: "appmixer.mutes")
        d.set(masterGain, forKey: "appmixer.master")
        d.set(duckAmount, forKey: "appmixer.duck")
    }

    // MARK: - public state API

    func userGain(bundleID: String?, pid: pid_t) -> Float {
        let k = keyFor(bundleID: bundleID, pid: pid)
        return queue.sync { userGains[k] ?? 1.0 }
    }

    func isMuted(bundleID: String?, pid: pid_t) -> Bool {
        let k = keyFor(bundleID: bundleID, pid: pid)
        return queue.sync { userMutes[k] ?? false }
    }

    func setUserGain(bundleID: String?, pid: pid_t, value: Float) {
        let k = keyFor(bundleID: bundleID, pid: pid)
        queue.async { [weak self] in
            guard let self else { return }
            self.userGains[k] = max(0, min(1.0, value))
            self.save()
            self.applyEffectiveGains()
            self.mirrorAppleScript(bundleID: bundleID, gain: value)
        }
    }

    func setUserMuted(bundleID: String?, pid: pid_t, muted: Bool) {
        let k = keyFor(bundleID: bundleID, pid: pid)
        queue.async { [weak self] in
            guard let self else { return }
            self.userMutes[k] = muted
            self.save()
            self.applyEffectiveGains()
        }
    }

    func getMaster() -> (gain: Float, muted: Bool) {
        queue.sync { (masterGain, masterMuted) }
    }

    func setMaster(gain: Float, muted: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.masterGain = max(0, min(1.0, gain))
            self.masterMuted = muted
            self.save()
            self.applyEffectiveGains()
        }
    }

    func getDuck() -> (enabled: Bool, amount: Float) {
        queue.sync { (duckEnabled, duckAmount) }
    }

    func setDuck(enabled: Bool, amount: Float) {
        queue.async { [weak self] in
            guard let self else { return }
            self.duckEnabled = enabled
            self.duckAmount = max(0, min(0.9, amount))
            self.save()
            self.applyEffectiveGains()
        }
    }

    func peak(for pid: pid_t) -> Float {
        queue.sync { slots[pid]?.readPeak() ?? 0 }
    }

    func noteMutated() {
        queue.async { [weak self] in self?.publishSnapshot() }
    }

    // MARK: - app set management

    func setAudibleApps(_ apps: [AudibleApp]) {
        queue.async { [weak self] in
            guard let self else { return }
            let newPIDs = Set(apps.map { $0.pid })
            self.currentBundleByPID = Dictionary(uniqueKeysWithValues: apps.map { ($0.pid, $0.bundleID) })

            let toRemove = Set(self.slots.keys).subtracting(newPIDs)
            for pid in toRemove { self.destroySlot(pid: pid) }

            for app in apps where self.slots[app.pid] == nil {
                self.createSlot(app: app)
            }
            self.applyEffectiveGains()
            self.publishSnapshot()
            self.ensureOutputRunning()
        }
    }

    // MARK: - effective gains + ducking

    private func isCommBundle(_ bid: String) -> Bool {
        let lower = bid.lowercased()
        return commBundleHints.contains { lower.contains($0) }
    }

    private func commActive() -> Bool {
        guard duckEnabled else { return false }
        for case let (_, bid?) in currentBundleByPID where isCommBundle(bid) {
            return true
        }
        return false
    }

    private func applyEffectiveGains() {
        let ducking = commActive()
        for (pid, slot) in slots {
            let realBundle: String? = currentBundleByPID[pid] ?? nil
            let lookupKey = keyFor(bundleID: realBundle, pid: pid)
            let user = userGains[lookupKey] ?? 1.0
            let muted = userMutes[lookupKey] ?? false
            var eff = user * masterGain
            if masterMuted { eff = 0 }
            if ducking, let rb = realBundle, !isCommBundle(rb) {
                eff *= (1.0 - duckAmount)
            }
            slot.setGain(eff)
            slot.setMuted(muted)
        }
    }

    // MARK: - tap + aggregate lifecycle

    private func createSlot(app: AudibleApp) {
        guard #available(macOS 14.2, *) else {
            DispatchQueue.main.async { [weak self] in self?.onError?("Per-app taps require macOS 14.2+.") }
            return
        }
        guard let processObject = translatePIDToProcessObject(app.pid) else { return }
        let desc = CATapDescription(stereoMixdownOfProcesses: [processObject])
        desc.name = "AppMixer: \(app.name)"
        desc.isPrivate = true
        desc.isExclusive = false
        desc.isMixdown = true
        desc.isMono = false
        desc.muteBehavior = .mutedWhenTapped

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let st = AudioHardwareCreateProcessTap(desc, &tapID)
        if st != noErr {
            if st == Int32(kAudioHardwareIllegalOperationError) || st == Int32(kAudioHardwareBadObjectError) {
                DispatchQueue.main.async { [weak self] in self?.onPermissionNeeded?() }
            } else {
                let msg = "Tap failed for \(app.name) (\(st))"
                DispatchQueue.main.async { [weak self] in self?.onError?(msg) }
            }
            return
        }
        guard let uid = tapUID(tapID) else {
            if #available(macOS 14.2, *) {
                AudioHardwareDestroyProcessTap(tapID)
            }
            return
        }
        let slot = TapSlot(pid: app.pid, bundleID: app.bundleID, processObjectID: processObject)
        slot.tapID = tapID
        slot.tapUID = uid
        slots[app.pid] = slot

        do {
            try createAggregateAndStartTap(slot: slot)
        } catch {
            destroySlot(pid: app.pid)
            DispatchQueue.main.async { [weak self] in self?.onError?("Audio setup failed for \(app.name)") }
        }
    }

    private func createAggregateAndStartTap(slot: TapSlot) throws {
        let aggUID = "com.karthikvavilala.appmixer.tap.\(slot.pid).\(UUID().uuidString)"
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AppMixer Tap \(slot.pid)",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: slot.tapUID,
                 kAudioSubTapDriftCompensationKey: true]
            ]
        ]
        var aggID = AudioObjectID(kAudioObjectUnknown)
        var st = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggID)
        try check(st, "create aggregate")
        slot.aggregateID = aggID

        for _ in 0..<50 {
            if aggregateIsAlive(aggID) { break }
            usleep(20_000)
        }

        var proc: AudioDeviceIOProcID?
        st = AudioDeviceCreateIOProcIDWithBlock(&proc, aggID, nil) { [weak slot] _, inData, _, _, _ in
            guard let slot else { return }
            let (gain, muted) = slot.loadGain()
            let effGain: Float = muted ? 0 : gain
            // Read input taps via buffer-list pointer (no allocation on realtime thread).
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            var peak: Float = 0
            if abl.count >= 2 {
                let b0 = abl[0], b1 = abl[1]
                let frames = Int(b0.mDataByteSize) / MemoryLayout<Float>.size
                if let d0 = b0.mData?.assumingMemoryBound(to: Float.self),
                   let d1 = b1.mData?.assumingMemoryBound(to: Float.self), frames > 0 {
                    for i in stride(from: 0, to: frames, by: 4) {
                        let a = abs(d0[i]); if a > peak { peak = a }
                        let b = abs(d1[i]); if b > peak { peak = b }
                    }
                    if effGain != 0 {
                        slot.ring.push(leftIn: d0, rightIn: d1, frames: frames, stride: 1)
                    }
                }
            } else if abl.count == 1 {
                let b0 = abl[0]
                guard let d = b0.mData else { slot.updatePeak(0); return }
                let channels = max(Int(b0.mNumberChannels), 1)
                let frames = Int(b0.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                guard frames > 0 else { return }
                let fp = d.assumingMemoryBound(to: Float.self)
                for i in stride(from: 0, to: frames, by: 4) {
                    let a = abs(fp[i * channels])
                    if a > peak { peak = a }
                }
                if effGain != 0 {
                    slot.ring.pushInterleaved(fp, frames: frames, channels: channels)
                }
            }
            slot.updatePeak(peak)
        }
        try check(st, "create tap IOProc")
        guard let proc else { throw CAError.status(-1, "nil tap IOProc") }
        slot.ioProc = proc
        st = AudioDeviceStart(aggID, proc)
        try check(st, "start tap IO")
    }

    private func aggregateIsAlive(_ id: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let st = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &alive)
        return st == noErr && alive != 0
    }

    private func destroySlot(pid: pid_t) {
        guard let slot = slots.removeValue(forKey: pid) else { return }
        if let proc = slot.ioProc, slot.aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(slot.aggregateID, proc)
            AudioDeviceDestroyIOProcID(slot.aggregateID, proc)
        }
        if slot.aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(slot.aggregateID)
        }
        if slot.tapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) {
                AudioHardwareDestroyProcessTap(slot.tapID)
            }
        }
    }

    // MARK: - output mixer

    private func refreshOutputDevice() {
        do {
            outputDevice = try defaultOutputDevice()
        } catch {
            outputDevice = kAudioObjectUnknown
        }
    }

    private func installDeviceChangeListener() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(systemObject(), &addr, queue) { [weak self] _, _ in
            guard let self else { return }
            self.restartOutput()
        }
    }

    private func outputSnapshot() -> [TapSlot] {
        snapshotLock.lock()
        let s = snapshot
        snapshotLock.unlock()
        if s.count == slots.count { return s }
        return Array(slots.values)
    }

    private func publishSnapshot() {
        snapshotLock.lock()
        snapshot = Array(slots.values)
        snapshotLock.unlock()
    }

    private func ensureOutputRunning() {
        if outputRunning { return }
        refreshOutputDevice()
        guard outputDevice != kAudioObjectUnknown else { return }
        var proc: AudioDeviceIOProcID?
        let st = AudioDeviceCreateIOProcIDWithBlock(&proc, outputDevice, nil) { [weak self] _, _, _, outData, _ in
            guard let self else { return }
            let snap = self.outputSnapshot()
            if snap.isEmpty { return }
            let outABL = UnsafeMutableAudioBufferListPointer(outData)
            if outABL.count >= 2 {
                let b0 = outABL[0], b1 = outABL[1]
                guard let d0 = b0.mData?.assumingMemoryBound(to: Float.self),
                      let d1 = b1.mData?.assumingMemoryBound(to: Float.self) else { return }
                let frames = Int(b0.mDataByteSize) / MemoryLayout<Float>.size
                guard frames > 0 else { return }
                for slot in snap {
                    let (g, m) = slot.loadGain()
                    let gain: Float = m ? 0 : g
                    if gain == 0 { continue }
                    _ = slot.ring.popAndMix(outLeft: d0, outRight: d1, frames: frames, gain: gain)
                }
                _ = b1
            } else if outABL.count == 1 {
                // Interleaved output: pop per-slot in chunks to avoid heap allocation.
                // Uses small stack scratch via static thread-local? v1 uses chunked heap arrays
                // only on underrun-free paths; acceptable but noted for future lock-free work.
                let b0 = outABL[0]
                guard let d = b0.mData?.assumingMemoryBound(to: Float.self) else { return }
                let channels = max(Int(b0.mNumberChannels), 1)
                let frames = Int(b0.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                guard frames > 0 else { return }
                for slot in snap {
                    let (g, m) = slot.loadGain()
                    let gain: Float = m ? 0 : g
                    if gain == 0 { continue }
                    var tmpL = [Float](repeating: 0, count: 512)
                    var tmpR = [Float](repeating: 0, count: 512)
                    var remaining = frames
                    var offset = 0
                    while remaining > 0 {
                        let chunk = min(remaining, 512)
                        tmpL.withUnsafeMutableBufferPointer { bl in
                            tmpR.withUnsafeMutableBufferPointer { br in
                                for i in 0..<chunk { bl[i] = 0; br[i] = 0 }
                                _ = slot.ring.popAndMix(outLeft: bl.baseAddress!, outRight: br.baseAddress!, frames: chunk, gain: 1.0)
                                for i in 0..<chunk {
                                    d[(offset + i) * channels] += bl[i] * gain
                                    if channels > 1 {
                                        d[(offset + i) * channels + 1] += br[i] * gain
                                    }
                                }
                            }
                        }
                        offset += chunk
                        remaining -= chunk
                    }
                }
            }
        }
        guard st == noErr, let proc else { return }
        let startSt = AudioDeviceStart(outputDevice, proc)
        guard startSt == noErr else {
            AudioDeviceDestroyIOProcID(outputDevice, proc)
            return
        }
        outputIOProc = proc
        outputRunning = true
    }

    private func restartOutput() {
        if let proc = outputIOProc, outputDevice != kAudioObjectUnknown {
            AudioDeviceStop(outputDevice, proc)
            AudioDeviceDestroyIOProcID(outputDevice, proc)
        }
        outputIOProc = nil
        outputRunning = false
        publishSnapshot()
        ensureOutputRunning()
    }

    // MARK: - output device picker

    func outputDevices() -> [(id: AudioObjectID, name: String, isDefault: Bool)] {
        let ids = allOutputDevices()
        let def = (try? defaultOutputDevice()) ?? kAudioObjectUnknown
        return ids.map { ($0, deviceName($0), $0 == def) }
    }

    func setDefaultOutput(_ id: AudioObjectID) {
        queue.async { [weak self] in
            guard let self else { return }
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var dev = id
            let st = AudioObjectSetPropertyData(systemObject(), &addr, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &dev)
            if st != noErr {
                DispatchQueue.main.async { [weak self] in self?.onError?("Could not switch output (\(st))") }
            }
            self.restartOutput()
        }
    }

    // MARK: - AppleScript mirror (best effort)

    private func mirrorAppleScript(bundleID: String?, gain: Float) {
        guard let bid = bundleID?.lowercased() else { return }
        let pct = Int((min(max(gain, 0), 1.0)) * 100)
        let script: String?
        if bid.contains("com.apple.music") {
            script = "tell application \"Music\" to set sound volume to \(pct)"
        } else if bid.contains("spotify") {
            script = "tell application \"Spotify\" to set sound volume to \(pct)"
        } else {
            script = nil
        }
        guard let s = script else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", s]
        try? proc.run()
    }
}
