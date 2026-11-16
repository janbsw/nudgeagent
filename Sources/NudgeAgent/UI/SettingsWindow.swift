import AppKit
import SwiftUI

final class UISettingsModel: ObservableObject {
    @Published var settings: AppSettings
    @Published var excludedText: String
    @Published var savedAt: Date?
    let permissions = UIPermissionModel()
    var onSave: ((AppSettings) -> Void)?

    init() {
        let s = AppSettings.load()
        settings = s
        excludedText = s.excludedBundleIDs.joined(separator: "\n")
    }

    func reload() {
        let s = AppSettings.load()
        settings = s
        excludedText = s.excludedBundleIDs.joined(separator: "\n")
        savedAt = nil
        permissions.refresh()
    }

    func save() {
        var s = settings
        s.excludedBundleIDs = excludedText.uiLines
        s.textModel = s.textModel.trimmingCharacters(in: .whitespaces)
        s.visionModel = s.visionModel.trimmingCharacters(in: .whitespaces)
        settings = s
        s.save()
        savedAt = Date()
        onSave?(s)
    }
}

struct SettingsView: View {
    @ObservedObject var model: UISettingsModel
    @ObservedObject var permissions: UIPermissionModel
    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    init(model: UISettingsModel) {
        self.model = model
        self.permissions = model.permissions
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("API key") {
                    UIAPIKeyView()
                }

                Section("Nudges") {
                    UISliderRowView(title: "Nudge after drifting for", value: $model.settings.driftThresholdMinutes,
                                    range: 1...15, step: 0.5, unit: "min")
                    UISliderRowView(title: "Within a window of", value: $model.settings.rollingWindowMinutes,
                                    range: 5...30, step: 1, unit: "min")
                    UISliderRowView(title: "Grace for every side trip", value: $model.settings.graceMinutes,
                                    range: 0...10, step: 0.5, unit: "min")
                    UISliderRowView(title: "Ask when unclear after", value: $model.settings.askAfterMinutes,
                                    range: 1...10, step: 0.5, unit: "min")
                    Toggle("Allow stronger nudges (bigger card and a sound)", isOn: $model.settings.strongNudges)
                }

                Section("Sensing") {
                    UISliderRowView(title: "Count as away after no input for", value: $model.settings.idleSeconds,
                                    range: 30...600, step: 15, unit: "s")
                    Toggle("Check unclear windows with a screenshot", isOn: $model.settings.screenshotsEnabled)
                    UISliderRowView(title: "Only after staying in a window for", value: $model.settings.screenshotDwellSeconds,
                                    range: 15...300, step: 5, unit: "s")
                        .disabled(!model.settings.screenshotsEnabled)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Never capture these apps")
                        Text("Bundle ids, one per line, e.g. com.apple.MobileSMS. Password managers, banking and messengers are always skipped.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        TextEditor(text: $model.excludedText)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 70)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
                    }
                }

                Section("Models") {
                    TextField("Text model", text: $model.settings.textModel)
                    TextField("Vision model", text: $model.settings.visionModel)
                }

                Section("Permissions") {
                    UIPermissionRowView(
                        title: "Accessibility",
                        explanation: "Lets NudgeAgent read window titles, so it knows which document or page you are in.",
                        granted: permissions.accessibility,
                        grant: { _ = Permissions.accessibilityGranted(prompt: true) },
                        paneAnchor: "Privacy_Accessibility")
                    UIPermissionRowView(
                        title: "Screen Recording",
                        explanation: "Used to check unclear windows. Screenshots are never stored.",
                        granted: permissions.screenRecording,
                        grant: { Permissions.requestScreenRecording() },
                        paneAnchor: "Privacy_ScreenCapture")
                    Text("After granting, macOS may ask you to restart NudgeAgent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let savedAt = model.savedAt {
                    Label("Saved at \(UIFormat.clock(savedAt))", systemImage: "checkmark")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Save") { model.save() }
                    .buttonStyle(.borderedProminent)
                    .tint(UIPalette.calm)
                    .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 520, minHeight: 520)
        .onReceive(ticker) { _ in permissions.refresh() }
        .onAppear { permissions.refresh() }
    }
}

struct UISliderRowView: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Slider(value: $value, in: range, step: step)
                .frame(width: 170)
            Text(formatted)
                .monospacedDigit()
                .frame(width: 60, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }

    private var formatted: String {
        let number = value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
        return "\(number) \(unit)"
    }
}
