import AppKit
import Combine
import CoreGraphics
import Foundation

/// One element in one pane.
struct InspectorSelection: Equatable {
    let paneID: UUID
    let elementID: Int
}

enum PaneSnapshotPhase: Equatable {
    case loading
    case loaded(ElementSnapshot)
    case failed(String)
}

struct PaneSnapshotState: Equatable {
    /// Device the snapshot belongs to; a different selection makes it stale.
    let deviceID: String?
    var phase: PaneSnapshotPhase

    var snapshot: ElementSnapshot? {
        if case let .loaded(snapshot) = phase { return snapshot }
        return nil
    }
}

/// A visible pane the inspector can read.
struct InspectorPane: Identifiable, Equatable {
    let id: UUID
    let source: ViewerSource
    let title: String
    let device: StreamedDevice?
}

/// Element inspection, cross-platform comparison, and design QA tools.
@MainActor
final class InspectorStore: ObservableObject {
    @Published var tab: InspectorTab = .elements {
        didSet {
            guard tab != oldValue else { return }
            hovered = nil
            measurement = nil
            hoverColor = nil
            if tab == .elements, isPresented {
                refreshStaleSnapshots()
            }
        }
    }
    @Published private(set) var isPresented = false
    @Published var designTool: DesignTool = .interact {
        didSet {
            hovered = nil
            measurement = nil
            hoverColor = nil
            if designTool == .measure {
                refreshStaleSnapshots()
            }
        }
    }
    @Published var showsAllOutlines = false
    @Published var showsIssues = true
    @Published private(set) var snapshots: [UUID: PaneSnapshotState] = [:]
    @Published private(set) var hovered: InspectorSelection?
    @Published private(set) var selection: InspectorSelection?
    @Published private(set) var matches: [UUID: ElementMatcher.Match] = [:]
    @Published private(set) var overlays: [UUID: DesignOverlay] = [:]
    @Published var grid = GridSettings()
    @Published private(set) var measurement: PaneMeasurement?
    @Published private(set) var hoverColor: ColorSample?
    @Published private(set) var loupe: (paneID: UUID, point: CGPoint, image: CGImage)?
    @Published private(set) var pickedColors: [ColorSample] = []
    @Published private(set) var overlayError: String?

    private weak var workspace: WorkspaceStore?
    private weak var web: WebViewModel?
    private let snapshotService: ElementSnapshotService
    private var snapshotTasks: [UUID: Task<Void, Never>] = [:]
    private var androidDensities: [String: Double] = [:]
    private var densityRequests: Set<String> = []
    private var webFrame: (image: CGImage, capturedAt: Date)?
    private var webFrameTask: Task<Void, Never>?
    private var lastColorSampleAt: CFAbsoluteTime = 0
    private var cancellables: Set<AnyCancellable> = []
    private var pendingRefreshTask: Task<Void, Never>?
    /// `WebElementSnapshot.contentVersion` when the web snapshot was taken.
    private var webContentVersion: String?
    private var webVersionCheck: Task<Void, Never>?
    private var lastWebVersionCheckAt = Date.distantPast

    init(
        workspace: WorkspaceStore,
        web: WebViewModel,
        snapshotService: ElementSnapshotService = ElementSnapshotService()
    ) {
        self.workspace = workspace
        self.web = web
        self.snapshotService = snapshotService
        observeContentChanges(workspace: workspace, web: web)
    }

    /// Re-reads element trees when a pane's device, frame size (rotation), or
    /// web page changes while elements are on screen.
    private func observeContentChanges(workspace: WorkspaceStore, web: WebViewModel) {
        for session in workspace.allCaptureSessions {
            session.$selectedDeviceID
                .combineLatest(session.$capturedFrameSize)
                .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
                .dropFirst()
                .sink { [weak self] _, _ in self?.scheduleStaleRefresh() }
                .store(in: &cancellables)
        }
        web.$isLoading
            .removeDuplicates()
            .filter { !$0 }
            .sink { [weak self] _ in self?.scheduleStaleRefresh(force: true) }
            .store(in: &cancellables)
        workspace.$paneLayout
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleStaleRefresh() }
            .store(in: &cancellables)
    }

    private func scheduleStaleRefresh(force: Bool = false) {
        guard showsElementOverlay else { return }
        pendingRefreshTask?.cancel()
        pendingRefreshTask = Task { [weak self] in
            // Let the stream settle (first frame, rotation) before reading.
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled, showsElementOverlay else { return }
            if force, let webPane = panes.first(where: { $0.source == .web }) {
                refreshSnapshot(for: webPane)
            }
            refreshStaleSnapshots()
        }
    }

    // MARK: - Presentation

    func setPresented(_ presented: Bool) {
        guard isPresented != presented else { return }
        isPresented = presented
        hovered = nil
        measurement = nil
        hoverColor = nil
        loupe = nil
        if presented, tab == .elements {
            refreshStaleSnapshots()
        }
    }

    /// Panes swallow clicks while selecting elements, measuring, or picking colours.
    var interceptsPaneInput: Bool {
        guard isPresented else { return false }
        switch tab {
        case .elements: return true
        case .design: return designTool != .interact
        case .location, .apps, .network: return false
        }
    }

    var showsElementOverlay: Bool {
        isPresented && (tab == .elements || (tab == .design && designTool == .measure))
    }

    // MARK: - Panes

    var panes: [InspectorPane] {
        guard let workspace else { return [] }
        let nodes = workspace.orderedVisiblePanes
        return nodes.compactMap { inspectorPane(for: $0, among: nodes, in: workspace) }
    }

    /// Builds only the requested pane; hover calls this on every mouse move.
    func pane(_ id: UUID) -> InspectorPane? {
        guard let workspace else { return nil }
        let nodes = workspace.orderedVisiblePanes
        guard let node = nodes.first(where: { $0.id == id }) else { return nil }
        return inspectorPane(for: node, among: nodes, in: workspace)
    }

    private func inspectorPane(
        for node: PaneGridNode,
        among nodes: [PaneGridNode],
        in workspace: WorkspaceStore
    ) -> InspectorPane? {
        guard let source = node.viewerSource else { return nil }
        let sameSource = nodes.filter { $0.viewerSource == source }
        let index = sameSource.firstIndex { $0.id == node.id } ?? 0
        let title = source.title + (index > 0 ? " \(index + 1)" : "")
        let device = source == .web ? nil : workspace.captureSession(for: node)?.selectedDevice
        return InspectorPane(id: node.id, source: source, title: title, device: device)
    }

    func snapshot(for paneID: UUID) -> ElementSnapshot? {
        snapshots[paneID]?.snapshot
    }

    func element(_ selection: InspectorSelection?) -> InspectorElementReference? {
        guard let selection,
              let element = snapshot(for: selection.paneID)?.element(id: selection.elementID),
              let pane = pane(selection.paneID) else {
            return nil
        }
        return InspectorElementReference(pane: pane, element: element)
    }

    // MARK: - Snapshots

    func refreshSnapshots() {
        for pane in panes {
            refreshSnapshot(for: pane)
        }
    }

    func refreshStaleSnapshots() {
        for pane in panes {
            let state = snapshots[pane.id]
            let isStale: Bool
            switch state?.phase {
            case .none, .failed: isStale = true
            case .loading: isStale = false
            case let .loaded(snapshot):
                // An in-flight refresh for the same device is left to finish.
                isStale = state?.deviceID != pane.device?.id
                    || (snapshotTasks[pane.id] == nil
                        && (Date().timeIntervalSince(snapshot.capturedAt) > 2
                            || (pane.source == .web && snapshot.elements.isEmpty)))
            }
            if isStale {
                refreshSnapshot(for: pane)
            }
        }
        // Drop panes that left the layout.
        let visible = Set(panes.map(\.id))
        snapshots = snapshots.filter { visible.contains($0.key) }
        for (paneID, task) in snapshotTasks where !visible.contains(paneID) {
            task.cancel()
            snapshotTasks[paneID] = nil
        }
    }

    private func refreshSnapshot(for pane: InspectorPane) {
        snapshotTasks[pane.id]?.cancel()
        let previous = snapshots[pane.id]
        if previous?.snapshot == nil || previous?.deviceID != pane.device?.id {
            snapshots[pane.id] = PaneSnapshotState(deviceID: pane.device?.id, phase: .loading)
        }
        let paneID = pane.id
        let deviceID = pane.device?.id
        snapshotTasks[paneID] = Task { [weak self] in
            guard let self else { return }
            let phase: PaneSnapshotPhase
            do {
                let snapshot: ElementSnapshot
                if pane.source == .web {
                    guard let web, web.webView.url != nil else {
                        throw ElementSnapshotError.unsupported("Load a page in the web pane first.")
                    }
                    let version = await WebElementSnapshot.contentVersion(in: web.webView)
                    snapshot = try await WebElementSnapshot.capture(in: web.webView)
                    webContentVersion = version
                } else if let device = pane.device {
                    snapshot = try await snapshotService.snapshot(of: device)
                } else {
                    throw ElementSnapshotError.unsupported("Select a device in this pane first.")
                }
                phase = .loaded(snapshot)
            } catch is CancellationError {
                return
            } catch {
                phase = .failed(error.localizedDescription)
            }
            guard !Task.isCancelled else { return }
            snapshots[paneID] = PaneSnapshotState(deviceID: deviceID, phase: phase)
            snapshotTasks[paneID] = nil
            if let selection, selection.paneID == paneID,
               snapshot(for: paneID)?.element(id: selection.elementID) == nil {
                self.selection = nil
            }
            updateMatches()
        }
    }

    // MARK: - Hover and selection

    func hover(paneID: UUID, at point: CGPoint?) {
        guard let point else {
            if hovered?.paneID == paneID { hovered = nil }
            if loupe?.paneID == paneID {
                loupe = nil
                hoverColor = nil
            }
            return
        }
        if tab == .design, designTool == .colorPicker {
            sampleColor(paneID: paneID, at: point)
            return
        }
        if pane(paneID)?.source == .web { refreshWebSnapshotIfOld(paneID: paneID) }
        let next = snapshot(for: paneID)?.hitTest(point).map {
            InspectorSelection(paneID: paneID, elementID: $0.id)
        }
        if hovered != next {
            hovered = next
        }
    }

    func click(paneID: UUID, at point: CGPoint) {
        if tab == .design, designTool == .colorPicker {
            pickColor(paneID: paneID, at: point)
            return
        }
        guard let element = snapshot(for: paneID)?.hitTest(point) else {
            selection = nil
            updateMatches()
            return
        }
        select(InspectorSelection(paneID: paneID, elementID: element.id))
    }

    func select(_ selection: InspectorSelection?) {
        self.selection = selection
        updateMatches()
    }

    private func updateMatches() {
        guard let reference = element(selection) else {
            matches = [:]
            return
        }
        var next: [UUID: ElementMatcher.Match] = [:]
        for pane in panes where pane.id != reference.pane.id {
            guard let snapshot = snapshot(for: pane.id),
                  let match = ElementMatcher.bestMatch(for: reference.element, in: snapshot) else {
                continue
            }
            next[pane.id] = match
        }
        matches = next
    }

    /// Counterparts for the selection in every other loaded pane (nil = not found).
    func counterparts() -> [(InspectorPane, ElementMatcher.Match?)] {
        guard let selection else { return [] }
        return panes
            .filter { $0.id != selection.paneID && snapshot(for: $0.id) != nil }
            .map { ($0, matches[$0.id]) }
    }

    func issues(for paneID: UUID) -> [AccessibilityAudit.Issue] {
        guard let snapshot = snapshot(for: paneID) else { return [] }
        return AccessibilityAudit.issues(in: snapshot)
    }

    private func refreshWebSnapshotIfOld(paneID: UUID) {
        guard snapshotTasks[paneID] == nil, webVersionCheck == nil, let web else { return }
        if let captured = snapshot(for: paneID)?.capturedAt,
           Date().timeIntervalSince(captured) < 1 {
            return
        }
        guard Date().timeIntervalSince(lastWebVersionCheckAt) >= 1 else { return }
        lastWebVersionCheckAt = Date()
        // A cheap version probe first; the full DOM walk only when the page changed.
        webVersionCheck = Task { [weak self] in
            let version = await WebElementSnapshot.contentVersion(in: web.webView)
            guard let self else { return }
            webVersionCheck = nil
            guard version == nil || version != webContentVersion || snapshot(for: paneID) == nil,
                  let pane = pane(paneID) else { return }
            refreshSnapshot(for: pane)
        }
    }

    // MARK: - Measurement

    func beginMeasurement(paneID: UUID, at point: CGPoint) {
        measurement = PaneMeasurement(paneID: paneID, start: point, end: point)
    }

    func updateMeasurement(to point: CGPoint) {
        measurement?.end = point
    }

    func endMeasurement(at point: CGPoint) {
        guard var current = measurement else { return }
        current.end = point
        // A click selects the element under it so hovering others shows spacing.
        if current.rect.width < 0.004, current.rect.height < 0.004 {
            measurement = nil
            click(paneID: current.paneID, at: point)
            return
        }
        measurement = current
    }

    // MARK: - Metrics

    func metrics(for paneID: UUID) -> PaneMetrics? {
        if let snapshot = snapshot(for: paneID), snapshot.screenSize.width > 0 {
            return PaneMetrics(screenSize: snapshot.screenSize, unit: snapshot.unit)
        }
        guard let pane = pane(paneID) else { return nil }
        switch pane.source {
        case .web:
            guard let web else { return nil }
            return PaneMetrics(screenSize: web.webView.bounds.size, unit: "px")
        case .android, .iOS:
            guard let workspace,
                  let node = workspace.orderedVisiblePanes.first(where: { $0.id == paneID }),
                  let size = workspace.captureSession(for: node)?.capturedFrameSize else {
                return nil
            }
            var density: Double?
            if let device = pane.device, pane.source == .android {
                density = androidDensities[device.id]
                if density == nil { requestDensity(for: device) }
            }
            return .estimated(for: pane.source, pixelSize: size, androidDensity: density)
        }
    }

    private func requestDensity(for device: StreamedDevice) {
        guard !densityRequests.contains(device.id) else { return }
        densityRequests.insert(device.id)
        Task { [weak self] in
            guard let self else { return }
            if let density = await snapshotService.androidDensity(for: device) {
                androidDensities[device.id] = density
                objectWillChange.send()
            }
        }
    }

    // MARK: - Colours

    private func frameImage(for paneID: UUID) -> CGImage? {
        guard let pane = pane(paneID) else { return nil }
        if pane.source == .web {
            refreshWebFrameIfNeeded()
            return webFrame?.image
        }
        guard let workspace,
              let node = workspace.orderedVisiblePanes.first(where: { $0.id == paneID }) else {
            return nil
        }
        return workspace.captureSession(for: node)?.snapshotFrame()
    }

    private func refreshWebFrameIfNeeded() {
        guard webFrameTask == nil else { return }
        if let webFrame, Date().timeIntervalSince(webFrame.capturedAt) < 0.5 { return }
        webFrameTask = Task { [weak self] in
            guard let self else { return }
            if let web, let image = await WorkspaceScreenshotService().snapshotWeb(web) {
                webFrame = (image, Date())
            }
            webFrameTask = nil
        }
    }

    private func sampleColor(paneID: UUID, at point: CGPoint) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastColorSampleAt > 1.0 / 30 else { return }
        lastColorSampleAt = now
        guard let source = pane(paneID)?.source,
              let image = frameImage(for: paneID) else {
            return
        }
        hoverColor = PixelSampler.color(in: image, at: point, source: source)
        if let crop = PixelSampler.loupe(in: image, at: point) {
            loupe = (paneID, point, crop)
        }
    }

    private func pickColor(paneID: UUID, at point: CGPoint) {
        guard let source = pane(paneID)?.source else { return }
        if source == .web, webFrame == nil || Date().timeIntervalSince(webFrame!.capturedAt) > 0.5 {
            // Web frames come from an async snapshot; pick once it lands.
            Task { [weak self] in
                guard let self, let web,
                      let image = await WorkspaceScreenshotService().snapshotWeb(web) else { return }
                webFrame = (image, Date())
                storePickedColor(PixelSampler.color(in: image, at: point, source: source))
            }
            return
        }
        guard let image = frameImage(for: paneID) else { return }
        storePickedColor(PixelSampler.color(in: image, at: point, source: source))
    }

    private func storePickedColor(_ sample: ColorSample?) {
        guard let sample else { return }
        pickedColors.removeAll { $0 == sample }
        pickedColors.insert(sample, at: 0)
        if pickedColors.count > 12 {
            pickedColors.removeLast(pickedColors.count - 12)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sample.hex, forType: .string)
    }

    func clearPickedColors() {
        pickedColors.removeAll()
    }

    // MARK: - Design overlays

    func setOverlay(from url: URL, for paneID: UUID) {
        do {
            overlays[paneID] = try DesignOverlay.load(from: url)
            overlayError = nil
        } catch {
            overlayError = error.localizedDescription
        }
    }

    func updateOverlay(for paneID: UUID, _ change: (inout DesignOverlay) -> Void) {
        guard var overlay = overlays[paneID] else { return }
        change(&overlay)
        overlays[paneID] = overlay
    }

    func removeOverlay(for paneID: UUID) {
        overlays[paneID] = nil
    }
}

struct InspectorElementReference: Equatable {
    let pane: InspectorPane
    let element: InspectedElement
}
