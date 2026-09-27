use super::*;
use crate::test_util;
use crate::ui::testing::{plain, rich, tagged};

fn started() -> login::DeviceStart {
    login::DeviceStart {
        device_code: "private-device-code".into(),
        user_code: "ABCD-EFGH".into(),
        verification_url: "https://kendex.ai/device".into(),
        interval_seconds: 5,
        expires_in_seconds: 600,
    }
}

#[test]
fn approval_snapshots_keep_the_private_device_code_off_screen() {
    let started = started();
    assert_eq!(
        approval(&plain(), &started),
        [
            "First, open:  https://kendex.ai/device?code=ABCD-EFGH",
            "Your code:    ABCD-EFGH",
            "",
            "Waiting for approval… (expires in 10 minutes)",
        ]
    );
    assert_eq!(
        tagged(&approval(&rich(80), &started)),
        [
            "<90>First, open: https://kendex.ai/device?code=ABCD-EFGH</>",
            "<90>Your code: ABCD-EFGH</>",
            "",
            "<90>Waiting for approval… (expires in 10 minutes)</>",
        ]
    );
}

#[test]
fn an_existing_sign_in_wraps_but_keeps_the_endpoint_whole() {
    let endpoint = "https://registry.example.test/a-long-endpoint-for-the-person-signing-in";
    let plain = already_signed_in(&plain(), endpoint);
    let rich = already_signed_in(&rich(80), endpoint);
    assert!(
        plain
            .iter()
            .any(|line| console::measure_text_width(line) > 80)
    );
    assert!(
        rich.iter()
            .all(|line| console::measure_text_width(line) <= 80)
    );
    assert!(rich.iter().any(|line| line.contains(endpoint)));
    assert_eq!(
        plain,
        [format!(
            "Already signed in to {endpoint} — run `kendex logout` first to switch."
        )]
    );
}

#[test]
fn sign_in_and_sign_out_outcome_snapshots() {
    for (state, plain_text, rich_text) in [
        (
            Outcome::SignedIn,
            "Signed in. Your sign-in is kept in your system keychain.",
            "<32>✓</> <1>Signed in. Your sign-in is kept in your system keychain.</>",
        ),
        (
            Outcome::SignedOut,
            "Signed out. kendex.ai no longer accepts this sign-in.",
            "<32>✓</> <1>Signed out. kendex.ai no longer accepts this sign-in.</>",
        ),
        (
            Outcome::NotSignedIn,
            "Not signed in.",
            "<36>•</> <1>Not signed in.</>",
        ),
    ] {
        let rich_lines = tagged(&outcome(&rich(80), state));
        assert_eq!(outcome(&plain(), state), [plain_text]);
        assert_eq!(rich_lines, ["", rich_text]);
    }
}

/// Re-execution gives the production style probe a fresh environment.
/// This view test never calls the keychain or the device-flow network API.
#[test]
#[allow(clippy::unwrap_used)]
fn no_color_login_view_matches_a_pipe() {
    const CHILD: &str = "KENDEX_LOGIN_VIEW_CHILD";
    if std::env::var_os(CHILD).is_some() {
        let style = ui::style();
        ui::stderr(&approval(&style, &started()));
        ui::stderr(&outcome(&style, Outcome::SignedIn));
        return;
    }
    let run = |extra: &[(&str, &str)]| {
        let mut environment = vec![(CHILD, "1"), ("LANG", "C.UTF-8")];
        environment.extend_from_slice(extra);
        let output = test_util::reexecute_test(
            module_path!(),
            "no_color_login_view_matches_a_pipe",
            &environment,
        )
        .unwrap();
        assert!(output.status.success(), "{output:?}");
        assert!(
            !output.stderr.is_empty(),
            "the child did not draw the login view"
        );
        output.stderr
    };
    let pipe = run(&[]);
    assert_eq!(run(&[("KENDEX_UI", "pretty"), ("NO_COLOR", "1")]), pipe);
    assert_eq!(run(&[("KENDEX_UI", "pretty"), ("TERM", "dumb")]), pipe);
    assert_ne!(run(&[("KENDEX_UI", "pretty")]), pipe);
}
