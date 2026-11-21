// megalooper — the rhythm echo, an experiment (roadmap item 23, idea 4):
// the loop's onsets as an echo, heard on a recorded set before anything is
// built. Two ways, each mixed into the set's master over a stretch of it:
//
//   A  convolution: the take's onsets (and strengths) as an impulse response
//      one loop long, the instrument stem through it (PartConv, as an effect
//      would). Each note comes back in the riff's rhythm, from the note on.
//   B  on the grid: a ring holds the instrument's last seconds; on each of
//      the loop's own onsets the last note played comes back as a grain, as
//      loud as that onset, for one loop after the note. The notes are heard
//      on the set's tap (the dry analysis input, levelled to -1 dBFS over
//      the stretch, threshold 0.5, as megalooper hears takes): on the
//      instrument stem, after the amp, Onsets found 4 notes in 40 s of
//      playing where the tap gave 97.
//
//     sclang scripts/rhythm-echo-experiment.scd <set stamp> <out dir> [<from> <secs> <wet dB>]...
//
// Without stretches: the set's takes, each from 6 s after its loop starts
// for 40 s (or to its clear). Writes, per stretch, <n>-dry.wav (the master),
// <n>-A-conv.wav and <n>-B-grid.wav, and the echoes alone, <n>-A-wet.wav and
// <n>-B-wet.wav. One offline render each (scsynth -N on a far port); nothing
// touches a running megalooper.
(
var stamp = thisProcess.argv[0], outDir = thisProcess.argv[1];
var sessions = Looper.repoRoot +/+ "sessions";
var sr = 48000, fftsize = 2048, ring = 4;
var eventsPath, events, audio0, files, guitarPath, masterPath, tapPath, takes, clears, stretches;
// The echoes' levels: A's taps sum over every note, so it sits lower.
var aDb = -12, bDb = 3, wetDb;
var render, writeMono, say = { |x| x.postln };
if(stamp.isNil or: { outDir.isNil }) {
    "usage: sclang scripts/rhythm-echo-experiment.scd <set stamp> <out dir> [<from s> <secs>]".postln;
    1.exit;
};
eventsPath = (sessions +/+ stamp ++ "*-events.jsonl").pathMatch.first;
events = File.readAllString(eventsPath).split($\n).reject { |x| x.isEmpty or: { x.contains("\"ev\": \"hit\"") } }
    .collect { |x| MegaRemote.plain(MegaFiles.parseObject(x)) };
audio0 = (events.detect { |e| e[\ev] == "audio" } !? { |e| e[\t] }) ? 0;
files = events.detect { |e| e[\ev] == "files" } !? { |e| e[\files] };
guitarPath = eventsPath.dirname +/+ files[\guitar];
masterPath = eventsPath.dirname +/+ files[\master];
tapPath = eventsPath.dirname +/+ files[\tap];
takes = events.select { |e| e[\ev] == "take" };
clears = events.select { |e| e[\ev] == "clear" }.collect { |e| e[\t] };
File.mkdir(outDir);

// A mono float WAV of `xs` at `path`.
writeMono = { |path, xs|
    var sf = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(1).sampleRate_(sr);
    sf.openWrite(path);
    sf.writeData(FloatArray.newFrom(xs));
    sf.close;
};

// One stretch of one take: [take event, from (file seconds), seconds].
stretches = if(thisProcess.argv.size > 2) {
    thisProcess.argv.drop(2).clump(3).collect { |c|
        var from = c[0].asFloat, secs = c[1].asFloat;
        c[2] !? { |db| aDb = db.asFloat; bDb = db.asFloat + 15 };
        // The take playing at `from`: the last one before it.
        [takes.select { |e| ((e[\play] ? e[\t]) - audio0) <= from }.last, from, secs]
    }
} {
    takes.collect { |e|
        var start = (e[\play] ? e[\t]) - audio0;
        var end = (clears.detect { |c| c > e[\t] } ? inf) - audio0;
        [e, start + 6, (end - (start + 6)).min(40)]
    }
};

render = { |n, take, from, secs|
    var loopDur = take[\loopDur], onsets = take[\onsets], play = (take[\play] ? take[\t]) - audio0;
    var peak = onsets.collect { |o| o[1] }.maxItem.max(1e-6);
    var gains = onsets.collect { |o| (o[1] / peak).sqrt * 0.7 };
    var frames = (secs * sr).round.asInteger, fromFrame = (from * sr).round.asInteger;
    var tmp = PathName.tmp +/+ "megalooper-recho-" ++ thisProcess.pid ++ "-" ++ n;
    var irPath = tmp +/+ "ir.wav", trigPath = tmp +/+ "trig.wav", durPath = tmp +/+ "dur.wav";
    var ir, irFrames, partBufSize, trig, durTrack, times = List.new, perLoop = onsets.size;
    var defA, defB, run, label = n.asString, tapGain;
    File.mkdir(tmp);
    say.("-- stretch " ++ n ++ ": " ++ from.round(0.1) ++ " s for " ++ secs.round(0.1) ++ " s, a loop of "
        ++ loopDur.round(0.001) ++ " s with " ++ perLoop ++ " onsets ("
        ++ take[\result][\numerator] ++ "/" ++ take[\result][\denominator] ++ " at " ++ take[\result][\bpm].round(0.1) ++ " BPM)");
    // A: taps at the onsets after the first, timed from it, one loop long.
    irFrames = (loopDur * sr).round.asInteger;
    ir = FloatArray.newClear(irFrames);
    onsets.do { |o, i|
        var at = ((o[0] - onsets[0][0]) * sr).round.asInteger;
        if((i > 0) and: { at < irFrames }) { ir[at] = gains[i] };
    };
    writeMono.(irPath, ir);
    partBufSize = fftsize * (irFrames / (fftsize / 2)).roundUp.asInteger;
    // B: every one of the loop's onsets in the stretch, its gain, and the
    // time to the next (the grain is most of it, at most 0.4 s).
    (((from - play) / loopDur).floor.asInteger .. ((from + secs - play) / loopDur).ceil.asInteger).do { |k|
        onsets.do { |o, i| times.add([play + (k * loopDur) + o[0] - from, gains[i]]) };
    };
    times = times.select { |t| (t[0] >= 0) and: { t[0] < secs } };
    trig = FloatArray.newClear(frames);
    durTrack = FloatArray.newClear(frames);
    times.do { |t, i|
        var at = (t[0] * sr).round.asInteger, next = times[i + 1] !? { |u| u[0] } ? (t[0] + 0.4);
        var d = ((next - t[0]) * 0.9).clip(0.03, 0.4), to = times[i + 1] !? { |u| (u[0] * sr).round.asInteger } ? frames;
        at = at.min(frames - 1);
        trig[at] = t[1];
        (at .. (to - 1).min(frames - 1)).do { |f| durTrack[f] = d };
    };
    // The tap levelled to -1 dBFS over the stretch, as the auto level does.
    tapGain = { var f = SoundFile.openRead(tapPath), xs = FloatArray.newClear(frames * f.numChannels);
        f.seek(fromFrame); f.readData(xs); f.close; -1.dbamp / xs.abs.maxItem.max(1e-6) }.value;
    writeMono.(trigPath, trig);
    writeMono.(durPath, durTrack);
    defA = SynthDef(\rechoA, { |out, wetOut, gain = 0.6|
        var g = PlayBuf.ar(2, 0).sum * 0.5;
        var wet = PartConv.ar(g, fftsize, 3) * gain;
        Out.ar(out, Limiter.ar(PlayBuf.ar(2, 1) + (wet ! 2), 0.97, 0.01));
        Out.ar(wetOut, Limiter.ar(wet ! 2, 0.97, 0.01));
    });
    defB = SynthDef(\rechoB, { |out, wetOut, gain = 0.6, perLoop = 8|
        var g = PlayBuf.ar(2, 0).sum * 0.5;
        var ringBuf = LocalBuf(sr * ring, 1).clear;
        var w = Phasor.ar(DC.ar(0), 1, 0, sr * ring);
        var write = BufWr.ar(g, ringBuf, w);
        // The live notes, and where the last began (10 ms before its onset).
        var live = Onsets.kr(FFT(LocalBuf(512), PlayBuf.ar(1, 6) * \tapGain.kr(1)), 0.5);
        var lastAt = Latch.kr(A2K.kr(w), live) - (0.01 * sr);
        var t = PlayBuf.ar(1, 4), hit = t > 0;
        var since = PulseCount.ar(hit, K2A.ar(live));
        var on = hit * (since <= perLoop) * (PulseCount.ar(K2A.ar(live)) > 0);
        var dur = Latch.ar(PlayBuf.ar(1, 5), hit);
        var amp = Latch.ar(t, hit);
        var wet = GrainBuf.ar(1, on, dur, ringBuf, 1, (lastAt.wrap(0, sr * ring) / (sr * ring)), 2, 0, -1, 32) * amp * gain;
        Out.ar(out, Limiter.ar(PlayBuf.ar(2, 1) + (wet ! 2), 0.97, 0.01));
        Out.ar(wetOut, Limiter.ar(wet ! 2, 0.97, 0.01));
    });
    run = { |def, kind, extra|
        var osc = tmp +/+ kind ++ ".osc", wav = tmp +/+ kind ++ ".wav", sf, data, said;
        var score = [
            [0.0, [\d_recv, def.asBytes]],
            [0.0, [\b_allocRead, 0, guitarPath, fromFrame, frames]],
            [0.0, [\b_allocRead, 1, masterPath, fromFrame, frames]],
            [0.0, [\b_allocRead, 2, irPath]],
            [0.0, [\b_alloc, 3, partBufSize, 1]],
            [0.0, [\b_gen, 3, "PreparePartConv", 2, fftsize]],
            [0.0, [\b_allocRead, 4, trigPath]],
            [0.0, [\b_allocRead, 5, durPath]],
            [0.0, [\b_allocRead, 6, tapPath, fromFrame, frames]],
            [0.0, [\s_new, def.name, 1000, 0, 0, \out, 0, \wetOut, 2] ++ extra],
            [secs - 0.01, [\n_free, 1000]],
            [secs, [\c_set, 0, 0]]
        ];
        Score(score).writeOSCFile(osc);
        said = ("perl -e 'alarm shift; exec @ARGV' 600 " ++ MegaSAPlugins.scsynthPath.shellQuote ++ " -u " ++ (58600 + 200.rand)
            ++ " -m 262144 -N " ++ osc.shellQuote ++ " _ " ++ wav.shellQuote ++ " " ++ sr ++ " WAV float -o 4 -i 0 2>&1").unixCmdGetStdOut;
        sf = SoundFile.openRead(wav);
        if(sf.isNil) { ("  " ++ kind ++ " did not render: " ++ said.split($\n).reject(_.isEmpty).keep(-3).join(" | ")).postln } {
            data = FloatArray.newClear(sf.numFrames * 4);
            sf.readData(data);
            sf.close;
            [[label ++ "-" ++ kind, 0], [label ++ "-" ++ kind.split($-)[0] ++ "-wet", 2]].do { |o|
                var out = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(2).sampleRate_(sr);
                var xs = FloatArray.newClear(sf.numFrames * 2);
                sf.numFrames.do { |f| xs[f * 2] = data[(f * 4) + o[1]]; xs[(f * 2) + 1] = data[(f * 4) + o[1] + 1] };
                out.openWrite(outDir +/+ o[0] ++ ".wav");
                out.writeData(xs);
                out.close;
                ("  wrote " ++ (outDir +/+ o[0] ++ ".wav")).postln;
            };
        };
    };
    run.(defA, "A-conv", [\gain, aDb.dbamp]);
    run.(defB, "B-grid", [\gain, bDb.dbamp, \perLoop, perLoop, \tapGain, tapGain]);
    // The master alone, for comparison.
    {
        var sf = SoundFile.openRead(masterPath), xs = FloatArray.newClear(frames * 2);
        var out = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(2).sampleRate_(sr);
        sf.seek(fromFrame);
        sf.readData(xs);
        sf.close;
        out.openWrite(outDir +/+ label ++ "-dry.wav");
        out.writeData(xs);
        out.close;
        ("  wrote " ++ (outDir +/+ label ++ "-dry.wav")).postln;
    }.value;
    [irPath, trigPath, durPath].do { |f| if(File.exists(f)) { File.delete(f) } };
};

stretches.do { |s, i| render.(i + 1, s[0], s[1], s[2]) };
"rhythm echo: done".postln;
0.exit;
)
