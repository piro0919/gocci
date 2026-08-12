import AppKit

// Gocci の印。雲の下半分が円盤（ディスク）になっている。
//
// メニューバーでの実寸は 18pt しかないので、絵ではなく図形として組む。塊同士の
// 組み合わせだけで出来ているため、縮めても輪郭が残る。
//
// 同じ形をアプリのアイコン（1024px）でも使う。大小で別々に作ると必ずずれるので、
// 座標は 100×100 の升目で一度だけ決めて、あとは倍率を掛ける。

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
    //
    // 幅 100・高さ 76 の升目で設計する。縦横で別々の倍率を掛けると円が歪むので、
    // 倍率は幅からの1つだけにする。

    /// 設計に使う升目の縦横比。画像の大きさもこれに合わせる
    static let aspect: CGFloat = 100 / 76

    /// 雲。円盤より狭くする。同じ幅だと重なって、ひと塊の雲にしか見えない
    static func cloud(in box: CGRect) -> CGPath {
        let s = box.width / 100
        let at = { (x: CGFloat, y: CGFloat, r: CGFloat) in
            CGRect(
                x: box.minX + (x - r) * s, y: box.minY + (y - r) * s,
                width: r * 2 * s, height: r * 2 * s)
        }

        let path = CGMutablePath()
        path.addEllipse(in: at(50, 52, 22))  // 中央の高いふくらみ
        path.addEllipse(in: at(28, 44, 16))
        path.addEllipse(in: at(72, 44, 16))
        // ふくらみの下を埋めて、底をまっすぐ円盤へ落とす
        path.addRect(
            CGRect(x: box.minX + 12 * s, y: box.minY + 38 * s, width: 76 * s, height: 10 * s))
        return path
    }

    /// 円盤。斜め上から見た楕円。雲より広く取らないと、雲の裾に飲まれて見えなくなる
    static func disk(in box: CGRect) -> CGPath {
        let s = box.width / 100
        let path = CGMutablePath()
        path.addEllipse(
            in: CGRect(x: box.minX, y: box.minY, width: 100 * s, height: 28 * s))
        return path
    }

    /// 雲と円盤を合わせた輪郭。
    ///
    /// 雲と円盤は離す。くっつけると裾の広い一つの塊になり、帽子にしか見えなくなる。
    /// 部品を重ねただけの道を線で描くと内側の線が全部出るので、雲は先に一つへまとめる
    static func silhouette(in box: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.addPath(merged(cloud(in: box)))
        path.addPath(disk(in: box))
        return path
    }

    /// 重なった部品を一つの形にまとめる
    private static func merged(_ path: CGPath) -> CGPath {
        path.union(CGMutablePath())
    }

    // MARK: - 絵にする

    /// 指定した高さの画像を作る。メニューバー用は単色として扱わせる
    static func image(height: CGFloat, style: Style, template: Bool = true) -> NSImage {
        // 円盤のぶん横に広いので、幅は高さの 1.15 倍
        let size = NSSize(width: (height * 1.15).rounded(), height: height)
        let image = NSImage(size: size)

        image.lockFocus()
        defer { image.unlockFocus() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return image }

        let box = CGRect(origin: .zero, size: size).insetBy(dx: size.width * 0.04, dy: height * 0.1)
        draw(in: ctx, box: box, style: style, color: .black)

        image.isTemplate = template
        return image
    }

    static func draw(in ctx: CGContext, box: CGRect, style: Style, color: NSColor) {
        let shape = silhouette(in: box)

        switch style {
        case .solid:
            ctx.setFillColor(color.cgColor)
            ctx.addPath(shape)
            ctx.fillPath()

        case .dim:
            ctx.setFillColor(color.withAlphaComponent(0.4).cgColor)
            ctx.addPath(shape)
            ctx.fillPath()

        case .outline, .badged:
            // 中抜き。線は実寸で 1.5px 相当まで太らせないと、18pt で消える
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(max(1.4, box.width * 0.075))
            ctx.setLineJoin(.round)
            ctx.addPath(shape)
            ctx.strokePath()

            if style == .badged { drawBadge(in: ctx, box: box, color: color) }
        }
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
