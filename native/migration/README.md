# Full native migration

## Delivery decision

The user requires all existing macOS functionality to migrate before replacing
the current Tez application. Intermediate native builds remain separately named
development artifacts. Passing a visual review is not functional acceptance.

The existing Tauri application remains the primary client. Do not overwrite its
bundle, activate another core, change its service owner, or migrate its data merely
to demonstrate native UI progress. No replacement has been performed.

## Scope and boundaries

| Native destination | Existing capabilities to preserve |
| --- | --- |
| Connection | Lifecycle, system proxy, PAC, TUN, mode, traffic, health, actionable failures |
| Routes | Dynamic groups, providers, sorting, search, delay, selection, persistence, tray synchronization, proxy chains |
| Profiles | Local/remote profiles, import, update scheduling, ordering, editors, merge/script/rule/group enhancements, validation, rollback |
| Migration | Read-only discovery, confirmation, script acknowledgment, independent copy, no automatic activation, undo |
| Activity | Live connections, close actions, traffic/memory streams, logs, rules/providers, media-unlock checks |
| Settings | DNS, ports, interface, TUN stack, controller, core upgrades, service repair/fallback, startup, shortcuts, tray, appearance, backups/WebDAV |
| Application lifecycle | Single backend ownership, reconnect, notification replay, cancellation, persistence, install/upgrade/rollback |

Mihomo REST endpoints do not replace the Rust client's configuration transactions,
subscription persistence, enhancement pipeline, service ownership, or rollback.
Do not create a second Swift implementation of those policies.

Target boundary:

```text
SwiftUI / AppKit presentation
        |
typed local request + snapshot events (explicit read-only attach supervisor implemented)
        |
existing Rust configuration, effects and lifecycle ownership
        |
Mihomo + privileged service
```

The adapter uses a separate, explicitly invoked `tez-native-host` binary and
inherited stdin/stdout pipes. Legacy `--stdio` retains the two-command proof.
`--stdio --attach` additionally provides read-only snapshots and subscription
control, with a bounded polling loop. It does not enter normal Tez startup,
initialize configuration, or start the core. See [the wire contract](wire-protocol.md)
and [the backend investigation](backend-boundary.md).

An experimental `--stdio --managed` runtime and mutation adapters now exist,
but managed activation is not exposed by the Swift preview. Own bundled resources
and Swift graceful shutdown passed isolated real-core checks. Production
CoreManager lifecycle and full configuration transaction acceptance remain pending.
Tauri invoke bindings are not directly callable from Swift. A controller-port-only
client is not the agreed migration.
Preserve command failure codes, event versions, lock ordering, persistent state,
and already-applied effects when a later operation fails. Authentication and
single-instance ownership must be established before exposing a local transport.

## Executable baseline

From the repository root:

```sh
node scripts/check-native-parity.mjs --check
node scripts/check-native-parity.mjs --release
```

The first command checks inventory coverage, not implementation completeness.
The second deliberately fails while any obligation is pending. It is a migration
preflight, not an installer or an automatic deployment gate. The preview build
remains available for development and does not replace the current app.

The inventory uses the TypeScript parser to read generated Tauri commands and
event names plus runtime Mihomo imports. Workflows add cross-command user paths.
It is a baseline, not proof of exhaustive setting-field or behavior coverage.
Review field-level settings and platform applicability during each migration.
Windows-only operations such as UWP require an explicit macOS applicability
record rather than a fake native implementation. Existing unavailable application
updates remain unavailable until release infrastructure exists.

`--sync` refreshes the baseline. A changed generated contract resets acceptance
to pending. New obligations start pending. It never marks work verified. Review
the resulting diff, including removed obligations. A verified entry requires
repository-relative evidence files; their existence is not proof of correctness.
Manual review must confirm that those files demonstrate real behavior, failure
paths, and persistence rather than fixtures.

## Acceptance order

1. Establish the reusable backend boundary and safe standalone packaging.
2. Implement typed request/event transport with disconnect and error handling.
3. Migrate all pages and advanced settings against the baseline.
4. Verify reads, writes, restart persistence, failure recovery and cancellation.
5. Verify service ownership, migration rollback, keyboard/accessibility and materials.
6. Approve one full native candidate before any replacement of the current app.

Current status: native configuration metadata and route pages consume real read-only
snapshots from the bundled host. Local controller reads reuse the existing Mihomo
client and ProxyViewBuilder; profile reads directly decode the existing IProfiles
schema without its mutating initializer. Changes produce snapshot events, not
legacy Tauri mutation events. Full feature migration remains incomplete; editing,
activation, lifecycle ownership and activity streams are not accepted yet.

The isolated integration runner `node scripts/test-native-attach.mjs <host>` checks
the actual host against temporary YAML and a fake Unix controller: data projection,
changes, subscribe/unsubscribe, monotonic events, mutation rejection, secret omission,
and EOF exit. Native process checks are in `native/test-backend-connection.sh`.
On-device profile reading and compact/standard native layouts were checked.
The controller endpoint mismatch was fixed on 2026-10-27: authenticated service
discovery now selects the live service socket instead of the stale sidecar socket.
The rebuilt preview displayed 248 real route members and the current profile.
Profile editing, route selection and core controls are wired to capability-gated
commands, and were visibly disabled in this read-only session. No live mutation
was attempted. The three existing configuration file hashes remained unchanged.
See [controller diagnosis](controller-diagnosis.md),
[managed runtime boundaries](managed-runtime-boundary.md), and
[this increment's validation](validation-2026-10-27.md).
