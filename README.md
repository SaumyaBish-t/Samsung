# Interruptible Real-Time Voice Agent — Theme 05

LiveKit voice agent evaluated on Full-Duplex-Bench v3 (FDB-v3).

## Architecture

```
benchmark WAV / mic
   │
   ▼
Silero VAD ─► Groq Whisper STT ─► LiveKit turn detector (waits out "um… no wait…")
                                        │ final user turn
                                        ▼
                        Planner LLM (Ollama Cloud gpt-oss:120b, fallback gemma4:31b)
                        • resolves self-corrections (last value wins)
                        • emits independent tool calls together
                                        │
                                        ▼
                        Tool layer (per-room, no cross-scenario state)
                        • blocking mocks run in a worker thread (loop never stalls)
                        • ledger: identical call never executed twice
                        • calls from an interrupted/superseded turn are dropped
                                        │ tool results
                                        ▼
                        grounded short answer ─► Kokoro TTS (interruptible)
```

## Providers (declaration)

| Layer | Model | Where | Key |
|---|---|---|---|
| VAD | Silero | local | — |
| Turn detection | LiveKit `EnglishModel` | local | — |
| STT | `whisper-large-v3-turbo` | Groq API | `GROQ_API_KEY` |
| Planner | `gpt-oss:120b` → fallback `gemma4:31b` | Ollama Cloud | `OLLAMA_API_KEY` |
| TTS | Kokoro-82M (`af_heart`) | local Python server `agent/kokoro_server.py` (Docker optional) | — |
| Transport | LiveKit Cloud | hosted | `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET` |
| Judge (benchmark) | gpt-4o | OpenAI | `OPENAI_API_KEY` |

All keys go in `.env` (template: `.env.example`). No keys are committed.

## Reproduce

Requirements: Ubuntu 22.04, Python 3.10, NVIDIA GPU + CUDA 12.x, and `apt install ffmpeg unzip espeak-ng python3.10-venv`. No Docker needed.

```bash
cp .env.example .env    # fill in keys
bash scripts/run_fdb_v3.sh
```

The script pins FDB-v3 to a fixed commit, installs deps, downloads the data, starts the local Kokoro server,
runs a preflight (keys + tool-call smoke test on both planner models), runs all 100 scenarios,
evaluates with the LLM judge, and writes everything to `eval/results/<timestamp>/`.

## Repo layout

```
agent/        main.py (worker) · tools.py (12 tools, ledger) · providers.py · prompts.py · config.py
scripts/      run_fdb_v3.sh · preflight.py
eval/results/ scores, logs, config per run
extension/    ★ EXTENSION USE CASE (TODO)
```

## Extension use case ★

TODO — camera-frame device troubleshooting.

## Results

TODO — fill from `eval/results/<best run>/`.
