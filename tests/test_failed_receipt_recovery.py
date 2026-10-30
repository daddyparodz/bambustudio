"""Offline replay of failed receipts; no provider writes are available."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/verify-ppa-release.sh'

FAKE = '''
import json
import os
from pathlib import Path
from types import SimpleNamespace as NS

captured = json.loads(Path(os.environ['CAPTURED_GET']).read_text())
class Publication:
    def __init__(self):
        self.__dict__.update(captured['source'])
        self.status = os.environ.get('SOURCE_STATUS', self.status)
    def getBuilds(self):
        values = dict(captured['build'], buildstate=os.environ['STATE'])
        field = os.environ.get('MISMATCH')
        if field: values[field] = 'wrong'
        return [NS(**values)]
class Archive:
    def getPublishedSources(self, status, **kwargs):
        return [Publication()] if status == os.environ.get('SOURCE_STATUS', 'Published') else []
    def getPublishedBinaries(self, **kwargs):
        if os.environ.get('BINARY_MODE') == 'missing': return []
        # Positive recovery is a simulated future, not a claim that the failed
        # stonking build or its binary has actually succeeded.
        values = json.loads(Path(os.environ['CAPTURED_BINARY']).read_text())
        values.update(source_package_version=captured['source']['source_package_version'],
            binary_package_version=captured['source']['source_package_version'],
            distro_arch_series_link=captured['source']['distro_series_link'] + '/amd64',
            build_link=captured['build']['self_link'])
        if os.environ.get('BINARY_MODE') == 'wrong-build': values['build_link'] = 'wrong'
        return [NS(**values)]
class Launchpad:
    @staticmethod
    def login_anonymously(*args, **kwargs):
        return NS(people={'daddyparodz': NS(getPPAByName=lambda **kw: Archive())},
            distributions={'ubuntu': NS(getSeries=lambda **kw: object())})
'''

class FailedReceiptRecoveryTests(unittest.TestCase):
    def verify(self, state, mismatch='', schema=1, binary_mode='', source_status='Published'):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            package = root / 'launchpadlib'
            package.mkdir()
            (package / '__init__.py').write_text('')
            (package / 'launchpad.py').write_text(FAKE)
            manifest = dict(schema=schema, channel='beta', package='bambustudio-beta',
                tag='v02.08.04.57', commit='48f33bbdcc4a8ca755c32f5201277812935a30b5',
                revision=3, created_at='2026-10-29T22:34:01Z', status='failed',
                sources=[dict(series='stonking', version='02.08.04.57+stonking-0ppa3~26.10.1')])
            path = root / 'failed.json'
            path.write_text(json.dumps(manifest))
            output = root / 'result.json'
            code = SCRIPT.read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
            env = dict(os.environ, PYTHONPATH=str(root), STATE=state, MISMATCH=mismatch,
                CAPTURED_GET=str(ROOT / 'tests/fixtures/failed-build-33886079.json.fixture'),
                CAPTURED_BINARY=str(ROOT / 'tests/fixtures/published-binary-33886076.json.fixture'),
                BINARY_MODE=binary_mode, SOURCE_STATUS=source_status,
                VERIFY_PPA_MANIFEST=str(path), VERIFY_PPA_RESULT=str(output),
                VERIFY_PPA_OWNER='daddyparodz', VERIFY_PPA_ARCHIVE='bambustudio',
                VERIFY_PPA_SOURCE_DEADLINE='1800', VERIFY_PPA_BUILD_DEADLINE='7200')
            result = subprocess.run([sys.executable, '-c', code], env=env,
                capture_output=True, text=True, timeout=15)
            self.assertEqual(path.read_text(), json.dumps(manifest))
            return result, json.loads(output.read_text()) if output.exists() else None

    def test_failed_receipt_recovers_only_after_exact_build_success(self):
        for state, expected in [('Failed to build', 'failed'),
                                ('Currently building', 'failed'),
                                ('Successfully built', 'success')]:
            with self.subTest(state=state):
                result, payload = self.verify(state)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIsNotNone(payload)
                assert payload is not None
                self.assertEqual(payload['status'], expected)

    def test_mismatched_build_identity_never_recovers(self):
        for field in ('source_package_name', 'source_package_version', 'archive_link',
                      'distro_series_link', 'current_source_publication_link', 'self_link', 'arch_tag'):
            with self.subTest(field=field):
                result, payload = self.verify('Successfully built', mismatch=field)
                self.assertTrue(result.returncode != 0 or not payload or payload['status'] != 'success')

    def test_success_without_exact_binary_publication_stays_held(self):
        for mode in ('missing', 'wrong-build'):
            with self.subTest(mode=mode):
                result, payload = self.verify('Successfully built', binary_mode=mode)
                self.assertTrue(result.returncode != 0 or not payload or payload['status'] != 'success')

    def test_pending_source_does_not_recover(self):
        result, payload = self.verify('Successfully built', source_status='Pending')
        self.assertTrue(result.returncode != 0 or not payload or payload['status'] != 'success')

    def test_unknown_schema_never_recovers(self):
        result, payload = self.verify('Successfully built', schema=2)
        self.assertTrue(result.returncode != 0 or not payload or payload['status'] != 'success')

if __name__ == '__main__':
    unittest.main()
