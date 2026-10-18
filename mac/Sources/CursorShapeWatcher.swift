import AppKit

/// Watches the system cursor image so the tablet can draw the same shape (arrow, I-beam, hand, resize).
@MainActor
final class CursorShapeWatcher {
    var onChange: ((CursorRelay.CursorShape) -> Void)?

    private var timer: Timer?
    private var lastSignature: Int?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastSignature = nil
    }

    private func poll() {
        guard let cursor = NSCursor.currentSystem else { return }
        let image = cursor.image
        let size = image.size
        guard size.width >= 1, size.height >= 1, size.width <= 256, size.height <= 256 else { return }

        // The virtual display is Retina, so draw at 2x to match its pixels.
        let pixelsWide = Int((size.width * 2).rounded())
        let pixelsHigh = Int((size.height * 2).rounded())
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        guard let bytes = bitmap.bitmapData else { return }
        var hasher = Hasher()
        hasher.combine(bytes: UnsafeRawBufferPointer(start: bytes, count: bitmap.bytesPerRow * pixelsHigh))
        hasher.combine(cursor.hotSpot.x)
        hasher.combine(cursor.hotSpot.y)
        let signature = hasher.finalize()
        guard signature != lastSignature else { return }
        lastSignature = signature

        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        onChange?(CursorRelay.CursorShape(png: png, hotspot: cursor.hotSpot, size: size))
    }
}
