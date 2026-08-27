use super::*;

fn tree(root: &Path) -> Artifact {
    Artifact::Tree {
        canonical: root.join(".agents/skills/hello"),
        files: vec![
            (PathBuf::from("SKILL.md"), b"# hello\n".to_vec()),
            (PathBuf::from("scripts/run.sh"), b"exit 0\n".to_vec()),
        ],
        link: Some(root.join(".claude/skills/hello")),
    }
}

#[test]
fn a_tree_records_each_file_by_repository_path_with_its_plain_hash() {
    let root = PathBuf::from("/repo");
    let scope = Scope::Project { root: root.clone() };
    let files = rendered_files(&tree(&root), &scope);
    assert_eq!(
        files.keys().collect::<Vec<_>>(),
        vec![
            ".agents/skills/hello/SKILL.md",
            ".agents/skills/hello/scripts/run.sh"
        ],
        "the link is a position, not bytes kendex wrote: {files:?}"
    );
    assert_eq!(
        files[".agents/skills/hello/SKILL.md"],
        content_hash(b"# hello\n"),
        "the hash a reader reproduces with sha256sum"
    );
}

#[test]
fn a_global_install_records_no_files() {
    let root = PathBuf::from("/home/someone");
    assert!(rendered_files(&tree(&root), &Scope::Global).is_empty());
}

#[test]
fn a_registration_records_only_the_script_it_writes() {
    let root = PathBuf::from("/repo");
    let scope = Scope::Project { root: root.clone() };
    let with_script = Artifact::Registration {
        script: Some((root.join(".claude/hooks/guard.sh"), b"exit 0\n".to_vec())),
        edits: Vec::new(),
    };
    assert_eq!(
        rendered_files(&with_script, &scope)
            .keys()
            .collect::<Vec<_>>(),
        vec![".claude/hooks/guard.sh"]
    );
    let config_only = Artifact::Registration {
        script: None,
        edits: Vec::new(),
    };
    assert!(rendered_files(&config_only, &scope).is_empty());
}
