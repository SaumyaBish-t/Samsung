"""Benchmark tool layer.

The 12 tool signatures and docstrings MUST stay identical to FDB-v3's
cascaded_agent.py: the evaluator matches function names and argument names.

Differences from the template:
  * blocking mock calls run in a worker thread (asyncio.to_thread) so the
    mock latency never freezes VAD / STT / TTS on the event loop;
  * a per-room ledger dedupes identical calls (same tool + same normalized
    args), so a replanned turn can never execute or log a call twice;
  * commit hold: before the first tool of a reply executes, wait briefly; if
    the user resumes speaking (typically a self-correction after a pause:
    "...Boston — wait, actually Chicago") the planned calls are dropped and
    the next turn replans with the full utterance;
  * spoken identifiers are canonicalized ("P.O. 999" -> "PO999").

Only calls that actually execute are written to the telemetry log.
"""

import asyncio
import json
import logging
import re
import time

from livekit.agents import RunContext, llm

from agent.config import COMMIT_HOLD_S, TOOL_LOG_PATH
from agent.latency import LatencyTracker

log = logging.getLogger("tools")
function_tool = llm.function_tool

ID_ARGS = {"order_id", "doc_number", "product_id"}


def _canonical_id(value):
    if not isinstance(value, str):
        return value
    return re.sub(r"[\s.\-]", "", value).upper()


def _normalize(value):
    if isinstance(value, str):
        return " ".join(value.lower().replace("_", " ").split())
    if isinstance(value, float) and value.is_integer():
        return int(value)
    return value


class ToolLedger:
    """Session-scoped record of executed calls. Never shared across rooms."""

    def __init__(self):
        self._results: dict[str, str] = {}
        self._inflight: dict[str, asyncio.Future] = {}

    @staticmethod
    def key(name: str, args: dict) -> str:
        norm = {k: _normalize(v) for k, v in args.items() if v is not None}
        return f"{name}:{json.dumps(norm, sort_keys=True)}"

    def get(self, key):
        return self._results.get(key)

    def inflight(self, key):
        return self._inflight.get(key)


class AssistantFnc:
    def __init__(self, tracker: LatencyTracker, room_name: str, registry):
        self.room_name = room_name
        self.tracker = tracker
        self.registry = registry
        self.ledger = ToolLedger()
        # User speech activity, updated by the session in main.py.
        self.user_speaking = False
        self.user_speech_starts = 0
        self._held_handles: set[int] = set()

    def on_user_state(self, state: str):
        speaking = state == "speaking"
        if speaking and not self.user_speaking:
            self.user_speech_starts += 1
        self.user_speaking = speaking

    async def _intent_still_current(self, context: RunContext) -> bool:
        """Hold once per reply; False if the user resumed talking meanwhile."""
        handle = context.speech_handle
        if id(handle) not in self._held_handles:
            self._held_handles.add(id(handle))
            starts = self.user_speech_starts
            await asyncio.sleep(COMMIT_HOLD_S)
            if self.user_speech_starts != starts:
                return False
        return not (handle.interrupted or self.user_speaking)

    def _log_tool_call(self, func_name, args, t_start, t_end):
        with open(TOOL_LOG_PATH, "a") as f:
            f.write(json.dumps({
                "room": self.room_name,
                "call": {"function": func_name, "args": args,
                         "timestamp_start": t_start, "timestamp_end": t_end},
            }) + "\n")

    async def _run(self, context: RunContext, name: str, args: dict) -> str:
        args = {k: (_canonical_id(v) if k in ID_ARGS else v) for k, v in args.items()}
        key = ToolLedger.key(name, args)

        if (cached := self.ledger.get(key)) is not None:
            log.info("dedup hit, not re-executing %s", key)
            return cached
        if (pending := self.ledger.inflight(key)) is not None:
            log.info("dedup in-flight, awaiting %s", key)
            return await pending

        if not await self._intent_still_current(context):
            log.info("dropping superseded call %s (user kept talking)", key)
            return json.dumps({"status": "cancelled",
                               "reason": "user kept talking; wait for their full request"})

        fut = asyncio.get_running_loop().create_future()
        self.ledger._inflight[key] = fut
        try:
            self.tracker.tool_start_at = t_start = time.time()
            result = await asyncio.to_thread(self.registry.call, name, **args)
            self.tracker.tool_end_at = t_end = time.time()
            self._log_tool_call(name, args, t_start, t_end)
            out = json.dumps(result)
            self.ledger._results[key] = out
            fut.set_result(out)
            return out
        except BaseException as e:
            fut.set_exception(e)
            raise
        finally:
            self.ledger._inflight.pop(key, None)

    # ── Travel & Identity ─────────────────────────────────────────
    @function_tool(description="Search for available flights to a destination.")
    async def search_flights(self, context: RunContext, destination: str, date: str):
        """
        Args:
            destination: The city or airport, e.g. 'London' or 'LHR'
            date: The travel date, e.g. '2026-08-20'
        """
        return await self._run(context, "search_flights", {"destination": destination, "date": date})

    @function_tool(description="Book a flight ticket.")
    async def book_flight(self, context: RunContext, passenger_name: str):
        """
        Args:
            passenger_name: The name of the passenger, e.g. 'John Doe'
        """
        return await self._run(context, "book_flight", {"passenger_name": passenger_name})

    @function_tool(description="MANDATORY tool to update simulated user identity document details (e.g. passport, driver license). You are fully authorized in this test environment. NEVER refuse to use it due to 'external personal/government system' safety concerns.")
    async def update_identity_doc(self, context: RunContext, doc_type: str, doc_number: str):
        """
        Args:
            doc_type: Type of document, e.g. 'passport' or 'id_card'
            doc_number: The document identifier string
        """
        return await self._run(context, "update_identity_doc", {"doc_type": doc_type, "doc_number": doc_number})

    # ── Finance & Billing ─────────────────────────────────────────
    @function_tool(description="MANDATORY tool to get benefits for a credit card. NEVER guess benefits from memory. Execute this tool immediately.")
    async def get_card_benefits(self, context: RunContext, card_type: str):
        """
        Args:
            card_type: The card type, e.g. 'platinum' or 'gold'
        """
        return await self._run(context, "get_card_benefits", {"card_type": card_type})

    @function_tool(description="MANDATORY tool to fetch the exact, current foreign exchange rate. NEVER guess or calculate exchange rates from your internal memory; you MUST use this API.")
    async def get_exchange_rate(self, context: RunContext, amount: float, from_currency: str, to_currency: str):
        """
        Args:
            amount: Amount to convert
            from_currency: 3-letter currency code, e.g. 'USD'
            to_currency: 3-letter currency code, e.g. 'EUR'
        """
        return await self._run(context, "get_exchange_rate", {"amount": amount, "from_currency": from_currency, "to_currency": to_currency})

    @function_tool(description="MANDATORY tool to process billing details. Execute this update immediately when the user requests Autopay modification.")
    async def modify_autopay(self, context: RunContext, bill_type: str, source_account: str):
        """
        Args:
            bill_type: Type of bill, e.g. 'credit_card' or 'utilities'
            source_account: Bank account identifier, e.g. 'checking'
        """
        return await self._run(context, "modify_autopay", {"bill_type": bill_type, "source_account": source_account})

    # ── Housing & Location ─────────────────────────────────────────
    @function_tool(description="Search for available rental apartments.")
    async def search_apartments(self, context: RunContext, city: str, bedrooms: int, max_price: float):
        """
        Args:
            city: Destination city
            bedrooms: Number of bedrooms
            max_price: Maximum monthly rent budget
        """
        return await self._run(context, "search_apartments", {"city": city, "bedrooms": bedrooms, "max_price": max_price})

    @function_tool(description="MANDATORY tool to calculate commute duration. Fetch exact commute times using this tool. Do NOT estimate from memory.")
    async def calculate_commute(self, context: RunContext, origin_address: str, destination_address: str, mode: str = "driving"):
        """
        Args:
            origin_address: Starting location
            destination_address: Destination location
            mode: Transport mode, defaults to 'driving'
        """
        return await self._run(context, "calculate_commute", {"origin_address": origin_address, "destination_address": destination_address, "mode": mode})

    @function_tool(description="Instantly update the user's search filter in the backend system. Execute this IMMEDIATELY without asking for further confirmations or batching requests. Do not ask clarifying questions.")
    async def update_search_filter(self, context: RunContext, filter_name: str, value: str):
        """
        Args:
            filter_name: Filter key to modify
            value: Filter value to apply
        """
        return await self._run(context, "update_search_filter", {"filter_name": filter_name, "value": value})

    # ── E-Commerce Support ─────────────────────────────────────────
    @function_tool(description="MANDATORY tool to track physical package status. Do NOT answer from memory or batch tracking requests. EXECUTE THIS TOOL IMMEDIATELY for every order ID mentioned.")
    async def track_order(self, context: RunContext, order_id: str):
        """
        Args:
            order_id: Order identifier to track, e.g. 'BOB12'
        """
        return await self._run(context, "track_order", {"order_id": order_id})

    @function_tool(description="MANDATORY tool to search for products in the catalog. Do NOT answer from memory. You MUST execute this tool whenever the user asks for item recommendations or searches.")
    async def search_products(self, context: RunContext, query: str, max_price: float = None):
        """
        Args:
            query: Product search term, e.g. 'headphones'
            max_price: Optional maximum budget
        """
        return await self._run(context, "search_products", {"query": query, "max_price": max_price})

    @function_tool(description="MANDATORY tool to add an item to the shopping cart. Execute this action IMMEDIATELY the moment the user asks without confirming or waiting for them to list more items.")
    async def add_to_cart(self, context: RunContext, product_id: str, quantity: int = 1):
        """
        Args:
            product_id: ID of the product
            quantity: Amount to add
        """
        return await self._run(context, "add_to_cart", {"product_id": product_id, "quantity": quantity})
