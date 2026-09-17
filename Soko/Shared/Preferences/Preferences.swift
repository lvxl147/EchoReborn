import Foundation

// Ported from waruhachi/Soko 1.0.0-rc.1.
//
// Two deliberate changes from upstream:
//   1. No `import libroot` — upstream imported it but never called jbroot();
//      dropping it removes a link-time dependency that can break under roothide.
//   2. Per-key direct reads instead of JSONDecoder().decode(Preferences.self,…).
//      The synthesized decoder throws when any non-optional field is absent, and
//      the catch-all then resets the WHOLE struct to defaults — so adding a new
//      field silently wiped the user's tuned offsets.  Reading each key
//      independently makes new fields additive and safe.
//
// The suite is EchoReborn's own so the whole package shares one preference domain;
// keys keep their upstream `soko_` prefix so they cannot collide with EchoReborn's
// existing keys (e.g. `Global.Enabled`).
struct Preferences: Codable {
    var widgetsEnabled: Bool = true
    var widgetOffset: Double = -18.0
    var notificationsEnabled: Bool = true
    var notificationOffset: Double = 60.0

    // Flipping a feature off zeroes its displacement so the view snaps back to
    // the stock position, rather than freezing at the last tuned offset.
    var effectiveWidgetOffset: Double { widgetsEnabled ? widgetOffset : 0.0 }
    var effectiveNotificationOffset: Double { notificationsEnabled ? notificationOffset : 0.0 }
}

public final class TweakPreferences: NSObject {
    private(set) var preferences: Preferences = Preferences()

    static let shared = TweakPreferences()

    private let userDefaultsName: String = "com.strive.echoreborn.preferences"
    private let keyPrefix: String = "soko_"

    func loadPreferences() throws {
        var preferences = Preferences()

        guard let defaults = UserDefaults(suiteName: userDefaultsName) else {
            self.preferences = preferences
            return
        }

        func readBool(_ key: String, _ fallback: Bool) -> Bool {
            let full = keyPrefix + key
            guard defaults.object(forKey: full) != nil else { return fallback }
            return defaults.bool(forKey: full)
        }

        func readDouble(_ key: String, _ fallback: Double) -> Double {
            let full = keyPrefix + key
            guard defaults.object(forKey: full) != nil else { return fallback }
            return defaults.double(forKey: full)
        }

        preferences.widgetsEnabled = readBool("widgetsEnabled", true)
        preferences.widgetOffset = readDouble("widgetOffset", -18.0)
        preferences.notificationsEnabled = readBool("notificationsEnabled", true)
        preferences.notificationOffset = readDouble("notificationOffset", 60.0)

        self.preferences = preferences
    }
}
