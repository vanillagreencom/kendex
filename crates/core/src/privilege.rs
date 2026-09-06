//! Whether this process is acting as root.
//!
//! Every path kendex writes on a person's own machine is resolved from the
//! environment this process was handed — `HOME`, `XDG_CONFIG_HOME` and
//! `XDG_DATA_HOME` decide where [`crate::env::Env`] puts the settings file,
//! the command record and the global scope — and a privileged run was
//! handed that environment by whoever invoked it. `sudo` resets it on most
//! machines, but a `sudoers` carrying `env_keep HOME` does not, and then a
//! root process opens a file every component of whose name belongs to the
//! invoking account: a link there is followed, and root writes wherever it
//! points. Worse where it succeeds than where it fails — a lock file or a
//! config directory left owned by root refuses every unprivileged write
//! after it, for good, with nothing on screen naming the cause.
//!
//! So a run acting as root writes none of that. The person's own next
//! unprivileged run does it instead.
//!
//! The effective uid and nothing else. `sudo`, `su`, `doas` and a root
//! login are one case here and none of them is distinguishable by a
//! variable: `SUDO_USER` and its neighbours are set by whoever invoked the
//! command, so a check reading one would be a check the invoker decides.

/// Whether this process is acting as root.
#[cfg(unix)]
pub fn acting_as_root() -> bool {
    rustix::process::geteuid().is_root()
}

/// Windows has no uid to answer with, and none of the elevation this
/// guards for — a command re-run under another account against the first
/// account's environment — is reachable there.
#[cfg(not(unix))]
pub fn acting_as_root() -> bool {
    false
}
