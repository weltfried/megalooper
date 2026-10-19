MeterAnalyzer {
    classvar <fitThreshold = 0.85;
    classvar <errThreshold = 0.12;
    classvar <onsetTolerance = 0.2;
    classvar <preferredBpm = 110;
    classvar <bpmRangeLo = 50;
    classvar <bpmRangeHi = 220;
    classvar <maxK = 4;
    classvar <maxN = 128;
    classvar <loopTolerance = 0.10;
    // The most Looper.snapAnalysisToLoop may move a take's length to make it
    // whole bars, in EIGHTHS at the reading's tempo. Half an eighth is the
    // nearest eighth: closer than that to the reading's bar line it is the stop
    // press (good to about ±60–80 ms, docs/dev/meter-perception.md), further it
    // is an eighth that was played — the long bar of 7+7+7+8, which a 7/8
    // reading would cut off. loopTolerance is no such guard: it is relative,
    // and lets a wrong reading move a ten-second take by a second.
    // snapLimitSecs caps it: the eighth is the READING's, and a wrong slow
    // reading has a long one (a sparse 5+5+5+6 read as 12/8 at 63 BPM was let
    // cut 159 ms off), while the hand on the switch is the same at any tempo.
    classvar <snapLimit = 0.5;
    classvar <snapLimitSecs = 0.1;
    // ...unless the reading's grid is that good: a reading whose onsets sit on
    // its pulse this often (`gridFit`, the uneven bars' grid) may be snapped by
    // the whole half eighth. A stop press 113 ms late on the duo's first
    // 5+5+5+8 (all its onsets on the grid) is the hand, not a wrong reading.
    classvar <snapTrustFit = 0.9;
    // Uneven bars, detected (analyzeUneven). Settable for the sweeps the
    // duo's labelled takes will allow; tuned so far on synthetic takes only.
    //   unevenPulse     the pulse it looks for, seconds: an eighth at 220 to a
    //                   quarter at 80 BPM
    //   unevenBar       the common bar, in pulses
    //   unevenMaxDev    how far an odd bar may be from it, in pulses (the duo's
    //                   5+5+5+8 is +3)
    //   unevenAcFloor   how clearly the riff must repeat at the bar's period
    //                   (the autocorrelation of the pulse profile there)
    //   unevenFitFloor  how alike the bars must be (cosine with their fold)
    //   unevenAccent    the weight of strong hits on the bar lines
    //   unevenLastBonus an odd bar last, as the duo mostly plays it
    //   unevenTwoOddCost two odd bars in a loop, which they rarely play
    classvar <>unevenPulse = #[0.13, 0.75];
    classvar <>unevenBar = #[4, 16];
    classvar <>unevenMaxDev = 4;
    classvar <>unevenAcFloor = 0.3;
    classvar <>unevenFitFloor = 0.6;
    classvar <>unevenAccent = 0.25;
    classvar <>unevenLastBonus = 0.05;
    classvar <>unevenTwoOddCost = 0.15;
    //   unevenDevCost   per pulse an odd bar is off: the nearer barring wins
    //                   a near tie (5+5+5+4, not 5+5+9)
    classvar <>unevenDevCost = 0.03;
    //   unevenOnsetSecs the pulse's onset tolerance in seconds as well: a
    //                   fifth of a slow pulse is ~100 ms, which sparse hits
    //                   meet on a wrong grid (7+7+7+6 came out 4+4+4+3/4)
    classvar <>unevenOnsetSecs = 0.04;
    classvar <accentWeight = 0.5;
    // How many ranked readings analyze() returns beside its answer, best
    // first. See prRankCandidates. Settable so an offline sweep can ask for
    // the whole list; the app keeps the default.
    classvar <>maxCandidates = 8;
    classvar <standardMeters;
    classvar <subdivisions;
    // Loop-length-anchored fallback. When no standard meter fits the onset
    // grid (short / percussive / rubato takes, whose expressive timing simply
    // doesn't lie on a single pulse grid), the loop LENGTH is the reliable
    // musical unit. The loop is then treated as a whole number of bars of
    // fallbackNum/fallbackDenom and the tempo is derived from the length
    // alone, so playback stays locked to the loop boundary no matter how
    // irregular the hits are. fallbackBars 0 = auto (pick the bar count whose
    // tempo sits nearest preferredBpm); > 0 forces that many bars.
    classvar <>fallbackNum = 4;
    classvar <>fallbackDenom = 4;
    classvar <>fallbackBars = 0;
    classvar <maxFallbackBars = 8;

    *initClass {
        standardMeters = [
            [2,4], [3,4], [4,4], [5,4], [6,4], [7,4],
            [5,8], [6,8], [7,8], [9,8], [11,8], [12,8]
        ];
        subdivisions = [1, 2, 4];
    }

    // `strengths` (optional) is a parallel array of onset saliences. When
    // present, candidates are re-ranked by how well the measured loudness
    // pattern matches each meter's accent template (see accentAlign), which
    // lets the music — not just the priors — decide the bar length and where
    // the downbeat sits. When nil, scoring reduces to the prior-only behavior.
    // `maxBars` (optional) overrides the maxK classvar for THIS call only.
    // Overdub detection needs it: an atmospheric opening loop tends to be long,
    // and a 12 s pad at 120 BPM is SIX bars of 4/4 — outside the default
    // enumeration entirely, so the fit would fail on exactly the loops the
    // feature exists for. First-take detection keeps the tighter default on
    // purpose: every extra bar count is another chance for a wrong meter to win
    // the scoring, which is how straight 4/4 takes came out as 7/8.
    // `minOnsetDensity` (optional, default 0 = off) rejects any candidate whose
    // grid has far more pulses than there are onsets to justify it. Widening the
    // bar search makes this necessary: a 56-pulse grid will always "fit" five
    // scattered onsets, so without it a rubato take gets confidently reported as
    // 7/4 and would start Live's transport on nothing. Expressed as onsets per
    // pulse, so it tightens automatically as the grid gets finer. Off by default
    // to leave first-take detection — which is tuned against the training loops —
    // exactly as it was.
    // `leadIn` (optional, seconds from the record press to the first onset)
    // turns on the uneven-bars detection (analyzeUneven), which counts its bars
    // from the press: the first take's path gives it, the overdub detection
    // (whose onsets are folded onto a loop already playing) does not. With no
    // even reading it answers instead of the length-anchored fallback when it
    // is sure; with one, its uneven reading goes second on the ranked list, so
    // the next-reading switch reaches it in one press.
    *analyze { |loopDur, onsets, strengths, maxBars, minOnsetDensity = 0, leadIn|
        var best, bestScore = -inf, uneven;
        var kMax = (maxBars ? maxK).asInteger.max(1);
        // Every reading that passes the fit, with its score. The perception map
        // (docs/dev/meter-perception.md) found the wrong answers to be near-ties,
        // so what came SECOND is worth returning: a correction can offer "the
        // next reading" instead of asking the player to name one. Flat arrays
        // in the loop; Events for the top few are built once at the end.
        var passed = List.new;

        if(onsets.size < 2) {
            ^(numerator: nil, denominator: nil, bpm: nil,
                error: \insufficientOnsets, onsetCount: onsets.size)
        };

        standardMeters.do { |meter|
            var num = meter[0];
            var denom = meter[1];
            (1..kMax).do { |k|
                subdivisions.do { |sub|
                    var n = k * num * sub;
                    // Every variable of the candidate test is declared HERE, at
                    // the top of the block, and not inside the nested `if`s
                    // below where each is first needed. That is not style: with
                    // the declarations inside the inlined `if` blocks, sclang
                    // 3.13 compiles this method into code that, on a specific
                    // path through the nesting, writes the winning `score` one
                    // slot BELOW the method's own frame — into the caller's
                    // operand stack. The caller then finds a Float where it left
                    // a Symbol or a half-built Array, and dies somewhere
                    // unrelated. Found on 2026-09-25 by scripts/probe-meter.scd
                    // on a clean two-bar 3/4 take at 185 BPM; bisected by
                    // rewriting a copy of this loop four ways, and hoisting the
                    // declarations was the one change that made it stop.
                    // test-meter-analyzer.scd pins that exact input with a
                    // detector that reads a marker sitting under the call.
                    var refinedTau, refinedLoop, driftRel, bpm, fit, accent, score;
                    if(n <= maxN and: { onsets.size >= (n * minOnsetDensity) }) {
                        refinedTau = this.fitTau(loopDur, n, onsets);
                        refinedLoop = refinedTau * n;
                        driftRel = (refinedLoop - loopDur).abs / loopDur;
                        if(driftRel <= loopTolerance) {
                            bpm = 240 * k * num / (denom * refinedLoop);
                            if(bpm >= bpmRangeLo and: { bpm <= bpmRangeHi }) {
                                fit = this.scorePulse(refinedTau, onsets);
                                if(fit.fit >= fitThreshold and: { fit.err <= errThreshold }) {
                                    accent = this.accentAlign(
                                        refinedTau, num, denom, sub, onsets, strengths);
                                    score = fit.fit
                                        + (accent.score * accentWeight)
                                        - (sub * 0.5)
                                        - (k * 0.1)
                                        - ((bpm.log - preferredBpm.log).abs * 0.2)
                                        - (driftRel * 0.5);
                                    passed.add([score, num, denom, k, sub, refinedTau,
                                        refinedLoop, bpm, accent.phase, accent.score, n]);
                                    if(score > bestScore) {
                                        bestScore = score;
                                        best = (
                                            numerator: num, denominator: denom, bpm: bpm,
                                            n: n, tau: refinedTau, k: k, sub: sub,
                                            loopDur: refinedLoop,
                                            phase: accent.phase,
                                            downbeatOffset: accent.phase * refinedTau,
                                            accent: accent.score,
                                            onsetCount: onsets.size
                                        );
                                    };
                                };
                            };
                        };
                    };
                };
            };
        };

        // No pulse grid fit: anchor the meter to the loop length instead of
        // guessing a blind 4/4. analyze() only sees the post-first-onset span,
        // so this is a best-effort estimate; a caller that knows the full
        // recorded length (the Looper) re-anchors with anchorToLength to fold
        // in any leading silence and stay exactly locked to the loop.
        uneven = leadIn !? { |lead|
            this.analyzeUneven(loopDur + lead, onsets + lead, strengths) };
        if(best.isNil) {
            ^uneven ?? { this.anchorToLength(loopDur, fallbackNum, fallbackDenom, onsets.size) }
        };

        // The answer carries its own score and the ranked list it won; a
        // length-anchored result carries neither, because nothing fit and there
        // is no next reading to offer.
        best[\score] = bestScore;
        best[\candidates] = this.prRankCandidates(passed, onsets.size);
        uneven !? { |u|
            best[\candidates] = best[\candidates].insert(1, u.copy.put(\candidates, nil)) };
        ^best
    }

    // The readings that passed the fit, best first, capped at maxCandidates,
    // shaped like the answer itself so Looper.snapAnalysisToLoop accepts any of
    // them (on a copy — the snap writes k, n and loopDur). The sort is stable
    // and the loop chose `best` with a strict >, so on a tie the first reading
    // the loop met is both the answer and the head of this list.
    *prRankCandidates { |passed, onsetCount|
        ^passed.asArray.sort { |a, b| a[0] >= b[0] }.keep(maxCandidates).collect { |c|
            (score: c[0], numerator: c[1], denominator: c[2], k: c[3], sub: c[4],
                tau: c[5], loopDur: c[6], bpm: c[7], n: c[10],
                phase: c[8], downbeatOffset: c[8] * c[5], accent: c[9],
                onsetCount: onsetCount)
        }
    }

    // Derive a meter purely from the loop LENGTH (not onset micro-timing).
    // The loop is exactly `bars` bars of num/denom by construction, so
    // tau * n == loopDur and the result stays perfectly in sync with the loop
    // boundary — the robust choice for takes no pulse grid fits.
    *anchorToLength { |loopDur, num, denom, onsetCount = 0|
        var bars = this.chooseBars(loopDur, num, denom);
        var n    = bars * num;           // denominator-unit pulses (sub = 1)
        var tau  = loopDur / n;          // one denominator unit
        var bpm  = 240 / (denom * tau);  // quarter-note BPM (matches main path)
        ^(numerator: num, denominator: denom, bpm: bpm,
            n: n, tau: tau, k: bars, sub: 1,
            loopDur: loopDur, phase: 0, downbeatOffset: 0, accent: 0,
            onsetCount: onsetCount, error: \lengthAnchored)
    }

    // ---- Uneven bars ---------------------------------------------------------
    // A reading whose bars are not all alike carries them: `bars`, one entry
    // per bar of the loop in denominator units, [7, 7, 7, 8] for three bars of
    // 7/8 and one of 8/8. `numerator` is then the commonest bar (the first of
    // the commonest on a tie), `k` the number of bars, and the invariant is
    // loopDur == tau * sub * (the sum of the bars). A reading whose bars ARE
    // alike has no `bars` key and k bars of its numerator, as every reading had
    // before, so the code that only knows numerator and k is right for it.
    // Read the bars through these, never `numerator * k`.

    // The bars of a reading, one per bar of the loop.
    *barsOf { |r|
        if(r.isNil) { ^[4] };
        ^r[\bars] ?? { Array.fill((r[\k] ? 1).asInteger.max(1), (r[\numerator] ? 4).asInteger.max(1)) }
    }

    // Denominator units in the loop: what numerator * k is for even bars.
    *unitsOf { |r| ^this.barsOf(r).sum }

    *isUneven { |r| ^r.notNil and: { r[\bars].notNil } }

    // The shortest run of bars whose repetition is the whole list: [7, 7, 7, 8]
    // for a multiplied 7 7 7 8 7 7 7 8, [7] for four bars of 7/8.
    *cycleOf { |bars|
        var size = bars.size;
        var p = (1..size.max(1)).detect { |len|
            ((size % len) == 0) and: { bars.every { |b, i| b == bars[i % len] } } };
        ^bars.keep(p ? size)
    }

    // "7/8", or for uneven bars the cycle's: "7+7+7+8/8".
    *sigString { |r|
        if(r.isNil or: { r[\denominator].isNil }) { ^"—" };
        ^if(this.isUneven(r)) { this.cycleOf(r[\bars]).join("+") } { r[\numerator].asString }
            ++ "/" ++ r[\denominator]
    }

    // `r` with these bars: k, numerator and n from them, and `bars` only when
    // they differ (all alike, the key goes). Changes r and answers it; the
    // pulse and the length are the caller's.
    *putBars { |r, bars|
        bars = bars.asArray.collect { |b| b.asInteger.max(1) };
        if(bars.isEmpty) { ^r };
        if(bars.every { |b| b == bars[0] }) {
            r.removeAt(\bars);
            r[\numerator] = bars[0];
        } {
            r[\bars] = bars;
            r[\numerator] = bars.maxItem { |b| bars.occurrencesOf(b) };
        };
        r[\k] = bars.size;
        r[\n] = bars.sum * (r[\sub] ? 1);
        ^r
    }

    // A reading of `bars` (one cycle, in units of 1/denom) over exactly
    // loopDur: as many cycles as put the tempo nearest `nearBpm` (the reading
    // in force, when there is one; else preferredBpm), the pulse the length
    // over the units. Not detected: `from: \hand` says the player gave it.
    *readingOfBars { |loopDur, bars, denom, nearBpm, onsetCount = 0|
        var cycle = bars.asArray.collect { |b| b.asInteger.max(1) };
        var units = cycle.sum, ref = (nearBpm ? preferredBpm), best = 1, bestErr = inf, tau, r;
        (1..maxFallbackBars).do { |c|
            var bpm = 240 * units * c / (denom * loopDur);
            var err = (bpm.log - ref.log).abs;
            if(bpm < bpmRangeLo or: { bpm > bpmRangeHi }) { err = err + 10 };
            if(err < bestErr) { bestErr = err; best = c };
        };
        tau = loopDur / (units * best);
        r = (denominator: denom, sub: 1, tau: tau, bpm: 240 / (denom * tau),
            loopDur: loopDur, phase: 0, downbeatOffset: 0, accent: 0,
            onsetCount: onsetCount, from: \hand);
        ^this.putBars(r, (cycle ! best).flatten)
    }

    // ---- Uneven bars, detected ----------------------------------------------
    // The bars of a take that are not all alike, from the onsets alone: three
    // bars of 7/8 and one of 8/8, say. `fullDur` is the take from the record
    // press, `onsets` from the press too, so bar 1 starts where the loop does.
    // Answers the best uneven reading, its ranked alternatives in
    // `candidates` (the odd bar elsewhere, the other denominator), or nil when
    // it is not sure or the bars come out even (the standard meters' business).
    //
    //   1. The pulse: the coarsest grid of n pulses over the whole take that
    //      the onsets fit (fitTau, scorePulse, the gates the meters pass), and
    //      whose n pulses meet the take's length within the snap's limit.
    //   2. The bar: the period at which the riff repeats, the autocorrelation
    //      of the onsets' strengths on that grid, shortest of the near-best.
    //   3. The bars: whole bars of that period, one or two of them up to
    //      unevenMaxDev pulses off, at every position; scored by how alike the
    //      bars are (each against their fold), the hits on their bar lines,
    //      an odd bar last a little up and two odd bars down.
    *analyzeUneven { |fullDur, onsets, strengths|
        var pulse, prof, profC, periods, scored, readings, seen;
        if(onsets.size < 4 or: { fullDur.isNil } or: { fullDur <= 0 }) { ^nil };
        pulse = this.prUnevenPulse(fullDur, onsets);
        if(pulse.isNil) { ^nil };
        // Two profiles of the same hits: compressed, where that a hit is there
        // counts most (the period: one loud hit drowned the riff's), and raw
        // (the bar lines: compressed, every eighth of a dense take looks alike).
        prof = this.prPulseProfile(onsets, strengths, pulse);
        periods = this.prBarPeriods(this.prPulseProfile(onsets, strengths, pulse, true));
        this.prBarPeriods(prof).do { |per|
            if(periods.any { |x| x[\m] == per[\m] }.not) { periods = periods.add(per) } };
        if(periods.isEmpty) { ^nil };
        scored = List.new;
        profC = this.prPulseProfile(onsets, strengths, pulse, true);
        periods.do { |per|
            this.prBarHypotheses(pulse[\n], per[\m]).do { |bars|
                scored.add(this.prScoreBars(profC, prof, bars, per[\m]).put(\bars, bars).put(\ac, per[\ac]));
            };
        };
        scored = scored.asArray.sort { |a, b| a[\score] >= b[\score] };
        // An even best is a standard meter's to find; a poor fit is no answer.
        if(scored.isEmpty or: { this.prAllAlike(scored[0][\bars]) }
            or: { scored[0][\fit] < unevenFitFloor }) { ^nil };
        readings = List.new;
        seen = List.new;
        scored.do { |h|
            if(this.prAllAlike(h[\bars]).not and: { seen.any { |b| b == h[\bars] }.not } and: { seen.size < 4 }) {
                seen.add(h[\bars]);
                readings.addAll(this.prUnevenReadings(h, pulse, onsets.size));
            };
        };
        if(readings.isEmpty) { ^nil };
        readings = readings.asArray.sort { |a, b| a[\unevenScore] >= b[\unevenScore] }.keep(maxCandidates);
        ^readings[0].copy.put(\candidates, readings)
    }

    *prAllAlike { |bars| ^bars.every { |b| b == bars[0] } }

    // The coarsest pulse grid over the take that the onsets fit, and whose n
    // pulses meet the take's length within half a pulse (the stop press).
    // The grid is t = phase + p * tau, both fitted (prPhaseFit): an onset
    // detector reports every hit some milliseconds late, and a player sits
    // behind or ahead of the beat, which a grid pinned to the press or to
    // the first onset (a faint click at the press, on the duo's first takes)
    // takes for timing errors. `phase` is wrapped to within half a pulse of
    // the press, so a take that begins with a rest counts its first hit from
    // pulse 1. `gridFit` is the share of onsets on the grid, for the snap
    // (Looper.prSnapFits trusts a grid this good with half a pulse).
    // (n:, tau:, phase:, gridFit:) or nil.
    *prUnevenPulse { |fullDur, onsets|
        var nLo = (fullDur / unevenPulse[1]).ceil.asInteger.max(4);
        var nHi = (fullDur / unevenPulse[0]).floor.asInteger.min(maxN);
        // (a..b) counts DOWN when a > b: no grid in range is no pulse.
        if(nLo > nHi) { ^nil };
        (nLo..nHi).do { |n|
            var fit = this.prPhaseFit(fullDur / n, onsets), tau = fit[0], phi = fit[1];
            var errs, tol, share;
            if(((tau * n) - fullDur).abs <= (tau * 0.5)) {
                // scorePulse's gates, with the tolerance in seconds capped.
                errs = onsets.collect { |t| ((t - phi) - (((t - phi) / tau).round * tau)).abs };
                tol = (onsetTolerance * tau).min(unevenOnsetSecs);
                share = errs.count { |e| e < tol } / errs.size;
                if((share >= fitThreshold) and: { (errs.mean / tau) <= errThreshold }) {
                    ^(n: n, tau: tau, phase: phi - ((phi / tau).round * tau), gridFit: share)
                };
            };
        };
        ^nil
    }

    // Least squares for t = phase + p * tau with p the nearest pulse, four
    // rounds from tau0 and the first onset. [tau, phase].
    *prPhaseFit { |tau0, onsets|
        var tau = tau0, phi = onsets[0], nn = onsets.size, ps, sp, spp, st, spt, den;
        4.do {
            ps = onsets.collect { |t| ((t - phi) / tau).round };
            sp = ps.sum;
            spp = (ps * ps).sum;
            st = onsets.sum;
            spt = (ps * onsets).sum;
            den = (nn * spp) - (sp * sp);
            if(den.abs > 1e-12) {
                tau = ((nn * spt) - (sp * st)) / den;
                phi = (st - (tau * sp)) / nn;
            };
        };
        ^[tau, phi]
    }

    // The onsets on the grid, counted from the press: per pulse the sum of
    // their strengths (1 each with none given), the loop's end wrapping to
    // its start.
    *prPulseProfile { |onsets, strengths, pulse, compressed = false|
        var tau = pulse[\tau], n = pulse[\n], prof = Array.fill(n, 0.0);
        var ref = this.prStrengthRef(strengths);
        onsets.do { |t, i|
            var p = ((t - pulse[\phase]) / tau).round.asInteger % n;
            var s = strengths !? { |x| x[i] };
            prof[p] = prof[p] + if(compressed) { this.prCompress(s, ref) } { (s ? 1).max(0) };
        };
        ^prof
    }

    // A hit's weight in the compressed profile: log(1 + strength / ref), ref a tenth of
    // the take's median strength, 1 with no strengths. Raw strengths span 50:1
    // on the duo's guitar (0.01 to 0.54 in one take), so one loud hit drowned
    // the riff's period (9 instead of 5 on their 5+5+5+8); compressed, that
    // there IS a hit counts most and how loud a little.
    *prCompress { |s, ref|
        if(s.isNil) { ^1 };
        ^(1 + (s.max(0) / ref)).log
    }
    *prStrengthRef { |strengths|
        var nz = (strengths ? []).select { |s| s > 0 };
        if(nz.isEmpty) { ^1 };
        ^(nz.asArray.sort[nz.size div: 2] * 0.1).max(1e-6)
    }

    // The periods the riff repeats at, in pulses: the autocorrelation of the
    // profile at every lag a bar can be (not around the loop: the odd bar
    // would break it), the best and every shorter or longer one within 0.1 of
    // it, at most three, each (m:, ac:). Empty when the best is under
    // unevenAcFloor or the profile has nothing to correlate.
    *prBarPeriods { |prof|
        var n = prof.size, acs = List.new, best, top = unevenBar[1].min(n div: 2);
        if(unevenBar[0] > top) { ^[] };
        (unevenBar[0]..top).do { |lag|
            acs.add((m: lag, ac: this.corr(prof.copyRange(0, n - lag - 1), prof.copyRange(lag, n - 1))));
        };
        if(acs.isEmpty) { ^[] };
        best = acs.collect { |a| a[\ac] }.maxItem;
        if(best < unevenAcFloor) { ^[] };
        // A riff that repeats every bar repeats every two bars too, often as
        // clearly (7+7+7+8 came out 14+15): a period with a shorter one inside
        // it that repeats nearly as well is that shorter one.
        ^acs.select { |a| a[\ac] >= (best - 0.1) }.asArray
            .sort { |a, b| a[\ac] >= b[\ac] }.keep(3)
            .collect { |a|
                acs.select { |x| (x[\m] < a[\m]) and: { (a[\m] % x[\m]) == 0 }
                    and: { x[\ac] >= (a[\ac] - 0.2).max(unevenAcFloor) } }
                    .asArray.sort { |p, q| p[\m] <= q[\m] }.first ? a
            }
            .inject([], { |acc, a| if(acc.any { |x| x[\m] == a[\m] }) { acc } { acc.add(a) } })
    }

    // Every barring of n pulses into bars of m with up to two odd ones: k
    // bars (n / m rounded down and up, at least 2), r = n - k * m pulses over;
    // none (all alike), one bar of m + r at each position, or two bars sharing
    // r (each off by 1..unevenMaxDev, the same way) at each pair.
    *prBarHypotheses { |n, m|
        var out = List.new, dev = unevenMaxDev;
        [(n / m).floor.asInteger, (n / m).ceil.asInteger].asSet.do { |k|
            var r = n - (k * m), splits;
            if((k >= 2) and: { k <= 32 }) {
                if(r == 0) { out.add(Array.fill(k, m)) };
                if((r != 0) and: { r.abs <= dev } and: { (m + r) >= 2 }) {
                    k.do { |i| out.add(Array.fill(k, m).put(i, m + r)) };
                };
                if(r.abs >= 2) {
                    splits = (1..dev).collect { |a| [a, r.abs - a] }
                        .select { |sp| (sp[1] >= 1) and: { sp[1] <= dev } }
                        .collect { |sp| sp * r.sign };
                    (k - 1).do { |i|
                        ((i + 1)..(k - 1)).do { |j|
                            splits.do { |sp|
                                if(((m + sp[0]) >= 2) and: { (m + sp[1]) >= 2 }) {
                                    out.add(Array.fill(k, m).put(i, m + sp[0]).put(j, m + sp[1]));
                                };
                            };
                        };
                    };
                };
            };
        };
        ^out.asArray
    }

    // One barring against the profiles: how alike its bars are (each bar's
    // first m pulses against the mean of all of them, by cosine, on the
    // compressed profile `prof`: which eighths are played), how strong the
    // hits on its bar lines are (on the raw one, `loud`, against its mean),
    // and the priors. (score:, fit:, accent:).
    *prScoreBars { |prof, loud, bars, m|
        var starts = bars.inject([0], { |acc, b| acc.add(acc.last + b) }).drop(-1);
        var ref = Array.fill(m, 0.0), cnt = Array.fill(m, 0), fit, accent, odd, score;
        var cosine = { |a, b|
            var den = ((a * a).sum * (b * b).sum).sqrt;
            if(den > 1e-12) { (a * b).sum / den } { 0 }
        };
        bars.do { |len, b|
            len.min(m).do { |j|
                ref[j] = ref[j] + prof[(starts[b] + j) % prof.size];
                cnt[j] = cnt[j] + 1;
            };
        };
        ref = ref.collect { |x, j| x / cnt[j].max(1) };
        fit = bars.collect { |len, b|
            var w = len.min(m);
            cosine.(Array.fill(w, { |j| prof[(starts[b] + j) % prof.size] }), ref.keep(w))
        }.mean;
        accent = starts.collect { |s| loud[s] }.mean / loud.mean.max(1e-9);
        odd = bars.count { |b| b != m };
        score = fit + (accent.min(3) * unevenAccent)
            + (if((odd == 1) and: { bars.last != m }) { unevenLastBonus } { 0 })
            - (if(odd >= 2) { unevenTwoOddCost } { 0 })
            - (bars.sum { |b| (b - m).abs } * unevenDevCost);
        ^(score: score, fit: fit, accent: accent)
    }

    // A barring in pulses as readings: over 8 and over 4 with a pulse to the
    // unit, and, for bars all of even length, with two pulses to the unit;
    // each in the tempo range, ranked as the meters' readings are (a tempo
    // near preferredBpm, one pulse to the unit).
    *prUnevenReadings { |h, pulse, onsetCount|
        var tau = pulse[\tau], out = List.new, opts = [[8, 1], [4, 1]];
        if(h[\bars].every(_.even)) { opts = opts ++ [[8, 2], [4, 2]] };
        opts.do { |o|
            var den = o[0], sub = o[1], bpm = 240 / (den * tau * sub), r;
            if((bpm >= bpmRangeLo) and: { bpm <= bpmRangeHi }) {
                r = (denominator: den, sub: sub, tau: tau, bpm: bpm, loopDur: pulse[\n] * tau,
                    phase: 0, downbeatOffset: 0, accent: h[\accent], onsetCount: onsetCount,
                    unevenFit: h[\fit], gridFit: pulse[\gridFit],
                    unevenScore: h[\score] - ((bpm.log - preferredBpm.log).abs * 0.2) - ((sub - 1) * 0.5));
                out.add(this.putBars(r, (h[\bars] / sub).collect(_.asInteger)));
            };
        };
        ^out
    }

    // Bar count for a length-anchored loop. fallbackBars > 0 forces it;
    // otherwise pick the count in 1..maxFallbackBars whose resulting tempo
    // sits closest to preferredBpm in log space, keeping it in the standard
    // bpm range. Ties resolve to fewer bars (the slower, simpler reading).
    *chooseBars { |loopDur, num, denom|
        var best, bestErr = inf;
        if(fallbackBars > 0) { ^fallbackBars };
        (1..maxFallbackBars).do { |bars|
            var bpm = 240 * bars * num / (denom * loopDur);
            var err = (bpm.log - preferredBpm.log).abs;
            if(bpm < bpmRangeLo or: { bpm > bpmRangeHi }) { err = err + 10 };
            if(err < bestErr) { bestErr = err; best = bars };
        };
        ^(best ? 1)
    }

    // Iterative least-squares: find tau that best places onsets on a grid of n pulses.
    *fitTau { |loopDur, n, onsets|
        var tau = loopDur / n;
        3.do {
            var p = onsets.collect { |t| (t / tau).round };
            var sumTP = (onsets * p).sum;
            var sumPP = (p * p).sum;
            if(sumPP > 0) { tau = sumTP / sumPP };
        };
        ^tau
    }

    *scorePulse { |tau, onsets|
        var errors = onsets.collect { |t|
            var k = (t / tau).round;
            (t - (k * tau)).abs / tau
        };
        ^(fit: errors.count(_ < onsetTolerance) / errors.size, err: errors.mean)
    }

    // How strongly the measured accent pattern matches this meter. Onset
    // strengths are folded into one bar (B = num*sub pulses); the fold is
    // correlated against the meter's accent template at every phase offset,
    // and the best phase (the most likely downbeat position, in pulses) is
    // returned alongside the correlation. Returns score 0 when no strengths
    // are supplied so scoring falls back to the priors.
    *accentAlign { |tau, num, denom, sub, onsets, strengths|
        var b = num * sub;
        var acc = Array.fill(b, 0.0);
        var template, best = -inf, bestPhase = 0;
        if(strengths.isNil) { ^(score: 0, phase: 0) };
        onsets.do { |t, i|
            var pulse = (t / tau).round.asInteger;
            var bin = pulse % b;
            acc[bin] = acc[bin] + (strengths[i] ? 0).max(0);
        };
        template = this.metricalTemplate(num, denom, sub);
        b.do { |phase|
            var rotated = Array.fill(b, { |r| acc[(r + phase) % b] });
            var c = this.corr(rotated, template);
            if(c > best) { best = c; bestPhase = phase };
        };
        ^(score: best.max(0), phase: bestPhase)
    }

    // Relative metrical weight of each pulse within one bar. The downbeat
    // dominates; beat-group heads are accented; bare denominator units sit
    // above plain subdivisions. Compound (x/8 in threes) and irregular
    // (5/8, 7/8, 11/8) meters group accordingly, so e.g. 6/8 and 3/4 — which
    // share a pulse grid — get distinct accent shapes.
    *metricalTemplate { |num, denom, sub|
        var b = num * sub;
        var w = Array.fill(b, 0.1);
        var groups = this.beatGrouping(num, denom);
        var pos = 0;
        num.do { |u| w[u * sub] = 0.3 };
        groups.do { |g|
            w[pos * sub] = 0.6;
            pos = pos + g;
        };
        w[0] = 1.0;
        ^w
    }

    // Beat grouping in denominator units. denom 8 with num divisible by 3 is
    // compound (groups of 3); other denom-8 meters are irregular and are
    // decomposed into twos with a trailing three (5→2+3, 7→2+2+3, 11→2+2+2+3).
    // Phase search rotates the template, so the specific starting rotation is
    // recovered from the audio. Everything else is one unit per beat.
    *beatGrouping { |num, denom|
        if(denom == 8) {
            if(num % 3 == 0) {
                ^Array.fill(num.div(3), 3)
            } {
                var groups = [], rem = num;
                while { rem > 4 } { groups = groups.add(2); rem = rem - 2 };
                if(rem == 4) {
                    groups = groups.add(2).add(2)
                } {
                    groups = groups.add(rem)
                };
                ^groups
            }
        } {
            ^Array.fill(num, 1)
        }
    }

    // Pearson correlation; 0 when either side has no variance.
    *corr { |a, b|
        var ma = a.mean, mb = b.mean;
        var da = a - ma, db = b - mb;
        var den = (da.squared.sum * db.squared.sum).sqrt;
        ^if(den > 1e-12) { (da * db).sum / den } { 0 }
    }
}
