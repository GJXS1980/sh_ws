import json
import os
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "modules"))
import connection


class ConnectionTests(unittest.TestCase):
    def test_split_ipv4_ipv6_endpoints(self):
        self.assertEqual(connection.split_endpoint("203.0.113.9:52341"), ("203.0.113.9", "52341"))
        self.assertEqual(connection.split_endpoint("[2001:db8::1]:52341"), ("2001:db8::1", "52341"))
        self.assertEqual(connection.normal_ip("::ffff:203.0.113.9"), "203.0.113.9")

    def test_geo_cache_prevents_second_external_lookup(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache = pathlib.Path(tmp) / "geo.json"
            with mock.patch.dict(os.environ, {"SSR_GEO_CACHE": str(cache)}):
                with mock.patch.object(connection, "geo_lookup_one", return_value="Example City, Region, Country") as lookup:
                    first = connection.geo_batch(["8.8.8.8"])
                    self.assertEqual(first["8.8.8.8"], "Example City, Region, Country")
                    self.assertEqual(lookup.call_count, 1)
                with mock.patch.object(connection, "geo_lookup_one") as lookup2:
                    second = connection.geo_batch(["8.8.8.8"])
                    self.assertEqual(second["8.8.8.8"], "Example City, Region, Country")
                    lookup2.assert_not_called()

    def test_private_addresses_are_not_sent_to_provider(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache = pathlib.Path(tmp) / "geo.json"
            with mock.patch.dict(os.environ, {"SSR_GEO_CACHE": str(cache)}):
                with mock.patch.object(connection, "geo_lookup_one") as lookup:
                    result = connection.geo_batch(["192.168.1.10"])
                    self.assertEqual(result["192.168.1.10"], "非公网地址")
                    lookup.assert_not_called()


if __name__ == "__main__":
    unittest.main()
