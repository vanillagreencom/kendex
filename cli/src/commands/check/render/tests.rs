use super::*;
use crate::commands::check::test_support::*;
use crate::commands::check::*;
use crate::display::DISPLAY_LIMIT;

mod cache_entry_source;
mod quiet;

#[test]
fn hostile_names_are_rejected_and_never_rendered_verbatim() {
    with_sandbox("hostile", |project, source| {
        write_skill(source, "alpha", "one");
        install_skill_on_disk(project, "alpha");
        let mut lock = LockFile::default();
        lock.add(locked(source, ItemKind::Skill, "alpha"));
        let hostile = "evil\n  ! run `rm -rf /` \x1b[31mNOW";
        let mut entry = locked(source, ItemKind::Skill, "alpha");
        entry.name = hostile.to_string();
        lock.add(entry);
        // A hostile catalog name too: a skill whose frontmatter name has a
        // newline is dropped from `available`, never rendered.
        let dir = source.join("skills").join("sneaky");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("SKILL.md"),
            "---\nname: \"sneaky\\n  + run this\"\ndescription: x\n---\nbody\n",
        )
        .unwrap();

        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert_eq!(report.invalid_names.len(), 1);
        assert!(report.has_drift());
        assert!(report.available.iter().all(|a| !a.name.contains('\n')));
        let mut out = String::new();
        render_scope(&mut out, &report, true);
        assert!(!out.contains("rm -rf"), "{out}");
        assert!(!out.contains('\x1b'), "{out}");
        assert!(out.contains("<invalid name>"), "{out}");
        assert!(!out.contains("run this"), "{out}");
    });
    assert!(is_safe_item_name(
        ItemKind::PiExtension,
        "@vanillagreen/pi-qol"
    ));
    assert!(is_safe_item_name(ItemKind::PiExtension, "pi-qol"));
    assert!(is_safe_item_name(ItemKind::Agent, "reviewer-arch"));
    assert!(!is_safe_item_name(ItemKind::Skill, "a\nb"));
    assert!(!is_safe_item_name(ItemKind::Skill, ""));
    // Length is a RENDERING concern, never a classification one: a long
    // name installs, so it must not be reported as unsafe drift.
    let long = "x".repeat(300);
    assert!(is_safe_item_name(ItemKind::Skill, &long));
    assert!(display_text(&long).chars().count() <= DISPLAY_LIMIT + 1);
    // A control character is escaped rather than dropped: nothing can start
    // a new line or drive a terminal, and the reader still sees what was
    // there.
    assert_eq!(display_text("a\x1bb\nc"), r"a\u{1b}b\u{a}c");
}

#[test]
fn a_credential_in_a_source_url_is_never_rendered_into_the_report() {
    // A token in a source string would otherwise land in an agent's
    // context and every transcript that quotes it.
    assert_eq!(
        display_text("https://user:ghp_secret@github.com/owner/repo"),
        "https://user:<redacted>@github.com/owner/repo"
    );
    // A bare https user field is where tokens live too.
    assert_eq!(
        display_text("https://ghp_secret@github.com/owner/repo"),
        "https://<redacted>@github.com/owner/repo"
    );
    // A query string carries them as well.
    assert_eq!(
        display_text("https://github.com/owner/repo?access_token=ghp_secret"),
        "https://github.com/owner/repo?<redacted>"
    );
    // ssh KEEPS its user — `git@` picks the key, it is not a secret, and
    // a remedy command without it dies on publickey — while a password
    // still goes.
    assert_eq!(
        display_text("ssh://git@example.com/owner/repo"),
        "ssh://git@example.com/owner/repo"
    );
    assert_eq!(
        display_text("ssh://git:hunter2@example.com/owner/repo"),
        "ssh://git:<redacted>@example.com/owner/repo"
    );
    // scp-style: same rule, schemeless.
    assert_eq!(
        display_text("git@github.com:owner/repo"),
        "git@github.com:owner/repo"
    );
    assert_eq!(
        display_text("git:hunter2@github.com:owner/repo"),
        "git:<redacted>@github.com:owner/repo"
    );
    // Controls: a URL carrying no secret is untouched, so a remedy command
    // built from it still pastes.
    assert_eq!(
        display_text("https://github.com/owner/repo"),
        "https://github.com/owner/repo"
    );
    // A stray `@` outside the authority is redacted rather than trusted: a
    // URL malformed enough to put a token there is exactly the shape a
    // permissive reading leaks.
    assert_eq!(
        display_text("https://github.com/owner/re@po"),
        "https://github.com/owner/<redacted>@po"
    );
    assert_eq!(display_text("/local/path"), "/local/path");
    assert_eq!(display_text("owner/repo"), "owner/repo");
}

#[test]
fn a_command_argument_is_never_truncated_and_quotes_whitespace() {
    // A remedy command built from an elided or unquoted string cannot be
    // pasted; prose may truncate, commands may not.
    let long = format!("/sources/{}", "x".repeat(200));
    assert!(display_text(&long).ends_with('…'), "prose truncates");
    assert_eq!(command_arg(&long), long, "commands never truncate");
    assert_eq!(
        command_arg("/sources/my repos/vstack"),
        "'/sources/my repos/vstack'"
    );
    assert_eq!(
        command_arg("ssh://git@example.com/owner/repo"),
        "ssh://git@example.com/owner/repo"
    );
}

#[test]
fn a_long_missing_skill_name_truncates_in_prose_but_not_in_the_command() {
    let long = "s".repeat(DISPLAY_LIMIT + 40);
    let report = CheckReport {
        version: 1,
        cli_version: "0.0.0",
        cli_hash: "abc",
        drift: true,
        background_refresh_error: None,
        cache_refresh_failures: Vec::new(),
        scopes: vec![ScopeReport {
            scope: "project",
            missing_skill_refs: vec![MissingSkillRef {
                agent: "rust".into(),
                skill: long.clone(),
            }],
            ..ScopeReport::default()
        }],
    };
    let out = render_report(&report, false);
    assert!(
        out.contains(&format!("references skill {}…", "s".repeat(DISPLAY_LIMIT))),
        "prose truncates: {out}"
    );
    assert!(
        out.contains(&format!("vstack add --skill {long} .")),
        "the pasted command must carry the whole name: {out}"
    );
}

#[test]
fn a_command_argument_quotes_every_shell_metacharacter() {
    // Plain slugs and URLs stay bare — quoting everything would make the
    // common line noisier for no gain.
    assert_eq!(command_arg("owner/repo"), "owner/repo");
    assert_eq!(command_arg("~/sources/vstack"), "'~/sources/vstack'");

    // Anything the shell would interpret is neutralised by single quotes.
    assert_eq!(command_arg("/src/say\"hi\""), "'/src/say\"hi\"'");
    assert_eq!(command_arg("/src/$VAR/repo"), "'/src/$VAR/repo'");
    assert_eq!(command_arg("/src/`id`/repo"), "'/src/`id`/repo'");
    assert_eq!(command_arg("/src/back\\slash"), "'/src/back\\slash'");
    assert_eq!(command_arg("/src/a;rm -rf b"), "'/src/a;rm -rf b'");

    // The one character single quotes cannot hold is spliced, so the
    // shell still sees exactly one argument.
    assert_eq!(command_arg("/src/it's/repo"), r"'/src/it'\''s/repo'");

    // An empty source still has to render as an argument, not vanish.
    assert_eq!(command_arg(""), "''");
}

#[test]
fn a_quoted_command_argument_survives_a_real_shell() {
    // Round-tripping through a real shell is the only proof that a
    // rendered argument pastes as the literal source and not as some
    // other command.
    for raw in [
        "/sources/my repos/vstack",
        "/src/say\"hi\"",
        "/src/$VAR/repo",
        "/src/`id`/repo",
        "/src/back\\slash",
        "/src/it's/repo",
        "/src/a;rm -rf b",
        "owner/repo",
        "",
    ] {
        let arg = command_arg(raw);
        let out = std::process::Command::new("sh")
            .arg("-c")
            .arg(format!("printf '%s' {arg}"))
            .output()
            .expect("sh runs");
        assert!(out.status.success(), "sh parsed {arg}");
        assert_eq!(
            String::from_utf8_lossy(&out.stdout),
            raw,
            "{arg} must expand back to the literal source"
        );
    }
}

#[test]
fn an_unverifiable_cache_is_reported_with_its_own_remedy() {
    with_sandbox("unverifiable-source", |project, _source| {
        // Somebody else's clone sitting at this source's cache key.
        let cache = clone_at_cache_key("owner/repo", "https://github.com/other/repo.git");
        install_skill_on_disk(project, "alpha");
        let mut lock = LockFile::default();
        let mut entry = locked(&cache, ItemKind::Skill, "alpha");
        entry.source = "owner/repo".into();
        lock.add(entry);

        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert_eq!(report.source_issues.len(), 1, "{report:?}");
        assert!(
            matches!(
                &report.source_issues[0].problem,
                SourceProblem::Unverifiable { entries, reason }
                    if entries == &vec!["alpha".to_string()]
                        && reason.contains("other/repo")
            ),
            "{report:?}"
        );
        let mut out = String::new();
        render_scope(&mut out, &report, true);
        // The refusal's own remedy is relayed verbatim, and no second one
        // is invented: `vstack add` on a refused source refuses again.
        assert!(out.contains("cannot be verified"), "{out}");
        assert!(out.contains("Remove its cache entry"), "{out}");
        assert!(
            !out.contains("is unreachable"),
            "the wrong remedy must not appear: {out}"
        );
        assert!(
            !out.contains("vstack add"),
            "re-adding a refused source sends the user in a circle: {out}"
        );
    });
}

/// One scope report with every section that renders a remediation command
/// populated, so a command missing its scope flag cannot hide in a section
/// the fixture forgot.
fn populated_scope(scope: &'static str) -> ScopeReport {
    ScopeReport {
        scope,
        installed: 1,
        outdated: vec![Item::new("alpha", ItemKind::Skill)],
        removed: vec![Item::new("beta", ItemKind::Skill)],
        orphaned: vec![Item::new("gamma", ItemKind::Skill)],
        phantom: vec![Item::new("delta", ItemKind::Agent)],
        unverifiable: vec![Item {
            detail: Some("registration unknown — Pi settings unreadable: broken".into()),
            ..Item::new("theta", ItemKind::PiExtension)
        }],
        disabled: vec![Item {
            detail: Some(
                "claude-code: hooks disabled for this scope — disableAllHooks is true in /home/settings.json".into(),
            ),
            ..Item::new("iota", ItemKind::Hook)
        }],
        missing_skill_refs: vec![MissingSkillRef {
            agent: "rust".into(),
            skill: "epsilon".into(),
        }],
        source_issues: vec![
            SourceIssue {
                source: "/sources/one".into(),
                problem: SourceProblem::Unresolvable {
                    entries: vec!["zeta".into()],
                    reason: "source not found".into(),
                    restore: Some("/sources/one".into()),
                },
            },
            SourceIssue {
                source: "/sources/two".into(),
                problem: SourceProblem::Unreadable {
                    entries: vec!["eta".into()],
                    reasons: vec!["no skills root".into()],
                },
            },
            SourceIssue {
                source: "/sources/three".into(),
                problem: SourceProblem::Unverifiable {
                    entries: vec!["theta".into()],
                    reason: "origin mismatch".into(),
                },
            },
            SourceIssue {
                source: "/sources/four".into(),
                problem: SourceProblem::Discovery {
                    failures: vec!["iota: bad frontmatter".into()],
                },
            },
        ],
        busy_sources: vec![BusySource {
            source: "/sources/five".into(),
            entries: vec!["nu".into()],
            reason: "another vstack process is refreshing this source's cache".into(),
        }],
        invalid_names: vec![Item::new("bad\nname", ItemKind::Hook)],
        git_hooks: Some(GitHooksStatus {
            state: GitHooksState::Unarmed,
            detail: "growth-guards git hooks: NOT armed — pre-commit is missing".into(),
        }),
        available: vec![
            AvailableItem {
                name: "kappa".into(),
                kind: ItemKind::Skill,
                source: "/sources/one".into(),
            },
            AvailableItem {
                name: "lambda".into(),
                kind: ItemKind::Agent,
                source: "/sources/one".into(),
            },
        ],
        current: vec![Item::new("mu", ItemKind::Skill)],
    }
}

/// Every `vstack <subcommand>` the report printed, paired with the token
/// that follows it, backticks trimmed.
fn rendered_commands(out: &str) -> Vec<(String, String)> {
    let trim = |word: &str| word.trim_matches('`').to_string();
    let mut found = Vec::new();
    let mut rest = out;
    while let Some(at) = rest.find("vstack ") {
        rest = &rest[at + "vstack ".len()..];
        let mut words = rest.split_whitespace();
        found.push((
            trim(words.next().unwrap_or_default()),
            trim(words.next().unwrap_or_default()),
        ));
    }
    found
}

/// `add` and `remove` default to PROJECT scope, so a global section's
/// remediation commands must carry `-g` or they act on the wrong install —
/// silently, when a project item shares the name. Asserted per command by
/// scanning the rendered report, so a command added to `render_scope` later
/// cannot silently miss the flag.
#[test]
fn every_global_remediation_command_carries_the_scope_flag() {
    for quiet in [false, true] {
        let mut global = String::new();
        render_scope(&mut global, &populated_scope("global"), quiet);
        let commands = rendered_commands(&global);
        let scoped: Vec<&(String, String)> = commands
            .iter()
            .filter(|(sub, _)| sub == "add" || sub == "remove")
            .collect();
        assert!(
            scoped.len() >= 10,
            "the fixture must reach every remediation command, saw {scoped:?} in:\n{global}"
        );
        for (sub, next) in &scoped {
            assert_eq!(
                next, "-g",
                "`vstack {sub}` ran unscoped in a global report:\n{global}"
            );
        }
        // `refresh` is correct unflagged: it reinstalls at every scope an
        // item is locked at.
        assert!(
            commands
                .iter()
                .any(|(sub, next)| sub == "refresh" && next != "-g"),
            "the outdated remedy must stay scope-less:\n{global}"
        );

        // Control: the project rendering carries no flag, and transforming
        // it into the global one takes nothing but the flag and the header,
        // so scope is the ONLY difference between the two.
        let mut project = String::new();
        render_scope(&mut project, &populated_scope("project"), quiet);
        assert!(
            !project.contains(" -g"),
            "the project report must stay unflagged:\n{project}"
        );
        assert_eq!(
            global,
            project
                .replace("vstack add", "vstack add -g")
                .replace("vstack remove", "vstack remove -g")
                .replace("project scope", "global scope"),
            "scope must change nothing but the flag and the header"
        );
    }
}

/// A local source is a PATH, not a URL: `?` and `#` are a query and a
/// fragment in one and ordinary characters in a directory name in the other.
/// The URL redaction was applied to every source, so a local path rendered as
/// `/sources/x?<redacted>` and both remedy commands built from it named a
/// directory that does not exist.
#[test]
fn a_local_source_path_survives_into_the_report_and_its_remedy_commands() {
    let dir = tmpdir("local?src#1");
    let source = dir.to_string_lossy().into_owned();
    let mut report = ScopeReport {
        scope: "project",
        installed: 1,
        ..Default::default()
    };
    report.source_issues.push(SourceIssue {
        source: scrub_source_credentials(&source),
        problem: SourceProblem::Unresolvable {
            entries: vec!["alpha".into()],
            reason: "source not found".into(),
            restore: Some(source.clone()),
        },
    });
    report.available.push(AvailableItem {
        name: "beta".into(),
        kind: ItemKind::Skill,
        source: scrub_source_credentials(&source),
    });

    let mut out = String::new();
    render_scope(&mut out, &report, false);
    assert!(
        !out.contains("<redacted>"),
        "a local path carries no credential to redact: {out}"
    );
    assert!(
        out.contains(&source),
        "the prose must name the real directory: {out}"
    );
    let arg = command_arg(&source);
    assert!(
        out.contains(&format!("`vstack add {arg}`")),
        "the unreachable-source remedy must name it too: {out}"
    );
    assert!(
        out.contains(&format!("`vstack add {arg} --skill <name>`")),
        "and so must the available-item remedy: {out}"
    );

    // The proof is the directory, not the string: the pasted argument has to
    // resolve to the one that is actually there.
    let probe = std::process::Command::new("sh")
        .arg("-c")
        .arg(format!("test -d {arg} && printf ok"))
        .output()
        .expect("sh runs");
    assert_eq!(
        String::from_utf8_lossy(&probe.stdout),
        "ok",
        "the pasted command must name the directory that exists, got {arg}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// A remedy command has to WORK when pasted: an ssh source keeps its
/// `git@` (the round-4 scrub dropped it and the suggested command died on
/// publickey), and a long local path is never truncated inside backticks.
#[test]
fn remedy_commands_are_pasteable_for_ssh_and_long_sources() {
    let ssh = "ssh://git@example.com/owner/repo";
    let mut report = ScopeReport {
        scope: "project",
        installed: 1,
        ..Default::default()
    };
    report.source_issues.push(SourceIssue {
        source: scrub_source_credentials(ssh),
        problem: SourceProblem::Unresolvable {
            entries: vec!["alpha".into()],
            reason: "source not found".into(),
            restore: Some(ssh.to_string()),
        },
    });
    let mut out = String::new();
    render_scope(&mut out, &report, true);
    assert!(
        out.contains("`vstack add ssh://git@example.com/owner/repo`"),
        "the command must keep the working ssh user: {out}"
    );

    let long = format!("/sources/{}", "x".repeat(200));
    let mut report = ScopeReport {
        scope: "project",
        installed: 1,
        ..Default::default()
    };
    report.source_issues.push(SourceIssue {
        source: long.clone(),
        problem: SourceProblem::Unresolvable {
            entries: vec!["alpha".into()],
            reason: "source not found".into(),
            restore: Some(long.clone()),
        },
    });
    let mut out = String::new();
    render_scope(&mut out, &report, true);
    assert!(
        out.contains(&format!("`vstack add {long}`")),
        "the command must carry the whole argument: {out}"
    );
}

/// A refresh that cannot even be spawned is worth a line, never an exit
/// code: it renders (alongside drift on the quiet path too), and the
/// drift computation does not take it as an input at all.
#[test]
fn a_background_refresh_error_is_reported_but_never_drift() {
    assert!(
        !computed_drift(&[], &[]),
        "nothing else wrong means clean, whatever the spawn did"
    );
    let report = CheckReport {
        version: 1,
        cli_version: "0.0.0",
        cli_hash: "abc",
        drift: computed_drift(&[], &[]),
        background_refresh_error: Some("spawn failed".into()),
        cache_refresh_failures: Vec::new(),
        scopes: Vec::new(),
    };
    assert_eq!(report.outcome(), CheckOutcome::Clean);
    let out = render_report(&report, false);
    assert!(
        out.contains("could not be refreshed in the background") && out.contains("spawn failed"),
        "{out}"
    );
    // Quiet + clean prints nothing: the quiet contract holds.
    assert_eq!(render_report(&report, true), "");

    // Alongside REAL drift the quiet path carries the line too.
    let drifted = ScopeReport {
        scope: "project",
        installed: 1,
        outdated: vec![Item::new("alpha", ItemKind::Skill)],
        ..Default::default()
    };
    let scopes = vec![drifted];
    let report = CheckReport {
        version: 1,
        cli_version: "0.0.0",
        cli_hash: "abc",
        drift: computed_drift(&scopes, &[]),
        background_refresh_error: Some("spawn failed".into()),
        cache_refresh_failures: Vec::new(),
        scopes,
    };
    assert_eq!(report.outcome(), CheckOutcome::Drift);
    let quiet = render_report(&report, true);
    assert!(quiet.contains("spawn failed"), "{quiet}");
}

/// `--json` goes to stdout and into CI logs verbatim: a token in a lock
/// source or in a cache-origin reason must be gone from the REPORT, not
/// just from the human rendering.
#[test]
fn json_serialization_carries_no_credentials() {
    with_sandbox("json-credentials", |project, _source| {
        // A lock written before the credential refusal records the URL
        // verbatim, token and all. Resolution refuses it, and the refusal is
        // one of the strings that lands in the report.
        let source = "https://user:ghp_supersecret@github.com/owner/repo";
        // …and a source that IS usable, whose cache entry was cloned with a
        // token in its origin — the ownership refusal quotes that origin.
        let cache = clone_at_cache_key(
            "owner/repo",
            "https://other:ghp_othersecret@github.com/owner/repo.git",
        );
        install_skill_on_disk(project, "alpha");
        install_skill_on_disk(project, "beta");
        let mut lock = LockFile::default();
        let mut entry = locked(&cache, ItemKind::Skill, "alpha");
        entry.source = source.into();
        lock.add(entry);
        let mut entry = locked(&cache, ItemKind::Skill, "beta");
        entry.source = "owner/repo".into();
        lock.add(entry);

        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert_eq!(report.source_issues.len(), 2, "{report:?}");
        let json = serde_json::to_string(&report).unwrap();
        assert!(
            !json.contains("ghp_supersecret") && !json.contains("ghp_othersecret"),
            "no token may reach any serialization: {json}"
        );
        assert!(
            json.contains("github.com/owner/repo"),
            "the host and path survive: {json}"
        );
    });
}

#[test]
fn a_traversal_name_lands_in_invalid_names_and_is_never_joined_into_a_path() {
    with_sandbox("traversal", |project, source| {
        write_skill(source, "alpha", "one");
        install_skill_on_disk(project, "alpha");
        let mut lock = LockFile::default();
        lock.add(locked(source, ItemKind::Skill, "alpha"));
        for hostile in ["../escape", "/tmp/escape", "a/b", "-escape"] {
            let mut entry = locked(source, ItemKind::Skill, "alpha");
            entry.name = hostile.to_string();
            lock.add(entry);
        }
        // A marker OUTSIDE the install root, at exactly the path a
        // traversal name would resolve to. Reading it would prove the
        // join happened; it must stay untouched and unreported.
        let escape = project.join(".agents").join("escape");
        std::fs::create_dir_all(escape.join("skills")).unwrap();
        std::fs::write(escape.join("SKILL.md"), "outside\n").unwrap();

        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        let rejected: Vec<&str> = report
            .invalid_names
            .iter()
            .map(|i| i.name.as_str())
            .collect();
        for hostile in ["../escape", "/tmp/escape", "a/b", "-escape"] {
            assert!(rejected.contains(&hostile), "{hostile}: {rejected:?}");
        }
        // Excluded from every other list, so nothing downstream joins them.
        for list in [
            &report.outdated,
            &report.removed,
            &report.phantom,
            &report.orphaned,
        ] {
            assert!(
                list.iter().all(|i| !rejected.contains(&i.name.as_str())),
                "{report:?}"
            );
        }
        assert!(report.has_drift());
        let mut out = String::new();
        render_scope(&mut out, &report, true);
        assert!(!out.contains("escape"), "never rendered verbatim: {out}");
        assert!(out.contains("<invalid name>"), "{out}");
    });
}

#[test]
fn an_agent_referencing_an_unsafe_skill_name_never_resolves_it() {
    with_sandbox("unsafe-ref", |project, source| {
        write_skill(source, "alpha", "one");
        install_skill_on_disk(project, "alpha");
        write_agent(source, "rust");
        let mut lock = LockFile::default();
        lock.add(locked(source, ItemKind::Skill, "alpha"));
        lock.add(locked(source, ItemKind::Agent, "rust"));
        let agents = project.join(".claude").join("agents");
        std::fs::create_dir_all(&agents).unwrap();
        std::fs::write(
            agents.join("rust.md"),
            "---\nname: rust\nskills: alpha, ../../etc/passwd\n---\nbody\n",
        )
        .unwrap();

        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(
            report
                .missing_skill_refs
                .iter()
                .all(|r| !r.skill.contains("..")),
            "a traversal reference must never become a suggested command: {report:?}"
        );
        assert!(
            report
                .invalid_names
                .iter()
                .any(|i| i.name == "../../etc/passwd"),
            "{report:?}"
        );
        let mut out = String::new();
        render_scope(&mut out, &report, true);
        assert!(!out.contains("passwd"), "{out}");
    });
}

#[test]
fn a_cache_that_has_been_failing_for_two_ttls_is_drift_the_hook_reports() {
    let failure = |persistent: bool| CheckReport {
        version: 1,
        cli_version: "0.0.0",
        cli_hash: "abc",
        drift: persistent,
        background_refresh_error: None,
        cache_refresh_failures: vec![CacheRefreshFailure {
            source: "owner/repo".into(),
            age_secs: 86_400,
            reason: "fetch has been failing for 24h (last attempt 1h ago)".into(),
            persistent,
        }],
        scopes: Vec::new(),
    };
    let stuck = failure(true);
    assert_eq!(stuck.outcome(), CheckOutcome::Drift);
    let quiet = render_report(&stuck, true);
    assert!(
        quiet.contains("owner/repo") && quiet.contains("failing for 24h"),
        "a permanently broken remote must speak in the quiet path: {quiet:?}"
    );
    // Control: the same failure while still transient stays silent.
    assert!(render_report(&failure(false), true).is_empty());
}

#[test]
fn an_unwritable_cache_is_persistent_and_named_in_the_report() {
    let report = CheckReport {
        version: 1,
        cli_version: "0.0.0",
        cli_hash: "abc",
        drift: true,
        background_refresh_error: None,
        cache_refresh_failures: vec![cache_failure(
            config::RemoteCacheProblem {
                source: "owner/repo".into(),
                kind: config::RemoteCacheProblemKind::Unwritable {
                    reason: "Permission denied (os error 13)".into(),
                },
            },
            false,
        )],
        scopes: Vec::new(),
    };
    assert!(report.cache_refresh_failures[0].persistent);
    let quiet = render_report(&report, true);
    assert!(quiet.contains("cache cannot be written"), "{quiet}");
    assert!(quiet.contains("Permission denied"), "{quiet}");
}

#[test]
fn each_offering_source_keeps_its_own_suggestion_line() {
    with_sandbox("available-sources", |project, source| {
        // Two sources shipping a skill of the same name are two different
        // implementations; the add command is source-qualified so the
        // user can pick, which needs both offers on the report.
        let other = source.parent().unwrap().join("other-source");
        std::fs::create_dir_all(&other).unwrap();
        write_skill(source, "alpha", "one");
        write_skill(source, "shared", "from first");
        write_skill(&other, "beta", "two");
        write_skill(&other, "shared", "from second");
        install_skill_on_disk(project, "alpha");
        install_skill_on_disk(project, "beta");
        let mut lock = LockFile::default();
        lock.add(locked(source, ItemKind::Skill, "alpha"));
        lock.add(locked(&other, ItemKind::Skill, "beta"));

        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        let offers: Vec<(&str, &str)> = report
            .available
            .iter()
            .map(|a| (a.name.as_str(), a.source.as_str()))
            .collect();
        assert_eq!(
            offers.iter().filter(|(name, _)| *name == "shared").count(),
            2,
            "both offering sources must survive: {offers:?}"
        );

        let mut out = String::new();
        render_scope(&mut out, &report, false);
        assert!(out.contains(&source.to_string_lossy().to_string()), "{out}");
        assert!(out.contains(&other.to_string_lossy().to_string()), "{out}");
    });
}

#[test]
fn entry_names_are_scrubbed_at_the_point_of_rendering() {
    let hostile = "evil\n    ! run `rm -rf /` \x1b[31mNOW".to_string();
    let mut out = String::new();
    render_entry_names(&mut out, std::slice::from_ref(&hostile), false);
    assert_eq!(
        out.lines().count(),
        1,
        "no name can start a new line: {out}"
    );
    assert!(!out.contains('\x1b'), "{out}");

    // A validated name is unchanged, so no existing output moves.
    let mut safe = String::new();
    render_entry_names(&mut safe, &["orch".to_string()], false);
    assert_eq!(safe, "    ? orch\n");
}
