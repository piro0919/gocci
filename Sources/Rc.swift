import Foundation

// rclone への問い合わせ口（`--rc`）。
//
// 動いている rclone の中を外から知る手立てはこれしかない。キャッシュが今どれだけ載って
// いるか、まだ上げ終えていない書き込みがあるか、今どこかを取りに行っているかを訊く。
//
// 口は 127.0.0.1 にだけ開き、起動のたびに作り直す合言葉で守る。合言葉を渡さないと
// 誰でも叩けてしまい、マウントを外すところまでできてしまう。
// 港（ポート）は空いているものを OS に選ばせる。決め打ちにすると、2台目や再起動の
// 直後にぶつかる。

enum Rc {
    /// 今の口。マウントのたびに作り直す
    private(set) static var endpoint: (port: UInt16, user: String, password: String)?

    /// 新しい口を用意して、rclone へ渡す引数を返す。
    ///
    /// `--rc` を付けるのは、口を「ついでに」開けるとき——つまり `nfsmount` のとき。
    /// `rcd` は口を開けること自体が仕事なので、付けると弾かれる
    /// （`CRITICAL: Don't supply --rc flag when using rcd`。2026-08-16 実測）
    static func prepare(alongsideMount: Bool = true) -> [String] {
        let port = freePort()
        let password = UUID().uuidString
        endpoint = (port, "gocci", password)

        return (alongsideMount ? ["--rc"] : []) + [
            "--rc-addr", "127.0.0.1:\(port)",
            "--rc-user", "gocci",
            "--rc-pass", password,
        ]
    }

    static func close() { endpoint = nil }

    /// 空いている港を訊く。0 番で開くと OS が選んでくれるので、それを聞いてすぐ閉じる。
    /// 閉じてから rclone が開くまでの隙間に他人が入る目は残るが、実用上はこれで足りる
    private static func freePort() -> UInt16 {
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        guard handle >= 0 else { return 5572 }
        defer { Darwin.close(handle) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_ANY.bigEndian
        address.sin_port = 0

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return 5572 }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let asked = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(handle, $0, &length)
            }
        }
        guard asked == 0 else { return 5572 }

        return UInt16(bigEndian: address.sin_port)
    }

    // MARK: - 問い合わせ

    /// 口を叩く。返事が無いのは普通のこと（起動直後・落ちた後）なので、失敗は nil で返す
    static func call(
        _ path: String, timeout: TimeInterval = 3,
        completion: @escaping ([String: Any]?) -> Void
    ) {
        guard let endpoint else { return completion(nil) }
        guard let url = URL(string: "http://127.0.0.1:\(endpoint.port)/\(path)") else {
            return completion(nil)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let credentials = Data("\(endpoint.user):\(endpoint.password)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return completion(nil) }
            completion(json)
        }.resume()
    }

    // MARK: - 訊きたいこと

    /// キャッシュの様子。`--vfs-cache-mode` が off でなければ `diskCache` が付く
    struct DiskCache {
        let bytesUsed: Int64
        let files: Int
        let uploadsInProgress: Int
        let uploadsQueued: Int

        /// まだ Drive へ上げ終えていないものがあるか。消す前に必ず訊く
        var hasPendingUploads: Bool { uploadsInProgress > 0 || uploadsQueued > 0 }
    }

    /// 今どこかを取りに行っているか。
    ///
    /// `core/stats` の `transferring` に、取りに行っている最中のファイルが並ぶ。
    /// 手元で測ったところ、読み始めてから 2 秒ほどで載り、読み終わると消える。
    /// 速さは最初の数秒 0 のままなので、速さではなく件数で見る
    static func transferring(completion: @escaping (Int) -> Void) {
        call("core/stats") { json in
            completion((json?["transferring"] as? [[String: Any]])?.count ?? 0)
        }
    }

    static func diskCache(completion: @escaping (DiskCache?) -> Void) {
        call("vfs/stats") { json in
            guard let cache = json?["diskCache"] as? [String: Any] else { return completion(nil) }
            completion(
                DiskCache(
                    bytesUsed: (cache["bytesUsed"] as? NSNumber)?.int64Value ?? 0,
                    files: (cache["files"] as? NSNumber)?.intValue ?? 0,
                    uploadsInProgress: (cache["uploadsInProgress"] as? NSNumber)?.intValue ?? 0,
                    uploadsQueued: (cache["uploadsQueued"] as? NSNumber)?.intValue ?? 0))
        }
    }
}
