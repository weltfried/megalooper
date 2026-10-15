#!/usr/bin/env python3
"""The controller streams the MIDI tests replay, cut from megalooper's log.

    python3 tools/midi-log-streams.py [path to megalooper.log]

Reads the log the Desktop launcher writes (~/Library/Logs/megalooper.log by
default), whose "cc       num=7 val=68 chan=0" lines are every CC megalooper
heard, and writes two fixtures into scripts/tests/fixtures/, values only (no
times, no devices):
  pedal-streams.json   the TSMega expression pedal's CC in a few launches;
                       test-midimap.scd replays them through its hysteresis
  switch-streams.json  its CC footswitches (80, 81) and the CC 0 sweeps it
                       sends now and then; test-midimap-learn.scd learns from
                       them
Each stream is named in STREAMS by its launch's banner time and its CC number.
"""
import json
import os
import re
import sys

STREAMS = [
    # file, name, launch banner, CC, what it is
    ("pedal-streams.json", "sa-resting", "2026-10-05 10:37:01", 7,
     "untouched on the SA rig: CC 7 hopping between 68 and 69"),
    ("pedal-streams.json", "sa-resting-wide", "2026-10-06 21:51:29", 7,
     "untouched on the SA rig, reaching 70 now and then"),
    ("pedal-streams.json", "sa-played", "2026-10-07 11:03:24", 7,
     "played on the SA rig, between 41 and 108"),
    ("pedal-streams.json", "cc4-resting", "2026-09-05 19:23:34", 4,
     "CC 4, the pedal's number until 2026-09-18, parked at 125-126"),
    ("switch-streams.json", "cc80-0922", "2026-09-22 20:34:28", 80,
     "the CC 80 footswitch, 64 then 0, one message a press, with its one 64-64 repeat"),
    ("switch-streams.json", "cc81-0918", "2026-09-18 14:21:39", 81,
     "the CC 81 footswitch, 64 then 0"),
    ("switch-streams.json", "cc81-0922", "2026-09-22 20:34:28", 81,
     "CC 81's 64-64 repeat"),
    ("switch-streams.json", "cc0-0922", "2026-09-22 20:34:28", 0,
     "a CC 0 sweep, 74 to 97"),
    ("switch-streams.json", "cc0-0928", "2026-09-28 10:37:39", 0,
     "CC 0 sweeps: 96 to 125, then 69 to 90 twice"),
    ("switch-streams.json", "cc0-1006", "2026-10-06 21:51:29", 0,
     "a CC 0 sweep, 52 to 69"),
]

LAUNCH = re.compile(r"^=== megalooper launch (\S+ \S+) ===")
CC = re.compile(r"^cc\s+num=(\d+) val=(\d+) chan=(\d+)")


def main():
    log = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser(
        "~/Library/Logs/megalooper.log")
    wanted = {}
    for _, name, launch, cc, _ in STREAMS:
        wanted.setdefault((launch, cc), []).append(name)
    values = {name: [] for _, name, _, _, _ in STREAMS}
    launch = None
    with open(log, errors="replace") as f:
        for line in f:
            m = LAUNCH.match(line)
            if m:
                launch = m.group(1)
                continue
            m = CC.match(line)
            if m:
                for name in wanted.get((launch, int(m.group(1))), []):
                    values[name].append(int(m.group(2)))
    missing = [name for name, v in values.items() if not v]
    if missing:
        sys.exit("not in the log: " + ", ".join(missing))
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    for fname in sorted({s[0] for s in STREAMS}):
        out = os.path.join(root, "scripts", "tests", "fixtures", fname)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        mine = [s for s in STREAMS if s[0] == fname]
        # One stream per line, so a diff shows which one changed.
        lines = ['{"format": "megalooper midi streams", "version": 1,',
                 ' "source": "megalooper.log, cut by tools/midi-log-streams.py",',
                 ' "streams": [']
        for i, (_, name, launch, cc, note) in enumerate(mine):
            entry = json.dumps({"name": name, "launch": launch, "cc": cc,
                                "note": note, "values": values[name]},
                               separators=(", ", ": "))
            lines.append("  " + entry + ("," if i < len(mine) - 1 else ""))
        lines.append(" ]}")
        with open(out, "w") as f:
            f.write("\n".join(lines) + "\n")
        print("wrote " + out)
    for _, name, _, cc, _ in STREAMS:
        v = values[name]
        print("%-16s CC %3d: %5d values, %d-%d" % (name, cc, len(v), min(v), max(v)))


if __name__ == "__main__":
    main()
