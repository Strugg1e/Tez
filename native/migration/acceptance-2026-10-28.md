# Native acceptance, 2026-10-28

## Decision

Full replacement is not accepted. The user's condition remains full migration
and acceptance before replacing the retained Tauri application. A working Core
and successful HTTPS request do not establish feature parity.

The user successfully started the existing native build. At inspection, its
managed helper was running, the old GUI was absent, and the native connection
page reported owned Service mode, a usable service, and no pending operation.
The system HTTP, HTTPS and SOCKS proxies used localhost port 7897. An explicit
HTTPS request through that proxy returned 204.

## Observed coverage

| Check | Evidence | Result |
| --- | --- | --- |
| Actual native ownership | Process inspection and live runtime response in the connection page | Passed at inspection |
| HTTPS proxy connectivity | curl through localhost port 7897 | HTTP 204 |
| Route reads | Live route page | 248 members displayed |
| Profile reads | Live profile page | Five local/remote profiles and 27 enhancement files displayed |
| Activity reads | Live connection page | Active connections and nonzero traffic totals displayed |
| Transport shutdown safeguards | native/test-backend-connection.sh | Passed |
| Independent candidate packaging | build-preview.sh with TEZ_NATIVE_APP_PATH | Passed, including embedded Core/resources and strict signature verification |
| Full release inventory | scripts/check-native-parity.mjs --release | Failed: 141 pending acceptance obligations |

No live profile edit or route-selection write was accepted in this audit.
No traffic destinations, subscription URLs, controller secrets or recovery tokens
are included in this record.

## Running build coverage gaps

These describe the unchanged running bundle. Candidate source additions below
do not count as live acceptance of these workflows.

- The production settings scene exposes interface settings only. DNS, ports,
  routing mode, TUN and service settings are not connected to its real backend.
- The real profile view exposes metadata and editing, not complete import,
  activation, subscription refresh and update scheduling workflows.
- The real route view exposes selection and existing history, not a complete
  user-triggered latency-test workflow.
- The real activity view has connection, rule and provider reads, not complete
  close-connection and live-log workflows.
- The acceptance inventory has not been reconciled to live feature evidence.
  Its pending entries are not proof that every underlying implementation is
  absent, but they cannot be silently promoted to verified.

## Candidate changes

The running native build has no menu-bar scene. The independent candidate adds a
SwiftUI MenuBarExtra with window, settings, Core control and safe-quit commands.
Closing the main window no longer disconnects its owned backend. Application
termination still waits for the existing managed shutdown confirmation.

Normal startup now creates a managed backend and explicitly starts its own Core.
It confirms the returned runtime mode rather than treating an RPC response alone
as proof of startup. Migration-only version switching, the old bundle path and
example-workspace selection are removed from the normal application scene.
The old application is not launched, stopped or overwritten by these changes.

The candidate is built separately at native/output.noindex/Tez Candidate.app.
The running native/output.noindex/Tez Preview.app was not overwritten during
compilation. A verified copy of that working native bundle, the configuration
and the network baseline exists in the private native acceptance backup folder.

## Runtime checks still required

### Network continuity constraint

The user subsequently instructed the agent not to exercise Core on/off or
restart controls: the agent itself depends on this Mihomo proxy. Do not quit the
owning native app, replace its running executable, stop its helper, or test Core
lifecycle operations during the active session. The earlier proposed restart
sequence below is deferred, not authorized by an unlock confirmation alone.

UI validation now uses TEZ_NATIVE_UI_ONLY=1, a separate bundle identifier and a
bundle containing no helper or Core. It must not automatically connect a backend.
Window-drag changes are staged in the separate production candidate, not installed
over the running app. A live update requiring lifecycle changes needs a new,
explicitly arranged handoff that preserves network continuity.

The window-drag candidate enables native background movement and supplies an
explicit AppKit toolbar drag region. The user manually confirmed dragging in the
isolated UI build. Its window-move notification recorded a delta of (541, 15)
points with movement enabled. The automated drag initially reported no movement;
it is not counted as passing evidence. The material/drag-configuration regression
and candidate packaging passed. The isolated UI build contains no helper/Core;
the real helper/Core were not restarted for this verification.

Desktop automation became unavailable because macOS was locked and physical
input had been detected. No unlock was attempted. A quit action returned stale
accessibility-element errors; subsequent inspection showed different native
process IDs. This does not establish an accepted quit/relaunch sequence.

The original planned checks, deferred by the continuity constraint above, were:

1. Normal launch starts the owned Core without a migration command.
2. The menu-bar item is present and its Show Tez command restores the window.
3. Closing the window leaves the same helper/Core running and HTTPS works.
4. Safe quit stops only the owned Core and releases its instance lock.
5. Relaunch restores the same active profile and selected routes.
6. Core restart and the required real write workflows pass with recovery evidence.

Do not replace the retained old application or remove its recovery entry based
only on this candidate's build or the previously observed connectivity result.

## Staged feature work, network continuity preserved

The candidate now connects the following native controls to existing backend policy:

- Settings: persisted interface preferences; system proxy, TUN, PAC, guard, ports,
  bypass list, saved routing mode, probe defaults and application log level.
- DNS: read/edit/save draft separately from application; subscription DNS override
  retains the existing explicit confirmation token flow.
- Profiles: remote import and local YAML creation; names, URLs, proxy download,
  automatic update options, usage and next update; activate, refresh, delete and
  reorder actions alongside the existing revision-checked YAML editor.
- Routes: per-node or filtered batch latency probes, bounded concurrency, progress,
  stop-after-batch and per-node errors. No group-delay endpoint or route selection
  is used by the test operation. Ambiguous provider-only names remain excluded.
- Logs: owned Core log tail, severity/search filtering, pause/follow and explicit
  export of displayed lines. Failed reads remain visible instead of becoming an
  empty success.

The subscription timer is initialized after owned Core startup. Native shutdown
drains its in-flight writes before Core cleanup rather than aborting them mid-write.
Managed sessions negotiate monotonic request IDs so repeated log reads do not
hit the legacy request limit and close the owned backend. Attach remains bounded.

Evidence from this work:

- Rust `--features native-host --lib native_`: 72 tests passed.
- Timer regression subset: eight tests passed, including drain/retry behavior.
- `native/test-native-features.sh`: passed latency batching/stopping/response identity,
  persisted preferences, negotiated IDs, serialized requests and backend error propagation.
- Existing Swift backend connection, profile editor, activity and material checks passed.
- Separate full candidate build passed strict code-signature verification and resource
  verification (two arm64 cores, four databases, two DNS scripts). Its Swift
  executable also declares minimum macOS 14.0. Build did not launch the candidate.
- `scripts/check-native-parity.mjs --check`: inventory still covers 141 obligations;
  none silently promoted to live verified.
- The actual GUI/helper/Core PIDs remained 58693/77266/77342. System proxy remained
  localhost:7897; a request through it returned HTTP 204. No live mutation was sent.

The optional Feature Check GUI initially failed to launch: its test executable
declared minimum macOS 28.0. This caused a visible compatibility alert. Its build
now explicitly targets macOS 14.0, confirmed with `vtool -show-build`; headless
feature tests passed again. It was not relaunched after the alert. Screenshots
and live GUI acceptance of these new feature forms are therefore not claimed.

Real subscription downloads/automatic updates, DNS/network writes, activation,
route probes and log reads through the newly built managed helper are not live
accepted. The candidate is not launched or installed over the current app.
The existing old/new desktop entries remain unchanged. Full parity and the
eventual coordinated update remain pending.

## Additional Pre-Switch Checks

The user requested further validation without changing the active Core. On the
same native bundle, helper and service Core (PIDs 58693, 77266 and 77342):

- Candidate bundle passed deep strict signature checks and bundled resource checks.
- A fixture-owned Core passed profile revision conflict and invalid-write checks,
  live reload, route persistence, restart, stop, prepared shutdown and EOF shutdown.
  The fixture exposes no TCP/UDP listener and has DNS/TUN disabled. Configuration
  hashes, proxy and DNS digests and the active Core identity remained unchanged.
- The Swift store also exercised isolated real profile writes, route selection,
  lifecycle and prepared shutdown. It did not use the production CoreManager.
- A separate read-only attach process from the candidate read 32 profile items,
  15 strategy groups and 237 node records. Connections, rules and providers were
  available. The process advertised no write capability and exited cleanly.
- Swift feature fixture checks, two effect-classification tests and 31 parity-gate
  regression tests passed. The current proxy returned HTTP 204 during the checks.
- The release gate still fails with 141 obligations pending, not necessarily 141
  missing features. No pending item is converted to accepted by these checks.

At that point the isolated host did not advertise the new managed settings,
subscription, latency or log commands. Their fixture/unit results do not establish
production write, scheduling, log-stream equivalence or real GUI acceptance.
Do not install or switch the candidate until those gaps are covered and full
feature acceptance is recorded. No additional GUI window was launched here.

## Isolated Feature Validation

The current isolated host advertises a limited subset, backed by a private
directory, an independent Core and an ephemeral loopback-only HTTP fixture source.
It refuses network-effect settings, external subscription URLs, proxy downloads
and external latency targets. The Core has no inbound TCP/UDP listeners.

- The packaged helper passed safe settings persistence, DNS draft validation,
  Core mode changes and Core log reads. Network-effect settings were rejected.
- Subscription import, metadata edit and update passed through the real download
  parser and the fixture server. File storage uses an isolated adapter rather
  than the managed profile transaction. No subscription scheduler runs.
- The real Mihomo latency endpoint passed against the loopback fixture. This uses
  DIRECT, excluded by the production UI; provider-node testing remains unverified.
- The SwiftUI settings form saved a timeout, the DNS form saved a draft, the
  subscription sheet imported and refreshed a fixture, and the log view filtered
  actual isolated Core logs. The fixture application exited with its Core stopped.
- An initial settings save exposed a refresh/request race. An isolated Swift store
  reproduction failed and then passed after the refresh deferral fix. The existing
  backend-connection regression suite passed. The initial GUI harness crash was
  also fixed before the successful UI checks.

The active GUI, helper and Core retained PIDs 58693/77266/77342. The proxy returned
HTTP 204. Production network effects, real subscription activation/scheduling,
provider-node latency and log-stream equivalence remain unverified. The release
inventory remains pending; these isolated checks do not authorize replacement.

## Remaining Workflow Checks

- One selected existing Core node was probed once through its local Unix controller
  using the same Mihomo per-node delay route and a 5-second timeout. It returned
  216 ms. No group delay, retry, second node or route change was requested. This
  did not exercise the candidate GUI or its managed-host dispatch path.
- An independently owned Core activated the downloaded fixture subscription. Its
  configuration was applied, persisted and reflected in the UI. A fixture with an
  unsafe listener setting was rejected. The actual managed production transaction
  has not been exercised against the current Core.
- The timer scheduler was tested with an injected update callback and the real
  local HTTP subscription parser. It fired one overdue job, fetched the fixture,
  prevented overlapping updates and waited for in-flight work during drain. This
  does not exercise `feat::update_profile` or the production profile transaction.
- Before the stream repair, messages from the isolated Core's WebSocket during a reload matched
  polled stdout lines. This covers a short, low-volume sample only. The old UI
  keeps up to 1000 streamed messages; the new UI polls the service/sidecar ring,
  which retains 100 lines. Bursts could be lost between polls, so that build was
  not accepted for log consistency.

The running GUI, managed helper and Core remained at PIDs 58693/77266/77342.
System proxy settings stayed on localhost:7897. Full functional parity remains
unverified and the release gate still reports 141 pending obligations.

## Log Stream Repair

- The candidate uses the Core's Unix-socket WebSocket log stream while the log
  view is active. It retains up to 1000 entries and reports interruptions and
  truncation. Initial history may overlap the stream and produce duplicates.
- The native Rust suite passed 78 tests, including a 150-message burst and a
  disconnect/reconnect check. The Swift native feature checks passed.
- A separately packaged candidate passed isolated real-Core checks, including
  subscription import, update and activation, and a log-stream comparison
  during reload. Latency tests were skipped; no additional node was probed.
- These checks do not verify the managed production subscription transaction or
  automatic update path. The candidate was not installed or launched as the
  active application. The running GUI, helper and Core remained at PIDs
  58693/77266/77342, and the system proxy remained on localhost:7897.
- The release gate remains blocked: 141 inventory obligations are pending.

## Production Subscription Code With an Isolated Core

The explicitly built `native-acceptance` executable now calls the production
native workspace dispatcher, profile commands, enhancement pipeline, Core
validator, CoreManager sidecar reload and default Timer. It does not substitute
the subscription update callback or use the isolated profile adapter.

`scripts/test-native-subscriptions.mjs` passed with a separately owned Core and
a loopback HTTP subscription source. It verified activation and persisted profile
selection, manual update, an overdue automatic update, disable/re-enable,
next-update reporting and scheduler drain. All four fixture revisions reached
both the stored subscription and the Core's rules. Exactly four fixture downloads
occurred. No nodes or latency endpoints were used.

The supervisor launches the executable under a macOS sandbox with a dedicated
HOME. Network access is limited to the fixture HTTP port and Core socket. Writes
outside its temporary directory and reads of the active configuration directory
are denied. SystemConfiguration's configd service and network-setting commands
are denied. The current Core identity (PID 22187), live configuration hashes,
system proxy and DNS matched the baseline after the successful run. Earlier
fixture setup failures also left that baseline unchanged.

This verifies production subscription code against the sidecar transport, not
the active service-mode staging branch, SwiftUI interaction or application
replacement. The production application was not updated. The test executable
requires a separate feature and is not part of normal native-host packaging.
The passing run's report is at
`/private/tmp/tez-subscription-check-ebb42ce7097643e6/report.json`.

## Native Local Backups

The sandboxed production dispatcher created two distinct local archives, listed
both, checked the contents, rejected traversal and deleted each archive. The
fixture performed four loopback subscription downloads and no node tests. The
current Core PID, configuration hashes, proxy and DNS matched their baseline.
The Swift feature checks and native release build compile the new controls. UI
interaction against the managed backend remains unverified. Restore, import,
export and WebDAV controls remain unimplemented. The passing test report is at
`/private/tmp/tez-subscription-check-bf32afbc0ee1712c/report.json`.

## Backup Transfers and Restore

The native workspace now exposes local import, export and restore, plus WebDAV
configuration, upload, list, delete and restore. File paths and archive contents
are checked before import or restore. Restores first create a local safety backup
and report that restarting Tez is required; the UI does not restart the app. A
restore can still trigger Core or system-network effects while applying settings.
WebDAV credentials are never returned to the UI. HTTPS certificate validation
is enabled; deployments using untrusted self-signed certificates need a trusted
certificate instead.

An isolated production-backend run against a loopback HTTP WebDAV fixture
verified import/export, authentication, upload/list/delete and both restore
paths. It changed fixture profile metadata before each restore, checked that the
original data returned, checked the pre-restore archive and verified credential
preservation. Imported and exported bytes matched the original. Same-file export
was rejected without damaging the source. An encoded WebDAV filename was listed
and deleted without touching the other file. A changed server cannot reuse the
stored password without re-entry. Invalid archives, traversal, oversized downloads and an untrusted local HTTPS
certificate were rejected. The HTTPS fixture received no HTTP request. The current Core,
configuration hashes, system proxy and DNS matched their baseline afterwards.
The sandbox blocked system network configuration and external traffic.

An independent native UI with a mock backend verified local backup creation,
import/export picker opening, restore confirmation and feedback, and the
WebDAV settings and restore confirmation. It did not connect to a real Core.
Service-mode restore, real WebDAV interoperability and
recovery from partial filesystem/network failures are not yet accepted. The
passing isolated report is
`/private/tmp/tez-subscription-check-085433c7b8b40553/report.json`.
