//! What "Create template" from a project offers before anything is saved:
//! every package the project manages, what the template would record for
//! each, the local packages the person can opt into, and everything left
//! out with the reason it was.
//!
//! Nothing here writes. The draft is read again at save time and every
//! choice is checked against that second reading, so a project that
//! changed under the modal refuses rather than saving a selection that no
//! longer describes it.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::author::import::{self, CandidateGroup, ImportCandidate};
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest::{INPLACE_SOURCE_NAME, LOCAL_SOURCE_NAME, Manifest};
use crate::model::{ItemKind, Scope};

use super::{Customizations, MemberKind};

/// What a template would record for one managed package.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(
    tag = "origin",
    rename_all = "kebab-case",
    rename_all_fields = "camelCase"
)]
pub enum DraftOrigin {
    /// A marketplace, by the repository or folder its source declares.
    /// Saving records the identity; the bytes come from the marketplace at
    /// install time.
    Marketplace {
        repo: String,
        /// The subscription alias the project declared, for the row to
        /// name a marketplace the person recognizes.
        source: String,
        rev: Option<String>,
    },
    /// The project's own content, which the template copies into its store.
    Copy {
        /// Where the bytes are read from, as kendex spells a path.
        at: String,
        /// The content identity the copy is taken at, revalidated when the
        /// template is saved.
        hash: String,
    },
    /// Both are on offer and neither may be picked for the person: the
    /// marketplace package this was installed from, and the edited copy on
    /// disk. Saving requires the choice.
    Choice {
        repo: String,
        source: String,
        rev: Option<String>,
        /// Where the edited copy is, or null where its current rendering
        /// is not something a template can store.
        at: Option<String>,
        hash: Option<String>,
        /// Why the edited copy cannot be stored, when it cannot.
        why: Option<String>,
        /// The licence the marketplace declares, where it declares one.
        /// Taking the edited copy copies that marketplace's bytes, so the
        /// person answers for the licence before it is stored.
        license: Option<String>,
        /// Whether kendex recognizes that licence as redistributable. An
        /// unrecognized one cannot be confirmed away: it needs a stated
        /// basis.
        license_recognized: bool,
    },
    /// Nothing a template can record. The member stays visible and the
    /// save refuses until it is resolved or excluded.
    Unresolved { why: String },
}

/// One managed package, as the modal lists it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct DraftMember {
    /// What identifies this member inside one draft: the person's choices
    /// come back keyed by it. Carried on the row rather than derived by
    /// each caller, so the modal, the command line and the save all key
    /// the same way.
    pub key: String,
    pub kind: MemberKind,
    pub name: String,
    /// Whether the project has this package switched on. A package
    /// switched off stays switched off in the template.
    pub enabled: bool,
    /// Whether the project declared this package itself, or it arrived
    /// with a set or as something else's dependency.
    pub derived: bool,
    /// The installed packages that require this one, in name order.
    pub required_by: Vec<String>,
    pub origin: DraftOrigin,
}

/// The one spelling of a draft row's key.
pub fn member_key(kind: MemberKind, name: &str) -> String {
    format!("{}:{}", kind.name(), name)
}

/// One unmanaged package the person may opt into copying.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct DraftLocal {
    /// Keyed the way a managed member is — see [`member_key`].
    pub key: String,
    pub kind: MemberKind,
    pub name: String,
    /// Where the bytes are.
    pub at: String,
    pub hash: String,
}

/// Something the project holds that a template cannot carry, and why.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct Excluded {
    pub kind: MemberKind,
    pub name: String,
    pub why: String,
}

/// Why the managed inventory is not the whole story. Present is not an
/// empty project: the modal shows it and the rows it did reach.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct DraftError {
    pub why: String,
}

/// Everything the create-from-project modal draws.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct Draft {
    /// The project this reads.
    pub project: String,
    /// A name the person can accept or replace: the project's folder.
    pub suggested_name: String,
    /// Managed packages, every one included to start with.
    pub members: Vec<DraftMember>,
    /// Unmanaged packages, none of them included to start with.
    pub locals: Vec<DraftLocal>,
    pub excluded: Vec<Excluded>,
    /// The package customizations the project's manifest carries for the
    /// packages above — what "Include package customizations" would save.
    pub customizations: Customizations,
    /// Why the managed reading is short, when it is.
    pub incomplete: Option<DraftError>,
    /// What the rows above offer, as one value. A save carries it back on
    /// [`super::Chosen`] and the save's own reading refuses when the two
    /// differ, so answers made against this draft cannot save something
    /// else. See [`fingerprint`].
    pub fingerprint: String,
}

/// Read a project and answer with everything the modal shows.
///
/// A manifest that will not read is an error rather than a project with
/// nothing in it: a template saved off an unreadable project would claim
/// the project holds nothing, and the person would not know it lied.
pub fn draft_from_project(env: &Env, root: &std::path::Path) -> Result<Draft> {
    let scope = Scope::Project {
        root: crate::paths::canonical(root).map_err(|e| CoreError::io(root, e))?,
    };
    let Scope::Project { root } = &scope else {
        unreachable!("built as a project scope on the line above");
    };
    let manifest: Manifest =
        crate::manifest::load_current(&crate::manifest::manifest_path(env, &scope))?
            .unwrap_or_default();
    let (planned, status) = crate::engine::planned_closure(env, &scope, &manifest);
    let inventory = import::inventory(env, std::slice::from_ref(&scope))?;
    let bytes_of: BTreeMap<(ItemKind, String), &ImportCandidate> = inventory
        .iter()
        .map(|candidate| ((candidate.kind, candidate.name.clone()), candidate))
        .collect();

    let mut members = Vec::new();
    let mut excluded = Vec::new();
    for row in planned {
        let kind = MemberKind::of(row.kind);
        let candidate = bytes_of.get(&(row.kind, row.name.clone())).copied();
        // Two reasons a package the project holds cannot be a member at
        // all. Both are decided here, where the person can see them
        // before saving, rather than at install, where the template is
        // already saved and every install of it refuses.
        if let Some(why) = left_out(row.kind, candidate) {
            excluded.push(Excluded {
                kind,
                name: row.name,
                why,
            });
            continue;
        }
        let origin = origin_of(&manifest, &row.decl, candidate);
        members.push(DraftMember {
            key: member_key(kind, &row.name),
            kind,
            name: row.name,
            enabled: row.decl.enabled,
            derived: row.derived,
            required_by: row.required_by,
            origin,
        });
    }
    // A curated set is a declaration of its own, and installing it is not
    // the same as installing the members it happens to hold today: the set
    // keeps itself whole. So it is a member beside them, and the members
    // it accounts for stay visible under it.
    for (name, decl) in &manifest.bundles {
        members.push(DraftMember {
            key: member_key(MemberKind::Bundle, name),
            kind: MemberKind::Bundle,
            name: name.clone(),
            enabled: decl.enabled,
            derived: false,
            required_by: Vec::new(),
            origin: origin_of(&manifest, decl, None),
        });
    }
    members.sort_by(|a, b| (a.kind, &a.name).cmp(&(b.kind, &b.name)));

    let (mut locals, mut excluded) = offered_locally(&inventory, &members, excluded);
    locals.sort_by(|a, b| (a.kind, &a.name).cmp(&(b.kind, &b.name)));
    excluded.sort_by(|a, b| (a.kind, &a.name).cmp(&(b.kind, &b.name)));

    let names: Vec<&str> = members
        .iter()
        .map(|member| member.name.as_str())
        .chain(locals.iter().map(|local| local.name.as_str()))
        .collect();
    Ok(Draft {
        project: crate::paths::slashed(root),
        fingerprint: fingerprint(&members, &locals),
        suggested_name: root
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| crate::paths::slashed(root)),
        customizations: customizations_for(&manifest, &names),
        members,
        locals,
        excluded,
        incomplete: (status == crate::engine::DeclarationStatus::Incomplete).then(|| DraftError {
            why: INCOMPLETE.to_owned(),
        }),
    })
}

/// The offer these rows make, as one value a save can be checked against.
///
/// Over what a save reads back off the draft and writes: each row's key,
/// the switch it would be saved under, and the identity it was offered
/// under — a copy's hash, a choice's hash and the sides it offers, a local
/// package's hash. A member whose bytes changed between the modal opening
/// and Save therefore changes this, and the save refuses instead of
/// capturing bytes nobody looked at.
///
/// Not over what only the rows say for themselves — which package requires
/// which, what was left out, whether the reading was short — because
/// nothing a save writes comes from those, and a refusal there would stop
/// a save the project has not actually changed under.
///
/// Every field is written length-prefixed: without that, two different
/// offers could spell one string by moving a separator into a name or a
/// path, and the check would pass over the difference it exists to find.
fn fingerprint(members: &[DraftMember], locals: &[DraftLocal]) -> String {
    let mut text = String::new();
    for member in members {
        field(&mut text, "member");
        field(&mut text, &member.key);
        field(&mut text, switch(member.enabled));
        match &member.origin {
            DraftOrigin::Marketplace { repo, source, rev } => {
                field(&mut text, "marketplace");
                field(&mut text, repo);
                field(&mut text, source);
                maybe(&mut text, rev.as_deref());
            }
            DraftOrigin::Copy { at, hash } => {
                field(&mut text, "copy");
                field(&mut text, at);
                field(&mut text, hash);
            }
            DraftOrigin::Choice {
                repo,
                source,
                rev,
                at,
                hash,
                why,
                license,
                license_recognized,
            } => {
                field(&mut text, "choice");
                field(&mut text, repo);
                field(&mut text, source);
                maybe(&mut text, rev.as_deref());
                maybe(&mut text, at.as_deref());
                maybe(&mut text, hash.as_deref());
                maybe(&mut text, why.as_deref());
                maybe(&mut text, license.as_deref());
                field(&mut text, switch(*license_recognized));
            }
            DraftOrigin::Unresolved { why } => {
                field(&mut text, "unresolved");
                field(&mut text, why);
            }
        }
    }
    for local in locals {
        field(&mut text, "local");
        field(&mut text, &local.key);
        field(&mut text, &local.at);
        field(&mut text, &local.hash);
    }
    crate::hash::hash_bytes(text.as_bytes())
}

/// One field of a fingerprint's text, length-prefixed.
fn field(text: &mut String, value: &str) {
    use std::fmt::Write as _;
    let _ = write!(text, "{}:{value}", value.len());
}

/// A field a row may not carry, written so that absent and present-and-empty
/// are two different offers.
fn maybe(text: &mut String, value: Option<&str>) {
    match value {
        Some(value) => {
            field(text, "some");
            field(text, value);
        }
        None => field(text, "none"),
    }
}

/// A boolean as a field, spelled rather than rendered, so the text says
/// what the bit means.
fn switch(on: bool) -> &'static str {
    match on {
        true => "on",
        false => "off",
    }
}

/// Why this package cannot be a template member at all, or `None` where
/// it can.
///
/// A bare Pi extension is one: it installs with what carries it, so a
/// member of its own is a member nothing can ever install. A name no
/// harness would accept is the other: the store would join it into a path
/// and the destination's manifest would refuse it only after the bytes
/// had landed.
fn left_out(kind: ItemKind, candidate: Option<&ImportCandidate>) -> Option<String> {
    if kind == ItemKind::PiExtension {
        return Some(super::PI_EXTENSION_DIRECT.to_owned());
    }
    candidate.and_then(|candidate| candidate.name_problem.clone())
}

/// The exclusion reason for a package with no boundary of its own to copy:
/// an entry that lives inside a tool's shared configuration file is that
/// file's, not a package's, and copying the file would take every
/// unrelated key with it.
pub(super) const NOTHING_TO_COPY: &str =
    "this is an entry in a tool's own configuration file, not a package with files of its own";

/// Said for a package this project declares from its own local packages
/// with nothing installed under that name yet. A template copies bytes,
/// and there are none to copy until the declaration has been applied.
pub(super) const NOT_INSTALLED: &str = "this project declares this package but nothing is installed under that name yet — install the project's own packages first";

/// Said when the closure could not account for every declaration —
/// a marketplace this machine has not fetched, or one that refused to
/// read. The rows that were reached are shown; this says the list is
/// short.
pub(super) const INCOMPLETE: &str = "some of this project's marketplaces could not be read, so this list may be short — refresh them and open this again";

/// The unmanaged packages the local opt-in offers, and everything the scan
/// saw that a template cannot carry, with the reason it cannot.
///
/// Its own function because it answers a different question from the
/// managed pass above it: that one reads what the project declares, this
/// one reads what is on disk under no declaration at all.
fn offered_locally(
    inventory: &[ImportCandidate],
    members: &[DraftMember],
    mut excluded: Vec<Excluded>,
) -> (Vec<DraftLocal>, Vec<Excluded>) {
    let mut locals: Vec<DraftLocal> = Vec::new();
    for candidate in inventory {
        let Some(unmanaged) = candidate
            .origins
            .iter()
            .find(|origin| origin.group == CandidateGroup::Unmanaged)
        else {
            continue;
        };
        let kind = MemberKind::of(candidate.kind);
        // Already a managed member: the same package cannot be both.
        if members
            .iter()
            .any(|member| member.kind == kind && member.name == candidate.name)
        {
            continue;
        }
        // Judged the same way a managed member is: a name no harness
        // would accept is not offered for copying.
        if let Some(why) = candidate.name_problem.clone() {
            excluded.push(Excluded {
                kind,
                name: candidate.name.clone(),
                why,
            });
            continue;
        }
        match (&unmanaged.problem, unmanaged.hash.is_empty()) {
            (Some(why), _) => excluded.push(Excluded {
                kind,
                name: candidate.name.clone(),
                why: why.clone(),
            }),
            (None, true) => excluded.push(Excluded {
                kind,
                name: candidate.name.clone(),
                why: NOTHING_TO_COPY.to_owned(),
            }),
            (None, false) => locals.push(DraftLocal {
                key: member_key(kind, &candidate.name),
                kind,
                name: candidate.name.clone(),
                at: unmanaged.locations.first().cloned().unwrap_or_default(),
                hash: unmanaged.hash.clone(),
            }),
        }
    }
    // Everything the scan saw that is neither managed nor copyable: a
    // config-only entry has no package boundary of its own to copy, so it
    // is named here rather than left out silently.
    for candidate in inventory {
        let kind = MemberKind::of(candidate.kind);
        let known = members
            .iter()
            .any(|member| member.kind == kind && member.name == candidate.name)
            || locals
                .iter()
                .any(|local| local.kind == kind && local.name == candidate.name)
            || excluded
                .iter()
                .any(|gone| gone.kind == kind && gone.name == candidate.name);
        if !known {
            excluded.push(Excluded {
                kind,
                name: candidate.name.clone(),
                why: NOTHING_TO_COPY.to_owned(),
            });
        }
    }
    (locals, excluded)
}

/// What the template would record for one declared package.
fn origin_of(
    manifest: &Manifest,
    decl: &crate::manifest::ItemDecl,
    candidate: Option<&ImportCandidate>,
) -> DraftOrigin {
    // The person's own content, wherever it is kept: the local capture, or
    // the shared tree an in-place declaration reads. Either way the bytes
    // are the project's and the template takes a copy.
    if decl.source == LOCAL_SOURCE_NAME || decl.source == INPLACE_SOURCE_NAME {
        return match own_bytes(candidate) {
            Some((at, hash)) => DraftOrigin::Copy { at, hash },
            // Nothing at all under this name: the project declares it and
            // nothing is installed, so there are no bytes for a copy to
            // be taken at. Said as the state it is, because the way out —
            // install the project's own declarations first — is not the
            // way out of unreadable files.
            None if candidate.is_none() => DraftOrigin::Unresolved {
                why: NOT_INSTALLED.to_owned(),
            },
            None => DraftOrigin::Unresolved {
                why: "this package is installed but its own files could not be read, so there is nothing to copy"
                    .to_owned(),
            },
        };
    }
    let Some(source) = manifest.sources.get(&decl.source) else {
        return DraftOrigin::Unresolved {
            why: format!(
                "this project declares it from '{}', which the project's kendex.toml does not declare",
                crate::names::shown(&decl.source)
            ),
        };
    };
    let Some(repo) = saved_repo(source, std::path::MAIN_SEPARATOR) else {
        return DraftOrigin::Unresolved {
            why: format!(
                "the marketplace '{}' names neither a repository nor a folder",
                crate::names::shown(&decl.source)
            ),
        };
    };
    let rev = decl.rev.clone().or_else(|| source.rev.clone());
    // An installed copy whose bytes have drifted from the marketplace's is
    // two things under one name. Neither may be picked for the person:
    // taking the marketplace bytes would drop their edits without a word,
    // and taking the edited copy would save something the marketplace
    // never offered.
    match candidate.and_then(edited_bytes) {
        Some(edited) => DraftOrigin::Choice {
            repo,
            source: decl.source.clone(),
            rev,
            at: edited.at,
            hash: edited.hash,
            why: edited.why,
            license: edited.license,
            license_recognized: edited.license_recognized,
        },
        None => DraftOrigin::Marketplace {
            repo,
            source: decl.source.clone(),
            rev,
        },
    }
}

/// The one spelling a template saves a marketplace under, or `None` where
/// the source names neither a repository nor a folder.
///
/// A repository reference is text and travels as it stands. A folder is a
/// path, and a path a manifest declares carries whatever separator the
/// machine that wrote it builds paths with — so it is spelled here the way
/// kendex spells every path it hands out. That one spelling is what the
/// member's identity, the grouping an install does over it, the
/// subscription that install makes and the row a person reads all key off:
/// on Windows two members of one folder marketplace saved under two
/// spellings would group apart, subscribe twice and read as two.
///
/// `separator` is what the declaration's own machine builds paths with,
/// passed in the way [`crate::paths`] passes it, so a Windows-shaped
/// declaration is provable on any host.
pub(super) fn saved_repo(source: &crate::manifest::SourceDecl, separator: char) -> Option<String> {
    match (&source.repo, &source.path) {
        (Some(repo), _) => Some(repo.clone()),
        (None, Some(path)) => Some(crate::paths::slashed_over(path, separator)),
        (None, None) => None,
    }
}

/// The person's own bytes for this package, where the inventory found any.
fn own_bytes(candidate: Option<&ImportCandidate>) -> Option<(String, String)> {
    let origin = candidate?
        .origins
        .iter()
        .find(|origin| origin.group == CandidateGroup::Own && !origin.hash.is_empty())?;
    Some((
        origin.locations.first().cloned().unwrap_or_default(),
        origin.hash.clone(),
    ))
}

/// The edited copy of a marketplace package, when the inventory saw one:
/// where it is and the identity it would be copied at, or the reason its
/// current rendering cannot be stored, plus the licence those bytes come
/// under.
struct Edited {
    at: Option<String>,
    hash: Option<String>,
    why: Option<String>,
    license: Option<String>,
    license_recognized: bool,
}

fn edited_bytes(candidate: &ImportCandidate) -> Option<Edited> {
    let origin = candidate
        .origins
        .iter()
        .find(|origin| matches!(origin.group, CandidateGroup::Edited { .. }))?;
    // Editing does not launder provenance: the licence question is the
    // marketplace's, whatever the bytes have become since.
    let (license, license_recognized) = match origin.group.licensed_source() {
        Some((_, license, recognized)) => (license.map(str::to_owned), recognized),
        None => (None, false),
    };
    let at = origin.locations.first().cloned();
    Some(match origin.hash.is_empty() {
        true => Edited {
            at,
            hash: None,
            why: Some(origin.problem.clone().unwrap_or_else(|| {
                "this tool's copy of the package is not in a form a template can store".to_owned()
            })),
            license,
            license_recognized,
        },
        false => Edited {
            at,
            hash: Some(origin.hash.clone()),
            why: None,
            license,
            license_recognized,
        },
    })
}

/// The customizations this manifest holds for these packages, and nothing
/// else. A project setting that is not about a package — the review-bot
/// table, custom hooks, install defaults — stays with the project.
pub(super) fn customizations_for(manifest: &Manifest, names: &[&str]) -> Customizations {
    let mine = |key: &String| names.contains(&key.as_str());
    Customizations {
        optional_dependencies: pick(&manifest.optional_dependencies, mine),
        agent_skills: pick(&manifest.agent_skills, mine),
        agent_launch_instructions: pick(&manifest.agent_launch_instructions, mine),
        agent_additional_instructions: pick(&manifest.agent_additional_instructions, mine),
        skill_instructions: pick(&manifest.skill_instructions, mine),
        agent_frontmatter: manifest
            .agent_frontmatter
            .iter()
            .filter_map(|(harness, agents)| {
                let kept = pick(agents, mine);
                (!kept.is_empty()).then(|| (harness.clone(), kept))
            })
            .collect(),
    }
}

fn pick<V: Clone>(
    from: &BTreeMap<String, V>,
    keep: impl Fn(&String) -> bool,
) -> BTreeMap<String, V> {
    from.iter()
        .filter(|(key, _)| keep(key))
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect()
}
