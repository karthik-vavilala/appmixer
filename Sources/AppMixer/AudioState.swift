import AppKit
import Combine
import Foundation

/// One UI row = one application (bundle ID). Helper processes sharing a
/// bundle merge into a single row; the engine taps the whole bundle.
struct AppRowModel: Identifiable {
    var id: String { key }
    let key: String
    let bundleID: String?
    var name: String
    var icon: NSImage?
    var volume: Float      // 0...1
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
        engine.setAudibleApps(audible)
        engine.noteMutated()
        // Group helper PIDs by app key; preserve existing slider values.
        var grouped: [String: [AudibleApp]] = [:]
        for a in audible {
            grouped[engine.keyFor(bundleID: a.bundleID, pid: a.pid), default: []].append(a)
        }
        var byKey: [String: AppRowModel] = Dictionary(uniqueKeysWithValues: apps.map { ($0.key, $0) })
        var next: [AppRowModel] = []
        for (key, group) in grouped {
            // Prefer the main app process for name/icon over helpers.
            let rep = group.sorted { score($0) > score($1) }.first!
            if var existing = byKey[key] {
                existing.name = rep.name
                existing.icon = rep.icon ?? existing.icon
                next.append(existing)
            } else {
                next.append(AppRowModel(
                    key: key, bundleID: rep.bundleID,
                    name: rep.name, icon: rep.icon,
                    volume: engine.userGain(key: key),
                    muted: engine.isMuted(key: key),
                    level: 0, isComm: isComm(rep.bundleID)
                ))
            }
            byKey.removeValue(forKey: key)
        }
        apps = next.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        refreshOutputs()
    }

    /// Rank processes for display: real app bundle + running app first.
    private func score(_ a: AudibleApp) -> Int {
        var s = 0
        if a.bundleID != nil { s += 2 }
        if NSRunningApplication(processIdentifier: a.pid) != nil { s += 1 }
        return s
    }

    private func refreshMeters() {
        guard !apps.isEmpty else { return }
        for i in apps.indices {
            apps[i].level = engine.peak(key: apps[i].key)
        }
    }

    func refreshOutputs() {
        outputs = engine.outputDevices()
    }

    func setVolume(key: String, value: Float) {
        guard let idx = apps.firstIndex(where: { $0.key == key }) else { return }
        apps[idx].volume = value
        // Touching the slider unmutes (standard mixer behavior).
        if apps[idx].muted {
            apps[idx].muted = false
            engine.setUserMuted(key: key, muted: false)
        }
        engine.setUserGain(key: key, bundleID: apps[idx].bundleID, value: value)
    }

    func setMuted(key: String, muted: Bool) {
        guard let idx = apps.firstIndex(where: { $0.key == key }) else { return }
        apps[idx].muted = muted
        engine.setUserMuted(key: key, muted: muted)
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
