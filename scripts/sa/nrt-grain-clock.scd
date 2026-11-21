// megalooper — the grain clock (LooperSynthDefs.grainClockGraph; roadmap
// item 23 idea 2, docs/dev/microsound.md), heard offline.
//
//     sclang scripts/sa/nrt-grain-clock.scd
//
// The loop is a constant 0.5 on the left and silence on the right, and the
// window is rectangular, so the output IS the grains: each one starts on the
// sample its trigger fires and is as long as it was made. A synth per case
// writes that case's engine phase (seconds into its loop) to a control bus, as
// the engine does; `ref` marks the sample the synths start on.
//
//   grid      a beat of 0.25 s, one grain a beat, half a beat long
//   grid2     two grains a beat
//   locked    the engine already 0.3 s into the loop: the first grain on its
//             next beat (0.2 s), not the clock's own (0.25)
//   free      the same, unlocked: the clock's own
//   groups    7/8 of 0.2 s eighths (2+2+3), a grain per group, half as long
//   sync      ten grains a second on the grid, 10 ms each
//   cloud     the same scattered: about as many, at random
// Pulsars (Phase B), a beat of 0.25 s:
//   pulsarQ   pulsar 0.25: the grid doubled once (every 0.125 s)
//   pulsarH   pulsar 0.5: doubled up to 16 Hz, still on the grid
//   pulsar34  pulsar 0.75: half way from 16 Hz to the root (A2, 110 Hz)
//   pulsar1   pulsar 1: the root, 110 Hz
//   masked    7/8 of 0.2 s eighths, pulsar 0.5 (20 Hz), mask 0.4: pulses
//             only in the first 60 % of each group
//
// One render (scsynth -N on a far port); exits 0 if every check passed.
(
var sr = 48000, dur = 3.05, bufSecs = 3, start = 0.05;
var tmp = PathName.tmp +/+ "megalooper-nrt-grainclock-" ++ thisProcess.pid;
var osc = tmp +/+ "clock.osc", wav = tmp +/+ "clock.wav", src = tmp +/+ "loop.wav";
var pass = 0, fail = 0, fails = List.new;
var ok = { |label, cond, detail|
    if(cond == true) { pass = pass + 1; ("  ok    " ++ label).postln } {
        fail = fail + 1;
        fails.add(label ++ (detail !? { |d| " — " ++ d } ? ""));
        ("  FAIL  " ++ label ++ (detail !? { |d| " — " ++ d } ? "")).postln;
    };
};
var clockDef = SynthDef(\nrtClock, LooperSynthDefs.grainClockGraph);
var phaseDef = SynthDef(\nrtClockPhase, { |out, loopSecs = 2, phase0 = 0| Out.kr(out, (Sweep.kr(0, 1) + phase0).mod(loopSecs)) });
var refDef = SynthDef(\nrtClockRef, { |out| Out.ar(out, Impulse.ar(0)) });
var slots = LooperSynthDefs.groupSlots;
// A take of one chord, A: its root in the first slot (period 0).
var rootA = [\chordStarts, [0] ++ (1e9 ! (LooperSynthDefs.chordSlots - 1)),
    \chordRoots, [9] ++ (0 ! (LooperSynthDefs.chordSlots - 1)), \chordPeriod, 0, \octave, 2];
// [label, loop seconds, engine phase at the start, the clock's args]
var cases = [
    [\grid, 2, 0, [\tau, 0.25, \division, 1, \length, 0.5]],
    [\grid2, 2, 0, [\tau, 0.25, \division, 2, \length, 0.5]],
    [\locked, 2, 0.3, [\tau, 0.25, \division, 1, \length, 0.5]],
    [\free, 2, 0.3, [\tau, 0.25, \division, 1, \length, 0.5, \locked, 0]],
    [\groups, 1.4, 0, [\tau, 0.2, \groups, 1, \length, 0.5, \headsBuf, 2, \lensBuf, 3, \groupCount, 3]],
    [\groupsLate, 1.4, 0, [\tau, 0.2, \groups, 1, \length, 0.5, \headsBuf, 6, \lensBuf, 7, \groupCount, 3]],
    [\sync, 2, 0, [\tau, 0.1, \division, 1, \length, 0.1]],
    [\cloud, 2, 0, [\tau, 0.1, \division, 1, \length, 0.1, \scatter, 1]],
    [\pulsarQ, 2, 0, [\tau, 0.25, \division, 1, \length, 0.5, \pulsar, 0.25]],
    [\pulsarH, 2, 0, [\tau, 0.25, \division, 1, \length, 0.5, \pulsar, 0.5]],
    [\pulsar34, 2, 0, [\tau, 0.25, \division, 1, \length, 0.5, \pulsar, 0.75] ++ rootA],
    [\pulsar1, 2, 0, [\tau, 0.25, \division, 1, \length, 0.5, \pulsar, 1] ++ rootA],
    [\masked, 1.4, 0, [\tau, 0.2, \division, 1, \length, 0.5, \pulsar, 0.5, \mask, 0.4,
        \headsBuf, 2, \lensBuf, 3, \groupCount, 3]]
];
var chans = (cases.size + 1) * 2, score, cmd, said, sf, data, chan, idx, grains, refAt, on, gaps, lens, cv, n, x;

File.mkdir(tmp);
sf = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(2).sampleRate_(sr);
sf.openWrite(src);
sf.writeData(FloatArray.fill((sr * bufSecs * 2).asInteger, { |j| if(j.even) { 0.5 } { 0 } }));
sf.close;
score = [
    [0.0, [\d_recv, clockDef.asBytes]], [0.0, [\d_recv, phaseDef.asBytes]], [0.0, [\d_recv, refDef.asBytes]],
    [0.0, [\b_allocRead, 0, src]],
    [0.0, [\b_alloc, 1, 1024, 1]],
    [0.0, [\b_setn, 1, 0, 1024] ++ (1 ! 1024)],
    // 7/8's heads and lengths, as the Looper will send them
    [0.0, [\b_alloc, 2, slots, 1]], [0.0, [\b_setn, 2, 0, slots] ++ [0, 0.4, 0.8] ++ (1e9 ! (slots - 3))],
    [0.0, [\b_alloc, 3, slots, 1]], [0.0, [\b_setn, 3, 0, slots] ++ [0.4, 0.4, 0.6] ++ (0 ! (slots - 3))],
    // ...and with its downbeat 0.2 s into the loop: the heads at 0.2, 0.6, 1.0
    [0.0, [\b_alloc, 6, slots, 1]], [0.0, [\b_setn, 6, 0, slots] ++ [0.2, 0.6, 1.0] ++ (1e9 ! (slots - 3))],
    [0.0, [\b_alloc, 7, slots, 1]], [0.0, [\b_setn, 7, 0, slots] ++ [0.4, 0.4, 0.6] ++ (0 ! (slots - 3))],
    [start, [\s_new, \nrtClockRef, 8999, 1, 0, \out, cases.size * 2]]
];
cases.do { |c, i|
    score = score.add([start, [\s_new, \nrtClockPhase, 9000 + i, 0, 0, \out, 50 + i, \loopSecs, c[1], \phase0, c[2]]]);
    score = score.add([start, [\s_new, \nrtClock, 10000 + i, 1, 0]
        ++ ([\bufnum, 0, \startFrame, 0, \loopFrames, (c[1] * sr).round.asInteger, \amp, 1, \out, i * 2,
            \envbuf, 1, \phaseBus, 50 + i, \locked, 1] ++ c[3]).asOSCArgArray]);
};
score = score ++ [[dur - 0.02, [\n_free, 8999] ++ cases.collect { |c, i| [9000 + i, 10000 + i] }.flatten],
    [dur, [\c_set, 0, 0]]];
Score(score).writeOSCFile(osc);
cmd = "perl -e 'alarm shift; exec @ARGV' 120 " ++ MegaSAPlugins.scsynthPath.shellQuote ++ " -u " ++ (58500 + 200.rand)
    ++ " -m 65536 -N " ++ osc.shellQuote ++ " _ " ++ wav.shellQuote ++ " " ++ sr ++ " WAV float -o " ++ chans
    ++ " -i 0 2>&1";
said = cmd.unixCmdGetStdOut;
sf = SoundFile.openRead(wav);
if(sf.isNil) {
    ("  FAIL  the render: " ++ said.split($\n).reject(_.isEmpty).keep(-4).join(" | ")).postln;
    "NRT GRAIN CLOCK FAILED — no render".postln;
    1.exit;
} {
    data = FloatArray.newClear(sf.numFrames * chans);
    sf.readData(data);
    sf.close;
    n = sf.numFrames;
    idx = { |label| cases.detectIndex { |c| c[0] == label } };
    chan = { |c, side = 0| Array.fill(n, { |f| data[(f * chans) + (c * 2) + side] }) };
    // The grains of a case: [start frame, length in frames] where the left
    // side rises over 0.25 and falls back.
    grains = { |label|
        var xs = chan.(idx.(label)), out = List.new, at;
        xs.do { |v, f|
            if(at.isNil and: { v > 0.25 }) { at = f };
            if(at.notNil and: { v <= 0.25 }) { out.add([at, f - at]); at = nil };
        };
        out.asArray
    };
    refAt = chan.(cases.size).detectIndex { |v| v > 0.5 };
    on = { |label| grains.(label).collect { |g| (g[0] - refAt) / sr } };
    "== the grain clock, offline ==".postln;
    ok.("every render is finite", data.every { |v| v.isNaN.not and: { v.abs < inf } });
    ok.("the synths started (the mark is there)", refAt.notNil);
    // Within two samples of where they belong.
    x = on.(\grid);
    ok.("a grain a beat: on every beat from the first (0.25, 0.5 ... 2.75 s)",
        (x.size == 11) and: { x.every { |t, i| (t - ((i + 1) * 0.25)).abs < (2 / sr) } }, x.round(0.0001).asString);
    lens = grains.(\grid).collect(_[1]);
    ok.("...each half a beat long (6000 frames)", lens.every { |l| (l - 6000).abs <= 2 }, lens.asString);
    x = on.(\grid2);
    ok.("two grains a beat: every 0.125 s", (x.size == 23) and: { x.every { |t, i| (t - ((i + 1) * 0.125)).abs < (2 / sr) } },
        x.size.asString ++ " " ++ x.keep(4).round(0.0001));
    x = on.(\locked);
    ok.("locked to an engine 0.3 s in: on ITS beats, 0.2 s after the start, then every 0.25",
        (x.size > 2) and: { x.every { |t, i| (t - (0.2 + (i * 0.25))).abs < (2 / sr) } }, x.keep(4).round(0.0001).asString);
    x = on.(\free);
    ok.("unlocked: the clock's own beats, from 0.25", (x.size > 2) and: { (x[0] - 0.25).abs < (2 / sr) },
        x.keep(4).round(0.0001).asString);
    x = on.(\groups);
    ok.("7/8 as 2+2+3: a grain on each group's head (0.4, 0.8, 1.4, 1.8, 2.2, 2.8 s)",
        (x.size == 6) and: { x.every { |t, i| (t - [0.4, 0.8, 1.4, 1.8, 2.2, 2.8][i]).abs < (2 / sr) } },
        x.round(0.0001).asString);
    lens = grains.(\groups).collect { |g| (g[1] / sr).round(0.001) };
    // (The last is cut off by the render's end.)
    ok.("...as long as half its group (0.2, 0.3, 0.2 ...)", lens.keep(5) == [0.2, 0.3, 0.2, 0.2, 0.3], lens.asString);
    x = on.(\groupsLate);
    ok.("...with the downbeat 0.2 s in: on the heads (0.2, 0.6, 1.0, 1.6, 2.0, 2.4 s), not at the loop's wrap",
        (x.size == 6) and: { x.every { |t, i| (t - [0.2, 0.6, 1.0, 1.6, 2.0, 2.4][i]).abs < (2 / sr) } },
        x.round(0.0001).asString);
    lens = grains.(\groupsLate).collect { |g| (g[1] / sr).round(0.001) };
    ok.("...each half its own group, the one across the wrap too (0.2, 0.2, 0.3 ...)", lens.keep(6) == [0.2, 0.2, 0.3, 0.2, 0.2, 0.3],
        lens.asString);
    cv = { |ts| var d = ts.differentiate.drop(1), m = d.mean; (d.collect { |v| (v - m).squared }.mean.sqrt) / m };
    x = on.(\sync);
    ok.("ten a second on the grid: 29, evenly (spread of the gaps under 1 %)",
        (x.size == 29) and: { cv.(x) < 0.01 }, x.size.asString ++ ", spread " ++ cv.(x).round(0.001));
    x = on.(\cloud);
    ok.("scattered: about as many (15 to 45) at random (spread over 50 %)",
        (x.size >= 15) and: { x.size <= 45 } and: { cv.(x) > 0.5 }, x.size.asString ++ ", spread " ++ cv.(x).round(0.001));
    "-- pulsars".postln;
    x = on.(\pulsarQ);
    ok.("pulsar 0.25: the grid doubled once, every 0.125 s, on it", (x.size == 23)
        and: { x.every { |t, i| (t - ((i + 1) * 0.125)).abs < (2 / sr) } }, x.size.asString ++ " " ++ x.keep(4).round(0.0001));
    x = on.(\pulsarH);
    ok.("pulsar 0.5: doubled up to 16 Hz (every 0.0625 s), still on the grid", (x.size == 47)
        and: { x.every { |t, i| (t - ((i + 1) * 0.0625)).abs < (2 / sr) } }, x.size.asString ++ " " ++ x.keep(4).round(0.0001));
    // The glide: the mean gap over the second half (the Lag long settled).
    gaps = { |label| var ts = on.(label).select { |t| t > 1.5 }; ts.differentiate.drop(1).mean };
    x = gaps.(\pulsar34);
    ok.("pulsar 0.75: half way (in pitch) from 16 Hz to A2: 42 Hz", (x.reciprocal - (16 * (110 / 16).sqrt)).abs < 0.5,
        x.reciprocal.round(0.01).asString ++ " Hz");
    x = gaps.(\pulsar1);
    ok.("pulsar 1: the chord's root, A2 at 110 Hz", (x.reciprocal - 110).abs < 0.5, x.reciprocal.round(0.01).asString ++ " Hz");
    lens = grains.(\pulsar1).select { |g| g[0] > (1.5 * sr) }.collect(_[1]);
    ok.("...each grain half its pulse long (the pulsaret's duty)", (lens.mean - (sr / 110 / 2)).abs < 2,
        lens.mean.round(0.1).asString ++ " frames");
    x = on.(\masked);
    // Where each falls in its group (heads 0, 0.4, 0.8 of a 1.4 s loop).
    n = x.collect { |t| var p = t.mod(1.4); if(p < 0.4) { p / 0.4 } { if(p < 0.8) { (p - 0.4) / 0.4 } { (p - 0.8) / 0.6 } } };
    ok.("masked 0.4: every pulse in the first 60 % of its group", n.every { |f| f < 0.6 }, n.round(0.01).asString);
    ok.("...18 a loop (5 + 5 + 8), the second loop whole", x.count { |t| (t >= 1.399) and: { t < 2.799 } } == 18,
        x.count { |t| (t >= 1.399) and: { t < 2.799 } }.asString);
    ok.("stereo kept: the right side, silent in the loop, is silent in every case",
        cases.every { |c, i| chan.(i, 1).every { |v| v.abs < 1e-6 } });
    [osc, wav, src].do { |f| if(File.exists(f)) { File.delete(f) } };
    File.delete(tmp);
    "".postln;
    if(fail == 0) { ("NRT GRAIN CLOCK PASSED — " ++ pass ++ " checks").postln; 0.exit } {
        ("NRT GRAIN CLOCK FAILED — " ++ fail ++ " of " ++ (pass + fail)).postln;
        fails.do { |f| ("  " ++ f).postln };
        1.exit;
    };
};
)
