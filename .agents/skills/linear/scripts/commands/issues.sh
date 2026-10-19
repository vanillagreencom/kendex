#!/bin/bash
# Linear GraphQL API - Issue Operations
# Usage: issues.sh <action> [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Help is answered before the libraries load: common.sh sources the repo's
# .env.local as shell code and resolves API auth, and help needs neither.
show_help() {
    cat <<'EOF'
Issue Operations

Usage: issues.sh <action> [options]

Actions:
  list           List issues with filters
  get            Get a single issue by ID (--with-bundle for recursive children + pending_count)
  bulk-get       Get several issues with full relations, by identifier or UUID
  bulk-update    Update multiple issues with the same changes
  create         Create a new issue
  update         Update an existing issue
  archive        Archive an issue (soft delete, restorable via UI)
  trash          Move issue to trash (recoverable for 30 days)
  delete         Alias for trash
  children       List sub-issues of a parent issue (--recursive for nested, --pending to filter)
  list-relations List issue relations (blocking/blocked-by)
  add-relation   Create a relation between issues
  remove-relation Delete an issue relation

Workflow Actions (composite operations for dev):
  activate       Claim issue: set "In Progress" (--agent applies agent:<name> label).
                 With KENDEX_USER_EMAIL set, an issue nobody is assigned is
                 assigned to that person in the same mutation. One keyed
                 stderr line and the JSON "assignee" field say what happened:
                 assignee-set assignee=<name> (set), assignee-kept
                 assignee=<name> (kept; an existing assignee is never
                 replaced), assignee-skipped cause=unset or
                 assignee-skipped cause=unknown-email email=<email> (skipped)
  block          Block issue: add label + relation + comment
  unblock        Unblock issue: remove label + comment
  complete       Complete issue: optional summary, then Done or post-merge Verifying
                 (--done-when-met ticks the met "## Done when" boxes in that
                 same update)
  validate-completion  Pre-merge check: state + summary comment
                 (--include-children-of <ID> for bundles; --container when the
                 target is a container parent closing after its children)

Cross-team guard: with LINEAR_TEAM set, update, bulk-update, activate, block,
unblock, complete, archive and trash|delete refuse an issue of another team
before any write, with
`linear: refused=cross-team action=<verb> issue=<ID> team=<KEY>
own-team=<KEY> route=peer-mail`. Reads and relations, like comments, reach
every team. With LINEAR_TEAM unset they run and print
`linear: cross-team-guard=inactive action=<verb> cause=no-team`.

Output Formats (all query commands):
  --format=safe         Flat, null-safe array (DEFAULT)
  --format=compact      Minimal fields for workflow routing (no description/url/timestamps)
  --format=ids          Newline-separated identifiers only
  --format=table        Human-readable table
  --format=raw          Original GraphQL structure

List Options:
  --label <name>        Filter by label (e.g., "backend"); repeat to require
                        every named label
  --labels <a,b,c>      Comma-separated labels, every one required (ANDs with
                        --label)
  --state <name>        Filter by state (e.g., "Todo", "In Progress,Todo")
  --project <name>      Filter by project name
  --project-id <uuid>   Filter by project ID
  --team <ref>          Filter by team key or name (no default; omit = all teams)
  --assignee <name|me|email>  Filter by assignee; addresses match exactly, ignoring case
  --updated-since <Nd>  Filter by updated date (e.g., "7d")
  --created-since <Nd|UTC>  Filter by created date; UTC is YYYY-MM-DDTHH:MM:SSZ
  --select <name>      full (default), triage (identity and creation), or owed
                        (priority, state, verification and container facts).
                        triage and owed use safe output and pages of 250.
  --limit <n>           Max results (default: 75); a larger value spans pages,
                        and a read that leaves rows unread says so on stderr
  --max                 Fetch every page; a chain left open at the page cap
                        or failed partway refuses with no output
  --search <terms>      Filter by title/description substring, server-side and
                        case-insensitive; pipe-separated terms are OR'd.
  --all-projects        Every project in one read (no project filter; each
                        row carries its project name). Not with --project
  --no-project          Only issues with no project. Not with --project or
                        --all-projects
  --include-archived    Include archived issues
  --with-relations      Include blocking info (use --format=raw for analyzed output)

Get:
  issues.sh get <id>    Get by UUID or identifier (PROJ-42)

Bulk Get:
  issues.sh bulk-get <id1> <id2> ...   Get multiple issues with relations
  issues.sh bulk-get --stdin           Read identifiers from stdin (one per line)
  --format <fmt>                      safe (default) | compact | ids | raw

Bulk Update:
  issues.sh bulk-update <id1> <id2> ... [update-options]
  issues.sh bulk-update --stdin [update-options]
  (Same update options as 'update' action, applied to all issues)

Create Options:
  --title <text>        Issue title (required)
  --team <ref>          Team key or name (default: $LINEAR_TEAM; required when unset);
                        another team than $LINEAR_TEAM is refused
  --description <text>  Issue description
  --description-file <path>  Read description from file (preferred for markdown)
  --label(s) <a,b,c>    Comma-separated label names
  --project <name|uuid> Project (name or UUID, auto-resolved)
  --state <name>        Initial state (case-sensitive, fails with available list)
  --priority <0-4>      Priority: 0=None, 1=Urgent, 2=High, 3=Normal, 4=Low
  --estimate <1-5>      Effort estimate (points)
  --assignee <name|me|email|id>  Assignee: a name matches as a substring, an
                        address (anything with @) matches a user's whole
                        email, case-insensitively, and a user id is used as
                        given; a miss refuses
  --parent <id>         Parent issue ID (creates sub-issue)
  --milestone <name|uuid> Project milestone (a name needs --project; a UUID does not)
  --cycle <id>          Cycle (sprint) ID
  --attach <path>       Upload a file to Linear and attach it (repeatable).
                        Images (png/jpg/jpeg/gif/webp/svg) embed into the
                        description as ![name](assetUrl); other files become
                        Linear attachments (attachmentCreate) on the created
                        issue. Composes with --description/--description-file.
                        Missing/unreadable paths refuse before any API call;
                        an attachment failure after the create reports the
                        created identifier and exits non-zero. The JSON
                        response carries attachments_requested whenever
                        records were requested; attachments lists them as
                        {url, repo_path} only when every attachmentCreate
                        succeeded, and stays empty on a partial failure.
  --format=ids          Print ONLY the created issue identifier (for capture;
                        default output is the full JSON create response)
  --no-agent-label      Permit a deliberate bare create (e.g. intake
                        mirroring) in a project that declares its agent-label
                        taxonomy. When LINEAR_AGENT_LABELS is set in
                        kendex.settings.toml [env], create refuses without an
                        agent:* label from that set: an unlabeled issue is
                        invisible to agent routing. Route normal issue
                        creation through the TPM pipeline (project-management
                        skill), which owns labels, project, priority, and
                        relations — do not create tracked issues directly.

  --review-born         This create came from a review finding, which is what
                        subjects it to the `Symptom:` half of the bar below.

  Reach guard: unless LINEAR_REQUIRE_REACH is set empty in kendex.settings.toml
  [env], create refuses a description with no `Reached by:` line, and a
  `--review-born --priority 2` one with no `Symptom:`; a placeholder or null
  token (TBD, n/a, none, -) counts as no line. Rule: project-management SKILL.md, § Disposition.
  Under the same key, create, update --description/--description-file,
  and bulk-update --description
  refuse a body whose first non-empty line, after an optional owner action
  line (`**Name, what you do:** ...`), is a header (a line-start `**Key**:` or
  `Reached by:`), and one with a header line over 500 characters; each
  refusal names the line number and its length. Update judges the body after
  it reads the issue: a body equal to the stored one apart from a leading
  owner action line, which it places, replaces or removes, is judged on that
  line's length alone, so an owner ask writes over a body filed header-first.

  Label taxonomy: where the repository declares one (project-management
  references/labels.md, plus LINEAR_AGENT_LABELS), create, update --labels,
  bulk-update --labels, activate and block refuse a label it does not declare,
  naming the label and the taxonomy file. The taxonomy check does not refuse
  an undeclared label the issue already carries. Create also refuses a
  declared label Linear does not have, where with no taxonomy it skips that
  label with a warning.

  Project map: where the repository declares one (project-management
  references/project-map.md), create refuses with no --project, and create,
  update --project and bulk-update --project refuse, before any write, a
  project the map does not list and a map project with no single live Linear
  project in the team.

Update Options:
  --state <name>        New state. Update and bulk-update refuse completed-type
                        states with open Done-when boxes or checked boxes that
                        lack a nonblank Evidence: line indented directly below.
                        Refusals list the boxes with fix=issues complete.
  --label(s) <a,b,c>    Replace the whole label set (comma-separated).
                        Read current labels, apply the intended change, then
                        pass the full final set.
  --title <text>        New title
  --description <text>  New description (empty text clears it)
  --description-file <path>  Read new description from file (preferred for markdown)
  --project <name|uuid> Move to project (name or UUID, auto-resolved)
  --priority <0-4>      Priority: 0=None, 1=Urgent, 2=High, 3=Normal, 4=Low
  --estimate <0-5>      Effort estimate (points); 0 clears the estimate (unset)
  --clear-estimate      Clear the estimate (unset; e.g. coordination parents = no estimate)
  --assignee <name|me|email|id>  Change assignee (matched as on create)
  --clear-assignee     Remove the assignee
  --parent <id>         Set parent issue (convert to sub-issue)
  --remove-parent       Remove parent (convert to top-level issue)
  --milestone <name|uuid> Set project milestone (a name resolves in --project,
                        else the issue's own project)
  --cycle <id>          Set cycle (sprint) ID
  --clear-cycle         Remove cycle assignment
  --attach <path>       Upload a file to Linear and attach it (repeatable).
                        Images embed as ![name](assetUrl) appended to the
                        description being written (with no --description on
                        this update, appended to the existing description);
                        other files become Linear attachments. --attach alone
                        is a valid update. Partial failures after the update
                        report the identifier and exit non-zero. An
                        attach-only update answers with the same
                        attachments_requested and attachments fields as
                        issues create.
  --sort-order <float>  Manual sort position (lower = higher; parent/standalone only)
  --format <fmt>        Output format for the updated issue: safe | compact | ids |
                        raw. When omitted, emits the mutation summary
                        ({success, identifier, url, data}) as before. An
                        attach-only update runs no issueUpdate and ignores
                        this flag: it answers with its own object, which has
                        the attachment fields and no data key.

Relation Options (add-relation):
  --blocks <id>         This issue blocks another
  --blocked-by <id>     This issue is blocked by another
  --related <id>        Mark as related
  --duplicate <id>      Mark as duplicate
  --peer-rule-violation remove-relation: the tpm-audit structural repair

Activate Options:
  --format <fmt>       Output format: ids (identifier only); default is JSON.
  --agent <name>        Apply the exclusive agent:<name> issue label together
                        with the "In Progress" transition (replaces any existing
                        agent:* label, preserves other labels). Fails without
                        changing state when the label does not exist.

Complete Options:
  On Done, exact at-completion entries under **Supersedes**: are commented
  and canceled. Malformed entries are reported and skipped; related links
  and Related prose grant no cancellation authority.
  Pending children require disposition before cancellation. Failed required
  effects exit nonzero even after Done, preserving the transition result and
  structured supersession-incomplete retry options without summary flags.
  --format <fmt>        Output format: ids (identifier only); default is JSON.
  --summary <text>       Post a summary comment, then apply the checklist state
  --summary-file <path>  Read the summary from a file (preferred for markdown)
  --post-merge-at <UTC>  Use the merged PR's mergedAt (YYYY-MM-DDTHH:MM:SSZ).
                        Refuse open branch-provable boxes. Set Verifying after
                        merge when a post-merge box remains open, otherwise Done.
                        Without this option, open post-merge boxes keep the
                        current started state; any other current state refuses.
                        Each Post-merge box names reading, Where, Why after
                        merge, Trigger and Deadline on one line. A missing
                        Trigger means merge. Trigger accepts merge, a UTC time
                        at or after merge, or release OWNER/REPO TAG-GLOB.
                        Deadline is +Nh, N from 1 through 72, counted from
                        the trigger: mergedAt, the stated time, or the first
                        matching publication after merge. In a repository
                        where the item merged, that release must contain its
                        latest merge commit. A merge or time trigger also
                        takes a UTC deadline at most 72 hours after it.
                        Every completion reads the checklist, with or without
                        this option. Open branch boxes refuse. Post-merge boxes
                        follow the phase above. Ticked boxes require a
                        nonblank Evidence: line indented directly below them.
  --done-when-met <all|N[,N...]>
                         Tick the "## Done when" checklist boxes the caller
                         verified as met, in the same issueUpdate that sets
                         the completion state. Boxes are numbered from 1 in the order the
                         section lists them, checked ones included; "all"
                         ticks every box. A box not named stays unchecked. A
                         number past the section's last box refuses before
                         any write. The section runs from its "## Done when"
                         line to the next "## " heading. The result's
                         "done_when_checked" counts the boxes this call ticked.
  --evidence-file <path>  Evidence for --done-when-met, one N: text line per box.
                         Writes each Evidence: line with the tick and state.
                         Also repairs evidence on selected already-ticked boxes.
  The comment is posted BEFORE the state transition; if posting fails the issue
  state is unchanged. Text lacking a "Completion Summary"/"Bundle Complete"
  marker is prefixed with a "## Completion Summary" heading so
  validate-completion detects it.

Validate-Completion:
  Pre-merge validation. Session-root issues (positional targets) are expected
  in "In Progress" or "In Review" — "Done" fails state_ok because managed
  session roots stay pre-merge until PR merge. This pre-merge state rule applies
  ONLY to the session root, not to expanded bundle children.
  Bundle children expanded via --include-children-of pass in Done, or a started
  state other than Verifying
  when the shared checklist parser proves every branch box and every checked
  box has evidence. A started child needs a checklist; post-merge boxes are
  optional. Open branch work or invalid post-merge metadata fails state_ok.
  Canceled children are excluded from the expansion:
  abandoned work can never be "Done" and is not a pending gap. Each validated
  issue must also have a comment containing "Completion Summary" or
  "Bundle Complete", without regard to letter case.
  --container marks the positional target as a CONTAINER parent — a parent
  whose children are each worked as their own PR unit, with the container
  closing when its last child is Done or Canceled. The container's state passes for any live state (canceled
  fails closed) and needs no pre-posted summary: `issues complete --summary`
  posts it at completion time. Its expanded children must each be Done with
  a summary; a Done child without one carries a `remedy`. all_ok answers
  "every row validated"; whether the container may close is container-close's
  decision. The container's row reports the facts that decision reads:
  `child_box`, the number of its "Every child Done or cancelled" box or null,
  which the closer ticks; `container_open_boxes`, every other box still open
  or missing its Evidence line, with a `remedy` to move each into its own
  child; `errors`; and `has_summary`. They do not gate its `ok`.
  No merge time is needed.
  The flag fails closed:
  it requires exactly one issue ID plus --include-children-of naming that
  same issue, and errors (exit 1) when the bundle has no children — a leaf
  cannot validate as a container. With every child canceled the result
  carries the container's row alone. A child of a container
  validates alone as its own session root. Use it only for containers;
  the review audit's in-PR bundle uses the default bundle-child contract above,
  and --container refuses its root, whose safe read reports `in_pr_bundle`
  true. A container with no Done-when checklist can complete.

Examples:
  # Basic operations
  issues.sh list --label "backend" --state "Todo"
  issues.sh get PROJ-42
  issues.sh create --title "New task" --labels "backend,priority:high" --description-file body.md
  issues.sh create --title "Bundle" --project "Phase 2" --description-file body.md --format=ids  # identifier only
  issues.sh update PROJ-42 --state "In Progress"
  issues.sh archive PROJ-42

  # Parent/sub-issues
  issues.sh create --title "Sub-task" --parent PROJ-42 --description-file body.md
  issues.sh children PROJ-42                    # Direct children only
  issues.sh children PROJ-42 --recursive        # All descendants (3 levels deep)
  issues.sh children PROJ-42 --recursive --pending  # Pending only: drops completed/canceled rows, keeps an open grandchild of a closed child
  issues.sh update PROJ-43 --parent PROJ-42
  issues.sh update PROJ-43 --remove-parent

  # Issue relations
  issues.sh list-relations PROJ-42
  issues.sh add-relation PROJ-42 --blocks PROJ-43
  issues.sh add-relation PROJ-42 --blocked-by PROJ-41
  issues.sh remove-relation PROJ-42 --blocks PROJ-43      # By issue + flag (mirrors add-relation)
  issues.sh remove-relation <relation-uuid>             # By UUID

  # Cycle (sprint) assignment
  issues.sh update PROJ-42 --cycle 864d7ea0-2347-4048-80cd-5be977d904e4
  issues.sh update PROJ-42 --clear-cycle

  # Estimate (1-5 real points; clear for coordination-only parents)
  issues.sh update PROJ-42 --estimate 3
  issues.sh update PROJ-42 --clear-estimate      # Unset estimate (coordination parent)
  issues.sh update PROJ-42 --estimate 0          # Alias for --clear-estimate

  # Bulk operations (reduces API calls)
  issues.sh list --project-id <uuid> --with-relations   # Single query with all relations
  issues.sh bulk-get PROJ-184 PROJ-185 PROJ-186 PROJ-187    # Multiple issues with full details

  # Workflow actions (dev shortcuts)
  issues.sh activate PROJ-42 --agent rust        # In Progress + agent:rust label
  issues.sh block PROJ-42 --by PROJ-41 --reason "Need market data types first"
  issues.sh unblock PROJ-42                      # Resume after blocker resolved
  issues.sh complete PROJ-42                     # Mark done
  issues.sh complete PROJ-42 --summary-file tmp/completion-summary-PROJ-42.md  # Summary comment, then done
  issues.sh complete PROJ-42 --done-when-met all --evidence-file proof.txt
  issues.sh complete PROJ-42 --done-when-met 1,3 --evidence-file proof.txt
  issues.sh validate-completion PROJ-42 --include-children-of PROJ-42  # In-PR bundle validation
  issues.sh validate-completion PROJ-42 --include-children-of PROJ-42 --container  # May the container close?

  # Bundle operations (single API call)
  issues.sh get PROJ-42 --with-bundle            # Issue + recursive children + pending_count

  # Search/filter
  issues.sh list --state Todo --search "market_data|order_book"  # Title/description contains either term (server-side)
EOF
}

case "${1:-help}" in
    help|--help|-h) show_help; exit 0 ;;
esac

# The help scan covers every argv position — enumerating positions is how
# this class leaks — but skips the value an option consumes, so a --title
# or --summary of '--help' stays data.
_help_takes_value() {
    case "$1" in
        --agent | --assignee | --attach | --blocked-by | --blocks | --by | \
            --cycle | --description | --description-file | --duplicate | \
            --estimate | --format | --include-children-of | --label | \
            --labels | --limit | --milestone | --parent | --priority | \
            --project | --reason | --related | --search | --sort-order | \
            --state | --status | --summary | --summary-file | --team | \
            --title) return 0 ;;
        *) return 1 ;;
    esac
}
_want_help=""
_skip_value=""
for _arg in "$@"; do
    if [ -n "$_skip_value" ]; then
        _skip_value=""
        continue
    fi
    case "$_arg" in
        --help | -h) _want_help=1; break ;;
        --*) if _help_takes_value "$_arg"; then _skip_value=1; fi ;;
    esac
done
if [ -n "$_want_help" ]; then
    show_help
    exit 0
fi
unset _want_help _skip_value _arg

source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/attachments.sh"
source "$SCRIPT_DIR/../lib/issue-validation.sh"

# Shared issue fields for mutation responses, the list query's fields
ISSUE_RETURN_FIELDS='
    id
    identifier
    title
    description
    state { name type }
    assignee { name }
    project { id name }
    projectMilestone { id name }
    cycle { id name number }
    parent { id identifier title }
    team { name }
    labels { pageInfo { hasNextPage endCursor } nodes { name } }
    priority
    estimate
    sortOrder
    url
    createdAt
    updatedAt
    archivedAt
    trashed
'"$ISSUE_RELATION_FIELDS"

read_description_file() {
    local description_file="$1"
    if [[ -z "$description_file" ]]; then
        echo '{"error": "--description-file requires a non-empty path argument"}' >&2
        return 1
    fi
    if [[ ! -r "$description_file" ]]; then
        echo "{\"error\": \"--description-file path not readable: $description_file\"}" >&2
        return 1
    fi
    description=$(<"$description_file")
}

list_issues() {
    local with_relations="false"
    local selection=full page=75 fields
    linear_list_reset
    local search_pattern=""
    local search_given="false"
    local args=()
    FORMAT="${DEFAULT_FORMAT}"

    while [ $# -gt 0 ]; do
        case "$1" in
        --with-relations)
            with_relations="true"
            ;;
        --select)
            linear_require_option_value "$@" || return 1
            selection="$2"
            shift
            ;;
        --max)
            linear_list_option --max
            ;;
        --format)
            # A following option token is a missing value, not a format:
            # otherwise `--format --search x` eats --search as the format
            # and silently drops the filter.
            if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
                echo '{"error": "--format requires a value"}' >&2
                return 1
            fi
            FORMAT="$2"
            shift
            ;;
        --format=*)
            FORMAT="${1#--format=}"
            ;;
        --search)
            # A following option token is a missing value, not a term:
            # `--search --state Todo` must refuse, not search for
            # "--state" and drop the state filter. An intentional
            # option-like term can still use --search='--like-this'.
            if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
                echo '{"error": "--search requires a value"}' >&2
                return 1
            fi
            search_given="true"
            search_pattern="$2"
            shift
            ;;
        --search=*)
            search_given="true"
            search_pattern="${1#--search=}"
            ;;
        *)
            args+=("$1")
            ;;
        esac
        shift
    done

    # A given-but-empty pattern must refuse, not degrade to an unfiltered
    # list: the dedupe preflight reads "rows came back" as "search ran".
    # Emptiness is judged by the SAME jq normalization that builds the
    # filter below — tr sees bytes, so a multibyte Unicode space (U+00A0)
    # would pass a tr check and then normalize into an empty or-clause.
    if [ "$search_given" = "true" ]; then
        term_count=$(jq -rn --arg pattern "$search_pattern" '
            $pattern | split("|")
                | map(gsub("^[[:space:]]+|[[:space:]]+$"; ""))
                | map(select(length > 0)) | length')
        if [ "$term_count" = "0" ]; then
            echo '{"error": "--search requires a non-empty value"}' >&2
            return 1
        fi
    fi

    parse_filter ${args[@]+"${args[@]}"} || return 1
    linear_require_format "$selection" full triage owed || return 1
    [[ "$selection" == full ]] || linear_require_format "$FORMAT" safe || return 1
    case "$selection" in
    triage) fields='identifier createdAt'; page=250 ;;
    owed)
        fields='id identifier title description priority state { name type } parent { identifier } createdAt
'"$ISSUE_BLOCKED_BY_FIELDS"
        page=250
        ;;
    full) fields="${ISSUE_RETURN_FIELDS/    team \{ name \}/}" ;;
    esac

    # Server-side search: pipe-separated terms, each matched as a
    # case-insensitive substring of title or description via Linear's
    # IssueFilter. Top-level filter fields AND with the or-clause, so
    # --state/--project/... still narrow the result.
    if [ -n "$search_pattern" ]; then
        # Terms are trimmed so "a | b" matches "a"/"b", not " b" — and
        # whitespace-only fragments are dropped, never matched broadly.
        FILTER_JSON=$(jq -cn --arg pattern "$search_pattern" --argjson base "$FILTER_JSON" '
            ($pattern | split("|")
                | map(gsub("^[[:space:]]+|[[:space:]]+$"; ""))
                | map(select(length > 0))) as $terms |
            $base + {or: [$terms[] |
                {title: {containsIgnoreCase: .}},
                {description: {containsIgnoreCase: .}}]}')
    fi

    local query
    query='
    query ListIssues($filter: IssueFilter, $first: Int, $includeArchived: Boolean, $after: String) {
        issues(filter: $filter, first: $first, includeArchived: $includeArchived, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes {
'"$fields"'
            }
        }
    }'

    local result variables
    variables="{\"filter\": $FILTER_JSON, \"includeArchived\": $INCLUDE_ARCHIVED_JSON}"
    result=$(linear_list_read "$query" "$variables" issues "$page") || return 1

    if [[ "$selection" == triage ]]; then
        jq '[.issues.nodes[] | {id: .identifier, created_at: .createdAt}]' <<<"$result"
        return
    elif [[ "$selection" == owed ]]; then
        jq "$ISSUE_RELATION_JQ"'[.issues.nodes[] | {id: .identifier, title, description,
          in_pr_bundle: issue_in_pr_bundle(.description), priority, state: .state.name, state_type: .state.type, parent_id: (.parent.identifier // ""),
          created_at: .createdAt, blocked_by_open: issue_blocked_by_open_ids(.inverseRelations.nodes)}]' <<<"$result"
        return
    fi

    # Apply output format
    case "$FORMAT" in
    compact)
        format_issues_list_compact "$result"
        ;;
    raw)
        # --with-relations with raw outputs analyzed format (legacy behavior)
        if [ "$with_relations" = "true" ]; then
            echo "$result" | jq "$ISSUE_RELATION_JQ"'{
                    unblocked: [.issues.nodes[] |
                        select(issue_blocked_by_open_relations(.inverseRelations.nodes) | length == 0) |
                        {id: .identifier, title, agent: ([.labels.nodes[].name | select(startswith("agent:"))] | first // "none"), priority}
                    ],
                    blocked: [.issues.nodes[] |
                        select(issue_blocked_by_open_relations(.inverseRelations.nodes) | length > 0) |
                        {id: .identifier, title, agent: ([.labels.nodes[].name | select(startswith("agent:"))] | first // "none"), priority,
                         blocked_by: issue_blocked_by_open_ids(.inverseRelations.nodes)}
                    ]
                }'
        else
            linear_public_result "$result"
        fi
        ;;
    ids)
        format_issues_ids "$result"
        ;;
    table)
        format_issues_table "$result"
        ;;
    safe | *)
        format_issues_list "$result"
        ;;
    esac
}

bulk_get_issues() {
    local identifiers=()
    local from_stdin="false"
    FORMAT="${DEFAULT_FORMAT}"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --stdin)
            from_stdin="true"
            shift
            ;;
        --format)
            FORMAT="$2"
            shift 2
            ;;
        --format=*)
            FORMAT="${1#--format=}"
            shift
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2
            return 1
            ;;
        *)
            identifiers+=("$1")
            shift
            ;;
        esac
    done

    # Read from stdin if requested
    if [ "$from_stdin" = "true" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            [ -n "$line" ] && identifiers+=("$line")
        done
    fi

    linear_require_format "$FORMAT" safe compact ids raw || return 1

    local refs
    refs=$(linear_issue_refs refs ${identifiers[@]+"${identifiers[@]}"}) || return 1

    local fields='
                id
                identifier
                title
                description
                state { name type }
                assignee { name email }
                project { id name }
                projectMilestone { id name }
                cycle { id name number }
                team { name }
                labels { pageInfo { hasNextPage endCursor } nodes { name } }
                priority
                estimate
                sortOrder
                url
                createdAt
                updatedAt
                archivedAt
                trashed
                parent { id identifier title }
                children { pageInfo { hasNextPage endCursor } nodes { id identifier title state { name type } } }
'"$ISSUE_RELATION_FIELDS"

    local result
    result=$(linear_issue_refs_read "$fields" "$refs") || return 1
    result=$(jq -c '{issues: {nodes: .nodes}}' <<<"$result") || return 1

    # Apply output format
    case "$FORMAT" in
    compact)
        format_issues_list_compact "$result"
        ;;
    raw)
        linear_public_result "$result"
        ;;
    ids)
        format_issues_ids "$result"
        ;;
    safe | *)
        format_issues_list "$result"
        ;;
    esac
}

bulk_update_issues() {
    local identifiers=()
    local from_stdin="false"
    local update_args=()
    local attach_paths=()
    local description="" description_set="false" state="" project=""

    # Separate issue IDs from update options
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --stdin)
            from_stdin="true"
            shift
            ;;
        --state | --status | --labels | --label | --title | --description | --project | --parent | --milestone | --priority | --estimate | --assignee | --cycle | --sort-order | --attach)
            # These are update options - collect with their values
            # (--attach re-uploads per issue: Linear assets are issue-agnostic
            # but each issue gets its own embed/attachment)
            [[ "$1" != --project ]] || project="$2"
            update_args+=("$1" "$2")
            [[ "$1" != --state && "$1" != --status ]] || state="$2"
            [[ "$1" != --attach ]] || attach_paths+=("$2")
            if [[ "$1" == --description ]]; then
                description="$2"
                description_set="true"
            fi
            shift 2
            ;;
        --state=* | --status=* | --labels=* | --label=* | --title=* | --description=* | --project=* | --parent=* | --milestone=* | --priority=* | --estimate=* | --assignee=* | --cycle=* | --sort-order=* | --attach=*)
            # Support --key=value syntax (AI agents often use this)
            local _key="${1%%=*}" _val="${1#*=}"
            [[ "$_key" != --project ]] || project="$_val"
            update_args+=("$_key" "$_val")
            [[ "$_key" != --state && "$_key" != --status ]] || state="$_val"
            [[ "$_key" != --attach ]] || attach_paths+=("$_val")
            if [[ "$_key" == --description ]]; then
                description="$_val"
                description_set="true"
            fi
            shift
            ;;
        --remove-parent | --clear-cycle | --clear-estimate)
            update_args+=("$1")
            shift
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2
            return 1
            ;;
        *)
            identifiers+=("$1")
            shift
            ;;
        esac
    done

    # Read from stdin if requested
    if [ "$from_stdin" = "true" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            [ -n "$line" ] && identifiers+=("$line")
        done
    fi

    if [ ${#identifiers[@]} -eq 0 ]; then
        echo '{"error": "No issue identifiers provided"}' >&2
        return 1
    fi

    if [ ${#update_args[@]} -eq 0 ]; then
        echo '{"error": "No update options provided. Example: bulk-update PROJ-1 PROJ-2 --state \"Backlog\""}' >&2
        return 1
    fi
    # --attach: refuse unreadable paths before any API call.
    if [ ${#attach_paths[@]} -gt 0 ]; then
        attach_preflight_files "${attach_paths[@]}" || return 1
    fi
    [[ "$description_set" != "true" ]] || require_issue_header_shape "$description" || return 1
    local project_map=""
    if [ -n "$project" ]; then
        project_map=$(linear_project_map) || return 1
        linear_map_preflight "$project_map" "$project" update || return 1
    fi
    linear_guard_issue_team bulk-update "${identifiers[@]}" || return 1

    # The state check and the map-project check run here, before any write,
    # so neither refusal leaves an issue Done, moved or with uploaded assets.
    # update_issue still refuses per issue in the write loop below (a
    # --milestone missing from that issue's project, a label for that issue's
    # team), after earlier issues are written. This loop reads each issue at
    # most once, and only when the state check or the issue's team needs it:
    # the guard above pins every issue to LINEAR_TEAM when one is set. The map
    # project is judged in each issue's own team; issue_project_id keeps each
    # team's result for the update_issue subshells below.
    local own_team_id=""
    if [[ -n "$project_map" && -n "$DEFAULT_TEAM" ]]; then
        linear_own_team || return 1
        own_team_id=$(jq -r '.id' <<<"$LINEAR_OWN_TEAM") || return 1
    fi
    if [[ -n "$state" || -n "$project_map" ]]; then
        local preflight_failed=0 issue_result effective_description team_id
        for id in "${identifiers[@]}"; do
            issue_result=""
            if [[ -n "$state" || -z "$own_team_id" ]] && ! issue_result=$(get_issue "$id" --format=raw); then
                preflight_failed=1
                continue
            fi
            if [ -n "$state" ]; then
                effective_description="$description"
                if [ "$description_set" != true ]; then
                    effective_description=$(jq -r '.issue.description // ""' <<<"$issue_result") || return 1
                fi
                resolve_issue_update_state "$issue_result" "$state" "$effective_description" >/dev/null || preflight_failed=1
            fi
            if [ -n "$project_map" ]; then
                team_id="$own_team_id"
                [ -n "$team_id" ] || team_id=$(jq -r '.issue.team.id // empty' <<<"$issue_result") || return 1
                issue_project_id "$project_map" "$project" "$team_id" "$id" || return 1
            fi
        done
        [ "$preflight_failed" = 0 ] || return 1
    fi

    # Process each issue
    local results=()
    local success_count=0
    local fail_count=0

    # update_issue writes advisory warnings to stderr on its success path (the
    # sub-issue sort-order note, a skipped label). Merging those into the
    # captured stdout would break the .success parse and report a committed
    # update as a failure, so stderr is captured aside: relayed as a warning
    # when the update succeeded, folded into the error report when it did not.
    local stderr_file
    stderr_file=$(mktemp)

    for id in "${identifiers[@]}"; do
        local result
        local update_rc=0
        : >"$stderr_file"
        if result=$(update_issue "$id" "${update_args[@]}" 2>"$stderr_file"); then
            update_rc=0
        else
            update_rc=$?
        fi

        local stderr_text
        stderr_text=$(cat "$stderr_file")

        local success
        success=$(echo "$result" | jq -r '.success // false' 2>/dev/null || echo "false")

        if [ "$update_rc" -eq 0 ] && [ "$success" = "true" ]; then
            ((++success_count))
            [ -n "$stderr_text" ] && printf '%s\n' "$stderr_text" >&2
            results+=("$(echo "$result" | jq -c '{identifier, success: true}')")
        else
            ((++fail_count))
            local detail="$result"
            if [ -n "$stderr_text" ]; then
                detail="${detail:+$detail
}$stderr_text"
            fi
            if [ -z "$detail" ]; then
                detail="update_issue exited with status $update_rc without output"
            fi
            results+=("$(jq -cn --arg identifier "$id" --arg error "$detail" --argjson exit_code "$update_rc" \
                '{identifier: $identifier, success: false, exit_code: $exit_code, error: $error}')")
        fi
    done
    rm -f "$stderr_file"

    # Output summary
    rm -f "$stderr_file"

    local results_json
    results_json=$(printf '%s\n' "${results[@]}" | jq -s '.')
    jq -n \
        --argjson success "$([ "$fail_count" -eq 0 ] && echo true || echo false)" \
        --argjson partial "$([ "$success_count" -gt 0 ] && [ "$fail_count" -gt 0 ] && echo true || echo false)" \
        --argjson updated "$success_count" \
        --argjson failed "$fail_count" \
        --argjson results "$results_json" \
        '{success: $success, partial: $partial, updated: $updated, failed: $failed, results: $results}'

    if [ "$fail_count" -gt 0 ]; then
        return 1
    fi
}

get_issue() {
    # Read by lib/pages.sh when a children connection is left open.
    local LINEAR_ISSUE_CHILD_MODE=brief LINEAR_CHILD_DEPTH=1
    local issue_id=""
    local with_bundle="false"
    local extra_args=()
    FORMAT="${DEFAULT_FORMAT}"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --format)
            FORMAT="$2"
            shift 2
            ;;
        --format=*)
            FORMAT="${1#--format=}"
            shift
            ;;
        --with-bundle)
            with_bundle="true"
            shift
            ;;
        *)
            if [ -z "$issue_id" ]; then
                issue_id="$1"
            else
                extra_args+=("$1")
            fi
            shift
            ;;
        esac
    done

    if [ -z "$issue_id" ]; then
        echo '{"error": "Issue ID required"}' >&2
        return 1
    fi

    linear_require_format "$FORMAT" safe raw compact || return 1

    # Warn about extra arguments (common mistake: use bulk-get for multiple)
    if [ ${#extra_args[@]} -gt 0 ]; then
        echo "Warning: 'get' accepts only one issue. Ignored: ${extra_args[*]}" >&2
        echo "Hint: Use 'bulk-get' for multiple issues: linear.sh issues bulk-get ${issue_id}" >&2
        if [[ " ${extra_args[*]} " == *" --bundle "* ]]; then
            echo "Hint: Read the bundle: linear.sh issues get ${issue_id} --with-bundle" >&2
        fi
    fi

    local query
    if [ "$with_bundle" = "true" ]; then
        LINEAR_ISSUE_CHILD_MODE=bundle
        LINEAR_CHILD_DEPTH=3
        # Extended query with 3-level recursive children for bundle analysis
        query='
        query GetIssueWithBundle($id: String!) {
            issue(id: $id) {
                id
                identifier
                title
                description
                state { name type }
                assignee { name email }
                project { id name }
                projectMilestone { id name }
                cycle { id name number }
                team { name }
                labels { pageInfo { hasNextPage endCursor } nodes { name } }
                priority
                estimate
                sortOrder
                url
                branchName
                createdAt
                updatedAt
                archivedAt
                trashed
                parent { id identifier title }
'"$ISSUE_RELATION_FIELDS"'
                children {
                    pageInfo { hasNextPage endCursor }
                    nodes {
                        id identifier title description
                        state { name type }
                        assignee { name }
                        labels { pageInfo { hasNextPage endCursor } nodes { name } }
                        priority estimate
                        parent { identifier }
'"$ISSUE_RELATION_FIELDS"'
                        children {
                            pageInfo { hasNextPage endCursor }
                            nodes {
                                id identifier title description
                                state { name type }
                                assignee { name }
                                labels { pageInfo { hasNextPage endCursor } nodes { name } }
                                priority estimate
                                parent { identifier }
'"$ISSUE_RELATION_FIELDS"'
                                children {
                                    pageInfo { hasNextPage endCursor }
                                    nodes {
                                        id identifier title description
                                        state { name type }
                                        assignee { name }
                                        labels { pageInfo { hasNextPage endCursor } nodes { name } }
                                        priority estimate
                                        parent { identifier }
'"$ISSUE_RELATION_FIELDS"'
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }'
    else
        query='
        query GetIssue($id: String!) {
            issue(id: $id) {
                id
                identifier
                title
                description
                state { name type }
                assignee { name email }
                project { id name }
                projectMilestone { id name }
                cycle { id name number }
                team { id name }
                labels { pageInfo { hasNextPage endCursor } nodes { name } }
                priority
                estimate
                sortOrder
                url
                branchName
                createdAt
                updatedAt
                archivedAt
                trashed
                parent { id identifier title }
                children { pageInfo { hasNextPage endCursor } nodes { id identifier title state { name } } }
                syncedWith { metadata { ... on ExternalEntityInfoGithubMetadata { owner repo number } } }
'"$ISSUE_RELATION_FIELDS"'
            }
        }'
    fi

    local variables="{\"id\": \"$issue_id\"}"
    local result
    result=$(graphql_query "$query" "$variables") || return 1

    if ! jq -e '.issue.id | strings | select(length > 0)' <<<"$result" >/dev/null; then
        jq -cn --arg id "$issue_id" '{error: ("Issue not found: " + $id)}' >&2
        return 1
    fi

    # Apply output format
    case "$FORMAT" in
    raw)
        linear_public_result "$result"
        ;;
    compact)
        if [ "$with_bundle" = "true" ]; then
            format_issue_with_bundle_compact "$result"
        else
            format_issue_compact "$result"
        fi
        ;;
    safe)
        if [ "$with_bundle" = "true" ]; then
            format_issue_with_bundle "$result"
        else
            format_issue_single "$result"
        fi
        ;;
    esac
}

# Agent-routing guard. A create with no agent:* label lands
# invisible to agent routing — no labels, project, or routing — while the CLI
# prints a URL that looks like success. When the project declares its
# agent-label set (LINEAR_AGENT_LABELS in kendex.settings.toml [env],
# comma- or space-separated), refuse a bare create before any API call.
# An undeclared/empty set keeps the guard off; --no-agent-label opts a
# single deliberate bare create out (e.g. intake mirroring).
require_agent_routing_label() {
    local labels="$1" opt_out="$2"
    local declared="${LINEAR_AGENT_LABELS:-}"
    [ -n "$declared" ] || return 0
    [ "$opt_out" = "1" ] && return 0

    local declared_names=()
    IFS=', ' read -ra declared_names <<<"$declared"

    # Supplied labels split on commas only — label names may contain spaces.
    local supplied_names=()
    [ -n "$labels" ] && IFS=',' read -ra supplied_names <<<"$labels"

    local supplied declared_name agent_matched=0 unknown_agent=""
    for supplied in ${supplied_names[@]+"${supplied_names[@]}"}; do
        kendex_trim supplied "$supplied"
        [ -n "$supplied" ] || continue
        local is_declared=0
        for declared_name in ${declared_names[@]+"${declared_names[@]}"}; do
            if [ "$supplied" = "$declared_name" ]; then
                is_declared=1
                break
            fi
        done
        if [ "$is_declared" = "1" ]; then
            agent_matched=1
        elif [[ "$supplied" == agent:* ]]; then
            unknown_agent="${unknown_agent:+$unknown_agent, }$supplied"
        fi
    done

    # A typoed agent label would otherwise be warn-and-skipped by
    # resolve_label_id, creating an unrouted issue that looks routed.
    if [ -n "$unknown_agent" ]; then
        jq -cn --arg unknown "$unknown_agent" --arg declared "$declared" \
            '{error: ("Unknown agent label(s): " + $unknown + " - not in this project declared agent-label set (LINEAR_AGENT_LABELS in kendex.settings.toml [env]): " + $declared + ". Label resolution silently skips unknown names, so this would create an issue that is invisible to agent routing. Fix the label name, or pass --no-agent-label for a deliberate bare create.")}' >&2
        return 1
    fi
    if [ "$agent_matched" != "1" ]; then
        jq -cn --arg declared "$declared" \
            '{error: ("Refusing to create an unrouted issue: this project declares an agent-label taxonomy (LINEAR_AGENT_LABELS in kendex.settings.toml [env]) and no agent:* label was supplied. An issue created without one gets no agent routing - the create would print a URL and look like success while the issue sits invisible to every agent. Route tracked issue creation through the TPM pipeline (project-management skill), which owns labels, project, priority, and relations. Direct create is for exceptions only: pass --labels with one of [" + $declared + "], or --no-agent-label for a deliberate bare create (e.g. intake mirroring).")}' >&2
        return 1
    fi
    return 0
}

# Project map guard
# -----------------------------------------------------------------------------
# Under a declared project map (project-management references/project-map.md),
# an issue write places its issue only in a map project, and a create names
# one. This script holds the rule because Linear cannot: an issue may join any
# project its team can reach, and no team setting narrows which
# (https://linear.app/docs/teams). With no map both checks pass and send no
# request.

# Refuse, before any request, a placement the map's text rules out: a create
# with no project, and a project name the map does not list. A UUID waits for
# the live check.
# Usage: linear_map_preflight MAP REF ACTION || return 1
linear_map_preflight() {
    local map="$1" ref="$2" action="$3" legal
    [[ -n "$map" ]] || return 0
    legal=$(jq -c '[.projects[].name]' <<<"$map") || return 1
    if [[ -z "$ref" ]]; then
        [[ "$action" == create ]] || return 0
        linear_project_message project-missing "" "$legal" >&2
        return 1
    fi
    [[ ! "$ref" =~ $LINEAR_UUID_PATTERN ]] || return 0
    if ! jq -e --arg ref "$ref" 'any(.[]; . == $ref)' <<<"$legal" >/dev/null; then
        linear_project_message off-map "$ref" "$legal" >&2
        return 1
    fi
}

# Print the Linear id of the map project REF names, read live within TEAM_ID
# (empty reads the workspace), or refuse: a map name with no live project or
# with more than one, and a UUID that is no map project's.
# Usage: project_id=$(linear_map_live MAP REF TEAM_ID) || return 1
linear_map_live() {
    local map="$1" ref="$2" team_id="$3" projects entry legal
    projects=$(linear_map_projects "$map" "$team_id") || return 1
    entry=$(jq -c --arg ref "$ref" 'first(.[] | select(.name == $ref or .id == $ref)) // empty' <<<"$projects") || return 1
    if [[ -z "$entry" ]]; then
        legal=$(jq -c '[.projects[].name]' <<<"$map") || return 1
        linear_project_message off-map "$ref" "$legal" >&2
        return 1
    fi
    case "$(jq -r '.live' <<<"$entry")" in
    1) jq -r '.id' <<<"$entry" ;;
    0)
        linear_project_message declared-missing "$(jq -r '.name' <<<"$entry")" >&2
        return 1
        ;;
    *)
        linear_project_message ambiguous "$(jq -r '.name' <<<"$entry")" >&2
        return 1
        ;;
    esac
}

# The Linear id each --project ref of this invocation resolved to, keyed by
# "TEAM_ID:REF": a ref resolved in one team says nothing of another. A
# `$(...)` subshell inherits it, so bulk-update fills it before its
# update_issue subshells and each finds its issue's team there.
declare -A LINEAR_ISSUE_PROJECT_IDS=()
ISSUE_PROJECT_ID=""

# Set ISSUE_PROJECT_ID to the Linear id of --project REF for ISSUE, an
# existing issue of team TEAM_ID: under MAP the map project in that team, else
# the project resolve_project_id names. A name resolves only in the issue's
# team, so an issue whose team is unknown refuses one; a UUID needs no team.
# Call it in the command's own shell, not `$(...)`, so the result is kept.
# Usage: issue_project_id MAP REF TEAM_ID ISSUE || return 1
issue_project_id() {
    local map="$1" ref="$2" team_id="$3" issue="$4" key="$3:$2" id
    if [[ -n "${LINEAR_ISSUE_PROJECT_IDS[$key]:-}" ]]; then
        ISSUE_PROJECT_ID="${LINEAR_ISSUE_PROJECT_IDS[$key]}"
        return 0
    fi
    if [[ -z "$team_id" && ! "$ref" =~ $LINEAR_UUID_PATTERN ]]; then
        jq -cn --arg issue "$issue" '{code: "ISSUE_TEAM_MISSING", issue: $issue, error: ("Issue team missing: " + $issue)}' >&2
        return 1
    fi
    if [ -n "$map" ]; then
        id=$(linear_map_live "$map" "$ref" "$team_id") || return 1
    else
        id=$(resolve_project_id "$ref" "$team_id") || return 1
    fi
    [ -n "$id" ] || return 1
    LINEAR_ISSUE_PROJECT_IDS[$key]="$id"
    ISSUE_PROJECT_ID="$id"
}

# Create pending non-image attachments on an issue that already exists.
# Entries are "assetUrl<TAB>title" strings from the upload loop. A failure
# here is a partial write: the issue mutation succeeded but an attachment is
# missing, so each failure emits a JSON error naming the issue with
# partial: true (same posture as bulk-update), and the caller must exit
# non-zero. Usage: apply_pending_attachments <uuid> <identifier> <entry>...
apply_pending_attachments() {
    local issue_uuid="$1" issue_identifier="$2"
    shift 2
    local failed=0 entry
    for entry in "$@"; do
        local pending_url="${entry%%$'\t'*}"
        local pending_name="${entry#*$'\t'}"
        if [[ -z "$issue_uuid" ]] ||
            ! attach_create_issue_attachment "$issue_uuid" "$pending_url" "$pending_name"; then
            jq -cn --arg id "${issue_identifier:-$issue_uuid}" --arg name "$pending_name" --arg url "$pending_url" \
                '{error: ("attachmentCreate failed for " + $name + " on issue " + $id + " - the issue write succeeded but this attachment is missing (uploaded asset: " + $url + ")"), identifier: $id, partial: true}' >&2
            failed=1
        fi
    done
    return "$failed"
}

# Render pending attachment entries as the {url, repo_path} array that both
# the create response and the attach-only update response publish. Entries are
# the "assetUrl<TAB>title" strings from the upload loop, kept in request order.
# Usage: pending_attachments_json <entry>...
pending_attachments_json() {
    local rendered='[]' entry
    for entry in "$@"; do
        rendered=$(jq -cn --argjson prior "$rendered" \
            --arg url "${entry%%$'\t'*}" --arg repo_path "${entry#*$'\t'}" \
            '$prior + [{url: $url, repo_path: $repo_path}]') || return 1
    done
    printf '%s' "$rendered"
}

# Upload every --attach path, embedding images into the description variable
# of the caller and queueing non-images for apply_pending_attachments.
# Usage: upload_attach_paths <path>...
# Caller contract: `description` and `attach_pending` are the CALLER's
# variables (description grows ![name](assetUrl) embeds; attach_pending grows
# "assetUrl<TAB>filename" entries). Returns 1 on any upload failure.
upload_attach_paths() {
    local attach_path attach_info
    local attach_sep=$'\n\n'
    for attach_path in "$@"; do
        attach_info=$(attach_upload_file "$attach_path") || return 1
        local attach_url attach_name attach_type
        attach_url=$(echo "$attach_info" | jq -r '.assetUrl')
        attach_name=$(echo "$attach_info" | jq -r '.filename')
        attach_type=$(echo "$attach_info" | jq -r '.contentType')
        if [[ "$attach_type" == image/* ]]; then
            local attach_label
            attach_label="$(attach_markdown_label "$attach_name")"
            description="${description:+${description}${attach_sep}}![${attach_label}](${attach_url})"
        else
            local attach_title
            attach_title=$(attach_issue_title "$attach_path") || return 1
            attach_pending+=("${attach_url}"$'\t'"${attach_title}")
        fi
    done
}

create_issue() {
    local title=""
    local team=""
    local description=""
    local description_file=""
    local labels=""
    local project=""
    local state=""
    local priority=""
    local assignee=""
    local parent=""
    local milestone=""
    local cycle=""
    local estimate=""
    local requested_parent_id=""
    local output_format=""
    local no_agent_label=0
    local review_born=0
    local attach_paths=()
    local attach_pending=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --title)
            title="$2"
            shift 2
            ;;
        --attach)
            if [ -z "${2-}" ]; then
                echo '{"error": "--attach requires a path argument"}' >&2
                return 1
            fi
            attach_paths+=("$2")
            shift 2
            ;;
        --attach=*)
            attach_paths+=("${1#*=}")
            shift
            ;;
        --format)
            output_format="$2"
            shift 2
            ;;
        --format=*)
            output_format="${1#--format=}"
            shift
            ;;
        --team)
            team="$2"
            shift 2
            ;;
        --description)
            description="$2"
            shift 2
            ;;
        --description-file)
            description_file="$2"
            shift 2
            ;;
        --labels | --label)
            labels="${labels:+$labels,}$2"
            shift 2
            ;;
        --project)
            project="$2"
            shift 2
            ;;
        --state | --status)
            state="$2"
            shift 2
            ;;
        --priority)
            priority="$2"
            shift 2
            ;;
        --estimate)
            estimate="$2"
            shift 2
            ;;
        --assignee)
            assignee="$2"
            shift 2
            ;;
        --parent)
            parent="$2"
            shift 2
            ;;
        --parent=*)
            parent="${1#*=}"
            shift
            ;;
        --milestone)
            milestone="$2"
            shift 2
            ;;
        --cycle)
            cycle="$2"
            shift 2
            ;;
        --no-agent-label)
            no_agent_label=1
            shift
            ;;
        --review-born)
            review_born=1
            shift
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2
            return 1
            ;;
        *) break ;;
        esac
    done

    if [[ -n "$description" && -n "$description_file" ]]; then
        echo '{"error": "--description and --description-file are mutually exclusive"}' >&2
        return 1
    fi
    if [[ -n "$description_file" ]]; then
        read_description_file "$description_file"
    fi

    # Resolve the team target; creating an issue without one is refused here,
    # before any API call.
    linear_set_team_target "$team"
    linear_require_team_target || return 1
    local explicit_team="$team"
    team="$LINEAR_TEAM_TARGET"

    if [ -z "$title" ]; then
        echo '{"error": "Required: --title"}' >&2
        return 1
    fi

    # Normalize the label list ONCE, before the guard: split on commas, trim
    # each name, drop empties, rejoin. The guard and the resolver below must
    # see identical tokens — the guard trimming a copy while the resolver got
    # the raw " agent:rust" made the natural "bug, agent:rust" input pass the
    # guard and then be warn-skipped by resolution: an unrouted create that
    # looked routed.
    if [ -n "$labels" ]; then
        local normalized_labels="" raw_label_name
        local raw_label_names=()
        IFS=',' read -ra raw_label_names <<<"$labels"
        for raw_label_name in "${raw_label_names[@]}"; do
            kendex_trim raw_label_name "$raw_label_name"
            [ -n "$raw_label_name" ] || continue
            normalized_labels="${normalized_labels:+$normalized_labels,}$raw_label_name"
        done
        labels="$normalized_labels"
    fi

    require_agent_routing_label "$labels" "$no_agent_label" || return 1
    # The taxonomy judges label writes only: a create with no labels never
    # reads it, so an unreadable one does not stop a label-less create.
    local declared=""
    if [[ -n "$labels" ]]; then
        declared=$(linear_declared_labels) || return 1
        linear_require_declared_labels "$labels" || return 1
    fi
    local project_map
    project_map=$(linear_project_map) || return 1
    linear_map_preflight "$project_map" "$project" create || return 1
    require_issue_reach "$description" "$priority" "$review_born" || return 1
    require_issue_header_shape "$description" || return 1

    # --attach: refuse unreadable paths before ANY API call, which is what
    # `--help` promises, so this stays ahead of the resolvers below. Images
    # embed into the description; other files become Linear attachments on
    # the created issue after the create (attachmentCreate needs its id).
    if [ ${#attach_paths[@]} -gt 0 ]; then
        attach_preflight_files "${attach_paths[@]}" || return 1
    fi

    # The first request: the checks above need none, so they refuse first.
    linear_guard_create_team "$explicit_team" || return 1

    # The same team id scopes project names, labels and the issue mutation.
    local team_id
    team_id=$(resolve_team_id "$team") || return 1

    # Resolve --project and --milestone BEFORE uploading: each can still
    # refuse — an unknown project, a milestone name with no project, an
    # ambiguous one, a failed lookup — and a refusal after the upload strands
    # the asset in Linear storage with no issue referencing it. The ids they
    # yield are what the input below carries.
    local project_id=""
    if [ -n "$project_map" ]; then
        project_id=$(linear_map_live "$project_map" "$project" "$team_id") || return 1
    elif [ -n "$project" ]; then
        project_id=$(resolve_project_id "$project" "$team_id") || return 1
        if [ -z "$project_id" ]; then
            return 1
        fi
    fi
    local milestone_id=""
    if [ -n "$milestone" ]; then
        milestone_id=$(resolve_milestone_id "$milestone" "$project_id")
        if [ -z "$milestone_id" ]; then
            return 1
        fi
    fi

    # A miss refuses here, before the upload, so an unknown assignee leaves
    # no orphaned asset behind.
    local assignee_id=""
    if [ -n "$assignee" ]; then
        assignee_id=$(resolve_assignee_id "$assignee") || return 1
    fi

    # Handle labels (warn + skip on miss per label — EXCEPT agent:* labels:
    # the routing guard's promise is routed-or-refused, so an agent label
    # that fails to resolve, e.g. one declared in LINEAR_AGENT_LABELS but
    # since deleted in Linear, must fail the create rather than silently
    # produce an unrouted issue that already passed the guard. Under a
    # declared label taxonomy every miss refuses: a declared label can be
    # committed before it is created, and skipping it would report success
    # for an issue missing a label its taxonomy requires)
    local label_ids=()
    if [ -n "$labels" ]; then
        IFS=',' read -ra label_names <<<"$labels"
        for label_name in "${label_names[@]}"; do
            local label_id label_rc=0
            label_id=$(resolve_label_id "$label_name" team-id "$team_id") || label_rc=$?
            case "$label_rc" in
            0)
                label_ids+=("\"$label_id\"")
                ;;
            1)
                echo "Warning: Label not found: '$label_name'" >&2
                if [[ "$label_name" == agent:* ]] && [ -n "${LINEAR_AGENT_LABELS:-}" ]; then
                    # Hard-fail only under a declared taxonomy — undeclared repos
                    # keep the historical warn-and-skip for every label.
                    jq -cn --arg label "$label_name" \
                        '{error: ("Agent label failed to resolve in Linear: " + $label + " - refusing to create an issue that would look routed but is not. Create the label in Linear (or fix LINEAR_AGENT_LABELS), then retry.")}' >&2
                    return 1
                fi
                if [ -n "$declared" ]; then
                    linear_label_message declared-missing "$label_name" >&2
                    return 1
                fi
                echo "Skipped label '$label_name' — not found; the create proceeds without it" >&2
                ;;
            *)
                # The lookup failed, so whether the label exists is unknown.
                # Skipping it here is the warn-and-skip path for a label proved
                # absent, which this is not.
                jq -cn --arg label "$label_name" \
                    '{error: ("Label lookup failed for " + $label + " - refusing the create rather than dropping a label that may well exist")}' >&2
                return 1
                ;;
            esac
        done
    fi

    # Uploads run only after the routing guard and the resolvers above.
    if [ ${#attach_paths[@]} -gt 0 ]; then
        upload_attach_paths "${attach_paths[@]}" || return 1
    fi

    # Build input object - use jq for proper JSON escaping
    # printf, not `echo -n`: `echo -n "-n"` prints nothing, so a title or
    # description of exactly -n/-e/-E became an empty string server-side.
    local escaped_title
    escaped_title=$(printf '%s' "$title" | jq -Rs '.')
    local input_parts=("\"title\": $escaped_title")

    input_parts+=("\"teamId\": \"$team_id\"")

    if [ -n "$description" ]; then
        local escaped_desc
        escaped_desc=$(printf '%s' "$description" | jq -Rs '.')
        input_parts+=("\"description\": $escaped_desc")
    fi
    if [ -n "$priority" ]; then
        linear_require_pattern --priority "$priority" '^[0-4]$' "an integer 0-4" || return 1
        input_parts+=("\"priority\": $priority")
    fi
    if [ -n "$estimate" ]; then
        linear_require_pattern --estimate "$estimate" '^[0-9]+(\.[0-9]+)?$' "a non-negative number" || return 1
        input_parts+=("\"estimate\": $estimate")
    fi

    # Resolved above, before the attachment upload.
    if [ ${#label_ids[@]} -gt 0 ]; then
        local label_json
        label_json=$(
            IFS=,
            echo "[${label_ids[*]}]"
        )
        input_parts+=("\"labelIds\": $label_json")
    fi

    # Resolved above, before the attachment upload.
    if [ -n "$project_id" ]; then
        input_parts+=("\"projectId\": \"$project_id\"")
    fi

    # Handle state (fail fast with available states on miss)
    if [ -n "$state" ]; then
        local state_id
        state_id=$(resolve_state_id "$state" "$team_id")
        if [ -z "$state_id" ]; then
            return 1
        fi
        input_parts+=("\"stateId\": \"$state_id\"")
    fi

    # Resolved above, before the attachment upload.
    if [ -n "$assignee_id" ]; then
        input_parts+=("\"assigneeId\": \"$assignee_id\"")
    fi

    # Handle parent (for sub-issues) - resolve identifier to UUID
    if [ -n "$parent" ]; then
        local parent_id
        if ! parent_id=$(resolve_issue_id "$parent") || [ -z "$parent_id" ]; then
            echo "{\"error\": \"Parent issue not found: $parent\"}" >&2
            return 1
        fi
        requested_parent_id="$parent_id"
        input_parts+=("\"parentId\": \"$requested_parent_id\"")
    fi

    # Resolved above, before the attachment upload.
    if [ -n "$milestone_id" ]; then
        input_parts+=("\"projectMilestoneId\": \"$milestone_id\"")
    fi

    # Handle cycle (sprint)
    if [ -n "$cycle" ]; then
        linear_require_pattern --cycle "$cycle" "$LINEAR_UUID_PATTERN" "a cycle UUID" || return 1
        input_parts+=("\"cycleId\": \"$cycle\"")
    fi

    local input_json
    input_json=$(
        IFS=,
        echo "{${input_parts[*]}}"
    )

    local mutation="
    mutation CreateIssue(\$input: IssueCreateInput!) {
        issueCreate(input: \$input) {
            success
            issue {
                $ISSUE_RETURN_FIELDS
            }
        }
    }"

    local result
    result=$(graphql_query "$mutation" "{\"input\": $input_json}")
    # graphql_query treats any HTTP-200 payload as a completed request — a
    # payload-level rejection (issueCreate.success == false) must fail HERE,
    # before anything downstream claims a created issue or attaches uploads
    # to whatever object a failed payload happened to include.
    if [ "$(echo "$result" | jq -r '.issueCreate.success // false')" != "true" ]; then
        echo "$result" | jq -c '{error: "issueCreate was rejected (success != true) - no issue was created; uploaded files (if any) were not attached", data: (.issueCreate // {})}' >&2
        return 1
    fi
    local created_issue
    created_issue=$(echo "$result" | jq '.issueCreate.issue // empty')
    if [[ -n "$requested_parent_id" ]]; then
        if [[ -z "$created_issue" || "$created_issue" = "null" ]]; then
            jq -nc --arg parent "$parent" \
                '{error: "Issue created but response omitted issue object; cannot verify requested parent " + $parent}' >&2
            return 1
        fi

        local created_parent_id
        created_parent_id=$(echo "$created_issue" | jq -r '.parent.id // empty')
        if [ "$created_parent_id" != "$requested_parent_id" ]; then
            local child_issue_id
            child_issue_id=$(echo "$created_issue" | jq -r '.id // empty')
            if [ -z "$child_issue_id" ]; then
                jq -nc --arg parent "$parent" \
                    '{error: "Issue created but response omitted child id; cannot verify requested parent " + $parent}' >&2
                return 1
            fi

            local parent_fix_mutation="
            mutation EnsureIssueParent(\$id: String!, \$input: IssueUpdateInput!) {
                issueUpdate(id: \$id, input: \$input) {
                    success
                    issue {
                        $ISSUE_RETURN_FIELDS
                    }
                }
            }"
            local parent_fix_variables
            parent_fix_variables=$(jq -cn --arg id "$child_issue_id" --arg parentId "$requested_parent_id" \
                '{id: $id, input: {parentId: $parentId}}')
            local parent_fix_result
            if ! parent_fix_result=$(graphql_query "$parent_fix_mutation" "$parent_fix_variables"); then
                jq -nc --arg child "$child_issue_id" --arg parent "$parent" \
                    '{error: "Issue " + $child + " was created, but Linear did not attach parent " + $parent + " during create and the follow-up repair failed"}' >&2
                return 1
            fi

            local updated_issue
            updated_issue=$(echo "$parent_fix_result" | jq '.issueUpdate.issue // empty')
            local updated_parent_id
            updated_parent_id=$(echo "$updated_issue" | jq -r '.parent.id // empty')
            if [ "$updated_parent_id" != "$requested_parent_id" ]; then
                jq -nc --arg child "$child_issue_id" --arg parent "$parent" \
                    '{error: "Issue " + $child + " was created, but parent " + $parent + " could not be verified after follow-up repair"}' >&2
                return 1
            fi

            result=$(echo "$parent_fix_result" | jq -c '{issueCreate: {success: (.issueUpdate.success // false), issue: .issueUpdate.issue}}')
            created_issue="$updated_issue"
        fi
    fi
    # Non-image --attach files: attachmentCreate against the created issue.
    # The issue already exists here, so a failure must surface the created
    # identifier AND exit non-zero — never a zero exit with a silent gap.
    local attach_failed=0
    if [ ${#attach_pending[@]} -gt 0 ]; then
        if [[ -n "$created_issue" && "$created_issue" != "null" ]]; then
            local created_uuid created_identifier
            created_uuid=$(echo "$created_issue" | jq -r '.id // empty')
            created_identifier=$(echo "$created_issue" | jq -r '.identifier // empty')
            apply_pending_attachments "$created_uuid" "$created_identifier" \
                "${attach_pending[@]}" || attach_failed=1
        else
            echo '{"error": "Issue was created but the response omitted the issue object; uploaded files could not be attached", "partial": true}' >&2
            attach_failed=1
        fi
    fi
    local normalized
    normalized=$(normalize_mutation_response "$result" "issueCreate" "issue")
    # The create response is the immediate proof that each non-image record
    # landed. Report the requested count and, when
    # every attachmentCreate succeeded, the records themselves; a partial
    # failure leaves the list empty rather than claiming a missing record.
    local attach_record_count=${#attach_pending[@]}
    if [ "$attach_record_count" -gt 0 ]; then
        local created_attachments='[]'
        if [ "$attach_failed" = "0" ]; then
            created_attachments=$(pending_attachments_json "${attach_pending[@]}") || return 1
        fi
        # Pretty, like normalize_mutation_response: the create response has one
        # shape whether or not --attach was passed.
        normalized=$(echo "$normalized" | jq --argjson count "$attach_record_count" \
            --argjson attachments "$created_attachments" \
            '. + {attachments_requested: $count, attachments: $attachments}') || return 1
    fi
    # --format=ids mirrors the query-command contract: print ONLY the created
    # identifier (one per line, nothing else) so workflows can capture it
    # deterministically. Any other/absent format keeps the default JSON output.
    if [ "$output_format" = "ids" ]; then
        echo "$normalized" | jq -r '.identifier // empty'
    else
        echo "$normalized"
    fi
    if [ "$attach_failed" = "1" ]; then
        return 1
    fi
}

# Both update routes use the description that will be written. Completion can
# therefore tick verified boxes and set Done in one mutation, without a bypass.
# FLT-1168 reached update from Verifying with an open post-merge box.
resolve_issue_update_state() {
    local issue_result="$1" state="$2" description="$3"
    local issue_id team_id resolved parsed open_boxes missing_evidence_boxes state_type
    issue_id=$(jq -r '.issue.identifier' <<<"$issue_result") || return 1
    team_id=$(jq -r '.issue.team.id // empty' <<<"$issue_result") || return 1
    if [ -z "$team_id" ]; then
        jq -cn --arg issue "$issue_id" '{error: ("Issue team id missing: " + $issue)}' >&2
        return 1
    fi
    resolved=$(resolve_state_id "$state" "$team_id" raw) || return 1
    parsed=$(done_when_parse "$description" '[]') || return 1
    open_boxes=$(jq -c '[.boxes[] | select(.checked | not) | .number]' <<<"$parsed") || return 1
    missing_evidence_boxes=$(jq -c '.missing_evidence_boxes' <<<"$parsed") || return 1
    if [ "$open_boxes" != '[]' ] || [ "$missing_evidence_boxes" != '[]' ]; then
        state_type=$(jq -r '.type // empty' <<<"$resolved") || return 1
        if [ -z "$state_type" ]; then
            printf 'linear: refused=state-type-unavailable issue=%s state=%s\n' "$issue_id" "$state" >&2
            return 1
        fi
        if [ "$state_type" = completed ]; then
            if [ "$open_boxes" != '[]' ]; then
                printf 'linear: refused=done-when-open issue=%s open_boxes=%s fix=issues complete\n' "$issue_id" "$open_boxes" >&2
                return 1
            fi
            if [ "$missing_evidence_boxes" != '[]' ]; then
                printf 'linear: refused=done-when-evidence issue=%s missing_evidence_boxes=%s fix=issues complete\n' "$issue_id" "$missing_evidence_boxes" >&2
                return 1
            fi
        fi
    fi
    jq -r '.id' <<<"$resolved"
}

update_issue() {
    local issue_id="$1"
    shift

    local state=""
    local labels=""
    local title=""
    local description=""
    local description_set="false"
    local description_file=""
    local project=""
    local priority=""
    local assignee=""
    local parent=""
    local remove_parent="false"
    local milestone=""
    local cycle=""
    local clear_cycle="false"
    local estimate=""
    local clear_estimate="false"
    local clear_labels="false"
    local clear_assignee="false"
    local sort_order=""
    local output_format=""
    local attach_paths=()
    local attach_pending=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --attach)
            if [ -z "${2-}" ]; then
                echo '{"error": "--attach requires a path argument"}' >&2
                return 1
            fi
            attach_paths+=("$2")
            shift 2
            ;;
        --attach=*)
            attach_paths+=("${1#*=}")
            shift
            ;;
        --format)
            output_format="$2"
            shift 2
            ;;
        --format=*)
            output_format="${1#--format=}"
            shift
            ;;
        --state | --status)
            state="$2"
            shift 2
            ;;
        --state=* | --status=*)
            state="${1#*=}"
            shift
            ;;
        --labels | --label)
            labels="${labels:+$labels,}$2"
            shift 2
            ;;
        --labels=* | --label=*)
            labels="${labels:+$labels,}${1#*=}"
            shift
            ;;
        --title)
            title="$2"
            shift 2
            ;;
        --title=*)
            title="${1#*=}"
            shift
            ;;
        --description)
            description="$2"
            description_set="true"
            shift 2
            ;;
        --description=*)
            description="${1#*=}"
            description_set="true"
            shift
            ;;
        --description-file)
            description_file="$2"
            shift 2
            ;;
        --description-file=*)
            description_file="${1#*=}"
            shift
            ;;
        --project)
            project="$2"
            shift 2
            ;;
        --project=*)
            project="${1#*=}"
            shift
            ;;
        --parent)
            parent="$2"
            shift 2
            ;;
        --parent=*)
            parent="${1#*=}"
            shift
            ;;
        --remove-parent)
            remove_parent="true"
            shift
            ;;
        --milestone)
            milestone="$2"
            shift 2
            ;;
        --milestone=*)
            milestone="${1#*=}"
            shift
            ;;
        --priority)
            priority="$2"
            shift 2
            ;;
        --priority=*)
            priority="${1#*=}"
            shift
            ;;
        --estimate)
            estimate="$2"
            shift 2
            ;;
        --estimate=*)
            estimate="${1#*=}"
            shift
            ;;
        --clear-estimate)
            clear_estimate="true"
            shift
            ;;
        --clear-assignee)
            clear_assignee="true"
            shift
            ;;
        --clear-labels)
            clear_labels="true"
            shift
            ;;
        --assignee)
            assignee="$2"
            shift 2
            ;;
        --assignee=*)
            assignee="${1#*=}"
            shift
            ;;
        --cycle)
            cycle="$2"
            shift 2
            ;;
        --cycle=*)
            cycle="${1#*=}"
            shift
            ;;
        --clear-cycle)
            clear_cycle="true"
            shift
            ;;
        --sort-order)
            sort_order="$2"
            shift 2
            ;;
        --sort-order=*)
            sort_order="${1#*=}"
            shift
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2
            return 1
            ;;
        *) break ;;
        esac
    done

    if [[ "$description_set" == "true" && -n "$description_file" ]]; then
        echo '{"error": "--description and --description-file are mutually exclusive"}' >&2
        return 1
    fi
    if [[ -n "$description_file" ]]; then
        read_description_file "$description_file"
        description_set="true"
    fi

    # --attach: refuse unreadable paths before any API call.
    if [ ${#attach_paths[@]} -gt 0 ]; then
        attach_preflight_files "${attach_paths[@]}" || return 1
    fi
    # A move is judged against the map; an issue already off it stays where
    # it is, as a label it already carries is kept, for `projects audit`.
    local project_map=""
    if [ -n "$project" ]; then
        project_map=$(linear_project_map) || return 1
        linear_map_preflight "$project_map" "$project" update || return 1
    fi
    linear_guard_issue_team update "$issue_id" || return 1

    local input_parts=()

    # Get issue to find its team for state and label lookup - use raw format
    local issue_result
    issue_result=$(get_issue "$issue_id" --format=raw) || return 1
    # The header shape is judged against the stored body, which an owner
    # action line may be placed on, replaced on or removed from. The sentinel
    # keeps the stored body's trailing newlines through the capture.
    if [[ "$description_set" == "true" ]]; then
        local stored_description
        stored_description=$(jq -r '(.issue.description // "") + "."' <<<"$issue_result") || return 1
        require_issue_header_shape "$description" "${stored_description%.}" || return 1
    fi
    local team_name team_id
    team_name=$(echo "$issue_result" | jq -r '.issue.team.name // empty')
    # The issue names its own team by id: a state resolves under that id, never
    # through a name lookup that a team key can make ambiguous.
    team_id=$(echo "$issue_result" | jq -r '.issue.team.id // empty')
    # The scope a milestone name resolves in when --project is absent: the
    # issue is already in a project, and asking for --project to name the one
    # it is in would move it to satisfy a lookup.
    local issue_project_id
    issue_project_id=$(echo "$issue_result" | jq -r '.issue.project.id // empty')

    local state_id="" effective_description="$description"
    if [ -n "$state" ]; then
        if [ "$description_set" != true ]; then
            effective_description=$(jq -r '.issue.description // ""' <<<"$issue_result") || return 1
        fi
        state_id=$(resolve_issue_update_state "$issue_result" "$state" "$effective_description") || return 1
        input_parts+=("\"stateId\": \"$state_id\"")
    fi

    # Same rule as the label resolution below, applied to the pure argument
    # check: a combination that can only be refused must be refused before any
    # upload, or the refusal strands the uploaded asset in Linear storage.
    if [ "$clear_assignee" = "true" ] && [ -n "$assignee" ]; then
        echo '{"error": "Use either --assignee or --clear-assignee"}' >&2
        return 1
    fi
    if [ "$clear_labels" = "true" ] && [ -n "$labels" ]; then
        echo '{"error": "Use either --labels <names> or --clear-labels, not both"}' >&2
        return 1
    fi
    # Resolved before the attachment upload below, for the reason the label
    # resolution states: an unknown project, a milestone name with no project,
    # an ambiguous one and a failed lookup all still refuse, and a refusal
    # after the upload strands the asset in Linear storage.
    local project_id=""
    if [ -n "$project" ]; then
        issue_project_id "$project_map" "$project" "$team_id" "$issue_id" || return 1
        project_id="$ISSUE_PROJECT_ID"
    fi
    local milestone_id=""
    if [ -n "$milestone" ]; then
        milestone_id=$(resolve_milestone_id "$milestone" "${project_id:-$issue_project_id}")
        if [ -z "$milestone_id" ]; then
            return 1
        fi
    fi

    # Resolve --labels BEFORE any attachment upload: an unresolvable label
    # refuses the whole update below, and an upload done first would strand
    # orphaned assets in Linear storage (the create path pre-resolves its
    # refusal-capable labels for the same reason).
    local resolved_label_json=""
    if [ "$clear_labels" != "true" ] && [ -n "$labels" ]; then
        if [ -z "$team_name" ]; then
            jq -cn --arg issue "$issue_id" '{error: ("Issue team missing: " + $issue)}' >&2
            return 1
        fi
        # Activation, block and unblock reach here too: activation and block
        # rebuild the set from the issue's own labels plus the one they apply,
        # and unblock rebuilds it without the label it removes.
        local kept_labels
        kept_labels=$(jq -c '[.issue.labels.nodes[]?.name]' <<<"$issue_result") || return 1
        linear_require_declared_labels "$labels" "$kept_labels" || return 1
        IFS=',' read -ra label_names <<<"$labels"
        local label_ids=()
        for label_name in "${label_names[@]}"; do
            local label_id label_rc=0
            # --labels replaces the whole set, so neither a miss nor a failed
            # lookup may drop a name and send a partial replacement.
            label_id=$(resolve_label_id "$label_name" team-name "$team_name") || label_rc=$?
            if [ "$label_rc" = 1 ]; then
                jq -cn --arg team "$team_name" --arg label "$label_name" \
                    '{error: ("Label not found for team " + ($team | tojson) + ": " + ($label | tojson))}' >&2
            fi
            [ "$label_rc" = 0 ] || return 1
            label_ids+=("\"$label_id\"")
        done
        if [ ${#label_ids[@]} -eq 0 ]; then
            jq -cn --arg labels "$labels" \
                '{error: ("No requested label resolved (" + $labels + ") - refusing to send an empty label set, which would clear every label on the issue. Use --clear-labels to do that deliberately.")}' >&2
            return 1
        fi
        resolved_label_json=$(
            IFS=,
            echo "[${label_ids[*]}]"
        )
    fi

    # A miss refuses here, before the upload, so an unknown assignee leaves
    # no orphaned asset behind.
    local assignee_id=""
    if [ -n "$assignee" ]; then
        assignee_id=$(resolve_assignee_id "$assignee") || return 1
    fi

    # Upload --attach files. Image embeds append to the description being
    # written; when this update does not itself rewrite the description,
    # seed it from the issue's current one so the embed is an append, not a
    # wipe. Non-images queue for attachmentCreate after the update.
    if [ ${#attach_paths[@]} -gt 0 ]; then
        if [[ "$description_set" == "false" ]]; then
            local has_image_attach=0 attach_probe
            for attach_probe in "${attach_paths[@]}"; do
                case "$(attach_upload_content_type "$attach_probe")" in
                image/*) has_image_attach=1 ;;
                esac
            done
            if [ "$has_image_attach" = "1" ]; then
                description=$(echo "$issue_result" | jq -r '.issue.description // empty')
            fi
        fi
        upload_attach_paths "${attach_paths[@]}" || return 1
    fi

    if [ -n "$title" ]; then
        local escaped_title
        escaped_title=$(printf '%s' "$title" | jq -Rs '.')
        input_parts+=("\"title\": $escaped_title")
    fi
    # An owner close can clear the last description line. Empty means clear
    # only when the caller supplied it; attachment embeds also write a body.
    if [[ "$description_set" == "true" || -n "$description" ]]; then
        local escaped_desc
        escaped_desc=$(printf '%s' "$description" | jq -Rs '.')
        input_parts+=("\"description\": $escaped_desc")
    fi
    if [ -n "$priority" ]; then
        linear_require_pattern --priority "$priority" '^[0-4]$' "an integer 0-4" || return 1
        input_parts+=("\"priority\": $priority")
    fi

    # Handle estimate. Real estimates are 1-5; Linear represents "no estimate" as
    # null. Clear the estimate via --clear-estimate or the --estimate 0 alias
# (this keeps coordination-only parents out of the estimate-0 format).
    if [ "$clear_estimate" = "true" ] && [ -n "$estimate" ] && [ "$estimate" != "0" ]; then
        echo '{"error": "Use either --estimate <1-5> or --clear-estimate, not both"}' >&2
        return 1
    elif [ "$clear_estimate" = "true" ] || [ "$estimate" = "0" ]; then
        input_parts+=("\"estimate\": null")
    elif [ -n "$estimate" ]; then
        if [[ "$estimate" =~ ^[1-5]$ ]]; then
            input_parts+=("\"estimate\": $estimate")
        else
            echo '{"error": "Invalid --estimate: must be an integer 1-5 (use 0 or --clear-estimate to unset)"}' >&2
            return 1
        fi
    fi

    # Sort order only meaningful on parent/standalone issues (sub-issues render under parent)
    if [ -n "$sort_order" ]; then
        local parent_id
        parent_id=$(echo "$issue_result" | jq -r '.issue.parent.identifier // empty')
        if [ -n "$parent_id" ]; then
            echo "WARN: $issue_id is a sub-issue of $parent_id — sort order has no effect on sub-issues" >&2
        fi
        linear_require_pattern --sort-order "$sort_order" '^-?[0-9]+(\.[0-9]+)?$' "a number" || return 1
        input_parts+=("\"sortOrder\": $sort_order")
    fi

    # --labels REPLACES the issue's label set, so a name that does not become an
    # id is not a skipped label — it is a label removed from the issue. A failed
    # lookup (rc 2) leaves that unknowable, and resolving nothing at all would
    # send an empty array, stripping every label while reporting success.
    # --clear-labels is the only way to ask for that.
    if [ "$clear_labels" = "true" ]; then
        # The --labels conflict was refused before the upload, above.
        input_parts+=("\"labelIds\": []")
    elif [ -n "$labels" ]; then
        # Resolved (or refused) above, before the attachment upload.
        input_parts+=("\"labelIds\": $resolved_label_json")
    fi

    # Resolved above, before the attachment upload.
    if [ -n "$project_id" ]; then
        input_parts+=("\"projectId\": \"$project_id\"")
    fi

    # Resolved above, before the attachment upload.
    if [ -n "$assignee_id" ]; then
        input_parts+=("\"assigneeId\": \"$assignee_id\"")
    fi
    if [ "$clear_assignee" = "true" ]; then
        input_parts+=('"assigneeId": null')
    fi

    # Handle parent (set or remove) - resolve identifier to UUID
    if [ "$remove_parent" = "true" ]; then
        input_parts+=("\"parentId\": null")
    elif [ -n "$parent" ]; then
        local parent_id
        parent_id=$(resolve_issue_id "$parent")
        if [ -z "$parent_id" ]; then
            echo "{\"error\": \"Parent issue not found: $parent\"}" >&2
            return 1
        fi
        input_parts+=("\"parentId\": \"$parent_id\"")
    fi

    # Resolved above, before the attachment upload.
    if [ -n "$milestone_id" ]; then
        input_parts+=("\"projectMilestoneId\": \"$milestone_id\"")
    fi

    # Handle cycle (sprint)
    if [ "$clear_cycle" = "true" ] && [ -n "$cycle" ]; then
        echo '{"error": "Use either --cycle or --clear-cycle, not both"}' >&2
        return 1
    elif [ "$clear_cycle" = "true" ]; then
        input_parts+=("\"cycleId\": null")
    elif [ -n "$cycle" ]; then
        linear_require_pattern --cycle "$cycle" "$LINEAR_UUID_PATTERN" "a cycle UUID" || return 1
        input_parts+=("\"cycleId\": \"$cycle\"")
    fi

    if [ ${#input_parts[@]} -eq 0 ] && [ ${#attach_pending[@]} -eq 0 ]; then
        echo '{"error": "No update options provided"}' >&2
        return 1
    fi

    # Attach-only update (non-image --attach, no field changes): there is
    # nothing to send through issueUpdate, so skip the mutation and only
    # create the attachments against the resolved issue.
    if [ ${#input_parts[@]} -eq 0 ]; then
        local attach_only_uuid attach_only_identifier attach_only_url
        attach_only_uuid=$(echo "$issue_result" | jq -r '.issue.id // empty')
        attach_only_identifier=$(echo "$issue_result" | jq -r '.issue.identifier // empty')
        attach_only_url=$(echo "$issue_result" | jq -r '.issue.url // empty')
        local attach_only_failed=0
        apply_pending_attachments "$attach_only_uuid" "$attach_only_identifier" \
            "${attach_pending[@]}" || attach_only_failed=1
        local attachments_json='[]'
        if [ "$attach_only_failed" = "0" ]; then
            attachments_json=$(pending_attachments_json "${attach_pending[@]}") || return 1
        fi
        jq -cn --arg identifier "$attach_only_identifier" --arg url "$attach_only_url" \
            --argjson ok "$([ "$attach_only_failed" = "0" ] && echo true || echo false)" \
            --argjson count "${#attach_pending[@]}" \
            --argjson attachments "$attachments_json" \
            '{success: $ok, identifier: $identifier, url: (if $url == "" then null else $url end), attachments_requested: $count, attachments: $attachments}'
        if [ "$attach_only_failed" = "1" ]; then
            return 1
        fi
        return 0
    fi

    local input_json
    input_json=$(
        IFS=,
        echo "{${input_parts[*]}}"
    )

    local mutation="
    mutation UpdateIssue(\$id: String!, \$input: IssueUpdateInput!) {
        issueUpdate(id: \$id, input: \$input) {
            success
            issue {
                $ISSUE_RETURN_FIELDS
            }
        }
    }"

    local result
    result=$(graphql_query "$mutation" "{\"id\": \"$issue_id\", \"input\": $input_json}")
    # Payload-level rejection (issueUpdate.success == false) must fail HERE —
    # falling through would report the pre-update issue and still attach
    # queued uploads to an issue the rejected update never touched.
    if [ "$(echo "$result" | jq -r '.issueUpdate.success // false')" != "true" ]; then
        echo "$result" | jq -c --arg id "$issue_id" '{error: ("issueUpdate was rejected (success != true) for " + $id + " - nothing was updated; uploaded files (if any) were not attached"), data: (.issueUpdate // {})}' >&2
        return 1
    fi
    local updated_issue
    updated_issue=$(echo "$result" | jq '.issueUpdate.issue // empty')
    local normalized
    normalized=$(normalize_mutation_response "$result" "issueUpdate" "issue")
    # Output format. Default (no --format) preserves the historical mutation
    # summary so existing callers that parse .success/.identifier/.data keep
    # working. When --format is passed explicitly, emit the updated issue in the
    # documented read format (safe is the README default), consistent with the
    # query actions. `safe`/`compact` reuse the shared formatters by wrapping the
    # mutation's issue in {issue: ...}; a response that omitted the issue object
    # falls back to the mutation summary.
    local wrapped_issue=""
    if [[ -n "$updated_issue" && "$updated_issue" != "null" ]]; then
        wrapped_issue=$(jq -n --argjson i "$updated_issue" '{issue: $i}')
    fi
    case "$output_format" in
    safe)
        if [[ -n "$wrapped_issue" ]]; then
            format_issue_single "$wrapped_issue"
        else
            echo "$normalized"
        fi
        ;;
    compact)
        if [[ -n "$wrapped_issue" ]]; then
            format_issue_compact "$wrapped_issue"
        else
            echo "$normalized"
        fi
        ;;
    ids)
        echo "$normalized" | jq -r '.identifier // empty'
        ;;
    raw)
        linear_public_result "$result"
        ;;
    "" | *)
        echo "$normalized"
        ;;
    esac

    # Non-image --attach files: attachmentCreate after the update. The update
    # itself succeeded (and was reported above), so a failure here must name
    # the issue and exit non-zero — never a zero exit with a silent gap.
    if [ ${#attach_pending[@]} -gt 0 ]; then
        local attach_target_uuid attach_target_identifier
        if [[ -n "$updated_issue" && "$updated_issue" != "null" ]]; then
            attach_target_uuid=$(echo "$updated_issue" | jq -r '.id // empty')
            attach_target_identifier=$(echo "$updated_issue" | jq -r '.identifier // empty')
        else
            attach_target_uuid=$(echo "$issue_result" | jq -r '.issue.id // empty')
            attach_target_identifier=$(echo "$issue_result" | jq -r '.issue.identifier // empty')
        fi
        apply_pending_attachments "$attach_target_uuid" "$attach_target_identifier" \
            "${attach_pending[@]}" || return 1
    fi
}

# IssueArchivePayload.success reports the request was processed, not that the
# entity mutated — Linear answers success=true even when the archive/trash
# no-ops server-side. Trust only the returned entity: require the
# marker field on it, and fail with
# a nonzero exit otherwise so a silent no-op can never look like success.
confirm_archive_mutation() {
    local result="$1"
    local operation="$2"
    local marker_filter="$3"
    local action="$4"
    local issue_ref="$5"
    local issue_id="$6"

    if ! echo "$result" | jq -e --arg op "$operation" \
        '.[$op].success == true and .[$op].entity != null and (.[$op].entity | '"$marker_filter"')' >/dev/null 2>&1; then
        echo "$result" | jq -c --arg op "$operation" --arg action "$action" --arg ref "$issue_ref" --arg id "$issue_id" \
            '{error: ($action + " not confirmed for " + $ref + " (resolved id: " + $id + "): " + $op + " returned success=\(.[$op].success // false) but the response entity does not confirm it — treat the issue as still active"), data: (.[$op] // {})}' >&2
        return 1
    fi

    normalize_mutation_response "$result" "$operation" "entity"
}

archive_issue() {
    local issue_ref="$1"
    shift || true
    linear_guard_issue_team archive "$issue_ref" || return 1

    # Resolve identifier to UUID (required for archive mutation)
    local issue_id
    issue_id=$(resolve_issue_id "$issue_ref")
    if [ -z "$issue_id" ]; then
        echo "{\"error\": \"Issue not found: $issue_ref\"}" >&2
        return 1
    fi

    local mutation='
    mutation ArchiveIssue($id: String!) {
        issueArchive(id: $id) {
            success
            entity { id identifier url archivedAt trashed }
        }
    }'
    local result
    result=$(graphql_query "$mutation" "{\"id\": \"$issue_id\"}")
    confirm_archive_mutation "$result" "issueArchive" '.archivedAt != null' "archive" "$issue_ref" "$issue_id"
}

trash_issue() {
    local issue_ref="$1"
    shift || true
    linear_guard_issue_team trash "$issue_ref" || return 1

    # Resolve identifier to UUID (required for delete mutation)
    local issue_id
    issue_id=$(resolve_issue_id "$issue_ref")
    if [ -z "$issue_id" ]; then
        echo "{\"error\": \"Issue not found: $issue_ref\"}" >&2
        return 1
    fi

    # Linear's issueDelete moves to trash (recoverable for 30 days)
    local mutation='
    mutation TrashIssue($id: String!) {
        issueDelete(id: $id) {
            success
            entity { id identifier url archivedAt trashed }
        }
    }'
    local result
    result=$(graphql_query "$mutation" "{\"id\": \"$issue_id\"}")
    confirm_archive_mutation "$result" "issueDelete" '.trashed == true' "trash" "$issue_ref" "$issue_id"
}

list_children() {
    # Read by lib/pages.sh when a children connection is left open.
    local LINEAR_ISSUE_CHILD_MODE=direct LINEAR_CHILD_DEPTH=1
    local issue_id=""
    local recursive="false"
    local pending_only="false"
    FORMAT="${DEFAULT_FORMAT}"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --format)
            FORMAT="$2"
            shift 2
            ;;
        --format=*)
            FORMAT="${1#--format=}"
            shift
            ;;
        --recursive | -r)
            recursive="true"
            shift
            ;;
        --pending)
            pending_only="true"
            shift
            ;;
        *)
            issue_id="$1"
            shift
            ;;
        esac
    done

    if [ -z "$issue_id" ]; then
        echo '{"error": "Issue ID required"}' >&2
        return 1
    fi

    linear_require_format "$FORMAT" safe raw ids || return 1

    local query
    if [ "$recursive" = "true" ]; then
        LINEAR_ISSUE_CHILD_MODE=recursive
        LINEAR_CHILD_DEPTH=3
        # Fetch 3 levels deep (covers nearly all real-world nesting)
        # Includes relations for blocking info between sub-issues
        query='
        query GetChildrenRecursive($id: String!) {
            issue(id: $id) {
                id
                identifier
                title
                children {
                    pageInfo { hasNextPage endCursor }
                    nodes {
                        id
                        identifier
                        title
                        state { name type }
                        assignee { name }
                        labels { pageInfo { hasNextPage endCursor } nodes { name } }
                        priority
                        estimate
                        parent { identifier }
'"$ISSUE_RELATION_FIELDS"'
                        children {
                            pageInfo { hasNextPage endCursor }
                            nodes {
                                id
                                identifier
                                title
                                state { name type }
                                assignee { name }
                                labels { pageInfo { hasNextPage endCursor } nodes { name } }
                                priority
                                estimate
                                parent { identifier }
'"$ISSUE_RELATION_FIELDS"'
                                children {
                                    pageInfo { hasNextPage endCursor }
                                    nodes {
                                        id
                                        identifier
                                        title
                                        state { name type }
                                        assignee { name }
                                        labels { pageInfo { hasNextPage endCursor } nodes { name } }
                                        priority
                                        estimate
                                        parent { identifier }
'"$ISSUE_RELATION_FIELDS"'
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }'
    else
        query='
        query GetChildren($id: String!) {
            issue(id: $id) {
                id
                identifier
                title
                children {
                    pageInfo { hasNextPage endCursor }
                    nodes {
                        id
                        identifier
                        title
                        state { name type }
                        assignee { name }
                        priority
                        estimate
                        createdAt
                    }
                }
            }
        }'
    fi

    local variables
    variables=$(jq -cn --arg id "$issue_id" '{id: $id}') || return 1
    local result
    result=$(graphql_query "$query" "$variables") || return 1

    # --pending drops completed and canceled rows. A flat read drops each such
    # row alone, so an open grandchild under a Done child stays listed. The
    # nested raw shape keeps a closed issue only as the container of an open
    # one beneath it. A raw row carries state.type, a flat row state_type.
    local open='def open: ((.state | objects | .type) // .state_type) | . != "completed" and . != "canceled";'
    if [ "$pending_only" = "true" ]; then
        if [ "$recursive" = "true" ]; then
            if [ "$FORMAT" = raw ]; then
                result=$(jq -c "$open"'
                    def prune: map(if (.children | type) == "object" then .children.nodes |= prune else . end
                        | select(open or ((.children.nodes // []) | length > 0)));
                    .issue.children.nodes |= prune' <<<"$result") || return 1
            fi
        else
            result=$(jq -c "$open"'.issue.children.nodes |= map(select(open))' <<<"$result") || return 1
        fi
    fi

    local rows
    case "$FORMAT" in
    raw)
        linear_public_result "$result"
        return
        ;;
    ids | safe)
        if [ "$recursive" = "true" ]; then
            rows=$(format_children_recursive "$result") || return 1
            if [ "$pending_only" = "true" ]; then
                rows=$(jq -c "$open"'map(select(open))' <<<"$rows") || return 1
            fi
        else
            rows=$(format_children_list "$result") || return 1
        fi
        ;;
    *)
        jq -cn --arg format "$FORMAT" '{error: ("issues children: unvalidated format " + $format)}' >&2
        return 1
        ;;
    esac
    if [ "$FORMAT" = ids ]; then
        jq -r '.[].id' <<<"$rows"
    else
        jq '.' <<<"$rows"
    fi
}

list_relations() {
    local issue_id=""
    FORMAT="${DEFAULT_FORMAT}"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --format)
            FORMAT="$2"
            shift 2
            ;;
        --format=*)
            FORMAT="${1#--format=}"
            shift
            ;;
        *)
            issue_id="$1"
            shift
            ;;
        esac
    done

    if [ -z "$issue_id" ]; then
        echo '{"error": "Issue ID required"}' >&2
        return 1
    fi

    linear_require_format "$FORMAT" safe raw || return 1

    local query='
    query GetRelations($id: String!) {
        issue(id: $id) {
            id
            identifier
            title
'"$ISSUE_RELATION_FIELDS"'
        }
    }'

    local variables
    variables=$(jq -cn --arg id "$issue_id" '{id: $id}') || return 1
    local result
    result=$(graphql_query "$query" "$variables") || return 1

    # Apply output format
    case "$FORMAT" in
    raw)
        linear_public_result "$result"
        ;;
    safe)
        format_relations_list "$result"
        ;;
    esac
}

add_relation() {
    local issue_ref="$1"
    shift

    local blocks=""
    local blocked_by=""
    local related=""
    local duplicate=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --blocks)
            blocks="$2"
            shift 2
            ;;
        --blocked-by)
            blocked_by="$2"
            shift 2
            ;;
        --related)
            related="$2"
            shift 2
            ;;
        --duplicate)
            duplicate="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2
            return 1
            ;;
        *) break ;;
        esac
    done

    # Resolve the main issue ID
    local issue_id
    issue_id=$(resolve_issue_id "$issue_ref")
    if [ -z "$issue_id" ]; then
        echo "{\"error\": \"Issue not found: $issue_ref\"}" >&2
        return 1
    fi

    local relation_type=""
    local related_issue_uuid=""
    local other_ref=""

    if [ -n "$blocks" ]; then
        # This issue blocks another: create relation type "blocks" with this as issueId
        relation_type="blocks"
        other_ref="$blocks"
    elif [ -n "$blocked_by" ]; then
        # This issue is blocked by another: create relation type "blocks" with other as issueId
        # Swap: the blocker is the issueId, this issue is relatedIssueId
        relation_type="blocks"
        other_ref="$blocked_by"
        # Will swap after resolving
    elif [ -n "$related" ]; then
        relation_type="related"
        other_ref="$related"
    elif [ -n "$duplicate" ]; then
        relation_type="duplicate"
        other_ref="$duplicate"
    else
        echo '{"error": "Required: --blocks, --blocked-by, --related, or --duplicate"}' >&2
        return 1
    fi

    # Resolve the other issue ID
    related_issue_uuid=$(resolve_issue_id "$other_ref")
    if [ -z "$related_issue_uuid" ]; then
        echo "{\"error\": \"Issue not found: $other_ref\"}" >&2
        return 1
    fi

    # For blocked-by, swap the IDs (blocker becomes issueId)
    if [ -n "$blocked_by" ]; then
        local temp="$issue_id"
        issue_id="$related_issue_uuid"
        related_issue_uuid="$temp"
    fi

    # issue-validation.sh owns the blocking-level rule and the query facts.
    if [ "$relation_type" = "blocks" ]; then
        local validation_query="
        query ValidateBlocking(\$id1: String!, \$id2: String!) {
            issue1: issue(id: \$id1) { id $BLOCKING_PARENT_FIELDS }
            issue2: issue(id: \$id2) { id $BLOCKING_PARENT_FIELDS $BLOCKING_CHILD_FIELDS }
        }"
        local validation_result
        validation_result=$(graphql_query "$validation_query" "{\"id1\": \"$issue_id\", \"id2\": \"$related_issue_uuid\"}") || return 1

        local facts nodes
        nodes=$(jq -c '{blocker: .issue1, blocked: .issue2}' <<<"$validation_result") || return 1
        facts=$(blocking_level_facts "$nodes") || return 1
        if ! blocking_level_ok "$facts"; then
            local violation_message
            violation_message=$(blocking_level_violation_message "$facts") || return 1
            printf '%s\n' "$violation_message" >&2
            return 1
        fi
    fi

    local mutation='
    mutation CreateRelation($input: IssueRelationCreateInput!) {
        issueRelationCreate(input: $input) {
            success
            issueRelation {
                id
                type
                issue { identifier title }
                relatedIssue { identifier title }
            }
        }
    }'

    local input="{\"issueId\": \"$issue_id\", \"relatedIssueId\": \"$related_issue_uuid\", \"type\": \"$relation_type\"}"
    local result
    local query_rc=0
    result=$(graphql_query "$mutation" "{\"input\": $input}") || query_rc=$?
    # Linear already holding this relation is idempotent success, not a
    # rejection — graphql_query reports it as already_exists.
    if [ "$(echo "$result" | jq -r '.already_exists // false' 2>/dev/null)" = "true" ]; then
        echo '{"success": true, "already_exists": true}'
        return 0
    fi
    # A payload-level rejection must fail here. Printing the normalized
    # {success: false} object and returning 0 let callers — block_issue among
    # them — report a blocked issue that carries no blocking relation.
    if [ "$(echo "$result" | jq -r '.issueRelationCreate.success // false' 2>/dev/null)" != "true" ]; then
        # Every graphql_query failure path reports on stderr and leaves stdout
        # empty. Piping that into jq would emit a parse error and no rejection
        # message at all, so the two causes are reported separately.
        local payload
        payload=$(echo "$result" | jq -c '.issueRelationCreate // {}' 2>/dev/null) || payload=""
        if [ -z "$result" ] || [ -z "$payload" ]; then
            jq -cn --arg type "$relation_type" --argjson rc "$query_rc" --arg raw "$result" \
                '{error: ("issueRelationCreate returned no usable response (graphql_query exit " + ($rc | tostring) + ") - no " + $type + " relation was created; see the preceding error"), raw: $raw}' >&2
            return 1
        fi
        jq -cn --argjson data "$payload" \
            '{error: "issueRelationCreate was rejected (success != true) - no relation was created", data: $data}' >&2
        return 1
    fi
    local normalized
    normalized=$(normalize_mutation_response "$result" "issueRelationCreate" "issueRelation")
    echo "$normalized"
}

# A Done or Canceled blocker's relation is history, ../../SKILL.md § Blocked Label vs Issue Relations
# says; $2 = true is tpm-audit's structural repair, for a pair the rule refuses.
refuse_completed_blocker() {
    local relation blocker facts nodes
    relation=$(graphql_query "query RelationBlocker(\$id: String!) { issueRelation(id: \$id) { type issue { state { name type } $BLOCKING_PARENT_FIELDS } relatedIssue { $BLOCKING_PARENT_FIELDS $BLOCKING_CHILD_FIELDS } } }" \
        "$(jq -cn --arg id "$1" '{id: $id}')") || return 1
    blocker=$(jq -r "$ISSUE_RELATION_JQ"'.issueRelation | select(.type == "blocks" and (.issue | issue_is_open | not)) | "blocker=\(.issue.identifier) state=\(.issue.state.name)"' <<<"$relation") || return 1
    [ -n "$blocker" ] || return 0
    nodes=$(jq -c '.issueRelation | {blocker: .issue, blocked: .relatedIssue}' <<<"$relation") || return 1
    facts=$(blocking_level_facts "$nodes") || return 1
    if [ "$2" = "true" ] && ! blocking_level_ok "$facts"; then return 0; fi
    echo "linear: refused=completed-blocker $blocker section=\"linear SKILL.md § Blocked Label vs Issue Relations\"" >&2
    return 1
}

remove_relation() {
    local first_arg="$1"
    shift || true

    # Check if first arg is a UUID (direct relation ID) or issue reference
    if [[ "$first_arg" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        # Direct UUID: delete by relation ID
        local relation_id="$first_arg"
        refuse_completed_blocker "$relation_id" "$([ "${1:-}" != --peer-rule-violation ] || echo true)" || return 1
        local mutation='
        mutation DeleteRelation($id: String!) {
            issueRelationDelete(id: $id) {
                success
            }
        }'
        local result
        result=$(graphql_query "$mutation" "{\"id\": \"$relation_id\"}")
        normalize_mutation_response "$result" "issueRelationDelete" "issueRelation"
        return
    fi

    # Issue reference with flags: find and delete the matching relation
    local issue_ref="$first_arg"
    local blocks=""
    local blocked_by=""
    local related=""
    local duplicate=""
    local peer_rule_violation=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --peer-rule-violation)
            peer_rule_violation="true"
            shift
            ;;
        --blocks)
            blocks="$2"
            shift 2
            ;;
        --blocked-by)
            blocked_by="$2"
            shift 2
            ;;
        --related)
            related="$2"
            shift 2
            ;;
        --duplicate)
            duplicate="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2
            return 1
            ;;
        *) break ;;
        esac
    done

    # Resolve the main issue ID
    local issue_id
    issue_id=$(resolve_issue_id "$issue_ref")
    if [ -z "$issue_id" ]; then
        echo "{\"error\": \"Issue not found: $issue_ref\"}" >&2
        return 1
    fi

    local relation_type=""
    local other_ref=""
    local search_inverse="false"

    if [ -n "$blocks" ]; then
        relation_type="blocks"
        other_ref="$blocks"
    elif [ -n "$blocked_by" ]; then
        relation_type="blocks"
        other_ref="$blocked_by"
        search_inverse="true" # Look in inverseRelations
    elif [ -n "$related" ]; then
        relation_type="related"
        other_ref="$related"
    elif [ -n "$duplicate" ]; then
        relation_type="duplicate"
        other_ref="$duplicate"
    else
        echo '{"error": "Required: UUID or --blocks, --blocked-by, --related, or --duplicate"}' >&2
        return 1
    fi

    # Resolve the other issue identifier
    local other_identifier
    other_identifier=$(echo "$other_ref" | tr '[:lower:]' '[:upper:]')

    # Query relations to find the matching one
    local query='
    query GetRelations($id: String!) {
        issue(id: $id) {
            id
'"$ISSUE_RELATION_FIELDS"'
        }
    }'
    local result
    result=$(graphql_query "$query" "{\"id\": \"$issue_id\"}") || return 1

    # Find the relation ID
    local relation_id=""
    if [ "$search_inverse" = "true" ]; then
        # Search in inverseRelations (other issue blocks this one)
        relation_id=$(echo "$result" | jq -r --arg type "$relation_type" --arg other "$other_identifier" '
            .issue.inverseRelations.nodes[] | select(.type == $type and .issue.identifier == $other) | .id' | head -n1)
    else
        # Search in relations (this issue blocks/relates to other)
        relation_id=$(echo "$result" | jq -r --arg type "$relation_type" --arg other "$other_identifier" '
            .issue.relations.nodes[] | select(.type == $type and .relatedIssue.identifier == $other) | .id' | head -n1)
    fi

    if [ -z "$relation_id" ] || [ "$relation_id" = "null" ]; then
        echo "{\"error\": \"Relation not found: $issue_ref ${relation_type} $other_ref\"}" >&2
        return 1
    fi

    refuse_completed_blocker "$relation_id" "$peer_rule_violation" || return 1
    # Delete the relation
    local mutation='
    mutation DeleteRelation($id: String!) {
        issueRelationDelete(id: $id) {
            success
        }
    }'
    result=$(graphql_query "$mutation" "{\"id\": \"$relation_id\"}")
    normalize_mutation_response "$result" "issueRelationDelete" "issueRelation"
}

# =============================================================================
# COMPOSITE ACTIONS - Workflow shortcuts combining multiple operations
# =============================================================================

# Activate an issue: set state to "In Progress"
# Usage: activate_issue CC-XXX [--agent <name>]
# --agent applies the exclusive agent:<name> issue label in the same
# issueUpdate mutation as the state change. The label is validated before any
# mutation, so an unknown agent fails without touching issue state.
#
# KENDEX_USER_EMAIL, the person operating this checkout, becomes the assignee
# of an issue nobody is assigned, in that same mutation. Every outcome lets the
# activation proceed; a failed issue read, users lookup or update fails it and
# reports no outcome. Each outcome is one keyed line on stderr after the
# mutation lands, with the JSON "assignee" field beside it:
#   assignee-set assignee=NAME                    "set"
#   assignee-kept assignee=NAME                   "kept"     (never replaced)
#   assignee-skipped cause=unset                  "skipped"
#   assignee-skipped cause=unknown-email email=E  "skipped"
activate_issue() {
    local issue_id="$1"
    shift

    local agent=""
    local output_format=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --format)
            linear_require_option_value "$@" || return 1
            output_format="$2"
            linear_require_format "$output_format" ids || return 1
            shift 2
            ;;
        --format=*)
            output_format="${1#*=}"
            linear_require_format "$output_format" ids || return 1
            shift
            ;;
        --agent)
            if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                agent="$2"
                shift 2
            else
                echo "{\"error\": \"--agent requires a value (e.g., --agent iced)\"}" >&2
                return 1
            fi
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2
            return 1
            ;;
        *) break ;;
        esac
    done

    linear_guard_issue_team activate "$issue_id" || return 1

    local agent_label=""
    if [ -n "$agent" ]; then
        agent_label="agent:$agent"
    fi

    local user_email="${KENDEX_USER_EMAIL:-}"
    local issue_result=""
    if [ -n "$agent" ] || [ -n "$user_email" ]; then
        # The label set and the assignee are both read off this answer, so a
        # failed read stops here: past it, an empty answer drops the one and
        # reports the other as kept.
        issue_result=$(get_issue "$issue_id" --format=raw) || return 1
    fi

    local update_args=(--state "In Progress")
    if [ -n "$agent" ]; then
        # Agent labels are exclusive: replace any existing agent:* label and
        # preserve all other labels (--labels replaces the full set).
        local final_labels
        final_labels=$(echo "$issue_result" | jq -r --arg agent_label "$agent_label" \
            '[.issue.labels.nodes[].name | select(startswith("agent:") | not)] + [$agent_label] | join(",")')
        update_args+=(--labels "$final_labels")
    fi

    local assignee_state assignee_line current_assignee=null
    if [ -n "$user_email" ]; then
        current_assignee=$(jq -c '.issue.assignee' <<<"$issue_result") || return 1
    fi
    if [ -z "$user_email" ]; then
        assignee_state="skipped"
        assignee_line="assignee-skipped cause=unset"
    elif [ "$current_assignee" != "null" ]; then
        assignee_state="kept"
        assignee_line="assignee-kept assignee=$(jq -r '.name // ""' <<<"$current_assignee")"
    else
        local user
        user=$(find_user_by_email "$user_email") || return 1
        if [ -z "$user" ]; then
            assignee_state="skipped"
            assignee_line="assignee-skipped cause=unknown-email email=$user_email"
        else
            local user_id
            user_id=$(jq -r '.id' <<<"$user") || return 1
            assignee_state="set"
            assignee_line="assignee-set assignee=$(jq -r '.name' <<<"$user")"
            # The id, not the address: the update then sends it without a
            # second lookup of the same person.
            update_args+=(--assignee "$user_id")
        fi
    fi

    # One mutation carries the state, the label set and the assignee.
    local update_result
    update_result=$(update_issue "$issue_id" "${update_args[@]}")
    local update_success
    update_success=$(echo "$update_result" | jq -r '.success // false')

    if [ "$update_success" != "true" ]; then
        echo "$update_result"
        return 1
    fi

    printf '%s\n' "$assignee_line" >&2
    if [ "$output_format" = "ids" ]; then
        echo "$update_result" | jq -r '.identifier // empty'
        return 0
    fi
    local identifier
    identifier=$(echo "$update_result" | jq -r '.identifier // empty')
    jq -cn --arg identifier "$identifier" --arg agent "$agent" --arg assignee "$assignee_state" \
        '{success: true, identifier: $identifier, action: "activated"}
        + (if $agent == "" then {} else {agent: $agent} end)
        + {assignee: $assignee}'
}

# Block an issue: add blocked label, create blocked-by relation, post comment
# Usage: block_issue CC-XXX --by CC-YYY [--reason "text"]
block_issue() {
    local issue_id="$1"
    shift

    local blocker=""
    local reason=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --by)
            blocker="$2"
            shift 2
            ;;
        --reason)
            reason="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2
            return 1
            ;;
        *) break ;;
        esac
    done

    if [ -z "$blocker" ]; then
        echo '{"error": "Required: --by <blocker-issue>"}' >&2
        return 1
    fi
    linear_guard_issue_team block "$issue_id" || return 1

    # Get current labels and add "blocked"
    local issue_result
    issue_result=$(get_issue "$issue_id" --format=raw)
    local current_labels
    current_labels=$(echo "$issue_result" | jq -r '[.issue.labels.nodes[].name] | join(",")')

    # Exact membership: a substring test skipped the label whenever the issue
    # already carried an unrelated name containing it (`unblocked`,
    # `blocked-by-design`), and `block` then reported success having applied none.
    local has_blocked_label="false" existing_label
    IFS=',' read -ra _existing_labels <<<"$current_labels"
    for existing_label in ${_existing_labels[@]+"${_existing_labels[@]}"}; do
        [ "$existing_label" = "blocked" ] && has_blocked_label="true"
    done
    if [ "$has_blocked_label" != "true" ]; then
        if [ -n "$current_labels" ]; then
            current_labels="${current_labels},blocked"
        else
            current_labels="blocked"
        fi
    fi

    # Update labels
    local update_result
    update_result=$(update_issue "$issue_id" --labels "$current_labels")
    local update_success
    update_success=$(echo "$update_result" | jq -r '.success // false')

    if [ "$update_success" != "true" ]; then
        echo "$update_result"
        return 1
    fi

    # Add blocked-by relation. The label and comment are cosmetic; this is the
    # relation that actually blocks, so its rejection cannot be reported as a
    # successful block.
    local relation_result
    if ! relation_result=$(add_relation "$issue_id" --blocked-by "$blocker"); then
        jq -cn --arg id "$issue_id" --arg blocker "$blocker" \
            '{error: ("Blocking relation could not be created between " + $id + " and " + $blocker + " - the blocked label was applied but the issue is NOT blocked")}' >&2
        return 1
    fi
    if [ "$(echo "$relation_result" | jq -r '.success // .already_exists // false')" != "true" ]; then
        echo "$relation_result" | jq -c '{error: "Blocking relation was rejected - the blocked label was applied but the issue is NOT blocked", data: .}' >&2
        return 1
    fi

    # Post blocking comment
    local comment_body="BLOCKED: Waiting for $blocker."
    [ -n "$reason" ] && comment_body="BLOCKED: Waiting for $blocker. $reason"

    local comment_mutation='
    mutation CreateComment($input: CommentCreateInput!) {
        commentCreate(input: $input) {
            success
            comment { id }
        }
    }'

    local escaped_body
    escaped_body=$(echo "$comment_body" | jq -Rs '.')
    local comment_input="{\"issueId\": \"$issue_id\", \"body\": $escaped_body}"

    # Comment is secondary - don't fail the whole operation if it fails
    set +e
    graphql_query "$comment_mutation" "{\"input\": $comment_input}" >/dev/null 2>&1
    set -e

    # Return combined result
    local identifier
    identifier=$(echo "$update_result" | jq -r '.identifier // empty')
    echo "{\"success\": true, \"identifier\": \"$identifier\", \"action\": \"blocked\", \"blocked_by\": \"$blocker\"}"
}

# Unblock an issue: remove blocked label, post comment
# Usage: unblock_issue CC-XXX
unblock_issue() {
    local issue_id="$1"
    linear_guard_issue_team unblock "$issue_id" || return 1

    # Get current labels and remove "blocked"
    local issue_result
    issue_result=$(get_issue "$issue_id" --format=raw)
    local current_labels
    current_labels=$(echo "$issue_result" | jq -r '[.issue.labels.nodes[].name | select(. != "blocked")] | join(",")')

    # Update labels (removing blocked)
    local update_result
    if [ -n "$current_labels" ]; then
        update_result=$(update_issue "$issue_id" --labels "$current_labels")
    else
        # `blocked` was the only label: ask for the set to be emptied outright.
        update_result=$(update_issue "$issue_id" --clear-labels)
    fi

    local update_success
    update_success=$(echo "$update_result" | jq -r '.success // false')

    if [ "$update_success" != "true" ]; then
        echo "$update_result"
        return 1
    fi

    # Post unblocked comment
    local comment_body="Unblocked. Resuming work."

    local comment_mutation='
    mutation CreateComment($input: CommentCreateInput!) {
        commentCreate(input: $input) {
            success
            comment { id }
        }
    }'

    local escaped_body
    escaped_body=$(echo "$comment_body" | jq -Rs '.')
    local comment_input="{\"issueId\": \"$issue_id\", \"body\": $escaped_body}"

    # Comment is secondary - don't fail the whole operation if it fails
    set +e
    graphql_query "$comment_mutation" "{\"input\": $comment_input}" >/dev/null 2>&1
    set -e

    # Return combined result
    local identifier
    identifier=$(echo "$update_result" | jq -r '.identifier // empty')
    echo "{\"success\": true, \"identifier\": \"$identifier\", \"action\": \"unblocked\"}"
}

# Required effects after Done stay retryable through the same completion verb.
# The filing cannot decide the disposition of children added before completion.
complete_superseded_issues() {
    local replacement="$1"
    shift
    local superseded_id superseded_result superseded_terminal disposition_result pending_children
    local frontier next_frontier child_parent children descendants seen
    for superseded_id in "$@"; do
        if ! superseded_result=$(get_issue "$superseded_id" --format=raw); then
            jq -cn --arg issue "$superseded_id" '{error: "supersession-read", issue: $issue}' >&2
            return 1
        fi
        superseded_terminal=$(jq -er '.issue.state.type | strings' <<<"$superseded_result") || return 1
        case "$superseded_terminal" in completed|canceled) continue ;; esac
        linear_guard_issue_team complete "$superseded_id" || return 1
        # Terminal ancestors can still contain open work. Keep every unfiltered
        # frontier until the whole subtree is read, as dependencies.md requires.
        frontier="$superseded_id"
        descendants='[]'
        seen=$(jq -c '[.issue.identifier]' <<<"$superseded_result") || return 1
        while [ -n "$frontier" ]; do
            next_frontier=""
            while IFS= read -r child_parent; do
                children=$(list_children "$child_parent" --format=raw) || return 1
                children=$(jq -c --argjson seen "$seen" \
                    '.issue.children.nodes | map({id: .identifier, state_type: .state.type})
                    | unique_by(.id) | map(select(.id as $id | $seen | index($id) | not))' <<<"$children") || return 1
                descendants=$(jq -c --argjson children "$children" '. + $children' <<<"$descendants") || return 1
                seen=$(jq -c --argjson children "$children" '. + ($children | map(.id))' <<<"$seen") || return 1
                children=$(jq -r '.[].id' <<<"$children") || return 1
                if [ -n "$children" ]; then
                    next_frontier="${next_frontier:+$next_frontier$'\n'}$children"
                fi
            done <<<"$frontier"
            frontier="$next_frontier"
        done
        pending_children=$(jq -r '.[] | select(.state_type != "completed" and .state_type != "canceled") | .id' <<<"$descendants") || return 1
        if [ -n "$pending_children" ]; then
            jq -cn --arg issue "$superseded_id" --arg children "$pending_children" \
                '{error: "supersession-children", issue: $issue, children: ($children | split("\n")), remedy: "Disposition the open children before retrying completion."}' >&2
            return 1
        fi
        disposition_result=$("$SCRIPT_DIR/comments.sh" create "$superseded_id" --body "Superseded by $replacement.") || return 1
        if ! jq -e '.success == true' <<<"$disposition_result" >/dev/null; then
            jq -cn --arg issue "$superseded_id" '{error: "supersession-comment", issue: $issue}' >&2
            return 1
        fi
        disposition_result=$(update_issue "$superseded_id" --state Canceled) || return 1
        if ! jq -e '.success == true' <<<"$disposition_result" >/dev/null; then
            jq -cn --arg issue "$superseded_id" '{error: "supersession-cancel", issue: $issue}' >&2
            return 1
        fi
    done
}

# Complete an issue from its checklist and recorded evidence.
# Usage: complete_issue CC-XXX [--summary <text> | --summary-file <path>] [--done-when-met <all|N[,N...]>]
# The summary comment is posted BEFORE the state transition so a failed post
# never yields a Done issue without a completion summary. Unknown or trailing
# arguments, and a Done-when box number the description does not hold, are
# rejected before any mutation; orch's merge-pr completion step numbers the
# boxes it passes from the description it read. Ticked boxes ride the
# issueUpdate that sets Done, from a description read just before the comment
# post: an edit landing between that read and the update is overwritten.
complete_issue() {
    local issue_id="$1"
    shift

    local usage="issues.sh complete <issue-id> [--summary <text> | --summary-file <path>] [--done-when-met <all|N[,N...]> --evidence-file <path>] [--post-merge-at <UTC>]"
    local summary=""
    local summary_file=""
    local done_when_met=""
    local post_merge_at=""
    local evidence_file=""
    local output_format=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --format)
            linear_require_option_value "$@" || return 1
            output_format="$2"
            linear_require_format "$output_format" ids || return 1
            shift 2
            ;;
        --format=*)
            output_format="${1#*=}"
            linear_require_format "$output_format" ids || return 1
            shift
            ;;
        --evidence-file)
            linear_require_option_value "$@" || return 1
            evidence_file="$2"
            shift 2
            ;;
        --evidence-file=*)
            evidence_file="${1#*=}"
            [ -n "$evidence_file" ] || return 1
            shift
            ;;
        --post-merge-at)
            linear_require_option_value "$@" || return 1
            post_merge_at="$2"
            shift 2
            ;;
        --post-merge-at=*)
            post_merge_at="${1#*=}"
            [ -n "$post_merge_at" ] || return 1
            shift
            ;;
        --done-when-met)
            if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                done_when_met="$2"
                shift 2
            else
                echo '{"error": "--done-when-met requires all or a box number list"}' >&2
                return 1
            fi
            ;;
        --done-when-met=*)
            done_when_met="${1#*=}"
            if [ -z "$done_when_met" ]; then
                echo '{"error": "--done-when-met requires all or a box number list"}' >&2
                return 1
            fi
            shift
            ;;
        --summary)
            if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                summary="$2"
                shift 2
            else
                echo '{"error": "--summary requires a text value"}' >&2
                return 1
            fi
            ;;
        --summary=*)
            summary="${1#*=}"
            if [ -z "$summary" ]; then
                echo '{"error": "--summary requires a text value"}' >&2
                return 1
            fi
            shift
            ;;
        --summary-file)
            if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                summary_file="$2"
                shift 2
            else
                echo '{"error": "--summary-file requires a path argument"}' >&2
                return 1
            fi
            ;;
        --summary-file=*)
            summary_file="${1#*=}"
            if [ -z "$summary_file" ]; then
                echo '{"error": "--summary-file requires a path argument"}' >&2
                return 1
            fi
            shift
            ;;
        -*)
            jq -cn --arg arg "$1" --arg usage "$usage" '{error: ("Unknown option: " + $arg + ". Usage: " + $usage)}' >&2
            return 1
            ;;
        *)
            jq -cn --arg arg "$1" --arg usage "$usage" '{error: ("Unexpected argument: " + $arg + ". Usage: " + $usage)}' >&2
            return 1
            ;;
        esac
    done

    if [[ -n "$summary" && -n "$summary_file" ]]; then
        echo '{"error": "--summary and --summary-file are mutually exclusive"}' >&2
        return 1
    fi
    if [[ -n "$summary_file" ]]; then
        if [[ ! -r "$summary_file" ]]; then
            echo "{\"error\": \"--summary-file path not readable: $summary_file\"}" >&2
            return 1
        fi
        summary=$(<"$summary_file")
        if [ -z "$summary" ]; then
            echo "{\"error\": \"--summary-file is empty: $summary_file\"}" >&2
            return 1
        fi
    fi

    local met_json=""
    if [ "$done_when_met" = "all" ]; then
        met_json='"all"'
    elif [[ "$done_when_met" =~ ^[1-9][0-9]{0,3}(,[1-9][0-9]{0,3})*$ ]]; then
        met_json=$(jq -cn --arg list "$done_when_met" '$list | split(",") | map(tonumber)') || return 1
    elif [ -n "$done_when_met" ]; then
        jq -cn --arg value "$done_when_met" \
            '{error: ("--done-when-met takes all or comma-separated box numbers from 1, got: " + $value)}' >&2
        return 1
    fi
    if [ -n "$post_merge_at" ]; then
        jq -en --arg stamp "$post_merge_at" '
            $stamp | select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
            | fromdateiso8601 | select(todateiso8601 == $stamp)' >/dev/null 2>&1 || {
            jq -cn '{error: "post-merge-timestamp", option: "--post-merge-at"}' >&2
            return 1
        }
    fi
    linear_guard_issue_team complete "$issue_id" || return 1

    local evidence_json='{}'
    if [ -n "$evidence_file" ]; then
        if [[ -z "$met_json" || ! -r "$evidence_file" ]]; then
            jq -cn '{error: "done-when-evidence-file"}' >&2
            return 1
        fi
        evidence_json=$(jq -Rsn '
            reduce (inputs | gsub("\r\n"; "\n") | split("\n")[] | select(length > 0)) as $line ({};
                (($line | capture("^(?<box>[1-9][0-9]*):[ \t]*(?<text>\\S.*)$")) // error("done-when-evidence-file")) as $proof
                | if has($proof.box) then error("done-when-evidence-file")
                  else .[$proof.box] = $proof.text end)' <"$evidence_file" 2>/dev/null) || {
            jq -cn '{error: "done-when-evidence-file"}' >&2
            return 1
        }
    fi
    local completion_state
    local update_args=()
    local done_when_checked=""
    local issue_result description tick missing_count
    issue_result=$(get_issue "$issue_id" --format=raw) || return 1
    # The sentinel keeps a trailing newline the substitution would strip.
    description=$(jq -r '(.issue.description // "") + "."' <<<"$issue_result") || return 1
    tick=$(done_when_parse "${description%.}" "${met_json:-[]}" "$post_merge_at" "$evidence_json") || return 1
    missing_count=$(jq '.missing | length' <<<"$tick") || return 1
    if [ "$missing_count" -ne 0 ]; then
        jq -c --arg id "$issue_id" \
            '{error: ("Done-when box not found in " + $id + ": " + (.missing | map(tostring) | join(",")) + ". Issue state unchanged."), missing}' <<<"$tick" >&2
        return 1
    fi
    completion_state=$(jq -r '.completion_state // ""' <<<"$tick") || return 1
    if [ -z "$completion_state" ]; then
        jq -c '{error: "post-merge-checklist", errors, unmet_branch_boxes, missing_evidence_boxes}' <<<"$tick" >&2
        return 1
    fi
    # Checklist proof does not establish a merge. Keep the development phase
    # until the existing post-merge route supplies its merge timestamp.
    if [[ "$completion_state" == Verifying && -z "$post_merge_at" ]]; then
        completion_state=$(jq -er '.issue.state | select(.type == "started") | .name | strings | select(length > 0)' <<<"$issue_result") || {
            jq -cn --arg id "$issue_id" '{error: "completion-phase", id: $id, fix: "issues complete --post-merge-at"}' >&2
            return 1
        }
    fi
    local superseded_ids=()
    local supersedes_block=0 supersedes_line
    local supersedes_entry='^- ([A-Z][A-Z0-9]*-[1-9][0-9]*) \(at-completion\):[[:blank:]]+[^[:blank:]].*$'
    while IFS= read -r supersedes_line || [ -n "$supersedes_line" ]; do
        supersedes_line=${supersedes_line%$'\r'}
        if [ "$supersedes_line" = '**Supersedes**:' ]; then
            supersedes_block=1
        elif [ "$supersedes_block" -gt 0 ]; then
            if [ -z "$supersedes_line" ]; then
                [ "$supersedes_block" -ne 2 ] || supersedes_block=0
            elif [[ "$supersedes_line" =~ ^# || "$supersedes_line" =~ ^\*\* ]]; then
                supersedes_block=0
            elif [[ "$supersedes_line" =~ $supersedes_entry ]]; then
                superseded_ids+=("${BASH_REMATCH[1]}")
                supersedes_block=2
            else
                jq -cn --arg issue "$issue_id" --arg line "$supersedes_line" \
                    '{warning: "supersedes-malformed", issue: $issue, line: $line}' >&2
                supersedes_block=2
            fi
        fi
    done <<<"${description%.}"
    if [ -n "$met_json" ]; then
        done_when_checked=$(jq '.ticked' <<<"$tick") || return 1
    fi
    if jq -e '.changed' <<<"$tick" >/dev/null; then
        local ticked_description
        ticked_description=$(jq -r '.description + "."' <<<"$tick") || return 1
        update_args+=(--description "${ticked_description%.}")
    fi

    update_args+=(--state "$completion_state")

    if [ -n "$summary" ]; then
        # validate-completion detects the summary by these markers; prefix the
        # canonical heading when the caller's text carries neither.
        if [[ "$summary" != *"Completion Summary"* && "$summary" != *"Bundle Complete"* ]]; then
            summary="## Completion Summary"$'\n\n'"$summary"
        fi

        # Post the comment first: a posting failure must leave state unchanged
        local comment_result=""
        local comment_rc=0
        set +e
        comment_result=$("$SCRIPT_DIR/comments.sh" create "$issue_id" --body "$summary")
        comment_rc=$?
        set -e
        if [ "$comment_rc" -ne 0 ] || [ "$(echo "$comment_result" | jq -r '.success // false')" != "true" ]; then
            echo "{\"error\": \"Completion summary comment failed for $issue_id. Issue state unchanged.\"}" >&2
            return 1
        fi
    fi

    local update_result
    local update_rc=0
    if [ "$completion_state" = Done ] && jq -e '.issue.state.type == "completed"' <<<"$issue_result" >/dev/null && ! jq -e '.changed' <<<"$tick" >/dev/null; then
        update_result=$(jq -c '{success: true, identifier: .issue.identifier, already_done: true}' <<<"$issue_result") || return 1
    else
        set +e
        # Ticks and evidence preserve the filed body's headers: an issue filed
        # before the header-shape bar still completes.
        update_result=$(LINEAR_REQUIRE_REACH='' update_issue "$issue_id" "${update_args[@]}")
        update_rc=$?
        set -e
    fi

    local update_success
    update_success=$(echo "$update_result" | jq -r '.success // false')

    if [ "$update_rc" -ne 0 ] || [ "$update_success" != "true" ]; then
        if [ -n "$summary" ]; then
            # The retry drops only the summary options: the comment is posted,
            # and the Done-when boxes still ride the update that sets Done.
            local retry="'issues.sh complete $issue_id"
            if [ -n "$done_when_met" ]; then
                retry+=" --done-when-met $done_when_met"
            fi
            if [ -n "$evidence_file" ]; then
                retry+=" --evidence-file $evidence_file"
            fi
            if [ -n "$post_merge_at" ]; then
                retry+=" --post-merge-at $post_merge_at"
            fi
            jq -cn --arg retry "$retry'" --arg state "$completion_state" \
                '{error: ("State transition to " + $state + " failed after the summary comment was posted. Rerun " + $retry + " without summary flags to avoid a duplicate comment.")}' >&2
        fi
        if [ -n "$update_result" ]; then
            echo "$update_result"
        fi
        return 1
    fi

    # Only the filing's explicit block grants cancellation authority. Related
    # links are informational, and a Verifying item has not completed yet.
    if [ "$completion_state" = Done ]; then
        local replacement
        replacement=$(jq -er '.issue.identifier' <<<"$issue_result") || return 1
        if ! complete_superseded_issues "$replacement" ${superseded_ids[@]+"${superseded_ids[@]}"}; then
            local retry_options='[]'
            if [ -n "$done_when_met" ]; then
                retry_options=$(jq -c --arg value "$done_when_met" '. + ["--done-when-met", $value]' <<<"$retry_options") || return 1
            fi
            if [ -n "$evidence_file" ]; then
                retry_options=$(jq -c --arg value "$evidence_file" '. + ["--evidence-file", $value]' <<<"$retry_options") || return 1
            fi
            if [ -n "$post_merge_at" ]; then
                retry_options=$(jq -c --arg value "$post_merge_at" '. + ["--post-merge-at", $value]' <<<"$retry_options") || return 1
            fi
            printf '%s\n' "$update_result"
            jq -cn --arg issue "$replacement" --argjson options "$retry_options" \
                '{error: "supersession-incomplete", issue: $issue, state: "Done", already_done: true,
                  retry: {resource: "issues", action: "complete", issue: $issue, options: $options}}' >&2
            return 1
        fi
    fi

    if [ "$output_format" = "ids" ]; then
        echo "$update_result" | jq -r '.identifier // empty'
        return 0
    fi
    local identifier
    identifier=$(echo "$update_result" | jq -r '.identifier // empty')
    jq -cn --arg identifier "$identifier" --arg summary "$summary" --arg checked "$done_when_checked" --arg state "$completion_state" \
        '{success: true, identifier: $identifier, action: "completed", state: $state}
         + (if $summary != "" then {summary_posted: true} else {} end)
         + (if $checked != "" then {done_when_checked: ($checked | tonumber)} else {} end)'
}

# Validate issue completion: check state is "In Progress" and has Completion Summary comment
# Usage: validate_completion CC-XXX [CC-YYY ...]
#        validate_completion CC-XXX --include-children-of CC-XXX
#        validate_completion CC-XXX --include-children-of CC-XXX --container
# Supports multiple issues for bundle validation. With --container the
# positional targets are container parents (each child is its own PR unit and
# the container closes LAST): any live state passes, canceled fails closed,
# and no pre-posted summary is required.
validate_completion() {
    local issue_ids=()
    # Roles parallel issue_ids: positional targets are managed session roots
    # (container parents under --container); bundle-expanded children (below)
    # are bundle sub-issues.
    local roles=()
    local include_children_of=""
    local container_mode="false"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --include-children-of)
            include_children_of="$2"
            shift 2
            ;;
        --include-children-of=*)
            include_children_of="${1#--include-children-of=}"
            shift
            ;;
        --container)
            container_mode="true"
            shift
            ;;
        *)
            issue_ids+=("$1")
            roles+=("session-root")
            shift
            ;;
        esac
    done

    if [ ${#issue_ids[@]} -eq 0 ]; then
        echo '{"error": "At least one issue ID required"}' >&2
        return 1
    fi

    # --container reports the facts a container's close reads, so it fails
    # CLOSED on any invocation that cannot read them: exactly one positional target,
    # a paired --include-children-of naming that same target, and (checked
    # after expansion below) at least one child. The flag may appear after
    # the positionals, so the role is assigned post-parse.
    if [ "$container_mode" = "true" ]; then
        if [ ${#issue_ids[@]} -ne 1 ]; then
            echo '{"error": "--container requires exactly one issue ID"}' >&2
            return 1
        fi
        if [ -z "$include_children_of" ] || [ "$include_children_of" != "${issue_ids[0]}" ]; then
            echo "{\"error\": \"--container requires --include-children-of naming the same issue (got target '${issue_ids[0]}', expansion '${include_children_of:-none}')\"}" >&2
            return 1
        fi
        roles[0]="container"
    fi

    # If --include-children-of specified, fetch the bundle and expand its
    # Completed children must remain in the validation set. An in-PR bundle
    # child can also carry verified branch work into post-merge verification.
    # Only CANCELED children are excluded: abandoned work can never be "Done",
    # is not a pending gap, and including it would permanently fail any bundle
    # that legitimately canceled a sub-issue. This mirrors the `children
    # --pending` filter, which likewise treats completed vs canceled distinctly
    # from still-pending work.
    if [ -n "$include_children_of" ]; then
        local bundle
        if ! bundle=$(get_issue "$include_children_of" --with-bundle --format=safe); then
            echo "{\"error\": \"Failed to fetch bundle for: $include_children_of\"}" >&2
            return 1
        fi
        if [ -z "$bundle" ]; then
            echo "{\"error\": \"Failed to fetch bundle for: $include_children_of\"}" >&2
            return 1
        fi
        # Container fail-closed, part 1b: the review audit's in-PR bundle
        # root is one work item, the OPPOSITE contract — validating it under
        # the permissive container role would skip the session root's
        # pre-merge state and summary checks. Reject it instead of silently
        # reclassifying.
        if [ "$container_mode" = "true" ] && [ "$(jq -r '.in_pr_bundle == true' <<<"$bundle")" = true ]; then
            echo "{\"error\": \"--container fail-closed: $include_children_of is an in-PR bundle root (in_pr_bundle) — it validates with plain validate-completion, never as a container\"}" >&2
            return 1
        fi
        # Container fail-closed, part 2: a bundle with no child at all proves
        # nothing about its children — a leaf mistakenly validated as a
        # container must error, not pass. Every child canceled leaves the
        # parent's row alone, so container-close reads its open boxes before
        # it sets the parent Canceled.
        if [ "$container_mode" = "true" ] && [ "$(jq -r '.children | length' <<<"$bundle")" = 0 ]; then
            echo "{\"error\": \"--container fail-closed: no children found under $include_children_of\"}" >&2
            return 1
        fi
        local child_ids
        child_ids=$(echo "$bundle" | jq -r '[.children[] | select(.state_type != "canceled") | .id] | .[]' 2>/dev/null)
        for child_id in $child_ids; do
            issue_ids+=("$child_id")
            if [ "$container_mode" = true ]; then
                roles+=("container-child")
            else
                roles+=("bundle-child")
            fi
        done
    fi

    local results="[]"
    local all_ok="true"

    local i
    for i in "${!issue_ids[@]}"; do
        local issue_id="${issue_ids[$i]}"
        local role="${roles[$i]}"
        # Get issue state
        local issue
        issue=$(get_issue "$issue_id" --format=safe) || return 1
        local state
        state=$(echo "$issue" | jq -r '.state // ""')
        local state_type
        state_type=$(echo "$issue" | jq -r '.state_type // ""')
        local parent_id
        parent_id=$(echo "$issue" | jq -r '.parent_id // ""')

        # Check for Completion Summary comment
        local comments
        # A failed read is not "no summary": the check fails closed on it.
        comments=$("$BASH" "$SCRIPT_DIR/comments.sh" list "$issue_id") || return 1
        local has_summary
        has_summary=$(echo "$comments" | jq 'any(.[]; .body | test("Completion Summary|Bundle Complete"; "i"))')

        local result description
        description=$(jq -r '(.description // "") + "."' <<<"$issue") || return 1
        result=$(build_completion_validation_result "$issue_id" "$state" "$parent_id" "$has_summary" "$role" "$state_type" "${description%.}") || return 1

        if [ "$(echo "$result" | jq -r '.ok')" != "true" ]; then
            all_ok="false"
        fi

        # Append to results
        results=$(echo "$results" | jq --argjson result "$result" '. + [$result]')
    done

    echo "$results" | jq --argjson all_ok "$all_ok" '{results: ., all_ok: $all_ok}'
}

# `<action> --help` prints usage and exits 0. A MISSING identifier is a caller
# bug, not a help request: printing usage and exiting 0 for it reported success
# for a write that never ran, so an unset shell variable in a caller's
# `issues complete "$ID"` read as a completed issue.
require_issue_ref() {
    local action="$1" first="${2:-}"
    case "$first" in
    --help | -h)
        show_help
        exit 0
        ;;
    esac
    if [ -z "$first" ]; then
        jq -cn --arg action "$action" \
            '{error: ("issues " + $action + " requires an issue identifier (e.g. PROJ-42)")}' >&2
        exit 1
    fi
}

main() {
    # Main routing
    action="${1:-help}"
    shift || true

    case "$action" in
    list)
        list_issues "$@"
        ;;
    get)
        require_issue_ref get "${1:-}"
        get_issue "$@"
        ;;
    bulk-get)
        bulk_get_issues "$@"
        ;;
    bulk-update)
        require_issue_ref bulk-update "${1:-}"
        bulk_update_issues "$@"
        ;;
    create)
        create_issue "$@"
        ;;
    update)
        require_issue_ref update "${1:-}"
        update_issue "$@"
        ;;
    archive)
        require_issue_ref archive "${1:-}"
        archive_issue "$@"
        ;;
    trash | delete)
        require_issue_ref trash "${1:-}"
        trash_issue "$@"
        ;;
    children)
        require_issue_ref children "${1:-}"
        list_children "$@"
        ;;
    list-relations | relations)
        require_issue_ref list-relations "${1:-}"
        list_relations "$@"
        ;;
    add-relation)
        require_issue_ref add-relation "${1:-}"
        add_relation "$@"
        ;;
    remove-relation)
        require_issue_ref remove-relation "${1:-}"
        remove_relation "$@"
        ;;
    # Composite workflow actions
    activate)
        require_issue_ref activate "${1:-}"
        activate_issue "$@"
        ;;
    block)
        require_issue_ref block "${1:-}"
        block_issue "$@"
        ;;
    unblock)
        require_issue_ref unblock "${1:-}"
        unblock_issue "$@"
        ;;
    complete)
        require_issue_ref complete "${1:-}"
        complete_issue "$@"
        ;;
    validate-completion)
        require_issue_ref validate-completion "${1:-}"
        validate_completion "$@"
        ;;
    move)
        echo "Error: 'move' is not an action. To move an issue to a different project:" >&2
        echo "  linear.sh issues update [ISSUE_ID] --project \"Target Project\"" >&2
        exit 1
        ;;
    comment)
        echo "Error: Comments are a separate resource. Use:" >&2
        echo "  linear.sh comments create [ISSUE_ID] --body \"Your comment\"" >&2
        echo "  linear.sh comments list [ISSUE_ID]" >&2
        exit 1
        ;;
    view | show)
        echo "Error: Unknown action '$action' — supported issue lookups:" >&2
        echo "  linear.sh issues get [ISSUE_ID]" >&2
        echo "  linear.sh issues bulk-get [ISSUE_ID_1] [ISSUE_ID_2]   # live state (post-mutation verification)" >&2
        exit 1
        ;;
    *)
        echo "Error: Unknown action '$action'" >&2
        echo "Run 'issues.sh --help' for usage." >&2
        exit 1
        ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
