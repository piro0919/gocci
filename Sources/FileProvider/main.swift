import CoreGraphics
import FileProvider
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

/// 拡張の中は外から見えない。何を訊かれて何を返したかを記録に残す
let logger = Logger(subsystem: "io.kkweb.gocci", category: "fileprovider")

// Drive を「クラウドのフォルダ」として Finder に見せる拡張。
//
// これまでの作り（NFS のマウント）では、Finder から見ると普通のディスクだった。だから
// フォルダを開けばサムネイルのために中身が読まれ、読まれれば取りに行くしかなかった。
// `.DS_Store` にプレビュー切りを書いて回っていたのは、その読み込みを起こさせないための回避。
//
// こちらでは macOS に事情が伝わる。サムネイルは専用の口（`fetchThumbnails`）で訊かれ、
// 本体は読まれない。途中だけ渡す道（`fetchPartialContents`）もある。
//
// 中身の受け渡しは rclone に任せる。マウントは張らず、`rcd` で開けた口へ HTTP で頼む。
//
// 識別子は Drive の ID にしてある。道にすると名前を変えるたびに別物になってしまう。
// rclone に頼むときは道が要るので、その対応は `Ledger` が持つ。根だけ `.rootContainer`。

final class Item: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let isDirectory: Bool
    let bytes: Int64
    let modified: Date
    /// rclone に頼むときの道。識別子には出さない
    let path: String
    /// 中身が変わったかの見分け。大きさと時刻が変わっていなければ同じものとして扱う
    let signature: String

    init(id: String, path: String, isDirectory: Bool, bytes: Int64, modified: Date) {
        self.itemIdentifier = NSFileProviderItemIdentifier(id)
        self.filename = (path as NSString).lastPathComponent
        self.isDirectory = isDirectory
        self.bytes = bytes
        self.modified = modified
        self.path = path
        // 秒で丸める。小数のまま文字にすると、控えに書いて読み直すたびに揺れて、
        // 変わっていないものまで「変わった」と伝えることになる
        // （2026-08-16 実測。1件しか変えていないのに 1159 件を更新と数えた）
        self.signature = "\(bytes)-\(Int(modified.timeIntervalSince1970))"
    }

    /// 親は台帳から引く。作るときに求めると、台帳を読み込んでいる最中に
    /// その台帳を引くことになる
    var parentItemIdentifier: NSFileProviderItemIdentifier {
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty else { return .rootContainer }
        return Ledger.shared.identifier(forPath: parent) ?? .rootContainer
    }

    var contentType: UTType {
        if isDirectory { return .folder }
        let suffix = (filename as NSString).pathExtension
        return UTType(filenameExtension: suffix) ?? .data
    }

    var documentSize: NSNumber? { isDirectory ? nil : NSNumber(value: bytes) }
    var contentModificationDate: Date? { modified }
    var creationDate: Date? { modified }

    /// 何ができるか。ここで許していないことは、macOS がそもそも頼んでこない
    var capabilities: NSFileProviderItemCapabilities {
        if isDirectory {
            return [
                .allowsReading, .allowsContentEnumerating, .allowsAddingSubItems, .allowsDeleting,
                .allowsRenaming, .allowsReparenting,
            ]
        }
        // `allowsEvicting` は macOS 13 で非推奨になったが、Finder の「ダウンロードを削除」は
        // まだこれを見ている（2026-08-16 実測。付けないと右クリックに項目が出ない）
        return [
            .allowsReading, .allowsWriting, .allowsDeleting, .allowsRenaming, .allowsReparenting,
            .allowsEvicting,
        ]
    }

    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(
            contentVersion: Data(signature.utf8), metadataVersion: Data(signature.utf8))
    }
}

/// マウント先そのもの
final class Root: NSObject, NSFileProviderItem {
    var itemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var filename: String { "Gocci" }
    var contentType: UTType { .folder }
    var capabilities: NSFileProviderItemCapabilities {
        [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems]
    }
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: Data("1".utf8), metadataVersion: Data("1".utf8))
    }
}

/// ゴミ箱。中身は持たないが、これを返せないと macOS は先へ進まない
/// （2026-08-16 実測。失敗を返すと列挙まで辿り着かず `-2011` で止まる）
final class Trash: NSObject, NSFileProviderItem {
    var itemIdentifier: NSFileProviderItemIdentifier { .trashContainer }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var filename: String { "Trash" }
    var contentType: UTType { .folder }
    var capabilities: NSFileProviderItemCapabilities { [.allowsReading, .allowsContentEnumerating] }
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: Data("1".utf8), metadataVersion: Data("1".utf8))
    }
}

/// 列挙で分かったことを覚えておく。`item()` は列挙と食い違ってはいけない。
///
/// 識別子は Drive の ID にしてある。道にすると、名前を変えるたびに識別子が変わるうえ、
/// 「識別子に機密情報を入れるな。システムログや診断ファイルに残る」という決めごとに反する
/// （`NSFileProviderItem.h` 295-299行）。ID なら名前が変わっても同じものを指し続ける。
///
/// ただし rclone に頼むときは道が要るので、ID から道を引けるようにしておく。拡張は
/// しょっちゅう起き直るので、覚えた内容は手元のディスクにも残す
final class Ledger {
    static let shared = Ledger()
    private var entries: [String: Item] = [:]
    /// 消したもの。混ぜるときに蘇らせないための覚え
    private var forgotten = Set<String>()
    private let lock = NSLock()

    private var url: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ledger.json")
    }

    /// 最後にそのフォルダを並べた時刻。変化を見て回る先を絞るのに使う
    private var listedAt: [String: Date] = [:]

    init() { load() }

    func noteListed(_ directory: String) {
        lock.lock(); defer { lock.unlock() }
        listedAt[directory] = Date()
    }

    func remember(_ item: Item) {
        lock.lock()
        entries[item.itemIdentifier.rawValue] = item
        lock.unlock()
        save()
    }

    func recall(_ identifier: NSFileProviderItemIdentifier) -> Item? {
        lock.lock(); defer { lock.unlock() }
        return entries[identifier.rawValue]
    }

    /// 道から識別子を引く。親を辿るのに使う
    func identifier(forPath path: String) -> NSFileProviderItemIdentifier? {
        lock.lock(); defer { lock.unlock() }
        return entries.values.first { $0.path == path }?.itemIdentifier
    }

    /// そのフォルダの直下として覚えているもの。変化の突き合わせに使う
    func children(of directory: String) -> [Item] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.filter {
            ($0.path as NSString).deletingLastPathComponent == directory
        }
    }

    /// 作業組に並べるもの。最近開いた場所の中身に絞る。
    ///
    /// 「最近使ったもの」を入れる場所であって、全部を入れる場所ではない
    /// （`NSFileProviderItem.h` 30-36行）
    func recent() -> [Item] {
        let directories = Set(recentDirectories())
        lock.lock(); defer { lock.unlock() }
        return entries.values.filter {
            directories.contains(($0.path as NSString).deletingLastPathComponent)
        }
    }

    /// 変化を見て回る先。
    ///
    /// 覚えているフォルダを全部見ると、見るほどに覚えが増えて雪だるまになる
    /// （2026-08-16 実測。2周で 1159 件から 5581 件に膨らんだ）。
    /// 人が最近開いたところだけにする。閉じた場所の変化は、開き直したときに拾えばいい
    func recentDirectories(within age: TimeInterval = 1800, limit: Int = 20) -> [String] {
        lock.lock(); defer { lock.unlock() }

        let fresh = listedAt.filter { Date().timeIntervalSince($0.value) < age }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
        // 根はいつも見る。ここが一番変わる
        return Array(Set(fresh).union([""]))
    }

    /// 識別子から道を引く。rclone に頼むときは道が要る
    func path(of identifier: NSFileProviderItemIdentifier) -> String? {
        if identifier == .rootContainer { return "" }
        return recall(identifier)?.path
    }

    /// 消えたものを忘れる。残しておくと、次に同じ ID を訊かれたときに嘘を返す
    func forget(_ identifier: NSFileProviderItemIdentifier) {
        lock.lock()
        entries.removeValue(forKey: identifier.rawValue)
        forgotten.insert(identifier.rawValue)
        lock.unlock()
        save()
    }

    // MARK: - 手元に残す

    /// 書く前に、ディスクにあるものと混ぜる。
    ///
    /// 拡張は同時に何本も起きる。それぞれが自分の覚えだけを書き出すと、後から書いたほうが
    /// 先の記録を消す。実際、1000件あった控えが19件まで縮み、控えから落ちたファイルは
    /// Finder から見えなくなった。Drive には残っているのに消えたように見える
    /// （2026-08-16 実測）。
    ///
    /// 消すときは `forget` が明示的に落とすので、混ぜても消えたものが蘇ることはない
    private func save() {
        guard let url else { return }

        lock.lock()
        let mine = entries.mapValues { item in
            [
                "path": item.path, "dir": item.isDirectory, "bytes": item.bytes,
                "modified": item.modified.timeIntervalSince1970,
            ] as [String: Any]
        }
        let dropped = forgotten
        lock.unlock()

        var merged = diskContents()
        for (id, value) in mine { merged[id] = value }
        for id in dropped { merged.removeValue(forKey: id) }

        guard let data = try? JSONSerialization.data(withJSONObject: merged) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func diskContents() -> [String: [String: Any]] {
        guard let url, let data = try? Data(contentsOf: url),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        else { return [:] }
        return payload
    }

    private func load() {
        for (id, raw) in diskContents() {
            guard let path = raw["path"] as? String else { continue }
            entries[id] = Item(
                id: id, path: path, isDirectory: (raw["dir"] as? Bool) ?? false,
                bytes: (raw["bytes"] as? NSNumber)?.int64Value ?? 0,
                modified: Date(timeIntervalSince1970: (raw["modified"] as? Double) ?? 0))
        }
    }
}

final class Enumerator: NSObject, NSFileProviderEnumerator {
    private let container: NSFileProviderItemIdentifier
    private let client: RcClient?

    init(_ container: NSFileProviderItemIdentifier, client: RcClient?) {
        self.container = container
        self.client = client
    }

    func invalidate() {}

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage
    ) {
        // ゴミ箱は中身を持たない
        guard container != .trashContainer else {
            observer.finishEnumerating(upTo: nil)
            return
        }

        // 作業組は「一度でも見た場所」の集まり。Drive の道ではないので、
        // そのまま rclone へ渡すと `directory not found` になる（2026-08-16 実測）。
        // ここには覚えているものを並べる。並べておかないと、変化を伝える先が無い
        if container == .workingSet {
            let known = Ledger.shared.recent()
            logger.info("作業組を並べた: \(known.count) 件")
            observer.didEnumerate(known)
            observer.finishEnumerating(upTo: nil)
            return
        }

        guard let client else {
            logger.error("rclone の口が分からない")
            observer.finishEnumeratingWithError(NSFileProviderError(.serverUnreachable))
            return
        }

        guard let base = Ledger.shared.path(of: container) else {
            logger.error("どこを並べるのか分からない")
            observer.finishEnumeratingWithError(NSFileProviderError(.noSuchItem))
            return
        }
        client.list(base) { result in
            switch result {
            case .failure(let error):
                logger.error("一覧を取れなかった: \(error.localizedDescription, privacy: .public)")
                observer.finishEnumeratingWithError(NSFileProviderError(.serverUnreachable))
            case .success(let entries):
                let items = entries.map { entry -> Item in
                    let path = base.isEmpty ? entry.name : "\(base)/\(entry.name)"
                    let item = Item(
                        id: entry.id, path: path, isDirectory: entry.isDirectory,
                        bytes: entry.size, modified: entry.modified)
                    Ledger.shared.remember(item)
                    return item
                }
                Ledger.shared.noteListed(base)
                logger.info("並べた: \(base, privacy: .public) の \(items.count) 件")
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            }
        }
    }

    /// Drive 側で変わったものを伝える。
    ///
    /// Drive に「前回から何が変わったか」を訊く道は rclone に無い。なので、今の一覧を取って
    /// 手元の覚えと突き合わせる。増えた・変わった・消えたを、それぞれ macOS に渡す。
    ///
    /// 呼ばれるのは、アプリが `signalEnumerator` で「見直して」と言ったときと、
    /// macOS が自分の都合で確かめたいとき
    /// 覚えているフォルダを順に見て回り、変わっていたものをまとめて伝える。
    ///
    /// Drive に「前回から何が変わったか」を訊く道は rclone に無いので、こうするしかない。
    /// 数が増えると重くなるが、見に行くのは1分に1回で、しかも一覧だけ
    private func sweepForChanges(
        client: RcClient, observer: NSFileProviderChangeObserver, anchor: NSFileProviderSyncAnchor
    ) {
        let directories = Ledger.shared.recentDirectories()
        let group = DispatchGroup()
        let lock = NSLock()
        var changed: [Item] = []
        var gone: [NSFileProviderItemIdentifier] = []

        for base in directories {
            group.enter()
            let remembered = Ledger.shared.children(of: base)

            client.list(base) { result in
                defer { group.leave() }
                guard case .success(let entries) = result else { return }

                var seen = Set<String>()
                var mine: [Item] = []

                for entry in entries {
                    let path = base.isEmpty ? entry.name : "\(base)/\(entry.name)"
                    seen.insert(entry.id)

                    let item = Item(
                        id: entry.id, path: path, isDirectory: entry.isDirectory,
                        bytes: entry.size, modified: entry.modified)

                    if let known = remembered.first(where: {
                        $0.itemIdentifier.rawValue == entry.id
                    }), known.signature == item.signature, known.path == item.path {
                        continue
                    }
                    Ledger.shared.remember(item)
                    mine.append(item)
                }

                let missing = remembered.filter { !seen.contains($0.itemIdentifier.rawValue) }
                for item in missing { Ledger.shared.forget(item.itemIdentifier) }

                lock.lock()
                changed.append(contentsOf: mine)
                gone.append(contentsOf: missing.map(\.itemIdentifier))
                lock.unlock()
            }
        }

        group.notify(queue: .global()) {
            if !changed.isEmpty { observer.didUpdate(changed) }
            if !gone.isEmpty { observer.didDeleteItems(withIdentifiers: gone) }
            if !changed.isEmpty || !gone.isEmpty {
                logger.info("見て回った: 更新 \(changed.count) / 消えた \(gone.count)")
            }
            observer.finishEnumeratingChanges(
                upTo: NSFileProviderSyncAnchor(Data(String(Date().timeIntervalSince1970).utf8)),
                moreComing: false)
        }
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor
    ) {
        guard container != .trashContainer, let client else {
            observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
            return
        }

        // 作業組で訊かれたら、覚えているフォルダを順に見て回る
        if container == .workingSet {
            sweepForChanges(client: client, observer: observer, anchor: anchor)
            return
        }

        guard let base = Ledger.shared.path(of: container) else {
            observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
            return
        }

        logger.info("変化を訊かれた: \(base, privacy: .public)")
        let remembered = Ledger.shared.children(of: base)

        client.list(base) { result in
            guard case .success(let entries) = result else {
                // 訊けなかっただけで、変わっていないとは限らない。次に持ち越す
                observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
                return
            }

            var changed: [Item] = []
            var seen = Set<String>()

            for entry in entries {
                let path = base.isEmpty ? entry.name : "\(base)/\(entry.name)"
                seen.insert(entry.id)

                let item = Item(
                    id: entry.id, path: path, isDirectory: entry.isDirectory,
                    bytes: entry.size, modified: entry.modified)

                // 中身も名前も変わっていなければ、伝える必要がない
                if let known = remembered.first(where: { $0.itemIdentifier.rawValue == entry.id }),
                    known.signature == item.signature, known.path == item.path
                {
                    continue
                }
                Ledger.shared.remember(item)
                changed.append(item)
            }

            let gone = remembered.filter { !seen.contains($0.itemIdentifier.rawValue) }
            for item in gone { Ledger.shared.forget(item.itemIdentifier) }

            if !changed.isEmpty { observer.didUpdate(changed) }
            if !gone.isEmpty { observer.didDeleteItems(withIdentifiers: gone.map(\.itemIdentifier)) }

            if !changed.isEmpty || !gone.isEmpty {
                logger.info(
                    "変わっていた: \(base, privacy: .public) で 更新 \(changed.count) / 消えた \(gone.count)")
            }
            observer.finishEnumeratingChanges(
                upTo: NSFileProviderSyncAnchor(Data(String(Date().timeIntervalSince1970).utf8)),
                moreComing: false)
        }
    }

    /// 今どこまで見たか。ここが変わらないと、macOS は変化を訊きに来ない
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(
            NSFileProviderSyncAnchor(Data(String(Date().timeIntervalSince1970).utf8)))
    }
}

final class GocciFileProvider: NSObject, NSFileProviderReplicatedExtension {
    /// 訊かれるたびに控えを読み直す。
    ///
    /// 起きたときに1回だけ読む作りにしていたら、繋ぐ前に起こされた拡張が
    /// 「口が分からない」と言い続けた。合言葉は繋ぎ直すたびに変わるので、
    /// 覚え込ませずに毎回読むほうが素直
    private var client: RcClient? {
        RcEndpoint.read().map(RcClient.init(connection:))
    }

    required init(domain: NSFileProviderDomain) {
        super.init()
        Self.myDomain = domain
        logger.info("拡張が起きた: \(domain.identifier.rawValue, privacy: .public)")
    }

    func invalidate() {}

    func item(
        for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        switch identifier {
        case .rootContainer:
            completionHandler(Root(), nil)
        case .trashContainer:
            completionHandler(Trash(), nil)
        default:
            if let known = Ledger.shared.recall(identifier) {
                completionHandler(known, nil)
            } else {
                // 台帳は拡張が起き直すと空になる。訊かれたものが無ければ、
                // 親を並べ直して探す。macOS は前に見たものを覚えていて、
                // こちらが忘れていても平気で訊いてくる
                find(identifier, completion: completionHandler)
            }
        }
        return Progress()
    }

    /// 台帳を先に見て、無ければ親を並べ直して探す。
    ///
    /// macOS は前に見たものを覚えていて、列挙を挟まずに訊いてくることがある。
    /// 絵を頼まれるときがまさにそれで、台帳だけを見ていると必ず空振りする
    func resolve(
        _ identifier: NSFileProviderItemIdentifier, completion: @escaping (Item?) -> Void
    ) {
        if let known = Ledger.shared.recall(identifier) {
            completion(known)
            return
        }
        find(identifier) { item, _ in completion(item as? Item) }
    }

    /// 親フォルダを並べ直して、その中から探す
    private func find(
        _ identifier: NSFileProviderItemIdentifier,
        completion: @escaping (NSFileProviderItem?, Error?) -> Void
    ) {
        guard let client else {
            completion(nil, NSFileProviderError(.serverUnreachable))
            return
        }

        guard let path = Ledger.shared.path(of: identifier) else {
            // 道を知らないものは探しようがない。macOS には「無い」と答える
            completion(nil, NSFileProviderError(.noSuchItem))
            return
        }
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent

        client.list(parent) { result in
            guard case .success(let entries) = result,
                let found = entries.first(where: { $0.name == name })
            else {
                completion(nil, NSFileProviderError(.noSuchItem))
                return
            }

            let item = Item(
                id: found.id, path: path, isDirectory: found.isDirectory, bytes: found.size,
                modified: found.modified)
            Ledger.shared.remember(item)
            completion(item, nil)
        }
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?, request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        guard let client, let item = Ledger.shared.recall(itemIdentifier) else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return progress
        }

        // 途中だけ渡す道と同じで、渡すファイルは見える場所と同じボリュームに置く。
        // 手元の一時置き場に作ると、外付けのときに別のボリュームになり、
        // 渡した直後に `POSIX 2` で断られる（2026-08-17 実測）
        let destination = Self.scratchDirectory()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(item.filename)
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        client.copy(path: item.path, to: destination) { result in
            progress.completedUnitCount = 1
            switch result {
            case .failure(let error):
                logger.error("取れなかった: \(error.localizedDescription, privacy: .public)")
                completionHandler(nil, nil, NSFileProviderError(.serverUnreachable))
            case .success:
                logger.info("渡した: \(item.filename, privacy: .public)")
                completionHandler(destination, item, nil)
            }
        }
        return progress
    }

    // MARK: - 書き込み

    func createItem(
        basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
        options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        // ゴミ箱まわりは素通しにする。Drive には作らず、頼まれた通りを返しておく。
        //
        // ここで断ると、macOS は `-2011「同期は有効になっていません」` を出し続け、
        // 列挙まで辿り着かない。macOS はゴミ箱そのもの（`.Trash`）を根の下に作ろうとするので、
        // 「ゴミ箱の下か」だけを見ていると取りこぼす（2026-08-17 実測）
        if itemTemplate.parentItemIdentifier == .trashContainer
            || itemTemplate.itemIdentifier == .trashContainer
            || itemTemplate.filename == ".Trash"
        {
            completionHandler(itemTemplate, [], false, nil)
            return progress
        }

        // 外付けに置くと、macOS はドメインの入れ物そのもの（`Gocci-Gocci`）を
        // 「ディスクにあって Drive に無いもの」と見なし、根の下へ作ろうとする。
        // 断ると `-2011` を出し続けて列挙まで進まないので、受けたことにして Drive には作らない
        // （2026-08-17 実測）
        if itemTemplate.parentItemIdentifier == .rootContainer,
            itemTemplate.filename.hasPrefix("Gocci-")
        {
            logger.info("入れ物そのものは作らない: \(itemTemplate.filename, privacy: .public)")
            completionHandler(itemTemplate, [], false, nil)
            return progress
        }

        guard let client else {
            completionHandler(nil, [], false, NSFileProviderError(.serverUnreachable))
            return progress
        }

        let parent = Ledger.shared.path(of: itemTemplate.parentItemIdentifier) ?? ""
        let name = itemTemplate.filename
        let path = parent.isEmpty ? name : "\(parent)/\(name)"
        let isDirectory = itemTemplate.contentType == .folder

        /// 上げ終えたら、こちらの覚えも新しくして返す
        let settle: (Int64) -> Void = { bytes in
            // 上げた直後は Drive の ID が分からない。道を借りておき、
            // 次に並べ直したときに本物の ID へ入れ替わる
            let item = Item(
                id: path, path: path, isDirectory: isDirectory, bytes: bytes,
                modified: itemTemplate.contentModificationDate.flatMap { $0 } ?? Date())
            Ledger.shared.remember(item)
            logger.info("作った: \(path, privacy: .public)")
            progress.completedUnitCount = 1
            completionHandler(item, [], false, nil)
        }

        let refuse: (Error) -> Void = { error in
            logger.error("作れなかった: \(path, privacy: .public) \(error.localizedDescription, privacy: .public)")
            progress.completedUnitCount = 1
            completionHandler(nil, [], false, NSFileProviderError(.serverUnreachable))
        }

        if isDirectory {
            client.makeDirectory(path: path) { result in
                switch result {
                case .success: settle(0)
                case .failure(let error): refuse(error)
                }
            }
        } else {
            guard let url else {
                completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
                return progress
            }
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            client.upload(local: url, named: name, toDirectory: parent) { result in
                switch result {
                case .success: settle(bytes)
                case .failure(let error): refuse(error)
                }
            }
        }
        return progress
    }

    func modifyItem(
        _ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields, contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        guard let client else {
            completionHandler(nil, [], false, NSFileProviderError(.serverUnreachable))
            return progress
        }

        guard let path = Ledger.shared.path(of: item.itemIdentifier) else {
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            return progress
        }

        // 名前が変わった、あるいは別のフォルダへ移された。Drive では同じ操作になる
        if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
            let parent = Ledger.shared.path(of: item.parentItemIdentifier) ?? ""
            let destination = parent.isEmpty ? item.filename : "\(parent)/\(item.filename)"

            guard destination != path else {
                completionHandler(item, [], false, nil)
                return progress
            }

            client.moveFile(from: path, to: destination) { result in
                progress.completedUnitCount = 1
                switch result {
                case .failure(let error):
                    logger.error(
                        "動かせなかった: \(path, privacy: .public) \(error.localizedDescription, privacy: .public)")
                    completionHandler(nil, [], false, NSFileProviderError(.serverUnreachable))
                case .success:
                    let moved = Item(
                        id: item.itemIdentifier.rawValue, path: destination, isDirectory: false,
                        bytes: item.documentSize.flatMap { $0 }?.int64Value ?? 0,
                        modified: item.contentModificationDate.flatMap { $0 } ?? Date())
                    Ledger.shared.remember(moved)
                    logger.info("動かした: \(path, privacy: .public) → \(destination, privacy: .public)")
                    completionHandler(moved, [], false, nil)
                }
            }
            return progress
        }

        // 中身が書き換えられた
        guard changedFields.contains(.contents), let newContents else {
            completionHandler(item, [], false, nil)
            return progress
        }

        let parent = (path as NSString).deletingLastPathComponent
        let bytes =
            (try? newContents.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0

        client.upload(
            local: newContents, named: (path as NSString).lastPathComponent,
            toDirectory: parent
        ) { result in
            progress.completedUnitCount = 1
            switch result {
            case .failure(let error):
                logger.error("書けなかった: \(path, privacy: .public) \(error.localizedDescription, privacy: .public)")
                completionHandler(nil, [], false, NSFileProviderError(.serverUnreachable))
            case .success:
                let updated = Item(
                    id: item.itemIdentifier.rawValue, path: path, isDirectory: false,
                    bytes: bytes, modified: Date())
                Ledger.shared.remember(updated)
                logger.info("書いた: \(path, privacy: .public)")
                completionHandler(updated, [], false, nil)
            }
        }
        return progress
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        guard let client else {
            completionHandler(NSFileProviderError(.serverUnreachable))
            return progress
        }

        guard let known = Ledger.shared.recall(identifier) else {
            // 知らないものは、こちらから見れば既に無い
            completionHandler(nil)
            return progress
        }
        let path = known.path
        let isDirectory = known.isDirectory

        let finish: (Result<Void, Error>) -> Void = { result in
            progress.completedUnitCount = 1
            switch result {
            case .failure(let error):
                logger.error("消せなかった: \(path, privacy: .public) \(error.localizedDescription, privacy: .public)")
                completionHandler(NSFileProviderError(.serverUnreachable))
            case .success:
                Ledger.shared.forget(identifier)
                logger.info("消した: \(path, privacy: .public)")
                completionHandler(nil)
            }
        }

        // フォルダは中身ごと。macOS はゴミ箱へ入れる前にここを通る
        if isDirectory {
            client.purge(path: path, completion: finish)
        } else {
            client.deleteFile(path: path, completion: finish)
        }
        return progress
    }

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        Enumerator(containerItemIdentifier, client: client)
    }
}

// MARK: - 右クリックの項目

// File Provider の下では、Finder 拡張のメニューは出ない。両方を同時に持つこともできない
// （Apple の開発者フォーラム 718381・736725）。出したい項目は拡張の Info.plist に
// `NSExtensionFileProviderActions` として書き、ここで受ける。
//
// iCloud Drive の「ダウンロードを削除」は Apple の内製で、こちらには降りてこない。
// 同じことをしたければ自分で足す

extension GocciFileProvider: NSFileProviderCustomAction {
    /// `@objc` を付ける。付けないと macOS からは実装が見えず、メニューは出るのに
    /// 押しても何も起きない（2026-08-17 実測）
    @objc func performAction(
        identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
        onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))

        guard actionIdentifier.rawValue == "io.kkweb.gocci.evict" else {
            completionHandler(NSFileProviderError(.noSuchItem))
            return progress
        }

        // 実体を捨てるのは macOS の受け持ち。こちらは頼むだけ
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier("gocci"), displayName: "Gocci")
        guard let manager = NSFileProviderManager(for: domain) else {
            completionHandler(NSFileProviderError(.serverUnreachable))
            return progress
        }

        let group = DispatchGroup()
        for identifier in itemIdentifiers {
            group.enter()
            manager.evictItem(identifier: identifier) { error in
                // 実体を持っていないものを頼まれることがある。捨てるものが無いだけなので、
                // 失敗として扱わない
                if let error, (error as NSError).code != NSFileProviderError.nonEvictable.rawValue {
                    logger.error(
                        "手元から消せなかった: \(String(describing: error), privacy: .public)")
                }
                progress.completedUnitCount += 1
                group.leave()
            }
        }

        let count = itemIdentifiers.count
        group.notify(queue: .global()) {
            logger.info("手元から消した: \(count) 件")
            completionHandler(nil)
        }
        return progress
    }
}

// MARK: - 途中だけ取る

// 丸ごと落とさずに、読まれている辺りだけを渡す。10GB の動画を開いても、そこだけで済む。
//
// 決まりごとは3つ（`NSFileProviderReplicatedExtension.h` 1219行から）。
//
// - 渡す範囲は、頼まれた範囲を覆っていて、指定された単位の倍数に揃っていること
// - 取った中身は、ファイルの中の同じ位置に置くこと。手前は穴のままでよい
// - ファイルの大きさは、渡した範囲の終わりまであれば足りる

extension GocciFileProvider: NSFileProviderPartialContentFetching {
    /// 一度に取りに行く最小の量。これより小さく頼まれても、この分は取っておく
    private static let readAhead = 8 << 20

    func fetchPartialContents(
        for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion,
        request: NSFileProviderRequest, minimalRange requestedRange: NSRange,
        aligningTo alignment: Int, options: NSFileProviderFetchContentsOptions = [],
        completionHandler: @escaping (URL?, NSFileProviderItem?, NSRange, NSFileProviderMaterializationFlags, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        resolve(itemIdentifier) { [weak self] item in
            guard let self, let client = self.client, let item else {
                completionHandler(nil, nil, NSRange(), [], NSFileProviderError(.noSuchItem))
                return
            }

            // 頼まれた範囲を覆うように、指定された単位へ広げる。
            //
            // 頼まれた分ちょうどを返すと、頭から読むだけで往復が何百回にもなる。macOS が
            // 訊いてくるのは 16KB ずつで、しかも一度取るたびに間を置かれるので、9MB の
            // ファイルに18分かかった（2026-08-17 実測）。先を多めに取っておく
            let start = (requestedRange.location / alignment) * alignment
            let wanted = max(
                requestedRange.location + requestedRange.length - start, Self.readAhead)
            let end = min(
                Int(item.bytes), start + ((wanted + alignment - 1) / alignment) * alignment)
            let length = max(0, end - start)

            guard length > 0 else {
                completionHandler(nil, nil, NSRange(), [], NSFileProviderError(.noSuchItem))
                return
            }

            client.fetchRange(
                path: item.path, offset: Int64(start), length: Int64(length)
            ) { result in
                progress.completedUnitCount = 1

                switch result {
                case .failure(let error):
                    logger.error(
                        "途中を取れなかった: \(error.localizedDescription, privacy: .public)")
                    completionHandler(nil, nil, NSRange(), [], NSFileProviderError(.serverUnreachable))

                case .success(let data):
                    guard
                        let file = Self.place(
                            data, at: start, of: item, identifier: itemIdentifier)
                    else {
                        completionHandler(
                            nil, nil, NSRange(), [], NSFileProviderError(.noSuchItem))
                        return
                    }

                    let fetched = NSRange(location: start, length: data.count)
                    logger.info(
                        "途中を渡した: \(item.filename, privacy: .public) の \(start) から \(data.count) バイト")
                    completionHandler(file, item, fetched, [], nil)
                }
            }
        }
        return progress
    }

    /// 取った中身を、ファイルの中の同じ位置へ置く。手前は穴のままにする
    private static func place(
        _ data: Data, at offset: Int, of item: Item, identifier: NSFileProviderItemIdentifier
    ) -> URL? {
        // 渡すファイルは、人から見える場所と同じボリュームに置く決まり
        // （`NSFileProviderReplicatedExtension.h` 1240行）。手元の一時置き場に作ると、
        // 外付けに置いたときに別のボリュームになり、受け取ってもらえない（2026-08-17 実測）
        let directory = scratchDirectory()
            .appendingPathComponent("part-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let file = directory.appendingPathComponent(item.filename)
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
            let handle = try? FileHandle(forWritingTo: file)
        else { return nil }
        defer { try? handle.close() }

        // 頭から書かずに位置を飛ばす。飛ばした分は穴になり、場所も食わない
        try? handle.seek(toOffset: UInt64(offset))
        try? handle.write(contentsOf: data)
        return file
    }
}

// MARK: - サムネイル

// これまでは Finder が勝手に中身を読んでいた。ここでは macOS が「この絵をくれ」と訊きに来る。
// 訊かれた側が、渡すか渡さないかを決められる。断っても本体は読まれない。
//
// Drive はサムネイルの絵を持っているが、rclone の一覧には出てこない（2026-08-16 に確認。
// `metadata` を付けても `thumbnailLink` は返らない）。なので、こちらで作る。
//
// 作るために本体を落とすのでは元の木阿弥なので、小さい絵だけに限る。動画や大きな素材は
// 断る。断ると macOS は書類の種類に応じた絵を出す。
//
// 返した絵は macOS が保管する。`itemVersion.contentVersion` が変わるまで訊かれない

extension GocciFileProvider: NSFileProviderThumbnailing {
    /// これより大きいものは作らない。落とす量が見合わない
    private static let thumbnailLimit: Int64 = 20_000_000

    func fetchThumbnails(
        for itemIdentifiers: [NSFileProviderItemIdentifier], requestedSize size: CGSize,
        perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
        let group = DispatchGroup()
        logger.info("絵を訊かれた: \(itemIdentifiers.count) 件")

        for identifier in itemIdentifiers {
            group.enter()

            /// 「絵は無い」と答える。これは失敗ではない。macOS は書類の種類に応じた絵を出す
            let giveUp = {
                perThumbnailCompletionHandler(identifier, nil, nil)
                progress.completedUnitCount += 1
                group.leave()
            }

            resolve(identifier) { [weak self] item in
                guard let self, let client = self.client, let item,
                    !item.isDirectory, item.bytes <= Self.thumbnailLimit,
                    item.contentType.conforms(to: .image)
                else { return giveUp() }

                let scratch = FileManager.default.temporaryDirectory
                    .appendingPathComponent("thumb-\(UUID().uuidString)")

                client.copy(path: item.path, to: scratch) { result in
                    defer { try? FileManager.default.removeItem(at: scratch) }

                    guard case .success = result else { return giveUp() }

                    let art = Self.shrink(scratch, to: size)
                    logger.info(
                        "絵を返した: \(item.filename, privacy: .public)（\(art?.count ?? 0) バイト）")
                    perThumbnailCompletionHandler(identifier, art, nil)
                    progress.completedUnitCount += 1
                    group.leave()
                }
            }
        }

        group.notify(queue: .global()) { completionHandler(nil) }
        return progress
    }

    /// 渡すものを一時的に置く場所。macOS が指すところを使う
    /// 自分がどの繋ぎとして起こされたか。外付けだと識別子が毎回変わるので、
    /// 決め打ちでは自分を見つけられない
    nonisolated(unsafe) static var myDomain: NSFileProviderDomain?

    static func scratchDirectory() -> URL {
        if let domain = myDomain, let manager = NSFileProviderManager(for: domain),
            let url = try? manager.temporaryDirectoryURL()
        {
            return url
        }
        return FileManager.default.temporaryDirectory
    }

    /// 絵を縮める。元の絵は開かずに、ImageIO に縮小だけ頼む
    private static func shrink(_ url: URL, to size: CGSize) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(size.width, size.height)),
        ]
        guard
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
            let data = CFDataCreateMutable(nil, 0),
            let target = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
        else { return nil }

        CGImageDestinationAddImage(target, image, nil)
        guard CGImageDestinationFinalize(target) else { return nil }
        return data as Data
    }
}
