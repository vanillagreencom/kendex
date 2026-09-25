//! The pass the desktop's writes close on, the mirror of the terminal's
//! `tidy_trash`. Where it runs and where its lines go is
//! `docs/architecture/trash.md` § Boundaries.

use kendex_core::env::Env;

/// Bring the trash within its bounds (`kendex_core::trash::retain`) and
/// hand back what went, or why the pass stopped, as lines. A stop is a
/// line, never an error; a pass that removed nothing and did not stop
/// hands back none.
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
