// The next reading — one footswitch that moves a take to the analyser's
// runner-up, then the one after, round to its own answer (roadmap item 9).
//
// Pure arithmetic first: what a reading makes of the take, on which boundary
// it may land so Live's bar line agrees, and whether the cutter has to be
// respawned for it. Then the gesture on the server-free fixture: arming,
// advancing, wrapping, refusing, cancelling, and the landing driven through a
// routine synchronously — the pattern test-break.scd uses, because a landing
// stops the routine it runs inside.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-reading");

{
// A 6/8 take, two bars, eighth 0.25 s, 3 s of loop, as the analyser returns
// it: the answer first, then 12/8 in one bar (the merge the perception map
// found at every tempo), then 3/4 at sub 2, then 4/4 with a pulse three times
// as long. Scores descending; the runner-up is close.
var cand = { |num, denom, k, sub, tau, bpm, score|
    (score: score, numerator: num, denominator: denom, k: k, sub: sub, tau: tau,
        loopDur: 3.0, bpm: bpm, n: num * sub * k, phase: 0, downbeatOffset: 0,
        accent: 0.4, onsetCount: 12)
};
var analysed = cand.(6, 8, 2, 1, 0.25, 120, 0.9);
var seg = [(root: 2, scaleName: "Minor", start: 0)];
var landed, notified, l, r, midi, gran;

analysed[\chordSegments] = seg;
analysed[\candidates] = [
    cand.(6,  8, 2, 1, 0.25, 120, 0.9),
    cand.(12, 8, 1, 1, 0.25, 120, 0.85),
    cand.(3,  4, 2, 2, 0.25, 120, 0.6),
    cand.(4,  4, 1, 1, 0.75, 80,  0.2)
];

// ---- readingFor -------------------------------------------------------------
r = Looper.readingFor(analysed, 0, 3.0);
~tEq.("reading 0 is the answer's meter", [r[\numerator], r[\denominator], r[\k]], [6, 8, 2]);
~tEq.("reading 0 says which reading it is", r[\reading], 0);
~tAssert.("the chord segments come along", r[\chordSegments] === seg, "not carried");
~tAssert.("the ranked list comes along", r[\candidates] === analysed[\candidates], "not carried");

r = Looper.readingFor(analysed, 1, 3.0);
~tEq.("reading 1 is the runner-up", [r[\numerator], r[\denominator], r[\k]], [12, 8, 1]);
~tNear.("reading 1 keeps the loop whole: tau*num*sub*k is the loop",
    r[\tau] * r[\numerator] * (r[\sub] ? 1) * r[\k], 3.0, 1e-9);
~tNear.("reading 1's tempo is the quarter-note tempo of that meter", r[\bpm], 120, 1e-6);

r = Looper.readingFor(analysed, 3, 3.0);
~tEq.("reading 3 is the slow 4/4", [r[\numerator], r[\denominator], r[\k]], [4, 4, 1]);
~tNear.("reading 3 has the pulse three times as long", r[\tau], 0.75, 1e-9);

// A multiplied loop: the candidate's bar count is re-derived from the length
// in force, and the candidate itself is untouched by the snap.
r = Looper.readingFor(analysed, 1, 6.0);
~tEq.("on a doubled loop reading 1 is two bars of 12/8", r[\k], 2);
~tEq.("the candidate in the list still says one bar", analysed[\candidates][1][\k], 1);

~tAssert.("no such reading -> nil", Looper.readingFor(analysed, 4, 3.0).isNil, "got a result");
~tAssert.("nothing analysed -> nil", Looper.readingFor(nil, 0, 3.0).isNil, "got a result");
~tAssert.("no loop -> nil", Looper.readingFor(analysed, 1, 0).isNil, "got a result");

// ---- does the cutter need respawning ----------------------------------------
~tAssert.("6/8 x2 -> 12/8 x1 keeps the pulse and the pulse count: no respawn",
    Looper.prReadingChangesCutter(analysed[\candidates][0], analysed[\candidates][1]).not, "");
~tAssert.("6/8 x2 -> 3/4 x2 sub 2 keeps both too: no respawn",
    Looper.prReadingChangesCutter(analysed[\candidates][0], analysed[\candidates][2]).not, "");
~tAssert.("6/8 -> slow 4/4 changes the pulse: respawn",
    Looper.prReadingChangesCutter(analysed[\candidates][0], analysed[\candidates][3]), "");
~tAssert.("no result to compare against: respawn, to be safe",
    Looper.prReadingChangesCutter(nil, analysed[\candidates][0]), "");

// ---- ticks: what Live counts ------------------------------------------------
~tEq.("a 6/8 bar is 72 ticks",  Looper.barTicksOf(analysed[\candidates][0]), 72);
~tEq.("a 12/8 bar is 144 ticks", Looper.barTicksOf(analysed[\candidates][1]), 144);
~tEq.("a 4/4 bar is 96 ticks",  Looper.barTicksOf(analysed[\candidates][3]), 96);
~tEq.("two bars of 6/8 are 144 ticks a loop", Looper.loopTicksOf(analysed[\candidates][0]), 144);

// ---- on which boundary does Live's bar line agree ---------------------------
// Two bars of 6/8 (144 ticks a loop) read as one bar of 12/8 (144-tick bar):
// every boundary agrees, so the very next one.
~tEq.("6/8 x2 -> 12/8: the next boundary", Looper.prReadingWait(144, 144, 144, 3), 1);
// One bar of 4/4 at 60 (96 ticks a loop) read as 12/8 (144-tick bar): Live's
// bar line meets the loop only every third loop.
~tEq.("4/4 -> 12/8 from the first boundary: the third", Looper.prReadingWait(96, 96, 144, 3), 3);
~tEq.("4/4 -> 12/8 with two loops already counted: the next", Looper.prReadingWait(288, 96, 144, 3), 1);
~tAssert.("4/4 -> 12/8 within two loops: not reachable", Looper.prReadingWait(96, 96, 144, 2).isNil, "got a wait");
// 7/8 in one bar (84 ticks a loop) read as 5/4 (120-tick bar): only every tenth
// loop, so out of reach — the caller re-sends Start instead.
~tAssert.("7/8 -> 5/4: out of reach", Looper.prReadingWait(84, 84, 120, 3).isNil, "got a wait");
~tEq.("with no clock reference every boundary is as good: the next",
    Looper.prReadingWait(nil, nil, 144, 3), 1);

// ---- the gesture ------------------------------------------------------------
// A playing looper carrying the take above, with a granular layer and a MIDI
// stub that records what goes to Live.
midi = ();
midi[\log]       = List.new;
midi[\start]     = { |self| self[\log].add(\start); self };
midi[\midiClock] = { |self| self };
midi[\latency]   = 0;

l = ~tLooper.();
~tPut.(l, \state, \playing);
~tPut.(l, \loopFrames, (3.0 * 48000).asInteger);
~tPut.(l, \loopStartTime, SystemClock.seconds);
~tPut.(l, \lastResult, analysed);
~tPut.(l, \analysedResult, analysed);
~tPut.(l, \midiOut, midi);
gran = ~tStubSynth.(l, \looperGranular);
~tPut.(l, \granularSynth, gran);
notified = List.new;
SimpleController(l).put(\reading, { |lp, what, val| notified.add(val) });

~tEq.("four readings to cycle through", l.readingCount, 4);
~tEq.("the runner-up is 12/8", [l.runnerUp[\numerator], l.runnerUp[\denominator]], [12, 8]);
~tNear.("the margin is the score gap", l.readingMargin, 0.05, 1e-9);

l.nextReading;
~tAssert.("a press arms the runner-up", l.pendingReading.notNil and: { l.pendingReading[\index] == 1 },
    "pending " ++ l.pendingReading);
~tAssert.("a routine will land it", ~tGet.(l, \readingRoutine).notNil, "no routine");
~tEq.("with no Start on record it lands on the next boundary", l.pendingReading[\loops], 1);
~tAssert.("and needs no Start", l.pendingReading[\restart] == false, "restart set");
~tEq.("the arming was published", notified.size, 1);
~tEq.("the reading in force has not moved yet", l.readingIndex, 0);

l.nextReading;
~tEq.("a second press moves on to the third reading", l.pendingReading[\index], 2);
l.nextReading;
~tEq.("a third press to the fourth", l.pendingReading[\index], 3);
l.nextReading;
~tEq.("past the last it comes round to the answer", l.pendingReading[\index], 0);
l.nextReading;
~tEq.("and on round again", l.pendingReading[\index], 1);

// Landing, driven synchronously: the boundary is put in the past, so the
// landing runs straight through with no yield, exactly as if the routine had
// woken on the boundary. It is driven THROUGH a routine because the landing
// stops the routine it is running inside (see prStopRoutine).
landed = nil;
l.onAnalysis = { |res| landed = res };
l.pendingReading[\at] = SystemClock.seconds - 0.01;
r = Routine { l.prLandReading(~tGet.(l, \readingSeq)) };
~tPut.(l, \readingRoutine, r);
r.next;
~tEq.("the take is now the runner-up", [l.lastResult[\numerator], l.lastResult[\denominator], l.lastResult[\k]], [12, 8, 1]);
~tEq.("readingIndex followed", l.readingIndex, 1);
~tAssert.("nothing pending after the landing", l.pendingReading.isNil, "still pending");
~tAssert.("the routine slot is clear", ~tGet.(l, \readingRoutine).isNil, "routine survived");
~tAssert.("Live was told, through the analysis callback", landed.notNil and: { landed[\numerator] == 12 }, "onAnalysis not called");
~tNear.("the grains took the pulse", ~tLastSet.(l, gran, \tau), 0.25, 1e-9);
~tAssert.("the landing was published as no longer pending", notified.last.isNil, "last notification " ++ notified.last);
~tEq.("no Start went out: the clock was not running", midi[\log].size, 0);

// The clock branch: a Start on record and a period to move. A reading that
// changes the tempo moves the period from the boundary and carries the tick
// reference to it; a reading no boundary in reach could align re-sends Start.
~tPut.(l, \midiClockRoutine, Routine { 1.wait });
~tPut.(l, \clockTicksAtRef, 0);
~tPut.(l, \clockRefTime, SystemClock.seconds - 3.0);
~tPut.(l, \clockTickRate, 48);     // 120 BPM: 48 ticks a second
~tPut.(l, \clockPeriod, 1 / 48);
l.nextReading;                     // -> reading 2, 3/4 at sub 2: 72-tick bar, 144 a loop
~tEq.("with the clock running the wait is worked out from Live's ticks",
    l.pendingReading[\loops], 1);
l.pendingReading[\at] = SystemClock.seconds - 0.01;
l.pendingReading[\restart] = true;   // as if no boundary in reach had aligned
r = Routine { l.prLandReading(~tGet.(l, \readingSeq)) };
~tPut.(l, \readingRoutine, r);
r.next;
~tEq.("the take is the third reading", [l.lastResult[\numerator], l.lastResult[\denominator]], [3, 4]);
~tNear.("the clock period follows the new tempo", ~tGet.(l, \clockPeriod), 60 / (120 * 24), 1e-12);
~tEq.("a reading that could not meet Live's bar line re-sent Start", midi[\log].asArray, [\start]);
~tNear.("and reset Live's count to this boundary", ~tGet.(l, \clockTicksAtRef), 0, 1e-9);

// Revert goes home the same way, on a boundary.
l.revertReading;
~tEq.("revert arms the analyser's own reading", l.pendingReading[\index], 0);

// Stopping cancels whatever is armed, and nothing is left running.
l.stopPlayback;
~tAssert.("stop cancels the pending reading", l.pendingReading.isNil, "still pending");
~tAssert.("stop leaves no reading routine", ~tGet.(l, \readingRoutine).isNil, "routine survived");
~tAssert.("stop published the cancel", notified.last.isNil, "last " ++ notified.last);

// Refusals: nothing playing, and a take that fit no grid.
notified = List.new;
l.nextReading;
~tAssert.("stopped: refused", l.pendingReading.isNil, "armed while stopped");
~tPut.(l, \state, \playing);
~tPut.(l, \analysedResult, (numerator: 7, denominator: 8, error: \lengthAnchored));
~tEq.("a fallback has nothing to offer", l.readingCount, 0);
l.nextReading;
~tAssert.("fallback: refused", l.pendingReading.isNil, "armed on a fallback");
~tAssert.("a refusal publishes nothing, so no button lights", notified.isEmpty, "notified " ++ notified);
~tAssert.("no runner-up to show either", l.runnerUp.isNil and: { l.readingMargin.isNil }, "");
}.value;

// Detect now (the overdub meter's button, on Setup and in Perform's band) that
// finds nothing says why in the footer, as a refusal; the run at an overdub's
// end, unasked, stays quiet. What it heard is the overdub's onsets, gathered
// only while the switch is on, so a press with the switch off says that too.
{
var l = ~tLooper.(), refused = List.new;
SimpleController(l).put(\refused, { |o, w, what, why| refused.add([what, why]) });
l.detectMeterFromOverdub(true);
~tEq.("Detect now with no loop: refused, and why", refused.asArray,
    [[\detectMeterFromOverdub, "no loop recorded"]]);
refused.clear;
l.detectMeterFromOverdub(false);
~tEq.("...the run at an overdub's end says nothing", refused.size, 0);
~tPut.(l, \loopFrames, 2 * 48000);
~tGet.(l, \overdubOnsets).addAll([[0.1, 1.0], [0.6, 0.5], [1.1, 1.0]]);
l.detectMeterFromOverdub(true);
~tEq.("Detect now on three onsets: refused, with the count and the switch that was off", refused.asArray,
    [[\detectMeterFromOverdub, "no beat in the last overdub: 3 onsets, 8 needed · Overdub meter is off"]]);
refused.clear;
~tPut.(l, \analyzeOverdubs, true);
l.detectMeterFromOverdub(true);
~tEq.("...with the switch on, the count alone", refused.asArray,
    [[\detectMeterFromOverdub, "no beat in the last overdub: 3 onsets, 8 needed"]]);
refused.clear;
l.detectMeterFromOverdub(false);
~tEq.("...and unasked, nothing", refused.size, 0);
~tEq.("no reading came of any of it", l.analysedResult, nil);
}.value;
