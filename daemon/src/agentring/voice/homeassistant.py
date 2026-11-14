"""Home Assistant Assist (STT + conversation) and an existing Wyoming PCM voice.

Audio stays in memory. Each utterance has a bounded Assist run and its own
conversation id per phone call. No HA pipeline or household playback is modified.
"""
from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import math
import re
import time
import unicodedata
from array import array
from collections.abc import AsyncIterator, Awaitable, Callable
from dataclasses import dataclass, field
from typing import Any
from urllib.parse import urlsplit

import websockets
from livekit import rtc

from .backend import AudioOut, Event, Interrupted, SessionEnding, ToolCalls, Transcript, TurnComplete
from .tools import Tool, ToolCall

log = logging.getLogger("agentring.voice.homeassistant")


def wyoming_frame(kind: str, data: dict[str, Any]) -> bytes:
    payload = json.dumps(data, ensure_ascii=False).encode()
    return json.dumps({"type": kind, "data_length": len(payload)}).encode() + b"\n" + payload


async def wyoming_event(reader: asyncio.StreamReader) -> tuple[str, dict[str, Any], bytes]:
    header = await reader.readline()
    if len(header) > 8192 or not header.endswith(b"\n"):
        raise ValueError("Invalid Wyoming header")
    h = json.loads(header)
    if not isinstance(h, dict) or not isinstance(h.get("type"), str):
        raise ValueError("Invalid Wyoming event")
    lengths = []
    for key in ("data_length", "payload_length"):
        size = h.get(key, 0)
        if type(size) is not int or not 0 <= size <= 65536:
            raise ValueError("Invalid Wyoming length")
        lengths.append(size)
    data = h.get("data") or {}
    if not isinstance(data, dict):
        raise ValueError("Invalid Wyoming data")
    if lengths[0]:
        extra = json.loads(await reader.readexactly(lengths[0]))
        if not isinstance(extra, dict):
            raise ValueError("Invalid Wyoming data")
        data.update(extra)
    return h["type"], data, await reader.readexactly(lengths[1])


@dataclass
class AudioInput:
    """One bounded utterance, streamed to recognition while the caller speaks."""
    chunks: asyncio.Queue[bytes | None] = field(default_factory=lambda: asyncio.Queue(maxsize=800))
    ended_at: float = 0.0

    def feed(self, pcm: bytes | None) -> None:
        self.chunks.put_nowait(pcm)
        if pcm is None:
            self.ended_at = time.monotonic()


class HomeAssistantVoice:
    input_rate = 16000
    output_rate = 24000
    max_session_s = 1800

    def __init__(self, url: str, token: str, pipeline: str, *, tts_host: str, tts_port: int = 10205,
                 tts_voice: str = "", vad_threshold: int = 350, silence_ms: int = 480):
        u = urlsplit(url)
        if (u.scheme not in ("http", "https") or not u.hostname or u.username or u.password
                or u.query or u.fragment or u.path not in ("", "/")):
            raise ValueError("HA_URL must be an HTTP(S) origin without credentials")
        if not token or not pipeline or not tts_host or not 1 <= tts_port <= 65535:
            raise ValueError("Home Assistant voice needs a token, pipeline and Wyoming endpoint")
        self.ws_url = url.rstrip("/").replace("http", "ws", 1) + "/api/websocket"
        self.token, self.pipeline = token, pipeline
        self.tts_host, self.tts_port, self.tts_voice = tts_host, tts_port, tts_voice
        if not 240 <= silence_ms <= 1500:
            raise ValueError("Silence detection must be between 240 and 1500 ms")
        self.vad_threshold, self.silence_ms = vad_threshold, silence_ms
        self._active: asyncio.Task | None = None
        self.last_timing: dict[str, float | int | bool] = {}
        self._turn_start = 0.0
        self.conversation_id: str | None = None
        self._events: asyncio.Queue[Event | None] = asyncio.Queue(maxsize=128)
        self._requests: asyncio.Queue[tuple[str, Any, int]] = asyncio.Queue(maxsize=2)
        self._worker: asyncio.Task | None = None
        self._closed = False
        self._generation = 0
        self._carry = bytearray()
        self._pre = bytearray()
        self._audio = bytearray()
        self._capture: AudioInput | None = None
        self._voiced_ms = 0
        self._silent_ms = 0
        self._speaking_until = 0.0
        self._can_hang_up = False

    async def _authenticate(self, ws: Any) -> None:
        if json.loads(await ws.recv()).get("type") != "auth_required":
            raise RuntimeError("Unexpected Home Assistant authentication challenge")
        await ws.send(json.dumps({"type": "auth", "access_token": self.token}))
        if json.loads(await ws.recv()).get("type") != "auth_ok":
            raise RuntimeError("Home Assistant rejected the voice token")

    async def connect(self, instructions: str, tools: list[Tool]) -> None:
        if instructions or any(t.name != "end_call" for t in tools):
            raise ValueError("Home Assistant owns its prompt and tools; custom agentring tools are unsupported")
        self._can_hang_up = any(t.name == "end_call" for t in tools)
        async with asyncio.timeout(15):
            async with websockets.connect(self.ws_url, open_timeout=10, close_timeout=2, proxy=None) as ws:
                await self._authenticate(ws)
                await ws.send(json.dumps({"id": 1, "type": "assist_pipeline/pipeline/list"}))
                r = json.loads(await ws.recv())
                pipelines = (r.get("result") or {}).get("pipelines", [])
                if not r.get("success") or not any(p.get("id") == self.pipeline for p in pipelines):
                    raise ValueError("Configured Home Assistant pipeline is unavailable")
        self._worker = asyncio.create_task(self._work())

    async def send_audio(self, pcm: bytes) -> None:
        if self._closed:
            return
        self._carry.extend(pcm)
        size = self.input_rate // 25 * 2  # 40 ms, matching the call mixer
        while len(self._carry) >= size:
            frame = bytes(self._carry[:size]); del self._carry[:size]
            samples = array("h", frame)
            speech = math.sqrt(sum(s * s for s in samples) / len(samples)) >= self.vad_threshold
            if not self._audio:
                self._pre.extend(frame); del self._pre[:-size * 5]
                self._voiced_ms = self._voiced_ms + 40 if speech else 0
                if self._voiced_ms >= 120:
                    self._generation += 1
                    if self._active:
                        self._active.cancel()
                    await self._events.put(Interrupted())
                    await self._events.put(TurnComplete())
                    self._speaking_until = 0
                    self._audio.extend(self._pre)
                    self._capture = AudioInput()
                    self._capture.feed(bytes(self._pre))
                    self._submit("audio", self._capture)
                    self._silent_ms = 0
                continue
            self._audio.extend(frame)
            if self._capture:
                self._capture.feed(frame)
            self._silent_ms = 0 if speech else self._silent_ms + 40
            if self._silent_ms >= self.silence_ms or len(self._audio) >= self.input_rate * 2 * 30:
                if self._capture:
                    self._capture.feed(None)
                    self._capture = None
                self._audio.clear(); self._pre.clear(); self._voiced_ms = self._silent_ms = 0

    def _submit(self, kind: str, value: Any) -> None:
        if self._requests.full():
            self._requests.get_nowait()  # bounded: newest utterance supersedes an unstarted one
        self._requests.put_nowait((kind, value, self._generation))

    async def send_text(self, text: str, *, respond: bool) -> None:
        # CallSession uses explicit Spanish membership/greeting prompts for this backend.
        if respond and text.strip() and not self._closed:
            self._submit("say", text[:4000])

    async def send_tool_results(self, results: list[Any]) -> None:
        if any(r.call.name != "end_call" for r in results):
            raise ValueError("Home Assistant manages its own conversation tools")

    async def _assist(self, pcm: bytes | AudioInput, on_text: Callable[[str], Awaitable[None]] | None = None) -> tuple[str, str]:
        recognized = reply = ""
        streamed = ""
        self._turn_start = time.monotonic()
        self.last_timing = {}
        async with asyncio.timeout(75):
            async with websockets.connect(self.ws_url, open_timeout=10, close_timeout=2,
                                          max_size=2**20, proxy=None) as ws:
                await self._authenticate(ws)
                command: dict[str, Any] = {"id": 1, "type": "assist_pipeline/run", "pipeline": self.pipeline,
                    "start_stage": "stt", "end_stage": "intent", "input": {"sample_rate": self.input_rate},
                    "timeout": 60}
                if self.conversation_id:
                    command["conversation_id"] = self.conversation_id
                await ws.send(json.dumps(command))
                uploader: asyncio.Task | None = None
                try:
                    async for raw in ws:
                        r = json.loads(raw)
                        if r.get("type") == "result":
                            if not r.get("success"):
                                raise RuntimeError("Home Assistant rejected the voice run")
                            continue
                        event = r.get("event") or {}; data = event.get("data") or {}; kind = event.get("type")
                        if kind == "run-start":
                            # Keep context even if the caller interrupts before intent-end.
                            conversation = data.get("conversation_id")
                            if isinstance(conversation, str) and conversation:
                                self.conversation_id = conversation
                            handler = (data.get("runner_data") or {}).get("stt_binary_handler_id")
                            if type(handler) is not int or not 0 <= handler <= 255:
                                raise ValueError("Home Assistant returned an invalid audio handler")
                            prefix = bytes([handler])
                            async def upload() -> None:
                                if isinstance(pcm, AudioInput):
                                    while (chunk := await pcm.chunks.get()) is not None:
                                        await ws.send(prefix + chunk)
                                else:
                                    for offset in range(0, len(pcm), 8000):
                                        await ws.send(prefix + pcm[offset:offset + 8000])
                                await ws.send(prefix)
                            uploader = asyncio.create_task(upload())
                        elif kind == "stt-end":
                            recognized = (data.get("stt_output") or {}).get("text", "")
                            self.last_timing["stt_ms"] = round((time.monotonic() - self._turn_start) * 1000)
                            if recognized and on_text:
                                await self._events.put(Transcript("user", recognized))
                                await self._events.put(TurnComplete())
                        elif kind == "intent-progress" and on_text:
                            delta = data.get("chat_log_delta") or {}
                            text = delta.get("content")
                            if isinstance(text, str) and text:
                                if len(streamed) + len(text) > 16000:
                                    raise ValueError("Home Assistant response exceeds voice limit")
                                if not streamed:
                                    self.last_timing["first_text_ms"] = round((time.monotonic() - self._turn_start) * 1000)
                                streamed += text
                                await on_text(text)
                        elif kind == "intent-end":
                            output = data.get("intent_output") or {}
                            self.conversation_id = output.get("conversation_id") or self.conversation_id
                            reply = (((output.get("response") or {}).get("speech") or {}).get("plain") or {}).get("speech", "")
                        elif kind == "error":
                            if data.get("code") == "stt-no-text-recognized":
                                return "", ""
                            raise RuntimeError("Home Assistant voice pipeline failed")
                        elif kind == "run-end":
                            self.last_timing["intent_ms"] = round((time.monotonic() - self._turn_start) * 1000)
                            if not recognized:
                                return "", ""
                            if not reply:
                                raise RuntimeError("Home Assistant returned no spoken response")
                            if on_text and not streamed:
                                await on_text(reply)
                            elif on_text and reply.startswith(streamed) and len(reply) > len(streamed):
                                await on_text(reply[len(streamed):])
                            self.last_timing["streamed"] = bool(streamed)
                            return recognized, reply
                finally:
                    if uploader:
                        uploader.cancel()
                        await asyncio.gather(uploader, return_exceptions=True)
        raise RuntimeError("Home Assistant closed the voice run")

    async def _speak(self, text: str, generation: int, *, complete: bool = True) -> None:
        if generation != self._generation:
            return
        await self._events.put(Transcript("agent", text))
        async with asyncio.timeout(60):
            reader, writer = await asyncio.open_connection(self.tts_host, self.tts_port, limit=8193)
            try:
                data: dict[str, Any] = {"text": text[:4000]}
                if self.tts_voice:
                    data["voice"] = {"name": self.tts_voice}
                writer.write(wyoming_frame("synthesize", data)); await writer.drain()
                resampler = None
                total = 0
                for _ in range(10000):
                    kind, data, payload = await wyoming_event(reader)
                    if generation != self._generation:
                        return
                    if kind == "audio-start":
                        rate = data.get("rate")
                        if data.get("width") != 2 or data.get("channels") != 1 or type(rate) is not int or not 8000 <= rate <= 48000:
                            raise ValueError("Wyoming must return PCM16 mono")
                        resampler = rtc.AudioResampler(rate, self.output_rate)
                    elif kind == "audio-chunk":
                        total += len(payload)
                        if resampler is None or len(payload) % 2 or total > 6 * 1024 * 1024:
                            raise ValueError("Invalid or oversized Wyoming audio")
                        for frame in resampler.push(bytearray(payload)):
                            await self._emit_audio(bytes(frame.data.cast("B")))
                    elif kind == "audio-stop":
                        if resampler is None:
                            raise ValueError("Missing Wyoming audio format")
                        for frame in resampler.flush():
                            await self._emit_audio(bytes(frame.data.cast("B")))
                        if complete:
                            await self._events.put(TurnComplete())
                        return
                    elif kind == "error":
                        raise RuntimeError("Wyoming synthesis failed")
                raise ValueError("Too many Wyoming events")
            finally:
                writer.close()
                with contextlib.suppress(Exception):
                    await writer.wait_closed()

    async def _emit_audio(self, pcm: bytes) -> None:
        if self._turn_start and "first_audio_ms" not in self.last_timing:
            self.last_timing["first_audio_ms"] = round((time.monotonic() - self._turn_start) * 1000)
        self._speaking_until = max(time.monotonic(), self._speaking_until) + len(pcm) / (2 * self.output_rate)
        await self._events.put(AudioOut(pcm))

    async def _audio_turn(self, value: bytes | AudioInput, generation: int) -> None:
        # Consume HA deltas and synthesize completed phrases concurrently. A bounded
        # queue applies backpressure without retaining unbounded model output.
        phrases: asyncio.Queue[str | None] = asyncio.Queue(maxsize=32)
        pending = ""

        async def delta(text: str) -> None:
            nonlocal pending
            pending += text
            while pending:
                boundary = re.search(r"[.!?…](?:[\"'»”)]*)(?:\s+)|\n", pending)
                end = boundary.end() if boundary else 0
                if not end and len(pending) >= 140:
                    end = pending.rfind(" ", 0, 140) + 1
                if not end:
                    break
                phrase, pending = pending[:end], pending[end:]
                if phrase.strip():
                    await phrases.put(phrase)

        async def speak() -> None:
            while (phrase := await phrases.get()) is not None:
                await self._speak(phrase, generation, complete=False)

        async with asyncio.TaskGroup() as group:
            group.create_task(speak())
            recognized, reply = await self._assist(value, delta)
            if pending.strip():
                await phrases.put(pending)
            await phrases.put(None)
        if generation != self._generation:
            return
        if reply:
            await self._events.put(TurnComplete())
        if isinstance(value, AudioInput) and value.ended_at and "first_audio_ms" in self.last_timing:
            first_audio_at = self._turn_start + float(self.last_timing["first_audio_ms"]) / 1000
            self.last_timing["after_speech_ms"] = round((first_audio_at - value.ended_at) * 1000 + self.silence_ms)
        log.info("voice timing %s", json.dumps(self.last_timing, sort_keys=True))
        if recognized and self._can_hang_up:
            normalized = "".join(c for c in unicodedata.normalize("NFKD", recognized.lower())
                                 if not unicodedata.combining(c)).strip(" .,!¿?¡")
            if normalized in {"adios", "hasta luego", "cuelga", "cuelga por favor", "termina la llamada"}:
                await self._events.put(ToolCalls([ToolCall("ha-hangup", "end_call", {})]))

    async def _work(self) -> None:
        try:
            while True:
                kind, value, generation = await self._requests.get()
                if generation != self._generation:
                    continue
                self._active = asyncio.create_task(self._audio_turn(value, generation) if kind == "audio"
                                                  else self._speak(value, generation))
                try:
                    await self._active
                except asyncio.CancelledError:
                    if self._closed or asyncio.current_task().cancelling():
                        raise
                    # New speech cancels old network/model work immediately.
                finally:
                    self._active = None
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            log.warning("Home Assistant voice failed (%s)", type(exc).__name__)
            await self._events.put(SessionEnding("Home Assistant voice unavailable"))
            await self._events.put(None)

    async def events(self) -> AsyncIterator[Event]:
        while True:
            event = await self._events.get()
            if event is None:
                return
            yield event

    async def close(self) -> None:
        self._closed = True
        if self._worker:
            self._worker.cancel()
            await asyncio.gather(self._worker, return_exceptions=True)
        self._carry.clear(); self._pre.clear(); self._audio.clear()
