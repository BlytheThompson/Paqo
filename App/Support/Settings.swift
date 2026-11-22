import CoreLocation
import Foundation
import PaqoCore

enum SettingsKey {
    static let unit = "unit"
    static let saveToHealth = "saveToHealth"
}

extension DistanceUnit {
    /// Miles in the US and UK, kilometers elsewhere.
    static var localeDefault: DistanceUnit {
        let system = Locale.current.measurementSystem
        return system == .us || system == .uk ? .miles : .kilometers
    }
}

extension UserDefaults {
    var distanceUnit: DistanceUnit {
        DistanceUnit(rawValue: string(forKey: SettingsKey.unit) ?? "") ?? .localeDefault
    }

    var saveToHealth: Bool {
        object(forKey: SettingsKey.saveToHealth) as? Bool ?? true
    }
}

extension Coordinate {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
