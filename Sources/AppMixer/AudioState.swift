import AppKit
import Combine
import Foundation

struct AppRowModel: Identifiable {
    let id: pid_t
    let pid: pid_t
    let bundleID: String?
    let name: String
    let icon: NSImage?
    var volume: Float      // 0...1.5
    var muted: Bool
    var level: Float       // 0...1 meter
    var isComm: Bool
}

/// Bridges ProcessDetector + TapEngine to SwiftUI.
@MainActor
final class AudioState: ObservableObject {
    @Published var apps: [AppRowModel] = []
    @Published var masterVolume: Float = 1.0
    @Published var masterMuted: Bool = false
    @Published var duckEnabled: Bool = true
    @Published var duckAmount: Float = 0.5
    @Published var outputs: [(id: UInt32, name: String, isDefault: Bool)] = []
    @Published var errorMessage: String?
    @Published var needsPermission: Bool = false
    @Published var engineActive: Bool = false

    private let detector = ProcessDetector()
    private let engine = TapEngine.shared
    private var meterTimer: Timer?
    private var lastAudible: [AudibleApp] = []

    init() {
        let (mg, mm) = engine.getMaster()
        masterVolume = mg
        masterMuted = mm
        let (de, da) = engine.getDuck()
        duckEnabled = de
        duckAmount = da

        engine.onError = { [weak self] msg in
            Task { @MainActor in self?.errorMessage = msg }
        }
        engine.onPermissionNeeded = { [weak self] in
            Task { @MainActor in self?.needsPermission = true }
        }
        detector.onChange = { [weak self] apps in
            Task { @MainActor in self?.handleAudible(apps) }
        }
    }

    func start() {
        detector.start()
        refreshOutputs()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshMeters() }
        }
        engineActive = true
    }

    func stop() {
        detector.stop()
        meterTimer?.invalidate()
    }

    private func handleAudible(_ audible: [AudibleApp]) {
        lastAudible = audible
        engine.setAudibleApps(audible)
        engine.noteMutated()
        // Preserve existing slider values; add new apps with persisted values.
        var byPid: [pid_t: AppRowModel] = Dictionary(uniqueKeysWithValues: apps.map { ($0.pid, $0) })
        var next: [AppRowModel] = []
        for a in audible {
            if let existing = byPid[a.pid] {
                next.append(existing)
            } else {
                let vol = engine.userGain(bundleID: a.bundleID, pid: a.pid)
                let mute = engine.isMuted(bundleID: a.bundleID, pid: a.pid)
                next.append(AppRowModel(
                    id: a.pid, pid: a.pid, bundleID: a.bundleID,
                    name: a.name, icon: a.icon,
                    volume: vol, muted: mute, level: 0,
                    isComm: isComm(a.bundleID)
                ))
            }
            byPid.removeValue(forKey: a.pid)
        }
        apps = next.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        refreshOutputs()
    }

    private func refreshMeters() {
        guard !apps.isEmpty else { return }
        for i in apps.indices {
            apps[i].level = engine.peak(for: apps[i].pid)
        }
    }

    func refreshOutputs() {
        outputs = engine.outputDevices()
    }

    func setVolume(pid: pid_t, value: Float) {
        guard let idx = apps.firstIndex(where: { $0.pid == pid }) else { return }
        apps[idx].volume = value
        // Touching the slider unmutes (standard mixer behavior).
        if apps[idx].muted {
            apps[idx].muted = false
            engine.setUserMuted(bundleID: apps[idx].bundleID, pid: pid, muted: false)
        }
        engine.setUserGain(bundleID: apps[idx].bundleID, pid: pid, value: value)
    }

    func setMuted(pid: pid_t, muted: Bool) {
        guard let idx = apps.firstIndex(where: { $0.pid == pid }) else { return }
        apps[idx].muted = muted
        engine.setUserMuted(bundleID: apps[idx].bundleID, pid: pid, muted: muted)
    }

    func setMasterVolume(_ v: Float) {
        masterVolume = v
        engine.setMaster(gain: v, muted: masterMuted)
    }

    func setMasterMuted(_ m: Bool) {
        masterMuted = m
        engine.setMaster(gain: masterVolume, muted: m)
    }

    func setDuck(enabled: Bool, amount: Float) {
        duckEnabled = enabled
        duckAmount = amount
        engine.setDuck(enabled: enabled, amount: amount)
    }

    func setOutput(_ id: UInt32) {
        engine.setDefaultOutput(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshOutputs()
        }
    }

    private func isComm(_ bid: String?) -> Bool {
        guard let b = bid?.lowercased() else { return false }
        return ["zoom", "teams", "slack", "discord", "webex", "skype", "facetime", "meet", "chime"]
            .contains { b.contains($0) }
    }
}
