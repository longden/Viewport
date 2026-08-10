import SwiftUI

struct SettingsSheet: View {
    @ObservedObject var workspace: WorkspaceStore
    @AppStorage("appAppearance") private var appearanceRaw = AppAppearance.system.rawValue
    @Environment(\.dismiss) private var dismiss

    private var appearance: Binding<AppAppearance> {
        Binding(
            get: { AppAppearance(rawValue: appearanceRaw) ?? .system },
            set: { appearanceRaw = $0.rawValue }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 560, idealHeight: 600)
        .presentationSizing(.form)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings")
                    .font(.title3.weight(.semibold))
                    Text("Appearance, screenshots, and experimental tools.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private var content: some View {
        List {
            Section("Appearance") {
                Picker("Mode", selection: appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Label(option.title, systemImage: option.systemImage)
                            .tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }

            Section("Screenshots") {
                Button {
                    workspace.setScreenshotPlatformLabelsEnabled(
                        !workspace.screenshotPlatformLabelsEnabled
                    )
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(
                            systemName: workspace.screenshotPlatformLabelsEnabled
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        .font(.title3)
                        .foregroundStyle(
                            workspace.screenshotPlatformLabelsEnabled
                                ? Color.accentColor
                                : Color.secondary
                        )
                        .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Show platform labels")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                            Text(
                                "Adds a caption above each pane: Web, Android, or iOS."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    workspace.setDeviceBezelsEnabled(!workspace.deviceBezelsEnabled)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(
                            systemName: workspace.deviceBezelsEnabled
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        .font(.title3)
                        .foregroundStyle(
                            workspace.deviceBezelsEnabled
                                ? Color.accentColor
                                : Color.secondary
                        )
                        .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Show device bezels")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                            Text(
                                "Optional geometric phone chassis around device panes and combined PNG export (not vendor skin assets). Off by default for max pixels."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Section("Diagnostics") {
                Button {
                    workspace.setPerfHUDEnabled(!workspace.perfHUDEnabled)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(
                            systemName: workspace.perfHUDEnabled
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        .font(.title3)
                        .foregroundStyle(
                            workspace.perfHUDEnabled
                                ? Color.accentColor
                                : Color.secondary
                        )
                        .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Show FPS HUD on device panes")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                            Text(
                                "Estimates frames per second from live capture delivery."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Section("Android") {
                Button {
                    workspace.setPreferHeadlessAndroidEmulators(
                        !workspace.preferHeadlessAndroidEmulators
                    )
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(
                            systemName: workspace.preferHeadlessAndroidEmulators
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        .font(.title3)
                        .foregroundStyle(
                            workspace.preferHeadlessAndroidEmulators
                                ? Color.accentColor
                                : Color.secondary
                        )
                        .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Launch emulators headless")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                            Text(
                                "Starts Android emulators with -no-window and an explicit gRPC port for direct capture."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Section("iOS") {
                Button {
                    workspace.setPreferHeadlessIOSSimulators(
                        !workspace.preferHeadlessIOSSimulators
                    )
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(
                            systemName: workspace.preferHeadlessIOSSimulators
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        .font(.title3)
                        .foregroundStyle(
                            workspace.preferHeadlessIOSSimulators
                                ? Color.accentColor
                                : Color.secondary
                        )
                        .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Launch Simulators without Simulator.app")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                            Text(
                                "Boots with simctl bootstatus and attaches when Booted. Direct Surface capture does not need Simulator.app — turn this off for Legacy host-window capture."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Section("Experiment") {
                Button {
                    workspace.setExperimentalFeaturesEnabled(
                        !workspace.experimentalFeaturesEnabled
                    )
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(
                            systemName: workspace.experimentalFeaturesEnabled
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        .font(.title3)
                        .foregroundStyle(
                            workspace.experimentalFeaturesEnabled
                                ? Color.accentColor
                                : Color.secondary
                        )
                        .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Experimental compare tools")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                            Text(
                                workspace.experimentalFeaturesEnabled
                                    ? "On — unfinished tools appear under Experimental in Device tools."
                                    : "Off — unfinished compare tools stay hidden. They still need refining."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}
