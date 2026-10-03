"""Sessions at remote locations: `[user@]host:/abs/path` workspaces.

A remote location is a stored key the daemon parses and labels without
connecting to the host. These cover what a client sees: the canonical
spelling and parsed `location`, the host label's `user@` elision against
`ssh -G`, rejected forms, and moving between local and remote. What needs
the host itself (kernels, `~`, folders, project files) is
remote_kernels_test.py, over a loopback ssh.
"""

import json
import shutil
import subprocess
import unittest
import urllib.error
import urllib.parse

from harness import Albedo, exclusive, operation_id

HOST = "albedo-e2e-nowhere"


def ssh_user(host):
    """The user ssh would pick for `host`, or None without ssh."""
    if shutil.which("ssh") is None:
        return None
    output = subprocess.run(
        ["ssh", "-G", host], capture_output=True, text=True, check=True
    ).stdout
    return next(
        line.split(" ", 1)[1]
        for line in output.splitlines()
        if line.startswith("user ")
    )


class LocationsTest(unittest.TestCase):
    def setUp(self):
        self.app = Albedo().__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)

    def api(self, path, body=None, **options):
        with self.app.api(path, body, **options) as response:
            return json.load(response)

    def failure(self, path, body=None, **options):
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.api(path, body, **options)
        return caught.exception.code, json.load(caught.exception)["detail"]

    def create(self, workspace):
        return self.api(
            f"/sessions/{operation_id()}",
            {
                "kind": "new",
                "workspace": workspace,
                "provider_profile": self.app.profile,
            },
            method="PUT",
            headers={"If-None-Match": "*"},
        )

    def move(self, session, workspace):
        snapshot = self.api(f"/sessions/{session}?tail=0")
        resource = snapshot["configuration_resource"]
        return self.api(
            resource["url"],
            {"workspace": workspace, "family_revision": snapshot["family_revision"]},
            method="PATCH",
            headers={"If-Match": resource["etag"]},
        )["session"]

    def test_remote_workspace_is_stored_canonically_with_its_location(self):
        created = self.create(f"mayer@{HOST}:/home/mayer//proj/./albedo/")
        canonical = f"mayer@{HOST}:/home/mayer/proj/albedo"
        self.assertEqual(created["workspace"], canonical)
        location = created["location"]
        self.assertEqual(
            (location["host"], location["user"], location["path"]),
            (HOST, "mayer", "/home/mayer/proj/albedo"),
        )
        query = urllib.parse.urlencode({"workspace": canonical})
        listed = next(
            s
            for s in self.api("/sessions?" + query)["items"]
            if s["id"] == created["id"]
        )
        self.assertEqual(listed["workspace"], canonical)

        local = self.create(str(self.app.workspace))
        self.assertEqual(local["workspace"], str(self.app.workspace))
        self.assertEqual(
            local["location"],
            {
                "host": None,
                "user": None,
                "path": str(self.app.workspace),
                "label": None,
            },
        )

    def test_host_label_drops_the_user_ssh_would_pick_anyway(self):
        self.assertEqual(self.create(f"{HOST}:/srv")["location"]["label"], HOST)
        other = "someone-else"
        self.assertEqual(
            self.create(f"{other}@{HOST}:/srv")["location"]["label"],
            f"{other}@{HOST}",
        )
        default = ssh_user(HOST)
        if default is None:
            self.skipTest("ssh is not installed: the label keeps any user")
        self.assertEqual(
            self.create(f"{default}@{HOST}:/srv")["location"]["label"], HOST
        )

    # `albedo new` takes the active profile, which other tests on the shared
    # daemon rewrite; a daemon of its own keeps that profile this fixture's.
    # exclusive: CLI new depends on the active provider profile other fixtures rewrite
    @exclusive
    def test_the_cli_starts_a_remote_session_without_resolving_it_locally(self):
        session = json.loads(self.app.cli("new", f"{HOST}:/srv/cli"))["session"]
        listed = next(s for s in self.api("/sessions")["items"] if s["id"] == session)
        self.assertEqual(listed["workspace"], f"{HOST}:/srv/cli")

    def test_unusable_locations_are_rejected(self):
        for workspace, said in (
            (f"{HOST}:proj", "must be absolute"),
            (f"{HOST}:", "must be absolute"),
            ("-oProxyCommand=touch:/tmp", "not a valid host"),
            (f"-l@{HOST}:/srv", "not a valid user"),
            ("relative/path", "absolute path or host:/absolute/path"),
            ("dir/with:colon", "absolute path or host:/absolute/path"),
        ):
            with self.subTest(workspace=workspace):
                status, message = self.failure(
                    f"/sessions/{operation_id()}",
                    {
                        "kind": "new",
                        "workspace": workspace,
                        "provider_profile": self.app.profile,
                    },
                    method="PUT",
                    headers={"If-None-Match": "*"},
                )
                self.assertEqual(status, 400)
                self.assertIn(said, message)

    def test_a_session_moves_to_a_remote_location_and_back(self):
        session = self.app.session()
        moved = self.move(session, f"{HOST}:/srv//app/")
        self.assertEqual(moved["workspace"], f"{HOST}:/srv/app")
        self.assertEqual(moved["location"]["host"], HOST)
        with self.assertRaises(urllib.error.HTTPError) as invalid:
            self.move(session, f"{HOST}:app")
        self.assertEqual(invalid.exception.code, 400)
        self.assertIn("must be absolute", json.load(invalid.exception)["detail"])
        back = self.move(session, str(self.app.workspace))
        self.assertEqual(back["workspace"], str(self.app.workspace))
        self.assertIsNone(back["location"]["host"])


if __name__ == "__main__":
    unittest.main()
