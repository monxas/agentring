# Contributing

Thanks for helping. Bug reports, fixes, OEM notes and docs are all welcome.
For anything larger than a fix, open an issue first so we can agree on the
approach. Security problems: see [SECURITY.md](SECURITY.md), not public issues.

## Repository layout

```
protocol/       relay.openapi.yaml (REST + event schemas), examples/ (event fixtures, push signature vector)
relay/          TypeScript, Fastify 5, node:sqlite, jose, livekit-server-sdk; FCM HTTP v1 without firebase-admin
daemon/         Python ≥ 3.11 + uv; the `agentring` CLI and the `agentring.voice` library
app-ios/        SwiftUI iPhone preview, Swift protocol core, CallKit/PushKit and LiveKit
app-android/    :core = pure Kotlin/JVM (protocol models, PushVerifier, RelayApi, RelaySocket, RelayUrlPolicy)
                :app  = Compose / Material 3 app, package dev.agentring.app, minSdk 26, targetSdk 35
deploy/         docker compose files, Caddyfile, LiveKit config, .env.example
scripts/        ci-emulator-e2e.sh, device-test.sh
docs/           architecture, protocol, setup, Firebase, voice, OEM troubleshooting
```

Design background: [docs/architecture.md](docs/architecture.md) and
[docs/protocol.md](docs/protocol.md).

## Build and test

Requirements: Node ≥ 22.13, Python ≥ 3.11 with [uv](https://docs.astral.sh/uv/),
JDK 17 and the Android SDK for the app.

```bash
cd relay  && npm ci && npm run typecheck && npm test && npm run build
cd daemon && uv run --extra voice pytest -q   # needs relay/dist: the e2e tests start the real relay
cd app-android && ./gradlew :core:test :app:assembleDebug
cd app-android && ./gradlew -PcoreOnly :core:test   # when Google's Maven is unreachable
```

- `daemon/tests/test_voice_live.py` needs a LiveKit server and a Gemini key; see
  [docs/voice.md](docs/voice.md#testing).
- `scripts/device-test.sh [apk]` installs and tests on a USB-connected phone
  (`--instrumented` runs the instrumented test; the phone must be unlocked).
- CI (`.github/workflows/`) runs the relay and daemon tests, a docker compose
  smoke test, and builds the APK and runs an end-to-end test on an Android
  emulator against a real relay.

iOS: `cd app-ios && swift test`; build `AgentRing.xcodeproj` with Xcode 16.3+.
See [docs/ios.md](docs/ios.md) for signing, Apple push setup and hardware checks.
The iOS workflow builds an unsigned simulator app and tests the protocol core.

## Protocol first

[`protocol/relay.openapi.yaml`](protocol/relay.openapi.yaml) is the single
source of truth for the relay's REST API and event payloads. To change the
protocol:

1. Edit `relay.openapi.yaml` first.
2. Update or add fixtures in `protocol/examples/` and keep them valid: the relay
   tests (`relay/test/relay.test.ts`) and the Kotlin tests
   (`app-android/core/src/test/.../CoreTest.kt`) read them.
3. Regenerate the relay types: `cd relay && npm run gen:types`
   (`openapi-typescript` → `relay/src/generated/api.ts`, committed; do not edit
   it by hand).
4. Update the implementations (relay, daemon, `app-android/core`) and
   [docs/protocol.md](docs/protocol.md).

Design changes that deviate from `docs/architecture.md` or `docs/protocol.md`
should be discussed in an issue first and recorded in those documents.

## Dependencies

Supply-chain attacks are a real risk for a project that rings your phone and
holds your agent's credentials, so:

- **Pin exact versions** and commit the lockfiles (`relay/package-lock.json`,
  `daemon/uv.lock`, `app-android/gradle/libs.versions.toml`).
- **Prefer releases at least ~2 weeks old.** Do not pull in a version published
  in the last few days unless it fixes something you need.
- **Check the lockfiles against [OSV](https://osv.dev)** before pushing, e.g.
  `osv-scanner --lockfile=relay/package-lock.json --lockfile=daemon/uv.lock`.
- **Apply age limits per package, never globally.** With uv:
  `uv lock --exclude-newer-package <name>=<date>`. A global `--exclude-newer`
  once downgraded `certifi` to a version with compromised CA roots.
- Avoid new dependencies when a few lines of code will do. Explain any new
  dependency in the pull request.

## Code and docs

- Code, comments and docs in English.
- Match the surrounding style. Keep comments for the non-obvious "why".
- Describe only behaviour that exists; update docs in the same change as the
  code.
- Never commit secrets (`google-services.json`, service-account files, `.env`,
  API keys). `app-android/app/debug.keystore` is the one intentional exception;
  see [SECURITY.md](SECURITY.md#android-signing-key).

## Commits and pull requests

- One logical change per commit, message in the imperative, prefixed with the
  component: `relay: …`, `daemon: …`, `android: …`, `deploy: …`, `docs: …`,
  `ci: …`, `scripts: …`. Examples from the history:
  `relay: pairing, devices, messages, event log + WebSocket, signed FCM push`,
  `daemon: config dir 0700 and .env created 0600 (no world-readable window)`.
- Pull requests: say what changed and why, how you tested it (tests, emulator,
  real phone model and Android version), and fill in the template.
- By contributing you agree that your contribution is licensed under the
  [Apache License 2.0](LICENSE).
