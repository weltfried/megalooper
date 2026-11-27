// A roll that halves (roadmap item 24, idea 7; docs/dev/sampler.md): the
// Looper's part (LooperRoll) that turns the pedal into a roll in the engine
// and the drums' roller. On the server-free fixture: where it is armed (the
// next beat-group head, on the note there), what the engine and the roller
// are sent at each step of the pedal, the landing and rolling on, what it
// refuses and when, Drums roll too, and what cuts it. How the engine and the
// roller play it is the server's, checked offline by scripts/sa/nrt-roll.scd.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-roll");

{
// 7/8, two bars, an eighth 0.25 s: 2+2+3 a bar, the heads at 0, 0.5, 1.0,
// 1.75, 2.25 and 2.75 s; the loop 3.5 s, 168000 frames, a unit 12000.
var ld = 3.5, sr = 48000, n = (ld * sr).asInteger, l, eng, rol, refused, heard, now, fresh, r78, sets, last, armAt;
r78 = (numerator: 7, denominator: 8, tau: 0.25, sub: 1, k: 2, loopDur: ld, bpm: 120, n: 14, phase: 0);
fresh = {
    var x = ~tLooper.();
    ~tPut.(x, \state, \playing);
    ~tPut.(x, \loopFrames, n);
    ~tPut.(x, \lastResult, r78);
    eng = ~tStubSynth.(x, \looperEngine);
    ~tPut.(x, \engineSynth, eng);
    rol = ~tStubSynth.(x, \looperRoller);
    x.rollPart.rollers = [rol];
    // A note 20 ms after the head at 1.75 s (84000): the slices'.
    x.slicesPart.instVarPut(\starts, [960, 84960, 120000]);
    x.slicesPart.instVarPut(\period, n);
    refused = List.new;
    heard = List.new;
    SimpleController(x).put(\refused, { |o, w, what, why| refused.add([what, why]) })
        .put(\rolling, { |o, w, v| heard.add(v) });
    now = SystemClock.seconds;
    // The playhead 1.0 s into the loop: the head there is too near, the next
    // is 1.75 s, 0.75 s on.
    ~tPut.(x, \loopStartTime, now - 1.0);
    x
};
// What `synth` was last sent for `key`, now or in a bundle.
last = { |x, synth, key| ~tLastSet.(x, synth, key) };

// ---- arming on the next group head -------------------------------------------------
l = fresh.();
l.roll = 0.1;
~tEq.("the pedal off 0: armed for the next group head", [l.rollState, heard.asArray], [\armed, [\armed]]);
~tAssert.("...at 1.75 s, 0.75 s on (the head at 1.0 is nearer than the margin)", (l.rollPart.at - (now + 0.75)).abs < 0.02,
    (l.rollPart.at - now).asString);
~tEq.("...the engine armed on the note there (20 ms after the grid point), a window of the group (bar 2's first: 2 units)",
    [last.(l, eng, \rollArm), last.(l, eng, \rollAnchor), last.(l, eng, \rollWin)], [0, 84960, 24000.0]);
~tAssert.("...armed now and disarmed after it starts",
    ~tGet.(l, \server)[\msgs].any { |m| (m[0] == 15) and: { m[1] == eng.nodeID } and: { m.indexOf(\rollArm).notNil }
        and: { m[m.indexOf(\rollArm) + 1] == 1 } });
~tEq.("...the drums' roller armed on the grid point less 10 ms, the same window",
    [last.(l, rol, \rollAnchor), last.(l, rol, \rollWin)], [84000 - 480, 24000.0]);
~tEq.("...and it is coming: the count counts in to it", l.upcoming(now).collect { |e| e[\what] }, [\roll]);

// ---- the pedal's steps ---------------------------------------------------------------
[[0.3, 12000], [0.5, 6000], [0.7, 3000], [0.95, 1500], [0.2, 24000]].do { |c|
    l.roll = c[0];
    ~tEq.("the pedal at " ++ c[0] ++ ": a window of " ++ c[1] ++ " frames to the engine and the roller",
        [last.(l, eng, \rollWin), last.(l, rol, \rollWin)], [c[1], c[1]]);
};
~tEq.("the steps: off, then fifths", [0, 0.01, 0.2, 0.21, 0.4, 0.6, 0.8, 0.81, 1].collect { |x| LooperRoll.stepOf(x) },
    [nil, 1, 1, 2, 2, 3, 4, 5, 5]);

// ---- on, landing, rolling on -----------------------------------------------------------
~tFire.(l, \roll);
~tEq.("on its head: on", [l.rollState, heard.asArray.last], [\on, \on]);
~tPut.(l, \loopStartTime, SystemClock.seconds - 2.0);
l.roll = 0;
~tEq.("back to 0: landing on the next group head (2.25 s), on the grid there with no note near",
    [l.rollState, last.(l, eng, \rollLand), last.(l, eng, \rollLandAt)], [\landing, 0, 2.25 * sr]);
~tAssert.("...landing sent now, cleared after", ~tGet.(l, \server)[\msgs].any { |m| (m[0] == 15) and: { m[1] == eng.nodeID }
    and: { m.indexOf(\rollLand).notNil } and: { m[m.indexOf(\rollLand) + 1] == 1 } });
~tEq.("...the roller's landing 10 ms before the grid point", last.(l, rol, \rollLandAt), (2.25 * sr) - 480);
~tEq.("...the count counts in to the landing", l.upcoming(SystemClock.seconds).collect { |e| e[\what] }, [\rollLands]);
l.roll = 0.4;
~tEq.("up again before it lands: rolling on, the landing taken back",
    [l.rollState, ~tGet.(l, \server)[\msgs].reverse.detect { |m| (m[0] == 15) and: { m[1] == eng.nodeID } and: { m.indexOf(\rollLand).notNil } } !? { |m| m[m.indexOf(\rollLand) + 1] }],
    [\on, 0]);
~tEq.("...and nothing waits to say it landed", [~tFire.(l, \roll), l.rollState], [false, \on]);
l.roll = 0;
~tFire.(l, \roll);
~tEq.("landed: off", [l.rollState, heard.asArray.last], [\off, \off]);

// ---- off before it starts, and what cuts it ----------------------------------------------
l = fresh.();
l.roll = 0.5;
l.roll = 0;
~tEq.("back to 0 before it starts: disarmed at once, the engine and the roller",
    [l.rollState, last.(l, eng, \rollArm), last.(l, rol, \rollArm)], [\off, 0, 0]);
l = fresh.();
l.roll = 0.5;
~tFire.(l, \roll);
l.stopPlayback;
~tEq.("stop cuts a roll: off, the roller told to stop at once", [l.rollState, last.(l, rol, \rollCut)], [\off, 1]);
l = fresh.();
l.roll = 0.5;
~tFire.(l, \roll);
l.rollPart.cut;
~tEq.("a cut (a multiply, an undo): the engine and the roller stopped at once",
    [l.rollState, last.(l, eng, \rollCut), last.(l, rol, \rollCut)], [\off, 1, 1]);

// ---- Drums roll too ---------------------------------------------------------------------
l = fresh.();
l.rollDrums = false;
l.roll = 0.5;
~tEq.("Drums roll too off: the roller is not armed", [l.rollState, last.(l, rol, \rollArm)], [\armed, nil]);
~tEq.("...and it is on by default", ~tLooper.().rollDrums, true);

// ---- what it refuses, once a gesture -------------------------------------------------------
l = fresh.();
~tPut.(l, \state, \overdubbing);
l.roll = 0.3;
l.roll = 0.6;
~tEq.("while overdubbing: refused, saying why, once for the gesture",
    [l.rollState, refused.asArray], [\off, [[\roll, "end the overdub first"]]]);
l.roll = 0;
l.roll = 0.3;
~tEq.("...and again on the next", refused.size, 2);
l = fresh.();
~tPut.(l, \reverseFlag, true);
l.roll = 0.3;
~tEq.("reversed: refused", refused.asArray, [[\roll, "reversed: the roll plays forwards"]]);
l = fresh.();
~tPut.(l, \halfTime, \on);
~tPut.(l, \speed, 0.5);
l.roll = 0.3;
~tEq.("at half-time: refused", refused.asArray.last, [\roll, "half-time: end it first"]);
l = fresh.();
~tPut.(l, \lastResult, nil);
l.roll = 0.3;
~tEq.("with no reading: refused", refused.asArray, [[\roll, "the roll needs a reading"]]);
l = fresh.();
~tPut.(l, \state, \stopped);
l.roll = 0.3;
~tEq.("with no loop playing: nothing, nothing refused", [l.rollState, refused.asArray], [\off, []]);

// ---- what it refuses while it rolls ----------------------------------------------------------
l = fresh.();
l.roll = 0.3;
~tFire.(l, \roll);
l.startOverdub;
l.reverse;
l.toggleHalfTime;
~tEq.("rolling: an overdub, a reverse and half-time refused",
    refused.asArray, [[\trigger, "a roll is on: land it first"], [\reverse, "a roll is on: land it first"],
        [\halfTime, "a roll is on: land it first"]]);
}.value;
