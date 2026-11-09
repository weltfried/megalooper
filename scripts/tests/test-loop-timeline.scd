// The loop's time (LoopTimeline, the Looper's own state until 2026-11-09):
// the boundaries counted from the anchor at speed 1 and at half-time, the
// position in the loop, and the arms: one per key, replaced by arming again,
// taken back by cancel (safe from inside the arm), a token that says whether
// work begun for an arm still belongs to it, and cancelAll and forget for
// free and Cmd-period. The arms' routines are stepped by hand: `.next` runs
// one synchronously, each wait just yielding its delta.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-loop-timeline");

{
var period = 2.0, tl = LoopTimeline({ period }), now, r, r2, got, token, t2, x, y;
// Thread:isPlaying is true only while a routine waits: a routine scheduled
// and not yet run is not "playing" either. Stopped is the state stop leaves.
var dead = Routine { 1.wait }, stopped;
dead.stop;
stopped = { |rt| rt.state == dead.state };

// ---- the loop's time ---------------------------------------------------------
~tEq.("no anchor: the next boundary is a loop from now", tl.nextBoundaryAt(50.0), 52.0);
tl.restart(100.0);
~tEq.("the anchor is loopStartTime", tl.loopStartTime, 100.0);
~tEq.("the next boundary counts from it", [tl.nextBoundaryAt(101.5), tl.nextBoundaryAt(103.9)], [102.0, 104.0]);
~tEq.("...ON a boundary, the one after (a landing never goes on the boundary it is on)", tl.nextBoundaryAt(102.0), 104.0);
~tEq.("...before the anchor, the anchor itself", tl.nextBoundaryAt(99.0), 100.0);
~tNear.("the position in the loop, from the anchor", tl.positionAt(103.5), 1.5, 1e-9);
~tNear.("...of another length, as asked", tl.positionAt(103.5, 3.0), 0.5, 1e-9);
~tEq.("at speed 1 a pass is the loop and starts at the anchor", [tl.wallPeriod, tl.passStart], [2.0, 100.0]);
tl.speedFrom(0.5, 104.0, 104.0);
~tEq.("half-time: a pass is two loops, counted from where it landed",
    [tl.speed, tl.wallPeriod, tl.passStart, tl.speedChangedAt], [0.5, 4.0, 104.0, 104.0]);
~tEq.("...the next boundary is a half-speed pass's end", [tl.nextBoundaryAt(105.0), tl.nextBoundaryAt(109.0)], [108.0, 112.0]);
tl.speedFrom(1, 112.0, nil);
~tEq.("back to 1: the anchor's grid again", [tl.passStart, tl.nextBoundaryAt(112.5), tl.passOrigin], [100.0, 114.0, nil]);
period = 3.0;
~tEq.("the period is asked each time (a multiply moves it)", tl.nextBoundaryAt(101.0), 103.0);

// ---- an arm --------------------------------------------------------------------
now = SystemClock.seconds;
got = nil;
token = tl.armAt(\a, now + 0.5, { |t| got = t });
~tEq.("an arm is armed, at its time", [tl.isArmed(\a), tl.armedAt(\a), tl.armedKeys], [true, now + 0.5, [\a]]);
~tEq.("...its token is the key's latest", [token, tl.token(\a), tl.holds(\a, token)], [1, 1, true]);
r = tl.routine(\a);
~tNear.("...its routine waits for its time", r.next, 0.5, 1e-6);
~tEq.("...and nothing has run yet", got, nil);
r.next;
~tEq.("on its time fn runs, handed its token", got, token);
~tEq.("...and the arm is over", [tl.isArmed(\a), tl.routine(\a)], [false, nil]);
~tEq.("...its token still the key's (work it began may carry on)", tl.holds(\a, token), true);

got = nil;
tl.armAt(\a, now - 1, { got = \late });
tl.routine(\a).next;
~tEq.("an arm whose time has passed runs on its first step, with no wait", got, \late);

// ---- replaced, taken back --------------------------------------------------------
got = List.new;
token = tl.armAt(\b, now + 10, { got.add(1) });
r = tl.routine(\b);
t2 = tl.armAt(\b, now + 20, { got.add(2) });
r2 = tl.routine(\b);
~tEq.("arming a key again replaces the arm: the first routine stopped", [stopped.(r), stopped.(r2)], [true, false]);
~tEq.("...the first token no longer holds, the new one does", [tl.holds(\b, token), tl.holds(\b, t2)], [false, true]);
~tEq.("...one arm, at the new time", [tl.armedKeys, tl.armedAt(\b)], [[\b], now + 20]);
r.next;
~tEq.("...and the replaced arm runs nothing", got.asArray, []);
tl.cancel(\b);
~tEq.("cancel takes it back: routine stopped, not armed, its token gone",
    [stopped.(r2), tl.isArmed(\b), tl.holds(\b, t2)], [true, false, false]);
r2.next;
~tEq.("...and it runs nothing", got.asArray, []);
tl.cancel(\nothing);
~tEq.("cancelling a key with no arm is harmless", tl.isArmed(\nothing), false);

// ---- from inside an arm ------------------------------------------------------------
// Routine:stop on the current thread never returns (a break once muted the
// looper for good that way): an arm's own fn may cancel it and go on.
x = false;
tl.armAt(\c, now - 1, { tl.cancel(\c); x = true });
tl.routine(\c).next;
~tEq.("cancel from inside the arm's own fn returns, and fn runs on", [x, tl.isArmed(\c)], [true, false]);

x = nil;
tl.armAt(\c, now - 1, { x = tl.armAt(\c, now + 5, {}) });
r = tl.routine(\c);
r.next;
~tEq.("an arm that arms its key again leaves the new arm in force",
    [tl.isArmed(\c), tl.armedAt(\c), tl.holds(\c, x), tl.routine(\c) !== r], [true, now + 5, true, true]);
tl.cancel(\c);

// fn may wait; after a wait it asks whether it still holds.
x = nil; y = nil;
token = tl.armAt(\d, now - 1, { |t| x = \first; 0.5.wait; y = tl.holds(\d, t) });
r = tl.routine(\d);
r.next;
~tEq.("an arm's fn may wait in its routine", [x, y], [\first, nil]);
r.next;
~tEq.("...and, still the arm in force, goes on", y, true);
x = nil; y = nil;
token = tl.armAt(\d, now - 1, { |t| x = \first; 0.5.wait; y = tl.holds(\d, t) });
r = tl.routine(\d);
r.next;
token = tl.claim(\d);
~tEq.("taken back during the wait: the routine stopped", stopped.(r), true);

// ---- claim: work that arms later --------------------------------------------------
token = tl.claim(\e);
~tEq.("claim answers a token that holds until the key is claimed again",
    [tl.holds(\e, token), tl.isArmed(\e)], [true, false]);
t2 = tl.claim(\e);
~tEq.("...then the old token holds no more", [tl.holds(\e, token), tl.holds(\e, t2)], [false, true]);
~tEq.("a nil token never holds", tl.holds(\e, nil), false);
~tEq.("before any arm the token is 0, and holds (a landing begun by hand)", [tl.token(\fresh), tl.holds(\fresh, 0)], [0, true]);

// ---- all at once ------------------------------------------------------------------
tl.armAt(\f, now + 10, {});
tl.armAt(\g, now + 10, {});
r = tl.routine(\f); r2 = tl.routine(\g);
token = tl.token(\f);
tl.cancelAll;
~tEq.("cancelAll takes back every arm and stops their routines",
    [tl.armedKeys, stopped.(r), stopped.(r2), tl.holds(\f, token)], [[], true, true, false]);

tl.armAt(\f, now + 10, {});
r = tl.routine(\f);
token = tl.token(\f);
tl.forget;
~tEq.("forget (Cmd-period stopped the routines already) drops the arms and their tokens, stopping nothing",
    [tl.armedKeys, tl.holds(\f, token), stopped.(r)], [[], false, false]);
r.stop;
}.value;

// ---- the Looper's ----------------------------------------------------------------------
// Its old names answer the timeline's, and what it arms goes on it: a reading,
// a reverse and half-time each have an arm while pending and none after a stop.
{
var l = ~tLooper.(), eng, now = SystemClock.seconds, ld = 2.0, tok, tok2, r, rNew, bus, said, ctl;
~tPut.(l, \state, \playing);
~tPut.(l, \loopFrames, (ld * 48000).asInteger);
eng = ~tStubSynth.(l, \looperEngine);
~tPut.(l, \engineSynth, eng);
l.timeline.restart(now - 0.5);
~tEq.("the Looper's loopStartTime, speed and boundary are the timeline's",
    [l.loopStartTime, l.speed, l.passStart, l.prNextBoundaryAt(now)], [now - 0.5, 1, now - 0.5, now + 1.5]);
~tPut.(l, \speed, 0.5);
~tEq.("the harness reaches the moved variables (~tPut speed)", [l.speed, l.timeline.speed], [0.5, 0.5]);
~tPut.(l, \speed, 1);
l.reverse;
~tEq.("a reverse armed is an arm at its boundary", [l.timeline.isArmed(\reverse), l.timeline.armedAt(\reverse)], [true, l.reverseAt]);
l.toggleHalfTime;
~tEq.("half-time armed is an arm, half a second before its boundary (the cutter's respawn)",
    [l.timeline.isArmed(\halfTime), l.timeline.armedAt(\halfTime)], [true, l.halfTimeAt - 0.5]);
// Each landing asks whether it is still the arm in force: one begun for an
// arm that was taken back and armed again lands nothing.
// The reverse and half-time armed above: taken back and armed again.
tok = l.timeline.token(\reverse);
l.reverse;
l.reverse;
tok2 = l.timeline.token(\reverse);
~tEq.("(the reverse armed again: a new token)", [l.reverseArmed, tok2 > tok], [true, true]);
l.prReverseLands(tok);
~tEq.("a reverse landing for an arm since replaced lands nothing", [l.reverseArmed, l.reverseFlag], [true, false]);
l.prReverseLands(tok2);
~tEq.("...the arm in force lands", [l.reverseArmed, l.reverseFlag], [false, true]);
tok = l.timeline.token(\halfTime);
l.toggleHalfTime;
l.toggleHalfTime;
~tEq.("(half-time armed again: a new token)", [l.halfTime, l.timeline.token(\halfTime) > tok], [\armed, true]);
l.prHalfTimeLands(tok);
~tEq.("a half-time landing for an arm since replaced lands nothing", [l.halfTime, l.speed], [\armed, 1]);
l.prHalfTimeLands(l.timeline.token(\halfTime));
~tEq.("...the arm in force lands", [l.halfTime, l.speed], [\on, 0.5]);
l.prResetHalfTime;
// A reading's landing waits in its arm for the boundary; taken back meanwhile
// (a re-arm or a cancel claims the key first), it lands nothing.
rNew = (numerator: 3, denominator: 4, tau: 0.5, sub: 1, k: 1, bpm: 120, loopDur: ld);
~tPut.(l, \pendingReading, (index: 1, result: rNew, at: SystemClock.seconds + 10, loops: 1, restart: false));
tok = l.timeline.token(\reading);
r = Routine { l.prLandReading(tok) };
r.next;
l.timeline.claim(\reading);
r.next;
~tEq.("a reading's landing whose arm was taken back during its wait lands nothing",
    [l.readingIndex, l.pendingReading.notNil], [0, true]);
// Landed by hand (as the tests and the gesture fuzz do), the landing still
// ends the arm that would have landed it.
~tPut.(l, \pendingReading, (index: 1, result: rNew, at: SystemClock.seconds - 0.01, loops: 1, restart: false));
l.timeline.armAt(\reading, SystemClock.seconds + 10, {});
tok = l.timeline.token(\reading);
Routine { l.prLandReading(tok) }.next;
~tEq.("a reading landed by hand ends its arm too", [l.pendingReading, l.readingIndex, l.timeline.isArmed(\reading)], [nil, 1, false]);
// A break waits for the engine's phase before it arms its end; a second stomp
// before the answer claims the break again, so the first answer arms nothing.
bus = Bus.control(~tGet.(l, \server), 1);
~tPut.(l, \phaseBus, bus);
said = List.new;
ctl = SimpleController(l).put(\breakEndsAt, { |o, w, v| said.add(v) });
l.fireBreak;
l.fireBreak;
thisProcess.recvOSCmessage(SystemClock.seconds, NetAddr("127.0.0.1", 57110), 57120, ['/c_set', bus.index, 0.5]);
~tEq.("two stomps, one answer to both: only the second break arms its end",
    [said.size, l.timeline.isArmed(\break)], [1, true]);
ctl.remove;
l.prCancelBreak;
l.prStartTransportAtPhase((downbeatPhase: 1.0, numerator: 4, denominator: 4, bpm: 120, k: 1, onsetCount: 8));
~tNear.("an overdub's detection arms the transport's start for the loop's next downbeat phase",
    l.timeline.armedAt(\overdubTransport) ? 0, now + 0.5, 0.01);
l.stopPlayback;
~tEq.("a stop leaves nothing armed", l.timeline.armedKeys, []);
try { l.free } { |err| ~tFail.("free threw", err.errorString) };
}.value;

// ---- the drift estimate (LoopDrift) -------------------------------------------------
// The timeline's, the drums' own until 2026-11-09: they send the probes and
// hand the answers here. A loop 3 ms late, probed: the answer its phase read
// would carry (A2K holds a block's first sample: 31.5 samples early).
{
var tl = LoopTimeline({ 2.0 }), drift = tl.drift, id, s16 = { 0.125 };
var late = { |t| (((t - 90.0) - 0.003) % 2.0) - (31.5 / 48000) };
~tEq.("the timeline has one drift estimate, from 0", [drift === tl.drift, drift.dHat], [true, 0]);
drift.from(90.0);
id = drift.sent(100.0, 90.0);
drift.answer(id, late.(100.0), 100.01, true, 90.0, 2.0, 48000, s16);
~tNear.("an answer moves it a quarter of the way", drift.dHat, 0.00075, 1e-9);
id = drift.sent(102.0, 90.0);
drift.reversed;
drift.reversed;
drift.answer(id, late.(102.0), 102.01, true, 90.0, 2.0, 48000, s16);
~tNear.("one sent across a reverse, even one there and back since, is thrown away", drift.dHat, 0.00075, 1e-9);
id = drift.sent(104.0, 90.0);
drift.speedChanged;
drift.answer(id, late.(104.0), 104.01, true, 90.0, 2.0, 48000, s16);
~tNear.("...and one sent across a speed change", drift.dHat, 0.00075, 1e-9);
id = drift.sent(106.0, 90.0);
drift.answer(id, late.(106.0), 106.01, false, 90.0, 2.0, 48000, s16);
~tNear.("...and one while the loop's model does not hold", drift.dHat, 0.00075, 1e-9);
id = drift.sent(108.0, 90.0);
drift.answer(id, late.(108.0), 108.04, true, 90.0, 2.0, 48000, s16);
~tNear.("...and one more than 30 ms late", drift.dHat, 0.00075, 1e-9);
drift.answer(id, late.(108.0), 108.01, true, 90.0, 2.0, 48000, s16);
~tNear.("...and an answer for no probe (or one answered already)", drift.dHat, 0.00075, 1e-9);
drift.sent(110.0, 90.0);
drift.sent(130.0, 90.0);
drift.prune(120.0);
~tEq.("probes that never came back are forgotten, those still due kept", drift.instVarAt(\probes).size, 1);
~tEq.("a new engine (the anchor moved): from 0, once", [drift.engine(95.0), drift.dHat, drift.engine(95.0)], [true, 0, false]);
id = drift.sent(95.02, 95.0);
drift.answer(id, late.(95.02), 95.03, true, 95.0, 2.0, 48000, s16);
~tEq.("...an answer within 50 ms of its start is thrown away (its own start lag)", drift.dHat, 0);
}.value;
