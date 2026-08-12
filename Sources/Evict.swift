import Foundation

// 「手元から削除」の実行役。
//
// Finder の右クリックから拡張が頼み、こちらが実際に消す。拡張はサンドボックスの中に
// いてキャッシュへ手が届かないので、頼みごとを自分のコンテナへ書き、こちらが拾う。
// バッジの一覧と同じ経路を逆向きに使っている。
//
// 消すのは rclone のキャッシュだけ。Drive の実体には触らない。

enum Evict {
    /// 拡張が頼みごとを置く場所
    private static var requestURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/io.kkweb.gocci.FinderSync/Data/Library/Application Support",
                isDirectory: true)
            .appendingPathComponent("evict.json")
    }

    private static var timer: Timer?

    static func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in take() }
    }

    /// 頼まれた道を消して、頼みごとを片付ける
    private static func take() {
        guard let data = try? Data(contentsOf: requestURL),
            let paths = try? JSONSerialization.jsonObject(with: data) as? [String],
            !paths.isEmpty
        else { return }

        try? FileManager.default.removeItem(at: requestURL)

        let mountPoint = (Settings.mountPoint as NSString).standardizingPath
        guard !mountPoint.isEmpty else { return }

        for path in paths {
            let full = (path as NSString).standardizingPath
            guard full.hasPrefix(mountPoint + "/") else { continue }
            drop(String(full.dropFirst(mountPoint.count + 1)))
        }

        BadgeIndex.write()
    }

    /// キャッシュから1つ落とす。書き戻していないものは残す
    private static func drop(_ relative: String) {
        let cacheDir = Settings.resolvedCacheDir
        let remote = Settings.remote

        for folder in ["vfs", "vfsMeta"] {
            let roots = (try? FileManager.default.contentsOfDirectory(
                atPath: "\(cacheDir)/\(folder)")) ?? []

            for root in roots where root == remote || root.hasPrefix("\(remote){") {
                let target = "\(cacheDir)/\(folder)/\(root)/\(relative)"

                // Drive へ送り終えていないものは消さない。消せば書いた内容が失われる
                if folder == "vfsMeta", isDirty(target) {
                    logger.info("まだ書き戻していないので残す: \(relative, privacy: .public)")
                    return
                }
                try? FileManager.default.removeItem(atPath: target)
            }
        }
        logger.info("手元から削除した: \(relative, privacy: .public)")
    }

    private static func isDirty(_ metaPath: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: metaPath),
            let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return (meta["Dirty"] as? Bool) ?? false
    }
}
