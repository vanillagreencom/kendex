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
#   optional variable definitions `($NAME: TYPE ...)`, TYPE a named type,
#   `[TYPE]` or either with `!`, no default; then its selection set; after
#   it, named fragments `fragment NAME on TYPE { ... }`, each spread
#   somewhere;
# - a field `NAME`, `NAME(ARGUMENTS)` or `ALIAS: NAME(ARGUMENTS)`;
# - an inline fragment `... on TYPE { ... }` and a spread `...NAME`, TYPE
#   one of SCHEMA's types;
# - arguments `NAME: VALUE`, a value a variable `$NAME`, an integer, a
#   double-quoted string, `true`, `false`, `null`, an enum value, a list
#   `[VALUE ...]` or an input object `{NAME: VALUE ...}`, commas between
#   any of them ignored.
# A comment, a directive, an empty selection set, a fragment defined twice
# or never spread, a type condition directly inside another, an argument or
# input field given twice, a variable defined twice, and any other
# character are refused.
#
# The validation (GraphQL specification § 5.3.1, § 5.3.3, § 5.4.1, § 5.4.2,
# § 5.5.2.3, § 5.6.1, § 5.6.2, § 5.6.4, § 5.8), from the operation's root
# type, whatever the plant: a field its type in SCHEMA lacks (an interface
# or union carries only its own fields, a field of one of its types is
# selected under that type's condition), a selection set on a scalar or
# enum, an object with none, a type condition that can never apply at its
# position (no type is both the position's and the condition's), an
# argument its field lacks, a required argument or input field missing, a
# value of another type than its position's (a literal by its kind, an enum
# value outside its enum, an input object's field outside its type, a
# variable whose definition its position does not admit), a variable used
# and never defined or defined and never used, and a variable defined with
# a type that is no input type are refused. `__typename` is a field of
# every type, and an `Int` literal is a signed 32-bit integer (§ 3.5.1).
# The request's variable bindings in $bindings, each [NAME, FLAG, TEXT] as
# gh takes it (`-f NAME=TEXT` a string, `-F NAME=TEXT` typed: an integer,
# `true`, `false` or `null` as that JSON value, any other text a string;
# `NAME[]=TEXT` one member of a list), are judged against the operation's
# variable definitions (GraphQL specification § 6.1.2, CoerceVariableValues):
# a binding of a variable the operation does not define, a variable bound
# twice, a list bound as one value or one value as a list, a value of
# another type than its definition's, null for a non-null type, and a
# variable whose type is non-null and that is not bound are refused; gh's
# own `$endCursor` under `--paginate` is nullable and bound by gh.
# GitHub's own rules on a connection are applied too: a connection field
# takes `first` or `last`, never both and neither null, and a literal one
# between 1 and 100 (docs.github.com/en/graphql/overview/rate-limits-and-
# query-limits-for-the-graphql-api, Node limit).
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
# LIST, ARGUMENTS], TYPE "S" for a scalar or enum, LIST true where GitHub
# answers a list, ARGUMENTS each argument the field takes and its input type
# (absent: none). INPUTS maps each input object to its fields' types, ENUMS
# each enum an argument takes to its values, and SCALARS names the input
# scalars, each cut, like SCHEMA, to what the queries send. POSSIBLE maps
# each interface and union to its member types, those of SCHEMA's types and
# the actor types.
def PAGE: {"first": "Int", "after": "String", "last": "Int", "before": "String"};
def SCHEMA: {
  "Query": {
    "nodes": ["Node", true, {"ids": "[ID!]!"}],
    "repository": ["Repository", false, {"owner": "String!", "name": "String!"}],
    "viewer": ["User", false]
  },
  "Mutation": {
    "dequeuePullRequest": ["DequeuePullRequestPayload", false, {"input": "DequeuePullRequestInput!"}],
    "disablePullRequestAutoMerge": [
      "DisablePullRequestAutoMergePayload", false, {"input": "DisablePullRequestAutoMergeInput!"}
    ]
  },
  "DequeuePullRequestPayload": {"mergeQueueEntry": ["MergeQueueEntry", false]},
  "DisablePullRequestAutoMergePayload": {"clientMutationId": ["S", false]},
  "Node": {"id": ["S", false]},
  "Actor": {"login": ["S", false]},
  "User": {"login": ["S", false], "databaseId": ["S", false]},
  "Bot": {"login": ["S", false], "databaseId": ["S", false]},
  "PullRequestTimelineItems": {},
  "CheckRun": {
    "id": ["S", false], "checkSuite": ["CheckSuite", false], "name": ["S", false],
    "status": ["S", false], "conclusion": ["S", false], "startedAt": ["S", false],
    "completedAt": ["S", false], "detailsUrl": ["S", false]
  },
  "CheckSuite": {
    "id": ["S", false], "databaseId": ["S", false], "createdAt": ["S", false],
    "workflowRun": ["WorkflowRun", false],
    "checkRuns": ["CheckRunConnection", false, (PAGE + {"filterBy": "CheckRunFilter"})]
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
    "nameWithOwner": ["S", false], "pullRequest": ["PullRequest", false, {"number": "Int!"}],
    "vulnerabilityAlerts": ["RepositoryVulnerabilityAlertConnection", false, PAGE]
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
    "headRefOid": ["S", false], "mergeStateStatus": ["S", false], "isInMergeQueue": ["S", false],
    "author": ["Actor", false], "headRepository": ["Repository", false],
    "mergeCommit": ["Commit", false], "mergeQueueEntry": ["MergeQueueEntry", false],
    "autoMergeRequest": ["AutoMergeRequest", false],
    "reviewThreads": ["PullRequestReviewThreadConnection", false, PAGE],
    "commits": ["PullRequestCommitConnection", false, PAGE],
    "reviews": ["PullRequestReviewConnection", false, PAGE],
    "timelineItems": [
      "PullRequestTimelineItemsConnection", false,
      (PAGE + {"itemTypes": "[PullRequestTimelineItemsItemType!]"})
    ]
  },
  "MergeQueueEntry": {
    "id": ["S", false], "state": ["S", false], "position": ["S", false],
    "headCommit": ["Commit", false], "mergeQueue": ["MergeQueue", false],
    "pullRequest": ["PullRequest", false]
  },
  "MergeQueue": {"entries": ["MergeQueueEntryConnection", false, PAGE]},
  "MergeQueueEntryConnection": {"nodes": ["MergeQueueEntry", true]},
  "AutoMergeRequest": {"enabledAt": ["S", false]},
  "PullRequestReviewThreadConnection": {
    "pageInfo": ["PageInfo", false], "nodes": ["PullRequestReviewThread", true]
  },
  "PullRequestReviewThread": {
    "isResolved": ["S", false], "comments": ["PullRequestReviewCommentConnection", false, PAGE]
  },
  "Commit": {
    "oid": ["S", false], "authoredDate": ["S", false], "committedDate": ["S", false],
    "status": ["Status", false], "checkSuites": ["CheckSuiteConnection", false, PAGE]
  },
  "Status": {"context": ["StatusContext", false, {"name": "String!"}]},
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
    "comments": ["PullRequestReviewCommentConnection", false, PAGE]
  },
  "PullRequestReviewCommentConnection": {
    "totalCount": ["S", false], "nodes": ["PullRequestReviewComment", true]
  },
  "PullRequestReviewComment": {
    "id": ["S", false], "replyTo": ["PullRequestReviewComment", false],
    "author": ["Actor", false], "authorAssociation": ["S", false], "body": ["S", false]
  },
  "PullRequestTimelineItemsConnection": {
    "pageInfo": ["PageInfo", false], "totalCount": ["S", false],
    "nodes": ["PullRequestTimelineItems", true]
  },
  "HeadRefForcePushedEvent": {"createdAt": ["S", false], "beforeCommit": ["Commit", false]},
  "AutoMergeEnabledEvent": {"createdAt": ["S", false]},
  "AutoMergeDisabledEvent": {
    "createdAt": ["S", false], "actor": ["Actor", false], "reason": ["S", false],
    "reasonCode": ["S", false]
  },
  "AutoSquashEnabledEvent": {"createdAt": ["S", false]},
  "AutoRebaseEnabledEvent": {"createdAt": ["S", false]},
  "AddedToMergeQueueEvent": {"createdAt": ["S", false]},
  "ReadyForReviewEvent": {"createdAt": ["S", false]},
  "ReviewDismissedEvent": {
    "previousReviewState": ["S", false], "review": ["PullRequestReview", false]
  }
};
def INPUTS: {
  "CheckRunFilter": {"checkType": "CheckRunType"},
  "DequeuePullRequestInput": {"id": "ID!", "clientMutationId": "String"},
  "DisablePullRequestAutoMergeInput": {"pullRequestId": "ID!", "clientMutationId": "String"}
};
def ENUMS: {
  "CheckRunType": ["ALL", "LATEST"],
  "PullRequestTimelineItemsItemType": [
    "HEAD_REF_FORCE_PUSHED_EVENT", "AUTO_MERGE_ENABLED_EVENT", "AUTO_SQUASH_ENABLED_EVENT",
    "AUTO_REBASE_ENABLED_EVENT", "ADDED_TO_MERGE_QUEUE_EVENT", "REVIEW_DISMISSED_EVENT",
    "READY_FOR_REVIEW_EVENT", "AUTO_MERGE_DISABLED_EVENT"
  ]
};
def SCALARS: ["Int", "String", "Boolean", "ID"];
def EVENTS: [
  "HeadRefForcePushedEvent", "AutoMergeEnabledEvent", "AutoSquashEnabledEvent",
  "AutoRebaseEnabledEvent", "AddedToMergeQueueEvent", "ReviewDismissedEvent",
  "ReadyForReviewEvent", "AutoMergeDisabledEvent"
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
# The lexemes inside one parenthesized argument or variable list: variables,
# names, integers, strings and punctuation, commas dropped; any other
# character refuses.
def lexemes:
  [.[1:-1] | scan("\"[^\"\\\\\\n]*\"|\\$[A-Za-z_][A-Za-z0-9_]*|-?[0-9]+|[A-Za-z_][A-Za-z0-9_]*|[\\[\\]{}:!,]|\\S")]
  | map(if test("^(\"|\\$|-?[0-9]|[A-Za-z_]|[\\[\\]{}:!,])") then . else refuse("argument token \(.)") end)
  | map(select(. != ","));
# One value at the head of the lexemes: {v, rest}, v {k: its kind, n: a
# variable's or enum value's name, an integer's value, items, fields}.
def value:
  def items($acc):
    if length == 0 then refuse("unclosed list")
    elif .[0] == "]" then {v: {k: "list", items: $acc}, rest: .[1:]}
    else value as $one | $one.rest | items($acc + [$one.v]) end;
  def fields($acc):
    if length == 0 then refuse("unclosed input object")
    elif .[0] == "}" then {v: {k: "object", fields: $acc}, rest: .[1:]}
    elif (.[0] | name) and .[1] == ":" then
      .[0] as $field
      | if $acc | has($field) then refuse("input field \($field) twice") else . end
      | (.[2:] | value) as $one | $one.rest | fields($acc + {($field): $one.v})
    else refuse("input field \(.[0])") end;
  if length == 0 then refuse("argument value missing")
  elif .[0] == "[" then .[1:] | items([])
  elif .[0] == "{" then .[1:] | fields({})
  elif .[0] | startswith("$") then {v: {k: "var", n: .[0][1:]}, rest: .[1:]}
  elif .[0] | startswith("\"") then {v: {k: "string"}, rest: .[1:]}
  elif .[0] | test("^-?[0-9]+$") then {v: {k: "int", n: (.[0] | tonumber)}, rest: .[1:]}
  elif .[0] == "true" or .[0] == "false" then {v: {k: "boolean"}, rest: .[1:]}
  elif .[0] == "null" then {v: {k: "null"}, rest: .[1:]}
  elif .[0] | name then {v: {k: "enum", n: .[0]}, rest: .[1:]}
  else refuse("argument value \(.[0])") end;
# A field's arguments: {NAME: value}.
def arguments:
  def read($acc):
    if length == 0 then $acc
    elif (.[0] | name) and .[1] == ":" then
      .[0] as $argument
      | if $acc | has($argument) then refuse("argument \($argument) twice") else . end
      | (.[2:] | value) as $one | $one.rest | read($acc + {($argument): $one.v})
    else refuse("argument \(.[0])") end;
  if . == "" then {} else lexemes | read({}) end;
# A type reference at the head of the lexemes: {t, rest}, t its text.
def typeref:
  if .[0] == "[" then
    (.[1:] | typeref) as $inner
    | if $inner.rest[0] != "]" then refuse("list type") else . end
    | $inner.rest[1:] as $after
    | if $after[0] == "!" then {t: "[\($inner.t)]!", rest: $after[1:]} else {t: "[\($inner.t)]", rest: $after} end
  elif (.[0] // "") | name then
    if .[1] == "!" then {t: (.[0] + "!"), rest: .[2:]} else {t: .[0], rest: .[1:]} end
  else refuse("type \(.[0] // "")") end;
# The operation's variable definitions: {NAME: type}.
def definitions:
  def read($acc):
    if length == 0 then $acc
    elif (.[0] | startswith("$")) and .[1] == ":" then
      .[0][1:] as $variable
      | if $acc | has($variable) then refuse("variable $\($variable) twice") else . end
      | (.[2:] | typeref) as $type | $type.rest | read($acc + {($variable): $type.t})
    else refuse("variable definition \(.[0])") end;
  lexemes | read({});
def required: endswith("!");
def nullable: if endswith("!") then .[:-1] else . end;
def listed: nullable | startswith("[");
def item: nullable | .[1:-1];
def named: gsub("[\\[\\]!]"; "");
# A binding's JSON value as gh sends it.
def bound_value($flag; $text):
  if $flag == "f" then $text
  elif $text | test("^-?[0-9]+$") then $text | tonumber
  elif $text == "true" then true
  elif $text == "false" then false
  elif $text == "null" then null
  else $text end;
# Whether a bound JSON value is one a variable of type $type takes.
def binds($declared):
  if . == null then $declared | required | not
  else
    ($declared | nullable) as $kind
    | . as $value
    | if $kind == "Int" then type == "number" and . == floor and . >= -2147483648 and . <= 2147483647
      elif $kind == "String" then type == "string"
      elif $kind == "ID" then type == "string" or (type == "number" and . == floor)
      elif $kind == "Boolean" then type == "boolean"
      elif ENUMS | has($kind) then type == "string" and (ENUMS[$kind] | index([$value])) != null
      else false end
  end;
# The bindings judged against the operation's definitions.
def check_bindings($variables):
  ($bindings | map(. as [$name, $flag, $text]
      | {n: ($name | sub("\\[\\]$"; "")), list: ($name | endswith("[]")), v: bound_value($flag; $text)})) as $given
  | reduce ($given | group_by(.n))[] as $group (.;
      $group[0].n as $n
      | ($variables[$n] // refuse("binding \($n) of no defined variable")) as $type
      | if ($group | map(.list) | unique | length) > 1 then refuse("variable $\($n) bound as a list and a value")
        elif $group[0].list then
          if ($type | listed | not) then refuse("variable $\($n) of \($type) bound as a list")
          elif all($group[]; .v | binds($type | item)) | not then refuse("variable $\($n) takes \($type)")
          else . end
        elif ($group | length) > 1 then refuse("variable $\($n) bound twice")
        elif $type | listed then refuse("variable $\($n) of \($type) bound as one value")
        elif $group[0].v | binds($type) | not then refuse("variable $\($n) takes \($type)")
        else . end)
  | ([$variables | to_entries[] | select(.value | required) | .key] - ($given | map(.n))) as $unbound
  | if $unbound != [] then refuse("variable $\($unbound[0]) of \($variables[$unbound[0]]) unbound") else . end;
# Whether a variable defined as $defined may stand at a position of type
# $at (GraphQL § 5.8.5, no defaults).
def admits($defined; $at):
  if $at | required then ($defined | required) and admits($defined | nullable; $at | nullable)
  elif $defined | required then admits($defined | nullable; $at)
  elif $at | listed then ($defined | listed) and admits($defined | item; $at | item)
  elif $defined | listed then false
  else $defined == $at end;
# Whether the value is one a position of type $at takes (GraphQL § 3.5,
# § 3.10, § 5.6.1, § 5.6.4), $variables the operation's definitions.
def takes($at; $variables):
  if .k == "var" then admits($variables[.n]; $at)
  elif .k == "null" then $at | required | not
  elif $at | listed then
    if .k == "list" then all(.items[]; takes($at | item; $variables)) else takes($at | item; $variables) end
  else
    ($at | nullable) as $kind
    | . as $value
    | if $kind == "Int" then .k == "int" and .n >= -2147483648 and .n <= 2147483647
      elif $kind == "String" then .k == "string"
      elif $kind == "Boolean" then .k == "boolean"
      elif $kind == "ID" then .k == "string" or .k == "int"
      elif ENUMS | has($kind) then .k == "enum" and (ENUMS[$kind] | index([$value.n])) != null
      elif INPUTS | has($kind) then
        INPUTS[$kind] as $fields
        | .k == "object"
          and (($value.fields | keys) - ($fields | keys)) == []
          and all($value.fields | to_entries[]; . as $f | $f.value | takes($fields[$f.key]; $variables))
          and all($fields | to_entries[] | select(.value | required); . as $f | $value.fields | has($f.key))
      else false end
  end;
# The variables a value names.
def uses: [.. | objects | select(.k == "var") | .n];
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
def validate($kind; $path; $variables):
  . as $tree
  | reduce ($tree | keys_unsorted[]) as $key ({};
      if $key | startswith("?on ") then
        $key[4:] as $condition
        | if $condition != $kind and (possible($kind) - (possible($kind) - possible($condition))) == []
          then refuse("condition \($condition) never applies at \($path) (\($kind))")
          else . + {($key): ($tree[$key] | validate($condition; $path; $variables))} end
      else
        $tree[$key] as $field
        | (if $path == "" then $field.f else $path + "." + $field.f end) as $at
        | (if $field.f == "__typename" then ["S", false]
           else SCHEMA[$kind][$field.f] // refuse("\($field.f) is no field of \($kind) at \($at)") end) as $position
        | ($position[2] // {}) as $takes
        | ($field.a | arguments) as $given
        | (($given | keys) - ($takes | keys)) as $unknown
        | if $unknown != [] then refuse("argument \($unknown[0]) is no argument of \($field.f) at \($at)") else . end
        | ([$takes | to_entries[] | select(.value | required) | .key] - ($given | keys)) as $missing
        | if $missing != [] then refuse("argument \($missing[0]) missing at \($at)") else . end
        | reduce ($given | keys_unsorted[]) as $argument (.;
            $given[$argument] as $value
            | if ($value | uses) - ($variables | keys) != []
              then refuse("variable $\(($value | uses) - ($variables | keys) | .[0]) undefined at \($at)")
              elif $value | takes($takes[$argument]; $variables) | not
              then refuse("argument \($argument) at \($at) takes \($takes[$argument])")
              elif ($argument == "first" or $argument == "last") and $value.k == "null"
              then refuse("argument \($argument) at \($at) is null")
              elif ($argument == "first" or $argument == "last") and $value.k == "int" and ($value.n < 1 or $value.n > 100)
              then refuse("argument \($argument) at \($at) outside 1..100")
              else . end)
        | if ($position[0] | endswith("Connection")) and ($given | has("first") or has("last") | not)
          then refuse("a connection with no first or last at \($at)") else . end
        | if $given | has("first") and has("last")
          then refuse("first and last together at \($at)") else . end
        | if $position[0] == "S" and $field.s != true then refuse("selection on a scalar at \($at)")
          elif $position[0] != "S" and $field.s == true then refuse("no selection on \($position[0]) at \($at)")
          elif $field.s == true then . + {($key): ($field + {t: "S", l: $position[1]})}
          else . + {($key): ($field + {t: $position[0], l: $position[1], s: ($field.s | validate($position[0]; $at; $variables))})} end
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
| ($tokens[:$open] | map(select(startswith("("))) | if . == [] then {} else .[0] | definitions end) as $variables
| ([$variables | to_entries[] | select(.value | named | . as $n | (SCALARS + (ENUMS | keys) + (INPUTS | keys)) | index([$n]) == null)]) as $foreign
| if $foreign != [] then refuse("variable $\($foreign[0].key) of \($foreign[0].value), no input type") else . end
| check_bindings($variables)
| ($tokens[$open + 1:] | if .[0] == "}" then refuse("empty selection") else parse end) as $operation
| ($operation.rest | fragments) as $fragments
| ([$operation.tree, $fragments] | [.. | objects | keys_unsorted[] | select(startswith("...")) | .[3:]] | unique) as $spread
| (($fragments | keys) - $spread) as $unused
| if ($unused | length) > 0 then refuse("fragment \($unused[0]) never spread") else . end
| ($operation.tree | resolve($fragments)) as $resolved
| ($resolved | validate($root; ""; $variables)) as $selection
| ([$resolved | .. | objects | select(has("a")) | .a | arguments | uses[]] | unique) as $used
| (($variables | keys) - $used) as $unused
| if $unused != [] then refuse("variable $\($unused[0]) never used") else . end
| if (.body | type) == "object" and (.body.data | type) == "object"
  then .body.data |= project($selection; $root; "")
  else . end
