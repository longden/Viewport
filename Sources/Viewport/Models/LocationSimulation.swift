import CoreLocation
import Foundation

struct GeoCoordinate: Equatable, Hashable, Codable, Sendable {
    var latitude: Double
    var longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude)
            && (-180...180).contains(longitude)
    }

    /// `lat,lon` with `.` decimals, as `simctl location` expects.
    var simctlArgument: String {
        "\(Self.format(latitude)),\(Self.format(longitude))"
    }

    var displayText: String {
        "\(Self.format(latitude, digits: 5)), \(Self.format(longitude, digits: 5))"
    }

    /// Accepts `37.33, -122.01`, `37.33 -122.01`, or `37.33;-122.01`.
    static func parse(_ text: String) -> GeoCoordinate? {
        let parts = text
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
            .map(String.init)
        guard parts.count == 2,
              let latitude = Double(parts[0]),
              let longitude = Double(parts[1]) else {
            return nil
        }
        let coordinate = GeoCoordinate(latitude: latitude, longitude: longitude)
        return coordinate.isValid ? coordinate : nil
    }

    static func format(_ value: Double, digits: Int = 6) -> String {
        String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

struct LocationPreset: Identifiable, Equatable {
    let name: String
    let coordinate: GeoCoordinate

    var id: String { name }

    static let all: [LocationPreset] = [
        LocationPreset(name: "Cupertino", coordinate: GeoCoordinate(latitude: 37.334_900, longitude: -122.009_020)),
        LocationPreset(name: "San Francisco", coordinate: GeoCoordinate(latitude: 37.779_300, longitude: -122.419_200)),
        LocationPreset(name: "New York", coordinate: GeoCoordinate(latitude: 40.758_000, longitude: -73.985_500)),
        LocationPreset(name: "London", coordinate: GeoCoordinate(latitude: 51.507_400, longitude: -0.127_800)),
        LocationPreset(name: "Berlin", coordinate: GeoCoordinate(latitude: 52.520_000, longitude: 13.405_000)),
        LocationPreset(name: "Paris", coordinate: GeoCoordinate(latitude: 48.856_600, longitude: 2.352_200)),
        LocationPreset(name: "Tokyo", coordinate: GeoCoordinate(latitude: 35.681_200, longitude: 139.767_100)),
        LocationPreset(name: "Singapore", coordinate: GeoCoordinate(latitude: 1.283_300, longitude: 103.850_700)),
        LocationPreset(name: "Sydney", coordinate: GeoCoordinate(latitude: -33.856_800, longitude: 151.215_300)),
        LocationPreset(name: "São Paulo", coordinate: GeoCoordinate(latitude: -23.550_500, longitude: -46.633_300)),
        LocationPreset(name: "Cape Town", coordinate: GeoCoordinate(latitude: -33.924_900, longitude: 18.424_100)),
        LocationPreset(name: "Dubai", coordinate: GeoCoordinate(latitude: 25.197_200, longitude: 55.274_400))
    ]
}

enum RouteSpeed: String, CaseIterable, Identifiable {
    case walk
    case run
    case cycle
    case city
    case highway

    var id: String { rawValue }

    var title: String {
        switch self {
        case .walk: "Walk"
        case .run: "Run"
        case .cycle: "Cycle"
        case .city: "City drive"
        case .highway: "Highway"
        }
    }

    var metersPerSecond: Double {
        switch self {
        case .walk: 1.4
        case .run: 3.0
        case .cycle: 6.0
        case .city: 13.0
        case .highway: 30.0
        }
    }
}

struct LocationRoute: Equatable {
    var name: String
    var points: [GeoCoordinate]

    /// Distance (m) from the first point to each point.
    private(set) var cumulativeDistances: [Double]

    init(name: String, points: [GeoCoordinate]) {
        self.name = name
        self.points = points
        var cumulative: [Double] = points.isEmpty ? [] : [0]
        for index in points.indices.dropFirst() {
            cumulative.append(
                cumulative[index - 1] + GeoMath.distance(points[index - 1], points[index])
            )
        }
        cumulativeDistances = cumulative
    }

    var totalDistance: Double {
        cumulativeDistances.last ?? 0
    }

    var isPlayable: Bool {
        points.count >= 2 && totalDistance > 0
    }

    func duration(speed: Double) -> TimeInterval {
        guard speed > 0 else { return 0 }
        return totalDistance / speed
    }

    /// Position after travelling `distance` metres along the route (clamped).
    func coordinate(atDistance distance: Double) -> GeoCoordinate? {
        guard let first = points.first else { return nil }
        guard points.count > 1, distance > 0 else { return first }
        guard distance < totalDistance else { return points.last }
        // Last index whose cumulative distance is <= target.
        var low = 0
        var high = cumulativeDistances.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if cumulativeDistances[mid] <= distance {
                low = mid
            } else {
                high = mid - 1
            }
        }
        let segmentStart = cumulativeDistances[low]
        let segmentLength = cumulativeDistances[low + 1] - segmentStart
        let fraction = segmentLength > 0 ? (distance - segmentStart) / segmentLength : 0
        return GeoMath.interpolate(points[low], points[low + 1], fraction: fraction)
    }

    func coordinate(atElapsed elapsed: TimeInterval, speed: Double) -> GeoCoordinate? {
        coordinate(atDistance: max(elapsed, 0) * max(speed, 0))
    }
}

enum GeoMath {
    static let earthRadius = 6_371_000.0

    /// Great-circle distance in metres.
    static func distance(_ a: GeoCoordinate, _ b: GeoCoordinate) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Linear interpolation; route segments are short enough for this to track the path.
    static func interpolate(
        _ a: GeoCoordinate,
        _ b: GeoCoordinate,
        fraction: Double
    ) -> GeoCoordinate {
        let t = min(max(fraction, 0), 1)
        return GeoCoordinate(
            latitude: a.latitude + (b.latitude - a.latitude) * t,
            longitude: a.longitude + (b.longitude - a.longitude) * t
        )
    }
}
