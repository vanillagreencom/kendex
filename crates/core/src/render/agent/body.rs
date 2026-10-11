use std::path::Path;

use crate::check_catalog::links::{decoded, relative_links};
use crate::render::RenderWarning;

/// Source and destination files with the roots their relative targets belong to.
#[derive(Clone, Copy)]
pub struct BodyPaths<'a> {
    pub source: &'a Path,
    pub source_root: &'a Path,
    pub rendered: &'a Path,
    pub install_root: &'a Path,
}

/// Map catalog-relative targets into the consumer tree. Fork capture uses the
/// same operation with the file and root pairs reversed.
pub(crate) fn rebase(text: &str, paths: BodyPaths<'_>) -> (String, Vec<RenderWarning>) {
    let mut links = relative_links(text);
    links.sort_by_key(|link| link.range.as_ref().map(|range| range.start));
    links.dedup_by(|left, right| left.range == right.range && left.target == right.target);
    let mut out = String::new();
    let mut warnings = Vec::new();
    let mut copied = 0;
    for link in links {
        let target = decoded(&link.path, '/')
            .and_then(|path| crate::fs::resolved(paths.source, Path::new(&path)))
            .and_then(|path| {
                path.strip_prefix(paths.source_root)
                    .ok()
                    .map(Path::to_path_buf)
            })
            .and_then(|path| {
                let parent = paths.rendered.parent()?;
                parent.strip_prefix(paths.install_root).ok()?;
                let target = paths.install_root.join(path);
                Some(if target == parent {
                    ".".into()
                } else {
                    crate::fs::spelling(Some(paths.install_root), &target, paths.rendered)
                })
            });
        let (Some(target), Some(range)) = (target, link.range) else {
            warnings.push(RenderWarning::with_fix(
                format!("agent-link-unrepresentable: {}", link.target),
                "keep the link target inside the catalog and the rendered scope, or use an absolute path or URL",
            ));
            continue;
        };
        if range.start < copied {
            continue;
        }
        out.push_str(&text[copied..range.start]);
        for ch in crate::paths::slashed(&target).chars() {
            match ch {
                ' ' => out.push_str("%20"),
                '<' => out.push_str("%3C"),
                '>' => out.push_str("%3E"),
                '%' => out.push_str("%25"),
                '#' => out.push_str("%23"),
                '?' => out.push_str("%3F"),
                ':' => out.push_str("%3A"),
                '(' | ')' | '[' | ']' => {
                    out.push('\\');
                    out.push(ch);
                }
                '&' => out.push_str("&amp;"),
                other => out.push(other),
            }
        }
        out.push_str(&link.target[link.path.len()..]);
        copied = range.end;
    }
    out.push_str(&text[copied..]);
    (out, warnings)
}

#[cfg(test)]
mod tests;
