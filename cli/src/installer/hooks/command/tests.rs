//! Reading back the commands vstack writes, and the ones a user reshaped.

use super::*;

fn targets(command: &str, script: &str) -> bool {
    command_targets_hook_script(command, Path::new(script), None)
}

/// The command vstack WRITES has to read back as the command vstack wrote.
/// `shell_quote` quotes any path that is not plain, and the whitespace
/// split that used to read it back cut a quoted path with a space into
/// three words — so every claude and codex hook on a machine whose install
/// path contains a space reported "script present but not registered",
/// forever, because the reinstall the report prescribed wrote the same
/// command back.
#[test]
fn a_quoted_path_round_trips_through_the_command_vstack_writes() {
    for script in [
        "/home/my user/.claude/hooks/guard.sh",
        "/home/o'brien/.claude/hooks/guard.sh",
        "/srv/a b/c d/hooks/guard.sh",
        // Control: the plain path `shell_quote` leaves unquoted.
        "/home/user/.claude/hooks/guard.sh",
    ] {
        let command = format!("bash {}", shell_quote(script));
        assert!(targets(&command, script), "{command}");
        // …and it is still THIS script, not any other.
        assert!(
            !targets(&command, "/home/user/.claude/hooks/other.sh"),
            "{command}"
        );
    }
}

/// Quoting decides word boundaries, so the same characters mean different
/// things in and out of quotes.
#[test]
fn words_are_split_the_way_a_shell_splits_them() {
    for (command, expected) in [
        ("bash /a/b.sh", vec!["bash", "/a/b.sh"]),
        ("  bash   /a/b.sh  ", vec!["bash", "/a/b.sh"]),
        ("bash '/a b/c.sh'", vec!["bash", "/a b/c.sh"]),
        ("bash \"/a b/c.sh\"", vec!["bash", "/a b/c.sh"]),
        ("bash /a\\ b/c.sh", vec!["bash", "/a b/c.sh"]),
        // Adjacent quoted and bare runs are ONE word.
        ("bash /a' b'/c.sh", vec!["bash", "/a b/c.sh"]),
        // An empty quoted word is a word.
        ("bash ''", vec!["bash", ""]),
        // Operators are ordinary characters inside quotes.
        ("bash '/a;b|c/d.sh'", vec!["bash", "/a;b|c/d.sh"]),
        ("bash \"/a*b/c.sh\"", vec!["bash", "/a*b/c.sh"]),
        // A backslash escapes only the four characters that need it
        // inside double quotes, and stands for itself before the rest.
        ("bash \"/a\\\"b/c.sh\"", vec!["bash", "/a\"b/c.sh"]),
        ("bash \"/a\\nb/c.sh\"", vec!["bash", "/a\\nb/c.sh"]),
    ] {
        assert_eq!(
            shell_words(command),
            Some(expected.iter().map(|s| s.to_string()).collect::<Vec<_>>()),
            "{command}"
        );
    }
}

/// A line whose words cannot be settled is refused outright, so no caller
/// can read a half-parsed command as a registration.
#[test]
fn a_command_that_cannot_be_settled_is_refused_not_guessed() {
    for command in [
        // Unterminated quoting.
        "bash '/a/b.sh",
        "bash \"/a/b.sh",
        "bash /a/b.sh\\",
        // Expansions and substitutions.
        "bash $HOOK/guard.sh",
        "bash \"$HOOK/guard.sh\"",
        "bash `which guard.sh`",
        "bash \"$(dirname x)/guard.sh\"",
        // More than one simple command, or output going elsewhere.
        "bash /a/b.sh; rm -rf /",
        "bash /a/b.sh | tee log",
        "bash /a/b.sh && other",
        "bash /a/b.sh > out",
        "(bash /a/b.sh)",
        // Pathname expansion this cannot resolve without the filesystem.
        "bash /a/*/guard.sh",
        "bash /a/guard?.sh",
    ] {
        assert_eq!(shell_words(command), None, "{command}");
        assert!(!targets(command, "/a/b.sh"), "{command}");
    }
}

/// The deferred placeholder is expanded BEFORE the split, so the one
/// substitution vstack itself writes is the only one that survives.
#[test]
fn the_deferred_root_placeholder_is_expanded_before_the_split() {
    let root = Path::new("/srv/my project");
    let script = root.join(".claude/hooks/guard.sh");
    let command = "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/guard.sh\"";
    assert!(command_targets_hook_script(
        command,
        &script,
        Some(("$CLAUDE_PROJECT_DIR", root))
    ));
    // Without the expansion the `$` is an expansion like any other.
    assert!(!command_targets_hook_script(command, &script, None));
}

/// An option one exec prefix defines is not an option the others ignore.
/// `nohup` and `setsid` take no option that leaves a command to run —
/// `nohup --foreground` exits 125, `setsid --preserve-status` the same — so a
/// registration spelled that way runs the hook never, and reading it as
/// registered was the fail-open the executable-position rule exists to close.
#[test]
fn an_option_a_prefix_does_not_define_means_the_script_never_runs() {
    let script = "/home/user/.claude/hooks/guard.sh";
    for command in [
        // The reported pair: both flags belong to `timeout` alone.
        "nohup --foreground /home/user/.claude/hooks/guard.sh",
        "setsid --preserve-status /home/user/.claude/hooks/guard.sh",
        // nohup's own options print and exit instead of running anything.
        "nohup --help /home/user/.claude/hooks/guard.sh",
        "nohup --version /home/user/.claude/hooks/guard.sh",
        // Nor do they become real by crossing to another prefix.
        "timeout --ctty 30 /home/user/.claude/hooks/guard.sh",
        "setsid --kill-after=5 /home/user/.claude/hooks/guard.sh",
        // `env` builds the command out of this one's value.
        "env --split-string=x /home/user/.claude/hooks/guard.sh",
        // An option one implementation grew and another rejects execs
        // nothing where it is not defined.
        "env --chdir=/tmp /home/user/.claude/hooks/guard.sh",
        // An option whose value is optional leaves nothing able to say
        // whether the next word is its value or the command.
        "env --block-signal /home/user/.claude/hooks/guard.sh",
        // A value flag with nothing following it runs nothing.
        "timeout -k",
    ] {
        assert!(!targets(command, script), "{command}");
    }
}

/// The options each prefix DOES define still resolve to the script, so the
/// rule costs no true registration — including the plain command vstack
/// writes itself.
#[test]
fn every_option_a_prefix_defines_still_reaches_the_script() {
    let script = "/home/user/.claude/hooks/guard.sh";
    for command in [
        // Control: what vstack renders, and its bare-path twin.
        "bash /home/user/.claude/hooks/guard.sh",
        "/home/user/.claude/hooks/guard.sh",
        // Control: no options at all.
        "nohup /home/user/.claude/hooks/guard.sh",
        "setsid /home/user/.claude/hooks/guard.sh",
        "nohup setsid bash /home/user/.claude/hooks/guard.sh",
        // Control: the flags are real on the prefix that defines them.
        "timeout --preserve-status 30 /home/user/.claude/hooks/guard.sh",
        "timeout --foreground 30 bash /home/user/.claude/hooks/guard.sh",
        "timeout -k 5 30 /home/user/.claude/hooks/guard.sh",
        "timeout --kill-after=5 -s TERM 30 /home/user/.claude/hooks/guard.sh",
        "setsid -f -w /home/user/.claude/hooks/guard.sh",
        "setsid --fork --ctty bash /home/user/.claude/hooks/guard.sh",
        // `env` keeps its assignment run and the options that still exec.
        "env FOO=bar bash /home/user/.claude/hooks/guard.sh",
        "env -i -u FOO bash /home/user/.claude/hooks/guard.sh",
        "env --unset=FOO /home/user/.claude/hooks/guard.sh",
        "env -- /home/user/.claude/hooks/guard.sh",
    ] {
        assert!(targets(command, script), "{command}");
        // …and it is still THIS script, not any other.
        assert!(
            !targets(command, "/home/user/.claude/hooks/other.sh"),
            "{command}"
        );
    }
}
