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

#[cfg(target_os = "macos")]
async fn protection_checks(
    credentials: &OwnerCredentials,
    session: &OwnerSessionProof,
    runtime: &RuntimeBundle,
    current: &CoreSessionSnapshot,
) -> Result<CoreSessionSnapshot> {
    let original_hash = management::sha256_file(Path::new(&runtime.core_path))?;
    let initial = session_protection_state(credentials, session)
        .await?
        .data
        .context("Missing protection state")?;
    ensure!(
        !initial.enabled && !current.session_protection,
        "New session protection was not off"
    );
    let mut request = SetSessionProtectionRequest {
        expected: current.identity.clone(),
        enabled: true,
    };
    request.expected.pid += 1;
    ensure!(
        set_session_protection(credentials, session, &request).await?.code != 0,
        "Stale protection identity accepted"
    );
    request.expected = current.identity.clone();
    ensure!(
        set_session_protection(credentials, &proof(session.generation, &"f".repeat(64)), &request)
            .await?
            .code
            != 0,
        "Wrong proof changed protection"
    );
    ensure!(
        get_status(credentials).await?.data.context("Missing status")?.core_pid == Some(current.identity.pid),
        "Rejected protection request stopped the core"
    );
    let enabled = set_session_protection(credentials, session, &request).await?;
    ensure!(enabled.code == 0, "Enable failed: {}", enabled.message);
    let enabled = enabled.data.context("Missing enable outcome")?;
    ensure!(
        enabled.outcome == "changed"
            && enabled.session.session_protection
            && enabled.session.identity.pid != current.identity.pid,
        "Protection did not restart the owned core"
    );
    let protected_path = PathBuf::from(&enabled.session.core_path);
    ensure!(
        is_session_core_path(&protected_path) && protected_path.is_file(),
        "Protected copy missing"
    );
    let process = std::process::Command::new("/bin/ps")
        .args([
            "-p",
            &enabled.session.identity.pid.to_string(),
            "-o",
            "comm=",
            "-o",
            "args=",
        ])
        .output()?;
    let process = String::from_utf8(process.stdout)?.to_lowercase();
    ensure!(
        process.contains("tezcore") && !process.contains("mihomo") && !process.contains("clash"),
        "Keywords remain in process metadata: {process}"
    );
    let signed = std::process::Command::new("/usr/bin/codesign")
        .args(["-d", "--verbose=2"])
        .arg(&protected_path)
        .output()?;
    ensure!(
        signed.status.success() && String::from_utf8_lossy(&signed.stderr).contains("Identifier=app.tez.session.core"),
        "Copy signature identity incorrect"
    );
    ensure!(
        enabled.session.runtime_yaml == current.runtime_yaml
            && management::sha256_file(Path::new(&runtime.core_path))? == original_hash,
        "Protection changed the original core or configuration"
    );
    let state = session_protection_state(credentials, session)
        .await?
        .data
        .context("Missing enabled state")?;
    ensure!(
        state.enabled && state.core_ipc_path.ends_with("/control.sock"),
        "Protected socket not reported"
    );
    let observer = tokio::process::Command::new(std::env::current_exe()?)
        .arg("--observe-fixture")
        .arg(&credentials.app_data_dir)
        .arg(enabled.session.identity.pid.to_string())
        .kill_on_drop(true)
        .output();
    let observer = tokio::time::timeout(Duration::from_secs(10), observer).await??;
    ensure!(
        observer.status.success(),
        "Separate read-only client lost protected controller: {}",
        String::from_utf8_lossy(&observer.stderr)
    );
    ensure!(
        load_owner_core(credentials)?.is_none(),
        "Protection persisted a core preference"
    );
    request.expected = enabled.session.identity.clone();
    let unchanged = set_session_protection(credentials, session, &request)
        .await?
        .data
        .context("Missing unchanged outcome")?;
    ensure!(
        unchanged.outcome == "unchanged" && unchanged.session.identity == enabled.session.identity,
        "Idempotent enable restarted the core"
    );
    let staged = stage_runtime(credentials, session, runtime).await?;
    ensure!(
        staged.code == 0 && matches!(staged.data, Some(StageRuntimeOutcome::Staged { .. })),
        "Protected runtime staging requested restart: {}",
        staged.message
    );
    let recovered = recover_core_session(credentials, session)
        .await?
        .data
        .context("Protected recovery failed")?;
    ensure!(
        recovered.session_protection
            && recovered.identity == enabled.session.identity
            && recovered.core_ipc_path == Some(state.core_ipc_path),
        "Recovery/staging lost protection or changed the process"
    );
    ensure!(
        unsafe { platform_lib::kill(recovered.identity.pid as i32, platform_lib::SIGTERM) } == 0,
        "Could not signal protected fixture core"
    );
    let mut recovered = recovered;
    for _ in 0..200 {
        if let Some(next) = recover_core_session(credentials, session).await?.data
            && next.identity.pid != recovered.identity.pid
        {
            recovered = next;
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    ensure!(
        recovered.session_protection
            && recovered.identity.pid != enabled.session.identity.pid
            && protected_path.is_file(),
        "Watchdog lost the protected session"
    );
    request.enabled = false;
    request.expected = recovered.identity;
    let original = Path::new(&runtime.core_path);
    let unavailable = original.with_extension("unavailable");
    std::fs::rename(original, &unavailable)?;
    let rollback = set_session_protection(credentials, session, &request).await;
    std::fs::rename(&unavailable, original)?;
    let rollback = rollback?;
    ensure!(rollback.code == 0, "Protection rollback failed: {}", rollback.message);
    let rollback = rollback.data.context("Missing protection rollback")?;
    ensure!(
        rollback.outcome == "rolled_back" && rollback.session.session_protection && protected_path.is_file(),
        "Failed disable did not retain the protected copy"
    );
    request.expected = rollback.session.identity;
    let disabled = set_session_protection(credentials, session, &request).await?;
    ensure!(disabled.code == 0, "Disable failed: {}", disabled.message);
    let disabled = disabled.data.context("Missing disable outcome")?;
    ensure!(
        disabled.outcome == "changed"
            && !disabled.session.session_protection
            && disabled.session.identity.pid != enabled.session.identity.pid
            && disabled.session.core_path == current.core_path,
        "Disable did not restore original core"
    );
    ensure!(
        !protected_path.exists() && management::sha256_file(Path::new(&runtime.core_path))? == original_hash,
        "Copy retained or original core changed"
    );
    println!(
        "PASS: session protection defaults off; stale identity/token rejected; signed temporary TezCore and keyword-free process arguments; original core/YAML unchanged; separate observer and session recovery; runtime staging without restart; watchdog retains protection; failed disable rolls back; no preference write; disable restores core and removes copy"
    );
    Ok(disabled.session)
}

#[cfg(target_os = "macos")]
async fn chrome_hello(session: &CoreSessionSnapshot, listener: &tokio::net::TcpListener, node: &str) -> Result<bool> {
    use tokio::io::AsyncReadExt as _;
    let socket = session.core_ipc_path.as_deref().context("Missing fixture controller")?;
    let client = kode_bridge::IpcHttpClient::new(Path::new(socket))?;
    let route = if node.ends_with("Provider") { format!("/providers/proxies/SubscriptionFixture/{node}/healthcheck") }
        else { format!("/proxies/{node}/delay") };
    let endpoint = format!("{route}?timeout=1500&url=http%3A%2F%2F127.0.0.1%3A9");
    let trigger = tokio::spawn(async move { client.get(&endpoint).send().await });
    let capture = async {
        let (mut stream, _) = listener.accept().await?;
        let mut header = [0; 5];
        stream.read_exact(&mut header).await?;
        ensure!(header[0] == 22, "Expected a TLS handshake record");
        let mut body = vec![0; u16::from_be_bytes([header[3], header[4]]) as usize];
        stream.read_exact(&mut body).await?;
        ensure!(body.len() > 40 && body[0] == 1, "Expected ClientHello");
        let start = 39 + body[38] as usize;
        let length = u16::from_be_bytes([body[start], body[start + 1]]) as usize;
        let ciphers = &body[start + 2..start + 2 + length];
        Ok::<_, anyhow::Error>(ciphers.chunks_exact(2).any(|cipher| cipher[0] == cipher[1] && cipher[0] & 0x0f == 0x0a))
    };
    let captured = tokio::time::timeout(Duration::from_secs(4), capture).await;
    let response = tokio::time::timeout(Duration::from_secs(3), &mut { trigger }).await;
    match captured {
        Ok(value) => value.with_context(|| format!("Invalid {node} handshake")),
        Err(error) => Err(anyhow::anyhow!("No {node} ClientHello: {error}; delay response: {response:?}")),
    }
}

#[cfg(target_os = "macos")]
async fn runtime_protection_checks(
    credentials: &OwnerCredentials,
    session: &OwnerSessionProof,
    runtime: &RuntimeBundle,
    current: &CoreSessionSnapshot,
) -> Result<CoreSessionSnapshot> {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let port = listener.local_addr()?.port();
    let mut compatible = runtime.clone();
    compatible.yaml = FIXTURE.replace("proxies: []", &format!("proxies:\n- {{name: TransportInline, type: trojan, server: 127.0.0.1, port: {port}, password: fixture, sni: fixture.test}}"))
        .replace("proxies: [DIRECT, REJECT]", "proxies: [DIRECT, REJECT]\n  - name: ProviderFixture\n    type: select\n    use: [SubscriptionFixture]");
    compatible.yaml.push_str(&format!("proxy-providers:\n  SubscriptionFixture:\n    type: inline\n    override: {{udp: true}}\n    payload:\n    - {{name: TransportProvider, type: trojan, server: 127.0.0.1, port: {port}, password: fixture, sni: fixture.test}}\n    - {{name: PresetProvider, type: trojan, server: 127.0.0.1, port: {port}, password: fixture, sni: fixture.test, client-fingerprint: none}}\n    - {{name: UnsupportedProvider, type: ss, server: 127.0.0.1, port: {port}, cipher: aes-128-gcm, password: fixture}}\n"));
    let subscription_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let url = format!("http://{}/subscription.yaml", subscription_listener.local_addr()?);
    let mut yaml: serde_yaml_ng::Value = serde_yaml_ng::from_str(&compatible.yaml)?;
    let provider = yaml["proxy-providers"]["SubscriptionFixture"].as_mapping_mut().unwrap();
    let payload = provider.remove("payload").context("Missing fixture payload")?;
    let body = serde_yaml_ng::to_string(&serde_yaml_ng::Mapping::from_iter([("proxies".into(), payload)]))?;
    provider.insert("type".into(), "http".into());
    provider.insert("url".into(), url.clone().into());
    provider.insert("path".into(), "subscription-fixture.yaml".into());
    provider.insert("interval".into(), 86400.into());
    compatible.yaml = serde_yaml_ng::to_string(&yaml)?;
    compatible.remote_providers.push(RemoteProvider { destination: "subscription-fixture.yaml".into(), url });
    let asset = Path::new(&credentials.app_data_dir).join("rollback-rules.yaml");
    std::fs::write(&asset, "payload: ['DOMAIN,fixture.test']\n")?;
    compatible.assets.push(RuntimeAsset { source: asset.to_string_lossy().into_owned(), destination: "rules/rollback.yaml".into() });
    compatible.assets.push(RuntimeAsset { source: asset.to_string_lossy().into_owned(), destination: "config.protection.next".into() });
    let subscription = tokio::spawn(async move {
        use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
        loop {
            let Ok((mut stream, _)) = subscription_listener.accept().await else { break };
            let mut request = [0; 4096];
            let _ = stream.read(&mut request).await;
            let response = format!("HTTP/1.1 200 OK\r\nContent-Type: text/yaml\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
            let _ = stream.write_all(response.as_bytes()).await;
        }
    });
    let mut request = RuntimeProtectionRequest {
        expected: current.identity.clone(), process_enabled: false, transport_enabled: true, restart: false, runtime: None,
    };
    ensure!(set_runtime_protection(credentials, session, &request).await?.code != 0, "Unsupported-only configuration was accepted");
    ensure!(get_status(credentials).await?.data.context("Missing status")?.core_pid == Some(current.identity.pid), "Unsupported preflight stopped the core");
    request.transport_enabled = false;
    request.restart = true;
    request.runtime = Some(compatible.clone());
    let mut active = set_runtime_protection(credentials, session, &request).await?.data.context("Could not load transport fixture")?.session;
    ensure!(!chrome_hello(&active, &listener, "TransportInline").await?, "Baseline unexpectedly uses a browser handshake");
    request.runtime = None;
    request.restart = false;
    request.transport_enabled = true;
    request.expected = active.identity.clone();
    request.expected.pid += 1;
    ensure!(set_runtime_protection(credentials, session, &request).await?.code != 0, "Combined change accepted a stale identity");
    request.expected = active.identity.clone();
    ensure!(set_runtime_protection(credentials, &proof(session.generation, &"f".repeat(64)), &request).await?.code != 0, "Combined change accepted a stale token");
    for (process, transport) in [(false, true), (true, true), (true, false), (false, false), (true, true), (false, true)] {
        request.expected = active.identity.clone();
        request.process_enabled = process;
        request.transport_enabled = transport;
        let changed = set_runtime_protection(credentials, session, &request).await?;
        ensure!(changed.code == 0, "Combined protection refused: {}", changed.message);
        let changed = changed.data.context("Missing combined outcome")?;
        ensure!(changed.outcome == "changed" && changed.session.identity.pid != active.identity.pid
            && changed.session.identity.generation == active.identity.generation, "Combined change did not retain one session");
        active = changed.session;
        let durable = service_paths()?.for_owner(&credentials.identity).runtime_dir().join("config.yaml");
        ensure!(std::fs::read_to_string(&durable)? == compatible.yaml, "Session transport overlay changed the durable baseline");
        ensure!(std::fs::read_to_string(durable.with_file_name("config.protection.next"))? == "payload: ['DOMAIN,fixture.test']\n", "Protection staging clobbered a provider resource");
        ensure!(active.session_protection == process && active.transport_protection == transport, "Protection modes interfered");
        ensure!(active.runtime_base_yaml.as_deref() == transport.then_some(compatible.yaml.as_str()), "Recovery baseline was contaminated");
        if !transport { ensure!(active.runtime_yaml == compatible.yaml, "Disabling transport did not restore the baseline"); }
        ensure!(chrome_hello(&active, &listener, "TransportInline").await? == transport, "Inline TLS handshake did not follow transport mode");
        ensure!(chrome_hello(&active, &listener, "TransportProvider").await? == transport, "Provider expression did not change the TLS handshake");
        ensure!(!chrome_hello(&active, &listener, "PresetProvider").await?, "Provider expression replaced an explicit fingerprint");
        request.expected = active.identity.clone();
        let unchanged = set_runtime_protection(credentials, session, &request).await?.data.context("Missing idempotent outcome")?;
        ensure!(unchanged.outcome == "unchanged" && unchanged.session.identity == active.identity, "Idempotent combined apply restarted the core");
    }
    request.expected = active.identity.clone();
    request.process_enabled = true;
    request.transport_enabled = true;
    active = set_runtime_protection(credentials, session, &request).await?.data.context("Missing dual protection")?.session;
    let client = kode_bridge::IpcHttpClient::new(Path::new(active.core_ipc_path.as_deref().context("Missing controller")?))?;
    ensure!(client.put("/providers/proxies/SubscriptionFixture").send().await?.is_success()
        && chrome_hello(&active, &listener, "TransportProvider").await?, "HTTP subscription refresh lost the transport overlay");
    let mut refreshed = compatible.clone();
    refreshed.yaml.push_str("# subscription refresh\n");
    let staged = stage_runtime(credentials, session, &refreshed).await?.data.context("Missing staged response")?;
    let StageRuntimeOutcome::Staged { config_path } = staged else { anyhow::bail!("Dual-protected staging failed") };
    let client = kode_bridge::IpcHttpClient::new(Path::new(active.core_ipc_path.as_deref().context("Missing controller")?))?;
    let loaded = client.put("/configs?force=true").json_body(&serde_json::json!({"path":config_path})).send().await?;
    ensure!(loaded.is_success() && chrome_hello(&active, &listener, "TransportProvider").await?, "Protected subscription reload failed");
    let recovered = recover_core_session(credentials, session).await?.data.context("Missing staged recovery")?;
    ensure!(recovered.identity == active.identity && recovered.transport_protection && recovered.session_protection
        && recovered.runtime_base_yaml.as_deref() == Some(refreshed.yaml.as_str()), "Staging lost session protection or baseline");
    request.expected = recovered.identity;
    request.restart = true;
    request.runtime = Some(refreshed.clone());
    active = set_runtime_protection(credentials, session, &request).await?.data.context("Missing protected restart")?.session;
    ensure!(active.transport_protection && active.session_protection && chrome_hello(&active, &listener, "TransportProvider").await?, "Manual/config restart lost protections");
    let before = active.identity.pid;
    ensure!(unsafe { platform_lib::kill(before as i32, platform_lib::SIGTERM) } == 0, "Could not signal dual-protected fixture");
    for _ in 0..200 {
        if let Some(next) = recover_core_session(credentials, session).await?.data && next.identity.pid != before { active = next; break; }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    ensure!(active.identity.pid != before && active.session_protection && active.transport_protection
        && active.runtime_base_yaml.as_deref() == Some(refreshed.yaml.as_str()), "Watchdog lost dual session state");
    request.expected = active.identity.clone();
    let mut broken = refreshed.clone();
    broken.yaml = "invalid: [".into();
    request.runtime = Some(broken);
    let refused = set_runtime_protection(credentials, session, &request).await?;
    ensure!(refused.code != 0 && get_status(credentials).await?.data.context("Missing status")?.core_pid == Some(active.identity.pid), "Invalid transport config stopped the core");
    request.transport_enabled = false;
    request.process_enabled = false;
    let generation = service_paths()?.for_owner(&credentials.identity).runtime_dir();
    let old_manifest = std::fs::read(generation.join(".runtime-manifest.json"))?;
    request.runtime = Some(RuntimeBundle { yaml: FIXTURE.replace("mode: rule", "mode: broken"), ..runtime.clone() });
    let rollback = set_runtime_protection(credentials, session, &request).await?.data.context("Missing combined rollback")?;
    ensure!(rollback.outcome == "rolled_back" && rollback.session.session_protection && rollback.session.transport_protection
        && rollback.session.runtime_base_yaml.as_deref() == Some(refreshed.yaml.as_str())
        && chrome_hello(&rollback.session, &listener, "TransportProvider").await?, "Failed candidate did not restore both modes");
    ensure!(std::fs::read_to_string(generation.join("rules/rollback.yaml"))? == "payload: ['DOMAIN,fixture.test']\n", "Rollback lost the previous runtime asset");
    ensure!(std::fs::read(generation.join(".runtime-manifest.json"))? == old_manifest, "Rollback did not restore the previous resource manifest");
    let mut no_tls = runtime.clone();
    no_tls.yaml = FIXTURE.replace("proxies: []", "proxies: [{name: Plain, type: ss, server: 127.0.0.1, port: 1, cipher: aes-128-gcm, password: fixture}]");
    ensure!(matches!(stage_runtime(credentials, session, &no_tls).await?.data, Some(StageRuntimeOutcome::Staged { .. })), "Could not stage a no-TLS subscription");
    request.expected = rollback.session.identity;
    request.process_enabled = true;
    request.transport_enabled = true;
    request.runtime = Some(no_tls);
    let no_tls = set_runtime_protection(credentials, session, &request).await?;
    ensure!(no_tls.code == 0, "Restart rejected a retained transport mode with no compatible nodes: {}", no_tls.message);
    let no_tls = no_tls.data.context("Missing no-TLS restart")?;
    ensure!(no_tls.session.session_protection && no_tls.session.transport_protection, "Restart lost protection modes on an uncovered subscription");
    request.expected = no_tls.session.identity;
    request.process_enabled = false;
    request.runtime = None;
    let independent = set_runtime_protection(credentials, session, &request).await?;
    ensure!(independent.code == 0, "Process protection was coupled to TLS node availability");
    let independent = independent.data.context("Missing independent protection outcome")?;
    ensure!(!independent.session.session_protection && independent.session.transport_protection, "Independent process disable changed transport mode");
    request.expected = independent.session.identity;
    request.restart = true;
    request.runtime = Some(compatible.clone());
    let before_cold = set_runtime_protection(credentials, session, &request).await?.data.context("Missing pre-recovery protection")?;
    ensure!(chrome_hello(&before_cold.session, &listener, "TransportInline").await?, "Transport was not active before service restart");
    stop_ipc_server().await?;
    let _restarted = run_ipc_server().await?;
    restore_desired_state().await?;
    let after_cold = recover_core_session(credentials, session).await?.data.context("Service restart did not restore the owned baseline")?;
    ensure!(!after_cold.session_protection && !after_cold.transport_protection
        && after_cold.runtime_base_yaml.is_none() && after_cold.runtime_yaml == compatible.yaml
        && !chrome_hello(&after_cold, &listener, "TransportInline").await?, "Service restart retained an unreported transport overlay");
    println!("PASS: durable baseline and cold service restore default off; no-TLS restart and independent process toggle; resource/manifest rollback; provider names cannot collide with protection temporaries");
    request.transport_enabled = false;
    request.process_enabled = false;
    request.expected = after_cold.identity;
    request.runtime = Some(runtime.clone());
    let restored = set_runtime_protection(credentials, session, &request).await?.data.context("Missing baseline restoration")?;
    ensure!(!restored.session.session_protection && !restored.session.transport_protection && restored.session.runtime_yaml == runtime.yaml, "Modes did not reset to the source fixture");
    subscription.abort();
    std::fs::remove_file(asset)?;
    println!("PASS: four protection combinations and both toggle orders; one session per combined change; idempotence; identity/token and unsupported preflight; real loopback ClientHello with inline and HTTP provider Chrome fingerprints; explicit fingerprint retained; baseline restoration; HTTP subscription refresh and config reload, manual restart, watchdog recovery and failed candidate rollback preserve both modes");
    Ok(restored.session)
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
    #[cfg(target_os = "macos")]
    {
        claimed = protection_checks(credentials, &session, &start.runtime, &claimed).await?;
        claimed = runtime_protection_checks(credentials, &session, &start.runtime, &claimed).await?;
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
    #[cfg(target_os = "macos")]
    {
        let fresh = start_idle_core(credentials, &start)
            .await?
            .data
            .context("Fresh start failed")?;
        let fresh_proof = proof(fresh.session.generation, &start.proposed_session_token);
        let fresh = recover_core_session(credentials, &fresh_proof)
            .await?
            .data
            .context("Fresh recovery failed")?;
        ensure!(!fresh.session_protection, "New session inherited protection");
        let protected = set_runtime_protection(
            credentials,
            &fresh_proof,
            &RuntimeProtectionRequest {
                expected: fresh.identity,
                process_enabled: true,
                transport_enabled: true,
                restart: false,
                runtime: Some(RuntimeBundle {
                    yaml: FIXTURE.replace("proxies: []", "proxies: [{name: StopFixture, type: trojan, server: 127.0.0.1, port: 1, password: fixture}]"),
                    ..start.runtime.clone()
                }),
            },
        )
        .await?
        .data
        .context("Fresh enable failed")?;
        let path = PathBuf::from(&protected.session.core_path);
        ensure!(
            stop_clash(credentials, &fresh_proof).await?.code == 0 && !path.exists(),
            "Protected stop retained its copy"
        );
        let fresh = start_idle_core(credentials, &start)
            .await?
            .data
            .context("Start after protected stop failed")?;
        let fresh_proof = proof(fresh.session.generation, &start.proposed_session_token);
        let fresh = recover_core_session(credentials, &fresh_proof)
            .await?
            .data
            .context("Fresh recovery failed")?;
        ensure!(!fresh.session_protection && !fresh.transport_protection && fresh.runtime_base_yaml.is_none(), "Protection survived a stopped core session");
        ensure!(
            stop_clash(credentials, &fresh_proof).await?.code == 0,
            "Fresh fixture stop failed"
        );
        println!("PASS: stopping a protected core removes its temporary copy; next owned session defaults off");
        let paths = service_paths()?;
        let orphan = paths.core_dir().join("session-deadbeef");
        std::fs::create_dir(&orphan)?;
        std::fs::write(orphan.join("TezCore"), "abandoned fixture copy")?;
        std::fs::write(paths.core_runtime_path(), serde_json::to_vec(&serde_json::json!({
            "pid": std::process::id(), "ipc_path": paths.runtime_dir().join("absent.sock"),
            "identity": {"executable": orphan.join("TezCore"), "started_at": 0}
        }))?)?;
        reconcile_service_startup().await?;
        ensure!(!orphan.exists() && !paths.core_runtime_path().exists(), "Stale-record reconciliation retained an orphan copy");
        println!("PASS: stale runtime record cleanup removes only the abandoned session copy without terminating a mismatched process");
    }
    println!(
        "PASS: separate-client recovery of pending receipt; private permissions/link/generation checks; root/token rejection; compare-and-claim without restart; displaced proof rejection; watchdog identity race rejection; private signed Mach-O staging without restart; stale identity/hash rejection without stopping; concurrent claim/upgrade serialization; real stable-to-alpha upgrade; failed candidate rollback; selected version persistence; owned stop. No latency tests or external subscriptions."
    );
    Ok(())
}

#[cfg(unix)]
#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.len() == 3 && args[0] == "--observe-fixture" {
        let credentials = test_owner_credentials(&Path::new(&args[1]).canonicalize()?)?;
        let pid = args[2].to_str().context("Invalid PID")?.parse::<u32>()?;
        let status = get_status(&credentials)
            .await?
            .data
            .context("Missing observer status")?;
        ensure!(
            status.is_active && status.core_pid == Some(pid),
            "Observer core changed"
        );
        let socket = status.core_ipc_path.context("Observer endpoint missing")?;
        let client = kode_bridge::IpcHttpClient::new(Path::new(&socket))?;
        let value = client.get("/version").send().await?.json::<serde_json::Value>()?;
        ensure!(value["version"].is_string(), "Observer controller unavailable");
        return Ok(());
    }
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
