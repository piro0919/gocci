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
// 既に表示設定を持つフォルダも覆う。以前から開いていたフォルダほどプレビューが生きており、
// そこを開くと中身が丸ごと落ちてくる（実測: `Images` を開いて 139MB）。
// 書き換えるのは `showIconPreview` の一項目だけで、並び順も列幅もアイコンの大きさも残す。

private let viewLogger = Logger(subsystem: "io.kkweb.gocci", category: "finderview")

enum FinderView {
    /// 表示設定を持つ記録。これが既にあるフォルダには触らない
    private static let viewRecords = ["icvp", "lsvp"]

    private static let queue = DispatchQueue(label: "io.kkweb.gocci.finderview")

    /// 設定を入れたときに、マウント先の下を一通り歩く。
    ///
    /// 走らせるのはこのときだけにしてある。一覧を取るのがひたすら遅く、大きめの Drive では
    /// 何時間もかかる（実測: 28分で上位2フォルダぶん。CPU 時間は 0.01 秒で、残りは待ち時間）。
    /// 定期的に歩き直す作りにすると、ほぼ常時 Drive を舐め続けることになる。
    /// 後から増えたフォルダは、そこを開いたときに `coverBrowsedDirectory` が拾う
    static func sweep(_ mountPoint: String) {
        guard Settings.keepsFinderSettings, !mountPoint.isEmpty else { return }

        queue.async {
            guard FileManager.default.fileExists(atPath: mountPoint) else { return }
            run(pending: [mountPoint], mountPoint: mountPoint)
        }
    }

    /// 前回の続きから歩く。歩き残しが無ければ何もしない。
    ///
    /// 一周に何時間もかかるので、終わる前の中断がむしろ普通に起きる——アプリの終了、
    /// 外付けを抜く、スリープ。根から歩き直していると、いつまでも終わらない
    static func resumeSweep(_ mountPoint: String) {
        guard Settings.keepsFinderSettings, !mountPoint.isEmpty else { return }

        queue.async {
            guard FileManager.default.fileExists(atPath: mountPoint),
                let pending = loadPending(for: mountPoint), !pending.isEmpty
            else { return }

            viewLogger.info("歩き残しから続ける: 残り \(pending.count) フォルダ")
            run(pending: pending, mountPoint: mountPoint)
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

    /// 拡張が最後に報せてきた「開いているフォルダ」。
    ///
    /// マウントを外すと、そこを見ていた Finder のウィンドウは黙って閉じる。閉じる前に
    /// どこを見ていたかを控えておき、繋ぎ直したあとで開き直すために使う
    static func browsedPath() -> String? {
        guard let data = try? Data(contentsOf: browsingURL) else { return nil }
        let path = String(decoding: data, as: UTF8.self)
        return path.isEmpty ? nil : path
    }

    private static var lastBrowsed = ""
    private static var lastCoveredAt = Date.distantPast
    /// 同じフォルダを見続けている間に見直す間隔。ここで新しく作られたフォルダを拾う
    private static let recheckInterval: TimeInterval = 10
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

    /// 見ているフォルダの一段先を覆う。歩き直しは何十分もかかるので、その隙間を埋める役。
    ///
    /// 移った直後だけでなく、同じ場所に留まっている間も見直す。フォルダは見ている最中に
    /// 増える——自分で作ることもあれば、Drive の側で増えることもある。
    /// 記録の無いフォルダを Finder が先に開くと、既定のまま「プレビュー有効」で保存される
    static func coverBrowsedDirectory() {
        guard Settings.keepsFinderSettings,
            let data = try? Data(contentsOf: browsingURL),
            case let path = String(decoding: data, as: UTF8.self), !path.isEmpty
        else { return }

        let moved = path != lastBrowsed
        guard moved || Date().timeIntervalSince(lastCoveredAt) > recheckInterval else { return }
        lastBrowsed = path
        lastCoveredAt = Date()
        let mountPoint = (Settings.mountPoint as NSString).standardizingPath
        guard !mountPoint.isEmpty, path == mountPoint || path.hasPrefix(mountPoint + "/") else {
            return
        }

        // 呼ばれるのは queue の上から。歩き回っている最中は、それが終わるまで順番を待つ。
        // 同じ `.DS_Store` を二人で書くと、どちらかの書き込みが消える
        guard let children = subdirectories(of: path), !children.isEmpty,
            apply(to: children, in: path)
        else { return }
        viewLogger.info("開いたフォルダの一段先を覆った: \(path, privacy: .public)")
    }

    /// 歩いている最中か。掃引が二重に走ると、同じ `.DS_Store` を二人で書くことになる
    private static var sweeping = false

    /// 中まで降りないフォルダ。
    ///
    /// 人が Finder で開く場所ではないのに、数だけが桁違いに多い。一つのリポジトリの
    /// `node_modules` だけで待ち行列が数百に膨らみ、その間ほかのフォルダが手つかずになる。
    /// `Miniconda3` ひとつで1時間以上を使った（2026-08-16 実測）。
    /// フォルダ自身の設定は親の `.DS_Store` に入るので、開いてもプレビューは出ない。
    ///
    /// `.git` などの隠しフォルダはここに要らない。`subdirectories` が先に弾いている
    private static let doNotEnter: Set<String> = [
        "node_modules", "__pycache__", "site-packages",
    ]

    /// 中まで降りるかどうか。
    ///
    /// 名前の一致だけでは足りない。Google ドライブは同期がぶつかると
    /// `node_modules (選択型同期の競合)` のように後ろを足した名前で複製を残す。
    /// 実際にこれで 541 フォルダを歩きかけた（2026-08-16 実測）
    private static func mayEnter(_ name: String) -> Bool {
        !doNotEnter.contains { name == $0 || name.hasPrefix($0 + " ") }
    }

    /// 待ち行列を歩いて、プレビューを切って回る。
    ///
    /// `.DS_Store` の書き込みは Drive へ上がる。設定を入れた人が承知の上で頼んだ動きなので
    /// 黙ってやるが、どれだけ触ったかは記録に残す。
    ///
    /// 1フォルダ片付けるごとに、残りを控えに書き出す。控えの置き場は手元のディスクで、
    /// 1フォルダの一覧取りに数秒かかるのに対して書き込みは桁が違う。歩きの速さには響かない
    private static func run(pending: [String], mountPoint: String) {
        guard !sweeping else { return }
        sweeping = true
        defer { sweeping = false }

        var queue = pending
        var touched = 0
        var folders = 0

        while let directory = queue.popLast() {
            // 設定を切られた、繋がりが切れた。その場でやめて、残りは控えに残す。
            //
            // マウント先の有無では足りない。rclone が落ちてもその場所は残り、中を覗くと
            // 空に見える。それを「子の無いフォルダ」と読むと、残り全部を歩いたことにして
            // 控えまで消してしまう（2026-08-15 に実際に起きた。rclone が落ちた4秒後に
            // 「歩き終えた」と出て、上位11フォルダが手つかずのまま残った）
            guard Settings.keepsFinderSettings, MountController.shared.state == .mounted else {
                savePending(queue + [directory], mountPoint: mountPoint)
                viewLogger.info("途中で止めた: 残り \(queue.count + 1) フォルダ")
                return
            }

            // 読めなかったのか、本当に子が無いのか。前者を後者として扱わない
            guard let children = subdirectories(of: directory) else {
                savePending(queue + [directory], mountPoint: mountPoint)
                viewLogger.info(
                    "一覧が取れないので止めた: \(directory, privacy: .public)（残り \(queue.count + 1) フォルダ）")
                return
            }

            if !children.isEmpty {
                folders += children.count
                if apply(to: children, in: directory) { touched += 1 }
            }

            // 書き出すのは apply の後。ここで落ちても、やり直すのは今のフォルダ1つぶん。
            // 中まで降りないものは積まない。名前は親の `.DS_Store` に既に入れてある
            queue.append(
                contentsOf: children
                    .filter { mayEnter($0) }
                    .map { (directory as NSString).appendingPathComponent($0) })
            savePending(queue, mountPoint: mountPoint)
        }

        clearPending()
        viewLogger.info("歩き終えた: \(touched) ファイル / \(folders) フォルダ")
    }

    // MARK: - 歩き残しの控え

    /// 控えの置き場。Drive 側には置かない。歩いている最中に Drive へ書き続けることになる
    private static var pendingURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Gocci", isDirectory: true)
            .appendingPathComponent("sweep.txt")
    }

    /// 1行目にマウント先、以降は歩き残したフォルダ。
    ///
    /// マウント先を控えておくのは、繋ぎ先を変えた人の残りを持ち越さないため
    private static func savePending(_ queue: [String], mountPoint: String) {
        let directory = pendingURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        let text = ([mountPoint] + queue).joined(separator: "\n")
        try? Data(text.utf8).write(to: pendingURL, options: .atomic)
    }

    private static func loadPending(for mountPoint: String) -> [String]? {
        guard let data = try? Data(contentsOf: pendingURL) else { return nil }

        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        guard let recorded = lines.first, recorded == mountPoint else {
            // 繋ぎ先が変わっている。前の残りは捨てる
            clearPending()
            return nil
        }
        lines.removeFirst()
        return lines.filter { !$0.isEmpty }
    }

    private static func clearPending() {
        try? FileManager.default.removeItem(at: pendingURL)
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

        // 既に設定を持っているフォルダは、プレビューの一項目だけ書き換える。
        // 一式を作り直すと、並び順も列幅もアイコンの大きさも既定に戻ってしまう
        let wanted = Set(children)
        var settled = Set<String>()
        var changed = false

        for index in records.indices where viewRecords.contains(records[index].id) {
            let record = records[index]
            guard wanted.contains(record.name) else { continue }
            settled.insert(record.name)

            guard let payload = previewDisabled(record.payload) else { continue }
            records[index] = DSStoreRecord(
                name: record.name, id: record.id, type: record.type, payload: payload)
            changed = true
        }

        let missing = children.filter { !settled.contains($0) }
        for name in missing {
            for (id, blob) in Self.blobs() {
                records.append(
                    DSStoreRecord(name: name, id: id, type: "blob", payload: blob))
            }
            changed = true
        }

        guard changed else { return false }

        do {
            try DSStore.write(records, to: path)
            return true
        } catch {
            viewLogger.error(
                "書けなかった: \(path, privacy: .public) \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// 中のフォルダの名前。一覧そのものが取れなかったときは nil。
    ///
    /// 空の配列と混ぜない。繋がりが切れている間は一覧が取れず、混ぜると
    /// 「子の無いフォルダ」として片付いたことになってしまう
    /// 既にある表示設定から、プレビューの一項目だけを落とす。
    ///
    /// 既に切ってあるものと、読めないものは nil。書き直す必要が無い
    private static func previewDisabled(_ payload: Data) -> Data? {
        guard
            var plist = try? PropertyListSerialization.propertyList(
                from: payload, options: [], format: nil) as? [String: Any],
            (plist["showIconPreview"] as? Bool) != false
        else { return nil }

        plist["showIconPreview"] = false
        return try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .binary, options: 0)
    }

    private static func subdirectories(of directory: String) -> [String]? {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory) else { return nil }

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
