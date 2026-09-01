use super::Wrapper;

pub(super) fn prose(body: &str, wrapper: Option<&Wrapper>) -> String {
    let lines: Vec<&str> = body.lines().collect();
    let kept = match wrapper {
        Some(wrapper) => {
            let published: Vec<&str> = wrapper.published.lines().collect();
            let front = &lines[taken(&lines, &published, &said(&wrapper.before, false))..];
            let body_back: Vec<&str> = front.iter().rev().copied().collect();
            let published_back: Vec<&str> = published.iter().rev().copied().collect();
            let back = taken(&body_back, &published_back, &said(&wrapper.after, true));
            front[..front.len() - back].to_vec()
        }
        None => lines,
    };
    format!("{}\n", kept.join("\n").trim_start_matches('\n').trim_end())
}

struct Line<'a> {
    text: &'a str,
    inside: bool,
}

fn said<'a>(sections: &'a [String], reverse: bool) -> Vec<Vec<Line<'a>>> {
    let lines = |section: &'a String| {
        let mut lines: Vec<Line<'a>> = section
            .lines()
            .zip(crate::render::inside_a_block(section))
            .filter(|(text, inside)| *inside || !text.trim().is_empty())
            .map(|(text, inside)| Line { text, inside })
            .collect();
        if reverse {
            lines.reverse();
        }
        lines
    };
    if reverse {
        sections.iter().rev().map(lines).collect()
    } else {
        sections.iter().map(lines).collect()
    }
}

fn taken(body: &[&str], published: &[&str], sections: &[Vec<Line>]) -> usize {
    let mut at = 0;
    for (index, section) in sections.iter().enumerate() {
        if let Some(more) = held(&body[at..], section) {
            let extra = copies(&body[at..], section) > copies(published, section);
            let exposes_next = sections.get(index + 1).is_some_and(|next| {
                held(&body[at..], next).is_none() && held(&body[at + more..], next).is_some()
            });
            if extra || exposes_next {
                at += more;
            }
        }
    }
    at
}

fn copies(body: &[&str], section: &[Line]) -> usize {
    let mut at = 0;
    let mut seen = 0;
    while let Some(more) = held(&body[at..], section) {
        at += more;
        seen += 1;
    }
    seen
}

fn held(body: &[&str], section: &[Line]) -> Option<usize> {
    if section.is_empty() {
        return None;
    }
    let mut matched = 0;
    let mut through = 0;
    for (at, line) in body.iter().enumerate() {
        let want = section.get(matched)?;
        if line.trim().is_empty() && !want.inside {
            continue;
        }
        if *line != want.text {
            return None;
        }
        matched += 1;
        through = at + 1;
        if matched == section.len() {
            break;
        }
    }
    (matched == section.len()).then(|| {
        through
            + body[through..]
                .iter()
                .take_while(|line| line.trim().is_empty())
                .count()
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::fork::agent::decompose;

    fn wrapper(published: &str, after: &[&str]) -> Wrapper {
        Wrapper {
            before: Vec::new(),
            after: after.iter().map(|text| (*text).to_owned()).collect(),
            published: published.to_owned(),
        }
    }

    #[test]
    fn after_sections_keep_an_authored_edge_copy_and_strip_a_nested_suffix() {
        let hook = "\n## Hook\n\nRun check.\n";
        let authored = format!("Body.\n{hook}");
        assert_eq!(
            prose(
                &format!("{authored}{hook}"),
                Some(&wrapper(&authored, &[hook]))
            ),
            authored
        );
        let tail = "\nRun check.\n";
        assert_eq!(
            prose(
                &format!("Body.{hook}{tail}"),
                Some(&wrapper("Body.", &[hook, tail]))
            ),
            "Body.\n"
        );
    }

    #[test]
    fn every_decomposition_invariant_refuses() {
        let cases = [
            ("B", "A", "B", "A", "X", vec![], "published prose"),
            (
                "B",
                "A",
                "BX",
                "AY",
                "BPA",
                vec![("BX".into(), "AY".into())],
                "both sides",
            ),
            (
                "B",
                "A",
                "B",
                "A",
                "BPA",
                vec![("X".into(), "A".into())],
                "rewrites",
            ),
            ("B", "A", "BZ", "A", "BPA", vec![], "reconstruct"),
        ];
        for (bare_before, bare_after, before, after, body, parts, expected) in cases {
            let error = decompose(
                bare_before.into(),
                bare_after.into(),
                before.into(),
                after.into(),
                body.into(),
                parts,
            )
            .unwrap_err();
            assert!(error.contains(expected), "{error}");
        }
    }
}
