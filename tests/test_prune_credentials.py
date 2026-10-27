"""Offline tests of the credential resolver extracted from the shipped script.

No Launchpad code or credential-bearing application entrypoint is executed.
"""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "prune-ppa.sh"
BASH = "C:/Program Files/Git/bin/bash.exe" if os.name == "nt" else "bash"


class CredentialResolutionTests(unittest.TestCase):
    def setUp(self):
        self.fixture = tempfile.TemporaryDirectory()
        self.addCleanup(self.fixture.cleanup)
        self.home = Path(self.fixture.name)
        self.env = os.environ.copy()
        for name in ("LAUNCHPAD_CREDENTIALS", "LAUNCHPAD_CREDENTIALS_FILE",
                     "LAUNCHPAD_OAUTH_CREDENTIALS_FILE"):
            self.env.pop(name, None)
        self.env.update(HOME=self.home.as_posix(), TMPDIR=self.home.as_posix())
        script = SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"^resolve_credentials_file\(\) \{\n.*?^\}", script, re.M | re.S
        )
        self.assertIsNotNone(match, "The shipped credential resolver must exist")
        assert match is not None
        self.resolver = match.group(0)

    def resolve(self, **settings):
        return subprocess.run(
            [BASH, "--noprofile", "--norc", "-c",
             self.resolver + "\nresolve_credentials_file"],
            env=dict(self.env, **settings), capture_output=True, text=True,
            timeout=10,
        )

    def test_unconfigured_credentials_do_not_search_home(self):
        cached = self.home / ".cache" / "launchpadlib" / "credentials"
        cached.parent.mkdir(parents=True)
        cached.write_text("inert fixture, not an OAuth credential", encoding="utf-8")
        result = self.resolve()
        self.assertNotEqual(result.returncode, 0, "Implicit credential discovery must fail closed")
        self.assertEqual(result.stdout, "")

    def test_explicit_file_precedes_oauth_file(self):
        result = self.resolve(LAUNCHPAD_CREDENTIALS_FILE="explicit.credentials",
                              LAUNCHPAD_OAUTH_CREDENTIALS_FILE="other.credentials")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "explicit.credentials")

    def test_oauth_file_is_supported(self):
        result = self.resolve(LAUNCHPAD_OAUTH_CREDENTIALS_FILE="explicit.credentials")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "explicit.credentials")

    def test_inline_credentials_precede_file_settings(self):
        result = self.resolve(LAUNCHPAD_CREDENTIALS="inert fixture text",
                              LAUNCHPAD_CREDENTIALS_FILE="not-selected")
        self.assertEqual(result.returncode, 0)
        # mktemp can emit MSYS paths; inspect the fixture directory instead.
        files = list(self.home.iterdir())
        self.assertEqual(len(files), 1)
        self.assertEqual(files[0].read_text(encoding="utf-8"), "inert fixture text\n")
        self.assertNotIn("inert fixture text", result.stdout)


if __name__ == "__main__":
    unittest.main()
