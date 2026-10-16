"""
title: Reasoning Budget (Flash-Next)
author: Pdl_Pwr
version: 1.0
description: Adds a reasoning-effort instruction to the system prompt of every request whose model (or
             persona base model) is Flash-Next, to counter LM Studio's fixed "xhigh" template default.
             Prefix a message with /deep to skip it for that message. Shows the applied level and the
             elapsed time as a status line, for A/B testing.
"""

import time
from typing import Optional

from pydantic import BaseModel, Field

BUDGETS = {
    "low": (
        "Reasoning budget: this request uses LOW reasoning effort, overriding any earlier reasoning-effort "
        "setting. Think only as much as needed to answer correctly: identify the key facts, decide, answer. "
        "Do not explore alternatives you will not recommend and do not re-verify settled points."
    ),
    "medium": (
        "Reasoning budget: this request uses MEDIUM reasoning effort, overriding any earlier reasoning-effort "
        "setting. Keep internal reasoning focused: identify the key facts, weigh only the realistic options, "
        "decide, then answer. For multi-part questions, reason briefly per part. Do not re-verify settled points."
    ),
}


class Filter:
    class Valves(BaseModel):
        priority: int = Field(default=0, description="Filter order (lower runs first)")
        TARGET_MODELS: str = Field(
            default="flash-next",
            description="Comma-separated model IDs; applies when the chat model or its base model matches",
        )
        LEVEL: str = Field(default="medium", description="low | medium | off")
        CUSTOM_TEXT: str = Field(default="", description="Optional: replaces the built-in text for the level")
        BYPASS_PREFIX: str = Field(default="/deep", description="Message prefix that skips the budget once")
        SHOW_STATUS: bool = Field(default=True, description="Show applied level and elapsed time")

    def __init__(self):
        self.valves = self.Valves()
        self._started = {}  # chat_id -> (start time, level)

    # ---------- helpers ----------
    def _targets(self):
        return {t.strip().lower() for t in self.valves.TARGET_MODELS.split(",") if t.strip()}

    def _applies(self, body: dict, model: Optional[dict]) -> bool:
        ids = {str(body.get("model", "")).lower()}
        if isinstance(model, dict):
            ids.add(str(model.get("id", "")).lower())
            info = model.get("info") or {}
            ids.add(str(info.get("base_model_id") or "").lower())
        return bool(ids & self._targets())

    @staticmethod
    def _get_text(msg: dict) -> str:
        c = msg.get("content")
        if isinstance(c, str):
            return c
        if isinstance(c, list):
            return "\n".join(p.get("text", "") for p in c if isinstance(p, dict) and p.get("type") == "text")
        return ""

    @staticmethod
    def _set_text(msg: dict, text: str):
        c = msg.get("content")
        if isinstance(c, list):
            for p in c:
                if isinstance(p, dict) and p.get("type") == "text":
                    p["text"] = text
                    return
            c.insert(0, {"type": "text", "text": text})
        else:
            msg["content"] = text

    @staticmethod
    def _chat_id(body: dict, metadata: Optional[dict]) -> str:
        if isinstance(metadata, dict) and metadata.get("chat_id"):
            return str(metadata["chat_id"])
        return str((body.get("metadata") or {}).get("chat_id") or body.get("chat_id") or "default")

    async def _status(self, emitter, text: str):
        if emitter and self.valves.SHOW_STATUS:
            try:
                await emitter({"type": "status", "data": {"description": text, "done": True}})
            except Exception:
                pass

    # ---------- hooks ----------
    async def inlet(self, body: dict, __user__: Optional[dict] = None, __model__: Optional[dict] = None,
                    __metadata__: Optional[dict] = None, __event_emitter__=None) -> dict:
        if not self._applies(body, __model__):
            return body
        messages = body.get("messages") or []
        users = [m for m in messages if m.get("role") == "user"]
        level = self.valves.LEVEL.strip().lower()

        # One-off bypass: "/deep ..." keeps the model's full reasoning for this message.
        prefix = self.valves.BYPASS_PREFIX.strip()
        if users and prefix:
            last = users[-1]
            text = self._get_text(last)
            if text.lstrip().lower().startswith(prefix.lower()):
                self._set_text(last, text.lstrip()[len(prefix):].lstrip())
                level = "off"

        cid = self._chat_id(body, __metadata__)
        self._started[cid] = (time.monotonic(), level)
        if level == "off" or (level not in BUDGETS and not self.valves.CUSTOM_TEXT.strip()):
            await self._status(__event_emitter__, "Reasoning budget: off (full depth)")
            return body

        budget = self.valves.CUSTOM_TEXT.strip() or BUDGETS[level]
        sys_msg = next((m for m in messages if m.get("role") == "system"), None)
        if sys_msg is None:
            messages.insert(0, {"role": "system", "content": budget})
        else:
            existing = self._get_text(sys_msg)
            if budget not in existing:  # idempotent if the filter runs twice
                self._set_text(sys_msg, budget + "\n\n" + existing)
        body["messages"] = messages
        await self._status(__event_emitter__, f"Reasoning budget: {level}")
        return body

    async def outlet(self, body: dict, __user__: Optional[dict] = None, __model__: Optional[dict] = None,
                     __metadata__: Optional[dict] = None, __event_emitter__=None) -> dict:
        if not self._applies(body, __model__):
            return body
        cid = self._chat_id(body, __metadata__)
        started = self._started.pop(cid, None)
        if started:
            elapsed = time.monotonic() - started[0]
            await self._status(__event_emitter__, f"Reasoning budget: {started[1]} · {elapsed:.0f} s total")
        return body
