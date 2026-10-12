import Foundation
import Security

enum ProxyCertificateError: LocalizedError, Equatable {
    case unreadable
    case notACertificate

    var errorDescription: String? {
        switch self {
        case .unreadable:
            "The certificate file couldn’t be read."
        case .notACertificate:
            "That file isn’t a PEM or DER certificate."
        }
    }
}

/// A proxy's root CA, loaded from the PEM or DER file the user picked.
struct ProxyCertificate: Equatable {
    let url: URL
    let derData: Data

    var summary: String {
        guard let certificate = SecCertificateCreateWithData(nil, derData as CFData),
              let name = SecCertificateCopySubjectSummary(certificate) as String? else {
            return url.lastPathComponent
        }
        return name
    }

    var secCertificate: SecCertificate? {
        SecCertificateCreateWithData(nil, derData as CFData)
    }

    static func load(from url: URL) throws -> ProxyCertificate {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ProxyCertificateError.unreadable
        }
        guard let der = derData(from: data),
              SecCertificateCreateWithData(nil, der as CFData) != nil else {
            throw ProxyCertificateError.notACertificate
        }
        return ProxyCertificate(url: url, derData: der)
    }

    /// First certificate in a PEM file, or the data itself when it's DER.
    static func derData(from data: Data) -> Data? {
        if let text = String(data: data, encoding: .utf8),
           let begin = text.range(of: "-----BEGIN CERTIFICATE-----") {
            guard let end = text.range(
                of: "-----END CERTIFICATE-----",
                range: begin.upperBound..<text.endIndex
            ) else {
                return nil
            }
            let base64 = text[begin.upperBound..<end.lowerBound]
                .components(separatedBy: .whitespacesAndNewlines)
                .joined()
            return Data(base64Encoded: base64)
        }
        // DER certificates start with an ASN.1 SEQUENCE.
        return data.first == 0x30 ? data : nil
    }

    /// PEM text for pushing to Android's Downloads folder.
    var pemText: String {
        let body = derData.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(body)\n-----END CERTIFICATE-----\n"
    }

    /// Evaluates `trust` with this CA as an extra anchor (system roots still apply).
    func evaluate(_ trust: SecTrust) -> Bool {
        guard let secCertificate else { return false }
        SecTrustSetAnchorCertificates(trust, [secCertificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, false)
        return SecTrustEvaluateWithError(trust, nil)
    }
}
