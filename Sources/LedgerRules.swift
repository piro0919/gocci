import Foundation

/// 台帳の判断のうち、拡張の外でも確かめられる部分。
///
/// 拡張の中は試験から触れないので、判断だけをここに切り出してアプリにも組み込む。
/// `./Gocci --selftest` がここを確かめる
enum LedgerRules {

    /// 見て回って一覧に無かったものを、消えたとみなしてよいか。
    ///
    /// 一覧を取りに行く前に覚えていた道と、今の台帳の道が同じときだけ消えたとみなす。
    /// 一覧を待つあいだに Finder から動かされたものは、もう新しい道で覚え直されている。
    /// それを ID ごと忘れると、動かした先のフォルダが台帳から落ち、中身の親が辿れなくなって
    /// Finder の直下に散らばった（2026-11-27 実測。7フォルダを動かして 543 件）。
    ///
    /// もう台帳に無いものは、別の道で忘れられたあと。消えたと伝え直しても害は無い
    static func isGone(rememberedPath: String, currentPath: String?) -> Bool {
        guard let currentPath else { return true }
        return currentPath == rememberedPath
    }

    /// 親の道。根の直下なら空。
    ///
    /// `NSString.deletingLastPathComponent` は1件ごとに橋渡しが挟まり、29万件で 1.7 秒かかった
    /// （2026-11-27 実測）。区切りは `/` だけなので、自分で切る
    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// 親を辿って根まで行けないものと、辿るのが途切れた道。
    ///
    /// 親の道が台帳に無いと、`parentItemIdentifier` は根を返すしかなく、Finder の直下に
    /// 散らばって見える。途切れた道（`missing`）を Drive に確かめて、あれば覚え直せば治る。
    /// 無ければ、その下は古い道のまま残った覚え（`lost`）なので片付ける
    /// 親を辿って根まで行けないものごとの、根に一番近い途切れた道。
    ///
    /// 親の道が台帳に無いと、`parentItemIdentifier` は根を返すしかなく、Finder の直下に
    /// 散らばって見える。途切れた道を Drive に確かめて、あれば覚え直せば治る。
    /// 無ければ、その下は古い道のまま残った覚えなので片付ける
    static func orphanGaps(_ paths: [String: String]) -> [String: String] {
        let known = Set(paths.values)
        // 道ごとに、根へ向かって最初に途切れた親。辿り着けるなら nil
        var breakAt: [String: String?] = [:]

        func firstMissing(_ path: String) -> String? {
            if let decided = breakAt[path] { return decided }
            // 親を辿る道を先に集め、根の側から答えを決める。再帰にすると深い道で積み上がる
            var chain: [String] = []
            var current = path
            var answer: String?
            while true {
                if let decided = breakAt[current] {
                    answer = decided
                    break
                }
                chain.append(current)
                let up = parent(of: current)
                if up.isEmpty {
                    answer = nil
                    break
                }
                guard known.contains(up) else {
                    answer = up
                    break
                }
                current = up
            }
            for step in chain { breakAt[step] = .some(answer) }
            return answer
        }

        var lost = [String: String]()
        for (id, path) in paths {
            guard let gap = firstMissing(path) else { continue }
            lost[id] = gap
        }
        return lost
    }

    /// 親を辿って根まで行けないものと、辿るのが途切れた道
    static func orphans(_ paths: [String: String]) -> (lost: Set<String>, missing: Set<String>) {
        let gaps = orphanGaps(paths)
        return (Set(gaps.keys), Set(gaps.values))
    }

    /// 片付けてよい覚え。途切れた道が Drive に無いと確かめられたものの下だけ。
    ///
    /// 確かめられなかった途切れ（訊く数の上限を超えた、Drive が混んでいて断られた）の下まで
    /// 忘れると、Drive にあるものが Finder から消える。そこは次の見回りでもう一度確かめる
    static func lost(_ paths: [String: String], under gone: Set<String>) -> Set<String> {
        Set(orphanGaps(paths).filter { gone.contains($0.value) }.keys)
    }

    /// 確かめに行く途切れた道を選ぶ。浅いものから、決まった数まで。
    ///
    /// 浅い道を一つ治すと、その下の途切れはまとめて消えることが多い
    static func pick(_ missing: Set<String>, limit: Int) -> [String] {
        Array(
            missing.sorted {
                let a = $0.split(separator: "/").count
                let b = $1.split(separator: "/").count
                return a == b ? $0 < $1 : a < b
            }.prefix(limit))
    }

    /// 控えに書き出すときに混ぜる。
    ///
    /// 自分が変えたものだけを上に重ねる。覚えている全部を重ねると、古い覚えを持ったまま
    /// 起きている拡張が、別の拡張の付け替えた道を古い道で書き戻してしまう
    /// （2026-11-27 実測。動かしたフォルダの中身 114 件が元の道に戻った）
    static func merge<Value>(
        disk: [String: Value], mine: [String: Value], dropped: Set<String>
    ) -> [String: Value] {
        var merged = disk
        for (id, value) in mine { merged[id] = value }
        for id in dropped { merged.removeValue(forKey: id) }
        return merged
    }

    /// 動かしたフォルダの道を、鍵にした辞書ごと付け替える。そのフォルダ自身も、中のものも。
    ///
    /// 見て回る先（最後に並べた時刻）を古い道のまま残すと、次の見回りで古い道を一覧しに行く。
    /// rclone は動かしたあとも古い道を動かした先のフォルダとして覚えていて、一覧が通ってしまう。
    /// 中身が古い道で覚え直され、親が辿れなくなって Finder から消えた
    /// （2026-11-27 実測。動かした1分後に中身の4件が消え、Drive には残っていた）
    static func rebaseKeys<Value>(_ dictionary: [String: Value], from old: String, to new: String)
        -> [String: Value]
    {
        let prefix = old + "/"
        var result: [String: Value] = [:]
        for (key, value) in dictionary {
            if key == old {
                result[new] = value
            } else if key.hasPrefix(prefix) {
                result[new + "/" + key.dropFirst(prefix.count)] = value
            } else {
                result[key] = value
            }
        }
        return result
    }

    /// 作ったものに付ける識別子。Drive の ID があればそれ、無ければ道を借りる。
    ///
    /// rclone の一件は、ID を返さない置き場だと ID の代わりに名前が入る
    /// （`RcClient.entry(from:)`）。名前は同じフォルダの中でしか一意でないので、そのときは道にする
    static func createdIdentifier(driveID: String, name: String, path: String) -> String {
        driveID.isEmpty || driveID == name ? path : driveID
    }
}
