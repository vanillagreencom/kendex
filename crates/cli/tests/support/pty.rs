//! Running the binary with a terminal on stderr instead of a pipe.
//!
//! The caller builds the command — its home, its arguments, its
//! environment — and this wires the terminal into it, so neither suite
//! inherits the other's rendering variables.
//!
//! Under `tests/support/` rather than `tests/`: it holds no `#[test]`, so
//! it is declared once by `tests/main.rs` and is no module of the harness's
//! roster of test files.
#![cfg(unix)]

use std::process::{Command, Output};

/// Everything the terminal was sent, colour codes and redraws included.
///
/// Reading runs until the last writer closes, which on Linux arrives as
/// `EIO` rather than end of file. Stdout goes nowhere: only the terminal is
/// under test, and a pipe nobody drains deadlocks the pair once a chattier
/// verb fills its buffer.
///
/// The command is taken by value and dropped before the read, because a
/// `Command` holds the handles it was given until it is: left alive, it is
/// a writer on the terminal that never closes, and the read below runs
/// until the suite is killed.
#[allow(
    dead_code,
    clippy::expect_used,
    reason = "including suites use it; the expects are fixture preconditions"
)]
pub fn sent_to_a_terminal(mut command: Command, input: &[u8]) -> Output {
    use std::fs;
    use std::io::{Read, Write};
    use std::os::fd::OwnedFd;

    let controller =
        rustix::pty::openpt(rustix::pty::OpenptFlags::RDWR | rustix::pty::OpenptFlags::NOCTTY)
            .expect("a pseudoterminal");
    rustix::pty::grantpt(&controller).expect("granted");
    rustix::pty::unlockpt(&controller).expect("unlocked");
    let name = rustix::pty::ptsname(&controller, Vec::new()).expect("its name");
    let terminal: OwnedFd = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(name.to_str().expect("a utf-8 device name"))
        .expect("the terminal side opens")
        .into();

    let mut child = command
        .stdin(std::process::Stdio::from(
            terminal.try_clone().expect("a second handle"),
        ))
        .stderr(std::process::Stdio::from(
            terminal.try_clone().expect("a third handle"),
        ))
        .stdout(std::process::Stdio::null())
        .spawn()
        .expect("kendex binary runs");
    // Every handle the parent still holds goes now, or the read below never
    // ends: the terminal stays open as long as any writer holds it, and the
    // command holds the three it was handed.
    drop(terminal);
    drop(command);

    let mut sent = Vec::new();
    let mut buffer = [0u8; 4096];
    let mut reader = fs::File::from(controller);
    reader.write_all(input).expect("terminal input");
    loop {
        match Read::read(&mut reader, &mut buffer) {
            Ok(0) => break,
            Ok(read) => sent.extend_from_slice(&buffer[..read]),
            // A signal arriving mid-read is not the end of the stream.
            // Taking it for one cuts the capture short without saying so.
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => break,
        }
    }
    Output {
        status: child.wait().expect("the child exits"),
        stdout: Vec::new(),
        stderr: sent,
    }
}
