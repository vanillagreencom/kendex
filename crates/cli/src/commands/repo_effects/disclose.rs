//! The block a person reads, and the seal taken as they read it.
//!
//! Its own file because it is one concept with one edge: everything here
//! turns an offer into what is on the screen, and hands back exactly what
//! was shown. The consent that follows is next door and reads nothing
//! else. What a declaration means for THIS repository — where a path
//! lands, who shares it, which companions are here — is core's answer, and
//! this only prints it, through the `ui` seam that escapes it.

use kendex_core::env::Env;
use kendex_core::model::Scope;
use kendex_core::repo_effects::{DeclaredEffects, Disclosure};

use super::super::say;

/// The block, in the order a reader needs it: what changes, what is
/// written, which packages take part, whatever the package itself wants
/// read, and how to undo it.
///
/// Every line of it is either the package's own words or a fact kendex
/// knows about this machine. Nothing here explains what a declaration
/// MEANS: that is the package's contract, and kendex is not a party to it.
///
/// On the human channel, with the question it belongs to. This is not
/// output a caller composes with — it is the context for `[y/N]`, and the
/// prompt writes to stderr. Sending the block to stdout meant
/// `kendex add ... > log` asked the question with the reasons for it in the
/// file, which is a consent prompt with nothing to consent to.
pub fn disclose(
    env: &Env,
    scope: &Scope,
    effects: &[DeclaredEffects],
) -> Result<Vec<Disclosure>, Box<dyn std::error::Error>> {
    let offers = kendex_core::repo_effects::offers_for(env, scope, effects)?;
    for withheld in &offers.withheld {
        say(&format!(
            "{}: not disclosed — {}",
            withheld.name, withheld.reason
        ));
    }
    for disclosure in &offers.shown {
        print(disclosure);
    }
    Ok(offers.shown)
}

fn print(disclosure: &Disclosure) {
    let name = &disclosure.name;
    say("");
    say(&format!(
        "{name} changes how this repository works, beyond the files above:"
    ));
    say(&format!("  {}", disclosure.summary));
    if !disclosure.writes.is_empty() {
        say("");
        say("  writes");
        // Marked one by one. A package that writes into `.git/hooks` and
        // into `.github` writes one file every work tree sees and one only
        // this checkout has, and a sentence under the whole list claimed
        // the first about both.
        for written in &disclosure.writes {
            let mark = match written.shared {
                true => "  (shared)",
                false => "",
            };
            say(&format!("    {}{mark}", written.path));
        }
        if disclosure.writes.iter().any(|written| written.shared) {
            say("");
            say("  the paths marked shared are the repository's, not this");
            say("  checkout's: every work tree of it sees those files");
        }
    }
    if !disclosure.companions.is_empty() {
        say("");
        say("  companion packages");
        for companion in &disclosure.companions {
            say(&format!(
                "    {} ({})",
                companion.name,
                match companion.installed {
                    true => "installed",
                    false => "not installed",
                }
            ));
        }
        // The names and whether each is here, and nothing about what that
        // means. What a companion's presence or absence does is the
        // package's own contract, and kendex stating it here stated
        // growth-guards' for every package that declares any. A package
        // with something to say about its companions says it in `notes`.
    }
    for note in &disclosure.notes {
        say("");
        say(&format!("  {}", note));
    }
    say("");
    match &disclosure.undo {
        Some(undo) => say(&format!("  to undo: {}", undo)),
        // Not "remove the package". Removal runs whatever uninstaller
        // the package declared, and this one declared none: its files
        // would go and the effect would stay — shims in .git/hooks
        // outlive the tree they point at, and then fail every commit
        // closed. What is true is that the package said nothing about
        // undoing this.
        None => say("  to undo: the package declares no way to undo it"),
    }
}
