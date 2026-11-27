// megalooper — the loop's notes in the engine, heard offline (roadmap item 24,
// docs/dev/sampler.md; LooperSynthDefs.noteSlices).
//
//     sclang scripts/sa/nrt-slices.scd
//
// One offline render (scsynth -N on a far port; megalooper, if it runs, is not
// touched): engines on buffers of their own, loaded from the same loop of
// plucks over noise (24007 frames, no whole number of blocks), one slice table
// for all of them (LoopSlices, the plucks' starts; the last slice spans the
// seam), a pulse of 4800 frames (100 ms). Each engine on two output channels of
// its own. "old" is the graph without the notes, engineGraph(false, 4, 1,
// false), as it was before.
//
//   0 new, no table in force (slicesOn 0)     1 old
//   2 new, the table, notes off (noteLen 0, noteRev 0)
//   3 new, noteRev 1 set 30 ms into the first pass: each note reversed in its
//     slot from the next pass
//   4 new, noteRev 1 and dir -1 set together: the loop backwards, each note
//     forwards (a retrograde)
//   5 new, noteLen 1, the gate          6 new, noteLen 1, the decay
//   7 new, noteRev 1 set in the first pass, 0 again in the reversed one
//   8 new, rate 0.5, noteRev 1 from the start: the mirror at half speed
//   9 new, noteRev 1 from the start, a declick of 96 frames: the mirrored
//     read crossing the buffer's seam inside the slot that spans it
//  10 new, the table, notes off, on a pulse of 100 frames: 16 pulses are
//     shorter than every note here, so off has to mean off, not "too long to
//     cut anything"
//
// Exits 0 if every check passed, 1 otherwise.
(
var sr = 48000, len = 24007, dur = 2.2, engines = 11, chans = engines * 2, tauFrames = 4800;
var starts = [1500, 5003, 9013, 13000, 17500, 21020];
var tmp = PathName.tmp +/+ "megalooper-nrt-slices-" ++ thisProcess.pid;
var osc = tmp +/+ "slices.osc", wav = tmp +/+ "slices.wav", src = tmp +/+ "loop.wav";
var after = { |i| tmp +/+ "after-" ++ i ++ ".wav" };
var pass = 0, fail = 0, fails = List.new;
var ok = { |label, cond, detail|
    if(cond == true) { pass = pass + 1; ("  ok    " ++ label).postln } {
        fail = fail + 1;
        fails.add(label ++ (detail !? { |d| " — " ++ d } ? ""));
        ("  FAIL  " ++ label ++ (detail !? { |d| " — " ++ d } ? "")).postln;
    };
};
var newDef = SynthDef(\megaNrtSlicesNew, LooperSynthDefs.engineGraph(false));
var oldDef = SynthDef(\megaNrtSlicesOld, LooperSynthDefs.engineGraph(false, 4, 1, false));
var tbl = LoopSlices.table(starts, len), table = LoopSlices.padded(tbl);
// [def, its args, [[time, control, value], ...]] per engine, in the list's
// order. The engines start at 0.1 s, the loop is 0.5 s: 0.13 s is in the
// first pass, 0.85 s in the second.
var on = [\slicesOn, 1];
var setups = [
    [\megaNrtSlicesNew, []],
    [\megaNrtSlicesOld, []],
    [\megaNrtSlicesNew, on],
    [\megaNrtSlicesNew, on, [[0.13, \noteRev, 1]]],
    [\megaNrtSlicesNew, on, [[0.13, \noteRev, 1], [0.13, \dir, -1]]],
    [\megaNrtSlicesNew, on ++ [\noteLen, 1, \noteShape, 0]],
    [\megaNrtSlicesNew, on ++ [\noteLen, 1, \noteShape, 1]],
    [\megaNrtSlicesNew, on, [[0.13, \noteRev, 1], [0.85, \noteRev, 0]]],
    [\megaNrtSlicesNew, on ++ [\noteRev, 1, \rate, 0.5]],
    [\megaNrtSlicesNew, on ++ [\noteRev, 1, \declickFrames, 96]],
    [\megaNrtSlicesNew, on ++ [\tauFrames, 100]]
];
// The loop: a decaying pluck at each start over arithmetic noise, so every run
// is the same. Interleaved stereo, the right a little different.
var loop = FloatArray.fill(len * 2, { |j|
    var i = j div: 2, c = j % 2, x;
    x = ((((sin((i * 12.9898) + (c * 78.233)) * 43758.5453).frac * 2) - 1) * 0.02);
    starts.do { |s, k|
        var d = (i - s).mod(len);
        x = x + (sin(d * 2pi * (220 + (k * 55) + (c * 3)) / sr) * 0.5 * exp(d.neg / (0.05 * sr)) * (d / 48).min(1));
    };
    x
});
var score, cmd, said, sf, data, frames, out, start, buf, sliceOf, mirror, played, differ, finite, miss, report;

File.mkdir(tmp);
sf = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(2).sampleRate_(sr);
sf.openWrite(src);
sf.writeData(loop);
sf.close;

score = [[0.0, [\d_recv, newDef.asBytes]], [0.0, [\d_recv, oldDef.asBytes]],
        [0.0, [\b_alloc, 50, table.size, 1]], [0.0, [\b_setn, 50, 0, table.size] ++ table]]
    ++ setups.collect { |s, i| [0.0, [\b_allocRead, i, src]] }
    ++ setups.collect { |s, i|
        [0.1, [\s_new, s[0], 1000 + i, 1, 0,
            \bufnum, i, \in, 0, \startFrame, 0, \loopFrames, len, \out, i * 2,
            \rate, 1, \latencyFrames, 0, \declickFrames, 0,
            \phaseBus, i, \gateBus, 100, \sliceBuf, 50, \tauFrames, tauFrames] ++ s[1]] }
    ++ setups.collect { |s, i| (s[2] ? []).collect { |e| [e[0], [\n_set, 1000 + i, e[1], e[2]]] } }.flatten(1)
    // Every synth freed before the end (scsynth 3.14.1 can hang in its offline
    // cleanup otherwise), then each buffer written as the engines left it.
    ++ [[dur - 0.1, [\n_free] ++ setups.collect { |s, i| 1000 + i }]]
    ++ setups.collect { |s, i| [dur - 0.05, [\b_write, i, after.(i), "wav", "float"]] }
    ++ [[dur, [\c_set, 0, 0]]];
Score(score).writeOSCFile(osc);
cmd = "perl -e 'alarm shift; exec @ARGV' 120 " ++ MegaSAPlugins.scsynthPath.shellQuote ++ " -u " ++ (58500 + 200.rand)
    ++ " -m 65536 -N " ++ osc.shellQuote ++ " _ " ++ wav.shellQuote ++ " " ++ sr ++ " WAV float -o " ++ chans ++ " -i 0 2>&1";
said = cmd.unixCmdGetStdOut;
sf = SoundFile.openRead(wav);
if(sf.isNil or: { sf.numFrames < ((dur - 0.2) * sr) }) {
    ("  FAIL  the render: " ++ said.split($\n).reject(_.isEmpty).keep(-4).join(" | ")).postln;
    sf !? { |f| f.close };
    ([osc, wav, src] ++ setups.collect { |s, i| after.(i) }).do { |f| if(File.exists(f)) { File.delete(f) } };
    File.delete(tmp);
    "NRT SLICES FAILED — no render".postln;
    1.exit;
} {
    frames = sf.numFrames;
    data = FloatArray.newClear(frames * chans);
    sf.readData(data);
    sf.close;
    // Engine e's channel c at frame t after the engines started.
    out = { |e, c, t| data[((start + t) * chans) + (e * 2) + c] };
    // The loop's channel c at frame i, round the loop.
    buf = { |c, i| loop[(i.mod(len) * 2) + c] };
    // The slice under loop frame p: [its start, its end] (the table's lookup).
    sliceOf = { |p| var s = LoopSlices.sliceAt(tbl, p); [s[0], s[1]] };
    // Where a reversed note reads at loop frame p.
    mirror = { |p| var s = sliceOf.(p); (((s[0] + s[1]) - 1) - p).mod(len) };
    // Where engine 1 (old) started: where it plays frame t of the loop at t.
    start = 0;
    start = (4800 - 128, 4800 - 64 .. 4800 + 128).detect { |s0|
        (1..200).every { |t| data[((s0 + t) * chans) + 2] == buf.(0, t) }
    };
    played = ((dur - 0.1 - 0.1) * sr).asInteger - 64;
    differ = { |a, b| (0 .. played - 1).inject(0, { |m, t|
        m.max((out.(a, 0, t) - out.(b, 0, t)).abs).max((out.(a, 1, t) - out.(b, 1, t)).abs) }) };
    finite = { |e| (0 .. frames - 1).every { |f| data[(f * chans) + (e * 2)].isNaN.not and: { data[(f * chans) + (e * 2) + 1].isNaN.not } } };
    // The first t in from..to-1 (of those `keep` lets through) where engine e
    // does not play `want.(t)` on both channels, as [t, got, want], or nil.
    miss = { |e, from, to, want, keep|
        var bad, w, t = from;
        while { bad.isNil and: { t < to } } {
            if(keep.isNil or: { keep.(t) }) {
                w = want.(t);
                if((out.(e, 0, t) != w[0]) or: { out.(e, 1, t) != w[1] }) { bad = t };
            };
            t = t + 1;
        };
        bad !? { |b| [b, out.(e, 0, b), want.(b)[0]] }
    };
    // Away from a slot's edges (the 4 ms fades) and the seam's sample.
    report = { |m| m !? { |x| "at frame " ++ x[0] ++ " (loop frame " ++ x[0].mod(len) ++ "): " ++ x[1] ++ ", want " ++ x[2] } };

    "== the loop's notes in the engine, offline ==".postln;
    ok.("the render found where the engines start", start.notNil, "no start within two blocks of 0.1 s");
    if(start.notNil) {
        {
            var edge = (sr * LooperSynthDefs.noteEdge).ceil.asInteger + 1;
            var inner = { |p| var s = sliceOf.(p), d = p - s[0]; (d >= edge) and: { ((s[1] - 1) - p) >= edge } };
            var notSeam = { |t| t.mod(len) != 0 };
            // Nor where a reversed note reads the buffer's own seam (its frame
            // 0), which the mirrored read's declick silences (checked on its own
            // below, with engine 9).
            var readsSeam = { |p| mirror.(p) == 0 };
            var fwd = { |t| [buf.(0, t), buf.(1, t)] };
            var rev = { |t| var m = mirror.(t.mod(len)); [buf.(0, m), buf.(1, m)] };
            var back = { |t| (t - len).neg.mod(len) };
            var m, lenF, rel, hold, gainAt, gainNear, worst, ratioOk;

            // ---- off is the engine as it was --------------------------------
            ok.("no table in force: the new engine sounds as the old, sample for sample", differ.(0, 1) == 0,
                "largest difference " ++ differ.(0, 1));
            ok.("the table in force, notes off: as the old, sample for sample", differ.(2, 1) == 0,
                "largest difference " ++ differ.(2, 1));
            ok.("...on a pulse so short every note is longer than 16 of them, all the same", differ.(10, 1) == 0,
                "largest difference " ++ differ.(10, 1));

            // ---- each note reversed in its slot -----------------------------
            m = miss.(3, 0, len, fwd, notSeam);
            ok.("noteRev set mid-pass: that pass plays on as it is", m.isNil, report.(m));
            m = miss.(3, len, len * 3, rev, { |t| notSeam.(t) and: { inner.(t.mod(len)) } and: { readsSeam.(t.mod(len)).not } });
            ok.("...from the sample the next pass begins, each note backwards in its own slot, two passes",
                m.isNil, report.(m));
            ok.("...the slots' edges faded to silence (the frame each starts on)",
                starts.every { |s| (out.(3, 0, len + s) == 0) and: { out.(3, 1, len + s) == 0 } },
                starts.collect { |s| out.(3, 0, len + s) }.asString);
            m = miss.(7, len * 2, played, fwd, notSeam);
            ok.("noteRev off again in the reversed pass: as it is from the sample that pass ends", m.isNil, report.(m));
            m = miss.(7, len, len * 2, rev, { |t| notSeam.(t) and: { inner.(t.mod(len)) } and: { readsSeam.(t.mod(len)).not } });
            ok.("...and reversed until then", m.isNil, report.(m));

            // ---- with Reverse, a retrograde -------------------------------
            m = miss.(4, len, len * 3, { |t| var p = back.(t), mm = mirror.(p); [buf.(0, mm), buf.(1, mm)] },
                { |t| notSeam.(t) and: { inner.(back.(t)) } and: { readsSeam.(back.(t)).not } });
            ok.("with Reverse: the loop backwards, each note forwards (it reads its slot from the start)", m.isNil, report.(m));

            // ---- at half speed ---------------------------------------------
            m = miss.(8, 0, len * 2, { |t| var mm = mirror.(t div: 2); [buf.(0, mm), buf.(1, mm)] },
                { |t| t.even and: { notSeam.(t div: 2) } and: { inner.(t div: 2) } and: { readsSeam.(t div: 2).not } });
            ok.("at half speed: every other sample its mirrored frame", m.isNil, report.(m));

            // ---- the mirrored read's own declick at the buffer's seam -------
            // The slot that spans the seam, [21020, 1500 + len): its mirror
            // reaches frame 0 of the buffer at loop frame 22519.
            ok.("the mirror crosses the buffer's seam at loop frame 22519", mirror.(22519) == 0);
            ok.("...faded to silence there", (out.(9, 0, len + 22519) == 0) and: { out.(9, 1, len + 22519) == 0 },
                [out.(9, 0, len + 22519), out.(9, 1, len + 22519)].asString);
            worst = (1 .. 95).collect { |d| [22519 - d, 22519 + d] }.flat.select { |p| inner.(p) }.every { |p|
                out.(9, 0, len + p).abs <= ((buf.(0, mirror.(p)).abs * ((p - 22519).abs / 96)) + 1e-6) };
            ok.("...and faded in over the declick either side", worst);
            m = miss.(9, len, len * 2, rev, { |t| var p = t.mod(len); notSeam.(t) and: { inner.(p) }
                and: { ((p - 22519).abs > 96) } and: { (p > 96) and: { p < (len - 96) } } });
            ok.("...the rest of the reversed pass as without it", m.isNil, report.(m));

            // ---- the gate and the decay -------------------------------------
            lenF = LooperSynthDefs.noteLenMin * tauFrames;
            rel = LooperSynthDefs.noteRelease * sr;
            hold = LooperSynthDefs.noteHold * sr;
            // The note's own frame at loop frame p.
            gainAt = { |p| p - sliceOf.(p)[0] };
            m = miss.(5, len, len * 3, fwd, { |t| var d = gainAt.(t.mod(len)); notSeam.(t) and: { d >= 150 } and: { d <= (lenF - 2) } });
            ok.("the gate at its shortest: each note as played for its first " ++ (lenF / sr * 1000).round(0.1) ++ " ms",
                m.isNil, report.(m));
            m = miss.(5, len, len * 3, { [0, 0] }, { |t| var d = gainAt.(t.mod(len)); d >= (lenF + rel + 200) });
            ok.("...silent from " ++ ((lenF + rel) / sr * 1000).round(0.1) ++ " ms (its release) to the next note",
                m.isNil, report.(m));
            // The gain where the loop is loud enough to read it: out / loop at
            // the note's frame d of the slice from starts[k], or the nearest
            // frame within 3 where the loop is over 0.05.
            gainNear = { |e, k, d|
                var best;
                (0 .. 3).do { |o| [d + o, d - o].do { |dd| var p = starts[k] + dd;
                    if(best.isNil and: { buf.(0, p).abs > 0.05 }) { best = [dd, out.(e, 0, len + p) / buf.(0, p)] } } };
                best
            };
            worst = (1 .. 9).collect { |k| var d = (lenF + (rel * k / 10)).round.asInteger, g = gainNear.(5, 1, d);
                g !? { (g[1] - ((lenF + rel - g[0]) / rel)).abs } ? inf };
            ok.("...falling straight through its release (the gain against the ramp, nine points)",
                worst.every { |x| x < 0.002 }, worst.round(0.0001).asString);
            ratioOk = { |e, d, want, tol|
                var p = starts[4] + d, b = buf.(0, p), g;
                g = if(b.abs < 0.02) { nil } { out.(e, 0, len + p) / b };
                g.notNil and: { (g - want).abs <= tol }
            };
            ok.("the decay at its shortest: as played for its first " ++ (hold / sr * 1000).round(0.1) ++ " ms",
                (200 .. (hold - 1).asInteger).every { |d| var p = starts[4] + d; out.(6, 0, len + p) == buf.(0, p) });
            ok.("...then down 60 dB in " ++ ((LooperSynthDefs.noteDecay * lenF) / sr * 1000).round(0.1) ++ " ms",
                [100, 300, 600, 900].every { |k|
                    var d = (hold + k).asInteger;
                    var want = exp(-6.9 * k / (LooperSynthDefs.noteDecay * lenF));
                    (-2 .. 2).any { |o| ratioOk.(6, d + o, want, 0.003) } },
                [100, 300, 600, 900].collect { |k| var d = (hold + k).asInteger, p = starts[4] + d;
                    [k, (out.(6, 0, len + p) / buf.(0, p)).round(0.0001), exp(-6.9 * k / (LooperSynthDefs.noteDecay * lenF)).round(0.0001)] }.asString);
        }.value;
    };
    // What the engines left in their buffers: playing never writes.
    setups.do { |s, i|
        var f = SoundFile.openRead(after.(i)), got, diff;
        if(f.isNil) { ok.("engine " ++ i ++ ": its buffer was written", false) } {
            got = FloatArray.newClear(f.numFrames * f.numChannels);
            f.readData(got);
            f.close;
            diff = if(got.size != loop.size) { inf } { (got - loop).abs.maxItem };
            ok.("engine " ++ i ++ ": the loop came out exactly as it went in", diff == 0, "largest change " ++ diff);
        };
    };
    ok.("every render is finite", (0 .. engines - 1).every { |e| finite.(e) });

    ([osc, wav, src] ++ setups.collect { |s, i| after.(i) }).do { |f| if(File.exists(f)) { File.delete(f) } };
    File.delete(tmp);
    "".postln;
    if(fail == 0) { ("NRT SLICES PASSED — " ++ pass ++ " checks").postln; 0.exit } {
        ("NRT SLICES FAILED — " ++ fail ++ " of " ++ (pass + fail)).postln;
        fails.do { |f| ("  " ++ f).postln };
        1.exit;
    };
};
)
