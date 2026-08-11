import Darwin
import Foundation

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

    /// マウントが表に載るまで待つ上限。手元では 1 秒前後で載る
    private static let mountTimeout: TimeInterval = 30
    /// アンマウントを待つ上限
    private static let unmountTimeout: TimeInterval = 15
    private static let pollInterval: TimeInterval = 0.3

    private(set) var state: MountState = .unmounted {
        didSet {
            guard state != oldValue else { return }
            NotificationCenter.default.post(name: .mountStateChanged, object: nil)
        }
    }

    private var process: Process?
    /// rclone の標準エラー出力。失敗したときに最後の行だけ見せる
    private var log = ""
    private let logLock = NSLock()
    private let queue = DispatchQueue(label: "io.kkweb.gocci.mount")

    private init() {
        // 前回の残りが生きていることがある。アプリを再起動しただけで未接続には見せない
        if Mounts.isMounted(Settings.mountPoint) { state = .mounted }
    }

    // MARK: - 同梱した rclone

    /// アプリの中に入れたものを使う。検証したバージョンで固定したいので、
    /// 見つからないときに Homebrew などへ回り込むことはしない
    static var rclonePath: String? {
        guard let url = Bundle.main.url(forAuxiliaryExecutable: "rclone") else { return nil }
        return FileManager.default.isExecutableFile(atPath: url.path) ? url.path : nil
    }

    // MARK: - マウント

    func mount() {
        guard state == .unmounted || isFailed(state) else { return }

        let mountPoint = (Settings.mountPoint as NSString).standardizingPath
        guard !mountPoint.isEmpty else {
            state = .failed(L.mountPointUnset)
            return
        }
        guard let rclone = Self.rclonePath else {
            state = .failed(L.rcloneMissing)
            return
        }

        // 外で誰かが既にマウントしている場合は、そのまま繋がっているものとして扱う
        if Mounts.isMounted(mountPoint) {
            state = .mounted
            return
        }

        let cacheDir = Settings.resolvedCacheDir
        let remote = Settings.remote
        state = .mounting

        queue.async { [weak self] in
            self?.launch(rclone: rclone, remote: remote, mountPoint: mountPoint, cacheDir: cacheDir)
        }
    }

    private func launch(rclone: String, remote: String, mountPoint: String, cacheDir: String) {
        do {
            try FileManager.default.createDirectory(
                atPath: mountPoint, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                atPath: cacheDir, withIntermediateDirectories: true)
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
                finish(.mounted)
                return
            }
            if !task.isRunning { return }  // 後始末は terminationHandler がやる
            Thread.sleep(forTimeInterval: Self.pollInterval)
        }

        task.terminate()
        finish(.failed(L.mountTimedOut))
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
        // rclone は SIGTERM を受けると自分でアンマウントして終わる。
        // こちらが umount を先に叩くと、rclone が書き戻す途中で足元を外すことになる
        process?.terminate()

        if waitUntilUnmounted(mountPoint) {
            finish(.unmounted)
            return
        }

        // 落ちた rclone の残骸や、外で張られたマウントはこちらで外す
        if run("/sbin/umount", [mountPoint]), waitUntilUnmounted(mountPoint) {
            finish(.unmounted)
            return
        }
        if run("/usr/sbin/diskutil", ["unmount", "force", mountPoint]),
            waitUntilUnmounted(mountPoint)
        {
            finish(.unmounted)
            return
        }

        finish(.failed(L.unmountFailed(lastLogLine())))
    }

    private func waitUntilUnmounted(_ mountPoint: String) -> Bool {
        let deadline = Date().addingTimeInterval(Self.unmountTimeout)
        while Date() < deadline {
            if !Mounts.isMounted(mountPoint) { return true }
            Thread.sleep(forTimeInterval: Self.pollInterval)
        }
        return false
    }

    @discardableResult
    private func run(_ path: String, _ arguments: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - 状態

    /// rclone が終わった。こちらが止めたのか、勝手に落ちたのかを分ける
    private func processDidExit() {
        process = nil
        DispatchQueue.main.async {
            switch self.state {
            case .mounting, .mounted:
                // 頼んでいないのに終わった
                self.state = .failed(L.mountFailed(self.lastLogLine()))
            case .unmounting, .unmounted, .failed:
                break
            }
        }
    }

    /// 外から状態が変わることがある。外付けを抜かれた、別のアプリに外された、など
    func refresh() {
        guard state == .mounted || state == .unmounted else { return }
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

        // rclone の行は「2026/08/12 07:25:46 ERROR : …」の形。時刻は見せても仕方がないので落とす
        let line = text.split(separator: "\n").last.map(String.init) ?? ""
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
