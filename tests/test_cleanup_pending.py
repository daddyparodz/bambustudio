"""Exercise the shipped cleanup gate assignment with real Bash and jq."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/sync-ppa-channel.yml"
BASH = "C:/Program Files/Git/bin/bash.exe" if os.name == "nt" else "bash"


class CleanupPendingTests(unittest.TestCase):
    def test_boolean_gate_under_errexit(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        assignments = re.findall(r'^\s*(cleanup_pending="\$\(jq .*\)")$', workflow, re.M)
        self.assertEqual(len(assignments), 1)
        cases = [
            ('{"cleanup_pending":false}', "false\n"),
            ('{"cleanup_pending":true}', "true\n"),
            ('{}', None),
            ('{"cleanup_pending":null}', None),
            ('{"cleanup_pending":"false"}', None),
            ('{"cleanup_pending":0}', None),
            ('{"cleanup_pending":', None),
        ]
        for payload, expected in cases:
            with self.subTest(payload=payload):
                # A separate Bash process preserves errexit (no guarded function call).
                script = ('set -euo pipefail\nresult="$1"\n'
                          + assignments[0] + '\nprintf "%s\\n" "$cleanup_pending"\n')
                with tempfile.TemporaryDirectory() as directory:
                    fixture = Path(directory) / "retention.json"
                    fixture.write_text(payload, encoding="utf-8")
                    result = subprocess.run(
                        [BASH, "--noprofile", "--norc", "-c", script,
                         "gate-test", fixture.as_posix()],
                        capture_output=True, text=True, timeout=10,
                    )
                if expected is None:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(result.stdout, "")
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout, expected)
                    self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
