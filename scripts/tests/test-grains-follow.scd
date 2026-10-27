// The grains read what the engine reads (Looper.prGranularFollow; roadmap
// item 20, found on the way): the buffer, its start, the loop's length and
// the pulse, sent to the running grains wherever one of them changes without
// a new grains synth. Before, Record next loop's swap left the grains on the
// old buffer (which the next capture records into), multiply and undo on the
// old length, and a first take's analysis on a pulse of a quarter of the raw
// take.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-grains-follow");

{
// Buffers as one-key Events (test-onset-notes.scd's): undo and multiply
// only copy them, which does nothing here.
var buf = { |n| (bufnum: n, numFrames: 48000 * 60, copyData: { |self ... args| self }) };
var r78 = (numerator: 7, denominator: 8, tau: 0.25, sub: 1, k: 2, n: 14, loopDur: 3.5, bpm: 120);
var l, g, got;
var heard = { [\bufnum, \startFrame, \loopFrames, \tau].collect { |k| ~tLastSet.(l, g, k) } };
l = ~tLooper.();
~tPut.(l, \state, \playing);
~tPut.(l, \buffer, buf.(11));
~tPut.(l, \nextBuffer, buf.(12));
~tPut.(l, \undoBuffer, buf.(13));
~tPut.(l, \loopFrames, 168000);
~tPut.(l, \lastResult, r78);
g = ~tStubSynth.(l, \looperGranular);
~tPut.(l, \granularSynth, g);

l.multiply(2);
~tEq.("multiply: the grains read the loop twice as long, on its pulse", heard.(), [11, 0, 336000, 0.25]);
l.undo;
~tEq.("undo: the loop before it again", heard.(), [11, 0, 168000, 0.25]);

// Record next loop's swap, as finishNextLoopRecord makes it (it then spawns
// an engine, which a test cannot: spawnEngine ends in prGranularFollow).
~tPut.(l, \buffer, buf.(12));
~tPut.(l, \nextBuffer, buf.(11));
~tPut.(l, \loopFrames, 336000);
l.prGranularFollow;
~tEq.("the swap: the buffer the new loop was recorded into", heard.()[0..2], [12, 0, 336000]);

// A reading with another pulse, and half-time.
~tPut.(l, \lastResult, r78.copy.put(\tau, 0.5));
~tPut.(l, \speed, 0.5);
l.prGranularFollow;
~tEq.("the pulse: the reading's, twice as long at half-time", ~tLastSet.(l, g, \tau), 1.0);
~tPut.(l, \speed, 1);
~tPut.(l, \lastResult, nil);
l.prGranularFollow;
~tEq.("...a quarter of the loop with no reading", ~tLastSet.(l, g, \tau), 336000 / 48000 / 4);

// No grains, nothing sent.
~tPut.(l, \granularSynth, nil);
got = ~tGet.(l, \server)[\msgs].size;
l.prGranularFollow;
~tEq.("with the grains off nothing is sent", ~tGet.(l, \server)[\msgs].size, got);
}.value;

