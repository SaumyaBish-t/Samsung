#!/usr/bin/env bash
# DEV: score an existing run label. Uses the substitute judge (dev_judge.py)
# when JUDGE_MODEL is set, else GPT-4o if OPENAI_API_KEY is set, else exact match.
#
#   bash scripts/dev_eval.sh <label>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
V3="$ROOT/third_party/Full-Duplex-Bench/v3"
LABEL="$1"
OUT="$ROOT/eval/results/$LABEL"
mkdir -p "$OUT"

cd "$ROOT"
source .venv/bin/activate
set -a; source <(tr -d '\r' < .env); set +a

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
python analyze_tool_latency.py --results-dir fdb_v3_data_released --provider "$LABEL" < /dev/null > "$OUT/eval_latency.log" 2>&1 || true

find fdb_v3_data_released -name "result_${LABEL}.json" -exec cp --parents {} "$OUT/" \;
grep -v -E 'KEY|SECRET|TOKEN' "$ROOT/.env" | tr -d '\r' > "$OUT/config.env" || true
echo "== scored $LABEL -> $OUT"
tail -30 "$OUT/eval_pass_rate.log"
