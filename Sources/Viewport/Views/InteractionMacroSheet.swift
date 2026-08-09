import SwiftUI

struct InteractionMacroSheet: View {
    @ObservedObject var service: InteractionMacroService
    @ObservedObject var workspace: WorkspaceStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedMacroID: UUID?
    @State private var editingEvents: [MacroPointerEvent] = []
    @State private var recordingName = ""
    @State private var replayTarget: MacroReplayTarget = .both
    @State private var statusMessage: String?

    private var selectedMacro: InteractionMacro? {
        guard let selectedMacroID else { return nil }
        return service.macros.first { $0.id == selectedMacroID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 520, idealHeight: 600)
        .onChange(of: selectedMacroID) { _, newValue in
            if let macro = service.macros.first(where: { $0.id == newValue }) {
                editingEvents = macro.events
            } else {
                editingEvents = []
            }
        }
        .onDisappear {
            service.cancelReplay()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Interaction macros")
                    .font(.title3.weight(.semibold))
                Text("Record taps and swipes, edit the event list, then replay on device panes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        HStack(spacing: 0) {
            macroList
                .frame(width: 240)
            Divider()
            macroDetail
        }
    }

    private var macroList: some View {
        VStack(alignment: .leading, spacing: 12) {
            recordingControls
                .padding(.horizontal, 12)
                .padding(.top, 12)

            List(selection: $selectedMacroID) {
                ForEach(service.macros) { macro in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(macro.name)
                            .font(.body.weight(.medium))
                        Text("\(macro.events.count) events")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(macro.id)
                }
                .onDelete(perform: deleteMacros)
            }
            .listStyle(.sidebar)
        }
    }

    private var recordingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if service.isRecording {
                TextField("Macro name", text: $recordingName)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Label(
                        "\(service.draftEventCount) events",
                        systemImage: "record.circle"
                    )
                    .foregroundStyle(.red)
                    .font(.caption)
                    Spacer()
                    Button("Stop recording") {
                        let name = recordingName
                        recordingName = ""
                        if let macro = service.stopRecording(named: name) {
                            selectedMacroID = macro.id
                            statusMessage = "Saved “\(macro.name)”"
                        } else {
                            statusMessage = "Nothing recorded"
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                Button {
                    recordingName = ""
                    service.startRecording()
                    statusMessage = "Recording… interact with a device pane."
                } label: {
                    Label("Start recording", systemImage: "record.circle")
                }
                .disabled(service.isReplaying)
            }
        }
    }

    @ViewBuilder
    private var macroDetail: some View {
        if let macro = selectedMacro {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(macro.name)
                        .font(.headline)
                    Spacer()
                    Picker("Replay target", selection: $replayTarget) {
                        ForEach(MacroReplayTarget.allCases) { target in
                            Text(target.title).tag(target)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)

                    Button(service.isReplaying ? "Stop replay" : "Replay") {
                        if service.isReplaying {
                            service.cancelReplay()
                            statusMessage = "Replay stopped"
                        } else {
                            let sessions = workspace.captureSessions(
                                forMacroTarget: replayTarget
                            )
                            guard !sessions.isEmpty else {
                                statusMessage = "No visible \(replayTarget.title) pane(s)"
                                return
                            }
                            service.replay(
                                macro,
                                targets: replayTarget,
                                sessions: sessions
                            )
                            statusMessage = "Replaying on \(replayTarget.title)…"
                        }
                    }
                    .disabled(macro.events.isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                Text("Edit events (normalized coordinates 0–1). Changes save automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)

                List {
                    ForEach($editingEvents) { $event in
                        MacroEventRow(event: $event)
                    }
                    .onDelete { offsets in
                        editingEvents.remove(atOffsets: offsets)
                        saveEdits(for: macro)
                    }
                }
                .onChange(of: editingEvents) { _, _ in
                    saveEdits(for: macro)
                }
            }
        } else {
            ContentUnavailableView(
                "Select a macro",
                systemImage: "hand.tap",
                description: Text("Choose a saved macro or record a new one.")
            )
        }
    }

    private var footer: some View {
        HStack {
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private func deleteMacros(at offsets: IndexSet) {
        for index in offsets {
            let macro = service.macros[index]
            if selectedMacroID == macro.id {
                selectedMacroID = nil
                editingEvents = []
            }
            service.delete(macro)
        }
        statusMessage = "Macro deleted"
    }

    private func saveEdits(for macro: InteractionMacro) {
        service.updateEvents(for: macro, events: editingEvents)
    }
}

private struct MacroEventRow: View {
    @Binding var event: MacroPointerEvent

    var body: some View {
        HStack(spacing: 12) {
            Text(event.phase.rawValue)
                .font(.caption.monospaced())
                .frame(width: 48, alignment: .leading)
            Text(event.source.title)
                .font(.caption)
                .frame(width: 56, alignment: .leading)
            Text(String(format: "%.2fs", event.timestamp))
                .font(.caption.monospaced())
                .frame(width: 48, alignment: .trailing)
            TextField("x", value: $event.point.x, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
            TextField("y", value: $event.point.y, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
            if let duration = event.duration {
                Text(String(format: "%.2fs", duration))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
