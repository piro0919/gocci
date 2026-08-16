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

    /// 内蔵に置くときの識別子。外付けに置くと macOS が別の識別子を振るので、決め打てない
    private static let builtInIdentifier = NSFileProviderDomainIdentifier("gocci")
    /// こちらの持ち物だと見分けるための印。外付けの識別子は毎回変わる
    private static let mark = "io.kkweb.gocci"

    /// 今ある繋ぎを探す
    private func currentDomain(completion: @escaping (NSFileProviderDomain?) -> Void) {
        NSFileProviderManager.getDomainsWithCompletionHandler { domains, _ in
            // 外付けに置くと macOS が `NSFPExternal-…` という識別子を振る。`userInfo` の印は
            // 読み返せなかったので、名前で見分ける。ここを取り違えると、自分が作った繋ぎを
            // 他人のものと見なして、内蔵にもう一つ作ってしまう（2026-08-17 実測）
            let mine = domains.first { domain in
                domain.identifier == Self.builtInIdentifier
                    || (domain.identifier.rawValue.hasPrefix("NSFPExternal-")
                        && domain.displayName == "Gocci")
            }
            completion(mine)
        }
    }

    /// 人から見える場所。macOS が決めるので、こちらでは訊くだけ
    func visibleURL(completion: @escaping (URL?) -> Void) {
        currentDomain { domain in
            guard let domain, let manager = NSFileProviderManager(for: domain) else {
                Task { @MainActor in completion(nil) }
                return
            }
            Task {
                let url = try? await manager.getUserVisibleURL(for: .rootContainer)
                await MainActor.run { completion(url) }
            }
        }
    }

    // MARK: - 繋ぐ

    func start() {
        guard state == .off || isFailed(state) else { return }
        state = .starting

        guard let path = Rclone.path else {
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
                    self.startWatching()
                }
            }
        }
    }

    /// macOS へ申し出る。ここを通ると Finder に現れる。
    ///
    /// 置き場所を選んでいれば、そのボリュームに置く（macOS 15 から）。
    ///
    /// 毎回、自分の繋ぎを全部外してから作り直す。「合っているかどうか」を見て残す作りにも
    /// してみたが、内蔵と外付けの両方が残って互いの邪魔をした。判断を挟まないほうが確実
    private func addDomain() {
        NSFileProviderManager.getDomainsWithCompletionHandler { [weak self] domains, _ in
            guard let self else { return }

            let mine = domains.filter {
                $0.identifier == Self.builtInIdentifier
                    || ($0.identifier.rawValue.hasPrefix("NSFPExternal-")
                        && $0.displayName == "Gocci")
            }
            providerLogger.info(
                "今ある繋ぎ: \(domains.count) 件、うち自分のもの \(mine.count) 件")

            let group = DispatchGroup()
            for domain in mine {
                group.enter()
                providerLogger.info("外す: \(domain.identifier.rawValue, privacy: .public)")
                NSFileProviderManager.remove(domain) { error in
                    if let error {
                        providerLogger.error(
                            "外せなかった: \(error.localizedDescription, privacy: .public)")
                    }
                    group.leave()
                }
            }

            // 外した直後に作ると `513` で断られる。macOS 側の後片付けを待つ
            group.notify(queue: .main) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    Task { @MainActor in self.createDomain() }
                }
            }
        }
    }

    private func createDomain() {
        let volume = Settings.volume
        let domain: NSFileProviderDomain

        if !volume.isEmpty, #available(macOS 15.0, *) {
            domain = NSFileProviderDomain(
                displayName: "Gocci", userInfo: ["owner": Self.mark],
                volumeURL: URL(fileURLWithPath: volume))
            providerLogger.info("外付けに作る: 「\(volume, privacy: .public)」")
        } else {
            domain = NSFileProviderDomain(
                identifier: Self.builtInIdentifier, displayName: "Gocci")
            providerLogger.info("内蔵に作る")
        }

        NSFileProviderManager.add(domain) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    let ns = error as NSError
                    providerLogger.error(
                        "繋げなかった: \(ns.domain, privacy: .public) \(ns.code) / \(ns.userInfo.description, privacy: .public)")
                    self.state = .failed(error.localizedDescription)
                } else {
                    providerLogger.info(
                        "繋がった: \(domain.identifier.rawValue, privacy: .public)")
                    self.state = .on
                    self.visibleURL { url in
                        providerLogger.info(
                            "見える場所: \(url?.path ?? "分からない", privacy: .public)")
                    }
                }
            }
        }
    }

    /// 手元に降りてきた実体を、まとめて捨てる。Drive のファイルはそのまま残る。
    ///
    /// 根に頼むと、その下は再帰的に片付く（`NSFileProviderManager.h` 470-471行）。
    ///
    /// Finder の右クリックにも「ダウンロードを削除」があるはずだが、こちらの拡張では
    /// 出ていない。理由は未確認。出ないままだと手元を空ける手立てが無くなるので、
    /// アプリ側にも口を残す
    func evictDownloads(completion: @escaping (String?) -> Void) {
        currentDomain { domain in
            guard let domain, let manager = NSFileProviderManager(for: domain) else {
                Task { @MainActor in completion("繋がっていません") }
                return
            }
            self.evict(with: manager, completion: completion)
        }
    }

    private func evict(with manager: NSFileProviderManager, completion: @escaping (String?) -> Void) {
        manager.evictItem(identifier: .rootContainer) { error in
            Task { @MainActor in
                // 消せないものが混じっていると `-2006` が返るが、消せた分は消えている。
                // 書き込みの途中や、まだ上げ終えていないものがそれにあたる。
                // 全部が失敗したかのように見せると、実際に空いたことが伝わらない
                if let error, (error as NSError).code != NSFileProviderError.nonEvictableChildren.rawValue {
                    providerLogger.error(
                        "手元から消せなかった: \(String(describing: error), privacy: .public)")
                    completion(error.localizedDescription)
                    return
                }
                if error != nil {
                    providerLogger.info("手元のダウンロードを空にした（消せないものは残した）")
                } else {
                    providerLogger.info("手元のダウンロードを空にした")
                }
                completion(nil)
            }
        }
    }


    // MARK: - Drive 側の変化

    private var watchTimer: Timer?
    /// 見に行く間隔。短くすると Drive を舐め続けることになる
    private static let watchInterval: TimeInterval = 60

    /// 「見直して」と macOS に言う。実際に何が変わったかは拡張が調べる。
    ///
    /// 声をかける先は作業組（`workingSet`）。ここが「一度でも見た場所」の集まりで、
    /// 親フォルダを開いていなくても変化を伝えられる口になっている
    /// （`NSFileProviderItem.h` 25-42行）。根に声をかけても何も起きない（実測）
    private func startWatching() {
        watchTimer?.invalidate()

        let timer = Timer.scheduledTimer(withTimeInterval: Self.watchInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.signal() }
        }
        watchTimer = timer
    }

    private func signal() {
        guard state == .on else { return }

        currentDomain { domain in
            guard let domain, let manager = NSFileProviderManager(for: domain) else { return }

            providerLogger.info("見直しを頼んだ")
            manager.signalEnumerator(for: .workingSet) { error in
                if let error {
                    providerLogger.error(
                        "見直しを頼めなかった: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    // MARK: - 外す

    func stop(completion: (() -> Void)? = nil) {
        currentDomain { target in
            guard let target else {
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
        watchTimer?.invalidate()
        watchTimer = nil
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
