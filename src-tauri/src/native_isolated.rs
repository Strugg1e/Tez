//! Fixture-only, child-owned experiments. This is not the production CoreManager runtime.
use std::{
    cell::RefCell,
    collections::BTreeMap,
    fs,
    io::{Read as _, Seek as _, SeekFrom, Write as _},
    net::{Ipv4Addr, TcpListener},
    os::unix::fs::{DirBuilderExt as _, MetadataExt as _},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    rc::Rc,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

use anyhow::{Context as _, Result, ensure};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::{
    cmd::{
        CmdResult, CommandFailure,
        save_profile::{profile_revision, write_checked_profile},
    },
    core::proxy_view::{ProxyViewBuilder, ProxyViewInput},
    native_control::{RouteParams, finish_selection, validate_route},
};

const FIXTURE: &str = "mode: rule\nport: 0\nsocks-port: 0\nredir-port: 0\ntproxy-port: 0\nmixed-port: 0\nallow-lan: false\nipv6: false\nlog-level: info\nexternal-controller: ''\ngeo-auto-update: false\nprofile:\n  store-selected: false\n  store-fake-ip: false\ndns:\n  enable: false\ntun:\n  enable: false\nproxies: []\nproxy-groups:\n  - name: Fixture\n    type: select\n    proxies: [DIRECT, REJECT]\nrules: ['MATCH,Fixture']\n";
const MAX_BYTES: usize = 64 * 1024;

fn isolated_io_error(_: impl std::fmt::Display) -> CommandFailure {
    CommandFailure::coded("ISOLATED_IO_FAILED", "Fixture storage failed")
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "kebab-case")]
struct FixtureConfig {
    mode: String,
    port: u16,
    socks_port: u16,
    redir_port: u16,
    tproxy_port: u16,
    mixed_port: u16,
    allow_lan: bool,
    ipv6: bool,
    log_level: String,
    external_controller: String,
    geo_auto_update: bool,
    profile: FixtureProfile,
    dns: Disabled,
    tun: Disabled,
    proxies: Vec<Value>,
    proxy_groups: Vec<FixtureGroup>,
    rules: Vec<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Disabled {
    enable: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "kebab-case")]
struct FixtureProfile {
    store_selected: bool,
    store_fake_ip: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct FixtureGroup {
    name: String,
    #[serde(rename = "type")]
    kind: String,
    proxies: Vec<String>,
}

fn validate_fixture(content: &str) -> Result<()> {
    ensure!(content.len() <= MAX_BYTES, "fixture content exceeds 64 KiB");
    let config: FixtureConfig = serde_yaml_ng::from_str(content)?;
    ensure!(
        ["rule", "global", "direct"].contains(&config.mode.as_str())
            && [
                config.port,
                config.socks_port,
                config.redir_port,
                config.tproxy_port,
                config.mixed_port
            ]
            .iter()
            .all(|port| *port == 0),
        "fixture cannot expose a proxy listener"
    );
    ensure!(
        !config.allow_lan && !config.ipv6 && !config.dns.enable && !config.tun.enable,
        "fixture cannot change networking"
    );
    ensure!(
        config.external_controller.is_empty()
            && config.proxies.is_empty()
            && !config.geo_auto_update
            && !config.profile.store_selected
            && !config.profile.store_fake_ip,
        "fixture cannot expose endpoints"
    );
    ensure!(
        ["info", "warning", "debug", "error", "silent"].contains(&config.log_level.as_str()),
        "unsupported fixture log level"
    );
    ensure!(
        config.proxy_groups.len() == 1 && config.rules == ["MATCH,Fixture"],
        "unsupported fixture structure"
    );
    let group = &config.proxy_groups[0];
    ensure!(
        group.name == "Fixture"
            && group.kind == "select"
            && (group.proxies == ["DIRECT", "REJECT"] || group.proxies == ["REJECT", "DIRECT"]),
        "fixture can only select builtin actions"
    );
    Ok(())
}

fn create_root(root: &Path) -> Result<()> {
    use std::os::unix::ffi::OsStrExt as _;
    ensure!(
        root.parent() == Some(Path::new("/private/tmp")),
        "fixture root must be directly below /private/tmp"
    );
    let name = root
        .file_name()
        .and_then(|name| name.to_str())
        .context("invalid fixture root")?;
    let suffix = name
        .strip_prefix("tez-native-isolated-")
        .context("invalid fixture root prefix")?;
    ensure!(
        suffix.len() >= 12
            && suffix.len() <= 32
            && suffix.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-'),
        "invalid fixture root identity"
    );
    ensure!(
        Path::new("/private/tmp").canonicalize()? == Path::new("/private/tmp"),
        "fixture parent contains symlinks"
    );
    ensure!(
        root.join("controller.sock").as_os_str().as_bytes().len() < 104,
        "fixture socket path too long"
    );
    fs::DirBuilder::new().mode(0o700).create(root)?;
    let metadata = fs::symlink_metadata(root)?;
    ensure!(
        metadata.is_dir() && metadata.uid() == unsafe { libc::geteuid() } && metadata.mode() & 0o777 == 0o700,
        "fixture directory ownership is invalid"
    );
    Ok(())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct ProfileRequest {
    uid: String,
    content: String,
    expected_revision: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ReadRequest {
    uid: String,
}

struct FixtureSource {
    url: String,
    stopping: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl FixtureSource {
    fn new(root: PathBuf) -> Result<Self> {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))?;
        listener.set_nonblocking(true)?;
        let url = format!("http://{}/subscription", listener.local_addr()?);
        let stopping = Arc::new(AtomicBool::new(false));
        let flag = stopping.clone();
        let thread = std::thread::spawn(move || {
            while !flag.load(Ordering::Acquire) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        let _ = stream.set_read_timeout(Some(Duration::from_secs(1)));
                        let _ = stream.set_write_timeout(Some(Duration::from_secs(1)));
                        let mut request = [0u8; 2048];
                        if let Ok(count) = stream.read(&mut request) {
                            if request[..count].starts_with(b"GET /subscription ") {
                                if let Ok(body) = fs::read(root.join("subscription-source.yaml")) {
                                let _ = write!(
                                    stream,
                                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nSubscription-Userinfo: upload=1; download=2; total=100; expire=0\r\nConnection: close\r\n\r\n",
                                    body.len()
                                );
                                    let _ = stream.write_all(&body);
                                }
                            } else if request[..count].starts_with(b"GET /generate_204 ")
                                || request[..count].starts_with(b"HEAD /generate_204 ") {
                                let _ = stream.write_all(b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                            }
                        }
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(10))
                    }
                    Err(_) => break,
                }
            }
        });
        Ok(Self {
            url,
            stopping,
            thread: Some(thread),
        })
    }
}

impl Drop for FixtureSource {
    fn drop(&mut self) {
        self.stopping.store(true, Ordering::Release);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

struct Session {
    root: PathBuf,
    core: PathBuf,
    client: reqwest::Client,
    child: Option<Child>,
    closing: bool,
    source: Option<FixtureSource>,
    log_stream: crate::native_logs::NativeLogStream,
}

impl Session {
    fn new(root: PathBuf) -> Result<Self> {
        let executable = std::env::current_exe()?;
        let bundle = crate::native_managed::inspect_bundle(&executable)?;
        let core = executable
            .parent()
            .context("missing helpers directory")?
            .join("verge-mihomo");
        validate_fixture(FIXTURE)?;
        create_root(&root)?;
        fs::write(root.join("profile.yaml"), FIXTURE)?;
        fs::write(root.join("core.log"), "")?;
        fs::create_dir(root.join("profiles"))?;
        fs::write(root.join("subscription-source.yaml"), FIXTURE)?;
        fs::write(root.join("dns.yaml"), "dns:\n  enable: false\n")?;
        fs::write(
            root.join("settings.json"),
            serde_json::to_vec(&json!({
                "enable_system_proxy":false, "enable_tun_mode":false, "enable_proxy_guard":false,
                "proxy_auto_config":false, "verge_mixed_port":7897, "verge_port":7899,
                "verge_http_enabled":false, "verge_socks_port":7898, "verge_socks_enabled":false,
                "system_proxy_bypass":"", "proxy_guard_duration":30,
                "default_latency_test":"https://www.gstatic.com/generate_204", "default_latency_timeout":5000,
                "app_log_level":"info"
            }))?,
        )?;
        fs::write(root.join("runtime.yaml"), FIXTURE)?;
        fs::write(
            root.join("profiles.yaml"),
            "current: fixture\nitems:\n  - uid: fixture\n    name: Isolated fixture\n    type: local\n    file: fixture.yaml\n",
        )?;
        fs::write(root.join("selection.json"), serde_json::to_vec("DIRECT")?)?;
        // The fixture never references databases, but own copies prevent core auto-downloads.
        for name in ["Country.mmdb", "ASN.mmdb", "geoip.dat", "geosite.dat"] {
            fs::copy(bundle.resources.join(name), root.join(name))?;
        }
        let client = reqwest::Client::builder()
            .no_proxy()
            .unix_socket(root.join("controller.sock"))
            .timeout(Duration::from_secs(2))
            .build()?;
        let source = FixtureSource::new(root.clone())?;
        Ok(Self {
            root,
            core,
            client,
            child: None,
            closing: false,
            source: Some(source),
            log_stream: crate::native_logs::NativeLogStream::new(),
        })
    }

    fn runtime(&mut self) -> Result<Value> {
        if let Some(child) = &mut self.child {
            if child.try_wait()?.is_some() {
                self.child = None;
            }
        }
        Ok(
            json!({"isolated":true,"running":self.child.is_some(),"pid":self.child.as_ref().map(Child::id),
            "dataDir":self.root,"socketPath":self.root.join("controller.sock"),"fixtureSubscriptionURL":self.source.as_ref().map(|source| &source.url)}),
        )
    }

    async fn request(&self, method: reqwest::Method, endpoint: &str, body: Option<Value>) -> Result<Value> {
        let mut request = self.client.request(method, format!("http://localhost{endpoint}"));
        if let Some(body) = body {
            request = request.json(&body);
        }
        let response = request.send().await?.error_for_status()?;
        let bytes = response.bytes().await?;
        if bytes.is_empty() {
            Ok(json!({}))
        } else {
            Ok(serde_json::from_slice(&bytes)?)
        }
    }

    async fn validate_file(&self, path: &Path) -> Result<()> {
        let mut command = tokio::process::Command::new(&self.core);
        command
            .args(["-t", "-d"])
            .arg(&self.root)
            .arg("-f")
            .arg(path)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .kill_on_drop(true);
        let status = tokio::time::timeout(Duration::from_secs(5), command.status())
            .await
            .context("fixture core validation timed out")??;
        ensure!(status.success(), "fixture core rejected the configuration");
        Ok(())
    }

    async fn select(&mut self, route: RouteParams, persist: bool) -> CmdResult<Value> {
        let result: Result<()> = async {
            ensure!(self.runtime()?["running"] == true, "fixture core is not running");
            let proxies = self.request(reqwest::Method::GET, "/proxies", None).await?;
            let view = ProxyViewBuilder::build(ProxyViewInput {
                runtime_group_order: vec!["Fixture".into()],
                group_scopes: BTreeMap::new(),
                proxies: serde_json::from_value(proxies)?,
                providers: None,
            });
            validate_route(&view, &route).map_err(|_| anyhow::anyhow!("invalid fixture route"))?;
            ensure!(
                route.group == "Fixture" && ["DIRECT", "REJECT"].contains(&route.name.as_str()),
                "unsupported fixture route"
            );
            self.request(
                reqwest::Method::PUT,
                "/proxies/Fixture",
                Some(json!({"name":route.name})),
            )
            .await?;
            Ok(())
        }
        .await;
        result.map_err(|_| CommandFailure::coded("ISOLATED_ROUTE_FAILED", "Fixture route selection failed"))?;
        Ok(finish_selection(&route.name, || async {
            if persist {
                fs::write(
                    self.root.join("selection.json"),
                    serde_json::to_vec(&route.name).map_err(CommandFailure::plain)?,
                )
                .map_err(CommandFailure::plain)?;
            }
            Ok(())
        })
        .await)
    }

    async fn start(&mut self) -> Result<Value> {
        if self.runtime()?["running"] == true {
            return self.runtime();
        }
        let content = fs::read_to_string(self.root.join("profile.yaml"))?;
        validate_fixture(&content)?;
        fs::write(self.root.join("runtime.yaml"), content)?;
        self.validate_file(&self.root.join("runtime.yaml")).await?;
        let log = fs::OpenOptions::new().append(true).open(self.root.join("core.log"))?;
        self.child = Some(
            Command::new(&self.core)
                .arg("-d")
                .arg(&self.root)
                .arg("-f")
                .arg(self.root.join("runtime.yaml"))
                .arg("-ext-ctl-unix")
                .arg(self.root.join("controller.sock"))
                .stdin(Stdio::null())
                .stdout(Stdio::from(log.try_clone()?))
                .stderr(Stdio::from(log))
                .spawn()?,
        );
        let mut ready = false;
        for _ in 0..40 {
            if self.runtime()?["running"] != true {
                break;
            }
            if self.request(reqwest::Method::GET, "/version", None).await.is_ok() {
                ready = true;
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        if !ready {
            self.stop().await?;
            anyhow::bail!("fixture core did not become ready");
        }
        let name: String = serde_json::from_slice(&fs::read(self.root.join("selection.json"))?)?;
        if !["DIRECT", "REJECT"].contains(&name.as_str()) {
            self.stop().await?;
            anyhow::bail!("invalid saved fixture selection");
        }
        if self
            .select(
                RouteParams {
                    group: "Fixture".into(),
                    name,
                },
                false,
            )
            .await
            .is_err()
        {
            self.stop().await?;
            anyhow::bail!("fixture selection restore failed");
        }
        self.runtime()
    }

    async fn stop(&mut self) -> Result<Value> {
        self.log_stream.reset();
        if let Some(child) = &mut self.child {
            if child.try_wait()?.is_none() {
                // Only the unreaped child owned by this session can receive a signal.
                let result = unsafe { libc::kill(child.id() as libc::pid_t, libc::SIGTERM) };
                ensure!(result == 0, "could not signal the owned fixture child");
                let deadline = Instant::now() + Duration::from_secs(5);
                while child.try_wait()?.is_none() && Instant::now() < deadline {
                    tokio::time::sleep(Duration::from_millis(50)).await;
                }
                if child.try_wait()?.is_none() {
                    child.kill()?;
                    child.wait()?;
                }
            }
            self.child = None;
        }
        self.runtime()
    }

    async fn save(&mut self, request: ProfileRequest) -> CmdResult<Value> {
        if request.uid != "fixture" {
            return Err(CommandFailure::coded("INVALID_PARAMS", "Unknown fixture profile"));
        }
        validate_fixture(&request.content).map_err(|_| {
            CommandFailure::coded(
                "ISOLATED_CONFIG_REJECTED",
                "Only the network-disabled fixture schema is accepted",
            )
        })?;
        let profile = self.root.join("profile.yaml");
        let original = fs::read_to_string(&profile).map_err(CommandFailure::plain)?;
        if profile_revision(&original) != request.expected_revision {
            return Err(CommandFailure::coded(
                "PROFILE_REVISION_CONFLICT",
                "Profile changed since it was read",
            ));
        }
        let candidate = self.root.join("candidate.yaml");
        fs::write(&candidate, &request.content).map_err(CommandFailure::plain)?;
        self.validate_file(&candidate)
            .await
            .map_err(|_| CommandFailure::coded("ISOLATED_CONFIG_INVALID", "Fixture core validation failed"))?;
        let latest = fs::read_to_string(&profile).map_err(CommandFailure::plain)?;
        write_checked_profile(&profile, &latest, &request.content, Some(&request.expected_revision)).await?;
        let apply: Result<()> = async {
            fs::write(self.root.join("runtime.yaml"), &request.content)?;
            if self.runtime()?["running"] == true {
                self.request(
                    reqwest::Method::PUT,
                    "/configs?force=true",
                    Some(json!({"path":self.root.join("runtime.yaml")})),
                )
                .await?;
                self.restore_selection().await?;
            }
            Ok(())
        }
        .await;
        if apply.is_err() {
            let rollback: Result<()> = async {
                fs::write(&profile, &original)?;
                fs::write(self.root.join("runtime.yaml"), &original)?;
                if self.runtime()?["running"] == true {
                    self.request(
                        reqwest::Method::PUT,
                        "/configs?force=true",
                        Some(json!({"path":self.root.join("runtime.yaml")})),
                    )
                    .await?;
                    self.restore_selection().await?;
                }
                Ok(())
            }
            .await;
            return Ok(json!({"uid":"fixture","saved":false,"revision":null,
                "validation":"runtimeApplyFailed","rollbackFailed":rollback.is_err()}));
        }
        Ok(json!({"uid":"fixture","saved":true,"revision":profile_revision(&request.content),"validation":"valid"}))
    }

    async fn restore_selection(&mut self) -> Result<()> {
        let name: String = serde_json::from_slice(&fs::read(self.root.join("selection.json"))?)?;
        ensure!(
            ["DIRECT", "REJECT"].contains(&name.as_str()),
            "invalid saved fixture selection"
        );
        self.select(
            RouteParams {
                group: "Fixture".into(),
                name,
            },
            false,
        )
        .await
        .map_err(|_| anyhow::anyhow!("fixture selection restore failed"))?;
        Ok(())
    }

    async fn dispatch(&mut self, command: &str, params: Value) -> CmdResult<Value> {
        if self.closing && !["native_get_runtime", "native_prepare_shutdown"].contains(&command) {
            return Err(CommandFailure::coded(
                "NATIVE_SHUTDOWN_IN_PROGRESS",
                "Session is closing",
            ));
        }
        match command {
            "native_close_connection" => {
                let id = crate::native_control::parse_connection_id(params)?;
                if self.child.is_none() {
                    return Err(CommandFailure::coded("CORE_NOT_RUNNING", "No isolated core is running"));
                }
                let data = crate::native_data::NativeData::new(self.root.clone(), self.root.join("controller.sock"))
                    .map_err(isolated_io_error)?;
                let (_, client, _) = data.controller().await.map_err(isolated_io_error)?;
                crate::native_control::close_connection(&client, &id).await
            }
            "native_get_settings"
            | "native_patch_settings"
            | "native_set_mode"
            | "native_get_dns"
            | "native_save_dns"
            | "native_get_logs"
            | "native_import_subscription"
            | "native_subscription_details"
            | "native_patch_subscription"
            | "native_update_subscription"
            | "native_activate_profile"
            | "native_test_latency" => self.workspace(crate::native_workspace::parse(command, params)?).await,
            "native_prepare_shutdown" => {
                if !params.as_object().is_some_and(serde_json::Map::is_empty) {
                    return Err(CommandFailure::coded("INVALID_PARAMS", "Expected empty params"));
                }
                self.closing = true;
                self.stop().await.map_err(|_| {
                    CommandFailure::coded("NATIVE_SHUTDOWN_UNRESOLVED", "Owned fixture shutdown is unconfirmed")
                })?;
                Ok(json!({"safeToExit":true}))
            }
            "native_read_profile" => {
                let request: ReadRequest = serde_json::from_value(params).map_err(CommandFailure::plain)?;
                if request.uid != "fixture" {
                    return Err(CommandFailure::coded("INVALID_PARAMS", "Unknown fixture profile"));
                }
                let content = fs::read_to_string(self.root.join("profile.yaml")).map_err(CommandFailure::plain)?;
                Ok(json!({"uid":"fixture","revision":profile_revision(&content),"content":content}))
            }
            "native_save_profile" => {
                self.save(serde_json::from_value(params).map_err(CommandFailure::plain)?)
                    .await
            }
            "native_select_route" => {
                self.select(serde_json::from_value(params).map_err(CommandFailure::plain)?, true)
                    .await
            }
            "native_core_start" | "native_core_stop" | "native_core_restart" | "native_get_runtime" => {
                if !params.as_object().is_some_and(serde_json::Map::is_empty) {
                    return Err(CommandFailure::coded("INVALID_PARAMS", "Expected empty params"));
                }
                let result = match command {
                    "native_core_start" => self.start().await,
                    "native_core_stop" => self.stop().await,
                    "native_core_restart" => {
                        self.stop().await.map_err(CommandFailure::plain)?;
                        self.start().await
                    }
                    _ => self.runtime(),
                };
                result.map_err(|_| CommandFailure::coded("ISOLATED_LIFECYCLE_FAILED", "Fixture core transition failed"))
            }
            _ => Err(CommandFailure::coded(
                "NATIVE_COMMAND_UNAVAILABLE",
                "Command is unavailable",
            )),
        }
    }

    async fn workspace(&mut self, request: crate::native_workspace::Request) -> CmdResult<Value> {
        use crate::native_workspace::Request;
        match request {
            Request::ActivateProfile { uid } => {
                let mut profiles = self.fixture_profiles()?;
                if profiles.current.as_deref() == Some(uid.as_str()) { return Ok(json!({"applied":true})); }
                let item = profiles.get_item(&uid).map_err(isolated_io_error)?;
                if item.itype.as_deref() != Some("remote") {
                    return Err(CommandFailure::coded("ISOLATED_PROFILE_UNAVAILABLE", "Only downloaded fixture subscriptions can be activated"));
                }
                let path = isolated_profile_path(&self.root, item)?;
                let content = fs::read_to_string(path).map_err(isolated_io_error)?;
                validate_fixture(&content).map_err(|_| CommandFailure::coded("ISOLATED_CONFIG_REJECTED", "Only network-disabled fixtures can be activated"))?;
                let original = fs::read_to_string(self.root.join("profile.yaml")).map_err(isolated_io_error)?;
                let applied = self.save(ProfileRequest { uid:"fixture".into(), content, expected_revision:profile_revision(&original) }).await?;
                if applied["saved"] != true { return Err(CommandFailure::coded("ISOLATED_APPLY_FAILED", applied)); }
                profiles.current = Some(uid.into());
                self.save_fixture_profiles(&profiles).map_err(|_| CommandFailure::coded("ISOLATED_PROFILE_COMMIT_FAILED", "Fixture configuration applied, but profile selection was not persisted"))?;
                Ok(json!({"applied":true}))
            }
            Request::TestLatency { names, url, timeout } => {
                let expected = self.source.as_ref().map(|source| source.url.replace("/subscription", "/generate_204"));
                if names != ["DIRECT"] || expected.as_deref() != Some(url.as_str()) {
                    return Err(CommandFailure::coded("ISOLATED_NETWORK_FORBIDDEN", "Only the owned loopback latency target is allowed"));
                }
                if self.runtime().map_err(isolated_io_error)?["running"] != true {
                    return Err(CommandFailure::coded("CORE_NOT_READY", "Fixture core is stopped"));
                }
                let socket = self.root.join("controller.sock").to_string_lossy().into_owned();
                let context = tauri_plugin_mihomo::MihomoContext::new(tauri_plugin_mihomo::models::Protocol::LocalSocket,
                    None, None, None, Some(socket), Duration::from_secs(2), self.client.clone());
                let client = tauri_plugin_mihomo::Mihomo::new(context);
                let result = client.delay_proxy_by_name("DIRECT", &url, timeout).await;
                let result = match result { Ok(value) => json!({"name":"DIRECT","delay":value.delay}),
                    Err(_) => json!({"name":"DIRECT","delay":null,"error":"PROBE_FAILED"}) };
                Ok(json!({"results":[result]}))
            }
            Request::ImportSubscription {
                url,
                name,
                interval,
                auto_update,
                with_proxy,
            } => {
                if self.source.as_ref().map(|source| source.url.as_str()) != Some(url.as_str()) || with_proxy {
                    return Err(CommandFailure::coded(
                        "ISOLATED_NETWORK_FORBIDDEN",
                        "Only the owned loopback subscription source is allowed",
                    ));
                }
                // Existing enhancement references prevent from_url from creating global profile files.
                let option = crate::config::PrfOption {
                    with_proxy: Some(false),
                    update_interval: Some(interval),
                    allow_auto_update: Some(auto_update),
                    merge: Some("fixture-merge".into()),
                    script: Some("fixture-script".into()),
                    rules: Some("fixture-rules".into()),
                    proxies: Some("fixture-proxies".into()),
                    groups: Some("fixture-groups".into()),
                    ..Default::default()
                };
                let mut item = crate::config::PrfItem::from_url(&url, Some(&name.into()), None, Some(&option))
                    .await
                    .map_err(|_| {
                        CommandFailure::coded("ISOLATED_IMPORT_FAILED", "Fixture subscription download failed")
                    })?;
                let uid = item
                    .uid
                    .as_ref()
                    .map(ToString::to_string)
                    .ok_or_else(|| isolated_io_error("missing uid"))?;
                let file = isolated_profile_path(&self.root, &item)?;
                let content = item
                    .file_data
                    .take()
                    .ok_or_else(|| isolated_io_error("missing content"))?;
                write_fixture_profile(&file, content.as_bytes(), true)?;
                let mut profiles = self.fixture_profiles()?;
                profiles.items.get_or_insert_with(Vec::new).push(item);
                self.save_fixture_profiles(&profiles)?;
                Ok(json!({"saved":true,"uid":uid}))
            }
            Request::SubscriptionDetails { uid } => {
                let profiles = self.fixture_profiles()?;
                let item = profiles.get_item(&uid).map_err(isolated_io_error)?;
                let option = item.option.clone().unwrap_or_default();
                Ok(
                    json!({"uid":uid,"name":item.name,"url":item.url,"interval":option.update_interval.unwrap_or(1440),
                    "autoUpdate":option.allow_auto_update.unwrap_or(true),"withProxy":option.with_proxy.unwrap_or(false),"usage":item.extra,"nextUpdate":null}),
                )
            }
            Request::PatchSubscription {
                uid,
                name,
                url,
                interval,
                auto_update,
                with_proxy,
            } => {
                if with_proxy
                    || url
                        .as_ref()
                        .is_some_and(|url| self.source.as_ref().map(|source| &source.url) != Some(url))
                {
                    return Err(CommandFailure::coded(
                        "ISOLATED_NETWORK_FORBIDDEN",
                        "Only the owned loopback subscription source is allowed",
                    ));
                }
                let mut profiles = self.fixture_profiles()?;
                let item = profiles
                    .items
                    .as_mut()
                    .and_then(|items| items.iter_mut().find(|item| item.uid.as_deref() == Some(uid.as_str())))
                    .ok_or_else(|| isolated_io_error("missing profile"))?;
                item.name = Some(name.into());
                if item.itype.as_deref() == Some("remote") {
                    if let Some(url) = url {
                        item.url = Some(url.into());
                    }
                    let option = item.option.get_or_insert_with(Default::default);
                    option.update_interval = Some(interval);
                    option.allow_auto_update = Some(auto_update);
                    option.with_proxy = Some(false);
                } else if url.is_some() {
                    return Err(isolated_io_error("local URL"));
                }
                self.save_fixture_profiles(&profiles)?;
                Ok(json!({"saved":true}))
            }
            Request::UpdateSubscription { uid } => {
                let mut profiles = self.fixture_profiles()?;
                if profiles.current.as_deref() == Some(uid.as_str()) {
                    return Err(CommandFailure::coded(
                        "ISOLATED_ACTIVE_UPDATE_UNAVAILABLE",
                        "Active fixture updates are not supported",
                    ));
                }
                let item = profiles
                    .items
                    .as_mut()
                    .and_then(|items| items.iter_mut().find(|item| item.uid.as_deref() == Some(uid.as_str())))
                    .ok_or_else(|| isolated_io_error("missing profile"))?;
                let url = item.url.as_deref().ok_or_else(|| isolated_io_error("missing URL"))?;
                let safe_options = item.option.as_ref().is_some_and(|option| {
                    option.with_proxy == Some(false)
                        && option.self_proxy != Some(true)
                        && option.merge.as_deref() == Some("fixture-merge")
                        && option.script.as_deref() == Some("fixture-script")
                        && option.rules.as_deref() == Some("fixture-rules")
                        && option.proxies.as_deref() == Some("fixture-proxies")
                        && option.groups.as_deref() == Some("fixture-groups")
                });
                if self.source.as_ref().map(|source| source.url.as_str()) != Some(url) || !safe_options {
                    return Err(CommandFailure::coded(
                        "ISOLATED_NETWORK_FORBIDDEN",
                        "Only the owned loopback subscription source is allowed",
                    ));
                }
                let fresh = crate::config::PrfItem::from_url(url, item.name.as_ref(), None, item.option.as_ref())
                    .await
                    .map_err(|_| {
                        CommandFailure::coded("ISOLATED_UPDATE_FAILED", "Fixture subscription download failed")
                    })?;
                let file = isolated_profile_path(&self.root, item)?;
                write_fixture_profile(
                    &file,
                    fresh
                        .file_data
                        .ok_or_else(|| isolated_io_error("missing content"))?
                        .as_bytes(),
                    false,
                )?;
                item.extra = fresh.extra;
                item.updated = fresh.updated;
                self.save_fixture_profiles(&profiles)?;
                Ok(json!({"updated":true}))
            }
            Request::GetSettings => {
                let values: Value =
                    serde_json::from_slice(&fs::read(self.root.join("settings.json")).map_err(isolated_io_error)?)
                        .map_err(isolated_io_error)?;
                let content = fs::read_to_string(self.root.join("profile.yaml")).map_err(isolated_io_error)?;
                let config: FixtureConfig = serde_yaml_ng::from_str(&content).map_err(isolated_io_error)?;
                Ok(json!({"values":values,"mode":config.mode}))
            }
            Request::PatchSettings { values } => {
                if values.keys().any(|key| {
                    !["default_latency_test", "default_latency_timeout", "app_log_level"].contains(&key.as_str())
                }) {
                    return Err(CommandFailure::coded(
                        "ISOLATED_NETWORK_FORBIDDEN",
                        "Fixture cannot modify network settings",
                    ));
                }
                let path = self.root.join("settings.json");
                let mut saved: serde_json::Map<String, Value> =
                    serde_json::from_slice(&fs::read(&path).map_err(isolated_io_error)?).map_err(isolated_io_error)?;
                saved.extend(values);
                fs::write(path, serde_json::to_vec(&saved).map_err(isolated_io_error)?).map_err(isolated_io_error)?;
                Ok(json!({"saved":true}))
            }
            Request::SetMode { mode } => {
                let original = fs::read_to_string(self.root.join("profile.yaml")).map_err(isolated_io_error)?;
                let mut mapping: serde_yaml_ng::Mapping =
                    serde_yaml_ng::from_str(&original).map_err(isolated_io_error)?;
                mapping.insert("mode".into(), mode.into());
                let content = serde_yaml_ng::to_string(&mapping).map_err(isolated_io_error)?;
                let result = self
                    .save(ProfileRequest {
                        uid: "fixture".into(),
                        content,
                        expected_revision: profile_revision(&original),
                    })
                    .await?;
                if result["saved"] != true {
                    return Err(CommandFailure::coded("ISOLATED_APPLY_FAILED", result));
                }
                Ok(json!({"applied":true}))
            }
            Request::GetDns => {
                let content = fs::read_to_string(self.root.join("dns.yaml")).map_err(isolated_io_error)?;
                Ok(json!({"content":content,"uid":"fixture","enabled":false}))
            }
            Request::SaveDns { content } => {
                fs::write(self.root.join("dns.yaml"), content).map_err(isolated_io_error)?;
                Ok(json!({"saved":true,"applied":false}))
            }
            Request::GetLogs { limit, level, query } => {
                let running = self.runtime().map_err(isolated_io_error)?["running"] == true;
                let connected = if running {
                    self.log_stream.connect(&self.root.join("controller.sock")).await
                        .map_err(|_| CommandFailure::coded("LOG_STREAM_UNAVAILABLE", "Cannot subscribe to fixture Core logs"))?
                } else { false };
                let mut file = fs::File::open(self.root.join("core.log")).map_err(isolated_io_error)?;
                let length = file.metadata().map_err(isolated_io_error)?.len();
                file.seek(SeekFrom::Start(length.saturating_sub(4 * 1024 * 1024)))
                    .map_err(isolated_io_error)?;
                let mut bytes = Vec::new();
                file.take(4 * 1024 * 1024)
                    .read_to_end(&mut bytes)
                    .map_err(isolated_io_error)?;
                let lines = String::from_utf8_lossy(&bytes).lines().map(str::to_owned).collect();
                if running {
                    if connected { self.log_stream.seed(lines); }
                    Ok(self.log_stream.read(limit, &level, &query))
                } else {
                    Ok(json!({"lines":crate::native_workspace::filter_logs(lines, limit, &level, &query),"streaming":false}))
                }
            }
            _ => Err(CommandFailure::coded(
                "NATIVE_COMMAND_UNAVAILABLE",
                "Command is unavailable in isolated mode",
            )),
        }
    }

    fn fixture_profiles(&self) -> CmdResult<crate::config::IProfiles> {
        serde_yaml_ng::from_str(&fs::read_to_string(self.root.join("profiles.yaml")).map_err(isolated_io_error)?)
            .map_err(isolated_io_error)
    }

    fn save_fixture_profiles(&self, profiles: &crate::config::IProfiles) -> CmdResult<()> {
        fs::write(
            self.root.join("profiles.yaml"),
            serde_yaml_ng::to_string(profiles).map_err(isolated_io_error)?,
        )
        .map_err(isolated_io_error)
    }
}

fn isolated_profile_path(root: &Path, item: &crate::config::PrfItem) -> CmdResult<PathBuf> {
    let uid = item.uid.as_deref().ok_or_else(|| isolated_io_error("missing uid"))?;
    if uid.len() > 128
        || !uid
            .bytes()
            .all(|value| value.is_ascii_alphanumeric() || value == b'-' || value == b'_')
        || item.file.as_deref() != Some(format!("{uid}.yaml").as_str())
    {
        return Err(isolated_io_error("invalid fixture file"));
    }
    Ok(root.join("profiles").join(format!("{uid}.yaml")))
}

fn write_fixture_profile(path: &Path, content: &[u8], create: bool) -> CmdResult<()> {
    use std::os::unix::fs::OpenOptionsExt as _;
    let mut options = fs::OpenOptions::new();
    options.write(true).custom_flags(libc::O_NOFOLLOW);
    if create {
        options.create_new(true);
    } else {
        options.truncate(true);
    }
    options
        .open(path)
        .and_then(|mut file| file.write_all(content))
        .map_err(isolated_io_error)
}

pub fn run_stdio(root: PathBuf) -> Result<()> {
    crate::native_host::require_inherited_pipes()?;
    let data = crate::native_data::NativeData::new(root.clone(), root.join("controller.sock"))?;
    let activity_data = data.clone();
    let session = Rc::new(RefCell::new(Session::new(root)?));
    let mut recovery_channel = crate::native_recovery::RecoveryChannel::from_env()?;
    let snapshot = session.clone();
    let commands = session.clone();
    let capabilities: Vec<_> = crate::native_managed::CAPABILITIES
        .iter()
        .copied()
        .filter(|command| {
            !crate::native_workspace::COMMANDS.contains(command)
                || [
                    "native_get_settings",
                    "native_patch_settings",
                    "native_set_mode",
                    "native_get_dns",
                    "native_save_dns",
                    "native_get_logs",
                    "native_import_subscription",
                    "native_subscription_details",
                    "native_patch_subscription",
                    "native_update_subscription",
                    "native_activate_profile",
                    "native_test_latency",
                ]
                .contains(command)
        })
        .collect();
    let served = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        crate::native_host::serve_managed_with_activity(
            move || {
                let runtime = snapshot.borrow_mut().runtime()?;
                let mut value = tauri::async_runtime::block_on(data.snapshot());
                value["isolated"] = json!(true);
                value["runtime"] = runtime;
                Ok(value)
            },
            move |query| Ok(tauri::async_runtime::block_on(activity_data.activity_query(query))),
            move |command, params| tauri::async_runtime::block_on(commands.borrow_mut().dispatch(command, params)),
            Some(&capabilities),
        )
    }))
    .unwrap_or_else(|_| Err(anyhow::anyhow!("isolated protocol worker panicked")));
    let stopped = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        tauri::async_runtime::block_on(session.borrow_mut().stop())
    }))
    .unwrap_or_else(|_| Err(anyhow::anyhow!("isolated controlled shutdown panicked")));
    if stopped.is_err() {
        let recovered = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            if let Some(channel) = &mut recovery_channel {
                channel.wait_and_retry(|| tauri::async_runtime::block_on(session.borrow_mut().stop()).map(|_| ()))
            } else {
                Err(anyhow::anyhow!("isolated recovery channel unavailable"))
            }
        }));
        if !matches!(recovered, Ok(Ok(()))) {
            // Preserve the owning session if recovery itself cannot confirm cleanup.
            loop {
                std::thread::park();
            }
        }
    }
    if served.is_err() {
        eprintln!("Isolated protocol failed; owned core cleanup was confirmed.");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn prepared_shutdown_is_idempotent_and_blocks_new_work() {
        let mut session = Session {
            root: PathBuf::from("/unused"),
            core: PathBuf::from("/unused"),
            client: reqwest::Client::new(),
            child: None,
            closing: false,
            source: None,
            log_stream: crate::native_logs::NativeLogStream::new(),
        };
        assert!(
            session
                .dispatch("native_prepare_shutdown", json!({"unexpected":true}))
                .await
                .is_err()
        );
        assert!(!session.closing);
        for _ in 0..2 {
            assert_eq!(
                session.dispatch("native_prepare_shutdown", json!({})).await.unwrap(),
                json!({"safeToExit":true})
            );
        }
        assert!(session.dispatch("native_core_start", json!({})).await.is_err());
        assert!(session.dispatch("native_save_profile", json!({})).await.is_err());
        assert_eq!(
            session.dispatch("native_get_runtime", json!({})).await.unwrap()["running"],
            false
        );
    }
    #[test]
    fn fixture_disallows_network_and_duplicate_or_unknown_fields() {
        validate_fixture(FIXTURE).unwrap();
        validate_fixture(&FIXTURE.replace("log-level: info", "log-level: warning")).unwrap();
        for content in [
            FIXTURE.replace("port: 0", "port: 7890"),
            FIXTURE.replace("enable: false", "enable: true"),
            format!("{FIXTURE}profile: {{store-selected: true}}\n"),
            format!("{FIXTURE}mode: rule\n"),
            FIXTURE.replace(
                "proxies: []",
                "proxies: [{name: remote, type: socks5, server: example.com, port: 443}]",
            ),
        ] {
            assert!(validate_fixture(&content).is_err());
        }
    }

    #[test]
    fn root_gate_refuses_existing_or_noncanonical_paths() {
        for path in [
            "/tmp/tez-native-isolated-abcdefghijkl",
            "/private/tmp/other-abcdefghijkl",
            "/private/tmp/tez-native-isolated-short",
            "/private/tmp/../tmp/tez-native-isolated-abcdefghijkl",
        ] {
            assert!(create_root(Path::new(path)).is_err());
        }
        let suffix = format!(
            "{:x}{:x}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        );
        let root = PathBuf::from(format!("/private/tmp/tez-native-isolated-{suffix}"));
        create_root(&root).unwrap();
        assert!(create_root(&root).is_err());
        fs::remove_dir(&root).unwrap();
    }
}
