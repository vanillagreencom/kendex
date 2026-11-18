//! A local lane's grants: what its harness and everything it starts may
//! write inside agent-runtime's wrapper, derived at each launch from the
//! lane's request, its record and the settings, and the lane's private
//! folder the launch hands it files through. The kernel holds them; the
//! launch record names the answer, the seats and the token's handing.

use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::confine::{self, Answer, Grants, Host};
use agent_runtime::effects::prepare::LaunchHome;
use agent_runtime::harness::{Harness, HomeWrites};
use agent_runtime::host;
use serde_json::{Value, json};

use super::refused;
use crate::error::Result;
use crate::settings::Settings;

/// The grants as JSON, the lane's to read.
const GRANTS_FILE: &str = "grants.json";

/// The `gh` token the launch hands a confined lane, mode 0600, removed at
/// the close.
pub(crate) const GH_TOKEN_FILE: &str = "gh-token";

/// The Pi session bridge's folder: the lane's own, so its socket is out of
/// every other lane's reach and the overseer's `pi-bridge` names it.
const PI_BRIDGE_FOLDER: &str = "pi-bridge";

/// The variable the Pi session bridge and its client read their folder
/// from.
const PI_BRIDGE_VAR: &str = "PI_BRIDGE_DIR";

/// The user's runtime folder, whose sockets the wrapper hides.
const RUNTIME_DIR_VAR: &str = "XDG_RUNTIME_DIR";

/// Cargo's home, whose registry and git checkouts a build writes.
const CARGO_HOME_VAR: &str = "CARGO_HOME";

/// The user's cache folder.
const CACHE_HOME_VAR: &str = "XDG_CACHE_HOME";

/// agent-runtime's build cache where it is named.
const RUNTIME_CACHE_VAR: &str = "AGENT_RUNTIME_CACHE";

/// kendex's folder under the cache folder.
const KENDEX_CACHE: &str = "kendex";

/// agent-runtime's build cache under kendex's folder where
/// `AGENT_RUNTIME_CACHE` names none (`skills/agent-runtime/scripts/lib/key.sh`
/// `agent_runtime_cache`).
const RUNTIME_CACHE_DEFAULT: &str = "agent-runtime";

/// A confined lane's own runtime cache under its checkout's `tmp`: outside
/// its mailbox, which a close can archive, since a build there holds a
/// cargo target folder per key.
const OWN_RUNTIME_CACHE: &str = "runtime-cache";

/// How long `gh auth token` may take.
const GH_BOUND: Duration = Duration::from_secs(30);

/// The second-opinion roster where the setting names none: the script's
/// own default.
const DEFAULT_REVIEW_TARGETS: &str = "claude codex";

/// The lane's private folder: its mailbox under its root, made before the
/// window, written by the lane and its overseer alone.
pub(crate) fn folder(mail_root: &Path, item: &str) -> PathBuf {
    crate::marker::mailbox_path(mail_root, item)
}

/// What a launch grants, and what it writes before the window so the
/// grants stand: the token's text (never recorded), the settings files a
/// carve-out needs and the usage folder the room pick records in.
pub(super) struct Granted {
    pub grants: Grants,
    pub answer: Answer,
    /// The empty settings files a read-only carve-out needs where the seat
    /// holds none: bwrap refuses a carve-out whose file is absent, and a
    /// seat left writable there lets the lane write settings that run in
    /// the operator's next session.
    missing: Vec<(PathBuf, &'static str)>,
    usage: Option<PathBuf>,
    /// The item's own folder of the state directory, made before the window
    /// so its bind stands.
    item_dir: PathBuf,
    /// The folders made where absent so their binds stand: the read-only
    /// ones a lane could otherwise plant (those under the cache folder and
    /// the launch records' under the common git folder), and a read-only
    /// seat's session folders, which the harness could not make there.
    kept: Vec<PathBuf>,
    /// The folders `ORCH_LANE_WRITABLE` granted.
    lane_writable: Vec<PathBuf>,
    /// A confined lane's own runtime cache, which its line names as
    /// `AGENT_RUNTIME_CACHE`: the pre-window build and the lane's own
    /// runtime calls build there what the shared cache, read-only inside,
    /// does not hold.
    own_cache: Option<PathBuf>,
    /// The shared runtime cache whose binaries the own cache links.
    shared_cache: Option<PathBuf>,
    token: Option<String>,
    pi_bridge: Option<PathBuf>,
}

/// The settings file a seat of `harness` runs code from, and its empty
/// form: Codex's TOML configuration, every other harness's JSON settings.
fn settings_file(harness: Harness) -> (&'static str, &'static str) {
    match harness {
        Harness::Codex => ("config.toml", ""),
        Harness::Claude | Harness::Copilot | Harness::Pi => ("settings.json", "{}\n"),
    }
}

/// The harnesses whose accounts the lane's second opinion can run on: each
/// roster entry's, the stock Copilot entries Copilot's, and none of the
/// lane's own Claude or Codex, since the review never dispatches to the
/// session's own model. An entry of another harness names no seat.
fn review_harnesses(roster: Option<&str>, lane: Harness) -> Vec<Harness> {
    let mut harnesses = Vec::new();
    for entry in roster
        .unwrap_or(DEFAULT_REVIEW_TARGETS)
        .split(|c: char| c == ',' || c.is_whitespace())
        .map(str::to_ascii_lowercase)
    {
        let harness = match entry.as_str() {
            "claude" => Harness::Claude,
            "codex" => Harness::Codex,
            name if name == "copilot" || name.starts_with("pi-copilot") => Harness::Copilot,
            _ => continue,
        };
        let own = harness == lane && matches!(lane, Harness::Claude | Harness::Codex);
        if !own && !harnesses.contains(&harness) {
            harnesses.push(harness);
        }
    }
    harnesses
}

/// A path as the kernel resolves it, so a bind names the folder a link
/// leads to; `None` for one that does not stand.
fn resolved(path: &Path) -> Option<PathBuf> {
    std::fs::canonicalize(path).ok()
}

/// Where a read-only grant binds. A path that stands as a link binds the
/// file it leads to, read-only at that file's own path: bwrap mounts on no
/// link, and the harness reads through the link to the bound file. A
/// read-only bind grants no write wherever its file lies, and the
/// carve-outs follow every writable bind, so a target inside a writable
/// grant stays read-only too. The target binds wherever it lies, outside
/// the seat included: an operator's seat links its settings to the
/// operator's own, which the seat already reads. A link whose target cannot
/// be read, absent or refused, refuses `grant-link-unreadable` naming the
/// link: the harness could not read through it, and the lane could make an
/// absent target. Any other path binds where it stands, or where
/// [`Granted::write`] makes it.
fn read_only_bind(path: PathBuf) -> Result<PathBuf> {
    match std::fs::symlink_metadata(&path) {
        Ok(meta) if meta.file_type().is_symlink() => std::fs::canonicalize(&path)
            .and_then(|target| std::fs::File::open(&target).map(|_| target))
            .map_err(|e| {
                refused(
                    "grant-link-unreadable",
                    &[
                        ("path", &path.display().to_string()),
                        ("cause", &e.to_string()),
                    ],
                )
            }),
        Ok(_) | Err(_) => Ok(path),
    }
}

/// Where a read-only seat's session folder binds writable: a link binds the
/// folder it leads to, at that folder's own path, since bwrap mounts on no
/// link; one absent is made before the window. A link whose target does
/// not stand refuses `grant-link-unreadable` naming the link, and one that
/// cannot be read `grant-seats-unread`.
fn seat_folder(path: PathBuf, made: &mut Vec<PathBuf>) -> Result<PathBuf> {
    let failed = |key: &'static str, e: std::io::Error| {
        refused(
            key,
            &[
                ("path", &path.display().to_string()),
                ("cause", &e.to_string()),
            ],
        )
    };
    match std::fs::symlink_metadata(&path) {
        Ok(meta) if meta.file_type().is_symlink() => {
            std::fs::canonicalize(&path).map_err(|e| failed("grant-link-unreadable", e))
        }
        Ok(_) => Ok(path),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            made.push(path.clone());
            Ok(path)
        }
        Err(e) => Err(failed("grant-seats-unread", e)),
    }
}

/// The grants of a local launch of `item` on `harness` from `mail_root`
/// under `homes`: writable its checkout (the root, and the common git
/// folder of a linked worktree with its hooks, its configuration and the
/// launch records every lane's hook resolves read-only), the item's own
/// folder of the state directory, whose other entries stay read-only, and
/// the room pick's usage records; in the seats its own launch runs under and
/// every configured account of a harness its second opinion can run on,
/// what the seat's harness writes there ([`Harness::home_writes`]): a
/// read-only seat's session folders, or a seat whole with its settings file
/// and the code folders that stand read-only; the build caches under the home and
/// the folders `ORCH_LANE_WRITABLE` names, the shared runtime cache
/// read-only wherever they would hold it; the user's runtime folder
/// hidden; the display where the record holds `desktop`. A confined launch also
/// takes the `gh` token the operator's login answers now, handed through
/// the lane's private folder, and a runtime cache of its own in its tree. A confined launch whose worktree's `tmp`
/// leads outside it is refused `grant-tmp-linked`: the link's target is
/// shared, the state directory or another lane's folder among what it can
/// hold.
#[allow(
    clippy::disallowed_methods,
    reason = "the launch's reads of the paths it grants and of `gh auth token`, before the window; it writes nothing"
)]
pub(super) fn of(
    settings: &Settings,
    item: &str,
    mail_root: &Path,
    harness: Harness,
    account: Option<&Path>,
    homes: &LaunchHome,
    desktop: bool,
) -> Result<Granted> {
    let item = crate::marker::item_name(item)?;
    let checkout = crate::marker::checkout(mail_root)?;
    let root = resolved(&checkout.root).unwrap_or_else(|| checkout.root.clone());
    let answer = confine::answer(Host::this(), harness);
    let tmp = checkout.root.join("tmp");
    if answer == Answer::Confined
        && let Some(target) = resolved(&tmp).filter(|t| !t.starts_with(&root))
    {
        return Err(refused(
            "grant-tmp-linked",
            &[
                ("path", &tmp.display().to_string()),
                ("target", &target.display().to_string()),
            ],
        ));
    }
    let mut writable = vec![root.clone()];
    let mut read_only = Vec::new();
    let mut kept = Vec::new();
    if let Some(common) = resolved(&checkout.common) {
        if !common.starts_with(&root) {
            writable.push(common.clone());
        }
        for name in ["hooks", "config"] {
            if std::fs::symlink_metadata(common.join(name)).is_ok() {
                read_only.push(common.join(name));
            }
        }
        // The launcher alone writes these: a marker names the root another
        // lane's hook resolves.
        for name in ["lane-mail", "lane-launch"] {
            read_only.push(common.join(name));
            kept.push(common.join(name));
        }
    }
    let state = resolved(&settings.state_dir).unwrap_or_else(|| settings.state_dir.clone());
    let item_dir = crate::state::item_dir(&state, item);
    writable.push(item_dir.clone());
    let usage = settings.account_state.get()?.join("usage");
    writable.push(usage.clone());
    // The lane's own seats: the home it runs under (a private Codex home
    // links the account's credentials), the root its sessions are read
    // under, and the account it spends. A Pi lane's account is the Claude
    // seat it bills, or its own root, which the home names first.
    let billed = match harness {
        Harness::Pi => Harness::Claude,
        Harness::Claude | Harness::Codex | Harness::Copilot => harness,
    };
    let mut seats: Vec<(PathBuf, Harness)> = Vec::new();
    for (home, kind) in [
        (homes.named.as_deref(), harness),
        (homes.sessions.as_deref(), harness),
        (account, billed),
        (homes.account.as_deref(), billed),
    ] {
        if let Some(home) = home.and_then(resolved) {
            seats.push((home, kind));
        }
    }
    let accounts = settings.accounts.get()?;
    let mut notes = Vec::new();
    let configured = agent_runtime::accounts::listing::configured(
        &accounts.account_dirs,
        settings.home.as_deref(),
        &mut notes,
    )
    .map_err(|cause| refused("grant-seats-unread", &[("cause", &cause)]))?;
    let review = review_harnesses(settings.review_targets.as_deref(), harness);
    for (kind, dir) in configured {
        if review.contains(&kind)
            && let Some(dir) = resolved(Path::new(&dir))
        {
            seats.push((dir, kind));
        }
    }
    let mut missing = Vec::new();
    let mut seat_paths: Vec<PathBuf> = Vec::new();
    for (seat, kind) in seats {
        if seat_paths.contains(&seat) {
            continue;
        }
        let (name, empty) = settings_file(kind);
        let file = seat.join(name);
        let stands = std::fs::symlink_metadata(&file).is_ok();
        match kind.home_writes() {
            // The settings stay read-only where they stand: a link's target
            // can lie inside a writable grant.
            HomeWrites::Folders(folders) => {
                if stands {
                    read_only.push(file);
                }
                for folder in folders {
                    writable.push(seat_folder(seat.join(folder), &mut kept)?);
                }
            }
            HomeWrites::Whole(code) => {
                writable.push(seat.clone());
                if !stands {
                    missing.push((file.clone(), empty));
                }
                read_only.push(file);
                // A code folder binds read-only only where it stands: every
                // bwrap mount over an absent one makes its mount point in
                // the home on the host, and Pi stops at start over an empty
                // `hooks/`. The lane can make one that is absent.
                for entry in code {
                    let path = seat.join(entry);
                    if std::fs::symlink_metadata(&path).is_ok() {
                        read_only.push(path);
                    }
                }
            }
        }
        seat_paths.push(seat);
    }
    let home = settings
        .home
        .as_deref()
        .map(PathBuf::from)
        .filter(|h| h.is_absolute());
    let (caches, cache_kept) = build_caches(home.as_deref());
    writable.extend(caches);
    read_only.extend(cache_kept.iter().cloned());
    kept.extend(cache_kept);
    let lane_writable = lane_writable(
        settings.lane_writable.as_deref(),
        home.as_deref(),
        &seat_paths,
    )?;
    writable.extend(lane_writable.iter().cloned());
    // The shared runtime cache holds the binaries the overseer, the hooks
    // and every other lane run: read-only wherever a writable grant would
    // hold it, and made where absent so a lane cannot plant it.
    let shared_cache = shared_runtime_cache(home.as_deref());
    if let Some(shared) = &shared_cache
        && writable
            .iter()
            .chain(&seat_paths)
            .any(|grant| shared.starts_with(grant))
    {
        read_only.push(shared.clone());
        kept.push(shared.clone());
    }
    let own_cache = (answer == Answer::Confined).then(|| root.join("tmp").join(OWN_RUNTIME_CACHE));
    let private = folder(&root, item);
    let token = match answer {
        Answer::Confined => gh_token(),
        Answer::Unconfined { .. } => None,
    };
    let read_only = match answer {
        Answer::Confined => read_only
            .into_iter()
            .map(read_only_bind)
            .collect::<Result<Vec<_>>>()?,
        Answer::Unconfined { .. } => read_only,
    };
    let grants = Grants {
        writable,
        seats: seat_paths,
        read_only,
        runtime_dir: std::env::var_os(RUNTIME_DIR_VAR)
            .map(PathBuf::from)
            .filter(|dir| dir.is_absolute()),
        sockets: Vec::new(),
        desktop,
        gh_token: token.as_ref().map(|_| private.join(GH_TOKEN_FILE)),
        file: private.join(GRANTS_FILE),
    };
    Ok(Granted {
        grants,
        answer,
        missing,
        usage: Some(usage),
        item_dir,
        kept,
        lane_writable,
        own_cache,
        shared_cache,
        token,
        pi_bridge: (harness == Harness::Pi).then(|| private.join(PI_BRIDGE_FOLDER)),
    })
}

/// The folders [`of`] grants some lane writable beside its checkout: every
/// item's folder of the state directory, the usage records, every
/// configured account's seat, the build caches and `ORCH_LANE_WRITABLE`'s
/// folders, each resolved where it stands. A lane's registration reads them
/// to refuse a common git folder an earlier lane could have planted.
pub(crate) fn writable_beside_checkout(settings: &Settings) -> Result<Vec<PathBuf>> {
    let state = resolved(&settings.state_dir).unwrap_or_else(|| settings.state_dir.clone());
    let usage = settings.account_state.get()?.join("usage");
    let home = settings
        .home
        .as_deref()
        .map(PathBuf::from)
        .filter(|h| h.is_absolute());
    let mut folders = vec![
        crate::state::items_dir(&state),
        resolved(&usage).unwrap_or(usage),
    ];
    let configured = agent_runtime::accounts::listing::configured(
        &settings.accounts.get()?.account_dirs,
        settings.home.as_deref(),
        &mut Vec::new(),
    )
    .map_err(|cause| refused("grant-seats-unread", &[("cause", &cause)]))?;
    folders.extend(
        configured
            .into_iter()
            .filter_map(|(_, dir)| resolved(Path::new(&dir))),
    );
    folders.extend(build_caches(home.as_deref()).0);
    folders.extend(lane_writable(
        settings.lane_writable.as_deref(),
        home.as_deref(),
        &[],
    )?);
    Ok(folders)
}

/// The variable a variable-named folder is read from, absolute only.
fn env_dir(name: &str) -> Option<PathBuf> {
    std::env::var_os(name)
        .map(PathBuf::from)
        .filter(|dir| dir.is_absolute())
}

/// The build caches a lane's validation writes under the home, shared with
/// the operator, each where it stands: cargo's registry and git checkouts
/// (never its `bin`, which the operator's shell runs), npm's, and the cache
/// folder. Beside them kendex's folder under the cache folder, which holds
/// what a controller or the operator installs from (`crates/core/src/env.rs`
/// `source_cache_dir`, `registry_cache_dir`, the app update), read-only and
/// made where absent so a lane cannot plant one.
#[allow(
    clippy::disallowed_methods,
    reason = "the launch reads which cache folders stand before the window; it writes nothing"
)]
fn build_caches(home: Option<&Path>) -> (Vec<PathBuf>, Vec<PathBuf>) {
    let cargo = env_dir(CARGO_HOME_VAR).or_else(|| home.map(|h| h.join(".cargo")));
    let cache = cache_folder(home);
    let mut caches: Vec<PathBuf> = Vec::new();
    if let Some(cargo) = &cargo {
        caches.extend([cargo.join("registry"), cargo.join("git")]);
    }
    caches.extend(home.map(|h| h.join(".npm")));
    caches.extend(cache.clone());
    let caches: Vec<PathBuf> = caches.iter().filter_map(|dir| resolved(dir)).collect();
    let kept = cache
        .as_deref()
        .and_then(resolved)
        .map(|cache| cache.join(KENDEX_CACHE))
        .into_iter()
        .collect();
    (caches, kept)
}

/// The user's cache folder: `XDG_CACHE_HOME`, else `~/.cache`.
fn cache_folder(home: Option<&Path>) -> Option<PathBuf> {
    env_dir(CACHE_HOME_VAR).or_else(|| home.map(|h| h.join(".cache")))
}

/// The shared runtime cache the launcher's own runtime calls build into, as
/// `skills/agent-runtime/scripts/lib/key.sh` `agent_runtime_cache` names it:
/// `AGENT_RUNTIME_CACHE`, else `kendex/agent-runtime` under the cache folder.
fn shared_runtime_cache(home: Option<&Path>) -> Option<PathBuf> {
    let dir = env_dir(RUNTIME_CACHE_VAR).or_else(|| {
        cache_folder(home).map(|cache| cache.join(KENDEX_CACHE).join(RUNTIME_CACHE_DEFAULT))
    })?;
    Some(resolved(&dir).unwrap_or(dir))
}

/// `ORCH_LANE_WRITABLE`'s folders, as the overseer's settings name them
/// (never the lane's tree, so a lane cannot widen its own grants): each an
/// absolute or `~/` path, bound where it stands. An entry that is relative,
/// the home or a folder holding it, or inside a seat refuses the launch.
#[allow(
    clippy::disallowed_methods,
    reason = "the launch reads which of the setting's folders stand before the window; it writes nothing"
)]
fn lane_writable(
    setting: Option<&str>,
    home: Option<&Path>,
    seats: &[PathBuf],
) -> Result<Vec<PathBuf>> {
    let home = home.map(|h| resolved(h).unwrap_or_else(|| h.to_path_buf()));
    let mut granted = Vec::new();
    for entry in setting.unwrap_or("").split(':').filter(|e| !e.is_empty()) {
        let refuse = |key: &'static str| refused(key, &[("entry", entry)]);
        let path = match (entry.strip_prefix("~/"), &home) {
            (Some(rest), Some(home)) => home.join(rest),
            (None, _) if Path::new(entry).is_absolute() => PathBuf::from(entry),
            (Some(_), None) | (None, _) => return Err(refuse("lane-writable-relative")),
        };
        let path = resolved(&path).unwrap_or(path);
        if home.as_deref().is_some_and(|home| home.starts_with(&path)) {
            return Err(refuse("lane-writable-home"));
        }
        if let Some(seat) = seats.iter().find(|seat| path.starts_with(seat)) {
            return Err(refused(
                "lane-writable-seat",
                &[("entry", entry), ("seat", &seat.display().to_string())],
            ));
        }
        if std::fs::symlink_metadata(&path).is_ok() && !granted.contains(&path) {
            granted.push(path);
        }
    }
    Ok(granted)
}

/// The token the operator's `gh` login answers, `None` where it answers
/// none: the lane then launches without one, as its record says.
#[allow(
    clippy::disallowed_methods,
    reason = "the launch's one read of the operator's `gh` token, handed to the lane it confines"
)]
fn gh_token() -> Option<String> {
    let out = host::run(
        "gh",
        Path::new("gh"),
        "auth-token",
        &["auth", "token"],
        GH_BOUND,
    )
    .ok()?;
    let token = host::stdout_text(&out).trim().to_owned();
    (out.status.success() && !token.is_empty()).then_some(token)
}

impl Granted {
    /// The variables the lane's launch line sets for its grants: the Pi
    /// bridge's folder and the lane's own runtime cache.
    pub fn env(&self) -> Vec<(String, String)> {
        [
            (PI_BRIDGE_VAR, &self.pi_bridge),
            (RUNTIME_CACHE_VAR, &self.own_cache),
        ]
        .into_iter()
        .filter_map(|(name, dir)| {
            dir.as_ref()
                .map(|dir| (name.to_owned(), dir.display().to_string()))
        })
        .collect()
    }

    /// What the launch record says of the grants: the answer, the seats it
    /// runs on, the display, whether a token was handed, and the Pi
    /// bridge's folder.
    pub fn record(&self) -> Value {
        let mut record = json!({
            "confinement": self.answer,
            "seats": self.grants.seats,
            "desktop": self.grants.desktop,
        });
        if self.answer == Answer::Confined {
            record["gh_token"] = json!(if self.token.is_some() {
                "handed"
            } else {
                "none"
            });
        }
        if let Some(dir) = &self.pi_bridge {
            record["pi_bridge_dir"] = json!(dir);
        }
        if !self.lane_writable.is_empty() {
            record["lane_writable"] = json!(self.lane_writable);
        }
        record
    }

    /// Write what the grants stand on before the window: the usage folder,
    /// the item's own folder, the read-only folders, each absent settings
    /// file in its empty form, the lane's own runtime cache, and the token
    /// at mode 0600 in the lane's private folder, which the marker made.
    #[allow(
        clippy::disallowed_methods,
        reason = "the launch writes the files its grants bind before the window opens; the token's file is the lane's own, at mode 0600"
    )]
    pub fn write(&self) -> Result<()> {
        use std::io::Write as _;
        use std::os::unix::fs::OpenOptionsExt as _;
        let failed = |path: &Path, e: std::io::Error| {
            refused(
                "grant-write-failed",
                &[
                    ("path", &path.display().to_string()),
                    ("cause", &e.to_string()),
                ],
            )
        };
        if self.answer != Answer::Confined {
            return Ok(());
        }
        if let Some(usage) = &self.usage {
            std::fs::create_dir_all(usage).map_err(|e| failed(usage, e))?;
        }
        std::fs::create_dir_all(&self.item_dir).map_err(|e| failed(&self.item_dir, e))?;
        for dir in &self.kept {
            std::fs::create_dir_all(dir).map_err(|e| failed(dir, e))?;
        }
        for (file, empty) in &self.missing {
            match std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(file)
            {
                Ok(mut f) => f.write_all(empty.as_bytes()).map_err(|e| failed(file, e))?,
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
                Err(e) => return Err(failed(file, e)),
            }
        }
        if let Some(own) = &self.own_cache {
            own_runtime_cache(own, self.shared_cache.as_deref())?;
        }
        if let (Some(token), Some(path)) = (&self.token, &self.grants.gh_token) {
            remove_token(path)?;
            let mut f = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(path)
                .map_err(|e| failed(path, e))?;
            f.write_all(token.as_bytes()).map_err(|e| failed(path, e))?;
        }
        Ok(())
    }
}

/// The lane's own runtime cache made before the window, with each binary of
/// the shared cache's `bin` linked into its own `bin` where it holds none of
/// that name: setup, run once under the lane's words, then finds a key the
/// shared cache holds and builds nothing, and builds one it lacks here. The
/// launcher names no key, so the key's one rule stays `key.sh`'s. A folder
/// that stands as a link is refused: the lane can plant one in its tree,
/// and the launcher writes through none.
#[allow(
    clippy::disallowed_methods,
    reason = "the launcher makes the lane's own cache and its links to the shared binaries before the window"
)]
fn own_runtime_cache(own: &Path, shared: Option<&Path>) -> Result<()> {
    let failed = |path: &Path, cause: &str| {
        refused(
            "grant-write-failed",
            &[("path", &path.display().to_string()), ("cause", cause)],
        )
    };
    let bin = own.join("bin");
    for dir in [own, bin.as_path()] {
        match std::fs::create_dir(dir) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(failed(dir, &e.to_string())),
        }
        if !std::fs::symlink_metadata(dir).is_ok_and(|meta| meta.is_dir()) {
            return Err(failed(dir, "not-a-folder"));
        }
    }
    let Some(shared) = shared else {
        return Ok(());
    };
    let shared_bin = shared.join("bin");
    let entries = match std::fs::read_dir(&shared_bin) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(failed(&shared_bin, &e.to_string())),
    };
    for entry in entries {
        let name = entry
            .map_err(|e| failed(&shared_bin, &e.to_string()))?
            .file_name();
        // A dot name is setup's temporary copy, not yet a binary.
        if name.as_encoded_bytes().starts_with(b".") {
            continue;
        }
        let link = bin.join(&name);
        match std::os::unix::fs::symlink(shared_bin.join(&name), &link) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(failed(&link, &e.to_string())),
        }
    }
    Ok(())
}

/// Remove a lane's token file: at a launch before it writes a fresh one,
/// and at the close. One that is gone is nothing to do.
#[allow(
    clippy::disallowed_methods,
    reason = "the lane's token file is removed by the launch that wrote it and by the lane's close"
)]
pub(crate) fn remove_token(path: &Path) -> Result<()> {
    match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(refused(
            "grant-write-failed",
            &[
                ("path", &path.display().to_string()),
                ("cause", &e.to_string()),
            ],
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_review_names_the_roster_s_other_harnesses() {
        assert_eq!(
            review_harnesses(None, Harness::Codex),
            vec![Harness::Claude]
        );
        assert_eq!(
            review_harnesses(Some("codex, pi-copilot-gpt opencode"), Harness::Pi),
            vec![Harness::Codex, Harness::Copilot]
        );
        assert!(review_harnesses(Some(""), Harness::Claude).is_empty());
    }
}
