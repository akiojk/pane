import CoreGraphics
import Foundation

/// What the virtual display should be. A preset can build one, and so can a tablet hello.
struct DisplaySpec: Equatable {
    var name: String
    var width: Int
    var height: Int
    var hiDPI: Bool
    var refresh: Double

    /// About 110 PPI makes macOS keep the full framebuffer instead of substituting a smaller mode.
    var sizeInMillimeters: CGSize {
        let ppi = 110.0
        return CGSize(
            width: Double(width) / ppi * 25.4,
            height: Double(height) / ppi * 25.4
        )
    }

    /// Retina when the panel is sharp enough that half the pixels is still a usable desktop.
    /// `dpi` is the tablet's reported xdpi. Zero means the tablet did not send one, so the
    /// pixel size decides: a short side of 1600 or more is treated as a dense panel.
    static func wantsHiDPI(width: Int, height: Int, dpi: Int) -> Bool {
        guard width % 2 == 0, height % 2 == 0 else { return false }
        guard min(width, height) / 2 >= 700 else { return false }
        if dpi <= 0 { return min(width, height) >= 1600 }
        return dpi >= 180
    }

    /// A display that follows the tablet. Nil when the reported size cannot be a mode.
    static func matching(_ hello: HelloMessage, refreshCap: Int) -> DisplaySpec? {
        var width = hello.screenWidth
        var height = hello.screenHeight
        guard width >= 640, height >= 480, width <= 7680, height <= 7680 else { return nil }
        width &= ~1
        height &= ~1
        guard width >= 640, height >= 480 else { return nil }
        let cap = (24...240).contains(refreshCap) ? refreshCap : 60
        let refresh = (24...240).contains(hello.refresh) ? Double(min(cap, hello.refresh)) : Double(cap)
        let trimmed = hello.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Pane" : String(trimmed.prefix(64))
        return DisplaySpec(
            name: name,
            width: width,
            height: height,
            hiDPI: wantsHiDPI(width: width, height: height, dpi: hello.density),
            refresh: refresh
        )
    }
}

enum DisplayPreset: String, CaseIterable, Identifiable {
    case match
    case tabS9
    case tabS9Portrait
    case lighter

    var id: String { rawValue }

    var label: String {
        switch self {
        case .match: return "Match tablet"
        case .tabS9: return "Tab S9  2560×1600"
        case .tabS9Portrait: return "Tab S9 portrait"
        case .lighter: return "Lighter  1920×1200"
        }
    }

    /// Nil for Match tablet until a tablet has connected.
    func spec(hello: HelloMessage?, refreshCap: Int) -> DisplaySpec? {
        switch self {
        case .match:
            guard let hello else { return nil }
            return DisplaySpec.matching(hello, refreshCap: refreshCap)
        case .tabS9:
            return fixed(hello: hello, width: 2560, height: 1600, hiDPI: true, refreshCap: refreshCap, fallback: "Galaxy Tab S9")
        case .tabS9Portrait:
            return fixed(hello: hello, width: 1600, height: 2560, hiDPI: true, refreshCap: refreshCap, fallback: "Galaxy Tab S9")
        case .lighter:
            return fixed(hello: hello, width: 1920, height: 1200, hiDPI: false, refreshCap: refreshCap, fallback: "Pane")
        }
    }

    private func fixed(hello: HelloMessage?, width: Int, height: Int, hiDPI: Bool, refreshCap: Int, fallback: String) -> DisplaySpec {
        let trimmed = hello?.deviceName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cap = (24...240).contains(refreshCap) ? refreshCap : 60
        return DisplaySpec(
            name: trimmed.isEmpty ? fallback : String(trimmed.prefix(64)),
            width: width,
            height: height,
            hiDPI: hiDPI,
            refresh: Double(cap)
        )
    }
}

enum DisplayArrangement {
    static let vendorID: UInt32 = 0x504E
    static let productID: UInt32 = 0x5309
    static let serialNumber: UInt32 = 1

    struct Geometry: Equatable {
        var pixelWidth: Int
        var pixelHeight: Int
        var pointWidth: Int
        var pointHeight: Int
        /// What WindowServer actually selected, which can differ from the request.
        var refreshRate: Int
    }

    static func create(_ spec: DisplaySpec) -> PaneVirtualDisplay? {
        PaneVirtualDisplay(
            name: spec.name,
            width: UInt32(spec.width),
            height: UInt32(spec.height),
            refreshRate: spec.refresh,
            vendorID: vendorID,
            productID: productID,
            serialNumber: serialNumber,
            sizeInMillimeters: spec.sizeInMillimeters,
            hiDPI: spec.hiDPI
        )
    }

    /// Places the virtual display to the right of the main display and selects a retina mode when one exists.
    /// `CGDisplayCopyAllDisplayModes` returns nothing for these displays, so mode selection goes through
    /// the private WindowServer mode list.
    static func arrange(displayID: CGDirectDisplayID, spec: DisplaySpec) -> Geometry? {
        var geometry = PaneDisplayGeometry()
        let ok = PaneConfigureVirtualDisplay(
            displayID,
            UInt32(spec.width),
            UInt32(spec.height),
            spec.refresh,
            spec.hiDPI,
            &geometry
        )
        guard ok, geometry.pixelWidth > 0, geometry.pointWidth > 0 else { return nil }
        return Geometry(
            pixelWidth: Int(geometry.pixelWidth),
            pixelHeight: Int(geometry.pixelHeight),
            pointWidth: Int(geometry.pointWidth),
            pointHeight: Int(geometry.pointHeight),
            refreshRate: Int(geometry.refreshRate)
        )
    }
}
