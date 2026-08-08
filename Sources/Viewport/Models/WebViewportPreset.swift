import CoreGraphics
import Foundation

/// Fixed CSS viewport sizes for responsive testing in the web pane.
enum WebViewportPreset: String, CaseIterable, Identifiable, Codable {
    case fillPane

    // Phones (portrait CSS points)
    case iPhoneSE
    case iPhone16
    case iPhone17
    case iPhoneAir
    case iPhone16Plus
    case iPhone17ProMax

    // Tablets (portrait)
    case iPadMini
    case iPad
    case iPadPro11
    case iPadPro13

    // Desktop / laptop
    case laptop
    case desktop
    case desktopFullHD

    var id: String { rawValue }

    enum Category: String, CaseIterable {
        case fill
        case iPhone
        case iPad
        case desktop

        var title: String {
            switch self {
            case .fill:
                "Pane"
            case .iPhone:
                "iPhone"
            case .iPad:
                "iPad"
            case .desktop:
                "Desktop"
            }
        }
    }

    var category: Category {
        switch self {
        case .fillPane:
            .fill
        case .iPhoneSE, .iPhone16, .iPhone17, .iPhoneAir, .iPhone16Plus,
             .iPhone17ProMax:
            .iPhone
        case .iPadMini, .iPad, .iPadPro11, .iPadPro13:
            .iPad
        case .laptop, .desktop, .desktopFullHD:
            .desktop
        }
    }

    static func presets(in category: Category) -> [WebViewportPreset] {
        allCases.filter { $0.category == category }
    }

    var title: String {
        switch self {
        case .fillPane:
            "Fill pane"
        case .iPhoneSE:
            "iPhone SE"
        case .iPhone16:
            "iPhone 16"
        case .iPhone17:
            "iPhone 17 / Pro"
        case .iPhoneAir:
            "iPhone Air"
        case .iPhone16Plus:
            "iPhone 16 Plus"
        case .iPhone17ProMax:
            "iPhone 17 Pro Max"
        case .iPadMini:
            "iPad mini"
        case .iPad:
            "iPad Air"
        case .iPadPro11:
            "iPad Pro 11″"
        case .iPadPro13:
            "iPad Pro 13″"
        case .laptop:
            "Laptop"
        case .desktop:
            "Desktop"
        case .desktopFullHD:
            "Full HD"
        }
    }

    /// Logical CSS points. `nil` means the web view fills the pane.
    var size: CGSize? {
        switch self {
        case .fillPane:
            nil
        case .iPhoneSE:
            CGSize(width: 375, height: 667)
        case .iPhone16:
            CGSize(width: 393, height: 852)
        case .iPhone17:
            // iPhone 17 and 17 Pro share this display.
            CGSize(width: 402, height: 874)
        case .iPhoneAir:
            CGSize(width: 420, height: 912)
        case .iPhone16Plus:
            CGSize(width: 430, height: 932)
        case .iPhone17ProMax:
            CGSize(width: 440, height: 956)
        case .iPadMini:
            CGSize(width: 744, height: 1_133)
        case .iPad:
            CGSize(width: 820, height: 1_180)
        case .iPadPro11:
            CGSize(width: 834, height: 1_194)
        case .iPadPro13:
            CGSize(width: 1_024, height: 1_366)
        case .laptop:
            CGSize(width: 1_280, height: 800)
        case .desktop:
            CGSize(width: 1_440, height: 900)
        case .desktopFullHD:
            CGSize(width: 1_920, height: 1_080)
        }
    }

    var sizeLabel: String? {
        guard let size else { return nil }
        return "\(Int(size.width))×\(Int(size.height))"
    }

    var menuLabel: String {
        if let sizeLabel {
            return "\(title) · \(sizeLabel)"
        }
        return title
    }

    var systemImage: String {
        switch category {
        case .fill:
            "rectangle.dashed"
        case .iPhone:
            "iphone"
        case .iPad:
            "ipad"
        case .desktop:
            "desktopcomputer"
        }
    }

    var prefersMobileContent: Bool {
        switch category {
        case .fill, .desktop:
            false
        case .iPhone, .iPad:
            true
        }
    }

    /// Safari-like UA so sites that sniff browsers pick mobile/desktop layouts.
    var customUserAgent: String? {
        switch category {
        case .fill, .desktop:
            nil
        case .iPhone:
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1"
        case .iPad:
            "Mozilla/5.0 (iPad; CPU OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1"
        }
    }

    /// Maps legacy persisted raw values onto current cases.
    static func resolved(rawValue: String?) -> WebViewportPreset? {
        guard let rawValue else { return nil }
        if rawValue == "iPhone17Pro" {
            return .iPhone17
        }
        return WebViewportPreset(rawValue: rawValue)
    }

    /// Scale ≤ 1 so the CSS viewport stays exact when the pane is smaller.
    func scaleFitting(in available: CGSize) -> CGFloat {
        guard let size,
              size.width > 0,
              size.height > 0,
              available.width > 0,
              available.height > 0 else {
            return 1
        }
        return min(
            1,
            min(available.width / size.width, available.height / size.height)
        )
    }

    func fittedLayoutSize(in available: CGSize) -> CGSize {
        guard let size else { return available }
        let scale = scaleFitting(in: available)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}
