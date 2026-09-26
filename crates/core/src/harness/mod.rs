use std::path::{Path, PathBuf};

use crate::env::Env;
use crate::model::{DetectedHarness, HarnessId, ItemKind};

pub mod antigravity;
pub mod claude;
pub mod codex;
pub mod copilot;
pub mod cursor;
pub mod gemini;
pub mod opencode;
pub mod pi;

mod caps;
pub mod models;
pub use caps::{
    CANONICAL_SEPARATOR, Enforcement, FormatCaps, KindCaps, McpTransport, NameRule, OpSupport,
    canonical_name, capabilities, format_caps, installable, installs_here, namespace_separator,
    pi_listener, rendered_name,
};

/// What a hook label may claim for this harness at this scope. The static
/// row says what the mechanism supports; Pi's enforcement is real only
/// while the pi-hooks carrier is registered somewhere Pi loads, so every
/// surface that labels an installation reads this instead of the row.
pub fn hook_enforcement(
    env: &crate::env::Env,
    scope: &crate::model::Scope,
    harness: HarnessId,
) -> Enforcement {
    match harness {
        HarnessId::Pi => crate::pi_ext::carrier::enforcement(env, scope),
        _ => capabilities(harness, crate::model::ItemKind::Hook).enforcement,
    }
}

/// What marks a directory as a project for this harness during discovery.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProjectMarker {
    Dir(&'static str),
    File(&'static str),
}

/// What a harness does with a project path it reads. The path's spelling
/// cannot say: `.cursor/rules` holds Cursor's rendered agents while
/// `.agents/rules` is context Antigravity loads every session, and
/// `.claude/settings.json` is Claude Code's own registry and a policy
/// input Copilot reads, so the role is read from the harness reading it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    /// Marks a project for the harness.
    Root,
    /// Holds the items kendex renders; the harness reads one when it is
    /// named.
    Catalog,
    /// A file the harness executes keys out of: its hooks, its
    /// permissions, its MCP servers, the packages it loads.
    Registry,
    /// Loaded as context, or read as policy deciding what the harness
    /// runs, with no item named.
    Instruction,
}

/// How much of the tree under a path it covers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Entry {
    File,
    /// The directory and everything under it.
    Dir,
    /// Every file under the directory carrying this extension.
    Files(&'static str),
}

/// A project path an adapter declares because no marker or surface of its
/// own says it is read, or says it in the role the harness reads it in.
/// Relative to the project root and `/`-separated.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProjectPath {
    pub path: &'static str,
    pub entry: Entry,
    pub role: Role,
}

impl ProjectPath {
    pub const fn file(path: &'static str, role: Role) -> ProjectPath {
        ProjectPath {
            path,
            entry: Entry::File,
            role,
        }
    }

    pub const fn dir(path: &'static str, role: Role) -> ProjectPath {
        ProjectPath {
            path,
            entry: Entry::Dir,
            role,
        }
    }

    pub const fn files(dir: &'static str, ext: &'static str, role: Role) -> ProjectPath {
        ProjectPath {
            path: dir,
            entry: Entry::Files(ext),
            role,
        }
    }

    /// Where this path sits in one project.
    pub fn at(&self, project: &Path) -> PathBuf {
        project.join(self.path)
    }
}

/// One project path one harness reads, with the role it reads it in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HarnessPath {
    pub harness: HarnessId,
    /// Relative to the project root, `/`-separated.
    pub path: String,
    pub entry: Entry,
    pub role: Role,
}

impl HarnessPath {
    /// Every repository-relative path this entry covers, as a shell pattern
    /// whose `*` also crosses `/`.
    pub fn glob(&self) -> String {
        match self.entry {
            Entry::File => self.path.clone(),
            Entry::Dir => format!("{}/*", self.path),
            Entry::Files(ext) => format!("{}/*.{ext}", self.path),
        }
    }
}

/// The project root the enumeration reads each adapter's surfaces at: a
/// directory no machine holds, and no home directory sits under. A surface
/// inside the project is read back relative to it; one a project scope
/// also reads from the home directory, such as Claude Code's `.claude.json`,
/// falls outside it and is left out, so the rows are the same whatever the
/// caller's home. A surface that looks at the disk to pick one of two files
/// finds neither here; the adapter's `project_reads` names both.
const ENUMERATION_ROOT: &str = "/kendex-enumeration-root";

/// Every project path one harness reads: each project marker as a root,
/// each project surface inside the project in the role its shape gives it
/// (a directory of items is a catalog, a structured file or directory a
/// registry), and each path its `project_reads` declares. Each path is
/// one row: a later source names its entry and role over an earlier one,
/// so a surface outranks a marker and a declaration outranks both, even
/// where the two cover the path differently (Copilot's `.github/hooks` is
/// a marker directory and a surface of `.json` registries).
pub fn harness_paths(adapter: &dyn HarnessAdapter, env: &Env) -> Vec<HarnessPath> {
    let project = Path::new(ENUMERATION_ROOT);
    let mut found: Vec<HarnessPath> = Vec::new();
    let mut add = |path: String, entry: Entry, role: Role| match found
        .iter_mut()
        .find(|held| held.path == path)
    {
        Some(held) => {
            held.entry = entry;
            held.role = role;
        }
        None => found.push(HarnessPath {
            harness: adapter.id(),
            path,
            entry,
            role,
        }),
    };
    for marker in adapter.project_markers() {
        match marker {
            ProjectMarker::Dir(path) => add(path.to_string(), Entry::Dir, Role::Root),
            ProjectMarker::File(path) => add(path.to_string(), Entry::File, Role::Root),
        }
    }
    for kind in ItemKind::ALL {
        for surface in adapter.project_surfaces(kind, project, env) {
            let (path, entry, role) = match &surface {
                Surface::FileDir { dir, .. } | Surface::SubdirPerItem { dir, .. } => {
                    (dir, Entry::Dir, Role::Catalog)
                }
                Surface::Structured { path, .. } => (path, Entry::File, Role::Registry),
                Surface::StructuredDir { dir, ext, .. } => (dir, Entry::Files(ext), Role::Registry),
            };
            if let Some(path) = relative(project, path) {
                add(path, entry, role);
            }
        }
    }
    for read in adapter.project_reads() {
        add(read.path.to_owned(), read.entry, read.role);
    }
    found
}

/// `path` relative to `project`, `/`-separated; `None` for a path outside
/// it.
fn relative(project: &Path, path: &Path) -> Option<String> {
    let rest = path.strip_prefix(project).ok()?;
    Some(
        rest.components()
            .map(|part| part.as_os_str().to_string_lossy().into_owned())
            .collect::<Vec<_>>()
            .join("/"),
    )
}

/// [`harness_paths`] for every harness, in `all_adapters` order. A path two
/// harnesses read appears once per harness, each in its own role.
pub fn project_paths(env: &Env) -> Vec<HarnessPath> {
    all_adapters()
        .into_iter()
        .flat_map(|adapter| harness_paths(adapter, env))
        .collect()
}

/// The version of [`PathsDocument`]. A reader pins it and refuses any
/// other, so a change to the rows' meaning moves it.
pub const PATHS_DOCUMENT_VERSION: u32 = 1;

/// The enumeration `kendex harness-paths` prints: every project path
/// kendex's harness adapters read, from their markers, their surfaces and
/// their declared reads alone, so it answers the same in a checkout that
/// has installed nothing and whatever the caller's home directory. Files a
/// harness reads that no adapter names, such as `AGENTS.md`, are not in it.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct PathsDocument {
    pub version: u32,
    pub paths: Vec<PathRow>,
}

/// One path, as the document prints it.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct PathRow {
    pub harness: HarnessId,
    pub role: Role,
    pub path: String,
    /// Every repository-relative path the entry covers, in the shell
    /// pattern grammar where `*` also crosses `/`.
    pub glob: String,
}

impl PathsDocument {
    pub fn new(env: &Env) -> PathsDocument {
        PathsDocument {
            version: PATHS_DOCUMENT_VERSION,
            paths: project_paths(env)
                .into_iter()
                .map(|path| PathRow {
                    glob: path.glob(),
                    harness: path.harness,
                    role: path.role,
                    path: path.path,
                })
                .collect(),
        }
    }
}

/// A place the scanner reads one kind from, plus how items are stored there.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Surface {
    /// `<dir>/<name>.<ext>` — one item per file, one folder level of
    /// namespacing included (`ns/name.md` → item `ns/name`). A `.disabled`
    /// suffix on the full filename marks a disabled item. A non-empty
    /// `prefixes` restricts to filenames starting with one of them —
    /// opencode hook instructions, where files written before the product
    /// rename carry the old spelling and must stay owned.
    FileDir {
        dir: PathBuf,
        exts: &'static [&'static str],
        prefixes: &'static [&'static str],
    },
    /// `<dir>/<name>/<marker>` — one item per subdirectory holding the
    /// marker file (`<marker>.disabled` marks a disabled item).
    SubdirPerItem { dir: PathBuf, marker: &'static str },
    /// Items are entries inside a structured file or tree; the reader names
    /// the harness-specific format the scanner must parse.
    Structured { path: PathBuf, reader: Reader },
    /// `<dir>/*.<ext>` — every file in the directory is a document of its
    /// own holding entries, all read by the same reader. Copilot's hook
    /// files work this way: what the file is called says nothing, and the
    /// entries inside it are the items.
    StructuredDir {
        dir: PathBuf,
        ext: &'static str,
        reader: Reader,
    },
}

impl Surface {
    pub fn files(dir: PathBuf, exts: &'static [&'static str]) -> Surface {
        Surface::FileDir {
            dir,
            exts,
            prefixes: &[],
        }
    }

    /// One skill per subdirectory, the shape every harness stores skills in.
    pub fn skills(dir: PathBuf) -> Surface {
        Surface::SubdirPerItem {
            dir,
            marker: "SKILL.md",
        }
    }
}

/// The skill surfaces for a harness that reads the project's shared
/// `.agents/skills` tree as well as one of its own. The shared tree leads,
/// because that is where an install goes: it is one definition every such
/// tool sees, and `native_dir` reads the first entry. The tool's own
/// directory stays on the list so a skill an older install (or a person)
/// left there is still seen, and so a copy delivery has somewhere per-tool
/// to write.
pub(crate) fn shared_first(shared: Option<&Path>, own: PathBuf) -> Vec<Surface> {
    match shared {
        Some(shared) => vec![Surface::skills(shared.to_path_buf()), Surface::skills(own)],
        None => vec![Surface::skills(own)],
    }
}

/// Harness-specific structured formats. One variant per real on-disk format;
/// the scanner owns the parsing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Reader {
    /// `{"mcpServers": {...}}` — claude `.mcp.json`, cursor `mcp.json`
    McpServersJson,
    /// `~/.claude.json` top-level `mcpServers`
    ClaudeUserMcp,
    /// `~/.claude.json` `projects.<root>.mcpServers`
    ClaudeUserProjectMcp { project: PathBuf },
    /// gemini settings `mcpServers`, joined with the global file recording
    /// whether each server is switched on and the settings `mcp.excluded`
    /// list
    GeminiMcp,
    /// codex `config.toml` `[mcp_servers.<name>]`
    McpServersToml,
    /// opencode config `mcp` key — jsonc tolerated, per-entry `enabled`
    OpencodeMcp,
    /// opencode config `plugin` array — npm plugin refs
    OpencodePluginRefs,
    /// `{"hooks": {"<Event>": [{matcher?, hooks: [{command}]} | {command}]}}`
    /// — claude settings.json, codex/cursor hooks.json
    HooksObject,
    /// `{version, disableAllHooks, hooks: {<event>: [{type, bash|powershell|
    /// command|url|prompt, matcher, timeoutSec}]}}` — copilot's hook files
    /// and the `hooks` key of its settings. Its entries carry the command
    /// themselves, so reading them as `HooksObject` would name every one of
    /// them after nothing (matrix §2, §7).
    CopilotHooks,
    /// `{"<hook-name>": {enabled?, "<Event>": [group | handler]}}` —
    /// antigravity's `hooks.json`, one named hook per top-level key with
    /// its own switch, tool events grouped under a matcher and the rest
    /// flat. Read as `HooksObject` the file would hold no `hooks` key and
    /// nothing would be found.
    AntigravityHooks,
    /// copilot settings `enabledPlugins` — `{"<plugin>@<marketplace>": bool}`
    CopilotPlugins,
    /// `~/.claude/plugins/installed_plugins.json` joined with settings
    /// `enabledPlugins`
    ClaudePluginRegistry,
    /// project `.claude/settings.json` + `.claude/settings.local.json`
    /// `enabledPlugins` entries
    ClaudeSettingsPlugins,
    /// `~/.codex/plugins/cache/<marketplace>/<plugin>/<version>/` tree with
    /// `.codex-plugin/plugin.json`, toggles in config.toml `[plugins]`
    CodexPluginCache,
    /// `~/.cursor/plugins/{local,cache}` tree with `.cursor-plugin/plugin.json`
    CursorPluginDirs,
    /// pi `settings.json` `packages[]` entries
    PiPackages,
}

pub trait HarnessAdapter: Send + Sync {
    fn id(&self) -> HarnessId;

    /// Where the harness keeps global state when no settings override is set.
    fn default_global_root(&self, env: &Env) -> PathBuf;

    fn detect(&self, env: &Env, global_root: &Path) -> Option<DetectedHarness> {
        let _ = env;
        global_root.is_dir().then(|| DetectedHarness {
            harness: self.id(),
            root: global_root.to_path_buf(),
            version: None,
        })
    }

    fn project_markers(&self) -> &'static [ProjectMarker];

    /// The project paths this harness reads that its markers and surfaces
    /// do not name in the role it reads them in: instruction and policy
    /// files, a marked or surfaced directory it loads with no item named,
    /// and each file a surface picks by looking at the disk. What the
    /// markers and surfaces already say is not repeated here;
    /// [`harness_paths`] reads it from them.
    fn project_reads(&self) -> &'static [ProjectPath];

    /// Every read surface for `kind` at global scope. Empty = unsupported.
    fn global_surfaces(&self, kind: ItemKind, root: &Path, env: &Env) -> Vec<Surface>;

    /// Every read surface for `kind` inside a project. Empty = unsupported.
    fn project_surfaces(&self, kind: ItemKind, project: &Path, env: &Env) -> Vec<Surface>;
}

pub fn all_adapters() -> [&'static dyn HarnessAdapter; 8] {
    [
        &claude::Claude,
        &codex::Codex,
        &opencode::Opencode,
        &cursor::Cursor,
        &pi::Pi,
        &gemini::Gemini,
        &copilot::Copilot,
        &antigravity::Antigravity,
    ]
}

pub fn adapter(id: HarnessId) -> &'static dyn HarnessAdapter {
    match id {
        HarnessId::Claude => &claude::Claude,
        HarnessId::Codex => &codex::Codex,
        HarnessId::Opencode => &opencode::Opencode,
        HarnessId::Cursor => &cursor::Cursor,
        HarnessId::Pi => &pi::Pi,
        HarnessId::Gemini => &gemini::Gemini,
        HarnessId::Copilot => &copilot::Copilot,
        HarnessId::Antigravity => &antigravity::Antigravity,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::env::FakeOs;

    #[test]
    fn adapter_registry_is_complete_and_ordered() {
        let ids: Vec<_> = all_adapters().iter().map(|a| a.id()).collect();
        assert_eq!(ids, HarnessId::ALL);
        for id in HarnessId::ALL {
            assert_eq!(adapter(id).id(), id);
        }
    }

    /// The capability table's observe column must mirror what the adapters
    /// actually declare — UI gating and scan behavior cannot drift apart.
    #[test]
    fn observe_capabilities_match_declared_surfaces() {
        let env = Env::fake("/home/user", FakeOs::Linux);
        let project = Path::new("/home/user/dev/proj");
        for a in all_adapters() {
            let root = a.default_global_root(&env);
            for kind in ItemKind::ALL {
                let caps = capabilities(a.id(), kind);
                assert_eq!(
                    caps.observe.global,
                    !a.global_surfaces(kind, &root, &env).is_empty(),
                    "{}/{} global observe",
                    a.id().name(),
                    kind.name(),
                );
                assert_eq!(
                    caps.observe.project,
                    !a.project_surfaces(kind, project, &env).is_empty(),
                    "{}/{} project observe",
                    a.id().name(),
                    kind.name(),
                );
            }
        }
    }

    /// Each path a settings reader opens that `project_paths` does not
    /// carry for the harness reading it, in the role that harness reads it
    /// in, spelled as the enumeration spells it.
    fn undeclared_reads(
        project: &Path,
        env: &Env,
        reads: &[(HarnessId, PathBuf, Role)],
    ) -> Vec<String> {
        let declared = project_paths(env);
        reads
            .iter()
            .filter_map(|(harness, path, role)| {
                let path = relative(project, path).unwrap_or_else(|| path.display().to_string());
                let held = declared.iter().any(|entry| {
                    entry.harness == *harness
                        && entry.path == path
                        && entry.entry == Entry::File
                        && entry.role == *role
                });
                (!held).then_some(path)
            })
            .collect()
    }

    /// The settings readers open files beside the adapters' surfaces. Each
    /// row holds one reader to the harness that reads the file and the role
    /// it reads it in, at a project root other than the one the enumeration
    /// is read at, so a reader that spells its path differently is named.
    /// The planted rows each break one clause the check holds a read to:
    /// the path, the role, and the harness reading it.
    #[test]
    fn every_settings_reader_opens_a_path_the_enumeration_carries() {
        let env = Env::fake("/home/user", FakeOs::Linux);
        let project = Path::new("/home/user/dev/proj");
        let scope = crate::model::Scope::Project {
            root: project.to_path_buf(),
        };
        let [repo, repo_local] = copilot::settings::repo_settings_files(project);
        let [claude, claude_local] = copilot::settings::claude_settings_files(project);
        let reads = [
            (
                HarnessId::Copilot,
                copilot::settings::allowed_models_file(project),
                Role::Instruction,
            ),
            (HarnessId::Copilot, claude, Role::Instruction),
            (HarnessId::Copilot, claude_local, Role::Instruction),
            (HarnessId::Copilot, repo, Role::Registry),
            (HarnessId::Copilot, repo_local, Role::Registry),
            (
                HarnessId::Copilot,
                copilot::settings::settings_file(&env, &scope),
                Role::Registry,
            ),
            (
                HarnessId::Gemini,
                gemini::settings::settings_file(&env, &scope),
                Role::Registry,
            ),
            (
                HarnessId::Opencode,
                opencode::config_file(&env, &scope),
                Role::Registry,
            ),
            (
                HarnessId::Pi,
                pi::hook_registry(&pi::scope_root(&env, &scope)),
                Role::Registry,
            ),
        ];
        assert_eq!(
            undeclared_reads(project, &env, &reads),
            Vec::<String>::new()
        );

        for (planted, named) in [
            (
                (
                    HarnessId::Copilot,
                    project.join(".github/models.txt"),
                    Role::Instruction,
                ),
                ".github/models.txt",
            ),
            (
                (
                    HarnessId::Copilot,
                    project.join(".claude/settings.json"),
                    Role::Registry,
                ),
                ".claude/settings.json",
            ),
            (
                (
                    HarnessId::Cursor,
                    copilot::settings::allowed_models_file(project),
                    Role::Instruction,
                ),
                ".github/allowed_models.txt",
            ),
        ] {
            assert_eq!(
                undeclared_reads(project, &env, std::slice::from_ref(&planted)),
                [named],
                "{planted:?}"
            );
        }
    }

    /// One spelling, two answers: the role is the harness's, never the
    /// path's. A rule keyed on the `rules` segment, or on the file name,
    /// gives each pair one answer. The rows also hold the precedence: a
    /// marker that is also a surface takes the surface's role, and a
    /// declared read outranks both.
    #[test]
    fn a_path_takes_the_role_its_harness_reads_it_in() {
        let env = Env::fake("/home/user", FakeOs::Linux);
        let declared = project_paths(&env);
        for (harness, path, role) in [
            (HarnessId::Cursor, ".cursor/rules", Role::Catalog),
            (HarnessId::Antigravity, ".agents/rules", Role::Instruction),
            (HarnessId::Claude, ".claude/settings.json", Role::Registry),
            (
                HarnessId::Copilot,
                ".claude/settings.json",
                Role::Instruction,
            ),
            (
                HarnessId::Copilot,
                ".github/allowed_models.txt",
                Role::Instruction,
            ),
            (
                HarnessId::Opencode,
                ".opencode/instructions",
                Role::Instruction,
            ),
            (HarnessId::Opencode, "opencode.jsonc", Role::Registry),
            (HarnessId::Claude, ".claude/skills", Role::Catalog),
            (HarnessId::Claude, ".mcp.json", Role::Registry),
            (HarnessId::Claude, ".claude", Role::Root),
            (HarnessId::Copilot, ".github/hooks", Role::Registry),
        ] {
            let roles: Vec<Role> = declared
                .iter()
                .filter(|entry| entry.harness == harness && entry.path == path)
                .map(|entry| entry.role)
                .collect();
            assert_eq!(roles, [role], "{} {path}", harness.name());
        }
    }

    /// A path is one row per harness, whatever sources name it: two rows for
    /// one path would give it two roles, and a reader could take either.
    #[test]
    fn a_harness_prints_each_path_once() {
        let env = Env::fake("/home/user", FakeOs::Linux);
        let rows = project_paths(&env);
        let mut seen = std::collections::BTreeSet::new();
        let twice: Vec<(HarnessId, &str)> = rows
            .iter()
            .map(|row| (row.harness, row.path.as_str()))
            .filter(|key| !seen.insert(*key))
            .collect();
        assert_eq!(twice, Vec::<(HarnessId, &str)>::new());
        let hooks: Vec<(Entry, Role)> = rows
            .iter()
            .filter(|row| row.harness == HarnessId::Copilot && row.path == ".github/hooks")
            .map(|row| (row.entry, row.role))
            .collect();
        assert_eq!(hooks, [(Entry::Files("json"), Role::Registry)]);
    }

    /// The rows are the adapters' alone: two callers with two homes get one
    /// enumeration, and no row is a file under either home, although a
    /// project scope reads Claude Code's `.claude.json` from there.
    #[test]
    fn the_enumeration_is_the_same_whatever_the_home() {
        let one = project_paths(&Env::fake("/home/one", FakeOs::Linux));
        let two = project_paths(&Env::fake("/srv/two", FakeOs::Linux));
        assert_eq!(one, two);
        let under_a_home: Vec<&String> = one
            .iter()
            .map(|row| &row.path)
            .filter(|path| path.starts_with("home/") || path.contains(".claude.json"))
            .collect();
        assert_eq!(under_a_home, Vec::<&String>::new());
    }

    /// Every kind stored as another, and no others: a renderer exists for
    /// exactly these pairs, so a further entry in the table must arrive
    /// with the renderer that serves it — and a pair the renderer takes
    /// that the table does not name leaves every reader of the table
    /// looking for the artifact under the kind it was declared as.
    #[test]
    fn every_kind_stored_as_another_is_one_the_renderer_takes() {
        let stored: Vec<_> = HarnessId::ALL
            .into_iter()
            .flat_map(|harness| ItemKind::ALL.map(|kind| (harness, kind)))
            .filter_map(|(harness, kind)| {
                capabilities(harness, kind)
                    .installs_as
                    .map(|emitted| (harness, kind, emitted))
            })
            .collect();
        assert_eq!(
            stored,
            [
                // `engine::desired_command::as_skill`.
                (HarnessId::Codex, ItemKind::Command, ItemKind::Skill),
                // `engine::targets::hook_target`'s cursor arm.
                (HarnessId::Cursor, ItemKind::Hook, ItemKind::Agent),
            ]
        );
    }

    /// A hook the tool merely reads must never be presented as one it runs.
    /// Every harness with a hook surface says which it is, and the harnesses
    /// without one are exactly the rows that say nothing.
    #[test]
    fn every_hook_row_says_whether_the_tool_runs_it() {
        for harness in HarnessId::ALL {
            let hook = capabilities(harness, ItemKind::Hook);
            let observed = hook.observe.project || hook.observe.global;
            assert_eq!(
                hook.enforcement == Enforcement::NotApplicable,
                !observed,
                "{} hook enforcement",
                harness.name(),
            );
            for kind in ItemKind::ALL.into_iter().filter(|k| *k != ItemKind::Hook) {
                assert_eq!(
                    capabilities(harness, kind).enforcement,
                    Enforcement::NotApplicable,
                    "{}/{} claims enforcement",
                    harness.name(),
                    kind.name(),
                );
            }
        }
    }

    /// The transport list and the MCP row describe one fact from two sides:
    /// a harness that reads no servers has no way to reach one.
    #[test]
    fn mcp_transports_agree_with_the_mcp_row() {
        for harness in HarnessId::ALL {
            let mcp = capabilities(harness, ItemKind::McpServer);
            assert_eq!(
                format_caps(harness).mcp_transports.is_empty(),
                mcp.observe == caps::NONE,
                "{} mcp transports",
                harness.name(),
            );
        }
    }

    /// Copilot is managed where its own documentation gives kendex a surface
    /// to write, and nowhere else: it has no file-backed command kind at all,
    /// and installing a plugin needs a marketplace kendex cannot resolve yet.
    #[test]
    fn copilot_manages_only_the_surfaces_it_documents() {
        for kind in [
            ItemKind::Agent,
            ItemKind::Skill,
            ItemKind::Hook,
            ItemKind::McpServer,
        ] {
            let c = capabilities(HarnessId::Copilot, kind);
            assert_eq!(c.install, caps::BOTH, "{} install", kind.name());
            assert_eq!(c.remove, caps::BOTH, "{} remove", kind.name());
        }
        assert_eq!(
            capabilities(HarnessId::Copilot, ItemKind::Hook).enforcement,
            Enforcement::Enforced,
        );
        let command = capabilities(HarnessId::Copilot, ItemKind::Command);
        assert_eq!((command.observe, command.install), (caps::NONE, caps::NONE));
        let plugin = capabilities(HarnessId::Copilot, ItemKind::Plugin);
        assert_eq!((plugin.toggle, plugin.install), (caps::BOTH, caps::NONE));
    }

    /// Gemini declares an MCP server per scope but records whether it is on
    /// in one global file, so the switch exists only where that file lives.
    /// Everything else it manages works the same at both scopes.
    #[test]
    fn a_gemini_server_installs_per_scope_and_switches_off_globally() {
        let mcp = capabilities(HarnessId::Gemini, ItemKind::McpServer);
        assert_eq!(mcp.install, caps::BOTH);
        assert_eq!(mcp.remove, caps::BOTH);
        assert_eq!(mcp.toggle, caps::GLOBAL);
        for kind in [
            ItemKind::Agent,
            ItemKind::Skill,
            ItemKind::Command,
            ItemKind::Hook,
        ] {
            let c = capabilities(HarnessId::Gemini, kind);
            assert_eq!(c.install, caps::BOTH, "{} install", kind.name());
            assert_eq!(c.toggle, caps::BOTH, "{} toggle", kind.name());
        }
        // Extensions install globally only and their enablement is an
        // undocumented path-rule file, so they stay read-only (matrix §R1).
        assert_eq!(
            capabilities(HarnessId::Gemini, ItemKind::Plugin).install,
            caps::NONE
        );
    }

    /// Nothing may be mutable where what it writes cannot be observed. A
    /// kind the harness stores as another one is checked against that
    /// kind's surfaces, because that is where its artifact lands.
    #[test]
    fn no_capability_exceeds_observation() {
        for harness in HarnessId::ALL {
            for kind in ItemKind::ALL {
                let c = capabilities(harness, kind);
                let written = match c.installs_as {
                    Some(emitted) => capabilities(harness, emitted).observe,
                    None => c.observe,
                };
                for (op, sup, observe) in [
                    ("adopt", c.adopt, c.observe),
                    ("install", c.install, written),
                    ("toggle", c.toggle, written),
                    ("remove", c.remove, written),
                    ("refresh", c.refresh, written),
                ] {
                    assert!(
                        (!sup.project || observe.project) && (!sup.global || observe.global),
                        "{}/{}: {op} exceeds observe",
                        harness.name(),
                        kind.name(),
                    );
                }
            }
        }
    }
}
