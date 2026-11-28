import base64
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "modules"))
import link


def old_b64(value):
    return base64.b64encode(value.encode()).decode().replace("\n", "").replace("=", "").replace("+", "-").replace("/", "_")


class LinkTests(unittest.TestCase):
    def test_urlsafe_matches_legacy_shell_pipeline(self):
        for value in ("aes-128-ctr:secret@203.0.113.5:2333", "203.0.113.5:2333:auth_sha1_v4:aes-128-ctr:plain:c2VjcmV0"):
            self.assertEqual(link.b64url(value), old_b64(value))

    def test_ssr_link_matches_legacy_payload(self):
        password = "secret"
        inner = old_b64(password)
        raw = "203.0.113.5:2333:auth_sha1_v4:aes-128-ctr:plain:" + inner
        self.assertEqual(link.make_ssr("203.0.113.5", "2333", password, "aes-128-ctr", "auth_sha1_v4_compatible", "plain"), "ssr://" + old_b64(raw))

    def test_ss_compatibility_rules(self):
        self.assertTrue(link.ss_allowed("origin", "plain"))
        self.assertTrue(link.ss_allowed("origin", "http_simple_compatible"))
        self.assertTrue(link.ss_allowed("auth_sha1_v4_compatible", "plain"))
        self.assertTrue(link.ss_allowed("auth_sha1_v4_compatible", "tls1.2_ticket_auth_compatible"))
        self.assertFalse(link.ss_allowed("auth_sha1_v4", "plain"))
        self.assertFalse(link.ss_allowed("auth_sha1_v4_compatible", "tls1.2_ticket_auth"))

    def test_manyuser_per_port_overrides_are_used_for_links(self):
        cfg = {
            "method": "aes-128-ctr", "protocol": "origin", "obfs": "plain",
            "port_password": {
                "2333": ["pw-list", "http_simple_compatible", "auth_sha1_v4_compatible"],
                "2334": {"password": "pw-dict", "method": "aes-256-ctr", "protocol": "auth_sha1_v4_compatible", "obfs": "tls1.2_ticket_auth_compatible"},
            },
        }
        accounts = link.get_accounts(cfg)
        self.assertEqual(accounts[0], ("2333", "pw-list", "aes-128-ctr", "auth_sha1_v4_compatible", "http_simple_compatible"))
        self.assertEqual(accounts[1], ("2334", "pw-dict", "aes-256-ctr", "auth_sha1_v4_compatible", "tls1.2_ticket_auth_compatible"))


if __name__ == "__main__":
    unittest.main()
