# PipeKit

Headless, deploy-anywhere voice infrastructure. A single `docker compose up` gives you
a low-latency **VAD → STT → LLM → TTS** pipeline behind an **OpenAI Realtime-compatible
WebSocket**, with every model running locally on your own GPU — no provider APIs, no
per-minute billing, no audio leaving your VPC.

PipeKit is a thin deployment wrapper around [`huggingface/speech-to-speech`](https://github.com/huggingface/speech-to-speech).
All the pipeline logic lives upstream; this repo owns the compose topology, the GPU
sizing, the operational scripts, and the pinned version.

```
                    ┌──────────────────────────────────────────┐
  client ──ws──▶    │ pipekit-core                             │
  (OpenAI Realtime) │  Silero VAD → Parakeet TDT → LLM → Qwen3 │
                    └───────────────────┬──────────────────────┘
                                        │ http (OpenAI-compatible)
                    ┌───────────────────▼──────────────────────┐
                    │ llm-engine — llama.cpp server-cuda       │
                    └──────────────────────────────────────────┘
                              both share GPU 0
```

## Stack

| Stage | Component | Why |
|---|---|---|
| VAD | Silero VAD v5 (built in) | turn-taking and speech boundaries |
| STT | Parakeet TDT (`--stt parakeet-tdt`) | fast streaming partial transcripts |
| LLM | any GGUF via llama.cpp | fully local, OpenAI-compatible endpoint |
| TTS | Qwen3-TTS (`--tts qwen3`) | streams synthesized chunks as they generate |

Parakeet and Qwen3-TTS are default dependencies of the upstream package on Linux, so
the stock Dockerfile covers them — there is no extra wheel to install.

## Sizing the GPU

STT, LLM and TTS weights all co-reside, so VRAM is the binding constraint.

| Instance | GPU | VRAM | Settings |
|---|---|---|---|
| `g5.xlarge` | A10G | 24 GB | defaults as shipped (`LLM_CTX=32768`) |
| `g4dn.xlarge` | T4 | 16 GB | `LLM_CTX=8192`, `NUM_PIPELINES=1`, consider dropping `--swa-full` |

`NUM_PIPELINES` sets max concurrent sessions; each pipeline holds its own STT/TTS
handlers, so raise it only with VRAM to spare. Connections beyond the pool size are
rejected with `session_limit_reached` rather than queued.

## Deploy

**1. Launch the instance.** Use the **Ubuntu Deep Learning AMI** — it ships the NVIDIA
driver, CUDA runtime and NVIDIA Container Toolkit already configured for GPU Docker.
Give it ~60 GB of EBS (the CUDA image plus model weights are large). Open TCP 8765 in
the security group, scoped to callers you trust; PipeKit has **no built-in
authentication** (see [Exposing it safely](#exposing-it-safely)).

**2. Preflight.**

```bash
git clone <this repo> pipekit && cd pipekit
cp .env.example .env    # set HF_TOKEN
./scripts/bootstrap-ec2.sh
```

Read-only by default: it checks driver, VRAM, Docker, Compose v2, GPU passthrough and
disk. On a non-DLAMI host, `./scripts/bootstrap-ec2.sh --install-toolkit` installs the
container toolkit.

**3. Bring it up.**

```bash
docker compose up -d
docker compose logs -f pipekit-core
```

First boot pulls the CUDA base image, builds the pipeline, and downloads the GGUF plus
STT/TTS weights into `./cache/` — expect 10–20 minutes. Subsequent restarts are fast
because the cache is a bind mount. Wait for:

```
OpenAI Realtime API starting on ws://0.0.0.0:8765/v1/realtime (pool size 1)
```

**4. Verify.**

```bash
pip install websockets
make smoke HOST=<ec2-ip>                          # session opens?
make smoke HOST=<ec2-ip> AUDIO=hello.wav          # full turn + time-to-first-audio
```

`hello.wav` must be 16 kHz mono 16-bit: `ffmpeg -i in.mp3 -ar 16000 -ac 1 -c:a pcm_s16le hello.wav`.

## Consuming the API

`ws://<host>:8765/v1/realtime` speaks the OpenAI Realtime protocol, so standard
Realtime client SDKs work — just repoint the base URL. No custom socket code.

```python
from openai import AsyncOpenAI

client = AsyncOpenAI(base_url="http://<ec2-ip>:8765/v1", api_key="unused")

async with client.realtime.connect(model="local") as conn:
    await conn.input_audio_buffer.append(audio=b64_pcm16)   # 16 kHz mono
    async for event in conn:
        if event.type == "response.output_audio.delta":
            play(event.delta)
```

Audio in and out is PCM16 at **16 kHz** by default (the pipeline's native rate). The
server resamples if you declare a different rate via `session.update`.

Events implemented upstream:

- **client → server:** `input_audio_buffer.append`, `input_audio_buffer.commit`,
  `session.update`, `conversation.item.create`, `response.create`, `response.cancel`
- **server → client:** `session.created`, `input_audio_buffer.speech_started` /
  `speech_stopped`, `conversation.item.input_audio_transcription.delta` / `.completed`,
  `response.created`, `response.output_audio.delta` / `.done`,
  `response.output_audio_transcript.done`, `response.function_call_arguments.done`,
  `response.done`, `error`

Barge-in works: when the VAD detects speech mid-response, the in-flight response is
cancelled with `response.done { status: "cancelled", reason: "turn_detected" }`.

### Operational endpoints

Plain HTTP on the same port:

```bash
make pool HOST=<ec2-ip>    # GET /v1/pool  — per-unit idle/active/stuck + session ids
make usage HOST=<ec2-ip>   # GET /v1/usage — aggregate counters, errors by type
```

`/v1/pool` is also the container healthcheck. A unit reported as `stuck` means a
session never drained — restart `pipekit-core`.

## Leaner transport: raw PCM

Skip the Realtime protocol entirely — no JSON envelope, no interruption events, no live
transcripts. Stream 16 kHz int16 mono PCM in, get audio bytes out:

```bash
docker compose -f docker-compose.yml -f docker-compose.raw-pcm.yml up -d
# or: make up-raw
```

This swaps `--mode realtime` for `--mode websocket` on the same port. Note that
`/v1/pool` and `/v1/usage` do not exist in this mode (the override switches the
healthcheck to a TCP connect), and `make smoke` will report the missing pool endpoint
before failing to complete a Realtime handshake — that is expected.

## Tuning

Everything below lives in `.env`; see `.env.example` for the full list.

| Knob | Effect |
|---|---|
| `LLM_MODEL` | any GGUF repo llama.cpp can serve with `-hf` |
| `LLM_CTX` / `LLM_PARALLEL` | KV cache size and slots — the main VRAM dial |
| `NUM_PIPELINES` | concurrent realtime sessions |
| `VAD_THRESHOLD` | raise it if background noise triggers turns; lower it if quiet speech is missed |
| `SYSTEM_PROMPT` | injected as the initial system turn |
| `S2S_REF` | pinned upstream commit; set to `main` to track the tip |

Swapping components is a flag change in `docker-compose.yml` —
`--stt faster-whisper`, `--tts kokoro`, `--llm_backend transformers` for in-process
inference instead of a separate llama.cpp container. Upstream extras
(`faster-whisper`, `kokoro`, …) need a Dockerfile change to install, since the pinned
image only builds the default dependency set.

## Exposing it safely

There is no authentication on `/v1/realtime` — anyone who can reach port 8765 can use
your GPU. Do not put it on `0.0.0.0` in a public subnet. Options, roughly in order of
effort: restrict the security group to known CIDRs; put an ALB or nginx in front to
terminate TLS (`wss://`) and check a bearer token; or keep 8765 private and reach it
through a VPN or Tailscale. `llm-engine` is already bound to loopback so only
`pipekit-core` can reach it.

## Layout

```
docker-compose.yml           llm-engine + pipekit-core, realtime mode
docker-compose.raw-pcm.yml   override for raw PCM transport
.env.example                 all tunables
Makefile                     up / down / logs / pool / usage / smoke
scripts/bootstrap-ec2.sh     preflight (read-only unless --install-toolkit)
scripts/smoke_test.py        realtime client: session check + full-turn latency
scripts/lint-compose.sh      compose lint, also run by CI
cache/                       HF + GGUF cache, shared by both containers (gitignored)
```

`make lint` runs the same checks as the `lint` workflow: yamllint (config in
`.yamllint.yml`), `docker compose config` for both the base file and the raw-PCM
override, a guard that every `${VAR}` has a default so a missing env var cannot
silently become an empty string, and a check that `.env.example` documents every
variable the compose files reference.

## Notes on the build

- `pipekit-core` builds directly from the upstream git context, pinned to a commit
  (`S2S_REF`) rather than a floating `main`, so redeploys are reproducible. Upstream's
  latest tag is `v0.2.9` while `main` is `0.2.11.dev`; the pinned commit is on `main`
  because the `chat-completions` backend and the realtime pipeline pool are not in
  `v0.2.9`.
- The LLM image is `ghcr.io/ggml-org/llama.cpp:server-cuda` — the project moved from
  the `ggerganov` namespace to `ggml-org`.
- The GGUF is fetched by llama.cpp via `-hf` into the shared cache; there is no manual
  model download or `./models` volume to populate.
- `--llm_backend chat-completions` targets `/v1/chat/completions`. Upstream's own
  compose uses `responses-api` against llama.cpp instead; if you hit a backend
  incompatibility, that is the first thing to switch (both backends read the same
  `--responses_api_*` flags).
