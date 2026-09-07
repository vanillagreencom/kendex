use super::*;

fn remote(repo: &str, rev: Option<&str>) -> SourceRef {
    SourceRef::Remote {
        repo: repo.into(),
        rev: rev.map(str::to_owned),
    }
}

fn tree(repo: &str, ref_and_path: &str) -> SourceRef {
    SourceRef::Tree {
        repo: repo.into(),
        ref_and_path: ref_and_path.into(),
    }
}

/// The refusal as the pair that tells it apart: the reference it was
/// asked about (trimmed, the spelling the person sees back) and the
/// reason this module composed.
fn refused<T: std::fmt::Debug>(result: Result<T>) -> (String, String) {
    match result {
        Err(CoreError::SourceRefInvalid { reference, reason }) => (reference, reason),
        other => panic!("expected a refused reference, got {other:?}"),
    }
}

/// Every spelling a typed reference accepts, one row per shape, and
/// what it parses to. Shorthand with and without a revision; full remote
/// URLs kept as typed (the `add.rs:318`-era heuristic read every URL as a
/// folder path); GitHub `https` URLs normalized to shorthand; paths,
/// including one holding an `@`, which is not a revision split because
/// what precedes it is not repository-shaped; tree URLs naming the whole
/// repository with ref and path kept joined; a skills.sh URL as the
/// repository plus the package; and one decode of a percent escape, so
/// `%252F` is the literal text `%2F` and never a separator.
#[test]
fn every_accepted_spelling_parses_to_its_reference() {
    let rows = [
        ("owner/repo", remote("owner/repo", None)),
        ("owner/repo@v1.2.0", remote("owner/repo", Some("v1.2.0"))),
        (
            "https://gitlab.com/team/catalog",
            remote("https://gitlab.com/team/catalog", None),
        ),
        (
            "http://git.example.com/team/catalog.git",
            remote("http://git.example.com/team/catalog.git", None),
        ),
        (
            "ssh://git@example.com/team/catalog.git",
            remote("ssh://git@example.com/team/catalog.git", None),
        ),
        (
            "git@example.com:team/catalog.git",
            remote("git@example.com:team/catalog.git", None),
        ),
        ("https://github.com/owner/repo", remote("owner/repo", None)),
        (
            "https://github.com/owner/repo.git",
            remote("owner/repo", None),
        ),
        (
            "https://www.github.com/owner/repo/",
            remote("owner/repo", None),
        ),
        ("http://github.com/owner/repo", remote("owner/repo", None)),
        (
            "./catalog",
            SourceRef::Path {
                path: "./catalog".into(),
            },
        ),
        (
            "/abs/catalog",
            SourceRef::Path {
                path: "/abs/catalog".into(),
            },
        ),
        (
            "~/catalog",
            SourceRef::Path {
                path: "~/catalog".into(),
            },
        ),
        (
            "../my@catalog",
            SourceRef::Path {
                path: "../my@catalog".into(),
            },
        ),
        (
            "a/b/c",
            SourceRef::Path {
                path: "a/b/c".into(),
            },
        ),
        (
            "https://github.com/o/r/tree/feat/x/skills/gh",
            tree("o/r", "feat/x/skills/gh"),
        ),
        ("https://github.com/o/r/tree/main", tree("o/r", "main")),
        (
            "https://github.com/o/r/tree/main/a%252Fb",
            tree("o/r", "main/a%2Fb"),
        ),
        (
            "https://skills.sh/vercel-labs/agent-skills/react-best-practices",
            SourceRef::SkillsSh {
                repo: "vercel-labs/agent-skills".into(),
                package: "react-best-practices".into(),
            },
        ),
    ];
    for (reference, parsed) in rows {
        assert_eq!(parse_typed(reference).unwrap(), parsed, "{reference}");
    }
}

/// Every spelling a typed reference refuses, one row per reason, refused
/// rather than reinterpreted. A `%2F` would move a path boundary after
/// decoding, so an encoded separator is refused wherever it sits, and a
/// bad escape is refused as one.
#[test]
fn every_hostile_spelling_is_refused_with_its_reason() {
    let rows = [
        ("", "empty reference"),
        ("-owner/repo", "a reference cannot start with '-'"),
        ("--upload-pack=x", "a reference cannot start with '-'"),
        ("owner/..", "'..' is not part of any repository name"),
        ("owner/re..po", "'..' is not part of any repository name"),
        (
            "https://github.com/o/r/tree/",
            "tree URL names no branch or tag",
        ),
        (
            "https://github.com/o/r/tree/../main",
            "'..' is not part of any repository name",
        ),
        (
            "https://github.com/o/r/blob/main/x.md",
            "not a repository or tree URL — expected github.com/owner/repo or …/tree/<ref>/<path>",
        ),
        (
            "https://example.com/a/../b",
            "'..' is not part of any repository URL",
        ),
        (
            "https://github.com/o/r/tree/main%2Fnested",
            "'main%2Fnested': encoded separator — spell the path with real slashes",
        ),
        (
            "https://github.com/o%2Fr/x/tree/main",
            "'o%2Fr': encoded separator — spell the path with real slashes",
        ),
        (
            "https://skills.sh/o/r/pkg%2f..",
            "'pkg%2f..': encoded separator — spell the path with real slashes",
        ),
        (
            "https://github.com/o/r/tree/main/%zz",
            "'%zz': invalid percent escape",
        ),
        (
            "https://skills.sh/vercel-labs/agent-skills",
            "not a skills.sh package URL — expected skills.sh/owner/repo/skill",
        ),
    ];
    for (reference, reason) in rows {
        assert_eq!(
            refused(parse_typed(reference)),
            (reference.to_owned(), reason.to_owned()),
            "{reference:?}"
        );
    }
}

/// The untrusted channel takes GitHub `https` URLs and shorthand and
/// nothing else, one row per door it closes.
#[test]
fn the_untrusted_validator_is_github_only() {
    assert_eq!(
        parse_untrusted("owner/repo").unwrap(),
        remote("owner/repo", None)
    );
    assert_eq!(
        parse_untrusted("https://github.com/owner/repo.git").unwrap(),
        remote("owner/repo", None)
    );
    let elsewhere = "only https://github.com URLs or owner/repo are accepted from this channel";
    let rows = [
        (
            "https://gitlab.com/owner/repo",
            "only github.com is accepted from this channel",
        ),
        (
            "https://skills.sh/o/r/x",
            "only github.com is accepted from this channel",
        ),
        ("http://github.com/owner/repo", elsewhere),
        ("git@github.com:owner/repo.git", elsewhere),
        ("ssh://git@github.com/owner/repo", elsewhere),
        ("./catalog", elsewhere),
        ("/abs/path", elsewhere),
        ("owner/repo$x", "'repo$x' is not a GitHub name"),
        (
            "owner/repo@re..v",
            "'..' is not part of any repository name",
        ),
    ];
    for (reference, reason) in rows {
        assert_eq!(
            refused(parse_untrusted(reference)),
            (reference.to_owned(), reason.to_owned()),
            "{reference:?}"
        );
    }
}

#[test]
fn repo_identity_folds_git_suffix_and_case() {
    let id = repo_identity("owner/repo");
    assert_eq!(repo_identity("https://github.com/Owner/Repo.git"), id);
    assert_eq!(repo_identity("git@github.com:owner/repo"), id);
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

/// A tree ref splits where the one matching ref says: the longest
/// prefix that names a known branch or tag, the rest the path, or no
/// path where the whole text is the ref.
#[test]
fn a_tree_ref_splits_where_the_one_matching_ref_says() {
    let refs = [branch("main"), branch("feat/x"), tag("v1")];
    assert_eq!(
        split_tree_ref("url", &refs, "feat/x/skills/gh").unwrap(),
        TreeSplit {
            kind: RefKind::Branch,
            reference: "feat/x".into(),
            path: Some("skills/gh".into()),
        }
    );
    assert_eq!(
        split_tree_ref("url", &refs, "v1").unwrap(),
        TreeSplit {
            kind: RefKind::Tag,
            reference: "v1".into(),
            path: None,
        }
    );
}

/// No matching ref, two valid split points, or a branch and a tag
/// sharing a name: refused naming every candidate, never string-split
/// and guessed.
#[test]
fn a_tree_ref_no_one_ref_claims_is_refused_naming_the_candidates() {
    let rows = [
        (
            vec![branch("main"), branch("feat/x"), tag("v1")],
            "gone/skills",
            "no branch or tag in the repository matches 'gone/skills'",
        ),
        (
            vec![branch("a"), branch("a/b")],
            "a/b/skills",
            "ambiguous ref — could be branch 'a/b' or branch 'a'",
        ),
        (
            vec![branch("v1"), tag("v1")],
            "v1/skills/gh",
            "ambiguous ref — could be branch 'v1' or tag 'v1'",
        ),
    ];
    for (refs, ref_and_path, reason) in rows {
        assert_eq!(
            refused(split_tree_ref("url", &refs, ref_and_path)),
            ("url".to_owned(), reason.to_owned()),
            "{ref_and_path}"
        );
    }
}
