# Native Bridge v1

The Swift application and `tez-native-host` exchange newline-delimited JSON over inherited stdin/stdout pipes. Protocol frames use stdout; diagnostics use stderr.

## Frames

Each frame is a UTF-8 JSON object followed by LF. The frame limit is 8 MiB including LF.

All envelopes carry integer `version: 1` and string `kind`:

| Kind | Fields |
| --- | --- |
| `hello` | `protocol: "tez.native"`, `sessionID`, `capabilities: string[]` |
| `request` | `id`, `command`, `params: object` |
| `response` | `id`, exactly one of `result` or `error` |
| `event` | `sequence`, `name`, `payload` |

Request IDs correlate responses. Event sequences and snapshot revisions use canonical decimal strings. Integer payloads preserve the range `Int64.min...UInt64.max`; decimal values use finite IEEE-754 Double semantics.

A successful response can contain `result: null`. Errors carry `detail` with optional `code` and `operation` metadata.

The codec rejects malformed frames, unsupported versions, duplicate top-level keys, oversized frames, and truncated input.

## Capabilities and Modes

The handshake lists commands available in the current session. Managed sessions advertise `native_continuous_session` and use sequential request IDs starting at `seq:1`.

| Mode | Operations |
| --- | --- |
| Attach / inspect | Snapshots, subscriptions, and activity reads |
| Managed | Configuration, routes, core controls, subscriptions, settings, backups, and logs |
| Isolated | The feature fixture's implemented command subset |

The Swift store serializes workspace operations and defers snapshot refresh while an operation is active. After an interrupted operation, the interface reads the current backend state.

## Snapshots

`native_get_snapshot`, `native_subscribe`, and `native_unsubscribe` take empty parameters. Snapshots include the revision, profile metadata, core state, network state, and available proxy groups.

Subscriptions poll every two seconds and emit `tez://snapshot-changed` when projected data changes. The subscription response precedes later events. Each helper session starts its own event sequence.

Subscription URLs and configuration bodies are loaded by their selected editor commands.

## Activity

`native_get_activity` takes these optional parameters:

| Field | Values |
| --- | --- |
| `section` | `connections`, `rules`, `providers` |
| `query` | Up to 256 UTF-8 bytes |
| `offset` | 0 through 1,000,000 |
| `limit` | 1 through the selected section's page limit |

Search and paging parameters require an explicit section. Each section reports its state, items, total, matched count, offset, and next offset. Search operates on projected records before pagination.

Connection records include the available application or process, matched rule, routing chain, actual outbound route, and transfer totals. Pausing stops automatic polling; explicit searches and page changes still request data.

## Operations

- Profile writes include a revision for conflict detection and use the existing configuration pipeline.
- Latency requests accept 1 to 16 names, an HTTP(S) URL, and a timeout of 100 to 30000 ms. The interface sends batches of four.
- Log reads use a local WebSocket stream with filtering, pause, follow, and export. Responses include gap and truncation state.
- Backup import and restore validate archive entries and metadata. Restore creates a local backup first and reports whether the application needs a restart.
- Core claims, upgrades, and protection switches include the observed generation, PID, and start time. The service checks the owner session and expected identity before changing the process.
- Protection switches report `changed`, `unchanged`, or `rolled_back`, together with the actual resulting session state.

## Checks

```sh
bash native/test-backend-wire.sh
node scripts/test-native-wire.mjs
bash native/test-backend-connection.sh
```

Shared fixtures cover frame boundaries, null results, errors, Unicode, events, and 64-bit numbers. Connection tests cover correlation, timeouts, reconnect, operation serialization, and shutdown.
