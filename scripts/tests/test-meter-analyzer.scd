// MeterAnalyzer against synthetic onset grids. No audio, no server.
//
// Ported from the older scripts/test_meter_analyzer.scd, which printed
// PASS/FAIL but had no exit code — so run headless it idled forever and, with
// stdout block-buffered, printed nothing at all. Two of its cases were failing
// unnoticed as a result; both are now stated explicitly below.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-meter-analyzer");

{
// MeterAnalyzer's fallback meter is CLASS state, so it has to be saved and put
// back or the length-anchored cases below would leak into every later file.
var origNum   = MeterAnalyzer.fallbackNum;
var origDenom = MeterAnalyzer.fallbackDenom;
var origBars  = MeterAnalyzer.fallbackBars;

// bpmTol defaults to 1.0. Jitter genuinely costs about a BPM, so that one case
// passes its own wider tolerance rather than having the global one loosened for
// everybody — a tolerance is a claim about the algorithm, and it should stay
// tight everywhere it can be.
var meter = { |label, loopDur, onsets, wantNum, wantDenom, wantBpm, bpmTol = 1.0|
    var r = MeterAnalyzer.analyze(loopDur, onsets);
    var got = "" ++ r.numerator ++ "/" ++ r.denominator ++ " @ "
        ++ r.bpm.round(0.1) ++ " bpm";
    ~tAssert.(label ++ " -> " ++ wantNum ++ "/" ++ wantDenom,
        (r.numerator == wantNum) and: { r.denominator == wantDenom }, got);
    ~tAssert.(label ++ " -> " ++ wantBpm ++ " bpm",
        r.bpm.notNil and: { (r.bpm - wantBpm).abs < bpmTol }, got);
    r
};

// A take that fits no pulse grid must NOT fall back to a blind 4/4. It anchors
// to the loop LENGTH as whole bars of whatever meter the user set, and the loop
// stays exactly N bars long (tau * n == loopDur).
var anchored = { |label, loopDur, onsets, num, denom|
    var r;
    MeterAnalyzer.fallbackNum = num;
    MeterAnalyzer.fallbackDenom = denom;
    MeterAnalyzer.fallbackBars = 0;
    r = MeterAnalyzer.analyze(loopDur, onsets.asArray, onsets.collect { 1.0 });
    ~tEq.(label ++ ": reports lengthAnchored", r.error, \lengthAnchored);
    ~tEq.(label ++ ": uses the user's meter",
        "" ++ r.numerator ++ "/" ++ r.denominator, "" ++ num ++ "/" ++ denom);
    ~tNear.(label ++ ": stays a whole number of bars", r.tau * r.n, loopDur, 1e-9);
    r
};

// ---- clean grids ---------------------------------------------------------

meter.("4/4 at 120", 2.0, [0, 0.5, 1.0, 1.5], 4, 4, 120);

// The headline case this instrument exists for.
meter.("7/8 at 100", 2.1, [0, 0.3, 0.6, 0.9, 1.2, 1.5, 1.8], 7, 8, 100);

meter.("5/4 at 90", 5 * (60/90), (0..4).collect { |i| i * (60/90) }, 5, 4, 90);

// v1 reports quarter-note BPM; compound feel is left to the player to read.
meter.("6/8 (quarter-equivalent bpm)", 1.5, (0..5).collect { |i| i * 0.25 },
    6, 8, 120);

// ---- sparse and off-beat inputs -----------------------------------------

// Three onsets are enough if they fit the 7-eighth grid.
meter.("7/8 sparse", 2.1, [0, 0.6, 1.5], 7, 8, 100);

// Nothing on beat 1 — the grid is fitted by phase, not by assuming an onset
// sits at zero.
meter.("7/8 with no downbeat onset", 2.1, [0.6, 0.9, 1.2, 1.5, 1.8], 7, 8, 100);

// +/-20 ms of human timing. The meter must survive it; the tempo estimate
// legitimately drifts about a BPM, so this case carries its own tolerance.
meter.("4/4 with +/-20ms jitter", 2.0, [0.01, 0.49, 1.02, 1.51], 4, 4, 120, 1.5);

// ---- the known octave error ---------------------------------------------

// Two bars of 4/4 at 87, sixteen eighths. The meter comes out right and it
// correctly refuses to call this 16/8 or 8/4 — but the tempo lands on the
// EIGHTH pulse, reporting exactly double. Recorded rather than hidden: onset
// quality is the known weak link in meter detection, and this is what a dense
// even subdivision currently does. If it ever stops reproducing the run says so.
{
var r = MeterAnalyzer.analyze(5.5172, (0..15).collect { |i| i * (5.5172/16) });
~tEq.("dense 4/4 over 2 bars still reads 4/4",
    "" ++ r.numerator ++ "/" ++ r.denominator, "4/4");
~tXfail.("dense 4/4 over 2 bars reports double tempo",
    (r.bpm - 174.0).abs < 1.0,
    "got " ++ r.bpm.round(0.1) ++ ", musically 87 — beat found on the eighth");
}.value;

// ---- the caller's stack must come back intact ----------------------------

// A clean two-bar 3/4 waltz at 185 BPM: six onsets on an exact grid, nothing
// odd about it musically. Until 2026-09-25, analyze() on exactly this input
// wrote its winning score one slot BELOW its own frame — into whatever the
// caller had on the operand stack. In a `~x = analyze(…)` that slot is the key
// `\x`, and the assignment dies with "envirPut not understood" on a Float; in
// the looper it belongs to whoever called the deferred analysis closure. The
// cause was `var` declarations inside the nested inlined `if` blocks of the
// candidate loop (see the comment in MeterAnalyzer:analyze); hoisting them was
// the fix. Found by scripts/probe-meter.scd, bisected in scratch copies of the
// loop.
//
// The detector puts a known number under the call and reads it back. A
// clobbered slot turns 1006 into the score plus the onset count (about 6.81),
// which is unmistakable — and it cannot throw, unlike a `~x =` canary would.
{
var loopDur   = 1.9459459459459;
var onsets    = [0.0, 0.324324324324, 0.648648648649, 0.972972972973, 1.297297297297, 1.621621621622];
var strengths = [1.0, 0.5, 0.5, 1.0, 0.5, 0.5];
var got = 1000 + MeterAnalyzer.analyze(loopDur, onsets, strengths)[\onsetCount];
~tEq.("analyze leaves the caller's operand stack intact (3/4 at 185, 2 bars)", got, 1006);
}.value;

// ---- ranked readings ----------------------------------------------------

// analyze() keeps every reading that passed the fit, best first, so a
// correction can offer "the next reading" (roadmap item 9). The list must agree
// with the answer, be sorted, be capped, snap like the answer does — and be
// absent where nothing fit, because a fallback has no next reading to offer.
{
var r = MeterAnalyzer.analyze(2.1, [0, 0.3, 0.6, 0.9, 1.2, 1.5, 1.8],
    [1, 0.3, 0.7, 0.3, 0.7, 0.3, 0.3]);
var c = r[\candidates];
~tAssert.("candidates are returned", c.notNil and: { c.notEmpty }, "got " ++ c);
~tEq.("the first candidate is the answer",
    [c[0][\numerator], c[0][\denominator], c[0][\k], c[0][\sub]],
    [r[\numerator], r[\denominator], r[\k], r[\sub]]);
~tNear.("the answer carries its score", r[\score], c[0][\score], 1e-12);
~tAssert.("candidates are sorted best first",
    c.every { |e, i| (i == 0) or: { c[i - 1][\score] >= e[\score] } },
    "scores " ++ c.collect { |e| e[\score].round(0.001) });
~tAssert.("no more than maxCandidates", c.size <= MeterAnalyzer.maxCandidates,
    "got " ++ c.size);
~tAssert.("every candidate snaps like the answer",
    c.every { |e|
        var s = Looper.snapAnalysisToLoop(e.copy, 2.1);
        s[\k].notNil and: { s[\loopDur].notNil }
    }, "snap failed");
~tAssert.("the snap left the candidate itself alone",
    c[0][\loopDur].notNil and: { c[0][\k] == r[\k] }, "candidate was mutated");
}.value;
{
var r = MeterAnalyzer.analyze(2.99,
    [0.0, 0.35, 0.61, 0.99, 1.4, 1.72, 2.05, 2.31, 2.66, 2.8]);
~tEq.("a take that fits no grid is length-anchored", r[\error], \lengthAnchored);
~tAssert.("and offers no next reading", r[\candidates].isNil, "got " ++ r[\candidates]);
}.value;

// ---- length-anchored fallback -------------------------------------------

// The SAME irregular onsets anchor to whichever meter the user has set, which
// is the whole point: an unfittable take becomes N bars of the player's meter
// rather than a guess.
anchored.("irregular -> 7/8", 2.99,
    [0.0, 0.35, 0.61, 0.99, 1.4, 1.72, 2.05, 2.31, 2.66, 2.8], 7, 8);
anchored.("irregular -> 5/8, same onsets", 2.99,
    [0.0, 0.35, 0.61, 0.99, 1.4, 1.72, 2.05, 2.31, 2.66, 2.8], 5, 8);
anchored.("irregular -> 4/4", 2.3,
    [0.0, 0.31, 0.55, 0.79, 1.1, 1.45, 1.7, 2.0, 2.1, 2.25], 4, 4);

MeterAnalyzer.fallbackNum   = origNum;
MeterAnalyzer.fallbackDenom = origDenom;
MeterAnalyzer.fallbackBars  = origBars;
~tEq.("class state restored: fallbackNum", MeterAnalyzer.fallbackNum, origNum);
}.value;
