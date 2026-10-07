"""Prompts the model schedules for itself must show in the chat sidebar, so
the user sees what will wake the session without opening /schedule."""

import json
import unittest

from harness import Albedo, Provider, python, text

SCHEDULE = (
    "await commands.schedule('add', 'in:5400 rebuild the index')\n"
    "await commands.schedule('heartbeat', 'every:600 check the ci')"
)


def reply(request):
    if request["messages"][-1].get("role") == "user":
        return python(SCHEDULE)
    return text("scheduled")


class ScheduleTests(unittest.TestCase):
    def test_model_schedules_show_in_the_sidebar(self):
        provider = Provider(reply)
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            session = app.session()
            app.prompt(session, "remind yourself").close()
            app.idle(session)
            with app.api(f"/sessions/{session}?tail=0") as response:
                glances = json.load(response)["glances"]
            glance = next(g for g in glances if g["extension"] == "schedule")
            self.assertEqual(glance["title"], "scheduled")
            self.assertEqual(
                glance["url"], f"/extensions/schedule/jobs?session_id={session}"
            )
            # soonest first, each led by when it fires
            self.assertEqual(
                [(row["badge"], row["text"]) for row in glance["rows"]],
                [
                    ("heartbeat", "heartbeat 10m · check the ci"),
                    ("once", "in 1h · rebuild the index"),
                ],
            )


if __name__ == "__main__":
    unittest.main()
