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
        /// rclone が断ってきた。`status` は rcd が返した HTTP の番号で、分からなければ 0
        case rejected(String, status: Int = 0)
    }

    /// 失敗の種類。File Provider へ返す誤りを選ぶのに使う。
    ///
    /// rcd は失敗を `{"error": "…", "status": 404}` の形で返す。番号が分けてくれるのは
    /// 「無い」（404）と引数の誤り（400）だけで、残りは 500 にまとめられ、Drive が何と
    /// 言ったかは文の中にしか無い（2026-10-01、local の置き場で実測）。なので文で見分ける
    enum FailureKind: Equatable {
        /// 手元の rcd まで届かない。繋がり直せば済む
        case network
        case notFound
        /// Drive の合鍵が切れた。繋ぎ直しが要る
        case notAuthenticated
        case quota
        case collision
        case other
    }

    static func classify(_ error: Error) -> FailureKind {
        if (error as NSError).domain == NSURLErrorDomain { return .network }
        guard let failure = error as? Failure else { return .other }
        guard case .rejected(let reason, let status) = failure else { return .network }

        // rcd 自身の合言葉が合わない。控えが古いだけで、Drive の合鍵とは関係ない
        if status == 401 { return .network }
        if status == 404 { return .notFound }

        let text = reason.lowercased()
        let says = { (needles: [String]) in needles.contains { text.contains($0) } }

        if says([
            "invalid_grant", "couldn't fetch token", "token expired", "oauth2:",
            "invalid authentication credentials", "error 401", "unauthenticated",
        ]) {
            return .notAuthenticated
        }
        // `userRateLimitExceeded` は回数の上限で、容量とは別。待てば通る
        if says(["storagequotaexceeded", "quota has been exceeded", "quotaexceeded"]),
            !says(["ratelimitexceeded"])
        {
            return .quota
        }
        if says(["already exists"]) { return .collision }
        if says(["not found", "no such file or directory"]) { return .notFound }
        return .other
    }

    // MARK: - 版と衝突

    /// 中身の版。大きさと秒で丸めた更新時刻から作る。
    ///
    /// 小数のまま文字にすると、控えに書いて読み直すたびに揺れて、変わっていないものまで
    /// 「変わった」と伝えることになる（2026-08-16 実測。1件しか変えていないのに 1159 件を
    /// 更新と数えた）
    static func signature(bytes: Int64, modified: Date) -> String {
        "\(bytes)-\(Int(modified.timeIntervalSince1970))"
    }

    /// 手元が元にした版と、Drive の今の版が食い違っているか。
    ///
    /// 食い違っていれば、手元が知らないうちに別の端末で書き換えられている。
    /// Drive に無いもの、元にした版がこちらの作った形でないもの（初めての同期で
    /// macOS が埋めてくる値など）は、比べようがないので食い違いとはしない
    static func hasConflict(base: Data, current: Entry?) -> Bool {
        guard let current, !current.isDirectory,
            let text = String(data: base, encoding: .utf8),
            text.range(of: #"^-?\d+-\d+$"#, options: .regularExpression) != nil
        else { return false }
        return text != signature(bytes: current.size, modified: current.modified)
    }

    /// 衝突したときに、手元の中身を逃がす先の名前。`報告書 (conflict 2026-10-01 140058).pdf`
    static func conflictName(for name: String, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let stamp = formatter.string(from: date)
        let suffix = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        // `.zshrc` のような名前は、全体が拡張子に見えて幹が空になる
        guard !suffix.isEmpty, !stem.isEmpty else { return "\(name) (conflict \(stamp))" }
        return "\(stem) (conflict \(stamp)).\(suffix)"
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
    func list(_ path: String, completion: @escaping @Sendable (Result<[Entry], Error>) -> Void) {
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
        path: String, to destination: URL, completion: @escaping @Sendable (Result<Void, Error>) -> Void
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
    func startHTTPServer(on port: UInt16, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
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
        completion: @escaping @Sendable (Result<Data, Error>) -> Void
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

    /// ファイルを丸ごと、決めた場所へ書き出す。
    ///
    /// `operations/copyfile` は使えない。落とすのは rclone で、あれは別のプロセス。
    /// File Provider が渡し先に指す `.CloudStorage` の下は、拡張が自分で作ったものしか
    /// 置けない。rclone に書かせると `operation not permitted`、いったん外へ落として
    /// から移すと、今度は移すところで断られる（どちらも 2026-08-17 実測）。
    ///
    /// なので中身を配る口から流し込む。届いた端から書くので、大きくても手元に溜めない。
    ///
    /// `progress` には届いた分を書き込む。Finder の円はこれで描かれるので、
    /// 終わりに一度だけ埋めると、止まったまま急に満了する
    func download(
        path: String, to destination: URL, reporting progress: Progress,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        let escaped =
            path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        guard let url = URL(string: connection.contentBase.absoluteString + "/" + escaped),
            FileManager.default.createFile(atPath: destination.path, contents: nil),
            let handle = try? FileHandle(forWritingTo: destination)
        else {
            return completion(.failure(Failure.noAnswer))
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 120

        let sink = Sink(handle: handle, progress: progress, completion: completion)
        let session = URLSession(configuration: .default, delegate: sink, delegateQueue: nil)
        sink.session = session
        let task = session.dataTask(with: request)

        // 途中で止められたら、取りに行くのもやめる
        progress.cancellationHandler = { task.cancel() }
        task.resume()
    }

    /// 届いた端からファイルへ書く係。`URLSession` は受け取り手を強く持つので、
    /// 終わったら自分で session を畳まないと残り続ける
    /// 委譲の呼び戻しは、`delegateQueue: nil` で作った session が直列の待ち行列で順に呼ぶ
    /// （URLSession の決まり）。中の状態はその一本の流れからしか触らないので、
    /// 施錠は持たずに Sendable を約束する
    private final class Sink: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let handle: FileHandle
        private let progress: Progress
        private let completion: @Sendable (Result<Void, Error>) -> Void
        private var rejection: Error?
        private var written: Int64 = 0
        var session: URLSession?

        init(
            handle: FileHandle, progress: Progress,
            completion: @escaping @Sendable (Result<Void, Error>) -> Void
        ) {
            self.handle = handle
            self.progress = progress
            self.completion = completion
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                rejection = Failure.rejected("中身を配る口が \(code) を返しました")
                return completionHandler(.cancel)
            }

            // 相手が大きさを教えてくれるなら、そちらを使う。分からないままだと
            // Finder は満了しない円を回し続ける
            if http.expectedContentLength > 0 {
                progress.totalUnitCount = http.expectedContentLength
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            do {
                try handle.write(contentsOf: data)
                written += Int64(data.count)
                progress.completedUnitCount = min(written, progress.totalUnitCount)
            } catch {
                rejection = error
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            try? handle.close()
            self.session?.finishTasksAndInvalidate()
            self.session = nil

            if let rejection { return completion(.failure(rejection)) }
            if let error { return completion(.failure(error)) }
            progress.completedUnitCount = progress.totalUnitCount
            completion(.success(()))
        }
    }

    // MARK: - 書く

    /// フォルダを作る
    func makeDirectory(path: String, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
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
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
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

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { return completion(.failure(error)) }
            guard let status = (response as? HTTPURLResponse)?.statusCode, status < 400 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                let reason = (json?["error"] as? String) ?? "上げられませんでした"
                return completion(.failure(Failure.rejected(reason, status: code)))
            }
            completion(.success(()))
        }.resume()
    }

    /// 動かす。名前を変えるのも、これで同じこと
    func move(
        from source: String, to destination: String, isDirectory: Bool,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        let request = Self.moveRequest(
            remote: connection.remote, from: source, to: destination, isDirectory: isDirectory)
        call(request.route, request.body) { completion($0.map { _ in () }) }
    }

    /// 動かすときの頼み方。
    ///
    /// `operations/movefile` はファイル専用で、フォルダを渡すと `is a directory not a file`
    /// で断られる。フォルダは `sync/move` に置き場ごと渡す。Drive のようにフォルダごと
    /// 動かせる相手なら、中身を一つずつ運ばずに一度で済み、Drive 側の ID も変わらない
    /// （どちらも 2026-10-01、rclone 1.75.0 と local の置き場で実測）。
    ///
    /// `sync/move` は行き先が既にあると黙って混ぜる。そこは呼ぶ側が先に確かめる
    static func moveRequest(
        remote: String, from source: String, to destination: String, isDirectory: Bool
    ) -> (route: String, body: [String: Any]) {
        if isDirectory {
            return (
                "sync/move",
                [
                    "srcFs": remote + source, "dstFs": remote + destination,
                    "deleteEmptySrcDirs": true,
                ]
            )
        }
        return (
            "operations/movefile",
            [
                "srcFs": remote, "srcRemote": source,
                "dstFs": remote, "dstRemote": destination,
            ]
        )
    }

    /// 一件の今の姿。無ければ nil。
    ///
    /// rcd は無いものを訊かれても失敗にせず、`{"item": null}` を返す（2026-10-01 実測）
    func stat(_ path: String, completion: @escaping @Sendable (Result<Entry?, Error>) -> Void) {
        call("operations/stat", ["fs": connection.remote, "remote": path]) { result in
            completion(result.map { json in (json["item"] as? [String: Any]).flatMap(Self.entry(from:)) })
        }
    }

    /// 空のフォルダを消す。中身が残っていれば断られる
    func removeDirectory(path: String, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        call("operations/rmdir", ["fs": connection.remote, "remote": path]) {
            completion($0.map { _ in () })
        }
    }

    /// ファイルを1つ消す
    func deleteFile(path: String, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        call("operations/deletefile", ["fs": connection.remote, "remote": path]) {
            completion($0.map { _ in () })
        }
    }

    /// フォルダを中身ごと消す
    func purge(path: String, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        call("operations/purge", ["fs": connection.remote, "remote": path]) {
            completion($0.map { _ in () })
        }
    }

    /// rclone が返す更新時刻を読む。
    ///
    /// 小数秒が付くかどうかは元の置き場による。`ISO8601DateFormatter` は
    /// `.withFractionalSeconds` を付けると小数秒を必須にし、外すと今度は
    /// 小数秒つきを弾くので、両方を順に当てる。どちらでも読めなければ nil。
    static func timestamp(_ raw: String) -> Date? {
        // ISO8601DateFormatter は共有できる状態を持つので静的に置けない。
        // 読み取りの型は構造体で、作る費用は無いに等しい
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(raw))
            ?? (try? Date.ISO8601FormatStyle().parse(raw))
    }

    static func entry(from raw: [String: Any]) -> Entry? {
        guard let name = raw["Name"] as? String else { return nil }

        let stamp = (raw["ModTime"] as? String) ?? ""

        return Entry(
            name: name,
            size: (raw["Size"] as? NSNumber)?.int64Value ?? 0,
            isDirectory: (raw["IsDir"] as? Bool) ?? false,
            modified: timestamp(stamp) ?? Date(timeIntervalSince1970: 0),
            id: (raw["ID"] as? String) ?? name)
    }

    // MARK: - 口を叩く

    private func call(
        _ route: String, _ body: [String: Any],
        completion: @escaping @Sendable (Result<[String: Any], Error>) -> Void
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
                return completion(.failure(Failure.rejected(reason, status: status)))
            }
            completion(.success(json))
        }.resume()
    }
}
