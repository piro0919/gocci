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

    /// 中身を配る口を立てる。合言葉は付けない——127.0.0.1 にだけ開くのと、
    /// 港を毎回変えるので、そこは問い合わせ口と同じ考え方にしてある
    func startHTTPServer(on port: UInt16, completion: @escaping (Result<Void, Error>) -> Void) {
        call(
            "serve/start",
            ["type": "http", "fs": connection.remote, "addr": "127.0.0.1:\(port)"]
        ) { completion($0.map { _ in () }) }
    }

    /// ファイルの一部だけを取る。
    ///
    /// 中身は `serve/start` で立てた HTTP の口から `Range` を付けて取る。丸ごと取らずに
    /// 済むので、10GB の動画でも見ている辺りだけで済む（rclone の VFS がやっていたのと
    /// 同じ考え方）。範囲が返ってこない相手なら、丸ごと返ってくる
    func fetchRange(
        path: String, offset: Int64, length: Int64,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        // 道はそのまま URL の一部になる。空白や日本語が入るので必ず逃がす
        let escaped =
            path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        guard let url = URL(string: connection.contentBase.absoluteString + "/" + escaped) else {
            return completion(.failure(Failure.noAnswer))
        }

        var request = URLRequest(url: url)
        request.setValue("bytes=\(offset)-\(offset + length - 1)", forHTTPHeaderField: "Range")
        request.timeoutInterval = 120

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { return completion(.failure(error)) }
            guard let data, let http = response as? HTTPURLResponse else {
                return completion(.failure(Failure.noAnswer))
            }
            guard http.statusCode == 206 || http.statusCode == 200 else {
                return completion(.failure(Failure.rejected("中身を配る口が \(http.statusCode) を返しました")))
            }
            completion(.success(data))
        }.resume()
    }

    // MARK: - 書く

    /// フォルダを作る
    func makeDirectory(path: String, completion: @escaping (Result<Void, Error>) -> Void) {
        call("operations/mkdir", ["fs": connection.remote, "remote": path]) {
            completion($0.map { _ in () })
        }
    }

    /// ファイルを1つ上げる。
    ///
    /// `operations/uploadfile` は JSON ではなく multipart で受け取る。ここだけ形が違う。
    ///
    /// 名前は `filename` がそのまま向こう側の名前になる。macOS が書き込みに使う一時ファイルは
    /// `318181502` のような番号なので、渡す名前を別に決める。渡さないと、その番号のまま
    /// Drive に並ぶ（2026-08-16 実測）
    func upload(
        local: URL, named name: String, toDirectory directory: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let contents = try? Data(contentsOf: local) else {
            return completion(.failure(Failure.noAnswer))
        }

        var components = URLComponents(
            url: connection.base.appendingPathComponent("operations/uploadfile"),
            resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "fs", value: connection.remote),
            URLQueryItem(name: "remote", value: directory),
        ]
        guard let url = components?.url else { return completion(.failure(Failure.noAnswer)) }

        let boundary = "gocci-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(
            Data(
                "Content-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(contents)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(connection.authorization, forHTTPHeaderField: "Authorization")
        request.httpBody = body
        request.timeoutInterval = 600

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error { return completion(.failure(error)) }
            guard let status = (response as? HTTPURLResponse)?.statusCode, status < 400 else {
                return completion(.failure(Failure.rejected("上げられませんでした")))
            }
            completion(.success(()))
        }.resume()
    }

    /// ファイルを1つ消す
    func deleteFile(path: String, completion: @escaping (Result<Void, Error>) -> Void) {
        call("operations/deletefile", ["fs": connection.remote, "remote": path]) {
            completion($0.map { _ in () })
        }
    }

    /// フォルダを中身ごと消す
    func purge(path: String, completion: @escaping (Result<Void, Error>) -> Void) {
        call("operations/purge", ["fs": connection.remote, "remote": path]) {
            completion($0.map { _ in () })
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
