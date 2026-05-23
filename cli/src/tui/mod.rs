mod install_flow;
mod multiselect;
mod render;
mod state;
mod summary;

pub use multiselect::RepoOption;

pub use install_flow::run_install_flow;
pub use summary::run_summary_screen;

use crate::agent::Agent;
use crate::config::InstallMethod;
use crate::extra::Extra;
use crate::harness::Harness;
use crate::hook::Hook;
use crate::pi_extension::PiExtension;
use crate::skill::Skill;

#[derive(PartialEq)]
pub enum SummaryAction {
    Exit,
    InstallMore,
}

pub struct SummaryData {
    pub agents: Vec<String>,
    pub skills: Vec<String>,
    pub hooks: Vec<(String, String)>,
    pub pi_extensions: Vec<String>,
    pub updated: Vec<String>,
    pub harnesses: Vec<String>,
    pub notes: Vec<String>,
    pub method: String,
    pub scope: String,
}

#[derive(Clone)]
pub struct DiscoveredItems {
    pub agents: Vec<Agent>,
    pub skills: Vec<Skill>,
    pub hooks: Vec<Hook>,
    pub pi_extensions: Vec<PiExtension>,
    pub extras: Vec<Extra>,
}

pub struct InstallSelections {
    pub agents: Vec<Agent>,
    pub skills: Vec<Skill>,
    pub hooks: Vec<Hook>,
    pub pi_extensions: Vec<PiExtension>,
    pub harnesses: Vec<Harness>,
    pub global: bool,
    pub method: InstallMethod,
    pub update_cli: bool,
}

pub struct SourceSelectorData {
    pub current_label: String,
    pub options: Vec<RepoOption>,
}

pub enum InstallFlowResult {
    Cancelled,
    Install(InstallSelections),
    SwitchSource(String),
}
