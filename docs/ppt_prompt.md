# Prompt: build the submission deck

Paste everything below the line into your slide tool / LLM together with the
template `CollegeName_TeamName_Submission.pptx`. Replace every `<<...>>`
placeholder with final values before submitting (benchmark numbers must come
from our own best full run in `eval/results/`).

---

## Context (read this first)

**Who the deck is for.** A jury from Samsung R&D Institute India (Language AI Team and PRISM Team) judging the Samsung PRISM Generative AI Hackathon, 3rd edition (2026–27). They are ML/speech engineers: they know LLMs, ASR, TTS and tool calling, and they value honest engineering over hype. Round 1 is judged from the submission only (repo, README, reproduction script, results, video, this deck). Top teams go to Round 2, a live demo where jurors interrupt the agent in person and ask design questions, so the deck must explain *why* each design choice was made.

**The problem in plain words.** Today's voice assistants are half-duplex: they wait for you to finish, think, then talk. Real people don't talk like that. They say "um", pause, start again, and change their minds halfway ("book Tuesday, no wait, Wednesday"). When that happens, current assistants either act on the wrong value, act twice (booking two flights or charging twice), or go silent while a slow backend call runs. Theme 05 asks for an agent that keeps talking naturally, does its work in the background, and handles mid-sentence corrections without stale or duplicate actions.

**How it is measured.** Full-Duplex-Bench v3 is a public benchmark from National Taiwan University (NVIDIA in an advisory role). It streams 100 real recordings of people making requests, full of natural disfluencies, into the agent through LiveKit (a real-time audio/video platform) and records which tools the agent calls. The tools are 12 fake ("mock") APIs such as `search_flights`, `book_flight`, `get_exchange_rate`, `add_to_cart`, with deterministic outputs. A scenario **passes** only if the agent calls exactly the expected tools with the right arguments: one missing call, one extra call, or one wrong value fails it. An LLM judge (GPT-4o) checks argument meaning ("August 20" = "2026-08-20") and answer quality. Latency (time until the agent first speaks, calls a tool, delivers the key answer) is also reported. The organizers re-run our reproduction script themselves; only their run counts.

**Key terms (define them on first use in the deck).**
- *Disfluency*: filler ("um"), pause, hesitation, false start, or self-correction.
- *Self-correction*: the user replaces something they just said ("Paris, actually Berlin").
- *Cascaded pipeline*: separate speech-to-text → text LLM → text-to-speech models, as opposed to a single end-to-end speech model.
- *Turn detection / endpointing*: deciding when the user has finished speaking.
- *Tool call*: the LLM asking the system to run an API with arguments.
- *Idempotency*: running the same action twice has no extra effect; the ledger enforces this.
- *Commit hold*: our short wait before executing tools, so a correction that arrives after a pause cancels the stale call.
- *Strict pass rate*: percentage of scenarios with exactly the right calls and arguments.

**Why we chose this design (the story to tell).**
1. We read the benchmark code before designing. Every tool the agent *executes* is logged and scored, so speculative or early calls count as mistakes. That ruled out "call tools early on partial speech", a common latency trick.
2. The recordings never react to the agent, so classic barge-in (the user interrupting the agent's speech) matters less than *early endpointing*: the agent thinking the user finished during a pause in the middle of a correction.
3. First end-to-end test: 4/7 runs correct. In both failures the speaker paused just before correcting ("…Boston. Wait. [pause] Actually Chicago"), the agent committed "Boston", then also "Chicago" → an extra call → fail. The fix was the commit hold plus prompt rules (don't act on a trailing "wait/actually/um"; never invent missing values). Re-test: 7/7 correct including every self-correction case.
4. A cascaded pipeline (rather than a realtime speech model) makes every part swappable, inspectable and reproducible, which matters because 60% of the score depends on the organizers re-running our code.
5. Hosted models (Groq for speech-to-text, Ollama Cloud for the LLM) because the dev machine is a laptop with a 6 GB GPU; Kokoro TTS runs locally because it is tiny (82M parameters) and fast. A fallback LLM on the same API keeps the run going if the main model errors.
6. Honesty rules we follow: no hard-coding or memorizing benchmark items (the benchmark is public, and doing so is disqualifying; we verified our prompt examples do not appear in the dataset), no state carried between scenarios, no calls to our own servers during evaluation.

**What is still in progress (do not overclaim).** The full 100-scenario benchmark run and the extension use case are not finished yet; their numbers and screenshots go into the `<<...>>` placeholders. Latency is currently 5–8 s from end of speech to spoken answer and is being optimized; present it as a known limitation, not a strength.

---

You are filling in the official **Samsung PRISM Generative AI Hackathon 2026–27** submission template (12 slides). Keep the template's layout, fonts, colours, logos and slide titles exactly as they are; only add content inside each slide. Use short bullet points (max ~6 bullets per slide, max ~12 words per bullet), one visual per slide where suggested, and no paragraphs. Tone: technical, honest, specific. Never invent numbers; where a value is marked `<<...>>`, leave the placeholder visible.

## Project facts (source of truth)

- **Theme 05: Interruptible Real-Time Agents.** Build a voice-native agent that (1) stays responsive with spoken feedback within a few hundred ms and no false "done" claims, (2) runs tool calls asynchronously without blocking the conversation, (3) recovers cleanly when the user changes their mind mid-utterance: discards stale intent, updates arguments, never performs a state-changing action twice.
- **Evaluation:** Full-Duplex-Bench v3 (FDB-v3, NTU; arXiv 2604.04847): 100 real human recordings, 79 scenarios, 12 speakers, 5 disfluency types (fillers, pauses, hesitations, false starts, self-corrections), 12 mock tools in 4 domains (travel, finance, housing, e-commerce), chains of 1–3 calls. Metrics: tool-selection F1, argument accuracy (LLM judge), strict pass rate (all expected calls, no extra calls, correct args), latency. Round 1 score = 0.6 × benchmark + 0.2 × extension + 0.2 × documentation/video.
- **Existing solutions (published FDB-v3 baselines):** native realtime speech models (GPT-Realtime, Gemini Live, Grok, Ultravox) and a cascaded Whisper → GPT-4o → TTS pipeline. Gaps: they commit tool calls as soon as a turn *sounds* finished, so a pause inside a self-correction ("…Boston — wait… actually Chicago") produces a stale call plus the corrected one → strict fail; blocking tool execution freezes audio; no duplicate-action protection; multi-step chains lose accuracy; closed realtime models are not reproducible or swappable.
- **Our solution (architecture):** a LiveKit Agents (v1.8.3) cascaded voice agent with a coordination layer:
  1. Silero VAD + LiveKit semantic turn detector (waits out "um… wait…").
  2. STT: Groq `whisper-large-v3-turbo`.
  3. Planner LLM: `gpt-oss:120b` on Ollama Cloud (reasoning effort low), automatic fallback to `gemma4:31b` via LiveKit `FallbackAdapter`. Planner prompt resolves self-corrections (last stated value wins), refuses to invent missing required values, and emits independent tool calls together.
  4. **Commit hold** (our key idea): before a reply's first tool executes, wait 1.5 s; if the user resumes speaking, the planned calls are dropped and the next turn replans with the full utterance. Latency of the LLM is overlapped with the hold.
  5. **Per-session idempotency ledger:** identical call (tool + normalized args) never executes twice; in-flight duplicates await the same result. Session-scoped only — no state across scenarios.
  6. **Async tool executor:** blocking mock APIs run in worker threads so VAD/STT/TTS never stall.
  7. Spoken-ID canonicalization ("P.O. 999"-style → "PO999"-style).
  8. TTS: Kokoro-82M served locally (OpenAI-compatible endpoint, ~0.1 s per sentence on GPU); responses are grounded only in tool outputs.
  Everything is swappable via environment variables; one-command reproduction script `scripts/run_fdb_v3.sh` (pinned benchmark commit, preflight checks of keys/models/tool-calling, run, LLM-judge evaluation, logs + config saved).
- **Architecture diagram (draw as boxes + arrows, left→right):** User audio (benchmark WAV / mic) → Silero VAD → Groq Whisper STT → Turn detector → **Coordinator** [commit hold · idempotency ledger · superseded-call drop · session state] → Planner LLM (gpt-oss-120b → fallback Gemma 4 31B) ⇄ Async tool executor (12 tools, worker threads) → grounded answer → Kokoro TTS → speaker. Side box: "Extension: camera troubleshooting" reusing the same coordinator.
- **Measured so far (dev laptop, smoke subset — replace with full-run numbers):** first smoke run 4/7 correct; after adding the commit hold + prompt rules, **7/7 runs chose the correct tools and arguments, including every self-correction case** (e.g. 100 → 150 EUR, Boston → Chicago). Planner and fallback both pass a self-correction tool-call preflight. Kokoro TTS 90–140 ms per sentence on an RTX 4050. Perceived latency currently 5–8 s end-of-speech → answer (being optimized). Full benchmark: strict pass rate `<<X%>>`, tool F1 `<<X>>`, argument accuracy `<<X>>`, median first-response latency `<<X s>>`, vs cascaded baseline `<<X%>>`.
- **Limitations (be honest):** commit hold adds ~1.5 s before tool execution; hosted APIs (Groq, Ollama Cloud) add network latency and need keys/quota; turn detection still mis-fires on very long mid-sentence pauses; English only; laptop dev GPU is 6 GB.
- **Extension use case:** `<<final extension, e.g. camera-frame device troubleshooting: the user shows a device, the agent says "let me look", a vision model describes the frame, a local manual lookup finds steps, and the agent asks a clarifying question when the frame is ambiguous — reusing the same coordinator>>`.
- **Links:** GitHub `https://github.com/SaumyaBish-t/Samsung` · Demo video `<<link>>`.

## Slide-by-slide instructions

1. **Title** — fill: Theme ID `05 – Interruptible Real-Time Agents`, Team Name `<<team>>`, College `<<college>>`, 4 members with emails `<<...>>`, GitHub link above.
2. **Theme** — one-line problem statement (half-duplex assistants break when people interrupt, hesitate, correct themselves); the three required capabilities as three icon bullets (Responsive · Asynchronous · Recovers cleanly); one example ("book Tuesday — no wait, Wednesday" must not double-book); how it is judged (FDB-v3, 60/20/20).
3. **Existing Solutions & Gaps** — 2-column table: left = existing approach (realtime speech models; cascaded Whisper+GPT-4o), right = gap (commit on pause → stale + duplicate calls; blocking tools; no idempotency; weak multi-step chains; not reproducible/swappable). Close with one line: "Across all published systems, self-correction and multi-step chains are where scores are lost."
4. **Our Solution & Architecture Diagram** — the diagram described above as the main visual; 4 callout bullets beside it: commit hold, idempotency ledger, async tool executor, grounded answers + fallback LLM.
5. **Demo & Product Walkthrough** — a 4-step storyboard with a transcript strip: user says "…2-bedroom in Boston — wait… actually Chicago, max 2000" → agent holds, drops the Boston call → single correct `search_apartments(Chicago, 2, 2000)` → spoken grounded answer. Add a second mini-panel for the extension. Include the demo video link / QR `<<link>>`.
6. **Tools and tech stack used** — grid of logos/labels grouped as: Framework (LiveKit Agents 1.8.3, Python 3.10), Speech (Silero VAD, LiveKit turn detector, Groq Whisper large-v3-turbo, Kokoro-82M), Reasoning (gpt-oss-120b, Gemma 4 31B on Ollama Cloud), Evaluation (FDB-v3, NVIDIA parakeet ASR, GPT-4o judge), Infra (WSL2 Ubuntu 22.04, one-command bash reproduction, GitHub).
7. **Impact & Use case** — who benefits (in-car assistants, customer-support voice bots, hands-free device help); why it matters (no double bookings/charges, no stale actions, natural conversation); the extension use case in 2–3 bullets with one image.
8. **Innovation highlights, results and limitations** — three blocks: Innovation (commit hold, idempotency ledger, correction-aware prompt, provider fallback); Results (bar chart: baseline vs ours on strict pass rate, tool F1, argument accuracy; latency table; smoke-test before/after 4/7 → 7/7 labelled as a subset) using `<<...>>` for final numbers; Limitations (the honest list above).
9. **What's next** — adaptive hold (short when the utterance is clearly complete, longer after "wait/actually"); streaming STT and speculative planning for read-only tools only; fully self-hosted profile on one 48 GB GPU (vLLM + faster-whisper + Kokoro); multilingual (Hindi/Indic) speech; on-device deployment.
10. **Brownie points (differentiation)** — reproducible one-command benchmark run with pinned versions and a preflight; swappable providers via env vars; no hard-coding of benchmark items (prompt examples verified absent from the dataset); open about failures; low cost (free/cheap hosted tiers + local TTS).
11. **Checklist** — fill Y/N: working prototype on GitHub `Y`; README with reproducible setup `Y`; demo video ≤ 5 min `<<link>>`; presentation file `Y`.
12. **Thank you** — keep as is.

Output: the completed 12-slide PPTX (plus speaker notes of 2–3 sentences per slide that explain the slide in plain language for the presenter).
