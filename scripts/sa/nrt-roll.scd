// megalooper — a roll that halves, in the engine and the drums' roller, heard
// offline (roadmap item 24, idea 7; docs/dev/sampler.md; LooperSynthDefs.rollOf,
// rollerGraph).
//
//     sclang scripts/sa/nrt-roll.scd
//
// One offline render (scsynth -N on a far port; megalooper, if it runs, is not
// touched): engines on buffers of their own loaded from the same loop (24007
// frames, plucks over noise), each on two output channels of its own; and a
// drums' roller on two private buses fed by a second signal (clicks), tapped
// to two outputs each. "old" is the graph without the notes and the roll,
// engineGraph(false, 4, 1, false).
//
//   engine 0 new, never armed, its playhead published on a bus   1 old
//   engine 2 new, a landing armed with no roll (fades nothing)
//   engine 3 new, the roll: armed for frame 4000 of the second pass, a window
//            of 4800, then 1200 (sent mid-window, taken on its next multiple),
//            then 300; landing armed for frame 993 of the third pass (across
//            the loop's seam)
//   the roller on engine 3's playhead: the same, its anchor 200 frames before
//   (the grid's point, the hit's front); and a roller never armed
//
// Exits 0 if every check passed, 1 otherwise.
(
var sr = 48000, len = 24007, dur = 1.8, chans = 12;
var tmp = PathName.tmp +/+ "megalooper-nrt-roll-" ++ thisProcess.pid;
var osc = tmp +/+ "roll.osc", wav = tmp +/+ "roll.wav", src = tmp +/+ "loop.wav", clk = tmp +/+ "clicks.wav";
var pass = 0, fail = 0, fails = List.new;
var ok = { |label, cond, detail|
    if(cond == true) { pass = pass + 1; ("  ok    " ++ label).postln } {
        fail = fail + 1;
        fails.add(label ++ (detail !? { |d| " — " ++ d } ? ""));
        ("  FAIL  " ++ label ++ (detail !? { |d| " — " ++ d } ? "")).postln;
    };
};
var newDef = SynthDef(\megaNrtRollNew, LooperSynthDefs.engineGraph(false));
var oldDef = SynthDef(\megaNrtRollOld, LooperSynthDefs.engineGraph(false, 4, 1, false));
var rollerDef = SynthDef(\megaNrtRoller, LooperSynthDefs.rollerGraph);
var srcDef = SynthDef(\megaNrtRollSrc, { |buf, out| Out.ar(out, PlayBuf.ar(2, buf, loop: 1)) });
var tapDef = SynthDef(\megaNrtRollTap, { |in, out| Out.ar(out, In.ar(in, 2)) });
// The landing is in the third pass, after the last switch: across the seam.
var anchor = 4000, landAt = 993, w0 = 4800, w1 = 1200, w2 = 300, dAnchor = 3800, dLand = 793;
var loop = FloatArray.fill(len * 2, { |j|
    var i = j div: 2, c = j % 2, x;
    x = ((((sin((i * 12.9898) + (c * 78.233)) * 43758.5453).frac * 2) - 1) * 0.02);
    [1500, 5003, 9013, 13000, 17500, 21020].do { |s, k|
        var d = (i - s).mod(len);
        x = x + (sin(d * 2pi * (220 + (k * 55) + (c * 3)) / sr) * 0.5 * exp(d.neg / (0.05 * sr)) * (d / 48).min(1));
    };
    x
});
// The drums: a click every 600 frames, a different one each, stereo.
var clicks = FloatArray.fill(len * 2, { |j| var i = j div: 2; if((i % 600) < 24) { ((i div: 600) % 7 + 1) * 0.1 * (1 - ((i % 600) / 24)) } { 0.0 } });
var score, cmd, said, sf, data, frames, out, start, buf, drum, miss, report, t0, passStart;

File.mkdir(tmp);
[[src, loop], [clk, clicks]].do { |fd|
    sf = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(2).sampleRate_(sr);
    sf.openWrite(fd[0]); sf.writeData(fd[1]); sf.close;
};

// Engines start at 0.1 s; the second pass from 0.1 + len / sr (0.6 s).
passStart = 0.1 + (len / sr);
score = [[0.0, [\d_recv, newDef.asBytes]], [0.0, [\d_recv, oldDef.asBytes]], [0.0, [\d_recv, rollerDef.asBytes]],
        [0.0, [\d_recv, srcDef.asBytes]], [0.0, [\d_recv, tapDef.asBytes]]]
    ++ (0 .. 3).collect { |i| [0.0, [\b_allocRead, i, src]] }
    ++ [[0.0, [\b_allocRead, 10, clk]], [0.0, [\b_alloc, 11, sr * 2, 2]], [0.0, [\b_alloc, 12, sr * 2, 2]],
        [0.0, [\b_alloc, 13, sr * 2, 2]], [0.0, [\b_alloc, 14, sr * 2, 2]]]
    ++ [[\megaNrtRollNew, 0, [\posBus, 60]], [\megaNrtRollOld, 1, []], [\megaNrtRollNew, 2, []], [\megaNrtRollNew, 3, [\posBus, 40]]]
        .collect { |e|
            [0.1, [\s_new, e[0], 1000 + e[1], 1, 0, \bufnum, e[1], \in, 0, \startFrame, 0, \loopFrames, len, \out, e[1] * 2,
                \rate, 1, \latencyFrames, 0, \declickFrames, 0, \phaseBus, e[1], \gateBus, 100] ++ e[2]] }
    // The drums: clicks on buses 50 and 52, the rollers after, the taps last.
    ++ [[0.1, [\s_new, \megaNrtRollSrc, 1100, 1, 0, \buf, 10, \out, 50]],
        [0.1, [\s_new, \megaNrtRollSrc, 1101, 1, 0, \buf, 10, \out, 52]],
        [0.1, [\s_new, \megaNrtRollSrc, 1102, 1, 0, \buf, 10, \out, 54]],
        [0.1, [\s_new, \megaNrtRoller, 1200, 1, 0, \inA, 50, \inB, 52, \posBus, 40, \capA, 11, \capB, 12]],
        [0.1, [\s_new, \megaNrtRoller, 1201, 1, 0, \inA, 54, \inB, 56, \posBus, 60, \capA, 13, \capB, 14]],
        [0.1, [\s_new, \megaNrtRollTap, 1300, 1, 0, \in, 50, \out, 8]],
        [0.1, [\s_new, \megaNrtRollTap, 1301, 1, 0, \in, 54, \out, 10]]]
    // Engine 2: a landing armed with no roll.
    ++ [[0.2, [\n_set, 1002, \rollLand, 1, \rollLandAt, 8000]]]
    // Engine 3 and roller 1200: armed in the first pass, disarmed once begun;
    // the windows sent mid-window; landing armed before it.
    ++ [[0.3, [\n_set, 1003, \rollArm, 1, \rollAnchor, anchor, \rollWin, w0]],
        [0.3, [\n_set, 1200, \rollArm, 1, \rollAnchor, dAnchor, \rollWin, w0]],
        [passStart + ((anchor + 600) / sr), [\n_set, 1003, \rollArm, 0], [\n_set, 1200, \rollArm, 0]],
        [passStart + ((anchor + (2 * w0) + 2000) / sr), [\n_set, 1003, \rollWin, w1], [\n_set, 1200, \rollWin, w1]],
        [passStart + ((anchor + (4 * w0) + 450) / sr), [\n_set, 1003, \rollWin, w2], [\n_set, 1200, \rollWin, w2]],
        [passStart + ((len + landAt - 1500) / sr), [\n_set, 1003, \rollLand, 1, \rollLandAt, landAt],
            [\n_set, 1200, \rollLand, 1, \rollLandAt, dLand]]]
    ++ [[dur - 0.1, [\n_free, 1000, 1001, 1002, 1003, 1100, 1101, 1102, 1200, 1201, 1300, 1301]], [dur, [\c_set, 0, 0]]];
Score(score).writeOSCFile(osc);
cmd = "perl -e 'alarm shift; exec @ARGV' 120 " ++ MegaSAPlugins.scsynthPath.shellQuote ++ " -u " ++ (58500 + 200.rand)
    ++ " -m 65536 -N " ++ osc.shellQuote ++ " _ " ++ wav.shellQuote ++ " " ++ sr ++ " WAV float -o " ++ chans ++ " -i 0 2>&1";
said = cmd.unixCmdGetStdOut;
sf = SoundFile.openRead(wav);
if(sf.isNil or: { sf.numFrames < ((dur - 0.2) * sr) }) {
    ("  FAIL  the render: " ++ said.split($\n).reject(_.isEmpty).keep(-4).join(" | ")).postln;
    sf !? { |f| f.close };
    "NRT ROLL FAILED — no render".postln;
    1.exit;
};
frames = sf.numFrames;
data = FloatArray.newClear(frames * chans);
sf.readData(data);
sf.close;
[osc, wav, src, clk].do { |f| if(File.exists(f)) { File.delete(f) } };
File.delete(tmp);

// Channel pair p's channel c at frame t after the engines started.
out = { |p, c, t| data[((start + t) * chans) + (p * 2) + c] };
buf = { |c, i| loop[(i.mod(len) * 2) + c] };
drum = { |c, i| clicks[(i.mod(len) * 2) + c] };
start = (4800 - 128, 4800 - 64 .. 4800 + 128).detect { |s0| (1..200).every { |t| data[((s0 + t) * chans) + 2] == buf.(0, t) } };
miss = { |p, from, to, want, keep, tol = 1e-6|
    var bad, w, t = from;
    while { bad.isNil and: { t < to } } {
        if(keep.isNil or: { keep.(t) }) {
            w = want.(t);
            if(((out.(p, 0, t) - w[0]).abs > tol) or: { (out.(p, 1, t) - w[1]).abs > tol }) { bad = t };
        };
        t = t + 1;
    };
    bad !? { |b| [b, out.(p, 0, b), want.(b)[0]] }
};
report = { |m| m !? { |x| "at frame " ++ x[0] ++ ": " ++ x[1] ++ ", want " ++ x[2] } };

"== a roll that halves, offline ==".postln;
ok.("the render found where the engines start", start.notNil);
if(start.notNil) {
    {
        var played = ((dur - 0.2) * sr).asInteger - 128, edge = (LooperSynthDefs.rollEdge * sr).ceil.asInteger + 1;
        var a = len + anchor, sLand = (2 * len) + landAt;
        // Where the windows switch: the first multiple of each after it was sent.
        var s1 = ((((len + anchor + (2 * w0) + 2000) - a) / w1).roundUp * w1) + a;
        var s2 = ((((len + anchor + (4 * w0) + 450) - a) / w2).roundUp * w2) + a;
        // The roll's read at frame t: the anchor plus where t is in its window.
        var readAt = { |t| case
            { t < s1 } { anchor + ((t - a) % w0) }
            { t < s2 } { anchor + ((t - a) % w1) }
            { anchor + ((t - a) % w2) } };
        var inner = { |t, w0x, from| var o = (t - from) % w0x; (o >= edge) and: { o < (w0x - edge) } };

        ok.("never armed: the new engine sounds as the old, sample for sample (its playhead on a bus)",
            miss.(0, 0, played, { |t| [out.(1, 0, t), out.(1, 1, t)] }, nil, 0).isNil,
            report.(miss.(0, 0, played, { |t| [out.(1, 0, t), out.(1, 1, t)] }, nil, 0)));
        ok.("a landing armed with no roll fades nothing", miss.(2, 0, played, { |t| [out.(1, 0, t), out.(1, 1, t)] }, nil, 0).isNil,
            report.(miss.(2, 0, played, { |t| [out.(1, 0, t), out.(1, 1, t)] }, nil, 0)));

        ok.("armed in the first pass: that pass and the second up to the anchor as played",
            miss.(3, 1, a, { |t| [buf.(0, t), buf.(1, t)] }, { |t| t.mod(len) != 0 }).isNil,
            report.(miss.(3, 1, a, { |t| [buf.(0, t), buf.(1, t)] }, { |t| t.mod(len) != 0 })));
        ok.("the first window is the loop as it plays (no seam at the start)",
            miss.(3, a + edge, a + w0 - edge, { |t| [buf.(0, t), buf.(1, t)] }).isNil);
        ok.("then the window again and again (a group held)",
            miss.(3, a + w0, s1, { |t| var r = readAt.(t); [buf.(0, r), buf.(1, r)] }, { |t| inner.(t, w0, a) }).isNil,
            report.(miss.(3, a + w0, s1, { |t| var r = readAt.(t); [buf.(0, r), buf.(1, r)] }, { |t| inner.(t, w0, a) })));
        ok.("a window of 1200 sent mid-window: taken on its next multiple from the start, " ++ (s1 - a) ++ " frames in",
            miss.(3, s1, s2, { |t| var r = readAt.(t); [buf.(0, r), buf.(1, r)] }, { |t| inner.(t, w1, a) }).isNil,
            report.(miss.(3, s1, s2, { |t| var r = readAt.(t); [buf.(0, r), buf.(1, r)] }, { |t| inner.(t, w1, a) })));
        ok.("...then 300, likewise",
            miss.(3, s2, sLand - edge, { |t| var r = readAt.(t); [buf.(0, r), buf.(1, r)] }, { |t| inner.(t, w2, a) }).isNil,
            report.(miss.(3, s2, sLand - edge, { |t| var r = readAt.(t); [buf.(0, r), buf.(1, r)] }, { |t| inner.(t, w2, a) })));
        ok.("...each window's edges faded to silence", [a + w0, s1, s2, s2 + w2].every { |t| out.(3, 0, t) == 0 },
            [a + w0, s1, s2, s2 + w2].collect { |t| out.(3, 0, t) }.asString);
        ok.("the landing: silent on its frame (faded out before it)", out.(3, 0, sLand) == 0, out.(3, 0, sLand).asString);
        ok.("...then the loop where it would have been, every frame, to the end",
            miss.(3, sLand + edge, played, { |t| [buf.(0, t), buf.(1, t)] }, { |t| t.mod(len) != 0 }).isNil,
            report.(miss.(3, sLand + edge, played, { |t| [buf.(0, t), buf.(1, t)] }, { |t| t.mod(len) != 0 })));

        // The drums' roller, on engine 3's playhead, its anchor 200 earlier.
        {
            var da = len + dAnchor, dsLand = (2 * len) + dLand;
            var ds1 = ((((len + anchor + (2 * w0) + 2000) - da) / w1).roundUp * w1) + da;
            var ds2 = ((((len + anchor + (4 * w0) + 450) - da) / w2).roundUp * w2) + da;
            var dread = { |t| case { t < ds1 } { (t - da) % w0 } { t < ds2 } { (t - da) % w1 } { (t - da) % w2 } };
            ok.("the drums never armed: handed on as they are",
                miss.(5, 0, played, { |t| [drum.(0, t), drum.(1, t)] }).isNil,
                report.(miss.(5, 0, played, { |t| [drum.(0, t), drum.(1, t)] })));
            ok.("the drums rolled: as they play up to their anchor and through their first window",
                miss.(4, 0, da + w0 - edge, { |t| [drum.(0, t), drum.(1, t)] }, { |t| (t < da) or: { (t - da) >= edge } }).isNil,
                report.(miss.(4, 0, da + w0 - edge, { |t| [drum.(0, t), drum.(1, t)] }, { |t| (t < da) or: { (t - da) >= edge } })));
            ok.("...then that window again, halving as the loop's does, from their own anchor",
                miss.(4, da + w0, dsLand - edge, { |t| var r = da + dread.(t); [drum.(0, r), drum.(1, r)] },
                    { |t| case { t < ds1 } { inner.(t, w0, da) } { t < ds2 } { inner.(t, w1, da) } { inner.(t, w2, da) } }).isNil,
                report.(miss.(4, da + w0, dsLand - edge, { |t| var r = da + dread.(t); [drum.(0, r), drum.(1, r)] },
                    { |t| case { t < ds1 } { inner.(t, w0, da) } { t < ds2 } { inner.(t, w1, da) } { inner.(t, w2, da) } })));
            ok.("...and landing on theirs: the drums as they play, to the end",
                miss.(4, dsLand + edge, played, { |t| [drum.(0, t), drum.(1, t)] }).isNil,
                report.(miss.(4, dsLand + edge, played, { |t| [drum.(0, t), drum.(1, t)] })));
        }.value;
    }.value;
};
ok.("every render is finite", (0 .. frames - 1).every { |f| (0 .. chans - 1).every { |c| data[(f * chans) + c].isNaN.not } });
"".postln;
if(fail == 0) { ("NRT ROLL PASSED — " ++ pass ++ " checks").postln; 0.exit } {
    ("NRT ROLL FAILED — " ++ fail ++ " of " ++ (pass + fail)).postln;
    fails.do { |f| ("  " ++ f).postln };
    1.exit;
};
)
