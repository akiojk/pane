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
        if !displaySpecEdges() {
            failures.append("display spec edges")
        }
        if !pointerAndPinchParse() {
            failures.append("pointer and pinch parse")
        }
        if !parserRecoversAfterBadLength() {
            failures.append("parser recovers after a bad length")
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
        // Any name and size. The parser copies the fields; it does not know about a particular tablet.
        var payload = ByteWriter()
        let name = Data("Tablet".utf8)
        payload.u16(UInt16(name.count))
        payload.bytes(name)
        payload.u16(2222)
        payload.u16(1111)
        payload.u16(90)
        payload.u8(0x1)
        payload.u16(201)
        let packet = PaneCodec.pack(type: .hello, payload: payload.data)
        let parser = FrameParser()
        let messages = parser.append(packet)
        guard case .hello(let hello) = messages.first else { return false }
        return hello.deviceName == "Tablet"
            && hello.screenWidth == 2222
            && hello.screenHeight == 1111
            && hello.refresh == 90
            && hello.hasTouch && !hello.hasStylus && !hello.hasHover
            && hello.density == 201
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

    private static func displaySpecEdges() -> Bool {
        let odd = HelloMessage(deviceName: "  ", screenWidth: 2561, screenHeight: 1600, refresh: 120, capabilities: 1, density: 276)
        guard let trimmed = DisplaySpec.matching(odd, refreshCap: 120),
              trimmed.width == 2560, trimmed.height == 1600, trimmed.hiDPI, trimmed.name == "Pane" else { return false }
        if DisplaySpec.matching(HelloMessage(deviceName: "x", screenWidth: 100, screenHeight: 100, refresh: 60, capabilities: 1, density: 300), refreshCap: 60) != nil {
            return false
        }
        if DisplaySpec.matching(HelloMessage(deviceName: "x", screenWidth: 8000, screenHeight: 1600, refresh: 60, capabilities: 1, density: 300), refreshCap: 60) != nil {
            return false
        }
        let boundary = HelloMessage(deviceName: "Panel", screenWidth: 1400, screenHeight: 1400, refresh: 60, capabilities: 1, density: 180)
        guard let sharp = DisplaySpec.matching(boundary, refreshCap: 120), sharp.hiDPI, sharp.refresh == 60 else { return false }
        var softDpi = boundary
        softDpi.density = 179
        guard let dull = DisplaySpec.matching(softDpi, refreshCap: 120), !dull.hiDPI else { return false }
        let unknown = HelloMessage(deviceName: "Panel", screenWidth: 1920, screenHeight: 1200, refresh: 500, capabilities: 1, density: 0)
        guard let fallback = DisplaySpec.matching(unknown, refreshCap: 60), !fallback.hiDPI, fallback.refresh == 60 else { return false }
        return true
    }

    private static func pointerAndPinchParse() -> Bool {
        var pointer = ByteWriter()
        pointer.u8(1)
        pointer.u8(0)
        pointer.u16(7)
        pointer.f32(0.5)
        pointer.f32(0.25)
        pointer.f32(0.8)
        var pinch = ByteWriter()
        pinch.u8(ScrollPhase.changed.rawValue)
        pinch.f32(0.05)
        pinch.f32(0.4)
        pinch.f32(0.6)
        let packet = PaneCodec.pack(type: .pointer, payload: pointer.data) + PaneCodec.pack(type: .pinch, payload: pinch.data)
        let messages = FrameParser().append(packet)
        guard messages.count == 2,
              case .pointer(let point) = messages[0],
              case .pinch(let gesture) = messages[1] else { return false }
        return point.phase == 1 && point.pointerID == 7 && abs(point.x - 0.5) < 0.0001 && abs(point.pressure - 0.8) < 0.0001
            && gesture.phase == .changed && abs(gesture.magnification - 0.05) < 0.0001
    }

    private static func parserRecoversAfterBadLength() -> Bool {
        var bad = Data(count: 4)
        bad[0] = 0xFF
        bad[1] = 0xFF
        bad[2] = 0xFF
        bad[3] = 0x7F
        let parser = FrameParser()
        if !parser.append(bad).isEmpty { return false }
        var payload = ByteWriter()
        payload.u8(1)
        let next = parser.append(PaneCodec.pack(type: .keyframeRequest, payload: payload.data))
        return next.count == 1 && next[0] == .keyframeRequest
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
