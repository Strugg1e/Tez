fn main() -> std::process::ExitCode {
    #[cfg(target_os = "macos")]
    {
        let args: Vec<_> = std::env::args_os().skip(1).collect();
        if args.len() == 3 {
            match app_lib::native_acceptance::run(
                std::path::PathBuf::from(&args[0]),
                &args[1].to_string_lossy(),
                &args[2].to_string_lossy(),
            ) {
                Ok(()) => return std::process::ExitCode::SUCCESS,
                Err(error) => eprintln!("Subscription acceptance failed: {error:#}"),
            }
        }
    }
    std::process::ExitCode::FAILURE
}
