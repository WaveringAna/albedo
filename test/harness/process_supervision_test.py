"""Focused supervision tests: ownership, deadlines, quota, and surfacing.

Runs with `gleam test`; standalone: python3 test/harness/process_supervision_test.py
"""
from __future__ import annotations

import asyncio
import os
import sys
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "priv", "python"))

import albedo_api  # noqa: E402
import albedo_kernel  # noqa: E402
import albedo_proc  # noqa: E402
from albedo_plugins import bash as plugin  # noqa: E402

LOOP = asyncio.new_event_loop()
asyncio.set_event_loop(LOOP)
EVENTS: list[dict[str, object]] = []


def install() -> None:
    plugin.setup(albedo_api.PythonApi(
        version=1, loop=LOOP,
        host=lambda method, args: (_ for _ in ()).throw(RuntimeError("no host in tests")),
        HostError=RuntimeError, capture=albedo_kernel.background_capture, preview=albedo_kernel.PREVIEW,
        send=EVENTS.append, on_shutdown=lambda close: None, background_handle=lambda _: None))


def run(coro):
    return LOOP.run_until_complete(coro)


def start(command: str, timeout: float = 300):
    """Start a job without waiting for it."""
    return plugin.bash(command, timeout=timeout)


def quick(term: float = 0.01, kill: float = 0.02):
    """Patch the ladder windows so a refusing group is tested without real waiting."""
    real = albedo_proc.terminate

    async def patched(groups, _term=0.0, _kill=0.0):
        return await real(groups, term, kill)

    albedo_proc.terminate = patched
    return real


def wait(job):
    return run(job)


def present(pgid: int) -> bool:
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def pid_present(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def pid_from(output: str) -> int:
    return int(output.strip().splitlines()[0])


class SupervisionTest(unittest.TestCase):
    def setUp(self):
        EVENTS.clear()
        install()

    def test_a_finished_job_does_not_hold_a_running_slot(self):
        first = start("printf first")
        wait(first)
        self.assertEqual(first.poll(), 0)
        for _ in range(plugin.ACTIVE_LIMIT + 6):
            self.assertEqual(wait(start("true")).poll(), 0)
        self.assertEqual(len(plugin.active), 0)
        self.assertLessEqual(len(plugin.retained), plugin.RETAINED_LIMIT)
        self.assertLessEqual(len(plugin.jobs), plugin.RETAINED_LIMIT)
        self.assertNotIn(first.id, plugin.jobs)      # displaced from the index
        self.assertEqual(first.tail(), "first")      # the handle still answers
        self.assertEqual(first.poll(), 0)

    def test_deadline_ends_the_whole_group(self):
        job = start("sleep 30 & echo $!; wait", timeout=0.1)
        wait(job)
        self.assertTrue(job.timed_out)
        self.assertTrue(job.termination.gone)
        self.assertFalse(present(job.group.pgid))
        self.assertFalse(pid_present(pid_from(job.tail())))
        self.assertIn("deadline exceeded after 0.1s", job.tail())
        self.assertIn("terminated", job.tail())

    def test_command_exit_ends_descendants_that_hold_no_output(self):
        started = time.monotonic()
        job = start("sleep 30 >/dev/null 2>&1 & echo $!; exit 0", timeout=30)
        wait(job)
        grandchild = pid_from(job.tail())
        self.assertLess(time.monotonic() - started, 5)   # no wait for the deadline
        self.assertFalse(job.timed_out)
        self.assertTrue(job.termination.gone)
        self.assertFalse(pid_present(grandchild))

    def test_command_exit_is_not_held_by_a_descendant_holding_output(self):
        started = time.monotonic()
        job = start("sleep 30 & echo $!; exit 0", timeout=30)
        wait(job)
        self.assertLess(time.monotonic() - started, 5)
        self.assertTrue(job.termination.gone)
        self.assertFalse(pid_present(pid_from(job.tail())))

    def test_stop_escalates_and_is_retryable(self):
        job = start("trap '' TERM; while :; do sleep 0.2; done", timeout=30)
        run(asyncio.sleep(0.05))
        self.assertIsNone(job.poll())                    # still running
        ending = run(job.stop())
        self.assertTrue(ending.gone)
        self.assertEqual(ending.signals, ("SIGTERM", "SIGKILL"))
        self.assertIs(run(job.stop()), ending)           # a reached verdict is not re-run
        run(job)
        self.assertIn(job.id, plugin.retained)

    def test_cancelled_spawn_still_owns_its_child(self):
        real = asyncio.create_subprocess_shell

        async def slow(*args, **kwargs):
            await asyncio.sleep(0.05)
            return await real(*args, **kwargs)

        asyncio.create_subprocess_shell = slow
        try:
            job = start("sleep 30", timeout=30)
            run(asyncio.sleep(0.01))       # inside the spawn
            job.task.cancel()
            run(asyncio.sleep(0.3))
        finally:
            asyncio.create_subprocess_shell = real
        self.assertIsNotNone(job.process)
        self.assertLess(job.exit_code, 0)   # the child the spawn created was ended
        self.assertTrue(job.termination.gone)
        self.assertFalse(present(job.group.pgid))

    def test_surviving_group_keeps_its_slot_and_is_surfaced(self):
        """A group that outlives KILL keeps its slot and is reported, not forgotten."""
        real = (albedo_proc.alive, albedo_proc.current, plugin.SHUTDOWN_TERM, plugin.SHUTDOWN_KILL, quick())
        albedo_proc.alive = lambda group: True
        albedo_proc.current = lambda group: True
        plugin.SHUTDOWN_TERM, plugin.SHUTDOWN_KILL = 0.01, 0.02
        try:
            job = start("true")
            wait(job)
            self.assertFalse(job.termination.gone)
            self.assertIn(job.id, plugin.active)          # work keeps its slot
            self.assertNotIn(job.id, plugin.retained)
            self.assertIn("cleanup failed", job.tail())
            run(plugin.close())
        finally:
            albedo_proc.alive, albedo_proc.current, plugin.SHUTDOWN_TERM, plugin.SHUTDOWN_KILL, albedo_proc.terminate = real
        cleanup = [event for event in EVENTS if event.get("type") == "cleanup"]
        self.assertEqual(len(cleanup), 1)
        self.assertTrue(any("SURVIVED" in failure for failure in cleanup[0]["failures"]))

    def test_ladder_reports_gone_and_refuses_reuse(self):
        self.assertFalse(albedo_proc.alive(albedo_proc.Group(999_999)))
        ending = run(albedo_proc.terminate([albedo_proc.Group(999_999)]))
        self.assertEqual(ending[0].signals, ())
        self.assertTrue(ending[0].gone)
        leader = run(asyncio.create_subprocess_shell("sleep 30", start_new_session=True))
        try:
            group = albedo_proc.Group(leader.pid, "not-the-leader-we-created")
            if albedo_proc.leader_token(leader.pid) is not None:   # identity source present
                self.assertFalse(albedo_proc.alive(group))
                self.assertTrue(present(leader.pid))             # and it was left alone
        finally:
            run(albedo_proc.terminate([albedo_proc.Group(leader.pid)]))
            run(leader.wait())

    def test_signal_helper_ends_a_group_and_reports_a_verdict(self):
        """The supervisor's helper: one argv in, one structured verdict out."""
        import json
        import subprocess

        root = os.path.join(ROOT, "priv", "python")
        child = subprocess.Popen(["/bin/sh", "-c", "sleep 30 >/dev/null 2>&1 & wait"],
                                 start_new_session=True)
        try:
            request = json.dumps({"targets": [{"label": "job", "pgid": child.pid}], "term_ms": 200, "kill_ms": 500})
            answer = subprocess.run(
                [sys.executable, "-u", os.path.join(root, "albedo_signal.py"), request],
                capture_output=True, text=True, timeout=30)
            self.assertEqual(answer.returncode, 0)
            verdict = json.loads(answer.stdout)
            self.assertEqual(verdict["ok"], True)
            self.assertEqual(verdict["targets"][0]["label"], "job")
            self.assertEqual(verdict["targets"][0]["gone"], True)
            self.assertEqual(child.wait(), -15)  # reap before probing the zombie's pid
            self.assertFalse(present(child.pid))
        finally:
            if child.poll() is None:
                os.killpg(child.pid, 9)
                child.wait()

    def test_active_quota_and_batch_shutdown_share_one_deadline(self):
        async def check():
            owned = [start("trap '' TERM; exec sleep 30") for _ in range(plugin.ACTIVE_LIMIT)]
            try:
                with self.assertRaisesRegex(RuntimeError, "64 jobs"):
                    start("true")
                # Allow every shell to install its handler before testing escalation.
                await asyncio.gather(*(job._spawn() for job in owned))
                await asyncio.sleep(0.1)
                started = time.monotonic()
                await plugin.close()
                await asyncio.gather(*owned)
                self.assertLess(time.monotonic() - started, 5)
                self.assertEqual(len(plugin.active), 0)
                self.assertTrue(all(job.termination.gone for job in owned))
                self.assertTrue(all(not present(job.group.pgid) for job in owned))
            finally:
                await asyncio.gather(*(job.stop() for job in owned))
        run(check())

    def test_permission_denied_is_a_survivor_not_a_success(self):
        from unittest.mock import patch
        with patch.object(albedo_proc, "deliver", side_effect=PermissionError(1, "denied")):
            result = run(albedo_proc.terminate([albedo_proc.Group(os.getpgrp())], term=0, kill=0))[0]
        self.assertFalse(result.gone)
        self.assertEqual(len(result.failures), 2)

    def test_stop_before_spawn_and_immediate_cancellation_keep_ownership(self):
        async def check():
            job = start("sleep 30")
            ending = await job.stop()
            await job
            self.assertTrue(ending.gone)
            self.assertFalse(present(job.group.pgid))
            self.assertNotIn(job.id, plugin.active)
            cancelled = start("sleep 30")
            cancelled.task.cancel()
            await asyncio.sleep(0)
            await cancelled.stop()
            self.assertFalse(present(cancelled.group.pgid))
            self.assertNotIn(cancelled.id, plugin.active)
        run(check())

    def test_retrying_failed_cleanup_releases_quota(self):
        from unittest.mock import patch
        async def refused(groups, *args, **kwargs):
            return [albedo_proc.Termination(group.pgid, (), False, ("fixture refusal",)) for group in groups]
        job = start("true")
        with patch.object(albedo_proc, "terminate", side_effect=refused):
            wait(job)
        self.assertIn(job.id, plugin.active)
        self.assertTrue(run(job.stop()).gone)
        self.assertNotIn(job.id, plugin.active)
        self.assertTrue(EVENTS[-1]["cleanup"]["gone"])

    def test_helper_watchdog_terminates_native_code_even_if_alarm_was_ignored(self):
        import signal
        import subprocess
        helper = os.path.join(ROOT, "priv", "python", "albedo_signal.py")
        code = (
            f"import sys; sys.path.insert(0, {os.path.dirname(helper)!r})\n"
            "import ctypes, runpy, signal, albedo_proc\n"
            "signal.signal(signal.SIGALRM, signal.SIG_IGN)\n"
            "async def stuck(*args, **kwargs):\n    ctypes.PyDLL(None).sleep(30)\n"
            "albedo_proc.terminate = stuck\n"
            "sys.argv = ['helper', '{\"targets\": []}']\n"
            f"runpy.run_path({helper!r}, run_name='__main__')\n"
        )
        started = time.monotonic()
        result = subprocess.run([sys.executable, "-c", code], capture_output=True, timeout=5)
        self.assertEqual(result.returncode, -signal.SIGALRM, result.stderr)
        self.assertLess(time.monotonic() - started, 5)

    def test_start_token_reads_a_kernel_stat_line(self):
        line = b"1234 (some cmd) S 1 1234 1234 0 -1 4194560 1 0 0 0 5 3 0 0 20 0 3 0 987654 1 2"
        self.assertEqual(albedo_proc.start_token(line), "987654")
        self.assertIsNone(albedo_proc.start_token(b"nonsense"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
