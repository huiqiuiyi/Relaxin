import Foundation

/// Customizable slogan shown on the home terminal banner.
/// Stored in UserDefaults so the user can edit it via long-press
/// without rebuilding the app.
enum RelaxinSlogan {
    static let key = "relaxin.slogan"
    static let changedNotification = Notification.Name("RelaxinSloganChanged")

    static let defaultSlogan = "小秋专属5.2.0至尊版本"

    static var current: String {
        let stored = UserDefaults.standard.string(forKey: key)
        guard let stored, !stored.isEmpty else { return defaultSlogan }
        return stored
    }

    static func set(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(trimmed, forKey: key)
        }
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }
}
