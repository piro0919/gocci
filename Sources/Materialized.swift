import FileProvider
import Foundation
import os

private let materializedLogger = Logger(subsystem: "io.kkweb.gocci", category: "materialized")

// 手元に降りている実体を数える。
//
// フォルダを歩いて数えるのは無理だった。まだ開いていない場所は一覧を Drive に取りに行くので、
// 90秒でフォルダ 137 個までしか進まない（2026-08-17 実測）。Drive 全体なら何時間もかかる。
//
// macOS は「今どれが手元にあるか」を自分で持っていて、`enumeratorForMaterializedItems` で
// 返してくれる（`NSFileProviderManager.h` 322行）。Drive には行かない。
//
// ただしこの口が返すのは、どれが手元にあるかだけ。`documentSize` は全件 `nil` で、
// 種別も `public.item` までしか入っていない（2026-08-17 実測）。大きさと日付は、
// 識別子から実ファイルの場所を貰って、そこから読む。

/// 手元にある1件。捨てる順を決めるのに使うので、最後に触った日も持つ
struct MaterializedItem {
    let identifier: NSFileProviderItemIdentifier
    let filename: String
    /// ディスクを実際に食っている量。穴あきで置かれることがあるので、見かけの長さではない
    let bytes: Int64
    let used: Date
}

enum Materialized {
    /// 手元にあるものを全部数える。フォルダは大きさを持たないので数えない
    static func list(
        in domain: NSFileProviderDomain, completion: @escaping ([MaterializedItem]) -> Void
    ) {
        guard let manager = NSFileProviderManager(for: domain) else {
            return completion([])
        }

        let enumerator = manager.enumeratorForMaterializedItems()
        let collector = Collector { identifiers in
            enumerator.invalidate()
            measure(identifiers, with: manager, completion: completion)
        }
        // 始めの頁は `NSData new` を渡す決まり（同ヘッダ 308-311行）。
        // 名前順・日付順の指定は効かない
        enumerator.enumerateItems(for: collector, startingAt: NSFileProviderPage(Data()))
    }

    /// 合計と件数。表示だけならこちらで足りる
    static func total(in domain: NSFileProviderDomain, completion: @escaping (Int64, Int) -> Void) {
        list(in: domain) { items in
            completion(items.reduce(0) { $0 + $1.bytes }, items.count)
        }
    }

    /// 識別子を1件ずつ実ファイルに引き当てて、大きさと日付を読む。
    /// 場所を貰うのは1件ごとの往復になるので、件数が増えるとここが時間を食う
    private static func measure(
        _ found: [(NSFileProviderItemIdentifier, String)], with manager: NSFileProviderManager,
        completion: @escaping ([MaterializedItem]) -> Void
    ) {
        let group = DispatchGroup()
        let lock = NSLock()
        var items: [MaterializedItem] = []

        for (identifier, filename) in found {
            group.enter()
            manager.getUserVisibleURL(for: identifier) { url, error in
                defer { group.leave() }

                guard let url else {
                    if let error {
                        materializedLogger.error(
                            "場所が分からなかった: \(filename, privacy: .public) \(error.localizedDescription, privacy: .public)")
                    }
                    return
                }
                // 場所を貰うと、そのファイルへの許しが一時的に開く。閉じ忘れると溜まる
                let opened = url.startAccessingSecurityScopedResource()
                defer { if opened { url.stopAccessingSecurityScopedResource() } }

                guard
                    let values = try? url.resourceValues(forKeys: [
                        .totalFileAllocatedSizeKey, .contentAccessDateKey, .contentModificationDateKey,
                    ]), let bytes = values.totalFileAllocatedSize, bytes > 0
                else { return }

                let used =
                    values.contentAccessDate ?? values.contentModificationDate ?? .distantPast
                lock.lock()
                items.append(
                    MaterializedItem(
                        identifier: identifier, filename: filename, bytes: Int64(bytes), used: used))
                lock.unlock()
            }
        }

        group.notify(queue: .global()) { completion(items) }
    }

    /// 受け取り係。頁が続く限り集め、終わったら一度だけ返す
    private final class Collector: NSObject, NSFileProviderEnumerationObserver {
        private var found: [(NSFileProviderItemIdentifier, String)] = []
        private let finish: ([(NSFileProviderItemIdentifier, String)]) -> Void
        private var finished = false

        init(finish: @escaping ([(NSFileProviderItemIdentifier, String)]) -> Void) {
            self.finish = finish
        }

        func didEnumerate(_ enumerated: [NSFileProviderItemProtocol]) {
            for item in enumerated where !isFolder(item) {
                found.append((item.itemIdentifier, item.filename))
            }
        }

        func finishEnumerating(upTo page: NSFileProviderPage?) {
            guard !finished else { return }
            finished = true
            finish(found)
        }

        func finishEnumeratingWithError(_ error: any Error) {
            guard !finished else { return }
            finished = true
            materializedLogger.error(
                "手元にあるものを数えられなかった: \(error.localizedDescription, privacy: .public)")
            finish(found)
        }

        private func isFolder(_ item: NSFileProviderItemProtocol) -> Bool {
            item.contentType?.conforms(to: .folder) ?? false
        }
    }
}
