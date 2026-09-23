from typing import cast

from albedo_api import Host, PythonApi, Record


class SkillResources(Record):
    """resources.resources and resources["resources"] both work."""
    resources: list[str]
    truncated: bool
    diagnostics: list[str]


class SkillPage(Record):
    """page.content and page["content"] both work."""
    path: str
    encoding: str
    content: str
    next_offset: int
    truncated: bool
    size: int


host: Host


class Skills:
    async def resources(self, name: str) -> SkillResources:
        """List resource names without reading or executing their contents."""
        return SkillResources(cast(dict, await host("skills.resources", {"name": name})))

    async def read(
        self,
        name: str,
        resource: str = "SKILL.md",
        *,
        offset: int = 0,
        limit: int = 16_384,
    ) -> SkillPage:
        """Read one bounded page from a cataloged skill resource."""
        return SkillPage(cast(
            dict,
            await host(
                "skills.read",
                {
                    "name": name,
                    "resource": resource,
                    "offset": offset,
                    "limit": limit,
                },
            ),
        ))


def setup(api: PythonApi) -> dict[str, object]:
    global host
    host = api.host
    return {"skills": Skills(), "SkillsError": api.HostError}
