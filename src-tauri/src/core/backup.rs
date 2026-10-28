use crate::constants::files::DNS_CONFIG;
use crate::{config::Config, process::AsyncHandler, utils::dirs};
use anyhow::Error;
use arc_swap::{ArcSwap, ArcSwapOption};
use backon::{ConstantBuilder, Retryable as _};
use clash_verge_logging::{Type, logging};
use reqwest_dav::list_cmd::{ListEntity, ListFile, ListMultiStatus};
use smartstring::alias::String;
use std::{
    collections::HashMap,
    env::{consts::OS, temp_dir},
    io::Write as _,
    path::PathBuf,
    sync::{Arc, OnceLock},
    time::Duration,
};
use tokio::{fs, time::timeout};
use zip::write::SimpleFileOptions;

const APP_VERSION: &str = env!("CARGO_PKG_VERSION");

const TIMEOUT_UPLOAD: u64 = 300;
const TIMEOUT_DOWNLOAD: u64 = 300;
const TIMEOUT_LIST: u64 = 30;
const TIMEOUT_DELETE: u64 = 30;

fn webdav_file_path(filename: &str) -> String {
    format!("{}/{}", dirs::BACKUP_DIR, percent_encoding::utf8_percent_encode(filename, percent_encoding::NON_ALPHANUMERIC)).into()
}

#[derive(Clone)]
struct WebDavConfig {
    url: String,
    username: String,
    password: String,
}

#[derive(Debug, Clone, Copy, Hash, Eq, PartialEq)]
enum Operation {
    Upload,
    Download,
    List,
    Delete,
}

impl Operation {
    const fn timeout(&self) -> u64 {
        match self {
            Self::Upload => TIMEOUT_UPLOAD,
            Self::Download => TIMEOUT_DOWNLOAD,
            Self::List => TIMEOUT_LIST,
            Self::Delete => TIMEOUT_DELETE,
        }
    }
}

pub struct WebDavClient {
    config: ArcSwapOption<WebDavConfig>,
    clients: ArcSwap<HashMap<Operation, reqwest_dav::Client>>,
}

impl WebDavClient {
    pub fn global() -> &'static Self {
        static WEBDAV_CLIENT: OnceLock<WebDavClient> = OnceLock::new();
        WEBDAV_CLIENT.get_or_init(|| Self {
            config: ArcSwapOption::new(None),
            clients: ArcSwap::new(Arc::new(HashMap::new())),
        })
    }

    async fn get_client(&self, op: Operation) -> Result<reqwest_dav::Client, Error> {
        {
            let clients_map = self.clients.load();
            if let Some(client) = clients_map.get(&op) {
                return Ok(client.clone());
            }
        }

        let config = {
            let existing_config = self.config.load();

            if let Some(cfg_arc) = existing_config.clone() {
                (*cfg_arc).clone()
            } else {
                let verge = Config::verge().await.data_arc();
                if verge.webdav_url.is_none() || verge.webdav_username.is_none() || verge.webdav_password.is_none() {
                    let msg: String =
                        "Unable to create web dav client, please make sure the webdav config is correct".into();
                    return Err(anyhow::Error::msg(msg));
                }

                let config = WebDavConfig {
                    url: verge
                        .webdav_url
                        .clone()
                        .unwrap_or_default()
                        .trim_end_matches('/')
                        .into(),
                    username: verge.webdav_username.clone().unwrap_or_default(),
                    password: verge.webdav_password.clone().unwrap_or_default(),
                };

                self.config.store(Some(Arc::new(config.clone())));
                config
            }
        };

        let client = reqwest_dav::ClientBuilder::new()
            .set_agent(
                reqwest::Client::builder()
                    .use_rustls_tls()
                    .timeout(Duration::from_secs(op.timeout()))
                    .user_agent(format!("Tez/{APP_VERSION} ({OS} WebDAV-Client)"))
                    .redirect(reqwest::redirect::Policy::custom(|attempt| {
                        if attempt.previous().len() >= 5 {
                            attempt.error("重定向次数过多")
                        } else {
                            attempt.follow()
                        }
                    }))
                    .build()?,
            )
            .set_host(config.url.into())
            .set_auth(reqwest_dav::Auth::Basic(config.username.into(), config.password.into()))
            .build()?;

        // 直接使用 MKCOL；部分服务器的 depth-0 PROPFIND 会误报解码错误。
        if let Err(e) = client.mkcol(dirs::BACKUP_DIR).await {
            let (status_code, message) = match &e {
                reqwest_dav::Error::Decode(reqwest_dav::DecodeError::Server(server_err)) => {
                    (Some(server_err.response_code), Some(server_err.message.as_str()))
                }
                reqwest_dav::Error::Decode(reqwest_dav::DecodeError::StatusMismatched(status_err)) => {
                    (Some(status_err.response_code), None)
                }
                reqwest_dav::Error::Reqwest(http_err) => (http_err.status().map(|s| s.as_u16()), None),
                _ => (None, None),
            };

            // 409 表示父目录不存在，不能按消息启发式处理。
            if status_code == Some(409) {
                logging!(
                    warn,
                    Type::Backup,
                    "Backup directory cannot be created because its parent folder does not exist"
                );
                self.reset();
                return Err(anyhow::Error::msg(
                    "Failed to create backup directory: parent directory does not exist",
                ));
            }

            // 405 是标准的已存在响应；部分服务器只在消息里说明。
            let already_exists = status_code == Some(405)
                || message.is_some_and(|m| {
                    let m = m.to_ascii_lowercase();
                    m.contains("already exist") || m.contains("already taken")
                });

            if already_exists {
                logging!(info, Type::Backup, "Backup directory already exists");
            } else {
                logging!(warn, Type::Backup, "Failed to create backup directory: {}", e);
                self.reset();
                return Err(anyhow::Error::msg(format!("Failed to create backup directory: {}", e)));
            }
        } else {
            logging!(info, Type::Backup, "Successfully created backup directory");
        }

        {
            self.clients.rcu(|clients_map| {
                let mut new_map = (**clients_map).clone();
                new_map.insert(op, client.clone());
                Arc::new(new_map)
            });
        }

        Ok(client)
    }

    pub fn reset(&self) {
        self.config.store(None);
        self.clients.store(Arc::new(HashMap::new()));
    }

    pub async fn upload(&self, file_path: PathBuf, file_name: String) -> Result<(), Error> {
        let client = self.get_client(Operation::Upload).await?;
        let webdav_path = webdav_file_path(&file_name);

        let file_content = fs::read(&file_path).await?;

        let backoff = ConstantBuilder::default()
            .with_delay(Duration::from_millis(500))
            .with_max_times(1);

        (|| async {
            timeout(
                Duration::from_secs(TIMEOUT_UPLOAD),
                client.put(&webdav_path, file_content.clone()),
            )
            .await??;
            Ok::<(), Error>(())
        })
        .retry(backoff)
        .notify(|err, dur| {
            logging!(warn, Type::Backup, "Upload failed: {err}, retrying in {dur:?}");
        })
        .await
    }

    pub async fn download(&self, filename: String, storage_path: PathBuf) -> Result<(), Error> {
        let client = self.get_client(Operation::Download).await?;
        let path = webdav_file_path(&filename);

        let mut created = false;
        let fut = async {
            use tokio::io::AsyncWriteExt as _;
            const MAX_BACKUP_BYTES: u64 = 512 * 1024 * 1024;
            let mut response = client.get(path.as_str()).await?;
            anyhow::ensure!(response.status().is_success(), "WebDAV download failed");
            anyhow::ensure!(response.content_length().is_none_or(|size| size <= MAX_BACKUP_BYTES), "WebDAV backup is too large");
            let mut options = fs::OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            options.mode(0o600);
            let mut file = options.open(&storage_path).await?;
            created = true;
            let mut total = 0u64;
            while let Some(chunk) = response.chunk().await? {
                total = total.saturating_add(chunk.len() as u64);
                anyhow::ensure!(total <= MAX_BACKUP_BYTES, "WebDAV backup is too large");
                file.write_all(&chunk).await?;
            }
            file.flush().await?;
            Ok::<(), Error>(())
        };
        let result = timeout(Duration::from_secs(TIMEOUT_DOWNLOAD), fut).await;
        if created && !matches!(&result, Ok(Ok(()))) {
            let _ = fs::remove_file(&storage_path).await;
        }
        result??;
        Ok(())
    }

    pub async fn list(&self) -> Result<Vec<ListFile>, Error> {
        let client = self.get_client(Operation::List).await?;
        let path = format!("{}/", dirs::BACKUP_DIR);

        let fut = async {
            const MAX_LIST_BYTES: usize = 4 * 1024 * 1024;
            let mut response = client.list_raw(path.as_str(), reqwest_dav::Depth::Number(1)).await?;
            let status = response.status();
            if !status.is_success() {
                return Err(reqwest_dav::Error::Decode(reqwest_dav::DecodeError::StatusMismatched(
                    reqwest_dav::StatusMismatchedError {
                        response_code: status.as_u16(),
                        expected_code: 207,
                    },
                )).into());
            }
            anyhow::ensure!(response.content_length().is_none_or(|size| size <= MAX_LIST_BYTES as u64), "WebDAV listing is too large");
            let mut xml = Vec::new();
            while let Some(chunk) = response.chunk().await? {
                anyhow::ensure!(xml.len().saturating_add(chunk.len()) <= MAX_LIST_BYTES, "WebDAV listing is too large");
                xml.extend_from_slice(&chunk);
            }
            let files = parse_webdav_list(std::str::from_utf8(&xml)?)?;
            let mut final_files = Vec::new();
            for file in files {
                if let ListEntity::File(file) = file {
                    final_files.push(file);
                }
            }
            Ok::<Vec<ListFile>, Error>(final_files)
        };

        Ok(timeout(Duration::from_secs(TIMEOUT_LIST), fut).await??)
    }

    pub async fn delete(&self, file_name: String) -> Result<(), Error> {
        let client = self.get_client(Operation::Delete).await?;
        let path = webdav_file_path(&file_name);

        let fut = client.delete(&path);
        timeout(Duration::from_secs(TIMEOUT_DELETE), fut).await??;
        Ok(())
    }
}

fn parse_webdav_list(xml: &str) -> Result<Vec<ListEntity>, reqwest_dav::Error> {
    // Some WebDAV servers emit RFC 2822's numeric UTC offset instead of HTTP-date's `GMT`.
    let normalized_xml = xml.replace(" +0000</", " GMT</");
    let multi_status: ListMultiStatus = reqwest_dav::re_exports::serde_xml_rs::from_str(&normalized_xml)?;
    multi_status.responses.into_iter().map(ListEntity::try_from).collect()
}

pub async fn create_backup() -> Result<(String, PathBuf), Error> {
    let now = chrono::Local::now().format("%Y-%m-%d_%H-%M-%S").to_string();
    let zip_file_name: String = format!("{OS}-backup-{now}.zip").into();
    let zip_path = temp_dir().join(format!("{}-{zip_file_name}", nanoid::nanoid!()));
    let value = zip_path.clone();
    let file = AsyncHandler::spawn_blocking(move || {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt as _;
            options.mode(0o600);
        }
        options.open(&value)
    }).await??;
    let cleanup = scopeguard::guard(zip_path.clone(), |path| { let _ = std::fs::remove_file(path); });
    let mut zip = zip::ZipWriter::new(file);
    zip.add_directory("profiles/", SimpleFileOptions::default())?;
    let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);

    if let Ok(mut entries) = fs::read_dir(dirs::app_profiles_dir()?).await {
        while let Some(entry) = entries.next_entry().await? {
            let path = entry.path();
            if path.is_file() {
                let file_name_os = entry.file_name();
                let file_name = file_name_os
                    .to_str()
                    .ok_or_else(|| anyhow::Error::msg("Invalid file name encoding"))?;
                let backup_path = format!("profiles/{}", file_name);
                zip.start_file(backup_path, options)?;
                let file_content = fs::read(&path).await?;
                zip.write_all(&file_content)?;
            }
        }
    }
    zip.start_file(dirs::CLASH_CONFIG, options)?;
    zip.write_all(fs::read(dirs::clash_path()?).await?.as_slice())?;

    let verge_text = fs::read_to_string(dirs::verge_path()?).await?;
    let mut verge_config: serde_json::Value = serde_yaml_ng::from_str(&verge_text)?;
    if let Some(obj) = verge_config.as_object_mut() {
        obj.remove("webdav_username");
        obj.remove("webdav_password");
        obj.remove("webdav_url");
    }
    zip.start_file(dirs::VERGE_CONFIG, options)?;
    zip.write_all(serde_yaml_ng::to_string(&verge_config)?.as_bytes())?;

    let dns_config_path = dirs::app_home_dir()?.join(DNS_CONFIG);
    if dns_config_path.exists() {
        zip.start_file(DNS_CONFIG, options)?;
        zip.write_all(fs::read(&dns_config_path).await?.as_slice())?;
    }

    zip.start_file(dirs::PROFILE_YAML, options)?;
    zip.write_all(fs::read(dirs::profiles_path()?).await?.as_slice())?;
    zip.finish()?;
    Ok((zip_file_name, scopeguard::ScopeGuard::into_inner(cleanup)))
}
