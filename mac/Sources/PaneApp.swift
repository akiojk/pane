import AppKit
import SwiftUI

@main
struct PaneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        if CommandLine.arguments.contains("--self-test") {
            let code = SelfTest.run()
            exit(Int32(code))
        }
    }

    var body: some Scene {
        Window("Pane", id: "main") {
            ContentView()
                .environmentObject(AppModel.shared)
        }
        .defaultSize(width: 480, height: 640)
        .windowResizability(.contentMinSize)

        MenuBarExtra("Pane", systemImage: "rectangle.on.rectangle") {
            MenuContent()
                .environmentObject(AppModel.shared)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = AppIcon.image()
        AppModel.shared.bootstrap()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }
}

enum AppIcon {
    static func image() -> NSImage {
        let side: CGFloat = 1024
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.15, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: side, height: side), xRadius: 220, yRadius: 220).fill()

        let back = NSBezierPath(roundedRect: NSRect(x: 150, y: 250, width: 620, height: 420), xRadius: 48, yRadius: 48)
        NSColor(calibratedWhite: 0.92, alpha: 1).setFill()
        back.fill()

        let front = NSBezierPath(roundedRect: NSRect(x: 280, y: 150, width: 560, height: 360), xRadius: 36, yRadius: 36)
        NSColor(calibratedRed: 0.77, green: 0.65, blue: 0.45, alpha: 1).setFill()
        front.fill()
        image.unlockFocus()
        return image
    }
}
