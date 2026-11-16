import AppKit
import SwiftUI
import Carbon

/// Global hotkeys via Carbon RegisterEventHotKey. Works without the Accessibility permission.
final class UIHotKeys {
    static let keyP: UInt32 = UInt32(kVK_ANSI_P)
    static let keyEqual: UInt32 = UInt32(kVK_ANSI_Equal)
    static let controlOption: UInt32 = UInt32(controlKey | optionKey)

    private var refs: [EventHotKeyRef] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1

    /// Returns false if the combination is taken by another app.
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4E55_4447), id: id) // "NUDG"
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs.append(ref)
        handlers[id] = handler
        return true
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard err == noErr else { return err }
            let hotKeys = Unmanaged<UIHotKeys>.fromOpaque(userData).takeUnretainedValue()
            let id = hotKeyID.id
            DispatchQueue.main.async { hotKeys.fire(id) }
            return noErr
        }, 1, &spec, userData, &eventHandler)
    }

    deinit {
        unregisterAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}

// MARK: - Parking lot

/// Small floating text field for dumping a thought without leaving the current app.
final class UIParkingLotPanel {
    var onSubmit: ((String) -> Void)?
    private var panel: UIFloatingPanel?
    private var previousApp: NSRunningApplication?

    var isOpen: Bool { panel?.isVisible ?? false }

    func toggle() {
        if isOpen { close(restoreFocus: true) } else { show() }
    }

    func show() {
        if let panel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front

        let panel = UIFloatingPanel(allowsKey: true)
        panel.onCancel = { [weak self] in self?.close(restoreFocus: true) }
        panel.setSwiftUIContent(UIParkingLotView(
            onSubmit: { [weak self] text in
                self?.onSubmit?(text)
                self?.close(restoreFocus: true)
            },
            onCancel: { [weak self] in self?.close(restoreFocus: true) }
        ))
        panel.place(.upperCenter)
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func close(restoreFocus: Bool) {
        panel?.orderOut(nil)
        panel = nil
        // The panel is non-activating, so usually the previous app never lost focus.
        // If something activated us anyway, hand focus back.
        if restoreFocus, NSApp.isActive, let previousApp {
            previousApp.activate()
        }
        previousApp = nil
    }
}

struct UIParkingLotView: View {
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Park a thought", systemImage: "tray.and.arrow.down.fill")
                .font(.headline)
                .foregroundStyle(UIPalette.calm)
            TextField("", text: $text, prompt: Text("It will wait for you in the recap"))
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .focused($focused)
                .onSubmit(submit)
            Text("Enter to save, Esc to close")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 440)
        .background(UICardBackground())
        .onExitCommand(perform: onCancel)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { onCancel() } else { onSubmit(trimmed) }
    }
}
