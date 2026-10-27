// Half-time (docs/dev/rc600-picks.md, 3a): the loop at half speed under drums
// that keep their tempo. On the server-free fixture: what a press does in each
// state and what it sends the engine (when the engine is to take it is the
// server's, checked offline by scripts/sa/nrt-engine-rate.scd), the landing and
// the release, what is refused at half-time and what refuses it, and what keeps
// time with it: the break, a reading, the next boundary, the onset kit, the
// drums' drift probe and the count.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-halftime");

{
var scripts = thisProcess.nowExecutingPath.dirname.dirname;
var ld = 3.5, l, eng, refused, heard, now, at, b, land, speeds, r78, sink, got, d, wasLooper, wasAnchor, wasDelay, s;
var fresh = {
    var x = ~tLooper.();
    ~tPut.(x, \state, \playing);
    ~tPut.(x, \loopFrames, (ld * 48000).asInteger);
    ~tPut.(x, \lastResult, r78);
    eng = ~tStubSynth.(x, \looperEngine);
    ~tPut.(x, \engineSynth, eng);
    refused = List.new;
    heard = List.new;
    SimpleController(x).put(\refused, { |o, w, what, why| refused.add([what, why]) })
        .put(\halfTime, { |o, w, v| heard.add([\halfTime, v]) })
        .put(\speed, { |o, w, v| heard.add([\speed, v]) });
    x
};
// The landing or release the press armed, as its routine would run it on time.
land = { |x|
    ~tGet.(x, \halfTimeRoutine) !? { |rt| rt.stop };
    x.prHalfTimeLands(~tGet.(x, \halfTimeSeq));
};
// The bundles sent to the engine, as [time, value] of its speed.
speeds = { |x| ~tGet.(x, \server)[\bundles].select { |e| e[1].any { |m| m[0] == 15 and: { m[2] == \speed } } }
    .collect { |e| [e[0], e[1].detect { |m| m[0] == 15 }[3]] } };
r78 = (numerator: 7, denominator: 8, tau: 0.25, sub: 1, k: 2, loopDur: ld, bpm: 120, n: 14, phase: 0);

// ---- arming ---------------------------------------------------------------------------
l = fresh.();
now = SystemClock.seconds;
~tPut.(l, \loopStartTime, now - 1.0);
l.toggleHalfTime;
~tEq.("a press while the loop plays arms half-time for the next boundary",
    [l.halfTime, l.speed, (l.halfTimeAt - (now + 2.5)).abs < 0.01], [\armed, 1, true]);
~tEq.("...the engine is sent speed 0.5 at once (it takes it on the loop's start)", ~tLastSet.(l, eng, \speed), 0.5);
~tEq.("...it is said", heard.asArray, [[\halfTime, \armed]]);
~tEq.("...and it is coming: the count counts in to it",
    l.upcoming(now).collect { |e| e[\what] }, [\halfTime]);
l.toggleHalfTime;
~tEq.("pressed again before the boundary: off, the engine sent speed 1",
    [l.halfTime, ~tLastSet.(l, eng, \speed), l.halfTimeAt], [\off, 1, nil]);

// Within the margin of the boundary: the boundary after, the speed timed past it.
l = fresh.();
now = SystemClock.seconds;
~tPut.(l, \loopStartTime, (now + 0.03) - ld);
l.toggleHalfTime;
b = speeds.(l);
~tEq.("a press 30 ms before a boundary arms the one after",
    (l.halfTimeAt - (now + 0.03 + ld)).abs < 0.01, true);
~tEq.("...and the speed is sent timed 10 ms past the near boundary, so the engine doesn't take it there",
    [b.size, b.last !? { |x| ((x[0] - (now + 0.04)).abs < 0.005) }, b.last !? { |x| x[1] }], [1, true, 0.5]);
l.toggleHalfTime;
~tEq.("...pressed again, taken back: speed 1 after it", [l.halfTime, speeds.(l).last[1]], [\off, 1]);

// ---- landing, the half-speed pass, the release -------------------------------------------
l = fresh.();
now = SystemClock.seconds;
~tPut.(l, \loopStartTime, now - 1.0);
l.toggleHalfTime;
at = l.halfTimeAt;
heard.clear;
land.(l);
~tEq.("on the boundary: half-time, the pass twice as long, counted from the boundary",
    [l.halfTime, l.speed, l.passOrigin == at, l.speedChangedAt == at, l.wallPeriod], [\on, 0.5, true, true, 7.0]);
~tEq.("...said as half-time on and the speed", heard.asArray, [[\halfTime, \on], [\speed, 0.5]]);
~tEq.("...the next boundary is the pass's end, two loops on",
    (l.prNextBoundaryAt(at + 1) - (at + 7)).abs < 1e-9, true);
~tEq.("...and passes begin where it landed", l.passStart == at, true);

// The release: sent in the pass's second half, never its first.
~tPut.(l, \passOrigin, now - 1.0);
~tPut.(l, \server, ~tStubServer.());
~tPut.(l, \engineSynth, (eng = ~tStubSynth.(l, \looperEngine)));
l.toggleHalfTime;
b = speeds.(l);
~tEq.("a press 1 s into the half-speed pass: ending, on the pass's end",
    [l.halfTime, (l.halfTimeAt - (now + 6.0)).abs < 0.01], [\releasing, true]);
~tEq.("...the engine sent speed 1 timed into the second half (3.5 s into the pass), not now",
    [b.size, b.last !? { |x| (x[0] - (now + 2.51)).abs < 0.005 }, b.last !? { |x| x[1] }], [1, true, 1]);
~tEq.("...the count counts in to it", l.upcoming(now).collect { |e| e[\what] }, [\halfTimeEnds]);
l.toggleHalfTime;
b = speeds.(l);
~tEq.("pressed again: on, speed 0.5 sent after the release still on its way",
    [l.halfTime, b.size, b.last[1], b.last[0] > b[0][0]], [\on, 2, 0.5, true]);
l.toggleHalfTime;
heard.clear;
land.(l);
~tEq.("the release lands: speed 1, off, no pass origin", [l.halfTime, l.speed, l.passOrigin, l.wallPeriod],
    [\off, 1, nil, ld]);
~tEq.("...said", heard.asArray, [[\halfTime, \off], [\speed, 1]]);
// A press in the second half: sent at once.
l = fresh.();
now = SystemClock.seconds;
~tPut.(l, \loopStartTime, now - 1.0);
l.toggleHalfTime;
land.(l);
~tPut.(l, \passOrigin, now - 5.0);
~tPut.(l, \server, ~tStubServer.());
~tPut.(l, \engineSynth, (eng = ~tStubSynth.(l, \looperEngine)));
l.toggleHalfTime;
~tEq.("a release pressed in the second half is sent at once", [speeds.(l).size, ~tLastSet.(l, eng, \speed)], [0, 1]);

// ---- refused at half-time, and what refuses it ---------------------------------------------
l = fresh.();
~tPut.(l, \loopStartTime, SystemClock.seconds - 1.0);
l.toggleHalfTime;
refused.clear;
l.startOverdub;
l.multiply;
l.undo;
l.recordNextLoop;
l.enableBBCut;
l.toggleGranular;
l.startDissolve;
~tEq.("armed: an overdub, multiply, undo, Rec next loop, the cutter, the grains, a dissolve are refused, saying why",
    refused.collect(_.first).asArray, [\trigger, \multiply, \undo, \recordNextLoop, \bbcut, \granular, \dissolve]);
~tEq.("...and nothing of them happened", [l.state, ~tGet.(l, \nextRecState), l.granularOn], [\playing, \idle, false]);
l.stopPlayback;
~tEq.("stop puts it back to speed 1, off", [l.halfTime, l.speed], [\off, 1]);
l = fresh.();
~tPut.(l, \state, \overdubbing);
l.toggleHalfTime;
~tPut.(l, \state, \stopped);
l.toggleHalfTime;
~tPut.(l, \state, \playing);
~tPut.(l, \bbcut, true);
l.toggleHalfTime;
~tPut.(l, \bbcut, false);
~tPut.(l, \nextRecState, \armed);
l.toggleHalfTime;
~tPut.(l, \nextRecState, \idle);
~tPut.(l, \dissolvePos, 0.3);
l.toggleHalfTime;
~tEq.("refused: overdubbing, stopped, with the cutter, with the next loop armed, in a dissolve",
    refused.collect(_.last).asArray, ["end the overdub first", "half-time needs a loop playing",
        "the cutter doesn't follow half-time yet", "Rec next loop is on", "a dissolve is on"]);
~tEq.("...and nothing armed", l.halfTime, \off);

// ---- what keeps time with it -----------------------------------------------------------------
~tEq.("a break at half-time: the rest of the pass at half speed (1 s of loop is 2 s), then passes of 7 s",
    [Looper.prBreakDuration(2.5, ld, 1, false, 0.5, 0.5), Looper.prBreakDuration(2.5, ld, 2, false, 0.5, 0.5)], [2.0, 9.0]);
~tEq.("...armed (speed 1 now, half after the boundary): 1 s, then 7 s",
    [Looper.prBreakDuration(2.5, ld, 1, false, 1, 0.5), Looper.prBreakDuration(2.5, ld, 2, false, 1, 0.5)], [1.0, 8.0]);
~tEq.("...at speed 1 as before", Looper.prBreakDuration(2.5, ld, 2), 4.5);

// The onset kit: the part twice as long, from where the pass began.
l = fresh.();
got = List.new;
sink = (startOnsets: { |self, lp, pattern, period| got.add([pattern, period, lp.passStart]) }, stopOnsets: { |self| });
l.onsetNoteSink = sink;
~tPut.(l, \onsetNotes, true);
~tPut.(l, \onsetNotePattern, [[0.5, 1.0], [1.25, 0.5]]);
~tPut.(l, \onsetNotePatternDur, ld);
now = SystemClock.seconds;
~tPut.(l, \loopStartTime, now - 1.0);
l.toggleHalfTime;
at = l.halfTimeAt;
got.clear;
land.(l);
~tEq.("landed: the onset kit plays the part at half speed, from the landing",
    got.asArray.collect { |g| [g[0], g[1], g[2] == at] }, [[[[1.0, 1.0], [2.5, 0.5]], 7.0, true]]);
l.startOnsetNotes;
~tAssert.("...a restart (a break's end) hands it the same part, so it stays on its grid",
    got[1][0] === got[0][0], "a new part");

// The drums' drift probe: the loop's phase runs at half the wall's.
d = MegaSADrums((server: ~tStubServer.()));
d.instVarPut(\looper, l);
~tEq.("the drums' loop model doesn't hold at half-time (no drift probe)", d.prLoopValid, false);
l.toggleHalfTime;
land.(l);
~tEq.("...and holds again after it", d.prLoopValid, true);

// A reading at half-time lands on the half-speed pass's end.
l = fresh.();
now = SystemClock.seconds;
~tPut.(l, \loopStartTime, now - 1.0);
~tPut.(l, \analysedResult, r78.copy.put(\candidates, [r78, r78.copy.putAll((numerator: 14, k: 1))]));
l.toggleHalfTime;
land.(l);
~tPut.(l, \passOrigin, now - 1.0);
l.nextReading;
~tEq.("a reading armed at half-time lands on the half-speed pass's end, 6 s on",
    l.pendingReading !? { |p| (p[\at] - (now + 6.0)).abs < 0.01 }, true);
l.stopPlayback;

// ---- the count at half speed (gui-status.scd) ---------------------------------------------------
if(~countPosAt.isNil) { (scripts +/+ "gui-status.scd").load };
wasLooper = ~looper; wasAnchor = ~countAnchor; wasDelay = ~countDelay;
l = fresh.();
~tPut.(l, \speed, 0.5);
~tPut.(l, \halfTime, \on);
~tPut.(l, \speedChangedAt, 99.0);
~tPut.(l, \passOrigin, 99.0);
~looper = l;
~countDelay = 0;
~countAnchor = (phase: 1.0, at: 100.0, dur: ld);
~tNear.("at half-time the playhead moves at half the wall's pace", ~countPosAt.(101.0), 1.5, 1e-9);
~tPut.(l, \speedChangedAt, 100.5);
~tNear.("...and across a change since the poll's answer, from the boundary", ~countPosAt.(101.0), 0.25, 1e-9);
~tPut.(l, \speedChangedAt, 99.0);
s = ~countAt.(101.0, 0);
~tEq.("the count: the loop's own bar and group (1.5 s in is its beat 7)", [s[\c][\bar], s[\c][\group], s[\c][\groupBeat]], [1, 3, 3]);
~tNear.("...its next beat line in wall time, twice as far", s[\c][\toEdge], 0.5, 1e-9);
~tNear.("...a beat twice as long", s[\beatDur], 0.5, 1e-9);
~looper = wasLooper; ~countAnchor = wasAnchor; ~countDelay = wasDelay;
}.value;
