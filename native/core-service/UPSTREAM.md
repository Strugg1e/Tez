# Tez Core Service Extension

Based on clash-verge-service-ipc v2.7.6, commit
`b2a7427d6681c8d3780ab83a73f4dc21da2f22d6` from
https://github.com/clash-verge-rev/clash-verge-service-ipc.
Upstream authorship and GPL-3.0 licensing are preserved. The library name and
legacy routes remain compatible with the installed service during migration.

Protocol 2.6 adds explicit session recovery, compare-and-claim ownership and
verified, separately approved core upgrades with rollback. None of these routes
is called automatically against a running legacy service.

Local modifications: Tez lifecycle, receipt/package clients, digest-bound version
staging and isolated acceptance, 2026-10-29. The extension is advertised for macOS.

The `test` feature disables system-proxy effects. Unit tests retain upstream's
test-only paths. `TEZ_SERVICE_TEST_ROOT` puts acceptance IPC, state and the core
execution lock below one new private directory; production builds ignore it.
Never package or install a test-feature binary.
This source copy does not install, launch or replace a service.
