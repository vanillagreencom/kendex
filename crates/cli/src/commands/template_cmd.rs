//! `kendex template …` — the same saved selections the window shows, over
//! the same core operations. Nothing about a template is decided here.

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
    /// The marketplace these packages come from — `owner/repo` or a folder
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
            .map(|(kind, name)| MemberRef { kind, name })
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
            picked,
            yes,
        } => create(
            env,
            &name,
            from_project,
            include_local,
            include_customizations,
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
        let subscribed = match &group.source {
            Some(name) => format!("subscribed as '{name}'"),
            None => "not subscribed yet — installing subscribes".to_owned(),
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

#[allow(clippy::too_many_arguments)]
fn create(
    env: &Env,
    name: &str,
    from_project: Option<PathBuf>,
    include_local: bool,
    include_customizations: bool,
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
    if let Some(short) = &draft.incomplete {
        warn(&short.why);
    }
    say(&format!(
        "{} manages {} package(s)",
        draft.project,
        draft.members.len()
    ));
    for member in &draft.members {
        say(&format!("  {} {}", member.kind.name(), member.name));
    }
    if include_local {
        say(&format!(
            "copying in {} package(s) this project manages nothing of",
            draft.locals.len()
        ));
        for local in &draft.locals {
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
    note(COPIES_GO_INTO_THIS_TEMPLATE);
    ask_before_writing(&format!("save this as '{name}'?"), yes)?;
    let template = template::create_from_project(
        env,
        &project,
        &Chosen {
            name: name.to_owned(),
            members: draft
                .members
                .iter()
                .map(|member| member.key.clone())
                .collect(),
            locals: match include_local {
                true => draft.locals.iter().map(|local| local.key.clone()).collect(),
                false => Vec::new(),
            },
            customizations: include_customizations,
            ..Chosen::default()
        },
    )?;
    out(&format!(
        "saved {} with {} package(s)",
        template.name,
        template.members.len()
    ));
    Ok(())
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
    Ok(())
}
