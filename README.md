# mq

A small `jq`-like JSON/CSV query & transform CLI, written in
[Mere](https://github.com/merelang/mere) and compiled to a **native
binary** (via the C backend: `mere -c | clang`).

This is a second dogfood app for Mere, in a deliberately different domain
from [mere-notes](https://github.com/284km/mere-notes) (a realtime web
app on the Wasm + Node host). `mq` exercises the parts mere-notes never
touched: the **native C/LLVM backends**, **CLI I/O** (argv, stdin, exit
codes, stderr), and **native binary distribution**. See [PAIN.md](./PAIN.md)
— the friction log is the point of this project as much as the tool is.

## Goal

```sh
echo '{"user":{"name":"alice","age":30}}' | mq '.user.name'   # → "alice"
mq '.items[]' data.json                                        # stream array
mq --csv '.[] | .price' sales.csv                              # CSV in
```

## Milestones

0. **Native CLI I/O** (upstream Mere). The C/LLVM backends don't implement
   `args` / `read_line` (stdin) / `exit` — a native Mere program can't
   read argv or stdin yet (PAIN P1). Add them to the C backend runtime so
   Mere can be a native CLI at all.
1. **Skeleton**: read JSON from stdin or a file arg, pretty-print it back
   (the identity query `.`), exit 0/1. Native binary end to end.
2. **Path queries**: `.field`, `.a.b`, `.[i]` — parse the query (a tiny
   ADT/recursive-descent parser, Mere's strength) and apply to the value.
3. **Pipes & filters**: `.a | .b`, array iteration `.[]`, `select`.
4. **CSV**: `--csv` input/output via `contrib/csv`, bridging JSON↔CSV.
5. **Distribution**: how a user gets the `mq` binary (build via `mere -c`
   + clang; a release workflow / `mere install`-assisted build) — a
   different story from mere-notes' `mere serve`.

## Dependencies

Declared in [`mere.toml`](./mere.toml), installed with `mere install`:
`json` and `csv` from `merelang/mere` contrib. No Node host — `mq` is a
native binary.
