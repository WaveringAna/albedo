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
from datetime import datetime
import os
import stat
import tempfile
import time
import unittest
import urllib.error

from harness import Albedo, Provider, exclusive, text


def milliseconds(timestamp):
    return round(
        datetime.fromisoformat(timestamp.replace("Z", "+00:00")).timestamp() * 1000
    )


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
RECOVERED = os.path.join(os.path.dirname(os.path.abspath(__file__)), "recovered")

def report_for(provider, credential):
    if provider == "anthropic" and credential.get("accountId") == "recovering-account":
        # Fails its first poll, then answers for good. A failure with no limits
        # is filed under the empty limit id, which a later success never reuses.
        if not os.path.exists(RECOVERED):
            open(RECOVERED, "w").close()
            return {"error": "the fixture key failed once"}
        return {"limits": [{"id": "weekly", "label": "Weekly usage", "usedPercent": 7,
                            "windowLabel": "7 days", "status": "ok"}]}
    if provider == "anthropic":
        return {"planType": "pro",
                "limits": [{"id": "weekly", "label": "Weekly usage",
                            "usedPercent": 5, "windowLabel": "7 days",
                            "status": "ok"}]}
    if provider == "google-antigravity":
        now_ms = int(time.time() * 1000)
        return {
            "limits": [
                {
                    "id": "gemini",
                    "label": "Gemini",
                    "usedPercent": 65,
                    "windowLabel": "1 hour",
                    "windowSeconds": 3600,
                    "resetsAt": now_ms + 3600000,
                    "status": "ok",
                },
                {
                    "id": "claude",
                    "label": "Claude",
                    "usedPercent": 100,
                    "windowLabel": "6 days",
                    "windowSeconds": 518400,
                    "resetsAt": 1799999999000,
                    "status": "exceeded",
                },
                {
                    "id": "gpt-oss",
                    "label": "GPT-OSS",
                    "usedPercent": 100,
                    "windowLabel": "6 days",
                    "windowSeconds": 518400,
                    "resetsAt": 1799999999000,
                    "status": "exceeded",
                },
            ]
        }
    if provider == "deepseek":
        return {"error": "the fixture deepseek key has no quota"}
    return {"limits": [{"id": "primary", "label": "Primary", "usedPercent": 85,
                        "windowLabel": "1 hour", "windowSeconds": 3600,
                        "resetsAt": int(time.time() * 1000) + 600000,
                        "status": "ok"}]}

try:
    line = sys.stdin.readline()
    envelope = json.loads(line)
    print(json.dumps({"report": report_for(envelope["provider"], envelope.get("credential", {}))}))
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
                        },
                        {
                            "type": "oauth",
                            "access": "fixture-recovering-access",
                            "refresh": "fixture-recovering-refresh",
                            "expires": int(time.time() * 1000) + 3600000,
                            "accountId": "recovering-account",
                        },
                    ],
                    "google-antigravity": [
                        {
                            "type": "oauth",
                            "access": "fixture-antigravity-access",
                            "refresh": "fixture-antigravity-refresh",
                            "expires": int(time.time() * 1000) + 3600000,
                            "projectId": "fixture-project",
                            "email": "antigravity@example.com",
                            "limitedUntil": 1799999999000,
                        }
                    ],
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
        with self.app.api("/server") as response:
            return json.load(response)["quota"]

    def samples(self):
        """Every stored sample, newest first, through the history pages."""
        rows, token = [], None
        while len(rows) < 1000:
            query = "&next=" + token if token else ""
            with self.app.api(
                f"/server?include=quota_history&limit=200{query}"
            ) as response:
                page = json.load(response)["quota_history"]
            rows.extend(page["items"])
            if page["next"] is None:
                break
            token = page["next"]
        return rows

    def observed(self, account):
        """One timestamp per poll of one account since the boot, oldest first."""
        return sorted(
            {
                milliseconds(row["observed_at"])
                for row in self.samples()
                if row["account_id"] == account
                and milliseconds(row["observed_at"]) > self.since
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
        wanted = {
            ("anthropic", "weekly"),
            ("hyper", "primary"),
            ("deepseek", ""),
            ("google-antigravity", "gemini"),
            ("google-antigravity", "claude"),
            ("google-antigravity", "gpt-oss"),
        }
        reading = {}
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            reading = {(r["provider"], r["limit_id"]): r for r in self.readings()}
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
        self.assertEqual(hyper["account_id"], "charm-hyper")
        self.assertEqual(hyper["used_percent"], 85.0)
        self.assertEqual(hyper["window_seconds"], 3600)
        self.assertGreater(milliseconds(hyper["resets_at"]), int(time.time() * 1000))
        self.assertEqual(hyper["status"], "ok")
        self.assertEqual(hyper["source"], "poll")
        anthropic = reading[("anthropic", "weekly")]
        self.assertEqual(anthropic["account_id"], "fixture-account")
        self.assertEqual(anthropic["used_percent"], 5.0)
        # The report plan and each limit's window label are readings too, kept
        # exactly as reported; where the report had neither, they stay null.
        self.assertEqual(anthropic["plan"], "pro")
        self.assertEqual(anthropic["window_label"], "7 days")
        self.assertIsNone(hyper["plan"])
        self.assertEqual(hyper["window_label"], "1 hour")
        # A failed report is recorded as a reading too, error and all; a
        # missing percentage stays unknown rather than becoming zero.
        deepseek = reading[("deepseek", "")]
        self.assertEqual(set(deepseek["error"]), {"code", "detail"})
        self.assertEqual(deepseek["error"]["code"], "quota_failed")
        self.assertIn("no quota", deepseek["error"]["detail"])
        self.assertLessEqual(len(deepseek["error"]["detail"]), 4096)
        self.assertIsNone(deepseek["used_percent"])
        self.assertIsNone(deepseek["plan"])

        # Google Antigravity readings for all three model-family meters
        gemini = reading[("google-antigravity", "gemini")]
        self.assertEqual(gemini["account_id"], "antigravity@example.com")
        self.assertEqual(gemini["used_percent"], 65.0)
        self.assertEqual(gemini["window_label"], "1 hour")
        self.assertEqual(gemini["window_seconds"], 3600)
        self.assertEqual(gemini["status"], "ok")

        claude = reading[("google-antigravity", "claude")]
        self.assertEqual(claude["account_id"], "antigravity@example.com")
        self.assertEqual(claude["used_percent"], 100.0)
        self.assertEqual(claude["window_label"], "6 days")
        self.assertEqual(claude["window_seconds"], 518400)
        self.assertEqual(claude["status"], "exceeded")

        gpt_oss = reading[("google-antigravity", "gpt-oss")]
        self.assertEqual(gpt_oss["account_id"], "antigravity@example.com")
        self.assertEqual(gpt_oss["used_percent"], 100.0)
        self.assertEqual(gpt_oss["window_label"], "6 days")
        self.assertEqual(gpt_oss["window_seconds"], 518400)
        self.assertEqual(gpt_oss["status"], "exceeded")

        # The poller heal re-keyed creds.json with legacy limitedUntil replaced by limitedMeters
        def healed():
            creds_path = self.app.home / "creds.json"
            if not creds_path.exists():
                return False
            data = (
                json.loads(creds_path.read_text())
                .get("accounts", {})
                .get("google-antigravity", [])
            )
            return bool(data and "limitedMeters" in data[0])

        self.wait_for(healed, 15, "poller heal did not re-key creds.json")
        creds = json.loads((self.app.home / "creds.json").read_text())["accounts"][
            "google-antigravity"
        ][0]
        self.assertNotIn("limitedUntil", creds)
        self.assertIn("limitedMeters", creds)
        self.assertEqual(creds["limitedMeters"]["claude"], 1799999999000)

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
            if milliseconds(row["observed_at"]) > self.since
            and row["error"]
            and "usage" in row["error"]["detail"]
        ]
        self.assertEqual(failures, [], "the usage driver failed against the fake")
        self.assertEqual(self.fake_errors(), "")

        # The latest reading per account and limit is the newest sample, and
        # history pages from it by row id, newest first.
        latest = {(r["provider"], r["limit_id"]): r for r in self.readings()}
        with self.app.api("/server?include=quota_history&limit=200") as response:
            page = json.load(response)["quota_history"]
        samples = page["items"]
        ids = [sample["sequence"] for sample in samples]
        self.assertTrue(
            all(later < earlier for earlier, later in zip(ids, ids[1:])),
            f"history is not newest first: {ids}",
        )
        newest = max(
            (s for s in samples if s["provider"] == "hyper"),
            key=lambda s: s["sequence"],
        )
        self.assertEqual(
            newest["observed_at"], latest[("hyper", "primary")]["observed_at"]
        )
        with self.app.api("/server?include=quota_history&limit=2") as response:
            first = json.load(response)["quota_history"]
        self.assertEqual(len(first["items"]), 2)
        self.assertIsNotNone(first["next"])
        with self.app.api(
            f"/server?include=quota_history&limit=2&next={first['next']}"
        ) as response:
            older = json.load(response)["quota_history"]
        self.assertTrue(older["items"])
        self.assertTrue(
            all(
                sample["sequence"] < first["items"][-1]["sequence"]
                for sample in older["items"]
            ),
            "quota continuation reached newer rows",
        )

        # An account that failed once and then answered has an old failure filed
        # under the empty limit id. The latest readings drop it once a later
        # reading of a real limit shows the account answering; deepseek, which
        # never answers, keeps its failure.
        self.wait_for(
            lambda: any(
                r["account_id"] != "fixture-account"
                and r["provider"] == "anthropic"
                and r["limit_id"] == "weekly"
                for r in self.readings()
            ),
            40,
            "the recovering account never answered",
        )
        recovered = [
            r
            for r in self.readings()
            if r["provider"] == "anthropic" and r["account_id"] != "fixture-account"
        ]
        self.assertEqual(
            [r["limit_id"] for r in recovered],
            ["weekly"],
            f"a failure the account recovered from is still its latest reading: {recovered}",
        )
        failures = [
            (r["provider"], r["limit_id"]) for r in self.readings() if r["error"]
        ]
        self.assertIn(("deepseek", ""), failures)
        self.assertTrue(
            any(
                row["limit_id"] == "" and row["error"]
                for row in self.samples()
                if row["provider"] == "anthropic"
                and row["account_id"] != "fixture-account"
            ),
            "the recovering account never recorded the failure this checks is dropped",
        )

        # Filtered history returns only that limit's rows newest-first.
        hyper_filter = (
            "quota_provider=hyper&quota_account=charm-hyper&quota_limit=primary"
        )
        with self.app.api(
            f"/server?include=quota_history&limit=200&{hyper_filter}"
        ) as response:
            hyper_history = json.load(response)["quota_history"]["items"]
        self.assertGreaterEqual(len(hyper_history), 5)
        self.assertTrue(
            all(
                s["provider"] == "hyper"
                and s["account_id"] == "charm-hyper"
                and s["limit_id"] == "primary"
                for s in hyper_history
            ),
            "filtered history returned observations from other limits",
        )
        hyper_ids = [s["sequence"] for s in hyper_history]
        self.assertTrue(
            all(later < earlier for earlier, later in zip(hyper_ids, hyper_ids[1:])),
            f"filtered history is not newest first: {hyper_ids}",
        )

        # quota_since in the future returns zero rows and next null.
        future_since = "2099-01-01T00:00:00Z"
        with self.app.api(
            f"/server?include=quota_history&limit=200&{hyper_filter}&quota_since={future_since}"
        ) as response:
            future_page = json.load(response)["quota_history"]
        self.assertEqual(future_page["items"], [])
        self.assertIsNone(future_page["next"])

        # since between two readings drops the older.
        cutoff = hyper_history[1]["observed_at"]
        with self.app.api(
            f"/server?include=quota_history&limit=200&{hyper_filter}&quota_since={cutoff}"
        ) as response:
            bounded_items = json.load(response)["quota_history"]["items"]
        self.assertTrue(
            all(
                milliseconds(s["observed_at"]) >= milliseconds(cutoff)
                for s in bounded_items
            ),
            "quota_since kept observations older than cutoff",
        )
        bounded_ids = [s["sequence"] for s in bounded_items]
        self.assertIn(hyper_history[0]["sequence"], bounded_ids)
        self.assertIn(hyper_history[1]["sequence"], bounded_ids)
        self.assertNotIn(hyper_history[-1]["sequence"], bounded_ids)

        # Paging a filtered history with limit=1 follows next across all of that
        # limit's rows with strictly decreasing sequence.
        paged_seqs = []
        next_cursor = None
        while True:
            cursor_param = f"&next={next_cursor}" if next_cursor else ""
            with self.app.api(
                f"/server?include=quota_history&limit=1&{hyper_filter}{cursor_param}"
            ) as response:
                page_data = json.load(response)["quota_history"]
            self.assertEqual(len(page_data["items"]), 1)
            paged_seqs.append(page_data["items"][0]["sequence"])
            next_cursor = page_data["next"]
            if not next_cursor:
                break
        self.assertEqual(paged_seqs, hyper_ids)
        self.assertTrue(
            all(later < earlier for earlier, later in zip(paged_seqs, paged_seqs[1:])),
            "paged filtered sequence is not strictly decreasing",
        )

        # A cursor from one filter replayed on another is rejected 400.
        with self.app.api(
            f"/server?include=quota_history&limit=1&{hyper_filter}"
        ) as response:
            token = json.load(response)["quota_history"]["next"]
        self.assertIsNotNone(token)
        anthropic_filter = (
            "quota_provider=anthropic&quota_account=fixture-account&quota_limit=weekly"
        )
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self.app.api(
                f"/server?include=quota_history&limit=1&{anthropic_filter}&next={token}"
            )
        self.assertEqual(cm.exception.code, 400)

        # Partial filter (only quota_account) is 400.
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self.app.api("/server?include=quota_history&quota_account=charm-hyper")
        self.assertEqual(cm.exception.code, 400)

        # quota_since without the trio is 400.
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self.app.api(f"/server?include=quota_history&quota_since={future_since}")
        self.assertEqual(cm.exception.code, 400)

        # Bad since is 400.
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self.app.api(
                f"/server?include=quota_history&{hyper_filter}&quota_since=not-a-timestamp"
            )
        self.assertEqual(cm.exception.code, 400)

        # Filter parameters require include=quota_history.
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self.app.api(f"/server?{hyper_filter}")
        self.assertEqual(cm.exception.code, 400)
