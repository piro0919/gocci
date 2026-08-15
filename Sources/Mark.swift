import AppKit

// Gocci の印。渦巻きの殻を背負ったヤドカリ。
//
// メニューバーでの実寸は 18pt しかない。形は `Resources/mark-solid.png` と
// `Resources/mark-outline.png` の2枚が持っていて、ここでは読み込んで単色として
// 扱うだけにする。塗りと中抜きは同じ枠で切ってあるので、状態が変わっても印は動かない。
//
// 待ちは塗りを薄くしたもの、不具合は中抜きにバッジを重ねたもので、どちらもここで作る。

enum Mark {
    /// メニューバーでの見せ方
    enum Style {
        /// 塗り。繋がっている
        case solid
        /// 中抜き。繋がっていない
        case outline
        /// 薄い塗り。待っている・繋ぎ直している
        case dim
        /// 中抜きに小さなバッジ。不具合
        case badged
    }

    // MARK: - 形

    /// 印の縦横比。2枚は同じ枠なので、どちらから取っても同じ
    static var aspect: CGFloat {
        guard let size = art(.solid)?.size, size.height > 0 else { return 1 }
        return size.width / size.height
    }

    /// 印の絵。アプリの中では束の中、道具から呼ぶときは作業場所の Resources から読む
    private static func art(_ style: Style) -> NSImage? {
        let name = (style == .outline || style == .badged) ? "mark-outline" : "mark-solid"
        if let cached = cache[name] { return cached }

        var found: NSImage?
        if let url = Bundle.main.url(forResource: name, withExtension: "png") {
            found = NSImage(contentsOf: url)
        }
        if found == nil {
            found = NSImage(contentsOfFile: "Resources/\(name).png")
        }
        cache[name] = found
        return found
    }

    private nonisolated(unsafe) static var cache: [String: NSImage?] = [:]

    // MARK: - 絵にする

    /// 指定した高さの画像を作る。メニューバー用は単色として扱わせる
    static func image(height: CGFloat, style: Style, template: Bool = true) -> NSImage {
        // 升目より横に広い。倍率は升目の縦横比から取る
        let size = NSSize(width: (height * aspect).rounded(), height: height)
        let image = NSImage(size: size)

        image.lockFocus()
        defer { image.unlockFocus() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return image }

        // 升目の比のまま中央に置く。不具合のバッジが下へ少しはみ出すので、余白を残す
        let boxWidth = size.width * 0.86
        let box = CGRect(
            x: (size.width - boxWidth) / 2, y: (height - boxWidth / aspect) / 2,
            width: boxWidth, height: boxWidth / aspect)
        draw(in: ctx, box: box, style: style, color: .black)

        image.isTemplate = template
        return image
    }

    static func draw(in ctx: CGContext, box: CGRect, style: Style, color: NSColor) {
        guard let art = art(style), let mask = art.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

        // 絵は黒に透明度だけを持たせてある。それを型紙にして、指定の色で塗る
        ctx.saveGState()
        ctx.clip(to: box, mask: mask)
        ctx.setFillColor(color.withAlphaComponent(style == .dim ? 0.4 : 1).cgColor)
        ctx.fill(box)
        ctx.restoreGState()

        if style == .badged { drawBadge(in: ctx, box: box, color: color) }
    }

    /// 不具合の印。右下に小さな丸を置き、地の輪郭をくり抜いてから重ねる。
    /// くり抜かないと、重なった線と丸がひと塊に見えて何も伝わらない
    private static func drawBadge(in ctx: CGContext, box: CGRect, color: NSColor) {
        let side = box.width * 0.42
        let rect = CGRect(x: box.maxX - side * 0.9, y: box.minY - side * 0.15, width: side, height: side)

        ctx.setBlendMode(.destinationOut)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillEllipse(in: rect.insetBy(dx: -side * 0.16, dy: -side * 0.16))

        ctx.setBlendMode(.normal)
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: rect)

        // 丸の中を白く抜いて「！」にする。棒と点だけ。線ではなく面で作る
        ctx.setBlendMode(.destinationOut)
        ctx.setFillColor(NSColor.black.cgColor)
        let barWidth = side * 0.16
        ctx.fill(
            CGRect(
                x: rect.midX - barWidth / 2, y: rect.midY - side * 0.04,
                width: barWidth, height: side * 0.3))
        ctx.fillEllipse(
            in: CGRect(
                x: rect.midX - barWidth / 2, y: rect.midY - side * 0.22,
                width: barWidth, height: barWidth))
        ctx.setBlendMode(.normal)
    }
}
