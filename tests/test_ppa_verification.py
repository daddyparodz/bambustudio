"""Regression checks for Launchpad post-build status and source publication gates."""
import datetime as dt
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
VERIFIER = ROOT / "scripts" / "verify-ppa-release.sh"

FAKE_LAUNCHPAD = """
import os
from types import SimpleNamespace

class Publication:
    def __init__(self):
        self.source_package_version = os.environ["FAKE_EXPECTED_VERSION"]
        self.status = os.environ["FAKE_SOURCE_STATUS"]

    def getBuilds(self):
        return [
            SimpleNamespace(buildstate=state)
            for state in os.environ["FAKE_BUILD_STATES"].split("|")
            if state
        ]

class Archive:
    def getPublishedSources(self, status, **kwargs):
        if status == os.environ["FAKE_SOURCE_STATUS"]:
            return [Publication()]
        return []

class Person:
    def getPPAByName(self, **kwargs):
        return Archive()

class People:
    def __getitem__(self, key):
        return Person()

class Ubuntu:
    def getSeries(self, **kwargs):
        return object()

class Distributions:
    def __getitem__(self, key):
        return Ubuntu()

class Launchpad:
    @staticmethod
    def login_anonymously(*args, **kwargs):
        return SimpleNamespace(people=People(), distributions=Distributions())
"""


class VerifyPPABuildStateTests(unittest.TestCase):
    def test_postbuild_states_do_not_become_terminal_at_generic_deadline(self):
        cases = [
            ("Published", "Uploading build", "pending"),
            ("Published", "Gathering build output", "pending"),
            ("Published", "Failed to upload", "failed"),
            ("Published", "Currently building", "failed"),
            ("Published", "Successfully built", "success"),
            ("Pending", "Successfully built", "pending"),
            ("Published", "Uploading build|Failed to upload", "failed"),
        ]
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            fake = directory / "fake" / "launchpadlib"
            fake.mkdir(parents=True)
            (fake / "__init__.py").write_text("", encoding="utf-8")
            (fake / "launchpad.py").write_text(
                textwrap.dedent(FAKE_LAUNCHPAD), encoding="utf-8"
            )

            version = "01.02.03+jammy-0ppa1~22.04.1"
            manifest = {
                "schema": 1,
                "channel": "stable",
                "package": "bambustudio",
                "tag": "v01.02.03",
                "commit": "deadbeef",
                "revision": 1,
                "created_at": (
                    dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=4)
                ).isoformat(),
                "status": "pending",
                "sources": [{"series": "jammy", "version": version}],
            }
            manifest_path = directory / "pending.json"
            result_path = directory / "result.json"
            manifest_path.write_text(
                json.dumps(manifest) + "\n", encoding="utf-8"
            )

            for source_status, build_states, expected in cases:
                with self.subTest(
                    source_status=source_status, build_states=build_states
                ):
                    environment = dict(os.environ)
                    environment.update({
                        "PYTHONPATH": str(fake.parent),
                        "FAKE_EXPECTED_VERSION": version,
                        "FAKE_SOURCE_STATUS": source_status,
                        "FAKE_BUILD_STATES": build_states,
                    })
                    result = subprocess.run(
                        [
                            "bash", str(VERIFIER), "--manifest", str(manifest_path),
                            "--result-json", str(result_path),
                        ],
                        cwd=ROOT, env=environment, capture_output=True,
                        text=True, timeout=15,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    payload = json.loads(
                        result_path.read_text(encoding="utf-8")
                    )
                    self.assertEqual(
                        payload["status"], expected,
                        (result.stdout, payload),
                    )
                    self.assertEqual(
                        payload["sources"][0]["source_status"],
                        source_status,
                    )


if __name__ == "__main__":
    unittest.main()
