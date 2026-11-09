// Reverse (2026-11-06): armed for the next boundary, as half-time is, so the
// loop's boundaries stay where they were. On the server-free fixture: what a
// press does in each state and what it sends the engine (when the engine takes
// it is the server's, checked offline by scripts/sa/nrt-engine-rate.scd), the
// landing, taking it back, the boundary after when a press comes too close,
// at half-time, with no loop playing, and what drops it.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-reverse");

{
var ld = 3.5, l, eng, refused, heard, now, b, land, dirs, fresh, r78, seq;
fresh = {
    var x = ~tLooper.();
    ~tPut.(x, \state, \playing);
    ~tPut.(x, \loopFrames, (ld * 48000).asInteger);
    ~tPut.(x, \lastResult, r78);
    eng = ~tStubSynth.(x, \looperEngine);
    ~tPut.(x, \engineSynth, eng);
    refused = List.new;
    heard = List.new;
    SimpleController(x).put(\refused, { |o, w, what, why| refused.add([what, why]) })
        .put(\reverse, { |o, w, v| heard.add([\reverse, v]) })
        .put(\reverseArmed, { |o, w, v| heard.add([\reverseArmed, v]) });
    x
};
// The landing the press armed, as its routine would run it on time.
land = { |x|
    x.timeline.routine(\reverse) !? { |rt| rt.stop };
    x.prReverseLands(x.timeline.token(\reverse));
};
// The bundles sent to the engine, as [time, value] of its direction.
dirs = { |x| ~tGet.(x, \server)[\bundles].select { |e| e[1].any { |m| (m[0] == 15) and: { m[2] == \dir } } }
    .collect { |e| [e[0], e[1].detect { |m| m[0] == 15 }[3]] } };
r78 = (numerator: 7, denominator: 8, tau: 0.25, sub: 1, k: 2, loopDur: ld, bpm: 120, n: 14, phase: 0);

// ---- arming and taking it back --------------------------------------------------------
l = fresh.();
now = SystemClock.seconds;
~tPut.(l, \loopStartTime, now - 1.0);
l.reverse;
~tEq.("a press while the loop plays arms the reverse for the next boundary, the loop still forwards",
    [l.reverseArmed, l.reverseFlag, (l.reverseAt - (now + 2.5)).abs < 0.01], [true, false, true]);
~tEq.("...the engine is sent the direction at once (it takes it on the loop's start)", ~tLastSet.(l, eng, \dir), -1);
~tEq.("...it is said", heard.asArray, [[\reverseArmed, true]]);
~tEq.("...and it is coming: the count counts in to it", l.upcoming(now).collect { |e| e[\what] }, [\reverse]);
heard.clear;
l.reverse;
~tEq.("pressed again before the boundary: taken back, the engine sent forwards",
    [l.reverseArmed, l.reverseFlag, ~tLastSet.(l, eng, \dir), l.reverseAt], [false, false, 1, nil]);
~tEq.("...said, and nothing coming", [heard.asArray, l.upcoming(now)], [[[\reverseArmed, false]], []]);
seq = l.timeline.token(\reverse);
l.prReverseLands(seq - 1);
~tEq.("...and the routine of the arm taken back lands nothing", [l.reverseFlag, l.reverseArmed], [false, false]);

// Within the margin of the boundary: the boundary after, the direction timed past it.
l = fresh.();
now = SystemClock.seconds;
~tPut.(l, \loopStartTime, (now + 0.03) - ld);
l.reverse;
b = dirs.(l);
~tEq.("a press 30 ms before a boundary arms the one after", (l.reverseAt - (now + 0.03 + ld)).abs < 0.01, true);
~tEq.("...and the direction is sent timed 10 ms past the near boundary, so the engine doesn't take it there",
    [b.size, b.last !? { |x| (x[0] - (now + 0.04)).abs < 0.005 }, b.last !? { |x| x[1] }], [1, true, -1]);
l.reverse;
~tEq.("...pressed again, taken back: forwards sent after it", [l.reverseArmed, dirs.(l).last[1]], [false, 1]);
~tAssert.("...timed after the one still on its way", dirs.(l).last[0] > dirs.(l).first[0],
    dirs.(l).asString);

// A press too close to its landing to be taken back.
l = fresh.();
now = SystemClock.seconds;
~tPut.(l, \loopStartTime, now - 1.0);
l.reverse;
~tPut.(l, \reverseAt, now + 0.02);
l.reverse;
~tEq.("a press within 50 ms of the landing is refused, saying why, and it stays armed",
    [refused.asArray, l.reverseArmed], [[[\reverse, "the reverse lands now"]], true]);

// ---- landing, and back -----------------------------------------------------------------
l = fresh.();
now = SystemClock.seconds;
~tPut.(l, \loopStartTime, now - 1.0);
l.reverse;
heard.clear;
land.(l);
~tEq.("on the boundary: backwards, nothing armed", [l.reverseFlag, l.reverseArmed, l.reverseAt], [true, false, nil]);
~tEq.("...said", heard.asArray, [[\reverseArmed, false], [\reverse, true]]);
l.reverse;
~tEq.("a press while it plays backwards arms forwards for the next boundary",
    [l.reverseArmed, l.reverseFlag, ~tLastSet.(l, eng, \dir), l.upcoming(now).collect { |e| e[\what] }],
    [true, true, 1, [\forward]]);
land.(l);
~tEq.("...and it lands forwards", [l.reverseFlag, l.reverseArmed], [false, false]);

// ---- at half-time ------------------------------------------------------------------------
// The pass is two loops long; the engine's reference wraps once a loop, so the
// direction goes after the wrap in the middle of the pass.
l = fresh.();
now = SystemClock.seconds;
~tPut.(l, \loopStartTime, now - 8.0);
~tPut.(l, \speed, 0.5);
~tPut.(l, \halfTime, \on);
~tPut.(l, \passOrigin, now - 1.0);
l.reverse;
b = dirs.(l);
~tEq.("at half-time a press lands on the end of the half-speed pass",
    (l.reverseAt - (now + 6.0)).abs < 0.01, true);
~tEq.("...the direction timed 10 ms past the loop-long wrap in its middle",
    [b.size, b.last !? { |x| (x[0] - (now + 2.51)).abs < 0.005 }, b.last !? { |x| x[1] }], [1, true, -1]);

// Half-time landing on the near boundary, a reverse pressed too close to it:
// the boundary after is a half-speed pass on.
l = fresh.();
now = SystemClock.seconds;
~tPut.(l, \loopStartTime, (now + 0.03) - ld);
~tPut.(l, \halfTime, \armed);
~tPut.(l, \halfTimeAt, (now + 0.03 - ld) + ld);
l.reverse;
~tEq.("a reverse too close to a half-time landing lands a half-speed pass after it",
    (l.reverseAt - (now + 0.03 + (2 * ld))).abs < 0.01, true);

// ---- with no loop playing, and what drops it ------------------------------------------------
l = fresh.();
~tPut.(l, \state, \stopped);
~tPut.(l, \engineSynth, nil);
l.reverse;
~tEq.("with no loop playing a press switches at once: the next take plays backwards",
    [l.reverseFlag, l.reverseArmed, heard.asArray], [true, false, [[\reverse, true]]]);
l.reverse;
~tEq.("...and back", l.reverseFlag, false);

l = fresh.();
now = SystemClock.seconds;
~tPut.(l, \loopStartTime, now - 1.0);
l.reverse;
l.stopPlayback;
~tEq.("stop drops a reverse that is armed, and it plays as it did", [l.reverseArmed, l.reverseFlag, l.reverseAt],
    [false, false, nil]);

l = fresh.();
now = SystemClock.seconds;
~tPut.(l, \loopStartTime, now - 1.0);
l.reverse;
l.prResetReverse;
~tEq.("a new engine drops it too (spawnEngine), saying so", [l.reverseArmed, heard.asArray.last],
    [false, [\reverseArmed, false]]);
}.value;
