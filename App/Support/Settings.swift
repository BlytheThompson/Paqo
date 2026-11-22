import CoreLocation
import Foundation
import PaqoCore

enum SettingsKey {
    static let unit = "unit"
    static let saveToHealth = "saveToHealth"
    static let recordSensorLogs = "recordSensorLogs"
    static let backupBookmark = "backupBookmark"
    static let lastBackupDate = "lastBackupDate"
    static let pendingBackupIDs = "pendingBackupIDs"
    static let pendingDeleteIDs = "pendingDeleteIDs"
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

    /// Sensor logs are on by default while detection is being tuned.
    var recordSensorLogs: Bool {
        object(forKey: SettingsKey.recordSensorLogs) as? Bool ?? true
    }
}

extension Coordinate {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
