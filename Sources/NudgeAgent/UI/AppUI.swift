import AppKit
import SwiftUI
import Combine

/// Entry point of the UI module: menu bar item, menu, windows, hotkeys and nudges.
///
/// Usage (main.swift):
///     let ui = AppUI(state: state, controller: coordinator)
///     coordinator.presenter = ui.presenter
///     ui.onSettingsChanged = { coordinator.reloadSettings($0) }
///     ui.start()   // in applicationDidFinishLaunching
final class AppUI: NSObject, NSMenuDelegate {
    let state: SessionState
    let controller: SessionControlling
    /// Hand this to the engine. It is the NudgeUI instance.
    let presenter: NudgePresenting
    /// Called after the user saves Settings.
    var onSettingsChanged: ((AppSettings) -> Void)?

    private let nudgeUI: NudgeUI
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var cancellables = Set<AnyCancellable>()
    private var clockTimer: Timer?
    private let hotKeys = UIHotKeys()
    private var hotKeysRegistered = (parking: false, progress: false)
    private let parkingLot = UIParkingLotPanel()
    private var toastPanel: UIFloatingPanel?
    private var toastTimer: Timer?

    private lazy var goalModel = UIGoalModel(controller: controller)
    private lazy var settingsModel = UISettingsModel()
    private let welcomePermissions = UIPermissionModel()

    private var goalWindow: UIHostedWindowController?
    private var settingsWindow: UIHostedWindowController?
    private var debugWindow: UIHostedWindowController?
    private var recapWindow: UIHostedWindowController?
    private var welcomeWindow: UIHostedWindowController?

    private static let welcomeDoneKey = "NudgeAgent.welcomeDone"

    init(state: SessionState, controller: SessionControlling) {
        self.state = state
        self.controller = controller
        let nudge = NudgeUI(state: state, controller: controller)
        self.nudgeUI = nudge
        self.presenter = nudge
        super.init()
    }

    /// Call once from applicationDidFinishLaunching.
    func start() {
        setUpStatusItem()
        nudgeUI.start()
        registerHotKeys()

        parkingLot.onSubmit = { [weak self] text in
            guard let self else { return }
            self.controller.addParkingLot(text)
            self.toast(symbol: "tray.and.arrow.down.fill", "Parked. Back to it.")
        }

        // objectWillChange fires before the value changes; debounce so we read the new values.
        state.objectWillChange
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStatusItem() }
            .store(in: &cancellables)
        // Keep the "minutes left" title fresh.
        clockTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.refreshStatusItem()
        }
        refreshStatusItem()

        if needsWelcome { showWelcome() }
    }

    private var needsWelcome: Bool {
        !UserDefaults.standard.bool(forKey: Self.welcomeDoneKey)
            || KeychainStore.loadAPIKey() == nil
            || !Permissions.accessibilityGranted()
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.imagePosition = .imageLeading
        statusItem = item
    }

    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        let status = state.status
        let spec = iconSpec(for: status)
        var config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        if let color = spec.color {
            config = config.applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        }
        let image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: UIFormat.statusName(status))?
            .withSymbolConfiguration(config)
        image?.isTemplate = spec.color == nil
        button.image = image

        let title = shortTitle()
        button.attributedTitle = NSAttributedString(
            string: title.isEmpty ? "" : " " + title,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])

        var tip = "NudgeAgent: \(UIFormat.statusName(status))"
        if let goal = state.profile?.goal, status != .idle { tip += "\n" + UIFormat.truncate(goal, 80) }
        button.toolTip = tip
    }

    private func iconSpec(for status: FocusStatus) -> (symbol: String, color: NSColor?) {
        switch status {
        case .idle: return ("circle.dashed", nil)
        case .anchored: return ("scope", .systemGreen)
        case .excursion:
            // Yellow when the classifier is unsure about this trip, blue otherwise.
            let unsure = state.currentClassification?.label == .unsure
            return ("arrow.triangle.branch", unsure ? .systemYellow : .systemBlue)
        case .drifting: return ("exclamationmark.circle.fill", .systemOrange)
        case .paused: return ("pause.circle", nil)
        case .onBreak: return ("cup.and.saucer", nil)
        }
    }

    /// "3/20" for count goals, otherwise time left to the deadline.
    private func shortTitle() -> String {
        guard state.status != .idle, let profile = state.profile else { return "" }
        if state.status == .onBreak || state.status == .paused, let until = state.pausedUntil {
            return UIFormat.compactMinutes(until.timeIntervalSinceNow)
        }
        if let target = profile.targetCount {
            return "\(state.progressCount)/\(target)"
        }
        if let deadline = profile.deadline {
            let left = deadline.timeIntervalSinceNow
            return left > 0 ? UIFormat.compactMinutes(left) : "0m"
        }
        return ""
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = state.status
        let active = status != .idle
        let paused = status == .paused || status == .onBreak

        if active, let profile = state.profile {
            menu.addItem(infoItem(UIFormat.truncate(profile.goal, 52), bold: true))
            menu.addItem(infoItem(statusLine()))
            if let ctx = state.current {
                menu.addItem(infoItem("Now: " + UIFormat.truncate(ctx.shortDescription, 56)))
                if let c = state.currentClassification {
                    menu.addItem(infoItem("\(UIFormat.labelName(c.label)): " + UIFormat.truncate(c.reason, 56)))
                }
            }
        } else {
            menu.addItem(infoItem("No goal yet", bold: true))
            menu.addItem(infoItem("Set one and I'll help you stay with it."))
        }
        menu.addItem(.separator())

        menu.addItem(UIActionMenuItem("New goal\u{2026}", key: "n", symbol: "plus.circle") { [weak self] in
            self?.showGoalWindow()
        })
        if active, (status == .excursion || status == .drifting), let anchor = state.anchorName {
            menu.addItem(UIActionMenuItem("Back to \(UIFormat.truncate(anchor, 36))", symbol: "arrow.uturn.backward") { [weak self] in
                self?.controller.backToWork()
            })
        }
        menu.addItem(UIActionMenuItem("End session", enabled: active, symbol: "flag.checkered") { [weak self] in
            self?.endSession()
        })
        menu.addItem(.separator())

        menu.addItem(submenu("Take a break", symbol: "cup.and.saucer", enabled: active && status != .onBreak,
                             minutes: [5, 10, 15, 30]) { [weak self] m in self?.controller.takeBreak(minutes: m) })
        menu.addItem(submenu("Working offline", symbol: "doc.text", enabled: active && !paused,
                             minutes: [15, 30, 60]) { [weak self] m in self?.controller.workOffline(minutes: m) })
        menu.addItem(UIActionMenuItem("Resume", enabled: paused, symbol: "play.circle") { [weak self] in
            self?.controller.resume()
        })
        menu.addItem(.separator())

        let canJudge = active && !paused && state.current != nil
        menu.addItem(UIActionMenuItem("This is relevant", enabled: canJudge, symbol: "hand.thumbsup") { [weak self] in
            self?.controller.markCurrentRelevant()
        })
        menu.addItem(UIActionMenuItem("This is off task", enabled: canJudge, symbol: "hand.thumbsdown") { [weak self] in
            self?.controller.markCurrentOffTask()
        })
        menu.addItem(UIActionMenuItem("Progress +1", key: "=", modifiers: [.control, .option], enabled: active,
                                      symbol: "plus.square") { [weak self] in
            self?.incrementProgress()
        })
        menu.addItem(UIActionMenuItem("Parking lot\u{2026}", key: "p", modifiers: [.control, .option],
                                      symbol: "tray.and.arrow.down") { [weak self] in
            self?.showParkingLot()
        })
        menu.addItem(.separator())

        menu.addItem(UIActionMenuItem("Debug window", key: "d", modifiers: [.command, .option], symbol: "ladybug") { [weak self] in
            self?.showDebug()
        })
        menu.addItem(UIActionMenuItem("Settings\u{2026}", key: ",", symbol: "gearshape") { [weak self] in
            self?.showSettings()
        })
        menu.addItem(.separator())
        menu.addItem(UIActionMenuItem("Quit NudgeAgent", key: "q") {
            NSApp.terminate(nil)
        })
    }

    private func statusLine() -> String {
        switch state.status {
        case .onBreak:
            if let until = state.pausedUntil { return "On a break until \(UIFormat.clock(until))" }
            return "On a break"
        case .paused:
            let reason = state.pauseReason.map { "Paused (\($0))" } ?? "Paused"
            if let until = state.pausedUntil { return "\(reason) until \(UIFormat.clock(until))" }
            return reason
        default:
            var parts = ["Focused \(UIFormat.duration(state.focusedSeconds))"]
            if state.driftCount > 0 { parts.append("drifted \(state.driftCount)x") }
            if let target = state.profile?.targetCount {
                let unit = state.profile?.targetUnit.map { " " + $0 } ?? ""
                parts.append("\(state.progressCount)/\(target)\(unit)")
            }
            return parts.joined(separator: ", ")
        }
    }

    private func infoItem(_ text: String, bold: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        let font = bold ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 12)
        let color: NSColor = bold ? .labelColor : .secondaryLabelColor
        item.attributedTitle = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        return item
    }

    private func submenu(_ title: String, symbol: String, enabled: Bool, minutes: [Int],
                         action: @escaping (Int) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.isEnabled = enabled
        let sub = NSMenu(title: title)
        sub.autoenablesItems = false
        for m in minutes {
            sub.addItem(UIActionMenuItem("\(m) min", enabled: enabled) { action(m) })
        }
        item.submenu = sub
        return item
    }

    // MARK: - Hotkeys

    private func registerHotKeys() {
        hotKeysRegistered.parking = hotKeys.register(keyCode: UIHotKeys.keyP, modifiers: UIHotKeys.controlOption) { [weak self] in
            self?.showParkingLot()
        }
        hotKeysRegistered.progress = hotKeys.register(keyCode: UIHotKeys.keyEqual, modifiers: UIHotKeys.controlOption) { [weak self] in
            self?.incrementProgress()
        }
        if !hotKeysRegistered.parking || !hotKeysRegistered.progress {
            NSLog("NudgeAgent: a global hotkey is already taken by another app (parking: %d, progress: %d)",
                  hotKeysRegistered.parking ? 1 : 0, hotKeysRegistered.progress ? 1 : 0)
        }
    }

    // MARK: - Actions

    func showParkingLot() {
        parkingLot.toggle()
    }

    func incrementProgress() {
        guard state.status != .idle else {
            toast(symbol: "info.circle", "Start a session to count progress")
            return
        }
        controller.incrementProgress(by: 1)
        // Read the new count on the next run loop turn, after the engine updated the state.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let count = self.state.progressCount
            if let target = self.state.profile?.targetCount {
                self.toast(symbol: "plus.circle.fill", "+1, \(count) of \(target)")
            } else {
                self.toast(symbol: "plus.circle.fill", "+1, \(count) so far")
            }
        }
    }

    func endSession() {
        nudgeUI.dismissAll()
        if let recap = controller.endSession() ?? state.lastRecap {
            showRecap(recap)
        }
    }

    private func toast(symbol: String, _ text: String) {
        toastTimer?.invalidate()
        toastPanel?.orderOut(nil)
        let panel = UIFloatingPanel(allowsKey: false)
        panel.ignoresMouseEvents = true
        panel.setSwiftUIContent(UIToastView(symbol: symbol, text: text))
        panel.place(.topRight)
        panel.showGently()
        toastPanel = panel
        toastTimer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: false) { [weak self] _ in
            self?.toastPanel?.orderOut(nil)
            self?.toastPanel = nil
        }
    }

    // MARK: - Windows

    func showGoalWindow() {
        goalModel.prepareForShow(sessionRunning: state.status != .idle)
        if goalWindow == nil {
            goalModel.onStarted = { [weak self] in self?.goalWindow?.close() }
            goalWindow = UIHostedWindowController(title: "New goal", size: NSSize(width: 640, height: 600),
                                                  content: GoalSetupView(model: goalModel))
        }
        goalWindow?.present()
    }

    func showSettings() {
        settingsModel.reload()
        settingsModel.onSave = { [weak self] s in self?.onSettingsChanged?(s) }
        if settingsWindow == nil {
            settingsWindow = UIHostedWindowController(title: "NudgeAgent Settings", size: NSSize(width: 580, height: 720),
                                                      autosaveName: "NudgeAgent.settingsWindow",
                                                      content: SettingsView(model: settingsModel))
        }
        settingsWindow?.present()
    }

    func showDebug() {
        if debugWindow == nil {
            debugWindow = UIHostedWindowController(title: "NudgeAgent Debug", size: NSSize(width: 1100, height: 680),
                                                   autosaveName: "NudgeAgent.debugWindow",
                                                   content: DebugView(state: state))
        }
        debugWindow?.present()
    }

    func showRecap(_ recap: SessionRecap) {
        recapWindow?.close()
        let view = RecapView(recap: recap,
                             onNewGoal: { [weak self] in
                                 self?.recapWindow?.close()
                                 self?.showGoalWindow()
                             },
                             onDone: { [weak self] in self?.recapWindow?.close() })
        recapWindow = UIHostedWindowController(title: "Session recap", size: NSSize(width: 540, height: 480),
                                               resizable: false, content: view)
        recapWindow?.present()
    }

    func showWelcome() {
        if welcomeWindow == nil {
            let view = WelcomeView(permissions: welcomePermissions) { [weak self] in
                guard let self else { return }
                UserDefaults.standard.set(true, forKey: Self.welcomeDoneKey)
                self.welcomeWindow?.close()
                self.showGoalWindow()
            }
            welcomeWindow = UIHostedWindowController(title: "Welcome to NudgeAgent", size: NSSize(width: 560, height: 600),
                                                     resizable: false, content: view)
        }
        welcomePermissions.refresh()
        welcomeWindow?.present()
    }
}
