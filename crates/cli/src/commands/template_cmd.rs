//! `kendex template …` — the same saved selections the window shows, over
//! the same core operations. Nothing about a template is decided here.

use std::collections::BTreeMap;
use std::path::PathBuf;

use clap::{Args, Subcommand};
use kendex_core::env::Env;
use kendex_core::model::Scope;
use kendex_core::template::{
    self, Chosen, Member, MemberKind, MemberRef, MemberSource, Resolution,
};

use super::engine_common::ask_before_writing;
use super::{CliResult, note, out, say, warn};

#[derive(Subcommand)]
pub enum TemplateCommand {
    /// List saved templates
    List,
    /// What one template installs, and anything it cannot reach
    Show { name: String },
    /// Save a template — from a project with --from-project, or from
    /// packages a marketplace offers
    Create {
        name: String,
        /// Take every package this project manages
        #[arg(long)]
        from_project: Option<PathBuf>,
        /// Also copy in the project's supported unmanaged packages
        #[arg(long, requires = "from_project")]
        include_local: bool,
        /// Also carry the project's package settings
        #[arg(long, requires = "from_project")]
        include_customizations: bool,
        /// Leave a package out, as `<kind>:<name>`; repeat for more
        #[arg(long = "exclude", requires = "from_project")]
        excluded: Vec<String>,
        /// For a package this project edited, save the marketplace's
        /// version — `<kind>:<name>`; repeat for more
        #[arg(long, requires = "from_project")]
        use_marketplace: Vec<String>,
        /// For a package this project edited, save this project's own
        /// copy — `<kind>:<name>`; repeat for more
        #[arg(long, requires = "from_project")]
        use_project_copy: Vec<String>,
        /// Confirm the marketplace licence permits copying, for every
        /// --use-project-copy whose licence kendex recognizes
        #[arg(long, requires = "use_project_copy")]
        confirm_license: bool,
        /// Your basis for copying, for a --use-project-copy whose licence
        /// kendex does not recognize
        #[arg(long, requires = "use_project_copy")]
        license_basis: Option<String>,
        #[command(flatten)]
        picked: Picked,
        /// Skip confirmation prompts
        #[arg(short = 'y', long)]
        yes: bool,
    },
    /// Add packages to a template
    Add {
        name: String,
        #[command(flatten)]
        picked: Picked,
        /// Take a package's current files from this project, replacing the
        /// template's own copy of it
        #[arg(long)]
        from_project: Option<PathBuf>,
        #[arg(short = 'y', long)]
        yes: bool,
    },
    /// Take packages out of a template
    Remove {
        name: String,
        #[command(flatten)]
        picked: Picked,
    },
    /// Give a template another name
    Rename { name: String, to: String },
    /// Install a template into a project, or into the personal setup
    Install {
        name: String,
        /// The project to install into; without it the personal setup
        #[arg(long)]
        project: Option<PathBuf>,
        #[arg(short = 'y', long)]
        yes: bool,
    },
    /// Delete a template. Packages installed from it stay installed
    Delete {
        name: String,
        #[arg(short = 'y', long)]
        yes: bool,
    },
}

/// The packages a verb names, in the spelling every other verb takes.
#[derive(Args, Clone, Default)]
pub struct Picked {
    /// The marketplace these packages come from — `owner/repo` or a
    /// folder. Naming it also tells two members of one kind and name
    /// apart; without it a removal reaches every member wearing them
    #[arg(long)]
    pub source: Option<String>,
    #[arg(short = 'a', long)]
    pub agent: Vec<String>,
    #[arg(short = 's', long)]
    pub skill: Vec<String>,
    #[arg(long)]
    pub hook: Vec<String>,
    #[arg(long)]
    pub command: Vec<String>,
    #[arg(long)]
    pub mcp_server: Vec<String>,
    /// Whole sets the marketplace offers
    #[arg(short = 'b', long)]
    pub bundle: Vec<String>,
}

impl Picked {
    fn named(&self) -> Vec<(MemberKind, String)> {
        [
            (MemberKind::Agent, &self.agent),
            (MemberKind::Skill, &self.skill),
            (MemberKind::Hook, &self.hook),
            (MemberKind::Command, &self.command),
            (MemberKind::McpServer, &self.mcp_server),
            (MemberKind::Bundle, &self.bundle),
        ]
        .into_iter()
        .flat_map(|(kind, names)| names.iter().map(move |name| (kind, name.clone())))
        .collect()
    }

    fn is_empty(&self) -> bool {
        self.named().is_empty()
    }

    /// The members these names stand for, or the refusal naming the flag
    /// that is missing.
    fn members(&self) -> Result<Vec<Member>, String> {
        let named = self.named();
        if named.is_empty() {
            return Err(NOTHING_PICKED.to_owned());
        }
        let Some(source) = &self.source else {
            return Err(NO_SOURCE.to_owned());
        };
        Ok(named
            .into_iter()
            .map(|(kind, name)| Member {
                kind,
                name,
                enabled: true,
                source: MemberSource::Marketplace {
                    repo: source.clone(),
                    rev: None,
                },
            })
            .collect())
    }

    fn refs(&self) -> Result<Vec<MemberRef>, String> {
        let named = self.named();
        if named.is_empty() {
            return Err(NOTHING_PICKED.to_owned());
        }
        Ok(named
            .into_iter()
            .map(|(kind, name)| MemberRef {
                kind,
                name,
                repo: self.source.clone(),
            })
            .collect())
    }
}

const NOTHING_PICKED: &str =
    "name at least one package: --skill, --agent, --hook, --command, --mcp-server or --bundle";
const NO_SOURCE: &str = "--source names the marketplace these packages come from";

pub fn run(env: &Env, command: TemplateCommand) -> CliResult {
    match command {
        TemplateCommand::List => list(env),
        TemplateCommand::Show { name } => show(env, &name),
        TemplateCommand::Create {
            name,
            from_project,
            include_local,
            include_customizations,
            excluded,
            use_marketplace,
            use_project_copy,
            confirm_license,
            license_basis,
            picked,
            yes,
        } => create(
            env,
            &name,
            from_project,
            CreateAnswers {
                include_local,
                include_customizations,
                excluded,
                use_marketplace,
                use_project_copy,
                confirm_license,
                license_basis,
            },
            picked,
            yes,
        ),
        TemplateCommand::Add {
            name,
            picked,
            from_project,
            yes,
        } => add(env, &name, picked, from_project, yes),
        TemplateCommand::Remove { name, picked } => {
            let after = template::remove_members(env, &name, &picked.refs()?)?;
            out(&format!(
                "{} now installs {} package(s)",
                after.name,
                after.members.len()
            ));
            Ok(())
        }
        TemplateCommand::Rename { name, to } => {
            let after = template::rename(env, &name, &to)?;
            out(&format!("renamed to {}", after.name));
            Ok(())
        }
        TemplateCommand::Install { name, project, yes } => install(env, &name, project, yes),
        TemplateCommand::Delete { name, yes } => {
            let template = template::get(env, &name)?;
            ask_before_writing(
                &format!(
                    "delete the template '{}'? Packages already installed from it stay installed",
                    template.name
                ),
                yes,
            )?;
            template::delete(env, &template.name)?;
            out(&format!("deleted {}", template.name));
            Ok(())
        }
    }
}

/// A listing distinguishes unreadable storage from an empty list: an error
/// leaves through the verb, and nothing at all says so in words.
fn list(env: &Env) -> CliResult {
    let templates = template::list(env)?;
    if templates.is_empty() {
        out("no templates yet");
        return Ok(());
    }
    for template in templates {
        out(&format!(
            "{}  {} package(s)",
            template.name,
            template.members.len()
        ));
    }
    Ok(())
}

fn show(env: &Env, name: &str) -> CliResult {
    let template = template::get(env, name)?;
    let resolution = template::resolve(env, &template)?;
    out(&format!(
        "{}  {} package(s)",
        template.name,
        template.members.len()
    ));
    print_resolution(&resolution);
    if !template.customizations.is_empty() {
        note("this template carries the package settings it was saved with");
    }
    Ok(())
}

/// The one listing of what a template installs, said the same way by
/// `show` and by the preview `install` asks over.
fn print_resolution(resolution: &Resolution) {
    for group in &resolution.groups {
        let version = match (&group.version, group.last_known) {
            (Some(commit), true) => format!("  (last known {})", &commit[..commit.len().min(7)]),
            (Some(commit), false) => format!("  ({})", &commit[..commit.len().min(7)]),
            (None, _) => String::new(),
        };
        // What the saved revision does, rather than a version this
        // install could pin: an add reads the subscription the scope
        // already declares, so the pin only ever spells a fresh one.
        let subscribed = match (&group.source, &group.rev) {
            (Some(name), _) => format!("subscribed as '{name}'"),
            (None, Some(rev)) => format!("not subscribed yet — installing subscribes at {rev}"),
            (None, None) => "not subscribed yet — installing subscribes".to_owned(),
        };
        say(&format!("{}  [{subscribed}]{version}", group.repo));
        for item in &group.items {
            let off = match item.enabled {
                true => "",
                false => "  (switched off)",
            };
            say(&format!("  {} {}{off}", item.kind.name(), item.name));
        }
        for bundle in &group.bundles {
            say(&format!("  set {bundle}"));
        }
    }
    if !resolution.copies.is_empty() {
        say("this template's own copies");
        for copy in &resolution.copies {
            let from = match &copy.from {
                Some(repo) => format!("  (edited copy of {repo}'s package)"),
                None => String::new(),
            };
            say(&format!("  {} {}{from}", copy.kind.name(), copy.name));
        }
    }
    for member in &resolution.missing {
        warn(&format!(
            "{} {} is not available — {}",
            member.kind.name(),
            member.name,
            member.why
        ));
    }
}

/// The answers `create --from-project` takes for the questions core
/// refuses without: which packages to leave out, which side of an edited
/// package to save, and the licence evidence a marketplace's bytes need.
///
/// A struct rather than seven parameters because they are one answer set,
/// and because the verb fails naming the flag that is missing — the flag
/// names live beside the fields they fill.
pub struct CreateAnswers {
    pub include_local: bool,
    pub include_customizations: bool,
    pub excluded: Vec<String>,
    pub use_marketplace: Vec<String>,
    pub use_project_copy: Vec<String>,
    pub confirm_license: bool,
    pub license_basis: Option<String>,
}

/// A draft key a flag named, refused where the project holds no such
/// package — a typo must not read as "nothing to exclude".
fn known(draft: &template::Draft, flag: &str, keys: &[String]) -> Result<(), String> {
    for key in keys {
        let known = draft.members.iter().any(|member| member.key == *key)
            || draft.locals.iter().any(|local| local.key == *key);
        if !known {
            return Err(format!(
                "{flag} names '{key}', which is not one of {}'s packages — `kendex template create` lists them",
                draft.project
            ));
        }
    }
    Ok(())
}

fn create(
    env: &Env,
    name: &str,
    from_project: Option<PathBuf>,
    answers: CreateAnswers,
    picked: Picked,
    yes: bool,
) -> CliResult {
    let Some(project) = from_project else {
        let template = template::create_from_selection(env, name, picked.members()?)?;
        out(&format!(
            "saved {} with {} package(s)",
            template.name,
            template.members.len()
        ));
        return Ok(());
    };
    if !picked.is_empty() {
        return Err(
            "--from-project takes the project's own packages; name packages without it instead"
                .into(),
        );
    }
    let draft = template::draft_from_project(env, &project)?;
    known(&draft, "--exclude", &answers.excluded)?;
    known(&draft, "--use-marketplace", &answers.use_marketplace)?;
    known(&draft, "--use-project-copy", &answers.use_project_copy)?;
    if let Some(both) = answers
        .use_marketplace
        .iter()
        .find(|key| answers.use_project_copy.contains(key))
    {
        return Err(
            format!("'{both}' is named for both --use-marketplace and --use-project-copy").into(),
        );
    }
    if let Some(short) = &draft.incomplete {
        warn(&short.why);
    }
    let kept: Vec<&template::DraftMember> = draft
        .members
        .iter()
        .filter(|member| !answers.excluded.contains(&member.key))
        .collect();
    say(&format!(
        "{} manages {} package(s)",
        draft.project,
        kept.len()
    ));
    for member in &kept {
        say(&format!("  {} {}", member.kind.name(), member.name));
    }
    let locals: Vec<&template::DraftLocal> = match answers.include_local {
        true => draft
            .locals
            .iter()
            .filter(|local| !answers.excluded.contains(&local.key))
            .collect(),
        false => Vec::new(),
    };
    if answers.include_local {
        say(&format!(
            "copying in {} package(s) this project manages nothing of",
            locals.len()
        ));
        for local in &locals {
            say(&format!("  {} {}", local.kind.name(), local.name));
        }
    }
    for gone in &draft.excluded {
        note(&format!(
            "left out: {} {} — {}",
            gone.kind.name(),
            gone.name,
            gone.why
        ));
    }
    let (sides, licenses) = answered(&kept, &answers)?;
    note(COPIES_GO_INTO_THIS_TEMPLATE);
    ask_before_writing(&format!("save this as '{name}'?"), yes)?;
    let template = template::create_from_project(
        env,
        &project,
        &Chosen {
            name: name.to_owned(),
            members: kept.iter().map(|member| member.key.clone()).collect(),
            locals: locals.iter().map(|local| local.key.clone()).collect(),
            sides,
            licenses,
            customizations: answers.include_customizations,
        },
    )?;
    out(&format!(
        "saved {} with {} package(s)",
        template.name,
        template.members.len()
    ));
    Ok(())
}

/// The per-member answers, or the refusal naming the flag that is still
/// missing.
///
/// Asked before the first write, which is the contract this crate keeps
/// for every verb: a run with nobody to ask must not stop half-way
/// through a save.
type Answers = (
    BTreeMap<String, template::Side>,
    BTreeMap<String, template::LicenseAnswer>,
);

fn answered(
    kept: &[&template::DraftMember],
    answers: &CreateAnswers,
) -> Result<Answers, Box<dyn std::error::Error>> {
    let mut sides = BTreeMap::new();
    let mut licenses = BTreeMap::new();
    for member in kept {
        let side = match (
            answers.use_marketplace.contains(&member.key),
            answers.use_project_copy.contains(&member.key),
        ) {
            (true, _) => Some(template::Side::Marketplace),
            (_, true) => Some(template::Side::Copy),
            _ => None,
        };
        if let Some(side) = side {
            sides.insert(member.key.clone(), side);
        }
        if let Some(missing) = unanswered(member, side, answers) {
            return Err(missing.into());
        }
        if side == Some(template::Side::Copy) {
            licenses.insert(
                member.key.clone(),
                template::LicenseAnswer {
                    confirmed: answers.confirm_license,
                    basis: answers.license_basis.clone(),
                },
            );
        }
    }
    Ok((sides, licenses))
}

/// The flag this member still needs, or `None` where it is answered.
///
/// Said before the first write and naming the flag, because a verb with
/// nobody to ask must not stop half-way through a save — and because the
/// refusal core gives names a choice the command line could not make
/// until now.
fn unanswered(
    member: &template::DraftMember,
    side: Option<template::Side>,
    answers: &CreateAnswers,
) -> Option<String> {
    match &member.origin {
        template::DraftOrigin::Unresolved { why } => Some(format!(
            "{} '{}' cannot be saved — {why}. Leave it out with --exclude {}",
            member.kind.name(),
            member.name,
            member.key
        )),
        template::DraftOrigin::Choice {
            license,
            license_recognized,
            ..
        } => match side {
            None => Some(format!(
                "{} '{}' is installed from a marketplace and edited here, and a template holds one of them — choose with --use-marketplace {} or --use-project-copy {}, or leave it out with --exclude {}",
                member.kind.name(),
                member.name,
                member.key,
                member.key,
                member.key
            )),
            Some(template::Side::Copy) => {
                license_needed(member, license.as_deref(), *license_recognized, answers)
            }
            Some(template::Side::Marketplace) => None,
        },
        _ => None,
    }
}

/// The licence evidence a marketplace's bytes need before they are
/// copied, named as the flag that supplies it.
///
/// Whether evidence is missing is the import gate's judgement, asked
/// through `license_answered` rather than restated here — a second
/// spelling of that rule would drift from the gate that enforces it.
/// What belongs here is only the flag name, which the gate cannot know.
fn license_needed(
    member: &template::DraftMember,
    license: Option<&str>,
    recognized: bool,
    answers: &CreateAnswers,
) -> Option<String> {
    if kendex_core::author::import::license_answered(
        license,
        recognized,
        answers.confirm_license,
        answers.license_basis.as_deref(),
    ) {
        return None;
    }
    let flag = match (license, recognized) {
        (Some(_), true) => "confirm it permits copying with --confirm-license",
        _ => "state your basis with --license-basis",
    };
    let under = match license {
        Some(license) => format!("under licence {license}"),
        None => "with no licence kendex could detect".to_owned(),
    };
    Some(format!(
        "{} '{}' comes from a marketplace {under} — {flag}, or choose --use-marketplace {}",
        member.kind.name(),
        member.name,
        member.key
    ))
}

/// The sentence the create-from-project path says wherever it is said. One
/// spelling, because the window says it too.
pub const COPIES_GO_INTO_THIS_TEMPLATE: &str =
    "Copies go into this template. Files in this project stay unchanged.";

/// Adding to a template: marketplace packages by name, or a fresh copy of
/// a package taken from a project.
fn add(
    env: &Env,
    name: &str,
    picked: Picked,
    from_project: Option<PathBuf>,
    yes: bool,
) -> CliResult {
    let Some(project) = from_project else {
        let after = template::add_members(env, name, picked.members()?)?;
        out(&format!(
            "{} now installs {} package(s)",
            after.name,
            after.members.len()
        ));
        return Ok(());
    };
    let template = template::get(env, name)?;
    let draft = template::draft_from_project(env, &project)?;
    let wanted = picked.refs()?;
    for want in &wanted {
        let key = template::member_key(want.kind, &want.name);
        let known = draft.members.iter().any(|member| member.key == key)
            || draft.locals.iter().any(|local| local.key == key);
        if !known {
            return Err(format!(
                "{} '{}' is not one of {}'s packages",
                want.kind.name(),
                want.name,
                draft.project
            )
            .into());
        }
    }
    // Replacing a copy is a replacement, so the person sees what it is
    // before it happens.
    for want in &wanted {
        if let Some(held) = template
            .members
            .iter()
            .find(|member| member.kind == want.kind && member.name == want.name)
        {
            let standing = match &held.source {
                MemberSource::Copy { .. } => " as a copy — this replaces those files".to_owned(),
                MemberSource::Marketplace { repo, .. } => {
                    format!(" from {repo} — this replaces it with this project's copy")
                }
            };
            say(&format!(
                "{} {} is already in this template{standing}",
                want.kind.name(),
                want.name,
            ));
        }
    }
    note(COPIES_GO_INTO_THIS_TEMPLATE);
    ask_before_writing(&format!("take these files into '{}'?", template.name), yes)?;
    let after = template::add_from_project(env, &template.name, &project, &wanted)?;
    out(&format!(
        "{} now installs {} package(s)",
        after.name,
        after.members.len()
    ));
    Ok(())
}

fn install(env: &Env, name: &str, project: Option<PathBuf>, yes: bool) -> CliResult {
    let template = template::get(env, name)?;
    let destination = match &project {
        Some(root) => Scope::Project {
            root: kendex_core::paths::canonical(root)?,
        },
        None => Scope::Global,
    };
    let resolution = template::resolve(env, &template)?;
    say(&format!(
        "installing {} into {}",
        template.name,
        super::scope_label(&destination)
    ));
    print_resolution(&resolution);
    if !resolution.missing.is_empty() {
        return Err("this template has members nothing can reach — remove them, choose a replacement, or try again once their marketplace reads".into());
    }
    ask_before_writing(&format!("install {} package(s)?", resolution.count()), yes)?;
    let landed = template::install(env, &template, &destination, None, None)?;
    for repo in &landed.subscribed {
        say(&format!("subscribed to {repo}"));
    }
    for declared in &landed.declared {
        say(&format!("installed {declared}"));
    }
    for note_line in &landed.notes {
        note(note_line);
    }
    // The lines above are what is on disk. A run that stopped short says
    // so after them and exits non-zero: reporting the refusal alone would
    // deny the packages that are in, and reporting success would deny the
    // rest of the template that is not.
    match landed.stopped {
        Some(why) => {
            Err(format!("{why} — what is listed above is installed and stays installed").into())
        }
        None => Ok(()),
    }
}
