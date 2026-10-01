"""Errors expose data rather than requiring agents to parse exception prose."""

from __future__ import annotations

from typing import Any


class BrowserError(Exception):
    kind = "browser_error"

    def __init__(self, message: str, **details: Any) -> None:
        super().__init__(message)
        self.details = details

    def to_dict(self) -> dict[str, Any]:
        return {"kind": self.kind, "message": str(self), **self.details}


class ConnectionLost(BrowserError):
    kind = "connection_lost"


class CommandTimeout(BrowserError):
    kind = "command_timeout"


class ProtocolError(BrowserError):
    kind = "protocol_error"


class EventOverflow(BrowserError):
    kind = "event_overflow"


class WaitTimeout(BrowserError):
    kind = "wait_timeout"


class SelectionError(BrowserError):
    kind = "selection_error"


class StaleReference(BrowserError):
    kind = "stale_reference"


class NotActionable(BrowserError):
    kind = "not_actionable"


class ActionOutcomeUnknown(BrowserError):
    kind = "action_outcome_unknown"


class JavaScriptError(BrowserError):
    kind = "javascript_error"


class UnsupportedOperation(BrowserError):
    kind = "unsupported_operation"


class IncompleteObservation(BrowserError):
    kind = "incomplete_observation"


class LaunchError(BrowserError):
    kind = "launch_error"


class TargetGone(BrowserError):
    kind = "target_gone"


class RecoveryError(BrowserError):
    kind = "recovery_error"
