"""run() starts programs without a shell, and cells stay on it: a shell line
or a raw process API is refused with the run() call it means."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "priv" / "python"))
from job_wake_test import Owner  # noqa: E402
import albedo_shell  # noqa: E402


class TranslateTest(unittest.TestCase):
    def test_simple_lines_read_as_run_calls(self):
        cases = {
            "cd cli && go test ./... | tail -5": "job = await run('go', 'test', './...', cwd='cli')\njob.tail(lines=5)",
            "FOO=1 cargo build 2>&1 | head -n 40": "job = await run('cargo', 'build', env={'FOO': '1'})\njob.head(lines=40)",
            "rg -n 'a|b; c' src": "job = await run('rg', '-n', 'a|b; c', 'src')\njob.tail()",
            "git log HEAD~1": "job = await run('git', 'log', 'HEAD~1')\njob.tail()",
            "bash -c 'cd cli && make'": "job = await run('make', cwd='cli')\njob.tail()",
            "cd a && grep x f | sort | head -3":
                "job = await run('grep', 'x', 'f', cwd='a').pipe('sort', cwd='a')\njob.head(lines=3)",
        }
        for line, want in cases.items():
            self.assertEqual(albedo_shell.translate(line), want, line)

    def test_lines_that_do_more_have_no_translation(self):
        for line in ["for f in *.py; do echo $f; done", "a && b", "ls ~/x", "a | b && c",
                     "sleep 1 &", "echo $HOME", "cat < f", "a || b", "echo 'open"]:
            self.assertIsNone(albedo_shell.translate(line), line)

    def test_shell_scripts_are_found_in_their_spellings(self):
        self.assertEqual(albedo_shell.shell_script(["/bin/bash", "-lc", "x"]), "x")
        self.assertEqual(albedo_shell.shell_script(["sh", "-e", "-c", "y"]), "y")
        self.assertIsNone(albedo_shell.shell_script(["bash", "build.sh"]))
        self.assertIsNone(albedo_shell.shell_script(["python3", "-c", "print(1)"]))


class RunTest(unittest.TestCase):
    def setUp(self):
        self.owner = Owner(["run"])
        self.addCleanup(self.owner.close)
        self.owner.wait_for(lambda f: f.get("type") == "ready")
        self.cells = 0

    def cell(self, code):
        self.cells += 1
        id = f"c{self.cells}"
        self.owner.send({"type": "execute", "id": id, "code": code})
        trace = self.owner.wait_for(lambda f: f.get("type") == "trace" and f.get("id") == id)["trace"]
        done = self.owner.wait_for(lambda f: f.get("type") == "done" and f.get("id") == id)
        return done, [item["target"] for item in trace["activities"] if item["kind"] == "run"]

    def assertSuggests(self, code, done):
        """The refusal carries `code`, indented as one block."""
        self.assertIn("".join(f"    {line}\n" for line in code.splitlines()), done["output"])

    def test_arguments_cwd_env_and_stdin_reach_the_program(self):
        Path(self.owner.workspace, "sub").mkdir()
        done, ran = self.cell(
            "import sys\n"
            "job = await run(sys.executable, '-c', 'import os, sys; print(os.getcwd().endswith(\"sub\"), "
            "os.environ[\"GREETING\"], sys.stdin.read().upper())', cwd='sub', env={'GREETING': 'hi'}, stdin='quiet')\n"
            "(job.exit_code, job.tail())")
        self.assertEqual(done["value"], "(0, 'True hi QUIET\\n')")
        self.assertEqual(len(ran), 1)

    def test_head_and_tail_read_lines(self):
        done, ran = self.cell("job = await run('seq', '1', '100')\n(job.head(lines=2), job.tail(lines=2))")
        self.assertEqual(done["value"], "('1\\n2\\n', '99\\n100\\n')")
        self.assertEqual(ran, ["seq 1 100"])

    def test_a_shell_is_refused_with_the_call_it_means(self):
        done, ran = self.cell("run('bash', '-c', 'cd /tmp && ls -la | tail -3')")
        self.assertEqual(done["status"], "error")
        self.assertSuggests("job = await run('ls', '-la', cwd='/tmp')\njob.tail(lines=3)", done)
        self.assertEqual(ran, [])

    def test_a_whole_line_as_the_program_says_how_to_split_it(self):
        done, _ = self.cell("run('git status --short')")
        self.assertSuggests("job = await run('git', 'status', '--short')\njob.tail()", done)
        missing, _ = self.cell("run('surely-not-a-program-here')")
        self.assertIn("no such program on PATH", missing["output"])

    def test_cells_are_refused_raw_process_apis(self):
        for code, suggestion in [
                ("import subprocess\nsubprocess.run(['git', 'status'], cwd='/tmp')",
                 "job = await run('git', 'status', cwd='/tmp')\njob.tail()"),
                ("import subprocess\nsubprocess.run('echo hi | head -1', shell=True)",
                 "job = await run('echo', 'hi')\njob.head(lines=1)"),
                ("import os\nos.system('make test')", "job = await run('make', 'test')\njob.tail()"),
                ("import asyncio\nawait asyncio.create_subprocess_exec('ls')", "job = await run('ls')\njob.tail()")]:
            done, ran = self.cell(code)
            self.assertEqual(done["status"], "error", code)
            self.assertIn("Refused", done["output"], code)
            self.assertSuggests(suggestion, done)
            self.assertEqual(ran, [], code)

    def test_pipes_chain_jobs_like_a_shell(self):
        done, ran = self.cell("job = await run('printf', 'b\\na\\nb\\n').pipe('sort').pipe('uniq', '-c')\n"
                              "(job.exit_code, job.tail().split(), job.pipeline.endswith(' | sort | uniq -c'))")
        self.assertEqual(done["value"], "(0, ['1', 'a', '2', 'b'], True)")
        self.assertEqual(ran[1:], ["sort", "uniq -c"])

    def test_a_pipe_carries_bytes_exactly_and_past_the_retention_cap(self):
        done, _ = self.cell(
            "import hashlib, sys\n"
            "blob = bytes(range(256)) * 20000\n"
            "writer = run(sys.executable, '-c', 'import sys; sys.stdout.buffer.write(bytes(range(256)) * 20000)')\n"
            "reader = await writer.pipe(sys.executable, '-c', 'import hashlib, sys; "
            "print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')\n"
            "reader.tail().strip() == hashlib.sha256(blob).hexdigest()")
        self.assertEqual(done["value"], "True")

    def test_late_pipe_preserves_non_utf8_bytes(self):
        done, _ = self.cell(
            "import sys\n"
            "writer = run(sys.executable, '-c', 'import sys; sys.stdout.buffer.write(bytes([0, 255, 254, 10]))')\n"
            "await writer\n"
            "reader = await run(sys.executable, '-c', 'import sys; print(list(sys.stdin.buffer.read()))', stdin=writer)\n"
            "reader.tail().strip()")
        self.assertEqual(done["value"], "'[0, 255, 254, 10]'")

    def test_a_reader_that_stops_ends_the_writer(self):
        done, _ = self.cell(
            "import asyncio\nwriter = run('yes')\nreader = await writer.pipe('head', '-2')\n"
            "await asyncio.wait_for(asyncio.shield(writer.task), 5)\n"
            "(reader.tail(), writer.exit_code != 0)")
        self.assertEqual(done["value"], "('y\\ny\\n', True)")

    def test_a_finished_job_feeds_what_it_retained(self):
        done, _ = self.cell("out = await run('printf', 'x\\ny\\n')\n(await run('wc', '-l', stdin=out)).tail().strip()")
        self.assertEqual(done["value"], "'2'")
        done, _ = self.cell("import sys\nbig = await run(sys.executable, '-c', 'print(\"x\" * 2000000)')\n"
                            "run('wc', '-c', stdin=big)")
        self.assertIn("pipe from it before it runs", done["output"])

    def test_cancelled_file_search_stops_its_internal_job(self):
        owner = Owner(["run", "files"])
        self.addCleanup(owner.close)
        owner.wait_for(lambda f: f.get("type") == "ready")
        # _run's internal shell is supervised but not a model-visible job.
        owner.send({"type": "execute", "id": "c1", "code":
                    "import asyncio\nfrom albedo_plugins import files as impl\n"
                    "async def wait_search():\n"
                    "    try: await impl._run('sleep 30')\n"
                    "    except asyncio.CancelledError: print('cancelled')\n"
                    "task = asyncio.create_task(wait_search())\nawait asyncio.sleep(.1)\n"
                    "task.cancel()\nawait task\n(len(impl.jobs.jobs), len(impl.jobs.active))"})
        done = owner.wait_for(lambda f: f.get("type") == "done" and f.get("id") == "c1")
        self.assertEqual(done["value"], "(0, 0)")
        self.assertIn("cancelled", done["output"])

    def test_a_library_the_cell_calls_may_still_spawn(self):
        done, _ = self.cell(
            "library = {}\n"
            "exec(compile('import subprocess\\ndef spawn(argv):\\n    return subprocess.run(argv, capture_output=True, text=True).stdout',"
            " 'fixture_library.py', 'exec'), library)\n"
            "library['spawn'](['echo', 'from a library'])")
        self.assertEqual(done["value"], "'from a library\\n'")


if __name__ == "__main__":
    unittest.main()
