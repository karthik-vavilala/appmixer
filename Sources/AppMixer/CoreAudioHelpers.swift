import CoreAudio
import Foundation

enum CAError: Error {
    case status(OSStatus, String)
}

func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw CAError.status(status, what) }
}

/// Read a property where the size is known via AudioObjectGetPropertyDataSize.
func getPropertyData<T>(object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) throws -> [T] {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: element
    )
    var size: UInt32 = 0
    var st = AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size)
    try check(st, "get size \(selector)")
    guard size > 0 else { return [] }
    var data = Data(count: Int(size))
    st = data.withUnsafeMutableBytes { buf in
        guard let base = buf.baseAddress else { return kAudioHardwareBadObjectError }
        var ioSize = UInt32(buf.count)
        let s = AudioObjectGetPropertyData(object, &addr, 0, nil, &ioSize, base)
        size = ioSize
        return s
    }
    try check(st, "get data \(selector)")
    let count = Int(size) / MemoryLayout<T>.stride
    guard count > 0 else { return [] }
    return data.withUnsafeBytes { raw in
        Array(raw.bindMemory(to: T.self).prefix(count))
    }
}

func getPropertySingle<T>(object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) throws -> T {
    let arr: [T] = try getPropertyData(object: object, selector: selector, scope: scope, element: element)
    guard let first = arr.first else { throw CAError.status(-1, "empty property \(selector)") }
    return first
}

func getCFProperty(object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> CFTypeRef? {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    var size = UInt32(MemoryLayout<CFTypeRef?>.size)
    var value: CFTypeRef?
    let st = withUnsafeMutablePointer(to: &value) { ptr in
        AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
    }
    guard st == noErr else { return nil }
    return value
}

func systemObject() -> AudioObjectID {
    AudioObjectID(kAudioObjectSystemObject)
}

func defaultOutputDevice() throws -> AudioObjectID {
    try getPropertySingle(object: systemObject(), selector: kAudioHardwarePropertyDefaultOutputDevice)
}

func allOutputDevices() -> [AudioObjectID] {
    do {
        let devices: [AudioObjectID] = try getPropertyData(object: systemObject(), selector: kAudioHardwarePropertyDevices)
        return devices.filter { isOutputDevice($0) }
    } catch {
        return []
    }
}

func isOutputDevice(_ id: AudioObjectID) -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    let st = AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size)
    return st == noErr && size > 0
}

func deviceUID(_ id: AudioObjectID) -> String? {
    getCFProperty(object: id, selector: kAudioDevicePropertyDeviceUID) as? String
}

func deviceName(_ id: AudioObjectID) -> String {
    if let s = getCFProperty(object: id, selector: kAudioDevicePropertyDeviceNameCFString) as? String {
        return s
    }
    return "Device \(id)"
}

func tapUID(_ tapID: AudioObjectID) -> String? {
    getCFProperty(object: tapID, selector: kAudioTapPropertyUID) as? String
}

func translatePIDToProcessObject(_ pid: pid_t) -> AudioObjectID? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var processObject = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var pidVar = pid
    let st = withUnsafeMutablePointer(to: &processObject) { outPtr in
        withUnsafePointer(to: &pidVar) { pidPtr in
            AudioObjectGetPropertyData(
                systemObject(), &addr,
                UInt32(MemoryLayout<pid_t>.size), pidPtr,
                &size, outPtr
            )
        }
    }
    guard st == noErr, processObject != kAudioObjectUnknown else { return nil }
    return processObject
}

func processIsRunningOutput(_ processObject: AudioObjectID) -> Bool {
    do {
        let v: UInt32 = try getPropertySingle(object: processObject, selector: kAudioProcessPropertyIsRunningOutput)
        return v != 0
    } catch {
        return false
    }
}

func processPID(_ processObject: AudioObjectID) -> pid_t? {
    do {
        let v: Int32 = try getPropertySingle(object: processObject, selector: kAudioProcessPropertyPID)
        return pid_t(v)
    } catch { return nil }
}

func processBundleID(_ processObject: AudioObjectID) -> String? {
    getCFProperty(object: processObject, selector: kAudioProcessPropertyBundleID) as? String
}
