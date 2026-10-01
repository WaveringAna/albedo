"""Watcher ownership and completion/read races need GC and busy-host control that daemon E2E cannot reliably provide."""

from pathlib import Path
import sys
import textwrap
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from job_wake_test import Owner  # noqa: E402


class JobWatchersTest(unittest.TestCase):
    def setUp(self):
        self.owner = Owner(["run", "files"])
        self.addCleanup(self.owner.close)
        self.owner.wait_for(lambda frame: frame.get("type") == "ready")
        self.cells = 0
        self.cell(
            "import __main__ as kernel, asyncio, gc, weakref\n"
            "from albedo_plugins import run as runner, files as file_plugin"
        )

    def cell(self, code):
        self.cells += 1
        cell_id = f"c{self.cells}"
        self.owner.send(
            {"type": "execute", "id": cell_id, "code": textwrap.dedent(code)}
        )
        done = self.owner.wait_for(
            lambda frame: frame.get("type") == "done" and frame.get("id") == cell_id
        )
        self.assertEqual(done["status"], "ok", done)
        return done

    def test_an_early_read_does_not_consume_the_completion_watcher(self):
        self.cell("""
            job = run('echo', 'result')
            output.read(job.id)
            await asyncio.shield(job.task)
            assert not job._read and not job._awaited
            assert output.read(job.id).strip() == 'result'
            assert job._read
        """)

    def test_forgotten_jobs_and_internal_file_commands_release_watchers(self):
        self.cell("""
            job = run('true')
            await job
            reference = weakref.ref(job)
            runner.forget(job)
            del job
            await file_plugin._run('printf internal')
            await asyncio.sleep(0)
            gc.collect()
            assert reference() is None
            assert not jobs and not kernel.READ_WATCHERS
            assert not [c for c in kernel.ARCHIVES.values() if c.kind == 'job']
        """)

    def test_eviction_releases_jobs_but_preserves_held_handles(self):
        self.cell("""
            held = run('echo', 'held output')
            await held
            disposable = run('true')
            await disposable
            reference = weakref.ref(disposable)
            capture = disposable.capture
            del disposable
            for index in range(runner.RETAINED_LIMIT):
                # Keep this output past job eviction to catch strong watcher ownership.
                kernel.remember(capture)
                await run('true')
            await asyncio.sleep(0)
            gc.collect()
            assert reference() is None and capture.id in kernel.ARCHIVES
            assert capture.id not in kernel.READ_WATCHERS
            assert held.id not in jobs and held.id not in kernel.ARCHIVES
            assert held.id not in kernel.READ_WATCHERS
            assert held.tail().strip() == 'held output' and await held is held
        """)

    def test_other_callables_and_replacement_watchers_remain_usable(self):
        self.cell("""
            capture = kernel.background_capture('callables')
            reads = []
            kernel.watch_output(capture.id, lambda: reads.append('function'))
            gc.collect()
            output.read(capture.id)
            class Callback:
                def __call__(self):
                    reads.append('callable')
            callback = Callback()
            kernel.watch_output(capture.id, callback)
            output.read(capture.id)
            kernel.watch_output(capture.id, callback.__call__)
            kernel.watch_output(capture.id, lambda: reads.append('replacement'))
            del callback
            gc.collect()
            output.read(capture.id)
            assert reads == ['function', 'callable', 'replacement']
            kernel.forget_output(capture.id)
            assert capture.id not in kernel.READ_WATCHERS
        """)


if __name__ == "__main__":
    unittest.main()
