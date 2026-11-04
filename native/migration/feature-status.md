# Native Feature Map

Swift sources are under `native/Sources/TezNative`; Rust host sources are under `src-tauri/src`.

| Feature | Interface | Backend |
| --- | --- | --- |
| Connection and core controls | `NativeConnectionOverview.swift`, `NativeProxyControls.swift` | `native_control.rs`, `core/manager` |
| Session protection | `NativeSessionProtectionView.swift` | `native_ownership.rs`, `core-service/src/core/session_protection.rs` |
| Route selection and comparison | `NativeRouteWorkspace.swift`, `NativeRouteComparison.swift` | `native_control.rs`, `native_data.rs` |
| Latency sampling | `NativeLatency.swift` | `native_workspace.rs` |
| Proxy chains | `NativeFeatureViews.swift` | `native_chain.rs` |
| Profiles and subscriptions | `NativeSubscriptions.swift`, `NativeProfileEditor.swift` | `native_profile.rs`, `native_workspace.rs` |
| Connections, rules, and providers | `NativeActivityView.swift` | `native_activity.rs`, `native_data.rs` |
| Logs | `NativeActivityView.swift`, `NativeFeatureViews.swift` | `native_logs.rs` |
| Network and DNS settings | `NativeFeatureViews.swift`, `TezSettingsView.swift` | `native_workspace.rs`, `native_proxy.rs` |
| Local and WebDAV backups | `NativeFeatureViews.swift` | `native_backup.rs`, `native_workspace.rs` |
| Core upgrades and service maintenance | `NativeCoreUpgradeView.swift`, `LiveWorkspaceView.swift` | `native_ownership.rs`, `core-service` |
| Menu bar | `NativeMenuBarPanel.swift` | Managed snapshots and control commands |
| Appearance and motion | `TezStyle.swift`, `TezUI.swift`, `TezSettingsView.swift` | Native preferences |

Tests for these workflows are in `native/Tests`, the Rust modules' unit tests, and the isolated lifecycle driver. See [the build guide](../README.md#tests) for commands.
