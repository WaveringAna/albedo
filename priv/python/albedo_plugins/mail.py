"""mail.submit: one letter from this session to another. The daemon derives
the sender, resolves the name, stores the letter, and delivers it."""

from __future__ import annotations

from typing import cast

from albedo_api import Host, PythonApi, Record


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
    async def submit(self, to: object, body: str) -> Receipt:
        """Send `body` to "parent", a child or sibling by name, an agent
        handle, or any session id."""
        target = getattr(to, "id", to)
        if not isinstance(target, str) or not target.strip():
            raise TypeError(
                'mail.submit(to, body): to is "parent", a name, a session id, or an agent handle'
            )
        if not isinstance(body, str):
            raise TypeError(
                f"mail.submit(to, body): body must be str, got {type(body).__name__}"
            )
        return Receipt(
            cast(dict, await host("mail.submit", {"to": target.strip(), "body": body}))
        )

    def read(self, *_: object, **__: object) -> None:
        raise AttributeError(
            "there is no mail.read: letters to you arrive in your conversation as <mail> blocks"
        )


def setup(api: PythonApi) -> dict[str, object]:
    global host
    host = api.host
    return {"mail": Mail(), "MailError": api.HostError}
