// megalooper — the loop's key, for the note sequencer (docs/dev/synth.md 6,
// "Key from the loop", 2026-11-14): ONE scale for the whole loop, heard from
// the dry tap. Pure class methods, as LooperSynthDefs' are: they work on a
// Signal and some times and need no server, so scripts/key-eval.scd and the
// tests run exactly what a take runs. The Looper's part that records the
// tap and calls these is LooperKey.
//
// Two questions, apart:
//   - Which notes are safe: of every transposition of five scale families
//     (diatonic, pentatonic, blues, harmonic and melodic minor), the set
//     holding the most of the loop's chroma for the fewest notes (each note
//     costs `lambda`). Little evidence gives a pentatonic, a lot the full
//     mode.
//   - Where home is: the root among the set's notes, from four cues (the
//     whole chroma, the first note's, the notes on the bar lines', what
//     sounds under 200 Hz), which names the mode (MegaSANoteSeq.scales).
//
// The chroma is the tap's spectrum: FFT peaks of 341 ms frames (4096 points
// at 12 kHz), 65..2100 Hz, binned to the loop's own tuning (the guitar is
// often 15..20 cents sharp), a peak counted at 0.35 when a peak at least a
// fifth as strong sits a 3rd, 5th, 6th or 7th harmonic below it: a chord's
// overtones would otherwise read as notes of their own.
//
// The settings come from 300 synthetic takes of known keys like the duo's
// (scripts/key-eval.scd, ~keyEvalCorpus): every note of the chosen set is in
// the true scale in 82 % of them, 96 % where the whole scale is played and
// the root sits on the bar lines; the root itself is right in 65 %. A loop
// whose chosen set holds under coreBelow of its chroma (a quarter of the
// duo's real takes: chromatic notes, bends, moving harmony) gets a core
// instead: the root, its fifth and the stronger third.
LoopKey {
    // The mode each note of a family names, once (famNames).
    classvar famNamesCache;

    // ---- Settings -------------------------------------------------------------

    *lambda { ^0.8 }
    *mu { ^0.1 }
    *prior { ^4 }
    // The root cues' weights: the whole chroma, the first note, the bar
    // lines, under 200 Hz.
    *cueWeights { ^#[0.5, 1, 2, 1] }
    *coreBelow { ^0.7 }
    // The rate the tap is captured at (LooperKey), and the FFT: 341 ms at any
    // rate, a power of two.
    *rate { ^12000 }
    *fftSize { |sr| ^(16384 * sr / 48000).round.asInteger.nextPowerOfTwo }
    *loHz { ^65 }
    *hiHz { ^2100 }
    *lowHz { ^200 }
    *peaksPerFrame { ^24 }
    // How near an onset must be to a bar line to be a bar line's note, and
    // the window after a note its cue reads (frame centres in it).
    *barSlack { ^0.08 }
    *cueWindow { ^#[0.08, 0.28] }

    // [family, intervals, prior cost]. A rotation of a family's set from one
    // of its notes is a mode, named from MegaSANoteSeq.scales.
    *families {
        ^#[
            [\diatonic, [0, 2, 4, 5, 7, 9, 11], 0],
            [\pentatonic, [0, 2, 4, 7, 9], 0],
            [\blues, [0, 3, 5, 6, 7, 10], 0.01],
            [\harmonicMinor, [0, 2, 3, 5, 7, 8, 11], 0.015],
            [\melodicMinor, [0, 2, 3, 5, 7, 9, 11], 0.02]
        ]
    }

    // What naming a mode costs when the cues cannot tell the roots of one
    // set apart: common modes first; a rotation with no name costs 0.05,
    // a named one not listed 0.03.
    *modePrior { |name|
        if(name.isNil) { ^0.05 };
        ^switch(name.asString,
            "Minor", { 0 }, "Major", { 0 }, "Minor pentatonic", { 0 }, "Harmonic minor", { 0 },
            "Melodic minor", { 0 }, "Minor blues", { 0.002 }, "Major pentatonic", { 0.003 },
            "Dorian", { 0.004 }, "Mixolydian", { 0.004 }, "Phrygian dominant", { 0.006 },
            "Phrygian", { 0.008 }, "Lydian", { 0.008 }, "Locrian", { 0.02 },
            { 0.03 })
    }

    // The scale of MegaSANoteSeq.scales a set of pitch classes is from
    // `root`: its index, or nil.
    *scaleIndex { |pcs, root|
        var iv = this.intervals(pcs, root);
        ^MegaSANoteSeq.scales.detectIndex { |s| s[1].asArray == iv }
    }

    *scaleName { |pcs, root| ^this.scaleIndex(pcs, root) !? { |i| MegaSANoteSeq.scales[i][0] } }

    // famNames[family][degree]: the name of the mode from that note of the
    // family's set (the same at every transposition).
    *famNames {
        ^famNamesCache ?? {
            famNamesCache = this.families.collect { |f| f[1].collect { |r| this.scaleName(f[1], r) } }
        }
    }

    // The semitones above `root` of a set of pitch classes, from 0 up.
    *intervals { |pcs, root| ^pcs.collect { |x| (x - root).mod(12) }.asArray.sort }

    // ---- The spectrum ---------------------------------------------------------

    // The tap's peaks, frame by frame: [[centre time, [[hz, magnitude], ...]
    // (the strongest peaksPerFrame), the frame's summed magnitude], ...].
    // `pause` is called after every frame (a Routine yields there).
    *spectrum { |sig, sr, pause|
        var n = this.fftSize(sr), hop = (n / 4).asInteger, top = this.peaksPerFrame;
        var win = Signal.hanningWindow(n), cosT = Signal.fftCosTable(n), imag = Signal.newClear(n);
        var kLo = (this.loHz * n / sr).floor.asInteger.max(2), kHi = (this.hiHz * n / sr).ceil.asInteger;
        var k0 = kLo - 1, m = (kHi - kLo) + 3, raw = List.new, padded = sig, count;
        var frame, cx, re, im, mags, fmax, floor, peaks, a, b, c, la, lc, lb, den, d;
        if(padded.size < n) { padded = Signal.newFrom(sig.asArray ++ Array.fill(n - sig.size, 0.0)) };
        count = ((padded.size - n) / hop).floor.asInteger + 1;
        count.do { |fi|
            var off = fi * hop;
            frame = Signal.newFrom(padded.copyRange(off, (off + n) - 1)) * win;
            cx = frame.fft(imag, cosT);
            re = cx.real.copyRange(k0, (k0 + m) - 1);
            im = cx.imag.copyRange(k0, (k0 + m) - 1);
            mags = ((re * re) + (im * im)).sqrt;
            fmax = mags.maxItem;
            floor = fmax * 0.01;
            peaks = List.new;
            b = mags[0];
            c = mags[1];
            (1 .. (m - 2)).do { |j|
                a = b;
                b = c;
                c = mags[j + 1];
                if((b > a) and: { b >= c } and: { b > floor }) {
                    la = a.max(1e-12).log;
                    lb = b.max(1e-12).log;
                    lc = c.max(1e-12).log;
                    den = (la - (2 * lb)) + lc;
                    d = if(den.abs > 1e-12) { (0.5 * (la - lc)) / den } { 0 };
                    peaks.add([((k0 + j) + d.clip(-0.5, 0.5)) * sr / n, b]);
                };
            };
            raw.add([(off + (n / 2)) / sr, peaks.asArray.sort { |x, y| x[1] > y[1] }.keep(top), mags.sum]);
            pause.value;
        };
        ^raw.asArray
    }

    // The tuning's circular mean, as [x, y]: the peaks' distance from the
    // nearest semitone, weighted by their magnitude. Sums of these add.
    *tuneVector { |peaks|
        var x = 0, y = 0, a, midi;
        peaks.do { |p|
            midi = p[0].cpsmidi;
            a = 2pi * (midi - midi.round);
            x = x + (cos(a) * p[1]);
            y = y + (sin(a) * p[1]);
        };
        ^[x, y]
    }

    // The tuning, a fraction of a semitone (-0.5..0.5), from a tuneVector.
    *tuneOf { |v| ^if((v[0] == 0) and: { v[1] == 0 }) { 0 } { atan2(v[1], v[0]) / 2pi } }

    // The frames as chroma: (frames: [(t:, c: plain, h: overtones counted
    // less, low: under lowHz), ...], tune: [x, y], first: the first heard
    // frame's start), quiet frames (40 dB under the loudest) dropped.
    // `pause` as spectrum's.
    *chromaFrames { |raw, sr, pause|
        var n = this.fftSize(sr), emax = raw.collect(_[2]).maxItem ? 0, kept, tv, tune, out = List.new;
        if(emax <= 0) { ^nil };
        kept = raw.select { |r| r[2] >= (emax * 0.01) };
        if(kept.isEmpty) { ^nil };
        tv = this.tuneVector(kept.collect(_[1]).flatten(1));
        tune = this.tuneOf(tv);
        kept.do { |r|
            var ch = Array.fill(12, 0.0), chH = Array.fill(12, 0.0), lo = Array.fill(12, 0.0);
            var ps = r[1], hz = ps.collect(_[0]), mag = ps.collect(_[1]), lowHz = this.lowHz;
            ps.do { |p, i|
                var pc = (hz[i].cpsmidi - tune).round.asInteger.mod(12), w = mag[i], sub = false, j = 0, q, tol;
                tol = 0.02 * hz[i];
                while { sub.not and: { j < ps.size } } {
                    if(mag[j] >= (0.2 * w)) {
                        q = hz[j];
                        sub = (((q * 3) - hz[i]).abs < tol) or: { ((q * 5) - hz[i]).abs < tol }
                            or: { ((q * 6) - hz[i]).abs < tol } or: { ((q * 7) - hz[i]).abs < tol };
                    };
                    j = j + 1;
                };
                ch[pc] = ch[pc] + w;
                chH[pc] = chH[pc] + (if(sub) { w * 0.35 } { w });
                if(hz[i] < lowHz) { lo[pc] = lo[pc] + w };
            };
            out.add((t: r[0], c: ch, h: chH, low: lo));
            pause.value;
        };
        ^(frames: out.asArray, tune: tv, first: kept.first[0] - (n / 2 / sr))
    }

    // ---- Evidence ---------------------------------------------------------------
    // What a recording says about the key, as sums that add across recordings
    // (a take and its overdubs): (all:, one:, bar:, low: four 12-note
    // profiles, tune: a tuneVector, seconds: heard). An overdub has no first
    // note and no bar lines of its own: its one and bar are zero.

    *emptyEvidence {
        ^(all: Array.fill(12, 0.0), one: Array.fill(12, 0.0), bar: Array.fill(12, 0.0),
            low: Array.fill(12, 0.0), tune: [0, 0], seconds: 0)
    }

    // The evidence of a take's tap: sig at sr; its onsets' times and the
    // bar lines (seconds into sig), with the first note's time (nil: the
    // first onset, or the first frame heard). Overdubs: onsets and bars nil.
    // nil when nothing was heard.
    *evidenceOf { |sig, sr, onsets, barLines, first, pause, grid|
        var cf = this.chromaFrames(this.spectrum(sig, sr, pause), sr, pause), frames, ev, near, one0, sumIn;
        if(cf.isNil) { ^nil };
        frames = cf[\frames];
        ev = this.emptyEvidence.put(\tune, cf[\tune]).put(\seconds, sig.size / sr);
        sumIn = { |acc, key, t0, t1|
            frames.do { |f| if((f[\t] >= t0) and: { f[\t] < t1 }) { 12.do { |i| acc[i] = acc[i] + f[key][i] } } };
        };
        frames.do { |f| 12.do { |i| ev[\all][i] = ev[\all][i] + f[\h][i]; ev[\low][i] = ev[\low][i] + f[\low][i] } };
        if(onsets.notNil) {
            first = first ?? { onsets.first } ?? { cf[\first] };
            near = this.barNotes(onsets, barLines ? [], first);
            one0 = near.first ? first;
            sumIn.(ev[\one], \c, one0 + this.cueWindow[0], one0 + this.cueWindow[1]);
            near.do { |t| sumIn.(ev[\bar], \c, t + this.cueWindow[0], t + this.cueWindow[1]) };
        };
        grid !? { |g| ev.put(\bars, this.barEvidence(frames, g, onsets, barLines, first)) };
        ^ev
    }

    // The onsets within barSlack of a bar line; with no onsets, the first
    // note's time alone.
    *barNotes { |onsets, barLines, first|
        if(onsets.isEmpty) { ^first !? { |f| [f] } ? [] };
        ^onsets.select { |o| barLines.any { |l| (o - l).abs < this.barSlack } }
    }

    // The bar lines of a take: from its first note, every bar of the reading
    // (uneven bars too) while under `dur`; with no meter, the first note alone.
    *barLinesOf { |result, first, dur|
        var beat, lines, t, bars, i = 0;
        first = first ? 0;
        if(result.isNil or: { result[\tau].isNil }) { ^[first] };
        beat = result[\tau] * (result[\sub] ? 1);
        if(beat <= 0) { ^[first] };
        bars = MeterAnalyzer.barsOf(result);
        lines = List.new;
        t = first;
        while { (t < dur) and: { lines.size < 1000 } } {
            lines.add(t);
            t = t + (bars.wrapAt(i) * beat);
            i = i + 1;
        };
        ^lines.asArray
    }

    *merge { |a, b|
        var bars;
        if(a.isNil) { ^b };
        if(b.isNil) { ^a };
        bars = if(a[\bars].notNil and: { b[\bars].notNil } and: { a[\bars].size == b[\bars].size }) {
            a[\bars].collect { |x, i| this.sumOf([x, b[\bars][i]]) }
        } { a[\bars] ? b[\bars] };
        ^(all: a[\all] + b[\all], one: a[\one] + b[\one], bar: a[\bar] + b[\bar], low: a[\low] + b[\low],
            tune: a[\tune] + b[\tune], seconds: a[\seconds] + b[\seconds], bars: bars)
    }

    // The four profiles of several evidences (or bars) added.
    *sumOf { |list|
        var out = (all: Array.fill(12, 0.0), one: Array.fill(12, 0.0), bar: Array.fill(12, 0.0), low: Array.fill(12, 0.0));
        list.do { |e| [\all, \one, \bar, \low].do { |k| e[k] !? { |v| out[k] = out[k] + v } } };
        ^out
    }

    // ---- The loop's bars ---------------------------------------------------------
    // A grid: (first: the first note's time (bar 1's line, seconds into the
    // recording's take), period: the loop's length, starts: where each of its
    // bars begins, seconds from the loop's frame 0 (the drums' bar lines),
    // posOf: { |t| } the take's time of the recording's time t, nil where
    // it cannot be placed). A take is its own (posOf: t); an overdub's
    // comes from where the loop played while it was recorded.

    // The grid of a reading: nil without a meter.
    *gridOf { |result, first, period|
        var beat, bars, starts, t = 0, cycles, n;
        if(result.isNil or: { result[\tau].isNil } or: { (period ? 0) <= 0 }) { ^nil };
        beat = result[\tau] * (result[\sub] ? 1);
        if(beat <= 0) { ^nil };
        bars = MeterAnalyzer.barsOf(result);
        cycles = (period / (bars.sum * beat)).round.asInteger.max(1);
        bars = (bars ! cycles).flatten;
        starts = bars.collect { |b| var s = t; t = t + (b * beat); s };
        if(starts.size < 1) { ^nil };
        ^(first: first ? 0, period: period, starts: starts, posOf: { |x| x })
    }

    // Which bar of the grid the take's time `pos` is in: counted from the
    // first note, round the loop (what comes before the first note is the
    // end of the last bar, as the loop plays it).
    *barIndexOf { |grid, pos|
        var rel = (pos - grid[\first]).mod(grid[\period]), starts = grid[\starts], i = starts.size - 1;
        while { (i > 0) and: { starts[i] > (rel + 1e-9) } } { i = i - 1 };
        ^i
    }

    // The evidence bar by bar: what sounds in each bar of the grid, the
    // first note's cue in its bar, each bar line's note's in its bar.
    *barEvidence { |frames, grid, onsets, barLines, first|
        var n = grid[\starts].size, posOf = grid[\posOf] ? { |t| t };
        var bars = Array.fill(n, { (all: Array.fill(12, 0.0), one: Array.fill(12, 0.0), bar: Array.fill(12, 0.0),
            low: Array.fill(12, 0.0)) });
        var barAt = { |t| posOf.(t) !? { |p| bars[this.barIndexOf(grid, p)] } };
        var addWindow = { |b, key, t0, t1|
            frames.do { |f| if((f[\t] >= t0) and: { f[\t] < t1 }) { 12.do { |i| b[key][i] = b[key][i] + f[\c][i] } } };
        };
        var near, one0;
        frames.do { |f|
            barAt.(f[\t]) !? { |b| 12.do { |i| b[\all][i] = b[\all][i] + f[\h][i]; b[\low][i] = b[\low][i] + f[\low][i] } };
        };
        if(onsets.notNil) {
            near = this.barNotes(onsets, barLines ? [], first);
            one0 = near.first ? first;
            one0 !? { |t| barAt.(t) !? { |b| addWindow.(b, \one, t + this.cueWindow[0], t + this.cueWindow[1]) } };
            near.do { |t| barAt.(t) !? { |b| addWindow.(b, \bar, t + this.cueWindow[0], t + this.cueWindow[1]) } };
        };
        ^bars
    }

    // ---- Sections: the loop's changes --------------------------------------------
    // A riff that moves (to the IV and back, minor to major) is cut into runs
    // of whole bars, each with a key of its own. Of every way to cut the
    // loop's bars, the one whose runs fit best, each run's fit cost weighted
    // by its share of what was played, plus `tau` for every run after the
    // first: a loop that does not move stays one run.
    *tau { ^0.04 }

    // What each run [i, j) of the bars costs: costs[i][j].
    *segmentCosts { |ev, pause|
        var bars = ev[\bars], n = bars.size, energy = bars.collect { |b| b[\all].sum }, total, costs;
        total = energy.sum;
        costs = Array.fill(n, { Array.fill(n + 1, 0) });
        if(total <= 0) { ^costs };
        n.do { |i|
            var acc = (all: Array.fill(12, 0.0), one: Array.fill(12, 0.0), bar: Array.fill(12, 0.0),
                low: Array.fill(12, 0.0)), share = 0, g;
            ((i + 1) .. n).do { |j|
                acc = this.sumOf([acc, bars[j - 1]]);
                share = share + (energy[j - 1] / total);
                g = this.fitOf(acc);
                costs[i][j] = if(g.isNil) { 0 } { share * g[\total] };
                pause.value;
            };
        };
        ^costs
    }

    // The cheapest cut, as runs [[i, j], ...] in order.
    *cut { |costs, tau|
        var n = costs.size, best = Array.fill(n + 1, inf), from = Array.fill(n + 1, 0), runs = List.new, j;
        best[0] = 0;
        (1 .. n).do { |jj|
            (0 .. (jj - 1)).do { |i|
                var c = (best[i] + costs[i][jj]) + (if(i > 0) { tau } { 0 });
                if(c < best[jj]) { best[jj] = c; from[jj] = i };
            };
        };
        j = n;
        while { j > 0 } { runs.addFirst([from[j], j]); j = from[j] };
        ^runs.asArray
    }

    // The loop's sections: [(from: its first bar, to: the bar after its
    // last, key: keyOf its bars), ...]; nil for one section (or no bars).
    // costs: segmentCosts, if already worked out. Neighbours are put back
    // together (and heard again as one) while `merge` says they are one:
    // \same, the same notes (a root that moves over the same notes is no
    // change of scale); \subset, also where one's notes are all in the
    // other's (a bar that plays less of the scale); \none, the same notes
    // from the same root only.
    *sectionsOf { |ev, tau, pause, costs, merge|
        var runs, bars, keyOfRun, secs, joined = true, mode = merge ? this.mergeMode;
        if(ev.isNil or: { ev[\bars].isNil } or: { ev[\bars].size < 2 }) { ^nil };
        bars = ev[\bars];
        runs = this.cut(costs ?? { this.segmentCosts(ev, pause) }, tau ? this.tau);
        if(runs.size < 2) { ^nil };
        keyOfRun = { |a, b| this.keyOf(this.sumOf(bars.copyRange(a, b - 1)).put(\tune, ev[\tune])) };
        secs = runs.collect { |r| (from: r[0], to: r[1], key: keyOfRun.(r[0], r[1])) }.asList;
        while { joined and: { secs.size > 1 } } {
            joined = false;
            (secs.size - 1).do { |i|
                var a = secs[i], b = secs[i + 1], ka, kb, one;
                if(joined.not and: { b.notNil }) {
                    ka = a[\key];
                    kb = b[\key];
                    one = ka.isNil or: { kb.isNil } or: {
                        (ka[\pcs] == kb[\pcs]) and: { (mode != \none) or: { ka[\root] == kb[\root] } } } or: {
                        (mode == \subset) and: { ka[\pcs].every { |pc| kb[\pcs].includes(pc) }
                            or: { kb[\pcs].every { |pc| ka[\pcs].includes(pc) } } } };
                    if(one) {
                        secs[i] = (from: a[\from], to: b[\to], key: keyOfRun.(a[\from], b[\to]));
                        secs.removeAt(i + 1);
                        joined = true;
                    };
                };
            };
        };
        ^if(secs.size < 2) { nil } { secs.asArray }
    }

    *mergeMode { ^\subset }

    // ---- The key ----------------------------------------------------------------

    *normSum { |v| var s = v.sum; ^if(s > 0) { v / s } { v } }
    *normMax { |v| var m = v.maxItem; ^if(m > 0) { v / m } { v } }

    // The best (set, root) for the chroma w (sums to 1) and the root
    // evidence ev (its best note 1): a set costs the weight it leaves out
    // plus lambda a note, its root what it lacks of the best note (times
    // mu), the family's and the mode's priors (times prior). With the
    // runner-up with another root or set, the margin to it, and the cost
    // (total).
    *fit { |w, ev|
        var lambda = this.lambda, mu = this.mu, prior = this.prior, names = this.famNames, best, alt;
        var cands = List.new;
        this.families.do { |f, fi|
            12.do { |t|
                var pcs = f[1].collect { |x| (x + t).mod(12) }, inside = 0, cost;
                pcs.do { |pc| inside = inside + w[pc] };
                cost = ((1 - inside) + (lambda * pcs.size / 12)) + (f[2] * prior);
                pcs.do { |r, d|
                    var nm = names[fi][d];
                    cands.add([(cost + (mu * (1 - ev[r]))) + (this.modePrior(nm) * prior), fi, t, r, nm, pcs]);
                };
            };
        };
        best = cands.minItem { |c| c[0] };
        alt = cands.select { |c| (c[3] != best[3]) or: { c[1] != best[1] } or: { c[2] != best[2] } }.minItem { |c| c[0] };
        ^(family: this.families[best[1]][0], pcs: best[5].copy.sort, root: best[3], name: best[4],
            inside: best[5].sum { |pc| w[pc] }, margin: alt[0] - best[0], total: best[0],
            alt: (pcs: alt[5].copy.sort, root: alt[3], name: alt[4]))
    }

    // The fit of some evidence (fit's Event, with chroma: the chroma it
    // fitted, summing to 1), or nil for nothing heard.
    *fitOf { |ev|
        var all, cw, cue;
        if(ev.isNil) { ^nil };
        all = this.normSum(ev[\all]);
        if(all.sum <= 0) { ^nil };
        cw = this.cueWeights;
        cue = this.normMax((((all * cw[0]) + (this.normSum(ev[\one]) * cw[1]))
            + (this.normSum(ev[\bar]) * cw[2])) + (this.normSum(ev[\low]) * cw[3]));
        ^this.fit(all, cue).put(\chroma, all)
    }

    // The key from evidence, or nil (nothing heard):
    //   root      0..11, pitch 0 of the sequencer
    //   pcs       the pitch classes it may play, sorted
    //   intervals pcs above the root, from 0 (MegaSANoteSeq.decide's scale)
    //   name      the scale's name, nil for a set no scale has from the root
    //   scale     its index in MegaSANoteSeq.scales, or nil
    //   inside    the share of the chroma in the set heard (0..1)
    //   margin    how far the runner-up was behind (0: a coin's toss)
    //   core      true: unsure (inside under coreBelow), pcs is the root,
    //             its fifth and the stronger third
    //   heard     (pcs:, name:) the set the fit chose, before the core
    //   cents     the tuning, -50..50
    //   chroma    the heard chroma, 12 values, the strongest 1
    *keyOf { |ev|
        var all, g, root, pcs, core, third, name;
        g = this.fitOf(ev);
        if(g.isNil) { ^nil };
        all = g[\chroma];
        root = g[\root];
        core = g[\inside] < this.coreBelow;
        pcs = if(core) {
            third = if(all[(root + 3).mod(12)] >= all[(root + 4).mod(12)]) { 3 } { 4 };
            [root, (root + third).mod(12), (root + 7).mod(12)].sort
        } { g[\pcs] };
        name = if(core) { nil } { g[\name] };
        ^(root: root, pcs: pcs, intervals: this.intervals(pcs, root), name: name,
            scale: if(core) { nil } { this.scaleIndex(pcs, root) },
            inside: g[\inside], margin: g[\margin], core: core,
            heard: (pcs: g[\pcs], name: g[\name]),
            cents: (this.tuneOf(ev[\tune] ? [0, 0]) * 100).round.asInteger.clip(-50, 50),
            chroma: this.normMax(all).collect { |x| x.round(0.001) })
    }

    // The key's name in words: "E Dorian", "E: E G B (unsure)", "A: A C D E G".
    *words { |key|
        var names = MegaSANoteSeq.rootNames, notes, rest;
        if(key.isNil) { ^"none" };
        notes = this.intervals(key[\pcs], key[\root]).collect { |iv| names[(iv + key[\root]).mod(12)] }.join(" ");
        rest = case
            { key[\core] == true } { ": " ++ notes ++ " (unsure)" }
            { key[\name].notNil } { " " ++ key[\name] }
            { ": " ++ notes };
        ^names[key[\root]] ++ rest
    }
}
