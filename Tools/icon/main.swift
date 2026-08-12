import AppKit

// アイコンを作る。Sources/Mark.swift の形をそのまま使う。
//
//   ./icon.sh    Resources/gocci-icon.png と docs/icon-preview.png を作り直して開く
//
// アプリのアイコンは角丸の四角にグラデーション、白い印。メニューバーは単色の輪郭だけ。
// Galopen に倣った形で、色だけ変えてある（あちらが青紫なので、こちらは青緑に振る）。

/// 背景のグラデーション。上が明るい青緑、下が濃い藍
let topColor = NSColor(srgbRed: 0.16, green: 0.78, blue: 0.76, alpha: 1)
let bottomColor = NSColor(srgbRed: 0.09, green: 0.33, blue: 0.62, alpha: 1)

func appIcon(side: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    defer { image.unlockFocus() }
    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }

    // 角の丸みは macOS のアイコンに合わせて、辺の 22%
    let bounds = CGRect(x: 0, y: 0, width: side, height: side)
    let rounded = CGPath(
        roundedRect: bounds, cornerWidth: side * 0.22, cornerHeight: side * 0.22, transform: nil)
    ctx.addPath(rounded)
    ctx.clip()

    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [topColor.cgColor, bottomColor.cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(
        gradient, start: CGPoint(x: 0, y: side), end: CGPoint(x: side, y: 0), options: [])

    // 印は中央に、辺の 62% の幅で置く
    let markWidth = side * 0.62
    let box = CGRect(
        x: (side - markWidth) / 2, y: side * 0.30, width: markWidth, height: markWidth * 0.62)
    Mark.draw(in: ctx, box: box, style: .solid, color: .white)

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
        label("\(Int(size))pt", NSPoint(x: 150 + CGFloat(index) * 150, y: image.size.height - 34), 12)
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
        FileHandle.standardError.write(Data("画像にできませんでした: \(path)\n".utf8))
        exit(1)
    }
    try! data.write(to: URL(fileURLWithPath: path))
    print("できました: \(path)")
}

let arguments = CommandLine.arguments
let resources = arguments.count > 1 ? arguments[1] : "Resources"
let docs = arguments.count > 2 ? arguments[2] : "docs"

write(appIcon(side: 1024), to: "\(resources)/gocci-icon.png")
write(preview(), to: "\(docs)/icon-preview.png")
