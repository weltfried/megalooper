// The loop's notes (roadmap item 24, docs/dev/sampler.md): the Looper's part
// that cuts the loop into slices at its attacks (LooperSlices) and the
// controls that play them shorter or backwards. On the server-free fixture:
// the table a take's analysis sends the engine, what a multiply, an undo, a
// clear, a new take and a reading do to it, a search overtaken, the note
// length and shape, and notes backwards armed for the boundary as Reverse
// is, with what it refuses and what drops it. How the engine plays the table
// is the server's, checked offline by scripts/sa/nrt-slices.scd.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-notes");

{
var ld = 3.5, sr = 48000, n = (ld * sr).asInteger, l, eng, refused, heard, now, fresh, r78, p, held, sent, tableOf, lastTable;
var attacks = [0.2, 0.7, 1.3, 1.9, 2.6, 3.1].collect { |s| (s * sr).asInteger };
var loop = FloatArray.newClear(n * 2), pending, snap, b, notes;
// The loop: a pluck at each attack (over a quiet floor), stereo, interleaved.
thisThread.randSeed = 27;
n.do { |f| var x = 0.0003.rand2; loop[f * 2] = x; loop[(f * 2) + 1] = x };
attacks.do { |a| (0.3 * sr).asInteger.do { |i|
    var x = sin(2pi * 196 * i / sr) * (i / 48).min(1) * exp(i.neg / (0.08 * sr));
    loop[(a + i) * 2] = loop[(a + i) * 2] + x; loop[((a + i) * 2) + 1] = loop[((a + i) * 2) + 1] + x } };
r78 = (numerator: 7, denominator: 8, tau: 0.25, sub: 1, k: 2, loopDur: ld, bpm: 120, n: 14, phase: 0);
fresh = {
    var x = ~tLooper.(), part;
    ~tPut.(x, \state, \playing);
    ~tPut.(x, \loopFrames, n);
    ~tPut.(x, \lastResult, r78);
    ~tPut.(x, \buffer, (bufnum: 5, numFrames: n * 4));
    ~tPut.(x, \undoBuffer, (bufnum: 6, numFrames: n * 4));
    eng = ~tStubSynth.(x, \looperEngine);
    ~tPut.(x, \engineSynth, eng);
    part = x.slicesPart;
    part.instVarPut(\tableBuf, (bufnum: 77));
    // The audio comes at once, the search never waits; `pending` holds a
    // read back for the test that overtakes one.
    part.reader = { |buf, from, frames, action| if(pending == \hold) { pending = action } { action.value(loop.copyRange(from * 2, ((from + frames) * 2) - 1)) } };
    part.runner = { |fn| fn.value };
    part.slice = inf;
    refused = List.new;
    heard = List.new;
    SimpleController(x).put(\refused, { |o, w, what, why| refused.add([what, why]) })
        .put(\notesBackwards, { |o, w, v| heard.add([\notesBackwards, v]) })
        .put(\notesBackwardsArmed, { |o, w, v| heard.add([\notesBackwardsArmed, v]) })
        .put(\noteLength, { |o, w, v| heard.add([\noteLength, v]) })
        .put(\noteShape, { |o, w, v| heard.add([\noteShape, v]) })
        .put(\slices, { |o, w, v| heard.add([\slices, v]) });
    x
};
// The last table written to buffer 77 ([\b_setn, 77, 0, size, values...]),
// cut to the table (the starts and their four repeats), or nil.
lastTable = { |x|
    var m = ~tGet.(x, \server)[\bundles].collect(_[1]).flatten(1).select { |m| m[0] == \b_setn and: { m[1] == 77 } }.last;
    m !? { m.copyToEnd(4).reject { |v| v == 1e9 } }
};
// The onset notes' pattern of a take with these attacks, reported 15 ms late.
notes = { |x| x.prBuildOnsetPattern(attacks.collect { |a| [(a / sr) + 0.015, 0.5] }, ld) };

// ---- a take's slices ----------------------------------------------------------------
l = fresh.();
notes.(l);
~tEq.("the onset pattern as frames from the loop's start", l.prOnsetFrames, attacks.collect { |a| a + 720 });
l.slicesPart.build(l.prOnsetFrames);
p = lastTable.(l);
~tEq.("a take's analysis: a slice a note", l.sliceCount, attacks.size);
~tAssert.("...each starting where its attack does, not where it was reported (at most 8 ms before, never after)",
    p.notNil and: { p.copyRange(2, p.size - 3).every { |s, i| ((attacks[i] - s) >= 0) and: { (attacks[i] - s) <= (sr * 0.008) } } },
    p.asString);
~tEq.("...the table and slicesOn 1 go to the server in one bundle, with the beat (0.25 s) in frames",
    ~tGet.(l, \server)[\bundles].last[1].collect { |m| m[0] }, [\b_setn, 15]);
~tEq.("...the engine on", [~tLastSet.(l, eng, \slicesOn), ~tLastSet.(l, eng, \tauFrames)], [1, 12000.0]);
~tEq.("...and said", heard.asArray.last, [\slices, attacks.size]);
~tEq.("a new engine starts with them", l.slicesPart.engineArgs, [\sliceBuf, 77, \slicesOn, 1, \tauFrames, 12000.0]);

// ---- what the loop's changes do to them ---------------------------------------------
~tPut.(l, \loopFrames, n * 2);
l.slicesPart.sync;
~tEq.("a loop twice as long (a multiply): the slices again in its second pass", l.sliceCount, attacks.size * 2);
~tEq.("...at the same places a pass later", lastTable.(l).copyRange(2, lastTable.(l).size - 3).keep(-1).first,
    p.copyRange(2, p.size - 3).last + n);
~tPut.(l, \loopFrames, (n * 0.6).asInteger);
l.slicesPart.sync;
~tEq.("a loop of another length: the slices that fit in it", l.sliceCount,
    p.copyRange(2, p.size - 3).count { |s| s < (n * 0.6).asInteger });
~tPut.(l, \loopFrames, n);
l.slicesPart.sync;

snap = l.slicesPart.takeState;
l.slicesPart.clear;
~tEq.("cleared: no slices, the engine told", [l.sliceCount, ~tLastSet.(l, eng, \slicesOn)], [0, 0]);
~tEq.("a new engine starts without them", l.slicesPart.engineArgs[3], 0);
l.slicesPart.restoreTake(snap);
~tEq.("an undo brings back its snapshot's", [l.sliceCount, ~tLastSet.(l, eng, \slicesOn)], [attacks.size, 1]);

~tPut.(l, \lastResult, (tau: 0.2, sub: 2));
l.prSetResult((tau: 0.2, sub: 2));
~tEq.("a new reading: its beat to the engine (0.2 s x 2)", ~tLastSet.(l, eng, \tauFrames), 0.4 * sr);

// A search overtaken: its audio still on its way when a new take begins.
l = fresh.();
notes.(l);
pending = \hold;
l.slicesPart.build(l.prOnsetFrames);
l.slicesPart.clear;
pending.value(loop.copyRange(0, (n * 2) - 1));
pending = nil;
~tEq.("a search whose loop is gone before it is done: dropped", l.sliceCount, 0);

// The next loop: the old starts kept (repeated) until its own are searched.
l = fresh.();
notes.(l);
l.slicesPart.build(l.prOnsetFrames);
pending = \hold;
~tPut.(l, \loopFrames, n * 2);
l.slicesPart.rebuild;
~tEq.("the next loop over it, twice as long: the old slices again in each pass while its own are searched",
    l.sliceCount, attacks.size * 2);
pending = nil;

// An overdub's reading: the slices in force hold until its own are in.
l = fresh.();
notes.(l);
l.slicesPart.build(l.prOnsetFrames);
pending = \hold;
l.slicesPart.build(l.prOnsetFrames, false);
~tEq.("searched again without dropping (an overdub's reading): the slices in force hold meanwhile",
    l.sliceCount, attacks.size);
pending = nil;
~tEq.("no onsets: nothing searched, nothing in force", { var x = fresh.(); x.slicesPart.build([]); x.sliceCount }.value, 0);
// The Looper's own paths.
l = fresh.();
notes.(l);
l.slicesPart.build(l.prOnsetFrames);
l.prTakeBegins(false);
~tEq.("a new take begins (Looper.prTakeBegins): its slices come with its analysis, the old ones gone",
    [l.sliceCount, ~tLastSet.(l, eng, \slicesOn)], [0, 0]);
~tEq.("...the undo snapshot it took keeps them", ~tGet.(l, \undoState)[\sliceStarts].size, attacks.size);
l = fresh.();
notes.(l);
l.slicesPart.build(l.prOnsetFrames);
l.clear;
~tEq.("Clear (Looper.clear): gone", l.sliceCount, 0);

// ---- the note length and shape ----------------------------------------------------
l = fresh.();
l.noteLength = 0.6;
~tEq.("the note length: to the engine and said", [~tLastSet.(l, eng, \noteLen), heard.asArray.last], [0.6, [\noteLength, 0.6]]);
l.noteLength = 3;
~tEq.("...held to 0..1", [l.noteLength, ~tLastSet.(l, eng, \noteLen)], [1, 1]);
l.noteShape = \decay;
~tEq.("the shape: decay is 1 to the engine, said", [l.noteShape, ~tLastSet.(l, eng, \noteShape), heard.asArray.last],
    [\decay, 1, [\noteShape, \decay]]);
l.noteShape = \anything;
~tEq.("...anything else is the gate, 0", [l.noteShape, ~tLastSet.(l, eng, \noteShape)], [\gate, 0]);

// ---- notes backwards, armed for the boundary -------------------------------------
l = fresh.();
now = SystemClock.seconds;
~tPut.(l, \loopStartTime, now - 1.0);
l.toggleNotesBackwards;
~tEq.("a press while the loop plays arms it for the next boundary, the notes still forwards",
    [l.notesBackwardsArmed, l.notesBackwards, (l.notesBackwardsAt - (now + 2.5)).abs < 0.01], [true, false, true]);
~tEq.("...the engine sent it (it takes it on the pass's first sample)", ~tLastSet.(l, eng, \noteRev), 1);
~tEq.("...said, and the count counts in to it",
    [heard.asArray, l.upcoming(now).collect { |e| e[\what] }], [[[\notesBackwardsArmed, true]], [\notesBackwards]]);
l.toggleNotesBackwards;
~tEq.("pressed again before the boundary: taken back, the engine sent forwards",
    [l.notesBackwardsArmed, l.notesBackwards, ~tLastSet.(l, eng, \noteRev), l.upcoming(now)], [false, false, 0, []]);
l.toggleNotesBackwards;
l.timeline.routine(\notesBackwards) !? { |rt| rt.stop };
l.prNotesBackwardsLands(l.timeline.token(\notesBackwards));
~tEq.("landing: backwards, said", [l.notesBackwards, l.notesBackwardsArmed, heard.asArray.last], [true, false, [\notesBackwards, true]]);
l.toggleNotesBackwards;
~tEq.("...and the next press arms forwards", [l.notesBackwardsArmed, l.upcoming(now).collect { |e| e[\what] }],
    [true, [\notesForwards]]);

// Within the margin: the boundary after; too close to take back.
l = fresh.();
now = SystemClock.seconds;
~tPut.(l, \loopStartTime, (now + 0.03) - ld);
l.toggleNotesBackwards;
b = ~tGet.(l, \server)[\bundles].select { |e| e[1].any { |m| (m[0] == 15) and: { m[2] == \noteRev } } };
~tEq.("a press 30 ms before a boundary arms the one after, the engine sent it timed past the near one",
    [(l.notesBackwardsAt - (now + 0.03 + ld)).abs < 0.01, b.size, b.last !? { |x| (x[0] - (now + 0.04)).abs < 0.005 }],
    [true, 1, true]);
~tPut.(l, \notesBackwardsAt, SystemClock.seconds + 0.02);
l.toggleNotesBackwards;
~tEq.("a press within 50 ms of the landing is refused, saying why",
    [refused.asArray, l.notesBackwardsArmed], [[[\notesBackwards, "the notes turn now"]], true]);

// With no loop playing: at once.
l = fresh.();
~tPut.(l, \state, \stopped);
~tPut.(l, \engineSynth, nil);
l.toggleNotesBackwards;
~tEq.("with no loop playing a press turns them at once", [l.notesBackwards, l.notesBackwardsArmed, heard.asArray],
    [true, false, [[\notesBackwards, true]]]);

// An overdub against it, and it against an overdub.
l = fresh.();
now = SystemClock.seconds;
~tPut.(l, \loopStartTime, now - 1.0);
l.toggleNotesBackwards;
l.startOverdub;
~tEq.("armed: an overdub is refused, saying why", refused.asArray.last,
    [\trigger, "notes backwards: turn them forwards before an overdub"]);
l = fresh.();
~tPut.(l, \state, \overdubbing);
l.toggleNotesBackwards;
~tEq.("while overdubbing a press is refused", [refused.asArray.last, l.notesBackwardsArmed], [[\notesBackwards, "end the overdub first"], false]);

// What drops the arm.
l = fresh.();
now = SystemClock.seconds;
~tPut.(l, \loopStartTime, now - 1.0);
l.toggleNotesBackwards;
l.stopPlayback;
~tEq.("stop drops an arm, the notes as they were", [l.notesBackwardsArmed, l.notesBackwards, l.notesBackwardsAt], [false, false, nil]);
l = fresh.();
now = SystemClock.seconds;
~tPut.(l, \loopStartTime, now - 1.0);
l.toggleNotesBackwards;
l.prResetNotesBackwards;
~tEq.("a new engine drops it too, saying so", [l.notesBackwardsArmed, heard.asArray.last], [false, [\notesBackwardsArmed, false]]);
}.value;
