import Foundation
import OSLog

// フォルダを開いてもファイルが落ちてこないようにする。
//
// Finder はアイコンプレビューのために中身を読む。読まれた分は rclone が取りに行くので、
// フォルダを開いただけで動画が丸ごと落ちてくる。プレビューを切ればこれが止まる（実測）。
//
// 切った状態は `.DS_Store` に入る。Finder に頼む道は無い——AppleScript の辞書では、
// 表示オプションは Finder の「ウィンドウ」にしか付いておらず、フォルダには付いていない
// （Finder.sdef 332-333 行）。フォルダごとにウィンドウを開かせるのは現実的ではないので、
// こちらで書く。
//
// 触るのは、まだ表示設定を持たないフォルダだけにする。利用者が自分で決めた設定は残す。

private let viewLogger = Logger(subsystem: "io.kkweb.gocci", category: "finderview")

enum FinderView {
    /// 表示設定を持つ記録。これが既にあるフォルダには触らない
    private static let viewRecords = ["icvp", "lsvp"]

    private static let queue = DispatchQueue(label: "io.kkweb.gocci.finderview")
    private static var sweptAt = Date.distantPast
    /// 全部を歩くので、マウントし直すたびに走らせない。設定を入れ直したときだけ間を空けずに走る。
    /// 歩き切るのに何十分もかかる（実測: 大きめの Drive で30分以上）ので、間隔は広く取る
    private static let interval: TimeInterval = 6 * 60 * 60

    /// 設定が入っていれば、マウント先の下を歩く。走るのは一度に一つだけ
    static func sweep(_ mountPoint: String, force: Bool = false) {
        guard Settings.keepsFinderSettings, !mountPoint.isEmpty else { return }

        queue.async {
            guard force || Date().timeIntervalSince(sweptAt) > interval else { return }
            guard FileManager.default.fileExists(atPath: mountPoint) else { return }
            sweptAt = Date()
            hideIconPreviews(under: mountPoint)
        }
    }

    /// 拡張が「開いたフォルダ」を置く場所。Evict と同じ経路を逆向きに使う
    private static var browsingURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/io.kkweb.gocci.FinderSync/Data/Library/Application Support",
                isDirectory: true)
            .appendingPathComponent("browsing.txt")
    }

    private static var lastBrowsed = ""
    private static var watchTimer: DispatchSourceTimer?

    /// 拡張からの報せを拾い続ける。主スレッドの時計はメニューを開いている間止まるので使わない
    static func startWatching() {
        watchTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { coverBrowsedDirectory() }
        timer.resume()
        watchTimer = timer
    }

    /// 見ているフォルダの一段先を覆う。歩き直しは何十分もかかるので、その隙間を埋める役
    static func coverBrowsedDirectory() {
        guard Settings.keepsFinderSettings,
            let data = try? Data(contentsOf: browsingURL),
            case let path = String(decoding: data, as: UTF8.self), !path.isEmpty,
            path != lastBrowsed
        else { return }

        lastBrowsed = path
        let mountPoint = (Settings.mountPoint as NSString).standardizingPath
        guard !mountPoint.isEmpty, path == mountPoint || path.hasPrefix(mountPoint + "/") else {
            return
        }

        // 呼ばれるのは queue の上から。歩き回っている最中は、それが終わるまで順番を待つ。
        // 同じ `.DS_Store` を二人で書くと、どちらかの書き込みが消える
        let children = subdirectories(of: path)
        guard !children.isEmpty, apply(to: children, in: path) else { return }
        viewLogger.info("開いたフォルダの一段先を覆った: \(path, privacy: .public)")
    }

    /// マウント先の下を歩いて、プレビューを切って回る。
    ///
    /// 書き込みは Drive へ上がる。設定を入れた人が承知の上で頼んだ動きなので黙ってやるが、
    /// どれだけ触ったかは記録に残す
    @discardableResult
    static func hideIconPreviews(under root: String) -> (touched: Int, folders: Int) {
        var touched = 0
        var folders = 0

        var queue = [root]
        while let directory = queue.popLast() {
            let children = subdirectories(of: directory)
            queue.append(contentsOf: children.map {
                (directory as NSString).appendingPathComponent($0)
            })
            guard !children.isEmpty else { continue }
            folders += children.count

            if apply(to: children, in: directory) { touched += 1 }
        }

        viewLogger.info("プレビューを切った: \(touched) ファイル / \(folders) フォルダ")
        return (touched, folders)
    }

    /// 一つのフォルダの `.DS_Store` を書き直す。書いたら true
    private static func apply(to children: [String], in directory: String) -> Bool {
        let path = (directory as NSString).appendingPathComponent(".DS_Store")

        var records: [DSStoreRecord] = []
        if FileManager.default.fileExists(atPath: path) {
            do {
                records = try DSStore.read(path)
            } catch {
                // 読めないものを書き直すと、入っていた設定を失う。触らない
                viewLogger.error(
                    "読めないので飛ばす: \(path, privacy: .public) \(error.localizedDescription, privacy: .public)"
                )
                return false
            }
        }

        // 既に設定を持っているフォルダは、その人の決めた通りにしておく
        var settled = Set<String>()
        for record in records where viewRecords.contains(record.id) {
            settled.insert(record.name)
        }

        let missing = children.filter { !settled.contains($0) }
        guard !missing.isEmpty else { return false }

        for name in missing {
            for (id, blob) in Self.blobs() {
                records.append(
                    DSStoreRecord(name: name, id: id, type: "blob", payload: blob))
            }
        }

        do {
            try DSStore.write(records, to: path)
            return true
        } catch {
            viewLogger.error(
                "書けなかった: \(path, privacy: .public) \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func subdirectories(of directory: String) -> [String] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory) else { return [] }

        return names.filter { name in
            guard !name.hasPrefix(".") else { return false }
            let path = (directory as NSString).appendingPathComponent(name)
            // リンクの先までは追わない。同じ場所を何度も歩くことになる
            guard let type = try? manager.attributesOfItem(atPath: path)[.type] as? FileAttributeType
            else { return false }
            return type == .typeDirectory
        }
    }

    /// プレビューを切った表示設定。
    ///
    /// 鍵を削ると Finder は読まない。`showIconPreview` だけの plist では効かず、
    /// この一式で効いた（2026-08-14 実測）。長さは1フォルダあたり約1.2KB
    private static func blobs() -> [(String, Data)] {
        let columns: [String: Any] = [
            "name": ["visible": true, "width": 300, "ascending": true, "index": 0],
            "dateModified": ["visible": true, "width": 181, "ascending": false, "index": 1],
            "size": ["visible": true, "width": 97, "ascending": false, "index": 2],
            "kind": ["visible": true, "width": 115, "ascending": true, "index": 3],
        ]

        let icon: [String: Any] = [
            "viewOptionsVersion": 1, "showIconPreview": false, "showItemInfo": false,
            "arrangeBy": "none", "iconSize": 64.0, "gridSpacing": 54.0, "textSize": 12.0,
            "labelOnBottom": true, "backgroundType": 0, "gridOffsetX": 0.0, "gridOffsetY": 0.0,
            "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0,
            "scrollPositionX": 0.0, "scrollPositionY": 0.0,
        ]

        let list: [String: Any] = [
            "viewOptionsVersion": 1, "showIconPreview": false, "iconSize": 16, "textSize": 12,
            "sortColumn": "name", "useRelativeDates": true, "calculateAllSizes": false,
            "columns": columns,
        ]

        return [("icvp", icon), ("lsvp", list)].compactMap { id, value in
            guard
                let data = try? PropertyListSerialization.data(
                    fromPropertyList: value, format: .binary, options: 0)
            else { return nil }
            return (id, data)
        }
    }
}
