import ast
import hashlib
import pathlib
import re
import subprocess
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class PackagingTests(unittest.TestCase):
    def test_uploaded_original_copy_matches_recorded_sha256(self):
        sums = (ROOT / "original" / "SHA256SUMS").read_text(encoding="utf-8").strip().split()
        expected, relpath = sums[0], sums[1]
        target = ROOT / relpath
        self.assertTrue(target.is_file())
        self.assertEqual(hashlib.sha256(target.read_bytes()).hexdigest(), expected)

    def test_original_version_and_main_menu_are_present(self):
        original = (ROOT / "original" / "ssr.sh.v2.0.38").read_text(encoding="utf-8")
        manager = (ROOT / "ssr.sh").read_text(encoding="utf-8")
        self.assertIn('sh_ver="2.0.38"', original)
        self.assertIn('1. 安装 ShadowsocksR', manager)
        for n in range(1, 16):
            self.assertRegex(manager, re.compile(r"(?m)^\s*%d\." % n))

    def test_manager_python_modules_parse_as_python_38(self):
        for rel in ("modules/config.py", "modules/link.py", "modules/connection.py", "install/core_install.py", "install/patch_core_crypto.py"):
            source = (ROOT / rel).read_text(encoding="utf-8")
            ast.parse(source, filename=rel, feature_version=(3, 8))

    def test_no_unsafe_remote_shell_or_firewall_flush_in_runtime_code(self):
        scan = [ROOT / "ssr.sh", *ROOT.glob("install/*.sh"), *ROOT.glob("modules/*.sh"), *ROOT.glob("migration/*.sh"), ROOT / "uninstall/uninstall.sh"]
        for path in scan:
            content = path.read_text(encoding="utf-8")
            self.assertNotIn("--no-check-certificate", content, str(path))
            self.assertNotRegex(content, r"(?i)\biptables\s+-F\b", str(path))
            self.assertNotRegex(content, r"(?i)\bnft\s+flush\s+ruleset\b", str(path))
            self.assertNotRegex(content, r"(?m)curl[^\n]*\|\s*(ba)?sh", str(path))

    def test_required_delivery_files_exist(self):
        required = [
            "ssr.sh", "install.sh", "README.md", "CHANGELOG.md", "install/install.sh",
            "install/dependencies.sh", "install/core_install.py", "install/patch_core_crypto.py",
            "install/prepare-core-archive.sh", "modules/config.py",
            "modules/link.py", "modules/connection.py", "modules/firewall.sh",
            "modules/bbr.sh", "modules/qr.sh", "modules/service.sh", "modules/log.sh",
            "service/ssr.service", "uninstall/uninstall.sh", "migration/detect.sh",
            "migration/backup.sh", "migration/migrate.sh", "migration/rollback.sh",
            "reports/source-audit.md", "reports/compatibility.md", "reports/test-report.md",
            "reports/delivery-status.md", "core/CORE_PIN_STATUS.md",
        ]
        for rel in required:
            self.assertTrue((ROOT / rel).is_file(), rel)

    def test_core_lock_contains_the_verified_commit_and_archive_hash(self):
        lock = (ROOT / "core/CORE.lock").read_text(encoding="utf-8")
        self.assertIn("CORE_COMMIT=046078c9568bee891f0ac74085ee82fc08e99e3e", lock)
        self.assertIn("CORE_SHA256=32a5a0fe14749f34f14859660f29e2bf10bc0a9deb3b278a55d4b42154b2de40", lock)
        self.assertIn("CORE_CLIENT_COMPATIBILITY=NOT_TESTED_END_TO_END", lock)

    def test_manager_version_and_one_click_installer_are_present(self):
        p = subprocess.run(["bash", str(ROOT / "ssr.sh"), "--version"], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.strip(), (ROOT / "VERSION").read_text(encoding="utf-8").strip())
        installer = (ROOT / "install.sh").read_text(encoding="utf-8")
        self.assertIn("CORE_COMMIT", installer)
        self.assertIn("CORE_SHA256", installer)
        self.assertIn("prepare-core-archive.sh", installer)
        self.assertIn("bash \"$ROOT/install/install.sh\"", installer)


if __name__ == "__main__":
    unittest.main()
