// flux-evidence.scd: step 1 of the onset-curve experiment (2026-11-05).
//
// Is there rhythmic evidence below the onset threshold? For every labelled
// take: the recorder's own onset chain (Looper.prOnsetTrig) at 0.5 and 0.2 in
// NRT, and a log spectral flux curve of the same audio (sclang STFT), both
// folded onto the label's eighth-note grid. The curve's peaks that 0.5 did not
// detect, away from every detected hit (60 ms before to the 107 ms mingap
// after), either land on the grid more often than chance (quiet real hits: a
// curve would add evidence) or not (noise: it would not). Chance is exact: the
// share of the take's allowed time that lies on the grid.
//
// Two synthetic takes check the measurement itself: quiet hits on the grid
// (must show lift), quiet hits at random times (must not).
//
// Run: sclang -u 58xxx scripts/flux-evidence.scd   (a far port: see the launcher)
//      FLUX_REUSE=1 sclang ...   reuses the render and the cached peaks
// First run 2026-11-05: free peaks on the grid 1.2x chance over 15 real takes,
// about 19 % more evidence than the 0.5 onsets; most of the curve is off-grid.
(
var repo = thisProcess.nowExecutingPath !? { |p| p.dirname.dirname } ?? { Looper.repoRoot };
var outDir = (Platform.defaultTempDir ? "/tmp") +/+ "megalooper-flux";
var scsynth = MegaSAPlugins.scsynthPath;
var thrs = [0.2, 0.5];
var maxOnsets = 4096;
var fftN = 1024, hop = 256;
var minDur = 2.5;
var detWin = 0.035, preEx = 0.06, postEx = 0.107, tightTol = 0.025;
var takes = List.new, rows = List.new;
var render, resPath, readSlots, readAudio, fluxOf, peaksOf, analyseTake, ranks, spearman, median;
var pct, fmtLift, fmtNum, synth, binOf, csv, groups, pooled;
var peaksPath, savePeaks, loadPeaks, reuse = "FLUX_REUSE".getenv == "1";

if(File.exists(outDir).not) { File.mkdir(outDir) };
thisThread.randSeed = 20261105;
// A runtime error stops the script before its 0.exit; this ends sclang anyway.
AppClock.sched(180, { "watchdog: exiting".postln; 1.exit; nil });

median = { |a| var s = a.asArray.copy.sort; if(s.isEmpty) { nil } { s[s.size div: 2] } };
ranks = { |a| var ord = a.asArray.order, r = Array.newClear(a.size); ord.do { |idx, k| r[idx] = k }; r };
spearman = { |a, b| if(a.size < 4) { nil } { MeterAnalyzer.corr(ranks.(a), ranks.(b)) } };
pct = { |x| if(x.isNil) { "—" } { (x * 100).round.asInteger.asString ++ "%" } };
fmtLift = { |x| if(x.isNil) { "—" } { x.asFloat.asStringPrec(2) ++ "x" } };
fmtNum = { |x, p = 2| if(x.isNil) { "—" } { x.asFloat.asStringPrec(p) } };
resPath = { |i, j| outDir +/+ ("take" ++ i ++ "-thr" ++ j ++ ".wav") };
binOf = { |d| ((d + 0.5) * 10).floor.asInteger.clip(0, 9) };
peaksPath = { |i| outDir +/+ ("peaks" ++ i ++ ".txt") };
savePeaks = { |i, pk| var f = File(peaksPath.(i), "w"); pk.do { |p| f.write(p.join(",") ++ "\n") }; f.close };
loadPeaks = { |i|
    File.readAllString(peaksPath.(i)).split($\n).reject { |l| l.isEmpty }
        .collect { |l| l.split($,).collect { |v| v.asFloat } }
};

// ------------------------------------------------------------ synthetic --
synth = { |path, quietOnGrid|
    var srS = 48000, eighth = 0.3, total = (8.5 * srS).asInteger;
    var sig = Signal.fill(total, { 1e-4.rand2 });
    var heads = [0, 2, 4], burst, sf;
    burst = { |at, amp|
        var start = (at * srS).round.asInteger, len = (0.1 * srS).asInteger;
        var attack = 0.002 * srS, decay = 0.03 * srS;
        len.do { |i|
            var env = (i / attack).min(1) * exp(i.neg / decay);
            if((start + i) < total) { sig[start + i] = sig[start + i] + (1.0.rand2 * env * amp) };
        };
    };
    28.do { |e|
        var t = 0.05 + (e * eighth);
        if(heads.includes(e % 7)) { burst.(t, 0.5) } { if(quietOnGrid) { burst.(t, 0.01) } };
    };
    if(quietOnGrid.not) { 16.do { burst.(0.05 + 8.3.rand, 0.01) } };
    sf = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(1).sampleRate_(srS);
    sf.openWrite(path);
    sf.writeData(sig);
    sf.close;
};
synth.(outDir +/+ "synth-ongrid.wav", true);
synth.(outDir +/+ "synth-random.wav", false);
[["synth-ongrid", true], ["synth-random", false]].do { |pr|
    takes.add((name: pr[0], file: outDir +/+ (pr[0] ++ ".wav"), start: 0, dur: 8.5, group: \synth,
        label: (numerator: 7, denominator: 8, k: 4, bpm: 100, loopDur: 8.4)));
};

// ------------------------------------------------------- labelled takes --
(repo +/+ "training-data/*.wav").pathMatch.sort.do { |wav|
    var parts = PathName(wav).fileNameWithoutExtension.split($_);
    var sig = parts[1].split($-);
    var sf = SoundFile.openRead(wav);
    var dur = sf.numFrames / sf.sampleRate;
    sf.close;
    takes.add((name: parts[0], file: wav, start: 0, dur: dur, group: \truth,
        label: (numerator: sig[0].asInteger, denominator: sig[1].asInteger,
            k: parts[2].drop(-4).asInteger, bpm: parts[3].drop(-3).asFloat, loopDur: dur)));
};
(LooperSessionRecorder.globQuote(repo +/+ "sessions") +/+ "*-events.jsonl").pathMatch.sort.do { |path|
    var events = LooperSessionRecorder.readEvents(path);
    var audio = events.detect { |e| e[\ev] == "audio" };
    var tap = LooperSessionRecorder.sessionPath(events, \tap, path);
    LooperSessionRecorder.takesFrom(events).do { |tk|
        var lb = tk[\label];
        if((tk[\kind] == \take) and: { lb.notNil } and: { lb[\numerator].notNil } and: { lb[\error].isNil }
            and: { (tk[\dur] ? 0) >= minDur } and: { audio.notNil } and: { tk[\start].notNil }
            and: { tap.notNil } and: { File.exists(tap) }) {
            takes.add((name: PathName(path).fileName.keep(13), file: tap, start: tk[\start] - audio[\t],
                dur: tk[\dur], label: lb, group: if(tk[\outcome] == \corrected) { \hand } { \played }));
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

// ------------------------------------------------------------ the render --
render = {
    var def = SynthDef(\fluxOnsets, { |bufnum = 0, threshold = 0.5, resultBuf = 1|
        var sig = PlayBuf.ar(1, bufnum, BufRateScale.kr(bufnum), 1, 0, 0);
        var trig = Looper.prOnsetTrig(sig, threshold);
        var time = Sweep.kr(1, 1);
        // the strength as the recorder read it until 2026-11-05 (what this script measured)
        var strength = Amplitude.kr(sig, 0.001, 0.1);
        var count = Stepper.kr(trig, 0, 0, maxOnsets, 1, 0);
        BufWr.kr([Latch.kr(time, trig), Latch.kr(strength, trig), 1], resultBuf, count, 0);
    });
    var score = List.new, t = 0.0, bufnum = 0, node = 1000;
    var osc = outDir +/+ "flux.osc", dummy = outDir +/+ "flux-out.wav", cmd, said;
    score.add([0.0, [\d_recv, def.asBytes]]);
    takes.do { |tk, i|
        var tapBuf = bufnum;
        bufnum = bufnum + 1;
        score.add([t + 0.001, [\b_allocReadChannel, tapBuf, tk[\file], tk[\startFrame], tk[\numFrames], 0]]);
        thrs.do { |thr, j|
            var res = bufnum;
            bufnum = bufnum + 1;
            score.add([t + 0.002, [\b_alloc, res, maxOnsets + 1, 3]]);
            score.add([t + 0.01, [\s_new, \fluxOnsets, node, 0, 0,
                \bufnum, tapBuf, \threshold, thr, \resultBuf, res]]);
            score.add([t + 0.01 + tk[\dur], [\n_free, node]]);
            score.add([t + 0.02 + tk[\dur], [\b_write, res, resPath.(i, j), "wav", "float", -1, 0, 0]]);
            score.add([t + 0.03 + tk[\dur], [\b_free, res]]);
            node = node + 1;
        };
        score.add([t + 0.04 + tk[\dur], [\b_free, tapBuf]]);
        t = t + tk[\dur] + 0.1;
    };
    score.add([t + 0.1, [\c_set, 0, 0]]);
    Score(score.asArray.sort { |a, b| a[0] <= b[0] }).writeOSCFile(osc);
    cmd = scsynth.quote ++ " -N " ++ osc.quote ++ " _ " ++ dummy.quote
        ++ " 48000 WAV int16 -o 1 -i 0 -u " ++ (58100 + 800.rand) ++ " 2>&1";
    said = cmd.unixCmdGetStdOut;
    if(said.contains("exception") or: { said.contains("ERROR") } or: { said.contains("FAILURE") }) {
        ("scsynth said:\n" ++ said).warn;
    };
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

readAudio = { |tk|
    var sf = SoundFile.openRead(tk[\file]), ch = tk[\chans], n = tk[\numFrames], data;
    sf.seek(tk[\startFrame], 0);
    data = FloatArray.newClear(n * ch);
    sf.readData(data);
    sf.close;
    if(ch == 1) { Signal.newFrom(data) } { Signal.fill(n, { |i| data[i * ch] }) }
};

// Log-magnitude positive spectral flux, one value per hop, frame f centred
// at (f * hop + fftN / 2) / sr. The take is peak-normalised first.
fluxOf = { |x|
    var win = Signal.hanningWindow(fftN), cosT = Signal.fftCosTable(fftN), half = fftN div: 2;
    var nF = ((x.size - fftN) div: hop) + 1, prev, out, xs;
    xs = x * (1 / x.peak.max(1e-9));
    out = Array.fill(nF.max(0), 0.0);
    nF.do { |f|
        var seg = xs.copyRange(f * hop, (f * hop) + fftN - 1) * win;
        var c = seg.fft(Signal.newClear(fftN), cosT);
        var re = c.real.copyRange(0, half), im = c.imag.copyRange(0, half);
        var lm = ((re.squared + im.squared).sqrt + 1).log;
        if(prev.notNil) { out[f] = (lm - prev).max(0).sum };
        prev = lm;
    };
    out
};

// Local maxima over +-8 hops (~43 ms), weight = height over the minimum of
// the 8 hops before; peaks under 2 % of the take's largest flux dropped.
peaksOf = { |flux, sr|
    var w = 8, out = List.new, maxF = flux.maxItem.max(1e-9), last = flux.size - 1;
    flux.do { |v, f|
        var lo = (f - w).max(0), hi = (f + w).min(last), isMax;
        isMax = (v > 0) and: { v >= flux.copyRange(lo, hi).maxItem } and: { (f == 0) or: { v > flux[f - 1] } };
        if(isMax) { out.add([((f * hop) + (fftN div: 2)) / sr, v - flux.copyRange(lo, f).minItem, v]) };
    };
    out.asArray.select { |p| p[2] >= (0.02 * maxF) }
};

// ------------------------------------------------------------ one take --
analyseTake = { |tk|
    var on05 = tk[\on][1], on02 = tk[\on][0];
    var t05 = on05.collect { |p| p[0] }, t02 = on02.collect { |p| p[0] };
    var lb = tk[\label], dur = tk[\dur], sr = tk[\sr], x = tk[\x];
    var loopDur = lb[\loopDur] ? dur;
    var tau0 = loopDur / (MeterAnalyzer.unitsOf(lb) * (8 / lb[\denominator]));
    var fit, tau, phi, ps, offs, offset, tolRel, tolAbs, tightRel, devOf, excluded, near05, onAt;
    var peaks, free, det, step = 0.002, nT, allowed, allowedCount, chance, chanceTight;
    var onFree, onFreeTight, wFree, wOnFree, wDet, gridFit05, p0, p1, pulses, empty, filled, expected, lambda;
    var extras, extrasAllowed, extrasOn, caught, strengths, truePk, fluxAt, nullBins, ea, eb, expVar;
    if(t05.size < 4) { ("too few onsets at 0.5: " ++ tk[\name] ++ " (" ++ t05.size ++ ")").postln; nil } {
        fit = MeterAnalyzer.prPhaseFit(tau0, t05);
        tau = fit[0];
        phi = fit[1];
        if(((tau - tau0).abs / tau0) > 0.03) {
            tau = tau0;
            phi = t05[0];
            4.do { ps = t05.collect { |t| ((t - phi) / tau).round }; phi = (t05 - (ps * tau)).mean };
        };
        devOf = { |t| var d = (t - phi) / tau; d - d.round };
        tolRel = 0.2.min(0.06 / tau);
        tolAbs = tolRel * tau;
        tightRel = tightTol / tau;
        onAt = { |t, tl| devOf.(t).abs < tl };
        // the flux peaks in the onsets' time base
        offs = t05.collect { |t|
            var nr = tk[\peaks].minItem { |p| (p[0] - t).abs };
            if(nr.notNil and: { (nr[0] - t).abs < 0.04 }) { nr[0] - t }
        }.reject { |o| o.isNil };
        offset = median.(offs) ? 0;
        peaks = tk[\peaks].collect { |p| [p[0] - offset, p[1]] };
        excluded = { |t| t05.any { |o| (t >= (o - preEx)) and: { t <= (o + postEx) } } };
        near05 = { |t| t05.any { |o| (t - o).abs < detWin } };
        free = peaks.reject { |p| excluded.(p[0]) };
        det = peaks.select { |p| near05.(p[0]) };
        wDet = det.collect { |p| p[1] }.sum;
        // exact chance: the allowed time on the grid
        nT = (dur / step).floor.asInteger;
        allowed = Array.fill(nT, true);
        t05.do { |o|
            ea = ((o - preEx) / step).floor.asInteger.max(0);
            eb = ((o + postEx) / step).ceil.asInteger.min(nT - 1);
            if(ea <= eb) { (ea..eb).do { |k| allowed[k] = false } };
        };
        allowedCount = allowed.count { |a| a };
        chance = Array.fill(nT, { |k| allowed[k] and: { onAt.(k * step, tolRel) } }).count { |a| a } / allowedCount.max(1);
        chanceTight = Array.fill(nT, { |k| allowed[k] and: { onAt.(k * step, tightRel) } }).count { |a| a } / allowedCount.max(1);
        nullBins = Array.fill(10, 0);
        nT.do { |k| if(allowed[k]) { nullBins[binOf.(devOf.(k * step))] = nullBins[binOf.(devOf.(k * step))] + 1 } };
        nullBins = nullBins / allowedCount.max(1);
        onFree = free.count { |p| onAt.(p[0], tolRel) } / free.size.max(1);
        onFreeTight = free.count { |p| onAt.(p[0], tightRel) } / free.size.max(1);
        wFree = free.collect { |p| p[1] }.sum;
        wOnFree = free.select { |p| onAt.(p[0], tolRel) }.collect { |p| p[1] }.sum;
        gridFit05 = t05.count { |t| onAt.(t, tolRel) } / t05.size;
        // the pulses no 0.5 onset sits on, and how many a free peak fills
        p0 = ((0 - phi) / tau).ceil.asInteger;
        p1 = ((dur - phi) / tau).floor.asInteger;
        pulses = (p0..p1).collect { |p| phi + (p * tau) }.select { |tp| (tp >= 0) and: { tp < dur } };
        empty = pulses.select { |tp| t05.every { |o| (o - tp).abs >= tolAbs } };
        filled = empty.count { |tp| free.any { |p| (p[0] - tp).abs < tolAbs } };
        lambda = free.size / (allowedCount * step).max(1e-9);
        expected = empty.collect { |tp|
            var a = ((tp - tolAbs) / step).floor.asInteger.max(0);
            var b = ((tp + tolAbs) / step).ceil.asInteger.min(nT - 1);
            var len = 0;
            if(a <= b) { (a..b).do { |k| if(allowed[k]) { len = len + step } } };
            1 - exp(lambda.neg * len)
        };
        expVar = expected.collect { |q| q * (1 - q) }.sum;
        expected = expected.sum;
        // what a 0.2 threshold adds
        extras = t02.reject { |t| near05.(t) };
        extrasAllowed = extras.reject { |t| excluded.(t) };
        extrasOn = if(extrasAllowed.isEmpty) { nil } { extrasAllowed.count { |t| onAt.(t, tolRel) } / extrasAllowed.size };
        caught = free.select { |p| onAt.(p[0], tolRel) }.count { |p| t02.any { |o| (o - p[0]).abs < detWin } };
        // the strengths against the take's own peak level
        strengths = on05.collect { |p| p[1] };
        truePk = t05.collect { |t|
            var a = ((t - 0.04) * sr).round.asInteger.max(0);
            var b = ((t + 0.03) * sr).round.asInteger.min(x.size - 1);
            x.copyRange(a, b).abs.maxItem
        };
        fluxAt = t05.collect { |t|
            var nr = peaks.minItem { |p| (p[0] - t).abs };
            if(nr.notNil and: { (nr[0] - t).abs < detWin }) { nr[1] } { 0 }
        };
        (name: tk[\name], group: tk[\group], sig: MeterAnalyzer.sigString(lb) ++ " x" ++ (lb[\k] ? 1),
            tau: tau, tauDrift: (tau - tau0) / tau0, n05: t05.size, n02: t02.size, gridFit05: gridFit05,
            nPeaks: peaks.size, nDet: det.size, nFree: free.size, chance: chance, chanceTight: chanceTight,
            onFree: onFree, onFreeTight: onFreeTight, liftN: onFree / chance.max(1e-9),
            liftTight: onFreeTight / chanceTight.max(1e-9),
            liftW: (wOnFree / wFree.max(1e-9)) / chance.max(1e-9),
            wOnFreeRel: wOnFree / wDet.max(1e-9), nOnFree: free.count { |p| onAt.(p[0], tolRel) },
            nEmpty: empty.size, nPulses: pulses.size, filled: filled, expected: expected, expVar: expVar,
            nExtras: extras.size, nExtrasAllowed: extrasAllowed.size, extrasOn: extrasOn, caught: caught,
            offsetMs: offset * 1000, rhoAmp: spearman.(strengths, truePk), rhoFlux: spearman.(truePk, fluxAt),
            rangeAmp: (strengths.maxItem / strengths.minItem.max(1e-9)).ampdb,
            rangePk: (truePk.maxItem / truePk.minItem.max(1e-9)).ampdb,
            freeDevs: free.collect { |p| [devOf.(p[0]), p[1], onAt.(p[0], tolRel)] },
            detDevs: t05.collect { |t| devOf.(t) }, nullBins: nullBins, tolRel: tolRel,
            freeAt: free.collect { |p| p[0] })
    }
};

// ------------------------------------------------------------------ run --
if(reuse and: { takes.size.collect { |i| File.exists(resPath.(i, 1)) }.every { |b| b } }) {
    "reusing the onset render".postln;
} {
    "rendering onsets (NRT)...".postln;
    render.();
};
takes.do { |tk, i|
    var r, t0 = Main.elapsedTime, cached = reuse and: { File.exists(peaksPath.(i)) };
    tk[\on] = thrs.collect { |thr, j| readSlots.(resPath.(i, j)) };
    tk[\x] = readAudio.(tk);
    tk[\peaks] = if(cached) { loadPeaks.(i) } { peaksOf.(fluxOf.(tk[\x]), tk[\sr]) };
    if(cached.not) { savePeaks.(i, tk[\peaks]) };
    r = analyseTake.(tk);
    ("take " ++ i ++ " " ++ tk[\name] ++ (if(cached) { " (cached peaks)" } { "" }) ++ ": "
        ++ (Main.elapsedTime - t0).round(0.1) ++ " s").postln;
    if(r.notNil) { rows.add(r) };
    tk[\x] = nil;
};

csv = File(outDir +/+ "free-peaks.csv", "w");
csv.write("take,group,t,weight,dev,onGrid\n");
rows.do { |r|
    r[\freeDevs].do { |fd, k|
        csv.write([r[\name], r[\group], r[\freeAt][k].round(0.0001), fd[1].round(0.001), fd[0].round(0.001),
            if(fd[2]) { 1 } { 0 }].join(",") ++ "\n");
    };
};
csv.close;

"".postln;
"=== Grid evidence below the 0.5 threshold ===".postln;
"free = flux peaks no 0.5 onset accounts for (none from 60 ms before to 107 ms after one)".postln;
"on-grid = within the analyser's tolerance of the label's eighth grid; chance = the allowed time on the grid".postln;
"".postln;
([ "take".padRight(14), "group".padRight(7), "label".padRight(16), "8th ms".padLeft(6), "n.5".padLeft(4),
    "fit.5".padLeft(6), "peaks".padLeft(6), "free".padLeft(5), "on-grid".padLeft(8), "chance".padLeft(7),
    "lift".padLeft(6), "lift25".padLeft(7), "liftW".padLeft(6), "wOn/wDet".padLeft(9),
    "empty".padLeft(6), "filled".padLeft(7), "exp".padLeft(5), "0.2+".padLeft(5), "on".padLeft(5), "caught".padLeft(7) ].join(" ")).postln;
rows.do { |r|
    ([ r[\name].padRight(14), r[\group].asString.padRight(7), r[\sig].padRight(16),
        (r[\tau] * 1000).round.asInteger.asString.padLeft(6), r[\n05].asString.padLeft(4),
        pct.(r[\gridFit05]).padLeft(6), r[\nPeaks].asString.padLeft(6), r[\nFree].asString.padLeft(5),
        pct.(r[\onFree]).padLeft(8), pct.(r[\chance]).padLeft(7), fmtLift.(r[\liftN]).padLeft(6),
        fmtLift.(r[\liftTight]).padLeft(7), fmtLift.(r[\liftW]).padLeft(6), pct.(r[\wOnFreeRel]).padLeft(9),
        (r[\nEmpty].asString ++ "/" ++ r[\nPulses]).padLeft(6), r[\filled].asString.padLeft(7),
        fmtNum.(r[\expected], 2).padLeft(5), r[\nExtrasAllowed].asString.padLeft(5), pct.(r[\extrasOn]).padLeft(5),
        r[\caught].asString.padLeft(7) ].join(" ")).postln;
};

"".postln;
"=== Pooled ===".postln;
groups = [[\synth, "synthetic"], [\hand, "corrected by hand"], [\truth, "training-data"], [\played, "played on (weak label)"]];
pooled = { |sel, title|
    var nFree = sel.collect { |r| r[\nFree] }.sum;
    var nOn = sel.collect { |r| r[\nOnFree] }.sum;
    var expOn = sel.collect { |r| r[\chance] * r[\nFree] }.sum;
    var wOnW = sel.collect { |r| r[\liftW] * r[\chance] * r[\nFree] }.sum;
    var emp = sel.collect { |r| r[\nEmpty] }.sum, fil = sel.collect { |r| r[\filled] }.sum;
    var expF = sel.collect { |r| r[\expected] }.sum;
    var varOn = sel.collect { |r| r[\chance] * (1 - r[\chance]) * r[\nFree] }.sum;
    var varF = sel.collect { |r| r[\expVar] }.sum;
    var n05 = sel.collect { |r| r[\n05] }.sum;
    var obs = Array.fill(10, 0.0), nul = Array.fill(10, 0.0), det = Array.fill(10, 0.0), nDet = 0;
    sel.do { |r|
        r[\freeDevs].do { |fd| obs[binOf.(fd[0])] = obs[binOf.(fd[0])] + 1 };
        nul = nul + (r[\nullBins] * r[\nFree]);
        r[\detDevs].do { |d| det[binOf.(d)] = det[binOf.(d)] + 1 };
        nDet = nDet + r[\detDevs].size;
    };
    (title ++ ": " ++ sel.size ++ " takes, " ++ nFree ++ " free peaks, " ++ nOn ++ " on the grid where chance gives "
        ++ expOn.round(0.1) ++ " (lift " ++ fmtLift.(nOn / expOn.max(1e-9)) ++ ", by weight "
        ++ fmtLift.(wOnW / expOn.max(1e-9)) ++ "); empty pulses " ++ emp ++ ", filled " ++ fil
        ++ " where chance gives " ++ expF.round(0.1)).postln;
    ("  z on-grid " ++ fmtNum.((nOn - expOn) / varOn.max(1e-9).sqrt) ++ ", z filled "
        ++ fmtNum.((fil - expF) / varF.max(1e-9).sqrt) ++ "; excess filled pulses " ++ (fil - expF).round(0.1)
        ++ " beside " ++ n05 ++ " onsets at 0.5 (" ++ pct.((fil - expF) / n05.max(1)) ++ " more evidence)").postln;
    "  position in the eighth   free peaks   chance   0.5 onsets".postln;
    10.do { |b|
        var lo = (b / 10) - 0.5;
        var o = obs[b] / nFree.max(1), nl = nul[b] / nFree.max(1), dt = det[b] / nDet.max(1);
        ("  " ++ (lo.round(0.1).asString ++ ".." ++ (lo + 0.1).round(0.1).asString).padRight(12)
            ++ pct.(o).padLeft(10) ++ " " ++ "".padRight((o * 60).round.asInteger, "#").padRight(14)
            ++ pct.(nl).padLeft(6) ++ pct.(dt).padLeft(10)).postln;
    };
    "".postln;
};
groups.do { |g|
    var sel = rows.select { |r| r[\group] == g[0] };
    if(sel.notEmpty) { pooled.(sel, g[1]) };
};
pooled.(rows.select { |r| r[\group] != \synth }, "all real takes");

"=== The onset strengths: Amplitude.kr at the trigger vs the take's own peak ===".postln;
"rho = rank correlation; range = loudest over softest, dB".postln;
([ "take".padRight(14), "n.5".padLeft(4), "rho(str,peak)".padLeft(14), "rho(peak,flux)".padLeft(15),
    "range str".padLeft(10), "range peak".padLeft(11), "offset ms".padLeft(10), "8th drift".padLeft(10) ].join(" ")).postln;
rows.do { |r|
    ([ r[\name].padRight(14), r[\n05].asString.padLeft(4), fmtNum.(r[\rhoAmp]).padLeft(14),
        fmtNum.(r[\rhoFlux]).padLeft(15), (r[\rangeAmp].round(0.1).asString ++ " dB").padLeft(10),
        (r[\rangePk].round(0.1).asString ++ " dB").padLeft(11), r[\offsetMs].round(0.1).asString.padLeft(10),
        pct.(r[\tauDrift]).padLeft(10) ].join(" ")).postln;
};
{
    var real = rows.select { |r| (r[\group] != \synth) and: { r[\rhoAmp].notNil } };
    ("median rho(str,peak) over real takes: " ++ fmtNum.(median.(real.collect { |r| r[\rhoAmp] }))
        ++ "; median rho(peak,flux): " ++ fmtNum.(median.(real.collect { |r| r[\rhoFlux] }))).postln;
}.value;
("peaks csv: " ++ (outDir +/+ "free-peaks.csv")).postln;
0.exit;
)
