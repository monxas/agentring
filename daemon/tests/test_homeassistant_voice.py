"""Wire-level Assist + Wyoming tests; no real house, models, phone or credentials."""
import asyncio
import json
import struct

import pytest

pytest.importorskip('livekit')
import websockets

from agentring.voice.homeassistant import HomeAssistantVoice, wyoming_event, wyoming_frame
from agentring.voice.backend import AudioOut, Interrupted, SessionEnding, Transcript, TurnComplete


def packet(kind, data=None, payload=b''):
    data_bytes = json.dumps(data or {}).encode()
    return json.dumps({'type': kind, 'data_length': len(data_bytes), 'payload_length': len(payload)}).encode() + b'\n' + data_bytes + payload


async def fixtures(reject_auth=False, fail_pipeline=False):
    calls = []
    audio = []
    spoken = []

    async def ha(ws):
        await ws.send(json.dumps({'type': 'auth_required'}))
        auth = json.loads(await ws.recv())
        assert auth == {'type': 'auth', 'access_token': 'test-secret'}
        await ws.send(json.dumps({'type': 'auth_invalid' if reject_auth else 'auth_ok'}))
        if reject_auth:
            return
        command = json.loads(await ws.recv())
        if command['type'] == 'assist_pipeline/pipeline/list':
            await ws.send(json.dumps({'id': 1, 'type': 'result', 'success': True, 'result': {'pipelines': [{'id': 'p1'}]}}))
            return
        calls.append(command)
        assert command['start_stage'] == 'stt' and command['end_stage'] == 'intent'
        assert command['pipeline'] == 'p1'
        await ws.send(json.dumps({'id': 1, 'type': 'result', 'success': True}))
        async def event(kind, data):
            await ws.send(json.dumps({'id': 1, 'type': 'event', 'event': {'type': kind, 'data': data}}))
        await event('run-start', {'runner_data': {'stt_binary_handler_id': 7}})
        raw_audio = bytearray()
        while True:
            chunk = await ws.recv()
            assert isinstance(chunk, bytes) and chunk[:1] == b'\x07'
            if len(chunk) == 1:
                break
            raw_audio.extend(chunk[1:])
        audio.append(bytes(raw_audio))
        if fail_pipeline:
            await event('error', {'code': 'cloud-auth-failed', 'message': 'private provider detail'})
        else:
            await event('stt-end', {'stt_output': {'text': 'dos más dos'}})
            await event('intent-end', {'intent_output': {'conversation_id': 'conversation-1', 'response': {'speech': {'plain': {'speech': 'Cuatro.'}}}}})
        await event('run-end', None)

    async def tts(reader, writer):
        try:
            kind, data, _ = await wyoming_event(reader)
            assert kind == 'synthesize'
            spoken.append(data['text'])
            pcm = struct.pack('<h', 1000) * 1600
            writer.write(packet('audio-start', {'rate': 16000, 'width': 2, 'channels': 1}))
            writer.write(packet('audio-chunk', {}, pcm))
            writer.write(packet('audio-stop'))
            await writer.drain()
        finally:
            writer.close()
            await writer.wait_closed()

    haserver = await websockets.serve(ha, '127.0.0.1', 0)
    ttsserver = await asyncio.start_server(tts, '127.0.0.1', 0)
    b = HomeAssistantVoice(f'http://127.0.0.1:{haserver.sockets[0].getsockname()[1]}', 'test-secret', 'p1',
                          tts_host='127.0.0.1', tts_port=ttsserver.sockets[0].getsockname()[1])
    return b, haserver, ttsserver, calls, audio, spoken


async def cleanup(b, ha, tts):
    await b.close()
    ha.close(); tts.close()
    await ha.wait_closed(); await tts.wait_closed()


async def turn(b):
    events = []
    async with asyncio.timeout(5):
        async for event in b.events():
            events.append(event)
            if isinstance(event, TurnComplete) and any(isinstance(e, AudioOut) for e in events):
                return events
            if isinstance(event, SessionEnding):
                return events


def test_assist_pcm_end_to_end_and_conversation_continuity():
    async def run():
        b, ha, tts, calls, audio, spoken = await fixtures()
        try:
            await b.connect('', [])
            assert not calls
            await b.send_audio(b'\0' * (b.input_rate * 2))
            assert not calls  # silence never opens cloud recognition
            pcm = struct.pack('<h', 2000) * (640 * 5) + b'\0' * (1280 * 20)
            await b.send_audio(pcm)
            events = await turn(b)
            assert any(isinstance(e, Interrupted) for e in events)
            assert [(e.role, e.text) for e in events if isinstance(e, Transcript)] == [('user', 'dos más dos'), ('agent', 'Cuatro.')]
            output = b''.join(e.pcm for e in events if isinstance(e, AudioOut))
            assert 4600 < len(output) <= 4900  # 100ms resampled from 16k to 24k PCM16
            assert audio[0] and spoken == ['Cuatro.']
            await b.send_audio(pcm)
            await turn(b)
            assert calls[1]['conversation_id'] == 'conversation-1'
        finally:
            await cleanup(b, ha, tts)
    asyncio.run(run())


def test_greeting_does_not_reach_conversation_or_household_playback():
    async def run():
        b, ha, tts, calls, audio, spoken = await fixtures()
        try:
            await b.connect('', [])
            await b.send_text('Hola.', respond=True)
            await turn(b)
            await b.send_text('Membership note', respond=False)
            assert spoken == ['Hola.'] and not calls and not audio
            assert b.conversation_id is None
        finally:
            await cleanup(b, ha, tts)
    asyncio.run(run())


def test_auth_and_missing_pipeline_fail_closed():
    async def run():
        b, ha, tts, *_ = await fixtures(reject_auth=True)
        try:
            with pytest.raises(RuntimeError, match='rejected'):
                await b.connect('', [])
        finally:
            await cleanup(b, ha, tts)
        b, ha, tts, *_ = await fixtures()
        b.pipeline = 'missing'
        try:
            with pytest.raises(ValueError, match='unavailable'):
                await b.connect('', [])
        finally:
            await cleanup(b, ha, tts)
    asyncio.run(run())


def test_pipeline_failure_ends_stream_without_exposing_provider_details():
    async def run():
        b, ha, tts, *_ = await fixtures(fail_pipeline=True)
        try:
            await b.connect('', [])
            b._submit('audio', b'\0' * 3200)
            events = await turn(b)
            assert isinstance(events[-1], SessionEnding)
            assert 'private' not in str(events)
        finally:
            await cleanup(b, ha, tts)
    asyncio.run(run())


def test_wyoming_bounds_and_url_validation():
    async def run():
        reader = asyncio.StreamReader()
        reader.feed_data(b'{"type":"audio-chunk","payload_length":9999999}\n'); reader.feed_eof()
        with pytest.raises(ValueError, match='length'):
            await wyoming_event(reader)
    asyncio.run(run())
    for url in ('http://user:password@localhost', 'http://localhost/?token=secret', 'file:///tmp/ha'):
        with pytest.raises(ValueError):
            HomeAssistantVoice(url, 'token', 'p1', tts_host='localhost')
