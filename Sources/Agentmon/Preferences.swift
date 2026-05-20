import Foundation
import Combine

@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }

    @Published var idleThresholdMinutes: Double {
        didSet { defaults.set(idleThresholdMinutes, forKey: Keys.idleThresholdMinutes) }
    }

    @Published var showCost: Bool {
        didSet { defaults.set(showCost, forKey: Keys.showCost) }
    }

    private enum Keys {
        static let notificationsEnabled = "agentmon.notificationsEnabled"
        static let idleThresholdMinutes = "agentmon.idleThresholdMinutes"
        static let showCost = "agentmon.showCost"
    }

    private init() {
        // Default values applied if unset
        defaults.register(defaults: [
            Keys.notificationsEnabled: true,
            Keys.idleThresholdMinutes: 30.0,
            Keys.showCost: true
        ])
        notificationsEnabled = defaults.bool(forKey: Keys.notificationsEnabled)
        idleThresholdMinutes = defaults.double(forKey: Keys.idleThresholdMinutes)
        showCost = defaults.bool(forKey: Keys.showCost)
    }
}
