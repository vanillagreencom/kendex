#!/usr/bin/env bash
# ---
# name: command-safety
# event: PreToolUse
# matcher: Bash
# description: On harnesses that execute hooks, refuse supported relative recursive deletes, git init and .git output writes reachable after a failed cd in a flat literal list. Refuse cat reads of the known ~/.fleet/env spellings. Refuse a recognized whole-environment read where the shell runs it, unless a proven direct pipe filters named variables: at a command head, among the forwarded operands of a shell or source script, orch-runtime launch-job, a shell command string, exec or builtin, and in composed env -S argv, in selected shell, eval or env -S source, in literal input a shell, exec or builtin gets, and in heredoc bodies an unknown receiver gets. Words elsewhere are data. This fixed check runs outside Git and before project policy. Nested dumps can refuse conservatively. It reads submitted text, not unseen programs, aliases or runtime-built commands. COMMAND_SAFETY_HISTORY_POLICY=no-lazy-fetch optionally requires literal global --no-lazy-fetch before reached Git history/diff subcommands, metadata and worktree diff included; off or absent preserves ordinary reads. COMMAND_SAFETY_DENY_PATTERN replaces only the default systemd-run memory-cap pattern; `^$` disables only that project-pattern check. Refuse curl or wget output that a shell or interpreter runs as its program, piped to it or through a substitution, naming the form; refuse an upload (curl -T, a curl data or form file, wget --post-file, scp or rsync to a remote) to a host COMMAND_SAFETY_UPLOAD_HOSTS does not list, empty by default, naming the host, and one an assignment before the program, or before the exec, builtin, eval or shell running it, can route; refuse git push to a repository operand that is neither a remote of the repository nor one of its remote URLs, naming the remote, and an unresolved remote or repository, a push in a command whose git remote or git config can change a remote included, and any other git word of a command whose git config can define an alias, or one a GIT_CONFIG_COUNT, GIT_CONFIG_KEY_, GIT_CONFIG_VALUE_ or GIT_CONFIG_PARAMETERS assignment reaches. A command those checks pass with a stage that holds curl, wget, scp, rsync or git push and is not plain literal argv in a plain pipeline is reported with a would= line. An exact command in the hook's own environment variable COMMAND_SAFETY_OWNER_COMMAND passes those three; a command with a word that names it refuses, except as an argument of grep, rg or cat.
# summary: Refuses commands that `cat` the private environment file or print the whole environment, pipe or feed a download into a shell, upload to a host the project has not listed, push to a remote the repository does not have, or match the project's deny pattern, which by default stops a small systemd-run memory cap. The owner allows one exact download, upload or push by starting the session with it in COMMAND_SAFETY_OWNER_COMMAND.
# safety: The targeting check uses existing flat stages, literal executable/operand roles and list separators; a failed cd can reach a relative recursive rm, direct git init or .git output redirect only on an executing path. Earlier cd failures remain possible after later changes. Unknown, nested, forwarded, assignment, glob/brace/tilde and unsupported invocation forms provide no targeting proof; independent environment checks still run. Classify literal command producers at executable positions, with one producer grammar: command heads, each forwarded operand of a shell or source script, orch-runtime launch-job, a shell command string, exec or builtin, composed env -S argv, selected shell, eval and env -S source, each literal body a shell, exec or builtin gets, and each heredoc body an unknown receiver gets, judged alone as shell source. Known interpreters at a stage's own head use language-specific whole-environment evidence, which also judges input to exec, builtin and syntax-only stages, piped input included; literal cat bodies retain their data contract. Text a shell or source script or orch-runtime launch-job forwards keeps a conservative word test. Unquoted body expansions are checked independently. Known private-file cat reads cannot be filtered into permission. Only proven direct named-variable filters grant environment-producer dump permission; project-pattern matching remains independent and reads the submitted text. Selected Git history admission consumes decoded executable argv through one Git decision; it grants no count, ref, path, format or environment-only exception. Not reached: unseen programs and runtime-built names; an unknown launcher or non-producer reader inside reserved-word syntax, such as if true; then timeout 5 env; fi; the same command as a quoted forwarded argument when the launcher stage redirects its output; the same command inside a body an unknown receiver gets; here-string input to any stage other than a shell, eval or source and an exec, builtin or syntax-only stage, an unknown program and a Python, Node, Ruby or Perl head alike, such as ssh host <<< env or python3 <<< os.environ; an interpreter body that is forwarded or nested in shell source, such as bash wrapper.sh python3 <<'EOF'; a cd, pushd or popd that eval, source or . runs in the same shell, for an environ read after that text, such as eval 'cd /proc/self'; cat environ; and a trap action word, such as trap 'env' EXIT. An undecoded ANSI-C escape refuses with reason=undecoded-ansi-escape under the keyed line in a command head or a producer argument or input; an ANSI-C escaped word judged as shell source, or redirected as input to a shell, source, eval, exec, builtin, script-operand or compound shell stage, refuses with no producer in it and even where that stage reads it as data, such as while read -r a b; do :; done <<< $'x 1\ny 2' or { cat; } <<< $'a\tb'; piped, it refuses only for a shell, source or eval receiver, and an exec, builtin or compound receiver reads it as data. Unreadable payloads or policy support warn and allow their affected check. Every diagnostic starts with command-safety: <key>=<value>. Download, upload and push facts come from the same producer and Git argv walk, where a shell runs the text and never in a body an unknown receiver gets: a download stage, or a command carrying it in a substitution, piped within its pipeline to a stage that runs its input, any stage of a subshell or the first command of a brace group included, stdin script paths included, or in a substitution its enclosing shell or interpreter takes as its program word or input; curl, wget, scp and rsync argv read with their recorded argument options, an unlisted option read as a flag and an abbreviation of a sending or routing option, an assignment before the program word, NAME= or NAME+=, or before the exec, builtin, eval, shell or script that runs it, or an expanding or substituted host unresolved, through the words after a substitution that splits the command; a push judged in every reader directory with git remote -v and ls-remote --get-url, an expanding or substituted operand, an unread Git global word whose first later literal word that is no option or option argument is push, and Git configuration, a GIT_ variable or an inline alias its command sets, or a git remote or git config anywhere in the command that can change a remote, unresolved, for every push of the command, and a git config that can define an alias makes every other git word of the command such a push, as a GIT_CONFIG_COUNT, GIT_CONFIG_KEY_, GIT_CONFIG_VALUE_ or GIT_CONFIG_PARAMETERS assignment makes the git word it reaches; a cd, env -C or git -C operand with an unquoted leading ~, a cd a launcher runs, such as builtin cd, any cd in text eval, source or . runs in the same shell, and a relative cd that CDPATH can search in a command with a word naming CDPATH leave the push's repository unresolved; that cd, and in such a command a cd, pushd or popd whose destination the walk does not follow, such as CDPATH=/proc cd self or cd -P self, also leave the directory of a later relative environ read in the same shell source unresolved, so CDPATH=/proc; cd self && cat environ refuses. Each literal curl, wget, scp, rsync or git word after an unresolved launcher is judged as that program's head, and an interpreter's script operand counts only after no option. The plain-stage rule reports and does not refuse: a command these checks pass with a stage holding such a word, or git with a later push, that is not plain, literal words with no expansion, substitution, glob, brace or line continuation, in no group, subshell, substitution or compound command, in a pipeline of plain stages, gets a report=plain-stage notice with one would= line per check naming its program and cause. A word naming COMMAND_SAFETY_OWNER_COMMAND refuses except as a grep, rg or cat argument. Not reached: a receiver behind an unresolved launcher, a sender in a brace group or compound command, a later command of a brace group that reads the pipe, a push behind an unread Git global word that takes the next literal word as its argument, a download passed through a variable, output substitutions, forwarded receivers of a substitution, ssh config aliases, Git configuration an earlier command or a file write sets, variables or aliases an earlier command or file sets, an export, declare -x or typeset -x earlier in the same command, the commands inside a sourced script or script file, a CDPATH the session's shell already holds, an alias that a configuration file a variable assigned before git names, such as GIT_CONFIG_GLOBAL or HOME, defines, other upload programs, a program that makes its own network calls, and runtime-built names.
# timeout: 10
# requires-skills: [commit-guards]
# ---

set -euo pipefail

# Git owns object access. A harness permission pattern cannot distinguish a
# global native fence from a path or option operand. Consume only the argv
# the existing producer selected; never search shell text for history words.
# Native option: Git v2.45.0 git.c. The fence first holds for diff prefetch
# in Git v2.45.1, whose promisor-remote.c fetch_objects honours it. The
# global options below are handle_options in git.c at v2.45.1 and master:
# Git refuses any other one, and takes -C only detached.
# Each refused read is one record of its reason and its -C chain. Outside a
# worktree that chain alone names the project whose policy judges the read.
# A launched git word may be data rather than the program, and since Git
# refuses any unlisted option, such an option there ends its judgment.
# The same walk finds a push for push_argv, outside a body an unknown
# receiver gets. Any configuration a push's own command sets can choose
# where or through what program it goes, a transport, a proxy or a URL
# rewrite, and an alias can make any word a push, so each leaves the remote
# unresolved; a repository option leaves the repository unresolved. So does
# a word the hook cannot read where a global option can stand, when the walk
# past it finds push as the subcommand.
# git_walk selects the history judgment, the push or both.
history_git_argv() { # START [launched]
  local cursor=$1 launched=${2:-} value fenced="" reason="" state=relative words=() tildes=() dirs=() assigned_name tilde_push=""
  local push_at="" push_reason="" push_state setting="" unread="" unread_push="" launch_names
  [ -n "${transfer_ignored:-}" ] || [ "${git_walk:-both}" = history ] || push_git_heads=$((push_git_heads + 1))
  # An assignment before the git word applies to it, and so does one before
  # the exec, eval or shell that runs it. Git reads these variables as
  # inline configuration, as it reads -c, so they can define an alias
  # (git-config(1) ENVIRONMENT).
  launch_assignments $(($1 - 1))
  for assigned_name in $launch_names; do
    case "$assigned_name" in GIT_CONFIG_COUNT | GIT_CONFIG_KEY_* | GIT_CONFIG_VALUE_* | GIT_CONFIG_PARAMETERS) setting='alias' ;; esac
  done
  while [ "$cursor" -lt "${#args[@]}" ]; do
    value=${args[$cursor]}
    [ "${arg_kinds[$cursor]}" = literal ] || { reason=unresolved-git-argv; unread=$cursor; unread_push=repository; break; }
    case "$value" in
      --no-lazy-fetch) fenced=1 ;;
      -C | -c | --git-dir | --work-tree | --namespace | --config-env | --shallow-file | --attr-source)
        cursor=$((cursor + 1))
        if [ "${arg_kinds[$cursor]:-}" != literal ]; then
          reason=unresolved-git-argv; unread=$((cursor + 1))
          case "$value" in -C | --git-dir | --work-tree) unread_push=repository ;; -c | --config-env) unread_push=remote ;; esac
          break
        fi
        # An inline alias stays one whatever setting follows it.
        case "$value" in -c | --config-env) setting=${setting:-1} ;; --git-dir | --work-tree) push_reason=repository ;; esac
        case "$value" in -c | --config-env) ! alias_key "${args[$cursor]}" || setting='alias' ;; esac
        if [ "$value" = -C ]; then words[${#words[@]}]=${args[$cursor]}; tildes[${#tildes[@]}]=${arg_unquoted[$cursor]%%:*}; fi ;;
      -c?* | --config-env=*)
        setting=${setting:-1}
        ! alias_key "${value#-c}" || setting='alias'
        ! alias_key "${value#--config-env=}" || setting='alias' ;;
      --git-dir=* | --work-tree=*) push_reason=repository ;;
      # Git runs its subcommands from the exec path.
      --exec-path=*) setting=${setting:-1} ;;
      -C?* | --namespace=* | --attr-source=*) ;;
      -p | --paginate | -P | --no-pager | --bare | --no-replace-objects | --no-optional-locks | --no-advice | --literal-pathspecs | --no-literal-pathspecs | --glob-pathspecs | --noglob-pathspecs | --icase-pathspecs) ;;
      --version | -v | --help | -h | --exec-path | --html-path | --man-path | --info-path | --list-cmds=*) break ;;
      -*) [ -n "$launched" ] || { reason=unresolved-git-argv; state=unknown; }; break ;;
      *)
        case "$value" in
          log | show | whatchanged | rev-list | diff | diff-tree | diff-index | diff-files | range-diff | format-patch | cherry)
            [ -n "$fenced" ] || reason=missing-no-lazy-fetch ;;
          push) push_at=$((cursor + 1)) ;;
          remote | config) push_config_mark $((cursor + 1)) "$value" ;;
        esac
        [ "$setting" != alias ] || { push_at=$((cursor + 1)); push_config_mark "$push_at" alias; }
        break ;;
    esac
    cursor=$((cursor + 1))
  done
  # The subcommand after an unread word is taken as the first literal word
  # that is no option or option argument. An unread word that expands to an
  # option taking an argument, as -C, makes that word its argument, so a push
  # after it is not judged here; the plain-stage rule reports it.
  if [ -n "$unread" ]; then
    for ((cursor=unread; cursor<${#args[@]}; cursor++)); do
      [ "${arg_kinds[$cursor]}" = literal ] || continue
      case "${args[$cursor]}" in
        -C | -c | --git-dir | --work-tree | --namespace | --config-env | --shallow-file | --attr-source) cursor=$((cursor + 1)) ;;
        -*) ;;
        *)
          case "${args[$cursor]}" in remote | config) push_config_mark $((cursor + 1)) "${args[$cursor]}" ;; esac
          [ "$setting" != alias ] || push_config_mark $((cursor + 1)) alias
          if [ "${args[$cursor]}" = push ] || [ "$setting" = alias ]; then
            push_at=$((cursor + 1))
            if [ "$unread_push" = repository ]; then push_reason=repository; else push_reason=${push_reason:-$unread_push}; fi
          fi
          break ;;
      esac
    done
  fi
  [ -z "${transfer_ignored:-}" ] || push_at=""
  [ "${git_walk:-both}" != history ] || push_at=""
  [ "${git_walk:-both}" != push ] || reason=""
  # An env -S escape, expansion or comment has no decoder here.
  [ -n "$reason" ] || [ -z "${split_undecoded:-}" ] || [ "${git_walk:-both}" = push ] || reason=unresolved-git-argv
  if [ -n "$push_at" ]; then
    [ -z "${split_undecoded:-}" ] || push_reason=${push_reason:-remote}
    [ -z "$setting" ] || push_reason=${push_reason:-remote}
    for assigned_name in $launch_names; do
      case "$assigned_name" in
        GIT_DIR | GIT_WORK_TREE | GIT_COMMON_DIR) push_reason=repository ;;
        GIT_*) push_reason=${push_reason:-remote} ;;
      esac
    done
  fi
  [ -n "$reason$push_at" ] || return 0
  # The shell expands an unquoted leading ~ or ~/, and a glob or brace word,
  # before Git sees it; any other tilde or expanding form leaves the chain
  # unknown. The ~ expands against HOME as it stands when the shell reaches
  # it, which any statement of the command can set first, one a sourced
  # heredoc runs included. A history read outside a work tree is judged only
  # where its chain resolves, so the hook's HOME can only add a refusal
  # there; a push judged in the wrong repository can pass, so the tilde
  # leaves its repository unresolved.
  for ((cursor=0; cursor<${#words[@]}; cursor++)); do
    value=${words[$cursor]}
    case "$value" in
      '~' | '~/'*) if [ -n "${tildes[$cursor]}" ] && [ -n "${HOME:-}" ]; then value=$HOME${value#\~}; tilde_push=1; else state=unknown; fi ;;
      '~'*) state=unknown ;;
    esac
    case "$value" in *'*'* | *'?'* | *'['* | *']'* | *'{'* | *'}'*) state=unknown ;; esac
    [ "$state" != relative ] || [[ $value != /* ]] || state=absolute
    dirs[cursor]=$value
  done
  push_state=$state
  [ -z "$tilde_push" ] || push_state=unknown
  [ "$push_reason" != repository ] || [ -z "$unread" ] || push_state=unknown
  [ -z "$push_at" ] || push_argv "$push_at" "$push_state" "$push_reason" ${dirs[@]+"${dirs[@]}"}
  [ -z "$unread" ] || state=unknown
  [ -n "$reason" ] || return 0
  history_record "$reason" "$state" ${dirs[@]+"${dirs[@]}"}
}

# A remote or Git setting the command changes moves where a push in the same
# command goes, wherever that push stands, since a loop can run the change
# first. git remote changes a remote with any verb but listing, show,
# get-url, add, whose new remote the hook does not find yet, and the
# fetch-side prune, update, set-head and set-branches; git config can write
# unless config_reads proves a read; an inline alias can run either. A
# config write that can define an alias makes every other git word of the
# command a possible push, which push_judge settles.
push_config_mark() { # START SUBCOMMAND
  local cursor=$1 config_action config_operand
  [ -z "${transfer_ignored:-}" ] && [ "${git_walk:-both}" != history ] || return 0
  case "$2" in
    remote)
      while [ "$cursor" -lt "${#args[@]}" ] && [ "${arg_kinds[$cursor]}" = literal ]; do
        case "${args[$cursor]}" in
          -v | --verbose) cursor=$((cursor + 1)) ;;
          show | get-url | add | prune | update | set-head | set-branches) return 0 ;;
          *) break ;;
        esac
      done
      [ "$cursor" -lt "${#args[@]}" ] || return 0 ;;
    config)
      ! config_reads "$cursor" || return 0
      config_alias "$cursor" ;;
  esac
  push_config_changed=1
}

# A Git setting that can define an alias: an alias key, or an include,
# which can read one from another file. Section names ignore case.
alias_key() { # WORD
  case "$1" in [Aa][Ll][Ii][Aa][Ss].* | [Ii][Nn][Cc][Ll][Uu][Dd][Ee].* | [Ii][Nn][Cc][Ll][Uu][Dd][Ee][Ii][Ff].*) return 0 ;; esac
  return 1
}

# A git config write can define an alias where its key names an alias or
# include key or section, as a rename-section target can, where it opens an
# editor, or where the hook cannot read a word that can stand for an option
# or the key. A value after a literal key cannot.
config_alias() { # START
  local cursor last
  config_words "$1"
  case "$config_action" in edit | unknown) push_alias_changed=1; return ;; esac
  last=$config_operand
  [ "$config_action" != rename ] || last=$((last + 1))
  for ((cursor=config_operand; cursor<=last; cursor++)); do
    [ "$cursor" -lt "${#args[@]}" ] || return 0
    [ "${arg_kinds[$cursor]}" = literal ] || { push_alias_changed=1; return; }
    case "${args[$cursor]}" in
      [Aa][Ll][Ii][Aa][Ss] | [Ii][Nn][Cc][Ll][Uu][Dd][Ee] | [Ii][Nn][Cc][Ll][Uu][Dd][Ee][Ii][Ff]) push_alias_changed=1; return ;;
    esac
    ! alias_key "${args[$cursor]}" || { push_alias_changed=1; return; }
  done
}

# git config only reads with its get or list subcommand, or in the legacy
# form with a read action among its options, or with one operand and no
# action.
config_reads() { # START
  config_words "$1"
  case "$config_action" in
    read) return 0 ;;
    '') [ "$((config_operand + 1))" -eq "${#args[@]}" ] && [ "${arg_kinds[$config_operand]}" = literal ] ;;
    *) return 1 ;;
  esac
}

# The one reading of git config's words: config_action is the subcommand or
# option action, read, edit, rename, write, unknown where an option the list
# does not name or a word the hook cannot read stands before the first
# operand, or empty for none, and config_operand is that operand's index.
# Git's parser stops at the first operand, so a later --get or -l is a
# value, and an option that takes an argument, such as --comment, takes the
# next word whatever it reads, where that word stays one field. A word whose
# field count the tokenizer cannot prove, such as $F, can split, and its
# later fields stand where an option or the key stands. Git takes a unique prefix of a long option,
# so an unlisted one can be --edit or --rename-section. Option list: git
# config -h and git config set -h of Git 2.56.1.
config_words() { # START
  local cursor=$1
  config_action=""
  case "${arg_kinds[$cursor]:-}:${args[$cursor]:-}" in
    literal:get | literal:list) config_action=read; return ;;
    literal:edit) config_action=edit; return ;;
    literal:rename-section) config_action=rename; cursor=$((cursor + 1)) ;;
    literal:set | literal:unset | literal:remove-section) config_action=write; cursor=$((cursor + 1)) ;;
  esac
  while [ "$cursor" -lt "${#args[@]}" ]; do
    [ "${arg_kinds[$cursor]}" = literal ] || { config_action=unknown; break; }
    case "${args[$cursor]}" in
      --get | --get-all | --get-regexp | --get-urlmatch | --get-color | --get-colorbool | -l | --list) config_action=read; break ;;
      -e | --edit) config_action=edit; break ;;
      --rename-section) config_action=rename ;;
      --add | --replace-all | --unset | --unset-all | --remove-section) config_action=write ;;
      -f | --file | --blob | -t | --type | --default | --comment | --value)
        cursor=$((cursor + 1))
        [[ ${arg_unquoted[$cursor]:-} != *:fields ]] || { config_action=unknown; break; } ;;
      -f?* | -t?* | --file=* | --blob=* | --type=* | --default=* | --comment=* | --value=*) ;;
      --no-file | --no-blob | --no-type | --no-default | --no-comment | --no-value | --all | --no-all) ;;
      --global | --system | --local | --worktree | --no-global | --no-system | --no-local | --no-worktree) ;;
      -z | --null | --no-null | --name-only | --no-name-only | --show-origin | --no-show-origin | --show-scope | --no-show-scope | --show-names | --no-show-names) ;;
      --bool | --int | --bool-or-int | --bool-or-str | --path | --expiry-date | --fixed-value | --no-fixed-value | --includes | --no-includes) ;;
      --) cursor=$((cursor + 1)); break ;;
      -*) config_action=unknown; break ;;
      *) break ;;
    esac
    cursor=$((cursor + 1))
  done
  config_operand=$cursor
}

# git push -h names the options that take a separate argument; Git takes the
# first other word as the repository, and --repo only when none is given.
# An expanding word, or one where an option could stand, can name any remote.
# Git also takes a unique prefix of a long option, so a long option this
# list does not name exactly can be one that takes the repository as its
# argument, as --exe origin URL does: it leaves the remote unresolved.
# A repository the payload directory and literal directory changes do not
# settle, such as after cd "$DIR", pushd or a GIT_DIR assignment, is
# unresolved, and so is one that does not exist yet when the hook runs,
# which a clone or init earlier in the command can create with its own remote.
push_argv() { # START STATE UNRESOLVED [DIR...]
  local cursor=$1 state=$2 unresolved=$3 value operand="" repository="" options_ended="" directory name
  local effective_dirs=() effective_dirs_unresolved
  # git push -h of Git 2.56.1; each takes --no- too, except no-verify and verify.
  local long=' all atomic branches delete dry-run exec follow-tags force force-if-includes force-with-lease ipv4 ipv6 mirror no-verify porcelain progress prune push-option quiet receive-pack recurse-submodules repo set-upstream signed tags thin verbose verify '
  shift 3
  # A push with no repository can still go where a remote change in the
  # command sends it; the push judgement relates the two once every stage is
  # read.
  push_seen=1
  while [ "$cursor" -lt "${#args[@]}" ]; do
    value=${args[$cursor]}
    if [ -n "$options_ended" ] || [ "${arg_kinds[$cursor]}" != literal ]; then operand=$cursor; break; fi
    case "$value" in
      --) options_ended=1 ;;
      --repo | --receive-pack | --exec | --push-option | --recurse-submodules)
        cursor=$((cursor + 1))
        [ "$value" != --repo ] || repository=$cursor ;;
      --repo=*) repository=$cursor ;;
      --*)
        name=${value%%=*}; name=${name#--}
        case "$long" in *" $name "* | *" ${name#no-} "*) ;; *) unresolved=${unresolved:-remote} ;; esac ;;
      -*o) cursor=$((cursor + 1)) ;;
      -*) ;;
      *) operand=$cursor; break ;;
    esac
    cursor=$((cursor + 1))
  done
  operand=${operand:-$repository}
  # With no repository Git pushes to a configured remote.
  [ -n "$operand$unresolved" ] || return 0
  value=""
  if [ -n "$operand" ]; then
    value=${args[$operand]:-}
    [ "$operand" != "$repository" ] || value=${value#--repo=}
    if [ "${arg_kinds[$operand]:-}" != literal ] || [[ ${arg_unquoted[$operand]:-} == *:fields ]]; then unresolved=${unresolved:-remote}; fi
  fi
  [ "$state" != unknown ] || unresolved=repository
  if [ "$state" != absolute ]; then
    effective_reader_directories
    [ -z "$effective_dirs_unresolved" ] || unresolved=repository
  else
    effective_dirs=(/)
  fi
  push_remotes[${#push_remotes[@]}]=$value
  push_reasons[${#push_reasons[@]}]=$unresolved
  push_states[${#push_states[@]}]=$state
  for directory in "${effective_dirs[@]}"; do push_bases[${#push_bases[@]}]=$directory; done
  push_base_ends[${#push_base_ends[@]}]=${#push_bases[@]}
  push_dirs=(${push_dirs[@]+"${push_dirs[@]}"} "$@")
  push_dir_ends[${#push_dir_ends[@]}]=${#push_dirs[@]}
}

# The one carrier of the history decision. STATE says how the -C chain
# resolves: absolute, relative to the payload directory, or unknown.
history_record() { # REASON STATE [DIR...]
  local record=${#history_reasons[@]}
  history_reasons[record]=$1; history_states[record]=$2; shift 2
  history_dirs=(${history_dirs[@]+"${history_dirs[@]}"} "$@")
  history_ends[record]=${#history_dirs[@]}
}

# A launcher the matcher does not resolve, such as timeout 5 or nice -n 5,
# can run any later literal word as its command, and an earlier one can be
# the launcher's own operand, as in doas -u git git log, so every later word
# naming git is judged as a Git head, and outside a body an unknown receiver
# gets, every one naming curl, wget, scp or rsync as that program's head. A
# shell, eval or source receiver's later words are its source, forwarded
# heads or positional data, judged where it runs them.
transfer_launched() { # [HEAD]
  local receiver receiver_pattern receiver_option receiver_named cursor head=${1-${program:-}}
  [ "$head" != opaque ] || return 0
  environment_receiver "$head"
  [ "$receiver" != shell ] || return 0
  for ((cursor=pos; cursor<${#args[@]}; cursor++)); do
    [ "${arg_kinds[$cursor]}" = literal ] || continue
    case "$head:${args[$cursor]##*/}" in
      *:git) history_git_argv $((cursor + 1)) launched ;;
      curl:* | wget:* | scp:* | rsync:*) ;;
      *:curl | *:wget | *:scp | *:rsync)
        [ -n "${transfer_ignored:-}" ] || [ "${git_walk:-both}" = history ] || launched_upload "${args[$cursor]##*/}" $((cursor + 1)) ;;
    esac
  done
}

launched_upload() { # PROGRAM START
  local program=$1 pos=$2
  upload_arguments
}

# The reported private file is checked as text, without opening it or
# evaluating submitted expansions. Filtering cannot make that read safe.
environment_private_path() {
  local path
  for path in "$@"; do
    case "$path" in '~/.fleet/env' | '$HOME/.fleet/env' | '${HOME}/.fleet/env') return 0 ;; esac
    if [ -n "${HOME:-}" ] && [ "$path" = "$HOME/.fleet/env" ]; then return 0; fi
  done
  return 1
}

literal_absolute_path() {
  local path=$1 part
  absolute_path=""
  while [ -n "$path" ]; do
    part=${path%%/*}
    case "$part" in
      '' | .) ;;
      ..) absolute_path=${absolute_path%/*} ;;
      *) absolute_path=$absolute_path/$part ;;
    esac
    case "$path" in */*) path=${path#*/} ;; *) break ;; esac
  done
  absolute_path=${absolute_path:-/}
}

effective_reader_directories() {
  local base absolute_path
  effective_dirs=()
  effective_dirs_unresolved=${reader_chdir_unresolved:-$reader_dirs_unresolved}
  case "$reader_chdir" in
    /*) effective_dirs=("$reader_chdir"); effective_dirs_unresolved=$reader_chdir_unresolved; return ;;
    '') effective_dirs=("${reader_dirs[@]}"); return ;;
  esac
  for base in "${reader_dirs[@]}"; do
    literal_absolute_path "$base/$reader_chdir"
    effective_dirs[${#effective_dirs[@]}]=$absolute_path
  done
}

proc_environment_path() {
  local path=$1 directory absolute_path effective_dirs=() effective_dirs_unresolved
  [ "${path##*/}" = environ ] || return 1
  case "$path" in
    /*) literal_absolute_path "$path"; [[ $absolute_path == /proc/*/environ ]]; return ;;
  esac
  effective_reader_directories
  [ -z "$effective_dirs_unresolved" ] || return 0
  for directory in "${effective_dirs[@]}"; do
    literal_absolute_path "$directory/$path"
    [[ $absolute_path != /proc/*/environ ]] || return 0
  done
  return 1
}

# A source frame keeps the reaching command's directory candidates, not the
# last stage's directory. Offsets preserve directory words without splitting.
record_reader_context() {
  local effective_dirs=() effective_dirs_unresolved directory
  effective_reader_directories
  reader_context_id=${#reader_context_starts[@]}
  reader_context_starts[reader_context_id]=${#reader_context_paths[@]}
  reader_context_counts[reader_context_id]=${#effective_dirs[@]}
  reader_context_uncertain[reader_context_id]=$effective_dirs_unresolved
  for directory in "${effective_dirs[@]}"; do
    reader_context_paths[${#reader_context_paths[@]}]=$directory
  done
}

load_reader_context() {
  local first=${reader_context_starts[$1]} count=${reader_context_counts[$1]}
  source_reader_dirs=("${reader_context_paths[@]:first:count}")
  source_reader_dirs_unresolved=${reader_context_uncertain[$1]}
}

# The reader walk takes a cd destination only where the shell does not
# expand it: an unquoted leading ~ expands against a HOME the command can
# set first, as history_git_argv states for -C, so it leaves the push's
# repository unresolved. The targeting check needs only the cd.
literal_cd_operand() {
  local cursor=$pos options_ended=""
  [ "${args[$cursor]:-}" != -- ] || { cursor=$((cursor + 1)); options_ended=1; }
  [ "$((cursor + 1))" -eq "${#args[@]}" ] && [ -n "${args[$cursor]}" ] &&
    [ "${arg_kinds[$cursor]}" = literal ] && [ "${args[$cursor]}" != - ] &&
    { [ -n "$options_ended" ] || [[ ${args[$cursor]} != -* ]]; } || return 1
  cd_operand=${args[$cursor]}
  case "${arg_unquoted[$cursor]%%:*}:$cd_operand" in ?*:'~'*) cd_destination="" ;; *) cd_destination=$cd_operand ;; esac
}

# The reader walk follows only a literal cd destination at a command head,
# and only in the frame whose later commands it judges. A cd a launcher
# runs, such as builtin cd or a sourced script running cd "$@", has no such
# destination, and any cd in text eval, source or . runs in the shell that
# queued it moves that shell's later commands; either moves them to a
# directory the walk does not follow. A shell's command string or input
# runs in a child, whose cd moves only its own frame.
# cd searches CDPATH for a relative destination whose first component is not
# . or .., .hidden included (bash 5.2 probes), and pushd runs cd. A cd the
# walk does not follow, such as CDPATH=/proc cd self, cd -P self or builtin
# cd self, can be searched too, so push_judge settles each such cd with the
# command's CDPATH words. The reader walk settles one only in the frame it
# walks: a cd in text eval, source or . runs leaves that nested walk's reader
# directories unresolved, not the outer walk's, so a read after the text is
# not reached.
directory_change() {
  case "$program" in cd | pushd | popd) ;; *) return 0 ;; esac
  [ -z "$same_shell" ] && [ -n "$cd_destination" ] || push_dir_unknown=1
  case "$cd_destination" in
    /* | . | .. | ./* | ../*) ;;
    *) cd_searched=1; push_cd_searched=1 ;;
  esac
}

# eval, source and . run their text in the shell that runs them.
runs_in_shell() {
  case "$program" in eval | source | .) return 0 ;; esac
  return 1
}

remember_reader_directory() {
  local destination=$1 index count=${#reader_dirs[@]} absolute_path
  # Retain both outcomes of earlier directory changes. Bound the number of
  # combinations before a relative chain can exceed the hook's time limit.
  [ -z "$reader_dirs_unresolved" ] || return 0
  case "$destination" in
    /*) reader_dirs[count]=$destination ;;
    *)
      for ((index=0; index<count; index++)); do
        literal_absolute_path "${reader_dirs[$index]}/$destination"
        reader_dirs[${#reader_dirs[@]}]=$absolute_path
      done ;;
  esac
  [ "${#reader_dirs[@]}" -le 32 ] || reader_dirs_unresolved=1
}

unit_environment_property() {
  local list=$1 property
  while [ -n "$list" ]; do
    property=${list%%,*}
    # The extended execution properties carry the configured argv too.
    case "${property%Ex}" in
      Environment | EnvironmentFiles | PassEnvironment | UnsetEnvironment | ExecCondition | ExecStart | ExecStartPre | ExecStartPost | ExecReload | ExecStop | ExecStopPost) return 0 ;;
    esac
    case "$list" in *,*) list=${list#*,} ;; *) break ;; esac
  done
  return 1
}

systemctl_literal_word() {
  case "${arg_kinds[$1]:-}" in
    dollar-literal) return 0 ;;
    literal) [[ ${args[$1]} != *[\*\?\[\]\{\}]* ]] ;;
    *) return 1 ;;
  esac
}

# Older systemctl uses getopt_long, which can stop at the verb. Count only
# leading filters as proof, and check every later option because versions
# that permute operands can still apply them. status and cat ignore filters.
systemctl_environment() {
  local cursor option property verb="" selected="" sensitive="" uncertain="" ended="" short take
  local property_list='^[A-Za-z][A-Za-z0-9]*(,[A-Za-z][A-Za-z0-9]*)*$'
  for ((cursor=pos; cursor<${#args[@]}; cursor++)); do
    option=${args[$cursor]}; property=""; take=""
    if [ -n "$ended" ] && [ -n "$verb" ]; then break; fi
    if ! systemctl_literal_word "$cursor"; then
      uncertain=1
      continue
    fi
    if [ -z "$ended" ]; then
      case "$option" in
        --) ended=1; continue ;;
        --property=*) property=${option#*=} ;;
        --property) take=1 ;;
        --user | --system | --no-pager | --no-ask-password | --all | --full | --value | --plain | --quiet | --with-dependencies | --no-legend | --failed | --no-block) continue ;;
        --host=* | --machine=* | --capsule=* | --type=* | --state=* | --lines=* | --output=* | --root=* | --image=* | --legend=* | --timestamp=*) continue ;;
        --host | --machine | --capsule | --type | --state | --lines | --output | --root | --image | --legend | --timestamp)
          cursor=$((cursor + 1)); systemctl_literal_word "$cursor" || uncertain=1; continue ;;
        --*=*) uncertain=1; continue ;;
        --*) uncertain=1; continue ;;
        -?*)
          short=${option:1}
          short=${short#"${short%%[!alqrfiT]*}"}
          case "$short" in
            [pP]) take=1 ;;
            [pP]?*) property=${short:1} ;;
            [HMCtnos]) cursor=$((cursor + 1)); systemctl_literal_word "$cursor" || uncertain=1; continue ;;
            [HMCtnos]?* | '') continue ;;
            *) uncertain=1; continue ;;
          esac ;;
        *) ;;
      esac
      case "$option" in
        -?*)
          if [ -n "$take" ]; then
            cursor=$((cursor + 1)); property=${args[$cursor]:-}
          fi
          if ! systemctl_literal_word "$cursor" || [[ ! $property =~ $property_list ]]; then
            uncertain=1
          elif unit_environment_property "$property"; then sensitive=1
          elif [ -z "$verb" ]; then selected=1; fi
          continue ;;
      esac
    fi
    case "$option:$verb:$uncertain" in
      status::* | cat::*) return 0 ;;
      show::*) verb=show ;;
      *::) return 1 ;;
    esac
  done
  [ "$verb" = show ] && { [ -z "$selected" ] || [ -n "$uncertain$sensitive" ]; }
}

# Procps BSD personalities and macOS legacy mode can read a dashed e as an
# environment flag too. The hook has no proof of the process's personality.
# Format and PID operands can contain e, so judge only the option letters.
ps_environment() {
  local cursor option letters flags operand grammar
  for grammar in bsd sysv; do
    for ((cursor=pos; cursor<${#args[@]}; cursor++)); do
      option=${args[$cursor]}
      case "$option" in
        --cols | --columns | --delimiter | --format | --group | --lines | --pid | --ppid | --quick-pid | --rows | --sid | --sort | --tty | --user | --width)
          cursor=$((cursor + 1)); continue ;;
        --*) continue ;;
      esac
      letters=${option#-}
      if [ "$grammar" = bsd ] || [ "$option" = "$letters" ]; then
        flags=${letters%%[kOopqtU0-9]*}
        [[ $flags != *e* ]] || return 0
      else
        flags=${letters%%[CDGgOopqstuU]*}
        [[ $flags != *E* ]] || return 0
      fi
      operand=${letters#"$flags"}
      case "$operand" in [CDGgOopqstuUk]) cursor=$((cursor + 1)) ;; esac
    done
  done
  return 1
}

# busctl prints only interface XML when it sees the leading XML option.
busctl_xml_only() {
  local cursor
  for ((cursor=pos; cursor<${#args[@]}; cursor++)); do
    case "${arg_kinds[$cursor]}:${args[$cursor]}" in
      literal:--xml-interface | dollar-literal:--xml-interface) return 0 ;;
      literal:--user | literal:--system | literal:--no-pager | literal:--no-legend) ;;
      *) return 1 ;;
    esac
  done
  return 1
}

# The D-Bus service publishes the same properties via Get, GetAll and
# introspection. systemd-analyze's dump prints the unit's execution context.
systemd_bus_environment() {
  local cursor word service="" read="" property=""
  for ((cursor=pos; cursor<${#args[@]}; cursor++)); do
    word=${args[$cursor]}
    case "$word" in --dest=* | --object-path=* | --method=*) word=${word#*=} ;; esac
    case "$word" in
      org.freedesktop.systemd1 | /org/freedesktop/systemd1 | /org/freedesktop/systemd1/*) service=1 ;;
      introspect) if [ "$program" != busctl ] || ! busctl_xml_only; then read=all; fi ;;
      GetAll | *.GetAll | Dump | *.Dump | DumpUnitsMatchingPatterns | *.DumpUnitsMatchingPatterns) read=all ;;
      get-property | Get | *.Get) [ "$read" = all ] || read=named ;;
      *) if unit_environment_property "${word#string:}"; then property=1; fi ;;
    esac
  done
  [ -n "$service" ] && { [ "$read" = all ] || { [ "$read" = named ] && [ -n "$property" ]; }; }
}

environment_file_input() {
  if [ "$2" = ansi-escaped ]; then
    mode=dump-unknown; dump_reason=undecoded-ansi-escape
  elif proc_environment_path "$1"; then
    mode=dump-unknown
  else
    return 1
  fi
}

reader_long_option_role() {
  case "$program:$1" in
    grep:--regexp | rg:--regexp) role=pattern ;;
    grep:--file | rg:--file) role=pattern-file ;;
    rg:--ignore-file | grep:--exclude-from | diff:--exclude-from | diff:--from-file | diff:--to-file | sort:--files0-from | sort:--random-source | xargs:--arg-file) role=file ;;
    grep:--color | grep:--colour | diff:--context | diff:--unified | xargs:--eof | xargs:--max-lines | xargs:--replace) role=optional-data ;;
    grep:--after-context | grep:--before-context | grep:--binary-files | grep:--context | grep:--devices | grep:--directories | grep:--exclude | grep:--exclude-dir | grep:--group-separator | grep:--include | grep:--label | grep:--max-count) role=data ;;
    rg:--after-context | rg:--before-context | rg:--color | rg:--colors | rg:--context | rg:--context-separator | rg:--dfa-size-limit | rg:--encoding | rg:--engine | rg:--field-context-separator | rg:--field-match-separator | rg:--generate | rg:--glob | rg:--hostname-bin | rg:--hyperlink-format | rg:--iglob | rg:--max-columns | rg:--max-count | rg:--max-depth | rg:--max-filesize | rg:--path-separator | rg:--pre | rg:--pre-glob | rg:--regex-size-limit | rg:--replace | rg:--sort | rg:--sortr | rg:--threads | rg:--type | rg:--type-add | rg:--type-clear | rg:--type-not) role=data ;;
    diff:--ifdef | diff:--ignore-matching-lines | diff:--label | diff:--show-function-line | diff:--starting-file | diff:--width) role=data ;;
    sort:--batch-size | sort:--buffer-size | sort:--compress-program | sort:--field-separator | sort:--key | sort:--output | sort:--parallel | sort:--temporary-directory) role=data ;;
    xargs:--delimiter | xargs:--max-args | xargs:--max-chars | xargs:--max-procs | xargs:--process-slot-var) role=data ;;
  esac
}

# Searchers use their first positional word as a pattern only when no
# explicit pattern or pattern file was supplied. An ignore file is still a
# file read, but does not take the place of a search pattern.
reader_environment_arguments() {
  local cursor value kind role short letters end="" explicit="" filter_ok=1 pattern="" patterns=0
  local search="" operand_flags index
  local positional=()
  case "$program" in
    grep) search=1; operand_flags='efABCDdm' ;;
    rg) search=1; operand_flags='efABCdEgjtTMmr' ;;
    diff) operand_flags='CDFILSUW' ;;
    sort) operand_flags='kSotT' ;;
    xargs) operand_flags='aEdIeLlniPs' ;;
  esac
  for ((cursor=pos; cursor<${#args[@]}; cursor++)); do
    value=${args[$cursor]}; kind=${arg_kinds[$cursor]}; role=""
    if [ "$program" = xargs ]; then
      # The first operand is the child executable. The child's grammar, not
      # the launcher's option arities, owns every subsequent word.
      case "$value" in
        --) cursor=$((cursor + 1)); break ;;
        -?*) ;;
        *) break ;;
      esac
      if [ "$kind" = ansi-escaped ]; then mode=dump-unknown; dump_reason=undecoded-ansi-escape; return; fi
    fi
    [ "$kind" = literal ] || filter_ok=""
    if [ -z "$end" ]; then
      case "$value" in
        --) end=1; continue ;;
        --*)
          filter_ok=""
          reader_long_option_role "${value%%=*}"
          case "$value" in
            *=*)
              value=${value#*=}
              # An unclassified attached operand cannot establish a data role.
              role=${role:-file} ;;
            *)
              case "$role" in '' | optional-data) continue ;; esac
              cursor=$((cursor + 1)); value=${args[$cursor]:-}; kind=${arg_kinds[$cursor]:-} ;;
          esac ;;
        -?*)
          letters=${value#-}
          short=${letters#"${letters%%[$operand_flags]*}"}
          if [ "$value" != -e ] && [[ ! $letters =~ ^[EFq]+$ ]]; then filter_ok=""; fi
          case "$program:$short" in
            grep:e* | rg:e*) role=pattern ;;
            grep:f* | rg:f*) role=pattern-file ;;
            xargs:a*) role=file ;;
            xargs:[eil] | *:) continue ;;
            *) role=data ;;
          esac
          if [ "${#short}" -eq 1 ]; then
            cursor=$((cursor + 1)); value=${args[$cursor]:-}; kind=${arg_kinds[$cursor]:-}
          else
            value=${short:1}
          fi ;;
      esac
    fi
    case "$role" in
      pattern) explicit=1; pattern=$value; patterns=$((patterns + 1)); [ "$kind" = literal ] || filter_ok="" ;;
      pattern-file | file)
        [ "$role" != pattern-file ] || explicit=1
        if environment_file_input "$value" "$kind"; then return; fi ;;
      data | optional-data) ;;
      *) positional[${#positional[@]}]=$cursor ;;
    esac
  done
  if [ "$program" = xargs ]; then pos=$cursor; return 0; fi
  index=0
  if [ -n "$search" ] && [ -z "$explicit" ] && [ "${#positional[@]}" -gt 0 ]; then
    pattern=${args[${positional[0]}]}; patterns=1; index=1
  fi
  for ((; index<${#positional[@]}; index++)); do
    cursor=${positional[$index]}
    if environment_file_input "${args[$cursor]}" "${arg_kinds[$cursor]}"; then return; fi
    filter_ok=""
  done
  if [ "$program" = grep ] && [ -n "$filter_ok" ] && [ "$patterns" -eq 1 ] &&
     [[ $pattern =~ $filter_re ]] && [ -z "$input_redirect" ]; then mode=filter; fi
}

# This rule belongs to this hook, not the replaceable project pattern. No
# harness output-rewrite interface can remove secrets before the transcript.
# A harness permission rule cannot hold it either: such a rule matches command
# text by prefix or pattern and knows no filter, launcher or quoting, so it
# can neither admit a named grep of a dump nor find a dump a launcher runs.
# Only a proven direct pipe grants permission. Nested syntax is detection
# evidence, never proof of routing; unseen program semantics are not judged.
# The one producer judges a stage head and every forwarded operand alike.
environment_producer() { # command kind
    local env_chdir env_chdir_word xargs_launch="" builtin_head=$pos assigned_name
    local exec_option_re='^-[cl]*(a.*)?$' exec_name_needed exec_word
    split_reader_chdir=$reader_chdir; split_reader_chdir_unresolved=$reader_chdir_unresolved
    shell_forwarder=""; shell_forwarded_pos=""
    # Other is unresolved. An existing arm's proof must establish clean.
    mode=other
    # Only these literal forwarding forms are part of the input contract.
    # Unsupported executable-string arguments get conservative detection.
    while [ "$program" != opaque ] && [ "$pos" -lt "${#args[@]}" ]; do
      # ANSI-C escapes in a head have no decoder in this input contract.
      # Refuse rather than permit an encoded environment producer.
      [ "${arg_kinds[$pos]}" != ansi-escaped ] || { mode=dump-unknown; dump_reason=undecoded-ansi-escape; return; }
      [ "${arg_kinds[$pos]}" != dollar-literal ] || arg_kinds[pos]=literal
      [ "${arg_kinds[$pos]}" = literal ] || break
      program_pos=$pos; program=${args[$pos]##*/}; pos=$((pos + 1))
      case "$program" in
        exec | builtin)
          if [ "$1" = shell ] && [ "${args[$((pos - 1))]}" = "$program" ]; then
            shell_forwarder=$program
            # A command prefix can reach a shell builtin. An external
            # launcher reaches an opaque operand but proves no dispatch.
            if [ "$program_pos" -eq "$builtin_head" ]; then
              shell_forwarded_pos=$pos
              if [ "$program" = exec ]; then
                # Bash's exec help names -c, -l and -a NAME. The first a
                # in a short cluster takes the rest or the next word as NAME.
                # NAME is argv[0] data, so only its word count matters. A word
                # that can split, or an expanding word where exec reads an
                # option, leaves the child and the directory it runs in unknown.
                exec_name_needed=""
                while [ "$shell_forwarded_pos" -lt "${#args[@]}" ]; do
                  value=${args[$shell_forwarded_pos]}
                  case "${arg_kinds[$shell_forwarded_pos]}:${arg_unquoted[$shell_forwarded_pos]}" in
                    *:fields) exec_word=split ;;
                    literal:* | dollar-literal:*) exec_word=literal ;;
                    *) exec_word=expanding ;;
                  esac
                  if [ "$exec_word" != split ] && [ -n "$exec_name_needed" ]; then
                    exec_name_needed=""
                  elif [ "$exec_word" = literal ] && [[ $value != -?* || $value == -- ]]; then
                    break
                  elif [ "$exec_word" = literal ] && [[ $value =~ $exec_option_re ]]; then
                    # An expanding attached NAME can be empty, and exec
                    # then takes the next word as NAME, so only a literal
                    # option word has a known boundary.
                    [ "${BASH_REMATCH[1]:-}" != a ] || exec_name_needed=1
                  elif [ "$exec_word" = literal ]; then
                    # exec refuses an unknown option and runs nothing.
                    shell_forwarded_pos=""; break
                  else
                    shell_forwarded_pos=""; reader_chdir_unresolved=1; break
                  fi
                  shell_forwarded_pos=$((shell_forwarded_pos + 1))
                done
                [ -z "$exec_name_needed" ] || shell_forwarded_pos=""
              fi
              if [ -n "$shell_forwarded_pos" ]; then
                case "${args[$shell_forwarded_pos]:-}:${arg_kinds[$shell_forwarded_pos]:-}" in
                  --:literal | --:dollar-literal) shell_forwarded_pos=$((shell_forwarded_pos + 1)) ;;
                esac
              fi
            fi
            program=opaque; compound=1
          fi
          break ;;
        command)
          case "${args[$pos]:-}" in -v | -V) pos=${#args[@]}; break ;; -p) pos=$((pos + 1)) ;; esac
          [ "${args[$pos]:-}" != -- ] || pos=$((pos + 1))
          if [ "$program_pos" -eq "$builtin_head" ] && [ "${args[$program_pos]}" = command ]; then builtin_head=$pos; fi
          continue ;;
        sudo)
          while [ "$pos" -lt "${#args[@]}" ]; do
            case "${args[$pos]}" in
              -u | -g | --user | --group) pos=$((pos + 2)) ;;
              --user=* | --group=* | -n | -E | -H) pos=$((pos + 1)) ;;
              --) pos=$((pos + 1)); break ;;
              *) break ;;
            esac
          done
          continue ;;
        xargs)
          if [ -n "$input_escaped" ]; then mode=dump-unknown; dump_reason=undecoded-ansi-escape; return; fi
          if [ -n "$proc" ]; then mode=dump-unknown; return; fi
          reader_environment_arguments
          [ "$mode" != dump-unknown ] || return
          xargs_launch=1
          continue ;;
        env)
          split_reader_chdir=$reader_chdir; split_reader_chdir_unresolved=$reader_chdir_unresolved
          options_ended=""; null_output=""; env_chdir=""; env_chdir_word=""
          while [ "$pos" -lt "${#args[@]}" ]; do
            value=${args[$pos]}
            case "${arg_kinds[$pos]}" in dollar-literal | ansi-escaped) break ;; esac
            # -- ends options, not the following assignment operands.
            if assignment_word "$value"; then pos=$((pos + 1)); continue; fi
            [ -z "$options_ended" ] || break
            case "$value" in
              -i | --ignore-environment) pos=$((pos + 1)) ;;
              -0 | --null) null_output=1; pos=$((pos + 1)) ;;
              -u | --unset | -C | --chdir)
                # A non-literal operand such as "$@" can expand to no word,
                # and env then takes the next word as that operand.
                [ "${arg_kinds[$((pos + 1))]:-}" = literal ] || { mode=dump-unknown; return; }
                case "$value" in -C | --chdir) env_chdir_word=$((pos + 1)); env_chdir=${args[$env_chdir_word]} ;; esac
                pos=$((pos + 2)) ;;
              --unset=*) pos=$((pos + 1)) ;;
              --chdir=* | -C?*)
                env_chdir_word=$pos
                case "$value" in --*) env_chdir=${value#*=} ;; *) env_chdir=${value:2} ;; esac
                pos=$((pos + 1)) ;;
              --help | --version) pos=${#args[@]}; program=""; break ;;
              --) options_ended=1; pos=$((pos + 1)); continue ;;
              -S | --split-string | --split-string=*) program=opaque; break ;;
              -*) mode=dump-unknown; break ;;
              *) break ;;
            esac
          done
          if [ -n "$env_chdir_word" ]; then
            # Shell expansion can change the directory, even when some
            # fragments in the word are quoted. The path was never resolved.
            if [ "${arg_kinds[$env_chdir_word]}" != literal ] ||
               [[ ${arg_unquoted[$env_chdir_word]} == *:fields ]]; then
              reader_chdir_unresolved=1
            # The shell expands an unquoted leading ~ in a separate operand
            # word, never in --chdir=~ or -C~, against a HOME the command
            # can set first, as literal_cd_operand states for cd.
            elif [ "${args[$env_chdir_word]}" = "$env_chdir" ] && [ -n "${arg_unquoted[$env_chdir_word]%%:*}" ] &&
                 [[ $env_chdir == '~'* ]]; then
              reader_chdir_unresolved=1
            else
              case "$env_chdir" in
                /*) reader_chdir=$env_chdir; reader_chdir_unresolved="" ;;
                ?*) reader_chdir=${reader_chdir:+$reader_chdir/}$env_chdir ;;
              esac
            fi
          fi
          if [ "$program" = env ] && [ "$pos" -ge "${#args[@]}" ]; then
            mode=dump-lines; [ -z "$null_output" ] || mode=dump-nul
          fi
          if [ "$program" = env ] && [ "${arg_kinds[$pos]:-literal}" != literal ]; then
            mode=dump-unknown; [ "${arg_kinds[$pos]}" != ansi-escaped ] || dump_reason=undecoded-ansi-escape
          fi
          [ "$program" = env ] && [ "$mode" = other ] || break
          continue ;;
        *) break ;;
      esac
    done
    producer_end=$pos
    transfer_walks
    # A directory change moves any relative -C chain the hook resolves from
    # the payload directory, wherever it stands, since a loop can run it
    # first. A launcher's own directory option, such as env -C or sudo -D, is
    # resolved as if absent: launcher option grammars are not modelled here.
    case "${program:-}" in cd | pushd | popd) history_dir_changed=1 ;; esac
    # Bash expands ANSI-C escapes after the harness submits command text.
    # These producer operands cannot prove a safe name, flag or input path.
    case "${program:-}" in
      printenv | export | declare | typeset | set | systemctl | tmux | ps | systemd-analyze | busctl | gdbus | dbus-send | cat | tr | strings)
        for ((j=pos; j<${#args[@]}; j++)); do
          [ "${arg_kinds[$j]}" != ansi-escaped ] || { mode=dump-unknown; dump_reason=undecoded-ansi-escape; return; }
        done ;;
    esac
    case "${program:-}" in
      cat | tr | strings) [ -z "$input_escaped" ] || { mode=dump-unknown; dump_reason=undecoded-ansi-escape; return; } ;;
      awk | base64 | comm | cp | cut | dd | head | hexdump | jq | less | more | nl | od | paste | perl | python | python3 | sed | split | tail | tee | uniq | xxd)
        [ -z "$input_escaped" ] || { mode=dump-unknown; dump_reason=undecoded-ansi-escape; return; }
        for ((j=pos; j<${#args[@]}; j++)); do
          value=${args[$j]}
          case "$program:$value" in dd:if=*) value=${value#if=} ;; esac
          if environment_file_input "$value" "${arg_kinds[$j]}"; then return; fi
        done ;;
    esac
    case "${program:-}" in
      printenv)
        named=""; options_ended=""; null_output=""; mode=dump-lines
        for ((j=pos; j<${#args[@]}; j++)); do
          value=${args[$j]}
          [ "${arg_kinds[$j]}" = literal ] || mode=dump-unknown
          if [ -z "$options_ended" ]; then
            case "$value" in
              --help | --version) named=1; continue ;;
              -0 | --null) null_output=1; continue ;;
              --) options_ended=1; continue ;;
              -*) mode=dump-unknown; continue ;;
            esac
          fi
          [ "${arg_kinds[$j]}" != literal ] || [[ ! $value =~ $name_re ]] || named=1
        done
        if [ "$mode" != dump-unknown ]; then
          if [ -n "$named" ]; then mode=clean; elif [ -n "$null_output" ]; then mode=dump-nul; fi
        fi ;;
      export | declare | typeset)
        # Only a word that starts with a literal name, alone or before = or
        # +=, names a variable. Any other expanding word, such as "$x", can
        # be an option or no word at all; beside listing flags alone, it
        # keeps the listing judgment.
        named=""; flags=""; listing=1
        for ((j=pos; j<${#args[@]}; j++)); do
          value=${args[$j]}
          case "${arg_kinds[$j]}:$value" in
            literal:-* | dollar-literal:-*)
              flags=$flags$value; [[ $value =~ ^(--|-[gI]+)$ ]] || listing="" ;;
            literal:* | dollar-literal:*)
              if [[ $value =~ $declared_re ]]; then named=1; else listing=""; fi ;;
            *) [[ ! $value =~ $declared_re ]] || named=1 ;;
          esac
        done
        if [ -z "$named" ]; then
          # With no name, declare and typeset print every variable: bare,
          # after --, with only the g and I scope flags, or with only those
          # flags and expanding words that name none.
          case "$program:$flags" in export:* | *:*p* | *:*x*) mode=dump-lines ;; esac
          [ -z "$listing" ] || mode=dump-lines
          if [ "$mode" = dump-lines ]; then
            for ((j=pos; j<${#args[@]}; j++)); do
              value=${args[$j]}
              case "$value" in --) ;; -*) [[ $value =~ ^-[px]+$ ]] || mode=dump-unknown ;; *) mode=dump-unknown ;; esac
            done
          fi
        else
          mode=clean
        fi ;;
      set)
        named=""
        for ((j=pos; j<${#args[@]}; j++)); do [ "${arg_kinds[$j]}" != literal ] || named=1; done
        if [ -z "$named" ]; then
          if [ "$pos" -lt "${#args[@]}" ]; then mode=dump-unknown; else mode=dump-lines; fi
        fi
        [ -z "$named" ] || [ "$mode" != other ] || mode=clean ;;
      systemctl)
        for ((j=pos; j<${#args[@]}; j++)); do [ "${args[$j]}" != show-environment ] || mode=dump-lines; done
        if [ "$mode" = dump-lines ]; then
          for ((j=pos; j<${#args[@]}; j++)); do
            case "${args[$j]}" in --user | --system | -- | show-environment) ;; *) mode=dump-unknown ;; esac
          done
        elif systemctl_environment; then mode=dump-unknown
        fi ;;
      tmux)
        # tmux.c:getopt owns global arities; cmd-show-environment.c declares
        # show-environment/showenv [-hgs] [-t target-session] [variable].
        # https://github.com/tmux/tmux/blob/master/cmd-show-environment.c
        local tmux_global_re='^-[2CDdhlNquUvV]+$' tmux_option_re='^-[ghs]*(t.*)?$' tmux_target
        j=$pos
        while [ "$j" -lt "${#args[@]}" ]; do
          value=${args[$j]}
          [ "${arg_kinds[$j]}" = literal ] || { mode=dump-unknown; return; }
          case "$value" in
            --) j=$((j + 1)); break ;;
            -f | -L | -S | -T)
              j=$((j + 1))
              [ "${arg_kinds[$j]:-}" = literal ] || { mode=dump-unknown; return; } ;;
            -f?* | -L?* | -S?* | -T?*) ;;
            -*) [[ $value =~ $tmux_global_re ]] || { mode=dump-unknown; return; } ;;
            *) break ;;
          esac
          j=$((j + 1))
        done
        case "${args[$j]:-}" in
          show-environment | showenv)
            mode=dump-lines; named=""; options_ended=""
            for ((j=j+1; j<${#args[@]}; j++)); do
              value=${args[$j]}
              [ "${arg_kinds[$j]}" = literal ] || { mode=dump-unknown; return; }
              if [ -z "$options_ended" ]; then
                case "$value" in
                  --) options_ended=1; continue ;;
                  -*)
                    [[ $value =~ $tmux_option_re ]] || { mode=dump-unknown; return; }
                    tmux_target=${BASH_REMATCH[1]:-}
                    # -s emits shell statements, not proven NAME=value rows.
                    case "${value%%t*}" in *s*) mode=dump-unknown ;; esac
                    if [ "$tmux_target" = t ]; then
                      j=$((j + 1))
                      [ "${arg_kinds[$j]:-}" = literal ] || { mode=dump-unknown; return; }
                    fi
                    continue ;;
                esac
              fi
              if [ "$j" -eq "$((${#args[@]} - 1))" ] && [[ $value =~ $name_re ]]; then named=1
              else mode=dump-unknown; return
              fi
            done
            if [ -n "$named" ]; then mode=clean; fi ;;
        esac ;;
      ps) if ps_environment; then mode=dump-unknown; fi ;;
      systemd-analyze)
        for ((j=pos; j<${#args[@]}; j++)); do [ "${args[$j]}" != dump ] || mode=dump-unknown; done ;;
      busctl | gdbus | dbus-send) if systemd_bus_environment; then mode=dump-unknown; fi ;;
      cat | tr | strings)
        for ((j=pos; j<${#args[@]}; j++)); do
          if proc_environment_path "${args[$j]}"; then proc=1; fi
        done
        if [ -n "$proc" ]; then
          case "$program" in
            cat | strings)
              mode=dump-nul; [ "$program" != strings ] || mode=dump-lines
              for ((j=pos; j<${#args[@]}; j++)); do
                [ "${args[$j]}" != -- ] || continue
                [ "${arg_kinds[$j]}" = literal ] || mode=dump-unknown
                proc_environment_path "${args[$j]}" || mode=dump-unknown
              done ;;
            tr) mode=dump-unknown ;;
          esac
        fi
        # Only this literal conversion proves separate newline records.
        # Unknown transformations and flattened xargs output stay unknown.
        if [ "$program" = tr ] && [ -z "$output" ] && [ "$((${#args[@]} - pos))" -eq 2 ] &&
          [ "${arg_kinds[$pos]}:${arg_kinds[$((pos + 1))]}" = literal:literal ]; then
          case "${args[$pos]}:${args[$((pos + 1))]}" in
            '\0:\n' | '\000:\n')
              if [ -n "$proc" ]; then mode=dump-lines; elif [ -z "$input_redirect" ]; then mode=convert; fi ;;
          esac
        fi
        if [ "$program" = cat ] && environment_private_path ${private_inputs[@]+"${private_inputs[@]}"} "${args[@]:pos}"; then mode=dump-unknown; fi ;;
      grep | rg | diff | sort)
        if [ -n "$input_escaped" ]; then mode=dump-unknown; dump_reason=undecoded-ansi-escape
        elif [ -n "$proc" ]; then mode=dump-unknown
        else reader_environment_arguments; fi ;;
    esac
    if [ -n "$xargs_launch" ]; then
      # xargs consumes stdin as arguments, so it cannot prove the child's
      # input or output record framing.
      case "$mode" in dump-lines | dump-nul) mode=dump-unknown ;; convert | filter) mode=other ;; esac
    fi
    # No unresolved arm can discharge the forwarded classification check.
    if [ "$mode" = other ] && [ -n "${forwarded_argument:-}" ]; then mode=unclassified-forwarded; fi
}

# The history judgment reads the stage as the tokenizer split it. The push
# and upload judgments read only where a shell runs the text, never a body an
# unknown receiver gets, and they read the whole command, the words after a
# substitution that splits it included.
transfer_walks() {
  local git_walk=both count=${#args[@]}
  if [ -n "${transfer_ignored:-}" ] || [ "${#tail_kinds[@]}" -gt 0 ] || [ -n "$tail_glued" ]; then git_walk=history; fi
  if [ "${program:-}" = git ]; then history_git_argv "$pos"; else transfer_launched; fi
  [ -z "${transfer_ignored:-}" ] || return 0
  if [ "$git_walk" = history ]; then
    local args=(${args[@]+"${args[@]}"} ${tail_args[@]+"${tail_args[@]}"})
    local arg_kinds=(${arg_kinds[@]+"${arg_kinds[@]}"} ${tail_kinds[@]+"${tail_kinds[@]}"})
    local arg_unquoted=(${arg_unquoted[@]+"${arg_unquoted[@]}"} ${tail_unquoted[@]+"${tail_unquoted[@]}"})
    [ -z "$tail_glued" ] || [ "$count" -eq 0 ] || arg_kinds[count - 1]=substituted
    git_walk=push
    # A command whose words before the substitution are all assignments,
    # as in http_proxy=$(...) curl, has its program word after it.
    if [ "$pos" -ge "$count" ]; then transfer_launched ""
    elif [ "${program:-}" = git ]; then history_git_argv "$pos"
    else transfer_launched; fi
  fi
  case "${program:-}" in curl | wget | scp | rsync) upload_arguments ;; esac
}

# Bash takes a NAME=value or NAME+=value word before the program word as an
# assignment and passes it to that program; env takes the same words as its
# operands. The one test of an assignment word, which names its variable in
# assigned_name.
assignment_word() { # WORD
  [[ $1 =~ ^([A-Za-z_][A-Za-z0-9_]*)\+?= ]] || return 1
  assigned_name=${BASH_REMATCH[1]}
}

# A program reads the variables assigned before its word, and so does what
# it runs: the command an exec or builtin forwards, the source eval or a
# shell runs, and a script's operands. inherited_assignments carries the
# names a launching command assigned into the frame or operand it runs;
# launch_names adds the current command's own, those before the word at END.
launch_assignments() { # END
  local cursor assigned_name
  launch_names=${inherited_assignments:-}
  for ((cursor=0; cursor<$1; cursor++)); do
    ! assignment_word "${args[$cursor]}" || launch_names="$launch_names $assigned_name"
  done
}

# Reserved-word syntax and assignment prefixes come before the executable
# head; a quoted or pathname word is never syntax.
environment_head() { # command kind; updates pos, syntax_head and head_start
  local cursor state=head value assigned_name
  pos=${#args[@]}; syntax_head=""; head_start=0
  if [ "$1" = argv ]; then pos=0; return; fi
  while [ "$head_start" -lt "${#args[@]}" ] && assignment_word "${args[$head_start]}"; do head_start=$((head_start + 1)); done
  for ((cursor=0; cursor<${#args[@]}; cursor++)); do
    value=${args[$cursor]}
    case "$state" in
      name) state=body; continue ;;
      body | loop | conditional)
        if [ "${arg_kinds[$cursor]}" = literal ] && [ "${arg_unquoted[$cursor]%%:*}" = 1 ]; then
          case "$value:$state" in '{:body') compound_depth=$((compound_depth + 1)); state=head ;; do:loop) state=head ;; esac
        fi
        continue ;;
      time)
        case "$value" in -*) continue ;; esac
        state=head ;;
    esac
    if assignment_word "$value"; then continue; fi
    if [ "${arg_kinds[$cursor]}" = literal ] && [ "${arg_unquoted[$cursor]%%:*}" = 1 ]; then
      case "$value" in
        if | while | until | '{')
          compound_depth=$((compound_depth + 1)); syntax_head=1; continue ;;
        then | elif | else | do | '!')
          syntax_head=1; continue ;;
        time) syntax_head=1; state=time; continue ;;
        function) syntax_head=1; state=name; continue ;;
        for | select) compound_depth=$((compound_depth + 1)); syntax_head=1; state=loop; continue ;;
        case) compound_depth=$((compound_depth + 1)); syntax_head=1; state=conditional; continue ;;
        '[[') syntax_head=1; state=conditional; continue ;;
        'coproc')
          syntax_head=1
          if [ "${args[$((cursor + 2))]:-}" = '{' ]; then state=name; fi
          continue ;;
        fi | done | 'esac' | '}')
          compound_depth=$((compound_depth - 1)); syntax_head=1; continue ;;
        ']]' | in)
          syntax_head=1; continue ;;
      esac
    fi
    pos=$cursor
    return
  done
}

# A word test for text a shell or source script or orch-runtime launch-job
# forwards, which it can run as a command: an unclassified stage, and a
# forwarded body that holds heredocs; also an eval join that holds a
# non-literal word. It runs nowhere
# else and grants no permission.
environment_main_evidence() {
  local value evidence continuation=$'\\\n'
  local opaque_re='(^|[^A-Za-z0-9_.-])(env|printenv|export|declare|typeset|set|show-environment|showenv)([^A-Za-z0-9_.-]|$)|/proc/[^[:space:]]*/environ'
  for value in "$@"; do
    evidence=${value//"$continuation"/}
    evidence=${evidence//[\'\"\\]/}
    [[ ! $evidence =~ $opaque_re ]] || return 0
  done
  return 1
}

# Receiving language is a local classification, not an exemption from the
# independent shell expansion and unsupported forwarding checks.
environment_receiver() { # language
  receiver=unknown; receiver_pattern=""; receiver_option=""; receiver_named=""
  case "$1" in
    cat) receiver=data ;;
    bash | sh | dash | zsh | ksh | eval | source | .) receiver=shell ;;
    python | python3)
      receiver=interpreter; receiver_option='^-[cm]$'
      receiver_pattern='(^|[^A-Za-z0-9_])os[[:space:]]*\.[[:space:]]*environ'
      receiver_named='^[[:blank:]]*(\[|\.[[:blank:]]*(get|pop|setdefault|__getitem__|__contains__)[[:blank:]]*\()' ;;
    node)
      receiver=interpreter; receiver_option='^(-e|--eval|-p|--print)$'
      receiver_pattern='(^|[^A-Za-z0-9_])process[[:space:]]*\.[[:space:]]*env'
      receiver_named='^[[:blank:]]*(\[|\.)' ;;
    ruby)
      receiver=interpreter; receiver_option='^-e$'
      receiver_pattern='(^|[^A-Za-z0-9_])ENV[[:space:]]*\.[[:space:]]*(to_h|each)([^A-Za-z0-9_]|$)' ;;
    perl)
      receiver=interpreter; receiver_option='^-e$'
      receiver_pattern='%ENV([^A-Za-z0-9_]|$)' ;;
  esac
}

environment_receiver_evidence() { # language text
  local remaining=$2 matched receiver receiver_pattern receiver_option receiver_named
  environment_receiver "$1"
  case "$1" in
    python | python3)
      local source=$2 executable="" span quote c i=0 end found uncertain=""
      local dynamic_re='(^|[^A-Za-z0-9_])(exec|eval|compile)([^A-Za-z0-9_]|$)'
      local span_re="^[^\"'#]+"
      local unsafe_re='(^|[^A-Za-z0-9_])(os|__import__|importlib|getattr|globals|vars|exec|eval|compile)([^A-Za-z0-9_]|$)|(^|[^A-Za-z0-9_])sys[[:space:]]*\.[[:space:]]*modules([^A-Za-z0-9_]|$)'
      local import_re='(^|[^A-Za-z0-9_])(from|import)([^A-Za-z0-9_]|$)' imports import_kind
      local module_re='^[[:blank:]]+(pathlib|re|json|textwrap)([[:blank:]]+as[[:blank:]]+[A-Za-z_][A-Za-z0-9_]*)?[[:blank:]]*(,[[:blank:]]*(pathlib|re|json|textwrap)([[:blank:]]+as[[:blank:]]+[A-Za-z_][A-Za-z0-9_]*)?[[:blank:]]*)*$'
      local from_re='^[[:blank:]]+(pathlib|re|json|textwrap)[[:blank:]]+import[[:blank:]]+'
      # Source-edit literals are data only with these non-executing imports.
      # Other imports, dynamic access and uncertain syntax keep raw evidence:
      # child interpreters can execute a quoted environment read.
      if [[ ! $source =~ $dynamic_re ]]; then
        while [ "$i" -lt "${#source}" ]; do
          c=${source:i:1}
          case "$c" in
            '#')
              span=${source:i}; span=${span%%$'\n'*}
              executable=$executable$span; i=$((i + ${#span})) ;;
            "'" | '"')
              if [ "$i" -gt 0 ]; then
                case "${source:i-1:1}" in [A-Za-z0-9_] | \\) uncertain=1; break ;; esac
              fi
              quote=$c
              [ "${source:i:3}" != "$c$c$c" ] || quote=$c$c$c
              end=$((i + ${#quote})); found=""
              while [ "$end" -lt "${#source}" ]; do
                if [ "${source:end:1}" = '\' ]; then end=$((end + 2)); continue; fi
                if [ "${source:end:${#quote}}" = "$quote" ]; then
                  end=$((end + ${#quote})); found=1; break
                fi
                if [ "${#quote}" -eq 1 ] && [ "${source:end:1}" = $'\n' ]; then break; fi
                span=${source:end}
                span=${span%%"$c"*}; span=${span%%\\*}
                [ "${#quote}" -ne 1 ] || span=${span%%$'\n'*}
                if [ -n "$span" ]; then end=$((end + ${#span})); else end=$((end + 1)); fi
              done
              [ -n "$found" ] || { uncertain=1; break; }
              span=${source:i:end-i}
              executable=$executable${span//[!$'\n']/ }; i=$end ;;
            *)
              [[ ${source:i} =~ $span_re ]] || { uncertain=1; break; }
              span=${BASH_REMATCH[0]}
              executable=$executable$span; i=$((i + ${#span})) ;;
          esac
        done
        if [[ $executable =~ $unsafe_re ]]; then uncertain=1; fi
        imports=$executable
        while [ -z "$uncertain" ] && [[ $imports =~ $import_re ]]; do
          matched=${BASH_REMATCH[0]}; import_kind=${BASH_REMATCH[2]}
          span=${BASH_REMATCH[3]}
          imports=$span${imports#*"$matched"}
          span=${imports%%$'\n'*}; span=${span%%;*}; span=${span%%#*}
          if [ "$import_kind" = from ]; then
            [[ $span =~ $from_re ]] || uncertain=1
          else
            [[ $span =~ $module_re ]] || uncertain=1
          fi
          imports=${imports#"$span"}
        done
        if [ -z "$uncertain" ]; then remaining=$executable; fi
      fi ;;
  esac
  while [[ $remaining =~ $receiver_pattern ]]; do
    matched=${BASH_REMATCH[0]}
    remaining=${remaining#*"$matched"}
    [ -n "$receiver_named" ] || return 0
    # Identifier suffixes are not this object. A newline ends the reference;
    # only same-line key selection proves a named value instead of a mapping.
    if [[ $remaining =~ ^[A-Za-z0-9_]+ ]]; then
      matched=${BASH_REMATCH[0]}
      remaining=${remaining#"$matched"}
      continue
    fi
    [[ $remaining =~ $receiver_named ]] || return 0
  done
  return 1
}

# Selected source keeps its decoding context. env -S replaces its option
# and source word with decoded argv, retaining the env prefix and typed tail.
# The word kind travels too, so every writer keeps the escape judgment.
environment_queue() { # source text, word kind, optional forwarded tag or split-string tail offset
  local code=${#executable_texts[@]} context=conservative cursor launch_names
  [ -z "${forwarded_argument:-}" ] && [ "${3:-}" != forwarded ] || context=forwarded
  executable_texts[code]=$1; executable_kinds[code]=$2; executable_stages[code]=$stage; executable_contexts[code]=$context
  executable_tail_starts[code]=${#executable_tail_args[@]}
  executable_tail_counts[code]=0
  executable_source_kinds[code]=shell; executable_prefix_counts[code]=0
  executable_same_shell[code]=""
  [ "$#" -ne 2 ] || ! runs_in_shell || executable_same_shell[code]=1
  if [ "$#" -eq 3 ] && [ "$3" != forwarded ]; then
    # The inner decode replays this env command's options. Its context starts
    # before that command applies its own chdir.
    local reader_chdir=$split_reader_chdir reader_chdir_unresolved=$split_reader_chdir_unresolved
    executable_source_kinds[code]=env-split
    executable_prefix_counts[code]=$((pos - program_pos))
    for ((cursor=program_pos; cursor<${#args[@]}; cursor++)); do
      [ "$cursor" -ne "$pos" ] || cursor=$3
      [ "$cursor" -lt "${#args[@]}" ] || break
      executable_tail_args[${#executable_tail_args[@]}]=${args[$cursor]}
      executable_tail_kinds[${#executable_tail_kinds[@]}]=${arg_kinds[$cursor]}
      executable_tail_unquoted[${#executable_tail_unquoted[@]}]=${arg_unquoted[$cursor]}
      executable_tail_counts[code]=$((executable_tail_counts[code] + 1))
    done
  fi
  record_reader_context
  executable_reader_context[code]=$reader_context_id
  launch_assignments "${program_pos:-0}"
  executable_assignments[code]=$launch_names
}

# A script operand that names the process's own standard input runs that input.
stdin_path() { # WORD
  case "$1" in /dev/stdin | /dev/fd/0 | /proc/self/fd/0) return 0 ;; esac
  return 1
}

# Shell invocation options precede the executable operand, including options
# after -c. Known literal input stays conservative for every shell invocation;
# script operands and redirects do not prove that the body is unused.
# The same reading names where a shell or interpreter takes the program it
# runs: input_program when it runs its input, and program_word, the index of
# the word holding it, empty where any word can be the program and -1 where
# every word is data. An interpreter option this reading does not name can
# take the next word as its argument, so a script operand counts only when
# no option comes before it.
environment_program_text() {
  local cursor=$pos source="" options_ended="" wants_string="" value text="" source_kind input expanding=""
  local reads_stdin="" uncertain="" optioned=""
  stdin_program=""; source_pos=""; script_operand=""; input_program=""; program_word=""
  environment_receiver "$program"
  if [ "$receiver" = interpreter ]; then
    input_program=1
    for ((cursor=pos; cursor<${#args[@]}; cursor++)); do
      if [[ ${args[$cursor]} =~ $receiver_option ]]; then
        cursor=$((cursor + 1))
        input_program=""; program_word=$cursor
        if [ "${arg_kinds[$cursor]:-}" = literal ] &&
           environment_receiver_evidence "$program" "${args[$cursor]:-}"; then mode=dump-unknown; fi
        break
      fi
      # An attached inline program, as python3 -c'...' spells it.
      if [[ ${args[$cursor]} =~ ${receiver_option%\$}. ]]; then input_program=""; program_word=$cursor; break; fi
      case "${args[$cursor]}" in
        -) program_word=$cursor; break ;;
        --) cursor=$((cursor + 1)) ;;
        -*) optioned=1; continue ;;
      esac
      [ "$cursor" -lt "${#args[@]}" ] || break
      if stdin_path "${args[$cursor]}"; then program_word=-1
      elif [ -z "$optioned" ]; then input_program=""; program_word=$cursor
      fi
      break
    done
    return
  fi
  case "$program" in
    bash | sh | dash | zsh | ksh)
      stdin_program=1
      while [ "$cursor" -lt "${#args[@]}" ]; do
        value=${args[$cursor]}
        # Only a literal word is a known option; an expanding one such as
        # -"$FLAGS" takes the non-literal option-word check below.
        if [ -z "$options_ended" ] && [ "${arg_kinds[$cursor]}" = literal ]; then
          case "$value" in
            --) options_ended=1; cursor=$((cursor + 1)); continue ;;
            --rcfile | --init-file) cursor=$((cursor + 2)); continue ;;
            -[^-]* | +*)
              # A short-option word can combine command-string selection and
              # an option with an operand. Consume the entire invocation word.
              [[ $value != -*c* ]] || wants_string=1
              [[ $value != -*s* ]] || reads_stdin=1
              case "${value:1}" in
                *[oO]*[oO]*)
                  # Grouped option operands cannot be counted, so any later
                  # word can be the command string.
                  for ((cursor=cursor+1; cursor<${#args[@]}; cursor++)); do environment_queue "${args[$cursor]}" "${arg_kinds[$cursor]}"; done
                  input_program=1
                  return ;;
                *o* | *O*) cursor=$((cursor + 2)) ;;
                *) cursor=$((cursor + 1)) ;;
              esac
              continue ;;
            -*) cursor=$((cursor + 1)); continue ;;
          esac
        fi
        # Words after the command string reach it as $0 and "$@", which it
        # can run, so they are forwarded operands like a script's.
        script_operand=$cursor
        if [ -n "$wants_string" ]; then source=$value; source_pos=$cursor
        # A non-literal option word such as "$MODE" can expand to -c, and
        # the next word is then the command string.
        elif [ -z "$options_ended" ] && [ "${arg_kinds[$cursor]}" != literal ] &&
             [ "$((cursor + 1))" -lt "${#args[@]}" ]; then
          environment_queue "${args[$((cursor + 1))]}" "${arg_kinds[$((cursor + 1))]}"
          uncertain=1
        fi
        break
      done
      if [ -n "$wants_string" ]; then program_word=$source_pos
      elif [ -n "$uncertain" ] || [ -z "$script_operand" ]; then input_program=1
      elif [ -n "$reads_stdin" ] || stdin_path "${args[$script_operand]}"; then input_program=1; program_word=-1
      else program_word=$script_operand
      fi ;;
    eval)
      stdin_program=1
      # Bash's eval takes one leading -- before joining its source.
      cursor=$pos
      [ "${args[$cursor]:-}:${arg_kinds[$cursor]:-}" != --:literal ] || cursor=$((cursor + 1))
      source_pos=$cursor
      for ((; cursor<${#args[@]}; cursor++)); do
        source=$source$text${args[$cursor]}; text=' '
      done ;;
    source | .)
      stdin_program=1
      # The script runs its operands as "$@", like a shell script's.
      [ "$pos" -ge "${#args[@]}" ] || script_operand=$pos
      program_word=$script_operand
      if stdin_path "${args[$pos]:-}"; then input_program=1; program_word=-1; fi ;;
    orch-runtime)
      # launch-job runs the argv after its -- as the job's command, so each
      # later word is judged as a possible head, as a script's operands are.
      [ "${args[$pos]:-}:${arg_kinds[$pos]:-}" != launch-job:literal ] || script_operand=$pos ;;
    opaque)
      # Literal input to exec, builtin or a syntax-only stage runs as shell
      # text; environment_dump also judges it with the interpreter patterns.
      [ -z "$data_source" ] || stdin_program=1
      case "${args[$pos]:-}" in
        -S | --split-string) source_pos=$((pos + 1)); source=${args[$source_pos]:-} ;;
        --split-string=*) source_pos=$pos; source=${args[$pos]#*=} ;;
      esac
      # The decoded program, not env itself, owns forwarding these operands.
      # Keep their kinds and boundaries; they are argv, never shell source.
      if [ -n "$source_pos" ]; then
        environment_queue "$source" "${arg_kinds[$source_pos]:-literal}" "$((source_pos + 1))"
      fi
      return ;;
  esac
  [ -n "$source_pos" ] || return 0
  # An eval join holds an ANSI-C escape when any word it joins does.
  source_kind=${arg_kinds[$source_pos]:-literal}
  if [ "$program" = eval ]; then
    for ((cursor=source_pos; cursor<${#args[@]}; cursor++)); do
      [ "${arg_kinds[$cursor]}" != ansi-escaped ] || source_kind=ansi-escaped
      [ "${arg_kinds[$cursor]}" = literal ] || expanding=1
    done
    # A non-literal word can expand to nothing, to options or to several
    # words, so the join need not spell the source eval runs; the complete
    # word evidence also judges it.
    if [ -n "$expanding" ] && environment_main_evidence "$source"; then mode=dump-unknown; return; fi
  fi
  environment_queue "$source" "$source_kind"
}

# The token where the substitution or group opening at INDEX closes, or
# empty when the text ends first.
nesting_close() { # INDEX -> close_at
  local depth=0
  for ((close_at=$1; close_at<${#tokens[@]}; close_at++)); do
    case "${nesting[$close_at]:-}" in
      open*) depth=$((depth + 1)) ;;
      close) depth=$((depth - 1)); [ "$depth" -gt 0 ] || return 0 ;;
    esac
  done
  close_at=""
}

# The tokenizer ends a stage where a substitution or group opens and starts
# one where it closes, so a command a substitution splits ends in the stage
# after the close: its separator is that last part's.
stage_last_part() { # STAGE -> part
  local close_at candidate
  part=$1
  while case "${nesting[${ends[$part]}]:-}" in open*) ;; *) false ;; esac; do
    nesting_close "${ends[$part]}"
    [ -n "$close_at" ] || return 0
    for ((candidate=part+1; candidate<${#starts[@]}; candidate++)); do [ "${starts[$candidate]}" -ne "$((close_at + 1))" ] || break; done
    [ "$candidate" -lt "${#starts[@]}" ] || return 0
    part=$candidate
  done
}

# The words of a command a substitution splits, after the substitution
# closes, for the push and upload walks. The substitution's value is one
# word they cannot read, kind substituted, and a word it is glued to is too.
substitution_tail() {
  local at=$end close_at mark
  tail_args=(); tail_kinds=(); tail_unquoted=(); tail_glued=""
  case "${nesting[$at]:-}:$((end > start))" in open*:1) ;; *) return 0 ;; esac
  [ "${nesting[$at]}" != open-glued ] || tail_glued=1
  while :; do
    mark=${nesting[$at]:-}
    case "$mark" in open*) ;; *) return 0 ;; esac
    if [ "$at" -ne "$end" ] && [ "$mark" = open-glued ] && [ "${#tail_kinds[@]}" -gt 0 ]; then
      tail_kinds[${#tail_kinds[@]} - 1]=substituted
    elif [ "$mark" = open ]; then
      tail_args[${#tail_args[@]}]=""; tail_kinds[${#tail_kinds[@]}]=substituted; tail_unquoted[${#tail_unquoted[@]}]=""
    fi
    nesting_close "$at"
    [ -n "$close_at" ] || return 0
    for ((at=close_at+1; at<${#tokens[@]}; at++)); do
      [ -z "${nesting[$at]:-}" ] || break
      case "${kinds[$at]}" in
        operator | operator-stderr | operator-explicit-other)
          case "${tokens[$at]}" in '|' | ';' | '&&' | '||' | '&') return 0 ;; esac
          at=$((at + 1)); continue ;;
      esac
      tail_args[${#tail_args[@]}]=${tokens[$at]}; tail_kinds[${#tail_kinds[@]}]=${kinds[$at]}; tail_unquoted[${#tail_unquoted[@]}]=${unquoted_words[$at]}
    done
    [ "$at" -lt "${#tokens[@]}" ] || return 0
  done
}

# The transfer checks read a stage literally only where it is plain: each
# word and redirect target literal, with no glob, brace or line
# continuation, in no substitution, subshell, brace group or compound
# command, and not split by one. An env -S text with a word this hook does
# not decode is not plain. A stage that is not plain keeps the first cause
# found, which the report names. Words a stage's walks record from here on
# are that stage's, so the resolver can find them.
transfer_stage_plain() {
  local j cause=""
  stage_uploads_from[stage]=${#upload_programs[@]}; stage_pushes_from[stage]=${#push_remotes[@]}
  [ "$end" -gt "$start" ] || cause=empty-stage
  [ -z "$split_undecoded" ] || cause=${cause:-undecoded-split}
  [ -z "$syntax_head" ] && [ "$compound_depth" -eq 0 ] || cause=${cause:-compound}
  [ "$nesting_depth" -eq 0 ] || cause=${cause:-nesting}
  [ "$start" -eq 0 ] || [ "${nesting[$((start - 1))]:-}" != close ] || cause=${cause:-nesting}
  case "${nesting[$end]:-}" in
    open*) cause=${cause:-nesting}; nesting_depth=$((nesting_depth + 1)) ;;
    close) nesting_depth=$((nesting_depth - 1)) ;;
  esac
  for ((j=start; j<=end; j++)); do
    [ -z "${continued[$j]:-}" ] || cause=${cause:-continuation}
    [ "$j" -lt "$end" ] || break
    case "${kinds[$j]}" in
      literal | dollar-literal) [[ ${unquoted_words[$j]} != *:fields ]] || cause=${cause:-glob} ;;
      operator | operator-stderr | operator-explicit-other) ;;
      *) cause=${cause:-expansion} ;;
    esac
  done
  stage_unplain[stage]=$cause
}

# A stage holds a transfer when a literal word in it names curl, wget, scp or
# rsync, or names git with a later literal push in the same command. A
# stage that holds one is unresolved when it, or any stage of its pipeline,
# is not plain, and an empty stage, which a newline after a pipe leaves, is
# not. Under plain_rule=enforce an unresolved stage's upload records lose
# their host and its push records their remote; where its walks made none,
# scp and rsync get an upload record and a push a push record. Its download
# refuses unless an upload record of the stage refuses it first, under that
# record's reason. Under plain_rule=report the stage keeps the judgement the
# per-form walks give it and the resolver adds one report line per check it
# would fail, which the EXIT trap writes only if the command passes.
transfer_resolve() {
  local stage j k git_at held unresolved part record uploads_end pushes_end
  for ((stage=0; stage<${#starts[@]}; stage++)); do
    held=""; git_at=""; stage_downloads[stage]=""
    for ((j=starts[stage]; j<ends[stage]; j++)); do
      case "${kinds[$j]}" in literal | dollar-literal) ;; *) continue ;; esac
      case "${tokens[$j]##*/}" in
        curl | wget) stage_downloads[stage]=${tokens[$j]##*/}; held=1 ;;
        scp | rsync) held=${held:-${tokens[$j]##*/}} ;;
        git) git_at=${git_at:-$j} ;;
      esac
    done
    if [ -n "$git_at" ]; then
      stage_last_part "$stage"
      for ((j=git_at+1; j<ends[part]; j++)); do
        case "${kinds[$j]}:${tokens[$j]}" in literal:push | dollar-literal:push) git_at=push; break ;; esac
      done
    fi
    uploads_end=${stage_uploads_from[$((stage + 1))]:-${#upload_programs[@]}}
    pushes_end=${stage_pushes_from[$((stage + 1))]:-${#push_remotes[@]}}
    stage_upload_records[stage]=$((uploads_end - stage_uploads_from[stage]))
    stage_unresolved[stage]=""
    [ -n "$held" ] || [ "$git_at" = push ] || continue
    unresolved=${stage_unplain[$stage]}
    k=$stage
    while [ -z "$unresolved" ] && [ "$k" -gt 0 ] && [ "${separators[$((k - 1))]}" = '|' ]; do k=$((k - 1)); unresolved=${stage_unplain[$k]:+pipeline-${stage_unplain[$k]}}; done
    k=$stage
    while [ -z "$unresolved" ] && [ "${separators[$k]}" = '|' ]; do k=$((k + 1)); unresolved=${stage_unplain[$k]-unread}; unresolved=${unresolved:+pipeline-$unresolved}; done
    [ -n "$unresolved" ] || continue
    if [ "$plain_rule" = report ]; then
      if [ "${stage_upload_records[$stage]}" -gt 0 ] || [ "$held" = scp ] || [ "$held" = rsync ]; then
        transfer_reports[${#transfer_reports[@]}]="would=upload-host program=${stage_downloads[$stage]:-$held} cause=$unresolved"
      elif [ -n "$held" ]; then
        transfer_reports[${#transfer_reports[@]}]="would=download-into-shell program=${stage_downloads[$stage]} cause=$unresolved"
      fi
      [ "$git_at" != push ] || transfer_reports[${#transfer_reports[@]}]="would=push-remote program=git cause=$unresolved"
      continue
    fi
    stage_unresolved[stage]=$unresolved
    for ((record=stage_uploads_from[stage]; record<uploads_end; record++)); do upload_hosts[record]=""; done
    for ((record=stage_pushes_from[stage]; record<pushes_end; record++)); do push_reasons[record]=${push_reasons[$record]:-remote}; done
    case "$held:${stage_upload_records[$stage]}" in
      scp:0 | rsync:0) upload_programs[${#upload_programs[@]}]=$held; upload_hosts[${#upload_hosts[@]}]=""; upload_assigned[${#upload_assigned[@]}]="" ;;
    esac
    if [ "$git_at" = push ] && [ "$pushes_end" -eq "${stage_pushes_from[$stage]}" ]; then
      push_remotes[${#push_remotes[@]}]=""; push_reasons[${#push_reasons[@]}]=remote; push_states[${#push_states[@]}]=unknown
      push_base_ends[${#push_base_ends[@]}]=${#push_bases[@]}; push_dir_ends[${#push_dir_ends[@]}]=${#push_dirs[@]}
    fi
  done
}

# A downloaded program runs unread where a shell or interpreter takes it as
# its program: piped, later in the same pipeline, to one that runs its input,
# a subshell such a stage is in or a brace group it begins included, or
# through a substitution that is its program word or its input. The command a substitution sits in carries the
# download on, so its own pipe and enclosing substitution are judged too. A
# forwarded receiver, as after exec, counts on the pipe route only. Under
# plain_rule=enforce a download in a stage the plain-stage rule leaves
# unresolved also refuses, unless an upload record of the stage refuses it.
download_judge() {
  local stage carrier cursor depth outer position word
  for ((stage=0; stage<${#starts[@]}; stage++)); do
    [ -n "${stage_downloads[$stage]:-}" ] || continue
    download_program=${stage_downloads[$stage]}
    carrier=$stage
    while :; do
      download_pipe "$carrier"
      depth=0
      for ((cursor=starts[carrier]-1; cursor>=0; cursor--)); do
        case "${nesting[$cursor]:-}" in
          close) depth=$((depth + 1)) ;;
          open*) if [ "$depth" -eq 0 ]; then break; fi; depth=$((depth - 1)) ;;
        esac
      done
      [ "$cursor" -ge 0 ] || break
      for ((outer=0; outer<carrier; outer++)); do [ "${ends[$outer]}" -ne "$cursor" ] || break; done
      [ "$outer" -lt "$carrier" ] || break
      carrier=$outer
      [ -n "${stage_receivers[$outer]}" ] || continue
      position=${stage_substitutions[$outer]}; word=${stage_program_words[$outer]}
      case "$position" in
        '') continue ;;
        input) [ -n "${stage_input_programs[$outer]}" ] || [ -z "$word" ] || continue ;;
        *) [ -z "$word" ] || [ "$word" -ge "$position" ] || continue ;;
      esac
      download_form=substitution; download_receiver=${stage_receivers[$outer]}
      refuse refused download-into-shell
    done
    if [ -n "${stage_unresolved[$stage]:-}" ] && [ "${stage_upload_records[$stage]:-0}" -eq 0 ]; then
      download_form=unresolved; refuse refused download-into-shell
    fi
  done
}

download_pipe() { # STAGE whose output the walk follows
  local next group depth part
  stage_last_part "$1"; next=$part
  while [ "${separators[$next]}" = '|' ]; do
    next=$((next + 1))
    download_receiver=${stage_input_programs[$next]:-}
    if [ -z "$download_receiver" ] && [ "${starts[$next]}" -eq "${ends[$next]}" ] && [ "${nesting[${ends[$next]}]:-}" = open ]; then
      # Any stage in a subshell that reads the pipe can run what it reads. A
      # brace group opens no nesting mark, so only its first command is read.
      depth=1
      for ((group=next+1; group<${#starts[@]} && depth>0; group++)); do
        download_receiver=${stage_input_programs[$group]:-}
        [ -z "$download_receiver" ] || break
        case "${nesting[${ends[$group]}]:-}" in open*) depth=$((depth + 1)) ;; close) depth=$((depth - 1)) ;; esac
      done
    fi
    [ -z "$download_receiver" ] || { download_form=pipe; refuse refused download-into-shell; }
    stage_last_part "$next"; next=$part
  done
}

# The owner's exception reaches another session only through the
# environment a command gives it, and a shell can set a variable in more
# ways than a reader can list. So a decoded word that names the variable
# refuses, except as an argument of grep, rg or cat, which only search or
# print it; sed is not one, since its scripts can run a command or write a
# file. A name built at runtime is not reached.
owner_word() {
  local cursor
  for ((cursor=0; cursor<${#args[@]}; cursor++)); do
    case "${args[$cursor]}" in *COMMAND_SAFETY_OWNER_COMMAND*) ;; *) continue ;; esac
    if [ -n "${program_pos:-}" ] && [ "$cursor" -gt "$program_pos" ]; then
      case "$program" in grep | rg | cat) continue ;; esac
    fi
    refuse refused owner-command
  done
}

# The host a curl or wget URL names, or the host of an scp or rsync remote
# operand. An expansion or glob in the host part, or a quote, backslash or
# space left in it after shell decoding, can choose any host, so it leaves
# host empty: unresolved, as a substitution does.
# A URL scheme stands only at the start. An scp or rsync host part ends at
# the first colon, except that a bracketed IPv6 host, at the start or right
# after the user's @, ends at its closing bracket; text in a path, a query
# or a remote file name never names the host.
transfer_host() { # WORD KIND url|remote; returns 1 for a local scp or rsync path
  local word=$1 authority bracketed='^(([^@:/[]*@)?\[[^]/]*\]):'
  host=""
  [ "$2" != substituted ] || return 0
  if [ "$3" = remote ] && [[ ! $word =~ ^(scp|sftp|ssh|rsync):// ]]; then
    if [[ $word =~ $bracketed ]]; then
      authority=${BASH_REMATCH[1]}
    else
      authority=${word%%/*}
      if [[ $authority != *:* ]]; then
        # An expansion before the first slash can supply the colon.
        [ "$2" != literal ] && [[ $authority == *[\$\`]* ]] || return 1
        return 0
      fi
      authority=${authority%%:*}
    fi
  else
    [[ ! $word =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]] || word=${word#*://}
    authority=${word%%[/?#]*}
  fi
  authority=${authority##*@}
  case "$authority" in
    '['*) authority=${authority%%]*}] ;;
    *) authority=${authority%%:*} ;;
  esac
  [ "$2" != ansi-escaped ] || return 0
  case "$authority" in '' | *[\$\`\\\*\?\{\}\(\)\'\"[:space:]]*) return 0 ;; esac
  if [[ $authority == *[\[\]]* ]] && [[ ! $authority =~ ^\[[0-9A-Fa-f:.]+\]$ ]]; then return 0; fi
  host=$authority
}

# What curl, wget, scp and rsync send. Each option list is the recorded help
# of curl 8.5.0, GNU Wget, OpenSSH scp and rsync 3.2.7 for the options that
# take a separate argument; an unlisted option is read as a flag, which
# leaves its argument an operand and its host judged. curl and wget send a
# file with the options below; scp and rsync send to a remote last operand.
# A proxy, address mapping, config file or ssh option that sets the host
# leaves the destination unresolved. curl and wget also take a unique prefix
# of a long option, which rsync's popt and scp do not: a word that is no
# listed option and begins a sending or routing one leaves it unresolved.
# curl's --expand- form of an option expands variables into its value, and
# wget's -i reads more URLs from a file.
# curl and wget read proxy variables and a config file their environment
# names, rsync its remote shell; each reads more of its environment than a
# list here would hold. So an assignment before the program word, as a
# prefix or an env or sudo operand, leaves the destination unresolved, as a
# GIT_ assignment leaves a push's remote, and so does one before the exec,
# eval or shell that runs the program. An export earlier in the command is
# not read.
upload_arguments() {
  local cursor=$pos value option argument letters takes short_takes long_takes upload="" redirected="" options_ended=""
  local destinations=() destination_kinds=() host index long_flags=' ' sensitive=' ' candidate assigned launch_names
  case "$program" in
    curl)
      # --head is the one curl 8.5.0 flag that begins a sending option.
      long_flags=' --head '
      sensitive=' --abstract-unix-socket --config --connect-to --data --data-ascii --data-binary --data-urlencode --doh-url --form --header --json --preproxy --proxy --proxy1.0 --resolve --socks4 --socks4a --socks5 --socks5-hostname --unix-socket --upload-file --url --url-query --variable '
      short_takes=AbcCdDeEFHKmoPQrtTuUwxXyYz
      long_takes=' --abstract-unix-socket --alt-svc --aws-sigv4 --cacert --capath --cert --cert-type --ciphers --config --connect-timeout --connect-to --continue-at --cookie --cookie-jar --create-file-mode --crlfile --curves --data --data-ascii --data-binary --data-raw --data-urlencode --delegation --dns-interface --dns-ipv4-addr --dns-ipv6-addr --dns-servers --doh-url --dump-header --egd-file --engine --etag-compare --etag-save --expect100-timeout --form --form-string --ftp-account --ftp-alternative-to-user --ftp-method --ftp-port --ftp-ssl-ccc-mode --happy-eyeballs-timeout-ms --header --hostpubmd5 --hostpubsha256 --hsts --interface --ipfs-gateway --json --keepalive-time --key --key-type --krb --libcurl --limit-rate --local-port --login-options --mail-auth --mail-from --mail-rcpt --max-filesize --max-redirs --max-time --netrc-file --noproxy --oauth2-bearer --output --output-dir --parallel-max --pass --pinnedpubkey --preproxy --proto --proto-default --proto-redir --proxy --proxy1.0 --proxy-cacert --proxy-capath --proxy-cert --proxy-cert-type --proxy-ciphers --proxy-crlfile --proxy-header --proxy-key --proxy-key-type --proxy-pass --proxy-pinnedpubkey --proxy-service-name --proxy-tls13-ciphers --proxy-tlsauthtype --proxy-tlspassword --proxy-tlsuser --proxy-user --pubkey --quote --random-file --range --rate --referer --request --request-target --resolve --retry --retry-delay --retry-max-time --sasl-authzid --service-name --socks4 --socks4a --socks5 --socks5-gssapi-service --socks5-hostname --speed-limit --speed-time --stderr --telnet-option --tftp-blksize --time-cond --tls-max --tls13-ciphers --tlsauthtype --tlspassword --tlsuser --trace --trace-ascii --trace-config --unix-socket --upload-file --url --url-query --user --user-agent --variable --write-out ' ;;
    wget)
      sensitive=' --body-file --config --execute --input-file --post-file '
      short_takes=aABDeiIloOPQRtTUwX
      long_takes=' --accept --append-output --base --bind-address --body-data --body-file --ca-certificate --certificate --config --connect-timeout --directory-prefix --dns-timeout --domains --exclude-directories --exclude-domains --execute --header --http-password --http-user --include-directories --input-file --level --limit-rate --load-cookies --method --output-document --output-file --password --post-data --post-file --private-key --proxy-password --proxy-user --quota --read-timeout --referer --reject --save-cookies --timeout --tries --user --user-agent --wait --waitretry ' ;;
    scp) short_takes=cDFiJloPSX; long_takes=' ' ;;
    rsync)
      short_takes=@BefMT
      long_takes=' --address --backup-dir --block-size --bwlimit --checksum-choice --checksum-seed --chmod --chown --compare-dest --compress-choice --compress-level --contimeout --copy-as --copy-dest --debug --early-input --exclude --exclude-from --files-from --filter --groupmap --iconv --include --include-from --info --link-dest --log-file --log-file-format --max-alloc --max-delete --max-size --min-size --modify-window --only-write-batch --out-format --outbuf --partial-dir --password-file --port --protocol --read-batch --remote-option --rsh --rsync-path --skip-compress --sockopts --stop-after --stop-at --suffix --temp-dir --timeout --usermap --write-batch ' ;;
  esac
  launch_assignments $((pos - 1)); assigned=${launch_names:+1}
  cursor=$pos
  while [ "$cursor" -lt "${#args[@]}" ]; do
    value=${args[$cursor]}; option=""; argument=""; takes=""
    if [ -n "$options_ended" ] || [[ $value != -?* ]]; then
      destinations[${#destinations[@]}]=$value; destination_kinds[${#destination_kinds[@]}]=${arg_kinds[$cursor]}
      [[ ${arg_unquoted[$cursor]} != *:fields ]] || destination_kinds[${#destination_kinds[@]} - 1]=fields
      cursor=$((cursor + 1)); continue
    fi
    case "$program:$value" in
      *:--) options_ended=1 ;;
      # curl 8.5.0 refuses --name=value; a later curl takes it.
      *:--*=*) option=${value%%=*}; argument=${value#*=} ;;
      *:--*) option=$value; takes=long ;;
      *)
        letters=${value#-}
        while [ -n "$letters" ]; do
          case "$short_takes" in
            *"${letters:0:1}"*)
              option=-${letters:0:1}; argument=${letters:1}
              [ -n "$argument" ] || takes=next
              break ;;
          esac
          letters=${letters:1}
        done ;;
    esac
    case "$program:$option" in curl:--expand-?*) option=--${option#--expand-}; redirected=1 ;; esac
    case "$option:$long_takes$long_flags" in
      --?*:*" $option "*) ;;
      --?*)
        for candidate in $sensitive; do
          case "$candidate" in
            "$option"?*) upload=1; redirected=1; [ "$takes" != long ] || takes=next ;;
          esac
        done ;;
    esac
    case "$takes:$long_takes" in
      long:*" $option "* | next:*) cursor=$((cursor + 1)); argument=${args[$cursor]:-} ;;
    esac
    case "$program:$option" in
      curl:-T | curl:--upload-file | wget:--post-file | wget:--body-file) upload=1 ;;
      curl:-d | curl:--data | curl:--data-ascii | curl:--data-binary | curl:--json) [[ $argument != @* ]] || upload=1 ;;
      curl:--data-urlencode) [[ ! $argument =~ ^[^=]*@ ]] || upload=1 ;;
      curl:-H | curl:--header) [[ $argument != @* ]] || upload=1 ;;
      curl:--url-query) [[ ! $argument =~ ^\+?[^=]*@ ]] || upload=1 ;;
      curl:--variable) [[ ! $argument =~ ^[^=]*@ ]] || upload=1 ;;
      curl:-F | curl:--form) case "$argument" in *=@* | *=\<*) upload=1 ;; esac ;;
      curl:--url) destinations[${#destinations[@]}]=$argument; destination_kinds[${#destination_kinds[@]}]=${arg_kinds[$cursor]:-unknown} ;;
      curl:-x | curl:--proxy | curl:--preproxy | curl:--proxy1.0 | curl:--socks4 | curl:--socks4a | curl:--socks5 | curl:--socks5-hostname | \
      curl:--connect-to | curl:--resolve | curl:--unix-socket | curl:--abstract-unix-socket | curl:-K | curl:--config | curl:--doh-url | \
      wget:-e | wget:--execute | wget:--config | wget:-i | wget:--input-file | scp:-F | scp:-J | scp:-S) redirected=1 ;;
      scp:-o | rsync:-e | rsync:--rsh)
        case "$argument" in *[Hh][Oo][Ss][Tt][Nn][Aa][Mm][Ee]* | *[Pp][Rr][Oo][Xx][Yy]* | *-[FJS]*) redirected=1 ;; esac ;;
    esac
    cursor=$((cursor + 1))
  done
  case "$program" in
    curl | wget)
      [ -n "$upload" ] || return 0
      [ "${#destinations[@]}" -gt 0 ] || { destinations=(""); destination_kinds=(unknown); } ;;
    *)
      [ "${#destinations[@]}" -ge 2 ] || return 0
      index=$((${#destinations[@]} - 1))
      destinations=("${destinations[$index]}"); destination_kinds=("${destination_kinds[$index]}") ;;
  esac
  for ((index=0; index<${#destinations[@]}; index++)); do
    case "$program" in
      curl | wget) transfer_host "${destinations[$index]}" "${destination_kinds[$index]}" url ;;
      *) transfer_host "${destinations[$index]}" "${destination_kinds[$index]}" remote || return 0 ;;
    esac
    [ "${destination_kinds[$index]}" != fields ] || host=""
    [ -z "$redirected$assigned" ] || host=""
    upload_programs[${#upload_programs[@]}]=$program
    upload_hosts[${#upload_hosts[@]}]=$host
    upload_assigned[${#upload_assigned[@]}]=$assigned
  done
}

# Permission settings match argv prefixes, subcommands or text patterns, not
# an earlier cd's failure and a later target's execution condition. Bash tool
# submissions can continue after that failure, so this hook relates the existing
# flat stage facts. Nested frames and uncertain words provide no targeting proof.
relative_targeting() { # collect | judge; environment_dump owns the stage facts
  local cursor value recursive="" operands="" options_ended="" relative="" states runnable skipped next_states gate=';' effect previous=""
  if [ "$1" = collect ]; then
    target_effects[stage]=ordinary
    if [ "${#args[@]}" -eq 0 ]; then
      if [ -z "${target_redirects[$stage]}" ]; then
        target_effects[stage]=empty
        [ "$stage" -eq 0 ] || previous=${separators[$((stage - 1))]}
        case "${separators[$stage]}:$previous" in
          '&&:'* | '||:'* | *':&&' | *':||') targeting_eligible="" ;;
        esac
      fi
      return 0
    fi
    [ "$head_start" -eq 0 ] && [ "$program_pos" = 0 ] || { targeting_eligible=""; return 0; }
    case "${args[0]}" in
      cd)
        if [ -n "$cd_operand" ]; then target_effects[stage]=cd; else targeting_eligible=""; fi ;;
      true | :)
        [ "${#args[@]}" -ne 1 ] || [ -n "${target_redirects[$stage]}" ] || target_effects[stage]=success ;;
      false) [ "${#args[@]}" -ne 1 ] || target_effects[stage]=failure ;;
      exit)
        if [ -z "${target_redirects[$stage]}" ] &&
           { [ "${#args[@]}" -eq 1 ] || { [ "${#args[@]}" -eq 2 ] && [[ ${args[1]} =~ ^[+-]?[0-9]+$ ]]; }; }; then target_effects[stage]=exit; fi ;;
      exec | builtin | pushd | popd | set) targeting_eligible="" ;;
    esac
    case "$program" in
      rm)
        for ((cursor=pos; cursor<${#args[@]}; cursor++)); do
          value=${args[$cursor]}
          if [ -z "$operands$options_ended" ]; then
            case "$value" in
              --) options_ended=1; continue ;;
              --recursive) recursive=1; continue ;;
              --force) continue ;;
              -*)
                [[ $value =~ ^-[rRf]+$ ]] || { targeting_eligible=""; return 0; }
                [[ $value != *[rR]* ]] || recursive=1
                continue ;;
            esac
          fi
          if [ -z "$options_ended" ] && [[ $value == -* ]]; then targeting_eligible=""; return 0; fi
          operands=1
          [ -z "$value" ] || [[ $value == /* ]] || relative=1
        done
        if [ -n "$recursive" ] && [ -n "$relative" ]; then target_operands[stage]=1; fi ;;
      git)
        [[ ${args[$pos]:-} != -* ]] || targeting_eligible=""
        if [ "${args[$pos]:-}" = init ]; then
          cursor=$((pos + 1))
          if [ "${args[$cursor]:-}" = -- ]; then options_ended=1; cursor=$((cursor + 1)); fi
          case "$((${#args[@]} - cursor))" in
            0) target_operands[stage]=1 ;;
            1)
              value=${args[$cursor]}
              if [ -z "$options_ended" ] && [[ $value == -* ]]; then targeting_eligible=""
              elif [ -n "$value" ] && [[ $value != /* ]]; then target_operands[stage]=1; fi ;;
            *) targeting_eligible="" ;;
          esac
        fi ;;
    esac
    return 0
  fi
  [ -n "$targeting_eligible" ] && [ -z "$compound" ] || return 1
  # Bits retain correlated outcomes: clean success/failure, then prior-failed-cd
  # success/failure. A skipped command keeps its status; a later cd cannot prove
  # that an earlier failure left the shell in the intended directory.
  states=1
  for ((stage=0; stage<${#starts[@]}; stage++)); do
    runnable=$states
    case "$gate" in '&&') runnable=$((states & 5)) ;; '||') runnable=$((states & 10)) ;; esac
    skipped=$((states ^ runnable))
    if [ "$((runnable & 12))" -ne 0 ] && [ -n "${target_files[$stage]}${target_operands[$stage]}" ]; then return 0; fi
    effect=${target_effects[$stage]}
    next_states=$skipped
    if [ "$effect" = empty ]; then next_states=$states
    elif [ "$effect" != exit ]; then
      if [ "$((runnable & 3))" -ne 0 ]; then
        case "$effect" in success) next_states=$((next_states | 1)) ;; failure) next_states=$((next_states | 2)) ;;
          cd) next_states=$((next_states | 1 | 8)) ;; *) next_states=$((next_states | 3)) ;; esac
      fi
      if [ "$((runnable & 12))" -ne 0 ]; then
        case "$effect" in success) next_states=$((next_states | 4)) ;; failure) next_states=$((next_states | 8)) ;;
          *) next_states=$((next_states | 12)) ;; esac
      fi
    fi
    states=$next_states; gate=${separators[$stage]}
  done
  return 1
}

# A word's quoting is 1 when no byte is quoted, escaped or expanded, ~
# when only bytes after its leading ~/ are, and empty otherwise. The
# tokenizer appends :fields when the word can expand to other than one
# word: an unquoted pathname pattern or parameter expansion, or a quoted
# expansion other than a positional or special parameter.
# Bash expands a tilde prefix, the bytes up to the first
# unquoted /, when none of them is quoted, so a 1 or ~ word starting ~/ is
# expanded. Called where a quote, escape or expansion first touches the word.
word_quoted() {
  [ -z "$bare" ] || [[ $word != '~/'* ]] || tilde='~'
  bare=""
}

# A case statement's patterns each end at a ), which closes no group. From
# its in to its esac no other ) can stand at the depth the case opened at, as
# one there would close an enclosing group before esac, so the tokenizer
# reads each ) there as a pattern's end. case is a reserved word only where
# a command starts. Called with each unquoted literal word the tokenizer
# ends, the word just stored.
case_word() {
  local depth=${#closers[@]} top=$((${#case_depths[@]} - 1)) previous=$((${#tokens[@]} - 2))
  if [ "$top" -ge 0 ] && [ "${case_depths[$top]}" -eq "$depth" ]; then
    case "${case_states[$top]}:$word" in
      subject:in) case_states[top]=arms; case_ins[top]=$((previous + 1)); return ;;
      arms:esac)
        ! esac_reserved "$previous" "${case_ins[$top]}" || unset 'case_depths[top]' 'case_states[top]' 'case_ins[top]'
        return ;;
    esac
  fi
  [ "$word" = case ] || return 0
  if [ "$previous" -ge 0 ]; then
    case "${kinds[$previous]}:${tokens[$previous]}" in
      operator:';' | operator:'&&' | operator:'||' | operator:'|' | operator:'&') ;;
      literal:then | literal:do | literal:else | literal:elif | literal:if | literal:while | literal:until | literal:'{' | literal:'!' | literal:time) ;;
      *) return 0 ;;
    esac
  fi
  case_depths[${#case_depths[@]}]=$depth; case_states[${#case_states[@]}]=subject
}

# esac ends a case only where a command can start or a compound command has
# just ended: after a ; or & terminator, a newline, a ;; or a pattern's ),
# which the tokenizer each stores as ;, after the case's own in, or after a
# reserved fi, done, esac, } or [[ ... ]]. After any other word it is an
# argument, as in echo esac, and the case stays open. After a | it is a
# pattern word, as in a|esac), or in a command a syntax error, as it is
# after && or ||. Bash 5.2 probes: it runs case x in x) if true; then :; fi
# esac and case x in a|esac) ;; esac, and refuses a redirect, |, && or ||
# before a command's esac.
esac_reserved() { # PREVIOUS IN
  local at=$1
  while [ "$at" -ge 0 ] && [ "$at" -ne "$2" ]; do
    case "${kinds[$at]}:${tokens[$at]}" in operator:';' | operator:'&') return 0 ;; esac
    [ "${kinds[$at]}" = literal ] && [ "${unquoted_words[$at]%%:*}" = 1 ] || return 1
    # 'esac' is quoted: Bash 3.2 ends the case at a bare esac pattern word.
    case "${tokens[$at]}" in
      fi | done | 'esac' | '}') ;;
      ']]')
        while [ "$at" -gt 0 ] && [ "${tokens[$at]}:${kinds[$at]}" != '[[:literal' ]; do at=$((at - 1)); done ;;
      *) return 1 ;;
    esac
    at=$((at - 1))
  done
}

environment_dump() { # command kind; arguments are already decoded data
  local LC_ALL=C i=0 c next quote="" word="" active="" kind=literal compound="" bare=1 tilde="" quoted="" fields_unknown=""
  local j start=0 end n fd redirection_kind target proc output input_redirect input_escaped pos program value named flags
  local reader_dirs=(${source_reader_dirs[@]+"${source_reader_dirs[@]}"}) reader_dirs_unresolved=${source_reader_dirs_unresolved:-}
  [ "${#reader_dirs[@]}" -gt 0 ] || reader_dirs=("${cwd:-$PWD}")
  local source_reader_dirs=("${reader_dirs[@]}") source_reader_dirs_unresolved=$reader_dirs_unresolved
  local reader_chdir reader_chdir_unresolved split_reader_chdir split_reader_chdir_unresolved cd_operand cd_destination cd_searched
  local shell_forwarder shell_forwarded_pos selected_forwarder selected_operand next_candidate
  local stage_chdir stage_chdir_unresolved reader_context_id
  local reader_context_paths=() reader_context_starts=() reader_context_counts=() reader_context_uncertain=()
  local stage_reader_context=() executable_reader_context=() executable_assignments=() stage_launches=() launch_names
  # Whether this frame's text runs in the shell of the frame that queued it.
  local same_shell=${queued_same_shell:-} queued_same_shell="" executable_same_shell=() stage_input_same_shell=()
  local mode stage=0 text text_length span span_re comment_span options_ended null_output syntax_head program_pos stdin_program source_pos script_operand data_source piped_source="" deferred_piped_source fallback_sources listing language
  local receiver receiver_pattern receiver_option receiver_named
  local candidate limit producer_end code incoming_sources="" file_output file_body head_start script_pos script_string forwarded_argument=""
  local heredoc_op="" heredoc_origin delimiter line remaining doc body found math_depth=0 needs_target=""
  local name_re='^[A-Za-z_][A-Za-z0-9_]*(=.*)?$' declared_re='^[A-Za-z_][A-Za-z0-9_]*(\+?=.*)?$'
  # What follows a $ in double quotes for one word: the closing quote, which
  # leaves the $ literal, or a positional or special parameter.
  local one_field_re='^("|[0-9#?$!*-]|\{([0-9]+|[#?$!*-])\})'
  local filter_re='^([A-Za-z_][A-Za-z0-9_]*=?|\^[A-Za-z_][A-Za-z0-9_]*=|\^\([A-Za-z_][A-Za-z0-9_]*(\|[A-Za-z_][A-Za-z0-9_]*)+\)=)$'
  local ordinary_span_re=$'^[^\'"\\\\$`# \t\r\n;|()<>&]+'
  local single_span_re="^[^']+" ansi_span_re="^[^'\\\\]+" double_span_re='^[^"\\$`]+' comment_span_re=$'^[^\n]+'
  local tokens=() kinds=() unquoted_words=() saved_quotes=() closers=() args=() arg_kinds=() arg_unquoted=() stage_args=() stage_kinds=() stage_unquoted=() heredocs=() heredoc_tabs=() heredoc_expand=() heredoc_bodies=() body_ids=() stage_sources=() stage_stdin=() stage_fallback=() executable_texts=() executable_stages=()
  local private_inputs=() executable_kinds=() literal_kinds=() escaped_input
  # Per source: split text with an escape, expansion or comment this hook
  # does not decode.
  local split_undecoded=""
  local starts=() ends=() separators=() decisions=() literal_inputs=() input_bodies=() executable_contexts=()
  local targeting_eligible="" target_effects=() target_files=() target_operands=() target_redirects=()
  # The transfer facts each stage records, related once every stage is read.
  local nesting=() continued=() compound_depth=0 nesting_depth=0 input_program program_word last_arg substitution_input
  local stage_unplain=() stage_unresolved=() stage_downloads=() stage_input_programs=()
  local stage_receivers=() stage_program_words=() stage_substitutions=()
  local stage_uploads_from=() stage_pushes_from=() stage_upload_records=()
  local tail_args=() tail_kinds=() tail_unquoted=() tail_glued=""
  # The case statements open at each substitution depth, for case_word.
  local case_depths=() case_states=() case_ins=()
  [ "$1" != shell ] || [ -n "${2:-}" ] || targeting_eligible=1
  local executable_tail_starts=() executable_tail_counts=() executable_tail_args=() executable_tail_kinds=() executable_tail_unquoted=()
  local executable_source_kinds=() executable_prefix_counts=() prefix_count=${command_prefix_count:-0}
  local appended_args=(${command_tail_args[@]+"${command_tail_args[@]}"}) appended_kinds=(${command_tail_kinds[@]+"${command_tail_kinds[@]}"}) appended_unquoted=(${command_tail_unquoted[@]+"${command_tail_unquoted[@]}"})
  tokens=("${appended_args[@]:0:prefix_count}")
  kinds=("${appended_kinds[@]:0:prefix_count}")
  unquoted_words=("${appended_unquoted[@]:0:prefix_count}")
  appended_args=("${appended_args[@]:prefix_count}"); appended_kinds=("${appended_kinds[@]:prefix_count}"); appended_unquoted=("${appended_unquoted[@]:prefix_count}")
  if [ "$1" = env-split ]; then
    ordinary_span_re=$'^[^\'"\\\\$# \t\r\n\v\f]+'
    single_span_re="^[^'\\\\]+"
  fi
  # Only this queued decode consumes the tail. Other recursive sources and
  # input bodies have independent lifetimes and must not inherit it.
  local command_tail_args=() command_tail_kinds=() command_tail_unquoted=() command_prefix_count=0
  if [ "${2:-}" = forwarded ]; then
    forwarded_argument=1
    set -- "$1" conservative "${@:3}"
  fi
  [ "${2:-}" != conservative ] || compound=1
  if [ "$1" = argv ]; then
    tokens=(${command_argv[@]+"${command_argv[@]}"})
    for ((i=0; i<${#tokens[@]}; i++)); do kinds[i]=literal; unquoted_words[i]=""; done
  else
    [ "$1" != expansions ] || quote='"'
    text=$command_text
    text_length=${#text}
    while [ "$i" -lt "$text_length" ]; do
      [ "$1" != expansions ] || [ "${#closers[@]}" -ne 0 ] || kind=heredoc-data
      case "$quote" in
        "'") span_re=$single_span_re ;;
        ansi) span_re=$ansi_span_re ;;
        '"') span_re=$double_span_re ;;
        *) span_re=$ordinary_span_re ;;
      esac
      # Copy literal spans once. Marker handlers keep the quote and routing
      # decisions; growing a word byte by byte exceeds the hook budget.
      if [[ ${text:$i} =~ $span_re ]]; then
        span=${BASH_REMATCH[0]}; word=$word$span; active=1
        if [ -z "$quote$fields_unknown" ] && [ "$1" != env-split ] &&
           [[ $span == *[\*\?\[\{\}]* ]]; then fields_unknown=1; fi
        i=$((i + ${#span}))
        continue
      fi
      c=${text:$i:1}; i=$((i + 1)); next=${text:$i:1}
      # GNU env split-string produces argv, not executable shell structure
      # (the recorded GNU env 9.4 printf probes). Its escapes, expansions and
      # comments have no decoder here, so they cannot prove selected Git argv.
      # Keep the fixed environment check's conservative evidence on that input.
      if [ "$1" = env-split ]; then
        case "$c" in
          '\') split_undecoded=1 ;;
          '$') [ "$quote" = "'" ] || split_undecoded=1 ;;
          '#') [ -n "$quote$active" ] || split_undecoded=1 ;;
        esac
      fi
      if [ "$quote" = ansi ]; then
        case "$c" in
          "'") quote="" ;;
          '\') kind=ansi-escaped; word=$word$c$next; i=$((i + 1)) ;;
          *) word=$word$c ;;
        esac
        continue
      fi
      if [ "$quote" = "'" ]; then
        if [ "$c" = "'" ]; then quote=""; else word=$word$c; fi
        continue
      fi
      if [ "$1" = env-split ] && [ -z "$quote" ]; then
        # Only env's word delimiters enter the shared marker handlers. Every
        # other byte is argv data, including all shell operators and grouping.
        case "$c" in
          ' ' | $'\t' | $'\r' | $'\n' | $'\v' | $'\f') c=' ' ;;
          "'" | '"' | '\' | '$' | '#') ;;
          *) word=$word$c; active=1; continue ;;
        esac
      fi
      if [ "$c" = '\' ]; then
        if [ "$i" -ge "$text_length" ]; then kind=unknown; break; fi
        i=$((i + 1))
        [ "$next" != $'\n' ] || continued[${#tokens[@]}]=1
        [ "$next" = $'\n' ] || { word_quoted; quoted=1; }
        if [ "$quote" = '"' ]; then
          case "$next" in '"' | '\' | '$' | '`' | $'\n') ;; *) word=$word$c ;; esac
        fi
        [ "$next" = $'\n' ] || { word=$word$next; active=1; }
        continue
      fi
      # A substitution's known producer must remain visible inside double
      # quotes. Saving only the enclosing quote grants no inner permission.
      if [ "$1" != env-split ] && { { [ "$c" = '$' ] && [ "$next" = '(' ]; } || [ "$c" = '`' ]; }; then
        if [ -n "$active" ]; then unquoted_words[${#tokens[@]}]=${bare:-$tilde}${fields_unknown:+:fields}; tokens[${#tokens[@]}]=$word; kinds[${#kinds[@]}]=$kind; fi
        # A substitution that opens inside a word belongs to that word.
        nesting[${#tokens[@]}]=open${active:+-glued}
        word=""; active=""; kind=literal; bare=1; tilde=""; quoted=""; fields_unknown=""; compound=1; needs_target=""
        n=${#closers[@]}
        if [ "$c" = '`' ] && [ "$n" -gt 0 ] && [ "${closers[$((n - 1))]}" = '`' ]; then
          nesting[${#tokens[@]}]=close
          quote=${saved_quotes[$((n - 1))]}; unset 'closers[n-1]' 'saved_quotes[n-1]'
        else
          saved_quotes[n]=$quote; quote=""
          if [ "$c" = '$' ]; then
            [ "${text:$((i + 1)):1}" != '(' ] || math_depth=$((n + 1))
            closers[n]=')'; i=$((i + 1))
          else closers[n]='`'; fi
        fi
        [ -z "$quote" ] || bare=""
        unquoted_words[${#tokens[@]}]=""
        tokens[${#tokens[@]}]=';'; kinds[${#kinds[@]}]=operator
        continue
      fi
      if [ "$quote" = '"' ]; then
        if [ "$c" = '"' ] && { [ "$1" != expansions ] || [ "${#closers[@]}" -ne 0 ]; }; then quote=""; else word=$word$c; [ "$c" != '$' ] || [ "$kind" = ansi-escaped ] || kind=unknown; fi
        # Only a positional or special parameter such as "$1", "${2}" or "$#"
        # is proven one word. "$@", ${!name} indirection to name[@] and a
        # nameref to name[@] spread a named expansion, and a nameref can be
        # declared where this decoder cannot see: eval, source, an expanding
        # head, a continued line. So every other expansion counts as unknown.
        if [ "$c" = '$' ] && [[ ! ${text:$i:24} =~ $one_field_re ]]; then fields_unknown=1; fi
        continue
      fi
      case "$c" in
        "'" | '"') quote=$c; active=1; word_quoted; quoted=1; continue ;;
        '$')
          case "$next" in
            "'" | '"')
              quoted=1; quote=$next; [ "$next" != "'" ] || quote=ansi
              # Dollar arguments keep their conservative kind. Only the
              # existing command-head selector can use the literal word.
              [ "$kind" != literal ] || kind=dollar-literal
              i=$((i + 1)) ;;
            *)
              [ "$kind" = ansi-escaped ] || kind=unknown; word=$word$c
              [ "$1" = env-split ] || fields_unknown=1 ;;
          esac
          active=1; word_quoted; continue ;;
        '#')
          if [ -z "$active" ]; then
            if [[ ${text:$i} =~ $comment_span_re ]]; then
              comment_span=${BASH_REMATCH[0]}; i=$((i + ${#comment_span}))
            fi
            continue
          fi ;;
      esac
      case "$c" in
        ' ' | $'\t' | $'\r' | $'\n' | ';' | '&' | '|' | '(' | ')' | '<' | '>')
          redirection_kind=operator
          if [ -n "$heredoc_op" ] && [ -n "$active" ]; then
            [ "$kind" != ansi-escaped ] || { dump_reason=undecoded-ansi-escape; return 0; }
            doc=${#heredocs[@]}
            heredocs[doc]=$word; heredoc_tabs[doc]=$heredoc_op
            heredoc_expand[doc]=""; [ -n "$quoted" ] || heredoc_expand[doc]=1
            body_ids[$heredoc_origin]=$doc
            heredoc_op=""
          # A numeric target remains operand data before a compact redirect.
          # Only a bare word outside that target can establish a descriptor.
          elif [ -z "$needs_target" ] && { [ "$c" = '<' ] || [ "$c" = '>' ]; } && [ -n "$active" ] &&
               [ -n "$bare" ] && [ "$kind" = literal ] && [[ $word =~ ^[0-9]+$ ]]; then
            redirection_kind=operator-explicit-other
            [ "$word" != 2 ] || redirection_kind=operator-stderr
            active=""
          fi
          if [ -n "$active" ]; then
            unquoted_words[${#tokens[@]}]=${bare:-$tilde}${fields_unknown:+:fields}; tokens[${#tokens[@]}]=$word; kinds[${#kinds[@]}]=$kind
            needs_target=""
            [ "$1" = env-split ] || [ "$kind:$bare" != literal:1 ] || case_word
          fi
          word=""; active=""; kind=literal; bare=1; tilde=""; quoted=""; fields_unknown=""
          case "$c" in ' ' | $'\t' | $'\r') continue ;; esac
          case "$c" in
            '(') compound=1; n=${#closers[@]}; saved_quotes[n]=""; closers[n]=')'; c=';'; nesting[${#tokens[@]}]=open ;;
            ')')
              compound=1; n=${#closers[@]}
              # A case pattern's ) ends the pattern and closes nothing.
              if [ "${#case_depths[@]}" -eq 0 ] || [ "${case_depths[${#case_depths[@]} - 1]}" -ne "$n" ] ||
                 [ "${case_states[${#case_states[@]} - 1]}" != arms ]; then
                nesting[${#tokens[@]}]=close
                if [ "$n" -gt 0 ]; then quote=${saved_quotes[$((n - 1))]}; unset 'closers[n-1]' 'saved_quotes[n-1]'; fi
                [ "${#closers[@]}" -ge "$math_depth" ] || math_depth=0
                [ -z "$quote" ] || bare=""
              fi
              c=';' ;;
            $'\n')
              c=';'
              # Keep every declared body in order. Quoting controls outer
              # expansion; the receiving program decides execution later.
              for ((doc=0; doc<${#heredocs[@]}; doc++)); do
                [ -z "${heredoc_bodies[$doc]+present}" ] || continue
                delimiter=${heredocs[$doc]}; body=""; found=""
                while [ "$i" -lt "$text_length" ]; do
                  remaining=${text:$i}; line=${remaining%%$'\n'*}
                  i=$((i + ${#line})); [ "$i" -ge "$text_length" ] || i=$((i + 1))
                  if [ "${heredoc_tabs[$doc]}" = '<<-' ]; then
                    while [[ $line == $'\t'* ]]; do line=${line:1}; done
                  fi
                  if [ "$line" = "$delimiter" ]; then found=1; break; fi
                  body=$body$line$'\n'
                done
                [ -n "$found" ] || return 0
                heredoc_bodies[doc]=$body
              done ;;
            *)
              case "$c$next" in
                '&&' | '||' | '>>' | '>&' | '<&' | '<>' | '&>' | '<<') c=$c$next; i=$((i + 1)) ;;
                # A pipe followed by & also sends stderr down that pipe.
                \|\&) i=$((i + 1)) ;;
              esac
              if [ "$c" = '&>' ] && [ "${text:$i:1}" = '>' ]; then c=$c'>'; i=$((i + 1)); fi
              if [ "$c" = '<<' ] && [ "${text:$i:1}" = '<' ]; then c='<<<'; i=$((i + 1)); fi
              if [ "$c" = '<<' ] && [ "$math_depth" -eq 0 ]; then
                compound=1
                if [ "${text:$i:1}" = - ]; then c='<<-'; i=$((i + 1)); fi
                heredoc_op=$c; heredoc_origin=${#tokens[@]}
              fi ;;
          esac
          unquoted_words[${#tokens[@]}]=""; tokens[${#tokens[@]}]=$c
          if [ "$c" = '<<' ] && [ "$math_depth" -ne 0 ]; then kinds[${#kinds[@]}]=arithmetic
          else
            kinds[${#kinds[@]}]=$redirection_kind
            case "$c" in '<'* | '>'* | '&>'*) needs_target=1 ;; *) needs_target="" ;; esac
          fi ;;
        *) word=$word$c; active=1 ;;
      esac
    done
    if [ -n "$quote" ] && [ "$1" = env-split ]; then split_undecoded=1; fi
    # Undecoded split text can also hide the git word itself.
    [ -z "$split_undecoded" ] || history_record unresolved-git-argv unknown
    [ -z "$quote" ] && [ "${#closers[@]}" -eq 0 ] || compound=1
    if [ -n "$active" ]; then unquoted_words[${#tokens[@]}]=${bare:-$tilde}${fields_unknown:+:fields}; tokens[${#tokens[@]}]=$word; kinds[${#kinds[@]}]=$kind; fi
  fi
  for ((j=0; j<${#appended_args[@]}; j++)); do
    tokens[${#tokens[@]}]=${appended_args[$j]}
    kinds[${#kinds[@]}]=${appended_kinds[$j]}
    unquoted_words[${#unquoted_words[@]}]=${appended_unquoted[$j]}
  done
  # A shell can end a submission before a registered body is read. Evidence
  # must exist before its identifier reaches either expansion or input checks.
  [ -z "$heredoc_op" ] || return 0
  # A forwarded local body cannot gain permission from a later receiver.
  # Check its complete source before expansion or input interpretation.
  if [ -n "$forwarded_argument" ] && [ "${#heredocs[@]}" -gt 0 ] &&
     environment_main_evidence "$text" "${@:3}"; then return 0; fi
  for ((doc=0; doc<${#heredocs[@]}; doc++)); do
    [ -n "${heredoc_bodies[$doc]+present}" ] || return 0
    [ -z "${heredoc_expand[$doc]}" ] || {
      local command_text=${heredoc_bodies[$doc]:-}
      if [ "$#" -ge 3 ]; then
        if environment_dump expansions conservative "${@:3}"; then return 0; fi
      else
        if environment_dump expansions conservative; then return 0; fi
      fi
    }
  done
  # A heredoc body is text, not a word: its own quoting is judged where it
  # is parsed. The drain hands on no ANSI-C escaped input; it refuses first.
  literal_inputs=(${heredoc_bodies[@]+"${heredoc_bodies[@]}"})
  for ((doc=0; doc<${#literal_inputs[@]}; doc++)); do literal_kinds[doc]=literal; done
  for ((doc=3; doc<=$#; doc++)); do
    n=${#literal_inputs[@]}; literal_inputs[n]=${!doc}; literal_kinds[n]=literal
    incoming_sources="$incoming_sources $n"
  done
  n=${#tokens[@]}
  for ((i=0; i<=n; i++)); do
    if [ "$i" -lt "$n" ]; then
      if [ -n "$targeting_eligible" ]; then
        case "${kinds[$i]}" in
          literal)
            # Whole-word quote evidence cannot distinguish protected wildcard
            # fragments from active ones. Exclude both, without another reader.
            case "${tokens[$i]}" in *'*'* | *'?'* | *'['* | *']'* | *'{'* | *'}'* | *'~'*) targeting_eligible="" ;; esac ;;
          operator | operator-stderr | operator-explicit-other)
            case "${tokens[$i]}" in ';' | '&&' | '||' | '<' | '>' | '>>' | '<>' | '&>' | '&>''>' | '>&' | '<&') ;; *) targeting_eligible="" ;; esac ;;
          *) targeting_eligible="" ;;
        esac
      fi
      [ "${kinds[$i]}" = operator ] || continue
      case "${tokens[$i]}" in '|' | ';' | '&&' | '||' | '&') ;; *) continue ;; esac
    fi
    starts[stage]=$start; ends[stage]=$i
    separators[stage]=${tokens[$i]:-end}; stage=$((stage + 1)); start=$((i + 1))
  done
  for ((stage=0; stage<${#starts[@]}; stage++)); do
    start=${starts[$stage]}; end=${ends[$stage]}; args=(); arg_kinds=(); arg_unquoted=()
    target_files[stage]=""; target_operands[stage]=""; target_redirects[stage]=""; target_effects[stage]=ordinary
    reader_chdir=""; reader_chdir_unresolved=""
    private_inputs=(); last_arg=""; proc=""; output=""; input_redirect=""; input_escaped=""; mode=other; program=""; program_pos=""; data_source=""; fallback_sources=""; file_output=""; file_body=""
    for ((j=start; j<end; j++)); do
      case "${kinds[$j]}" in operator | operator-stderr | operator-explicit-other)
        fd=${kinds[$j]}
        j=$((j + 1)); target=${tokens[$j]:-}
        target_redirects[stage]=1
        case "${tokens[$((j - 1))]}" in
          '>' | '>>' | '<>' | '&>' | '&>''>')
            case "$target" in /*) ;; .git | .git/* | */.git | */.git/*) target_files[stage]=1 ;; esac ;;
        esac
        case "${tokens[$((j - 1))]}" in
          '<' | '<>')
            input_redirect=1
            private_inputs[${#private_inputs[@]}]=$target
            [ "${kinds[$j]:-}" != ansi-escaped ] || input_escaped=1
            if proc_environment_path "$target"; then proc=1; fi
            [ "${tokens[$((j - 1))]}" != '<>' ] || output=1 ;;
          '<&') input_redirect=1 ;;
          '<<' | '<<-')
            input_redirect=1
            doc=${body_ids[$((j - 1))]:-}
            [ -n "$doc" ] || return 0
            if [ "$fd" = operator ] && [ "${tokens[$((j - 1))]}" = '<<' ] &&
               [ "${kinds[$j]:-}" = literal ]; then
              file_body=1; [ -z "${heredoc_expand[$doc]}" ] || file_body=expanding
            fi
            data_source="$data_source $doc" ;;
          '<<<')
            input_redirect=1; doc=${#literal_inputs[@]}; literal_inputs[doc]=$target
            literal_kinds[doc]=${kinds[$j]:-literal}
            data_source="$data_source $doc" ;;
          '>')
            [ "$fd" = operator-stderr ] || output=1
            if [ "$fd" = operator ] && [ "${kinds[$j]:-}" = literal ]; then file_output=1; fi ;;
          '>>')
            [ "$fd" = operator-stderr ] || output=1
            if [ "$fd" = operator ] && [ "${kinds[$j]:-}" = literal ]; then file_output=append; fi ;;
          '>&') [ "$fd" = operator-stderr ] || output=1 ;;
          '&>' | '&>''>') output=1 ;;
        esac
        continue ;;
      esac
      n=${#args[@]}
      args[n]=${tokens[$j]}; arg_kinds[n]=${kinds[$j]}; arg_unquoted[n]=${unquoted_words[$j]}; last_arg=$j
    done
    # A stage that ends where a substitution opens takes its output as the
    # word at this position, or as input after <, << or <<<.
    stage_substitutions[stage]=""
    case "${nesting[$end]:-}:$((end > start))" in
      open*:1)
        if [ "$last_arg" = "$((end - 1))" ]; then
          stage_substitutions[stage]=${#args[@]}
          [ "${nesting[$end]}" != open-glued ] || stage_substitutions[stage]=$((${#args[@]} - 1))
        else
          # The operator, or the redirect target it takes.
          substitution_input=$((end - 1))
          case "${kinds[$substitution_input]}" in operator*) ;; *) substitution_input=$((end - 2)) ;; esac
          case "${tokens[$substitution_input]:-}" in '<' | '<>' | '<<<') stage_substitutions[stage]=input ;; esac
        fi ;;
    esac
    substitution_tail
    environment_head "$1"
    [ -z "$syntax_head" ] || compound=1
    transfer_stage_plain
    if [ "$pos" -ge "${#args[@]}" ]; then
      program=opaque
    fi
    environment_producer "$1"
    launch_assignments "${program_pos:-0}"; stage_launches[stage]=$launch_names
    [ -n "${transfer_ignored:-}" ] || owner_word
    # A shell can set CDPATH in more ways than a reader can list, so any
    # decoded word that names it counts, as owner_word counts its variable.
    if [ -z "${transfer_ignored:-}" ]; then
      for value in ${args[@]+"${args[@]}"}; do case "$value" in *CDPATH*) push_cdpath_named=1 ;; esac; done
    fi
    cd_operand=""; cd_destination=""; cd_searched=""
    if [ "$program" = cd ] && [ "$head_start" -eq 0 ] && [ "$program_pos" = 0 ]; then
      literal_cd_operand || :
    fi
    directory_change
    [ -z "$targeting_eligible" ] || relative_targeting collect
    # A /proc environ input only these readers' arms can classify. Any other
    # program, such as a shell reading its descriptors, can print it.
    case "$program" in cat | strings | tr | xargs) ;; *) [ -z "$proc" ] || mode=dump-unknown ;; esac
    # Plain pipe text must reach the receiver's source decision. Other word
    # kinds keep their late arrival: opaque receivers treat escaped pipes as data.
    deferred_piped_source=""
    if [ "$stage" -gt 0 ] && [ "${separators[$((stage - 1))]}" = '|' ]; then
      for doc in $piped_source; do
        if [ "${literal_kinds[$doc]}" = literal ]; then
          data_source="$data_source $doc"
        else
          deferred_piped_source="$deferred_piped_source $doc"
        fi
      done
    fi
    environment_program_text
    stage_input_programs[stage]=${input_program:+$program}
    stage_input_same_shell[stage]=""
    [ -z "$stdin_program" ] || ! runs_in_shell || stage_input_same_shell[stage]=1
    stage_receivers[stage]=""
    case "$receiver" in shell | interpreter) stage_receivers[stage]=$program ;; esac
    stage_program_words[stage]=$program_word
    [ -z "$stdin_program$script_operand" ] || targeting_eligible=""
    # Supported shell source keeps this classification check in its queue.
    # Other unclassified forwarded argv retains the complete read evidence.
    if [ "$mode" = unclassified-forwarded ]; then
      mode=other
      if [ -z "$stdin_program" ] && environment_main_evidence "${args[@]}"; then mode=dump-unknown; fi
    fi
    # Scan all forwarded operands for conservative detection. Only the
    # selected builtin dispatch can transfer the stdin directory.
    script_pos=$script_operand; script_string=$source_pos
    selected_forwarder=$shell_forwarder; selected_operand=$shell_forwarded_pos
    if [ -n "$selected_forwarder" ]; then
      script_pos=$program_pos; script_string=""
    fi
    data_source="$data_source$deferred_piped_source"
    # The approved data and file-writing classes are data. Every other
    # heredoc body an unknown receiver gets is judged alone as shell source
    # below. A here-string is judged only here, for an opaque stage, and as
    # a shell's input.
    for doc in $data_source; do
      # Input to exec, builtin or a syntax-only stage, piped input included,
      # can reach an interpreter as well as run as shell text.
      if [ "$program" = opaque ]; then
        for language in python node ruby perl; do
          if environment_receiver_evidence "$language" "${literal_inputs[$doc]}"; then return 0; fi
        done
      fi
      [ "$doc" -lt "${#heredocs[@]}" ] || continue
      if [ -z "${2:-}$incoming_sources" ] && [ "$1" = shell ] &&
         [ "$receiver" = data ] && [ "$mode" = other ] && [ "${#args[@]}" -eq 1 ] &&
         [ "$file_output" = 1 ] && [ "$file_body" = 1 ] &&
         [ "$program_pos" = 0 ] && [ "$head_start" -eq 0 ] && [ "${arg_kinds[0]}" = literal ] &&
         [ "$data_source" = " $doc" ]; then continue; fi
      if [ "$1" = shell ] && [ -z "${2:-}$incoming_sources" ] &&
         [ "$mode" = other ] && [ -z "$stdin_program" ]; then
        case "$receiver" in
          interpreter)
            if environment_receiver_evidence "$program" "${literal_inputs[$doc]}"; then return 0; fi
            continue ;;
          data)
            if [ "${#heredocs[@]}" -eq 1 ] && [ "$data_source" = " 0" ] &&
               [ "$program_pos" = 0 ] && [ "$head_start" -eq 0 ] && [ "${arg_kinds[0]}" = literal ] &&
               { [ "$file_body" = 1 ] || { [ -z "$input_redirect" ] && [ -n "$piped_source" ] &&
                 [ -z "${heredoc_expand[$doc]}" ] && [ "${heredoc_tabs[$doc]}" = '<<' ]; }; }; then continue; fi ;;
        esac
      fi
      [ -n "$stdin_program" ] || fallback_sources="$fallback_sources $doc"
    done
    stage_stdin[stage]=$stdin_program; stage_sources[stage]=$data_source; stage_fallback[stage]=$fallback_sources
    if [ -n "$data_source$incoming_sources" ]; then
      record_reader_context
      stage_reader_context[stage]=$reader_context_id
    fi
    if [ -n "$script_pos" ]; then
      case "$mode" in dump-*) return 0 ;; esac
      stage_args=(${args[@]+"${args[@]}"}); stage_kinds=(${arg_kinds[@]+"${arg_kinds[@]}"})
      stage_unquoted=(${arg_unquoted[@]+"${arg_unquoted[@]}"})
      stage_chdir=$reader_chdir; stage_chdir_unresolved=$reader_chdir_unresolved
      for ((candidate=script_pos+1; candidate<${#stage_args[@]}; candidate++)); do
        # The approved ordinary quoted-data class has the same recorded
        # receiver, head and argument bounds. It recognizes no inner words.
        if [ "$1" = shell ] && [ -z "${2:-}$compound" ] && [ "$program" = bash ] && [ -z "$source_pos" ] && [ -z "$syntax_head" ] &&
           [ "${#stage_args[@]}" -eq 3 ] && [ "$candidate" -eq 2 ] && [ "${#starts[@]}" -eq 1 ] &&
           [ "$start" -eq 0 ] && [ "$end" -eq 3 ] && [ "${stage_kinds[1]}" = literal ] &&
           [ "$program_pos" = 0 ] && [ "${stage_kinds[$candidate]}" = literal ] &&
           [ "${stage_unquoted[$candidate]%%:*}" != 1 ] && [ -z "$input_redirect$output" ]; then continue; fi
        # A shell or source script and orch-runtime launch-job execute
        # forwarded argv, so each operand is judged as a possible head by
        # the one producer, beside its own operands.
        limit=${#stage_args[@]}
        args=("${stage_args[@]:candidate:limit-candidate}")
        arg_kinds=("${stage_kinds[@]:candidate:limit-candidate}")
        arg_unquoted=("${stage_unquoted[@]:candidate:limit-candidate}")
        program=""; pos=0; mode=other; producer_end=0; program_pos=""
        reader_chdir=$stage_chdir; reader_chdir_unresolved=$stage_chdir_unresolved
        inherited_assignments=${stage_launches[$stage]} environment_producer shell
        inherited_assignments=${stage_launches[$stage]} environment_program_text
        directory_change
        [ -z "$stdin_program" ] || stage_stdin[stage]=1
        [ -z "$stdin_program" ] || ! runs_in_shell || stage_input_same_shell[stage]=1
        [ -z "$input_program" ] || stage_input_programs[stage]=$program
        if [ "$candidate" = "$selected_operand" ]; then
          selected_operand=""
          case "$selected_forwarder" in
            builtin)
              selected_forwarder=$shell_forwarder
              if [ -n "$shell_forwarded_pos" ]; then
                selected_operand=$((candidate + shell_forwarded_pos))
              elif [ "$shell_forwarder" = exec ] && [ -n "$reader_chdir_unresolved" ] &&
                   [ -n "$data_source$incoming_sources" ]; then
                # The producer could not bound this exec's argv.
                record_reader_context
                stage_reader_context[stage]=$reader_context_id
              fi ;;
            exec)
              if [ -n "$stdin_program" ] &&
                 [ -n "$data_source$incoming_sources" ] && [ -n "$reader_chdir$reader_chdir_unresolved" ]; then
                record_reader_context
                stage_reader_context[stage]=$reader_context_id
              fi ;;
          esac
        fi
        case "$mode" in dump-*) return 0 ;; esac
        # A quoted operand past the program can be a whole command string,
        # and so can an expanding one, whose producer selection stops at 0;
        # after a command string, every quoted operand can be, $0 included.
        if { [ -n "$script_string" ] || [ "$candidate" -gt "$((script_pos + 1))" ]; } && [ -z "$output" ] &&
           [ "${stage_unquoted[$candidate]%%:*}" != 1 ] && [ "$producer_end" -le 1 ]; then
          inherited_assignments=${stage_launches[$stage]} environment_queue "${stage_args[$candidate]}" "${stage_kinds[$candidate]}" forwarded
        fi
        if [ "$producer_end" -gt 1 ]; then
          next_candidate=$((candidate + producer_end - 1))
          # An exploratory candidate can span the proven executable.
          if [ -n "$selected_operand" ] && [ "$selected_operand" -lt "$next_candidate" ]; then
            next_candidate=$selected_operand
          fi
          candidate=$((next_candidate - 1))
        fi
      done
      mode=opaque-clean
    fi
    case "$mode" in dump-*) [ -z "$output" ] || mode=unrouted ;; esac
    decisions[stage]=$mode
    case "${separators[$stage]}" in
      '|' | '&') ;;
      # A CDPATH word can send a searched cd anywhere, by push_judge's rule.
      *)
        if [ -n "$cd_searched" ] && [ -n "$push_cdpath_named" ]; then reader_dirs_unresolved=1
        elif [ -n "$cd_destination" ]; then remember_reader_directory "$cd_destination"; fi ;;
    esac
    piped_source=$data_source
    # Echo's plain operands define its output without another shell parser.
    # Options, escapes and expanding words need runtime interpretation.
    if [ "$program" = echo ] && [ "${separators[$stage]}" = '|' ] && [ -z "$output" ]; then
      text=""; span=""; named=1
      for ((j=pos; j<${#args[@]}; j++)); do
        [ "${arg_kinds[$j]}" = literal ] || { named=""; break; }
        value=${args[$j]}
        case "$value" in *\\*) named=""; break ;; esac
        if [ "$j" -eq "$pos" ]; then
          case "$value" in -*) named=""; break ;; esac
        fi
        text=$text$span$value; span=' '
      done
      if [ -n "$named" ]; then
        doc=${#literal_inputs[@]}; literal_inputs[doc]=$text$'\n'; literal_kinds[doc]=literal
        piped_source=" $doc"
      fi
    fi
  done
  [ -n "${transfer_ignored:-}" ] || transfer_resolve
  for ((stage=0; stage<${#decisions[@]}; stage++)); do
    data_source=${stage_sources[$stage]}
    data_source="$data_source $incoming_sources"
    input_bodies=(); escaped_input=""
    for doc in $data_source; do
      input_bodies[${#input_bodies[@]}]=${literal_inputs[$doc]}
      [ "${literal_kinds[$doc]}" != ansi-escaped ] || escaped_input=1
    done
    # A command string can start a shell that reads the same stdin. This
    # check has no ANSI-C decoder, so an escaped source, or escaped input
    # handed to one, refuses here, whichever writer queued it.
    for ((code=0; code<${#executable_texts[@]}; code++)); do
      [ "${executable_stages[$code]}" -eq "$stage" ] || continue
      if [ "${executable_kinds[$code]}" = ansi-escaped ] || [ -n "$escaped_input" ]; then
        dump_reason=undecoded-ansi-escape; return 0
      fi
      local command_text=${executable_texts[$code]}
      local tail_start=${executable_tail_starts[$code]:-0} tail_count=${executable_tail_counts[$code]:-0}
      command_tail_args=("${executable_tail_args[@]:tail_start:tail_count}")
      command_tail_kinds=("${executable_tail_kinds[@]:tail_start:tail_count}")
      command_tail_unquoted=("${executable_tail_unquoted[@]:tail_start:tail_count}")
      command_prefix_count=${executable_prefix_counts[$code]:-0}
      load_reader_context "${executable_reader_context[$code]}"
      if inherited_assignments=${executable_assignments[$code]} queued_same_shell=${executable_same_shell[$code]:-} environment_dump "${executable_source_kinds[$code]:-shell}" "${executable_contexts[$code]:-conservative}" ${input_bodies[@]+"${input_bodies[@]}"}; then return 0; fi
    done
    command_tail_args=(); command_tail_kinds=(); command_tail_unquoted=(); command_prefix_count=0
    # A stdin shell runs every body; an unknown receiver may run the ones
    # no data class admitted. These identifiers come only from the proved
    # registry. Keep bodies independent: quotes in one program cannot hide
    # another program.
    local fallback_only=${transfer_ignored:-}
    [ -n "${stage_stdin[$stage]}" ] || { data_source=${stage_fallback[$stage]}; fallback_only=1; }
    for doc in $data_source; do
      [ "${literal_kinds[$doc]}" != ansi-escaped ] || { dump_reason=undecoded-ansi-escape; return 0; }
      local command_text=${literal_inputs[$doc]}
      load_reader_context "${stage_reader_context[$stage]}"
      if inherited_assignments=${stage_launches[$stage]} queued_same_shell=${stage_input_same_shell[$stage]:-} transfer_ignored=$fallback_only environment_dump shell conservative; then return 0; fi
    done
  done
  for ((stage=0; stage<${#decisions[@]}; stage++)); do
    case "${decisions[$stage]}" in
      unrouted | dump-unknown) return 0 ;;
      dump-lines | dump-nul)
        [ -z "$compound" ] || return 0
        j=$stage
        if [ "${decisions[$stage]}" = dump-nul ]; then
          if [ "${separators[$j]}" != '|' ] || [ "${decisions[$((j + 1))]:-}" != convert ]; then return 0; fi
          j=$((j + 1))
        fi
        if [ "${separators[$j]}" != '|' ] || [ "${decisions[$((j + 1))]:-}" != filter ]; then return 0; fi ;;
    esac
  done
  [ -n "$owner_command${transfer_ignored:-}" ] || download_judge
  if relative_targeting judge; then refuse refused relative-target; fi
  return 1
}

# Every line this hook writes, and the only place its text lives. The first
# line is the contract a reader parses, `command-safety: <key>=<value>`: a
# stable key for the condition and the value acted on — the missing tool, why
# the payload could not be read, the state of the project policy, or the exit
# status of a check that did not complete. The English explanation follows it.
# The keyed line stands first, at position 1. What a command this hook runs
# wrote is captured where the hook reads it and passed here as the cause, so
# it is replayed under the key rather than ahead of it.
# The EXIT trap below calls this, so the whole message is one group that
# cannot carry a failure out: a write that fails there would leave with the
# writer's status rather than the refusal's, which the harness runs past.
refuse() { # KEY VALUE [CAUSE]
  loading=""
  {
    printf 'command-safety: %s=%s\n' "$1" "$2"
    case "$1=$2" in
      missing-tools=*) echo "the commands ${2//,/, } are required and are not on PATH" ;;
      payload=unreadable) echo "the hook input could not be read" ;;
    cwd=*) echo "the working directory $2 could not be entered" ;;
      payload=invalid-json) echo "the hook input is not valid JSON, or names no command this hook can read" ;;
      payload=invalid-cwd) echo "the payload's working directory is not a string" ;;
        git=unreadable) echo "the Git working directory could not be resolved" ;;
      hook=unlocatable) echo "this hook's own directory could not be read, so its installed dependencies cannot be found" ;;
      settings=no-loader) echo "the command-safety bundle requires the installed commit-guards settings loader" ;;
      support=unreadable) echo "the installed commit-guards support could not be loaded; repair that installation; its diagnostic follows" ;;
      settings=unreadable) echo "the project settings could not be read, so the project command policies are unknown; the loader's line below names what to fix" ;;
      settings=invalid-history-policy) echo "COMMAND_SAFETY_HISTORY_POLICY must be off or no-lazy-fetch; the history check is unavailable" ;;
      settings=empty) echo "COMMAND_SAFETY_DENY_PATTERN must be configured" ;;
      settings=invalid-pattern) echo "COMMAND_SAFETY_DENY_PATTERN is not a readable POSIX ERE" ;;
      refused=policy) echo "the command text matches this project's COMMAND_SAFETY_DENY_PATTERN" ;;
      refused=relative-target)
        echo "a failed directory change can reach a relative recursive delete, git init or .git write in this literal command list"
        echo "make the target depend on a successful directory change with &&, stop on failure, or use a verified literal absolute target"
        echo "earlier failed directory changes remain possible even after a later cd; nested, dynamic and unsupported forms have no targeting proof" ;;
      refused=history-policy)
        printf 'command-safety: reason=%s\n' "$history_reason"
        echo "COMMAND_SAFETY_HISTORY_POLICY requires the literal global --no-lazy-fetch option before each reached Git history or diff subcommand"
        echo "submit literal Git global options and put --no-lazy-fetch before the subcommand, for example: git --no-lazy-fetch log -1 --oneline HEAD"
        echo "use Git 2.45.1 or later, the first release whose diff prefetch honours that option; counts, refs, paths, formats and GIT_NO_LAZY_FETCH alone grant no exception" ;;
      refused=environment-dump)
        # An undecoded escape is refused as unknown, not as a recognized read,
        # so it gets its own reason and remedy.
        if [ -n "${dump_reason:-}" ]; then
          printf 'command-safety: reason=%s\n' "$dump_reason"
          echo "the shell runs a word holding an ANSI-C escape, a backslash inside \$'...', and this check does not decode those escapes"
          echo "decode the escape in the command text, or pass the value as a literal argument"
        else
          echo "the command contains a recognized private-file read or a whole-environment read without a proven direct named-variable filter"
          echo "for named non-secret settings, use orch-env NAME DEFAULT; do not read or filter the private file"
          echo "for unit state, put the named property before show: systemctl --user --property=ActiveState show -- UNIT"
          echo "for process metadata, select fields without environment flags, for example: ps -A -o pid,comm"
          echo "for actual environment producers, read named variables, for example: systemctl --user show-environment | grep '^NAME='"
          echo "nested or unsupported environment routing can refuse conservatively; use the direct filtered form for environment producers"
        fi ;;
      refused=download-into-shell)
        case "$download_form" in
          pipe)
            echo 'command-safety: form=pipe'
            echo "the command pipes what $download_program downloads into $download_receiver, which runs it as a program before anyone reads it" ;;
          substitution)
            echo 'command-safety: form=substitution'
            echo "a substitution gives what $download_program downloads to $download_receiver as the program it runs, before anyone reads it" ;;
          *)
            echo 'command-safety: reason=unresolved-receiver'
          echo "the command holds $download_program in a form this check does not read: an expansion, a substitution, a glob, a line continuation, a group or a compound command, in its stage or its pipeline, so a shell could run what it downloads" ;;
        esac
        echo "write the download as one plain pipeline with literal words; to run what it fetches, save it to a file in one command, read the file, then run it in a separate command"
        echo "if the owner asked for this exact command, the owner starts the session with COMMAND_SAFETY_OWNER_COMMAND set to its text" ;;
      refused=upload-host)
        if [ -n "$upload_host" ]; then
          printf 'command-safety: host=%s\n' "${upload_host//$'\n'/\\n}"
          echo "$upload_program sends local data to $upload_host, which COMMAND_SAFETY_UPLOAD_HOSTS does not list"
        elif [ "$upload_cause" = assignment ]; then
          echo 'command-safety: reason=unresolved-host'
          echo 'command-safety: cause=assignment'
          echo "$upload_program sends local data, and an assignment before it, such as a proxy variable, CURL_HOME, HOME or RSYNC_RSH, can choose where it goes"
        else
          echo 'command-safety: reason=unresolved-host'
          echo "$upload_program sends local data, and the command can choose where it goes: an abbreviated option, a proxy, an address mapping or a config file, or a form this check does not read, an expansion, a substitution, a glob, a line continuation, a group or a compound command"
        fi
        if [ "$upload_cause" = assignment ]; then
          echo "remove the assignment before $upload_program, and send it only to a host the project owner lists in COMMAND_SAFETY_UPLOAD_HOSTS under [env] in kendex.settings.toml"
        else
          echo "send it only to a host the project owner lists in COMMAND_SAFETY_UPLOAD_HOSTS under [env] in kendex.settings.toml, named literally in a plain pipeline"
        fi
        echo "if the owner asked for this exact command, the owner starts the session with COMMAND_SAFETY_OWNER_COMMAND set to its text" ;;
      refused=push-remote)
        case "$push_reason:$push_cause" in
          remote:config)
            echo 'command-safety: reason=unresolved-remote'
            echo 'command-safety: cause=remote-change'
            echo "a git remote, git config or inline alias in this command can change where git push goes, so the push cannot be compared with the repository's remotes" ;;
          remote:*)
            echo 'command-safety: reason=unresolved-remote'
            echo "the command can choose where git push goes: a Git setting, a GIT_ variable, an abbreviated or unknown option, or a form this check does not read, an expansion, a substitution, a glob, a line continuation, a group or a compound command, so the push cannot be compared with the repository's remotes" ;;
          repository:*)
            echo 'command-safety: reason=unresolved-repository'
            echo "the repository this git push runs in is not known: a directory change, -C, --git-dir or GIT_DIR the check cannot follow, an unquoted leading ~, or a directory that is not in a Git work tree yet" ;;
          unreadable:*)
            echo 'command-safety: reason=unreadable-repository'
            echo "git could not list the remotes of the repository at $push_repository; repair what git names below, then retry" ;;
          *)
            printf 'command-safety: remote=%s\n' "${push_remote//$'\n'/\\n}"
            echo "git push names $push_remote, which is neither a remote of the repository at $push_repository nor one of its remote URLs" ;;
        esac
        if [ "$push_cause" = config ]; then
          echo "run the remote or configuration change as its own command, then push in a separate command"
        else
          echo "push to a remote the repository already has, by its name, in a plain pipeline from a directory named literally, for example: git push origin HEAD"
        fi
        echo "a new destination is the owner's choice: the owner adds the remote, or starts the session with COMMAND_SAFETY_OWNER_COMMAND set to this exact command" ;;
      report=plain-stage)
        for line in ${transfer_reports[@]+"${transfer_reports[@]}"}; do printf 'command-safety: %s\n' "$line"; done
        echo "the plain-stage rule reports and does not refuse: each stage above holds curl, wget, scp, rsync or git push in a form the transfer checks passed but do not read literally, an expansion, a substitution, a glob, a line continuation, a group or a compound command, in the stage or its pipeline" ;;
      refused=owner-command)
        echo "a word of the command names COMMAND_SAFETY_OWNER_COMMAND, the owner's exception for one exact command, and a command that names it can give it to a session it starts"
        echo "run the command without that name; to search for it or print a file that holds it, use grep, rg or cat; only the owner sets it, in the environment a session starts with" ;;
      refused=default-policy)
        echo "the command text sets a systemd-run MemoryMax= or MemoryHigh= cap in kilobytes or megabytes, which the hook's default COMMAND_SAFETY_DENY_PATTERN refuses: a cgroup starved by a cap that small can fail a kernel allocation and leave the host's root volume read-only"
        echo "run it with no memory cap, or with a cap in gigabytes; text that only mentions such a cap goes in a file, because matching reads the command text"
        echo "a project that wants another pattern sets COMMAND_SAFETY_DENY_PATTERN in kendex.settings.toml [env] to replace the default, and the value \"^\$\" turns only project-pattern matching off; the fixed environment-dump refusal remains active" ;;
      exit=*) echo "the command safety check could not complete" ;;
    esac
    # The cause a command this hook ran wrote, captured at the site and
    # replayed here: under the keyed line, never ahead of it.
    [ -z "${3:-}" ] || printf '%s\n' "$3"
  } >&2 || :
  case "$1=$2" in settings=invalid-history-policy | report=plain-stage) return 0 ;; esac
  case "$1" in
    refused | path) exit 2 ;;
    *)
      echo "Check skipped. Repair the hook installation, tools or payload adapter; retry the command." >&2
      exit 0 ;;
  esac
}
# An exit that is neither a verdict (0) nor a refusal (2) is a check that did
# not complete, and it leaves with a warning. The EXIT trap is what reaches every
# such exit on Bash 3.2 too: an ERR trap inherited through `set -E` fires there
# inside a command substitution even when the substitution stands on the left
# of `||`, which reads the settings loader's guarded probes as failures.
# Support can explicitly exit with a guard's verdict status. While sourcing,
# that status is a support failure, not an executable-command refusal.
loading=""
# The plain-stage rule reports and does not refuse until a replay of the
# fleet's agent command logs shows which forms real work uses that it would
# refuse; then this reads enforce. transfer_reports holds its lines, which
# the EXIT trap writes only for a command the hook passes: a refused one
# already names what stopped it.
plain_rule=report
transfer_reports=()
trap '
  rc=$?
  if [ -n "$loading" ]; then
    cause=$loading
    while IFS= read -r detail <&5 || [ -n "$detail" ]; do
      cause="$cause
  $detail"
    done
    refuse support unreadable "$cause" 2>&3
  fi
  case $rc in
    0) [ "${#transfer_reports[@]}" -eq 0 ] || refuse report plain-stage ;;
    2) ;;
    *) refuse exit "$rc" ;;
  esac
' EXIT
MISSING=""
for dependency in jq git grep cat dirname mktemp rm; do
  command -v "$dependency" >/dev/null 2>&1 || MISSING="$MISSING,$dependency"
done
if ! command -v jq >/dev/null 2>&1 || ! command -v cat >/dev/null 2>&1; then
  refuse missing-tools "${MISSING#,}"
fi
input="$(cat 2>&1)" || refuse payload unreadable "$input"
fields="$(jq -er '
  def command_arg:
    if type == "object" then (.command // .cmd)
    elif type == "string" then
      (try fromjson catch null)
      | if type == "object" then (.command // .cmd) else null end
    else null end;
  . as $payload
  | [.tool_input.command, .tool_input.cmd, (.toolArgs | command_arg), .command, .cmd]
  | map(select(. != null))
  | if length == 0 then error("missing command") else .[0] end
  | . as $submitted
  | if type == "string" then .
    elif type == "array" and all(.[]; type == "string") then join(" ")
    else error("invalid command") end
  | sub("\n+$"; "") as $command
  | (if $payload.cwd != null and ($payload.cwd | type) != "string" then "invalid-cwd" else "valid-cwd" end) as $cwd_state
  | [(if $cwd_state == "invalid-cwd" then "" else ($payload.cwd // "" | sub("\n+$"; "")) end),
     $command, $cwd_state,
     (if ($submitted | type) == "array" then "argv" else "shell" end),
     (if ($submitted | type) == "array" then ($submitted | length), $submitted[] else 0 end)] | @tsv
' <<<"$input" 2>/dev/null)" || refuse payload invalid-json
[ -n "$fields" ] || exit 0
# TSV escapes tabs, newlines and backslashes, so only the field boundary is
# a literal tab. Read each field once instead of repeatedly copying and
# matching the remaining line. printf decodes data without shell evaluation.
# Bash 3.2 can unset the target of an empty %b assignment. Keep empty fields
# as ordinary assignments and decode only nonempty text.
{
  IFS= read -r -d $'\t' cwd || refuse payload invalid-json
  IFS= read -r -d $'\t' command_text || refuse payload invalid-json
  [ -n "$command_text" ] || exit 0
  [ -z "$cwd" ] || printf -v cwd '%b' "$cwd"
  printf -v command_text '%b' "$command_text"
  IFS= read -r -d $'\t' cwd_state || refuse payload invalid-json
  IFS= read -r -d $'\t' command_kind || refuse payload invalid-json
  IFS= read -r -d $'\t' argument_count || refuse payload invalid-json
  command_argv=()
  for ((argument_index=0; argument_index<argument_count; argument_index++)); do
    IFS= read -r -d $'\t' argument || refuse payload invalid-json
    [ -z "$argument" ] || printf -v argument '%b' "$argument"
    command_argv[argument_index]=$argument
  done
} <<<"$fields"$'\t'
# Set by the escape arms, which refuse what they cannot decode.
dump_reason=""
# The judged record's reason, which the history refusal names.
history_reason=""
history_reasons=(); history_states=(); history_dirs=(); history_ends=(); history_dir_changed=""
# The owner's exact-action exception is read from this hook's own process
# environment, which the harness passes from the environment its session
# started with. No settings file answers it, since a session can write one.
# owner_word refuses a command that names the variable, so a command cannot
# hand it to a session that command starts.
owner_command=""
if [ -n "${COMMAND_SAFETY_OWNER_COMMAND:-}" ] && [ "$COMMAND_SAFETY_OWNER_COMMAND" = "$command_text" ]; then owner_command=1; fi
download_form=""; download_program=""; download_receiver=""
upload_programs=(); upload_hosts=(); upload_assigned=(); upload_program=""; upload_host=""; upload_cause=""
push_remotes=(); push_reasons=(); push_states=(); push_bases=(); push_base_ends=(); push_dirs=(); push_dir_ends=(); push_dir_unknown=""
push_seen=""; push_config_changed=""; push_cd_searched=""; push_cdpath_named=""; push_alias_changed=""; push_git_heads=0
push_reason=""; push_remote=""; push_repository=""; push_cause=""
history_roots=(); history_root_reasons=(); outside=""
if environment_dump "$command_kind"; then
  refuse refused environment-dump
fi
# The first walk can reach a CDPATH word only after a searched cd, as in a
# sourced here-string or a loop that sets CDPATH after its cd, so a second
# walk, which knows the word from its start, judges that cd unresolved. Its
# subshell keeps the first walk's facts and diagnostics. The walk's verdict
# is its last line, since a walk that dies can exit with any status, 1
# included; that walk, and a refusal inside it, keep their captured words.
if [ -n "$push_cd_searched" ] && [ -n "$push_cdpath_named" ]; then
  walk_status=0
  walk_text=$( (
    verdict=0
    environment_dump "$command_kind" >/dev/null || verdict=$?
    printf '\nwalk=%s' "$verdict"
  ) 2>&1 ) || walk_status=$?
  walk_verdict=""
  case "$walk_status:$walk_text" in
    0:*$'\n'walk=[01]) walk_verdict=${walk_text##*=}; walk_text=${walk_text%$'\n'walk=?} ;;
  esac
  case "$walk_verdict:$walk_status:$walk_text" in
    0:*) refuse refused environment-dump ;;
    1:*) ;;
    :2:'command-safety: refused='*) printf '%s\n' "$walk_text" >&2; exit 2 ;;
    *) refuse exit "$walk_status" "$walk_text" ;;
  esac
fi
[ "$cwd_state" != invalid-cwd ] || refuse payload invalid-cwd
[ -z "$MISSING" ] || refuse missing-tools "${MISSING#,}"
[ -n "$cwd" ] || cwd="$PWD"
# The requested path is kept: the substitution below holds cd's own words when
# the directory cannot be entered, and the physical path when it can, so the
# refusal names the path it was asked for and replays the cause under it.
requested_cwd="$cwd"
cwd="$(cd -- "$cwd" 2>&1 && pwd -P)" || refuse cwd "$requested_cwd" "$cwd"
# A .git entry at or above DIR makes it a Git work tree, so a git failure
# there is git's to name, not a missing repository.
git_entry_above() { # DIR
  local at=$1
  while [ "$at" != / ]; do
    if [ -e "$at/.git" ] || [ -L "$at/.git" ]; then return 0; fi
    at="${at%/*}"
    [ -n "$at" ] || at=/
  done
  return 1
}
# Git keeps no record of a push destination beyond the remotes git remote -v
# lists: a push to a URL writes no ref and no log. A push is judged in every
# directory the reader directories say it can run in, before any settings.
push_judge() {
  local record base_start=0 dir_start=0 base cursor chain listing line name url rewritten known directory
  # A CDPATH the command sets moves a searched cd wherever it stands, since
  # the walk can reach the word only after the cd, as in a sourced
  # here-string, where the reader directories already hold the cd.
  [ -z "$push_cd_searched" ] || [ -z "$push_cdpath_named" ] || push_dir_unknown=1
  for ((record=0; record<${#push_remotes[@]}; record++)); do
    push_remote=${push_remotes[$record]}; push_reason=${push_reasons[$record]}
    if [ -z "$push_reason" ] && [ -n "$push_config_changed" ]; then push_reason=remote; push_cause=config; fi
    [ "${push_states[$record]}" = absolute ] || [ -z "$push_dir_unknown" ] || push_reason=${push_reason:-repository}
    [ -z "$push_reason" ] || refuse refused push-remote
    for ((base=base_start; base<${push_base_ends[$record]}; base++)); do
      chain=(-C "${push_bases[$base]}")
      for ((cursor=dir_start; cursor<${push_dir_ends[$record]}; cursor++)); do chain[${#chain[@]}]=-C; chain[${#chain[@]}]=${push_dirs[$cursor]}; done
      # Git's words are the cause: a repository whose configuration it
      # cannot read is not one the check failed to find.
      if ! listing=$(git "${chain[@]}" remote -v 2>&1); then
        push_reason=repository
        push_repository=$(cd -- "${push_bases[$base]}" 2>/dev/null && for directory in ${push_dirs[@]+"${push_dirs[@]:dir_start:push_dir_ends[record]-dir_start}"}; do cd -- "$directory" || exit; done && pwd -P) || push_repository=""
        if [ -n "$push_repository" ] && git_entry_above "$push_repository"; then push_reason=unreadable; fi
        refuse refused push-remote "$listing"
      fi
      push_repository=$(git "${chain[@]}" rev-parse --show-toplevel 2>/dev/null) || push_repository=${push_bases[$base]}
      rewritten=""
      case "$push_remote" in -*) ;; *) rewritten=$(git "${chain[@]}" ls-remote --get-url "$push_remote" 2>/dev/null) || rewritten="" ;; esac
      known=""
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        name=${line%%$'\t'*}; url=${line#*$'\t'}; url=${url% (*)}
        if [ "$push_remote" = "$name" ] || [ "$push_remote" = "$url" ] || [ "$rewritten" = "$url" ]; then known=1; break; fi
      done <<<"$listing"
      [ -n "$known" ] || refuse refused push-remote
    done
    base_start=${push_base_ends[$record]}; dir_start=${push_dir_ends[$record]}
  done
  # An alias the command's git config defines can make any other git word a
  # push, one with no record.
  [ -z "$push_alias_changed" ] || [ "$push_git_heads" -lt 2 ] || push_seen=1
  # A push with no repository has no record.
  if [ -n "$push_seen" ] && [ -n "$push_config_changed" ]; then
    push_remote=""; push_reason=remote; push_cause=config
    refuse refused push-remote
  fi
}
[ -n "$owner_command" ] || push_judge
# A consumer's list names each host an upload may reach, separated by
# whitespace and compared without case, as DNS compares names. An empty list
# refuses every upload.
upload_judge() { # LIST
  local record listed known hosts=()
  read -r -a hosts <<<"$1" || :
  for ((record=0; record<${#upload_programs[@]}; record++)); do
    upload_program=${upload_programs[$record]}; upload_host=${upload_hosts[$record]}
    upload_cause=${upload_assigned[$record]:+assignment}
    [ -n "$upload_host" ] || refuse refused upload-host
    known=""
    shopt -s nocasematch
    for listed in ${hosts[@]+"${hosts[@]}"}; do [[ $upload_host != "$listed" ]] || known=1; done
    shopt -u nocasematch
    [ -n "$known" ] || refuse refused upload-host
  done
}
# git's words come back in place of the path when it cannot answer, so the
# refusal below has the cause to replay: which .git entry it could not read.
root_status=0
root="$(git -C "$cwd" rev-parse --show-toplevel 2>&1)" || root_status=$?
if [ "$root_status" -ne 0 ]; then
  if git_entry_above "$cwd"; then refuse git unreadable "$root"; fi
  # Outside a worktree only a refused read's own -C chain names a project,
  # and Git resolves that chain from the payload directory. A chain the hook
  # cannot read whole, or a relative one in a command that changes directory,
  # names no project it can resolve and is not judged. The project pattern
  # stays inactive here.
  outside=1
  start=0
  for ((record=0; record<${#history_ends[@]}; record++)); do
    end=${history_ends[$record]}
    chain=(-C "$cwd")
    for ((j=start; j<end; j++)); do chain[${#chain[@]}]=-C; chain[${#chain[@]}]=${history_dirs[$j]}; done
    case "${history_states[$record]}:$history_dir_changed" in
      absolute:* | relative:)
        if [ "$end" -gt "$start" ] && target_root="$(git "${chain[@]}" rev-parse --show-toplevel 2>/dev/null)"; then
          history_roots[${#history_roots[@]}]=$target_root
          history_root_reasons[${#history_root_reasons[@]}]=${history_reasons[$record]}
        fi ;;
    esac
    start=$end
  done
  # No project file answers here; the process environment can still list hosts.
  [ -n "$owner_command" ] || upload_judge "${COMMAND_SAFETY_UPLOAD_HOSTS:-}"
  [ "${#history_roots[@]}" -gt 0 ] || exit 0
  # The hook enters the payload directory first and reads nothing there; it
  # reads each target's policy after entering that target's root.
  root=$cwd
fi

hook_dir="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)" || refuse hook unlocatable
# The support library is the hook's own install's, found from where the hook
# sits and never from a directory the payload names, so a command cannot
# choose the code this hook sources. The harness root holding hooks/, or
# kendex/hooks/ for Pi, may keep native skills/ beside it. A registered
# project layout names the install scope whose shared .agents/skills come
# next: <scope>/.claude, .codex, .github or .gemini /hooks, or
# <scope>/.pi/kendex/hooks. HOME's shared .agents/skills come last, which is
# where a global install keeps them: a harness root in no such form, such
# as ~/.copilot or ~/.pi/agent, and a registered one whose scope is HOME
# itself, such as ~/.claude/hooks. A harness home that CODEX_HOME,
# COPILOT_HOME or PI_CODING_AGENT_DIR moves is a global root even where its
# name is a project layout's, such as CODEX_HOME=/data/.codex, so a hook in
# that home's hooks directory reads no scope. Codex and the Pi carrier run
# the hook with the variable they found it by. Without it, such a hook looks
# like a project install, and a scope holding no loader still reaches HOME's.
scope=""
case "$hook_dir" in
  */.pi/kendex/hooks) scope=${hook_dir%/.pi/kendex/hooks} ;;
  */.claude/hooks | */.codex/hooks | */.github/hooks | */.gemini/hooks) scope=${hook_dir%/*/hooks} ;;
esac
[ "$scope" != "${HOME:-}" ] || scope=""
# Pi's own reading of its variable: trimmed, a leading ~ expanded against
# HOME, used only when absolute (pi_global_root, crates/core/src/harness/pi.rs).
pi_root=${PI_CODING_AGENT_DIR:-}
pi_root=${pi_root#"${pi_root%%[![:space:]]*}"}
pi_root=${pi_root%"${pi_root##*[![:space:]]}"}
case "$pi_root" in \~ | \~/*) pi_root=${HOME:+$HOME${pi_root#\~}} ;; esac
case "$pi_root" in /*) ;; *) pi_root="" ;; esac
hook_real="$(cd -P -- "$hook_dir" && pwd -P)" || refuse hook unlocatable
for configured in "${CODEX_HOME:+$CODEX_HOME/hooks}" "${COPILOT_HOME:+$COPILOT_HOME/hooks}" "${pi_root:+$pi_root/kendex/hooks}"; do
  if [ -n "$configured" ] && [ "$(cd -P -- "$configured" 2>/dev/null && pwd -P)" = "$hook_real" ]; then
    scope=""
    break
  fi
done
install_roots=("${hook_dir%/hooks}")
case "$hook_dir" in */kendex/hooks) install_roots[1]=${hook_dir%/kendex/hooks} ;; esac
[ -z "$scope" ] || install_roots[${#install_roots[@]}]="$scope/.agents"
lib=""
for at in "${install_roots[@]}"; do
  candidate="$at/skills/commit-guards/scripts/lib"
  if [ -f "$candidate/common.sh" ] && [ -f "$candidate/settings.sh" ]; then lib=$candidate; break; fi
done
if [ -z "$lib" ]; then
  lib="${HOME:+$HOME/.agents/skills/commit-guards/scripts/lib}"
fi
[ -f "$lib/common.sh" ] && [ -f "$lib/settings.sh" ] || refuse settings no-loader
GG_CHECK=command-safety
# Keep nested support reads under errexit. A source on the left of || would
# continue past a failed nested import. EXIT owns the advisory outcome, and
# its saved stderr survives the source command's diagnostic redirection.
exec 3>&2
# Capture installed support's stderr in an owned file. Open separate write and
# read descriptions before unlinking it; EXIT can read from the beginning even
# while source's stderr redirection remains active. Process exit owns teardown.
support_capture=$(mktemp 2>&1) || refuse support unreadable "$support_capture"
exec 4>"$support_capture" 5<"$support_capture"
capture_err=$(rm -- "$support_capture" 2>&1) || refuse support unreadable "$capture_err"
loading="$lib/common.sh"
# shellcheck source=../skills/commit-guards/scripts/lib/common.sh
source "$lib/common.sh" 2>&4
loading="$lib/settings.sh"
# shellcheck source=../skills/commit-guards/scripts/lib/settings.sh
source "$lib/settings.sh" 2>&4
loading=""
exec 3>&- 4>&- 5<&-
# cd runs twice on purpose: a substitution cannot move this shell, so the
# probe is what carries the cause into the refusal and the second one is the
# move. The second failure is unreachable in practice — the probe just
# succeeded — and refuses without a cause rather than not at all.
if ! ROOT_ERR=$( (cd -- "$root") 2>&1 ); then
  refuse cwd "$root" "$ROOT_ERR"
fi
cd -- "$root" || refuse cwd "$root"
# The loader's diagnostic is captured, not left to precede the refusal: on
# failure the substitution holds the loader's keyed line — for a value in
# another shape, the file, the line and the key — and a successful read is
# silent, so the pattern is not mixed with a diagnostic.
# A failed whole-table settings read warns; the shell call remains available
# so the operator can repair that file.
# The default is the host-safety rule every install gets: a systemd-run memory
# cap in K or M starved a build's cgroup into a kernel allocation failure that
# left a host's root volume read-only. skills/commit-guards'
# kendex.settings.toml.example declares the same value.
default_pattern='(^|[^[:alnum:]_-])systemd-run[[:space:]][^&;|]*Memory(Max|High)=[[:punct:]]?[0-9]+[KkMm]([^[:alnum:]]|$)'
history_judge() { # REASON: judged against the current directory's settings
  history_reason=$1
  if ! history_policy="$(gg_setting COMMAND_SAFETY_HISTORY_POLICY off 2>&1)"; then
    # A -C target's unreadable settings warn once every other target has
    # been judged, so a later refusal is not lost to this warning.
    [ -z "$outside" ] || { history_unread=$history_policy; return 0; }
    refuse settings unreadable "$history_policy"
  fi
  case "$history_policy" in
    off) ;;
    no-lazy-fetch) [ -z "$history_reason" ] || refuse refused history-policy ;;
    *)
      # An invalid selection leaves only this advisory check unavailable. The
      # independently readable project pattern must still get its decision.
      refuse settings invalid-history-policy ;;
  esac
}
if [ "${#history_roots[@]}" -gt 0 ]; then
  history_unread=""
  for ((target=0; target<${#history_roots[@]}; target++)); do
    cd -- "${history_roots[$target]}" || refuse cwd "${history_roots[$target]}"
    history_judge "${history_root_reasons[$target]}"
  done
  [ -z "$history_unread" ] || refuse settings unreadable "$history_unread"
  exit 0
fi
history_judge "${history_reasons[0]:-}"
if [ -z "$owner_command" ] && [ "${#upload_programs[@]}" -gt 0 ]; then
  upload_list="$(gg_setting COMMAND_SAFETY_UPLOAD_HOSTS "" 2>&1)" || refuse settings unreadable "$upload_list"
  upload_judge "$upload_list"
fi
pattern="$(gg_setting COMMAND_SAFETY_DENY_PATTERN "$default_pattern" 2>&1)" || refuse settings unreadable "$pattern"
[ -n "$pattern" ] || refuse settings empty
[ "$pattern" != '^$' ] || exit 0
status=0
# Shell line continuations can split a denied command or token. Keep the raw
# text too: single quotes preserve backslash-newline pairs as literal text.
# Bash 3.2 needs ANSI-C quoting expanded before the replacement pattern.
continuation=$'\\\n'
joined_command_text="${command_text//"$continuation"/}"
# grep's words on a pattern it cannot read are captured: stderr becomes the
# substitution's stdout and grep's own stdout is discarded, so the status still
# decides and the cause reaches the refusal below its keyed line.
GREP_ERR=$(printf '%s\n' "$command_text" "$joined_command_text" | LC_ALL=C grep -E -- "$pattern" 2>&1 >/dev/null) || status=$?
case "$status" in
  0)
    # The default's reason and remedy are known here; a project pattern's are
    # its own. A project that sets the default's own value refuses for the
    # default's reason, so it gets the default's text.
    if [ "$pattern" = "$default_pattern" ]; then
      refuse refused default-policy
    fi
    refuse refused policy
    ;;
  1) exit 0 ;;
  *) refuse settings invalid-pattern "$GREP_ERR" ;;
esac
