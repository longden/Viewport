import Foundation
import WebKit

enum WebsiteDataScope: Equatable {
    case cookies
    case allData
}

@MainActor
protocol WebsiteDataClearing {
    func clear(_ scope: WebsiteDataScope) async
}

@MainActor
struct WebsiteDataCleaner: WebsiteDataClearing {
    let dataStore: WKWebsiteDataStore

    init() {
        dataStore = .default()
    }

    init(dataStore: WKWebsiteDataStore) {
        self.dataStore = dataStore
    }

    func clear(_ scope: WebsiteDataScope) async {
        let dataTypes: Set<String>

        switch scope {
        case .cookies:
            dataTypes = [WKWebsiteDataTypeCookies]
        case .allData:
            dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        }

        await withCheckedContinuation { continuation in
            dataStore.removeData(
                ofTypes: dataTypes,
                modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }
    }
}
