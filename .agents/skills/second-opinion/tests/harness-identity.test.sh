#!/usr/bin/env bash
# The session's identity: the nearest harness ancestor `ps` reports wins
# (exact names, trimmed; a bystander sharing a prefix is not a harness), the
# environment markers are the fallback with Codex's own ahead of an inherited
# Claude one, and the model of a detected single-model harness beats any
# declaration: an agreeing one changes nothing, a contradicting one is refused
# naming both values and where it was declared. Where detection cannot
# arbitrate (Pi, Cursor, no harness at all) the declaration is the only
# identity, and only a value exported in the session's own environment counts:
# a project settings file is refused naming the file that supplied it, a key
# the loader never reads declares nothing, a set-but-empty export takes the
# undeclared path and suppresses the project file in the lanes. One table, a
# row per scenario; the `ps` of each row's world answers the detection walk
# with one ancestor of the named comm, so the rows run the same on every
# platform.
# shellcheck source=lib/roster-world.bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/roster-world.bash"

# A row's world starts from these: no harness in the process tree, nothing
# declared, the two built-in lanes stubbed, one opinion.
DEFAULTS="ps:none current:- models:claude+codex count:1 cmd:claude=claude cmd:codex=codex"

OWN="pass/b=-/s=-/cov=null/req=1/sel=1/lanes=-/dedupe=-/head=head/union=null"
NONE="calls=claude:0,codex:0,extra:0 art=- files=-"
# The dispatch of a claude session (codex taken) and of a codex session.
CLAUDE_SESSION="same:claude:claude single:codex:review:claude written|calls=claude:0,codex:1,extra:0 art=external-codex/$OWN files=out"
CODEX_SESSION="same:codex:codex single:claude:review:codex written|calls=claude:1,codex:0,extra:0 art=external-claude/$OWN files=out"
# The fan-out of the agreeing-value rows: two lanes on a deepseek-declared
# custom target.
FANOUT="models:claude+my-model count:2 cmd:my-model=extra model:my-model=deepseek"
UNION="multi:claude+my-model:codex union:2|calls=claude:1,codex:0,extra:1 art=external-union(claude+my-model)/pass/b=-/s=-/cov=full/req=2/sel=2/lanes=claude:ok,my-model:ok/dedupe=0/0/0/0/head=head/union=true files=out,out.claude,out.my-model"

# label|world|command|rc|out|err|calls art files
ROWS="
a detected claude session excludes claude without a declaration|ps:claude|review|0|<out>|$CLAUDE_SESSION
a declaration contradicting the detected harness is refused, naming both values and the session's environment as its source|ps:claude current:codex|review|1|-|contradicts:codex:claude:env refused:claude:1|$NONE
the Claude marker alone identifies a claude session when the tree shows no harness|marker:CLAUDECODE=1|review|0|<out>|$CLAUDE_SESSION
an undeclared Pi session refuses: no CLI, no artifact, the setting named, no force hint|ps:pi models:codex+claude|review|1|-|undeclared:pi refused:undeclared:1|$NONE
control: the declared Pi-on-claude session gets codex|ps:pi current:claude|review|0|<out>|$CLAUDE_SESSION
an undeclared Cursor session refuses the same way; cursor-agent is the harness's own name|ps:cursor-agent|review|1|-|undeclared:cursor refused:undeclared:1|$NONE
a forced target under an undeclared session is refused for the identity, with no force hint|ps:pi target:codex|review|1|-|undeclared:pi refused:undeclared:1|$NONE
the innermost harness wins over an inherited CLAUDECODE|ps:codex marker:CLAUDECODE=1 models:codex+claude|review|0|<out>|$CODEX_SESSION
a detected identity the roster does not name excludes nothing|ps:claude models:codex|review|0|<out>|single:codex:review:claude written|calls=claude:0,codex:1,extra:0 art=external-codex/$OWN files=out
a force under a detected identity the roster omits is honoured|ps:claude models:codex target:codex|review|0|<out>|single:codex:review:claude written|calls=claude:0,codex:1,extra:0 art=external-codex/$OWN files=out
the marker route with a target-only roster likewise|marker:CLAUDECODE=1 models:codex|review|0|<out>|single:codex:review:claude written|calls=claude:0,codex:1,extra:0 art=external-codex/$OWN files=out
no harness and no declaration: the not-detected refusal names the none escape|ps:none|review|1|-|undetected refused:undeclared:1|$NONE
control: none declared with no harness dispatches the roster's first entry|current:none|review|0|<out>|single:claude:review:none written|calls=claude:1,codex:0,extra:0 art=external-claude/$OWN files=out
a ps that answers nothing ends the walk as undetected|ps:empty|review|1|-|undetected refused:undeclared:1|$NONE
an ancestor named cursor (the editor) establishes no harness identity|ps:cursor|review|1|-|undetected refused:undeclared:1|$NONE
an ancestor named codex-wrapper establishes no harness identity|ps:codex-wrapper|review|1|-|undetected refused:undeclared:1|$NONE
CODEX_SANDBOX outranks an inherited CLAUDECODE|marker:CLAUDECODE=1 marker:CODEX_SANDBOX=seatbelt models:codex+claude|review|0|<out>|$CODEX_SESSION
CODEX_SANDBOX_NETWORK_DISABLED outranks it too|marker:CLAUDECODE=1 marker:CODEX_SANDBOX_NETWORK_DISABLED=1 models:codex+claude|review|0|<out>|$CODEX_SESSION
a project-file identity contradicting a detected claude session is refused naming the file|ps:claude proj:settings:codex|review|1|-|contradicts:codex:claude:kendex.settings.toml refused:claude:1|$NONE
a project-file none in a detected claude session is a contradiction too|ps:claude proj:settings:none|review|1|-|contradicts:none:claude:kendex.settings.toml refused:claude:1|$NONE
an exported declaration beside the project file is named as the session's own|ps:claude current:codex proj:settings:codex|review|1|-|contradicts:codex:claude:env refused:claude:1|$NONE
a project value agreeing with detection proceeds cross-model|ps:claude proj:settings:claude|review|0|<out>|$CLAUDE_SESSION
an agreeing project value carries no roster-spelling requirement|ps:claude proj:settings:claude models:codex|review|0|<out>|single:codex:review:claude written|calls=claude:0,codex:1,extra:0 art=external-codex/$OWN files=out
the mirrored harness: an agreeing codex value in a codex session with a claude-only roster|ps:codex proj:settings:codex models:claude|review|0|<out>|single:claude:review:codex written|calls=claude:1,codex:0,extra:0 art=external-claude/$OWN files=out
a project value contradicting a detected codex session is refused|ps:codex proj:settings:claude|review|1|-|contradicts:claude:codex:kendex.settings.toml refused:codex:1|$NONE
a project-sourced identity is refused in a Pi session, naming the file|ps:pi proj:settings:codex|review|1|-|project:codex:pi:kendex.settings.toml refused:codex:1|$NONE
a project-sourced identity is refused in a Cursor session|ps:cursor-agent proj:settings:codex|review|1|-|project:codex:cursor:kendex.settings.toml refused:codex:1|$NONE
control: the same value exported in the session's own environment is honoured in a Pi session|ps:pi current:codex proj:settings:codex models:codex+claude|review|0|<out>|$CODEX_SESSION
a set-but-empty export takes the undeclared path, not the project file's|ps:pi current:empty proj:settings:codex|review|1|-|undeclared:pi refused:undeclared:1|$NONE
.env.local is named when it supplied the value|ps:pi proj:envlocal:codex|review|1|-|project:codex:pi:.env.local refused:codex:1|$NONE
a set-but-empty export suppresses .env.local's value too, which is sourced wholesale|ps:pi current:empty proj:envlocal:codex|review|1|-|undeclared:pi refused:undeclared:1|$NONE
.kendex/settings.toml is named when it supplied the value|ps:pi proj:local:codex|review|1|-|project:codex:pi:.kendex/settings.toml refused:codex:1|$NONE
the agreeing-value exemption survives the recursive lane launch|ps:codex proj:settings:codex $FANOUT|review|0|<out>|$UNION
control: a caller-exported identity still fans out to the lanes|ps:pi current:codex $FANOUT models:claude+my-model+codex|review|0|<out>|$UNION
an exported empty value suppresses a contradicting project file in the lanes too|ps:codex current:empty proj:settings:claude $FANOUT|review|0|<out>|$UNION
a nested harness does not inherit the outer session's exported identity|ps:codex current:claude|review|1|-|contradicts:claude:codex:env refused:codex:1|$NONE
control: the same export in a real claude session is agreement|ps:claude current:claude|review|0|<out>|$CLAUDE_SESSION
only the file that supplied the value is named: .env.local, not a settings file that merely mentions the key|ps:pi proj:mixed|review|1|-|project:codex:pi:.env.local refused:codex:1|$NONE
a commented key under [env] declares nothing and names no file|ps:pi proj:comment|review|1|-|undeclared:pi refused:undeclared:1|$NONE
a key under a table the loader never reads declares nothing|ps:pi proj:other-table|review|1|-|undeclared:pi refused:undeclared:1|$NONE
a padded ps result still resolves to the harness|ps-pad:claude|review|0|<out>|$CLAUDE_SESSION
control: a padded bystander name is still not a harness|ps-pad:codex-wrapper|review|1|-|undetected refused:undeclared:1|$NONE
"

run_table "harness identity" "$DEFAULTS" "$ROWS"
finish
