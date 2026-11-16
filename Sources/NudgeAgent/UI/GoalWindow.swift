import AppKit
import SwiftUI

/// State for the goal window: enter a goal, generate a profile, edit it, start.
final class UIGoalModel: ObservableObject {
    enum Step { case enter, loading, edit }

    @Published var step: Step = .enter
    @Published var goal = ""
    @Published var hasDeadline = false
    @Published var deadline = UIGoalModel.defaultDeadline()
    @Published var error: String?
    @Published var needsKey = KeychainStore.loadAPIKey() == nil
    @Published var sessionRunning = false

    // Editable profile
    @Published var type: TaskType = .create
    @Published var summary = ""
    @Published var outputs = ""
    @Published var sources = ""
    @Published var tools = ""
    @Published var drift = ""
    @Published var keywords = ""
    @Published var hasTarget = false
    @Published var targetCount = 10
    @Published var targetUnit = ""

    private let controller: SessionControlling
    private var task: Task<Void, Never>?
    /// Called after "Start focus" so the window can close.
    var onStarted: (() -> Void)?

    init(controller: SessionControlling) {
        self.controller = controller
    }

    static func defaultDeadline() -> Date {
        // Two hours from now, rounded to the next quarter hour.
        let target = Date().addingTimeInterval(2 * 3600)
        let quarter: TimeInterval = 15 * 60
        return Date(timeIntervalSinceReferenceDate: (target.timeIntervalSinceReferenceDate / quarter).rounded(.up) * quarter)
    }

    /// Fresh form when the window is reopened (unless a profile is being generated).
    func prepareForShow(sessionRunning: Bool) {
        self.sessionRunning = sessionRunning
        needsKey = KeychainStore.loadAPIKey() == nil
        guard step != .loading else { return }
        step = .enter
        goal = ""
        error = nil
        hasDeadline = false
        deadline = Self.defaultDeadline()
    }

    var canSetUp: Bool {
        !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func setUp() {
        let text = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, step != .loading else { return }
        if KeychainStore.loadAPIKey() == nil {
            needsKey = true
            error = "Add your API key above first, then try again."
            return
        }
        error = nil
        step = .loading
        let chosenDeadline = hasDeadline ? deadline : nil
        let controller = self.controller
        task = Task { @MainActor [weak self] in
            do {
                let profile = try await controller.generateProfile(goal: text, deadline: chosenDeadline)
                guard let self, !Task.isCancelled else { return }
                self.load(profile)
                self.step = .edit
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                self.step = .enter
            }
        }
    }

    func back() {
        task?.cancel()
        task = nil
        error = nil
        step = .enter
    }

    private func load(_ p: TaskProfile) {
        goal = p.goal.isEmpty ? goal : p.goal
        type = p.type
        summary = p.summary
        outputs = p.outputs.joined(separator: "\n")
        sources = p.sources.joined(separator: "\n")
        tools = p.tools.joined(separator: "\n")
        drift = p.drift.joined(separator: "\n")
        keywords = p.keywords.joined(separator: "\n")
        hasTarget = p.targetCount != nil
        targetCount = p.targetCount ?? 10
        targetUnit = p.targetUnit ?? ""
        if let d = p.deadline {
            hasDeadline = true
            deadline = d
        }
    }

    func makeProfile() -> TaskProfile {
        let unit = targetUnit.trimmingCharacters(in: .whitespaces)
        return TaskProfile(
            goal: goal.trimmingCharacters(in: .whitespacesAndNewlines),
            type: type,
            outputs: outputs.uiLines,
            sources: sources.uiLines,
            tools: tools.uiLines,
            drift: drift.uiLines,
            keywords: keywords.uiLines,
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            targetCount: hasTarget ? max(1, targetCount) : nil,
            targetUnit: hasTarget && !unit.isEmpty ? unit : nil,
            deadline: hasDeadline ? deadline : nil
        )
    }

    func startFocus() {
        if makeProfile().outputs.isEmpty {
            error = "Add at least one place where the work lands (Output), so I know where \"back\" is."
            return
        }
        error = nil
        controller.startSession(makeProfile())
        step = .enter
        onStarted?()
    }
}

struct GoalSetupView: View {
    @ObservedObject var model: UIGoalModel

    var body: some View {
        Group {
            switch model.step {
            case .enter: enterStep
            case .loading: loadingStep
            case .edit: editStep
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    // MARK: Step 1

    private var enterStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("What do you want to get done?")
                .font(.system(size: 24, weight: .semibold, design: .rounded))

            TextField("", text: $model.goal,
                      prompt: Text("Finish the pitch deck draft"),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .font(.title3)
                .lineLimit(2...5)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
                .onSubmit { model.setUp() }

            Text("One sentence is plenty. For example: \"Find 20 fintech leads and add them to Attio\", \"Clear my inbox before lunch\" or \"Read chapter 3 of the course\".")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            deadlineRow

            if model.needsKey {
                VStack(alignment: .leading, spacing: 6) {
                    Text("One more thing: your Anthropic API key").font(.headline)
                    Text("It stays in your Mac's Keychain.").font(.caption).foregroundStyle(.secondary)
                    UIAPIKeyView { model.needsKey = false; model.error = nil }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            }

            if model.sessionRunning {
                Label("This replaces your current goal.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let error = model.error { UIErrorTextView(message: error) }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button { model.setUp() } label: {
                    Text("Set up").frame(minWidth: 90)
                }
                .buttonStyle(.borderedProminent)
                .tint(UIPalette.calm)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSetUp)
            }
        }
        .padding(28)
    }

    private var deadlineRow: some View {
        HStack(spacing: 12) {
            Toggle("Deadline", isOn: $model.hasDeadline)
                .toggleStyle(.switch)
                .controlSize(.small)
            if model.hasDeadline {
                DatePicker("", selection: $model.deadline, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.compact)
            }
            Spacer()
        }
    }

    // MARK: Step 2

    private var loadingStep: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView().controlSize(.large)
            Text("Sketching what working on this looks like\u{2026}")
                .font(.title3)
            Text(model.goal)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Spacer()
            HStack {
                Button("Back") { model.back() }
                Spacer()
            }
        }
        .padding(28)
    }

    // MARK: Step 3

    private var editStep: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Here is the plan")
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                        Text("Change anything that looks off. Lists take one item per line.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    TextField("Goal", text: $model.goal, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.weight(.medium))
                        .lineLimit(1...3)

                    Picker("Kind of work", selection: $model.type) {
                        ForEach(TaskType.allCases, id: \.self) { t in
                            Text(UIFormat.taskTypeName(t)).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)

                    UIListEditorView(title: "What working looks like", hint: "One or two sentences",
                                     text: $model.summary, height: 48)

                    HStack(alignment: .top, spacing: 14) {
                        UIListEditorView(title: "Output", hint: "Where results land (app, site, file)",
                                         text: $model.outputs)
                        UIListEditorView(title: "Sources", hint: "Where input comes from",
                                         text: $model.sources)
                    }
                    HStack(alignment: .top, spacing: 14) {
                        UIListEditorView(title: "Tools", hint: "Helpers you use along the way",
                                         text: $model.tools)
                        UIListEditorView(title: "Easy places to drift", hint: "Where attention tends to wander",
                                         text: $model.drift)
                    }
                    UIListEditorView(title: "Keywords", hint: "Topics that make a page relevant",
                                     text: $model.keywords, height: 60)

                    HStack(spacing: 12) {
                        Toggle("Count progress", isOn: $model.hasTarget)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        if model.hasTarget {
                            TextField("", value: $model.targetCount, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                            Stepper("", value: $model.targetCount, in: 1...10_000).labelsHidden()
                            TextField("", text: $model.targetUnit, prompt: Text("leads, slides, emails"))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 200)
                        }
                        Spacer()
                    }

                    deadlineRow

                    if let error = model.error { UIErrorTextView(message: error) }
                }
                .padding(28)
            }

            Divider()
            HStack {
                Button("Back") { model.back() }
                Spacer()
                Button { model.startFocus() } label: {
                    Label("Start focus", systemImage: "scope").frame(minWidth: 110)
                }
                .buttonStyle(.borderedProminent)
                .tint(UIPalette.calm)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
        }
    }
}

/// Labeled multi-line editor for one-item-per-line lists.
struct UIListEditorView: View {
    let title: String
    let hint: String
    @Binding var text: String
    var height: CGFloat = 84

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(hint).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: height)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
