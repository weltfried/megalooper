// The Looper's state guards (docs/dev/architecture.md, 3.4 and 5, step 5):
// one table of refusals (prRefusal) that the entry points with conditions
// ask, so two things that must not overlap refuse each other both ways; and
// the faults the review found where they didn't. On the harness's Looper (a
// stub server that records what it is sent): no server, no sound.
//   - an overdub (the trigger while playing) and a multiply while the next
//     loop is armed or recording: refused, where they broke the swap
//   - the swap to the next loop says the loop plays forwards again, where it
//     dropped a reverse without a word
//   - a cutter starting (waiting for its boundary) taken back by a stop, a
//     new take or free, where a stop during that wait was ignored
//   - free stops the half-time and reverse routines and frees the insert bus

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-looper-guards");

{
var l, said, heard, playing, r, ht, rv, bus, dead;
// What the looper said while `fn` ran: [what, args...] per notification.
heard = { |model, fn|
    var out = List.new;
    var f = { |obj, what ... args| out.add([what] ++ args) };
    model.addDependant(f);
    protect { fn.value } { model.removeDependant(f) };
    out.asArray
};
// A looper playing a one-second loop, its buffers objects on the stub (none
// allocated), the overdub analysis off so nothing listens for OSC.
playing = {
    var lp = ~tLooper.(), srv;
    srv = ~tGet.(lp, \server);
    ~tPut.(lp, \buffer, Buffer.new(srv, 96000, 1, 0));
    ~tPut.(lp, \undoBuffer, Buffer.new(srv, 96000, 1, 1));
    ~tPut.(lp, \nextBuffer, Buffer.new(srv, 96000, 1, 2));
    // The busses an engine is spawned with (the swap to the next loop spawns one).
    ~tPut.(lp, \outBus, Bus.audio(srv, 2));
    ~tPut.(lp, \phaseBus, Bus.control(srv, 1));
    ~tPut.(lp, \insertBus, Bus.control(srv, 1));
    ~tPut.(lp, \tapGainBus, Bus.control(srv, 1));
    ~tPut.(lp, \startFrame, 0);
    ~tPut.(lp, \loopFrames, 48000);
    ~tPut.(lp, \engineSynth, ~tStubSynth.(lp));
    ~tPut.(lp, \analyzeOverdubs, false);
    ~tPut.(lp, \state, \playing);
    lp
};
said = { |events, what| events.select { |x| x[0] == what } };

// ---- an overdub and a multiply against the next loop ---------------------------------
[\armed, \recording, \stopping].do { |rec|
    l = playing.();
    ~tPut.(l, \nextRecState, rec);
    r = heard.(l, { l.trigger });
    ~tEq.("the trigger while the next loop is " ++ rec ++ " is no overdub", l.state, \playing);
    ~tAssert.("...it is refused, and says why",
        said.(r, \refused).any { |x| x[2].asString.contains("Rec next loop") }, r.asString);
    r = heard.(l, { l.multiply });
    ~tEq.("a multiply while the next loop is " ++ rec ++ " leaves the loop as it was", ~tGet.(l, \loopFrames), 48000);
    ~tAssert.("...and is refused", said.(r, \refused).any { |x| x[1] == \multiply }, r.asString);
};
l = playing.();
~tPut.(l, \nextRecState, \idle);
l.trigger;
~tEq.("with no next loop the trigger overdubs, as it always did", l.state, \overdubbing);
l = playing.();
l.multiply;
~tEq.("...and a multiply doubles the loop", ~tGet.(l, \loopFrames), 96000);
l = playing.();
~tPut.(l, \state, \overdubbing);
r = heard.(l, { l.recordNextLoop });
~tAssert.("and Rec next loop still refuses an overdub's playing (the other way round)",
    said.(r, \refused).any { |x| x[1] == \recordNextLoop }, r.asString);
~tEq.("half-time's refusals answer through the same table", l.prHalfTimeRefusal, "end the overdub first");

// ---- the swap to the next loop says the direction ------------------------------------
l = playing.();
~tPut.(l, \nextRecState, \recording);
~tPut.(l, \nextRecReps, 2);
~tPut.(l, \reverseFlag, true);
r = heard.(l, { l.finishNextLoopRecord(0) });
~tEq.("the next loop swapped in plays forwards", l.reverseFlag, false);
~tAssert.("...and says so, for the window and the drums", said.(r, \reverse).any { |x| x[1] == false }, r.asString);
~tEq.("...the next loop is in, twice the length", [l.state, ~tGet.(l, \loopFrames)], [\playing, 96000]);
l = playing.();
~tPut.(l, \nextRecState, \recording);
~tPut.(l, \nextRecReps, 1);
r = heard.(l, { l.finishNextLoopRecord(0) });
~tAssert.("a swap that was forwards already says nothing of the direction", said.(r, \reverse).isEmpty, r.asString);
// The capture becomes the loop and the old loop the next capture's scratch
// (LooperChainRecorder hands its buffer over, Looper.prSwapInNextLoop answers
// the old one): kept the same, the next capture would write over the loop
// playing.
{
    var was, scratch;
    l = playing.();
    was = ~tGet.(l, \buffer); scratch = ~tGet.(l, \nextBuffer);
    ~tPut.(l, \nextRecState, \recording);
    ~tPut.(l, \nextRecReps, 1);
    l.finishNextLoopRecord(0);
    ~tEq.("the swap trades the buffers: the capture plays, the old loop is the next scratch, the state idle",
        [~tGet.(l, \buffer) === scratch, ~tGet.(l, \nextBuffer) === was, l.nextRecState], [true, true, \idle]);
}.value;

// ---- a cutter starting, taken back --------------------------------------------------
[[\stop, { |lp| lp.stopPlayback }], [\take, { |lp| lp.startRecord }]].do { |c|
    l = playing.();
    r = Routine { loop { 10.wait } }.play(SystemClock);
    ~tPut.(l, \bbcutEnableRoutine, r);
    ~tPut.(l, \bbcutEnabling, true);
    c[1].value(l);
    ~tEq.("a cutter starting is taken back by a " ++ c[0], [l.bbcutEnabling, r.isPlaying], [false, false]);
};

// ---- a reading armed for the loop as it was --------------------------------------------
// Taken back by a multiply and by the next loop's swap, as by a new take and an
// undo: it would land at the old length, mid-pass in the new loop.
[[\multiply, { |lp| lp.multiply }], [\swap, { |lp| ~tPut.(lp, \nextRecState, \recording);
    ~tPut.(lp, \nextRecReps, 2); lp.finishNextLoopRecord(0) }]].do { |c|
    l = playing.();
    ~tPut.(l, \pendingReading, (index: 1, at: SystemClock.seconds + 1, result: (loopDur: 1.0)));
    r = heard.(l, { c[1].value(l) });
    ~tEq.("a reading armed before a " ++ c[0] ++ " is taken back", l.pendingReading, nil);
    ~tAssert.("...and the window is told", said.(r, \reading).any { |x| x[1].isNil }, r.asString);
};

// ---- the result in force, said ----------------------------------------------------------
// Looper.prSetResult: every change of lastResult says \result (the window, the
// export fields), where only a new take's analysis reached anyone, through
// the onAnalysis slot that undo, clear and multiply never called.
l = playing.();
~tPut.(l, \lastResult, (k: 1, n: 4, bars: [4], loopDur: 1.0, numerator: 4, denominator: 4, tau: 0.25, sub: 1));
r = heard.(l, { l.multiply });
~tAssert.("a multiply says the result it scaled", said.(r, \result).any { |x| x[1] !? { |res| res[\k] == 2 } ? false },
    said.(r, \result).asString);
r = heard.(l, { l.undo });
~tAssert.("an undo says the result it brought back", said.(r, \result).any { |x| x[1] !? { |res| res[\k] == 1 } ? false },
    said.(r, \result).asString);
r = heard.(l, { l.clear });
~tEq.("a clear says there is none", said.(r, \result).collect { |x| x[1] }, [nil]);
~tEq.("...and the looper keeps none", l.lastResult, nil);

// ---- Cmd-period ----------------------------------------------------------------------
// It freed every node and stopped every routine: the looper forgets them,
// stops saying it plays, and stops answering ready, as MegaSA does.
l = playing.();
~tPut.(l, \ready, true);
~tPut.(l, \midiClockRoutine, Routine { });
r = heard.(l, { l.cmdPeriod });
~tEq.("after Cmd-period the loop is stopped, not playing", l.state, \stopped);
~tAssert.("...and says so", said.(r, \state).any { |x| x[1] == \stopped }, r.asString);
~tEq.("...no engine, no MIDI clock, not ready", [~tGet.(l, \engineSynth), l.midiClockRunning, l.ready], [nil, false, false]);
~tEq.("...and its buffer is kept", ~tGet.(l, \loopFrames), 48000);
r = heard.(l, { l.cmdPeriod });
~tEq.("a second Cmd-period says nothing more", r, []);
// The cutter running or starting is off after it (LooperCutter.forget).
l = playing.();
~tPut.(l, \ready, true);
~tPut.(l, \bbcut, true);
~tPut.(l, \bbcutEnabling, true);
r = heard.(l, { l.cmdPeriod });
~tEq.("after Cmd-period the cutter is off and not starting, and says so",
    [l.bbcut, l.bbcutEnabling, said.(r, \bbcut).any { |x| x[1] == false }], [false, false, true]);
l = ~tLooper.();
r = heard.(l, { l.cmdPeriod });
~tEq.("a looper never ready is left alone", [r, l.state], [[], \empty]);
l = playing.();
CmdPeriod.add(l);
l.free;
~tAssert.("free stops listening for Cmd-period", CmdPeriod.objects.includes(l).not);

// ---- what the Looper tells the cutter, and the cutter the engine -------------------------
// (LooperCutter, split out of the Looper on 2026-11-08.)
{
    var vol;
    l = playing.();
    ~tGet.(l, \bbcutVoices)[0].put(\amp, 0.8).put(\mixer, (volume_: { |self, x| vol = x }));
    ~tPut.(l, \dissolvePos, 0.2);
    l.prApplyMixes;
    ~tEq.("the arc sets each voice's level: its own times the cutter's mix", vol, 0.8 * l.prBBCutMix);
    ~tPut.(l, \bbcut, true);
    l.bbcutMode = \gate;
    ~tEq.("a mode change while cutting gates the dry loop at once (gate: muted)",
        ~tLastSet.(l, ~tGet.(l, \engineSynth), \gateMode), 1);
    l.bbcutMode = \insert;
    ~tEq.("...insert: ducked under the repetitions", ~tLastSet.(l, ~tGet.(l, \engineSynth), \gateMode), 2);
    ~tPut.(l, \bbcut, false);
}.value;

// ---- free ------------------------------------------------------------------------------
l = playing.();
l.timeline.armAt(\halfTime, SystemClock.seconds + 10, {});
l.timeline.armAt(\reverse, SystemClock.seconds + 10, {});
ht = l.timeline.routine(\halfTime);
rv = l.timeline.routine(\reverse);
r = Routine { loop { 10.wait } }.play(SystemClock);
bus = Bus.control(~tGet.(l, \server), 1);
~tPut.(l, \bbcutEnableRoutine, r);
~tPut.(l, \insertBus, bus);
// Thread:isPlaying answers only while a routine waits, which a routine
// scheduled but not yet run does not: the state stop leaves says it.
dead = Routine { 1.wait };
dead.stop;
~tEq.("(none of them stopped before free)", [ht, rv, r].collect { |x| x.state == dead.state }, [false, false, false]);
try { l.free } { |err| ~tFail.("free threw on the harness's looper", err.errorString) };
~tEq.("free stops the half-time and reverse arms and a cutter starting",
    [ht, rv, r].collect { |x| x.state == dead.state }, [true, true, true]);
~tEq.("...and frees the insert bus", bus.index, nil);
}.value;
