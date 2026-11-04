# Contributing to Tez

Issues and pull requests are welcome. Use [Issues](https://github.com/Strugg1e/Tez/issues) for bug reports and feature requests.

## Development Setup

The [native build guide](native/README.md) covers the SwiftUI/AppKit application, managed Rust host, core service, packaging, and tests.

| Area | Source |
| --- | --- |
| Native interface | `native/Sources/TezNative` |
| Native tests | `native/Tests` |
| Configuration and lifecycle | `src-tauri/src` |
| Core service | `native/core-service` |
| Bridge codec | `native/backend-wire` |
| React/Tauri client | `src` |
| Shared modules | `crates` |

For the React/Tauri client:

```sh
pnpm install --frozen-lockfile
pnpm prebuild
pnpm dev
```

Translation bundles and their tooling are described in [the localization guide](docs/CONTRIBUTING_i18n.md).

## Contribution Expectations

- Link an existing issue for product features and bug fixes.
- Keep each pull request focused on one outcome.
- Describe the problem, approach, and affected workflows.
- Include reproduction steps and the checks you ran.
- Do not pad changes with unrelated tests, refactors, or formatting.
- Use English Conventional Commit subjects, such as `fix(native): retain route selection`.
- Include screenshots for interface changes.
- Agents append an `Assisted by:` line to issues and pull requests they create, following [AGENTS.md](AGENTS.md).

## Checks

Run the checks for the affected code:

```sh
# Native host
cargo test --locked -p tez --features native-host --lib native_

# Core service
cargo test --locked --manifest-path native/core-service/Cargo.toml \
  --features standalone,client,test --lib

# React frontend
pnpm typecheck
pnpm test
pnpm lint

# Generated frontend contract
node scripts/gen-contract.mjs --check
```

Native UI scripts are listed in [native/README.md](native/README.md). Use the scripts for the views and interactions changed by the pull request.

## Pull Requests

Fill in the [pull request template](.github/PULL_REQUEST_TEMPLATE.md) with the problem, approach, and scope. Reference the affected page or module and include the relevant test results.
