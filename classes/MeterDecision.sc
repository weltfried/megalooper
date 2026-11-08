// megalooper — what a reading means for the loop, decided: the meter snapped
// onto a take's length, the playhead's bar and beat, the count to an event, a
// break's length, a reading's ticks and what it changes. Pure class methods:
// every argument they need is passed in, so the window, the offline
// harnesses (eval_meter_analyzer.scd, replay-session.scd, meter-eval.scd)
// and the tests ask the same decision the Looper does. Until 2026-11-08 these
// were the Looper's (docs/dev/architecture.md 3.3 and 5, step 8), and
// MeterAnalyzer reached into the Looper for its snap.
MeterDecision {

    // Snap a raw MeterAnalyzer result onto the take's ACTUAL length.
    //
    // Three cases. A clean grid fit keeps its tempo and re-derives the bar count
    // (bpm depends only on tau/denom/sub, so k/n/loopDur are safe to recompute);
    // a take that fits no grid is anchored to the full length as whole bars of
    // the user's fallback meter, or has none with the fallback off
    // (MeterAnalyzer.fallbackFor); anything else keeps the raw take.
    //
    // The guard: a grid fit may move the take by at most MeterAnalyzer.snapLimit
    // eighths, and never more than snapLimitSecs. Rounding a 7+7+7+8 take to
    // whole bars of 7/8 would cut the long bar off; a sparse 7+7+7+7+8 read as
    // 5/4 lost 448 ms that way. An answer
    // that would move the loop further gives way to the best reading that does
    // not, and with none the take is length-anchored, which keeps its length
    // exactly (or, with the fallback off, has no meter). The readings that
    // would move it are dropped from the ranked list, so the next-reading
    // switch never offers one. `snapRefused` on the
    // result says what gave way and by how much. guard = false is readingFor's:
    // its readings were vetted against the take when it was analysed, and the
    // loop in force since then is whole bars of the answer (a multiply doubles
    // a reading's small drift with it).
    //
    // A CLASS method taking everything it needs as arguments, so the offline
    // harnesses can call the real decision instead of reproducing it — see
    // scripts/eval_meter_analyzer.scd, which carried its own copy of this and
    // could therefore score a take differently from the way the app decided it.
    *snapAnalysisToLoop { |result, loopSecs, guard = true|
        var fits, refused, out;
        if(result.isNil) { ^result };
        if(result[\error].isNil) {
            if(guard.not or: { this.snapFits(result, loopSecs) }) {
                if(guard and: { result[\candidates].notNil }) {
                    result[\candidates] = result[\candidates].select { |c|
                        this.snapFits(c, loopSecs) };
                };
                ^this.prSnapToBars(result, loopSecs)
            };
            refused = (numerator: result[\numerator], denominator: result[\denominator],
                k: this.prSnapCycles(result, loopSecs)
                    * MeterAnalyzer.cycleOf(MeterAnalyzer.barsOf(result)).size,
                moveMs: (this.prSnapMove(result, loopSecs) * 1000).round(1));
            fits = (result[\candidates] ? []).select { |c| this.snapFits(c, loopSecs) };
            out = if(fits.notEmpty) {
                this.prSnapToBars(fits[0].copy, loopSecs).put(\candidates, fits)
            } {
                MeterAnalyzer.fallbackFor(loopSecs, result[\onsetCount])
            };
            out[\snapRefused] = refused;
            ^out
        };
        if(result[\error] == \lengthAnchored) {
            ^MeterAnalyzer.fallbackFor(loopSecs, result[\onsetCount])
        };
        result[\loopDur] = loopSecs;
        ^result
    }

    // A grid fit made whole bars of the take. The unit is the reading's CYCLE:
    // one bar when its bars are alike, the whole run when they are not (7 7 7 8
    // snaps to whole 7 7 7 8s, never to 7 7 7). How many, and how far that
    // moves the take (seconds, + longer). Neither touches the result.
    *cycleDur { |r|
        ^r[\tau] * (r[\sub] ? 1) * MeterAnalyzer.cycleOf(MeterAnalyzer.barsOf(r)).sum
    }

    *prSnapCycles { |r, loopSecs|
        ^(loopSecs / this.cycleDur(r)).round.asInteger.max(1)
    }

    *prSnapMove { |r, loopSecs|
        ^(this.prSnapCycles(r, loopSecs) * this.cycleDur(r)) - loopSecs
    }

    // Within MeterAnalyzer.snapLimit eighths, an eighth being 30 / bpm seconds
    // whatever the denominator, and never more than snapLimitSecs unless the
    // reading's grid fits its onsets that well (gridFit >= snapTrustFit).
    *snapFits { |r, loopSecs|
        ^this.prSnapMove(r, loopSecs).abs
            <= this.snapLimitAt(r[\bpm], (r[\gridFit] ? 0) >= MeterAnalyzer.snapTrustFit)
    }

    *snapLimitAt { |bpm, trusted = false|
        var half = MeterAnalyzer.snapLimit * 30 / bpm;
        ^if(trusted) { half } { half.min(MeterAnalyzer.snapLimitSecs) }
    }

    *prSnapToBars { |r, loopSecs|
        var cycle = MeterAnalyzer.cycleOf(MeterAnalyzer.barsOf(r));
        var count = this.prSnapCycles(r, loopSecs), dur = this.cycleDur(r);
        MeterAnalyzer.putBars(r, (cycle ! count).flatten);
        r[\loopDur] = count * dur;
        ^r
    }

    // Fold a position in seconds onto the analysed grid.
    //
    // A CLASS method taking everything as arguments, for the same reason
    // snapAnalysisToLoop above is one: the headless harness can test the real
    // arithmetic instead of a copy that is free to drift from it.
    //
    // Returns an Event. `fraction` (0..1 through the loop) is ALWAYS present —
    // that is the progress bar, and it needs no meter. `bar` and `beat` are nil
    // whenever there is no grid to count on: no result, a failed or
    // length-anchored analysis, or a loop of zero length. A caller that gets nil
    // shows elapsed/total alone rather than inventing a beat.
    //
    // Units, which are easy to get wrong here: tau is ONE PULSE, and a pulse is
    // a denominator unit divided by sub (MeterAnalyzer enumerates n = k*num*sub
    // pulses). So a musical beat is tau*sub and a bar is tau*num*sub. Counting
    // in tau alone reports 7/8 as though it had 14 beats to the bar whenever the
    // fit came back with sub = 2.
    //
    // Uneven bars (MeterAnalyzer.barsOf): `bars` is the length of every bar of
    // the loop in beats, `beatsPerBar` the length of the bar the playhead is
    // in, and the bars repeat every cycle of them, so a loop that has grown
    // since its reading still counts bar by bar.
    *loopPositionAt { |posSecs, result, loopDur|
        var pos, beatDur, beatsPerBar, totalBeats, beat;
        var bars, units, cycles, within, idx = 0, start = 0;
        var out = (bar: nil, beat: nil, barCount: nil, beatsPerBar: nil, bars: nil, fraction: 0);
        if(posSecs.isNil or: { loopDur.isNil } or: { loopDur <= 0 }) { ^out };
        pos = posSecs.clip(0, loopDur);
        out[\fraction] = pos / loopDur;
        if(result.isNil or: { result[\error].notNil }) { ^out };
        beatsPerBar = result[\numerator];
        beatDur     = result[\tau] !? { |t| t * (result[\sub] ? 1) };
        if(beatDur.isNil or: { beatDur <= 0 }
            or: { beatsPerBar.isNil } or: { beatsPerBar < 1 }) { ^out };
        // Beat one is where the TRANSPORT's beat one is, not where the analyser
        // guessed it. For a first take that is the record press — frame 0, the
        // point the MIDI Start is aligned to, the cutter's beat 0 and the
        // break's resume — so nothing is subtracted. A meter detected from an
        // overdub arrives mid-loop with no press to anchor to; there
        // detectMeterFromOverdub stores `downbeatPhase`, the absolute loop
        // position it holds Live's Start for, and the count starts from that.
        //
        // Until 2026-09-25 this subtracted `downbeatOffset`, the analyser's
        // accent-derived estimate. That put the header's bar 1 beat 1 somewhere
        // Live, the cutter and the break did not agree on whenever a take began
        // with a pickup — and the estimate is measured from the first onset,
        // not from frame 0, so it was off by the lead-in even when they did.
        // Decided for the press (docs/dev/signals.md, "One downbeat"); the estimate
        // stays in the result as what the analyser thought.
        //
        // The epsilon is not cosmetic: (0.35 - 0.1) / 0.25 is 0.9999999999999998
        // in doubles, so a playhead exactly ON a beat boundary floors to the
        // PREVIOUS beat. A microbeat of slack puts it on the beat it is on.
        totalBeats = (loopDur / beatDur).round.asInteger.max(1);
        beat = (((pos - (result[\downbeatPhase] ? 0)) / beatDur) + 1e-6)
            .floor.asInteger.mod(totalBeats);
        bars   = MeterAnalyzer.barsOf(result);
        units  = bars.sum;
        cycles = (totalBeats / units).round.asInteger.max(1);
        within = beat mod: units;
        while { (idx < (bars.size - 1)) and: { (start + bars[idx]) <= within } } {
            start = start + bars[idx];
            idx = idx + 1;
        };
        out[\bars]        = (bars ! cycles).flatten;
        out[\beatsPerBar] = bars[idx];
        out[\barCount]    = cycles * bars.size;
        out[\bar]         = ((beat div: units) * bars.size) + idx + 1;
        out[\beat]        = (within - start) + 1;
        ^out
    }

    // The count on Perform: where the playhead is in its bar's beat groups,
    // and how far an event on its way is. A class method on its arguments, as
    // loopPositionAt is, and built on it, so the count says what the header
    // says: `bar` and `beat` are loopPositionAt's, and every key of it is here.
    //
    // The groups are the analyser's (MeterAnalyzer.beatGrouping): 7/8 is
    // 2+2+3, an 8/8 bar 2+2+2+2, 12/8 3+3+3+3, 4/4 four groups of one beat.
    // Added to loopPositionAt's answer, nil where it has no grid:
    //   groups      the groups of the bar the playhead is in, in beats
    //   group       the group it is in, from 1; groupBeat, its beat in it
    //   nextBeatsPerBar  the bar the playhead comes to next
    //   barOdd, nextOdd  that bar, or the next, is the odd one of uneven bars
    //               (7 7 7 8: nextOdd all through the third bar)
    //   toEdge      seconds to the next beat line the playhead crosses
    //   countdown   given `until`, the seconds to an event on its way: in the
    //               last bar before it, the groups left, this one counted
    //               (3, 2, 1 in 7/8); nil until that bar
    //   loopsLeft   given `until`: the passes to it, from 1
    // Every event that can be counted to lands on a loop boundary, so its last
    // bar is the loop's last (its first when `reversed`). Backwards the
    // playhead plays the groups from the top, and counts down to the bar line
    // it reaches last.
    *beatCountAt { |posSecs, result, loopDur, until, reversed = false|
        var out = this.loopPositionAt(posSecs, result, loopDur);
        var beatDur, totalBeats, bars, units, y, x, idx, beat0, acc = 0, heads, e, c, within, start, i;
        out.putAll((groups: nil, group: nil, groupBeat: nil, nextBeatsPerBar: nil,
            barOdd: false, nextOdd: false, toEdge: nil, countdown: nil, loopsLeft: nil));
        if(out[\bar].isNil) { ^out };
        beatDur    = result[\tau] * (result[\sub] ? 1);
        totalBeats = (loopDur / beatDur).round.asInteger.max(1);
        bars       = MeterAnalyzer.barsOf(result);
        units      = bars.sum;
        // In beats from beat one, folded into the loop; x carries
        // loopPositionAt's microbeat, so a group changes where its beat does.
        y = ((posSecs.clip(0, loopDur) - (result[\downbeatPhase] ? 0)) / beatDur).mod(totalBeats);
        x = y + 1e-6;
        // The bar, and its groups
        idx   = (out[\bar] - 1) % bars.size;
        beat0 = out[\beat] - 1;
        out[\groups] = MeterAnalyzer.beatGrouping(out[\beatsPerBar], result[\denominator] ? 4);
        out[\group] = out[\groups].detectIndex { |g| acc = acc + g; beat0 < acc } + 1;
        out[\groupBeat] = beat0 - (out[\groups].keep(out[\group] - 1).sum) + 1;
        out[\nextBeatsPerBar] = bars.wrapAt(idx + (if(reversed) { -1 } { 1 }));
        out[\barOdd]  = MeterAnalyzer.isUneven(result) and: { out[\beatsPerBar] != result[\numerator] };
        out[\nextOdd] = MeterAnalyzer.isUneven(result) and: { out[\nextBeatsPerBar] != result[\numerator] };
        out[\toEdge] = beatDur * if(reversed) { y - y.ceil + 1 } { y.floor + 1 - y };
        if(until.isNil or: { until <= 0 }) { ^out };
        out[\loopsLeft] = ((until / loopDur) - 1e-9).ceil.asInteger.max(1);
        // The event, in beats on the same line, unfolded: past the loop's end,
        // or below its start backwards. Its last bar is the one the playhead
        // crosses into it from.
        e = y + ((if(reversed) { -1 } { 1 }) * until / beatDur);
        e = e + (if(reversed) { 1e-6 } { -1e-6 });
        c = (e / units).floor;
        within = e - (c * units);
        start = 0;
        i = 0;
        while { (i < (bars.size - 1)) and: { (start + bars[i]) <= within } } {
            start = start + bars[i];
            i = i + 1;
        };
        start = start + (c * units);
        if((x < start) or: { x >= (start + bars[i]) }) { ^out };
        acc = 0;
        heads = MeterAnalyzer.beatGrouping(bars[i], result[\denominator] ? 4)
            .collect { |g| var h = start + acc; acc = acc + g; h };
        out[\countdown] = if(reversed) {
            heads.count { |h| (h >= (e - 2e-6)) and: { h <= x } }
        } {
            heads.count { |h| (h > x) and: { h < e } } + 1
        };
        ^out
    }

    // How long a break lasts, given where the playhead is when it is struck.
    //
    // A CLASS method taking everything as arguments, for the same reason
    // snapAnalysisToLoop and loopPositionAt are: the arithmetic that decides
    // when the music comes back is worth testing without a server.
    //
    // = the rest of the current pass, plus `loops` - 1 whole passes. The pass the
    // break was struck in counts as the first one, so the default (1) ends at the
    // NEXT loop downbeat, and every value lands on a loop boundary. The cost of
    // that is a one-loop break lasting anything from a hair to a whole pass
    // depending on where the foot landed — stomping just before a downbeat buys
    // almost no silence at all. That is the honest reading of "come back on the
    // next downbeat"; ask for 2 when you want a guaranteed full pass of room.
    //
    // Backwards, the playhead runs loopDur -> 0 and wraps, so the distance to
    // the boundary IS the phase rather than what is left after it.
    // At half-time `speed` is the engine's (0.5) and `after` the speed once
    // the boundary is passed (a landing or a release armed): the rest of the
    // pass takes twice as long, and so does each pass at half speed.
    *breakDuration { |phase, loopDur, loops = 1, reversed = false, speed = 1, after|
        var remaining;
        if(loopDur.isNil or: { loopDur <= 0 }) { ^0 };
        // A nil phase means nothing could be read back; assume a whole pass
        // remains, which errs towards a longer break rather than a resume that
        // lands in the middle of one.
        remaining = if(phase.isNil) { loopDur } {
            if(reversed) { phase } { loopDur - phase }
        };
        ^(remaining.clip(0, loopDur) / speed) + ((loops.asInteger.max(1) - 1) * (loopDur / (after ? speed)))
    }

    // The take as reading `index` of `analysed` would have it, snapped to the
    // loop's actual length: the candidate's meter and pulse, with everything
    // that belongs to the TAKE rather than to the reading carried over — the
    // chord segments, an overdub detection's downbeat, the ranked list itself.
    // A class method so the arithmetic is testable without a server; index 0
    // is the analyser's own answer, nil when there is no such reading.
    *readingFor { |analysed, index, loopSecs|
        var cands = analysed !? { |a| a[\candidates] };
        var r;
        if(cands.isNil or: { index < 0 } or: { index >= cands.size }
            or: { loopSecs.isNil } or: { loopSecs <= 0 }) { ^nil };
        r = this.snapAnalysisToLoop(cands[index].copy, loopSecs, false);
        [\chordSegments, \chordPeriod, \downbeatPhase, \fromOverdub, \candidates].do { |key|
            analysed[key] !? { |v| r[key] = v };
        };
        r[\reading] = index;
        ^r
    }

    // On which of the next `maxWait` loop boundaries will Live's bar line fall
    // once this reading is in force there? `ticksAtNext` is Live's tick count
    // at the next boundary, `ticksPerLoop` what a loop adds under the reading
    // in force NOW, `newBarTicks` the new reading's bar in ticks. Returns loops
    // to wait, 1..maxWait, or nil when no boundary in reach lines up — the
    // caller then lands on the next one and re-sends Start if it may. With no
    // clock reference every boundary is as good as any other, so 1.
    //
    // Why this exists: Live counts bars in ticks from the Start it received. A
    // reading that changes how many quarters one loop holds — compound to
    // simple, or the other denominator — makes Live's bar line meet the loop
    // boundary only every so many loops; landing on one of those needs no
    // Start, and a Start is what a session recording cannot survive.
    *readingWait { |ticksAtNext, ticksPerLoop, newBarTicks, maxWait = 2|
        if(ticksAtNext.isNil or: { ticksPerLoop.isNil } or: { newBarTicks.isNil }
            or: { newBarTicks <= 0 }) { ^1 };
        (1..maxWait.max(1)).do { |w|
            var ticks = (ticksAtNext + ((w - 1) * ticksPerLoop)).round.asInteger;
            if((ticks % newBarTicks) == 0) { ^w };
        };
        ^nil
    }

    // Live counts 24 ticks per quarter note whatever the signature, so a bar
    // of num/denom is 96·num/denom ticks and a loop of k bars k times that.
    // Uneven bars give Live one bar per cycle of them (the signature
    // setup-model.scd sends it, 29/8 for 7 7 7 8), so its bar is the cycle.
    *barTicksOf  { |r|
        ^(96 * MeterAnalyzer.cycleOf(MeterAnalyzer.barsOf(r)).sum / r[\denominator]).round.asInteger
    }

    *loopTicksOf { |r| ^(96 * MeterAnalyzer.unitsOf(r) / r[\denominator]).round.asInteger }

    // The cutter reads the pulse and the pulse count and nothing else, so a
    // reading that keeps both — the other denominator, or half the bars —
    // leaves it running; one that changes the pulse respawns it.
    *readingChangesCutter { |from, to|
        var fromBeats, toBeats;
        if(from.isNil or: { to.isNil } or: { from[\tau].isNil } or: { to[\tau].isNil }) { ^true };
        fromBeats = if(from[\numerator].isNil) { 0 } { MeterAnalyzer.unitsOf(from) * (from[\sub] ? 1) };
        toBeats   = if(to[\numerator].isNil) { 0 } { MeterAnalyzer.unitsOf(to) * (to[\sub] ? 1) };
        ^(((from[\tau] - to[\tau]).abs > 1e-6) or: { fromBeats != toBeats })
    }

    *readingString { |r|
        ^(MeterAnalyzer.sigString(r) ++ " @ "
            ++ (r[\bpm] ? 0).round(0.1) ++ " BPM · " ++ (r[\k] ? 1)
            ++ " bar" ++ (if((r[\k] ? 1) > 1) { "s" } { "" }))
    }

    // The click's bars in pulses (tau each), one entry per bar of the loop.
    *clickBars { |r| ^MeterAnalyzer.barsOf(r) * (r[\sub] ? 1) }
}
