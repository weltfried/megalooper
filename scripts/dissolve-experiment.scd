// megalooper — the dissolve into dust, an experiment (roadmap item 23, idea 1;
// docs/dev/microsound.md, "Idea 1"): a dissolve put on a recorded set's take,
// rendered three ways before anything is built.
//
//   1-today       as megalooper ends now: the dry loop gone by 0.6, the grains
//                 fading from 0.5 to 1.0 at their texture, the drums, the
//                 onset kit and the synth at full level until the stop
//   2-dust-cloud  the grains (Cloud) turn to dust from 0.5 (shorter, fewer,
//                 less regular, held up as they stop overlapping), their
//                 level held until 0.8; the drums and the onset kit gone by
//                 0.4, the synth by 0.6
//   3-dust-clock  the same on the Clock: the grid thins (the pulses late in a
//                 beat group first, then the heads by chance), on the beats
//
// The duo heard it on 2026-11-22 before anything was built, on a patched copy
// of the graphs, as four renders: 2 without the lift and 2b with it (the
// overlaps' ratio to the -1/4, at most +12 dB, added here as the arc's
// level). "2b sounds better": the lift went into the graph, so 2 now renders
// what 2b was.
//
// The grains are the set's own settings (Cloud) or the Clock's at two a beat;
// the Clock's level is matched to Cloud's over the lead-in. The live players
// are left out: this is what megalooper plays on its own, which they would
// play into. Each file also comes as its grains alone (-grains).
//
//     sclang scripts/dissolve-experiment.scd <set stamp> <out dir> [<take> <lead passes> <dissolve passes>]
//
// The take counts from 1 (default 2); the lead-in starts two passes after it
// (the drums running); defaults 2 passes of lead-in, a dissolve of 4 (the
// app's default), 3 s after the stop. One offline render each (scsynth -N on
// a far port); nothing touches a running megalooper.
(
var stamp = thisProcess.argv[0], outDir = thisProcess.argv[1];
var takeNo = (thisProcess.argv[2] ? "2").asInteger, leadPasses = (thisProcess.argv[3] ? "2").asInteger;
var passes = (thisProcess.argv[4] ? "4").asInteger, tail = 3;
var root = thisProcess.nowExecutingPath.dirname.dirname, sessions = root +/+ "sessions";
var sr = 48000, eventsPath, events, audio0, files, take, play, loopDur, clearAt, grainsState, settings;
var leadStart, dissolveAt, endAt, leadSecs, dissolveSecs, total, fromFrame, frames, loopFrames;
var stems = [\loop, \drums, \onset, \synth], paths = (), chans = (), result, grid, plateau, envIdx;
var tmp = PathName.tmp +/+ "megalooper-dissolve-" ++ thisProcess.pid;
var defArc, defStems, defCloud, defClock, render, rmsOver, cloudArgs, clockArgs, cloudAmp, clockAmp, measured;
if(stamp.isNil or: { outDir.isNil }) {
    "usage: sclang -l <conf> scripts/dissolve-experiment.scd <set stamp> <out dir> [<take> <lead passes> <dissolve passes>]".postln;
    1.exit;
};
eventsPath = (sessions +/+ stamp ++ "*-events.jsonl").pathMatch.first;
events = File.readAllString(eventsPath).split($\n).reject { |x| x.isEmpty or: { x.contains("\"ev\": \"hit\"") } }
    .collect { |x| MegaRemote.plain(MegaFiles.parseObject(x)) };
audio0 = (events.detect { |e| e[\ev] == "audio" } !? { |e| e[\t] }) ? 0;
files = events.detect { |e| e[\ev] == "files" } !? { |e| e[\files] };
stems.do { |k| paths[k] = eventsPath.dirname +/+ files[k] };
take = events.select { |e| e[\ev] == "take" }[takeNo - 1];
play = take[\play] ? take[\t];
loopDur = take[\loopDur];
clearAt = (events.detect { |e| (e[\ev] == "clear") and: { e[\t] > take[\t] } } !? { |e| e[\t] }) ? inf;
leadStart = play + (2 * loopDur);
dissolveAt = leadStart + (leadPasses * loopDur);
endAt = dissolveAt + (passes * loopDur);
leadSecs = dissolveAt - leadStart;
dissolveSecs = endAt - dissolveAt;
total = leadSecs + dissolveSecs + tail;
if(endAt + tail > clearAt) { ("the take was cleared at " ++ clearAt.round(0.1) ++ " s, before the render's end at "
    ++ (endAt + tail).round(0.1) ++ " s: fewer passes").postln; 1.exit };
fromFrame = ((leadStart - audio0) * sr).round.asInteger;
frames = (total * sr).round.asInteger;
loopFrames = (loopDur * sr).round.asInteger;
stems.do { |k| var f = SoundFile.openRead(paths[k]); chans[k] = f.numChannels; f.close };
// The Grains as they were set in the set, the last state before the dissolve.
grainsState = events.select { |e| (e[\ev] == "state") and: { e[\part] == "looper" } and: { e[\t] <= dissolveAt } }
    .last[\state][\grains];
settings = grainsState[\settings];
// The Clock's grid from the take's reading, as the app makes it.
result = Event.new.putAll(take[\result]);
result[\downbeatPhase] = ((take[\firstOnset] ? 0) + (result[\downbeatOffset] ? 0)).mod(loopDur);
grid = LooperGrains.groupGrid(result, loopDur);
// The window as a buffer for both engines (Cloud's Hann is its own, -1).
envIdx = (LooperGrains.envNames.detectIndex { |n| n == grainsState[\window] }) ? 0;
plateau = if(envIdx > 0) { LooperGrains.envShapes[envIdx - 1].discretize(1024) } {
    Array.fill(1024, { |i| sin(pi * i / 1023).squared }) };
("take " ++ takeNo ++ ": " ++ result[\numerator] ++ "/" ++ result[\denominator] ++ " at " ++ result[\bpm].round(0.1)
    ++ " BPM, a loop of " ++ loopDur.round(0.001) ++ " s; lead-in from " ++ leadStart.round(0.01) ++ " s, the dissolve "
    ++ dissolveAt.round(0.01) ++ " to " ++ endAt.round(0.01) ++ " s (" ++ passes ++ " passes)").postln;
("grains: " ++ grainsState[\window] ++ ", " ++ settings.asString).postln;
("grid: beat " ++ grid[\beat].round(0.001) ++ ", offset " ++ grid[\offset].round(0.001) ++ ", " ++ grid[\count] ++ " groups").postln;
File.mkdir(tmp);
File.mkdir(outDir);

// Buses: 0-3 out (the mix, the grains alone); 20-21 the grains; kr 0 the
// dissolve's position, 1 the loop's phase (seconds), 2 the grains' amp, 3 dust.
defArc = SynthDef(\dxArc, { |amp = 0.15, newWay = 0|
    var pos = EnvGen.kr(Env([0, 0, 1], [leadSecs, dissolveSecs]));
    var held = Select.kr(newWay, [(1 - ((pos - 0.5) / 0.5)).clip(0, 1), (1 - ((pos - 0.8) / 0.2)).clip(0, 1)]);
    var dust = ((pos - 0.5) / 0.5).clip(0, 1) * newWay;
    Out.kr(0, pos);
    Out.kr(1, Sweep.kr(0, 1).mod(loopDur));
    Out.kr(2, amp * held);
    Out.kr(3, dust);
});
defStems = SynthDef(\dxStems, { |newWay = 0|
    var pos = In.kr(0), live = pos < 1;
    var stem = { |k, buf| var x = PlayBuf.ar(chans[k], buf); if(chans[k] == 1) { x ! 2 } { x } };
    var loopMix = (1 - (pos / 0.6)).clip(0, 1);
    var drumsMix = Select.kr(newWay, [1, (1 - (pos / 0.4)).clip(0, 1)]) * live;
    var synthMix = Select.kr(newWay, [1, (1 - (pos / 0.6)).clip(0, 1)]) * live;
    var grains = In.ar(20, 2);
    var mix = (stem.(\loop, 0) * Lag.kr(loopMix, 0.05)) + ((stem.(\drums, 1) + stem.(\onset, 2)) * Lag.kr(drumsMix, 0.05))
        + (stem.(\synth, 3) * Lag.kr(synthMix, 0.05)) + grains;
    Out.ar(0, Limiter.ar(mix, 0.97, 0.01));
    Out.ar(2, grains);
});
defCloud = SynthDef(\dxCloud, LooperSynthDefs.granularGraph);
defClock = SynthDef(\dxClock, LooperSynthDefs.grainClockGraph);
cloudAmp = settings[\amp];
cloudArgs = [\bufnum, 4, \out, 20, \startFrame, 0, \loopFrames, loopFrames, \tau, grid[\beat], \phaseBus, 1, \locked, 1, \rate, 1,
    \morph, settings[\morph], \pitch, settings[\pitch], \detune, settings[\detune], \size, settings[\size],
    \density, settings[\density], \sizeRand, settings[\sizeRand], \position, settings[\position], \scan, settings[\scan],
    \sprayMs, settings[\spray], \envbuf, if(envIdx > 0) { 5 } { -1 }];
// The Clock: two grains a beat, half a pulse long, where the loop plays.
clockArgs = [\bufnum, 4, \out, 20, \startFrame, 0, \loopFrames, loopFrames, \tau, grid[\beat], \phaseBus, 1, \locked, 1, \rate, 1,
    \pitch, settings[\pitch], \position, 0, \envbuf, 5, \gridOffset, grid[\offset], \headsBuf, 6, \lensBuf, 7,
    \division, 2, \groups, 0, \scatter, 0, \length, 0.5, \pulsar, 0, \mask, 0, \octave, 2, \groupCount, grid[\count]];

// One render: [the grains' def, its args, their amp, the new way?] into
// <name>.wav and <name>-grains.wav; answers the grains alone, as frames.
render = { |name, def, args, amp, newWay|
    var osc = tmp +/+ name ++ ".osc", wav = tmp +/+ name ++ ".wav", sf, data, said, grains;
    var score = [
        [0.0, [\d_recv, defArc.asBytes]], [0.0, [\d_recv, defStems.asBytes]], [0.0, [\d_recv, def.asBytes]],
        [0.0, [\b_allocRead, 0, paths[\loop], fromFrame, frames]],
        [0.0, [\b_allocRead, 1, paths[\drums], fromFrame, frames]],
        [0.0, [\b_allocRead, 2, paths[\onset], fromFrame, frames]],
        [0.0, [\b_allocRead, 3, paths[\synth], fromFrame, frames]],
        // The loop the grains read: the lead-in's first pass.
        [0.0, [\b_allocRead, 4, paths[\loop], fromFrame, loopFrames]],
        [0.0, [\b_alloc, 5, 1024, 1]], [0.0, [\b_setn, 5, 0, 1024] ++ plateau],
        [0.0, [\b_alloc, 6, 64, 1]], [0.0, [\b_setn, 6, 0, 64] ++ grid[\heads]],
        [0.0, [\b_alloc, 7, 64, 1]], [0.0, [\b_setn, 7, 0, 64] ++ grid[\lens]],
        [0.0, [\s_new, \dxArc, 1000, 1, 0, \amp, amp, \newWay, newWay]],
        [0.0, [\s_new, def.name, 1001, 1, 0] ++ args.asOSCArgArray],
        [0.0, [\n_map, 1001, \amp, 2, \dust, 3]],
        [0.0, [\s_new, \dxStems, 1002, 1, 0, \newWay, newWay]],
        [total - 0.01, [\n_free, 1000, 1001, 1002]],
        [total, [\c_set, 0, 0]]
    ];
    Score(score).writeOSCFile(osc);
    said = ("perl -e 'alarm shift; exec @ARGV' 600 " ++ MegaSAPlugins.scsynthPath.shellQuote ++ " -u " ++ (58800 + 150.rand)
        ++ " -m 262144 -N " ++ osc.shellQuote ++ " _ " ++ wav.shellQuote ++ " " ++ sr ++ " WAV float -o 4 -i 0 2>&1").unixCmdGetStdOut;
    sf = SoundFile.openRead(wav);
    if(sf.isNil) { ("  " ++ name ++ " did not render: " ++ said.split($\n).reject(_.isEmpty).keep(-3).join(" | ")).postln; 1.exit };
    data = FloatArray.newClear(sf.numFrames * 4);
    sf.readData(data);
    sf.close;
    grains = FloatArray.newClear(sf.numFrames);
    [[name, 0], [name ++ "-grains", 2]].do { |o|
        var out = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(2).sampleRate_(sr);
        var xs = FloatArray.newClear(sf.numFrames * 2);
        sf.numFrames.do { |f| xs[f * 2] = data[(f * 4) + o[1]]; xs[(f * 2) + 1] = data[(f * 4) + o[1] + 1] };
        out.openWrite(outDir +/+ o[0] ++ ".wav");
        out.writeData(xs);
        out.close;
    };
    sf.numFrames.do { |f| grains[f] = data[(f * 4) + 2] };
    File.delete(osc); File.delete(wav);
    ("  wrote " ++ (outDir +/+ name) ++ ".wav and -grains.wav").postln;
    grains
};
// The RMS of `xs` from `a` to `b` seconds, dB.
rmsOver = { |xs, a, b| var seg = xs.copyRange((a * sr).asInteger, (b * sr).asInteger - 1);
    ((seg.squared.sum / seg.size.max(1)).sqrt.max(1e-9)).ampdb };

measured = ();
measured[\today] = render.("1-today", defCloud, cloudArgs, cloudAmp, 0);
measured[\cloud] = render.("2-dust-cloud", defCloud, cloudArgs, cloudAmp, 1);
// The Clock at Cloud's level over the lead-in: once to measure, then again.
measured[\clock] = render.("3-dust-clock", defClock, clockArgs, cloudAmp, 1);
clockAmp = cloudAmp * (rmsOver.(measured[\cloud], 1, leadSecs) - rmsOver.(measured[\clock], 1, leadSecs)).dbamp;
("  the Clock " ++ (clockAmp / cloudAmp).ampdb.round(0.1) ++ " dB to match Cloud's lead-in").postln;
measured[\clock] = render.("3-dust-clock", defClock, clockArgs, clockAmp, 1);
// The grains' level through the dissolve, a second at a time, dB.
"the grains alone, dB a second, from the dissolve's start:".postln;
[\today, \cloud, \clock].do { |k|
    ("  " ++ k ++ ": " ++ (0 .. (dissolveSecs.floor.asInteger - 1)).collect { |s|
        rmsOver.(measured[k], leadSecs + s, leadSecs + s + 1).round(1).asInteger }.asString).postln;
};
File.delete(tmp);
"dissolve experiment: done".postln;
0.exit;
)
