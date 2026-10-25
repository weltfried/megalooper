#!/usr/bin/env python3
"""Read and adjust CoreAudio devices, using nothing but the standard library.

megalooper needs three things macOS exposes only through CoreAudio and no shell
tool reports: a device's real channel counts, its nominal sample rate, and — the
one that actually blocks a first run — the ability to CHANGE that rate.

    scsynth refuses to boot when the default input and the default output run at
    different rates, and a stock Mac often ships the built-in microphone at
    44.1 kHz and the speakers at 48 kHz.

`system_profiler` can report that mismatch (scripts/setup-routing.scd does), but
nothing on macOS can fix it from a script. This can:

    python3 tools/coreaudio.py defaults            # do they agree?
    python3 tools/coreaudio.py match-default-rates # make them agree

Stdlib only, deliberately, following tools/make-icon.py: a bare macOS python3
runs this, so setting up megalooper never turns into installing a toolchain
first. Targets Python 3.9 — the version the Command Line Tools ship.

Everything here is public, unentitled CoreAudio API. Reads are always safe;
`set-rate` and `match-default-rates` are the only calls that change anything,
they touch one documented property, and both refuse a device another program is
currently using.
"""

import argparse
import ctypes
import ctypes.util
import json
import struct
import sys
import time

# --------------------------------------------------------------------------
# ctypes bridge
# --------------------------------------------------------------------------
# Rule one for a hand-rolled CF bridge: declare restype and argtypes on EVERY
# function. Left at the default, ctypes assumes a C int return and truncates
# returned pointers to 32 bits on arm64 — which is a crash, not an error
# message, and it happens far away from the call that caused it.

_ca = ctypes.CDLL(ctypes.util.find_library("CoreAudio"))
_cf = ctypes.CDLL(ctypes.util.find_library("CoreFoundation"))

CFStringRef = ctypes.c_void_p
CFAllocatorRef = ctypes.c_void_p

_cf.CFRelease.argtypes = [ctypes.c_void_p]
_cf.CFRelease.restype = None
_cf.CFStringGetLength.argtypes = [CFStringRef]
_cf.CFStringGetLength.restype = ctypes.c_long
_cf.CFStringGetCString.argtypes = [CFStringRef, ctypes.c_char_p, ctypes.c_long,
                                   ctypes.c_uint32]
_cf.CFStringGetCString.restype = ctypes.c_bool

kCFStringEncodingUTF8 = 0x08000100


class AudioObjectPropertyAddress(ctypes.Structure):
    _fields_ = [("mSelector", ctypes.c_uint32),
                ("mScope", ctypes.c_uint32),
                ("mElement", ctypes.c_uint32)]


# The one struct where hand-computing an offset goes wrong: AudioBuffer is
# 4 + 4 + 8 bytes and AudioBufferList pads mNumberBuffers out to an 8-byte
# boundary before the array starts. Let ctypes compute both rather than writing
# the numbers down — a wrong stride yields plausible-looking channel counts.
class AudioBuffer(ctypes.Structure):
    _fields_ = [("mNumberChannels", ctypes.c_uint32),
                ("mDataByteSize", ctypes.c_uint32),
                ("mData", ctypes.c_void_p)]


class AudioBufferList(ctypes.Structure):
    _fields_ = [("mNumberBuffers", ctypes.c_uint32),
                ("mBuffers", AudioBuffer * 1)]


class AudioValueRange(ctypes.Structure):
    _fields_ = [("mMinimum", ctypes.c_double),
                ("mMaximum", ctypes.c_double)]


_ca.AudioObjectGetPropertyDataSize.argtypes = [
    ctypes.c_uint32, ctypes.POINTER(AudioObjectPropertyAddress),
    ctypes.c_uint32, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
_ca.AudioObjectGetPropertyDataSize.restype = ctypes.c_int32

_ca.AudioObjectGetPropertyData.argtypes = [
    ctypes.c_uint32, ctypes.POINTER(AudioObjectPropertyAddress),
    ctypes.c_uint32, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32),
    ctypes.c_void_p]
_ca.AudioObjectGetPropertyData.restype = ctypes.c_int32

_ca.AudioObjectSetPropertyData.argtypes = [
    ctypes.c_uint32, ctypes.POINTER(AudioObjectPropertyAddress),
    ctypes.c_uint32, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p]
_ca.AudioObjectSetPropertyData.restype = ctypes.c_int32

_ca.AudioObjectHasProperty.argtypes = [
    ctypes.c_uint32, ctypes.POINTER(AudioObjectPropertyAddress)]
_ca.AudioObjectHasProperty.restype = ctypes.c_bool

SYSTEM_OBJECT = 1


def fourcc(code):
    """'nsrt' -> the UInt32 CoreAudio selector. Spaces are significant: the
    device UID selector really is 'uid ' with a trailing space."""
    if len(code) != 4:
        raise ValueError("a FourCC is exactly four characters: %r" % code)
    return struct.unpack(">I", code.encode("ascii"))[0]


def unfourcc(value):
    """Render an OSStatus as the FourCC it usually is. CoreAudio reports
    failures as packed characters, so -10851 is really '!dat' — which says
    'unsupported format' and is actionable, where the number is not."""
    try:
        raw = struct.pack(">i", value)
        if all(32 <= b < 127 for b in raw):
            return "'%s'" % raw.decode("ascii")
    except struct.error:
        pass
    return str(value)


GLOBAL, INPUT, OUTPUT = fourcc("glob"), fourcc("inpt"), fourcc("outp")

# Selectors. Names follow the CoreAudio constants they stand for; the literals
# come from CoreAudio.framework/Headers/AudioHardware.h.
PROP_DEVICES = fourcc("dev#")          # kAudioHardwarePropertyDevices
PROP_DEFAULT_IN = fourcc("dIn ")       # ...DefaultInputDevice
PROP_DEFAULT_OUT = fourcc("dOut")      # ...DefaultOutputDevice
PROP_NAME = fourcc("lnam")             # kAudioObjectPropertyName
PROP_UID = fourcc("uid ")              # kAudioDevicePropertyDeviceUID
PROP_RATE = fourcc("nsrt")             # ...NominalSampleRate
PROP_RATES = fourcc("nsr#")            # ...AvailableNominalSampleRates
PROP_STREAMS = fourcc("slay")          # ...StreamConfiguration
PROP_TRANSPORT = fourcc("tran")        # ...TransportType
PROP_RUNNING = fourcc("goin")          # ...DeviceIsRunningSomewhere
PROP_LATENCY = fourcc("ltnc")          # ...Latency (device), kAudioStreamPropertyLatency
PROP_SAFETY = fourcc("saft")           # ...SafetyOffset
PROP_BUFFER = fourcc("fsiz")           # ...BufferFrameSize
PROP_BUFFER_RANGE = fourcc("fsz#")     # ...BufferFrameSizeRange
PROP_STREAM_IDS = fourcc("stm#")       # ...Streams

TRANSPORTS = {
    "virt": "virtual", "usb ": "usb", "bltn": "built-in", "grup": "aggregate",
    "thnd": "thunderbolt", "blue": "bluetooth", "hdmi": "hdmi", "pci ": "pci",
    "fire": "firewire", "avb ": "avb", "airp": "airplay", "unkn": "unknown",
    "ccwd": "continuity", "ccwl": "continuity", "disp": "displayport",
}


class CoreAudioError(RuntimeError):
    pass


def _get_raw(obj, selector, scope=GLOBAL, element=0):
    """Fetch a property as bytes, or None when the object does not have it."""
    addr = AudioObjectPropertyAddress(selector, scope, element)
    if not _ca.AudioObjectHasProperty(obj, ctypes.byref(addr)):
        return None
    size = ctypes.c_uint32(0)
    err = _ca.AudioObjectGetPropertyDataSize(obj, ctypes.byref(addr), 0, None,
                                             ctypes.byref(size))
    if err != 0 or size.value == 0:
        return None
    buf = (ctypes.c_byte * size.value)()
    err = _ca.AudioObjectGetPropertyData(obj, ctypes.byref(addr), 0, None,
                                         ctypes.byref(size), buf)
    if err != 0:
        return None
    return bytes(bytearray(buf))[:size.value]


def _get_cfstring(obj, selector):
    """CFStringRef properties (name, UID) come back as an owned reference, so
    every one of them has to be released or the process leaks a string per
    device per call."""
    raw = _get_raw(obj, selector)
    if not raw or len(raw) < ctypes.sizeof(ctypes.c_void_p):
        return None
    ref = CFStringRef(struct.unpack("P", raw[:ctypes.sizeof(ctypes.c_void_p)])[0])
    if not ref.value:
        return None
    try:
        length = _cf.CFStringGetLength(ref)
        buf = ctypes.create_string_buffer((length + 1) * 4)
        if not _cf.CFStringGetCString(ref, buf, len(buf), kCFStringEncodingUTF8):
            return None
        return buf.value.decode("utf-8", "replace")
    finally:
        _cf.CFRelease(ref)


def _channels(device, scope):
    raw = _get_raw(device, PROP_STREAMS, scope)
    if not raw:
        return 0
    blist = AudioBufferList.from_buffer_copy(
        raw.ljust(ctypes.sizeof(AudioBufferList), b"\0"))
    stride = ctypes.sizeof(AudioBuffer)
    base = AudioBufferList.mBuffers.offset
    total = 0
    for i in range(blist.mNumberBuffers):
        start = base + i * stride
        if start + stride > len(raw):
            break
        buf = AudioBuffer.from_buffer_copy(raw[start:start + stride])
        total += buf.mNumberChannels
    return total


def _rate(device):
    raw = _get_raw(device, PROP_RATE)
    return struct.unpack("d", raw[:8])[0] if raw and len(raw) >= 8 else 0.0


def _available_rates(device):
    raw = _get_raw(device, PROP_RATES)
    if not raw:
        return []
    step = ctypes.sizeof(AudioValueRange)
    rates = []
    for i in range(len(raw) // step):
        rng = AudioValueRange.from_buffer_copy(raw[i * step:(i + 1) * step])
        # A discrete rate is reported as a zero-width range. Genuine ranges
        # (some pro interfaces) are kept as a min/max pair.
        if rng.mMinimum == rng.mMaximum:
            rates.append(rng.mMinimum)
        else:
            rates.append((rng.mMinimum, rng.mMaximum))
    return rates


def _supports_rate(device, rate):
    for entry in _available_rates(device):
        if isinstance(entry, tuple):
            if entry[0] - 1e-6 <= rate <= entry[1] + 1e-6:
                return True
        elif abs(entry - rate) < 1e-6:
            return True
    return False


def _transport(device):
    raw = _get_raw(device, PROP_TRANSPORT)
    if not raw or len(raw) < 4:
        return "unknown"
    code = struct.pack(">I", struct.unpack("I", raw[:4])[0]).decode("ascii", "replace")
    return TRANSPORTS.get(code, code.strip() or "unknown")


def _is_running(device):
    raw = _get_raw(device, PROP_RUNNING)
    return bool(struct.unpack("I", raw[:4])[0]) if raw and len(raw) >= 4 else False


def _u32(obj, selector, scope=GLOBAL):
    raw = _get_raw(obj, selector, scope)
    return struct.unpack("I", raw[:4])[0] if raw and len(raw) >= 4 else None


def latency(device, buffer=None):
    """The frames CoreAudio says each direction costs, the way a host totals
    them: device latency + safety offset + the stream's own latency + one
    buffer. `buffer` defaults to the size the device runs at right now; pass
    the size the host will ask for (scsynth's hardwareBufferSize) to predict
    a configuration before booting it. The plugin's latency comes on top."""
    raw = _get_raw(device, PROP_BUFFER_RANGE)
    rng = AudioValueRange.from_buffer_copy(raw[:ctypes.sizeof(AudioValueRange)]) \
        if raw and len(raw) >= ctypes.sizeof(AudioValueRange) else None
    result = {
        "rate": _rate(device),
        "buffer_now": _u32(device, PROP_BUFFER),
        "buffer_range": [rng.mMinimum, rng.mMaximum] if rng else None,
    }
    result["buffer"] = buffer or result["buffer_now"] or 0
    for name, scope in (("input", INPUT), ("output", OUTPUT)):
        ids = _get_raw(device, PROP_STREAM_IDS, scope) or b""
        streams = list(struct.unpack("%dI" % (len(ids) // 4), ids[:len(ids) // 4 * 4]))
        part = {
            "device": _u32(device, PROP_LATENCY, scope) or 0,
            "safety": _u32(device, PROP_SAFETY, scope) or 0,
            # A device's streams can differ; the first is the one channel 1 rides.
            "stream": (_u32(streams[0], PROP_LATENCY) or 0) if streams else 0,
        }
        part["total"] = part["device"] + part["safety"] + part["stream"] + result["buffer"]
        result[name] = part
    result["round_trip"] = result["input"]["total"] + result["output"]["total"]
    return result


def _default_device(selector):
    raw = _get_raw(SYSTEM_OBJECT, selector)
    if not raw or len(raw) < 4:
        return None
    dev = struct.unpack("I", raw[:4])[0]
    return dev or None


def device_ids():
    raw = _get_raw(SYSTEM_OBJECT, PROP_DEVICES)
    if not raw:
        return []
    return list(struct.unpack("%dI" % (len(raw) // 4), raw))


def describe(device):
    return {
        "id": device,
        "name": _get_cfstring(device, PROP_NAME) or "(unnamed)",
        "uid": _get_cfstring(device, PROP_UID) or "",
        "in": _channels(device, INPUT),
        "out": _channels(device, OUTPUT),
        "rate": _rate(device),
        "rates": [r for r in _available_rates(device) if not isinstance(r, tuple)],
        "transport": _transport(device),
        "running": _is_running(device),
        "aggregate": _transport(device) == "aggregate",
    }


def all_devices():
    return [describe(d) for d in device_ids()]


def defaults():
    """The devices scsynth will open when no -H is given, which is exactly what
    megalooper's \\saSystem routing profile relies on."""
    din, dout = _default_device(PROP_DEFAULT_IN), _default_device(PROP_DEFAULT_OUT)
    return (describe(din) if din else None, describe(dout) if dout else None)


def set_rate(device, rate, timeout=2.0):
    """Set a device's nominal sample rate, and confirm it actually took.

    The property is asynchronous and CoreAudio is entitled to accept the call
    and then not honour it — notably when another process has the device open —
    so a zero return value is not evidence of anything. Poll until the device
    reports the rate we asked for.
    """
    if not _supports_rate(device, rate):
        supported = ", ".join("%g" % r for r in _available_rates(device)
                              if not isinstance(r, tuple)) or "none reported"
        raise CoreAudioError(
            "device does not support %g Hz (it offers: %s)" % (rate, supported))
    addr = AudioObjectPropertyAddress(PROP_RATE, GLOBAL, 0)
    value = ctypes.c_double(float(rate))
    err = _ca.AudioObjectSetPropertyData(device, ctypes.byref(addr), 0, None,
                                         ctypes.sizeof(value), ctypes.byref(value))
    if err != 0:
        raise CoreAudioError("setting the sample rate failed: %s" % unfourcc(err))
    deadline = time.time() + timeout
    while time.time() < deadline:
        if abs(_rate(device) - rate) < 1e-6:
            return True
        time.sleep(0.05)
    raise CoreAudioError(
        "the device accepted %g Hz but still reports %g Hz. Something else may "
        "have it open — quit Live and SuperCollider and try again, or set it in "
        "Audio MIDI Setup." % (rate, _rate(device)))


def find(spec):
    """Resolve a device by UID first, then by exact name, then by unique
    substring. UID first because names are not unique and can be renamed."""
    devices = all_devices()
    for d in devices:
        if d["uid"] and d["uid"] == spec:
            return d
    exact = [d for d in devices if d["name"] == spec]
    if len(exact) == 1:
        return exact[0]
    if len(exact) > 1:
        raise CoreAudioError("%r names %d devices; use --uid" % (spec, len(exact)))
    loose = [d for d in devices if spec.lower() in d["name"].lower()]
    if len(loose) == 1:
        return loose[0]
    if len(loose) > 1:
        raise CoreAudioError("%r matches %s; be more specific or use --uid"
                             % (spec, ", ".join(repr(d["name"]) for d in loose)))
    raise CoreAudioError("no audio device matches %r" % spec)


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def _fmt_rate(hz):
    return "%g" % hz if hz else "-"


def cmd_list(args):
    devices = all_devices()
    din, dout = defaults()
    if args.json:
        print(json.dumps({"devices": devices,
                          "default_in": din["uid"] if din else None,
                          "default_out": dout["uid"] if dout else None}, indent=2))
        return 0
    print("%-34s %4s %4s %9s  %-11s %s" % ("name", "in", "out", "rate", "kind", "uid"))
    for d in devices:
        if d["in"] == 0 and d["out"] == 0:
            continue
        marks = ""
        if din and d["id"] == din["id"]:
            marks += " [default in]"
        if dout and d["id"] == dout["id"]:
            marks += " [default out]"
        print("%-34.34s %4d %4d %9s  %-11s %s%s"
              % (d["name"], d["in"], d["out"], _fmt_rate(d["rate"]),
                 d["transport"], d["uid"][:36], marks))
    return 0


def cmd_inspect(args):
    d = find(args.uid or args.device)
    if args.json:
        print(json.dumps(d, indent=2))
        return 0
    print("name      : %s" % d["name"])
    print("uid       : %s" % d["uid"])
    print("channels  : %d in, %d out" % (d["in"], d["out"]))
    print("rate      : %s Hz" % _fmt_rate(d["rate"]))
    print("supports  : %s" % (", ".join("%g" % r for r in d["rates"]) or "(not reported)"))
    print("transport : %s" % d["transport"])
    print("in use    : %s" % ("yes" if d["running"] else "no"))
    return 0


def cmd_latency(args):
    d = find(args.uid or args.device)
    lat = latency(d["id"], args.buffer)
    if args.json:
        print(json.dumps(dict(lat, name=d["name"]), indent=2))
        return 0
    rate = lat["rate"] or 48000.0
    ms = lambda frames: frames * 1000.0 / rate  # noqa: E731
    rng = lat["buffer_range"]
    print("%s at %s Hz; buffer now %s frames%s" % (
        d["name"], _fmt_rate(lat["rate"]), lat["buffer_now"],
        " (allowed %g-%g)" % tuple(rng) if rng else ""))
    print("\n%-8s %7s %7s %7s %7s %8s" % ("", "device", "safety", "stream", "buffer", "total"))
    for name in ("input", "output"):
        p = lat[name]
        print("%-8s %7d %7d %7d %7d %8d  = %.2f ms" % (
            name, p["device"], p["safety"], p["stream"], lat["buffer"], p["total"], ms(p["total"])))
    print("\nround trip at a %d-frame buffer: %d frames = %.2f ms, before any plugin"
          % (lat["buffer"], lat["round_trip"], ms(lat["round_trip"])))
    return 0


def cmd_defaults(args):
    """Exit 0 when the default input and output agree on a rate, 1 when they do
    not. That makes it usable as a plain shell test in install.sh."""
    din, dout = defaults()
    payload = {"input": din, "output": dout, "agree": None}
    if din is None or dout is None:
        payload["agree"] = False
        if args.json:
            print(json.dumps(payload, indent=2))
        else:
            print("could not read both default devices "
                  "(input=%s, output=%s)"
                  % (din["name"] if din else None, dout["name"] if dout else None))
        return 1
    agree = abs(din["rate"] - dout["rate"]) < 1e-6
    payload["agree"] = agree
    if args.json:
        print(json.dumps(payload, indent=2))
        return 0 if agree else 1
    print("default input  : %-30s %s Hz" % (din["name"], _fmt_rate(din["rate"])))
    print("default output : %-30s %s Hz" % (dout["name"], _fmt_rate(dout["rate"])))
    if agree:
        print("\nBoth run at %s Hz. scsynth will boot." % _fmt_rate(din["rate"]))
        return 0
    print("\nMISMATCH. scsynth does not support differing input and output rates")
    print("and will refuse to boot. Fix it with:")
    print("    python3 tools/coreaudio.py match-default-rates")
    return 1


def cmd_set_rate(args):
    d = find(args.uid or args.device)
    if abs(d["rate"] - args.rate) < 1e-6:
        print("%s is already at %g Hz." % (d["name"], args.rate))
        return 0
    if args.dry_run:
        print("would set %s: %s Hz -> %g Hz" % (d["name"], _fmt_rate(d["rate"]), args.rate))
        return 0
    if d["running"]:
        print("warning: %s is in use by another program; the change may be "
              "ignored." % d["name"], file=sys.stderr)
    set_rate(d["id"], args.rate)
    print("%s: %s Hz -> %g Hz" % (d["name"], _fmt_rate(d["rate"]), args.rate))
    return 0


def cmd_match(args):
    """Make the default input and output agree, which is what unblocks a boot.

    Defaults to the OUTPUT device's rate: that is what the listener actually
    hears, and moving the microphone instead is the less audible change.
    """
    din, dout = defaults()
    if din is None or dout is None:
        print("could not read both default devices.", file=sys.stderr)
        return 1
    target = args.rate or dout["rate"]
    if not target:
        print("could not read a target sample rate.", file=sys.stderr)
        return 1
    if abs(din["rate"] - target) < 1e-6 and abs(dout["rate"] - target) < 1e-6:
        print("default input and output already agree at %g Hz." % target)
        return 0
    print("target rate: %g Hz" % target)
    failed = False
    for role, d in (("input", din), ("output", dout)):
        if abs(d["rate"] - target) < 1e-6:
            print("  %-6s %-30s already %g Hz" % (role, d["name"], target))
            continue
        if args.dry_run:
            print("  %-6s %-30s would go %s -> %g Hz"
                  % (role, d["name"], _fmt_rate(d["rate"]), target))
            continue
        try:
            was = d["rate"]
            set_rate(d["id"], target)
            print("  %-6s %-30s %s -> %g Hz" % (role, d["name"], _fmt_rate(was), target))
        except CoreAudioError as exc:
            print("  %-6s %-30s FAILED: %s" % (role, d["name"], exc), file=sys.stderr)
            failed = True
    return 1 if failed else 0


def cmd_selftest(args):
    """Check the bridge against an independent source: system_profiler.

    The ctypes layer has exactly three places where a silent wrong answer is
    possible — the AudioBufferList stride, the FourCC packing, and CFString
    decoding — and none of them raises when it is wrong. system_profiler reports
    the same channel counts and rates through a completely different code path,
    so disagreement means the bridge is broken. Needs no particular hardware:
    it checks whatever this Mac happens to have.
    """
    import subprocess
    try:
        raw = subprocess.run(
            ["system_profiler", "SPAudioDataType", "-json"],
            capture_output=True, text=True, timeout=30, check=True).stdout
        items = json.loads(raw)["SPAudioDataType"][0]["_items"]
    except Exception as exc:  # noqa: BLE001 - any failure here is "cannot check"
        print("cannot run system_profiler to cross-check: %s" % exc, file=sys.stderr)
        return 2

    reference = {}
    for it in items:
        reference[it["_name"]] = (
            int(it.get("coreaudio_device_input", 0) or 0),
            int(it.get("coreaudio_device_output", 0) or 0),
            int(it.get("coreaudio_device_srate", 0) or 0))

    failures, checked = [], 0
    for d in all_devices():
        want = reference.get(d["name"])
        if want is None:
            continue
        got = (d["in"], d["out"], int(round(d["rate"])))
        checked += 1
        if got != want:
            failures.append("%s: ctypes %s vs system_profiler %s"
                            % (d["name"], got, want))
        print("  %-34.34s %s %s" % (d["name"], "ok " if got == want else "FAIL",
                                    "%d in %d out %d Hz" % got))

    if not checked:
        print("no devices in common to compare", file=sys.stderr)
        return 2
    # A device the system has but we never listed is a real failure: it means
    # enumeration, not just parsing, is dropping something.
    missing = set(reference) - {d["name"] for d in all_devices()}
    for name in sorted(missing):
        failures.append("%s: present to system_profiler, absent here" % name)

    print()
    if failures:
        for f in failures:
            print("FAIL %s" % f, file=sys.stderr)
        return 1
    print("selftest ok — %d device(s) agree with system_profiler" % checked)
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="coreaudio.py", description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="cmd")

    p = sub.add_parser("list", help="list every audio device")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("inspect", help="show one device in full")
    p.add_argument("device", nargs="?", help="name, or a unique part of one")
    p.add_argument("--uid")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_inspect)

    p = sub.add_parser("latency",
                       help="the frames each direction costs, and the round trip")
    p.add_argument("device", nargs="?", help="name, or a unique part of one")
    p.add_argument("--uid")
    p.add_argument("--buffer", type=int,
                   help="host buffer in frames (default: what the device runs at now)")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_latency)

    p = sub.add_parser("defaults",
                       help="report the default input/output; exit 1 if their rates differ")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_defaults)

    p = sub.add_parser("set-rate", help="set one device's nominal sample rate")
    p.add_argument("device", nargs="?", help="name, or a unique part of one")
    p.add_argument("--uid")
    p.add_argument("--rate", type=float, required=True)
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=cmd_set_rate)

    p = sub.add_parser("match-default-rates",
                       help="make the default input and output share a rate")
    p.add_argument("--rate", type=float,
                   help="target rate (default: the output device's current rate)")
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=cmd_match)

    p = sub.add_parser("selftest",
                       help="cross-check every reading against system_profiler")
    p.set_defaults(func=cmd_selftest)

    args = parser.parse_args(argv)
    if not getattr(args, "func", None):
        parser.print_help()
        return 2
    if args.cmd in ("inspect", "set-rate", "latency") and not (args.device or args.uid):
        parser.error("%s needs a device name or --uid" % args.cmd)
    try:
        return args.func(args)
    except CoreAudioError as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
