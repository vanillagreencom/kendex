//! The pass the desktop's writes close on, the mirror of the terminal's
//! `tidy_trash`: the trash brought within its bounds once a command's own
//! writes are done. The call sites are the list and
//! `docs/architecture/trash.md` § Boundaries owns it.

use kendex_core::env::Env;

/// Bring the trash within its bounds (`kendex_core::trash::retain`) and
/// hand back what went, or why the pass stopped, as lines for the account
/// the command answers with. A pass that stopped is a line and never a
/// failure of the command: the writes are on disk, and the next command
/// through a call site retries it. A pass that removed nothing and did
/// not stop says nothing.
pub(crate) fn tidy(env: &Env) -> Vec<String> {
    let (removed, stopped) = match kendex_core::trash::retain(env) {
        Ok(removed) => (removed, None),
        Err(kendex_core::trash::Stopped { removed, reason }) => (removed, Some(reason)),
    };
    let mut said = Vec::new();
    if removed > 0 {
        said.push(format!(
            "trash: removed {removed} older entr{}",
            if removed == 1 { "y" } else { "ies" }
        ));
    }
    if let Some(reason) = stopped {
        said.push(format!("trash: older entries kept ({reason})"));
    }
    said
}
