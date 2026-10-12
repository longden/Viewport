import Foundation

/// Android emulator console network shaping (`network speed` / `network delay`).
enum NetworkProfile: String, CaseIterable, Identifiable {
    case unrestricted
    case lte
    case threeG
    case edge
    case gprs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unrestricted: "No throttling"
        case .lte: "LTE"
        case .threeG: "3G"
        case .edge: "EDGE"
        case .gprs: "GPRS (2G)"
        }
    }

    var detail: String {
        switch self {
        case .unrestricted: "Full speed, no added latency"
        case .lte: "~58 Mbps down, no added latency"
        case .threeG: "~384 kbps, 100–200 ms latency"
        case .edge: "~237 kbps, 80–400 ms latency"
        case .gprs: "~54 kbps, 150–550 ms latency"
        }
    }

    var emulatorSpeed: String {
        switch self {
        case .unrestricted: "full"
        case .lte: "lte"
        case .threeG: "umts"
        case .edge: "edge"
        case .gprs: "gprs"
        }
    }

    var emulatorDelay: String {
        switch self {
        case .unrestricted, .lte: "none"
        case .threeG: "umts"
        case .edge: "edge"
        case .gprs: "gprs"
        }
    }
}

enum ProxyPreset: String, CaseIterable, Identifiable {
    case proxyman
    case charles
    case mitmproxy
    case httpToolkit
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .proxyman: "Proxyman"
        case .charles: "Charles"
        case .mitmproxy: "mitmproxy"
        case .httpToolkit: "HTTP Toolkit"
        case .custom: "Custom"
        }
    }

    var defaultPort: Int? {
        switch self {
        case .proxyman: 9090
        case .charles: 8888
        case .mitmproxy: 8080
        case .httpToolkit: 8000
        case .custom: nil
        }
    }

    /// CA files these tools leave on disk by default, when known.
    func defaultCertificateURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        switch self {
        case .mitmproxy:
            home.appendingPathComponent(".mitmproxy/mitmproxy-ca-cert.pem")
        case .proxyman, .charles, .httpToolkit, .custom:
            nil
        }
    }
}

struct ProxySettings: Equatable {
    var host: String
    var port: Int

    var isValid: Bool {
        (1...65_535).contains(port) && Self.isValidHost(host)
    }

    /// Loopback proxies reach Android through `adb reverse` so the same address
    /// works on emulators and USB phones.
    var isLoopback: Bool {
        let lowered = host.trimmingCharacters(in: .whitespaces).lowercased()
        return lowered == "localhost" || lowered == "127.0.0.1" || lowered == "::1"
    }

    var trimmedHost: String {
        host.trimmingCharacters(in: .whitespaces)
    }

    /// `host:port` written to Android's `http_proxy` global setting.
    var androidProxyValue: String {
        isLoopback ? "127.0.0.1:\(port)" : "\(trimmedHost):\(port)"
    }

    static func isValidHost(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 253 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-:"))
        return trimmed.unicodeScalars.allSatisfy(allowed.contains)
    }
}
