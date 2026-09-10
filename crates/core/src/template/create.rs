//! Saving a template: from a project's draft, and from packages picked in
//! a marketplace.
//!
//! Creating a template from a project copies bytes into the template's own
//! store. It never touches the project: no file moves, no declaration is
//! rewritten, no ownership changes hands. Adoption is the operation that
//! does those things, and it is not what this is.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::author::import::{self, ImportSelection};
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::model::Scope;

use super::draft::{Draft, DraftOrigin, draft_from_project, member_key};
use super::{Customizations, Member, MemberSource, Template, store};

/// Which side of a member offering both a marketplace package and an
/// edited copy the person took.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(
    tag = "side",
    rename_all = "kebab-case",
    rename_all_fields = "camelCase"
)]
pub enum Side {
    /// The package as its marketplace offers it. No bytes are copied, so
    /// there is no licence question to answer.
    Marketplace,
    /// The edited copy on disk, taken into the template's store. Those
    /// bytes are the marketplace's, so the evidence its terms require
    /// travels with the choice: a copy cannot be asked for without it, and
    /// no entry point can reach the capture with the answer left behind.
    Copy { license: LicenseAnswer },
}

/// What the person said about a licensed origin's terms before its bytes
/// are copied. Confirming is only an answer for a licence kendex
/// recognizes as redistributable; anything else needs a stated basis,
/// because a checkbox cannot make proprietary text copyable.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct LicenseAnswer {
    #[serde(default)]
    pub confirmed: bool,
    #[serde(default)]
    pub basis: Option<String>,
}

/// The modal's answers.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct Chosen {
    pub name: String,
    /// Managed members to keep, by [`super::DraftMember::key`]. Anything
    /// the draft listed and this omits is a deliberate exclusion.
    pub members: Vec<String>,
    /// For a member the draft offered as a choice, the side taken — and,
    /// where that side is the copy, the licence evidence it carries. A
    /// member left without a side refuses the save.
    #[serde(default)]
    pub sides: BTreeMap<String, Side>,
    /// Local packages to copy in, by [`super::DraftLocal::key`]. Empty is
    /// the opt-in left off.
    #[serde(default)]
    pub locals: Vec<String>,
    /// Whether the project's package customizations travel with the
    /// selection.
    #[serde(default)]
    pub customizations: bool,
}

/// One copy to take, held until every check has passed.
struct Copying {
    kind: crate::model::ItemKind,
    name: String,
    selection: ImportSelection,
}

/// Save a template from a project, taking the copies the answers opted
/// into.
///
/// The draft is read again here rather than trusted from the modal: a
/// project that changed underneath must refuse, not save a selection that
/// no longer describes it. Every byte is resolved before the index is
/// written, so a refusal leaves neither an index entry nor a store.
pub fn create_from_project(env: &Env, root: &std::path::Path, chosen: &Chosen) -> Result<Template> {
    let draft = draft_from_project(env, root)?;
    let scope = Scope::Project {
        root: crate::paths::canonical(root).map_err(|e| CoreError::io(root, e))?,
    };
    let (mut members, copying, kept) = wanted(&draft, chosen)?;
    // Every byte read and revalidated before the index moves: a stale hash
    // refuses here, with nothing saved and nothing copied.
    let mut resolved = Vec::new();
    for copy in &copying {
        let bytes = import::resolve(env, std::slice::from_ref(&scope), &copy.selection)?;
        resolved.push((copy, bytes));
    }
    bind_notices(&mut members, &resolved);
    super::admit(&members)?;
    let customizations = match chosen.customizations {
        true => super::draft::customizations_for(
            &project_manifest(env, &scope)?,
            &kept.iter().map(String::as_str).collect::<Vec<_>>(),
        ),
        false => Customizations::default(),
    };
    // The index write decides the name and the store folder together,
    // under the settings lock, so two creates racing cannot land on one
    // folder.
    let saved = super::insert(
        env,
        Template {
            name: chosen.name.clone(),
            id: String::new(),
            members,
            customizations,
        },
    )?;
    for (copy, bytes) in resolved {
        if let Err(error) = store::write(
            env,
            &saved.id,
            copy.kind,
            &copy.name,
            &bytes.files,
            &bytes.notices,
        ) {
            // The index names copies that are not there. Nothing has been
            // installed from it and nothing else points at it, so the
            // entry goes and the refusal is the one the copy gave. The
            // removal is a fallible write like any other, and one that
            // fails leaves a template a person can see and can never
            // install — said beside the copy's own reason rather than
            // dropped, because nothing else would ever report it.
            if let Err(removing) = super::delete(env, &saved.name) {
                return Err(CoreError::TemplateCopyUnreadable {
                    copy: copy.name.clone(),
                    why: format!(
                        "{error} — and removing the template this create had already saved failed too: {removing}"
                    ),
                });
            }
            return Err(error);
        }
    }
    super::get(env, &saved.name)
}

/// Take fresh copies of a project's packages into a template that already
/// exists, replacing whatever it held under the same kind and name.
///
/// The design's "replace a local member copy", and the way a marketplace
/// package from a project joins a template too. Same order as a create:
/// every byte is read and revalidated before the index moves, so a
/// refusal leaves the template exactly as it was.
pub fn add_from_project(
    env: &Env,
    name: &str,
    root: &std::path::Path,
    wanted: &[super::MemberRef],
    license: &LicenseAnswer,
) -> Result<Template> {
    let template = super::get(env, name)?;
    let draft = draft_from_project(env, root)?;
    let scope = Scope::Project {
        root: crate::paths::canonical(root).map_err(|e| CoreError::io(root, e))?,
    };
    let mut chosen = Chosen {
        name: template.name.clone(),
        ..Chosen::default()
    };
    for want in wanted {
        let key = member_key(want.kind, &want.name);
        if draft.members.iter().any(|member| member.key == key) {
            chosen.members.push(key);
        } else if draft.locals.iter().any(|local| local.key == key) {
            chosen.locals.push(key);
        } else {
            return Err(CoreError::TemplateMemberUnknown { member: key });
        }
    }
    // An edited package reached this way takes the project's own copy:
    // that is what "take this project's files" asked for, and it is the
    // one reading of the verb that is not a guess. Those bytes are a
    // marketplace's, so the side carries the evidence its terms need —
    // the type is what makes that unforgettable, and it is why this
    // operation asks its caller for the answer.
    for key in &chosen.members {
        chosen.sides.insert(
            key.clone(),
            Side::Copy {
                license: license.clone(),
            },
        );
    }
    let (mut members, copying, _) = self::wanted(&draft, &chosen)?;
    let mut bytes = Vec::new();
    for copy in &copying {
        bytes.push((
            copy,
            import::resolve(env, std::slice::from_ref(&scope), &copy.selection)?,
        ));
    }
    bind_notices(&mut members, &bytes);
    super::admit(&members)?;
    // What each slot held before this write, so a refusal half-way puts
    // the template back the way the doc above says it does. Read before
    // the first write, because after it the bytes are already gone.
    let mut replaced = Vec::new();
    for (copy, _) in &bytes {
        replaced.push((
            copy.kind,
            copy.name.clone(),
            store::held(env, &template, copy.kind, &copy.name)?,
        ));
    }
    for (copy, resolved) in bytes {
        if let Err(error) = store::write(
            env,
            &template.id,
            copy.kind,
            &copy.name,
            &resolved.files,
            &resolved.notices,
        ) {
            // The index still names the old copies, so the store is put
            // back to match it. A restore that itself fails is said out
            // loud rather than folded into the write's own reason: the
            // template is then neither what it was nor what was asked for.
            if let Err(restoring) = store::restore(env, &template, &replaced) {
                return Err(CoreError::TemplateCopyUnreadable {
                    copy: copy.name.clone(),
                    why: format!(
                        "{error} — and putting this template's own copies back failed too: {restoring}"
                    ),
                });
            }
            return Err(error);
        }
    }
    let after = super::change(env, name, |template| {
        for member in members {
            // Every member of that kind and name, deliberately: this verb
            // promises to replace what the template held under the name,
            // and the command line says so before it runs. A reference
            // naming one of several is [`super::MemberWhich`]'s job, and
            // removal is where it is asked.
            template
                .members
                .retain(|held| !(held.kind == member.kind && held.name == member.name));
            template.members.push(member);
        }
        Ok(())
    })?;
    // What only the replaced member accounted for goes with it, through
    // the same prune a removal makes — a replacement takes a member out
    // as much as a removal does, and the store should not hold what no
    // member names.
    //
    // Litter is the smaller half. A licence file nothing references still
    // sits where the terms comparison looks, so a later capture whose own
    // terms differ from that orphan refuses against a file no copy here
    // came under: yesterday's leftover becomes tomorrow's false refusal.
    store::prune(env, &template, &after)?;
    Ok(after)
}

/// Save a template from packages picked somewhere else — a marketplace's
/// table, a set's page. No bytes are copied: every member is a marketplace
/// identity.
pub fn create_from_selection(env: &Env, name: &str, members: Vec<Member>) -> Result<Template> {
    super::admit(&members)?;
    for member in &members {
        if let MemberSource::Copy { copy, .. } = &member.source {
            return Err(CoreError::TemplateCopyUnreadable {
                copy: copy.clone(),
                why: "a template created from a marketplace selection holds no copies".to_owned(),
            });
        }
    }
    let mut kept: Vec<Member> = Vec::new();
    for member in members {
        if !kept.iter().any(|held| held.identity() == member.identity()) {
            kept.push(member);
        }
    }
    super::insert(
        env,
        Template {
            name: name.to_owned(),
            id: String::new(),
            members: kept,
            customizations: Customizations::default(),
        },
    )
}

/// Record on each copied member the licence files its own bytes travel
/// with, now that they have been read.
///
/// The one place a copy's terms are bound to the copy that requires them,
/// so both save paths record the same thing and neither can save a copy
/// whose terms belong to nothing. What a read lists and what an install
/// carries is then the union over the copies the template holds.
fn bind_notices(members: &mut [Member], taken: &[(&Copying, import::ResolvedBytes)]) {
    let recorded: BTreeMap<String, Vec<String>> = taken
        .iter()
        .map(|(copy, bytes)| {
            (
                store::slot_id(copy.kind, &copy.name),
                store::notice_ids(&bytes.notices),
            )
        })
        .collect();
    for member in members {
        if let MemberSource::Copy { copy, notices, .. } = &mut member.source
            && let Some(ids) = recorded.get(copy)
        {
            notices.clone_from(ids);
        }
    }
}

/// The members the answers keep, the copies they require, and the package
/// names the customizations are read for.
fn wanted(draft: &Draft, chosen: &Chosen) -> Result<(Vec<Member>, Vec<Copying>, Vec<String>)> {
    let mut members = Vec::new();
    let mut copying = Vec::new();
    let mut kept = Vec::new();
    for wanted in &chosen.members {
        let member = draft
            .members
            .iter()
            .find(|member| member.key == *wanted)
            .ok_or_else(|| CoreError::TemplateMemberUnknown {
                member: wanted.clone(),
            })?;
        let source = source_of(member, chosen.sides.get(wanted), &mut copying)?;
        kept.push(member.name.clone());
        members.push(Member {
            kind: member.kind,
            name: member.name.clone(),
            enabled: member.enabled,
            source,
        });
    }
    for wanted in &chosen.locals {
        let local = draft
            .locals
            .iter()
            .find(|local| local.key == *wanted)
            .ok_or_else(|| CoreError::TemplateMemberUnknown {
                member: wanted.clone(),
            })?;
        let kind = local
            .kind
            .item()
            .ok_or_else(|| CoreError::TemplateMemberUnresolved {
                member: wanted.clone(),
                why: "a curated set has no files of its own to copy".to_owned(),
            })?;
        // A local package the managed list already carries is the same
        // package, and the template holds it once.
        if members
            .iter()
            .any(|member| member.kind == local.kind && member.name == local.name)
        {
            continue;
        }
        copying.push(Copying {
            kind,
            name: local.name.clone(),
            selection: selection_of(kind, &local.name, &local.hash, None),
        });
        kept.push(local.name.clone());
        members.push(Member {
            kind: local.kind,
            name: local.name.clone(),
            enabled: true,
            source: MemberSource::Copy {
                copy: store::slot_id(kind, &local.name),
                from: None,
                notices: Vec::new(),
            },
        });
    }
    Ok((members, copying, kept))
}

/// Where one chosen member's content comes from, and the copy it needs
/// taken where it needs one.
///
/// Its own function because it is the whole judgement of the save: a
/// marketplace identity is recorded as it stands, the person's own content
/// is copied, a package the project holds two versions of needs the answer
/// the modal asked for, and anything the template cannot record refuses.
fn source_of(
    member: &super::DraftMember,
    side: Option<&Side>,
    copying: &mut Vec<Copying>,
) -> Result<MemberSource> {
    let key = &member.key;
    let unresolved = |why: String| CoreError::TemplateMemberUnresolved {
        member: key.clone(),
        why,
    };
    // A curated set is the catalog's to expand, so it has no files of its
    // own for a copy to be taken from.
    let copyable = || {
        member
            .kind
            .item()
            .ok_or_else(|| unresolved(NO_FILES_OF_ITS_OWN.to_owned()))
    };
    let mut take_copy = |hash: &str,
                         from: Option<String>,
                         license: Option<&LicenseAnswer>|
     -> Result<MemberSource> {
        let kind = copyable()?;
        copying.push(Copying {
            kind,
            name: member.name.clone(),
            selection: selection_of(kind, &member.name, hash, license),
        });
        // The terms these bytes come under are recorded on the member by
        // [`bind_notices`], once the bytes have been read and there is an
        // answer to record. Nothing is copied yet at this point.
        Ok(MemberSource::Copy {
            copy: store::slot_id(kind, &member.name),
            from,
            notices: Vec::new(),
        })
    };
    match (&member.origin, side) {
        (DraftOrigin::Marketplace { repo, rev, .. }, _)
        | (DraftOrigin::Choice { repo, rev, .. }, Some(Side::Marketplace)) => {
            Ok(MemberSource::Marketplace {
                repo: repo.clone(),
                rev: rev.clone(),
            })
        }
        // The person's own content, which came under nobody's terms.
        (DraftOrigin::Copy { hash, .. }, _) => take_copy(hash, None, None),
        (
            DraftOrigin::Choice {
                hash, why, repo, ..
            },
            Some(Side::Copy { license }),
        ) => match hash {
            Some(hash) => take_copy(hash, Some(repo.clone()), Some(license)),
            None => Err(unresolved(
                why.clone()
                    .unwrap_or_else(|| UNSTORABLE_RENDERING.to_owned()),
            )),
        },
        (DraftOrigin::Choice { .. }, None) => Err(unresolved(CHOOSE_A_SIDE.to_owned())),
        (DraftOrigin::Unresolved { why }, _) => Err(unresolved(why.clone())),
    }
}

/// Said for a curated set somebody asked to copy: what it holds is the
/// catalog's to say, and it has no files of its own.
const NO_FILES_OF_ITS_OWN: &str = "a curated set has no files of its own to copy";

/// Said for an edited copy whose current form a template cannot store.
const UNSTORABLE_RENDERING: &str = "this copy is not in a form a template can store";

/// Said for a package the project holds two versions of, with neither
/// chosen. Never resolved here: taking the marketplace bytes would drop
/// the person's edits without a word, and taking the edited copy would
/// save something the marketplace never offered.
const CHOOSE_A_SIDE: &str = "this package is installed from a marketplace and edited here, and a template cannot hold both — choose the marketplace package or this project's copy";

/// The selection the import reader re-resolves: the package's own name at
/// both ends, since a template stores what the project called it.
fn selection_of(
    kind: crate::model::ItemKind,
    name: &str,
    hash: &str,
    license: Option<&LicenseAnswer>,
) -> ImportSelection {
    ImportSelection {
        kind,
        name: name.to_owned(),
        destination: name.to_owned(),
        hash: hash.to_owned(),
        license_confirmed: license.is_some_and(|answer| answer.confirmed),
        license_basis: license.and_then(|answer| answer.basis.clone()),
    }
}

fn project_manifest(env: &Env, scope: &Scope) -> Result<crate::manifest::Manifest> {
    Ok(
        crate::manifest::load_current(&crate::manifest::manifest_path(env, scope))?
            .unwrap_or_default(),
    )
}
