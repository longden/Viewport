import Foundation

/// Confirmation shown when closing Viewport while Simulators or emulators
/// are still running.
struct SessionGuestClosePrompt: Equatable, Sendable {
    let title: String
    let message: String
    let confirmButtonTitle: String

    static func make(
        androidNames: [String],
        iOSNames: [String]
    ) -> SessionGuestClosePrompt? {
        let names = androidNames + iOSNames
        guard !names.isEmpty else { return nil }

        let guestPhrase: String
        switch (androidNames.isEmpty, iOSNames.isEmpty) {
        case (false, false):
            guestPhrase = "the running emulators and Simulators"
        case (false, true):
            guestPhrase = androidNames.count == 1
                ? "the running emulator"
                : "the running emulators"
        case (true, false):
            guestPhrase = iOSNames.count == 1
                ? "the running Simulator"
                : "the running Simulators"
        case (true, true):
            return nil
        }

        return SessionGuestClosePrompt(
            title: "Close Viewport?",
            message: "Closing Viewport will also shut down \(guestPhrase): \(Self.joined(names)).",
            confirmButtonTitle: "Close and Shut Down"
        )
    }

    private static func joined(_ names: [String]) -> String {
        switch names.count {
        case 0:
            ""
        case 1:
            names[0]
        case 2:
            "\(names[0]) and \(names[1])"
        default:
            names.dropLast().joined(separator: ", ") + ", and \(names.last!)"
        }
    }
}
