"""Exercise release-state persistence with an ignored JSON suffix and a real Git remote."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
RECORD = ROOT / "scripts" / "record-ppa-pending-state.sh"
RECONCILE = ROOT / "scripts" / "reconcile-ppa-release-state.sh"


def command(*args, cwd=None, check=True):
    result = subprocess.run(
        [str(arg) for arg in args],
        cwd=cwd, capture_output=True, text=True, timeout=30,
    )
    if check and result.returncode:
        raise AssertionError(
            f"Command {args!r} failed with {result.returncode}: {result.stderr}\n{result.stdout}"
        )
    return result


class ReleaseStateTrackingTests(unittest.TestCase):
    def test_ignored_pending_and_failure_json_are_recorded(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bare = root / "remote.git"
            seed = root / "seed"
            worker = root / "worker"
            command("git", "init", "--bare", bare)
            command("git", "init", "-b", "main", seed)
            command("git", "config", "user.name", "Test Author", cwd=seed)
            command("git", "config", "user.email", "test@example.invalid", cwd=seed)
            (seed / "state").mkdir()
            (seed / ".gitignore").write_text("*.json\n", encoding="utf-8")
            (seed / "state" / "latest-stable-tag.txt").write_text(
                "v00.00.00.00\n", encoding="utf-8"
            )
            command("git", "add", ".", cwd=seed)
            command("git", "commit", "-m", "Seed release state", cwd=seed)
            command("git", "branch", "release-state", cwd=seed)
            command("git", "remote", "add", "origin", bare, cwd=seed)
            command("git", "push", "origin", "main", "release-state", cwd=seed)
            command("git", "clone", "-b", "main", bare, worker)

            manifest = root / "pending.json"
            manifest.write_text(
                json.dumps({
                    "channel": "stable", "status": "pending", "revision": 1,
                    "tag": "v01.00.00.00",
                }) + "\n", encoding="utf-8",
            )
            command("bash", RECORD, "--channel", "stable",
                    "--manifest", manifest, cwd=worker)
            pending = command(
                "git", "--git-dir", bare, "show",
                "release-state:state/pending-stable.json",
            )
            self.assertEqual(json.loads(pending.stdout)["status"], "pending")

            first_sha = command(
                "git", "--git-dir", bare, "rev-parse", "refs/heads/release-state",
            ).stdout.strip()
            command("bash", RECORD, "--channel", "stable",
                    "--manifest", manifest, cwd=worker)
            second_sha = command(
                "git", "--git-dir", bare, "rev-parse", "refs/heads/release-state",
            ).stdout.strip()
            self.assertEqual(first_sha, second_sha, "Repeated pending write must be idempotent")

            scripts = worker / "scripts"
            scripts.mkdir()
            verifier = scripts / "verify-ppa-release.sh"
            verifier.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "result=''\n"
                "while [[ $# -gt 0 ]]; do\n"
                "  if [[ \"$1\" == '--result-json' ]]; then result=\"$2\"; break; fi\n"
                "  shift\n"
                "done\n"
                "printf '%s\\n' '{\"status\":\"failed\",\"message\":\"test rejection\"}' > \"$result\"\n",
                encoding="utf-8",
            )
            reconciliation = command("bash", RECONCILE, cwd=worker, check=False)
            self.assertEqual(reconciliation.returncode, 1, reconciliation.stderr)
            failed = command(
                "git", "--git-dir", bare, "show",
                "release-state:state/failed-stable.json",
            )
            self.assertEqual(json.loads(failed.stdout)["status"], "failed")
            missing = command(
                "git", "--git-dir", bare, "cat-file", "-e",
                "release-state:state/pending-stable.json", check=False,
            )
            self.assertNotEqual(missing.returncode, 0)

            # Repeated native reconciliation must retain the exact failed
            # receipt, not turn a rebuilding/absent source into a new upload.
            failed_sha = command(
                "git", "--git-dir", bare, "rev-parse", "refs/heads/release-state",
            ).stdout.strip()
            for status in ("failed", "pending", "retryable"):
                payload = {"status": status, "tag": "v01.00.00.00",
                           "commit": "deadbeef", "revision": 1}
                verifier.write_text(
                    '#!/usr/bin/env bash\nset -euo pipefail\n'
                    'while [[ $# -gt 0 ]]; do\n'
                    '  if [[ "$1" == "--result-json" ]]; then result="$2"; break; fi\n'
                    '  shift\ndone\n'
                    f"printf '%s\\n' '{json.dumps(payload)}' > \"$result\"\n",
                    encoding="utf-8",
                )
                held = command("bash", RECONCILE, cwd=worker, check=False)
                self.assertEqual(held.returncode, 1, held.stderr)
                self.assertEqual(command(
                    "git", "--git-dir", bare, "rev-parse", "refs/heads/release-state",
                ).stdout.strip(), failed_sha, status)

            verifier.write_text(verifier.read_text().replace('"retryable"', '"success"'))
            recovered = command("bash", RECONCILE, cwd=worker, check=False)
            self.assertEqual(recovered.returncode, 0, recovered.stderr)
            latest = command("git", "--git-dir", bare, "show",
                             "release-state:state/latest-stable-tag.txt")
            self.assertEqual(latest.stdout.strip(), "v01.00.00.00")
            self.assertNotEqual(command(
                "git", "--git-dir", bare, "cat-file", "-e",
                "release-state:state/failed-stable.json", check=False,
            ).returncode, 0)


if __name__ == "__main__":
    unittest.main()
