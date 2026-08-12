import AppKit

// メニューバーに出す絵。
//
// 状態は塗り・中抜き・薄い塗りで出し分け、不具合のときだけ小さいバッジを足す。
// 形は Mark が持っている。絵ではなく図形なので、どの大きさでも潰れない。

enum Icon {
    /// メニューバーでの実寸
    static let height: CGFloat = 18

    static func image(for state: MountState) -> NSImage {
        Mark.image(height: height, style: style(for: state))
    }

    private static func style(for state: MountState) -> Mark.Style {
        switch state {
        case .mounted: return .solid
        case .mounting, .unmounting, .waitingForDisk, .reconnecting: return .dim
        case .unmounted: return .outline
        case .failed: return .badged
        }
    }
}
