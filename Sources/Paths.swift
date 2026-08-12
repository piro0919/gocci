import Foundation

// 場所と割合の計算。
//
// アプリ本体・Finder 拡張・試験の3つから使う。ここに集めてあるのは、手元で実際に
// 間違えた計算ばかり。書き写しを増やすと、直したはずの間違いが片方に残る。

enum Paths {
    /// キャッシュ先を決めるときに見る場所。
    ///
    /// マウント先そのものではなく、その置き場所から数える。繋がった後のマウント先は
    /// それ自体が別のボリュームになり、自分の中を指してしまう
    static func cacheParent(of mountPoint: String) -> String {
        ((mountPoint as NSString).standardizingPath as NSString).deletingLastPathComponent
    }

    /// キャッシュの置き場所かどうか。
    ///
    /// rclone は `vfs/gdrive{a4x2W}` のように、リモート名の後ろへ設定の指紋を付ける。
    /// 名前を決め打ちにすると空振りする
    static func isCacheRoot(_ name: String, remote: String) -> Bool {
        name == remote || name.hasPrefix("\(remote){")
    }

    /// マウント先から見た相対の道。外の場所なら nil。
    ///
    /// 濁点の表し方が場所によって違うことがあるので、比べる前に揃える
    static func relative(_ path: String, mountPoint: String) -> String? {
        let path = (path as NSString).standardizingPath
        guard !mountPoint.isEmpty, path.hasPrefix(mountPoint + "/") else { return nil }
        return String(path.dropFirst(mountPoint.count + 1)).precomposedStringWithCanonicalMapping
    }

    /// 実際に手元にある量。範囲が重なっていても数えすぎない
    static func coveredBytes(ranges: [(pos: Int64, size: Int64)]) -> Int64 {
        let spans = ranges.map { ($0.pos, $0.pos + $0.size) }.sorted { $0.0 < $1.0 }
        var merged: [(Int64, Int64)] = []
        for span in spans {
            if let last = merged.last, span.0 <= last.1 {
                merged[merged.count - 1].1 = max(last.1, span.1)
            } else {
                merged.append(span)
            }
        }
        return merged.reduce(Int64(0)) { $0 + ($1.1 - $1.0) }
    }

    /// 落ちてきた割合。rclone の控えにある大きさと、持っている範囲から出す。
    ///
    /// 範囲が重なっていても数えすぎないよう、まとめてから足す
    static func percentage(size: Int64, ranges: [(pos: Int64, size: Int64)]) -> Int {
        guard size > 0 else { return 100 }
        return Int(min(100, coveredBytes(ranges: ranges) * 100 / size))
    }

    /// 欠けている最初の位置。全部あるなら nil。
    ///
    /// 続きを取りにいくときは、ここを読ませる。先頭を読んでも、そこが既に手元にあれば
    /// rclone は何も取りに行かない（先読みは「読んだ位置より先」を取る仕掛けのため）
    static func firstGap(size: Int64, ranges: [(pos: Int64, size: Int64)]) -> Int64? {
        guard size > 0 else { return nil }

        let spans = ranges.map { ($0.pos, $0.pos + $0.size) }.sorted { $0.0 < $1.0 }
        var covered: Int64 = 0
        for span in spans {
            if span.0 > covered { return covered }
            covered = max(covered, span.1)
            if covered >= size { return nil }
        }
        return covered < size ? covered : nil
    }

    /// ここまで読まれていれば「使った」と見なす量。
    ///
    /// Finder はサムネイルのために動画の先頭を数 MB 読む。それを「使った」と扱うと、
    /// 眺めただけのファイルが取得中に見えるし、続きまで取りにいってしまう
    static let usedThreshold: Int64 = 32_000_000

    /// バッジに出す割合。使ったと言えない量しか無いものは、クラウドのみとして見せる
    static func badgePercent(percent: Int, held: Int64) -> Int {
        if percent >= 100 { return 100 }
        return held >= usedThreshold ? percent : 0
    }

    /// バッジの段。10 きざみ。切り上げない。9割方まで来ていないのに「9割」とは出さない
    static func step(_ percent: Int) -> Int {
        max(0, min(100, percent / 10 * 10))
    }
}
