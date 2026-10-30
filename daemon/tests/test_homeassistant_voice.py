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


async def fixtures(reject_auth=False, fail_pipeline=False, stream=None):
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
        await event('run-start', {'conversation_id': 'conversation-1', 'runner_data': {'stt_binary_handler_id': 7}})
        raw_audio = bytearray()
        while True:
            chunk = await ws.recv()
            assert isinstance(chunk, bytes) and chunk[:1] == b'\x07'
            if len(chunk) == 1:
                break
            raw_audio.extend(chunk[1:])
        audio.append(bytes(raw_audio))
        if stream is not None:
            stream['uploaded'].set()
        if fail_pipeline:
            await event('error', {'code': 'cloud-auth-failed', 'message': 'private provider detail'})
        else:
            await event('stt-end', {'stt_output': {'text': 'dos más dos'}})
            if stream is not None:
                await event('intent-progress', {'chat_log_delta': {'role': 'assistant', 'content': 'La primera frase. '}})
                await stream['release'].wait()
                await event('intent-progress', {'chat_log_delta': {'content': 'La segunda frase.'}})
            await event('intent-end', {'intent_output': {'conversation_id': 'conversation-1', 'response': {'speech': {'plain': {'speech': 'Cuatro.' if stream is None else 'La primera frase. La segunda frase.'}}}}})
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


def test_cli_homeassistant_selection_needs_no_gemini(monkeypatch, tmp_path):
    from agentring.cli import _build_ai
    from agentring.voice.quick import configured_home_assistant_agent
    monkeypatch.setenv('AGENTRING_HOME', str(tmp_path))
    monkeypatch.setenv('AGENTRING_VOICE_BACKEND', 'homeassistant')
    monkeypatch.delenv('GEMINI_API_KEY', raising=False)
    token = tmp_path / 'ha-token'; token.write_text('test-secret')
    for k, value in {'HA_URL': 'http://127.0.0.1:8123', 'HA_TOKEN_FILE': str(token),
                     'HA_PIPELINE_ID': 'p1', 'WYOMING_TTS_HOST': 'localhost'}.items():
        monkeypatch.setenv(k, value)
    async def run():
        built = await _build_ai(None, None, None, None, None, 'none')
        assert isinstance(built.agent.backend(), HomeAssistantVoice)
        assert not built.agent.tools
        await built.aclose()
    asyncio.run(run())
    assert isinstance(configured_home_assistant_agent().agent.backend(), HomeAssistantVoice)


def test_mcp_outgoing_selects_existing_ha_backend(monkeypatch, tmp_path):
    from types import SimpleNamespace
    from agentring.mcp_server import AgentringTools, ToolError
    from agentring.voice import quick
    from agentring.voice.session import CallResult
    monkeypatch.setenv('AGENTRING_HOME', str(tmp_path))
    monkeypatch.setenv('AGENTRING_VOICE_BACKEND', 'homeassistant')
    monkeypatch.delenv('GEMINI_API_KEY', raising=False)
    seen = []
    async def call(info, join, **kwargs):
        seen.append(info.reason)
        return CallResult(info.call_id, True, 1, 'hung_up', [('user', 'Sí')])
    async def close():
        pass
    monkeypatch.setattr(quick, 'configured_home_assistant_agent', lambda: SimpleNamespace(agent=SimpleNamespace(run=call), aclose=close))
    async def run():
        tool = object.__new__(AgentringTools)
        tool._call_lock = asyncio.Lock(); tool.agent_name = tool.device_ids = None
        tool.client = SimpleNamespace(create_call=lambda *a, **kw: {'call': {'call_id': 'c1'}, 'join': {}})
        result = await tool.call('¿Seguimos?')
        assert seen == ['¿Seguimos?'] and result['transcript'] == [{'who': 'user', 'text': 'Sí'}]
        with pytest.raises(ToolError, match='manages its own context'):
            await tool.call('Reason', context='Do not silently discard this')
    asyncio.run(run())


def test_first_audio_precedes_final_model_response_and_has_no_duplicate_speech():
    async def run():
        stream = {'release': asyncio.Event(), 'uploaded': asyncio.Event()}
        b, ha, tts, _, _, spoken = await fixtures(stream=stream)
        try:
            await b.connect('', [])
            b._submit('audio', b'\0' * 3200)
            events = []
            async with asyncio.timeout(5):
                async for event in b.events():
                    events.append(event)
                    if isinstance(event, AudioOut):
                        break
            assert not stream['release'].is_set()
            assert spoken == ['La primera frase. ']
            assert 'intent_ms' not in b.last_timing
            stream['release'].set()
            events += await turn(b)
            assert spoken == ['La primera frase. ', 'La segunda frase.']
            assert [e.role for e in events if isinstance(e, Transcript)] == ['user', 'agent', 'agent']
            assert b.last_timing['first_audio_ms'] <= b.last_timing['intent_ms']
        finally:
            stream['release'].set()
            await cleanup(b, ha, tts)
    asyncio.run(run())


def test_recognition_upload_starts_while_caller_is_still_speaking():
    from agentring.voice.homeassistant import AudioInput
    async def run():
        b, ha, tts, calls, audio, _ = await fixtures()
        try:
            await b.connect('', [])
            await b.send_audio(struct.pack('<h', 2000) * (640 * 8))
            async with asyncio.timeout(5):
                while not calls:
                    await asyncio.sleep(.005)
            assert b._capture is not None and not b._capture.ended_at
            assert not audio  # EOF has not been sent; recognition is already connected.
            await b.send_audio(b'\0' * (1280 * 14))
            await turn(b)
            assert len(audio) == 1 and b._capture is None
            assert 'after_speech_ms' in b.last_timing
        finally:
            await cleanup(b, ha, tts)
    asyncio.run(run())


def test_new_speech_cancels_stalled_model_instead_of_waiting_for_timeout():
    async def run():
        stream = {'release': asyncio.Event(), 'uploaded': asyncio.Event()}
        b, ha, tts, calls, _, _ = await fixtures(stream=stream)
        try:
            await b.connect('', [])
            b._submit('audio', b'\0' * 3200)
            async with asyncio.timeout(5):
                while b._active is None or not stream['uploaded'].is_set():
                    await asyncio.sleep(.005)
            old = b._active
            await b.send_audio(struct.pack('<h', 2000) * (640 * 8))
            async with asyncio.timeout(5):
                while not old.done() or len(calls) < 2:
                    await asyncio.sleep(.005)
            assert old.cancelled()
            assert calls[1]['conversation_id'] == 'conversation-1'
            assert b._capture is not None
            # The second recognition session opened despite the first model being gated.
        finally:
            stream['release'].set()
            await cleanup(b, ha, tts)
    asyncio.run(run())
