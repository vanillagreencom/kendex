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
        "{path} is a v1 manifest (no schema key) — migration required; v2 never modifies v1 files (the importer arrives with the release)"
    )]
    LegacyManifest { path: PathBuf },

    #[error("{path} is a v1 vstack lock — migration required; v2 never modifies v1 files")]
    LegacyLock { path: PathBuf },

    #[error(
        "both {new} and {old} exist — {old} was renamed to {new}, and both are here; keep the contents you mean, delete the other, and run again"
    )]
    BothGenerations { new: PathBuf, old: PathBuf },

    #[error("{path}: this lock file is damaged and could not be read — {message}")]
    LockCorrupt { path: PathBuf, message: String },

    #[error(
        "{path} was written by a newer kendex (format {found}) — update this app before touching it"
    )]
    SchemaTooNew { path: PathBuf, found: i64 },

    #[error("{path}: refused catalog read — {reason}")]
    SourceEscape { path: PathBuf, reason: String },

    #[error(
        "the catalog carries both {new} and {old} with different content — it must say one thing; ask its author to remove one, or pin a commit where they agree"
    )]
    CatalogAmbiguous { new: PathBuf, old: PathBuf },

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

    #[error("scope is busy: another apply holds {lock}")]
    ScopeBusy { lock: PathBuf },

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

    /// A skill tree carrying both `SKILL.md` and `SKILL.md.disabled` has
    /// two claims on one source file; a fork would keep one and lose the
    /// other, so it keeps neither until the tree says which is meant.
    #[error(
        "'{name}' has both SKILL.md and SKILL.md.disabled — remove one before keeping it as your own"
    )]
    ForkAmbiguous { name: String },

    /// A second fork of the same package would overwrite the first's
    /// provenance — which source it came from, and at which commit — and
    /// that record lives nowhere but the manifest.
    /// Keeping a package as your own is two steps: the record, and the
    /// render from the copy just kept. The first commits on its own and
    /// takes the installed rendering away, so an interruption between them
    /// leaves the record standing and nothing on disk — and forking again
    /// refuses, because the record is already there. The line has to name
    /// the way back out of that, not only the exits that assume the files
    /// are present.
    #[error(
        "'{name}' is already your own copy — apply this scope to render it again if its files are missing, edit them in place, or remove it and install it again to go back to the source"
    )]
    AlreadyForked { name: String },

    /// Case 4 of naming a catalog: a qualifier that names no subscription
    /// refuses, listing what is subscribed — never a guess, never a
    /// download.
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

    /// Test-only fault injection stopped the apply. Never reached in a
    /// real run: `fail_after` is how the rollback boundaries are exercised.
    #[error("injected fault")]
    Injected,

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

    #[error("no accepted findings recorded under '{key}' in this scope")]
    OverrideNotFound { key: String },

    #[error("no dismissed finding {fingerprint} recorded under '{key}' in this scope")]
    DismissalNotFound { key: String, fingerprint: String },

    #[error(
        "the dismissal of {fingerprint} on '{key}' was replaced by a newer one — nothing was changed"
    )]
    DecisionReplaced { key: String, fingerprint: String },

    #[error(
        "'{token}' is not a decision token — expected kind:name:harness#fingerprint@hash, as printed beside the finding"
    )]
    DecisionToken { token: String },

    #[error("'{key}' does not name an installation — expected kind:name:harness")]
    DecisionKey { key: String },

    #[error("--allow-unsafe {flag} does not name anything this run would install{fix}")]
    GrantMatchesNothing { flag: String, fix: String },

    #[error(
        "'{token}' no longer names what is installed: {why} — nothing was changed; read the current findings and decide again"
    )]
    DecisionStale { token: String, why: String },

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

    /// A guard's configuration is wrong or a measurement could not be
    /// taken — the loud exit-2 state, never a silent pass.
    #[error("{check}: {message}")]
    Guard { check: String, message: String },

    /// An authoring operation refused; the message is the whole sentence,
    /// including what to do instead.
    #[error("{message}")]
    Authoring { message: String },
}

impl CoreError {
    pub fn io(path: impl Into<PathBuf>, source: std::io::Error) -> Self {
        CoreError::Io {
            path: path.into(),
            source,
        }
    }
}

pub type Result<T> = std::result::Result<T, CoreError>;
