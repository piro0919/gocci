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

    /// 直近に書き出した割合。途中で止まっているものを探すのに使う
    private static var lastProgress: [String: Int] = [:]
    /// 前回の書き出しから割合が増えたものがあったか
    private static var advancing = false
    /// 道 → 欠けている最初の位置
    private static var lastGaps: [String: Int64] = [:]
    private static let progressLock = NSLock()

    /// 途中で止まっているファイルと、欠けている最初の位置。
    /// 進んでいる順に返す（あと少しのものから片付ける）
    static func unfinished() -> [(path: String, gap: Int64)] {
        progressLock.lock()
        defer { progressLock.unlock() }
        return
            lastProgress
            .filter { $0.value > 0 && $0.value < 100 }
            .sorted { $0.value > $1.value }
            .compactMap { path, _ in lastGaps[path].map { (path: path, gap: $0) } }
    }

    /// 取得の途中にあるもの。進んでいる順に返す
    static func partials() -> [(path: String, percent: Int)] {
        progressLock.lock()
        defer { progressLock.unlock() }
        return
            lastProgress
            .filter { $0.value > 0 && $0.value < 100 }
            .sorted { $0.value > $1.value }
            .map { (path: $0.key, percent: $0.value) }
    }

    /// 今この瞬間、何かが落ちてきているか。前回の書き出しから割合が増えたものがあれば真
    static func isFetching() -> Bool {
        progressLock.lock()
        defer { progressLock.unlock() }
        return advancing
    }

    /// 書き出しを始める。キャッシュは黙って増えたり消えたりするので、様子を見に行く
    static func start() {
        write()
        timer?.invalidate()
        // メニューを開いている間も回す必要がある。既定の作り方だと、そのあいだ止まる
        let created = Timer(timeInterval: 5, repeats: true) { _ in write() }
        RunLoop.main.add(created, forMode: .common)
        timer = created
    }

    static func write() {
        let mountPoint = (Settings.mountPoint as NSString).standardizingPath
        let cacheDir = Settings.resolvedCacheDir
        let remote = Settings.remote

        queue.async {
            var progress: [String: Int] = [:]
            var gaps: [String: Int64] = [:]
            if !mountPoint.isEmpty {
                for root in cacheRoots(under: cacheDir, remote: remote, folder: "vfsMeta") {
                    let (found, holes) = scan(root)
                    progress.merge(found) { left, right in max(left, right) }
                    gaps.merge(holes) { left, _ in left }
                }
            }

            let state: [String: Any] = [
                "mountPoint": mountPoint,
                // 道 → 落ちてきた割合（0〜100）。100 なら全部手元にある
                "progress": progress,
            ]

            progressLock.lock()
            advancing = progress.contains { path, percent in
                percent > (lastProgress[path] ?? 0)
            }
            lastProgress = progress
            lastGaps = gaps
            progressLock.unlock()

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
    private static func scan(_ root: String) -> ([String: Int], [String: Int64]) {
        guard let walker = FileManager.default.enumerator(atPath: root) else { return ([:], [:]) }

        var found: [String: Int] = [:]
        var gaps: [String: Int64] = [:]
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
            let name = path.precomposedStringWithCanonicalMapping
            found[name] = Paths.percentage(size: size, ranges: ranges)
            gaps[name] = Paths.firstGap(size: size, ranges: ranges)

            // 数が膨らむと書き出しも読み込みも重くなる。実用の範囲で頭を打つ
            if found.count >= 20000 { break }
        }
        return (found, gaps)
    }
}
