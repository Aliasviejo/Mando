// Thin wrappers over the CoreAudio C API.
// SPDX-License-Identifier: MIT

import CoreAudio
import Foundation

enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func get<T>(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ initial: T) -> T? {
        var addr = addr
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let err = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0) }
        return err == noErr ? value : nil
    }

    @discardableResult
    static func set<T>(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ value: T) -> OSStatus {
        var addr = addr
        var value = value
        let size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { AudioObjectSetPropertyData(obj, &addr, 0, nil, size, $0) }
    }

    static func string(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &ref)
        guard err == noErr, let s = ref?.takeRetainedValue() else { return nil }
        return s as String
    }

    static func array<T>(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress, of: T.Type) -> [T] {
        var addr = addr
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, buffer) == noErr else { return [] }
        let typed = buffer.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: Int(size) / MemoryLayout<T>.stride))
    }

    static func isSettable(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
        var addr = addr
        guard AudioObjectHasProperty(obj, &addr) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(obj, &addr, &settable) == noErr && settable.boolValue
    }

    // MARK: Devices

    static func allDevices() -> [AudioObjectID] {
        array(system, address(kAudioHardwarePropertyDevices), of: AudioObjectID.self)
    }

    static func device(withUID uid: String) -> AudioObjectID? {
        allDevices().first { CA.string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    static func uid(_ dev: AudioObjectID) -> String? { string(dev, kAudioDevicePropertyDeviceUID) }
    static func name(_ dev: AudioObjectID) -> String { string(dev, kAudioObjectPropertyName) ?? "?" }

    static func hasOutput(_ dev: AudioObjectID) -> Bool {
        !array(dev, address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput), of: AudioStreamID.self).isEmpty
    }

    /// True when macOS can change this device's volume itself (built-in speakers,
    /// AirPods, USB DACs…). HDMI/DisplayPort outputs usually return false.
    static func hasSettableVolume(_ dev: AudioObjectID) -> Bool {
        let out = kAudioObjectPropertyScopeOutput
        for element: UInt32 in [kAudioObjectPropertyElementMain, 1, 2] {
            if isSettable(dev, address(kAudioDevicePropertyVolumeScalar, out, element)) { return true }
        }
        return false
    }

    static var defaultOutput: AudioObjectID {
        CA.get(system, address(kAudioHardwarePropertyDefaultOutputDevice), AudioObjectID(0)) ?? 0
    }

    static func setDefaultOutput(_ dev: AudioObjectID) {
        set(system, address(kAudioHardwarePropertyDefaultOutputDevice), dev)
        set(system, address(kAudioHardwarePropertyDefaultSystemOutputDevice), dev)
    }

    static func nominalRate(_ dev: AudioObjectID) -> Float64 {
        get(dev, address(kAudioDevicePropertyNominalSampleRate), Float64(0)) ?? 0
    }

    static func availableRates(_ dev: AudioObjectID) -> [Float64] {
        array(dev, address(kAudioDevicePropertyAvailableNominalSampleRates), of: AudioValueRange.self).map { $0.mMinimum }
    }

    // MARK: Listeners

    @discardableResult
    static func listen(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ block: @escaping () -> Void) -> AudioObjectPropertyListenerBlock {
        var addr = addr
        let listener: AudioObjectPropertyListenerBlock = { _, _ in DispatchQueue.main.async(execute: block) }
        AudioObjectAddPropertyListenerBlock(obj, &addr, DispatchQueue.main, listener)
        return listener
    }

    static func unlisten(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ listener: @escaping AudioObjectPropertyListenerBlock) {
        var addr = addr
        AudioObjectRemovePropertyListenerBlock(obj, &addr, DispatchQueue.main, listener)
    }
}
