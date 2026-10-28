# Tez

Tez is an independent desktop network client built with React, Tauri and Mihomo.
This repository is a local development fork, not an official upstream release.

## Development

Install the versions recorded in `package.json` and `rust-toolchain.toml`.

```sh
pnpm install --frozen-lockfile
pnpm web:build
pnpm tauri build --debug --bundles app
```

Sidecar binaries and geographic databases are build prerequisites. The local
checkout uses copies of the previously downloaded upstream build resources.
The source repository and these resources are separate from `tez-prototype`.

## Product Identity

- Product and executable: `Tez` / `tez`.
- Version: `0.1.0`.
- Bundle identifier: `app.tez.client`.
- Independent application-data directory and `tez.yaml` preferences.
- URL scheme: `tez://`.
- No upstream client updater endpoints or signing key.
- Original proxy configuration schema and command/event contracts are retained.

Client updates remain unavailable until Tez has its own release server and
signing keys. Core updates, subscription updates and provider updates retain
their existing implementations.

## Implementation Boundary

The first integrated version replaces the main shell, connection workflow,
profile list/detail layout and settings navigation. Routes, profiles, live connections, logs, diagnostics and
service checks use the original backend APIs rather than prototype data.
The detailed editors and advanced management controls remain available.

When Tez has no subscription or local profile, the connection page automatically
scans known local client data directories. The Profiles page also offers a manual
scan. Scanning is read-only; copying requires confirmation. Linked enhancement
files and node selections are preserved, while automatic subscription updates
are paused and no profile is activated. Scripts require a separate acknowledgment:
they are copied, not executed by migration, but can run during later startup or
profile activation through the existing enhancement pipeline.

Migration refuses to overwrite an existing Tez profile collection. It backs up
the previous index, writes copied files under new names and atomically replaces
the index. Undo is available only while the imported index and files are unchanged.
It restores the previous index without deleting either copy. No system-proxy,
TUN, DNS, core or service settings are imported.

Upstream crate/module names, the service IPC protocol, helper binary filenames
and third-party dependency URLs are compatibility identifiers, not Tez branding.
The privileged service package has **not** been independently renamed or audited.
Windows and Linux installers have not been validated as Tez distributions.
Do not distribute this development build as a finished cross-platform release.
Do not launch it alongside an active upstream proxy client: service ownership
and system-proxy behavior are not yet isolated for concurrent use.
Local macOS builds use ad-hoc signing, not Apple notarization or a distribution certificate.

## License And Provenance

Tez derives from [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev),
baseline commit `eefd0258`, and remains licensed under **GPL-3.0-only**.
The original license, copyright notices, authors and Git history are retained.
Mihomo and other dependencies retain their respective licenses.
See [LICENSE](LICENSE) and the in-app open-source acknowledgments.
