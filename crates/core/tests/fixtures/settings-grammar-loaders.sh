#!/usr/bin/env bash
# Observe what the real shell loaders do with every row of
# fixtures/settings-grammar.tsv, one `name<TAB>env-sh<TAB>settings-sh` line
# per row on stdout. The Rust side compares those observations with the
# row's recorded verdict AND with what settings_template::read says, so the
# reader and the loaders are pinned to one grammar.
#
# usage: settings-grammar-loaders.sh REPO_ROOT CORPUS
#
# The caller's environment is not an input to any of this. Both loader
# families give an exported variable precedence over the file, so a probe
# taken under an ambient value for the key it is about would be a reading of
# the caller — and a harness that can report a wrong verdict is worse than
# no harness, because it looks authoritative. Every probe therefore starts
# by unsetting what it is about to ask about.
#
# Errexit is on, and every loader call is guarded by `||` or an `if`: their
# nonzero exits are the observation, and nothing else here may fail quietly.
set -euo pipefail

# Absolute, because each probe runs from somewhere else: a relative root
# leaves the `source` below reading nothing, and a resolver that was never
# defined answers every row `refused`.
root="$(cd -- "$1" && pwd)"
corpus="$2"
env_lib="$root/skills/orch/scripts/lib/kendex-env.sh"
settings_lib="$root/skills/review-gate/scripts/lib/settings.sh"
for lib in "$env_lib" "$settings_lib"; do
  [ -r "$lib" ] || { echo "cannot read the loader at $lib" >&2; exit 1; }
done

work="$(mktemp -d)"
trap 'rm -rf -- "${work:?}"' EXIT
file="$work/kendex.settings.toml"

# Whether a shell can hold a variable of this name at all. Both loaders skip
# every other name in silence, and neither the indirect expansion below nor
# `unset` will take one.
holdable() { # NAME — 0 = a shell identifier
  case "$1" in "" | [0-9]* | *[!A-Za-z0-9_]*) return 1 ;; esac
}

# Verdict for one file under skills/orch/scripts/lib/kendex-env.sh: the load
# either fails loud, assigns the key, or reads past it in silence.
env_sh() { # KEY -> loads:VALUE | refused | unread
  (
    unset -v "$1" 2>/dev/null || :
    # shellcheck source=/dev/null
    source "$env_lib"
    kendex_load_settings_file "$file" >/dev/null 2>&1 || { echo refused; exit 0; }
    # The shell's own variable, not `printenv`: this answers whether the
    # load created one. `printenv` would only answer whether one exists,
    # which for an inherited name is true however the file reads — and for
    # a name no shell can hold it is true while nothing ever read it.
    holdable "$1" && [ -n "${!1+set}" ] || { echo unread; exit 0; }
    printf 'loads:%s\n' "${!1}"
  )
}

# The same file under skills/review-gate/scripts/lib/settings.sh. A key name
# that resolver refuses outright reads nothing, which is the same answer as
# a table it walks past.
settings_sh() { # KEY -> loads:VALUE | refused | unread
  (
    unset -v "$1" 2>/dev/null || :
    # This resolver reads two names of its own: REVIEW_GATE_MODE is a
    # per-key exception in it, and REVIEW_GATE_SETTINGS_FILE selects which
    # sources answer at all. Which file a corpus row is about is settled
    # here, never by whoever ran the script.
    unset -v REVIEW_GATE_MODE
    cd "$work"
    # shellcheck source=/dev/null
    source "$settings_lib"
    rg_env_table "$file" >/dev/null 2>&1 || { echo refused; exit 0; }
    holdable "$1" || { echo unread; exit 0; }
    export REVIEW_GATE_SETTINGS_FILE="$file"
    value="$(rg_setting "$1" $'\x01none' 2>/dev/null)" || { echo refused; exit 0; }
    [ "$value" != $'\x01none' ] || { echo unread; exit 0; }
    printf 'loads:%s\n' "$value"
  )
}

while IFS=$'\t' read -r name _verdict key _expect body; do
  case "$name" in "" | \#*) continue ;; esac
  printf '%b' "${body//\\n/\\n}" > "$file"
  printf '%s\t%s\t%s\n' "$name" "$(env_sh "$key")" "$(settings_sh "$key")"
done < "$corpus"
