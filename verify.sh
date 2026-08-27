#!/bin/sh
# verify.sh -- mq against jq, on the queries mq claims to support.
#
# WHAT THIS IS. mq is a jq-like CLI, and jq exists. So the oracle is not a
# recorded output from a previous run of mq -- it is a different program,
# written by other people, that answers the same question. A gate whose
# expected values came from the thing it is testing can only catch a change,
# never a mistake.
#
# THE SUBSET IS THE README'S, NOT jq's. mq claims `.`, field paths, indexing,
# `.[]` iteration, `|` pipes, `--csv`, and stdin. jq does far more, and asking
# mq for any of it would be testing a claim nobody made. Each case below is a
# line from the README's own list.
#
# CSV HAS ITS OWN ORACLE. jq cannot read CSV, so `--csv` is checked against the
# JSON that the same CSV means -- the header row as keys, one object per row --
# with jq answering the query on that. The two inputs are different spellings
# of one document, which is what makes them each other's check.
#
#   MERE=/path/to/mere sh verify.sh
#
# Needs jq on PATH. Skips loudly without it rather than passing: a differential
# with no oracle is not a weaker test, it is not a test.
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
MERE="${MERE:-mere}"
command -v "$MERE" >/dev/null 2>&1 || { echo "verify: no mere -- set MERE=/path/to/mere.exe" >&2; exit 1; }
command -v jq      >/dev/null 2>&1 || { echo "verify: SKIP -- no jq, and jq is the oracle"; exit 0; }
CC="${CC:-clang}"
command -v "$CC"   >/dev/null 2>&1 || { echo "verify: no C compiler -- set CC" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

"$MERE" -c "$ROOT/main.mere" > "$TMP/mq.c" 2>"$TMP/emit.err" \
  || { echo "verify: mere -c failed"; sed -n '1,3p' "$TMP/emit.err"; exit 1; }
"$CC" -O2 -w "$TMP/mq.c" -o "$TMP/mq" 2>"$TMP/cc.err" \
  || { echo "verify: the emitted C did not compile"; sed -n '1,3p' "$TMP/cc.err"; exit 1; }
MQ="$TMP/mq"

pass=0; fail=0

cat > "$TMP/d.json" <<'JSON'
{"user":{"name":"alice","age":30},"xs":[1,2,3],"items":[{"id":7,"name":"a"},{"id":9,"name":"b"}],"deep":{"a":{"b":{"c":"found"}}}}
JSON

# The CSV and the JSON below are the same document, spelled two ways.
cat > "$TMP/p.csv" <<'CSV'
name,city,age
alice,tokyo,30
bob,osaka,41
CSV
cat > "$TMP/p.json" <<'JSON'
[{"name":"alice","city":"tokyo","age":"30"},{"name":"bob","city":"osaka","age":"41"}]
JSON

check() {  # check <label> <query> <mq-args...> -- compares against jq on <oracle>
  label="$1"; q="$2"; input="$3"; oracle="$4"; csv="${5:-}"
  if [ -n "$csv" ]; then
    got="$("$MQ" --csv "$q" "$input" 2>&1)"
  else
    got="$("$MQ" "$q" "$input" 2>&1)"
  fi
  want="$(jq -c "$q" "$oracle" 2>&1)"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf '  ok    %-22s %s\n' "$label" "$q"
  else
    fail=$((fail + 1))
    printf '  FAIL  %-22s %s\n' "$label" "$q"
    printf '    mq: %s\n' "$(printf '%s' "$got"  | tr '\n' '|')"
    printf '    jq: %s\n' "$(printf '%s' "$want" | tr '\n' '|')"
  fi
}

# Milestone 1-2: identity and path queries.
check identity        '.'                 "$TMP/d.json" "$TMP/d.json"
check field           '.user'             "$TMP/d.json" "$TMP/d.json"
check nested-field    '.user.name'        "$TMP/d.json" "$TMP/d.json"
check deep-field      '.deep.a.b.c'       "$TMP/d.json" "$TMP/d.json"
check absent          '.nope'             "$TMP/d.json" "$TMP/d.json"
check absent-nested   '.user.nope'        "$TMP/d.json" "$TMP/d.json"
check index           '.xs[0]'            "$TMP/d.json" "$TMP/d.json"
check index-last      '.xs[2]'            "$TMP/d.json" "$TMP/d.json"
check index-field     '.items[1].id'      "$TMP/d.json" "$TMP/d.json"

# Milestone 3: streams and pipes.
check iterate         '.xs[]'             "$TMP/d.json" "$TMP/d.json"
check iterate-objects '.items[]'          "$TMP/d.json" "$TMP/d.json"
check pipe            '.items[] | .id'    "$TMP/d.json" "$TMP/d.json"
check pipe-two        '.items[] | .name'  "$TMP/d.json" "$TMP/d.json"
check pipe-chain      '.user | .name'     "$TMP/d.json" "$TMP/d.json"

# Milestone 4: CSV, against the JSON the same CSV means.
check csv-identity    '.'                 "$TMP/p.csv" "$TMP/p.json" csv
check csv-index       '.[0]'              "$TMP/p.csv" "$TMP/p.json" csv
check csv-field       '.[1].city'         "$TMP/p.csv" "$TMP/p.json" csv
check csv-iterate     '.[]'               "$TMP/p.csv" "$TMP/p.json" csv
check csv-pipe        '.[] | .name'       "$TMP/p.csv" "$TMP/p.json" csv

# Milestone 6: stdin. The same query through the pipe must give the same bytes
# as through the file -- and jq is still the oracle for both.
got="$("$MQ" '.items[] | .id' < "$TMP/d.json" 2>&1)"
want="$(jq -c '.items[] | .id' "$TMP/d.json" 2>&1)"
if [ "$got" = "$want" ]; then pass=$((pass + 1)); printf '  ok    %-22s %s\n' "stdin" ".items[] | .id"
else fail=$((fail + 1)); printf '  FAIL  %-22s mq=%s jq=%s\n' "stdin" "$got" "$want"; fi

got="$("$MQ" --csv '.[] | .city' < "$TMP/p.csv" 2>&1)"
want="$(jq -c '.[] | .city' "$TMP/p.json" 2>&1)"
if [ "$got" = "$want" ]; then pass=$((pass + 1)); printf '  ok    %-22s %s\n' "stdin-csv" ".[] | .city"
else fail=$((fail + 1)); printf '  FAIL  %-22s mq=%s jq=%s\n' "stdin-csv" "$got" "$want"; fi

# The exit status, which is not the output. A Mere program's main value is
# PRINTED, so returning an int put the digit on stdout and still exited 0 --
# `mq ... || handle` never fired and a pipeline was fed a line that is not
# JSON. Both directions, because only checking the failure would let a program
# that always exits 1 pass.
if "$MQ" '.user.name' "$TMP/d.json" >/dev/null 2>&1; then
  pass=$((pass + 1)); printf '  ok    %-22s exit 0 on success\n' "exit-status"
else
  fail=$((fail + 1)); printf '  FAIL  %-22s a successful query exited nonzero\n' "exit-status"
fi
if "$MQ" >/dev/null 2>&1; then
  fail=$((fail + 1)); printf '  FAIL  %-22s a usage error exited 0\n' "exit-status"
else
  pass=$((pass + 1)); printf '  ok    %-22s nonzero on a usage error\n' "exit-status"
fi

echo "verify: $pass passed, $fail failed  (oracle: $(jq --version))"
[ "$fail" -eq 0 ]
