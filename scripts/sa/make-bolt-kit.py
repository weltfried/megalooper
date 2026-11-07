"""Build megalooper's "Bolt Kit" from two CC0 libraries by Karoryfer Samples.

  Big Rusty Drums  github.com/sfzinstruments/karoryfer.big-rusty-drums  (CC0-1.0)
  Frankensnare     github.com/sfzinstruments/karoryfer.frankensnare     (CC0-1.0)

Usage: python3 scripts/sa/make-bolt-kit.py DOWNLOAD_DIR [KITS_DIR] [--drive DB] [--dry]

  DOWNLOAD_DIR  where the FLACs are fetched to (kept, so a rebuild downloads nothing)
  KITS_DIR      default: presets/sa/drums/kits of this checkout
  --drive DB    how far each drum mic's loudest layer goes into the tanh (default 6, 0: off)
  --dry         measure and report, write nothing

megalooper lists the kit at its next start.

Downloads only the files the kit plays (round robin 1 of each velocity layer
it uses), measures them, and writes KITS_DIR/bolt.json plus KITS_DIR/bolt/*.flac:
the FLACs renamed, and trimmed where each falls TRIM_DB below its own peak,
with a 50 ms fade. Their recordings run on for seconds after the sound: the
trim takes the kit from 15 to about 11 MB, and its buffers from 130 to 93 MB.
Pure stdlib + afconvert.
"""
import json
import math
import wave
import os
import shutil
import struct
import array
import tempfile
import subprocess
import sys
import urllib.request


RAW = "https://raw.githubusercontent.com/sfzinstruments/karoryfer.%s/%s/Samples/%s"
BR, FS = "big-rusty-drums", "frankensnare"
# The commits the shipped kit was built from (both repos' main since April 2023).
COMMITS = {BR: "f07ce00df34a46b6b08375be56fe116cf15782bc",
           FS: "9151c2d79fcbb73c65d63f78918d4ba7abc91a81"}

# The steps' seven velocities (MegaSASteps.velocities); zone edges halfway between.
STEP_VELS = [10, 29, 49, 68, 88, 107, 127]
EDGES = [1] + [(a + b) // 2 + 1 for a, b in zip(STEP_VELS, STEP_VELS[1:])] + [128]

# A mic: (repo, folder, file prefix, group, offset dB, drive on?)
# Offsets follow the libraries' own SFZ defaults: tom overheads cc70 vs close
# cc100 (-3.1 dB); snare top cc60 vs bottom and overheads cc100 (-4.4 dB);
# cymbals on their overheads alone (close at cc40 is -7.9 dB, left out);
# kick overhead left off there (high-passed at 300 Hz when on): here -10 dB.
def mics(repo, base, prefix, kind):
    if kind == "drum":
        return [(repo, base + "/cl", prefix, "close", 0.0, True),
                (repo, base + "/oh", prefix, "room", -3.1, True)]
    if kind == "kick":
        return [(repo, base + "/kick", prefix, "close", 0.0, True),
                (repo, base + "/oh", prefix, "room", -10.0, True)]
    if kind == "snare":
        return [(repo, base + "/top", prefix, "close", -4.4, True),
                (repo, base + "/btm", prefix, "close", 0.0, True),
                (repo, base + "/oh", prefix, "room", 0.0, True)]
    if kind == "snare-clean":
        return [(r[0], r[1], r[2], r[3], r[4], False) for r in mics(repo, base, prefix, "snare")]
    if kind == "hat":
        return [(repo, base + "/cl", prefix, "close", 0.0, False),
                (repo, base + "/oh", prefix, "room", 0.0, False)]
    if kind == "cymbal":
        return [(repo, base + "/oh", prefix, "room", 0.0, False)]
    raise ValueError(kind)


# note: (name, mics, layers available, zones, pad trim dB, choke, retrigger, transpose)
PADS = {
    36: ("Kick 24", mics(BR, "kick_24/kick", "k", "kick"), 14, 7, 0, 0, True, 0),
    37: ("Sidestick", mics(BR, "snare_14/sidestick", "sn_ss", "snare-clean"), 4, 4, -6, 0, True, 0),
    38: ("Snare 12 Steel", mics(FS, "12_basic", "sn", "snare"), 7, 7, 0, 0, True, 0),
    39: ("Trash Stack", mics(BR, "stack_3_layer/ed", "st_ed", "cymbal"), 6, 3, -5, 0, False, 0),
    40: ("Rimshot 14 Alu", mics(FS, "14a_rimshot", "sr", "snare"), 3, 3, -1, 0, True, 0),
    41: ("Tom 22 Floor", mics(BR, "tom_22/center", "t22", "drum"), 7, 7, -1, 0, False, 0),
    42: ("HiHat Closed", mics(BR, "hihat_14/tc", "ht_tc", "hat"), 8, 7, -8, 1, False, 0),
    43: ("Tom 18 Floor", mics(BR, "tom_18/center", "t18", "drum"), 8, 7, -1, 0, False, 0),
    44: ("HiHat Pedal", mics(BR, "hihat_14/chik", "ht_chik", "hat"), 5, 3, -9, 1, False, 0),
    45: ("Tom 15", mics(BR, "tom_15/center", "t15", "drum"), 7, 7, -2, 0, False, 0),
    46: ("HiHat Open", mics(BR, "hihat_14/open", "ht_open", "hat"), 6, 3, -9, 1, False, 0),
    47: ("Tom 14", mics(BR, "tom_14/center", "t14", "drum"), 6, 6, -2, 0, False, 0),
    48: ("Tom 14 +3", mics(BR, "tom_14/center", "t14", "drum"), 6, 6, -2, 0, False, 3),
    49: ("Crash Ride 22 Edge", mics(BR, "ride_22/ed", "rd_ed", "cymbal"), 4, 3, -4, 0, False, 0),
    50: ("Tom 14 +6", mics(BR, "tom_14/center", "t14", "drum"), 6, 6, -3, 0, False, 6),
    51: ("Ride 22", mics(BR, "ride_22/rd", "rd", "cymbal"), 10, 3, -7, 0, False, 0),
}
# Toms panned by size, floor toms left, as a balance on the overheads too.
# Their own overheads put every tom right of centre.
TOM_PANS = {41: -0.35, 43: -0.2, 45: 0.0, 47: 0.15, 48: 0.25, 50: 0.35}
GROUP_NAMES = {"close": "Close mics", "room": "Room (overheads)"}
TARGET_DB = -18.0       # each pad's top zone, energy of its first 150 ms, before the trim
TRIM_DB = 60.0          # a file ends where its 10 ms peaks stay this far below its own peak
FADE_SECS = 0.05        # ...with this fade, which starts at that point
VEL = {"law": "simpler", "amount": 0.15}


def zone_layers(n, k):
    """k zones over the seven step velocities -> (velLo, velHi, vl) each."""
    k = min(k, n)
    groups = [min(k - 1, i * k // 7) for i in range(7)]
    s = min(3.0, (n - 1) / (k - 1)) if k > 1 else 0
    out = []
    for j in range(k):
        steps = [i for i, g in enumerate(groups) if g == j]
        lo, hi = EDGES[steps[0]], EDGES[steps[-1] + 1] - 1
        vl = int(round(n - s * (k - 1 - j)))
        out.append((lo, hi, vl))
    return out


def fetch(dl, repo, rel):
    out = os.path.join(dl, repo, rel)
    if not os.path.exists(out) or os.path.getsize(out) == 0:
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with urllib.request.urlopen(RAW % (repo, COMMITS[repo], rel), timeout=60) as r, open(out + ".part", "wb") as f:
            shutil.copyfileobj(r, f)
        os.replace(out + ".part", out)
    return out


def read_wav16(path):
    """16-bit PCM WAV, plain or WAVE_FORMAT_EXTENSIBLE (the wave module refuses that)."""
    with open(path, "rb") as f:
        b = f.read()
    assert b[:4] == b"RIFF" and b[8:12] == b"WAVE", "not a WAV"
    pos, ch, sr, data = 12, None, None, None
    while pos + 8 <= len(b):
        cid, size = b[pos:pos + 4], struct.unpack("<I", b[pos + 4:pos + 8])[0]
        body = b[pos + 8:pos + 8 + size]
        if cid == b"fmt ":
            _, ch, sr, _, _, bits = struct.unpack("<HHIIHH", body[:16])
            assert bits == 16, "bits %d" % bits
        elif cid == b"data":
            data = array.array("h", body[:len(body) // 2 * 2])
        pos += 8 + size + (size & 1)
    return ch, sr, data



_cache = {}
_decoded = {}
TMP = tempfile.mkdtemp(prefix="bolt-kit-")


def decode(path):
    if path not in _decoded:
        tmp = os.path.join(TMP, "s.wav")
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16", path, tmp], check=True, timeout=60)
        _decoded[path] = read_wav16(tmp)
    return _decoded[path]


def cut_frames(path):
    """Where the file ends: past its last 10 ms window within TRIM_DB of its peak, plus the fade."""
    ch, sr, data = decode(path)
    frames, win = len(data) // ch, sr // 100
    env = []
    for i in range(0, frames, win):
        seg = data[i * ch:(i + win) * ch]
        env.append(max(abs(min(seg)), abs(max(seg))))
    thr = max(env) * 10 ** (-TRIM_DB / 20)
    last = max(i for i, e in enumerate(env) if e > thr)
    return min(frames, (last + 1) * win + int(FADE_SECS * sr))


def write_trimmed(path, dest):
    ch, sr, data = decode(path)
    n, fade = cut_frames(path), int(FADE_SECS * sr)
    out = array.array("h", data[:n * ch])
    for k in range(min(fade, n)):
        g = 1 - k / fade
        for c in range(ch):
            j = (n - fade + k) * ch + c
            if j >= 0:
                out[j] = int(out[j] * g)
    wav, flac = os.path.join(TMP, "t.wav"), os.path.join(TMP, "t.flac")
    w = wave.open(wav, "wb")
    w.setnchannels(ch)
    w.setsampwidth(2)
    w.setframerate(sr)
    w.writeframes(out.tobytes())
    w.close()
    subprocess.run(["afconvert", "-f", "flac", "-d", "flac", wav, flac], check=True, timeout=60)
    shutil.copyfile(flac, dest)


def stats(path, drive_db):
    key = (path, drive_db)
    if key in _cache:
        return _cache[key]
    ch, sr, data = decode(path)
    g = 10 ** (drive_db / 20) if drive_db > 0 else 1.0
    n = int(0.15 * sr)
    chans = [[v / 32768.0 for v in data[c::ch][:n]] for c in range(ch)]
    if drive_db > 0:
        chans = [[math.tanh(v * g) for v in c] for c in chans]
    energy = [sum(v * v for v in c) / max(1, len(c)) for c in chans]
    peak = max(abs(v) for c in chans for v in c)
    allpeak = max(abs(v) for v in data) / 32768.0
    res = {"ch": ch, "sr": sr, "frames": len(data) // ch, "energy": sum(energy) / ch,
           "lr": (energy[0], energy[1]) if ch == 2 else None, "peak": peak, "rawpeak": allpeak}
    _cache[key] = res
    return res


def db(x):
    return 10 * math.log10(x) if x > 0 else -200.0


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dl = args[0]
    kits = args[1] if len(args) > 1 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "..", "presets", "sa", "drums", "kits")
    drive_x = 6.0
    if "--drive" in sys.argv:
        drive_x = float(sys.argv[sys.argv.index("--drive") + 1])
    dry = "--dry" in sys.argv
    pads_out, copies, report = {}, {}, []
    total_bytes = 0
    for note, (name, ms, n, k, trim, choke, retrig, transpose) in sorted(PADS.items()):
        zones = zone_layers(n, k)
        # files per zone and mic
        zfiles = []
        for lo, hi, vl in zones:
            row = []
            for repo, folder, prefix, group, off, drv in ms:
                rel = "%s/%s_vl%d_rr1.flac" % (folder, prefix, vl)
                row.append((fetch(dl, repo, rel), repo, rel, group, off, drv))
            zfiles.append(row)
        # drive per mic: the loudest zone's raw peak goes drive_x dB into tanh
        drives = {}
        for path, repo, rel, group, off, drv in zfiles[-1]:
            raw = stats(path, 0)["rawpeak"]
            drives[(repo, rel.rsplit("/", 1)[0])] = (drive_x - 20 * math.log10(raw)) if drv and drive_x > 0 else 0.0
        # pad gain from the top zone's summed energy, after drive
        e = 0.0
        lr = [0.0, 0.0]
        for path, repo, rel, group, off, drv in zfiles[-1]:
            st = stats(path, drives[(repo, rel.rsplit("/", 1)[0])])
            e += st["energy"] * 10 ** (off / 10)
            if group == "room" and st["lr"]:
                lr[0] += st["lr"][0]
                lr[1] += st["lr"][1]
        pad_gain = TARGET_DB - db(e)
        # where the drum sits in its overheads: -1 left .. 1 right
        bal = 0.0
        if lr[0] + lr[1] > 0:
            bal = (lr[1] - lr[0]) / (lr[1] + lr[0])
        pan = TOM_PANS.get(note, 0.0)
        layers = []
        for (lo, hi, vl), row in zip(zones, zfiles):
            for path, repo, rel, group, off, drv in row:
                folder = rel.rsplit("/", 1)[0]
                mic = folder.rsplit("/", 1)[1]
                src = "BR" if repo == BR else "FS"
                fname = "%s %s %s vl%d.flac" % (src, folder.rsplit("/", 1)[0].replace("/", " "), mic, vl)
                dest = "bolt/" + fname
                if dest not in copies:
                    copies[dest] = path
                    total_bytes += 4 * stats(path, 0)["ch"] * cut_frames(path)
                layers.append({
                    "group": group, "file": dest, "gainDb": round(pad_gain + off, 2),
                    "transpose": float(transpose), "velLo": lo, "velHi": hi,
                    "startFrames": 0, "lenSecs": 0.0, "drive": round(drives[(repo, folder)], 1),
                    "vel": dict(VEL)})
        pads_out[str(note)] = {
            "name": name, "choke": choke, "retrigger": retrig, "pan": pan, "gainDb": float(trim),
            "beatRepeat": False, "repeatFilter": False, "layers": layers}
        report.append("%d %-20s zones %s gain %+.1f trim %+d pan %+.2f drive %s" % (
            note, name, [(lo, hi, vl) for lo, hi, vl in zones], pad_gain, trim, pan,
            sorted(set(round(v, 1) for v in drives.values()))))
    kit = {
        "version": 1, "key": "bolt", "name": "Bolt Kit",
        "description": "A big, loud, roomy acoustic kit: 24\" kick, deep floor toms, a tight steel "
                       "snare, rides played as crashes, a trash stack; close mics and room as two "
                       "trims, driven into saturation",
        "source": "Karoryfer Samples, CC0 1.0: Big Rusty Drums (github.com/sfzinstruments/"
                  "karoryfer.big-rusty-drums) and Frankensnare (github.com/sfzinstruments/"
                  "karoryfer.frankensnare), FLACs renamed and trimmed (each ends %.0f dB below its own "
                  "peak, %.0f ms fade). The map is CC0 too" % (TRIM_DB, FADE_SECS * 1000),
        "groups": GROUP_NAMES,
        "notes": [
            "Assembled 2026-11-07: a big, loud kit in a room, kick and snare up front, floor toms "
            "left, rides played as crashes, the drums run into saturation. Samples chosen by "
            "measurement.",
            "Big Rusty Drums (Szpaderski, Poland): 24x18 kick, 22x16 / 18x16 floor toms, 15x15 and "
            "14x14 toms, 14\" hats, 22\" Sabian Big & Ugly ride (bow on 51, edge as the crash-ride on "
            "49), a three-cymbal stack (39) as a trashy crash. Frankensnare: 12x5 steel snare (38, "
            "the tightest and highest, about 276 Hz) and the 14x8 aluminium snare's rimshot (40).",
            "Pads 48 and 50 are the 14\" tom transposed +3 and +6 semitones, so General MIDI "
            "patterns find six toms.",
            "Velocity: the steps' seven velocities (10 29 49 68 88 107 127) each play their own "
            "recording where a drum has seven layers, so rolls (x0.7 per hit) walk down through "
            "different hits; law simpler 0.15 on top. Round robin 1 of each layer only.",
            "Mics: groups 'close' and 'room' (the overheads; cymbals play from them alone). Offsets "
            "from the libraries' own SFZ defaults: tom room -3.1 dB, snare top -4.4 dB under bottom "
            "and room, kick room -10 dB (unfiltered).",
            "Drive: each drum mic's loudest layer goes %.0f dB into the voice's tanh (drive = %.0f dB "
            "minus its raw peak), the softer layers less; hats and cymbals clean. Level: each pad's "
            "top zone at %.0f dB energy over its first 150 ms after drive, then the pad trims "
            "(gainDb). Toms panned by size, floor toms left; sidestick clean." % (drive_x, drive_x, TARGET_DB),
            "Made by scripts/sa/make-bolt-kit.py. The samples are CC0, so megalooper ships the kit "
            "with its audio, as it does the Analog Kit.",
        ],
        "pads": pads_out,
    }
    print("\n".join(report))
    print("files %d, buffer memory %.0f MB (trimmed)" % (len(copies), total_bytes / 1e6))
    if dry:
        return
    os.makedirs(os.path.join(kits, "bolt"), exist_ok=True)
    for dest, src in copies.items():
        write_trimmed(src, os.path.join(kits, dest))
    with open(os.path.join(kits, "bolt.json"), "w") as f:
        json.dump(kit, f, indent=1)
        f.write("\n")
    print("wrote", os.path.join(kits, "bolt.json"))


if __name__ == "__main__":
    main()
