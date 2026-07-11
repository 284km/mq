# PAIN log — mq dogfood

Friction hit building a **native CLI** in Mere — a different domain from
the mere-notes web app, chosen to surface pain the Wasm + Node host never
did (native C/LLVM backends, CLI I/O, native distribution). Each entry is
a signal for a language / runtime / tooling improvement. Distill the sharp
ones into upstream issues when they mature.

Status legend: 🔴 open · 🟡 worked around · 🟢 fixed upstream

---

## P1 🟢 Native CLI I/O (argv + stdin + exit — all fixed upstream)

The whole point of a CLI: read arguments and stdin. In the interpreter,
`args ()` (argv), `read_line ()` (stdin), and `exit n` all work. But
compiling a native binary hits a wall:

- `mere -c` **emits** C that references `args` / `read_line` as if they
  were runtime closures, but never defines them, so `clang` fails:
  `use of undeclared identifier 'args'` / `'read_line'`. The C backend
  supports `print` / `read_file` but not argv / stdin / exit.
- `mere -ll` (LLVM) rejects it earlier: `unsupported (llvm codegen,
  Phase 5.1 MVP): unbound variable: args`.

So a native Mere program today can only read a **fixed file path**, not
take arguments or read stdin — which is why `examples/word_count.mere`
notes it "uses a fixed path without taking arguments." mere-notes never
hit this: the Wasm + Node host provided every extern.

**Signal (M0, upstream):** add `args` (argv), `read_line` (read a line
from stdin), `exit` (process exit code), and ideally stderr (`eprint`) +
`getenv` to the **C backend runtime**. This is the prerequisite for `mq`
and for Mere-as-a-CLI-language generally.

**Fixed so far (mere `ba99b56`):** `args()` now works on the C backend —
`main()` takes `(argc, argv)` and captures them; `__lang_args` builds the
argv[1..] str list. Verified native: `mq apple banana` → `[apple, banana]`.
So an argument-driven native CLI is possible now (`mq <query> <file>`,
reading the file with the already-working `read_file`).

**stdin fixed (mere v0.1.2):** a `read_stdin : unit -> str` builtin now
reads all of stdin (interp + C backend), so `echo … | mq '.query'` works —
`mq` falls back to `read_stdin ()` when given no file argument (`--csv`
included). Verified native end-to-end through the release binary.

**`exit n` fixed (mere v0.1.7):** the C backend now emits libc `exit(n)`
(noreturn) followed by a default value of the expected type, so `exit`'s
`'a` (bottom) result type-checks as an unreachable C expression — the same
shape as `fail`. A native CLI can now set its process exit code mid-program
instead of only returning it from `main`. Verified native: `exit 3` → exit
code 3. LLVM still rejects `args` outright ("Phase 5.1 MVP"), so `mq`
builds via the C backend only.

## P2 🟢 C backend ignored shadowing of the `join` builtin (fixed upstream)

First hit while testing `args`, then for real in `contrib/csv` (a local
`let rec join` string-joiner): a user-bound `join` compiled to
`pthread_join(t.tid, …)`, failing with `no member named 'tid'`. The C
backend's `App` dispatch matched `Ast.Var "join"` before its
shadowing-aware cases.

**Fixed (mere `dd17b8a`):** the `join` case now checks the same shadow set
used elsewhere (`current_var_types` / `current_env_subst` / `inner_lifts` /
`toplevel_fn_names`), so a shadowed `join` falls through to ordinary
application. Regression test added.

**Signal (upstream):** the C backend's `Ast.Var "<builtin>"` dispatch
should first check whether the name is locally bound (shadowed) before
treating it as the builtin — the interpreter and typer already respect
shadowing.

## P3 🟢 contrib/json parser & writer don't share a type (fixed upstream)

**Fixed (mere `31b4c45`):** the serialiser (`to_json_str` /
`to_pretty_str`) was merged into `module Json` (and `writer.mere` deleted),
so it operates on the same `Json.json` the parser produces —
`Json.to_pretty_str (Json.parse_json s)` now type-checks. (mq keeps its own
compact serialiser for now; it can switch to `Json.to_json_str` when its
deps pin a mere rev that includes this.)


`contrib/json/json.mere` defines the parser inside `module Json` (so its
type is `Json.json`); `contrib/json/writer.mere` defines a **top-level**
`type json` + `module JsonWriter` with `to_pretty_str`. The two `json`
types are structurally identical but nominally distinct, so a value from
`Json.parse_json` can't be handed to `JsonWriter.to_pretty_str` — you get
a type mismatch. So you can parse *or* serialise from contrib, not both.

**Worked around:** hand-rolled a serialiser over `Json.json` in `mq`.

**Signal (upstream):** parser and writer should share one `json` type —
either put both in the same `module Json`, or have the writer `import` the
parser's type instead of redeclaring it.

## P4 🟢 Qualified module types (`Json.json`) can't appear in annotations (fixed upstream)

**Fixed (mere `5eaa3d9`):** the type-annotation grammar now accepts
`Module.t`; module-internal types are registered unqualified, so the
parser drops the prefix and resolves the bare name.


`let f = fn (v: Json.json) -> …` fails to parse: `expected ',' or ')' in
param list` at the `.`. Type annotations don't accept a qualified
(module-scoped) type name, so functions over an imported module's type
must go unannotated and rely on inference.

**Worked around:** dropped the annotations; HM inference recovers the type
from the `Json.JNull` / … match arms.

**Signal (upstream):** the type-annotation grammar should accept
`Module.type` (qualified type constructors), mirroring qualified value
(`Module.f`) and constructor (`Module.Ctor`) access, which already work.

## P5 🟢 contrib/json.mere ran self-tests on import (fixed upstream)

Importing `contrib/json/json.mere` printed ~20 lines of `run_case` demo
output and could `fail` on the intentional bad-input cases — because the
file kept executable self-tests as top-level `let _ = run_case …;`
statements *outside* `module Json` (the file even said "Remove in actual
use"). So it wasn't usable as a library: the demo ran on every import.

**Fixed (mere):** truncated the file at the module close so `json.mere` is
library-clean (a module-only file, like `xml.mere`). The parser is already
covered by the compile-time bootstrap tests, so no coverage was lost.

## P6 🟢 C backend lacks the `str_eq` function (only `==` on str) (fixed upstream)

**Fixed (mere `5eaa3d9`):** added a curried `str_eq a b` case to the C
backend → `strcmp(a, b) == 0`, matching the `==`-on-str path.


`str_eq a b` compiled to an undeclared-identifier `clang` error: the C
backend has no runtime `str_eq`, only the `==` operator on str-typed
operands (→ `strcmp(...) == 0`). `str_eq` works in the interpreter and the
Wasm backend, so this is a 4-backend parity gap.

**Worked around:** used `path == ""` instead of `str_eq path ""`.

**Signal (upstream):** either add a `str_eq` direct-call case to the C
backend (→ `strcmp == 0`, like the `==`-on-str path already does) or
document `==` as the portable string-equality idiom.

## P7 🟢 `>=` / `<=` don't typecheck on str (fixed upstream in mere v0.1.3)

Writing char-range tests as `c >= "0" && c <= "9"` failed: `type error:
expected 'int', got 'str'` — the ordering operators were typed int-only, so
`c` was forced to int and the str literal `"0"` clashed. (`==` / `!=` did
work on str, and the C backend even had `strcmp`-based `<`/`<=`/`>`/`>=`
for str operands — so the gap was in the typer, not codegen.)

**Worked around (initially):** classified characters via `ord c` (byte
value) + int comparison.

**Fixed upstream (mere v0.1.3):** the typer now accepts `<`/`<=`/`>`/`>=`
on str, comparing lexicographically, across all four backends (interp / C /
Wasm / LLVM — C and LLVM already lowered str comparison via `strcmp`). The
`int` default for unresolved operands is preserved, so the fix is backward
compatible. mq's char classes are now the direct
`c >= "0" && c <= "9"` / `(c >= "a" && c <= "z") || …` form; the `ord`
workaround is gone. (`ord` is still used in `scan_int` to turn a digit char
into its numeric value — that's genuine char→int conversion, not a
comparison workaround.)

## (M3) 🟢 positive: stream redesign hit no language friction

Generalising the query engine from `json -> json` to a stream model
(`json -> json list`, flat-mapped per selector, with `.[]` exploding one
value into many and `|` sequencing) was written in Mere with no friction:
the `sel` ADT gained an `Iter` case, and `step` / `run` / `concat` are
plain recursion. Like the CRDT in mere-notes, functional stream/AST code
is where Mere is comfortable — the pains so far are all at the edges
(native I/O, contrib packaging, str/Unicode), not in the core language.

## P8 🟢 C backend broke inner-fn lifting when two modules are composed (fixed upstream)

The sharpest finding of M4. Importing **both** `json/json.mere` and
`csv/parser.mere` and parsing a JSON array fails to compile: a lifted
inner loop in json's array parser is emitted as
`__lifted_loop_2(s, n, …)` but `n` (the string length it captured) is
never declared — `use of undeclared identifier 'n'`. Isolated:

- `import json` alone + parse a JSON array → compiles & runs (M1–M3).
- `import json` **and** `import csv` + the same parse → C compile error.

So it's not either module alone — composing two modules that each contain
inner-lifted recursive loops corrupts the C backend's capture analysis
(the `__lifted_loop_N` numbering / captured-var set isn't isolated per
module). A real limitation on composing contrib libraries in native builds.

**Root cause (found upstream):** not naming — the transitive-capture
fixpoint resolved inner-fn names via a *global* last-write map. Two hosts
with a same-named inner fn (json's `loop` and csv's `loop`) collided, so
json's recursive `loop` self-call resolved to csv's lifted fn and json's
loop inherited csv's `n` capture — a variable undeclared at json's call
sites.

**Fixed (mere `27fbfca`):** the fixpoint now resolves inner-fn names per
host (`inner_lifts_by_host[l_host]`), keeping same-named inner fns
isolated. Minimal repro (two top-level fns each with a `loop`, one
capturing an extra var) added as a regression test.

**Follow-through:** the milestone-4 `str_split` workaround is gone — `mq`
now imports `contrib/csv` directly and gets real quoted-field / embedded-
comma parsing (`"hello, world"` → one field). The fix is validated in the
app.

## P9 🟢 `str_of_int` emits `show_int()` without ensuring it's declared (fixed upstream)

**Fixed (mere `5eaa3d9`):** `collect_show_types` now adds `int` when
`str_of_int` is used, so the `show_int` definition is emitted even without
a direct `show`.


Compiling a program that uses `str_of_int` (e.g. inside `contrib/json`'s
`parse_json`) but never uses `show` fails at `clang` with
`call to undeclared function 'show_int'`. The `show_int` runtime helper is
only emitted when `show` is used; `str_of_int` lowers to the same call but
doesn't trigger the helper's declaration. Works when the program also uses
`show` (mq does, so it's not blocked).

**Signal (upstream):** `str_of_int` should pull in the `show_int` helper
(set the same gating flag `show` does).
