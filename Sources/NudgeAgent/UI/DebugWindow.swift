import AppKit
import SwiftUI

/// Live view of what the sensors see and how the classifier labels it. Used to check data quality.
struct DebugView: View {
    @ObservedObject var state: SessionState
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(16)
            Divider()
            Picker("", selection: $tab) {
                Text("Classifications (\(state.log.count))").tag(0)
                Text("Sensor stream (\(state.sensorLog.count))").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if tab == 0 { classificationTable } else { sensorTable }
        }
        .frame(minWidth: 900, minHeight: 520)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    key("Goal")
                    Text(state.profile?.goal ?? "No session").lineLimit(2)
                }
                GridRow {
                    key("Context")
                    Text(state.current?.shortDescription ?? "Nothing yet")
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                GridRow {
                    key("Classification")
                    if let c = state.currentClassification {
                        HStack(spacing: 6) {
                            UIBadgeView(text: UIFormat.labelName(c.label), color: UIPalette.color(for: c.label))
                            Text("\(c.source.rawValue), \(c.role.rawValue), \(Int((c.confidence * 100).rounded()))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    } else {
                        Text("None").foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    key("Reason")
                    Text(state.currentClassification?.reason ?? "")
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                if let err = state.lastError {
                    GridRow {
                        key("Last error")
                        Text(err).foregroundStyle(.orange).lineLimit(3).textSelection(.enabled)
                    }
                }
            }
            .font(.callout)

            Spacer(minLength: 0)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    key("Status")
                    UIBadgeView(text: UIFormat.statusName(state.status), color: UIPalette.color(for: state.status))
                }
                GridRow { key("Drift (rolling)"); value("\(Int(state.driftSeconds)) s") }
                GridRow { key("Focused"); value(String(format: "%.1f min", state.focusedSeconds / 60)) }
                GridRow { key("Drift count"); value("\(state.driftCount)") }
                GridRow { key("LLM calls"); value("text \(state.textCalls), vision \(state.visionCalls)") }
                if let anchor = state.anchorName {
                    GridRow { key("Anchor"); Text(anchor).lineLimit(1) }
                }
            }
            .font(.callout)
            .frame(width: 280, alignment: .leading)
        }
    }

    private func key(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private func value(_ text: String) -> some View {
        Text(text).monospacedDigit()
    }

    // MARK: Tables

    private var classificationTable: some View {
        let rows = Array(state.log.reversed())
        return VStack(spacing: 0) {
            Table(rows) {
                TableColumn("Time") { e in Text(UIFormat.time(e.at)).monospacedDigit() }
                    .width(min: 60, ideal: 66, max: 80)
                TableColumn("App") { e in Text(e.appName).lineLimit(1) }
                    .width(min: 70, ideal: 110, max: 180)
                TableColumn("Title / URL") { e in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.title).lineLimit(1)
                        if let url = e.url {
                            Text(url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .help([e.title, e.url ?? ""].joined(separator: "\n"))
                }
                .width(min: 160, ideal: 300)
                TableColumn("Label") { e in
                    if let label = e.label {
                        UIBadgeView(text: UIFormat.labelName(label), color: UIPalette.color(for: label))
                    } else {
                        Text("-").foregroundStyle(.secondary)
                    }
                }
                .width(min: 70, ideal: 86, max: 110)
                TableColumn("Source") { e in Text(e.source?.rawValue ?? "-").foregroundStyle(.secondary) }
                    .width(min: 60, ideal: 76, max: 100)
                TableColumn("Reason") { e in Text(e.reason).lineLimit(2).help(e.reason) }
                    .width(min: 140, ideal: 260)
                TableColumn("Status") { e in
                    Text(UIFormat.statusName(e.status)).foregroundStyle(UIPalette.color(for: e.status))
                }
                .width(min: 60, ideal: 80, max: 100)
            }
            footer(count: rows.count) { Self.jsonLines(state.log) }
        }
    }

    private var sensorTable: some View {
        let rows = state.sensorLog.enumerated().reversed().map { UISensorRow(id: $0.offset, ctx: $0.element) }
        return VStack(spacing: 0) {
            Table(rows) {
                TableColumn("Time") { r in Text(UIFormat.time(r.ctx.timestamp)).monospacedDigit() }
                    .width(min: 60, ideal: 66, max: 80)
                TableColumn("App") { r in
                    Text(r.ctx.appName).lineLimit(1).help(r.ctx.bundleID)
                }
                .width(min: 70, ideal: 110, max: 180)
                TableColumn("Title") { r in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.ctx.cleanTitle.isEmpty ? "(no title)" : r.ctx.cleanTitle).lineLimit(1)
                        if r.ctx.windowTitle != r.ctx.cleanTitle && !r.ctx.windowTitle.isEmpty {
                            Text("raw: \(r.ctx.windowTitle)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .help(r.ctx.windowTitle)
                }
                .width(min: 160, ideal: 280)
                TableColumn("Domain / path") { r in
                    Text((r.ctx.domain ?? "") + (r.ctx.urlPath ?? "")).lineLimit(1).help(r.ctx.url ?? "")
                }
                .width(min: 100, ideal: 200)
                TableColumn("Query") { r in Text(r.ctx.searchQuery ?? "").lineLimit(1) }
                    .width(min: 60, ideal: 120)
                TableColumn("Document") { r in
                    Text(r.ctx.documentPath.map { ($0 as NSString).lastPathComponent } ?? "")
                        .lineLimit(1)
                        .help(r.ctx.documentPath ?? "")
                }
                .width(min: 60, ideal: 120)
                TableColumn("Private") { r in
                    if r.ctx.isPrivateWindow {
                        Image(systemName: "eye.slash").foregroundStyle(.purple)
                    } else {
                        Text("")
                    }
                }
                .width(min: 44, ideal: 50, max: 60)
            }
            footer(count: rows.count) { Self.jsonLines(state.sensorLog) }
        }
    }

    private func footer(count: Int, json: @escaping () -> String) -> some View {
        HStack {
            Text("\(count) rows, newest first").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Copy as JSON lines") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(json(), forType: .string)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private static func jsonLines<T: Encodable>(_ items: [T]) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return items.compactMap { try? encoder.encode($0) }
            .compactMap { String(data: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }
}

struct UISensorRow: Identifiable {
    let id: Int
    let ctx: WindowContext
}
