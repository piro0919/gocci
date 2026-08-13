import Darwin
import Foundation
import OSLog

/// 落ちた・繋ぎ直したといった出来事は、後から追えないと直しようがない。
/// `log show --predicate 'subsystem == "io.kkweb.gocci"' --last 10m` で読める
let logger = Logger(subsystem: "io.kkweb.gocci", category: "mount")

// rclone の起動と停止。
//
// `rclone nfsmount` を子プロセスとして持つ。`--daemon` は付けない。付けると rclone が
// すぐ抜けてしまい、落ちたことをこちらから知る手立てが無くなる。前面で走らせておけば、
// 終了をそのまま受け取れる。
//
// マウントできたかどうかは rclone の出力ではなく statfs で確かめる。実際にマウント表に
// 載ったかが知りたいことで、rclone が何を書いたかではない。

enum MountState: Equatable {
    case unmounted
    /// マウント先を置くディスクがまだ繋がっていない。繋がるのを待っている
    case waitingForDisk
    /// rclone が勝手に落ちた。少し置いてから自分で繋ぎ直す
    case reconnecting
    case mounting
    case unmounting
    case mounted
    case failed(String)
}

extension Notification.Name {
    static let mountStateChanged = Notification.Name("gocci.mountStateChanged")
}

final class MountController {
    static let shared = MountController()

    /// マウントが表に載るまで待つ上限。
    ///
    /// 手元では 5 秒から 30 秒までばらついた。rclone は NFS サーバーを上げる前に Drive の
    /// 認証を通すので、そこの機嫌に引きずられる。短く切ると、繋がる寸前で諦めることになる
    private static let mountTimeout: TimeInterval = 120
    /// アンマウントを待つ上限
    private static let unmountTimeout: TimeInterval = 15
    private static let pollInterval: TimeInterval = 0.3

    private(set) var state: MountState = .unmounted {
        didSet {
            guard state != oldValue else { return }

            logger.info(
                """
                状態: \(String(describing: oldValue), privacy: .public) \
                → \(String(describing: self.state), privacy: .public)
                """)
            NotificationCenter.default.post(name: .mountStateChanged, object: nil)
        }
    }

    private var process: Process?
    /// rclone の標準エラー出力。失敗したときに最後の行だけ見せる
    private var log = ""
    private let logLock = NSLock()
    private let queue = DispatchQueue(label: "io.kkweb.gocci.mount")

    private init() {
        // ここでは何も決めない。前回の残りが表に載っていても、それが生きているとは限らない。
        // 引き継ぐか外すかは mount() が応答を見て決める
    }

    // MARK: - 同梱した rclone

    /// アプリの中に入れたものを使う。検証したバージョンで固定したいので、
    /// 見つからないときに Homebrew などへ回り込むことはしない
    static var rclonePath: String? {
        guard let url = Bundle.main.url(forAuxiliaryExecutable: "rclone") else { return nil }
        return FileManager.default.isExecutableFile(atPath: url.path) ? url.path : nil
    }

    // MARK: - 外付けを待つ

    /// ログイン直後は、外付けが繋がるより先にこちらが起きていることがある。
    /// 場所ができるまで待ってからマウントする
    func mountWhenReady() {
        guard state == .unmounted || state == .waitingForDisk || isFailed(state) else { return }
        guard !Settings.mountPoint.isEmpty else { return }

        if Settings.mountPointParentExists {
            mount()
            return
        }
        if state != .waitingForDisk {
            waitStartedAt = Date()
            state = .waitingForDisk
        }
    }

    /// 待ちを諦めるまで。これを過ぎたら未接続に戻し、メニューから繋ぎ直してもらう。
    /// 待ち続けても害は無いが、状態表示が「待っています」のまま居座るのは分かりにくい
    private static let waitLimit: TimeInterval = 30 * 60
    private var waitStartedAt: Date?

    // MARK: - マウント

    func mount() {
        guard
            state == .unmounted || state == .waitingForDisk || state == .reconnecting
                || isFailed(state)
        else { return }

        let mountPoint = (Settings.mountPoint as NSString).standardizingPath
        guard !mountPoint.isEmpty else {
            state = .failed(L.mountPointUnset)
            return
        }
        guard let rclone = Self.rclonePath else {
            state = .failed(L.rcloneMissing)
            return
        }

        // 既にマウント表に載っている場合。応答するなら引き継ぎ、返らないなら抜け殻として外す。
        // 表に載っているかどうかだけで判断すると、相手の居ないマウントを繋がっていると
        // 報せることになる（rclone を止めた直後に起動し直すと、実際にそうなった）
        if Mounts.isMounted(mountPoint) {
            // 自分が起動した rclone のマウントではない。前のアプリが残していったものか、
            // 抜け殻か。どちらにせよ外して張り直す。
            //
            // 引き継ぐと、その rclone が死んでもこちらには終了が届かない。statfs は抜け殻でも
            // 「マウント済み」と答えるので、繋がっているつもりのまま Finder だけが
            // 永久に待つことになる（実際にそうなった）
            logger.info("自分のものではないマウントがある。外して張り直す")
            state = .mounting

            queue.async { [weak self] in
                guard let self else { return }
                self.process?.terminate()
                self.killOrphans(mountPoint)

                if Mounts.isMounted(mountPoint), !self.forceUnmount(mountPoint) {
                    self.finish(.failed(L.staleMountStuck(mountPoint)))
                    return
                }
                DispatchQueue.main.async {
                    self.state = .unmounted
                    self.mount()
                }
            }
            return
        }

        // リンクの先へマウントしない。他のアプリがマウント先へのリンクを置いていることがあり、
        // そこへ乗せにいくと失敗する。失敗の後始末で、リンクの先を含むボリュームごと
        // 外されることもある（CloudMounter の GoogleDrive で踏んだ）
        if let type = try? FileManager.default.attributesOfItem(atPath: mountPoint)[.type] as? FileAttributeType,
            type == .typeSymbolicLink
        {
            state = .failed(L.mountPointIsLink)
            return
        }

        // 置き場所ごと無いときは待ちに回す。ここで作りにいくと、抜けている外付けの代わりに
        // 内蔵ディスクへ `/Volumes/HIKSEMI` を作ってしまい、そこへマウントすることになる
        guard Settings.mountPointParentExists else {
            waitStartedAt = Date()
            state = .waitingForDisk
            return
        }

        let cacheDir = Settings.resolvedCacheDir
        let remote = Settings.remote
        let options = Options(
            cacheMaxAge: Settings.cacheMaxAge, cacheMaxSize: Settings.cacheMaxSize,
            keepsFinderSettings: Settings.keepsFinderSettings)
        state = .mounting

        queue.async { [weak self] in
            self?.launch(
                rclone: rclone, remote: remote, mountPoint: mountPoint, cacheDir: cacheDir,
                options: options)
        }
    }

    /// 設定から決まる、rclone へ渡す値。マウントを始めた時点のものを持ち回る
    private struct Options {
        let cacheMaxAge: String
        let cacheMaxSize: String
        let keepsFinderSettings: Bool
    }

    private func launch(
        rclone: String, remote: String, mountPoint: String, cacheDir: String, options: Options
    ) {
        // 途中の道は作らない。外付けが抜けている隙に、内蔵へその場しのぎの入れ物を
        // 作ってしまうのを防ぐ。作るのはマウント先とキャッシュ先そのものだけ
        do {
            try createDirectoryIfNeeded(mountPoint)
            try createDirectoryIfNeeded(cacheDir)
        } catch {
            finish(.failed(error.localizedDescription))
            return
        }

        logLock.lock()
        log = ""
        logLock.unlock()

        let task = Process()
        task.executableURL = URL(fileURLWithPath: rclone)
        task.arguments = [
            "nfsmount", "\(remote):", mountPoint,
            // これが無いと読み取り専用になる
            "--vfs-cache-mode", "full",
            "--cache-dir", cacheDir,
            // Google ドキュメント類は .webloc で出す。開くとブラウザで Drive が開く
            "--drive-export-formats", "webloc",
        ]

        // 先読みは使わない。読んだところだけが落ちてくる素の動きにする。
        // 最後まで取りにいく役目はアプリが持つ（Finisher）
        if !options.cacheMaxAge.isEmpty {
            task.arguments? += ["--vfs-cache-max-age", options.cacheMaxAge]
        }
        if !options.cacheMaxSize.isEmpty {
            task.arguments? += ["--vfs-cache-max-size", options.cacheMaxSize]
        }
        // 既定では rclone が .DS_Store を捨てる。捨てられると Finder の表示設定が残らない
        if options.keepsFinderSettings {
            task.arguments? += ["--noappledouble=false"]
        }

        let errorPipe = Pipe()
        task.standardError = errorPipe
        task.standardOutput = FileHandle.nullDevice
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.append(text)
        }

        task.terminationHandler = { [weak self] _ in
            errorPipe.fileHandleForReading.readabilityHandler = nil
            self?.processDidExit()
        }

        do {
            try task.run()
        } catch {
            finish(.failed(error.localizedDescription))
            return
        }
        process = task

        // マウント表に載るまで待つ。載る前に rclone が落ちることもあるので、両方を見る
        let deadline = Date().addingTimeInterval(Self.mountTimeout)
        while Date() < deadline {
            if Mounts.isMounted(mountPoint) {
                busyRetries = 0
                finish(.mounted)
                return
            }
            if !task.isRunning { return }  // 後始末は terminationHandler がやる
            Thread.sleep(forTimeInterval: Self.pollInterval)
        }

        // ここで SIGTERM を送ってはいけない。rclone は終わるときに後片付けとして
        // マウント先を外しにいくが、まだ何もマウントされていないと、外す相手が
        // 「その場所を含むボリューム」だと解釈され、外付けごと外れる（手元で3回起きた）。
        // 上がっていないのだから外すものは無い。片付けをさせずに落とす
        kill(task.processIdentifier, SIGKILL)
        logger.error("マウントが \(Int(Self.mountTimeout)) 秒で終わらなかったので rclone を落とした")
        finish(.failed(L.mountTimedOut))
    }

    /// 前のアプリが残していった rclone を始末する。
    ///
    /// アプリが片付けの余地なく落ちると、子の rclone が生き残る。マウントを外しても
    /// プロセスは残り、次のアプリが張り直すと同じ場所に複数の rclone が居ることになる。
    /// 互いに邪魔をして取得が止まるので、張り直す前に掃除する（実際に5つ溜まった）
    private func killOrphans(_ mountPoint: String) {
        guard let rclone = Self.rclonePath else { return }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", "\(rclone) nfsmount .* \(mountPoint)"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return }
        task.waitUntilExit()

        let output =
            String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let mine = process?.processIdentifier
        for line in output.split(separator: "\n") {
            guard let pid = Int32(line.trimmingCharacters(in: .whitespaces)), pid != mine else {
                continue
            }
            logger.info("前のアプリが残した rclone を落とす: \(pid)")
            kill(pid, SIGKILL)
        }
    }

    /// そのマウントが生きているか。表に載っていても、相手が死んでいれば読み出しは返らない
    private func responds(_ mountPoint: String) -> Bool {
        // 短く切ると、忙しいだけの rclone を落としたと見なす
        run("/bin/ls", [mountPoint], timeout: 20)
    }

    private func createDirectoryIfNeeded(_ path: String) throws {
        guard !FileManager.default.fileExists(atPath: path) else { return }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    }

    // MARK: - メニューからの操作

    /// 人が押したときの入口。自動で繋ぎ直した回数はここで数え直す。
    /// 手で繋ぎ直したなら、それまでの失敗は引きずらない
    func toggleByUser() {
        restarts.removeAll()

        switch state {
        case .mounted:
            unmount()
        case .unmounted, .waitingForDisk, .reconnecting, .failed:
            mount()
        case .mounting, .unmounting:
            break
        }
    }

    /// 設定が変わったので繋ぎ直す。切ってから、外れたのを見届けて繋ぐ
    func remount() {
        guard state == .mounted else { return }
        unmount()

        var waited = 0.0
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            waited += 1
            if self.state == .unmounted {
                timer.invalidate()
                self.mount()
            } else if waited > 30 {
                timer.invalidate()
            }
        }
    }

    // MARK: - アンマウント

    func unmount() {
        guard state == .mounted || isFailed(state) else { return }

        let mountPoint = (Settings.mountPoint as NSString).standardizingPath
        state = .unmounting

        queue.async { [weak self] in
            self?.stop(mountPoint: mountPoint)
        }
    }

    private func stop(mountPoint: String) {
        if Mounts.isMounted(mountPoint) {
            // rclone は SIGTERM を受けると自分でアンマウントして終わる。
            // こちらが umount を先に叩くと、rclone が書き戻す途中で足元を外すことになる
            process?.terminate()
        } else if let task = process {
            // 上がっていないときに片付けをさせると、外す相手を取り違えて
            // 外付けごと外される。片付けの余地を与えずに落とす
            kill(task.processIdentifier, SIGKILL)
        }

        if waitUntilUnmounted(mountPoint) {
            finish(.unmounted)
            return
        }

        // 落ちた rclone の残骸や、外で張られたマウントはこちらで外す
        if run("/sbin/umount", [mountPoint]), waitUntilUnmounted(mountPoint) {
            finish(.unmounted)
            return
        }
        if forceUnmount(mountPoint) {
            finish(.unmounted)
            return
        }

        finish(.failed(L.unmountFailed(lastLogLine())))
    }

    /// 強制的に外す。
    ///
    /// 手立ては `umount -f` だけ。他は使えないことを手元で確かめた。
    ///
    /// - `diskutil unmount force` — 相手の居ない NFS に投げると、こちらから殺せない状態のまま
    ///   戻ってこなくなる
    /// - DiskArbitration（`DADiskUnmount`）— 同じ場面でアプリのプロセスごと固まる
    ///
    /// その `umount -f` も、外付けの上のマウントに対してはアプリから叩くと
    /// `Operation not permitted` で弾かれる。同じ道具がターミナルからは通るので、権限の違い。
    /// 外せなかったことは呼び出し元へ返し、人に頼む
    private func forceUnmount(_ mountPoint: String) -> Bool {
        for attempt in 0..<3 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 1) }
            run("/sbin/umount", ["-f", mountPoint])
            if !Mounts.isMounted(mountPoint) { return true }
        }
        return false
    }

    private func waitUntilUnmounted(_ mountPoint: String) -> Bool {
        let deadline = Date().addingTimeInterval(Self.unmountTimeout)
        while Date() < deadline {
            if !Mounts.isMounted(mountPoint) { return true }
            Thread.sleep(forTimeInterval: Self.pollInterval)
        }
        return false
    }

    /// 外部の道具を呼ぶ。返ってこないものがあるので、待つ時間に上限を置く。
    /// 上限まで待ったら諦めて失敗として返す。ここで止まると、以降の操作を全部道連れにする
    @discardableResult
    private func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 10) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments

        // 失敗したときに理由が要る。umount の「なぜ外せないか」は本人しか知らない
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
        } catch {
            logger.error("\(path, privacy: .public) を起動できなかった: \(error.localizedDescription, privacy: .public)")
            return false
        }

        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard !task.isRunning else {
            logger.error("\(path, privacy: .public) が \(Int(timeout)) 秒で返らなかった")
            task.terminate()
            return false
        }

        let output =
            String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if task.terminationStatus != 0 {
            logger.error(
                """
                \(path, privacy: .public) \(arguments.joined(separator: " "), privacy: .public) \
                が失敗した（\(task.terminationStatus)）: \(output, privacy: .public)
                """)
        }
        return task.terminationStatus == 0
    }

    // MARK: - 状態

    /// rclone が終わった。こちらが止めたのか、勝手に落ちたのかを分ける
    private func processDidExit() {
        process = nil

        logLock.lock()
        let tail = log
        logLock.unlock()
        logger.info("rclone が終了した。出力:\n\(tail, privacy: .public)")
        DispatchQueue.main.async {
            switch self.state {
            case .mounted:
                // 繋がっていたものが落ちた。繋ぎ直しにいく
                self.recover()
            case .mounting:
                // 場所がまだ掴まれているだけなら、少し置けば通る。
                // それ以外は設定か認証の問題なので、繰り返しても同じ
                let reason = self.lastLogLine()
                if reason.contains("Resource busy"), self.busyRetries < Self.busyRetryLimit {
                    self.busyRetries += 1
                    logger.error("場所がまだ掴まれている。置いてからやり直す（\(self.busyRetries) 回目）")
                    self.state = .reconnecting
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                        guard let self, self.state == .reconnecting else { return }
                        self.mount()
                    }
                    return
                }
                self.busyRetries = 0
                self.state = .failed(L.mountFailed(reason))
            case .unmounting, .unmounted, .waitingForDisk, .reconnecting, .failed:
                break
            }
        }
    }

    // MARK: - 落ちたときの繋ぎ直し

    /// 自分で繋ぎ直す回数の上限と、数え直すまでの間隔。
    /// 直せる類の不調は数回で直る。直らないものは何回やっても直らず、その間 Drive を叩き続ける
    private static let restartLimit = 3
    private static let restartWindow: TimeInterval = 10 * 60
    /// 落ちてから繋ぎ直すまで。回を追うごとに間を空ける
    private static let restartDelays: [TimeInterval] = [2, 5, 15]
    private var restarts: [Date] = []

    private func recover() {
        process = nil

        // 外付けごと消えたのなら、落ちたのではなく抜かれた。繋ぎ直さずに、挿し直されるのを待つ
        guard Settings.mountPointParentExists else {
            waitStartedAt = Date()
            state = .waitingForDisk
            return
        }

        let now = Date()
        restarts = restarts.filter { now.timeIntervalSince($0) < Self.restartWindow }
        guard restarts.count < Self.restartLimit else {
            state = .failed(L.restartGaveUp(lastLogLine()))
            return
        }

        let delay = Self.restartDelays[min(restarts.count, Self.restartDelays.count - 1)]
        let mountPoint = (Settings.mountPoint as NSString).standardizingPath
        restarts.append(now)
        state = .reconnecting

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            // この間に人が触っていたら、そちらを優先する
            guard let self, self.state == .reconnecting else { return }

            self.queue.async {
                // rclone が死んでもマウント表の項目は残る。応答しない抜け殻なのに statfs では
                // 繋がって見えるので、繋ぎ直す前にこちらで外す。
                // 外せないまま進むと、抜け殻を見て「繋がっている」と誤って報せることになる
                if Mounts.isMounted(mountPoint) {
                    logger.info("抜け殻のマウントを外す: \(mountPoint, privacy: .public)")
                    guard self.clearStaleMount(mountPoint) else {
                        logger.error("抜け殻のマウントを外せなかった")
                        self.finish(.failed(L.staleMountStuck(mountPoint)))
                        return
                    }
                }

                DispatchQueue.main.async {
                    guard self.state == .reconnecting else { return }
                    self.mount()
                }
            }
        }
    }

    /// 応答しないマウントを外す。相手が死んでいるので、待つ形の umount は返ってこない。強制で外す。
    ///
    /// 外れた直後はまだ場所が掴まれていて、すぐ張り直すと `Resource busy` で撥ねられたり、
    /// マウントが終わらなくなったりする。落ち着くまで少し置く
    @discardableResult
    private func clearStaleMount(_ mountPoint: String) -> Bool {
        guard forceUnmount(mountPoint) else { return false }
        Thread.sleep(forTimeInterval: 5)
        return true
    }

    /// 最後に応答を確かめた時刻。表に載っているかどうかだけでは、生きているか分からない
    private var lastProbe = Date()
    /// 応答を確かめる間隔
    private static let probeInterval: TimeInterval = 60

    /// 場所が掴まれたままのときに、置いてからやり直す回数
    private static let busyRetryLimit = 3
    private var busyRetries = 0

    /// 続けて何回返らなければ落ちたと見なすか。
    ///
    /// 1回で落とすと、忙しいだけの rclone を殺してしまう。先読みで大量に落としている間は
    /// 一覧が遅れることがあり、そのたびに繋ぎ直すと「サーバ接続が中断されました」が出る
    private static let probeStrikes = 2
    private var probeFailures = 0

    /// マウントが生きているかを確かめる。続けて返らなければ落ちたものとして扱う
    private func probeIfDue() {
        guard state == .mounted, Date().timeIntervalSince(lastProbe) > Self.probeInterval else {
            return
        }
        lastProbe = Date()

        let mountPoint = (Settings.mountPoint as NSString).standardizingPath
        queue.async { [weak self] in
            guard let self else { return }

            guard !self.responds(mountPoint) else {
                self.probeFailures = 0
                return
            }

            self.probeFailures += 1
            logger.error("マウントが応答しない（\(self.probeFailures) 回目）")
            guard self.probeFailures >= Self.probeStrikes else { return }
            self.probeFailures = 0

            DispatchQueue.main.async {
                guard self.state == .mounted else { return }

                // 息はあるのに返事をしない rclone は、こちらで落とす。
                // 生かしたまま張り直そうとしても、相手が場所を握ったままになる
                if let task = self.process {
                    kill(task.processIdentifier, SIGKILL)
                    return  // 後始末は終了の受け取り口がやる
                }
                self.recover()
            }
        }
    }

    /// 外から状態が変わることがある。外付けを抜かれた、別のアプリに外された、など
    func refresh() {
        if state == .waitingForDisk {
            if Settings.mountPointParentExists {
                mount()
            } else if let started = waitStartedAt,
                Date().timeIntervalSince(started) > Self.waitLimit
            {
                state = .unmounted
            }
            return
        }

        guard state == .mounted || state == .unmounted else { return }
        probeIfDue()

        let mounted = Mounts.isMounted(Settings.mountPoint)
        if mounted, state == .unmounted { state = .mounted }
        if !mounted, state == .mounted { state = .unmounted }
    }

    private func finish(_ next: MountState) {
        DispatchQueue.main.async { self.state = next }
    }

    private func isFailed(_ state: MountState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    // MARK: - rclone の出力

    private func append(_ text: String) {
        logLock.lock()
        log += text
        // 全部は要らない。失敗したときに最後の数行が読めればいい
        if log.count > 4000 { log = String(log.suffix(4000)) }
        logLock.unlock()
    }

    private func lastLogLine() -> String {
        logLock.lock()
        let text = log
        logLock.unlock()

        let lines = text.split(separator: "\n").map(String.init)
        // 失敗の理由として読ませたいのは不具合の行。rclone は常用の client_id について
        // NOTICE を出すので、素直に末尾を採ると毎回それが理由として出てしまう
        let line =
            lines.last(where: { $0.contains("ERROR") || $0.contains("CRITICAL") })
            ?? lines.last(where: { !$0.contains("NOTICE") })
            ?? lines.last ?? ""
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        if parts.count == 3, parts[0].contains("/"), parts[1].contains(":") {
            return String(parts[2])
        }
        return line
    }
}

// MARK: - マウント表

enum Mounts {
    /// その場所が今マウント点になっているか。
    ///
    /// 中身の有無では判断できない（アンマウント後も空の入れ物は残る）ので、statfs で
    /// 「この道がその場所自身をマウント点とする nfs か」を見る
    static func isMounted(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let standardized = (path as NSString).standardizingPath

        var info = statfs()
        guard statfs(standardized, &info) == 0 else { return false }

        return cString(info.f_fstypename) == "nfs" && cString(info.f_mntonname) == standardized
    }

    /// C の固定長配列は Swift ではタプルで来る。先頭から文字列として読む
    private static func cString<T>(_ value: T) -> String {
        withUnsafePointer(to: value) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
                String(cString: $0)
            }
        }
    }
}
