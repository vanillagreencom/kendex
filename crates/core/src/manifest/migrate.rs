//! One-time document rewrites. Each schema bump supplies its own step;
//! readers interpret only the current form after the whole chain succeeds.

use toml_edit::{DocumentMut, Value};

use super::MANIFEST_SCHEMA;

struct Step {
    from: u32,
    to: u32,
    rewrite: fn(&mut DocumentMut) -> Option<&'static str>,
}

const STEPS: &[Step] = &[Step {
    from: 6,
    to: 7,
    rewrite: schema_6_to_7,
}];

pub(super) fn migrate(document: &mut DocumentMut) -> Option<Vec<String>> {
    let schema = document.get("schema")?.as_integer()?;
    let start = STEPS
        .iter()
        .position(|step| i64::from(step.from) == schema)?;
    let steps = &STEPS[start..];
    // Do not start a partial rewrite when this build lacks a later step.
    if steps.last()?.to != MANIFEST_SCHEMA
        || steps.windows(2).any(|pair| pair[0].to != pair[1].from)
    {
        return None;
    }
    steps
        .iter()
        .map(|step| {
            (step.rewrite)(document)
                .map(|account| format!("schema {} to {}: {account}", step.from, step.to))
        })
        .collect()
}

fn schema_6_to_7(document: &mut DocumentMut) -> Option<&'static str> {
    let schema = document.get_mut("schema")?.as_value_mut()?;
    if schema.as_integer() != Some(6) {
        return None;
    }
    let mut replacement = Value::from(7);
    *replacement.decor_mut() = schema.decor().clone();
    *schema = replacement;
    Some("updated the root schema value; nothing left to do")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn steps_are_contiguous_and_end_at_the_current_schema() {
        let last = STEPS.last().expect("a supported older schema has a step");
        assert_eq!(last.to, MANIFEST_SCHEMA);
        for step in STEPS {
            assert_eq!(step.to, step.from + 1);
        }
        for pair in STEPS.windows(2) {
            assert_eq!(pair[0].to, pair[1].from);
        }
    }
}
