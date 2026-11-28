import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class ScriptTests(unittest.TestCase):
    def test_service_wrapper_passes_only_known_actions(self):
        with tempfile.TemporaryDirectory() as tmp:
            bindir = pathlib.Path(tmp) / "bin"
            bindir.mkdir()
            log = pathlib.Path(tmp) / "calls.txt"
            fake = bindir / "systemctl"
            fake.write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"%s\"\n" % (" ".join(["%s"]), str(log)), encoding="utf-8")
            fake.chmod(0o755)
            env = os.environ.copy()
            env["PATH"] = str(bindir) + os.pathsep + env.get("PATH", "")
            p = subprocess.run(["bash", str(ROOT / "modules/service.sh"), "restart"], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(log.read_text(encoding="utf-8").strip(), "restart ssr.service")
            bad = subprocess.run(["bash", str(ROOT / "modules/service.sh"), "kill"], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual(bad.returncode, 2)

    def test_main_script_version_command_is_noninteractive(self):
        p = subprocess.run(["bash", str(ROOT / "ssr.sh"), "--version"], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue(p.stdout.strip())


if __name__ == "__main__":
    unittest.main()
