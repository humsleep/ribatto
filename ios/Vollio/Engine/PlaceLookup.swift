import AVFoundation
import CoreLocation

/// Where a match was filmed, taken from the video's own metadata.
///
/// iPhone recordings carry an ISO 6709 location tag, and Photos keeps the same
/// thing on the asset. Turning coordinates into a readable name needs the
/// network, so that step is best-effort: without it the session still works,
/// it just shows no place.
enum PlaceLookup {

    /// Coordinate stored inside the movie file itself.
    static func coordinate(in asset: AVAsset) async -> CLLocationCoordinate2D? {
        guard let metadata = try? await asset.load(.metadata) else { return nil }
        for item in metadata {
            let isLocation = item.commonKey == .commonKeyLocation
                || item.identifier == .quickTimeMetadataLocationISO6709
            guard isLocation,
                  let raw = try? await item.load(.stringValue),
                  let coordinate = parseISO6709(raw) else { continue }
            return coordinate
        }
        return nil
    }

    /// "+37.5665+126.9780+050.000/" → lat/lon
    static func parseISO6709(_ text: String) -> CLLocationCoordinate2D? {
        // leading sign is required on each component, which makes them easy to split
        let scanner = Scanner(string: text)
        guard let lat = scanner.scanDouble(), let lon = scanner.scanDouble() else { return nil }
        guard abs(lat) <= 90, abs(lon) <= 180, !(lat == 0 && lon == 0) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Short, human place name. Returns nil offline — callers treat it as
    /// "unknown" rather than failing.
    static func placeName(for coordinate: CLLocationCoordinate2D,
                          locale: Locale) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude,
                                  longitude: coordinate.longitude)
        // kept in a local: a temporary geocoder can be released mid-request,
        // which silently cancels it
        let geocoder = CLGeocoder()
        guard let marks = try? await geocoder.reverseGeocodeLocation(
                location, preferredLocale: locale),
              let mark = marks.first else { return nil }

        // prefer a named spot (a park or court), then the district
        if let poi = mark.areasOfInterest?.first, !poi.isEmpty { return poi }
        let parts = [mark.locality, mark.subLocality].compactMap { $0 }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        return mark.name ?? mark.administrativeArea
    }
}
