import Foundation
import Combine
import CallKit
import AVFoundation
import LiveKit
import AgentRingCore

@MainActor
final class CallManager: NSObject, ObservableObject, CXProviderDelegate {
    @Published private(set) var callID: String?
    var isBusy: Bool { uuid != nil }
    @Published private(set) var label = ""
    @Published private(set) var muted = false
    @Published private(set) var speakerEnabled = false
    @Published private(set) var connectedAt: Date?
    private let provider: CXProvider
    private let controller = CXCallController()
    private unowned let state: AppState
    @Published private var uuid: UUID?
    private var incoming = false
    private var accepted = false
    private var timer: Timer?
    private var room: Room?
    private var seen = Set<String>()
    private var connectionTask: Task<Void, Never>?

    init(state: AppState) {
        self.state = state
        let config = CXProviderConfiguration()
        config.supportsVideo = false; config.maximumCallGroups = 1; config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]; config.includesCallsInRecents = false
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: .main)
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
        try? AudioManager.shared.setEngineAvailability(.none)
    }

    func receive(_ event: RelayEvent, completion: @escaping () -> Void = {}) {
        guard let id = event.call_id else { rejectPush(completion: completion); return }
        // A duplicate PushKit invite still goes through CallKit (which rejects its UUID as already reported).
        if id == callID, let uuid {
            provider.reportNewIncomingCall(with: uuid, update: update(event.agent_name ?? "Agent")) { _ in completion() }
            return
        }
        guard callID == nil, !seen.contains(id), event.direction == "agent_to_user",
              (event.expires_at ?? 0) > Date().timeIntervalSince1970 * 1000 else {
            rejectPush(completion: completion); return
        }
        let uuid = UUID()
        self.uuid = uuid; callID = id; incoming = true; accepted = false
        label = event.agent_name ?? "Agent"; seen.insert(id)
        provider.reportNewIncomingCall(with: uuid, update: update(label)) { [weak self] error in
            DispatchQueue.main.async {
                if error != nil { self?.reset() }
                completion()
            }
        }
        let interval = max(0.1, (event.expires_at! / 1000) - Date().timeIntervalSince1970)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finish(reason: .unanswered) }
        }
        state.start()
        Task {
            do { _ = try await state.api().data("/v1/calls/\(id)/ringing", method: "POST") }
            catch { state.error = error.localizedDescription; finish(reason: .failed) }
        }
    }
    private func update(_ name: String) -> CXCallUpdate {
        let update = CXCallUpdate(); update.remoteHandle = CXHandle(type: .generic, value: name)
        update.localizedCallerName = name; update.hasVideo = false
        update.supportsHolding = false; update.supportsGrouping = false; update.supportsUngrouping = false
        update.supportsDTMF = false
        return update
    }
    // Every delivered VoIP push must be reported synchronously, including invalid/stale payloads.
    func rejectPush(completion: @escaping () -> Void) {
        let id = UUID()
        provider.reportNewIncomingCall(with: id, update: update("Unavailable call")) { [weak self] _ in
            self?.provider.reportCall(with: id, endedAt: Date(), reason: .failed)
            completion()
        }
    }
    func event(_ event: RelayEvent) {
        if event.type == "call.invite", event.direction == "agent_to_user", event.call_id != callID,
           !seen.contains(event.call_id ?? ""), (event.expires_at ?? 0) > Date().timeIntervalSince1970 * 1000 {
            receive(event)
        }
        guard event.call_id == callID else { return }
        if event.type == "call.end" || event.type == "call.missed" { finish(reason: event.type == "call.missed" ? .unanswered : .remoteEnded) }
        if event.type == "call.decline", event.by == "agent" { finish(reason: .remoteEnded) }
        if event.type == "call.accept", event.by == "agent", let uuid {
            provider.reportOutgoingCall(with: uuid, connectedAt: Date()); label = "Connected"
        }
    }
    func reconcile(_ call: RelayCall) {
        guard call.call_id == callID else { return }
        if !["ringing", "active"].contains(call.state) { finish(reason: .remoteEnded) }
        else if !incoming, call.state == "active", let uuid {
            provider.reportOutgoingCall(with: uuid, connectedAt: Date()); label = "Connected"
        }
    }
    func startOutgoing() async throws {
        guard callID == nil, uuid == nil else { return }
        let permission = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard permission else { throw RelayError.http(403, "Enable microphone access in Settings") }
        let id = UUID(); uuid = id; incoming = false; accepted = false; label = "Calling…"
        do { try await controller.request(CXTransaction(action: CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: state.credentials?.agent_name ?? "Agent")))) }
        catch { reset(); throw error }
    }
    func end() async throws {
        guard let uuid else { return }
        try await controller.request(CXTransaction(action: CXEndCallAction(call: uuid)))
    }
    func toggleMute() async throws {
        guard let uuid else { return }
        try await controller.request(CXTransaction(action: CXSetMutedCallAction(call: uuid, muted: !muted)))
    }
    func speaker(_ enabled: Bool) throws {
        try AVAudioSession.sharedInstance().overrideOutputAudioPort(enabled ? .speaker : .none)
        speakerEnabled = enabled
    }
    private func configureAudio() throws {
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
    }
    private func connect(_ join: JoinInfo, uuid: UUID) async throws {
        guard self.uuid == uuid else { throw CancellationError() }
        guard URL(string: join.livekit_url)?.scheme == "wss" else { throw RelayError.invalidURL }
        try configureAudio()
        let room = Room(); self.room = room
        try await room.connect(url: join.livekit_url, token: join.livekit_token)
        guard self.uuid == uuid, !Task.isCancelled else { await room.disconnect(); throw CancellationError() }
        try await room.localParticipant.setMicrophone(enabled: true)
        if connectedAt == nil { connectedAt = Date() }
        label = "Connected"
    }
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let id = callID, action.callUUID == uuid else { action.fail(); return }
        timer?.invalidate()
        connectionTask = Task {
            do {
                let result: CallWithJoin = try await state.api().get("/v1/calls/\(id)/accept", method: "POST")
                accepted = true
                try await connect(result.join, uuid: action.callUUID)
                label = "Connected"; if connectedAt == nil { connectedAt = Date() }; action.fulfill()
            } catch { action.fail(); state.error = error.localizedDescription; await cleanupRemote(id); finish(reason: .failed) }
        }
    }
    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        connectionTask = Task {
            do {
                let result: CallWithJoin = try await state.api().get("/v1/calls", method: "POST", body: [:])
                guard self.uuid == action.callUUID else { await cleanupRemote(result.call.call_id); action.fail(); return }
                callID = result.call.call_id; accepted = true; state.start()
                try await connect(result.join, uuid: action.callUUID)
                provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date()); action.fulfill()
            } catch { action.fail(); state.error = error.localizedDescription; if let id = callID { await cleanupRemote(id) }; finish(reason: .failed) }
        }
    }
    private func cleanupRemote(_ id: String) async {
        let endpoint = incoming && !accepted ? "decline" : "end"
        do { _ = try await state.api().data("/v1/calls/\(id)/\(endpoint)", method: "POST") }
        catch { state.error = error.localizedDescription }
    }
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard action.callUUID == uuid else { action.fail(); return }
        let id = callID
        Task {
            if let id { await cleanupRemote(id) }
            reset(); action.fulfill()
        }
    }
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        guard action.callUUID == uuid, let room else { action.fail(); return }
        Task {
            do { try await room.localParticipant.setMicrophone(enabled: !action.isMuted); muted = action.isMuted; action.fulfill() }
            catch { state.error = error.localizedDescription; action.fail() }
        }
    }
    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        action.fail()
        let id = callID
        Task { if let id { await cleanupRemote(id) }; finish(reason: .failed) }
    }
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        do { try AudioManager.shared.setEngineAvailability(.default) }
        catch { state.error = error.localizedDescription; finish(reason: .failed) }
    }
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        try? AudioManager.shared.setEngineAvailability(.none)
    }
    func providerDidReset(_ provider: CXProvider) {
        let id = callID
        Task { if let id { await cleanupRemote(id) }; reset() }
    }
    private func finish(reason: CXCallEndedReason) {
        if let uuid { provider.reportCall(with: uuid, endedAt: Date(), reason: reason) }
        reset()
    }
    func reset() {
        connectionTask?.cancel(); connectionTask = nil; timer?.invalidate(); timer = nil
        if let room { Task { await room.disconnect() } }; room = nil
        callID = nil; uuid = nil; muted = false; speakerEnabled = false; connectedAt = nil; accepted = false; label = ""
        try? AudioManager.shared.setEngineAvailability(.none)
        state.callFinished()
    }
}
