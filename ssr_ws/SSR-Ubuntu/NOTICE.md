# Third-party notices and source provenance

## Original management script

`original/ssr.sh.v2.0.38` is a byte-for-byte copy of the file uploaded by the user for this project. Its SHA256 is recorded in `original/SHA256SUMS`. The source header identifies version 2.0.38 and author Toyo.

## ShadowsocksR manyuser core

The SSR core is **not bundled** in this source package. The user-specified candidate source is <https://github.com/ssrlive/shadowsocksr/tree/manyuser>; its README also names <https://github.com/ShadowsocksR-Live/shadowsocksr.git> as the clone URL. The visible source identifies Apache-2.0 licensing; retain upstream LICENSE and copyright notices when redistributing the core.

The core installer accepts only a caller-supplied archive whose commit identifier, top-level directory, package version, and SHA256 meet its checks. The archive SHA256 must be independently recorded by the operator. The exact commit and archive hash are still unverified because this build environment cannot resolve GitHub Git transport. The new source candidate has not yet been diffed byte-for-byte against the historical Toyo backup repository or tested with the original client.

## New manager code

No separate redistribution license is asserted for the new manager code in this delivery. Review and assign a project license before public redistribution.
