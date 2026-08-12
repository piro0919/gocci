import AppKit

// アイコン周りの道具。
//
//   ./build/icon preview <出力先>          メニューバーの印の見本を作る
//   ./build/icon placeholder <出力先.png>  絵がまだ無いときの仮のアプリアイコンを作る
//   ./build/icon mask <元.png> <先.png>    角を丸く抜く
//
// 生成した絵は角が塗り潰された正方形で来る。そのまま .icns にすると Finder で
// 角が黒い四角に見えるので、ビルドのたびにここで抜く。元の絵には手を入れない。

/// 仮アイコンの背景。上が明るい青緑、下が濃い藍
let topColor = NSColor(srgbRed: 0.16, green: 0.78, blue: 0.76, alpha: 1)
let bottomColor = NSColor(srgbRed: 0.09, green: 0.33, blue: 0.62, alpha: 1)

/// macOS のアイコンの角の丸み。辺に対する割合
let cornerRatio: CGFloat = 0.22

func placeholder(side: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    defer { image.unlockFocus() }
    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }

    let bounds = CGRect(x: 0, y: 0, width: side, height: side)
    ctx.addPath(
        CGPath(
            roundedRect: bounds, cornerWidth: side * cornerRatio, cornerHeight: side * cornerRatio,
            transform: nil))
    ctx.clip()

    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [topColor.cgColor, bottomColor.cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(
        gradient, start: CGPoint(x: 0, y: side), end: CGPoint(x: side, y: 0), options: [])

    let markWidth = side * 0.62
    let box = CGRect(
        x: (side - markWidth) / 2, y: side * 0.28, width: markWidth, height: markWidth / Mark.aspect)
    Mark.draw(in: ctx, box: box, style: .solid, color: .white)

    return image
}

/// 角を丸く抜く。元の絵の大きさはそのまま
func masked(_ source: NSImage) -> NSImage {
    let size = source.size
    let side = min(size.width, size.height)
    let image = NSImage(size: size)

    image.lockFocus()
    defer { image.unlockFocus() }
    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }

    ctx.addPath(
        CGPath(
            roundedRect: CGRect(origin: .zero, size: size),
            cornerWidth: side * cornerRatio, cornerHeight: side * cornerRatio, transform: nil))
    ctx.clip()

    // 絵の縁には、元の角丸を黒地に描いたときの名残が1〜2画素残っている。
    // ほんの少し広げて描き、その帯を枠の外へ追い出す
    let bleed = side * 0.015
    source.draw(
        in: CGRect(origin: .zero, size: size).insetBy(dx: -bleed, dy: -bleed),
        from: .zero, operation: .sourceOver, fraction: 1)

    return image
}

/// 実寸で潰れないかを確かめるための見本。18pt の並びと、拡大したものを1枚に収める
func preview() -> NSImage {
    let styles: [(String, Mark.Style)] = [
        ("接続中", .solid), ("未接続", .outline), ("待ち", .dim), ("不具合", .badged),
    ]
    let sizes: [CGFloat] = [18, 36, 72]

    let width: CGFloat = 640
    let rowHeight: CGFloat = 96
    let image = NSImage(size: NSSize(width: width, height: rowHeight * CGFloat(styles.count) + 60))

    image.lockFocus()
    defer { image.unlockFocus() }

    NSColor.white.setFill()
    NSRect(origin: .zero, size: image.size).fill()

    let label: (String, NSPoint, CGFloat) -> Void = { text, at, size in
        (text as NSString).draw(
            at: at,
            withAttributes: [
                .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.darkGray,
            ])
    }

    for (index, size) in sizes.enumerated() {
        label(
            "\(Int(size))pt", NSPoint(x: 150 + CGFloat(index) * 150, y: image.size.height - 34), 12)
    }

    for (row, (name, style)) in styles.enumerated() {
        let y = image.size.height - 60 - CGFloat(row + 1) * rowHeight + 20
        label(name, NSPoint(x: 24, y: y + 30), 14)

        for (index, size) in sizes.enumerated() {
            let mark = Mark.image(height: size, style: style, template: false)
            mark.draw(
                at: NSPoint(x: 150 + CGFloat(index) * 150, y: y + 30), from: .zero,
                operation: .sourceOver, fraction: 1)
        }
    }

    return image
}

func write(_ image: NSImage, to path: String) {
    guard let tiff = image.tiffRepresentation,
        let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    else {
        die("画像にできませんでした: \(path)")
    }
    do {
        try data.write(to: URL(fileURLWithPath: path))
    } catch {
        die("書けませんでした: \(path): \(error.localizedDescription)")
    }
    print("できました: \(path)")
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    die("使い方: icon preview <出力先> | icon placeholder <先.png> | icon mask <元.png> <先.png>")
}

switch arguments[1] {
case "preview":
    write(preview(), to: "\(arguments[2])/icon-preview.png")

case "placeholder":
    write(placeholder(side: 1024), to: arguments[2])

case "mask":
    guard arguments.count >= 4 else { die("使い方: icon mask <元.png> <先.png>") }
    guard let source = NSImage(contentsOfFile: arguments[2]) else {
        die("読めませんでした: \(arguments[2])")
    }
    write(masked(source), to: arguments[3])

default:
    die("知らない指示です: \(arguments[1])")
}
