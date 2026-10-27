// megalooper — the Reverb (MegaSAFx.reverb, the Space group), heard offline.
//
//     sclang scripts/sa/nrt-space.scd
//
// As nrt-texture.scd: each case one device of MegaSAFx's own SynthDef between
// a test signal on a private bus and two taps, the signal as it went in and as
// it came out. An impulse for the tail's decay, damping and pre-delay; noise
// for its level. One render (scsynth -N on a far port); exits 0 if every
// check passed, 1 otherwise.
(
var sr = 48000, dur = 2.5, hit = 0.1;
var tmp = PathName.tmp +/+ "megalooper-nrt-space-" ++ thisProcess.pid;
var osc = tmp +/+ "space.osc", wav = tmp +/+ "space.wav";
var pass = 0, fail = 0, fails = List.new;
var ok = { |label, cond, detail|
    if(cond == true) { pass = pass + 1; ("  ok    " ++ label).postln } {
        fail = fail + 1;
        fails.add(label ++ (detail !? { |d| " — " ++ d } ? ""));
        ("  FAIL  " ++ label ++ (detail !? { |d| " — " ++ d } ? "")).postln;
    };
};
// One sample at 1 when it starts, on both sides; or noise until freed.
var impDef = SynthDef(\nrtSpaceImp, { |bus| Out.ar(bus, (Impulse.ar(0) * Line.kr(1, 1, 0.01, doneAction: 2)) ! 2) });
var noiseDef = SynthDef(\nrtSpaceNoise, { |bus, amp = 0.1| Out.ar(bus, WhiteNoise.ar(amp) ! 2) });
var tapDef = SynthDef(\nrtSpaceTap, { |bus, out| Out.ar(out, In.ar(bus, 1)) });
// [label, the device's settings, the source: \imp or \noise]
var cases = [
    [\decay1, [\reverbDecay, 1, \reverbDamp, 20000, \reverbPredelay, 0, \reverbMix, 1], \imp],
    [\decay3, [\reverbDecay, 3, \reverbDamp, 20000, \reverbPredelay, 0, \reverbMix, 1], \imp],
    [\dark, [\reverbDecay, 3, \reverbDamp, 1000, \reverbPredelay, 0, \reverbMix, 1], \imp],
    [\pre, [\reverbPredelay, 0.1, \reverbMix, 1], \imp],
    [\level, [\reverbMix, 1], \noise],
    [\dry, [\reverbMix, 0], \noise],
    [\huge, [\reverbDecay, 20, \reverbSize, 2, \reverbMix, 1], \noise]
];
var chans = cases.size * 2, score, cmd, said, sf, data, frames, chanOf, rmsDb, band, idx, x, y, slope, t60;

File.mkdir(tmp);
score = [impDef, noiseDef, tapDef].collect { |d| [0.0, [\d_recv, d.asBytes]] }
    ++ [[0.0, [\d_recv, MegaSAFx.deviceDef(\reverb).asBytes]]];
cases.do { |c, i|
    var bus = 100 + (i * 2), base = 10000 + (i * 10);
    score = score ++ [
        // The device and the taps first, the source put at the head at its time.
        [0.01, [\s_new, \nrtSpaceTap, base + 1, 1, 0, \bus, bus, \out, (i * 2) + 1]],
        [0.01, [\s_new, MegaSAFx.deviceDefName(\reverb), base + 2, 3, base + 1, \bus, bus, \reverbOn, 1] ++ c[1]],
        [0.01, [\s_new, \nrtSpaceTap, base + 3, 3, base + 2, \bus, bus, \out, i * 2]],
        if(c[2] == \imp) { [hit, [\s_new, \nrtSpaceImp, base, 2, base + 1, \bus, bus]] }
            { [hit, [\s_new, \nrtSpaceNoise, base, 2, base + 1, \bus, bus]] },
        [dur - 0.05, [\n_free, base + 1, base + 2, base + 3] ++ (if(c[2] == \noise) { [base] } { [] })]
    ];
};
score = score.sort { |a, b| a[0] <= b[0] } ++ [[dur, [\c_set, 0, 0]]];
Score(score).writeOSCFile(osc);
cmd = "perl -e 'alarm shift; exec @ARGV' 120 " ++ MegaSAPlugins.scsynthPath.shellQuote ++ " -u " ++ (58500 + 200.rand)
    ++ " -m 65536 -N " ++ osc.shellQuote ++ " _ " ++ wav.shellQuote ++ " " ++ sr ++ " WAV float -o " ++ chans
    ++ " -i 0 2>&1";
said = cmd.unixCmdGetStdOut;
sf = SoundFile.openRead(wav);
if(sf.isNil) {
    ("  FAIL  the render: " ++ said.split($\n).reject(_.isEmpty).keep(-4).join(" | ")).postln;
    "NRT SPACE FAILED — no render".postln;
    1.exit;
} {
    frames = sf.numFrames;
    data = FloatArray.newClear(frames * chans);
    sf.readData(data);
    sf.close;
    idx = { |label| cases.detectIndex { |c| c[0] == label } };
    // Case `label`'s output (0) or input (1) from `t0` to `t1` seconds.
    chanOf = { |label, which, t0, t1| ((t0 * sr).asInteger .. (t1 * sr).asInteger).collect { |f|
        data[(f * chans) + (idx.(label) * 2) + which] } };
    rmsDb = { |xs| ((xs.squared.sum / xs.size.max(1)).sqrt).max(1e-12).ampdb };
    // xs through a band-pass two octaves wide around `freq`, as RMS dB: a
    // biquad (RBJ), run here.
    band = { |xs, freq|
        var w = 2pi * freq / sr, q = 0.7, alpha = sin(w) / (2 * q), a0 = 1 + alpha;
        var b0 = alpha / a0, b2 = alpha.neg / a0, a1 = -2 * cos(w) / a0, a2 = (1 - alpha) / a0;
        var x1 = 0, x2 = 0, y1 = 0, y2 = 0, out = xs.collect { |v|
            var o = (b0 * v) + (b2 * x2) - (a1 * y1) - (a2 * y2);
            x2 = x1; x1 = v; y2 = y1; y1 = o; o };
        rmsDb.(out.drop(200))
    };
    // T60 from the tail's RMS in two windows `gap` apart: 60 dB over the
    // slope.
    t60 = { |label, t0, gap|
        var a = rmsDb.(chanOf.(label, 0, t0, t0 + 0.1)), b = rmsDb.(chanOf.(label, 0, t0 + gap, t0 + gap + 0.1));
        60 * gap / (a - b).max(1e-9)
    };
    "== the Reverb, offline ==".postln;
    ok.("every render is finite", data.every { |v| v.isNaN.not and: { v.abs < inf } });

    x = t60.(\decay1, hit + 0.25, 0.5);
    ok.("Decay 1 s: the tail falls 60 dB in about a second (within 20 %)", (x - 1).abs < 0.2, x.round(0.01).asString ++ " s");
    x = t60.(\decay3, hit + 0.25, 1.0);
    ok.("Decay 3 s: in about three (within 20 %)", (x - 3).abs < 0.6, x.round(0.01).asString ++ " s");
    // Late in the tail, the highs against the lows: Damp at 1 kHz takes the
    // highs down far sooner than at 20 kHz.
    x = chanOf.(\decay3, 0, hit + 1.0, hit + 1.5);
    y = chanOf.(\dark, 0, hit + 1.0, hit + 1.5);
    x = band.(x, 4000) - band.(x, 300);
    y = band.(y, 4000) - band.(y, 300);
    ok.("Damp 1 kHz: a second into the tail, 4 kHz at least 20 dB further under 300 Hz than undamped",
        (x - y) > 20, [x, y].collect(_.round(0.1)).asString);
    x = rmsDb.(chanOf.(\pre, 0, hit + 0.002, hit + 0.095));
    y = rmsDb.(chanOf.(\pre, 0, hit + 0.1, hit + 0.2));
    ok.("Pre-delay 100 ms: nothing in the first 95 ms, the tail after", (x < -100) and: { y > -60 },
        [x, y].collect(_.round(0.1)).asString);
    x = rmsDb.(chanOf.(\level, 0, 1.2, 2.2)) - rmsDb.(chanOf.(\level, 1, 1.2, 2.2));
    ok.("its level: steady noise comes out of the tail within 6 dB of what went in", x.abs < 6, x.round(0.1).asString ++ " dB");
    ok.("Dry/Wet 0: the sound as it came, to the sample",
        (chanOf.(\dry, 0, 0.2, 1.2) - chanOf.(\dry, 1, 0.2, 1.2)).abs.maxItem < 1e-7);
    x = rmsDb.(chanOf.(\huge, 0, 0.8, 1.3));
    y = rmsDb.(chanOf.(\huge, 0, 1.9, 2.4));
    ok.("Decay 20 s at Size 200 % holds: noise in for two seconds, the tail not growing past 3 dB",
        (y - x) < 3, [x, y].collect(_.round(0.1)).asString);

    [osc, wav].do { |f| if(File.exists(f)) { File.delete(f) } };
    File.delete(tmp);
    "".postln;
    if(fail == 0) { ("NRT SPACE PASSED — " ++ pass ++ " checks").postln; 0.exit } {
        ("NRT SPACE FAILED — " ++ fail ++ " of " ++ (pass + fail)).postln;
        fails.do { |f| ("  " ++ f).postln };
        1.exit;
    };
};
)
