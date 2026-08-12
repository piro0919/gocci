import AppKit

// メニューバーの常駐。
//
// Konechi と同じく SwiftUI の MenuBarExtra ではなく AppKit で組む。メニューを開いた時点で
// 実際にマウントされているかを見に行きたいので、開閉が取れる必要がある。

@main
enum Gocci {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Dock とアプリ切替に出さず、メニューバーだけに常駐する
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    private let titleItem = NSMenuItem()
    private let pathItem = NSMenuItem()
    private let finderItem = NSMenuItem()
    private let toggleItem = NSMenuItem()

    /// 取得中の見出しと行。開いている最中に差し替えると描き直されないので、
    /// あらかじめ置いておき、文字だけ書き換える
    private let fetchingHeader = NSMenuItem()
    private let fetchingRows = (0..<5).map { _ in NSMenuItem() }
    private let fetchingMore = NSMenuItem()
    /// キャッシュの使用量。今どれだけ手元に置いているかが、どこにも出ていなかった
    private let cacheItem = NSMenuItem()
    private let fetchingSeparator = NSMenuItem.separator()
    /// 開いた時点で見せている道。文字を書き換えるときの照合に使う
    private var shownPaths: [String] = []
    /// メニューを開いている間だけ動く時計
    private var openTimer: Timer?
    private var openSource: DispatchSourceTimer?

    private var settingsWindow = SettingsWindowController()
    /// 画面を作り直すかの判断に使う。文字列は組み立て時に焼き込まれるため
    private var builtLanguage = Language.resolved
    private var pollTimer: Timer?

    private var mount: MountController { MountController.shared }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = menu

        NotificationCenter.default.addObserver(
            forName: .mountStateChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }

        NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.builtLanguage != Language.resolved {
                self.builtLanguage = Language.resolved
                let wasVisible = self.settingsWindow.window?.isVisible ?? false
                self.settingsWindow.close()
                self.settingsWindow = SettingsWindowController()
                if wasVisible { self.settingsWindow.show() }
            }
            self.buildMenu()
            self.refresh()
        }

        // 外付けを抜かれた、別のアプリに外された、といった変化はこちらに通知が来ない
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.mount.refresh()
        }

        refresh()

        handleSignals()

        // 更新の確認は起動時に1回だけ。見つかったときだけ画面が出る
        Updater.shared.checkQuietly()

        // Finder のバッジに使う一覧。拡張は自分では調べられないので、こちらが書く
        BadgeIndex.start()

        // Finder の右クリックから「手元から削除」を頼まれる。拡張は自分では消せない
        Evict.start()

        // 中断で途中のまま残ったファイルを、最後まで取りにいく
        Finisher.start()

        // 外付けが挿さったら繋ぐ。5秒の見回りでも拾えるが、待たされた感じになる。
        //
        // 通知が来た直後は、ボリュームがまだ落ち着いていない。その隙にマウントを始めると
        // 失敗しやすく、失敗の後始末で外付けごと外れることがある。少し置いてから動く
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self?.mount.mountWhenReady()
            }
        }

        // マウント先が決まっていなければ、まず設定を出す。初回はここに来る
        if Settings.mountPoint.isEmpty || CommandLine.arguments.contains("--settings") {
            openSettings()
            return
        }

        // 普段はメニューを触らずに繋がる。外付けがまだなら、繋がるまで待つ
        mount.mountWhenReady()
    }

    /// 合図で止められたときも片付ける。
    ///
    /// SIGTERM は `pkill` や一部の終了手続きで飛んでくる。既定では即座に落ちるので、
    /// applicationWillTerminate が走らず、マウントと rclone が残る。
    /// 実機の試験で残ることを確かめた
    private func handleSignals() {
        for signalNumber in [SIGTERM, SIGINT] {
            // 既定の動作を止めないと、受け口が呼ばれる前に落ちる
            signal(signalNumber, SIG_IGN)

            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    private var signalSources: [DispatchSourceSignal] = []

    /// 繋がったまま終了すると、次に Finder から触ったときに固まる。降りる前に外す
    func applicationWillTerminate(_ notification: Notification) {
        guard mount.state == .mounted else { return }
        mount.unmount()

        // 終了処理の中なので実行ループは回らない。外れるまでここで待つ
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, Mounts.isMounted(Settings.mountPoint) {
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    // MARK: - メニュー

    private func buildMenu() {
        menu.delegate = self
        menu.removeAllItems()

        titleItem.isEnabled = false
        menu.addItem(titleItem)

        pathItem.isEnabled = false
        menu.addItem(pathItem)

        fetchingHeader.isEnabled = false
        menu.addItem(fetchingHeader)

        for row in fetchingRows {
            row.action = #selector(revealFile(_:))
            row.target = self
            menu.addItem(row)
        }

        fetchingMore.isEnabled = false
        menu.addItem(fetchingMore)

        cacheItem.isEnabled = false
        menu.addItem(cacheItem)
        menu.addItem(fetchingSeparator)

        menu.addItem(.separator())

        finderItem.title = L.openInFinder
        finderItem.action = #selector(openInFinder)
        finderItem.target = self
        menu.addItem(finderItem)

        toggleItem.action = #selector(toggleMount)
        toggleItem.target = self
        menu.addItem(toggleItem)

        // 更新でアプリを入れ替えると拡張も入れ替わり、Finder を再起動するまで
        // バッジが出なくなる。黙って消えるので、戻す手立てを見える場所に置く
        let restartFinder = NSMenuItem(
            title: L.restartFinder, action: #selector(restartFinder), keyEquivalent: "")
        restartFinder.target = self
        menu.addItem(restartFinder)

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: L.settings, action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(
            withTitle: L.quit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    func menuWillOpen(_ menu: NSMenu) {
        mount.refresh()
        refresh()
        updateProgressSection(reset: true)

        // 開いている間は通常の実行ループが止まるので、値が固まって見える。
        // 別に時計を回して、取得中の行だけ動かし続ける
        openTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.updateProgressSection(reset: false)
        }
        RunLoop.current.add(timer, forMode: .common)
        openTimer = timer

        // 経路2。別のスレッドから主スレッドへ投げる。どちらが届くかを測る
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        source.schedule(deadline: .now() + 2, repeating: 2)
        source.setEventHandler {
            DispatchQueue.main.async { [weak self] in
                self?.updateProgressSection(reset: false)
            }
        }
        source.resume()
        openSource = source
    }

    func menuDidClose(_ menu: NSMenu) {
        openTimer?.invalidate()
        openTimer = nil
        openSource?.cancel()
        openSource = nil
    }

    // MARK: - 表示の更新

    private func refresh() {
        let state = mount.state

        statusItem.button?.image = Icon.image(for: state)
        statusItem.button?.toolTip = "Gocci — \(label(for: state))"

        // 状態は行の右端に出す。左の丸は色で、遠目にも接続の有無が分かるように
        titleItem.attributedTitle = titleText(for: state)

        let path = Settings.mountPoint
        pathItem.attributedTitle = secondary(path.isEmpty ? L.notSet : path)
        pathItem.toolTip = path.isEmpty ? nil : path

        finderItem.isEnabled = state == .mounted

        switch state {
        case .mounted:
            toggleItem.title = L.disconnect
            toggleItem.isEnabled = true
        case .unmounted, .waitingForDisk, .reconnecting, .failed:
            // 待っている間も押せる。外付けを繋いだ直後に、5秒の見回りを待たず繋げるように
            toggleItem.title = L.connect
            toggleItem.isEnabled = !Settings.mountPoint.isEmpty
        case .mounting, .unmounting:
            toggleItem.title = state == .mounting ? L.mounting : L.unmounting
            toggleItem.isEnabled = false
        }
    }

    /// 取得中のものをメニューに出す。
    ///
    /// 裏で1本ずつ落としているので、Finder のバッジだけだと動いているのか止まっているのかが
    /// 分からない。何が今どこまで来ているかを、開いたときに見えるようにする。
    ///
    /// 見せる顔ぶれは開いた時点で決める。開いている最中に行が増えたり減ったりすると、
    /// 押そうとしたものが動く
    private func updateProgressSection(reset: Bool) {
        let partials = BadgeIndex.partials()
        let byPath = Dictionary(partials.map { ($0.path, $0) }) { left, _ in left }

        if reset {
            shownPaths = partials.prefix(fetchingRows.count).map(\.path)
        }

        cacheItem.isHidden = mount.state != .mounted
        cacheItem.attributedTitle = secondary(
            L.cacheUsage(formatted(BadgeIndex.cacheBytes()), limitLabel()))

        let hidden = shownPaths.isEmpty || mount.state != .mounted
        fetchingHeader.isHidden = hidden
        fetchingMore.isHidden = hidden || partials.count <= fetchingRows.count
        fetchingSeparator.isHidden = hidden

        fetchingHeader.attributedTitle = secondary(L.fetching(partials.count))
        fetchingMore.attributedTitle = secondary(L.andMore(partials.count - fetchingRows.count))

        for (index, row) in fetchingRows.enumerated() {
            guard index < shownPaths.count, !hidden else {
                row.isHidden = true
                continue
            }
            let path = shownPaths[index]
            row.isHidden = false
            row.representedObject = path
            let current = byPath[path]
            let name = (path as NSString).lastPathComponent
            let amount = current.map {
                " \($0.held / 1_000_000) / \($0.size / 1_000_000) MB"
            } ?? ""
            row.attributedTitle = secondary("\(current?.percent ?? 100)%\(amount)  \(name)")
        }
    }

    @objc private func revealFile(_ sender: NSMenuItem) {
        guard let relative = sender.representedObject as? String else { return }
        let path = "\(Settings.mountPoint)/\(relative)"
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    /// 上限の書き方を、使用量と揃える。設定には 50G のように入っている
    private func limitLabel() -> String {
        let limit = Settings.cacheMaxSize
        guard !limit.isEmpty else { return "" }
        if limit.hasSuffix("G") || limit.hasSuffix("M") || limit.hasSuffix("K") {
            return limit + "B"
        }
        return limit
    }

    /// 量の書き方。GB と MB だけで足りる
    private func formatted(_ bytes: Int64) -> String {
        let gigabytes = Double(bytes) / 1_000_000_000
        if gigabytes >= 1 { return String(format: "%.1fGB", gigabytes) }
        return "\(bytes / 1_000_000)MB"
    }

    private func titleText(for state: MountState) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: "● ",
            attributes: [.foregroundColor: color(for: state), .font: NSFont.menuFont(ofSize: 13)])
        text.append(
            NSAttributedString(
                string: L.driveName,
                attributes: [.font: NSFont.menuFont(ofSize: 13)]))
        text.append(
            NSAttributedString(
                string: "  \(label(for: state))",
                attributes: [
                    .font: NSFont.menuFont(ofSize: 12),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
        return text
    }

    private func label(for state: MountState) -> String {
        switch state {
        case .mounted: return L.mounted
        case .mounting: return L.mounting
        case .unmounting: return L.unmounting
        case .unmounted: return L.unmounted
        case .waitingForDisk: return L.waitingForDisk
        case .reconnecting: return L.reconnecting
        case .failed(let reason): return "\(L.failed): \(reason)"
        }
    }

    private func color(for state: MountState) -> NSColor {
        switch state {
        case .mounted: return .systemGreen
        case .mounting, .unmounting, .waitingForDisk, .reconnecting: return .systemYellow
        case .unmounted: return .tertiaryLabelColor
        case .failed: return .systemRed
        }
    }

    /// 場所の行は一段小さい文字で出す。操作の行と区別が付き、幅も詰まる
    private func secondary(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: "  \(text)",
            attributes: [
                .font: NSFont.menuFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
    }

    // MARK: - 操作

    @objc private func toggleMount() {
        mount.toggleByUser()
    }

    @objc private func openInFinder() {
        guard !Settings.mountPoint.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: Settings.mountPoint))
    }

    /// Finder を再起動する。開いているウィンドウが閉じるので、押した本人が選ぶ形にしてある
    @objc private func restartFinder() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["Finder"]
        try? task.run()
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }
}
