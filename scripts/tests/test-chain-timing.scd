// Chain-record start timing ("free multiply").
//
// This is a REGRESSION file. The arithmetic it covers got the chained loops
// wrong once — a positive calibrated offset made the recorder start a whole
// repetition early — and at the time it was inline in a Routine next to
// Synth.tail, so there was no way to test it. Looper:prChainStartWait and
// Looper:prChainRecOffset exist so there is.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-chain-timing");

{
var l = ~tLooper.();
var ld = 2.0;

// ---- prChainRecOffset: ms control -> clipped seconds ---------------------

l.chainRecOffsetMs = 59;        // the calibrated bhTsMega value
~tNear.("59 ms becomes 0.059 s", l.prChainRecOffset(ld), 0.059, 1e-12);
l.chainRecOffsetMs = 0;
~tNear.("zero offset is zero", l.prChainRecOffset(ld), 0.0, 1e-12);
l.chainRecOffsetMs = -80;
~tNear.("negative offsets pass through", l.prChainRecOffset(ld), -0.08, 1e-12);

// Clipped to 90% of a loop either way. An offset of a whole loop or more would
// shift the start across a NEIGHBOURING boundary, which is the one error this
// cannot recover from: the recording would be a full repetition out and no
// amount of trimming afterwards would line it up.
l.chainRecOffsetMs = 2000;
~tNear.("offset clips to +90% of a short loop", l.prChainRecOffset(1.0), 0.9, 1e-12);
l.chainRecOffsetMs = -2000;
~tNear.("offset clips to -90% of a short loop", l.prChainRecOffset(1.0), -0.9, 1e-12);
~tAssert.("clip is loop-relative, not absolute",
    l.prChainRecOffset(10.0) == -2.0,
    "got " ++ l.prChainRecOffset(10.0) ++ ", want -2.0 on a 10 s loop");

// ---- prChainStartWait: the bug this file exists for ----------------------

// With no offset the recorder simply waits out the rest of the current pass.
~tNear.("no offset waits to the next boundary",
    l.prChainStartWait(ld, 0.5, 0.0), 1.5, 1e-12);
~tNear.("no offset, late in the pass",
    l.prChainStartWait(ld, 1.9, 0.0), 0.1, 1e-12);

// THE REGRESSION. Arming just after a boundary with a POSITIVE offset makes the
// correct wait longer than a whole loop (1.99 + 0.059). The old code ran this
// through .mod(ld), which collapsed it to 0.049 — starting the recorder at THIS
// boundary instead of the next one, a full repetition early. Only reachable
// when the arm lands within `off` of a boundary, which is why it presented as
// "sometimes the multiplied loop is out".
~tNear.("positive offset just after a boundary does NOT collapse (was .mod)",
    l.prChainStartWait(ld, 0.01, 0.059), 2.049, 1e-12);
~tAssert.("...and specifically exceeds a whole loop",
    l.prChainStartWait(ld, 0.01, 0.059) > ld,
    "a wait <= loop length here is the .mod bug returning");

// A negative offset CAN legitimately push the wait below zero, and that is the
// one case that does need a whole loop added back.
~tNear.("negative offset near the boundary is rescued by one loop",
    l.prChainStartWait(ld, 1.99, -0.059), 1.951, 1e-12);
~tAssert.("the wait is never negative",
    (0, 0.05 .. 1.95).collect { |ph|
        [-0.9, -0.2, -0.059, 0, 0.059, 0.2, 0.9].collect { |off|
            l.prChainStartWait(ld, ph, off)
        }
    }.flat.every { |w| w >= 0 },
    "a negative wait would make Routine:wait fire immediately");

// ---- the invariants the audio actually depends on -----------------------

// The start must land on a TRUE loop boundary plus the offset, whatever phase
// the player armed at. This is the property that makes the offset a calibration
// rather than a fudge: one number, correct from anywhere in the pass.
~tCheck.("start always lands on a boundary + offset, from any phase", {
    var worst = 0;
    (0, 0.017 .. 1.99).do { |ph|
        [-0.9, -0.3, -0.059, 0, 0.059, 0.3, 0.9].do { |off|
            var wait = l.prChainStartWait(ld, ph, off);
            // Absolute position of the start, measured from the loop reference,
            // with the offset taken back out: must be a whole number of loops.
            var landed = (ph + wait - off);
            var err = (landed / ld - (landed / ld).round).abs * ld;
            worst = max(worst, err);
        };
    };
    if(worst > 1e-9) {
        Error("worst deviation from a boundary: " ++ worst ++ " s").throw
    };
    worst
});

// The first repetition absorbs the offset ((ld - off).wait) so every LATER
// boundary is a true one — that is what keeps the handoff gapless when the
// finished chain replaces the running loop. Whatever the phase and offset, the
// end of the first repetition is a whole number of loops from the reference.
~tCheck.("first repetition ends exactly on a true boundary", {
    var worst = 0;
    (0, 0.017 .. 1.99).do { |ph|
        [-0.9, -0.059, 0, 0.059, 0.9].do { |off|
            var total = ph + l.prChainStartWait(ld, ph, off) + (ld - off);
            var err = (total / ld - (total / ld).round).abs * ld;
            worst = max(worst, err);
        };
    };
    if(worst > 1e-9) {
        Error("worst deviation at the end of rep 1: " ++ worst ++ " s").throw
    };
    worst
});

// Odd meters are the normal case here, so nothing may assume a 2-second loop.
~tCheck.("holds for a 7/8 loop length too", {
    var seven = 7 * (60/100) / 2;      // 7/8 at 100 bpm = 2.1 s
    var worst = 0;
    (0, seven / 37 .. seven * 0.999).do { |ph|
        [-0.13, 0, 0.053, 0.059].do { |off|
            var wait = l.prChainStartWait(seven, ph, off);
            var landed = ph + wait - off;
            worst = max(worst, (landed / seven - (landed / seven).round).abs * seven);
            if(wait < 0) { Error("negative wait at phase " ++ ph).throw };
        };
    };
    if(worst > 1e-9) { Error("worst deviation: " ++ worst).throw };
    worst
});

// ---- chaining is refused outright on a rig with no return path -----------

// returnChannel nil is the \standalone profile saying "there is no Live here,
// so there is nothing to chain from". Without the guard, arming would build a
// Synth with \ret -> nil, which cannot go into an OSC message; and a rig that
// pointed returnChannel at a plausible-looking channel instead would record
// either silence or, on a 2-in device, a private bus carrying the looper's own
// output straight back into the new loop.
~tAssert.("a rig with a return channel can chain",
    ~tPut.(~tLooper.(), \returnChannel, 12).canChainLoops);
~tAssert.("a rig without one cannot",
    ~tPut.(~tLooper.(), \returnChannel, nil).canChainLoops.not);

// Arming must bail on the guard, not on the "no loop playing" check below it —
// otherwise the message sends the player looking for a loop that is not the
// problem. loopFrames is deliberately non-zero so only the guard can stop it.
~tCheck.("arming is a no-op, not a throw, when chaining is unavailable", {
    var l = ~tLooper.();
    ~tPut.(l, \returnChannel, nil);
    ~tPut.(l, \loopFrames, 96000);
    l.armNextLoopRecord;
    if(~tGet.(l, \nextRecState) == \armed) {
        Error("armed anyway on a rig that cannot chain").throw;
    };
});

// The setter has to tolerate nil too: setup-model.scd pushes the profile's
// value in at boot, and \standalone's is nil.
~tCheck.("returnChannel_ accepts nil", { ~tLooper.().returnChannel = nil });
}.value;
