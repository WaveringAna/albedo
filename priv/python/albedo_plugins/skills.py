from typing import TypedDict, cast

from albedo_api import Host, PythonApi


class SkillResources(TypedDict):
    resources: list[str]
    truncated: bool
    diagnostics: list[str]


class SkillPage(TypedDict):
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
        return cast(SkillResources, await host("skills.resources", {"name": name}))

    async def read(
        self,
        name: str,
        resource: str = "SKILL.md",
        *,
        offset: int = 0,
        limit: int = 16_384,
    ) -> SkillPage:
        """Read one bounded page from a cataloged skill resource."""
        return cast(
            SkillPage,
            await host(
                "skills.read",
                {
                    "name": name,
                    "resource": resource,
                    "offset": offset,
                    "limit": limit,
                },
            ),
        )


def setup(api: PythonApi) -> dict[str, object]:
    global host
    host = api.host
    return {"skills": Skills(), "SkillsError": api.HostError}
