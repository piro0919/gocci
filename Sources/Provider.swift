import FileProvider
import Foundation
import OSLog

private let providerLogger = Logger(subsystem: "io.kkweb.gocci", category: "provider")

// Drive を「クラウドのフォルダ」として繋ぐ側の世話役。
//
// これまでのマウント（`MountController`）と役割は同じだが、やることが違う。
// 場所を借りて NFS を張るのではなく、macOS へ「ここにクラウドのフォルダがあります」と
// 申し出る。実際の置き場所は macOS が決め、`~/Library/CloudStorage` の下に現れる。
//
// rclone は残る。ただしマウントは張らせず、`rcd` で問い合わせ口だけ開けておく。
// 拡張はその口を叩いて一覧と中身を取る。

@MainActor
final class Provider {
    static let shared = Provider()

    enum State: Equatable {
        case off
        case starting
        case on
        case failed(String)
    }

    private(set) var state: State = .off {
        didSet {
            guard state != oldValue else { return }
            providerLogger.info("状態: \(String(describing: oldValue), privacy: .public) → \(String(describing: self.state), privacy: .public)")
            NotificationCenter.default.post(name: .providerStateChanged, object: nil)
        }
    }

    /// 口だけ開けた rclone。マウントは張らない
    private var rclone: Process?

    private static let domainIdentifier = NSFileProviderDomainIdentifier("gocci")

    // MARK: - 繋ぐ

    func start() {
        guard state == .off || isFailed(state) else { return }
        state = .starting

        guard let path = MountController.rclonePath else {
            state = .failed("rclone が見つかりません")
            return
        }

        // `rcd` は口を開けるのが仕事なので `--rc` は渡さない
        let port = Rc.prepare(alongsideMount: false)
        guard let endpoint = Rc.endpoint else {
            state = .failed("問い合わせ口を作れませんでした")
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = ["rcd"] + port

        // 黙らせない。ここを捨てていたせいで、`--rc` を弾かれていたことに気づけなかった
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard !text.isEmpty else { return }
            providerLogger.info("rclone: \(text, privacy: .public)")
        }

        do {
            try task.run()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        rclone = task

        // 中身を配る口も開ける。範囲を指定して取るために、こちらは HTTP にする。
        // 口が立つまで少し待つ。rcd が受け付けを始める前に頼むと届かない
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.startContentServer(endpoint: endpoint)
        }
    }

    /// 中身を配る口。`serve/start` を rcd に頼んで立てる
    private func startContentServer(endpoint: (port: UInt16, user: String, password: String)) {
        let contentPort = Rc.freePort()
        let client = RcClient(
            connection: RcEndpoint.Connection(
                port: endpoint.port, user: endpoint.user, password: endpoint.password,
                remote: Settings.remote + ":", contentPort: contentPort))

        client.startHTTPServer(on: contentPort) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    providerLogger.error(
                        "中身を配る口を開けなかった: \(error.localizedDescription, privacy: .public)")
                    self.state = .failed(error.localizedDescription)
                case .success:
                    // 拡張は設定を読めない。どこへ訊けばいいかを控えに書く
                    RcEndpoint.write(
                        port: endpoint.port, user: endpoint.user, password: endpoint.password,
                        remote: Settings.remote + ":", contentPort: contentPort)
                    self.addDomain()
                }
            }
        }
    }

    /// macOS へ申し出る。ここを通ると Finder のサイドバーに現れる
    private func addDomain() {
        let domain = NSFileProviderDomain(
            identifier: Self.domainIdentifier, displayName: "Gocci")

        NSFileProviderManager.add(domain) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    providerLogger.error(
                        "繋げなかった: \(error.localizedDescription, privacy: .public)")
                    self.state = .failed(error.localizedDescription)
                } else {
                    providerLogger.info("繋がった")
                    self.state = .on
                }
            }
        }
    }

    // MARK: - 外す

    func stop(completion: (() -> Void)? = nil) {
        NSFileProviderManager.getDomainsWithCompletionHandler { domains, _ in
            let mine = domains.filter { $0.identifier == Self.domainIdentifier }
            guard let target = mine.first else {
                Task { @MainActor in
                    self.finishStopping()
                    completion?()
                }
                return
            }
            NSFileProviderManager.remove(target) { error in
                Task { @MainActor in
                    if let error {
                        providerLogger.error(
                            "外せなかった: \(error.localizedDescription, privacy: .public)")
                    } else {
                        providerLogger.info("外した")
                    }
                    self.finishStopping()
                    completion?()
                }
            }
        }
    }

    private func finishStopping() {
        rclone?.terminate()
        rclone = nil
        // 古い口を叩き続けないように、控えも消す
        RcEndpoint.clear()
        Rc.close()
        state = .off
    }

    private func isFailed(_ state: State) -> Bool {
        if case .failed = state { return true }
        return false
    }
}

extension Notification.Name {
    static let providerStateChanged = Notification.Name("gocci.providerStateChanged")
}
