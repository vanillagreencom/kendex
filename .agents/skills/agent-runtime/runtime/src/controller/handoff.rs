//! The handoff's snapshot under its generation header: the one writer of
//! the `Start here: <UTC> generation=<N>` line a live transfer is admitted
//! on. The opener names what its body may not hold and amends the text
//! before the header is put on it.

use std::path::Path;

use crate::error::{Error, Result};
use crate::journal::Env;
use crate::record;

use super::MEMBER;

/// What the opener adds to the snapshot: a body line it refuses as a record
/// that belongs elsewhere, with the record's kind and its home, and its own
/// amendment of the composed text, read once the body passed every check.
pub struct Opener<'a> {
    pub misplaced: &'a dyn Fn(&str) -> Option<(&'static str, &'static str)>,
    pub amend: &'a dyn Fn(&str) -> Result<String>,
}

/// The snapshot as written: where, at which generation, when.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct Written {
    pub path: String,
    pub generation: u64,
    pub written_at: String,
}

fn refused(key: &'static str, fields: &[(&str, &str)]) -> Error {
    Error::refused(key, fields)
}

/// The handoff at `handoff` replaced by the `Start here: <UTC>
/// generation=<N>` header, the record's controller generation, over the
/// prepared body at `body`, amended by the opener. `keep_prior` keeps
/// the installed snapshot's content, its old header dropped, ahead of the
/// body, as a recovery that writes no fresh State does. The body is the
/// caller's session scratch: a link, an empty or irregular file, the
/// installed handoff itself, a `Start here:` line, and a line under
/// `## Progress log` the opener names as a record that belongs elsewhere are
/// refused. The write is a private staged file renamed over the
/// handoff, so a failure leaves the installed snapshot as it stood.
#[allow(
    clippy::disallowed_methods,
    reason = "the handoff's one writer: its own exclusive staged file renamed over the handoff it owns"
)]
pub fn write(
    path: &Path,
    body: &Path,
    handoff: &Path,
    keep_prior: bool,
    opener: &Opener,
    env: &Env,
) -> Result<Written> {
    use std::io::Write;
    let shown = handoff.display().to_string();
    let invalid = |reason: &str| {
        refused(
            "handoff-body-invalid",
            &[("path", &body.display().to_string()), ("reason", reason)],
        )
    };
    let failed = |step: &str| refused("handoff-write-failed", &[("path", &shown), ("step", step)]);
    let generation = record::read_document(path)?
        .and_then(|doc| doc.get(MEMBER)?.get("generation")?.as_u64())
        .ok_or_else(|| {
            refused(
                "handoff-stale",
                &[("path", &shown), ("expected", "unknown"), ("found", "none")],
            )
        })?;
    let meta = std::fs::symlink_metadata(body).map_err(|_| invalid("not-nonempty-regular"))?;
    if !meta.is_file() || meta.len() == 0 {
        return Err(invalid("not-nonempty-regular"));
    }
    let body_parent = body
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    std::fs::canonicalize(body_parent).map_err(|_| invalid("parent"))?;
    let parent = handoff
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    std::fs::create_dir_all(parent).map_err(|_| failed("mkdir"))?;
    let parent = std::fs::canonicalize(parent).map_err(|_| failed("parent"))?;
    let leaf = handoff.file_name().ok_or_else(|| failed("leaf"))?;
    let destination = parent.join(leaf);
    let standing = |destination: &Path| -> Result<bool> {
        match std::fs::symlink_metadata(destination) {
            Ok(m) if m.is_file() => Ok(true),
            Ok(_) => Err(failed("destination-type")),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(_) => Err(failed("destination-type")),
        }
    };
    let stood = standing(&destination)?;
    if stood && same_file(body, &destination) {
        return Err(invalid("installed-handoff"));
    }
    let payload = std::fs::read_to_string(body).map_err(|_| failed("body-read"))?;
    if payload.lines().any(|l| l.starts_with("Start here:")) {
        return Err(invalid("header"));
    }
    let mut in_log = false;
    for (n, line) in payload.lines().enumerate() {
        if line == "## Progress log" {
            in_log = true;
            continue;
        }
        if line.starts_with("## ") {
            in_log = false;
        }
        if in_log && let Some((kind, home)) = (opener.misplaced)(line) {
            return Err(refused(
                "handoff-body-invalid",
                &[
                    ("path", &body.display().to_string()),
                    ("reason", &format!("progress-log-{kind}")),
                    ("line", &(n + 1).to_string()),
                    ("home", home),
                ],
            ));
        }
    }
    let mut text = String::new();
    if keep_prior && stood {
        let prior = std::fs::read_to_string(&destination).map_err(|_| failed("prior-read"))?;
        let mut rows = prior.lines();
        let first = rows.next().unwrap_or("");
        if !first.starts_with("Start here:") {
            text.push_str(first);
            text.push('\n');
        }
        for row in rows {
            text.push_str(row);
            text.push('\n');
        }
        text.push('\n');
    }
    text.push_str(&payload);
    let amended = (opener.amend)(&text)?;
    let at = env.iso();
    let complete = format!("Start here: {at} generation={generation}\n\n{amended}");
    static STAGE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let stage = parent.join(format!(
        ".handoff.{}-{}",
        std::process::id(),
        STAGE.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    ));
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&stage)
        .map_err(|_| failed("mktemp"))?;
    let written = file
        .write_all(complete.as_bytes())
        .and_then(|()| file.sync_all())
        .map_err(|_| failed("body-write"))
        .and_then(|()| standing(&destination).map(|_| ()))
        .and_then(|()| {
            if same_file(body, &destination) {
                Err(invalid("installed-handoff"))
            } else {
                Ok(())
            }
        })
        .and_then(|()| std::fs::rename(&stage, &destination).map_err(|_| failed("rename")));
    if written.is_err() {
        let _ = std::fs::remove_file(&stage);
    }
    written?;
    Ok(Written {
        path: destination.display().to_string(),
        generation,
        written_at: at,
    })
}

fn same_file(a: &Path, b: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    match (std::fs::metadata(a), std::fs::metadata(b)) {
        (Ok(x), Ok(y)) => x.dev() == y.dev() && x.ino() == y.ino(),
        _ => false,
    }
}
