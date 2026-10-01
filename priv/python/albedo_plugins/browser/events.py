"""Subscriptions are explicit scopes, separate from observation and interaction."""

from __future__ import annotations
from typing import Any
from .transport import CDPSession, Subscription


class EventScope:
    def __init__(
        self,
        cdp: CDPSession,
        method: str,
        *,
        capacity: int = 256,
        max_bytes: int = 2 * 1024 * 1024,
        enable: bool = True,
    ) -> None:
        self.cdp = cdp
        self.method = method
        self.capacity = capacity
        self.max_bytes = max_bytes
        self.enable = enable
        self.subscription: Subscription | None = None

    async def __aenter__(self) -> Subscription:
        if self.subscription is not None:
            raise RuntimeError("An event scope cannot be entered twice")
        self.subscription = self.cdp.connection.subscribe(
            self.method,
            self.cdp.session_id,
            capacity=self.capacity,
            max_bytes=self.max_bytes,
        )
        try:
            if self.enable:
                domain = self.method.split(".")[0]
                if domain not in {
                    "Network",
                    "Runtime",
                    "Page",
                    "DOM",
                    "Accessibility",
                    "Log",
                    "Performance",
                    "Security",
                }:
                    raise ValueError(
                        f"Enable {domain} explicitly with CDP, then use enable=False"
                    )
                await self.cdp.send(f"{domain}.enable")
            return self.subscription
        except BaseException:
            self.subscription.close()
            raise

    async def __aexit__(self, *exc: Any) -> None:
        if self.subscription is not None:
            self.subscription.close()
