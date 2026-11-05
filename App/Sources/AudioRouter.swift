// Decides when to route audio through the Mando driver and keeps the route alive.
//
// Policy: whenever the Mac's output is a device macOS can't change the volume
// of (HDMI, DisplayPort…), Mando becomes the system output and forwards the
// audio to that device. Devices with their own volume (speakers, AirPods…) are
// left alone.
//
// SPDX-License-Identifier: MIT

import CoreAudio
import Foundation

final class AudioRouter {
    static let mandoUID = "MandoDevice_UID"
    private static let aggregateUID = "com.aliasviejo.mando.aggregate"
    private static let savedTargetKey = "targetDeviceUID"

    private(set) var target: AudioObjectID?
    private var aggregate: AudioObjectID = 0
    private var router: OpaquePointer?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var volumeListener: AudioObjectPropertyListenerBlock?
    private var listenedMando: AudioObjectID = 0
    private var busy = false

    var onChange: (() -> Void)?

    var mando: AudioObjectID? { CA.device(withUID: Self.mandoUID) }
    var driverInstalled: Bool { mando != nil }
    var isRouting: Bool { router != nil }

    // MARK: Lifecycle

    func start() {
        let sys = CA.system
        listeners.append((sys, CA.address(kAudioHardwarePropertyDefaultOutputDevice),
                          CA.listen(sys, CA.address(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in self?.evaluate() }))
        listeners.append((sys, CA.address(kAudioHardwarePropertyDevices),
                          CA.listen(sys, CA.address(kAudioHardwarePropertyDevices)) { [weak self] in self?.devicesChanged() }))
        evaluate()
    }

    /// Restore the real device as system output and tear the route down.
    func stop() {
        for (obj, addr, l) in listeners { CA.unlisten(obj, addr, l) }
        listeners.removeAll()
        let restoreTo = target
        teardown()
        if let mando, CA.defaultOutput == mando, let restoreTo { CA.setDefaultOutput(restoreTo) }
    }

    // MARK: Policy

    private func devicesChanged() {
        // Target unplugged? Re-evaluate; also refresh the Mando volume listener.
        if let t = target, !CA.allDevices().contains(t) {
            teardown()
            target = nil
        }
        evaluate()
    }

    func evaluate() {
        guard !busy else { return }
        busy = true
        defer { busy = false; attachVolumeListener(); onChange?() }

        guard let mando else { teardown(); return }
        let current = CA.defaultOutput

        if current == mando {
            // Already on Mando (e.g. after a crash or a relaunch): find the real device.
            if target == nil, let uid = UserDefaults.standard.string(forKey: Self.savedTargetKey),
               let dev = CA.device(withUID: uid) {
                target = dev
            }
            if let target, router == nil { buildRoute(to: target) }
            if target == nil {
                // Nothing to forward to; fall back to any real output.
                if let fallback = outputDevices().first { CA.setDefaultOutput(fallback) }
            }
            return
        }

        if current != 0, current != aggregate, !CA.hasSettableVolume(current), CA.hasOutput(current) {
            // A fixed-volume output (HDMI…) was selected: wrap it with Mando.
            if target != current || router == nil { buildRoute(to: current) }
            if router != nil { CA.setDefaultOutput(mando) }
        } else {
            // A device with its own volume: get out of the way.
            teardown()
            target = nil
        }
    }

    /// Real output devices the user can choose from (Mando and our aggregate hidden).
    func outputDevices() -> [AudioObjectID] {
        CA.allDevices().filter { dev in
            guard CA.hasOutput(dev) else { return false }
            let uid = CA.uid(dev) ?? ""
            return uid != Self.mandoUID && uid != Self.aggregateUID && CA.transportType(dev) != kAudioDeviceTransportTypeAggregate
        }
    }

    /// User picked a device in our menu.
    func select(_ dev: AudioObjectID) {
        CA.setDefaultOutput(dev) // the default-output listener runs evaluate()
    }

    // MARK: Volume (Mando's own control)

    var volume: Float {
        get {
            guard let mando else { return 0 }
            return CA.get(mando, CA.address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput), Float32(0)) ?? 0
        }
        set {
            guard let mando else { return }
            CA.set(mando, CA.address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput), Float32(max(0, min(1, newValue))))
        }
    }

    var muted: Bool {
        get {
            guard let mando else { return false }
            return (CA.get(mando, CA.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput), UInt32(0)) ?? 0) != 0
        }
        set {
            guard let mando else { return }
            CA.set(mando, CA.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput), UInt32(newValue ? 1 : 0))
        }
    }

    /// True while the Mac is actually playing through Mando.
    var isActiveOutput: Bool {
        guard let mando else { return false }
        return CA.defaultOutput == mando
    }

    private func attachVolumeListener() {
        let current = mando ?? 0
        guard current != listenedMando else { return }
        let addr = CA.address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput)
        if listenedMando != 0, let l = volumeListener { CA.unlisten(listenedMando, addr, l) }
        volumeListener = nil
        listenedMando = current
        if current != 0 { volumeListener = CA.listen(current, addr) { [weak self] in self?.onChange?() } }
    }

    // MARK: Route

    private func buildRoute(to dev: AudioObjectID) {
        teardown()
        guard let mando, let targetUID = CA.uid(dev) else { return }

        // Run Mando at the target's sample rate so no conversion is needed.
        var rate = CA.nominalRate(dev)
        let mandoRates = CA.availableRates(mando)
        if !mandoRates.contains(rate) {
            rate = 48000
            if CA.availableRates(dev).contains(rate) {
                CA.set(dev, CA.address(kAudioDevicePropertyNominalSampleRate), rate)
            }
        }
        CA.set(mando, CA.address(kAudioDevicePropertyNominalSampleRate), rate)

        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: Self.aggregateUID,
            kAudioAggregateDeviceNameKey: "Mando Router",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceMainSubDeviceKey: targetUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: targetUID],
                [kAudioSubDeviceUIDKey: Self.mandoUID, kAudioSubDeviceDriftCompensationKey: 1],
            ],
        ]
        var agg: AudioObjectID = 0
        guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &agg) == noErr, agg != 0 else {
            Log.info("could not create aggregate device")
            return
        }
        aggregate = agg
        // The aggregate needs a moment to publish its streams.
        let deadline = Date().addingTimeInterval(1.0)
        while CA.bufferCount(agg, scope: kAudioObjectPropertyScopeOutput) == 0 && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        let inBuffers = CA.bufferCount(dev, scope: kAudioObjectPropertyScopeInput)
        let outBuffers = CA.bufferCount(dev, scope: kAudioObjectPropertyScopeOutput)
        var err: OSStatus = 0
        router = MandoRouterStart(agg, inBuffers, outBuffers, &err)
        if router == nil {
            Log.info("router failed to start (\(err))")
            AudioHardwareDestroyAggregateDevice(agg)
            aggregate = 0
            return
        }
        target = dev
        UserDefaults.standard.set(targetUID, forKey: Self.savedTargetKey)
    }

    private func teardown() {
        if let r = router { MandoRouterStop(r); router = nil }
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
    }
}
