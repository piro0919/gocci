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
    /// 落ちてきた割合をどう見せるか。段ごとに別の印として登録する
    private enum Step: Int, CaseIterable {
        case none = 0, quarter = 25, half = 50, most = 75, whole = 100

        /// この割合はどの段か。達した段を採る
        static func of(_ percent: Int) -> Step {
            allCases.last { percent >= $0.rawValue } ?? .none
        }

        var identifier: String { "io.kkweb.gocci.step\(rawValue)" }

        var label: String {
            switch self {
            case .none: return "クラウドのみ"
            case .whole: return "手元にある"
            default: return "取得中 \(rawValue)%"
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
        for step in Step.allCases {
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
        let path = (url.path as NSString).standardizingPath
        guard !mountPoint.isEmpty, path.hasPrefix(mountPoint + "/") else { return }

        // フォルダには印を付けない。実体が手元にあるかという話が当てはまらない
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            return
        }

        // 濁点の表し方が場所によって違うことがあるので、比べる前に揃える
        let relative = String(path.dropFirst(mountPoint.count + 1))
            .precomposedStringWithCanonicalMapping
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

        if mountPoint != self.mountPoint { known.removeAll() }
        self.mountPoint = mountPoint
        self.progress = progress

        // 見張る場所はマウント先だけ。空のときは何も見張らない
        FIFinderSyncController.default().directoryURLs =
            mountPoint.isEmpty ? [] : [URL(fileURLWithPath: mountPoint)]

        logger.info(
            "一覧を読み直した: \(progress.count) 件 / 塗り直す \(self.known.count) 件")

        // 既に描かれている印を塗り直す
        for url in known { apply(to: url) }
    }

    // MARK: - 印の絵

    /// 段ごとの絵。記号をそのまま渡すと大きさも色も決まらないので、自分で描く。
    /// 途中の段は円を時計回りに塗って、どこまで来たかを形で見せる
    private static func badge(_ step: Step) -> NSImage {
        let side: CGFloat = 32
        let image = NSImage(size: NSSize(width: side, height: side))

        image.lockFocus()
        defer { image.unlockFocus() }

        switch step {
        case .none:
            draw(symbol: "cloud.fill", color: .systemGray, in: side)
        case .whole:
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
                startAngle: 90, endAngle: 90 - 360 * CGFloat(step.rawValue) / 100, clockwise: true)
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
