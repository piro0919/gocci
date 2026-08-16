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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    private let titleItem = NSMenuItem()
    private let finderItem = NSMenuItem()
    private let toggleItem = NSMenuItem()


    /// 失敗しているときだけ動く点滅
    private var blinkTimer: Timer?
    private var blinkOn = true

    private var settingsWindow = SettingsWindowController()
    /// 画面を作り直すかの判断に使う。文字列は組み立て時に焼き込まれるため
    private var builtLanguage = Language.resolved

    /// 繋がった瞬間を拾うために、前の状態を控えておく
    private var lastState: Provider.State?

    private var provider: Provider { Provider.shared }
    /// 置き場所が変わったことに気づくために、前の値を控えておく
    private var lastVolume = Settings.volume

    private var state: Provider.State { provider.state }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = menu

        NotificationCenter.default.addObserver(
            forName: .providerStateChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }

        NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }

            // 置き場所が変わった。繋ぎ直さないと前のボリュームに置かれたままになる
            if self.lastVolume != Settings.volume {
                self.lastVolume = Settings.volume
                self.provider.stop { self.provider.start() }
            }

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

        refresh()

        handleSignals()

        // 更新の確認は起動時に1回だけ。見つかったときだけ画面が出る
        Updater.shared.checkQuietly()

        // 切り分け用。ドメインを作るところだけをやる
        if CommandLine.arguments.contains("--only-domain") {
            Provider.shared.createDomainOnly { NSApp.terminate(nil) }
            return
        }

        // 今ある繋ぎを並べる
        if CommandLine.arguments.contains("--list-domains") {
            Provider.shared.listDomains { NSApp.terminate(nil) }
            return
        }

        // 繋ぎを外して降りる。ドメインの出し入れはこの束（アプリ本体）からしかできないので、
        // 外から叩ける口をここに開けておく
        if CommandLine.arguments.contains("--file-provider-stop") {
            Provider.shared.stop { NSApp.terminate(nil) }
            return
        }

        if CommandLine.arguments.contains("--settings") { openSettings() }

        // 置き場所を借りないので、待つものが無い。すぐ繋ぐ
        provider.start()
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

    /// 降りるときに外す必要はない。繋ぎは macOS が覚えていて、次に起きたら続きから使える

    // MARK: - メニュー

    private func buildMenu() {
        menu.delegate = self
        menu.removeAllItems()

        titleItem.isEnabled = false
        menu.addItem(titleItem)

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
        refresh()
    }

    // MARK: - 表示の更新

    private func refresh() {
        let state = self.state
        lastState = state

        statusItem.button?.image = Icon.image(for: state)
        statusItem.button?.toolTip = "Gocci — \(label(for: state))"

        // 通知はアドホック署名では出せない（実測）。人の手が要る失敗は、
        // メニューバーの印を点滅させて気付かせる
        updateBlink(for: state)

        // 状態は行の右端に出す。左の丸は色で、遠目にも接続の有無が分かるように
        titleItem.attributedTitle = titleText(for: state)

        finderItem.isEnabled = state == .on

        switch state {
        case .on:
            toggleItem.title = L.disconnect
            toggleItem.isEnabled = true
        case .off, .failed:
            toggleItem.title = L.connect
            toggleItem.isEnabled = true
        case .starting:
            toggleItem.title = L.mounting
            toggleItem.isEnabled = false
        }
    }


    /// 失敗しているときだけ動く点滅。
    ///
    /// 通知はアドホック署名では出せない（`Notifications are not allowed for this application`）。
    /// 人の手が要る失敗に気付ける手立てが、印の色だけでは弱い
    private func updateBlink(for state: Provider.State) {
        let failed: Bool
        if case .failed = state { failed = true } else { failed = false }

        guard failed else {
            blinkTimer?.invalidate()
            blinkTimer = nil
            statusItem.button?.alphaValue = 1
            return
        }
        guard blinkTimer == nil else { return }

        let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.blinkOn.toggle()
            self.statusItem.button?.alphaValue = self.blinkOn ? 1 : 0.35
        }
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    private func titleText(for state: Provider.State) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: "● ",
            attributes: [.foregroundColor: color(for: state), .font: NSFont.menuFont(ofSize: 13)])
        text.append(
            NSAttributedString(
                string: L.driveName,
                attributes: [.font: NSFont.menuFont(ofSize: 13)]))
        text.append(
            NSAttributedString(
                string: " — \(label(for: state))",
                attributes: [
                    .font: NSFont.menuFont(ofSize: 12),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
        return text
    }

    private func label(for state: Provider.State) -> String {
        switch state {
        case .on: return L.mounted
        case .starting: return L.mounting
        case .off: return L.unmounted
        case .failed(let reason): return "\(L.failed): \(reason)"
        }
    }

    private func color(for state: Provider.State) -> NSColor {
        switch state {
        case .on: return .systemGreen
        case .starting: return .systemYellow
        case .off: return .tertiaryLabelColor
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
        if provider.state == .on {
            provider.stop()
        } else {
            provider.start()
        }
    }

    @objc private func openInFinder() {
        provider.entranceURL { url in
            guard let url else { return }
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }
}
