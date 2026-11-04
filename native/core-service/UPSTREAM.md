# Tez Core Service

Based on [clash-verge-service-ipc](https://github.com/clash-verge-rev/clash-verge-service-ipc) v2.7.6, commit `b2a7427d6681c8d3780ab83a73f4dc21da2f22d6`, under the [GPL-3.0 license](LICENSE).

## Tez Integration

| Surface | Value |
| --- | --- |
| macOS service identifier | `app.tez.service` |
| Executable | `tez-service` |
| Controller socket | `/var/run/tez-service/service.sock` |
| Protocol | 2.6 |

The extension adds owner sessions, runtime staging, recovery, compare-and-claim control, verified core upgrades with rollback, and session-only protection. Explicit capability fields advertise the supported extensions.

## Tests

The `test` feature uses isolated state and excludes system-proxy effects. `TEZ_SERVICE_TEST_ROOT` selects a private acceptance directory containing the sockets, state, and execution lock. The acceptance channel uses its own service identifier and paths.

Build, packaging, and test commands are in [the native guide](../README.md).
