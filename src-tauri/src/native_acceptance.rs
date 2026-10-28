//! Explicitly built acceptance executable. Production binaries do not include this module.

use crate::{
    config::Config,
    core::{CoreManager, Timer, manager::RunningMode},
    utils::dirs,
};
use anyhow::{Context as _, Result, ensure};
use serde_json::{Value, json};
use std::{
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};

struct OwnedCore(Child);

impl Drop for OwnedCore {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

pub fn run(root: PathBuf, source: &str, invalid_tls: &str) -> Result<()> {
    let canonical = root.canonicalize()?;
    ensure!(
        root == canonical && root.parent() == Some(Path::new("/private/tmp")),
        "acceptance root must be canonical and temporary"
    );
    ensure!(
        root.file_name()
            .and_then(|v| v.to_str())
            .is_some_and(|v| v.starts_with("tez-subscription-check-")),
        "unexpected acceptance root"
    );
    ensure!(
        std::env::var_os("HOME").as_deref() == Some(root.join("home").as_os_str()),
        "dedicated HOME required"
    );
    ensure!(
        dirs::app_home_dir()? == root.join("home/Library/Application Support/app.tez.client"),
        "data resolver escaped acceptance HOME"
    );
    let url = reqwest::Url::parse(source)?;
    ensure!(
        url.scheme() == "http"
            && url.host_str() == Some("127.0.0.1")
            && url.port().is_some()
            && url.path() == "/subscription",
        "loopback subscription source required"
    );
    let invalid_tls_url = reqwest::Url::parse(invalid_tls)?;
    ensure!(
        invalid_tls_url.scheme() == "https"
            && invalid_tls_url.host_str() == Some("127.0.0.1")
            && invalid_tls_url.port().is_some(),
        "loopback HTTPS fixture required"
    );
    let source = source.to_owned();
    let invalid_tls = invalid_tls.to_owned();
    let socket = root.join("core.sock");
    let mut context = tauri::generate_context!();
    context.config_mut().app.windows.clear();
    let result = Arc::new(Mutex::new(None));
    let worker_result = result.clone();
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
            crate::APP_HANDLE
                .set(app.handle().clone())
                .map_err(|_| anyhow::anyhow!("app handle already initialized"))?;
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);
            let handle = app.handle().clone();
            std::thread::Builder::new()
                .name("tez-subscription-check".into())
                .spawn(move || {
                    let outcome = tauri::async_runtime::block_on(async {
                        let outcome = execute(&root, &socket, &source, &invalid_tls).await;
                        // Drain the real scheduler even after a failed assertion before dropping its runtime.
                        let drained = Timer::global().drain().await;
                        outcome.and(drained)
                    });
                    if let Err(error) = &outcome {
                        let _ = std::fs::write(root.join("failure.txt"), format!("{error:#}"));
                    }
                    let code = i32::from(outcome.is_err());
                    *worker_result.lock().unwrap() = Some(outcome);
                    handle.exit(code);
                })?;
            Ok(())
        })
        .build(context)?;
    app.run(|_, _| {});
    result
        .lock()
        .unwrap()
        .take()
        .context("acceptance worker did not finish")?
}

async fn command(name: &str, params: Value) -> Result<Value> {
    crate::native_workspace::dispatch(name, params)
        .await
        .map_err(|error| anyhow::anyhow!("{name}: {error:?}"))
}

fn command_error(error: crate::cmd::CommandFailure) -> anyhow::Error {
    anyhow::anyhow!("{error:?}")
}

async fn core_rules(socket: &Path) -> Result<Value> {
    let mut connection = tokio::net::UnixStream::connect(socket).await?;
    connection
        .write_all(b"GET /rules HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        .await?;
    let mut response = Vec::new();
    tokio::time::timeout(
        Duration::from_secs(3),
        connection.take(1024 * 1024).read_to_end(&mut response),
    )
    .await??;
    let boundary = response
        .windows(4)
        .position(|v| v == b"\r\n\r\n")
        .context("Core HTTP response")?;
    ensure!(response.starts_with(b"HTTP/1.1 200"), "Core rejected rule read");
    serde_json::from_slice(&response[boundary + 4..]).context("Core rule JSON")
}

async fn control(source: &str, revision: u8) -> Result<Value> {
    let url = reqwest::Url::parse(source)?.join(&format!("control?revision={revision}"))?;
    Ok(reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(3))
        .build()?
        .get(url)
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?)
}

async fn wait_revision(uid: &str, socket: &Path, revision: u8) -> Result<()> {
    let marker = format!("revision-{revision}.tez.invalid");
    tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            let content = crate::cmd::read_profile_file(uid.to_owned())
                .await
                .map_err(command_error)?;
            if content.contains(&marker) && core_rules(socket).await?.to_string().contains(&marker) {
                return Ok::<_, anyhow::Error>(());
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    })
    .await
    .context("subscription was not persisted and applied before deadline")?
}

async fn patch(uid: &str, enabled: bool) -> Result<()> {
    command(
        "native_patch_subscription",
        json!({"uid":uid,"name":"Acceptance subscription", "interval":1440, "auto_update":enabled,"with_proxy":false}),
    )
    .await?;
    Timer::global().refresh().await
}

async fn execute(root: &Path, socket: &Path, source: &str, invalid_tls: &str) -> Result<()> {
    let data = dirs::app_home_dir()?;
    std::fs::create_dir_all(data.join("profiles"))?;
    std::fs::write(data.join("profiles.yaml"), "current: null\nitems: []\n")?;
    std::fs::write(
        data.join("tez.yaml"),
        "enable_tun_mode: false\nenable_system_proxy: false\nenable_builtin_enhanced: false\nenable_external_controller: false\n",
    )?;
    let safe_config = format!(
        "mixed-port: 0\nport: 0\nsocks-port: 0\nredir-port: 0\nexternal-controller: ''\nexternal-controller-unix: '{}'\nsecret: ''\nallow-lan: false\nipv6: false\nmode: rule\nlog-level: debug\ntun: {{enable: false}}\ndns: {{enable: false}}\nproxies: []\nproxy-groups: []\nrules: ['MATCH,DIRECT']\n",
        socket.display()
    );
    std::fs::write(data.join("config.yaml"), &safe_config)?;
    Config::init_config_before_window().await?;
    crate::core::logger::init().await?;
    // Production startup guards replace zero mixed-port; the fixture deliberately has no listeners.
    Config::clash().await.edit_draft(|draft| {
        draft.0 = serde_yaml_ng::from_str(&safe_config).unwrap();
        for key in ["proxies", "proxy-groups", "rules"] {
            draft.0.remove(key);
        }
    });
    Config::clash().await.apply();
    let bootstrap = root.join("bootstrap.yaml");
    std::fs::write(&bootstrap, &safe_config)?;
    let core = std::env::current_exe()?.with_file_name("verge-mihomo");
    let child = Command::new(core)
        .args(["-d"])
        .arg(&data)
        .arg("-f")
        .arg(&bootstrap)
        .stdin(Stdio::null())
        .stdout(Stdio::from(std::fs::File::create(root.join("core.log"))?))
        .stderr(Stdio::null())
        .spawn()?;
    let mut owned = OwnedCore(child);
    std::fs::write(root.join("owned-core.pid"), owned.0.id().to_string())?;
    tokio::time::timeout(Duration::from_secs(8), async {
        loop {
            ensure!(owned.0.try_wait()?.is_none(), "fixture Core exited during startup");
            if core_rules(socket).await.is_ok() {
                return Ok::<_, anyhow::Error>(());
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    })
    .await
    .context("fixture Core did not become ready")??;
    CoreManager::global().core_started(RunningMode::Sidecar);

    command(
        "native_create_local_profile",
        json!({"name":"Acceptance baseline", "content":"proxies: []\nrules: ['MATCH,DIRECT']\n"}),
    )
    .await?;
    let previous = Config::profiles().await.data_arc().current.clone();
    ensure!(previous.is_some(), "baseline profile was not selected");
    let imported = command(
        "native_import_subscription",
        json!({"url":source,"name":"Acceptance subscription","interval":1440,"auto_update":true,"with_proxy":false}),
    )
    .await?;
    let uid = imported["uid"].as_str().context("imported subscription identity")?;
    ensure!(
        Config::profiles().await.data_arc().current == previous,
        "import unexpectedly selected the subscription"
    );
    command("native_activate_profile", json!({"uid":uid})).await?;
    wait_revision(uid, socket, 0).await?;
    let persisted: crate::config::IProfiles =
        serde_yaml_ng::from_str(&std::fs::read_to_string(data.join("profiles.yaml"))?)?;
    ensure!(persisted.current.as_deref() == Some(uid), "activation not persisted");

    control(source, 1).await?;
    command("native_update_subscription", json!({"uid":uid})).await?;
    wait_revision(uid, socket, 1).await?;

    control(source, 2).await?;
    let overdue = (chrono::Utc::now().timestamp() - 1440 * 60 - 5) as usize;
    crate::cmd::patch_profile(
        uid.to_owned(),
        crate::cmd::ProfilePatch {
            updated: Some(overdue),
            ..Default::default()
        },
    )
    .await
    .map_err(command_error)?;
    Timer::global().init().await?;
    wait_revision(uid, socket, 2).await?;
    let details = command("native_subscription_details", json!({"uid":uid})).await?;
    ensure!(
        details["autoUpdate"] == true
            && details["nextUpdate"]
                .as_i64()
                .is_some_and(|v| v > chrono::Utc::now().timestamp()),
        "next update was not reported"
    );

    patch(uid, false).await?;
    let before = control(source, 3).await?["downloads"]
        .as_u64()
        .context("download counter")?;
    crate::feat::update_profile(&uid.into(), None, false).await?;
    tokio::time::sleep(Duration::from_millis(300)).await;
    ensure!(
        control(source, 3).await?["downloads"] == before,
        "disabled subscription downloaded automatically"
    );
    ensure!(
        !crate::cmd::read_profile_file(uid.to_owned())
            .await
            .map_err(command_error)?
            .contains("revision-3"),
        "disabled update changed the subscription"
    );
    ensure!(
        command("native_subscription_details", json!({"uid":uid})).await?["nextUpdate"].is_null(),
        "disabled subscription still has a scheduled update"
    );

    crate::cmd::patch_profile(
        uid.to_owned(),
        crate::cmd::ProfilePatch {
            updated: Some(overdue),
            ..Default::default()
        },
    )
    .await
    .map_err(command_error)?;
    patch(uid, true).await?;
    wait_revision(uid, socket, 3).await?;
    Timer::global().drain().await?;
    let final_state = control(source, 3).await?;
    ensure!(
        final_state["downloads"] == 4,
        "unexpected duplicate subscription downloads"
    );
    let first = command("native_create_local_backup", json!({})).await?;
    let second = command("native_create_local_backup", json!({})).await?;
    let first_name = first["filename"].as_str().context("first backup filename")?;
    let second_name = second["filename"].as_str().context("second backup filename")?;
    ensure!(first_name != second_name, "consecutive backups have the same name");
    let listed = command("native_list_local_backups", json!({})).await?;
    let entries = listed["backups"].as_array().context("backup list")?;
    ensure!(
        entries.len() == 2 && entries.iter().all(|entry| entry.get("path").is_none()),
        "backup list was incomplete or exposed paths"
    );
    let backup_path = data.join("tez-backup").join(first_name);
    let mut archive = zip::ZipArchive::new(std::fs::File::open(backup_path)?)?;
    ensure!(
        archive.by_name("profiles.yaml").is_ok(),
        "backup is missing profile metadata"
    );
    ensure!(
        command("native_delete_local_backup", json!({"filename":"../profiles.yaml"}))
            .await
            .is_err(),
        "backup path traversal was accepted"
    );
    command("native_delete_local_backup", json!({"filename":first_name})).await?;
    ensure!(
        command("native_list_local_backups", json!({})).await?["backups"]
            .as_array()
            .is_some_and(|entries| entries.len() == 1 && entries[0]["filename"] == second_name),
        "backup deletion changed the wrong archive"
    );
    let backup_source = data.join("tez-backup").join(second_name);
    let original_archive = std::fs::read(&backup_source)?;
    ensure!(
        command(
            "native_export_local_backup",
            json!({"filename":second_name,"destination":backup_source})
        )
        .await
        .is_err(),
        "export accepted its own source as destination"
    );
    ensure!(
        std::fs::read(&backup_source)? == original_archive,
        "same-file export damaged the backup"
    );
    let exported = root.join("exported.zip");
    command(
        "native_export_local_backup",
        json!({"filename":second_name,"destination":exported}),
    )
    .await?;
    ensure!(std::fs::read(&exported)? == original_archive, "exported archive differs from the original");
    let imported = command("native_import_local_backup", json!({"source":exported})).await?;
    let imported_name = imported["filename"].as_str().context("imported backup filename")?;
    ensure!(std::fs::read(data.join("tez-backup").join(imported_name))? == original_archive, "imported archive differs from the original");
    let invalid = root.join("invalid.zip");
    std::fs::write(&invalid, b"not a backup")?;
    let before_invalid = std::fs::read(data.join("profiles.yaml"))?;
    ensure!(
        command("native_import_local_backup", json!({"source":invalid}))
            .await
            .is_err(),
        "invalid archive was imported"
    );
    ensure!(
        std::fs::read(data.join("profiles.yaml"))? == before_invalid,
        "invalid import changed profile metadata"
    );
    let dav_url = reqwest::Url::parse(source)?.join("/dav/")?.to_string();
    command(
        "native_save_webdav_config",
        json!({"url":dav_url,"username":"fixture","password":"fixture-secret"}),
    )
    .await?;
    ensure!(
        !std::fs::read_to_string(data.join("tez.yaml"))?.contains("fixture-secret"),
        "WebDAV password was saved in plain text"
    );
    let config = command("native_get_webdav_config", json!({})).await?;
    ensure!(
        config["passwordConfigured"] == true && config.get("password").is_none(),
        "WebDAV password state is incorrect"
    );
    ensure!(
        command(
            "native_save_webdav_config",
            json!({"url":format!("{dav_url}other/"),"username":"fixture","password":null})
        )
        .await
        .is_err(),
        "changed WebDAV destination reused a password"
    );
    ensure!(
        command("native_get_webdav_config", json!({})).await?["url"] == dav_url,
        "rejected WebDAV edit changed configuration"
    );
    command(
        "native_save_webdav_config",
        json!({"url":dav_url,"username":"fixture","password":null}),
    )
    .await?;
    command(
        "native_save_webdav_config",
        json!({"url":invalid_tls,"username":"fixture","password":"fixture-secret"}),
    )
    .await?;
    ensure!(
        command("native_list_webdav_backups", json!({})).await.is_err(),
        "WebDAV accepted an untrusted TLS certificate"
    );
    command(
        "native_save_webdav_config",
        json!({"url":dav_url,"username":"fixture","password":"fixture-secret"}),
    )
    .await?;
    let remote = command("native_create_webdav_backup", json!({})).await?;
    let remote_name = remote["filename"].as_str().context("remote backup filename")?;
    let remote_list = command("native_list_webdav_backups", json!({})).await?;
    ensure!(
        remote_list["backups"]
            .as_array()
            .is_some_and(|files| files.iter().any(|file| file["filename"] == remote_name)),
        "uploaded WebDAV backup was not listed"
    );
    let alias = reqwest::Url::parse(source)?.join("control?alias=1")?;
    reqwest::Client::builder().no_proxy().build()?.get(alias).send().await?.error_for_status()?;
    let aliases = command("native_list_webdav_backups", json!({})).await?;
    ensure!(aliases["backups"].as_array().is_some_and(|files| files.iter().any(|file| file["filename"] == "backup #?%.zip")), "encoded WebDAV filename was not listed");
    command("native_delete_webdav_backup", json!({"filename":"backup #?%.zip"})).await?;
    ensure!(command("native_list_webdav_backups", json!({})).await?["backups"].as_array().is_some_and(|files| files.iter().any(|file| file["filename"] == remote_name)), "encoded WebDAV deletion removed a different file");
    ensure!(command("native_restore_webdav_backup", json!({"filename":"oversize.zip"})).await.is_err(), "oversized WebDAV archive was accepted");
    ensure!(!std::fs::read_dir(data.join("tez-backup"))?.any(|entry| entry.ok().is_some_and(|entry| entry.file_name().to_string_lossy().starts_with("webdav-restore-"))), "failed download left a staging archive");
    crate::cmd::patch_profile(
        uid.to_owned(),
        crate::cmd::ProfilePatch {
            name: Some("changed before remote restore".into()),
            ..Default::default()
        },
    )
    .await
    .map_err(command_error)?;
    let restored_remote = command("native_restore_webdav_backup", json!({"filename":remote_name})).await?;
    ensure!(
        restored_remote["restored"] == true && restored_remote["requiresRestart"] == true,
        "WebDAV restore did not report its state"
    );
    ensure!(
        Config::profiles().await.data_arc().get_item(uid)?.name.as_deref() == Some("Acceptance subscription"),
        "WebDAV restore did not restore the profile"
    );
    let safety = restored_remote["safetyBackup"].as_str().context("pre-restore backup")?;
    let mut safety_zip = zip::ZipArchive::new(std::fs::File::open(data.join("tez-backup").join(safety))?)?;
    let mut safety_profiles = String::new();
    std::io::Read::read_to_string(&mut safety_zip.by_name("profiles.yaml")?, &mut safety_profiles)?;
    ensure!(
        safety_profiles.contains("changed before remote restore"),
        "pre-restore backup did not capture the previous state"
    );
    command("native_delete_webdav_backup", json!({"filename":remote_name})).await?;
    crate::cmd::patch_profile(
        uid.to_owned(),
        crate::cmd::ProfilePatch {
            name: Some("changed before local restore".into()),
            ..Default::default()
        },
    )
    .await
    .map_err(command_error)?;
    let restored_local = command("native_restore_local_backup", json!({"filename":second_name})).await?;
    ensure!(
        restored_local["restored"] == true && restored_local["requiresRestart"] == true,
        "local restore did not report its state"
    );
    ensure!(
        Config::profiles().await.data_arc().get_item(uid)?.name.as_deref() == Some("Acceptance subscription"),
        "local restore did not restore the profile"
    );
    let preserved = command("native_get_webdav_config", json!({})).await?;
    ensure!(
        preserved["passwordConfigured"] == true && preserved["username"] == "fixture",
        "restore lost WebDAV credentials"
    );
    command("native_delete_local_backup", json!({"filename":second_name})).await?;
    ensure!(owned.0.try_wait()?.is_none(), "fixture Core was replaced or stopped");
    std::fs::write(
        root.join("report.json"),
        serde_json::to_vec_pretty(&json!({
            "activation":true,"manualUpdate":true,"defaultScheduler":true,"disabledUpdate":true,"reenabledUpdate":true,
            "downloads":4,"fixtureCorePid":owned.0.id(),"localBackups":true,"backupTransfers":true,"webdav":true,"invalidTlsRejected":true,
            "coverage":"production native workspace, profile transactions, enhancement, Core validator, sidecar reload and default Timer; not service staging or GUI"
        }))?,
    )?;
    drop(owned);
    CoreManager::global().core_stopped();
    Ok(())
}
