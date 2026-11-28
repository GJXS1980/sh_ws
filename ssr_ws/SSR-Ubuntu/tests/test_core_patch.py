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
import patch_core_crypto

OPENSSL_FIXTURE = (
    "from ctypes import c_char_p, c_int, c_long, byref,\\\n"
    "    create_string_buffer, c_void_p\n"
    "libcrypto = None\nloaded = False\n"
    "def load_openssl():\n"
    "    if hasattr(libcrypto, 'OpenSSL_add_all_ciphers'):\n"
    "        pass\n"
    "def rand_bytes(length):\n"
    "    return None\n"
    "class Cipher:\n"
    "    def __init__(self, cipher_name):\n"
    "        if not loaded:\n"
    "            load_openssl()\n"
    "        cipher = libcrypto.EVP_get_cipherbyname(common.to_bytes(cipher_name))\n"
    "    def clean(self):\n"
    "        if self._ctx:\n"
    "            if hasattr(libcrypto, \"EVP_CIPHER_CTX_cleanup\"):\n"
    "                libcrypto.EVP_CIPHER_CTX_cleanup(self._ctx)\n"
    "            else:\n"
    "                libcrypto.EVP_CIPHER_CTX_reset(self._ctx)\n"
    "            libcrypto.EVP_CIPHER_CTX_free(self._ctx)\n"
)


class CorePatchTests(unittest.TestCase):
    def make_core(self, root):
        (root / "shadowsocks/crypto").mkdir(parents=True)
        (root / "shadowsocks/server.py").write_text(core_install.OLD_LOG + "\n", encoding="utf-8")
        (root / "shadowsocks/crypto/openssl.py").write_text(OPENSSL_FIXTURE, encoding="utf-8")

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

    def test_openssl3_patch_is_exact_and_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            self.make_core(root)
            state = patch_core_crypto.patch_openssl3(root)
            patched = (root / "shadowsocks/crypto/openssl.py").read_text(encoding="utf-8")
            self.assertEqual(state, "openssl3-provider-and-context-lifecycle-patched")
            self.assertIn("OSSL_PROVIDER_load(None, b'default')", patched)
            self.assertIn("OSSL_PROVIDER_load(None, b'legacy')", patched)
            self.assertIn("self._ctx = None", patched)
            compile(patched, "openssl.py", "exec")
            self.assertEqual(patch_core_crypto.patch_openssl3(root), "already-patched")

    def test_openssl3_patch_rejects_unknown_layout_without_partial_write(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            (root / "shadowsocks/crypto").mkdir(parents=True)
            source = "# unknown OpenSSL source\n"
            target = root / "shadowsocks/crypto/openssl.py"
            target.write_text(source, encoding="utf-8")
            with self.assertRaises(RuntimeError):
                patch_core_crypto.patch_openssl3(root)
            self.assertEqual(target.read_text(encoding="utf-8"), source)

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
                    if name == "shadowsocks/server.py":
                        content = core_install.OLD_LOG + "\n"
                    elif name == "shadowsocks/crypto/openssl.py":
                        content = OPENSSL_FIXTURE
                    else:
                        content = "# fixture\n"
                    zf.writestr(core_root + name, content)
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            dest = root / "installed-core"
            p = subprocess.run([sys.executable, str(ROOT / "install" / "core_install.py"), "--archive", str(archive), "--commit", commit, "--sha256", digest, "--destination", str(dest)], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            metadata = json.loads((dest / "SSR-UBUNTU-CORE-METADATA.json").read_text(encoding="utf-8"))
            self.assertEqual(metadata["commit"], commit)
            self.assertEqual(metadata["archive_sha256"], digest)
            self.assertEqual(metadata["package_version"], "2.6.12")
            self.assertEqual(len(metadata["patches"]), 2)
            self.assertIn("password [REDACTED]", (dest / "shadowsocks" / "server.py").read_text(encoding="utf-8"))
            self.assertIn("OSSL_PROVIDER_load", (dest / "shadowsocks/crypto/openssl.py").read_text(encoding="utf-8"))

    def test_archive_hash_mismatch_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = pathlib.Path(tmp) / ("shadowsocksr-" + pathlib.Path(tmp).name + ".zip")
            archive.write_bytes(b"not a real archive")
            p = subprocess.run([sys.executable, str(ROOT / "install" / "core_install.py"), "--archive", str(archive), "--commit", "a" * 40, "--sha256", "0" * 64, "--destination", str(pathlib.Path(tmp) / "dest")], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertNotEqual(p.returncode, 0)
            self.assertIn("SHA256 不匹配", p.stdout + p.stderr)


if __name__ == "__main__":
    unittest.main()
