import AppKit
import UserNotifications

/// System notifications and little sounds.
enum Notifier {
    static func post(title: String, body: String, sound: Bool = true) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if sound { content.sound = .default }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    enum Sound: String {
        case start = "Tink", stop = "Pop", done = "Glass", alert = "Submarine"
    }

    static func play(_ s: Sound) {
        guard PalSettings.c.sounds else { return }
        NSSound(named: NSSound.Name(s.rawValue))?.play()
    }
}
