import Combine
import XCTest
@testable import Viewport

@MainActor
final class WorkspaceStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "WorkspaceStoreTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testVisibilityPreservesPlatformOrder() {
        let store = WorkspaceStore(defaults: defaults)

        store.setVisible(false, for: .android)

        XCTAssertEqual(store.orderedVisibleSources, [.web, .iOS])
    }

    func testLaunchReconnectOnlyRefreshesSessionsWithPanes() {
        let store = WorkspaceStore(defaults: defaults)
        func reconnects(_ session: WindowCaptureSession) -> Bool {
            store.launchReconnectSessions.contains { $0 === session }
        }

        XCTAssertTrue(reconnects(store.androidCapture))
        XCTAssertTrue(reconnects(store.iOSCapture))
        XCTAssertFalse(reconnects(store.androidCaptureSecondary))
        XCTAssertFalse(reconnects(store.iOSCaptureSecondary))

        XCTAssertTrue(store.addPane(.android))
        XCTAssertTrue(reconnects(store.androidCaptureSecondary))
    }

    func testCannotHideLastVisiblePane() {
        let store = WorkspaceStore(defaults: defaults)

        store.setVisible(false, for: .android)
        store.setVisible(false, for: .iOS)
        store.setVisible(false, for: .web)

        XCTAssertEqual(store.orderedVisibleSources, [.web])
    }

    func testReopeningWebKeepsCanonicalPaneOrder() {
        let store = WorkspaceStore(defaults: defaults)
        store.setVisible(false, for: .web)
        XCTAssertEqual(
            store.orderedVisiblePanes.map(\.source),
            [ViewerSource.android.rawValue, ViewerSource.iOS.rawValue]
        )

        store.setVisible(true, for: .web)
        XCTAssertEqual(
            store.orderedVisiblePanes.map(\.source),
            [
                ViewerSource.web.rawValue,
                ViewerSource.android.rawValue,
                ViewerSource.iOS.rawValue
            ]
        )

        store.setVisible(false, for: .android)
        store.setVisible(true, for: .android)
        XCTAssertEqual(
            store.orderedVisiblePanes.map(\.source),
            [
                ViewerSource.web.rawValue,
                ViewerSource.android.rawValue,
                ViewerSource.iOS.rawValue
            ]
        )
    }

    func testSecondAndroidPaneStaysBesidePrimaryAndroid() {
        let store = WorkspaceStore(defaults: defaults)
        XCTAssertTrue(store.addPane(.android))
        XCTAssertEqual(
            store.orderedVisiblePanes.map { "\($0.source):\($0.slot)" },
            [
                "\(ViewerSource.web.rawValue):0",
                "\(ViewerSource.android.rawValue):0",
                "\(ViewerSource.android.rawValue):1",
                "\(ViewerSource.iOS.rawValue):0"
            ]
        )
    }

    func testVisibilityPersists() {
        let store = WorkspaceStore(defaults: defaults)
        store.setVisible(false, for: .web)

        let restored = WorkspaceStore(defaults: defaults)

        XCTAssertEqual(restored.orderedVisibleSources, [.android, .iOS])
    }

    func testEveryNonEmptyVisibilityCombinationPreservesPlatformOrder() {
        for mask in 1..<(1 << ViewerSource.allCases.count) {
            defaults.removePersistentDomain(forName: suiteName)
            let store = WorkspaceStore(defaults: defaults)
            let expected = ViewerSource.allCases.enumerated().compactMap {
                index, source in
                mask & (1 << index) == 0 ? nil : source
            }

            for source in ViewerSource.allCases where !expected.contains(source) {
                store.setVisible(false, for: source)
            }

            XCTAssertEqual(store.orderedVisibleSources, expected)
        }
    }

    func testPaneWeightsSurviveVisibilityChangesAndRelaunch() {
        let store = WorkspaceStore(defaults: defaults)
        store.resizePanes(
            leading: .web,
            leadingWeight: 1.6,
            trailing: .android,
            trailingWeight: 0.4,
            persist: true
        )
        store.setVisible(false, for: .web)
        store.setVisible(true, for: .web)

        XCTAssertEqual(store.paneWeight(for: .web), 1.6)
        XCTAssertEqual(store.paneWeight(for: .android), 0.4)

        let restored = WorkspaceStore(defaults: defaults)
        XCTAssertEqual(restored.paneWeight(for: .web), 1.6)
        XCTAssertEqual(restored.paneWeight(for: .android), 0.4)
    }

    func testResetPaneWindowsRestoresPreferredWeights() {
        let store = WorkspaceStore(defaults: defaults)
        store.noteSplitContentSize(CGSize(width: 1_600, height: 800))
        store.resizePanes(
            leading: .web,
            leadingWeight: 0.5,
            trailing: .android,
            trailingWeight: 2.5,
            persist: true
        )
        store.resizePanes(
            leading: .android,
            leadingWeight: 2.5,
            trailing: .iOS,
            trailingWeight: 2.0,
            persist: true
        )
        XCTAssertTrue(store.addPane(.android))

        store.resetPaneWindows()

        let nodes = store.orderedVisiblePanes
        XCTAssertEqual(nodes.count, 4)

        let expected = PaneGridLayout.balancedPaneWidths(
            nodes: nodes,
            contentSize: CGSize(width: 1_600, height: 800),
            deviceAspectByNodeID: [:]
        )
        for node in nodes {
            XCTAssertEqual(node.weight, expected[node.id] ?? -1, accuracy: 0.01)
        }

        // Device columns should be near phone aspect for the preview height;
        // web should keep the leftover (larger than either phone).
        let previewHeight = 800 - PaneGridLayout.paneChromeHeight
        let phoneWidth = previewHeight * PaneGridLayout.fallbackDeviceAspect
        let androidPrimary = nodes.first {
            $0.source == ViewerSource.android.rawValue && $0.slot == 0
        }
        let web = nodes.first { $0.source == ViewerSource.web.rawValue }
        XCTAssertEqual(androidPrimary?.weight ?? 0, phoneWidth, accuracy: 1)
        XCTAssertGreaterThan(web?.weight ?? 0, phoneWidth)

        let restored = WorkspaceStore(defaults: defaults)
        XCTAssertEqual(
            restored.paneWeight(for: .web),
            store.paneWeight(for: .web),
            accuracy: 0.01
        )
    }

    func testBalancedPaneWidthsGivesLeftoverToWeb() {
        let nodes = ViewerSource.allCases.map {
            PaneGridNode(source: $0, weight: 1, slot: 0)
        }
        let widths = PaneGridLayout.balancedPaneWidths(
            nodes: nodes,
            contentSize: CGSize(width: 1_600, height: 800),
            deviceAspectByNodeID: [:]
        )
        let total = nodes.reduce(0.0) { $0 + (widths[$1.id] ?? 0) }
        let available = 1_600 - PaneGridLayout.splitDividerWidth * 2
        XCTAssertEqual(total, available, accuracy: 0.5)

        let webID = nodes.first { $0.viewerSource == .web }!.id
        let androidID = nodes.first { $0.viewerSource == .android }!.id
        XCTAssertGreaterThan(widths[webID]!, widths[androidID]!)
    }

    func testPaneResizePublishesOneAtomicWeightChange() {
        let store = WorkspaceStore(defaults: defaults)
        var updates = 0
        let observation = store.$paneWeights
            .dropFirst()
            .sink { _ in updates += 1 }

        store.resizePanes(
            leading: .web,
            leadingWeight: 1.25,
            trailing: .android,
            trailingWeight: 0.75,
            persist: false
        )

        XCTAssertEqual(updates, 1)
        XCTAssertEqual(store.paneWeight(for: .web), 1.25)
        XCTAssertEqual(store.paneWeight(for: .android), 0.75)
        withExtendedLifetime(observation) {}
    }

    func testPerformanceProfilePersists() {
        let store = WorkspaceStore(defaults: defaults)
        store.setPerformanceProfile(.sharp)

        let restored = WorkspaceStore(defaults: defaults)

        XCTAssertEqual(restored.performanceProfile, .sharp)
    }

    func testCanAddSecondAndroidPaneAndPersistLayout() {
        let store = WorkspaceStore(defaults: defaults)
        XCTAssertEqual(store.orderedVisiblePanes.count, 3)
        XCTAssertTrue(store.addPane(.android))
        XCTAssertEqual(store.paneCount(of: .android), 2)
        XCTAssertEqual(store.orderedVisiblePanes.count, 4)
        XCTAssertTrue(store.addPane(.iOS))

        let restored = WorkspaceStore(defaults: defaults)
        XCTAssertEqual(restored.paneCount(of: .android), 2)
        XCTAssertEqual(restored.orderedVisiblePanes.count, 5)
    }

    func testLaunchingFiveAndroidEmulatorsUsesFiveDistinctPanes() async {
        let devices = (1...5).map { index in
            LaunchableDevice(
                id: "Pixel_\(index)",
                source: .android,
                name: "Pixel \(index)",
                runtime: nil,
                state: .shutdown
            )
        }
        let client = RecordingDeviceClient(
            source: .android,
            devices: devices,
            launchDelay: .milliseconds(50)
        )
        let store = WorkspaceStore(
            defaults: defaults,
            androidClient: client,
            iOSClient: RecordingDeviceClient(source: .iOS, devices: [])
        )
        store.androidDevices.refreshDevices()
        try? await Task.sleep(for: .milliseconds(30))

        for device in devices {
            XCTAssertTrue(store.launchInNewPane(device))
        }

        XCTAssertEqual(store.paneCount(of: .android), 5)
        XCTAssertEqual(
            (0..<5).compactMap {
                store.captureSession(for: .android, slot: $0)?.pendingLaunchDeviceID
            },
            devices.map(\.id)
        )
        XCTAssertFalse(store.canLaunchAnotherGuest(for: .android))
        XCTAssertFalse(store.launchInNewPane(devices[0]))
        try? await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(Set(client.launchedIDs), Set(devices.map(\.id)))
    }

    func testShutdownAllAndroidGuestsClearsPanesAndStopsEachGuest() async {
        let devices = (1...2).map { index in
            LaunchableDevice(
                id: "Pixel_\(index)",
                source: .android,
                name: "Pixel \(index)",
                runtime: nil,
                state: .shutdown
            )
        }
        let client = RecordingDeviceClient(source: .android, devices: devices)
        let store = WorkspaceStore(
            defaults: defaults,
            androidClient: client,
            iOSClient: RecordingDeviceClient(source: .iOS, devices: [])
        )
        store.androidDevices.refreshDevices()
        try? await Task.sleep(for: .milliseconds(30))
        for device in devices { XCTAssertTrue(store.launchInNewPane(device)) }

        store.shutdownAllGuests(for: .android)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(Set(client.shutDownIDs), Set(devices.map(\.id)))
        XCTAssertTrue(store.androidCaptureSessions.allSatisfy {
            $0.pendingLaunchDeviceID == nil && $0.selectedDeviceID == nil
        })
    }

    func testClosingTwoBootingAndroidPanesStopsBothGuests() async {
        let devices = (1...2).map { index in
            LaunchableDevice(
                id: "Pixel_\(index)",
                source: .android,
                name: "Pixel \(index)",
                runtime: nil,
                state: .shutdown
            )
        }
        let client = RecordingDeviceClient(source: .android, devices: devices)
        let store = WorkspaceStore(
            defaults: defaults,
            androidClient: client,
            iOSClient: RecordingDeviceClient(source: .iOS, devices: [])
        )
        store.androidDevices.refreshDevices()
        try? await Task.sleep(for: .milliseconds(30))
        for device in devices { XCTAssertTrue(store.launchInNewPane(device)) }

        let paneIDs = store.orderedVisiblePanes
            .filter { $0.viewerSource == .android }
            .map(\.id)
        for id in paneIDs { XCTAssertTrue(store.closePane(id: id)) }
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(Set(client.shutDownIDs), Set(devices.map(\.id)))
        XCTAssertEqual(store.paneCount(of: .android), 0)
    }

    func testRemoveExtraPaneKeepsPrimary() {
        let store = WorkspaceStore(defaults: defaults)
        XCTAssertTrue(store.addPane(.iOS))
        XCTAssertTrue(store.removeExtraPane(.iOS))
        XCTAssertEqual(store.paneCount(of: .iOS), 1)
        XCTAssertTrue(store.isVisible(.iOS))
    }

    func testRemovePaneByIDOnlyRemovesExtraSlot() {
        let store = WorkspaceStore(defaults: defaults)
        XCTAssertTrue(store.addPane(.android))
        let extraID = store.orderedVisiblePanes.first {
            $0.source == ViewerSource.android.rawValue && $0.slot >= 1
        }?.id
        XCTAssertNotNil(extraID)
        let primaryID = store.orderedVisiblePanes.first {
            $0.source == ViewerSource.android.rawValue && $0.slot == 0
        }?.id
        XCTAssertNotNil(primaryID)

        XCTAssertFalse(store.removePane(id: primaryID!))
        XCTAssertEqual(store.paneCount(of: .android), 2)

        XCTAssertTrue(store.closePane(id: primaryID!))
        XCTAssertEqual(store.paneCount(of: .android), 1)

        XCTAssertTrue(store.removePane(id: extraID!))
        XCTAssertEqual(store.paneCount(of: .android), 0)
        XCTAssertFalse(store.isVisible(.android))
    }

    func testCloseOnlyPlatformPaneHidesColumnWhenOthersRemain() {
        let store = WorkspaceStore(defaults: defaults)
        let primaryID = store.orderedVisiblePanes.first {
            $0.source == ViewerSource.iOS.rawValue && $0.slot == 0
        }?.id
        XCTAssertNotNil(primaryID)
        XCTAssertTrue(store.closePane(id: primaryID!))
        XCTAssertFalse(store.isVisible(.iOS))
        XCTAssertEqual(store.paneCount(of: .iOS), 0)
    }

    func testClosePrimaryPaneLeavesOtherAndroidPane() {
        let store = WorkspaceStore(defaults: defaults)
        store.setVisible(false, for: .web)
        store.setVisible(false, for: .iOS)
        XCTAssertTrue(store.addPane(.android))
        let primaryID = store.orderedVisiblePanes.first {
            $0.source == ViewerSource.android.rawValue && $0.slot == 0
        }?.id
        XCTAssertNotNil(primaryID)
        XCTAssertTrue(store.closePane(id: primaryID!))
        XCTAssertEqual(store.paneCount(of: .android), 1)
        XCTAssertTrue(store.isVisible(.android))
    }

    func testCloseOnlyVisiblePaneClearsWithoutHidingWorkspace() {
        let store = WorkspaceStore(defaults: defaults)
        store.setVisible(false, for: .android)
        store.setVisible(false, for: .web)
        XCTAssertEqual(store.orderedVisiblePanes.count, 1)
        let primaryID = store.orderedVisiblePanes.first?.id
        XCTAssertNotNil(primaryID)
        XCTAssertTrue(store.closePane(id: primaryID!))
        XCTAssertEqual(store.orderedVisiblePanes.count, 1)
        XCTAssertTrue(store.isVisible(.iOS))
        XCTAssertNil(store.iOSCapture.selectedDeviceID)
    }

    func testHidingPlatformRemovesAllItsPanes() {
        let store = WorkspaceStore(defaults: defaults)
        XCTAssertTrue(store.addPane(.android))
        store.setVisible(false, for: .android)
        XCTAssertEqual(store.paneCount(of: .android), 0)
        XCTAssertFalse(store.isVisible(.android))
        XCTAssertEqual(store.orderedVisiblePanes.count, 2)
    }

    func testCaptureModeDefaultsToDirect() {
        let store = WorkspaceStore(defaults: defaults)
        XCTAssertEqual(store.captureMode, .direct)
    }

    func testCaptureModePersists() {
        let store = WorkspaceStore(defaults: defaults)
        store.setCaptureMode(.classic)

        let restored = WorkspaceStore(defaults: defaults)

        XCTAssertEqual(restored.captureMode, .classic)
    }

    func testScreenshotPlatformLabelsPersist() {
        let store = WorkspaceStore(defaults: defaults)
        XCTAssertFalse(store.screenshotPlatformLabelsEnabled)

        store.setScreenshotPlatformLabelsEnabled(true)

        let restored = WorkspaceStore(defaults: defaults)
        XCTAssertTrue(restored.screenshotPlatformLabelsEnabled)
    }

    func testClearPendingLaunchScopedToDeviceID() {
        let store = WorkspaceStore(defaults: defaults)
        XCTAssertTrue(store.addPane(.android))

        store.androidCapture.prepareForPendingLaunch(
            named: "Pixel 7",
            deviceID: "pixel7"
        )
        store.androidCaptureSecondary.prepareForPendingLaunch(
            named: "Pixel 8",
            deviceID: "pixel8"
        )

        store.clearPendingLaunch(for: .android, deviceID: "pixel7")

        XCTAssertNil(store.androidCapture.pendingLaunchName)
        XCTAssertNil(store.androidCapture.pendingLaunchDeviceID)
        XCTAssertEqual(store.androidCaptureSecondary.pendingLaunchName, "Pixel 8")
        XCTAssertEqual(store.androidCaptureSecondary.pendingLaunchDeviceID, "pixel8")
    }

    func testPendingAndroidLaunchWaitsForMatchingAVD() {
        let session = WindowCaptureSession(source: .android)
        session.prepareForPendingLaunch(named: "Pixel 2", deviceID: "Pixel_2")
        let first = StreamedDevice(
            id: "emulator-5554",
            name: "Pixel 1",
            source: .android,
            pixelSize: nil,
            kind: .androidEmulator
        )
        let second = StreamedDevice(
            id: "emulator-5556",
            name: "Pixel 2",
            source: .android,
            pixelSize: nil,
            kind: .androidEmulator
        )

        XCTAssertNil(session.preferredDevice(
            in: [first], previousSelection: nil, occupied: []
        ))
        XCTAssertEqual(session.preferredDevice(
            in: [first, second], previousSelection: nil, occupied: []
        )?.id, second.id)
    }

    func testLaunchLightSimBindsPendingCaptureToGuestUDID() async {
        let light = LaunchableDevice(
            id: "lightsim:UDID-IPHONE",
            source: .iOS,
            name: "Light Sim — iPhone 16",
            runtime: "iOS 26",
            state: .shutdown
        )
        let store = WorkspaceStore(
            defaults: defaults,
            androidClient: RecordingDeviceClient(source: .android, devices: []),
            iOSClient: RecordingDeviceClient(source: .iOS, devices: [light])
        )

        store.iOSDevices.refreshDevices()
        try? await Task.sleep(for: .milliseconds(30))

        store.launch(light, into: store.iOSCapture)

        XCTAssertEqual(store.iOSCapture.pendingLaunchName, "Light Sim — iPhone 16")
        XCTAssertEqual(store.iOSCapture.pendingLaunchDeviceID, "UDID-IPHONE")
    }

    func testTerminateRunningGuestsShutsDownLaunchedAndBootedDevices() async {
        let android = LaunchableDevice(
            id: "Pixel_7",
            source: .android,
            name: "Pixel 7",
            runtime: nil,
            state: .shutdown
        )
        let alreadyRunning = LaunchableDevice(
            id: "Pixel_8",
            source: .android,
            name: "Pixel 8",
            runtime: nil,
            state: .booted
        )
        let simulator = LaunchableDevice(
            id: "UDID-IPHONE",
            source: .iOS,
            name: "iPhone 16",
            runtime: "iOS 26",
            state: .shutdown
        )
        let androidClient = RecordingDeviceClient(
            source: .android,
            devices: [android, alreadyRunning]
        )
        let iOSClient = RecordingDeviceClient(
            source: .iOS,
            devices: [simulator]
        )
        let store = WorkspaceStore(
            defaults: defaults,
            androidClient: androidClient,
            iOSClient: iOSClient
        )

        store.androidDevices.refreshDevices()
        store.iOSDevices.refreshDevices()
        try? await Task.sleep(for: .milliseconds(30))

        store.launch(android, into: store.androidCapture)
        store.launch(simulator, into: store.iOSCapture)
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(store.androidDevices.sessionStartedGuestIDs, ["Pixel_7"])
        XCTAssertEqual(store.iOSDevices.sessionStartedGuestIDs, ["UDID-IPHONE"])

        await store.terminateSessionStartedGuests()

        XCTAssertEqual(androidClient.shutDownIDs, ["Pixel_7", "Pixel_8"])
        XCTAssertEqual(iOSClient.shutDownIDs, ["UDID-IPHONE"])
        XCTAssertEqual(store.androidDevices.sessionStartedGuestIDs, [])
        XCTAssertEqual(store.iOSDevices.sessionStartedGuestIDs, [])

        await store.terminateSessionStartedGuests()
        XCTAssertEqual(androidClient.shutDownIDs, ["Pixel_7", "Pixel_8"])
        XCTAssertEqual(iOSClient.shutDownIDs, ["UDID-IPHONE"])
    }

    func testPlayMenuShutdownRemovesGuestFromSessionSet() async {
        let android = LaunchableDevice(
            id: "Pixel_7",
            source: .android,
            name: "Pixel 7",
            runtime: nil,
            state: .shutdown
        )
        let androidClient = RecordingDeviceClient(
            source: .android,
            devices: [android]
        )
        let iOSClient = RecordingDeviceClient(source: .iOS, devices: [])
        let store = WorkspaceStore(
            defaults: defaults,
            androidClient: androidClient,
            iOSClient: iOSClient
        )

        store.androidDevices.refreshDevices()
        try? await Task.sleep(for: .milliseconds(30))
        store.launch(android, into: store.androidCapture)
        try? await Task.sleep(for: .milliseconds(20))

        store.shutdownGuest(android)
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(store.androidDevices.sessionStartedGuestIDs, [])
        await store.terminateSessionStartedGuests()
        XCTAssertEqual(androidClient.shutDownIDs, ["Pixel_7"])
    }

    func testLaunchableDeviceMatchesAndroidPaneGuestByAVDName() {
        let avd = LaunchableDevice(
            id: "Pixel_7",
            source: .android,
            name: "Pixel 7",
            runtime: nil,
            state: .booted
        )
        let paneGuest = StreamedDevice(
            id: "emulator-5554",
            name: "Pixel 7",
            source: .android,
            pixelSize: nil,
            kind: .androidEmulator
        )
        let pendingGuest = StreamedDevice(
            id: "Pixel_7",
            name: "Pixel 7",
            source: .android,
            pixelSize: nil,
            kind: .androidEmulator
        )
        let other = StreamedDevice(
            id: "emulator-5556",
            name: "Pixel 8",
            source: .android,
            pixelSize: nil,
            kind: .androidEmulator
        )

        XCTAssertTrue(avd.matchesSessionGuest(paneGuest))
        XCTAssertTrue(avd.matchesSessionGuest(pendingGuest))
        XCTAssertFalse(avd.matchesSessionGuest(other))
    }

    func testSessionGuestClosePromptListsStartedGuests() async {
        let android = LaunchableDevice(
            id: "Pixel_7",
            source: .android,
            name: "Pixel 7",
            runtime: nil,
            state: .shutdown
        )
        let simulator = LaunchableDevice(
            id: "UDID-IPHONE",
            source: .iOS,
            name: "iPhone 16",
            runtime: "iOS 26",
            state: .shutdown
        )
        let store = WorkspaceStore(
            defaults: defaults,
            androidClient: RecordingDeviceClient(
                source: .android,
                devices: [android]
            ),
            iOSClient: RecordingDeviceClient(
                source: .iOS,
                devices: [simulator]
            )
        )
        XCTAssertNil(store.sessionGuestClosePrompt)

        store.androidDevices.refreshDevices()
        store.iOSDevices.refreshDevices()
        try? await Task.sleep(for: .milliseconds(30))
        store.launch(android, into: store.androidCapture)
        store.launch(simulator, into: store.iOSCapture)

        let prompt = store.sessionGuestClosePrompt
        XCTAssertEqual(prompt?.title, "Close Viewport?")
        XCTAssertEqual(prompt?.confirmButtonTitle, "Close and Shut Down")
        XCTAssertEqual(
            prompt?.message,
            "Closing Viewport will also shut down the running emulators and Simulators: Pixel 7 and iPhone 16."
        )
    }

    func testSessionGuestClosePromptCopy() {
        XCTAssertNil(SessionGuestClosePrompt.make(androidNames: [], iOSNames: []))

        let emulator = SessionGuestClosePrompt.make(
            androidNames: ["Pixel 7"],
            iOSNames: []
        )
        XCTAssertEqual(
            emulator?.message,
            "Closing Viewport will also shut down the running emulator: Pixel 7."
        )

        let simulators = SessionGuestClosePrompt.make(
            androidNames: [],
            iOSNames: ["iPhone 16", "iPad"]
        )
        XCTAssertEqual(
            simulators?.message,
            "Closing Viewport will also shut down the running Simulators: iPhone 16 and iPad."
        )
    }

    func testClosePromptIncludesAlreadyBootedGuests() async {
        let booted = LaunchableDevice(
            id: "Pixel_8",
            source: .android,
            name: "Pixel 8",
            runtime: nil,
            state: .booted
        )
        let store = WorkspaceStore(
            defaults: defaults,
            androidClient: RecordingDeviceClient(
                source: .android,
                devices: [booted]
            ),
            iOSClient: RecordingDeviceClient(source: .iOS, devices: [])
        )
        store.androidDevices.refreshDevices()
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(
            store.sessionGuestClosePrompt?.message,
            "Closing Viewport will also shut down the running emulator: Pixel 8."
        )
    }

    func testClosePromptIncludesPaneGuestWithoutPlayLaunch() {
        let store = WorkspaceStore(
            defaults: defaults,
            androidClient: RecordingDeviceClient(source: .android, devices: []),
            iOSClient: RecordingDeviceClient(source: .iOS, devices: [])
        )
        store.iOSCapture.prepareForPendingLaunch(
            named: "iPhone 17e",
            deviceID: "UDID-17E"
        )

        XCTAssertEqual(
            store.sessionGuestClosePrompt?.message,
            "Closing Viewport will also shut down the running Simulator: iPhone 17e."
        )
    }
}

@MainActor
private final class RecordingDeviceClient: DeviceClient {
    let source: ViewerSource
    private let devices: [LaunchableDevice]
    private let launchDelay: Duration
    private(set) var launchedIDs: [String] = []
    private(set) var shutDownIDs: [String] = []

    init(
        source: ViewerSource,
        devices: [LaunchableDevice],
        launchDelay: Duration = .zero
    ) {
        self.source = source
        self.devices = devices
        self.launchDelay = launchDelay
    }

    func listDevices() async throws -> [LaunchableDevice] {
        devices
    }

    func launch(_ device: LaunchableDevice) async throws {
        if launchDelay > .zero { try await Task.sleep(for: launchDelay) }
        launchedIDs.append(device.id)
    }

    func shutdown(_ device: LaunchableDevice) async throws {
        shutDownIDs.append(device.id)
    }
}
