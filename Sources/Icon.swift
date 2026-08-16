import AppKit

// メニューバーに出す絵。
//
// 状態は塗り・中抜き・薄い塗りで出し分け、不具合のときだけ小さいバッジを足す。
// 形は Mark が持っている。絵ではなく図形なので、どの大きさでも潰れない。

/// 印の隣で回す輪。取りに行っている間だけ出す。
///
/// メニューバーの項目は1つのまま、押したときの当たりは印に任せる。輪が当たりを取ると、
/// 輪が出ている間だけメニューが開かない場所ができてしまう
final class SpinnerView: NSProgressIndicator {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

enum Icon {
    /// メニューバーでの実寸
    static let height: CGFloat = 18

    /// 輪の実寸と、印との間
    static let spinnerSize: CGFloat = 13
    static let spinnerGap: CGFloat = 5

    /// メニューバーに出す絵。
    ///
    /// 取りに行っている間は、右に輪のぶんの空きを足した絵を返す。項目を広げるだけでは、
    /// 絵が広がった真ん中に来て輪と重なる。空きは絵の側で持たせる
    static func image(for state: Provider.State, reservingSpinner: Bool = false) -> NSImage {
        let mark = Mark.image(height: height, style: style(for: state))
        guard reservingSpinner else { return mark }

        let size = NSSize(width: mark.size.width + spinnerGap + spinnerSize, height: mark.size.height)
        let padded = NSImage(size: size)
        padded.lockFocus()
        mark.draw(
            at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        padded.unlockFocus()
        padded.isTemplate = true
        return padded
    }

    private static func style(for state: Provider.State) -> Mark.Style {
        switch state {
        case .on: return .solid
        case .starting: return .dim
        case .off: return .outline
        case .failed: return .badged
        }
    }
}
