use std::fmt::Write as _;
use std::fs;
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

use crate::error::{CoreError, Result};
use crate::manifest::Manifest;
use crate::model::{HarnessId, ItemKind};

/// Deeper than any rendered tree goes; a link that loops back into its own
/// tree hits this instead of the stack limit.
pub(crate) const MAX_DEPTH: usize = 32;

/// SHA-256 over a file's bytes, or over a directory tree as sorted
/// relative-path + content pairs. Symlinks hash their resolved content.
/// Anything that is neither file nor directory (a pipe, a device) is an
/// error, not a read that never returns — the caller reports it uncompared.
pub fn hash_tree(path: &Path) -> Result<String> {
    let mut hasher = Sha256::new();
    hash_into(&mut hasher, path, Path::new(""), 0)?;
    Ok(hex(&hasher.finalize()))
}

fn hash_into(hasher: &mut Sha256, path: &Path, rel: &Path, depth: usize) -> Result<()> {
    let refuse = |why: &str| CoreError::io(path, std::io::Error::other(why.to_owned()));
    if depth > MAX_DEPTH {
        return Err(refuse(
            "nested too deep — a link pointing back into its own tree?",
        ));
    }
    let meta = fs::metadata(path).map_err(|e| CoreError::io(path, e))?;
    if meta.is_dir() {
        let mut entries: Vec<_> = fs::read_dir(path)
            .map_err(|e| CoreError::io(path, e))?
            .flatten()
            .map(|e| e.path())
            .collect();
        entries.sort();
        for entry in entries {
            let Some(name) = entry.file_name() else {
                continue;
            };
            hash_into(hasher, &entry, &rel.join(name), depth + 1)?;
        }
    } else if meta.is_file() {
        let bytes = fs::read(path).map_err(|e| CoreError::io(path, e))?;
        hasher.update(rel.to_string_lossy().as_bytes());
        hasher.update([0]);
        hasher.update(&bytes);
        hasher.update([0]);
    } else {
        return Err(refuse("not a regular file or directory"));
    }
    Ok(())
}

/// SHA-256 over a tree as it sits, never following a link: a plain file
/// by relative path and bytes, a link by relative path and target,
/// dangling or not, a directory by relative path before its entries, so
/// an empty one created or removed is a change. What a directory move
/// binds to — a rename carries the entries themselves, a dangling link
/// included, so the precondition names exactly those and never the bytes
/// a link points at. Every record is framed: a kind byte, then each field
/// as its length and its raw OS bytes, so no file content can spell a
/// record boundary and no two names collapse into one. Anything else (a
/// pipe, a socket, a device) is an error naming the entry, as in
/// `hash_tree`: the journal snapshots a moved directory by copying it,
/// and a copy of a reader-less pipe never returns.
pub fn hash_tree_as_is(path: &Path) -> Result<String> {
    let mut hasher = Sha256::new();
    hash_as_is_into(&mut hasher, path, Path::new(""))?;
    Ok(hex(&hasher.finalize()))
}

const AS_IS_FILE: u8 = 0;
const AS_IS_LINK: u8 = 1;
const AS_IS_DIR: u8 = 2;

/// One field of an as-is record: its length, fixed width, then its bytes.
fn frame(hasher: &mut Sha256, bytes: &[u8]) {
    hasher.update((bytes.len() as u64).to_le_bytes());
    hasher.update(bytes);
}

fn hash_as_is_into(hasher: &mut Sha256, path: &Path, rel: &Path) -> Result<()> {
    let refuse = |why: &str| CoreError::io(path, std::io::Error::other(why.to_owned()));
    let kind = fs::symlink_metadata(path)
        .map_err(|e| CoreError::io(path, e))?
        .file_type();
    let name = rel.as_os_str().as_encoded_bytes();
    if kind.is_symlink() {
        let target = fs::read_link(path).map_err(|e| CoreError::io(path, e))?;
        hasher.update([AS_IS_LINK]);
        frame(hasher, name);
        frame(hasher, target.as_os_str().as_encoded_bytes());
    } else if kind.is_dir() {
        hasher.update([AS_IS_DIR]);
        frame(hasher, name);
        let mut entries: Vec<_> = fs::read_dir(path)
            .map_err(|e| CoreError::io(path, e))?
            .flatten()
            .map(|e| e.path())
            .collect();
        entries.sort();
        for entry in entries {
            let Some(name) = entry.file_name() else {
                continue;
            };
            hash_as_is_into(hasher, &entry, &rel.join(name))?;
        }
    } else if kind.is_file() {
        let bytes = fs::read(path).map_err(|e| CoreError::io(path, e))?;
        hasher.update([AS_IS_FILE]);
        frame(hasher, name);
        frame(hasher, &bytes);
    } else {
        return Err(refuse("not a regular file, directory or link"));
    }
    Ok(())
}

/// The hash a single-file artifact will have once written — mirrors
/// `hash_tree` applied to a lone file.
pub fn hash_bytes(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"");
    hasher.update([0]);
    hasher.update(bytes);
    hasher.update([0]);
    hex(&hasher.finalize())
}

/// The hash an in-memory rendered tree will have once written — mirrors
/// `hash_tree` so plans can compare desired vs. disk without materializing.
pub fn hash_files(files: &[(std::path::PathBuf, Vec<u8>)]) -> String {
    let mut sorted: Vec<_> = files.iter().collect();
    sorted.sort_by(|a, b| a.0.cmp(&b.0));
    let mut hasher = Sha256::new();
    for (rel, bytes) in sorted {
        hasher.update(rel.to_string_lossy().as_bytes());
        hasher.update([0]);
        hasher.update(bytes);
        hasher.update([0]);
    }
    hex(&hasher.finalize())
}

/// One rendered artifact's exact disk identity and committed identity.
///
/// The exact hash binds mutations to the bytes previewed on this machine.
/// The persisted hash removes only the LF-to-CRLF conversion the
/// destination's Git text policy performs, so one committed lock has the
/// same identity in every clone.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RenderedIdentity {
    exact: String,
    persisted: String,
}

impl RenderedIdentity {
    /// Identity for final rendered bytes at their destination.
    ///
    /// Git attributes belong to the destination path. This classifies that
    /// path even before it exists, then normalizes each text file before
    /// aggregating a tree. A destination marked binary remains exact.
    pub fn rendered(destination: &Path, rendered: &[(PathBuf, Vec<u8>)]) -> Self {
        Self::under(destination, rendered, Checkout::Rendered)
    }

    /// Identity for a selected set of files at a path, under that path's
    /// Git policy. The selection keeps package exclusions while applying
    /// the same policy as a full on-disk artifact. `owned_untracked` names
    /// the kendex-owned destination; a source path passes `false`.
    pub fn observed_files(
        root: &Path,
        files: &[(PathBuf, Vec<u8>)],
        owned_untracked: bool,
    ) -> Self {
        Self::under(root, files, Checkout::observed(owned_untracked))
    }

    /// Identity for a file or tree already on disk.
    ///
    /// `owned_untracked` is for a kendex output whose destination Git does
    /// not track, such as a Pi package copied from tracked catalog text.
    pub fn from_path(path: &Path, owned_untracked: bool) -> Result<Self> {
        let mut files = Vec::new();
        collect_plain_files(path, Path::new(""), 0, &mut files)?;
        Ok(Self::under(
            path,
            &files,
            Checkout::observed(owned_untracked),
        ))
    }

    fn under(root: &Path, files: &[(PathBuf, Vec<u8>)], checkout: Checkout) -> Self {
        let exact = hash_files(files);
        if let Some(identity) = exact_without_git(files, exact.clone()) {
            return identity;
        }
        let persisted = checkout_hash(root, files, checkout).unwrap_or_else(|| exact.clone());
        Self { exact, persisted }
    }

    pub fn exact(&self) -> &str {
        &self.exact
    }

    pub fn persisted(&self) -> &str {
        &self.persisted
    }

    pub fn matches(&self, recorded: &str) -> bool {
        self.exact == recorded || self.persisted == recorded
    }
}

/// Git's portable form can differ only where CRLF becomes LF. When no file
/// contains that pair, policy cannot change the hash, so avoid every Git
/// probe and keep exact identity for both roles.
fn exact_without_git(files: &[(PathBuf, Vec<u8>)], exact: String) -> Option<RenderedIdentity> {
    (!git_can_convert(files)).then(|| RenderedIdentity {
        persisted: exact.clone(),
        exact,
    })
}

/// Whether any file carries a CRLF pair, the only bytes Git's text
/// conversion rewrites.
fn git_can_convert(files: &[(PathBuf, Vec<u8>)]) -> bool {
    files.iter().any(|(_, bytes)| normalization_eligible(bytes))
}

fn normalization_eligible(bytes: &[u8]) -> bool {
    !bytes.contains(&0) && bytes.windows(2).any(|pair| pair == b"\r\n")
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Checkout {
    /// Planned rendered bytes. The destination can be absent or replaced.
    Rendered,
    /// Existing bytes. Any Git-visible change keeps exact identity.
    Observed,
    /// Existing bytes at a lock-owned path. The destination's policy
    /// decides whatever Git status says: kendex's own write over a
    /// committed render is tracked and modified until the person commits
    /// it, and it is still the render.
    ObservedOwned,
}

impl Checkout {
    fn observed(owned_untracked: bool) -> Self {
        match owned_untracked {
            true => Self::ObservedOwned,
            false => Self::Observed,
        }
    }
}

/// Hash clean tracked files as Git carries them between checkouts.
///
/// Git for Windows commonly writes a tracked text file with CRLF while its
/// index keeps LF. A committed install record must keep the index identity,
/// or an unchanged clone reads Git's line-ending conversion as a local edit.
/// Git remains the judge: normalization applies only when the selected tree
/// is clean, every file is tracked, and `ls-files --eol` reports that exact
/// index/worktree conversion. Modified, untracked, and binary files keep
/// their raw bytes, so this helper cannot hide a person's edit.
pub fn hash_clean_checkout_files(
    root: &Path,
    files: &[(std::path::PathBuf, Vec<u8>)],
) -> Option<String> {
    checkout_hash(root, files, Checkout::Observed)
}

/// Each file's Git path is joined onto the resolved root, never onto the
/// caller's spelling: Git names the repository by where a path resolves,
/// so a root reached through a linked ancestor must strip against the
/// same resolution or every file falls back to exact bytes.
fn checkout_hash(root: &Path, files: &[(PathBuf, Vec<u8>)], checkout: Checkout) -> Option<String> {
    let root = crate::paths::absolute(root);
    let cwd = root.ancestors().find(|candidate| candidate.is_dir())?;
    let top = git_stdout(cwd, &["rev-parse", "--show-toplevel"])?;
    let top = crate::paths::canonical(Path::new(std::str::from_utf8(&top).ok()?.trim())).ok()?;
    if checkout == Checkout::Observed {
        let selected = root.strip_prefix(&top).ok()?;
        let selected = literal_pathspec(selected);
        let status = git_stdout(
            &top,
            &[
                "--no-optional-locks",
                "status",
                "--porcelain=v1",
                "-z",
                "--untracked-files=all",
                "--",
                &selected,
            ],
        )?;
        if !status.is_empty() {
            return None;
        }
    }

    let mut normalized = Vec::with_capacity(files.len());
    for (relative, bytes) in files {
        if checkout != Checkout::Observed && !normalization_eligible(bytes) {
            normalized.push((relative.clone(), bytes.clone()));
            continue;
        }
        let named = root.join(relative);
        let named = named.strip_prefix(&top).ok()?;
        let named = crate::paths::slashed(named);
        let pathspec = format!(":(literal){named}");
        let mut args = vec!["ls-files", "--eol", "-z", "--cached"];
        if matches!(checkout, Checkout::Rendered | Checkout::ObservedOwned) {
            args.extend(["--others", "--exclude-standard"]);
        }
        args.extend(["--", &pathspec]);
        let answer = git_stdout(&top, &args)?;
        let mut records = answer
            .split(|byte| *byte == 0)
            .filter(|row| !row.is_empty());
        let row = match records.next() {
            Some(record) if records.next().is_none() => parse_eol_row(record, &named),
            Some(_) => return None,
            None => None,
        };
        if checkout == Checkout::Observed && row.is_none() {
            return None;
        }
        let normalize = portable_text(&top, &named, bytes, row.as_ref());
        let bytes = match normalize {
            true => crlf_to_lf(bytes),
            false => bytes.clone(),
        };
        normalized.push((relative.clone(), bytes));
    }
    Some(hash_files(&normalized))
}

struct EolRow {
    index: String,
    policy: TextPolicy,
}

#[derive(Clone, Copy, Default)]
struct TextPolicy {
    text: TextAttribute,
    eol: EolAttribute,
}

#[derive(Clone, Copy, Default, PartialEq, Eq)]
enum TextAttribute {
    Set,
    Auto,
    Unset,
    #[default]
    Unspecified,
}

#[derive(Clone, Copy, Default, PartialEq, Eq)]
enum EolAttribute {
    Lf,
    Crlf,
    Unset,
    #[default]
    Unspecified,
}

fn parse_eol_row(record: &[u8], named: &str) -> Option<EolRow> {
    let tab = record.iter().position(|byte| *byte == b'\t')?;
    if record.get(tab + 1..) != Some(named.as_bytes()) {
        return None;
    }
    let eol = std::str::from_utf8(&record[..tab]).ok()?;
    let mut fields = eol.split_ascii_whitespace();
    let index = fields.next()?.to_owned();
    let _worktree = fields.next()?;
    let policy = fields.fold(TextPolicy::default(), |mut policy, field| {
        match field {
            "attr/text" => policy.text = TextAttribute::Set,
            "attr/text=auto" => policy.text = TextAttribute::Auto,
            "attr/-text" => policy.text = TextAttribute::Unset,
            "eol=lf" => policy.eol = EolAttribute::Lf,
            "eol=crlf" => policy.eol = EolAttribute::Crlf,
            _ => {}
        }
        policy
    });
    Some(EolRow { index, policy })
}

fn portable_text(top: &Path, named: &str, bytes: &[u8], row: Option<&EolRow>) -> bool {
    if !normalization_eligible(bytes) || row.is_some_and(|row| row.index == "i/crlf") {
        return false;
    }
    let policy = row
        .map(|row| row.policy)
        .or_else(|| text_attributes(top, named))
        .unwrap_or_default();
    if policy.text == TextAttribute::Unset {
        return false;
    }
    if matches!(policy.text, TextAttribute::Set | TextAttribute::Auto)
        || matches!(policy.eol, EolAttribute::Lf | EolAttribute::Crlf)
    {
        return true;
    }
    git_stdout(top, &["config", "--get", "core.autocrlf"])
        .and_then(|value| String::from_utf8(value).ok())
        .is_some_and(|value| matches!(value.trim(), "true" | "input"))
}

fn text_attributes(top: &Path, named: &str) -> Option<TextPolicy> {
    let output = git_stdout(top, &["check-attr", "-z", "text", "eol", "--", named])?;
    let fields: Vec<_> = output
        .split(|byte| *byte == 0)
        .filter(|field| !field.is_empty())
        .map(|field| String::from_utf8(field.to_vec()).ok())
        .collect::<Option<_>>()?;
    let mut policy = TextPolicy::default();
    for row in fields.chunks_exact(3) {
        match (row[1].as_str(), row[2].as_str()) {
            ("text", "set") => policy.text = TextAttribute::Set,
            ("text", "auto") => policy.text = TextAttribute::Auto,
            ("text", "unset") => policy.text = TextAttribute::Unset,
            ("eol", "lf") => policy.eol = EolAttribute::Lf,
            ("eol", "crlf") => policy.eol = EolAttribute::Crlf,
            ("eol", "unset") => policy.eol = EolAttribute::Unset,
            _ => {}
        }
    }
    Some(policy)
}

/// The Git-portable hash of an on-disk file or tree, when every file in it
/// is clean and tracked. `None` keeps the caller on its exact-byte path.
pub fn hash_clean_checkout_tree(path: &Path) -> Result<Option<String>> {
    let mut files = Vec::new();
    collect_plain_files(path, Path::new(""), 0, &mut files)?;
    Ok(hash_clean_checkout_files(path, &files))
}

fn collect_plain_files(
    path: &Path,
    relative: &Path,
    depth: usize,
    files: &mut Vec<(std::path::PathBuf, Vec<u8>)>,
) -> Result<()> {
    let refuse = |why: &str| CoreError::io(path, std::io::Error::other(why.to_owned()));
    if depth > MAX_DEPTH {
        return Err(refuse(
            "nested too deep — a link pointing back into its own tree?",
        ));
    }
    let meta = fs::metadata(path).map_err(|error| CoreError::io(path, error))?;
    if meta.is_dir() {
        let mut entries: Vec<_> = fs::read_dir(path)
            .map_err(|error| CoreError::io(path, error))?
            .flatten()
            .map(|entry| entry.path())
            .collect();
        entries.sort();
        for entry in entries {
            let Some(name) = entry.file_name() else {
                continue;
            };
            collect_plain_files(&entry, &relative.join(name), depth + 1, files)?;
        }
    } else if meta.is_file() {
        files.push((
            relative.to_path_buf(),
            fs::read(path).map_err(|error| CoreError::io(path, error))?,
        ));
    } else {
        return Err(refuse("not a regular file or directory"));
    }
    Ok(())
}

fn git_stdout(cwd: &Path, args: &[&str]) -> Option<Vec<u8>> {
    #[cfg(test)]
    GIT_QUERY_COUNT.with(|count| count.set(count.get() + 1));
    let output = crate::process::Hardened::git(args, Some(cwd)).run().ok()?;
    output.status.success().then_some(output.stdout)
}

#[cfg(test)]
thread_local! {
    static GIT_QUERY_COUNT: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

fn literal_pathspec(path: &Path) -> String {
    let path = crate::paths::slashed(path);
    match path.is_empty() {
        true => ":(literal).".to_owned(),
        false => format!(":(literal){path}"),
    }
}

fn crlf_to_lf(bytes: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(bytes.len());
    let mut at = 0;
    while at < bytes.len() {
        if bytes[at..].starts_with(b"\r\n") {
            out.push(b'\n');
            at += 2;
        } else {
            out.push(bytes[at]);
            at += 1;
        }
    }
    out
}

/// The full installation hash: source bytes plus the manifest sections that
/// shape this artifact (invariant 3) — editing a shared key invalidates
/// dependents because the serialized sections change. Source bytes come
/// through the sealed reader: a symlinked catalog must not feed host bytes
/// into an installation hash.
pub fn installation_hash(
    sealed: &crate::source_read::SealedSource,
    source_tree: &Path,
    manifest: &Manifest,
    kind: ItemKind,
    name: &str,
    harness: HarnessId,
) -> Result<String> {
    let files = if kind == ItemKind::Skill {
        sealed.collect_skill_tree(source_tree)?
    } else if sealed.is_dir(source_tree) {
        sealed.collect_tree(source_tree, &[])?
    } else {
        vec![(Path::new("").to_path_buf(), sealed.read(source_tree)?)]
    };
    let mut hasher = Sha256::new();
    hasher.update(portable_source_hash(source_tree, &files));
    hasher.update(relevant_sections(manifest, kind, name, harness).as_bytes());
    Ok(hex(&hasher.finalize()))
}

/// A source's bytes under the identity a committed lock carries. Git is
/// asked only where it could convert something: a plan hashes every source
/// once per harness, and the Git route starts a process per file.
fn portable_source_hash(source_tree: &Path, files: &[(PathBuf, Vec<u8>)]) -> String {
    let exact = hash_files(files);
    match git_can_convert(files) {
        true => hash_clean_checkout_files(source_tree, files).unwrap_or(exact),
        false => exact,
    }
}

/// Deterministic serialization of every manifest value that shapes the
/// rendered artifact, shared `all`/`*` keys included.
pub fn relevant_sections(
    manifest: &Manifest,
    kind: ItemKind,
    name: &str,
    harness: HarnessId,
) -> String {
    let mut out = String::new();
    let mut push = |section: &str, key: &str, value: &str| {
        let _ = writeln!(out, "{section}.{key}={value}");
    };
    let shared_keys = [name, "all", "*"];
    match kind {
        ItemKind::Skill => {
            for key in shared_keys {
                if let Some(text) = manifest.skill_instructions.get(key) {
                    push("skill-instructions", key, text);
                }
            }
        }
        ItemKind::Agent => {
            if let Some(skills) = manifest.agent_skills.get(name) {
                push("agent-skills", name, &skills.join(","));
            }
            for key in shared_keys {
                if let Some(text) = manifest.agent_launch_instructions.get(key) {
                    push("agent-launch-instructions", key, text);
                }
                if let Some(text) = manifest.agent_additional_instructions.get(key) {
                    push("agent-additional-instructions", key, text);
                }
            }
            if let Some(overrides) = manifest
                .agent_frontmatter
                .get(harness.name())
                .and_then(|by_agent| by_agent.get(name))
            {
                push(
                    "agent-frontmatter",
                    name,
                    &toml::to_string(overrides).unwrap_or_default(),
                );
            }
            for (index, hook) in manifest.custom_hooks.iter().enumerate() {
                push(
                    "custom-hooks",
                    &index.to_string(),
                    &format!(
                        "{}:{}:{}",
                        hook.event,
                        hook.matcher.as_deref().unwrap_or(""),
                        hook.command
                    ),
                );
            }
        }
        // A hook's declared environment is part of the command its
        // registration runs.
        ItemKind::Hook => {
            for (key, value) in manifest.hook_env(name).into_iter().flatten() {
                push("hooks-env", &format!("{name}.{key}"), value);
            }
        }
        _ => {}
    }
    out
}

pub(crate) fn hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        let _ = write!(out, "{byte:02x}");
    }
    out
}

/// 64-bit FNV-1a as a 16-hex-digit string — the one implementation behind
/// the scope-lock keys, the repo cache keys, and the settings-seed ledger.
/// Imported ledgers use the same constants and remain verifiable.
pub fn fnv1a_hex(bytes: &[u8]) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{hash:016x}")
}

#[cfg(test)]
mod tests;
