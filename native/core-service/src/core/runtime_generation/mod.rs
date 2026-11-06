//! Builds or refreshes the runtime directory used by a core.
//! Preparation writes only after the old core stops; staging updates a live generation and
//! therefore plans first and declines whenever it cannot preserve consistency.

mod assets;
mod readback;
mod staging;

pub(crate) use assets::{PreparedRuntime, approved_core_copy, prepare_runtime, validate_core_path};
pub(crate) use assets::SESSION_CONFIG_FILE_NAME;
pub(crate) use readback::read_runtime_file;
pub(crate) use staging::stage_runtime;
pub(crate) use staging::write_atomically;
