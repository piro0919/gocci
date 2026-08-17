import AppKit

// 設定画面。
//
// 項目が少ないので xib は使わず、素の NSView に積む。
// 言語を変えると文字列が全部変わるので、そのときは画面ごと作り直す。

final class SettingsWindowController: NSWindowController {
    private let remotePopUp = NSPopUpButton()
    private let clientIDField = NSTextField(string: "")
    private let clientSecretField = NSSecureTextField(string: "")
    private let launchCheckbox = NSButton(
        checkboxWithTitle: L.launchAtLogin, target: nil, action: nil)
    private let evictButton = NSButton(title: L.removeAllDownloads, target: nil, action: nil)
    /// 押す前に、何がどれだけ消えるのかを出す
    private let downloadedLabel = NSTextField(labelWithString: "")
    private let volumeLabel = NSTextField(labelWithString: "")
    /// 接続先がまだ無いときは「Google に接続する」、あるときは「保存して認証し直す」
    private let saveButton = NSButton(title: L.reconnect, target: nil, action: nil)
    private let connectHintLabel = NSTextField(labelWithString: L.connectGoogleHint)
    private lazy var connectHintRow: NSView = aligned(connectHintLabel)
    /// 落としてきた分の上限。超えたら古いものから捨てる
    private let limitPopUp = NSPopUpButton()
    private let languagePopUp = NSPopUpButton()
    /// 報告は、押したものの真下に出す。離れた場所に一つだけ置くと、
    /// どの操作の結果なのか読み取れない
    private let messageLabel = NSTextField(labelWithString: "")
    /// 文字が無いときは行ごと畳む。中身だけ隠しても、包んでいる行が場所を取り続ける
    private lazy var messageRow: NSView = aligned(messageLabel)
    private let evictMessageLabel = NSTextField(labelWithString: "")
    private lazy var evictMessageRow: NSView = aligned(evictMessageLabel)
    private let storageMessageLabel = NSTextField(labelWithString: "")
    private lazy var storageMessageRow: NSView = aligned(storageMessageLabel)
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

        remotePopUp.target = self
        remotePopUp.action = #selector(changeRemote)

        clientIDField.placeholderString = "…apps.googleusercontent.com"

        launchCheckbox.target = self
        launchCheckbox.action = #selector(toggleLaunch)



        languagePopUp.target = self
        languagePopUp.action = #selector(changeLanguage)
        for language in Language.allCases {
            languagePopUp.addItem(withTitle: language.label)
        }
        languagePopUp.selectItem(at: Language.allCases.firstIndex(of: Settings.language) ?? 0)

        messageLabel.textColor = .secondaryLabelColor
        messageLabel.font = .systemFont(ofSize: 11)
        // 文字が無いときは畳む。空のまま置くと、その行のぶんだけ間延びする
        messageLabel.isHidden = true
        messageRow.isHidden = true
        evictMessageLabel.font = .systemFont(ofSize: 11)
        evictMessageLabel.textColor = .secondaryLabelColor
        evictMessageLabel.isHidden = true
        evictMessageRow.isHidden = true
        storageMessageLabel.font = .systemFont(ofSize: 11)
        storageMessageLabel.textColor = .secondaryLabelColor
        storageMessageLabel.isHidden = true
        storageMessageRow.isHidden = true

        evictButton.bezelStyle = .rounded
        evictButton.target = self
        evictButton.action = #selector(evictDownloads)

        volumeLabel.font = .systemFont(ofSize: 13)

        downloadedLabel.font = .systemFont(ofSize: 11)
        downloadedLabel.textColor = .secondaryLabelColor

        connectHintLabel.font = .systemFont(ofSize: 11)
        connectHintLabel.textColor = .secondaryLabelColor
        connectHintLabel.isHidden = true
        connectHintRow.isHidden = true

        limitPopUp.target = self
        limitPopUp.action = #selector(changeLimit)
        for choice in Settings.downloadLimitChoices {
            limitPopUp.addItem(withTitle: Self.limitTitle(choice))
        }

        let updateButton = NSButton(
            title: L.checkForUpdates, target: self, action: #selector(checkForUpdates))
        updateButton.bezelStyle = .rounded

        let buttons = aligned(updateButton)

        let about = NSTextField(labelWithString: "Gocci \(version)")
        about.textColor = .secondaryLabelColor
        about.font = .systemFont(ofSize: 11)

        let remotes = RcloneConfig.driveRemotes()
        // 接続先が1つなら、行そのものを置かない。隠すだけだと余白が残る
        if remotes.count == 1, remotes[0] != Settings.remote { Settings.remote = remotes[0] }

        // 置き場所も、手元にどれだけ残すかも、macOS の受け持ちになった。
        // ここに出しても効かないので、行ごと置かない
        var rows: [NSView] = []
        if remotes.count > 1 { rows.append(row(L.remote, remotePopUp)) }

        let chooseVolume = NSButton(title: L.choose, target: self, action: #selector(chooseVolume))
        chooseVolume.bezelStyle = .rounded
        chooseVolume.isEnabled = Settings.canUseExternalVolume

        let stack = NSStackView(views: rows + [
            row(L.storage, volumeLabel, chooseVolume),
            storageMessageRow,
            divider(),
            row(L.clientID, clientIDField),
            row(L.clientSecret, clientSecretField),
            links(),
            connectHintRow,
            divider(),
            row(L.downloads, downloadedLabel, evictButton),
            row(L.downloadLimit, limitPopUp),
            evictMessageRow,
            divider(),
            row(L.language, languagePopUp),
            checkboxRow(launchCheckbox),
            messageRow,
            buttons,
            aligned(about),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        // 畳んだ行の場所を残さない。残すと、繋ぎ方を変えたときに空白だけが居座る
        stack.detachesHiddenViews = true
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
        let available = RcloneConfig.driveRemotes()
        remotePopUp.removeAllItems()
        remotePopUp.addItems(withTitles: available.isEmpty ? [Settings.remote] : available)
        remotePopUp.selectItem(withTitle: Settings.remote)
        if remotePopUp.indexOfSelectedItem < 0 { remotePopUp.selectItem(at: 0) }


        let credentials = RcloneConfig.values(of: Settings.remote)
        clientIDField.stringValue = credentials["client_id"] ?? ""
        clientSecretField.stringValue = credentials["client_secret"] ?? ""
        launchCheckbox.state = Settings.launchesAtLogin ? .on : .off
        showConnectState()
        showVolume()
        showLimit()
        showDownloaded()
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









    /// client_id を取りに行くための入口と、書き込みの実行
    private func links() -> NSView {
        let howTo = NSButton(
            title: L.howToGetCredentials, target: self, action: #selector(openHowTo))
        let console = NSButton(
            title: L.openCloudConsole, target: self, action: #selector(openConsole))
        saveButton.target = self
        saveButton.action = #selector(saveCredentials)
        for button in [howTo, console] { button.bezelStyle = .accessoryBarAction }
        saveButton.bezelStyle = .rounded

        let stack = NSStackView(views: [howTo, console, saveButton])
        stack.orientation = .horizontal
        stack.spacing = 10
        return aligned(stack)
    }

    /// 見出しのぶんだけ空けて、入力欄の列に揃える
    private func aligned(_ views: NSView...) -> NSView {
        let spacer = NSView()
        spacer.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true

        let stack = NSStackView(views: [spacer] + views)
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

    /// 接続先があるか。無ければ、まず作るところから
    private var hasRemote: Bool { !RcloneConfig.driveRemotes().isEmpty }

    private func showConnectState() {
        let connected = hasRemote
        saveButton.title = connected ? L.reconnect : L.connectGoogle
        connectHintLabel.isHidden = connected
        connectHintRow.isHidden = connected
    }

    /// 書き込んでから認証をやり直す。client_id を変えると今の認証は無効になるため、
    /// 書き込みだけでは繋がらなくなる。
    ///
    /// 接続先そのものが無いときは、書き込む先も無いので、作るところから始める
    @objc private func saveCredentials() {
        guard hasRemote else { return connectGoogle() }

        if let failure = RcloneConfig.setCredentials(
            remote: Settings.remote, clientID: clientIDField.stringValue,
            clientSecret: clientSecretField.stringValue)
        {
            report(failure, failed: true)
            return
        }

        report(L.reconnecting2)

        RcloneConfig.reconnect(remote: Settings.remote) { [weak self] failure in
            guard let self else { return }
            if let failure {
                self.report(failure, failed: true)
                return
            }
            self.report(L.reconnected)

            // 認証が変わったので繋ぎ直す。繋がっていないときは何もしない
            if Provider.shared.state == .on {
                Provider.shared.stop { Provider.shared.start() }
            }
        }
    }

    /// 接続先を作る。端末で `rclone config` を叩かなくて済むようにするのがここ
    private func connectGoogle() {
        saveButton.isEnabled = false
        report(L.connectingGoogle)

        RcloneConfig.create(
            remote: Settings.remote, clientID: clientIDField.stringValue,
            clientSecret: clientSecretField.stringValue
        ) { [weak self] failure in
            guard let self else { return }
            self.saveButton.isEnabled = true

            if let failure {
                self.report(failure, failed: true)
                return
            }
            self.report(L.connectedGoogle)
            self.showConnectState()
            Provider.shared.start()
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

    /// 置き場所を選ぶ。ボリュームそのものを指すので、フォルダの中までは選ばせない
    @objc private func chooseVolume() {
        guard Settings.canUseExternalVolume else {
            return reportStorage(L.storageNeedsSequoia, failed: true)
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        panel.prompt = L.choose

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // 選ばれたのがボリュームの根でなくても、そのボリュームに置かれる
        Settings.volume = url.path
        showVolume()
        reportStorage(L.storageChanged)
    }

    private func showVolume() {
        let volume = Settings.volume
        volumeLabel.stringValue = volume.isEmpty ? L.storageBuiltIn : volume
    }

    /// 手元に降りてきた実体を捨てる。Drive のファイルはそのまま残る
    @objc private func evictDownloads() {
        evictButton.isEnabled = false
        reportEviction("")
        Provider.shared.evictDownloads { [weak self] failure in
            guard let self else { return }
            self.evictButton.isEnabled = true
            self.reportEviction(
                failure.map { L.evictFailed($0) } ?? L.evictedDownloads, failed: failure != nil)
            self.showDownloaded()
        }
    }

    /// 手元にどれだけ降りているかを数えて出す。macOS が持っている台帳を読むだけなので
    /// Drive には行かないが、件数が多いと少し待つ
    private func showDownloaded() {
        downloadedLabel.stringValue = L.downloadedCounting
        Provider.shared.downloadedSize { [weak self] bytes, count in
            guard let self else { return }
            self.evictButton.isEnabled = count > 0
            guard count > 0 else {
                self.downloadedLabel.stringValue = L.downloadedNothing
                return
            }
            // 既定だと 0 が「Zero KB」になる。数字で出したい
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            formatter.allowsNonnumericFormatting = false
            let size = formatter.string(fromByteCount: bytes)
            self.downloadedLabel.stringValue = L.downloaded(size, count: count)
        }
    }

    private static func limitTitle(_ bytes: Int64) -> String {
        guard bytes > 0 else { return L.downloadLimitNone }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func showLimit() {
        let index = Settings.downloadLimitChoices.firstIndex(of: Settings.downloadLimit) ?? 0
        limitPopUp.selectItem(at: index)
    }

    /// 上限を変える。下げたときは、その場で収まるところまで捨てる
    @objc private func changeLimit() {
        let index = limitPopUp.indexOfSelectedItem
        guard Settings.downloadLimitChoices.indices.contains(index) else { return }
        Settings.downloadLimit = Settings.downloadLimitChoices[index]
        Provider.shared.trimNow()
    }

    @objc private func checkForUpdates() {
        Updater.shared.checkNow()
    }

    @objc private func changeLanguage() {
        let index = languagePopUp.indexOfSelectedItem
        guard Language.allCases.indices.contains(index) else { return }
        Settings.language = Language.allCases[index]
    }

    /// 置き場所を変えたときの知らせ。その行の真下に出す
    private func reportStorage(_ text: String, failed: Bool = false) {
        storageMessageLabel.textColor = failed ? .systemRed : .secondaryLabelColor
        storageMessageLabel.stringValue = text
        storageMessageLabel.isHidden = text.isEmpty
        storageMessageRow.isHidden = text.isEmpty
    }

    /// 「ダウンロードを空にする」の結果。そのボタンの真下に出す
    private func reportEviction(_ text: String, failed: Bool = false) {
        evictMessageLabel.textColor = failed ? .systemRed : .secondaryLabelColor
        evictMessageLabel.stringValue = text
        evictMessageLabel.isHidden = text.isEmpty
        evictMessageRow.isHidden = text.isEmpty
    }

    private func report(_ text: String, failed: Bool = false) {
        messageLabel.textColor = failed ? .systemRed : .secondaryLabelColor
        messageLabel.stringValue = text
        messageLabel.isHidden = text.isEmpty
        messageRow.isHidden = text.isEmpty
    }
}

extension SettingsWindowController: NSWindowDelegate {
    /// 閉じるときに書きかけを拾う。Enter を押さずに閉じる人のほうが多い
    func windowWillClose(_ notification: Notification) {
        commitFields()
    }
}
