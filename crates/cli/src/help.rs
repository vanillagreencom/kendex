//! One layout for the command tree. Clap still owns parsing and usage;
//! this module sets only the opening, spacing and flag headings.

use clap::{Command, CommandFactory};

pub(crate) fn command() -> Command {
    layout(
        crate::Cli::command()
            .about("Install and manage packages for your AI coding harnesses.")
            .long_about(None)
            .version(env!("KENDEX_BUILD_VERSION")),
    )
}

fn layout(command: Command) -> Command {
    command
        .help_template("{about-with-newline}\n{usage-heading} {usage}\n\n{all-args}{after-help}")
        .max_term_width(100)
        .mut_args(|arg| {
            if arg.is_positional() {
                return arg;
            }
            let arg = if arg.get_id() == "global" && arg.get_help().is_none() {
                arg.help("Use your personal setup instead of this project")
            } else {
                arg
            };
            let heading = match arg.get_id().as_str() {
                "global" | "scope" | "from_scope" | "project_path" | "harness"
                | "all_harnesses" | "throwaway" => "Where",
                "agent" | "skill" | "hook" | "command" | "mcp_server" | "pi_extension"
                | "bundle" | "optional" | "all" | "asset" | "skills" | "agents" | "hooks"
                | "commands" | "mcp" | "plugin" => "Packages",
                "json" | "quiet" | "verbose" | "output" => "Output",
                "commit" | "push" | "pull_request" | "leave" | "message" => "Git",
                _ => return arg,
            };
            arg.help_heading(heading)
        })
        .mut_subcommands(layout)
}

#[cfg(test)]
mod tests;
