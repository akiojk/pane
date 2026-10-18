import AppKit
import CoreGraphics
import Foundation

enum SelfTest {
    static func run() -> Int32 {
        DispatchQueue.global().asyncAfter(deadline: .now() + 25) {
            fputs("self-test timed out\n", stderr)
            exit(2)
        }
        _ = NSApplication.shared
        var failures: [String] = []

        if !protocolRoundTrip() {
            failures.append("protocol round trip")
        }
        if !partialFrameParse() {
            failures.append("partial frame parse")
        }
        if !annexBConversion() {
            failures.append("annex-b conversion")
        }

        if !displaySpecChoices() {
            failures.append("display spec choices")
        }

        guard let spec = DisplayPreset.tabS9.spec(hello: nil, refreshCap: 60) else {
            failures.append("tab S9 spec")
            return finish(failures)
        }
        let display = DisplayArrangement.create(spec)
        guard let display else {
            failures.append("CGVirtualDisplay init returned nil")
            return finish(failures)
        }
        if display.displayID == 0 {
            failures.append("display id is 0")
        } else {
            print("created display \(display.displayID)")
            var geometry: DisplayArrangement.Geometry?
            for _ in 0..<15 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                geometry = DisplayArrangement.arrange(displayID: display.displayID, spec: spec)
                if geometry != nil { break }
            }
            if let geometry {
                print("selected \(geometry.pixelWidth)x\(geometry.pixelHeight) pixels, \(geometry.pointWidth)x\(geometry.pointHeight) points")
                if geometry.pixelWidth != 2560 || geometry.pixelHeight != 1600 || geometry.pointWidth != 1280 || geometry.pointHeight != 800 {
                    failures.append("expected 2560x1600 retina, got \(geometry)")
                }
            } else {
                failures.append("no display mode selected")
            }
        }
        return finish(failures)
    }

    private static func finish(_ failures: [String]) -> Int32 {
        if failures.isEmpty {
            print("self-test ok")
            return 0
        }
        for failure in failures {
            fputs("FAIL \(failure)\n", stderr)
        }
        return 1
    }

    private static func protocolRoundTrip() -> Bool {
        var payload = ByteWriter()
        let name = Data("Galaxy Tab S9".utf8)
        payload.u16(UInt16(name.count))
        payload.bytes(name)
        payload.u16(2560)
        payload.u16(1600)
        payload.u16(120)
        payload.u8(0x7)
        let packet = PaneCodec.pack(type: .hello, payload: payload.data)
        let parser = FrameParser()
        let messages = parser.append(packet)
        guard case .hello(let hello) = messages.first else { return false }
        return hello.deviceName == "Galaxy Tab S9"
            && hello.screenWidth == 2560
            && hello.screenHeight == 1600
            && hello.refresh == 120
            && hello.hasTouch && hello.hasStylus && hello.hasHover
            && hello.density == 0
    }

    private static func displaySpecChoices() -> Bool {
        let dense = HelloMessage(deviceName: "Tablet", screenWidth: 2560, screenHeight: 1600, refresh: 120, capabilities: 0x7, density: 276)
        let coarse = HelloMessage(deviceName: "Tablet", screenWidth: 1920, screenHeight: 1200, refresh: 60, capabilities: 0x1, density: 140)
        let phone = HelloMessage(deviceName: "Phone", screenWidth: 1080, screenHeight: 2400, refresh: 90, capabilities: 0x1, density: 400)
        guard let matched = DisplaySpec.matching(dense, refreshCap: 120),
              matched.hiDPI, matched.width == 2560, matched.height == 1600, matched.refresh == 120, matched.name == "Tablet" else { return false }
        guard let capped = DisplaySpec.matching(dense, refreshCap: 60), capped.refresh == 60 else { return false }
        guard let soft = DisplaySpec.matching(coarse, refreshCap: 120), !soft.hiDPI, soft.refresh == 60 else { return false }
        guard let handset = DisplaySpec.matching(phone, refreshCap: 120), !handset.hiDPI, handset.refresh == 90 else { return false }
        guard DisplayPreset.match.spec(hello: nil, refreshCap: 60) == nil else { return false }
        return true
    }

    private static func partialFrameParse() -> Bool {
        var payload = ByteWriter()
        payload.f32(0.25)
        payload.f32(-0.5)
        let packet = PaneCodec.pack(type: .scroll, payload: payload.data)
        let split = 3
        let parser = FrameParser()
        if !parser.append(packet.prefix(split)).isEmpty { return false }
        guard case .scroll(let dx, let dy, let phase) = parser.append(packet.suffix(from: split)).first else { return false }
        return abs(dx - 0.25) < 0.0001 && abs(dy + 0.5) < 0.0001 && phase == .none
    }

    private static func annexBConversion() -> Bool {
        var avcc = Data([0, 0, 0, 4, 0x65, 0x88, 0x84, 0x00])
        avcc.append(contentsOf: [0, 0, 0, 2, 0x41, 0x9A])
        let annex = AnnexB.avccToAnnexB(avcc, lengthSize: 4)
        let expected = Data([0, 0, 0, 1, 0x65, 0x88, 0x84, 0x00, 0, 0, 0, 1, 0x41, 0x9A])
        return annex == expected
    }
}
