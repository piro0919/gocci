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

        // 更新の確認は起動時に1回だけ。見つかったときだけ画面が出る
        Updater.shared.checkQuietly()

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

        menu.addItem(.separator())

        finderItem.title = L.openInFinder
        finderItem.action = #selector(openInFinder)
        finderItem.target = self
        menu.addItem(finderItem)

        toggleItem.action = #selector(toggleMount)
        toggleItem.target = self
        menu.addItem(toggleItem)

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

    @objc private func openSettings() {
        settingsWindow.show()
    }
}
