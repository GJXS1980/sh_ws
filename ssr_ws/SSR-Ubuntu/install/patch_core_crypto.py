#!/usr/bin/env python3
"""OpenSSL 3 compatibility patch for the pinned SSR manyuser core.

The patch keeps the upstream SSR protocol implementation intact. It only:
- loads and retains OpenSSL default/legacy providers when the provider API exists;
- loads the legacy provider before RC4 cipher lookup;
- makes EVP_CIPHER_CTX cleanup idempotent and safe across OpenSSL versions.

Every source anchor must match exactly once. Unknown upstream layouts are rejected.
"""
from pathlib import Path


def patch_openssl3(core: Path) -> str:
    path = core / "shadowsocks/crypto/openssl.py"
    source = path.read_text(encoding="utf-8")
    marker = "# SSR-UBUNTU OpenSSL 3 RC4/provider and context-lifecycle patch"
    if marker in source:
        return "already-patched"

    def replace_once(old: str, new: str, label: str) -> None:
        nonlocal source
        count = source.count(old)
        if count != 1:
            raise RuntimeError("%s: 预期匹配一次，实际匹配 %d 次" % (label, count))
        source = source.replace(old, new, 1)

    replace_once(
        "from ctypes import c_char_p, c_int, c_long, byref,\\\n"
        "    create_string_buffer, c_void_p\n",
        "import threading\n\n"
        "from ctypes import c_char_p, c_int, c_long, byref,\\\n"
        "    create_string_buffer, c_void_p\n",
        "导入 threading",
    )
    replace_once(
        "libcrypto = None\nloaded = False\n",
        "libcrypto = None\nloaded = False\n\n"
        + marker + "\n"
        "_provider_handles = []\n"
        "_provider_lock = threading.Lock()\n"
        "_legacy_provider = None\n",
        "Provider 生命周期管理",
    )
    replace_once(
        "    if hasattr(libcrypto, 'OpenSSL_add_all_ciphers'):\n",
        "    # OpenSSL 3: explicitly retain the default provider.\n"
        "    # Loading another provider can otherwise prevent automatic default loading.\n"
        "    if hasattr(libcrypto, 'OSSL_PROVIDER_load'):\n"
        "        libcrypto.OSSL_PROVIDER_load.argtypes = (c_void_p, c_char_p)\n"
        "        libcrypto.OSSL_PROVIDER_load.restype = c_void_p\n\n"
        "        default_provider = libcrypto.OSSL_PROVIDER_load(None, b'default')\n"
        "        if not default_provider:\n"
        "            raise Exception('cannot load OpenSSL default provider')\n"
        "        _provider_handles.append(default_provider)\n\n"
        "    if hasattr(libcrypto, 'OpenSSL_add_all_ciphers'):\n",
        "加载 OpenSSL default Provider",
    )
    replace_once(
        "def rand_bytes(length):\n",
        "def load_legacy_provider():\n"
        "    global _legacy_provider\n\n"
        "    if not loaded:\n"
        "        load_openssl()\n\n"
        "    # OpenSSL 1.1 and earlier do not have the provider API.\n"
        "    if not hasattr(libcrypto, 'OSSL_PROVIDER_load'):\n"
        "        return\n\n"
        "    with _provider_lock:\n"
        "        if _legacy_provider is None:\n"
        "            provider = libcrypto.OSSL_PROVIDER_load(None, b'legacy')\n"
        "            if not provider:\n"
        "                raise Exception('cannot load OpenSSL legacy provider for RC4')\n"
        "            # Keep the provider loaded for the lifetime of the process.\n"
        "            _provider_handles.append(provider)\n"
        "            _legacy_provider = provider\n\n\n"
        "def rand_bytes(length):\n",
        "增加 Legacy Provider 加载函数",
    )
    replace_once(
        "        if not loaded:\n"
        "            load_openssl()\n"
        "        cipher = libcrypto.EVP_get_cipherbyname(common.to_bytes(cipher_name))\n",
        "        if not loaded:\n"
        "            load_openssl()\n\n"
        "        # SSR rc4 and rc4-md5 both use the underlying RC4 cipher.\n"
        "        if common.to_str(cipher_name).lower() == 'rc4':\n"
        "            load_legacy_provider()\n\n"
        "        cipher = libcrypto.EVP_get_cipherbyname(common.to_bytes(cipher_name))\n",
        "RC4 初始化前加载 Legacy Provider",
    )
    replace_once(
        "    def clean(self):\n"
        "        if self._ctx:\n"
        "            if hasattr(libcrypto, \"EVP_CIPHER_CTX_cleanup\"):\n"
        "                libcrypto.EVP_CIPHER_CTX_cleanup(self._ctx)\n"
        "            else:\n"
        "                libcrypto.EVP_CIPHER_CTX_reset(self._ctx)\n"
        "            libcrypto.EVP_CIPHER_CTX_free(self._ctx)\n",
        "    def clean(self):\n"
        "        ctx = self._ctx\n"
        "        if not ctx:\n"
        "            return\n\n"
        "        # Clear the pointer first to make cleanup idempotent.\n"
        "        self._ctx = None\n"
        "        try:\n"
        "            if hasattr(libcrypto, \"EVP_CIPHER_CTX_cleanup\"):\n"
        "                libcrypto.EVP_CIPHER_CTX_cleanup(ctx)\n"
        "            else:\n"
        "                libcrypto.EVP_CIPHER_CTX_reset(ctx)\n"
        "        finally:\n"
        "            libcrypto.EVP_CIPHER_CTX_free(ctx)\n",
        "修复 EVP 上下文重复释放",
    )

    # Write only after every anchor has matched successfully.
    path.write_text(source, encoding="utf-8")
    return "openssl3-provider-and-context-lifecycle-patched"
