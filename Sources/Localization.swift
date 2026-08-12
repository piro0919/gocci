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
    static var mounted: String { t("接続中", "Connected") }
    static var mounting: String { t("接続しています…", "Connecting…") }
    static var unmounting: String { t("切っています…", "Disconnecting…") }
    static var unmounted: String { t("未接続", "Not connected") }
    static var waitingForDisk: String {
        t("外付けを待っています…", "Waiting for the disk…")
    }
    static var reconnecting: String { t("繋ぎ直しています…", "Reconnecting…") }
    static var failed: String { t("エラー", "Error") }
    static var mountPointUnset: String { t("マウント先が未設定です", "No mount point set") }
    static var openInFinder: String { t("Finder で開く", "Open in Finder") }
    static var connect: String { t("接続する", "Connect") }
    static var disconnect: String { t("接続を切る", "Disconnect") }
    static func fetching(_ count: Int) -> String {
        t("取得中 \(count) 件", "Fetching \(count)")
    }
    static func andMore(_ count: Int) -> String {
        t("ほか \(count) 件", "and \(count) more")
    }
    static var restartFinder: String { t("Finder を再起動", "Restart Finder") }
    static var settings: String { t("設定…", "Settings…") }
    static var quit: String { t("終了", "Quit") }

    // 設定画面
    static var settingsTitle: String { t("Gocci の設定", "Gocci Settings") }
    static var mountPoint: String { t("マウント先", "Mount point") }
    static var cacheDir: String { t("キャッシュ先", "Cache folder") }
    static var remote: String { t("rclone のリモート名", "rclone remote") }
    static var choose: String { t("選ぶ…", "Choose…") }
    static var notSet: String { t("未設定", "Not set") }
    static var cacheDefaultHint: String {
        t(
            "空にすると、マウント先と同じディスクに置きます",
            "Leave empty to place it on the same disk as the mount point")
    }
    static var cacheMaxAge: String { t("キャッシュを残す期間", "Keep the cache for") }
    static var cacheMaxSize: String { t("キャッシュの上限", "Cache size limit") }
    static var cacheLimitsHint: String {
        t(
            "空にすると rclone の既定（1時間・上限なし）に戻ります。例: 30d、50G",
            "Empty falls back to rclone's defaults (1 hour, no limit). e.g. 30d, 50G")
    }
    static var launchAtLogin: String { t("ログイン時に起動する", "Launch at login") }
    static var fetchWhole: String {
        t("再生を止めても最後まで取得する", "Keep fetching after you stop playing")
    }
    static var fetchWholeHint: String {
        t(
            "ある程度まで読まれたファイルだけが対象です。Finder が覗いただけのものは取りません",
            "Only files you actually used. A thumbnail peek does not count")
    }
    static var clientID: String { "client_id" }
    static var clientSecret: String { "client_secret" }
    static var credentialsHint: String {
        t(
            "rclone 共用のものは 2026年中に停止します。自分の client_id を作って入れてください",
            "rclone's shared one stops working during 2026. Create your own and paste it here")
    }
    static var howToGetCredentials: String { t("取得の手順", "How to get one") }
    static var openCloudConsole: String { t("Cloud Console を開く", "Open Cloud Console") }
    static var reconnect: String { t("保存して認証し直す", "Save and re-authenticate") }
    static var reconnecting2: String {
        t("ブラウザで認証してください…", "Finish the sign-in in your browser…")
    }
    static var reconnected: String { t("認証し直しました", "Re-authenticated") }
    static var keepFinderSettings: String {
        t("Finder の表示設定を保存する", "Let Finder remember view settings")
    }
    static var keepFinderSettingsHint: String {
        t(
            "フォルダのアイコンプレビューを切れるようになり、覗いても中身が落ちてきません。Drive に .DS_Store が作られます",
            "Lets you turn off icon previews per folder, so browsing downloads nothing. Adds .DS_Store files to your Drive")
    }
    static var language: String { t("言語", "Language") }
    static var checkForUpdates: String { t("更新を確認", "Check for updates") }
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
