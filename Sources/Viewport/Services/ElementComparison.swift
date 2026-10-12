import CoreGraphics
import Foundation

/// Finds the same control on other platforms by its name, text, or identifier.
enum ElementMatcher {
    static let minimumScore = 0.5

    struct Match: Equatable {
        let element: InspectedElement
        let score: Double
    }

    /// Lowercased, accent-folded, punctuation-free form for comparison.
    static func normalizedKey(_ value: String?) -> String {
        guard let value else { return "" }
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars)
            .split(separator: " ")
            .joined(separator: " ")
    }

    static func score(_ a: InspectedElement, _ b: InspectedElement) -> Double {
        var best = 0.0
        let aNames = [a.label, a.text].map(normalizedKey).filter { !$0.isEmpty }
        let bNames = [b.label, b.text].map(normalizedKey).filter { !$0.isEmpty }
        for aName in aNames {
            for bName in bNames {
                best = max(best, nameScore(aName, bName))
            }
        }
        let aID = identifierKey(a.identifier)
        let bID = identifierKey(b.identifier)
        if !aID.isEmpty, aID == bID {
            best = max(best, 0.95)
        }
        guard best > 0 else { return 0 }
        if a.role == b.role {
            best = min(best + 0.05, 1)
        } else if a.role.isInteractive != b.role.isInteractive {
            best -= 0.1
        }
        return max(best, 0)
    }

    static func bestMatch(
        for element: InspectedElement,
        in snapshot: ElementSnapshot
    ) -> Match? {
        var best: Match?
        for candidate in snapshot.elements {
            let value = score(element, candidate)
            guard value >= minimumScore else { continue }
            if let current = best {
                // Ties go to the element nearest the same relative position.
                if value > current.score + 0.001
                    || (abs(value - current.score) <= 0.001
                        && distance(element, candidate) < distance(element, current.element)) {
                    best = Match(element: candidate, score: value)
                }
            } else {
                best = Match(element: candidate, score: value)
            }
        }
        return best
    }

    private static func nameScore(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let shorter = a.count <= b.count ? a : b
        let longer = a.count <= b.count ? b : a
        if shorter.count >= 3, longer.contains(shorter) {
            return 0.55 + 0.3 * Double(shorter.count) / Double(longer.count)
        }
        let aTokens = Set(a.split(separator: " "))
        let bTokens = Set(b.split(separator: " "))
        let union = aTokens.union(bTokens)
        guard !union.isEmpty else { return 0 }
        let jaccard = Double(aTokens.intersection(bTokens).count) / Double(union.count)
        return jaccard >= 0.5 ? 0.4 + 0.4 * jaccard : 0
    }

    /// `com.app:id/sign_in_button`, `signInButton`, and `sign-in-button` compare equal.
    static func identifierKey(_ identifier: String?) -> String {
        guard var identifier, !identifier.isEmpty else { return "" }
        if let range = identifier.range(of: ":id/") {
            identifier = String(identifier[range.upperBound...])
        }
        return identifier.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func distance(_ a: InspectedElement, _ b: InspectedElement) -> CGFloat {
        hypot(a.frame.midX - b.frame.midX, a.frame.midY - b.frame.midY)
    }
}

/// Differences between one element and its counterparts on other platforms.
enum ElementParityCheck {
    struct Finding: Equatable, Identifiable {
        enum Kind: Equatable {
            case missing
            case labelDiffers
            case roleDiffers
            case missingLabel
        }

        let kind: Kind
        let source: ViewerSource
        let message: String

        var id: String { "\(source.rawValue)-\(message)" }
    }

    static func findings(
        for element: InspectedElement,
        in source: ViewerSource,
        counterparts: [(ViewerSource, ElementMatcher.Match?)]
    ) -> [Finding] {
        var findings: [Finding] = []
        let name = ElementMatcher.normalizedKey(element.label ?? element.text)
        for (otherSource, match) in counterparts {
            guard let match else {
                findings.append(Finding(
                    kind: .missing,
                    source: otherSource,
                    message: "No matching element found on \(otherSource.title)."
                ))
                continue
            }
            let other = match.element
            if !other.hasAccessibleName, element.hasAccessibleName {
                findings.append(Finding(
                    kind: .missingLabel,
                    source: otherSource,
                    message: "\(otherSource.title) has no accessible name for this \(other.role.title.lowercased())."
                ))
            } else {
                let otherName = ElementMatcher.normalizedKey(other.label ?? other.text)
                if !name.isEmpty, !otherName.isEmpty, name != otherName {
                    findings.append(Finding(
                        kind: .labelDiffers,
                        source: otherSource,
                        message: "\(otherSource.title) says “\(other.label ?? other.text ?? "")” instead of “\(element.label ?? element.text ?? "")”."
                    ))
                }
            }
            if other.role != element.role,
               other.role.isInteractive || element.role.isInteractive {
                findings.append(Finding(
                    kind: .roleDiffers,
                    source: otherSource,
                    message: "\(source.title) exposes a \(element.role.title.lowercased()); \(otherSource.title) exposes a \(other.role.title.lowercased())."
                ))
            }
        }
        return findings
    }
}

/// Lightweight accessibility checks that apply on every platform.
enum AccessibilityAudit {
    struct Issue: Identifiable, Equatable {
        enum Kind: String, Equatable {
            case missingLabel
            case smallTarget
        }

        let kind: Kind
        let elementID: Int
        let message: String

        var id: String { "\(kind.rawValue)-\(elementID)" }

        var systemImage: String {
            switch kind {
            case .missingLabel: "text.badge.xmark"
            case .smallTarget: "hand.tap"
            }
        }
    }

    /// Apple HIG 44pt, Material 48dp, WCAG 2.2 AA 24px.
    static func minimumTargetSize(for source: ViewerSource) -> CGFloat {
        switch source {
        case .iOS: 44
        case .android: 48
        case .web: 24
        }
    }

    static func issues(in snapshot: ElementSnapshot) -> [Issue] {
        let minimum = minimumTargetSize(for: snapshot.source)
        var issues: [Issue] = []
        for element in snapshot.elements where element.isInteractive && element.isEnabled {
            if !element.hasAccessibleName {
                issues.append(Issue(
                    kind: .missingLabel,
                    elementID: element.id,
                    message: "\(element.role.title) has no accessible name"
                        + (element.identifier.map { " (\($0))" } ?? "")
                ))
            }
            // WCAG 2.5.8 exempts links inside a sentence; web text links are inline.
            if snapshot.source == .web, element.role == .link { continue }
            let shortSide = min(element.size.width, element.size.height)
            // Text fields and sliders grow along one axis; check height only.
            let checked = element.role == .textField || element.role == .slider
                ? element.size.height
                : shortSide
            if checked > 0, checked + 0.5 < minimum {
                issues.append(Issue(
                    kind: .smallTarget,
                    elementID: element.id,
                    message: "“\(element.displayName)” is \(Int(element.size.width.rounded()))×\(Int(element.size.height.rounded())) \(snapshot.unit); aim for \(Int(minimum)) \(snapshot.unit)"
                ))
            }
        }
        return issues
    }
}
