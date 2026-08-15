import Foundation

// rclone への問い合わせそのもの。
//
// マウントを張らずに使う。`rclone rcd` で口だけ開けておけば、一覧も取得も HTTP で頼める
// （2026-08-16 に実測。マウント無しで `operations/list` と `operations/copyfile` が通った）。
//
// 呼ぶのは拡張の中からなので、待たせ方に気をつける。File Provider は要求ごとに
// `NSProgress` を返す作りで、そこで待ち続けると Finder の表示が止まる。

struct RcClient {
    let connection: RcEndpoint.Connection

    enum Failure: Error {
        case noAnswer
        case rejected(String)
    }

    /// Drive の一件ぶん。返ってくる形は rclone が決めている
    struct Entry {
        let name: String
        let size: Int64
        let isDirectory: Bool
        let modified: Date
        /// Drive 側の識別子。名前が変わっても追える
        let id: String
    }

    /// フォルダの中身を並べる。`path` はマウント先から見た道で、根は空文字
    func list(_ path: String, completion: @escaping (Result<[Entry], Error>) -> Void) {
        call("operations/list", ["fs": connection.remote, "remote": path]) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let json):
                let raw = (json["list"] as? [[String: Any]]) ?? []
                completion(.success(raw.compactMap(Self.entry(from:))))
            }
        }
    }

    /// ファイルを1つ手元へ落とす。落とし先は呼ぶ側が決める
    func copy(
        path: String, to destination: URL, completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let directory = destination.deletingLastPathComponent().path
        let name = destination.lastPathComponent
        let source = (path as NSString).deletingLastPathComponent
        let file = (path as NSString).lastPathComponent

        call(
            "operations/copyfile",
            [
                "srcFs": connection.remote + source, "srcRemote": file,
                "dstFs": directory, "dstRemote": name,
            ]
        ) { result in
            completion(result.map { _ in () })
        }
    }

    private static func entry(from raw: [String: Any]) -> Entry? {
        guard let name = raw["Name"] as? String else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = (raw["ModTime"] as? String) ?? ""

        return Entry(
            name: name,
            size: (raw["Size"] as? NSNumber)?.int64Value ?? 0,
            isDirectory: (raw["IsDir"] as? Bool) ?? false,
            modified: formatter.date(from: stamp) ?? Date(timeIntervalSince1970: 0),
            id: (raw["ID"] as? String) ?? name)
    }

    // MARK: - 口を叩く

    private func call(
        _ route: String, _ body: [String: Any],
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        var request = URLRequest(url: connection.base.appendingPathComponent(route))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(connection.authorization, forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        // 相手は手元の rclone だが、Drive の向こうまで待つことがある
        request.timeoutInterval = 120

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { return completion(.failure(error)) }
            guard let data else { return completion(.failure(Failure.noAnswer)) }

            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if let status = (response as? HTTPURLResponse)?.statusCode, status >= 400 {
                let reason = (json["error"] as? String) ?? "rclone が \(status) を返しました"
                return completion(.failure(Failure.rejected(reason)))
            }
            completion(.success(json))
        }.resume()
    }
}
