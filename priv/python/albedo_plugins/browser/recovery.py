"""Explicit session recovery; only acknowledged declarative settings are retained.

This is NOT a command log. Navigation, input, JavaScript, permissions, scripts,
request interception and event subscriptions must never be replayed here.
"""

from __future__ import annotations

import copy
import json
from typing import TYPE_CHECKING

from .errors import ConnectionLost
from .transport import CDPSession, JSON

if TYPE_CHECKING:
    from .page import Page

# A closed list, not "anything beginning with Emulation.set". Each entry has
# replacement semantics. Clear commands share a key with their matching setter.
SETTINGS = {
    "Emulation.setDeviceMetricsOverride": "metrics",
    "Emulation.clearDeviceMetricsOverride": "metrics",
    "Emulation.setTouchEmulationEnabled": "touch",
    "Emulation.setEmulatedMedia": "media",
    "Emulation.setTimezoneOverride": "timezone",
    "Emulation.setLocaleOverride": "locale",
    "Emulation.setUserAgentOverride": "user_agent",
    "Network.setUserAgentOverride": "user_agent",
    "Emulation.setGeolocationOverride": "geolocation",
    "Emulation.clearGeolocationOverride": "geolocation",
    "Emulation.setCPUThrottlingRate": "cpu",
    "Emulation.setDefaultBackgroundColorOverride": "background",
    "Emulation.setEmulatedVisionDeficiency": "vision",
}
MAX_SETTINGS_BYTES = 256 * 1024


class PageCDPSession(CDPSession):
    """Raw CDP plus retention of the documented root-page emulation setters.

    Sending still happens exactly once. Settings are saved only after success.
    A saved CDPSession is tied to its original attachment, never silently rebound.
    """

    def __init__(self, page: Page, session_id: str) -> None:
        super().__init__(page.browser._connection, session_id)
        self.page = page

    async def send(
        self, method: str, params: JSON | None = None, *, timeout: float | None = None
    ) -> JSON:
        if self is not self.page.cdp:
            raise ConnectionLost(
                "This CDP session was replaced; use page.cdp after reattachment."
            )
        if method not in SETTINGS:
            return await super().send(method, params, timeout=timeout)
        # Serialize configuration and reattachment, so a late acknowledgement
        # cannot overwrite a newer intended setting. Copy before the first await.
        payload = copy.deepcopy(params or {})
        async with self.page._settings_lock:
            self.page._check()
            if self is not self.page.cdp:
                raise ConnectionLost("This CDP session was replaced; use page.cdp.")
            candidate = dict(self.page._settings)
            key = SETTINGS[method]
            candidate.pop(key, None)
            candidate[key] = {"method": method, "params": payload}
            if (
                len(json.dumps(candidate, allow_nan=False).encode())
                > MAX_SETTINGS_BYTES
            ):
                raise ValueError(
                    "Remembered emulation settings exceed 256 KiB; command was not sent"
                )
            result = await super().send(method, payload, timeout=timeout)
            self.page._settings = candidate
            return result
