"""mail.submit: one letter from this session to another. The daemon derives
the sender, resolves the name, stores the letter, and delivers it."""

from __future__ import annotations

from typing import cast

from albedo_api import Host, PythonApi, Record
from albedo_plugins import hook


class Receipt(Record):
    """receipt.id, .to (session id), .name, and .status: "delivered",
    "queued" behind a running turn, or "pending" until that session runs.
    "delivered" may still be waiting for kernel preparation."""

    id: str
    to: str
    name: str
    status: str


host: Host


class Mail:
    @hook.reported("mail.submit", {"to": "to", "body": "body", "blocker": "blocker"})
    async def submit(self, to: object, body: str, *, blocker: bool = False) -> Receipt:
        """Send `body` to "parent", a child or sibling by name, an agent
        handle, or any session id. Pass blocker=True to report an unavoidable
        blocker to your parent when a verifier gate cannot be satisfied."""
        target = getattr(to, "id", to)
        if not isinstance(target, str) or not target.strip():
            raise TypeError(
                'mail.submit(to, body): to is "parent", a name, a session id, or an agent handle'
            )
        if not isinstance(body, str):
            raise TypeError(
                f"mail.submit(to, body): body must be str, got {type(body).__name__}"
            )
        payload: dict[str, object] = {"to": target.strip(), "body": body}
        if blocker:
            payload["blocker"] = True
        return Receipt(cast(dict, await host("mail.submit", payload)))

    @hook.reported("mail.request", {"to": "to", "body": "body"})
    async def request(self, to: object, body: str) -> Receipt:
        """Send a request; the recipient owes a reply until sending any letter back."""
        target = getattr(to, "id", to)
        if (
            not isinstance(target, str)
            or not target.strip()
            or not isinstance(body, str)
        ):
            raise TypeError("mail.request(to, body) takes a target and string body")
        return Receipt(
            cast(dict, await host("mail.request", {"to": target.strip(), "body": body}))
        )

    async def open(self) -> Record:
        """Return {owed, awaiting} open request summaries."""
        return Record(cast(dict, await host("mail.open", {})))

    def read(self, *_: object, **__: object) -> None:
        raise AttributeError(
            "there is no mail.read: letters to you arrive in your conversation as <mail> blocks"
        )


def setup(api: PythonApi) -> dict[str, object]:
    global host
    host = api.host
    return {"mail": Mail(), "MailError": api.HostError}
