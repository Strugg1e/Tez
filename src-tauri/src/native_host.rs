use crate::cmd::{self, CmdResult, CommandFailure};
use crate::native_activity::{ActivityQuery, parse_query};
use serde_json::{Value, json};
use std::collections::HashSet;
use std::io::{self, Read, Write};
use std::path::PathBuf;
use std::time::{Duration, Instant};
use tez_backend_wire::{Decoder, Frame};

const CAPABILITIES: [&str; 2] = ["get_app_dir", "get_system_hostname"];
const MAX_REQUESTS: usize = 4096;
const MAX_REQUEST_ID_BYTES: usize = 128;
const ATTACH_CAPABILITIES: [&str; 5] = [
    "get_app_dir",
    "get_system_hostname",
    "native_get_snapshot",
    "native_subscribe",
    "native_unsubscribe",
];
const REFRESH_INTERVAL: Duration = Duration::from_secs(2);

pub(crate) fn serve_managed_with_activity(
    provider: impl FnMut() -> anyhow::Result<Value>,
    mut activity: impl FnMut(ActivityQuery) -> anyhow::Result<Value>,
    mut handler: impl FnMut(&str, Value) -> CmdResult<Value>,
    capabilities: Option<&[&str]>,
) -> anyhow::Result<()> {
    require_inherited_pipes()?;
    #[cfg(unix)]
    {
        let mut output = PipeWriter::new()?;
        serve_workspace_with_activity(
            io::stdin().lock(),
            &mut output,
            &nanoid::nanoid!(),
            provider,
            wait_for_input,
            Some(&mut handler),
            Some(&mut activity),
            capabilities,
        )
    }
    #[cfg(not(unix))]
    anyhow::bail!("managed pipes require Unix")
}

pub fn run_attach(data_dir: Option<PathBuf>, socket_path: Option<PathBuf>) -> anyhow::Result<()> {
    require_inherited_pipes()?;
    let data_dir = data_dir.map(Ok).unwrap_or_else(crate::utils::dirs::app_home_dir)?;
    anyhow::ensure!(
        data_dir.is_absolute() && socket_path.as_ref().is_none_or(|path| path.is_absolute()),
        "attach paths must be absolute"
    );
    let data = crate::native_data::NativeData::new_attach(data_dir, socket_path)?;
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
    #[cfg(unix)]
    {
        let mut output = PipeWriter::new()?;
        let mut activity = |query| Ok(runtime.block_on(data.activity_query(query)));
        serve_workspace_with_activity(
            io::stdin().lock(),
            &mut output,
            &nanoid::nanoid!(),
            || {
                runtime.block_on(async {
                    tokio::time::timeout(Duration::from_secs(6), data.snapshot())
                        .await
                        .map_err(|_| anyhow::anyhow!("snapshot timed out"))
                })
            },
            wait_for_input,
            None,
            Some(&mut activity),
            None,
        )
    }
    #[cfg(not(unix))]
    anyhow::bail!("attach is supported only on Unix")
}

#[cfg(unix)]
fn wait_for_input(timeout: Option<Duration>) -> io::Result<bool> {
    poll_fd(libc::STDIN_FILENO, libc::POLLIN, timeout)
}

#[cfg(unix)]
fn poll_fd(fd: libc::c_int, events: libc::c_short, timeout: Option<Duration>) -> io::Result<bool> {
    let deadline = timeout.map(|duration| Instant::now() + duration);
    loop {
        let timeout_ms = deadline.map_or(-1, |deadline| {
            deadline
                .saturating_duration_since(Instant::now())
                .as_millis()
                .min(i32::MAX as u128) as i32
        });
        let mut descriptor = libc::pollfd { fd, events, revents: 0 };
        let result = unsafe { libc::poll(&mut descriptor, 1, timeout_ms) };
        if result < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        if descriptor.revents & (libc::POLLERR | libc::POLLNVAL) != 0 {
            return Err(io::Error::other("inherited pipe disconnected"));
        }
        return Ok(result > 0);
    }
}

#[cfg(unix)]
struct PipeWriter {
    original_flags: libc::c_int,
}

#[cfg(unix)]
impl PipeWriter {
    fn new() -> io::Result<Self> {
        let flags = unsafe { libc::fcntl(libc::STDOUT_FILENO, libc::F_GETFL) };
        if flags < 0 || unsafe { libc::fcntl(libc::STDOUT_FILENO, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self { original_flags: flags })
    }
}

#[cfg(unix)]
impl Drop for PipeWriter {
    fn drop(&mut self) {
        unsafe {
            libc::fcntl(libc::STDOUT_FILENO, libc::F_SETFL, self.original_flags);
        }
    }
}

#[cfg(unix)]
impl Write for PipeWriter {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if !poll_fd(libc::STDOUT_FILENO, libc::POLLOUT, Some(Duration::from_secs(5)))? {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "inherited pipe write timed out",
            ));
        }
        let count = unsafe { libc::write(libc::STDOUT_FILENO, bytes.as_ptr().cast(), bytes.len()) };
        if count < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(count as usize)
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

struct AttachState {
    snapshot: Option<Value>,
    revision: u64,
    sequence: u64,
    subscribed: bool,
}

impl AttachState {
    fn new() -> Self {
        Self {
            snapshot: None,
            revision: 0,
            sequence: 0,
            subscribed: false,
        }
    }

    fn refresh(&mut self, provider: &mut impl FnMut() -> anyhow::Result<Value>) -> anyhow::Result<bool> {
        let mut value = provider()?;
        let object = value
            .as_object_mut()
            .ok_or_else(|| anyhow::anyhow!("snapshot must be an object"))?;
        object.remove("revision");
        if self.snapshot.as_ref() == Some(&value) {
            return Ok(false);
        }
        self.revision = self
            .revision
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("revision exhausted"))?;
        self.snapshot = Some(value);
        Ok(true)
    }

    fn current(&self) -> Value {
        let mut snapshot = self.snapshot.clone().expect("snapshot refreshed before use");
        snapshot["revision"] = self.revision.to_string().into();
        snapshot
    }

    fn event(&mut self, output: &mut impl Write) -> anyhow::Result<()> {
        self.sequence = self
            .sequence
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("sequence exhausted"))?;
        write_frame(
            output,
            json!({"version":1,"kind":"event","name":"tez://snapshot-changed",
            "sequence":self.sequence.to_string(),"payload":self.current()}),
        )
    }
}

#[cfg(test)]
fn serve_attach(
    input: impl Read,
    output: impl Write,
    session_id: &str,
    provider: impl FnMut() -> anyhow::Result<Value>,
    wait: impl FnMut(Option<Duration>) -> io::Result<bool>,
) -> anyhow::Result<()> {
    serve_workspace(input, output, session_id, provider, wait, None)
}

#[cfg(test)]
fn serve_workspace(
    input: impl Read,
    output: impl Write,
    session_id: &str,
    provider: impl FnMut() -> anyhow::Result<Value>,
    wait: impl FnMut(Option<Duration>) -> io::Result<bool>,
    managed_handler: Option<&mut dyn FnMut(&str, Value) -> CmdResult<Value>>,
) -> anyhow::Result<()> {
    serve_workspace_with_activity(input, output, session_id, provider, wait, managed_handler, None, None)
}

fn serve_workspace_with_activity(
    mut input: impl Read,
    mut output: impl Write,
    session_id: &str,
    mut provider: impl FnMut() -> anyhow::Result<Value>,
    mut wait: impl FnMut(Option<Duration>) -> io::Result<bool>,
    mut managed_handler: Option<&mut dyn FnMut(&str, Value) -> CmdResult<Value>>,
    mut activity_provider: Option<&mut dyn FnMut(ActivityQuery) -> anyhow::Result<Value>>,
    managed_capabilities: Option<&[&str]>,
) -> anyhow::Result<()> {
    let mut capabilities = if managed_handler.is_some() {
        managed_capabilities.unwrap_or(crate::native_managed::CAPABILITIES)
    } else {
        &ATTACH_CAPABILITIES
    }
    .to_vec();
    if activity_provider.is_some() {
        capabilities.push("native_get_activity");
    }
    write_frame(
        &mut output,
        json!({"version":1,"kind":"hello","protocol":"tez.native",
        "sessionID":session_id,"capabilities":capabilities}),
    )?;
    let mut state = AttachState::new();
    let mut seen = HashSet::new();
    let mut sequence: Option<u64> = None;
    let mut decoder = Decoder::new();
    let mut buffer = [0u8; 8192];
    let mut next_refresh = Instant::now() + REFRESH_INTERVAL;
    loop {
        let ready = wait(
            state
                .subscribed
                .then(|| next_refresh.saturating_duration_since(Instant::now())),
        )?;
        if ready {
            let count = match input.read(&mut buffer) {
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                result => result?,
            };
            if count == 0 {
                decoder.finish()?;
                return Ok(());
            }
            for frame in decoder.push(&buffer[..count])? {
                let value = frame.value();
                anyhow::ensure!(value["kind"] == "request", "only request frames are accepted");
                let id = value["id"]
                    .as_str()
                    .ok_or_else(|| anyhow::anyhow!("invalid request ID"))?;
                anyhow::ensure!(id.len() <= MAX_REQUEST_ID_BYTES, "request ID exceeds 128 bytes");
                if capabilities.contains(&"native_continuous_session") && (sequence.is_some() || id.starts_with("seq:")) {
                    anyhow::ensure!(seen.is_empty(), "cannot change request ID mode within a session");
                    let next = sequence.unwrap_or(0).checked_add(1).ok_or_else(|| anyhow::anyhow!("request sequence exhausted"))?;
                    anyhow::ensure!(id == format!("seq:{next}"), "request sequence must increase by one");
                    sequence = Some(next);
                } else {
                    anyhow::ensure!(seen.len() < MAX_REQUESTS, "request limit reached");
                    anyhow::ensure!(seen.insert(id.to_owned()), "duplicate request ID");
                }
                let command = value["command"]
                    .as_str()
                    .ok_or_else(|| anyhow::anyhow!("invalid command"))?;
                let mut changed = false;
                let result = if !capabilities.contains(&command) || command == "native_continuous_session" {
                    Err(CommandFailure::coded(
                        "NATIVE_COMMAND_UNAVAILABLE",
                        "Command is unavailable",
                    ))
                } else if command == "native_get_activity" {
                    parse_query(value["params"].clone()).and_then(|query| {
                        activity_provider
                            .as_mut()
                            .expect("activity capability requires provider")(query)
                        .map_err(|_| CommandFailure::coded("NATIVE_ACTIVITY_UNAVAILABLE", "Activity read failed"))
                    })
                } else if !ATTACH_CAPABILITIES.contains(&command) {
                    let result =
                        managed_handler.as_mut().expect("managed command allowlist")(command, value["params"].clone());
                    // A failed refresh must not erase the outcome of an already-applied write.
                    if command != "native_prepare_shutdown"
                        && (!crate::native_workspace::COMMANDS.contains(&command) || crate::native_workspace::mutates(command)) {
                        changed = state.refresh(&mut provider).unwrap_or(false);
                    }
                    result
                } else if !value["params"].as_object().is_some_and(|params| params.is_empty()) {
                    Err(CommandFailure::coded(
                        "NATIVE_PARAMS_UNSUPPORTED",
                        "Command requires empty params",
                    ))
                } else {
                    match command {
                        "native_get_snapshot" | "native_subscribe" => {
                            changed = state.refresh(&mut provider)?;
                            if command == "native_subscribe" {
                                state.subscribed = true;
                            }
                            next_refresh = Instant::now() + REFRESH_INTERVAL;
                            Ok(state.current())
                        }
                        "native_unsubscribe" => {
                            state.subscribed = false;
                            Ok(json!({}))
                        }
                        _ => dispatch(command),
                    }
                };
                let response = match result {
                    Ok(result) => json!({"version":1,"kind":"response","id":id,"result":result}),
                    Err(error) => json!({"version":1,"kind":"response","id":id,"error":serde_json::to_value(error)?}),
                };
                write_frame(&mut output, response)?;
                if changed && state.subscribed && command != "native_subscribe" {
                    state.event(&mut output)?;
                }
            }
        }
        if state.subscribed && (!ready || Instant::now() >= next_refresh) {
            if state.refresh(&mut provider)? {
                state.event(&mut output)?;
            }
            next_refresh = Instant::now() + REFRESH_INTERVAL;
        }
    }
}

pub fn run_stdio() -> anyhow::Result<()> {
    require_inherited_pipes()?;
    serve(io::stdin().lock(), io::stdout().lock(), &nanoid::nanoid!(), dispatch)
}

#[cfg(unix)]
pub(crate) fn require_inherited_pipes() -> io::Result<()> {
    for fd in [libc::STDIN_FILENO, libc::STDOUT_FILENO] {
        let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
        // fstat initializes stat only on success; inherited descriptors stay open here.
        if unsafe { libc::fstat(fd, stat.as_mut_ptr()) } != 0 {
            return Err(io::Error::last_os_error());
        }
        let stat = unsafe { stat.assume_init() };
        if stat.st_mode & libc::S_IFMT != libc::S_IFIFO {
            return Err(io::Error::other("stdin and stdout must be inherited pipes"));
        }
    }
    Ok(())
}

#[cfg(not(unix))]
pub(crate) fn require_inherited_pipes() -> io::Result<()> {
    Err(io::Error::other("native host pipes are supported only on Unix"))
}

fn dispatch(command: &str) -> CmdResult<Value> {
    match command {
        "get_app_dir" => cmd::get_app_dir().map(Value::String),
        "get_system_hostname" => Ok(Value::String(cmd::get_system_hostname())),
        _ => Err(CommandFailure::coded(
            "NATIVE_COMMAND_UNAVAILABLE",
            "Command is unavailable",
        )),
    }
}

fn write_frame(output: &mut impl Write, value: Value) -> anyhow::Result<()> {
    output.write_all(&Frame::new(value)?.encode()?)?;
    output.flush()?;
    Ok(())
}

fn serve(
    mut input: impl Read,
    mut output: impl Write,
    session_id: &str,
    mut handler: impl FnMut(&str) -> CmdResult<Value>,
) -> anyhow::Result<()> {
    write_frame(
        &mut output,
        json!({"version":1,"kind":"hello","protocol":"tez.native",
            "sessionID":session_id,"capabilities":CAPABILITIES}),
    )?;
    let mut decoder = Decoder::new();
    let mut seen = HashSet::new();
    let mut buffer = [0u8; 8192];
    loop {
        let count = match input.read(&mut buffer) {
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            result => result?,
        };
        if count == 0 {
            decoder.finish()?;
            return Ok(());
        }
        for frame in decoder.push(&buffer[..count])? {
            let value = frame.value();
            anyhow::ensure!(value["kind"] == "request", "only request frames are accepted");
            anyhow::ensure!(seen.len() < MAX_REQUESTS, "request limit reached");
            let id = value["id"]
                .as_str()
                .ok_or_else(|| anyhow::anyhow!("invalid request ID"))?;
            anyhow::ensure!(id.len() <= MAX_REQUEST_ID_BYTES, "request ID exceeds 128 bytes");
            anyhow::ensure!(seen.insert(id.to_owned()), "duplicate request ID");
            let command = value["command"]
                .as_str()
                .ok_or_else(|| anyhow::anyhow!("invalid command"))?;
            let result = if !CAPABILITIES.contains(&command) {
                Err(CommandFailure::coded(
                    "NATIVE_COMMAND_UNAVAILABLE",
                    "Command is unavailable",
                ))
            } else if !value["params"].as_object().is_some_and(|params| params.is_empty()) {
                Err(CommandFailure::coded(
                    "NATIVE_PARAMS_UNSUPPORTED",
                    "Command requires empty params",
                ))
            } else {
                handler(command)
            };
            let response = match result {
                Ok(result) => json!({"version":1,"kind":"response","id":id,"result":result}),
                Err(error) => json!({"version":1,"kind":"response","id":id,"error":serde_json::to_value(error)?}),
            };
            write_frame(&mut output, response)?;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;

    #[test]
    fn activity_is_explicit_read_only_and_does_not_refresh_snapshots() {
        let mut input = request("1", "native_get_activity", json!({"unexpected":true}));
        input.extend(request("2", "native_get_activity", json!({})));
        input.extend(request("3", "native_core_start", json!({})));
        let mut output = Vec::new();
        let mut calls = 0;
        let mut activity = |_query| {
            calls += 1;
            Ok(json!({"connections":{"state":"ready","items":[]}}))
        };
        serve_workspace_with_activity(
            input.as_slice(),
            &mut output,
            "test",
            || panic!("must not read snapshots"),
            |_| Ok(true),
            None,
            Some(&mut activity),
            None,
        )
        .unwrap();
        assert_eq!(calls, 1);
        let result = frames(&output);
        assert!(
            result[0]["capabilities"]
                .as_array()
                .unwrap()
                .contains(&json!("native_get_activity"))
        );
        assert_eq!(result[1]["error"]["code"], "INVALID_PARAMS");
        assert_eq!(result[2]["result"]["connections"]["state"], "ready");
        assert_eq!(result[3]["error"]["code"], "NATIVE_COMMAND_UNAVAILABLE");
    }

    #[test]
    fn activity_errors_are_sanitized_and_absent_providers_are_not_advertised() {
        let input = request("1", "native_get_activity", json!({}));
        let mut output = Vec::new();
        serve_attach(
            input.as_slice(),
            &mut output,
            "test",
            || panic!("snapshot"),
            |_| Ok(true),
        )
        .unwrap();
        let result = frames(&output);
        assert!(
            !result[0]["capabilities"]
                .as_array()
                .unwrap()
                .contains(&json!("native_get_activity"))
        );
        assert_eq!(result[1]["error"]["code"], "NATIVE_COMMAND_UNAVAILABLE");
        let mut output = Vec::new();
        let mut activity = |_query| anyhow::bail!("private-path-and-token");
        serve_workspace_with_activity(
            input.as_slice(),
            &mut output,
            "test",
            || panic!("snapshot"),
            |_| Ok(true),
            None,
            Some(&mut activity),
            None,
        )
        .unwrap();
        assert_eq!(frames(&output)[1]["error"]["code"], "NATIVE_ACTIVITY_UNAVAILABLE");
        assert!(!String::from_utf8(output).unwrap().contains("private-path-and-token"));
    }

    struct Chunks(VecDeque<Vec<u8>>);
    impl Read for Chunks {
        fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
            let Some(chunk) = self.0.pop_front() else {
                return Ok(0);
            };
            assert!(chunk.len() <= buffer.len());
            buffer[..chunk.len()].copy_from_slice(&chunk);
            Ok(chunk.len())
        }
    }

    const MANAGED_COMMANDS: [&str; 20] = [
        "native_read_profile",
        "native_save_profile",
        "native_select_route",
        "native_core_start",
        "native_core_stop",
        "native_core_restart",
        "native_get_runtime",
        "native_prepare_shutdown",
        "native_list_local_backups",
        "native_create_local_backup",
        "native_delete_local_backup",
        "native_import_local_backup", "native_export_local_backup", "native_restore_local_backup",
        "native_get_webdav_config", "native_save_webdav_config", "native_list_webdav_backups",
        "native_create_webdav_backup", "native_delete_webdav_backup", "native_restore_webdav_backup",
    ];

    #[test]
    fn managed_continuous_reads_exceed_legacy_budget_without_snapshot_writes() {
        let input = Chunks((1..=MAX_REQUESTS + 2).map(|id| request(&format!("seq:{id}"), "native_get_logs", json!({}))).collect());
        let mut calls = 0;
        let mut handler = |_: &str, _: Value| { calls += 1; Ok(json!({"lines":[]})) };
        serve_workspace(input, io::sink(), "continuous", || panic!("Log reads must not refresh snapshots"), |_| Ok(true), Some(&mut handler)).unwrap();
        assert_eq!(calls, MAX_REQUESTS + 2);
    }

    #[test]
    fn managed_continuous_sequence_rejects_replay_skips_and_mode_changes() {
        for bad in ["seq:1", "seq:3", "legacy"] {
            let input = Chunks(VecDeque::from([
                request("seq:1", "native_get_logs", json!({})),
                request(bad, "native_get_logs", json!({})),
            ]));
            let mut calls = 0;
            let mut handler = |_: &str, _: Value| { calls += 1; Ok(json!({})) };
            assert!(serve_workspace(input, io::sink(), "continuous", || panic!("snapshot"), |_| Ok(true), Some(&mut handler)).is_err());
            assert_eq!(calls, 1);
        }
    }

    #[test]
    fn managed_workspace_advertises_and_dispatches_only_explicit_commands() {
        let forbidden = [
            "save_profile_file",
            "restart_core",
            "install_service",
            "native_shutdown",
        ];
        let mut chunks = VecDeque::new();
        for (index, command) in MANAGED_COMMANDS.iter().chain(forbidden.iter()).enumerate() {
            chunks.push_back(request(&index.to_string(), command, json!({"injected":index})));
        }
        let mut calls = Vec::new();
        let mut refreshes = 0;
        let mut handler = |command: &str, params: Value| {
            calls.push(command.to_owned());
            Ok(json!({"command":command,"params":params}))
        };
        let mut output = Vec::new();
        serve_workspace(
            Chunks(chunks),
            &mut output,
            "managed-test",
            || {
                refreshes += 1;
                Ok(json!({"core":"injected"}))
            },
            |_| Ok(true),
            Some(&mut handler),
        )
        .unwrap();
        assert_eq!(calls, MANAGED_COMMANDS);
        assert_eq!(refreshes, MANAGED_COMMANDS.len() - 4);
        let result = frames(&output);
        assert_eq!(result[0]["capabilities"], json!(crate::native_managed::CAPABILITIES));
        assert_eq!(result.len(), 1 + MANAGED_COMMANDS.len() + forbidden.len());
        for (index, command) in MANAGED_COMMANDS.iter().enumerate() {
            assert_eq!(result[index + 1]["id"], index.to_string());
            assert_eq!(
                result[index + 1]["result"],
                json!({"command":command,"params":{"injected":index}})
            );
        }
        for response in result.iter().skip(1 + MANAGED_COMMANDS.len()) {
            assert_eq!(response["error"]["code"], "NATIVE_COMMAND_UNAVAILABLE");
            assert!(response.get("result").is_none());
        }
    }

    #[test]
    fn attach_workspace_rejects_every_managed_command_without_refreshing() {
        let input = Chunks(
            MANAGED_COMMANDS
                .iter()
                .enumerate()
                .map(|(index, command)| request(&index.to_string(), command, json!({})))
                .collect(),
        );
        let mut output = Vec::new();
        serve_attach(
            input,
            &mut output,
            "attach-test",
            || panic!("attach rejection must not refresh or initialize the backend"),
            |_| Ok(true),
        )
        .unwrap();
        let result = frames(&output);
        assert_eq!(result[0]["capabilities"], json!(ATTACH_CAPABILITIES));
        assert_eq!(result.len(), MANAGED_COMMANDS.len() + 1);
        for response in result.iter().skip(1) {
            assert_eq!(response["error"]["code"], "NATIVE_COMMAND_UNAVAILABLE");
            assert!(response.get("result").is_none());
        }
    }

    #[test]
    fn managed_write_result_survives_a_failed_snapshot_refresh() {
        let input = request("save-1", "native_save_profile", json!({"injected":true}));
        let committed = json!({"saved":true,"revision":"injected-committed-revision"});
        let mut calls = 0;
        let mut handler = |command: &str, params: Value| {
            assert_eq!(command, "native_save_profile");
            assert_eq!(params, json!({"injected":true}));
            calls += 1;
            Ok(committed.clone())
        };
        let mut output = Vec::new();
        serve_workspace(
            input.as_slice(),
            &mut output,
            "managed-test",
            || anyhow::bail!("injected snapshot refresh failure after commit"),
            |_| Ok(true),
            Some(&mut handler),
        )
        .unwrap();
        assert_eq!(calls, 1);
        let result = frames(&output);
        assert_eq!(result.len(), 2);
        assert_eq!(result[1]["id"], "save-1");
        assert_eq!(result[1]["result"], committed);
        assert!(result[1].get("error").is_none());
    }

    #[test]
    fn attach_subscription_orders_response_and_only_publishes_changes() {
        let input = Chunks(VecDeque::from([
            request("1", "native_subscribe", json!({})),
            request("2", "native_unsubscribe", json!({})),
        ]));
        let mut waits = VecDeque::from([true, false, false, true, true]);
        let mut snapshots = VecDeque::from([json!({"core":1}), json!({"core":1}), json!({"core":2})]);
        let mut output = Vec::new();
        serve_attach(
            input,
            &mut output,
            "test",
            || Ok(snapshots.pop_front().unwrap()),
            |_| Ok(waits.pop_front().unwrap()),
        )
        .unwrap();
        assert!(snapshots.is_empty());
        let result = frames(&output);
        assert_eq!(result.len(), 4);
        assert_eq!(result[1]["kind"], "response");
        assert_eq!(result[1]["result"]["revision"], "1");
        assert_eq!(result[2]["name"], "tez://snapshot-changed");
        assert_eq!(result[2]["sequence"], "1");
        assert_eq!(result[2]["payload"], json!({"core":2,"revision":"2"}));
        assert_eq!(result[3]["id"], "2");
    }

    #[test]
    fn attach_get_refresh_and_resubscribe_preserve_counters() {
        let input = Chunks(VecDeque::from([
            request("1", "native_subscribe", json!({})),
            request("2", "native_get_snapshot", json!({})),
            request("3", "native_unsubscribe", json!({})),
            request("4", "native_subscribe", json!({})),
        ]));
        let mut waits = VecDeque::from([true, true, true, true, false, true]);
        let mut n = 0;
        let mut output = Vec::new();
        serve_attach(
            input,
            &mut output,
            "test",
            || {
                n += 1;
                Ok(json!({"core":n}))
            },
            |_| Ok(waits.pop_front().unwrap()),
        )
        .unwrap();
        let result = frames(&output);
        assert_eq!(result[2]["id"], "2");
        assert_eq!(result[3]["sequence"], "1");
        assert_eq!(result[5]["id"], "4");
        assert_eq!(result[5]["result"]["revision"], "3");
        assert_eq!(result[6]["sequence"], "2");
        assert_eq!(result[6]["payload"]["revision"], "4");
        assert_eq!(n, 4);
    }

    #[test]
    fn attach_rejects_mutations_params_and_id_bounds_before_snapshot() {
        serve_attach(
            request(&"x".repeat(MAX_REQUEST_ID_BYTES), "native_unsubscribe", json!({})).as_slice(),
            io::sink(),
            "test",
            || panic!("must not read snapshot"),
            |_| Ok(true),
        )
        .unwrap();
        for input in [
            request("1", "patch_verge_config", json!({})),
            request("1", "native_subscribe", json!({"unexpected":true})),
        ] {
            let mut output = Vec::new();
            serve_attach(
                input.as_slice(),
                &mut output,
                "test",
                || panic!("must not read snapshot"),
                |_| Ok(true),
            )
            .unwrap();
            assert!(frames(&output)[1].get("error").is_some());
        }
        for id in ["x".repeat(129), "\u{e9}".repeat(65)] {
            assert!(
                serve_attach(
                    request(&id, "native_get_snapshot", json!({})).as_slice(),
                    io::sink(),
                    "test",
                    || panic!("must not read snapshot"),
                    |_| Ok(true)
                )
                .is_err()
            );
        }
        let mut duplicate = request("1", "native_unsubscribe", json!({}));
        duplicate.extend(request("1", "native_subscribe", json!({})));
        assert!(
            serve_attach(
                duplicate.as_slice(),
                io::sink(),
                "test",
                || panic!("must not read snapshot"),
                |_| Ok(true)
            )
            .is_err()
        );
    }

    #[test]
    fn attach_eof_stops_polling_and_provider_failure_is_terminal() {
        let input = request("1", "native_subscribe", json!({}));
        let mut calls = 0;
        serve_attach(
            input.as_slice(),
            io::sink(),
            "test",
            || {
                calls += 1;
                Ok(json!({}))
            },
            |_| Ok(true),
        )
        .unwrap();
        assert_eq!(calls, 1);
        assert!(
            serve_attach(
                input.as_slice(),
                io::sink(),
                "test",
                || anyhow::bail!("snapshot timeout"),
                |_| Ok(true)
            )
            .is_err()
        );
        assert!(
            serve_attach(
                &input[..input.len() - 1],
                io::sink(),
                "test",
                || panic!("truncated"),
                |_| Ok(true)
            )
            .is_err()
        );
    }

    #[test]
    fn attach_session_request_count_is_bounded() {
        let mut input = Vec::new();
        for id in 0..=MAX_REQUESTS {
            input.extend(request(&id.to_string(), "native_unsubscribe", json!({})));
        }
        assert!(
            serve_attach(
                input.as_slice(),
                io::sink(),
                "test",
                || panic!("must not read snapshot"),
                |_| Ok(true)
            )
            .is_err()
        );
    }

    fn request(id: &str, command: &str, params: Value) -> Vec<u8> {
        Frame::new(json!({"version":1,"kind":"request","id":id,"command":command,"params":params}))
            .unwrap()
            .encode()
            .unwrap()
    }

    fn frames(output: &[u8]) -> Vec<Value> {
        let mut decoder = Decoder::new();
        let frames = decoder.push(output).unwrap();
        decoder.finish().unwrap();
        frames.into_iter().map(|frame| frame.value().clone()).collect()
    }

    #[test]
    fn hello_and_response_preserve_id_and_command_failure() {
        let input = request("request-1", "get_app_dir", json!({}));
        let mut output = Vec::new();
        let failure = CommandFailure::coded("READ_FAILED", "unavailable")
            .asking_for(Some(crate::core::notification::FailedOperation::SystemProxyEnable));
        serve(input.as_slice(), &mut output, "session", |_| Err(failure.clone())).unwrap();
        let result = frames(&output);
        assert_eq!(
            result[0],
            json!({"version":1,"kind":"hello","protocol":"tez.native",
            "sessionID":"session","capabilities":CAPABILITIES})
        );
        assert_eq!(result[1]["id"], "request-1");
        assert_eq!(result[1]["error"], serde_json::to_value(failure).unwrap());
        assert!(result[1].get("result").is_none());
    }

    #[test]
    fn allowlist_and_params_reject_before_handler() {
        let mut input = request("1", "restart_core", json!({}));
        input.extend(request("2", "get_app_dir", json!({"unexpected":true})));
        let mut output = Vec::new();
        serve(input.as_slice(), &mut output, "session", |_| {
            panic!("must not dispatch")
        })
        .unwrap();
        let result = frames(&output);
        assert_eq!(result[1]["error"]["code"], "NATIVE_COMMAND_UNAVAILABLE");
        assert_eq!(result[2]["error"]["code"], "NATIVE_PARAMS_UNSUPPORTED");
    }

    #[test]
    fn duplicate_nonrequest_and_truncated_frames_fail() {
        let request = request("1", "get_system_hostname", json!({}));
        let mut duplicate = request.clone();
        duplicate.extend(&request);
        let response = Frame::new(json!({"version":1,"kind":"response","id":"1","result":null}))
            .unwrap()
            .encode()
            .unwrap();
        for input in [duplicate, response, request[..request.len() - 1].to_vec()] {
            let mut calls = 0;
            assert!(
                serve(input.as_slice(), Vec::new(), "session", |_| {
                    calls += 1;
                    Ok(json!("test"))
                })
                .is_err()
            );
            assert!(calls <= 1);
        }
    }

    #[test]
    fn bounded_session_and_successful_eof() {
        let mut input = Vec::new();
        for id in 0..=MAX_REQUESTS {
            input.extend(request(&id.to_string(), "get_system_hostname", json!({})));
        }
        let mut calls = 0;
        assert!(
            serve(input.as_slice(), io::sink(), "session", |_| {
                calls += 1;
                Ok(json!("test"))
            })
            .is_err()
        );
        assert_eq!(calls, MAX_REQUESTS);
        let mut output = Vec::new();
        serve(
            request("1", "get_app_dir", json!({})).as_slice(),
            &mut output,
            "session",
            |_| Ok(json!("test")),
        )
        .unwrap();
        assert_eq!(frames(&output)[1]["result"], "test");
    }

    #[test]
    fn request_id_limit_counts_utf8_bytes_before_dispatch() {
        let mut calls = 0;
        let exact = "x".repeat(MAX_REQUEST_ID_BYTES);
        serve(
            request(&exact, "get_app_dir", json!({})).as_slice(),
            io::sink(),
            "session",
            |_| {
                calls += 1;
                Ok(Value::Null)
            },
        )
        .unwrap();
        assert_eq!(calls, 1);
        for id in ["x".repeat(MAX_REQUEST_ID_BYTES + 1), "\u{e9}".repeat(65)] {
            assert!(
                serve(
                    request(&id, "get_app_dir", json!({})).as_slice(),
                    io::sink(),
                    "session",
                    |_| { panic!("oversized ID must not dispatch") }
                )
                .is_err()
            );
        }
    }
}
