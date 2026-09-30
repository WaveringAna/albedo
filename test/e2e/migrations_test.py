"""Owner-contributed schema and image migrations survive real startup and restarts.

Legacy ETF fixtures cannot be written by the current daemon. They are seeded
while the shared daemon is stopped, then exercised through its normal readers.
"""

import base64
import hashlib
import json
import sqlite3
import unittest

from harness import Albedo, Provider, exclusive, python, text


PNG = "iVBORw0KGgoAAAANSUhEUgAAAA0AAAAD"
# term_to_binary({1, {user_image, <<"legacy image">>, Image}}), where Image
# is the legacy {image, <<"image/png">>, Base64, 13, 3, 24} tuple.
LEGACY_TRANSCRIPT = base64.b64decode(
    "g2gCYQFoA3cKdXNlcl9pbWFnZW0AAAAMbGVnYWN5IGltYWdlaAZ3BWltYWdlbQAAAAlp"
    "bWFnZS9wbmdtAAAAIGlWQk9SdzBLR2dvQUFBQU5TVWhFVWdBQUFBMEFBQUFEYQ1hA2EY"
)
# A successful outcome before duration was added, carrying the same inline image.
LEGACY_CELL = base64.b64decode(
    "g2gCYQFoAncCb2toCHcHb3V0Y29tZW0AAAAObGVnYWN5LWNlbGwtMDB3CXN1Y2NlZWRl"
    "ZG0AAAANbGVnYWN5IG91dHB1dG0AAAAIJ2xlZ2FjeSd3BWZhbHNlbAAAAAFoBncFaW1h"
    "Z2VtAAAACWltYWdlL3BuZ20AAAAgaVZCT1J3MEtHZ29BQUFBTlNVaEVVZ0FBQUEwQUFB"
    "QURhDWEDYRhqag=="
)


def legacy_cell(cell_id):
    # Replace only this fixture's ETF binary field, including its length.
    original = b"legacy-cell-00"
    encoded = cell_id.encode()
    return LEGACY_CELL.replace(
        b"m" + len(original).to_bytes(4, "big") + original,
        b"m" + len(encoded).to_bytes(4, "big") + encoded,
    )


@exclusive
class MigrationsTest(unittest.TestCase):
    def test_installed_extensions_upgrade_legacy_tables_before_their_routes_run(self):
        provider = Provider(
            lambda request: python(
                "items = await work.list()\n"
                "assert not items\n"
                "item = await work.create('new scoped item')\n"
                "assert (await work.get(item.id)).title == 'new scoped item'\n"
                "legacy = [v for v in await vents() if v['message'] == 'legacy vent']\n"
                "assert len(legacy) == 1 and legacy[0]['title'] == ''\n"
                "await vent('bug', 'new vent', title='new title')\n"
                "assert any(v['title'] == 'new title' for v in await vents())\n"
                "print('upgraded extension routes usable')"
            )
            if request["messages"][-1].get("role") == "user"
            else text("done")
        )
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            session = app.session()
            database = app.home / "albedo.sqlite"
            previous_cwds, previous_titles = [], []
            legacy_work = None

            def prepare(_app):
                nonlocal legacy_work
                with sqlite3.connect(database) as db:
                    previous_cwds.extend(db.execute("SELECT cwd,id FROM work"))
                    previous_titles.extend(
                        db.execute("SELECT title,id FROM paperclips")
                    )
                    db.execute("DROP INDEX work_cwd_id")
                    db.execute("ALTER TABLE work DROP COLUMN cwd")
                    db.execute("ALTER TABLE paperclips DROP COLUMN title")
                    legacy_work = db.execute(
                        "INSERT INTO work(title) VALUES('legacy isolated item')"
                    ).lastrowid
                    db.execute(
                        "INSERT INTO paperclips(topic,message,cwd) VALUES('bug','legacy vent',?)",
                        (str(app.workspace),),
                    )
                settings_path = app.home / "extensions.json"
                settings = json.loads(settings_path.read_text())
                settings.setdefault("enabled", {}).update(work=False, paperclips=False)
                settings_path.write_text(json.dumps(settings))

            def restore(_app):
                with sqlite3.connect(database) as db:
                    db.executemany("UPDATE work SET cwd=? WHERE id=?", previous_cwds)
                    db.executemany(
                        "UPDATE paperclips SET title=? WHERE id=?", previous_titles
                    )

            try:
                app.restart(prepare=prepare)
                # Installed storage still upgrades when its routes are disabled.
                with sqlite3.connect(database) as db:
                    self.assertEqual(
                        db.execute(
                            "SELECT cwd FROM work WHERE id=?", (legacy_work,)
                        ).fetchone(),
                        ("__albedo_legacy__",),
                    )
                    self.assertIsNotNone(
                        db.execute(
                            "SELECT name FROM sqlite_master WHERE name='work_cwd_id' AND type='index'"
                        ).fetchone()
                    )
                for name in ("work", "paperclips"):
                    app.api(
                        f"/sessions/{session}/extensions",
                        {"name": name, "enabled": True},
                    ).close()
                app.restart()
                app.prompt(session, "use the upgraded extension ledgers").close()
                app.idle(session)
                results = [
                    json.loads(event["result"])
                    for event in app.events(session)
                    if event.get("type") == "tool" and event.get("name") == "python"
                ]
                self.assertEqual(len(results), 1)
                self.assertEqual(results[0]["status"], "ok", results[0])
                self.assertIn("upgraded extension routes usable", results[0]["output"])
            finally:
                # Restore other fixtures' fields erased by the legacy schema seed.
                app.restart(prepare=restore)

    def test_startup_migrates_legacy_images_once_with_a_consistent_backup(self):
        probe = ""

        def reply(request):
            if request["messages"][-1].get("role") == "user" and probe:
                return python(probe)
            return text("done")

        provider = Provider(reply)
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            session = app.session()
            database = app.home / "albedo.sqlite"
            image_hash = hashlib.sha256(PNG.encode()).hexdigest()
            cell_ids = [f"{session}-legacy-{n}" for n in range(20)]
            seqs = []
            backups_before = set(
                app.home.glob("backups/albedo-before-image-store-*.sqlite")
            )

            def prepare(_app):
                with sqlite3.connect(database) as db:
                    db.execute(
                        "DELETE FROM migrations WHERE name IN ('image_store','cell_images')"
                    )
                    db.execute(
                        "INSERT INTO images(hash,data) VALUES(?,?) "
                        "ON CONFLICT(hash) DO UPDATE SET data=excluded.data",
                        (image_hash, PNG),
                    )
                    for _ in range(20):
                        row = db.execute(
                            "INSERT INTO transcript(session,payload) VALUES(?,?)",
                            (session, LEGACY_TRANSCRIPT),
                        )
                        seqs.append(row.lastrowid)
                    for cell_id in cell_ids:
                        db.execute(
                            "INSERT INTO cells(id,session,source,status,started,payload) "
                            "VALUES(?,?,'legacy source','finished',1,?)",
                            (cell_id, session, legacy_cell(cell_id)),
                        )

            app.restart(prepare=prepare)
            backups = set(app.home.glob("backups/albedo-before-image-store-*.sqlite"))
            created = backups - backups_before
            self.assertEqual(len(created), 1)
            with sqlite3.connect(next(iter(created))) as backup:
                self.assertEqual(
                    backup.execute("PRAGMA integrity_check").fetchone()[0], "ok"
                )
                self.assertEqual(
                    backup.execute(
                        "SELECT data,typeof(data) FROM images WHERE hash=?",
                        (image_hash,),
                    ).fetchone(),
                    (PNG, "text"),
                )
                self.assertEqual(
                    backup.execute(
                        "SELECT payload FROM transcript WHERE seq=?", (seqs[0],)
                    ).fetchone()[0],
                    LEGACY_TRANSCRIPT,
                )
                self.assertEqual(
                    backup.execute(
                        "SELECT payload FROM cells WHERE id=?", (cell_ids[0],)
                    ).fetchone()[0],
                    legacy_cell(cell_ids[0]),
                )

            def migrated_state():
                with sqlite3.connect(database) as db:
                    self.assertEqual(
                        db.execute("PRAGMA integrity_check").fetchone()[0], "ok"
                    )
                    self.assertEqual(
                        db.execute("PRAGMA foreign_key_check").fetchall(), []
                    )
                    self.assertEqual(
                        db.execute(
                            "SELECT data,typeof(data) FROM images WHERE hash=?",
                            (image_hash,),
                        ).fetchone(),
                        (base64.b64decode(PNG), "blob"),
                    )
                    transcript = db.execute(
                        "SELECT seq,payload FROM transcript WHERE session=? ORDER BY seq",
                        (session,),
                    ).fetchall()
                    self.assertEqual([row[0] for row in transcript], seqs)
                    cells = db.execute(
                        "SELECT id,source,payload FROM cells WHERE session=? ORDER BY id",
                        (session,),
                    ).fetchall()
                    self.assertEqual([row[0] for row in cells], sorted(cell_ids))
                    self.assertTrue(all(row[1] == "legacy source" for row in cells))
                    for payload in [row[1] for row in transcript] + [
                        row[2] for row in cells
                    ]:
                        self.assertNotIn(PNG.encode(), payload)
                        self.assertIn(image_hash.encode(), payload)
                    markers = db.execute(
                        "SELECT name,applied_at FROM migrations "
                        "WHERE name IN ('image_store','cell_images') ORDER BY name"
                    ).fetchall()
                    self.assertEqual(
                        [row[0] for row in markers], ["cell_images", "image_store"]
                    )
                    return transcript, cells, markers

            first = migrated_state()
            app.restart()
            self.assertEqual(migrated_state(), first)
            self.assertEqual(
                set(app.home.glob("backups/albedo-before-image-store-*.sqlite")),
                backups,
            )
            # A normal provider request resolves the migrated transcript images.
            probe = (
                f"info = await cells.info({cell_ids[0]!r})\n"
                "assert info['status'] == 'ok' and info['started']\n"
                "assert info['duration'] is None\n"
                f"assert 'legacy source' in await cells.read({cell_ids[0]!r})\n"
                "print('legacy cell readable')"
            )
            app.prompt(session, "read the migrated history and cell").close()
            app.idle(session)
            serialized = json.dumps(provider.requests[-1]["request"])
            self.assertIn("legacy image", serialized)
            self.assertIn(PNG, serialized)
            self.assertIn("legacy cell readable", serialized)


if __name__ == "__main__":
    unittest.main()
