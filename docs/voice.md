# Voice AI on calls (M3)

When a call is answered, a realtime speech-to-speech model talks to the user, can
use your tools while the call goes on, and hangs up by itself when the user says
goodbye. It works both ways: the agent calling the phone, and the phone calling
the agent ("Call agent" in the app).

Install the voice extra and give it a Gemini API key (environment or
`~/.agentring/.env`):

```bash
uv tool install './daemon[voice]'
echo GEMINI_API_KEY=... >> ~/.agentring/.env
```

## Existing Home Assistant pipeline and Wyoming voice

Set `AGENTRING_VOICE_BACKEND=homeassistant` to reuse an existing Assist speech-to-text
and conversation agent, with an existing Wyoming PCM text-to-speech server. This
backend needs no Gemini key and adds no dependencies. The iPhone, relay, APNs and
LiveKit transport are unchanged.

Store these settings in the daemon's private `~/.agentring/.env` (container: `/config/.env`):

```dotenv
AGENTRING_VOICE_BACKEND=homeassistant
HA_URL=http://homeassistant.local:8123
HA_TOKEN_FILE=/voice-secrets/ha-token
HA_PIPELINE_ID=YOUR_EXISTING_PIPELINE_ID
WYOMING_TTS_HOST=your-wyoming-host
WYOMING_TTS_PORT=10205
WYOMING_TTS_VOICE=your-installed-voice
```

`HA_TOKEN_FILE` is a private, read-only file with an existing Home Assistant access
token. Mount only that credential directory, never the whole HA configuration or
secret store. The token must authorize Assist. Phone speech is handled by the
selected HA conversation agent, with **that agent's existing permissions and tools**.
No pipeline, satellites, speakers, HA model settings or exposed-entity lists are changed.

Run `agentring serve --ai --agents none`, or `agentring call "Reason" --ai --agents none`.
This backend owns its greeting, and HA owns the conversation prompt/model/tools:
`--instructions`, `--mcp`, `--tools`, `--model`, `--voice` and agent consultation
configuration are rejected rather than silently ignored. MCP outgoing calls also
use this backend, but reject a separate `context` argument: include the request in
the spoken `reason`; the HA agent retains its own context and tools. Gemini remains the default
when `AGENTRING_VOICE_BACKEND` is absent or `gemini`.

Audio uses PCM16 mono, 16kHz into Assist and 24kHz out to LiveKit. A local energy gate
collects speech, waits 720ms of silence, and sends one bounded utterance (maximum30s)
to Assist. Each call has its own conversation id. Recognition and response run in
sequence; the Wyoming voice streams PCM chunks directly, avoiding MP3 encoding or
additional decoders. New speech clears queued playback and supersedes unstarted
utterances. An HA action already started is not undone by an interruption.

The caller can hang up normally. Exact Spanish farewell commands such as `adiós`,
`hasta luego`, `cuelga` and `termina la llamada` also end the call after the spoken
response. Calls have a 29-minute bound. Silence does not continuously open cloud
recognition sessions. Provider failures close the voice session with a sanitized
error; audio is not written to disk.

## Without code

```bash
# Call the phone; the AI explains why and answers questions with your MCP tools.
agentring call "The nightly backup failed" --ai \
  --instructions @prompt.md --mcp http://127.0.0.1:8787/mcp --tools status,logs

# Answer calls from the phone with the AI.
agentring serve --ai --instructions @prompt.md --mcp http://127.0.0.1:8787/mcp
```

- `--instructions`: the system prompt (inline or `@file`). Default: a short, generic phone persona.
- `--mcp`: any MCP server over Streamable HTTP; repeat for several. `--tools` keeps only
  the listed tools: over the phone, expose only what the caller should be able to do.
- `--model` / `--voice`: Gemini Live model (default `gemini-3.8-live`) and voice (default `Charon`).
- `--agents`: an [`agents.yaml`](agents.md#agentsyaml) with your agents (the AI consults them with
  `consult_agent`) and MCP servers. Default `~/.agentring/agents.yaml` if it exists; `none` skips it.
- `call --ai --json` prints the whole result (transcript, tool calls, duration).

## As a library

```python
from agentring.relay_client import RelayClient
from agentring.voice import CallInfo, GeminiLive, Prompts, Tool, VoiceAgent

def status(service: str) -> str:
    return "up"

agent = VoiceAgent(
    lambda: GeminiLive(api_key, voice="Charon"),
    instructions="You are the on-call assistant…",   # or a (sync/async) function of CallInfo
    tools=[Tool("status", "Is a service up?", status,
                {"type": "object", "properties": {"service": {"type": "string"}}, "required": ["service"]})],
)
client = RelayClient(relay_url, api_key)
created = client.create_call("The API is down", priority="urgent")
result = await agent.run(CallInfo(created["call"]["call_id"], "The API is down"), created["join"], relay=client)
print(result.end_reason, result.transcript, result.tools)
```

Incoming calls: on each relay event (`agentring.sync.run_ws`), `accept_incoming(client, event)`
returns `(CallInfo, join)` for a call from the phone, ready for `agent.run`.

What you can plug in:

| Option | What it does |
|---|---|
| `tools` | `Tool(name, description, handler, parameters)`; sync handlers run in a thread, async ones in the loop. `mcp_tools(url, allow=[…])` turns an MCP server into tools; `Consultations(load_agents(path).agents).tool()` is `consult_agent` ([agents.md](agents.md)). A tool can find its call with `current_session()` and answer later with `session.notify(text, respond=True)`. |
| `instructions` | Text, or a function of `CallInfo` (e.g. to add fresh context when the call starts). |
| `prompts` | `Prompts(...)`: the notes the session gives the model when someone answers, joins or leaves, and the `end_call` description. Change them to change wording or language. |
| `name_of` | LiveKit identity (`device_<id>`) → the person's name, so the model greets them by name. |
| `before_tool` | `(session, call) → None \| dict \| str`: run, run with other args, or skip with that answer. The session exposes `transcript`, `partial`, `participants` and `last_user_speech_at` (e.g. "only act if the user asked in the last 45 s"). |
| `end_call_tool`, `tool_timeout_s`, `ring_timeout_s`, `max_duration_s`, `empty_room_grace_s` | Limits. A tool slower than its timeout keeps running; the model is told so. |

Behaviour: the agent joins the room while the phone rings and opens the model
session at the same time, so it greets as soon as someone answers. In group
calls everyone's audio is mixed into one input and the model is told who joins
or leaves. Talking over the model interrupts it. Tools run in their own task, so
the call keeps listening while a slow tool works. The call ends when the model
calls `end_call` (after its goodbye), everyone leaves (10 s grace for a dropped
connection), the relay says it is over, or the model's session limit is near
(Gemini: 15 min).

Gemini pricing: the Live models have a free tier (rate-limited; Google may use free-tier
data to improve its products) and a paid tier of about $0.005/min of audio in and
$0.018/min out. See https://ai.google.dev/gemini-api/docs/pricing.

## Backends

`RealtimeBackend` (voice/backend.py) is the plug point: a class that connects with
instructions + tools, sends audio/text/tool results and yields a few plain events.
Gemini Live is built in (`voice/gemini.py`); OpenAI Realtime is the next one.

## Testing

`tests/test_voice.py` covers the protocol, tools, MCP and session logic without a
phone. `tests/test_voice_live.py` runs whole calls (the AI calls a simulated phone,
and the phone calls `agentring serve --ai`) against a real relay, LiveKit and Gemini:

```bash
docker run -d --name lk -p 7880:7880 -p 7881:7881 -p 50000-50100:50000-50100/udp \
  -e "LIVEKIT_KEYS=devkey: $(openssl rand -hex 24 | tee /tmp/lk)" \
  -e 'LIVEKIT_CONFIG=rtc: {port_range_start: 50000, port_range_end: 50100, tcp_port: 7881}' \
  livekit/livekit-server:v1.13.10 --node-ip "$(ipconfig getifaddr en0)" --bind 0.0.0.0
AGENTRING_TEST_LIVEKIT_URL=ws://127.0.0.1:7880 AGENTRING_TEST_LIVEKIT_SECRET=$(cat /tmp/lk) \
GEMINI_API_KEY=... uv run --extra voice pytest tests/test_voice_live.py -s
```

### Streaming Home Assistant bridge

The bridge now opens recognition after120ms of confirmed speech and uploads PCM
while the caller speaks. Silence never opens recognition. A480ms end-of-speech
window replaces720ms; `AGENTRING_SILENCE_MS` accepts240–1500ms for slower speakers.
Assist text deltas are split at phrase boundaries and synthesized concurrently,
so the first phrase can play before the complete LLM response. Non-streaming
agents fall back to their final response without duplicate speech. New confirmed
speech cancels the previous recognition/model/synthesis task and clears playback.
The conversation ID is retained from run-start, so interrupting the first response
does not start a disconnected conversation on the next turn.

`voice timing` logs contain only phase timings and a streaming flag, never text,
audio, tokens or credentials. `after_speech_ms` estimates the interval from the
last voiced frame to first backend PCM; it excludes LiveKit/iPhone playback.

For a bounded A/B measurement, use a harmless fixed spoken question (no home
commands), encoded as PCM16 mono16kHz, inside the configured daemon environment:

```bash
python scripts/measure-ha-voice.py --pcm /private/question.pcm --repetitions 3
```

The buffered baseline reproduces the previous720ms window, upload after speech,
final-response wait and whole-text synthesis. Streaming feeds the same audio at
real-time speed. Only timings and byte counts are printed; there is no phone
call or household playback. These measurements do not prove audible latency on
a physical iPhone. Keep synthetic input private and remove it after measurement.
