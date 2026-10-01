#!/usr/bin/env python3
"""LiveKit worker entrypoint for the FDB-v3 benchmark agent.

    python -m agent.main download-files   # turn-detector + VAD weights, once
    python -m agent.main start            # production worker (used by the harness)
    python -m agent.main console          # talk to it with your mic
"""

import json
import logging
import time

from livekit import agents
from livekit.agents import Agent, AgentServer, AgentSession, llm

from agent import config as C
from agent import providers
from agent.latency import LatencyTracker, heartbeat
from agent.prompts import PLANNER_INSTRUCTIONS
from agent.tools import AssistantFnc
from mock_apis import MockAPIRegistry  # from FDB_V3_DIR, unchanged

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("agent")

# The harness runs one room at a time; a couple of warm processes is enough and
# keeps RAM free on small machines (LiveKit's default pre-forks many).
server = AgentServer(num_idle_processes=C.NUM_IDLE_PROCESSES)


class PlannerAgent(Agent):
    def __init__(self, tools, fnc: AssistantFnc):
        super().__init__(instructions=PLANNER_INSTRUCTIONS, tools=tools)
        self._fnc = fnc

    async def on_user_turn_completed(self, turn_ctx: llm.ChatContext, new_message: llm.ChatMessage) -> None:
        # Calls dropped by the commit hold are in the history as "cancelled";
        # tell the planner explicitly that they never ran so it re-plans them.
        dropped = self._fnc.take_dropped_calls()
        if dropped:
            listed = "; ".join(f"{name}({json.dumps(args)})" for name, args in dropped)
            turn_ctx.add_message(role="system", content=(
                f"Note: these tool calls were NOT executed because the user was still speaking: {listed}. "
                "Using everything the user has said so far (apply any corrections), make the tool calls "
                "that are still needed now."))


@server.rtc_session()
async def entrypoint(ctx: agents.JobContext):
    room = ctx.room.name
    heartbeat(f"!!! AGENT JOINING ROOM: {room} !!!")

    # Everything below is per room: no state survives across scenarios.
    registry = MockAPIRegistry(latency_profile=C.MOCK_LATENCY)
    tracker = LatencyTracker()
    fnc = AssistantFnc(tracker, room, registry)
    tools = llm.find_function_tools(fnc)

    session = AgentSession(
        vad=providers.build_vad(),
        stt=providers.build_stt(),
        llm=providers.build_llm(),
        tts=providers.build_tts(),
        turn_detection=providers.build_turn_detector(),
        min_endpointing_delay=C.MIN_ENDPOINTING_DELAY,
        max_endpointing_delay=C.MAX_ENDPOINTING_DELAY,
        allow_interruptions=True,
    )

    @session.on("user_input_transcribed")
    def on_user_input(ev: agents.voice.UserInputTranscribedEvent):
        log.info("STT (final=%s): %s", ev.is_final, ev.transcript)
        if ev.is_final:
            # Latest final segment = end of the request that triggers tools.
            tracker.user_done_at = time.time()
            tracker.query_received = True

    @session.on("metrics_collected")
    def on_metrics(ev: agents.MetricsCollectedEvent):
        m = ev.metrics
        fields = {k: round(v, 3) for k in ("end_of_utterance_delay", "transcription_delay",
                                           "on_user_turn_completed_delay", "ttft", "duration", "ttfb")
                  if isinstance(v := getattr(m, k, None), (int, float))}
        log.info("METRICS %s %s", type(m).__name__, fields)

    @session.on("user_state_changed")
    def on_user_state(ev: agents.voice.UserStateChangedEvent):
        fnc.on_user_state(ev.new_state)

    @session.on("agent_state_changed")
    def on_agent_state(ev: agents.voice.AgentStateChangedEvent):
        if ev.new_state == "speaking" and tracker.query_received and not tracker.agent_start_at:
            tracker.agent_start_at = time.time()
            tracker.log_breakdown(room_name=room)
            tracker.reset()

    await session.start(room=ctx.room, agent=PlannerAgent(tools, fnc))
    log.info("agent started in room %s (llm=%s, fallback=%s)", room, C.LLM_MODEL, C.LLM_FALLBACK_MODEL)


if __name__ == "__main__":
    agents.cli.run_app(server)
