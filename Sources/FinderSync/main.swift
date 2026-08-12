import AppKit
import FinderSync
import OSLog

/// 拡張の中は外から見えない。何を読んで何を描いたかを記録に残す
let logger = Logger(subsystem: "io.kkweb.gocci", category: "finder")

// Finder に「実体が手元にあるか」を出す拡張。
//
// この拡張はサンドボックスの中で動く。サンドボックスは Finder 拡張の必須条件で、
// 付けずに署名すると、そもそも一覧に載らず有効にできない（2026-08-12 に確認）。
//
// 中からは設定もキャッシュも読めないので、判定はしない。アプリが自分のコンテナへ
// 書いた一覧（state.json）を読むだけにしてある。
//
// 名前を GocciFinderSync にしてあるのは、FinderSync という枠組みの名前と衝突させないため。

final class GocciFinderSync: FIFinderSync {
    /// 落ちてきた割合をどう見せるか。段ごとに別の印として登録する。
    ///
    /// Finder のバッジは絵の差し替えなので、段の数だけ絵を作って持たせる。
    /// 10 きざみにしてあるのは、円グラフで見て違いが分かる限界がその辺りのため
    private struct Step {
        let percent: Int

        static let all = stride(from: 0, through: 100, by: 10).map { Step(percent: $0) }

        /// この割合はどの段か。切り上げない。9割方まで来ていないのに「9割」とは出さない
        static func of(_ percent: Int) -> Step {
            Step(percent: Paths.step(percent))
        }

        var identifier: String { "io.kkweb.gocci.step\(percent)" }

        var label: String {
            switch percent {
            case 0: return "クラウドのみ"
            case 100: return "手元にある"
            default: return "取得中 \(percent)%"
            }
        }
    }

    private var mountPoint = ""
    /// 道 → 落ちてきた割合
    private var progress: [String: Int] = [:]
    /// 一度でも尋ねられた道。Finder は一度描いた印を訊き直さないので、
    /// 一覧が変わったらこちらから塗り直す
    private var known: Set<URL> = []
    private var stateStamp: Date?

    override init() {
        super.init()

        let controller = FIFinderSyncController.default()
        for step in Step.all {
            controller.setBadgeImage(
                Self.badge(step), label: step.label, forBadgeIdentifier: step.identifier)
        }

        load()

        // 一覧はアプリが書き換える。落ちてくれば印も変わるので、様子を見に行く
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.load()
        }
    }

    override func requestBadgeIdentifier(for url: URL) {
        known.insert(url)
        apply(to: url)
    }

    private func apply(to url: URL) {
        guard let relative = Paths.relative(url.path, mountPoint: mountPoint) else { return }

        // フォルダには印を付けない。実体が手元にあるかという話が当てはまらない
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            return
        }

        let step = Step.of(progress[relative] ?? 0)
        FIFinderSyncController.default().setBadgeIdentifier(step.identifier, for: url)
    }

    /// アプリが書いた一覧を読む。変わっていなければ何もしない
    private func load() {
        guard
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        else { return }

        let file = support.appendingPathComponent("state.json")
        let stamp =
            (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        if let stamp, let stateStamp, stamp == stateStamp { return }
        stateStamp = stamp

        guard let data = try? Data(contentsOf: file),
            let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        let mountPoint = (state["mountPoint"] as? String) ?? ""
        let progress = (state["progress"] as? [String: Int]) ?? [:]
        guard mountPoint != self.mountPoint || progress != self.progress else { return }

        // 見張る場所を入れ直すのは、行き先が変わったときだけ。
        // 一覧が変わるたびに入れ直すと、そのたびに Finder 側の登録がやり直しになり、
        // 印を訊きに来なくなる（先読みを入れて割合が数秒ごとに動くようになって発覚した）
        if mountPoint != self.mountPoint {
            known.removeAll()
            self.mountPoint = mountPoint
            FIFinderSyncController.default().directoryURLs =
                mountPoint.isEmpty ? [] : [URL(fileURLWithPath: mountPoint)]
        }
        self.progress = progress

        logger.info(
            "一覧を読み直した: \(progress.count) 件 / 塗り直す \(self.known.count) 件")

        // 既に描かれている印を塗り直す
        for url in known { apply(to: url) }
    }

    // MARK: - 右クリックの項目

    /// 選んだファイルを手元から追い出す。実際に消すのはアプリで、ここでは頼むだけ。
    /// サンドボックスの中からキャッシュには手が届かない
    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems else { return nil }

        let menu = NSMenu(title: "")
        let item = menu.addItem(
            withTitle: "手元から削除", action: #selector(evict(_:)), keyEquivalent: "")
        item.target = self
        return menu
    }

    @objc private func evict(_ sender: AnyObject?) {
        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        guard !urls.isEmpty,
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        else { return }

        let paths = urls.map(\.path)
        guard let data = try? JSONSerialization.data(withJSONObject: paths) else { return }
        try? data.write(to: support.appendingPathComponent("evict.json"), options: .atomic)
        logger.info("手元から削除を頼んだ: \(paths.count) 件")
    }

    // MARK: - 印の絵

    /// 段ごとの絵。記号をそのまま渡すと大きさも色も決まらないので、自分で描く。
    /// 途中の段は円を時計回りに塗って、どこまで来たかを形で見せる
    private static func badge(_ step: Step) -> NSImage {
        let side: CGFloat = 32
        let image = NSImage(size: NSSize(width: side, height: side))

        image.lockFocus()
        defer { image.unlockFocus() }

        switch step.percent {
        case 0:
            draw(symbol: "cloud.fill", color: .systemGray, in: side)
        case 100:
            draw(symbol: "checkmark.circle.fill", color: .systemGreen, in: side)
        default:
            let center = NSPoint(x: side / 2, y: side / 2)
            let radius = side * 0.42
            let box = NSRect(
                x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)

            NSColor.white.setFill()
            NSBezierPath(ovalIn: box).fill()

            NSColor.systemBlue.setFill()
            let pie = NSBezierPath()
            pie.move(to: center)
            pie.appendArc(
                withCenter: center, radius: radius,
                startAngle: 90, endAngle: 90 - 360 * CGFloat(step.percent) / 100, clockwise: true)
            pie.close()
            pie.fill()

            NSColor.systemBlue.setStroke()
            let ring = NSBezierPath(ovalIn: box)
            ring.lineWidth = side * 0.08
            ring.stroke()
        }

        return image
    }

    private static func draw(symbol: String, color: NSColor, in side: CGFloat) {
        guard
            let mark = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: side * 0.9, weight: .semibold))
        else { return }

        let rect = NSRect(
            x: (side - mark.size.width) / 2, y: (side - mark.size.height) / 2,
            width: mark.size.width, height: mark.size.height)
        mark.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
    }
}
