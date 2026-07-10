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

## P2 🟡 C backend ignores shadowing of the concurrency `join` builtin

Hit incidentally while testing `args`: a user-defined `let rec join = …`
compiled to `pthread_join(t.tid, …)` — the C backend matched the name
against the Q-012 thread-`join` builtin instead of the local binding, then
failed to compile (`no member named 'tid' in struct list_str_node`).
Builtin names used as ordinary identifiers aren't shadow-checked in the C
backend's `App` dispatch. Worked around by renaming (`sjoin`).

**Signal (upstream):** the C backend's `Ast.Var "<builtin>"` dispatch
should first check whether the name is locally bound (shadowed) before
treating it as the builtin — the interpreter and typer already respect
shadowing.
