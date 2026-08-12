import Foundation

// 途中で止まったファイルを最後まで取りにいく。
//
// 「開いたファイルを最後まで取得する」を入れているのに、47% で止まったまま残るのは
// 約束を守れていない状態になる。中断は普通に起きる（アプリの終了、外付けを抜く、
// 通信の切断、rclone の異常終了）ので、放っておくと途中のものが溜まっていく。
//
// やり方は、欠けている位置から順に読み進めるだけ。読んだところが rclone のキャッシュに残る。
//
// 時々つつく形も試したが、駄目だった。1回のつつきで 30MB ほど取れたあと、次まで何も
// 起きない。36 秒止まって一気に増える動きになり、止まっているようにしか見えない。
// 読み続ける形にすれば滑らかに進む。1 バイトでは何も起きないことも実測した。
//
// この仕掛けは設定が入っているときだけ動く。切っている人にとっては、
// 開いてもいないファイルが裏で落ちてくることになるため。

enum Finisher {
    /// ここまで読まれていれば「使った」と見なす。
    ///
    /// Finder はサムネイルのために動画の先頭を数 MB 読む。それを「開いた」と扱うと、
    /// フォルダを眺めただけで数 GB 落ちてくる。人が再生したなら、これは軽く超える
    private static let usedThreshold: Int64 = 32_000_000
    /// 残りがこれ以下なら、読まれた量にかかわらず片付ける。
    /// 小さい動画は Finder のサムネイルだけで 9 割方読まれる。そこで止めても得が無い
    private static let leftoverThreshold: Int64 = 32_000_000

    /// 一度に読む量
    private static let blockSize = 4_000_000
    /// 次の1本を探すまでの間隔
    private static let interval: TimeInterval = 5

    private static let queue = DispatchQueue(label: "io.kkweb.gocci.finish")
    private static var timer: DispatchSourceTimer?
    /// 今1本を読み進めている最中か。何本も並べて読むと回線を占有する
    private static var busy = false

    static func start() {
        timer?.cancel()

        let created = DispatchSource.makeTimerSource(queue: queue)
        created.schedule(deadline: .now() + interval, repeating: interval)
        created.setEventHandler { tick() }
        created.resume()
        timer = created
    }

    private static func tick() {
        guard !busy, Settings.fetchesWholeFile, MountController.shared.state == .mounted else {
            return
        }

        let mountPoint = (Settings.mountPoint as NSString).standardizingPath
        guard !mountPoint.isEmpty,
            let target = BadgeIndex.unfinished().first(where: {
                $0.held >= usedThreshold || $0.size - $0.held <= leftoverThreshold
            })
        else { return }

        busy = true
        DispatchQueue.global(qos: .utility).async {
            fill(mountPoint: mountPoint, relative: target.path, from: target.gap)
            queue.async { busy = false }
        }
    }

    /// 欠けている位置から、終わりまで読み進める。読んだところがキャッシュに残る
    private static func fill(mountPoint: String, relative: String, from offset: Int64) {
        let path = "\(mountPoint)/\(relative)"
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }

        try? handle.seek(toOffset: UInt64(offset))
        logger.info(
            "続きを取りにいく: \(relative, privacy: .public)（\(offset / 1_000_000)MB 目から）")

        var read: Int64 = 0
        while true {
            // 途中で設定が切られたり、外付けが抜かれたりしたら、その場でやめる
            guard Settings.fetchesWholeFile, MountController.shared.state == .mounted else { return }

            guard let block = try? handle.read(upToCount: blockSize), !block.isEmpty else { break }
            read += Int64(block.count)
        }
        logger.info("取り終えた: \(relative, privacy: .public)（\(read / 1_000_000)MB）")
    }
}
