"""Quota readings land raw, each account keeps its own cadence, and failures back off.

The daemon-wide poller maps every account it can see — an OAuth account from
creds.json, an API-key profile whose base url names a feed — onto provide-usage
credentials and records each report as it came. This is the only place that
wiring is visible from outside, so it is E2E: the usage core itself is a fake
executable answering the `usage advance -` envelope (the real one needs
accounts), pointed at by ALBEDO_USAGE_CORE with short poll settings.

The cadence is asserted through the interval between one account's consecutive
readings, not through poll counts over wall time: counts race the machine, and
a hyper poll arriving a second late was read as "the busy cadence did not kick
in" when the schedule was exactly as configured. The intervals are what the
poller actually kept.
"""

import json
import os
import stat
import tempfile
import time
import unittest

from harness import Albedo, Provider, exclusive, text

# The busy cadence must stay distinguishable from the ordinary one, and the
# first failure backoff waits 2x the ordinary cadence, which sets the length.
# How the backoff grows and where it stops is test/daemon/quota_test.gleam.
POLL_SECONDS = 2
BUSY_SECONDS = 1

FAKE_USAGE = """#!/usr/bin/env python3
# Fake usage-core: one `advance -` envelope line in, one report line out. Each
# account is answered immediately, so one poll is one process. The provider in
# the envelope picks the script: anthropic is ordinary (5 percent), hyper is
# busy (85 percent, resetting soon), deepseek fails (an error report is data,
# not a driver failure). The happy path touches no file, so nothing can make
# it exit 1; anything unexpected is logged to fake-error.txt and answered as
# an error report rather than crashing, which the driver would report as the
# CLI itself failing.
import json, os, sys, time, traceback

ERRORS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fake-error.txt")

def report_for(provider):
    if provider == "anthropic":
        return {"planType": "pro",
                "limits": [{"id": "weekly", "label": "Weekly usage",
                            "usedPercent": 5, "windowLabel": "7 days",
                            "status": "ok"}]}
    if provider == "deepseek":
        return {"error": "the fixture deepseek key has no quota"}
    return {"limits": [{"id": "primary", "label": "Primary", "usedPercent": 85,
                        "windowLabel": "1 hour", "windowSeconds": 3600,
                        "resetsAt": int(time.time() * 1000) + 600000,
                        "status": "ok"}]}

try:
    line = sys.stdin.readline()
    provider = json.loads(line)["provider"]
    print(json.dumps({"report": report_for(provider)}))
except Exception:
    # A bad envelope lands here too: record it and answer an error report, so
    # the failure shows up as a reading rather than as an exit-1 crash.
    try:
        with open(ERRORS, "a") as errors:
            errors.write(traceback.format_exc())
    except Exception:
        pass
    print(json.dumps({"report": {"error": "the fake usage core failed"}}))
"""


# exclusive: configures global quota cadence, credentials, and usage-core environment
@exclusive
class QuotaTests(unittest.TestCase):
    def setUp(self):
        self.provider = Provider(lambda _request: text("ok"))
        self.addCleanup(self.provider.close)
        self.core = tempfile.TemporaryDirectory(prefix="quota-core-")
        self.addCleanup(self.core.cleanup)
        self.usage = os.path.join(self.core.name, "usage")
        with open(self.usage, "w") as out:
            out.write(FAKE_USAGE)
        os.chmod(self.usage, os.stat(self.usage).st_mode | stat.S_IEXEC)

        def prepare(app):
            # The poller resolves the core through the daemon's environment.
            app.env["ALBEDO_USAGE_CORE"] = self.usage
            app.write_extensions(
                {
                    "quota": {
                        "pollSeconds": POLL_SECONDS,
                        "busyPollSeconds": BUSY_SECONDS,
                    }
                }
            )
            app.store_secrets(
                "accounts",
                {
                    "anthropic": [
                        {
                            "type": "oauth",
                            "access": "fixture-anthropic-access",
                            "refresh": "fixture-anthropic-refresh",
                            "expires": int(time.time() * 1000) + 3600000,
                            "accountId": "fixture-account",
                        }
                    ]
                },
            )

        self.app = Albedo(
            self.provider,
            providers={
                "fixture": {
                    "baseUrl": self.provider.url,
                    "apiKey": "fixture-key",
                    "model": "fixture-model",
                    "protocol": "chat_completions",
                },
                "charm-hyper": {
                    "baseUrl": "https://hyper.charm.land/v1",
                    "apiKey": "fixture-hyper-key",
                    "model": "fixture-model",
                    "protocol": "chat_completions",
                },
                "deepseek-fixture": {
                    "baseUrl": "https://api.deepseek.com/v1",
                    "apiKey": "fixture-deepseek-key",
                    "model": "fixture-model",
                    "protocol": "chat_completions",
                },
            },
            prepare=prepare,
        )
        # The daemon boots with the fake core once prepare has named it, so
        # its cadence starts here.
        self.since = time.time() * 1000
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)

    def readings(self):
        with self.app.api("/quota") as response:
            return json.load(response)["readings"]

    def samples(self):
        """Every stored sample, newest first, through the history pages."""
        rows, cursor = [], 0
        while len(rows) < 1000:
            with self.app.api(f"/quota?history={cursor}&limit=200") as response:
                page = json.load(response)
            rows.extend(page["items"])
            if not page["hasMore"]:
                break
            cursor = page["nextCursor"]
        return rows

    def observed(self, account):
        """One timestamp per poll of one account since the boot, oldest first."""
        return sorted(
            {
                row["observedAt"]
                for row in self.samples()
                if row["account"] == account and row["observedAt"] > self.since
            }
        )

    def intervals(self, account):
        times = self.observed(account)
        return [later - earlier for earlier, later in zip(times, times[1:])]

    def fake_errors(self):
        try:
            with open(os.path.join(self.core.name, "fake-error.txt")) as errors:
                return errors.read()
        except FileNotFoundError:
            return ""

    def wait_for(self, condition, timeout, message):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if condition():
                return
            time.sleep(0.25)
        self.fail(message)

    def test_readings_land_and_each_account_keeps_its_cadence(self):
        # Readings land for every account: the OAuth account from creds.json,
        # the hyper-charm profile, and the deepseek profile.
        wanted = {("anthropic", "weekly"), ("hyper", "primary"), ("deepseek", "")}
        reading = {}
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            reading = {(r["provider"], r["limitId"]): r for r in self.readings()}
            if wanted.issubset(reading):
                break
            time.sleep(0.25)
        else:
            self.fail(
                "quota readings did not land: "
                + json.dumps(self.readings())
                + self.fake_errors()
            )
        hyper = reading[("hyper", "primary")]
        self.assertEqual(hyper["account"], "charm-hyper")
        self.assertEqual(hyper["usedPercent"], 85.0)
        self.assertEqual(hyper["windowSeconds"], 3600)
        self.assertGreater(hyper["resetsAt"], int(time.time() * 1000))
        self.assertEqual(hyper["status"], "ok")
        self.assertEqual(hyper["source"], "poll")
        anthropic = reading[("anthropic", "weekly")]
        self.assertEqual(anthropic["account"], "fixture-account")
        self.assertEqual(anthropic["usedPercent"], 5.0)
        # The report plan and each limit's window label are readings too, kept
        # exactly as reported; where the report had neither, they stay null.
        self.assertEqual(anthropic["plan"], "pro")
        self.assertEqual(anthropic["windowLabel"], "7 days")
        self.assertIsNone(hyper["plan"])
        self.assertEqual(hyper["windowLabel"], "1 hour")
        # A failed report is recorded as a reading too, error and all; a
        # missing percentage stays unknown rather than becoming zero.
        deepseek = reading[("deepseek", "")]
        self.assertIn("no quota", deepseek["error"])
        self.assertIsNone(deepseek["usedPercent"])
        self.assertIsNone(deepseek["plan"])

        # Enough polls of each account to read a cadence off the intervals.
        self.wait_for(
            lambda: len(self.observed("charm-hyper")) >= 5,
            60,
            "the busy cadence never produced five polls: "
            + json.dumps(self.intervals("charm-hyper"))
            + self.fake_errors(),
        )
        self.wait_for(
            lambda: len(self.observed("fixture-account")) >= 3,
            60,
            "the ordinary cadence never produced three polls: "
            + json.dumps(self.intervals("fixture-account"))
            + self.fake_errors(),
        )
        self.wait_for(
            lambda: len(self.observed("deepseek-fixture")) >= 2,
            60,
            "the failure backoff never produced a second poll: "
            + json.dumps(self.intervals("deepseek-fixture"))
            + self.fake_errors(),
        )

        # The schedule as the poller kept it: one account's consecutive
        # readings are one poll duration plus its wait, so each cadence shows
        # up as an interval with generous bounds either side of its setting.
        # The busy cadence (85 percent, resetting soon) is busyPollSeconds,
        # the ordinary one is pollSeconds, and the failing account backs off
        # past the ordinary cadence.
        busy = self.intervals("charm-hyper")
        ordinary = self.intervals("fixture-account")
        backed_off = self.intervals("deepseek-fixture")

        def median(values):
            return sorted(values)[len(values) // 2]

        message = (
            f"busy {busy}, ordinary {ordinary}, backed off {backed_off}, "
            f"fake errors {self.fake_errors()!r}"
        )
        self.assertGreaterEqual(median(busy), BUSY_SECONDS * 900, message)
        self.assertLess(
            median(busy),
            POLL_SECONDS * 900,
            message + " — the busy account polled at the ordinary cadence",
        )
        self.assertGreaterEqual(median(ordinary), POLL_SECONDS * 900, message)
        self.assertLess(median(ordinary), POLL_SECONDS * 1700, message)
        self.assertGreaterEqual(
            min(backed_off),
            POLL_SECONDS * 1800,
            message + " — failures did not back off",
        )

        # The feed is the fake, so a driver failure ("usage is not built", the
        # CLI crashing, the feed not finishing) is a bug in the host half, not
        # weather. An exit-1 burst would surface here as readings carrying it.
        failures = [
            row
            for row in self.samples()
            if row["observedAt"] > self.since
            and row["error"]
            and "usage" in row["error"]
        ]
        self.assertEqual(failures, [], "the usage driver failed against the fake")
        self.assertEqual(self.fake_errors(), "")

        # The latest reading per account and limit is the newest sample, and
        # history pages from it by row id, newest first.
        latest = {(r["provider"], r["limitId"]): r for r in self.readings()}
        with self.app.api("/quota?history=0") as response:
            page = json.load(response)
        samples = page["items"]
        ids = [sample["id"] for sample in samples]
        self.assertTrue(
            all(later < earlier for earlier, later in zip(ids, ids[1:])),
            f"history is not newest first: {ids}",
        )
        newest = max(
            (s for s in samples if s["provider"] == "hyper"), key=lambda s: s["id"]
        )
        self.assertEqual(
            newest["observedAt"], latest[("hyper", "primary")]["observedAt"]
        )
        cursor = ids[len(ids) // 2]
        with self.app.api(f"/quota?history={cursor}") as response:
            older = json.load(response)
        self.assertTrue(
            all(sample["id"] < cursor for sample in older["items"]),
            f"history after {cursor} reached newer rows: "
            f"{[s['id'] for s in older['items']]}",
        )
