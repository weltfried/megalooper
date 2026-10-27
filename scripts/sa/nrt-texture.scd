// megalooper — the Texture effects (Freeze, Slicer, Tremolo, Octave Down,
// Ring Mod), heard offline.
//
//     sclang scripts/sa/nrt-texture.scd
//
// As nrt-utility.scd: each case one device of MegaSAFx's own SynthDef between
// a test signal on a private bus and two taps, the signal as it went in and as
// it came out. The Slicer's loop phase is a control bus a synth writes as the
// Looper's engine would (seconds into a 4 s loop). Frequencies are read with a
// Goertzel filter over a stretch. One render (scsynth -N on a far port);
// exits 0 if every check passed, 1 otherwise. (docs/dev/rc600-picks.md, 4c.)
(
var sr = 48000, dur = 1.5;
var tmp = PathName.tmp +/+ "megalooper-nrt-texture-" ++ thisProcess.pid;
var osc = tmp +/+ "texture.osc", wav = tmp +/+ "texture.wav";
var pass = 0, fail = 0, fails = List.new;
var ok = { |label, cond, detail|
    if(cond == true) { pass = pass + 1; ("  ok    " ++ label).postln } {
        fail = fail + 1;
        fails.add(label ++ (detail !? { |d| " — " ++ d } ? ""));
        ("  FAIL  " ++ label ++ (detail !? { |d| " — " ++ d } ? "")).postln;
    };
};
var srcDef = SynthDef(\nrtTexSrc, { |bus, freq = 1000, amp = 0.1|
    var sig = SinOsc.ar(freq) * amp;
    Out.ar(bus, [sig, sig]);
});
var tapDef = SynthDef(\nrtTexTap, { |bus, out| Out.ar(out, In.ar(bus, 1)) });
// The right side, for the Tremolo's Spread: that case's second tap.
var tapRDef = SynthDef(\nrtTexTapR, { |bus, out| Out.ar(out, In.ar(bus + 1, 1)) });
// The loop's phase as the engine writes it: seconds into a 4 s loop, from
// `offset` when the synth starts.
var phaseDef = SynthDef(\nrtTexPhase, { |out, offset = 0| Out.kr(out, (Sweep.kr(0, 1) + offset).mod(4)) });
// The Slicer's phase: the synth starts at 0.05 s at 0.3 s into the loop, so
// at render time t the loop is at t + 0.25 s; at 120 BPM (beatDur 0.5) a 16th
// is 0.125 s.
var phaseKr = 50, offset = 0.3;
// [label, type, its settings, the source's, [[time, control, value], ...] sent to the device, phase?]
var cases = [
    [\freezeOn, \freeze, [\freezeFade, 0.05], [\freq, 440, \amp, 0.25], [[0.4, \freezeOn, 1]], false],
    [\freezeOff, \freeze, [], [\freq, 440, \amp, 0.25], [], false],
    [\sliceFree, \slicer, [\beatDur, 0.5], [\freq, 1000, \amp, 0.25], [], false],
    [\slicePhase, \slicer, [\beatDur, 0.5, \slicerSmooth, 0.001], [\freq, 1000, \amp, 0.25], [], true],
    [\slice332, \slicer, [\beatDur, 0.5, \slicerSmooth, 0.001, \slicerPattern, 3, \slicerDuty, 1],
        [\freq, 1000, \amp, 0.25], [], true],
    // Tremolo, depth 100 %: free at 4 Hz; on the loop's 8ths at 120 BPM (a
    // cycle every 0.25 s); and spread, its right side's tap in place of the
    // input's.
    [\tremFree, \tremolo, [\tremoloRate, 4, \tremoloDepth, 1], [\freq, 1000, \amp, 0.25], [], false],
    [\tremSync, \tremolo, [\beatDur, 0.5, \tremoloSync, 0.5, \tremoloDepth, 1], [\freq, 1000, \amp, 0.25], [], true],
    [\tremSpread, \tremolo, [\tremoloRate, 4, \tremoloDepth, 1, \tremoloSpread, 1], [\freq, 1000, \amp, 0.25], [], false],
    [\octave, \octaveDown, [\octaveDownDry, 0], [\freq, 220, \amp, 0.5], [], false],
    [\ring, \ringMod, [\ringModFreq, 300, \ringModMix, 1], [\freq, 1000, \amp, 0.25], [], false]
];
var chans = cases.size * 2, score, cmd, said, sf, data, frames, chanOf, rmsDb, goertzel, idx, at, open, closed, x, y;

File.mkdir(tmp);
score = [[0.0, [\d_recv, srcDef.asBytes]], [0.0, [\d_recv, tapDef.asBytes]], [0.0, [\d_recv, tapRDef.asBytes]],
    [0.0, [\d_recv, phaseDef.asBytes]]]
    ++ MegaSAFx.extraKeys.collect { |k| [0.0, [\d_recv, MegaSAFx.deviceDef(k).asBytes]] }
    ++ [[0.05, [\s_new, \nrtTexPhase, 9000, 0, 0, \out, phaseKr, \offset, offset]]];
cases.do { |c, i|
    var bus = 100 + (i * 2), base = 10000 + (i * 10);
    // The Freeze's input stops at 0.5 s: what comes after is the drone alone.
    var srcEnd = if(c[1] == \freeze) { 0.5 } { dur - 0.05 };
    var on = if(c[4].any { |e| e[1] == MegaSAFx.switchName(c[1]) }) { 0 } { 1 };
    score = score ++ [
        [0.05, [\s_new, \nrtTexSrc, base, 1, 0, \bus, bus] ++ c[3]],
        // Spread's second channel is the output's right side (base + 4, after
        // the device); its input tap writes a bus nobody reads.
        [0.05, [\s_new, \nrtTexTap, base + 1, 3, base, \bus, bus, \out,
            if(c[0] == \tremSpread) { 900 } { (i * 2) + 1 }]],
        [0.05, [\s_new, MegaSAFx.deviceDefName(c[1]), base + 2, 3, base + 1, \bus, bus,
            MegaSAFx.switchName(c[1]), if(c[0] == \freezeOff) { 0 } { on }]
            ++ c[2] ++ (if(c[5]) { [\phaseBus, phaseKr] } { [] })],
        [0.05, [\s_new, \nrtTexTap, base + 3, 3, base + 2, \bus, bus, \out, i * 2]],
        [0.05, if(c[0] == \tremSpread) { [\s_new, \nrtTexTapR, base + 4, 3, base + 3, \bus, bus, \out, (i * 2) + 1] }
            { [\s_new, \nrtTexTap, base + 4, 3, base + 3, \bus, bus, \out, 900] }],
        [srcEnd, [\n_free, base]],
        [dur - 0.05, [\n_free, base + 1, base + 2, base + 3, base + 4]]
    ] ++ c[4].collect { |e| [e[0], [\n_set, base + 2, e[1], e[2]]] };
};
score = score ++ [[dur - 0.05, [\n_free, 9000]]];
score = score.sort { |a, b| a[0] <= b[0] } ++ [[dur, [\c_set, 0, 0]]];
Score(score).writeOSCFile(osc);
cmd = "perl -e 'alarm shift; exec @ARGV' 120 " ++ MegaSAPlugins.scsynthPath.shellQuote ++ " -u " ++ (58500 + 200.rand)
    ++ " -m 65536 -N " ++ osc.shellQuote ++ " _ " ++ wav.shellQuote ++ " " ++ sr ++ " WAV float -o " ++ chans
    ++ " -i 0 2>&1";
said = cmd.unixCmdGetStdOut;
sf = SoundFile.openRead(wav);
if(sf.isNil) {
    ("  FAIL  the render: " ++ said.split($\n).reject(_.isEmpty).keep(-4).join(" | ")).postln;
    "NRT TEXTURE FAILED — no render".postln;
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
    // The amplitude of `freq` in xs (a Goertzel filter), as a sine's peak.
    goertzel = { |xs, freq|
        var w = 2pi * freq / sr, c = 2 * cos(w), s1 = 0, s2 = 0, s0;
        xs.do { |v| s0 = v + (c * s1) - s2; s2 = s1; s1 = s0 };
        (((s1.squared + s2.squared) - (c * s1 * s2)).max(0).sqrt * 2 / xs.size).max(1e-12)
    };
    "== the Texture effects, offline ==".postln;
    ok.("every render is finite", data.every { |v| v.isNaN.not and: { v.abs < inf } });

    // Freeze: switched on at 0.4 s while a 440 Hz tone plays; the tone stops at 0.5 s.
    // After the tone: a drone, its energy where the tone's was.
    x = rmsDb.(chanOf.(\freezeOn, 0, 0.8, 1.4));
    y = rmsDb.(chanOf.(\freezeOff, 0, 0.8, 1.4));
    ok.("Freeze: what it was switched on in goes on after the tone stops (above -40 dBFS)", x > -40,
        x.round(0.1).asString ++ " dBFS");
    ok.("...the tone's: 440 Hz at least 20 dB over 2 kHz",
        (goertzel.(chanOf.(\freezeOn, 0, 0.8, 1.4), 440).ampdb - goertzel.(chanOf.(\freezeOn, 0, 0.8, 1.4), 2000).ampdb) > 20,
        [440, 2000].collect { |f| goertzel.(chanOf.(\freezeOn, 0, 0.8, 1.4), f).ampdb.round(0.1) }.asString);
    ok.("...switched off, nothing after the tone stops (below -100)", y < -100, y.round(0.1).asString ++ " dBFS");
    ok.("...and while the tone plays it passes as it came beside the drone (Dry 100 %)",
        (goertzel.(chanOf.(\freezeOff, 0, 0.1, 0.45), 440) - goertzel.(chanOf.(\freezeOff, 1, 0.1, 0.45), 440)).abs < 1e-4);

    // Slicer, no loop phase: open half the time.
    x = chanOf.(\sliceFree, 0, 0.3, 1.3).clump(48).collect { |b| rmsDb.(b) };
    ok.("Slicer with no loop moving: open half the time (16ths at 120 BPM, duty 50 %)",
        ((x.count { |v| v > -20 } / x.size) - 0.5).abs < 0.08, (x.count { |v| v > -20 } / x.size).round(0.01).asString);
    // On the loop's phase: at render time t the loop is at t + 0.25 s, a 16th
    // 0.125 s long: open in the first half of each, shut in the second.
    at = { |t| (t + 0.25).mod(0.125) };
    open = List.new; closed = List.new;
    (0.4, 0.405 .. 1.3).do { |t|
        var b = rmsDb.(chanOf.(\slicePhase, 0, t, t + 0.004)), ph = at.(t);
        if((ph > 0.01) and: { ph < 0.05 }) { open.add(b) };
        if((ph > 0.075) and: { ph < 0.115 }) { closed.add(b) };
    };
    ok.("Slicer on the loop's phase: open in each 16th's first half, on the loop's grid",
        open.notEmpty and: { open.every { |v| v > -20 } }, open.minItem.round(0.1).asString ++ " dB at the least");
    ok.("...shut in its second half (below -80)", closed.notEmpty and: { closed.every { |v| v < -80 } },
        closed.maxItem.round(0.1).asString ++ " dB at the most");
    // 3+3+2, duty 100 %: of each eight 16ths, the 1st, 4th and 7th open.
    open = List.new; closed = List.new;
    (0.4, 0.405 .. 1.3).do { |t|
        var b = rmsDb.(chanOf.(\slice332, 0, t, t + 0.004)), k = ((t + 0.25) / 0.125).floor.asInteger.mod(8),
            ph = at.(t);
        if((ph > 0.02) and: { ph < 0.1 }) { if([0, 3, 6].includes(k)) { open.add(b) } { closed.add(b) } };
    };
    ok.("...3+3+2: the 1st, 4th and 7th of eight 16ths open, the rest shut",
        open.notEmpty and: { closed.notEmpty } and: { open.every { |v| v > -20 } } and: { closed.every { |v| v < -80 } },
        [open.minItem.round(0.1), closed.maxItem.round(0.1)].asString);

    // Tremolo, depth 100 % on a 1 kHz tone (-15 dBFS RMS): full level at the
    // top of each cycle, silence at its bottom. Free at 4 Hz from the synth's
    // start (0.05 s): tops at 0.05 + k/4, bottoms an eighth of a second on.
    // On the loop's 8ths: the loop is at t + 0.25, so tops at multiples of
    // 0.25 s, bottoms between.
    x = { |label, which, t| rmsDb.(chanOf.(label, which, t - 0.002, t + 0.002)) };
    y = rmsDb.(chanOf.(\tremFree, 1, 0.3, 0.5));
    ok.("Tremolo free at 4 Hz: full level at each cycle's top, within 1 dB",
        [0.3, 0.55, 0.8, 1.05].every { |t| (x.(\tremFree, 0, t) - y).abs < 1 },
        [0.3, 0.55, 0.8, 1.05].collect { |t| (x.(\tremFree, 0, t) - y).round(0.1) }.asString);
    ok.("...and silent at its bottom (40 dB under)", [0.425, 0.675, 0.925, 1.175].every { |t| (x.(\tremFree, 0, t) - y) < -40 },
        [0.425, 0.675, 0.925, 1.175].collect { |t| (x.(\tremFree, 0, t) - y).round(0.1) }.asString);
    ok.("Tremolo on the loop's 8ths: tops on the loop's grid, bottoms between",
        [0.5, 0.75, 1.0, 1.25].every { |t| (x.(\tremSync, 0, t) - y).abs < 1 }
            and: { [0.375, 0.625, 0.875, 1.125].every { |t| (x.(\tremSync, 0, t) - y) < -40 } },
        [0.5, 0.375, 0.75, 0.625].collect { |t| (x.(\tremSync, 0, t) - y).round(0.1) }.asString);
    ok.("Tremolo spread 100 %: the right side is down where the left is up, and up where it is down",
        [0.3, 0.55, 0.8].every { |t| ((x.(\tremSpread, 0, t) - y).abs < 1) and: { (x.(\tremSpread, 1, t) - y) < -40 } }
            and: { [0.425, 0.675].every { |t| ((x.(\tremSpread, 1, t) - y).abs < 1) and: { (x.(\tremSpread, 0, t) - y) < -40 } } },
        [0.3, 0.425].collect { |t| [x.(\tremSpread, 0, t), x.(\tremSpread, 1, t)].collect { |v| (v - y).round(0.1) } }.asString);

    // Octave Down on a 220 Hz sine, its dry off: 110 Hz, and little 220.
    x = chanOf.(\octave, 0, 0.5, 1.4);
    ok.("Octave Down: a 220 Hz note comes out an octave down, 110 Hz at least 12 dB over 220",
        (goertzel.(x, 110).ampdb - goertzel.(x, 220).ampdb) > 12,
        [goertzel.(x, 110).ampdb.round(0.1), goertzel.(x, 220).ampdb.round(0.1)].asString);
    ok.("...at about the note's level (110 Hz within 12 dB of the input's 220)",
        (goertzel.(x, 110).ampdb - goertzel.(chanOf.(\octave, 1, 0.5, 1.4), 220).ampdb).abs < 12);

    // Ring Mod: 1000 Hz times 300 Hz is 700 and 1300, and no 1000.
    x = chanOf.(\ring, 0, 0.3, 1.3);
    ok.("Ring Mod: 1 kHz times 300 Hz is 700 Hz and 1.3 kHz, each about half the input",
        [700, 1300].every { |f| (goertzel.(x, f).ampdb - (0.25 * 0.5).ampdb).abs < 1 },
        [700, 1300].collect { |f| goertzel.(x, f).ampdb.round(0.1) }.asString);
    ok.("...and no 1 kHz left (fully wet, 40 dB under)", (goertzel.(x, 1000).ampdb - 0.25.ampdb) < -40,
        goertzel.(x, 1000).ampdb.round(0.1).asString);

    [osc, wav].do { |f| if(File.exists(f)) { File.delete(f) } };
    File.delete(tmp);
    "".postln;
    if(fail == 0) { ("NRT TEXTURE PASSED — " ++ pass ++ " checks").postln; 0.exit } {
        ("NRT TEXTURE FAILED — " ++ fail ++ " of " ++ (pass + fail)).postln;
        fails.do { |f| ("  " ++ f).postln };
        1.exit;
    };
};
)
