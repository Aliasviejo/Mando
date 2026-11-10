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

    /// Steps per key press across the whole range, like macOS; ⇧⌥ gives quarter steps.
    private static let keySteps: Float = 16
    private static let fineSteps = keySteps * 4

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

        audio.onChange = { [weak self] in self?.refreshControls() }
        audio.start()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = DDCDisplay.findExternal()
            Log.info(found.map { "DDC display: \($0.name) id=\($0.displayID)" } ?? "DDC display: none")
            DispatchQueue.main.async {
                self?.display = found
                self?.refreshControls()
            }
        }
        Log.info("accessibility trusted: \(MediaKeys.hasAccessibility)")

        keys.handler = { [weak self] key, fine in
            if key.isBrightness { self?.handleBrightnessKey(key, fine: fine) } else { self?.handleVolumeKey(key, fine: fine) }
        }
        if MediaKeys.hasAccessibility {
            keys.start()
        } else {
            MediaKeys.requestAccessibility()
            pollForAccessibility()
        }

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displaysChanged),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        if DriverInstaller.needsInstall {
            DispatchQueue.main.async { [weak self] in self?.offerDriverInstall() }
        }
    }

    // MARK: Driver

    private func offerDriverInstall() {
        let update = DriverInstaller.isInstalled
        let alert = NSAlert()
        alert.messageText = update ? "Actualizar el driver de audio" : "Instalar el driver de audio"
        alert.informativeText = "Mando usa un dispositivo de audio virtual para que las teclas de volumen funcionen con tu monitor o TV. macOS te pedirá tu contraseña y el audio se cortará un momento."
        alert.addButton(withTitle: update ? "Actualizar" : "Instalar")
        alert.addButton(withTitle: "Ahora no")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        installDriver()
    }

    @objc private func installDriver() {
        audio.stop()
        guard DriverInstaller.install() else { audio.start(); return }
        relaunch()
    }

    /// CoreAudio restarts after a driver change; a fresh process picks up the new device cleanly.
    private func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
    }

    @objc private func uninstallMando() {
        let alert = NSAlert()
        alert.messageText = "¿Desinstalar Mando?"
        alert.informativeText = "Se quitarán el driver de audio y la app. macOS te pedirá tu contraseña."
        alert.addButton(withTitle: "Desinstalar")
        alert.addButton(withTitle: "Cancelar")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        audio.stop()
        guard DriverInstaller.uninstall() else { audio.start(); return }
        try? SMAppService.mainApp.unregister()
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
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

    /// After a wake or a display change, give the display a moment, then find
    /// it again for DDC and let the audio route catch up.
    @objc private func displaysChanged() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            let found = DDCDisplay.findExternal()
            DispatchQueue.main.async {
                self?.display = found
                self?.audio.evaluate() // ends in refreshControls()
            }
        }
    }

    // MARK: Brightness

    private func handleBrightnessKey(_ key: MediaKeys.Key, fine: Bool) {
        guard let display else { return }
        let value = Self.step(display.normalizedBrightness, up: key == .brightnessUp, fine: fine)
        display.setBrightness(normalized: value)
        _ = MandoShowOSD(display.displayID, 1, UInt32((value * Self.fineSteps).rounded()), UInt32(Self.fineSteps))
        brightnessSlider.floatValue = value
    }

    private static func step(_ value: Float, up: Bool, fine: Bool) -> Float {
        let steps = fine ? fineSteps : keySteps
        return max(0, min(1, ((value * steps).rounded() + (up ? 1 : -1)) / steps))
    }

    @objc private func brightnessSliderMoved() {
        display?.setBrightness(normalized: brightnessSlider.floatValue)
    }

    // MARK: Volume

    @objc private func volumeSliderMoved() {
        audio.volume = volumeSlider.floatValue
    }

    private func handleVolumeKey(_ key: MediaKeys.Key, fine: Bool) {
        guard audio.isActiveOutput else { return }
        var value = audio.volume
        if key == .mute {
            audio.muted.toggle()
        } else {
            value = Self.step(value, up: key == .volumeUp, fine: fine)
            audio.volume = value
            if audio.muted { audio.muted = false }
        }
        let muted = audio.muted || value == 0
        _ = MandoShowOSD(osdDisplayID, muted ? 4 : 3, muted ? 0 : UInt32((value * Self.fineSteps).rounded()), UInt32(Self.fineSteps))
        volumeSlider.floatValue = value
    }

    /// Display the mouse is on, so the bezel shows where you're looking.
    private var osdDisplayID: CGDirectDisplayID {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        return (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    /// Sliders, and which keys Mando takes: brightness with a DDC display,
    /// volume only while Mando is the output (otherwise macOS handles them).
    private func refreshControls() {
        volumeSlider.floatValue = audio.volume
        if let display { brightnessSlider.floatValue = display.normalizedBrightness }
        keys.take(brightness: display != nil, volume: audio.isActiveOutput)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        refreshControls()

        if audio.driverInstalled {
            menu.addItem(header("Volumen"))
            menu.addItem(sliderItem(volumeSlider, symbol: "speaker.wave.2.fill"))
            let status: String
            if let t = audio.target {
                status = "Enviando audio a \(CA.name(t))"
            } else if audio.isAwaitingTarget {
                status = "En espera: volverá al monitor cuando se encienda"
            } else {
                status = "Inactivo: la salida actual ya tiene volumen propio"
            }
            menu.addItem(note(status))
        } else {
            menu.addItem(note("Falta el driver de audio de Mando"))
            if DriverInstaller.bundledURL != nil {
                let item = NSMenuItem(title: "Instalar driver de audio…", action: #selector(installDriver), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
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
        let current = audio.target ?? CA.defaultOutput
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
        let uninstall = NSMenuItem(title: "Desinstalar Mando…", action: #selector(uninstallMando), keyEquivalent: "")
        uninstall.target = self
        menu.addItem(uninstall)
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
