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
    static var mounted: String { t("接続済み", "Connected") }
    static var mounting: String { t("接続中…", "Connecting…") }
    static var unmounted: String { t("未接続", "Not connected") }
    static var failed: String { t("エラー", "Error") }
    static var openInFinder: String { t("Finderに表示", "Show in Finder") }
    // 押すと何が起きるかを、行そのものに書く。状態の表示と読み違えられないように
    static var connect: String { t("接続する", "Connect") }
    static var disconnect: String { t("接続を解除する", "Disconnect") }
    static var settings: String { t("設定…", "Settings…") }
    static var quit: String { t("終了", "Quit") }

    // 設定画面
    static var settingsTitle: String { t("設定", "Settings") }
    static var remote: String { t("接続先", "Account") }
    /// macOS 本体の翻訳表（AppKit の Common.loctable）に合わせる。"Choose…" は「選択…」
    static var launchAtLogin: String { t("ログイン時に起動する", "Launch at Login") }
    /// Google Cloud Console の表示と揃える。貼り付ける人が迷わないように
    static var clientID: String { t("クライアントID", "Client ID") }
    static var clientSecret: String { t("クライアントシークレット", "Client secret") }
    static var howToGetCredentials: String { t("取得の手順", "How to Get One") }
    static var openCloudConsole: String { t("Google Cloud Console", "Google Cloud Console") }
    static var reconnect: String { t("保存して認証し直す", "Save and Re-authenticate") }
    static var reconnecting2: String {
        t("ブラウザで認証してください…", "Finish the sign-in in your browser…")
    }
    static var reconnected: String { t("認証し直しました", "Re-authenticated") }
    static var storage: String { t("置き場所", "Stored on") }
    static var storageBuiltIn: String { t("内蔵ディスク", "This Mac") }
    static var choose: String { t("選択…", "Choose…") }
    static var storageNeedsSequoia: String {
        t("外付けに置けるのは macOS 15 以降です", "Storing on another disk needs macOS 15 or later")
    }
    static var storageChanged: String {
        t("繋ぎ直します。降りてきていたものは消えます", "Reconnecting. Anything downloaded is dropped")
    }
    static var evictDownloads: String { t("ダウンロードを空にする", "Remove Downloads") }
    /// 空にする前に、何がどれだけ消えるのかを出す
    static func downloaded(_ size: String, count: Int) -> String {
        t("手元に \(size)（\(count) 件）", "\(size) here (\(count) files)")
    }
    static var downloadedNothing: String { t("手元には何もありません", "Nothing is here yet") }
    static var downloadLimit: String { t("手元に残す上限", "Keep at most") }
    static var downloadLimitNone: String { t("上限なし", "No limit") }
    static var downloadLimitHint: String {
        t(
            "超えた分は、古く落としたものから消えます",
            "Anything over it is dropped, oldest download first")
    }
    static var downloadedCounting: String { t("数えています…", "Counting…") }
    static var evictedDownloads: String { t("空にしました", "Downloads removed") }
    static func evictFailed(_ reason: String) -> String {
        t("空にできませんでした: \(reason)", "Could not remove them: \(reason)")
    }
    static var language: String { t("言語", "Language") }
    static var checkForUpdates: String { t("更新を確認", "Check for Updates") }
    static func launchToggleFailed(_ reason: String) -> String {
        t("切り替えられませんでした: \(reason)", "Could not change it: \(reason)")
    }


}
