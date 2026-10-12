import MapKit
import SwiftUI
import UniformTypeIdentifiers

/// Simulated location and GPX route playback for every visible pane.
struct LocationInspectorView: View {
    @ObservedObject var store: LocationSimulationStore
    @ObservedObject var workspace: WorkspaceStore
    @State private var camera: MapCameraPosition = .automatic
    @State private var pending: GeoCoordinate?
    @State private var coordinateText = ""
    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var isSearching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PlatformTargetToggles(targets: $store.targets, workspace: workspace)

            map

            InspectorSection("Search") {
                HStack(spacing: 6) {
                    TextField("City, address, or place", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(search)
                    if isSearching {
                        ProgressView().controlSize(.small)
                    }
                }
                ForEach(searchResults, id: \.self) { item in
                    Button {
                        choose(GeoCoordinate(item.location.coordinate), apply: true)
                        searchResults = []
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name ?? "Result")
                                .font(.caption.weight(.medium))
                            if let address = item.address?.shortAddress {
                                Text(address)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PaneToolbarButtonStyle())
                }
            }

            InspectorSection("Coordinate") {
                HStack(spacing: 6) {
                    TextField("37.33490, -122.00902", text: $coordinateText)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                        .onSubmit(applyTypedCoordinate)
                    Button("Set") {
                        applyTypedCoordinate()
                    }
                    .disabled(GeoCoordinate.parse(coordinateText) == nil || store.isBusy)
                }
                HStack {
                    Menu("Presets") {
                        ForEach(LocationPreset.all) { preset in
                            Button(preset.name) {
                                choose(preset.coordinate, apply: true)
                            }
                        }
                    }
                    .fixedSize()
                    Spacer()
                    Button("Clear location", role: .destructive) {
                        store.clear()
                    }
                    .disabled(store.isBusy)
                }
                .controlSize(.small)
                if let applied = store.appliedCoordinate {
                    Text("Current: \(applied.displayText)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            route

            InspectorStatusLine(status: store.status)
            Text("Web gets a simulated navigator.geolocation. Physical phones keep their real location.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            if let applied = store.appliedCoordinate {
                pending = applied
                coordinateText = applied.displayText
                camera = .region(region(around: applied))
            }
        }
        .onChange(of: store.routePosition) { _, position in
            guard store.isPlayingRoute, let position else { return }
            camera = .region(region(around: position, span: 0.02))
        }
    }

    private var map: some View {
        MapReader { proxy in
            Map(position: $camera) {
                if let route = store.route {
                    MapPolyline(coordinates: route.points.map(\.clCoordinate))
                        .stroke(.blue, lineWidth: 3)
                }
                if let pending {
                    Marker("Pin", coordinate: pending.clCoordinate)
                        .tint(.red)
                }
                if let position = store.routePosition, store.route != nil {
                    Annotation("Now", coordinate: position.clCoordinate) {
                        Circle()
                            .fill(.blue)
                            .frame(width: 12, height: 12)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                }
            }
            .mapControls {
                MapZoomStepper()
            }
            .onTapGesture { location in
                guard let coordinate = proxy.convert(location, from: .local) else { return }
                choose(GeoCoordinate(coordinate), apply: false)
            }
        }
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            Text("Click the map to drop a pin, then Set.")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: Capsule())
                .padding(6)
                .allowsHitTesting(false)
        }
    }

    private var route: some View {
        InspectorSection("Route") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button(store.route == nil ? "Import GPX…" : "Replace GPX…") {
                        importGPX()
                    }
                    if store.route != nil {
                        Button("Remove", role: .destructive) {
                            store.setRoute(nil)
                        }
                    }
                    Spacer()
                }
                .controlSize(.small)

                if let route = store.route {
                    Text("\(route.name) · \(route.points.count) points · \(LocationSimulationStore.distanceText(route.totalDistance))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Speed", selection: $store.routeSpeed) {
                        ForEach(RouteSpeed.allCases) { speed in
                            Text(speed.title).tag(speed)
                        }
                    }
                    .controlSize(.small)
                    .disabled(store.isPlayingRoute)
                    HStack {
                        if store.isPlayingRoute {
                            Button {
                                store.stopRoute()
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                            }
                            ProgressView(value: store.routeProgress)
                        } else {
                            Button {
                                store.playRoute()
                            } label: {
                                Label("Play route", systemImage: "play.fill")
                            }
                            .disabled(!route.isPlayable)
                            Text(LocationSimulationStore.durationText(
                                route.duration(speed: store.routeSpeed.metersPerSecond)
                            ))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                    }
                    .controlSize(.small)
                } else {
                    Text("Play a GPX track on Simulators (natively), Android emulators, and the web pane together.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func choose(_ coordinate: GeoCoordinate, apply: Bool) {
        pending = coordinate
        coordinateText = coordinate.displayText
        if apply {
            camera = .region(region(around: coordinate))
            store.apply(coordinate)
        }
    }

    private func applyTypedCoordinate() {
        guard let coordinate = GeoCoordinate.parse(coordinateText) else { return }
        choose(coordinate, apply: true)
    }

    private func search() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        isSearching = true
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        Task {
            let response = try? await MKLocalSearch(request: request).start()
            searchResults = Array((response?.mapItems ?? []).prefix(5))
            isSearching = false
        }
    }

    private func importGPX() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "gpx") ?? .xml, .xml]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a GPX track or route"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.loadRoute(from: url)
        if let route = store.route, let bounds = Self.bounds(of: route.points) {
            camera = .region(bounds)
        }
    }

    private func region(around coordinate: GeoCoordinate, span: Double = 0.05) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate.clCoordinate,
            span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)
        )
    }

    static func bounds(of points: [GeoCoordinate]) -> MKCoordinateRegion? {
        guard let first = points.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for point in points {
            minLat = min(minLat, point.latitude)
            maxLat = max(maxLat, point.latitude)
            minLon = min(minLon, point.longitude)
            maxLon = max(maxLon, point.longitude)
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLat - minLat) * 1.3, 0.005),
                longitudeDelta: max((maxLon - minLon) * 1.3, 0.005)
            )
        )
    }
}
