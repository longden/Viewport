import SwiftUI

struct DeviceLocationSheet: View {
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var web: WebViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var latitude = "37.3349"
    @State private var longitude = "-122.0090"
    @State private var favoriteName = ""
    @State private var alsoSetWeb = false
    @State private var isBusy = false
    @State private var statusMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                Section("Coordinates") {
                    TextField("Latitude", text: $latitude)
                        .textFieldStyle(.roundedBorder)
                    TextField("Longitude", text: $longitude)
                        .textFieldStyle(.roundedBorder)
                    Text("Latitude −90…90 · Longitude −180…180")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Also set Web geolocation", isOn: $alsoSetWeb)
                        .disabled(!workspace.isVisible(.web))
                }

                Section("Favorites") {
                    HStack {
                        TextField("Name", text: $favoriteName)
                            .textFieldStyle(.roundedBorder)
                        Button("Save") {
                            saveFavorite()
                        }
                        .disabled(
                            favoriteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || isBusy
                        )
                    }

                    if workspace.locationFavorites.isEmpty {
                        Text("No saved locations yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(workspace.locationFavorites) { favorite in
                            HStack {
                                Button(favorite.name) {
                                    latitude = String(favorite.latitude)
                                    longitude = String(favorite.longitude)
                                }
                                .buttonStyle(.plain)
                                Spacer()
                                Button(role: .destructive) {
                                    workspace.removeLocationFavorite(favorite)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 8)

            Divider()
            footer
        }
        .frame(minWidth: 460, idealWidth: 480, minHeight: 420, idealHeight: 460)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Set Location")
                    .font(.title3.weight(.semibold))
                Text("Spoof GPS on visible Android and iOS Simulators.")
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

    private var footer: some View {
        HStack {
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer()
            }

            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(isBusy)

            Button("Set on all devices") {
                run {
                    let (lat, lon) = try parsedCoordinate()
                    try await workspace.broadcastLocation(
                        latitude: lat,
                        longitude: lon,
                        alsoSetWeb: alsoSetWeb,
                        web: web
                    )
                    statusMessage = "Location updated."
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(isBusy)
        }
        .padding(16)
    }

    private func saveFavorite() {
        run {
            let (lat, lon) = try parsedCoordinate()
            try workspace.addLocationFavorite(
                name: favoriteName,
                latitude: lat,
                longitude: lon
            )
            statusMessage = "Favorite saved."
        }
    }

    private func parsedCoordinate() throws -> (Double, Double) {
        let lat = try Self.parseCoordinateField(
            latitude,
            fieldName: "latitude"
        )
        let lon = try Self.parseCoordinateField(
            longitude,
            fieldName: "longitude"
        )
        try DeviceAutomationService.validateCoordinate(
            latitude: lat,
            longitude: lon
        )
        return (lat, lon)
    }

    private static func parseCoordinateField(
        _ raw: String,
        fieldName: String
    ) throws -> Double {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        if let number = formatter.number(from: trimmed) {
            return number.doubleValue
        }
        // Accept comma decimals from locales that use "," as the separator.
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        if normalized != trimmed,
           let number = formatter.number(from: normalized) {
            return number.doubleValue
        }
        throw DeviceAutomationError.commandFailed("Enter a valid \(fieldName).")
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        isBusy = true
        statusMessage = nil
        Task {
            do {
                try await work()
            } catch {
                statusMessage = error.localizedDescription
            }
            isBusy = false
        }
    }
}
