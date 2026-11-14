// The loop's key and scale, offline, for the note sequencer (2026-11-14;
// docs/dev/synth.md "Key from the loop"): one scale for the whole loop. Every
// take there is, through these guesses side by side:
//   ks   PitchAnalyzer today: Krumhansl-Schmuckler major/minor on the take's
//        Tartini readings (25 Hz, one note at a time)
//   T    the note set the Tartini readings use: of every transposition of the
//        scale families below, the one holding the most of the take's weight
//        for the fewest notes (each note of the set costs `lambda`); then the
//        root among its notes from the cues (`mu`), which names the mode;
//        rarer families and modes cost a little more (`prior` scales that)
//   F    the same on a spectral chroma of the audio (the peaks of an FFT of
//        341 ms, 16384 points at 48 kHz, 65..2100 Hz), which also hears chords
//   Fh   F with a peak counted at 0.35 when a peak at least a fifth as strong
//        sits a 3rd, 5th, 6th or 7th harmonic below it (a chord's overtones)
// Root cues, each a 12-note profile (posted as its strongest note):
//   all  the whole chroma                low  what sounds under 200 Hz
//   one  the first note's 300 ms         bar  just after the onsets on the
//                                             reading's bar lines
//
// Three ways to run it (sclang -u 58xxx: a far port, beside megalooper):
//   the takes (default): sessions/*-events.jsonl (a take with its audio in its
//     set's tap: T and F; one carried in from an earlier set: readings only)
//     and the training-data loops (audio only), all private. Posts each
//     take's guesses, then checks that need no labels: do T and Fh agree, do
//     a take's two halves agree, how much of each chroma lies outside each
//     guess. Labels, if any, in sessions/key-labels.json ({"<take>": "E
//     Dorian"} or a root alone) are scored too.
//   ~keyEvalCorpus = 240: that many synthetic takes of known keys instead,
//     made to be like the duo's (riffs, strummed and power chords, both in
//     one take; odd meters, 70..160 BPM; guitar-like tones: weak low
//     fundamentals, inharmonic, decaying; passing notes; tuning +-30 cents;
//     a quarter with the root NOT on the bar lines), scored over a grid of
//     lambda x mu x prior for F and Fh, then the best setting by material.
//   ~keyEvalSelfTest = true: five fixed synthetic takes (a riff, chords,
//     power chords, a modal line, a mixolydian move).
//     ~keyEvalGrid = false: the settings only (F, Fh and Fh2: Fh also
//     against the 2nd harmonic, 2.5 and 3.5 below: no gain, 2026-11-14).
//     ~keyEvalShow = true: every synthetic take, truth, notes and guess.
// Scores: root, set (the same notes), exact (both), safe (every note the
// guess may play is in the true scale: what the sequencer needs).
// Settings, the defaults from the corpus's grid (2026-11-14; were 0.25, 0.06,
// 1, equal cues): ~keyEvalLambda (0.8), ~keyEvalMu (0.1), ~keyEvalPrior (4),
// ~keyEvalCueWeights ([all, one, bar, low] = [0.5, 1, 2, 1]).
// ~keyEvalClips = true: each real take's audio to sessions/key-takes/ (a
// take with readings only: twice its length from the set's loop stem).
// Sections (a key that changes inside the loop, LoopKey.sectionsOf; the
// code that runs, not a copy):
//   ~keyEvalSections = 300: that many synthetic takes of 2..8 bars whose key
//     changes at bar lines (A B, A A B B, A B A B, A B C...: the riff moved,
//     its mode changed, or another key), a third in one key, scored bar by
//     bar for every tau (~keyEvalTaus) and merge rule (~keyEvalMerges);
//     tau inf is one key for the loop. ~keyEvalShow: each take's sections.
//   ~keyEvalSections = \real: the real takes' sections at a few taus.
(
var repo = thisProcess.nowExecutingPath !? { |p| p.dirname.dirname } ?? { Looper.repoRoot };
var names = PitchAnalyzer.noteNames, scales = MegaSANoteSeq.scales;
var mode = case { ~keyEvalSections.isNumber } { \sections } { ~keyEvalCorpus.notNil } { \corpus }
    { ~keyEvalSelfTest == true } { \self } { \takes };
var secReal = ~keyEvalSections == \real;
var settings = (lambda: ~keyEvalLambda ? 0.8, mu: ~keyEvalMu ? 0.1, prior: ~keyEvalPrior ? 4,
    cw: ~keyEvalCueWeights ? #[0.5, 1, 2, 1], m0: ~keyEvalFallback ? 0);
var clips = ~keyEvalClips == true, corpusSize = (~keyEvalCorpus ? 0).asInteger;
var families, famNames, modePrior, items = List.new, seen = Set.new, labels = Dictionary.new;
var normSum, normMax, addInto, tuningOf, chromaOfPitches, analyseAudio, framesChroma, readAudio;
var nameOf, fmtPcs, fit, parseLabel, barLines, nearBar, cuesOf, guessOf, verdictOf, fmtChroma, fmtGuess;
var labelPath, clipDir, fixedTake, addNote, genTake, score, fmtScore, withFallback, outside;
var genSectionTake, sectionReport, keyWords;
var t0run = Main.elapsedTime;
AppClock.sched(3000, { "watchdog: exiting".postln; 1.exit; nil });

// ---- scales ----------------------------------------------------------------------
// [family, intervals, prior cost]. A rotation of a family's set from one of its
// notes is a mode; its name comes from MegaSANoteSeq.scales.
families = [
    [\diatonic, [0, 2, 4, 5, 7, 9, 11], 0],
    [\pentatonic, [0, 2, 4, 7, 9], 0],
    [\blues, [0, 3, 5, 6, 7, 10], 0.01],
    [\harmonicMinor, [0, 2, 3, 5, 7, 8, 11], 0.015],
    [\melodicMinor, [0, 2, 3, 5, 7, 9, 11], 0.02]
];
// What naming a mode costs when the cues cannot tell the roots of one set
// apart: common modes first. A rotation with no name costs 0.05.
modePrior = Dictionary.new;
[["Minor", 0], ["Major", 0], ["Minor pentatonic", 0], ["Harmonic minor", 0], ["Melodic minor", 0],
    ["Minor blues", 0.002], ["Major pentatonic", 0.003], ["Dorian", 0.004], ["Mixolydian", 0.004],
    ["Phrygian dominant", 0.006], ["Phrygian", 0.008], ["Lydian", 0.008], ["Locrian", 0.02]
].do { |p| modePrior.put(p[0], p[1]) };

nameOf = { |pcs, root|
    var iv = pcs.collect { |x| (x - root).mod(12) }.sort;
    var hit = scales.detect { |s| s[1].asArray == iv };
    hit !? { |s| s[0] }
};
// The mode each note of a family names, once: famNames[family][degree].
famNames = families.collect { |f| f[1].collect { |r| nameOf.(f[1], r) } };
fmtPcs = { |pcs| pcs.collect { |pc| names[pc] }.join(" ") };

// ---- profiles --------------------------------------------------------------------
normSum = { |v| var s = v.sum; if(s > 0) { v / s } { v } };
normMax = { |v| var m = v.maxItem; if(m > 0) { v / m } { v } };
addInto = { |acc, v| 12.do { |i| acc[i] = acc[i] + v[i] }; acc };

// The tuning as a fraction of a semitone, -0.5..0.5: the weighted circular
// mean of [midi, weight] pairs' distance from the nearest semitone.
tuningOf = { |pairs|
    var x = 0, y = 0, a;
    pairs.do { |p|
        a = 2pi * (p[0] - p[0].round);
        x = x + (cos(a) * p[1]);
        y = y + (sin(a) * p[1]);
    };
    if((x == 0) and: { y == 0 }) { 0 } { atan2(y, x) / 2pi }
};

// Tartini readings [t, hz, amp] in [t0, t1), under hzTop, as a chroma,
// amplitude-weighted as PitchAnalyzer.buildChroma weights them.
chromaOfPitches = { |ps, tune, t0, t1, hzTop|
    var c = Array.fill(12, 0.0), pc;
    ps.do { |p|
        if((p[0] >= t0) and: { p[0] < t1 } and: { p[1] > 30 } and: { p[1] < hzTop } and: { p[2] > 0 }) {
            pc = (p[1].cpsmidi - tune).round.asInteger.mod(12);
            c[pc] = c[pc] + p[2];
        };
    };
    c
};

// The audio's frames: [centre time, chroma, chroma with overtones counted
// less, chroma under 200 Hz]; quiet frames (40 dB under the loudest) dropped.
// The FFT is 341 ms at any rate (16384 points at 48 kHz, 4096 at 12 kHz).
analyseAudio = { |sig, sr|
    var n = (16384 * sr / 48000).round.asInteger.nextPowerOfTwo, hop, win, cosT, imag, padded = sig;
    var kLo, kHi, raw = List.new, frameCount, off, frame, cx, re, im, mags, fmax, peaks;
    var a, b, c, la, lb, lc, den, d, hz, emax, tune, out = List.new, ch, chH, chH2, lo, pc, w, wh, wh2, sub, sub2;
    var kept, top;
    hop = (n / 4).asInteger;
    win = Signal.hanningWindow(n); cosT = Signal.fftCosTable(n); imag = Signal.newClear(n);
    if(sig.size < n) { padded = Signal.newFrom(sig.asArray ++ Array.fill(n - sig.size, 0.0)) };
    kLo = (65 * n / sr).floor.asInteger.max(2);
    kHi = (2100 * n / sr).ceil.asInteger;
    frameCount = ((padded.size - n) / hop).floor.asInteger + 1;
    frameCount.do { |fi|
        off = fi * hop;
        frame = Signal.newFrom(padded.copyRange(off, (off + n) - 1)) * win;
        cx = frame.fft(imag, cosT);
        re = cx.real; im = cx.imag;
        mags = Array.fill((kHi - kLo) + 3, { |j| re[(kLo - 1) + j].hypot(im[(kLo - 1) + j]) });
        fmax = mags.maxItem;
        peaks = List.new;
        (1 .. (mags.size - 2)).do { |j|
            a = mags[j - 1]; b = mags[j]; c = mags[j + 1];
            if((b > a) and: { b >= c } and: { b > (fmax * 0.01) }) {
                la = a.max(1e-12).log; lb = b.max(1e-12).log; lc = c.max(1e-12).log;
                den = (la - (2 * lb)) + lc;
                d = if(den.abs > 1e-12) { (0.5 * (la - lc)) / den } { 0 };
                hz = (((kLo - 1) + j) + d.clip(-0.5, 0.5)) * sr / n;
                peaks.add([hz, b]);
            };
        };
        // the 24 strongest: enough for a chord and its overtones
        top = peaks.asArray.sort { |x, y| x[1] > y[1] }.keep(24);
        raw.add([(off + (n / 2)) / sr, top, mags.sum]);
    };
    emax = raw.collect { |r| r[2] }.maxItem ? 0;
    kept = raw.select { |r| r[2] >= (emax * 0.01) };
    tune = tuningOf.(kept.collect { |r| r[1].collect { |p| [p[0].cpsmidi, p[1]] } }.flatten(1));
    kept.do { |r|
        ch = Array.fill(12, 0.0); chH = Array.fill(12, 0.0); chH2 = Array.fill(12, 0.0); lo = Array.fill(12, 0.0);
        r[1].do { |p|
            pc = (p[0].cpsmidi - tune).round.asInteger.mod(12);
            w = p[1];
            sub = r[1].detect { |q|
                (q[1] >= (0.2 * w)) and: { [3, 5, 6, 7].any { |h| ((q[0] * h) - p[0]).abs < (0.02 * p[0]) } }
            };
            // also against the 2nd harmonic, for a low string whose fundamental is weak
            sub2 = sub ?? { r[1].detect { |q|
                (q[1] >= (0.2 * w)) and: { [2.5, 3.5].any { |h| ((q[0] * h) - p[0]).abs < (0.02 * p[0]) } }
            } };
            wh = if(sub.notNil) { w * 0.35 } { w };
            wh2 = if(sub2.notNil) { w * 0.35 } { w };
            ch[pc] = ch[pc] + w;
            chH[pc] = chH[pc] + wh;
            chH2[pc] = chH2[pc] + wh2;
            if(p[0] < 200) { lo[pc] = lo[pc] + w };
        };
        out.add((t: r[0], c: ch, h: chH, h2: chH2, low: lo));
    };
    (frames: out.asArray, tune: tune, first: kept.first !? { |r| r[0] - (n / 2 / sr) })
};

// The sum of one field over the frames whose centre is in [t0, t1).
framesChroma = { |frames, key, t0, t1|
    var acc = Array.fill(12, 0.0);
    frames.do { |f| if((f[\t] >= t0) and: { f[\t] < t1 }) { addInto.(acc, f[key]) } };
    acc
};

readAudio = { |path, startFrame, numFrames|
    var sf = SoundFile.new, data, ch, s0, nf;
    if(sf.openRead(path).not) { nil } {
        ch = sf.numChannels;
        s0 = startFrame.asInteger.clip(0, sf.numFrames);
        nf = numFrames.asInteger.min(sf.numFrames - s0);
        sf.seek(s0, 0);
        data = FloatArray.newClear(nf * ch);
        sf.readData(data);
        sf.close;
        if(ch == 1) { Signal.newFrom(data) } {
            Signal.fill(nf, { |i| (data[i * ch] + data[(i * ch) + 1]) * 0.5 })
        }
    }
};

// ---- bar lines -------------------------------------------------------------------
// From the first onset, every loopDur / k of the reading: the bars the
// Looper counts from the take's first note.
barLines = { |it|
    var r = it[\reading], k, bar, lines = List.new, i = 0;
    if(r.isNil or: { r[\loopDur].isNil }) { [it[\first]] } {
        k = (r[\k] ? 1).asInteger.max(1);
        bar = r[\loopDur].asFloat / k;
        while { (it[\first] + (i * bar)) < it[\dur] } { lines.add(it[\first] + (i * bar)); i = i + 1 };
        lines.asArray
    }
};
nearBar = { |it|
    var lines = barLines.(it);
    it[\onsets].select { |o| lines.any { |l| (o[0] - l).abs < 0.08 } }.collect { |o| o[0] }
        ++ (if(it[\onsets].isEmpty) { [it[\first]] } { [] })
};

// ---- the cues and the fit ----------------------------------------------------------
// The 12-note profiles a guess reads over [t0, t1), from the readings (\T) or
// the audio (\F, \Fh). Each sums to 1 (zero where nothing was heard).
cuesOf = { |it, est, t0, t1|
    var ps = it[\pitches], au = it[\audio], bars, one0, all, one, bar = Array.fill(12, 0.0), low, key;
    bars = nearBar.(it).select { |t| (t >= t0) and: { t < t1 } };
    one0 = if(bars.isEmpty) { t0.max(it[\first]) } { bars.first };
    if(est == \T) {
        all = chromaOfPitches.(ps, it[\tuneT], t0, t1, 2000);
        one = chromaOfPitches.(ps, it[\tuneT], one0 + 0.02, one0 + 0.35, 2000);
        bars.do { |t| addInto.(bar, chromaOfPitches.(ps, it[\tuneT], t + 0.02, t + 0.3, 2000)) };
        low = chromaOfPitches.(ps, it[\tuneT], t0, t1, 200);
    } {
        key = switch(est, \Fh, { \h }, \Fh2, { \h2 }, { \c });
        all = framesChroma.(au[\frames], key, t0, t1);
        one = framesChroma.(au[\frames], \c, one0 + 0.08, one0 + 0.28);
        bars.do { |t| addInto.(bar, framesChroma.(au[\frames], \c, t + 0.08, t + 0.28)) };
        low = framesChroma.(au[\frames], \low, t0, t1);
    };
    (all: normSum.(all), one: normSum.(one), bar: normSum.(bar), low: normSum.(low))
};

// The best (set, root) for the chroma `w` (sums to 1) and the root evidence
// `ev` (its best note 1), under settings `s`: the set's cost is the weight it
// leaves out plus lambda for each of its notes, the root's what it lacks of
// the best note (times mu), the family's and the mode's priors (times
// prior). Also the runner-up with another root or set, and the margin to it.
fit = { |w, ev, s|
    var cands = List.new, pcs, inside, cost, nm, best, alt;
    families.do { |f, fi|
        12.do { |t|
            pcs = f[1].collect { |x| (x + t).mod(12) };
            inside = 0;
            pcs.do { |pc| inside = inside + w[pc] };
            cost = ((1 - inside) + (s[\lambda] * pcs.size / 12)) + (f[2] * s[\prior]);
            pcs.do { |r, d|
                nm = famNames[fi][d];
                cands.add([(cost + (s[\mu] * (1 - ev[r])))
                    + ((if(nm.isNil) { 0.05 } { modePrior[nm] ? 0.03 }) * s[\prior]), fi, t, r, nm, pcs]);
            };
        };
    };
    best = cands.minItem { |c| c[0] };
    alt = cands.select { |c| (c[3] != best[3]) or: { c[1] != best[1] } or: { c[2] != best[2] } }.minItem { |c| c[0] };
    (fam: families[best[1]][0], pcs: best[5].copy.sort, root: best[3], name: best[4], total: best[0],
        inside: best[5].sum { |pc| w[pc] },
        margin: alt[0] - best[0], alt: (pcs: alt[5].copy.sort, root: alt[3], name: alt[4]))
};

// A guess over [t0, t1) (the whole take by default); the cues are kept on the
// take, so a grid of settings reads them once.
guessOf = { |it, est, s, t0 = -1e9, t1 = 1e9|
    var cues, ev, ks, ckey, cw;
    if(est == \ks) {
        ks = PitchAnalyzer.analyze(it[\pitches].collect { |p| [p[1], p[2]] });
        if(ks[\root].isNil) { nil } {
            (root: ks[\root], name: ks[\scaleName],
                pcs: scales.detect { |x| x[0] == ks[\scaleName] }[1].collect { |x| (x + ks[\root]).mod(12) }.sort)
        }
    } {
        if(it[\cueCache].isNil) { it[\cueCache] = Dictionary.new };
        ckey = est.asString ++ "@" ++ t0 ++ "/" ++ t1;
        cues = it[\cueCache][ckey];
        if(cues.isNil) { cues = cuesOf.(it, est, t0, t1); it[\cueCache].put(ckey, cues) };
        if(cues[\all].sum <= 0) { nil } {
            cw = s[\cw] ? #[1, 1, 1, 1];
            ev = normMax.((((cues[\all] * cw[0]) + (cues[\one] * cw[1])) + (cues[\bar] * cw[2])) + (cues[\low] * cw[3]));
            fit.(cues[\all], ev, s).put(\cues, cues)
        }
    }
};

// Below margin m0, only the notes the guess and its runner-up share.
withFallback = { |g, m0|
    var shared;
    if(g.isNil or: { g[\margin] >= m0 }) { g } {
        shared = g[\pcs].select { |pc| g[\alt][\pcs].includes(pc) };
        g.copy.put(\pcs, shared).put(\name, nil)
    }
};
// How much of the chroma w (sums to 1) lies outside the guess's notes.
outside = { |g, w| 1 - g[\pcs].sum { |pc| w[pc] } };

// ---- labels ------------------------------------------------------------------------
parseLabel = { |s|
    var parts = s.asString.split($ ).reject { |x| x.isEmpty }, rn, root, rest, sc;
    rn = parts[0] ? "";
    root = names.indexOfEqual(rn.toUpper);
    if(root.isNil and: { rn.size == 2 } and: { rn[1] == $b }) {
        root = names.indexOfEqual(rn[0].toUpper.asString) !? { |i| (i - 1).mod(12) };
    };
    rest = parts.drop(1).join(" ").toLower;
    rest = switch(rest, "aeolian", { "minor" }, "ionian", { "major" }, { rest });
    sc = if(rest.isEmpty) { nil } { scales.detect { |x| x[0].toLower == rest } };
    if(root.isNil or: { rest.notEmpty and: { sc.isNil } }) {
        ("key-eval: label \"" ++ s ++ "\" not understood").warn; nil
    } {
        (root: root, name: sc !? { |x| x[0] }, pcs: sc !? { |x| x[1].collect { |v| (v + root).mod(12) }.sort })
    }
};

verdictOf = { |g, l|
    var rootOk, setOk, safe;
    if(g.isNil or: { l.isNil }) { nil } {
        rootOk = g[\root] == l[\root];
        setOk = l[\pcs] !? { |p| p == g[\pcs] };
        safe = l[\pcs] !? { |p| g[\pcs].every { |pc| p.includes(pc) } };
        (root: rootOk, set: setOk, exact: if(setOk.isNil) { nil } { rootOk and: { setOk } }, safe: safe,
            size: g[\pcs].size)
    }
};
// [root, set, exact, safe] as fractions, and the mean number of notes, over
// the verdicts vs.
score = { |vs|
    var n = vs.size.max(1);
    [\root, \set, \exact, \safe].collect { |k| vs.count { |v| v[k] == true } / n } ++ [vs.collect { |v| v[\size] }.mean ? 0]
};
fmtScore = { |sc| "root " ++ (sc[0] * 100).round.asInteger.asString.padLeft(3) ++ "%  set "
    ++ (sc[1] * 100).round.asInteger.asString.padLeft(3) ++ "%  exact " ++ (sc[2] * 100).round.asInteger.asString.padLeft(3)
    ++ "%  safe " ++ (sc[3] * 100).round.asInteger.asString.padLeft(3) ++ "%  notes " ++ sc[4].round(0.01) };

// ---- synthetic takes ---------------------------------------------------------------------
// A plucked note into `data`: eight partials, inharmonic (B), each at
// rrand(0.4, 1.4) / k^p, the fundamental under 120 Hz down by lowCut (a
// guitar's low strings), decaying faster the higher; 3 ms attack, 12 ms end.
addNote = { |data, sr, t, midi, len, amp, tim|
    var f0 = (midi + tim[\tune]).midicps, s0 = (t * sr).round.asInteger.max(0), n, k, fk, ak, tk, sum, att, rel;
    n = (len * sr).round.asInteger.min(data.size - s0);
    att = (0.003 * sr).round.asInteger.max(1);
    rel = (0.012 * sr).round.asInteger.max(1);
    if(n > (att + rel)) {
        sum = Signal.newClear(n);
        8.do { |ki|
            k = ki + 1;
            fk = k * f0 * (1 + (tim[\inh] * k * k)).sqrt;
            if(fk < (sr * 0.45)) {
                ak = rrand(0.4, 1.4) / (k ** tim[\p]);
                if((k == 1) and: { f0 < 120 }) { ak = ak * tim[\lowCut] };
                tk = tim[\tau] / (1 + (0.35 * (k - 1)));
                sum = sum + ((Signal.series(n, rrand(0.0, 2pi), 2pi * fk / sr).sin
                    * Signal.series(n, 0, -1 / (tk * sr)).exp) * ak);
            };
        };
        att.do { |i| sum[i] = sum[i] * (i / att) };
        rel.do { |i| sum[(n - 1) - i] = sum[(n - 1) - i] * (i / rel) };
        data.overDub(sum * amp, s0);
    };
};

// One random take of a known key, at 12 kHz (the analysis reads 65..2100 Hz).
genTake = { |idx|
    var sr = 12000, modeW, modeName, iv, root, rootMidi, mt, num, den, bpm, pulse, perBar, barDur, bars, dur, lead;
    var tim, type, emph, pedal, power, scaleNotes, allowed, slotKinds, nSlots, slotStart, kindOf, notes = List.new;
    var riff = List.new, ons = List.new, pos, m, density, deg, lastDeg, tones, bassM, voicing, spread, strums;
    var ps0, ps1, ts, te, data, pick, step, pedalNote, sorted, len, last, top;
    thisThread.randSeed = 7000 + idx;
    modeW = [["Minor", 25], ["Minor pentatonic", 14], ["Dorian", 14], ["Major", 14], ["Mixolydian", 10],
        ["Phrygian", 8], ["Harmonic minor", 5], ["Major pentatonic", 5], ["Minor blues", 5]];
    modeName = modeW.collect { |x| x[0] }.wchoose(modeW.collect { |x| x[1] }.normalizeSum);
    iv = scales.detect { |x| x[0] == modeName }[1].asArray;
    root = 12.rand;
    rootMidi = 40 + (root - 4).mod(12);
    mt = [[4, 4], [7, 8], [5, 8], [6, 8], [9, 8], [11, 8], [12, 8], [5, 4], [7, 4], [3, 4]].choose;
    num = mt[0]; den = mt[1];
    bpm = rrand(70.0, 160.0);
    pulse = 30 / bpm;
    perBar = if(den == 8) { num } { num * 2 };
    barDur = perBar * pulse;
    bars = (rrand(3.0, 10.0) / barDur).round.asInteger.clip(1, 4);
    lead = rrand(0.005, 0.08);
    dur = lead + (bars * barDur);
    type = [\riff, \chords, \mixed].wchoose([0.4, 0.3, 0.3]);
    emph = 0.75.coin;
    pedal = 0.3.coin;
    power = (iv.size != 7) or: { 0.4.coin };
    tim = (p: rrand(0.6, 1.4), lowCut: rrand(0.15, 0.7), inh: rrand(0.00005, 0.0003), tau: rrand(0.5, 2.0),
        tune: rrand(-0.3, 0.3));
    scaleNotes = (40 .. 72).select { |x| iv.includes((x - rootMidi).mod(12)) };
    top = scaleNotes.indexOf(scaleNotes.detect { |x| x >= 64 } ? scaleNotes.last);
    allowed = (0 .. (iv.size - 1)).select { |d| iv.includes((iv[d] + 7).mod(12)) };
    pedalNote = if(emph) { rootMidi } { scaleNotes[2] };
    // half bars, on the pulse grid; each one riff or chord
    nSlots = bars * 2;
    slotStart = { |j| (((j / 2).floor * perBar) + (if(j.odd) { (perBar / 2).round } { 0 })).asInteger };
    slotKinds = Array.fill(nSlots, { switch(type, \riff, { \riff }, \chords, { \chord }, { [\riff, \chord].choose }) });
    if((type == \mixed) and: { slotKinds.every { |x| x == slotKinds[0] } }) {
        slotKinds[nSlots - 1] = if(slotKinds[0] == \riff) { \chord } { \riff };
    };
    pos = if(emph) { scaleNotes.indexOf(rootMidi) } { scaleNotes.size.rand.min(top) };
    density = rrand(0.5, 0.9);
    spread = rrand(0.006, 0.015);
    lastDeg = nil;
    nSlots.do { |j|
        ps0 = slotStart.(j);
        ps1 = if(j == (nSlots - 1)) { bars * perBar } { slotStart.(j + 1) };
        if(slotKinds[j] == \riff) {
            (ps0 .. (ps1 - 1)).do { |p|
                if(((p % perBar) == 0) or: { density.coin }) {
                    step = [-2, -1, 1, 2, 3, -3, 0].wchoose([2, 4, 4, 2, 1, 1, 1].normalizeSum);
                    pos = (pos + step).clip(0, top);
                    m = scaleNotes[pos];
                    if(((p % perBar) == 0) and: { emph } and: { 0.6.coin }) {
                        m = rootMidi + (if(0.3.coin) { 12 } { 0 });
                    } {
                        if(pedal and: { p.odd }) { m = pedalNote };
                    };
                    // a chromatic passing note now and then: off the bar line, short
                    pick = ((p % perBar) != 0) and: { 0.08.coin };
                    if(pick) { m = m + [-1, 1].choose };
                    riff.add([lead + (p * pulse) + 0.006.rand2, m,
                        rrand(0.5, 1.0) * (if((p % perBar) == 0) { 1.2 } { 1 }), pick]);
                };
            };
        } {
            // a chord: on the bar's first slot always new, on its second now and then
            if(lastDeg.isNil or: { j.even } or: { 0.3.coin }) {
                deg = if(lastDeg.isNil and: { emph } and: { 0.7.coin }) { 0 } {
                    if(power) { allowed.choose } { [0, 3, 4, 5, 1, 2, 6].wchoose([3, 3, 3, 2, 1, 1, 0.5].normalizeSum) }
                };
            };
            lastDeg = deg;
            bassM = 40 + ((root + iv[deg]) - 4).mod(12);
            tones = if(power) { [iv[deg], (iv[deg] + 7).mod(12)] } {
                [iv[deg], iv[(deg + 2) % 7], iv[(deg + 4) % 7]] };
            voicing = if(power) { [bassM, bassM + 7, bassM + 12] } {
                [bassM] ++ (52 .. 71).select { |x| tones.includes((x - root).mod(12)) }.scramble.keep(rrand(2, 4)).sort
            };
            strums = (ps0 .. (ps1 - 1)).select { |p| (p == ps0) or: { 0.4.coin } };
            strums.do { |p, si|
                ts = lead + (p * pulse) + 0.006.rand2;
                te = lead + ((strums[si + 1] ? ps1) * pulse);
                ons.add(ts);
                voicing.do { |x, vi|
                    notes.add([ts + (vi * spread), x, ((te - ts) - (vi * spread)) * rrand(0.85, 1.0), rrand(0.25, 0.45)]);
                };
            };
        };
    };
    // a single line: each note until the next (damped), now and then ringing on
    sorted = riff.asArray.sort { |a, b| a[0] < b[0] };
    sorted.do { |r, i|
        len = if(i < (sorted.size - 1)) { (sorted[i + 1][0] - r[0]) * rrand(0.7, 1.0) } {
            (dur - r[0]).min(2 * pulse) };
        if(r[3]) { len = len * 0.5 } { if(0.25.coin) { len = len * 1.8 } };
        notes.add([r[0], r[1], len, r[2]]);
        ons.add(r[0]);
    };
    if(~keyEvalDump == idx) {
        ("dump " ++ idx ++ " " ++ modeName ++ " root " ++ root ++ " rootMidi " ++ rootMidi ++ " iv " ++ iv
            ++ " scaleNotes " ++ scaleNotes ++ " top " ++ top ++ " pedal " ++ pedal ++ " emph " ++ emph).postln;
        notes.do { |nt| nt.round(0.01).postln };
    };
    data = Signal.fill((dur * sr).round.asInteger, { 0.0003.rand2 });
    notes.do { |nt| addNote.(data, sr, nt[0].max(0), nt[1], nt[2], nt[3] * 0.3, tim) };
    ons = ons.asArray.sort;
    last = -1;
    ons = ons.select { |t| var keep = t > (last + 0.03); if(keep) { last = t }; keep };
    (name: "syn" ++ idx, src: \synth, dur: dur, pitches: nil, sig: data, sr: sr,
        notesChroma: { var c = Array.fill(12, 0.0);
            notes.do { |nt| var pc = (nt[1] - 0).mod(12); c[pc] = c[pc] + (nt[2].min(dur - nt[0]) * nt[3]) }; c }.value,
        onsets: ons.collect { |t| [t, 1] }, first: ons.first ? lead, reading: (k: bars, loopDur: bars * barDur),
        label: (root: root, name: modeName, pcs: iv.collect { |x| (x + root).mod(12) }.sort),
        type: type, emph: emph, mode: modeName, power: power, meter: num.asString ++ "/" ++ den,
        // every note of the scale played (2 % of the weight or more): only
        // then can the notes name the scale; else safe and the root are the test
        whole: { var c = Array.fill(12, 0.0), s;
            notes.do { |nt| c[nt[1].mod(12)] = c[nt[1].mod(12)] + (nt[2].min(dur - nt[0]) * nt[3]) };
            s = c.sum.max(1e-9);
            iv.every { |x| c[(x + root).mod(12)] >= (0.02 * s) } }.value)
};

// The five fixed synthetic takes: [start, midi, length] as plucked notes,
// 20 cents sharp, at 48 kHz.
fixedTake = { |name, nts, dur, bars, label|
    var sr = 48000, data = Signal.newClear((dur * sr).asInteger);
    var tim = (p: 1, lowCut: 1, inh: 0, tau: 0.33, tune: 0.2);
    nts.do { |nt| addNote.(data, sr, nt[0], nt[1], nt[2], 0.15, tim) };
    (name: name, src: \synth, dur: dur, pitches: nil, sig: data, sr: sr,
        onsets: nts.collect { |nt| [nt[0], 1] }.asSet.asArray.sort { |a, b| a[0] < b[0] },
        first: nts.collect { |nt| nt[0] }.minItem, reading: (k: bars, loopDur: dur), label: parseLabel.(label))
};

// A synthetic take whose key changes at bar lines (2026-11-14, sections):
// a pattern of keys per bar (A B, A A B B, A B A B, A B C ...), key 0 drawn
// as genTake draws one, the others from it: the riff moved (to the IV, the
// V, the bVII...: the same mode on another root), its mode changed (minor to
// major, Dorian...), or another key altogether; `single`: one key, as long,
// for the false splits. The material as genTake's, bar by bar in the bar's
// key: the riff walks on to the nearest note of the new scale.
genSectionTake = { |idx, single|
    var sr = 12000, modeW, drawMode, keyOf2, keys, pat, pats, rep, perBar, num, den, bpm, pulse, barDur, bars, dur, lead;
    var keysPerBar, tim, type, emph, pedal, density, spread, notes = List.new, riff = List.new, ons = List.new;
    var pos, lastMidi, data, sorted, len, last, mt, tries = 0, related, kOf, beat;
    thisThread.randSeed = 9000 + idx;
    modeW = [["Minor", 25], ["Minor pentatonic", 14], ["Dorian", 14], ["Major", 14], ["Mixolydian", 10],
        ["Phrygian", 8], ["Harmonic minor", 5], ["Major pentatonic", 5], ["Minor blues", 5]];
    drawMode = { modeW.collect { |x| x[0] }.wchoose(modeW.collect { |x| x[1] }.normalizeSum) };
    related = Dictionary.newFrom(["Minor", ["Major", "Dorian", "Phrygian", "Harmonic minor"],
        "Major", ["Minor", "Mixolydian", "Lydian"], "Dorian", ["Minor", "Mixolydian", "Phrygian"],
        "Mixolydian", ["Major", "Dorian"], "Phrygian", ["Minor", "Phrygian dominant"],
        "Harmonic minor", ["Minor", "Major"], "Minor pentatonic", ["Major pentatonic", "Minor", "Dorian"],
        "Major pentatonic", ["Minor pentatonic", "Major"], "Minor blues", ["Major pentatonic", "Mixolydian"]]);
    // a key: (name:, root:, iv:, pcs:, rootMidi:, scaleNotes:, top:, allowed:)
    kOf = { |name, root|
        var iv = scales.detect { |x| x[0] == name }[1].asArray, rootMidi = 40 + (root - 4).mod(12), sn;
        sn = (40 .. 72).select { |x| iv.includes((x - rootMidi).mod(12)) };
        (name: name, root: root, iv: iv, pcs: iv.collect { |x| (x + root).mod(12) }.sort, rootMidi: rootMidi,
            scaleNotes: sn, top: sn.indexOf(sn.detect { |x| x >= 64 } ? sn.last),
            allowed: (0 .. (iv.size - 1)).select { |d| iv.includes((iv[d] + 7).mod(12)) })
    };
    keys = [kOf.(drawMode.(), 12.rand)];
    2.do {
        var k0 = keys[0], k, rel = [\transpose, \mode, \other].wchoose([0.55, 0.25, 0.2]), guard = 0;
        while { (k.isNil or: { keys.any { |x| x[\pcs] == k[\pcs] } }) and: { guard < 20 } } {
            guard = guard + 1;
            k = switch(rel,
                \transpose, { kOf.(k0[\name], (k0[\root] + [5, 7, 10, 2, 8, 3].wchoose([4, 3, 2, 1, 1, 1].normalizeSum)).mod(12)) },
                \mode, { kOf.((related[k0[\name]] ? ["Major"]).choose, k0[\root]) },
                { kOf.(drawMode.(), 12.rand) });
        };
        keys = keys.add(k);
    };
    pats = [[0, 1], [0, 0, 1, 1], [0, 1, 0, 1], [0, 0, 0, 1], [0, 1, 2], [0, 0, 1, 2], [0, 1, 0, 2],
        [0, 0, 1, 1, 2, 2, 0, 0], [0, 0, 1, 1, 0, 0, 2, 2], [0, 1, 1, 0]];
    pat = if(single) { 0 ! rrand(2, 8) } { pats.choose };
    while {
        mt = [[4, 4], [7, 8], [5, 8], [6, 8], [9, 8], [11, 8], [12, 8], [5, 4], [7, 4], [3, 4]].choose;
        num = mt[0]; den = mt[1];
        bpm = rrand(70.0, 160.0);
        pulse = 30 / bpm;
        perBar = if(den == 8) { num } { num * 2 };
        barDur = perBar * pulse;
        rep = if((pat.size <= 4) and: { 0.4.coin } and: { ((pat.size * 2) * barDur) <= 26 }) { 2 } { 1 };
        tries = tries + 1;
        (((pat.size * rep) * barDur) > 26) and: { tries < 100 }
    } { };
    keysPerBar = pat.collect { |x| x ! rep }.flatten;
    bars = keysPerBar.size;
    lead = rrand(0.005, 0.08);
    dur = lead + (bars * barDur);
    beat = if(den == 8) { pulse } { 2 * pulse };
    type = [\riff, \chords, \mixed].wchoose([0.4, 0.3, 0.3]);
    emph = 0.75.coin;
    pedal = 0.3.coin;
    tim = (p: rrand(0.6, 1.4), lowCut: rrand(0.15, 0.7), inh: rrand(0.00005, 0.0003), tau: rrand(0.5, 2.0),
        tune: rrand(-0.3, 0.3));
    density = rrand(0.5, 0.9);
    spread = rrand(0.006, 0.015);
    lastMidi = nil;
    bars.do { |b|
        var key = keys[keysPerBar[b]], sn = key[\scaleNotes], top = key[\top], power, kinds, deg, lastDeg, half;
        var bassM, tones, voicing, strums, p0, p1, ts, te, m, step, pick, pedalNote;
        power = (key[\iv].size != 7) or: { 0.4.coin };
        pedalNote = if(emph) { key[\rootMidi] } { sn[2] };
        pos = if(lastMidi.isNil) {
            if(emph) { sn.indexOf(key[\rootMidi]) } { sn.size.rand.min(top) }
        } { sn.indexOf(sn.minItem { |x| (x - lastMidi).abs }) };
        kinds = Array.fill(2, { switch(type, \riff, { \riff }, \chords, { \chord }, { [\riff, \chord].choose }) });
        2.do { |h|
            p0 = (b * perBar) + (if(h == 1) { (perBar / 2).round.asInteger } { 0 });
            p1 = if(h == 1) { (b + 1) * perBar } { (b * perBar) + (perBar / 2).round.asInteger };
            if(kinds[h] == \riff) {
                (p0 .. (p1 - 1)).do { |p|
                    if(((p % perBar) == 0) or: { density.coin }) {
                        step = [-2, -1, 1, 2, 3, -3, 0].wchoose([2, 4, 4, 2, 1, 1, 1].normalizeSum);
                        pos = (pos + step).clip(0, top);
                        m = sn[pos];
                        if(((p % perBar) == 0) and: { emph } and: { 0.6.coin }) {
                            m = key[\rootMidi] + (if(0.3.coin) { 12 } { 0 });
                        } {
                            if(pedal and: { p.odd }) { m = pedalNote };
                        };
                        pick = ((p % perBar) != 0) and: { 0.08.coin };
                        if(pick) { m = m + [-1, 1].choose };
                        lastMidi = m;
                        riff.add([lead + (p * pulse) + 0.006.rand2, m,
                            rrand(0.5, 1.0) * (if((p % perBar) == 0) { 1.2 } { 1 }), pick]);
                    };
                };
            } {
                if(lastDeg.isNil or: { h == 0 } or: { 0.3.coin }) {
                    deg = if((h == 0) and: { emph } and: { 0.7.coin }) { 0 } {
                        if(power) { key[\allowed].choose } {
                            [0, 3, 4, 5, 1, 2, 6].wchoose([3, 3, 3, 2, 1, 1, 0.5].normalizeSum) }
                    };
                };
                lastDeg = deg;
                bassM = 40 + ((key[\root] + key[\iv][deg]) - 4).mod(12);
                tones = if(power) { [key[\iv][deg], (key[\iv][deg] + 7).mod(12)] } {
                    [key[\iv][deg], key[\iv][(deg + 2) % 7], key[\iv][(deg + 4) % 7]] };
                voicing = if(power) { [bassM, bassM + 7, bassM + 12] } {
                    [bassM] ++ (52 .. 71).select { |x| tones.includes((x - key[\root]).mod(12)) }.scramble.keep(rrand(2, 4)).sort
                };
                lastMidi = voicing.last;
                strums = (p0 .. (p1 - 1)).select { |p| (p == p0) or: { 0.4.coin } };
                strums.do { |p, si|
                    ts = lead + (p * pulse) + 0.006.rand2;
                    te = lead + ((strums[si + 1] ? p1) * pulse);
                    ons.add(ts);
                    voicing.do { |x, vi|
                        notes.add([ts + (vi * spread), x, ((te - ts) - (vi * spread)) * rrand(0.85, 1.0), rrand(0.25, 0.45)]);
                    };
                };
            };
        };
    };
    sorted = riff.asArray.sort { |a, b| a[0] < b[0] };
    sorted.do { |r, i|
        len = if(i < (sorted.size - 1)) { (sorted[i + 1][0] - r[0]) * rrand(0.7, 1.0) } {
            (dur - r[0]).min(2 * pulse) };
        if(r[3]) { len = len * 0.5 } { if(0.25.coin) { len = len * 1.8 } };
        notes.add([r[0], r[1], len, r[2]]);
        ons.add(r[0]);
    };
    data = Signal.fill((dur * sr).round.asInteger, { 0.0003.rand2 });
    notes.do { |nt| addNote.(data, sr, nt[0].max(0), nt[1], nt[2], nt[3] * 0.3, tim) };
    ons = ons.asArray.sort;
    last = -1;
    ons = ons.select { |t| var keep = t > (last + 0.03); if(keep) { last = t }; keep };
    (name: "sec" ++ idx, src: \synth, dur: dur, sig: data, sr: sr, single: single, pattern: keysPerBar,
        onsets: ons.collect { |t| [t, 1] }, first: ons.first ? lead, period: bars * barDur,
        reading: (tau: beat, sub: 1, numerator: num, denominator: den, k: bars, loopDur: bars * barDur),
        truth: keysPerBar.collect { |k| keys[k] }, type: type, emph: emph)
};

// The sections of the synthetic takes (LoopKey, the code that runs): bar by
// bar, the key each `tau` gives against the bar's own; tau inf is the loop
// as one key (as before sections).
sectionReport = { |its|
    var taus0 = ~keyEvalTaus ? [0.01, 0.02, 0.03, 0.05, 0.08, inf], merges = ~keyEvalMerges ? [\none, \same, \subset];
    var taus = taus0.collect { |t| merges.collect { |m| [t, m] } }.flatten(1).reject { |x| (x[0] == inf) and: { x[1] != merges[0] } };
    var rows = taus.collect { List.new };
    its.do { |it|
        var grid = LoopKey.gridOf(it[\reading], it[\first], it[\period]);
        var ons = it[\onsets].collect(_[0]), lines = LoopKey.barLinesOf(it[\reading], it[\first], it[\dur]);
        var ev = LoopKey.evidenceOf(it[\sig], it[\sr], ons, lines, it[\first], nil, grid);
        var costs = LoopKey.segmentCosts(ev), whole = LoopKey.keyOf(ev), n = grid[\starts].size;
        var trueB = (1 .. (n - 1)).select { |b| it[\truth][b][\pcs] != it[\truth][b - 1][\pcs] };
        if(~keyEvalDebug == it[\name]) {
            ("debug " ++ it[\name] ++ " reading " ++ it[\reading] ++ " first " ++ it[\first] ++ " dur " ++ it[\dur]).postln;
            ("  starts " ++ grid[\starts].round(0.001) ++ " lines " ++ lines.round(0.001)).postln;
            ("  onsets " ++ ons.round(0.01)).postln;
            ev[\bars].do { |b, i| ("  bar " ++ i ++ " truth " ++ keyWords.(it[\truth][i]) ++ " " ++ it[\truth][i][\pcs]
                ++ "  heard " ++ LoopKey.words(LoopKey.keyOf(b.copy.put(\tune, ev[\tune])))
                ++ "  energy " ++ b[\all].sum.round(0.01) ++ "  chroma " ++ fmtChroma.(b[\all])).postln };
        };
        taus.do { |tm, k|
            var tau = tm[0], secs = if(tau == inf) { nil } { LoopKey.sectionsOf(ev, tau, nil, costs, tm[1]) };
            var perBar = Array.fill(n, { |b| (secs !? { |ss| ss.detect { |sc| (b >= sc[\from]) and: { b < sc[\to] } } !? { |sc| sc[\key] } }) ? whole });
            var foundB = (secs ? []).collect { |sc| sc[\from] }.reject { |b| b == 0 };
            rows[k].add((single: it[\single], n: n, secs: (secs ? [1]).size,
                safe: perBar.collect { |g, b| g.notNil and: { g[\pcs].every { |pc| it[\truth][b][\pcs].includes(pc) } } },
                root: perBar.collect { |g, b| g.notNil and: { g[\root] == it[\truth][b][\root] } },
                size: perBar.collect { |g| (g !? { |x| x[\pcs].size }) ? 0 },
                trueB: trueB, foundB: foundB, hit: foundB.count { |b| trueB.includes(b) },
                near: foundB.count { |b| trueB.any { |t| (t - b).abs <= 1 } },
                show: [it[\name], it[\pattern], it[\pattern].collect { |x, i| [x, keyWords.(it[\truth][i])] }.asSet.asArray.sort { |a, b| a[0] < b[0] }.collect(_[1]),
                    secs !? { |ss| ss.collect { |sc| [sc[\from], sc[\to], LoopKey.words(sc[\key])] } } ? LoopKey.words(whole)]));
        };
        it[\sig] = nil;
    };
    "".postln;
    "tau, merge     | single-key takes: safe/bar  root/bar  notes  split%  secs | changing takes: safe/bar  root/bar  notes  secs  bounds found (exact/±1 of true)".postln;
    taus.do { |tau, k|
        var one = rows[k].select { |r| r[\single] }, many = rows[k].reject { |r| r[\single] };
        var pct = { |rs, key| var all = rs.collect { |r| r[key] }.flatten; if(all.isEmpty) { "-" } { ((all.count(_ == true) / all.size) * 100).round.asInteger.asString ++ "%" } };
        var mean = { |rs, f| if(rs.isEmpty) { "-" } { rs.collect(f).mean.round(0.01).asString } };
        ((tau[0].asString ++ " " ++ (if(tau[0] == inf) { "" } { tau[1] })).padRight(14) ++ " | " ++ pct.(one, \safe).padLeft(19) ++ pct.(one, \root).padLeft(10)
            ++ mean.(one, { |r| r[\size].mean }).padLeft(7)
            ++ (if(one.isEmpty) { "-" } { ((one.count { |r| r[\secs] > 1 } / one.size) * 100).round.asInteger.asString ++ "%" }).padLeft(8)
            ++ mean.(one, { |r| r[\secs] }).padLeft(6)
            ++ " | " ++ pct.(many, \safe).padLeft(17) ++ pct.(many, \root).padLeft(10)
            ++ mean.(many, { |r| r[\size].mean }).padLeft(7) ++ mean.(many, { |r| r[\secs] }).padLeft(6)
            ++ ("   " ++ many.collect { |r| r[\foundB].size }.sum ++ " found, " ++ many.collect { |r| r[\hit] }.sum ++ "/"
                ++ many.collect { |r| r[\near] }.sum ++ " on true, of " ++ many.collect { |r| r[\trueB].size }.sum ++ " true")).postln;
    };
    if(~keyEvalShow == true) {
        "".postln;
        rows[taus.detectIndex { |x| (x[0] == LoopKey.tau) and: { x[1] == LoopKey.mergeMode } } ? 0].do { |r| r[\show].postln };
    };
};
keyWords = { |t| names[t[\root]] ++ " " ++ t[\name] };

// ---- the takes -------------------------------------------------------------------------
switch(mode,
    \sections, {
        ~keyEvalSections.do { |i| items.add(genSectionTake.(i, (i % 3) == 0)) };
        ("made " ++ items.size ++ " synthetic takes (a third in one key) in " ++ (Main.elapsedTime - t0run).round(0.1) ++ " s").postln;
    },
    \self, {
        items.add(fixedTake.("riff-Em-pent", [40, 43, 45, 40, 47, 45, 43, 50, 40, 43, 45, 47, 50, 47, 45, 43]
            .collect { |m, i| [0.05 + (i * 0.3), m, 0.32] }, 4.9, 2, "E minor pentatonic"));
        items.add(fixedTake.("chords-Em-C-G-D", [[40, 47, 52, 55, 59, 64], [48, 52, 55, 60, 64],
            [43, 47, 50, 55, 59, 67], [50, 57, 62, 66]].collect { |ch, bi|
                ch.collect { |m, si| [0.05 + (bi * 2.4) + (si * 0.01), m, 2.3] } }.flatten(1), 9.7, 4, "E minor"));
        items.add(fixedTake.("power-E5-G5-A5", [40, 43, 45, 43].collect { |r, i| [r, r + 7, r + 12].collect { |m|
            [0.05 + (i * 0.6), m, 0.58] } }.flatten(1), 2.5, 1, "E minor pentatonic"));
        items.add(fixedTake.("line-A-dorian", [45, 48, 50, 52, 54, 55, 57, 55, 45, 52, 54, 50, 48, 54, 52, 57]
            .collect { |m, i| [0.05 + (i * 0.3), m, 0.3] }, 4.9, 2, "A dorian"));
        items.add(fixedTake.("chords-D-C-G-D", [[50, 57, 62, 66], [48, 52, 55, 60, 64], [43, 47, 50, 55, 59, 67],
            [50, 57, 62, 66]].collect { |ch, bi| ch.collect { |m, si| [0.05 + (bi * 2.4) + (si * 0.01), m, 2.3] } }
            .flatten(1), 9.7, 4, "D mixolydian"));
    },
    \corpus, {
        corpusSize.do { |i| items.add(genTake.(i)) };
        ("made " ++ items.size ++ " synthetic takes in " ++ (Main.elapsedTime - t0run).round(0.1) ++ " s").postln;
    },
    {
        labelPath = repo +/+ "sessions/key-labels.json";
        if(File.exists(labelPath)) {
            File.readAllString(labelPath).parseJSON.keysValuesDo { |k, v|
                if(v.asString.notEmpty) { parseLabel.(v) !? { |l| labels.put(k.asString, l) } };
            };
        };
        (LooperSessionRecorder.globQuote(repo +/+ "sessions") +/+ "*-events.jsonl").pathMatch.sort.do { |path|
            var events = LooperSessionRecorder.readEvents(path), header, audioEv, tapPath, sr, stamp, ps, key, sig, on;
            var loopPath = LooperSessionRecorder.sessionPath(events, \loop, path);
            header = events.detect { |e| e[\ev] == "session" } ? ();
            audioEv = events.detect { |e| e[\ev] == "audio" };
            tapPath = LooperSessionRecorder.sessionPath(events, \tap, path) ? header[\tap];
            sr = (header[\sampleRate] ? 48000).asFloat;
            stamp = PathName(path).fileName.keep(13);
            LooperSessionRecorder.takesFrom(events).do { |tk, i|
                ps = (tk[\pitches] ? []).collect { |p| p.collect(_.asFloat) };
                on = (tk[\onsets] ? []).collect { |p| [p[0].asFloat, p[1].asFloat] };
                key = (tk[\dur] ? 0).asFloat.round(0.001).asString ++ "/" ++ ps.size;
                if(#[\take, \inForce].includes(tk[\kind]) and: { ps.size >= 20 } and: { (tk[\dur] ? 0).asFloat >= 1.0 }
                    and: { (tk[\tapPeakDb] ? 0).asFloat > -40 } and: { seen.includes(key).not }) {
                    seen.add(key);
                    sig = nil;
                    if((tk[\kind] == \take) and: { tk[\start].notNil } and: { audioEv.notNil }
                        and: { tapPath.notNil } and: { File.exists(tapPath ? "") }) {
                        sig = readAudio.(tapPath, (tk[\start].asFloat - audioEv[\t].asFloat) * sr, tk[\dur].asFloat * sr);
                    };
                    items.add((name: stamp ++ "#" ++ i, src: if(sig.notNil) { \tap } { \pitch },
                        dur: tk[\dur].asFloat, pitches: ps, onsets: on, sig: sig, sr: sr,
                        listen: if(sig.isNil and: { loopPath.notNil } and: { File.exists(loopPath ? "") }) {
                            readAudio.(loopPath, 0, 2 * (tk[\loopDur] ? tk[\dur]).asFloat * sr) },
                        first: (tk[\firstOnset] ?? { on.first !? { |o| o[0] } } ? 0).asFloat,
                        reading: tk[\settledReading] ? tk[\result]));
                };
            };
        };
        (repo +/+ "training-data/*.json").pathMatch.sort.do { |path|
            var d = File.readAllString(path).parseJSON, wav = path.splitext[0] ++ ".wav", gt, sig, sr, dur, raw;
            if(File.exists(wav)) {
                gt = d["groundTruth"];
                sr = (d["sampleRate"] ? 48000).asFloat;
                sig = readAudio.(wav, 0, 1e9);
                dur = sig.size / sr;
                raw = (d["rawOnsets"] ? []).collect { |p| [p[0].asFloat, p[1].asFloat] }
                    .select { |p| (p[0] >= 0) and: { p[0] < dur } };
                if(raw.notEmpty and: { (raw.first[0] - (d["firstOnsetSec"] ? 0).asFloat).abs > 0.001 }) { raw = [] };
                items.add((name: PathName(path).fileNameWithoutExtension, src: \loop, dur: dur, pitches: nil,
                    onsets: raw, sig: sig, sr: sr, first: raw.first !? { |p| p[0] },
                    reading: (k: gt["bars"].asInteger, loopDur: dur)));
            };
        };
        items.do { |it| labels[it[\name]] !? { |l| it[\label] = l } };
    }
);

// ---- analysis ----------------------------------------------------------------------------
clipDir = repo +/+ "sessions/key-takes";
if(clips) { File.mkdir(clipDir) };
if(mode == \sections) {
    sectionReport.(items);
    items = [];
};
items.do { |it|
    var au;
    if(it[\pitches].notNil) {
        it[\tuneT] = tuningOf.(it[\pitches].select { |p| (p[1] > 30) and: { p[1] < 2000 } }
            .collect { |p| [p[1].cpsmidi, p[2]] });
    };
    if(it[\sig].notNil) {
        au = analyseAudio.(it[\sig], it[\sr]);
        it[\audio] = au;
        it[\first] = it[\first] ?? { au[\first] ? 0 };
    };
    it[\first] = it[\first] ? 0;
    if(clips and: { mode == \takes } and: { (it[\sig] ? it[\listen]).notNil }) {
        {
            var sf = SoundFile.new.headerFormat_("WAV").sampleFormat_("int24").numChannels_(1)
                .sampleRate_(it[\sr]);
            if(sf.openWrite(clipDir +/+ it[\name].replace("#", "-") ++ ".wav")) {
                sf.writeData(FloatArray.newFrom(it[\sig] ? it[\listen])); sf.close;
            };
        }.value;
    };
    if(mode == \corpus) { it[\sig] = nil };
};
("analysed in " ++ (Main.elapsedTime - t0run).round(0.1) ++ " s").postln;

// ~keyEvalSections = \real: the real takes' sections (LoopKey, at its tau
// and a few others), where their reading has a meter.
if(secReal) {
    "".postln;
    "-- the real takes' sections (bars from the first note):".postln;
    items.do { |it|
        var r = it[\reading], period = (r !? { |x| x[\loopDur] } ? it[\dur]).asFloat, grid, ev, costs, lines;
        grid = if(it[\sig].notNil) { LoopKey.gridOf(r, it[\first], period) };
        if(grid.notNil) {
            lines = LoopKey.barLinesOf(r, it[\first], it[\dur]);
            ev = LoopKey.evidenceOf(it[\sig], it[\sr], it[\onsets].collect(_[0]), lines, it[\first], nil, grid);
            costs = LoopKey.segmentCosts(ev);
            (it[\name].keep(28).padRight(30) ++ grid[\starts].size.asString ++ " bars  whole: "
                ++ LoopKey.words(LoopKey.keyOf(ev))).postln;
            [0.02, LoopKey.tau, 0.1].do { |tau|
                ("    tau " ++ tau.asString.padRight(5) ++ (LoopKey.sectionsOf(ev, tau, nil, costs) !? { |ss|
                    ss.collect { |sc| "bars " ++ (sc[\from] + 1) ++ "-" ++ sc[\to] ++ " " ++ LoopKey.words(sc[\key]) }.join("  |  ")
                } ? "one section")).postln;
            };
        };
    };
};

fmtChroma = { |v|
    var m = v.maxItem;
    v.collect { |x| if((m <= 0) or: { x < (m * 0.05) }) { "." } { ((x / m) * 9).round.asInteger.asString } }.join
};
fmtGuess = { |g|
    if(g.isNil) { "-" } {
        names[g[\root]] ++ " " ++ (g[\name] ?? { "{" ++ fmtPcs.(g[\pcs]) ++ "}" })
            ++ (g[\margin] !? { |m| " m" ++ m.round(0.001) } ? "")
            ++ (g[\inside] !? { |x| " in" ++ (x * 100).round.asInteger } ? "")
    }
};

// ---- the grid (synthetic corpus) -------------------------------------------------------------
if(mode == \corpus) {
    {
        var grid = List.new, best, top, bySc, show, groups, fb, run, cws;
        // root cue weights [all, one, bar, low]
        cws = [[1, 1, 1, 1], [0, 1, 1, 1], [0.5, 1, 2, 1], [0.5, 1, 1, 2], [0.5, 2, 1, 1], [0, 1, 2, 2], [0, 2, 2, 1],
            [0, 1, 1, 3]];
        run = { |est, s|
            var vs = items.collect { |it| verdictOf.(guessOf.(it, est, s), it[\label]) }.reject(_.isNil);
            grid.add([est, s, score.(vs)]);
        };
        if(~keyEvalGrid == false) {
            // the settings only: Fh first (the best below), then F and Fh2
            [\Fh, \F, \Fh2].do { |e| run.(e, settings) };
        } {
            run.(\F, (lambda: 0.25, mu: 0.07, prior: 1, cw: cws[0]));
            [0.25, 0.3, 0.4, 0.5, 0.6, 0.8].do { |lam|
                [0.02, 0.04, 0.07, 0.1, 0.15, 0.25].do { |m|
                    [1, 2, 4].do { |pr|
                        cws.do { |cw| run.(\Fh, (lambda: lam, mu: m, prior: pr, cw: cw)) };
                    };
                };
            };
        };
        ("grid of " ++ grid.size ++ " in " ++ (Main.elapsedTime - t0run).round(0.1) ++ " s").postln;
        show = { |g| (g[0].asString.padRight(3) ++ "lambda " ++ g[1][\lambda].asString.padRight(5) ++ "mu "
            ++ g[1][\mu].asString.padRight(5) ++ "prior " ++ g[1][\prior].asString.padRight(2) ++ "cues "
            ++ g[1][\cw].asString.padRight(15) ++ fmtScore.(g[2])).postln };
        "".postln;
        "-- today's settings (lambda 0.25, mu 0.06 -> 0.07 on the grid, prior 1, cues equal):".postln;
        grid.select { |g| (g[1][\lambda] == 0.25) and: { g[1][\mu] == 0.07 } and: { g[1][\prior] == 1 }
            and: { g[1][\cw] == cws[0] } }.do(show);
        "-- by root cue weights (Fh, the best lambda, mu, prior for each):".postln;
        cws.do { |cw| grid.select { |g| (g[0] == \Fh) and: { g[1][\cw] == cw } }.maxItem { |g| g[2][0] + g[2][2] } !? show };
        "-- best by safe + exact:".postln;
        top = grid.asArray.sort { |a, b| (a[2][3] + a[2][2]) > (b[2][3] + b[2][2]) };
        top.keep(10).do(show);
        "-- best by safe:".postln;
        grid.asArray.sort { |a, b| (a[2][3] > b[2][3]) or: { (a[2][3] == b[2][3]) and: { a[2][2] > b[2][2] } } }
            .keep(6).do(show);
        "-- by lambda (Fh, the best mu, prior and cues for each):".postln;
        [0.25, 0.3, 0.4, 0.5, 0.6, 0.8].do { |lam|
            grid.select { |g| (g[0] == \Fh) and: { g[1][\lambda] == lam } }
                .maxItem { |g| g[2][3] + g[2][2] } !? show;
        };
        best = top[0];
        "".postln;
        ("-- the best, " ++ best[0] ++ " " ++ best[1] ++ ", by material:").postln;
        groups = [
            ["riff", { |it| it[\type] == \riff }], ["chords", { |it| it[\type] == \chords }],
            ["mixed", { |it| it[\type] == \mixed }], ["root on the one", { |it| it[\emph] }],
            ["root elsewhere", { |it| it[\emph].not }], ["power chords", { |it| it[\power] and: { it[\type] != \riff } }],
            ["whole scale played", { |it| it[\whole] }], ["part of the scale", { |it| it[\whole].not }],
            ["whole + root on 1", { |it| it[\whole] and: { it[\emph] } }]
        ] ++ ["Minor", "Minor pentatonic", "Dorian", "Major", "Mixolydian", "Phrygian", "Harmonic minor",
            "Major pentatonic", "Minor blues"].collect { |nm| [nm, { |it| it[\mode] == nm }] };
        groups.do { |gr|
            var sel = items.select(gr[1]);
            var vs = sel.collect { |it| verdictOf.(guessOf.(it, best[0], best[1]), it[\label]) }.reject(_.isNil);
            (gr[0].padRight(18) ++ sel.size.asString.padLeft(4) ++ "  " ++ fmtScore.(score.(vs))).postln;
        };
        "-- what it says instead (the best setting), the commonest confusions:".postln;
        {
            var conf = Dictionary.new;
            items.do { |it|
                var g = guessOf.(it, best[0], best[1]), k;
                if(g.notNil and: { (g[\root] != it[\label][\root]) or: { g[\pcs] != it[\label][\pcs] } }) {
                    k = it[\mode] ++ " -> " ++ (if(g[\pcs] == it[\label][\pcs]) {
                        (g[\name] ? "?") ++ " (same notes, root " ++ ((g[\root] - it[\label][\root]).mod(12)) ++ " up)" } {
                        (g[\name] ? "?") ++ (if(g[\pcs].every { |pc| it[\label][\pcs].includes(pc) }) { " (safe)" } { "" }) });
                    conf.put(k, (conf[k] ? 0) + 1);
                };
            };
            conf.asSortedArray.sort { |a, b| a[1] > b[1] }.keep(14).do { |kv| ("  " ++ kv[1].asString.padLeft(3) ++ "  " ++ kv[0]).postln };
        }.value;
        if(~keyEvalShow == true) {
            "-- every take (the best setting): truth, guess, chroma, cues one/bar/low/all".postln;
            items.do { |it|
                var g = guessOf.(it, best[0], best[1]), c = g !? { |x| x[\cues] };
                (it[\name].padRight(7) ++ it[\type].asString.padRight(7) ++ it[\meter].padRight(5)
                    ++ (if(it[\emph]) { "one " } { "    " }) ++ (if(it[\power]) { "pow " } { "    " })
                    ++ (names[it[\label][\root]] ++ " " ++ it[\mode]).padRight(22) ++ fmtGuess.(g).padRight(30)
                    ++ "notes " ++ fmtChroma.(it[\notesChroma]) ++ "  heard "
                    ++ (c !? { fmtChroma.(c[\all]) ++ "  " ++ [\one, \bar, \low, \all].collect { |k|
                        if(c[k].sum > 0) { names[c[k].maxIndex] } { "-" } }.join("/") } ? "")
                    ++ "  tune " ++ (it[\audio][\tune] * 100).round.asInteger).postln;
            };
        };
        "-- how much of the chroma the best's notes hold (inside), and safe by it:".postln;
        {
            var gs = items.collect { |it| [it, guessOf.(it, best[0], best[1])] }.select { |x| x[1].notNil };
            var ins = gs.collect { |x| x[1][\inside] }.sort;
            ("  inside percentiles 10/25/50/75/90: " ++ [0.1, 0.25, 0.5, 0.75, 0.9].collect { |q|
                (ins[(q * (ins.size - 1)).round.asInteger] * 100).round.asInteger }).postln;
            [[0, 0.7], [0.7, 0.8], [0.8, 0.9], [0.9, 1.01]].do { |b|
                var sel = gs.select { |x| (x[1][\inside] >= b[0]) and: { x[1][\inside] < b[1] } };
                var vs = sel.collect { |x| verdictOf.(x[1], x[0][\label]) };
                ("  inside " ++ (b[0] * 100).round.asInteger ++ ".." ++ (b[1] * 100).round.asInteger.min(100) ++ " %: "
                    ++ sel.size.asString.padLeft(4) ++ " takes  " ++ fmtScore.(score.(vs))).postln;
            };
        }.value;
        "-- the best with a fallback: below margin m0, only the notes it shares with its runner-up:".postln;
        [0, 0.005, 0.01, 0.02, 0.03, 0.05].do { |m0|
            var vs = items.collect { |it| verdictOf.(withFallback.(guessOf.(it, best[0], best[1]), m0), it[\label]) }
                .reject(_.isNil);
            ("m0 " ++ m0.asString.padRight(6) ++ fmtScore.(score.(vs))).postln;
        };
    }.value;
};

// ---- the takes' report ---------------------------------------------------------------------
if(mode != \corpus) {
    ("settings " ++ settings ++ "; " ++ items.size ++ " takes ("
        ++ #[\tap, \pitch, \loop, \synth].collect { |s| items.count { |it| it[\src] == s }.asString ++ " " ++ s }.join(", ")
        ++ "), " ++ items.count { |it| it[\label].notNil } ++ " labelled").postln;
    "chroma columns: CcDdEFfGgAaB (lower case = sharp)".postln;
    items.do { |it|
        var l = it[\label];
        it[\guesses] = (ks: if(it[\pitches].notNil) { guessOf.(it, \ks, settings) },
            T: if(it[\pitches].notNil) { guessOf.(it, \T, settings) },
            F: if(it[\audio].notNil) { guessOf.(it, \F, settings) },
            Fh: if(it[\audio].notNil) { guessOf.(it, \Fh, settings) });
        "".postln;
        (it[\name] ++ "  " ++ it[\src] ++ "  " ++ it[\dur].round(0.01) ++ " s"
            ++ (it[\reading] !? { |r| r[\numerator] !? { "  " ++ MeterDecision.readingString(r) } } ? "")
            ++ (it[\tuneT] !? { |t| "  tuning T " ++ (t * 100).round.asInteger ++ " c" } ? "")
            ++ (it[\audio] !? { |a| "  F " ++ (a[\tune] * 100).round.asInteger ++ " c" } ? "")
            ++ (l !? { "  LABEL " ++ names[l[\root]] ++ " " ++ (l[\name] ? "(root)") } ? "")).postln;
        #[\ks, \T, \F, \Fh].do { |e|
            var g = it[\guesses][e], v = verdictOf.(g, l), c;
            if(g.notNil) {
                c = g[\cues];
                ("  " ++ e.asString.padRight(3) ++ fmtGuess.(g).padRight(34)
                    ++ (c !? { "all " ++ fmtChroma.(c[\all]) ++ "  low " ++ fmtChroma.(c[\low])
                        ++ "  cues one/bar/low/all " ++ [\one, \bar, \low, \all].collect { |k|
                            if(c[k].sum > 0) { names[c[k].maxIndex] } { "-" } }.join("/") } ? "")
                    ++ (g[\alt] !? { |a| "  alt " ++ fmtGuess.(a) } ? "")
                    ++ (v !? { "  " ++ [\root, \set, \safe].collect { |k|
                        k ++ (switch(v[k], true, { "+" }, false, { "-" }, { "?" })) }.join(" ") } ? "")).postln;
            };
        };
    };
    "".postln;
    if(items.any { |it| it[\label].notNil }) {
        "-- scores over the labelled takes:".postln;
        #[\ks, \T, \F, \Fh].do { |e|
            var vs = items.collect { |it| verdictOf.(it[\guesses][e], it[\label]) }.reject(_.isNil);
            if(vs.notEmpty) { (e.asString.padRight(4) ++ vs.size.asString.padLeft(3) ++ "  " ++ fmtScore.(score.(vs))).postln };
        };
    };
};

// ---- checks without labels (the real takes) ---------------------------------------------------
if(mode == \takes) {
    {
        var both = items.select { |it| it[\audio].notNil and: { it[\pitches].notNil } };
        var audio = items.select { |it| it[\audio].notNil };
        var same, root, compat, halves = List.new, cross;
        "".postln;
        ("-- checks without labels, settings " ++ settings).postln;
        same = both.count { |it| it[\guesses][\T] !? { |a| it[\guesses][\Fh] !? { |b| a[\pcs] == b[\pcs] } } ? false };
        root = both.count { |it| it[\guesses][\T] !? { |a| it[\guesses][\Fh] !? { |b| a[\root] == b[\root] } } ? false };
        compat = both.count { |it| it[\guesses][\T] !? { |a| it[\guesses][\Fh] !? { |b|
            a[\pcs].every { |pc| b[\pcs].includes(pc) } or: { b[\pcs].every { |pc| a[\pcs].includes(pc) } } } } ? false };
        ("T and Fh, " ++ both.size ++ " takes with both: same notes " ++ same ++ ", same root " ++ root
            ++ ", one inside the other " ++ compat).postln;
        audio.do { |it|
            var h = it[\dur] / 2, a, b;
            if(it[\dur] >= 3) {
                a = guessOf.(it, \Fh, settings, -1e9, h);
                b = guessOf.(it, \Fh, settings, h, 1e9);
                if(a.notNil and: { b.notNil }) { halves.add([it, a, b]) };
            };
        };
        ("Fh, a take's two halves (" ++ halves.size ++ " takes of 3 s or more): same notes "
            ++ halves.count { |x| x[1][\pcs] == x[2][\pcs] } ++ ", same root " ++ halves.count { |x| x[1][\root] == x[2][\root] }
            ++ ", one inside the other " ++ halves.count { |x| x[1][\pcs].every { |pc| x[2][\pcs].includes(pc) }
                or: { x[2][\pcs].every { |pc| x[1][\pcs].includes(pc) } } }).postln;
        halves.do { |x| ("  " ++ x[0][\name].keep(24).padRight(26) ++ fmtGuess.(x[1]).padRight(30) ++ "| "
            ++ fmtGuess.(x[2])).postln };
        // each guess against the OTHER representation's chroma, so no guess is
        // judged by the profile it was fitted to: T and ks on the spectrum's
        // chroma (raw, overtones and all), Fh on the readings'
        "weight outside each guess, on the other representation (takes with both; lower clashes less):".postln;
        cross = #[\ks, \T, \Fh].collect { |e|
            var vals = both.collect { |it|
                var g = it[\guesses][e], w;
                if(g.isNil) { nil } {
                    w = if(e == \Fh) { guessOf.(it, \T, settings) !? { |x| x[\cues][\all] } } {
                        guessOf.(it, \F, settings) !? { |x| x[\cues][\all] } };
                    w !? { [outside.(g, w), g[\pcs].size] }
                }
            }.reject(_.isNil);
            ("  " ++ e.asString.padRight(3) ++ "outside " ++ (vals.collect { |v| v[0] }.mean * 100).round(0.1) ++ " %"
                ++ "  notes " ++ vals.collect { |v| v[1] }.mean.round(0.01) ++ "  (" ++ vals.size ++ " takes)").postln;
        };
        {
            var ins = audio.collect { |it| it[\guesses][\Fh] !? { |g| g[\inside] } }.reject(_.isNil).sort;
            ("Fh inside (its own chroma), percentiles 10/25/50/75/90: " ++ [0.1, 0.25, 0.5, 0.75, 0.9].collect { |q|
                (ins[(q * (ins.size - 1)).round.asInteger] * 100).round.asInteger } ++ "  (" ++ ins.size ++ " takes)").postln;
        }.value;
    }.value;
};
if(clips) { ("clips in " ++ clipDir).postln };
("KEY EVAL DONE in " ++ (Main.elapsedTime - t0run).round(0.1) ++ " s").postln;
0.exit;
)
