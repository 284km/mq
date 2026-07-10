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
mq '.user.name' data.json          # → "alice"
mq '.items[]' data.json            # stream array elements
mq --csv '.[] | .name' people.csv  # query CSV as JSON
```

## Install

Prebuilt binary (no Mere toolchain or C compiler needed), once a release
is published:

```sh
curl -fsSL https://raw.githubusercontent.com/284km/mq/main/scripts/install.sh | sh
# installs to ~/.local/bin/mq (override with MQ_BINDIR)
```

Build from source — needs the [Mere](https://github.com/merelang/mere)
compiler + a C compiler:

```sh
mere install                       # fetch json/csv into .mere_modules/
mere -c main.mere > mq.c
clang -O2 mq.c -o mq
```

Distributing a Mere *app* is more involved than a normal binary: the build
needs the Mere toolchain (`mere` + `mere install`) and a C compiler. The
[release workflow](.github/workflows/release.yml) builds `mere` from source
at a pinned commit, then `mere install` + `mere -c | clang` produces native
`mq` binaries (macOS arm64 / Linux x86_64) on each `v*` tag.

## Milestones

0. ✅ **Native CLI I/O** (upstream Mere). Added `args()` (argv → str list)
   to the C backend so a native Mere program can read arguments (PAIN P1).
   stdin (read-all) and `exit` remain.
1. ✅ **Skeleton**: read a JSON file arg, parse, and print it back (the
   identity query `.`). Native binary end to end via `mere -c | clang`.
2. ✅ **Path queries** ← latest: `.`, `.a.b`, `.items[0]`, `.[1].name` —
   a tiny recursive-descent query parser (ADT `sel = Field | Index`) over
   the parsed `Json.json`; absent paths give `null`.
3. ✅ **Streams**: array/object iteration `.[]` and pipes `.items[] | .id`.
   Evaluation is stream-based (`json -> json list`, flat-mapped per
   selector); each result prints on its own line.
4. ✅ **CSV input**: `mq --csv '<query>' <file.csv>` turns CSV into a JSON
   array of objects (header row → keys) and queries it with the same
   engine. Uses `contrib/csv` (proper quoted-field handling). Composing
   csv + json first broke the C backend's inner-fn lifting (PAIN P8) — now
   fixed upstream, so mq imports contrib/csv directly.
5. ✅ **Distribution** ← latest: prebuilt binaries (macOS arm64 / Linux
   x86_64) on each `v*` tag + a `curl | sh` installer. CI builds the Mere
   compiler from source at a pinned commit, then `mere install` +
   `mere -c | clang`. Released as **v0.0.1**.

## Dependencies

Declared in [`mere.toml`](./mere.toml), installed with `mere install`:
`json` and `csv` from `merelang/mere` contrib. No Node host — `mq` is a
native binary.
