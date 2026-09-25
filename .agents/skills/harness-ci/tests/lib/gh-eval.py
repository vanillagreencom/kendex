"""Evaluate the GitHub Actions expressions a workflow's job conditions use.

Shared by the suites that read a workflow and ask which of its jobs a context
runs: this package's ci-template suite and kendex's own
tools/tests/ci-class-job-set.test.sh. Sourced by path, never installed.

    gh-eval.py value CONTEXT_JSON EXPR   print the value EXPR evaluates to, as JSON
    gh-eval.py jobs CONTEXT_JSON         read JOB<TAB>NEEDS<TAB>EXPR lines on stdin,
                                         NEEDS comma-separated, and print each JOB
                                         whose condition holds

CONTEXT_JSON is the object the expressions read, `github`, `needs`, `steps` or
any other context, with `needs.<job>.result` set for every job a condition's
status function reads. The evaluator covers string, number and boolean
literals, context paths, `!`, `==`, `!=`, `&&`, `||`, parentheses, and the
functions fromJSON, always, cancelled and success. Anything else is a refusal,
not a guess: every refusal starts `gh-eval: cause=` and exits 2. `==` compares
strings without regard to case, `&&` and `||` return an operand, and a path
that names no value is null, as GitHub evaluates them.
"""
import json
import re
import sys

TOKEN = re.compile(r"\s*(?:(\|\||&&|==|!=|!|\(|\)|,)|'((?:[^']|'')*)'"
                   r"|([A-Za-z_][A-Za-z0-9_-]*(?:\.[A-Za-z_][A-Za-z0-9_-]*)*)|(\d+))")
STATUS = ("always", "cancelled", "success", "failure")


def refuse(msg):
    sys.stderr.write("gh-eval: " + msg + "\n")
    sys.exit(2)


def tokens(src):
    out, i, src = [], 0, src.strip()
    while i < len(src):
        m = TOKEN.match(src, i)
        if not m or m.end() == i:
            refuse("cause=untokenizable at=%d expr=%s" % (i, src))
        op, string, ident, num = m.groups()
        if op:
            out.append(("op", op))
        elif string is not None:
            out.append(("str", string.replace("''", "'")))
        elif ident:
            out.append(("id", ident))
        else:
            out.append(("num", int(num)))
        i = m.end()
    return out


def truthy(v):
    return not (v is None or v is False or v == "" or (type(v) in (int, float) and v == 0))


def equal(a, b):
    if isinstance(a, str) and isinstance(b, str):
        return a.lower() == b.lower()
    return a == b


class Parser:
    # NEEDS is the job's own `needs:` list, which success() reads; None where
    # no job is being judged, and success() is then a refusal.
    def __init__(self, toks, ctx, needs=None):
        self.t, self.i, self.ctx, self.needs = toks, 0, ctx, needs

    def peek(self):
        return self.t[self.i] if self.i < len(self.t) else (None, None)

    def expect(self, value):
        if self.peek() != ("op", value):
            refuse("cause=expected token=%s at=%d" % (value, self.i))
        self.i += 1

    def whole(self):
        v = self.or_()
        if self.i != len(self.t):
            refuse("cause=trailing-tokens at=%d" % self.i)
        return v

    def or_(self):
        v = self.and_()
        while self.peek() == ("op", "||"):
            self.i += 1
            r = self.and_()
            v = v if truthy(v) else r
        return v

    def and_(self):
        v = self.cmp()
        while self.peek() == ("op", "&&"):
            self.i += 1
            r = self.cmp()
            v = r if truthy(v) else v
        return v

    def cmp(self):
        v = self.unary()
        kind, op = self.peek()
        if kind == "op" and op in ("==", "!="):
            self.i += 1
            r = self.unary()
            v = equal(v, r) if op == "==" else not equal(v, r)
        return v

    def unary(self):
        if self.peek() == ("op", "!"):
            self.i += 1
            return not truthy(self.unary())
        return self.primary()

    def primary(self):
        kind, v = self.peek()
        if (kind, v) == ("op", "("):
            self.i += 1
            r = self.or_()
            self.expect(")")
            return r
        if kind in ("str", "num"):
            self.i += 1
            return v
        if kind != "id":
            refuse("cause=unexpected-token at=%d" % self.i)
        self.i += 1
        if v in ("true", "false"):
            return v == "true"
        if v == "null":
            return None
        if self.peek() == ("op", "("):
            self.i += 1
            args = []
            if self.peek() != ("op", ")"):
                args.append(self.or_())
                while self.peek() == ("op", ","):
                    self.i += 1
                    args.append(self.or_())
            self.expect(")")
            return self.call(v, args)
        return self.lookup(v)

    def call(self, name, args):
        if name == "fromJSON":
            return json.loads(args[0])
        if name == "always":
            return True
        if name == "cancelled":
            return False
        if name == "success":
            if self.needs is None:
                refuse("cause=success-outside-a-job")
            return all(self.result(n) == "success" for n in self.needs)
        refuse("cause=unknown-function name=%s" % name)

    def result(self, need):
        job = self.ctx.get("needs", {}).get(need)
        if not isinstance(job, dict) or "result" not in job:
            refuse("cause=unknown-need name=%s" % need)
        return job["result"]

    def lookup(self, path):
        parts = path.split(".")
        if parts[0] not in self.ctx:
            refuse("cause=unknown-context name=%s" % parts[0])
        v = self.ctx
        for p in parts:
            v = v.get(p) if isinstance(v, dict) else None
        return v


def main(argv):
    if len(argv) < 3:
        refuse("cause=usage")
    mode, ctx = argv[1], json.loads(argv[2])
    if mode == "value" and len(argv) == 4:
        print(json.dumps(Parser(tokens(argv[3]), ctx).whole(), separators=(",", ":")))
    elif mode == "jobs" and len(argv) == 3:
        for line in sys.stdin:
            job, needs, expr = line.rstrip("\n").split("\t", 2)
            # A condition naming no status function runs under GitHub's
            # implicit success(), which a failed need makes false.
            if not any(re.search(r"\b%s\(" % f, expr) for f in STATUS):
                expr = "success() && (%s)" % expr
            job_needs = [n for n in needs.split(",") if n]
            if truthy(Parser(tokens(expr), ctx, job_needs).whole()):
                print(job)
    else:
        refuse("cause=unknown-mode mode=%s" % mode)


main(sys.argv)
