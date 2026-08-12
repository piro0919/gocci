import Foundation

// 表示文字列。
//
// Konechi と同じく .lproj は使わず Swift の表に置く。ビルドを自前の shell で組んでいるので、
// 文字列だけのために資源の仕組みを足すと build.sh が重くなる。言語は2つしかない。

enum Language: String, CaseIterable {
    case system, ja, en

    /// 実際に使う言語。既定は英語で、環境が日本語のときだけ日本語にする
    static var resolved: Language {
        switch Settings.language {
        case .ja: return .ja
        case .en: return .en
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.hasPrefix("ja") ? .ja : .en
        }
    }

    var label: String {
        switch self {
        case .system: return L.t("システムに従う", "Follow system")
        case .ja: return "日本語"
        case .en: return "English"
        }
    }
}

enum L {
    static func t(_ ja: String, _ en: String) -> String {
        Language.resolved == .ja ? ja : en
    }

    // メニュー
    static var driveName: String { "Google Drive" }
    static var mounted: String { t("マウント済み", "Mounted") }
    static var mounting: String { t("マウント中…", "Mounting…") }
    static var unmounting: String { t("マウント解除中…", "Unmounting…") }
    static var unmounted: String { t("未マウント", "Not mounted") }
    static var waitingForDisk: String {
        t("ディスクを待機中…", "Waiting for the disk…")
    }
    static var reconnecting: String { t("再マウント中…", "Remounting…") }
    static var failed: String { t("エラー", "Error") }
    static var mountPointUnset: String { t("マウント先が未設定です", "No mount point set") }
    static var openInFinder: String { t("Finderに表示", "Show in Finder") }
    static var connect: String { t("マウント", "Mount") }
    static var disconnect: String { t("マウント解除", "Unmount") }
    static func fetching(_ count: Int) -> String {
        t("\(count)項目をダウンロード中", "Downloading \(count) items")
    }
    static func andMore(_ count: Int) -> String {
        t("ほか\(count)項目", "\(count) more")
    }
    static func cacheUsage(_ used: String, _ limit: String) -> String {
        limit.isEmpty
            ? t("ダウンロード済み \(used)", "Downloaded \(used)")
            : t("ダウンロード済み \(used)／\(limit)", "Downloaded \(used) of \(limit)")
    }
    static var restartFinder: String { t("Finderを再起動", "Restart Finder") }
    static var restartFinderHint: String {
        t(
            "更新後にバッジが出なくなったときに押します（Finderのウィンドウが閉じます）",
            "Press it if badges stop appearing after an update (closes Finder windows)")
    }
    static var settings: String { t("設定…", "Settings…") }
    static var quit: String { t("終了", "Quit") }

    // 設定画面
    static var settingsTitle: String { t("設定", "Settings") }
    static var mountPoint: String { t("マウント先", "Mount point") }
    static var cacheDir: String { t("キャッシュの場所", "Cache location") }
    static var remote: String { t("接続先", "Account") }
    /// macOS 本体の翻訳表（AppKit の Common.loctable）に合わせる。"Choose…" は「選択…」
    static var choose: String { t("選択…", "Choose…") }
    static var notSet: String { t("未設定", "Not set") }
    static var cacheDefaultHint: String {
        t("マウント先と同じディスク", "Same disk as the mount point")
    }
    static var cacheMaxAge: String { t("ダウンロードを残す", "Keep downloads for") }
    static var cacheMaxSize: String { t("上限", "Limit") }
    static var cacheLimitsHint: String { "" }
    static var launchAtLogin: String { t("ログイン時に起動する", "Launch at Login") }
    static var fetchWhole: String {
        t("再生を止めてもダウンロードを続ける", "Keep Downloading After You Stop Playing")
    }
    static var fetchWholeHint: String { "" }
    static var clientID: String { "client_id" }
    static var clientSecret: String { "client_secret" }
    static var credentialsHint: String {
        t(
            "Googleが発行する認証情報です。入れないと2026年中に使えなくなります",
            "Google issues these. Without your own, this stops working during 2026")
    }
    static var howToGetCredentials: String { t("取得の手順", "How to Get One") }
    static var openCloudConsole: String { t("Google Cloud Console", "Google Cloud Console") }
    static var reconnect: String { t("保存して認証し直す", "Save and Re-authenticate") }
    static var reconnecting2: String {
        t("ブラウザで認証してください…", "Finish the sign-in in your browser…")
    }
    static var reconnected: String { t("認証し直しました", "Re-authenticated") }
    static var keepFinderSettings: String {
        t("フォルダの表示設定を覚える", "Remember Folder View Settings")
    }
    static var keepFinderSettingsHint: String {
        t(
            "アイコンプレビューを切ったフォルダは、開いてもダウンロードされません",
            "Folders with icon previews off download nothing when you open them")
    }
    static var language: String { t("言語", "Language") }
    static var checkForUpdates: String { t("更新を確認", "Check for Updates") }
    static func launchToggleFailed(_ reason: String) -> String {
        t("切り替えられませんでした: \(reason)", "Could not change it: \(reason)")
    }

    // エラー
    static var rcloneMissing: String {
        t("rclone が見つかりません", "rclone was not found")
    }
    static func mountFailed(_ reason: String) -> String {
        reason.isEmpty ? t("マウントできませんでした", "Could not mount") : reason
    }
    static func restartGaveUp(_ reason: String) -> String {
        let head = t("繋ぎ直せませんでした", "Could not stay connected")
        return reason.isEmpty ? head : "\(head): \(reason)"
    }
    static func unmountFailed(_ reason: String) -> String {
        t("切れませんでした: \(reason)", "Could not disconnect: \(reason)")
    }
    static var mountPointIsLink: String {
        t(
            "マウント先がリンクです。実体のあるフォルダを選んでください",
            "The mount point is a symlink. Choose a real folder")
    }

    /// 自分では外せない。手でやってもらうしかないので、叩く命令をそのまま出す
    static func staleMountStuck(_ mountPoint: String) -> String {
        t(
            "前の接続が残っています。ターミナルで umount -f \(mountPoint) を実行してください",
            "The previous mount is still there. Run umount -f \(mountPoint) in Terminal")
    }
    static var mountTimedOut: String {
        t("マウントが終わりませんでした", "The mount did not finish")
    }
}
