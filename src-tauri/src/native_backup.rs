use crate::{
    cmd::{self, CmdResult, CommandFailure},
    config::{Config, IProfiles, IVerge},
    core::backup::WebDavClient,
    utils::dirs,
};
use anyhow::{Context as _, Result, ensure};
use serde_json::{Value, json};
use std::{
    collections::HashSet,
    io::Read as _,
    path::{Component, Path, PathBuf},
};

const MAX_ARCHIVE_BYTES: u64 = 512 * 1024 * 1024;
const MAX_METADATA_BYTES: u64 = 4 * 1024 * 1024;

fn failure(code: &str, message: impl std::fmt::Display) -> CommandFailure {
    CommandFailure::coded(code, message)
}

pub(crate) fn valid_filename(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 255
        && !name.chars().any(char::is_control)
        && !name.contains('\\')
        && name.to_ascii_lowercase().ends_with(".zip")
        && matches!(
            Path::new(name).components().collect::<Vec<_>>().as_slice(),
            [Component::Normal(_)]
        )
}

pub(crate) fn valid_file_path(path: &str) -> bool {
    path.len() <= 4096
        && !path.chars().any(char::is_control)
        && Path::new(path).is_absolute()
        && Path::new(path)
            .extension()
            .and_then(|v| v.to_str())
            .is_some_and(|v| v.eq_ignore_ascii_case("zip"))
}

fn read_metadata(archive: &mut zip::ZipArchive<std::fs::File>, name: &str) -> Result<String> {
    let entry = archive.by_name(name)?;
    ensure!(entry.size() <= MAX_METADATA_BYTES, "backup metadata is too large");
    let mut text = String::new();
    entry.take(MAX_METADATA_BYTES + 1).read_to_string(&mut text)?;
    ensure!(text.len() as u64 <= MAX_METADATA_BYTES, "backup metadata is too large");
    Ok(text)
}

fn verify_archive(path: &Path) -> Result<()> {
    let file = std::fs::File::open(path)?;
    ensure!(
        file.metadata()?.len() <= MAX_ARCHIVE_BYTES,
        "backup archive is too large"
    );
    let mut archive = zip::ZipArchive::new(file)?;
    ensure!(archive.len() <= 8192, "backup has too many entries");
    let mut names = HashSet::new();
    let mut total = 0u64;
    for index in 0..archive.len() {
        let mut entry = archive.by_index(index)?;
        let path = entry.enclosed_name().context("unsafe backup path")?;
        ensure!(
            entry.unix_mode().is_none_or(|mode| mode & 0o170000 != 0o120000),
            "backup contains a symbolic link"
        );
        let name = path.to_str().context("invalid backup path")?;
        ensure!(
            !name.contains('\\') && !name.chars().any(char::is_control) && names.insert(name.to_owned()),
            "duplicate or invalid backup path"
        );
        let parts: Vec<_> = path.components().collect();
        let allowed = match parts.as_slice() {
            [Component::Normal(root)] => {
                ["config.yaml", "tez.yaml", "profiles.yaml", "dns_config.yaml"]
                    .iter()
                    .any(|v| root == v)
                    || (*root == "profiles" && entry.is_dir())
            }
            [Component::Normal(root), Component::Normal(_)] => *root == "profiles" && !entry.is_dir(),
            _ => false,
        };
        ensure!(allowed, "backup contains an unsupported path");
        total = total.checked_add(entry.size()).context("backup size overflow")?;
        ensure!(total <= MAX_ARCHIVE_BYTES, "backup contents are too large");
        if !entry.is_dir() {
            let expected = entry.size();
            let decoded = std::io::copy(&mut (&mut entry).take(expected.saturating_add(1)), &mut std::io::sink())?;
            ensure!(decoded == expected, "backup entry size mismatch");
        }
    }
    let _: serde_yaml_ng::Mapping = serde_yaml_ng::from_str(&read_metadata(&mut archive, "config.yaml")?)?;
    let _: IVerge = serde_yaml_ng::from_str(&read_metadata(&mut archive, "tez.yaml")?)?;
    let profiles: IProfiles = serde_yaml_ng::from_str(&read_metadata(&mut archive, "profiles.yaml")?)?;
    if let Some(items) = profiles.items {
        for item in items {
            if let Some(file) = item.file {
                ensure!(
                    matches!(
                        Path::new(file.as_str()).components().collect::<Vec<_>>().as_slice(),
                        [Component::Normal(_)]
                    ) && !file.contains('\\'),
                    "invalid profile filename"
                );
                ensure!(
                    names.contains(&format!("profiles/{file}")),
                    "backup is missing a profile file"
                );
            }
        }
    }
    if names.contains("dns_config.yaml") {
        let _: serde_yaml_ng::Mapping = serde_yaml_ng::from_str(&read_metadata(&mut archive, "dns_config.yaml")?)?;
    }
    Ok(())
}

async fn check(path: PathBuf) -> CmdResult<()> {
    tokio::task::spawn_blocking(move || verify_archive(&path))
        .await
        .map_err(|_| failure("BACKUP_INVALID", "Backup inspection failed"))?
        .map_err(|error| failure("BACKUP_INVALID", format!("Invalid backup: {error:#}")))
}

pub(crate) async fn import(source: String) -> CmdResult<Value> {
    check(PathBuf::from(&source)).await?;
    let filename = cmd::import_local_backup(source).await?;
    Ok(json!({"filename":filename}))
}

pub(crate) async fn export(filename: String, destination: String) -> CmdResult<Value> {
    let source = dirs::local_backup_dir()
        .map_err(|_| failure("BACKUP_EXPORT_FAILED", "Backup directory unavailable"))?
        .join(&filename);
    if let (Ok(a), Ok(b)) = (source.canonicalize(), Path::new(&destination).canonicalize()) {
        if a == b {
            return Err(failure(
                "BACKUP_EXPORT_FAILED",
                "Source and destination are the same file",
            ));
        }
    }
    cmd::export_local_backup(filename, destination).await?;
    Ok(json!({"exported":true}))
}

fn restore_failure(mut error: CommandFailure, safety: &str) -> CommandFailure {
    error.detail = format!("Restore failed; pre-restore backup: {safety}; {}", error.detail);
    if error.code.is_none() {
        error.code = Some("BACKUP_RESTORE_FAILED".to_owned());
    }
    error
}

pub(crate) async fn restore(filename: String) -> CmdResult<Value> {
    let source = dirs::local_backup_dir()
        .map_err(|_| failure("BACKUP_RESTORE_FAILED", "Backup directory unavailable"))?
        .join(&filename);
    check(source).await?;
    let safety = {
        let _profile = crate::config::profiles::PROFILE_WRITE_LOCK.lock().await;
        let _config = Config::lock_config_write().await;
        crate::feat::create_local_backup_with_namer(|name| {
            format!(
                "pre-restore-{}-{}.zip",
                name.trim_end_matches(".zip"),
                nanoid::nanoid!(8)
            )
            .into()
        })
        .await
        .map_err(|_| failure("BACKUP_RESTORE_FAILED", "Could not create the pre-restore backup"))?
    };
    cmd::restore_local_backup(filename)
        .await
        .map_err(|error| restore_failure(error, safety.as_str()))?;
    Ok(json!({"restored":true,"safetyBackup":safety,"requiresRestart":true}))
}

pub(crate) async fn webdav_config() -> Value {
    let config = Config::verge().await.data_arc();
    json!({"url":config.webdav_url,"username":config.webdav_username,"passwordConfigured":config.webdav_password.as_ref().is_some_and(|v| !v.is_empty())})
}

pub(crate) async fn save_webdav(url: String, username: String, password: Option<String>) -> CmdResult<Value> {
    let _write = Config::lock_config_write().await;
    Config::verge()
        .await
        .with_data_modify(|mut verge| async move {
            if password.is_none()
                && (verge.webdav_url.as_deref() != Some(url.as_str())
                    || verge.webdav_username.as_deref() != Some(username.as_str()))
            {
                anyhow::bail!("WebDAV destination changed; enter the password again");
            }
            let password = password
                .map(Into::into)
                .or(verge.webdav_password.clone())
                .filter(|v: &smartstring::alias::String| !v.is_empty())
                .ok_or_else(|| anyhow::anyhow!("WebDAV password is required"))?;
            verge.webdav_url = Some(url.into());
            verge.webdav_username = Some(username.into());
            verge.webdav_password = Some(password);
            verge.save_file().await?;
            Ok((verge, ()))
        })
        .await
        .map_err(|_| failure("WEBDAV_CONFIG_FAILED", "Could not save WebDAV configuration"))?;
    WebDavClient::global().reset();
    Ok(json!({"saved":true}))
}

fn remote_filename(href: &str) -> Option<String> {
    let path = reqwest::Url::parse(href)
        .ok()
        .map(|url| url.path().to_owned())
        .unwrap_or_else(|| href.split('?').next().unwrap_or("").to_owned());
    let name = percent_encoding::percent_decode_str(path.rsplit('/').next()?)
        .decode_utf8()
        .ok()?
        .into_owned();
    valid_filename(&name).then_some(name)
}

pub(crate) async fn webdav_list() -> CmdResult<Value> {
    let files = cmd::list_webdav_backup()
        .await
        .map_err(|_| failure("WEBDAV_FAILED", "Could not list WebDAV backups"))?;
    let mut seen = HashSet::new();
    let mut backups = Vec::new();
    for item in files {
        if let Some(name) = remote_filename(&item.href)
            && seen.insert(name.clone())
        {
            if backups.len() == 2000 {
                return Err(failure("WEBDAV_FAILED", "Too many WebDAV backups to display"));
            }
            backups.push(json!({"filename":name,"lastModified":item.last_modified}));
        }
    }
    Ok(json!({"backups":backups}))
}

pub(crate) async fn webdav_create() -> CmdResult<Value> {
    let (name, path) = {
        let _profile = crate::config::profiles::PROFILE_WRITE_LOCK.lock().await;
        let _config = Config::lock_config_write().await;
        crate::core::backup::create_backup()
            .await
            .map_err(|_| failure("BACKUP_CREATE_FAILED", "Could not create backup"))?
    };
    let remote = format!("{}-{}.zip", name.trim_end_matches(".zip"), nanoid::nanoid!(8));
    let result = WebDavClient::global().upload(path.clone(), remote.clone().into()).await;
    let _ = tokio::fs::remove_file(path).await;
    result.map_err(|_| failure("WEBDAV_FAILED", "Could not upload backup"))?;
    Ok(json!({"filename":remote}))
}

pub(crate) async fn webdav_delete(filename: String) -> CmdResult<Value> {
    cmd::delete_webdav_backup(filename)
        .await
        .map_err(|_| failure("WEBDAV_FAILED", "Could not delete WebDAV backup"))?;
    Ok(json!({"deleted":true}))
}

pub(crate) async fn webdav_restore(filename: String) -> CmdResult<Value> {
    let staging_name = format!("webdav-restore-{}.zip", nanoid::nanoid!());
    let staging = dirs::local_backup_dir()
        .map_err(|_| failure("WEBDAV_FAILED", "Backup directory unavailable"))?
        .join(&staging_name);
    WebDavClient::global()
        .download(filename.into(), staging.clone())
        .await
        .map_err(|_| failure("WEBDAV_FAILED", "Could not download WebDAV backup"))?;
    let result = restore(staging_name).await;
    let _ = tokio::fs::remove_file(staging).await;
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write as _;

    #[test]
    fn remote_filenames_and_user_paths_are_bounded() {
        assert_eq!(
            remote_filename("/dav/tez-backup/my%20backup.zip").as_deref(),
            Some("my backup.zip")
        );
        for href in ["/x/%2e%2e%2fsecret.zip", "/x/%5Cevil.zip", "/x/a.txt", "/x/"] {
            assert!(remote_filename(href).is_none());
        }
        assert!(valid_file_path("/tmp/a.zip"));
        assert!(!valid_file_path("relative.zip"));
        assert!(!valid_file_path("/tmp/a.txt"));
    }

    #[test]
    fn restore_failure_preserves_network_error_metadata() {
        let original = CommandFailure::coded("SYSTEM_PROXY_STATE_UNKNOWN", "unconfirmed")
            .asking_for(Some(crate::core::notification::FailedOperation::SystemProxyRestore));
        let result = restore_failure(original, "pre-restore.zip");
        assert_eq!(result.code.as_deref(), Some("SYSTEM_PROXY_STATE_UNKNOWN"));
        assert_eq!(
            result.operation,
            Some(crate::core::notification::FailedOperation::SystemProxyRestore)
        );
        assert!(result.detail.contains("pre-restore.zip"));
    }

    #[test]
    fn malformed_and_unsafe_archives_are_rejected() -> Result<()> {
        let path = std::env::temp_dir().join(format!("tez-backup-test-{}.zip", nanoid::nanoid!()));
        let mut zip = zip::ZipWriter::new(std::fs::File::create(&path)?);
        zip.start_file("../outside", zip::write::SimpleFileOptions::default())?;
        zip.write_all(b"unsafe")?;
        zip.finish()?;
        assert!(verify_archive(&path).is_err());
        std::fs::remove_file(path)?;
        Ok(())
    }

    #[test]
    fn corrupted_non_metadata_entries_are_rejected() -> Result<()> {
        let path = std::env::temp_dir().join(format!("tez-backup-crc-test-{}.zip", nanoid::nanoid!()));
        let mut zip = zip::ZipWriter::new(std::fs::File::create(&path)?);
        let options = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
        for (name, content) in [
            ("config.yaml", "{}\n"),
            ("tez.yaml", "{}\n"),
            ("profiles.yaml", "current: null\nitems: []\n"),
            ("profiles/unreferenced.yaml", "unique-crc-test-payload"),
        ] {
            zip.start_file(name, options)?;
            zip.write_all(content.as_bytes())?;
        }
        zip.finish()?;
        verify_archive(&path)?;
        let mut bytes = std::fs::read(&path)?;
        let marker = b"unique-crc-test-payload";
        let offset = bytes.windows(marker.len()).position(|part| part == marker).context("fixture payload")?;
        bytes[offset] ^= 1;
        std::fs::write(&path, bytes)?;
        assert!(verify_archive(&path).is_err());
        std::fs::remove_file(path)?;
        Ok(())
    }
}
