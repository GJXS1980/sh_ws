import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
CONFIG = ROOT / "modules" / "config.py"


def single_config():
    return {
        "server": "0.0.0.0", "server_ipv6": "::", "server_port": 2333,
        "local_address": "127.0.0.1", "local_port": 1080,
        "password": "secret-1", "method": "aes-128-ctr",
        "protocol": "auth_sha1_v4_compatible", "protocol_param": "",
        "obfs": "plain", "obfs_param": "", "speed_limit_per_con": 0,
        "speed_limit_per_user": 0, "additional_ports": {}, "timeout": 120,
        "udp_timeout": 60, "dns_ipv6": False, "connect_verbose_info": 0,
        "redirect": "", "fast_open": False, "custom_field": {"keep": True},
    }


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = pathlib.Path(self.tmp.name) / "user-config.json"
        self.write(single_config())

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, data):
        self.path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")

    def load(self):
        return json.loads(self.path.read_text(encoding="utf-8"))

    def run_cli(self, *args, ok=True):
        env = os.environ.copy()
        env["SSR_SKIP_SYSTEMCTL"] = "1"
        env["SSR_SKIP_FIREWALL"] = "1"
        p = subprocess.run([sys.executable, str(CONFIG), *args, "--file", str(self.path), "--no-restart"], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if ok and p.returncode != 0:
            self.fail("command failed: %s\n%s\n%s" % (args, p.stdout, p.stderr))
        if not ok and p.returncode == 0:
            self.fail("command unexpectedly succeeded: %s" % (args,))
        return p

    def test_single_to_multi_preserves_account_and_unknown_fields(self):
        self.run_cli("mode", "multi")
        d = self.load()
        self.assertEqual(d["port_password"], {"2333": "secret-1"})
        self.assertEqual(d["custom_field"], {"keep": True})
        self.assertNotIn("password", d)
        self.assertTrue(list((self.path.parent / "backups").glob("*.bak")))

    def test_add_duplicate_and_delete_last_protection(self):
        self.run_cli("mode", "multi")
        self.run_cli("add-user", "2334", "secret-2")
        self.assertEqual(self.load()["port_password"]["2334"], "secret-2")
        self.run_cli("add-user", "2334", "other", ok=False)
        self.run_cli("delete-user", "2333")
        self.run_cli("delete-user", "2334", ok=False)

    def test_multi_to_single_requires_explicit_drop_confirmation(self):
        self.run_cli("mode", "multi")
        self.run_cli("add-user", "2334", "secret-2")
        self.run_cli("mode", "single", "--port", "2334", ok=False)
        self.run_cli("mode", "single", "--port", "2334", "--confirm-drop")
        d = self.load()
        self.assertEqual(d["server_port"], 2334)
        self.assertEqual(d["password"], "secret-2")
        self.assertNotIn("port_password", d)

    def test_multi_to_single_promotes_list_overrides(self):
        d = single_config()
        d.pop("server_port"); d.pop("password")
        d["port_password"] = {
            "2333": ["list-secret", "http_simple_compatible", "auth_sha1_v4_compatible"],
            "2334": "other-secret",
        }
        self.write(d)
        self.run_cli("mode", "single", "--port", "2333", "--confirm-drop")
        result = self.load()
        self.assertEqual(result["server_port"], 2333)
        self.assertEqual(result["password"], "list-secret")
        self.assertEqual(result["method"], "aes-128-ctr")
        self.assertEqual(result["obfs"], "http_simple_compatible")
        self.assertEqual(result["protocol"], "auth_sha1_v4_compatible")
        self.assertNotIn("port_password", result)

    def test_multi_to_single_promotes_dict_overrides(self):
        d = single_config()
        d.pop("server_port"); d.pop("password")
        d["port_password"] = {
            "2333": {"password": "dict-secret", "method": "aes-256-ctr", "protocol": "auth_sha1_v4_compatible", "protocol_param": "8", "obfs": "tls1.2_ticket_auth_compatible", "obfs_param": "host.example", "out_bind": "192.0.2.10", "out_bindv6": "2001:db8::1"},
            "2334": "other-secret",
        }
        self.write(d)
        self.run_cli("mode", "single", "--port", "2333", "--confirm-drop")
        result = self.load()
        self.assertEqual(result["password"], "dict-secret")
        self.assertEqual(result["method"], "aes-256-ctr")
        self.assertEqual(result["protocol_param"], "8")
        self.assertEqual(result["obfs_param"], "host.example")
        self.assertEqual(result["out_bind"], "192.0.2.10")
        self.assertEqual(result["out_bindv6"], "2001:db8::1")

    def test_json_string_escaping(self):
        self.run_cli("set", "password", json.dumps('a"b\\c'))
        self.assertEqual(self.load()["password"], 'a"b\\c')

    def test_invalid_candidate_does_not_replace_config(self):
        candidate = pathlib.Path(self.tmp.name) / "candidate.json"
        candidate.write_text('{bad json', encoding="utf-8")
        before = self.path.read_bytes()
        p = subprocess.run([sys.executable, str(CONFIG), "replace", "--candidate", str(candidate), "--file", str(self.path), "--no-restart"], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(self.path.read_bytes(), before)

    def test_stale_manual_edit_is_rejected(self):
        candidate = pathlib.Path(self.tmp.name) / "candidate.json"
        candidate.write_bytes(self.path.read_bytes())
        expected = hashlib.sha256(self.path.read_bytes()).hexdigest()
        changed = single_config(); changed["password"] = "changed-concurrently"
        self.write(changed)
        current = self.path.read_bytes()
        p = subprocess.run([sys.executable, str(CONFIG), "replace", "--candidate", str(candidate), "--file", str(self.path), "--expected-sha256", expected, "--no-restart"], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(self.path.read_bytes(), current)

    def test_runtime_config_removes_daemon_fields_only_from_copy(self):
        d = single_config()
        d.update({"daemon": "start", "pid-file": "/tmp/a.pid", "log-file": "/tmp/a.log", "user": "nobody"})
        self.write(d)
        output = pathlib.Path(self.tmp.name) / "runtime.json"
        p = subprocess.run([sys.executable, str(CONFIG), "runtime", "--source", str(self.path), "--output", str(output)], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(p.returncode, 0, p.stderr)
        runtime = json.loads(output.read_text(encoding="utf-8"))
        for key in ("daemon", "pid-file", "log-file", "user"):
            self.assertNotIn(key, runtime)
        self.assertIn("daemon", self.load())

    def test_symlink_lock_file_is_rejected(self):
        lock = self.path.parent / ("." + self.path.name + ".lock")
        target = pathlib.Path(self.tmp.name) / "outside-lock"
        target.write_text("", encoding="utf-8")
        lock.symlink_to(target)
        before = self.path.read_bytes()
        p = self.run_cli("set", "password", json.dumps("not-written"), ok=False)
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(target.read_text(encoding="utf-8"), "")

    def test_symlink_backup_directory_is_rejected(self):
        outside = pathlib.Path(self.tmp.name) / "outside-backups"
        outside.mkdir()
        (self.path.parent / "backups").symlink_to(outside, target_is_directory=True)
        before = self.path.read_bytes()
        self.run_cli("set", "password", json.dumps("not-written"), ok=False)
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(list(outside.iterdir()), [])

    def test_invalid_method_rejected(self):
        self.run_cli("set", "method", json.dumps("not-a-cipher"), ok=False)

    def test_compatible_suffix_restricted_to_original_plugin_behavior(self):
        self.run_cli("set", "protocol", json.dumps("auth_chain_a_compatible"), ok=False)
        self.run_cli("set", "obfs", json.dumps("plain_compatible"), ok=False)
        self.run_cli("set", "obfs", json.dumps("tls1.2_ticket_auth_compatible"))

    def test_advanced_manyuser_entries_are_preserved_and_password_can_change(self):
        d = single_config()
        d.pop("server_port"); d.pop("password")
        d["port_password"] = {
            "2333": ["pw-list", "http_simple_compatible", "auth_sha1_v4_compatible"],
            "2334": {"password": "pw-dict", "method": "aes-256-ctr", "protocol": "auth_sha1_v4_compatible", "obfs": "tls1.2_ticket_auth_compatible"},
        }
        self.write(d)
        self.run_cli("update-user", "2333", "2443", "--password", "pw-list-new")
        self.run_cli("update-user", "2334", "2444", "--password", "pw-dict-new")
        result = self.load()["port_password"]
        self.assertEqual(result["2443"], ["pw-list-new", "http_simple_compatible", "auth_sha1_v4_compatible"])
        self.assertEqual(result["2444"]["password"], "pw-dict-new")
        self.assertEqual(result["2444"]["method"], "aes-256-ctr")
        self.assertEqual(result["2444"]["obfs"], "tls1.2_ticket_auth_compatible")

    def test_legacy_missing_optional_defaults_are_preserved(self):
        d = {"server_port": 2333, "password": "legacy-password"}
        self.write(d)
        p = subprocess.run([sys.executable, str(CONFIG), "validate", "--file", str(self.path)], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.load(), d)

    def test_set_many_is_one_validated_transaction(self):
        payload = {"server_port": 2444, "password": "secret-new", "method": "aes-256-ctr", "protocol": "auth_sha1_v4_compatible", "obfs": "http_simple_compatible", "protocol_param": "5", "speed_limit_per_con": 128, "speed_limit_per_user": 512}
        self.run_cli("set-many", json.dumps(payload))
        d = self.load()
        for key, value in payload.items():
            self.assertEqual(d[key], value)

    def test_set_many_invalid_value_leaves_old_config_unchanged(self):
        before = self.path.read_bytes()
        payload = {"server_port": 2444, "password": "secret-new", "method": "bad-cipher"}
        self.run_cli("set-many", json.dumps(payload), ok=False)
        self.assertEqual(self.path.read_bytes(), before)

    def test_password_inputs_can_be_supplied_via_stdin(self):
        env = os.environ.copy(); env["SSR_SKIP_SYSTEMCTL"] = "1"
        self.run_cli("mode", "multi")
        add = subprocess.run([sys.executable, str(CONFIG), "add-user", "2444", "--password-stdin", "--file", str(self.path), "--no-restart"], input="stdin-secret\n", env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(add.returncode, 0, add.stderr)
        self.assertEqual(self.load()["port_password"]["2444"], "stdin-secret")
        update = subprocess.run([sys.executable, str(CONFIG), "update-user", "2444", "2445", "--password-stdin", "--file", str(self.path), "--no-restart"], input="new-stdin-secret\n", env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(update.returncode, 0, update.stderr)
        self.assertEqual(self.load()["port_password"]["2445"], "new-stdin-secret")

    def test_set_many_accepts_json_from_stdin(self):
        payload = {"server_port": 2555, "password": "stdin-batch-secret"}
        env = os.environ.copy(); env["SSR_SKIP_SYSTEMCTL"] = "1"
        p = subprocess.run([sys.executable, str(CONFIG), "set-many", "--json-stdin", "--file", str(self.path), "--no-restart"], input=json.dumps(payload), env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.load()["password"], "stdin-batch-secret")

    def test_service_restart_failure_rolls_back_config(self):
        before = self.path.read_bytes()
        bindir = pathlib.Path(self.tmp.name) / "bin"
        bindir.mkdir()
        state = pathlib.Path(self.tmp.name) / "restart-state"
        fake = bindir / "systemctl"
        fake.write_text(
            "#!/bin/sh\n"
            "cmd=$1\n"
            "case \"$cmd\" in\n"
            "  cat) exit 0 ;;\n"
            "  restart) if [ ! -f \"$FAKE_STATE\" ]; then touch \"$FAKE_STATE\"; exit 1; fi; exit 0 ;;\n"
            "  is-active) [ -f \"$FAKE_STATE\" ] && exit 0 || exit 1 ;;\n"
            "esac\n"
            "exit 0\n",
            encoding="utf-8",
        )
        fake.chmod(0o755)
        env = os.environ.copy()
        env["PATH"] = str(bindir) + os.pathsep + env.get("PATH", "")
        env["FAKE_STATE"] = str(state)
        env.pop("SSR_SKIP_SYSTEMCTL", None)
        p = subprocess.run([sys.executable, str(CONFIG), "set", "password", json.dumps("new-secret"), "--file", str(self.path)], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(self.path.read_bytes(), before)


    def _run_add_with_firewall_helper(self, helper, extra_env=None, no_restart=True):
        env = os.environ.copy()
        env.pop("SSR_SKIP_FIREWALL", None)
        env["SSR_FIREWALL_HELPER"] = str(helper)
        env["SSR_SKIP_SYSTEMCTL"] = "1" if no_restart else "0"
        if extra_env:
            env.update(extra_env)
        args = [sys.executable, str(CONFIG), "add-user", "2444", "new-secret", "--file", str(self.path)]
        if no_restart:
            args.append("--no-restart")
        return subprocess.run(args, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def test_add_user_calls_firewall_and_reports_result(self):
        self.run_cli("mode", "multi")
        helper = pathlib.Path(self.tmp.name) / "firewall-helper.sh"
        log = pathlib.Path(self.tmp.name) / "firewall.log"
        helper.write_text(
            "#!/bin/sh\n"
            "printf '%s\\n' \"$*\" >> \"%s\"\n"
            "case \"$1\" in allow) echo 'mock firewall allowed tcp and udp'; exit 0;; remove) exit 0;; *) exit 2;; esac\n"
            % ("%s", str(log)),
            encoding="utf-8",
        )
        helper.chmod(0o755)
        p = self._run_add_with_firewall_helper(helper)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("TCP/UDP 已自动放行", p.stdout)
        self.assertIn("SSR 服务状态：未执行重启", p.stdout)
        self.assertEqual(log.read_text().strip(), "allow 2444")
        self.assertEqual(self.load()["port_password"]["2444"], "new-secret")

    def test_add_user_aborts_when_active_firewall_allow_fails(self):
        self.run_cli("mode", "multi")
        helper = pathlib.Path(self.tmp.name) / "firewall-helper.sh"
        helper.write_text("#!/bin/sh\necho 'mock firewall failure' >&2\nexit 2\n", encoding="utf-8")
        helper.chmod(0o755)
        before = self.load()
        p = self._run_add_with_firewall_helper(helper)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("防火墙自动放行失败", p.stderr)
        self.assertEqual(self.load(), before)

    def test_add_user_continues_when_no_supported_firewall_is_active(self):
        self.run_cli("mode", "multi")
        helper = pathlib.Path(self.tmp.name) / "firewall-helper.sh"
        helper.write_text("#!/bin/sh\necho 'no active firewall'\nexit 3\n", encoding="utf-8")
        helper.chmod(0o755)
        p = self._run_add_with_firewall_helper(helper)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("未自动放行", p.stdout)
        self.assertIn("手动检查 VPS 防火墙", p.stdout)
        self.assertEqual(self.load()["port_password"]["2444"], "new-secret")

    def test_restart_failure_rolls_back_new_firewall_rule(self):
        self.run_cli("mode", "multi")
        helper = pathlib.Path(self.tmp.name) / "firewall-helper.sh"
        log = pathlib.Path(self.tmp.name) / "firewall.log"
        helper.write_text(
            "#!/bin/sh\n"
            "printf '%s\\n' \"$*\" >> \"%s\"\n"
            "exit 0\n" % ("%s", str(log)),
            encoding="utf-8",
        )
        helper.chmod(0o755)
        bindir = pathlib.Path(self.tmp.name) / "bin"
        bindir.mkdir()
        state = pathlib.Path(self.tmp.name) / "restart-state"
        systemctl = bindir / "systemctl"
        systemctl.write_text(
            "#!/bin/sh\n"
            "cmd=$1\n"
            'case "$cmd" in\n'
            "  cat) exit 0 ;;\n"
            '  restart) if [ ! -f "$FAKE_STATE" ]; then touch "$FAKE_STATE"; exit 1; fi; exit 0 ;;\n'
            '  is-active) [ -f "$FAKE_STATE" ] && exit 0 || exit 1 ;;\n'
            "esac\n"
            "exit 0\n",
            encoding="utf-8",
        )
        systemctl.chmod(0o755)
        env = os.environ.copy()
        env.pop("SSR_SKIP_FIREWALL", None)
        env.pop("SSR_SKIP_SYSTEMCTL", None)
        env["SSR_FIREWALL_HELPER"] = str(helper)
        env["FAKE_STATE"] = str(state)
        env["PATH"] = str(bindir) + os.pathsep + env.get("PATH", "")
        p = subprocess.run(
            [sys.executable, str(CONFIG), "add-user", "2444", "new-secret", "--file", str(self.path)],
            env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.assertNotEqual(p.returncode, 0)
        self.assertNotIn("2444", self.load()["port_password"])
        self.assertEqual(log.read_text().splitlines(), ["allow 2444", "remove 2444"])


if __name__ == "__main__":
    unittest.main()
