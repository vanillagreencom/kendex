use std::env;
use std::io;
use std::os::unix::process::ExitStatusExt;
use std::path::Path;
use std::process::{Command, ExitCode};

fn run() -> io::Result<ExitCode> {
    let mut args = env::args_os();
    let executable = args
        .next()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "missing argv[0]"))?;
    let harness = Path::new(&executable)
        .file_name()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "missing harness name"))?;

    // Preserve the caller's environment, streams and process group for tmux teardown.
    let mut child = Command::new("python3")
        .arg(".fixture-harness.py")
        .args(args)
        .env("JARVIS_TEST_HARNESS", harness)
        .spawn()?;
    let status = child.wait()?;
    let code = match (status.code(), status.signal()) {
        (Some(code), _) => code,
        (None, Some(signal)) => 128 + signal,
        (None, None) => {
            return Err(io::Error::other("child has no exit code or signal"));
        }
    };
    let code = u8::try_from(code)
        .map_err(|_| io::Error::other("child exit status does not fit an exit code"))?;
    Ok(ExitCode::from(code))
}

fn main() -> ExitCode {
    match run() {
        Ok(code) => code,
        Err(error) => {
            eprintln!("harness-launcher: operation=launch-or-wait error={error}");
            ExitCode::FAILURE
        }
    }
}
