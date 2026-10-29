import SwiftUI
import UserNotifications
import AVFoundation
import AgentRingCore

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var credentials = CredentialStore.load()
    @Published var messages: [Message] = []
    @Published var callHistory: [RelayCall] = []
    @Published var connected = false
    @Published var agentOnline = false
    @Published var error: String?
    @Published var busy = false
    @Published var pushStatus = "Registering with Apple…"
    lazy var calls = CallManager(state: self)
    private var socket: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private var lastSeq = 0
    private var foreground = false
    private var alertToken: String?
    private var voipToken: String?
    private var tokenUpdate: Task<Void, Never>?

    func api() throws -> RelayAPI {
        guard let c = credentials else { throw RelayError.http(401, "Pair this iPhone first") }
        return try RelayAPI(url: c.relayURL, jwt: c.device_jwt)
    }
    func pair(_ text: String) async throws {
        guard credentials == nil else { return }
        let qr = try PairingQR.parse(text)
        let api = try RelayAPI(url: qr.relay_url)
        let pair: PairResponse = try await api.get("/v1/pair", method: "POST", body: [
            "pairing_token": qr.pairing_token, "device_name": String(UIDevice.current.name.prefix(64)),
            "platform": "ios", "app_version": "0.2.0"])
        let c = Credentials(relayURL: qr.relay_url, pair: pair)
        try CredentialStore.save(c)
        credentials = c; lastSeq = 0
        let mic = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
        }
        if !mic { error = "Enable microphone access in Settings to talk on calls." }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        UIApplication.shared.registerForRemoteNotifications()
        updateTokens(); start()
    }
    func setToken(_ token: String?, voip: Bool) {
        if voip { voipToken = token } else { alertToken = token }
        updateTokens()
    }
    func updateTokens() {
        tokenUpdate?.cancel()
        guard credentials != nil else { return }
        let body: [String: Any] = ["alert_token": alertToken as Any? ?? NSNull(),
                                   "voip_token": voipToken as Any? ?? NSNull(),
                                   "environment": Bundle.main.object(forInfoDictionaryKey: "APNSEnvironment") as? String ?? "sandbox"]
        tokenUpdate = Task {
            do {
                _ = try await api().data("/v1/device/apns", method: "POST", body: body)
                if !Task.isCancelled { pushStatus = voipToken == nil ? "Waiting for a VoIP token (real iPhone required)" : "VoIP token registered" }
            } catch { if !Task.isCancelled { pushStatus = error.localizedDescription } }
        }
    }
    func setForeground(_ active: Bool) {
        foreground = active
        if active { start() }
        else if calls.callID == nil { stop() }
    }
    func callFinished() { if !foreground { stop() } }
    func start() {
        guard loop == nil, credentials != nil else { return }
        loop = Task {
            var delay: UInt64 = 1
            while !Task.isCancelled && credentials != nil {
                do {
                    let ws = try api().socket(after: lastSeq)
                    socket = ws; ws.resume()
                    try await refresh()
                    updateTokens()
                    connected = true; delay = 1
                    while !Task.isCancelled {
                        let frame = try await ws.receive()
                        let data: Data
                        switch frame { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: continue }
                        let event = try JSONDecoder().decode(RelayEvent.self, from: data)
                        await handle(event)
                        // Only advance after processing; a reconnect replays failures.
                        if let seq = event.seq { lastSeq = max(lastSeq, seq) }
                    }
                } catch {
                    connected = false
                    socket?.cancel(with: .goingAway, reason: nil)
                    if case RelayError.http(401, _) = error {
                        self.error = "This device was revoked. Pair again."
                        forget(); return
                    }
                    // Connection loss is represented inline; avoid repeated modal alerts
                    // while the phone changes networks or the server is unavailable.
                }
                do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { break }
                delay = min(delay * 2, 30)
            }
        }
    }
    func stop() {
        loop?.cancel(); loop = nil; socket?.cancel(with: .goingAway, reason: nil); socket = nil; connected = false
    }
    func forget() {
        stop(); tokenUpdate?.cancel(); calls.reset(); CredentialStore.clear(); credentials = nil; messages = []; callHistory = []; lastSeq = 0
    }
    func unpair() async throws {
        _ = try await api().data("/v1/device/apns", method: "POST", body: [
            "alert_token": NSNull(), "voip_token": NSNull(), "environment": "sandbox"])
        forget()
    }
    func refresh() async throws {
        let api = try api()
        let status: RelayStatus = try await api.get("/v1/status")
        agentOnline = status.agent_online
        if !status.push_provider.contains("apns") { pushStatus = "Relay has no APNs configured; background calls unavailable" }
        if let id = calls.callID {
            let call: RelayCall = try await api.get("/v1/calls/\(id)")
            calls.reconcile(call)
        }
        var collected: [Message] = []
        var after = ""
        repeat {
            let page: MessagePage = try await api.get("/v1/messages?limit=500" + (after.isEmpty ? "" : "&after=\(after)"))
            collected.append(contentsOf: page.messages)
            guard page.has_more, let last = page.messages.last else { break }
            after = last.msg_id
        } while !Task.isCancelled
        messages = collected
        let history: CallPage = try await api.get("/v1/calls?limit=100")
        callHistory = history.calls
    }
    func send(_ text: String, replyTo: String? = nil) async throws {
        var body: [String: Any] = ["text": text, "client_msg_id": UUID().uuidString]
        if let replyTo { body["reply_to"] = replyTo }
        let _: Message = try await api().get("/v1/messages", method: "POST", body: body)
        try await refresh()
    }
    func read(_ message: Message) async {
        guard message.from == "agent", message.read_at == nil else { return }
        do { _ = try await api().data("/v1/messages/\(message.msg_id)/read", method: "POST") }
        catch { self.error = error.localizedDescription }
    }
    func handle(_ event: RelayEvent) async {
        if event.type == "agent.presence" { agentOnline = event.online ?? false }
        if event.type.hasPrefix("call.") {
            calls.event(event)
            if event.type == "call.end" || event.type == "call.missed" {
                do { try await refresh() } catch { self.error = error.localizedDescription }
            }
        }
        if event.type.hasPrefix("msg.") {
            do { try await refresh() } catch { self.error = error.localizedDescription }
        }
    }
    func run(_ operation: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { try await operation() } catch { self.error = error.localizedDescription }
        }
    }
}
