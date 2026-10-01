#!/usr/bin/env bash
# DEV: (re-)run recordings that have no result yet, or where the agent heard
# nothing (infrastructure failure: no tool call AND empty agent transcript),
# e.g. after the laptop ran out of memory. Each recording runs in a fresh
# harness process: the long-lived NeMo ASR process leaks RAM (4.6 GB after
# ~60 recordings) and starves the audio client on small machines.
# Re-runs are listed in eval/results/<label>/RERUNS.txt for transparency.
#
#   bash scripts/dev_rerun_silent.sh <label>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
V3="$ROOT/third_party/Full-Duplex-Bench/v3"
LABEL="$1"
OUT="$ROOT/eval/results/$LABEL"
mkdir -p "$OUT"

cd "$ROOT"
source .venv/bin/activate
tr -d '\r' < .env > "$V3/.env.local"
set -a; source <(tr -d '\r' < .env); set +a
export FDB_V3_DIR="$V3" HF_HUB_OFFLINE="${HF_HUB_OFFLINE:-1}" DEV_ASR_DEVICE="${DEV_ASR_DEVICE:-cuda-half}"

mapfile -t SILENT < <(cd "$V3" && python - "$LABEL" <<'PY'
import glob, json, sys
import os
label = sys.argv[1]
for wav in sorted(glob.glob("fdb_v3_data_released/*/input.wav")):
    folder = wav.split("/")[1]
    res = f"fdb_v3_data_released/{folder}/result_{label}.json"
    if os.path.exists(res):
        r = json.load(open(res))
        if r.get("actual_tool_calls") or (r.get("transcript") or "").strip():
            continue
        why = "silent"
    else:
        why = "missing"
    example, pid = folder.rsplit("_", 1)
    print(f"{example} {pid} {why}")
PY
)
echo "recordings to (re-)run: ${#SILENT[@]}"
[[ ${#SILENT[@]} -gt 0 ]] || exit 0

if ! curl -sf http://127.0.0.1:8880/v1/models >/dev/null; then
  python -m agent.kokoro_server < /dev/null > "$OUT/kokoro_rerun.log" 2>&1 &
  KOKORO_PID=$!
  for _ in $(seq 1 90); do curl -sf http://127.0.0.1:8880/v1/models >/dev/null && break; sleep 2; done
fi
: > /tmp/agent_tool_calls.log   # main run already copied its log into $OUT
python -m agent.main start < /dev/null >> "$OUT/agent_rerun.log" 2>&1 &
AGENT_PID=$!
trap 'kill $AGENT_PID ${KOKORO_PID:-} 2>/dev/null || true' EXIT
sleep 15

cd "$V3"
for item in "${SILENT[@]}"; do
  read -r ex pid why <<< "$item"
  echo "$(date -Is) run $ex $pid ($why)" | tee -a "$OUT/RERUNS.txt"
  python "$ROOT/scripts/dev_harness.py" --provider "$LABEL" --example "$ex" --pid "$pid" --force \
    < /dev/null >> "$OUT/inference_rerun.log" 2>&1
done
cat /tmp/agent_tool_calls.log >> "$OUT/agent_tool_calls.log"
echo "done; now run: bash scripts/dev_eval.sh $LABEL"
