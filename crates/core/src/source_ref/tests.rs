use super::*;

fn typed(reference: &str) -> SourceRef {
    parse_typed(reference).unwrap()
}

#[test]
fn shorthand_and_revision_parse_as_a_remote() {
    assert_eq!(
        typed("owner/repo"),
        SourceRef::Remote {
            repo: "owner/repo".into(),
            rev: None
        }
    );
    assert_eq!(
        typed("owner/repo@v1.2.0"),
        SourceRef::Remote {
            repo: "owner/repo".into(),
            rev: Some("v1.2.0".into())
        }
    );
}

/// The `add.rs:318`-era heuristic read every URL as a folder path.
#[test]
fn full_remote_urls_are_remotes_not_paths() {
    for url in [
        "https://gitlab.com/team/catalog",
        "http://git.example.com/team/catalog.git",
        "ssh://git@example.com/team/catalog.git",
        "git@example.com:team/catalog.git",
    ] {
        assert_eq!(
            typed(url),
            SourceRef::Remote {
                repo: url.into(),
                rev: None
            },
            "{url}"
        );
    }
}

#[test]
fn github_https_urls_normalize_to_shorthand() {
    for url in [
        "https://github.com/owner/repo",
        "https://github.com/owner/repo.git",
        "https://www.github.com/owner/repo/",
        "http://github.com/owner/repo",
    ] {
        assert_eq!(
            typed(url),
            SourceRef::Remote {
                repo: "owner/repo".into(),
                rev: None
            },
            "{url}"
        );
    }
}

#[test]
fn paths_stay_paths_including_an_at_sign() {
    for path in [
        "./catalog",
        "/abs/catalog",
        "~/catalog",
        "../my@catalog",
        "a/b/c",
    ] {
        assert_eq!(typed(path), SourceRef::Path { path: path.into() }, "{path}");
    }
}

#[test]
fn a_tree_url_names_the_whole_repo_and_keeps_ref_and_path_joined() {
    assert_eq!(
        typed("https://github.com/o/r/tree/feat/x/skills/gh"),
        SourceRef::Tree {
            repo: "o/r".into(),
            ref_and_path: "feat/x/skills/gh".into()
        }
    );
    assert_eq!(
        typed("https://github.com/o/r/tree/main"),
        SourceRef::Tree {
            repo: "o/r".into(),
            ref_and_path: "main".into()
        }
    );
}

#[test]
fn a_skills_sh_url_is_the_repo_plus_the_package_lead() {
    assert_eq!(
        typed("https://skills.sh/vercel-labs/agent-skills/react-best-practices"),
        SourceRef::SkillsSh {
            repo: "vercel-labs/agent-skills".into(),
            package: "react-best-practices".into()
        }
    );
    assert!(parse_typed("https://skills.sh/vercel-labs/agent-skills").is_err());
}

#[test]
fn hostile_spellings_are_refused_not_reinterpreted() {
    for bad in [
        "",
        "-owner/repo",
        "--upload-pack=x",
        "owner/..",
        "owner/re..po",
    ] {
        assert!(parse_typed(bad).is_err(), "{bad:?}");
    }
    assert!(parse_typed("https://github.com/o/r/tree/").is_err());
    assert!(parse_typed("https://github.com/o/r/tree/../main").is_err());
    assert!(parse_typed("https://github.com/o/r/blob/main/x.md").is_err());
    assert!(parse_typed("https://example.com/a/../b").is_err());
}

/// A `%2F` would move a path boundary after decoding; it is refused,
/// and decoding happens exactly once — a double-encoded separator
/// stays the literal text it decoded to.
#[test]
fn encoded_separators_are_refused() {
    assert!(parse_typed("https://github.com/o/r/tree/main%2Fnested").is_err());
    assert!(parse_typed("https://github.com/o%2Fr/x/tree/main").is_err());
    assert!(parse_typed("https://skills.sh/o/r/pkg%2f..").is_err());
    assert!(parse_typed("https://github.com/o/r/tree/main/%zz").is_err());
    // One decode: %252F is the literal text "%2F", not a separator.
    assert_eq!(
        typed("https://github.com/o/r/tree/main/a%252Fb"),
        SourceRef::Tree {
            repo: "o/r".into(),
            ref_and_path: "main/a%2Fb".into()
        }
    );
}

#[test]
fn the_untrusted_validator_is_github_only() {
    assert_eq!(
        parse_untrusted("owner/repo").unwrap(),
        SourceRef::Remote {
            repo: "owner/repo".into(),
            rev: None
        }
    );
    assert_eq!(
        parse_untrusted("https://github.com/owner/repo.git").unwrap(),
        SourceRef::Remote {
            repo: "owner/repo".into(),
            rev: None
        }
    );
    for bad in [
        "https://gitlab.com/owner/repo",
        "https://skills.sh/o/r/x",
        "http://github.com/owner/repo",
        "git@github.com:owner/repo.git",
        "ssh://git@github.com/owner/repo",
        "./catalog",
        "/abs/path",
        "owner/repo$x",
        "owner/repo@re..v",
    ] {
        assert!(parse_untrusted(bad).is_err(), "{bad:?}");
    }
}

#[test]
fn repo_identity_folds_git_suffix_case_and_the_moved_default() {
    let id = repo_identity("owner/repo");
    assert_eq!(repo_identity("https://github.com/Owner/Repo.git"), id);
    assert_eq!(repo_identity("git@github.com:owner/repo"), id);
    assert_eq!(
        repo_identity("vanillagreencom/vstack"),
        repo_identity("vanillagreencom/kendex")
    );
    assert_ne!(repo_identity("owner/other"), id);
    assert_ne!(repo_identity("https://gitlab.com/owner/repo"), id);
    assert_eq!(
        repo_identity("https://gitlab.com/team/catalog.git"),
        repo_identity("https://gitlab.com/team/catalog/")
    );
}

/// Scheme and host fold; on a host that is not GitHub the path keeps its
/// case, because `Team/catalog` and `team/catalog` can be two repositories
/// there — the same distinction the mirror store draws.
#[test]
fn repo_identity_keeps_path_case_off_github() {
    assert_eq!(
        repo_identity("HTTPS://GitLab.com/team/catalog"),
        repo_identity("https://gitlab.com/team/catalog")
    );
    assert_ne!(
        repo_identity("https://git.example/Team/catalog"),
        repo_identity("https://git.example/team/catalog")
    );
    assert_ne!(
        repo_identity("git@git.example:Team/catalog.git"),
        repo_identity("git@git.example:team/catalog")
    );
    assert_eq!(
        repo_identity("Git@Git.Example:team/catalog.git"),
        repo_identity("git@git.example:team/catalog")
    );
    assert_eq!(
        repo_identity("https://github.com/Owner/Repo"),
        repo_identity("https://github.com/owner/repo")
    );
}

fn branch(name: &str) -> MirrorRef {
    MirrorRef {
        kind: RefKind::Branch,
        name: name.into(),
    }
}

fn tag(name: &str) -> MirrorRef {
    MirrorRef {
        kind: RefKind::Tag,
        name: name.into(),
    }
}

#[test]
fn a_tree_ref_splits_where_the_one_matching_ref_says() {
    let refs = [branch("main"), branch("feat/x"), tag("v1")];
    let split = split_tree_ref("url", &refs, "feat/x/skills/gh").unwrap();
    assert_eq!(split.reference, "feat/x");
    assert_eq!(split.kind, RefKind::Branch);
    assert_eq!(split.path.as_deref(), Some("skills/gh"));

    let split = split_tree_ref("url", &refs, "v1").unwrap();
    assert_eq!(split.kind, RefKind::Tag);
    assert_eq!(split.path, None);

    let error = split_tree_ref("url", &refs, "gone/skills").unwrap_err();
    assert!(error.to_string().contains("no branch or tag"), "{error}");
}

/// Two valid split points, or a branch and tag sharing a name, are
/// refused naming every candidate — never string-split and guessed.
#[test]
fn an_ambiguous_tree_ref_is_refused_naming_both() {
    let refs = [branch("a"), branch("a/b")];
    let error = split_tree_ref("url", &refs, "a/b/skills").unwrap_err();
    let text = error.to_string();
    assert!(text.contains("branch 'a'"), "{text}");
    assert!(text.contains("branch 'a/b'"), "{text}");

    let refs = [branch("v1"), tag("v1")];
    let error = split_tree_ref("url", &refs, "v1/skills/gh").unwrap_err();
    let text = error.to_string();
    assert!(text.contains("branch 'v1'"), "{text}");
    assert!(text.contains("tag 'v1'"), "{text}");
}
