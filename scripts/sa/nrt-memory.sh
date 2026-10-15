#!/bin/bash
# The real-time pool a whole Megalooper SA set takes, for MegaSA.memReserve
# (docs/dev/device-chains.md, phase 2): bisects NRT_SESSION_MEMKB over
# scripts/sa/nrt-session.scd's renders (MegaSA with both chains, the drums with
# their reverb, the Looper's engine and master, the session recorder, the
# drums' voices) down to the smallest pool, in steps of STEP KB, in which no
# allocation fails. Offline, one sclang at a time on a far UDP port, about
# 30 s a step.
#
#     scripts/sa/nrt-memory.sh [sclang arguments, e.g. -l my.yaml]
#
# What the set does not hold is MegaSA.memReserve's to add: the take
# recorder, the analysis monitors, the grains and up to four cutter voices
# with their reverb and comb.
here=$(cd "$(dirname "$0")" && pwd)
sclang=${SCLANG:-/Applications/SuperCollider.app/Contents/MacOS/sclang}
step=${STEP:-512}
lo=${LO:-1024}
hi=${HI:-65536}
# How many allocations failed in a pool of $1 KB: a number only for a run
# that rendered to the end, passing, or failing with allocations among its
# failures. Anything else (it did not finish, or failed for another reason)
# is "unfinished", and the bisection stops there rather than count it as fitting.
fails() {
    local out n
    out=$(NRT_SESSION_MEMKB=$1 perl -e 'alarm shift; exec @ARGV' 900 "$sclang" -u $((58100 + RANDOM % 800)) "${args[@]}" \
        "$here/nrt-session.scd" 2>&1)
    n=$(printf '%s\n' "$out" | grep -c "scsynth:.*\(alloc\|memory\)")
    if printf '%s\n' "$out" | grep -q "NRT SESSION PASSED"; then echo "$n"; return; fi
    if [ "$n" != "0" ] && printf '%s\n' "$out" | grep -q "NRT SESSION FAILED"; then echo "$n"; return; fi
    echo "unfinished"
}
args=("$@")
n=$(fails "$hi")
if [ "$n" != "0" ]; then echo "even $hi KB does not pass ($n)"; exit 1; fi
while [ $((hi - lo)) -gt "$step" ]; do
    mid=$(( (lo + hi) / 2 ))
    n=$(fails "$mid")
    if [ "$n" = "unfinished" ]; then echo "$mid KB: the set did not render to the end, or failed for another reason; stopping"; exit 1; fi
    echo "$mid KB: $n allocation failure(s)"
    if [ "$n" = "0" ]; then hi=$mid; else lo=$mid; fi
done
echo "SMALLEST POOL $hi KB"
