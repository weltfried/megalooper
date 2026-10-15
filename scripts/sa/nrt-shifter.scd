// megalooper SA — Pitch Shift's two modes, Grain and FFT, heard offline.
//
//     sclang scripts/sa/nrt-shifter.scd
//
// One offline render (scsynth -N on a far port; megalooper, if it runs, is
// not touched), each channel MegaSAFx.shifter at +12 semitones, fully wet:
//
//   0  Grain, a 220 Hz sine (for the switch's clicks)
//   1  FFT, the same sine
//   2  Grain, plucks with sharp attacks
//   3  FFT, the same plucks
//   4  the plucks through PitchShift with the 80 ms window the shifter had
//      before the modes, for comparison
//   5  the sine, switched from Grain to FFT at 1.5 s
//
// Exits 0 if every check passed, 1 otherwise.
(
var sr = 48000, dur = 4.0, chans = 6;
var tmp = PathName.tmp +/+ "megalooper-nrt-shifter-" ++ thisProcess.pid;
var osc = tmp +/+ "shifter.osc", wav = tmp +/+ "shifter.wav";
var pass = 0, fail = 0, fails = List.new;
var ok = { |label, cond, detail|
    if(cond == true) { pass = pass + 1; ("  ok    " ++ label).postln } {
        fail = fail + 1;
        fails.add(label ++ (detail !? { |d| " — " ++ d } ? ""));
        ("  FAIL  " ++ label ++ (detail !? { |d| " — " ++ d } ? "")).postln;
    };
};
var plucks = [0.3, 1.0, 1.7, 2.4, 3.1];
var defs = [
    SynthDef(\megaNrtShifter, { |out = 0, kind = 0|
        var sig = Select.ar(kind, [SinOsc.ar(220) * 0.3,
            Pluck.ar(WhiteNoise.ar(0.5), Impulse.ar(1 / 0.7, 1 - (0.3 / 0.7)), 0.05, 196.reciprocal, 4, 0.25)]);
        Out.ar(out, MegaSAFx.shifter(sig));
    }),
    SynthDef(\megaNrtShifterOld, { |out = 0|
        var sig = Pluck.ar(WhiteNoise.ar(0.5), Impulse.ar(1 / 0.7, 1 - (0.3 / 0.7)), 0.05, 196.reciprocal, 4, 0.25);
        Out.ar(out, PitchShift.ar(sig, 0.08, 12.midiratio));
    })
];
var common = [\shifterCoarse, 12, \shifterCents, 0, \shifterMix, 1];
var score, cmd, said, sf, data, frames, chan, finite, rise, periodFreq, pluckErr, jump;

File.mkdir(tmp);
score = defs.collect { |d| [0.0, [\d_recv, d.asBytes]] }
    ++ [
        [0.01, [\s_new, \megaNrtShifter, 1001, 0, 0, \out, 0, \kind, 0, \shifterMode, 0] ++ common],
        [0.01, [\s_new, \megaNrtShifter, 1002, 0, 0, \out, 1, \kind, 0, \shifterMode, 1] ++ common],
        [0.01, [\s_new, \megaNrtShifter, 1003, 0, 0, \out, 2, \kind, 1, \shifterMode, 0] ++ common],
        [0.01, [\s_new, \megaNrtShifter, 1004, 0, 0, \out, 3, \kind, 1, \shifterMode, 1] ++ common],
        [0.01, [\s_new, \megaNrtShifterOld, 1005, 0, 0, \out, 4]],
        [0.01, [\s_new, \megaNrtShifter, 1006, 0, 0, \out, 5, \kind, 0, \shifterMode, 0] ++ common],
        [1.5, [\n_set, 1006, \shifterMode, 1]],
        // Every synth freed before the end: scsynth 3.14.1 hangs in its offline
        // cleanup when a synth that owns memory is still running.
        [dur - 0.05, [\n_free, 1001, 1002, 1003, 1004, 1005, 1006]],
        [dur, [\c_set, 0, 0]]
    ];
Score(score).writeOSCFile(osc);
cmd = "perl -e 'alarm shift; exec @ARGV' 120 " ++ MegaSAPlugins.scsynthPath.shellQuote ++ " -u " ++ (58300 + 200.rand)
    ++ " -m 65536 -N " ++ osc.shellQuote ++ " _ " ++ wav.shellQuote ++ " " ++ sr ++ " WAV float -o " ++ chans ++ " -i 0 2>&1";
said = cmd.unixCmdGetStdOut;
sf = SoundFile.openRead(wav);
if(sf.isNil or: { sf.numFrames < ((dur - 0.2) * sr) }) {
    ("  FAIL  the render: " ++ said.split($\n).reject(_.isEmpty).keep(-4).join(" | ")).postln;
    sf !? { |f| f.close };
    [osc, wav].do { |f| if(File.exists(f)) { File.delete(f) } };
    File.delete(tmp);
    "NRT SHIFTER FAILED — no render".postln;
    1.exit;
} {
    frames = sf.numFrames;
    data = FloatArray.newClear(frames * chans);
    sf.readData(data);
    sf.close;
    chan = { |c, from, to|
        var a = (from * sr).asInteger, b = (to * sr).asInteger.min(frames);
        FloatArray.fill(b - a, { |i| data[((a + i) * chans) + c] })
    };
    finite = { |x| x.every { |v| v.isNaN.not and: { v.abs < 1e6 } } };
    // A note's pitch from its period: normalised autocorrelation over 4096
    // samples, lags within 20 % of the expected one. What the ear follows on a
    // plucked note; a lone sine through grains or FFT frames peaks elsewhere
    // in the spectrum (2026-10-15: both PitchShift windows at 420 Hz, the FFT
    // at 440, for a 220 Hz saw an octave up), so the pitch is checked on plucks.
    periodFreq = { |x, at, want|
        var len = 4096, p = sr / want, lo = (p * 0.8).floor.asInteger, hi = (p * 1.25).ceil.asInteger, best = -2, bestLag = lo;
        (lo..hi).do { |lag|
            var num = 0, d1 = 0, d2 = 0, r;
            len.do { |i| var a = x[at + i], b = x[at + i + lag]; num = num + (a * b); d1 = d1 + (a * a); d2 = d2 + (b * b) };
            r = num / ((d1 * d2).sqrt.max(1e-12));
            if(r > best) { best = r; bestLag = lag };
        };
        sr / bestLag
    };
    // The plucks' pitch errors in cents, their median.
    pluckErr = { |c|
        var x = chan.(c, 0, dur - 0.1);
        plucks.collect { |t| ((periodFreq.(x, ((t + 0.2) * sr).asInteger, 392) / 392).ratiomidi * 100).abs }.sort[plucks.size div: 2]
    };
    // A pluck's rise in ms: 10 % to 90 % of its peak, on a 1 ms peak envelope.
    rise = { |c|
        plucks.collect { |t|
            var x = chan.(c, t, t + 0.25), e, peak, i10, i90;
            e = ((x.size / 48).floor.asInteger).collect { |b| var m = 0; 48.do { |j| m = m.max(x[(b * 48) + j].abs) }; m };
            peak = e.maxItem;
            i10 = e.detectIndex { |v| v >= (peak * 0.1) } ? 0;
            i90 = e.detectIndex { |v| v >= (peak * 0.9) } ? 0;
            (i90 - i10)
        }.mean
    };
    // The largest step from one sample to the next.
    jump = { |x| (x.size - 1).collect { |i| (x[i + 1] - x[i]).abs }.maxItem };

    "== Pitch Shift's modes, offline ==".postln;
    [[2, "Grain"], [3, "FFT"]].do { |m|
        ok.(m[1] ++ " shifts plucked G3s an octave up: their period says 392 Hz within 25 cents (median)",
            pluckErr.(m[0]) < 25, pluckErr.(m[0]).round(0.1).asString ++ " ct");
    };
    ok.("Grain smears the plucks' attacks less than the 80 ms window did", rise.(2) < (rise.(4) * 0.75),
        [rise.(2), rise.(4)].round(0.1).asString ++ " ms");
    ok.("...and so does FFT", rise.(3) < (rise.(4) * 0.75), [rise.(3), rise.(4)].round(0.1).asString ++ " ms");
    ok.("switched from Grain to FFT, the sine after the crossfade is FFT's: sample for sample the same",
        (chan.(5, 1.8, 2.2) - chan.(1, 1.8, 2.2)).abs.maxItem < 1e-4, (chan.(5, 1.8, 2.2) - chan.(1, 1.8, 2.2)).abs.maxItem.asString);
    // A click would be a step far larger than either mode's own steps.
    ok.("...without a click: no step during the switch larger than the steadiest mode's own, doubled",
        jump.(chan.(5, 1.45, 1.65)) < (2 * jump.(chan.(0, 1.0, 1.2)).max(jump.(chan.(1, 1.0, 1.2)))),
        [jump.(chan.(5, 1.45, 1.65)), jump.(chan.(0, 1.0, 1.2)), jump.(chan.(1, 1.0, 1.2))].round(0.0001).asString);
    ok.("every render is finite", (0..chans - 1).every { |c| finite.(chan.(c, 0, dur - 0.1)) });

    [osc, wav].do { |f| if(File.exists(f)) { File.delete(f) } };
    File.delete(tmp);
    "".postln;
    if(fail == 0) { ("NRT SHIFTER PASSED — " ++ pass ++ " checks").postln; 0.exit } {
        ("NRT SHIFTER FAILED — " ++ fail ++ " of " ++ (pass + fail)).postln;
        fails.do { |f| ("  " ++ f).postln };
        1.exit;
    };
};
)
