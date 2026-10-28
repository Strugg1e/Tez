# Native feature status

This is a workflow-level assessment, not a release approval. “Implemented”
means an entry and a backend path exist; it does not imply production acceptance.
`parity.json` remains the authoritative release inventory. Its pending entries
include both missing functionality and functionality without complete evidence.
This assessment covers the 16 listed workflows. It does not classify every
individual command, event or platform-specific inventory entry.

| Workflow | Implementation | Verification and remaining work |
| --- | --- | --- |
| Core lifecycle, proxy, TUN and mode | Partial: native controls and managed backend | Isolated Core and earlier limited live checks exist. Full service ownership, failures and restart persistence are not accepted. |
| Route read, select and persistence | Partial: native route view, selection and persistence | Isolated real-Core writes passed; full provider, chain and live service behavior is not accepted. |
| Route latency and providers | Partial: individual latency and provider views | One live node was tested in an earlier session. Additional nodes were not tested in this session. Group and provider coverage remains incomplete. |
| Profiles, subscriptions and scheduler | Partial: import, edit, activate and update controls | Production transactions and the default scheduler passed with an isolated Core. Current service-mode staging and native end-to-end scheduling are unverified. |
| Enhancement chains | Partial: profile content editor and existing backend enhancement pipeline | Native management of merge, script, rules, proxy and group enhancement chains is not implemented. Validation and rollback are not fully accepted. |
| Migration | Native workflow not implemented | Legacy discovery and migration code exists separately. Native confirmation, independent copy and undo are unverified. |
| Connections and activity | Partial: read-only connection, rule and provider views | Closing individual or all connections and full traffic/memory stream parity are not implemented. |
| Logs | Partial: bounded real-time stream, filtering and export | Burst and isolated Core tests passed. Sustained live service-mode equivalence and reconnection gaps are not accepted. |
| Rule providers | Partial: read-only view | Provider update and management are not fully implemented or accepted. |
| Media unlock | Native workflow not implemented | No native management or acceptance evidence. |
| Settings and DNS | Partial: network and DNS controls | Isolated settings and draft checks passed. Full field coverage, production network effects and restoration remain unverified. |
| Local backups | Implemented: create, list, delete, import, export and restore controls | Isolated production-backend tests verified import/export, changed-data restore, pre-restore backup and invalid input rejection. The mock native UI verified pickers, confirmation and feedback. Real service-mode effects and failure recovery remain unverified. |
| WebDAV backups | Implemented: configuration, list, upload, deletion and restore controls | Local HTTP fixture tests verified authentication, upload, list, restore, delete and credential preservation. An untrusted local HTTPS certificate was rejected before an HTTP request. The mock UI verified settings and restore confirmation. Real WebDAV servers and service-mode effects remain unverified. |
| Core upgrade and service repair | Native workflow not implemented | Native controls and safe failure/recovery checks are outstanding. |
| Notifications, reconnection and tray | Partial: native tray and snapshots | Event completeness, reconnection, sleep/wake and global shortcuts are not fully accepted. |
| Installation, upgrade and rollback | Separate candidate packaging exists | Single final app identity, migration, upgrade and rollback are not fully accepted. No replacement is authorized until the release gate passes. |

Evidence: [acceptance-2026-10-28.md](acceptance-2026-10-28.md),
[wire-protocol.md](wire-protocol.md), the native Swift views and the managed
command allowlist in `src-tauri/src/native_workspace.rs`.
