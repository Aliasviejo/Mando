// Menu bar UI and glue.
// SPDX-License-Identifier: MIT

import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let audio = AudioRouter()
    private let keys = MediaKeys()
    private var display: DDCDisplay?

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let volumeSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let brightnessSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)

    private static let brightnessSteps: Float = 16

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "dial.medium", accessibilityDescription: "Mando")
        menu.delegate = self
        statusItem.menu = menu

        volumeSlider.target = self
        volumeSlider.action = #selector(volumeSliderMoved)
        brightnessSlider.target = self
        brightnessSlider.action = #selector(brightnessSliderMoved)
        brightnessSlider.isContinuous = true

        audio.onChange = { [weak self] in self?.refreshSliders() }
        audio.start()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = DDCDisplay.findExternal()
            Log.info(found.map { "DDC display: \($0.name) id=\($0.displayID)" } ?? "DDC display: none")
            DispatchQueue.main.async {
                self?.display = found
                self?.refreshSliders()
            }
        }
        Log.info("accessibility trusted: \(MediaKeys.hasAccessibility)")

        keys.handler = { [weak self] key, fine in
            guard let self else { return false }
            switch key {
            case .brightnessUp, .brightnessDown: return self.handleBrightnessKey(key, fine: fine)
            case .volumeUp, .volumeDown, .mute: return self.handleVolumeKey(key, fine: fine)
            }
        }
        if MediaKeys.hasAccessibility {
            keys.start()
        } else {
            MediaKeys.requestAccessibility()
            pollForAccessibility()
        }

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screensChanged),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        audio.stop()
    }

    private func pollForAccessibility() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            if MediaKeys.hasAccessibility { self.keys.start() } else { self.pollForAccessibility() }
        }
    }

    @objc private func screensChanged() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            let found = DDCDisplay.findExternal()
            DispatchQueue.main.async { self?.display = found; self?.refreshSliders() }
        }
    }

    // MARK: Brightness

    private func handleBrightnessKey(_ key: MediaKeys.Key, fine: Bool) -> Bool {
        guard let display else { Log.info("brightness key ignored: no DDC display"); return false }
        let steps = fine ? Self.brightnessSteps * 4 : Self.brightnessSteps
        var level = (display.normalizedBrightness * steps).rounded()
        level += (key == .brightnessUp) ? 1 : -1
        let value = max(0, min(1, level / steps))
        display.setBrightness(normalized: value)
        showBrightnessOSD(value)
        brightnessSlider.floatValue = value
        return true
    }

    @objc private func brightnessSliderMoved() {
        display?.setBrightness(normalized: brightnessSlider.floatValue)
    }

    private func showBrightnessOSD(_ value: Float) {
        guard let display else { return }
        _ = MandoShowOSD(display.displayID, 1, UInt32((value * Self.brightnessSteps * 4).rounded()), UInt32(Self.brightnessSteps * 4))
    }

    // MARK: Volume

    @objc private func volumeSliderMoved() {
        audio.volume = volumeSlider.floatValue
    }

    /// Only while Mando is the output; otherwise macOS handles the keys itself.
    private func handleVolumeKey(_ key: MediaKeys.Key, fine: Bool) -> Bool {
        guard audio.isActiveOutput else { return false }
        var value = audio.volume
        if key == .mute {
            audio.muted.toggle()
        } else {
            let steps = fine ? Self.brightnessSteps * 4 : Self.brightnessSteps
            var level = (value * steps).rounded()
            level += (key == .volumeUp) ? 1 : -1
            value = max(0, min(1, level / steps))
            audio.volume = value
            if audio.muted { audio.muted = false }
        }
        let muted = audio.muted || value == 0
        let total = UInt32(Self.brightnessSteps * 4)
        _ = MandoShowOSD(osdDisplayID, muted ? 4 : 3, muted ? 0 : UInt32((value * Float(total)).rounded()), total)
        volumeSlider.floatValue = value
        return true
    }

    /// Display the mouse is on, so the bezel shows where you're looking.
    private var osdDisplayID: CGDirectDisplayID {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        return (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    private func refreshSliders() {
        volumeSlider.floatValue = audio.volume
        if let display { brightnessSlider.floatValue = display.normalizedBrightness }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        refreshSliders()

        if audio.driverInstalled {
            menu.addItem(header("Volumen"))
            menu.addItem(sliderItem(volumeSlider, symbol: "speaker.wave.2.fill"))
            let status: String
            if audio.isRouting, let t = audio.target {
                status = "Enviando audio a \(CA.name(t))"
            } else {
                status = "Inactivo: la salida actual ya tiene volumen propio"
            }
            menu.addItem(note(status))
        } else {
            menu.addItem(note("El driver de audio Mando no está instalado"))
        }

        menu.addItem(.separator())
        if let display {
            menu.addItem(header("Brillo · \(display.name)"))
            menu.addItem(sliderItem(brightnessSlider, symbol: "sun.max.fill"))
            if !MediaKeys.hasAccessibility {
                let item = NSMenuItem(title: "Permitir teclas de brillo (Accesibilidad)…", action: #selector(openAccessibility), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
        } else {
            menu.addItem(note("Brillo: ningún monitor externo responde por DDC"))
        }

        menu.addItem(.separator())
        let outputs = NSMenuItem(title: "Salida de audio", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let current = audio.isRouting ? audio.target : CA.defaultOutput
        for dev in audio.outputDevices() {
            let item = NSMenuItem(title: CA.name(dev), action: #selector(selectOutput(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(dev)
            item.state = (dev == current) ? .on : .off
            sub.addItem(item)
        }
        outputs.submenu = sub
        menu.addItem(outputs)

        let login = NSMenuItem(title: "Abrir al iniciar sesión", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Salir de Mando", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func selectOutput(_ sender: NSMenuItem) {
        audio.select(AudioObjectID(sender.tag))
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            Log.info("login item error \(error)")
        }
    }

    @objc private func openAccessibility() {
        MediaKeys.requestAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Menu item builders

    private func header(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        return item
    }

    private func note(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func sliderItem(_ slider: NSSlider, symbol: String) -> NSMenuItem {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        let stack = NSStackView(views: [icon, slider])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 18, bottom: 4, right: 18)
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 30)
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        let item = NSMenuItem()
        item.view = stack
        return item
    }
}
