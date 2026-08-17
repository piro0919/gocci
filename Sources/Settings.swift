import Foundation
import ServiceManagement

// 設定の保存と読み出し。
//
// 数が少ないので UserDefaults に直接置く。ログイン時の起動だけは OS 側が持つ状態なので、
// こちらでは持たず ServiceManagement に問い合わせる。二重に持つと必ずずれる。

enum Settings {
    private static let remoteKey = "remote"
    private static let languageKey = "language"
    private static let volumeKey = "volume"

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

    // MARK: - 置き場所

    /// ダウンロードしたものを置くボリューム。空なら内蔵（`~/Library/CloudStorage`）。
    ///
    /// 外付けに置けるのは macOS 15 から。拡張の Info.plist に
    /// `NSExtensionFileProviderAllowsExternalVolumes` が要る（2026-08-17 に実測）
    static var volume: String {
        get { UserDefaults.standard.string(forKey: volumeKey) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: volumeKey)
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    /// 外付けに置けるか。置けない機械では、選ばせても意味がない
    static var canUseExternalVolume: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    // MARK: - 手元に残す上限

    private static let limitKey = "downloadLimit"

    /// これを超えたら、長く触っていないものから捨てる。0 なら捨てない。
    ///
    /// 外付けに置けても、外付けもいつかは一杯になる。今のところ減らす手立ては
    /// 「全部空にする」しか無く、それは片付けとしては大雑把すぎる
    static var downloadLimit: Int64 {
        get { Int64(UserDefaults.standard.integer(forKey: limitKey)) }
        set {
            UserDefaults.standard.set(Int(newValue), forKey: limitKey)
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    /// 選ばせる目盛り。刻みを細かくしても選びようがないので、桁で並べる
    static let downloadLimitChoices: [Int64] = [
        0, 10 << 30, 50 << 30, 100 << 30, 200 << 30, 500 << 30, 1000 << 30,
    ]

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
