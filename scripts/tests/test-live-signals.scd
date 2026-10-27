// What the Looper hears live, held for the model and the window (roadmap
// items 12 and 20): the analysis monitor's hits in a ring (the room), and a
// take the analysis tap heard far below the recorded input (tapStarvedGap),
// which the take's hint says until the next take.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-live-signals");

// ---- the room ------------------------------------------------------------------
{
var l = ~tLooper.(), heard = List.new, lamp = List.new, got;
~tPut.(l, \inChannel, 0);
~tPut.(l, \analysisChannel, 2);
SimpleController(l).put(\liveOnset, { |obj, what, t, s| heard.add([t, s]) });
l.onMonitor = { |level, onset, strength| lamp.add([level, onset, strength]) };
~tEq.("no hit yet: none, no last one, no rate", [l.liveOnsets(nil, 100), l.lastLiveOnset(100), l.liveOnsetRate(4, 100)], [[], nil, 0]);
[[100.0, 0.8], [100.5, 0.3], [101.25, 0.6], [103.0, 0.9]].do { |h| l.prMonitorOnset(h[1], 0.2, h[0]) };
l.prMonitorLevel(0.05);
~tEq.("each hit is kept, said, and lit on the lamp as before", [l.liveOnsetCount, heard.size, lamp.size, lamp[0]],
    [4, 4, 5, [0.2, true, 0.8]]);
~tEq.("...the level is the monitor's last", l.liveLevel, 0.05);
~tEq.("the hits of the last two and a half seconds before 103.5", l.liveOnsets(2.5, 103.5), [[101.25, 0.6], [103.0, 0.9]]);
~tEq.("the last hit before a press at 102: what a pre-roll snaps back to", l.lastLiveOnset(102.0), [101.25, 0.6]);
~tEq.("hits a second over the last four", l.liveOnsetRate(4, 103.5), 1.0);
100.do { |i| l.prMonitorOnset(0.5, 0.1, 200 + (i * 0.1)) };
got = l.liveOnsets(nil, 1000);
~tEq.("the ring keeps the last 64, oldest first", [l.liveOnsetCount, got.size, got.first[0], got.last[0]],
    [64, 64, 200 + (36 * 0.1), 200 + (99 * 0.1)]);
// A wet analysis input (no tap: the processed input) hears a note one round
// trip late.
~tPut.(l, \analysisChannel, nil);
~tPut.(l, \latencyMs, 30);
l.prMonitorOnset(0.5, 0.1, 300.0);
~tNear.("on the processed input a hit is placed one round trip earlier", l.lastLiveOnset(301)[0], 299.97, 1e-9);
}.value;

// ---- a starved analysis tap ------------------------------------------------------
{
var l = ~tLooper.(), said = List.new, t, scripts = Looper.repoRoot +/+ "scripts";
~tPut.(l, \inChannel, 0);
~tPut.(l, \analysisChannel, 2);
SimpleController(l).put(\tapStarved, { |obj, what, gap| said.add(gap) });
l.prCheckTap([0.001, 0.5]);
~tEq.("a tap 54 dB under the input: kept and said", [l.tapStarvedGap.round, said.asArray.collect(_.round)], [54, [54]]);
l.prCheckTap([0.2, 0.5]);
~tEq.("a tap that heard the take: none, and said so", [l.tapStarvedGap, said.last], [nil, nil]);
~tPut.(l, \analysisChannel, nil);
l.prCheckTap([0.001, 0.5]);
~tEq.("no tap (the analysis on the input itself): nothing to starve", l.tapStarvedGap, nil);
~tPut.(l, \analysisChannel, 2);
l.prCheckTap([0.001, 0.5]);
l.clear;
~tEq.("a clear forgets it", l.tapStarvedGap, nil);

// The take's hint says it, in the record colour, until the next take.
if(~statusTake.isNil) { (scripts +/+ "gui-status.scd").load };
l.prCheckTap([0.001, 0.5]);
~tPut.(l, \state, \playing);
~tPut.(l, \lastResult, (numerator: 7, denominator: 8, tau: 0.25, sub: 1, k: 2, n: 14, loopDur: 3.5, bpm: 120));
t = ~statusTake.(l);
~tEq.("the take's hint says the tap was starved, and by how much",
    [t[\starved], t[\hint].contains("54 dB under the input")], [true, true]);
l.prCheckTap([0.2, 0.5]);
~tEq.("...and nothing once a take was heard", ~statusTake.(l)[\starved], nil);
}.value;
