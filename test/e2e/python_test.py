"""File editing, search, and cell timing are exercised through the daemon's real Python tool."""

import json
import unittest

from harness import Albedo, Provider, Reply, python, text


class PythonToolsTests(unittest.TestCase):
    def setUp(self):
        self.arguments = None

        def script(request):
            if request["messages"][-1].get("role") == "user":
                if self.arguments is not None:
                    return Reply("python", tool_arguments=self.arguments)
                return python(self.code)
            return text("done")

        self.provider = Provider(script)
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider)
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)

    def run_cell(self, code, session):
        """The result of one prompt's cell, the latest in the session."""
        self.code = code
        self.app.prompt(session, "use the Python tools").close()
        self.app.idle(session)
        results = [
            json.loads(part["value"])
            for entry in self.app.history(session)["items"]
            if entry["kind"] == "tool_result" and entry["tool"]["name"] == "python"
            for part in entry["content"]
            if part["kind"] == "json" and part["field"] == "result"
        ]
        self.assertEqual(results[-1]["status"], "ok", results[-1])
        return results[-1]

    def execute(self, code):
        return self.run_cell(code, self.app.session())["output"]

    def test_deleting_shadowed_tools_recovers_the_original_bindings(self):
        (self.app.workspace / "note.txt").write_text("recovered\n")
        session = self.app.session()
        output = self.run_cell(
            "original_tools = (files, run, jobs, cells, output, show_image)\n"
            "files, run, jobs, cells, output, show_image = range(6)\n"
            "assert (files, run, jobs, cells, output, show_image) == tuple(range(6))\n"
            "del files, run, jobs, cells, output, show_image\n"
            "assert (files, run, jobs, cells, output, show_image) == original_tools\n"
            "def recovered_read():\n    return files.read('note.txt')\n"
            "print(recovered_read())",
            session,
        )["output"]
        self.assertIn("recovered", output)
        output = self.run_cell(
            "assert (files, run, jobs, cells, output, show_image) == original_tools\n"
            "print(recovered_read())\n"
            "import builtins\nassert not hasattr(builtins, 'files')",
            session,
        )["output"]
        self.assertIn("recovered", output)

    def test_ambiguous_edit_requires_a_hint_and_preserves_other_matches(self):
        note = self.app.workspace / "note.txt"
        note.write_text("same\nother\nsame\n")
        output = self.execute(
            "try:\n    files.edit('note.txt', 'same', 'changed')\n"
            "except Exception as exc:\n    print('ambiguous:', exc)\n"
            "files.edit('note.txt', 'same', 'changed', line_hint=3)\n"
            "print(files.read('note.txt'))"
        )
        self.assertEqual(note.read_text(), "same\nother\nchanged\n")
        self.assertIn("ambiguous:", output)
        self.assertIn("same", output)
        self.assertIn("changed", output)

    def test_an_edit_miss_says_when_only_whitespace_differs(self):
        (self.app.workspace / "note.txt").write_text("if ok:\n    run()\n")
        output = self.execute(
            "for old in ('if ok:\\n\\trun()', 'absent'):\n"
            "    try:\n        files.edit('note.txt', old, 'x')\n"
            "    except ValueError as error:\n        print(str(error).splitlines()[0])"
        )
        lines = output.splitlines()
        self.assertIn("whitespace differs", lines[0])
        self.assertNotIn("whitespace differs", lines[1])

    def test_find_searches_workspace_and_returns_context(self):
        (self.app.workspace / "note.txt").write_text("before\nneedle\nafter\n")
        output = self.execute(
            "rows = await files.find('needle', '.', context=1)\n"
            "print(rows)\nprint(files.read('note.txt', start_line=2, end_line=2))"
        )
        self.assertIn("note.txt", output)
        self.assertIn("needle", output)
        self.assertIn("before", output)
        self.assertIn("after", output)

    def test_an_empty_find_says_what_was_searched_and_skipped(self):
        (self.app.workspace / ".ignore").write_text("ignored.txt\n")
        (self.app.workspace / "ignored.txt").write_text("needle\n")
        (self.app.workspace / ".dot.txt").write_text("needle\n")
        (self.app.workspace / "plain.txt").write_text("nothing\n")
        output = self.execute(
            "print(await files.find('needle', '.'))\n"
            "print(await files.find('needle', '.', hidden=True, ignored=True))"
        )
        self.assertIn("no matches for 'needle'", output)
        self.assertIn("1 files searched", output)
        self.assertIn("skipped hidden files, .gitignore/.ignore rules", output)
        self.assertIn("ignored.txt", output)
        self.assertIn("rerun with hidden=True and/or ignored=True", output)
        self.assertEqual(output.count("no matches"), 1, output)

    def test_find_in_a_missing_root_raises_instead_of_returning_nothing(self):
        output = self.execute(
            "try:\n    await files.find('needle', 'nowhere')\n"
            "except FileNotFoundError as exc:\n    print('missing:', exc)"
        )
        self.assertIn("missing: nowhere not found", output)

    def test_a_file_result_is_awaitable_and_offers_content_and_text(self):
        (self.app.workspace / "note.txt").write_text("hello\n")
        output = self.execute(
            "text = await files.read('note.txt')\n"
            "print('awaited:', text.strip())\n"
            "print('content:', (await files.read('note.txt')).content.strip())\n"
            "print('text:', files.read('note.txt').text.strip())"
        )
        self.assertIn("awaited: 1 | hello", output)
        self.assertIn("content: 1 | hello", output)
        self.assertIn("text: 1 | hello", output)

    def test_paths_searches_a_list_of_directories_with_a_list_of_globs(self):
        for directory, name in [("a", "one.md"), ("b", "two.txt"), ("c", "three.md")]:
            (self.app.workspace / directory).mkdir()
            (self.app.workspace / directory / name).write_text("x")
        output = self.execute(
            "rows = await files.paths(None, ['a', 'b'], glob=['*.md', '*.txt'])\n"
            "print(sorted(str(row) for row in rows))"
        )
        self.assertIn("one.md", output)
        self.assertIn("two.txt", output)
        self.assertNotIn("three.md", output)

    def test_paths_globs_a_path_from_the_workspace_root(self):
        (self.app.workspace / "src" / "deep").mkdir(parents=True)
        (self.app.workspace / "src" / "deep" / "stream_test.go").write_text("x")
        output = self.execute(
            "print([str(row) for row in await files.paths('src/*/*_test.go')])\n"
            "print([str(row) for row in await files.paths('./src/*/*_test.go')])"
        )
        self.assertEqual(output.count("['src/deep/stream_test.go']"), 2, output)

    def test_file_reads_decode_complete_lines_across_chunk_boundaries(self):
        fixtures = [
            (b"", []),
            (b"\n\n", ["", ""]),
            (b"a\r\r\n", ["a", ""]),
            (b"a\n", ["a"]),
            (b"a\nlast", ["a", "last"]),
            (
                "a\nb\rc\r\nd\ve\ff\x1cg\x1dh\x1ei\x85j\u2028k\u2029last".encode(),
                list("abcdefghijk") + ["last"],
            ),
            (b"a\xffb\xe2\x82", ["a\ufffdb\ufffd"]),
        ]
        for padding in (65_534, 65_535, 65_536):
            prefix = b"x" * padding
            for separator in (
                b"\r\n",
                "\x85".encode(),
                "\u2028".encode(),
                "\u2029".encode(),
            ):
                fixtures.append((prefix + separator + b"tail", ["x" * padding, "tail"]))
            fixtures.append((prefix + "é\n尾".encode(), ["x" * padding + "é", "尾"]))
            fixtures.append(
                (
                    prefix + b"\xe2\x82\nend\xe2\x82",
                    ["x" * padding + "\ufffd", "end\ufffd"],
                )
            )
        for index, (data, _lines) in enumerate(fixtures):
            (self.app.workspace / f"decode-{index}.txt").write_bytes(data)
        # Keep large expected lines inside the kernel, out of the tool output.
        small_expected = [lines for _data, lines in fixtures[:7]]
        output = self.execute(
            f"expected = {small_expected!r}\n"
            "for padding in (65534, 65535, 65536):\n"
            "    expected.extend([['x' * padding, 'tail']] * 4)\n"
            "    expected.append(['x' * padding + 'é', '尾'])\n"
            "    expected.append(['x' * padding + '\ufffd', 'end\ufffd'])\n"
            "for index, lines in enumerate(expected):\n"
            "    result = files.read(f'decode-{index}.txt', max_chars=200000)\n"
            "    numbered = '\\n'.join(f'{number:>6} | {line}' for number, line in enumerate(lines, 1))\n"
            "    if lines:\n"
            "        assert result == numbered, (index, len(result), len(numbered))\n"
            "    else:\n"
            "        assert ' | ' not in result\n"
            "        assert all(detail in result for detail in ('decode-0.txt', '0 lines', 'line 1'))\n"
            "print('decoded complete lines')"
        )
        self.assertEqual(output.strip(), "decoded complete lines")

    def test_file_reads_enforce_budgets_and_character_limit_precedence(self):
        (self.app.workspace / "budget.txt").write_text("a\nbb\nc\nd\n")
        (self.app.workspace / "numbered.txt").write_text("\n" * 999_999 + "x\nz")
        output = self.execute(
            "first = '     1 | a'\n"
            "second = '     2 | bb'\n"
            "both = first + '\\n' + second\n"
            "assert files.read('budget.txt', end_line=2, max_chars=23) == both\n"
            "assert files.read('budget.txt', end_line=1, max_chars=11) == first\n"
            "rejected = files.read('budget.txt', max_chars=10)\n"
            "assert ' | ' not in rejected\n"
            "assert all(detail in rejected for detail in ('line 1', '10 characters', 'max_chars=10', 'start_line=1', 'end_line=1', 'max_chars=11'))\n"
            "for budget, shown, unshown, resume in ((22, [first], 'lines 2-4', 2), (23, [first, second], 'lines 3-4', 3)):\n"
            "    result = files.read('budget.txt', max_chars=budget).splitlines()\n"
            "    assert result[:-1] == shown\n"
            "    assert all(detail in result[-1] for detail in (f'max_chars={budget}', unshown, f'start_line={resume}'))\n"
            "result = files.read('budget.txt', limit=2, max_chars=23).splitlines()\n"
            "assert result[:-1] == [first, second]\n"
            "assert all(detail in result[-1] for detail in ('limit=2', '2 more through line 4', 'start_line=3'))\n"
            "result = files.read('budget.txt', limit=3, max_chars=23).splitlines()\n"
            "assert result[:-1] == [first, second]\n"
            "assert all(detail in result[-1] for detail in ('max_chars=23', 'lines 3-3', 'start_line=3'))\n"
            "assert 'limit=' not in result[-1]\n"
            "assert files.read('numbered.txt', start_line=1000000, end_line=1000000, max_chars=12) == '1000000 | x'\n"
            "rejected = files.read('numbered.txt', start_line=1000000, end_line=1000000, max_chars=11)\n"
            "assert ' | ' not in rejected\n"
            "assert all(detail in rejected for detail in ('line 1000000', '11 characters', 'max_chars=11', 'start_line=1000000', 'end_line=1000000', 'max_chars=12'))\n"
            "print('budgets and numbering checked')"
        )
        self.assertEqual(output.strip(), "budgets and numbering checked")

    def test_file_reads_count_requested_windows_and_eof_exactly(self):
        (self.app.workspace / "window.txt").write_text("a\nb\nc\nd")
        pattern = "a\r\nb\rc\nd\ve\ff\x1cg\x1dh\x1ei\x85j\u2028k\u2029last\n".encode()
        (self.app.workspace / "bulk.txt").write_bytes(
            b"head\r\n" + pattern * 10_000 + b"tail\xe2\x82"
        )
        output = self.execute(
            "assert files.read('window.txt', start_line=2, end_line=3) == '     2 | b\\n     3 | c'\n"
            "assert files.read('window.txt', start_line=3, end_line=99) == '     3 | c\\n     4 | d'\n"
            "for options, row, remaining, last, resume in (({'start_line': 2}, '     2 | b', 2, 4, 3), ({'start_line': 2, 'end_line': 3}, '     2 | b', 1, 3, 3), ({'start_line': 3, 'end_line': 99}, '     3 | c', 1, 4, 4)):\n"
            "    result = files.read('window.txt', limit=1, **options).splitlines()\n"
            "    assert result[:-1] == [row]\n"
            "    assert all(detail in result[-1] for detail in ('limit=1', f'{remaining} more through line {last}', f'start_line={resume}'))\n"
            "assert files.read('window.txt', start_line=4, limit=1) == '     4 | d'\n"
            "empty = files.read('window.txt', start_line=5, end_line=99)\n"
            "assert all(detail in empty for detail in ('window.txt', '4 lines', 'line 5'))\n"
            "assert ' | ' not in empty\n"
            "result = files.read('bulk.txt', start_line=2, limit=1).splitlines()\n"
            "assert result[:-1] == ['     2 | a']\n"
            "assert all(detail in result[-1] for detail in ('limit=1', '120000 more through line 120002', 'start_line=3'))\n"
            "result = files.read('bulk.txt', start_line=2, end_line=100000, limit=1).splitlines()\n"
            "assert result[:-1] == ['     2 | a']\n"
            "assert all(detail in result[-1] for detail in ('limit=1', '99998 more through line 100000', 'start_line=3'))\n"
            "result = files.read('bulk.txt', start_line=120001, limit=1).splitlines()\n"
            "assert result[:-1] == ['120001 | last']\n"
            "assert all(detail in result[-1] for detail in ('limit=1', '1 more through line 120002', 'start_line=120002'))\n"
            "assert files.read('bulk.txt', start_line=120001, end_line=120001) == '120001 | last'\n"
            "assert files.read('bulk.txt', start_line=120002) == '120002 | tail\\ufffd'\n"
            "print('window counts checked')"
        )
        self.assertEqual(output.strip(), "window counts checked")

    def test_file_reads_count_giant_lines_without_shortening_them(self):
        (self.app.workspace / "giant.txt").write_text(
            "head\n" + "x" * 1_048_576 + "\ntail\n"
        )
        (self.app.workspace / "unicode.txt").write_text("é" * 110_000)
        output = self.execute(
            "assert files.read('giant.txt', start_line=3) == '     3 | tail'\n"
            "assert files.read('giant.txt', end_line=1) == '     1 | head'\n"
            "rejected = files.read('giant.txt', start_line=2, end_line=2)\n"
            "assert ' | ' not in rejected\n"
            "assert all(detail in rejected for detail in ('line 2', '1048585 characters', 'max_chars=16000', '200000'))\n"
            "assert 'max_chars=1048586' not in rejected\n"
            "result = files.read('giant.txt', max_chars=32).splitlines()\n"
            "assert result[:-1] == ['     1 | head']\n"
            "assert all(detail in result[-1] for detail in ('max_chars=32', 'lines 2-3', 'start_line=2'))\n"
            "result = files.read('giant.txt', limit=1).splitlines()\n"
            "assert result[:-1] == ['     1 | head']\n"
            "assert all(detail in result[-1] for detail in ('limit=1', '2 more through line 3', 'start_line=2'))\n"
            "for budget in (16000, 110009):\n"
            "    rejected = files.read('unicode.txt', max_chars=budget)\n"
            "    assert ' | ' not in rejected\n"
            "    assert all(detail in rejected for detail in ('line 1', '110009 characters', f'max_chars={budget}', 'start_line=1', 'end_line=1', 'max_chars=110010'))\n"
            "assert files.read('unicode.txt', max_chars=110010) == '     1 | ' + 'é' * 110000\n"
            "print('giant lines counted and returned intact')"
        )
        self.assertEqual(output.strip(), "giant lines counted and returned intact")

    def test_file_reads_validate_ranges_before_opening_and_report_path_errors(self):
        output = self.execute(
            "for options in ({'start_line': 0}, {'start_line': 2, 'end_line': 1}, {'limit': 0}, {'max_chars': 0}, {'max_chars': 200001}):\n"
            "    try:\n"
            "        files.read('absent.txt', **options)\n"
            "    except ValueError:\n"
            "        pass\n"
            "    else:\n"
            "        raise AssertionError(options)\n"
            "try:\n"
            "    files.read('absent.txt')\n"
            "except FileNotFoundError as error:\n"
            "    assert 'absent.txt' in str(error)\n"
            "else:\n"
            "    raise AssertionError('missing file accepted')\n"
            "try:\n"
            "    files.read('.')\n"
            "except IsADirectoryError as error:\n"
            "    assert \"files.ls('.')\" in str(error)\n"
            "else:\n"
            "    raise AssertionError('directory accepted')\n"
            "print('range and path errors preserved')"
        )
        self.assertEqual(output.strip(), "range and path errors preserved")

    def test_cells_get_the_api_a_model_reaches_for(self):
        output = self.execute(
            "job = run('echo', 'hello')\n"
            "await job\n"
            "assert (await job.tail()).strip() == 'hello'\n"
            "assert (await job.head(lines=1)).strip() == 'hello'\n"
            "assert output.read(job.id, 0, 3) == 'hel'\n"
            "try:\n"
            "    output.read(job.id, limit=10**7)\n"
            "except ValueError as error:\n"
            "    assert 'offset=' in str(error), error\n"
            "else:\n"
            "    raise AssertionError('over-cap limit shortened silently')\n"
            "from albedo import files as imported\n"
            "assert imported is files\n"
            "assert re.fullmatch('a+', 'aa') and Path('.').is_dir()\n"
            "assert hashlib.md5(b'').hexdigest() and json.dumps(os.sep)\n"
            "try:\n"
            "    run('true', timeout=120000)\n"
            "except ValueError as error:\n"
            "    assert 'seconds' in str(error) and 'milliseconds' in str(error), error\n"
            "try:\n"
            "    time.sleep(2)\n"
            "except PermissionError as error:\n"
            "    assert 'run()' in str(error) and 'asyncio.sleep' in str(error), error\n"
            "time.sleep(0.01)\n"
            "await asyncio.sleep(0.01)\n"
            "print('api shapes ok')"
        )
        self.assertEqual(output.strip(), "api shapes ok")

    def test_a_cell_reports_how_long_it_ran(self):
        session = self.app.session()
        slept = self.run_cell("import asyncio\nawait asyncio.sleep(0.3)", session)
        self.assertGreaterEqual(slept["duration"], 0.3)
        self.assertLess(slept["duration"], 5)
        # The journal keeps it, so cells.info reports it after the fact.
        info = self.run_cell(
            f"print((await cells.info({slept['cell_id']!r}))['duration'])", session
        )
        self.assertEqual(float(info["output"]), slept["duration"])

    def call(self, arguments, session):
        """The result of one python call made with exactly these arguments."""
        self.arguments = arguments
        self.app.prompt(session, "call the Python tool").close()
        self.app.idle(session)
        self.arguments = None
        return [
            json.loads(part["value"])
            for entry in self.app.history(session)["items"]
            if entry["kind"] == "tool_result" and entry["tool"]["name"] == "python"
            for part in entry["content"]
            if part["kind"] == "json" and part["field"] == "result"
        ][-1]

    def test_timeout_is_optional(self):
        result = self.call({"code": "print('no timeout')"}, self.app.session())
        self.assertEqual(result["status"], "ok", result)
        self.assertEqual(result["output"].strip(), "no timeout")

    def test_an_unusable_timeout_keeps_the_code_for_a_rerun(self):
        session = self.app.session()
        rejected = self.call(
            {"code": "open('made.txt', 'w').write('hi')", "timeout_ms": "soon"},
            session,
        )
        self.assertIn("timeout_ms", rejected["error"])
        self.assertFalse((self.app.workspace / "made.txt").exists())
        self.run_cell(f"await cells.run({rejected['cell_id']!r})", session)
        self.assertEqual((self.app.workspace / "made.txt").read_text(), "hi")
