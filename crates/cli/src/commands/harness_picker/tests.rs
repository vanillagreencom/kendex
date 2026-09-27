//! The questions `add` asks at a terminal, in both renderings, answered by
//! scripted keys. `tests/add_picker_terminal.rs` drives them through the
//! binary.

use std::cell::RefCell;

use console::Key as Pressed;
use kendex_core::manifest::Method;
use kendex_core::model::HarnessId::{self, Claude, Codex, Cursor};

use super::{pick_method, pick_tools};
use crate::ui::Style;
use crate::ui::testing::{asked, plain, rich, tagged};

type Answer<T> = std::io::Result<T>;

/// A question driven by `keys`, one per keyed question it reads, through
/// `run`: what it drew, and the answer it settled. A question read past
/// its keys reads the end of input, which cancels.
fn driven<Q: Copy, T>(
    style: &Style,
    keys: &[Pressed],
    run: impl FnOnce(
        &mut dyn FnMut(&[String]),
        &mut dyn FnMut(&[(crate::ui::Choice<'_>, Q)]) -> std::io::Result<Q>,
    ) -> Answer<T>,
) -> (Vec<String>, Answer<T>) {
    let drawn = RefCell::new(Vec::new());
    let mut keys = keys.iter();
    let answer = run(
        &mut |lines| drawn.borrow_mut().extend_from_slice(lines),
        &mut |options| {
            let key: Vec<Pressed> = keys.next().cloned().into_iter().collect();
            let (lines, answer) = asked(style, options, &key);
            drawn.borrow_mut().extend(lines);
            answer
        },
    );
    (tagged(&drawn.into_inner()), answer)
}

/// The answer a row wants: what it settled, or a cancel.
fn assert_answer<T: PartialEq + std::fmt::Debug>(what: &str, got: Answer<T>, want: Option<T>) {
    match (got, want) {
        (Ok(got), Some(want)) => assert_eq!(got, want, "{what}"),
        (Err(error), None) => assert!(crate::ui::cancelled(&error), "{what}: {error}"),
        (got, want) => panic!("{what}: got {got:?}, wanted {want:?}"),
    }
}

const RICH_TOOLS: [&str; 3] = [
    "",
    "<33>!</> <1>where should this install to?</>",
    "  the shared .agents home is always included; a number checks or unchecks a tool",
];
const PLAIN_TOOLS: [&str; 2] = [
    "! where should this install to?",
    "  the shared .agents home is always included; a number checks or unchecks a tool",
];

/// The buttons with Claude Code checked, and with nothing checked.
const RICH_FROM: [&str; 2] = [
    "  <34>[1]</> <90>drop Claude Code</><90> · </><34>[2]</> <90>add Codex</><90> · </><34>[3]</> <90>add Cursor</><90> · </><34>[a]</> <90>every tool</>",
    "  <1;34>[Enter]</> <1>install to Claude Code</>",
];
const PLAIN_FROM: &str = "  [1] drop Claude Code · [2] add Codex · [3] add Cursor · [a] every tool · [Enter] install to Claude Code";
const RICH_NONE: [&str; 2] = [
    "  <34>[1]</> <90>add Claude Code</><90> · </><34>[2]</> <90>add Codex</><90> · </><34>[3]</> <90>add Cursor</><90> · </><34>[a]</> <90>every tool</>",
    "  <1;34>[Enter]</> <1>install to the checked tools</>",
];
const PLAIN_NONE: &str = "  [1] add Claude Code · [2] add Codex · [3] add Cursor · [a] every tool · [Enter] install to the checked tools";
type ToolRow = (
    &'static str,
    [bool; 3],
    &'static [Pressed],
    Option<&'static [HarnessId]>,
    &'static [&'static str],
    &'static [&'static str],
);

/// The tool question's rows, one per way of answering it: what the row
/// is, the pre-checked tools, its keys, the tools it settles or `None` for
/// a cancel, and what it draws under the callout in each rendering.
fn tool_rows() -> [ToolRow; 4] {
    [
        (
            "accept",
            [true, false, false],
            &[Pressed::Char('2'), Pressed::Char('1'), Pressed::Enter],
            Some(&[Codex]),
            &[
                RICH_FROM[0],
                RICH_FROM[1],
                "  <34>›</> <1>add Codex</>",
                "  <34>[1]</> <90>drop Claude Code</><90> · </><34>[2]</> <90>drop Codex</><90> · </><34>[3]</> <90>add Cursor</><90> · </><34>[a]</> <90>every tool</>",
                "  <1;34>[Enter]</> <1>install to Claude Code, Codex</>",
                "  <34>›</> <1>drop Claude Code</>",
                "  <34>[1]</> <90>add Claude Code</><90> · </><34>[2]</> <90>drop Codex</><90> · </><34>[3]</> <90>add Cursor</><90> · </><34>[a]</> <90>every tool</><90> · </><1;34>[Enter]</> <1>install to Codex</>",
                "  <34>›</> <1>install to Codex</>",
            ],
            &[
                PLAIN_FROM,
                "  › add Codex",
                "  [1] drop Claude Code · [2] drop Codex · [3] add Cursor · [a] every tool · [Enter] install to Claude Code, Codex",
                "  › drop Claude Code",
                "  [1] add Claude Code · [2] drop Codex · [3] add Cursor · [a] every tool · [Enter] install to Codex",
                "  › install to Codex",
            ],
        ),
        (
            "default",
            [true, false, false],
            &[Pressed::Enter],
            Some(&[Claude]),
            &[
                RICH_FROM[0],
                RICH_FROM[1],
                "  <34>›</> <1>install to Claude Code</>",
            ],
            &[PLAIN_FROM, "  › install to Claude Code"],
        ),
        (
            "refusal",
            [false, false, false],
            &[Pressed::Enter, Pressed::Char('a'), Pressed::Enter],
            Some(&[Claude, Codex, Cursor]),
            &[
                RICH_NONE[0],
                RICH_NONE[1],
                "  <34>›</> <1>install to the checked tools</>",
                "    <31>✗</> no tool is checked; a number checks one",
                RICH_NONE[0],
                RICH_NONE[1],
                "  <34>›</> <1>every tool</>",
                "  <34>[1]</> <90>drop Claude Code</><90> · </><34>[2]</> <90>drop Codex</><90> · </><34>[3]</> <90>drop Cursor</><90> · </><34>[a]</> <90>every tool</>",
                "  <1;34>[Enter]</> <1>install to Claude Code, Codex, Cursor</>",
                "  <34>›</> <1>install to Claude Code, Codex, Cursor</>",
            ],
            &[
                PLAIN_NONE,
                "  › install to the checked tools",
                "    no tool is checked; a number checks one",
                PLAIN_NONE,
                "  › every tool",
                "  [1] drop Claude Code · [2] drop Codex · [3] drop Cursor · [a] every tool · [Enter] install to Claude Code, Codex, Cursor",
                "  › install to Claude Code, Codex, Cursor",
            ],
        ),
        (
            "cancel",
            [true, false, false],
            &[Pressed::Escape],
            None,
            &RICH_FROM,
            &[PLAIN_FROM],
        ),
    ]
}

/// The tool question, in both renderings, from Claude Code pre-checked
/// among three tools: a number checks or unchecks its tool and the buttons
/// are drawn again naming the new set; Enter installs to the checked set,
/// the pre-checked one where nothing was pressed; Enter with nothing
/// checked says so and asks again, and `a` checks every tool; Escape
/// cancels with nothing picked.
#[test]
fn the_tool_question_draws_accept_default_refusal_and_cancel() {
    for (what, checked, keys, want, rich_tail, plain_tail) in tool_rows() {
        for (style, head, tail) in [
            (rich(100), &RICH_TOOLS[..], rich_tail),
            (plain(), &PLAIN_TOOLS[..], plain_tail),
        ] {
            let (drawn, answer) = driven(&style, keys, |draw, ask| {
                pick_tools(
                    &style,
                    ".agents",
                    &[Claude, Codex, Cursor],
                    checked.to_vec(),
                    draw,
                    ask,
                )
            });
            let wanted: Vec<&str> = head.iter().chain(tail).copied().collect();
            assert_eq!(drawn, wanted, "{what}");
            assert_answer(what, answer, want.map(<[HarnessId]>::to_vec));
        }
    }
}

/// The delivery question, in both renderings: `c` copies, Enter takes the
/// default links, Escape cancels with nothing picked. It has no refusal:
/// every key it shows picks a delivery.
#[test]
fn the_delivery_question_draws_accept_default_and_cancel() {
    let rich_asked = [
        "",
        "<33>!</> <1>how should each tool get what is installed?</>",
        "  <34>[c]</> <90>copy: each tool gets a tree of its own</><90> · </><1;34>[Enter]</> <1>link: every tool reads one shared copy</>",
    ];
    let plain_asked = [
        "! how should each tool get what is installed?",
        "  [c] copy: each tool gets a tree of its own · [Enter] link: every tool reads one shared copy",
    ];
    type Row = (
        &'static str,
        Pressed,
        Option<Method>,
        Option<&'static str>,
        Option<&'static str>,
    );
    let rows: [Row; 3] = [
        (
            "accept",
            Pressed::Char('c'),
            Some(Method::Copy),
            Some("  <34>›</> <1>copy: each tool gets a tree of its own</>"),
            Some("  › copy: each tool gets a tree of its own"),
        ),
        (
            "default",
            Pressed::Enter,
            Some(Method::Symlink),
            Some("  <34>›</> <1>link: every tool reads one shared copy</>"),
            Some("  › link: every tool reads one shared copy"),
        ),
        ("cancel", Pressed::Escape, None, None, None),
    ];
    for (what, key, want, rich_tail, plain_tail) in rows {
        for (style, head, tail) in [
            (rich(100), &rich_asked[..], rich_tail),
            (plain(), &plain_asked[..], plain_tail),
        ] {
            let (drawn, answer) = driven(&style, std::slice::from_ref(&key), |draw, ask| {
                pick_method(&style, draw, ask)
            });
            let wanted: Vec<&str> = head.iter().copied().chain(tail).collect();
            assert_eq!(drawn, wanted, "{what}");
            assert_answer(what, answer, want);
        }
    }
}
