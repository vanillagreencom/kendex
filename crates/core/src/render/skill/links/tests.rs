use std::path::{Path, PathBuf};

use super::*;

fn files(rel: &str, text: &str) -> Files {
    vec![(PathBuf::from(rel), text.as_bytes().to_vec())]
}

fn origin(directory: &Path, files: Files, siblings: Siblings) -> Origin {
    Origin {
        directory: directory.to_path_buf(),
        files,
        siblings,
        link_files: Vec::new(),
    }
}

/// One table of the link rules, read from an origin skill directory into a
/// destination one level deeper under the same bound.
#[test]
fn each_link_class_converts_or_keeps_its_bytes_by_the_one_rule_set() {
    let tmp = tempfile::tempdir().unwrap();
    let root = crate::test_util::rooted(&tmp);
    let catalog = root.join("catalog");
    std::fs::create_dir_all(catalog.join("skills/other")).unwrap();
    std::fs::write(catalog.join("skills/other/SKILL.md"), "Other.\n").unwrap();
    std::fs::create_dir_all(catalog.join("skills/loose")).unwrap();
    let sealed = SealedSource::open(&catalog).unwrap();
    let source = catalog.join("skills/ship");
    let destination = Position {
        directory: root.join("project/.agents/skills/ship"),
        bound: root.clone(),
    };
    let block = format!(
        "{}\n[managed](../../memory/x.md)\n{}\n",
        crate::render::skill::INSTRUCTIONS_START,
        crate::render::skill::INSTRUCTIONS_END
    );
    // (row, file, origin text, siblings, expected text, kept targets)
    type Row<'a> = (&'a str, &'a str, String, Siblings, String, Vec<&'a str>);
    let rows: Vec<Row<'_>> = vec![
        (
            "internal",
            "SKILL.md",
            "[guide](./guide%2Emd#a)\n".into(),
            Siblings::Unknown,
            "[guide](./guide%2Emd#a)\n".into(),
            vec![],
        ),
        (
            "sibling beside a skills directory",
            "SKILL.md",
            "[other](../other/SKILL.md)\n".into(),
            Siblings::SkillsDirectory,
            "[other](../other/SKILL.md)\n".into(),
            vec![],
        ),
        (
            "sibling beside a catalog with a package",
            "SKILL.md",
            "[other](../other/SKILL.md)\n".into(),
            Siblings::Catalog(sealed.clone()),
            "[other](../other/SKILL.md)\n".into(),
            vec![],
        ),
        (
            "directory beside a catalog without a package",
            "SKILL.md",
            "[loose](../loose/x.md)\n".into(),
            Siblings::Catalog(sealed.clone()),
            "[loose](../../../../catalog/skills/loose/x.md)\n".into(),
            vec![],
        ),
        (
            "loose file beside a skills directory",
            "SKILL.md",
            "[notes](../notes.md)\n".into(),
            Siblings::SkillsDirectory,
            "[notes](../../../../catalog/skills/notes.md)\n".into(),
            vec![],
        ),
        (
            "exiting link",
            "SKILL.md",
            "[memory](../../memory/x.md)\n".into(),
            Siblings::Unknown,
            "[memory](../../../../catalog/memory/x.md)\n".into(),
            vec![],
        ),
        (
            "nested file",
            "references/read.md",
            "[memory](../../../memory/x.md)\n".into(),
            Siblings::Unknown,
            "[memory](../../../../../catalog/memory/x.md)\n".into(),
            vec![],
        ),
        (
            "text file of another extension",
            "reference.txt",
            "[memory](../../memory/x.md)\n".into(),
            Siblings::Unknown,
            "[memory](../../../../catalog/memory/x.md)\n".into(),
            vec![],
        ),
        (
            "outside the bound",
            "SKILL.md",
            "[escape](../../../../outside.md)\n".into(),
            Siblings::Unknown,
            "[escape](../../../../outside.md)\n".into(),
            vec!["../../../../outside.md"],
        ),
        (
            "unresolvable",
            "SKILL.md",
            "[bad](../../%zz.md)\n".into(),
            Siblings::Unknown,
            "[bad](../../%zz.md)\n".into(),
            vec!["../../%zz.md"],
        ),
        (
            "managed block",
            "SKILL.md",
            format!("---\nname: ship\n---\n{block}[memory](../../memory/x.md)\n"),
            Siblings::Unknown,
            format!("---\nname: ship\n---\n{block}[memory](../../../../catalog/memory/x.md)\n"),
            vec![],
        ),
    ];
    for (row, file, text, siblings, expected, kept) in rows {
        let (converted, links) =
            convert(origin(&source, files(file, &text), siblings), &destination);
        assert_eq!(converted, files(file, &expected), "{row}");
        let targets: Vec<&str> = links.iter().map(|link| link.target.as_str()).collect();
        assert_eq!(targets, kept, "{row}");
        assert!(
            links.iter().all(|link| link.file == Path::new(file)),
            "{row}"
        );
    }
}

/// A spelling that already reaches its target from the destination keeps
/// every byte, but only inside the bound: the equivalent check never keeps
/// a link the bound refused.
#[test]
fn an_equivalent_spelling_keeps_its_bytes_only_inside_the_bound() {
    let tmp = tempfile::tempdir().unwrap();
    let root = crate::test_util::rooted(&tmp);
    let source = root.join("project/skills/ship");
    let destination = Position {
        directory: root.join("project/skills/ship"),
        bound: root.join("project"),
    };
    let text = "[memory](../.././memory/x%2Emd#part)\n[out](../../../outside.md)\n";
    let (converted, kept) = convert(
        origin(&source, files("SKILL.md", text), Siblings::Unknown),
        &destination,
    );
    assert_eq!(converted, files("SKILL.md", text));
    assert_eq!(
        kept,
        vec![KeptLink {
            file: PathBuf::from("SKILL.md"),
            target: "../../../outside.md".into(),
        }]
    );
}

#[test]
fn bytes_that_are_not_text_are_carried_unchanged() {
    let tmp = tempfile::tempdir().unwrap();
    let root = crate::test_util::rooted(&tmp);
    let bytes = b"\xff[memory](../../memory/x.md)".to_vec();
    let (converted, kept) = convert(
        origin(
            &root.join("skills/ship"),
            vec![(PathBuf::from("binary"), bytes.clone())],
            Siblings::Unknown,
        ),
        &Position {
            directory: root.join(".agents/skills/ship"),
            bound: root.clone(),
        },
    );
    assert_eq!(converted, vec![(PathBuf::from("binary"), bytes)]);
    assert!(kept.is_empty());
}

/// Several positions agree only when their links mean the same targets at
/// the destination. Equal raw bytes at two depths mean two targets; bytes
/// each spelled for its own position mean one.
#[test]
fn positions_agree_by_meaning_not_by_bytes() {
    let tmp = tempfile::tempdir().unwrap();
    let home = crate::test_util::rooted(&tmp);
    let destination = Position {
        directory: home.join(".agents/skills/ship"),
        bound: home.clone(),
    };
    let claude = home.join(".claude/skills/ship");
    let pi = home.join(".pi/agent/skills/ship");
    // (row, Claude's text, Pi's text, agree)
    let rows = [
        (
            "equal bytes at depth 3 and depth 4, exiting link",
            "[m](../../../memory/x.md)\n",
            "[m](../../../memory/x.md)\n",
            false,
        ),
        (
            "equal bytes, internal and sibling links only",
            "[r](reference.md)\n[o](../other/SKILL.md)\n",
            "[r](reference.md)\n[o](../other/SKILL.md)\n",
            true,
        ),
        (
            "different bytes, each spelled for its own position",
            "[m](../../../memory/x.md)\n",
            "[m](../../../../memory/x.md)\n",
            true,
        ),
    ];
    for (row, at_claude, at_pi, agree) in rows {
        let outcome = agreed(
            origin(
                &claude,
                files("SKILL.md", at_claude),
                Siblings::SkillsDirectory,
            ),
            [origin(
                &pi,
                files("SKILL.md", at_pi),
                Siblings::SkillsDirectory,
            )],
            &destination,
        );
        match (outcome, agree) {
            (
                Converted::Agreed {
                    files: converted,
                    kept,
                },
                true,
            ) => {
                assert!(kept.is_empty(), "{row}");
                let (expected, _) = convert(
                    origin(
                        &claude,
                        files("SKILL.md", at_claude),
                        Siblings::SkillsDirectory,
                    ),
                    &destination,
                );
                assert_eq!(converted, expected, "{row}");
            }
            (Converted::Disagree { positions }, false) => {
                assert_eq!(positions, [claude.clone(), pi.clone()], "{row}");
            }
            (Converted::Agreed { .. }, false) => panic!("{row}: positions agreed"),
            (Converted::Disagree { .. }, true) => panic!("{row}: positions disagreed"),
        }
    }
}

/// A link file is carried, never written through, so positions agree on it
/// only where it reaches the same place from each: inside its own tree by
/// its path there, outside by the whole path. The order a directory lists
/// its entries in decides nothing.
#[test]
fn positions_agree_on_link_files_by_what_they_reach() {
    let tmp = tempfile::tempdir().unwrap();
    let home = crate::test_util::rooted(&tmp);
    let destination = Position {
        directory: home.join(".agents/skills/ship"),
        bound: home.clone(),
    };
    let claude = home.join(".claude/skills/ship");
    let pi = home.join(".pi/agent/skills/ship");
    let link = |file: &str, target: &str| LinkFile {
        file: file.into(),
        target: target.into(),
    };
    // (row, Claude's link files, Pi's link files, agree)
    let rows = [
        (
            "the same files inside the tree, listed in either order",
            vec![link("alias", "reference.md"), link("entry", "SKILL.md")],
            vec![link("entry", "SKILL.md"), link("alias", "reference.md")],
            true,
        ),
        (
            "one spelling at two depths reaches two places",
            vec![link("assets", "../../../assets")],
            vec![link("assets", "../../../assets")],
            false,
        ),
        (
            "each spelled for its own depth reaches one place",
            vec![link("assets", "../../../assets")],
            vec![link("assets", "../../../../assets")],
            true,
        ),
        (
            "the same name at two different targets",
            vec![link("fixture", "/fixtures/a.md")],
            vec![link("fixture", "/fixtures/b.md")],
            false,
        ),
        (
            "a link file at one position only",
            vec![link("alias", "reference.md")],
            vec![],
            false,
        ),
    ];
    for (row, at_claude, at_pi, agree) in rows {
        let held = |directory: &Path, link_files: Vec<LinkFile>| Origin {
            link_files,
            ..origin(
                directory,
                files("SKILL.md", "[r](reference.md)\n"),
                Siblings::SkillsDirectory,
            )
        };
        let outcome = agreed(held(&claude, at_claude), [held(&pi, at_pi)], &destination);
        match (outcome, agree) {
            (Converted::Agreed { .. }, true) | (Converted::Disagree { .. }, false) => {}
            (Converted::Agreed { .. }, false) => panic!("{row}: positions agreed"),
            (Converted::Disagree { .. }, true) => panic!("{row}: positions disagreed"),
        }
    }
}

#[test]
fn the_reading_comes_from_the_store_class() {
    let tmp = tempfile::tempdir().unwrap();
    let root = crate::test_util::rooted(&tmp);
    let project = root.join("project");
    let catalog = project.join("vendor/catalog");
    std::fs::create_dir_all(catalog.join("skills/ship")).unwrap();
    let sealed = SealedSource::open(&catalog).unwrap();
    let env = Env::fake(root.join("home"), crate::env::FakeOs::Linux);
    let scope = Scope::Project {
        root: project.clone(),
    };
    let mut manifest = Manifest::default();
    manifest.sources.insert(
        "vendor".into(),
        crate::manifest::SourceDecl {
            path: Some("vendor/catalog".into()),
            ..Default::default()
        },
    );
    manifest.sources.insert(
        "fetched".into(),
        crate::manifest::SourceDecl {
            repo: Some("acme/catalog".into()),
            ..Default::default()
        },
    );
    let tagged = ItemDecl {
        links: Some(SkillLinks::SharedTree),
        ..ItemDecl::from_source(LOCAL_SOURCE_NAME)
    };
    let item = catalog.join("skills/ship");
    let shared = project.join(".agents/skills/ship");
    // (row, declaration, expected reading directory or None for pass-through)
    let rows = [
        ("tagged local", tagged.clone(), Some(shared.clone())),
        (
            "tagged in-place",
            ItemDecl {
                source: INPLACE_SOURCE_NAME.into(),
                ..tagged
            },
            Some(shared),
        ),
        (
            "untagged local",
            ItemDecl::from_source(LOCAL_SOURCE_NAME),
            None,
        ),
        (
            "path catalog",
            ItemDecl::from_source("vendor"),
            Some(item.clone()),
        ),
        ("fetched catalog", ItemDecl::from_source("fetched"), None),
    ];
    for (row, decl, expected) in rows {
        let reading = declared(
            &env,
            &scope,
            &manifest,
            (&decl).into(),
            "ship",
            &item,
            &sealed,
        );
        let directory = match reading {
            Reading::Fixed { position, .. } => {
                assert_eq!(position.bound, project, "{row}");
                Some(position.directory)
            }
            Reading::AsDelivered | Reading::Opaque => None,
        };
        assert_eq!(directory, expected, "{row}");
    }
    assert!(matches!(
        declared(
            &env,
            &scope,
            &manifest,
            (&ItemDecl::from_source(LOCAL_SOURCE_NAME)).into(),
            "ship",
            &item,
            &sealed
        ),
        Reading::AsDelivered
    ));
    assert!(matches!(
        declared(
            &env,
            &scope,
            &manifest,
            (&ItemDecl::from_source("fetched")).into(),
            "ship",
            &item,
            &sealed
        ),
        Reading::Opaque
    ));
}
