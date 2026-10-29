"""Exercise orig-recovery imports against real complete and incomplete stdlibs."""
import json
import os
from pathlib import Path
import subprocess
import sys
import sysconfig
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipIf(os.name == "nt", "isolated stdlib fixture uses POSIX symlinks")
class OrigRecoveryRuntimeTests(unittest.TestCase):
    def run_imports(self, missing_quopri):
        script = (ROOT / "scripts/fetch-ppa-origs.sh").read_text()
        header = script.split("<<'PY'\n", 1)[1].split('\npackage = ', 1)[0]
        stdlib = Path(sysconfig.get_path("stdlib"))
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory)
            for entry in stdlib.iterdir():
                if entry.name in {"__pycache__", "site-packages", "dist-packages"}:
                    continue
                if missing_quopri and entry.name in {"quopri.py", "quopri.pyc"}:
                    continue
                (fixture / entry.name).symlink_to(entry, target_is_directory=entry.is_dir())
            paths = [str(fixture), str(stdlib / "lib-dynload")]
            code = f"import sys; sys.path[:] = {paths!r}; exec({header!r})"
            env = dict(os.environ, PYTHONPATH="runtime-secret-canary", PYTHONHOME="")
            return subprocess.run(
                [sys.executable, "-S", "-c", code], env=env,
                capture_output=True, text=True, timeout=30,
            )

    def test_missing_real_stdlib_module_retains_failure_and_runtime_evidence(self):
        result = self.run_imports(missing_quopri=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ModuleNotFoundError: No module named 'quopri'", result.stderr)
        records = [line for line in result.stderr.splitlines()
                   if line.startswith("ORIG_RUNTIME_IMPORT_FAILURE ")]
        self.assertEqual(len(records), 1, result.stderr)
        record = json.loads(records[0].split(" ", 1)[1])
        self.assertEqual(record["missing_module"], "quopri")
        self.assertEqual(Path(record["executable"]).resolve(), Path(sys.executable).resolve())
        self.assertTrue(record["pythonpath_set"])
        self.assertIn("stdlib_quopri_exists", record)
        self.assertFalse(record["search_path_quopri_exists"])
        self.assertNotIn("runtime-secret-canary", result.stdout + result.stderr)

    def test_complete_real_stdlib_imports_succeed_without_failure_record(self):
        result = self.run_imports(missing_quopri=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("ORIG_RUNTIME_IMPORT_FAILURE", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
