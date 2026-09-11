//! Installing from a subscription: the picker's rows, and the install
//! itself.
//!
//! Which tools an install lands on is a choice made here rather than taken
//! from the scope's manifest — detection is re-read at install time, so a
//! tool that arrived after the scope was set up is offerable and one gone
//! since does not read as present.

use kendex_core::engine::ops::AddRequest;
use kendex_core::env::Env;
use kendex_core::manifest::Method;
use kendex_core::model::{HarnessId, ItemKind, Scope};
use kendex_core::repo_effects::Offers;
use kendex_core::source_ops;
use serde::{Deserialize, Serialize};
use specta::Type;

use super::{AvailablePackage, env};
use kendex_core::source::browse::{self, Catalog};

/// One row of the install picker: a tool the scope can install to, whether
/// this machine has it, and whether it reads the shared `.agents` tree
/// rather than a directory of its own.
#[derive(Debug, Clone, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct InstallTarget {
    pub harness: HarnessId,
    pub detected: bool,
    pub shares_the_universal_tree: bool,
}

/// Where an install of these kinds could land, for the picker the install
/// flow draws. Two filters, both read from core: which tools can take the
/// kinds being installed at this scope — the same one the install itself
/// refuses by, so the picker cannot offer a choice the install turns down —
/// and which are on this machine. Detection is read now rather than taken
/// from the scope's manifest: a tool that arrived after the scope was set
/// up has to be offerable, and one gone since must not read as present.
#[tauri::command(async)]
#[specta::specta]
pub fn install_targets(scope: Scope, kinds: Vec<ItemKind>) -> Result<Vec<InstallTarget>, String> {
    let env = env()?;
    let detected = kendex_core::engine::ops::detected_harnesses(&env);
    let kinds = match kinds.is_empty() {
        true => ItemKind::ALL.to_vec(),
        false => kinds,
    };
    Ok(kendex_core::engine::ops::targets_for(&kinds, &scope)
        .into_iter()
        .map(|harness| InstallTarget {
            harness,
            detected: detected.contains(&harness),
            shares_the_universal_tree: kendex_core::engine::desired::native_dir(
                &env,
                &scope,
                harness,
                ItemKind::Skill,
            )
            .is_some_and(|dir| dir.ends_with(".agents/skills")),
        })
        .collect())
}

/// One selected package, by the kind and name the catalog offers it under.
#[derive(Debug, Clone, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct InstallItem {
    pub kind: ItemKind,
    pub name: String,
}

/// What an install hands back: the subscription's packages as they stand
/// now, the repository effects the install brought — read and asked about
/// in the window, because nothing here ran them — and what any package the
/// plan took away had undone, which is not asked about at all.
///
/// Both reads happen after the plan is committed, so neither can refuse
/// the install: the files are in whatever they answer. A failure travels
/// as `unread` instead, and the read that failed says nothing rather than
/// something wrong — no packages at all, which is the rows the caller
/// already had standing, and no offer, which is no claim that this install
/// brought none.
#[derive(Debug, Clone, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct Installed {
    /// The subscription as it stands now, or null where reading it back
    /// failed. Absent is not empty: an empty list is a subscription with
    /// nothing in it.
    pub packages: Option<Vec<AvailablePackage>>,
    pub repo_effects: Offers,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub undone: Vec<String>,
    /// What a read behind the write could not answer, or null. The write
    /// landed either way — this is why the account of it is short, and
    /// never why an install is reported as refused.
    pub unread: Option<String>,
}

/// Install packages or a curated set from one subscription. `destination`
/// redirects the install from the scope being browsed into a project: the
/// project gains the personal subscription first (§4.1), then the add runs
/// there — every write lands in exactly one scope. `harnesses` and `method`
/// carry the picker's answer; absent, the scope's own install defaults
/// decide, brought up to date against this machine by the add itself.
/// `optional` carries the optional dependencies the picker ticked, by the
/// name their parent declares them under; the engine records the choice
/// against every item that offers one by that name — a name no item this
/// request touches, and no skill already installed from that source, offers
/// is an error that writes nothing.
#[tauri::command(async)]
#[specta::specta]
#[allow(clippy::too_many_arguments)]
pub fn marketplace_install(
    scope: Scope,
    source: String,
    items: Vec<InstallItem>,
    bundle: Option<String>,
    destination: Option<Scope>,
    hold: bool,
    harnesses: Option<Vec<HarnessId>>,
    method: Option<Method>,
    optional: Vec<String>,
) -> Result<Installed, String> {
    let env = env()?;
    install(
        &env,
        scope,
        source,
        items,
        bundle,
        destination,
        hold,
        harnesses,
        method,
        optional,
    )
}

/// The install itself, against the environment it is given.
#[allow(clippy::too_many_arguments)]
pub fn install(
    env: &Env,
    scope: Scope,
    source: String,
    items: Vec<InstallItem>,
    bundle: Option<String>,
    destination: Option<Scope>,
    hold: bool,
    harnesses: Option<Vec<HarnessId>>,
    method: Option<Method>,
    optional: Vec<String>,
) -> Result<Installed, String> {
    if items.is_empty() && bundle.is_none() {
        return Err("nothing selected to install".to_owned());
    }
    let target = destination.unwrap_or_else(|| scope.clone());
    let mut request = AddRequest {
        source: Some(source.clone()),
        hold,
        harnesses,
        method,
        optional,
        ..AddRequest::default()
    };
    request.bundles.extend(bundle);
    for item in items {
        match item.kind {
            ItemKind::Agent => request.agents.push(item.name),
            ItemKind::Skill => request.skills.push(item.name),
            ItemKind::Hook => request.hooks.push(item.name),
            ItemKind::Command => request.commands.push(item.name),
            ItemKind::McpServer => request.mcp_servers.push(item.name),
            // A plugin is its registry's curated set, so it installs as one.
            ItemKind::Plugin => request.bundles.push(item.name),
            // Passed through so the engine's uniform refusal answers it.
            ItemKind::PiExtension => request.pi_extensions.push(item.name),
        }
    }
    // A whole set carries its own members; expanding agents' skills on top
    // would install beyond what the set declares.
    request.no_auto_skills = !request.bundles.is_empty();
    // Which places a subscription installs into is core's rule. Redirected
    // into a project, the subscription and the packages are one plan: a
    // refused install leaves the project subscribed to nothing.
    let report = source_ops::install_from(env, &scope, &source, &target, &request)
        .map_err(|e| e.to_string())?;
    // Through the one executor, like every report, because no path here
    // can prove its own plan takes nothing away. An add is not exempt: a
    // rendering the engine refuses drops that package's lock entry
    // whatever the planning options say, and its uninstaller runs.
    let undone = crate::repo_effects::write(env, &report)?;
    // After the write, because the script an effect runs is the one this
    // install just put on disk.
    //
    // Both reads are enrichment past a committed plan: the uninstallers
    // have run, the files are in, and nothing either of them answers can
    // change that. So neither is a `?`. A refusal reaches the caller as
    // this command's error and means the write did not happen — reporting
    // "couldn't install" over an install that landed is the one account
    // the person cannot act on, and it would take the repository effects
    // this install brought down with it, leaving a package that arms a
    // checkout installed and undisclosed.
    let offers = kendex_core::repo_effects::offers_for(env, &target, &report.repo_effects)
        .map_err(|e| e.to_string());
    let listed = browse::packages(
        env,
        &Catalog::Subscription {
            scope: target,
            source,
        },
    )
    .map_err(|e| e.to_string());
    Ok(landed(undone, offers, listed))
}

/// The account of a write that has already happened, from what the two
/// reads behind it answered.
///
/// Neither read can refuse the install, so this returns an `Installed`
/// whatever they say. Both of their failures where both failed: they are
/// two reads and either fails on its own. What the write left is not
/// folded in the way `repo_effects::after_writing` folds it — `undone`
/// rides back on this same answer and the caller says it, so repeating it
/// here would say it twice.
fn landed(
    undone: Vec<String>,
    offers: Result<Offers, String>,
    listed: Result<Vec<AvailablePackage>, String>,
) -> Installed {
    let unread: Vec<String> = [offers.as_ref().err(), listed.as_ref().err()]
        .into_iter()
        .flatten()
        .cloned()
        .collect();
    Installed {
        packages: listed.ok(),
        repo_effects: offers.unwrap_or_default(),
        undone,
        unread: (!unread.is_empty()).then(|| unread.join("\n")),
    }
}

#[cfg(test)]
mod tests {
    use kendex_core::repo_effects::Withheld;

    use super::*;

    /// A read behind a committed write is not the write: the files are in
    /// whatever it answers. One row per way the pair can go, and each says
    /// the same thing — the failure is named, the read that landed is kept
    /// whole, and what the write undid rides back untouched.
    ///
    /// The catalogue row is the one a person sees: without it the install
    /// reports "couldn't install" over packages that are on disk. The
    /// effects row is the one they do not — a package that arms a checkout
    /// would be installed with nothing disclosed.
    #[test]
    fn a_read_that_failed_after_the_write_is_never_a_refusal() {
        let offers = || Offers {
            shown: Vec::new(),
            withheld: vec![Withheld {
                name: "commit-guards".to_owned(),
                reason: "this project is not a git repository".to_owned(),
            }],
        };
        type Row<'a> = (
            &'a str,
            Result<Offers, String>,
            Result<Vec<AvailablePackage>, String>,
            bool,
            Option<&'a str>,
            usize,
        );
        let rows: [Row<'_>; 4] = [
            ("both read", Ok(offers()), Ok(Vec::new()), true, None, 1),
            (
                "the catalogue would not read",
                Ok(offers()),
                Err("no catalogue".to_owned()),
                false,
                Some("no catalogue"),
                1,
            ),
            (
                "the effects would not read",
                Err("no effects".to_owned()),
                Ok(Vec::new()),
                true,
                Some("no effects"),
                0,
            ),
            (
                "neither read",
                Err("no effects".to_owned()),
                Err("no catalogue".to_owned()),
                false,
                Some("no effects\nno catalogue"),
                0,
            ),
        ];
        for (name, offers, listed, listed_kept, unread, withheld) in rows {
            let answer = landed(vec!["took the hooks out".to_owned()], offers, listed);
            assert_eq!(answer.packages.is_some(), listed_kept, "{name}");
            assert_eq!(answer.unread.as_deref(), unread, "{name}");
            assert_eq!(answer.repo_effects.withheld.len(), withheld, "{name}");
            assert_eq!(answer.undone, ["took the hooks out"], "{name}");
        }
    }
}
