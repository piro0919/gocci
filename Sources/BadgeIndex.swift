import Foundation

// Finder のバッジに使う一覧を書き出す。
//
// 拡張はサンドボックスの中で動くので、設定もキャッシュも自分では読めない。
// 読めるのは自分のコンテナだけ。そこでアプリ側が「今どこがマウント先か」と
// 「キャッシュに実体がある道の一覧」を書き、拡張はそれを読むだけにする。
//
// 共有には App Group を使わない。あちらは Developer ID の団体識別子が要るので、
// アドホック署名では作れない。コンテナへ直接置く方が確実で、こちらは
// サンドボックスの外にいるので書き込める。

enum BadgeIndex {
    /// 拡張のコンテナ。サンドボックスの中からは、ここが書類の置き場所として見える
    private static var stateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/io.kkweb.gocci.FinderSync/Data/Library/Application Support",
                isDirectory: true)
            .appendingPathComponent("state.json")
    }

    private static let queue = DispatchQueue(label: "io.kkweb.gocci.badge")
    private static var timer: Timer?

    /// 書き出しを始める。キャッシュは黙って増えたり消えたりするので、様子を見に行く
    static func start() {
        write()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in write() }
    }

    static func write() {
        let mountPoint = (Settings.mountPoint as NSString).standardizingPath
        let cacheDir = Settings.resolvedCacheDir
        let remote = Settings.remote

        queue.async {
            var progress: [String: Int] = [:]
            if !mountPoint.isEmpty {
                for root in cacheRoots(under: cacheDir, remote: remote, folder: "vfsMeta") {
                    progress.merge(percentages(under: root)) { left, right in max(left, right) }
                }
            }

            let state: [String: Any] = [
                "mountPoint": mountPoint,
                // 道 → 落ちてきた割合（0〜100）。100 なら全部手元にある
                "progress": progress,
            ]

            do {
                try FileManager.default.createDirectory(
                    at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONSerialization.data(withJSONObject: state)
                try data.write(to: stateURL, options: .atomic)
                let complete = progress.values.filter { $0 >= 100 }.count
                logger.info("バッジの一覧を書いた: 全 \(progress.count) 件、うち完全に手元 \(complete) 件")
            } catch {
                logger.error("バッジの一覧を書けなかった: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// キャッシュの中で、このリモートの実体が置かれている場所。
    ///
    /// rclone は `vfs/gdrive{a4x2W}` のように、リモート名の後ろへ設定の指紋を付ける。
    /// 名前を決め打ちにすると空振りするので、前方一致で拾う
    private static func cacheRoots(under cacheDir: String, remote: String, folder: String)
        -> [String]
    {
        let vfs = "\(cacheDir)/\(folder)"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: vfs)) ?? []
        return
            names
            .filter { Paths.isCacheRoot($0, remote: remote) }
            .map { "\(vfs)/\($0)" }
    }

    /// キャッシュの控えを読んで、道ごとに「落ちてきた割合」を出す。
    ///
    /// rclone は `vfsMeta` に本来の大きさ（Size）と、落ちてきた範囲（Rs）を書いている。
    /// 実体があるかどうかだけを見ると、途中まで落ちたものまで「手元にある」と数えてしまう
    private static func percentages(under root: String) -> [String: Int] {
        guard let walker = FileManager.default.enumerator(atPath: root) else { return [:] }

        var found: [String: Int] = [:]
        for case let path as String in walker {
            var isDirectory: ObjCBool = false
            let full = "\(root)/\(path)"
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory),
                !isDirectory.boolValue,
                let data = FileManager.default.contents(atPath: full),
                let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let size = (meta["Size"] as? NSNumber)?.int64Value ?? 0
            let ranges = ((meta["Rs"] as? [[String: Any]]) ?? []).map {
                (
                    pos: ($0["Pos"] as? NSNumber)?.int64Value ?? 0,
                    size: ($0["Size"] as? NSNumber)?.int64Value ?? 0
                )
            }
            found[path.precomposedStringWithCanonicalMapping] =
                Paths.percentage(size: size, ranges: ranges)

            // 数が膨らむと書き出しも読み込みも重くなる。実用の範囲で頭を打つ
            if found.count >= 20000 { break }
        }
        return found
    }
}
