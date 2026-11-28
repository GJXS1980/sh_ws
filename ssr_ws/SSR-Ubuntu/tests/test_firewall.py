import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
FIREWALL = ROOT / "modules" / "firewall.sh"


class FirewallHelperTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        self.bindir = self.root / "bin"
        self.bindir.mkdir()
        self.state = self.root / "state"
        self.log = self.root / "commands.log"

    def tearDown(self):
        self.tmp.cleanup()

    def _mock(self, name, lines):
        path = self.bindir / name
        path.write_text("#!/bin/sh\n" + "\n".join(lines) + "\n", encoding="utf-8")
        path.chmod(0o755)
        return path

    def _run(self, *args):
        env = os.environ.copy()
        env["PATH"] = str(self.bindir) + os.pathsep + env.get("PATH", "")
        env["SSR_STATE_DIR"] = str(self.state)
        env["MOCK_LOG"] = str(self.log)
        return subprocess.run(
            ["bash", str(FIREWALL), *args],
            env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )

    def test_firewalld_adds_runtime_and_permanent_tcp_udp(self):
        self._mock("firewall-cmd", [
            'echo "$*" >> "$MOCK_LOG"',
            'case "$1" in --state) echo running; exit 0 ;; --get-default-zone) echo public; exit 0 ;; esac',
            'case " $* " in *" --query-port="*) exit 1 ;; *" --add-port="*) exit 0 ;; *) exit 0 ;; esac',
        ])
        p = self._run("allow", "555")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        ledger = (self.state / "firewall-created.tsv").read_text()
        self.assertIn("firewalld|public|555|tcp|1|1", ledger)
        self.assertIn("firewalld|public|555|udp|1|1", ledger)
        calls = self.log.read_text()
        self.assertIn("--add-port=555/tcp", calls)
        self.assertIn("--permanent --zone=public --add-port=555/tcp", calls)
        self.assertIn("--add-port=555/udp", calls)
        self.assertIn("--permanent --zone=public --add-port=555/udp", calls)

    def test_firewalld_remove_deletes_only_managed_rules(self):
        self._mock("firewall-cmd", [
            'echo "$*" >> "$MOCK_LOG"',
            'case "$1" in --state) echo running; exit 0 ;; --get-default-zone) echo public; exit 0 ;; esac',
            'case " $* " in *" --query-port="*) exit 1 ;; *" --add-port="*) exit 0 ;; *" --remove-port="*) exit 0 ;; *) exit 0 ;; esac',
        ])
        add = self._run("allow", "555")
        self.assertEqual(add.returncode, 0, add.stderr)
        remove = self._run("remove", "555")
        self.assertEqual(remove.returncode, 0, remove.stderr)
        self.assertFalse((self.state / "firewall-created.tsv").read_text().strip())
        calls = self.log.read_text()
        self.assertIn("--remove-port=555/tcp", calls)
        self.assertIn("--permanent --zone=public --remove-port=555/tcp", calls)
        self.assertIn("--remove-port=555/udp", calls)
        self.assertIn("--permanent --zone=public --remove-port=555/udp", calls)

    def test_ufw_adds_tcp_and_udp_without_enabling_firewall(self):
        self._mock("ufw", [
            'if [ "$1" = status ]; then echo "Status: active"; exit 0; fi',
            'echo "$*" >> "$MOCK_LOG"',
            'exit 0',
        ])
        p = self._run("allow", "555")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        calls = self.log.read_text()
        self.assertIn("allow 555/tcp comment ssr-ubuntu-managed", calls)
        self.assertIn("allow 555/udp comment ssr-ubuntu-managed", calls)

    def test_no_active_firewall_returns_nonfatal_status(self):
        p = self._run("allow", "555")
        self.assertEqual(p.returncode, 3)
        self.assertIn("不会自动开启防火墙", p.stdout)

    def test_invalid_port_rejected(self):
        p = self._run("allow", "65536")
        self.assertEqual(p.returncode, 2)
        self.assertIn("端口无效", p.stderr)


if __name__ == "__main__":
    unittest.main()
