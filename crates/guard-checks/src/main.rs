use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::error::Error;
use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

use proc_macro2::Span;
use syn::spanned::Spanned;
use syn::visit::{self, Visit};
use syn::{Expr, ExprCall, ExprMethodCall, ItemUse, UseTree};

#[derive(Clone, Copy)]
enum Imported {
    Crate,
    Function,
    TempDir,
    Builder,
}

#[derive(Default)]
struct Imports {
    aliases: HashMap<String, Imported>,
    tempfile_glob: bool,
}

impl Imports {
    fn collect(&mut self, tree: &UseTree, prefix: &mut Vec<String>) {
        match tree {
            UseTree::Path(path) => {
                prefix.push(path.ident.to_string());
                self.collect(&path.tree, prefix);
                prefix.pop();
            }
            UseTree::Name(name) => {
                prefix.push(name.ident.to_string());
                self.record(prefix, name.ident.to_string());
                prefix.pop();
            }
            UseTree::Rename(rename) => {
                prefix.push(rename.ident.to_string());
                self.record(prefix, rename.rename.to_string());
                prefix.pop();
            }
            UseTree::Group(group) => {
                for item in &group.items {
                    self.collect(item, prefix);
                }
            }
            UseTree::Glob(_) if prefix.as_slice() == ["tempfile"] => {
                self.tempfile_glob = true;
            }
            UseTree::Glob(_) => {}
        }
    }

    fn record(&mut self, path: &[String], local: String) {
        let kind = match path {
            [krate] if krate == "tempfile" => Some(Imported::Crate),
            [krate, name]
                if krate == "tempfile" && matches!(name.as_str(), "tempdir" | "tempdir_in") =>
            {
                Some(Imported::Function)
            }
            [krate, name] if krate == "tempfile" && name == "TempDir" => Some(Imported::TempDir),
            [krate, name] if krate == "tempfile" && name == "Builder" => Some(Imported::Builder),
            _ => None,
        };
        if let Some(kind) = kind {
            self.aliases.insert(local, kind);
        }
    }
}

impl<'ast> Visit<'ast> for Imports {
    fn visit_item_use(&mut self, node: &'ast ItemUse) {
        self.collect(&node.tree, &mut Vec::new());
        visit::visit_item_use(self, node);
    }
}

struct Calls<'a> {
    added: &'a BTreeSet<usize>,
    imports: &'a Imports,
    lines: BTreeSet<usize>,
}

impl Calls<'_> {
    fn added_span(&self, span: Span) -> bool {
        let start = span.start().line;
        let end = span.end().line.max(start);
        self.added.range(start..=end).next().is_some()
    }

    fn record(&mut self, span: Span) {
        if self.added_span(span) {
            self.lines.insert(span.start().line);
        }
    }

    fn path_is_constructor(&self, path: &syn::Path) -> bool {
        let segments: Vec<String> = path
            .segments
            .iter()
            .map(|segment| segment.ident.to_string())
            .collect();
        match segments.as_slice() {
            [krate, name]
                if krate == "tempfile" && matches!(name.as_str(), "tempdir" | "tempdir_in") =>
            {
                true
            }
            [krate, ty, method]
                if krate == "tempfile"
                    && ty == "TempDir"
                    && matches!(
                        method.as_str(),
                        "new" | "new_in" | "with_prefix" | "with_prefix_in"
                    ) =>
            {
                true
            }
            [local] => {
                matches!(self.imports.aliases.get(local), Some(Imported::Function))
                    || (self.imports.tempfile_glob
                        && matches!(local.as_str(), "tempdir" | "tempdir_in"))
            }
            [local, method] => {
                (matches!(self.imports.aliases.get(local), Some(Imported::TempDir))
                    && matches!(
                        method.as_str(),
                        "new" | "new_in" | "with_prefix" | "with_prefix_in"
                    ))
                    || (matches!(self.imports.aliases.get(local), Some(Imported::Crate))
                        && matches!(method.as_str(), "tempdir" | "tempdir_in"))
                    || (self.imports.tempfile_glob
                        && local == "TempDir"
                        && matches!(
                            method.as_str(),
                            "new" | "new_in" | "with_prefix" | "with_prefix_in"
                        ))
            }
            [local, ty, method] => {
                matches!(self.imports.aliases.get(local), Some(Imported::Crate))
                    && ty == "TempDir"
                    && matches!(
                        method.as_str(),
                        "new" | "new_in" | "with_prefix" | "with_prefix_in"
                    )
            }
            _ => false,
        }
    }

    fn path_is_builder_new(&self, path: &syn::Path) -> bool {
        let segments: Vec<String> = path
            .segments
            .iter()
            .map(|segment| segment.ident.to_string())
            .collect();
        match segments.as_slice() {
            [head, ty, method] => {
                ((head == "tempfile")
                    || matches!(self.imports.aliases.get(head), Some(Imported::Crate)))
                    && ty == "Builder"
                    && method == "new"
            }
            [local, method] => {
                (matches!(self.imports.aliases.get(local), Some(Imported::Builder))
                    || (self.imports.tempfile_glob && local == "Builder"))
                    && method == "new"
            }
            _ => false,
        }
    }

    fn expression_is_builder(&self, expression: &Expr) -> bool {
        match expression {
            Expr::Call(call) => {
                matches!(call.func.as_ref(), Expr::Path(path) if self.path_is_builder_new(&path.path))
            }
            Expr::MethodCall(call) => self.expression_is_builder(&call.receiver),
            Expr::Group(group) => self.expression_is_builder(&group.expr),
            Expr::Paren(paren) => self.expression_is_builder(&paren.expr),
            Expr::Reference(reference) => self.expression_is_builder(&reference.expr),
            _ => false,
        }
    }
}

impl<'ast> Visit<'ast> for Calls<'_> {
    fn visit_expr_call(&mut self, node: &'ast ExprCall) {
        if let Expr::Path(path) = node.func.as_ref()
            && self.path_is_constructor(&path.path)
        {
            self.record(node.span());
        }
        visit::visit_expr_call(self, node);
    }

    fn visit_expr_method_call(&mut self, node: &'ast ExprMethodCall) {
        if matches!(node.method.to_string().as_str(), "tempdir" | "tempdir_in")
            && self.expression_is_builder(&node.receiver)
        {
            self.record(node.span());
        }
        visit::visit_expr_method_call(self, node);
    }
}

fn added_lines(diff: &str) -> Result<BTreeMap<PathBuf, BTreeSet<usize>>, Box<dyn Error>> {
    let mut files: BTreeMap<PathBuf, BTreeSet<usize>> = BTreeMap::new();
    let mut path: Option<PathBuf> = None;
    let mut new_line = 0usize;
    let mut in_hunk = false;
    for line in diff.lines() {
        if let Some(raw) = line.strip_prefix("+++ ") {
            path = raw.strip_prefix("b/").map(PathBuf::from);
            in_hunk = false;
            continue;
        }
        if line.starts_with("@@ ") {
            let spec = line
                .split_whitespace()
                .find(|part| part.starts_with('+'))
                .ok_or_else(|| {
                    io::Error::new(io::ErrorKind::InvalidData, "diff hunk has no new range")
                })?;
            let start = spec[1..].split(',').next().unwrap_or_default();
            new_line = start.parse()?;
            in_hunk = true;
            continue;
        }
        if !in_hunk {
            continue;
        }
        match line.as_bytes().first() {
            Some(b'+') => {
                if let Some(path) = &path {
                    files.entry(path.clone()).or_default().insert(new_line);
                }
                new_line += 1;
            }
            Some(b'-') => {}
            Some(b' ') => new_line += 1,
            Some(b'\\') => {}
            _ => in_hunk = false,
        }
    }
    Ok(files)
}

fn violations(source: &str, added: &BTreeSet<usize>) -> Result<BTreeSet<usize>, syn::Error> {
    let syntax = syn::parse_file(source)?;
    let mut imports = Imports::default();
    imports.visit_file(&syntax);
    let mut calls = Calls {
        added,
        imports: &imports,
        lines: BTreeSet::new(),
    };
    calls.visit_file(&syntax);
    Ok(calls.lines)
}

fn run(root: &Path, diff: &str) -> Result<Vec<String>, Box<dyn Error>> {
    let mut hits = Vec::new();
    for (path, added) in added_lines(diff)? {
        let source = fs::read_to_string(root.join(&path))?;
        for line in violations(&source, &added)? {
            hits.push(format!(
                "{}:{line}: direct tempfile constructor",
                path.display()
            ));
        }
    }
    Ok(hits)
}

fn main() -> Result<(), Box<dyn Error>> {
    let root = std::env::args_os()
        .nth(1)
        .map(PathBuf::from)
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "usage: temp-fixture-check ROOT",
            )
        })?;
    let mut diff = String::new();
    io::stdin().read_to_string(&mut diff)?;
    let stdout = io::stdout();
    let mut output = stdout.lock();
    for hit in run(&root, &diff)? {
        writeln!(output, "{hit}")?;
    }
    Ok(())
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    fn find(source: &str) -> BTreeSet<usize> {
        let added = (1..=source.lines().count()).collect();
        violations(source, &added).unwrap()
    }

    #[test]
    fn split_calls_and_import_aliases_are_constructors() {
        let source = r#"
use tempfile::tempdir as make;
fn fixtures() {
    let _one = tempfile::tempdir
        ();
    let _two = make();
}
"#;
        assert_eq!(find(source).len(), 2);
    }

    #[test]
    fn type_aliases_and_builder_methods_are_constructors() {
        let source = r#"
use tempfile::{Builder as TempBuilder, TempDir as Dir};
fn fixtures() {
    let _one = Dir::new().unwrap();
    let _two = TempBuilder::new().tempdir().unwrap();
}
"#;
        assert_eq!(find(source).len(), 2);
    }

    #[test]
    fn crate_aliases_are_constructors_but_same_name_methods_are_not() {
        let source = r#"
use tempfile as tf;
fn fixtures() {
    let _one = tf::tempdir().unwrap();
    let _two = tf::TempDir::new().unwrap();
    let project = ProjectBuilder::new().tempdir();
    drop(project);
}
"#;
        assert_eq!(find(source).len(), 2);
    }

    #[test]
    fn multiline_raw_strings_are_not_code() {
        let source = r####"
fn fixture() {
    let _script = r###"
        tempfile::tempdir()
        TempDir::new()
    "###;
}
"####;
        assert!(find(source).is_empty());
    }

    #[test]
    fn rooted_owners_and_same_name_shadows_pass() {
        let source = r#"
fn fixture() {
    let tmp = kendex_test_support::RootedTempDir::new().unwrap();
    let _root = tmp.path();
    let tempfile = ProjectFixture::new();
    let _other = tempfile.path();
}
"#;
        assert!(find(source).is_empty());
    }

    #[test]
    fn unified_diff_added_lines_are_tracked() {
        let diff = "diff --git a/crates/core/tests/x.rs b/crates/core/tests/x.rs\n--- a/crates/core/tests/x.rs\n+++ b/crates/core/tests/x.rs\n@@ -2,0 +3,2 @@\n+one\n+two\n";
        assert_eq!(
            added_lines(diff).unwrap()[Path::new("crates/core/tests/x.rs")],
            [3, 4].into()
        );
    }
}
