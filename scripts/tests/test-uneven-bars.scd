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
