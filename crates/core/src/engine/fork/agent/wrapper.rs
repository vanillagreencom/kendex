//! The generated document around one agent's prose, read back as the
//! sections the renderer wrote. Where each one starts and ends is asked of
//! the renderer rather than read off its output: any boundary recovered
//! from text can be forged by content that legitimately holds that text,
//! and an agent's instructions may say anything, headings included.

use crate::model::{HarnessId, Scope};
use crate::render::agent::SourceAgent;

use super::{Around, render};

/// One input a section can come from. The banner comes from no input —
/// it is what the bare rendering holds — so it is not one of these. A
/// hook is one input each: the renderer writes a section per hook, and an
/// input standing for all of them accounts for a body only where every
/// one of them is still in it.
#[derive(Clone, Copy)]
enum Wrote {
    LaunchInstructions,
    Skills,
    Hook(usize),
    AdditionalInstructions,
}

/// The generated wrapper, as the sections the renderer wrote, each the
/// bytes one input added, in the order it wrote them.
pub(super) struct Wrapper {
    pub before: Vec<String>,
    pub after: Vec<String>,
    /// The publisher's own prose as this harness renders it, which is the
    /// text a section's copies are counted against. Every harness but
    /// Claude rewrites a body's tool references, so the catalog's bytes
    /// and what those bytes stand as in the rendering are different text —
    /// and a count taken from the source would read a rewritten line as a
    /// section the publisher never brought.
    pub published: String,
}

/// Every input that can produce a section, in the order the renderer is
/// taken to write them. Taken, not trusted: [`wrapper`] rebuilds the
/// rendering out of the sections it read and refuses where the rebuild is
/// not the rendering byte for byte, so a renderer that reorders, grows, or
/// splits a section is a refusal rather than a body cut in the wrong
/// place.
fn from(around: &Around) -> Vec<Wrote> {
    let mut from = vec![Wrote::LaunchInstructions, Wrote::Skills];
    from.extend((0..around.hooks.len()).map(Wrote::Hook));
    from.push(Wrote::AdditionalInstructions);
    from
}

/// The wrapper this harness writes around this agent's prose, or `None`
/// where the harness refuses the agent's permission intent and installs
/// no file at all. `Err` is a rendering this reader cannot account for,
/// which is a refusal: a wrapper read wrongly cuts the person's own words
/// out of their prose.
///
/// Each section's extent is asked of the renderer, by rendering the same
/// agent with that one input and no other and taking what the rendering
/// gains over the one that asked for no sections at all. Nothing is
/// searched for in the rendered text, so a heading standing inside an
/// instruction's own words is part of that instruction and opens nothing.
pub(super) fn wrapper(
    scope: &Scope,
    publisher: &SourceAgent,
    harness: HarnessId,
    around: &Around,
) -> Result<Option<Wrapper>, String> {
    let (Some((bare_before, bare_after)), Some((before, after)), Some(bare_body)) = (
        ends(scope, publisher, harness, &bare(around)),
        ends(scope, publisher, harness, around),
        document(scope, publisher, harness, &bare(around)),
    ) else {
        return Ok(None);
    };
    // The bare rendering is the banner and the separators with this prose
    // between them, so what stands between the ends of that same rendering
    // is the prose alone, in the words this harness renders it in.
    //
    // The strip cannot fail as the two are built here: `bare_before` and
    // `bare_after` are what this same configuration renders around a
    // stand-in body, and `bare_body` is what it renders around the real
    // one, so the ends bracket it by construction. It is written as a
    // refusal rather than a `debug_assert` because only a renderer whose
    // text around a body varied with that body could break it, and reading
    // a wrapper wrongly cuts the person's own words out of their prose. An
    // invariant held fail-closed, not a guard with a case behind it —
    // `a_publisher_body_with_nothing_in_it_still_forks` holds the end of
    // the range where a body could plausibly change what surrounds it.
    let Some(published) = bare_body
        .strip_prefix(bare_before.as_str())
        .and_then(|rest| rest.strip_suffix(bare_after.as_str()))
    else {
        return Err("the prose it publishes does not stand whole inside it".to_owned());
    };
    let mut read = Wrapper {
        before: vec![bare_before.clone()],
        after: Vec::new(),
        published: published.to_owned(),
    };
    for wrote in from(around) {
        let Some((one_before, one_after)) = ends(scope, publisher, harness, &only(around, wrote))
        else {
            return Ok(None);
        };
        let above = one_before.strip_prefix(bare_before.as_str());
        let below = one_after.strip_prefix(bare_after.as_str());
        match (above, below) {
            (Some(""), Some("")) => continue,
            (Some(text), Some("")) => read.before.push(text.to_owned()),
            (Some(""), Some(text)) => read.after.push(text.to_owned()),
            (Some(_), Some(_)) => {
                return Err("a section of it stands both above and below the prose".to_owned());
            }
            (None, _) | (_, None) => {
                return Err(
                    "a section of it rewrites the document around it, rather than adding to it"
                        .to_owned(),
                );
            }
        }
    }
    match read.before.concat() == before && format!("{bare_after}{}", read.after.concat()) == after
    {
        true => Ok(Some(read)),
        false => Err("its sections do not add up to the document it writes".to_owned()),
    }
}

/// What the renderer writes above and below one agent's own prose, asked
/// of the renderer with a stand-in body rather than assembled from a list
/// of headings here, so a renderer that grows a section cannot leave this
/// reader behind.
fn ends(
    scope: &Scope,
    publisher: &SourceAgent,
    harness: HarnessId,
    around: &Around,
) -> Option<(String, String)> {
    const STAND_IN: &str = "kendexstandsinfortheagentsownprose";
    let source = SourceAgent {
        body: STAND_IN.to_owned(),
        ..publisher.clone()
    };
    let body = document(scope, &source, harness, around)?;
    let (before, after) = body.split_once(STAND_IN)?;
    Some((before.to_owned(), after.to_owned()))
}

/// One rendering with its frontmatter taken off, which is the document the
/// wrapper is read out of.
fn document(
    scope: &Scope,
    source: &SourceAgent,
    harness: HarnessId,
    around: &Around,
) -> Option<String> {
    let text = render(scope, source, harness, around)?;
    let (_, body) = crate::frontmatter::split(&text).ok()?;
    Some(body.to_owned())
}

/// The same configuration with every section-producing input emptied.
/// What the renderer writes for it is the banner and the separators — the
/// floor every section stands on.
fn bare<'a>(around: &Around<'a>) -> Around<'a> {
    Around {
        skills: Vec::new(),
        launch: None,
        additional: None,
        hooks: Vec::new(),
        overrides: around.overrides.clone(),
    }
}

/// The same configuration with one input kept and every other emptied.
fn only<'a>(around: &Around<'a>, wrote: Wrote) -> Around<'a> {
    let mut one = bare(around);
    match wrote {
        Wrote::LaunchInstructions => one.launch = around.launch.clone(),
        Wrote::Skills => one.skills = around.skills.clone(),
        Wrote::Hook(at) => one.hooks = around.hooks.get(at).copied().into_iter().collect(),
        Wrote::AdditionalInstructions => one.additional = around.additional.clone(),
    }
    one
}
