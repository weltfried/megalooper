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
    *analyze { |loopDur, onsets, strengths, maxBars, minOnsetDensity = 0|
        var best, bestScore = -inf;
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
        if(best.isNil) {
            ^this.anchorToLength(loopDur, fallbackNum, fallbackDenom, onsets.size)
        };

        // The answer carries its own score and the ranked list it won; a
        // length-anchored result carries neither, because nothing fit and there
        // is no next reading to offer.
        best[\score] = bestScore;
        best[\candidates] = this.prRankCandidates(passed, onsets.size);
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
