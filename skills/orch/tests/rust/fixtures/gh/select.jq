# GraphQL answers only the fields a query selects (GraphQL specification
# § 6.3): a planted reply's `data` projected onto the selection set of the
# query in $q. Arguments and variable declarations are dropped, an alias is
# the field's key in the answer, and a fragment's fields, inline or named,
# are read as its parent's. A directive, or any other form, is refused,
# never guessed at.
def unsupported: error("gh-fake: unsupported-selection query=[\($q)]");
# The selection after a `{`, up to its matching `}`: {tree, rest}, where a
# leaf field is `true`, an object field its own tree, and a named fragment's
# spread the key `...NAME`.
def parse:
  if length == 0 then unsupported
  elif .[0] == "}" then {tree: {}, rest: .[1:]}
  elif .[0] == "..." then
    if .[1] == "on" and .[3] == "{" then
      (.[4:] | parse) as $fragment
      | ($fragment.rest | parse) as $siblings
      | {tree: ($fragment.tree * $siblings.tree), rest: $siblings.rest}
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
# The named fragments after the operation: {NAME: tree}.
def fragments:
  if length == 0 then {}
  elif .[0] == "fragment" and .[2] == "on" and .[4] == "{" then
    .[1] as $name | (.[5:] | parse) as $fragment
    | {($name): $fragment.tree} + ($fragment.rest | fragments)
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
def project($tree):
  if $tree == true then .
  elif type == "object" then
    with_entries(.key as $k | select($tree[$k] != null) | .value |= project($tree[$k]))
  elif type == "array" then map(project($tree))
  else . end;
[$q | scan("\\([^)]*\\)|\\.\\.\\.|[A-Za-z_][A-Za-z0-9_]*|[{}:@]") | select(startswith("(") | not)] as $tokens
| ($tokens | index("{") // unsupported) as $open
| ($tokens[$open + 1:] | parse) as $operation
| ($operation.rest | fragments) as $fragments
| ($operation.tree | resolve($fragments)) as $selection
| if (.body | type) == "object" and (.body.data | type) == "object"
  then .body.data |= project($selection)
  else . end
