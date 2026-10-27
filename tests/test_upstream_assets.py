"""Exercise the shipped asset selector without network or package publication."""
import json
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = 'C:/Program Files/Git/bin/bash.exe' if os.name == 'nt' else 'bash'


class AppImageSelectionTests(unittest.TestCase):
    def select(self, names, series='jammy'):
        release = json.dumps({'assets': [{'browser_download_url': 'https://example.test/' + name} for name in names]})
        script = '''source "$1"
series_version_suffix() { case "$1" in jammy) echo 22.04;; noble) echo 24.04;; esac; }
appimage_asset_url "$2" "$3"
'''
        return subprocess.run([BASH, '--noprofile', '--norc', '-c', script,
                               'selector-test', (ROOT / 'scripts/lib/upstream.sh').as_posix(), release, series],
                              capture_output=True, text=True, timeout=10)

    def test_current_shortened_ubuntu_assets_select_matching_series(self):
        names = ['BambuStudio_ubu24-v02.08.04.57-20260922164607.AppImage',
                 'BambuStudio_ubu22-v02.08.04.57-20260922164607.AppImage']
        for series, expected in [('jammy', names[1]), ('noble', names[0])]:
            with self.subTest(series=series):
                result = self.select(names, series)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), 'https://example.test/' + expected)

    def test_legacy_asset_format_and_series_preference_remain_supported(self):
        names = ['BambuStudio_ubuntu-24.04-v1.AppImage', 'BambuStudio_ubuntu22.04-v1.AppImage']
        self.assertEqual(self.select(names).stdout.strip(), 'https://example.test/' + names[1])
        self.assertEqual(self.select(names, 'noble').stdout.strip(), 'https://example.test/' + names[0])

    def test_existing_cross_series_fallback_is_preserved(self):
        for name in ['BambuStudio_ubuntu_24.04-v1.AppImage', 'BambuStudio_ubu24-v1.AppImage']:
            with self.subTest(name=name):
                self.assertEqual(self.select([name]).stdout.strip(), 'https://example.test/' + name)

    def test_unrelated_or_non_appimage_assets_are_rejected(self):
        result = self.select(['BambuStudio_ubu22-v1.exe', 'Other_ubu22-v1.AppImage'])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')


if __name__ == '__main__':
    unittest.main()
