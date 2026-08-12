import Foundation
import ServiceManagement

// 設定の保存と読み出し。
//
// 数が少ないので UserDefaults に直接置く。ログイン時の起動だけは OS 側が持つ状態なので、
// こちらでは持たず ServiceManagement に問い合わせる。二重に持つと必ずずれる。

enum Settings {
    private static let mountPointKey = "mountPoint"
    private static let cacheDirKey = "cacheDir"
    private static let remoteKey = "remote"
    private static let readAheadKey = "readAhead"
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

    /// 利用者が指定した値。空のときは resolvedCacheDir が決める
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

        if let volume = volumeRoot(of: Paths.cacheParent(of: mountPoint)) {
            return (volume as NSString).appendingPathComponent(".gocci-cache")
        }

        let fallback = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        return fallback?.appendingPathComponent("io.kkweb.gocci").path ?? NSTemporaryDirectory()
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
    static var cacheMaxAge: String {
        get { UserDefaults.standard.object(forKey: cacheMaxAgeKey) as? String ?? "30d" }
        set {
            UserDefaults.standard.set(newValue, forKey: cacheMaxAgeKey)
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    /// キャッシュ全体の上限（`--vfs-cache-max-size`）。
    ///
    /// rclone の既定は上限なし。寿命を延ばす以上、歯止めが要る。空にすると上限なしに戻る
    static var cacheMaxSize: String {
        get { UserDefaults.standard.object(forKey: cacheMaxSizeKey) as? String ?? "50G" }
        set {
            UserDefaults.standard.set(newValue, forKey: cacheMaxSizeKey)
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    // MARK: - 先読み

    /// 読んだ位置より先を、どれだけ余分に取りに行くか（`--vfs-read-ahead`）。
    ///
    /// 空なら渡さない。rclone の既定は先読み無しで、開かれた部分しか落ちてこない。
    /// 大きく取ると「一度開いたら最後まで落ちてくる」に近づくが、少し覗いただけの
    /// 大きなファイルまで丸ごと落ちてくる。`defaults write io.kkweb.gocci readAhead 100G`
    static var readAhead: String {
        get { UserDefaults.standard.string(forKey: readAheadKey) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: readAheadKey)
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    /// 設定画面から見た「開いたファイルを最後まで取得する」。
    /// 実体は先読みの大きさなので、入りきらない大きさを渡して事実上「全部」にする
    static var fetchesWholeFile: Bool {
        get { !readAhead.isEmpty }
        set { readAhead = newValue ? "100G" : "" }
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
