//! The one line of `kendex check` that is not a stat.
//!
//! Everything else the report says comes off the manifest, the lock, the
//! drift snapshot and the fetch stamps. Commit hooks live in `.git/hooks`,
//! which no lock tracks and which git clones for nobody, so this asks the
//! package that owns them — and asking means launching a script out of a
//! checkout, unattended, at every session start.
//!
//! Which is why this is its own file. Two questions decide whether that
//! happens, in this order and no other: has this project declared the
//! package, and has anything local left a helper in the hooks directory.
//! Everything below either answers those from local state or relays what
//! the package said.

use kendex_core::drift::report::{self, CheckReport};
use kendex_core::env::Env;

/// Whether commits here are actually gated. The one thing this report
/// cannot read off a stat: the shims live in `.git/hooks`, which no lock
/// tracks, and a repository whose shims drifted looks identical on disk to
/// one that never armed any.
///
/// The verdict is the package's own `install-git-hooks --check`, and its
/// summary line is folded whole. kendex used to read the hook files itself
/// here, with a second grammar for what "armed" means; the two never agreed
/// for long, and the disagreement showed up as a session-start report
/// contradicting the gate that actually runs.
///
/// This runs a script out of a checkout, unattended, at every session start
/// — so what may run it is the question the rest of this is about.
///
/// The license is `guard::locally_armed`: the helper the installer leaves
/// in the hooks directory, which git clones for nobody. Its presence is a
/// local act on this machine, and it is the same act that put the
/// checkout's scripts on every commit here. Cloning a repository and asking
/// after its status therefore executes none of its code, whatever the
/// repository ships.
///
/// The install record is NOT that license and never was: `.kendex-lock.json`
/// sits under the work tree and arrives with the fetch, so a checkout can
/// write one declaring anything. It answers a different question — whether
/// this project asked for a commit gate — and so decides only whether an
/// unarmed repository hears about it, which is wording.
///
/// Only project scopes have a work tree to ask about. Every probe here has
/// three answers and not two: a state it read, a state it read as absent,
/// and a state it could not read. The last is `could not check` carrying
/// the reason, never a verdict in the package's vocabulary about something
/// nobody measured.
pub(super) fn fold_commit_hooks(
    env: &Env,
    checked: &mut CheckReport,
    scopes: &[kendex_core::model::Scope],
) {
    use kendex_core::drift::report::{Class, Text};
    use kendex_core::model::Scope;
    for scope in scopes {
        let Scope::Project { root } = scope.canonical() else {
            continue;
        };
        // A checkout that merely carries the files is not missing an arming
        // nobody asked for. Asked before the probe: both cost git
        // processes, and this runs at every session start.
        if !installed_here(env, scope) {
            continue;
        }
        // No repository here is no verdict: there is nothing to arm and no
        // drift to report. Folding it into "not armed" told a scope with no
        // work tree to run `kendex guard install`, which exits 2 there —
        // advice that cannot be taken, every session. The installer's own
        // refusal is exit 2, so asking it would report could-not-check
        // there for ever instead.
        let repo = match kendex_core::guard::Repo::probe(&root) {
            Ok(Some(repo)) => repo,
            Ok(None) => continue,
            Err(error) => {
                fold_unknown(checked, "git", &error);
                continue;
            }
        };
        let (class, text) = match kendex_core::guard::locally_armed(&repo) {
            // No helper, so nothing here is ours to run and the package
            // has nothing to be asked about. The sentence says the one
            // thing that was measured and stops. Not that nothing armed the
            // repository, which the helper's absence does not establish —
            // the lane hooks are three files and this reads one. And no
            // remedy: `kendex guard install` stands down under a configured
            // `core.hooksPath`, so offering it here would offer it every
            // session for ever. What the state means is the package's to
            // say, and it is invited.
            Ok(false) => (
                Class::Drift,
                Text::Own(format!(
                    "the hooks directory of {} holds no {} helper — `kendex guard check` asks the package what this repository's state is",
                    root.display(),
                    kendex_core::guard::HELPER
                )),
            ),
            Err(error) => {
                fold_unknown(checked, "the hooks directory", &error);
                continue;
            }
            Ok(true) => match kendex_core::guard::check_repo(&repo) {
                Ok(report) => match verdict_of(&report) {
                    Some(verdict) => verdict,
                    // Armed, checked, and nothing to say.
                    None => continue,
                },
                // A declaration with nothing at all to run is a missing
                // render: the lock already records the package, so
                // `kendex add` would be advice about a state the reader is
                // not in. Drift with a remedy. A search that could not be
                // made says so instead.
                //
                // And it stops at the two things that were read. Not that
                // every commit therefore fails, which the license above
                // does not establish: that is one stat on the helper, and
                // the lanes that invoke it are separate files nothing here
                // opens. Delete those and leave the helper, and commits go
                // through while this line says they cannot. What git does
                // next is the package's to report, and reading the lane
                // files to find out is the second grammar this module
                // exists to be rid of.
                Err(error) => match kendex_core::guard::installer_present(&repo) {
                    Ok(false) => (
                        Class::Drift,
                        Text::Own(format!(
                            "{} is declared in {} but its scripts are not there — `kendex refresh` renders it again",
                            kendex_core::guard::SKILL,
                            root.display()
                        )),
                    ),
                    Ok(true) => (
                        Class::Unknown,
                        relayed("the growth-guards installer", error.to_string()),
                    ),
                    Err(search) => {
                        fold_unknown(checked, "the skills directories", &search);
                        continue;
                    }
                },
            },
        };
        report::fold(checked, "commit hooks", class, text);
    }
}

/// A state nobody could read, with the reason kept whole.
///
/// `what` names the thing that would not answer, so a reader meets the
/// subject before the diagnosis: an io error's own words say what went
/// wrong and almost never what it was doing.
fn fold_unknown(checked: &mut CheckReport, what: &str, error: &dyn std::fmt::Display) {
    use kendex_core::drift::report::Class;
    report::fold(
        checked,
        "commit hooks",
        Class::Unknown,
        relayed(
            what,
            format!("{what} would not answer, so commit hooks could not be checked: {error}"),
        ),
    );
}

/// Foreign words carried whole rather than as a fragment. The reasons these
/// lines exist sit at their END — an io error's cause, the package's
/// remedy — so a bound that cuts takes exactly the half worth having.
///
/// `line` carries whatever framing the reader needs, because that is what
/// is shown. `producer` names who to go and ask, and is shown only in the
/// one case where the line is not: a line too long to carry at all.
fn relayed(producer: &str, line: String) -> kendex_core::drift::report::Text {
    kendex_core::drift::report::Text::Relayed {
        producer: producer.to_owned(),
        line,
    }
}

/// The package's verdict as a report line, or `None` where there is
/// nothing to report.
///
/// The no-verdict rule is asked FIRST, ahead of every exit-code arm, and
/// that ordering is the point. A summary line is the one thing the package
/// promises on stdout, and it promises it only once `--check` has run:
/// arriving without one means the script died before reaching it, and no
/// exit code it happens to carry makes that a measurement. An
/// `install-git-hooks` truncated at a clean `}` boundary exits 0, which
/// read exit-first is `all clear` about a repository nothing checked.
/// Asking here rather than in each arm is what keeps every later arm from
/// having to remember it.
///
/// What is asked is whether the line IS the summary, not whether stdout
/// held anything. Silence is one way to arrive without a verdict and not
/// the only one: a half-synced installer prints something of its own and
/// exits 0, which a guard testing only for emptiness waves through.
fn verdict_of(
    report: &kendex_core::guard::GuardReport,
) -> Option<(
    kendex_core::drift::report::Class,
    kendex_core::drift::report::Text,
)> {
    use kendex_core::drift::report::Class;
    // One line by contract; joined rather than indexed so a script that
    // wrote two does not have the second silently dropped.
    let said = report.stdout.join(" ");
    let said = said.trim();
    if !said.starts_with(SUMMARY) {
        // The diagnostics are the package's own, and whichever stream its
        // shell put them on is where the reason is.
        return Some((
            Class::Unknown,
            relayed(
                "the growth-guards installer",
                format!(
                    "the growth-guards installer exited {} with no verdict, so commit hooks could not be checked — its own words were: {}",
                    report.code,
                    words_of(report)
                ),
            ),
        ));
    }
    match report.code {
        0 => None,
        // The package's taxonomy: 1 not armed, everything else could not
        // determine. Its sentence is relayed whole, remedy included.
        //
        // And its stderr travels with it, because the sentence can point
        // there: under a configured `core.hooksPath` the summary line says
        // git's report of where the setting comes from is on stderr, and
        // `hooks_path_origins` puts the origins and the one remedy there.
        // Relaying the pointer without what it points at gave the reader a
        // verdict naming a report they were never shown.
        //
        // Still one line, and still the bounded one: the composition
        // happens here, so `Text::Relayed` measures the whole of it against
        // `RELAYED_CHARS` and replaces it past that rather than handing
        // back a remedy cut in half.
        code => Some((
            match code {
                1 => Class::Drift,
                _ => Class::Unknown,
            },
            relayed(
                "the growth-guards installer (`kendex guard check` prints it)",
                with_aside(said, &report.stderr),
            ),
        )),
    }
}

/// The prefix on the package's summary line, and the whole of what tells a
/// verdict from anything else that reached stdout.
///
/// A derivation rather than a copy of the list, because a copy goes stale
/// unread: the lines `install-git-hooks` writes to stdout are what
/// `grep -n echo` on that script shows once the `>&2` lines are dropped,
/// and the `--check` summaries are the ones under `if [ "$MODE" = "check" ]`.
/// Its warnings and diagnostics go to stderr instead (`--help` says so), so
/// stdout carrying something without this prefix is a run that stopped
/// before it reached a verdict.
///
/// Held to the script rather than to this comment by the fixtures that
/// drive the real package and expect an armed repository to report nothing:
/// a prefix that stopped matching folds a clean check as could-not-check,
/// and those go red.
const SUMMARY: &str = "growth-guards git hooks:";

/// Whatever the installer put on either stream, for a line that has to
/// carry words in place of a verdict. Both streams, because a run that
/// never reached its summary may have said why on either of them.
fn words_of(report: &kendex_core::guard::GuardReport) -> String {
    let streams = [report.stdout.join(" "), report.stderr.join(" ")];
    streams
        .iter()
        .map(|stream| stream.trim())
        .filter(|stream| !stream.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

/// The package's verdict with whatever it wrote alongside, or the verdict
/// alone where it wrote nothing.
fn with_aside(said: &str, stderr: &[String]) -> String {
    let aside = stderr.join(" ");
    let aside = aside.trim();
    match aside.is_empty() {
        true => said.to_owned(),
        false => format!("{said} — its stderr said: {aside}"),
    }
}

/// Whether this project's install record carries the guard package — the
/// difference between "your hooks are not armed" and a clone that simply
/// ships the files.
///
/// It is one of two conditions the fold above requires before it launches
/// the package's script, so widening it widens what `kendex check` runs
/// unattended. It is the weaker of the two by design and cannot stand
/// alone: this file arrives with the fetch, so a checkout can write one
/// saying anything, and `guard::locally_armed` is what a checkout cannot
/// forge. Narrowing execution further is safe; loosening this without
/// reading that one is not.
fn installed_here(env: &Env, scope: &kendex_core::model::Scope) -> bool {
    kendex_core::lock::load(&kendex_core::lock::lock_path(env, scope)).is_ok_and(|lock| {
        // Enabled, not merely recorded: a declaration switched off is
        // someone saying they do not want this gate here, and reporting it
        // as unarmed drift every session start argues with them about a
        // choice they already made.
        //
        // And the SKILL of that name, not anything of that name. A name is
        // not unique across kinds — an agent called growth-guards is a
        // legal thing to install — and reading one as consent to a commit
        // gate reports hook drift, every session, at a project that never
        // asked for hooks and has no way to make the report stop.
        lock.entries.values().any(|entry| {
            entry.name == kendex_core::guard::SKILL
                && entry.kind == kendex_core::model::ItemKind::Skill
                && entry.enabled
        })
    })
}
