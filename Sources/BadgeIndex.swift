import Darwin
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
    /// 主スレッドの時計は、メニューを開いている間まったく動かない（実測した）。
    /// 別のスレッドで回して、画面の操作に左右されないようにする
    private static var timer: DispatchSourceTimer?

    /// 直近に書き出した割合。途中で止まっているものを探すのに使う
    private static var lastProgress: [String: Int] = [:]
    /// 前回の書き出しから割合が増えたものがあったか
    private static var advancing = false
    /// 道 → 欠けている最初の位置
    private static var lastGaps: [String: Int64] = [:]
    /// 道 → 手元にある量と、本来の大きさ。動いているかの判断と、MB での表示に使う
    private static var lastHeld: [String: Int64] = [:]
    private static var previousHeld: [String: Int64] = [:]
    private static var lastSizes: [String: Int64] = [:]
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

    /// 取得の途中にあるもの。
    ///
    /// **今まさに落ちてきているものを先に返す。** 割合の高い順に並べると、止まったまま
    /// 残っているものが上に居座り、動いている最中のファイルが一覧から漏れる
    static func partials() -> [(path: String, percent: Int, held: Int64, size: Int64)] {
        progressLock.lock()
        defer { progressLock.unlock() }

        return
            lastProgress
            .filter { $0.value > 0 && $0.value < 100 }
            .map { path, percent in
                (
                    path: path, percent: percent, held: lastHeld[path] ?? 0,
                    size: lastSizes[path] ?? 0, moving: (lastHeld[path] ?? 0) > (previousHeld[path] ?? 0)
                )
            }
            .sorted { left, right in
                if left.moving != right.moving { return left.moving }
                return left.percent > right.percent
            }
            .map { (path: $0.path, percent: $0.percent, held: $0.held, size: $0.size) }
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
        timer?.cancel()

        let created = DispatchSource.makeTimerSource(queue: queue)
        created.schedule(deadline: .now() + 5, repeating: 5)
        created.setEventHandler { write() }
        created.resume()
        timer = created
    }

    static func write() {
        let mountPoint = (Settings.mountPoint as NSString).standardizingPath
        let cacheDir = Settings.resolvedCacheDir
        let remote = Settings.remote

        queue.async {
            var progress: [String: Int] = [:]
            var gaps: [String: Int64] = [:]
            var held: [String: Int64] = [:]
            var sizes: [String: Int64] = [:]
            if !mountPoint.isEmpty {
                for root in cacheRoots(under: cacheDir, remote: remote, folder: "vfs") {
                    let scanned = scan(root)
                    progress.merge(scanned.progress) { left, right in max(left, right) }
                    gaps.merge(scanned.gaps) { left, _ in left }
                    held.merge(scanned.held) { left, _ in left }
                    sizes.merge(scanned.sizes) { left, _ in left }
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
            previousHeld = lastHeld
            lastHeld = held
            lastSizes = sizes
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

    /// キャッシュの実ファイルを見て、道ごとの取得状況を出す。
    ///
    /// rclone の控え（`vfsMeta`）は当てにならない。取得が終わるまで書き換わらないことがあり、
    /// 実際 4 秒ごとに 40MB 増えている最中でも、控えは 74MB のまま動かなかった。
    ///
    /// 実ファイルは穴あきで置かれているので、**実際に使っている量**がそのまま取得量になる。
    /// 穴の位置も、空き領域の頭を訊けば分かる
    private static func scan(_ root: String) -> (
        progress: [String: Int], gaps: [String: Int64], held: [String: Int64],
        sizes: [String: Int64]
    ) {
        guard let walker = FileManager.default.enumerator(atPath: root) else {
            return ([:], [:], [:], [:])
        }

        var found: [String: Int] = [:]
        var gaps: [String: Int64] = [:]
        var held: [String: Int64] = [:]
        var sizes: [String: Int64] = [:]

        for case let path as String in walker {
            let full = "\(root)/\(path)"

            var info = stat()
            guard stat(full, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }

            let size = Int64(info.st_size)
            // 使っている塊の数から、実際に手元にある量を出す
            let bytes = min(Int64(info.st_blocks) * 512, size)

            let name = path.precomposedStringWithCanonicalMapping
            sizes[name] = size
            held[name] = bytes
            found[name] = size <= 0 ? 100 : Int(min(100, bytes * 100 / size))
            gaps[name] = firstHole(in: full, size: size)

            // 数が膨らむと書き出しも読み込みも重くなる。実用の範囲で頭を打つ
            if found.count >= 20000 { break }
        }
        return (found, gaps, held, sizes)
    }

    /// 穴の頭。全部埋まっていれば nil
    private static func firstHole(in path: String, size: Int64) -> Int64? {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        let hole = lseek(descriptor, 0, SEEK_HOLE)
        guard hole >= 0, hole < size else { return nil }
        return Int64(hole)
    }
}
