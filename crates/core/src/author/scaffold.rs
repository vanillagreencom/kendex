//! The Create flow's writer: a versioned scaffold that maps normalized
//! inputs to exact relative paths and bytes.
//!
//! Byte-stable by construction — no timestamps, no absolute paths, no
//! locale, no environment, no randomness. Identical inputs produce
//! identical trees, pinned by golden tests, so a re-run can prove nothing
//! drifted. Newlines are `\n` on every platform: git and GitHub treat that
//! as canonical, and a scaffold that differed by platform would break its
//! own promise.

use std::path::{Path, PathBuf};

use crate::env::Env;
use crate::error::{CoreError, Result};

use super::status::MineRow;

/// Part of the golden contract: bump when any emitted byte changes shape.
pub const SCAFFOLD_VERSION: u32 = 1;

const MIT_TEXT: &str = include_str!("assets/mit.txt");
const APACHE_TEXT: &str = include_str!("assets/apache-2.0.txt");

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize, specta::Type)]
#[serde(rename_all = "kebab-case")]
pub enum License {
    Mit,
    Apache2,
    /// Valid locally forever; blocks submission until chosen.
    NoneYet,
}

impl License {
    fn spdx(self) -> Option<&'static str> {
        match self {
            License::Mit => Some("MIT"),
            License::Apache2 => Some("Apache-2.0"),
            License::NoneYet => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, specta::Type)]
#[serde(rename_all = "camelCase")]
pub struct CreateRequest {
    /// Folder and repository name; must be a plain installable spelling.
    pub name: String,
    pub description: String,
    pub author: String,
    pub license: License,
    /// The folder to create — its parent must exist, itself must not.
    pub dir: PathBuf,
}

/// The exact files `create` will write, relative path → bytes. Pure: the
/// answer depends on the request alone.
pub fn plan(request: &CreateRequest) -> Result<Vec<(String, String)>> {
    let name = request.name.trim();
    if let Some(problem) = marketplace_name_problem(name) {
        return Err(CoreError::Authoring {
            message: format!("'{name}' cannot name a marketplace — {problem}"),
        });
    }
    let description = single_line(&request.description);
    let author = single_line(&request.author);
    let mut files = vec![
        (
            "kendex.toml".to_owned(),
            manifest_text(name, &description, &author, request.license),
        ),
        ("README.md".to_owned(), readme_text(name, &description)),
        (
            ".github/workflows/kendex-check.yml".to_owned(),
            WORKFLOW_TEXT.to_owned(),
        ),
    ];
    match request.license {
        License::Mit => files.push((
            "LICENSE".to_owned(),
            format!("MIT License\n\nCopyright (c) {author}\n\n{MIT_TEXT}"),
        )),
        License::Apache2 => files.push(("LICENSE".to_owned(), APACHE_TEXT.to_owned())),
        License::NoneYet => {}
    }
    Ok(files)
}

/// The two optional offers a "use existing" row shows. Each is its own
/// previewed write; an existing file is a refusal naming it, never a merge
/// or an overwrite.
pub fn offer_manifest(dir: &Path, name: &str, description: &str, author: &str) -> Result<String> {
    let target = dir.join(crate::manifest::MANIFEST_FILE);
    if target.exists() {
        return Err(CoreError::Authoring {
            message: format!(
                "{} already has a catalog config — edit it directly instead",
                dir.display()
            ),
        });
    }
    Ok(manifest_text(
        name,
        &single_line(description),
        &single_line(author),
        License::NoneYet,
    ))
}

pub fn offer_workflow(dir: &Path) -> Result<String> {
    let target = dir.join(WORKFLOW_REL);
    if target.exists() {
        return Err(CoreError::Authoring {
            message: format!(
                "{} already exists — edit it directly instead",
                target.display()
            ),
        });
    }
    Ok(WORKFLOW_TEXT.to_owned())
}

/// Accept the manifest offer: the bytes are regenerated here from the
/// given fields — never taken from the caller — and land at the one fixed
/// path. Only a folder registered under Mine can be written to.
pub fn accept_manifest_offer(
    env: &Env,
    dir: &Path,
    name: &str,
    description: &str,
    author: &str,
) -> Result<()> {
    let dir = require_registered(env, dir)?;
    let bytes = offer_manifest(&dir, name, description, author)?;
    write_offer(&dir, crate::manifest::MANIFEST_FILE, &bytes)
}

/// Accept the workflow offer — same contract as the manifest offer.
pub fn accept_workflow_offer(env: &Env, dir: &Path) -> Result<()> {
    let dir = require_registered(env, dir)?;
    let bytes = offer_workflow(&dir)?;
    write_offer(&dir, WORKFLOW_REL, &bytes)
}

pub const WORKFLOW_REL: &str = ".github/workflows/kendex-check.yml";

/// Offers write only into folders the person registered — an arbitrary
/// path over IPC is not a folder kendex has any business writing into.
fn require_registered(env: &Env, dir: &Path) -> Result<std::path::PathBuf> {
    let canonical = dir.canonicalize().map_err(|e| CoreError::io(dir, e))?;
    if !super::registry::list(env)?.contains(&canonical) {
        return Err(CoreError::Authoring {
            message: format!("{} is not under Mine — register it first", dir.display()),
        });
    }
    Ok(canonical)
}

/// One offered write at a fixed relative path. Anything already at the
/// target — a file, a directory, even a dangling symlink — refuses, and a
/// symlinked intermediate directory refuses rather than being followed
/// out of the folder.
fn write_offer(dir: &Path, rel: &str, bytes: &str) -> Result<()> {
    let path = dir.join(rel);
    if path.symlink_metadata().is_ok() {
        return Err(CoreError::Authoring {
            message: format!(
                "{} appeared since the preview — nothing was written",
                path.display()
            ),
        });
    }
    let mut walked = dir.to_path_buf();
    for component in Path::new(rel).components() {
        walked.push(component);
        if let Ok(meta) = walked.symlink_metadata()
            && meta.file_type().is_symlink()
        {
            return Err(CoreError::Authoring {
                message: format!(
                    "{} is a symlink — kendex writes only inside the folder itself",
                    walked.display()
                ),
            });
        }
    }
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| CoreError::io(parent, e))?;
    }
    crate::fs::atomic_write(&path, bytes)
}

/// The name doubles as the folder and the GitHub repository name, so it
/// lives by GitHub's repo-name alphabet, not the looser item rules.
fn marketplace_name_problem(name: &str) -> Option<String> {
    if name.is_empty() {
        return Some("a name cannot be empty".to_owned());
    }
    if name.starts_with(['-', '.']) {
        return Some("it cannot start with `-` or `.`".to_owned());
    }
    if let Some(bad) = name
        .chars()
        .find(|c| !(c.is_ascii_alphanumeric() || "._-".contains(*c)))
    {
        return Some(format!(
            "`{bad}` cannot appear in a repository name — use letters, digits, `-`, `_` or `.`"
        ));
    }
    None
}

fn single_line(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn manifest_text(name: &str, description: &str, author: &str, license: License) -> String {
    let mut text = String::from("[marketplace]\n");
    text.push_str(&format!("name = {}\n", toml_string(name)));
    if !description.is_empty() {
        text.push_str(&format!("description = {}\n", toml_string(description)));
    }
    if !author.is_empty() {
        text.push_str(&format!("author = {}\n", toml_string(author)));
    }
    if let Some(spdx) = license.spdx() {
        text.push_str(&format!("license = {}\n", toml_string(spdx)));
    }
    text.push_str(
        "\n# Items live in agents/, skills/, hooks/, commands/ and mcp/.\n\
         # Curated sets: [bundles.<name>] with description and members, e.g.\n\
         # [bundles.starter]\n\
         # description = \"Everything a new project needs\"\n\
         # members = [\"skill/my-skill\", \"agent/my-agent\"]\n",
    );
    text
}

fn toml_string(value: &str) -> String {
    let mut quoted = String::with_capacity(value.len() + 2);
    quoted.push('"');
    for ch in value.chars() {
        match ch {
            '"' => quoted.push_str("\\\""),
            '\\' => quoted.push_str("\\\\"),
            _ => quoted.push(ch),
        }
    }
    quoted.push('"');
    quoted
}

fn readme_text(name: &str, description: &str) -> String {
    let described = match description.is_empty() {
        true => String::new(),
        false => format!("\n{description}\n"),
    };
    format!(
        "# {name}\n{described}\n\
         A [kendex](https://kendex.ai) marketplace: agents, skills, hooks,\n\
         commands and MCP servers that install with one command.\n\n\
         ## Install from it\n\n\
         ```\n\
         kendex marketplace subscribe <owner>/{name}\n\
         kendex add <package>\n\
         ```\n\n\
         Or subscribe inside the kendex app: Marketplaces → Subscribe.\n\n\
         ## Layout\n\n\
         ```\n\
         kendex.toml            what this marketplace says about itself\n\
         agents/<name>.md       one agent per file\n\
         skills/<name>/SKILL.md one folder per skill\n\
         hooks/<name>.sh        commands/<name>.md   mcp/<name>.toml\n\
         ```\n\n\
         `kendex check --catalog . --strict` validates every package the way\n\
         installing validates it; the included workflow runs it on each push.\n",
    )
}

const WORKFLOW_TEXT: &str = "\
# Validates every package in this catalog the way installing validates it.
name: kendex check
on:
  push:
  pull_request:
jobs:
  kendex:
    uses: vanillagreencom/kendex/.github/workflows/catalog-check.yml@v5.0.0
    with:
      path: .
      strict: true
";

mod make;
pub use make::create;
