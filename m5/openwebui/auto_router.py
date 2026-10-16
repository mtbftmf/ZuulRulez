"""
title: Auto Router (Gemma ⇄ Flash-Next)
author: Pdl_Pwr
version: 1.3.1
description: One "Auto" model. Quick requests go to Gemma 4 26B-A4B, clearly complex ones to
             Qwen3.8-Flash-Next (medium effort), both served by LM Studio.
             Prefixes: /flash or /strong, /gemma or /fast, /deep (Flash at xhigh effort),
             /route <text> (shows where <text> would go, without running it).
             v1.3: escalates to Flash at xhigh on its own for explicit "think hard"-style
             phrases (DEEP_PHRASES) or a very high complexity score (DEEP_SCORE).
requirements: httpx
"""

# v1.3 changes (Oct 14 2026)
# - DEEP_PHRASES: explicit asks for depth ("think carefully", "deep dive", ...) → Flash + [effort:xhigh].
# - DEEP_SCORE: messages scoring this high (several strong signals at once) → Flash + [effort:xhigh].
#   To turn automatic escalation off: DEEP_SCORE = 0 and DEEP_PHRASES = off (empty = built-in list).
#
# v1.2 changes (Oct 13 2026)
# - Routing is a score instead of first-match: several weak signals must add up before Flash is used.
# - Gemma is the default for chat, follow-ups, short snippets and simple lookups.
# - LONG_CHAT_TURNS default 0: a long conversation alone no longer forces Flash.
# - Code blocks count fully only when large or when the message asks to debug/fix/review/write code.
# - Narrower task keywords; bare topic words (dns, vlan, tls...) no longer route to Flash.
# - Short continuations ("continue", "yes", "go on") follow the previous answer's size.
# - reasoning_effort is no longer sent (LM Studio ignores it, and if it ever passed it through it
#   would override the template marker). /deep adds [effort:xhigh] to the system message instead.
# - /route dry run; images never go to Flash unless STRONG_HAS_VISION is on.

import json
import re
from typing import AsyncGenerator, Optional

import httpx
from pydantic import BaseModel, Field

CONTINUATION_RE = re.compile(
    r"^(continue|go on|keep going|carry on|do it|yes|yep|ok(ay)?|please do|proceed|next|more|finish|"
    r"same|again|thanks|thank you)\b", re.I)
TRIVIAL_RE = re.compile(
    r"\b(translate|paraphrase|rewrite|reword|summari[sz]e|tl;?dr|what is|what's|who is|define|definition of|"
    r"convert|spelling|grammar|typo|synonym)\b", re.I)
CODE_INTENT_RE = re.compile(
    r"\b(debug|fix|error|traceback|stack trace|refactor|review|optimi[sz]e|implement|write|complete|"
    r"why does|doesn't work|does not work|fails?|failing|broken)\b", re.I)


DEFAULT_DEEP_PHRASES = ("think hard, think harder, think carefully, think deeply, think it through, deep dive, "
                    "in-depth, in depth, be thorough, rigorous, rigorously, "
                    "check your work, verify your reasoning, take your time, leave no stone unturned")


class Pipe:
    class Valves(BaseModel):
        LMSTUDIO_URL: str = Field(default="http://localhost:1234/v1", description="LM Studio OpenAI-compatible base URL")
        FAST_MODEL: str = Field(default="gemma-4-26b-a4b-it-qat", description="Quick model ID (as lms ps shows it)")
        STRONG_MODEL: str = Field(default="flash-next", description="Heavy model ID")
        SCORE_THRESHOLD: int = Field(default=3, description="Score at or above this → Flash")
        LENGTH_THRESHOLD: int = Field(default=1800, description="Last message longer than this (chars) adds 2; 3x longer adds 2 more")
        KEYWORDS: str = Field(
            default="root cause, troubleshoot, troubleshooting, traceback, stack trace, debug, refactor, optimize, "
                    "architecture, design review, trade-off, tradeoff, harden, hardening, audit, compliance, "
                    "threat model, derive, prove, proof, algorithm, implement, complete script, production script, "
                    "write a script, review this, review my, step by step, step-by-step, dcf, irr, wacc, "
                    "amortization, depreciation, roth conversion, monte carlo, network design, segmentation, isolation, "
                    "migration plan, disaster recovery, failover, redundancy, capacity planning",
            description="Comma-separated task phrases (whole-word match); one match adds 3",
        )
        IMAGES_TO_FAST: bool = Field(default=True, description="Messages with images go to the fast model (vision)")
        STRONG_HAS_VISION: bool = Field(default=False, description="Allow images on Flash when forced with /flash or /deep")
        LONG_CHAT_TURNS: int = Field(default=0, description="If > 0: conversations past this many turns add 1 for substantial messages")
        USE_CLASSIFIER: bool = Field(default=False, description="Ambiguous messages: ask the fast model SIMPLE/COMPLEX (+~0.5 s)")
        DEEP_PHRASES: Optional[str] = Field(
            default=None,
            description="Phrases (comma-separated) that send a message to Flash at xhigh. "
                        "Empty = built-in list; type off to disable",
        )
        DEEP_SCORE: int = Field(default=7, description="Score at or above this → Flash at xhigh (0 = off). Max score is 10-11")
        DEEP_MARKER: str = Field(default="[effort:xhigh]", description="Added to the system message for /deep")
        SHOW_ROUTE: bool = Field(default=True, description="Show which model answered, and why, above the reply")
        STRONG_PARAMS: str = Field(default='{"temperature": 1.0, "top_p": 0.95, "top_k": 20, "min_p": 0.0}',
                                   description="JSON sampling params for the strong model")
        FAST_PARAMS: str = Field(default='{"temperature": 1.0, "top_p": 0.95, "top_k": 64}',
                                 description="JSON sampling params for the fast model")

    def __init__(self):
        self.valves = self.Valves()

    def pipes(self):
        return [{"id": "auto", "name": "Auto (Gemma ⇄ Flash)"}]

    # ---------- helpers ----------
    @staticmethod
    def _text_and_images(content):
        if isinstance(content, str):
            return content, False
        text, has_img = [], False
        for part in content or []:
            if isinstance(part, dict):
                if part.get("type") == "text":
                    text.append(part.get("text", ""))
                elif part.get("type") in ("image_url", "image"):
                    has_img = True
        return "\n".join(text), has_img

    @staticmethod
    def _set_text(msg, new_text):
        if isinstance(msg.get("content"), str):
            msg["content"] = new_text
        else:
            for part in msg.get("content") or []:
                if isinstance(part, dict) and part.get("type") == "text":
                    part["text"] = new_text
                    break

    def _keywords(self, field: str = "KEYWORDS"):
        raw = getattr(self.valves, field) or ""
        if field == "DEEP_PHRASES":
            if raw.strip().lower() in ("off", "none", "-"):
                return []
            raw = raw.strip() or DEFAULT_DEEP_PHRASES
        kws = [k.strip().lower() for k in raw.split(",") if k.strip()]
        return [(k, re.compile(r"(?<![\w-])" + re.escape(k) + r"(?![\w-])", re.I)) for k in kws]

    def _add_marker(self, messages):
        marker = self.valves.DEEP_MARKER.strip()
        if not marker:
            return
        if messages and messages[0].get("role") == "system" and isinstance(messages[0].get("content"), str):
            if "[effort:" not in messages[0]["content"]:
                messages[0]["content"] = messages[0]["content"].rstrip() + "\n" + marker
        else:
            messages.insert(0, {"role": "system", "content": marker})

    async def _classify(self, text: str) -> Optional[bool]:
        prompt = ("Classify the user's request. Reply with exactly one word: SIMPLE if it is a quick fact, "
                  "short answer, casual chat or light rewrite; COMPLEX if it needs multi-step reasoning, "
                  "analysis, code, planning or careful accuracy.\n\nRequest:\n" + text[:2000])
        try:
            async with httpx.AsyncClient(timeout=15) as c:
                r = await c.post(f"{self.valves.LMSTUDIO_URL.rstrip('/')}/chat/completions",
                                 json={"model": self.valves.FAST_MODEL, "temperature": 0, "max_tokens": 8,
                                       "messages": [{"role": "user", "content": prompt}]})
                if r.status_code != 200:
                    return None
                out = str(((r.json().get("choices") or [{}])[0].get("message") or {}).get("content") or "").upper()
        except Exception:
            return None
        if "COMPLEX" in out:
            return True
        if "SIMPLE" in out:
            return False
        return None

    # ---------- routing ----------
    async def route(self, messages) -> tuple:
        """Returns (use_strong, deep, reason, dry_run). Strips control prefixes from the last user message."""
        users = [m for m in messages if m.get("role") == "user"]
        if not users:
            return False, False, "no user message", False
        last = users[-1]
        text, has_img = self._text_and_images(last.get("content"))
        stripped = text.lstrip()

        m = re.match(r"^/route\b\s*", stripped, re.I)
        if m:
            self._set_text(last, stripped[m.end():])
            use_strong, deep, reason, _ = await self.route(messages)
            return use_strong, deep, reason, True

        m = re.match(r"^/(flash|strong|gemma|fast|deep)\b\s*", stripped, re.I)
        if m:
            cmd = m.group(1).lower()
            self._set_text(last, stripped[m.end():])
            if cmd in ("gemma", "fast"):
                return False, False, f"forced with /{cmd}", False
            if has_img and not self.valves.STRONG_HAS_VISION:
                return False, False, f"/{cmd} ignored: image attached and Flash is text-only", False
            return True, cmd == "deep", f"forced with /{cmd}", False

        if has_img and self.valves.IMAGES_TO_FAST:
            return False, False, "image attached", False

        low = stripped.lower().strip()
        if not low:
            return False, False, "empty message", False

        # Short continuation: follow the size of the previous answer.
        if len(low) <= 60 and CONTINUATION_RE.match(low):
            prev = next((msg for msg in reversed(messages) if msg.get("role") == "assistant"), None)
            prev_text = self._text_and_images(prev.get("content"))[0] if prev else ""
            if len(prev_text) > 1500:
                return True, False, "continuation of a long answer", False
            return False, False, "short continuation", False

        score, reasons = 0, []
        if "```" in stripped:
            if len(stripped) > 400 or CODE_INTENT_RE.search(stripped):
                score += 3
                reasons.append("code task")
            else:
                score += 1
                reasons.append("small code snippet")
        n = len(stripped)
        if n > self.valves.LENGTH_THRESHOLD:
            score += 2
            reasons.append(f"long message ({n} chars)")
            if n > 3 * self.valves.LENGTH_THRESHOLD:
                score += 2
                reasons.append("very long")
        for kw, rx in self._keywords():
            if rx.search(stripped):
                score += 3
                reasons.append(f'"{kw}"')
                break
        if self.valves.LONG_CHAT_TURNS and len(users) > self.valves.LONG_CHAT_TURNS and n > 220:
            score += 1
            reasons.append(f"long conversation ({len(users)} turns)")

        for kw, rx in self._keywords("DEEP_PHRASES"):
            if rx.search(stripped):
                return True, True, f'deep: asked for depth ("{kw}")' + (f"; score {score}" if score else ""), False
        if self.valves.DEEP_SCORE and score >= self.valves.DEEP_SCORE:
            return True, True, f"deep: score {score}: " + ", ".join(reasons), False

        if n < 220 and score < self.valves.SCORE_THRESHOLD and TRIVIAL_RE.search(stripped):
            return False, False, "simple short request", False
        if score >= self.valves.SCORE_THRESHOLD:
            return True, False, f"score {score}: " + ", ".join(reasons), False

        if self.valves.USE_CLASSIFIER and 60 <= n <= 2200:
            verdict = await self._classify(stripped)
            if verdict is not None:
                return verdict, False, "classifier: " + ("complex" if verdict else "simple"), False
        return False, False, f"score {score}" + (": " + ", ".join(reasons) if reasons else "") + " (quick)", False

    # ---------- forwarding ----------
    async def pipe(self, body: dict, __event_emitter__=None):
        messages = [dict(m) for m in body.get("messages", [])]
        use_strong, deep, reason, dry_run = await self.route(messages)
        label = ("Flash-Next (xhigh)" if deep else "Flash-Next") if use_strong else "Gemma"

        if dry_run:
            return f"**Route test:** this message would go to **{label}**: {reason}."

        model = self.valves.STRONG_MODEL if use_strong else self.valves.FAST_MODEL
        if deep:
            self._add_marker(messages)

        if __event_emitter__ and self.valves.SHOW_ROUTE:
            await __event_emitter__({"type": "status",
                                     "data": {"description": f"→ {label} ({reason})", "done": True}})

        try:
            params = json.loads(self.valves.STRONG_PARAMS if use_strong else self.valves.FAST_PARAMS)
        except json.JSONDecodeError:
            params = {}
        payload = {"model": model, "messages": messages, "stream": bool(body.get("stream", True)), **params}
        if body.get("max_tokens"):
            payload["max_tokens"] = body["max_tokens"]
        url = f"{self.valves.LMSTUDIO_URL.rstrip('/')}/chat/completions"

        if not payload["stream"]:
            async with httpx.AsyncClient(timeout=None) as c:
                r = await c.post(url, json=payload)
                if r.status_code != 200:
                    return f"**Router error {r.status_code} from {model}:** {r.text[:400]}"
                msg = (r.json().get("choices") or [{}])[0].get("message") or {}
                think = msg.get("reasoning_content") or msg.get("reasoning")
                return (f"<think>{think}</think>\n" if think else "") + (msg.get("content") or "")

        return self._stream(url, payload, model)

    async def _stream(self, url, payload, model) -> AsyncGenerator:
        in_think = False
        async with httpx.AsyncClient(timeout=None) as c:
            async with c.stream("POST", url, json=payload) as r:
                if r.status_code != 200:
                    err = (await r.aread()).decode("utf-8", "ignore")[:400]
                    yield f"**Router error {r.status_code} from {model}:** {err}\n\n(Is it loaded? `lms ps`)"
                    return
                async for line in r.aiter_lines():
                    if not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if data == "[DONE]":
                        break
                    try:
                        delta = (json.loads(data).get("choices") or [{}])[0].get("delta") or {}
                    except (json.JSONDecodeError, IndexError, AttributeError):
                        continue
                    think = delta.get("reasoning_content") or delta.get("reasoning")
                    if think:
                        if not in_think:
                            in_think = True
                            yield "<think>"
                        yield think
                    content = delta.get("content")
                    if content:
                        if in_think:
                            in_think = False
                            yield "</think>\n"
                        yield content
        if in_think:
            yield "</think>\n"
