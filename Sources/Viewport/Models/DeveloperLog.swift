import Foundation

enum DeveloperLogSource: String, CaseIterable, Identifiable {
    case web
    case android
    case iOS
    case build

    var id: String { rawValue }

    var title: String {
        switch self {
        case .web: "Web"
        case .android: "Android"
        case .iOS: "iOS"
        case .build: "Build"
        }
    }

    var systemImage: String {
        switch self {
        case .web: "globe"
        case .android: "apps.iphone"
        case .iOS: "iphone"
        case .build: "hammer"
        }
    }
}

enum DeveloperLogLevel: String, CaseIterable {
    case debug
    case info
    case warning
    case error
}

enum DeveloperLogRetention: Int, CaseIterable, Identifiable {
    case kilobytes128 = 131_072
    case kilobytes512 = 524_288
    case megabyte1 = 1_048_576
    case megabytes5 = 5_242_880

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .kilobytes128: "128 KB"
        case .kilobytes512: "512 KB"
        case .megabyte1: "1 MB"
        case .megabytes5: "5 MB"
        }
    }
}

struct DeveloperLogEntry: Identifiable, Equatable {
    let id: UInt64
    let timestamp: Date
    let source: DeveloperLogSource
    let level: DeveloperLogLevel
    let message: String
}

enum DeveloperLogStreamStatus: Equatable {
    case idle
    case connecting
    case streaming
    case unavailable(String)
    case failed(String)

    var label: String {
        switch self {
        case .idle: "Waiting"
        case .connecting: "Connecting"
        case .streaming: "Streaming"
        case let .unavailable(message), let .failed(message): message
        }
    }
}
