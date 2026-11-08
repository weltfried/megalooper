// strength-check.scd: which onset salience should the analyser get? (2026-11-05)
//
// Candidates, all on the same onsets (the stage's logged ones for sets, the
// recorder chain's at 0.5 for training-data and synthetic takes):
//   cur    the logged / rendered strength: Amplitude.kr(sig, 0.001, 0.1) at the
//          trigger, which runs 64x fast (a ~1.6 ms release)
//   ampAr  what that line meant: a 1 ms / 100 ms follower at the trigger
//   peak   max |x| from 40 ms before the trigger to 30 ms after
//   rms    RMS over the same window
//   rise   the energy the hit adds: sqrt(max(rms(-40..+30 ms)^2 - rms(-130..-50 ms)^2, 0))
//   none   no strengths at all (the analyser's own fallback)
// Judged three ways:
//   (a) synthetic plucks with known levels: equal hits should read equal,
//       graded hits in order; damped single-line notes and ringing ones
//   (b) repeatability: the same position in different regular bars of a
//       labelled riff should get a similar strength (per-take normalised log)
//   (c) the analyser's readings against the labels
//
// Run: sclang -u 58xxx scripts/strength-check.scd   (a far port: see the launcher)
// First run 2026-11-05: rms over -40..+30 ms beat cur on (a) and (b) and fixed
// gerade-3; windows that end at the trigger fail on sharp synthetic attacks.
(
var repo = thisProcess.nowExecutingPath !? { |p| p.dirname.dirname } ?? { Looper.repoRoot };
var outDir = (Platform.defaultTempDir ? "/tmp") +/+ "megalooper-strength";
var scsynth = MegaSAPlugins.scsynthPath;
var maxOnsets = 4096;
var cands = [\cur, \ampAr, \peak, \rms, \rise, \rmsPre, \rmsPre70, \peakPre];
var takes = List.new;
var median, ranks, spearman, nrt, makeSynth, render, onPath, pitchPath, readSlots, readPitchSlots, readAudio;
var follower, seg, rmsOf, candidatesOf, barPairs, analyse, sameReading, gridSame, verdict, word, normLog;
var corrSafe, fmtReading;
var synthSpecs, port;

if(File.exists(outDir).not) { File.mkdir(outDir) };
// A runtime error stops the script before its 0.exit; this ends sclang anyway.
AppClock.sched(400, { "watchdog: exiting".postln; 1.exit; nil });
thisThread.randSeed = 20261105;
port = { 58100 + 800.rand };

median = { |a| var s = a.asArray.copy.sort; if(s.isEmpty) { nil } { s[s.size div: 2] } };
ranks = { |a| var ord = a.asArray.order, r = Array.newClear(a.size); ord.do { |idx, k| r[idx] = k }; r };
spearman = { |a, b| if(a.size < 4) { nil } { MeterAnalyzer.corr(ranks.(a), ranks.(b)) } };
onPath = { |i| outDir +/+ ("take" ++ i ++ "-on.wav") };
corrSafe = { |a, b| if(a.size < 3) { "—" } { MeterAnalyzer.corr(a.asArray, b.asArray).round(0.01).asString } };
fmtReading = { |r|
    case
    { r.isNil } { "—" }
    { r[\numerator].isNil } { "no meter" ++ (r[\error] !? { |e| " (" ++ e ++ ")" } ? "") }
    { MeterDecision.readingString(r) ++ (r[\error] !? { |e| " (" ++ e ++ ")" } ? "") }
};
pitchPath = { |i| outDir +/+ ("take" ++ i ++ "-pitch.wav") };

// ------------------------------------------------------------- helpers --
nrt = { |score, outPath|
    var osc = outPath ++ ".osc", cmd, said;
    Score(score.asArray.sort { |a, b| a[0] <= b[0] }).writeOSCFile(osc);
    cmd = scsynth.quote ++ " -N " ++ osc.quote ++ " _ " ++ outPath.quote
        ++ " 48000 WAV float -o 1 -i 0 -u " ++ port.() ++ " 2>&1";
    said = cmd.unixCmdGetStdOut;
    if(said.contains("exception") or: { said.contains("ERROR") } or: { said.contains("FAILURE") }) {
        ("scsynth said:\n" ++ said).warn;
    };
};

// A synthetic take: 28 eighths at 110 BPM, +-10 ms of hands, guitar-range
// harmonic tones (eight partials, random phases, the same RMS at any pitch)
// with a 4 ms pick noise. damped: each note stopped at the next (a single
// line); else they ring and overlap. graded: levels uniform over 24 dB.
makeSynth = { |path, damped, graded|
    var def = SynthDef(\scNote, { |freq = 110, amp = 0.25, decay = 0.6, gate = 1|
        var harm = (1..8);
        var norm = (harm.collect { |k| (1 / k).squared }.sum / 2).sqrt;
        var tone = Mix(harm.collect { |k| SinOsc.ar(freq * k, Rand(0, 2pi), 1 / k) }) / norm;
        var env = EnvGen.ar(Env.perc(0.003, decay * 5, 1, -6), doneAction: 2);
        var damp = EnvGen.ar(Env.asr(0, 1, 0.015), gate);
        var pick = WhiteNoise.ar(0.5) * EnvGen.ar(Env.perc(0.0005, 0.004));
        Out.ar(0, ((tone * env * damp) + pick) * amp * 0.5);
    });
    var eighth = 30 / 110, n = 28, score = List.new, times, amps, freqs;
    times = Array.fill(n, { |i| 0.1 + (i * eighth) + 0.01.rand2 });
    amps = if(graded) { Array.fill(n, { 24.0.rand.neg.dbamp }) } { Array.fill(n, 1.0) };
    freqs = Array.fill(n, { (40 + 25.rand).midicps });
    score.add([0.0, [\d_recv, def.asBytes]]);
    n.do { |i|
        score.add([times[i], [\s_new, \scNote, 2000 + i, 0, 0, \freq, freqs[i], \amp, 0.25 * amps[i],
            \decay, if(damped) { 0.6 } { 0.8 }]]);
        if(damped and: { i < (n - 1) }) { score.add([times[i + 1] - 0.005, [\n_set, 2000 + i, \gate, 0]]) };
    };
    score.add([12.0, [\c_set, 0, 0]]);
    nrt.(score, path);
    [times, amps]
};

readSlots = { |path|
    var sf = SoundFile.new, data, found = List.new;
    if(sf.openRead(path)) {
        data = FloatArray.newClear(sf.numFrames * sf.numChannels);
        sf.readData(data);
        sf.close;
        (1..(sf.numFrames - 1)).do { |slot|
            var time = data[slot * 3], strength = data[(slot * 3) + 1], flag = data[(slot * 3) + 2];
            if((flag > 0.5) and: { time > 0 }) { found.add([time, strength]) };
        };
    } { ("no result file " ++ path).warn };
    found.asArray
};
readPitchSlots = { |path|
    var sf = SoundFile.new, data, found = List.new;
    if(sf.openRead(path)) {
        data = FloatArray.newClear(sf.numFrames * sf.numChannels);
        sf.readData(data);
        sf.close;
        (1..(sf.numFrames - 1)).do { |slot|
            if((data[(slot * 4) + 3] > 0.5) and: { data[slot * 4] > 0 }) {
                found.add([data[slot * 4], data[(slot * 4) + 1], data[(slot * 4) + 2]]);
            };
        };
    };
    found.asArray
};
readAudio = { |tk|
    var sf = SoundFile.openRead(tk[\file]), ch = tk[\chans], n = tk[\numFrames], data;
    sf.seek(tk[\startFrame], 0);
    data = FloatArray.newClear(n * ch);
    sf.readData(data);
    sf.close;
    if(ch == 1) { Signal.newFrom(data) } { Signal.fill(n, { |i| data[i * ch] }) }
};

// The recorder's onset chain at the take's threshold, and Tartini as the
// recorder runs it, every take in one NRT run.
render = {
    var def = SynthDef(\scOnsets, { |bufnum = 0, threshold = 0.5, resultBuf = 1|
        var sig = PlayBuf.ar(1, bufnum, BufRateScale.kr(bufnum), 1, 0, 0);
        var trig = LooperSynthDefs.onsetTrig(sig, threshold);
        var time = Sweep.kr(1, 1);
        // the strength as the recorder read it until 2026-11-05 (what this script measured)
        var strength = Amplitude.kr(sig, 0.001, 0.1);
        var count = Stepper.kr(trig, 0, 0, maxOnsets, 1, 0);
        BufWr.kr([Latch.kr(time, trig), Latch.kr(strength, trig), 1], resultBuf, count, 0);
    });
    var pitchDef = SynthDef(\scPitch, { |bufnum = 0, resultBuf = 1, slots = 100|
        var sig = PlayBuf.ar(1, bufnum, BufRateScale.kr(bufnum), 1, 0, 0);
        var tartini = Tartini.kr(sig);
        var trig = Impulse.kr(25) * tartini[1];
        var time = Sweep.kr(1, 1);
        var count = Stepper.kr(trig, 0, 0, slots, 1, 0);
        BufWr.kr([Latch.kr(time, trig), Latch.kr(tartini[0], trig), Latch.kr(Amplitude.kr(sig), trig), 1],
            resultBuf, count, 0);
    });
    var score = List.new, t = 0.0, bufnum = 0, node = 1000;
    score.add([0.0, [\d_recv, def.asBytes]]);
    score.add([0.0, [\d_recv, pitchDef.asBytes]]);
    takes.do { |tk, i|
        var tapBuf = bufnum, res = bufnum + 1, pb = bufnum + 2, slots = (tk[\dur] * 25).ceil.asInteger + 16;
        bufnum = bufnum + 3;
        score.add([t + 0.001, [\b_allocReadChannel, tapBuf, tk[\file], tk[\startFrame], tk[\numFrames], 0]]);
        score.add([t + 0.002, [\b_alloc, res, maxOnsets + 1, 3]]);
        score.add([t + 0.002, [\b_alloc, pb, slots + 1, 4]]);
        score.add([t + 0.01, [\s_new, \scOnsets, node, 0, 0, \bufnum, tapBuf, \threshold, tk[\threshold], \resultBuf, res]]);
        score.add([t + 0.01, [\s_new, \scPitch, node + 1, 0, 0, \bufnum, tapBuf, \resultBuf, pb, \slots, slots]]);
        score.add([t + 0.01 + tk[\dur], [\n_free, node]]);
        score.add([t + 0.01 + tk[\dur], [\n_free, node + 1]]);
        score.add([t + 0.02 + tk[\dur], [\b_write, res, onPath.(i), "wav", "float", -1, 0, 0]]);
        score.add([t + 0.02 + tk[\dur], [\b_write, pb, pitchPath.(i), "wav", "float", -1, 0, 0]]);
        score.add([t + 0.03 + tk[\dur], [\b_free, res]]);
        score.add([t + 0.03 + tk[\dur], [\b_free, pb]]);
        score.add([t + 0.04 + tk[\dur], [\b_free, tapBuf]]);
        node = node + 2;
        t = t + tk[\dur] + 0.1;
    };
    score.add([t + 0.1, [\c_set, 0, 0]]);
    nrt.(score, outDir +/+ "render-out.wav");
};

// Amplitude.ar's own recursion (SC's attack/release coefficients, 20 dB).
follower = { |x, sr|
    var cA = exp(log(0.1) / (0.001 * sr)), cR = exp(log(0.1) / (0.1 * sr)), y = 0.0, out = Signal.newClear(x.size);
    x.do { |v, i|
        var a = v.abs;
        y = if(a > y) { a + (cA * (y - a)) } { a + (cR * (y - a)) };
        out[i] = y;
    };
    out
};
seg = { |x, sr, a, b|
    var i0 = (a * sr).round.asInteger.clip(0, x.size - 1), i1 = (b * sr).round.asInteger.clip(0, x.size - 1);
    x.copyRange(i0, i1.max(i0))
};
rmsOf = { |s| (s.squared.sum / s.size.max(1)).sqrt };

// Every candidate at every onset; `delta` maps onset time to audio time.
candidatesOf = { |onsets, x, foll, sr, delta|
    var ts = onsets.collect { |p| p[0] + delta };
    (cur: onsets.collect { |p| p[1] },
        ampAr: ts.collect { |t| foll[(t * sr).round.asInteger.clip(0, foll.size - 1)] },
        peak: ts.collect { |t| seg.(x, sr, t - 0.04, t + 0.03).abs.maxItem },
        rms: ts.collect { |t| rmsOf.(seg.(x, sr, t - 0.04, t + 0.03)) },
        rise: ts.collect { |t|
            var a = rmsOf.(seg.(x, sr, t - 0.04, t + 0.03)), b = rmsOf.(seg.(x, sr, t - 0.13, t - 0.05));
            (a.squared - b.squared).max(0).sqrt
        },
        rmsPre: ts.collect { |t| rmsOf.(seg.(x, sr, t - 0.05, t)) },
        rmsPre70: ts.collect { |t| rmsOf.(seg.(x, sr, t - 0.07, t)) },
        peakPre: ts.collect { |t| seg.(x, sr, t - 0.05, t).abs.maxItem })
};

// Log strengths, the take's mean removed; a floor of 5 % of the median.
normLog = { |s|
    var floor = ((median.(s) ? 0) * 0.05).max(1e-9), ls = s.collect { |v| (v.max(0) + floor).log };
    ls - ls.mean
};

// Pairs of onsets [i, j] at the same place in two regular bars of the label.
barPairs = { |lb, times, dur|
    var perUnit = 8 / lb[\denominator], barsE, nE, starts, m, tau0, fit, tau, phi, slot, pairs;
    barsE = MeterAnalyzer.barsOf(lb).collect { |b| (b * perUnit).round.asInteger };
    nE = barsE.sum;
    tau0 = (lb[\loopDur] ? dur) / nE;
    pairs = List.new;
    if(times.size >= 4) {
        fit = MeterAnalyzer.prPhaseFit(tau0, times);
        tau = fit[0];
        phi = fit[1];
        if(((tau - tau0).abs / tau0) > 0.03) { tau = tau0; phi = times[0] };
        phi = phi - ((phi / tau).round * tau);
        starts = barsE.inject([0], { |acc, b| acc.add(acc.last + b) }).drop(-1);
        m = barsE.maxItem { |b| barsE.occurrencesOf(b) };
        slot = Dictionary.new;
        times.do { |t, i|
            var p = ((t - phi) / tau).round.asInteger % nE, b = starts.size - 1;
            while { starts[b] > p } { b = b - 1 };
            if((barsE[b] == m) and: { slot[[b, p - starts[b]]].isNil }) { slot.put([b, p - starts[b]], i) };
        };
        barsE.size.do { |b1|
            barsE.size.do { |b2|
                if((b2 > b1) and: { barsE[b1] == m } and: { barsE[b2] == m }) {
                    m.do { |j|
                        if(slot[[b1, j]].notNil and: { slot[[b2, j]].notNil }) { pairs.add([slot[[b1, j]], slot[[b2, j]]]) };
                    };
                };
            };
        };
    };
    pairs.asArray
};

// The Looper's own path (as replay-session.scd's `analyse`).
analyse = { |tk, onsets, strengths, pitches|
    var first = if(onsets.isEmpty) { 0 } { onsets[0][0] };
    var rel = onsets.collect { |p| p[0] - first }, r;
    r = MeterAnalyzer.analyze(tk[\dur] - first, rel, strengths, leadIn: first, pitches: pitches);
    MeterDecision.snapAnalysisToLoop(r, tk[\dur])
};
sameReading = { |a, b|
    a.notNil and: { b.notNil }
        and: { a[\numerator] == b[\numerator] }
        and: { a[\denominator] == b[\denominator] }
        and: { (a[\k] ? 1) == (b[\k] ? 1) }
        and: { MeterAnalyzer.barsOf(a) == MeterAnalyzer.barsOf(b) }
};
gridSame = { |a, b|
    a.notNil and: { b.notNil } and: { sameReading.(a, b).not }
        and: { a[\bpm].notNil } and: { b[\bpm].notNil }
        and: { a[\numerator].notNil } and: { b[\numerator].notNil }
        and: { ((a[\bpm] - b[\bpm]).abs / a[\bpm].max(1e-6)) < 0.005 }
        and: { ((MeterAnalyzer.unitsOf(a) / a[\denominator])
            - (MeterAnalyzer.unitsOf(b) / b[\denominator])).abs < 1e-6 }
};
verdict = { |r, ref| case { ref.isNil } { nil } { sameReading.(r, ref) } { \yes } { gridSame.(r, ref) } { \grid } { \no } };
word = { |v| switch(v, \yes, { "yes" }, \grid, { "≈" }, \no, { "no" }, { "—" }) };

// --------------------------------------------------------------- takes --
synthSpecs = [["synth-damped-equal", true, false], ["synth-damped-graded", true, true],
    ["synth-ring-equal", false, false], ["synth-ring-graded", false, true]];
synthSpecs.do { |s|
    var path = outDir +/+ (s[0] ++ ".wav"), truth = makeSynth.(path, s[1], s[2]);
    takes.add((name: s[0], file: path, start: 0, dur: 8.0, group: \synth, threshold: 0.5,
        truthTimes: truth[0], truthAmps: truth[1], graded: s[2]));
};
(repo +/+ "training-data/*.wav").pathMatch.sort.do { |wav|
    var parts = PathName(wav).fileNameWithoutExtension.split($_);
    var sig = parts[1].split($-);
    var sf = SoundFile.openRead(wav);
    var dur = sf.numFrames / sf.sampleRate, num = sig[0].asInteger, den = sig[1].asInteger, k = parts[2].drop(-4).asInteger;
    sf.close;
    takes.add((name: parts[0], file: wav, start: 0, dur: dur, group: \truth, threshold: 0.5, fallback: "7/8",
        label: (numerator: num, denominator: den, k: k, loopDur: dur, bpm: (240 * num * k) / (den * dur))));
};
(LooperSessionRecorder.globQuote(repo +/+ "sessions") +/+ "*-events.jsonl").pathMatch.sort.do { |path|
    var events = LooperSessionRecorder.readEvents(path);
    var audio = events.detect { |e| e[\ev] == "audio" };
    var header = events.detect { |e| e[\ev] == "session" } ? ();
    var tap = LooperSessionRecorder.sessionPath(events, \tap, path);
    LooperSessionRecorder.takesFrom(events).do { |tk|
        var lb = tk[\label];
        if((tk[\kind] == \take) and: { lb.notNil } and: { lb[\numerator].notNil } and: { lb[\error].isNil }
            and: { audio.notNil } and: { tk[\start].notNil } and: { tk[\dur].notNil }
            and: { tap.notNil } and: { File.exists(tap) }) {
            takes.add((name: PathName(path).fileName.keep(13), file: tap, start: tk[\start] - audio[\t],
                dur: tk[\dur], label: lb, group: if(tk[\outcome] == \corrected) { \hand } { \played },
                threshold: (tk[\threshold] ? header[\threshold] ? 0.5).asFloat,
                logged: tk[\onsets].asArray.collect { |p| [p[0].asFloat, p[1].asFloat] },
                pitches: tk[\pitches], stage: tk[\result],
                fallback: header[\fallback] ? "7/8", fallbackBars: header[\fallbackBars] ? 0));
        };
    };
};
takes = takes.select { |tk|
    var sf = SoundFile.openRead(tk[\file]), ok = false;
    if(sf.notNil) {
        tk[\sr] = sf.sampleRate;
        tk[\chans] = sf.numChannels;
        tk[\startFrame] = (tk[\start] * sf.sampleRate).round.asInteger;
        tk[\numFrames] = (tk[\dur] * sf.sampleRate).round.asInteger;
        ok = (tk[\startFrame] >= 0) and: { (tk[\startFrame] + tk[\numFrames]) <= sf.numFrames };
        sf.close;
    };
    if(ok.not) { ("skipped " ++ tk[\name]).postln };
    ok
};
("takes: " ++ takes.size).postln;

"rendering...".postln;
render.();

takes.do { |tk, i|
    var rendered = readSlots.(onPath.(i)), x = readAudio.(tk), offs, foll;
    tk[\renderedPitches] = readPitchSlots.(pitchPath.(i));
    if(tk[\logged].notNil and: { tk[\logged].notEmpty }) {
        tk[\onsets] = tk[\logged];
        offs = tk[\logged].collect { |p|
            var nr = rendered.minItem { |q| (q[0] - p[0]).abs };
            if(nr.notNil and: { (nr[0] - p[0]).abs < 0.04 }) { nr[0] - p[0] }
        }.reject { |o| o.isNil };
        tk[\delta] = median.(offs) ? 0;
        tk[\matched] = offs.size;
    } {
        tk[\onsets] = rendered;
        tk[\delta] = 0;
    };
    foll = follower.(x, tk[\sr]);
    tk[\cands] = candidatesOf.(tk[\onsets], x, foll, tk[\sr], tk[\delta]);
};

// ------------------------------------------------ (a) synthetic levels --
"".postln;
"=== (a) Synthetic plucks: equal hits should read equal, graded hits in order ===".postln;
"equal: spread of the strengths in dB (std; lower is better); graded: rank correlation with the true level".postln;
("take".padRight(22) ++ "hits".padLeft(5) ++ cands.collect { |c| c.asString.padLeft(9) }.join).postln;
takes.select { |tk| tk[\group] == \synth }.do { |tk|
    var matched = tk[\onsets].collect { |p|
        var d = tk[\truthTimes].collect { |s| (p[0] - s).abs };
        var j = d.minIndex;
        if(d[j] < 0.06) { j }
    };
    var idx = matched.collect { |j, i| if(j.notNil) { i } }.reject { |i| i.isNil };
    var cells = cands.collect { |c|
        var s = idx.collect { |i| tk[\cands][c][i] }, truth = idx.collect { |i| tk[\truthAmps][matched[i]] }, db;
        if(tk[\graded]) { spearman.(s, truth) !? { |r| r.round(0.01) } ? "—" } {
            db = s.collect { |v| v.max(1e-9).ampdb };
            (((db - db.mean).squared.mean).sqrt).round(0.1).asString ++ " dB"
        }
    };
    (tk[\name].padRight(22) ++ (idx.size.asString ++ "/28").padLeft(5)
        ++ cells.collect { |c| c.asString.padLeft(9) }.join).postln;
};

// ------------------------------------------------- (b) repeatability --
"".postln;
"=== (b) Repeatability: the same place in two regular bars of a labelled riff ===".postln;
"correlation of per-take normalised log strengths over all such pairs (higher is better)".postln;
{
    var real = takes.select { |tk| tk[\group] != \synth };
    var sets = [["all labelled", real], ["hand + training", real.select { |tk| #[\hand, \truth].includes(tk[\group]) }]];
    real.do { |tk| tk[\pairs] = barPairs.(tk[\label], tk[\onsets].collect { |p| p[0] }, tk[\dur]) };
    sets.do { |st|
        var line = st[0].padRight(18) ++ ("pairs " ++ st[1].collect { |tk| tk[\pairs].size }.sum).padRight(10);
        cands.do { |c|
            var xs = List.new, ys = List.new;
            st[1].do { |tk|
                var nl = normLog.(tk[\cands][c]);
                tk[\pairs].do { |pr| xs.add(nl[pr[0]]); ys.add(nl[pr[1]]) };
            };
            line = line ++ (c.asString ++ " " ++ corrSafe.(xs, ys)).padLeft(12);
        };
        line.postln;
    };
    ("per take (pairs; " ++ cands.join(" / ") ++ "):").postln;
    real.select { |tk| tk[\pairs].size >= 4 }.do { |tk|
        ("  " ++ tk[\name].padRight(14) ++ MeterAnalyzer.sigString(tk[\label]).padRight(12)
            ++ tk[\pairs].size.asString.padLeft(4) ++ "   "
            ++ cands.collect { |c|
                var nl = normLog.(tk[\cands][c]);
                corrSafe.(tk[\pairs].collect { |pr| nl[pr[0]] }, tk[\pairs].collect { |pr| nl[pr[1]] }).padLeft(6)
            }.join).postln;
    };
}.value;

// ------------------------------------------------------ (c) readings --
"".postln;
"=== (c) The analyser's readings against the labels ===".postln;
{
    var real = takes.select { |tk| tk[\group] != \synth };
    var variants = [\none] ++ cands;
    var saved = [MeterAnalyzer.fallbackNum, MeterAnalyzer.fallbackDenom, MeterAnalyzer.fallbackBars];
    real.do { |tk|
        var parts = tk[\fallback].asString.split($/);
        var pitches = if(tk[\pitches].notNil and: { tk[\pitches].notEmpty }) { tk[\pitches] } { tk[\renderedPitches] };
        if(parts.size == 2) { MeterAnalyzer.fallbackNum = parts[0].asInteger; MeterAnalyzer.fallbackDenom = parts[1].asInteger };
        MeterAnalyzer.fallbackBars = tk[\fallbackBars] ? 0;
        tk[\readings] = variants.collect { |v|
            var r = analyse.(tk, tk[\onsets], if(v == \none) { nil } { tk[\cands][v] }, pitches);
            [r, verdict.(r, tk[\label])]
        };
    };
    MeterAnalyzer.fallbackNum = saved[0];
    MeterAnalyzer.fallbackDenom = saved[1];
    MeterAnalyzer.fallbackBars = saved[2];
    ("take".padRight(14) ++ "group".padRight(7) ++ "label".padRight(16) ++ "onsets".padLeft(7) ++ "  δ ms"
        ++ variants.collect { |v| v.asString.padLeft(7) }.join ++ "   cur's reading / the stage's").postln;
    real.do { |tk|
        ("" ++ tk[\name].padRight(14) ++ tk[\group].asString.padRight(7)
            ++ (MeterAnalyzer.sigString(tk[\label]) ++ " x" ++ (tk[\label][\k] ? 1)).padRight(16)
            ++ tk[\onsets].size.asString.padLeft(7) ++ (tk[\delta] * 1000).round(0.1).asString.padLeft(6)
            ++ tk[\readings].collect { |rv| word.(rv[1]).padLeft(7) }.join
            ++ "   " ++ fmtReading.(tk[\readings][1][0])
            ++ (tk[\stage] !? { |s| " / " ++ fmtReading.(s) } ? "")).postln;
    };
    "".postln;
    [["corrected by hand", \hand], ["training-data", \truth], ["played on (label = the stage's reading)", \played]].do { |g|
        var sel = real.select { |tk| tk[\group] == g[1] };
        (g[0] ++ " (" ++ sel.size ++ "): " ++ variants.collect { |v, k|
            v.asString ++ " " ++ sel.count { |tk| tk[\readings][k][1] == \yes }
                ++ (sel.count { |tk| tk[\readings][k][1] == \grid } !? { |n| if(n > 0) { "+" ++ n ++ "≈" } { "" } })
        }.join(", ")).postln;
    };
}.value;
"".postln;
"done".postln;
0.exit;
)
