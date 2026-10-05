from __future__ import annotations

from typing import cast

from albedo_api import Host, PythonApi, Record
import albedo_trace


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


async def web_search(query: str, limit: int = 8) -> WebSearch:
    """Search the web: a written answer and the sources behind it."""
    found = cast(
        dict, await host("web_search.search", {"query": query, "limit": limit})
    )
    result = WebSearch(
        answer=found["answer"],
        sources=[Record(source) for source in found["sources"]],
    )
    albedo_trace.note("web", query, result.markdown())
    return result


def setup(api: PythonApi) -> dict[str, object]:
    global host
    host = api.host
    return {"web_search": web_search}
