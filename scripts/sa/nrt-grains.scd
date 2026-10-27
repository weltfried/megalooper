// megalooper — the grains following the chords (Looper.granularGraph,
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
// a fourth, the nearer way to D) while it plays D. One render (scsynth -N on a
// far port); exits 0 if every check passed, 1 otherwise.
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
var grainsDef = SynthDef(\nrtGrains, Looper.granularGraph);
var phaseDef = SynthDef(\nrtGrainsPhase, { |out| Out.kr(out, Sweep.kr(0, 1).mod(loopSecs)) });
var a = 220, d = 220 * 5.midiratio, g = 220 * 10.midiratio;
var starts = [0, 1] ++ (1e9 ! (Looper.chordSlots - 2)), roots = [9, 2] ++ (0 ! (Looper.chordSlots - 2));
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
    File.delete(tmp);
    "".postln;
    if(fail == 0) { ("NRT GRAINS PASSED — " ++ pass ++ " checks").postln; 0.exit } {
        ("NRT GRAINS FAILED — " ++ fail ++ " of " ++ (pass + fail)).postln;
        fails.do { |f| ("  " ++ f).postln };
        1.exit;
    };
};
)
