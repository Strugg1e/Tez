use std::{
    cell::RefCell,
    fs,
    path::{Path, PathBuf},
    rc::Rc,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

use anyhow::{Context as _, Result, anyhow, ensure};
use serde::Deserialize;
use serde_json::{Value, json};
use tauri::Manager as _;

use crate::{
    cmd::{CmdResult, CommandFailure},
    core::{CoreManager, handle::Handle, manager::RunningMode},
    native_data::NativeData,
};

pub const CAPABILITIES: &[&str] = &[
    "native_continuous_session",
    "get_app_dir",
    "get_system_hostname",
    "native_get_snapshot",
    "native_subscribe",
    "native_unsubscribe",
    "native_read_profile",
    "native_save_profile",
    "native_select_route",
    "native_close_connection",
    "native_get_proxy_config", "native_patch_proxy_config",
    "native_get_proxy_chains", "native_save_proxy_chain", "native_delete_proxy_chain", "native_activate_proxy_chain", "native_deactivate_proxy_chain",
    "native_core_start",
    "native_core_stop",
    "native_core_restart",
    "native_get_runtime",
    "native_prepare_shutdown",
    "native_get_settings", "native_patch_settings", "native_set_mode", "native_get_dns",
    "native_save_dns", "native_set_dns_override", "native_import_subscription",
    "native_create_local_profile", "native_subscription_details", "native_patch_subscription",
    "native_update_subscription", "native_activate_profile", "native_delete_profile",
    "native_reorder_profile", "native_test_latency", "native_get_logs",
    "native_list_local_backups", "native_create_local_backup", "native_delete_local_backup",
    "native_import_local_backup", "native_export_local_backup", "native_restore_local_backup",
    "native_get_webdav_config", "native_save_webdav_config", "native_list_webdav_backups",
    "native_create_webdav_backup", "native_delete_webdav_backup", "native_restore_webdav_backup",
];

const SERVICE_STATUS_TIMEOUT: Duration = Duration::from_secs(3);
const SIDECAR_STATUS_TIMEOUT: Duration = Duration::from_secs(1);
const STOP_TIMEOUT: Duration = Duration::from_secs(15);
const DATABASES: [&str; 4] = ["Country.mmdb", "ASN.mmdb", "geoip.dat", "geosite.dat"];
const DNS_SCRIPTS: [&str; 2] = ["set_dns.sh", "unset_dns.sh"];

#[derive(Debug)]
pub(crate) enum ActivationRefused {
    InstanceUnavailable,
    Preflight,
}

impl std::fmt::Display for ActivationRefused {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("Managed activation refused before serving commands")
    }
}

impl std::error::Error for ActivationRefused {}

pub fn activation_exit_code(error: &anyhow::Error) -> Option<u8> {
    error.downcast_ref::<ActivationRefused>().map(|reason| match reason {
        ActivationRefused::InstanceUnavailable => 73,
        ActivationRefused::Preflight => 78,
    })
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ReadProfile {
    uid: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct SaveProfile {
    uid: String,
    content: String,
    expected_revision: String,
}

pub(crate) struct BundlePaths {
    pub(crate) resources: PathBuf,
}

fn ordinary_file(path: &Path, executable: bool) -> Result<()> {
    let metadata = fs::symlink_metadata(path)
        .with_context(|| format!("required bundled file is unavailable: {}", path.display()))?;
    ensure!(
        metadata.is_file(),
        "bundled path is not an ordinary file: {}",
        path.display()
    );
    ensure!(metadata.len() > 0, "bundled file is empty: {}", path.display());
    #[cfg(unix)]
    if executable {
        use std::os::unix::fs::PermissionsExt as _;
        ensure!(
            metadata.permissions().mode() & 0o111 != 0,
            "bundled Core is not executable: {}",
            path.display()
        );
    }
    Ok(())
}

pub(crate) fn inspect_bundle(executable: &Path) -> Result<BundlePaths> {
    ensure!(executable.is_absolute(), "managed helper path must be absolute");
    ordinary_file(executable, true)?;
    let helpers = executable.parent().context("managed helper has no parent")?;
    let contents = helpers.parent().context("managed helper has no bundle contents")?;
    let bundle = contents.parent().context("managed helper has no application bundle")?;
    ensure!(
        executable.file_name().is_some_and(|name| name == "tez-native-host")
            && helpers.file_name().is_some_and(|name| name == "Helpers")
            && contents.file_name().is_some_and(|name| name == "Contents")
            && bundle.extension().is_some_and(|extension| extension == "app"),
        "managed helper must run from its own application Contents/Helpers directory"
    );
    let canonical_helpers = helpers.canonicalize()?;
    ensure!(
        canonical_helpers == helpers,
        "managed Helpers directory must not traverse symlinks"
    );
    for core in crate::config::IVerge::VALID_CLASH_CORES {
        ordinary_file(&helpers.join(crate::core::service::native_core_name(core)), true)?;
    }
    let resources = contents.join("Resources").join("resources");
    ensure!(
        resources.canonicalize()? == resources,
        "managed resource directory must not traverse symlinks"
    );
    for database in DATABASES {
        ordinary_file(&resources.join(database), false)?;
    }
    for script in DNS_SCRIPTS {
        let path = resources.join(script);
        ordinary_file(&path, false)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            ensure!(
                fs::metadata(path)?.permissions().mode() & 0o777 == 0o644,
                "bundled DNS scripts must have mode 0644"
            );
        }
    }
    Ok(BundlePaths { resources })
}

fn require_resource_root(actual: &Path, expected: &Path) -> Result<()> {
    ensure!(
        actual.canonicalize()? == expected,
        "Tauri resolved resources outside the managed helper's application bundle"
    );
    Ok(())
}

fn require_idle_service(code: u16, status: Option<(bool, Option<u64>, Option<u32>, bool)>) -> Result<()> {
    ensure!(
        code == 0,
        "managed activation refused: service ownership status returned code {code}"
    );
    let (active, generation, pid, desired_running) = status.context("service ownership status omitted data")?;
    ensure!(
        !active && generation.is_none() && pid.is_none() && !desired_running,
        "managed activation refused: service has an existing or unresolved Core owner"
    );
    Ok(())
}

async fn check_service_ownership(data_dir: &Path) -> Result<()> {
    let credentials = crate::core::owner_identity::current_owner_credentials_for_root(data_dir)?;
    let response = tokio::time::timeout(
        SERVICE_STATUS_TIMEOUT,
        clash_verge_service_ipc::get_status(&credentials),
    )
    .await
    .context("managed activation refused: service ownership check timed out")?
    .context("managed activation refused: service ownership is unavailable")?;
    require_idle_service(
        response.code,
        response.data.as_ref().map(|status| {
            (
                status.is_active,
                status.active_generation,
                status.core_pid,
                status.desired_core_should_be_running,
            )
        }),
    )
}

fn stale_sidecar_error(kind: std::io::ErrorKind) -> bool {
    matches!(
        kind,
        std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused
    )
}

#[cfg(unix)]
async fn check_sidecar_ownership(socket: &Path) -> Result<()> {
    use std::os::unix::fs::FileTypeExt as _;

    tokio::time::timeout(SIDECAR_STATUS_TIMEOUT, async {
        let metadata = match tokio::fs::symlink_metadata(socket).await {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(error) => return Err(error).context("managed activation refused: cannot inspect sidecar socket"),
        };
        ensure!(
            metadata.file_type().is_socket(),
            "managed activation refused: sidecar path is not an ordinary Unix socket"
        );
        match tokio::net::UnixStream::connect(socket).await {
            Ok(_) => anyhow::bail!("managed activation refused: an unowned sidecar is listening"),
            Err(error) if stale_sidecar_error(error.kind()) => Ok(()),
            Err(error) => Err(error).context("managed activation refused: sidecar ownership is unresolved"),
        }
    })
    .await
    .context("managed activation refused: sidecar ownership check timed out")?
}

fn dispatch_with(
    command: &str,
    params: Value,
    read: impl FnOnce(String) -> CmdResult<Value>,
    save: impl FnOnce(String, String, String) -> CmdResult<Value>,
    control: impl FnOnce(&str, Value) -> CmdResult<Value>,
) -> CmdResult<Value> {
    match command {
        "native_read_profile" => {
            let request: ReadProfile =
                serde_json::from_value(params).map_err(|error| CommandFailure::coded("INVALID_PARAMS", error))?;
            read(request.uid)
        }
        "native_save_profile" => {
            let request: SaveProfile =
                serde_json::from_value(params).map_err(|error| CommandFailure::coded("INVALID_PARAMS", error))?;
            save(request.uid, request.content, request.expected_revision)
        }
        "native_select_route"
        | "native_close_connection"
        | "native_core_start"
        | "native_core_stop"
        | "native_core_restart"
        | "native_get_runtime" => control(command, params),
        _ => Err(CommandFailure::coded(
            "NATIVE_COMMAND_UNAVAILABLE",
            "Command is unavailable",
        )),
    }
}

fn dispatch(command: &str, params: Value) -> CmdResult<Value> {
    if crate::native_chain::COMMANDS.contains(&command) {
        return tauri::async_runtime::block_on(crate::native_chain::dispatch(command, params));
    }
    if crate::native_proxy::COMMANDS.contains(&command) {
        return tauri::async_runtime::block_on(crate::native_proxy::dispatch(command, params));
    }
    #[cfg(target_os = "macos")]
    if command == "native_upgrade_core" {
        return tauri::async_runtime::block_on(crate::native_ownership::upgrade(params));
    }
    #[cfg(target_os = "macos")]
    if command == "native_install_service" {
        return tauri::async_runtime::block_on(crate::native_ownership::install_managed_service(params));
    }
    #[cfg(target_os = "macos")]
    if command == "native_inspect_core" {
        if !params.as_object().is_some_and(serde_json::Map::is_empty) {
            return Err(CommandFailure::coded("INVALID_PARAMS", "Core inspection requires empty params"));
        }
        return tauri::async_runtime::block_on(async {
            serde_json::to_value(crate::native_lifecycle::inspect().await).map_err(CommandFailure::plain)
        });
    }
    #[cfg(target_os = "macos")]
    if command == "native_get_core_control" {
        return tauri::async_runtime::block_on(crate::native_ownership::control_state(params));
    }
    #[cfg(target_os = "macos")]
    if command == "native_prepare_core_upgrade" {
        return tauri::async_runtime::block_on(crate::native_ownership::prepare_upgrade(params));
    }
    if crate::native_workspace::COMMANDS.contains(&command) {
        return tauri::async_runtime::block_on(crate::native_workspace::dispatch(command, params));
    }
    dispatch_with(
        command,
        params,
        |uid| tauri::async_runtime::block_on(crate::native_profile::read(uid)),
        |uid, content, revision| tauri::async_runtime::block_on(crate::native_profile::save(uid, content, revision)),
        |command, params| tauri::async_runtime::block_on(crate::native_control::dispatch(command, params)),
    )
}

#[derive(Default)]
struct ManagedRecovery {
    closing: bool,
    cleanup_owed: bool,
}

impl ManagedRecovery {
    fn observe_owned_core(&mut self, running: bool) {
        self.cleanup_owed |= running;
    }

    fn handle_with(
        &mut self,
        command: &str,
        params: Value,
        execute: impl FnOnce(&str, Value) -> CmdResult<Value>,
        cleanup: impl FnOnce(bool) -> Result<()>,
    ) -> CmdResult<Value> {
        if command == "native_prepare_shutdown" {
            if !params.as_object().is_some_and(serde_json::Map::is_empty) {
                return Err(CommandFailure::coded("INVALID_PARAMS", "Expected empty params"));
            }
            self.prepare_with(cleanup).map_err(|_| {
                CommandFailure::coded(
                    "NATIVE_SHUTDOWN_UNRESOLVED",
                    "Owned runtime cleanup is unresolved; retry shutdown before disconnecting",
                )
            })?;
            return Ok(json!({"safeToExit": true}));
        }
        if self.closing && command != "native_get_runtime" {
            return Err(CommandFailure::coded(
                "NATIVE_SHUTTING_DOWN",
                "The managed session only accepts runtime inspection and shutdown retry",
            ));
        }
        if matches!(command, "native_core_start" | "native_core_restart") {
            if !params.as_object().is_some_and(serde_json::Map::is_empty) {
                return Err(CommandFailure::coded("INVALID_PARAMS", "Expected empty params"));
            }
            // Startup can change DNS before a running mode is published or return an error.
            self.cleanup_owed = true;
        }
        if command == "native_save_profile" {
            let request = serde_json::from_value::<SaveProfile>(params.clone())
                .map_err(|_| CommandFailure::coded("INVALID_PARAMS", "Invalid profile save params"))?;
            crate::native_profile::check_write_params(&request.content, &request.expected_revision)?;
            self.cleanup_owed = true;
        }
        if crate::native_workspace::COMMANDS.contains(&command) {
            crate::native_workspace::validate(command, params.clone())?;
            if crate::native_workspace::mutates(command) { self.cleanup_owed = true; }
        }
        if crate::native_proxy::COMMANDS.contains(&command) {
            if crate::native_proxy::parse(command,params.clone())?.is_some() { self.cleanup_owed = true; }
        }
        if crate::native_chain::COMMANDS.contains(&command) { crate::native_chain::validate(command,params.clone())?; }
        execute(command, params)
    }

    fn prepare_with(&mut self, cleanup: impl FnOnce(bool) -> Result<()>) -> Result<()> {
        self.closing = true;
        if self.cleanup_owed {
            cleanup(self.cleanup_owed)?;
            self.cleanup_owed = false;
        }
        Ok(())
    }
}

#[cfg(target_os = "macos")]
async fn stop_owned_core(cleanup_owed: bool) -> Result<()> {
    let manager = CoreManager::global();
    if !cleanup_owed && matches!(*manager.get_running_mode(), RunningMode::NotRunning) {
        return Ok(());
    }
    tokio::time::timeout(STOP_TIMEOUT, crate::core::timer::Timer::global().drain())
        .await.context("subscription updates have not finished; Core remains running")??;
    Handle::global().set_is_exiting();
    finish_owned_shutdown(
        || async {
            tokio::time::timeout(STOP_TIMEOUT, manager.stop_core())
                .await
                .context("managed shutdown timed out; Core ownership remains unresolved")?
        },
        || matches!(*manager.get_running_mode(), RunningMode::NotRunning),
        crate::utils::resolve::dns::restore_public_dns,
    )
    .await
}

async fn finish_owned_shutdown<Stop, StopFuture, Stopped, Restore, RestoreFuture>(
    stop: Stop,
    stopped: Stopped,
    restore_dns: Restore,
) -> Result<()>
where
    Stop: FnOnce() -> StopFuture,
    StopFuture: std::future::Future<Output = Result<()>>,
    Stopped: FnOnce() -> bool,
    Restore: FnOnce() -> RestoreFuture,
    RestoreFuture: std::future::Future<Output = Result<()>>,
{
    let stop_result = stop().await;
    if !stopped() {
        return stop_result.and(Err(anyhow!(
            "managed shutdown did not confirm that the owned Core stopped"
        )));
    }
    // is_exiting suppresses queued DNS syncs; its explicit restoration has its own process-group deadline.
    let restored = restore_dns().await;
    match (stop_result, restored) {
        (Ok(()), Ok(())) => Ok(()),
        (Err(error), Ok(())) | (Ok(()), Err(error)) => Err(error),
        (Err(error), Err(restore_error)) => {
            Err(error.context(format!("DNS restoration also failed: {restore_error:#}")))
        }
    }
}

fn diagnostic(code: &str, message: &str, core_stopped: bool) -> Value {
    json!({"version": 1, "kind": "diagnostic", "code": code,
        "message": message, "coreStopped": core_stopped})
}

fn shutdown_outcome(served: Result<()>, stopped: Result<()>) -> Result<()> {
    match (served, stopped) {
        (_, Ok(())) => Ok(()),
        (Ok(()), Err(error)) => Err(error),
        (Err(error), Err(stop_error)) => Err(error.context(format!("managed shutdown also failed: {stop_error:#}"))),
    }
}

pub fn run_stdio() -> Result<()> {
    run_stdio_with(None)
}

#[cfg(target_os = "macos")]
pub(crate) fn run_restored(proof: clash_verge_service_ipc::OwnerSessionProof) -> Result<()> {
    run_stdio_with(Some(proof))
}

fn run_stdio_with(restored: Option<clash_verge_service_ipc::OwnerSessionProof>) -> Result<()> {
    #[cfg(not(target_os = "macos"))]
    anyhow::bail!("managed native runtime is supported only on macOS");

    #[cfg(target_os = "macos")]
    {
        crate::native_host::require_inherited_pipes().context(ActivationRefused::Preflight)?;
        // Keep this descriptor alive until controlled shutdown has completed.
        let _instance_lock =
            crate::utils::server::try_acquire_native_instance_lock().context(ActivationRefused::InstanceUnavailable)?;
        // Only these pre-command checks can certify a refusal without Core or network effects.
        let (socket, bundle, mut recovery_channel, data) = (|| -> Result<_> {
            let data_dir = crate::utils::dirs::app_home_dir()?;
            if let Some(proof) = &restored {
                let credentials = crate::core::owner_identity::current_owner_credentials_for_root(&data_dir)?;
                let response = tauri::async_runtime::block_on(clash_verge_service_ipc::recover_core_session(&credentials, proof))?;
                ensure!(response.code == 0 && response.data.is_some(), "Service refused restored owner session");
            } else {
                tauri::async_runtime::block_on(check_service_ownership(&data_dir))?;
            }
            let socket = crate::utils::dirs::sidecar_ipc_path()?;
            tauri::async_runtime::block_on(check_sidecar_ownership(&socket))?;
            if restored.is_none() { tauri::async_runtime::block_on(crate::native_lifecycle::require_start_admission())?; }
            let bundle = inspect_bundle(&std::env::current_exe()?)?;
            let recovery = crate::native_recovery::RecoveryChannel::from_env()?;
            let data = NativeData::new_attach(data_dir, None)?;
            Ok((socket, bundle, recovery, data))
        })()
        .context(ActivationRefused::Preflight)?;
        let pac_server = tauri::async_runtime::block_on(crate::utils::server::start_native_pac_server())?;
        let activity_data = data.clone();
        let mut context = tauri::generate_context!();
        context.config_mut().app.windows.clear();
        let result = Arc::new(Mutex::new(None::<Result<()>>));
        let exit_confirmed = Arc::new(AtomicBool::new(false));
        let worker_result = result.clone();
        let worker_exit = exit_confirmed.clone();
        let app = tauri::Builder::default()
            .plugin(tauri_plugin_shell::init())
            .plugin(tauri_plugin_clash_verge_sysinfo::init())
            .plugin(tauri_plugin_notification::init())
            .plugin(
                tauri_plugin_mihomo::Builder::new()
                    .protocol(tauri_plugin_mihomo::models::Protocol::LocalSocket)
                    .socket_path(socket.to_string_lossy().into_owned())
                    .build(),
            )
            .setup(move |app| {
                require_resource_root(&app.path().resource_dir()?.join("resources"), &bundle.resources)?;
                crate::APP_HANDLE
                    .set(app.handle().clone())
                    .map_err(|_| anyhow!("application handle is already initialized"))?;
                let handle = app.handle().clone();
                std::thread::Builder::new()
                    .name("tez-native-managed".into())
                    .spawn(move || {
                        let recovery = Rc::new(RefCell::new(ManagedRecovery::default()));
                        let commands = recovery.clone();
                        let served = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                            if let Some(proof) = restored {
                                tauri::async_runtime::block_on(CoreManager::global().restore_native_service(proof))?;
                                // A recovered core does not execute the normal start callback.
                                // Scheduler failure must not stop that already-running core.
                                if tauri::async_runtime::block_on(crate::core::timer::Timer::global().init()).is_err() {
                                    eprintln!("{{\"version\":1,\"kind\":\"diagnostic\",\"code\":\"NATIVE_TIMER_RECOVERY_FAILED\",\"message\":\"Core control recovered; subscription scheduling initialization failed\"}}");
                                }
                            }
                            let mut capabilities = CAPABILITIES.to_vec();
                            if tauri::async_runtime::block_on(crate::native_ownership::supported()) {
                                capabilities.extend(["native_upgrade_core", "native_prepare_core_upgrade", "native_get_core_control"]);
                                if crate::native_ownership::service_tools_available() {
                                    capabilities.extend(["native_install_service", "native_inspect_core"]);
                                }
                            }
                            crate::native_host::serve_managed_with_activity(
                                || Ok(tauri::async_runtime::block_on(data.snapshot())),
                                |query| Ok(tauri::async_runtime::block_on(activity_data.activity_query(query))),
                                move |command, params| {
                                    #[cfg(feature = "native-lifecycle-acceptance")]
                                    if command == "native_core_restart" || (command == "native_core_start" && matches!(*CoreManager::global().get_running_mode(), RunningMode::NotRunning)) {
                                        return Err(CommandFailure::coded("ACCEPTANCE_START_REFUSED", "Acceptance package only recovers its isolated running core"));
                                    }
                                    if command == "native_core_start"
                                        && params.as_object().is_some_and(serde_json::Map::is_empty)
                                        && matches!(*CoreManager::global().get_running_mode(), RunningMode::NotRunning)
                                    {
                                        // Refusal here precedes cleanup obligations and all startup effects.
                                        tauri::async_runtime::block_on(crate::native_lifecycle::require_start_admission())
                                            .map_err(|error| CommandFailure::coded("CORE_START_ADMISSION_REFUSED", error))?;
                                    }
                                    let mut recovery = commands.borrow_mut();
                                    recovery.observe_owned_core(!matches!(
                                        *CoreManager::global().get_running_mode(),
                                        RunningMode::NotRunning
                                    ));
                                    recovery.handle_with(command, params, dispatch, |owed| {
                                        tauri::async_runtime::block_on(stop_owned_core(owed))
                                    })
                                },
                                Some(&capabilities),
                            )
                        }))
                        .unwrap_or_else(|_| Err(anyhow!("managed pipe worker panicked")));
                        let mut stopped = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                            let mut recovery = recovery.borrow_mut();
                            recovery.observe_owned_core(!matches!(
                                *CoreManager::global().get_running_mode(),
                                RunningMode::NotRunning
                            ));
                            recovery.prepare_with(|owed| tauri::async_runtime::block_on(stop_owned_core(owed)))
                        }))
                        .unwrap_or_else(|_| Err(anyhow!("managed controlled shutdown panicked")));
                        if stopped.is_err()
                            && let Some(channel) = recovery_channel.as_mut()
                        {
                            eprintln!(
                                "{}",
                                diagnostic(
                                    "NATIVE_SHUTDOWN_RECOVERY_READY",
                                    "The managed session is awaiting an authenticated shutdown retry",
                                    false,
                                )
                            );
                            stopped = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                                channel.wait_and_retry(|| {
                                    let mut recovery = recovery.borrow_mut();
                                    recovery.observe_owned_core(!matches!(
                                        *CoreManager::global().get_running_mode(),
                                        RunningMode::NotRunning
                                    ));
                                    recovery.prepare_with(|owed| tauri::async_runtime::block_on(stop_owned_core(owed)))
                                })
                            }))
                            .unwrap_or_else(|_| Err(anyhow!("managed recovery worker panicked")));
                        }
                        let safe_to_exit = stopped.is_ok();
                        let session_failed = served.is_err();
                        let outcome = shutdown_outcome(served, stopped);
                        let exit_code = i32::from(outcome.is_err());
                        if session_failed || outcome.is_err() {
                            let failure = if safe_to_exit {
                                diagnostic("NATIVE_SESSION_FAILED", "The native pipe session failed", true)
                            } else {
                                diagnostic(
                                    "NATIVE_SHUTDOWN_UNRESOLVED",
                                    "Core shutdown failed; the managed process retains its ownership lock",
                                    false,
                                )
                            };
                            eprintln!("{failure}");
                        }
                        if let Ok(mut result) = worker_result.lock() {
                            *result = Some(outcome);
                        }
                        if safe_to_exit {
                            crate::core::logger::Logger::global().flush_logs();
                            worker_exit.store(true, Ordering::Release);
                            handle.exit(exit_code);
                        }
                    })?;
                Ok(())
            })
            .build(context)
            .context("failed to build managed native runtime")?;
        app.run(move |_, event| {
            if let tauri::RunEvent::ExitRequested { api, .. } = event
                && !exit_confirmed.load(Ordering::Acquire)
            {
                api.prevent_exit();
            }
        });
        let outcome = result
            .lock()
            .map_err(|_| anyhow!("managed runtime result lock was poisoned"))?
            .take()
            .unwrap_or_else(|| Err(anyhow!("managed runtime exited without confirmed pipe shutdown")));
        outcome.and(tauri::async_runtime::block_on(pac_server.shutdown()))
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn native_pac_server_lifetime_brackets_managed_runtime() {
        let source = include_str!("native_managed.rs");
        let production = source.split("\n#[cfg(test)]").next().unwrap();
        let initialization = production.find("start_native_pac_server");
        assert!(initialization.is_some(), "native management must initialize its PAC listener");
        assert!(initialization.unwrap() < production.find(".setup(move |app|").unwrap());
        assert!(production.find("pac_server.shutdown()").unwrap() > production.find("app.run(move").unwrap());
    }

    #[test]
    fn startup_refusal_codes_do_not_certify_runtime_failures() {
        use super::*;
        let busy = anyhow!("lock unavailable").context(ActivationRefused::InstanceUnavailable);
        let refused = anyhow!("preflight refused").context(ActivationRefused::Preflight);
        assert_eq!(activation_exit_code(&busy), Some(73));
        assert_eq!(activation_exit_code(&refused), Some(78));
        assert_eq!(activation_exit_code(&anyhow!("runtime failure")), None);
    }
    use super::*;

    #[test]
    fn recovery_retries_failed_cleanup_and_does_not_repeat_confirmed_cleanup_at_eof() {
        let mut recovery = ManagedRecovery::default();
        recovery
            .handle_with("native_core_start", json!({}), |_, _| Ok(json!({})), |_| unreachable!())
            .unwrap();
        let failure = recovery
            .handle_with(
                "native_prepare_shutdown",
                json!({}),
                |_, _| unreachable!(),
                |owed| {
                    assert!(owed);
                    Err(anyhow!("private-cleanup-detail"))
                },
            )
            .unwrap_err();
        assert_eq!(failure.code.as_deref(), Some("NATIVE_SHUTDOWN_UNRESOLVED"));
        assert!(
            !serde_json::to_string(&failure)
                .unwrap()
                .contains("private-cleanup-detail")
        );
        assert!(recovery.closing && recovery.cleanup_owed);
        for command in [
            "native_core_start",
            "native_core_stop",
            "native_core_restart",
            "native_save_profile",
            "native_read_profile",
            "native_select_route",
        ] {
            let failure = recovery
                .handle_with(
                    command,
                    json!({}),
                    |_, _| panic!("closing must prevent dispatch"),
                    |_| unreachable!(),
                )
                .unwrap_err();
            assert_eq!(failure.code.as_deref(), Some("NATIVE_SHUTTING_DOWN"));
        }
        assert!(
            recovery
                .handle_with(
                    "native_get_runtime",
                    json!({}),
                    |_, _| Ok(json!({"running":false})),
                    |_| unreachable!()
                )
                .is_ok()
        );
        let response = recovery
            .handle_with(
                "native_prepare_shutdown",
                json!({}),
                |_, _| unreachable!(),
                |owed| {
                    assert!(owed);
                    Ok(())
                },
            )
            .unwrap();
        assert_eq!(response, json!({"safeToExit":true}));
        assert!(recovery.closing && !recovery.cleanup_owed);
        assert_eq!(
            recovery
                .handle_with(
                    "native_prepare_shutdown",
                    json!({}),
                    |_, _| unreachable!(),
                    |_| panic!("repeated prepare must not restore DNS twice"),
                )
                .unwrap(),
            json!({"safeToExit":true})
        );
        recovery
            .prepare_with(|_| panic!("confirmed cleanup must not run twice"))
            .unwrap();
    }

    #[test]
    fn failed_start_and_profile_save_still_owe_cleanup_without_a_running_mode() {
        for (command, params) in [
            ("native_core_start", json!({})),
            ("native_core_restart", json!({})),
            (
                "native_save_profile",
                json!({"uid":"fixture","content":"value","expectedRevision":"0".repeat(64)}),
            ),
        ] {
            let mut recovery = ManagedRecovery::default();
            let failure = recovery.handle_with(
                command,
                params,
                |_, _| Err(CommandFailure::coded("INJECTED_START_FAILURE", "injected")),
                |_| unreachable!(),
            );
            assert!(failure.is_err());
            assert!(recovery.cleanup_owed);
            recovery.observe_owned_core(false);
            assert!(recovery.cleanup_owed);
            let mut cleaned = false;
            recovery
                .prepare_with(|owed| {
                    cleaned = owed;
                    Ok(())
                })
                .unwrap();
            assert!(cleaned && !recovery.cleanup_owed);
        }
    }

    #[test]
    fn invalid_commands_do_not_claim_network_effects_or_begin_shutdown() {
        for (command, params) in [
            ("native_core_start", json!({"extra":true})),
            ("native_core_restart", json!({"extra":true})),
            ("native_save_profile", json!({"uid":"fixture"})),
            (
                "native_save_profile",
                json!({"uid":"fixture","content":"value","expectedRevision":"invalid"}),
            ),
            ("native_prepare_shutdown", json!({"extra":true})),
        ] {
            let mut recovery = ManagedRecovery::default();
            assert!(
                recovery
                    .handle_with(command, params, |_, _| unreachable!(), |_| unreachable!())
                    .is_err()
            );
            assert!(!recovery.closing && !recovery.cleanup_owed);
            recovery
                .prepare_with(|_| panic!("never-owned session must not restore DNS"))
                .unwrap();
        }
    }

    #[test]
    fn observed_owned_core_and_cleanup_panic_preserve_recovery_obligations() {
        let mut recovery = ManagedRecovery::default();
        recovery.observe_owned_core(true);
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            recovery.prepare_with(|_| panic!("injected cleanup panic"))
        }));
        assert!(result.is_err());
        assert!(recovery.closing && recovery.cleanup_owed);
        recovery.prepare_with(|_| Ok(())).unwrap();
        assert!(!recovery.cleanup_owed);
    }

    #[test]
    fn protocol_failure_does_not_negate_confirmed_cleanup_or_hide_cleanup_failure() {
        assert!(shutdown_outcome(Err(anyhow!("protocol failed")), Ok(())).is_ok());
        assert!(shutdown_outcome(Ok(()), Err(anyhow!("cleanup failed"))).is_err());
        let error = shutdown_outcome(Err(anyhow!("protocol failed")), Err(anyhow!("cleanup failed"))).unwrap_err();
        let details = format!("{error:#}");
        assert!(details.contains("protocol failed") && details.contains("cleanup failed"));
    }

    #[tokio::test]
    async fn managed_shutdown_requires_stop_confirmation_before_dns_restoration() {
        use std::cell::Cell;
        let restored = Cell::new(false);
        let result = finish_owned_shutdown(
            || async { Ok(()) },
            || false,
            || async {
                restored.set(true);
                Ok(())
            },
        )
        .await;
        assert!(result.is_err());
        assert!(!restored.get());
    }

    #[tokio::test]
    async fn managed_shutdown_does_not_hide_dns_failure() {
        let result = finish_owned_shutdown(
            || async { Ok(()) },
            || true,
            || async { Err(anyhow!("injected DNS failure")) },
        )
        .await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn managed_shutdown_restores_dns_after_stopped_transition_error() {
        use std::cell::Cell;
        let restored = Cell::new(false);
        let result = finish_owned_shutdown(
            || async { Err(anyhow!("injected stop error")) },
            || true,
            || async {
                restored.set(true);
                Ok(())
            },
        )
        .await;
        assert!(result.is_err());
        assert!(restored.get());
    }

    struct Fixture(PathBuf);

    impl Fixture {
        fn new() -> Result<Self> {
            let root = std::env::temp_dir()
                .canonicalize()?
                .join(format!("tez-managed-gate-{}", nanoid::nanoid!()));
            let helpers = root.join("Preview.app/Contents/Helpers");
            let resources = root.join("Preview.app/Contents/Resources/resources");
            fs::create_dir_all(&helpers)?;
            fs::create_dir_all(&resources)?;
            let fixture = Self(root);
            for name in
                std::iter::once("tez-native-host").chain(crate::config::IVerge::VALID_CLASH_CORES.iter().map(|name|crate::core::service::native_core_name(name)))
            {
                let file = helpers.join(name);
                fs::write(&file, b"injected fixture")?;
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt as _;
                    fs::set_permissions(file, fs::Permissions::from_mode(0o700))?;
                }
            }
            for name in DATABASES.into_iter().chain(DNS_SCRIPTS) {
                fs::write(resources.join(name), b"injected fixture")?;
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt as _;
                    fs::set_permissions(resources.join(name), fs::Permissions::from_mode(0o644))?;
                }
            }
            Ok(fixture)
        }

        fn executable(&self) -> PathBuf {
            self.0.join("Preview.app/Contents/Helpers/tez-native-host")
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn bundle_gate_requires_own_complete_resources() -> Result<()> {
        let fixture = Fixture::new()?;
        assert!(inspect_bundle(&fixture.executable()).is_ok());
        fs::remove_file(fixture.0.join("Preview.app/Contents/Resources/resources/ASN.mmdb"))?;
        assert!(inspect_bundle(&fixture.executable()).is_err());
        Ok(())
    }

    #[test]
    fn bundle_gate_requires_dns_scripts_with_safe_permissions() -> Result<()> {
        let fixture = Fixture::new()?;
        let script = fixture.0.join("Preview.app/Contents/Resources/resources/unset_dns.sh");
        fs::remove_file(&script)?;
        assert!(inspect_bundle(&fixture.executable()).is_err());
        fs::write(&script, b"fixture")?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            fs::set_permissions(&script, fs::Permissions::from_mode(0o666))?;
            assert!(inspect_bundle(&fixture.executable()).is_err());
            fs::remove_file(&script)?;
            std::os::unix::fs::symlink("set_dns.sh", &script)?;
            assert!(inspect_bundle(&fixture.executable()).is_err());
        }
        Ok(())
    }

    #[cfg(unix)]
    #[test]
    fn bundle_gate_refuses_a_borrowed_core_symlink() -> Result<()> {
        let fixture = Fixture::new()?;
        let helpers = fixture.executable().parent().context("fixture parent")?.to_path_buf();
        let core = helpers.join(crate::core::service::native_core_name(crate::config::IVerge::VALID_CLASH_CORES[0]));
        fs::remove_file(&core)?;
        std::os::unix::fs::symlink(helpers.join(crate::core::service::native_core_name(crate::config::IVerge::VALID_CLASH_CORES[1])), core)?;
        assert!(inspect_bundle(&fixture.executable()).is_err());
        Ok(())
    }

    #[test]
    fn ownership_gate_refuses_active_incomplete_and_unreadable_status() {
        assert!(require_idle_service(0, Some((false, None, None, false))).is_ok());
        for status in [
            None,
            Some((true, None, None, false)),
            Some((false, Some(1), None, false)),
            Some((false, None, Some(1), false)),
            Some((false, None, None, true)),
        ] {
            assert!(require_idle_service(0, status).is_err());
        }
        assert!(require_idle_service(1, Some((false, None, None, false))).is_err());
    }

    #[test]
    fn only_missing_and_connection_refused_are_stale_sidecar_errors() {
        use std::io::ErrorKind;

        assert!(stale_sidecar_error(ErrorKind::NotFound));
        assert!(stale_sidecar_error(ErrorKind::ConnectionRefused));
        for kind in [
            ErrorKind::PermissionDenied,
            ErrorKind::TimedOut,
            ErrorKind::ConnectionReset,
            ErrorKind::Other,
        ] {
            assert!(!stale_sidecar_error(kind));
        }
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn sidecar_gate_refuses_listener_and_symlink_without_deleting_them() -> Result<()> {
        struct SocketFixture(PathBuf);
        impl Drop for SocketFixture {
            fn drop(&mut self) {
                let _ = fs::remove_file(&self.0);
            }
        }

        let socket = SocketFixture(
            std::env::temp_dir()
                .canonicalize()?
                .join(format!("tez-{}", nanoid::nanoid!(6))),
        );
        assert!(check_sidecar_ownership(&socket.0).await.is_ok());
        let listener = tokio::net::UnixListener::bind(&socket.0)?;
        assert!(check_sidecar_ownership(&socket.0).await.is_err());
        assert!(fs::symlink_metadata(&socket.0).is_ok());
        drop(listener);
        assert!(check_sidecar_ownership(&socket.0).await.is_ok());
        fs::remove_file(&socket.0)?;
        std::os::unix::fs::symlink("missing-injected-socket", &socket.0)?;
        assert!(check_sidecar_ownership(&socket.0).await.is_err());
        assert!(fs::symlink_metadata(&socket.0)?.file_type().is_symlink());
        Ok(())
    }

    #[test]
    fn dispatch_rejects_bad_profile_params_before_adapters() {
        for (command, params) in [
            ("native_read_profile", json!({"uid": "fixture", "extra": 1})),
            ("native_save_profile", json!({"uid": "fixture", "content": ""})),
            ("install_service", json!({})),
        ] {
            let result = dispatch_with(
                command,
                params,
                |_| panic!("read adapter must not run"),
                |_, _, _| panic!("save adapter must not run"),
                |_, _| panic!("control adapter must not run"),
            );
            assert!(result.is_err());
        }
    }

    #[test]
    fn dispatch_preserves_profile_and_control_results() {
        let closed = dispatch_with(
            "native_close_connection", json!({"id":"connection-1"}),
            |_| unreachable!(), |_, _, _| unreachable!(),
            |command, params| {
                assert_eq!(command, "native_close_connection");
                assert_eq!(params["id"], "connection-1");
                Ok(json!({"closed":true,"id":"connection-1"}))
            },
        );
        assert_eq!(closed.unwrap()["closed"], true);
        let read = dispatch_with(
            "native_read_profile",
            json!({"uid": "fixture"}),
            |uid| Ok(json!({"uid": uid})),
            |_, _, _| unreachable!(),
            |_, _| unreachable!(),
        );
        assert_eq!(read, Ok(json!({"uid": "fixture"})));
        let failure = CommandFailure::coded("CORE_STOP_FAILED", "injected stop failure");
        let result = dispatch_with(
            "native_core_stop",
            json!({}),
            |_| unreachable!(),
            |_, _, _| unreachable!(),
            |command, params| {
                assert_eq!(command, "native_core_stop");
                assert_eq!(params, json!({}));
                Err(failure.clone())
            },
        );
        assert_eq!(result, Err(failure));
    }

    #[test]
    fn shutdown_diagnostic_contains_no_runtime_error_details() {
        let value = diagnostic("NATIVE_SHUTDOWN_UNRESOLVED", "Core shutdown failed", false);
        assert_eq!(value["coreStopped"], false);
        assert_eq!(value.as_object().map(serde_json::Map::len), Some(5));
        assert!(value.get("detail").is_none());
    }
}
