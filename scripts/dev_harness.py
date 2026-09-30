#!/usr/bin/env python3
"""DEV ONLY — run FDB-v3's run_tool_benchmark.py on a small-GPU laptop.

The harness loads parakeet ASR in fp32 on the GPU, which does not fit next to
Kokoro on a 6 GB card. This wrapper swaps only the ASR loader (fp16 on GPU,
or CPU with DEV_ASR_DEVICE=cpu) and then runs the unmodified harness main().
Scoring logic is untouched. The official run (scripts/run_fdb_v3.sh) never
uses this file.

    cd third_party/Full-Duplex-Bench/v3
    python ../../../scripts/dev_harness.py --provider smoke --example travel_09 --force
"""

import os
import sys

sys.path.insert(0, os.getcwd())
import run_tool_benchmark as rtb  # noqa: E402

DEVICE = os.getenv("DEV_ASR_DEVICE", "cuda-half")


def load_asr_model_small_gpu():
    print(f"🔊 Loading ASR model (dev wrapper, device={DEVICE})...")
    import nemo.collections.asr as nemo_asr
    import torch

    model = nemo_asr.models.ASRModel.from_pretrained(model_name=rtb.ASR_MODEL_NAME, map_location="cpu")
    if DEVICE == "cuda-half" and torch.cuda.is_available():
        model = model.half().cuda()
    model.eval()
    print("✅ ASR model loaded")
    return model


rtb.load_asr_model = load_asr_model_small_gpu

if __name__ == "__main__":
    rtb.main()
