"""Data-first CDP browser plugin. Use top-level await inside Albedo cells.

    b = await browser.spawn()
    page = await b.new_page()
    await page.goto("https://example.com")
    snapshot = await page.observe()
    print(browser.render(snapshot))

No run() entry point: the plugin is a regular importable module. Only the
errors load with the kernel; the rest loads on first use, so a kernel that
never drives a browser does not hold it.
"""

from __future__ import annotations

import importlib
import sys
from typing import TYPE_CHECKING

from . import hooks
from .errors import (
    ActionOutcomeUnknown,
    BrowserError,
    CommandTimeout,
    ConnectionLost,
    EventOverflow,
    IncompleteObservation,
    JavaScriptError,
    LaunchError,
    NotActionable,
    ProtocolError,
    SelectionError,
    StaleReference,
    UnsupportedOperation,
    WaitTimeout,
    TargetGone,
    RecoveryError,
)

if TYPE_CHECKING:
    from albedo_api import PythonApi

    from .launch import spawn
    from .observation import Node, Observation, find, one, render
    from .page import Page
    from .session import Browser, EventScope, connect
    from .transport import CDPSession, Subscription

# Where each name that loads on first use lives.
_LAZY = {
    "spawn": "launch",
    "cleanup_all": "launch",
    "connect": "session",
    "Browser": "session",
    "EventScope": "session",
    "Page": "page",
    "Observation": "observation",
    "Node": "observation",
    "find": "observation",
    "one": "observation",
    "render": "observation",
    "CDPSession": "transport",
    "Subscription": "transport",
}

__all__ = [
    "connect",
    "spawn",
    "Browser",
    "Page",
    "Observation",
    "Node",
    "find",
    "one",
    "render",
    "CDPSession",
    "EventScope",
    "Subscription",
    "BrowserError",
    "ActionOutcomeUnknown",
    "CommandTimeout",
    "ConnectionLost",
    "EventOverflow",
    "IncompleteObservation",
    "JavaScriptError",
    "LaunchError",
    "NotActionable",
    "ProtocolError",
    "SelectionError",
    "StaleReference",
    "UnsupportedOperation",
    "WaitTimeout",
    "TargetGone",
    "RecoveryError",
]


def __getattr__(name: str) -> object:
    if name not in _LAZY:
        raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
    return getattr(importlib.import_module(f".{_LAZY[name]}", __name__), name)


class BrowserApi:
    """Browser CDP control for Chrome and Chromium."""

    _METHODS = ("spawn", "connect", "render", "find", "one")

    def __getattr__(self, name: str) -> object:
        if name not in self._METHODS:
            raise AttributeError(name)
        return __getattr__(name)

    def __dir__(self) -> list[str]:
        return [*super().__dir__(), *self._METHODS]

    def __repr__(self) -> str:
        return "<browser api: spawn(), connect(), render(), find(), one()>"


browser = BrowserApi()

# Register module alias so `import browser` works alongside the `browser` binding
sys.modules["browser"] = sys.modules[__name__]


async def _cleanup() -> None:
    """End the browsers this kernel launched, if it ever launched one."""
    launch = sys.modules.get(f"{__name__}.launch")
    if launch is not None:
        await launch.cleanup_all()


def setup(api: PythonApi) -> dict[str, object]:
    hooks.attach_image = api.attach_image
    api.on_shutdown(_cleanup)
    return {
        "browser": browser,
        "BrowserError": BrowserError,
    }
