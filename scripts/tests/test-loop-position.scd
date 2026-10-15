// Looper.loopPositionAt: folding a playhead position onto the analysed grid.
//
// Pure arithmetic, no server and no Looper instance — which is the reason it is
// a class method at all (same argument as snapAnalysisToLoop beside it).
//
// The unit trap this file exists to pin down: tau is ONE PULSE, and
// MeterAnalyzer enumerates n = k*num*sub pulses, so a musical beat is tau*sub.
// Counting in tau alone reports a 7/8 fit with sub = 2 as 14 beats to the bar.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-loop-position");

{
// A 7/8 take, 2 bars, sub = 2: pulse 0.125 s, beat 0.25 s, bar 1.75 s,
// loop 3.5 s. The user records in 7/8, so this is the shape that matters most.
var r78 = (numerator: 7, denominator: 8, tau: 0.125, sub: 2, k: 2,
    downbeatOffset: 0);
var dur78 = 3.5;

// The same fit as the analyzer's length-anchored path returns it: sub = 1, so
// tau IS the beat. Both spellings must count the same way.
var r44 = (numerator: 4, denominator: 4, tau: 0.5, sub: 1, k: 2,
    downbeatOffset: 0);
var dur44 = 4.0;

var at = { |pos, result, dur| Looper.loopPositionAt(pos, result, dur) };
var barBeat = { |pos, result, dur|
    var o = at.(pos, result, dur);
    [o[\bar], o[\beat]]
};

// ---- 7/8, sub = 2: beats are tau*sub, NOT tau -------------------------------
~tEq.("7/8 beatsPerBar is the numerator", at.(0, r78, dur78)[\beatsPerBar], 7);
~tEq.("7/8 barCount is k",                at.(0, r78, dur78)[\barCount],    2);
~tEqArray.("7/8 loop start is bar 1 beat 1", barBeat.(0,     r78, dur78), [1, 1]);
~tEqArray.("7/8 one beat in is beat 2",      barBeat.(0.25,  r78, dur78), [1, 2]);
~tEqArray.("7/8 mid-beat stays on the beat", barBeat.(0.26,  r78, dur78), [1, 2]);
~tEqArray.("7/8 last beat of bar 1",         barBeat.(1.5,   r78, dur78), [1, 7]);
~tEqArray.("7/8 bar 2 downbeat",             barBeat.(1.75,  r78, dur78), [2, 1]);
~tEqArray.("7/8 last beat of the loop",      barBeat.(3.49,  r78, dur78), [2, 7]);

// ---- sub = 1 counts identically --------------------------------------------
~tEq.("4/4 beatsPerBar", at.(0, r44, dur44)[\beatsPerBar], 4);
~tEqArray.("4/4 beat 3 of bar 1", barBeat.(1.0, r44, dur44), [1, 3]);
~tEqArray.("4/4 bar 2 downbeat",  barBeat.(2.0, r44, dur44), [2, 1]);

// ---- fraction ---------------------------------------------------------------
~tNear.("fraction at loop start", at.(0,     r78, dur78)[\fraction], 0.0,  1e-9);
~tNear.("fraction at half way",   at.(1.75,  r78, dur78)[\fraction], 0.5,  1e-9);
~tNear.("fraction clips past the end", at.(99, r78, dur78)[\fraction], 1.0, 1e-9);
~tNear.("fraction clips before the start", at.(-5, r78, dur78)[\fraction], 0.0, 1e-9);

// ---- the wrap ---------------------------------------------------------------
// The playhead is only ever inside the loop — Phasor wraps rather than ever
// emitting loopDur — but a stale bus read can arrive at or past the end, and
// the answer there must not be a phantom bar 3. loopDur IS the next pass's
// downbeat, so the modulo folding it to bar 1 beat 1 is the right answer, and
// one beat earlier is still the last beat of the last bar.
~tEqArray.("just before the end is the last beat of the last bar",
    barBeat.(dur78 - 0.01, r78, dur78), [2, 7]);
~tEqArray.("exactly loopDur folds to the next downbeat, not a phantom bar",
    barBeat.(dur78, r78, dur78), [1, 1]);
~tEqArray.("an overshooting read clips rather than running off the grid",
    barBeat.(dur78 + 99, r78, dur78), [1, 1]);

// ---- whose downbeat ---------------------------------------------------------
// Beat one is the TRANSPORT's beat one. For a first take that is the record
// press: Live's 1.1.1, the cutter's beat 0 and the break's resume all sit at
// frame 0, and the header has to agree with them. So the analyser's
// accent-derived estimate — kept in the result as downbeatOffset, and measured
// from the first onset rather than from frame 0 — must not move the count.
// Decided 2026-09-25 after the disagreement was confirmed on the rig with a
// pickup; see docs/dev/signals.md.
{
    var est = r78.copy;
    est[\downbeatOffset] = 0.1;
    ~tEqArray.("the analyser's estimate does not move beat 1 off the press",
        barBeat.(0.0,  est, dur78), [1, 1]);
    ~tEqArray.("and the first beat boundary is still one beat from the press",
        barBeat.(0.25, est, dur78), [1, 2]);
}.value;

// A meter detected from an OVERDUB has no press to anchor to. There
// detectMeterFromOverdub stores downbeatPhase — the absolute loop position it
// holds Live's Start for — and the count starts from that, so the header and
// Live agree on that path too.
{
    var od = r78.copy;
    od[\downbeatPhase] = 0.1;
    ~tEqArray.("overdub grid: the downbeat itself is bar 1 beat 1",
        barBeat.(0.1,  od, dur78), [1, 1]);
    // 0.35 - 0.1 = 0.24999999999999994 in doubles; without the epsilon in
    // loopPositionAt this floors to the PREVIOUS beat and reports beat 1.
    ~tEqArray.("overdub grid: a beat boundary lands on the new beat",
        barBeat.(0.35, od, dur78), [1, 2]);
    ~tEqArray.("overdub grid: before the downbeat wraps to the loop's last beat",
        barBeat.(0.0,  od, dur78), [2, 7]);
}.value;

// ---- no grid to count on -----------------------------------------------------
// Every one of these must still yield a usable fraction: the progress bar needs
// no meter, and a caller that gets a nil bar shows elapsed/total alone.
{
    var noMeter = { |label, result, pos = 1.0, dur = 3.5|
        var o = at.(pos, result, dur);
        ~tAssert.(label ++ ": bar is nil",  o[\bar].isNil,  "got " ++ o[\bar]);
        ~tAssert.(label ++ ": beat is nil", o[\beat].isNil, "got " ++ o[\beat]);
        o
    };
    ~tNear.("nil result still reports a fraction",
        noMeter.("nil result", nil)[\fraction], 1.0 / 3.5, 1e-9);
    ~tNear.("failed analysis still reports a fraction",
        noMeter.("insufficientOnsets", (error: \insufficientOnsets))[\fraction],
        1.0 / 3.5, 1e-9);
    // The length-anchored fallback is the "we found no beat" answer, so it gets
    // no beat counter — consistent with prHasValidMeter rejecting it.
    ~tNear.("length-anchored still reports a fraction",
        noMeter.("lengthAnchored",
            (error: \lengthAnchored, numerator: 7, denominator: 8, tau: 0.5,
                sub: 1, k: 1))[\fraction],
        1.0 / 3.5, 1e-9);
    noMeter.("tau nil",  (numerator: 7, sub: 1));
    noMeter.("tau zero", (numerator: 7, tau: 0, sub: 1));
    noMeter.("numerator nil", (tau: 0.25, sub: 1));
}.value;

// ---- degenerate arguments ----------------------------------------------------
// A UI polls this every frame, including before anything is recorded and in the
// gap between a bus read being issued and the loop being cleared under it. None
// of that may throw.
{
    var degenerate = { |label, o|
        ~tAssert.(label ++ ": bar is nil", o[\bar].isNil, "got " ++ o[\bar]);
        ~tNear.(label ++ ": fraction is 0", o[\fraction], 0.0, 1e-9);
    };
    degenerate.("loopDur 0",   at.(1.0, r78, 0));
    degenerate.("loopDur nil", at.(1.0, r78, nil));
    degenerate.("loopDur negative", at.(1.0, r78, -1));
    degenerate.("pos nil",     at.(nil, r78, dur78));
    degenerate.("all nil",     at.(nil, nil, nil));
}.value;

}.value;
