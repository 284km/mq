# PAIN log — mq dogfood

Friction hit building a **native CLI** in Mere — a different domain from
the mere-notes web app, chosen to surface pain the Wasm + Node host never
did (native C/LLVM backends, CLI I/O, native distribution). Each entry is
a signal for a language / runtime / tooling improvement. Distill the sharp
ones into upstream issues when they mature.

Status legend: 🔴 open · 🟡 worked around · 🟢 fixed upstream

---

## P1 🟡 Native backends can't do CLI I/O (argv done; stdin / exit remain)

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

**Still open:** (a) **stdin** — there's no read-all-stdin primitive; `jq`'s
`echo … | mq …` UX needs one (a new `read_all` builtin across interp +
backends, or looping `read_line` with an EOF sentinel). (b) **`exit n`** —
the C backend has no case for it, and `exit`'s `'a` (bottom) result is
awkward as a C expression; `mq` returns its code from `main` for now.
LLVM still rejects `args` outright ("Phase 5.1 MVP"), so `mq` builds via
the C backend only.

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

## P3 🟡 contrib/json parser & writer don't share a type — can't compose

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

## P4 🟡 Qualified module types (`Json.json`) can't appear in annotations

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

## P6 🟡 C backend lacks the `str_eq` function (only `==` on str)

`str_eq a b` compiled to an undeclared-identifier `clang` error: the C
backend has no runtime `str_eq`, only the `==` operator on str-typed
operands (→ `strcmp(...) == 0`). `str_eq` works in the interpreter and the
Wasm backend, so this is a 4-backend parity gap.

**Worked around:** used `path == ""` instead of `str_eq path ""`.

**Signal (upstream):** either add a `str_eq` direct-call case to the C
backend (→ `strcmp == 0`, like the `==`-on-str path already does) or
document `==` as the portable string-equality idiom.

## P7 🟡 `>=` / `<=` don't typecheck on str (comparison ops default to int)

Writing char-range tests as `c >= "0" && c <= "9"` failed: `type error:
expected 'int', got 'str'` — the ordering operators are typed int-only, so
`c` was forced to int and the str literal `"0"` clashed. (`==` / `!=` do
work on str, and the C backend even has `strcmp`-based `<`/`<=`/`>`/`>=`
for str operands — so the gap is in the typer, not codegen.)

**Worked around:** classify characters via `ord c` (byte value) + int
comparison instead.

**Signal (upstream):** let the typer accept `<`/`<=`/`>`/`>=` on str
(lexicographic, backed by the existing strcmp paths), or document that
string ordering must go through `ord` / a `str_cmp` helper.

## (M3) 🟢 positive: stream redesign hit no language friction

Generalising the query engine from `json -> json` to a stream model
(`json -> json list`, flat-mapped per selector, with `.[]` exploding one
value into many and `|` sequencing) was written in Mere with no friction:
the `sel` ADT gained an `Iter` case, and `step` / `run` / `concat` are
plain recursion. Like the CRDT in mere-notes, functional stream/AST code
is where Mere is comfortable — the pains so far are all at the edges
(native I/O, contrib packaging, str/Unicode), not in the core language.

## P8 🔴 C backend breaks inner-fn lifting when two modules are composed

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

**Worked around:** don't import `contrib/csv`; parse CSV inline with a
tiny `str_split`-based reader (top-level recursion only, no inner-lifted
loops), so only `json` is imported. (Cost: no quoted-field / embedded-comma
handling.)

**Signal (upstream):** inner-fn lifting must give each lifted function a
program-unique name and carry its full captured-variable set regardless of
how many modules are linked. This blocks composing inner-lift-heavy contrib
modules on the C backend.

## P9 🟡 `str_of_int` emits `show_int()` without ensuring it's declared

Compiling a program that uses `str_of_int` (e.g. inside `contrib/json`'s
`parse_json`) but never uses `show` fails at `clang` with
`call to undeclared function 'show_int'`. The `show_int` runtime helper is
only emitted when `show` is used; `str_of_int` lowers to the same call but
doesn't trigger the helper's declaration. Works when the program also uses
`show` (mq does, so it's not blocked).

**Signal (upstream):** `str_of_int` should pull in the `show_int` helper
(set the same gating flag `show` does).
