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
