// Uneven bars: a reading whose bars are not all alike, three of 7/8 and one
// of 8/8 as ONE reading (MeterAnalyzer.barsOf). The arithmetic first — the
// helpers, the snap, the position, what Live, the click, the cutter and the
// drums are told — then bars given by hand (Looper.offerBars) on the
// server-free fixture, armed and landed like any reading.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-uneven-bars");

{
// 120 BPM: an eighth is 0.25 s, so 7 7 7 8 is 29 of them, 7.25 s.
var e8 = 0.25;
var r, s, pos, at, even;

// ---- the helpers --------------------------------------------------------------
~tEq.("even bars: k of the numerator", MeterAnalyzer.barsOf((numerator: 7, denominator: 8, k: 4)), [7, 7, 7, 7]);
~tEq.("no reading: one bar of 4", MeterAnalyzer.barsOf(nil), [4]);
~tEq.("uneven: the bars themselves", MeterAnalyzer.barsOf((numerator: 7, k: 4, bars: [7, 7, 7, 8])), [7, 7, 7, 8]);
~tEq.("the units in the loop", MeterAnalyzer.unitsOf((numerator: 7, k: 4, bars: [7, 7, 7, 8])), 29);
~tEq.("the cycle of a multiplied 7 7 7 8", MeterAnalyzer.cycleOf([7, 7, 7, 8, 7, 7, 7, 8]), [7, 7, 7, 8]);
~tEq.("...of even bars, one bar", MeterAnalyzer.cycleOf([7, 7, 7, 7]), [7]);
~tEq.("...of 7 7 7 8 7 7 7 9, all eight", MeterAnalyzer.cycleOf([7, 7, 7, 8, 7, 7, 7, 9]), [7, 7, 7, 8, 7, 7, 7, 9]);
~tEq.("in words, even", MeterAnalyzer.sigString((numerator: 7, denominator: 8, k: 4)), "7/8");
~tEq.("...uneven, the cycle", MeterAnalyzer.sigString((numerator: 7, denominator: 8, bars: [7, 7, 7, 8, 7, 7, 7, 8])),
    "7+7+7+8/8");
r = MeterAnalyzer.putBars((sub: 2), [7, 7, 7, 8]);
~tEq.("putBars: the commonest bar, the count, the pulses at the sub, the bars",
    [r[\numerator], r[\k], r[\n], r[\bars]], [7, 4, 58, [7, 7, 7, 8]]);
r = MeterAnalyzer.putBars((sub: 1, bars: [7, 7, 7, 8]), [7, 7, 7, 7]);
~tEq.("...all alike, and the key goes: an even reading as it always was",
    [r[\numerator], r[\k], r[\n], r[\bars]], [7, 4, 28, nil]);
~tEq.("...a tie goes to the first of the commonest", MeterAnalyzer.putBars((), [8, 7])[\numerator], 8);
~tAssert.("uneven only with the key", MeterAnalyzer.isUneven((bars: [7, 8]))
    and: { MeterAnalyzer.isUneven((numerator: 7, k: 4)).not } and: { MeterAnalyzer.isUneven(nil).not });

// ---- a reading of bars, given by hand ----------------------------------------------
r = MeterAnalyzer.readingOfBars(29 * e8, [7, 7, 7, 8], 8);
~tEq.("29 eighths of 7 7 7 8: one cycle, the commonest bar 7, from the hand",
    [r[\bars], r[\k], r[\numerator], r[\denominator], r[\sub], r[\from], r[\error]],
    [[7, 7, 7, 8], 4, 7, 8, 1, \hand, nil]);
~tNear.("...at 120 BPM", r[\bpm], 120, 1e-9);
~tNear.("...and tau times the units is the loop", r[\tau] * 29, 29 * e8, 1e-9);
s = MeterAnalyzer.readingOfBars(58 * e8, [7, 7, 7, 8], 8, 120);
~tEq.("a loop twice as long, near 120: two cycles", [s[\bars], s[\k]], [[7, 7, 7, 8, 7, 7, 7, 8], 8]);
~tNear.("...still 120", s[\bpm], 120, 1e-9);
s = MeterAnalyzer.readingOfBars(58 * e8, [7, 7, 7, 8], 8, 60);
~tEq.("...near 60: one cycle at 60", [s[\k], s[\bpm].round(1e-6)], [4, 60]);

// ---- the snap: whole cycles, never 7 7 7 ---------------------------------------------
s = Looper.snapAnalysisToLoop(r.copy, 58 * e8, false);
~tEq.("a doubled loop snaps to two cycles", s[\bars], [7, 7, 7, 8, 7, 7, 7, 8]);
~tNear.("...its whole length", s[\loopDur], 58 * e8, 1e-9);
s = Looper.snapAnalysisToLoop(r.copy, (29 * e8) + 0.05);
~tEq.("a stop press 50 ms late on 7 7 7 8 is corrected to the cycle", [s[\bars], s[\snapRefused]],
    [[7, 7, 7, 8], nil]);
~tNear.("...to 29 eighths", s[\loopDur], 29 * e8, 1e-9);
s = Looper.snapAnalysisToLoop(r.copy, 30 * e8);
~tEq.("an eighth more than 7 7 7 8 is not this reading", s[\error], \lengthAnchored);

// ---- the position: bar 4 has eight ---------------------------------------------------
pos = { |t, len| Looper.loopPositionAt(t, r, len ? (29 * e8)) };
at = pos.(0);
~tEq.("bar 1 beat 1, of 7, of 4 bars", [at[\bar], at[\beat], at[\beatsPerBar], at[\barCount]], [1, 1, 7, 4]);
~tEq.("...the bars for the grid", at[\bars], [7, 7, 7, 8]);
at = pos.((20 * e8) + 0.01);
~tEq.("the last eighth of bar 3 is beat 7", [at[\bar], at[\beat]], [3, 7]);
at = pos.((21 * e8) + 0.01);
~tEq.("then bar 4, of 8", [at[\bar], at[\beat], at[\beatsPerBar]], [4, 1, 8]);
at = pos.((28 * e8) + 0.01);
~tEq.("...to its beat 8", [at[\bar], at[\beat]], [4, 8]);
at = pos.((30 * e8) + 0.01, 58 * e8);
~tEq.("a loop grown to two cycles counts on: bar 5 beat 2 of 8 bars",
    [at[\bar], at[\beat], at[\barCount], at[\bars].size], [5, 2, 8, 8]);
even = (numerator: 7, denominator: 8, k: 4, sub: 1, tau: e8, bpm: 120, loopDur: 28 * e8);
at = Looper.loopPositionAt((14 * e8) + 0.01, even, 28 * e8);
~tEq.("even bars as before: bar 3 beat 1 of 7, 4 bars", [at[\bar], at[\beat], at[\beatsPerBar], at[\barCount]],
    [3, 1, 7, 4]);

// ---- what everything else is told ----------------------------------------------------
~tEq.("Live gets the cycle as one bar: 29/8 is 348 ticks", Looper.barTicksOf(r), 348);
~tEq.("...and the loop the same", Looper.loopTicksOf(r), 348);
~tEq.("even: a bar of 7/8 is 84 ticks", Looper.barTicksOf(even), 84);
~tEq.("...and four of them the loop", Looper.loopTicksOf(even), 336);
~tEq.("the click's bar lines, in pulses at sub 2", Looper.prClickBars(r.copy.put(\sub, 2)), [14, 14, 14, 16]);
~tAssert.("7 7 7 8 after 7/8 x4 at the same pulse: the cutter respawns (29 beats, not 28)",
    Looper.prReadingChangesCutter(even, r), "");
~tAssert.("...and not between a reading and itself", Looper.prReadingChangesCutter(r, r.copy).not, "");
~tEq.("the reading in words", Looper.prReadingString(r), "7+7+7+8/8 @ 120.0 BPM · 4 bars");
~tEq.("the drums put 58 sixteenths in it", MegaSADrums.sixteenthsFor(r), 58);
~tEq.("...the bars beginning at these ticks", MegaSADrums.barStartTicks(r), [0, 1680, 3360, 5040]);
~tEq.("...even 7/8 over two bars", MegaSADrums.barStartTicks((numerator: 7, denominator: 8, k: 2)), [0, 1680]);
~tEq.("...and no reading, one bar of 4/4", [MegaSADrums.sixteenthsFor(nil), MegaSADrums.barStartTicks(nil)], [16, [0]]);
~tEq.("the log keeps the bars and where they came from", [Looper.resultForLog(r)[\bars], Looper.resultForLog(r)[\from]],
    [[7, 7, 7, 8], \hand]);
}.value;

// ---- bars by hand, on a take that fit no grid ------------------------------------------
// 7 7 7 8 at 120: 7.25 s, which no even meter fits, so the analyser anchored
// it to the fallback. offerBars gives it the bars: a reading after the answer,
// armed for the next boundary and landed like one.
{
var l = ~tLooper.();
var analysed = MeterAnalyzer.anchorToLength(7.25, 7, 8, 20);
var land = {
    var rt;
    l.pendingReading[\at] = SystemClock.seconds - 0.01;
    rt = Routine { l.prLandReading(~tGet.(l, \readingSeq)) };
    ~tPut.(l, \readingRoutine, rt);
    rt.next;
};
var refused = List.new;
~tPut.(l, \state, \playing);
~tPut.(l, \loopFrames, (7.25 * 48000).asInteger);
~tPut.(l, \loopStartTime, SystemClock.seconds);
~tPut.(l, \lastResult, analysed);
~tPut.(l, \analysedResult, analysed);
SimpleController(l).put(\refused, { |lp, what, gesture, why| refused.add(gesture) });

~tEq.("a fallback offers nothing to begin with", l.readingCount, 0);
l.offerBars([7, 7, 7, 8], 8);
~tAssert.("bars by hand arm a reading", l.pendingReading.notNil and: { l.pendingReading[\index] == 1 },
    "pending " ++ l.pendingReading);
~tEq.("...after the analyser's own answer", l.readingCount, 2);
~tEq.("...which is still reading 0", l.analysedResult[\candidates][0][\error], \lengthAnchored);
~tAssert.("...and the take's own result is left alone (the undo snapshot holds it)",
    analysed[\candidates].isNil, "candidates " ++ analysed[\candidates]);
~tAssert.("no score, so no close call to show", l.readingMargin.isNil, "margin " ++ l.readingMargin);
land.();
~tEq.("landed: the take is 7 7 7 8", [l.lastResult[\bars], l.lastResult[\denominator], l.readingIndex],
    [[7, 7, 7, 8], 8, 1]);
~tNear.("...at 120 BPM", l.lastResult[\bpm], 120, 1e-6);
~tAssert.("...a meter the cutter can use", l.hasValidMeter, "");

l.offerBars([7, 7, 7, 8], 8);
~tEq.("the same bars again: the same reading, no second copy", [l.pendingReading[\index], l.readingCount], [1, 2]);
l.offerBars([7, 7, 7, 9], 8);
~tEq.("other bars: one more reading", [l.pendingReading[\index], l.readingCount], [2, 3]);
l.nextReading;
~tEq.("the switch passes through them, round to the answer", l.pendingReading[\index], 0);
l.revertReading;
~tEq.("revert goes to the analyser's answer", l.pendingReading[\index], 0);

l.prCancelReading;
refused = List.new;
l.offerBars([], 8);
l.offerBars([7, 0], 8);
l.offerBars([7, 7, 7, 8], 7);
~tEq.("no bars, a bar of none, a denominator of 7: refused", refused.asArray, [\offerBars, \offerBars, \offerBars]);
~tAssert.("...and nothing armed", l.pendingReading.isNil, "pending " ++ l.pendingReading);
~tPut.(l, \state, \stopped);
l.offerBars([7, 7, 7, 8], 8);
~tAssert.("stopped: refused", (refused.size == 4) and: { l.pendingReading.isNil }, "");
}.value;

// ---- uneven bars, detected ----------------------------------------------------------
// MeterAnalyzer.analyzeUneven through analyze, as the first take's path calls it
// (leadIn given). Synthetic hits on an eighth of 0.25 s: bar heads 1.0, the
// heads of the beat groups (2+2+3, 2+2+2+2, 2+2+2+3, 2+3) 0.7, the rest 0.35,
// every eighth played or the group heads only.
{
var e8 = 0.25;
var take = { |bars, dense, delay = 0|
    var t = List.new, s = List.new, pos = 0;
    bars.do { |len|
        var groups = switch(len, 5, { [2, 3] }, 6, { [2, 2, 2] }, 7, { [2, 2, 3] },
            8, { [2, 2, 2, 2] }, 9, { [2, 2, 2, 3] });
        var p = pos;
        groups.do { |g, gi|
            g.do { |u|
                if((u == 0) or: { dense }) {
                    t.add(((p + u) * e8) + delay);
                    s.add(if(u == 0) { if(gi == 0) { 1.0 } { 0.7 } } { 0.35 });
                };
            };
            p = p + g;
        };
        pos = pos + len;
    };
    (onsets: t.asArray, strengths: s.asArray, dur: pos * e8)
};
// The Looper's preparation: relative to the first onset, the span after it,
// the lead-in given, then the snap on the whole take.
var read = { |tk, lead = true|
    var first = tk[\onsets][0];
    Looper.snapAnalysisToLoop(MeterAnalyzer.analyze(tk[\dur] - first, tk[\onsets] - first,
        tk[\strengths], leadIn: if(lead) { first }), tk[\dur])
};
var r, tk, unevenOn;
unevenOn = { |res| (res[\candidates] ? []).select { |c| MeterAnalyzer.isUneven(c) } };

r = read.(take.([7, 7, 7, 8], true));
~tEq.("7+7+7+8, no meter fits it: the bars are the answer",
    [r[\bars], r[\denominator], r[\k], r[\error]], [[7, 7, 7, 8], 8, 4, nil]);
~tNear.("...at 120 BPM", r[\bpm], 120, 0.5);
~tNear.("...the loop kept to the eighth", r[\loopDur], 29 * e8, 0.01);
~tAssert.("...and its alternatives are the odd bar elsewhere",
    r[\candidates].drop(1).any { |c| c[\bars] == [7, 7, 8, 7] }, r[\candidates].collect { |c| c[\bars] }.asString);
r = read.(take.([7, 7, 7, 8], true, 0.025));
~tEq.("...with every hit reported 25 ms late, as an onset detector does", r[\bars], [7, 7, 7, 8]);
r = read.(take.([8, 7, 7, 7], true));
~tEq.("the odd bar first", r[\bars], [8, 7, 7, 7]);
r = read.(take.([7, 7, 7, 8, 7, 7, 7, 9], false));
~tEq.("two odd bars in eight, the group heads only", r[\bars], [7, 7, 7, 8, 7, 7, 7, 9]);
r = read.(take.([5, 5, 5, 6], false));
~tEq.("5+5+5+6, the group heads only", r[\bars], [5, 5, 5, 6]);
r = read.(take.([7, 7, 7, 8], true), false);
~tEq.("no lead-in, no detection (the overdub's path): the fallback as before", r[\error], \lengthAnchored);

r = read.(take.([7, 7, 7, 9], true));
~tEq.("7+7+7+9 is also three bars of 5, but its bars score clearly better on the same grid: they answer",
    r[\bars], [7, 7, 7, 9]);
~tAssert.("...the meter second, one press of the switch away",
    (r[\candidates][1] !? { |c| (c[\numerator] == 5) and: { c[\k] == 3 } and: { c[\bars].isNil } }) == true,
    r[\candidates].keep(3).collect { |c| Looper.prReadingString(c) }.asString);
r = read.(take.([7, 7, 7, 6], true));
~tAssert.("7+7+7+6 dense, no notes: a near tie with 9/8 x3, so the meter answers and the bars come second",
    (r[\numerator] == 9) and: { r[\bars].isNil } and: { r[\candidates][1][\bars] == [7, 7, 7, 6] },
    Looper.prReadingString(r));

[[[7, 7, 7, 7], "7/8 x4"], [[8, 8], "4/4 x2"], [[5, 5, 5, 5], "5/8 x4"], [[8, 8, 8, 8], "4/4 x4"]].do { |c|
    [true, false].do { |dense|
        tk = take.(c[0], dense);
        r = read.(tk);
        ~tAssert.(c[1] ++ (if(dense) { " dense" } { " sparse" }) ++ ": no uneven reading offered",
            r[\bars].isNil and: { unevenOn.(r).isEmpty }, Looper.prReadingString(r) ++ " "
                ++ unevenOn.(r).collect { |x| MeterAnalyzer.sigString(x) });
    };
};

// The pieces: the pulse is fitted from the first onset and counted from the
// press; the period is the shortest the riff repeats at.
tk = take.([7, 7, 7, 8], true);
r = MeterAnalyzer.prUnevenPulses(tk[\dur] + 0.25, tk[\onsets] + 0.25)[0];
~tEq.("a take that begins with an eighth's rest: 30 pulses, nothing on pulse 0, the first hit on pulse 1",
    [r[\n], MeterAnalyzer.prPulseProfile(tk[\onsets] + 0.25, tk[\strengths], r).keep(2).collect(_.sign)], [30, [0, 1]]);
// A grid that fits its onsets this well is trusted with the whole half eighth.
~tAssert.("its grid fit is recorded, for the snap", r[\gridFit] >= MeterAnalyzer.snapTrustFit, r[\gridFit].asString);
~tEqArray.("trusted, the snap may move it half an eighth (139 ms at 108 BPM), else 100 ms",
    [Looper.snapLimitAt(108, true), Looper.snapLimitAt(108)], [15 / 108, 0.1], 1e-9);
r = MeterAnalyzer.prBarPeriods(MeterAnalyzer.prPulseProfile(tk[\onsets], tk[\strengths],
    MeterAnalyzer.prUnevenPulses(tk[\dur], tk[\onsets])[0]));
~tEq.("the riff repeats every 7 (not 14)", r[0][\m], 7);
~tEq.("the barrings of 29 into 7s: one odd bar at each of four places",
    MeterAnalyzer.prBarHypotheses(29, 7).select { |b| b.count { |x| x != 7 } == 1 }.size, 4);
~tAssert.("...and of 59: 7 7 7 8 7 7 7 9 among the two odd ones",
    MeterAnalyzer.prBarHypotheses(59, 7).any { |b| b == [7, 7, 7, 8, 7, 7, 7, 9] }, "");
}.value;

// ---- the Looper with detected readings ---------------------------------------------
{
var l = ~tLooper.();
var even = { |num, score| (score: score, numerator: num, denominator: 8, k: 4, sub: 1, tau: 0.25,
    loopDur: num * 4 * 0.25, bpm: 120, n: num * 4, phase: 0, downbeatOffset: 0, accent: 0.4, onsetCount: 30) };
var uneven = MeterAnalyzer.putBars((denominator: 8, sub: 1, tau: 0.25, bpm: 120, loopDur: 7.5,
    phase: 0, downbeatOffset: 0, accent: 1.5, onsetCount: 30, unevenScore: 1.2), [7, 7, 7, 9]);
var answer = even.(5, 0.9).put(\denominator, 4).put(\k, 3);
answer[\candidates] = [answer.copy, uneven, even.(10, 0.85)];
~tPut.(l, \state, \playing);
~tPut.(l, \loopFrames, (7.5 * 48000).asInteger);
~tPut.(l, \loopStartTime, SystemClock.seconds);
~tPut.(l, \lastResult, answer);
~tPut.(l, \analysedResult, answer);
~tNear.("the margin skips the bars, to the next meter", l.readingMargin, 0.05, 1e-9);
~tEq.("the runner-up is the bars", l.runnerUp !? { |r| r[\bars] }, [7, 7, 7, 9]);
l.offerBars([7, 7, 7, 9], 8);
~tEq.("bars given by hand that the detection found arm its reading, no copy",
    [l.pendingReading[\index], l.readingCount], [1, 3]);
l.prCancelReading;
}.value;

// ---- the duo's labelled takes (2026-10-19) ----------------------------------------
// fixtures/uneven-takes.json: six takes of the duo's own, the onsets and the
// pitch the stage heard (for the first two, logged before the take carried its
// pitch, the replay's from the tap), and the bars they gave by hand.
//   261019_100238 7+7+7+8: every eighth played, its loudest hits off the
//     downbeats; the onsets alone carry no bar line, the notes do (the same
//     seven notes three times, then a descending turnaround)
//   261019_100113 5+5+5+8: its stop press 113 ms late, over the snap's cap
//   261019_120346 7+7+7+6: also three bars of 9/8, the bars win on its grid
//   261019_120507 9+9+9+4: the last bar five eighths short
//   261019_120233 7+7+7+6: hits off any strict grid by up to 140 ms, known
{
var takes = File.readAllString(thisProcess.nowExecutingPath.dirname +/+ "fixtures" +/+ "uneven-takes.json").parseJSON;
takes.do { |tk|
    var dur = tk["dur"].asFloat, on = tk["onsets"].collect { |p| p[0].asFloat };
    var st = tk["onsets"].collect { |p| p[1].asFloat }, want = tk["bars"].collect(_.asInteger);
    var pz = tk["pitches"].collect { |p| p.collect(_.asFloat) };
    var read = { |pitches| Looper.snapAnalysisToLoop(MeterAnalyzer.analyze(dur - on[0], on - on[0], st,
        leadIn: on[0], pitches: pitches), dur) };
    var r = read.(pz), label = tk["set"] ++ ": " ++ want.join("+") ++ " from the stage's onsets and the notes";
    if(tk["expect"] == "found") {
        ~tEq.(label, r[\bars], want);
    } {
        ~tXfail.(label, r[\bars] != want, Looper.prReadingString(r) ++ " — no strict grid fits its hits");
    };
    if(tk["set"] == "261019_100113") {
        ~tNear.("...its stop press 113 ms late corrected: a grid all its onsets sit on is trusted",
            r[\loopDur], dur - 0.113, 0.01);
        ~tEq.("...and from the onsets alone", read.(nil)[\bars], want);
    };
    if(tk["set"] == "261019_100238") {
        ~tXfail.("...and from the onsets alone, every eighth played", read.(nil)[\bars] != want,
            Looper.prReadingString(read.(nil)) ++ " — the onsets carry no bar line");
    };
};
}.value;

// The notes, synthetic: every eighth played at one loudness, so the hits show
// no bar at all; three bars of a riff and a turnaround, each note read by the
// pitch tracker three times after its hit.
{
var e8 = 0.25, riff = [40, 40, 47, 47, 45, 45, 43], turn = [44, 44, 43, 43, 42, 42, 41, 41];
var notes = riff ++ riff ++ riff ++ turn, on = notes.collect { |m, i| i * e8 };
var st = Array.fill(notes.size, 0.5), pz = List.new, r;
notes.do { |m, i| [0.04, 0.08, 0.12].do { |d| pz.add([(i * e8) + d, m.midicps, 0.1]) } };
r = Looper.snapAnalysisToLoop(MeterAnalyzer.analyze(29 * e8, on, st, leadIn: 0, pitches: pz.asArray), 29 * e8);
~tEq.("flat hits, the notes repeating: 7+7+7+8", r[\bars], [7, 7, 7, 8]);
r = Looper.snapAnalysisToLoop(MeterAnalyzer.analyze(29 * e8, on, st, leadIn: 0), 29 * e8);
~tAssert.("...the same hits without the notes: not those bars", r[\bars] != [7, 7, 7, 8], Looper.prReadingString(r));
~tEq.("a note per onset: the median of its readings", MeterAnalyzer.prOnsetNotes(on.keep(2), pz.asArray.keep(6))
    .collect { |m| m !? { |x| x.round(1e-6) } }, [40, 40]);
~tEq.("...none without readings", MeterAnalyzer.prOnsetNotes(on.keep(2), nil), nil);
}.value;

// ---- the label: bars given by hand count once armed --------------------------------
// A set stopped before the next boundary logs the arming and not the landing;
// the bars the player typed are the label all the same.
{
var hand = (numerator: 7, denominator: 8, k: 4, bars: [7, 7, 7, 8], bpm: 107.5, from: \hand);
var other = (numerator: 7, denominator: 4, k: 4, bpm: 200);
var take = (ev: "take", t: 10.0, start: 2.0, dur: 8.0, onsets: [], result: (numerator: 7, denominator: 8, k: 4,
    error: \lengthAnchored), candidates: []);
var x = LooperSessionRecorder.takesFrom([
    (ev: "recordStart", t: 2.0), take,
    (ev: "readingArmed", t: 30.0, index: 1, via: "hand", reading: hand),
    (ev: "sessionStop", t: 31.0)])[0];
~tEq.("armed by hand, not landed: corrected, the bars its label", [x[\outcome], x[\label][\bars], x[\byHand]],
    [\corrected, [7, 7, 7, 8], true]);
x = LooperSessionRecorder.takesFrom([
    (ev: "recordStart", t: 2.0), take,
    (ev: "readingArmed", t: 30.0, index: 1, via: "next", reading: other),
    (ev: "sessionStop", t: 31.0)])[0];
~tEq.("armed by the switch and not landed: no label, as before", [x[\outcome], x[\label]], [\reverted, nil]);
x = LooperSessionRecorder.takesFrom([
    (ev: "recordStart", t: 2.0), take,
    (ev: "readingArmed", t: 30.0, index: 1, via: "hand", reading: hand),
    (ev: "readingArmed", t: 31.0, index: 0, via: "revert", reading: take[\result]),
    (ev: "sessionStop", t: 32.0)])[0];
~tEq.("by hand, then reverted before it landed: no label", [x[\outcome], x[\label]], [\reverted, nil]);
}.value;
