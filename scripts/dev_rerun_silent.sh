#!/usr/bin/env bash
# DEV: re-run recordings where the agent heard nothing (infrastructure
# failure: no tool call AND empty agent transcript), e.g. after the laptop ran
# out of memory and the harness's audio client never streamed.
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
label = sys.argv[1]
for f in sorted(glob.glob(f"fdb_v3_data_released/*/result_{label}.json")):
    r = json.load(open(f))
    if not r.get("actual_tool_calls") and not (r.get("transcript") or "").strip():
        folder = f.split("/")[1]
        example, pid = folder.rsplit("_", 1)
        print(f"{example} {pid}")
PY
)
echo "silent recordings: ${#SILENT[@]}"
[[ ${#SILENT[@]} -gt 0 ]] || exit 0

if ! curl -sf http://127.0.0.1:8880/v1/models >/dev/null; then
  python -m agent.kokoro_server < /dev/null > "$OUT/kokoro_rerun.log" 2>&1 &
  KOKORO_PID=$!
  for _ in $(seq 1 90); do curl -sf http://127.0.0.1:8880/v1/models >/dev/null && break; sleep 2; done
fi
python -m agent.main start < /dev/null >> "$OUT/agent_rerun.log" 2>&1 &
AGENT_PID=$!
trap 'kill $AGENT_PID ${KOKORO_PID:-} 2>/dev/null || true' EXIT
sleep 15

cd "$V3"
for item in "${SILENT[@]}"; do
  read -r ex pid <<< "$item"
  echo "$(date -Is) rerun $ex $pid (silent: no audio reached agent)" | tee -a "$OUT/RERUNS.txt"
  python "$ROOT/scripts/dev_harness.py" --provider "$LABEL" --example "$ex" --pid "$pid" --force \
    < /dev/null >> "$OUT/inference_rerun.log" 2>&1
done
cat /tmp/agent_tool_calls.log >> "$OUT/agent_tool_calls.log"
echo "done; re-evaluate with the same judge as the main run"
