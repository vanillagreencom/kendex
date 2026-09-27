//! One layout for the command tree. Clap owns parsing, usage and argument
//! groups; this module sets the opening, spacing and width.

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
            if arg.get_id() == "global" && arg.get_help().is_none() {
                arg.help("Use your personal setup instead of this project")
            } else {
                arg
            }
        })
        .mut_subcommands(layout)
}

#[cfg(test)]
mod tests;
