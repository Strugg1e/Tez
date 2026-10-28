# Native bridge v1

This is an internal development contract, not a public network API. Full native
functional parity remains pending. Legacy `--stdio` exposes two safe read-only
commands. Explicit `--stdio --attach` also supports snapshots, subscriptions and
the independent read-only activity query.
Neither mode calls the ordinary app startup or shutdown path.

## Boundary

Use a parent-owned child process with private inherited stdin/stdout pipes.
No TCP listener, discovery port, global socket, or controller token is introduced.
Stdout is exclusively protocol frames; diagnostics go to stderr and omit payloads.
The native client starts the helper at its fixed bundle path, validates its
session handshake and required capabilities, correlates requests with deadlines,
and rejects interrupted event sequences. Distribution identity verification and
the complete mutating backend lifecycle remain pending.

Each frame is one UTF-8 JSON object followed by LF. Maximum size is 8 MiB including
LF. Blank, malformed, unsupported-version, duplicate top-level keys, and truncated
frames fail. Streaming decoders accept split and multiple frames. Nested duplicate
keys are not a supported interoperability guarantee.

All envelopes carry integer `version: 1` and a string `kind`:

| Kind | Required fields |
| --- | --- |
| hello | protocol="tez.native", nonempty sessionID, capabilities:string[] |
| request | nonempty id and command, params:object |
| response | nonempty id; exactly one of result:any JSON or error:object |
| event | sequence:canonical nonnegative decimal string, nonempty name, payload:any JSON |

Errors preserve `detail`, optional nullable `code`, and optional `operation` JSON.
A null result is success, not a missing result. Legacy request IDs are opaque strings. Event
sequence strings avoid numeric precision loss and start a new domain per session.
Integer payload literals must be within Int64.min...UInt64.max and are preserved
exactly. Decimal/exponent literals use finite IEEE-754 Double semantics. Larger
integer literals and nonfinite floats fail rather than silently round.

Unknown command failures never imply successful effects. Local cancellation or
disconnect never proves that a backend write was rolled back. Production request
tracking must distinguish transport failure from authoritative runtime state and
re-read committed state after reconnect. No automatic retries of writes are allowed.

## Managed workspace additions

Managed hosts advertise `native_continuous_session`. This is a transport capability,
not a callable command. A client can start a new session with request ID `seq:1`
and increment by exactly one for every request. A single u64 high-water mark rejects
replays, gaps and mixed ID modes without growing the legacy ID set. These sessions
do not end at the legacy 4096-request cap, which would otherwise make continuous
log polling terminate the owned Core. Legacy and attach sessions keep their bounded
ID policy; managed helpers are never renewed or force-killed to extend a session.

The managed workspace adds allowlisted settings reads/patches, routing mode, DNS
draft/confirmation/application, subscription import/details/metadata/update, local
YAML creation, profile activation/deletion/reordering, latency probes, Core log
queries, local backup operations and WebDAV backup operations. Attach does not advertise these workspace commands. The isolated host
advertises only its explicitly implemented subset.
Only local backup import and export accept absolute `.zip` file paths; the native
UI obtains them from system file panels. The inherited-pipe backend relies on its
owning client to restrict those paths to user-selected files. No command execution
parameter is accepted. Subscription
URLs reach only the explicitly opened subscription editor, not general snapshots.

Backup names are single ZIP filenames. Import and restore inspect archive paths,
entry types, size and configuration metadata before copying or extracting. A
restore first saves a local safety backup; its response reports that an app restart
is required and the UI does not automatically restart the app. Restored settings
can change network settings or trigger Core lifecycle effects before that restart;
failures can leave already-applied changes. WebDAV
passwords are written through the settings transaction but never returned by the
settings read. HTTPS uses certificate verification; HTTP is explicitly confirmed
in the UI. Downloaded archives have a bounded size.

Latency probes accept 1–16 names, an HTTP(S) URL and a 100–30000 ms timeout.
Core nodes take precedence as in ProxyView; provider-only names must be unique.
Each provider probe uses its provider/name endpoint. Group delay endpoints are
not used because they clear fixed group selections. The UI uses batches of four;
Stop prevents future batches, not the already running probes. Duplicate, missing,
ambiguous and non-proxy targets fail before probing. A changed Core generation
invalidates results. No probe selects or persists a route.

On Unix, `native_get_logs` connects to the owned Core's local WebSocket log stream
and retains up to 1000 messages independently of the service's 100-line ring.
The first connection also reads historical lines after establishing the stream;
overlap can display duplicate messages because the two sources have no shared ID.
Queries cap each line at 4096 characters and total raw text at 1 MiB to leave room
for JSON escaping within the 8 MiB frame. Overwritten or response-limited history
is reported to the UI. A broken stream is reconnected on the next request and
reports a possible gap; malformed messages also mark a gap. The idle stream closes
after the log page stops reading. Explicit export writes displayed lines only.
This protects a bounded burst while connected, not unlimited history or lossless
recovery during disconnection. Reads do not refresh snapshots.

Workspace operations are serialized in the Swift store. Snapshot refresh requests
are deferred while one is pending; concurrent commands are refused rather than
queued behind a long download. Errors preserve backend operation metadata.
An elapsed deadline does not certify rollback, and mutations are never retried.
Subscription scheduling begins after owned Core startup. Shutdown drains pending
subscription writes before stopping the Core; timeout retains ownership for retry.

### Isolated feature adapter

The isolated backend uses the same request parser, log filter, subscription fetch
and Mihomo delay client as managed operation, but has its own storage adapter.
It exposes safe settings, routing mode, DNS drafts, log reads and subscription
import/details/edit/update. Network-effect settings and DNS apply are rejected or
not advertised. No isolated subscription timer is started or next update claimed.

A short-lived HTTP fixture server binds an ephemeral 127.0.0.1 port in the helper.
Only that server's exact subscription and latency URLs are accepted. Import and
update refuse proxy downloads and never access global profile directories.
Latency exercises the real local Mihomo endpoint using DIRECT; the production
node selector intentionally excludes DIRECT, so this is not node-path acceptance.
The fixture Core has no inbound TCP/UDP listeners and no DNS or TUN. EOF and
prepared shutdown reap it and stop the loopback fixture server.

## Attach snapshots

The runtime advertises `native_get_activity` only when an activity provider is
installed. Empty params preserve the default first pages. Optional query params
are `section` (connections/rules/providers), `query` (at most 256 UTF-8 bytes),
`offset` (0..1,000,000), and `limit` (1..the section cap). Nondefault query fields
require an explicit section. Unknown fields, invalid ranges and other sections
are rejected before controller reads. The command never refreshes or changes snapshot
subscription state. Schema 1 has independent connections/rules/providers sections
with state, safe error code, total, matched, offset, nextOffset, truncated and
items. Query fields affect only the selected section. Identity assignment and
search precede paging. Queries only issue GET
requests to the resolved local Unix controller. Input bodies are capped at 4 MiB
per section, rows at 128/256/64, and the overall query at six seconds. Connections
include cumulative transfer totals, not sampled instantaneous rates. URLs,
process paths and provider extras are not projected. Activity is polled only
while its native page is visible and enabled; it is not a legacy Tauri event stream.
Live connections can move between pages as traffic changes; pagination does not
promise an immutable snapshot. The Swift client discards old-query responses and
serializes requests, including rapid search changes. Pausing stops automatic
polling, not explicit search or page navigation.

Attach adds `native_get_snapshot`, `native_subscribe`, and `native_unsubscribe`,
all requiring empty params. A snapshot contains a canonical revision string,
safe `profiles` metadata, `core` read status, and an optional existing ProxyViewV1.
The subscription response precedes subsequent `tez://snapshot-changed` events.
Only changed projected data increments revision or emits events. Events carry
the full snapshot and a session-local monotonically increasing sequence.

Polling occurs at a bounded two-second interval while subscribed. Reads have
deadlines; EOF and disconnect stop the helper without ordinary Tez shutdown.
This does not forward Tauri's event bus or authorize any writes. Missing or failed
profile/core sections are explicit, not replaced with fixture data. Optional
absolute data-directory and socket-path CLI arguments support isolated checks;
the bundled application uses only the default existing Tez paths.

## Checks

Build both offline codec runners, then run from the repository root:

```sh
bash native/test-backend-wire.sh
node scripts/test-native-wire.mjs
```

The shared fixtures cover null success, errors, Unicode, events, booleans and
64-bit boundaries in both directions. Negative frames must fail in both runtimes.
Passing a real `tez-native-host` binary path as an extra argument additionally
checks its narrow read-only allowlist and Swift decoding of actual responses.
This optional check does not authorize ordinary Tez startup or core/service writes.

The initial pipe integration check passed with the built Rust host: Swift encoded
four requests, the host reused both existing read commands, rejected a core-restart
request and unexpected parameters, and Swift decoded all five output frames
(one hello plus four responses). Values containing local paths or the hostname
were validated in memory and were not printed in the test report. This is a
backend-reuse proof, not native page integration or permission to expose writes.
