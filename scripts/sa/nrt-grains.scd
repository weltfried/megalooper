// megalooper — the grains following the chords (LooperSynthDefs.granularGraph,
// granularFollowChords; roadmap item 8), heard offline.
//
//     sclang scripts/sa/nrt-grains.scd
//
// A 2 s loop of two chords as the analysis would segment it: A (root 9) for its
// first second, a 220 Hz tone, then D (root 2), 293.66 Hz. A synth writes the
// engine's phase (seconds into the loop) to a control bus as the engine does,
// from 0.05 s. Each case is one grains synth of the Looper's own graph, on two
// output channels of its own:
//
//   frozen    morph 0, reading at a quarter of the loop (in A), following
//   asPlayed  the same, not following
//   frozenD   morph 0, reading at three quarters (in D), following
//   pulsed    morph 1 (reading where the loop is), following
//   stopped   frozen and following, but not locked to an engine
//   oneChord  frozen and following, a take of one chord (period 0)
//
// Frozen and following, the grains sound A while the loop plays A and D (A up
// a fourth, the nearer way to D) while it plays D.
//
// Then the dissolve's dust (docs/dev/microsound.md, idea 1), on a loop of a
// constant 0.5 on the left and silence on the right, so the output is the
// grains' windows: morph 0 (0.4 s grains, six overlapping: 15 a second), a
// Hann window, amp 1.
//
//   rain      dust 1: about 3.75 grains a second (a quarter of 15) of
//             15 ms, at irregular gaps, each held up by the overlaps' ratio
//             to the -1/4 (x 3.21)
//   capped    the same at Size 4 and Density 16: the lift at its top, x 4
//   ramp      dust from 0 to 1 over 7 s: the grains sound less and less of
//             the time, every quarter less than the one before
//
// Two renders (scsynth -N on a far port); exits 0 if every check passed, 1
// otherwise. (That dust 0 is the graph as it was, sample for sample, was shown
// once against the graph before it, both engines seeded alike: microsound.md.)
(
var sr = 48000, loopSecs = 2, dur = 3.3, frames = sr * loopSecs;
var tmp = PathName.tmp +/+ "megalooper-nrt-grains-" ++ thisProcess.pid;
var osc = tmp +/+ "grains.osc", wav = tmp +/+ "grains.wav", src = tmp +/+ "loop.wav";
var pass = 0, fail = 0, fails = List.new;
var ok = { |label, cond, detail|
    if(cond == true) { pass = pass + 1; ("  ok    " ++ label).postln } {
        fail = fail + 1;
        fails.add(label ++ (detail !? { |d| " — " ++ d } ? ""));
        ("  FAIL  " ++ label ++ (detail !? { |d| " — " ++ d } ? "")).postln;
    };
};
var grainsDef = SynthDef(\nrtGrains, LooperSynthDefs.granularGraph);
var phaseDef = SynthDef(\nrtGrainsPhase, { |out| Out.kr(out, Sweep.kr(0, 1).mod(loopSecs)) });
var a = 220, d = 220 * 5.midiratio, g = 220 * 10.midiratio;
var starts = [0, 1] ++ (1e9 ! (LooperSynthDefs.chordSlots - 2)), roots = [9, 2] ++ (0 ! (LooperSynthDefs.chordSlots - 2));
// [label, morph, position, follow, locked, chordPeriod]: at morph 0 the read
// point is Position (the scan's phase starts at its wrap), so 0.25 reads at
// half a second, in A.
var cases = [
    [\frozen, 0, 0.25, 1, 1, loopSecs],
    [\asPlayed, 0, 0.25, 0, 1, loopSecs],
    [\frozenD, 0, 0.75, 1, 1, loopSecs],
    [\pulsed, 1, 0, 1, 1, loopSecs],
    [\stopped, 0, 0.25, 1, 0, loopSecs],
    [\oneChord, 0, 0.25, 1, 1, 0]
];
var chans = cases.size * 2, phaseKr = 50, score, cmd, said, sf, data, chanOf, goertzel, idx, x, near, sound;

File.mkdir(tmp);
// The loop, stereo, the tone the same on both sides.
sf = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(2).sampleRate_(sr);
sf.openWrite(src);
sf.writeData(FloatArray.fill(frames * 2, { |j|
    var i = j div: 2;
    sin(i * 2pi * (if(i < (frames / 2)) { a } { d }) / sr) * 0.3
}));
sf.close;
score = [
    [0.0, [\d_recv, grainsDef.asBytes]], [0.0, [\d_recv, phaseDef.asBytes]],
    [0.0, [\b_allocRead, 0, src]],
    [0.05, [\s_new, \nrtGrainsPhase, 9000, 0, 0, \out, phaseKr]]
];
cases.do { |c, i|
    score = score.add([0.05, [\s_new, \nrtGrains, 10000 + i, 1, 0,
        \bufnum, 0, \startFrame, 0, \loopFrames, frames, \tau, 0.5, \morph, c[1], \amp, 1, \out, i * 2,
        \position, c[2], \phaseBus, phaseKr, \locked, c[4], \follow, c[3], \chordPeriod, c[5],
        \chordStarts, starts, \chordRoots, roots].asOSCArgArray]);
};
score = score ++ [[dur - 0.05, [\n_free, 9000] ++ cases.collect { |c, i| 10000 + i }], [dur, [\c_set, 0, 0]]];
Score(score).writeOSCFile(osc);
cmd = "perl -e 'alarm shift; exec @ARGV' 120 " ++ MegaSAPlugins.scsynthPath.shellQuote ++ " -u " ++ (58500 + 200.rand)
    ++ " -m 65536 -N " ++ osc.shellQuote ++ " _ " ++ wav.shellQuote ++ " " ++ sr ++ " WAV float -o " ++ chans
    ++ " -i 0 2>&1";
said = cmd.unixCmdGetStdOut;
sf = SoundFile.openRead(wav);
if(sf.isNil) {
    ("  FAIL  the render: " ++ said.split($\n).reject(_.isEmpty).keep(-4).join(" | ")).postln;
    "NRT GRAINS FAILED — no render".postln;
    1.exit;
} {
    data = FloatArray.newClear(sf.numFrames * chans);
    sf.readData(data);
    sf.close;
    idx = { |label| cases.detectIndex { |c| c[0] == label } };
    chanOf = { |label, t0, t1| ((t0 * sr).asInteger .. (t1 * sr).asInteger).collect { |f| data[(f * chans) + (idx.(label) * 2)] } };
    // The amplitude of `freq` in xs (a Goertzel filter), in dB.
    goertzel = { |xs, freq|
        var w = 2pi * freq / sr, c = 2 * cos(w), s1 = 0, s2 = 0, s0;
        xs.do { |v| s0 = v + (c * s1) - s2; s2 = s1; s1 = s0 };
        ((((s1.squared + s2.squared) - (c * s1 * s2)).max(0).sqrt * 2 / xs.size).max(1e-12)).ampdb
    };
    // Which of A, D and G a stretch sounds: the loudest, if it leads the
    // others by 12 dB; else nil.
    sound = { |label, t0, t1|
        var xs = chanOf.(label, t0, t1), lv = [a, d, g].collect { |f| goertzel.(xs, f) }, best = lv.maxIndex;
        if(lv.every { |v, i| (i == best) or: { (lv[best] - v) > 12 } }) { [\A, \D, \G][best] }
    };
    "== the grains following the chords, offline ==".postln;
    ok.("every render is finite", data.every { |v| v.isNaN.not and: { v.abs < inf } });
    // The loop is in A from 0.05 to 1.05 s and from 2.05 to 3.05, in D from
    // 1.05 to 2.05. Each stretch leaves the grains of the change (0.4 s at the
    // drone end) time to go.
    x = [[0.55, 1.0], [1.55, 2.0], [2.55, 3.0]];
    near = { |label| x.collect { |w| sound.(label, w[0], w[1]) } };
    ok.("frozen in A and following: A while the loop plays A, D (A a fourth up) while it plays D, A again",
        near.(\frozen) == [\A, \D, \A], near.(\frozen).asString);
    ok.("...as played (the switch off): A all the way, as the grains always were", near.(\asPlayed) == [\A, \A, \A],
        near.(\asPlayed).asString);
    ok.("frozen in D and following: A (D a fourth down) while the loop plays A, D while it plays D",
        near.(\frozenD) == [\A, \D, \A], near.(\frozenD).asString);
    ok.("pulsed, reading where the loop is: the loop's own chords, nothing moved on top (no G)",
        near.(\pulsed) == [\A, \D, \A], near.(\pulsed).asString);
    ok.("not locked to a moving engine: nothing to follow", near.(\stopped) == [\A, \A, \A], near.(\stopped).asString);
    ok.("a take of one chord: nothing to follow", near.(\oneChord) == [\A, \A, \A], near.(\oneChord).asString);
    [osc, wav, src].do { |f| if(File.exists(f)) { File.delete(f) } };

    // ---- the dissolve's dust ----------------------------------------------
    "-- the dissolve's dust".postln;
    {
        var dDur = 8, dCases = [
            [\rain, [\dust, 1]],
            [\capped, [\dust, 1, \size, 4, \density, 16 / 6]],
            [\ramp, []]
        ];
        var dChans = dCases.size * 2, dScore, dData, dn, left, bumps, gapsCv, inWin, x, y, duty;
        // The lift the graph gives at dust 1, from its own sums.
        var liftOf = { |size, density|
            var ws = (0.4 * size).clip(0.001, 4), ov = (6 * density).clip(0.5, 16), r0 = ov / ws;
            (((ws.min(0.015) / ws) * ((r0 * 0.25).min(4) / r0)) ** (-0.25)).min(4)
        };
        sf = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(2).sampleRate_(sr);
        sf.openWrite(src);
        sf.writeData(FloatArray.fill(frames * 2, { |j| if(j.even) { 0.5 } { 0 } }));
        sf.close;
        dScore = [
            [0.0, [\d_recv, grainsDef.asBytes]], [0.0, [\d_recv, phaseDef.asBytes]],
            [0.0, [\d_recv, SynthDef(\nrtGrainsRamp, { |out| Out.kr(out, Line.kr(0, 1, 7)) }).asBytes]],
            [0.0, [\b_allocRead, 0, src]],
            [0.05, [\s_new, \nrtGrainsPhase, 9000, 0, 0, \out, phaseKr]],
            [0.5, [\s_new, \nrtGrainsRamp, 9001, 0, 0, \out, phaseKr + 1]]
        ];
        dCases.do { |c, i|
            dScore = dScore.add([0.05, [\s_new, \nrtGrains, 10000 + i, 1, 0,
                \bufnum, 0, \startFrame, 0, \loopFrames, frames, \tau, 0.5, \morph, 0, \amp, 1, \out, i * 2,
                \phaseBus, phaseKr, \locked, 1] ++ c[1]]);
        };
        dScore = dScore ++ [[0.5, [\n_map, 10000 + dCases.detectIndex { |c| c[0] == \ramp }, \dust, phaseKr + 1]],
            [dDur - 0.05, [\n_free, 9000, 9001] ++ dCases.collect { |c, i| 10000 + i }], [dDur, [\c_set, 0, 0]]];
        Score(dScore).writeOSCFile(osc);
        said = ("perl -e 'alarm shift; exec @ARGV' 120 " ++ MegaSAPlugins.scsynthPath.shellQuote ++ " -u " ++ (58500 + 200.rand)
            ++ " -m 65536 -N " ++ osc.shellQuote ++ " _ " ++ wav.shellQuote ++ " " ++ sr ++ " WAV float -o " ++ dChans
            ++ " -i 0 2>&1").unixCmdGetStdOut;
        sf = SoundFile.openRead(wav);
        if(sf.isNil) { ok.("the dust render", false, said.split($\n).reject(_.isEmpty).keep(-4).join(" | ")) } {
            dData = FloatArray.newClear(sf.numFrames * dChans);
            sf.readData(dData);
            sf.close;
            dn = sf.numFrames;
            left = { |label| var c = dCases.detectIndex { |k| k[0] == label }; Array.fill(dn, { |f| dData[(f * dChans) + (c * 2)] }) };
            // The grains of a case between t0 and t1 s: [start, length, peak]
            // of every stretch over 1e-4 (a Hann window is under it for its
            // outer 0.3 %).
            bumps = { |xs, t0, t1|
                var out = List.new, at, pk = 0;
                ((t0 * sr).asInteger .. (t1 * sr).asInteger).do { |f|
                    var v = xs[f].abs;
                    if(at.isNil and: { v > 1e-4 }) { at = f; pk = 0 };
                    if(at.notNil) { pk = pk.max(v); if(v <= 1e-4) { out.add([at / sr, (f - at) / sr, pk]); at = nil } };
                };
                out.asArray
            };
            gapsCv = { |ts| var d = ts.differentiate.drop(1), m = d.mean; (d.collect { |v| (v - m).squared }.mean.sqrt) / m };
            ok.("every dust render is finite", dData.every { |v| v.isNaN.not and: { v.abs < inf } });
            x = bumps.(left.(\rain), 1, 7.9);
            ok.("dust 1: about 3.75 grains a second (2.2 to 5.8 over 6.9 s)", (x.size >= 15) and: { x.size <= 40 },
                x.size.asString);
            y = x.collect(_[1]).mean;
            ok.("...of 15 ms on average (10 to 20)", (y >= 0.010) and: { y <= 0.020 }, (y * 1000).round(0.1).asString ++ " ms");
            ok.("...at irregular gaps (spread over 30 %)", gapsCv.(x.collect(_[0])) > 0.3, gapsCv.(x.collect(_[0])).round(0.01).asString);
            y = x.collect(_[2]).sort[x.size div: 2];
            ok.("...each held up by the overlaps' ratio to the -1/4 (a peak of 0.5 x " ++ liftOf.(1, 1).round(0.01) ++ ")",
                (y - (0.5 * liftOf.(1, 1))).abs < (0.05 * 0.5 * liftOf.(1, 1)), y.round(0.001).asString);
            x = bumps.(left.(\capped), 1, 7.9);
            y = x.collect(_[2]).sort[x.size div: 2];
            ok.("...the lift at most x 4 (Size 4, Density 16: " ++ liftOf.(4, 16 / 6).round(0.01) ++ ")",
                (liftOf.(4, 16 / 6) == 4) and: { (y - 2).abs < 0.1 }, y.round(0.001).asString);
            // The share of the time the ramp sounds, a quarter of it at a time.
            duty = (0 .. 3).collect { |q| var t0 = 0.5 + (q * 1.75), xs = left.(\ramp);
                (((t0 * sr).asInteger .. ((t0 + 1.75) * sr).asInteger).count { |f| xs[f].abs > 1e-4 })
                    / (1.75 * sr) };
            ok.("a ramp of dust: the grains sound less of the time, every quarter less (from nearly all, to under a third)",
                (duty[0] > 0.9) and: { duty.differentiate.drop(1).every { |d| d < 0 } } and: { duty[3] < 0.3 },
                duty.round(0.01).asString);
        };
    }.value;
    [osc, wav, src].do { |f| if(File.exists(f)) { File.delete(f) } };
    File.delete(tmp);
    "".postln;
    if(fail == 0) { ("NRT GRAINS PASSED — " ++ pass ++ " checks").postln; 0.exit } {
        ("NRT GRAINS FAILED — " ++ fail ++ " of " ++ (pass + fail)).postln;
        fails.do { |f| ("  " ++ f).postln };
        1.exit;
    };
};
)
