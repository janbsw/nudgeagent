import AppKit
import SwiftUI
import Combine
import UserNotifications

/// Presents nudges and one-tap questions. Implements the escalation ladder from DESIGN.md section 7.
final class NudgeUI: NSObject, NudgePresenting, UNUserNotificationCenterDelegate {
    private let state: SessionState
    private let controller: SessionControlling

    private var cardPanel: UIFloatingPanel?
    private var askPanel: UIFloatingPanel?
    private var askTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var notificationsAllowed = false

    private enum ID {
        static let categoryWithBack = "nudge.withBack"
        static let categoryNoBack = "nudge.noBack"
        static let back = "nudge.back"
        static let relevant = "nudge.relevant"
        static let snooze = "nudge.snooze"
        static let takeBreak = "nudge.break"
    }

    init(state: SessionState, controller: SessionControlling) {
        self.state = state
        self.controller = controller
        super.init()
    }

    /// UNUserNotificationCenter crashes in a bare binary without a bundle, so only use it inside an .app.
    var canUseNotifications: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Called by AppUI.start(). Sets the notification delegate, registers categories and asks for permission.
    func start() {
        state.$status
            .removeDuplicates()
            .sink { [weak self] status in self?.statusChanged(status) }
            .store(in: &cancellables)

        guard canUseNotifications else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        registerCategories(backTarget: nil)
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async { self?.notificationsAllowed = granted }
        }
        center.getNotificationSettings { [weak self] settings in
            let ok = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            DispatchQueue.main.async { if ok { self?.notificationsAllowed = true } }
        }
    }

    // MARK: NudgePresenting

    func present(_ nudge: Nudge) {
        onMain { [self] in
            switch nudge.level {
            case .ambient:
                break // the menu bar icon reflects the state
            case .notification:
                if canUseNotifications && notificationsAllowed {
                    postNotification(nudge)
                } else {
                    showCard(nudge, strong: false)
                }
            case .card:
                showCard(nudge, strong: false)
            case .strong:
                showCard(nudge, strong: true)
                NSSound(named: "Glass")?.play()
            }
        }
    }

    func ask(_ question: String) {
        onMain { [self] in
            closeAsk()
            let panel = UIFloatingPanel(allowsKey: false)
            panel.setSwiftUIContent(UIAskCardView(question: question) { [weak self] answer in
                guard let self else { return }
                self.closeAsk()
                if let answer { self.controller.answerQuestion(isRelevant: answer) }
            })
            // Sit below an open nudge card if there is one.
            panel.place(.topRight)
            if let card = cardPanel, card.isVisible {
                panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: card.frame.minY - panel.frame.height - 10))
            }
            panel.showGently()
            askPanel = panel
            askTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
                self?.closeAsk()
            }
        }
    }

    func dismissAll() {
        onMain { [self] in
            closeCard()
            closeAsk()
            if canUseNotifications {
                UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            }
        }
    }

    // MARK: State

    private func statusChanged(_ status: FocusStatus) {
        switch status {
        case .anchored, .paused, .onBreak, .idle:
            dismissAll()
        case .excursion, .drifting:
            break
        }
    }

    // MARK: Cards

    private func showCard(_ nudge: Nudge, strong: Bool) {
        closeCard()
        let panel = UIFloatingPanel(allowsKey: false)
        panel.setSwiftUIContent(NudgeCardView(nudge: nudge, strong: strong) { [weak self] action in
            self?.handleCard(action)
        })
        panel.place(strong ? .center : .topRight)
        panel.showGently()
        cardPanel = panel
    }

    private func handleCard(_ action: UINudgeAction) {
        closeCard()
        switch action {
        case .back: controller.backToWork()
        case .relevant: controller.markCurrentRelevant()
        case .snooze: controller.snooze(minutes: 10)
        case .takeBreak: controller.takeBreak(minutes: 10)
        case .dismiss: break
        }
    }

    private func closeCard() {
        cardPanel?.orderOut(nil)
        cardPanel = nil
    }

    private func closeAsk() {
        askTimer?.invalidate()
        askTimer = nil
        askPanel?.orderOut(nil)
        askPanel = nil
    }

    // MARK: Notifications

    private func registerCategories(backTarget: String?) {
        let back = UNNotificationAction(identifier: ID.back, title: "Back to \(backTarget ?? "work")", options: [])
        let relevant = UNNotificationAction(identifier: ID.relevant, title: "This is relevant", options: [])
        let snooze = UNNotificationAction(identifier: ID.snooze, title: "Snooze 10 min", options: [])
        let takeBreak = UNNotificationAction(identifier: ID.takeBreak, title: "Take a 10 min break", options: [])
        let withBack = UNNotificationCategory(identifier: ID.categoryWithBack,
                                              actions: [back, relevant, snooze, takeBreak],
                                              intentIdentifiers: [], options: [])
        let noBack = UNNotificationCategory(identifier: ID.categoryNoBack,
                                            actions: [relevant, snooze, takeBreak],
                                            intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([withBack, noBack])
    }

    private func postNotification(_ nudge: Nudge) {
        let center = UNUserNotificationCenter.current()
        // Action titles are fixed per category, so re-register with the current target name.
        registerCategories(backTarget: nudge.backTargetName)
        // Keep only the latest nudge in Notification Center.
        center.removeAllDeliveredNotifications()

        let content = UNMutableNotificationContent()
        content.title = nudge.title
        content.body = nudge.message
        content.categoryIdentifier = nudge.backTargetName == nil ? ID.categoryNoBack : ID.categoryWithBack
        content.threadIdentifier = "nudge"
        content.userInfo = ["hasBackTarget": nudge.backTargetName != nil]

        let request = UNNotificationRequest(identifier: "nudge-\(UUID().uuidString)", content: content, trigger: nil)
        center.add(request) { [weak self] error in
            guard error != nil else { return }
            DispatchQueue.main.async { self?.showCard(nudge, strong: false) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let hasBack = (response.notification.request.content.userInfo["hasBackTarget"] as? Bool) ?? false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch action {
            case ID.back: self.controller.backToWork()
            case ID.relevant: self.controller.markCurrentRelevant()
            case ID.snooze: self.controller.snooze(minutes: 10)
            case ID.takeBreak: self.controller.takeBreak(minutes: 10)
            case UNNotificationDefaultActionIdentifier:
                // Clicking the banner itself means "ok, take me back".
                if hasBack { self.controller.backToWork() }
            default: break
            }
        }
        completionHandler()
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}

// MARK: - Card views

enum UINudgeAction { case back, relevant, snooze, takeBreak, dismiss }

struct NudgeCardView: View {
    let nudge: Nudge
    let strong: Bool
    let onAction: (UINudgeAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: strong ? 16 : 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "leaf.fill")
                    .font(strong ? .title : .title3)
                    .foregroundStyle(UIPalette.calm)
                    .frame(width: strong ? 36 : 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text(nudge.title)
                        .font(strong ? .title2.weight(.semibold) : .headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if !nudge.message.isEmpty {
                        Text(nudge.message)
                            .font(strong ? .body : .callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Button { onAction(.dismiss) } label: {
                    Image(systemName: "xmark").font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close")
            }

            if let target = nudge.backTargetName {
                Button { onAction(.back) } label: {
                    Label("Back to \(target)", systemImage: "arrow.uturn.backward")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(UIPalette.calm)
                .controlSize(.large)
            }

            HStack(spacing: 8) {
                Button("This is relevant") { onAction(.relevant) }
                Button("Snooze 10 min") { onAction(.snooze) }
                Button("Take a break") { onAction(.takeBreak) }
            }
            .buttonStyle(.bordered)
            .controlSize(strong ? .regular : .small)
            .frame(maxWidth: .infinity)
        }
        .padding(strong ? 24 : 16)
        .frame(width: strong ? 480 : 380)
        .background(UICardBackground(cornerRadius: strong ? 20 : 16))
    }
}

struct UIAskCardView: View {
    let question: String
    /// true = yes, false = no, nil = closed without answering.
    let onAnswer: (Bool?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.title3)
                    .foregroundStyle(UIPalette.calm)
                Text(question)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { onAnswer(nil) } label: {
                    Image(systemName: "xmark").font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button { onAnswer(true) } label: { Text("Yes").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .tint(UIPalette.calm)
                Button { onAnswer(false) } label: { Text("No").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(UICardBackground())
    }
}

/// Tiny confirmation bubble ("+1, 4 of 20").
struct UIToastView: View {
    let symbol: String
    let text: String
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(UICardBackground(cornerRadius: 12))
    }
}
