import AppKit

// メニューバーに出す絵。
//
// 本物のアイコン（雲＋ディスク）はまだ決まっていない。決まるまでは SF Symbols で代用する。
// 記号の名前は macOS の版によって在る無いが変わるので、候補を並べて最初に見つかったものを使う。

enum Icon {
    static func image(for state: MountState) -> NSImage? {
        let names: [String]
        switch state {
        case .mounted:
            names = ["externaldrive.fill.badge.icloud", "externaldrive.badge.icloud", "icloud.fill"]
        case .mounting, .unmounting, .reconnecting:
            names = ["externaldrive.badge.timemachine", "externaldrive", "icloud"]
        case .unmounted, .waitingForDisk:
            names = ["externaldrive", "icloud"]
        case .failed:
            names = [
                "externaldrive.badge.exclamationmark", "exclamationmark.icloud", "icloud.slash",
            ]
        }

        guard let image = first(of: names) else { return nil }
        // メニューバーの色（外観の切り替えやダークメニューバー）に追従させる
        image.isTemplate = true
        return image
    }

    private static func first(of names: [String]) -> NSImage? {
        for name in names {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
                return image
            }
        }
        return nil
    }
}
