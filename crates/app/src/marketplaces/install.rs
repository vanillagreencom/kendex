//! Installing from a subscription: the picker's rows, and the install
//! itself.
//!
//! Which tools an install lands on is a choice made here rather than taken
//! from the scope's manifest — detection is re-read at install time, so a
//! tool added since the scope was set up is offerable and one removed since
//! does not read as present.

use kendex_core::engine::ops::{self as engine_ops, AddRequest};
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
/// from the scope's manifest: a tool added since the scope was set up has
/// to be offerable, and one removed since must not read as present.
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
#[derive(Debug, Clone, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct Installed {
    pub packages: Vec<AvailablePackage>,
    pub repo_effects: Offers,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub undone: Vec<String>,
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
    let redirected = target != scope;
    if redirected {
        if !matches!(&target, Scope::Project { .. }) {
            return Err("an install can only be redirected into a project".to_owned());
        }
        if scope != Scope::Global {
            return Err("only a personal subscription can install into a project".to_owned());
        }
    }
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
    // Redirected into a project, the subscription and the packages are one
    // plan: a refused install leaves the project subscribed to nothing.
    let report = match &target {
        Scope::Project { root } if redirected => {
            source_ops::install_project_from_personal(env, root, &source, &request)
        }
        _ => engine_ops::add(env, &target, &request),
    }
    .map_err(|e| e.to_string())?;
    // Through the one executor, like every report, because no path here
    // can prove its own plan takes nothing away. An add is not exempt: a
    // rendering the engine refuses drops that package's lock entry
    // whatever the planning options say, and its uninstaller runs.
    let undone = crate::repo_effects::write(env, &report)?;
    // After the write, because the script an effect runs is the one this
    // install just put on disk.
    // Both reads are enrichment past the write, so both carry the account
    // on their failure rather than through it: the uninstallers have run
    // and the plan is committed, and a listing error over a repository
    // that was just disarmed is this issue's own failure mode.
    let repo_effects = crate::repo_effects::after_writing(
        &undone,
        kendex_core::repo_effects::offers_for(env, &target, &report.repo_effects)
            .map_err(|e| e.to_string()),
    )?;
    let packages = crate::repo_effects::after_writing(
        &undone,
        browse::packages(
            env,
            &Catalog::Subscription {
                scope: target,
                source,
            },
        )
        .map_err(|e| e.to_string()),
    )?;
    Ok(Installed {
        packages,
        repo_effects,
        undone,
    })
}
