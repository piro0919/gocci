import AppKit

// 設定画面。
//
// 項目が少ないので xib は使わず、素の NSView に積む。
// 言語を変えると文字列が全部変わるので、そのときは画面ごと作り直す。

final class SettingsWindowController: NSWindowController {
    private let mountPointField = NSTextField(string: "")
    private let cacheDirField = NSTextField(string: "")
    private let remoteField = NSTextField(string: "")
    private let launchCheckbox = NSButton(
        checkboxWithTitle: L.launchAtLogin, target: nil, action: nil)
    private let languagePopUp = NSPopUpButton()
    private let messageLabel = NSTextField(labelWithString: "")

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

        for field in [mountPointField, cacheDirField, remoteField] {
            field.target = self
            field.action = #selector(commitFields)
        }
        mountPointField.placeholderString = "/Volumes/…"
        cacheDirField.placeholderString = L.cacheDefaultHint
        remoteField.placeholderString = "gdrive"

        launchCheckbox.target = self
        launchCheckbox.action = #selector(toggleLaunch)

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

        let chooseCacheDir = NSButton(
            title: L.choose, target: self, action: #selector(chooseCacheDir))
        chooseCacheDir.bezelStyle = .rounded

        let about = NSTextField(labelWithString: "Gocci \(version)")
        about.textColor = .secondaryLabelColor
        about.font = .systemFont(ofSize: 11)

        let stack = NSStackView(views: [
            row(L.mountPoint, mountPointField, chooseMountPoint),
            row(L.cacheDir, cacheDirField, chooseCacheDir),
            row(L.remote, remoteField),
            row(L.language, languagePopUp),
            launchCheckbox,
            messageLabel,
            about,
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
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 460, height: content.fittingSize.height))
    }

    private func row(_ title: String, _ controls: NSView...) -> NSView {
        let label = NSTextField(labelWithString: title)
        // 見出しの幅を揃えて、入力欄の左端を一列にする
        label.widthAnchor.constraint(equalToConstant: 120).isActive = true
        label.alignment = .right

        for control in controls where control is NSTextField {
            control.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        }

        let stack = NSStackView(views: [label] + controls)
        stack.orientation = .horizontal
        stack.spacing = 10
        return stack
    }

    func show() {
        // 開くたびに読み直す。設定画面の外（システム設定）で変えられることがあるため
        mountPointField.stringValue = Settings.mountPoint
        cacheDirField.stringValue = Settings.cacheDir
        remoteField.stringValue = Settings.remote
        launchCheckbox.state = Settings.launchesAtLogin ? .on : .off
        report("")

        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    /// 入力欄は Enter か、窓を閉じたときに保存する
    @objc private func commitFields() {
        if mountPointField.stringValue != Settings.mountPoint {
            Settings.mountPoint = mountPointField.stringValue
        }
        if cacheDirField.stringValue != Settings.cacheDir {
            Settings.cacheDir = cacheDirField.stringValue
        }
        if remoteField.stringValue != Settings.remote {
            Settings.remote = remoteField.stringValue
        }
    }

    @objc private func chooseMountPoint() {
        guard let path = pickDirectory() else { return }
        mountPointField.stringValue = path
        commitFields()
    }

    @objc private func chooseCacheDir() {
        guard let path = pickDirectory() else { return }
        cacheDirField.stringValue = path
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
