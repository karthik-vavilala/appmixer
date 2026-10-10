import CoreAudio
import Foundation
import os.lock

/// Simple stereo ring buffer for one tapped app.
/// Main thread writes from tap IOProc, output IOProc reads.
/// Uses unfair lock + trylock in realtime paths to avoid blocking.
final class StereoRing: @unchecked Sendable {
    private let capacityFrames: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private var writeIdx: Int = 0
    private var readIdx: Int = 0
    private var count: Int = 0
    private var lock = os_unfair_lock()

    init(capacityFrames: Int = 16384) {
        self.capacityFrames = capacityFrames
        self.left = .allocate(capacity: capacityFrames)
        self.right = .allocate(capacity: capacityFrames)
        self.left.initialize(repeating: 0, count: capacityFrames)
        self.right.initialize(repeating: 0, count: capacityFrames)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    /// Called from tap IOProc (realtime). Never blocks: drops on contention.
    nonisolated func push(leftIn: UnsafePointer<Float>, rightIn: UnsafePointer<Float>?, frames: Int, stride: Int) {
        if os_unfair_lock_trylock(&lock) == false { return }
        defer { os_unfair_lock_unlock(&lock) }
        var i = 0
        while i < frames {
            if count >= capacityFrames {
                // Overrun: drop oldest.
                readIdx = (readIdx + 1) % capacityFrames
                count -= 1
            }
            left[writeIdx] = leftIn[i * stride]
            if let r = rightIn {
                right[writeIdx] = r[i * stride]
            } else {
                right[writeIdx] = leftIn[i * stride]
            }
            writeIdx = (writeIdx + 1) % capacityFrames
            count += 1
            i += 1
        }
    }

    nonisolated func pushInterleaved(_ data: UnsafePointer<Float>, frames: Int, channels: Int) {
        if os_unfair_lock_trylock(&lock) == false { return }
        defer { os_unfair_lock_unlock(&lock) }
        for i in 0..<frames {
            if count >= capacityFrames {
                readIdx = (readIdx + 1) % capacityFrames
                count -= 1
            }
            left[writeIdx] = data[i * channels]
            right[writeIdx] = channels > 1 ? data[i * channels + 1] : data[i * channels]
            writeIdx = (writeIdx + 1) % capacityFrames
            count += 1
        }
    }

    /// Called from output IOProc (realtime). Adds into out buffers with gain.
    /// Returns number of frames actually mixed.
    nonisolated func popAndMix(outLeft: UnsafeMutablePointer<Float>, outRight: UnsafeMutablePointer<Float>, frames: Int, gain: Float, outStride: Int = 1) -> Int {
        if os_unfair_lock_trylock(&lock) == false { return 0 }
        defer { os_unfair_lock_unlock(&lock) }
        let n = min(frames, count)
        for i in 0..<n {
            outLeft[i * outStride] += left[readIdx] * gain
            outRight[i * outStride] += right[readIdx] * gain
            readIdx = (readIdx + 1) % capacityFrames
        }
        count -= n
        // Underrun: remaining output samples stay as-is (system mix preserved).
        return n
    }

    func clear() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        writeIdx = 0; readIdx = 0; count = 0
    }
}

/// One tapped app: tap + tap-only aggregate + tap IOProc + ring + gain/peak state.
final class TapSlot: @unchecked Sendable {
    let pid: pid_t
    let bundleID: String?
    let processObjectID: AudioObjectID
    var tapID: AudioObjectID = kAudioObjectUnknown
    var aggregateID: AudioObjectID = kAudioObjectUnknown
    var ioProc: AudioDeviceIOProcID?
    var tapUID: String = ""

    private var stateLock = os_unfair_lock()
    private var _gain: Float = 1.0       // user gain 0...1.5 (effective incl. duck/master applied by engine)
    private var _muted: Bool = false
    private var _peak: Float = 0

    let ring = StereoRing()

    init(pid: pid_t, bundleID: String?, processObjectID: AudioObjectID) {
        self.pid = pid
        self.bundleID = bundleID
        self.processObjectID = processObjectID
    }

    nonisolated func setGain(_ g: Float) {
        os_unfair_lock_lock(&stateLock)
        _gain = g
        os_unfair_lock_unlock(&stateLock)
    }

    nonisolated func setMuted(_ m: Bool) {
        os_unfair_lock_lock(&stateLock)
        _muted = m
        os_unfair_lock_unlock(&stateLock)
    }

    nonisolated func loadGain() -> (gain: Float, muted: Bool) {
        if os_unfair_lock_trylock(&stateLock) == false { return (1.0, false) }
        defer { os_unfair_lock_unlock(&stateLock) }
        return (_gain, _muted)
    }

    nonisolated func updatePeak(_ v: Float) {
        if os_unfair_lock_trylock(&stateLock) == false { return }
        _peak = max(_peak * 0.95, v)
        os_unfair_lock_unlock(&stateLock)
    }

    nonisolated func readPeak() -> Float {
        if os_unfair_lock_trylock(&stateLock) == false { return 0 }
        defer { os_unfair_lock_unlock(&stateLock) }
        return _peak
    }
}
