// megalooper SA — Pitch Loops' feedback, the right voice's LFO and the left
// voice's random distance, heard offline.
//
//     sclang scripts/sa/nrt-pitchloop.scd
//
// One offline render (scsynth -N on a far port; megalooper, if it runs, is
// not touched): six synths, each MegaSAFx.pitchLoop on the same input, wet
// only, each on an output channel of its own. The input is half a second of
// a decaying saw at 0.1 s, then silence, so whatever sounds seconds later
// came round through the feedback.
//
//   0  as megalooper ships it
//   1  Feedback 80 %
//   2  Feedback 90 %, the input ten times as loud
//   3  the right voice's LFO 300 ms deep
//   4  the left voice's random distance up to 100 ms
//   5  as 0 again
//
// The right voice's own random distance is off in all of them: it draws from
// the server's dice, and two synths would not draw alike.
//
// Exits 0 if every check passed, 1 otherwise.
(
var sr = 48000, dur = 10.0, chans = 6;
var tmp = PathName.tmp +/+ "megalooper-nrt-pitchloop-" ++ thisProcess.pid;
var osc = tmp +/+ "pitchloop.osc", wav = tmp +/+ "pitchloop.wav";
var pass = 0, fail = 0, fails = List.new;
var ok = { |label, cond, detail|
    if(cond == true) { pass = pass + 1; ("  ok    " ++ label).postln } {
        fail = fail + 1;
        fails.add(label ++ (detail !? { |d| " — " ++ d } ? ""));
        ("  FAIL  " ++ label ++ (detail !? { |d| " — " ++ d } ? "")).postln;
    };
};
var def = SynthDef(\megaNrtPitchLoop, { |out = 0, level = 0.3|
    var sig = Saw.ar(220) * EnvGen.ar(Env.perc(0.005, 0.5)) * level;
    Out.ar(out, MegaSAFx.pitchLoop(sig));
});
var common = [\pitchLoopMix, 1, \pitchLoopRandR, 0];
var settings = [
    [],
    [\pitchLoopFeedback, 0.8],
    [\pitchLoopFeedback, 0.9, \level, 3.0],
    [\pitchLoopLfoR, 0.3],
    [\pitchLoopRandL, 0.1],
    []
];
var score, cmd, said, sf, data, frames, chan, rmsDb, peak, differ, finite;

File.mkdir(tmp);
score = [[0.0, [\d_recv, def.asBytes]]]
    ++ settings.collect { |s, i| [0.1, [\s_new, \megaNrtPitchLoop, 1001 + i, 0, 0, \out, i] ++ common ++ s] }
    // Every synth freed before the end: scsynth 3.14.1 hangs in its offline
    // cleanup when a synth that owns memory is still running.
    ++ [[dur - 0.05, [\n_free] ++ settings.collect { |s, i| 1001 + i }], [dur, [\c_set, 0, 0]]];
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
    "NRT PITCH LOOPS FAILED — no render".postln;
    1.exit;
} {
    frames = sf.numFrames;
    data = FloatArray.newClear(frames * chans);
    sf.readData(data);
    sf.close;
    // One channel between two times, in seconds.
    chan = { |c, from, to|
        var a = (from * sr).asInteger, b = (to * sr).asInteger.min(frames);
        FloatArray.fill(b - a, { |i| data[((a + i) * chans) + c] })
    };
    rmsDb = { |x| (x.sum { |v| v * v } / x.size.max(1)).sqrt.max(1e-12).ampdb };
    peak = { |x| x.inject(0, { |m, v| m.max(v.abs) }) };
    differ = { |a, b| (a - b).inject(0, { |m, v| m.max(v.abs) }) };
    finite = { |x| x.every { |v| v.isNaN.not and: { v.abs < 1e6 } } };

    "== Pitch Loops, offline ==".postln;
    ok.("every voice is heard: the two pieces of the burst come back", rmsDb.(chan.(0, 0.1, 3)) > -60,
        rmsDb.(chan.(0, 0.1, 3)).round(0.1).asString ++ " dB");
    ok.("with no feedback it is silent once the last piece has played", rmsDb.(chan.(0, 5, 9.5)) < -100,
        rmsDb.(chan.(0, 5, 9.5)).round(0.1).asString ++ " dB");
    ok.("the same settings sound the same, sample for sample", differ.(chan.(0, 0, 9.5), chan.(5, 0, 9.5)) == 0,
        differ.(chan.(0, 0, 9.5), chan.(5, 0, 9.5)).asString);
    ok.("Feedback keeps it sounding: seconds after the burst the voices still come round",
        rmsDb.(chan.(1, 5, 9.5)) > (rmsDb.(chan.(0, 5, 9.5)) + 40),
        rmsDb.(chan.(1, 5, 9.5)).round(0.1).asString ++ " dB against " ++ rmsDb.(chan.(0, 5, 9.5)).round(0.1) ++ " dB");
    // The octave voice closes in on what was just played: its first piece
    // sounds 146 ms in and can read its own return 218 ms in (the render's
    // 0.318 s). Before that the pieces are the same.
    ok.("...and adds to the pieces, never changes them: until the first return can sound, both are alike",
        (differ.(chan.(0, 0.1, 0.31), chan.(1, 0.1, 0.31)) == 0) and: { peak.(chan.(0, 0.1, 0.31)) > 1e-4 },
        [differ.(chan.(0, 0.1, 0.31), chan.(1, 0.1, 0.31)), peak.(chan.(0, 0.1, 0.31))].asString);
    ok.("...dying away at 80 %", rmsDb.(chan.(1, 8, 9.5)) < rmsDb.(chan.(1, 3, 4.5)),
        [rmsDb.(chan.(1, 3, 4.5)), rmsDb.(chan.(1, 8, 9.5))].round(0.1).asString);
    ok.("at 90 % with an input ten times as loud it stays finite and bounded: the returns are softened",
        finite.(chan.(2, 0, 9.5)) and: { peak.(chan.(2, 0, 9.5)) < 8 } and: { rmsDb.(chan.(2, 8, 9.5)) <= (rmsDb.(chan.(2, 3, 4.5)) + 3) },
        [peak.(chan.(2, 0, 9.5)), rmsDb.(chan.(2, 3, 4.5)), rmsDb.(chan.(2, 8, 9.5))].round(0.01).asString);
    ok.("the right voice's LFO moves where its pieces start", differ.(chan.(0, 0.1, 3), chan.(3, 0.1, 3)) > 1e-3,
        differ.(chan.(0, 0.1, 3), chan.(3, 0.1, 3)).asString);
    ok.("the left voice's random distance moves where its pieces start", differ.(chan.(0, 0.1, 3), chan.(4, 0.1, 3)) > 1e-3,
        differ.(chan.(0, 0.1, 3), chan.(4, 0.1, 3)).asString);
    ok.("every render is finite", (0..chans - 1).every { |c| finite.(chan.(c, 0, 9.5)) });

    [osc, wav].do { |f| if(File.exists(f)) { File.delete(f) } };
    File.delete(tmp);
    "".postln;
    if(fail == 0) { ("NRT PITCH LOOPS PASSED — " ++ pass ++ " checks").postln; 0.exit } {
        ("NRT PITCH LOOPS FAILED — " ++ fail ++ " of " ++ (pass + fail)).postln;
        fails.do { |f| ("  " ++ f).postln };
        1.exit;
    };
};
)
