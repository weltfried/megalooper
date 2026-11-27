// megalooper — the loop as a sampler, an experiment (roadmap item 24; the
// plan in docs/dev/sampler.md): a recorded take cut into slices at its own
// onsets, and the first two things a sampler does with slices. Rendered
// before anything was built (2026-11-27, on a graph of its own, which the
// duo heard and chose from: "both are great"); since then through the
// engine as built.
//
//   1a-gate     legato to staccato: each note held, then cut with a short
//               fade; the pedal (a ramp here) shortens how long it is held
//   1b-decay    the same with a decay instead of a gate: each note fades from
//               its attack, faster as the pedal goes down, as a damped string
//   2-reverse   each note reversed in its own slot: two loops as played, then
//               reversed (armed to the loop's boundary, as Reverse is), then
//               as played again
//   2-reverse-raw  the same, cut where the detector reported each onset
//               rather than where the attack starts: what the slices would be
//               without the search
//   3-retrograde  Notes backwards with Reverse: the loop backwards, each note
//               forwards, the riff played backwards note by note
//
// The ramp for 1: a pass or so as played, then three passes of the pedal going
// down, one at the bottom, two coming back up, one as played. A unit is the
// fewest whole passes that last 8 s.
//
// The slices: the take's onsets (the set's log, as the onset notes replay
// them), each moved to where its attack really starts in the loop's audio
// (LoopSlices.attackStarts: the detector reports an attack late, and the
// loop's audio sits a chain's latency away from the tap). The table prints
// how far each one moved.
//
// The loop is one pass of the set's loop stem (`pass`, counted from 0 at the
// press: 1 by default), the drums the same stretch of the drums stem, both
// played round. Each render comes as the loop with the drums, and the loop
// alone (-loop).
//
//     sclang scripts/sampler-experiment.scd <set stamp> <out dir> [<take> <pass>]
//
// The take counts from 1 (default 1). One offline render each (scsynth -N on
// a far port); nothing touches a running megalooper.
(
var stamp = thisProcess.argv[0], outDir = thisProcess.argv[1];
var takeNo = (thisProcess.argv[2] ? "1").asInteger, passNo = (thisProcess.argv[3] ? "1").asInteger;
var root = thisProcess.nowExecutingPath.dirname.dirname, sessions = root +/+ "sessions";
var sr = 48000, eventsPath, events, audio0, files, take, play, loopDur, loopFrames, fromFrame, tau, result;
var paths = (), loopData, drumData, mono, n, found;
var onsets, raw, table, unit, total, tmp, engineDef, rampDef, mixDef, render, rmsOver, peakDb, report;
var readPass, fmtMs;
var watchdog;
if(stamp.isNil or: { outDir.isNil }) {
    "usage: sclang scripts/sampler-experiment.scd <set stamp> <out dir> [<take> <pass>]".postln;
    1.exit;
};
// A runtime error stops the script but not sclang (it idles): out after 10 min.
watchdog = Routine { 600.wait; "sampler experiment: timed out".postln; 1.exit }.play(AppClock);
eventsPath = (sessions +/+ stamp ++ "*-events.jsonl").pathMatch.first;
events = File.readAllString(eventsPath).split($\n).reject { |x| x.isEmpty or: { x.contains("\"ev\": \"hit\"") } }
    .collect { |x| MegaRemote.plain(MegaFiles.parseObject(x)) };
audio0 = (events.detect { |e| e[\ev] == "audio" } !? { |e| e[\t] }) ? 0;
files = events.detect { |e| e[\ev] == "files" } !? { |e| e[\files] };
[\loop, \drums].do { |k| paths[k] = eventsPath.dirname +/+ files[k] };
take = events.select { |e| e[\ev] == "take" }[takeNo - 1];
play = take[\play] ? take[\t];
loopDur = take[\loopDur];
loopFrames = (loopDur * sr).round.asInteger;
result = take[\result];
tau = result[\tau] * (result[\sub] ? 1);
fromFrame = ((play + (passNo * loopDur) - audio0) * sr).round.asInteger;
("take " ++ takeNo ++ ": " ++ result[\numerator] ++ "/" ++ result[\denominator] ++ " at "
    ++ result[\bpm].round(0.1) ++ " BPM, pulse " ++ (tau * 1000).round(0.1) ++ " ms, a loop of "
    ++ loopDur.round(0.001) ++ " s, pass " ++ passNo ++ " from " ++ (fromFrame / sr).round(0.01) ++ " s in the stems").postln;

// One pass of a stem, stereo, as a FloatArray (a mono stem doubled).
readPass = { |path|
    var sf = SoundFile.openRead(path), c, data, out;
    c = sf.numChannels;
    sf.seek(fromFrame, 0);
    data = FloatArray.newClear(loopFrames * c);
    sf.readData(data);
    sf.close;
    if(c == 2) { data } {
        out = FloatArray.newClear(loopFrames * 2);
        loopFrames.do { |f| out[f * 2] = data[f]; out[(f * 2) + 1] = data[f] };
        out
    }
};
loopData = readPass.(paths[\loop]);
drumData = readPass.(paths[\drums]);

// The take's onsets as the onset notes replay them: from the press, within
// the loop; and where each attack really starts in the loop's audio
// (LoopSlices.attackStarts, as a take would have it).
n = loopFrames;
onsets = (take[\onsets] ? []).select { |p| (p[0] >= 0) and: { p[0] < loopDur } };
raw = onsets.collect { |p| (p[0] * sr).round.asInteger };
mono = LoopSlices.monoOf(loopData, 2);
found = LoopSlices.attackStarts(mono, sr, raw);
("the loop's audio sits " ++ (found[\offset] / sr * 1000).round(0.1) ++ " ms from the reported onsets; "
    ++ found[\found].count(_.value) ++ " of " ++ raw.size ++ " attacks found, the rest take that distance").postln;
fmtMs = { |frames| (frames / sr * 1000).round(0.1) };
"the onsets (ms from the press; moved = where the attack starts against where it was reported):".postln;
onsets.do { |p, i|
    ("  " ++ (i + 1) ++ "  reported " ++ fmtMs.(raw[i]) ++ "  moved " ++ fmtMs.(found[\moved][i])
        ++ (if(found[\found][i]) { "" } { " (no attack found: the distance)" })
        ++ "  strength " ++ p[1].round(0.001)).postln;
};
table = (raw: LoopSlices.table(LoopSlices.merged(raw, n, 0), n), refined: LoopSlices.table(found[\starts], n));
("  " ++ (table[\refined].size - 4) ++ " slices, " ++ (loopDur / (table[\refined].size - 4) / tau).round(0.01)
    ++ " pulses each on average").postln;

unit = (8 / loopDur).roundUp.max(1).asInteger;
File.mkdir(outDir);
// The slices' starts, frames into the loop, one a line (refined, then raw),
// for checking the renders against.
File.use(outDir +/+ "slices.txt", "w", { |f|
    f.write("refined " ++ table[\refined].copyRange(2, table[\refined].size - 3).join(" ") ++ "\n");
    f.write("raw " ++ table[\raw].copyRange(2, table[\raw].size - 3).join(" ") ++ "\n");
    f.write("loopFrames " ++ loopFrames ++ " unit " ++ unit ++ "\n");
});
tmp = PathName.tmp +/+ "megalooper-sampler-" ++ thisProcess.pid;
File.mkdir(tmp);
File.mkdir(outDir);
// The two passes as files for the renders to read.
[["loop.wav", loopData], ["drums.wav", drumData]].do { |fd|
    var out = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(2).sampleRate_(sr);
    out.openWrite(tmp +/+ fd[0]);
    out.writeData(fd[1]);
    out.close;
};

// The renders play the loop through megalooper's own engine
// (LooperSynthDefs.engineGraph, the loop's notes in LooperSynthDefs.noteSlices)
// on buffer 0 (a pass), its slice table in buffer 2, its output on bus 20, as
// the app plays it: Staccato's pedal a ramp on control bus 0 mapped to the
// engine's noteLen, Notes backwards and Reverse sent half a pass before the
// boundary they land on. The drums (buffer 1, the same stretch) are mixed in
// after it. Out 0-1 the loop with the drums, 2-3 the loop.
engineDef = SynthDef(\smEngine, LooperSynthDefs.engineGraph(false));
rampDef = SynthDef(\smRamp, { |times = #[1, 1, 1, 1, 1]| Out.kr(0, EnvGen.kr(Env([0, 0, 1, 1, 0, 0], times))) });
mixDef = SynthDef(\smMix, {
    var loop = In.ar(20, 2), drums = PlayBuf.ar(2, 1, loop: 1);
    Out.ar(0, Limiter.ar(loop + drums, 0.97, 0.01));
    Out.ar(2, loop);
});

// One render: <name>.wav and <name>-loop.wav; answers the loop alone (mono, a
// FloatArray) for measuring.
// `ramp`: Staccato's ramp, [the times of its five segments], or nil; `args`
// the engine's own; `sets` [[time, [control, value, ...]], ...] for it.
render = { |name, tbl, args, sets, dur, ramp|
    var osc = tmp +/+ name ++ ".osc", wav = tmp +/+ name ++ ".wav", sf, data, said, alone, score, padded;
    padded = LoopSlices.padded(tbl);
    score = [
        [0.0, [\d_recv, engineDef.asBytes]], [0.0, [\d_recv, rampDef.asBytes]], [0.0, [\d_recv, mixDef.asBytes]],
        [0.0, [\b_allocRead, 0, tmp +/+ "loop.wav"]],
        [0.0, [\b_allocRead, 1, tmp +/+ "drums.wav"]],
        [0.0, [\b_alloc, 2, padded.size, 1]],
        [0.0, [\b_setn, 2, 0, padded.size] ++ padded],
        [0.0, [\s_new, \smRamp, 999, 0, 0, \times, ramp ? [1, 1, 1, 1, 1]].asOSCArgArray],
        [0.0, [\s_new, \smEngine, 1000, 3, 999, \bufnum, 0, \in, 0, \startFrame, 0, \loopFrames, loopFrames,
            \out, 20, \rate, 1, \declickFrames, (0.003 * sr).round, \phaseBus, 1, \gateBus, 100,
            \sliceBuf, 2, \slicesOn, 1, \tauFrames, tau * sr] ++ args.asOSCArgArray],
        [0.0, [\s_new, \smMix, 1001, 3, 1000]]
    ] ++ (if(ramp.notNil) { [[0.0, [\n_map, 1000, \noteLen, 0]]] } { [] })
    ++ sets.collect { |s| [s[0], [\n_set, 1000] ++ s[1]] } ++ [
        [dur - 0.01, [\n_free, 999, 1000, 1001]],
        [dur, [\c_set, 0, 0]]
    ];
    Score(score).writeOSCFile(osc);
    said = ("perl -e 'alarm shift; exec @ARGV' 600 " ++ MegaSAPlugins.scsynthPath.shellQuote ++ " -u " ++ (58800 + 150.rand)
        ++ " -m 262144 -N " ++ osc.shellQuote ++ " _ " ++ wav.shellQuote ++ " " ++ sr ++ " WAV float -o 4 -i 0 2>&1").unixCmdGetStdOut;
    sf = SoundFile.openRead(wav);
    if(sf.isNil) { ("  " ++ name ++ " did not render: " ++ said.split($\n).reject(_.isEmpty).keep(-3).join(" | ")).postln; 1.exit };
    data = FloatArray.newClear(sf.numFrames * 4);
    sf.readData(data);
    sf.close;
    [[name, 0], [name ++ "-loop", 2]].do { |o|
        var out = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(2).sampleRate_(sr);
        var xs = FloatArray.newClear(sf.numFrames * 2);
        sf.numFrames.do { |f| xs[f * 2] = data[(f * 4) + o[1]]; xs[(f * 2) + 1] = data[(f * 4) + o[1] + 1] };
        out.openWrite(outDir +/+ o[0] ++ ".wav");
        out.writeData(xs);
        out.close;
    };
    alone = FloatArray.newClear(sf.numFrames);
    sf.numFrames.do { |f| alone[f] = (data[(f * 4) + 2] + data[(f * 4) + 3]) * 0.5 };
    File.delete(osc); File.delete(wav);
    ("  wrote " ++ (outDir +/+ name) ++ ".wav and -loop.wav (" ++ dur.round(0.1) ++ " s)").postln;
    alone
};
rmsOver = { |xs, a, b| var seg = xs.copyRange((a * sr).asInteger, (b * sr).asInteger - 1);
    ((seg.asArray.squared.sum / seg.size.max(1)).sqrt.max(1e-9)).ampdb };
peakDb = { |xs, a, b| (xs.copyRange(a, b - 1).asArray.abs.maxItem.max(1e-9)).ampdb };

// Idea 1: the ramp, in whole passes: 1 unit as played, 3 down, 1 at the
// bottom, 2 up, 1 as played.
report = { |name, alone|
    var times = [1, 3, 1, 2, 1] * unit;
    ("  " ++ name ++ ", dB a pass against the first: " ++ (0 .. times.sum - 1).collect { |k|
        (rmsOver.(alone, k * loopDur, (k + 1) * loopDur) - rmsOver.(alone, 0, loopDur)).round(0.5) }.asString).postln;
};
total = 8 * unit * loopDur;
[[\gate, 0, "1a-gate"], [\decay, 1, "1b-decay"]].do { |v|
    var alone = render.(v[2], table[\refined], [\noteShape, v[1]], [], total, [1, 3, 1, 2, 1] * unit * loopDur);
    report.(v[2], alone);
};

// Idea 2: 2 units forward, 3 reversed, 1 forward; each switch sent half a
// pass before the boundary it lands on.
total = 6 * unit * loopDur;
[[table[\refined], "2-reverse"], [table[\raw], "2-reverse-raw"]].do { |v|
    var alone = render.(v[1], v[0], [], [
        [((2 * unit) - 0.5) * loopDur, [\noteRev, 1]],
        [((5 * unit) - 0.5) * loopDur, [\noteRev, 0]]
    ], total);
    // How hard each reversed slice starts: its first 10 ms against its loudest.
    var starts = v[0].copyRange(2, v[0].size - 3), from = (2 * unit * loopFrames);
    var heads = starts.collect { |s, i|
        var a = from + s.mod(n), e = from + (starts[(i + 1).mod(starts.size)] - s).mod(n) + s.mod(n);
        peakDb.(alone, a, a + (0.01 * sr).asInteger) - peakDb.(alone, a, e)
    };
    ("  " ++ v[1] ++ ": each reversed slice's first 10 ms against its peak, dB (0 = it starts on its loudest): "
        ++ heads.collect { |h| h.round(1).asInteger }.asString).postln;
};
// With Reverse: the loop backwards, each note forwards (a retrograde), as
// the switches land together: 2 units forward, 3 so, 1 forward.
render.("3-retrograde", table[\refined], [], [
    [((2 * unit) - 0.5) * loopDur, [\noteRev, 1, \dir, -1]],
    [((5 * unit) - 0.5) * loopDur, [\noteRev, 0, \dir, 1]]
], total);
["loop.wav", "drums.wav"].do { |f| File.delete(tmp +/+ f) };
File.delete(tmp);
watchdog.stop;
"sampler experiment: done".postln;
0.exit;
)
