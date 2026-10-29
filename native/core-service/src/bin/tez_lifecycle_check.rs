//! Isolated acceptance only: no installer, elevation, proxy ports, DNS or TUN.
use anyhow::{Context as _, Result, ensure};
use clash_verge_service_ipc::*;
use std::{
    path::{Path, PathBuf},
    time::Duration,
};

const FIXTURE: &str = "mode: rule\nport: 0\nsocks-port: 0\nredir-port: 0\ntproxy-port: 0\nmixed-port: 0\nallow-lan: false\nipv6: false\nlog-level: info\nexternal-controller: ''\ngeo-auto-update: false\nprofile:\n  store-selected: false\n  store-fake-ip: false\ndns:\n  enable: false\ntun:\n  enable: false\nproxies: []\nproxy-groups:\n  - name: Fixture\n    type: select\n    proxies: [DIRECT, REJECT]\nrules: ['MATCH,Fixture']\n";

fn version(path: &Path) -> Result<String> {
    let output = std::process::Command::new(path).arg("-v").output()?;
    ensure!(output.status.success(), "Core version check failed");
    let output = String::from_utf8(output.stdout)?;
    parse_mihomo_version(&output)
        .map(str::to_owned)
        .context("Missing version")
}

fn proof(generation: u64, token: &str) -> OwnerSessionProof {
    OwnerSessionProof {
        generation,
        token: token.into(),
    }
}

async fn checks(credentials: &OwnerCredentials, stable: &Path, candidate: &Path) -> Result<()> {
    let start = StartClashRequest {
        runtime: RuntimeBundle {
            yaml: FIXTURE.into(),
            assets: vec![],
            remote_providers: vec![],
            core_path: stable.to_string_lossy().into_owned(),
        },
        proposed_session_token: "a".repeat(64),
        macos_proxy: None,
    };
    let (first_start, second_start) = tokio::join!(
        start_idle_core(credentials, &start),
        start_idle_core(credentials, &start)
    );
    let (first_start, second_start) = (first_start?, second_start?);
    ensure!(
        (first_start.code == 0) != (second_start.code == 0),
        "Concurrent idle starts did not have one winner"
    );
    let response = if first_start.code == 0 {
        first_start
    } else {
        second_start
    };
    ensure!(response.code == 0, "Fixture start failed: {}", response.message);
    let first = proof(
        response.data.context("Missing session")?.session.generation,
        &"a".repeat(64),
    );
    let recovered = recover_core_session(credentials, &first)
        .await?
        .data
        .context("Recovery failed")?;
    ensure!(
        start_idle_core(credentials, &start).await?.code == ServiceErrorCode::CoreIdentityChanged as u16,
        "Idle start displaced an existing core"
    );
    ensure!(
        get_status(credentials).await?.data.context("Missing status")?.core_pid == Some(recovered.identity.pid),
        "Rejected idle start restarted the core"
    );
    ensure!(
        recovered.runtime_yaml == FIXTURE,
        "Recovery did not read the running runtime"
    );
    ensure!(
        load_owner_session(credentials, first.generation)?.is_none(),
        "Missing receipt unexpectedly loaded"
    );
    ensure!(
        !Path::new(&credentials.app_data_dir).join("native-session").exists(),
        "Receipt read created a directory"
    );
    ensure!(
        recover_core_session(credentials, &proof(first.generation, &"b".repeat(64)))
            .await?
            .code
            == ServiceErrorCode::StaleOwnerSession as u16,
        "Wrong token accepted"
    );
    let mut other_root = credentials.clone();
    let other = PathBuf::from(&credentials.app_data_dir).join("other");
    std::fs::create_dir(&other)?;
    other_root.app_data_dir = other.to_string_lossy().into_owned();
    ensure!(
        recover_core_session(&other_root, &first).await?.code != 0,
        "Different data root accepted"
    );
    let mut stale = recovered.identity.clone();
    stale.generation += 1;
    ensure!(
        claim_core(
            credentials,
            &ClaimCoreRequest {
                expected: stale,
                proposed_session_token: "b".repeat(64)
            }
        )
        .await?
        .code
            == ServiceErrorCode::CoreIdentityChanged as u16,
        "Stale claim accepted"
    );
    save_owner_session(credentials, &"b".repeat(64), None)?;
    let mut claimed = claim_core(
        credentials,
        &ClaimCoreRequest {
            expected: recovered.identity.clone(),
            proposed_session_token: "b".repeat(64),
        },
    )
    .await?
    .data
    .context("Claim failed")?;
    ensure!(
        claimed.identity.pid == recovered.identity.pid && claimed.identity.started_at == recovered.identity.started_at,
        "Claim restarted the core"
    );
    ensure!(
        claimed.identity.generation > recovered.identity.generation,
        "Claim did not rotate generation"
    );
    ensure!(
        recover_core_session(credentials, &first).await?.code != 0,
        "Displaced proof still works"
    );
    let session = proof(claimed.identity.generation, &"b".repeat(64));
    let child = tokio::process::Command::new(std::env::current_exe()?)
        .arg("--recover-fixture")
        .arg(&credentials.app_data_dir)
        .arg(session.generation.to_string())
        .arg(claimed.identity.pid.to_string())
        .kill_on_drop(true)
        .output();
    let child = tokio::time::timeout(Duration::from_secs(10), child).await??;
    ensure!(
        child.status.success(),
        "Separate client could not recover the pending receipt"
    );
    save_owner_session(credentials, &session.token, Some(session.generation))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        let receipt = Path::new(&credentials.app_data_dir).join("native-session/owner.json");
        std::fs::set_permissions(&receipt, std::fs::Permissions::from_mode(0o644))?;
        ensure!(
            load_owner_session(credentials, session.generation).is_err(),
            "Public receipt accepted"
        );
        std::fs::set_permissions(&receipt, std::fs::Permissions::from_mode(0o600))?;
        let hardlink = receipt.with_extension("linked");
        std::fs::hard_link(&receipt, &hardlink)?;
        ensure!(
            load_owner_session(credentials, session.generation).is_err(),
            "Hard-linked receipt accepted"
        );
        std::fs::remove_file(hardlink)?;
        let original = receipt.with_extension("original");
        std::fs::rename(&receipt, &original)?;
        std::os::unix::fs::symlink(&original, &receipt)?;
        ensure!(
            load_owner_session(credentials, session.generation).is_err(),
            "Symlinked receipt accepted"
        );
        std::fs::remove_file(&receipt)?;
        std::fs::rename(original, &receipt)?;
    }
    ensure!(
        load_owner_session(credentials, session.generation + 1)?.is_none(),
        "Stale confirmed generation accepted"
    );
    #[cfg(target_os = "macos")]
    {
        let prepared = prepare_owner_core(credentials, candidate, &version(candidate)?).await?;
        ensure!(
            prepared.sha256 == management::sha256_file(candidate)?
                && Path::new(&prepared.path).parent()
                    == Some(Path::new(&credentials.app_data_dir).join("native-upgrades").as_path()),
            "Private staging changed the package"
        );
        ensure!(
            get_status(credentials).await?.data.context("Missing status")?.core_pid == Some(claimed.identity.pid),
            "Package staging changed the core"
        );
        std::fs::write(&prepared.path, b"interrupted cache write")?;
        let repaired = prepare_owner_core(credentials, candidate, &version(candidate)?).await?;
        ensure!(
            repaired.sha256 == prepared.sha256,
            "Interrupted staging was not recoverable"
        );
    }
    let before_restart = claimed.identity.clone();
    #[cfg(unix)]
    ensure!(
        unsafe { platform_lib::kill(before_restart.pid as i32, platform_lib::SIGTERM) } == 0,
        "Could not signal the owned test core"
    );
    for _ in 0..200 {
        let response = recover_core_session(credentials, &session).await?;
        if let Some(next) = response.data
            && next.identity.pid != before_restart.pid
        {
            claimed = next;
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    ensure!(
        claimed.identity.pid != before_restart.pid,
        "Fixture watchdog did not restart its own core"
    );
    ensure!(
        claim_core(
            credentials,
            &ClaimCoreRequest {
                expected: before_restart,
                proposed_session_token: "c".repeat(64)
            }
        )
        .await?
        .code
            == ServiceErrorCode::CoreIdentityChanged as u16,
        "Stale PID claim accepted after watchdog recovery"
    );
    let request = UpgradeCoreRequest {
        expected: claimed.identity.clone(),
        approved_core_path: candidate.to_string_lossy().into_owned(),
        sha256: management::sha256_file(candidate)?,
        version: version(candidate)?,
    };
    let mut tampered = request.clone();
    tampered.sha256 = "0".repeat(64);
    ensure!(
        upgrade_owned_core(credentials, &session, &tampered).await?.code != 0,
        "Tampered candidate accepted"
    );
    ensure!(
        get_status(credentials).await?.data.context("Missing status")?.core_pid == Some(claimed.identity.pid),
        "Rejected preflight stopped the core"
    );
    let mut raced = request.clone();
    raced.expected = recovered.identity;
    ensure!(
        upgrade_owned_core(credentials, &session, &raced).await?.code != 0,
        "Stale upgrade identity accepted"
    );
    let (first_upgrade, second_upgrade) = tokio::join!(
        upgrade_owned_core(credentials, &session, &request),
        upgrade_owned_core(credentials, &session, &request)
    );
    let (first_upgrade, second_upgrade) = (first_upgrade?, second_upgrade?);
    ensure!(
        (first_upgrade.code == 0) != (second_upgrade.code == 0),
        "Concurrent upgrades did not have one winner"
    );
    let (upgraded, rejected_upgrade) = if first_upgrade.code == 0 {
        (first_upgrade, second_upgrade)
    } else {
        (second_upgrade, first_upgrade)
    };
    ensure!(
        rejected_upgrade.code == ServiceErrorCode::CoreIdentityChanged as u16,
        "Concurrent stale upgrade was not rejected"
    );
    ensure!(upgraded.code == 0, "Upgrade failed: {}", upgraded.message);
    let upgraded = upgraded.data.context("Missing upgrade outcome")?;
    ensure!(
        upgraded.outcome == "upgraded" && upgraded.session.identity.pid != claimed.identity.pid,
        "Upgrade not running: {:?}",
        upgraded.failure
    );
    ensure!(
        Path::new(&upgraded.previous_core_path).is_file(),
        "Previous version not retained"
    );
    save_owner_core(credentials, &upgraded.session.core_path, &upgraded.session.core_sha256)?;
    ensure!(
        load_owner_core(credentials)?.as_deref() == Some(Path::new(&upgraded.session.core_path)),
        "Selected version not retained"
    );
    let broken = service_paths()?.core_dir().canonicalize()?.join("fixture-broken");
    std::fs::write(
        &broken,
        "#!/bin/sh\nif [ \"$1\" = \"-v\" ]; then echo 'Mihomo fixture-broken'; exit 0; fi\nexit 42\n",
    )?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        std::fs::set_permissions(&broken, std::fs::Permissions::from_mode(0o700))?;
    }
    let rollback = upgrade_owned_core(
        credentials,
        &session,
        &UpgradeCoreRequest {
            expected: upgraded.session.identity.clone(),
            approved_core_path: broken.to_string_lossy().into_owned(),
            sha256: management::sha256_file(&broken)?,
            version: "fixture-broken".into(),
        },
    )
    .await?;
    ensure!(rollback.code == 0, "Rollback failed: {}", rollback.message);
    let rollback = rollback.data.context("Missing rollback outcome")?;
    ensure!(
        rollback.outcome == "rolled_back" && rollback.session.core_sha256 == request.sha256,
        "Wrong rollback version"
    );
    ensure!(
        rollback.session.identity.pid != upgraded.session.identity.pid,
        "Rollback PID unchanged"
    );
    ensure!(
        stop_clash(credentials, &first).await?.code != 0,
        "Old owner stopped claimed core"
    );
    ensure!(
        get_status(credentials).await?.data.context("Missing status")?.core_pid == Some(rollback.session.identity.pid),
        "Old owner's stop affected the core"
    );
    save_owner_session(credentials, &"c".repeat(64), None)?;
    let claim = ClaimCoreRequest {
        expected: rollback.session.identity.clone(),
        proposed_session_token: "c".repeat(64),
    };
    let (first_claim, second_claim) = tokio::join!(claim_core(credentials, &claim), claim_core(credentials, &claim));
    let (first_claim, second_claim) = (first_claim?, second_claim?);
    ensure!(
        (first_claim.code == 0) != (second_claim.code == 0),
        "Concurrent claims did not have one winner"
    );
    let winner = if first_claim.code == 0 {
        first_claim.data
    } else {
        second_claim.data
    }
    .context("Missing claimed identity")?;
    ensure!(
        winner.identity.pid == rollback.session.identity.pid,
        "Concurrent claim restarted the core"
    );
    ensure!(
        stop_clash(credentials, &session).await?.code != 0,
        "Displaced claimant still controlled the core"
    );
    ensure!(
        stop_clash(credentials, &proof(winner.identity.generation, &"c".repeat(64)))
            .await?
            .code
            == 0,
        "Fixture stop failed"
    );
    forget_owner_session(credentials)?;
    ensure!(
        load_owner_session(credentials, session.generation)?.is_none(),
        "Stopped receipt retained"
    );
    ensure!(
        load_owner_core(credentials)?.is_some(),
        "Stopping lost the selected version"
    );
    println!(
        "PASS: separate-client recovery of pending receipt; private permissions/link/generation checks; root/token rejection; compare-and-claim without restart; displaced proof rejection; watchdog identity race rejection; private signed Mach-O staging without restart; stale identity/hash rejection without stopping; concurrent claim/upgrade serialization; real stable-to-alpha upgrade; failed candidate rollback; selected version persistence; owned stop. No latency tests or external subscriptions."
    );
    Ok(())
}

#[cfg(unix)]
#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.len() == 4 && args[0] == "--recover-fixture" {
        let credentials = test_owner_credentials(&Path::new(&args[1]).canonicalize()?)?;
        let generation = args[2].to_str().context("Invalid generation")?.parse()?;
        let expected_pid = args[3].to_str().context("Invalid PID")?.parse::<u32>()?;
        let proof = load_owner_session(&credentials, generation)?.context("Receipt unavailable")?;
        let recovered = recover_core_session(&credentials, &proof)
            .await?
            .data
            .context("Session rejected")?;
        ensure!(
            recovered.identity.pid == expected_pid,
            "Recovery changed the running core"
        );
        return Ok(());
    }
    ensure!(
        args.len() == 3 && args[0] == "--isolated",
        "Usage: tez-lifecycle-check --isolated ABSOLUTE_STABLE_CORE ABSOLUTE_CANDIDATE_CORE"
    );
    let paths = service_paths()?;
    let root = isolated_test_root().context("TEZ_SERVICE_TEST_ROOT must select a new private acceptance directory")?;
    ensure!(
        paths.ipc_path() == root.join("ipc/service.sock") && paths.persistent_state_dir() == root.join("state"),
        "Refusing non-isolated service paths"
    );
    {
        use std::os::unix::fs::DirBuilderExt as _;
        std::fs::DirBuilder::new().mode(0o700).create(&root)?;
    }
    ensure!(
        !paths.runtime_dir().exists() && !paths.persistent_state_dir().exists(),
        "Test state already exists; refusing to alter it"
    );
    let directory = root.join("data");
    std::fs::create_dir(&directory)?;
    let credentials = test_owner_credentials(&directory.canonicalize()?)?;
    let cores = prepare_core_install_directory()?.canonicalize()?;
    let stable = cores.join("fixture-stable");
    let candidate = cores.join("fixture-candidate");
    std::fs::copy(Path::new(&args[1]).canonicalize()?, &stable)?;
    std::fs::copy(Path::new(&args[2]).canonicalize()?, &candidate)?;
    set_config(Some(IpcConfig {
        default_timeout: Duration::from_secs(5),
        max_retries: 1,
        retry_delay: Duration::from_millis(10),
    }))
    .await;
    let handle = run_ipc_server().await?;
    for _ in 0..100 {
        if paths.ipc_path().exists() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let result = checks(&credentials, &stable, &candidate).await;
    let stopped = stop_ipc_server().await;
    let _ = handle.await;
    if stopped.is_ok() {
        std::fs::remove_dir_all(paths.persistent_state_dir())?;
        std::fs::remove_dir_all(paths.runtime_dir())?;
        std::fs::remove_dir_all(&directory)?;
        std::fs::remove_dir_all(root)?;
    }
    result?;
    stopped?;
    Ok(())
}

#[cfg(not(unix))]
fn main() { eprintln!("Tez lifecycle acceptance requires a Unix fixture environment"); }
