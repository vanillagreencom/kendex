//! Every program kendex spawns, and what each one is allowed to inherit.
//!
//! Separate from the supervision in `mod.rs` because they are different
//! questions. That file decides how a child is watched — timeout, output
//! cap, killing the tree. This one decides what gets run and under which
//! environment, which is where the security-relevant choices live: which
//! children keep git's redirect variables and which have them scrubbed,
//! whose stdin is the caller's, and how a shell script is spawned on a
//! platform whose kernel does not read `#!`.

use std::ffi::OsString;
use std::path::Path;
use std::process::Stdio;

use super::{Hardened, owned};

impl Hardened {
    pub fn git(args: &[&str], cwd: Option<&Path>) -> Hardened {
        let mut hardened = Hardened::git_command(owned(args), cwd);
        hardened.label = format!("git {}", args.join(" "));
        hardened
    }

    /// git against a downloaded repository. The working tree is pinned on
    /// the command line, where it outranks a `core.worktree` the repository
    /// ships, so the call cannot reach outside `repo`.
    pub fn git_in(repo: &Path, args: &[&str]) -> Hardened {
        let mut pinned = vec![
            OsString::from("--git-dir"),
            repo.join(".git").into_os_string(),
            OsString::from("--work-tree"),
            repo.as_os_str().to_owned(),
        ];
        pinned.extend(owned(args));
        let mut hardened = Hardened::git_command(pinned, Some(repo));
        hardened.label = format!("git {}", args.join(" "));
        hardened
    }

    /// git against a bare mirror in the cache. No working tree is attached,
    /// so no operation on it can write a file anywhere: a mirror only ever
    /// gains objects and refs.
    pub fn git_bare(git_dir: &Path, args: &[&str]) -> Hardened {
        let mut pinned = vec![OsString::from("--git-dir"), git_dir.as_os_str().to_owned()];
        pinned.extend(owned(args));
        let mut hardened = Hardened::git_command(pinned, Some(git_dir));
        hardened.label = format!("git {}", args.join(" "));
        hardened
    }

    /// git materializing a commit out of a bare mirror into `work_tree`.
    /// Both ends are pinned on the command line, where they outrank any
    /// `core.worktree` in the mirror, so the write lands in the directory
    /// named here and nowhere else.
    ///
    /// The one call that writes a working tree kendex then reads, so the
    /// one that settles line endings — `super::MATERIALISING` says why it
    /// goes here and nowhere else. Every other constructor above is either
    /// an inspection or has no working tree to write: `git_bare` attaches
    /// none, and the only clone kendex makes is `--mirror`, which is bare
    /// for the same reason. Conversion happens where git writes files.
    ///
    /// `attr_source` is the tree git reads `.gitattributes` from, in place
    /// of the commit being written and of the working tree it is written
    /// into. Named here rather than settled in `MATERIALISING` because its
    /// value belongs to the repository — the empty tree of that mirror's
    /// object format — and because a caller that has to name it cannot
    /// forget to; `remote::store::attribute_source` is where the value
    /// comes from, and a git too old for the option is refused there,
    /// before this call is spawned, so the reader gets a sentence naming
    /// the version they have rather than git's usage wall. It goes on the
    /// command line as the global option and not as `attr.tree` or
    /// `GIT_ATTR_SOURCE`, which do the same thing on a git that knows
    /// them: an option a git is too old to know is refused by name, where
    /// an unknown config key or environment variable is ignored without a
    /// word and the checkout converts in silence.
    pub fn git_into(
        git_dir: &Path,
        work_tree: &Path,
        attr_source: &str,
        args: &[&str],
    ) -> Hardened {
        let mut pinned = vec![
            OsString::from("--git-dir"),
            git_dir.as_os_str().to_owned(),
            OsString::from("--work-tree"),
            work_tree.as_os_str().to_owned(),
            OsString::from(format!("--attr-source={attr_source}")),
        ];
        pinned.extend(owned(args));
        let mut hardened = Hardened::git_materialising_command(pinned, Some(work_tree));
        hardened.label = format!("git {}", args.join(" "));
        hardened
    }

    pub fn npm(args: &[&str], cwd: Option<&Path>) -> Hardened {
        let mut hardened = Hardened::new("npm", owned(args));
        if let Some(cwd) = cwd {
            hardened.command.current_dir(cwd);
        }
        hardened
    }

    pub fn gh(args: &[&str]) -> Hardened {
        Hardened::new("gh", owned(args))
    }

    pub fn curl(args: &[&str]) -> Hardened {
        Hardened::new("curl", owned(args))
    }

    /// One of the package's shell scripts, spawned the way the platform can
    /// actually run it.
    ///
    /// Every script this crate spawns from the package is bash with a `#!`
    /// line. On Unix the kernel reads that line, so the path is the
    /// program. Windows has no such rule — `CreateProcess` would try to
    /// execute the text — so there the interpreter is the program and the
    /// script is its first argument, which is what git itself does when it
    /// runs a hook on Windows, through the `sh` that ships with Git for
    /// Windows — which IS bash, which is why naming it is correct rather
    /// than a hope about POSIX compatibility. A `sh` that is not on PATH
    /// fails as a spawn error naming it, which is a legible answer;
    /// guessing at a shell would not be.
    ///
    /// The scripts ask for bash, and Git for Windows' `sh` IS bash — that
    /// is why naming `sh` there is correct rather than a hope about POSIX
    /// compatibility. The package's own bash-3.2 suite keeps them inside
    /// what that build accepts.
    fn shell_script(program: &Path, args: Vec<OsString>) -> Hardened {
        #[cfg(unix)]
        {
            Hardened::spawning(program.as_os_str(), args)
        }
        #[cfg(not(unix))]
        {
            let mut argv = vec![program.as_os_str().to_owned()];
            argv.extend(args);
            Hardened::new("sh", argv)
        }
    }

    /// A hook body the growth-guards package ships, run from the repository
    /// root as the commit gate.
    ///
    /// The one child here that deliberately keeps git's redirect variables.
    /// Everything else scrubs them, because an inherited `GIT_DIR` would
    /// send a command at the wrong repository; but this child *is* a git
    /// hook body. Git exported those variables for it — `GIT_INDEX_FILE`
    /// naming the temporary index of the commit being made — and a chain
    /// that could not see them would judge the wrong snapshot, passing a
    /// commit nobody checked. Its stdin stays the caller's for the same
    /// reason: the commit-msg lane reads a message from a pipe when git
    /// hands it no file, and `/dev/null` there is an empty message. The
    /// program is never a name a committed file chose: it is the installed
    /// package's own script, at a path this crate derived.
    pub fn guard_hook(program: &Path, args: Vec<OsString>, cwd: &Path) -> Hardened {
        let mut hardened = Hardened::shell_script(program, args);
        hardened.command.stdin(Stdio::inherit());
        hardened.command.current_dir(cwd);
        hardened
    }

    /// A management script the growth-guards package ships — arming,
    /// disarming, or reporting on the shims.
    ///
    /// Not a hook body, so it gets the ordinary scrub. These run git
    /// themselves against the repository they were pointed at, and an
    /// inherited `GIT_DIR` or `GIT_INDEX_FILE` would outrank that and send
    /// them at a different repository — writing hooks into one repo while
    /// reporting about another.
    pub fn guard_script(program: &Path, args: Vec<OsString>, cwd: &Path) -> Hardened {
        let mut hardened = Hardened::shell_script(program, args);
        hardened.scrub_git_redirects();
        hardened.command.current_dir(cwd);
        hardened
    }
}
