import CoreLocation
import Foundation

struct LocationSample: Codable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double
    let timestamp: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Collects a deliberately sparse, on-device location trail and groups it by day.
/// Samples are kept for 90 days and never leave the device.
@Observable
final class LocationHistory: NSObject, CLLocationManagerDelegate {
    private(set) var authorizationStatus: CLAuthorizationStatus
    private(set) var samplesByDay: [String: [LocationSample]]

    private let manager = CLLocationManager()
    private let calendar = Calendar.current
    private let storageURL: URL
    private let persistence = LocationHistoryPersistence()
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    override init() {
        authorizationStatus = manager.authorizationStatus
        storageURL = Self.makeStorageURL()
        samplesByDay = Self.load(from: storageURL)
        super.init()

        manager.delegate = self
    }

    var isDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    func samples(on day: Date) -> [LocationSample] {
        samplesByDay[dayKey(for: day), default: []]
    }

    /// Refreshes the coordinate used for a newly-created note with one bounded
    /// request. This doesn't start continuous tracking.
    func requestLocationForNewNote() {
        guard AppSettings.shared.locationTrackingEnabled else { return }
        guard authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else { return }
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.requestLocation()
    }

    /// The freshest trustworthy coordinate already available on the device.
    func locationForNewNote(now: Date = .now) -> NoteLocation? {
        guard AppSettings.shared.locationTrackingEnabled else { return nil }

        if let location = manager.location,
           location.horizontalAccuracy >= 0,
           location.horizontalAccuracy <= 500,
           abs(now.timeIntervalSince(location.timestamp)) <= 30 * 60 {
            return NoteLocation(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                capturedAt: location.timestamp
            )
        }

        guard let sample = samples(on: now).last,
              abs(now.timeIntervalSince(sample.timestamp)) <= 30 * 60
        else { return nil }
        return NoteLocation(
            latitude: sample.latitude,
            longitude: sample.longitude,
            capturedAt: sample.timestamp
        )
    }

    func setTrackingEnabled(_ enabled: Bool) {
        AppSettings.shared.locationTrackingEnabled = enabled

        if enabled {
            requestPermissionOrStart()
        } else {
            stopTracking()
        }
    }

    func resumeIfNeeded() {
        guard AppSettings.shared.locationTrackingEnabled else {
            stopTracking()
            return
        }
        requestPermissionOrStart()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus

        guard AppSettings.shared.locationTrackingEnabled else { return }
        switch authorizationStatus {
        case .authorizedAlways:
            startTracking()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
            startTracking()
        case .denied, .restricted:
            stopTracking()
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard AppSettings.shared.locationTrackingEnabled else { return }

        for location in locations where location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= 500 {
            append(location)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        // Transient location failures are expected indoors and need no user-facing interruption.
    }

    private func requestPermissionOrStart() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
            startTracking()
        case .authorizedAlways:
            startTracking()
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    private func startTracking() {
        guard CLLocationManager.significantLocationChangeMonitoringAvailable() else { return }
        manager.startMonitoringSignificantLocationChanges()
    }

    private func stopTracking() {
        manager.stopMonitoringSignificantLocationChanges()
    }

    private func append(_ location: CLLocation) {
        let key = dayKey(for: location.timestamp)
        var samples = samplesByDay[key, default: []]

        if let last = samples.last {
            let lastLocation = CLLocation(
                coordinate: last.coordinate,
                altitude: 0,
                horizontalAccuracy: 0,
                verticalAccuracy: 0,
                timestamp: last.timestamp
            )
            let elapsed = location.timestamp.timeIntervalSince(last.timestamp)
            guard location.distance(from: lastLocation) >= 35 || elapsed >= 5 * 60 else { return }
        }

        samples.append(
            LocationSample(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                timestamp: location.timestamp
            )
        )
        samplesByDay[key] = Array(samples.suffix(1_200))
        removeOldDays()
        save()
    }

    private func removeOldDays() {
        guard let cutoff = calendar.date(byAdding: .day, value: -90, to: .now) else { return }
        samplesByDay = samplesByDay.filter { key, _ in
            guard let date = Self.dayFormatter.date(from: key) else { return false }
            return date >= calendar.startOfDay(for: cutoff)
        }
    }

    private func dayKey(for date: Date) -> String {
        Self.dayFormatter.string(from: calendar.startOfDay(for: date))
    }

    private func save() {
        let snapshot = samplesByDay
        let storageURL = storageURL
        let persistence = persistence

        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await persistence.save(snapshot, to: storageURL)
        }
    }

    private static func makeStorageURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "Wispr/location-history.json")
    }

    private static func load(from url: URL) -> [String: [LocationSample]] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: [LocationSample]].self, from: data)) ?? [:]
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private actor LocationHistoryPersistence {
    func save(_ samplesByDay: [String: [LocationSample]], to storageURL: URL) {
        guard let data = try? JSONEncoder().encode(samplesByDay) else { return }
        try? FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: storageURL, options: .atomic)
    }
}
