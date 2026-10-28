use super::{Config, IProfiles, profiles::PROFILE_WRITE_LOCK};
use crate::core::notify::{Refresh, announce};
use crate::utils::dirs;
use anyhow::{Context as _, Result, ensure};
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};
use std::{
    collections::{HashMap, HashSet},
    fs,
    io::{Read as _, Write as _},
    path::{Component, Path, PathBuf},
};

const SOURCES: &[(&str, &str)] = &[
    ("io.github.clash-verge-rev.clash-verge-rev", "Clash Verge Rev"),
    (
        "io.github.clash-verge-rev.clash-verge-rev.dev",
        "Clash Verge Rev · Development",
    ),
    ("io.github.clash-verge.clash-verge", "Clash Verge · Legacy"),
];
const MAX_INDEX: usize = 2 * 1024 * 1024;
const MAX_FILE: usize = 32 * 1024 * 1024;
const MAX_TOTAL: usize = 256 * 1024 * 1024;
const RECEIPT: &str = "migration-receipt.json";

#[derive(Clone, Serialize, specta::Type)]
#[serde(rename_all = "camelCase")]
pub struct MigrationSource {
    pub id: String,
    pub label: String,
    pub path: String,
    pub profile_count: u32,
    pub file_count: u32,
    pub script_count: u32,
    pub fingerprint: Option<String>,
    pub error: Option<String>,
}

#[derive(Clone, Serialize, specta::Type)]
#[serde(rename_all = "camelCase")]
pub struct MigrationReceiptView {
    pub source: String,
    pub profile_count: u32,
    pub can_rollback: bool,
}

#[derive(Serialize, specta::Type)]
#[serde(rename_all = "camelCase")]
pub struct MigrationScan {
    pub sources: Vec<MigrationSource>,
    pub destination_has_profiles: bool,
    pub last_migration: Option<MigrationReceiptView>,
}

#[derive(Serialize, specta::Type)]
#[serde(rename_all = "camelCase")]
pub struct MigrationResult {
    pub profile_count: u32,
    pub file_count: u32,
}

struct Plan {
    index: IProfiles,
    files: Vec<(String, Vec<u8>)>,
    fingerprint: String,
    profile_count: u32,
    script_count: u32,
}

#[derive(Serialize, Deserialize)]
struct Receipt {
    id: String,
    source: String,
    profile_count: u32,
    previous_hash: String,
    imported_hash: String,
    files: Vec<(String, String)>,
}

fn hash(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|byte| format!("{byte:02x}")).collect()
}

fn filename(name: &str) -> Result<()> {
    let mut parts = Path::new(name).components();
    ensure!(
        !name.is_empty() && name.len() <= 240 && !name.contains(['/', '\\']),
        "Invalid profile filename"
    );
    ensure!(
        matches!((parts.next(), parts.next()), (Some(Component::Normal(_)), None)),
        "Invalid profile filename"
    );
    Ok(())
}

fn real_directory(path: &Path) -> Result<()> {
    let meta = fs::symlink_metadata(path).context("Configuration directory is unavailable")?;
    ensure!(
        meta.is_dir() && !meta.file_type().is_symlink(),
        "Linked configuration directories are not supported"
    );
    Ok(())
}

fn read_regular(path: &Path, limit: usize) -> Result<Vec<u8>> {
    let meta = fs::symlink_metadata(path).context("A required configuration file is missing")?;
    ensure!(
        meta.is_file() && !meta.file_type().is_symlink(),
        "Linked configuration files are not supported"
    );
    ensure!(
        meta.len() <= limit as u64,
        "Configuration file exceeds migration size limit"
    );
    let mut data = Vec::new();
    let mut options = fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    options.open(path)?.take(limit as u64 + 1).read_to_end(&mut data)?;
    ensure!(data.len() <= limit, "Configuration file exceeds migration size limit");
    Ok(data)
}

fn profile_count(index: &IProfiles) -> u32 {
    index
        .items
        .as_deref()
        .unwrap_or_default()
        .iter()
        .filter(|item| matches!(item.itype.as_deref(), Some("remote" | "local")))
        .count() as u32
}

fn load_plan(root: &Path) -> Result<Plan> {
    real_directory(root)?;
    real_directory(&root.join("profiles"))?;
    let bytes = read_regular(&root.join("profiles.yaml"), MAX_INDEX)?;
    let index: IProfiles =
        serde_yaml_ng::from_slice(&bytes).map_err(|_| anyhow::anyhow!("Profile index could not be parsed"))?;
    let items = index.items.as_ref().context("Profile index has no items")?;
    ensure!(items.len() <= 512, "Too many configuration items to migrate");
    let count = profile_count(&index);
    ensure!(count > 0, "No subscriptions or local profiles found");
    let mut ids = HashSet::new();
    let mut names = HashSet::new();
    let mut files = Vec::new();
    let mut scripts = 0;
    let mut total = bytes.len();
    let mut digest = Sha256::new();
    digest.update(&bytes);
    for item in items {
        let uid = item.uid.as_ref().context("Profile identifier is missing")?;
        ensure!(
            !uid.is_empty() && ids.insert(uid.as_str()),
            "Profile identifiers must be unique"
        );
        let kind = item.itype.as_deref().context("Profile type is missing")?;
        ensure!(
            matches!(
                kind,
                "remote" | "local" | "merge" | "script" | "rules" | "proxies" | "groups"
            ),
            "Unsupported profile type"
        );
        let name = item.file.as_deref().context("Profile filename is missing")?;
        filename(name)?;
        ensure!(name.len() <= 160, "Profile filename is too long to migrate");
        let ext = Path::new(name).extension().and_then(|s| s.to_str()).unwrap_or_default();
        ensure!(
            matches!((kind, ext), ("script", "js") | (_, "yaml" | "yml")),
            "Unsupported profile file format"
        );
        let data = read_regular(&root.join("profiles").join(name), MAX_FILE)?;
        total += data.len();
        ensure!(total <= MAX_TOTAL, "Configuration exceeds migration size limit");
        if kind == "script" {
            scripts += 1;
        } else {
            serde_yaml_ng::from_slice::<serde_yaml_ng::Value>(&data)
                .map_err(|_| anyhow::anyhow!("A profile YAML file could not be parsed"))?;
        }
        ensure!(names.insert(name.to_owned()), "Profile filenames must be unique");
        digest.update((name.len() as u64).to_le_bytes());
        digest.update(name.as_bytes());
        digest.update((data.len() as u64).to_le_bytes());
        digest.update(&data);
        files.push((name.to_owned(), data));
    }
    for item in items {
        if let Some(option) = &item.option {
            for reference in [
                &option.merge,
                &option.script,
                &option.rules,
                &option.proxies,
                &option.groups,
            ]
            .into_iter()
            .flatten()
            {
                ensure!(ids.contains(reference.as_str()), "An enhancement reference is missing");
            }
        }
    }
    ensure!(
        read_regular(&root.join("profiles.yaml"), MAX_INDEX)? == bytes,
        "Source changed during scan; scan again"
    );
    Ok(Plan {
        index,
        files,
        fingerprint: digest.finalize().iter().map(|byte| format!("{byte:02x}")).collect(),
        profile_count: count,
        script_count: scripts,
    })
}

fn source_path(id: &str) -> Result<PathBuf> {
    ensure!(
        SOURCES.iter().any(|(known, _)| *known == id),
        "Unknown migration source"
    );
    Ok(::dirs::data_dir()
        .context("Application data directory is unavailable")?
        .join(id))
}

fn private_dir(path: &Path) -> Result<()> {
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt as _;
        builder.mode(0o700);
    }
    builder.create(path)?;
    real_directory(path)
}

fn private_write(path: &Path, bytes: &[u8]) -> Result<()> {
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.mode(0o600);
    }
    let mut file = options.open(path)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    Ok(())
}

fn atomic_private_write(path: &Path, bytes: &[u8]) -> Result<()> {
    let temporary = path.with_extension(format!("migration-{}", nanoid::nanoid!()));
    let cleanup = scopeguard::guard(temporary, |path| {
        let _ = fs::remove_file(path);
    });
    private_write(&cleanup, bytes)?;
    fs::rename(&*cleanup, path)?;
    Ok(())
}

fn receipt(root: &Path) -> Result<Receipt> {
    let receipt: Receipt = serde_json::from_slice(&read_regular(&root.join(RECEIPT), MAX_INDEX)?)?;
    ensure!(
        receipt.id.len() <= 64
            && !receipt.id.is_empty()
            && receipt
                .id
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'-' | b'_')),
        "Invalid migration backup identifier"
    );
    for (name, _) in &receipt.files {
        filename(name)?;
    }
    Ok(receipt)
}

fn unchanged(root: &Path, receipt: &Receipt) -> bool {
    let check = || -> Result<bool> {
        if hash(&read_regular(&root.join("profiles.yaml"), MAX_INDEX)?) != receipt.imported_hash {
            return Ok(false);
        }
        for (name, expected) in &receipt.files {
            if hash(&read_regular(&root.join("profiles").join(name), MAX_FILE)?) != *expected {
                return Ok(false);
            }
        }
        Ok(true)
    };
    check().unwrap_or(false)
}

fn scan_at(data_root: &Path, destination: &Path) -> MigrationScan {
    let sources = SOURCES
        .iter()
        .filter_map(|(id, label)| {
            let root = data_root.join(id);
            if !root.exists() {
                return None;
            }
            let mut view = MigrationSource {
                id: (*id).into(),
                label: (*label).into(),
                path: root.display().to_string(),
                profile_count: 0,
                file_count: 0,
                script_count: 0,
                fingerprint: None,
                error: None,
            };
            match load_plan(&root) {
                Ok(plan) => {
                    view.profile_count = plan.profile_count;
                    view.file_count = plan.files.len() as u32;
                    view.script_count = plan.script_count;
                    view.fingerprint = Some(plan.fingerprint);
                }
                Err(error) => view.error = Some(error.to_string()),
            }
            Some(view)
        })
        .collect();
    let destination_has_profiles = read_regular(&destination.join("profiles.yaml"), MAX_INDEX)
        .and_then(|bytes| serde_yaml_ng::from_slice::<IProfiles>(&bytes).map_err(Into::into))
        .map_or(true, |index| profile_count(&index) > 0);
    let last_migration = receipt(destination)
        .ok()
        .filter(|r| destination_has_profiles || unchanged(destination, r))
        .map(|r| MigrationReceiptView {
            source: r.source.clone(),
            profile_count: r.profile_count,
            can_rollback: unchanged(destination, &r),
        });
    MigrationScan {
        sources,
        destination_has_profiles,
        last_migration,
    }
}

pub async fn scan_sources() -> Result<MigrationScan> {
    let data_root = ::dirs::data_dir().context("Application data directory is unavailable")?;
    let destination = dirs::app_home_dir()?;
    tokio::task::spawn_blocking(move || scan_at(&data_root, &destination))
        .await
        .context("Migration scan was interrupted")
}

fn commit_plan(
    mut plan: Plan,
    destination: &Path,
    source: &str,
    expected: &str,
    scripts_confirmed: bool,
) -> Result<(IProfiles, MigrationResult)> {
    ensure!(
        plan.fingerprint == expected,
        "Source changed since the scan; scan again"
    );
    ensure!(
        plan.script_count == 0 || scripts_confirmed,
        "Confirm enhancement scripts before migrating"
    );
    real_directory(destination)?;
    real_directory(&destination.join("profiles"))?;
    let previous = read_regular(&destination.join("profiles.yaml"), MAX_INDEX)?;
    let old: IProfiles =
        serde_yaml_ng::from_slice(&previous).map_err(|_| anyhow::anyhow!("Tez profile index could not be parsed"))?;
    ensure!(
        profile_count(&old) == 0 && old.current.is_none(),
        "Tez already has profiles; automatic migration will not overwrite them"
    );
    let id = nanoid::nanoid!();
    let backup = destination.join("migration-backups").join(&id);
    private_dir(&destination.join("migration-backups"))?;
    private_dir(&backup)?;
    private_write(&backup.join("profiles.yaml"), &previous)?;
    let remap: HashMap<_, _> = plan
        .files
        .iter()
        .map(|(name, _)| (name.clone(), format!("migrated-{id}-{name}")))
        .collect();
    plan.index.current = None;
    for item in plan.index.items.iter_mut().flatten() {
        if let Some(name) = &item.file {
            item.file = Some(remap[name.as_str()].clone().into());
        }
        if matches!(item.itype.as_deref(), Some("remote" | "local")) {
            item.option.get_or_insert_with(Default::default).allow_auto_update = Some(false);
        }
    }
    let mut imported_files = Vec::new();
    // Files get new names; the atomic index replacement is the only activation point.
    for (name, data) in &plan.files {
        let new_name = &remap[name];
        private_write(&destination.join("profiles").join(new_name), data)?;
        imported_files.push((new_name.clone(), hash(data)));
    }
    let serialized = serde_yaml_ng::to_string(&plan.index)?.into_bytes();
    let receipt = Receipt {
        id,
        source: source.into(),
        profile_count: plan.profile_count,
        previous_hash: hash(&previous),
        imported_hash: hash(&serialized),
        files: imported_files,
    };
    atomic_private_write(&destination.join(RECEIPT), &serde_json::to_vec(&receipt)?)?;
    atomic_private_write(&destination.join("profiles.yaml"), &serialized)?;
    Ok((
        plan.index,
        MigrationResult {
            profile_count: plan.profile_count,
            file_count: plan.files.len() as u32,
        },
    ))
}

pub async fn import_source(source: String, fingerprint: String, scripts_confirmed: bool) -> Result<MigrationResult> {
    let root = source_path(&source)?;
    let plan = tokio::task::spawn_blocking(move || load_plan(&root)).await??;
    let _write = PROFILE_WRITE_LOCK.lock().await;
    let _config = Config::lock_config_write().await;
    let destination = dirs::app_home_dir()?;
    let result = Config::profiles()
        .await
        .with_data_modify(move |current| async move {
            ensure!(
                profile_count(&current) == 0 && current.current.is_none(),
                "Tez already has profiles; automatic migration will not overwrite them"
            );
            tokio::task::spawn_blocking(move || {
                commit_plan(plan, &destination, &source, &fingerprint, scripts_confirmed)
            })
            .await?
        })
        .await?;
    announce(Refresh::Profiles);
    Ok(result)
}

fn rollback_at(destination: &Path) -> Result<IProfiles> {
    let receipt = receipt(destination)?;
    ensure!(
        unchanged(destination, &receipt),
        "Migrated profiles have changed; rollback would hide your edits"
    );
    real_directory(&destination.join("migration-backups"))?;
    real_directory(&destination.join("migration-backups").join(&receipt.id))?;
    let previous = read_regular(
        &destination
            .join("migration-backups")
            .join(&receipt.id)
            .join("profiles.yaml"),
        MAX_INDEX,
    )?;
    ensure!(hash(&previous) == receipt.previous_hash, "Migration backup has changed");
    let index: IProfiles = serde_yaml_ng::from_slice(&previous)?;
    atomic_private_write(&destination.join("profiles.yaml"), &previous)?;
    // Keep both backups and copied files so rollback never deletes user data.
    let _ = fs::remove_file(destination.join(RECEIPT));
    Ok(index)
}

pub async fn rollback() -> Result<()> {
    let _write = PROFILE_WRITE_LOCK.lock().await;
    let _config = Config::lock_config_write().await;
    let destination = dirs::app_home_dir()?;
    Config::profiles()
        .await
        .with_data_modify(move |current| async move {
            ensure!(
                current.current.is_none(),
                "Deactivate the migrated profile before rollback"
            );
            let restored = tokio::task::spawn_blocking(move || rollback_at(&destination)).await??;
            Ok((restored, ()))
        })
        .await?;
    announce(Refresh::Profiles);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fixture {
        root: PathBuf,
        source: PathBuf,
        target: PathBuf,
    }

    impl Fixture {
        fn new() -> Result<Self> {
            let root = std::env::temp_dir().join(format!("tez-migration-{}", nanoid::nanoid!()));
            let source = root.join(SOURCES[0].0);
            let target = root.join("app.tez.client");
            for path in [&source, &target] {
                fs::create_dir_all(path.join("profiles"))?;
            }
            fs::write(
                source.join("profiles.yaml"),
                "current: daily\nitems:\n  - uid: daily\n    type: remote\n    name: Daily\n    file: daily.yaml\n    url: https://example.invalid/subscription\n    option:\n      script: Script\n      allow_auto_update: true\n  - uid: Script\n    type: script\n    file: script.js\n",
            )?;
            fs::write(
                source.join("profiles/daily.yaml"),
                "proxies: []\nrules: [MATCH,DIRECT]\n",
            )?;
            fs::write(
                source.join("profiles/script.js"),
                "throw new Error('must never execute during migration')",
            )?;
            fs::write(
                source.join("verge.yaml"),
                "enable_system_proxy: true\nenable_tun_mode: true\n",
            )?;
            fs::write(
                target.join("profiles.yaml"),
                "current: null\nitems:\n  - uid: Merge\n    type: merge\n    file: default.yaml\n",
            )?;
            fs::write(target.join("profiles/default.yaml"), "prepend: []\n")?;
            fs::write(target.join("tez.yaml"), "enable_system_proxy: false\n")?;
            Ok(Self { root, source, target })
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    #[test]
    fn migration_scan_is_read_only_and_only_checks_known_sources() -> Result<()> {
        let fixture = Fixture::new()?;
        fs::create_dir_all(fixture.root.join("unrelated.app"))?;
        fs::write(fixture.root.join("unrelated.app/profiles.yaml"), "not a profile index")?;
        let source_before = fs::read(fixture.source.join("profiles.yaml"))?;
        let target_before = fs::read(fixture.target.join("profiles.yaml"))?;
        let scan = scan_at(&fixture.root, &fixture.target);
        assert_eq!(scan.sources.len(), 1);
        assert_eq!(scan.sources[0].profile_count, 1);
        assert_eq!(scan.sources[0].script_count, 1);
        assert!(scan.sources[0].fingerprint.is_some());
        assert!(!scan.destination_has_profiles);
        assert_eq!(fs::read(fixture.source.join("profiles.yaml"))?, source_before);
        assert_eq!(fs::read(fixture.target.join("profiles.yaml"))?, target_before);
        assert!(!fixture.target.join(RECEIPT).exists());
        Ok(())
    }

    #[test]
    fn migration_preserves_source_and_settings_and_can_restore_the_old_index() -> Result<()> {
        let fixture = Fixture::new()?;
        let source_before = fs::read(fixture.source.join("profiles.yaml"))?;
        let target_before = fs::read(fixture.target.join("profiles.yaml"))?;
        let plan = load_plan(&fixture.source)?;
        let fingerprint = plan.fingerprint.clone();
        let (index, result) = commit_plan(plan, &fixture.target, SOURCES[0].0, &fingerprint, true)?;
        assert_eq!(result.profile_count, 1);
        assert_eq!(result.file_count, 2);
        assert!(index.current.is_none());
        let item = index.get_item("daily")?;
        assert_eq!(item.option.as_ref().and_then(|o| o.allow_auto_update), Some(false));
        assert_eq!(item.option.as_ref().and_then(|o| o.script.as_deref()), Some("Script"));
        let copied = fixture
            .target
            .join("profiles")
            .join(item.file.as_deref().unwrap_or_default());
        assert_eq!(fs::read(copied)?, fs::read(fixture.source.join("profiles/daily.yaml"))?);
        assert_eq!(fs::read(fixture.source.join("profiles.yaml"))?, source_before);
        assert_eq!(
            fs::read_to_string(fixture.target.join("tez.yaml"))?,
            "enable_system_proxy: false\n"
        );
        assert_eq!(
            fs::read_to_string(fixture.target.join("profiles/default.yaml"))?,
            "prepend: []\n"
        );
        assert!(
            scan_at(&fixture.root, &fixture.target)
                .last_migration
                .is_some_and(|r| r.can_rollback)
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            assert_eq!(
                fs::metadata(fixture.target.join("profiles.yaml"))?.permissions().mode() & 0o777,
                0o600
            );
        }
        rollback_at(&fixture.target)?;
        assert_eq!(fs::read(fixture.target.join("profiles.yaml"))?, target_before);
        assert!(!fixture.target.join(RECEIPT).exists());
        Ok(())
    }

    #[test]
    fn migration_refuses_changed_sources_unconfirmed_scripts_and_existing_profiles() -> Result<()> {
        let fixture = Fixture::new()?;
        let old_fingerprint = load_plan(&fixture.source)?.fingerprint;
        fs::write(fixture.source.join("profiles/daily.yaml"), "proxies: []\nrules: []\n")?;
        let plan = load_plan(&fixture.source)?;
        assert!(commit_plan(plan, &fixture.target, SOURCES[0].0, &old_fingerprint, true).is_err());
        let plan = load_plan(&fixture.source)?;
        let fingerprint = plan.fingerprint.clone();
        assert!(commit_plan(plan, &fixture.target, SOURCES[0].0, &fingerprint, false).is_err());
        fs::write(
            fixture.target.join("profiles.yaml"),
            "items:\n - uid: existing\n   type: local\n   file: default.yaml\n",
        )?;
        let before = fs::read(fixture.target.join("profiles.yaml"))?;
        let plan = load_plan(&fixture.source)?;
        assert!(commit_plan(plan, &fixture.target, SOURCES[0].0, &fingerprint, true).is_err());
        assert_eq!(fs::read(fixture.target.join("profiles.yaml"))?, before);
        assert!(!fixture.target.join("migration-backups").exists());
        Ok(())
    }

    #[test]
    fn migration_rejects_traversal_missing_dependencies_and_unknown_roots() -> Result<()> {
        let fixture = Fixture::new()?;
        let original = fs::read_to_string(fixture.source.join("profiles.yaml"))?;
        fs::write(
            fixture.source.join("profiles.yaml"),
            original.replace("daily.yaml", "../outside.yaml"),
        )?;
        assert!(load_plan(&fixture.source).is_err());
        fs::write(
            fixture.source.join("profiles.yaml"),
            original.replace("script: Script", "script: missing"),
        )?;
        assert!(load_plan(&fixture.source).is_err());
        assert!(source_path("../../elsewhere").is_err());
        assert!(filename("a\\b.yaml").is_err());
        Ok(())
    }

    #[cfg(unix)]
    #[test]
    fn migration_rejects_linked_profile_files() -> Result<()> {
        let fixture = Fixture::new()?;
        fs::remove_file(fixture.source.join("profiles/daily.yaml"))?;
        fs::write(fixture.root.join("outside.yaml"), "proxies: []")?;
        std::os::unix::fs::symlink(
            fixture.root.join("outside.yaml"),
            fixture.source.join("profiles/daily.yaml"),
        )?;
        assert!(load_plan(&fixture.source).is_err());
        Ok(())
    }

    #[test]
    fn migration_does_not_replace_the_index_when_receipt_persistence_fails() -> Result<()> {
        let fixture = Fixture::new()?;
        fs::create_dir(fixture.target.join(RECEIPT))?;
        let before = fs::read(fixture.target.join("profiles.yaml"))?;
        let plan = load_plan(&fixture.source)?;
        let fingerprint = plan.fingerprint.clone();
        assert!(commit_plan(plan, &fixture.target, SOURCES[0].0, &fingerprint, true).is_err());
        assert_eq!(fs::read(fixture.target.join("profiles.yaml"))?, before);
        assert!(fixture.target.join("profiles/default.yaml").is_file());
        Ok(())
    }

    #[test]
    fn migration_rollback_refuses_to_hide_edits_to_imported_files() -> Result<()> {
        let fixture = Fixture::new()?;
        let plan = load_plan(&fixture.source)?;
        let fingerprint = plan.fingerprint.clone();
        let (index, _) = commit_plan(plan, &fixture.target, SOURCES[0].0, &fingerprint, true)?;
        let imported = index.get_item("daily")?.file.as_deref().context("filename")?;
        fs::write(fixture.target.join("profiles").join(imported), "rules: [DIRECT]\n")?;
        let before = fs::read(fixture.target.join("profiles.yaml"))?;
        assert!(rollback_at(&fixture.target).is_err());
        assert_eq!(fs::read(fixture.target.join("profiles.yaml"))?, before);
        Ok(())
    }
}
