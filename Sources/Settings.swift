import Foundation
import ServiceManagement

// 設定の保存と読み出し。
//
// 数が少ないので UserDefaults に直接置く。ログイン時の起動だけは OS 側が持つ状態なので、
// こちらでは持たず ServiceManagement に問い合わせる。二重に持つと必ずずれる。

enum Settings {
    private static let remoteKey = "remote"
    private static let languageKey = "language"

    // MARK: - rclone のリモート

    /// `rclone config` で作った名前。既定は検証に使ってきた gdrive
    static var remote: String {
        get {
            let saved = UserDefaults.standard.string(forKey: remoteKey) ?? ""
            return saved.isEmpty ? "gdrive" : saved
        }
        set {
            UserDefaults.standard.set(newValue, forKey: remoteKey)
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    // MARK: - 言語

    static var language: Language {
        get {
            UserDefaults.standard.string(forKey: languageKey)
                .flatMap(Language.init(rawValue:)) ?? .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: languageKey)
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    // MARK: - ログイン時の起動

    /// 状態は OS 側が持っているので、こちらでは覚えず毎回問い合わせる
    static var launchesAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 切り替えに失敗したら理由を返す。成功なら nil
    static func setLaunchesAtLogin(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

extension Notification.Name {
    static let settingsChanged = Notification.Name("gocci.settingsChanged")
}
