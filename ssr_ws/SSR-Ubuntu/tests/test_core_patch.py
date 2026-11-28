import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "install"))
import core_install


class CorePatchTests(unittest.TestCase):
    def test_only_startup_password_log_is_redacted(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            (root / "shadowsocks").mkdir()
            server = root / "shadowsocks" / "server.py"
            server.write_text(core_install.OLD_LOG + "\n", encoding="utf-8")
            state = core_install.patch_log(root)
            text = server.read_text(encoding="utf-8")
            self.assertEqual(state, "password-log-redaction-only")
            self.assertIn("password [REDACTED]", text)
            self.assertNotIn("(protocol, password, method, obfs, obfs_param)", text)
            self.assertEqual(core_install.patch_log(root), "already-redacted")

    def test_unknown_source_layout_is_not_patched(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            (root / "shadowsocks").mkdir()
            server = root / "shadowsocks" / "server.py"
            server.write_text("logging.info('unknown source')\n", encoding="utf-8")
            with self.assertRaises(RuntimeError):
                core_install.patch_log(root)

    def test_archive_pin_contract_fixture_installs_and_records_hash(self):
        commit = "a" * 40
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            archive = root / ("shadowsocksr-" + commit + ".zip")
            core_root = "shadowsocksr-" + commit + "/"
            files = list(core_install.REQUIRED)
            with zipfile.ZipFile(archive, "w") as zf:
                zf.writestr(core_root + "setup.py", 'setup(name="shadowsocks", version="2.6.12", install_requires=[])\n')
                for name in files:
                    content = core_install.OLD_LOG + "\n" if name == "shadowsocks/server.py" else "# fixture\n"
                    zf.writestr(core_root + name, content)
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            dest = root / "installed-core"
            p = subprocess.run([sys.executable, str(ROOT / "install" / "core_install.py"), "--archive", str(archive), "--commit", commit, "--sha256", digest, "--destination", str(dest)], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            metadata = json.loads((dest / "SSR-UBUNTU-CORE-METADATA.json").read_text(encoding="utf-8"))
            self.assertEqual(metadata["commit"], commit)
            self.assertEqual(metadata["archive_sha256"], digest)
            self.assertEqual(metadata["package_version"], "2.6.12")
            self.assertIn("password [REDACTED]", (dest / "shadowsocks" / "server.py").read_text(encoding="utf-8"))

    def test_archive_hash_mismatch_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = pathlib.Path(tmp) / ("shadowsocksr-" + pathlib.Path(tmp).name + ".zip")
            archive.write_bytes(b"not a real archive")
            p = subprocess.run([sys.executable, str(ROOT / "install" / "core_install.py"), "--archive", str(archive), "--commit", "a" * 40, "--sha256", "0" * 64, "--destination", str(pathlib.Path(tmp) / "dest")], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertNotEqual(p.returncode, 0)
            self.assertIn("SHA256 不匹配", p.stdout + p.stderr)


if __name__ == "__main__":
    unittest.main()
