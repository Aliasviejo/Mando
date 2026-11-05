// DDC/CI brightness control for external displays on Apple Silicon.
// Protocol details follow the VESA MCCS spec and the approach documented by
// MonitorControl (MIT) and m1ddc.
//
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import IOKit

final class DDCDisplay {
    static let brightnessVCP: UInt8 = 0x10
    private static let chipAddress: UInt32 = 0x37
    private static let dataAddress: UInt8 = 0x51

    let service: IOAVService
    let name: String
    let displayID: CGDirectDisplayID
    private let queue = DispatchQueue(label: "mando.ddc")
    private var pendingBrightness: UInt16?
    private var writing = false

    private(set) var maxBrightness: UInt16 = 100
    private(set) var brightness: UInt16 = 50

    private init(service: IOAVService, name: String, displayID: CGDirectDisplayID) {
        self.service = service
        self.name = name
        self.displayID = displayID
    }

    private static let savedBrightnessKey = "brightness"

    /// First external display reachable over DDC. Many monitors (and Apple
    /// Silicon HDMI ports) accept DDC writes but return garbage on reads, so a
    /// failed read is not fatal: we fall back to the last value we set.
    static func findExternal() -> DDCDisplay? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        let displayID = externalDisplayID()
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            guard location == "External",
                  let svc = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
            let display = DDCDisplay(service: svc, name: displayName(displayID) ?? "Monitor", displayID: displayID)
            if let (current, maximum) = display.read(brightnessVCP), maximum > 0 {
                display.maxBrightness = maximum
                display.brightness = min(current, maximum)
            } else {
                let saved = UserDefaults.standard.object(forKey: savedBrightnessKey) as? Double ?? 0.5
                display.brightness = UInt16((saved * Double(display.maxBrightness)).rounded())
            }
            return display
        }
        return nil
    }

    var normalizedBrightness: Float { Float(brightness) / Float(maxBrightness) }

    /// Coalesces rapid changes (key repeat, slider drags) into the latest value.
    func setBrightness(normalized: Float) {
        let clamped = max(0, min(1, normalized))
        let value = UInt16((clamped * Float(maxBrightness)).rounded())
        brightness = value
        UserDefaults.standard.set(Double(clamped), forKey: Self.savedBrightnessKey)
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingBrightness = value
            guard !self.writing else { return }
            self.writing = true
            while let v = self.pendingBrightness {
                self.pendingBrightness = nil
                _ = self.write(Self.brightnessVCP, value: v)
            }
            self.writing = false
        }
    }

    // MARK: DDC transport

    private func write(_ vcp: UInt8, value: UInt16) -> Bool {
        var packet: [UInt8] = [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        packet[5] = checksum(UInt8(Self.chipAddress << 1) ^ Self.dataAddress, packet[0..<5])
        for _ in 0..<3 {
            usleep(10_000)
            if IOAVServiceWriteI2C(service, Self.chipAddress, UInt32(Self.dataAddress), &packet, UInt32(packet.count)) == 0 { return true }
        }
        return false
    }

    private func read(_ vcp: UInt8) -> (current: UInt16, max: UInt16)? {
        var packet: [UInt8] = [0x82, 0x01, vcp, 0]
        packet[3] = checksum(UInt8(Self.chipAddress << 1), packet[0..<3])
        var reply = [UInt8](repeating: 0, count: 11)
        for _ in 0..<4 {
            usleep(10_000)
            guard IOAVServiceWriteI2C(service, Self.chipAddress, UInt32(Self.dataAddress), &packet, UInt32(packet.count)) == 0 else { continue }
            usleep(50_000)
            guard IOAVServiceReadI2C(service, Self.chipAddress, 0, &reply, UInt32(reply.count)) == 0 else { continue }
            guard checksum(0x50, reply[0..<10]) == reply[10] else { continue }
            return (UInt16(reply[8]) << 8 | UInt16(reply[9]), UInt16(reply[6]) << 8 | UInt16(reply[7]))
        }
        return nil
    }

    private func checksum(_ seed: UInt8, _ bytes: ArraySlice<UInt8>) -> UInt8 {
        bytes.reduce(seed) { $0 ^ $1 }
    }

    // MARK: Display info

    private static func externalDisplayID() -> CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) == 0 } ?? CGMainDisplayID()
    }

    private static func displayName(_ id: CGDirectDisplayID) -> String? {
        NSScreenName(for: id)
    }
}

import AppKit

private func NSScreenName(for id: CGDirectDisplayID) -> String? {
    NSScreen.screens.first {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
    }?.localizedName
}
