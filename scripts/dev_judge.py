#!/usr/bin/env python3
"""DEV ONLY — run FDB-v3's evaluation scripts with a substitute LLM judge.

The official judge is GPT-4o (hardcoded in the harness). For our own
iteration we may use any OpenAI-compatible endpoint instead, e.g. NVIDIA NIM.
This wrapper only swaps the judge's base URL / key / model name, then runs
the unmodified evaluation script. Scores from a substitute judge are
indicative only: always label them with the judge model, never present them
as official FDB-v3 numbers.

    JUDGE_BASE_URL=https://integrate.api.nvidia.com/v1 JUDGE_API_KEY=nvapi-... \
    JUDGE_MODEL=<model id> \
    python ../../../scripts/dev_judge.py evaluate_pass_rate.py --benchmark ... --use-llm
"""

import os
import runpy
import sys

from openai.resources.chat import completions as _completions

JUDGE_MODEL = os.environ["JUDGE_MODEL"]
os.environ["OPENAI_BASE_URL"] = os.environ.get("JUDGE_BASE_URL", os.environ.get("OPENAI_BASE_URL", ""))
os.environ["OPENAI_API_KEY"] = os.environ.get("JUDGE_API_KEY", os.environ.get("OPENAI_API_KEY", ""))

_original_create = _completions.Completions.create
stats = {"calls": 0, "errors": 0}


def _create(self, *args, **kwargs):
    kwargs["model"] = JUDGE_MODEL
    stats["calls"] += 1
    try:
        return _original_create(self, *args, **kwargs)
    except Exception:
        stats["errors"] += 1  # harness silently falls back to exact match on errors
        raise


_completions.Completions.create = _create

if __name__ == "__main__":
    script, sys.argv = sys.argv[1], sys.argv[1:]
    sys.path.insert(0, os.getcwd())
    try:
        runpy.run_path(script, run_name="__main__")
    finally:
        print(f"[dev_judge] judge={JUDGE_MODEL} calls={stats['calls']} errors={stats['errors']}", file=sys.stderr)
