# Tez Native Preview

A standalone SwiftUI/AppKit client under migration. Full replacement of
`../build/Tez.app` remains pending acceptance. The current source defaults to
automatic discovery: a running or unresolved Core opens a read-only observer.
Only an authenticated idle service plus a complete, empty Core process scan can
enter managed operation. The managed helper repeats its admission checks under
the instance lock before accepting any command. It can then change configurations
and system networking. Use `--stdio --inspect`, not `--automatic`, for guaranteed
read-only inspection. Do not overwrite a running bundle during development.
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

Automatic discovery -> verified idle service + no Core processes -> managed host
                    -> running / unknown / conflicting Core -> read-only observer
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

Automatic observers report service generation, PID, executable, UID and process
start time. Explicit re-inspection performs only service status and process reads.
They negotiate continuous request IDs and expose no Core, configuration, network
or shutdown writes. Helper loss retries discovery at most three times (1/2/4s),
preserves an offline snapshot, never replays a write, and cancels on disconnect.
Pre-command managed admission refusal falls back to a new read-only inspection;
post-admission cleanup failures do not. Closing an observer stops only its helper.
Closing a managed session still requires confirmed controlled shutdown.

Secure recovery and explicit control claiming use the Tez lifecycle extension in
`core-service/`. It preserves protocol 2.5 compatibility and adds protocol 2.6
routes behind an explicit `tez_lifecycle` capability, not a guessed version.
An already-running legacy session remains observer-only; updating source never
installs or restarts its service. A PID or matching executable alone is not proof of control.
An automatic observer may offer an explicitly confirmed claim when the extension
and package prerequisites are present. Explicit `--inspect` never offers it.

```text
Running Core + private receipt -> authenticate token/root -> resume, same PID
Running Core + explicit claim  -> compare generation/PID/start under lock -> rotate control
Idle Core + start              -> atomic idle check -> start, never replace another owner
Approved upgrade              -> preserve versions -> start candidate -> verify controller
                                                   -> failure -> restore previous Core
```

Receipts use a private 0700 directory and 0600 ordinary files. Loads never create
directories; links, wrong roots, stale generations and unsafe permissions are
rejected. A pending token saved before a start/claim survives a lost response.
Recovery reads the service's actual runtime into memory without regenerating it,
changing proxy/DNS settings, restoring selections or restarting the Core. Claiming
rotates the generation while preserving the PID. It displaces the old proof.
Claiming is limited to service-managed cores with the same user and canonical
data root. Arbitrary standalone Mihomo processes remain read-only; matching a
process name never authorizes termination or control.

Automatic observers with complete bundled service tools expose a user-confirmed
`native_install_service` command when the running service lacks lifecycle support.
Explicit `--inspect` and `--attach` remain read-only. The connection page displays
the service protocol and offers installation/upgrade instead of a disabled-control
dead end. The confirmation identifies the observed core and warns about proxy
interruption and administrator authorization. The backend rechecks that identity
before invoking the existing installer. Nothing is installed on discovery.
Installation serializes workspace requests and blocks quit/disconnect until its
result returns. Administrator authorization has no client request deadline, so
waiting for the password dialog never detaches an active installer. It does not
replay cancelled requests. Success or a returned installer error reconnects
discovery so capabilities reflect the actual installed service;
the user then chooses to claim a running core or start an idle core. Native core
start/stop/restart and claiming retain their separate confirmation dialogs.

The native update sheet stages a user-selected signed, matching-architecture
Mach-O file outside the application bundle. Administrator approval is requested
only after explicit confirmation. Approved copies are content-addressed and
digest-bound. Candidate startup and controller-version checks precede commitment;
failure restores the retained previous version. A serialized identity gate also
excludes watchdog PID replacement during claim/upgrade. Both versions survive an
unresolved rollback. The selected version survives a normal stop.

Isolated acceptance uses the real service implementation with its `test` feature,
real packaged stable/alpha cores, zero proxy listeners, disabled DNS/TUN, no
subscriptions, and no latency probes. `TEZ_SERVICE_TEST_ROOT` selects a fresh
private directory below `/private/tmp/tez-service-acceptance-*`; the IPC socket,
state and execution lock all stay below it. Production builds ignore this
variable. Build and run from `core-service/`:

```sh
cargo build --locked --features standalone,client,test --bin tez-lifecycle-check
TEZ_SERVICE_TEST_ROOT=/private/tmp/tez-service-acceptance-20261029-example \
  target/debug/tez-lifecycle-check --isolated ABSOLUTE_STABLE_CORE ABSOLUTE_ALPHA_CORE
```

The checker refuses existing test state, never elevates, never installs the
service, and removes its own directory after confirmed child shutdown. It checks
separate-client receipt recovery, authentication failures, same-PID claims,
watchdog identity changes, concurrent idle starts/claims/upgrades, signed private
staging, real upgrades and automatic rollback. Service unit tests use upstream's
separate test paths.

Native UI and backend acceptance are separate from production installation.
The package now includes the signed service, installer and uninstaller in
`Contents/Helpers`; their digest manifest is a sealed resource. The packaging
check compares the native helper's `--build-info` channel with the service
manifest, preventing an acceptance helper from being packaged as production.
Prepare built service tools with `package-service.mjs --prepare SOURCE NEW_OUTPUT`
and `TEZ_NATIVE_SERVICE_CHANNEL=production` (or `acceptance`), then pass that output
as `TEZ_NATIVE_SERVICE_DIR` to `build-preview.sh`.

On 2026-10-29, the complete acceptance application passed real managed recovery,
backend crash/relaunch, simultaneous application/backend crash/relaunch, and
controlled quit. The GUI and restarted backend recovered the same fixture PID
and service generation. The administrator installation path published root-owned
files, registered a running launchd service, and verified the installed service
digest against its bundled source. These were real installation and CoreManager
checks, not fixture protocol responses. The administrator cancellation result
remains unconfirmed: user feedback reported cancellation, but the installation
process returned success and the isolated service was present.
After acceptance, the fixture core was stopped and its dedicated launchd service,
privileged files, runtime and execution lock were removed. The private HOME and
test application were archived under `output.noindex`, with the application kept
as a `.bundle` artifact rather than installed beside the working application.

The explicit `native-lifecycle-acceptance` / `acceptance-channel` builds use
`app.tez.acceptance.service`, `/var/run/tez-acceptance-service`, a separate core
execution lock, and a private HOME under `/private/tmp/tez-package-acceptance-*`.
They never connect to the production service. System-proxy writes are excluded
from this channel; it only resumes its preseeded core and refuses fresh starts or
restarts. Its fixture has zero proxy listeners, disabled DNS/TUN, no subscriptions
and no latency probes. `tez-package-check` prepares, installs, seeds, inspects,
stops and removes only this dedicated channel. The native GUI uses its sealed
`TezAcceptanceHome` value for its child helper; production bundles have no override.

```text
Tez Acceptance.app -> real packaged native host -> acceptance launchd service
                    -> private receipt recovery -> same isolated core PID
Production Tez.app -> production service         -> current core (unchanged)
```

`node scripts/test-native-packaged-recovery.mjs ABSOLUTE_APP ACCEPTANCE_ROOT`
checks real managed handshakes, control identity, snapshots, idempotent start and
graceful shutdown across a killed helper. Build the acceptance host with
`cargo build -p tez --features native-lifecycle-acceptance --bin tez-native-host`;
build service tools and the driver in `core-service/` with features
`standalone,client,acceptance-channel`. Do not use an acceptance package as a
production update. Production installation and system-proxy effects remain
outside this isolation acceptance; the current production service is not updated.
Service unit tests additionally require the `test` feature, which redirects their
state and sockets away from the privileged installation paths. Building the real
acceptance installer intentionally does not use that feature.
Online release discovery/download and a separately confirmed force-stop workflow
are not implemented in this native update sheet. The legacy stop protocol can
still escalate internally; the UI does not promise a separate force-confirmation
stage. No candidate replaces the running application until acceptance is complete.

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

Run `bash test-layout.sh` to check the live workspace against a local
protocol fixture at standard and compact widths, in light and dark mode, with
the protocol column shown and hidden. No real controller or core is used.
`bash test-layout.sh --ui-bundle` also builds `Tez Layout Check.app` under
`output.noindex` for visual inspection with synthetic routes and activity.

The live activity table polls the selected section once per second. Transfer
rates use consecutive samples and measured elapsed time; the first sample,
paused reads, failed reads and counter resets have no inferred rate. Connection
details and a context menu offer closing one exact connection after confirmation.
`native_close_connection` is available only to an owned managed backend. Attach
and inspection sessions do not advertise this write command. There is no bulk
close command in the native protocol.

The home snapshot includes observed network state. System proxy and PAC switches
come from the active macOS network service. TUN and routing mode come from the
running controller's `/configs`, not saved settings. Missing or failed reads are
unknown, never disabled. The isolated core reader does not borrow the host's
system-proxy state.

`node scripts/test-native-network-observation.mjs /absolute/path/to/tez-native-host`
from the repository root checks a built helper against a private Unix-socket
HTTP fixture. It covers runtime mode changes, TUN, activity counters, read-only
write refusal and unavailable state without using a real core or proxy traffic.

Use Command-1 through Command-4 for navigation. In the fixture workspace,
Command-F searches routes, Return applies, and Escape cancels a simulated switch.
Command-comma opens settings. The Window menu includes compact and
standard sizes (Command-Option-1/2). Quitting retains persisted interface settings.

Design references: Apple's [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars),
[Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars),
and [Windows](https://developer.apple.com/design/human-interface-guidelines/windows).
System controls own window chrome, selection, focus, and menu behavior rather
than reproducing those controls with HTML or custom painted assets.
