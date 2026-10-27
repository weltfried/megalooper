// Looper.beatCountAt: the count on Perform. Where the playhead is in its
// bar's beat groups (the analyser's: 7/8 is 2+2+3), the odd bar of uneven bars
// a bar ahead, the time to the next beat line, and the groups left before an
// event on a loop boundary (3, 2, 1 in 7/8).
//
// Pure arithmetic, as loopPositionAt's tests are; the count is built on it, so
// what the header says is not tested again here.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-beat-count");

{
// 7/8, two bars, an eighth 0.25 s: a bar 1.75 s, the loop 3.5 s. The same fit
// at sub 2 (a pulse 0.125 s) must count alike.
var r78 = (numerator: 7, denominator: 8, tau: 0.25, sub: 1, k: 2);
var r78s = (numerator: 7, denominator: 8, tau: 0.125, sub: 2, k: 2);
var dur78 = 3.5;
var e8 = 0.25;
var at = { |pos, r, dur, until, rev = false| Looper.beatCountAt(pos, r, dur, until, rev) };
var gg = { |pos, r, dur| var o = at.(pos, r, dur); [o[\group], o[\groupBeat]] };
var cd = { |pos, until, r, dur, rev = false| at.(pos, r ? r78, dur ? dur78, until, rev)[\countdown] };
var uneven = MeterAnalyzer.readingOfBars(29 * e8, [7, 7, 7, 8], 8);
var o;

// ---- the groups -----------------------------------------------------------------
o = at.(0, r78, dur78);
~tEq.("7/8: the bar's groups are the analyser's 2+2+3", o[\groups], [2, 2, 3]);
~tEq.("...and the header's keys are all there", [o[\bar], o[\beat], o[\beatsPerBar], o[\barCount]], [1, 1, 7, 2]);
~tEqArray.("beat 1 is group 1, its beat 1", gg.(0, r78, dur78), [1, 1]);
~tEqArray.("beat 2 is group 1, its beat 2", gg.(0.25, r78, dur78), [1, 2]);
~tEqArray.("beat 3 is group 2", gg.(0.5, r78, dur78), [2, 1]);
~tEqArray.("beat 5 is group 3", gg.(1.0, r78, dur78), [3, 1]);
~tEqArray.("beat 7 is group 3, its beat 3", gg.(1.5, r78, dur78), [3, 3]);
~tEqArray.("bar 2 starts over", gg.(1.76, r78, dur78), [1, 1]);
~tEqArray.("on a group's line exactly, the group it starts (the header's microbeat)",
    gg.((2 * 0.25), r78, dur78), [2, 1]);
~tEq.("sub 2 counts as sub 1", [0, 0.25, 0.5, 1.0, 1.5, 1.76].collect { |p| gg.(p, r78s, dur78) },
    [0, 0.25, 0.5, 1.0, 1.5, 1.76].collect { |p| gg.(p, r78, dur78) });
~tEqArray.("5/8 is 2+3: its beat 3 heads group 2",
    gg.(2 * e8, (numerator: 5, denominator: 8, tau: e8, sub: 1, k: 1), 5 * e8), [2, 1]);
~tEq.("12/8 is four threes", at.(0, (numerator: 12, denominator: 8, tau: e8, sub: 1, k: 1), 12 * e8)[\groups],
    [3, 3, 3, 3]);
~tEqArray.("...its beat 7 heads group 3",
    gg.(6 * e8, (numerator: 12, denominator: 8, tau: e8, sub: 1, k: 1), 12 * e8), [3, 1]);
o = at.(1.0, (numerator: 4, denominator: 4, tau: 0.5, sub: 1, k: 2), 4.0);
~tEq.("4/4: four groups of one, so the group is the beat",
    [o[\groups], o[\beat], o[\group], o[\groupBeat]], [[1, 1, 1, 1], 3, 3, 1]);

// ---- the odd bar, a bar ahead ---------------------------------------------------------
o = at.(0, uneven, 29 * e8);
~tEq.("7 7 7 8, bar 1: a bar of seven, seven next, nothing odd",
    [o[\beatsPerBar], o[\nextBeatsPerBar], o[\barOdd], o[\nextOdd]], [7, 7, false, false]);
o = at.((14 * e8) + 0.01, uneven, 29 * e8);
~tEq.("bar 3: the odd bar is next, all through it",
    [o[\bar], o[\nextBeatsPerBar], o[\barOdd], o[\nextOdd]], [3, 8, false, true]);
~tEq.("...to its last beat", at.((20 * e8) + 0.01, uneven, 29 * e8)[\nextOdd], true);
o = at.((21 * e8) + 0.01, uneven, 29 * e8);
~tEq.("bar 4 is the odd one, of 2+2+2+2, and bar 1 follows",
    [o[\bar], o[\groups], o[\barOdd], o[\nextOdd], o[\nextBeatsPerBar]], [4, [2, 2, 2, 2], true, false, 7]);
~tEqArray.("...its beat 7 heads group 4", gg.((27 * e8) + 0.01, uneven, 29 * e8), [4, 1]);
~tEq.("backwards, bar 1 comes to bar 4: the odd bar next",
    at.(0.1, uneven, 29 * e8, nil, true)[\nextOdd], true);
~tEq.("even bars are never odd", (0, 0.25 .. 3.25).collect { |p| at.(p, r78, dur78)[\nextOdd] or: { at.(p, r78, dur78)[\barOdd] } }
    .includes(true), false);

// ---- the next beat line ------------------------------------------------------------------
~tNear.("forwards, the line ahead", at.(0.1, r78, dur78)[\toEdge], 0.15, 1e-9);
~tNear.("...on a line, the next one, a beat on", at.(0.25, r78, dur78)[\toEdge], 0.25, 1e-9);
~tNear.("backwards, the line below", at.(0.1, r78, dur78, nil, true)[\toEdge], 0.1, 1e-9);
~tNear.("...on a line, the one a beat below", at.(0.25, r78, dur78, nil, true)[\toEdge], 0.25, 1e-9);
~tNear.("sub 2: still a beat, not a pulse", at.(0.1, r78s, dur78)[\toEdge], 0.15, 1e-9);

// ---- the count to an event at the loop's end ----------------------------------------------
~tEq.("no event, no count", cd.(3.0, nil), nil);
~tEq.("bar 1: not the last bar yet", cd.(1.7, 1.8), nil);
~tEq.("bar 2, group 1: three groups left", cd.(1.75, 1.75), 3);
~tEq.("...its beat 2: still three", cd.(2.0, 1.5), 3);
~tEq.("group 2: two", cd.(2.25, 1.25), 2);
~tEq.("group 3: one", cd.(2.75, 0.75), 1);
~tEq.("...to the end of the bar", cd.(3.4, 0.1), 1);
~tEq.("sub 2 counts the same", [[1.75, 1.75], [2.25, 1.25], [2.75, 0.75]].collect { |pu| cd.(pu[0], pu[1], r78s) },
    [3, 2, 1]);
~tEq.("an event a loop further on: no count in this pass", cd.(2.75, 0.75 + dur78), nil);
~tEq.("...but the loops to it", at.(2.75, r78, dur78, 0.75 + dur78)[\loopsLeft], 2);
~tEq.("...and one loop", at.(2.75, r78, dur78, 0.75)[\loopsLeft], 1);
~tEq.("a whole pass away is one loop", at.(0, r78, dur78, dur78)[\loopsLeft], 1);
~tEq.("a past event counts nothing", cd.(2.75, -0.1), nil);
~tEq.("a one-bar loop: its only bar is the last, from its first beat",
    cd.(0, 1.75, (numerator: 7, denominator: 8, tau: e8, sub: 1, k: 1), 1.75), 3);
~tEq.("...but not a pass early", cd.(0, 3.5, (numerator: 7, denominator: 8, tau: e8, sub: 1, k: 1), 1.75), nil);
~tEq.("4/4: four, three, two, one",
    [0, 0.5, 1.0, 1.5].collect { |p| cd.(2 + p, 2 - p, (numerator: 4, denominator: 4, tau: 0.5, sub: 1, k: 2), 4.0) },
    [4, 3, 2, 1]);
~tEq.("7 7 7 8: the last bar is the odd one, four groups",
    [21, 23, 25, 27].collect { |b| cd.((b * e8) + 0.01, ((29 - b) * e8) - 0.01, uneven, 29 * e8) }, [4, 3, 2, 1]);
~tEq.("...and its third bar counts nothing", cd.((20 * e8) + 0.01, (9 * e8) - 0.01, uneven, 29 * e8), nil);

// ---- backwards, to the loop's start -------------------------------------------------------------
~tEq.("backwards from bar 2: nothing yet", cd.(1.8, 1.8, nil, nil, true), nil);
~tEq.("bar 1 from its top, group 3: three", cd.(1.6, 1.6, nil, nil, true), 3);
~tEq.("...group 2: two", cd.(0.9, 0.9, nil, nil, true), 2);
~tEq.("...group 1: one", cd.(0.3, 0.3, nil, nil, true), 1);
~tEq.("...on group 3's line, three, as the header still shows it",
    cd.(1.0, 1.0, nil, nil, true), 3);
~tEq.("7 7 7 8 backwards ends on bar 1: three", cd.(1.6, 1.6, uneven, 29 * e8, true), 3);

// ---- the count and the group agree, on every beat line ---------------------------------
// At a tempo whose eighth is no round number, a line computed as k eighths
// lands a rounding error either side of k. The group shown and the count must
// still change together: forwards the count is the groups left from the one
// shown, backwards the one shown, and only in the last bar. A downbeat moved
// to 0.35 s puts seven of the lines below their beat (the event is then the
// next downbeat, not the loop's start).
{
    var tau = 60 / 103.2 / 2;
    [[(numerator: 7, denominator: 8, tau: tau, sub: 1, k: 2), 14, 0],
        [MeterAnalyzer.readingOfBars(29 * tau, [7, 7, 7, 8], 8), 29, 0],
        [(numerator: 7, denominator: 8, tau: tau, sub: 1, k: 2, downbeatPhase: 0.35), 14, 0.35]].do { |rn|
        var r = rn[0], n = rn[1], dbp = rn[2], len = n * tau, bad = List.new;
        (0 .. (2 * n) - 1).do { |h|
            var p = dbp + (h * tau / 2);
            var f = at.(p.wrap(0, len), r, len, (len + dbp) - p), b = at.(p.wrap(0, len), r, len, p - dbp, true);
            if(f[\countdown] != (if(f[\bar] == f[\barCount]) { (f[\groups].size - f[\group]) + 1 })) {
                bad.add([\forward, h / 2, f[\bar], f[\group], f[\countdown]]) };
            if((h > 0) and: { b[\countdown] != (if(b[\bar] == 1) { b[\group] }) }) {
                bad.add([\backward, h / 2, b[\bar], b[\group], b[\countdown]]) };
        };
        ~tEq.(MeterAnalyzer.sigString(r) ++ " at 103.2, downbeat at " ++ dbp
            ++ " s: the count is the group shown, on every line and between", bad.asArray, []);
    };
}.value;

// ---- a downbeat moved off the loop's start ---------------------------------------------------------
// A meter read from an overdub counts from downbeatPhase; the loop's boundary
// is then mid-bar, and the count runs to it all the same.
o = (numerator: 7, denominator: 8, tau: 0.25, sub: 1, k: 2, downbeatPhase: 0.5);
~tEqArray.("the bar starts at the downbeat", gg.(0.5, o, dur78), [1, 1]);
~tEq.("the boundary is bar 2 beat 6: three groups left from bar 2's start",
    cd.(2.25, 1.25, o, dur78), 3);
~tEq.("...one in its group 3", cd.(3.25, 0.25, o, dur78), 1);

// ---- no grid ---------------------------------------------------------------------------------------
o = at.(1.0, nil, dur78, 0.5);
~tEq.("no reading: no group, no count, the fraction still",
    [o[\group], o[\groups], o[\countdown], o[\toEdge], o[\fraction].round(1e-6)], [nil, nil, nil, nil, (1 / 3.5).round(1e-6)]);
o = at.(1.0, (error: \lengthAnchored, numerator: 7, denominator: 8, tau: 0.5, sub: 1, k: 1), 3.5, 0.5);
~tEq.("a length-anchored reading: no count", [o[\group], o[\countdown]], [nil, nil]);
~tEq.("a nil phase: no count", at.(nil, r78, dur78, 0.5)[\countdown], nil);
~tEq.("no loop: no count", at.(1.0, r78, 0, 0.5)[\countdown], nil);
}.value;

// ---- what the count counts to, and on --------------------------------------------------------
// On the server-free fixture: Looper.upcoming lists the events with a time
// ahead; countResult keeps the reading the loop still plays by while a landing
// has swapped lastResult early.
{
    var l = ~tLooper.(), ev, r;
    var rOld = (numerator: 7, denominator: 8, tau: 0.25, sub: 1, k: 2, loopDur: 3.5, bpm: 120,
        n: 14, phase: 0, score: 0.9);
    var rNew = (numerator: 14, denominator: 8, tau: 0.25, sub: 1, k: 1, loopDur: 3.5, bpm: 120,
        n: 14, phase: 0, score: 0.8);
    var whatAt = { |now| l.upcoming(now).collect { |e| [e[\what], e[\at]] } };
    ~tPut.(l, \state, \playing);
    ~tPut.(l, \loopFrames, (3.5 * 48000).asInteger);
    ~tPut.(l, \loopStartTime, 100.0);
    ~tEq.("a loop playing: nothing coming", whatAt.(101.0), []);
    ~tPut.(l, \nextRecState, \armed);
    ~tEq.("the next loop armed: it records from the next boundary", whatAt.(101.0), [[\recordNextLoop, 103.5]]);
    ~tEq.("...a pass later, the boundary after", whatAt.(104.0), [[\recordNextLoop, 107.0]]);
    ~tPut.(l, \nextRecState, \stopping);
    ~tEq.("asked to stop: it ends on the next", whatAt.(101.0), [[\recordNextLoopEnds, 103.5]]);
    ~tPut.(l, \nextRecState, \recording);
    ~tEq.("recording on: no time ahead", whatAt.(101.0), []);
    ~tPut.(l, \nextRecState, \idle);
    ~tPut.(l, \bbcutEnabling, true);
    ~tEq.("the cutter coming in: on the next boundary", whatAt.(101.0), [[\cutter, 103.5]]);
    ~tPut.(l, \bbcut, true);
    ~tEq.("...but not a cutter already in, respawning for a reading", whatAt.(101.0), []);
    ~tPut.(l, \bbcut, false);
    ~tPut.(l, \bbcutEnabling, false);
    ~tPut.(l, \breakEndsAt, 102.0);
    ~tPut.(l, \pendingReading, (index: 1, result: rNew, at: 107.0, loops: 2, restart: false));
    ~tEq.("a break's end and a reading's landing, at their own times",
        whatAt.(101.0), [[\break, 102.0], [\reading, 107.0]]);
    ~tPut.(l, \breakEndsAt, nil);
    ~tPut.(l, \pendingReading, nil);
    ~tPut.(l, \loopFrames, 0);
    ~tPut.(l, \nextRecState, \armed);
    ~tEq.("no loop: no boundary to count to", whatAt.(101.0), []);
    ~tPut.(l, \nextRecState, \idle);
    ~tPut.(l, \loopFrames, (3.5 * 48000).asInteger);

    // A landing, driven through a routine as test-reading.scd does: it swaps
    // lastResult, then waits for the boundary ten seconds off.
    ~tPut.(l, \lastResult, rOld);
    ~tPut.(l, \analysedResult, rOld.copy.put(\candidates, [rOld, rNew]));
    ~tPut.(l, \granularSynth, ~tStubSynth.(l, \looperGranular));
    ~tAssert.("nothing landing: countResult is lastResult", l.countResult === rOld, "");
    ~tPut.(l, \pendingReading, (index: 1, result: rNew, at: SystemClock.seconds + 10, loops: 1, restart: false));
    r = Routine { l.prLandReading(~tGet.(l, \readingSeq)) };
    ~tPut.(l, \readingRoutine, r);
    r.next;
    ~tAssert.("landing: lastResult has swapped before the boundary", l.lastResult === rNew, "");
    ~tAssert.("...and the count stays on the reading before it", l.countResult === rOld, "");
    l.pendingReading[\at] = SystemClock.seconds - 0.01;
    r.next;
    ~tAssert.("landed: nothing pending", l.pendingReading.isNil, "still pending");
    ~tAssert.("...and the count on the new reading", l.countResult === rNew, "");
    ~tPut.(l, \pendingReading, (index: 0, result: rOld, at: SystemClock.seconds + 10, loops: 1, restart: false));
    ~tAssert.("armed, not landing: the reading in force", l.countResult === rNew, "");
}.value;

// ---- what Perform's count shows (gui-status.scd) ---------------------------------------------
// ~countCompute on the fixture, the poll's answer put in by hand: the count
// predicted from it, the event counted to, the word once it lands (and none
// for one cancelled), and why there is nothing to count.
{
    var scripts = Looper.repoRoot +/+ "scripts";
    var l = ~tLooper.(), was = ~looper, wasDelay = ~countDelay, s;
    var r78 = (numerator: 7, denominator: 8, tau: 0.25, sub: 1, k: 2, loopDur: 3.5, bpm: 120, n: 14, phase: 0);
    var at = { |now| ~countCompute.(now) };
    var gb = { |s| s[\c] !? { |c| [c[\bar], c[\group], c[\groupBeat]] } };
    if(~countCompute.isNil) { (scripts +/+ "gui-status.scd").load };
    ~looper = l;
    ~countDelay = 0;
    ~countPrevNear = nil;
    ~countFlash = nil;
    ~countAnchor = nil;
    ~tEq.("an empty looper: nothing to count", [at.(100)[\c], at.(100)[\why]], [nil, "no loop"]);
    ~tPut.(l, \state, \recording);
    ~tEq.("a take recording: it starts when the loop closes", at.(100)[\why], "starts when\nthe loop closes");
    ~tPut.(l, \loopFrames, (3.5 * 48000).asInteger);
    ~tPut.(l, \state, \stopped);
    ~tEq.("a stopped loop", at.(100)[\why], "stopped");
    ~tPut.(l, \state, \playing);
    ~tPut.(l, \lastResult, r78);
    ~tEq.("playing, before the poll's first answer: nothing yet", [at.(100)[\c], at.(100)[\why]], [nil, ""]);
    ~countAnchor = (phase: 0.5, at: 100.0, dur: 3.5);
    s = at.(100.3);
    ~tEq.("0.3 s after an answer at 0.5 s: beat 4, group 2, its beat 2", gb.(s), [1, 2, 2]);
    ~tNear.("...the routine sleeps a tenth at most", s[\wait], 0.1, 1e-9);
    ~tNear.("...and near a beat line, to it", at.(100.45)[\wait], 0.052, 1e-6);
    ~countDelay = 0.1;
    ~tEq.("a delay shows the beat 0.1 s back: beat 3, group 2's first", gb.(at.(100.3)), [1, 2, 1]);
    ~countDelay = 0;
    ~tPut.(l, \reverseFlag, true);
    ~tEq.("backwards, 0.3 s before: beat 1", gb.(at.(100.3)), [1, 1, 1]);
    ~tPut.(l, \reverseFlag, false);
    ~countAnchor = (phase: 0.5, at: 100.0, dur: 7.0);
    ~tEq.("an answer about a loop of another length: nothing until the next", at.(100.3)[\c], nil);
    ~countAnchor = (phase: 0.5, at: 100.0, dur: 3.5);
    ~tPut.(l, \lastResult, nil);
    ~tEq.("a take with no reading", [at.(100.3)[\c], at.(100.3)[\why]], [nil, "no grid\non this take"]);
    ~tPut.(l, \lastResult, r78);

    // The next loop armed: its boundary from loopStartTime, 103.0 here.
    ~tPut.(l, \loopStartTime, 99.5);
    ~tPut.(l, \nextRecState, \armed);
    s = at.(100.3);
    ~tEq.("armed, bar 1: the event, a loop to go, no count yet",
        [s[\near][\what], s[\c][\countdown], s[\c][\loopsLeft]], [\recordNextLoop, nil, 1]);
    s = at.(102.0);
    ~tEq.("bar 2, group 2: two to go", [gb.(s), s[\c][\countdown]], [[2, 2, 2], 2]);
    ~tEq.("...the last group: one", at.(102.6)[\c][\countdown], 1);
    ~tPut.(l, \nextRecState, \recording);
    s = at.(103.05);
    ~tEq.("past the boundary, recording: its word, for the first group", [s[\flash] !? { |f| f[\what] }, gb.(s)],
        [\recordNextLoop, [1, 1, 1]]);
    ~tNear.("...to the group's end", s[\flash][\until], 103.5, 1e-9);
    ~tEq.("...still there within it", at.(103.4)[\flash] !? { |f| f[\what] }, \recordNextLoop);
    ~tEq.("...and gone at the next group", at.(103.5)[\flash], nil);
    ~tPut.(l, \nextRecState, \armed);
    at.(105.0);
    ~tPut.(l, \nextRecState, \idle);
    ~tEq.("armed, then cancelled before its boundary: no word", at.(105.1)[\flash], nil);
    ~tPut.(l, \state, \stopped);
    ~countFlash = (what: \break, until: 200);
    ~tEq.("a word left over when the loop stops goes with it", at.(105.2)[\flash], nil);

    ~looper = was;
    ~countDelay = wasDelay;
    ~countAnchor = nil;
    ~countPrevNear = nil;
    ~countFlash = nil;
}.value;
