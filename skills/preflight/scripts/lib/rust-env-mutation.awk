# Rust test call sites, as line numbers. This is a lexical check, not name
# resolution: aliases, wrappers and calls split across lines are unjudged.
# Strings and nested comments must be removed before braces define test scope.
function code_line(s,    out, c, pair, n, token) {
  out = ""
  while (length(s)) {
    c = substr(s, 1, 1); pair = substr(s, 1, 2)
    if (block) {
      if (pair == "/*") { block++; s = substr(s, 3) }
      else if (pair == "*/") { block--; s = substr(s, 3) }
      else s = substr(s, 2)
    } else if (raw_end != "") {
      n = index(s, raw_end)
      if (!n) return out
      s = substr(s, n + length(raw_end)); raw_end = ""
    } else if (quoted) {
      s = substr(s, 2)
      if (escaped) escaped = 0
      else if (c == "\\") escaped = 1
      else if (c == "\"") quoted = 0
    } else if (pair == "//") return out
    else if (pair == "/*") { block = 1; out = out " "; s = substr(s, 3) }
    else if (match(s, /^r#*"/)) {
      token = substr(s, 1, RLENGTH)
      raw_end = "\"" substr(token, 2, length(token) - 2)
      out = out " "; s = substr(s, RLENGTH + 1)
    } else if (c == "\"") { quoted = 1; out = out " "; s = substr(s, 2) }
    else if (match(s, /^'([^'\\]|\\.)'/)) {
      out = out " "; s = substr(s, RLENGTH + 1)
    } else { out = out c; s = substr(s, 2) }
  }
  return out
}
{
  code = code_line($0)
  hit = 0
  for (i = 1; i <= length(code); i++) {
    rest = substr(code, i)
    if (match(rest, /^#[[:space:]]*\[[[:space:]]*(cfg[[:space:]]*\([[:space:]]*test[[:space:]]*\)|test)[[:space:]]*\]/)) {
      pending_test = 1
      sig_parens = sig_brackets = sig_angles = sig_braces = 0
      i += RLENGTH - 1
      continue
    }
    c = substr(code, i, 1)
    if (c == "{") {
      depth++
      if (pending_test) {
        # Const expressions in a signature are not the attributed item body.
        if (sig_parens || sig_brackets || sig_angles || sig_braces) sig_braces++
        else {
          if (!test_depth) test_depth = depth
          pending_test = 0
        }
      }
    } else if (c == "}") {
      if (pending_test && sig_braces) sig_braces--
      if (test_depth == depth) test_depth = 0
      depth--
    } else if (pending_test && !sig_braces) {
      if (c == "(") sig_parens++
      else if (c == ")") sig_parens--
      else if (c == "[") sig_brackets++
      else if (c == "]") sig_brackets--
      else if (c == "<") sig_angles++
      else if (c == ">" && sig_angles && substr(code, i - 1, 1) != "-") sig_angles--
      else if (c == ";" && !sig_parens && !sig_brackets && !sig_angles) pending_test = 0
    }
    if ((file_test || test_depth) && (i == 1 || substr(code, i - 1, 1) !~ /[[:alnum:]_:]/) &&
        rest ~ /^((::[[:space:]]*)?std[[:space:]]*::[[:space:]]*)?env[[:space:]]*::[[:space:]]*(set_var|remove_var)[[:space:]]*\(/) hit = 1
  }
  if (hit) print NR
}
