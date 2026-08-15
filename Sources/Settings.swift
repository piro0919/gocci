import Darwin
import Foundation
import ServiceManagement

// 設定の保存と読み出し。
//
// 数が少ないので UserDefaults に直接置く。ログイン時の起動だけは OS 側が持つ状態なので、
// こちらでは持たず ServiceManagement に問い合わせる。二重に持つと必ずずれる。

/// キャッシュを残す期間。rclone へ渡す値と、画面に出す名前を持つ
enum CachePeriod: String, CaseIterable {
    case day = "24h"
    case week = "168h"
    case month = "720h"
    case quarter = "2160h"
    case forever = "off"

    var label: String {
        switch self {
        case .day: return L.t("1日", "1 day")
        case .week: return L.t("1週間", "1 week")
        case .month: return L.t("30日", "30 days")
        case .quarter: return L.t("90日", "90 days")
        case .forever: return L.t("消さない", "Never")
        }
    }

    /// rclone へ渡す値。消さない場合は渡さない
    var argument: String { self == .forever ? "" : rawValue }
}

/// キャッシュの上限
enum CacheLimit: String, CaseIterable {
    case tiny = "5G"
    case small = "10G"
    case modest = "25G"
    case medium = "50G"
    case big = "100G"
    case large = "200G"
    case huge = "500G"
    case unlimited = "off"

    var label: String {
        switch self {
        case .unlimited: return L.t("無制限", "No limit")
        default: return rawValue.replacingOccurrences(of: "G", with: "GB")
        }
    }

    var argument: String { self == .unlimited ? "" : rawValue }

    /// 何バイトぶんか。空きと比べるために使う。無制限は比べる相手がいない
    var bytes: Int64? {
        guard self != .unlimited, let number = Int64(rawValue.dropLast()) else { return nil }
        return number * 1024 * 1024 * 1024
    }
}

enum Settings {
    private static let mountPointKey = "mountPoint"
    private static let cacheDirKey = "cacheDir"
    private static let remoteKey = "remote"
    private static let fetchWholeKey = "fetchWholeFile"
    private static let finderSettingsKey = "keepFinderSettings"
    private static let cacheMaxAgeKey = "cacheMaxAge"
    private static let cacheMaxSizeKey = "cacheMaxSize"
    private static let languageKey = "language"

    // MARK: - マウント先

    /// 空なら未設定。既定値は置かない。外付けの名前は人によって違うので、推測して作らない
    static var mountPoint: String {
        get { UserDefaults.standard.string(forKey: mountPointKey) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: mountPointKey)
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    // MARK: - キャッシュ先

    /// 利用者が指定した値。空のときは resolvedCacheDir が決める。
    ///
    /// 設定画面には出さない。既定（マウント先と同じディスク）でほぼ正解になり、
    /// 変える理由は例外的（外付けが exFAT で穴あきファイルを作れない、外付けが遅い、など）。
    /// 必要な人は `defaults write io.kkweb.gocci cacheDir <パス>` で変えられる
    static var cacheDir: String {
        get { UserDefaults.standard.string(forKey: cacheDirKey) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: cacheDirKey)
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    /// 実際に rclone へ渡すキャッシュ先。
    ///
    /// `--vfs-cache-mode full` では書き込んだファイルが丸ごとここに載る。内蔵の空きが乏しいから
    /// 外付けにマウントしているので、既定でも内蔵には置かず、マウント先と同じディスクの直下に置く。
    /// マウント先が未設定のときだけ、行き場が無いので通常のキャッシュ置き場に落とす
    static var resolvedCacheDir: String {
        if !cacheDir.isEmpty { return cacheDir }

        if let volume = volumeRoot(of: Paths.cacheParent(of: mountPoint)),
            supportsSparseFiles(volume)
        {
            return (volume as NSString).appendingPathComponent(".gocci-cache")
        }

        let fallback = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        return fallback?.appendingPathComponent("io.kkweb.gocci").path ?? NSTemporaryDirectory()
    }

    /// キャッシュ先のディスクの空き。
    ///
    /// 上限に並ぶ数字は、置き場所の空きと比べないと選びようがない。まだ作られていない
    /// フォルダを訊いても答えは返らないので、実在する親まで遡って訊く
    static var cacheDiskFreeBytes: Int64? {
        var path = resolvedCacheDir
        while !path.isEmpty, path != "/" {
            if FileManager.default.fileExists(atPath: path) { break }
            path = (path as NSString).deletingLastPathComponent
        }

        let values = try? URL(fileURLWithPath: path).resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// 大きさを字にする。
    ///
    /// `ByteCountFormatter` は既定では 0 を「Zero KB」と書く。数の並びの中に字が混ざると
    /// 読み手が引っかかるので、数字で出させる
    static func byteText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }

    /// キャッシュが今どれだけ使っているか。
    ///
    /// rclone のキャッシュは穴あきファイルなので、ファイルの大きさではなく実際に取っている
    /// 場所を足す。フォルダを歩くので、呼ぶ側は主スレッドの外で回す
    static func cacheUsedBytes() -> Int64 {
        let root = URL(fileURLWithPath: resolvedCacheDir)
        guard
            let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles])
        else { return 0 }

        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// キャッシュ先に残しておく空き（`--vfs-cache-min-free-space`）。
    ///
    /// 上限（`--vfs-cache-max-size`）だけでは、ディスクが埋まるのを防げない。rclone は
    /// 空きを見ないので、上限を空きより大きく取ると上限は効かず、置き場所のほうが先に尽きる。
    /// こちらを渡しておくと、空きがこの値を切ったところで古いものから消える。
    /// 画面には出さない。既定で効かせ、変えたい人は
    /// `defaults write io.kkweb.gocci cacheMinFreeSpace 20G` で上書きする
    static var cacheMinFreeSpace: String {
        let saved = UserDefaults.standard.string(forKey: "cacheMinFreeSpace") ?? ""
        return saved.isEmpty ? "10G" : saved
    }

    /// 穴あきファイルを作れるか。
    ///
    /// rclone は読んだところだけを持つ穴あきファイルでキャッシュを作る。FAT や exFAT は
    /// これを作れず、rclone 自身が「極端に遅くなる」と警告する。作れない場所は避ける
    private static func supportsSparseFiles(_ volume: String) -> Bool {
        var info = statfs()
        guard statfs(volume, &info) == 0 else { return true }

        let type = withUnsafePointer(to: info.f_fstypename) { pointer in
            pointer.withMemoryRebound(
                to: CChar.self, capacity: MemoryLayout.size(ofValue: info.f_fstypename)
            ) { String(cString: $0) }
        }
        return !["exfat", "msdos", "fat32", "ntfs"].contains(type.lowercased())
    }

    /// マウント先を置く場所が今あるか。外付けが繋がっていなければ `/Volumes/HIKSEMI` ごと無い。
    /// マウント先そのものは、こちらで作るので無くて構わない
    static var mountPointParentExists: Bool {
        let path = (mountPoint as NSString).standardizingPath
        guard !path.isEmpty else { return false }
        let parent = (path as NSString).deletingLastPathComponent
        return !parent.isEmpty && FileManager.default.fileExists(atPath: parent)
    }

    /// マウント先が載っているディスクの一番上。`/Volumes/HIKSEMI/GoogleDrive` なら `/Volumes/HIKSEMI`。
    /// マウント先自体はまだ存在しないことがあるので、遡って実在する親から調べる
    private static func volumeRoot(of path: String) -> String? {
        guard !path.isEmpty else { return nil }

        var current = (path as NSString).standardizingPath
        while !FileManager.default.fileExists(atPath: current) {
            let parent = (current as NSString).deletingLastPathComponent
            guard parent != current, !parent.isEmpty else { return nil }
            current = parent
        }

        let values = try? URL(fileURLWithPath: current).resourceValues(forKeys: [.volumeURLKey])
        return values?.volume?.path
    }

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

    // MARK: - キャッシュの寿命と上限

    /// 最終アクセスからどれだけ残すか（`--vfs-cache-max-age`）。
    ///
    /// rclone の既定は 1 時間で、それだと一度落としたものがすぐ消える。
    /// 「開いたものは手元に残る」に寄せて 30 日を既定にする。空にすると rclone の既定に戻る
    static var cachePeriod: CachePeriod {
        get {
            (UserDefaults.standard.string(forKey: cacheMaxAgeKey)).flatMap(CachePeriod.init) ?? .month
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: cacheMaxAgeKey)
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    static var cacheMaxAge: String { cachePeriod.argument }

    /// キャッシュ全体の上限（`--vfs-cache-max-size`）。
    ///
    /// rclone の既定は上限なし。寿命を延ばす以上、歯止めが要る。空にすると上限なしに戻る
    static var cacheLimit: CacheLimit {
        get {
            (UserDefaults.standard.string(forKey: cacheMaxSizeKey)).flatMap(CacheLimit.init) ?? .medium
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: cacheMaxSizeKey)
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    static var cacheMaxSize: String { cacheLimit.argument }

    // MARK: - 先読み

    /// 再生を途中で止めても、残りを最後まで取りにいくか。
    ///
    /// rclone 側の先読み（`--vfs-read-ahead`）は使わない。あれを有効にすると、Finder が
    /// サムネイルのために覗いただけの動画まで丸ごと落ちてくる。「開いた」の範囲が
    /// 人の意図と合わない。
    ///
    /// 代わりにアプリが、ある程度読まれたファイルの続きを取りにいく。
    ///
    /// 設定画面には出さない。開いたものが手元に残るのが普通の期待で、切って嬉しいのは
    /// 通信量を切り詰めたいときだけ。キャッシュには期限と上限がかかっているので、
    /// 際限なく溜まることもない。切りたい人は `defaults write io.kkweb.gocci fetchWholeFile -bool NO`
    static var fetchesWholeFile: Bool {
        get { (UserDefaults.standard.object(forKey: fetchWholeKey) as? Bool) ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: fetchWholeKey)
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    // MARK: - Finder の表示設定

    /// フォルダごとの表示設定（`.DS_Store`）を Drive 側に保存するか。
    ///
    /// rclone は既定で `.DS_Store` を無視する（`--noappledouble`）。無視されると、Finder が
    /// アイコンプレビューを切っても開き直すたびに戻る。保存を許すと設定が残り、
    /// プレビューを切ったフォルダでは中身が読まれなくなる＝落ちてこない。
    ///
    /// 代償は Drive 側に `.DS_Store` が増えること。既定では入れる。
    ///
    /// 切り替えは残してある。これは利用者の Drive にこちらがファイルを書く設定で、
    /// 共有フォルダなら相手にも見える。断る手立てごと無くすのは避ける
    static var keepsFinderSettings: Bool {
        get { (UserDefaults.standard.object(forKey: finderSettingsKey) as? Bool) ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: finderSettingsKey)
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
