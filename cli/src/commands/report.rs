//! `vstack report` — file a workflow-error issue for a vstack asset and route
//! it to the correct repository.
//!
//! Consuming repos historically misfiled project-local asset problems into
//! `vanillagreencom/vstack` because the filing agent was asked to *judge*
//! ownership and got it wrong, with a default of "file everything upstream".
//! This command moves the ownership decision out of a judgement call and into
//! two concrete signals, and flips the default to "file to the LOCAL repo unless
//! the asset is provably vstack-owned":
//!
//! 1. **Installed frontmatter.** Skills (and agents) that declare provenance —
//!    `source: vstack` or a `repository` identifying the upstream repo — are
//!    recognized as vstack-owned.
//! 2. **The project lock's recorded source identity.** For an asset whose
//!    installed files carry no provenance frontmatter (hooks, and agents that
//!    omit it), the signal is the lock entry's durable `source_repo` GitHub
//!    identity. Legacy entries may still resolve through a live source Git
//!    origin or the upstream `owner/repo` remote shorthand.
//!
//! Anything else defaults to project-local. This is a best-effort ownership
//! signal, not a cryptographic proof of authorship; when the signals are absent
//! it deliberately errs toward the local repo.
//!
//! There is intentionally no interactive prompt: non-interactive shells crash on
//! stdin reads (`os error 6`). `--dry-run` is the only preview mechanism.

use crate::config::{self, ItemKind, LockFile};
use crate::frontmatter::split_yaml_frontmatter;
use crate::harness::Harness;
use crate::scope::ScopeFilter;
use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

/// Default upstream repo for vstack-owned issues.
const DEFAULT_UPSTREAM: &str = "vanillagreencom/vstack";

/// Parsed CLI arguments for `vstack report`. Bundled into a struct so the match
/// arm in `main.rs` stays readable and to avoid a `too_many_arguments` lint.
pub struct ReportArgs {
    pub skill: Option<String>,
    pub agent: Option<String>,
    pub hook: Option<String>,
    pub asset: Option<String>,
    pub title: String,
    pub body: Option<String>,
    pub body_file: Option<PathBuf>,
    pub scope: Option<String>,
    pub global: bool,
    pub upstream: Option<String>,
    pub dry_run: bool,
}

/// Where a report should be filed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Ownership {
    /// The asset is provably owned by vstack — file upstream.
    Vstack,
    /// The asset belongs to the local project (safe default) — file locally.
    ProjectLocal,
}

impl Ownership {
    fn label(self) -> &'static str {
        match self {
            Ownership::Vstack => "vstack",
            Ownership::ProjectLocal => "project-local",
        }
    }
}

/// An asset selector: a name plus an optional kind constraint. `--asset` yields
/// `kind: None` (match any kind by name); `--skill`/`--agent`/`--hook` constrain
/// to a specific kind.
#[derive(Debug, Clone, PartialEq, Eq)]
struct AssetSelector {
    name: String,
    kind: Option<ItemKind>,
}

/// The ownership-relevant subset of an installed asset's frontmatter.
#[derive(Debug, Clone, PartialEq, Eq)]
struct AssetFrontmatter {
    source: Option<String>,
    repository: Option<String>,
}

/// The resolved routing target for a report.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Target {
    /// File to the named upstream repo (`gh issue create --repo <owner/repo>`).
    Upstream(String),
    /// File to the current repo's origin (`gh issue create`, no `--repo`).
    Local,
}

/// A fully-resolved plan for a report: what was decided, where it goes, the
/// exact `gh` arguments, and the body actually sent (with marker for vstack).
#[derive(Debug, Clone, PartialEq, Eq)]
struct ReportPlan {
    ownership: Ownership,
    target: Target,
    gh_args: Vec<String>,
    body_with_marker: String,
}

/// Abstraction over the `gh issue create` call so tests can inject a fake and
/// never shell out to real `gh`. Returns the issue URL (or `gh` stdout) on
/// success, or a captured error string on any failure.
trait IssueFiler {
    fn file(&self, gh_args: &[String]) -> std::result::Result<String, String>;
}

/// Production filer: shells out to `gh`.
struct GhFiler;

impl IssueFiler for GhFiler {
    fn file(&self, gh_args: &[String]) -> std::result::Result<String, String> {
        let output = std::process::Command::new("gh")
            .args(gh_args)
            .output()
            .map_err(|e| {
                format!("could not launch `gh` (is the GitHub CLI installed and on PATH?): {e}")
            })?;
        if output.status.success() {
            Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
            let detail = if stderr.is_empty() { stdout } else { stderr };
            Err(format!("gh exited with {}: {detail}", output.status))
        }
    }
}

/// Entry point wired into `main.rs`.
pub fn run(args: ReportArgs) -> Result<()> {
    run_with_filer(args, &GhFiler)
}

/// Testable core: same as [`run`] but with an injectable filer so the routing
/// and error paths can be exercised without invoking real `gh`.
fn run_with_filer(args: ReportArgs, filer: &dyn IssueFiler) -> Result<()> {
    let selector = resolve_selector(
        args.skill.as_deref(),
        args.agent.as_deref(),
        args.hook.as_deref(),
        args.asset.as_deref(),
    )?;
    let body = resolve_body(args.body.as_deref(), args.body_file.as_deref())?;
    let global = resolve_scope(args.scope.as_deref(), args.global)?;
    let upstream = args
        .upstream
        .unwrap_or_else(|| DEFAULT_UPSTREAM.to_string());

    let lock = LockFile::load(&config::lock_file_path(global))?;
    let frontmatter = selector
        .as_ref()
        .and_then(|sel| load_asset_frontmatter(sel, &lock, global));

    if selector.is_none() {
        eprintln!(
            "warning: no asset selector (--skill/--agent/--hook/--asset) provided; \
             ownership could not be determined, so this report defaults to the local repo."
        );
    }

    let plan = plan_for_inputs(
        &lock,
        selector.as_ref(),
        frontmatter.as_ref(),
        &args.title,
        &body,
        &upstream,
    );

    // Print the decision and target before doing anything.
    eprintln!("Ownership: {}", plan.ownership.label());
    eprintln!("Target repo: {}", target_label(&plan.target));

    if args.dry_run {
        eprintln!("[dry-run] would run: {}", render_gh_command(&plan.gh_args));
        return Ok(());
    }

    match filer.file(&plan.gh_args) {
        Ok(url) => {
            if url.is_empty() {
                println!("Issue filed.");
            } else {
                println!("Issue filed: {url}");
            }
            Ok(())
        }
        Err(err) => {
            let saved = save_report_body(&args.title, &plan.body_with_marker).ok();
            print_failure_guidance(
                &err,
                plan.ownership,
                &plan.target,
                &upstream,
                saved.as_deref(),
            );
            anyhow::bail!("failed to file the report via gh (see guidance above)");
        }
    }
}

/// Ownership resolver. Pure: takes already-loaded inputs (the lock, an optional
/// selector, optional parsed frontmatter, and the configured upstream slug) so
/// it only touches disk for the legacy path-present Git-origin fallback.
///
/// Precedence:
/// 1. Frontmatter self-declares vstack: `source: vstack`, OR a `repository` whose
///    parsed `owner/repo` slug equals the canonical `vanillagreencom/vstack`.
/// 2. Else name is in the lock (kind matching any given kind selector) with a
///    `source_repo` that identifies the canonical or configured upstream
///    `owner/repo` → Vstack. A
///    foreign `source_repo` is authoritative project-local; live source Git
///    origin and remote shorthand fallbacks only apply to legacy entries that
///    have no recorded `source_repo`.
/// 3. Else → ProjectLocal (safe default).
/// 4. No selector at all → ProjectLocal (safe default).
fn resolve_ownership(
    lock: &LockFile,
    selector: Option<&AssetSelector>,
    frontmatter: Option<&AssetFrontmatter>,
    upstream: &str,
) -> Ownership {
    // Rule 4: with no asset to reason about, default to local.
    let Some(selector) = selector else {
        return Ownership::ProjectLocal;
    };

    // Rule 1: the installed asset self-declares vstack provenance.
    if let Some(fm) = frontmatter
        && frontmatter_declares_vstack(fm)
    {
        return Ownership::Vstack;
    }

    // Rule 2: the lock says it came from a vstack source (local dir or remote slug).
    if let Some(entry) = lock.entries.get(&selector.name) {
        let kind_matches = selector.kind.is_none_or(|k| k == entry.kind);
        if kind_matches && lock_entry_is_vstack(entry, upstream) {
            return Ownership::Vstack;
        }
    }

    // Rule 3: absent from the lock, or lock source is not vstack, and no vstack
    // frontmatter — treat as project-local.
    Ownership::ProjectLocal
}

/// True when a lock entry identifies vstack by repository identity. This
/// deliberately ignores source layout: a local project-shaped package source is
/// not upstream unless its recorded or live GitHub identity is upstream.
fn lock_entry_is_vstack(entry: &config::LockEntry, upstream: &str) -> bool {
    if let Some(source_repo) = entry.source_repo.as_deref() {
        return repo_is_vstack_upstream(source_repo, upstream);
    }

    // Skills carry their own provenance frontmatter. A marker-only orphaned
    // skill recovered after lock loss has no attributable source, even though
    // reconciliation needs a source hint so a later successful refresh can
    // reinstall it. Other legacy kinds (including Pi packages) have no such
    // self-provenance and retain the live-source fallback.
    if entry.kind == ItemKind::Skill {
        return false;
    }

    config::source_repo_for_source(
        config::resolve_source_path(&entry.source).as_deref(),
        &entry.source,
    )
    .is_some_and(|source_repo| repo_is_vstack_upstream(&source_repo, upstream))
}

/// `--upstream` redirects filing and may name a fork that owns a vstack
/// distribution, but it must never stop canonical vstack assets from being
/// recognized as upstream-owned.
fn repo_is_vstack_upstream(repository: &str, upstream: &str) -> bool {
    config::github_slug_eq(repository, DEFAULT_UPSTREAM)
        || config::github_slug_eq(repository, upstream)
}

/// True when frontmatter self-declares vstack ownership. The `repository` field
/// is matched by exact `owner/repo` identity against the canonical upstream —
/// NOT a substring — so `vanillagreencom/vstack-plugins` does not falsely match.
fn frontmatter_declares_vstack(fm: &AssetFrontmatter) -> bool {
    if fm.source.as_deref() == Some("vstack") {
        return true;
    }
    fm.repository
        .as_deref()
        .is_some_and(|repo| config::github_slug_eq(repo, DEFAULT_UPSTREAM))
}

/// Compose ownership resolution and gh-argument building into a single plan.
/// Pure (modulo the disk stat inside `resolve_ownership`).
fn plan_for_inputs(
    lock: &LockFile,
    selector: Option<&AssetSelector>,
    frontmatter: Option<&AssetFrontmatter>,
    title: &str,
    body: &str,
    upstream: &str,
) -> ReportPlan {
    let ownership = resolve_ownership(lock, selector, frontmatter, upstream);
    let name = selector.map(|s| s.name.as_str());
    let kind_label = kind_label_for(lock, selector);
    build_plan(ownership, name, &kind_label, title, body, upstream)
}

/// Resolve the kind label used in the marker: the explicit kind selector, else
/// the lock entry's kind, else "unknown".
fn kind_label_for(lock: &LockFile, selector: Option<&AssetSelector>) -> String {
    let Some(sel) = selector else {
        return "unknown".to_string();
    };
    sel.kind
        .map(|k| k.to_string())
        .or_else(|| lock.entries.get(&sel.name).map(|e| e.kind.to_string()))
        .unwrap_or_else(|| "unknown".to_string())
}

/// Build the routing target, the exact `gh` args, and the body that will be
/// sent. The machine-readable marker is appended (as the last line) for
/// vstack-targeted issues ONLY, so the CI ownership guard can recognize
/// command-filed issues.
fn build_plan(
    ownership: Ownership,
    name: Option<&str>,
    kind_label: &str,
    title: &str,
    body: &str,
    upstream: &str,
) -> ReportPlan {
    match ownership {
        Ownership::Vstack => {
            let marker = marker_line(name.unwrap_or("unknown"), kind_label);
            let body_with_marker = format!("{body}{marker}");
            let gh_args = vec![
                "issue".to_string(),
                "create".to_string(),
                "--repo".to_string(),
                upstream.to_string(),
                "--title".to_string(),
                title.to_string(),
                "--body".to_string(),
                body_with_marker.clone(),
            ];
            ReportPlan {
                ownership,
                target: Target::Upstream(upstream.to_string()),
                gh_args,
                body_with_marker,
            }
        }
        Ownership::ProjectLocal => {
            // No `--repo`: gh files against the current repo's origin. No marker:
            // the marker is only meaningful upstream.
            let gh_args = vec![
                "issue".to_string(),
                "create".to_string(),
                "--title".to_string(),
                title.to_string(),
                "--body".to_string(),
                body.to_string(),
            ];
            ReportPlan {
                ownership,
                target: Target::Local,
                gh_args,
                body_with_marker: body.to_string(),
            }
        }
    }
}

/// Render the machine-readable marker line appended to vstack-targeted issues.
fn marker_line(name: &str, kind_label: &str) -> String {
    format!("\n\n<!-- vstack-report:v1 asset={name} kind={kind_label} ownership=vstack -->")
}

/// Resolve at most one asset selector, erroring if more than one is given.
fn resolve_selector(
    skill: Option<&str>,
    agent: Option<&str>,
    hook: Option<&str>,
    asset: Option<&str>,
) -> Result<Option<AssetSelector>> {
    let mut selectors: Vec<AssetSelector> = Vec::new();
    if let Some(name) = skill {
        selectors.push(AssetSelector {
            name: name.to_string(),
            kind: Some(ItemKind::Skill),
        });
    }
    if let Some(name) = agent {
        selectors.push(AssetSelector {
            name: name.to_string(),
            kind: Some(ItemKind::Agent),
        });
    }
    if let Some(name) = hook {
        selectors.push(AssetSelector {
            name: name.to_string(),
            kind: Some(ItemKind::Hook),
        });
    }
    if let Some(name) = asset {
        selectors.push(AssetSelector {
            name: name.to_string(),
            kind: None,
        });
    }

    match selectors.len() {
        0 => Ok(None),
        1 => Ok(Some(selectors.remove(0))),
        _ => anyhow::bail!(
            "pass at most one asset selector: exactly one of --skill/--agent/--hook/--asset"
        ),
    }
}

/// Resolve the report body from `--body` or `--body-file`. Exactly one is
/// required.
fn resolve_body(body: Option<&str>, body_file: Option<&Path>) -> Result<String> {
    match (body, body_file) {
        (Some(_), Some(_)) => {
            anyhow::bail!("pass only one of --body or --body-file, not both")
        }
        (None, None) => {
            anyhow::bail!("a report body is required: pass --body <str> or --body-file <path>")
        }
        (Some(text), None) => Ok(text.to_string()),
        (None, Some(path)) => std::fs::read_to_string(path)
            .with_context(|| format!("reading body file {}", path.display())),
    }
}

/// Resolve the ownership-resolution scope to a `global` bool. Mirrors the
/// sibling-command convention (`--scope` wins over `--global`; `--global` alone
/// means global; default project), but reports against a single lock, so `all`
/// is rejected.
fn resolve_scope(scope: Option<&str>, global: bool) -> Result<bool> {
    match ScopeFilter::resolve(scope, global, ScopeFilter::Project)? {
        ScopeFilter::Project => Ok(false),
        ScopeFilter::Global => Ok(true),
        ScopeFilter::All => anyhow::bail!(
            "report resolves ownership against one lock; use --scope project or --scope global (not all)"
        ),
    }
}

/// Locate and parse the installed asset's frontmatter for ownership checking.
/// Returns None if the file can't be found or parsed (callers then fall through
/// to the lock-based check).
fn load_asset_frontmatter(
    selector: &AssetSelector,
    lock: &LockFile,
    global: bool,
) -> Option<AssetFrontmatter> {
    let path = locate_installed_asset(selector, lock, global)?;
    let content = std::fs::read_to_string(&path).ok()?;
    let (fm, _body) = split_yaml_frontmatter(&content).ok()?;
    parse_asset_frontmatter(&fm)
}

/// Find the installed asset file whose frontmatter we should read. Skills live
/// at `.agents/skills/<name>/SKILL.md`; agents live in a harness agents dir.
/// Hooks/Pi/Extras have no YAML source frontmatter, so they resolve to None and
/// fall through to the lock check.
fn locate_installed_asset(
    selector: &AssetSelector,
    lock: &LockFile,
    global: bool,
) -> Option<PathBuf> {
    let kinds: Vec<ItemKind> = match selector.kind {
        Some(kind) => vec![kind],
        None => match lock.entries.get(&selector.name) {
            Some(entry) => vec![entry.kind],
            None => vec![ItemKind::Skill, ItemKind::Agent],
        },
    };

    for kind in kinds {
        match kind {
            ItemKind::Skill => {
                if let Some(path) = find_installed_skill_file(global, &selector.name) {
                    return Some(path);
                }
            }
            ItemKind::Agent => {
                if let Some(path) = find_installed_agent_file(global, &selector.name) {
                    return Some(path);
                }
            }
            ItemKind::Hook | ItemKind::PiExtension | ItemKind::Extra => {}
        }
    }
    None
}

/// Probe every harness's skills dir for `<name>/SKILL.md`, returning the first
/// hit. Mirrors [`find_installed_agent_file`] and reuses the canonical
/// [`Harness::skills_dir`] so global installs (Claude/OpenCode/Codex/Pi homes)
/// are all covered — the previous hand-rolled `~/.config/vstack/skills` path
/// matched no harness's global skill location.
fn find_installed_skill_file(global: bool, name: &str) -> Option<PathBuf> {
    for harness in Harness::ALL {
        let path = harness.skills_dir(global).join(name).join("SKILL.md");
        if path.exists() {
            return Some(path);
        }
    }
    None
}

fn find_installed_agent_file(global: bool, name: &str) -> Option<PathBuf> {
    for harness in Harness::ALL {
        let dir = harness.agents_dir(global);
        let md = dir.join(format!("{name}.md"));
        if md.exists() {
            return Some(md);
        }
        let toml = dir.join(format!("{name}.toml"));
        if toml.exists() {
            return Some(toml);
        }
    }
    None
}

/// Parse the ownership-relevant fields out of a frontmatter string. Handles both
/// top-level `source:`/`repository:` and the common nested `metadata:` block
/// (vstack skills declare provenance under `metadata:`). Navigates a parsed
/// YAML value so a non-string field never aborts the whole parse.
fn parse_asset_frontmatter(fm: &str) -> Option<AssetFrontmatter> {
    let value: serde_yaml::Value = serde_yaml::from_str(fm).ok()?;
    let get_str = |v: &serde_yaml::Value, key: &str| -> Option<String> {
        v.get(key).and_then(|x| x.as_str()).map(str::to_string)
    };
    let (meta_source, meta_repo) = match value.get("metadata") {
        Some(meta) => (get_str(meta, "source"), get_str(meta, "repository")),
        None => (None, None),
    };
    Some(AssetFrontmatter {
        source: get_str(&value, "source").or(meta_source),
        repository: get_str(&value, "repository").or(meta_repo),
    })
}

fn target_label(target: &Target) -> String {
    match target {
        Target::Upstream(repo) => format!("{repo} (vstack upstream)"),
        Target::Local => "this project's origin (gh uses the current repo)".to_string(),
    }
}

/// Render a `gh <args...>` invocation with minimal shell quoting for display.
fn render_gh_command(gh_args: &[String]) -> String {
    let mut rendered = String::from("gh");
    for arg in gh_args {
        rendered.push(' ');
        rendered.push_str(&shell_quote(arg));
    }
    rendered
}

fn shell_quote(s: &str) -> String {
    let safe = !s.is_empty()
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || "-_./:@=,".contains(c));
    if safe {
        s.to_string()
    } else {
        format!("'{}'", s.replace('\'', "'\\''"))
    }
}

/// Save the rendered report (title header + body) to the OS temp dir, NOT the
/// repo working tree — writing into a consumer repo would pollute it with an
/// untracked file. The filename carries the process id and a nanosecond stamp so
/// it is unpredictable: a fixed `vstack-report-<slug>.md` in a world-writable
/// temp dir invites a symlink pre-creation clobber on shared hosts. Returns the
/// absolute path written.
fn save_report_body(title: &str, body: &str) -> Result<PathBuf> {
    let slug = slugify(title);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let path = std::env::temp_dir().join(format!(
        "vstack-report-{slug}-{}-{nanos}.md",
        std::process::id()
    ));
    let content = format!("# {title}\n\n{body}\n");
    std::fs::write(&path, content)
        .with_context(|| format!("writing report body to {}", path.display()))?;
    Ok(path)
}

fn slugify(title: &str) -> String {
    let mut slug = String::new();
    let mut prev_dash = false;
    for c in title.chars() {
        if c.is_ascii_alphanumeric() {
            slug.push(c.to_ascii_lowercase());
            prev_dash = false;
        } else if !prev_dash {
            slug.push('-');
            prev_dash = true;
        }
    }
    let trimmed: String = slug.trim_matches('-').chars().take(60).collect();
    let trimmed = trimmed.trim_matches('-').to_string();
    if trimmed.is_empty() {
        "report".to_string()
    } else {
        trimmed
    }
}

/// Print actionable guidance when `gh` fails, including the captured error, the
/// resolved ownership, the intended issues URL, and where the body was saved.
fn print_failure_guidance(
    err: &str,
    ownership: Ownership,
    target: &Target,
    upstream: &str,
    saved: Option<&Path>,
) {
    eprintln!("\nFailed to file the issue via gh.\n");
    eprintln!("  gh error: {err}");
    eprintln!("  Resolved ownership: {}", ownership.label());
    let issues_url = match target {
        Target::Upstream(_) => format!("https://github.com/{upstream}/issues"),
        Target::Local => local_repo_issues_url()
            .unwrap_or_else(|| "your project's origin repository".to_string()),
    };
    eprintln!("  Intended repo: {issues_url}");
    match saved {
        Some(path) => eprintln!("  Saved report body: {}", path.display()),
        None => eprintln!("  Saved report body: (failed to write to the temp dir)"),
    }
    eprintln!(
        "\nFile it manually at that repo, or use your own project's issue tracker \
         (GitHub issues / Linear / etc.)."
    );
}

/// Best-effort resolution of the local repo's issues URL from `origin`.
fn local_repo_issues_url() -> Option<String> {
    let output = std::process::Command::new("git")
        .args(["remote", "get-url", "origin"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let url = String::from_utf8_lossy(&output.stdout);
    let slug = config::parse_github_slug(url.trim())?;
    Some(format!("https://github.com/{slug}/issues"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{InstallMethod, ItemKind, LockEntry, LockFile};

    fn lock_with(name: &str, kind: ItemKind, source: &str) -> LockFile {
        lock_with_repo(name, kind, source, None)
    }

    fn lock_with_repo(
        name: &str,
        kind: ItemKind,
        source: &str,
        source_repo: Option<&str>,
    ) -> LockFile {
        let mut lock = LockFile::default();
        lock.add(LockEntry {
            name: name.to_string(),
            kind,
            source: source.to_string(),
            source_repo: source_repo.map(str::to_string),
            harnesses: vec!["claude-code".to_string()],
            method: InstallMethod::Copy,
            installed_at: "2026-07-21T00:00:00Z".to_string(),
            source_hash: String::new(),
        });
        lock
    }

    fn init_git_origin(dir: &Path, origin: &str) {
        let status = std::process::Command::new("git")
            .args(["init", "-q"])
            .current_dir(dir)
            .status()
            .unwrap();
        assert!(status.success());
        let status = std::process::Command::new("git")
            .args(["remote", "add", "origin", origin])
            .current_dir(dir)
            .status()
            .unwrap();
        assert!(status.success());
    }

    fn tmpdir(label: &str) -> PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("system clock before epoch")
            .as_nanos();
        std::env::temp_dir().join(format!(
            "vstack-report-{label}-{}-{nanos}",
            std::process::id()
        ))
    }

    /// Create an on-disk directory shaped like a vstack source (2+ item dirs),
    /// so `is_vstack_source` returns true for it.
    fn make_vstack_source(label: &str) -> PathBuf {
        let dir = tmpdir(label);
        std::fs::create_dir_all(dir.join("agents")).unwrap();
        std::fs::create_dir_all(dir.join("skills")).unwrap();
        std::fs::create_dir_all(dir.join("hooks")).unwrap();
        dir
    }

    fn selector(name: &str, kind: Option<ItemKind>) -> AssetSelector {
        AssetSelector {
            name: name.to_string(),
            kind,
        }
    }

    /// A project-scope `ReportArgs` with an inline body, for driving
    /// `run_with_filer` in tests.
    fn skill_args(skill: &str, title: &str, body: &str, dry_run: bool) -> ReportArgs {
        ReportArgs {
            skill: Some(skill.to_string()),
            agent: None,
            hook: None,
            asset: None,
            title: title.to_string(),
            body: Some(body.to_string()),
            body_file: None,
            global: false,
            scope: Some("project".to_string()),
            upstream: None,
            dry_run,
        }
    }

    /// Write a SKILL.md with vstack provenance frontmatter under the project
    /// skills dir (`.agents/skills/<name>/SKILL.md`, the Codex/Pi project root).
    fn write_vstack_skill(project_root: &Path, name: &str) {
        let dir = project_root.join(".agents").join("skills").join(name);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("SKILL.md"),
            "---\nname: skillname\nmetadata:\n  source: vstack\n---\n\n# body\n",
        )
        .unwrap();
    }

    /// Temp-dir report files this test process wrote for a given title slug.
    fn saved_reports_for(slug: &str) -> Vec<PathBuf> {
        let prefix = format!("vstack-report-{slug}-{}-", std::process::id());
        let mut out = Vec::new();
        if let Ok(entries) = std::fs::read_dir(std::env::temp_dir()) {
            for entry in entries.flatten() {
                let name = entry.file_name();
                let name = name.to_string_lossy();
                if name.starts_with(&prefix) && name.ends_with(".md") {
                    out.push(entry.path());
                }
            }
        }
        out
    }

    // --- resolve_ownership: precedence branches -------------------------------

    #[test]
    fn ownership_vstack_via_frontmatter_source() {
        // Rule 1: frontmatter `source: vstack` wins even against an empty lock.
        let lock = LockFile::default();
        let fm = AssetFrontmatter {
            source: Some("vstack".to_string()),
            repository: None,
        };
        let sel = selector("github", Some(ItemKind::Skill));
        assert_eq!(
            resolve_ownership(&lock, Some(&sel), Some(&fm), DEFAULT_UPSTREAM),
            Ownership::Vstack
        );
    }

    #[test]
    fn ownership_vstack_via_frontmatter_repository() {
        // Rule 1: a repository field pointing at vanillagreencom/vstack.
        let lock = LockFile::default();
        let fm = AssetFrontmatter {
            source: None,
            repository: Some("https://github.com/vanillagreencom/vstack".to_string()),
        };
        let sel = selector("github", Some(ItemKind::Skill));
        assert_eq!(
            resolve_ownership(&lock, Some(&sel), Some(&fm), DEFAULT_UPSTREAM),
            Ownership::Vstack
        );
    }

    #[test]
    fn ownership_project_local_for_vstack_shaped_lock_source_without_repo_identity() {
        // Rule 2 no longer trusts layout alone: arbitrary project-local package
        // sources can be vstack-shaped without being upstream-owned.
        let source = make_vstack_source("lock-source");
        let lock = lock_with("dev", ItemKind::Skill, source.to_str().unwrap());
        let sel = selector("dev", Some(ItemKind::Skill));
        assert_eq!(
            resolve_ownership(&lock, Some(&sel), None, DEFAULT_UPSTREAM),
            Ownership::ProjectLocal
        );
        let _ = std::fs::remove_dir_all(&source);
    }

    #[test]
    fn ownership_vstack_via_lock_source_repo_when_path_absent() {
        let missing_source = tmpdir("missing-vstack-source");
        let lock = lock_with_repo(
            "dev",
            ItemKind::Agent,
            missing_source.to_str().unwrap(),
            Some("vanillagreencom/vstack"),
        );
        let sel = selector("dev", Some(ItemKind::Agent));
        assert_eq!(
            resolve_ownership(&lock, Some(&sel), None, DEFAULT_UPSTREAM),
            Ownership::Vstack
        );
    }

    #[test]
    fn ownership_vstack_via_canonical_lock_source_repo_with_upstream_override() {
        let missing_source = tmpdir("missing-vstack-source-custom-target");
        let lock = lock_with_repo(
            "dev",
            ItemKind::Agent,
            missing_source.to_str().unwrap(),
            Some(DEFAULT_UPSTREAM),
        );
        let sel = selector("dev", Some(ItemKind::Agent));
        assert_eq!(
            resolve_ownership(&lock, Some(&sel), None, "example/vstack-fork"),
            Ownership::Vstack
        );
    }

    #[test]
    fn ownership_vstack_via_configured_fork_lock_source_repo() {
        let missing_source = tmpdir("missing-vstack-fork-source");
        let lock = lock_with_repo(
            "dev",
            ItemKind::Agent,
            missing_source.to_str().unwrap(),
            Some("example/vstack-fork"),
        );
        let sel = selector("dev", Some(ItemKind::Agent));
        assert_eq!(
            resolve_ownership(&lock, Some(&sel), None, "example/vstack-fork"),
            Ownership::Vstack
        );
    }

    #[test]
    fn ownership_vstack_via_legacy_live_source_git_origin() {
        let source = make_vstack_source("live-origin");
        init_git_origin(&source, "git@github.com:vanillagreencom/vstack.git");
        let lock = lock_with("guard", ItemKind::Hook, source.to_str().unwrap());
        let sel = selector("guard", Some(ItemKind::Hook));
        assert_eq!(
            resolve_ownership(&lock, Some(&sel), None, DEFAULT_UPSTREAM),
            Ownership::Vstack
        );
        let _ = std::fs::remove_dir_all(&source);
    }

    #[test]
    fn ownership_vstack_via_canonical_legacy_source_with_upstream_override() {
        let lock = lock_with("guard", ItemKind::Hook, DEFAULT_UPSTREAM);
        let sel = selector("guard", Some(ItemKind::Hook));
        assert_eq!(
            resolve_ownership(&lock, Some(&sel), None, "example/vstack-fork"),
            Ownership::Vstack
        );
    }

    #[test]
    fn ownership_project_local_when_source_repo_is_not_upstream() {
        let missing_source = tmpdir("missing-local-source");
        let lock = lock_with_repo(
            "guard",
            ItemKind::Hook,
            missing_source.to_str().unwrap(),
            Some("example/project-assets"),
        );
        let sel = selector("guard", Some(ItemKind::Hook));
        assert_eq!(
            resolve_ownership(&lock, Some(&sel), None, DEFAULT_UPSTREAM),
            Ownership::ProjectLocal
        );
    }

    #[test]
    fn ownership_project_local_when_foreign_source_repo_has_live_vstack_origin() {
        let source = make_vstack_source("foreign-recorded-live-vstack");
        init_git_origin(&source, "git@github.com:vanillagreencom/vstack.git");
        let lock = lock_with_repo(
            "guard",
            ItemKind::Hook,
            source.to_str().unwrap(),
            Some("example/project-assets"),
        );
        let sel = selector("guard", Some(ItemKind::Hook));
        assert_eq!(
            resolve_ownership(&lock, Some(&sel), None, DEFAULT_UPSTREAM),
            Ownership::ProjectLocal
        );
        let _ = std::fs::remove_dir_all(&source);
    }

    #[test]
    fn ownership_vstack_via_lock_source_requires_kind_match() {
        // Rule 2 kind guard: a --agent selector must not match a skill lock entry.
        let source = make_vstack_source("kind-mismatch");
        let lock = lock_with("dev", ItemKind::Skill, source.to_str().unwrap());
        let sel = selector("dev", Some(ItemKind::Agent));
        assert_eq!(
            resolve_ownership(&lock, Some(&sel), None, DEFAULT_UPSTREAM),
            Ownership::ProjectLocal
        );
        let _ = std::fs::remove_dir_all(&source);
    }

    #[test]
    fn ownership_project_local_absent_from_lock() {
        // Rule 3: named, but not in the lock and no vstack frontmatter.
        let lock = LockFile::default();
        let sel = selector("visual-qa", Some(ItemKind::Skill));
        assert_eq!(
            resolve_ownership(&lock, Some(&sel), None, DEFAULT_UPSTREAM),
            Ownership::ProjectLocal
        );
    }

    #[test]
    fn ownership_project_local_in_lock_with_nonvstack_source() {
        // Rule 3: present in the lock, but the source dir is not vstack-shaped.
        let non_vstack = tmpdir("nonvstack-source");
        std::fs::create_dir_all(&non_vstack).unwrap();
        let lock = lock_with("visual-qa", ItemKind::Skill, non_vstack.to_str().unwrap());
        let sel = selector("visual-qa", Some(ItemKind::Skill));
        assert_eq!(
            resolve_ownership(&lock, Some(&sel), None, DEFAULT_UPSTREAM),
            Ownership::ProjectLocal
        );
        let _ = std::fs::remove_dir_all(&non_vstack);
    }

    #[test]
    fn ownership_no_selector_defaults_to_project_local() {
        // Rule 4: no asset selector at all.
        let lock = LockFile::default();
        assert_eq!(
            resolve_ownership(&lock, None, None, DEFAULT_UPSTREAM),
            Ownership::ProjectLocal
        );
    }

    #[test]
    fn ownership_vstack_hook_via_legacy_lock_remote_slug_source() {
        // Legacy agent/hook lock entries may use the `owner/repo` shorthand
        // when no durable source_repo field was recorded.
        let lock = lock_with("guard", ItemKind::Hook, "vanillagreencom/vstack");
        let sel = selector("guard", Some(ItemKind::Hook));
        assert_eq!(
            resolve_ownership(&lock, Some(&sel), None, DEFAULT_UPSTREAM),
            Ownership::Vstack
        );
    }

    #[test]
    fn ownership_vstack_pi_extension_via_legacy_lock_remote_slug_source() {
        let lock = lock_with(
            "@vanillagreen/pi-hooks",
            ItemKind::PiExtension,
            "vanillagreencom/vstack",
        );
        let sel = selector("@vanillagreen/pi-hooks", None);
        assert_eq!(
            resolve_ownership(&lock, Some(&sel), None, DEFAULT_UPSTREAM),
            Ownership::Vstack
        );
    }

    #[test]
    fn ownership_project_local_for_unattributed_recovered_skill_source_hint() {
        let lock = lock_with("third-party", ItemKind::Skill, "vanillagreencom/vstack");
        let sel = selector("third-party", Some(ItemKind::Skill));
        assert_eq!(
            resolve_ownership(&lock, Some(&sel), None, DEFAULT_UPSTREAM),
            Ownership::ProjectLocal
        );
    }

    #[test]
    fn ownership_project_local_when_lock_slug_is_not_upstream() {
        // A remote slug that is NOT the upstream must not be claimed as vstack.
        let lock = lock_with("dev", ItemKind::Skill, "someorg/other-repo");
        let sel = selector("dev", Some(ItemKind::Skill));
        assert_eq!(
            resolve_ownership(&lock, Some(&sel), None, DEFAULT_UPSTREAM),
            Ownership::ProjectLocal
        );
    }

    #[test]
    fn frontmatter_repository_requires_exact_slug() {
        // Exact identity, not substring: the lookalike must NOT match.
        let exact = AssetFrontmatter {
            source: None,
            repository: Some("https://github.com/vanillagreencom/vstack".to_string()),
        };
        assert!(frontmatter_declares_vstack(&exact));

        let lookalike = AssetFrontmatter {
            source: None,
            repository: Some("https://github.com/vanillagreencom/vstack-plugins".to_string()),
        };
        assert!(!frontmatter_declares_vstack(&lookalike));

        let bare = AssetFrontmatter {
            source: None,
            repository: Some("vanillagreencom/vstack".to_string()),
        };
        assert!(frontmatter_declares_vstack(&bare));
    }

    // --- marker rendering -----------------------------------------------------

    #[test]
    fn marker_line_renders_expected_string() {
        assert_eq!(
            marker_line("visual-qa", "skill"),
            "\n\n<!-- vstack-report:v1 asset=visual-qa kind=skill ownership=vstack -->"
        );
    }

    #[test]
    fn marker_line_uses_unknown_kind_when_absent() {
        assert_eq!(
            marker_line("mystery", "unknown"),
            "\n\n<!-- vstack-report:v1 asset=mystery kind=unknown ownership=vstack -->"
        );
    }

    #[test]
    fn marker_matches_workflow_recognizer_regex() {
        // Cross-file contract: the CI guard
        // (.github/workflows/issue-ownership-guard.yml) trusts an issue whose
        // body matches this exact ERE. If the marker is ever reformatted so it
        // stops matching, the trust gate silently breaks — this test is the
        // tripwire. Keep the pattern byte-identical to the workflow's grep.
        let pattern = "vstack-report:v1[^>]*ownership=vstack";
        let marker = marker_line("visual-qa", "skill");
        let re = regex_lite::Regex::new(pattern).unwrap();
        assert!(re.is_match(&marker), "marker must match the guard regex");
        // The `[^>]*` class only works if no '>' appears before ownership=vstack.
        let idx = marker.find("ownership=vstack").unwrap();
        assert!(
            !marker[..idx].contains('>'),
            "no '>' may precede ownership=vstack in the marker"
        );
    }

    // --- build_plan / routing (dry-run decision, no gh) -----------------------

    #[test]
    fn build_plan_vstack_targets_upstream_with_marker() {
        let plan = build_plan(
            Ownership::Vstack,
            Some("github"),
            "skill",
            "Title",
            "Body text",
            DEFAULT_UPSTREAM,
        );
        assert_eq!(plan.target, Target::Upstream(DEFAULT_UPSTREAM.to_string()));
        assert!(plan.gh_args.iter().any(|a| a == "--repo"));
        assert!(plan.gh_args.iter().any(|a| a == DEFAULT_UPSTREAM));
        assert!(plan.body_with_marker.starts_with("Body text"));
        assert!(
            plan.body_with_marker
                .contains("<!-- vstack-report:v1 asset=github kind=skill ownership=vstack -->")
        );
        // The body passed to gh is the one carrying the marker.
        let body_idx = plan.gh_args.iter().position(|a| a == "--body").unwrap();
        assert_eq!(&plan.gh_args[body_idx + 1], &plan.body_with_marker);
    }

    #[test]
    fn build_plan_project_local_targets_local_without_marker_or_repo() {
        let plan = build_plan(
            Ownership::ProjectLocal,
            Some("visual-qa"),
            "skill",
            "Title",
            "Body text",
            DEFAULT_UPSTREAM,
        );
        assert_eq!(plan.target, Target::Local);
        assert!(!plan.gh_args.iter().any(|a| a == "--repo"));
        assert!(!plan.body_with_marker.contains("vstack-report:v1"));
        assert_eq!(plan.body_with_marker, "Body text");
    }

    #[test]
    fn build_plan_honors_upstream_override() {
        let plan = build_plan(
            Ownership::Vstack,
            Some("github"),
            "skill",
            "T",
            "B",
            "myorg/fork",
        );
        assert_eq!(plan.target, Target::Upstream("myorg/fork".to_string()));
        let repo_idx = plan.gh_args.iter().position(|a| a == "--repo").unwrap();
        assert_eq!(plan.gh_args[repo_idx + 1], "myorg/fork");
    }

    #[test]
    fn plan_for_inputs_routes_vstack_frontmatter_to_upstream() {
        // End-to-end decision seam used by the dry-run path: a vstack asset is
        // routed upstream, with no gh invocation.
        let lock = LockFile::default();
        let fm = AssetFrontmatter {
            source: Some("vstack".to_string()),
            repository: None,
        };
        let sel = selector("github", Some(ItemKind::Skill));
        let plan = plan_for_inputs(&lock, Some(&sel), Some(&fm), "T", "B", DEFAULT_UPSTREAM);
        assert_eq!(plan.ownership, Ownership::Vstack);
        assert_eq!(plan.target, Target::Upstream(DEFAULT_UPSTREAM.to_string()));
    }

    #[test]
    fn plan_for_inputs_routes_unknown_asset_to_local() {
        let lock = LockFile::default();
        let sel = selector("visual-qa", Some(ItemKind::Skill));
        let plan = plan_for_inputs(&lock, Some(&sel), None, "T", "B", DEFAULT_UPSTREAM);
        assert_eq!(plan.ownership, Ownership::ProjectLocal);
        assert_eq!(plan.target, Target::Local);
    }

    #[test]
    fn plan_for_inputs_marker_kind_falls_back_to_lock_entry() {
        // `--asset` (kind None) resolves its marker kind from the lock entry.
        let lock = lock_with_repo(
            "dev",
            ItemKind::Skill,
            "/missing/source",
            Some("vanillagreencom/vstack"),
        );
        let sel = selector("dev", None);
        let plan = plan_for_inputs(&lock, Some(&sel), None, "T", "B", DEFAULT_UPSTREAM);
        assert_eq!(plan.ownership, Ownership::Vstack);
        assert!(plan.body_with_marker.contains("kind=skill"));
    }

    // --- selector validation --------------------------------------------------

    #[test]
    fn selector_single_ok() {
        let sel = resolve_selector(Some("visual-qa"), None, None, None).unwrap();
        assert_eq!(sel, Some(selector("visual-qa", Some(ItemKind::Skill))));
    }

    #[test]
    fn selector_asset_has_no_kind() {
        let sel = resolve_selector(None, None, None, Some("anything")).unwrap();
        assert_eq!(sel, Some(selector("anything", None)));
    }

    #[test]
    fn selector_none_is_ok() {
        assert_eq!(resolve_selector(None, None, None, None).unwrap(), None);
    }

    #[test]
    fn selector_multiple_is_error() {
        assert!(resolve_selector(Some("a"), Some("b"), None, None).is_err());
        assert!(resolve_selector(Some("a"), None, None, Some("c")).is_err());
    }

    // --- body validation ------------------------------------------------------

    #[test]
    fn body_neither_is_error() {
        assert!(resolve_body(None, None).is_err());
    }

    #[test]
    fn body_both_is_error() {
        assert!(resolve_body(Some("b"), Some(Path::new("/tmp/x.md"))).is_err());
    }

    #[test]
    fn body_inline_ok() {
        assert_eq!(resolve_body(Some("hello"), None).unwrap(), "hello");
    }

    #[test]
    fn body_from_file_ok() {
        let path = tmpdir("body-file");
        std::fs::create_dir_all(path.parent().unwrap()).ok();
        let file = path.with_extension("md");
        std::fs::write(&file, "from file body").unwrap();
        assert_eq!(resolve_body(None, Some(&file)).unwrap(), "from file body");
        let _ = std::fs::remove_file(&file);
    }

    #[test]
    fn body_from_missing_file_is_error() {
        assert!(resolve_body(None, Some(Path::new("/nonexistent/vstack-report-x.md"))).is_err());
    }

    // --- scope validation -----------------------------------------------------

    #[test]
    fn scope_defaults_and_values() {
        assert!(!resolve_scope(None, false).unwrap()); // default project
        assert!(!resolve_scope(Some("project"), false).unwrap());
        assert!(resolve_scope(Some("global"), false).unwrap());
        assert!(resolve_scope(None, true).unwrap()); // --global shortcut
        // --scope wins over --global (sibling convention).
        assert!(!resolve_scope(Some("project"), true).unwrap());
        // report reads one lock, so 'all' is rejected.
        assert!(resolve_scope(Some("all"), false).is_err());
    }

    // --- frontmatter parsing --------------------------------------------------

    #[test]
    fn parse_frontmatter_reads_nested_metadata() {
        let fm = "name: github\nmetadata:\n  source: vstack\n  repository: \"https://github.com/vanillagreencom/vstack\"";
        let parsed = parse_asset_frontmatter(fm).unwrap();
        assert_eq!(parsed.source.as_deref(), Some("vstack"));
        assert!(frontmatter_declares_vstack(&parsed));
    }

    #[test]
    fn parse_frontmatter_project_local_is_not_vstack() {
        let fm = "name: visual-qa\ndescription: local skill";
        let parsed = parse_asset_frontmatter(fm).unwrap();
        assert!(!frontmatter_declares_vstack(&parsed));
    }

    // --- dry-run does not invoke the filer -----------------------------------

    struct PanicFiler;
    impl IssueFiler for PanicFiler {
        fn file(&self, _gh_args: &[String]) -> std::result::Result<String, String> {
            panic!("gh must not be invoked during --dry-run");
        }
    }

    #[test]
    fn dry_run_does_not_invoke_filer() {
        let root = tmpdir("dry-run-root");
        std::fs::create_dir_all(&root).unwrap();
        crate::test_util::with_project_root(&root, || {
            let args = skill_args("visual-qa", "Something broke", "details", true);
            // PanicFiler panics if called; a clean Ok proves dry-run short-circuits.
            let result = run_with_filer(args, &PanicFiler);
            assert!(result.is_ok());
        });
        let _ = std::fs::remove_dir_all(&root);
    }

    // --- capturing filer at the run_with_filer seam (never route local upstream) -

    #[derive(Default)]
    struct CapturingFiler {
        calls: std::cell::RefCell<Vec<Vec<String>>>,
    }
    impl IssueFiler for CapturingFiler {
        fn file(&self, gh_args: &[String]) -> std::result::Result<String, String> {
            self.calls.borrow_mut().push(gh_args.to_vec());
            Ok("https://github.com/example/repo/issues/1".to_string())
        }
    }

    #[test]
    fn run_project_local_files_locally_without_repo_or_marker() {
        let root = tmpdir("cap-local");
        std::fs::create_dir_all(&root).unwrap();
        crate::test_util::with_project_root(&root, || {
            let filer = CapturingFiler::default();
            // Unknown skill, empty lock, no frontmatter → project-local.
            let args = skill_args("visual-qa", "broke", "body", false);
            let result = run_with_filer(args, &filer);
            assert!(result.is_ok(), "success branch should return Ok");
            let calls = filer.calls.borrow();
            assert_eq!(calls.len(), 1, "exactly one gh invocation");
            let a = &calls[0];
            assert!(
                !a.iter().any(|x| x == "--repo"),
                "project-local must NOT pass --repo"
            );
            assert!(
                !a.iter().any(|x| x.contains("vstack-report:v1")),
                "project-local must NOT carry the vstack marker"
            );
        });
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn run_vstack_asset_files_upstream_with_marker() {
        let root = tmpdir("cap-vstack");
        std::fs::create_dir_all(&root).unwrap();
        write_vstack_skill(&root, "prov-skill");
        crate::test_util::with_project_root(&root, || {
            let filer = CapturingFiler::default();
            let args = skill_args("prov-skill", "broke", "body", false);
            let result = run_with_filer(args, &filer);
            assert!(result.is_ok());
            let calls = filer.calls.borrow();
            assert_eq!(calls.len(), 1);
            let a = &calls[0];
            let repo_idx = a
                .iter()
                .position(|x| x == "--repo")
                .expect("vstack asset must pass --repo");
            assert_eq!(a[repo_idx + 1], DEFAULT_UPSTREAM);
            assert!(
                a.iter().any(|x| x.contains(
                    "<!-- vstack-report:v1 asset=prov-skill kind=skill ownership=vstack -->"
                )),
                "vstack issue body must carry the marker"
            );
        });
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn run_lock_source_repo_vstack_files_upstream_with_marker_without_frontmatter() {
        let root = tmpdir("cap-lock-source-repo-vstack");
        std::fs::create_dir_all(&root).unwrap();
        let missing_source = root.join("missing-source");
        let lock = lock_with_repo(
            "locked-skill",
            ItemKind::Skill,
            missing_source.to_str().unwrap(),
            Some("vanillagreencom/vstack"),
        );
        lock.save(&root.join(".vstack-lock.json")).unwrap();

        crate::test_util::with_project_root(&root, || {
            let filer = CapturingFiler::default();
            let args = skill_args("locked-skill", "broke", "body", false);
            let result = run_with_filer(args, &filer);
            assert!(result.is_ok());
            let calls = filer.calls.borrow();
            assert_eq!(calls.len(), 1);
            let a = &calls[0];
            let repo_idx = a
                .iter()
                .position(|x| x == "--repo")
                .expect("source_repo=vstack must pass --repo");
            assert_eq!(a[repo_idx + 1], DEFAULT_UPSTREAM);
            assert!(
                a.iter().any(|x| x.contains(
                    "<!-- vstack-report:v1 asset=locked-skill kind=skill ownership=vstack -->"
                )),
                "vstack issue body must carry the marker"
            );
        });
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn run_lock_source_repo_foreign_files_locally_without_marker() {
        let root = tmpdir("cap-lock-source-repo-foreign");
        std::fs::create_dir_all(&root).unwrap();
        let missing_source = root.join("missing-source");
        let lock = lock_with_repo(
            "locked-skill",
            ItemKind::Skill,
            missing_source.to_str().unwrap(),
            Some("example/project-assets"),
        );
        lock.save(&root.join(".vstack-lock.json")).unwrap();

        crate::test_util::with_project_root(&root, || {
            let filer = CapturingFiler::default();
            let args = skill_args("locked-skill", "broke", "body", false);
            let result = run_with_filer(args, &filer);
            assert!(result.is_ok());
            let calls = filer.calls.borrow();
            assert_eq!(calls.len(), 1);
            let a = &calls[0];
            assert!(
                !a.iter().any(|x| x == "--repo"),
                "foreign source_repo must not pass --repo"
            );
            assert!(
                !a.iter().any(|x| x.contains("vstack-report:v1")),
                "foreign source_repo must not carry the marker"
            );
        });
        let _ = std::fs::remove_dir_all(&root);
    }

    // --- disk frontmatter / installed-file resolution -------------------------

    #[test]
    fn load_asset_frontmatter_reads_vstack_skill_from_disk() {
        let root = tmpdir("disk-skill");
        write_vstack_skill(&root, "diskskill");
        crate::test_util::with_project_root(&root, || {
            let lock = LockFile::default();
            let sel = selector("diskskill", Some(ItemKind::Skill));
            let fm = load_asset_frontmatter(&sel, &lock, false).expect("frontmatter found");
            assert_eq!(fm.source.as_deref(), Some("vstack"));

            // A skill with no installed file falls through to None (safe).
            let missing = selector("nowhere", Some(ItemKind::Skill));
            assert!(load_asset_frontmatter(&missing, &lock, false).is_none());
        });
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn find_installed_agent_file_prefers_md_then_toml() {
        let root = tmpdir("agent-files");
        // Claude project agents dir holds both a .md agent and a .toml-only agent.
        let agents = root.join(".claude").join("agents");
        std::fs::create_dir_all(&agents).unwrap();
        std::fs::write(agents.join("mdagent.md"), "---\nname: mdagent\n---\n").unwrap();
        std::fs::write(agents.join("tomlagent.toml"), "name = \"tomlagent\"\n").unwrap();
        crate::test_util::with_project_root(&root, || {
            let md = find_installed_agent_file(false, "mdagent").expect("md agent found");
            assert!(md.extension().is_some_and(|e| e == "md"));
            // No .md present → falls back to the .toml file.
            let toml = find_installed_agent_file(false, "tomlagent").expect("toml agent found");
            assert!(toml.extension().is_some_and(|e| e == "toml"));
            // Neither → None.
            assert!(find_installed_agent_file(false, "ghost").is_none());
        });
        let _ = std::fs::remove_dir_all(&root);
    }

    // --- gh failure saves the body and exits non-zero ------------------------

    struct FailFiler;
    impl IssueFiler for FailFiler {
        fn file(&self, _gh_args: &[String]) -> std::result::Result<String, String> {
            Err("simulated gh failure".to_string())
        }
    }

    #[test]
    fn gh_failure_saves_body_and_errors() {
        let root = tmpdir("fail-root");
        std::fs::create_dir_all(&root).unwrap();
        // Distinctive title so the slug is unlikely to collide with other tests.
        let title = "report gh failure path smoke uniq";
        let slug = slugify(title);
        for path in saved_reports_for(&slug) {
            let _ = std::fs::remove_file(path);
        }

        let result = crate::test_util::with_project_root(&root, || {
            let args = skill_args("visual-qa", title, "body text goes here", false);
            run_with_filer(args, &FailFiler)
        });

        assert!(
            result.is_err(),
            "a gh failure must surface as a non-zero error"
        );
        // The failure path saves the body under a unique temp filename; find it
        // by its slug+pid prefix rather than a hardcoded fixed name.
        let saved = saved_reports_for(&slug);
        assert!(
            !saved.is_empty(),
            "the report body must be saved to the temp dir on gh failure"
        );
        let content = std::fs::read_to_string(&saved[0]).unwrap();
        assert!(content.contains("# report gh failure path smoke uniq"));
        assert!(content.contains("body text goes here"));

        for path in saved {
            let _ = std::fs::remove_file(path);
        }
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn save_report_body_returns_existing_unique_path() {
        let p1 = save_report_body("Alpha Bug", "body one").unwrap();
        let p2 = save_report_body("Alpha Bug", "body two").unwrap();
        assert!(p1.exists(), "returned path must exist");
        assert!(p2.exists());
        assert_ne!(p1, p2, "each save must get a unique temp path");
        assert!(
            p1.starts_with(std::env::temp_dir()),
            "must live in the OS temp dir, not the repo tree"
        );
        let content = std::fs::read_to_string(&p1).unwrap();
        assert!(content.contains("# Alpha Bug"));
        assert!(content.contains("body one"));
        let _ = std::fs::remove_file(&p1);
        let _ = std::fs::remove_file(&p2);
    }

    // --- helpers --------------------------------------------------------------

    #[test]
    fn slugify_produces_temp_safe_names() {
        assert_eq!(slugify("Hello, World!"), "hello-world");
        assert_eq!(slugify("   "), "report");
        assert_eq!(slugify("visual-qa crashes"), "visual-qa-crashes");
    }

    #[test]
    fn parse_github_slug_handles_urls_bare_and_rejects_paths() {
        assert_eq!(
            config::parse_github_slug("git@github.com:hyprtrade/app.git").as_deref(),
            Some("hyprtrade/app")
        );
        assert_eq!(
            config::parse_github_slug("https://github.com/vanillagreencom/vstack").as_deref(),
            Some("vanillagreencom/vstack")
        );
        // Bare owner/repo shorthand (remote-install lock source, repository fm).
        assert_eq!(
            config::parse_github_slug("vanillagreencom/vstack").as_deref(),
            Some("vanillagreencom/vstack")
        );
        assert_eq!(
            config::parse_github_slug("vanillagreencom/vstack.git").as_deref(),
            Some("vanillagreencom/vstack")
        );
        // Non-GitHub URL, local paths, and non-slug tokens must NOT parse.
        assert_eq!(config::parse_github_slug("https://gitlab.com/x/y"), None);
        assert_eq!(config::parse_github_slug("/home/me/dev/vstack"), None);
        assert_eq!(config::parse_github_slug("a/b/c"), None);
        assert_eq!(config::parse_github_slug("just-a-name"), None);
    }

    #[test]
    fn render_gh_command_quotes_spaces() {
        let args = vec![
            "issue".to_string(),
            "create".to_string(),
            "--title".to_string(),
            "has spaces".to_string(),
        ];
        assert_eq!(
            render_gh_command(&args),
            "gh issue create --title 'has spaces'"
        );
    }
}
