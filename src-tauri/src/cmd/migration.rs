use super::{CmdResult, WithErrorCode as _};
use crate::config::migration::{self, MigrationResult, MigrationScan};

#[tauri::command]
#[specta::specta]
pub async fn scan_migration_sources() -> CmdResult<MigrationScan> {
    migration::scan_sources().await.with_error_code("MIGRATION_SCAN_FAILED")
}

#[tauri::command]
#[specta::specta]
pub async fn migrate_local_profiles(
    source: String,
    fingerprint: String,
    scripts_confirmed: bool,
) -> CmdResult<MigrationResult> {
    migration::import_source(source, fingerprint, scripts_confirmed)
        .await
        .with_error_code("MIGRATION_IMPORT_FAILED")
}

#[tauri::command]
#[specta::specta]
pub async fn rollback_profile_migration() -> CmdResult<()> {
    migration::rollback().await.with_error_code("MIGRATION_ROLLBACK_FAILED")
}
