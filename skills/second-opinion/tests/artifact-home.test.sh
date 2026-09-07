#!/usr/bin/env bash
# The artifact home: where a stdout-mode run keeps its records. The default is
# tmp/second-opinion under --cwd; a relative setting must resolve to exactly
# <cwd>/<setting>, so a `..` component, a symlink anywhere along it (inside
# the repo or dangling outside) and the repo root itself are refused before
# anything is created, while the ordinary spellings of one directory all land
# in it and a --cwd reached through a symlink is accepted under its physical
# root. `~` and `~/…` expand against HOME (refused when it is unset, and ~user
# is refused); a rejected home falls back to system temp with the exit class
# kept. A home this run created is seeded with a `*` .gitignore so records
# never dirty the reviewed tree; a pre-existing home is the operator's and is
# never touched, a dangling .gitignore symlink there creates nothing. One
# table, a row per scenario; every row is a stdout-mode review whose CLI
# fails, so a record is written.
# shellcheck source=lib/stub-cli-world.bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/stub-cli-world.bash"

DEFAULTS="output:- rc:1 stdout:- stderr:quota"

FAILED="failed(exited with code 1|claude stderr|quota)"
# the record in the row's home, and in the temp fallback
IN_HOME="header:review failed:exit:home:1 cause:stderr preserved:home"
IN_TEMP="temp-fallback failed:exit:tmp:1 cause:stderr preserved:tmp"
HOME_OK="home=mode=700,review-claude-failed=$FAILED,ignore=*"

# label|world|argv|rc|out|err|calls files home tmp [probes] dirty
ROWS="
the default home is created owner-only under --cwd, seeded with a * .gitignore, and dirties nothing|-|review|5|-|$IN_HOME|calls=1 files=- $HOME_OK tmp=0 dirty=-
a symlink at the home pointing inside the repo is rejected and nothing lands under its target|prepare:link-inside home:tmp/second-opinion|review|5|-|header:review home-rejected:inside $IN_TEMP|calls=1 files=- home=link tmp=1 elsewhere=1 dirty=-
a relative path escaping --cwd is rejected lexically and nothing is created outside|home:../outside/second-opinion|review|5|-|header:review home-rejected:escape $IN_TEMP|calls=1 files=- home=absent tmp=1 dirty=-
a symlinked parent pointing at a not-yet-existing outside path is rejected before mkdir could create it|prepare:link-parent home:tmp/link-parent/second-opinion|review|5|-|header:review home-rejected:parent $IN_TEMP|calls=1 files=- home=absent tmp=1 dirty=-
control: a --cwd reached through a symlink resolves the home under the physical root and is accepted|cwd:link|review|5|-|$IN_HOME|calls=1 files=- $HOME_OK tmp=0 dirty=-
a trailing slash still names the home|home:tmp/second-opinion/|review|5|-|$IN_HOME|calls=1 files=- $HOME_OK tmp=0 dirty=-
a leading ./ still names the home|home:./tmp/second-opinion|review|5|-|$IN_HOME|calls=1 files=- $HOME_OK tmp=0 dirty=-
a leading .// still names the home|home:.//tmp/second-opinion|review|5|-|$IN_HOME|calls=1 files=- $HOME_OK tmp=0 dirty=-
an inner /./ still names the home|home:tmp/./second-opinion|review|5|-|$IN_HOME|calls=1 files=- $HOME_OK tmp=0 dirty=-
a trailing /. still names the home|home:tmp/second-opinion/.|review|5|-|$IN_HOME|calls=1 files=- $HOME_OK tmp=0 dirty=-
the repo root spelled . is refused as the root, not as an escape|home:.|review|5|-|header:review home-rejected:root:. $IN_TEMP|calls=1 files=- home=root tmp=1 dirty=-
the repo root spelled ./ likewise|home:./|review|5|-|header:review home-rejected:root:./ $IN_TEMP|calls=1 files=- home=root tmp=1 dirty=-
~/… expands against HOME, leaves no literal ~ in the checkout, and gets no .gitignore|home:~/so-records HOME:fake|review|5|-|$IN_HOME|calls=1 files=- home=mode=700,review-claude-failed=$FAILED tmp=0 dirty=-
a bare ~ expands to HOME and never seeds HOME/.gitignore|home:~ HOME:fake|review|5|-|$IN_HOME|calls=1 files=- home=mode=755,review-claude-failed=$FAILED tmp=0 dirty=-
~user is refused, not taken literally|home:~someuser/records|review|5|-|header:review home-rejected:user $IN_TEMP|calls=1 files=- home=absent tmp=1 dirty=-
a bare ~ with HOME unset says so and falls back|home:~ HOME:-|review|5|-|header:review home-rejected:nohome $IN_TEMP|calls=1 files=- home=mode=755 tmp=1 dirty=-
~/… with HOME unset likewise|home:~/so-records HOME:-|review|5|-|header:review home-rejected:nohome:~/so-records $IN_TEMP|calls=1 files=- home=absent tmp=1 dirty=-
a pre-existing home is the operator's: a tracked, curated .gitignore is left as it is, so the record shows as untracked|prepare:curated home:pre-existing|review|5|-|$IN_HOME|calls=1 files=- home=mode=755,review-claude-failed=$FAILED,ignore=build/ tmp=0 dirty=?? pre-existing/review-claude-failed
a pre-existing home with no .gitignore is not given one|prepare:plain home:pre-existing|review|5|-|$IN_HOME|calls=1 files=- home=mode=755,review-claude-failed=$FAILED tmp=0 dirty=?? pre-existing/review-claude-failed
a dangling .gitignore symlink in a pre-existing home creates nothing at its target and is left alone|prepare:dangling-ignore home:pre-existing|review|5|-|$IN_HOME|calls=1 files=- home=mode=755,review-claude-failed=$FAILED,ignore=link tmp=0 dirty=?? pre-existing/review-claude-failed
"

run_table "the artifact home" "$DEFAULTS" "$ROWS"
finish
