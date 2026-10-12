import SwiftUI

/// Selected element details, its counterparts on other platforms, and audit issues.
struct ElementsInspectorView: View {
    @ObservedObject var inspector: InspectorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Text("Click an element in any pane. Viewport finds the same control on the other platforms.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    inspector.refreshSnapshots()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .help("Read the element trees again (⌘R)")
                .keyboardShortcut("r", modifiers: .command)
            }

            HStack(spacing: 14) {
                Toggle("All outlines", isOn: $inspector.showsAllOutlines)
                Toggle("Flag issues", isOn: $inspector.showsIssues)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)

            paneStatus

            if let reference = inspector.element(inspector.selection) {
                selectedElement(reference)
                counterparts(for: reference)
            } else {
                InspectorPlaceholder(
                    systemImage: "cursorarrow.click.2",
                    title: "No element selected",
                    message: "Hover a pane to preview elements, then click one to compare it."
                )
            }

            issues
        }
    }

    private var paneStatus: some View {
        InspectorSection("Panes") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(inspector.panes) { pane in
                    HStack(spacing: 8) {
                        Image(systemName: pane.source.systemImage)
                            .foregroundStyle(pane.source.accentColor)
                            .frame(width: 16)
                        Text(pane.title)
                            .font(.caption.weight(.medium))
                        Spacer(minLength: 4)
                        statusText(for: pane)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func statusText(for pane: InspectorPane) -> some View {
        switch inspector.snapshots[pane.id]?.phase {
        case .none:
            Text("Not read").font(.caption).foregroundStyle(.tertiary)
        case .loading:
            ProgressView().controlSize(.mini)
        case let .loaded(snapshot):
            Text("\(snapshot.elements.count) elements")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        case let .failed(message):
            Label("Unavailable", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .help(message)
        }
    }

    private func selectedElement(_ reference: InspectorElementReference) -> some View {
        let element = reference.element
        let unit = inspector.snapshot(for: reference.pane.id)?.unit ?? "pt"
        return InspectorSection("Selected · \(reference.pane.title)") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: element.role.systemImage)
                        .foregroundStyle(.orange)
                    Text(element.displayName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                InspectorPropertyRow(title: "Role", value: element.role.title)
                InspectorPropertyRow(title: "Label", value: element.label, copyable: true)
                if element.text != nil {
                    InspectorPropertyRow(title: "Text", value: element.text, copyable: true)
                }
                InspectorPropertyRow(
                    title: "Identifier",
                    value: element.identifier,
                    monospaced: true,
                    copyable: true
                )
                if element.value != nil {
                    InspectorPropertyRow(title: "Value", value: element.value)
                }
                InspectorPropertyRow(
                    title: "Size",
                    value: "\(PaneInspectionOverlay.format(element.size.width)) × \(PaneInspectionOverlay.format(element.size.height)) \(unit)"
                )
                InspectorPropertyRow(
                    title: "Enabled",
                    value: element.isEnabled ? "Yes" : "No"
                )
                InspectorPropertyRow(title: "Platform", value: element.platformRole, monospaced: true)
            }
        }
    }

    @ViewBuilder
    private func counterparts(for reference: InspectorElementReference) -> some View {
        let counterparts = inspector.counterparts()
        if !counterparts.isEmpty {
            let findings = ElementParityCheck.findings(
                for: reference.element,
                in: reference.pane.source,
                counterparts: counterparts.map { ($0.0.source, $0.1) }
            )
            // Missing counterparts already read "Not found" in their row.
            .filter { $0.kind != .missing }
            InspectorSection("On other platforms") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(counterparts, id: \.0.id) { pane, match in
                        counterpartRow(pane: pane, match: match)
                    }
                    if !findings.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(findings) { finding in
                                Label(finding.message, systemImage: icon(for: finding.kind))
                                    .font(.caption)
                                    .foregroundStyle(finding.kind == .missing ? Color.secondary : Color.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    } else if counterparts.contains(where: { $0.1 != nil }) {
                        Label("Labels and roles match", systemImage: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }
        }
    }

    private func counterpartRow(pane: InspectorPane, match: ElementMatcher.Match?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: pane.source.systemImage)
                .foregroundStyle(pane.source.accentColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(pane.title)
                    .font(.caption.weight(.semibold))
                if let match {
                    let unit = inspector.snapshot(for: pane.id)?.unit ?? ""
                    Text(match.element.displayName)
                        .font(.caption)
                        .lineLimit(2)
                    Text("\(match.element.role.title) · \(PaneInspectionOverlay.format(match.element.size.width))×\(PaneInspectionOverlay.format(match.element.size.height)) \(unit)"
                        + (match.element.identifier.map { " · \($0)" } ?? ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text("Not found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if let match {
                Text("\(Int((match.score * 100).rounded()))%")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.green.opacity(0.18), in: Capsule())
                    .help("Match confidence")
                Button {
                    inspector.select(InspectorSelection(paneID: pane.id, elementID: match.element.id))
                } label: {
                    Image(systemName: "scope")
                }
                .buttonStyle(PaneToolbarButtonStyle())
                .help("Select this element instead")
            }
        }
    }

    @ViewBuilder
    private var issues: some View {
        let groups = inspector.panes.compactMap { pane -> (InspectorPane, [AccessibilityAudit.Issue])? in
            let issues = inspector.issues(for: pane.id)
            return issues.isEmpty ? nil : (pane, issues)
        }
        if !groups.isEmpty {
            InspectorSection("Accessibility issues") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(groups, id: \.0.id) { pane, issues in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(issues) { issue in
                                    Button {
                                        inspector.select(
                                            InspectorSelection(paneID: pane.id, elementID: issue.elementID)
                                        )
                                    } label: {
                                        Label(issue.message, systemImage: issue.systemImage)
                                            .font(.caption)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(PaneToolbarButtonStyle())
                                }
                            }
                            .padding(.top, 4)
                        } label: {
                            Text("\(pane.title) · \(issues.count)")
                                .font(.caption.weight(.semibold))
                        }
                    }
                }
            }
        }
    }

    private func icon(for kind: ElementParityCheck.Finding.Kind) -> String {
        switch kind {
        case .missing: "questionmark.circle"
        case .labelDiffers: "textformat.alt"
        case .roleDiffers: "square.on.square"
        case .missingLabel: "text.badge.xmark"
        }
    }
}
