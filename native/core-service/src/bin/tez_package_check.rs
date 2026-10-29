//! Explicit acceptance-channel driver; never connects to the production service.
use anyhow::{Context as _, Result, ensure};
use clash_verge_service_ipc::*;
use std::{
    io::Read as _,
    os::unix::fs::{DirBuilderExt as _, MetadataExt as _},
    path::{Path, PathBuf},
};

const FIXTURE: &str = "mode: rule\nport: 0\nsocks-port: 0\nredir-port: 0\ntproxy-port: 0\nmixed-port: 0\nallow-lan: false\nipv6: false\nlog-level: info\nexternal-controller: ''\ngeo-auto-update: false\nprofile: {store-selected: false, store-fake-ip: false}\ndns: {enable: false}\ntun: {enable: false}\nproxies: []\nproxy-groups:\n  - name: Fixture\n    type: select\n    proxies: [DIRECT, REJECT]\nrules: ['MATCH,Fixture']\n";

fn root(value: &std::ffi::OsStr) -> Result<PathBuf> {
    ensure!(CHANNEL_IDENTITY.id == "acceptance", "Acceptance build required");
    let root = PathBuf::from(value);
    ensure!(
        root.parent() == Some(Path::new("/private/tmp"))
            && root.file_name().and_then(|name| name.to_str()).is_some_and(|name| {
                name.strip_prefix("tez-package-acceptance-").is_some_and(|suffix| {
                    suffix.len() >= 12
                        && suffix.len() <= 32
                        && suffix.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
                })
            }),
        "Refusing nonacceptance root"
    );
    Ok(root)
}

fn data(root: &Path) -> PathBuf {
    root.join("home/Library/Application Support/app.tez.client.dev")
}

fn credentials(root: &Path) -> Result<OwnerCredentials> {
    let metadata = std::fs::symlink_metadata(root)?;
    ensure!(
        metadata.is_dir() && metadata.uid() == unsafe { platform_lib::geteuid() } && root.canonicalize()? == root,
        "Private acceptance root required"
    );
    Ok(OwnerCredentials {
        identity: OwnerIdentity::Unix {
            uid: unsafe { platform_lib::geteuid() },
            gid: unsafe { platform_lib::getegid() },
        },
        app_data_dir: data(root).canonicalize()?.to_string_lossy().into_owned(),
        token: None,
    })
}

fn prepare(root: &Path, bundle: &Path) -> Result<()> {
    ensure!(!root.exists(), "Acceptance root must be new");
    ensure!(
        bundle.is_absolute() && bundle.extension().is_some_and(|value| value == "app"),
        "Application bundle required"
    );
    std::fs::DirBuilder::new().mode(0o700).create(root)?;
    std::fs::create_dir_all(data(root).join("profiles"))?;
    std::fs::write(
        data(root).join("profiles/fixture.yaml"),
        "proxies: []\nproxy-groups:\n  - name: Fixture\n    type: select\n    proxies: [DIRECT, REJECT]\nrules: ['MATCH,Fixture']\n",
    )?;
    std::fs::write(
        data(root).join("profiles.yaml"),
        "current: fixture\nitems:\n  - uid: fixture\n    name: Package acceptance\n    type: local\n    file: fixture.yaml\n",
    )?;
    std::fs::write(data(root).join("config.yaml"), FIXTURE)?;
    std::fs::write(
        data(root).join("tez.yaml"),
        "enable_system_proxy: false\nenable_proxy_guard: false\nenable_tun_mode: false\nenable_builtin_enhanced: false\nenable_external_controller: false\n",
    )?;
    ensure!(
        bundle.parent().context("Bundle parent required")?.canonicalize()? == bundle.parent().unwrap(),
        "Canonical bundle parent required"
    );
    std::fs::write(root.join("bundle.txt"), bundle.to_string_lossy().as_bytes())?;
    println!("Prepared private acceptance HOME; no service or core started");
    Ok(())
}

async fn status(credentials: &OwnerCredentials) -> Result<ServiceStatusSnapshot> {
    let response = get_status(credentials).await?;
    ensure!(response.code == 0, "Service status rejected: {}", response.message);
    response.data.context("Missing service status")
}

async fn execute(mode: &str, root: &Path) -> Result<()> {
    let credentials = credentials(root)?;
    let bundle = PathBuf::from(std::fs::read_to_string(root.join("bundle.txt"))?);
    if mode == "--install" {
        ensure!(
            status(&credentials).await.is_err(),
            "Refusing to replace an existing acceptance service"
        );
        let helpers = bundle.join("Contents/Helpers");
        let cores = ["mihomo", "mihomo-alpha"].map(|name| management::CoreSource {
            name: name.into(),
            path: helpers.join(name),
        });
        management::install(
            &helpers.join("tez-service-install"),
            &cores,
            false,
            Some(unsafe { platform_lib::getegid() }),
            "Install the isolated Tez acceptance service only. The current proxy is unchanged.",
        )?;
        println!("Installed isolated app.tez.acceptance.service");
        return Ok(());
    }
    let current = status(&credentials).await?;
    if mode == "--uninstall" {
        ensure!(
            !current.is_active && current.core_pid.is_none() && current.active_generation.is_none(),
            "Stop the isolated fixture before uninstalling"
        );
        let tool = root.join("uninstall-tool");
        std::fs::copy(bundle.join("Contents/Helpers/tez-service-uninstall"), &tool)?;
        let command = format!(
            "cd /; '{}' && /bin/rm -rf '/Library/Application Support/tez-acceptance-service' '/var/run/tez-acceptance-service' '/private/tmp/tez-acceptance-service.core-execution.lock'",
            tool.display()
        );
        let script = "on run argv\ndo shell script (item 1 of argv) with administrator privileges with prompt (item 2 of argv)\nend run";
        let result = std::process::Command::new("osascript")
            .args([
                "-e",
                script,
                &command,
                "Remove the isolated Tez acceptance service only. The current proxy is unchanged.",
            ])
            .status()?;
        ensure!(result.success(), "Isolated service cleanup was not authorized");
        ensure!(
            status(&credentials).await.is_err(),
            "Acceptance service is still reachable"
        );
        println!("Removed isolated service, state, runtime and execution lock");
        return Ok(());
    }
    if mode == "--seed" {
        ensure!(
            !current.is_active
                && current.core_pid.is_none()
                && current.active_generation.is_none()
                && !current.desired_core_should_be_running,
            "Acceptance service must be idle"
        );
        let mut random = [0u8; 32];
        std::fs::File::open("/dev/urandom")?.read_exact(&mut random)?;
        let token: String = random.iter().map(|byte| format!("{byte:02x}")).collect();
        save_owner_session(&credentials, &token, None)?;
        let response = start_idle_core(
            &credentials,
            &StartClashRequest {
                runtime: RuntimeBundle {
                    yaml: FIXTURE.into(),
                    assets: vec![],
                    remote_providers: vec![],
                    core_path: service_paths()?
                        .core_dir()
                        .join("mihomo")
                        .to_string_lossy()
                        .into_owned(),
                },
                proposed_session_token: token.clone(),
                macos_proxy: None,
            },
        )
        .await?;
        ensure!(response.code == 0, "Fixture start rejected: {}", response.message);
        let generation = response.data.context("Missing fixture session")?.session.generation;
        save_owner_session(&credentials, &token, Some(generation))?;
        let current = status(&credentials).await?;
        std::fs::write(
            root.join("seed.json"),
            serde_json::to_vec(
                &serde_json::json!({"pid":current.core_pid,"generation":generation,"startedAt":current.core_started_at}),
            )?,
        )?;
    } else if mode == "--stop" {
        if let Some(generation) = current.active_generation {
            let proof = load_owner_session(&credentials, generation)?.context("No authenticated fixture receipt")?;
            let response = stop_clash(&credentials, &proof).await?;
            ensure!(response.code == 0, "Fixture stop rejected: {}", response.message);
            forget_owner_session(&credentials)?;
        }
    } else {
        ensure!(mode == "--status", "Unknown command");
    }
    let current = status(&credentials).await?;
    println!(
        "{}",
        serde_json::json!({"channel":CHANNEL_IDENTITY.id,"pid":current.core_pid,"generation":current.active_generation,"startedAt":current.core_started_at,"active":current.is_active})
    );
    Ok(())
}

#[tokio::main(flavor = "multi_thread")]
async fn main() -> Result<()> {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    ensure!(
        !cfg!(feature = "test"),
        "Use the real acceptance-channel build, not a mock/test build"
    );
    ensure!(
        args.len() == 2 || args.len() == 3,
        "Usage: tez-package-check --prepare ROOT APP | (--install|--seed|--status|--stop|--uninstall) ROOT"
    );
    let root = root(&args[1])?;
    if args[0] == "--prepare" {
        ensure!(args.len() == 3, "Bundle required");
        prepare(&root, Path::new(&args[2]))
    } else {
        ensure!(args.len() == 2, "Unexpected arguments");
        execute(args[0].to_str().context("Invalid command")?, &root).await
    }
}
