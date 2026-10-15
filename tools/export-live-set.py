#!/usr/bin/env python3
"""Export what Megalooper SA needs from the Ableton Live set, standard library only.

Megalooper SA (docs/dev/megalooper-sa.md) takes over the jobs the Live set does
today. Three things in that set are data SA can reuse rather than rebuild, and
an .als file is gzipped XML, so they can be read without Live running:

    python3 tools/export-live-set.py inventory   # tracks, device chains, MIDI mappings
    python3 tools/export-live-set.py biasfx      # each BIAS FX instance's state as an .fxb
    python3 tools/export-live-set.py steps       # every Rhythmic Steps device as JSON
    python3 tools/export-live-set.py drumrender  # what Live needs to render the kits
    python3 tools/export-live-set.py variations  # the effect racks' macro states
    python3 tools/export-live-set.py kits        # SA's drum kits, from audio on this Mac
    python3 tools/export-live-set.py all         # biasfx + steps + variations
    ... --set path/to/other.als                  # any set; default: megalooper-slave.als

    python3 tools/export-live-set.py kits --only carbon-layer,one-hit
    python3 tools/export-live-set.py kits --adg path/to/Kit.adg --key my-kit
    python3 tools/export-live-set.py kits --folder path/to/one-shots --key my-kit
    python3 tools/export-live-set.py kits --check  # every kit against its files

`inventory` prints what is on and what the footswitches toggle: the source of
the tables in docs/dev/megalooper-sa.md, rerun when the set changes.

`biasfx` writes presets/sa/biasfx/<track>-<preset>.fxb. Live hosts the VST2
build of BIAS FX 2 and stores the plugin's opaque bank chunk; wrapped in the
standard .fxb header, VSTPluginController:readBank loads it, so SA starts from
the exact guitar sound of the Live set. Regenerated, not committed.

`steps` writes presets/sa/rhythmic-steps.json: per device, the step lanes from
the Max device's saved blob (hex-encoded JSON) plus its 59 parameters.

`drumrender` prepares the one job only Live can do: playing its drum kits
(Operator voices, nested racks, per-pad effects) into audio files SA can load.
For every track whose instrument is a Drum Rack it writes presets/sa/drums/
<kit>.mid, every pad at the seven velocities Rhythmic Steps uses, one hit per
bar after a bar of silence, and <kit>.json, the map of which hit is which. It
also writes megalooper-drum-render.als, a copy of the set changed in exactly
three ways, by text replacement so nothing else moves: the kits' Beat Repeats
off (they repeat at random, which a one-shot must not capture), Rhythmic Steps
off, and the kit tracks' monitoring from In to Auto, so a clip on them plays.
The steps for Live are in docs/dev/megalooper-sa.md, Phase 4.

`kits` builds the sample kits SA's drums play, since Live's own pack samples
are encrypted (AIFC 'able') and cannot be rendered here. Per kit it writes
presets/sa/drums/kits/<key>.json (committed: MegaSAKit's schema, version 1)
and copies the audio it plays into presets/sa/drums/kits/<key>/ (git-ignored:
Ableton's audio is never committed). It reads only plain audio installed with
Live 12 Suite and writes nowhere else:
  carbon        Kit-Carbon: Designer Drums' recordings of the set's 15 pads,
                balanced by a fit to Ableton's preview of the whole kit and
                levelled against Live's own recordings of the set
  carbon-layer  carbon plus Core Library stand-ins for its KJ Sawka 9 layer
                (the default steps kit)
  one-hit       stand-ins for the One Hit Kit (the default onset kit)
  core-808 core-909 core-dry-session core-707 core-c78 core-flares
                Core Library Drum Racks converted as they are, but for a pad
                far over the kit's others, brought down to 6 dB over them
  _ir           Hybrid Reverb's true-stereo pair as four mono 48 kHz paths
--only picks among these. --adg converts any Drum Rack preset whose samples
are readable (with the same rule for a pad far over the others); --folder
makes a kit of a folder of one-shots, by words in the file names (kick, snare,
rim/side, clap, hat closed/chh, pedal, open/ohh, toms low to high, crash,
ride, perc) and lists the files it could not place. --check validates every
kit JSON against its files, and that no pad plays more than 6 dB over its
kit's median at velocity 127, and prints a table.

Targets Python 3.9, following tools/coreaudio.py.
"""

import argparse
import array
import gzip
import json
import math
import os
import re
import shutil
import statistics
import struct
import sys
import xml.etree.ElementTree as ET
from fractions import Fraction

DEFAULT_SET = os.path.expanduser(
    "~/Library/Mobile Documents/com~apple~CloudDocs/"
    "sketch-template_live_12 Project/megalooper-slave.als")
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(REPO, "presets", "sa")

# Device elements whose children are not devices; skipped when walking chains.
MX_PARAMS = ("MxDFloatParameter", "MxDIntParameter", "MxDEnumParameter", "MxDBoolParameter")


def load_set(path):
    with gzip.open(path) as f:
        root = ET.fromstring(f.read())
    return root, {child: parent for parent in root.iter() for child in parent}


def value(el, path):
    found = el.find(path)
    return found.get("Value") if found is not None else None


def track_name(track):
    return value(track, "Name/EffectiveName") or value(track, "Name/UserName") or "?"


def owner_track(el, parents):
    while el is not None and el.tag not in ("AudioTrack", "MidiTrack", "GroupTrack",
                                            "ReturnTrack", "MasterTrack"):
        el = parents.get(el)
    return el


def branch_name(el, parents):
    while el is not None and not el.tag.endswith("Branch"):
        el = parents.get(el)
    if el is None:
        return None
    return value(el, "Name/EffectiveName") or value(el, "Name/UserName") or value(el, "Name")


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-") or "unnamed"


# --------------------------------------------------------------------------
# inventory
# --------------------------------------------------------------------------
def device_label(dev):
    label = dev.tag
    user = value(dev, "UserName")
    if user:
        label += " '" + user + "'"
    if dev.tag == "PluginDevice":
        label += " [" + (value(dev, ".//PluginDesc//PlugName") or "?") + "]"
    if dev.tag.startswith("MxDevice"):
        path = value(dev, ".//PatchSlot//FileRef//Path") or value(dev, ".//PatchSlot//FileRef//RelativePath")
        if path:
            label += " [" + os.path.basename(path.rstrip("/")) + "]"
    return label


def print_chain(devices, depth):
    for dev in devices:
        on = value(dev, "On/Manual")
        print("  " * depth + "- " + device_label(dev) + ("" if on == "true" else "  (off)"))
        for branch in dev.findall("./Branches/*"):
            name = value(branch, "Name/EffectiveName") or value(branch, "Name") or ""
            print("  " * (depth + 1) + "[" + branch.tag + (" " + name if name else "") + "]")
            inner = branch.find("DeviceChain/*/Devices")
            if inner is not None:
                print_chain(inner, depth + 2)


def mapping_target(el, parents):
    """What a KeyMidi mapping controls: the device (or track) holding it."""
    names = []
    node = el
    while node is not None and node.tag not in ("Tracks", "LiveSet"):
        user = value(node, "UserName")
        if node.tag in ("DeviceChain", "Devices", "Branches", "MidiToAudioDeviceChain",
                        "AudioToAudioDeviceChain", "MidiToMidiDeviceChain"):
            pass
        elif node.tag.endswith("Track"):
            names.append("track '" + track_name(node) + "'")
            break
        else:
            names.append(node.tag + (" '" + user + "'" if user else ""))
        node = parents.get(node)
    return " < ".join(names)


def cmd_inventory(root, parents, args):
    live = root.find("LiveSet")
    tracks = list(live.find("Tracks"))
    master = live.find("MasterTrack")
    for track in tracks + ([master] if master is not None else []):
        chain = track.find("DeviceChain")
        audio_in = value(chain, "AudioInputRouting/Target") or ""
        midi_in = value(chain, "MidiInputRouting/Target") or ""
        out = value(chain, "AudioOutputRouting/Target") or ""
        print("\n## %s '%s'" % (track.tag, track_name(track)))
        print("   in: %s   midi in: %s   out: %s" % (audio_in, midi_in, out))
        devices = chain.find("DeviceChain/Devices")
        if devices is not None:
            print_chain(devices, 1)

    print("\n## MIDI mappings (channel 1-16; Live stores unmapped as -1)")
    for km in root.iter("KeyMidi"):
        channel = int(value(km, "Channel") or -1)
        if not 0 <= channel <= 15:
            continue
        is_note = value(km, "IsNote") == "true"
        number = value(km, "NoteOrController")
        target = parents[km]
        what = target.tag
        print("   ch%-2d %-6s %-4s %-22s %s" % (
            channel + 1, "note" if is_note else "cc", number, what,
            mapping_target(parents.get(target), parents)))
    return 0


# --------------------------------------------------------------------------
# biasfx
# --------------------------------------------------------------------------
def fxb_bank(chunk, fx_id, fx_version, num_programs):
    """An opaque-chunk VST2 bank file ('FBCh'), big-endian, as hosts write it."""
    body = (b"FBCh" + struct.pack(">iiii", 1, fx_id, fx_version, num_programs)
            + bytes(128) + struct.pack(">i", len(chunk)) + chunk)
    return b"CcnK" + struct.pack(">i", len(body)) + body


def cmd_biasfx(root, parents, args):
    out_dir = os.path.join(args.out, "biasfx")
    written = 0
    for dev in root.iter("PluginDevice"):
        info = dev.find("PluginDesc/VstPluginInfo")
        if info is None or "BIAS FX" not in (value(info, "PlugName") or ""):
            continue
        preset = info.find("Preset/VstPreset")
        chunk_type = int(value(preset, "Type") or 0)
        if chunk_type != struct.unpack(">i", b"FBCh")[0]:
            print("skipping a BIAS FX instance whose state is not a bank chunk (type %d)"
                  % chunk_type, file=sys.stderr)
            continue
        chunk = bytes.fromhex("".join(preset.find("Buffer").text.split()))
        try:
            state = json.loads(chunk.rstrip(b"\x00").decode("utf-8"))
            name = state["appModel"]["project"]["liveSigPath"]["currentPresetName"]
        except (ValueError, KeyError):
            name = "state"
        track = track_name(owner_track(dev, parents))
        os.makedirs(out_dir, exist_ok=True)
        path = os.path.join(out_dir, "%s-%s.fxb" % (slug(track), slug(name)))
        with open(path, "wb") as f:
            f.write(fxb_bank(chunk, int(value(preset, "UniqueId")),
                             int(value(preset, "PluginVersion")),
                             int(value(preset, "ProgramCount") or 1)))
        print("%s  (track '%s', preset '%s', %s, %d in / %d out, %s)" % (
            os.path.relpath(path, REPO), track, name, value(info, "Path"),
            int(value(info, "NumAudioInputs") or 0), int(value(info, "NumAudioOutputs") or 0),
            "on" if value(dev, "On/Manual") == "true" else "off"))
        written += 1
    if written == 0:
        print("no BIAS FX instance in the set", file=sys.stderr)
        return 1
    return 0


# --------------------------------------------------------------------------
# steps
# --------------------------------------------------------------------------
def cmd_steps(root, parents, args):
    devices = []
    for dev in root.iter("MxDeviceMidiEffect"):
        path = value(dev, ".//PatchSlot//FileRef//Path") or ""
        if "Rhythmic Steps" not in path:
            continue
        blob = next(dev.iter("Blob"), None)
        lanes = {}
        if blob is not None and blob.text:
            raw = bytes.fromhex("".join(blob.text.split())).rstrip(b"\x00")
            lanes = json.loads(raw.decode("utf-8"))
        params = {}
        for p in dev.iter():
            if p.tag in MX_PARAMS:
                v = value(p, "Timeable/Manual")
                if v is not None:
                    v = float(v) if p.tag == "MxDFloatParameter" else int(float(v))
                params[value(p, "Name")] = v
        devices.append({
            "track": track_name(owner_track(dev, parents)),
            "branch": branch_name(dev, parents),
            "on": value(dev, "On/Manual") == "true",
            "lanes": {k: lanes[k] for k in sorted(lanes)},
            "parameters": params,
        })
    if not devices:
        print("no Rhythmic Steps device in the set", file=sys.stderr)
        return 1
    os.makedirs(args.out, exist_ok=True)
    path = os.path.join(args.out, "rhythmic-steps.json")
    text = json.dumps({
        "source": os.path.basename(args.set),
        "notes": "Step values are 0-6 as the device stores them. Lane.maxpat draws "
                 "'random 6' for chance and alt and scales velocity 0-6 to 10-127, "
                 "so chance k probably fires with probability k/6; confirm before "
                 "relying on it. Lanes are 1-4; 'Pad Note n' is lane n's note.",
        "devices": devices,
    }, indent=1)
    # One lane per line: a step grid reads (and diffs) as a row, not a column.
    text = re.sub(r"\[\s+([-0-9.,\s]+?)\s+\]",
                  lambda m: "[" + " ".join(m.group(1).split()) + "]", text)
    with open(path, "w") as f:
        f.write(text + "\n")
    print("%s  (%d devices: %s)" % (os.path.relpath(path, REPO), len(devices),
                                    ", ".join(str(d["branch"]) for d in devices)))
    return 0


# --------------------------------------------------------------------------
# drumrender
# --------------------------------------------------------------------------
# Rhythmic Steps scales its velocity steps 0-6 to 10-127 (Lane.maxpat) and
# truncates; re-derived step by step for Phase 4, these are the seven levels the
# kits are ever played at. The render files already in presets/sa/drums/
# (kit-carbon.mid, one-hit-kit.mid and their .json maps) were written with an
# earlier, rounded table, [10, 30, 49, 69, 88, 108, 127], and are left as they
# are: SA now plays sample kits (`kits`) instead of a render.
RENDER_VELOCITIES = [10, 29, 49, 68, 88, 107, 127]


def vlq(n):
    """A MIDI variable-length quantity."""
    out = [n & 0x7F]
    n >>= 7
    while n:
        out.insert(0, (n & 0x7F) | 0x80)
        n >>= 7
    return bytes(out)


def write_midi(path, hits, ppq=480, bpm=120):
    """A format-0 MIDI file: hits are (beat, note, velocity), each a 16th long.
    Live places dropped notes by beat and keeps its own tempo."""
    events = []
    for beat, note, vel in hits:
        tick = int(round(beat * ppq))
        events.append((tick, 1, bytes([0x90, note, vel])))
        events.append((tick + ppq // 4, 0, bytes([0x80, note, 0])))
    events.sort(key=lambda e: (e[0], e[1]))   # a note-off before a note-on at one tick
    track = bytearray(vlq(0) + b"\xff\x51\x03" + (60000000 // bpm).to_bytes(3, "big"))
    last = 0
    for tick, _, data in events:
        track += vlq(tick - last) + data
        last = tick
    track += vlq(0) + b"\xff\x2f\x00"
    with open(path, "wb") as f:
        f.write(b"MThd" + struct.pack(">IHHH", 6, 0, 1, ppq))
        f.write(b"MTrk" + struct.pack(">I", len(track)) + bytes(track))


def kit_tracks(root):
    """(track, its outermost Drum Rack) for every track that plays one."""
    found = []
    for track in root.find("LiveSet/Tracks"):
        rack = next(track.iter("DrumGroupDevice"), None)
        if rack is not None:
            found.append((track, rack))
    return found


# A Drum Rack pad set to receive "All Notes" stores 0 as its note and plays
# under every note, passing the note on unchanged (Kit-Carbon's KJ Sawka layer).
ALL_NOTES = 0


def pad_notes(rack):
    """MIDI note -> pad names, All Notes pads under ALL_NOTES. Live stores a
    pad's note as 128 - note in the pad's own BranchInfo, its direct child: a
    search below it would find the pads of a rack nested in the pad (the
    Kit-Carbon layer's KJ Sawka kit) and file the layer under their notes."""
    pads = {}
    for branch in rack.findall("./Branches/DrumBranch"):
        stored = value(branch, "BranchInfo/ReceivingNote")
        if stored is None:
            continue
        name = value(branch, "Name/EffectiveName") or value(branch, "Name/UserName") or "?"
        note = ALL_NOTES if int(stored) == 0 else 128 - int(stored)
        pads.setdefault(note, []).append(name)
    return pads


def track_span(text, name):
    """(start, end) of the <MidiTrack> named `name` in the set's raw text."""
    at = text.find('<EffectiveName Value="%s" />' % name)
    if at < 0:
        raise ValueError("no track named %r" % name)
    start = text.rfind("<MidiTrack ", 0, at)
    return start, text.find("</MidiTrack>", at)


def switch_off_devices(text, start, end, tag):
    """Every <tag> device between start and end switched off: the Manual value
    of its own <On>, the first one in the device. Answers (text, count)."""
    count, pos = 0, start
    while True:
        dev = text.find("<" + tag + " ", pos, end)
        if dev < 0:
            return text, count
        on = text.find("<On>", dev, end)
        manual = text.find('<Manual Value="true" />', on, end)
        if on < 0 or manual < 0 or manual > text.find("</On>", on, end):
            pos = dev + 1
            continue
        text = text[:manual] + '<Manual Value="false" />' + text[manual + len('<Manual Value="true" />'):]
        end += 1   # "false" is one character longer than "true"
        count += 1
        pos = manual


def cmd_drumrender(root, parents, args):
    out_dir = os.path.join(args.out, "drums")
    os.makedirs(out_dir, exist_ok=True)
    with gzip.open(args.set) as f:
        text = f.read().decode("utf-8")
    for track, rack in kit_tracks(root):
        name = track_name(track)
        kit = value(rack, "UserName") or name
        pads = pad_notes(rack)
        # An All Notes pad has no note of its own: it sounds under every hit.
        notes = sorted(n for n in pads if n != ALL_NOTES)
        hits, beat = [], 4.0
        for note in notes:
            for vel in RENDER_VELOCITIES:
                hits.append((beat, note, vel))
                beat += 4.0
        stem = os.path.join(out_dir, slug(kit))
        write_midi(stem + ".mid", hits)
        with open(stem + ".json", "w") as f:
            json.dump({
                "source": os.path.basename(args.set), "track": name, "kit": kit,
                "beatsPerHit": 4, "leadInBeats": 4, "noteBeats": 0.25,
                "velocities": RENDER_VELOCITIES,
                "pads": {str(n): pads[n] for n in notes},
                "allNotes": pads.get(ALL_NOTES, []),
                "hits": [{"beat": b, "note": n, "velocity": v} for b, n, v in hits],
            }, f, indent=1)
        start, end = track_span(text, name)
        text, repeats = switch_off_devices(text, start, end, "BeatRepeat")
        start, end = track_span(text, name)
        span = text[start:end].replace('<MonitoringEnum Value="0" />', '<MonitoringEnum Value="1" />', 1)
        text = text[:start] + span + text[end:]
        print("%s.mid  (%s: %d pads x %d velocities = %d hits, %d bars; %d Beat Repeats off)" % (
            os.path.relpath(stem, REPO), name, len(notes), len(RENDER_VELOCITIES), len(hits),
            int(beat // 4), repeats))
    # Rhythmic Steps, so the transport cannot play the sequencer into the kits.
    for track in root.find("LiveSet/Tracks"):
        if any("Rhythmic Steps" in (value(d, ".//PatchSlot//FileRef//Path") or "")
               for d in track.iter("MxDeviceMidiEffect")):
            start, end = track_span(text, track_name(track))
            text, n = switch_off_devices(text, start, end, "MidiEffectGroupDevice")
            print("Rhythmic Steps rack off on track '%s'" % track_name(track))
    ET.fromstring(text.encode("utf-8"))   # still well-formed, or no file at all
    path = os.path.join(out_dir, "megalooper-drum-render.als")
    with gzip.open(path, "wb") as f:
        f.write(text.encode("utf-8"))
    print(os.path.relpath(path, REPO) + "  (open in Live, drop the .mid files, export)")
    return 0


# --------------------------------------------------------------------------
# variations
# --------------------------------------------------------------------------
# Five of SA's seven effects sit in racks whose macros drive their knobs, and
# Live leaves a macro-driven knob's own stored value frozen: what Live plays is
# the macro's position sent through the knob's curve over the mapping's range.
# The curves are not in the set. These are fitted from Live 12's factory racks
# and the user's own rack presets, which store both a macro's position and the
# value it gives: "power" raises the knob's travel to that power over the
# parameter's whole range, "log" is logarithmic between the mapping's ends,
# "enum" rounds, and anything else is linear.
CURVES = {
    ("Delay", "DelayLine_TimeL"): ("power", 0.001, 5.0, 5.0),
    ("Delay", "DelayLine_TimeR"): ("power", 0.001, 5.0, 5.0),
    ("Delay", "DelayLine_SmoothingMode"): ("enum",),
    ("AutoFilter2", "Filter_Frequency"): ("log",),
    ("AutoFilter2", "Filter_Type"): ("enum",),
    ("AutoFilter2", "Filter_Circuit"): ("enum",),
    ("AutoFilter2", "Lfo_Waveform"): ("enum",),
    ("AutoFilter2", "Lfo_TimeMode"): ("enum",),
    ("AutoFilter2", "Lfo_SyncedRate"): ("enum",),
    ("Saturator", "ColorFrequency"): ("log",),
    ("Redux2", "SampleRate"): ("power", 20.0, 40000.0, 10.0 / 3.0),
    ("Redux2", "Jitter"): ("power", 0.0, 1.0, 2.0),
    ("Redux2", "BitDepth"): ("enum",),
    ("Mx", "Shape"): ("enum",),
    ("Mx", "CoarseLeft"): ("enum",),
}

# The racks, by the track they sit on and how to tell them: a user name, or
# the name of their one branch.
SA_RACKS = [
    ("delay", "Guitar Rig", None, "LFO | Delay"),
    ("filter", "Guitar Rig", "filter", None),
    ("pitchLoop", "Guitar Rig", None, "PitchLoop89"),
    ("saturator", "looper guitar", "wavetable", None),
    ("redux", "looper guitar", "redux", None),
]

# Live's synced LFO rates, slow to fast, in whole notes.
SYNC_DIVISIONS = [8, 6, 4, 3, 2, 1.5, 1, 0.75, 0.5, 0.375, 1 / 3, 5 / 16, 0.25, 3 / 16,
                  1 / 6, 0.125, 1 / 12, 1 / 16, 1 / 24, 1 / 32, 1 / 48, 1 / 64]
# MegaSAFx's filterLfoBeats choices, in beats (0 = free).
SA_LFO_BEATS = [0, 0.0625, 1 / 12, 0.09375, 0.125, 1 / 6, 0.1875, 0.25, 1 / 3, 0.375, 0.5,
                2 / 3, 0.75, 1, 4 / 3, 1.5, 2, 3, 4, 8]

# Which of the Live device's parameters each SA setting is made from. A
# variation carries a setting only if a macro drives one of them and the
# variation stores that macro, as Live's own recall moves only those.
SA_SOURCES = {
    "delay": {
        "delayTimeL": [("Delay", "DelayLine_TimeL")],
        "delayTimeR": [("Delay", "DelayLine_TimeR")],
        "delayFeedback": [("Delay", "Feedback")],
        "delayMix": [("Delay", "DryWet")],
        "delayLfoHz": [("Mx", "Freq Rate")],
        "delayLfoMax": [("Mx", "Depth")],
        "delayLfoMin": [],
    },
    "filter": {
        "filterType": [("AutoFilter2", "Filter_Type")],
        "filterFreq": [("AutoFilter2", "Filter_Frequency")],
        "filterRes": [("AutoFilter2", "Filter_Resonance")],
        "filterMorph": [("AutoFilter2", "Filter_Morph")],
        "filterEnvAmount": [("AutoFilter2", "Envelope_Amount")],
        "filterLfoWave": [("AutoFilter2", "Lfo_Waveform")],
        "filterLfoAmount": [("AutoFilter2", "Lfo_Amount")],
        "filterLfoBeats": [("AutoFilter2", "Lfo_TimeMode"), ("AutoFilter2", "Lfo_SyncedRate"),
                           ("AutoFilter2", "Lfo_Sixteenth")],
        "filterLfoHz": [("AutoFilter2", "Lfo_Frequency"), ("AutoFilter2", "Lfo_Time")],
    },
    "pitchLoop": {
        "pitchLoopPitchL": [("Mx", "CoarseLeft")],
        "pitchLoopPosL": [("Mx", "PositionLeft")],
    },
    "saturator": {
        "saturatorType": [("Saturator", "Type")],
        "saturatorDrive": [("Saturator", "PreDrive")],
        "saturatorBase": [("Saturator", "BaseDrive")],
        "saturatorFreq": [("Saturator", "ColorFrequency")],
        "saturatorWidth": [("Saturator", "ColorWidth")],
        "saturatorDepth": [("Saturator", "ColorDepth")],
        "saturatorOutput": [("Saturator", "PostDrive")],
        "saturatorMix": [("Saturator", "DryWet")],
    },
    "redux": {
        "reduxRate": [("Redux2", "SampleRate")],
        "reduxJitter": [("Redux2", "Jitter")],
        "reduxBits": [("Redux2", "BitDepth")],
        "reduxDcShift": [("Redux2", "QuantizerDcShift")],
        "reduxPreFilter": [("Redux2", "EnablePreFilter")],
        "reduxPostFilter": [("Redux2", "EnablePostFilter")],
        "reduxPostOctaves": [("Redux2", "PostFilterValue")],
        "reduxMix": [("Redux2", "DryWet")],
    },
}


def through_macro(curve, lo, hi, position):
    t = position / 127.0
    kind = curve[0] if curve else "linear"
    if kind == "log" and lo > 0 and hi > 0:
        return lo * (hi / lo) ** t
    if kind == "power":
        pmin, pmax, k = curve[1:]
        # Live stores 1 ms as 0.001000000047; the root of that sliver above
        # the minimum would move the whole curve, so ends within a millionth
        # of the range are the ends.
        def travel(v):
            frac = min(max((v - pmin) / (pmax - pmin), 0.0), 1.0)
            frac = 0.0 if frac < 1e-6 else (1.0 if frac > 1 - 1e-6 else frac)
            return frac ** (1.0 / k)
        x = travel(lo) + (travel(hi) - travel(lo)) * t
        return pmin + (pmax - pmin) * x ** k
    v = lo + (hi - lo) * t
    return float(round(v)) if kind == "enum" else v


def find_rack(root, track_wanted, user_wanted, branch_wanted):
    for track in root.iter():
        if track.tag != "AudioTrack" or track_name(track) != track_wanted:
            continue
        for rack in track.iter("AudioEffectGroupDevice"):
            branches = [value(b, "Name/EffectiveName") or value(b, "Name")
                        for b in rack.findall("./Branches/*")]
            if user_wanted is not None and value(rack, "UserName") == user_wanted:
                return rack
            if branch_wanted is not None and branches == [branch_wanted]:
                return rack
    return None


def rack_devices(rack):
    """The devices directly in the rack's branches, keyed as CURVES keys them."""
    out = []
    for branch in rack.findall("./Branches/*"):
        devs = branch.find("DeviceChain/*/Devices")
        for dev in (devs if devs is not None else []):
            out.append(dev)
    return out


def device_values(dev):
    """Every parameter's stored value: (tag, name) -> float, and its mapping."""
    stored, mapped = {}, {}
    mx = dev.tag.startswith("MxDevice")
    for param in (dev.iter() if mx else dev):
        if mx and param.tag not in MX_PARAMS:
            continue
        holder = param.find("Timeable") if mx else param
        if holder is None or holder.find("Manual") is None:
            continue
        key = ("Mx", value(param, "Name")) if mx else (dev.tag, param.tag)
        raw = value(holder, "Manual")
        try:
            stored[key] = {"true": 1.0, "false": 0.0}.get(raw, None) if raw in ("true", "false") \
                else float(raw)
        except (TypeError, ValueError):
            continue
        km = holder.find("KeyMidi")
        if km is not None and value(km, "Channel") == "16":
            # A Max for Live enum stores no mapping range, nor does a switch:
            # their own one applies (off/on for a switch).
            rng = holder.find("MidiControllerRange")
            lo = value(rng, "Min") if rng is not None else value(param, "MinValue")
            hi = value(rng, "Max") if rng is not None else value(param, "MaxValue")
            if (lo is None or hi is None) and value(holder, "Manual") in ("true", "false"):
                lo, hi = "0", "1"
            if lo is not None and hi is not None:
                mapped[key] = (int(value(km, "NoteOrController")), float(lo), float(hi))
            else:
                print("a macro drives %s %s over a range the set does not store; skipped"
                      % key, file=sys.stderr)
    return stored, mapped


def rack_states(rack):
    """[(name, macro positions)], the set's own positions first. A variation
    holds only the macros it stores: recalling it leaves the others where
    they are."""
    current = {}
    for i in range(16):
        v = value(rack, "MacroControls.%d/Manual" % i)
        if v is not None:
            current[i] = float(v)
    states = [("as saved", current)]
    for snap in rack.iter("MacroSnapshot"):
        vals = {}
        for i in range(16):
            if value(snap, "MacroHasValue.%d" % i) == "true":
                vals[i] = float(value(snap, "MacroValues.%d" % i))
        states.append((value(snap, "SnapshotName") or "?", vals))
    return states


def sa_settings(effect, live):
    """Live's values for one effect, as MegaSAFx's settings."""
    get = live.get
    if effect == "delay":
        depth = get(("Mx", "Depth"), 100.0) / 100.0
        return {
            "delayTimeL": get(("Delay", "DelayLine_TimeL")),
            "delayTimeR": get(("Delay", "DelayLine_TimeR")),
            "delayFeedback": get(("Delay", "Feedback")),
            "delayMix": get(("Delay", "DryWet")),
            "delayLfoHz": get(("Mx", "Freq Rate")),
            # The LFO sweeps the Delay's Rate (0.01-40 Hz) from its bottom over
            # `depth` of the knob's travel, taken as logarithmic.
            "delayLfoMin": 0.01,
            "delayLfoMax": 0.01 * 4000 ** depth,
        }
    if effect == "filter":
        live_type = int(get(("AutoFilter2", "Filter_Type"), 4))
        mode = int(get(("AutoFilter2", "Lfo_TimeMode"), 0))
        hz = get(("AutoFilter2", "Lfo_Frequency"), 1.0)
        beats = 0
        if mode == 1:
            hz = 1.0 / max(get(("AutoFilter2", "Lfo_Time"), 1.0), 0.01)
        elif mode in (2, 3, 4):
            index = min(max(int(get(("AutoFilter2", "Lfo_SyncedRate"), 12)), 0), len(SYNC_DIVISIONS) - 1)
            beats = SYNC_DIVISIONS[index] * 4 * {2: 1.0, 3: 2 / 3, 4: 1.5}[mode]
        elif mode == 5:
            beats = get(("AutoFilter2", "Lfo_Sixteenth"), 4) / 4.0
        if beats > 0:
            snapped = min(SA_LFO_BEATS[1:], key=lambda b: abs(b - beats))
            if abs(snapped - beats) > 0.05 * beats:
                print("filter LFO: %.4g beats is not one of SA's divisions; %.4g instead"
                      % (beats, snapped), file=sys.stderr)
            beats = snapped
        return {
            # Live: 0 LP, 1 HP, 2 BP, 3 Notch, 4 Morph, 5 DJ, 6 Comb, 7 Resampling,
            # 8 Notch+LP, 9 Vowel; SA builds the first five.
            "filterType": {5: 0, 6: 2, 7: 0, 8: 3, 9: 2}.get(live_type, live_type),
            "filterFreq": get(("AutoFilter2", "Filter_Frequency")),
            "filterRes": get(("AutoFilter2", "Filter_Resonance")),
            "filterMorph": get(("AutoFilter2", "Filter_Morph")),
            "filterEnvAmount": get(("AutoFilter2", "Envelope_Amount")),
            "filterLfoWave": get(("AutoFilter2", "Lfo_Waveform")),
            "filterLfoAmount": get(("AutoFilter2", "Lfo_Amount")),
            "filterLfoBeats": beats,
            "filterLfoHz": hz,
        }
    if effect == "pitchLoop":
        # PitchLoop89's positions are % of its 88200-sample memory, 1.8375 s at
        # 48 kHz.
        return {
            "pitchLoopPitchL": get(("Mx", "CoarseLeft")),
            "pitchLoopPosL": get(("Mx", "PositionLeft"), 0) / 100.0 * 1.8375,
        }
    if effect == "saturator":
        live_type = int(get(("Saturator", "Type"), 3))
        return {
            # Live 12: 0 Analog Clip, 1 Soft Sine, 2 Bass Shaper, 3 Medium Curve,
            # 4 Hard Curve, 5 Sinoid Fold, 6 Digital Clip, 7 Waveshaper; SA has
            # no Bass Shaper or Waveshaper and plays Medium Curve for them.
            "saturatorType": {2: 3, 7: 3}.get(live_type, live_type),
            "saturatorDrive": get(("Saturator", "PreDrive")),
            "saturatorBase": get(("Saturator", "BaseDrive")),
            "saturatorFreq": get(("Saturator", "ColorFrequency")),
            "saturatorWidth": get(("Saturator", "ColorWidth")),
            "saturatorDepth": get(("Saturator", "ColorDepth")),
            "saturatorOutput": get(("Saturator", "PostDrive")),
            "saturatorMix": get(("Saturator", "DryWet")),
        }
    if effect == "redux":
        return {
            "reduxRate": get(("Redux2", "SampleRate")),
            "reduxJitter": get(("Redux2", "Jitter")),
            "reduxBits": get(("Redux2", "BitDepth")),
            "reduxDcShift": get(("Redux2", "QuantizerDcShift")),
            "reduxPreFilter": get(("Redux2", "EnablePreFilter")),
            "reduxPostFilter": get(("Redux2", "EnablePostFilter")),
            "reduxPostOctaves": get(("Redux2", "PostFilterValue")),
            "reduxMix": get(("Redux2", "DryWet")),
        }
    return {}


def cmd_variations(root, parents, args):
    effects = {}
    for effect, track, user, branch in SA_RACKS:
        rack = find_rack(root, track, user, branch)
        if rack is None:
            print("no rack for %s on track '%s'" % (effect, track), file=sys.stderr)
            continue
        stored, mapped = {}, {}
        for dev in rack_devices(rack):
            s, m = device_values(dev)
            stored.update(s)
            mapped.update(m)
        sources = SA_SOURCES[effect]
        states = rack_states(rack)
        saved = states[0][1]
        variations = []
        for name, positions in states:
            # Macros the variation does not store keep the set's positions,
            # for working the values out; they are not recalled.
            live = dict(stored)
            for key, (macro, lo, hi) in mapped.items():
                live[key] = through_macro(CURVES.get(key), lo, hi, positions.get(macro, saved.get(macro, 0)))
            settings = {}
            for setting, v in sa_settings(effect, live).items():
                keys = list(sources.get(setting, []))
                # The free LFO rate is the Time knob's when a macro picks Time
                # mode, so the mode then drives it too.
                if setting == "filterLfoHz" and int(live.get(("AutoFilter2", "Lfo_TimeMode"), 0)) == 1:
                    keys.append(("AutoFilter2", "Lfo_TimeMode"))
                driven = [mapped[k][0] for k in keys if k in mapped]
                if v is not None and driven and all(m in positions for m in driven):
                    settings[setting] = round(v, 6)
            variations.append({"name": name, "settings": settings})
        # What no macro drives: the device's own stored values, which are what
        # Live plays and so where SA's knobs start.
        fixed = {setting: round(v, 6) for setting, v in sa_settings(effect, dict(stored)).items()
                 if v is not None and not any(k in mapped for k in sources.get(setting, []))}
        effects[effect] = {
            "rack": value(rack, "UserName") or branch,
            "track": track,
            "variations": variations,
            "fixed": fixed,
        }
    if not effects:
        return 1
    os.makedirs(args.out, exist_ok=True)
    path = os.path.join(args.out, "fx-variations.json")
    text = json.dumps({
        "source": os.path.basename(args.set),
        "notes": "Each effect's rack states as MegaSAFx settings: 'as saved' is the macros "
                 "as the set left them; the rest are the rack's own macro variations, each "
                 "with only the settings its macros drive (a recall leaves the rest). "
                 "'fixed' holds the settings no macro drives, at the device's stored values. "
                 "MegaSAFx's defaults are 'as saved' plus 'fixed'. Macro positions go "
                 "through Live's knob curves (tools/export-live-set.py CURVES).",
        "effects": effects,
    }, indent=1, ensure_ascii=False)
    with open(path, "w") as f:
        f.write(text + "\n")
    for effect, e in effects.items():
        print("%s: %s" % (effect, ", ".join(v["name"] for v in e["variations"])))
    print(os.path.relpath(path, REPO))
    return 0


# --------------------------------------------------------------------------
# kits
# --------------------------------------------------------------------------
# SA plays its drums from sample kits: per kit a JSON file (committed) and the
# audio it plays, copied beside it into a git-ignored folder. The set's own
# samples cannot be used: every Factory Pack sample is an AIFC 'able' file,
# Ableton's encrypted format, which only Live reads. So the kits are made from
# what is plain on this Mac and licensed with Live: the Live 12 Suite Core
# Library, the packs' browser previews (Ogg Vorbis; Designer Drums has one of
# every Kit-Carbon pad) and Hybrid Reverb's impulse responses. Their audio is
# copied only to presets/sa/drums/kits/<folder>/, never committed. The JSON is
# MegaSAKit's version 1 (docs/dev/megalooper-sa.md, Phase 4), its file paths
# relative to presets/sa/drums/kits/.
KIT_VERSION = 1
LIVE_APP = "/Applications/Ableton Live 12 Suite.app"
CORE_LIBRARY = os.path.join(LIVE_APP, "Contents", "App-Resources", "Core Library")
CORE_SAMPLES = os.path.join(CORE_LIBRARY, "Samples")
CORE_PACK_ID = "www.ableton.com/0"
HYBRID_IRS = os.path.join(LIVE_APP, "Contents", "App-Resources", "Builtin", "Samples", "Hybrid",
                          "ImpulseResponses")
FACTORY_PACKS = os.path.expanduser(
    "~/Library/Mobile Documents/com~apple~CloudDocs/Ableton/Factory Packs")
DRUM_PREVIEWS = os.path.join(FACTORY_PACKS, "Designer Drums", "Ableton Folder Info", "Previews",
                             "Drums")
# macOS keeps a file whose content is still in iCloud "dataless"; opening one
# downloads it, so nothing here ever reads one.
SF_DATALESS = 0x40000000
AUDIO_EXTENSIONS = (".wav", ".wave", ".aif", ".aiff", ".aifc", ".ogg", ".flac")
# MegaSA's drum voices play mono and stereo buffers only.
KIT_MAX_CHANNELS = 2


class KitError(Exception):
    """A kit that cannot be built: reported, and the other kits are still built."""


def tilde(path):
    """A path for provenance: the home folder written ~, never a user's name."""
    home = os.path.expanduser("~")
    if path == home or path.startswith(home + os.sep):
        return "~" + path[len(home):]
    return path


def num(x, places=3):
    """A float as the kit JSON keeps it: rounded, and never -0.0."""
    return round(x, places) or 0.0


def shown(path):
    """A path to print: relative inside the repository, with ~ outside it."""
    return os.path.relpath(path, REPO) if path.startswith(REPO + os.sep) else tilde(path)


# --- sound files, read by hand (no audio libraries here) ----------------------
def ext80(b):
    """An AIFF sample rate: an 80-bit IEEE 754 extended float."""
    exponent = ((b[0] & 0x7F) << 8) | b[1]
    mantissa = int.from_bytes(b[2:10], "big")
    if exponent == 0 and mantissa == 0:
        return 0.0
    return (-1.0 if b[0] & 0x80 else 1.0) * mantissa * 2.0 ** (exponent - 16383 - 63)


def wav_header(f, info):
    fmt = None
    while True:
        chunk = f.read(8)
        if len(chunk) < 8:
            break
        cid, size = chunk[:4], struct.unpack("<I", chunk[4:])[0]
        if cid == b"fmt ":
            body = f.read(size + (size & 1))
            tag, channels, rate, _, _, bits = struct.unpack("<HHIIHH", body[:16])
            if tag == 0xFFFE and len(body) >= 26:
                # WAVE_FORMAT_EXTENSIBLE: the real format is the sub-format's first word.
                tag = struct.unpack("<H", body[24:26])[0]
            fmt = (tag, channels, rate, bits)
        elif cid == b"data":
            info["dataOffset"], info["dataBytes"] = f.tell(), size
            f.seek(size + (size & 1), 1)
        else:
            f.seek(size + (size & 1), 1)
    info["container"] = "WAV"
    if fmt is None or "dataOffset" not in info:
        info["why"] = "a WAV file without a fmt or data chunk"
        return
    tag, channels, rate, bits = fmt
    info.update(channels=channels, rate=float(rate), bits=bits, bigEndian=False)
    if tag == 1 and bits in (8, 16, 24, 32):
        info["codec"] = "pcm"
    elif tag == 3 and bits in (32, 64):
        info["codec"] = "float"
    else:
        info["why"] = "WAV format %d at %d bits" % (tag, bits)
        return
    info["frames"] = info["dataBytes"] // max(1, channels * bits // 8)


# AIFC compression types libsndfile reads as plain samples: (codec, big-endian).
AIFC_CODECS = {"NONE": ("pcm", True), "twos": ("pcm", True), "sowt": ("pcm", False),
               "fl32": ("float", True), "FL32": ("float", True),
               "fl64": ("float", True), "FL64": ("float", True)}


def aiff_header(f, info, aifc):
    comm = None
    while True:
        chunk = f.read(8)
        if len(chunk) < 8:
            break
        cid, size = chunk[:4], struct.unpack(">I", chunk[4:])[0]
        if cid == b"COMM":
            body = f.read(size + (size & 1))
            channels, frames, bits = struct.unpack(">hIh", body[:8])
            compression = body[18:22].decode("latin-1") if aifc and len(body) >= 22 else "NONE"
            comm = (channels, frames, bits, ext80(body[8:18]), compression)
        elif cid == b"SSND":
            offset = struct.unpack(">I", f.read(4))[0]
            f.seek(4, 1)
            info["dataOffset"], info["dataBytes"] = f.tell() + offset, size - 8 - offset
            f.seek(size - 8 + (size & 1), 1)
        else:
            f.seek(size + (size & 1), 1)
    info["container"] = "AIFC" if aifc else "AIFF"
    if comm is None or "dataOffset" not in info:
        info["why"] = "an AIFF file without a COMM or SSND chunk"
        return
    channels, frames, bits, rate, compression = comm
    info.update(channels=channels, frames=frames, bits=bits, rate=rate, compression=compression)
    if compression == "able":
        info["why"] = "AIFC 'able', Ableton's encrypted pack format"
    elif compression in AIFC_CODECS:
        info["codec"], info["bigEndian"] = AIFC_CODECS[compression]
        if info["codec"] == "float":
            info["bits"] = 64 if compression.lower() == "fl64" else 32
    else:
        info["why"] = "AIFC compression '%s'" % compression


def ogg_header(f, info):
    """Ogg Vorbis: channels and rate from the identification header (the first
    page's packet), the length from the last page's granule position."""
    info["container"] = "Ogg"
    f.seek(0)
    page = f.read(27)
    segments = f.read(page[26])
    packet = f.read(sum(segments))
    serial = page[14:18]
    if packet[:7] != b"\x01vorbis":
        info["why"] = "an Ogg stream that is not Vorbis"
        return
    channels, rate = packet[11], struct.unpack("<I", packet[12:16])[0]
    # A page is at most 64 kB, so the last one starts in the last 128 kB.
    f.seek(max(0, info["bytes"] - 131072))
    tail = f.read()
    at, granule = len(tail), -1
    while granule < 0:
        at = tail.rfind(b"OggS", 0, at)
        if at < 0:
            break
        if len(tail) >= at + 18 and tail[at + 4] == 0 and tail[at + 14:at + 18] == serial:
            granule = struct.unpack("<q", tail[at + 6:at + 14])[0]
    info.update(codec="vorbis", channels=channels, rate=float(rate), frames=max(granule, 0))


def flac_header(f, info):
    info["container"] = "FLAC"
    f.seek(4)
    block = f.read(4)
    if block[0] & 0x7F != 0:
        info["why"] = "a FLAC file that does not start with STREAMINFO"
        return
    packed = int.from_bytes(f.read(34)[10:18], "big")
    info.update(codec="flac", rate=float(packed >> 44), channels=((packed >> 41) & 7) + 1,
                bits=((packed >> 36) & 31) + 1, frames=packed & ((1 << 36) - 1))


def audio_info(path):
    """A sound file's format from its header alone: container, codec, channels,
    rate, frames, bits, and `readable`, with `why` when it is not. scsynth
    reads through libsndfile: PCM and float WAV and AIFF/AIFC, Ogg Vorbis, FLAC."""
    info = {"path": path, "readable": False, "why": None, "container": None, "codec": None,
            "channels": 0, "rate": 0.0, "frames": 0, "bits": 0, "bytes": 0}
    try:
        st = os.stat(path)
    except OSError:
        info["why"] = "missing"
        return info
    info["bytes"] = st.st_size
    if getattr(st, "st_flags", 0) & SF_DATALESS:
        info["why"] = "still in iCloud (dataless): opening it would download it"
        return info
    try:
        with open(path, "rb") as f:
            head = f.read(12)
            if head[:4] == b"RIFF" and head[8:12] == b"WAVE":
                wav_header(f, info)
            elif head[:4] == b"FORM" and head[8:12] in (b"AIFF", b"AIFC"):
                aiff_header(f, info, head[8:12] == b"AIFC")
            elif head[:4] == b"OggS":
                ogg_header(f, info)
            elif head[:4] == b"fLaC":
                flac_header(f, info)
            else:
                info["why"] = "not a WAV, AIFF, Ogg Vorbis or FLAC file"
    except (OSError, struct.error, IndexError, ValueError) as e:
        info["why"] = "an unreadable header (%s)" % e
    if "dataBytes" in info:
        # A header may promise more than the file holds.
        info["dataBytes"] = max(0, min(info["dataBytes"], st.st_size - info["dataOffset"]))
        if info["codec"] in ("pcm", "float") and info["channels"] > 0:
            info["frames"] = min(info["frames"],
                                 info["dataBytes"] // (info["channels"] * info["bits"] // 8))
    if info["why"] is None:
        if info["channels"] < 1 or info["rate"] <= 0 or info["frames"] <= 0:
            info["why"] = "empty (%d channels, %g Hz, %d frames)" % (
                info["channels"], info["rate"], info["frames"])
        else:
            info["readable"] = True
    return info


def raw_samples(info):
    """A PCM or float file's interleaved samples: (array, scale to -1..1)."""
    bits, width = info["bits"], info["bits"] // 8
    with open(info["path"], "rb") as f:
        f.seek(info["dataOffset"])
        raw = f.read(info["frames"] * info["channels"] * width)
    swap = info.get("bigEndian", False) != (sys.byteorder == "big")
    if info["codec"] == "float":
        data, scale = array.array("f" if bits == 32 else "d"), 1.0
        data.frombytes(raw[:len(raw) // width * width])
    elif bits == 8:
        # WAV keeps 8-bit samples unsigned, AIFF signed.
        data = array.array("B" if info["container"] == "WAV" else "b")
        data.frombytes(raw)
        if info["container"] == "WAV":
            data = array.array("h", [x - 128 for x in data])
        return data, 1.0 / 128
    elif bits == 16:
        data, scale = array.array("h"), 1.0 / 32768
        data.frombytes(raw[:len(raw) // 2 * 2])
    else:
        if bits == 24:
            # Widen each sample to 32 bits with its bytes on top, so array reads
            # them at C speed: the value is then the sample times 256.
            raw = raw[:len(raw) // 3 * 3]
            wide = bytearray(len(raw) // 3 * 4)
            top = 0 if info.get("bigEndian", False) else 1
            for i in range(3):
                wide[top + i::4] = raw[i::3]
            raw = bytes(wide)
        data, scale = array.array("i"), 1.0 / 2147483648
        data.frombytes(raw[:len(raw) // 4 * 4])
    if swap:
        data.byteswap()
    return data, scale


def channel_samples(info, channel):
    """One channel of a PCM or float file as floats, -1..1."""
    data, scale = raw_samples(info)
    return [x * scale for x in data[channel::info["channels"]]]


PEAKS = {}


def peak_dbfs(info):
    """A PCM or float file's peak in dBFS: None for Vorbis and FLAC (only a
    decoder could tell), -inf for silence."""
    if info["codec"] not in ("pcm", "float"):
        return None
    if info["path"] not in PEAKS:
        data, scale = raw_samples(info)
        peak = max(max(data), -min(data)) * scale if len(data) else 0.0
        PEAKS[info["path"]] = 20 * math.log10(peak) if peak > 0 else float("-inf")
    return PEAKS[info["path"]]


def to_full_scale(info):
    """The gain (dB) that brings a PCM file's peak to 0 dBFS; a silent file, or
    one whose peak only a decoder could tell, is refused."""
    peak = peak_dbfs(info)
    if peak is None or peak == float("-inf"):
        raise KitError("%s: silent, or its peak unknown: cannot normalise it" % tilde(info["path"]))
    return -peak


def kit_sample(path):
    """The header of a sample a kit is to play, or KitError saying why it cannot."""
    info = audio_info(path)
    if not info["readable"]:
        raise KitError("%s: %s" % (tilde(path), info["why"]))
    if info["channels"] > KIT_MAX_CHANNELS:
        raise KitError("%s: %d channels (SA plays mono and stereo samples)"
                       % (tilde(path), info["channels"]))
    return info


def core_sample(rel):
    """A Core Library sample by its path under Core Library/Samples."""
    return kit_sample(os.path.join(CORE_SAMPLES, rel))


# --- where kits go -----------------------------------------------------------
def kits_folder(args):
    """presets/sa/drums/kits/ (under --out), refused if it lies in Ableton's own
    folders: the importer reads Ableton's files and never writes there."""
    path = os.path.realpath(os.path.join(args.out, "drums", "kits"))
    for root in (LIVE_APP, FACTORY_PACKS):
        real = os.path.realpath(root)
        if path == real or path.startswith(real + os.sep):
            raise KitError("refusing to write kits into Ableton's folder %s" % tilde(root))
    return path


def inside(kits_dir, rel):
    """A kit file's absolute path, refusing any path that leaves the kits folder."""
    base = os.path.realpath(kits_dir)
    path = os.path.realpath(os.path.join(base, rel))
    if not path.startswith(base + os.sep):
        raise KitError("refusing a path outside %s: %s" % (tilde(kits_dir), rel))
    return path


class KitFiles:
    """The audio of the kits being built: (source, folder) -> the copy's path
    in the kits folder, `<folder>/<name>`, as the kit JSON gives it."""

    def __init__(self, kits_dir):
        self.kits_dir = kits_dir
        self.rel = {}       # (source, folder) -> relative path
        self.source = {}    # relative path -> source

    def add(self, src, folder, name=None):
        src = os.path.abspath(src)
        if (src, folder) in self.rel:
            return self.rel[(src, folder)]
        stem, ext = os.path.splitext(name or os.path.basename(src))
        rel, n = "%s/%s%s" % (folder, stem, ext), 2
        while rel in self.source:
            rel, n = "%s/%s %d%s" % (folder, stem, n, ext), n + 1
        self.rel[(src, folder)], self.source[rel] = rel, src
        return rel

    def copy(self, rels):
        """Copy these files in, skipping copies already identical; answers the
        number of files written."""
        written = 0
        for rel in sorted(set(rels)):
            src, dst = self.source[rel], inside(self.kits_dir, rel)
            if os.path.isfile(dst) and os.path.getsize(dst) == os.path.getsize(src):
                with open(src, "rb") as a, open(dst, "rb") as b:
                    if a.read() == b.read():
                        continue
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(src, dst)
            written += 1
        return written


def kit_layer(group, file, gain_db, transpose=0.0, vel_lo=1, vel_hi=127, start_frames=0,
              len_secs=0.0, drive=0.0, law="none", amount=0.0, curve=None):
    """One layer as MegaSAKit reads it, its fields in the schema's order. A vel
    'curve' p is written only when given: the law's factor a(v) becomes
    a(v) ** p * a(88) ** (1 - p), the same at velocity 88 and steeper (p > 1)
    around it."""
    vel = {"law": law, "amount": num(amount, 4)}
    if curve is not None:
        vel["curve"] = num(curve)
    return {"group": group, "file": file, "gainDb": num(gain_db), "transpose": num(transpose),
            "velLo": int(vel_lo), "velHi": int(vel_hi), "startFrames": int(start_frames),
            "lenSecs": num(len_secs, 6), "drive": num(drive), "vel": vel}


def vel_factor(vel, v):
    """MegaSAKit's velocity factor of a layer's vel at velocity v (design 2.1:
    velDb as a factor times velAmp, with the curve anchored at 88)."""
    law, amount = vel.get("law"), vel.get("amount", 0.0)

    def a(x):
        db = 22.8 * amount * ((x - 64) / 63.0) if law == "simpler" else 0.0
        amp = (1 - amount) + amount * (x / 127.0) if law == "operator" else 1.0
        return 10 ** (db / 20.0) * amp

    p = vel.get("curve", 1.0)
    return a(v) ** p * a(88) ** (1 - p)


def pad_peak(pad, peaks, v=127):
    """A pad's peak at velocity v in dBFS, before the drums' strip: its sounding
    layers' peaks as MegaSA's voice plays them (gains, velocity, drive into
    tanh; a mono sample at its own level on both sides), summed. `peaks` maps
    a layer's file to its sample peak; None when one is unknown (Vorbis, FLAC)
    or nothing sounds."""
    total = 0.0
    for layer in pad["layers"]:
        if not layer["velLo"] <= v <= layer["velHi"]:
            continue
        peak = peaks.get(layer["file"])
        if peak is None:
            return None
        x = 10 ** (peak / 20.0)
        if layer["drive"] > 0:
            x = math.tanh(x * 10 ** (layer["drive"] / 20.0))
        total += 10 ** ((layer["gainDb"] + pad["gainDb"]) / 20.0) * vel_factor(layer["vel"], v) * x
    return 20 * math.log10(total) if total > 0 else None


# A pad more than this over the median of its kit's pads at velocity 127 is out
# of the kit's balance: a preset can set one part far above the rest (Flares'
# Snare Thin Smack, its Simpler at 0 dB where the others are at -12), and on SA,
# with no limiter on the drums, such a pad can drive the master into its clip.
HOT_PAD_DB = 6.0


def hot_pads(pads, peaks):
    """(median, [(note, peak dBFS, dB over median + HOT_PAD_DB)]) at velocity
    127, over the pads whose peaks are known; (None, []) for fewer than three."""
    known = {}
    for note, pad in pads.items():
        peak = pad_peak(pad, peaks)
        if peak is not None:
            known[int(note)] = peak
    if len(known) < 3:
        return None, []
    median = statistics.median(known.values())
    return median, [(n, known[n], known[n] - median - HOT_PAD_DB) for n in sorted(known)
                    if known[n] - median - HOT_PAD_DB > 0.05]


def kit_pad(name, layers, choke=0, retrigger=False, pan=0.0, gain_db=0.0, fit=None,
            beat_repeat=False, repeat_filter=False):
    pad = {"name": name, "choke": int(choke), "retrigger": bool(retrigger),
           "pan": num(max(-1.0, min(1.0, pan))), "gainDb": num(gain_db)}
    if fit is not None:
        pad["fit"] = fit
    pad.update(beatRepeat=bool(beat_repeat), repeatFilter=bool(repeat_filter), layers=layers)
    return pad


def kit_json(kit):
    """A kit as JSON text, one line per layer, so a kit reads (and diffs) pad
    by pad: each layer is dumped on its own, then put in its token's place."""
    layers = []

    def token(layer):
        layers.append(layer)
        return "@@layer%d@@" % (len(layers) - 1)

    shallow = dict(kit, pads={note: dict(pad, layers=[token(l) for l in pad["layers"]])
                              for note, pad in kit["pads"].items()})
    text = json.dumps(shallow, indent=1, ensure_ascii=False)
    for i, layer in enumerate(layers):
        text = text.replace('"@@layer%d@@"' % i, json.dumps(layer, ensure_ascii=False))
    return text + "\n"


def kit_files(kit):
    return sorted({layer["file"] for pad in kit["pads"].values() for layer in pad["layers"]})


def write_kit(kits_dir, kit, files):
    """Copy a kit's audio in and write its JSON; one summary line."""
    rels = kit_files(kit)
    written = files.copy(rels)
    path = inside(kits_dir, kit["key"] + ".json")
    with open(path, "w") as f:
        f.write(kit_json(kit))
    size = sum(os.path.getsize(inside(kits_dir, rel)) for rel in rels)
    print("%s  (%s: %d pads, %d files, %.0f kB; %d copied)" % (
        shown(path), kit["name"], len(kit["pads"]), len(rels), size / 1024.0,
        written))


def prune(kits_dir, folders):
    """Remove audio no kit refers to any more from these kit folders (a
    rebuild may choose other samples); only ever inside the kits folder."""
    used = set()
    for name in os.listdir(kits_dir):
        if name.endswith(".json"):
            try:
                with open(os.path.join(kits_dir, name)) as f:
                    used.update(kit_files(json.load(f)))
            except (ValueError, KeyError, TypeError, AttributeError):
                return   # a kit that cannot be read: keep everything
    for folder in folders:
        here = inside(kits_dir, folder)
        if not os.path.isdir(here):
            continue
        for name in sorted(os.listdir(here)):
            rel = folder + "/" + name
            if (rel not in used and name.lower().endswith(AUDIO_EXTENSIONS)
                    and os.path.isfile(os.path.join(here, name))):
                os.remove(inside(kits_dir, rel))
                print("removed %s (no kit plays it now)" % rel)


# --- Drum Racks: what a pad plays ---------------------------------------------
SAMPLE_INSTRUMENTS = ("OriginalSimpler", "MultiSampler")
RACK_TAGS = ("InstrumentGroupDevice", "DrumGroupDevice", "AudioEffectGroupDevice",
             "MidiEffectGroupDevice")
# Parameters Live steps in whole numbers: a macro's position is rounded onto them.
STEPPED = ("SampleSelector", "KeyZoneShift", "ChainSelector", "TransposeKey", "Pitch")
PACK_ROOTS = {}


def pack_roots():
    """Pack id -> its folders, from each pack's Properties.cfg (Core Library too)."""
    if not PACK_ROOTS:
        PACK_ROOTS[CORE_PACK_ID] = [CORE_LIBRARY]
        for name in (sorted(os.listdir(FACTORY_PACKS)) if os.path.isdir(FACTORY_PACKS) else []):
            cfg = os.path.join(FACTORY_PACKS, name, "Ableton Folder Info", "Properties.cfg")
            try:
                if os.stat(cfg).st_flags & SF_DATALESS:
                    continue
                with open(cfg, "rb") as f:
                    found = re.search(r'PackUniqueID = "([^"]+)"', f.read().decode("latin-1"))
            except OSError:
                continue
            if found:
                PACK_ROOTS.setdefault(found.group(1), []).append(os.path.join(FACTORY_PACKS, name))
    return PACK_ROOTS


def sample_file(fileref, base):
    """Where a sample a set or preset refers to lies on this Mac: (path, None),
    or (None, why). Live 11/12 store a path relative to its pack's folder plus
    the pack's id; Live 9/10 a list of folder names; both keep the path the
    sample had when saved, tried last."""
    if fileref is None:
        return None, "no sample"
    rel = value(fileref, "RelativePath")
    if rel is None and fileref.find("RelativePath") is not None:
        dirs = [e.get("Dir") for e in fileref.findall("RelativePath/RelativePathElement")]
        rel = "/".join([d for d in dirs if d] + [value(fileref, "Name") or ""])
    candidates = []
    if rel:
        rel = rel.lstrip("/")
        pack = value(fileref, "LivePackId") or ""
        if value(fileref, "LivePackName") == "Core Library":
            pack = CORE_PACK_ID
        candidates += [os.path.join(root, rel) for root in pack_roots().get(pack, [])]
        candidates.append(os.path.join(base, rel))
    if value(fileref, "Path"):
        candidates.append(value(fileref, "Path"))
    for path in candidates:
        if os.path.isfile(path):
            return path, None
    return None, "not found: %s" % (rel or value(fileref, "Path") or "?")


def macro_rack(param_el, parents):
    """The rack whose macros a parameter's channel-16 mapping counts in: the
    nearest rack around it, and for a rack's own macro knob the rack around that."""
    node = parents.get(param_el)
    if node is not None and node.tag in RACK_TAGS and param_el.tag.startswith("MacroControls."):
        node = parents.get(node)
    while node is not None and node.tag not in RACK_TAGS:
        node = parents.get(node)
    return node


def param(dev, path, default, parents=None, depth=0):
    """The value Live plays for a device parameter, as a float (switches 1/0).
    In a set (`parents` given) a parameter a rack macro drives keeps a frozen
    Manual (see `variations`): it plays the macro's position sent through the
    mapping's range, linear, rounded for stepped parameters, and a switch is on
    inside its thresholds. A preset stores what its macros produce, so presets
    are read without parents."""
    el = dev.find(path) if path else dev
    if el is None:
        return default
    holder = el if el.get("Value") is not None else el.find("Manual")
    raw = holder.get("Value") if holder is not None else None
    if raw is None:
        return default
    stored = {"true": 1.0, "false": 0.0}.get(raw)
    if stored is None:
        try:
            stored = float(raw)
        except ValueError:
            return default
    km = el.find("KeyMidi")
    if parents is None or km is None or value(km, "Channel") != "16" or depth > 8:
        return stored
    rack = macro_rack(el, parents)
    macro = rack.find("MacroControls.%s" % value(km, "NoteOrController")) if rack is not None else None
    if macro is None:
        return stored
    position = param(macro, None, 0.0, parents, depth + 1)
    if raw in ("true", "false"):
        lo = float(value(el, "MidiCCOnOffThresholds/Min") or 64)
        hi = float(value(el, "MidiCCOnOffThresholds/Max") or 127)
        within = min(lo, hi) <= position <= max(lo, hi)
        return 1.0 if (within if lo <= hi else not within) else 0.0
    if el.find("MidiControllerRange") is None:
        return stored
    v = through_macro(None, float(value(el, "MidiControllerRange/Min")),
                      float(value(el, "MidiControllerRange/Max")), position)
    return float(round(v)) if el.tag in STEPPED else v


def zone_span(zone, lo, hi):
    """A key, velocity or selector zone as SA plays it. Live fades a zone in
    from Min to CrossfadeMin and out from CrossfadeMax to Max; SA has no
    crossfades, so a fade becomes a switch at its midpoint, except a fade at
    the end of the whole range (lo, hi), which only makes the edge quieter."""
    if zone is None or value(zone, "Min") is None:
        return lo, hi
    z_lo, z_hi = int(value(zone, "Min")), int(value(zone, "Max"))
    c_lo = int(value(zone, "CrossfadeMin") or z_lo)
    c_hi = int(value(zone, "CrossfadeMax") or z_hi)
    return (z_lo if c_lo <= z_lo or z_lo <= lo else (z_lo + c_lo) // 2 + 1,
            z_hi if c_hi >= z_hi or z_hi >= hi else (c_hi + z_hi) // 2)


def zone_weight(zone, v):
    """A zone's crossfade weight at v: 1 inside, ramping over its fades, 0 outside."""
    if zone is None or value(zone, "Min") is None:
        return 1.0
    z_lo, z_hi = int(value(zone, "Min")), int(value(zone, "Max"))
    c_lo = int(value(zone, "CrossfadeMin") or z_lo)
    c_hi = int(value(zone, "CrossfadeMax") or z_hi)
    if v < z_lo or v > z_hi:
        return 0.0
    if v < c_lo:
        return (v - z_lo + 1) / float(c_lo - z_lo + 1)
    if v > c_hi:
        return (z_hi - v + 1) / float(z_hi - c_hi + 1)
    return 1.0


def velocity_runs(zones, lo, hi):
    """The velocities each of several parts plays as SA layers, which have no
    crossfades: at each velocity the parts at half weight or more, or, when
    none is, the strongest (so a fade to silence at the range's edge keeps
    playing; the velocity law makes it quiet). Answers per part its runs,
    [(velLo, velHi), ...]."""
    runs = [[] for _ in zones]
    for v in range(lo, hi + 1):
        weights = [zone_weight(zone, v) for zone in zones]
        top = max(weights) if weights else 0.0
        if top <= 0:
            continue
        chosen = [i for i, w in enumerate(weights) if w >= 0.5] or \
            [i for i, w in enumerate(weights) if w == top]
        for i in chosen:
            if runs[i] and runs[i][-1][1] == v - 1:
                runs[i][-1] = (runs[i][-1][0], v)
            else:
                runs[i].append((v, v))
    return runs


def chain_devices(branch, fmt):
    """A chain's devices in order, each with its preset wrapper (.adg) or None."""
    if fmt == "adg":
        found = []
        presets = branch.find("DevicePresets")
        for wrapper in (list(presets) if presets is not None else []):
            dev = wrapper.find("Device")
            if dev is not None and len(dev):
                found.append((dev[0], wrapper))
        return found
    devices = branch.find("DeviceChain/*/Devices")
    if devices is None:
        devices = branch.find("DeviceChain/Devices")
    return [(d, None) for d in (list(devices) if devices is not None else [])]


def rack_branches(dev, wrapper, fmt):
    holder = (wrapper.find("BranchPresets") if wrapper is not None else None) if fmt == "adg" \
        else dev.find("Branches")
    return list(holder) if holder is not None else []


def drum_zone(branch, fmt):
    """A Drum Rack pad's (receiving note as stored: 128 - note, or 0 for All
    Notes; the note it sends its chain; its choke group)."""
    zone = branch.find("ZoneSettings" if fmt == "adg" else "BranchInfo")
    if zone is None:
        return None, 60, 0
    return (int(value(zone, "ReceivingNote") or 0), int(value(zone, "SendingNote") or 60),
            int(value(zone, "ChokeGroup") or 0))


def pad_label(br, fmt):
    """A pad's name: the branch's, or the name of its instrument (or the rack
    holding it); an effect's name would say nothing about the sound."""
    name = value(br, "Name/EffectiveName") or value(br, "Name/UserName") if fmt == "als" \
        else value(br, "Name")
    if name:
        return name
    for dev, wrapper in chain_devices(br, fmt):
        if dev.tag in RACK_TAGS or dev.tag in SAMPLE_INSTRUMENTS or dev.tag in ("DrumCell", "Operator"):
            return value(dev, "UserName") or None
    return None


def chain_context(ctx, branch, fmt, parents, vel_lo=1, vel_hi=127):
    """What a branch's devices play inside: its mixer's gain and pan added, its
    velocity zone intersected; None when the branch is silent."""
    if fmt == "adg":
        holder = branch.find("MixerPreset")
        mixer = holder.find(".//AudioBranchMixerDevice") if holder is not None else None
    else:
        mixer = branch.find("MixerDevice")
    gain_db, pan = ctx["gainDb"], ctx["pan"]
    if mixer is not None:
        if param(mixer, "Speaker", 1.0, parents) < 0.5:
            return None
        volume_el = mixer.find("Volume")
        if parents is not None and volume_el is not None and volume_el.find("KeyMidi") is not None \
                and value(volume_el, "KeyMidi/Channel") == "16":
            # A macro on a chain fader plays through the fader's own curve,
            # which is not known: its stored value is used.
            ctx["notes"].append("a macro drives a chain volume; its stored value is used")
        volume = float(value(mixer, "Volume/Manual") or 1.0)
        if volume <= 0:
            return None
        gain_db += 20 * math.log10(volume)
        pan += param(mixer, "Panorama", 0.0, parents)
    lo, hi = max(ctx["velLo"], vel_lo), min(ctx["velHi"], vel_hi)
    if lo > hi:
        return None
    return dict(ctx, gainDb=gain_db, pan=pan, velLo=lo, velHi=hi)


def new_context():
    return {"gainDb": 0.0, "pan": 0.0, "velLo": 1, "velHi": 127, "other": [], "notes": []}


def chain_voices(branch, fmt, parents, note, ctx, base):
    """Every sample voice a chain plays for one note, in chain order: through
    MIDI Pitch, nested racks (chain selector, key and velocity zones, chain
    mixers) and nested Drum Racks. Other devices are only listed in ctx."""
    out = []
    for dev, wrapper in chain_devices(branch, fmt):
        if param(dev, "On", 1.0, parents) < 0.5:
            continue
        tag = dev.tag
        if tag == "MidiPitcher":
            note += int(round(param(dev, "Pitch", 0.0, parents)))
        elif tag in SAMPLE_INSTRUMENTS:
            out.extend(simpler_voices(dev, parents, note, ctx, base))
        elif tag == "DrumCell":
            out.append(drum_sampler_voice(dev, parents, ctx, base))
        elif tag == "InstrumentGroupDevice":
            chosen = param(dev, "ChainSelector", 0.0, parents)
            for br in rack_branches(dev, wrapper, fmt):
                s_lo, s_hi = zone_span(br.find("BranchSelectorRange"), 0, 127)
                k_lo, k_hi = zone_span(br.find("ZoneSettings/KeyRange"), 0, 127)
                v_lo, v_hi = zone_span(br.find("ZoneSettings/VelocityRange"), 1, 127)
                if s_lo <= chosen <= s_hi and k_lo <= note <= k_hi:
                    sub = chain_context(ctx, br, fmt, parents, v_lo, v_hi)
                    if sub is not None:
                        out.extend(chain_voices(br, fmt, parents, note, sub, base))
        elif tag == "DrumGroupDevice":
            for br in rack_branches(dev, wrapper, fmt):
                stored, sending, _ = drum_zone(br, fmt)
                if stored is not None and (stored == ALL_NOTES or 128 - stored == note):
                    sub = chain_context(ctx, br, fmt, parents)
                    if sub is not None:
                        # An All Notes pad passes the note on unchanged.
                        out.extend(chain_voices(br, fmt, parents,
                                                note if stored == ALL_NOTES else sending, sub, base))
        else:
            ctx["other"].append(tag)
    return out


def simpler_voices(dev, parents, note, ctx, base):
    """The sample parts a Simpler (or Sampler) plays for one note, one voice per
    velocity run: parts whose key zone holds the note moved by Key Zone Shift
    (which picks zones only; the pitch still follows the played note, Live
    manual) and whose selector zone holds the Sample Selector, their velocity
    crossfades made switches (velocity_runs)."""
    zone_note = note + int(round(param(dev, "Globals/KeyZoneShift", 0.0, parents)))
    selector = param(dev, "Player/SampleSelector", 0.0, parents)
    filter_on = param(dev, "Filter/IsOn", 0.0, parents) > 0.5
    common = {
        "device": value(dev, "UserName") or "",
        "volumeDb": param(dev, "VolumeAndPan/Volume", 0.0, parents),
        "velScale": param(dev, "VolumeAndPan/VolumeVelScale", 0.0, parents),
        "retrigger": param(dev, "Globals/RetriggerMode", 0.0, parents) > 0.5,
        # Simpler's filter drive: a gain into the filter's saturating circuit.
        "drive": param(dev, "Filter/Slot/Value/SimplerFilter/Drive", 0.0, parents) if filter_on else 0.0,
        "filterHz": param(dev, "Filter/Slot/Value/SimplerFilter/Freq", 22000.0, parents)
        if filter_on else None,
        "reverse": param(dev, "Player/Reverse", 0.0, parents) > 0.5,
        "startMod": param(dev, "Player/LoopModulators/SampleStart", 0.0, parents),
        "lengthMod": param(dev, "Player/LoopModulators/SampleLength", 1.0, parents),
        "classic": value(dev, "Globals/PlaybackMode") in (None, "0"),
    }
    transpose = (param(dev, "Pitch/TransposeKey", 0.0, parents)
                 + param(dev, "Pitch/TransposeFine", 0.0, parents) / 100.0)
    parts = []
    for part in dev.findall("Player/MultiSampleMap/SampleParts/MultiSamplePart"):
        if value(part, "IsActive") == "false" or float(value(part, "Volume") or 1.0) <= 0:
            continue
        k_lo, k_hi = zone_span(part.find("KeyRange"), 0, 127)
        s_lo, s_hi = zone_span(part.find("SelectorRange"), 0, 127)
        if k_lo <= zone_note <= k_hi and s_lo <= selector <= s_hi:
            parts.append(part)
    runs = velocity_runs([part.find("VelocityRange") for part in parts], ctx["velLo"], ctx["velHi"])
    voices = []
    for part, part_runs in zip(parts, runs):
        fileref = part.find("SampleRef/FileRef")
        path, missing = sample_file(fileref, base)
        for v_lo, v_hi in part_runs:
            voice = dict(common)
            voice.update(
                part=value(part, "Name") or "", path=path, missing=missing,
                sample=os.path.basename(value(fileref, "RelativePath") or value(fileref, "Path")
                                        or "") if fileref is not None else "",
                gainDb=ctx["gainDb"] + common["volumeDb"]
                + 20 * math.log10(float(value(part, "Volume") or 1.0)),
                pan=ctx["pan"] + param(dev, "VolumeAndPan/Panorama", 0.0, parents)
                + float(value(part, "Panorama") or 0.0),
                transpose=(note - int(value(part, "RootKey") or 60))
                * float(value(part, "TuneScale") or 100) / 100.0
                + float(value(part, "Detune") or 0.0) / 100.0 + transpose,
                velLo=v_lo, velHi=v_hi,
                start=int(value(part, "SampleStart") or 0), end=int(value(part, "SampleEnd") or 0))
            voices.append(voice)
    return voices


def drum_sampler_voice(dev, parents, ctx, base):
    """What a Drum Sampler plays: its one sample at its gain (linear) and volume,
    its Vel and transpose (it does not follow the note), from its Start for its
    Length (fractions of the sample). Its built-in effect is only listed."""
    fileref = dev.find("UserSample/Value/SampleRef/FileRef")
    path, missing = sample_file(fileref, base)
    gain = param(dev, "Voice_Gain", 1.0, parents)
    volume = param(dev, "Volume", 0.0, parents)
    if param(dev, "Effect_On", 0.0, parents) > 0.5:
        ctx["other"].append("Drum Sampler effect")
    filter_on = param(dev, "Voice_Filter_On", 0.0, parents) > 0.5
    return {
        "device": value(dev, "UserName") or "", "part": "", "path": path, "missing": missing,
        "sample": os.path.basename(value(fileref, "RelativePath") or value(fileref, "Path") or "")
        if fileref is not None else "",
        "volumeDb": volume,
        "gainDb": ctx["gainDb"] + volume + (20 * math.log10(gain) if gain > 0 else -120.0),
        "pan": ctx["pan"] + param(dev, "Pan", 0.0, parents),
        "velScale": param(dev, "Voice_VelocityToVolume", 0.0, parents),
        "retrigger": False, "drive": 0.0,
        "filterHz": param(dev, "Voice_Filter_Frequency", 22000.0, parents) if filter_on else None,
        "reverse": False,
        "startMod": param(dev, "Voice_PlaybackStart", 0.0, parents),
        "lengthMod": param(dev, "Voice_PlaybackLength", 1.0, parents),
        "classic": False,
        # Detune is stored in semitones (the knob's ±50 cents as ±0.5).
        "transpose": param(dev, "Voice_Transpose", 0.0, parents)
        + param(dev, "Voice_Detune", 0.0, parents),
        "velLo": ctx["velLo"], "velHi": ctx["velHi"], "start": 0, "end": 0,
    }


def voice_region(voice, info):
    """(startFrames, lenSecs) of a voice: its part's sample region, moved by
    Simpler's Start and Length; lenSecs 0 when it plays to the file's end."""
    frames = info["frames"]
    start, end = min(max(0, voice["start"]), frames - 1), voice["end"]
    if end <= start or end >= frames - 1:
        end = frames - 1
    region = end + 1 - start
    start += int(round(min(max(voice["startMod"], 0.0), 1.0) * region))
    length = min(end + 1 - start, int(round(min(max(voice["lengthMod"], 0.0), 1.0) * region)))
    if start + length >= frames:
        return start, 0.0
    return start, length / info["rate"]


# --- the kits made from the set ----------------------------------------------
# Kit-Carbon's pads are Operator voices, recorded by Ableton as the Designer
# Drums previews (Drum Hits/<category>/<pad>.adg.ogg: those presets are the
# set's pads, value for value). Each preview is peak-normalised, so the kit's
# balance is lost. It is fitted instead against Ableton's 2 s preview of the
# whole kit, Previews/Drums/Kit-Carbon.adg.ogg: a one-off done in the Phase 4
# fidelity review (review/match2.py), a least-squares fit of the single-pad
# previews at each of the kit preview's 8 hits, one coefficient per (pad, hit).
# The results, (dB on the preview file as it is, R² of the fit), hold at the
# kit preview's own, unknown, velocities.
CARBON_FITS = {
    36: (-7.1, 0.996),    # kick at 0.00 s (-7.0 at 1.00 s, R² 0.994)
    37: (-2.3, 0.829),    # sidestick, 0.75 s
    38: (-3.3, 0.954),    # snare, 0.50 s
    39: (-3.85, 0.789),   # clap: -3.5 at 0.25 s (R² 0.814), -4.2 at 1.50 s; the mean, the worse R²
    40: (-3.8, 0.789),    # snare 2: only at 1.50 s, layered with the clap; low confidence
    42: (-10.1, 0.996),   # closed hat, its accented on-beat level (the clip's accents span -9.4..-23.6)
    46: (-5.7, 0.800),    # open hat, 1.75 s
}
# The pedal hat never plays in the kit preview. Its Operator is the closed hat's
# voice with a longer decay, 4.2 dB more Operator volume and +3 dB EQ output,
# into the same 7.34:1 compressor: about 1 to 4 dB over 42 (the review). Live's
# recordings put it 4.9 dB over 42's fit (liverec, below), not the 2.5 guessed.
CARBON_DERIVED = {44: (42, 4.9)}
# The pads the patterns never play and the kit preview never shows.
CARBON_UNFITTED_DB = -6.0
# The fit gives the pads' balance, not the level Live plays them at. That was
# calibrated against Live's own recordings of the set ("liverec", the Phase 4
# comparison of Live's drum takes with SA: SA re-rendered on the patterns of
# the 28/29 Sep session takes and resampler take 0007, each hit class's band
# levels set against Live's, through the drums strip at -10.6 dB and the reverb
# at 15.08 %; with the values below every one of the 14 hat, snare and
# sidestick classes came within 1 dB of Live's).
# 1. Every Carbon layer plays 10.8 dB over its fit: the kit preview is
#    normalised, so the fit could not see the kit's own level (high confidence
#    on 36, 37, 40, 42 and 44, assumed for the others). It is in the layers, not
#    the Drums tab's trim: 44 at velocity 127 needs about 15 dB, the trim 12.
CARBON_LEVEL_DB = 10.8
# 2. Then per pad (medium-high confidence). liverec's -2 dB on 38 had low
#    confidence and is left out.
CARBON_TRIMS_DB = {36: -2.0, 37: -0.2, 40: 1.0, 42: 0.4}
# 3. Operator's velocity response is steeper than the linear placeholder on the
#    hats and the sidestick: the layer's vel 'curve', the placeholder's
#    amplitude raised to that power and anchored at velocity 88 (MegaSAKit),
#    fitted at velocities 10 to 127. 46 never plays in the takes and takes 44's.
#    Kick and snares play only at 88 there, so their law stays unmeasured.
CARBON_CURVES = {37: 1.2, 42: 2.4, 44: 2.8, 46: 2.8}

# Kit-Carbon's All Notes pad holds an Instrument Rack whose macro selects KJ
# Sawka Drumkit 9: a sampled acoustic kit sounding under every note (on 50,
# where Carbon has no pad, its floor tom alone, 8 semitones up). Its samples
# are encrypted, so each note gets a stand-in of the same INSTRUMENT from the
# Core Library, not of the same name (on 37 KJ9 plays a snare, not a
# sidestick). The Dry Session Kit is one dry acoustic kit from one session, as
# KJ9 is: the loudest take of its matching pad stands in, normalised to 0 dBFS
# as pack one-shots are, at KJ9's level. Paths under Core Library/Samples.
KJ9_STANDINS = {
    # Except the kick: Live's is far brighter than Carbon's and the Dry Session
    # kick (with KJ7 and Kit-Meaty under it alike), 15 dB more at 3-6 kHz even
    # at the right level. This vinyl kick, at its gain in KJ9_FITTED_DB,
    # matched all five bands of Live's within 1 dB (liverec; by band levels,
    # not by ear).
    "kick": "One Shots/Drums/Kick/Kick Vinyl DLJ 4.wav",
    "snare": "One Shots/Drums/Snare/Snare Stick Hit Hard Dry Session.aif",      # KJ9's Snare Tim
    "snare2": "One Shots/Drums/Snare/Snare Stick Hit Hard 2 Dry Session.aif",   # KJ9's Snare TT
    "closed": "One Shots/Drums/Hihat/Hihat Closed Stick Tip Medium.aif",
    "pedal": "One Shots/Drums/Hihat/Hihat Foot Hard.aif",
    "open": "One Shots/Drums/Hihat/Hihat Open Stick Tip Hard 2.aif",   # its open hat's selector 0
    "floor": "One Shots/Drums/Tom/Tom Stick Hit Hard Dry Session 16.aif",
    # The Dry Session ride rings 8.7 s; KJ9's 'Ride mute' is a short choked
    # hit, so a short acoustic ride stands in for it.
    "ride": "One Shots/Drums/Ride/Ride Acoustic Yakiman.aif",
    "ride2": "One Shots/Drums/Ride/Ride Stick Mid Hard Dry Session.aif",   # 'Ride Dark noisy'
}
KJ9_INSTRUMENTS = {36: "kick", 37: "snare", 38: "snare", 39: "snare2", 40: "snare2", 41: "snare2",
                   42: "closed", 44: "pedal", 46: "open", 43: "floor", 45: "floor", 47: "floor",
                   48: "floor", 50: "floor", 49: "ride", 51: "ride2"}
# KJ9's levels as the set plays them (Simpler volume plus pad volume), for a
# check: the levels are read from the set, and a set that differs is reported.
KJ9_EXPECTED_DB = {36: -16.0, 37: -25.0, 38: -15.75, 39: -21.2, 40: -13.075, 41: -16.0,
                   42: -19.0, 44: -23.0, 46: -23.0, 43: -16.0, 45: -16.0, 47: -16.0, 48: -16.0,
                   50: -16.0, 49: -22.0, 51: -22.2}
# Layer gains fitted to Live's recordings rather than KJ9's level on the
# stand-in's peak (liverec, with the Carbon kick at its calibrated level).
KJ9_FITTED_DB = {36: -11.06}
# Layer lengths (lenSecs): the closed hat's stand-in rings for 0.33 s, while
# KJ9's Hihat Art 02 lasts 82 ms and Live's 42 has died away by 80 ms (liverec).
KJ9_LEN_SECS = {42: 0.075}

# The One Hit Kit's samples (Drum Essentials) are encrypted too: Core Library
# one-shots stand in, matched by sample family and length (the originals cannot
# be heard to compare): the Phase 4 kit survey's picks. Pad 38 layers two
# Simplers, a snare and a clap, so it has two, in the set's order.
ONE_HIT_STANDINS = {
    36: ["One Shots/Drums/Kick/Kick Electrified.wav"],
    37: ["One Shots/Drums/Snare/Snare Strike Kindified.wav"],
    38: ["One Shots/Drums/Snare/Snare Kindified.wav", "One Shots/Drums/Clap/Clap Electrified.wav"],
    39: ["One Shots/Drums/Clap/Clap Acoustified Dry.wav"],
    40: ["One Shots/Drums/Snare/Snare Electrified.wav"],
    41: ["One Shots/Drums/Kick/Kick Acoustic Room.aif"],
    42: ["One Shots/Drums/Hihat/Hihat Closed Acoustified.aif"],
    43: ["One Shots/Drums/Kick/Kick Felt Crack.wav"],
    44: ["One Shots/Drums/Shaker/Shaker Acoustified 1.wav"],
    45: ["One Shots/Drums/Electronic Percussion/E-Perc Strike Burned 1.wav"],
    46: ["One Shots/Drums/Hihat/Hihat Open Acoustified.aif"],
    47: ["One Shots/Drums/Tambourine/Tamb Acoustified Plymouth.wav"],
    48: ["One Shots/Drums/Electronic Percussion/E-Perc Strike Grounded 1.wav"],
    49: ["One Shots/Drums/Cymbal/Crash Acoustified High.wav"],
    50: ["One Shots/Drums/Bell/Bell Mid Metallic Electrified.wav"],
    51: ["One Shots/Drums/Ride/Ride Acoustified.wav"],
}


def set_rack(root, name):
    """The set's Drum Rack named `name` (a track's outermost one) and its track."""
    for track, rack in kit_tracks(root):
        if value(rack, "UserName") == name:
            return track, rack
    raise KitError("the set has no Drum Rack named '%s'" % name)


def standin_for(rel, frames_wanted):
    """A Core Library one-shot by path, or when it is gone or unreadable the
    closest readable one: same folder, same first word, nearest length."""
    try:
        return core_sample(rel), None
    except KitError as e:
        folder = os.path.join(CORE_SAMPLES, os.path.dirname(rel))
        word = os.path.basename(rel).split()[0].lower()
        best = None
        for name in (sorted(os.listdir(folder)) if os.path.isdir(folder) else []):
            if not name.lower().endswith(AUDIO_EXTENSIONS) or name.split()[0].lower() != word:
                continue
            info = audio_info(os.path.join(folder, name))
            if info["readable"] and info["channels"] <= KIT_MAX_CHANNELS:
                distance = abs(info["frames"] - frames_wanted)
                if best is None or distance < best[0]:
                    best = (distance, info)
        if best is None:
            raise
        return best[1], "%s; %s instead" % (e, os.path.basename(best[1]["path"]))


def carbon_kit(set_path, root, parents, files, with_layer):
    """`carbon`: the Designer Drums previews of the set's Kit-Carbon pads, at the
    fitted levels; `carbon-layer` adds stand-ins for the KJ Sawka layer."""
    track, rack = set_rack(root, "Kit-Carbon")
    previews = {}
    for folder, _, names in os.walk(os.path.join(DRUM_PREVIEWS, "Drum Hits")):
        for name in names:
            if name.endswith(".adg.ogg"):
                previews[name[:-len(".adg.ogg")]] = os.path.join(folder, name)
    key = "carbon-layer" if with_layer else "carbon"
    pads, notes, all_notes, gains = {}, [], None, []
    for br in rack.findall("Branches/DrumBranch"):
        stored, _, choke = drum_zone(br, "als")
        if stored is None:
            continue
        if stored == ALL_NOTES:
            all_notes = br
            continue
        note, name = 128 - stored, value(br, "Name/EffectiveName") or "?"
        if name not in previews:
            notes.append("%d %s: no Designer Drums preview of that name; pad left out" % (note, name))
            continue
        kit_sample(previews[name])
        op = next(br.iter("Operator"), None)
        repeats = [d for d in br.iter("BeatRepeat") if param(d, "On", 0.0, parents) > 0.5]
        if note in CARBON_FITS:
            fitted, r2 = CARBON_FITS[note]
            fit = {"db": fitted, "r2": r2}
        elif note in CARBON_DERIVED:
            other, offset = CARBON_DERIVED[note]
            fitted, fit = CARBON_FITS[other][0] + offset, None
        else:
            fitted, fit = CARBON_UNFITTED_DB, None
        trim = CARBON_TRIMS_DB.get(note, 0.0)
        gain = fitted + CARBON_LEVEL_DB + trim
        gains.append((note, "%d: %s + %g%s = %g" % (
            note, "%g + %g" % (CARBON_FITS[CARBON_DERIVED[note][0]][0], CARBON_DERIVED[note][1])
            if note in CARBON_DERIVED else "%g" % fitted, CARBON_LEVEL_DB,
            " %s %g" % ("-" if trim < 0 else "+", abs(trim)) if trim else "", num(gain))))
        # Operator's velocity sensitivity is per oscillator; A is a carrier in
        # every algorithm, and its 'Vel' is what the pad's level follows.
        amount = param(op, "Operator.0/VelScale", 0.0, parents) / 100.0 if op is not None else 0.0
        layer = kit_layer("carbon", files.add(previews[name], "carbon", name + ".ogg"), gain,
                          law="operator", amount=amount, curve=CARBON_CURVES.get(note))
        pads[note] = kit_pad(
            name, [layer], choke=choke,
            retrigger=op is not None and param(op, "Globals/RetriggerMode", 0.0, parents) > 0.5,
            pan=param(br.find("MixerDevice"), "Panorama", 0.0, parents), fit=fit,
            beat_repeat=bool(repeats),
            repeat_filter=any(param(d, "FilterOn", 0.0, parents) > 0.5 for d in repeats))
    if not pads:
        raise KitError("no Kit-Carbon pad has a preview")
    groups = {"carbon": "Kit-Carbon"}
    notes.append("Pads: the Designer Drums previews (Ableton's recordings of these Operator pads), "
                 "names, pans, choke groups, Operator retrigger and osc A's Vel from the set's "
                 "'%s' track." % track_name(track))
    notes.append("Balance: a per-onset least-squares fit of the pad previews against Ableton's "
                 "preview of the whole kit (Phase 4 fidelity review, review/match2.py), at that "
                 "clip's unknown velocities; 'fit' holds dB and R². 39 is the mean of two fits, "
                 "40 has R² 0.79 (low confidence), 42 is its accented on-beat level, 44 is 42 + "
                 "%g dB (derived: never in the preview; from liverec, below, where the review "
                 "had 42 + 2.5), %s are %g dB (unplayed, unfitted)."
                 % (CARBON_DERIVED[44][1], "/".join(str(n) for n in sorted(pads)
                                                     if n not in CARBON_FITS
                                                     and n not in CARBON_DERIVED),
                    CARBON_UNFITTED_DB))
    notes.append("Level: calibrated against Live's own recordings of the set (liverec, the Phase 4 "
                 "comparison of Live's drum takes with SA: SA re-rendered on the patterns of the "
                 "28/29 Sep session takes and resampler take 0007, each hit class's band levels "
                 "set against Live's through the drums strip at -10.6 dB and the reverb at 15.08 "
                 "%%; then all 14 hat, snare and sidestick classes came within 1 dB of Live's). "
                 "Every Carbon layer plays %g dB over its fit (the kit preview is normalised; high "
                 "confidence on 36, 37, 40, 42 and 44, assumed for the others), then per pad %s dB "
                 "(medium-high confidence; liverec's -2 dB on 38 had low confidence and is left "
                 "out). Layer gains: %s."
                 % (CARBON_LEVEL_DB, ", ".join("%d %+g" % (n, CARBON_TRIMS_DB[n])
                                               for n in sorted(CARBON_TRIMS_DB)),
                    "; ".join(text for _, text in sorted(gains))))
    notes.append("Velocity: law 'operator', amount = osc A's Vel (Operator's own law is unknown: "
                 "a linear placeholder), and on %s a 'curve': the placeholder's amplitude to that "
                 "power, anchored at velocity 88, fitted to Live's hats and sidestick at "
                 "velocities 10 to 127 (liverec; 46, never in the takes, as 44). Kick and snares "
                 "play only at 88 in the takes: their law is unmeasured."
                 % ", ".join("%d %g" % (n, CARBON_CURVES[n]) for n in sorted(CARBON_CURVES)))
    notes.append("Beat Repeat: on for every pad whose chain has one on in the set, its band filter "
                 "where the set's is on. The pads' EQ, Saturator and Compressor are in the "
                 "recordings; the track's Limiter is not.")
    if with_layer:
        groups["layer"] = "KJ Sawka 9 stand-in"
        if all_notes is None:
            raise KitError("Kit-Carbon has no All Notes pad: no layer to stand in for")
        # The chain the All Notes rack's selector picks (its macro, in the set).
        selector_rack = next(all_notes.iter("InstrumentGroupDevice"), None)
        picked = []
        if selector_rack is not None:
            chosen = param(selector_rack, "ChainSelector", 0.0, parents)
            for b in selector_rack.findall("Branches/InstrumentBranch"):
                lo, hi = zone_span(b.find("BranchSelectorRange"), 0, 127)
                if lo <= chosen <= hi:
                    picked.append(value(b, "Name/EffectiveName") or "?")
        if picked != ["KJ Sawka Drumkit 9"]:
            notes.append("WARNING: the All Notes rack plays %s, not KJ Sawka Drumkit 9 alone; "
                         "the stand-ins below are KJ9's." % (", ".join(picked) or "nothing"))
            print("carbon-layer: the All Notes rack plays %s; the stand-ins are KJ9's"
                  % (", ".join(picked) or "nothing"), file=sys.stderr)
        base = os.path.dirname(set_path)
        for note in sorted(KJ9_INSTRUMENTS):
            ctx = chain_context(new_context(), all_notes, "als", parents)
            voices = chain_voices(all_notes, "als", parents, note, ctx, base) if ctx else []
            if not voices:
                notes.append("layer %d: KJ9 plays nothing there" % note)
                continue
            level = max(v["gainDb"] for v in voices)
            if abs(level - KJ9_EXPECTED_DB[note]) > 0.05:
                print("carbon-layer: KJ9 plays %d at %.3f dB in the set, not the %.3f dB of the "
                      "Phase 4 table; using the set's" % (note, level, KJ9_EXPECTED_DB[note]),
                      file=sys.stderr)
            rel = KJ9_STANDINS[KJ9_INSTRUMENTS[note]]
            info = core_sample(rel)
            peak = -to_full_scale(info)
            gain = KJ9_FITTED_DB.get(note, level - peak)
            layer = kit_layer("layer", files.add(info["path"], key), gain,
                              transpose=voices[0]["transpose"],
                              len_secs=KJ9_LEN_SECS.get(note, 0.0), law="simpler",
                              amount=voices[0]["velScale"])
            if note in pads:
                pads[note]["layers"].append(layer)
            else:
                pads[note] = kit_pad("KJ Floor Tom %+g" % voices[0]["transpose"]
                                     if KJ9_INSTRUMENTS[note] == "floor" else "KJ " + voices[0]["part"],
                                     [layer], retrigger=voices[0]["retrigger"])
            sampled = sorted({v["sample"] for v in voices})
            notes.append("layer %d: KJ9 plays %s at %.3f dB%s -> %s (peak %.1f dBFS) at %.3f dB%s%s"
                         % (note, " / ".join(sampled), level,
                            ", %+g st" % voices[0]["transpose"] if voices[0]["transpose"] else "",
                            os.path.basename(rel), peak, gain,
                            ", fitted to Live's kick (liverec; KJ9's level on its peak would be "
                            "%.3f)" % (level - peak) if note in KJ9_FITTED_DB else "",
                            ", cut at %g s (liverec)" % KJ9_LEN_SECS[note]
                            if note in KJ9_LEN_SECS else ""))
        notes.append("Layer: KJ Sawka Drumkit 9 is encrypted; stand-ins by INSTRUMENT from the "
                     "Core Library's Dry Session Kit (one dry acoustic kit, as KJ9 is): one "
                     "sample per pad, its loudest take, normalised to 0 dBFS, at KJ9's level; "
                     "law 'simpler' with KJ9's Vel 0.25. KJ9 has velocity layers only on its "
                     "floor tom; the Dry Session floor tom has two takes, not four, so one plays "
                     "on all velocities. 41 layers KJ9's three Snare TT takes, one here. 49 and "
                     "51 (rides, unplayed by the patterns) use a short acoustic ride and the "
                     "Dry Session ride.")
        notes.append("Except, from liverec: on 36 %s at %g dB, not the Dry Session kick at KJ9's "
                     "level. Live's kick is far brighter than Carbon's (with KJ7 and Kit-Meaty "
                     "under it alike), 15 dB more at 3-6 kHz even at the right level; this one "
                     "matched all five of its bands within 1 dB (medium confidence: by band "
                     "levels, not by ear). On 42 the stand-in, which rings 0.33 s, is cut at %g "
                     "s: KJ9's Hihat Art 02 lasts 82 ms, and Live's 42 has died away by 80 ms. "
                     "The layer's level is otherwise not checked: no recording is known to hold "
                     "KJ9 (they hold Kit-Meaty or other layers, under a Carbon that dominates)."
                     % (os.path.splitext(os.path.basename(KJ9_STANDINS["kick"]))[0],
                        KJ9_FITTED_DB[36], KJ9_LEN_SECS[42]))
        notes.append("The layer's balance against Carbon is KJ9's level on normalised stand-ins: "
                     "the Drums tab's layer trim sets it by ear.")
        notes.append("Per-pad retrigger is Carbon's; on 49 and 51 KJ9's layer would not "
                     "retrigger. The layer is not beat-repeated (it is not in the pads' chains).")
    notes.append("Not changed by the calibration (liverec): the drums strip (-10.6 dB) and the "
                 "reverb (15.08 %); no limiter. The levels above hold through them.")
    description = ("Kit-Carbon as Ableton recorded its pads (Designer Drums previews), at Live's "
                   "level" + (", over stand-ins for the set's KJ Sawka 9 layer" if with_layer
                              else ", without the KJ Sawka layer"))
    return {
        "version": KIT_VERSION, "key": key,
        "name": "Kit-Carbon + layer" if with_layer else "Kit-Carbon",
        "description": description,
        "source": "%s (track '%s'); previews %s; fit: Phase 4 fidelity review; level: Live's "
                  "recordings of the set (Phase 4 liverec)%s" % (
            tilde(set_path), track_name(track), tilde(os.path.join(DRUM_PREVIEWS, "Drum Hits")),
            "; layer stand-ins: Live 12 Suite Core Library, %s" % CORE_SAMPLES if with_layer else ""),
        "groups": groups,
        "pads": {str(n): pads[n] for n in sorted(pads)},
        "notes": notes,
    }


def one_hit_kit(set_path, root, parents, files):
    """`one-hit`: Core Library stand-ins for the set's One Hit Kit, which plays
    the Looper's onset notes, at the set's Simpler levels and settings."""
    track, rack = set_rack(root, "One Hit Kit")
    base = os.path.dirname(set_path)
    pads, notes = {}, []
    for br in rack.findall("Branches/DrumBranch"):
        stored, sending, choke = drum_zone(br, "als")
        if stored is None or stored == ALL_NOTES or 128 - stored not in ONE_HIT_STANDINS:
            continue
        note = 128 - stored
        ctx = chain_context(new_context(), br, "als", parents)
        voices = chain_voices(br, "als", parents, sending, ctx, base) if ctx else []
        wanted = ONE_HIT_STANDINS[note]
        if len(voices) != len(wanted):
            notes.append("%d: the set's pad plays %d samples, %d stand-ins; paired in order"
                         % (note, len(voices), len(wanted)))
        layers, names = [], []
        for voice, rel in zip(voices, wanted):
            info, why = standin_for(rel, voice["end"] + 1)
            if why:
                notes.append("%d: %s" % (note, why))
            peak = -to_full_scale(info)
            layers.append(kit_layer("onehit", files.add(info["path"], "one-hit"),
                                    voice["gainDb"] - peak, transpose=voice["transpose"],
                                    vel_lo=voice["velLo"], vel_hi=voice["velHi"],
                                    drive=voice["drive"], law="simpler", amount=voice["velScale"]))
            names.append(os.path.splitext(os.path.basename(info["path"]))[0])
            notes.append("%d %s: %s at %.2f dB (Simpler %.2f + part %.2f), Vel %.3f, drive "
                         "%.2f dB -> %s (peak %.1f dBFS) at %.2f dB"
                         % (note, value(br, "Name/EffectiveName"), voice["sample"],
                            voice["gainDb"], voice["volumeDb"], voice["gainDb"] - voice["volumeDb"],
                            voice["velScale"], voice["drive"], os.path.basename(info["path"]),
                            peak, voice["gainDb"] - peak))
        if layers:
            pads[note] = kit_pad(" + ".join(names), layers, choke=choke,
                                 retrigger=any(v["retrigger"] for v in voices), pan=voices[0]["pan"])
    if not pads:
        raise KitError("no One Hit Kit pad could be built")
    notes.append("The One Hit Kit's Drum Essentials samples are encrypted; Core Library one-shots "
                 "stand in, matched by family and length only (the Phase 4 kit survey). Each "
                 "layer's gainDb is the set's Simpler volume plus part volume, plus the stand-in's "
                 "peak normalisation to 0 dBFS: the originals' peaks are unknown, and pack "
                 "one-shots are normalised.")
    notes.append("Velocity: law 'simpler' with each Simpler's Vel. drive: the Simpler filter's "
                 "drive in dB (the filters are open at 22 kHz); Live applies it before the "
                 "Simpler volume, to the sample at its own level.")
    notes.append("Not reproduced: the reverbs on pads 38 and 39 and the Limiter on 38 (heard "
                 "only when the onset note is 38 or 39), and the kit's 'Drum Machines Audio "
                 "Effect' chain, which MegaSA builds as the onset FX (\\megaSAOnsetFx).")
    return {
        "version": KIT_VERSION, "key": "one-hit", "name": "One Hit Kit",
        "description": "Core Library stand-ins for the set's One Hit Kit, which plays the "
                       "Looper's onset notes",
        "source": "%s (track '%s'); stand-ins: Live 12 Suite Core Library, %s" % (
            tilde(set_path), track_name(track), CORE_SAMPLES),
        "groups": {"onehit": "One Hit Kit stand-ins"},
        "pads": {str(n): pads[n] for n in sorted(pads)},
        "notes": notes,
    }


# --- kits converted from Drum Rack presets -----------------------------------
# Core Library kits SA ships converted: (key, preset under Racks/Drum Racks).
# The three the plan names, then three more for range: the 707 and the CR-78
# (machines the 808/909 pair lacks) and an electronic kit.
CORE_KITS = [
    ("core-808", "Drum Machines/808 Core Kit.adg"),
    ("core-909", "Drum Machines/909 Core Kit.adg"),
    ("core-dry-session", "Acoustic/Dry Session Kit.adg"),
    ("core-707", "Drum Machines/707 Core Kit.adg"),
    ("core-c78", "Drum Machines/C78 Core Kit.adg"),
    ("core-flares", "Electronic/Flares Kit.adg"),
]


def adg_kit(path, key, files, description=None):
    """A kit from any Drum Rack preset (.adg) whose samples are readable: each
    pad's sample parts (its selector's part, velocity zones as layers) with
    the preset's volumes, pans, transposes, Vel and choke groups."""
    try:
        root, parents = load_set(path)
    except (OSError, ET.ParseError, EOFError) as e:
        raise KitError("%s: not a readable preset (%s)" % (tilde(path), e))
    found = None
    for preset in root.iter("GroupDevicePreset"):
        dev = preset.find("Device")
        if dev is not None and len(dev) and dev[0].tag == "DrumGroupDevice":
            found = (dev[0], preset)
            break
    if found is None:
        raise KitError("%s holds no Drum Rack" % tilde(path))
    rack, wrapper = found
    # Devices around the Drum Rack (a bus chain beside it in an outer rack).
    around = []
    for holder in root.iter("Device"):
        if not len(holder) or holder[0] is rack or holder[0].tag in RACK_TAGS \
                or holder[0].tag == "AudioBranchMixerDevice" or param(holder[0], "On", 1.0) < 0.5:
            continue
        node = holder
        while node is not None and node is not wrapper:
            node = parents.get(node)
        if node is None:
            around.append(holder[0].tag)
    top = root.find("GroupDevicePreset/Device")
    name = value(rack, "UserName") or (value(top[0], "UserName") if top is not None and len(top)
                                       else None) or os.path.splitext(os.path.basename(path))[0]
    base = os.path.dirname(path)
    keyed, everywhere = [], []
    for br in rack_branches(rack, wrapper, "adg"):
        stored, sending, choke = drum_zone(br, "adg")
        if stored is None:
            continue
        (everywhere if stored == ALL_NOTES else keyed).append((br, stored, sending, choke))
    # A rack of All Notes pads only (a whole kit nested in one pad) plays 36-51.
    played_notes = sorted({128 - s for _, s, _, _ in keyed}) or list(range(36, 52))
    pads, notes, skipped, peaks = {}, [], [], {}
    others, filters, shifts, reversed_, hot = set(), [], [], [], []
    for note in played_notes:
        voices, label, choke = [], None, 0
        ctx = new_context()
        for br, stored, sending, br_choke in keyed:
            if 128 - stored == note:
                sub = chain_context(ctx, br, "adg", None)
                if sub is not None:
                    voices += chain_voices(br, "adg", None, sending, sub, base)
                label, choke = label or pad_label(br, "adg"), br_choke
        for br, stored, sending, br_choke in everywhere:
            sub = chain_context(ctx, br, "adg", None)
            if sub is not None:
                voices += chain_voices(br, "adg", None, note, sub, base)
        others.update(ctx["other"])
        layers, why = [], []
        for voice in voices:
            if voice["reverse"]:
                reversed_.append(note)
                continue
            try:
                if voice["path"] is None:
                    raise KitError(voice["missing"])
                info = kit_sample(voice["path"])
            except KitError as e:
                why.append(str(e))
                continue
            start, length = voice_region(voice, info)
            rel = files.add(info["path"], key)
            layers.append(kit_layer("kit", rel, voice["gainDb"],
                                    transpose=voice["transpose"], vel_lo=voice["velLo"],
                                    vel_hi=voice["velHi"], start_frames=start, len_secs=length,
                                    drive=voice["drive"], law="simpler", amount=voice["velScale"]))
            # At velocity 127 Simpler's law adds 22.8 dB times Vel (MegaSAKit).
            peak = peaks[rel] = peak_dbfs(info)
            if peak is not None and voice["velHi"] == 127 \
                    and voice["gainDb"] + 22.8 * voice["velScale"] + peak > 0:
                hot.append("%d %+.1f dBFS" % (note, voice["gainDb"] + 22.8 * voice["velScale"] + peak))
            if voice["filterHz"] is not None and voice["filterHz"] < 18000:
                filters.append("%d (%.0f Hz)" % (note, voice["filterHz"]))
            if abs(voice["transpose"]) >= 0.5 and not any(s.startswith("%d " % note) for s in shifts):
                shifts.append("%d %s %+g st" % (note, voice["sample"], round(voice["transpose"], 2)))
        if not layers:
            skipped.append("%d %s: %s" % (note, label or "?", "; ".join(why) if why else
                                          "no sample instrument plays it"))
            continue
        label = label or (voices[0]["part"] or os.path.splitext(voices[0]["sample"])[0])
        pads[note] = kit_pad(label, layers, choke=choke,
                             retrigger=any(v["retrigger"] for v in voices), pan=voices[0]["pan"])
    if not pads:
        raise KitError("%s: no pad plays a readable sample (%s%s)" % (
            tilde(path), "; ".join(skipped[:2]),
            "; and %d pads more" % (len(skipped) - 2) if len(skipped) > 2 else ""))
    # A pad far over the others at velocity 127 comes down to HOT_PAD_DB over
    # their median, by its pad gainDb: its layers keep the preset's levels.
    median, pulled = hot_pads(pads, peaks)
    for note, peak, over in pulled:
        pads[note]["gainDb"] = num(pads[note]["gainDb"] - over)
    notes.append("Converted from the preset: each pad's sample parts for its note, Key Zone Shift "
                 "and Sample Selector as stored; velocity zones become layers, a crossfade a "
                 "switch where a part falls below half its level (a fade at the velocity range's "
                 "edge keeps playing). gainDb = pad and chain faders + Simpler volume + part "
                 "volume; Vel as law 'simpler'.")
    notes.append("Not reproduced: the instruments' envelopes (every sample plays its region to the end), "
                 "filters (only their drive), the pads' other devices (%s) and the devices around the "
                 "Drum Rack (%s)." % (", ".join(sorted(others)) or "none",
                                      ", ".join(around) or "none"))
    if skipped:
        notes.append("Left out: " + "; ".join(skipped))
    if filters:
        notes.append("Simpler filters closed below 18 kHz, not reproduced, on: " + ", ".join(filters))
    if shifts:
        notes.append("Transposed parts, by the preset's transpose or root key, or by a Key Zone "
                     "Shift, which picks another zone's part and plays it relative to the played "
                     "note (Live's manual; unverified in Live): " + "; ".join(shifts))
    if reversed_:
        notes.append("Reversed parts left out on: %s" % ", ".join(str(n) for n in sorted(set(reversed_))))
    if hot:
        notes.append("Over full scale at velocity 127 as the preset sets them (before the drums' "
                     "strip): " + ", ".join(hot))
    if pulled:
        notes.append("Pulled down to %g dB over the kit's median pad at velocity 127 (%.1f dBFS "
                     "before the drums' strip), by the pad's gainDb, its layers as the preset sets "
                     "them: %s. A pad far over the rest is out of the kit's balance, and SA's "
                     "drums have no limiter: with the loop on top it can drive the master into "
                     "its clip."
                     % (HOT_PAD_DB, median, ", ".join(
                         "%d %s %+.1f dBFS, %.2f dB" % (n, pads[n]["name"], peak, -over)
                         for n, peak, over in pulled)))
    for line in skipped:
        print("%s: left out %s" % (key, line), file=sys.stderr)
    return {
        "version": KIT_VERSION, "key": key, "name": name,
        "description": description or "Converted from the Drum Rack preset '%s'" % name,
        "source": tilde(path),
        "groups": {"kit": name},
        "pads": {str(n): pads[n] for n in sorted(pads)},
        "notes": notes,
    }


# --- kits from a folder of one-shots -----------------------------------------
# Words in a file's name (or in its folders' names) that place it on a pad of
# Live's General MIDI drum layout, tried in this order so that "Conga Open" is
# percussion before "open" can make it an open hat.
FOLDER_WORDS = [
    ("kick", {"kick", "kicks", "kik", "kck", "bd", "bassdrum"}),
    ("rim", {"rim", "rims", "rimshot", "rimclick", "side", "sidestick", "rs"}),
    ("clap", {"clap", "claps", "clp", "cp", "handclap"}),
    ("snare", {"snare", "snares", "snr", "sd"}),
    ("tom", {"tom", "toms", "floortom", "tm", "lt", "mt", "ht", "ft"}),
    ("crash", {"crash", "crashes", "cymbal", "cym", "splash", "china"}),
    ("ride", {"ride", "rides", "rd"}),
    ("perc", {"perc", "percs", "percussion", "shaker", "shake", "tamb", "tambourine", "cowbell",
              "conga", "bongo", "clave", "claves", "block", "woodblock", "bell", "tabla", "guiro",
              "maraca", "maracas", "cabasa", "triangle", "timbale", "timbales", "agogo", "snap"}),
]
HAT_WORDS = {"hat", "hats", "hihat", "hihats", "hh", "hhat"}
OPEN_WORDS = {"open", "ohh", "oh", "opn"}
PEDAL_WORDS = {"pedal", "foot", "ph", "phh"}
CLOSED_WORDS = {"closed", "chh", "ch", "clsd"}
FOLDER_PADS = {"kick": [36], "rim": [37], "snare": [38, 40], "clap": [39], "closed": [42],
               "pedal": [44], "open": [46], "tom": [41, 43, 45, 47, 48, 50], "crash": [49],
               "ride": [51]}
TOM_HEIGHT = [({"floor", "ft"}, 0), ({"low", "lo", "lt"}, 1), ({"mid", "med", "middle", "mt"}, 2),
              ({"high", "hi", "ht"}, 3)]
# A folder kit's levels: each sample's peak at -8 dBFS, and Simpler's law at
# 0.35, which lifts velocity 127 by 8 dB: a full-scale hit at the top.
FOLDER_PEAK_DB = -8.0
FOLDER_VEL = 0.35


def name_words(text):
    """The words of a file or folder name, lower case: 'KickHard_02' -> kick hard 02."""
    return [w.lower() for w in re.findall(r"[A-Z]+(?![a-z])|[A-Z]?[a-z]+|[0-9]+", text)]


def folder_category(words):
    w = set(words)
    joined = " ".join(words)
    if w & HAT_WORDS or "hi hat" in joined:
        return "open" if w & OPEN_WORDS else "pedal" if w & PEDAL_WORDS else "closed"
    if w & {"ohh", "oh"}:
        return "open"
    if w & {"chh", "ch"}:
        return "closed"
    if w & PEDAL_WORDS:
        return "pedal"
    if "bass drum" in joined:
        return "kick"
    for category, keywords in FOLDER_WORDS:
        if w & keywords:
            return category
    if w & OPEN_WORDS:
        return "open"
    if w & CLOSED_WORDS:
        return "closed"
    return None


def folder_kit(folder, key, files):
    """A kit from a folder of one-shots (a free download, say): pads by words in
    the file names, toms low to high; what does not fit is listed."""
    if not os.path.isdir(folder):
        raise KitError("no folder %s" % tilde(folder))
    found = []
    for here, dirs, names in os.walk(folder):
        dirs.sort()
        for name in sorted(names):
            if name.startswith(".") or not name.lower().endswith(AUDIO_EXTENSIONS):
                continue
            path = os.path.join(here, name)
            rel = os.path.relpath(path, folder)
            category = folder_category(name_words(os.path.splitext(name)[0]))
            for part in reversed(rel.split(os.sep)[:-1]):
                if category is None:
                    category = folder_category(name_words(part))
            found.append((category, rel, path))
    if not found:
        raise KitError("no sound files in %s" % tilde(folder))
    by = {}
    for category, rel, path in found:
        by.setdefault(category, []).append((rel, path))

    def height(item):
        words = set(name_words(item[0]))
        level = next((h for ws, h in TOM_HEIGHT if words & ws), 1.5)
        digits = [int(d) for d in re.findall(r"[0-9]+", os.path.basename(item[0]))]
        return (level, digits, item[0].lower())

    taken, unmapped = {}, []
    for category in ("kick", "rim", "snare", "clap", "closed", "pedal", "open", "tom", "crash",
                     "ride"):
        items = by.get(category, [])
        slots = list(FOLDER_PADS[category])
        if category == "tom":
            items = sorted(items, key=height)
            if 0 < len(items) < len(slots):
                # Spread fewer toms over the six tom pads, low to high.
                picks = [0] if len(items) == 1 else \
                    [int(round(i * (len(slots) - 1) / float(len(items) - 1))) for i in range(len(items))]
                slots = [slots[i] for i in picks] if len(items) > 1 else [45]
        for (rel, path), note in zip(items, slots):
            taken[note] = (category, rel, path)
        unmapped += [rel for rel, _ in items[len(slots):]]
    free = [n for n in range(36, 52) if n not in taken]
    perc = by.get("perc", [])
    for (rel, path), note in zip(perc, free):
        taken[note] = ("perc", rel, path)
    unmapped += [rel for rel, _ in perc[len(free):]] + [rel for rel, _ in by.get(None, [])]
    pads, notes, problems = {}, [], []
    for note in sorted(taken):
        category, rel, path = taken[note]
        try:
            info = kit_sample(path)
        except KitError as e:
            problems.append(str(e))
            continue
        peak = peak_dbfs(info)
        gain = FOLDER_PEAK_DB - peak if peak is not None and peak > float("-inf") else 0.0
        layer = kit_layer("kit", files.add(path, key), gain, law="simpler", amount=FOLDER_VEL)
        pads[note] = kit_pad(os.path.splitext(os.path.basename(rel))[0], [layer],
                             choke=1 if note in (42, 44, 46) else 0,
                             retrigger=category not in ("closed", "pedal", "open", "crash", "ride"))
        if peak is None:
            notes.append("%d %s: a compressed file, its peak unknown: gain 0 dB" % (note, rel))
        print("%s  %d  %-6s %s" % (key, note, category, rel))
    for rel in unmapped:
        print("%s  unmapped: %s" % (key, rel))
    for line in problems:
        print("%s  unreadable: %s" % (key, line), file=sys.stderr)
    if not pads:
        raise KitError("no readable one-shot in %s" % tilde(folder))
    notes.append("Pads by words in the file names (kick, snare, rim/side, clap, hat closed/chh, "
                 "pedal, open/ohh, toms low to high, crash, ride, perc on the free pads). Each "
                 "sample's peak normalised to %g dBFS; law 'simpler' at %g (velocity 127 = the "
                 "peak at 0 dBFS); hats in choke group 1; drums retrigger, hats and cymbals ring."
                 % (FOLDER_PEAK_DB, FOLDER_VEL))
    if unmapped:
        notes.append("Not on a pad: " + "; ".join(unmapped))
    if problems:
        notes.append("Unreadable: " + "; ".join(problems))
    name = os.path.basename(os.path.normpath(folder))
    return {
        "version": KIT_VERSION, "key": key, "name": name,
        "description": "One-shots from the folder '%s'" % name,
        "source": tilde(os.path.abspath(folder)),
        "groups": {"kit": name},
        "pads": {str(n): pads[n] for n in sorted(pads)},
        "notes": notes,
    }


# --- the drum reverb's impulse responses -------------------------------------
# Hybrid Reverb on the set's 'drums' group convolves with the true-stereo pair
# 'Early Reflections / Ableton Studio Backwards': an L file (what the left input
# makes) and an R file (the right input's), each with both outputs. MegaSA runs
# it as four mono convolutions at the server's rate.
IR_PAIR = ("Hybrid_Early_Reflections_Ableton Studio Backwards L.aif",
           "Hybrid_Early_Reflections_Ableton Studio Backwards R.aif")
IR_RATE = 48000
# PartConv passes an impulse response at unity gain, and this pair adds 12 dB
# of energy per output, where Live evidently normalises an IR's level: at 1/4
# (-12.04 dB) every path leaves a centred input's wet energy equal to its own
# (the Phase 4 fidelity review; Hybrid Reverb's exact rule is not known).
IR_SCALE = 0.25
# (file name, which file, which channel of it, the path it is)
IR_PATHS = (("ll", 0, 0, "in L -> out L"), ("lr", 0, 1, "in L -> out R"),
            ("rl", 1, 0, "in R -> out L"), ("rr", 1, 1, "in R -> out R"))
IR_TAPS = 64
IR_BETA = 8.6
IR_CUTOFF = 0.97


def bessel_i0(x):
    total, term, k = 1.0, 1.0, 1
    while term > 1e-15 * total:
        term *= (x / (2.0 * k)) ** 2
        total += term
        k += 1
    return total


def resample(signal, rate_in, rate_out, taps=IR_TAPS, beta=IR_BETA, cutoff=IR_CUTOFF):
    """Band-limited resampling: a Kaiser-windowed sinc of `taps` taps, cut off at
    `cutoff` of the lower Nyquist, normalised per output phase so a constant
    stays constant. An impulse response is a filter, so the result is scaled by
    rate_in / rate_out as well: it then filters at the new rate as the original
    did at its own (a sampled kernel's gain grows with the sample rate)."""
    step = Fraction(int(rate_in), int(rate_out))     # input samples per output sample
    half = taps // 2
    fc = cutoff * min(1.0, float(rate_out) / rate_in)
    gain, window0 = float(rate_in) / rate_out, bessel_i0(beta)
    kernels, out = {}, []
    for n in range(-(-len(signal) * step.denominator // step.numerator)):
        k0, phase = divmod(n * step.numerator, step.denominator)
        weights = kernels.get(phase)
        if weights is None:
            frac, weights = phase / float(step.denominator), []
            for j in range(1 - half, half + 1):
                t = frac - j                         # this tap's distance in input samples
                x = math.pi * fc * t
                s = fc * (math.sin(x) / x if x else 1.0)
                weights.append(s * bessel_i0(beta * math.sqrt(max(0.0, 1.0 - (t / half) ** 2)))
                               / window0)
            total = sum(weights)
            weights = kernels[phase] = [gain * w / total for w in weights]
        acc = 0.0
        for j, w in zip(range(k0 + 1 - half, k0 + half + 1), weights):
            if 0 <= j < len(signal):
                acc += signal[j] * w
        out.append(acc)
    return out


def write_float_wav(path, samples, rate):
    """A mono 32-bit float WAV: format 3, with the fact chunk the format asks for."""
    data = array.array("f", samples)
    if sys.byteorder == "big":
        data.byteswap()
    payload = data.tobytes()
    fmt = struct.pack("<HHIIHHH", 3, 1, int(rate), int(rate) * 4, 4, 32, 0)
    body = (b"WAVE" + b"fmt " + struct.pack("<I", len(fmt)) + fmt
            + b"fact" + struct.pack("<II", 4, len(samples))
            + b"data" + struct.pack("<I", len(payload)) + payload)
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", len(body)) + body)


def build_ir(kits_dir):
    """_ir/: the four paths of Hybrid Reverb's pair as mono 48 kHz float WAVs,
    scaled, with _ir/ir.json describing them."""
    infos = [audio_info(os.path.join(HYBRID_IRS, name)) for name in IR_PAIR]
    for name, info in zip(IR_PAIR, infos):
        if not info["readable"] or info["codec"] not in ("pcm", "float") or info["channels"] != 2:
            raise KitError("impulse response %s: %s" % (name, info["why"] or "%d channels"
                                                         % info["channels"]))
    os.makedirs(inside(kits_dir, "_ir"), exist_ok=True)
    files, energies, frames = {}, {}, 0
    for name, which, channel, _ in IR_PATHS:
        info = infos[which]
        signal = channel_samples(info, channel)
        if info["rate"] != IR_RATE:
            signal = resample(signal, info["rate"], IR_RATE)
        signal = [x * IR_SCALE for x in signal]
        files[name] = "_ir/%s.wav" % name
        write_float_wav(inside(kits_dir, files[name]), signal, IR_RATE)
        energies[name] = num(10 * math.log10(sum(x * x for x in signal)), 2)
        frames = len(signal)
    meta = {
        "version": 1, "rate": IR_RATE, "frames": frames, "scale": IR_SCALE,
        "rateGain": num(infos[0]["rate"] / IR_RATE, 6),
        "files": files, "paths": {name: what for name, _, _, what in IR_PATHS},
        "energyDb": energies,
        "source": "Hybrid Reverb, 'Early Reflections / Ableton Studio Backwards': %s (in L) and "
                  "%s (in R), 2 channels (out L, out R), %g Hz" % (
                      os.path.join(HYBRID_IRS, IR_PAIR[0]), IR_PAIR[1], infos[0]["rate"]),
        "method": "Each channel apart; resampled to %d Hz with a Kaiser-windowed sinc (%d taps, "
                  "beta %g, cut off at %g of the source Nyquist) and scaled by the rate ratio "
                  "so it filters as at the source rate; times %g (-12.04 dB: unit energy per "
                  "output for a centred input, the Phase 4 fidelity review); 32-bit float." % (
                      IR_RATE, IR_TAPS, IR_BETA, IR_CUTOFF, IR_SCALE),
    }
    with open(inside(kits_dir, "_ir/ir.json"), "w") as f:
        f.write(json.dumps(meta, indent=1, ensure_ascii=False) + "\n")
    print("%s  (4 paths, %d frames at %d Hz, x%g; energy dB %s)" % (
        shown(inside(kits_dir, "_ir/ir.json")), frames, IR_RATE, IR_SCALE,
        " ".join("%s %+.2f" % (k, energies[k]) for k in sorted(energies))))


# --- checking ------------------------------------------------------------------
def kit_problems(kit, key):
    """What is wrong with a kit's JSON, as MegaSAKit would read it (no files)."""
    problems = []

    def number(x):
        return isinstance(x, (int, float)) and not isinstance(x, bool)

    if kit.get("version") != KIT_VERSION:
        problems.append("version %r, not %d" % (kit.get("version"), KIT_VERSION))
    if kit.get("key") != key:
        problems.append("key %r in %s.json" % (kit.get("key"), key))
    for field in ("name", "description", "source"):
        if not isinstance(kit.get(field), str):
            problems.append("no %s" % field)
    groups = kit.get("groups") if isinstance(kit.get("groups"), dict) else {}
    pads = kit.get("pads") if isinstance(kit.get("pads"), dict) else {}
    if not pads:
        problems.append("no pads")
    for note, pad in sorted(pads.items()):
        where = "pad %s" % note
        if not note.isdigit() or not 0 <= int(note) <= 127:
            problems.append("%s: not a MIDI note" % where)
        if not isinstance(pad.get("name"), str) or not isinstance(pad.get("retrigger"), bool) \
                or not isinstance(pad.get("beatRepeat"), bool) \
                or not isinstance(pad.get("repeatFilter"), bool):
            problems.append("%s: name, retrigger, beatRepeat or repeatFilter missing" % where)
        if not isinstance(pad.get("choke"), int) or pad.get("choke") < 0:
            problems.append("%s: choke %r" % (where, pad.get("choke")))
        if not number(pad.get("pan")) or not -1 <= pad["pan"] <= 1 or not number(pad.get("gainDb")):
            problems.append("%s: pan or gainDb" % where)
        layers = pad.get("layers") if isinstance(pad.get("layers"), list) else []
        if not layers:
            problems.append("%s: no layers" % where)
        for i, layer in enumerate(layers):
            at = "%s layer %d" % (where, i)
            vel = layer.get("vel") if isinstance(layer.get("vel"), dict) else {}
            if layer.get("group") not in groups:
                problems.append("%s: group %r not in groups" % (at, layer.get("group")))
            if not isinstance(layer.get("file"), str):
                problems.append("%s: no file" % at)
            if not all(number(layer.get(f)) for f in ("gainDb", "transpose", "lenSecs", "drive")):
                problems.append("%s: gainDb, transpose, lenSecs or drive" % at)
            elif layer["lenSecs"] < 0 or layer["drive"] < 0:
                problems.append("%s: negative lenSecs or drive" % at)
            lo, hi = layer.get("velLo"), layer.get("velHi")
            if not (isinstance(lo, int) and isinstance(hi, int) and 1 <= lo <= hi <= 127):
                problems.append("%s: velocity zone %r..%r" % (at, lo, hi))
            if not isinstance(layer.get("startFrames"), int) or layer["startFrames"] < 0:
                problems.append("%s: startFrames" % at)
            if vel.get("law") not in ("simpler", "operator", "none") or not number(vel.get("amount")) \
                    or not 0 <= vel["amount"] <= 1 \
                    or ("curve" in vel and not (number(vel["curve"]) and vel["curve"] > 0)):
                problems.append("%s: vel %r" % (at, vel))
    return problems


def check_kits(kits_dir):
    """Every kit JSON against its schema and its files, as a table."""
    names = sorted(n for n in os.listdir(kits_dir) if n.endswith(".json")) \
        if os.path.isdir(kits_dir) else []
    if not names:
        print("no kits in %s" % shown(kits_dir), file=sys.stderr)
        return 1
    rows, details = [], []
    for name in names:
        key = name[:-len(".json")]
        try:
            with open(os.path.join(kits_dir, name)) as f:
                kit = json.load(f)
            problems = kit_problems(kit, key)
            rels = kit_files(kit)
        except (ValueError, KeyError, TypeError, AttributeError) as e:
            rows.append((key, "-", "-", "-", "unreadable", "-"))
            details.append("%s: %s" % (key, e))
            continue
        missing, size = 0, 0
        frames, peaks = {}, {}
        for rel in rels:
            try:
                info = audio_info(inside(kits_dir, rel))
            except KitError as e:
                info = {"readable": False, "why": str(e), "channels": 0}
            if not info["readable"] or info["channels"] > KIT_MAX_CHANNELS:
                missing += 1
                details.append("%s: %s: %s" % (key, rel, info["why"] or "%d channels"
                                                % info["channels"]))
            else:
                size += info["bytes"]
                frames[rel] = info["frames"]
                peaks[rel] = peak_dbfs(info)
        for note, pad in kit.get("pads", {}).items():
            for layer in pad.get("layers", []):
                if layer.get("file") in frames and layer.get("startFrames", 0) >= frames[layer["file"]]:
                    problems.append("pad %s: startFrames %d past the end of %s"
                                    % (note, layer["startFrames"], layer["file"]))
        if not problems and not missing:
            median, hot = hot_pads(kit["pads"], peaks)
            problems += ["pad %d: %+.1f dBFS at velocity 127, %.1f dB over the kit's median pad "
                         "(%.1f dBFS), more than %g: out of the kit's balance" % (
                             n, peak, peak - median, median, HOT_PAD_DB) for n, peak, _ in hot]
        details += ["%s: %s" % (key, p) for p in problems]
        rows.append((key, str(len(kit.get("pads", {}))),
                     str(sum(len(p.get("layers", [])) for p in kit.get("pads", {}).values())),
                     str(len(rels)), str(missing + len(problems)), "%.0f kB" % (size / 1024.0)))
    ir = os.path.join(kits_dir, "_ir", "ir.json")
    if os.path.isfile(ir):
        with open(ir) as f:
            meta = json.load(f)
        bad = [rel for rel in meta.get("files", {}).values()
               if not audio_info(inside(kits_dir, rel))["readable"]]
        details += ["_ir: %s unreadable" % rel for rel in bad]
        rows.append(("_ir", "-", "-", str(len(meta.get("files", {}))), str(len(bad)), "%.0f kB" % (
            sum(os.path.getsize(inside(kits_dir, rel)) for rel in meta.get("files", {}).values()
                if os.path.isfile(inside(kits_dir, rel))) / 1024.0)))
    else:
        details.append("_ir: no ir.json (the drum reverb's impulse responses)")
        rows.append(("_ir", "-", "-", "0", "1", "-"))
    head = ("key", "pads", "layers", "files", "missing", "size")
    widths = [max(len(r[i]) for r in rows + [head]) for i in range(len(head))]
    for row in [head] + rows:
        print("  ".join(cell.ljust(widths[i]) if i == 0 else cell.rjust(widths[i])
                        for i, cell in enumerate(row)))
    for line in details:
        print("  " + line)
    return 1 if details else 0


# --- the command ----------------------------------------------------------------
STANDARD_KITS = ["carbon", "carbon-layer", "one-hit"] + [k for k, _ in CORE_KITS] + ["_ir"]
SET_KITS = ("carbon", "carbon-layer", "one-hit")


def cmd_kits(root, parents, args):
    kits_dir = kits_folder(args)
    if args.check:
        return check_kits(kits_dir)
    os.makedirs(kits_dir, exist_ok=True)
    files = KitFiles(kits_dir)
    if args.adg or args.folder:
        if bool(args.adg) == bool(args.folder) or not args.key:
            print("kits: give --adg PATH or --folder DIR, and --key KEY", file=sys.stderr)
            return 1
        if not re.match(r"^[a-z0-9][a-z0-9-]*$", args.key) or args.key in STANDARD_KITS:
            print("kits: --key must be lower-case letters, digits and dashes, and not one of "
                  "the standard kits (%s)" % ", ".join(STANDARD_KITS), file=sys.stderr)
            return 1
        try:
            if args.adg:
                kit = adg_kit(os.path.abspath(os.path.expanduser(args.adg)), args.key, files)
            else:
                kit = folder_kit(os.path.abspath(os.path.expanduser(args.folder)), args.key, files)
            write_kit(kits_dir, kit, files)
            prune(kits_dir, [args.key])
        except KitError as e:
            print("kits: %s" % e, file=sys.stderr)
            return 1
        return 0
    keys = STANDARD_KITS
    if args.only:
        keys = [k.strip() for k in args.only.split(",") if k.strip()]
        unknown = [k for k in keys if k not in STANDARD_KITS]
        if unknown:
            print("kits: no standard kit %s (they are: %s)"
                  % (", ".join(unknown), ", ".join(STANDARD_KITS)), file=sys.stderr)
            return 1
    failed = []
    if any(k in SET_KITS for k in keys) and root is None:
        if os.path.exists(args.set):
            root, parents = load_set(args.set)
        else:
            print("kits: no Live set at %s, so no %s" % (args.set, ", ".join(SET_KITS)),
                  file=sys.stderr)
            failed += [k for k in keys if k in SET_KITS]
    presets = dict(CORE_KITS)
    built = []
    for key in keys:
        if key in failed:
            continue
        try:
            if key == "_ir":
                build_ir(kits_dir)
                continue
            if key in ("carbon", "carbon-layer"):
                kit = carbon_kit(args.set, root, parents, files, key == "carbon-layer")
            elif key == "one-hit":
                kit = one_hit_kit(args.set, root, parents, files)
            else:
                path = os.path.join(CORE_LIBRARY, "Racks", "Drum Racks", presets[key])
                kit = adg_kit(path, key, files, "Live 12 Suite Core Library: %s, its own samples "
                              "and levels" % os.path.splitext(os.path.basename(path))[0])
            write_kit(kits_dir, kit, files)
            built.append(key)
        except KitError as e:
            print("kits: %s: %s" % (key, e), file=sys.stderr)
            failed.append(key)
    prune(kits_dir, built)
    if failed:
        print("kits: not built: %s" % ", ".join(failed), file=sys.stderr)
        return 1
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("command", choices=["inventory", "biasfx", "steps", "drumrender",
                                            "variations", "kits", "all"])
    parser.add_argument("--set", default=DEFAULT_SET, help="the .als file (default: %(default)s)")
    parser.add_argument("--out", default=OUT_DIR, help="output folder (default: presets/sa)")
    parser.add_argument("--only", help="kits: build only these standard kits, KEY[,KEY]")
    parser.add_argument("--adg", help="kits: a kit from this Drum Rack preset (needs --key)")
    parser.add_argument("--folder", help="kits: a kit from this folder of one-shots (needs --key)")
    parser.add_argument("--key", help="kits: the new kit's key, its file and folder name")
    parser.add_argument("--check", action="store_true",
                        help="kits: check every kit JSON against its files")
    args = parser.parse_args(argv)
    if args.command == "kits":
        # Only the kits made from the set read it, and only those load it.
        try:
            return cmd_kits(None, None, args)
        except KitError as e:
            print("kits: %s" % e, file=sys.stderr)
            return 1
    if not os.path.exists(args.set):
        print("no Live set at " + args.set, file=sys.stderr)
        return 1
    root, parents = load_set(args.set)
    if args.command == "inventory":
        return cmd_inventory(root, parents, args)
    if args.command == "biasfx":
        return cmd_biasfx(root, parents, args)
    if args.command == "steps":
        return cmd_steps(root, parents, args)
    if args.command == "drumrender":
        return cmd_drumrender(root, parents, args)
    if args.command == "variations":
        return cmd_variations(root, parents, args)
    return max(cmd_biasfx(root, parents, args), cmd_steps(root, parents, args),
               cmd_variations(root, parents, args))


if __name__ == "__main__":
    sys.exit(main())
