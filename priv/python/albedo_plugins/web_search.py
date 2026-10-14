from __future__ import annotations

from typing import cast

from albedo_api import Host, PythonApi, Record
import albedo_trace
from albedo_plugins import hook


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

    def markdown(self) -> str:
        """The answer and a list of its linked sources, for the transcript."""
        lines = [self.answer, ""] if self.answer else []
        lines += [f"- [{source.title}]({source.url})" for source in self.sources]
        return "\n".join(lines)


host: Host


@hook.reported("web_search", {"query": "query", "limit": "limit"})
async def web_search(query: str, limit: int = 8) -> WebSearch:
    """Search the web: a written answer and the sources behind it."""

    async def search() -> WebSearch:
        found = cast(
            dict, await host("web_search.search", {"query": query, "limit": limit})
        )
        return WebSearch(
            answer=found["answer"],
            sources=[Record(source) for source in found["sources"]],
        )

    return await albedo_trace.noted(
        "web", query, search(), lambda result: (True, result.markdown())
    )


def setup(api: PythonApi) -> dict[str, object]:
    global host
    host = api.host
    return {"web_search": web_search}
