import FileProvider
import Foundation

/// 画面を出さずに、判断だけを確かめる。`./Gocci --selftest` で走る。
/// rclone にも Drive にも繋がないし、手元の実体にも触らない。
/// 組み上がったものの検査は `./test.sh` のほうにある。
@MainActor
enum SelfTest {

    private static var failures = 0

    static func run() -> Int32 {
        failures = 0

        // rclone が返す一件を読む
        do {
            let raw: [String: Any] = [
                "Name": "報告書.pdf", "Size": NSNumber(value: 12345),
                "IsDir": false, "ModTime": "2026-08-16T12:34:56.789Z", "ID": "abc123",
            ]
            let entry = RcClient.entry(from: raw)
            check(entry?.name == "報告書.pdf", "名前を読む")
            check(entry?.size == 12345, "大きさを読む")
            check(entry?.isDirectory == false, "フォルダかどうかを読む")
            check(entry?.id == "abc123", "Drive 側の識別子を読む")

            // 名前が無ければ何も作れない
            check(
                RcClient.entry(from: ["Size": NSNumber(value: 1)]) == nil,
                "名前が無ければ読まない")

            // 識別子を返さない置き場があるので、そのときは名前で代える
            check(
                RcClient.entry(from: ["Name": "no-id.txt"])?.id == "no-id.txt",
                "識別子が無ければ名前で代える")
            check(RcClient.entry(from: ["Name": "x"])?.size == 0, "大きさが無ければ 0")
            check(
                RcClient.entry(from: ["Name": "x"])?.isDirectory == false,
                "種別が無ければファイル扱い")
        }

        // 更新時刻。小数秒が付くかどうかは元の置き場による
        do {
            check(RcClient.timestamp("2026-08-16T12:34:56.789Z") != nil, "小数秒つきを読む")
            check(RcClient.timestamp("2026-08-16T12:34:56Z") != nil, "小数秒なしも読む")
            check(
                RcClient.timestamp("2026-08-16T12:34:56.789Z")
                    == RcClient.timestamp("2026-08-16T12:34:56Z")?.addingTimeInterval(0.789),
                "小数秒ぶんだけ差が出る")
            check(RcClient.timestamp("") == nil, "空文字は読めない")
            check(RcClient.timestamp("2026-08-16") == nil, "日付だけでは読めない")

            // 読めなかったときは 1970 に落として、一番古いものとして扱う
            check(
                RcClient.entry(from: ["Name": "x", "ModTime": "こわれた"])?.modified
                    == Date(timeIntervalSince1970: 0),
                "読めない時刻は 1970 になる")
        }

        // 上限を超えた分として捨てる相手を選ぶ
        do {
            let base = Date(timeIntervalSince1970: 1_800_000_000)
            func item(_ name: String, _ bytes: Int64, minutesAgo: Int) -> MaterializedItem {
                MaterializedItem(
                    identifier: NSFileProviderItemIdentifier(name), filename: name,
                    bytes: bytes, downloaded: base.addingTimeInterval(-Double(minutesAgo) * 60))
            }

            let items = [
                item("new.bin", 100, minutesAgo: 1),
                item("old.bin", 100, minutesAgo: 100),
                item("middle.bin", 100, minutesAgo: 50),
            ]

            check(
                Materialized.overflow(items: items, limit: 300).isEmpty,
                "上限に収まっていれば誰も捨てない")
            check(
                Materialized.overflow(items: items, limit: 1000).isEmpty,
                "上限が余っていても捨てない")

            // 300 のうち 250 まで。超過は 50 なので、一番古いものひとつで足りる
            let one = Materialized.overflow(items: items, limit: 250)
            check(one.map(\.filename) == ["old.bin"], "超過が埋まる分だけ捨てる")

            // 超過が 150 なら、古い順にふたつ
            let two = Materialized.overflow(items: items, limit: 150)
            check(two.map(\.filename) == ["old.bin", "middle.bin"], "足りなければ次に古いものへ")

            // 同じ時刻なら大きいものから。捨てる件数が少なくて済む
            let sameTime = [
                item("small.bin", 10, minutesAgo: 10),
                item("large.bin", 200, minutesAgo: 10),
            ]
            check(
                Materialized.overflow(items: sameTime, limit: 100).map(\.filename)
                    == ["large.bin"], "同じ時刻なら大きいものを先に捨てる")

            check(
                Materialized.overflow(items: items, limit: 0).isEmpty,
                "上限が 0 なら何もしない")
            check(
                Materialized.overflow(items: [], limit: 100).isEmpty,
                "手元に何も無ければ何もしない")
        }

        // 動かすときの頼み方。フォルダを operations/movefile に渡すと断られる
        do {
            let folder = RcClient.moveRequest(
                remote: "gdrive:", from: "書類/旧", to: "書類/新", isDirectory: true)
            check(folder.route == "sync/move", "フォルダは sync/move で動かす")
            check(folder.body["srcFs"] as? String == "gdrive:書類/旧", "フォルダの元は置き場ごと渡す")
            check(folder.body["dstFs"] as? String == "gdrive:書類/新", "フォルダの先も置き場ごと渡す")
            check(folder.body["srcRemote"] == nil, "フォルダにはファイル用の引数を付けない")
            check(folder.body["deleteEmptySrcDirs"] as? Bool == true, "空になった元フォルダを残さない")

            let file = RcClient.moveRequest(
                remote: "gdrive:", from: "a/b.txt", to: "c/b.txt", isDirectory: false)
            check(file.route == "operations/movefile", "ファイルは operations/movefile で動かす")
            check(file.body["srcFs"] as? String == "gdrive:", "ファイルの元は根を渡す")
            check(file.body["srcRemote"] as? String == "a/b.txt", "ファイルの元は道で渡す")
            check(file.body["dstRemote"] as? String == "c/b.txt", "ファイルの先は道で渡す")
        }

        // 失敗の見分け。File Provider へ返す誤りがここで決まる
        do {
            typealias F = RcClient.Failure
            check(RcClient.classify(URLError(.cannotConnectToHost)) == .network, "rcd に届かなければ繋がらない扱い")
            check(RcClient.classify(F.noAnswer) == .network, "返事が無ければ繋がらない扱い")
            check(
                RcClient.classify(F.rejected("unauthorized", status: 401)) == .network,
                "rcd の合言葉違いは控えが古いだけ")
            check(
                RcClient.classify(F.rejected("object not found", status: 404)) == .notFound,
                "404 は無い")
            check(
                RcClient.classify(F.rejected("error in ListJSON: directory not found", status: 500))
                    == .notFound,
                "文で not found と言えば無い")
            check(
                RcClient.classify(
                    F.rejected(
                        "couldn't fetch token: invalid_grant: maybe token expired? - try refreshing",
                        status: 500)) == .notAuthenticated,
                "合鍵切れは認証の誤り")
            check(
                RcClient.classify(
                    F.rejected(
                        "googleapi: Error 403: The user's Drive storage quota has been exceeded., storageQuotaExceeded",
                        status: 500)) == .quota,
                "容量切れは容量の誤り")
            check(
                RcClient.classify(
                    F.rejected(
                        "googleapi: Error 403: User Rate Limit Exceeded, userRateLimitExceeded", status: 500))
                    == .other,
                "回数の上限は容量の誤りにしない")
            check(
                RcClient.classify(F.rejected("directory already exists", status: 500)) == .collision,
                "既にあれば名前の衝突")
            check(
                RcClient.classify(F.rejected("is a directory not a file", status: 500)) == .other,
                "見分けのつかないものはその他")
        }

        // 別の端末での書き換えを見分ける
        do {
            let stamp = Date(timeIntervalSince1970: 1_800_000_000.4)
            let entry = RcClient.Entry(name: "a.txt", size: 10, isDirectory: false, modified: stamp, id: "x")
            let same = Data(RcClient.signature(bytes: 10, modified: stamp).utf8)
            check(RcClient.signature(bytes: 10, modified: stamp) == "10-1800000000", "版は大きさと秒")
            check(!RcClient.hasConflict(base: same, current: entry), "同じ版なら衝突しない")
            check(
                RcClient.hasConflict(base: Data("10-1799999000".utf8), current: entry),
                "時刻が違えば衝突")
            check(RcClient.hasConflict(base: Data("9-1800000000".utf8), current: entry), "大きさが違えば衝突")
            check(!RcClient.hasConflict(base: Data("9-1".utf8), current: nil), "Drive に無ければ衝突にしない")
            check(!RcClient.hasConflict(base: Data(), current: entry), "元の版が空なら比べない")
            check(
                !RcClient.hasConflict(base: Data([0xff, 0x00]), current: entry),
                "こちらの形でない版は比べない")
            let folder = RcClient.Entry(name: "d", size: -1, isDirectory: true, modified: stamp, id: "d")
            check(!RcClient.hasConflict(base: Data("0-1".utf8), current: folder), "フォルダは比べない")

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let when = calendar.date(
                from: DateComponents(year: 2026, month: 10, day: 1, hour: 14, minute: 0, second: 58))!
            check(
                RcClient.conflictName(for: "報告書.pdf", at: when) == "報告書 (conflict 2026-10-01 140058).pdf",
                "衝突の写しは拡張子の前に印を付ける")
            check(
                RcClient.conflictName(for: "README", at: when) == "README (conflict 2026-10-01 140058)",
                "拡張子が無ければ後ろに付ける")
            check(
                RcClient.conflictName(for: ".zshrc", at: when) == ".zshrc (conflict 2026-10-01 140058)",
                "隠しファイルの名前を拡張子と取り違えない")
            check(
                RcClient.conflictName(for: "a.tar.gz", at: when) == "a.tar (conflict 2026-10-01 140058).gz",
                "拡張子は最後の一つだけ")
        }

        // 台帳。フォルダを動かしたあとに中身が Finder の直下へ散らばった（2026-11-27）
        do {
            // 一覧を待つあいだに動かされたものは、消えたことにしない
            check(
                LedgerRules.isGone(rememberedPath: "Repository", currentPath: "Repository"),
                "道が変わっていなければ消えたとみなす")
            check(
                !LedgerRules.isGone(
                    rememberedPath: "Repository", currentPath: "Development/Repository"),
                "一覧を待つあいだに動かされたものは忘れない")
            check(
                LedgerRules.isGone(rememberedPath: "Repository", currentPath: nil),
                "もう覚えていないものは消えたとみなす")

            // 親を辿って根まで行けないものだけを拾う
            let paths = [
                "dev": "Development",
                "repo": "Development/Repository",
                "pkg": "Development/Repository/app/package.json",  // 親の app が無い
                "lib": "Extension/commit-type/node_modules/glob",  // 古い道のまま残った
                "lic": "Extension/commit-type/node_modules/glob/LICENSE",
                "top": "Movies",
                "deep": "Development/Repository/readme.md",
            ]
            let (lost, missing) = LedgerRules.orphans(paths)
            check(lost == ["pkg", "lib", "lic"], "親の辿れないものを拾う")
            check(!lost.contains("top"), "直下のものは親が要らない")
            check(!lost.contains("deep"), "親を辿れるものは残す")
            check(
                missing == ["Development/Repository/app", "Extension/commit-type/node_modules"],
                "途切れた親の道を、根に一番近い途切れで返す")
            check(LedgerRules.orphans([:]).lost.isEmpty, "空の台帳からは何も拾わない")

            // 片付けるのは、Drive に無いと確かめた途切れの下だけ
            check(
                LedgerRules.lost(paths, under: ["Extension/commit-type/node_modules"]) == ["lib", "lic"],
                "無いと確かめた途切れの下だけを片付ける")
            check(
                LedgerRules.lost(paths, under: []).isEmpty,
                "確かめられなかった途切れの下は残す")

            // 動かした先のフォルダだけが落ちた形。親を覚え直せば、中身は全部辿れる
            var moved = [
                "dev": "Development",
                "a": "Development/Repository/app",
                "b": "Development/Repository/app/package.json",
            ]
            check(
                LedgerRules.orphans(moved).missing == ["Development/Repository"],
                "落ちたのが動かした先のフォルダだけなら、そこを確かめに行く")
            moved["repo"] = "Development/Repository"
            check(LedgerRules.orphans(moved).lost.isEmpty, "親を覚え直せば片付けるものは無い")

            check(LedgerRules.parent(of: "a/b/c.txt") == "a/b", "親の道を切り出す")
            check(LedgerRules.parent(of: "c.txt") == "", "直下なら親は空")
            check(
                LedgerRules.pick(["a/b/c", "x", "a/b", "m/n"], limit: 3) == ["x", "a/b", "m/n"],
                "浅い途切れから確かめに行く")

            // 書き出すときは、自分が変えたものだけを重ねる
            let disk = ["a": "Development/Repository", "b": "Movies", "c": "Comics"]
            let merged = LedgerRules.merge(
                disk: disk, mine: ["b": "Movies 2"], dropped: ["c"])
            check(merged["a"] == "Development/Repository", "自分が触っていない覚えは書き戻さない")
            check(merged["b"] == "Movies 2", "自分が変えたものは重ねる")
            check(merged["c"] == nil, "忘れたものは落とす")

            // 動かしたら、見て回る先も新しい道へ付け替える
            let listed = ["": 1, "Repository": 2, "Repository/gocci": 3, "Repository2": 4]
            let rebased = LedgerRules.rebaseKeys(listed, from: "Repository", to: "Development/Repository")
            check(rebased["Repository"] == nil, "古い道は見て回る先に残さない")
            check(rebased["Repository/gocci"] == nil, "古い道の中も残さない")
            check(rebased["Development/Repository"] == 2, "動かしたフォルダ自身を付け替える")
            check(rebased["Development/Repository/gocci"] == 3, "中のフォルダも付け替える")
            check(rebased["Repository2"] == 4, "名前の頭が同じだけのものは触らない")
            check(rebased[""] == 1, "根はそのまま")

            // 作ったものには、Drive に訊き直した ID を付ける
            check(
                LedgerRules.createdIdentifier(driveID: "1AXhR0lE", name: "sub", path: "x/sub") == "1AXhR0lE",
                "作ったものには Drive の ID を付ける")
            check(
                LedgerRules.createdIdentifier(driveID: "sub", name: "sub", path: "x/sub") == "x/sub",
                "ID が無く名前で代えられていたら道を借りる")
            check(
                LedgerRules.createdIdentifier(driveID: "", name: "sub", path: "x/sub") == "x/sub",
                "ID が空なら道を借りる")
        }

        print(failures == 0 ? "全部通りました" : "\(failures) 件こけました")
        return failures == 0 ? 0 : 1
    }

    private static func check(_ condition: Bool, _ what: String) {
        if condition {
            print("  ok   \(what)")
        } else {
            print("  NG   \(what)")
            failures += 1
        }
    }
}
