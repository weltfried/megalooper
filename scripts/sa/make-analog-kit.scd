// megalooper's own drum kit, "Analog Kit": sixteen pads synthesized here, in
// the manner of the classic analog drum machines' circuits, and rendered once
// to presets/sa/drums/kits/analog/ with the kit's map, analog.json. Made for
// megalooper (2026-11-06) and shipped with it, so a fresh install has drums
// before any kit is imported. The sounds and the map are CC0 (the kit
// folder's LICENSE); this script is GPL-3 like the rest of megalooper.
//
//     sclang -u 58xxx scripts/sa/make-analog-kit.scd     (a far port, beside megalooper)
//
// One offline render (scsynth -N, no audio device): each pad's synth on an
// output channel of its own, its noise from a fixed seed, so a render gives
// the same files every time. Each pad is then cut where it falls below
// -80 dB, faded over its last 5 ms, brought to -1 dBFS and written as a mono
// 24-bit WAV; the kit's balance is in each pad's gainDb, and megalooper
// levels the kit as a whole when it loads it (MegaSAKit.measureLevel).
//
// The pads are those of a classic analog machine's sixteen, on the notes the
// kits megalooper knows put them (36 kick to 51 claves), the hats choking each
// other. The voices, as such machines make them:
//   kick      a sine that drops from 150 Hz to 49 Hz in a quarter second,
//             a long decay, a click on top, softly clipped
//   rim       two short resonances, 455 Hz and 1.67 kHz, and a tick of noise
//   snare     two tones, 238 and 476 Hz, under band-passed noise
//   clap      band-passed noise in three quick bursts, then its tail
//   congas    sines with a short upward blip: 165, 250, 370 Hz
//   toms      sines falling a little: 87, 130, 175 Hz, a breath of noise
//   hats      six square waves (205, 304, 370, 523, 540, 800 Hz) through a
//             high band; closed short, open long
//   cymbal    the same six through two bands, the high one ringing longer
//   maracas   high-passed noise, very short
//   cowbell   two squares, 540 and 800 Hz, band-passed, a two-stage decay
//   claves    a 2.5 kHz resonance, very short
//
// Exits 0 when the kit is written, 1 otherwise.
(
var repo = thisProcess.nowExecutingPath !? { |p| p.dirname.dirname.dirname } ?? { Looper.repoRoot };
var kitDir = repo +/+ "presets" +/+ "sa" +/+ "drums" +/+ "kits";
var outDir = kitDir +/+ "analog";
var tmp = PathName.tmp +/+ "megalooper-analog-kit-" ++ thisProcess.pid;
var osc = tmp +/+ "kit.osc", wav = tmp +/+ "kit.wav";
var sr = 48000, dur = 3.0;
var metal = [205.3, 304.4, 369.6, 522.7, 540.0, 800.0];
// [note, name, gainDb, choke (group), retrigger, the voice: a function of no arguments]
var pads, defs, score, cmd, said, sf, data, frames, chans, ok = true, json, esc;

AppClock.sched(120, { "watchdog: exiting".postln; 1.exit; nil });

pads = [
    [36, "Bass Drum", 0, 0, false, {
        var f = EnvGen.ar(Env([150, 58, 49], [0.012, 0.25], [-4, -2]));
        var body = SinOsc.ar(f, 0.5pi) * EnvGen.ar(Env([0, 1, 0.55, 0], [0.0008, 0.09, 1.2], [0, -2, -5]));
        var click = (HPF.ar(WhiteNoise.ar, 1500) * EnvGen.ar(Env.perc(0.0005, 0.006)) * 0.25)
            + (SinOsc.ar(1800) * EnvGen.ar(Env.perc(0.0002, 0.003)) * 0.2);
        ((body + click) * 1.3).tanh
    }],
    [37, "Rim Shot", -8, 0, false, {
        var env = EnvGen.ar(Env.perc(0.0003, 0.018, 1, -6));
        var tone = (SinOsc.ar(455) * 0.6) + (SinOsc.ar(1667) * 0.5);
        var tick = HPF.ar(WhiteNoise.ar, 3000) * EnvGen.ar(Env.perc(0.0002, 0.004)) * 0.4;
        HPF.ar((tone * env) + tick, 300)
    }],
    [38, "Snare Drum", -3, 0, false, {
        var t1 = SinOsc.ar(EnvGen.ar(Env([265, 238], [0.02]))) * EnvGen.ar(Env.perc(0.0005, 0.16, 1, -5));
        var t2 = SinOsc.ar(476) * EnvGen.ar(Env.perc(0.0005, 0.09, 1, -5));
        var noise = BPF.ar(HPF.ar(WhiteNoise.ar, 1800), 6000, 1.6) * EnvGen.ar(Env.perc(0.001, 0.22, 1, -6));
        (t1 * 0.6) + (t2 * 0.35) + (noise * 1.4)
    }],
    [39, "Hand Clap", -4, 0, false, {
        var bursts = EnvGen.ar(Env([1, 0.1, 1, 0.1, 1, 0.1, 0], [0.01, 0, 0.01, 0, 0.01, 0], -4));
        var tail = EnvGen.ar(Env([0, 0, 0.7, 0], [0.03, 0.001, 0.28], [0, 0, -5]));
        var noise = BPF.ar(WhiteNoise.ar, 1150, 0.55) + (BPF.ar(WhiteNoise.ar, 2400, 0.8) * 0.35);
        noise * (bursts + tail) * 1.6
    }],
    [40, "Low Conga", -7, 0, false, {
        SinOsc.ar(EnvGen.ar(Env([165 * 1.25, 165], [0.008]))) * EnvGen.ar(Env.perc(0.0005, 0.26, 1, -5))
    }],
    [41, "Mid Conga", -7, 0, false, {
        SinOsc.ar(EnvGen.ar(Env([250 * 1.25, 250], [0.008]))) * EnvGen.ar(Env.perc(0.0005, 0.2, 1, -5))
    }],
    [42, "Closed Hi Hat", -10, 1, true, {
        var m = metal.collect { |f| Pulse.ar(f) }.sum * 0.2;
        HPF.ar(BPF.ar(m, 7200, 0.9), 7000) * EnvGen.ar(Env.perc(0.0005, 0.055, 1, -6)) * 4
    }],
    [43, "Hi Conga", -7, 0, false, {
        SinOsc.ar(EnvGen.ar(Env([370 * 1.25, 370], [0.008]))) * EnvGen.ar(Env.perc(0.0005, 0.16, 1, -5))
    }],
    [44, "Low Tom", -5, 0, false, {
        var f = EnvGen.ar(Env([87 * 1.3, 87], [0.06], -3));
        (SinOsc.ar(f) * EnvGen.ar(Env.perc(0.001, 0.55, 1, -4)))
            + (BPF.ar(PinkNoise.ar, 600, 1) * EnvGen.ar(Env.perc(0.001, 0.05)) * 0.15)
    }],
    [45, "Mid Tom", -5, 0, false, {
        var f = EnvGen.ar(Env([130 * 1.3, 130], [0.05], -3));
        (SinOsc.ar(f) * EnvGen.ar(Env.perc(0.001, 0.45, 1, -4)))
            + (BPF.ar(PinkNoise.ar, 800, 1) * EnvGen.ar(Env.perc(0.001, 0.045)) * 0.15)
    }],
    [46, "Open Hi Hat", -11, 1, false, {
        var m = metal.collect { |f| Pulse.ar(f) }.sum * 0.2;
        HPF.ar(BPF.ar(m, 7200, 0.9), 7000) * EnvGen.ar(Env.perc(0.0008, 0.45, 1, -5)) * 4
    }],
    [47, "Hi Tom", -5, 0, false, {
        var f = EnvGen.ar(Env([175 * 1.3, 175], [0.04], -3));
        (SinOsc.ar(f) * EnvGen.ar(Env.perc(0.001, 0.38, 1, -4)))
            + (BPF.ar(PinkNoise.ar, 1000, 1) * EnvGen.ar(Env.perc(0.001, 0.04)) * 0.15)
    }],
    [48, "Maracas", -12, 0, false, {
        HPF.ar(WhiteNoise.ar, 5000) * EnvGen.ar(Env([0, 1, 0], [0.006, 0.04], [2, -5]))
    }],
    [49, "Cymbal", -13, 0, false, {
        var m = metal.collect { |f| Pulse.ar(f) }.sum * 0.2;
        var low = BPF.ar(m, 3440, 0.7) * EnvGen.ar(Env.perc(0.001, 0.5, 1, -5));
        var high = HPF.ar(BPF.ar(m, 7100, 0.9), 6000) * EnvGen.ar(Env.perc(0.001, 1.6, 1, -4));
        (low * 1.2) + (high * 3)
    }],
    [50, "Cow Bell", -8, 0, false, {
        var m = (Pulse.ar(540) + Pulse.ar(800)) * 0.5;
        var sig = BPF.ar(m, 900, 1.2) + (BPF.ar(m, 2640, 0.8) * 0.3);
        sig * EnvGen.ar(Env([0, 1, 0.35, 0], [0.001, 0.02, 0.35], [0, -4, -4])) * 2
    }],
    [51, "Claves", -9, 0, false, {
        SinOsc.ar(2500) * EnvGen.ar(Env.perc(0.0002, 0.035, 1, -6))
    }]
];

// One def per pad, its noise seeded by its note, onto its own channel.
defs = pads.collect { |p, i|
    SynthDef(("megaAnalogKit" ++ p[0]).asSymbol, { |out = 0|
        RandSeed.ir(1, p[0] * 7919);
        Out.ar(out, LeakDC.ar(p[5].value));
    })
};
chans = pads.size;
File.mkdir(tmp);
score = defs.collect { |d| [0.0, [\d_recv, d.asBytes]] }
    ++ defs.collect { |d, i| [0.01, [\s_new, d.name, 1000 + i, 0, 0, \out, i]] }
    // Every synth freed before the end: scsynth 3.14.1 can hang in its
    // offline cleanup otherwise.
    ++ [[dur - 0.05, [\n_free] ++ defs.collect { |d, i| 1000 + i }], [dur, [\c_set, 0, 0]]];
Score(score).writeOSCFile(osc);
cmd = "perl -e 'alarm shift; exec @ARGV' 60 " ++ MegaSAPlugins.scsynthPath.shellQuote ++ " -u " ++ (58500 + 200.rand)
    ++ " -N " ++ osc.shellQuote ++ " _ " ++ wav.shellQuote ++ " " ++ sr ++ " WAV float -o " ++ chans ++ " -i 0 2>&1";
said = cmd.unixCmdGetStdOut;
sf = SoundFile.openRead(wav);
if(sf.isNil) {
    ("the render failed: " ++ said.split($\n).reject(_.isEmpty).keep(-4).join(" | ")).postln;
    1.exit;
};
frames = sf.numFrames;
data = FloatArray.newClear(frames * chans);
sf.readData(data);
sf.close;

File.mkdir(outDir);
pads.do { |p, i|
    var x = FloatArray.fill(frames, { |f| data[(f * chans) + i] });
    var start = (0.01 * sr).asInteger, peak, last, cut, fade = (0.005 * sr).asInteger, out, w, path;
    x = x.copyRange(start, frames - 1);
    peak = x.abs.maxItem;
    // Cut where it falls below -80 dB of its peak for good, 10 ms on.
    last = x.size - 1;
    while { (last > 0) and: { x[last].abs < (peak * 1e-4) } } { last = last - 1 };
    cut = (last + (0.01 * sr).asInteger).min(x.size - 1);
    out = x.copyRange(0, cut);
    fade.min(out.size).do { |k| var j = out.size - 1 - k; out[j] = out[j] * (k / fade) };
    // A FloatArray times a number answers an Array in 3.14.1, which writeData refuses.
    out = FloatArray.newFrom(out * (-1.dbamp / peak.max(1e-9)));
    path = outDir +/+ p[1] ++ ".wav";
    w = SoundFile.new.headerFormat_("WAV").sampleFormat_("int24").numChannels_(1).sampleRate_(sr);
    if(w.openWrite(path)) {
        w.writeData(out);
        w.close;
        ("  " ++ p[0] ++ " " ++ p[1].padRight(14) ++ (out.size / sr).round(0.001) ++ " s").postln;
    } {
        ("could not write " ++ path).postln;
        ok = false;
    };
};
[osc, wav].do { |f| if(File.exists(f)) { File.delete(f) } };
File.delete(tmp);

// The kit's map, as MegaSAKit reads it.
esc = { |s| "\"" ++ s.asString.replace("\\", "\\\\").replace("\"", "\\\"") ++ "\"" };
json = "{\n  \"version\": 1,\n  \"key\": \"analog\",\n  \"name\": \"Analog Kit\",\n"
    ++ "  \"description\": " ++ esc.("megalooper's own drum machine: sixteen pads synthesized in the manner of the classic analog machines") ++ ",\n"
    ++ "  \"source\": \"scripts/sa/make-analog-kit.scd\",\n"
    ++ "  \"groups\": { \"kit\": \"Analog Kit\" },\n"
    ++ "  \"notes\": [" ++ esc.("Rendered offline by scripts/sa/make-analog-kit.scd: each pad a SuperCollider synth, its noise from a fixed seed, cut at -80 dB, at -1 dBFS; the balance is each pad's gainDb. Made for megalooper and shipped with it; the sounds and this map are CC0 1.0 (analog/LICENSE).") ++ "],\n"
    ++ "  \"pads\": {\n"
    ++ pads.collect { |p|
        "    \"" ++ p[0] ++ "\": { \"name\": " ++ esc.(p[1]) ++ ", \"choke\": " ++ p[3] ++ ", \"retrigger\": " ++ p[4]
            ++ ", \"pan\": 0.0, \"gainDb\": 0.0, \"beatRepeat\": false, \"repeatFilter\": false,\n"
            ++ "      \"layers\": [ { \"group\": \"kit\", \"file\": " ++ esc.("analog/" ++ p[1] ++ ".wav")
            ++ ", \"gainDb\": " ++ p[2].asFloat ++ ", \"transpose\": 0.0, \"velLo\": 1, \"velHi\": 127, \"startFrames\": 0, \"lenSecs\": 0.0, \"drive\": 0.0,"
            ++ " \"vel\": { \"law\": \"simpler\", \"amount\": 0.5 } } ] }"
    }.join(",\n")
    ++ "\n  }\n}\n";
File.use(kitDir +/+ "analog.json", "w", { |f| f.write(json) });
("wrote " ++ pads.size ++ " pads and analog.json in " ++ kitDir).postln;
if(ok) { "ANALOG KIT DONE".postln; 0.exit } { "ANALOG KIT FAILED".postln; 1.exit };
)
