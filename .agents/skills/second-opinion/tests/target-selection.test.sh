#!/usr/bin/env bash
# Target selection: every mode walks SECOND_OPINION_MODELS in priority order,
# takes a target when its declared model differs from this session's and its
# CLI resolves, never dispatches to the session's own model, and refuses naming
# every candidate when nothing eligible remains. A forced target skips the walk
# but not the exclusion; a declared identity the roster does not spell refuses
# ahead of the force; identities canonicalize (model ids, provider prefixes,
# padding); the count is validated only where it is read; a refusal names
# availability rather than identity when that is its only cause. One table, a
# row per scenario; the session's identity is declared in every row (the
# harness-identity suite covers detection).
# shellcheck source=lib/roster-world.bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/roster-world.bash"

# A row's world starts from these: no harness in the process tree, a session
# with no model, the two built-in lanes stubbed, one opinion.
DEFAULTS="ps:none current:none models:codex+claude count:1 cmd:claude=claude cmd:codex=codex"

# The lane's own artifact, as the single-lane path stamps it.
OWN="pass/b=-/s=-/cov=null/req=1/sel=1/lanes=-/dedupe=-/head=head/union=null"
NONE="calls=claude:0,codex:0,extra:0 art=- files=-"

# label|world|command|rc|out|err|calls art files
ROWS="
the default count is one opinion, the first eligible in priority order; none is the declared absence of a model, not a typo|-|review|0|<out>|single:codex:review:none written|calls=claude:0,codex:1,extra:0 art=external-codex/$OWN files=out
the session's own model is skipped and the next distinct model taken|current:codex|review|0|<out>|same:codex:codex single:claude:review:codex written|calls=claude:1,codex:0,extra:0 art=external-claude/$OWN files=out
a forced target equal to the session model is refused with no artifact and no CLI spend, naming what the roster would pick|current:claude target:claude count:2|review|1|-|same:claude:claude refused:claude:1 hint:claude:codex|$NONE
a --target flag refused the same way carries no settings hint|current:codex|review --target codex|1|-|same:codex:codex refused:codex:1|$NONE
a target's declared SECOND_OPINION_<NAME>_MODEL is what the guard compares: excluded from a session on that model|current:claude models:my-model+codex cmd:my-model=extra model:my-model=claude|review|0|<out>|same:my-model:claude single:codex:review:claude written|calls=claude:0,codex:1,extra:0 art=external-codex/$OWN files=out
control: the same target is eligible from a session on another model|current:codex models:my-model+codex cmd:my-model=extra model:my-model=claude|review|0|<out>|single:my-model:review:codex written|calls=claude:0,codex:0,extra:1 art=external-my-model/$OWN files=out
two roster entries with one declared model count as one opinion|models:claude+my-model+codex count:2 cmd:my-model=extra model:my-model=claude|review|0|<out>|selected:my-model:claude multi:claude+codex:none union:2|calls=claude:1,codex:1,extra:0 art=external-union(claude+codex)/pass/b=-/s=-/cov=full/req=2/sel=2/lanes=claude:ok,codex:ok/dedupe=0/0/0/0/head=head/union=true files=out,out.claude,out.codex
nothing eligible: refuse, naming the session model and every candidate with its reason, with no availability verdict|current:claude models:claude+my-model cmd:my-model=extra model:my-model=claude|review|1|-|same:claude:claude same:my-model:claude refused:claude:2|$NONE
quick mode is guarded too|current:codex models:codex|quick|1|-|same:codex:codex refused:codex:1|$NONE
control: quick takes the next eligible model and prints its answer|current:codex|quick|0|answer:external-claude|same:codex:codex single:claude:quick:codex|calls=claude:1,codex:0,extra:0 art=- files=-
detect prints the cross-model target|current:claude|detect|0|codex|-|$NONE
detect prints none and exits 1 when refusing|current:claude models:claude|detect|1|none|same:claude:claude refused:claude:1|$NONE
SECOND_OPINION_COUNT applies to review only: quick with COUNT=2 takes the single-target path|count:2|quick|0|answer:external-codex|single:codex:quick:none|calls=claude:0,codex:1,extra:0 art=- files=-
COUNT=0 is refused before any CLI|count:0|review|1|-|count-invalid|$NONE
COUNT=0 does not fail quick, which never reads it|count:0|quick|0|answer:external-codex|single:codex:quick:none|calls=claude:0,codex:1,extra:0 art=- files=-
a declared identity the roster does not spell refuses with no artifact|current:clade|review|1|-|unspelled:clade refused:clade:1|$NONE
naming the session model in the roster, with no command, makes it a known identity that is excluded|current:deepseek models:deepseek+codex+claude|review|0|<out>|same:deepseek:deepseek single:codex:review:deepseek written|calls=claude:0,codex:1,extra:0 art=external-codex/$OWN files=out
a Claude model id normalizes to claude and is excluded|current:claude-opus-5 models:claude+codex|review|0|<out>|same:claude:claude single:codex:review:claude written|calls=claude:0,codex:1,extra:0 art=external-codex/$OWN files=out
an OpenAI model id normalizes to codex and is excluded|current:gpt-6-astra|review|0|<out>|same:codex:codex single:claude:review:codex written|calls=claude:1,codex:0,extra:0 art=external-claude/$OWN files=out
a bare Claude family name normalizes to claude|current:Opus models:claude+codex|review|0|<out>|same:claude:claude single:codex:review:claude written|calls=claude:0,codex:1,extra:0 art=external-codex/$OWN files=out
a provider-qualified Anthropic id canonicalizes on its final component|current:anthropic/claude-opus-4 models:claude+codex|review|0|<out>|same:claude:claude single:codex:review:claude written|calls=claude:0,codex:1,extra:0 art=external-codex/$OWN files=out
a provider-qualified OpenAI id likewise|current:openai/gpt-6-astra|review|0|<out>|same:codex:codex single:claude:review:codex written|calls=claude:1,codex:0,extra:0 art=external-claude/$OWN files=out
the openai-codex provider prefix likewise|current:openai-codex/gpt-6-astra|review|0|<out>|same:codex:codex single:claude:review:codex written|calls=claude:1,codex:0,extra:0 art=external-claude/$OWN files=out
a force does not carry a misspelled identity past the roster check|current:codxe|review --target codex|1|-|unspelled:codxe refused:codxe:1|$NONE
detect --target refuses an unspelled identity the same way|current:deepseek|detect --target codex|1|none|unspelled:deepseek refused:deepseek:1|$NONE
control: a spelled identity with a cross-model force dispatches to it|current:claude|review --target codex|0|<out>|single:codex:review:claude written|calls=claude:0,codex:1,extra:0 art=external-codex/$OWN files=out
an identity refusal never advises about a settings-seeded force|current:codxe target:codex|review|1|-|unspelled:codxe refused:codxe:1|$NONE
a per-target identity with a leading space is still the same model|current:claude models:claude+codex model:claude=_claude|review|0|<out>|same:claude:claude single:codex:review:claude written|calls=claude:0,codex:1,extra:0 art=external-codex/$OWN files=out
a non-canonical per-target identity padded on the right is still the same model|current:deepseek models:my-model+codex cmd:my-model=extra model:my-model=deepseek_|review|0|<out>|same:my-model:deepseek single:codex:review:deepseek written|calls=claude:0,codex:1,extra:0 art=external-codex/$OWN files=out
a non-canonical session identity padded on the right resolves, not refuses|current:deepseek_ models:deepseek+codex+claude|review|0|<out>|same:deepseek:deepseek single:codex:review:deepseek written|calls=claude:0,codex:1,extra:0 art=external-codex/$OWN files=out
a per-target identity padded on both sides likewise|current:claude models:claude+codex model:claude=__claude__|review|0|<out>|same:claude:claude single:codex:review:claude written|calls=claude:0,codex:1,extra:0 art=external-codex/$OWN files=out
a per-target identity with a leading tab likewise|current:claude models:claude+codex model:claude=TABclaude|review|0|<out>|same:claude:claude single:codex:review:claude written|calls=claude:0,codex:1,extra:0 art=external-codex/$OWN files=out
a padded session identity resolves instead of refusing as unspelled|current:_codex_|review|0|<out>|same:codex:codex single:claude:review:codex written|calls=claude:1,codex:0,extra:0 art=external-claude/$OWN files=out
an explicitly empty roster refuses instead of defaulting|models:|review|1|-|roster-empty refused:none:1|$NONE
control: an unset roster takes the default roster|models:-|review|0|<out>|single:claude:review:none written|calls=claude:1,codex:0,extra:0 art=external-claude/$OWN files=out
an all-unavailable roster names availability, not identity, as its cause|cmd:claude=missing cmd:codex=missing|review|1|-|nocli:codex:CODEX nocli:claude:CLAUDE refused:none:2 availability|$NONE
mixed causes: both skip reasons stand with no availability verdict on top|current:claude models:claude+codex cmd:codex=missing|review|1|-|same:claude:claude nocli:codex:CODEX refused:claude:2|$NONE
"

run_table "target selection" "$DEFAULTS" "$ROWS"
finish
