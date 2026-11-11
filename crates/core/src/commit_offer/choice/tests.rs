//! Which choices an offer carries, and why one is missing.

use std::path::PathBuf;

use super::*;
use crate::commit_offer::{Carry, OpenPullRequest, Remote, Scan};

fn offer(
    remote: bool,
    push: Result<(), Unavailable>,
    pull_request: Result<(), Unavailable>,
    open: Option<u64>,
) -> Offer {
    Offer {
        scan: Scan {
            root: PathBuf::from("/project"),
            owned: Vec::new(),
            beside: Vec::new(),
            carry: Carry::Untaken,
            others: 0,
            manifest: None,
            branch: Branch::On("main".to_owned()),
        },
        branch: "main".to_owned(),
        remote: remote.then(|| Remote {
            name: "origin".to_owned(),
            url: "https://example.invalid/r.git".to_owned(),
            push_url: None,
            tracked: true,
        }),
        push,
        pull_request,
        open: open.map(|number| OpenPullRequest {
            number,
            url: format!("https://example.invalid/r/pull/{number}"),
        }),
        message: "kendex".to_owned(),
        new_branch: "kendex/update".to_owned(),
    }
}

/// The routes each offer carries, in order, and the reason each missing
/// one gives. Leave is always last and is the only default.
#[test]
fn the_choices_stand_where_their_preconditions_hold() {
    use Route::{Commit, Leave, PullRequest, Push};
    let no_remote = || Err(Unavailable::NoRemote);
    let rules = || Err(Unavailable::PullRequestRequired);
    // (offer, routes on offer, why push is missing, why a pull request is)
    type Row = (Offer, Vec<Route>, Option<Withheld>, Option<Withheld>);
    let rows: Vec<Row> = vec![
        (
            offer(true, Ok(()), Ok(()), None),
            vec![Commit, Push, PullRequest, Leave],
            None,
            None,
        ),
        (
            offer(false, no_remote(), no_remote(), None),
            vec![Commit, Leave],
            Some(Withheld::Unavailable(Unavailable::NoRemote)),
            Some(Withheld::Unavailable(Unavailable::NoRemote)),
        ),
        (
            offer(true, rules(), Ok(()), None),
            vec![Commit, PullRequest, Leave],
            Some(Withheld::Unavailable(Unavailable::PullRequestRequired)),
            None,
        ),
        (
            offer(true, Ok(()), Ok(()), Some(7)),
            vec![Commit, Push, Leave],
            None,
            Some(Withheld::AlreadyOpen(7)),
        ),
        (
            offer(true, Ok(()), Err(Unavailable::GhMissing), None),
            vec![Commit, Push, Leave],
            None,
            Some(Withheld::Unavailable(Unavailable::GhMissing)),
        ),
    ];
    for (offer, routes, push, pull_request) in rows {
        let choices = offer.choices();
        let taken: Vec<Route> = choices.iter().map(|choice| choice.route).collect();
        assert_eq!(taken, routes);
        let defaults: Vec<Route> = choices
            .iter()
            .filter(|choice| choice.default)
            .map(|choice| choice.route)
            .collect();
        assert_eq!(defaults, vec![Leave]);
        assert_eq!(offer.withheld(Push), push, "{routes:?}");
        assert_eq!(offer.withheld(PullRequest), pull_request, "{routes:?}");
        assert_eq!(offer.withheld(Commit), None);
        assert_eq!(offer.withheld(Leave), None);
    }
}

/// Each choice is bound to the branch, remote and pull request it acts on.
#[test]
fn each_choice_names_its_target() {
    let effects = |offer: Offer| -> Vec<RouteEffect> {
        offer
            .choices()
            .into_iter()
            .map(|choice| choice.effect)
            .collect()
    };
    let main = || "main".to_owned();
    let origin = || "origin".to_owned();
    assert_eq!(
        effects(offer(true, Ok(()), Ok(()), None)),
        vec![
            RouteEffect::Commit { branch: main() },
            RouteEffect::Push {
                remote: origin(),
                branch: main()
            },
            RouteEffect::OpenPullRequest {
                branch: "kendex/update".to_owned(),
                base: main()
            },
            RouteEffect::Leave,
        ]
    );
    assert_eq!(
        effects(offer(true, Ok(()), Ok(()), Some(7)))[1],
        RouteEffect::AddToPullRequest {
            remote: origin(),
            branch: main(),
            number: 7
        }
    );
}

/// A checkout on no branch, or in the middle of an operation, is blocked:
/// no choice can be offered there.
#[test]
fn a_checkout_off_a_branch_is_blocked() {
    use crate::commit_offer::Operation;
    for (branch, need) in [
        (Branch::On("main".to_owned()), Need::Decision),
        (Branch::Detached, Need::Blocked),
        (Branch::InProgress(Operation::Merge), Need::Blocked),
    ] {
        assert_eq!(branch.need(), need);
    }
}
