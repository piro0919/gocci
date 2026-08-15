import Foundation

// rclone の問い合わせ口を、拡張へ渡すための控え。
//
// File Provider の拡張はサンドボックスの中で動く。設定も rclone の設定も自分では読めないので、
// 「どこへ、どの合言葉で訊けばいいか」をアプリ側が書き、拡張はそれを読むだけにする。
// バッジの一覧（`BadgeIndex`）と同じ経路で、置き場所は拡張のコンテナ。
//
// 合言葉は起動のたびに作り直す。控えが古いままだと、拡張は繋がらないまま待つことになるので、
// 書き出しはマウント（rclone の起動）と同じ順で行う。

enum RcEndpoint {
    private static let fileName = "rc.json"

    /// 書く側（アプリ）から見た場所。サンドボックスの外にいるので、道をそのまま組み立てる
    private static var writeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/io.kkweb.gocci.FileProvider/Data/Library/Application Support",
                isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// 読む側（拡張）から見た場所。
    ///
    /// 中では `Application Support` を訊けばコンテナの中が返る。書く側と同じ書き方をすると
    /// コンテナの中にもう一段コンテナの道を作ってしまい、いつまでも見つからない
    private static var readURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(fileName)
    }

    struct Connection {
        let port: UInt16
        let user: String
        let password: String
        /// どのリモートを見せるか。`gdrive:` のような形
        let remote: String
        /// 中身を配る口。範囲を指定して取るために、こちらは HTTP で持つ
        let contentPort: UInt16

        var base: URL { URL(string: "http://127.0.0.1:\(port)")! }
        var contentBase: URL { URL(string: "http://127.0.0.1:\(contentPort)")! }

        /// Basic 認証の中身
        var authorization: String {
            "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
        }
    }

    /// アプリ側から書く。rclone を起こしたらすぐに呼ぶ
    static func write(
        port: UInt16, user: String, password: String, remote: String, contentPort: UInt16
    ) {
        let payload: [String: Any] = [
            "port": Int(port), "user": user, "password": password, "remote": remote,
            "contentPort": Int(contentPort),
        ]

        let target = writeURL
        let directory = target.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: target, options: .atomic)
    }

    /// 拡張側から読む。まだ書かれていなければ nil
    static func read() -> Connection? {
        guard let source = readURL,
            let data = try? Data(contentsOf: source),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let port = json["port"] as? Int,
            let user = json["user"] as? String,
            let password = json["password"] as? String,
            let remote = json["remote"] as? String,
            let contentPort = json["contentPort"] as? Int
        else { return nil }

        return Connection(
            port: UInt16(truncatingIfNeeded: port), user: user, password: password, remote: remote,
            contentPort: UInt16(truncatingIfNeeded: contentPort))
    }

    /// 繋がりが切れたら消す。古い口を叩き続けないように
    static func clear() {
        try? FileManager.default.removeItem(at: writeURL)
    }
}
