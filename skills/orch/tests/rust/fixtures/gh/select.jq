# GraphQL answers only the fields a query selects (GraphQL specification
# § 6.3): a planted reply's `data` projected onto the selection set of the
# query in $q. The projector is closed: it reads the forms below, the ones
# the runtime's queries and the github package's queries it answers send,
# and refuses every other token and form, so a query edit either projects
# as GraphQL would answer it or reddens the row that reads it.
#
# The forms:
# - one operation, `query` or `mutation`, with an optional name and
#   optional variable definitions, then its selection set; after it, named
#   fragments `fragment NAME on TYPE { ... }`, each spread somewhere;
# - a field `NAME`, `NAME(ARGUMENTS)` or `ALIAS: NAME(ARGUMENTS)`, with a
#   selection set where its value is an object and none where it is not;
# - an inline fragment `... on TYPE { ... }` and a spread `...NAME`, TYPE
#   one of TYPES;
# - arguments: names, variables, numbers, enum values, lists, input objects
#   and double-quoted strings, read whole and not interpreted.
# A comment, a directive, an empty selection set, a fragment defined twice
# or never spread, a type condition directly inside another, and any other
# character are refused.
#
# The plants: a field is planted under its schema name, never under a
# response alias, and the answer carries the planted value under the
# response key. A field selected on one object with different arguments is
# planted under NAME(ARGUMENTS) as the query writes them, whitespace
# collapsed. A selected field with no plant, a leaf selected on an object,
# a selection set on a scalar, and a field outside a type condition on an
# abstract position (ABSTRACT) that its interface or union lacks are
# refused, never answered from a neighbour. A type condition applies to an
# object of its type: the planted `__typename`, else the GitHub node id's
# prefix; an untyped object under a condition is refused.
def TYPES: [
  "CheckSuite", "CheckRun", "Commit", "CheckSuiteConnection", "CheckRunConnection",
  "HeadRefForcePushedEvent", "AutoMergeEnabledEvent", "AutoSquashEnabledEvent",
  "AutoRebaseEnabledEvent", "AddedToMergeQueueEvent", "ReviewDismissedEvent",
  "ReadyForReviewEvent"
];
# The abstract positions the queries select under, by their path of field
# names from `data`, each with the fields its interface or union carries.
def ABSTRACT: {
  "nodes": ["__typename", "id"],
  "node": ["__typename", "id"],
  "repository.object": ["__typename", "id", "oid"],
  "repository.pullRequest.timelineItems.nodes": ["__typename"]
};
def NAME: "^[A-Za-z_][A-Za-z0-9_]*$";
def ARGS: "\\((?:[A-Za-z0-9_$:,!\\[\\]{}\\s]|\"[^\"\\\\\\n]*\")*\\)";
def refuse($why): error("gh-fake: unsupported-selection \($why) query=[\($q)]");
def name: type == "string" and test(NAME);
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
      (.[2] // "") as $type
      | if (TYPES | index([$type])) == null then refuse("type \($type)")
        elif .[3] != "{" or .[4] == "}" then refuse("inline fragment")
        else (.[4:] | parse) as $inner | ($inner.rest | parse) as $siblings
          | {tree: ({("?on " + $type): $inner.tree} | merge($siblings.tree)), rest: $siblings.rest} end
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
    .[1] as $name | .[3] as $type
    | if (TYPES | index([$type])) == null then refuse("type \($type)") else . end
    | (.[5:] | parse) as $fragment
    | ($fragment.rest | fragments) as $others
    | if $others | has($name) then refuse("fragment \($name) twice") else . end
    | {($name): {("?on " + $type): $fragment.tree}} + $others
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
# An object's GraphQL type: its `__typename`, else its node id's prefix
# (GitHub's global ids: `CR_` a CheckRun, `CS_` a CheckSuite).
def node_type:
  if (.__typename | type) == "string" then .__typename
  elif (.id | type) == "string" then {"CR": "CheckRun", "CS": "CheckSuite"}[.id | split("_")[0]]
  else null end;
def project($tree; $path):
  if type == "array" then map(project($tree; $path))
  elif type != "object" then .
  else
    . as $value
    | [$tree | keys_unsorted[] | select(startswith("?on "))] as $conditions
    | ($tree | with_entries(select(.key | startswith("?on ") | not))) as $direct
    | (ABSTRACT | .[$path]) as $interface
    | ([$direct[] | .f] - ($interface // [$direct[] | .f])) as $outside
    | if ($outside | length) > 0 then refuse("\($outside[0]) outside a type condition at \($path)") else . end
    | (if ($conditions | length) == 0 then $direct
       else ($value | node_type) as $type
       | if $type == null then refuse("untyped-node-under-condition at \($path)") else . end
       | reduce $conditions[] as $condition ($direct;
           if $condition == ("?on " + $type) then merge($tree[$condition]) else . end)
       end) as $selected
    | if [$selected | keys_unsorted[] | select(startswith("?on "))] != [] then refuse("nested type condition at \($path)") else . end
    | reduce ($selected | keys_unsorted[]) as $key ({};
        $selected[$key] as $field
        | (if $path == "" then $field.f else $path + "." + $field.f end) as $at
        | (if $field.a != "" and ($value | has($field.f + $field.a)) then $value[$field.f + $field.a]
           elif $field.a != "" and ($value | keys | any(startswith($field.f + "(")))
           then refuse("no plant for \($field.f + $field.a) at \($at)")
           elif $value | has($field.f) then $value[$field.f]
           else refuse("no plant for \($at)") end) as $planted
        | if $field.s == true and ([$planted] | flatten | any(type == "object"))
          then refuse("leaf on an object at \($at)")
          elif $field.s != true and ([$planted] | flatten | any(type != "object" and type != "null"))
          then refuse("selection on a scalar at \($at)")
          elif $field.s == true then . + {($key): $planted}
          else . + {($key): ($planted | project($field.s; $at))} end)
  end;
($q | tokens) as $tokens
| ($tokens | index(["{"]) // refuse("no selection")) as $open
| ($tokens[:$open] | map(if startswith("(") then "A" elif name then "N" else "X" end) | join("")) as $head
| if ($tokens[0] == "query" or $tokens[0] == "mutation") and (["N", "NN", "NA", "NNA"] | index([$head])) != null
  then . else refuse("operation") end
| ($tokens[$open + 1:] | if .[0] == "}" then refuse("empty selection") else parse end) as $operation
| ($operation.rest | fragments) as $fragments
| ([$operation.tree, $fragments] | [.. | objects | keys_unsorted[] | select(startswith("...")) | .[3:]] | unique) as $spread
| (($fragments | keys) - $spread) as $unused
| if ($unused | length) > 0 then refuse("fragment \($unused[0]) never spread") else . end
| ($operation.tree | resolve($fragments)) as $selection
| if (.body | type) == "object" and (.body.data | type) == "object"
  then .body.data |= project($selection; "")
  else . end
