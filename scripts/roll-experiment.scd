// megalooper — a roll that halves, an experiment (roadmap item 24, idea 7;
// docs/dev/sampler.md, "Idea 7"): a moment of the loop held and repeated in
// windows that halve through the meter's own units, landing on the loop's
// one, rendered on a recorded take before anything is built.
//
//   7a-build        armed: the last two bars before the one. The first of them
//                   repeats its first beat group; the second halves group by
//                   group, an eighth (the bar's unit), a sixteenth, a 32nd,
//                   and its last unit a 64th; then the one, the loop where it
//                   would have been (the playhead runs on underneath). The
//                   drums play on.
//   7b-build-drums  the same, the drums rolled with it.
//   7c-pedal        the pedal instead of the meter: a ramp from the first of
//                   the two bars to the one, the window stepping down as it
//                   rises (a group, a unit, a half, a quarter, an eighth of a
//                   unit), each step taken at the next window's edge.
//
// What repeats starts on a note: the window is anchored on the attack the
// slices put nearest the bar's head (LoopSlices), not the grid point, which
// the loop's audio sits ~20 ms after: a 64th from the grid would be mostly
// the note before's tail. The roll comes in and lands with 3 ms crossfades,
// and each window's edges fade over 2 ms.
//
// The render: a pass as played, a pass with the build, a pass as played; for a
// loop under 6 s, five passes with the build in the second and the fourth.
// Each comes as the loop with the drums, and 7a also the loop alone (-loop).
//
//     sclang scripts/roll-experiment.scd <set stamp> <out dir> [<take> <pass>]
(
var stamp = thisProcess.argv[0], outDir = thisProcess.argv[1];
var takeNo = (thisProcess.argv[2] ? "1").asInteger, passNo = (thisProcess.argv[3] ? "1").asInteger;
var root = thisProcess.nowExecutingPath.dirname.dirname, sessions = root +/+ "sessions";
var sr = 48000, eventsPath, events, audio0, files, take, play, loopDur, n, fromFrame, result, paths = ();
var loopData, drumData, readPass, tmp, watchdog, bars, units, unitF, barHeads, groupsOf, starts, anchorAt;
var passes, buildPasses, barA, barB, sched, pedalSched, rollDef, render, fmtU;
if(stamp.isNil or: { outDir.isNil }) {
    "usage: sclang scripts/roll-experiment.scd <set stamp> <out dir> [<take> <pass>]".postln;
    1.exit;
};
watchdog = Routine { 600.wait; "roll experiment: timed out".postln; 1.exit }.play(AppClock);
eventsPath = (sessions +/+ stamp ++ "*-events.jsonl").pathMatch.first;
events = File.readAllString(eventsPath).split($\n).reject { |x| x.isEmpty or: { x.contains("\"ev\": \"hit\"") } }
    .collect { |x| MegaRemote.plain(MegaFiles.parseObject(x)) };
audio0 = (events.detect { |e| e[\ev] == "audio" } !? { |e| e[\t] }) ? 0;
files = events.detect { |e| e[\ev] == "files" } !? { |e| e[\files] };
[\loop, \drums].do { |k| paths[k] = eventsPath.dirname +/+ files[k] };
take = events.select { |e| e[\ev] == "take" }[takeNo - 1];
play = take[\play] ? take[\t];
loopDur = take[\loopDur];
n = (loopDur * sr).round.asInteger;
result = take[\result];
fromFrame = ((play + (passNo * loopDur) - audio0) * sr).round.asInteger;

readPass = { |path|
    var sf = SoundFile.openRead(path), c, data, out;
    c = sf.numChannels;
    sf.seek(fromFrame, 0);
    data = FloatArray.newClear(n * c);
    sf.readData(data);
    sf.close;
    if(c == 2) { data } {
        out = FloatArray.newClear(n * 2);
        n.do { |f| out[f * 2] = data[f]; out[(f * 2) + 1] = data[f] };
        out
    }
};
loopData = readPass.(paths[\loop]);
drumData = readPass.(paths[\drums]);

// The drums' grid, from the loop's start: the bars in the reading's units,
// each unit the loop's length over their sum; a bar's beat groups.
bars = MeterAnalyzer.barsOf(result);
units = bars.sum;
unitF = n / units;
barHeads = bars.inject([0], { |acc, b| acc.add(acc.last + b) });
groupsOf = { |b| MeterAnalyzer.beatGrouping(bars[b], result[\denominator] ? 8) };
fmtU = { |u| (u * unitF / sr * 1000).round(0.1) };
("take " ++ takeNo ++ ": " ++ result[\numerator] ++ "/" ++ result[\denominator] ++ " at " ++ result[\bpm].round(0.1)
    ++ " BPM, bars " ++ bars.asString ++ ", a unit " ++ fmtU.(1) ++ " ms, a loop of " ++ loopDur.round(0.001) ++ " s").postln;
if(bars.size < 2) { "the build needs two bars".postln; 1.exit };

// The attacks (LoopSlices), and the one a grid point's window starts on: the
// nearest within 60 ms, else the point itself.
starts = LoopSlices.attackStarts(loopData, sr,
    (take[\onsets] ? []).select { |p| (p[0] >= 0) and: { p[0] < loopDur } }.collect { |p| (p[0] * sr).round.asInteger }, 2)[\starts];
anchorAt = { |frame|
    var near = starts.collect { |s| [s, ((s - frame + (n / 2)).mod(n) - (n / 2)).abs] }.sort { |a, b| a[1] < b[1] }.first;
    if(near.notNil and: { near[1] < (0.06 * sr) }) { near[0] } { frame.round.asInteger.mod(n) }
};

// The build: bar A held at its first group's length, bar B halving group by
// group from a unit, its last unit one more; [unit from bar A's head, window
// in units] each.
barA = bars.size - 2;
barB = bars.size - 1;
sched = [[0, groupsOf.(barA).first]];
{
    var at = bars[barA], w = 1;
    groupsOf.(barB).do { |g| sched = sched.add([at, w]); at = at + g; w = w / 2 };
    sched = sched.add([at - 1, w]);
}.value;
// The pedal: a ramp over the two bars, its five steps at even fifths of it.
pedalSched = [groupsOf.(barA).first, 1, 0.5, 0.25, 0.125].collect { |w, i| [(bars[barA] + bars[barB]) * i / 5, w] };
("the build: " ++ sched.collect { |s| "from unit " ++ s[0] ++ " a window of " ++ fmtU.(s[1]) ++ " ms" }.join(", ")).postln;

passes = if(loopDur >= 6) { 3 } { 5 };
buildPasses = if(passes == 3) { [1] } { [1, 3] };
tmp = PathName.tmp +/+ "megalooper-roll-" ++ thisProcess.pid;
File.mkdir(tmp);
File.mkdir(outDir);
[["loop.wav", loopData], ["drums.wav", drumData]].do { |fd|
    var out = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(2).sampleRate_(sr);
    out.openWrite(tmp +/+ fd[0]);
    out.writeData(fd[1]);
    out.close;
};

// The roll. Buffers 0 the loop, 1 the drums (a pass each, played round).
//   armed 1: the roll starts on the sample the playhead crosses `anchor`;
//   win: the window wanted, frames, taken on the next multiple of it since
//   the start; land 1: it ends on the sample the playhead crosses `landAt`.
// Out 0-1 the loop with the drums, 2-3 the loop.
rollDef = SynthDef(\rollTest, { |loopFrames = 48000, anchor = 0, landAt = 1, drumsToo = 0|
    var p = Phasor.ar(DC.ar(0), 1, 0, loopFrames);
    var prev = Delay1.ar(p);
    var armed = \armed.ar(0), land = \land.ar(0), want = \win.ar(4800).max(64);
    var startTrig = armed * (p >= anchor) * (prev < anchor);
    var landTrig = land * (p >= landAt) * (prev < landAt);
    var rolling = SetResetFF.ar(startTrig, landTrig);
    var c = Sweep.ar(startTrig, SampleRate.ir);
    var cPrev = Delay1.ar(c);
    var w = Latch.ar(want, startTrig + ((c % want) < (cPrev % want))).max(64);
    var off = c % w;
    var edge = ((off.min(w - off)) / (0.002 * SampleRate.ir)).clip(0, 1);
    var at = (anchor + off).mod(loopFrames);
    var mix = Slew.ar(rolling, 333, 333);
    var loopN = BufRd.ar(2, 0, p, 0, 1), loopR = BufRd.ar(2, 0, at, 0, 1) * edge;
    var drumN = BufRd.ar(2, 1, p, 0, 1), drumR = BufRd.ar(2, 1, at, 0, 1) * edge;
    var loop = (loopN * (1 - mix)) + (loopR * mix);
    var drums = Select.ar(drumsToo, [drumN, (drumN * (1 - mix)) + (drumR * mix)]);
    Out.ar(0, Limiter.ar(loop + drums, 0.97, 0.01));
    Out.ar(2, loop);
});

// A render: `steps` the windows, [unit from bar A's head, window in units].
render = { |name, steps, drumsToo|
    var osc = tmp +/+ name ++ ".osc", wav = tmp +/+ name ++ ".wav", sf, data, said, score, dur = passes * loopDur;
    var headA = barHeads[barA] * unitF, anchor = anchorAt.(headA), land = anchorAt.(0).max(1);
    score = [
        [0.0, [\d_recv, rollDef.asBytes]],
        [0.0, [\b_allocRead, 0, tmp +/+ "loop.wav"]],
        [0.0, [\b_allocRead, 1, tmp +/+ "drums.wav"]],
        [0.0, [\s_new, \rollTest, 1000, 1, 0, \loopFrames, n, \anchor, anchor, \landAt, land, \drumsToo, drumsToo,
            \win, steps[0][1] * unitF]]
    ];
    buildPasses.do { |k|
        var t0 = (k * n) + anchor;
        // Armed a unit before its start; each window sent half a window
        // before its edge, so the next multiple of it is that edge.
        score = score.add([((t0 - unitF) / sr), [\n_set, 1000, \armed, 1, \land, 0, \win, steps[0][1] * unitF]]);
        steps.drop(1).do { |s|
            score = score.add([((t0 + (s[0] * unitF) - (s[1] * unitF / 2)) / sr), [\n_set, 1000, \win, s[1] * unitF]]);
        };
        score = score.add([((t0 + (unitF / 4)) / sr), [\n_set, 1000, \armed, 0]]);
        // Landing armed half a unit before the loop's one.
        score = score.add([((((k + 1) * n) - (unitF / 2)) / sr), [\n_set, 1000, \land, 1]]);
        score = score.add([((((k + 1) * n) + (unitF / 2)) / sr), [\n_set, 1000, \land, 0]]);
    };
    score = score ++ [[dur - 0.01, [\n_free, 1000]], [dur, [\c_set, 0, 0]]];
    Score(score).writeOSCFile(osc);
    said = ("perl -e 'alarm shift; exec @ARGV' 600 " ++ MegaSAPlugins.scsynthPath.shellQuote ++ " -u " ++ (58800 + 150.rand)
        ++ " -m 262144 -N " ++ osc.shellQuote ++ " _ " ++ wav.shellQuote ++ " " ++ sr ++ " WAV float -o 4 -i 0 2>&1").unixCmdGetStdOut;
    sf = SoundFile.openRead(wav);
    if(sf.isNil) { ("  " ++ name ++ " did not render: " ++ said.split($\n).reject(_.isEmpty).keep(-3).join(" | ")).postln; 1.exit };
    data = FloatArray.newClear(sf.numFrames * 4);
    sf.readData(data);
    sf.close;
    ([[name, 0]] ++ (if(drumsToo == 0) { [[name ++ "-loop", 2]] } { [] })).do { |o|
        var out = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(2).sampleRate_(sr);
        var xs = FloatArray.newClear(sf.numFrames * 2);
        sf.numFrames.do { |f| xs[f * 2] = data[(f * 4) + o[1]]; xs[(f * 2) + 1] = data[(f * 4) + o[1] + 1] };
        out.openWrite(outDir +/+ o[0] ++ ".wav");
        out.writeData(xs);
        out.close;
    };
    File.delete(osc); File.delete(wav);
    ("  wrote " ++ (outDir +/+ name) ++ ".wav (" ++ dur.round(0.1) ++ " s; the build from "
        ++ ((buildPasses[0] * loopDur) + (barHeads[barA] * unitF / sr)).round(0.01) ++ " s)").postln;
    data
};

render.("7a-build", sched, 0);
render.("7b-build-drums", sched, 1);
render.("7c-pedal", pedalSched, 0);
["loop.wav", "drums.wav"].do { |f| File.delete(tmp +/+ f) };
File.delete(tmp);
watchdog.stop;
"roll experiment: done".postln;
0.exit;
)
