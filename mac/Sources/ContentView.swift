import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            statusBlock
            connectionBlock
            displayBlock
            if !model.screenRecordingGranted || !model.accessibilityGranted {
                permissionBlock
            }
            if let error = model.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 460, minHeight: 600)
        .onAppear { model.bootstrap() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Pane")
                .font(.largeTitle.weight(.semibold))
            Text("An Android tablet as a second Mac display")
                .foregroundStyle(.secondary)
        }
    }

    private var statusBlock: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(statusTitle)
                        .font(.headline)
                    Spacer()
                    if model.phase == .streaming {
                        Text(String(format: "%.0f fps  %.1f Mb/s", model.fps, model.megabits))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(model.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let name = model.clientName {
                    Text("\(name)\(model.clientDetail.isEmpty ? "" : " · \(model.clientDetail)")")
                        .font(.callout)
                }
                if !model.geometryLabel.isEmpty {
                    Text(model.geometryLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var connectionBlock: some View {
        GroupBox("Connection") {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.usbDetail)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Keep the USB cable plugged in and USB debugging on. Pane on the tablet connects through the cable.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.listenerDetail.isEmpty, model.listenerDetail != "ready" {
                    Text(model.listenerDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(audioText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var audioText: String {
        if !model.audioInstalled {
            return "Audio: the Pane output is not installed. Run mac/AudioDriver/install.sh."
        }
        if model.audioRouted {
            return "Audio: playing on the tablet. Pane is the Mac's sound output."
        }
        return "Audio: choose Pane in the Sound menu or System Settings › Sound to play sound on the tablet."
    }

    private var displayBlock: some View {
        GroupBox("Display") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Size", selection: $model.preset) {
                    ForEach(DisplayPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: model.preset) { _, _ in
                    model.applyDisplaySettings()
                }

                Picker("Refresh", selection: $model.refresh) {
                    Text("120 Hz").tag(120)
                    Text("60 Hz").tag(60)
                    Text("30 Hz").tag(30)
                }
                .pickerStyle(.segmented)
                .onChange(of: model.refresh) { _, _ in
                    model.applyDisplaySettings()
                }
                Text("macOS draws this display no faster than your fastest Mac screen. With a 60 Hz main display, 120 Hz still runs at 60.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Natural scrolling", isOn: Binding(
                    get: { model.naturalScroll },
                    set: { model.setNaturalScroll($0) }
                ))
                Text("On the tablet: tap to click, drag to scroll, press and hold then drag to move windows or select, two-finger tap to right-click, pinch to zoom. A stylus, when the tablet has one, works as a precise pointer. The Mac keyboard still types into whichever window you focus.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var permissionBlock: some View {
        GroupBox("Permissions") {
            VStack(alignment: .leading, spacing: 8) {
                if !model.screenRecordingGranted {
                    Text("Screen Recording lets Pane capture the virtual display.")
                        .font(.callout)
                    HStack {
                        Button("Allow Screen Recording") { model.requestScreenRecording() }
                        Button("Open Settings") { model.openScreenRecordingSettings() }
                    }
                }
                if !model.accessibilityGranted {
                    Text("Accessibility lets taps on the tablet click on the Mac.")
                        .font(.callout)
                    HStack {
                        Button("Allow Accessibility") { model.requestAccessibility() }
                        Button("Open Settings") { model.openAccessibilitySettings() }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusTitle: String {
        switch model.phase {
        case .starting: return "Starting"
        case .waiting: return "Waiting for the tablet"
        case .streaming: return "Streaming"
        case .stopped: return "Stopped"
        case .failed: return "Needs attention"
        }
    }

    private var statusColor: Color {
        switch model.phase {
        case .starting: return .gray
        case .waiting: return .orange
        case .streaming: return .green
        case .stopped: return .gray
        case .failed: return .red
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Show Pane") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Text(menuStatus)
        if model.phase == .streaming {
            Text(String(format: "%.0f fps", model.fps))
        }
        Divider()
        Button("Quit Pane") {
            model.shutdown()
            NSApp.terminate(nil)
        }
    }

    private var menuStatus: String {
        switch model.phase {
        case .streaming: return model.clientName ?? "Streaming"
        case .waiting: return "Waiting for tablet"
        case .failed: return "Needs attention"
        case .starting: return "Starting"
        case .stopped: return "Stopped"
        }
    }
}
