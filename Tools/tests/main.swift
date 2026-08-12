import Foundation

// 計算の間違いを捕まえる試験。
//
//   ./test.sh
//
// 実機には触らない。マウントもしないし、設定も書き換えない。ここで見るのは、
// 手元で実際に踏んだ間違いばかりで、どれも「値の出し方」を誤ったことが原因だった。

var failures = 0

func check(_ name: String, _ actual: some Equatable, _ expected: some Equatable) {
    if "\(actual)" == "\(expected)" {
        print("  ✓ \(name)")
    } else {
        print("  ✗ \(name)\n      期待: \(expected)\n      実際: \(actual)")
        failures += 1
    }
}

func group(_ name: String, _ body: () -> Void) {
    print("\n\(name)")
    body()
}

group("キャッシュ先を決めるときに見る場所") {
    check(
        "マウント先ではなく、その親を見る", Paths.cacheParent(of: "/Volumes/HIKSEMI/GoogleDrive"),
        "/Volumes/HIKSEMI")
    check("末尾の斜線があっても同じ", Paths.cacheParent(of: "/Volumes/HIKSEMI/GoogleDrive/"), "/Volumes/HIKSEMI")
    check("内蔵でも同じ", Paths.cacheParent(of: "/Users/piro/GocciHome"), "/Users/piro")
}

// MARK: - 落ちてきた割合


group("落ちてきた割合") {
    check("全部あれば 100", Paths.percentage(size: 100, ranges: [(0, 100)]), 100)
    check("何も無ければ 0", Paths.percentage(size: 100, ranges: []), 0)
    check("途中まで", Paths.percentage(size: 100, ranges: [(0, 26)]), 26)
    check("飛び飛びでも足す", Paths.percentage(size: 100, ranges: [(0, 10), (50, 10)]), 20)
    check("重なっている範囲を数えすぎない", Paths.percentage(size: 100, ranges: [(0, 60), (40, 60)]), 100)
    check("大きさ 0 のファイルは手元にあるものとして扱う", Paths.percentage(size: 0, ranges: []), 100)
}

group("欠けている最初の位置") {
    check("全部あれば無し", Paths.firstGap(size: 100, ranges: [(0, 100)]), Int64?.none)
    check("何も無ければ先頭", Paths.firstGap(size: 100, ranges: []), Optional(Int64(0)))
    check("先頭だけあるなら、その次", Paths.firstGap(size: 100, ranges: [(0, 30)]), Optional(Int64(30)))
    check("途中に穴があるなら、その手前", Paths.firstGap(size: 100, ranges: [(0, 30), (50, 50)]), Optional(Int64(30)))
    check("後ろだけあるなら先頭", Paths.firstGap(size: 100, ranges: [(50, 50)]), Optional(Int64(0)))
}

// MARK: - バッジの段


group("バッジの段") {
    check("47% は 40 の段", Paths.step(47), 40)
    check("97% は 90 の段。100 にはしない", Paths.step(97), 90)
    check("5% は 0 の段。ほとんど無いものを取得中とは見せない", Paths.step(5), 0)
    check("100% はそのまま", Paths.step(100), 100)
}

// MARK: - キャッシュの置き場所


group("キャッシュの置き場所を探す") {
    check("指紋つきの名前を拾う", Paths.isCacheRoot("gdrive{a4x2W}", remote: "gdrive"), true)
    check("指紋なしも拾う", Paths.isCacheRoot("gdrive", remote: "gdrive"), true)
    check("別のリモートは拾わない", Paths.isCacheRoot("dropbox{x}", remote: "gdrive"), false)
    check("前方一致だけで拾わない", Paths.isCacheRoot("gdrive2", remote: "gdrive"), false)
}

// MARK: - マウント先の相対の道


group("マウント先から見た道") {
    check(
        "中のファイル", Paths.relative("/Volumes/HIKSEMI/GoogleDrive/Movies/a.mp4", mountPoint: "/Volumes/HIKSEMI/GoogleDrive"),
        Optional("Movies/a.mp4"))
    check(
        "外のファイルは相手にしない", Paths.relative("/Users/piro/a.mp4", mountPoint: "/Volumes/HIKSEMI/GoogleDrive"),
        String?.none)
    check(
        "名前が途中まで同じだけの場所も相手にしない",
        Paths.relative("/Volumes/HIKSEMI/GoogleDriveOld/a.mp4", mountPoint: "/Volumes/HIKSEMI/GoogleDrive"),
        String?.none)
    check(
        "濁点の表し方を揃える",
        Paths.relative(
            "/Volumes/HIKSEMI/GoogleDrive/" + "が".decomposedStringWithCanonicalMapping + ".txt",
            mountPoint: "/Volumes/HIKSEMI/GoogleDrive"),
        Optional("が.txt"))
}

print("")
if failures == 0 {
    print("全部通りました")
} else {
    print("\(failures) 件落ちました")
    exit(1)
}
