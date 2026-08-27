use kendex_core::apply;
use kendex_core::env::Env;
use kendex_core::error::CoreError;
use kendex_core::model::Scope;

/// Roll back any apply a crash left half-finished, for every scope this
/// machine knows about — before the first scan, so the UI only ever sees
/// consistent state. Failures are reported, never fatal: a broken journal
/// in one scope must not keep the app from opening.
pub fn recover_on_launch(env: &Env) -> Vec<String> {
    let mut messages = Vec::new();
    let mut scopes = vec![Scope::Global];
    match kendex_core::settings::load(env) {
        Ok(settings) => scopes.extend(
            settings
                .projects
                .into_iter()
                .map(|root| Scope::Project { root }),
        ),
        Err(error) => messages.push(format!(
            "settings unreadable, checking global only: {error}"
        )),
    }
    for scope in scopes {
        report(
            &mut messages,
            &scope.label(),
            apply::recover_locked(env, &scope),
        );
    }
    // Common-dir journals are recovered separately from scope ones because
    // they are keyed by a repository rather than a scope, and no scope pass
    // would find them. kendex writes none today — the hook installer that
    // did was replaced by the package's own, which journals nothing — so
    // this recovers what an older version may have left behind.
    match apply::recover_common_journals(env) {
        Ok(keys) => {
            for (key, result) in keys {
                report(&mut messages, &format!("repository hooks ({key})"), result);
            }
        }
        Err(error) => messages.push(format!("repository hooks: recovery failed: {error}")),
    }
    messages
}

fn report(messages: &mut Vec<String>, label: &str, result: Result<bool, CoreError>) {
    match result {
        Ok(true) => messages.push(format!("{label}: recovered an interrupted apply")),
        Ok(false) => {}
        // A live writer holds this key and recovers it itself.
        Err(CoreError::ScopeBusy { .. }) => {}
        Err(error) => messages.push(format!("{label}: recovery failed: {error}")),
    }
}
