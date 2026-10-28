"""Exercise SFTP configuration with HOME different from OpenSSH's passwd home."""
import os
import socket
import threading
from pathlib import Path
import subprocess
import tempfile
import unittest

import paramiko


ROOT = Path(__file__).resolve().parents[1]


class UploadSFTPTests(unittest.TestCase):
    def test_setup_uses_openssh_home_and_strict_pinned_trust(self):
        script = (ROOT / "scripts/upload-ppa.sh").read_text()
        setup = script[script.index("setup_sftp_target() {"):script.index('\nupload_target="$PPA_TARGET"')]
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory) / "environment-home"
            ssh_home = Path(directory) / "passwd-home"
            home.mkdir()
            ssh_home.mkdir()
            env = dict(os.environ, HOME=str(home), TEST_SSH_HOME=str(ssh_home),
                       LAUNCHPAD_SFTP_LOGIN="publisher", LAUNCHPAD_SSH_PRIVATE_KEY="test-key",
                       SCRIPT_DIR=str(ROOT / "scripts"))
            # Control only the account lookup; do not touch the invoking user's SSH files.
            command = '''set -euo pipefail
getent() { printf 'test:x:1234:1234::%s:/bin/bash\\n' "$TEST_SSH_HOME"; }
ssh-keyscan() { echo 'Unexpected network trust discovery' >&2; return 91; }
''' + setup + '\nsetup_sftp_target ppa:example/archive\n'
            result = subprocess.run(["bash", "-c", command], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            config = ssh_home / ".ssh/config"
            self.assertTrue(config.exists(), "OpenSSH reads passwd home, not the HOME environment variable")
            effective = subprocess.run(["ssh", "-G", "-F", str(config), "ppa.launchpad.net"],
                                       capture_output=True, text=True, check=True).stdout
            self.assertIn("stricthostkeychecking true", effective)
            self.assertIn("batchmode yes", effective)
            self.assertIn("identitiesonly yes", effective)
            self.assertIn(str(ssh_home / ".ssh/id_launchpad_upload"), effective)
            trust = ssh_home / ".ssh/known_hosts_launchpad"
            fingerprint = subprocess.run(["ssh-keygen", "-lf", str(trust), "-E", "sha256"],
                                         capture_output=True, text=True, check=True).stdout
            self.assertIn("SHA256:MGq+4hxD7RduVTcfwlwwboZnsgJC6SL/NltM8ye+gNg", fingerprint)
            self.assertIn(str(trust), effective)
            self.assertTrue((home / ".dput.cf").exists())
            self.assertFalse((home / ".ssh").exists())


    def test_openssh_accepts_pinned_key_and_denies_replacement(self):
        server_key = paramiko.RSAKey.generate(2048)
        other_key = paramiko.RSAKey.generate(2048)
        with tempfile.TemporaryDirectory() as directory:
            ssh_dir = Path(directory) / ".ssh"
            ssh_dir.mkdir()
            # Use the actual generated configuration, with an isolated account home.
            script = (ROOT / "scripts/upload-ppa.sh").read_text()
            setup = script[script.index("setup_sftp_target() {"):script.index('\nupload_target="$PPA_TARGET"')]
            env = dict(os.environ, HOME=directory, TEST_SSH_HOME=directory,
                       LAUNCHPAD_SFTP_LOGIN="publisher", LAUNCHPAD_SSH_PRIVATE_KEY="test-key",
                       SCRIPT_DIR=str(ROOT / "scripts"))
            command = '''set -euo pipefail
getent() { printf 'test:x:1234:1234::%s:/bin/bash\\n' "$TEST_SSH_HOME"; }
''' + setup + '\nsetup_sftp_target ppa:example/archive\n'
            subprocess.run(["bash", "-c", command], env=env, check=True)
            for pinned_key, expected in ((server_key, "is known and matches the RSA host key"),
                                         (other_key, "REMOTE HOST IDENTIFICATION HAS CHANGED")):
                with self.subTest(matches=pinned_key == server_key):
                    trust = ssh_dir / "known_hosts_launchpad"
                    trust.write_text("ppa.launchpad.net ssh-rsa " + pinned_key.get_base64() + "\n")
                    listener = socket.socket()
                    listener.bind(("127.0.0.1", 0))
                    listener.listen(1)
                    listener.settimeout(10)
                    port = listener.getsockname()[1]
                    errors = []

                    def serve():
                        try:
                            with listener:
                                conn, _ = listener.accept()
                                with paramiko.Transport(conn) as transport:
                                    transport.add_server_key(server_key)
                                    transport.start_server(server=paramiko.ServerInterface())
                                    transport.accept(timeout=3)
                        except (EOFError, paramiko.SSHException):
                            # Host rejection closes the handshake before authentication.
                            pass
                        except ConnectionResetError as error:
                            # OpenSSH may reset TCP when rejecting the replacement key.
                            if pinned_key == server_key:
                                errors.append(error)
                        except Exception as error:
                            errors.append(error)

                    worker = threading.Thread(target=serve, daemon=True)
                    worker.start()
                    result = subprocess.run([
                        "ssh", "-v", "-F", str(ssh_dir / "config"),
                        "-oHostKeyAlias=ppa.launchpad.net", "-oHostName=127.0.0.1",
                        "-oPreferredAuthentications=none", "-oConnectTimeout=5",
                        "-p", str(port), "ppa.launchpad.net", "true"],
                        capture_output=True, text=True, timeout=10)
                    worker.join(timeout=10)
                    self.assertFalse(worker.is_alive())
                    self.assertEqual(errors, [])
                    self.assertIn(expected, result.stderr)
                    if pinned_key != server_key:
                        self.assertNotIn("Authentications that can continue", result.stderr)


    def test_preflight_is_read_only_and_propagates_failure(self):
        for status in (0, 255):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as directory:
                env = dict(os.environ, HOME=directory, PREFLIGHT_RC=str(status),
                           LAUNCHPAD_SSH_PRIVATE_KEY="test-key", PPA_UPLOAD_METHOD="auto",
                           LAUNCHPAD_SFTP_LOGIN="publisher")
                command = '''set -euo pipefail
getent() { printf 'test:x:1234:1234::%s:/bin/bash\\n' "$HOME"; }
sftp() { printf '%s\\n' "$*" > "$HOME/preflight-args"; cat > "$HOME/preflight-commands"; return "$PREFLIGHT_RC"; }
dput() { touch "$HOME/upload-attempted"; return 97; }
export -f getent sftp dput
bash "$1" --check-sftp
'''
                result = subprocess.run(["bash", "-c", command, "test", str(ROOT / "scripts/upload-ppa.sh")],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertEqual((Path(directory) / "preflight-commands").read_text(), "pwd\nquit\n")
                self.assertIn("-b -", (Path(directory) / "preflight-args").read_text())
                self.assertFalse((Path(directory) / "upload-attempted").exists())
                self.assertNotIn("falling back", result.stdout + result.stderr)
                if status:
                    self.assertNotIn("authentication succeeded", result.stdout)


if __name__ == "__main__":
    unittest.main()
