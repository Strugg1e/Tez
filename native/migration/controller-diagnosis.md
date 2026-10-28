# Local controller diagnosis

Observed on 2026-10-27. Inspection was read-only. No application, core,
service, configuration, proxy setting, or network setting was changed.

## Confirmed cause

The native attach host selected the sidecar controller socket unconditionally.
The existing core runs in Service mode and listens on the separate,
owner-scoped service controller socket.

- The default sidecar socket exists, is a Unix socket, and belongs to UID 501.
  Its mode is `srw-rw-rw-`. Existence therefore did not establish liveness.
- A bounded `curl --unix-socket <sidecar socket> .../version` failed with
  `curl: (7) Failed to connect`. This also failed outside the command sandbox.
- The running service core's launch arguments specify its owner-scoped service
  socket. The process ID was 32868. The service process ID was 703.
- A bounded `curl --unix-socket <service controller socket> .../version`
  succeeded with `{"meta":true,"version":"v1.19.32"}`.
- An authenticated, read-only service `/status` request using the current Unix
  identity and the Tez application data root returned code 0, `is_active=true`,
  `core_pid=32868`, and `service_state="Running"`.

These observations rule out a stopped core and a general inability to access
the service controller. They establish a sidecar/service endpoint mismatch.
They do not independently prove which historical process created the stale
sidecar socket inode.

## Ownership boundary

The service authenticates the Unix peer and verifies ownership of the supplied
application data root. Its status endpoint identifies the active owner by Unix
UID, not by the supplied application data root. Therefore a successful status
request proves current-user ownership, but not a strict active-root match.

The service's `active-owner.json` is private. Reading it as the current user
returns `Permission denied`. The old application's session proof exists only
in process memory. The attach host must not create credentials, impersonate a
privileged process, read another application's controller, scan socket paths,
or fall back to TCP to bypass this boundary.

## Source evidence

- `src-tauri/src/native_host.rs`: the former default used
  `IClashTemp::guard_external_controller_ipc()`.
- `src-tauri/src/config/clash.rs`: that guard selects `sidecar_ipc_path()`.
- `src-tauri/src/core/manager/state.rs`: Service mode uses `dirs::ipc_path()`;
  Sidecar mode uses `dirs::sidecar_ipc_path()`.
- `src-tauri/src/core/owner_identity.rs`: Unix credentials canonicalize the
  supplied root without creating a file. Windows credentials can create an
  owner token, so read-only discovery must not invoke that branch.
- The service IPC library's `service_status_snapshot` matches `owner_key`
  against the active owner. Its endpoint builder scopes the controller by
  channel and identity.

## Validation boundary

Read-only attach uses the authenticated current-user and service-channel
boundary, consistent with the existing `dirs::ipc_path()` contract. It does
not claim that the active service application data root matches Tez. The
snapshot identifies a successful service connection with `core.source` set
to `service`. An explicit socket override never discovers another endpoint.
This read-only discovery does not grant lifecycle or controller-write access.

Live validation above only queried version and status. Profile contents,
subscription URLs, configuration contents, credentials, session tokens, and
proxy names were not printed. Full application replacement, lifecycle actions,
and live controller writes remain outside this diagnosis.
