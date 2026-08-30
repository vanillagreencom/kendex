#!/usr/bin/env bash
# In-place carve-outs: a path under .agents that the repo's own kendex.toml
# declares `source = "in-place"`, or any .agents/hooks script, is project
# source — never render output. Without a manifest, or under any other
# declaration, .agents stays a render tree.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

repo="$(new_repo in-place)"
mkdir -p "$repo"
cat >"$repo/kendex.toml" <<'MANIFEST'
schema = 6

[skills.mine]
source = "in-place"

[skills.orch]
source = "kendex"
MANIFEST
commit_paths "$repo" "baseline" README.md
base="$(git -C "$repo" rev-parse HEAD)"

case_verdict() { # LABEL EXPECTED PATH...
  local label="$1" expected="$2"
  shift 2
  git -C "$repo" checkout -q -B "case" "$base"
  git -C "$repo" clean -qfd -e kendex.toml
  commit_paths "$repo" "$label" "$@"
  assert_verdict "$label" "$expected" --repo "$repo" --event push --base "$base" --head HEAD
}

case_verdict "an in-place skill edit alone" false \
  .agents/skills/mine/SKILL.md
case_verdict "a rendered skill beside the same manifest" true \
  .agents/skills/orch/SKILL.md
case_verdict "an undeclared .agents skill stays render output" true \
  .agents/skills/stranger/SKILL.md
case_verdict "an adopted hook script alone" false \
  .agents/hooks/claim.sh
case_verdict "an in-place edit inside an otherwise-render diff" false \
  .agents/skills/mine/scripts/tool.sh .claude/agents/rust.md

# A skill name that merely shares a prefix or suffix with a declared one is
# somebody else's tree.
case_verdict "a prefix of the declared name is not it" true \
  .agents/skills/min/SKILL.md
case_verdict "an extension of the declared name is not it" true \
  .agents/skills/mine2/SKILL.md

# No manifest, no carve-outs: the answer before in-place existed.
norepo="$(new_repo no-manifest)"
commit_paths "$norepo" "baseline" README.md
nobase="$(git -C "$norepo" rev-parse HEAD)"
commit_paths "$norepo" "render edit" .agents/skills/mine/SKILL.md
assert_verdict "without a manifest every .agents path is render output" true \
  --repo "$norepo" --event push --base "$nobase" --head HEAD


# The shape kendex writes, in both its spellings: a bare name, and a quoted
# one where the name needs quoting. A hand edit's indentation, trailing
# value comment and sibling keys do not defeat the anchored matches.
spell="$(new_repo spellings)"
cat >"$spell/kendex.toml" <<'MANIFEST'
schema = 6

[skills."ship it"]
source = "in-place"
enabled = true

  [skills.indented]
  source = "in-place" # kept in place
MANIFEST
commit_paths "$spell" "baseline" README.md
spellbase="$(git -C "$spell" rev-parse HEAD)"
spell_case() { # LABEL EXPECTED PATH
  git -C "$spell" checkout -q -B "case" "$spellbase"
  git -C "$spell" clean -qfd -e kendex.toml
  commit_paths "$spell" "$1" "$3"
  assert_verdict "$1" "$2" --repo "$spell" --event push --base "$spellbase" --head HEAD
}
spell_case "a quoted name with a space" false ".agents/skills/ship it/SKILL.md"
spell_case "an indented declaration with a value comment" false .agents/skills/indented/SKILL.md
# Both names were read, not coarsely carved: an undeclared sibling in the
# same repo still answers true.
spell_case "an undeclared sibling beside them stays render" true .agents/skills/stranger/SKILL.md

# A CRLF manifest is legal TOML; the carriage return must not defeat the
# anchored matches.
crlf="$(new_repo crlf)"
printf 'schema = 6\r\n\r\n[skills.mine]\r\nsource = "in-place"\r\n' >"$crlf/kendex.toml"
commit_paths "$crlf" "baseline" README.md
crlfbase="$(git -C "$crlf" rev-parse HEAD)"
commit_paths "$crlf" "edit" .agents/skills/mine/SKILL.md
assert_verdict "a CRLF manifest still carves" false --repo "$crlf" --event push --base "$crlfbase" --head HEAD

# A legal spelling the reader does not name degrades to the coarse carve:
# an in-place line it could not tie to a name makes every skill path
# project source rather than a guessed name set. The header shapes are the
# two the TOML serializer writes, so a name wearing an apostrophe, a space
# outside the quotes, or an escape is not a name here; the value shapes
# are the one kendex writes, so a value that decodes to in-place without
# any line spelling it counts as a mention and cannot be accounted.
for unnamed in whole-table dotted-key inline-table dotted-escape multiline-table \
  nested-table apostrophe-name apostrophe-name-space trailing-space leading-space \
  padded-name quoted-trailing-space spaced-table escaped-name \
  malformed-quoted-name header-comment \
  escaped-value hex-escaped-value split-value quoted-key-split-value; do
  coarse="$(new_repo "coarse-$unnamed")"
  case "$unnamed" in
    whole-table) printf 'schema = 6\nskills = { mine = { source = "in-place" } }\n' ;;
    dotted-key) printf 'schema = 6\nskills.mine.source = "in-place"\n' ;;
    inline-table) printf 'schema = 6\n[skills]\nmine = { source = "in-place" }\n' ;;
    dotted-escape) printf 'schema = 6\nskills."mi\\u006Ee" = { source = "in-place" }\n' ;;
    # A TOML 1.1 multiline inline table puts the value on its own line.
    multiline-table) printf 'schema = 6\n[skills]\nmine = {\n"x.y" = true, source = "in-place",\n}\n' ;;
    # A bare dotted header is skills to a to b, not a skill named a.b.
    nested-table) printf 'schema = 6\n[skills.a.b]\nsource = "in-place"\n' ;;
    apostrophe-name) printf "schema = 6\n[skills.'mine']\nsource = \"in-place\"\n" ;;
    apostrophe-name-space) printf "schema = 6\n[skills.'ship it']\nsource = \"in-place\"\n" ;;
    trailing-space) printf 'schema = 6\n[skills.mine ]\nsource = "in-place"\n' ;;
    leading-space) printf 'schema = 6\n[skills. mine]\nsource = "in-place"\n' ;;
    padded-name) printf 'schema = 6\n[skills. mine ]\nsource = "in-place"\n' ;;
    quoted-trailing-space) printf 'schema = 6\n[skills."mine" ]\nsource = "in-place"\n' ;;
    spaced-table) printf 'schema = 6\n[ skills.mine ]\nsource = "in-place"\n' ;;
    escaped-name) printf 'schema = 6\n[skills."mi\\u006Ee"]\nsource = "in-place"\n' ;;
    malformed-quoted-name) printf 'schema = 6\n[skills."a"b"]\nsource = "in-place"\n' ;;
    header-comment) printf 'schema = 6\n[skills.mine] # kept here\nsource = "in-place"\n' ;;
    # A value no line spells: the escape and the splice both decode to
    # in-place, so each counts as a mention the name rule cannot account.
    escaped-value) printf 'schema = 6\n[skills.mine]\nsource = "in\\u002Dplace"\n' ;;
    hex-escaped-value) printf 'schema = 6\n[skills.mine]\nsource = "in-\\x70lace"\n' ;;
    split-value) printf 'schema = 6\n[skills.mine]\nsource = """in\\\n-place"""\n' ;;
    quoted-key-split-value) printf 'schema = 6\n[skills.mine]\n"source" = """in-\\\nplace"""\n' ;;
  esac >"$coarse/kendex.toml"
  commit_paths "$coarse" "baseline" README.md
  coarsebase="$(git -C "$coarse" rev-parse HEAD)"
  commit_paths "$coarse" "edit" .agents/skills/mine/SKILL.md
  assert_verdict "an unnamed spelling carves its own skill ($unnamed)" false --repo "$coarse" --event push --base "$coarsebase" --head HEAD
  git -C "$coarse" checkout -q -B "case" "$coarsebase"
  git -C "$coarse" clean -qfd -e kendex.toml
  commit_paths "$coarse" "sibling" .agents/skills/other/SKILL.md
  assert_verdict "the coarse carve covers every skill path ($unnamed)" false --repo "$coarse" --event push --base "$coarsebase" --head HEAD
done

# A quoted key delimits the name, so one holding a `]` still reads as that
# one name and carves nothing else.
bracket="$(new_repo bracket-name)"
printf 'schema = 6\n[skills."a]b"]\nsource = "in-place"\n' >"$bracket/kendex.toml"
commit_paths "$bracket" "baseline" README.md
bracketbase="$(git -C "$bracket" rev-parse HEAD)"
commit_paths "$bracket" "edit" ".agents/skills/a]b/SKILL.md"
assert_verdict "a quoted name holding a bracket carves" false --repo "$bracket" --event push --base "$bracketbase" --head HEAD
git -C "$bracket" checkout -q -B "case" "$bracketbase"
git -C "$bracket" clean -qfd -e kendex.toml
commit_paths "$bracket" "sibling" .agents/skills/other/SKILL.md
assert_verdict "a sibling beside the bracket name stays render" true --repo "$bracket" --event push --base "$bracketbase" --head HEAD

# An in-place declaration under another table is not a skill name: the
# header ends the one in scope, so the line goes unaccounted and every
# skill path carves rather than inheriting the last skill's name.
foreign="$(new_repo foreign-table)"
printf 'schema = 6\n[skills.mine]\nsource = "kendex"\n\n[agents.helper]\nsource = "in-place"\n' >"$foreign/kendex.toml"
commit_paths "$foreign" "baseline" README.md
foreignbase="$(git -C "$foreign" rev-parse HEAD)"
commit_paths "$foreign" "edit" .agents/skills/other/SKILL.md
assert_verdict "an in-place agent carves every skill path" false --repo "$foreign" --event push --base "$foreignbase" --head HEAD

# The manifests come from the selected head tree, not the checkout: a head
# that declares the skill carves even when the checkout sits on a commit
# without the declaration, and the head's answer wins in the other
# direction too.
tree="$(new_repo head-tree)"
commit_paths "$tree" "baseline" README.md
treebase="$(git -C "$tree" rev-parse HEAD)"
printf 'schema = 6\n[skills.mine]\nsource = "in-place"\n' >"$tree/kendex.toml"
commit_paths "$tree" "declare and edit" .agents/skills/mine/SKILL.md
treehead="$(git -C "$tree" rev-parse HEAD)"
git -C "$tree" checkout -q "$treebase"
assert_verdict "the head tree's manifest carves from another checkout" false --repo "$tree" --event push --base "$treebase" --head "$treehead"
git -C "$tree" checkout -q "$treehead"
assert_verdict "the same head classifies the same checked out" false --repo "$tree" --event push --base "$treebase" --head "$treehead"

# A source-catalog project declares installs in kendex-local.toml; both
# manifests are read and their carve-outs union.
localrepo="$(new_repo local-manifest)"
printf 'schema = 6\n[marketplace]\nname = "cat"\n' >"$localrepo/kendex.toml"
printf 'schema = 6\n[skills.mine]\nsource = "in-place"\n' >"$localrepo/kendex-local.toml"
commit_paths "$localrepo" "baseline" README.md
localbase="$(git -C "$localrepo" rev-parse HEAD)"
commit_paths "$localrepo" "edit" .agents/skills/mine/SKILL.md
assert_verdict "a kendex-local.toml declaration carves" false --repo "$localrepo" --event push --base "$localbase" --head HEAD
git -C "$localrepo" checkout -q -B "case" "$localbase"
git -C "$localrepo" clean -qfd -e kendex.toml -e kendex-local.toml
commit_paths "$localrepo" "render" .agents/skills/other/SKILL.md
assert_verdict "an undeclared path beside a local manifest stays render" true --repo "$localrepo" --event push --base "$localbase" --head HEAD

# A namespaced declaration covers its whole tree: the declared name matches
# as a path prefix, not as the first segment.
ns="$(new_repo namespaced)"
printf 'schema = 6\n[skills."plugin/item"]\nsource = "in-place"\n' >"$ns/kendex.toml"
commit_paths "$ns" "baseline" README.md
nsbase="$(git -C "$ns" rev-parse HEAD)"
commit_paths "$ns" "edit" .agents/skills/plugin/item/SKILL.md
assert_verdict "a namespaced declaration carves its tree" false --repo "$ns" --event push --base "$nsbase" --head HEAD
git -C "$ns" checkout -q -B "case" "$nsbase"
git -C "$ns" clean -qfd -e kendex.toml
commit_paths "$ns" "sibling" .agents/skills/plugin-other/SKILL.md
assert_verdict "a sibling outside the namespace stays render" true --repo "$ns" --event push --base "$nsbase" --head HEAD

# An equals sign in the repository path must not turn the manifest operand
# into an awk variable assignment: the manifest reaches awk on stdin.
eqrepo="$(new_repo "work=tree")"
printf 'schema = 6\n[skills.mine]\nsource = "in-place"\n' >"$eqrepo/kendex.toml"
commit_paths "$eqrepo" "baseline" README.md
eqbase="$(git -C "$eqrepo" rev-parse HEAD)"
commit_paths "$eqrepo" "edit" .agents/skills/mine/SKILL.md
assert_verdict "an equals-sign repo path still carves" false --repo "$eqrepo" --event push --base "$eqbase" --head HEAD

# A symlinked manifest reads back as link text, not manifest content: it is
# unclassifiable and carves.
sym="$(new_repo symlinked)"
printf 'schema = 6\n[skills.mine]\nsource = "in-place"\n' >"$sym/real.toml"
ln -s real.toml "$sym/kendex.toml"
commit_paths "$sym" "baseline" README.md
symbase="$(git -C "$sym" rev-parse HEAD)"
commit_paths "$sym" "edit" .agents/skills/mine/SKILL.md
assert_verdict "a symlinked manifest carves" false --repo "$sym" --event push --base "$symbase" --head HEAD

# An entry the tree lists but whose blob will not read is unclassifiable:
# the loose object is deleted and the read failure carves.
gone="$(new_repo missing-blob)"
printf 'schema = 6\n[skills.mine]\nsource = "in-place"\n' >"$gone/kendex.toml"
commit_paths "$gone" "baseline" README.md
gonebase="$(git -C "$gone" rev-parse HEAD)"
commit_paths "$gone" "edit" .agents/skills/mine/SKILL.md
blob="$(git -C "$gone" rev-parse "HEAD:kendex.toml")"
rm -f -- "$gone/.git/objects/${blob%??????????????????????????????????????}/${blob#??}"
assert_verdict "a listed manifest whose blob will not read carves" false --repo "$gone" --event push --base "$gonebase" --head HEAD

report in-place
