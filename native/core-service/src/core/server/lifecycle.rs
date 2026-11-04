use super::*;
use crate::core::trusted_core_location::require_trusted_core_location;
use crate::{
    ClaimCoreRequest, CoreIdentity, CoreSessionSnapshot, CoreUpgradeOutcome, ServiceErrorCode, UpgradeCoreRequest,
};
use sha2::{Digest as _, Sha256};
use std::path::{Path, PathBuf};

fn rejected(message: impl Into<String>) -> ServiceError {
    ServiceError::new(ServiceErrorCode::CoreUpgradeRejected, message)
}

fn changed() -> ServiceError {
    ServiceError::new(
        ServiceErrorCode::CoreIdentityChanged,
        "Core identity or data root changed; inspect again",
    )
}

async fn identity(owner: &AuthenticatedOwner) -> std::result::Result<CoreIdentity, ServiceError> {
    let active = load_active_owner().await.map_err(|_| changed())?.ok_or_else(changed)?;
    if active.owner_key != owner.key || Path::new(&active.app_data_root) != owner.app_data_root {
        return Err(changed());
    }
    let status = service_status_snapshot(owner).await.map_err(|_| changed())?;
    Ok(CoreIdentity {
        generation: active.generation,
        pid: status.core_pid.ok_or_else(changed)?,
        started_at: status.core_started_at.ok_or_else(changed)?,
    })
}

async fn require_identity(
    owner: &AuthenticatedOwner,
    expected: &CoreIdentity,
) -> std::result::Result<(), ServiceError> {
    if identity(owner).await? != *expected {
        return Err(changed());
    }
    Ok(())
}

async fn snapshot(owner: &AuthenticatedOwner) -> std::result::Result<CoreSessionSnapshot, ServiceError> {
    use tokio::io::AsyncReadExt as _;
    let current = identity(owner).await?;
    let (_, config) = CORE_MANAGER
        .lock()
        .await
        .running_core_config()
        .await
        .ok_or_else(changed)?;
    let path = Path::new(&config.core_config.config_path);
    let root = service_paths()
        .map_err(|_| changed())?
        .for_owner(&owner.identity)
        .runtime_dir()
        .canonicalize()
        .map_err(|_| changed())?;
    let canonical = tokio::fs::canonicalize(path).await.map_err(|_| changed())?;
    if canonical.parent() != Some(root.as_path())
        || tokio::fs::symlink_metadata(path)
            .await
            .map_err(|_| changed())?
            .file_type()
            .is_symlink()
    {
        return Err(changed());
    }
    let mut yaml = String::new();
    tokio::fs::File::open(&canonical)
        .await
        .map_err(|_| changed())?
        .take(4 * 1024 * 1024 + 1)
        .read_to_string(&mut yaml)
        .await
        .map_err(|_| changed())?;
    if yaml.len() > 4 * 1024 * 1024 {
        return Err(rejected("Runtime exceeds recovery limit"));
    }
    let core_sha256 =
        crate::management::sha256_file(Path::new(&config.core_config.core_path)).map_err(|_| changed())?;
    Ok(CoreSessionSnapshot {
        identity: current,
        core_path: config.core_config.core_path,
        core_sha256,
        runtime_yaml: yaml,
        session_protection: CORE_MANAGER.lock().await.session_protection_enabled().await,
        core_ipc_path: Some(config.core_config.core_ipc_path),
    })
}

// Content-addressed copies preserve both versions without editing a signed application bundle.
fn preserve_version(source: &Path, digest: &str) -> std::result::Result<PathBuf, ServiceError> {
    use std::io::Write as _;
    let directory = service_paths()
        .map_err(|_| rejected("Core storage unavailable"))?
        .core_dir();
    crate::core::platform_security::ensure_private_service_directory(&directory)
        .map_err(|_| rejected("Core storage is not protected"))?;
    let directory = directory
        .canonicalize()
        .map_err(|_| rejected("Core storage unavailable"))?;
    let target = directory.join(format!("tez-{digest}"));
    if target.exists() {
        if std::fs::symlink_metadata(&target)
            .map_err(|_| rejected("Version metadata unavailable"))?
            .file_type()
            .is_symlink()
            || crate::management::sha256_file(&target).map_err(|_| rejected("Version unreadable"))? != digest
        {
            return Err(rejected("Stored version digest mismatch"));
        }
        require_trusted_core_location(&target)?;
        return Ok(target);
    }
    let bytes = std::fs::read(source).map_err(|_| rejected("Approved core unreadable"))?;
    let actual: String = Sha256::digest(&bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    if bytes.len() > 64 * 1024 * 1024 || actual != digest {
        return Err(rejected("Core digest mismatch"));
    }
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.mode(0o700).custom_flags(platform_lib::O_NOFOLLOW);
    }
    let staging = target.with_extension("next");
    let result = (|| -> std::io::Result<()> {
        let mut file = options.open(&staging)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        std::fs::rename(&staging, &target)?;
        std::fs::File::open(&directory)?.sync_all()
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(staging);
        return Err(rejected("Could not preserve core version"));
    }
    require_trusted_core_location(&target)?;
    Ok(target)
}

async fn verify_candidate(request: &UpgradeCoreRequest) -> std::result::Result<PathBuf, ServiceError> {
    use std::process::Stdio;
    use tokio::io::AsyncReadExt as _;
    if request.sha256.len() != 64
        || !request
            .sha256
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        || request.version.is_empty()
        || request.version.len() > 64
        || !request
            .version
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b".-_".contains(&byte))
    {
        return Err(rejected("Invalid digest or version"));
    }
    let path = Path::new(&request.approved_core_path);
    let directory = service_paths()
        .map_err(|_| rejected("Core storage unavailable"))?
        .core_dir()
        .canonicalize()
        .map_err(|_| rejected("Core storage unavailable"))?;
    if !path.is_absolute()
        || path.parent() != Some(directory.as_path())
        || path.canonicalize().ok().as_deref() != Some(path)
    {
        return Err(rejected(
            "Only separately administrator-approved core files are accepted",
        ));
    }
    let approved = crate::core::runtime_generation::approved_core_copy(&directory, path)?;
    require_trusted_core_location(&approved)?;
    let pinned = preserve_version(&approved, &request.sha256)?;
    let mut command = tokio::process::Command::new(&pinned);
    command
        .arg("-v")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let mut child = command.spawn().map_err(|_| rejected("Version check failed"))?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| rejected("Version output unavailable"))?;
    let mut bytes = Vec::new();
    let result = tokio::time::timeout(Duration::from_secs(5), async {
        stdout
            .take(65537)
            .read_to_end(&mut bytes)
            .await
            .map_err(|_| rejected("Version read failed"))?;
        if bytes.len() > 65536 {
            return Err(rejected("Version output exceeds limit"));
        }
        child.wait().await.map_err(|_| rejected("Version check failed"))
    })
    .await;
    let status = match result {
        Ok(Ok(status)) => status,
        _ => {
            let _ = child.start_kill();
            let _ = child.wait().await;
            return Err(rejected("Version check failed or exceeded limits"));
        }
    };
    let output_text = std::str::from_utf8(&bytes).map_err(|_| rejected("Invalid core version output"))?;
    if !status.success() || crate::parse_mihomo_version(output_text) != Some(request.version.as_str()) {
        return Err(rejected("Approved core does not match the requested version"));
    }
    Ok(pinned)
}

async fn upgrade(
    owner: &AuthenticatedOwner,
    request: &UpgradeCoreRequest,
) -> std::result::Result<CoreUpgradeOutcome, ServiceError> {
    if CORE_MANAGER.lock().await.session_protection_enabled().await {
        return Err(rejected("Disable session protection before upgrading the core"));
    }
    require_identity(owner, &request.expected).await?;
    let candidate = verify_candidate(request).await?;
    let identity_gate = CORE_MANAGER.lock().await.identity_gate();
    let _identity = identity_gate.lock().await;
    let (_, old) = CORE_MANAGER
        .lock()
        .await
        .running_core_config()
        .await
        .ok_or_else(changed)?;
    let old_digest = crate::management::sha256_file(Path::new(&old.core_config.core_path))
        .map_err(|_| rejected("Previous core unreadable"))?;
    let previous = preserve_version(Path::new(&old.core_config.core_path), &old_digest)?;
    // The watchdog can change the PID while a candidate is validated.
    require_identity(owner, &request.expected).await?;
    let mut next = old.clone();
    next.core_config.core_path = candidate.to_string_lossy().into_owned();
    let mut rollback = old;
    rollback.core_config.core_path = previous.to_string_lossy().into_owned();
    CORE_MANAGER
        .lock()
        .await
        .stop_core()
        .await
        .map_err(|_| rejected("Previous core did not stop; upgrade not started"))?;
    let started = CORE_MANAGER
        .lock()
        .await
        .start_core(next.clone(), owner.identity.clone())
        .await;
    let committed = if started.is_ok() {
        match controller_version(&next).await {
            Ok(version) if version == request.version => persist_owner_core_started(owner, &next).await.map(|_| ()),
            _ => Err(anyhow!("Candidate controller did not report the requested version")),
        }
    } else {
        started
    };
    let failure = committed
        .as_ref()
        .err()
        .map(|_| "Candidate startup or readiness failed; previous core restored".to_owned());
    let outcome = if committed.is_ok() {
        "upgraded"
    } else {
        CORE_MANAGER.lock().await.stop_core().await.map_err(|_| {
            ServiceError::new(
                ServiceErrorCode::CoreRollbackFailed,
                "Could not stop rejected candidate; old version retained",
            )
        })?;
        CORE_MANAGER
            .lock()
            .await
            .start_core(rollback.clone(), owner.identity.clone())
            .await
            .map_err(|_| {
                ServiceError::new(
                    ServiceErrorCode::CoreRollbackFailed,
                    "Previous core did not restart; both versions retained",
                )
            })?;
        persist_owner_core_started(owner, &rollback).await.map_err(|_| {
            ServiceError::new(
                ServiceErrorCode::CoreRollbackFailed,
                "Rollback is running but persistence failed",
            )
        })?;
        "rolled_back"
    };
    Ok(CoreUpgradeOutcome {
        outcome: outcome.into(),
        session: snapshot(owner).await?,
        previous_core_path: previous.to_string_lossy().into_owned(),
        failure,
    })
}

async fn controller_version(config: &crate::ClashConfig) -> AnyResult<String> {
    let client = kode_bridge::IpcHttpClient::with_config(
        Path::new(&config.core_config.core_ipc_path),
        kode_bridge::ClientConfig {
            default_timeout: Duration::from_secs(2),
            max_retries: 1,
            enable_pooling: false,
            ..Default::default()
        },
    )?;
    let value = client.get("/version").send().await?.json::<serde_json::Value>()?;
    value["version"]
        .as_str()
        .map(str::to_owned)
        .context("Controller version missing")
}

pub(super) fn routes(router: Router) -> Router {
    #[cfg(target_os = "macos")]
    let router = router
        .get(IpcCommand::SessionProtection.as_ref(), |ctx| async move {
            let (request, owner) = match authenticate_request::<AuthenticatedSessionRequest<()>>(&ctx) {
                ControlFlow::Continue(value) => value,
                ControlFlow::Break(response) => return response,
            };
            let _guard = match enter_owner_lifecycle(&owner, OwnerLifecycleGate::ActiveSession(&request.session)).await
            {
                ControlFlow::Continue(guard) => guard,
                ControlFlow::Break(response) => return response,
            };
            match protection_state(&owner).await {
                Ok(value) => ok_json(value),
                Err(error) => service_error(error),
            }
        })
        .post(IpcCommand::SessionProtection.as_ref(), |ctx| async move {
            let (request, owner) =
                match authenticate_request::<AuthenticatedSessionRequest<crate::SetSessionProtectionRequest>>(&ctx) {
                    ControlFlow::Continue(value) => value,
                    ControlFlow::Break(response) => return response,
                };
            let _guard = match enter_owner_lifecycle(&owner, OwnerLifecycleGate::ActiveSession(&request.session)).await
            {
                ControlFlow::Continue(guard) => guard,
                ControlFlow::Break(response) => return response,
            };
            match switch_protection(&owner, &request.payload).await {
                Ok(value) => ok_json(value),
                Err(error) => service_error(error),
            }
        });
    router
        .post(IpcCommand::StartIdleCore.as_ref(), |ctx| async move {
            super::start_core_request(&ctx, true).await
        })
        .get(IpcCommand::CoreSession.as_ref(), |ctx| async move {
            let (request, owner) = match authenticate_request::<AuthenticatedSessionRequest<()>>(&ctx) {
                ControlFlow::Continue(value) => value,
                ControlFlow::Break(response) => return response,
            };
            let _guard = match enter_owner_lifecycle(&owner, OwnerLifecycleGate::ActiveSession(&request.session)).await
            {
                ControlFlow::Continue(guard) => guard,
                ControlFlow::Break(response) => return response,
            };
            match snapshot(&owner).await {
                Ok(value) => ok_json(value),
                Err(error) => service_error(error),
            }
        })
        .post(IpcCommand::ClaimCore.as_ref(), |ctx| async move {
            let (request, owner) = match authenticate_request::<AuthenticatedRequest<ClaimCoreRequest>>(&ctx) {
                ControlFlow::Continue(value) => value,
                ControlFlow::Break(response) => return response,
            };
            let _guard = match enter_owner_lifecycle(&owner, OwnerLifecycleGate::ActiveOwner).await {
                ControlFlow::Continue(guard) => guard,
                ControlFlow::Break(response) => return response,
            };
            let identity_gate = CORE_MANAGER.lock().await.identity_gate();
            let _identity = identity_gate.lock().await;
            if let Err(error) = require_identity(&owner, &request.payload.expected).await {
                return service_error(error);
            }
            if hash_session_token(&request.payload.proposed_session_token).is_err() {
                return bad_request("Invalid proposed session token");
            }
            // Read recovery data before committing so a refused snapshot cannot rotate ownership.
            let mut recovered = match snapshot(&owner).await {
                Ok(value) => value,
                Err(error) => return service_error(error),
            };
            if recovered.identity != request.payload.expected {
                return service_error(changed());
            }
            match commit_active_owner_session(&owner, &request.payload.proposed_session_token).await {
                Ok(active) => {
                    recovered.identity.generation = active.generation;
                    ok_json(recovered)
                }
                Err(_) => service_unavailable("Could not commit claimed session"),
            }
        })
        .post(IpcCommand::UpgradeCore.as_ref(), |ctx| async move {
            let (request, owner) = match authenticate_request::<AuthenticatedSessionRequest<UpgradeCoreRequest>>(&ctx) {
                ControlFlow::Continue(value) => value,
                ControlFlow::Break(response) => return response,
            };
            let _guard = match enter_owner_lifecycle(&owner, OwnerLifecycleGate::ActiveSession(&request.session)).await
            {
                ControlFlow::Continue(guard) => guard,
                ControlFlow::Break(response) => return response,
            };
            match upgrade(&owner, &request.payload).await {
                Ok(value) => ok_json(value),
                Err(error) => service_error(error),
            }
        })
}

#[cfg(target_os = "macos")]
async fn protection_state(
    owner: &AuthenticatedOwner,
) -> std::result::Result<crate::SessionProtectionState, ServiceError> {
    let current = identity(owner).await?;
    let manager = CORE_MANAGER.lock().await;
    let (_, config) = manager.running_core_config().await.ok_or_else(changed)?;
    Ok(crate::SessionProtectionState {
        identity: current,
        enabled: manager.session_protection_enabled().await,
        core_ipc_path: config.core_config.core_ipc_path,
    })
}

#[cfg(target_os = "macos")]
async fn switch_protection(
    owner: &AuthenticatedOwner,
    request: &crate::SetSessionProtectionRequest,
) -> std::result::Result<crate::SessionProtectionOutcome, ServiceError> {
    let gate = CORE_MANAGER.lock().await.identity_gate();
    let _identity = gate.lock().await;
    require_identity(owner, &request.expected).await?;
    let (_, old) = CORE_MANAGER
        .lock()
        .await
        .running_core_config()
        .await
        .ok_or_else(changed)?;
    let enabled = CORE_MANAGER.lock().await.session_protection_enabled().await;
    if enabled == request.enabled {
        return Ok(crate::SessionProtectionOutcome {
            outcome: "unchanged".into(),
            session: snapshot(owner).await?,
        });
    }
    let prepared = if request.enabled {
        Some(
            crate::core::session_protection::SessionCoreCopy::prepare(&old)
                .await
                .map_err(|_| rejected("Could not prepare session core"))?,
        )
    } else {
        None
    };
    let previous = CORE_MANAGER.lock().await.take_session_protection().await;
    let mut next = old.clone();
    if let Some(copy) = prepared.as_ref() {
        next.core_config.core_path = copy.executable().to_string_lossy().into_owned();
        next.core_config.core_ipc_path = copy.ipc_path();
    } else if let Some(copy) = previous.as_ref() {
        next.core_config.core_path = copy.original_core.clone();
        next.core_config.core_ipc_path = copy.original_ipc.clone();
    }
    let stopped = CORE_MANAGER.lock().await.stop_core().await;
    if stopped.is_err() {
        CORE_MANAGER.lock().await.set_session_protection(previous).await;
        return Err(rejected("Current core did not stop; mode unchanged"));
    }
    CORE_MANAGER.lock().await.set_session_protection(prepared).await;
    let started = CORE_MANAGER
        .lock()
        .await
        .start_core(next.clone(), owner.identity.clone())
        .await;
    let healthy = started.is_ok() && controller_version(&next).await.is_ok();
    let outcome = if healthy {
        "changed"
    } else {
        CORE_MANAGER
            .lock()
            .await
            .stop_core()
            .await
            .map_err(|_| rejected("Candidate stop unconfirmed; inspect current core"))?;
        CORE_MANAGER.lock().await.set_session_protection(previous).await;
        CORE_MANAGER
            .lock()
            .await
            .start_core(old, owner.identity.clone())
            .await
            .map_err(|_| rejected("Previous core restart unconfirmed; inspect current core"))?;
        "rolled_back"
    };
    Ok(crate::SessionProtectionOutcome {
        outcome: outcome.into(),
        session: snapshot(owner).await?,
    })
}
