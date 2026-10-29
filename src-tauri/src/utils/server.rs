use super::resolve;
use crate::{
    config::{Config, DEFAULT_PAC, MixedPort},
    core::lightweight,
    process::AsyncHandler,
    utils::{dirs, window_manager::WindowManager},
};
use anyhow::{Context as _, Result, bail};
use clash_verge_logging::{Type, logging};
use parking_lot::Mutex;
use reqwest::ClientBuilder;
use serde::{Deserialize, Serialize};
use std::io::{Read as _, Write as _};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;
use tokio::sync::oneshot;
use warp::Filter as _;

const INSTANCE_TOKEN_HEADER: &str = "x-instance-token";
pub(crate) const INSTANCE_RECORD_FILE: &str = "singleton-instance.json";
pub(crate) const INSTANCE_LOCK_FILE: &str = "singleton-instance.lock";

#[derive(Deserialize, Debug)]
struct QueryParam {
    param: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct InstanceRecord {
    port: u16,
    token: String,
}

static SHUTDOWN_SENDER: OnceLock<Mutex<Option<oneshot::Sender<()>>>> = OnceLock::new();
static EMBEDDED_PORT: OnceLock<u16> = OnceLock::new();
static INSTANCE_LOCK: OnceLock<std::fs::File> = OnceLock::new();
const PAC_INITIAL_AVAILABLE: bool = false;
static PAC_AVAILABLE: AtomicBool = AtomicBool::new(PAC_INITIAL_AVAILABLE);
static COMMANDS_READY: AtomicBool = AtomicBool::new(false);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SingletonDisposition {
    Primary,
    Secondary,
}

pub async fn check_singleton() -> Result<SingletonDisposition> {
    let record_path = instance_record_path().context("failed to resolve singleton instance record path")?;
    let lock = open_instance_lock(&record_path.with_file_name(INSTANCE_LOCK_FILE))
        .context("failed to initialize singleton lock")?;
    if !try_lock_instance(&lock).context("failed to acquire singleton lock")? {
        let deadline = std::time::Instant::now() + Duration::from_secs(20);
        use crate::utils::retry::{RetryError, RetryPolicy, retry};
        let secondary = retry(
            RetryPolicy::fixed(
                std::num::NonZeroUsize::MIN.saturating_add(400),
                Duration::from_millis(50),
            ),
            |_| async {
                if std::time::Instant::now() >= deadline {
                    return Err(RetryError::Stop(anyhow::anyhow!("another app instance is starting")));
                }
                // A restarting primary releases the lock after spawning us, with its server down.
                if try_lock_instance(&lock)
                    .context("failed to acquire singleton lock")
                    .map_err(RetryError::Stop)?
                {
                    return Ok(false);
                }
                if let Ok(record) = read_instance_record(&record_path)
                    && notify_existing_instance(&record).await
                {
                    return Ok(true);
                }
                Err(RetryError::Retry(anyhow::anyhow!("another app instance is starting")))
            },
        )
        .await?;
        if secondary {
            return Ok(SingletonDisposition::Secondary);
        }
    }

    let preferred = read_instance_record(&record_path).ok().map(|record| record.port);
    let listener = bind_primary_listener(preferred)
        .await
        .context("failed to reserve embedded server port")?;
    let port = listener
        .local_addr()
        .context("failed to read embedded server address")?
        .port();
    let record = InstanceRecord {
        port,
        token: random_token().context("failed to generate singleton instance token")?,
    };
    write_instance_record(&record_path, &record).context("failed to persist singleton instance record")?;
    INSTANCE_LOCK
        .set(lock)
        .map_err(|_| anyhow::anyhow!("singleton lock is already initialized"))?;
    let _ = EMBEDDED_PORT.set(port);
    start_embedded_server(listener, record.token);
    Ok(SingletonDisposition::Primary)
}

async fn bind_primary_listener(preferred: Option<u16>) -> Result<tokio::net::TcpListener> {
    let preferred_port = preferred.unwrap_or(0);
    match tokio::net::TcpListener::bind(std::net::SocketAddrV4::new(
        std::net::Ipv4Addr::LOCALHOST,
        preferred_port,
    ))
    .await
    {
        Ok(listener) => Ok(listener),
        Err(_) if preferred.is_some() => {
            Ok(tokio::net::TcpListener::bind(std::net::SocketAddrV4::new(std::net::Ipv4Addr::LOCALHOST, 0)).await?)
        }
        Err(error) => Err(error.into()),
    }
}

async fn notify_existing_instance(record: &InstanceRecord) -> bool {
    let client = match ClientBuilder::new().timeout(Duration::from_millis(500)).build() {
        Ok(client) => client,
        Err(_) => return false,
    };
    #[cfg(not(target_os = "macos"))]
    let request = if let Some(arg) = std::env::args().nth(1).as_deref() {
        if arg.starts_with("tez:") {
            client
                .get(format!("http://127.0.0.1:{}/commands/scheme", record.port))
                .query(&[("param", arg)])
        } else {
            client.get(format!("http://127.0.0.1:{}/commands/visible", record.port))
        }
    } else {
        client.get(format!("http://127.0.0.1:{}/commands/visible", record.port))
    };
    #[cfg(target_os = "macos")]
    let request = client.get(format!("http://127.0.0.1:{}/commands/visible", record.port));

    request
        .header(INSTANCE_TOKEN_HEADER, &record.token)
        .send()
        .await
        .is_ok_and(|response| response.status().is_success())
}

fn instance_auth(token: String) -> impl warp::Filter<Extract = (), Error = warp::Rejection> + Clone {
    warp::header::optional::<String>(INSTANCE_TOKEN_HEADER)
        .and_then(move |provided: Option<String>| {
            let token = token.clone();
            async move {
                if provided.as_deref() == Some(token.as_str()) {
                    Ok::<(), warp::Rejection>(())
                } else {
                    Err(warp::reject())
                }
            }
        })
        .untuple_one()
}

fn pac_route() -> impl warp::Filter<Extract = (warp::http::Response<String>,), Error = warp::Rejection> + Clone {
    warp::path!("commands" / "pac").and_then(|| async move {
        if !PAC_AVAILABLE.load(Ordering::Acquire) {
            return Ok::<_, warp::Rejection>(
                warp::http::Response::builder()
                    .status(warp::http::StatusCode::SERVICE_UNAVAILABLE)
                    .body("PAC endpoint is inactive".to_string())
                    .unwrap_or_default(),
            );
        }
        let verge_config = Config::verge().await;
        let verge_data = verge_config.data_arc();
        let pac_content = verge_data.pac_file_content.as_deref().unwrap_or(DEFAULT_PAC);
        // Port changes disable PAC, so the draft port avoids per-request Core queries.
        let pac_port = MixedPort::desired().await;
        let processed_content = pac_content.replace("%mixed-port%", &format!("{pac_port}"));
        Ok::<_, warp::Rejection>(
            warp::http::Response::builder()
                .header("Content-Type", "application/x-ns-proxy-autoconfig")
                .body(processed_content)
                .unwrap_or_default(),
        )
    })
}

#[cfg(all(feature = "native-host", target_os = "macos"))]
pub(crate) struct NativePacServer {
    shutdown: Option<oneshot::Sender<()>>,
    task: tokio::task::JoinHandle<()>,
}

#[cfg(all(feature = "native-host", target_os = "macos"))]
impl NativePacServer {
    pub(crate) async fn shutdown(mut self) -> Result<()> {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        self.task.await.context("native PAC server shutdown failed")?;
        Ok(())
    }
}

#[cfg(all(feature = "native-host", target_os = "macos"))]
pub(crate) async fn start_native_pac_server() -> Result<NativePacServer> {
    let record_path = instance_record_path()?;
    let preferred = read_instance_record(&record_path).ok().map(|record| record.port);
    let listener = bind_primary_listener(preferred).await.context("failed to reserve native PAC server port")?;
    let port = listener.local_addr()?.port();
    anyhow::ensure!(preferred.is_none_or(|previous| previous == port), "previous PAC listener port is unavailable; the saved PAC URL was not replaced");
    EMBEDDED_PORT
        .set(port)
        .map_err(|_| anyhow::anyhow!("native PAC server port is already initialized"))?;
    write_instance_record(&record_path, &InstanceRecord { port, token: random_token()? })?;
    let (shutdown, stopped) = oneshot::channel();
    let task = tokio::spawn(async move {
        warp::serve(warp::get().and(pac_route()))
            .incoming(listener)
            .graceful(async { let _ = stopped.await; })
            .run()
            .await;
    });
    Ok(NativePacServer { shutdown: Some(shutdown), task })
}

fn start_embedded_server(listener: tokio::net::TcpListener, token: String) {
    let (shutdown_tx, shutdown_rx) = oneshot::channel();
    let _ = SHUTDOWN_SENDER.set(Mutex::new(Some(shutdown_tx)));

    #[cfg(feature = "verge-dev")]
    let auth = instance_auth(token);
    #[cfg(not(feature = "verge-dev"))]
    let auth = instance_auth(token);

    let visible = warp::path!("commands" / "visible").and_then(|| async {
        if !COMMANDS_READY.load(Ordering::Acquire) {
            return Ok::<_, warp::Rejection>(warp::reply::with_status(
                "starting".to_string(),
                warp::http::StatusCode::SERVICE_UNAVAILABLE,
            ));
        }
        // Keep blocking UI calls off HTTP workers.
        AsyncHandler::spawn_blocking(|| {
            AsyncHandler::block_on(async {
                logging!(
                    info,
                    Type::Window,
                    "Restoring the application window from a secondary instance"
                );
                if crate::APP_HANDLE.get().is_some() && !lightweight::exit_lightweight_mode().await {
                    WindowManager::show_main_window().await;
                }
            });
        });
        Ok(warp::reply::with_status("ok".to_string(), warp::http::StatusCode::OK))
    });

    let pac = pac_route();

    let scheme = warp::path!("commands" / "scheme")
        .and(warp::query::<QueryParam>())
        .and_then(|query: QueryParam| async move {
            if !COMMANDS_READY.load(Ordering::Acquire) {
                return Ok::<_, warp::Rejection>(warp::reply::with_status(
                    "starting".to_string(),
                    warp::http::StatusCode::SERVICE_UNAVAILABLE,
                ));
            }
            AsyncHandler::spawn(|| async move {
                resolve::resolve_scheme(&query.param).await;
            });
            Ok::<_, warp::Rejection>(warp::reply::with_status("ok".to_string(), warp::http::StatusCode::OK))
        });

    let commands = auth.clone().and(visible).or(auth.and(scheme)).or(pac);
    AsyncHandler::spawn(move || async move {
        warp::serve(commands)
            .incoming(listener)
            .graceful(async {
                shutdown_rx.await.ok();
            })
            .run()
            .await;
    });
}

pub fn set_pac_available(available: bool) {
    PAC_AVAILABLE.store(available, Ordering::Release);
}

pub fn set_commands_ready() {
    COMMANDS_READY.store(true, Ordering::Release);
}

pub fn embed_server() {
    if EMBEDDED_PORT.get().is_none() {
        logging!(
            error,
            Type::Window,
            "embedded server was not reserved during singleton check"
        );
    }
}

pub fn embedded_server_port() -> Result<u16> {
    EMBEDDED_PORT
        .get()
        .copied()
        .context("embedded server port is not initialized")
}

pub fn shutdown_embedded_server() {
    logging!(info, Type::Window, "shutting down embedded server");
    if let Some(sender) = SHUTDOWN_SENDER.get()
        && let Some(sender) = sender.lock().take()
    {
        sender.send(()).ok();
    }
}

fn instance_record_path() -> Result<PathBuf> {
    Ok(dirs::preinit_app_data_dir()?.join(INSTANCE_RECORD_FILE))
}

fn open_instance_lock(path: &Path) -> Result<std::fs::File> {
    let parent = path.parent().context("singleton lock has no parent")?;
    std::fs::create_dir_all(parent)?;
    #[cfg(windows)]
    {
        crate::core::owner_identity::open_or_create_current_user_lock(path)
    }

    #[cfg(unix)]
    {
        let mut options = std::fs::OpenOptions::new();
        options.read(true).write(true).create(true);

        use std::os::unix::fs::OpenOptionsExt as _;
        use std::os::unix::fs::PermissionsExt as _;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);

        let file = options.open(path)?;
        let metadata = file.metadata()?;
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            bail!("singleton lock is not an ordinary file");
        }
        file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
        Ok(file)
    }
}

#[cfg(feature = "native-host")]
pub(crate) fn try_acquire_native_instance_lock() -> Result<std::fs::File> {
    let path = dirs::app_home_dir()?.join(INSTANCE_LOCK_FILE);
    let file = open_instance_lock(&path)?;
    if !try_lock_instance(&file)? {
        bail!("another client owns the backend");
    }
    Ok(file)
}

fn try_lock_instance(file: &std::fs::File) -> Result<bool> {
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd as _;
        let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        if result == 0 {
            return Ok(true);
        }
        let error = std::io::Error::last_os_error();
        if error
            .raw_os_error()
            .is_some_and(|code| code == libc::EWOULDBLOCK || code == libc::EAGAIN)
        {
            return Ok(false);
        }
        Err(error).context("failed to lock singleton file")
    }

    #[cfg(windows)]
    {
        use std::os::windows::io::AsRawHandle as _;
        use windows_sys::Win32::Foundation::{ERROR_LOCK_VIOLATION, GetLastError};
        use windows_sys::Win32::Storage::FileSystem::LockFile;
        let locked = unsafe { LockFile(file.as_raw_handle(), 0, 0, u32::MAX, u32::MAX) };
        if locked != 0 {
            return Ok(true);
        }
        if unsafe { GetLastError() } == ERROR_LOCK_VIOLATION {
            return Ok(false);
        }
        Err(std::io::Error::last_os_error()).context("failed to lock singleton file")
    }
}

fn random_token() -> Result<String> {
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes)?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

fn read_instance_record(path: &Path) -> Result<InstanceRecord> {
    #[cfg(windows)]
    let mut file = crate::core::owner_identity::open_private_current_user_file(path)?;
    #[cfg(unix)]
    let mut file = {
        use std::os::unix::fs::OpenOptionsExt as _;
        let mut options = std::fs::OpenOptions::new();
        options.read(true).custom_flags(libc::O_NOFOLLOW);
        options.open(path)?
    };
    let metadata = file.metadata()?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        bail!("singleton record is not an ordinary file");
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};
        if metadata.uid() != unsafe { libc::geteuid() } || metadata.permissions().mode() & 0o777 != 0o600 {
            bail!("singleton record permissions are invalid");
        }
    }
    let mut content = Vec::new();
    file.read_to_end(&mut content)?;
    Ok(serde_json::from_slice(&content)?)
}

fn write_instance_record(path: &Path, record: &InstanceRecord) -> Result<()> {
    let parent = path.parent().context("singleton record has no parent")?;
    std::fs::create_dir_all(parent)?;
    let temporary = path.with_extension(format!("json.tmp-{}-{}", std::process::id(), &random_token()?[..16]));
    #[cfg(windows)]
    let mut file = crate::core::owner_identity::create_private_current_user_file(&temporary)?;
    #[cfg(unix)]
    let mut file = {
        use std::os::unix::fs::OpenOptionsExt as _;
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        options.mode(0o600);
        options.open(&temporary)?
    };
    file.write_all(&serde_json::to_vec(record)?)?;
    file.sync_all()?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    }
    drop(file);
    std::fs::rename(&temporary, path).context("failed to replace singleton record")?;
    Ok(())
}

#[cfg(all(test, feature = "native-host", target_os = "macos"))]
mod tests {
    use super::*;

    #[test]
    fn native_pac_http_uses_private_config_and_closes() -> Result<()> {
        let home = std::env::temp_dir().join(format!("tez-native-pac-{}", nanoid::nanoid!(8)));
        std::fs::create_dir(&home)?;
        let home = home.canonicalize()?;
        let root = home.join("Library/Application Support").join(dirs::APP_ID);
        std::fs::create_dir_all(&root)?;
        std::fs::write(root.join("config.yaml"), "mixed-port: 17897\n")?;
        std::fs::write(root.join("profiles.yaml"), "current: null\nitems: []\n")?;
        std::fs::write(root.join("tez.yaml"), "verge_mixed_port: 17897\npac_file_content: 'function FindProxyForURL(url, host) { return \"PROXY 127.0.0.1:%mixed-port%\"; }'\n")?;
        let result = (|| -> Result<()> {
            let child = || {
                let mut command = std::process::Command::new(std::env::current_exe().unwrap());
                command.args(["--exact", "utils::server::tests::native_pac_http_child", "--ignored", "--nocapture", "--test-threads=1"])
                    .env("HOME", &home).env("TEZ_PAC_TEST_HOME", &home);
                command
            };
            let mut port = None;
            for _ in 0..2 {
                let mut command = child();
                if let Some(port) = port { command.env("TEZ_PAC_TEST_PORT", format!("{port}")); }
                let result = command.output()?;
                anyhow::ensure!(result.status.success(), "{}\n{}", String::from_utf8_lossy(&result.stdout), String::from_utf8_lossy(&result.stderr));
                let record = read_instance_record(&root.join(INSTANCE_RECORD_FILE)).context("native PAC listener must persist its port for recovery")?;
                if let Some(port) = port { assert_eq!(record.port, port); }
                port = Some(record.port);
            }
            let port = port.unwrap();
            let _occupied = std::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, port))?;
            let result = child().env("TEZ_PAC_TEST_EXPECT_REFUSED", "1").output()?;
            anyhow::ensure!(result.status.success(), "{}\n{}", String::from_utf8_lossy(&result.stdout), String::from_utf8_lossy(&result.stderr));
            assert_eq!(read_instance_record(&root.join(INSTANCE_RECORD_FILE))?.port, port);
            Ok(())
        })();
        std::fs::remove_dir_all(home)?;
        result
    }

    #[tokio::test]
    #[ignore = "run by native_pac_http_uses_private_config_and_closes with a private HOME"]
    async fn native_pac_http_child() -> Result<()> {
        let home = PathBuf::from(std::env::var_os("TEZ_PAC_TEST_HOME").context("private PAC test HOME is required")?);
        anyhow::ensure!(dirs::app_home_dir()?.starts_with(home), "PAC fixture must not read the user's configuration");
        let started = start_native_pac_server().await;
        if std::env::var_os("TEZ_PAC_TEST_EXPECT_REFUSED").is_some() {
            let error = started.err().context("an occupied PAC recovery port must not silently change")?;
            assert!(error.to_string().contains("previous PAC listener port is unavailable"));
            return Ok(());
        }
        let server = started?;
        let port = embedded_server_port()?;
        assert_ne!(port, 0);
        if let Ok(expected) = std::env::var("TEZ_PAC_TEST_PORT") { assert_eq!(port, expected.parse::<u16>()?); }
        let client = ClientBuilder::new().no_proxy().timeout(Duration::from_secs(3)).build()?;
        let base = format!("http://127.0.0.1:{port}");
        assert_eq!(client.get(format!("{base}/commands/pac")).send().await?.status(), 503);
        set_pac_available(true);
        let response = client.get(format!("{base}/commands/pac")).send().await?;
        assert_eq!(response.status(), 200);
        assert_eq!(response.headers()["content-type"], "application/x-ns-proxy-autoconfig");
        assert_eq!(response.text().await?, "function FindProxyForURL(url, host) { return \"PROXY 127.0.0.1:17897\"; }");
        for route in ["visible", "scheme?param=tez://fixture"] {
            assert_eq!(client.get(format!("{base}/commands/{route}")).send().await?.status(), 404);
        }
        set_pac_available(false);
        assert_eq!(client.get(format!("{base}/commands/pac")).send().await?.status(), 503);
        server.shutdown().await?;
        assert!(tokio::net::TcpStream::connect((std::net::Ipv4Addr::LOCALHOST, port)).await.is_err());
        Ok(())
    }
}
