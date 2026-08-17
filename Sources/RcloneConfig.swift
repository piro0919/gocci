import Foundation

// rclone の設定ファイルへの読み書き。
//
// client_id と client_secret は UserDefaults に持たない。持ち主は rclone の設定
// （`~/.config/rclone/rclone.conf`）で、二重に持てば必ずずれる。読むのも書くのも
// rclone 自身に頼む。ファイルの書式に合わせる仕事をこちらでやる意味が無い。

enum RcloneConfig {
    /// リモートの設定を読む。値の中身は見せないので、そのまま返す
    static func values(of remote: String) -> [String: String] {
        guard let output = run(["config", "show", remote]) else { return [:] }

        var values: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            values[parts[0].trimmingCharacters(in: .whitespaces)] =
                parts[1].trimmingCharacters(in: .whitespaces)
        }
        return values
    }

    /// 使える接続先（type が drive のもの）を並べる
    static func driveRemotes() -> [String] {
        guard let output = run(["config", "dump"]),
            let data = output.data(using: .utf8),
            let all = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        else { return [] }

        return
            all
            .filter { ($0.value["type"] as? String) == "drive" }
            .keys
            .sorted()
    }

    /// client_id と client_secret を書き込む。空文字を渡せば消える（rclone 共用のものに戻る）
    static func setCredentials(remote: String, clientID: String, clientSecret: String) -> String? {
        let result = run([
            "config", "update", remote,
            "client_id", clientID,
            "client_secret", clientSecret,
            // 対話に落とさない。落ちると返ってこなくなる
            "--non-interactive",
        ])
        return result == nil ? "rclone config update に失敗しました" : nil
    }

    /// 接続先を新しく作る。ブラウザが開いて Google の同意画面が出る。
    ///
    /// これまでは端末で `rclone config` を叩いてもらう必要があった。入れてすぐ使えると
    /// 思って落とした人が、そこで詰まる。
    ///
    /// `--non-interactive` は付けない。付けると質問が JSON で返ってきて、こちらが
    /// 一問ずつ答える羽目になる。付けなければ質問は既定で進み、Drive の場合は
    /// そのままブラウザでの認証に入る（`rclone config create --help`）
    static func create(
        remote: String, clientID: String, clientSecret: String,
        completion: @escaping (String?) -> Void
    ) {
        DispatchQueue.global().async {
            var arguments = ["config", "create", remote, "drive"]
            if !clientID.isEmpty { arguments += ["client_id", clientID] }
            if !clientSecret.isEmpty { arguments += ["client_secret", clientSecret] }

            let output = run(arguments, timeout: 300)
            DispatchQueue.main.async {
                completion(output == nil ? "繋げませんでした" : nil)
            }
        }
    }

    /// 認証をやり直す。ブラウザが開いて Google の同意画面が出る。
    /// client_id を変えると今の認証は無効になるので、書き込みの後は必ずこれが要る
    static func reconnect(remote: String, completion: @escaping (String?) -> Void) {
        DispatchQueue.global().async {
            let output = run(["config", "reconnect", "\(remote):"], timeout: 300)
            DispatchQueue.main.async {
                completion(output == nil ? "認証をやり直せませんでした" : nil)
            }
        }
    }

    // MARK: - rclone を呼ぶ

    /// 失敗したら nil。値そのものは記録に残さない
    private static func run(_ arguments: [String], timeout: TimeInterval = 30) -> String? {
        guard let rclone = Rclone.path else { return nil }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: rclone)
        task.arguments = arguments

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
        } catch {
            logger.error("rclone を起動できなかった: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard !task.isRunning else {
            task.terminate()
            logger.error("rclone config が \(Int(timeout)) 秒で返らなかった")
            return nil
        }

        let output =
            String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard task.terminationStatus == 0 else {
            logger.error("rclone config が失敗した（\(task.terminationStatus)）")
            return nil
        }
        return output
    }
}
