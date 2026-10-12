import Foundation

enum GPXRouteParserError: LocalizedError, Equatable {
    case unreadable
    case noPoints

    var errorDescription: String? {
        switch self {
        case .unreadable:
            "That file isn’t a readable GPX file."
        case .noPoints:
            "The GPX file has no track, route, or waypoint coordinates."
        }
    }
}

/// Reads track points, then route points, then waypoints from a GPX file.
enum GPXRouteParser {
    static func parse(_ data: Data, fallbackName: String = "Route") throws -> LocationRoute {
        let delegate = GPXParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw GPXRouteParserError.unreadable
        }
        let points = !delegate.trackPoints.isEmpty
            ? delegate.trackPoints
            : (!delegate.routePoints.isEmpty ? delegate.routePoints : delegate.waypoints)
        guard !points.isEmpty else {
            throw GPXRouteParserError.noPoints
        }
        let name = delegate.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return LocationRoute(
            name: (name?.isEmpty == false ? name : nil) ?? fallbackName,
            points: points
        )
    }

    static func parse(contentsOf url: URL) throws -> LocationRoute {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw GPXRouteParserError.unreadable
        }
        return try parse(data, fallbackName: url.deletingPathExtension().lastPathComponent)
    }
}

private final class GPXParserDelegate: NSObject, XMLParserDelegate {
    var trackPoints: [GeoCoordinate] = []
    var routePoints: [GeoCoordinate] = []
    var waypoints: [GeoCoordinate] = []
    var name: String?

    private var elementStack: [String] = []
    private var nameBuffer = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let element = Self.localName(elementName)
        elementStack.append(element)
        switch element {
        case "trkpt", "rtept", "wpt":
            guard let latitude = attributeDict["lat"].flatMap(Double.init),
                  let longitude = attributeDict["lon"].flatMap(Double.init) else {
                return
            }
            let coordinate = GeoCoordinate(latitude: latitude, longitude: longitude)
            guard coordinate.isValid else { return }
            switch element {
            case "trkpt": trackPoints.append(coordinate)
            case "rtept": routePoints.append(coordinate)
            default: waypoints.append(coordinate)
            }
        case "name":
            nameBuffer = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if elementStack.last == "name" {
            nameBuffer += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let element = Self.localName(elementName)
        if element == "name", name == nil {
            // Prefer the track / route / metadata name over per-point names.
            let parent = elementStack.dropLast().last
            if parent == "trk" || parent == "rte" || parent == "metadata" || parent == "gpx" {
                name = nameBuffer
            }
        }
        if !elementStack.isEmpty {
            elementStack.removeLast()
        }
    }

    private static func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }
}
