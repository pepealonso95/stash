import Foundation

enum OverlayStartupMode: String {
    case visible
    case hidden
    case disabled
}

final class OverlaySettingsStore {
    static let suiteName = "com.stash.overlay.settings"
    static let overlayModeKey = "overlayMode"

    private let defaults: UserDefaults

    init(defaults: UserDefaults? = UserDefaults(suiteName: suiteName)) {
        self.defaults = defaults ?? .standard
    }

    func overlayMode() -> OverlayStartupMode {
        guard let raw = defaults.string(forKey: Self.overlayModeKey) else {
            return .hidden
        }
        return OverlayStartupMode(rawValue: raw) ?? .hidden
    }

    func setOverlayMode(_ mode: OverlayStartupMode) {
        defaults.set(mode.rawValue, forKey: Self.overlayModeKey)
    }
}
