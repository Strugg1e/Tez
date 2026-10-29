use crate::{
    cmd::{CmdResult, CommandFailure},
    config::Config,
    core::{CoreManager, owner_identity::current_owner_credentials},
};
use anyhow::{Context as _, Result, ensure};
use clash_verge_service_ipc::{self as service, CoreIdentity, OwnerSessionProof, UpgradeCoreRequest};
use serde::Deserialize;
use serde_json::{Value, json};

pub(crate) async fn supported() -> bool {
    service::get_version()
        .await
        .ok()
        .filter(|response| response.code == 0)
        .and_then(|response| response.data)
        .is_some_and(|info| info.supports_tez_lifecycle())
}

pub(crate) async fn recover() -> Option<OwnerSessionProof> {
    if !supported().await {
        return None;
    }
    let credentials = current_owner_credentials().ok()?;
    let status = service::get_status(&credentials).await.ok()?.data?;
    if !status.is_active || status.core_pid.is_none() {
        return None;
    }
    let proof = service::load_owner_session(&credentials, status.active_generation?).ok()??;
    let recovered = service::recover_core_session(&credentials, &proof).await.ok()?.data?;
    if Some(recovered.identity.pid) != status.core_pid || Some(recovered.identity.started_at) != status.core_started_at
    {
        return None;
    }
    Some(proof)
}

pub(crate) fn can_offer_claim() -> bool {
    std::env::current_exe()
        .ok()
        .is_some_and(|executable| crate::native_managed::inspect_bundle(&executable).is_ok())
}

pub(crate) fn can_offer_service_install(inspection: &crate::native_lifecycle::Inspection) -> bool {
    if inspection.reason == "client-already-running" || !service_install_target_available(inspection) {
        return false;
    }
    service_tools_available()
}

pub(crate) fn service_tools_available() -> bool {
    let Ok(executable) = std::env::current_exe() else { return false; };
    if crate::native_managed::inspect_bundle(&executable).is_err() { return false; }
    let Some(helpers) = executable.parent() else { return false; };
    ["tez-service", "tez-service-install", "tez-service-uninstall"].iter().all(|name| {
        std::fs::symlink_metadata(helpers.join(name)).is_ok_and(|metadata| {
            use std::os::unix::fs::PermissionsExt as _;
            metadata.is_file() && metadata.len() > 0 && metadata.permissions().mode() & 0o111 != 0
        })
    })
}

fn service_install_target_available(inspection: &crate::native_lifecycle::Inspection) -> bool {
    if inspection.service_control_available {
        return inspection.can_start && inspection.state == "stopped" && inspection.source == "service";
    }
    inspection.can_start
        || (inspection.reason == "service-unavailable" && inspection.processes.is_empty())
        || (inspection.state == "runningReadOnly" && inspection.source == "service")
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct InstallServiceParams {
    confirmed: bool,
    expected: Option<CoreIdentity>,
}

fn parse_install_request(params: Value) -> CmdResult<InstallServiceParams> {
    let request: InstallServiceParams = serde_json::from_value(params)
        .map_err(|_| CommandFailure::coded("INVALID_PARAMS", "Expected explicit installation confirmation and observed core identity"))?;
    if !request.confirmed {
        return Err(CommandFailure::coded("CORE_CONFIRMATION_REQUIRED", "Service installation requires explicit confirmation"));
    }
    Ok(request)
}

fn validate_install_identity(expected: Option<&CoreIdentity>, inspection: &crate::native_lifecycle::Inspection) -> Result<()> {
    ensure!(service_install_target_available(inspection), "Service installation is unavailable in the current state");
    match expected {
        Some(expected) => ensure!(inspection.state == "runningReadOnly" && inspection.source == "service"
            && inspection.core_pid == Some(expected.pid)
            && inspection.service_generation == Some(expected.generation)
            && inspection.service_started_at == Some(expected.started_at), "Core identity changed; inspect again before installing"),
        None => ensure!(inspection.core_pid.is_none() && inspection.processes.is_empty(), "A running core requires explicit identity confirmation"),
    }
    Ok(())
}

pub(crate) async fn install_service(params: Value) -> CmdResult<Value> {
    let request = parse_install_request(params)?;
    let result: Result<Value> = async {
        let _instance = crate::utils::server::try_acquire_native_instance_lock()?;
        let inspection = crate::native_lifecycle::inspect().await;
        validate_install_identity(request.expected.as_ref(), &inspection)?;
        ensure!(can_offer_service_install(&inspection), "Required bundled service tools are unavailable");
        install_service_tools().await?;
        Ok(json!({"installed":true,"reconnectRequired":true}))
    }.await;
    result.map_err(service_install_failure)
}

fn validate_managed_install_identity(
    request: &InstallServiceParams,
    inspection: &crate::native_lifecycle::Inspection,
    mode: crate::core::manager::RunningMode,
    core_busy: bool,
) -> Result<()> {
    ensure!(matches!(mode, crate::core::manager::RunningMode::NotRunning), "Stop the owned core before reinstalling the service");
    ensure!(!core_busy, "Another or recovering core session prevents service reinstallation");
    ensure!(inspection.service_control_available, "Managed reinstallation requires a compatible Tez service");
    ensure!(request.expected.is_none(), "A running-core confirmation cannot authorize idle reinstallation");
    validate_install_identity(None, inspection)
}

/// The managed command dispatcher retains the instance lock throughout this idle-only operation.
pub(crate) async fn install_managed_service(params: Value) -> CmdResult<Value> {
    let request = parse_install_request(params)?;
    let result: Result<Value> = async {
        let write = Config::lock_config_write().await;
        let manager = CoreManager::global();
        let _update = manager.claim_config_update(&write)?;
        let inspection = crate::native_lifecycle::inspect().await;
        let installation = service::inspect_installation(&[]).await?;
        validate_managed_install_identity(&request, &inspection, *manager.get_running_mode(), installation.core_busy)?;
        ensure!(service_tools_available(), "Required bundled service tools are unavailable");
        let _execution = service::execution::CoreExecutionGuard::acquire()?;
        let inspection = crate::native_lifecycle::inspect().await;
        validate_managed_install_identity(&request, &inspection, *manager.get_running_mode(), false)?;
        install_service_tools().await?;
        Ok(json!({"installed":true,"reconnectRequired":false}))
    }.await;
    result.map_err(service_install_failure)
}

async fn install_service_tools() -> Result<()> {
    let helpers = std::env::current_exe()?.parent().context("Missing helpers directory")?.to_path_buf();
    tokio::task::spawn_blocking(move || {
        let cores = crate::config::IVerge::VALID_CLASH_CORES.iter().map(|name| service::management::CoreSource {
            name: crate::core::service::native_core_name(name).into(), path: helpers.join(crate::core::service::native_core_name(name)),
        }).collect::<Vec<_>>();
        service::management::install(&helpers.join("tez-service-install"), &cores, false,
            Some(unsafe { libc::getegid() }), "Tez needs administrator authorization to upgrade its background service. The current proxy may be interrupted.")
    }).await??;
    ensure!(supported().await, "Installed service did not confirm Tez lifecycle support");
    Ok(())
}

fn service_install_failure(error: anyhow::Error) -> CommandFailure {
    let cancelled = format!("{error:#}").contains("(-128)");
    CommandFailure::coded(if cancelled { "SERVICE_INSTALL_CANCELLED" } else { "SERVICE_INSTALL_FAILED" },
        if cancelled { "Administrator authorization was cancelled. Inspect the current core before retrying." }
        else { "Service upgrade was not confirmed. Inspect the current core and retry explicitly; no automatic retry was scheduled." })
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ClaimParams {
    confirmed: bool,
    expected: CoreIdentity,
}

pub(crate) async fn claim(params: Value) -> CmdResult<Value> {
    let request: ClaimParams = serde_json::from_value(params)
        .map_err(|_| CommandFailure::coded("INVALID_PARAMS", "Expected a confirmed, inspected core identity"))?;
    if !request.confirmed {
        return Err(CommandFailure::coded(
            "CORE_CONFIRMATION_REQUIRED",
            "Core ownership must be explicitly confirmed",
        ));
    }
    let result: Result<Value> = async {
        ensure!(
            supported().await && can_offer_claim(),
            "Core claim prerequisites are unavailable"
        );
        let _instance = crate::utils::server::try_acquire_native_instance_lock()?;
        let credentials = current_owner_credentials()?;
        let mut random = [0u8; 32];
        getrandom::fill(&mut random)?;
        let token: String = random.iter().map(|byte| format!("{byte:02x}")).collect();
        service::save_owner_session(&credentials, &token, None)?;
        let response = service::claim_core(
            &credentials,
            &service::ClaimCoreRequest {
                expected: request.expected,
                proposed_session_token: token.clone(),
            },
        )
        .await?;
        ensure!(response.code == 0, "Core claim rejected (code {})", response.code);
        let snapshot = response.data.context("Core claim response omitted identity")?;
        let persisted = service::save_owner_session(&credentials, &token, Some(snapshot.identity.generation)).is_ok();
        Ok(json!({"claimed":true,"reconnectRequired":true,"receiptConfirmed":persisted,"pid":snapshot.identity.pid}))
    }
    .await;
    result.map_err(|_| {
        CommandFailure::coded(
            "CORE_CLAIM_FAILED",
            "Core claim was not confirmed; reconnect to inspect the current owner. No stop or restart was requested",
        )
    })
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct UpgradeParams {
    confirmed: bool,
    expected: CoreIdentity,
    approved_core_path: String,
    sha256: String,
    version: String,
}

pub(crate) async fn upgrade(params: Value) -> CmdResult<Value> {
    let request: UpgradeParams = serde_json::from_value(params).map_err(|_| {
        CommandFailure::coded(
            "INVALID_PARAMS",
            "Expected a confirmed approved core version and inspected identity",
        )
    })?;
    if !request.confirmed {
        return Err(CommandFailure::coded(
            "CORE_CONFIRMATION_REQUIRED",
            "Core upgrade must be explicitly confirmed",
        ));
    }
    let mut request = UpgradeCoreRequest {
        expected: request.expected,
        approved_core_path: request.approved_core_path,
        sha256: request.sha256,
        version: request.version,
    };
    let credentials = current_owner_credentials().map_err(CommandFailure::plain)?;
    let source = std::path::Path::new(&request.approved_core_path);
    let staging = std::path::Path::new(&credentials.app_data_dir).join("native-upgrades");
    if source.parent() == Some(staging.as_path()) {
        if source.file_name().and_then(|name| name.to_str()) != Some(format!("tez-{}", request.sha256).as_str())
            || service::management::sha256_file(source).ok().as_deref() != Some(request.sha256.as_str())
        {
            return Err(CommandFailure::coded(
                "CORE_PACKAGE_CHANGED",
                "Prepared core changed before approval",
            ));
        }
        crate::core::service::stage_approved_core(source).map_err(|_| {
            CommandFailure::coded(
                "CORE_APPROVAL_FAILED",
                "Core approval was cancelled or failed; upgrade was not requested",
            )
        })?;
        request.approved_core_path = service::service_paths()
            .map_err(CommandFailure::plain)?
            .core_dir()
            .join(source.file_name().expect("validated core name"))
            .to_string_lossy()
            .into_owned();
    }
    let outcome = CoreManager::global()
        .upgrade_native_service(&request)
        .await
        .map_err(|_| {
            CommandFailure::coded(
                "CORE_UPGRADE_UNRESOLVED",
                "Upgrade or rollback was not confirmed; inspect the current runtime before retrying",
            )
        })?;
    let credentials = current_owner_credentials().map_err(CommandFailure::plain)?;
    let preference_saved =
        service::save_owner_core(&credentials, &outcome.session.core_path, &outcome.session.core_sha256).is_ok();
    Ok(
        json!({"outcome":outcome.outcome,"pid":outcome.session.identity.pid,"coreSHA256":outcome.session.core_sha256,
        "versionSelectionSaved":preference_saved,"message":outcome.failure}),
    )
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct PrepareParams {
    source_path: String,
    version: String,
}

pub(crate) async fn prepare_upgrade(params: Value) -> CmdResult<Value> {
    let request: PrepareParams = serde_json::from_value(params)
        .map_err(|_| CommandFailure::coded("INVALID_PARAMS", "Expected sourcePath and version"))?;
    let credentials = current_owner_credentials().map_err(CommandFailure::plain)?;
    let staged = service::prepare_owner_core(
        &credentials,
        std::path::Path::new(&request.source_path),
        &request.version,
    )
    .await
    .map_err(|_| {
        CommandFailure::coded(
            "CORE_PACKAGE_REJECTED",
            "Core must be a signed native Mach-O binary with a valid version",
        )
    })?;
    serde_json::to_value(staged).map_err(CommandFailure::plain)
}

pub(crate) async fn control_state(params: Value) -> CmdResult<Value> {
    if !params.as_object().is_some_and(serde_json::Map::is_empty) {
        return Err(CommandFailure::coded("INVALID_PARAMS", "Expected empty params"));
    }
    let result: Result<Value> = async {
        let credentials = current_owner_credentials()?;
        let proof = crate::core::service::active_service_session()?;
        let response = service::get_status(&credentials).await?;
        ensure!(response.code == 0, "Service status unavailable");
        let status = response.data.context("Missing service status")?;
        ensure!(
            status.is_active && status.active_generation == Some(proof.generation),
            "Service session changed"
        );
        Ok(json!({"generation":proof.generation,"pid":status.core_pid,"started_at":status.core_started_at}))
    }
    .await;
    result.map_err(|_| CommandFailure::coded("CORE_CONTROL_UNAVAILABLE", "Owned core identity could not be confirmed"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn native_compatible_idle_service_can_be_explicitly_reinstalled() {
        let inspection = crate::native_lifecycle::Inspection {
            state: "stopped", source: "service", can_start: true, reason: "idle-service",
            core_pid: None, service_generation: None, service_started_at: None,
            service_protocol: Some("2.6".into()), service_control_available: true, processes: vec![],
        };
        assert!(service_install_target_available(&inspection));
        assert!(validate_install_identity(None, &inspection).is_ok());
    }

    #[test]
    fn native_managed_reinstallation_requires_a_confirmed_idle_owned_runtime() {
        use crate::core::manager::RunningMode;
        let request = InstallServiceParams { confirmed: true, expected: None };
        let mut inspection = crate::native_lifecycle::Inspection {
            state: "stopped", source: "service", can_start: true, reason: "idle-service",
            core_pid: None, service_generation: None, service_started_at: None,
            service_protocol: Some("2.6".into()), service_control_available: true, processes: vec![],
        };
        assert!(validate_managed_install_identity(&request, &inspection, RunningMode::NotRunning, false).is_ok());
        for mode in [RunningMode::Service, RunningMode::Sidecar] {
            assert!(validate_managed_install_identity(&request, &inspection, mode, false).is_err());
        }
        assert!(validate_managed_install_identity(&request, &inspection, RunningMode::NotRunning, true).is_err());
        let stale_request = InstallServiceParams { confirmed: true, expected: Some(CoreIdentity { generation: 1, pid: 2, started_at: 3 }) };
        assert!(validate_managed_install_identity(&stale_request, &inspection, RunningMode::NotRunning, false).is_err());
        inspection.processes.push(crate::native_lifecycle::CoreProcess { pid: 7, uid: 99, executable: "/tmp/mihomo".into(), started_at: "fixture".into() });
        assert!(validate_managed_install_identity(&request, &inspection, RunningMode::NotRunning, false).is_err());
        inspection.processes.clear();
        inspection.source = "process";
        assert!(validate_managed_install_identity(&request, &inspection, RunningMode::NotRunning, false).is_err());
        inspection.source = "service";
        inspection.can_start = false;
        assert!(validate_managed_install_identity(&request, &inspection, RunningMode::NotRunning, false).is_err());
    }

    #[tokio::test]
    async fn ownership_writes_reject_invalid_or_unconfirmed_requests_before_backend_access() {
        for value in [
            json!({}),
            json!({"confirmed":true,"unexpected":true}),
            json!({"confirmed":false,"expected":{"generation":1,"pid":1,"started_at":1}}),
        ] {
            assert!(claim(value.clone()).await.is_err());
            assert!(install_service(value.clone()).await.is_err());
            assert!(install_managed_service(value.clone()).await.is_err());
            assert!(upgrade(value).await.is_err());
        }
        assert!(control_state(json!({"unexpected":true})).await.is_err());
    }

    #[test]
    fn native_service_install_requires_the_confirmed_core_identity() {
        let mut inspection = crate::native_lifecycle::Inspection {
            state: "runningReadOnly", source: "service", can_start: false, reason: "service-upgrade-required",
            core_pid: Some(123), service_generation: Some(42), service_started_at: Some(7),
            service_protocol: Some("2.5".into()), service_control_available: false, processes: vec![],
        };
        let expected = CoreIdentity { generation: 42, pid: 123, started_at: 7 };
        assert!(validate_install_identity(Some(&expected), &inspection).is_ok());
        assert!(validate_install_identity(None, &inspection).is_err());
        inspection.service_generation = Some(43);
        assert!(validate_install_identity(Some(&expected), &inspection).is_err());
        inspection.service_control_available = true;
        assert!(!service_install_target_available(&inspection));
        inspection.service_control_available = false;
        inspection.state = "conflict";
        assert!(!service_install_target_available(&inspection));
    }
}
