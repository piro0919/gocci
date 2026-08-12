import Foundation

// 途中で止まったファイルを最後まで取りにいく。
//
// 「開いたファイルを最後まで取得する」を入れているのに、47% で止まったまま残るのは
// 約束を守れていない状態になる。中断は普通に起きる（アプリの終了、外付けを抜く、
// 通信の切断、rclone の異常終了）ので、放っておくと途中のものが溜まっていく。
//
// やることは、止まっているファイルの先頭を 1 バイト読むだけ。あとは rclone の先読みが
// 残りを落とす。1バイトで 100% まで進むことは実機で確かめた。
//
// この仕掛けは設定が入っているときだけ動く。切っている人にとっては、
// 開いてもいないファイルが裏で落ちてくることになるため。

enum Finisher {
    /// 一度に追いかけるのは1つだけ。まとめてつつくと、外付けを繋ぎ直した直後などに
    /// 大量の取得が一斉に走る
    private static let interval: TimeInterval = 20
    /// 主スレッドの時計は、メニューを開いている間まったく動かない（実測した）。
    /// 別のスレッドで回して、画面の操作に左右されないようにする
    private static let queue = DispatchQueue(label: "io.kkweb.gocci.finish")
    private static var timer: DispatchSourceTimer?

    static func start() {
        timer?.cancel()

        let created = DispatchSource.makeTimerSource(queue: queue)
        created.schedule(deadline: .now() + interval, repeating: interval)
        created.setEventHandler { tick() }
        created.resume()
        timer = created
    }

    private static func tick() {
        guard Settings.fetchesWholeFile, MountController.shared.state == .mounted else { return }

        // 何かが落ちてきている間は手を出さない。次々つつくと、大きなファイルが
        // 何本も同時に落ち始めて回線を占有する
        guard !BadgeIndex.isFetching() else { return }

        let mountPoint = (Settings.mountPoint as NSString).standardizingPath
        guard !mountPoint.isEmpty, let target = BadgeIndex.unfinished().first else { return }

        DispatchQueue.global(qos: .utility).async {
            let path = "\(mountPoint)/\(target.path)"
            guard let handle = FileHandle(forReadingAtPath: path) else { return }
            defer { try? handle.close() }

            // 欠けている最初の位置から、まとまった量を読む。
            //
            // 1 バイトでは rclone は何も取りに行かない（実測した。つついた記録だけが残り、
            // 1 バイトも増えなかった）。1MB 読ませると取得が始まり、あとは先読みが続ける
            try? handle.seek(toOffset: UInt64(target.gap))
            _ = try? handle.read(upToCount: 1_000_000)
            logger.info(
                """
                途中で止まっていたので続きを取りにいく: \(target.path, privacy: .public) \
                （\(target.gap) バイト目から）
                """)
        }
    }
}
