# Tez

English · [简体中文](README_zh-CN.md)

A native macOS proxy client. SwiftUI and AppKit power the interface, Rust manages configurations and connections, and Mihomo handles proxy traffic.

[Download](https://github.com/Strugg1e/Tez/releases/latest) · [Changelog](Changelog.md) · [Build Guide](native/README.md)

## Install

**Apple Silicon, macOS 14 or later.**

1. Download the Apple Silicon ZIP from the [latest release](https://github.com/Strugg1e/Tez/releases/latest).
2. Extract the archive and move `Tez.app` to Applications.
3. Open Tez, configure the background service on the Connection page, and add a subscription or local configuration.

Each release includes `SHA256SUMS.txt` for verification.

## Features

| Page | Tasks |
| --- | --- |
| Connection | System proxy, PAC, TUN, routing mode, core controls, process protection, and transport protection |
| Routes | Policy groups, node search, latency sampling, route comparison, and proxy chains |
| Profiles | Subscription import and updates, local YAML editing, activation, and ordering |
| Activity | Source applications and processes, matched rules, actual outbound routes, rules, and logs |
| Settings | Ports, DNS, appearance, shortcuts, local backups, and WebDAV backups |

The Routes page separates the active route from the preview target and supports holding latency readings. Activity places the source, rule, and outbound route together for each connection.

The interface supports light and dark appearance, compact windows, and reduced motion. Maintenance tools and less frequent options sit inside disclosure sections.

### Runtime Protection

Connection → Core and Service has two independent switches. Process protection runs a temporary core copy. Transport protection adds Chrome-style TLS handshakes to compatible nodes while retaining existing fingerprints. Node coverage and DNS configuration checks appear alongside the switches.

Both protections start off and last for the current core session. Apply changes together with one restart confirmation. Hover over either switch for its principle and scope.

## Development

See the [native build guide](native/README.md) for build, packaging, and test commands, and [CONTRIBUTING.md](CONTRIBUTING.md) for contributions.

| Directory | Contents |
| --- | --- |
| `native/Sources/TezNative` | SwiftUI/AppKit interface, components, and motion |
| `src-tauri/src` | Rust configuration, subscription, connection, and lifecycle management |
| `native/core-service` | Core service and session management |
| `native/backend-wire` | Local bridge protocol |
| `native/Tests` | Native UI and connection tests |
| `src` | React/Tauri client and frontend resources |
| `crates` | Shared Rust modules |

See [PRIVACY.md](PRIVACY.md) for local storage and network connections.

## Open Source

Tez builds on [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev) and is licensed under [GPL-3.0-only](LICENSE).

Thanks to the authors of [Mihomo](https://github.com/MetaCubeX/mihomo), [Tauri](https://github.com/tauri-apps/tauri), and the project's dependencies.
