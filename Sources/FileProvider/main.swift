import FileProvider
import Foundation
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
// 識別子はマウント先から見た道そのものにしてある。Drive の ID を使う手もあるが、
// 道が分かればそのまま rclone に渡せる。根だけ `.rootContainer` で特別扱い。

/// 道と識別子の行き来
enum Route {
    static func path(of identifier: NSFileProviderItemIdentifier) -> String {
        identifier == .rootContainer ? "" : identifier.rawValue
    }

    static func identifier(of path: String) -> NSFileProviderItemIdentifier {
        path.isEmpty ? .rootContainer : NSFileProviderItemIdentifier(path)
    }

    static func parent(of path: String) -> NSFileProviderItemIdentifier {
        identifier(of: (path as NSString).deletingLastPathComponent)
    }
}

final class Item: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let isDirectory: Bool
    let bytes: Int64
    let modified: Date
    /// 中身が変わったかの見分け。大きさと時刻が変わっていなければ同じものとして扱う
    let signature: String

    init(path: String, isDirectory: Bool, bytes: Int64, modified: Date) {
        self.itemIdentifier = Route.identifier(of: path)
        self.parentItemIdentifier = Route.parent(of: path)
        self.filename = (path as NSString).lastPathComponent
        self.isDirectory = isDirectory
        self.bytes = bytes
        self.modified = modified
        self.signature = "\(bytes)-\(modified.timeIntervalSince1970)"
    }

    var contentType: UTType {
        if isDirectory { return .folder }
        let suffix = (filename as NSString).pathExtension
        return UTType(filenameExtension: suffix) ?? .data
    }

    var documentSize: NSNumber? { isDirectory ? nil : NSNumber(value: bytes) }
    var contentModificationDate: Date? { modified }
    var creationDate: Date? { modified }

    var capabilities: NSFileProviderItemCapabilities {
        isDirectory ? [.allowsReading, .allowsContentEnumerating] : [.allowsReading]
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
    var capabilities: NSFileProviderItemCapabilities { [.allowsReading, .allowsContentEnumerating] }
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

/// 列挙で分かったことを覚えておく。`item()` は列挙と食い違ってはいけない
final class Ledger {
    static let shared = Ledger()
    private var entries: [String: Item] = [:]
    private let lock = NSLock()

    func remember(_ item: Item) {
        lock.lock(); defer { lock.unlock() }
        entries[item.itemIdentifier.rawValue] = item
    }

    func recall(_ identifier: NSFileProviderItemIdentifier) -> Item? {
        lock.lock(); defer { lock.unlock() }
        return entries[identifier.rawValue]
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
        // ゴミ箱の中身は持たない。空だと答える
        guard container != .trashContainer else {
            observer.finishEnumerating(upTo: nil)
            return
        }

        guard let client else {
            logger.error("rclone の口が分からない")
            observer.finishEnumeratingWithError(NSFileProviderError(.serverUnreachable))
            return
        }

        let base = Route.path(of: container)
        client.list(base) { result in
            switch result {
            case .failure(let error):
                logger.error("一覧を取れなかった: \(error.localizedDescription, privacy: .public)")
                observer.finishEnumeratingWithError(NSFileProviderError(.serverUnreachable))
            case .success(let entries):
                let items = entries.map { entry -> Item in
                    let path = base.isEmpty ? entry.name : "\(base)/\(entry.name)"
                    let item = Item(
                        path: path, isDirectory: entry.isDirectory, bytes: entry.size,
                        modified: entry.modified)
                    Ledger.shared.remember(item)
                    return item
                }
                logger.info("並べた: \(base, privacy: .public) の \(items.count) 件")
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            }
        }
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor
    ) {
        // Drive 側の変化を拾う道はまだ入れていない。開き直せば読み直される
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("1".utf8)))
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
        logger.info("拡張が起きた")
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
                completionHandler(nil, NSFileProviderError(.noSuchItem))
            }
        }
        return Progress()
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

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(item.filename)
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        client.copy(path: itemIdentifier.rawValue, to: destination) { result in
            progress.completedUnitCount = 1
            switch result {
            case .failure(let error):
                logger.error("取れなかった: \(error.localizedDescription, privacy: .public)")
                completionHandler(nil, nil, NSFileProviderError(.serverUnreachable))
            case .success:
                logger.info("渡した: \(itemIdentifier.rawValue, privacy: .public)")
                completionHandler(destination, item, nil)
            }
        }
        return progress
    }

    // MARK: - 書き込み

    // まだ受けない。読み取り側が固まるまでは、頼まれても断る。
    // ただし断り方は選ぶ。macOS はゴミ箱を作ろうとしてここへ来るので、
    // 一律で失敗を返すと列挙まで辿り着かない

    func createItem(
        basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
        options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        // ゴミ箱の下は素通しにする。中身を持たないので、頼まれた通りを返しておく
        if itemTemplate.parentItemIdentifier == .trashContainer {
            completionHandler(itemTemplate, [], false, nil)
            return Progress()
        }

        completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
        return Progress()
    }

    func modifyItem(
        _ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields, contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
        return Progress()
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        completionHandler(NSFileProviderError(.noSuchItem))
        return Progress()
    }

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        Enumerator(containerItemIdentifier, client: client)
    }
}
