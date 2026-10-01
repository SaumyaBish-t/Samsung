#!/usr/bin/env bash
# Quick dev loop (inside WSL): run a few scenarios end to end and print
# expected vs actual tool calls. Assumes install + Kokoro already done.
#
#   bash scripts/smoke_test.sh                       # default mix
#   bash scripts/smoke_test.sh ecommerce_09 finance_12  # specific example IDs
#
# Uses scripts/dev_harness.py (fp16 ASR) so it fits a 6 GB laptop GPU.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
V3="$ROOT/third_party/Full-Duplex-Bench/v3"
LABEL="${PROVIDER_LABEL:-smoke}"
EXAMPLES=("$@")
[[ ${#EXAMPLES[@]} -gt 0 ]] || EXAMPLES=(ecommerce_01 ecommerce_09 finance_12 housing_09 ecommerce_18)  # easy, 3x self-correction, hard

cd "$ROOT"
source .venv/bin/activate
tr -d '\r' < .env > "$V3/.env.local"   # tolerate CRLF .env edited on Windows
set -a; source <(tr -d '\r' < .env); set +a
export FDB_V3_DIR="$V3" HF_HUB_OFFLINE="${HF_HUB_OFFLINE:-1}"
export DEV_ASR_DEVICE="${DEV_ASR_DEVICE:-cuda-half}"   # cpu option starves a 7 GB-RAM WSL during live audio

if ! curl -sf http://127.0.0.1:8880/v1/models >/dev/null; then
  python -m agent.kokoro_server < /dev/null > /tmp/smoke_kokoro.log 2>&1 &
  KOKORO_PID=$!
  for _ in $(seq 1 60); do curl -sf http://127.0.0.1:8880/v1/models >/dev/null && break; sleep 2; done
fi

: > /tmp/agent_tool_calls.log
python -m agent.main start < /dev/null > /tmp/smoke_agent.log 2>&1 &
AGENT_PID=$!
trap 'kill $AGENT_PID ${KOKORO_PID:-} 2>/dev/null || true' EXIT
sleep 12

cd "$V3"
for ex in "${EXAMPLES[@]}"; do
  python "$ROOT/scripts/dev_harness.py" --provider "$LABEL" --example "$ex" --force < /dev/null 2>&1 | grep -E "Transcript|Perceived|❌|⚠️" || true
done

python - "$LABEL" "${EXAMPLES[@]}" <<'PY'
import json, sys, glob
label, examples = sys.argv[1], sys.argv[2:]
for ex in examples:
    for d in sorted(glob.glob(f"fdb_v3_data_released/{ex}_*")):
        meta = json.load(open(f"{d}/metadata.json"))
        try:
            res = json.load(open(f"{d}/result_{label}.json"))
        except FileNotFoundError:
            print(f"\n{d}: NO RESULT"); continue
        exp = [(c["function"], c["args"]) for c in meta["expected_tool_calls"]]
        act = [(c["function"], c["args"]) for c in res.get("actual_tool_calls", [])]
        names_ok = sorted(f for f, _ in exp) == sorted(f for f, _ in act)
        print(f"\n{'OK ' if names_ok else 'BAD'} {d.split('/')[-1]}  latency={res.get('perceived_total_latency')}s")
        print("   expected:", exp)
        print("   actual:  ", act)
        print("   said:    ", (res.get("transcript") or "")[:160])
PY
