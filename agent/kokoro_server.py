#!/usr/bin/env python3
"""Minimal local Kokoro TTS server with an OpenAI-compatible endpoint.

Runs on the evaluation machine as part of the submission (no Docker needed):

    python -m agent.kokoro_server            # serves http://127.0.0.1:8880/v1

POST /v1/audio/speech  {"input": "...", "voice": "af_heart", "response_format": "wav"|"pcm", "speed": 1.0}
GET  /v1/models        health check
"""

import io
import os
import wave

import numpy as np
import uvicorn
from fastapi import FastAPI
from fastapi.responses import JSONResponse, Response
from kokoro import KPipeline
from pydantic import BaseModel

SAMPLE_RATE = 24000
LANG = os.getenv("KOKORO_LANG", "a")  # 'a' = American English
DEFAULT_VOICE = os.getenv("TTS_VOICE", "af_heart")

app = FastAPI()
pipeline = KPipeline(lang_code=LANG)
list(pipeline("Warm up.", voice=DEFAULT_VOICE))  # load weights + voice before first request


class SpeechRequest(BaseModel):
    input: str
    model: str = "kokoro"
    voice: str = DEFAULT_VOICE
    response_format: str = "wav"
    speed: float = 1.0


def synthesize(text: str, voice: str, speed: float) -> bytes:
    chunks = [audio.numpy() if hasattr(audio, "numpy") else np.asarray(audio)
              for _, _, audio in pipeline(text, voice=voice, speed=speed) if audio is not None]
    audio = np.concatenate(chunks) if chunks else np.zeros(1, dtype=np.float32)
    return (np.clip(audio, -1, 1) * 32767).astype(np.int16).tobytes()


@app.get("/v1/models")
def models():
    return {"object": "list", "data": [{"id": "kokoro", "object": "model"}]}


@app.post("/v1/audio/speech")
def speech(req: SpeechRequest):
    pcm = synthesize(req.input, req.voice, req.speed)
    if req.response_format == "pcm":
        return Response(pcm, media_type="audio/pcm")
    if req.response_format != "wav":
        return JSONResponse({"error": f"unsupported response_format {req.response_format}; use wav or pcm"}, 400)
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(pcm)
    return Response(buf.getvalue(), media_type="audio/wav")


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=int(os.getenv("KOKORO_PORT", "8880")), log_level="warning")
