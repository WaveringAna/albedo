"""OS process-group identity, shutdown races and heavy-slot admission need controlled child processes rather than flaky daemon timing."""

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
from albedo_plugins import run as plugin  # noqa: E402

LOOP = asyncio.new_event_loop()
asyncio.set_event_loop(LOOP)
albedo_proc.reap_stopped_safely(LOOP)
EVENTS: list[dict[str, object]] = []


def install(job_slot=None) -> None:
    plugin.setup(
        albedo_api.PythonApi(
            version=1,
            loop=LOOP,
            host=lambda method, args: (_ for _ in ()).throw(
                RuntimeError("no host in tests")
            ),
            HostError=RuntimeError,
            capture=albedo_kernel.background_capture,
            preview=albedo_kernel.PREVIEW,
            send=EVENTS.append,
            on_shutdown=lambda close: None,
            background_handle=lambda _: None,
            job_slot=job_slot,
        )
    )


def run(coro):
    return LOOP.run_until_complete(coro)


def start(command: str, timeout: float = 300):
    """Start a shell line as a job without waiting for it; supervision is the
    same for any program, and a shell makes descendants easy to arrange."""
    return plugin.start(["/bin/sh", "-c", command], timeout)


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
        self.assertLess(time.monotonic() - started, 5)  # no wait for the deadline
        self.assertFalse(job.timed_out)
        self.assertTrue(job.termination.gone)
        self.assertFalse(pid_present(grandchild))

    def test_stop_escalates_and_is_retryable(self):
        job = start("trap '' TERM; while :; do sleep 0.2; done", timeout=30)
        run(asyncio.sleep(0.05))
        self.assertIsNone(job.poll())  # still running
        ending = run(job.stop())
        self.assertTrue(ending.gone)
        self.assertEqual(ending.signals, ("SIGTERM", "SIGKILL"))
        self.assertIs(run(job.stop()), ending)  # a reached verdict is not re-run
        run(job)
        self.assertIn(job.id, plugin.retained)

    def test_surviving_group_keeps_its_slot_and_is_surfaced(self):
        """A group that outlives KILL keeps its slot and is reported, not forgotten."""
        real = (
            albedo_proc.alive,
            albedo_proc.current,
            plugin.SHUTDOWN_TERM,
            plugin.SHUTDOWN_KILL,
            quick(),
        )
        albedo_proc.alive = lambda group: True
        albedo_proc.current = lambda group: True
        plugin.SHUTDOWN_TERM, plugin.SHUTDOWN_KILL = 0.01, 0.02
        try:
            job = start("true")
            wait(job)
            self.assertFalse(job.termination.gone)
            self.assertIn(job.id, plugin.active)  # work keeps its slot
            self.assertNotIn(job.id, plugin.retained)
            self.assertIn("cleanup failed", job.tail())
            run(plugin.close())
        finally:
            (
                albedo_proc.alive,
                albedo_proc.current,
                plugin.SHUTDOWN_TERM,
                plugin.SHUTDOWN_KILL,
                albedo_proc.terminate,
            ) = real
        cleanup = [event for event in EVENTS if event.get("type") == "cleanup"]
        self.assertEqual(len(cleanup), 1)
        self.assertTrue(
            any("SURVIVED" in failure for failure in cleanup[0]["failures"])
        )

    def test_ladder_reports_gone_and_refuses_reuse(self):
        self.assertFalse(albedo_proc.alive(albedo_proc.Group(999_999)))
        ending = run(albedo_proc.terminate([albedo_proc.Group(999_999)]))
        self.assertEqual(ending[0].signals, ())
        self.assertTrue(ending[0].gone)
        leader = run(
            asyncio.create_subprocess_shell("sleep 30", start_new_session=True)
        )
        try:
            group = albedo_proc.Group(leader.pid, "not-the-leader-we-created")
            if (
                albedo_proc.leader_token(leader.pid) is not None
            ):  # identity source present
                self.assertFalse(albedo_proc.alive(group))
                self.assertTrue(present(leader.pid))  # and it was left alone
        finally:
            run(albedo_proc.terminate([albedo_proc.Group(leader.pid)]))
            run(leader.wait())

    def test_long_jobs_pause_for_a_heavy_slot_and_quick_ones_never_ask(self):
        import subprocess

        async def check():
            asked: list[str] = []
            grant = LOOP.create_future()

            async def admission(id, on_queued):
                asked.append(id)
                on_queued()  # no slot free: the job is paused
                await grant

            install(admission)
            grace = plugin.GRACE
            plugin.GRACE = 0.2
            try:
                quick = start("true")
                await quick
                self.assertEqual(asked, [], "a quick command must never ask for a slot")
                slow = start("sleep 5", timeout=1.0)
                await asyncio.sleep(0.5)
                self.assertEqual(asked, [slow.id])
                self.assertTrue(slow.queued)
                state = subprocess.run(
                    ["ps", "-o", "stat=", "-p", str(slow.process.pid)],
                    capture_output=True,
                    text=True,
                ).stdout.strip()
                self.assertTrue(
                    state.startswith("T"),
                    f"paused job should be stopped, ps says {state!r}",
                )
                # Time spent paused does not count against the timeout.
                await asyncio.sleep(1.2)
                self.assertFalse(slow.task.done())
                grant.set_result(None)
                await asyncio.sleep(0.1)
                self.assertFalse(slow.queued)
                await slow
                self.assertTrue(slow.timed_out)
                self.assertTrue(slow.termination.gone)
            finally:
                plugin.GRACE = grace
                await plugin.close()

        run(check())

    def test_stop_before_spawn_and_immediate_cancellation_keep_ownership(self):
        async def check():
            job = start("sleep 30")
            ending = await job.stop()
            await job
            self.assertTrue(ending.gone)
            if job.group is not None:
                self.assertFalse(present(job.group.pgid))
            self.assertNotIn(job.id, plugin.active)
            cancelled = start("sleep 30")
            cancelled.task.cancel()
            await asyncio.sleep(0)
            await cancelled.stop()
            if cancelled.group is not None:
                self.assertFalse(present(cancelled.group.pgid))
            self.assertNotIn(cancelled.id, plugin.active)

        run(check())

    def test_retrying_failed_cleanup_releases_quota(self):
        from unittest.mock import patch

        async def refused(groups, *args, **kwargs):
            return [
                albedo_proc.Termination(group.pgid, (), False, ("fixture refusal",))
                for group in groups
            ]

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
            # the helper's alarm, fired sooner: it still has to arm it and
            # restore the default action, or the sleep outlasts the timeout
            "signal.alarm = lambda seconds: signal.setitimer(signal.ITIMER_REAL, 0.2)\n"
            "async def stuck(*args, **kwargs):\n    ctypes.PyDLL(None).sleep(30)\n"
            "albedo_proc.terminate = stuck\n"
            "sys.argv = ['helper', '{\"targets\": []}']\n"
            f"runpy.run_path({helper!r}, run_name='__main__')\n"
        )
        started = time.monotonic()
        result = subprocess.run(
            [sys.executable, "-c", code], capture_output=True, timeout=5
        )
        self.assertEqual(result.returncode, -signal.SIGALRM, result.stderr)
        self.assertLess(time.monotonic() - started, 5)

    def test_start_token_reads_a_kernel_stat_line(self):
        line = b"1234 (some cmd) S 1 1234 1234 0 -1 4194560 1 0 0 0 5 3 0 0 20 0 3 0 987654 1 2"
        self.assertEqual(albedo_proc.start_token(line), "987654")
        self.assertIsNone(albedo_proc.start_token(b"nonsense"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
