import AppKit
import SwiftUI

// MARK: - Recap

struct RecapView: View {
    let recap: SessionRecap
    var onNewGoal: () -> Void
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Session wrapped up")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text(recap.goal)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                tile("Focused", UIFormat.duration(recap.focusedSeconds), "scope", .green)
                tile("Wandered", UIFormat.duration(recap.driftSeconds), "arrow.triangle.branch", .orange)
                tile("Nudges needed", "\(recap.driftCount)", "leaf", UIPalette.calm)
                if let target = recap.targetCount {
                    tile("Progress", "\(recap.progressCount) / \(target)", "checkmark.circle", .blue)
                } else if recap.progressCount > 0 {
                    tile("Progress", "\(recap.progressCount)", "checkmark.circle", .blue)
                }
            }

            Text(encouragement)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            if !recap.topDrift.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Where attention wandered").font(.headline)
                    ForEach(recap.topDrift.prefix(5)) { item in
                        HStack {
                            Text(item.name).lineLimit(1)
                            Spacer()
                            Text(UIFormat.duration(item.seconds)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
            }

            if !recap.parkingLot.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Parked thoughts").font(.headline)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(recap.parkingLot.map { "- \($0)" }.joined(separator: "\n"),
                                                           forType: .string)
                        }
                        .controlSize(.small)
                    }
                    ForEach(Array(recap.parkingLot.enumerated()), id: \.offset) { _, text in
                        Label(text, systemImage: "tray")
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }
            }

            HStack {
                Text("Total \(UIFormat.duration(recap.duration))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Set a new goal", action: onNewGoal)
                Button("Done", action: onDone)
                    .buttonStyle(.borderedProminent)
                    .tint(UIPalette.calm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 540)
    }

    private var encouragement: String {
        let tracked = recap.focusedSeconds + recap.driftSeconds
        let ratio = tracked > 0 ? recap.focusedSeconds / tracked : 0
        if let target = recap.targetCount, recap.progressCount >= target {
            return "You hit your target. That is a real win."
        }
        if recap.driftCount == 0 && recap.focusedSeconds > 60 {
            return "Steady session. You stayed with it the whole way."
        }
        if ratio >= 0.75 {
            return "Most of this session went into the goal. Nice work."
        }
        if recap.progressCount > 0 {
            return "You moved it forward. Every step counts."
        }
        return "You showed up and worked on it. The next session starts fresh."
    }

    private func tile(_ title: String, _ value: String, _ symbol: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.08)))
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @ObservedObject var permissions: UIPermissionModel
    var onContinue: () -> Void
    @State private var hasKey = KeychainStore.loadAPIKey() != nil
    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "scope")
                    .font(.system(size: 34))
                    .foregroundStyle(UIPalette.calm)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hi, I'm NudgeAgent")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text("Tell me what you want to get done. I notice when your attention wanders and give you a friendly nudge back. No judgement, ever.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                Text("A few permissions").font(.headline)
                UIPermissionRowView(
                    title: "Accessibility",
                    explanation: "Lets me read window titles, so I know which document or page you are in.",
                    granted: permissions.accessibility,
                    grant: { _ = Permissions.accessibilityGranted(prompt: true) },
                    paneAnchor: "Privacy_Accessibility")
                UIPermissionRowView(
                    title: "Screen Recording (optional)",
                    explanation: "Used to check unclear windows. Screenshots are never stored.",
                    granted: permissions.screenRecording,
                    grant: { Permissions.requestScreenRecording() },
                    paneAnchor: "Privacy_ScreenCapture")
                infoRow("Notifications", "For gentle reminders. You can turn them off any time.", "bell")
                infoRow("Browser automation", "macOS asks once per browser so I can read the current tab's address.", "safari")
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))

            VStack(alignment: .leading, spacing: 6) {
                Text("Your Anthropic API key").font(.headline)
                Text("Stored in your Keychain. Everything else stays on your Mac; only short descriptions of the current window go to the AI model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                UIAPIKeyView { hasKey = true }
            }

            HStack {
                if !permissions.accessibility || !hasKey {
                    Text("You can finish this later in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onContinue) {
                    Label("Set my first goal", systemImage: "arrow.right").frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .tint(UIPalette.calm)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 560)
        .onReceive(ticker) { _ in
            permissions.refresh()
            hasKey = KeychainStore.loadAPIKey() != nil
        }
    }

    private func infoRow(_ title: String, _ text: String, _ symbol: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).font(.title3).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
