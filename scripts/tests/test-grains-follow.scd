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

// ---- following the chords (granularFollowChords, roadmap item 8) ------------------
{
var buf = { |n| (bufnum: n, numFrames: 48000 * 60, copyData: { |self ... args| self }) };
var segs = [(start: 0, root: 9, rootName: "A", scale: \minor), (start: 1.75, root: 2, rootName: "D", scale: \major)];
var r = (numerator: 7, denominator: 8, tau: 0.25, sub: 1, k: 2, n: 14, loopDur: 3.5, bpm: 120,
    chordSegments: segs, chordPeriod: 3.5);
var l, g, srv, setn, data, warnings, clean;
l = ~tLooper.();
~tPut.(l, \state, \playing);
~tPut.(l, \buffer, buf.(11));
~tPut.(l, \loopFrames, 168000);
~tPut.(l, \lastResult, r);
g = ~tStubSynth.(l, \looperGranular);
~tPut.(l, \granularSynth, g);
srv = ~tGet.(l, \server);
// The last /n_setn to the grains, as name -> values.
setn = {
    var m = srv[\msgs].select { |x| (x[0] == 16) and: { x[1] == g.nodeID } }.last, out = ();
    var i = 2;
    m !? { while { i < m.size } { out[m[i]] = m.copyRange(i + 2, i + 1 + m[i + 1]); i = i + 2 + m[i + 1] } };
    out
};
~tEq.("off by default: the grains as the loop sounds where they read", l.granularFollowChords, false);
l.prGranularFollow;
~tEq.("the grains are sent the take's chords: their period, the switch off",
    [~tLastSet.(l, g, \chordPeriod), ~tLastSet.(l, g, \follow)], [3.5, 0]);
~tEq.("...the starts and roots, the unused slots past any time",
    [setn.()[\chordStarts].keep(3), setn.()[\chordRoots].keep(3), setn.()[\chordStarts].size],
    [[0, 1.75, 1e9], [9, 2, 0], Looper.chordSlots]);
l.granularFollowChords = true;
~tEq.("switched on: the grains follow, and it is said", [~tLastSet.(l, g, \follow), l.granularFollowChords], [1, true]);
~tPut.(l, \lastResult, r.copy.put(\chordSegments, segs.keep(1)));
l.prGranularFollow;
~tEq.("a take of one chord has nothing to follow (period 0)", ~tLastSet.(l, g, \chordPeriod), 0);
~tPut.(l, \lastResult, r.copy.put(\chordPeriod, nil));
l.prGranularFollow;
~tEq.("...a reading without its period uses the loop's length", ~tLastSet.(l, g, \chordPeriod), 3.5);
~tEq.("a reading the analyser ranked carries the take's chords and their period",
    Looper.readingFor((candidates: [r], chordSegments: segs, chordPeriod: 3.5), 0, 3.5) !? { |x| [x[\chordSegments].size, x[\chordPeriod]] },
    [2, 3.5]);

// In a granular preset, by name; one from before it plays as it did.
data = l.granularPresetData("x");
~tEq.("a granular preset holds it", data[\followChords], true);
~tAssert.("...and its file says it", l.granularPresetString(data).contains("followChords: true"));
l.granularFollowChords = false;
~tEq.("...and puts it back", [l.applyGranularPreset(data), l.granularFollowChords], [true, true]);
warnings = List.new;
clean = l.prValidateGranularPreset(data.copy.put(\followChords, nil), warnings);
~tEq.("a preset from before it: off, said nothing", [clean !? { |c| c[\followChords] }, warnings.size], [false, 0]);
warnings = List.new;
clean = l.prValidateGranularPreset(data.copy.put(\followChords, 1), warnings);
~tEq.("...a value that is no switch: off, and said", [clean !? { |c| c[\followChords] }, warnings.any { |w| w.contains("followChords") }],
    [false, true]);
}.value;
