// Decides when the Mac plays through the Mando driver, and on which device the
// driver plays.
//
// Policy: whenever the Mac's output is a device macOS can't change the volume
// of (HDMI, DisplayPort…), Mando becomes the system output and the driver
// plays on that device (the "target"). Devices with their own volume
// (speakers, AirPods…) are left alone.
//
// When the target goes away without the user choosing another one (the display
// sleeps or is unplugged), audio falls back to a real output and Mando takes
// the device again as soon as it returns.
//
// The driver is asked through its custom "target" property and answers every
// request with a change notification, so only one request is in flight.
//
// SPDX-License-Identifier: MIT

import CoreAudio
import Foundation

final class AudioRouter {
    static let mandoUID = "MandoDevice_UID"
    private static let savedTargetKey = "targetDeviceUID"
    /// The driver's custom property: UID of the device it plays on ("" = none).
    private static let targetProperty = CA.address(0x6D74_6774) // 'mtgt'

    /// The device the driver confirmed it is playing on.
    private(set) var target: AudioObjectID?
    /// UID asked of the driver and not answered yet ("" = stop playing).
    private var pending: String?
    /// UID the driver could not play on; not asked again until the devices change.
    private var refused: String?
    /// UID of the device we left only because it disappeared, and the output used meanwhile.
    private var awaitedUID: String?
    private var fallback: AudioObjectID = 0

    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var mandoListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var listenedMando: AudioObjectID = 0

    var onChange: (() -> Void)?

    var mando: AudioObjectID? { CA.device(withUID: Self.mandoUID) }
    var driverInstalled: Bool { mando != nil }
    var isAwaitingTarget: Bool { awaitedUID != nil }

    // MARK: Lifecycle

    func start() {
        let sys = CA.system
        func listen(_ selector: AudioObjectPropertySelector, _ block: @escaping () -> Void) {
            listeners.append((sys, CA.address(selector), CA.listen(sys, CA.address(selector), block)))
        }
        listen(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in self?.evaluate() }
        listen(kAudioHardwarePropertyDevices) { [weak self] in self?.devicesChanged() }
        listen(kAudioHardwarePropertyServiceRestarted) { [weak self] in
            // A new coreaudiod: the driver plays on nothing and owes no answer.
            self?.target = nil
            self?.pending = nil
            self?.devicesChanged()
        }
        attachMandoListeners()
        // Whatever a previous run left the driver doing, start from "none".
        // Its answer runs the policy.
        target = nil
        if !request("") { evaluate() }
    }

    /// Stop the driver's playback and restore the real device as system output.
    func stop() {
        for (obj, addr, l) in listeners { CA.unlisten(obj, addr, l) }
        listeners.removeAll()
        let restoreTo = target
        target = nil
        pending = nil
        if let mando {
            CA.set(mando, Self.targetProperty, "" as CFString)
            if CA.defaultOutput == mando, let restoreTo { CA.setDefaultOutput(restoreTo) }
        }
    }

    // MARK: Driver

    /// Asks the driver to play on the device with that UID ("" = stop).
    /// False if the driver can't be asked (missing, or older than this app).
    private func request(_ uid: String) -> Bool {
        guard let mando, CA.set(mando, Self.targetProperty, uid as CFString) == noErr else { return false }
        pending = uid
        return true
    }

    private func ask(_ dev: AudioObjectID) -> Bool {
        guard let mando, let uid = CA.uid(dev) else { return false }
        // Run Mando at the target's sample rate so no conversion is needed.
        var rate = CA.nominalRate(dev)
        if !CA.availableRates(mando).contains(rate) {
            rate = 48000
            if CA.availableRates(dev).contains(rate) {
                CA.set(dev, CA.address(kAudioDevicePropertyNominalSampleRate), rate)
            }
        }
        CA.set(mando, CA.address(kAudioDevicePropertyNominalSampleRate), rate)
        if request(uid) { return true }
        refused = uid
        return false
    }

    private func driverAnswered() {
        guard let asked = pending, let mando else { return }
        pending = nil
        let playing = CA.string(mando, Self.targetProperty.mSelector) ?? ""
        if playing == asked {
            target = asked.isEmpty ? nil : CA.device(withUID: asked)
            if target != nil { UserDefaults.standard.set(asked, forKey: Self.savedTargetKey) }
        } else {
            Log.info("the driver could not play on \(asked)")
            refused = asked
        }
        evaluate()
    }

    private func clearTarget() {
        guard target != nil else { return }
        target = nil
        _ = request("")
    }

    // MARK: Policy

    private func devicesChanged() {
        if let t = target, !CA.allDevices().contains(t) { clearTarget() }
        refused = nil
        evaluate()
    }

    func evaluate() {
        attachMandoListeners()
        if pending == nil { applyPolicy() } // otherwise the driver's answer runs it
        onChange?()
    }

    private func usable(_ uid: String?) -> AudioObjectID? {
        guard let uid, uid != refused, let dev = CA.device(withUID: uid), CA.hasOutput(dev) else { return nil }
        return dev
    }

    private func applyPolicy() {
        guard let mando else { target = nil; return }

        if let dev = usable(awaitedUID) {
            // The display is back.
            if target == dev {
                awaitedUID = nil
                CA.setDefaultOutput(mando)
            } else {
                _ = ask(dev)
            }
            return
        }

        let current = CA.defaultOutput
        if current == mando {
            guard target == nil else { return }
            // On Mando with nowhere to play: the target vanished, or we were relaunched.
            let uid = UserDefaults.standard.string(forKey: Self.savedTargetKey)
            if let dev = usable(uid), ask(dev) { return }
            awaitedUID = uid
            fallback = outputDevices().first ?? 0
            if fallback != 0 { CA.setDefaultOutput(fallback) }
        } else if current != 0, !CA.hasSettableVolume(current), CA.hasOutput(current) {
            // A fixed-volume output (HDMI…) was selected: put Mando in front of it.
            awaitedUID = nil
            if target == current {
                CA.setDefaultOutput(mando)
            } else if CA.uid(current) != refused {
                _ = ask(current)
            }
        } else {
            // A device with its own volume: get out of the way. Unless it is our
            // own fallback, the user chose it, so stop waiting for the display.
            if current != fallback { awaitedUID = nil }
            clearTarget()
        }
    }

    /// Real output devices the user can choose from (Mando hidden).
    func outputDevices() -> [AudioObjectID] {
        CA.allDevices().filter { CA.hasOutput($0) && CA.uid($0) != Self.mandoUID }
    }

    /// User picked a device in our menu.
    func select(_ dev: AudioObjectID) {
        awaitedUID = nil
        refused = nil
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

    /// Follows the Mando device (its ID changes when the driver is reinstalled).
    private func attachMandoListeners() {
        let current = mando ?? 0
        guard current != listenedMando else { return }
        for (addr, l) in mandoListeners { CA.unlisten(listenedMando, addr, l) }
        mandoListeners.removeAll()
        listenedMando = current
        guard current != 0 else { return }
        let volume = CA.address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput)
        mandoListeners.append((volume, CA.listen(current, volume) { [weak self] in self?.onChange?() }))
        mandoListeners.append((Self.targetProperty, CA.listen(current, Self.targetProperty) { [weak self] in self?.driverAnswered() }))
    }
}
