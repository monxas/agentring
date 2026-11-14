#!/usr/bin/env python3
"""Measure Assist-to-PCM latency without calling a phone or playing a house speaker.

Use a fixed, harmless spoken question as PCM16 mono 16kHz. Credentials are read
through the daemon's existing private configuration. Only timings/counts leave RAM.
"""
from __future__ import annotations
import argparse
import asyncio
import json
import time
from pathlib import Path
from statistics import median

from agentring.voice.backend import AudioOut
from agentring.voice.homeassistant import AudioInput
from agentring.voice.quick import configured_home_assistant_agent


async def measure(pcm: bytes, mode: str) -> dict:
    built = configured_home_assistant_agent()
    backend = built.agent.backend()
    await backend.connect('', [])
    first_audio = None
    audio_bytes = 0
    origin = time.monotonic()
    speech_end = origin + len(pcm) / 32000

    async def collect():
        nonlocal first_audio, audio_bytes
        async for event in backend.events():
            if isinstance(event, AudioOut):
                first_audio = first_audio or time.monotonic()
                audio_bytes += len(event.pcm)

    consumer = asyncio.create_task(collect())
    try:
        async with asyncio.timeout(90):
            if mode == 'buffered':
                # Reproduce the previous bridge: wait for the whole utterance plus
                # 720ms silence, then upload, wait for final text and synthesize.
                await asyncio.sleep(len(pcm) / 32000 + .720)
                recognized, reply = await backend._assist(pcm)
                if not recognized or not reply:
                    raise RuntimeError('No recognized question or response')
                await backend._speak(reply, backend._generation)
            else:
                capture = AudioInput()
                task = asyncio.create_task(backend._audio_turn(capture, backend._generation))
                try:
                    for offset in range(0, len(pcm), 1280):
                        capture.feed(pcm[offset:offset + 1280])
                        target = origin + min(offset + 1280, len(pcm)) / 32000
                        await asyncio.sleep(max(0, target - time.monotonic()))
                    speech_end = time.monotonic()
                    await asyncio.sleep(backend.silence_ms / 1000)
                    capture.feed(None)
                    await task
                finally:
                    task.cancel()
                    await asyncio.gather(task, return_exceptions=True)
            await asyncio.sleep(0)  # drain events already emitted by the synthesizer
            if first_audio is None or not audio_bytes:
                raise RuntimeError('No PCM audio received')
            return {'mode': mode, 'speech_duration_ms': round(len(pcm) / 32),
                    'end_of_speech_to_pcm_ms': round((first_audio - speech_end) * 1000),
                    'audio_bytes': audio_bytes, 'backend': backend.last_timing,
                    'scope': 'first backend PCM; excludes LiveKit/iPhone playout'}
    finally:
        consumer.cancel()
        await asyncio.gather(consumer, return_exceptions=True)
        await backend.close()
        await built.aclose()


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pcm', required=True, type=Path)
    parser.add_argument('--repetitions', type=int, default=3, choices=range(1, 6))
    parser.add_argument('--mode', choices=['buffered', 'streaming', 'compare'], default='compare')
    args = parser.parse_args()
    pcm = args.pcm.read_bytes()
    if not 3200 <= len(pcm) <= 960000 or len(pcm) % 2:
        parser.error('Input must be 0.1–30 seconds of PCM16 mono 16kHz')
    samples = []
    for _ in range(args.repetitions):
        for mode in (['buffered', 'streaming'] if args.mode == 'compare' else [args.mode]):
            result = await measure(pcm, mode)
            samples.append(result)
            print(json.dumps(result), flush=True)
    print(json.dumps({'median_end_of_speech_to_pcm_ms': {
        mode: median(r['end_of_speech_to_pcm_ms'] for r in samples if r['mode'] == mode)
        for mode in {r['mode'] for r in samples}}, 'samples': len(samples),
        'phone_playback_verified': False}), flush=True)


if __name__ == '__main__':
    asyncio.run(main())
