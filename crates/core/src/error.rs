use std::path::PathBuf;

use thiserror::Error;

use crate::model::{HarnessId, ItemKind};

#[derive(Debug, Error)]
pub enum CoreError {
    #[error("cannot locate the home directory on this system")]
    NoHomeDir,

    #[error("{path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },

    #[error("{path}: invalid TOML: {message}")]
    TomlParse { path: PathBuf, message: String },

    #[error("{path}: invalid JSON: {message}")]
    JsonParse { path: PathBuf, message: String },

    #[error("{path} is not a directory")]
    NotADirectory { path: PathBuf },

    #[error("project already registered: {path}")]
    ProjectAlreadyRegistered { path: PathBuf },

    #[error("project not registered: {path}")]
    ProjectNotRegistered { path: PathBuf },

    #[error("{path}: invalid manifest:\n{}", findings.join("\n"))]
    ManifestInvalid {
        path: PathBuf,
        findings: Vec<String>,
    },

    #[error(
        "{path}: this manifest could not be read — {message}; move it aside and install fresh, declaring again from the file you moved"
    )]
    LegacyManifest { path: PathBuf, message: String },

    #[error(
        "{path}: this lock file could not be read — {message}; move it aside and install fresh. Keep it: it is the only record naming a pi hooks.json or hooks/ beside a scope root, so move those aside as well"
    )]
    LockCorrupt { path: PathBuf, message: String },

    #[error(
        "{path} records {key} at {recorded}, outside the project at {root} — this lock belongs to another checkout; delete it and apply again"
    )]
    LockOutsideProject {
        path: PathBuf,
        key: String,
        recorded: PathBuf,
        root: PathBuf,
    },

    #[error(
        "{path} was written by the project at {recorded}, not the one at {root} — this lock belongs to another checkout; delete it and apply again"
    )]
    LockFromAnotherProject {
        path: PathBuf,
        recorded: PathBuf,
        root: PathBuf,
    },

    #[error(
        "{path} does not say which project wrote it — refusing to read it as this project's; delete it and apply again"
    )]
    LockWithoutProject { path: PathBuf },

    #[error(
        "{path} was written by a newer kendex (format {found}) — update this app before touching it"
    )]
    SchemaTooNew { path: PathBuf, found: i64 },

    #[error("{path}: refused catalog read — {reason}")]
    SourceEscape { path: PathBuf, reason: String },

    #[error("{path} lands at {landed}, outside {root} — refusing to write there")]
    ScopeEscape {
        path: PathBuf,
        landed: PathBuf,
        root: PathBuf,
    },

    #[error("'{name}' already installed from {existing} — refusing to rebind to {requested}")]
    SourceCollision {
        name: String,
        existing: String,
        requested: String,
    },

    // Said as what a person would see if they looked: the name they clicked
    // is a shortcut somebody else set up, and the files are somewhere else.
    // "Foreign symlink, not a clobber target" is the same fact in words that
    // only mean anything to whoever wrote the check.
    #[error(
        "{target} is a shortcut to {points_to}, not a folder of its own.          kendex only takes over files it can move, and moving this would          break whatever set the shortcut up."
    )]
    ForeignSymlink { target: PathBuf, points_to: PathBuf },

    // Keeping the files hands one copy to kendex, and there is one place
    // to put it. Two tools holding different files under one name is a
    // choice, not a merge: which to keep is the reader's to say, and
    // picking for them would put the other in the trash unasked.
    // A take-over named per item answers for that item whole: a name
    // reaching nothing, or a place the take-over cannot settle, stops the
    // run rather than answering a question already gone. Adoption takes
    // what kendex did not write; a position it did write is already looked
    // after, and keeping it would turn a catalog-tracked item into a fork
    // of itself.
    // One item is on or off, not both. Taking one spelling while the other
    // stays leaves a file a later switch reads as kendex's own and writes
    // over, so the reader settles it first.
    #[error(
        "{name} has files under both its on and off names ({detail}). Move the one you don't want somewhere else first."
    )]
    TogglesDiffer { name: String, detail: String },

    #[error("kendex already looks after {name} at {path} — nothing was changed")]
    AlreadyManaged { name: String, path: String },

    #[error("{name} has no files waiting on that choice any more — nothing was changed")]
    TakeOverMatchesNothing { name: String },

    #[error("{name} changed while you were deciding — nothing was changed")]
    TakeOverLeavesSome { name: String },

    /// Each held item as `kind name (why)`: no plan survives to carry the notes.
    #[error("nothing was replaced: every item in the way also has a conflict to settle first — {}", held.join("; "))]
    TakeOverAllHeld { held: Vec<String> },

    #[error(
        "{name}'s files are different for {first} and {second}. kendex keeps one copy of an item, so move the copy you don't want somewhere else first."
    )]
    AdoptedCopiesDiffer {
        name: String,
        first: String,
        second: String,
    },

    #[error("scope is busy: another apply holds {lock}")]
    ScopeBusy { lock: PathBuf },

    #[error("settings are busy: another kendex process holds {lock}")]
    SettingsBusy { lock: PathBuf },

    /// A settings edit that did not go in; the shapes are the module's.
    #[error(transparent)]
    SettingsRefused(#[from] crate::settings_file::SettingsRefusal),

    #[error("credential refresh is busy: another kendex process holds {lock}")]
    CredentialRefreshBusy { lock: PathBuf },

    #[error("app update check is busy: another kendex process holds {lock}")]
    AppUpdateBusy { lock: PathBuf },

    #[error("source cache is busy: another download holds {lock}")]
    CacheBusy { lock: PathBuf },

    #[error(
        "{repo} is pinned to {pin}, which is not in the cache and could not be fetched: {reason}"
    )]
    PinUnavailable {
        repo: String,
        pin: String,
        reason: String,
    },

    #[error("plan is stale: {path} changed since the plan was computed — re-plan and retry")]
    PlanStale { path: PathBuf },

    #[error("source '{name}' has not been downloaded yet — refresh it first")]
    SourcePending { name: String },

    #[error("source '{name}' is disabled")]
    SourceDisabled { name: String },

    #[error("source '{name}' points at {path}, which does not exist")]
    SourceMissing { name: String, path: PathBuf },

    #[error("unknown source '{name}' — declare [sources.{name}] first")]
    UnknownSource { name: String },

    #[error(
        "'{reference}' is not a GitHub repository (owner/repo) — subscribe to it to browse its contents"
    )]
    NotBrowsable { reference: String },

    #[error("{repo} could not be fetched: {reason}")]
    FetchFailed { repo: String, reason: String },

    #[error("'{reference}': {reason}")]
    SourceRefInvalid { reference: String, reason: String },

    #[error(
        "{reference} is already subscribed as '{name}' ({repo}) — one subscription per repository per scope"
    )]
    DuplicateSourceRepo {
        reference: String,
        name: String,
        repo: String,
    },

    /// The typed no-default state the cross-source search catches: a bare
    /// add with no default subscription resolves by searching every
    /// subscription, never by guessing one.
    #[error(
        "no default marketplace in this scope: nothing subscribes to {repo} — name a source, or subscribe to one"
    )]
    NoDefaultSource { repo: String },

    #[error(
        "two subscriptions name the default repository ({repo}): {} — remove one, or name the one you mean",
        names.join(", ")
    )]
    DefaultSourceAmbiguous { repo: String, names: Vec<String> },

    #[error("'{name}' not found in source '{source_name}'")]
    ItemNotInSource { name: String, source_name: String },

    /// A forked agent is assigned a skill nothing in reach offers. The fork
    /// stopped reading the catalog that assigned it, so the rendering would
    /// name instructions that cannot be loaded, and leaving the skill out
    /// takes a whole section off the agent without a word. No source is
    /// named: the assignment resolves against every source here, so which
    /// one supplied the skill is not recorded anywhere, and guessing the
    /// fork's own catalog would send the person to restore a source that
    /// may be enabled and may never have carried it.
    #[error(
        "agent '{name}' is assigned the skill '{skill}', which no source in this scope offers — install a source that carries '{skill}', or drop it from the agent's [agent-skills] entry"
    )]
    AgentSkillUnavailable { name: String, skill: String },

    /// A fork of content already the user's own: forking an in-place tree
    /// would demote the content of record to a render of a hidden copy.
    #[error(
        "'{name}' is already yours — it comes from the {origin} source, so there is nothing to fork"
    )]
    AlreadyOwn { name: String, origin: String },

    /// A tree carrying both `SKILL.md` and `SKILL.md.disabled` has two
    /// claims on one file; a fork keeps neither until it is told which.
    #[error(
        "'{name}' has both SKILL.md and SKILL.md.disabled — remove one before keeping it as your own"
    )]
    ForkAmbiguous { name: String },

    /// An install-beside or fork rename refused before anything was
    /// written: the copy cannot answer to the requested name.
    #[error("`{name}` can't be your copy's name: {problem}")]
    ForkNameUnusable { name: String, problem: String },

    /// A fork refused before writing anything: the rendering on disk keeps
    /// tools from this agent that the fork would hand back. Landing it
    /// would leave the person an agent more permissive than the one they
    /// forked, which is the one thing a fork must never do.
    #[error("keeping '{name}' as your own cannot carry {problem} — nothing was written")]
    ForkWidensAccess { name: String, problem: String },

    /// A fork refused before writing anything: the generated document
    /// around this agent's prose does not read back as the sections the
    /// renderer wrote, so there is no telling the person's own words from
    /// the generated ones, and a capture would cut theirs out.
    #[error("keeping '{name}' as your own cannot read its {harness} rendering: {problem}")]
    ForkWrapperUnreadable {
        name: String,
        harness: String,
        problem: String,
    },

    /// Adoption refused before writing anything: a name kendex would not
    /// install, or a hook entry doing something a declaration has no field
    /// for, is refused rather than followed or quietly reshaped.
    #[error("`{name}` can't name an item to keep: {problem}")]
    AdoptNameUnusable { name: String, problem: String },

    /// An install that would land nowhere: success has to mean bytes
    /// reached disk, so it is refused before the manifest is touched.
    #[error("nothing would be installed — {reason}")]
    InstallsNowhere { reason: String },

    /// Case 4 of naming a catalog: a qualifier naming no subscription
    /// refuses, listing what is subscribed — never a guess.
    #[error(
        "no subscription called '{name}' in this scope — subscribed: {}",
        if subscribed.is_empty() { "none".to_owned() } else { subscribed.join(", ") }
    )]
    UnknownMarketplace {
        name: String,
        /// Each subscription as `alias (owner/repo)`.
        subscribed: Vec<String>,
    },

    /// Case 2: two subscriptions offer the name. The refusal prints the
    /// qualified spellings — the answer to "which one?" is also the syntax
    /// for next time — and each subscription's canonical repository, since
    /// an alias is a local label, not an identity.
    #[error(
        "more than one subscription offers a {} called '{name}': {} — say which one, e.g. --{} {}",
        kind.name(),
        offers.join(", "),
        kind.name(),
        offers.first().map(|o| o.split(' ').next().unwrap_or(o)).unwrap_or_default()
    )]
    ItemAmbiguous {
        kind: ItemKind,
        name: String,
        /// Each offer as `alias::name (owner/repo)`.
        offers: Vec<String>,
    },

    /// Case: no subscription offers the name. Not found is the whole
    /// answer — a fallback would install from a source nobody named.
    #[error(
        "no subscription in this scope offers a {} called '{name}' — qualify it as <marketplace>::{name}, or subscribe to a marketplace that offers it",
        kind.name()
    )]
    ItemNotOffered { kind: ItemKind, name: String },

    /// Case: a bare name matched nothing, but one or more subscriptions
    /// could not be read to answer for it — a broken or unfetched catalog
    /// must not masquerade as "not found", or a hostile marketplace could
    /// hide a name the user really has by refusing to open.
    #[error(
        "could not read {} to search for '{name}': {} — refresh or unsubscribe it, or qualify the name as <marketplace>::{name}",
        if sources.len() == 1 { "a subscription" } else { "some subscriptions" },
        sources.join(", ")
    )]
    SearchSourcesUnreadable { name: String, sources: Vec<String> },

    /// Pi extensions are carrier-only: they are never installed on their own,
    /// and the carrier that would bring one in is not built yet.
    #[error(
        "pi extension '{name}' is not installable on its own, and kendex cannot install one yet — pi-extension support is coming"
    )]
    PiExtensionDirect { name: String },

    /// Keeping a marketplace's packages copies each from its source form, which
    /// would drop a hand edit — so an edited package is decided first.
    #[error(
        "these packages have edits that keeping them from source form would drop: {} — fork or discard each first",
        names.join(", ")
    )]
    DetachEdited { names: Vec<String> },

    /// Keeping a package copies one commit's bytes, but its installations pin
    /// two different commits — local storage has one path per identity.
    #[error(
        "'{name}' is installed at two different revisions — resolve them to one before keeping it as your own"
    )]
    DetachCommitConflict { name: String },

    /// Detach never overwrites what is already in the local source: a different
    /// package of the same kind and name is already there.
    #[error(
        "the local source already holds a different {} called '{name}' at {} — remove it first, or it would be overwritten",
        kind.name(),
        path.display()
    )]
    LocalTargetOccupied {
        kind: ItemKind,
        name: String,
        path: PathBuf,
    },

    /// Invariant 4 for bundles: `[bundles.<name>]` is keyed by bare name,
    /// so one scope holds one bundle per name, whoever offers it.
    #[error(
        "bundle '{name}' is already installed from {existing} — refusing to rebind to {requested}; install the members you want individually (--skill, --agent, …) instead"
    )]
    BundleCollision {
        name: String,
        existing: String,
        requested: String,
    },

    #[error(
        "source '{source_name}' is not a repository — only items from a repo source have revisions; remove the item's rev"
    )]
    ItemRevUnsupported { source_name: String },

    #[error(
        "no {} named '{name}' is declared in this scope — only declared items can be held at a version",
        kind.name()
    )]
    NotDeclared { kind: ItemKind, name: String },

    #[error("'{name}' does not exist in {repo} at {}", &commit[..commit.len().min(7)])]
    ItemMissingAtRev {
        name: String,
        repo: String,
        commit: String,
    },

    #[error("no item from source '{source_name}' offers '{name}' as an optional dependency")]
    NoSuchOptional { name: String, source_name: String },

    #[error("source '{source_name}' offers no bundle called '{name}'")]
    NoSuchBundle { name: String, source_name: String },

    /// Nothing was left behind, and `cause` is the failure that stopped it
    /// — kept whole rather than flattened into `reason`, because what a
    /// caller does about a rollback depends on why: a precondition that
    /// found the file changed is a reload to offer, and a disk that would
    /// not take the write is not.
    #[error("apply failed and was rolled back: {reason}")]
    RolledBack {
        reason: String,
        cause: Box<CoreError>,
    },

    #[error("{path}: structured edit failed: {message}")]
    ConfigEdit { path: PathBuf, message: String },

    #[error("pi package {name}: {message}")]
    PiPackage { name: String, message: String },

    #[error("no {} named '{name}' found for {} in this scope", kind.name(), harness.name())]
    ItemNotFound {
        kind: ItemKind,
        name: String,
        harness: HarnessId,
    },

    #[error("no {} named '{name}' found — not declared and nothing installed under that name", kind.name())]
    PackageNotFound { kind: ItemKind, name: String },

    #[error("{command} failed: {stderr}")]
    GitFailed { command: String, stderr: String },

    /// The community directory or skills.sh could not be reached and
    /// nothing cached can stand in.
    #[error("the community directory is not reachable: {why}")]
    RegistryUnavailable { why: String },

    /// A registry response that does not parse under the pinned schema is
    /// refused whole — never partially believed.
    #[error("the community directory answered something this build does not read: {why}")]
    RegistryMalformed { why: String },

    /// A release feed that exceeds its bounds or does not match the pinned
    /// schema is never partly trusted.
    #[error("the release feed is not valid for this build: {why}")]
    UpdateFeedMalformed { why: String },

    /// A download that does not carry the release's own signature is never
    /// installed, whatever served it.
    #[error("the download does not verify under the pinned release key: {why}")]
    UpdateSignatureRefused { why: String },

    /// A guard's configuration is wrong or a measurement could not be
    /// taken — the loud exit-2 state, never a silent pass.
    #[error("{check}: {message}")]
    Guard { check: String, message: String },

    /// An authoring operation refused; the message is the whole sentence,
    /// including what to do instead.
    #[error("{message}")]
    Authoring { message: String },

    /// No credential is stored on this machine — signing in is the fix.
    #[error("not signed in — run `kendex login` first")]
    NotSignedIn,

    /// The server refuses this sign-in; the local copy is gone unless `why`
    /// says it could not be removed, and `why` carries the fitting remedy.
    #[error("{why}")]
    SignInExpired { why: String },
}

impl CoreError {
    pub fn io(path: impl Into<PathBuf>, source: std::io::Error) -> Self {
        CoreError::Io {
            path: path.into(),
            source,
        }
    }

    /// Whether this is a record kendex cannot read: a lock or manifest
    /// another version wrote, or one damaged past parsing. Two policies
    /// key off this one list. A read that only annotates rows absorbs
    /// exactly it to empty ([`crate::manifest::observed`],
    /// [`crate::lock::observed`]); a verb walking several scopes skips
    /// exactly it, names the scope, and still fails the run. Everything
    /// else propagates from both: an IO failure, or a lock another project
    /// wrote, is not a file kendex merely declines to convert.
    /// `kendex_app::audit::ScopeError` gives each of the three a kind of
    /// its own, and a test there holds the two lists together.
    pub fn is_unreadable_record(&self) -> bool {
        matches!(
            self,
            CoreError::LegacyManifest { .. }
                | CoreError::LockCorrupt { .. }
                | CoreError::SchemaTooNew { .. }
        )
    }
}

pub type Result<T> = std::result::Result<T, CoreError>;
