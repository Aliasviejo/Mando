// Intercepts the keyboard brightness and volume keys (Apple and most Logitech
// keyboards send them as "system defined" media key events; some send the
// brightness keys as keycodes 144/145, and PC layouts offer F14/F15). Volume keys are
// only taken while Mando is the output, so Mando can show the classic
// bottom-centre bezel; otherwise macOS handles them as usual.
//
// SPDX-License-Identifier: MIT

import AppKit
import ApplicationServices

final class MediaKeys {
    enum Key { case brightnessUp, brightnessDown, volumeUp, volumeDown, mute }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// Return true when the key was handled (it is then swallowed).
    var handler: ((Key, _ fine: Bool) -> Bool)?

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        // systemDefined (14) carries media keys; some keyboards send the
        // brightness keys as plain keyDown/keyUp with keycodes 144/145.
        let mask = CGEventMask(1 << 14) | CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: mediaKeyCallback, userInfo: refcon) else {
            Log.info("event tap could not be created (Accessibility not granted?)")
            return false
        }
        Log.info("event tap started")
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
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
            default: return Unmanaged.passUnretained(event)
            }
            if (keyCode == 107 || keyCode == 113) && !event.flags.intersection([.maskCommand, .maskControl]).isEmpty {
                return Unmanaged.passUnretained(event)   // someone's shortcut, not a brightness key
            }
            isDown = (type == .keyDown)
            fine = event.flags.contains(.maskShift) && event.flags.contains(.maskAlternate)
        } else {
            guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
                return Unmanaged.passUnretained(event)
            }
            let code = Int32((ns.data1 & 0xFFFF_0000) >> 16)
            isDown = ((ns.data1 & 0xFF00) >> 8) == 0xA
            switch code {
            case NX_KEYTYPE_BRIGHTNESS_UP: key = .brightnessUp
            case NX_KEYTYPE_BRIGHTNESS_DOWN: key = .brightnessDown
            case NX_KEYTYPE_SOUND_UP: key = .volumeUp
            case NX_KEYTYPE_SOUND_DOWN: key = .volumeDown
            case NX_KEYTYPE_MUTE: key = .mute
            default: return Unmanaged.passUnretained(event)
            }
            fine = ns.modifierFlags.contains(.shift) && ns.modifierFlags.contains(.option)
        }
        if isDown {
            let handled = handler?(key, fine) ?? false
            lastDownHandled[key] = handled
            return handled ? nil : Unmanaged.passUnretained(event)
        }
        // Swallow the key-up only when we swallowed its key-down.
        return (lastDownHandled[key] ?? false) ? nil : Unmanaged.passUnretained(event)
    }

    private var lastDownHandled: [Key: Bool] = [:]
}

private func mediaKeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<MediaKeys>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}
