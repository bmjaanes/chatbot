import CoreLocation
import Observation

/// One-shot access to the user's current location.
@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    private(set) var lastLocation: CLLocation?

    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<CLLocation?, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        authorizationStatus = manager.authorizationStatus
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    var isDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    func requestPermission() {
        if authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Asks for permission if needed, then returns a fresh location (or nil if unavailable).
    func currentLocation() async -> CLLocation? {
        if isDenied { return nil }
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
            if isAuthorized {
                manager.requestLocation()
            } else {
                requestPermission()
            }
        }
    }

    private func finish(with location: CLLocation?) {
        if let location { lastLocation = location }
        let continuations = waiting
        waiting.removeAll()
        continuations.forEach { $0.resume(returning: location) }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            guard !self.waiting.isEmpty else { return }
            if self.isAuthorized {
                self.manager.requestLocation()
            } else if self.isDenied {
                self.finish(with: nil)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        Task { @MainActor in self.finish(with: location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(with: nil) }
    }
}
