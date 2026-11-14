import SwiftUI
import PushKit
import UserNotifications
import AgentRingCore

@main
struct AgentRingApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppState.shared
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            ContentView(state: state)
                .onChange(of: phase) { state.setForeground($0 == .active) }
                .onAppear { state.setForeground(true) }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, PKPushRegistryDelegate, UNUserNotificationCenterDelegate {
    private var registry: PKPushRegistry?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = AppState.shared.calls
        let registry = PKPushRegistry(queue: .main); self.registry = registry
        registry.delegate = self; registry.desiredPushTypes = [.voIP]
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        AppState.shared.setToken(deviceToken.hex, voip: false)
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        AppState.shared.pushStatus = "Apple push registration failed: \(error.localizedDescription)"
    }
    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        if type == .voIP { AppState.shared.setToken(pushCredentials.token.hex, voip: true) }
    }
    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        if type == .voIP { AppState.shared.setToken(nil, voip: true) }
    }
    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        let state = AppState.shared
        guard type == .voIP, let credentials = state.credentials else { state.calls.rejectPush(completion: completion); return }
        let strings = payload.dictionaryPayload.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
        }
        do {
            let event = try PushVerifier.verify(strings, relayID: credentials.relay_id, secret: credentials.push_secret)
            guard event.type == "call.invite" else { throw RelayError.invalidPush }
            state.calls.receive(event, completion: completion)
        } catch { state.calls.rejectPush(completion: completion) }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
        AppState.shared.start()
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        AppState.shared.start(); completionHandler()
    }
}
private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
