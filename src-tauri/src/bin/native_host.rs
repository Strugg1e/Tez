use std::path::PathBuf;
use std::process::ExitCode;

fn options(args: &[std::ffi::OsString]) -> Option<(bool, Option<PathBuf>, Option<PathBuf>)> {
    if args.first()? != "--stdio" {
        return None;
    }
    if args.len() == 1 {
        return Some((false, None, None));
    }
    if args.get(1)? != "--attach" {
        return None;
    }
    let mut data_dir = None;
    let mut socket_path = None;
    let mut remaining = args[2..].chunks_exact(2);
    for pair in &mut remaining {
        let target = if pair[0] == "--data-dir" {
            &mut data_dir
        } else if pair[0] == "--socket-path" {
            &mut socket_path
        } else {
            return None;
        };
        let path = PathBuf::from(&pair[1]);
        if target.is_some() || !path.is_absolute() {
            return None;
        }
        *target = Some(path);
    }
    if !remaining.remainder().is_empty() {
        return None;
    }
    Some((true, data_dir, socket_path))
}

fn main() -> ExitCode {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.len() == 1 && args[0] == "--build-info" {
        let mut identity=clash_verge_service_ipc::identity_info();
        identity["lifecycleAcceptance"]=serde_json::json!(cfg!(feature="native-lifecycle-acceptance"));
        println!("{identity}");
        return ExitCode::SUCCESS;
    }
    #[cfg(target_os = "macos")]
    if args.len() == 2 && args[0] == "--stdio" && (args[1] == "--automatic" || args[1] == "--inspect") {
        let result = if args[1] == "--automatic" { app_lib::native_lifecycle::run_automatic() }
            else { app_lib::native_lifecycle::run_inspection() };
        return match result {
            Ok(()) => ExitCode::SUCCESS,
            Err(_) => { eprintln!("Native lifecycle session failed; inspect current ownership before retrying."); ExitCode::FAILURE }
        };
    }
    #[cfg(target_os = "macos")]
    if args.len() == 3 && args[0] == "--stdio" && args[1] == "--isolated" {
        return match app_lib::native_isolated::run_stdio(PathBuf::from(&args[2])) {
            Ok(()) => ExitCode::SUCCESS,
            Err(_) => {
                eprintln!("Isolated fixture session failed.");
                ExitCode::FAILURE
            }
        };
    }
    if args.len() == 2 && args[0] == "--stdio" && args[1] == "--managed" {
        return match app_lib::native_managed::run_stdio() {
            Ok(()) => ExitCode::SUCCESS,
            Err(error) => {
                if let Some(code) = app_lib::native_managed::activation_exit_code(&error) {
                    eprintln!("Managed activation refused before any Core or network changes.");
                    ExitCode::from(code)
                } else {
                    eprintln!("Managed backend session or shutdown failed.");
                    ExitCode::FAILURE
                }
            }
        };
    }
    let Some((attach, data_dir, socket_path)) = options(&args) else {
        eprintln!(
            "Usage: tez-native-host --stdio [--attach [--data-dir ABSOLUTE_PATH] [--socket-path ABSOLUTE_PATH]] (inherited pipes only)"
        );
        return ExitCode::FAILURE;
    };
    let result = if attach {
        app_lib::native_host::run_attach(data_dir, socket_path)
    } else {
        app_lib::native_host::run_stdio()
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(_) => {
            eprintln!("Native host session failed.");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn attach_options_are_explicit_absolute_and_unique() {
        for valid in [
            vec!["--stdio"],
            vec!["--stdio", "--attach"],
            vec![
                "--stdio",
                "--attach",
                "--socket-path",
                "/tmp/test.sock",
                "--data-dir",
                "/tmp/data",
            ],
        ] {
            assert!(options(&valid.into_iter().map(Into::into).collect::<Vec<_>>()).is_some());
        }
        for invalid in [
            vec![],
            vec!["--attach"],
            vec!["--stdio", "--data-dir", "/tmp"],
            vec!["--stdio", "--attach", "--data-dir"],
            vec!["--stdio", "--attach", "--data-dir", "relative"],
            vec!["--stdio", "--attach", "--data-dir", "/tmp", "--data-dir", "/tmp"],
        ] {
            assert!(options(&invalid.into_iter().map(Into::into).collect::<Vec<_>>()).is_none());
        }
    }
}
