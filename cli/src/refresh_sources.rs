use crate::config::{self, CacheLease};
use anyhow::{Context, Result, bail};
use std::path::{Path, PathBuf};

mod records;
mod url;

pub(crate) use records::*;
pub(crate) use url::*;

fn canonicalish(path: &Path) -> PathBuf {
    path.canonicalize().unwrap_or_else(|_| path.to_path_buf())
}

fn same_path(a: &Path, b: &Path) -> bool {
    canonicalish(a) == canonicalish(b)
}

/// Whether an entry's recorded source still names a source of its own.
///
/// Deliberately side-effect free (no remote fetch): callers use it in per-entry
/// loops to decide whether an entry may fall back to a different source. A
/// remote-shaped source always does — whether its clone is present, and whether
/// vstack will use its URL at all, are questions about that source and never
/// grounds to reinstall the entry from a different one.
pub(crate) fn recorded_source_exists(source: &str) -> bool {
    let path = Path::new(source);
    if path.is_absolute() {
        return path.is_dir();
    }
    resolve_recorded_local_source(source).is_some()
        || looks_like_remote_source(source)
        || names_a_transport(source)
}

pub(crate) fn resolve_source_path(source: &str) -> Option<PathBuf> {
    source_path_resolution(source).or_warn(source)
}

/// The resolution [`resolve_source_path`] performs, with the distinction it
/// discards: a source that exists and was REFUSED is not one that is absent,
/// and the two are repaired differently. Reads the cache as it stands — no
/// fetch — so a caller that only reports on state does not update one.
pub(crate) fn source_path_resolution(source: &str) -> SourceResolution {
    // No fetch, so no lease: this reads the cache as it stands.
    resolve_single_source_with(source, false, false).resolution
}

/// Resolve one source string, taking a lease when the resolution UPDATES a
/// remote cache — because a caller that asked for an update is a caller that
/// is about to read what the update produced. Every other branch is a local
/// directory and leases nothing.
fn resolve_single_source_with(
    source: &str,
    update_remote: bool,
    require_vstack_source: bool,
) -> LeasedResolution {
    // Absolute local path that exists.
    let p = std::path::Path::new(source);
    if p.is_absolute()
        && p.is_dir()
        && (!require_vstack_source || crate::resolve::is_vstack_source(p))
    {
        return SourceResolution::Resolved(p.to_path_buf()).into();
    }

    // Explicit relative local source tokens in locks/registries are
    // project-scoped. Treating them as "walk upward to any vstack source" can
    // rebind a live ./source entry to the checkout running the command from a
    // linked worktree, then repair the lock to the wrong source.
    if is_explicit_relative_local_source(source) {
        return resolve_relative_local_source(source, require_vstack_source)
            .map_or(SourceResolution::Absent, SourceResolution::Resolved)
            .into();
    }

    // Legacy pure hash/reconcile paths accepted bare placeholders such as
    // "source" by falling back to the nearest vstack checkout from CWD. Keep
    // that compatibility only after trying the project-relative path, and only
    // for non-discovery calls where the historical fallback existed.
    if !require_vstack_source && is_bare_local_source(source) {
        return resolve_relative_local_source(source, false)
            .or_else(find_vstack_source_from_cwd)
            .map_or(SourceResolution::Absent, SourceResolution::Resolved)
            .into();
    }

    // Remote shorthand or URL: update once during top-level source resolution,
    // then use the cached clone as it stands — nothing here writes to the
    // cache, so the pure attribution and hash paths are read-only.
    let remote = match RemoteSource::parse(source) {
        Ok(Some(remote)) => remote,
        Ok(None) => return SourceResolution::Absent.into(),
        Err(err) => return SourceResolution::refused(&err).into(),
    };
    if !cache_entry_present(&remote) {
        return SourceResolution::Absent.into();
    }
    if update_remote {
        eprintln!("Updating cached repo {}...", remote.display);
        // The update path runs the filesystem checks itself, on its way to the
        // git-level ones that guard `reset --hard`.
        return match update_cached_repo(&remote) {
            // The lease travels with the directory it protects: whoever reads
            // this root holds it until the read is done.
            Ok(lease) => LeasedResolution {
                resolution: SourceResolution::Resolved(remote.cache_dir),
                lease,
            },
            Err(err) => SourceResolution::refused(&err).into(),
        };
    } else if config::remote_cache_fetch_in_flight(&remote.cache_dir) {
        // Read-only, and another process is mid-fetch: this tree is being
        // `reset --hard` right now, so every question asked of it — which
        // assets it ships, what they hash to, even which repository its
        // `.git/config` names — can be answered wrongly rather than not at
        // all. Probed, never waited on: the session-start check runs this path
        // and must stay local, so the answer is "not this run" rather than a
        // lease taken out from under an install.
        return SourceResolution::Busy.into();
    } else if let Err(err) = ensure_cache_entry_is_owned(&remote) {
        // The same question the update path asks, because reading an entry is
        // how its content becomes the installed asset: a symlinked entry or a
        // redirected `.git` is some other checkout, and an entry whose origin
        // is a different repository would be installed as this source. Every
        // check is a read; only the fetch and reset the update path adds are
        // not.
        return SourceResolution::refused(&err).into();
    }
    SourceResolution::Resolved(remote.cache_dir).into()
}

/// Best-effort update of every remote source's cache entry named by a lock.
/// A refusal is reported and the entry left alone; a failed fetch keeps the
/// stale clone. Cheap enough to run before staleness checks.
///
/// Nothing reads the caches afterwards, so every lease it takes is released
/// as each entry is done.
#[cfg(test)]
pub(crate) fn refresh_remote_caches(lock: &config::LockFile) {
    let mut seen = std::collections::HashSet::new();
    for entry in lock.entries.values() {
        if !seen.insert(entry.source.clone()) {
            continue;
        }
        let remote = match RemoteSource::parse(&entry.source) {
            Ok(Some(remote)) => remote,
            Ok(None) => continue,
            Err(err) => {
                warn_once(&entry.source, &format!("{err:#}"));
                continue;
            }
        };
        if !cache_entry_present(&remote) {
            continue;
        }
        if let Err(err) = update_cached_repo(&remote) {
            warn_once(&entry.source, &format!("{err:#}"));
        }
    }
}

/// Print `message` once per process for `key`. Output dedup only — which
/// sources were refused is carried by [`SourceResolution`], never by this set;
/// two callers resolving the same source must not print the same warning
/// twice.
pub(crate) fn warn_once(key: &str, message: &str) {
    if warn_once_is_new(key, message) {
        eprintln!("  Warning: {message}");
    }
}

/// Whether this `(key, message)` pair has not been printed yet, recording it.
///
/// A pair, not a concatenation: a source string carries arbitrary bytes, so
/// any delimiter byte can appear inside one and let two distinct pairs collapse
/// to the same string — suppressing a warning that was never printed.
fn warn_once_is_new(key: &str, message: &str) -> bool {
    type SeenPairs = std::collections::HashSet<(String, String)>;
    static SEEN: std::sync::OnceLock<std::sync::Mutex<SeenPairs>> = std::sync::OnceLock::new();
    let mut seen = SEEN
        .get_or_init(Default::default)
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    seen.insert((key.to_string(), message.to_string()))
}

fn is_explicit_relative_local_source(source: &str) -> bool {
    source == "." || source.starts_with("./") || source.starts_with("../")
}

fn is_bare_local_source(source: &str) -> bool {
    !source.is_empty()
        && !source.starts_with('~')
        && !Path::new(source).is_absolute()
        && !source.contains('/')
        && !source.contains('\\')
        && !looks_like_remote_source(source)
}

fn resolve_recorded_local_source(source: &str) -> Option<PathBuf> {
    if !is_explicit_relative_local_source(source) && !is_bare_local_source(source) {
        return None;
    }
    resolve_relative_local_source(source, false)
}

fn resolve_relative_local_source(source: &str, require_vstack_source: bool) -> Option<PathBuf> {
    if source.starts_with('~') {
        return None;
    }
    let candidate = config::project_root().join(source);
    if !candidate.is_dir() {
        return None;
    }
    if require_vstack_source && !crate::resolve::is_vstack_source(&candidate) {
        return None;
    }
    Some(canonicalish(&candidate))
}

fn find_vstack_source_from_cwd() -> Option<PathBuf> {
    let mut dir = std::env::current_dir().ok()?;
    loop {
        if crate::resolve::is_vstack_source(&dir) {
            return Some(dir);
        }
        if !dir.pop() {
            return None;
        }
    }
}

// ---------------------------------------------------------------------------
// Remote sources
// ---------------------------------------------------------------------------

/// What a remote source string names: the one URL git is given, and the one
/// cache entry its clone lives in. This is also where credential-bearing and
/// unsupported inputs are refused, before any git process sees them.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct RemoteSource {
    /// The source as recorded, safe to show: userinfo secrets, query and
    /// fragment replaced.
    pub display: String,
    /// The URL handed to git.
    pub git_url: String,
    /// The single path component under [`remote_cache_root`] the clone lives
    /// in. Derived from the repository identity, so two spellings of one repo
    /// share a clone and two repositories never do.
    pub cache_key: String,
    pub cache_dir: PathBuf,
}

impl RemoteSource {
    /// `Ok(None)` when `source` is not remote-shaped (a local path or bare
    /// name); `Err` when it is remote-shaped but must not be used.
    pub(crate) fn parse(source: &str) -> Result<Option<Self>> {
        let source = source.trim();
        if source.starts_with('~') {
            return Ok(None);
        }
        let url_shaped = is_url_shaped(source);
        let slug = config::parse_github_slug(source);
        if !url_shaped && slug.is_none() {
            return Ok(None);
        }
        let display = remote_source_display(source);
        // From here `source` is remote-shaped: every rejection below is a
        // refusal to use a source, never a verdict that it is a local path.
        if source.starts_with('-') {
            bail!(
                "remote source URLs must not start with `-`, which git reads as an option: {display}"
            );
        }
        if parse_remote_url(source).is_some_and(|url| {
            url.authority
                .chars()
                .any(|ch| ch.is_whitespace() || ch.is_control())
        }) {
            bail!(
                "remote source URLs must not carry whitespace or control characters in their authority: {display}"
            );
        }
        let git_url = if url_shaped {
            if is_plaintext_http(source) {
                bail!("plaintext HTTP remote sources are not supported: {display}");
            }
            reject_unsupported_transport(source)?;
            reject_credential_bearing_git_url(source)?;
            // Lowercased: the transport checks are case-insensitive, as URL
            // schemes are, but git is not — it reads `SSH://` as a request for
            // a `git-remote-SSH` helper. `git+ssh` is git's own alias for
            // `ssh`, so it collapses here too.
            match parse_remote_url(source) {
                Some(url) if !url.scheme.is_empty() => {
                    let scheme = url.scheme.to_ascii_lowercase();
                    let scheme = if scheme == "git+ssh" { "ssh" } else { &scheme };
                    format!("{scheme}://{}", &source[url.scheme.len() + 3..])
                }
                _ => source.to_string(),
            }
        } else if let Some(slug) = slug {
            // GitHub shorthand: built from the canonical slug, never from the
            // raw spelling — `owner/repo.git` would otherwise clone
            // `repo.git.git`, and `owner/repo/` would clone `repo/.git`.
            format!("https://github.com/{slug}.git")
        } else {
            return Ok(None);
        };
        let identity = remote_identity(&git_url).ok_or_else(|| {
            anyhow::anyhow!("remote source URL has no repository path: {display}")
        })?;
        let cache_key = cache_key_for_identity(&identity);
        Ok(Some(Self {
            cache_dir: remote_cache_root().join(&cache_key),
            display,
            git_url,
            cache_key,
        }))
    }
}

pub(crate) fn looks_like_remote_source(source: &str) -> bool {
    matches!(RemoteSource::parse(source), Ok(Some(_)) | Err(_))
}

pub(crate) fn remote_cache_root() -> PathBuf {
    config::global_base_dir().join(".vstack").join("cache")
}

/// `scheme://...` (any scheme, any case) or scp-like `user@host:path`.
fn is_url_shaped(source: &str) -> bool {
    parse_remote_url(source).is_some()
}

fn is_plaintext_http(source: &str) -> bool {
    parse_remote_url(source).is_some_and(|url| url.scheme.eq_ignore_ascii_case("http"))
}

/// The repository a URL names, independent of how it is spelled: a GitHub
/// slug for GitHub remotes in any form, otherwise
/// `transport://[user@]host/path` with host case, `.git` and trailing slashes
/// normalized.
///
/// The username and the transport are both part of a non-GitHub identity,
/// because on an arbitrary host each of them can select the repository: an
/// scp-like path is resolved relative to the account's home, so
/// `alice@host:repo` and `bob@host:repo` are two repositories, and nothing
/// says a host serves the same tree at one path over https and over ssh.
/// Dropping either gave two repositories one cache entry, and the origin check
/// — which asks this same question — then accepted either one's clone as the
/// other's source. Two spellings of one transport still agree:
/// `git@host:repo`, `ssh://git@host/repo` and `git+ssh://git@host/repo` are
/// one identity. GitHub is the exception it always was — `git@github.com` and
/// `https://github.com` are the same repository over two transports, which is
/// a fact about GitHub and not about hosts in general.
fn remote_identity(git_url: &str) -> Option<String> {
    let Some(url) = parse_remote_url(git_url) else {
        // The bare `owner/repo` shorthand, which is the one shape that parser
        // does not describe.
        return config::parse_github_slug(git_url).map(|slug| format!("github.com/{slug}"));
    };
    let path = url.path.trim_matches('/');
    let path = path
        .strip_suffix(".git")
        .unwrap_or(path)
        .trim_end_matches('/');
    if path.is_empty() {
        return None;
    }
    let host = url.host.to_ascii_lowercase();
    // GitHub owner and repository names are case-insensitive. Deciding that
    // from the host this parser reports, rather than from a second parser's
    // case-SENSITIVE prefix match, is what keeps `git@GitHub.com:Owner/Repo`
    // in the same cache entry as every other spelling of it.
    if host == "github.com" {
        return Some(format!("github.com/{}", path.to_ascii_lowercase()));
    }
    // The username only — the secret half of a `user:secret@` userinfo is
    // refused elsewhere, and this string is hashed into a cache key.
    let user = url
        .userinfo
        .split_once(':')
        .map_or(url.userinfo, |(u, _)| u);
    let user = if user.is_empty() {
        String::new()
    } else {
        format!("{user}@")
    };
    Some(format!("{}://{user}{host}/{path}", url.transport()))
}

/// A cache key is exactly one path component made of `[a-z0-9_-]`, so it can
/// never leave the cache root, and it names exactly one repository. The
/// readable prefix keeps the `owner_repo` shape the cache always used, but it
/// lowercases and collapses — `foo/bar_baz` and `foo_bar/baz` reduce to the
/// same text — so the digest of the full identity is what keeps two
/// repositories from sharing a clone.
fn cache_key_for_identity(identity: &str) -> String {
    let raw = identity.strip_prefix("github.com/").unwrap_or(identity);
    let mut prefix = String::with_capacity(raw.len());
    let mut last_was_sep = false;
    for ch in raw.chars() {
        let next = if ch.is_ascii_alphanumeric() {
            ch.to_ascii_lowercase()
        } else if ch == '-' {
            ch
        } else {
            '_'
        };
        if next == '_' {
            if last_was_sep {
                continue;
            }
            last_was_sep = true;
        } else {
            last_was_sep = false;
        }
        prefix.push(next);
    }
    let digest = format!("{:016x}", config::fnv1a(identity.as_bytes()));
    let prefix = prefix.trim_matches('_');
    // The prefix is readability; the digest is the identity. A `file://` or
    // self-hosted source with a deeply nested path can make the whole
    // identity longer than a filesystem's 255-byte name limit, at which point
    // `git clone` fails on a source that is perfectly valid — so the readable
    // half is bounded and the digest, which is what keeps two repositories
    // apart, is never truncated.
    const PREFIX_LIMIT: usize = 96;
    let prefix = match prefix.char_indices().nth(PREFIX_LIMIT) {
        Some((end, _)) => prefix[..end].trim_end_matches('_'),
        None => prefix,
    };
    match prefix {
        "" => digest,
        prefix => format!("{prefix}-{digest}"),
    }
}

/// Whether `remote`'s clone is on this machine.
///
/// A cache entry written by an earlier vstack under a different key is not
/// reused: the key derives from the repository identity now, and re-cloning is
/// one `vstack add` away. Every caller reports the absence with that command.
pub(crate) fn cache_entry_present(remote: &RemoteSource) -> bool {
    remote.cache_dir.join(".git").exists()
}

// ---------------------------------------------------------------------------
// Git invocations
//
// EVERY `git` process vstack runs is built by `hardened_git_command`: the cache
// commands here, the repository-identity reads in `path_safety`, the Pi
// package's HEAD read, the source-repository read in `config`, and `report`'s
// origin read. The update path runs `reset --hard`, and git will happily aim
// that at whatever an inherited `GIT_DIR`/`GIT_WORK_TREE`, a symlinked entry, a
// redirected `.git`, or the clone's own `core.worktree` names; the identity
// reads decide which repository an ownership boundary is judged against, and
// the same inherited variables answer for a different one. An inherited
// `GIT_CONFIG_*` names programs git RUNS (`core.fsmonitor`, `core.hooksPath`,
// `core.sshCommand`) for any of them. Every process here runs unattended, where
// a credential prompt is a hang. What differs between callers is how much of
// the environment is hostile: the cache is vstack's own repository, the project
// is the user's — see `GIT_CACHE_ONLY_ENV_VARS`.
// ---------------------------------------------------------------------------

/// Inherited git configuration no vstack command may run under, whichever
/// repository it asks about. The location variables each override the working
/// directory, so an inherited value — vstack invoked from a hook, or from a
/// shell that exported one — would answer for a repository that is not the one
/// being asked about. The `GIT_CONFIG_*` family injects arbitrary
/// configuration into the same command, including `core.fsmonitor`,
/// `core.hooksPath` and `core.sshCommand` — programs git runs, or hands vstack
/// back to re-export.
const GIT_INHERITED_ENV_VARS: &[&str] = &[
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_COMMON_DIR",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_NAMESPACE",
    // Every way an environment hands git configuration to the process it
    // starts. `GIT_CONFIG_PARAMETERS` is the one git sets ITSELF for every
    // subprocess of a `git -c key=value` invocation, so it is present in
    // exactly the hook environment this scrubbing exists for — and an injected
    // `core.sshCommand` was read back by `configured_ssh_command` and
    // re-exported to the fetch.
    "GIT_CONFIG_PARAMETERS",
    "GIT_CONFIG",
    "GIT_CONFIG_GLOBAL",
    "GIT_CONFIG_SYSTEM",
    "GIT_CONFIG_NOSYSTEM",
    // Clearing the count is what drops the indexed `GIT_CONFIG_KEY_n` /
    // `GIT_CONFIG_VALUE_n` pairs with it: git reads them only up to this
    // number, so without it they are not configuration at all.
    "GIT_CONFIG_COUNT",
    // Names the directory git runs its own helper programs from.
    "GIT_EXEC_PATH",
    // Names the template directory a `git clone`/`git init` copies into the
    // new repository — hooks included, and `post-checkout` runs as part of the
    // clone, before any check this module makes could see the entry.
    "GIT_TEMPLATE_DIR",
    // Both name a program run to obtain credentials, which is the same
    // inherited-program class as `core.sshCommand`. `GIT_TERMINAL_PROMPT=0`
    // does not neutralise them: an askpass program is used INSTEAD of the
    // terminal, not because of it.
    "GIT_ASKPASS",
    "SSH_ASKPASS",
];

/// Cleared for the cache only. Where the repository is vstack's own clone an
/// inherited discovery limit is hostile; for the user's own project it is
/// configuration, and clearing it changed the answer the callers that anchor
/// against a project fail closed on.
const GIT_CACHE_ONLY_ENV_VARS: &[&str] =
    &["GIT_CEILING_DIRECTORIES", "GIT_DISCOVERY_ACROSS_FILESYSTEM"];

/// A `git` process pinned to `dir`: the working directory decides the
/// repository, every inherited location and configuration override is cleared,
/// and no terminal prompt can be raised. Reads about the user's own project are
/// built here; the cache adds [`hardened_cache_git_command`], and network
/// commands add ssh batch mode via [`hardened_git_network_command`].
pub(crate) fn hardened_git_command(dir: &Path) -> std::process::Command {
    let mut command = std::process::Command::new("git");
    for key in GIT_INHERITED_ENV_VARS {
        command.env_remove(key);
    }
    command.env("GIT_TERMINAL_PROMPT", "0");
    command.current_dir(dir);
    command
}

/// [`hardened_git_command`] for a command about the cache, where vstack owns
/// the repository and every inherited answer about where one lives is hostile.
pub(crate) fn hardened_cache_git_command(dir: &Path) -> Result<std::process::Command> {
    let mut command = hardened_git_command(dir);
    for key in GIT_CACHE_ONLY_ENV_VARS {
        command.env_remove(key);
    }
    // A repository's `.git/hooks/` is a directory of programs git runs on its
    // own behalf — `reference-transaction` on every ref a fetch writes,
    // `post-checkout` on a reset — and unlike `core.hooksPath` it is not
    // configuration any check can inspect. Command-line `-c` outranks the
    // repository's config, so pointing the hook directory at a path that
    // cannot hold one is what makes the whole class unreachable. vstack's own
    // clone has no use for a hook.
    command.arg("-c");
    command.arg(format!("core.hooksPath={}", no_hooks_path()?.display()));
    Ok(command)
}

/// [`hardened_cache_git_command`] for a command that may open an ssh
/// connection. The ssh program git would choose is kept — `GIT_SSH_COMMAND`,
/// `GIT_SSH`, else the user's own `core.sshCommand` — and given its own
/// variant's noninteractive flag. A command carrying arguments of its own is
/// left exactly as the user wrote it; see [`batch_mode_ssh_command`].
///
/// `GIT_SSH_COMMAND` is always set, never left for git to resolve, because git
/// resolves it from the REPOSITORY's config too — and the repository here is a
/// cache entry, whose `.git/config` is cloned content. `core.sshCommand` there
/// names a program git runs, so an entry that passes every ownership check
/// could still execute one; `GIT_SSH_COMMAND` outranks it.
pub(crate) fn hardened_git_network_command(dir: &Path) -> Result<std::process::Command> {
    let mut command = hardened_cache_git_command(dir)?;
    command.env("GIT_SSH_COMMAND", network_ssh_command(dir));
    Ok(command)
}

/// The `GIT_SSH_COMMAND` [`hardened_git_network_command`] sets for `dir`, from
/// the inputs git itself would consult. Named so a test can assert the value
/// the command actually carries.
fn network_ssh_command(dir: &Path) -> String {
    batch_mode_ssh_command(
        std::env::var("GIT_SSH_COMMAND").ok().as_deref(),
        configured_ssh_command(dir).as_deref(),
        std::env::var("GIT_SSH").ok().as_deref(),
        std::env::var("GIT_SSH_VARIANT").ok().as_deref(),
        user_git_value(dir, "ssh.variant").as_deref(),
    )
}

/// `core.sshCommand` as the USER configured it.
fn configured_ssh_command(dir: &Path) -> Option<String> {
    user_git_value(dir, "core.sshCommand")
}

/// A git setting as the user wrote it — global config, then system — and never
/// as the repository at `dir` carries it.
///
/// The repository scope is skipped on purpose: these two keys select the
/// program git runs to open an ssh connection, and the only repository these
/// commands run in is a cache entry whose config vstack cloned rather than the
/// user wrote. `dir` still decides where the process runs, so a caller that
/// has one passes it; the answer does not depend on it.
fn user_git_value(dir: &Path, key: &str) -> Option<String> {
    ["--global", "--system"].into_iter().find_map(|scope| {
        let output = hardened_cache_git_command(dir)
            .ok()?
            .args(["config", scope, "--get", key])
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        let value = String::from_utf8_lossy(&output.stdout).trim().to_string();
        (!value.is_empty()).then_some(value)
    })
}

/// The ssh implementations git knows how to drive. They take different
/// noninteractive options, and `simple` takes no options at all — passing
/// OpenSSH's to any of the others breaks the connection outright.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SshVariant {
    OpenSsh,
    Plink,
    TortoisePlink,
    Simple,
}

impl SshVariant {
    /// An explicit `ssh.variant`. `auto` and unknown values fall through to
    /// detection, as they do in git.
    fn named(value: &str) -> Option<Self> {
        match value.trim().to_ascii_lowercase().as_str() {
            "ssh" => Some(Self::OpenSsh),
            "plink" | "putty" => Some(Self::Plink),
            "tortoiseplink" => Some(Self::TortoisePlink),
            "simple" => Some(Self::Simple),
            _ => None,
        }
    }

    /// Git's own auto-detection: the program's basename decides.
    fn detect(program: &str) -> Self {
        let program = program.trim_matches(['\'', '"']);
        let base = program.rsplit(['/', '\\']).next().unwrap_or(program);
        // Lowercased first: `PLINK.EXE` keeps its suffix through an
        // ASCII-exact strip and was detected as OpenSSH.
        let base = base.to_ascii_lowercase();
        let base = base.strip_suffix(".exe").unwrap_or(&base);
        match base {
            "tortoiseplink" => Self::TortoisePlink,
            "plink" | "putty" => Self::Plink,
            _ => Self::OpenSsh,
        }
    }

    fn batch_flag(self) -> Option<&'static str> {
        match self {
            Self::OpenSsh => Some("-o BatchMode=yes"),
            Self::Plink | Self::TortoisePlink => Some("-batch"),
            Self::Simple => None,
        }
    }
}

/// The `GIT_SSH_COMMAND` to set. Always a command, never `None`: leaving git
/// to resolve one lets the cache entry's own `core.sshCommand` name it.
///
/// The option is APPENDED to the command git would run. Git appends
/// `<host> git-upload-pack <path>` after the whole string, so a trailing option
/// stays ahead of the positionals — which is what lets a command carrying
/// arguments of its own (`ssh -i key`, `env FOO=bar ssh`) be made
/// noninteractive at all: inserting after its first token corrupted it, and
/// leaving it alone lost batch mode for the commonest spelling there is.
/// `GIT_TERMINAL_PROMPT=0` does not reach ssh's own host-key prompt, so that
/// is a hang waiting for a tty.
///
/// Appending means an explicit `-o BatchMode=no` earlier in the user's own
/// command wins, OpenSSH taking the first value it sees. That is the user's
/// instruction, and it is theirs to give.
///
/// No option is appended for the `simple` variant, which takes none at all;
/// for a `GIT_SSH` program, invoked with host and command arguments only; or
/// for a plink-family command carrying arguments, where an option's place is
/// the implementation's business. Those still pin the PROGRAM — leaving it
/// unset is what let the cache's own config choose one.
fn batch_mode_ssh_command(
    inherited_command: Option<&str>,
    configured_command: Option<&str>,
    inherited_program: Option<&str>,
    inherited_variant: Option<&str>,
    configured_variant: Option<&str>,
) -> String {
    fn non_empty(value: Option<&str>) -> Option<&str> {
        value.map(str::trim).filter(|v| !v.is_empty())
    }
    let explicit = non_empty(inherited_command).or_else(|| non_empty(configured_command));
    if let Some(program) = non_empty(inherited_program).filter(|_| explicit.is_none()) {
        // `GIT_SSH` names a PROGRAM, not a command line: git execs it with the
        // host and command arguments only. Quoted, so the shell that runs
        // `GIT_SSH_COMMAND` cannot resplit a path containing whitespace, and
        // with nothing appended, so the program keeps the argument list it
        // expects.
        return shell_quote(program);
    }
    let command = explicit.unwrap_or("ssh");
    let (program, arguments) = split_program_token(command);
    // `GIT_SSH_VARIANT` outranks `ssh.variant`, as it does in git.
    let variant = non_empty(inherited_variant)
        .and_then(SshVariant::named)
        .or_else(|| non_empty(configured_variant).and_then(SshVariant::named))
        .unwrap_or_else(|| SshVariant::detect(program));
    // Exhaustive over the variants, so a new one is a compile error here
    // rather than a connection silently losing batch mode.
    let flag = match variant {
        SshVariant::OpenSsh => variant.batch_flag(),
        SshVariant::Plink | SshVariant::TortoisePlink if arguments.trim().is_empty() => {
            variant.batch_flag()
        }
        // A plink-family command carrying its own arguments, and `simple`,
        // which takes no options at all.
        SshVariant::Plink | SshVariant::TortoisePlink | SshVariant::Simple => None,
    };
    match flag {
        Some(flag) => format!("{command} {flag}"),
        None => command.to_string(),
    }
}

/// One shell word. `GIT_SSH_COMMAND` is run through a shell, so a program path
/// carrying whitespace or shell metacharacters has to arrive as a single word.
///
/// Deliberately not [`crate::display::shell_arg`]: this word is EXECUTED, not
/// printed, so it must carry the path byte for byte rather than escape what a
/// terminal would act on.
fn shell_quote(word: &str) -> String {
    format!("'{}'", word.replace('\'', r"'\''"))
}

/// A command string split into its program token and the rest. A quoted token
/// is one token however much whitespace it contains.
fn split_program_token(command: &str) -> (&str, &str) {
    let end = match command.chars().next() {
        Some(quote @ ('\'' | '"')) => command[1..]
            .find(quote)
            .map(|index| index + 2)
            .unwrap_or(command.len()),
        _ => command.find(char::is_whitespace).unwrap_or(command.len()),
    };
    command.split_at(end)
}

/// The `git clone` that mints a fresh cache entry. The destination is named on
/// the command line, so this one runs from the cache root.
/// `dest` is the directory git writes into, which is the staging path rather
/// than the entry itself — see [`clone_cached_repo`].
fn cache_clone_command(remote: &RemoteSource, dest: &Path) -> Result<std::process::Command> {
    let mut command = hardened_git_network_command(&remote_cache_root())?;
    // `--` so a URL is never read as an option, whatever it starts with.
    command.args(["clone", "--depth", "1", "--", &remote.git_url]);
    command.arg(dest);
    Ok(command)
}

/// The remediation every refusal ends with. The redacted display and the
/// cache root are safe to print; the key is identity-derived and carries no
/// userinfo.
fn refusal(remote: &RemoteSource, what: &str) -> anyhow::Error {
    anyhow::anyhow!(
        "refusing cached source {}: {what}. Remove its cache entry `{}` under {} and re-run",
        remote.display,
        remote.cache_key,
        remote_cache_root().display()
    )
}

/// Refuse a cache entry whose contents are not vstack's own directory.
///
/// A symlinked entry, or one whose `.git` is a symlink or a `gitdir:` file, is
/// some other checkout's working tree — one with the same origin passes every
/// content check — so it must be neither read as the remote source nor be the
/// target of `reset --hard`. Filesystem checks only; see
/// [`ensure_cache_entry_is_owned`] for the git-level checks that guard updates.
pub(crate) fn reject_unowned_cache_entry(remote: &RemoteSource) -> Result<()> {
    let meta = std::fs::symlink_metadata(&remote.cache_dir)
        .with_context(|| format!("inspecting cached source {}", remote.display))?;
    if meta.file_type().is_symlink() {
        return Err(refusal(
            remote,
            "its cache entry is a symlink, and updating it would run destructive git commands outside the cache",
        ));
    }
    if !meta.is_dir() {
        return Err(refusal(remote, "its cache entry is not a directory"));
    }
    // `git clone` always leaves a real `.git` directory. A symlink or a
    // `gitdir:` file there redirects the repository metadata elsewhere, so
    // `reset --hard` would act on a worktree vstack does not own even though
    // the entry itself is a plain directory.
    let git_meta = std::fs::symlink_metadata(remote.cache_dir.join(".git")).with_context(|| {
        format!(
            "inspecting git metadata for cached source {}",
            remote.display
        )
    })?;
    if !git_meta.is_dir() || git_meta.file_type().is_symlink() {
        return Err(refusal(
            remote,
            "its cache entry does not own its git metadata",
        ));
    }
    Ok(())
}

/// The checks that decide whether a cache entry is vstack's to update: the
/// filesystem checks above, then two questions for git. Where would it act —
/// the cache's own `config` can carry a `core.worktree` pointing at a user
/// checkout, which no check on the entry or its `.git` sees, and `reset --hard`
/// would then overwrite the user's copies of the tracked files. And whose
/// clone is this — an entry whose `origin` is a different repository would be
/// installed as this source after the reset, and one whose `origin` carries a
/// credential would hand it to the fetch.
pub(crate) fn ensure_cache_entry_is_owned(remote: &RemoteSource) -> Result<()> {
    reject_unowned_cache_entry(remote)?;

    // Canonicalized on both sides: the cache root is routinely reached through
    // a symlinked home or temp directory. Anything git cannot answer fails
    // closed, naming which of the three ways it failed.
    let toplevel = hardened_cache_git_command(&remote.cache_dir)?
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .map_err(|err| refusal(remote, &format!("git could not be run to read it: {err}")))?;
    if !toplevel.status.success() {
        return Err(refusal(
            remote,
            &format!(
                "its work tree could not be read: {}",
                git_output_summary(&toplevel)
            ),
        ));
    }
    // The work tree is the user location this refuses to touch; it is not
    // printed, here or below.
    let resolved = PathBuf::from(git_stdout_line(&toplevel.stdout))
        .canonicalize()
        .map_err(|err| refusal(remote, &format!("its work tree does not resolve: {err}")))?;
    let expected = std::fs::canonicalize(&remote.cache_dir)
        .map_err(|err| refusal(remote, &err.to_string()))?;
    if resolved != expected {
        return Err(refusal(
            remote,
            "its git work tree does not resolve to its cache entry, and updating it would run destructive git commands outside the cache",
        ));
    }

    // A real `.git` DIRECTORY is still only half the answer: a `commondir`
    // file inside it points refs and objects at another repository's metadata,
    // which `--show-toplevel` does not see — it keeps answering with the cache.
    // The fetch then advances the other repository's remote-tracking refs and
    // writes its objects.
    let common = hardened_cache_git_command(&remote.cache_dir)?
        .args(["rev-parse", "--git-common-dir"])
        .output()
        .map_err(|err| refusal(remote, &format!("git could not be run to read it: {err}")))?;
    if !common.status.success() {
        return Err(refusal(
            remote,
            &format!(
                "its git metadata could not be read: {}",
                git_output_summary(&common)
            ),
        ));
    }
    // Git answers relatively from inside the repository and absolutely from
    // outside it; joining handles both, since an absolute path replaces.
    let resolved_common = remote
        .cache_dir
        .join(git_stdout_line(&common.stdout))
        .canonicalize()
        .map_err(|err| refusal(remote, &format!("its git metadata does not resolve: {err}")))?;
    let expected_common = expected
        .join(".git")
        .canonicalize()
        .map_err(|err| refusal(remote, &err.to_string()))?;
    if resolved_common != expected_common {
        return Err(refusal(
            remote,
            "its git metadata resolves outside its cache entry, and fetching it would write refs and objects into another repository",
        ));
    }

    reject_redirected_cache_metadata(remote)?;

    reject_unowned_cache_config(remote)?;

    let output = hardened_cache_git_command(&remote.cache_dir)?
        .args(["remote", "get-url", "origin"])
        .output()
        .with_context(|| format!("reading origin for cached source {}", remote.display))?;
    if !output.status.success() {
        return Err(refusal(
            remote,
            &format!(
                "its origin could not be read: {}",
                git_output_summary(&output)
            ),
        ));
    }
    let origin = git_stdout_line(&output.stdout);
    if remote_identity(&origin) != remote_identity(&remote.git_url) {
        return Err(refusal(
            remote,
            &format!(
                "its origin is {}, not this source",
                remote_source_display(&origin)
            ),
        ));
    }
    if let Err(err) = reject_credential_bearing_git_url(&origin) {
        return Err(refusal(
            remote,
            &format!("its origin carries a credential ({err})"),
        ));
    }
    // An entry minted before the transport policy — or by anything else — can
    // hold an origin vstack would refuse as a source. Fetching it would pull
    // this source's content over that transport anyway.
    if let Err(err) = reject_unsupported_transport(&origin) {
        return Err(refusal(remote, &format!("its origin is unusable ({err})")));
    }
    Ok(())
}

/// The revision an update brings a cache entry to, and the refspec that writes
/// it, both named on the command line.
///
/// Neither the entry's stored `remote.<name>.fetch` nor its `origin/HEAD` is
/// consulted: both are values inside the entry, and an altered refspec mapped
/// another branch onto `origin/main` while `origin/HEAD` is written once at
/// clone time and never updated by a fetch. Asking the REMOTE for its `HEAD`
/// on every fetch, into a ref only vstack writes, is what makes the revision a
/// fact about the source rather than about the cache.
pub(crate) const CACHE_HEAD_REF: &str = "refs/vstack/head";
pub(crate) const CACHE_HEAD_REFSPEC: &str = "+HEAD:refs/vstack/head";

/// Set the entry's `origin` to the URL this invocation selected.
///
/// Only ever called after [`ensure_cache_entry_is_owned`], so the entry is
/// already known to be this repository's clone and the URL has already been
/// through the credential and transport refusals: the write changes which
/// transport the same repository is reached over, nothing more.
pub(crate) fn point_cache_origin_at(remote: &RemoteSource) -> Result<()> {
    let output = hardened_cache_git_command(&remote.cache_dir)?
        .args(["remote", "set-url", "origin", "--", &remote.git_url])
        .output()
        .with_context(|| format!("setting origin for cached source {}", remote.display))?;
    if !output.status.success() {
        bail!(
            "setting origin for cached source {}: {}",
            remote.display,
            git_output_summary(&output)
        );
    }
    Ok(())
}

/// Refuse a cache entry whose git metadata is not entirely its own.
///
/// One walk rather than a guard per file: git follows a symlink anywhere under
/// `.git`, and every part of it is somewhere a command writes — `config` is
/// the file `remote set-url` edits, `refs` and `logs` are what a fetch
/// advances, `objects` is where it puts what it downloads. A link anywhere in
/// that tree points part of the repository at something vstack does not own,
/// and `--git-common-dir` only answers for the `.git` root. Symlinks are
/// refused rather than descended into, so the walk cannot leave the entry.
fn reject_redirected_cache_metadata(remote: &RemoteSource) -> Result<()> {
    let git_dir = remote.cache_dir.join(".git");
    let mut pending = vec![git_dir.clone()];
    while let Some(dir) = pending.pop() {
        let entries = std::fs::read_dir(&dir).map_err(|err| {
            refusal(
                remote,
                &format!("its git metadata could not be read: {err}"),
            )
        })?;
        for entry in entries {
            let path = entry
                .map_err(|err| {
                    refusal(
                        remote,
                        &format!("its git metadata could not be read: {err}"),
                    )
                })?
                .path();
            let meta = std::fs::symlink_metadata(&path).map_err(|err| {
                refusal(
                    remote,
                    &format!("its git metadata could not be read: {err}"),
                )
            })?;
            if meta.file_type().is_symlink() {
                // The linked path is a user location this refuses to touch and
                // is not printed; the entry-relative name is enough to find it.
                return Err(refusal(
                    remote,
                    &format!(
                        "its git metadata redirects {} elsewhere",
                        entry_name(&git_dir, &path)
                    ),
                ));
            }
            // A hard link is the same file reached by two names, with no link
            // to follow and nothing on the path to see: writing the entry's
            // `config`, its refs or its reflogs would write the other name's
            // file too. A clone writes every one of them fresh. Unix only — no
            // stable Rust API reports a link count on Windows.
            #[cfg(unix)]
            if meta.is_file() && std::os::unix::fs::MetadataExt::nlink(&meta) > 1 {
                return Err(refusal(
                    remote,
                    &format!(
                        "its git metadata shares {} with another file, and writing it would write that file",
                        entry_name(&git_dir, &path)
                    ),
                ));
            }
            if meta.is_dir() {
                pending.push(path);
            }
        }
    }

    // `.git/config` is the one file vstack WRITES by name, so it must be there
    // and be a plain file — a walk says nothing about a path that is missing.
    let meta = std::fs::symlink_metadata(git_dir.join("config")).map_err(|err| {
        refusal(
            remote,
            &format!("its git configuration could not be read: {err}"),
        )
    })?;
    if !meta.is_file() {
        return Err(refusal(
            remote,
            "its cache entry does not own its git configuration",
        ));
    }
    Ok(())
}

/// A metadata path as a refusal names it: relative to `.git`, and escaped. The
/// absolute path is a user location this never prints.
fn entry_name(git_dir: &Path, path: &Path) -> String {
    let relative = path.strip_prefix(git_dir).unwrap_or(path);
    escape_unprintable(&relative.display().to_string())
}

/// The `core.hooksPath` every cache command runs under: a REGULAR FILE, so no
/// `<hooksPath>/<name>` resolves to a hook on any platform.
///
/// A file rather than a missing path, because whoever can write the cache root
/// can create a directory at one; and rather than `/dev/null`, which is a
/// directory-shaped path on Windows.
fn no_hooks_path() -> Result<PathBuf> {
    // Recomputed rather than memoized: the cache root is derived from the home
    // directory, and a memo would outlive the answer.
    let root = remote_cache_root();
    std::fs::create_dir_all(&root)
        .with_context(|| format!("preparing the cache root {}", root.display()))?;
    let path = root.join(".no-hooks");
    match std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
    {
        Ok(_) => {}
        Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(err) => {
            bail!(
                "refusing to run git: {} could not be created to disable repository hooks: {err}",
                path.display()
            )
        }
    }
    // Whether this process created it or found it, it must still be a plain
    // file: a directory there is a hooks directory, and git would run what it
    // holds. Fail closed rather than run a command whose hooks are live.
    let meta = std::fs::symlink_metadata(&path).with_context(|| {
        format!(
            "refusing to run git: {} could not be inspected",
            path.display()
        )
    })?;
    if !meta.is_file() || meta.file_type().is_symlink() {
        bail!(
            "refusing to run git: {} must be a regular file so repository hooks cannot run; remove whatever is there and re-run",
            path.display()
        );
    }
    Ok(path)
}

/// The settings `git clone` itself writes, and nothing else.
///
/// A subsection is `*`: `remote.origin.url` normalizes to `remote.*.url`. The
/// list is deliberately short and platform-generous — the keys a clone writes
/// on Linux, macOS and Windows — because it is an ALLOWLIST. Nothing on it can
/// name a program or redirect where the repository lives.
const CACHE_CLONE_CONFIG_KEYS: &[&str] = &[
    "core.repositoryformatversion",
    "core.filemode",
    "core.bare",
    "core.logallrefupdates",
    "core.symlinks",
    "core.ignorecase",
    "core.precomposeunicode",
    "core.autocrlf",
    "core.eol",
    "remote.*.url",
    "remote.*.fetch",
    "remote.*.tagopt",
    "remote.*.mirror",
    "remote.*.promisor",
    "remote.*.partialclonefilter",
    "branch.*.remote",
    "branch.*.merge",
    // The repository-format extensions a clone records. Deliberately named one
    // by one: `extensions.worktreeconfig` enables a second config file this
    // check never sees.
    "extensions.objectformat",
    "extensions.compatobjectformat",
    "extensions.refstorage",
    "extensions.partialclone",
];

/// Refuse a cache entry whose own config carries settings vstack's clone did
/// not write.
///
/// The ownership checks above answer where the repository is; this one answers
/// what it will DO. A repository's config names programs git runs on its own
/// behalf — `core.fsmonitor`, `core.hooksPath`, a `filter.<driver>.smudge`
/// — and `fetch` and `reset --hard` run them. An allowlist rather than a list
/// of dangerous keys: the dangerous set grows with git, the set a clone writes
/// does not.
fn reject_unowned_cache_config(remote: &RemoteSource) -> Result<()> {
    let output = hardened_cache_git_command(&remote.cache_dir)?
        .args(["config", "--local", "--list", "--name-only"])
        .output()
        .map_err(|err| refusal(remote, &format!("git could not be run to read it: {err}")))?;
    if !output.status.success() {
        return Err(refusal(
            remote,
            &format!(
                "its configuration could not be read: {}",
                git_output_summary(&output)
            ),
        ));
    }
    let listed = String::from_utf8_lossy(&output.stdout);
    // An `include.path` is expanded by this listing, so a key pulled in from
    // another file is judged here too.
    for key in listed.lines().map(str::trim).filter(|key| !key.is_empty()) {
        if !CACHE_CLONE_CONFIG_KEYS.contains(&normalized_config_key(key).as_str()) {
            return Err(refusal(
                remote,
                &format!(
                    "its configuration sets {}, which `git clone` does not write and which git may act on when fetching or resetting",
                    escape_unprintable(key)
                ),
            ));
        }
    }
    Ok(())
}

/// A config key with its subsection replaced by `*` and its case normalized.
/// Git lowercases the section and the final key but preserves subsection case,
/// so only the two ends are compared.
fn normalized_config_key(key: &str) -> String {
    let section = key.split('.').next().unwrap_or(key).to_ascii_lowercase();
    let name = key.rsplit('.').next().unwrap_or(key).to_ascii_lowercase();
    match key.split('.').count() {
        0 | 1 => key.to_ascii_lowercase(),
        2 => format!("{section}.{name}"),
        // A subsection may itself contain dots (`branch.v1.2.merge`); every
        // part between the two ends is subsection.
        _ => format!("{section}.*.{name}"),
    }
}

/// Git's single-line stdout without the trailing newline — and only that, so a
/// path with legitimate trailing whitespace is left intact.
fn git_stdout_line(stdout: &[u8]) -> String {
    let text = String::from_utf8_lossy(stdout);
    let text = text.strip_suffix('\n').unwrap_or(&text);
    text.strip_suffix('\r').unwrap_or(text).to_string()
}

/// Bring a cache entry to its remote's `HEAD`.
///
/// Refuses an entry vstack does not own — that error propagates, because the
/// entry's contents are some other checkout's and must not be installed. A
/// failed fetch is tolerated: the clone is still the requested source at an
/// older revision, so it is kept and the reset skipped. A failed reset is an
/// error: the entry is no longer known to match any revision.
///
/// A user asked for this fetch, so it is unbounded and ignores the TTL.
///
/// The returned [`CacheLease`] is what keeps the entry still: discovery,
/// hashing and copying all read this tree AFTER the fetch, and the lease is
/// held until the caller drops it.
pub(crate) fn update_cached_repo(remote: &RemoteSource) -> Result<CacheLease> {
    update_cached_repo_bounded(remote, None, config::FetchBound::Unbounded)
}

/// [`update_cached_repo`] for a caller that is not willing to wait: a cache
/// fetched within `max_age` is left alone, and the fetch is killed at `bound`.
///
/// The mutation itself lives in [`config::lease_remote_cache`], the one place
/// an existing entry is fetched and reset, so the ownership proof, the lease,
/// the deadline and the stamp are one mechanism no caller halves.
pub(crate) fn update_cached_repo_bounded(
    remote: &RemoteSource,
    max_age: Option<std::time::Duration>,
    bound: config::FetchBound,
) -> Result<CacheLease> {
    let (attempt, lease) = config::lease_remote_cache(remote, max_age, bound)?;
    attempt.report(remote);
    Ok(lease)
}

/// Shallow-clone the remote into its cache entry, and lease it: the caller
/// reads what was cloned, and a concurrent `add` or `refresh` would otherwise
/// be free to fetch and `reset --hard` it mid-read.
///
/// The clone lands in a staging directory and is RENAMED into the entry, so
/// the entry itself appears whole or not at all. It is the one cache write no
/// lock can cover — the lock lives inside a `.git` that does not exist yet —
/// and a reader looks for exactly that `.git` to decide the cache is present.
/// Cloning in place therefore published a half-checked-out tree to every
/// concurrent reader, which is the same false "removed" a mid-`reset` tree
/// produces, with the same `vstack remove` printed beside it.
pub(crate) fn clone_cached_repo(remote: &RemoteSource) -> Result<CacheLease> {
    let root = remote_cache_root();
    std::fs::create_dir_all(&root)
        .with_context(|| format!("creating source cache {}", root.display()))?;
    // `git clone` FOLLOWS a symlink at its destination, writing the repository
    // into the link target — outside the cache root — and `add` then installs
    // from there, with the ownership refusal only arriving on a later refresh.
    // Every other write path proves the entry is vstack's own directory before
    // touching it; this is the one that did not.
    match std::fs::symlink_metadata(&remote.cache_dir) {
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
        Err(err) => {
            return Err(refusal(
                remote,
                &format!("its cache entry could not be inspected: {err}"),
            ));
        }
        Ok(meta) if meta.is_dir() => {
            let empty = std::fs::read_dir(&remote.cache_dir)
                .map(|mut entries| entries.next().is_none())
                .unwrap_or(false);
            if !empty {
                return Err(refusal(
                    remote,
                    "its cache entry already exists and is not an empty directory",
                ));
            }
        }
        Ok(_) => {
            return Err(refusal(
                remote,
                "its cache entry is not a directory vstack can clone into",
            ));
        }
    }
    // Dot-prefixed, so it can never be read as a cache key: every consumer of
    // the cache root skips dot entries, and a partial clone must not be one
    // any lookup can land on even by name. Keyed by pid as well, so two
    // processes cloning the same remote stage into different directories and
    // neither can delete the other's work in progress — and so a path left
    // behind by a killed clone is reclaimed rather than accumulating.
    let staging = root.join(format!(
        ".staging-{}-{}",
        remote.cache_key,
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&staging);
    let output = cache_clone_command(remote, &staging)?
        .stdout(std::process::Stdio::null())
        .output()
        .context("failed to run git clone — is git installed?")?;
    if !output.status.success() {
        let _ = std::fs::remove_dir_all(&staging);
        bail!(
            "git clone failed for {}: {}",
            remote.display,
            git_output_summary(&output)
        );
    }
    // The publish. `rename` onto a path that does not exist — or onto the
    // empty directory tolerated above — is atomic, so no reader ever sees the
    // entry in a state the clone was still building. A rename that fails means
    // somebody else published one first, and installing from a tree this run
    // did not clone is exactly what the ownership proofs exist to prevent.
    if let Err(err) = std::fs::rename(&staging, &remote.cache_dir) {
        let _ = std::fs::remove_dir_all(&staging);
        return Err(refusal(
            remote,
            &format!(
                "its cache entry could not be published ({err}); retry once no other vstack process is adding it"
            ),
        ));
    }
    // Nothing to fetch — the clone IS the newest revision — and everything to
    // hold: the caller discovers, hashes and copies out of this tree next.
    let (attempt, lease) = config::lease_cached_source(remote)?;
    attempt.report(remote);
    Ok(lease)
}

fn git_output_summary(output: &std::process::Output) -> String {
    git_error_summary(&output.stderr, &output.stdout)
}

/// [`git_output_summary`] over raw streams, for the bounded fetch — it kills
/// its child at a deadline and so never has an `Output` to hand over, but its
/// diagnostics must be redacted by exactly the same rules.
pub(crate) fn git_error_summary(stderr: &[u8], stdout: &[u8]) -> String {
    let stderr = String::from_utf8_lossy(stderr);
    let stdout = String::from_utf8_lossy(stdout);
    let combined = [stderr.trim(), stdout.trim()]
        .into_iter()
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join("\n");
    let sanitized = combined
        .split_whitespace()
        .map(redact_token)
        .collect::<Vec<_>>()
        .join(" ");
    if sanitized.is_empty() {
        "git exited without stderr".to_string()
    } else {
        sanitized
    }
}

/// Redact one whitespace-delimited token of git output: URLs (with or without
/// git's quoting around them) lose userinfo secrets and query/fragment;
/// anything else is left alone.
fn redact_token(token: &str) -> String {
    let start = token
        .find(|ch: char| ch.is_ascii_alphanumeric())
        .unwrap_or(0);
    let (prefix, rest) = token.split_at(start);
    // `rfind` reports where the character starts; the URL ends where it ends,
    // which is one byte later only for single-byte characters.
    let end = rest
        .char_indices()
        .rev()
        .find(|(_, ch)| !matches!(ch, '\'' | '"' | '.' | ',' | ';' | ':' | ')' | ']'))
        .map(|(index, ch)| index + ch.len_utf8())
        .unwrap_or(rest.len());
    let (url, suffix) = rest.split_at(end);
    // The same grammar every other question about a remote is asked of, rather
    // than a `://` test: the scp-like `user:secret@host:path` carries its
    // secret where no scheme separator appears, and git prints the remote it
    // failed on verbatim.
    if parse_remote_url(url).is_none() {
        return token.to_string();
    }
    format!("{prefix}{}{suffix}", remote_source_display(url))
}

#[cfg(test)]
mod tests;
