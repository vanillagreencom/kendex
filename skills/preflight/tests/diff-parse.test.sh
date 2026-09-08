#!/usr/bin/env bash
# Diff-parse hardening. Everything between the changed-file list and a lane's
# added lines: the attributes rows that can withhold hunks, the content test
# that decides what is binary, the index revspec that fetches a staged blob,
# the patch parser's file-header anchor, and the read failures that must not
# become a clean verdict. docs-cited-paths is the vehicle throughout: one
# added line, one finding, and any loss of it is a scan reported but never
# performed.
#
# Every row pins the WHOLE fired set, so a forgery that stole another file's
# record reddens the row whether the victim's finding vanished or the carrier
# gained one. Split from `modes.test.sh`, which keeps the scope contract.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The one dead citation every victim file carries, on its line 3.
CITE='# Staged

See `docs/gone.md` for the rest.
'

# A text carrier whose third added line forges a file header. Both forging
# fixtures share the shape that makes the loss happen: the carrier sorts
# AFTER the victim and writes at least one row under its OWN name before
# forging, so the forged rows arrive as a second, non-adjacent group.
forge_carrier() { # PATH — relative to $R
  printf 'seed\nnormal\n++ b/docs/staged.md\njunk\n' >"$R/$1"
}

# One world per row, seeded and planted from scratch, so no row depends on the
# row before it. A world whose mechanism git has to cooperate with checks that
# it did and refuses loudly when it did not: a fixture that stopped reproducing
# the shape would otherwise leave its row passing on nothing.
#
# The temp-path literals are substituted at run time: the generated fixture
# carries them by design, while this suite's own committed bytes never join a
# creation call to one.
pf_world() {
  pf_scope_seed "$1"
  case "$1" in
    # A committed '-diff' (or 'binary') row makes git call a path binary, and
    # the patch then says "Binary files ... differ" with no hunks at all:
    # every line-scoped lane would have nothing to read while the run still
    # counted the file as changed. One row would take a whole extension out
    # of reach.
    attrs-none | attrs-nodiff | attrs-macro)
      printf '%s' "$CITE" >"$R/docs/staged.md"
      git -C "$R" add docs/staged.md
      case "$1" in
        attrs-nodiff) printf '*.md -diff\n' >"$R/.gitattributes" ;;
        attrs-macro) printf '*.md binary\n' >"$R/.gitattributes" ;;
      esac
      if [ "$1" != attrs-none ]; then
        git -C "$R" add .gitattributes
      fi
      if [ "$1" = attrs-nodiff ]; then
        PRECOND="$(git -C "$R" diff --cached --no-ext-diff -- docs/staged.md)"
        case "$PRECOND" in
          *'Binary files'*) ;;
          *)
            printf "pf_world: '*.md -diff' left the unpinned diff carrying hunks: %s\n" "$PRECOND" >&2
            return 1
            ;;
        esac
      fi
      ;;
    # The base scope reads the same patch shape against the merge base.
    attrs-base)
      printf '*.md -diff\n' >"$R/.gitattributes"
      git -C "$R" add .gitattributes
      git -C "$R" commit -qm attrs
      printf '%s' "$CITE" >"$R/docs/staged.md"
      ;;
    # The other half: forcing text is not a licence to decode an asset.
    # Content is the judge in every scope, so binary bytes contribute no lines
    # and no finding built from them; the same bytes without the NUL do.
    binary-nul | binary-nonul)
      case "$1" in
        binary-nul) printf 'PNG\000See `docs/gone.md` for the rest.\n' >"$R/docs/staged.md" ;;
        binary-nonul) printf 'PNG See `docs/gone.md` for the rest.\n' >"$R/docs/staged.md" ;;
      esac
      git -C "$R" add docs/staged.md
      ;;
    # git calls a blob binary on a NUL in its LEADING 8000 BYTES and reads the
    # rest as text. A wider window would drop a file git reads as text, taking
    # its added lines out of every lane while the run still counted it changed.
    binary-window)
      {
        printf '# Staged\n\n'
        printf 'See `docs/gone.md` for the rest.\n'
        head -c 20000 /dev/zero | tr '\0' 'x'
        printf '\n\000\n'
      } >"$R/docs/staged.md"
      git -C "$R" add docs/staged.md
      ;;
    # The other half of "no lines": a file whose lines are withheld is still a
    # CHANGED FILE, and the whole-file lanes judge the path, not the content —
    # no amount of binary content makes a new suite wired. The temp-path line
    # is what makes the control mean something: it is a line-scoped finding on
    # that same path, and the NUL is the only reason it stays quiet.
    binary-wholefile-nul | binary-wholefile-text)
      mkdir -p "$R/tests" "$R/.github/workflows"
      printf 'name: ci\non: push\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: bash tests/other.test.sh\n' \
        >"$R/.github/workflows/ci.yml"
      git -C "$R" add -A
      git -C "$R" commit -qm ci
      case "$1" in
        binary-wholefile-nul)
          printf '#!/usr/bin/env bash\nset -euo pipefail\nmkdir -p %s/preflight-fixture\n# \000\n' \
            /tmp >"$R/tests/new.test.sh"
          ;;
        binary-wholefile-text)
          printf '#!/usr/bin/env bash\nset -euo pipefail\nmkdir -p %s/preflight-fixture\n# x\n' \
            /tmp >"$R/tests/new.test.sh"
          ;;
      esac
      git -C "$R" add tests/new.test.sh
      ;;
    # A committed blob whose own bytes spell a patch header. Forcing --text
    # hands every changed file's raw content to the patch parser unless content
    # is judged FIRST: a line reading '++ b/<path>' renders with the '+' prefix
    # as a file header at column 1, re-points the parser at that path, and the
    # record split then reopens and truncates it — destroying another file's
    # added lines.
    binary-forged-header)
      printf '%s' "$CITE" >"$R/docs/staged.md"
      printf 'PNG\000\n++ b/docs/staged.md\n+junk\n' >"$R/zz.bin"
      git -C "$R" add -A
      ;;
    # The index revspec carries its stage: `:0:PATH`, never a bare `:PATH`.
    # Under the bare form git reads a leading `0:` through `3:` in the path AS
    # the stage selector, so `0:asset` asks for the blob at `asset` instead.
    # That lookup either lands on another file's bytes or fails outright, and a
    # failure drops the path out of the binary exclusion, where --text hands its
    # raw content to the patch parser and the forged header goes live again.
    #
    # The victim is dot-named on purpose. git orders the patch by path, and the
    # record split truncates a file's collected lines only when its path is
    # reopened after another one, so the forging file has to come SECOND.
    stage-prefixed-path | stage-prefixed-control)
      printf '%s' "$CITE" >"$R/.top.md"
      case "$1" in
        stage-prefixed-path) printf 'PNG\000\n++ b/.top.md\n+junk\n' >"$R/0:asset" ;;
        stage-prefixed-control) printf 'PNG\000\n+junk\n' >"$R/0:asset" ;;
      esac
      git -C "$R" add -- .top.md '0:asset'
      ;;
    # The other half of the bare form: a sibling sits at the shortened path,
    # the lookup succeeds, and the binary verdict is taken over bytes belonging
    # to a different file.
    stage-prefixed-sibling)
      printf '%s' "$CITE" >"$R/0:doc.md"
      printf 'PNG\000binary\n' >"$R/doc.md"
      git -C "$R" add -- '0:doc.md' doc.md
      ;;
    # The header state machine, pinned where excluding carriers cannot reach.
    # `+++ b/<path>` is a file header only where git can have written one:
    # inside the preamble a `diff --git` line opens, directly after `--- `. A
    # hunk BODY spells the same shape at column 0 whenever an added line reads
    # `++ b/<path>`, and an unanchored parser hands the victim's record to the
    # carrier. Variant one is a NUL-free blob a committed `-diff` row marks
    # binary: the --text pin gives it hunks it would not otherwise have had,
    # and content classification correctly calls it text, so nothing excludes
    # it. Only the anchor closes this.
    attributed-text-forged | attributed-text-plain)
      printf '%s' "$CITE" >"$R/docs/staged.md"
      printf '*.txt -diff\n' >"$R/.gitattributes"
      case "$1" in
        attributed-text-forged) forge_carrier zz.txt ;;
        attributed-text-plain) printf 'seed\nnormal\njunk\n' >"$R/zz.txt" ;;
      esac
      git -C "$R" add -A
      if [ "$1" = attributed-text-forged ]; then
        PRECOND="$(git -C "$R" -c core.quotePath=false diff --cached --no-color --unified=0 -- zz.txt)"
        case "$PRECOND" in
          *'Binary files'*) ;;
          *)
            printf "pf_world: the '-diff' row left zz.txt's unpinned diff carrying hunks: %s\n" "$PRECOND" >&2
            return 1
            ;;
        esac
      fi
      ;;
    # Variant two: no attributes row at all. A plain text file reaches the
    # parser by every route, on every scope, with nothing to exclude it by.
    plain-text-forged | plain-text-plain)
      printf '%s' "$CITE" >"$R/docs/staged.md"
      case "$1" in
        plain-text-forged) forge_carrier zz.txt ;;
        plain-text-plain) printf 'seed\nnormal\njunk\n' >"$R/zz.txt" ;;
      esac
      git -C "$R" add -A
      ;;
    # A flag set by `--- ` alone would still be forgeable: with --unified=0 a
    # hunk emits its removed lines before its added ones, so ONE hunk that
    # replaces a line reading `-- a/<x>` with one reading `++ b/<victim>`
    # spells the whole header pair at column 0. `diff --git` is the record no
    # body can spell, which is why the flag is anchored there.
    #
    # Every half of the shape matters, so the world checks it: the first hunk
    # gives the carrier a record under its OWN name, without which there is
    # nothing to reopen and nothing to truncate; the second spells the pair on
    # ADJACENT records, which is what a flag set by `--- ` alone accepts, and
    # puts an added line AFTER it, without which the forged header re-points
    # at nothing.
    forged-header-pair)
      printf 'seed\nfiller\n-- a/x\ntail\n' >"$R/zz.txt"
      git -C "$R" add zz.txt
      git -C "$R" commit -qm carrier
      printf '%s' "$CITE" >"$R/docs/staged.md"
      printf 'seed\nnormal\nfiller\n++ b/docs/staged.md\njunk\ntail\n' >"$R/zz.txt"
      git -C "$R" add -A
      PRECOND="$(git -C "$R" diff --cached --no-color --unified=0 -- zz.txt |
        grep -A2 -e '^--- a/x$' | tr '\n' '|')"
      case "$PRECOND" in
        '--- a/x|+++ b/docs/staged.md|+junk|') ;;
        *)
          printf 'pf_world: the hunk body does not spell the header pair with a line after it: %s\n' \
            "$PRECOND" >&2
          return 1
          ;;
      esac
      ;;
    # The forged line is not swallowed either: it is content of the file that
    # carries it, so a lane scanning that file's added lines still sees it.
    forged-line-is-content)
      printf 'seed\nnormal\n++ b/docs/staged.md\nmkdir -p %s/preflight-fixture\n' /tmp >"$R/zz.txt"
      git -C "$R" add -A
      ;;
    # A read that FAILS is not a verdict of "no lines". The path is already
    # inside the changed-file count, so a silent skip would print a clean total
    # covering content no lane read — the exact shape every pin above closes.
    unreadable | readable)
      printf '# New\n\nSee `docs/gone.md` for the rest.\n' >"$R/docs/new.md"
      if [ "$1" = unreadable ]; then chmod 000 "$R/docs/new.md"; fi
      ;;
    # Staged scope reads the index, so the failure is the index lookup's: the
    # blob the change set just listed cannot be materialized. The path stays in
    # the changed-file count either way, so a silent skip here is the same
    # clean verdict over unread content, arriving through the other scope.
    vanished-blob-control | vanished-blob)
      printf '# New\n\nSee `docs/gone.md` for the rest.\n' >"$R/docs/new.md"
      git -C "$R" add docs/new.md
      if [ "$1" = vanished-blob ]; then
        OID="$(git -C "$R" rev-parse :0:docs/new.md)"
        if [ ! -f "$R/.git/objects/${OID:0:2}/${OID:2}" ]; then
          printf 'pf_world: the staged blob is not a loose object at the expected path: %s\n' "$OID" >&2
          return 1
        fi
        rm -f -- "$R/.git/objects/${OID:0:2}/${OID:2}"
      fi
      ;;
    *)
      printf 'pf_world: no such world: %s\n' "$1" >&2
      return 1
      ;;
  esac
}

# `read -d ''` rather than `$(cat <<'ROWS' ...)`: Bash 3.2 scans a here-document
# inside a command substitution for quotes, and a row carrying an odd number
# of double quotes runs its parse past the closing parenthesis. It returns 1
# at the end of the document, which errexit must not read; an empty table is
# pf_table's refusal.
IFS= read -r -d '' rows <<'ROWS' || :
control: the added dead citation fires with no attributes row|attrs-none|--staged|-|1|docs/staged.md:3: [docs-cited-paths]|-
--staged still reads the added line under a '-diff' row|attrs-nodiff|--staged|-|1|docs/staged.md:3: [docs-cited-paths]|-
the 'binary' attribute macro cannot withhold them either|attrs-macro|--staged|-|1|docs/staged.md:3: [docs-cited-paths]|-
--base still reads the added line under a '-diff' row|attrs-base|-|-|1|docs/staged.md:3: [docs-cited-paths]|-
a changed file whose own bytes are binary contributes no lines|binary-nul|--staged|-|0|-|preflight: clean=1
control: the same bytes without the NUL are read as text|binary-nonul|--staged|-|1|docs/staged.md:1: [docs-cited-paths]|-
a NUL past the leading 8000 bytes leaves the file text, as it is to git|binary-window|--staged|-|1|docs/staged.md:3: [docs-cited-paths]|-
a binary file still reaches the whole-file lanes; only its lines are withheld|binary-wholefile-nul|--staged|-|1|tests/new.test.sh:0: [unwired-suite]|-
control: without the NUL the same fixture fires on the line too|binary-wholefile-text|--staged|-|1|tests/new.test.sh:0: [unwired-suite];tests/new.test.sh:3: [hardcoded-temp-path]|-
a binary blob cannot forge a patch header over another file's lines|binary-forged-header|--staged|-|1|docs/staged.md:3: [docs-cited-paths]|-
--base holds the same line against the forged header|binary-forged-header|-|-|1|docs/staged.md:3: [docs-cited-paths]|-
a path named for a stage selector cannot forge a header over another file's record|stage-prefixed-path|--staged|-|1|.top.md:3: [docs-cited-paths]|-
control: the same fixture without the injected header line reports the same finding|stage-prefixed-control|--staged|-|1|.top.md:3: [docs-cited-paths]|-
a stage-prefixed path is judged on its own bytes, not on its shortened sibling's|stage-prefixed-sibling|--staged|-|1|0:doc.md:3: [docs-cited-paths]|-
an attributed-text carrier cannot forge a header over another file's record|attributed-text-forged|--staged|-|1|docs/staged.md:3: [docs-cited-paths]|-
control: the same fixture without the forged line reports the same finding|attributed-text-plain|--staged|-|1|docs/staged.md:3: [docs-cited-paths]|-
a plain text carrier cannot forge a header over another file's record|plain-text-forged|--staged|-|1|docs/staged.md:3: [docs-cited-paths]|-
--base holds the same line against the plain text carrier|plain-text-forged|-|-|1|docs/staged.md:3: [docs-cited-paths]|-
control: the plain text fixture without the forged line reports the same finding|plain-text-plain|--staged|-|1|docs/staged.md:3: [docs-cited-paths]|-
a forged '---'/'+++' PAIR cannot re-point the parse either|forged-header-pair|--staged|-|1|docs/staged.md:3: [docs-cited-paths]|-
a rejected header record leaves the lines after it attributed to their own file|forged-line-is-content|--staged|-|1|zz.txt:4: [hardcoded-temp-path]|-
content the run cannot read is exit 2, naming the path|unreadable|-|nonroot|2|-|docs/new.md
control: the same file readable produces the ordinary verdict|readable|-|-|1|docs/new.md:3: [docs-cited-paths]|-
control: the staged file reports the ordinary verdict while its blob is readable|vanished-blob-control|--staged|-|1|docs/new.md:3: [docs-cited-paths]|-
a staged blob the index lookup cannot materialize is exit 2, naming the path|vanished-blob|--staged|-|2|-|docs/new.md
ROWS
pf_table "what the diff parse may withhold" "$rows"

pf_summary
