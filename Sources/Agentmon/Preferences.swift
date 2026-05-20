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

    @Published var mutedProjects: Set<String> {
        didSet { defaults.set(Array(mutedProjects), forKey: Keys.mutedProjects) }
    }

    func toggleMute(_ cwd: String) {
        if mutedProjects.contains(cwd) {
            mutedProjects.remove(cwd)
        } else {
            mutedProjects.insert(cwd)
        }
    }

    func isMuted(_ cwd: String?) -> Bool {
        guard let cwd else { return false }
        return mutedProjects.contains(cwd)
    }

    private enum Keys {
        static let notificationsEnabled = "agentmon.notificationsEnabled"
        static let idleThresholdMinutes = "agentmon.idleThresholdMinutes"
        static let showCost = "agentmon.showCost"
        static let mutedProjects = "agentmon.mutedProjects"
    }

    private init() {
        defaults.register(defaults: [
            Keys.notificationsEnabled: true,
            Keys.idleThresholdMinutes: 30.0,
            Keys.showCost: true,
            Keys.mutedProjects: [String]()
        ])
        notificationsEnabled = defaults.bool(forKey: Keys.notificationsEnabled)
        idleThresholdMinutes = defaults.double(forKey: Keys.idleThresholdMinutes)
        showCost = defaults.bool(forKey: Keys.showCost)
        let muted = (defaults.array(forKey: Keys.mutedProjects) as? [String]) ?? []
        mutedProjects = Set(muted)
    }
}
