# GraphQL answers only the fields a query selects (GraphQL specification
# § 6.3): a planted reply's `data` projected onto the selection set of the
# query in $q. Comments and arguments are dropped, an alias is the field's
# key in the answer, and a fragment's fields, inline or named, are read only
# on an object of its type condition: the planted `__typename`, else the
# GitHub node id's prefix. An object whose type is unknown under a condition,
# a directive, or any other form is refused, never guessed at.
def unsupported: error("gh-fake: unsupported-selection query=[\($q)]");
# The selection after a `{`, up to its matching `}`: {tree, rest}, where a
# leaf field is `true`, an object field its own tree, a type condition the
# key `?on TYPE`, and a named fragment's spread the key `...NAME`.
def parse:
  if length == 0 then unsupported
  elif .[0] == "}" then {tree: {}, rest: .[1:]}
  elif .[0] == "..." then
    if .[1] == "on" and .[3] == "{" then
      .[2] as $type
      | (.[4:] | parse) as $fragment
      | ($fragment.rest | parse) as $siblings
      | {tree: ({("?on " + $type): $fragment.tree} * $siblings.tree), rest: $siblings.rest}
    elif (.[1] // "") | test("^[A-Za-z_]") then
      (.[2:] | parse) as $siblings
      | {tree: ({("..." + .[1]): true} * $siblings.tree), rest: $siblings.rest}
    else unsupported end
  elif .[0] == "{" or .[0] == ":" or .[0] == "@" then unsupported
  else
    .[0] as $key
    | (if .[1] == ":" then .[3:] else .[1:] end) as $after
    | (if $after[0] == "{" then ($after[1:] | parse) else {tree: true, rest: $after} end) as $child
    | ($child.rest | parse) as $siblings
    | {tree: ({($key): $child.tree} * $siblings.tree), rest: $siblings.rest}
  end;
# The named fragments after the operation: {NAME: {"?on TYPE": tree}}.
def fragments:
  if length == 0 then {}
  elif .[0] == "fragment" and .[2] == "on" and .[4] == "{" then
    .[1] as $name | .[3] as $type | (.[5:] | parse) as $fragment
    | {($name): {("?on " + $type): $fragment.tree}} + ($fragment.rest | fragments)
  else unsupported end;
def resolve($fragments):
  if type != "object" then .
  else
    . as $tree
    | reduce ($tree | keys_unsorted[]) as $key ({};
        if $key | startswith("...")
        then . * (($fragments[$key[3:]] // unsupported) | resolve($fragments))
        else . * {($key): ($tree[$key] | resolve($fragments))} end)
  end;
# An object's GraphQL type: its `__typename`, else its node id's prefix
# (GitHub's global ids: `CR_` a CheckRun, `CS_` a CheckSuite).
def node_type:
  if (.__typename | type) == "string" then .__typename
  elif (.id | type) == "string" then {"CR": "CheckRun", "CS": "CheckSuite"}[.id | split("_")[0]]
  else null end;
def project($tree):
  if $tree == true then .
  elif type == "object" then
    ([$tree | keys_unsorted[] | select(startswith("?on "))]) as $conditions
    | (if ($conditions | length) == 0 then $tree
       else node_type as $type
       | if $type == null then error("gh-fake: untyped-node-under-condition query=[\($q)]") else . end
       | reduce $conditions[] as $condition (($tree | with_entries(select(.key | startswith("?on ") | not)));
           if $condition == ("?on " + $type) then . * $tree[$condition] else . end)
       end) as $selected
    | with_entries(.key as $k | select($selected[$k] != null) | .value |= project($selected[$k]))
  elif type == "array" then map(project($tree))
  else . end;
[$q | gsub("#[^\n]*"; "") | scan("\\([^)]*\\)|\\.\\.\\.|[A-Za-z_][A-Za-z0-9_]*|[{}:@]") | select(startswith("(") | not)] as $tokens
| ($tokens | index("{") // unsupported) as $open
| ($tokens[$open + 1:] | parse) as $operation
| ($operation.rest | fragments) as $fragments
| ($operation.tree | resolve($fragments)) as $selection
| if (.body | type) == "object" and (.body.data | type) == "object"
  then .body.data |= project($selection)
  else . end
