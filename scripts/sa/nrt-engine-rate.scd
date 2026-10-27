// megalooper — the loop engine at other rates than ±1, heard offline.
//
//     sclang scripts/sa/nrt-engine-rate.scd
//
// The engine writes the sample under its write head back on every block,
// recording or not (Looper.prEngineGraph). At rate ±1 every position is a whole
// frame and that write-back is an identity. At half speed each frame is visited
// twice, and a write-back read with linear interpolation would put the average
// of a frame and its neighbour back into it: a half-sample shift and a low-pass
// on every pass. Since 2026-10-27 the write-back reads without interpolation and
// the playback read is cubic; before, both were linear.
//
// One offline render (scsynth -N on a far port; megalooper, if it runs, is not
// touched): ten engines, each on a buffer of its own loaded from the same 0.1 s
// of noise and sine, nothing recording, each on two output channels of its own.
// "old" is the graph as it was, prEngineGraph(false, 2, 2) — but for the write
// head's latency shift, now rounded to whole frames, which is the same number
// at rate ±1 (latencyFrames is whole).
//
//   0 new  rate  1          1 old  rate  1
//   2 new  rate -1          3 old  rate -1
//   4 new  rate  0.5        5 old  rate  0.5
//   6 new  rate  1, latency 7 frames    7 old, the same
//   8 new  rate  0.5, latency 7         9 new  rate -0.5, latency 7
//
// Then half-time as the Looper plays it (docs/dev/rc600-picks.md, 3a): the
// engine's `speed`, set at any time in a pass, takes over on the sample the
// pass ends (a reference Phasor at ±1 wraps there):
//
//  10 new  rate  1, speed 0.5 set 30 ms into the first pass
//  11 new  rate  1, the same, and speed 1 again set in the second half of the
//          half-speed pass: back to rate 1 on the sample that pass ends
//  12 new  rate -1, speed 0.5 set 30 ms into the first pass
//
// Exits 0 if every check passed, 1 otherwise.
(
// The loop is 4803 frames, no whole number of blocks: a wrap falls inside a
// block, where a change of speed taken a block late would show.
var sr = 48000, len = 4803, dur = 1.2, engines = 13, chans = engines * 2;
var tmp = PathName.tmp +/+ "megalooper-nrt-engine-rate-" ++ thisProcess.pid;
var osc = tmp +/+ "engine.osc", wav = tmp +/+ "engine.wav", src = tmp +/+ "loop.wav";
var after = { |i| tmp +/+ "after-" ++ i ++ ".wav" };
var pass = 0, fail = 0, fails = List.new;
var ok = { |label, cond, detail|
    if(cond == true) { pass = pass + 1; ("  ok    " ++ label).postln } {
        fail = fail + 1;
        fails.add(label ++ (detail !? { |d| " — " ++ d } ? ""));
        ("  FAIL  " ++ label ++ (detail !? { |d| " — " ++ d } ? "")).postln;
    };
};
var newDef = SynthDef(\megaNrtEngineNew, Looper.prEngineGraph(false));
var oldDef = SynthDef(\megaNrtEngineOld, Looper.prEngineGraph(false, 2, 2));
// [def, rate, latencyFrames, [[time, speed], ...]] per engine, in the
// table's order. The loop is 0.1 s, the engines start at 0.1 s: 0.13 s is in
// the first pass, 0.35 s in the second half of the half-speed pass after it.
var setups = [
    [\megaNrtEngineNew, 1, 0], [\megaNrtEngineOld, 1, 0],
    [\megaNrtEngineNew, -1, 0], [\megaNrtEngineOld, -1, 0],
    [\megaNrtEngineNew, 0.5, 0], [\megaNrtEngineOld, 0.5, 0],
    [\megaNrtEngineNew, 1, 7], [\megaNrtEngineOld, 1, 7],
    [\megaNrtEngineNew, 0.5, 7], [\megaNrtEngineNew, -0.5, 7],
    [\megaNrtEngineNew, 1, 0, [[0.13, 0.5]]],
    [\megaNrtEngineNew, 1, 0, [[0.13, 0.5], [0.35, 1]]],
    [\megaNrtEngineNew, -1, 0, [[0.13, 0.5]]]
];
// The loop: noise and a sine, made by arithmetic so every run is the same, and
// broadband, so a low-pass would show. Interleaved stereo.
var loop = FloatArray.fill(len * 2, { |j|
    var i = j div: 2, c = j % 2;
    var noise = ((sin((i * 12.9898) + (c * 78.233)) * 43758.5453).frac * 2) - 1;
    (noise * 0.4) + (sin(i * 2pi * (440 + (c * 110)) / sr) * 0.3)
});
var score, cmd, said, sf, data, frames, out, start, buf, played, differ, finite, hiDb;

File.mkdir(tmp);
sf = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(2).sampleRate_(sr);
sf.openWrite(src);
sf.writeData(loop);
sf.close;

score = [[0.0, [\d_recv, newDef.asBytes]], [0.0, [\d_recv, oldDef.asBytes]]]
    ++ setups.collect { |s, i| [0.0, [\b_allocRead, i, src]] }
    ++ setups.collect { |s, i|
        [0.1, [\s_new, s[0], 1000 + i, 1, 0,
            \bufnum, i, \in, 0, \startFrame, 0, \loopFrames, len, \out, i * 2,
            \rate, s[1], \latencyFrames, s[2], \declickFrames, 0,
            \phaseBus, i, \gateBus, 100]] }
    ++ setups.collect { |s, i| (s[3] ? []).collect { |e| [e[0], [\n_set, 1000 + i, \speed, e[1]]] } }.flatten(1)
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
    "NRT ENGINE RATE FAILED — no render".postln;
    1.exit;
} {
    frames = sf.numFrames;
    data = FloatArray.newClear(frames * chans);
    sf.readData(data);
    sf.close;
    // Engine e's channel c (0 left, 1 right) at render frame f.
    out = { |e, c, f| data[(f * chans) + (e * 2) + c] };
    // The loop's channel c at frame i, i taken round the loop.
    buf = { |c, i| loop[(i.mod(len) * 2) + c] };
    // Where engine 0 started: the render frame at which it plays the loop's
    // frame 1 one frame after its start. The engines start together.
    start = (4800 - 128, 4800 - 64 .. 4800 + 128).detect { |s|
        (1..200).every { |t| out.(0, 0, s + t) == buf.(0, t) }
    };
    // Frames the engines were playing, all of them whole.
    played = ((dur - 0.1 - 0.1) * sr).asInteger - 64;
    differ = { |a, b, ca, cb| (0 .. played - 1).inject(0, { |m, t|
        m.max((out.(a, ca, start + t) - out.(b, cb, start + t)).abs) }) };
    finite = { |e| (0 .. frames - 1).every { |f| out.(e, 0, f).isNaN.not and: { out.(e, 1, f).isNaN.not } } };
    // The loop's high end: the RMS of its first difference, in dB.
    hiDb = { |x| (((1 .. len - 1).sum { |i| (x[i * 2] - x[(i - 1) * 2]).squared }) / (len - 1)).sqrt.max(1e-12).ampdb };

    "== the loop engine at other rates, offline ==".postln;
    ok.("the render found where the engines start", start.notNil, "no start within two blocks of 0.1 s");
    if(start.notNil) {
        ok.("rate 1: every frame of the loop played as it is, both channels (but frame 0, the seam's declick)",
            (0 .. played - 1).every { |t| (t.mod(len) == 0) or: {
                (out.(0, 0, start + t) == buf.(0, t)) and: { out.(0, 1, start + t) == buf.(1, t) } } });
        ok.("rate 1: the new engine sounds as the old did, sample for sample",
            (differ.(0, 1, 0, 0) == 0) and: { differ.(0, 1, 1, 1) == 0 },
            [differ.(0, 1, 0, 0), differ.(0, 1, 1, 1)].asString);
        ok.("rate -1: the loop played backwards, frame for frame (but the seam)",
            (0 .. played - 1).every { |t| (t.mod(len) == 0) or: {
                (out.(2, 0, start + t) == buf.(0, t.neg)) and: { out.(2, 1, start + t) == buf.(1, t.neg) } } });
        ok.("rate -1: the new engine sounds as the old did",
            (differ.(2, 3, 0, 0) == 0) and: { differ.(2, 3, 1, 1) == 0 },
            [differ.(2, 3, 0, 0), differ.(2, 3, 1, 1)].asString);
        ok.("rate 1 with an odd latency: the new engine sounds as the old did",
            (differ.(6, 7, 0, 0) == 0) and: { differ.(6, 7, 1, 1) == 0 },
            [differ.(6, 7, 0, 0), differ.(6, 7, 1, 1)].asString);
        ok.("rate 0.5: every other sample is the loop's frame itself (cubic at a whole frame)",
            (0 .. (played div: 2) - 1).every { |k| (k.mod(len) == 0) or: {
                (out.(4, 0, start + (k * 2)) == buf.(0, k)) and: { out.(4, 1, start + (k * 2)) == buf.(1, k) } } });
        // Half-time: e plays frame `at.(t)` of the loop `t` frames after its start.
        {
            // The first frame `t` where e doesn't play `at.(t)`, or nil.
            var miss = { |e, from, to, at| (from .. to - 1).detect { |t| var k = at.(t);
                k.notNil and: { (out.(e, 0, start + t) != buf.(0, k)) or: { out.(e, 1, start + t) != buf.(1, k) } } } };
            var plays = { |e, from, to, at| miss.(e, from, to, at).isNil };
            // Whole frames only, and not the seam's declick.
            var whole = { |x| if((x.frac == 0) and: { x.mod(len) != 0 }) { x } };
            ok.("half-time set 30 ms into a pass: rate 1 to the pass's end, every frame",
                plays.(10, 0, len, { |t| whole.(t) }));
            ok.("...then half speed from the sample the loop starts again: every other sample its frame, for two passes",
                plays.(10, len, len * 5, { |t| whole.((t - len) / 2) }));
            ok.("a release set in the second half of the half-speed pass: back to rate 1 on the sample that pass ends",
                plays.(11, len, len * 3, { |t| whole.((t - len) / 2) }) and: { plays.(11, len * 3, len * 6, { |t| whole.(t) }) });
            // Backwards a pass begins a sample after frame 0, on frame L - 1:
            // the half-speed pass starts there, on the sample the reference
            // wraps.
            ok.("reversed, half-time lands where a pass begins backwards, on frame L - 1, all the same",
                plays.(12, 0, len + 1, { |t| whole.(t.neg) })
                    and: { plays.(12, len + 1, len * 5, { |t| whole.((((t - len) - 1) / 2 + 1).neg) }) },
                [miss.(12, 0, len + 1, { |t| whole.(t.neg) }),
                    miss.(12, len + 1, len * 5, { |t| whole.((((t - len) - 1) / 2 + 1).neg) })] !? { |m|
                    m.collect { |t| t !? { "frame " ++ t ++ " plays " ++ out.(12, 0, start + t) ++ ", loop frames around: "
                        ++ (-3..3).collect { |d| [((t - len) - 1) / 2 + 1 + d, buf.(0, (((t - len) - 1) / 2 + 1 + d).neg.floor)] } } }.asString });
        }.value;
    };
    // What the engines left in their buffers.
    setups.do { |s, i|
        var f = SoundFile.openRead(after.(i)), got, diff, name;
        name = (if(s[0] == \megaNrtEngineNew) { "new" } { "old" }) ++ " engine at rate " ++ s[1]
            ++ (if(s[2] != 0) { ", latency " ++ s[2] } { "" })
            ++ (s[3] !? { |ev| ", speed " ++ ev.collect { |e| e[1] }.join(" then ") } ? "");
        if(f.isNil) { ok.(name ++ ": its buffer was written", false) } {
            got = FloatArray.newClear(f.numFrames * f.numChannels);
            f.readData(got);
            f.close;
            diff = if(got.size != loop.size) { inf } { (got - loop).abs.maxItem };
            if((s[0] == \megaNrtEngineOld) and: { s[1].abs != 1 }) {
                ok.(name ++ ": the check catches the old write-back — the loop came out changed, its high end "
                    ++ (hiDb.(loop) - hiDb.(got)).round(0.1) ++ " dB down",
                    (diff > 1e-3) and: { hiDb.(got) < (hiDb.(loop) - 0.5) },
                    "largest change " ++ diff);
            } {
                ok.(name ++ ": the loop came out " ++ (if(s[3].isNil) {
                        "of " ++ ((dur - 0.2) * s[1].abs / (len / sr)).round(0.1) ++ " passes " } { "" })
                    ++ "exactly as it went in", diff == 0, "largest change " ++ diff);
            };
        };
    };
    ok.("every render is finite", (0 .. engines - 1).every { |e| finite.(e) });

    ([osc, wav, src] ++ setups.collect { |s, i| after.(i) }).do { |f| if(File.exists(f)) { File.delete(f) } };
    File.delete(tmp);
    "".postln;
    if(fail == 0) { ("NRT ENGINE RATE PASSED — " ++ pass ++ " checks").postln; 0.exit } {
        ("NRT ENGINE RATE FAILED — " ++ fail ++ " of " ++ (pass + fail)).postln;
        fails.do { |f| ("  " ++ f).postln };
        1.exit;
    };
};
)
