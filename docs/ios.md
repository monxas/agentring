# iOS companion (preview)

`app-ios/AgentRing.xcodeproj` contains the native SwiftUI iPhone app (iOS 16+).
It pairs with the existing QR payload, stores device credentials in the Keychain,
reads and replies to messages, and uses CallKit, PushKit and LiveKit for voice calls.
The daemon and agent integrations are unchanged. The relay supports Android and iOS
at the same time; iOS-only installations do not need Firebase.

This is a development preview: the relay and Swift protocol core have automated
tests, and the complete app builds for arm64 iPhones in CI. End-to-end calling must still be verified on an actual iPhone.
Do not treat locked-phone ringing or audio as hardware-validated yet.

## Apple setup

1. Use Xcode 16.3 or later. Complete Xcode's first-run setup and accept its license
   yourself if prompted. Open `app-ios/AgentRing.xcodeproj`.
2. Select the AgentRing target, choose your signing team, and change the bundle
   identifier to one registered in your Apple Developer account. Enable Push
   Notifications for that identifier. The project already declares audio, VoIP
   and remote-notification background modes.
3. Configure an APNs signing key in the Apple Developer portal for the app. Keep
   the downloaded `.p8` private. Record its key ID and your team ID. Background
   push testing requires the appropriate Apple Developer membership and a real
   device with a matching provisioning profile.
4. The Debug build uses the APNs sandbox (`aps-environment=development`); Release
   uses production. `APNSEnvironment` in Info.plist supplies the corresponding
   relay registration value. If you change signing profiles, keep both values
   aligned. TestFlight and distribution builds use production.
5. Run on your iPhone. Allow microphone and notification access when pairing.
   Camera access is used only for QR scanning. Alternatively paste the raw QR JSON.

The app requires HTTPS with a trusted certificate for the relay and WSS for
LiveKit. For local development, put a trusted TLS proxy in front of the existing
local compose stack. The Android-only HTTP LAN shortcut is not enabled on iOS.

## Relay setup

Upgrade the relay with this branch. Its SQLite migration preserves existing
Android devices. Existing API endpoints and FCM routing continue to work.

Mount your key read-only into the relay container (the compose files already mount
`/secrets`) and add the following to its environment or compose `.env`:

```dotenv
APNS_KEY_FILE=/secrets/AuthKey_EXAMPLE.p8
APNS_KEY_ID=EXAMPLE123
APNS_TEAM_ID=TEAM123456
APNS_BUNDLE_ID=your.registered.bundle.identifier
```

The bundle identifier must match the app exactly. The relay uses the `.voip` topic
suffix automatically for incoming-call pushes. Keep the `.p8` out of git and app
bundles. The key file must be readable by the relay container user. Restart the
relay after setting the environment. For an iOS-only installation, leave the FCM
variables empty (remove the hard-coded FCM entries in the proxy compose variant).
LiveKit still needs its existing server URL, API credentials and working media ports.

## Try it

```bash
agentring pair
# Scan the QR with the iPhone app.
agentring msg "Hello iPhone"
agentring call "Testing the iOS companion" --ai
```

The app's settings menu shows push registration status. Confirm that it says
`VoIP token registered`, and that `/v1/status` reports `apns` (or `fcm+apns`).
Run `agentring serve --ai` to receive calls placed with the app's **Call agent**
button. Messages can be replied to in the app; long-press a message to reply to
that specific message. Reading a message sends its read receipt.

Before relying on it, verify on an actual device:

- Lock the iPhone, let the app leave the foreground, and trigger an agent call.
  Answer from the system call UI; check two-way audio.
- Mute/unmute, route to speaker/Bluetooth, and hang up from both ends.
- Cancel before answering, let a call time out, and decline a call.
- Call the agent from the app, including agent-offline and busy cases.
- Reconnect Wi-Fi/cellular and reopen the app; confirm message catch-up.
- Use a targeted call with another Android/iOS phone and confirm privacy.
- Revoke the iPhone using the existing agent device-revocation API; no further
  pushes should be sent and API requests must fail authentication.

CallKit respects the device's Focus/Do Not Disturb settings; an urgent agentring
priority does not override them. This preview does not provide notification
inline replies, an in-app join button for an already active group call, CallKit
Recents redial, or App Store distribution assets.

## Transport and security

Apple requires each delivered VoIP push to be reported promptly to CallKit.
Only `call.invite` is sent over the VoIP channel. Cancellation, acceptance, end
and missed-call events use the resumable authenticated WebSocket established
when the call arrives. A local expiry timer dismisses an unanswered incoming
call even if the socket drops. APNs expiration is zero, so calls are not queued
for delivery after the phone reconnects. The app reconciles state through REST
on reconnection. Multiple paired phones may answer according to the relay's
existing group-call rules.

The relay sends messages through ordinary APNs alert notifications. Custom fields
carry the same HMAC-signed event envelope as Android. Incoming VoIP envelopes
are verified against the paired relay and secret before handling the call.
An invalid, stale or duplicate VoIP payload is reported to CallKit and immediately
ended (or rejected by CallKit as an existing UUID) to satisfy PushKit's reporting
contract. Ordinary notification previews are displayed by iOS; this app has no
notification service extension to verify signatures before that display.

Credentials use `AfterFirstUnlockThisDeviceOnly` Keychain accessibility so a
legitimate VoIP wake can read them while locked after the first device unlock.
The app rejects cleartext URLs, URL credentials and HTTP redirects. LiveKit tokens
are fetched only after the user answers and are never placed in push payloads.

References: [Apple PushKit/CallKit requirements](https://developer.apple.com/documentation/pushkit/responding-to-voip-notifications-from-pushkit),
[LiveKit audio configuration](https://github.com/livekit/client-sdk-swift/blob/2.19.0/Docs/audio.md).

## Development checks

```bash
cd relay && npm ci && npm run typecheck && npm test && npm run build
cd app-ios && swift test
xcodebuild -project AgentRing.xcodeproj -scheme AgentRing \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

The core Swift package tests use the shared protocol event fixtures and HMAC
signature vector. Relay tests cover APNs HTTP/2 headers and provider JWTs, token
rotation/revocation, platform validation and targeted calls. Unsigned device builds do not validate background VoIP delivery, CallKit timing or microphone routing.

LiveKit Swift is pinned to 2.19.0 despite being less than two weeks old because
that release updates WebRTC to remove compromised eMudhra roots. See its
[release notes](https://github.com/livekit/client-sdk-swift/releases/tag/2.19.0).

### Local validation (2026-10-29)

- Relay: typecheck/build passed; 49 tests passed, including 13 new APNs/iOS tests
  plus the APNs configuration test.
- Daemon: 37 tests passed, 2 live-service tests skipped.
- Swift protocol core: compiled successfully; all 3 XCTest cases passed using
  Xcode's XCTest runner with the Command Line Tools SDK.
- App Swift sources passed the compiler's syntax parsing; project and property
  lists passed `plutil -lint`. These checks do not replace compiling/linking the app.
- Relay production dependency audit: zero reported vulnerabilities (`npm audit --omit=dev`).
- Full arm64 iPhone build passed in [GitHub Actions](https://github.com/monxas/agentring/actions/runs/40964308597). The artifact is an unsigned device app (not a simulator build).
- The iOS CI workflow builds an unsigned arm64 iPhone app. Hardware verification still requires local signing and installation.

### Install a CI device build without rebuilding LiveKit locally

The iOS workflow publishes `AgentRing-iPhone`, containing `AgentRing-iphone.zip`.
After downloading and extracting it on a Mac with Xcode and a valid Apple
Developer account, run:

```bash
python3 scripts/install-ios-device.py /path/to/AgentRing.app \
  --device YOUR_IPHONE_UDID --team YOUR_TEAM_ID --bundle-id your.registered.bundle.identifier
```

The helper builds a tiny local signing target with matching capabilities so Xcode
can provision the selected physical iPhone. It copies that development profile and
entitlements into the CI app, signs the app and its embedded frameworks, verifies
the signature, and installs and launches it with `devicectl`. The helper is never
installed. Apple signing keys stay in the local Keychain. Generated files live in
`.build/ios-device-signing`; no simulator is used.

### Physical-device validation (2026-10-29)

The CI-built arm64 app was signed locally with a development profile, installed
and launched on an iPhone 16 Pro running iOS 27.2. Its process remained alive
under `devicectl --console` after startup. The installer signs embedded `.dylib`
files as well as frameworks; unsigned debug dylibs otherwise cause an immediate
dyld exit even when installation itself succeeds. The signed app passes
`codesign --verify --deep --strict`.

Pairing with a real relay, background APNs/PushKit delivery and two-way call audio
still require end-to-end verification. No relay or APNs provider key has been
configured on behalf of this installation.

If Xcode's account session cannot provision automatically, use a development
profile downloaded manually from your Apple Developer account. The profile must
match your team, exact bundle identifier and physical iPhone, and enable Push
Notifications:

```bash
python3 scripts/install-ios-device.py /path/to/AgentRing.app \
  --device YOUR_IPHONE_UDID --team YOUR_TEAM_ID --bundle-id your.bundle.identifier \
  --profile /path/to/Development.mobileprovision
```

The profile embeds its public development certificate. When needed, `--key`
imports the corresponding locally generated private key and that certificate
into the login Keychain. It does not upload the private key. The temporary PKCS#12
file is encrypted with a random password and deleted after import. On macOS the
helper uses the system OpenSSL implementation for Keychain-compatible PKCS#12.

### Native interface refresh (2026-10-30)

The companion now has native conversation, recent-call and settings tabs, with
adaptive system surfaces, dark mode, Dynamic Type, semantic accessibility labels,
a dedicated call sheet and a persistent active-call banner. Conversation messages
use separate bubbles, date separators, read states, reply/copy menus and a keyboard
composer. Recent calls come from the existing authenticated `/v1/calls` endpoint;
no protocol or relay migration is needed. Reconnection stays inline rather than
repeatedly opening alerts. The native icon is an original waveform/ring asset.

Device build2 passed the complete iPhone CI build and was signed/installed over
the existing `com.monxas.agentring` app with the same team and Keychain access.
Launch/visual validation is pending an unlocked physical phone. No simulator was
used. CI: https://github.com/monxas/agentring/actions/runs/40976692212 .
