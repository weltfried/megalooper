// Breaks: drop the looper out for a bar or two, resume exactly in phase.
//
// No server here, so what the gate SOUNDS like is untestable — masterSynth is
// nil in the fixture and every set on it is nil-guarded. What is testable is
// the part that actually bites in performance: how long a break lasts, when it
// refuses, and that it can never strand the master gate at 0.
//
// That last one is the reason this file exists. A break left counting down
// across a stop would leave breakAmp muted, and the NEXT loop would play into
// silence with nothing on screen explaining why — a fault that would look like
// broken audio routing on stage.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-break");

{
// A playing looper with a 7/8 take: tau 0.125, sub 2, so a beat is 0.25 s and a
// bar is 1.75 s. Two bars of loop => 3.5 s at 48 k.
var playing = {
    var l = ~tLooper.();   // already carries the stub server (48 k)
    ~tPut.(l, \state, \playing);
    ~tPut.(l, \loopFrames, (3.5 * 48000).asInteger);
    ~tPut.(l, \lastResult, (numerator: 7, denominator: 8, tau: 0.125, sub: 2, k: 2,
        downbeatOffset: 0));
    ~tPut.(l, \breakLoops, 1);
    l
};

// ---- how long a break lasts -------------------------------------------------
// The unit is LOOP PASSES, and the resume always lands on a loop boundary. The
// pass the break is struck in COUNTS as the first one, so the duration is
// "whatever is left of this pass" plus N - 1 whole passes, and the default (1)
// comes back on the NEXT loop downbeat. A fixed bar count — what this did first
// — resumed wherever it happened to land, which put the loop back mid-phrase;
// counting N whole passes ON TOP of the remainder — what it did second — came
// back a whole pass later than the ear expected.
{
    var dur = { |phase, loops = 1, reversed = false|
        Looper.prBreakDuration(phase, 3.5, loops, reversed) };

    // Struck right at a downbeat: the whole pass is still to come, and the next
    // boundary is the end of it.
    ~tNear.("struck at the downbeat: the rest of this pass, which is all of it",
        dur.(0), 3.5, 1e-9);
    // Struck just before the boundary: almost nothing is left of this pass, so
    // almost no hole. That is the honest reading of "the next downbeat".
    ~tNear.("struck just before the boundary: barely any hole at all",
        dur.(3.49), 0.01, 1e-9);
    ~tNear.("struck half way: what is left of the pass",
        dur.(1.75), 1.75, 1e-9);
    ~tNear.("two loops adds exactly one more pass", dur.(1.75, 2), 5.25, 1e-9);

    // The guarantee the feature rests on.
    (0, 0.1 .. 3.4).do { |phase|
        var d = dur.(phase);
        // Parenthesised deliberately: sclang binary operators are strictly
        // left to right with NO precedence, so the subtraction has to be bracketed
        // before `.abs` or it would compare, then subtract from a Boolean.
        if((d - (3.5 - phase)).abs > 1e-9) {
            ~tFail.("a one-loop break is exactly the distance to the next downbeat",
                "phase " ++ phase ++ " -> " ++ d);
        };
    };
    ~tPass.("a one-loop break always ends on the very next loop downbeat");

    // Backwards the playhead runs loopDur -> 0 and wraps, so the distance to the
    // boundary IS the phase rather than what is left after it.
    ~tNear.("reversed: the phase itself is what remains", dur.(1.0, 1, true), 1.0, 1e-9);
    ~tNear.("reversed at 0 is the boundary itself",       dur.(0.0, 1, true), 0.0, 1e-9);

    // A phase that could not be read must err long, never landing the resume in
    // the middle of a pass.
    ~tNear.("an unreadable phase assumes a whole pass remains",
        dur.(nil), 3.5, 1e-9);
    ~tNear.("no loop length means no break at all",
        Looper.prBreakDuration(0, 0, 1), 0, 1e-9);
    ~tNear.("a nil loop length means no break at all",
        Looper.prBreakDuration(0, nil, 1), 0, 1e-9);
    // Overshoot from a stale read must not produce a negative remainder — it
    // clips to nothing left, i.e. the boundary is here.
    ~tNear.("a phase past the end clips rather than going negative",
        dur.(99), 0, 1e-9);
    ~tNear.("...and with more loops asked for, only the whole passes remain",
        dur.(99, 3), 7.0, 1e-9);
}.value;

// ---- breakLoops is clipped, not trusted -------------------------------------
{
    var l = playing.();
    l.breakLoops = 0;   ~tEq.("breakLoops clips up to 1",   l.breakLoops, 1);
    l.breakLoops = 99;  ~tEq.("breakLoops clips down to 8", l.breakLoops, 8);
    l.breakLoops = 2;   ~tEq.("breakLoops accepts 2",       l.breakLoops, 2);
}.value;

// ---- when a break refuses ---------------------------------------------------
// Refusing has to leave onBreak false, or the header would light a BREAK lamp
// for a break that never happened — the same honesty rule the state label follows.
{
    var l = playing.();
    ~tPut.(l, \state, \empty);
    l.fireBreak;
    ~tAssert.("a break with nothing playing is refused", l.onBreak.not);
}.value;

{
    var l = playing.();
    ~tPut.(l, \state, \stopped);
    l.fireBreak;
    ~tAssert.("a break while stopped is refused", l.onBreak.not);
}.value;

{
    var l = playing.();
    ~tPut.(l, \loopFrames, 0);
    ~tPut.(l, \lastResult, nil);
    l.fireBreak;
    ~tAssert.("a break with no loop to break out of is refused", l.onBreak.not);
}.value;

{
    // The gate shuts synchronously on the stomp; only the RESUME waits on the
    // playhead read. With no engine in the fixture queryLoopPhase answers nil
    // immediately, which exercises the unreadable-phase path end to end.
    var l = playing.();
    l.fireBreak;
    ~tAssert.("the hole opens on the stomp, not on the callback", l.onBreak);
    ~tAssert.("and a resume time is published for the countdown",
        l.breakEndsAt.notNil, l.breakEndsAt.asString);
    l.endBreak;
    ~tAssert.("which is cleared when the break ends", l.breakEndsAt.isNil);
}.value;

// ---- the gate always comes back ---------------------------------------------
{
    var l = playing.();
    l.breakLoops = 8;        // long enough that the resume cannot fire mid-test
    l.fireBreak;
    ~tAssert.("firing a break sets onBreak", l.onBreak);
    l.endBreak;
    ~tAssert.("endBreak clears onBreak", l.onBreak.not);
}.value;

{
    // The one that would strand a muted gate on stage.
    var l = playing.();
    l.breakLoops = 8;
    l.fireBreak;
    ~tAssert.("break is armed before the stop", l.onBreak);
    l.stopPlayback;
    ~tAssert.("stopPlayback cancels an armed break", l.onBreak.not);
}.value;

{
    // clear routes through stopPlayback, so it must inherit the same guarantee.
    var l = playing.();
    l.breakLoops = 8;
    l.fireBreak;
    l.clear;
    ~tAssert.("clear cancels an armed break", l.onBreak.not);
}.value;

{
    // Re-firing restarts the count rather than stacking a second resume that
    // would unmute early, halfway through the new break.
    var l = playing.();
    l.breakLoops = 8;
    l.fireBreak;
    l.fireBreak;
    ~tAssert.("re-firing mid-break leaves exactly one break armed", l.onBreak);
    l.endBreak;
    ~tAssert.("and one endBreak is enough to clear it", l.onBreak.not);
}.value;

// ---- the resume actually runs -----------------------------------------------
// REGRESSION. On the rig, a break muted the looper permanently: the hole opened
// and the loop never came back.
//
// endBreak is reached from INSIDE breakRoutine, and its first act was to stop
// that routine. Routine:stop on the current thread is `nil.alwaysYield` — it
// does not return — so endBreak died on its first line and never reached the
// line that reopens the gate.
//
// Every assertion above calls endBreak DIRECTLY, which runs it on a different
// thread, where stop behaves normally and everything passes. That is precisely
// why the bug survived them, and why this one has to drive it through a
// routine. `.next` runs a routine synchronously with thisThread set to it, so
// the real path is reproduced with no waiting.
//
// `reachedEnd` is the assertion that matters: masterSynth is nil in the fixture
// so the gate itself is unobservable, but reaching the end of the routine proves
// execution passed the line that sets breakAmp back to 1.
{
    var l = playing.();
    var reachedEnd = false;
    var r;
    ~tPut.(l, \onBreak, true);
    r = Routine { l.endBreak; reachedEnd = true };
    ~tPut.(l, \breakRoutine, r);
    r.next;
    ~tAssert.("endBreak survives being called from inside its own routine",
        reachedEnd);
    ~tAssert.("so a timed break actually ends", l.onBreak.not);
}.value;

{
    // Same hazard on the cancel path, which stopPlayback reaches.
    var l = playing.();
    var reachedEnd = false;
    var r;
    ~tPut.(l, \onBreak, true);
    r = Routine { l.prCancelBreak; reachedEnd = true };
    ~tPut.(l, \breakRoutine, r);
    r.next;
    ~tAssert.("prCancelBreak survives running inside its own routine", reachedEnd);
    ~tAssert.("and still clears the break", l.onBreak.not);
}.value;

// ---- the gate reopens as the downbeat reaches it ------------------------------
// The gate sits after the master's limiter, whose look-ahead puts what the
// engine plays at the gate 20 ms later (Looper.masterDelay). So endBreak opens
// it on a bundle stamped 20 ms on, as the downbeat gets there, rather than at
// once, when the last 20 ms of the pass before would still come through; the
// onset part and the \break notification go at once. The stomp shuts it at
// once. A stomp inside those 20 ms keeps it shut (its write goes in again just
// after the reopening), and a stop then opens it: the gate always ends as the
// last write left it. Each call runs at its own time, in a Routine that sets
// thisThread.seconds, as the break's own routine and a MIDI responder do.
{
    var l = playing.();
    var stub = ~tGet.(l, \server), syn = ~tStubSynth.(l, \looperMaster);
    var at = { |t, fn| Routine { thisThread.seconds = t; fn.value }.next };
    var gate = { ~tLastSet.(l, syn, \breakAmp) ? 1 };
    var gateBundles = { stub[\bundles].select { |b| b[1].any { |m| (m[0] == 15) and: { m[1] == syn.nodeID } } } };
    var seen = List.new, ctl, n;
    ~tPut.(l, \masterSynth, syn);
    ctl = SimpleController(l).put(\break, { |o, what, v| seen.add([thisThread.seconds, v]) });
    l.breakLoops = 8;
    at.(100.0, { l.fireBreak });
    ~tEq.("the stomp shuts the gate at once", [stub[\msgs].last, gate.()], [[15, syn.nodeID, \breakAmp, 0], 0]);
    at.(103.5, { l.endBreak });
    ~tNear.("the break's end opens it on a bundle 20 ms on, as the downbeat reaches it",
        gateBundles.().last !? { |b| b[0] }, 103.52, 1e-9);
    ~tEq.("...setting breakAmp to 1", gateBundles.().last !? { |b| b[1] }, [[15, syn.nodeID, \breakAmp, 1]]);
    ~tAssert.("...and not at once", stub[\msgs].every { |m| (m[0] != 15) or: { m[1] != syn.nodeID } or: { m[3] != 1 } });
    ~tEq.("...while \\break false goes at once", seen.last, [103.5, false]);
    ~tEq.("the 20 ms are the master Limiter's look-ahead, the drums' loopAudioDelay", Looper.masterDelay,
        MegaSADrums.loopAudioDelay);
    at.(103.51, { l.fireBreak });
    ~tEq.("a stomp inside those 20 ms keeps the gate shut", gate.(), 0);
    ~tAssert.("...its write sent again just after the reopening", gateBundles.().last !? { |b|
        (b[0] > 103.52) and: { b[0] < 103.5201 } and: { b[1] == [[15, syn.nodeID, \breakAmp, 0]] } } ? false);
    at.(103.515, { l.prCancelBreak });
    ~tEq.("...and a stop then opens it", gate.(), 1);
    n = gateBundles.().size;
    at.(110.0, { l.fireBreak });
    ~tEq.("a stomp once the reopening has been carried out is one write, at once",
        [gateBundles.().size, stub[\msgs].last, gate.()], [n, [15, syn.nodeID, \breakAmp, 0], 0]);
    at.(110.01, { l.prCancelBreak });
    ctl.remove;
}.value;

// ---- notifications ----------------------------------------------------------
{
    var l = playing.();
    var seen = List.new;
    var listener = SimpleController(l).put(\break, { |o, what, val| seen.add(val) });
    l.breakLoops = 8;
    l.fireBreak;
    l.endBreak;
    // As 1/0: ~tEqArray compares numerically, and subtracting booleans throws.
    ~tEqArray.("break fires changed(true) then changed(false)",
        seen.asArray.collect { |b| if(b) { 1 } { 0 } }, [1, 0]);
    // A cancel with no break armed must stay silent, or the lamp would flicker
    // on every stop.
    seen.clear;
    l.prCancelBreak;
    ~tEq.("cancelling when no break is armed notifies nothing", seen.size, 0);
    listener.remove;
}.value;

// ---- the rack-macro CC out to Live ------------------------------------------
// Live's rack carries two Rhythmic Steps devices on one macro, and that drum
// rack keeps playing through a break — it is fed by its own clips, not by the
// looper's onset notes. So the break has to SAY it is open: 0 swaps the pattern
// for the hole, 127 puts the original back with the loop.
//
// Worth a test rather than a stomp on the rig because the wiring is indirect —
// setup-model subscribes to \break, and nothing would fail loudly if that
// subscription were lost in a refactor; the rack would just stop following.
{
    var scripts = Looper.repoRoot +/+ "scripts";
    var sent = List.new;
    var l;
    // These define only, so loading them starts nothing: no MIDIClient, no
    // server, no window.
    (scripts +/+ "setup-midi.scd").load;
    (scripts +/+ "setup-model.scd").load;
    ~midiLog = false;              // the post window, not the send
    // An Event answers any selector by key lookup, so this is a whole MIDIOut
    // as far as one `control` call is concerned.
    ~midiOut = (control: { |self, chan, num, val| sent.add([chan, num, val]) });
    l = playing.();
    ~looper = l;
    ~wireLooperCallbacks.();

    l.breakLoops = 8;              // long enough that no resume fires mid-test
    l.fireBreak;
    ~tEqArray.("the hole opening sends macro CC 0",
        sent.asArray.last, [~pcCcChannel, ~breakMacroCc, 0]);
    l.endBreak;
    ~tEqArray.("the loop returning sends macro CC 127",
        sent.asArray.last, [~pcCcChannel, ~breakMacroCc, 127]);
    ~tEq.("exactly one CC per edge, nothing repeated", sent.size, 2);

    // A break cancelled by a stop or a clear is still a return, so the rack has
    // to be put back — otherwise stopping mid-break strands Live on the break
    // pattern for the rest of the set.
    sent.clear;
    l.fireBreak;
    l.prCancelBreak;
    ~tEqArray.("a cancelled break still hands the pattern back",
        sent.asArray, [[~pcCcChannel, ~breakMacroCc, 0],
            [~pcCcChannel, ~breakMacroCc, 127]]);

    ~breakController.remove;
    ~looper = nil; ~midiOut = nil;
}.value;

}.value;
