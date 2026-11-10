// Intercepts the keyboard brightness and volume keys (Apple and most Logitech
// keyboards send them as "system defined" media key events; some send the
// brightness keys as keycodes 144/145, and PC layouts offer F14/F15).
//
// The tap sees every keystroke of the session, so it runs on its own thread
// and never waits for the app: it decides from two flags whether a key is
// Mando's, swallows it, and hands the work to the main thread. A busy or
// blocked main thread can't stall the keyboard.
//
// SPDX-License-Identifier: MIT

import AppKit
import ApplicationServices

final class MediaKeys {
    enum Key {
        case brightnessUp, brightnessDown, volumeUp, volumeDown, mute
        var isBrightness: Bool { self == .brightnessUp || self == .brightnessDown }
    }

    /// Called on the main thread for each key press Mando takes.
    var handler: ((Key, _ fine: Bool) -> Void)?

    private var tap: CFMachPort?
    private let lock = NSLock()
    private var takesBrightness = false
    private var takesVolume = false
    private var swallowedDown: Set<Key> = [] // tap thread only

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// Which keys to swallow and handle; the rest go on to macOS untouched.
    func take(brightness: Bool, volume: Bool) {
        lock.withLock { takesBrightness = brightness; takesVolume = volume }
    }

    func start() {
        guard tap == nil else { return }
        // systemDefined (14) carries media keys; some keyboards send the
        // brightness keys as plain keyDown/keyUp with keycodes 144/145.
        let mask = CGEventMask(1 << 14) | CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: mediaKeyCallback, userInfo: refcon) else {
            Log.info("event tap could not be created (Accessibility not granted?)")
            return
        }
        self.tap = tap
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "mando.keys"
        thread.qualityOfService = .userInteractive
        thread.start()
        Log.info("event tap started")
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        let key: Key
        let isDown: Bool
        let fine: Bool
        if type == .keyDown || type == .keyUp {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            // F14/F15 are Scroll Lock/Pause on PC-layout keyboards (Logitech K120,
            // MX Keys in Windows mode…); macOS uses them for brightness too.
            switch keyCode {
            case 144, 113: key = .brightnessUp
            case 145, 107: key = .brightnessDown
            default: return pass
            }
            if (keyCode == 107 || keyCode == 113) && !event.flags.intersection([.maskCommand, .maskControl]).isEmpty {
                return pass // someone's shortcut, not a brightness key
            }
            isDown = (type == .keyDown)
            fine = event.flags.contains(.maskShift) && event.flags.contains(.maskAlternate)
        } else {
            guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return pass }
            let code = Int32((ns.data1 & 0xFFFF_0000) >> 16)
            isDown = ((ns.data1 & 0xFF00) >> 8) == 0xA
            switch code {
            case NX_KEYTYPE_BRIGHTNESS_UP: key = .brightnessUp
            case NX_KEYTYPE_BRIGHTNESS_DOWN: key = .brightnessDown
            case NX_KEYTYPE_SOUND_UP: key = .volumeUp
            case NX_KEYTYPE_SOUND_DOWN: key = .volumeDown
            case NX_KEYTYPE_MUTE: key = .mute
            default: return pass
            }
            fine = ns.modifierFlags.contains(.shift) && ns.modifierFlags.contains(.option)
        }
        if isDown {
            let taken = lock.withLock { key.isBrightness ? takesBrightness : takesVolume }
            guard taken else { swallowedDown.remove(key); return pass }
            swallowedDown.insert(key)
            DispatchQueue.main.async { [weak self] in self?.handler?(key, fine) }
            return nil
        }
        // Swallow the key-up only when we swallowed its key-down.
        return swallowedDown.contains(key) ? nil : pass
    }
}

private func mediaKeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return autoreleasepool { Unmanaged<MediaKeys>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event) }
}
