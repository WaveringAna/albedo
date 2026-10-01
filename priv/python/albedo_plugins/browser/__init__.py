"""Data-first CDP browser plugin. Use top-level await inside Albedo cells.

    b = await browser.spawn()
    page = await b.new_page()
    await page.goto("https://example.com")
    snapshot = await page.observe()
    print(browser.render(snapshot))

No run() entry point: the plugin is a regular importable module.
"""

from __future__ import annotations

import sys
from typing import TYPE_CHECKING

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
from .launch import cleanup_all, spawn
from .observation import Node, Observation, find, one, render
from .page import Page, register_attach_image
from .session import Browser, EventScope, connect
from .transport import CDPSession, Subscription

if TYPE_CHECKING:
    from albedo_api import PythonApi

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


class BrowserApi:
    """Browser CDP control for Chrome and Chromium."""

    spawn = staticmethod(spawn)
    connect = staticmethod(connect)
    render = staticmethod(render)
    find = staticmethod(find)
    one = staticmethod(one)

    def __repr__(self) -> str:
        return "<browser api: spawn(), connect(), render(), find(), one()>"


browser = BrowserApi()

# Register module alias so `import browser` works alongside the `browser` binding
sys.modules["browser"] = sys.modules[__name__]


def setup(api: PythonApi) -> dict[str, object]:
    register_attach_image(api.attach_image)
    api.on_shutdown(cleanup_all)
    return {
        "browser": browser,
        "BrowserError": BrowserError,
    }
