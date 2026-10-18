"""Python agent API: spawn, family identity, refusals, progress, explicit mail,
agents.get, reading messages across sessions, and listing and searching them."""

import json
import re
import time
import unittest

from harness import Albedo, Provider, latest_user, python, text

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

PEEK = """async def paged_sessions(query='', cwd=None):
    found = []
    while True:
        page = await agents.sessions(query, cwd=cwd, offset=len(found))
        if not page:
            return found
        found.extend(page)

kid = await agents.get({kid!r})
print('PEEK', kid.name, kid.depth, kid.closed)
page = await kid.messages()
print('PEEK_READ', 'count to three' in page.content)
try:
    await kid.cancel()
except AgentsError as error:
    print('PEEK_REFUSED', error)
listed = await paged_sessions()
print('LISTED', {kid!r} in [s.id for s in listed], agents.self.id in [s.id for s in listed])
child_session = next(s for s in listed if s.id == {kid!r})
scouts = await paged_sessions('SCOUT', cwd=child_session.cwd)
scout = next(s for s in scouts if s.id == {kid!r})
print('BY_NAME', scout.name, scout.depth, scout.model, scout.cwd == child_session.cwd)
print('ELSEWHERE', await paged_sessions(cwd='/nowhere'))
talked = await paged_sessions('COUNT TO THREE')
said = next(s for s in talked if s.id == {kid!r})
hit = said.matches[0]
row = await said.messages(seq=hit['seq'], limit=200)
print('SEARCHED', agents.self.id in [s.id for s in talked], 'count to three' in hit['preview'], 'count to three' in row.content)
print('UNQUERIED', listed[0].matches)
print('UNICODE', {kid!r} in [s.id for s in await paged_sessions('CAFÉ ÜNÏCODE')])
print('NOTHING', await paged_sessions('never ' + 'said anywhere'))
try:
    await agents.get('nobody')
except AgentsError as error:
    print('PEEK_MISSING', error)
"""


def wait_for(predicate, timeout=60):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.05)
    raise AssertionError(f"agent Python turn never arrived within {timeout}s")


class AgentsPythonTests(unittest.TestCase):
    def test_python_spawn_identity_refusals_and_explicit_answer(self):
        def script(request):
            last = request["messages"][-1]
            user = latest_user(request)
            peek = re.search(r"peek ([0-9a-f]+)", user)
            if last.get("role") == "user" and peek:
                return python(PEEK.format(kid=peek.group(1)))
            if last.get("role") == "user" and user == "spawn a scout":
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
                        records.append(
                            {
                                "user": latest_user(item["request"]),
                                "context": " ".join(
                                    str(m.get("content", "")) for m in messages
                                ),
                                "tool": " ".join(
                                    str(m.get("content", ""))
                                    for m in messages
                                    if m.get("role") == "tool"
                                ),
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
                match = re.search(r"KID=([0-9a-f]+)", spawned)
                assert match is not None
                kid = match.group(1)
                outsider = app.session()
                app.prompt(outsider, f"peek {kid}").close()
                app.idle(outsider, timeout=60)
                delivered = [record["tool"] for record in observed() if record["tool"]]
                peeked = next(
                    (record for record in delivered if "PEEK_MISSING" in record), None
                )
                assert peeked is not None, (
                    "PEEK turn finished without its final marker; delivered tools: "
                    + repr(delivered)
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

    def test_spawn_verifier_gates_parent_mail_and_stopping_until_command_exits_zero(
        self,
    ):
        lead_code = (
            "models = await agents.models()\n"
            "buddy = await agents.self.spawn('wait', name='buddy', model=models[0])\n"
            "try:\n"
            "    await agents.self.spawn('bad', name='bad', model=models[0], verifier='   ')\n"
            "except TypeError as error:\n"
            "    print('EMPTY_VERIFIER', error)\n"
            "worker = await agents.self.spawn(\n"
            "    'create gate-passed',\n"
            "    name='worker',\n"
            "    model=models[0],\n"
            "    verifier='test -f gate-passed && grep -q ready gate-passed || { echo MISSING_GATE >&2; exit 1; }',\n"
            ")\n"
            "print('SPAWNED_VERIFIED', worker.name, buddy.name)\n"
        )
        worker_first = (
            "peer_receipt = await mail.submit('buddy', 'hello sibling')\n"
            "print('PEER_MAIL', peer_receipt.status)\n"
            "try:\n"
            "    await mail.submit('parent', 'premature done')\n"
            "except PermissionError as error:\n"
            "    print('GATE_BLOCKED', error)\n"
        )
        worker_fix = (
            "q = await mail.request('parent', 'need clarification')\n"
            "print('QUESTION_MAIL', q.status)\n"
            "b = await mail.submit('parent', 'unavoidable issue', blocker=True)\n"
            "print('BLOCKER_MAIL', b.status)\n"
            "files.write('gate-passed', 'ready\\n')\n"
            "receipt = await mail.submit('parent', 'verified done')\n"
            "print('GATE_PASSED', receipt.status)\n"
        )

        def script(request):
            last = request["messages"][-1]
            user = latest_user(request)
            if last.get("role") == "user" and user == "verify worker":
                return python(lead_code)
            if (
                last.get("role") == "user"
                and 'kind="task"' in user
                and "create gate-passed" in user
            ):
                return python(worker_first)
            if last.get("role") == "tool" and "GATE_BLOCKED" in str(
                last.get("content", "")
            ):
                return text("stopping without fixing yet")
            if last.get("role") == "user" and "MISSING_GATE" in user:
                return python(worker_fix)
            if last.get("role") == "user" and 'kind="task"' in user and "wait" in user:
                return python("await mail.submit('parent', 'buddy done')")
            return text("ok")

        provider = Provider(script)
        try:
            with Albedo(provider) as app:
                lead = app.session()
                app.prompt(lead, "verify worker").close()

                def observed():
                    records = []
                    for item in provider.requests:
                        messages = item["request"]["messages"]
                        records.append(
                            {
                                "user": latest_user(item["request"]),
                                "tool": " ".join(
                                    str(m.get("content", ""))
                                    for m in messages
                                    if m.get("role") == "tool"
                                ),
                            }
                        )
                    return records

                try:
                    spawned = wait_for(
                        lambda: next(
                            (
                                r["tool"]
                                for r in observed()
                                if "SPAWNED_VERIFIED" in r["tool"]
                            ),
                            None,
                        ),
                    )
                    self.assertIn("EMPTY_VERIFIER", spawned)
                    self.assertIn("SPAWNED_VERIFIED worker buddy", spawned)
                    blocked = wait_for(
                        lambda: next(
                            (
                                r["tool"]
                                for r in observed()
                                if "GATE_BLOCKED" in r["tool"]
                            ),
                            None,
                        ),
                    )
                    self.assertIn("PEER_MAIL", blocked)
                    self.assertIn("MISSING_GATE", blocked)
                    passed = wait_for(
                        lambda: next(
                            (
                                r["tool"]
                                for r in observed()
                                if "GATE_PASSED" in r["tool"]
                            ),
                            None,
                        ),
                    )
                    self.assertIn("QUESTION_MAIL", passed)
                    self.assertIn("BLOCKER_MAIL", passed)
                    self.assertIn("GATE_PASSED", passed)
                    wait_for(
                        lambda: any(
                            'from="worker"' in r["user"]
                            and "verified done" in r["user"]
                            for r in observed()
                        ),
                    )
                    self.assertFalse(
                        any("premature done" in r["user"] for r in observed())
                    )
                except Exception:
                    print("DEBUG_OBSERVED:", json.dumps(observed(), indent=2))
                    raise
        finally:
            provider.close()
