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

// Two bars of 4/4 at 87, sixteen eighths, no accents. Until bpmRangeHi came
// down to 160 (2026-10-28) the tempo landed on the EIGHTH pulse: 4/4 at 174.
// That reading is out of range now, and the next near-tie takes its place:
// 12/8 at 130.5, the same bar and the same beat (a dotted quarter at 87) with
// the hits as duplets. It wins on the near-110 preference alone, which counts
// quarters, by 0.013; 4/4 at 87 is next on the list, one press away. Recorded
// rather than hidden: if it ever stops reproducing the run says so.
{
var r = MeterAnalyzer.analyze(5.5172, (0..15).collect { |i| i * (5.5172/16) });
var next = r[\candidates] !? { |c| c[1] };
~tAssert.("dense 4/4 over 2 bars no longer reports double tempo",
    (r.bpm - 174.0).abs >= 1.0, "got " ++ r.bpm.round(0.1));
~tEq.("...4/4 in two bars is the next reading",
    next !? { |c| [MeterAnalyzer.sigString(c), c[\k]] }, ["4/4", 2]);
~tNear.("...at 87", next !? { |c| c[\bpm] } ? 0, 87.0, 0.1);
~tXfail.("dense 4/4 over 2 bars reads 12/8 at the same beat",
    MeterAnalyzer.sigString(r) == "12/8",
    "got " ++ MeterAnalyzer.sigString(r) ++ " at " ++ r.bpm.round(0.1) ++ ", musically 4/4 at 87");
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
        var s = MeterDecision.snapAnalysisToLoop(e.copy, 2.1);
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

// ---- the snap moves a take by half an eighth at most ------------------------
// MeterAnalyzer.snapLimit. Rounding to whole bars of a reading is there for
// the stop press; an eighth further is a bar that was played longer, which the
// rounding would cut off (a sparse 7+7+7+7+8 read as 5/4 lost 448 ms).
{
var e8 = 60 / 108 / 2;
var limitAt = { |bpm| (MeterAnalyzer.snapLimit * 30 / bpm).min(MeterAnalyzer.snapLimitSecs) };
var cand = { |num, denom, sub, tau, score|
    (score: score, numerator: num, denominator: denom, k: 1, sub: sub, tau: tau,
        loopDur: tau * num * sub, bpm: 240 / (denom * tau * sub), n: num * sub,
        phase: 0, downbeatOffset: 0, accent: 0, onsetCount: 9)
};
var withList = { |list| list[0].copy.put(\candidates, list) };
var fiveFour = cand.(5, 4, 1, 0.6369, 0.9);
var twelveEight = cand.(12, 8, 1, e8, 0.8);
var sevenEight = cand.(7, 8, 1, e8, 0.9);
var s, takes;

// The answer would cut 446 ms off ten seconds: the runner-up keeps them.
s = MeterDecision.snapAnalysisToLoop(withList.([fiveFour, twelveEight]), 10.0);
~tEq.("an answer that would move the take gives way to one that does not",
    [s[\numerator], s[\denominator], s[\k], s[\error]], [12, 8, 3, nil]);
~tNear.("...which keeps the take's length", s[\loopDur], 10.0, 1e-3);
~tEq.("...and says what gave way", [s[\snapRefused][\numerator], s[\snapRefused][\denominator],
    s[\snapRefused][\k]], [5, 4, 3]);
~tNear.("...and by how much", s[\snapRefused][\moveMs], -446, 1);
~tEq.("the reading that would move it is no longer offered",
    s[\candidates].collect { |c| c[\numerator] }, [12]);

s = MeterDecision.snapAnalysisToLoop(withList.([fiveFour]), 10.0);
~tEq.("with nothing that fits, the take is length-anchored", s[\error], \lengthAnchored);
~tNear.("...at its own length", s[\loopDur], 10.0, 1e-9);
~tAssert.("...and still says what gave way", s[\snapRefused].notNil, "no snapRefused");

// The stop press 60 ms late on four bars of 7/8: corrected, as before.
s = MeterDecision.snapAnalysisToLoop(withList.([sevenEight]), (28 * e8) + 0.06);
~tEq.("a stop press 60 ms late is still corrected", [s[\numerator], s[\k], s[\snapRefused]], [7, 4, nil]);
~tNear.("...to four whole bars", s[\loopDur], 28 * e8, 1e-9);
// 120 ms is past the cap, at any tempo: the take keeps it, as it would a
// played eighth. The cost of the guard, on a hand that late.
s = MeterDecision.snapAnalysisToLoop(withList.([sevenEight]), (28 * e8) + 0.12);
~tEq.("a stop press 120 ms late is kept", s[\error], \lengthAnchored);
~tNear.("...in the loop's length", s[\loopDur], (28 * e8) + 0.12, 1e-9);
// An eighth longer is 7+7+7+8, not a late press.
s = MeterDecision.snapAnalysisToLoop(withList.([sevenEight]), 29 * e8);
~tEq.("an eighth longer keeps the eighth", s[\error], \lengthAnchored);
~tNear.("...the loop is 29 eighths", s[\loopDur], 29 * e8, 1e-9);
// readingFor's guard = false: the plain rounding, for readings already vetted.
s = MeterDecision.snapAnalysisToLoop(sevenEight.copy, 29 * e8, false);
~tEq.("unguarded, the snap rounds as it always did", [s[\k], s[\snapRefused]], [4, nil]);

// The property over the analyser itself: shapes with a longer or shorter bar,
// every eighth played or only the group heads. Whatever the reading, the loop
// moves by half an eighth at most, or it is length-anchored at its own length,
// and every reading still offered fits too.
takes = [[7, 7, 7, 7], [7, 7, 7, 8], [7, 7, 7, 9], [7, 7, 7, 6], [7, 7, 7, 7, 8],
    [5, 5, 5, 6], [7, 7, 7, 8, 7, 7, 7, 9]];
takes.do { |bars|
    [true, false].do { |dense|
        var onsets = List.new, strengths = List.new, pos = 0, full, r, moved, offered, kept;
        bars.do { |len|
            var groups = switch(len, 5, { [2, 3] }, 6, { [2, 2, 2] }, 7, { [2, 2, 3] },
                8, { [2, 2, 2, 2] }, 9, { [2, 2, 2, 3] });
            var p = pos;
            groups.do { |g, gi|
                g.do { |u|
                    if((u == 0) or: { dense }) {
                        onsets.add((p + u) * e8);
                        strengths.add(if(u == 0) { if(gi == 0) { 1.0 } { 0.7 } } { 0.35 });
                    };
                };
                p = p + g;
            };
            pos = pos + len;
        };
        full = pos * e8;
        r = MeterDecision.snapAnalysisToLoop(
            MeterAnalyzer.analyze(full, onsets.asArray, strengths.asArray), full);
        moved = (r[\loopDur] - full).abs;
        offered = (r[\candidates] ? []).every { |c| MeterDecision.snapFits(c, full) };
        kept = if(r[\error] == \lengthAnchored) { moved < 1e-9 } { moved <= limitAt.(r[\bpm]) };
        ~tAssert.(bars.join("+") ++ (if(dense) { " dense" } { " sparse" })
            ++ ": the loop keeps its length to half an eighth",
            kept and: { offered },
            MeterDecision.readingString(r) ++ " moved " ++ (moved * 1000).round(1) ++ " ms");
    };
};
}.value;

// ---- the whole loop's fit (MeterAnalyzer.wholeLoop, 2026-11-06) -------------
// A first take's grids fitted a second way, over the whole loop from the
// press with their phase free: the rescue where the fit from the first onset
// finds nothing, after its readings on the ranked list. As the duo's rig, the
// fallback is 7/8.
{
var origNum = MeterAnalyzer.fallbackNum, origDenom = MeterAnalyzer.fallbackDenom;
var origBars = MeterAnalyzer.fallbackBars, origWhole = MeterAnalyzer.wholeLoop;
var take = { |full, hits, strengths, whole = true|
    var r;
    MeterAnalyzer.wholeLoop = whole;
    r = MeterDecision.snapAnalysisToLoop(MeterAnalyzer.analyze(full - hits[0], hits - hits[0], strengths,
        leadIn: hits[0]), full);
    MeterAnalyzer.wholeLoop = origWhole;
    r
};
var beat = 60 / 107, full, hits, st, r, a, b, f, s;
MeterAnalyzer.fallbackNum = 7;
MeterAnalyzer.fallbackDenom = 8;
MeterAnalyzer.fallbackBars = 0;

// The training take gerade-5's shape: four even quarters at 107, the first
// half a beat after the press. From the first onset the span is 3.5 beats,
// whose only grid (7/8 on eighths) would move the loop by a beat; the snap
// refuses it, and before the whole loop's readings were on the list the take
// was length-anchored as 7/8.
full = 4 * beat;
hits = (0..3).collect { |i| (beat * 0.5) + (i * beat) };
st = [0.13, 0.19, 0.18, 0.2];
r = take.(full, hits, st);
~tEq.("four even hits half a beat after the press read as one bar of 4/4", [r[\numerator], r[\denominator], r[\k], r[\error]], [4, 4, 1, nil]);
~tNear.("...at their tempo", r[\bpm], 107, 0.5);
~tNear.("...the loop as long as it was", r[\loopDur], full, 1e-6);
~tEq.("...saying it came from the whole loop's fit, as the take's log does", [r[\wholeLoop], Looper.resultForLog(r)[\wholeLoop]], [true, true]);
r = take.(full, hits, st, false);
~tEq.("...where the first onset's fit alone length-anchors them", r[\error], \lengthAnchored);
// Before the snap: the answer is still the first fit's, its readings first on
// the list, the whole loop's after them, where the snap found 4/4.
MeterAnalyzer.wholeLoop = true;
a = MeterAnalyzer.analyze(full - hits[0], hits - hits[0], st, leadIn: hits[0]);
MeterAnalyzer.wholeLoop = false;
b = MeterAnalyzer.analyze(full - hits[0], hits - hits[0], st, leadIn: hits[0]);
MeterAnalyzer.wholeLoop = origWhole;
~tEq.("...the answer before the snap still the first fit's, its readings first",
    [a[\numerator], a[\k]] ++ a[\candidates].keep(b[\candidates].size).collect { |c| [c[\numerator], c[\denominator], c[\k]] },
    [b[\numerator], b[\k]] ++ b[\candidates].collect { |c| [c[\numerator], c[\denominator], c[\k]] });
~tAssert.("...and one bar of 4/4 after them", a[\candidates].drop(b[\candidates].size).any { |c|
    (c[\numerator] == 4) and: { c[\denominator] == 4 } and: { c[\k] == 1 } }, a[\candidates].collect { |c| c[\numerator] }.asString);

// A take the first fit reads keeps its reading: the rescue only answers
// where that fit found nothing.
full = 2.1;
hits = [0, 0.3, 0.6, 0.9, 1.2, 1.5, 1.8] + 0.01;
st = [1.0, 0.4, 0.7, 0.4, 0.7, 0.4, 0.4];
a = take.(full, hits, st);
b = take.(full, hits, st, false);
~tEq.("a take the first fit reads keeps its reading", [a[\numerator], a[\denominator], a[\k], a[\bpm], a[\wholeLoop]],
    [b[\numerator], b[\denominator], b[\k], b[\bpm], nil]);
~tEq.("...and its ranked list starts as it did", (a[\candidates] ? []).keep(b[\candidates].size).collect { |c|
    [c[\numerator], c[\denominator], c[\k]] }, b[\candidates].collect { |c| [c[\numerator], c[\denominator], c[\k]] });

// Without a lead-in (the overdub detection) there is no whole loop to fit:
// the switch changes nothing.
MeterAnalyzer.wholeLoop = true;
a = MeterAnalyzer.analyze(2.1, [0, 0.3, 0.6, 0.9, 1.2, 1.5, 1.8], st);
MeterAnalyzer.wholeLoop = false;
b = MeterAnalyzer.analyze(2.1, [0, 0.3, 0.6, 0.9, 1.2, 1.5, 1.8], st);
MeterAnalyzer.wholeLoop = origWhole;
~tEq.("without a lead-in the whole loop's fit changes nothing", a[\candidates].collect { |c| [c[\numerator], c[\k], c[\score]] },
    b[\candidates].collect { |c| [c[\numerator], c[\k], c[\score]] });

// The fallback is the meter the player plays: where it fits the loop itself
// the rescue does not overrule it.
s = 0.3;
~tEq.("the 7/8 fallback fits hits on its own eighths over the whole loop",
    MeterAnalyzer.prFallbackFits([0, 2, 4, 7, 9, 11].collect { |p| (p * s) + 0.05 }, 14 * s), true);
~tEq.("...and not sixteen even pulses, two bars of 4/4", MeterAnalyzer.prFallbackFits((0..15).collect { |p| p * 0.28 }, 16 * 0.28), false);

// fitPhase: the pulse is the loop over n, the phase where the hits are.
f = MeterAnalyzer.fitPhase((0..7).collect { |i| 0.1 + (i * 0.25) }, 2.0, 8);
~tNear.("fitPhase finds the phase", f[\origin], 0.1, 1e-6);
~tEq.("...the pulse the loop over n, every hit on it", [f[\tau], f[\fit], f[\err].round(1e-9)], [0.25, 1.0, 0.0]);

// A two-pulse bar's accent is the contrast of its pulses in the whole loop's
// fit: a correlation of two values that differ at all is always 1.
a = MeterAnalyzer.accentAlign(0.5, 2, 4, 1, [0, 0.5, 1.0, 1.5], [0.5, 1.0, 0.5, 1.0], true);
~tEq.("a 2/4 bar's accent is its contrast, the stronger pulse the downbeat", [a[\score].round(1e-9), a[\phase]], [(1/3).round(1e-9), 1]);
a = MeterAnalyzer.accentAlign(0.5, 2, 4, 1, [0, 0.5, 1.0, 1.5], [1.0, 1.0, 1.0, 1.0], true);
~tEq.("...none for even hits", a[\score], 0);
a = MeterAnalyzer.accentAlign(0.5, 2, 4, 1, [0, 0.5, 1.0, 1.5], [0.9, 1.0, 0.9, 1.0]);
~tEq.("...where the first fit's correlation gives any difference it all", a[\score].round(1e-9), 1);

MeterAnalyzer.fallbackNum = origNum;
MeterAnalyzer.fallbackDenom = origDenom;
MeterAnalyzer.fallbackBars = origBars;
}.value;

// ---- long phrases (longK) ------------------------------------------------
// Eight bars of 4/4 under 100 BPM have no reading in maxK bars: four of them
// are under bpmRangeLo. The duo's eight bars at 85 (2026-11-07) came out as
// the 7/8 fallback; up to longK bars, tried when nothing else fits, reads them.
{
var origLongK = MeterAnalyzer.longK;
var origFallback = [MeterAnalyzer.fallbackNum, MeterAnalyzer.fallbackDenom, MeterAnalyzer.fallbackBars];
var jit = [0.008, -0.006, 0.011, -0.009, 0.004, -0.012, 0.007, -0.003];
// `bars` bars of 4/4 at `bpm`, hits on the eighths where `pat` is above 0,
// a little off the grid, the record press 40 ms ahead of the first.
var phrase = { |bars, bpm, pat|
    var eighth = 30 / bpm, hits = List.new, st = List.new;
    bars.do { |b| pat.do { |s, i| if(s > 0) {
        hits.add(0.04 + (((b * 8) + i) * eighth) + jit.wrapAt(hits.size));
        st.add(s) } } };
    [(bars * 8 * eighth) + 0.02, hits.asArray, st.asArray]
};
var read = { |p|
    var hits = p[1];
    MeterAnalyzer.fallbackNum = 7; MeterAnalyzer.fallbackDenom = 8; MeterAnalyzer.fallbackBars = 0;
    MeterDecision.snapAnalysisToLoop(MeterAnalyzer.analyze(p[0] - hits[0], hits - hits[0], p[2],
        leadIn: hits[0]), p[0])
};
var riff = [1, 0, 0.6, 0.5, 0, 0.6, 0.7, 0], rock = [1, 0.3, 0.7, 0.3, 0.9, 0.3, 0.7, 0.5];
var r;

MeterAnalyzer.longK = 8;
r = read.(phrase.(8, 85, riff));
~tEq.("eight bars of 4/4 at 85 read as eight bars of 4/4",
    [r[\numerator], r[\denominator], r[\k], r[\error], r[\long]], [4, 4, 8, nil, true]);
~tNear.("...at 85", r[\bpm], 85, 0.5);
r = read.(phrase.(8, 85, rock));
~tEq.("...played on every eighth too", [r[\numerator], r[\denominator], r[\k]], [4, 4, 8]);
MeterAnalyzer.longK = MeterAnalyzer.maxK;
r = read.(phrase.(8, 85, riff));
~tEq.("...and with longK at maxK, the fallback as before", [r[\numerator], r[\denominator], r[\error]], [7, 8, \lengthAnchored]);
MeterAnalyzer.longK = 8;

// Only where nothing fits: a slow four-bar take keeps its four bars. With
// eight let in everywhere, four of 4/4 at 60 to 78 read as eight at twice
// the tempo (maxK 8: this one as eight at 140).
r = read.(phrase.(4, 70, rock));
~tEq.("four bars of 4/4 at 70 stay four bars", [r[\numerator], r[\denominator], r[\k], r[\long]], [4, 4, 4, nil]);
~tNear.("...at 70", r[\bpm], 70, 0.5);

// Hits on no grid still go to the fallback: the longer grids want onsets
// to fill them (longMinDensity). Of 200 random takes of 6 to 30 hits over
// 10 to 25 s, the longer grids read 2 more than maxK's do, 15 without it:
// this one came out 9/8 at 85 over seven bars.
r = read.([22.27, [3.23, 6.78, 9.01, 9.98, 12.13, 13.41, 13.47, 16.3, 17.02, 19.08, 21.59],
    [0.58, 0.93, 0.54, 0.61, 0.57, 0.4, 0.73, 0.84, 0.4, 0.65, 0.88]]);
~tEq.("eleven scattered hits over 22 s still go to the fallback", [r[\numerator], r[\denominator], r[\error]], [7, 8, \lengthAnchored]);
r = read.([22, [0.42, 1.00, 1.38, 2.05, 2.12, 3.49, 4.07, 6.62, 9.83, 10.11, 11.02, 11.11, 11.46,
    12.14, 12.73, 13.33, 13.64, 14.16, 15.01, 17.15, 17.51, 19.97, 20.84, 21.22], 0.5 ! 24]);
~tEq.("...and twenty-four", [r[\numerator], r[\denominator], r[\error]], [7, 8, \lengthAnchored]);

MeterAnalyzer.longK = origLongK;
MeterAnalyzer.fallbackNum = origFallback[0];
MeterAnalyzer.fallbackDenom = origFallback[1];
MeterAnalyzer.fallbackBars = origFallback[2];
}.value;

// ---- no fallback (fallbackOn off) ------------------------------------------
// Off, a take that fits nothing has no meter: the loop keeps its length and
// has no tempo, and an overdub can find one (2026-11-07; the app's default,
// the Rig page's switch). On is the library's default, every test above.
{
var orig = [MeterAnalyzer.fallbackOn, MeterAnalyzer.fallbackNum, MeterAnalyzer.fallbackDenom,
    MeterAnalyzer.fallbackBars];
var irregular = [0.0, 0.35, 0.61, 0.99, 1.4, 1.72, 2.05, 2.31, 2.66, 2.8];
var tenSecs = (score: 0.9, numerator: 5, denominator: 4, k: 1, sub: 1, tau: 0.6369,
    loopDur: 0.6369 * 5, bpm: 240 / (4 * 0.6369), n: 5, phase: 0, downbeatOffset: 0, accent: 0, onsetCount: 9);
// A sparse take whose whole loop reads 7/8, which the 7/8 fallback fits too.
var full = 4.097, hits = [0.341, 0.622, 2.076, 2.673, 3.538], st = [1.0, 0.4, 1.0, 0.6, 0.4];
var take = { |on|
    MeterAnalyzer.fallbackOn = on;
    MeterDecision.snapAnalysisToLoop(MeterAnalyzer.analyze(full - hits[0], hits - hits[0], st, leadIn: hits[0]), full)
};
var r;
MeterAnalyzer.fallbackNum = 7; MeterAnalyzer.fallbackDenom = 8; MeterAnalyzer.fallbackBars = 0;

MeterAnalyzer.fallbackOn = false;
r = MeterAnalyzer.analyze(2.99, irregular, irregular.collect { 1.0 });
~tEq.("off, a take that fits no grid has no meter",
    [r[\error], r[\numerator], r[\denominator], r[\bpm], r[\onsetCount]], [\noFit, nil, nil, nil, 10]);
r = MeterDecision.snapAnalysisToLoop(r, 3.1);
~tEq.("...and the snap keeps the take as it is", [r[\error], r[\numerator], r[\loopDur]], [\noFit, nil, 3.1]);
r = MeterDecision.snapAnalysisToLoop(tenSecs.copy.put(\candidates, [tenSecs]), 10.0);
~tEq.("...as where a reading would move it and nothing else fits",
    [r[\error], r[\numerator], r[\loopDur], r[\snapRefused].notNil], [\noFit, nil, 10.0, true]);
MeterAnalyzer.fallbackOn = true;
r = MeterDecision.snapAnalysisToLoop(tenSecs.copy.put(\candidates, [tenSecs]), 10.0);
~tEq.("...which on is the fallback, as before", [r[\error], r[\numerator], r[\denominator]], [\lengthAnchored, 7, 8]);

// The whole loop's reading gives way to a fallback that fits, the meter
// the player chose; with none chosen, it answers.
r = take.(true);
~tEq.("on, a fallback that fits the whole loop keeps the take",
    [r[\error], r[\numerator], r[\denominator]], [\lengthAnchored, 7, 8]);
r = take.(false);
~tEq.("...off, the whole loop's reading answers", [r[\error], r[\numerator], r[\denominator], r[\wholeLoop]],
    [nil, 7, 8, true]);

MeterAnalyzer.fallbackOn = orig[0];
MeterAnalyzer.fallbackNum = orig[1];
MeterAnalyzer.fallbackDenom = orig[2];
MeterAnalyzer.fallbackBars = orig[3];
}.value;
