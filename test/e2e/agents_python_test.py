"""Python agent API: spawn, family identity, refusals, progress, and explicit mail."""
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
print('SPAWNED', kid.name, kid.depth, kid.parent.name)
"""
CHILD = """me = agents.self
print('ME', me.name, me.depth, me.parent.name)
print('PROGRESS', await agents.progress('counting'))
try:
    await me.parent.cancel()
except AgentsError as error:
    print('REFUSED', error)
try:
    await me.parent.delete()
except AgentsError as error:
    print('ASK', error)
receipt = await mail.submit('parent', 'three')
print('SENT', receipt.status, receipt.name)
"""


def user_text(request):
    return next((item.get("content", "") for item in reversed(request["messages"])
                 if item.get("role") == "user"), "")


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
            if last.get("role") == "user" and "spawn a scout" in user:
                return python(LEAD)
            if last.get("role") == "user" and 'kind="task"' in user:
                return python(CHILD)
            return text("ok")

        provider = Provider(script)
        providers = {name: {"baseUrl": provider.url + f"/{name}/v1", "apiKey": "key",
                            "model": f"fixture-{name}", "protocol": "chat_completions"}
                     for name in ("alpha", "beta")}
        try:
            with Albedo(provider, providers=providers) as app:
                lead = app.session()
                app.prompt(lead, "spawn a scout").close()

                def observed():
                    records = []
                    for item in provider.requests:
                        messages = item["request"]["messages"]
                        last = messages[-1]
                        records.append({"user": user_text(item["request"]),
                                        "context": " ".join(str(m.get("content", "")) for m in messages),
                                        "tool": str(last.get("content", "")) if last.get("role") == "tool" else ""})
                    return records

                spawned = wait_for(lambda: next((r["tool"] for r in observed()
                                                  if "SPAWNED" in r["tool"]), None))
                self.assertIn("SPAWNED scout 1", spawned)
                self.assertIn("EMPTY_MODEL", spawned)
                child = wait_for(lambda: next((r["tool"] for r in observed()
                                                if "SENT" in r["tool"]), None))
                self.assertIn("ME scout 1", child)
                self.assertIn("PROGRESS True", child)
                self.assertIn("REFUSED", child)
                self.assertIn("own children", child)
                self.assertIn("ASK", child)
                self.assertIn("only the user deletes", child)
                self.assertTrue("SENT delivered spawn a scout" in child or
                                "SENT queued spawn a scout" in child)
                task = next(r for r in observed() if 'kind="task"' in r["user"])
                self.assertIn('You are child agent "scout"', task["context"])
                wait_for(lambda: any('kind="message"' in r["user"] and "three" in r["user"]
                                     for r in observed()))
                app.idle(lead)
                time.sleep(1)
                self.assertFalse(any('kind="unreviewed"' in r["user"] for r in observed()))
        finally:
            provider.close()


if __name__ == "__main__":
    unittest.main()
