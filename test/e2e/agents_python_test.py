"""Python agent API: spawn, family identity, refusals, progress, explicit mail,
agents.get, reading messages across sessions, and listing and searching them."""

import re
import time
import unittest

from harness import Albedo, Provider, python, text

LEAD = """models = await agents.models()
assert 'beta/fixture-beta' in models, models
kid = await agents.self.spawn('count to three', name='scout', model=models[0])
try:
    await agents.self.spawn('again', name='scout2', model='')
except TypeError as error:
    print('EMPTY_MODEL', error)
print('SPAWNED', kid.name, kid.depth, kid.parent.name, 'KID=' + kid.id)
"""
CHILD = """me = agents.self
print('ME', me.name, me.depth, me.parent.name)
print('PROGRESS', await agents.progress('counting'))
print('Café Ünïcode')
try:
    await me.parent.cancel()
except AgentsError as error:
    print('REFUSED', error)
page = await me.parent.messages()
print('PARENT_READ', 'spawn a scout' in page.content)
up = await agents.get('parent')
print('GOT', up.id == me.parent.id, up.depth, up.parent, up.closed)
try:
    await me.parent.delete()
except AgentsError as error:
    print('ASK', error)
receipt = await mail.submit('parent', 'three')
print('SENT', receipt.status, receipt.name)
"""

READ = """kid = (await agents.self.children())[0]
page = await kid.messages()
print('TASK_SEEN', 'count to three' in page.content)
hits = await kid.search_messages('COUNT TO THREE')
seq = hits.rows[0]['seq']
row = await kid.messages(seq=seq, limit=200)
print('FOUND', hits.count, row.content.startswith(f'[row #{seq}]'), 'count to three' in row.content)
"""

PEEK = """kid = await agents.get({kid!r})
print('PEEK', kid.name, kid.depth, kid.closed)
page = await kid.messages()
print('PEEK_READ', 'count to three' in page.content)
try:
    await kid.cancel()
except AgentsError as error:
    print('PEEK_REFUSED', error)
listed = await agents.sessions()
print('LISTED', {kid!r} in [s.id for s in listed], agents.self.id in [s.id for s in listed])
child_session = next(s for s in listed if s.id == {kid!r})
scouts = await agents.sessions('SCOUT', cwd=child_session.cwd)
scout = next(s for s in scouts if s.id == {kid!r})
print('BY_NAME', scout.name, scout.depth, scout.model, scout.cwd == child_session.cwd)
print('ELSEWHERE', await agents.sessions(cwd='/nowhere'))
talked = await agents.sessions('COUNT TO THREE')
said = next(s for s in talked if s.id == {kid!r})
hit = said.matches[0]
row = await said.messages(seq=hit['seq'], limit=200)
print('SEARCHED', agents.self.id in [s.id for s in talked], 'count to three' in hit['preview'], 'count to three' in row.content)
print('UNQUERIED', listed[0].matches)
print('UNICODE', {kid!r} in [s.id for s in await agents.sessions('CAFÉ ÜNÏCODE')])
print('NOTHING', await agents.sessions('never ' + 'said anywhere'))
try:
    await agents.get('nobody')
except AgentsError as error:
    print('PEEK_MISSING', error)
"""


def user_text(request):
    return next(
        (
            item.get("content", "")
            for item in reversed(request["messages"])
            if item.get("role") == "user"
        ),
        "",
    )


def wait_for(predicate):
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.1)
    raise AssertionError("agent Python turn never arrived")


class AgentsPythonTests(unittest.TestCase):
    def test_python_spawn_identity_refusals_and_explicit_answer(self):
        def script(request):
            last = request["messages"][-1]
            user = user_text(request)
            peek = re.search(r"peek ([0-9a-f]+)", user)
            if last.get("role") == "user" and peek:
                return python(PEEK.format(kid=peek.group(1)))
            if last.get("role") == "user" and "spawn a scout" in user:
                return python(LEAD)
            if last.get("role") == "user" and 'kind="task"' in user:
                return python(CHILD)
            if last.get("role") == "user" and 'kind="message"' in user:
                return python(READ)
            return text("ok")

        provider = Provider(script)
        providers = {
            name: {
                "baseUrl": provider.url + f"/{name}/v1",
                "apiKey": "key",
                "model": f"fixture-{name}",
                "protocol": "chat_completions",
            }
            for name in ("alpha", "beta")
        }
        try:
            with Albedo(provider, providers=providers) as app:
                lead = app.session()
                app.prompt(lead, "spawn a scout").close()

                def observed():
                    records = []
                    for item in provider.requests:
                        messages = item["request"]["messages"]
                        last = messages[-1]
                        records.append(
                            {
                                "user": user_text(item["request"]),
                                "context": " ".join(
                                    str(m.get("content", "")) for m in messages
                                ),
                                "tool": str(last.get("content", ""))
                                if last.get("role") == "tool"
                                else "",
                            }
                        )
                    return records

                spawned = wait_for(
                    lambda: next(
                        (r["tool"] for r in observed() if "SPAWNED" in r["tool"]), None
                    )
                )
                self.assertIn("SPAWNED scout 1", spawned)
                self.assertIn("EMPTY_MODEL", spawned)
                child = wait_for(
                    lambda: next(
                        (r["tool"] for r in observed() if "SENT" in r["tool"]), None
                    )
                )
                self.assertIn("ME scout 1", child)
                self.assertIn("PROGRESS True", child)
                self.assertIn("REFUSED", child)
                self.assertIn("own children", child)
                self.assertIn("PARENT_READ True", child)
                self.assertIn("GOT True 0 None False", child)
                self.assertIn("ASK", child)
                self.assertIn("only the user deletes", child)
                self.assertTrue(
                    "SENT delivered spawn a scout" in child
                    or "SENT queued spawn a scout" in child
                )
                task = next(r for r in observed() if 'kind="task"' in r["user"])
                self.assertIn('You are child agent "scout"', task["context"])
                wait_for(
                    lambda: any(
                        'kind="message"' in r["user"] and "three" in r["user"]
                        for r in observed()
                    )
                )
                read = wait_for(
                    lambda: next(
                        (r["tool"] for r in observed() if "FOUND" in r["tool"]), None
                    )
                )
                self.assertIn("TASK_SEEN True", read)
                self.assertRegex(read, r"FOUND [1-9]\d* True True")
                kid = re.search(r"KID=([0-9a-f]+)", spawned).group(1)
                outsider = app.session()
                app.prompt(outsider, f"peek {kid}").close()
                peeked = wait_for(
                    lambda: next(
                        (r["tool"] for r in observed() if "PEEK_MISSING" in r["tool"]),
                        None,
                    )
                )
                self.assertIn("PEEK scout 1 False", peeked)
                self.assertIn("PEEK_READ True", peeked)
                self.assertIn("PEEK_REFUSED you can only cancel or close", peeked)
                self.assertIn("no agent named 'nobody'", peeked)
                self.assertIn("LISTED True True", peeked)
                self.assertIn("BY_NAME scout 1 fixture-alpha True", peeked)
                self.assertIn("ELSEWHERE []", peeked)
                self.assertIn("SEARCHED False True True", peeked)
                self.assertIn("UNQUERIED []", peeked)
                self.assertIn("UNICODE True", peeked)
                self.assertIn("NOTHING []", peeked)
                app.idle(lead)
                time.sleep(1)
                self.assertFalse(
                    any('kind="unreviewed"' in r["user"] for r in observed())
                )
        finally:
            provider.close()


if __name__ == "__main__":
    unittest.main()
