"""Run with: uv run --with pyyaml python tests/test_reboot_recovery.py"""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid

import yaml


ROOT = Path(__file__).resolve().parents[1]
RELEASE = yaml.safe_load((ROOT / "infrastructure/crowdsec/helmrelease.yaml").read_text())
PATCH = yaml.safe_load(RELEASE["spec"]["postRenderers"][0]["kustomize"]["patches"][0]["patch"])
COMMAND = PATCH["spec"]["template"]["spec"]["initContainers"][0]["command"]


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for directory in ("bin", "staging", "etc", "saved"):
            (self.root / directory).mkdir()
        self.credentials = self.root / "saved/local_api_credentials.yaml"
        self.calls = self.root / "calls"
        self.env = dict(os.environ, PATH=f"{self.root}/bin:{os.environ['PATH']}",
                        TEST_ROOT=str(self.root), USERNAME="existing-pod",
                        LAPI_HOST="lapi", LAPI_PORT="8080", LAPI_URL="http://lapi:8080",
                        REGISTRATION_TOKEN="test-token")
        for name, body in {
            "nc": "exit 0\n",
            "cscli": '''echo "$*" >> "$TEST_ROOT/calls"
if [ "$2" = status ]; then exit "${STATUS_EXIT:-0}"; fi
if [ "${REGISTER_EXIT:-0}" != 0 ]; then exit "$REGISTER_EXIT"; fi
machine="$4"
if [ "$machine" = existing-pod ]; then exit 1; fi
echo "$machine" > "$TEST_ROOT/etc/crowdsec/local_api_credentials.yaml"
''',
        }.items():
            executable = self.root / "bin" / name
            executable.write_text("#!/bin/sh\nset -eu\n" + body)
            executable.chmod(0o755)

    def run_init(self, **env):
        # Each init-container start gets a fresh writable layer; emptyDir survives.
        link = self.root / "etc/crowdsec"
        if link.is_symlink():
            link.unlink()
        (self.root / "uuid").write_text(str(uuid.uuid4()))
        script = COMMAND[2]
        for source, destination in (
            ("/staging/etc/crowdsec", "staging"),
            ("/etc/crowdsec", "etc/crowdsec"),
            ("/tmp_config", "saved"),
            ("/proc/sys/kernel/random/uuid", "uuid"),
        ):
            script = script.replace(source, str(self.root / destination))
        return subprocess.run([*COMMAND[:2], script], env=self.env | env,
                              capture_output=True, text=True)

    def test_reboot_reuses_credentials(self):
        self.assertEqual(self.run_init().returncode, 0)
        original = self.credentials.read_text()
        self.assertEqual(self.run_init().returncode, 0)
        self.assertEqual(self.credentials.read_text(), original)
        self.assertEqual(self.calls.read_text().count("lapi register"), 1)
        self.assertIn("lapi status", self.calls.read_text())

    def test_lost_credentials_do_not_reuse_registered_name(self):
        self.assertEqual(self.run_init().returncode, 0)
        original = self.credentials.read_text()
        self.credentials.unlink()
        self.assertEqual(self.run_init().returncode, 0)
        self.assertNotEqual(self.credentials.read_text(), original)

    def test_registration_failure_does_not_publish_credentials(self):
        self.assertNotEqual(self.run_init(REGISTER_EXIT="1").returncode, 0)
        self.assertFalse(self.credentials.exists())
        self.assertEqual(self.run_init().returncode, 0)

    def test_authentication_failure_retries_without_overwriting_credentials(self):
        self.assertEqual(self.run_init().returncode, 0)
        original = self.credentials.read_text()
        self.assertNotEqual(self.run_init(STATUS_EXIT="1").returncode, 0)
        self.assertEqual(self.credentials.read_text(), original)
        self.assertEqual(self.calls.read_text().count("lapi register"), 1)
        self.assertEqual(self.run_init().returncode, 0)


if __name__ == "__main__":
    unittest.main()
