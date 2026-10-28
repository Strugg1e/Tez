# Native integration validation, 2026-10-27

This is incremental evidence, not full-migration acceptance. The old application
was not replaced, stopped or reconfigured. The live core received read-only
requests only.

## Automated checks

- Rust `--features native-host --lib native_`: 38 passed. Covers read-only
  endpoint discovery, strict dispatch, revision validation, mutation ownership
  guards, applied/persisted separation, managed preflight and failed refresh
  preserving a successful mutation result. Unix-socket fixtures use temporary
  directories; sandbox execution initially denied binding, then the permitted
  isolated run passed.
- Rust `--lib cmd::`: 9 passed, including bounded profile reads and optimistic
  revision checks without changing the existing legacy save entry point.
- Rust `--lib config::profiles`: 22 passed.
- Swift `test-backend-connection.sh` and `test-profile-editor.sh`: passed.
- `test-materials.sh`: passed after allowing Swift compiler cache access;
  covers system glass structure and accessibility material fallbacks.
- `test-native-wire.mjs`: 6 shared roundtrip fixtures and 12 rejected frames
  passed, including real legacy helper responses decoded by Swift.
- `test-native-attach.mjs` against the built helper: passed. Uses isolated
  metadata and a fake Unix controller; verifies events, resubscription,
  mutation rejection, secret omission and EOF exit.
- Rust helper build and Swift release build: passed. Preview and helper
  ad-hoc signing and deep strict signature verification passed.
- Migration inventory check: 141 covered, 0 verified, 141 pending.

## On-device read-only checks

The preview was explicitly disconnected before updating its bundle. The rebuilt
preview started disconnected. An explicit connection displayed live route data
(248 members in the selected group) and the existing current profile.

Selecting a row only changed the native detail selection. The route switch
button was disabled. Profile edit and core start/stop/restart were also disabled,
as the attach handshake does not advertise their capabilities.

Screenshot: `native/output.noindex/native-service-routes.png`.

SHA-256 values for `profiles.yaml`, `tez.yaml` and `config.yaml` in the existing
application data directory matched before and after the check. Config contents,
subscription URLs and secrets were not included in this evidence.

## Not accepted

- Live configuration writes, validation rollback and concurrent legacy writes.
- Live route switching and persistence across restart.
- Managed runtime start/stop/restart, resource packaging, shutdown after pipe
  failure, and Swift supervision without forcibly terminating an owned core.
- Remaining activity streams, advanced settings, service/system integration,
  migration recovery, and full feature parity.

The write adapters and native controls are implemented but remain dormant in the
preview. Passing isolated adapter tests is not permission to take over the
currently running service. Replacement remains blocked by full acceptance.

## Follow-up: Own Packaging and Real Isolated Writes

The rebuilt preview now includes two signed arm64 cores and four independently
copied databases. `test-core-packaging.mjs` rejects missing files, altered hashes
and symlinks. The release build and strict bundle signature verification passed.

`test-native-isolated.mjs` passed against the packaged helper and real Mihomo:

- Read/save with revision conflict rejection; unsafe configurations stay unchanged.
- Live reload changes the core log level, verified through its Unix controller.
- Select `REJECT`, save again, restart, and confirm the selection persists.
- Repeated start/stop is safe; EOF stops and reaps all session-owned core PIDs.
- Every running test core has no TCP/UDP endpoints, checked with `lsof`.
- Existing configuration hashes, system proxy/DNS digests and protected running
  core identity are unchanged before/after. No production service mutation occurs.

`test-native-isolated-connection.sh` also passed through the actual Swift
`NativeBackendStore`: writes, route selection, restart, stop, and EOF shutdown
with a running real core. Subsequent checks confirmed the three existing
configuration hashes and system proxy digest still matched, with the same old
core process running.

The Swift mock checks cover delayed EOF, shutdown timeout, abnormal exit and
repeated disconnect. Unconfirmed shutdown retains the child and blocks reconnect
and app termination. All Swift sources typecheck; 40 native Rust tests passed.
The rebuilt application was opened through CUA and remained disconnected in
read-only mode by default.

These experiments do not run the production CoreManager because its global
service reservation and system network effects conflict with keeping the current
proxy untouched. Production save rollback, service takeover/restoration and full
UI write acceptance therefore remain pending. The migration inventory still has
141 pending obligations, with no automatic promotion to verified.

## Follow-up: Read-only Activity and Takeover Preparation

The native activity page now queries connections, cumulative transfer totals,
rules and rule-provider summaries through a separate GET-only command. Each
section has a deadline, body/row limits, sanitized errors and a truncation flag.
Polling is visible-page only, non-overlapping and pausable; searches cover loaded
rows rather than implying an exhaustive server-side query.

Validation in this increment:

- 49 native Rust tests passed, including activity projection/GET-only reads,
  independent section errors, response limits and explicit DNS shutdown order.
  Two initial mock-socket tests failed before their assertions because the macOS
  temporary path exceeded SUN_LEN. Shortening their private fixture names fixed
  the setup, and the default-environment rerun passed.
- Swift activity and backend-connection checks passed; the release app built and
  passed deep strict signature verification.
- The real helper passed the isolated mock-controller integration test with
  activity, partial failures, secret omission, mutation rejection and EOF exit.
- CUA showed real connections and 4,111 rules (256 loaded), plus an empty rule-
  provider section. Tab switching, paused refresh, search empty state and compact
  layout were checked without invoking any core mutation.
  The final compact connection-detail screenshot is
  `native/output.noindex/native-live-activity-compact.png`. The page was left
  paused. A port-only destination is labeled as a port, not a malformed address.
- Packaging checks passed for two signed cores, four databases and two DNS
  scripts. The DNS scripts are only copied/checked; they were not executed.
- The read-only preflight confirmed valid bundle signature/manifest and found
  the existing core PID 32868. It exited 2 as designed, with takeover unauthorized,
  recovery acceptance incomplete and full parity pending. It acquires no lock,
  sends no service mutation and creates no user configuration.
  After the UI checks, configuration hashes still matched. System proxy/DNS
  digests matched the preflight when read under the same permission environment.

Production shutdown now explicitly attempts DNS restoration only after an owned
core is confirmed stopped. Injected tests verify error preservation; this is not
live production DNS-restoration acceptance. Remaining limitations include logs,
connection-close/provider-update actions, exhaustive rules pagination, automatic
pipe-session renewal, settings/service integration, backup/rollback, and production
takeover recovery. No old bundle was replaced, and actual switching still requires
the user's confirmation.

## Follow-up: Query Pagination and Attach Renewal

- Activity now filters all safe projected entries in the bounded controller
  response before paging, with matched/total counts and stable rule indices.
  Query parameters reject unknown fields, oversized UTF-8 text and invalid ranges
  before sending any controller request.
- 52 native Rust tests passed. The real helper's mock-controller integration
  passed searches beyond row 256, page bounds, invalid requests with no GET,
  partial failures and rejection of mutations.
- Swift tests passed pagination decoding, stale-query rejection, serialized
  refresh and cancellation. Pausing still permits explicit searches/pages.
- CUA verified the real second rule page (257-512 of 4,111), then `MATCH` found
  rule index 4,110 from a fresh first page of search results. Compact layout was
  checked. Screenshot: `native/output.noindex/native-rules-full-query.png`.
- Read-only attach renews at 3,500 requests, below the helper's 4,096 limit.
  Mock tests cover pending-request drain, old-process exit, retained snapshots,
  generation/revision reset, cancellation, timeout and forbidden renewal in
  managed or write-capable sessions. A real bundled helper renewed twice through
  Swift using an injected threshold of two. No core lifecycle command was sent.
- The updated preview built and passed strict signature/resource checks.

These results supersede the earlier loaded-rows-only search and missing attach
renewal limitations. Multi-hour soak testing and managed-session renewal remain
pending. Search still excludes private fields and refuses controller bodies over
4 MiB; live connection pages are not immutable snapshots. No production takeover
or application replacement occurred.

## Authorized Trial Preflight

The user subsequently authorized one reversible trial with a brief interruption,
backup retention and immediate rollback on failure. This is trial authorization,
not full-parity acceptance or permission to overwrite the old bundle.

Preflight confirmed the preview remains read-only by default and failed managed
cleanup still has no retry/recovery entry point that reliably releases ownership.
Consequently the old core was not stopped and the production trial did not start.
This is a missing recovery implementation, not a request for repeated consent.

`native/backup-trial.mjs` copied the old `build/Tez.app` and 47 application-data
files into a private `.noindex` backup directory outside this repository. It
verified source/copy inventories and SHA-256 hashes, checked the copied app's
strict deep signature, and recorded all five network services' proxy/DNS settings.
Source application/configuration and network baselines stayed stable during the
copy. Live logs and singleton lock/instance files are explicitly excluded; a lock
file must never be restored over a live owner. This verifies backup integrity,
not production restoration or automatic rollback.

The first capture used an unsupported automatic-discovery query spelling and
correctly recorded an incomplete network baseline. The corrected, fully verified
backup is `trial-2026-10-27T10-03-33.305Z-e3bafc76` under
`Documents/mac管理/Tez-trial-backups.noindex`. That directory is user-only and
contains a Git ignore rule. The manifest reports `trialStarted:false` and
`rollbackReady:false`; there is no automatic restore command in the backup tool.
