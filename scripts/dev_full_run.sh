#!/usr/bin/env bash
# DEV full benchmark run on a small laptop (inside WSL): all 100 recordings
# through the agent using dev_harness.py (fp16 ASR), then scoring with the
# substitute judge (dev_judge.py) if JUDGE_MODEL is set, else exact match.
# Official reproduction is scripts/run_fdb_v3.sh.
#
#   bash scripts/dev_full_run.sh [label]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
V3="$ROOT/third_party/Full-Duplex-Bench/v3"
LABEL="${1:-dev_$(date +%m%d_%H%M)}"
OUT="$ROOT/eval/results/$LABEL"
mkdir -p "$OUT"

cd "$ROOT"
source .venv/bin/activate
tr -d '\r' < .env > "$V3/.env.local"
set -a; source <(tr -d '\r' < .env); set +a
export FDB_V3_DIR="$V3" HF_HUB_OFFLINE="${HF_HUB_OFFLINE:-1}" DEV_ASR_DEVICE="${DEV_ASR_DEVICE:-cuda-half}"

if ! curl -sf http://127.0.0.1:8880/v1/models >/dev/null; then
  python -m agent.kokoro_server < /dev/null > "$OUT/kokoro.log" 2>&1 &
  KOKORO_PID=$!
  for _ in $(seq 1 90); do curl -sf http://127.0.0.1:8880/v1/models >/dev/null && break; sleep 2; done
fi

: > /tmp/agent_tool_calls.log
python -m agent.main start < /dev/null > "$OUT/agent.log" 2>&1 &
AGENT_PID=$!
trap 'kill $AGENT_PID ${KOKORO_PID:-} 2>/dev/null || true' EXIT
sleep 15

echo "== inference ($LABEL) $(date)"
(cd "$V3" && python "$ROOT/scripts/dev_harness.py" --provider "$LABEL" --force < /dev/null) > "$OUT/inference.log" 2>&1
kill $AGENT_PID 2>/dev/null || true
cp /tmp/agent_tool_calls.log "$OUT/"

echo "== evaluation $(date)"
cd "$V3"
EVAL=(python)
JUDGE_FLAG=()
if [[ -n "${JUDGE_MODEL:-}" ]]; then
  EVAL=(python "$ROOT/scripts/dev_judge.py"); JUDGE_FLAG=(--use-llm)
  echo "judge: $JUDGE_MODEL (substitute, indicative only)" | tee "$OUT/JUDGE.txt"
elif [[ -n "${OPENAI_API_KEY:-}" ]]; then
  JUDGE_FLAG=(--use-llm); echo "judge: gpt-4o (official)" | tee "$OUT/JUDGE.txt"
else
  echo "judge: none (exact match)" | tee "$OUT/JUDGE.txt"
fi
"${EVAL[@]}" evaluate_tool_calls.py --benchmark benchmark_data_v2.json --results-dir fdb_v3_data_released \
  --provider "$LABEL" --output "$OUT/evaluation_report.json" "${JUDGE_FLAG[@]}" < /dev/null > "$OUT/eval_tool_calls.log" 2>&1
"${EVAL[@]}" evaluate_pass_rate.py --benchmark benchmark_data_v2.json --results-dir fdb_v3_data_released \
  --provider "$LABEL" --output "$OUT/pass_rate_report.json" "${JUDGE_FLAG[@]}" < /dev/null > "$OUT/eval_pass_rate.log" 2>&1
find fdb_v3_data_released -name "result_${LABEL}.json" -exec cp --parents {} "$OUT/" \;
grep -v -E 'KEY|SECRET|TOKEN' "$ROOT/.env" | tr -d '\r' > "$OUT/config.env" || true
echo "== done $(date): $OUT"
tail -25 "$OUT/eval_pass_rate.log"
