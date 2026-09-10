//! Templates: a saved selection of packages, kept for this person and
//! reusable in any project.
//!
//! A template is not a subscription and not a project. It records what to
//! install — marketplace packages by the identity their catalog offers
//! them under, and copies of local packages it owns outright — plus the
//! package customizations the selection was saved with. Installing one is
//! an ordinary install of those packages into a scope, so editing or
//! deleting a template afterwards reaches nothing that was installed from
//! it.
//!
//! The index lives in its own `templates.toml` beside the settings file,
//! written through the same writer every other machine-local preference
//! goes through — separate rather than a table inside `AppSettings`
//! because a template carries package customizations whose shape is the
//! manifest's, and folding that into the whole-file settings type split
//! every settings type in the bindings and broke the UI's settings round
//! trip. [`crate::env::Env::templates_file`] names it and [`index`] reads
//! and writes it. The copies live in their own store under the app data
//! root, because a template outlives the project its copies were taken
//! from.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest::FrontmatterOverrides;
use crate::model::ItemKind;

mod create;
mod draft;
mod index;
mod install;
mod store;

pub use create::{
    Chosen, LicenseAnswer, Side, add_from_project, create_from_project, create_from_selection,
};
pub use draft::{
    Draft, DraftError, DraftLocal, DraftMember, DraftOrigin, Excluded, draft_from_project,
    member_key,
};
pub use install::{
    MissingMember, Resolution, ResolvedCopy, ResolvedGroup, ResolvedItem, ResolvedSet,
    TemplateInstall, install, resolve,
};
pub use store::{copy_path, stored_file, stored_files};

/// What a template member is. A curated set is not a kind of package —
/// the catalog offers it under one name and installs it whole — so it
/// stands beside the kinds rather than inside them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub enum MemberKind {
    Agent,
    Skill,
    Hook,
    Command,
    McpServer,
    Plugin,
    PiExtension,
    Bundle,
}

impl MemberKind {
    /// The package kind this member is, or `None` for a curated set.
    pub fn item(self) -> Option<ItemKind> {
        match self {
            MemberKind::Agent => Some(ItemKind::Agent),
            MemberKind::Skill => Some(ItemKind::Skill),
            MemberKind::Hook => Some(ItemKind::Hook),
            MemberKind::Command => Some(ItemKind::Command),
            MemberKind::McpServer => Some(ItemKind::McpServer),
            MemberKind::Plugin => Some(ItemKind::Plugin),
            MemberKind::PiExtension => Some(ItemKind::PiExtension),
            MemberKind::Bundle => None,
        }
    }

    pub fn of(kind: ItemKind) -> MemberKind {
        match kind {
            ItemKind::Agent => MemberKind::Agent,
            ItemKind::Skill => MemberKind::Skill,
            ItemKind::Hook => MemberKind::Hook,
            ItemKind::Command => MemberKind::Command,
            ItemKind::McpServer => MemberKind::McpServer,
            ItemKind::Plugin => MemberKind::Plugin,
            ItemKind::PiExtension => MemberKind::PiExtension,
        }
    }

    pub fn name(self) -> &'static str {
        match self.item() {
            Some(kind) => kind.name(),
            None => "bundle",
        }
    }
}

/// Where a member's content comes from when the template is installed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(
    tag = "held",
    rename_all = "kebab-case",
    rename_all_fields = "kebab-case"
)]
pub enum MemberSource {
    /// A marketplace, named the way a source declaration names it: the
    /// repository, or the folder a path source points at. Saved rather
    /// than the subscription's alias, because an alias is a per-place
    /// manifest key and a template belongs to no place.
    Marketplace {
        repo: String,
        /// The version choice saved with the member, when the selection
        /// carried one. Absent follows the source.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        rev: Option<String>,
    },
    /// A copy this template owns, under its own store. The originating
    /// project may move or disappear without reaching it.
    Copy {
        /// The copy's path inside the template's store, slash-separated.
        copy: String,
        /// The marketplace the copied bytes came from, where they came
        /// from one — an edited copy of a marketplace package keeps
        /// saying so, because editing does not change where content came
        /// from. Absent for the person's own content.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        from: Option<String>,
        /// The licence and attribution files these bytes came under, at
        /// their paths inside the store. Empty for content that came
        /// under nobody's terms.
        ///
        /// The terms are the copy's own record rather than a tree beside
        /// it, so what a read lists and what an install carries are the
        /// union over the copies the template holds: taking a copy out
        /// takes its terms with it, and a notice no copy requires cannot
        /// be shown or written into anybody's project.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        notices: Vec<String>,
    },
}

/// One package a template installs.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub struct Member {
    pub kind: MemberKind,
    pub name: String,
    /// Whether the destination installs this member switched on. A
    /// package the originating project had switched off stays switched
    /// off here rather than being quietly enabled.
    #[serde(default = "yes", skip_serializing_if = "is_yes")]
    pub enabled: bool,
    pub source: MemberSource,
}

fn yes() -> bool {
    true
}

fn is_yes(value: &bool) -> bool {
    *value
}

impl Member {
    /// What tells one member from another: two packages of the same kind
    /// and name from two marketplaces are two members, and the same
    /// identity saved twice is one.
    ///
    /// The repository is folded through [`crate::source_ref::repo_identity`],
    /// which is this repository's one judge of whether two references name
    /// one marketplace — the same value [`install::resolve`] groups by and
    /// `subscription_for` matches a subscription on. A stored `repo` is a
    /// reference to subscribe with and a spelling to show, never a value to
    /// compare: `owner/repo` and its HTTPS spelling are one marketplace and
    /// two strings, and comparing them raw admitted the same package twice
    /// while the row a person could act on named only the first.
    pub fn identity(&self) -> (MemberKind, &str, Option<String>) {
        let repo = match &self.source {
            MemberSource::Marketplace { repo, .. } => Some(crate::source_ref::repo_identity(repo)),
            MemberSource::Copy { .. } => None,
        };
        (self.kind, self.name.as_str(), repo)
    }
}

/// One member, named the way a caller outside core addresses it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct MemberRef {
    pub kind: MemberKind,
    pub name: String,
    /// Which of the members wearing this kind and name is meant.
    pub which: MemberWhich,
}

/// Which member a reference means, where a template holds more than one
/// under a kind and a name.
///
/// Three states, because the domain has three: a template may hold the
/// same kind and name from two marketplaces and as a copy of its own, all
/// at once — [`add_members`] permits it deliberately. A two-state
/// reference could not tell "the copy" from "every one of them", so
/// removing a copy took every marketplace member with it. The state is
/// carried rather than inferred so a caller physically cannot ask for one
/// and be given the other.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(tag = "of", rename_all = "kebab-case", rename_all_fields = "camelCase")]
pub enum MemberWhich {
    /// Every member of this kind and name, whatever it came from. What a
    /// caller means when it has no way to tell them apart and wants them
    /// all gone.
    Any,
    /// The one that came from this marketplace.
    Marketplace { repo: String },
    /// The copy this template owns, which came from no marketplace and so
    /// cannot be named by one.
    Copy,
}

impl MemberRef {
    /// Whether this reference names that member.
    pub fn names(&self, member: &Member) -> bool {
        if self.kind != member.kind || self.name != member.name {
            return false;
        }
        match (&self.which, &member.source) {
            (MemberWhich::Any, _) => true,
            (MemberWhich::Copy, MemberSource::Copy { .. }) => true,
            // One marketplace, however either side spells it: the
            // reference a surface builds its row from is the member's own
            // stored spelling, and a person may have added the same
            // package under another. Folded through the same judge
            // [`Member::identity`] uses, so admission, dedup, grouping and
            // removal all read one value.
            (MemberWhich::Marketplace { repo }, MemberSource::Marketplace { repo: held, .. }) => {
                crate::source_ref::repo_identity(repo) == crate::source_ref::repo_identity(held)
            }
            (MemberWhich::Copy, MemberSource::Marketplace { .. })
            | (MemberWhich::Marketplace { .. }, MemberSource::Copy { .. }) => false,
        }
    }
}

/// Package customizations a template carries, keyed the way the manifest
/// keys them: by the package's own name. Project settings that are not
/// about a package — the review-bot table, custom hooks, install
/// defaults — are not customizations and are never part of a template.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub struct Customizations {
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub optional_dependencies: BTreeMap<String, Vec<String>>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub agent_skills: BTreeMap<String, Vec<String>>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub agent_launch_instructions: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub agent_additional_instructions: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub skill_instructions: BTreeMap<String, String>,
    /// `[agent-frontmatter.<harness>.<agent>]`, as the manifest stores it.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub agent_frontmatter: BTreeMap<String, BTreeMap<String, FrontmatterOverrides>>,
}

impl Customizations {
    pub fn is_empty(&self) -> bool {
        *self == Customizations::default()
    }
}

/// One saved selection.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub struct Template {
    pub name: String,
    /// The folder this template's copies live in, under the store root.
    /// Kept apart from the name so a rename never moves a byte.
    pub id: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub members: Vec<Member>,
    #[serde(default, skip_serializing_if = "Customizations::is_empty")]
    pub customizations: Customizations,
}

/// The refusal for a Pi extension named on its own: it installs with the
/// package that carries it, and the engine says so wherever one is asked
/// for directly. A template keeps that relationship by carrying the
/// package or the curated set that brings the extension, never the
/// extension itself — so the draft leaves a bare one out with this
/// sentence rather than saving a member no install could ever take.
pub const PI_EXTENSION_DIRECT: &str =
    "a Pi extension installs with the package that carries it, never on its own";

/// The longest a template name may be. A name is a row label and names no
/// file, so the ceiling is about what a person can read back rather than
/// about any filesystem: the store keys off [`Template::id`]. Whatever
/// characters a name carries reach a screen through
/// [`crate::names::shown`], the one place kendex makes an untrusted string
/// safe to print, so nothing here re-judges them.
const NAME_CEILING: usize = 80;

/// Whether these members may join a template at all.
///
/// The one place the admission rules live, called by every path that puts
/// members into a template — [`create::create_from_selection`],
/// [`add_members`], [`create::create_from_project`] and
/// [`create::add_from_project`]. Each of those used to decide for itself,
/// which is how adding to an existing template came to accept a member
/// creating one refused: a rule stated at three entry points is a rule
/// the fourth does not have.
///
/// What is here is what holds for every path. A rule true of only one —
/// that a selection picked in a marketplace holds no copies — stays with
/// that path, where it is true.
pub(crate) fn admit(members: &[Member]) -> Result<()> {
    if members.is_empty() {
        return Err(CoreError::TemplateEmpty);
    }
    for member in members {
        // A Pi extension installs with the package that carries it, so a
        // member of its own is a member no install could ever take.
        if member.kind == MemberKind::PiExtension {
            return Err(CoreError::TemplateMemberUnresolved {
                member: member.name.clone(),
                why: PI_EXTENSION_DIRECT.to_owned(),
            });
        }
    }
    Ok(())
}

/// Every template on this machine, in the order they were created.
pub fn list(env: &Env) -> Result<Vec<Template>> {
    Ok(index::load(env)?.templates)
}

/// One template by name, or the refusal naming what was asked for.
pub fn get(env: &Env, name: &str) -> Result<Template> {
    list(env)?
        .into_iter()
        .find(|template| template.name == name)
        .ok_or_else(|| CoreError::NoSuchTemplate {
            name: name.to_owned(),
        })
}

/// A name a template may be saved under, or the refusal saying why not.
/// Asked before a byte is copied, so a refused create leaves no store
/// behind.
fn usable_name(existing: &[Template], name: &str, renaming: Option<&str>) -> Result<String> {
    let name = name.trim().to_owned();
    if name.is_empty() {
        return Err(CoreError::TemplateNameUnusable {
            name,
            why: "a template needs a name".to_owned(),
        });
    }
    if name.chars().count() > NAME_CEILING {
        return Err(CoreError::TemplateNameUnusable {
            name,
            why: format!("a template name is at most {NAME_CEILING} characters"),
        });
    }
    let taken = existing
        .iter()
        .any(|template| template.name == name && Some(template.name.as_str()) != renaming);
    match taken {
        true => Err(CoreError::TemplateNameTaken { name }),
        false => Ok(name),
    }
}

/// A folder name for a template's store that no live template holds and
/// that the store can hold at all.
///
/// Derived from the name for a person reading the directory, and made
/// unique by a counter rather than by the name, so two templates named
/// alike after a rename cannot meet.
///
/// The counter also answers the one way a derived stem can be a name no
/// folder may take: every character here is already `[a-z0-9-]` with no
/// leading or trailing dash, which leaves only a Windows device stem —
/// a template called `NUL` derives `nul` — and a suffix settles that in
/// one turn, since `nul-2` is a device no longer. Asked of the same rule
/// [`index::load`] refuses an id by, so this producer cannot mint a value
/// that reader would turn away.
fn fresh_id(existing: &[Template], name: &str) -> String {
    let stem: String = name
        .chars()
        .map(|c| match c.is_ascii_alphanumeric() {
            true => c.to_ascii_lowercase(),
            false => '-',
        })
        .collect();
    let stem = stem.trim_matches('-').to_owned();
    let stem = match stem.is_empty() {
        true => "template".to_owned(),
        false => stem.chars().take(40).collect(),
    };
    let mut candidate = stem.clone();
    let mut n = 2;
    while existing.iter().any(|template| template.id == candidate)
        || crate::names::segment_problem(&candidate).is_some()
    {
        candidate = format!("{stem}-{n}");
        n += 1;
    }
    candidate
}

/// Save a template built elsewhere. The copies it names are already in the
/// store: this is the index write that makes them a template.
pub(crate) fn insert(env: &Env, template: Template) -> Result<Template> {
    let (_, saved) = index::mutate(env, |index| {
        let mut saved = template.clone();
        saved.name = usable_name(&index.templates, &saved.name, None)?;
        saved.id = fresh_id(&index.templates, &saved.name);
        index.templates.push(saved.clone());
        Ok(saved)
    })?;
    Ok(saved)
}

/// Rename. The store is keyed by id, so nothing moves and every installed
/// package is untouched.
pub fn rename(env: &Env, from: &str, to: &str) -> Result<Template> {
    let (_, renamed) = index::mutate(env, |index| {
        let wanted = usable_name(&index.templates, to, Some(from))?;
        let template = index
            .templates
            .iter_mut()
            .find(|template| template.name == from)
            .ok_or_else(|| CoreError::NoSuchTemplate {
                name: from.to_owned(),
            })?;
        template.name = wanted;
        Ok(template.clone())
    })?;
    Ok(renamed)
}

/// Delete a template and the copies it owns. Packages installed from it
/// stay where they are: an install copies content into the destination,
/// so nothing there points here.
pub fn delete(env: &Env, name: &str) -> Result<()> {
    let (_, template) = index::mutate(env, |index| {
        let at = index
            .templates
            .iter()
            .position(|template| template.name == name)
            .ok_or_else(|| CoreError::NoSuchTemplate {
                name: name.to_owned(),
            })?;
        Ok(index.templates.remove(at))
    })?;
    // The index no longer names these bytes, so the store goes with it.
    // Removed after the index write: a store left behind by a failed
    // delete is unreferenced, while an index entry left behind by a failed
    // store removal is a template whose copies are gone.
    store::remove(env, &template)
}

/// Add members to a template, deduplicating by identity. Returns the
/// template as it now stands.
pub fn add_members(env: &Env, name: &str, members: Vec<Member>) -> Result<Template> {
    admit(&members)?;
    change(env, name, |template| {
        for member in members {
            if !template
                .members
                .iter()
                .any(|held| held.identity() == member.identity())
            {
                template.members.push(member);
            }
        }
        Ok(())
    })
}

/// Take members out. A member whose bytes only this template held goes
/// from the store with it.
pub fn remove_members(env: &Env, name: &str, members: &[MemberRef]) -> Result<Template> {
    let before = get(env, name)?;
    let after = change(env, name, |template| {
        template
            .members
            .retain(|held| !members.iter().any(|wanted| wanted.names(held)));
        Ok(())
    })?;
    store::prune(env, &before, &after)?;
    Ok(after)
}

/// One in-place change to a saved template, under the settings write lock.
pub(crate) fn change(
    env: &Env,
    name: &str,
    edit: impl FnOnce(&mut Template) -> Result<()>,
) -> Result<Template> {
    let (_, changed) = index::mutate(env, |index| {
        let template = index
            .templates
            .iter_mut()
            .find(|template| template.name == name)
            .ok_or_else(|| CoreError::NoSuchTemplate {
                name: name.to_owned(),
            })?;
        edit(template)?;
        Ok(template.clone())
    })?;
    Ok(changed)
}

#[cfg(test)]
mod tests;
