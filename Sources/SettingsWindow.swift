import AppKit

// 設定画面。
//
// 項目が少ないので xib は使わず、素の NSView に積む。
// 言語を変えると文字列が全部変わるので、そのときは画面ごと作り直す。

final class SettingsWindowController: NSWindowController {
    private let mountPointField = NSTextField(string: "")
    private let remotePopUp = NSPopUpButton()
    private let periodPopUp = NSPopUpButton()
    private let limitPopUp = NSPopUpButton()
    private let clientIDField = NSTextField(string: "")
    private let clientSecretField = NSSecureTextField(string: "")
    private let launchCheckbox = NSButton(
        checkboxWithTitle: L.launchAtLogin, target: nil, action: nil)
    private let fetchWholeCheckbox = NSButton(
        checkboxWithTitle: L.fetchWhole, target: nil, action: nil)
    private let finderSettingsCheckbox = NSButton(
        checkboxWithTitle: L.keepFinderSettings, target: nil, action: nil)
    private let languagePopUp = NSPopUpButton()
    private let messageLabel = NSTextField(labelWithString: "")
    /// 一度でも開いたか。入力欄に今の値が入っているかの判断に使う
    private var hasShown = false

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = L.settingsTitle
        window.isReleasedWhenClosed = false
        self.init(window: window)
        build()
    }

    private func build() {
        guard let window else { return }

        let version =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"

        window.delegate = self

        for field in [mountPointField] {
            field.target = self
            field.action = #selector(commitFields)
        }
        mountPointField.placeholderString = "/Volumes/…"
        remotePopUp.target = self
        remotePopUp.action = #selector(changeRemote)

        periodPopUp.target = self
        periodPopUp.action = #selector(changePeriod)
        for period in CachePeriod.allCases { periodPopUp.addItem(withTitle: period.label) }

        limitPopUp.target = self
        limitPopUp.action = #selector(changeLimit)
        for limit in CacheLimit.allCases { limitPopUp.addItem(withTitle: limit.label) }
        clientIDField.placeholderString = "…apps.googleusercontent.com"

        launchCheckbox.target = self
        launchCheckbox.action = #selector(toggleLaunch)

        fetchWholeCheckbox.target = self
        fetchWholeCheckbox.action = #selector(toggleFetchWhole)

        finderSettingsCheckbox.target = self
        finderSettingsCheckbox.action = #selector(toggleFinderSettings)

        languagePopUp.target = self
        languagePopUp.action = #selector(changeLanguage)
        for language in Language.allCases {
            languagePopUp.addItem(withTitle: language.label)
        }
        languagePopUp.selectItem(at: Language.allCases.firstIndex(of: Settings.language) ?? 0)

        messageLabel.textColor = .systemRed
        messageLabel.font = .systemFont(ofSize: 11)
        // 文字が無いときは畳む。空のまま置くと、その行のぶんだけ間延びする
        messageLabel.isHidden = true

        let chooseMountPoint = NSButton(
            title: L.choose, target: self, action: #selector(chooseMountPoint))
        chooseMountPoint.bezelStyle = .rounded

        let updateButton = NSButton(
            title: L.checkForUpdates, target: self, action: #selector(checkForUpdates))
        updateButton.bezelStyle = .rounded

        // 更新でアプリを入れ替えると拡張も入れ替わり、Finder を再起動するまでバッジが出ない。
        // 戻す手立ては要るが、普段の操作に混ぜる話ではないのでここに置く
        let restartFinderButton = NSButton(
            title: L.restartFinder, target: self, action: #selector(restartFinder))
        restartFinderButton.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [updateButton, restartFinderButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        let buttons = aligned(buttonRow)

        let about = NSTextField(labelWithString: "Gocci \(version)")
        about.textColor = .secondaryLabelColor
        about.font = .systemFont(ofSize: 11)

        let remotes = RcloneConfig.driveRemotes()
        // 接続先が1つなら、行そのものを置かない。隠すだけだと余白が残る
        if remotes.count == 1, remotes[0] != Settings.remote { Settings.remote = remotes[0] }

        var rows: [NSView] = [row(L.mountPoint, mountPointField, chooseMountPoint)]
        if remotes.count > 1 { rows.append(row(L.remote, remotePopUp)) }

        let stack = NSStackView(views: rows + [
            divider(),
            row(L.clientID, clientIDField),
            row(L.clientSecret, clientSecretField),
            links(),
            divider(),
            row(L.cacheMaxAge, periodPopUp),
            row(L.cacheMaxSize, limitPopUp),
            checkboxRow(fetchWholeCheckbox),
            checkboxRow(finderSettingsCheckbox),
            hint(L.keepFinderSettingsHint),
            divider(),
            row(L.language, languagePopUp),
            checkboxRow(launchCheckbox),
            messageLabel,
            buttons,
            hint(L.restartFinderHint),
            aligned(about),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        // 余白は枠との距離として直接指定する。積み上げ側の余白指定は、
        // 窓の幅を中身から決めるときに右側が勘定に入らない
        let margin: CGFloat = 24
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: margin),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -margin),
        ])
        // 区切り線は、積み上げた中身と同じ幅にする。固定値だと中身とずれる
        for line in dividers {
            line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        window.contentView = content
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 460, height: content.fittingSize.height))
    }

    /// 見出しの幅。入力欄の左端を一列に揃えるための基準。
    /// 一番長い見出し（クライアントシークレット）が収まる幅にする
    private static let labelWidth: CGFloat = 170

    private func row(_ title: String, _ controls: NSView...) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true
        label.alignment = .right

        for control in controls where control is NSTextField {
            control.widthAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
        }

        let stack = NSStackView(views: [label] + controls)
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 10
        return stack
    }

    /// チェックの行
    private func checkboxRow(_ checkbox: NSButton) -> NSView { aligned(checkbox) }

    func show() {
        // 開くたびに読み直す。設定画面の外（システム設定）で変えられることがあるため
        mountPointField.stringValue = Settings.mountPoint
        let available = RcloneConfig.driveRemotes()
        remotePopUp.removeAllItems()
        remotePopUp.addItems(withTitles: available.isEmpty ? [Settings.remote] : available)
        remotePopUp.selectItem(withTitle: Settings.remote)
        if remotePopUp.indexOfSelectedItem < 0 { remotePopUp.selectItem(at: 0) }

        periodPopUp.selectItem(at: CachePeriod.allCases.firstIndex(of: Settings.cachePeriod) ?? 0)
        limitPopUp.selectItem(at: CacheLimit.allCases.firstIndex(of: Settings.cacheLimit) ?? 0)

        let credentials = RcloneConfig.values(of: Settings.remote)
        clientIDField.stringValue = credentials["client_id"] ?? ""
        clientSecretField.stringValue = credentials["client_secret"] ?? ""
        launchCheckbox.state = Settings.launchesAtLogin ? .on : .off
        fetchWholeCheckbox.state = Settings.fetchesWholeFile ? .on : .off
        finderSettingsCheckbox.state = Settings.keepsFinderSettings ? .on : .off
        report("")
        hasShown = true

        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        // 開いた瞬間に文字が選ばれていると、うっかり上書きしてしまう
        window?.makeFirstResponder(nil)
    }

    /// 入力欄は Enter か、窓を閉じたときに保存する。
    ///
    /// 一度も開いていないときは書かない。窓は起動時に作るだけ作ってあるので、
    /// この番をしないと、終了時の閉じる通知で空欄が設定を上書きする
    @objc private func commitFields() {
        guard hasShown else { return }

        if mountPointField.stringValue != Settings.mountPoint {
            Settings.mountPoint = mountPointField.stringValue
        }

    }

    @objc private func chooseMountPoint() {
        guard let path = pickDirectory() else { return }
        mountPointField.stringValue = path
        commitFields()
    }

    /// マウント先はまだ無い場所を指すこともあるので、新しいフォルダを作れるようにしておく
    private func pickDirectory() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.path
    }

    @objc private func toggleLaunch() {
        let wanted = launchCheckbox.state == .on
        if let failure = Settings.setLaunchesAtLogin(wanted) {
            report(L.launchToggleFailed(failure))
            // OS 側が変わっていないので、見た目を実際の状態へ戻す
            launchCheckbox.state = Settings.launchesAtLogin ? .on : .off
            return
        }
        report("")
    }

    @objc private func changeRemote() {
        guard let title = remotePopUp.titleOfSelectedItem else { return }
        Settings.remote = title
    }

    @objc private func changePeriod() {
        let index = periodPopUp.indexOfSelectedItem
        guard CachePeriod.allCases.indices.contains(index) else { return }
        Settings.cachePeriod = CachePeriod.allCases[index]
    }

    @objc private func changeLimit() {
        let index = limitPopUp.indexOfSelectedItem
        guard CacheLimit.allCases.indices.contains(index) else { return }
        Settings.cacheLimit = CacheLimit.allCases[index]
    }

    @objc private func toggleFinderSettings() {
        Settings.keepsFinderSettings = finderSettingsCheckbox.state == .on
    }

    @objc private func toggleFetchWhole() {
        Settings.fetchesWholeFile = fetchWholeCheckbox.state == .on
    }

    /// client_id を取りに行くための入口と、書き込みの実行
    private func links() -> NSView {
        let howTo = NSButton(
            title: L.howToGetCredentials, target: self, action: #selector(openHowTo))
        let console = NSButton(
            title: L.openCloudConsole, target: self, action: #selector(openConsole))
        let save = NSButton(title: L.reconnect, target: self, action: #selector(saveCredentials))
        for button in [howTo, console] { button.bezelStyle = .accessoryBarAction }
        save.bezelStyle = .rounded

        let stack = NSStackView(views: [howTo, console, save])
        stack.orientation = .horizontal
        stack.spacing = 10
        return aligned(stack)
    }

    /// 見出しのぶんだけ空けて、入力欄の列に揃える
    private func aligned(_ view: NSView) -> NSView {
        let spacer = NSView()
        spacer.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true

        let stack = NSStackView(views: [spacer, view])
        stack.orientation = .horizontal
        stack.spacing = 10
        return stack
    }

    @objc private func openHowTo() {
        NSWorkspace.shared.open(URL(string: "https://rclone.org/drive/#making-your-own-client-id")!)
    }

    @objc private func openConsole() {
        NSWorkspace.shared.open(URL(string: "https://console.cloud.google.com/apis/credentials")!)
    }

    /// 書き込んでから認証をやり直す。client_id を変えると今の認証は無効になるため、
    /// 書き込みだけでは繋がらなくなる
    @objc private func saveCredentials() {
        if let failure = RcloneConfig.setCredentials(
            remote: Settings.remote, clientID: clientIDField.stringValue,
            clientSecret: clientSecretField.stringValue)
        {
            report(failure)
            return
        }

        report(L.reconnecting2)
        messageLabel.textColor = .secondaryLabelColor

        RcloneConfig.reconnect(remote: Settings.remote) { [weak self] failure in
            guard let self else { return }
            if let failure {
                self.messageLabel.textColor = .systemRed
                self.report(failure)
                return
            }
            self.report(L.reconnected)

            // 認証が変わったので繋ぎ直す。繋がっていないときは何もしない
            if MountController.shared.state == .mounted {
                MountController.shared.remount()
            }
        }
    }

    /// 区切り線。性質の違うものを分ける。幅は中身に合わせるので、組み上げた後に決める
    private var dividers: [NSView] = []

    private func divider() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        dividers.append(line)
        return line
    }

    /// 添え書き。項目の下に一段小さく置く
    private func hint(_ text: String) -> NSView {
        guard !text.isEmpty else { return NSView() }

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor

        return aligned(label)
    }

    /// Finder を再起動する。開いているウィンドウが閉じるので、押した本人が選ぶ形にしてある
    @objc private func restartFinder() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["Finder"]
        try? task.run()
    }

    @objc private func checkForUpdates() {
        Updater.shared.checkNow()
    }

    @objc private func changeLanguage() {
        let index = languagePopUp.indexOfSelectedItem
        guard Language.allCases.indices.contains(index) else { return }
        Settings.language = Language.allCases[index]
    }

    private func report(_ text: String) {
        messageLabel.stringValue = text
        messageLabel.isHidden = text.isEmpty
    }
}

extension SettingsWindowController: NSWindowDelegate {
    /// 閉じるときに書きかけを拾う。Enter を押さずに閉じる人のほうが多い
    func windowWillClose(_ notification: Notification) {
        commitFields()
    }
}
