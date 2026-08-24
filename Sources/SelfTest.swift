import FileProvider
import Foundation

/// 画面を出さずに、判断だけを確かめる。`./Gocci --selftest` で走る。
/// rclone にも Drive にも繋がないし、手元の実体にも触らない。
/// 組み上がったものの検査は `./test.sh` のほうにある。
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
            check(RcClient.entry(from: ["Size": NSNumber(value: 1)]) == nil,
                  "名前が無ければ読まない")

            // 識別子を返さない置き場があるので、そのときは名前で代える
            check(RcClient.entry(from: ["Name": "no-id.txt"])?.id == "no-id.txt",
                  "識別子が無ければ名前で代える")
            check(RcClient.entry(from: ["Name": "x"])?.size == 0, "大きさが無ければ 0")
            check(RcClient.entry(from: ["Name": "x"])?.isDirectory == false,
                  "種別が無ければファイル扱い")
        }

        // 更新時刻。小数秒が付くかどうかは元の置き場による
        do {
            check(RcClient.timestamp("2026-08-16T12:34:56.789Z") != nil, "小数秒つきを読む")
            check(RcClient.timestamp("2026-08-16T12:34:56Z") != nil, "小数秒なしも読む")
            check(RcClient.timestamp("2026-08-16T12:34:56.789Z")
                    == RcClient.timestamp("2026-08-16T12:34:56Z")?.addingTimeInterval(0.789),
                  "小数秒ぶんだけ差が出る")
            check(RcClient.timestamp("") == nil, "空文字は読めない")
            check(RcClient.timestamp("2026-08-16") == nil, "日付だけでは読めない")

            // 読めなかったときは 1970 に落として、一番古いものとして扱う
            check(RcClient.entry(from: ["Name": "x", "ModTime": "こわれた"])?.modified
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

            check(Materialized.overflow(items: items, limit: 300).isEmpty,
                  "上限に収まっていれば誰も捨てない")
            check(Materialized.overflow(items: items, limit: 1000).isEmpty,
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
            check(Materialized.overflow(items: sameTime, limit: 100).map(\.filename)
                    == ["large.bin"], "同じ時刻なら大きいものを先に捨てる")

            check(Materialized.overflow(items: items, limit: 0).isEmpty,
                  "上限が 0 なら何もしない")
            check(Materialized.overflow(items: [], limit: 100).isEmpty,
                  "手元に何も無ければ何もしない")
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
