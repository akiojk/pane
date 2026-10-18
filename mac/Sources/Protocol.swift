import Foundation

enum PaneMessageType: UInt8 {
    case hello = 1
    case helloAck = 2
    case video = 3
    case pointer = 4
    case scroll = 5
    case keyframeRequest = 6
    case goodbye = 7
    case cursorPosition = 8
    case cursorShape = 9
    case pinch = 10
    case audioFormat = 11
    case audio = 12
    /// Sent by the tablet only so its TCP acknowledges at once instead of after the 40 ms delayed-ACK timer.
    case ack = 13
}

struct HelloMessage: Equatable {
    var deviceName: String
    var screenWidth: Int
    var screenHeight: Int
    var refresh: Int
    var capabilities: UInt8
    /// Horizontal pixels per inch. Zero when the tablet did not send one.
    var density: Int

    var hasTouch: Bool { capabilities & 0x1 != 0 }
    var hasStylus: Bool { capabilities & 0x2 != 0 }
    var hasHover: Bool { capabilities & 0x4 != 0 }
}

/// Phase 0 move, 1 down, 2 up, 3 cancel, 4 right click at the point.
struct PointerMessage: Equatable {
    var phase: UInt8
    var tool: UInt8
    var pointerID: UInt16
    var x: Float
    var y: Float
    var pressure: Float
}

/// How a scroll message relates to the finger gesture, like a trackpad.
enum ScrollPhase: UInt8 {
    /// No gesture information. Sent by older tablet builds.
    case none = 0
    case began = 1
    case changed = 2
    /// The finger lifted. dx and dy are the fling velocity in display fractions per second.
    case ended = 3
    /// The gesture stopped without a fling.
    case cancelled = 4
}

/// A two-finger pinch. `magnification` is the change since the last message, 0.05 meaning 5% larger.
/// `x` and `y` are the point between the fingers, normalized to the display.
struct PinchMessage: Equatable {
    var phase: ScrollPhase
    var magnification: Float
    var x: Float
    var y: Float
}

enum InboundMessage: Equatable {
    case hello(HelloMessage)
    case pointer(PointerMessage)
    case pinch(PinchMessage)
    /// dx and dy are fractions of the display, positive right and down, following the finger.
    case scroll(dx: Float, dy: Float, phase: ScrollPhase)
    case keyframeRequest
    case goodbye
}

struct ByteWriter {
    var data = Data()

    mutating func u8(_ value: UInt8) {
        data.append(value)
    }

    mutating func u16(_ value: UInt16) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    mutating func u32(_ value: UInt32) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    mutating func u64(_ value: UInt64) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    mutating func f32(_ value: Float) {
        u32(value.bitPattern)
    }

    mutating func bytes(_ value: Data) {
        data.append(value)
    }
}

struct ByteReader {
    let data: Data
    var offset = 0

    var remaining: Int { data.count - offset }

    mutating func u8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        let value = data[data.startIndex + offset]
        offset += 1
        return value
    }

    mutating func u16() -> UInt16? {
        load(UInt16.self)
    }

    mutating func u32() -> UInt32? {
        load(UInt32.self)
    }

    mutating func u64() -> UInt64? {
        load(UInt64.self)
    }

    private mutating func load<T: FixedWidthInteger>(_ type: T.Type) -> T? {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { return nil }
        let start = data.startIndex + offset
        let value = data.subdata(in: start..<(start + size)).withUnsafeBytes {
            T(littleEndian: $0.loadUnaligned(as: T.self))
        }
        offset += size
        return value
    }

    mutating func f32() -> Float? {
        guard let bits = u32() else { return nil }
        return Float(bitPattern: bits)
    }

    mutating func bytes(_ count: Int) -> Data? {
        guard count >= 0, remaining >= count else { return nil }
        let start = data.startIndex + offset
        let value = data.subdata(in: start..<(start + count))
        offset += count
        return value
    }
}

enum PaneCodec {
    static let h264: UInt8 = 1
    static let maxPayload = 8_000_000

    static func pack(type: PaneMessageType, payload: Data) -> Data {
        var writer = ByteWriter()
        writer.u32(UInt32(payload.count + 1))
        writer.u8(type.rawValue)
        writer.bytes(payload)
        return writer.data
    }

    static func helloAck(width: Int, height: Int, fps: Int) -> Data {
        var payload = ByteWriter()
        payload.u16(UInt16(clamping: width))
        payload.u16(UInt16(clamping: height))
        payload.u16(UInt16(clamping: fps))
        payload.u8(h264)
        return pack(type: .helloAck, payload: payload.data)
    }

    static func video(annexB: Data, keyframe: Bool, ptsMicros: UInt64) -> Data {
        var payload = ByteWriter()
        payload.u8(keyframe ? 1 : 0)
        payload.u64(ptsMicros)
        payload.bytes(annexB)
        return pack(type: .video, payload: payload.data)
    }

    /// Position is normalized to the virtual display. `visible` is false when the pointer is on another screen.
    static func cursorPosition(visible: Bool, x: Float, y: Float) -> Data {
        var payload = ByteWriter()
        payload.u8(visible ? 1 : 0)
        payload.f32(x)
        payload.f32(y)
        return pack(type: .cursorPosition, payload: payload.data)
    }

    /// Sent once when the audio connection opens.
    static func audioFormat(sampleRate: Int, channels: Int) -> Data {
        var payload = ByteWriter()
        payload.u32(UInt32(sampleRate))
        payload.u8(UInt8(channels))
        return pack(type: .audioFormat, payload: payload.data)
    }

    /// Signed 16-bit little-endian PCM, channels interleaved.
    static func audio(pcm: Data) -> Data {
        pack(type: .audio, payload: pcm)
    }

    /// Hotspot and size are fractions of the virtual display's width and height. The image is a PNG.
    static func cursorShape(hotX: Float, hotY: Float, width: Float, height: Float, png: Data) -> Data {
        var payload = ByteWriter()
        payload.f32(hotX)
        payload.f32(hotY)
        payload.f32(width)
        payload.f32(height)
        payload.bytes(png)
        return pack(type: .cursorShape, payload: payload.data)
    }

    static func parseBody(_ body: Data) -> InboundMessage? {
        guard let typeRaw = body.first, let type = PaneMessageType(rawValue: typeRaw) else {
            return nil
        }
        var reader = ByteReader(data: body)
        _ = reader.u8()
        switch type {
        case .hello:
            guard let nameCount = reader.u16(),
                  let nameData = reader.bytes(Int(nameCount)),
                  let width = reader.u16(),
                  let height = reader.u16(),
                  let refresh = reader.u16(),
                  let caps = reader.u8(),
                  let name = String(data: nameData, encoding: .utf8) else { return nil }
            let density = Int(reader.u16() ?? 0)
            return .hello(HelloMessage(
                deviceName: name,
                screenWidth: Int(width),
                screenHeight: Int(height),
                refresh: Int(refresh),
                capabilities: caps,
                density: density
            ))
        case .pointer:
            guard let phase = reader.u8(),
                  let tool = reader.u8(),
                  let pointerID = reader.u16(),
                  let x = reader.f32(),
                  let y = reader.f32(),
                  let pressure = reader.f32() else { return nil }
            return .pointer(PointerMessage(
                phase: phase, tool: tool, pointerID: pointerID, x: x, y: y, pressure: pressure
            ))
        case .scroll:
            guard let dx = reader.f32(), let dy = reader.f32() else { return nil }
            let phase = reader.u8().flatMap(ScrollPhase.init(rawValue:)) ?? ScrollPhase.none
            return .scroll(dx: dx, dy: dy, phase: phase)
        case .pinch:
            guard let rawPhase = reader.u8(), let phase = ScrollPhase(rawValue: rawPhase),
                  let magnification = reader.f32(), let x = reader.f32(), let y = reader.f32() else { return nil }
            return .pinch(PinchMessage(phase: phase, magnification: magnification, x: x, y: y))
        case .keyframeRequest:
            return .keyframeRequest
        case .goodbye:
            return .goodbye
        case .helloAck, .video, .cursorPosition, .cursorShape, .audioFormat, .audio, .ack:
            return nil
        }
    }
}

/// Reassembles length-prefixed messages from a TCP byte stream.
final class FrameParser {
    private var buffer = Data()
    private var start = 0

    func append(_ chunk: Data) -> [InboundMessage] {
        guard !chunk.isEmpty else { return [] }
        buffer.append(chunk)
        var messages: [InboundMessage] = []
        while buffer.count - start >= 4 {
            let length: UInt32 = buffer.withUnsafeBytes { raw in
                let base = raw.baseAddress!.advanced(by: start)
                return UInt32(littleEndian: base.loadUnaligned(as: UInt32.self))
            }
            if length == 0 || length > PaneCodec.maxPayload {
                buffer.removeAll()
                start = 0
                break
            }
            let total = 4 + Int(length)
            if buffer.count - start < total { break }
            let bodyStart = buffer.startIndex + start + 4
            let body = buffer.subdata(in: bodyStart..<(bodyStart + Int(length)))
            start += total
            if let message = PaneCodec.parseBody(body) {
                messages.append(message)
            }
        }
        if start > 64 * 1024 {
            buffer.removeSubrange(0..<start)
            start = 0
        }
        return messages
    }
}

private extension UInt16 {
    init(clamping value: Int) {
        let clamped = Swift.min(Int(UInt16.max), Swift.max(0, value))
        self = UInt16(clamped)
    }
}
