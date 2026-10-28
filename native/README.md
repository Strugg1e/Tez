# Tez Native Preview

A standalone SwiftUI/AppKit client under migration. Full replacement of
`../build/Tez.app` remains pending acceptance. The current source defaults to
managed operation: normal launch connects its bundled helper and starts its owned
Core. It can change configurations and system networking. Do not launch it beside
an active owner for inspection, or overwrite a running bundle during development.
General snapshots omit subscription URLs and script bodies. Explicit subscription
and configuration editors load their selected content on request.

The original fixture views are not an alternative production data source. Use the
separate interface-only build or feature fixtures for checks without a Core.

## Build

Requires macOS 14+ and a Swift 6 toolchain:

```sh
TEZ_NATIVE_UI_ONLY=1 TEZ_NATIVE_APP_PATH="$PWD/output.noindex/Tez UI Check.app" bash build-preview.sh
```

The build script does not launch the app. Output is ad-hoc signed, not notarized.
The separate bundle identifier prevents settings and window state from being
shared with the existing client. The output directory uses `.noindex` to keep
this sample out of normal Spotlight indexing.

For managed operation, first build `tez-native-host` with the `native-host` Cargo feature,
then pass its absolute executable path as `TEZ_NATIVE_HOST` to `build-preview.sh`.
The script embeds and signs it under `Contents/Helpers`. A UI-only build removes
any stale embedded helper; connecting then reports the unavailable helper.

Set an explicit `TEZ_NATIVE_APP_PATH` pointing at a non-running candidate bundle.
Set `TEZ_NATIVE_BUNDLE_CORE=1` alongside `TEZ_NATIVE_HOST` to package independent
copies of both local cores and all four databases. `package-core.mjs` checks
architecture, signatures, hashes and symlinks. Packaging does not launch the app.
The default build removes stale core resources; an incomplete bundle cannot start
managed operation.

For developer-only real-write experiments, run
`node scripts/test-native-isolated.mjs ABSOLUTE_BUNDLED_HELPER --run` from the
repository root. The host creates a fresh private `/private/tmp` directory and
uses a fixture Core with no inbound network listener. Its subscription and
latency checks use only its own ephemeral loopback HTTP fixture server; they never
import a user subscription or use the system proxy. The
Swift connection check is `bash native/test-native-isolated-connection.sh
ABSOLUTE_BUNDLED_HELPER NEW_ISOLATED_ROOT`. These checks do not validate the
production service/CoreManager takeover path.

## Scope

- Native window, sidebar, toolbar, and Settings scene.
- Fused route workspace: current/target switchbar, full-width route list, and a
  fixed bottom detail rail. Secondary columns collapse in compact windows.
- Live profile sections, current profile metadata, collapsed enhancement files,
  dynamic proxy groups, provider-aware members, search and historical delays.
  Group selection and row selection never activate a route.
- The separate fixture workspace retains favorites, sorting and simulated apply.
- System-owned sidebar glass, semantic `NSVisualEffectView` content materials,
  a native glass primary button on macOS 26, and a shared gap-ring Tez mark, including
  the app icon generated from vector paths during packaging.
- Appearance, protocol visibility, and reduced motion settings affect the preview.
  Reduced transparency and increased contrast replace custom material surfaces
  with opaque colors; system controls also follow macOS accessibility settings.
  Interface switches do not modify system accessibility preferences. Appearance
  preferences persist in the native app's own UserDefaults domain.
- Live activity reads connections, traffic totals, rules and rule-provider summaries.
  It uses a separate bounded GET-only query while visible, with search, details,
  pause and explicit pagination/error states. Search scans all safe projected
  entries in the bounded controller response, before paging. Bodies over 4 MiB
  still fail explicitly; private process paths are not searchable.
  A bounded Core WebSocket log stream, severity/search filtering, pause/follow
  and export are staged. The UI reports stream gaps and display limits.
  Connection-close actions and provider refresh actions still await migration.
- Managed Settings exposes network and DNS controls with explicit application.
  Profiles adds import/create, subscription management, refresh, activate, delete
  and reorder. Routes adds bounded per-node latency testing without changing
  selection. These staged workflows have not replaced the running app.

The presentation boundary is deliberate:

```text
SwiftUI/AppKit live views -> Foundation Process/Pipe -> managed Rust host
                                                    -> existing configuration policy
                                                    -> owned service/sidecar Core

Explicit read-only attach -> existing Mihomo socket (no mutation capabilities)
```

The helper publishes `tez://snapshot-changed` after actual projected data changes.
This is bounded two-second polling, not forwarding Tauri mutation events. The
client correlates requests, checks revisions and sequence, preserves visibly
offline snapshots on failure, and terminates its own read-only child on disconnect.
Activity polling is independent of snapshot subscriptions and never sends a core
mutation. Attach helpers cap requests per pipe session. The explicit read-only
attach client renews before that limit, after outstanding requests finish and the
old helper exits. It retains the last snapshot, never replays a request, and stops
on renewal failure. Managed sessions and unexpected capability sets do not renew.
Low-threshold mock and real-helper checks pass; a multi-hour soak remains pending.
New managed sessions negotiate strictly increasing request IDs without the legacy
request-count limit or helper renewal. Snapshot refreshes wait behind workspace
operations; timed-out writes are not automatically retried.
Managed/isolated sessions instead close stdin and wait for confirmed successful
exit. Timeout or abnormal exit blocks reconnect and application termination;
the supervisor does not force-kill an owned backend.
There are no automatic write retries. Core absence does not prevent profile reads.

See
[migration scope](migration/README.md) and [wire protocol](migration/wire-protocol.md).
The existing client stays in place until full macOS feature acceptance. Do not
interpret successful protocol tests as verified functional parity.

The approved visual direction combines the route-switch desk layout with the
glass connection console's material and logo. Native glass responds to the real
desktop, active-window state, and accessibility settings; no wallpaper image is
embedded to imitate transparency. Motion is limited to one-time entry, selected
route details, switch feedback, and favorite-symbol replacement. No throughput or
frame-rate claims are made.

Run `bash test-materials.sh` on macOS 26 to inspect a non-visible workspace's
real AppKit view hierarchy. It rejects glass nested inside the native sidebar
and checks standard content materials and opaque accessibility fallbacks.
It uses the Swift command-line toolchain without requiring XCTest. This does
not replace visual checks on a real desktop.

Use Command-1 through Command-4 for navigation. In the fixture workspace,
Command-F searches routes, Return applies, and Escape cancels a simulated switch.
Command-comma opens settings. The Window menu includes compact and
standard sizes (Command-Option-1/2). Quitting retains persisted interface settings.

Design references: Apple's [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars),
[Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars),
and [Windows](https://developer.apple.com/design/human-interface-guidelines/windows).
System controls own window chrome, selection, focus, and menu behavior rather
than reproducing those controls with HTML or custom painted assets.
