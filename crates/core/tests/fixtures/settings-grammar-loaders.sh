#!/usr/bin/env bash
# Observe what the real shell loaders do with every row of
# fixtures/settings-grammar.tsv, one `name<TAB>env-sh<TAB>settings-sh` line
# per row on stdout. The Rust side compares those observations with the
# row's recorded verdict AND with what settings_template::read says, so the
# reader and the loaders are pinned to one grammar.
#
# usage: settings-grammar-loaders.sh REPO_ROOT CORPUS
# Errexit is on, and every loader call is guarded by `||` or an `if`: their
# nonzero exits are the observation, and nothing else here may fail quietly.
set -euo pipefail

root="$1"
corpus="$2"
work="$(mktemp -d)"
trap 'rm -rf -- "${work:?}"' EXIT
file="$work/kendex.settings.toml"

# Verdict for one file under skills/orch/scripts/lib/kendex-env.sh: the load
# either fails loud, exports the key, or reads past it in silence.
env_sh() { # KEY -> loads:VALUE | refused | unread
  (
    # shellcheck source=/dev/null
    source "$root/skills/orch/scripts/lib/kendex-env.sh" 2>/dev/null
    kendex_load_settings_file "$file" >/dev/null 2>&1 || { echo refused; exit 0; }
    if value="$(printenv "$1")"; then echo "loads:$value"; else echo unread; fi
  )
}

# The same file under skills/review-gate/scripts/lib/settings.sh. A key name
# that resolver refuses outright reads nothing, which is the same answer as
# a table it walks past.
settings_sh() { # KEY -> loads:VALUE | refused | unread
  (
    cd "$work" || exit 1
    # shellcheck source=/dev/null
    source "$root/skills/review-gate/scripts/lib/settings.sh" 2>/dev/null
    rg_env_table "$file" >/dev/null 2>&1 || { echo refused; exit 0; }
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo unread; exit 0; }
    REVIEW_GATE_SETTINGS_FILE="$file"
    export REVIEW_GATE_SETTINGS_FILE
    value="$(rg_setting "$1" $'\x01none' 2>/dev/null)" || { echo refused; exit 0; }
    if [ "$value" = $'\x01none' ]; then echo unread; else echo "loads:$value"; fi
  )
}

while IFS=$'\t' read -r name _verdict key _expect body; do
  case "$name" in "" | \#*) continue ;; esac
  printf '%b' "${body//\\n/\\n}" > "$file"
  printf '%s\t%s\t%s\n' "$name" "$(env_sh "$key")" "$(settings_sh "$key")"
done < "$corpus"
