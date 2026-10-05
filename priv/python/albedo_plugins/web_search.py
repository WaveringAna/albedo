from __future__ import annotations

from typing import cast

from albedo_api import Host, PythonApi, Record


class WebSearch(Record):
    """One answered search: `r.answer` and `r["answer"]` both work. It prints
    as the answer followed by its numbered sources."""

    answer: str
    sources: list[Record]

    def __str__(self) -> str:
        lines = [self.answer, ""] if self.answer else []
        for index, source in enumerate(self.sources, 1):
            dated = f" ({source.published})" if source.published else ""
            lines.append(f"[{index}] {source.title}{dated}\n    {source.url}")
            if source.snippet:
                lines.append(f"    {source.snippet}")
        return "\n".join(lines)

    __repr__ = __str__


host: Host


async def web_search(query: str, limit: int = 8) -> WebSearch:
    """Search the web: a written answer and the sources behind it."""
    found = cast(
        dict, await host("web_search.search", {"query": query, "limit": limit})
    )
    return WebSearch(
        answer=found["answer"],
        sources=[Record(source) for source in found["sources"]],
    )


def setup(api: PythonApi) -> dict[str, object]:
    global host
    host = api.host
    return {"web_search": web_search}
