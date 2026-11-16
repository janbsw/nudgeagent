import AppKit
import SwiftUI

// Shared building blocks for the UI module: floating panels, hosted windows,
// closure based menu items, formatting and small reusable SwiftUI views.

// MARK: - Floating panel

/// Borderless, non-activating panel that floats above other apps on every Space.
/// Used for nudge cards, questions, the parking lot and small toasts.
final class UIFloatingPanel: NSPanel {
    /// Only panels with text input (parking lot) should become key.
    var allowsKey = false
    /// Called when the user presses Esc while the panel is key.
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    convenience init(allowsKey: Bool) {
        self.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
                  styleMask: [.borderless, .nonactivatingPanel],
                  backing: .buffered,
                  defer: false)
        self.allowsKey = allowsKey
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }

    func setSwiftUIContent<V: View>(_ view: V) {
        let host = UIFirstMouseHostingView(rootView: AnyView(view))
        contentView = host
        let size = host.fittingSize
        setContentSize(NSSize(width: max(size.width, 100), height: max(size.height, 40)))
        invalidateShadow()
    }

    enum Placement { case topRight, center, upperCenter }

    func place(_ placement: Placement, margin: CGFloat = 16) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let vf = screen.visibleFrame
        let size = frame.size
        let origin: NSPoint
        switch placement {
        case .topRight:
            origin = NSPoint(x: vf.maxX - size.width - margin, y: vf.maxY - size.height - margin)
        case .center:
            origin = NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2 + vf.height * 0.08)
        case .upperCenter:
            origin = NSPoint(x: vf.midX - size.width / 2, y: vf.maxY - size.height - vf.height * 0.22)
        }
        setFrameOrigin(origin)
    }

    /// Show without activating the app, with a short fade in.
    func showGently() {
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            animator().alphaValue = 1
        }
    }
}

/// Hosting view that reacts to the first click even when its window is not key,
/// so buttons on nudge cards work with a single click.
final class UIFirstMouseHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Regular windows

/// Shows NudgeAgent in the Dock and Cmd+Tab while one of its regular windows is open,
/// and hides it again (menu bar only) when the last one closes. Nudge panels don't count.
enum UIDockPresence {
    private static var open = Set<ObjectIdentifier>()

    static func windowOpened(_ controller: NSWindowController) {
        open.insert(ObjectIdentifier(controller))
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    static func windowClosed(_ controller: NSWindowController) {
        open.remove(ObjectIdentifier(controller))
        guard open.isEmpty else { return }
        // Wait for the close to finish, then drop back to menu bar only.
        DispatchQueue.main.async {
            guard open.isEmpty, NSApp.activationPolicy() != .accessory else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// A titled window hosting SwiftUI content. Kept alive and reused by AppUI.
final class UIHostedWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init<V: View>(title: String, size: NSSize, resizable: Bool = true, autosaveName: String? = nil, content: V) {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: style, backing: .buffered, defer: false)
        window.title = title
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = resizable ? [.minSize] : [.preferredContentSize]
        window.contentViewController = hosting
        if resizable { window.setContentSize(size) }
        window.isReleasedWhenClosed = false
        window.center()
        if let autosaveName { window.setFrameAutosaveName(autosaveName) }
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func setContent<V: View>(_ content: V) {
        (window?.contentViewController as? NSHostingController<V>)?.rootView = content
    }

    /// Show and bring to front. Menu bar apps must activate explicitly.
    func present() {
        UIDockPresence.windowOpened(self)
        showWindow(nil)
        // A menu bar app is never the active app, so the plain cooperative activate()
        // can leave the window behind others. Force it to the front.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        UIDockPresence.windowClosed(self)
        onClose?()
    }
}

// MARK: - Menu items with closures

final class UIActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command],
         enabled: Bool = true, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        keyEquivalentModifierMask = modifiers
        isEnabled = enabled
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}

// MARK: - Formatting

enum UIFormat {
    /// "42 min", "1 h 5 min", "under a minute".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((max(0, seconds) / 60).rounded())
        if seconds > 0 && minutes == 0 { return "under a minute" }
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    /// Compact form for the menu bar: "42m", "2h05".
    static func compactMinutes(_ seconds: TimeInterval) -> String {
        let minutes = Int((max(0, seconds) / 60).rounded(.up))
        if minutes < 60 { return "\(minutes)m" }
        return String(format: "%dh%02d", minutes / 60, minutes % 60)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }
    static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }

    static func truncate(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard flat.count > limit, limit > 1 else { return flat }
        return String(flat.prefix(limit - 1)) + "\u{2026}"
    }

    static func labelName(_ label: ActivityLabel) -> String {
        switch label {
        case .onTask: return "On task"
        case .supporting: return "Supporting"
        case .neutral: return "Neutral"
        case .offTask: return "Off task"
        case .unsure: return "Unsure"
        }
    }

    static func statusName(_ status: FocusStatus) -> String {
        switch status {
        case .idle: return "No session"
        case .anchored: return "Focused"
        case .excursion: return "Exploring"
        case .drifting: return "Drifting"
        case .paused: return "Paused"
        case .onBreak: return "On a break"
        }
    }

    static func taskTypeName(_ type: TaskType) -> String {
        switch type {
        case .create: return "Create"
        case .research: return "Research"
        case .process: return "Process"
        case .communicate: return "Communicate"
        case .learn: return "Learn"
        }
    }
}

enum UIPalette {
    static let calm = Color(nsColor: .systemTeal)

    static func color(for label: ActivityLabel) -> Color {
        switch label {
        case .onTask: return .green
        case .supporting: return .teal
        case .neutral: return .gray
        case .offTask: return .orange
        case .unsure: return .yellow
        }
    }

    static func color(for status: FocusStatus) -> Color {
        switch status {
        case .idle: return .gray
        case .anchored: return .green
        case .excursion: return .blue
        case .drifting: return .orange
        case .paused: return .gray
        case .onBreak: return .brown
        }
    }
}

// MARK: - Small SwiftUI pieces

/// Rounded material background used by every floating card.
struct UICardBackground: View {
    var cornerRadius: CGFloat = 16
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

struct UIBadgeView: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

struct UIErrorTextView: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.bubble")
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// SecureField that saves the Anthropic API key to the Keychain.
struct UIAPIKeyView: View {
    var onSaved: (() -> Void)? = nil
    @State private var key = ""
    @State private var hasKey = KeychainStore.loadAPIKey() != nil
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField(hasKey ? "Key saved. Paste a new one to replace it" : "Anthropic API key (sk-ant-...)",
                            text: $key)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Save", action: save)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            } else if hasKey {
                Label("Key saved in your Keychain", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }

    private func save() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if KeychainStore.saveAPIKey(trimmed) {
            key = ""
            hasKey = true
            message = "Saved to your Keychain."
            onSaved?()
        } else {
            message = "Could not save to the Keychain. Try again?"
        }
    }
}

/// Live permission status, refreshed by the views that show it.
final class UIPermissionModel: ObservableObject {
    @Published var accessibility = Permissions.accessibilityGranted()
    @Published var screenRecording = Permissions.screenRecordingGranted()

    func refresh() {
        let ax = Permissions.accessibilityGranted()
        let sr = Permissions.screenRecordingGranted()
        if ax != accessibility { accessibility = ax }
        if sr != screenRecording { screenRecording = sr }
    }

    static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct UIPermissionRowView: View {
    let title: String
    let explanation: String
    let granted: Bool
    let grant: () -> Void
    let paneAnchor: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(granted ? Color.green : Color.secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !granted {
                    HStack {
                        Button("Grant", action: grant)
                        Button("Open System Settings") { UIPermissionModel.openPrivacyPane(paneAnchor) }
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

extension String {
    /// Split a one-item-per-line text into trimmed, non-empty items.
    var uiLines: [String] {
        split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
