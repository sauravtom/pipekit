#!/usr/bin/env python3
"""Verify a PipeKit deployment over the OpenAI Realtime protocol.

Without --audio it checks that the pool endpoint responds and that a session
opens. With --audio it streams a wav through a full turn and reports
time-to-first-audio, which is the latency number that actually matters.

    pip install websockets
    python scripts/smoke_test.py --host <ec2-ip>
    python scripts/smoke_test.py --host <ec2-ip> --audio hello.wav --out reply.wav

Input must be 16 kHz mono 16-bit PCM wav. To convert:
    ffmpeg -i in.mp3 -ar 16000 -ac 1 -c:a pcm_s16le hello.wav
"""

import argparse
import asyncio
import base64
import json
import sys
import time
import urllib.error
import urllib.request
import wave

try:
    import websockets
except ImportError:
    sys.exit("missing dependency: pip install websockets")

PIPELINE_RATE = 16000
CHUNK_MS = 20


def check_pool(host: str, port: int) -> bool:
    """GET /v1/pool — served on the same port as the websocket in realtime mode."""
    url = f"http://{host}:{port}/v1/pool"
    try:
        with urllib.request.urlopen(url, timeout=5) as resp:
            body = json.load(resp)
    except (urllib.error.URLError, OSError, json.JSONDecodeError) as exc:
        print(f"  ✗ {url}: {exc}")
        return False
    units = body.get("units", body)
    print(f"  ✓ pool: {json.dumps(units)}")
    return True


def read_wav(path: str) -> bytes:
    with wave.open(path, "rb") as wf:
        if (wf.getnchannels(), wf.getsampwidth(), wf.getframerate()) != (1, 2, PIPELINE_RATE):
            sys.exit(
                f"{path} is {wf.getnchannels()}ch / {wf.getsampwidth() * 8}-bit / {wf.getframerate()} Hz.\n"
                f"Convert first: ffmpeg -i {path} -ar 16000 -ac 1 -c:a pcm_s16le out.wav"
            )
        return wf.readframes(wf.getnframes())


def write_wav(path: str, pcm: bytes) -> None:
    with wave.open(path, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(PIPELINE_RATE)
        wf.writeframes(pcm)


async def stream_audio(ws, pcm: bytes) -> None:
    """Append audio in real time so the server-side VAD sees a natural cadence."""
    bytes_per_chunk = int(PIPELINE_RATE * CHUNK_MS / 1000) * 2
    for off in range(0, len(pcm), bytes_per_chunk):
        chunk = pcm[off : off + bytes_per_chunk]
        await ws.send(
            json.dumps(
                {
                    "type": "input_audio_buffer.append",
                    "audio": base64.b64encode(chunk).decode(),
                }
            )
        )
        await asyncio.sleep(CHUNK_MS / 1000)
    await ws.send(json.dumps({"type": "input_audio_buffer.commit"}))


async def run(args: argparse.Namespace) -> int:
    uri = f"ws://{args.host}:{args.port}/v1/realtime"
    print(f"PipeKit smoke test → {uri}")

    if not check_pool(args.host, args.port):
        print("  (expected in raw-PCM mode, which serves no HTTP routes)")

    pcm = read_wav(args.audio) if args.audio else None

    try:
        ws = await asyncio.wait_for(websockets.connect(uri, max_size=None), timeout=args.timeout)
    except (OSError, asyncio.TimeoutError, websockets.exceptions.WebSocketException) as exc:
        print(f"  ✗ connect failed: {exc}")
        return 1

    async with ws:
        raw = await asyncio.wait_for(ws.recv(), timeout=args.timeout)
        first = json.loads(raw)
        if first.get("type") != "session.created":
            print(f"  ✗ expected session.created, got {first.get('type')}: {first}")
            return 1
        print(f"  ✓ session.created (session {first.get('session', {}).get('id', '?')})")

        if pcm is None:
            print("\nTransport is healthy. Re-run with --audio to exercise a full turn.")
            return 0

        secs = len(pcm) / (PIPELINE_RATE * 2)
        print(f"  → streaming {secs:.1f}s of audio")
        sender = asyncio.create_task(stream_audio(ws, pcm))
        sent_at = time.monotonic()

        audio_out = bytearray()
        first_audio_at = None
        transcripts: list[str] = []
        reply_text = None

        try:
            while True:
                event = json.loads(await asyncio.wait_for(ws.recv(), timeout=args.timeout))
                etype = event.get("type")

                if etype == "input_audio_buffer.speech_started":
                    print("  · speech_started")
                elif etype == "conversation.item.input_audio_transcription.completed":
                    text = event.get("transcript", "")
                    transcripts.append(text)
                    print(f"  · heard: {text!r}")
                elif etype == "response.output_audio.delta":
                    if first_audio_at is None:
                        first_audio_at = time.monotonic()
                        print(f"  · first audio after {first_audio_at - sent_at:.2f}s")
                    audio_out += base64.b64decode(event["delta"])
                elif etype == "response.output_audio_transcript.done":
                    reply_text = event.get("transcript", "")
                    print(f"  · said: {reply_text!r}")
                elif etype == "response.done":
                    status = event.get("response", {}).get("status", "?")
                    print(f"  · response.done ({status})")
                    break
                elif etype == "error":
                    print(f"  ✗ error: {event.get('error')}")
                    return 1
        except asyncio.TimeoutError:
            print(f"  ✗ no further events for {args.timeout}s")
            return 1
        finally:
            sender.cancel()

    if not audio_out:
        print("\n✗ no audio came back. Check `make logs`; if the VAD never fired, "
              "lower VAD_THRESHOLD or use a louder recording.")
        return 1

    write_wav(args.out, bytes(audio_out))
    dur = len(audio_out) / (PIPELINE_RATE * 2)
    print(f"\n✓ {dur:.1f}s of reply audio → {args.out}")
    if first_audio_at:
        print(f"  time to first audio: {first_audio_at - sent_at:.2f}s")
    return 0


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--host", default="localhost")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--audio", help="16 kHz mono 16-bit wav to send")
    p.add_argument("--out", default="reply.wav", help="where to write the reply (default: reply.wav)")
    p.add_argument("--timeout", type=float, default=60.0, help="per-event timeout in seconds")
    args = p.parse_args()
    try:
        sys.exit(asyncio.run(run(args)))
    except KeyboardInterrupt:
        sys.exit(130)


if __name__ == "__main__":
    main()
