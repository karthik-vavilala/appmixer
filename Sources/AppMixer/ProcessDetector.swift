import AppKit
import CoreAudio
import Foundation

struct AudibleApp: Identifiable, Equatable {
    let id: pid_t  // pid
    let pid: pid_t
    let bundleID: String?
    let name: String
    let icon: NSImage?
    let processObjectID: AudioObjectID

    static func == (lhs: AudibleApp, rhs: AudibleApp) -> Bool {
        lhs.pid == rhs.pid
    }
}

/// Detects apps currently producing output audio.
/// Uses kAudioHardwarePropertyProcessObjectList + kAudioProcessPropertyIsRunningOutput (piro),
/// with a 1 Hz fallback poll because HAL notifications can lag.
final class ProcessDetector {
    private var timer: Timer?
    var onChange: (([AudibleApp]) -> Void)?

    private var last: [AudibleApp] = []

    func start() {
        stop()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Also listen for HAL process-list changes for faster updates.
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // Listener block must stay alive; keep it simple with a C callback via helper object.
        AudioObjectAddPropertyListenerBlock(systemObject(), &addr, DispatchQueue.main) { [weak self] _, _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let apps = Self.snapshotAudibleApps()
        if apps != last {
            last = apps
            onChange?(apps)
        }
    }

    static func snapshotAudibleApps() -> [AudibleApp] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var processObjects: [AudioObjectID] = []
        do {
            processObjects = try getPropertyData(object: systemObject(), selector: kAudioHardwarePropertyProcessObjectList)
        } catch {
            return []
        }
        var out: [AudibleApp] = []
        for obj in processObjects {
            guard processIsRunningOutput(obj) else { continue }
            guard let pid = processPID(obj) else { continue }
            if pid == ownPID { continue } // never list ourselves
            let bundleID = processBundleID(obj)
            let running = NSRunningApplication(processIdentifier: pid)
            let name = running?.localizedName
                ?? bundleID?.components(separatedBy: ".").last
                ?? "PID \(pid)"
            let icon = running?.icon
            out.append(AudibleApp(id: pid, pid: pid, bundleID: bundleID, name: name, icon: icon, processObjectID: obj))
        }
        // Stable sort by name for UI.
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
