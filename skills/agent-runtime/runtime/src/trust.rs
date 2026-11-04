//! The folder-trust record a harness reads before it reads the arguments it
//! was launched with, made before an unattended launch so the session never
//! opens on `Do you trust the contents of this directory?` with nobody at
//! the pane to answer. Codex reads `[projects."<dir>"] trust_level =
//! "trusted"` in the config.toml of its `CODEX_HOME`; Claude reads
//! `projects.<dir>.hasTrustDialogAccepted` in the `.claude.json` of its
//! config dir; Copilot's trust is the launch line's `COPILOT_ALLOW_ALL=true`
//! on a full bypass, and what its home must hold before a fleet session
//! starts is the kendex context reader: the `kendex-lane-context` extension
//! under `extensions/`, loaded only while `enabledFeatureFlags.EXTENSIONS`
//! is true in its settings.json, and the directory the reader leaves each
//! session's pending marker in; Pi asks none.
//!
//! A numbered Codex account's config.toml is a link the account shim repoints
//! at every launch, so an entry written there is gone by the next one: the
//! launch gets a `CODEX_HOME` of its own under the account, holding the
//! account's files by link and one config.toml of its own carrying the
//! account's config plus the entry. Claude's `.claude.json` is the account's
//! own state, the file the harness writes its own answer into, so the entry
//! goes there and the launch runs under the config dir itself.
//!
//! An answer already recorded for the directory that is not trust refuses
//! on both arms: it is a decision somebody gave in the harness's own
//! spelling, and overwriting it would run the launch at full trust against
//! that answer.

use std::ffi::OsStr;
use std::fs;
use std::io::ErrorKind;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt, symlink};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::error::{Error, Result};
use crate::harness::Harness;

/// The Copilot context reader a fleet session loads: the extension the
/// launch installs into the lane's Copilot home.
const EXTENSION: &str = include_str!("copilot-lane-context.mjs");

/// The age past which a status-line session record is stale, in seconds,
/// the bound the record's readers apply.
const STATUS_LINE_MAX_AGE_S: u64 = 120;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Route {
    /// The harness asks no such question.
    None,
    /// Copilot: the launch line grants folder trust through
    /// `COPILOT_ALLOW_ALL=true` on a full bypass, so nothing is written.
    AllowAllEnv,
    /// The account's own config already trusts the directory.
    Preapproved,
    /// A private Codex home carrying the entry.
    LaunchHome,
    /// The entry written into the Claude config dir's own `.claude.json`.
    AccountConfig,
}

/// What a launch runs under once the trust record stands.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Prepared {
    pub route: Route,
    /// The account home, or the private Codex home built under it.
    pub home: PathBuf,
}

/// Make the trust entry for `launch_dir` exist in the config a launch of
/// `harness` under `home` will read, and say which home that is. A refusal
/// is the launch-readiness answer: `trust-refused` for a recorded answer
/// that is not trust, `config-unreadable` for a config that exists and
/// cannot be read or parsed, and the write's own failure otherwise.
pub fn prepare(harness: Harness, home: &Path, launch_dir: &Path) -> Result<Prepared> {
    match harness {
        Harness::Codex => codex(home, launch_dir),
        Harness::Claude => claude(home, launch_dir),
        Harness::Copilot => copilot(home, pending_dir().as_deref()),
        Harness::Pi => Ok(Prepared {
            route: Route::None,
            home: home.to_path_buf(),
        }),
    }
}

/// The home [`prepare`] names for a launch of `harness` under `home` in
/// `launch_dir`, read without writing anything, for a launch that already
/// ran on it.
pub fn prepared_home(harness: Harness, home: &Path, launch_dir: &Path) -> Result<PathBuf> {
    match harness {
        Harness::Codex => Ok(codex_route(home, launch_dir)?.home),
        Harness::Claude | Harness::Copilot | Harness::Pi => Ok(home.to_path_buf()),
    }
}

/// Where one launch directory's private Codex home sits under the account:
/// `<account>/lane-launch/<leaf>-<cksum>/home`. The leaf is the launch
/// directory's basename with every byte outside `A-Za-z0-9._-` made `_`,
/// for an operator reading `ps`, and the checksum is the POSIX `cksum` of
/// the whole path, because two worktrees of one repository share a
/// basename. The last component is the fixed word `home`, never a name
/// derived from the account, so an account launcher on `PATH` named for the
/// account never matches it. `account_of` takes the path back apart.
pub fn home_path(account: &Path, launch_dir: &Path) -> PathBuf {
    let dir = launch_dir.as_os_str().as_bytes();
    let base = launch_dir.file_name().map_or(dir, OsStr::as_bytes);
    let leaf: String = base
        .iter()
        .map(|&b| {
            if b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-') {
                b as char
            } else {
                '_'
            }
        })
        .collect();
    account
        .join("lane-launch")
        .join(format!("{leaf}-{}", cksum(dir)))
        .join("home")
}

/// The account a launched home belongs to: the path itself, or the account
/// a private launch home was built under. A reader holding a `CODEX_HOME`
/// asks which account is spent; a home built under an account is that
/// account.
pub fn account_of(path: &Path) -> &Path {
    let bytes = path.as_os_str().as_bytes();
    let Some(prefix) = bytes.strip_suffix(b"/home") else {
        return path;
    };
    match prefix
        .windows(b"/lane-launch/".len())
        .rposition(|w| w == b"/lane-launch/")
    {
        Some(at) => Path::new(OsStr::from_bytes(&bytes[..at])),
        None => path,
    }
}

/// The POSIX `cksum` of `data`: CRC-32 over the bytes then the length,
/// complemented, the figure the shell's `cksum` prints first.
fn cksum(data: &[u8]) -> u32 {
    const fn table() -> [u32; 256] {
        let mut table = [0u32; 256];
        let mut i = 0;
        while i < 256 {
            let mut crc = (i as u32) << 24;
            let mut bit = 0;
            while bit < 8 {
                crc = if crc & 0x8000_0000 != 0 {
                    (crc << 1) ^ 0x04C1_1DB7
                } else {
                    crc << 1
                };
                bit += 1;
            }
            table[i] = crc;
            i += 1;
        }
        table
    }
    const TABLE: [u32; 256] = table();
    let mut crc: u32 = 0;
    for &byte in data {
        crc = (crc << 8) ^ TABLE[((crc >> 24) ^ u32::from(byte)) as usize];
    }
    let mut len = data.len();
    while len > 0 {
        crc = (crc << 8) ^ TABLE[((crc >> 24) ^ (len as u32 & 0xff)) as usize];
        len >>= 8;
    }
    !crc
}

fn refused(key: &'static str, harness: Harness, path: &Path, cause: Option<&str>) -> Error {
    let path = path.display().to_string();
    match cause {
        Some(cause) => Error::refused(
            key,
            &[
                ("harness", harness.name()),
                ("path", &path),
                ("cause", cause),
            ],
        ),
        None => Error::refused(key, &[("harness", harness.name()), ("path", &path)]),
    }
}

/// Whether a config file stands: absent, readable, or present and not a
/// readable file (a dangling link included, which a readability test alone
/// would read as absence and rebuild the config from nothing).
enum Present {
    Absent,
    File,
    Unreadable(String),
}

fn present(path: &Path) -> Present {
    match fs::symlink_metadata(path) {
        Err(e) if e.kind() == ErrorKind::NotFound => Present::Absent,
        Err(e) => Present::Unreadable(e.to_string()),
        Ok(_) => match fs::metadata(path) {
            Ok(m) if m.is_file() => Present::File,
            Ok(_) => Present::Unreadable("not a regular file".to_owned()),
            Err(e) => Present::Unreadable(e.to_string()),
        },
    }
}

/// The text of a file that `present` read as a file.
fn read(path: &Path, harness: Harness) -> Result<String> {
    fs::read_to_string(path)
        .map_err(|e| refused("config-unreadable", harness, path, Some(&e.to_string())))
}

/// The step of [`install`] that failed.
enum Step {
    Write,
    Rename,
}

/// Write `text` to `path` through a staged file beside it, private whatever
/// the caller's umask, since the files a launch prepares hold an account's
/// state and the harnesses keep them 0600; renamed over the target so a
/// harness reading the file meets the whole previous file or the whole new
/// one.
fn install(path: &Path, text: &str) -> std::result::Result<(), (Step, std::io::Error)> {
    let staged = path.with_file_name(format!(
        "{}.{}",
        path.file_name().and_then(OsStr::to_str).unwrap_or("file"),
        std::process::id()
    ));
    let written = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&staged)
        .and_then(|mut f| std::io::Write::write_all(&mut f, text.as_bytes()));
    if let Err(e) = written {
        let _ = fs::remove_file(&staged);
        return Err((Step::Write, e));
    }
    if let Err(e) = fs::rename(&staged, path) {
        let _ = fs::remove_file(&staged);
        return Err((Step::Rename, e));
    }
    Ok(())
}

/// A trust config through [`install`], its failure the arm's refusal.
fn install_config(path: &Path, text: &str, harness: Harness) -> Result<()> {
    install(path, text).map_err(|(step, e)| {
        let key = match step {
            Step::Write => "config-write",
            Step::Rename => "config-install",
        };
        refused(key, harness, path, Some(&e.to_string()))
    })
}

fn private_dir(path: &Path, key: &'static str, harness: Harness) -> Result<()> {
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path)
        .map_err(|e| refused(key, harness, path, Some(&e.to_string())))
}

// ---------------------------------------------------------------------------
// Codex
// ---------------------------------------------------------------------------

/// What a Codex config says about opening into `dir`: `Some(true)` trusted
/// outright, `Some(false)` an answer for the directory that is not trust,
/// `None` the config does not say (no file, no table, no key).
fn codex_trusted(config: &Path, dir: &Path, harness: Harness) -> Result<Option<bool>> {
    let text = match present(config) {
        Present::Absent => return Ok(None),
        Present::Unreadable(cause) => {
            return Err(refused("config-unreadable", harness, config, Some(&cause)));
        }
        Present::File => read(config, harness)?,
    };
    Ok(toml_value(&text, &codex_section(dir), "trust_level").map(|v| v == "trusted"))
}

fn codex_section(dir: &Path) -> String {
    format!("projects.\"{}\"", dir.display())
}

/// Which home a Codex launch under `home_given` in `dir` runs on, read and
/// nothing written: the account where its own config trusts `dir`, else the
/// private home under it.
fn codex_route(home_given: &Path, dir: &Path) -> Result<Prepared> {
    let h = Harness::Codex;
    // The account, never a private home: a caller inside a launched session
    // reads its own `CODEX_HOME` to name its lane, and a home taken raw here
    // would hold the next home inside it, one level deeper per launch.
    let account = account_of(home_given);
    if account.as_os_str().is_empty() {
        return Err(refused("home-path", h, home_given, None));
    }
    let home = home_path(account, dir);
    // Both configs a launch here can open: the private home is where the
    // launch-home route points `CODEX_HOME`, so it is where Codex writes the
    // answer somebody gives at the pane.
    let in_account = codex_trusted(&account.join("config.toml"), dir, h)?;
    let in_home = codex_trusted(&home.join("config.toml"), dir, h)?;
    if in_account == Some(false) || in_home == Some(false) {
        return Err(refused("trust-refused", h, dir, None));
    }
    // `preapproved` is the account's own answer and only the account's: a
    // `trusted` in the private home is this preparation's own earlier write.
    Ok(if in_account == Some(true) {
        Prepared {
            route: Route::Preapproved,
            home: account.to_path_buf(),
        }
    } else {
        Prepared {
            route: Route::LaunchHome,
            home,
        }
    })
}

fn codex(home_given: &Path, dir: &Path) -> Result<Prepared> {
    let h = Harness::Codex;
    let route = codex_route(home_given, dir)?;
    if route.route == Route::Preapproved {
        return Ok(route);
    }
    let account = account_of(home_given);
    let config = account.join("config.toml");
    let home = route.home;
    let private = home.join("config.toml");
    private_dir(&home, "home-create", h)?;
    // The transcript store belongs to the account: the harness creates what
    // is missing under the home it is given, and a rollout written inside
    // the private home is one no relaunch scan finds. Made in the account
    // first so the loop below links it like any other entry.
    private_dir(&account.join("sessions"), "account-store", h)?;
    // The account's own files by link, never by copy: a token the harness
    // renews under this lane is renewed in the account's auth.json. The
    // config is written below and `lane-launch` holds this home, so linking
    // it in would nest the tree inside itself.
    let entries = fs::read_dir(account)
        .map_err(|e| refused("home-link", h, account, Some(&e.to_string())))?;
    for entry in entries {
        let entry = entry.map_err(|e| refused("home-link", h, account, Some(&e.to_string())))?;
        let name = entry.file_name();
        if name == "config.toml" || name == "lane-launch" {
            continue;
        }
        let target = home.join(&name);
        match fs::symlink_metadata(&target) {
            Ok(m) if m.is_dir() => {
                // Codex can create a plugins directory under the home before
                // the account has that entry; it stays, data of an unknown
                // producer included. Any other real directory refuses: a
                // link made inside it would add a level at every launch.
                if name == "plugins" {
                    continue;
                }
                return Err(refused("home-entry", h, &target, None));
            }
            Ok(_) => {
                fs::remove_file(&target)
                    .map_err(|e| refused("home-link", h, &target, Some(&e.to_string())))?;
            }
            Err(e) if e.kind() == ErrorKind::NotFound => {}
            Err(e) => return Err(refused("home-link", h, &target, Some(&e.to_string()))),
        }
        symlink(entry.path(), &target)
            .map_err(|e| refused("home-link", h, &target, Some(&e.to_string())))?;
    }
    // The account's config minus this directory's own table, which the entry
    // states outright: a second header for a table the file already declares
    // is a duplicate key the harness rejects the whole file for. A leading
    // newline, because the account's config ends inside whatever table it
    // ends in.
    let section = codex_section(dir);
    let mut text = match present(&config) {
        Present::File => without_table(&read(&config, h)?, &section),
        Present::Absent => String::new(),
        Present::Unreadable(cause) => {
            return Err(refused("config-unreadable", h, &config, Some(&cause)));
        }
    };
    text.push_str(&format!("\n[{section}]\ntrust_level = \"trusted\"\n"));
    install_config(&private, &text, h)?;
    if codex_trusted(&private, dir, h)? != Some(true) {
        return Err(refused("entry-unreadable", h, &private, None));
    }
    Ok(Prepared {
        route: Route::LaunchHome,
        home,
    })
}

/// The table a line belongs to: the header's text between the brackets, or
/// `None` for a line that is itself a header.
fn table_of<'a>(line: &'a str, current: &mut &'a str) -> bool {
    let trimmed = line.trim_start();
    if let Some(rest) = trimmed.strip_prefix('[') {
        *current = rest.trim_end().strip_suffix(']').unwrap_or(rest).trim_end();
        return true;
    }
    false
}

/// The value of `key` inside the table whose header reads `section`, with
/// one layer of surrounding quotes removed; `None` where the file does not
/// say (no table, no key, an empty value). Not a TOML parser: a table is its
/// header line spelled as the caller names it and a key a word left of the
/// first `=` inside it, which is what every writer of these files emits.
fn toml_value(text: &str, section: &str, key: &str) -> Option<String> {
    let mut current = "";
    for line in text.lines() {
        if table_of(line, &mut current) || current != section {
            continue;
        }
        let line = line.split('#').next().unwrap_or("");
        let Some((k, v)) = line.split_once('=') else {
            continue;
        };
        if k.trim() != key {
            continue;
        }
        let v = v.trim();
        if v.is_empty() {
            return None;
        }
        let v = v
            .strip_prefix('"')
            .and_then(|s| s.strip_suffix('"'))
            .or_else(|| v.strip_prefix('\'').and_then(|s| s.strip_suffix('\'')))
            .unwrap_or(v);
        return Some(v.to_owned());
    }
    None
}

/// `text` with `section`'s table removed: its header line and every line
/// under it up to the next header.
fn without_table(text: &str, section: &str) -> String {
    let mut current = "";
    let mut drop = false;
    let mut out = String::new();
    for line in text.lines() {
        if table_of(line, &mut current) {
            drop = current == section;
        }
        if !drop {
            out.push_str(line);
            out.push('\n');
        }
    }
    out
}

// ---------------------------------------------------------------------------
// Claude
// ---------------------------------------------------------------------------

fn claude(lane: &Path, dir: &Path) -> Result<Prepared> {
    let h = Harness::Claude;
    let config = lane.join(".claude.json");
    let key = dir.display().to_string();
    let mut root = match present(&config) {
        Present::Absent => Value::Object(Map::new()),
        Present::Unreadable(cause) => {
            return Err(refused("config-unreadable", h, &config, Some(&cause)));
        }
        Present::File => serde_json::from_str::<Value>(&read(&config, h)?)
            .map_err(|e| refused("config-unreadable", h, &config, Some(&e.to_string())))?,
    };
    match root
        .get("projects")
        .and_then(|p| p.get(&key))
        .and_then(|e| e.get("hasTrustDialogAccepted"))
    {
        None | Some(Value::Null) => {}
        Some(Value::Bool(true)) => {
            return Ok(Prepared {
                route: Route::Preapproved,
                home: lane.to_path_buf(),
            });
        }
        Some(_) => return Err(refused("trust-refused", h, dir, None)),
    }
    // The config dir holds the account's credentials and the file its
    // address, user id and every per-project tool allowance, so a dir this
    // creates is private and the file it writes is private too, whatever
    // the caller's umask: the harness itself makes the file 0600.
    private_dir(lane, "home-create", h)?;
    let Some(object) = root.as_object_mut() else {
        return Err(refused(
            "config-write",
            h,
            &config,
            Some("the document is not an object"),
        ));
    };
    object.insert("hasCompletedOnboarding".to_owned(), Value::Bool(true));
    let projects = object
        .entry("projects")
        .or_insert_with(|| Value::Object(Map::new()));
    let Some(projects) = projects.as_object_mut() else {
        return Err(refused(
            "config-write",
            h,
            &config,
            Some("`projects` is not an object"),
        ));
    };
    let entry = projects
        .entry(key.clone())
        .or_insert_with(|| Value::Object(Map::new()));
    let Some(entry) = entry.as_object_mut() else {
        return Err(refused(
            "config-write",
            h,
            &config,
            Some("the directory's entry is not an object"),
        ));
    };
    entry.insert("hasTrustDialogAccepted".to_owned(), Value::Bool(true));
    let text = serde_json::to_string_pretty(&root)
        .map_err(|e| refused("config-write", h, &config, Some(&e.to_string())))?;
    install_config(&config, &format!("{text}\n"), h)?;
    let written: Value = serde_json::from_str(&read(&config, h)?)
        .map_err(|e| refused("entry-unreadable", h, &config, Some(&e.to_string())))?;
    if written["projects"][&key]["hasTrustDialogAccepted"] != Value::Bool(true) {
        return Err(refused("entry-unreadable", h, &config, None));
    }
    Ok(Prepared {
        route: Route::AccountConfig,
        home: lane.to_path_buf(),
    })
}

// ---------------------------------------------------------------------------
// Copilot
// ---------------------------------------------------------------------------

/// The directory the context reader leaves each session's pending marker
/// in, under the launcher's own home, which the lane's Copilot inherits;
/// the extension spells it again from its own `os.homedir()`.
fn pending_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".cache/lane-mail/copilot-usage"))
}

fn reader_refused(detail: &str, file: &Path, cause: Option<&str>) -> Error {
    let file = file.display().to_string();
    match cause {
        Some(cause) => Error::refused(
            "no-context-reader",
            &[
                ("harness", "copilot"),
                ("file", &file),
                ("detail", detail),
                ("cause", cause),
            ],
        ),
        None => Error::refused(
            "no-context-reader",
            &[("harness", "copilot"), ("file", &file), ("detail", detail)],
        ),
    }
}

/// Make `home` run the context reader: the extension copied into
/// `extensions/kendex-lane-context/`, rewritten only where its content
/// differs, and `enabledFeatureFlags.EXTENSIONS` set true in settings.json,
/// written through a link to its target so the link stays; then the pending
/// directory made and proved writable. An `EXTENSIONS` flag set false is the
/// operator's choice, never overridden: the launch is admitted only where
/// the home's status line writes the fallback session record, else refused
/// with that reader's own cause.
fn copilot(home: &Path, pending: Option<&Path>) -> Result<Prepared> {
    if !home.is_absolute() {
        return Err(Error::refused(
            "home-relative",
            &[
                ("harness", "copilot"),
                ("home", &home.display().to_string()),
            ],
        ));
    }
    let dest = home.join("extensions/kendex-lane-context/extension.mjs");
    let standing = match present(&dest) {
        Present::File => Some(read_as(&dest, "unwritable")?),
        Present::Absent => None,
        Present::Unreadable(cause) => {
            return Err(reader_refused("unwritable", &dest, Some(&cause)));
        }
    };
    if standing.as_deref() != Some(EXTENSION) {
        let dir = dest.parent().unwrap_or(home);
        fs::create_dir_all(dir)
            .map_err(|e| reader_refused("unwritable", &dest, Some(&e.to_string())))?;
        install(&dest, EXTENSION)
            .map_err(|(_, e)| reader_refused("unwritable", &dest, Some(&e.to_string())))?;
    }
    let settings = home.join("settings.json");
    let target =
        link_target(&settings).ok_or_else(|| reader_refused("unreadable", &settings, None))?;
    let doc = match present(&target) {
        Present::Absent => Value::Object(Map::new()),
        Present::Unreadable(cause) => {
            return Err(reader_refused("unreadable", &target, Some(&cause)));
        }
        Present::File => serde_json::from_str::<Value>(&read_as(&target, "unreadable")?)
            .map_err(|e| reader_refused("unreadable", &target, Some(&e.to_string())))?,
    };
    let Value::Object(mut object) = doc else {
        return Err(reader_refused(
            "unreadable",
            &target,
            Some("the document is not an object"),
        ));
    };
    match object
        .get("enabledFeatureFlags")
        .and_then(|f| f.get("EXTENSIONS"))
    {
        Some(Value::Bool(true)) => {}
        Some(Value::Bool(false)) => {
            return match status_line(home) {
                Ok(()) => Ok(Prepared {
                    route: Route::AllowAllEnv,
                    home: home.to_path_buf(),
                }),
                Err(cause) => Err(reader_refused("disabled", &target, Some(cause))),
            };
        }
        None | Some(Value::Null) => {
            let flags = object
                .entry("enabledFeatureFlags")
                .or_insert_with(|| Value::Object(Map::new()));
            let Some(flags) = flags.as_object_mut() else {
                return Err(reader_refused(
                    "unreadable",
                    &target,
                    Some("`enabledFeatureFlags` is not an object"),
                ));
            };
            flags.insert("EXTENSIONS".to_owned(), Value::Bool(true));
            let text = serde_json::to_string_pretty(&Value::Object(object))
                .map_err(|e| reader_refused("unwritable", &target, Some(&e.to_string())))?;
            install(&target, &format!("{text}\n"))
                .map_err(|(_, e)| reader_refused("unwritable", &target, Some(&e.to_string())))?;
        }
        Some(_) => {
            return Err(reader_refused(
                "unreadable",
                &target,
                Some("`EXTENSIONS` is not a boolean"),
            ));
        }
    }
    let Some(pending) = pending else {
        return Err(reader_refused(
            "pending-unwritable",
            Path::new("$HOME/.cache/lane-mail/copilot-usage"),
            Some("no HOME"),
        ));
    };
    let probed = fs::create_dir_all(pending).and_then(|()| {
        let probe = pending.join(format!(".probe.{}", std::process::id()));
        fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&probe)
            .and_then(|_| fs::remove_file(&probe))
    });
    if let Err(e) = probed {
        return Err(reader_refused(
            "pending-unwritable",
            pending,
            Some(&e.to_string()),
        ));
    }
    Ok(Prepared {
        route: Route::AllowAllEnv,
        home: home.to_path_buf(),
    })
}

/// The file a path names through its links, hop by hop, at most forty.
fn link_target(path: &Path) -> Option<PathBuf> {
    let mut target = path.to_path_buf();
    for _ in 0..=40 {
        match fs::symlink_metadata(&target) {
            Ok(m) if m.file_type().is_symlink() => {
                let link = fs::read_link(&target).ok()?;
                target = if link.is_absolute() {
                    link
                } else {
                    target.parent().map_or(link.clone(), |d| d.join(&link))
                };
            }
            _ => return Some(target),
        }
    }
    None
}

fn read_as(path: &Path, detail: &str) -> Result<String> {
    fs::read_to_string(path).map_err(|e| reader_refused(detail, path, Some(&e.to_string())))
}

/// Whether `home` runs `copilot-statusline` as its status line often enough
/// for the fallback session record to stay fresh: `statusLine` a command
/// whose first word is that script, an executable file, with a whole-second
/// `refreshInterval` above 0 and below the record's age bound. The first
/// thing that fails names the cause.
fn status_line(home: &Path) -> std::result::Result<(), &'static str> {
    let settings = home.join("settings.json");
    let text = match present(&settings) {
        Present::File => fs::read_to_string(&settings).map_err(|_| "settings-unreadable")?,
        Present::Absent | Present::Unreadable(_) => return Err("settings-missing"),
    };
    let doc: Value = serde_json::from_str(&text).map_err(|_| "settings-unreadable")?;
    let line = &doc["statusLine"];
    if !line.is_object() || line["type"] != "command" {
        return Err("no-status-line");
    }
    let command = line["command"].as_str().unwrap_or("");
    let first = command.split(' ').next().unwrap_or("");
    if Path::new(first).file_name() != Some(OsStr::new("copilot-statusline")) {
        return Err("other-command");
    }
    let resolved = if first.contains('/') {
        Some(PathBuf::from(first))
    } else {
        std::env::var_os("PATH").and_then(|path| {
            std::env::split_paths(&path)
                .map(|dir| dir.join(first))
                .find(|p| fs::metadata(p).is_ok_and(|m| m.is_file()))
        })
    };
    let executable = resolved.is_some_and(|p| {
        fs::metadata(&p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
    });
    if !executable {
        return Err("command-missing");
    }
    let interval = line["refreshInterval"].as_f64().ok_or("refresh-interval")?;
    if interval.fract() != 0.0 || interval <= 0.0 || interval >= STATUS_LINE_MAX_AGE_S as f64 {
        return Err("refresh-interval");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOOK_ENTRY: &str = "[hooks.state.\"/repo/.codex/hooks.json:pre_tool_use:0:0\"]";

    /// An account directory with its own files and a config written from
    /// `body` where one is given; `store` makes the transcript directory.
    fn account(root: &Path, name: &str, body: Option<&str>, store: bool) -> PathBuf {
        let lane = root.join(name).join(".1codex");
        fs::create_dir_all(&lane).unwrap();
        if store {
            fs::create_dir_all(lane.join("sessions")).unwrap();
        }
        fs::write(lane.join("auth.json"), "token\n").unwrap();
        if let Some(body) = body {
            fs::write(lane.join("config.toml"), format!("{body}\n")).unwrap();
        }
        lane
    }

    fn key(e: &Error) -> &'static str {
        match e {
            Error::Refused { key, .. } => key,
            other => panic!("{other}"),
        }
    }

    fn count(text: &str, needle: &str) -> usize {
        text.lines().filter(|l| l.contains(needle)).count()
    }

    /// The private home's path is the account's launch leaf and checksum,
    /// the figures the shell's `cksum` prints for the same paths, and the
    /// inverse takes it apart; a path that is no private home is its own
    /// account.
    #[test]
    fn the_private_home_path_is_the_account_s_launch_leaf_and_checksum() {
        let account = Path::new("/home/x/.1codex");
        assert_eq!(
            home_path(account, Path::new("/work/tree")),
            Path::new("/home/x/.1codex/lane-launch/tree-1914715100/home")
        );
        let home = home_path(account, Path::new("/work/my tree (2)"));
        assert_eq!(
            home,
            Path::new("/home/x/.1codex/lane-launch/my_tree__2_-316542674/home")
        );
        assert_eq!(account_of(&home), account);
        assert_eq!(account_of(account), account);
        assert_eq!(cksum(b""), 4_294_967_295);
        assert_eq!(cksum(b"a"), 1_220_704_766);
    }

    /// The effective config a launch would open is read back through the
    /// production reader, so a row measures what the launch will meet.
    #[test]
    fn a_codex_launch_runs_under_a_private_home_carrying_the_account_s_config_and_the_trust_table()
    {
        let root = tempfile::tempdir().unwrap();
        type Row<'a> = (&'a str, Option<&'a str>, Route, bool, usize, &'a str);
        let rows: [Row; 4] = [
            ("no-config", None, Route::LaunchHome, true, 0, "none"),
            (
                "trusts-another",
                Some(
                    "HOOK\ntrusted_hash = \"sha256:aa\"\n\n[projects.\"/elsewhere\"]\ntrust_level = \"trusted\"",
                ),
                Route::LaunchHome,
                true,
                1,
                "none",
            ),
            (
                "already-trusted",
                Some(
                    "HOOK\ntrusted_hash = \"sha256:aa\"\n\n[projects.\"DIR\"]\ntrust_level = \"trusted\"",
                ),
                Route::Preapproved,
                false,
                1,
                "none",
            ),
            (
                "table-then-more",
                Some(
                    "HOOK\ntrusted_hash = \"sha256:aa\"\n\n[projects.\"DIR\"]\napproval_policy = \"never\"\n\n[features.multi_agent_v2]\nmax_concurrent_threads_per_session = 6",
                ),
                Route::LaunchHome,
                true,
                1,
                "6",
            ),
        ];
        for (name, body, route, private, hooks, after) in rows {
            let dir = root.path().join(name).join("wt");
            fs::create_dir_all(&dir).unwrap();
            let body = body.map(|b| {
                b.replace("HOOK", HOOK_ENTRY)
                    .replace("DIR", &dir.display().to_string())
            });
            let lane = account(root.path(), name, body.as_deref(), true);
            let read = prepared_home(Harness::Codex, &lane, &dir).unwrap();
            assert!(
                fs::symlink_metadata(home_path(&lane, &dir)).is_err(),
                "{name}: the read writes nothing"
            );
            let prepared = prepare(Harness::Codex, &lane, &dir).unwrap();
            assert_eq!(read, prepared.home, "{name}: the home the launch runs on");
            assert_eq!(prepared.route, route, "{name}");
            assert_eq!(prepared.home != lane, private, "{name}: private");
            let config = prepared.home.join("config.toml");
            assert_eq!(
                codex_trusted(&config, &dir, Harness::Codex).unwrap(),
                Some(true),
                "{name}: trusted"
            );
            let text = fs::read_to_string(&config).unwrap();
            assert_eq!(count(&text, HOOK_ENTRY), hooks, "{name}: hooks");
            assert_eq!(
                count(&text, &format!("[{}]", codex_section(&dir))),
                1,
                "{name}: tables"
            );
            assert_eq!(
                toml_value(
                    &text,
                    "features.multi_agent_v2",
                    "max_concurrent_threads_per_session"
                )
                .unwrap_or_else(|| "none".to_owned()),
                after,
                "{name}: after"
            );
            if let Some(body) = &body {
                assert_eq!(
                    fs::read_to_string(lane.join("config.toml")).unwrap(),
                    format!("{body}\n"),
                    "{name}: the account's own config is left as it was"
                );
            }
        }
        // The account's files reach the launch by link, so a token renewed
        // under the lane lands in the account's own auth.json; a store the
        // account lacked is made in the account and linked.
        let dir = root.path().join("linked").join("wt");
        fs::create_dir_all(&dir).unwrap();
        let lane = account(root.path(), "linked", None, false);
        let home = prepare(Harness::Codex, &lane, &dir).unwrap().home;
        fs::write(home.join("auth.json"), "renewed\n").unwrap();
        assert_eq!(
            fs::read_to_string(lane.join("auth.json")).unwrap(),
            "renewed\n"
        );
        fs::write(home.join("sessions").join("one.jsonl"), "rollout\n").unwrap();
        assert_eq!(
            fs::read_to_string(lane.join("sessions").join("one.jsonl")).unwrap(),
            "rollout\n"
        );
        // A second preparation, from the private home as a relaunch gives
        // it, links a private file at a name the account has since gained.
        fs::write(home.join("models_cache.json"), "private\n").unwrap();
        fs::write(lane.join("models_cache.json"), "shipped\n").unwrap();
        let again = prepare(Harness::Codex, &home, &dir).unwrap();
        assert_eq!(again.home, home);
        assert_eq!(
            fs::read_to_string(home.join("models_cache.json")).unwrap(),
            "shipped\n"
        );
        assert_eq!(
            fs::read_link(home.join("models_cache.json")).unwrap(),
            lane.join("models_cache.json")
        );
    }

    /// The private home is where Codex writes the answer given at the pane,
    /// so it is read beside the account's config.
    #[test]
    fn an_answer_recorded_in_either_codex_config_refuses_and_is_left_as_written() {
        let root = tempfile::tempdir().unwrap();
        let dir = root.path().join("answered").join("wt");
        fs::create_dir_all(&dir).unwrap();
        let body = format!(
            "{HOOK_ENTRY}\ntrusted_hash = \"sha256:aa\"\n\n[projects.\"{}\"]\ntrust_level = \"untrusted\"",
            dir.display()
        );
        let lane = account(root.path(), "answered", Some(&body), true);
        let e = prepare(Harness::Codex, &lane, &dir).unwrap_err();
        assert_eq!(key(&e), "trust-refused");
        assert_eq!(
            fs::read_to_string(lane.join("config.toml")).unwrap(),
            format!("{body}\n")
        );
        let dir = root.path().join("home-answered").join("wt");
        fs::create_dir_all(&dir).unwrap();
        let lane = account(root.path(), "home-answered", None, true);
        let home = prepare(Harness::Codex, &lane, &dir).unwrap().home;
        let answer = format!(
            "\n[projects.\"{}\"]\ntrust_level = \"untrusted\"\n",
            dir.display()
        );
        fs::write(home.join("config.toml"), &answer).unwrap();
        let e = prepare(Harness::Codex, &lane, &dir).unwrap_err();
        assert_eq!(key(&e), "trust-refused");
        assert_eq!(
            fs::read_to_string(home.join("config.toml")).unwrap(),
            answer
        );
        let dir = root.path().join("dangling").join("wt");
        fs::create_dir_all(&dir).unwrap();
        let lane = account(root.path(), "dangling", None, true);
        symlink(lane.join("absent.toml"), lane.join("config.toml")).unwrap();
        let e = prepare(Harness::Codex, &lane, &dir).unwrap_err();
        assert_eq!(key(&e), "config-unreadable");
    }

    /// Codex makes its `plugins` directory under the home before the account
    /// has the name, so the sequence is reproduced from that home, as a
    /// relaunch hands it.
    #[test]
    fn a_private_plugins_directory_is_kept_and_another_real_directory_refuses() {
        let root = tempfile::tempdir().unwrap();
        for (name, kept) in [("plugins", true), ("unknown", false)] {
            let dir = root.path().join(name).join("wt");
            fs::create_dir_all(&dir).unwrap();
            let lane = account(root.path(), name, None, false);
            let home = prepare(Harness::Codex, &lane, &dir).unwrap().home;
            fs::create_dir_all(home.join(name).join("cache")).unwrap();
            fs::write(home.join(name).join("private"), "unproved private data\n").unwrap();
            fs::create_dir_all(lane.join(name)).unwrap();
            fs::write(lane.join(name).join("account"), "shipped\n").unwrap();
            let result = prepare(Harness::Codex, &home, &dir);
            if kept {
                let again = result.unwrap();
                assert_eq!(again.home, home);
                assert!(prepare(Harness::Codex, &home, &dir).is_ok(), "repeats");
                assert_eq!(
                    fs::read_to_string(home.join(name).join("private")).unwrap(),
                    "unproved private data\n"
                );
            } else {
                assert_eq!(key(&result.unwrap_err()), "home-entry");
            }
            assert!(
                !home.join(name).join(name).exists(),
                "{name}: no nested link"
            );
            assert!(fs::symlink_metadata(home.join(name)).unwrap().is_dir());
        }
    }

    /// The file holds the account's address, user id and every per-project
    /// tool allowance, so each row reads back what else it held.
    #[test]
    fn a_claude_config_dir_gains_the_trust_pair_and_a_recorded_refusal_or_unreadable_file_refuses()
    {
        let root = tempfile::tempdir().unwrap();
        type Row<'a> = (
            &'a str,
            Option<&'a str>,
            Result<(Route, &'a str, usize, usize)>,
        );
        let rows: [Row; 6] = [
            ("no-config", None, Ok((Route::AccountConfig, "-", 0, 0))),
            (
                "trusts-another",
                Some(
                    r#"{"userID": "u", "projects": {"/elsewhere": {"hasTrustDialogAccepted": true, "allowedTools": ["Bash"]}}}"#,
                ),
                Ok((Route::AccountConfig, "u", 1, 0)),
            ),
            (
                "already-trusted",
                Some(
                    r#"{"userID": "u", "hasCompletedOnboarding": true, "projects": {"DIR": {"hasTrustDialogAccepted": true, "allowedTools": ["Bash"]}}}"#,
                ),
                Ok((Route::Preapproved, "u", 0, 1)),
            ),
            (
                "entry-without-answer",
                Some(r#"{"projects": {"DIR": {"allowedTools": ["Bash", "Read"]}}}"#),
                Ok((Route::AccountConfig, "-", 0, 2)),
            ),
            (
                "answered-no",
                Some(r#"{"userID": "u", "projects": {"DIR": {"hasTrustDialogAccepted": false}}}"#),
                Err(Error::refused("trust-refused", &[])),
            ),
            (
                "not-json",
                Some(r#"{"projects": "#),
                Err(Error::refused("config-unreadable", &[])),
            ),
        ];
        for (name, body, want) in rows {
            let lane = root.path().join(name).join(".1claude");
            let dir = root.path().join(name).join("wt");
            fs::create_dir_all(&lane).unwrap();
            fs::create_dir_all(&dir).unwrap();
            let config = lane.join(".claude.json");
            let body = body.map(|b| b.replace("DIR", &dir.display().to_string()));
            if let Some(body) = &body {
                fs::write(&config, format!("{body}\n")).unwrap();
            }
            let got = prepare(Harness::Claude, &lane, &dir);
            match want {
                Ok((route, user, other_tools, own_tools)) => {
                    let prepared = got.unwrap();
                    assert_eq!(prepared.route, route, "{name}");
                    assert_eq!(
                        prepared.home, lane,
                        "{name}: the launch runs under the config dir"
                    );
                    let doc: Value =
                        serde_json::from_str(&fs::read_to_string(&config).unwrap()).unwrap();
                    let entry = &doc["projects"][dir.display().to_string()];
                    assert_eq!(entry["hasTrustDialogAccepted"], Value::Bool(true), "{name}");
                    assert_eq!(doc["hasCompletedOnboarding"], Value::Bool(true), "{name}");
                    assert_eq!(doc["userID"].as_str().unwrap_or("-"), user, "{name}");
                    let tools = |v: &Value| v.as_array().map_or(0, Vec::len);
                    assert_eq!(
                        tools(&doc["projects"]["/elsewhere"]["allowedTools"]),
                        other_tools,
                        "{name}"
                    );
                    assert_eq!(tools(&entry["allowedTools"]), own_tools, "{name}");
                    if route == Route::AccountConfig {
                        assert_eq!(
                            fs::metadata(&config).unwrap().permissions().mode() & 0o777,
                            0o600,
                            "{name}: private"
                        );
                    }
                }
                Err(e) => {
                    assert_eq!(key(&got.unwrap_err()), key(&e), "{name}");
                }
            }
            if matches!(name, "answered-no" | "already-trusted") {
                assert_eq!(
                    fs::read_to_string(&config).unwrap(),
                    format!("{}\n", body.as_deref().unwrap()),
                    "{name}: left as written"
                );
            }
        }
    }

    /// Pi asks no trust question and loads no reader: its arm writes
    /// nothing, and the home is the one given.
    #[test]
    fn the_dispatcher_hands_each_harness_to_its_arm() {
        let root = tempfile::tempdir().unwrap();
        let dir = root.path().join("wt");
        let lane = root.path().join(".1pi");
        let prepared = prepare(Harness::Pi, &lane, &dir).unwrap();
        assert_eq!(prepared.route, Route::None);
        assert_eq!(prepared.home, lane);
        assert!(fs::symlink_metadata(&lane).is_err(), "nothing written");
    }

    /// The launch installs the catalog's reader and nothing else, so the
    /// embedded copy and the catalog file are held equal while the Bash
    /// installer ships beside this one.
    #[test]
    fn the_catalog_s_copilot_reader_is_the_embedded_one() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../orch/scripts/copilot-lane-context/extension.mjs"
        );
        let text = fs::read_to_string(path).unwrap_or_else(|e| panic!("{path}: {e}"));
        assert_eq!(text, EXTENSION, "{path}");
    }

    fn field<'a>(e: &'a Error, name: &str) -> &'a str {
        match e {
            Error::Refused { fields, .. } => fields
                .iter()
                .find(|(k, _)| k == name)
                .map(|(_, v)| v.as_str())
                .unwrap_or(""),
            other => panic!("{other}"),
        }
    }

    /// The pending directory is the row's own: the production one is under
    /// the launcher's HOME, which a test never writes into.
    #[test]
    fn a_copilot_home_gains_the_context_reader_and_an_unwritable_home_refuses_by_name() {
        let root = tempfile::tempdir().unwrap();
        let pending = root.path().join("cache/copilot-usage");
        let home = root.path().join(".1copilot");
        fs::create_dir_all(&home).unwrap();
        let prepared = copilot(&home, Some(&pending)).unwrap();
        assert_eq!(prepared.route, Route::AllowAllEnv);
        assert_eq!(prepared.home, home);
        let dest = home.join("extensions/kendex-lane-context/extension.mjs");
        assert_eq!(fs::read_to_string(&dest).unwrap(), EXTENSION);
        let settings: Value =
            serde_json::from_str(&fs::read_to_string(home.join("settings.json")).unwrap()).unwrap();
        assert_eq!(
            settings["enabledFeatureFlags"]["EXTENSIONS"],
            Value::Bool(true)
        );
        assert!(fs::metadata(&pending).unwrap().is_dir());
        // A stale copy is replaced; other settings stay; a linked settings
        // file is written through and the link stands.
        let linked = root.path().join(".2copilot");
        fs::create_dir_all(linked.join("extensions/kendex-lane-context")).unwrap();
        fs::write(
            linked.join("extensions/kendex-lane-context/extension.mjs"),
            "stale\n",
        )
        .unwrap();
        let shared = root.path().join("shared-settings.json");
        fs::write(
            &shared,
            "{\"theme\": \"dark\", \"enabledFeatureFlags\": {\"OTHER\": true}}\n",
        )
        .unwrap();
        fs::set_permissions(&shared, fs::Permissions::from_mode(0o600)).unwrap();
        symlink(&shared, linked.join("settings.json")).unwrap();
        copilot(&linked, Some(&pending)).unwrap();
        assert_eq!(
            fs::read_to_string(linked.join("extensions/kendex-lane-context/extension.mjs"))
                .unwrap(),
            EXTENSION
        );
        assert!(
            fs::symlink_metadata(linked.join("settings.json"))
                .unwrap()
                .file_type()
                .is_symlink()
        );
        let settings: Value = serde_json::from_str(&fs::read_to_string(&shared).unwrap()).unwrap();
        assert_eq!(
            fs::metadata(&shared).unwrap().permissions().mode() & 0o777,
            0o600,
            "the operator's private settings stay private"
        );
        assert_eq!(settings["theme"], "dark");
        assert_eq!(settings["enabledFeatureFlags"]["OTHER"], Value::Bool(true));
        assert_eq!(
            settings["enabledFeatureFlags"]["EXTENSIONS"],
            Value::Bool(true)
        );
        // The operator's `false`: admitted on a working status line alone,
        // and never overridden.
        let off = root.path().join(".3copilot");
        fs::create_dir_all(&off).unwrap();
        fs::write(
            off.join("settings.json"),
            "{\"enabledFeatureFlags\": {\"EXTENSIONS\": false}}\n",
        )
        .unwrap();
        let e = copilot(&off, Some(&pending)).unwrap_err();
        assert_eq!(
            (key(&e), field(&e, "detail"), field(&e, "cause")),
            ("no-context-reader", "disabled", "no-status-line")
        );
        let script = root.path().join("copilot-statusline");
        fs::write(&script, "#!/bin/sh\n").unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
        fs::write(
            off.join("settings.json"),
            format!(
                "{{\"enabledFeatureFlags\": {{\"EXTENSIONS\": false}}, \"statusLine\": {{\"type\": \"command\", \"command\": \"{} --fast\", \"refreshInterval\": 30}}}}\n",
                script.display()
            ),
        )
        .unwrap();
        assert_eq!(
            copilot(&off, Some(&pending)).unwrap().route,
            Route::AllowAllEnv
        );
        let settings: Value =
            serde_json::from_str(&fs::read_to_string(off.join("settings.json")).unwrap()).unwrap();
        assert_eq!(
            settings["enabledFeatureFlags"]["EXTENSIONS"],
            Value::Bool(false)
        );
        // Settings that are no object refuse as unreadable.
        let odd = root.path().join(".4copilot");
        fs::create_dir_all(&odd).unwrap();
        fs::write(odd.join("settings.json"), "[]\n").unwrap();
        let e = copilot(&odd, Some(&pending)).unwrap_err();
        assert_eq!(
            (key(&e), field(&e, "detail")),
            ("no-context-reader", "unreadable")
        );
        // A home that cannot be written, and a pending directory that
        // cannot, each refuse by name with the file.
        let sealed = root.path().join(".5copilot");
        fs::create_dir_all(&sealed).unwrap();
        fs::set_permissions(&sealed, fs::Permissions::from_mode(0o500)).unwrap();
        let e = copilot(&sealed, Some(&pending)).unwrap_err();
        fs::set_permissions(&sealed, fs::Permissions::from_mode(0o700)).unwrap();
        assert_eq!(
            (key(&e), field(&e, "detail")),
            ("no-context-reader", "unwritable")
        );
        assert_eq!(
            field(&e, "file"),
            sealed
                .join("extensions/kendex-lane-context/extension.mjs")
                .display()
                .to_string()
        );
        let blocked = root.path().join("blocked-pending");
        fs::write(&blocked, "").unwrap();
        let e = copilot(&home, Some(&blocked)).unwrap_err();
        assert_eq!(
            (key(&e), field(&e, "detail")),
            ("no-context-reader", "pending-unwritable")
        );
        assert_eq!(
            key(&copilot(Path::new("rel/.copilot"), Some(&pending)).unwrap_err()),
            "home-relative"
        );
    }
}
