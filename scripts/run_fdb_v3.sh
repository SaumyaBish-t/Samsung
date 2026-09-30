#!/usr/bin/env bash
# One-command FDB-v3 reproduction: install -> configure -> preflight -> run -> evaluate.
#
#   cp .env.example .env   # fill in keys
#   bash scripts/run_fdb_v3.sh
#
# Tested target: Ubuntu 22.04, Python 3.10, NVIDIA GPU + CUDA 12.x.
# System packages: ffmpeg unzip espeak-ng python3.10-venv. Docker optional
# (KOKORO_MODE=docker); default runs Kokoro as a local Python server.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FDB_REPO="https://github.com/DanielLin94144/Full-Duplex-Bench"
FDB_COMMIT="3e799c45a045256f47d5f1c9cda90157e2d2ec9e"   # pinned 2026-05-20
FDB_DIR="$ROOT/third_party/Full-Duplex-Bench"
V3="$FDB_DIR/v3"
DATA_GDRIVE_ID="1SO_4MTazWQ_jvCx0dtmpQ-t40bdd07yz"
PROVIDER_LABEL="${PROVIDER_LABEL:-interrupt_agent}"
KOKORO_MODE="${KOKORO_MODE:-python}"   # python = agent/kokoro_server.py (default) | docker
KOKORO_IMAGE="${KOKORO_IMAGE:-ghcr.io/remsky/kokoro-fastapi-gpu:latest}"   # only for KOKORO_MODE=docker
RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT="$ROOT/eval/results/$RUN_ID"
mkdir -p "$OUT"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

[[ -f .env ]] || { echo "Missing .env — copy .env.example to .env and fill in keys."; exit 1; }

# ── 1. Benchmark checkout (pinned) ──────────────────────────────────
log "FDB-v3 @ $FDB_COMMIT"
if [[ ! -d "$FDB_DIR/.git" ]]; then
  git clone "$FDB_REPO" "$FDB_DIR"
fi
git -C "$FDB_DIR" fetch --quiet origin "$FDB_COMMIT" || true
git -C "$FDB_DIR" checkout --quiet "$FDB_COMMIT"

# ── 2. Python env ──────────────────────────────────────────────────
log "Python environment"
if [[ ! -d .venv ]]; then
  python3.10 -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate
pip install --quiet --upgrade pip
pip install --quiet -r requirements.txt
[[ "$KOKORO_MODE" == python ]] && pip install --quiet -r requirements-kokoro-local.txt \
  && python -m spacy download en_core_web_sm -q
pip install --quiet "nemo_toolkit[asr]" pydub ffmpeg-python gdown   # harness-side ASR + data download

# ── 3. Benchmark data ──────────────────────────────────────────────
if [[ ! -d "$V3/fdb_v3_data_released" ]]; then
  log "Downloading benchmark audio"
  gdown --quiet "$DATA_GDRIVE_ID" -O "$V3/fdb_v3_data.archive"
  (cd "$V3" && { unzip -q fdb_v3_data.archive 2>/dev/null || tar -xf fdb_v3_data.archive; } && rm -f fdb_v3_data.archive)
fi
[[ -d "$V3/fdb_v3_data_released" ]] || { echo "Data folder fdb_v3_data_released not found after extract."; exit 1; }

# Harness reads LiveKit + judge keys from v3/.env.local
tr -d '\r' < .env > "$V3/.env.local"   # tolerate CRLF .env edited on Windows
set -a; source <(tr -d '\r' < .env); set +a
export FDB_V3_DIR="$V3"

# ── 4. Local services ──────────────────────────────────────────────
log "Kokoro TTS ($KOKORO_MODE)"
if ! curl -sf "http://127.0.0.1:8880/v1/models" >/dev/null; then
  if [[ "$KOKORO_MODE" == docker ]]; then
    docker rm -f fdb-kokoro >/dev/null 2>&1 || true
    GPU_FLAG=""; [[ "$KOKORO_IMAGE" == *gpu* ]] && GPU_FLAG="--gpus all"
    # shellcheck disable=SC2086
    docker run -d --name fdb-kokoro $GPU_FLAG -p 8880:8880 "$KOKORO_IMAGE" >/dev/null
  else
    python -m agent.kokoro_server > "$OUT/kokoro.log" 2>&1 &
    KOKORO_PID=$!
  fi
  for _ in $(seq 1 180); do curl -sf "http://127.0.0.1:8880/v1/models" >/dev/null && break; sleep 2; done
fi
curl -sf "http://127.0.0.1:8880/v1/models" >/dev/null || { echo "Kokoro TTS did not come up on :8880"; exit 1; }

log "Model files (VAD / turn detector)"
python -m agent.main download-files

# ── 5. Preflight ───────────────────────────────────────────────────
log "Preflight"
python scripts/preflight.py | tee "$OUT/preflight.txt"

# ── 6. Start agent worker ──────────────────────────────────────────
log "Starting agent worker"
: > /tmp/agent_tool_calls.log
: > /tmp/agent_heartbeat.log
python -m agent.main start > "$OUT/agent.log" 2>&1 &
AGENT_PID=$!
trap 'kill $AGENT_PID ${KOKORO_PID:-} 2>/dev/null || true' EXIT
sleep 15   # worker registration with LiveKit Cloud

# ── 7. Inference ───────────────────────────────────────────────────
log "Inference over all scenarios (provider label: $PROVIDER_LABEL)"
(cd "$V3" && python run_tool_benchmark_all_released.py --provider "$PROVIDER_LABEL" --force) | tee "$OUT/inference.log"
kill $AGENT_PID 2>/dev/null || true

# ── 8. Evaluation (LLM judge) ──────────────────────────────────────
log "Evaluation"
cd "$V3"
python evaluate_tool_calls.py --benchmark benchmark_data_v2.json --results-dir fdb_v3_data_released \
  --provider "$PROVIDER_LABEL" --output "$OUT/${PROVIDER_LABEL}_evaluation_report.json" --use-llm | tee "$OUT/eval_tool_calls.log"
python evaluate_pass_rate.py --benchmark benchmark_data_v2.json --results-dir fdb_v3_data_released \
  --provider "$PROVIDER_LABEL" --output "$OUT/${PROVIDER_LABEL}_pass_rate_report.json" --use-llm | tee "$OUT/eval_pass_rate.log"
python analyze_tool_latency.py --results-dir fdb_v3_data_released --provider "$PROVIDER_LABEL" | tee "$OUT/eval_latency.log"
mv -f ./*"${PROVIDER_LABEL}"*_report.json "$OUT/" 2>/dev/null || true

# ── 9. Collect run artifacts ───────────────────────────────────────
cp /tmp/agent_tool_calls.log /tmp/agent_heartbeat.log "$OUT/"
find fdb_v3_data_released -name "result_${PROVIDER_LABEL}.json" -exec cp --parents {} "$OUT/" \;
grep -v -E 'KEY|SECRET|TOKEN' "$ROOT/.env" > "$OUT/config.env" || true   # config without secrets
pip freeze > "$OUT/pip-freeze.txt"

log "Done. Results in $OUT"
