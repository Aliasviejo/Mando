// Installs, updates and removes the audio driver that ships inside the app
// (Contents/PlugIns/Mando.driver), so nobody has to open Terminal.
// macOS shows its own password dialog for the admin step.
//
// SPDX-License-Identifier: MIT

import AppKit

enum DriverInstaller {
    static let installedURL = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/Mando.driver")
    static var bundledURL: URL? {
        let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("Mando.driver")
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    private static let binary = "Contents/MacOS/Mando"

    /// True when the driver is missing or differs from the one inside this app.
    static var needsInstall: Bool {
        guard let bundled = bundledURL, let mine = try? Data(contentsOf: bundled.appendingPathComponent(binary)) else {
            return false
        }
        return (try? Data(contentsOf: installedURL.appendingPathComponent(binary))) != mine
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: installedURL.path) }

    /// Copies the bundled driver into HAL and restarts CoreAudio. False if cancelled or failed.
    static func install() -> Bool {
        guard let bundled = bundledURL else { return false }
        let dst = quoted(installedURL.path)
        return runAsAdmin("rm -rf \(dst) && ditto \(quoted(bundled.path)) \(dst) && chown -R root:wheel \(dst) && (killall -9 coreaudiod || true)",
                          prompt: "Mando necesita instalar su driver de audio.")
    }

    static func uninstall() -> Bool {
        runAsAdmin("rm -rf \(quoted(installedURL.path)) && (killall -9 coreaudiod || true)",
                   prompt: "Mando necesita quitar su driver de audio.")
    }

    private static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func runAsAdmin(_ command: String, prompt: String) -> Bool {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let source = "do shell script \"\(escape(command))\" with prompt \"\(escape(prompt))\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { Log.info("driver admin step failed: \(error)"); return false }
        return true
    }
}
