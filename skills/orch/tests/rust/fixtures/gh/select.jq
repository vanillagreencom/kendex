# GraphQL answers only the fields a query selects (GraphQL specification
# § 6.3): a planted reply's `data` projected onto the selection set of the
# query in $q. The projector is closed: it reads the forms below, the ones
# the runtime's queries and the github package's queries it answers send,
# validates the query against SCHEMA before it reads any plant, and refuses
# every other token, form and selection, so a query edit either projects as
# GraphQL would answer it or reddens the row that reads it.
#
# The forms:
# - one operation, `query` or `mutation`, with an optional name and
#   optional variable definitions, then its selection set; after it, named
#   fragments `fragment NAME on TYPE { ... }`, each spread somewhere;
# - a field `NAME`, `NAME(ARGUMENTS)` or `ALIAS: NAME(ARGUMENTS)`;
# - an inline fragment `... on TYPE { ... }` and a spread `...NAME`, TYPE
#   one of SCHEMA's types;
# - arguments: names, variables, numbers, enum values, lists, input objects
#   and double-quoted strings, read whole and not interpreted.
# A comment, a directive, an empty selection set, a fragment defined twice
# or never spread, a type condition directly inside another, and any other
# character are refused.
#
# The validation (GraphQL specification § 5.3.1, § 5.3.3, § 5.5.2.3), from
# the operation's root type, whatever the plant: a field its type in SCHEMA
# lacks (an interface or union carries only its own fields, a field of one
# of its types is selected under that type's condition), a selection set on
# a scalar or enum, an object with none, and a type condition that can never
# apply at its position (no type is both the position's and the
# condition's) are refused. `__typename` is a field of every type.
#
# The plants: a field is planted under its schema name, never under a
# response alias, and the answer carries the planted value under the
# response key. A field selected on one object with different arguments is
# planted under NAME(ARGUMENTS) as the query writes them, whitespace
# collapsed. A selected field with no plant, an object planted at a scalar
# position, a scalar at an object position and a list at a single position
# are refused, never answered from a neighbour. An object at an abstract
# position is of the type its `__typename` names, else its GitHub node id's
# prefix; a condition at an abstract position applies to an object of one
# of the condition's types, and an untyped object under a condition, or one
# of a type the position cannot hold, is refused.
#
# SCHEMA is GitHub.com's public GraphQL schema, the `fpt` schema GitHub
# publishes at docs.github.com/public/fpt/schema.docs.graphql and documents
# at docs.github.com/en/graphql/reference (the GraphQL API carries no
# version number; its changes are dated in docs.github.com/en/graphql/
# overview/changelog), as it stood in 2026, cut to the types and fields the
# queries the fixture answers select: each type maps its fields to [TYPE,
# LIST], TYPE "S" for a scalar or enum, LIST true where GitHub answers a
# list. POSSIBLE maps each interface and union to its member types, those of
# SCHEMA's types and the actor types.
def SCHEMA: {
  "Query": {"nodes": ["Node", true], "repository": ["Repository", false]},
  "Mutation": {
    "dequeuePullRequest": ["DequeuePullRequestPayload", false],
    "disablePullRequestAutoMerge": ["DisablePullRequestAutoMergePayload", false]
  },
  "DequeuePullRequestPayload": {"mergeQueueEntry": ["MergeQueueEntry", false]},
  "DisablePullRequestAutoMergePayload": {"clientMutationId": ["S", false]},
  "Node": {"id": ["S", false]},
  "Actor": {"login": ["S", false]},
  "PullRequestTimelineItems": {},
  "CheckRun": {
    "id": ["S", false], "checkSuite": ["CheckSuite", false], "name": ["S", false],
    "status": ["S", false], "conclusion": ["S", false], "startedAt": ["S", false],
    "completedAt": ["S", false], "detailsUrl": ["S", false]
  },
  "CheckSuite": {
    "id": ["S", false], "databaseId": ["S", false], "createdAt": ["S", false],
    "workflowRun": ["WorkflowRun", false], "checkRuns": ["CheckRunConnection", false]
  },
  "WorkflowRun": {
    "databaseId": ["S", false], "runAttempt": ["S", false], "event": ["S", false],
    "url": ["S", false], "workflow": ["Workflow", false], "file": ["WorkflowRunFile", false]
  },
  "WorkflowRunFile": {
    "path": ["S", false], "repositoryName": ["S", false],
    "repositoryFileUrl": ["S", false], "viewerCanReadRepository": ["S", false]
  },
  "Workflow": {"name": ["S", false]},
  "Repository": {
    "nameWithOwner": ["S", false], "pullRequest": ["PullRequest", false],
    "vulnerabilityAlerts": ["RepositoryVulnerabilityAlertConnection", false]
  },
  "RepositoryVulnerabilityAlertConnection": {
    "pageInfo": ["PageInfo", false], "nodes": ["RepositoryVulnerabilityAlert", true]
  },
  "RepositoryVulnerabilityAlert": {
    "number": ["S", false], "state": ["S", false], "dependabotUpdate": ["DependabotUpdate", false]
  },
  "DependabotUpdate": {"pullRequest": ["PullRequest", false]},
  "PageInfo": {"hasNextPage": ["S", false], "endCursor": ["S", false]},
  "PullRequest": {
    "id": ["S", false], "number": ["S", false], "state": ["S", false], "body": ["S", false],
    "createdAt": ["S", false], "mergedAt": ["S", false], "headRefName": ["S", false],
    "author": ["Actor", false], "headRepository": ["Repository", false],
    "mergeCommit": ["Commit", false], "mergeQueueEntry": ["MergeQueueEntry", false],
    "autoMergeRequest": ["AutoMergeRequest", false],
    "reviewThreads": ["PullRequestReviewThreadConnection", false],
    "commits": ["PullRequestCommitConnection", false],
    "reviews": ["PullRequestReviewConnection", false],
    "timelineItems": ["PullRequestTimelineItemsConnection", false]
  },
  "MergeQueueEntry": {
    "id": ["S", false], "state": ["S", false], "position": ["S", false],
    "headCommit": ["Commit", false], "mergeQueue": ["MergeQueue", false],
    "pullRequest": ["PullRequest", false]
  },
  "MergeQueue": {"entries": ["MergeQueueEntryConnection", false]},
  "MergeQueueEntryConnection": {"nodes": ["MergeQueueEntry", true]},
  "AutoMergeRequest": {"enabledAt": ["S", false]},
  "PullRequestReviewThreadConnection": {
    "pageInfo": ["PageInfo", false], "nodes": ["PullRequestReviewThread", true]
  },
  "PullRequestReviewThread": {"isResolved": ["S", false]},
  "Commit": {
    "oid": ["S", false], "authoredDate": ["S", false], "committedDate": ["S", false],
    "status": ["Status", false], "checkSuites": ["CheckSuiteConnection", false]
  },
  "Status": {"context": ["StatusContext", false]},
  "StatusContext": {"state": ["S", false], "createdAt": ["S", false]},
  "CheckSuiteConnection": {"pageInfo": ["PageInfo", false], "nodes": ["CheckSuite", true]},
  "CheckRunConnection": {"pageInfo": ["PageInfo", false], "nodes": ["CheckRun", true]},
  "PullRequestCommitConnection": {
    "totalCount": ["S", false], "nodes": ["PullRequestCommit", true]
  },
  "PullRequestCommit": {"commit": ["Commit", false]},
  "PullRequestReviewConnection": {
    "totalCount": ["S", false], "nodes": ["PullRequestReview", true]
  },
  "PullRequestReview": {
    "state": ["S", false], "body": ["S", false], "submittedAt": ["S", false],
    "author": ["Actor", false], "commit": ["Commit", false],
    "comments": ["PullRequestReviewCommentConnection", false]
  },
  "PullRequestReviewCommentConnection": {
    "totalCount": ["S", false], "nodes": ["PullRequestReviewComment", true]
  },
  "PullRequestReviewComment": {
    "id": ["S", false], "replyTo": ["PullRequestReviewComment", false]
  },
  "PullRequestTimelineItemsConnection": {
    "pageInfo": ["PageInfo", false], "nodes": ["PullRequestTimelineItems", true]
  },
  "HeadRefForcePushedEvent": {"createdAt": ["S", false], "beforeCommit": ["Commit", false]},
  "AutoMergeEnabledEvent": {"createdAt": ["S", false]},
  "AutoSquashEnabledEvent": {"createdAt": ["S", false]},
  "AutoRebaseEnabledEvent": {"createdAt": ["S", false]},
  "AddedToMergeQueueEvent": {"createdAt": ["S", false]},
  "ReadyForReviewEvent": {"createdAt": ["S", false]},
  "ReviewDismissedEvent": {
    "previousReviewState": ["S", false], "review": ["PullRequestReview", false]
  }
};
def EVENTS: [
  "HeadRefForcePushedEvent", "AutoMergeEnabledEvent", "AutoSquashEnabledEvent",
  "AutoRebaseEnabledEvent", "AddedToMergeQueueEvent", "ReviewDismissedEvent",
  "ReadyForReviewEvent"
];
def ACTORS: ["Bot", "EnterpriseUserAccount", "Mannequin", "Organization", "User"];
def POSSIBLE: {
  "Node": ([
    "CheckRun", "CheckSuite", "WorkflowRun", "WorkflowRunFile", "Workflow", "Repository",
    "RepositoryVulnerabilityAlert", "PullRequest", "MergeQueueEntry", "MergeQueue",
    "PullRequestReviewThread", "Commit", "Status", "StatusContext", "PullRequestCommit",
    "PullRequestReview", "PullRequestReviewComment"
  ] + EVENTS + ACTORS),
  "Actor": ACTORS,
  "PullRequestTimelineItems": (EVENTS + ["PullRequestCommit", "PullRequestReview", "PullRequestReviewThread"])
};
def NAME: "^[A-Za-z_][A-Za-z0-9_]*$";
def ARGS: "\\((?:[A-Za-z0-9_$:,!\\[\\]{}\\s]|\"[^\"\\\\\\n]*\")*\\)";
def refuse($why): error("gh-fake: unsupported-selection \($why) query=[\($q)]");
def name: type == "string" and test(NAME);
def known($kind): SCHEMA | has($kind);
def possible($kind): POSSIBLE[$kind] // [$kind];
# Every non-blank character falls in a token; a token outside the forms
# refuses.
def tokens:
  [scan(ARGS + "|\\.\\.\\.|[A-Za-z_][A-Za-z0-9_]*|[{}:]|\\S")]
  | map(if . == "..." or . == "{" or . == "}" or . == ":" or name or startswith("(") and length > 1
        then . else refuse("token \(.)") end);
def normalize: gsub("\\s+"; " ") | gsub("\\( "; "(") | gsub(" \\)"; ")");
# Two selections at one level merged as GraphQL merges them: one response
# key names one field with one set of arguments.
def merge($b):
  reduce ($b | keys_unsorted[]) as $k (.;
    if has($k) | not then . + {($k): $b[$k]}
    elif $k | startswith("?on ") then .[$k] |= merge($b[$k])
    elif $k | startswith("...") then .
    elif .[$k].f != $b[$k].f or .[$k].a != $b[$k].a then refuse("conflicting fields at \($k)")
    elif (.[$k].s == true) != ($b[$k].s == true) then refuse("conflicting selections at \($k)")
    elif .[$k].s == true then .
    else .[$k].s |= merge($b[$k].s) end);
# The selection after a `{`, up to its matching `}`: {tree, rest}. A field
# is its response key over {f: NAME, a: ARGUMENTS, s: its selection, true
# for a leaf}, a type condition the key `?on TYPE`, a spread `...NAME`.
def parse:
  if length == 0 then refuse("unclosed selection")
  elif .[0] == "}" then {tree: {}, rest: .[1:]}
  elif .[0] == "..." then
    if .[1] == "on" then
      (.[2] // "") as $kind
      | if known($kind) | not then refuse("type \($kind)")
        elif .[3] != "{" or .[4] == "}" then refuse("inline fragment")
        else (.[4:] | parse) as $inner | ($inner.rest | parse) as $siblings
          | {tree: ({("?on " + $kind): $inner.tree} | merge($siblings.tree)), rest: $siblings.rest} end
    elif .[1] | name then
      .[1] as $spread | (.[2:] | parse) as $siblings
      | {tree: ({("..." + $spread): true} | merge($siblings.tree)), rest: $siblings.rest}
    else refuse("spread") end
  elif .[0] | name | not then refuse("token \(.[0])")
  else
    (if .[1] == ":" then {key: .[0], f: .[2], after: .[3:]} else {key: .[0], f: .[0], after: .[1:]} end) as $h
    | if $h.f | name | not then refuse("alias \($h.key)") else . end
    | (if ($h.after[0] // "") | startswith("(") then {a: ($h.after[0] | normalize), after: $h.after[1:]}
       else {a: "", after: $h.after} end) as $g
    | (if $g.after[0] == "{" then
         if $g.after[1] == "}" then refuse("empty selection at \($h.key)") else ($g.after[1:] | parse) end
       else {tree: true, rest: $g.after} end) as $child
    | ($child.rest | parse) as $siblings
    | {tree: ({($h.key): {f: $h.f, a: $g.a, s: $child.tree}} | merge($siblings.tree)), rest: $siblings.rest}
  end;
# The named fragments after the operation: {NAME: {"?on TYPE": tree}}.
def fragments:
  if length == 0 then {}
  elif .[0] == "fragment" and (.[1] | name) and .[2] == "on" and .[4] == "{" and .[5] != "}" then
    .[1] as $name | .[3] as $kind
    | if known($kind) | not then refuse("type \($kind)") else . end
    | (.[5:] | parse) as $fragment
    | ($fragment.rest | fragments) as $others
    | if $others | has($name) then refuse("fragment \($name) twice") else . end
    | {($name): {("?on " + $kind): $fragment.tree}} + $others
  else refuse("after the operation") end;
def resolve($fragments):
  if type != "object" then .
  else
    . as $tree
    | reduce ($tree | keys_unsorted[]) as $key ({};
        if $key | startswith("...") then
          merge(($fragments[$key[3:]] // refuse("fragment \($key[3:]) undefined")) | resolve($fragments))
        elif $key | startswith("?on ") then merge({($key): ($tree[$key] | resolve($fragments))})
        else merge({($key): ($tree[$key] | .s |= resolve($fragments))}) end)
  end;
# The resolved selection judged against SCHEMA at $kind, each field given
# its position: t its type ("S" a scalar or enum), l whether it is a list.
def validate($kind; $path):
  . as $tree
  | reduce ($tree | keys_unsorted[]) as $key ({};
      if $key | startswith("?on ") then
        $key[4:] as $condition
        | if $condition != $kind and (possible($kind) - (possible($kind) - possible($condition))) == []
          then refuse("condition \($condition) never applies at \($path) (\($kind))")
          else . + {($key): ($tree[$key] | validate($condition; $path))} end
      else
        $tree[$key] as $field
        | (if $path == "" then $field.f else $path + "." + $field.f end) as $at
        | (if $field.f == "__typename" then ["S", false]
           else SCHEMA[$kind][$field.f] // refuse("\($field.f) is no field of \($kind) at \($at)") end) as $position
        | if $position[0] == "S" and $field.s != true then refuse("selection on a scalar at \($at)")
          elif $position[0] != "S" and $field.s == true then refuse("no selection on \($position[0]) at \($at)")
          elif $field.s == true then . + {($key): ($field + {t: "S", l: $position[1]})}
          else . + {($key): ($field + {t: $position[0], l: $position[1], s: ($field.s | validate($position[0]; $at))})} end
      end);
# An object's GraphQL type: its `__typename`, else its node id's prefix
# (GitHub's global ids: `CR_` a CheckRun, `CS_` a CheckSuite).
def node_type:
  if (.__typename | type) == "string" then .__typename
  elif (.id | type) == "string" then {"CR": "CheckRun", "CS": "CheckSuite"}[.id | split("_")[0]]
  else null end;
def project($tree; $kind; $path):
  if type == "array" then map(project($tree; $kind; $path))
  elif type != "object" then .
  else
    . as $value
    | [$tree | keys_unsorted[] | select(startswith("?on "))] as $conditions
    | ($tree | with_entries(select(.key | startswith("?on ") | not))) as $direct
    | (if POSSIBLE | has($kind) then $value | node_type else $kind end) as $concrete
    | if ($concrete != null and (possible($kind) | index([$concrete])) == null)
      or ((POSSIBLE | has($kind) | not) and ($value.__typename | type) == "string" and $value.__typename != $kind)
      then refuse("a \($value | node_type) planted at \($path) (\($kind))") else . end
    | if $concrete == null and ($conditions | length) > 0
      then refuse("untyped-node-under-condition at \($path)") else . end
    | (reduce $conditions[] as $condition ($direct;
         if (possible($condition[4:]) | index([$concrete])) != null then merge($tree[$condition]) else . end)) as $selected
    | if [$selected | keys_unsorted[] | select(startswith("?on "))] != [] then refuse("nested type condition at \($path)") else . end
    | reduce ($selected | keys_unsorted[]) as $key ({};
        $selected[$key] as $field
        | (if $path == "" then $field.f else $path + "." + $field.f end) as $at
        | (if $field.a != "" and ($value | has($field.f + $field.a)) then $value[$field.f + $field.a]
           elif $field.a != "" and ($value | keys | any(startswith($field.f + "(")))
           then refuse("no plant for \($field.f + $field.a) at \($at)")
           elif $value | has($field.f) then $value[$field.f]
           else refuse("no plant for \($at)") end) as $planted
        | if $field.l != true and ($planted | type) == "array" then refuse("a list planted at \($at)")
          elif $field.s == true and ([$planted] | flatten | any(type == "object"))
          then refuse("leaf on an object at \($at)")
          elif $field.s != true and ([$planted] | flatten | any(type != "object" and type != "null"))
          then refuse("selection on a scalar at \($at)")
          elif $field.s == true then . + {($key): $planted}
          else . + {($key): ($planted | project($field.s; $field.t; $at))} end)
  end;
($q | tokens) as $tokens
| ($tokens | index(["{"]) // refuse("no selection")) as $open
| ($tokens[:$open] | map(if startswith("(") then "A" elif name then "N" else "X" end) | join("")) as $head
| if ($tokens[0] == "query" or $tokens[0] == "mutation") and (["N", "NN", "NA", "NNA"] | index([$head])) != null
  then . else refuse("operation") end
| (if $tokens[0] == "query" then "Query" else "Mutation" end) as $root
| ($tokens[$open + 1:] | if .[0] == "}" then refuse("empty selection") else parse end) as $operation
| ($operation.rest | fragments) as $fragments
| ([$operation.tree, $fragments] | [.. | objects | keys_unsorted[] | select(startswith("...")) | .[3:]] | unique) as $spread
| (($fragments | keys) - $spread) as $unused
| if ($unused | length) > 0 then refuse("fragment \($unused[0]) never spread") else . end
| ($operation.tree | resolve($fragments) | validate($root; "")) as $selection
| if (.body | type) == "object" and (.body.data | type) == "object"
  then .body.data |= project($selection; $root; "")
  else . end
