import Foundation
import OSLog

/// アプリ側の記録。拡張は自分の名前で別に持つ
let logger = Logger(subsystem: "io.kkweb.gocci", category: "app")

// 同梱した rclone。
//
// アプリの中に入れたものを使う。検証したバージョンで固定したいので、見つからないときに
// Homebrew などへ回り込むことはしない。

enum Rclone {
    static var path: String? {
        guard let url = Bundle.main.url(forAuxiliaryExecutable: "rclone") else { return nil }
        return FileManager.default.isExecutableFile(atPath: url.path) ? url.path : nil
    }
}
