// Recording the set: the decisions, not the disk.
//
// DiskOut needs a server, so nothing here writes a file. What is testable — and
// what would actually cost a gig — is the language-side half: which files a
// session would open, when a start is refused and why, that the elapsed time
// stops when the recording does, and above all that a later analysis cannot
// relocate Live out from under an arrangement recording.
//
// That last one is the reason this file exists. MIDI Start jumps Live to its
// cue point. That is correct for the first take and destructive for every one
// after it while Live is recording, and the failure is silent at the time: you
// find out the set was overwritten when you open the project the next day.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-session-recorder");

{
// This run's own folder (~tTempPath): runs at the same time do not share it.
var dir = ~tTempPath.("megalooper-session-tests");

// ---- file naming ---------------------------------------------------------
// Pure, so it can be asked without a server. Both files carry the SAME stamp:
// they are two views of one set and are meant to be lined up against each
// other, which is impossible if their names disagree about when it started.
{
var paths = LooperSessionRecorder.pathsFor(dir, "260922_201500");
~tEq.("the master file is named for the set",
    paths[\master].basename, "260922_201500-master.wav");
~tEq.("the dry tap sits beside it under the same stamp",
    paths[\tap].basename, "260922_201500-tap.wav");
~tEq.("both land in the session directory",
    paths[\master].dirname, paths[\tap].dirname);
}.value;

// ---- refusals ------------------------------------------------------------
// Each one is a sentence rather than a boolean, because every one of them is
// something the player has to fix before the next set starts.
{
var rec = LooperSessionRecorder(nil, nil);
~tAssert.("no directory is refused, and says so",
    rec.prRefusal(0, 16).notNil, "got nil");
rec.dir = dir;
~tEq.("with a directory and both channels, nothing is refused",
    rec.prRefusal(0, 16), nil);
~tEq.("a rig with no session input still records the dry tap",
    rec.prRefusal(nil, 16), nil);
~tEq.("a rig with no analysis tap still records the master",
    rec.prRefusal(0, nil), nil);
~tAssert.("NEITHER channel is refused rather than opening an empty file",
    rec.prRefusal(nil, nil).notNil, "got nil");
}.value;

// ---- elapsed -------------------------------------------------------------
// It freezes on stop. A clock that keeps counting after the recording ended is
// not a readout, it is a lie about what is on disk.
{
var rec = LooperSessionRecorder(nil, dir);
~tEq.("elapsed is zero before anything has been recorded", rec.elapsed, 0);
rec.instVarPut(\startedAt, 100);
rec.instVarPut(\stoppedAt, 142.5);
~tNear.("a finished set reports its length", rec.elapsed, 42.5, 1e-9);
rec.instVarPut(\startedAt, SystemClock.seconds - 5);
rec.instVarPut(\stoppedAt, nil);
~tAssert.("a running set counts up",
    rec.elapsed >= 5, "got " ++ rec.elapsed);
}.value;

// ---- the looper's side ---------------------------------------------------
{
var l = ~tLooper.();
~tAssert.("a looper comes with a recorder", l.sessionRec.notNil, "nil");
~tEq.("...which is idle", l.sessionRecording, false);
~tEq.("...and reports no elapsed time", l.sessionElapsed, 0);
~tEq.("a rig with no sessionChannel says it cannot record the master",
    l.canRecordMaster, false);
l.sessionChannel = 0;
~tEq.("...and says it can once the profile names a pair",
    l.canRecordMaster, true);
l.sessionDir = dir;
~tEq.("the directory reaches the recorder", l.sessionRec.dir, dir);
// Live's arrangement record is a SEPARATE footswitch (PC 21), so nothing here
// may reach out to Live. Asserted as an absence: if this class grows a Live
// hook again, the two switches stop being independent and the second one starts
// lying about the first.
~tEq.("the recorder has no Live-side hook to arm",
    Looper.findRespondingMethodFor(\onSessionRecording_), nil);
}.value;

// ---- the transport guard -------------------------------------------------
// The one that costs a set. `startTempoClocks` must not send a second MIDI
// Start while a session is being recorded and the clock is already running.
{
var l = ~tLooper.();
var result = (numerator: 4, denominator: 4, tau: 0.5, sub: 1, k: 1,
    bpm: 120, loopDur: 2.0, downbeatOffset: 0);
// The guard is the MIDI clock's. The click would play Synth(\looperClick) on
// the default server, a real one at 127.0.0.1:57110 whenever megalooper runs
// beside the suite, from a routine nothing here would stop.
l.metronome = false;
// A clock is "already running" iff midiClockRoutine is not nil. Stand one up
// without playing it: the guard reads the slot, not the routine's state.
~tPut.(l, \midiClockRoutine, Routine {});
~tPut.(l, \midiOut, ());
~tCheck.("a later analysis does NOT restart the transport mid-recording", {
    var startedClock = false;
    // Stub startMidiClock by watching whether the routine slot is replaced —
    // the real one always assigns it. Keep the sentinel and compare identity.
    var sentinel = l.instVarAt(\midiClockRoutine);
    l.sessionRec.instVarPut(\recording, true);
    l.startTempoClocks(result);
    startedClock = l.instVarAt(\midiClockRoutine) !== sentinel;
    l.sessionRec.instVarPut(\recording, false);
    if(startedClock) {
        Error("the clock was restarted — Live would have jumped to 1.1.1 "
            "and overwritten the arrangement take").throw
    };
    startedClock
});
// ...and the FIRST start must still happen, or arming the recorder before the
// set would stop Live from ever running.
~tCheck.("with no clock yet, a recording does not block the first start", {
    var started;
    ~tPut.(l, \midiClockRoutine, nil);
    l.sessionRec.instVarPut(\recording, true);
    l.startTempoClocks(result);
    started = l.instVarAt(\midiClockRoutine).notNil;
    l.sessionRec.instVarPut(\recording, false);
    l.instVarAt(\midiClockRoutine) !? { |r| r.stop };
    if(started.not) {
        Error("the transport never started — a session recording armed before "
            "the first take would keep Live stopped for the whole set").throw
    };
    started
});
// And with nothing being recorded, a later analysis restarts as it always did.
~tCheck.("outside a session recording, a later analysis restarts as before", {
    var sentinel;
    ~tPut.(l, \midiClockRoutine, Routine {});
    sentinel = l.instVarAt(\midiClockRoutine);
    l.startTempoClocks(result);
    if(l.instVarAt(\midiClockRoutine) === sentinel) {
        Error("the clock was NOT restarted; the guard is firing when no "
            "session is being recorded").throw
    };
    l.instVarAt(\midiClockRoutine) !? { |r| r.stop };
    true
});
~tEq.("(no click was started, so nothing plays on a server after the suite)", l.instVarAt(\clickRoutine), nil);
}.value;
// ---- the event log: naming ------------------------------------------------
// The third file of a set. Same stamp, so it can never be matched to the wrong
// pair of WAVs.
{
var paths = LooperSessionRecorder.pathsFor(dir, "260928_183000");
~tEq.("the event log sits beside the WAVs under the same stamp",
    paths[\events].basename, "260928_183000-events.jsonl");
}.value;

// ---- the event log: JSON ----------------------------------------------------
// One writer, keys sorted, so equal events are equal lines; strings escaped;
// nil and non-finite numbers become null, the one token every reader accepts.
{
~tEq.("an event serialises with sorted keys",
    LooperSessionRecorder.json((b: 1, a: "x", c: [1, 2.5], d: (e: true))),
    "{\"a\": \"x\", \"b\": 1, \"c\": [1, 2.5], \"d\": {\"e\": true}}");
~tEq.("a quote and a backslash are escaped",
    LooperSessionRecorder.json("say \"hi\" \\ bye"), "\"say \\\"hi\\\" \\\\ bye\"");
~tEq.("nil is null", LooperSessionRecorder.json(nil), "null");
~tEq.("a symbol is a string", LooperSessionRecorder.json(\lengthAnchored), "\"lengthAnchored\"");
~tEq.("infinity is null", LooperSessionRecorder.json(inf), "null");
~tEq.("not-a-number is null", LooperSessionRecorder.json(0/0), "null");
~tEq.("false is false", LooperSessionRecorder.json(false), "false");
}.value;

// ---- the event log: round trip ---------------------------------------------
// What goes in comes back typed: String:parseJSON hands every scalar back as
// text, and the reader turns numbers back into numbers without touching a
// stamp that happens to be made of digits.
{
var rec = LooperSessionRecorder(nil, dir);
var path = dir +/+ "roundtrip-events.jsonl";
var base = SystemClock.seconds - 5;
var events, ev, f;
if(File.exists(dir).not) { File.mkdir(dir) };
rec.instVarPut(\startedAt, base);
~tEq.("with no log open an event is refused", rec.logEvent(\take, ()), false);
~tEq.("...and the recorder says it is not logging", rec.logging, false);
rec.prOpenLog(path);
~tEq.("with a log open it is logging", rec.logging, true);
~tEq.("...and an event is taken", rec.logEvent(\take,
    (dur: 3.5, stamp: "260928_183000", onsets: [[0.1, 0.5], [0.4, 0.25]], ok: true,
        none: nil, err: \lengthAnchored), base + 1.25), true);
rec.logEvent(\threshold, (value: 0.4));
rec.prCloseLog;
events = LooperSessionRecorder.readEvents(path);
~tEq.("both lines come back", events.size, 2);
ev = events[0];
~tEq.("the kind comes back", ev[\ev], "take");
~tNear.("the time is seconds from the stomp", ev[\t], 1.25, 1e-6);
~tAssert.("numbers come back as numbers", ev[\dur].isNumber and: { ev[\dur] == 3.5 },
    "got " ++ ev[\dur].class ++ " " ++ ev[\dur]);
~tEq.("a stamp made of digits stays a string", ev[\stamp], "260928_183000");
~tEq.("nested arrays come back as numbers", ev[\onsets], [[0.1, 0.5], [0.4, 0.25]]);
~tEq.("booleans come back", ev[\ok], true);
~tEq.("null comes back as nil", ev[\none], nil);
~tEq.("a symbol comes back as a string", ev[\err], "lengthAnchored");
~tAssert.("an event stamped 'now' comes after one stamped earlier",
    events[1][\t] > 1.25, "got " ++ events[1][\t]);
// A crash mid-write leaves a torn last line; it is skipped, not fatal.
f = File(path, "a");
f.write("{\"t\": 9, \"ev\": \"take\", \"dur\":");
f.close;
~tEq.("a torn line is skipped", LooperSessionRecorder.readEvents(path).size, 2);
~tEq.("a missing log is no events", LooperSessionRecorder.readEvents(dir +/+ "nope.jsonl"), []);
File.delete(path);
}.value;

// ---- the event log: takes and outcomes ------------------------------------
// The label logic. A take the switch moved is a take the analyser got wrong,
// and where it settled is the label; moved and moved back is wrong with no
// label; undone is discarded; played on as heard is a weak label the other way.
{
var r78 = (numerator: 7, denominator: 8, k: 2, bpm: 100);
var r74 = (numerator: 7, denominator: 4, k: 2, bpm: 200);
var events = [
    (t: 0,    ev: "session"),
    (t: 0.05, ev: "audio"),
    (t: 1.9,  ev: "recordStart"),
    (t: 6.1,  ev: "take", start: 1.9, dur: 4.2, result: r78, candidates: [r78, r74], threshold: 0.5),
    (t: 6.5,  ev: "readingArmed", index: 1),
    (t: 7.0,  ev: "readingLanded", index: 1, reading: r74),
    (t: 7.5,  ev: "clear"),
    (t: 8.0,  ev: "recordStart"),
    (t: 9.0,  ev: "take", start: 8.0, dur: 1.0, result: r78, candidates: [r78]),
    (t: 9.5,  ev: "undo", state: "stopped"),
    (t: 10.0, ev: "recordStart"),
    (t: 11.0, ev: "take", start: 10.0, dur: 1.0, result: r78, candidates: [r78, r74]),
    (t: 11.2, ev: "readingArmed", index: 1),
    (t: 11.5, ev: "readingLanded", index: 1, reading: r74),
    (t: 11.7, ev: "readingArmed", index: 0),
    (t: 12.0, ev: "readingLanded", index: 0, reading: r78),
    (t: 13.0, ev: "recordStart"),
    (t: 14.0, ev: "take", start: 13.0, dur: 1.0, result: r78, candidates: [r78]),
    (t: 14.5, ev: "overdubStart"),
    (t: 15.5, ev: "overdubEnd"),
    (t: 15.6, ev: "undo", state: "playing"),
    (t: 15.8, ev: "overdubDetect", outcome: "applied", loopDur: 1.0, result: r78, candidates: [r78]),
    (t: 16.0, ev: "sessionStop")
];
var takes = LooperSessionRecorder.takesFrom(events);
~tEq.("four takes and one overdub detection", takes.size, 5);
~tEq.("a take the switch moved is corrected", takes[0][\outcome], \corrected);
~tEq.("...and its label is the reading it settled on", takes[0][\label], r74);
~tEq.("...ended by the clear", [takes[0][\endedBy], takes[0][\end]], [\clear, 7.5]);
~tEq.("a take undone is discarded", takes[1][\outcome], \discarded);
~tEq.("...with no label", takes[1][\label], nil);
~tEq.("moved and moved back is reverted", takes[2][\outcome], \reverted);
~tEq.("...with no label either", takes[2][\label], nil);
~tEq.("...but the presses are counted", takes[2][\presses], 2);
~tEq.("a take played on as heard is accepted", takes[3][\outcome], \accepted);
~tEq.("...its label is the analyser's own reading", takes[3][\label], r78);
~tEq.("undoing an overdub does not discard the take", takes[3][\endedBy], \sessionStop);
~tEq.("an applied overdub detection is listed as its own analysis", takes[4][\kind], \overdub);
~tEq.("the press places a take in the tap", takes[0][\start], 1.9);
}.value;

// ---- the event log: what the looper writes ----------------------------------
// The hooks, on the server-free fixture: the set's story comes out in order
// with the fields the replay needs, and turns back into one corrected take.
{
var l = ~tLooper.();
var rec = l.sessionRec;
var path = dir +/+ "looper-events.jsonl";
var take = (numerator: 6, denominator: 8, k: 2, sub: 1, tau: 0.25, bpm: 120, loopDur: 3.0,
    score: 0.9, n: 12, chordSegments: [(root: 2)]);
var midi = ();
var events, kinds, ev, ctx;
midi[\log] = List.new;
midi[\start] = { |self| self[\log].add(\start); self };
midi[\midiClock] = { |self| self };
midi[\latency] = 0;
take[\candidates] = [take.copy,
    (numerator: 12, denominator: 8, k: 1, sub: 1, tau: 0.25, bpm: 120, loopDur: 3.0, score: 0.85, n: 12)];
if(File.exists(dir).not) { File.mkdir(dir) };
rec.dir = dir;
rec.instVarPut(\startedAt, SystemClock.seconds - 10);
rec.prOpenLog(path);

ctx = l.prSessionContext;
~tEq.("the header context carries the threshold", ctx[\threshold], 0.5);
~tEq.("...and the fallback meter",
    ctx[\fallback], MeterAnalyzer.fallbackNum.asString ++ "/" ++ MeterAnalyzer.fallbackDenom);
~tEq.("...and no loop when nothing is playing", ctx[\loop], nil);

l.onsetThreshold = 0.4;
l.onsetThreshold = 0.4;      // unchanged: nothing to log
~tPut.(l, \state, \playing);
~tPut.(l, \loopFrames, (3.0 * 48000).asInteger);
~tPut.(l, \loopStartTime, SystemClock.seconds - 1);
~tPut.(l, \lastResult, take);
~tPut.(l, \analysedResult, take);
~tPut.(l, \midiOut, midi);
~tEq.("with a loop in force the context carries it", l.prSessionContext[\loop][\numerator], 6);
l.prLogTake(take, 3.0, 0.1, [[0.1, 0.5], [0.85, 0.3]], true, SystemClock.seconds - 4);
l.nextReading;
Routine {
    l.pendingReading[\at] = SystemClock.seconds - 0.01;
    l.prLandReading(~tGet.(l, \readingSeq));
}.next;
l.revertReading;
l.prCancelReading;
l.clear;
rec.prCloseLog;

events = LooperSessionRecorder.readEvents(path);
kinds = events.collect { |e| e[\ev] };
~tEq.("the set's story, in order", kinds,
    ["threshold", "take", "readingArmed", "readingLanded", "readingArmed",
        "readingCancelled", "clear", "stop"]);
ev = events[0];
~tEq.("a threshold change logs the new value", ev[\value], 0.4);
ev = events[1];
~tEq.("the take logs the meter it was heard as",
    [ev[\result][\numerator], ev[\result][\denominator], ev[\result][\k]], [6, 8, 2]);
~tEq.("...its ranked list", ev[\candidates].size, 2);
~tEq.("...the onsets the detector reported", ev[\onsets], [[0.1, 0.5], [0.85, 0.3]]);
~tEq.("...the threshold in force", ev[\threshold], 0.4);
~tNear.("...its length", ev[\dur], 3.0, 1e-9);
~tNear.("...the press, on the log's axis", ev[\start], 6.0, 0.05);
~tNear.("...stamped at the stop press", ev[\t], 9.0, 0.05);
~tEq.("...without the chord segments", ev[\result][\chordSegments], nil);
~tEq.("...and whether it was applied", ev[\applied], true);
ev = events[2];
~tEq.("a press logs which reading it armed", [ev[\index], ev[\of], ev[\via]], [1, 2, "next"]);
~tEq.("...and the reading itself", [ev[\reading][\numerator], ev[\reading][\denominator]], [12, 8]);
ev = events[3];
~tEq.("the landing logs the reading in force", ev[\index], 1);
ev = events[4];
~tEq.("revert arms reading 0 and says so", [ev[\index], ev[\via]], [0, "revert"]);
ev = events[5];
~tEq.("a cancelled reading names which", ev[\index], 0);
~tEq.("the log turns into one corrected take",
    LooperSessionRecorder.takesFrom(events)[0][\outcome], \corrected);
File.delete(path);
}.value;

// ---- the event log: nothing when no set is being recorded -------------------
// Every hook is a no-op otherwise. A looper straight from the fixture has no
// recorder at all; one with an idle recorder has no log open.
{
var l = ~tLooper.();
~tCheck.("a threshold change with no recorder does not throw", { l.onsetThreshold = 0.3 });
~tCheck.("a clear with no recorder does not throw", { l.clear });
l.sessionRec;
~tEq.("an idle recorder is not logging", l.sessionRec.logging, false);
~tEq.("...and refuses events", l.sessionRec.logEvent(\take, ()), false);
~tCheck.("a clear with an idle recorder does not throw", { l.clear });
}.value;
// ---- the starved tap ---------------------------------------------------------
// A clean tap far under the recorded input is a starved analyser, and the
// onset count does not say so once the threshold has been lowered to chase it.
// One rule, on peak levels, shared by the recorder's warning and the replay.
{
~tEq.("a tap 34 dB under a real input is starved",
    Looper.tapStarvedDb([-40.dbamp, -6.dbamp]).round(0.01), 34.0);
~tEq.("a tap 24 dB under is not", Looper.tapStarvedDb([-30.dbamp, -6.dbamp]), nil);
~tEq.("no input at all is not a starved tap (nothing was played)",
    Looper.tapStarvedDb([-90.dbamp, -50.dbamp]), nil);
~tEq.("a silent tap under a real input is", Looper.tapStarvedDb([0, -6.dbamp]).round(1), 114.0);
~tEq.("no report yet is not a verdict", Looper.tapStarvedDb(nil), nil);
~tEq.("the dB form agrees", Looper.tapStarvedFromDb(-40, -6), 34);
~tEq.("...and tolerates a missing figure", Looper.tapStarvedFromDb(nil, -6), nil);
}.value;

// ---- the loop in force when a set begins ----------------------------------
// The header carries the take the loop came from — analyser input and answer,
// which reading is in force — so a set started over a playing loop still
// yields something to score, and the reader makes a take of it.
{
var l = ~tLooper.();
var take = (numerator: 6, denominator: 8, k: 2, sub: 1, tau: 0.25, bpm: 120, loopDur: 3.0,
    score: 0.9, n: 12);
var ctx, events, takes, r128;
take[\candidates] = [take.copy,
    (numerator: 12, denominator: 8, k: 1, sub: 1, tau: 0.25, bpm: 120, loopDur: 3.0, score: 0.85, n: 12)];
r128 = take[\candidates][1];
~tPut.(l, \state, \playing);
~tPut.(l, \loopFrames, (3.0 * 48000).asInteger);
~tPut.(l, \loopDur, 3.02);
~tPut.(l, \lastResult, r128);
~tPut.(l, \analysedResult, take);
~tPut.(l, \readingIndex, 1);
~tGet.(l, \onsets).addAll([[0.1, 0.5], [0.85, 0.3], [1.6, 0.4]]);
ctx = l.prSessionContext;
~tEq.("the header carries the take's raw length", ctx[\take][\dur], 3.02);
~tEq.("...its onsets from the press", ctx[\take][\onsets], [[0.1, 0.5], [0.85, 0.3], [1.6, 0.4]]);
~tEq.("...the analyser's own answer, not the reading in force",
    [ctx[\take][\result][\numerator], ctx[\take][\result][\denominator]], [6, 8]);
~tEq.("...its ranked list", ctx[\take][\candidates].size, 2);
~tEq.("...and which reading is in force", ctx[\take][\reading], 1);
~tEq.("the loop itself is the reading in force", ctx[\loop][\numerator], 12);

events = [
    (t: 0, ev: "session", loop: r128, loopDur: 3.0, take: ctx[\take]),
    (t: 0.04, ev: "audio"),
    (t: 30.0, ev: "readingArmed", index: 0),
    (t: 33.0, ev: "readingLanded", index: 0, reading: take),
    (t: 60.0, ev: "sessionStop")
];
takes = LooperSessionRecorder.takesFrom(events);
~tEq.("the loop in force becomes a take of its own kind", [takes.size, takes[0][\kind]], [1, \inForce]);
~tEq.("...with no place in the tap", takes[0][\start], nil);
~tEq.("...carrying the analyser input", takes[0][\onsets].size, 3);
~tEq.("moved back to the answer during the set: reverted, since it began moved",
    takes[0][\outcome], \reverted);
takes = LooperSessionRecorder.takesFrom(events.keep(2) ++ [events.last]);
~tEq.("a loop already on reading 2 when the set began is corrected", takes[0][\outcome], \corrected);
~tEq.("...and its label is the reading in force", takes[0][\label], r128);
takes = LooperSessionRecorder.takesFrom([(t: 0, ev: "session", loop: r128, loopDur: 3.0), (t: 60, ev: "sessionStop")]);
~tEq.("an older header without the take yields none", takes.size, 0);
}.value;

// ---- the take's levels in the log -----------------------------------------
{
var l = ~tLooper.();
var rec = l.sessionRec;
var path = dir +/+ "levels-events.jsonl";
var take = (numerator: 7, denominator: 8, k: 2, sub: 1, tau: 0.25, bpm: 120, loopDur: 3.5, score: 0.7);
var ev;
if(File.exists(dir).not) { File.mkdir(dir) };
rec.dir = dir;
rec.instVarPut(\startedAt, SystemClock.seconds - 10);
rec.prOpenLog(path);
l.prLogTake(take, 3.5, 0.1, [[0.1, 0.5]], true, SystemClock.seconds - 4, [-40.dbamp, -6.dbamp]);
l.prLogTake(take, 3.5, 0.1, [[0.1, 0.5]], true, SystemClock.seconds - 4, nil);
rec.prCloseLog;
ev = LooperSessionRecorder.readEvents(path);
~tNear.("the take logs the tap's peak in dB", ev[0][\tapPeakDb], -40, 0.11);
~tNear.("...and the input's", ev[0][\inPeakDb], -6, 0.11);
~tEq.("with no level report the fields are absent", ev[1][\tapPeakDb], nil);
File.delete(path);
}.value;
// ===========================================================================
// Phase 5: the files of a set, named with its tempo and signature
// ===========================================================================
// What a set leaves must be enough to take it into Live afterwards: set Live's
// tempo and signature from a file name, drop the stems and the .mid at 1.1.1,
// and everything plays in sync. So the names carry the tempo (Live's two
// decimals) and the signature, decided when the set stops; every WAV starts
// from one bundle, so frame 0 is one moment in every file; and every reader
// still finds a set whatever it was renamed to.

// A Routine stepped to its end (each wait answers a number from .next).
~srRun = { |routine|
    var n = 0;
    while { routine.next.notNil and: { n < 100000 } } { n = n + 1 };
    n
};
~srTouch = { |path, text|
    var f = File(path, "w");
    f.write(text ? "x");
    f.close;
};
// A stub server that hands out node IDs of its own and has a default group,
// as a Server does.
~srStub = {
    var stub = ~tStubServer.();
    stub[\nextNodeID] = { |self| var id = (self[\lastNodeID] ? 1999) + 1; self[\lastNodeID] = id; id };
    stub[\defaultGroup] = Group.basicNew(stub, 1);
    stub[\asTarget] = { |self| self[\defaultGroup] };
    stub
};
// Moves a running recorder's clock back `secs`: the set has been playing that
// long. The header and the audio line keep their places on the log's axis.
~srAge = { |rec, secs|
    rec.instVarPut(\startedAt, rec.startedAt - secs);
    rec.audioAt !? { |a| rec.instVarPut(\audioAt, a - secs) };
};

// ---- the names ------------------------------------------------------------------
{
var t78 = (bpm: 165.0412, numerator: 7, denominator: 8);
var cls = LooperSessionRecorder;
~tEq.("the tempo with exactly two decimals, then the signature", cls.tempoLabel(165.0412, 7, 8), "165.04bpm-7-8");
~tEq.("a whole tempo still has two", cls.tempoLabel(165, 7, 8), "165.00bpm-7-8");
~tEq.("rounded, not cut: 99.995 is 100.00", cls.tempoLabel(99.995, 4, 4), "100.00bpm-4-4");
~tEq.("...as (bpm * 100).round / 100", [cls.tempoLabel(120.004, 4, 4), cls.roundBpm(165.0412)], ["120.00bpm-4-4", 165.04]);
~tEq.("no tempo, no label", [nil, 0, -5, inf, 0/0].collect { |b| cls.tempoLabel(b, 4, 4) }, [nil, nil, nil, nil, nil]);
~tEq.("no signature, no label", [cls.tempoLabel(120, nil, 4), cls.tempoLabel(120, 4, 0)], [nil, nil]);
~tEq.("a file of the set", cls.nameFor("261007_143012", t78, "master", "wav"),
    "261007_143012-165.04bpm-7-8-master.wav");
~tEq.("a set with no tempo keeps today's names", cls.nameFor("261007_143012", nil, "tap", "wav"),
    "261007_143012-tap.wav");
~tEq.("the log and the drums' MIDI file", [\events, \midi].collect { |r|
    var f = cls.fileOf(r);
    cls.nameFor("261007_143012", t78, f[0], f[1])
}, ["261007_143012-165.04bpm-7-8-events.jsonl", "261007_143012-165.04bpm-7-8-drums.mid"]);
~tEq.("a stem's file is named for its role", cls.fileOf(\guitar), ["guitar", "wav"]);
~tEq.("fixed decimals", [cls.fixed(0.3829, 3), cls.fixed(12.3456, 3), cls.fixed(0, 2), cls.fixed(-0.5, 3), cls.fixed(1e-9, 3)],
    ["0.383", "12.346", "0.00", "-0.500", "0.000"]);
~tEq.("a renamed file taken apart", cls.parseName("/x/261007_143012-165.04bpm-7-8-master.wav"),
    (stamp: "261007_143012", bpm: 165.04, numerator: 7, denominator: 8, role: "master", ext: "wav"));
~tEq.("a stamp name", cls.parseName("261007_143012-tap.wav"), (stamp: "261007_143012", role: "tap", ext: "wav"));
~tEq.("a second set of the same second", [cls.parseName("261007_143012-2-165.04bpm-7-8-events.jsonl")[\stamp],
    cls.parseName("261007_143012-2-tap.wav")[\stamp]], ["261007_143012-2", "261007_143012-2"]);
~tEq.("not a session file's name", [cls.parseName("README"), cls.parseName("x.wav")], [nil, nil]);
}.value;

// ---- final names never overwrite ---------------------------------------------------
// Two sets of one second are a double stomp, so the rule is all but never
// needed; when it is, the second set must not open over or rename onto the
// first's files.
{
var d = dir +/+ "names";
var t78 = (bpm: 165.0412, numerator: 7, denominator: 8);
var roles = [\master, \tap, \events, \midi];
var cls = LooperSessionRecorder;
var fp;
File.mkdir(d);
fp = cls.finalPaths(d, "261007_143012", t78, roles);
~tEq.("every file of a set gets the set's name", roles.collect { |r| fp[r].basename },
    ["261007_143012-165.04bpm-7-8-master.wav", "261007_143012-165.04bpm-7-8-tap.wav",
        "261007_143012-165.04bpm-7-8-events.jsonl", "261007_143012-165.04bpm-7-8-drums.mid"]);
~srTouch.(fp[\master]);
fp = cls.finalPaths(d, "261007_143012", t78, roles);
~tEq.("one name taken moves the WHOLE set to -2, so its files stay together", roles.collect { |r| fp[r].basename },
    ["261007_143012-2-165.04bpm-7-8-master.wav", "261007_143012-2-165.04bpm-7-8-tap.wav",
        "261007_143012-2-165.04bpm-7-8-events.jsonl", "261007_143012-2-165.04bpm-7-8-drums.mid"]);
~srTouch.(fp[\events]);
~tEq.("...and to -3 when that is taken too", cls.finalPaths(d, "261007_143012", t78, roles)[\tap].basename,
    "261007_143012-3-165.04bpm-7-8-tap.wav");
~srTouch.(d +/+ "261007_150000-tap.wav");
~tEq.("a set with no tempo keeps its names: they are its own, not taken",
    cls.finalPaths(d, "261007_150000", nil, [\tap], [d +/+ "261007_150000-tap.wav"])[\tap].basename,
    "261007_150000-tap.wav");
~tEq.("a stamp no file uses is the set's", cls.freshStamp(d, "261007_160000"), "261007_160000");
~srTouch.(d +/+ "261007_160000-master.wav");
~tEq.("a second set started in the same second gets -2", cls.freshStamp(d, "261007_160000"), "261007_160000-2");
~srTouch.(d +/+ "261007_160000-2-165.04bpm-7-8-tap.wav");
~tEq.("...and a third -3, whatever the second was renamed to", cls.freshStamp(d, "261007_160000"), "261007_160000-3");
}.value;

// ---- stems --------------------------------------------------------------------------
{
var rec = LooperSessionRecorder(nil, dir);
~tEq.("a recorder starts with no stems (every Live rig)", rec.stems, []);
rec.stems = [(role: \guitar, channel: 30, numChannels: 1), (role: \loop, channel: 32, numChannels: 2),
    (role: \master, channel: 1, numChannels: 2), (role: \loop, channel: 40, numChannels: 2),
    (role: \drums, channel: -2, numChannels: 2), (role: \onset, channel: 36, numChannels: 3),
    (role: "two-words", channel: 38, numChannels: 2), (role: \drums, channel: nil, numChannels: 2),
    (role: \drums, channel: 34, numChannels: 2), 42];
~tEq.("good stems are kept in order, a bad one left out (a reserved role, twice, a negative or no channel, 3 channels, a role with a dash, not an Event)",
    rec.stems.collect { |s| [s[\role], s[\channel], s[\numChannels]] }, [[\guitar, 30, 1], [\loop, 32, 2], [\drums, 34, 2]]);
~tEq.("a rig with stems alone has something to record", rec.prRefusal(nil, nil), nil);
rec.stems = nil;
~tEq.("...and with none, nothing is still refused", [rec.stems, rec.prRefusal(nil, nil).notNil], [[], true]);
~tEq.("the stems' paths before a start", LooperSessionRecorder.pathsFor(dir, "261007_143012", [\guitar])[\guitar].basename,
    "261007_143012-guitar.wav");
}.value;

// ---- the set's tempo and signature ----------------------------------------------------
// The first that applied while the set was recorded: on SA the drums' own
// segment (its exact tempo); otherwise the loop in force at the start, or the
// first take, overdub detection or reading that applied.
{
var path = dir +/+ "tempo-events.jsonl";
var base = SystemClock.seconds - 100;
var r44 = (numerator: 4, denominator: 4, k: 1, bpm: 120.0);
var r78 = (numerator: 7, denominator: 8, k: 2, bpm: 100.0);
var r74 = (numerator: 7, denominator: 4, k: 2, bpm: 200.0);
var fresh = {
    var x = LooperSessionRecorder(nil, dir);
    x.instVarPut(\startedAt, base);
    x.prOpenLog(path);
    x
};
var rec, t;
rec = fresh.();
rec.logEvent(\session, (stamp: "x", loop: r44), base);
rec.logEvent(\take, (result: r78, applied: true), base + 10);
rec.logEvent(\drumsStart, (bpm: 165.0412, numerator: 7, denominator: 8, n16: 28, loopDur: 10.1792), base + 20);
t = rec.chosenTempo(base + 60);
~tEq.("on SA the drums' first segment wins over every analysis",
    [t[\from], t[\bpm], t[\numerator], t[\denominator], t[\at]], [\drums, 165.0412, 7, 8, base + 20]);
~tEq.("a segment that had not begun when the set stopped is not the set's", rec.chosenTempo(base + 15)[\from], \loop);
~tEq.("the drums' transport becomes markers", rec.markers.collect(_[\text]), ["drums start 7/8 165.04 BPM"]);
rec.prCloseLog;

// Two segments: the drums start in 7/8, a 4/4 reading lands half a minute on.
// The first is the set's, the one its drum hits were played at from the start.
rec = fresh.();
rec.logEvent(\drumsStart, (bpm: 165.0412, numerator: 7, denominator: 8, n16: 28, loopDur: 10.1792), base + 2);
rec.logEvent(\drumsSegment, (bpm: 120.0, numerator: 4, denominator: 4, n16: 16, loopDur: 2.0), base + 30);
t = rec.chosenTempo(base + 60) ? ();
~tEq.("two drums segments: the set's tempo is the first that sounded, not a later landing",
    [t[\from], t[\bpm], t[\numerator], t[\denominator], t[\at]], [\drums, 165.0412, 7, 8, base + 2]);
rec.prCloseLog;

rec = fresh.();
rec.logEvent(\session, (stamp: "x", loop: r44), base);
rec.logEvent(\take, (result: r78, applied: true), base + 10);
~tEq.("without drums, the loop in force when the set began", rec.chosenTempo(base + 60)[\from], \loop);
rec.prCloseLog;

rec = fresh.();
rec.logEvent(\session, (stamp: "x"), base);
rec.logEvent(\take, (result: r78, applied: false), base + 5);
rec.logEvent(\take, (result: (error: \tooFewOnsets, onsetCount: 2)), base + 8);
rec.logEvent(\take, (result: r74, applied: true), base + 10);
rec.logEvent(\readingLanded, (index: 1, reading: r44), base + 20);
t = rec.chosenTempo(base + 60);
~tEq.("then the first take that applied: not one cleared during its analysis, not one with no tempo",
    [t[\from], t[\bpm], t[\numerator], t[\denominator]], [\take, 200.0, 7, 4]);
rec.prCloseLog;

rec = fresh.();
rec.logEvent(\overdubDetect, (outcome: \skipped), base + 2);
rec.logEvent(\overdubDetect, (outcome: \applied, result: r78), base + 3);
rec.logEvent(\readingLanded, (index: 0, reading: r44), base + 4);
~tEq.("an overdub detection that applied counts; one skipped does not", rec.chosenTempo(base + 60)[\from], \overdub);
rec.prCloseLog;

rec = fresh.();
rec.logEvent(\readingLanded, (index: 1, reading: r74), base + 4);
~tEq.("so does a reading that landed", rec.chosenTempo(base + 60)[\from], \reading);
rec.prCloseLog;

rec = fresh.();
rec.logEvent(\drumsSegment, (n16: 16, loopDur: 2.0, numerator: 4, denominator: 4), base + 4);
rec.logEvent(\breakStart, (), base + 5);
rec.logEvent(\breakEnd, (), base + 6);
rec.logEvent(\drumsOn, (on: false), base + 7);
rec.logEvent(\drumsOn, (on: true), base + 8);
rec.logEvent(\drumsStop, (), base + 9);
t = rec.chosenTempo(base + 60);
~tEq.("a drums segment with only n16 and loopDur: 15 * n16 / loopDur", [t[\from], t[\bpm]], [\drums, 120.0]);
~tEq.("...and every transport event a marker", rec.markers.collect(_[\text]),
    ["reading 4/4 120.00 BPM", "break", "back", "drums off", "drums on", "drums stop"]);
rec.prCloseLog;

rec = fresh.();
rec.logEvent(\drumsStart, (bpm: 165.0412, numerator: 7, denominator: 8, inForce: true), base - 30);
~tEq.("the drums' segment in force when the set began is a tempo, and its marker says they were playing",
    [rec.chosenTempo(base + 60) !? (_[\from]), rec.markers.collect(_[\text]).asArray],
    [\drums, ["drums playing 7/8 165.04 BPM"]]);
rec.prCloseLog;

rec = fresh.();
rec.logEvent(\session, (stamp: "x"), base);
~tEq.("nothing analysed and no loop at the start: no tempo", rec.chosenTempo(base + 60), nil);
rec.prCloseLog;
File.delete(path);
}.value;

// ---- the drums' hits in the log ------------------------------------------------------
{
var rec = LooperSessionRecorder(nil, dir);
var path = dir +/+ "hits-events.jsonl";
var base = SystemClock.seconds - 10;
var fake, events, hits;
rec.instVarPut(\startedAt, base);
hits = [
    (at: base + 2.5, slot: \steps, kind: \step, note: 36, vel: 100, lane: 0, which: \main, kit: 'carbon-layer'),
    (at: base + 2.25, slot: \onset, kind: \onset, note: 36, vel: 70, gate: 0.02, kit: 'one-hit'),
    (at: base + 2.375, slot: \steps, kind: \repeat, note: 37, vel: 90, lane: 1, which: \break, kit: 'carbon-layer')
];
~tEq.("with no set being recorded, hits are refused", rec.logHits(hits), false);
~tEq.("...and none is kept", rec.loggedHits.size, 0);
rec.prOpenLog(path);
~tEq.("with a log open, a batch is taken", rec.logHits(hits), true);
rec.prCloseLog;
events = LooperSessionRecorder.readEvents(path);
~tEq.("one hit line per hit", events.collect(_[\ev]), ["hit", "hit", "hit"]);
~tEq.("in time order within the batch, on the log's axis", events.collect(_[\t]), [2.25, 2.375, 2.5]);
~tEq.("...with what was played", [\slot, \kind, \note, \vel, \lane, \which, \kit].collect { |k| events[2][k] },
    ["steps", "step", 36, 100, 0, "main", "carbon-layer"]);
~tEq.("an onset's gate; a repeat says it is one", [events[0][\gate], events[1][\kind]], [0.02, "repeat"]);
~tEq.("the absolute time is not written: t is the time", events.collect(_[\at]), [nil, nil, nil]);
~tEq.("kept for the MIDI file at their heard times, in order", rec.loggedHits.collect(_[\at]),
    [base + 2.25, base + 2.375, base + 2.5]);
// One flush per call: the drums send a batch per pump, a hundred a second.
fake = (writes: List.new, flushes: 0);
fake[\write] = { |self, str| self[\writes].add(str); self };
fake[\flush] = { |self| self[\flushes] = self[\flushes] + 1; self };
fake[\close] = { |self| self };
rec.instVarPut(\logFile, fake);
rec.logHits(hits);
~tEq.("a batch is one write and ONE flush, not one per hit", [fake[\writes].size, fake[\flushes]], [1, 1]);
~tEq.("...holding every line", fake[\writes][0].split($\n).reject(_.isEmpty).size, 3);
rec.logEvent(\threshold, (value: 0.4));
~tEq.("an event is a flush of its own", fake[\flushes], 2);
~tEq.("an empty batch writes nothing", [rec.logHits([]), fake[\writes].size], [true, 2]);
rec.logHits([(kind: \step, note: 36)]);
~tEq.("a hit with no time is left out", fake[\writes].size, 2);
rec.instVarPut(\logFile, nil);
File.delete(path);
}.value;

// ---- the hint for Live ----------------------------------------------------------------
{
var cls = LooperSessionRecorder;
var bd = cls.barDur(165.04, 7, 8);
var t78 = (bpm: 165.0412, numerator: 7, denominator: 8);
var t44 = (bpm: 120, numerator: 4, denominator: 4);
~tNear.("a bar of 7/8 is three and a half quarters", bd, 3.5 * (60 / 165.04), 1e-12);
~tNear.("bar 1 at 12.345 s is moved right to the next bar line", cls.barShift(12.345, bd), bd - (12.345 - (9 * bd)), 1e-9);
~tNear.("a bar 1 before frame 0 likewise", cls.barShift(-0.5, bd), 0.5, 1e-9);
~tNear.("one on a bar line needs no move", cls.barShift(4.0, 2.0), 0, 1e-12);
~tEq.("the sentence the post window ends with",
    cls.liveHint(t78, 12.345),
    "In Live: 165.04 BPM, 7/8. The drums' bar 1 is at 12.345 s (drop the files at 1.1.1; to put the drums "
    "on Live's bar lines, move everything right by " ++ cls.fixed(cls.barShift(12.345, bd), 3) ++ " s).");
~tEq.("...which is 0.379 s here", cls.fixed(cls.barShift(12.345, bd), 3), "0.379");
~tEq.("with no drums, the tempo and the signature", cls.liveHint(t44, nil), "In Live: 120.00 BPM, 4/4. Drop the files at 1.1.1.");
~tAssert.("drums on a bar line already: no move", cls.liveHint(t44, 4.0).contains("the drums are on Live's bar lines there"),
    cls.liveHint(t44, 4.0));
~tAssert.("drums already playing at the start: their first bar line in the files",
    cls.liveHint(t78, -0.5).contains("first bar line in the files is at " ++ cls.fixed((-0.5).mod(bd), 3) ++ " s"),
    cls.liveHint(t78, -0.5));
// Five minutes of drums at 97.3349 BPM before the set: their bar lines are
// 2.4658 s apart, Live's at 97.33 2.4659 s; stepped back at Live's, the first
// would be 15 ms off by now.
~tEq.("drums playing for minutes before the set: their first bar line stepped back at THEIR bar, not Live's rounded one",
    cls.liveHint((bpm: 97.3349, numerator: 4, denominator: 4), -300.0),
    "In Live: 97.33 BPM, 4/4. The drums were already playing; their first bar line in the files is at 0.817 s "
    "(drop the files at 1.1.1; to put the drums on Live's bar lines, move everything right by 1.649 s).");
~tNear.("...and the shift the files event gets", cls.liveShift((bpm: 97.3349, numerator: 4, denominator: 4), -300.0),
    1.649, 0.0005);
~tEq.("bar 1 itself when it is in the set", cls.firstBarLine(t78, 12.345), 12.345);
~tEq.("with the set's clock, bar 1's place in the files",
    cls.liveHint(t44, 4.0, (rate: 1, lead: 0.25)).contains("bar 1 is at 4.250 s"), true);
~tEq.("no tempo, no hint", cls.liveHint(nil, 3), nil);
}.value;

// ---- a set on SA, start to finish ----------------------------------------------------
// The real start and stop, on a stub server: every buffer, synth and bundle is
// captured instead of reaching scsynth, and the WAVs the server would have
// written are made by hand, so the stop's renaming runs on real files.
{
var d = dir +/+ "flow";
var stub = ~srStub.();
var specs = [(role: \guitar, channel: 30, numChannels: 1), (role: \loop, channel: 32, numChannels: 2),
    (role: \drums, channel: 34, numChannels: 2), (role: \onset, channel: 36, numChannels: 2)];
var wavs = [\master, \tap, \guitar, \loop, \drums, \onset];
var label = "-165.04bpm-7-8-";
var rec, r, allocs, opened, starts, sNew, events, ev, filesEv, back, a0, stamp, ids, frees, closes, found;
// Frame 0 half a block before audioAt; the stub's WAVs are no sound files, so
// their length says nothing and the clock is taken as the Mac's.
var lead = LooperSessionRecorder.frame0Lead(stub), clock = (rate: 1, lead: lead);
rec = LooperSessionRecorder(stub, d);
rec.target = Group.basicNew(stub, 7);
rec.stems = specs;
~tCheck.("a set starts on the stub", {
    ~srRun.(Routine { rec.start(20, 16, (threshold: 0.5, loop: (numerator: 4, denominator: 4, bpm: 120.0)), true) })
});
stamp = rec.stamp;
~tEq.("it is recording", rec.recording, true);
~tEq.("every file under the set's stamp while it records",
    rec.paths.keys.asArray.collect(_.asString).sort.collect { |k| rec.paths[k.asSymbol].basename },
    ["drums", "events", "guitar", "loop", "master", "onset", "tap"].collect { |k|
        stamp ++ "-" ++ k ++ (if(k == "events") { ".jsonl" } { ".wav" }) });
allocs = stub[\msgs].select { |m| m[0].asString.contains("b_alloc") };
~tEq.("a buffer per WAV, of its channel count: master, tap, then the stems", allocs.collect { |m| m[3] }, [2, 1, 1, 2, 2, 2]);
opened = stub[\msgs].select { |m| m[0].asString.contains("b_write") };
~tEq.("...each opened as a WAV left open for DiskOut: the master and the tap int24, the stems float (a strip can run over full scale)",
    opened.collect { |m| [m[2].basename, m[3], m[4], m[7]] },
    wavs.collect { |w| [stamp ++ "-" ++ w ++ ".wav", "wav", if([\master, \tap].includes(w)) { "int24" } { "float" }, 1] });
starts = stub[\bundles].select { |b| b[1].any { |m| m[0] == 9 } };
~tEq.("ONE bundle starts every DiskOut synth", starts.size, 1);
sNew = starts[0] !? { |b| b[1] } ? [];
~tEq.("...all six: stereo for the master and the stereo stems, mono for the tap and the guitar",
    sNew.collect { |m| m[1] }, [\looperSessionMaster, \looperSessionTap, \looperSessionTap,
        \looperSessionMaster, \looperSessionMaster, \looperSessionMaster]);
~tEq.("...each at the tail of the record group", sNew.collect { |m| [m[3], m[4]] }.asSet.asArray, [[1, 7]]);
~tEq.("...each reading its channel into its own buffer", sNew.collect { |m| [m[6], m[8]] },
    allocs.collect(_[1]).collect { |b, i| [b, [20, 16, 30, 32, 34, 36][i]] });
~tNear.("...stamped audioAt: the moment that is frame 0 of every file", starts[0] !? { |b| b[0] }, rec.audioAt, 1e-9);
~tNear.("...the start latency ahead", rec.audioAt - rec.startedAt, LooperSessionRecorder.startLatency, 1e-9);
~tEq.("no synth starts outside it", stub[\msgs].count { |m| m[0] == 9 }, 0);
events = LooperSessionRecorder.readEvents(rec.paths[\events]);
ev = events[0];
~tEq.("the header lists the stems: role, channel, channels, path",
    (ev[\stems] ? []).collect { |s| [s[\role], s[\channel], s[\numChannels], s[\path].basename] },
    specs.collect { |s| [s[\role].asString, s[\channel], s[\numChannels], stamp ++ "-" ++ s[\role] ++ ".wav"] });
~tEq.("...and the master and the tap as before", [ev[\master].basename, ev[\tap].basename],
    [stamp ++ "-master.wav", stamp ++ "-tap.wav"]);
~tEq.("the audio line is frame 0 on the log's axis", events[1] !? { |e| [e[\ev], e[\t]] },
    ["audio", LooperSessionRecorder.startLatency]);

// A minute of set: the drums start a second after frame 0, play, break. The
// onset kit's gate is 60 ms, as the player set it, not the 20 ms default.
~srAge.(rec, 60);
a0 = rec.audioAt;
rec.logEvent(\drumsStart, (bpm: 165.0412, numerator: 7, denominator: 8, n16: 28, loopDur: 10.1792), a0 + 1.0);
rec.logHits([
    (at: a0 + 1.0, slot: \steps, kind: \step, note: 36, vel: 100, lane: 0, which: \main, kit: 'k'),
    (at: a0 + 1.2, slot: \steps, kind: \roll, note: 42, vel: 60, lane: 2, which: \main, kit: 'k'),
    (at: a0 + 1.3, slot: \onset, kind: \onset, note: 36, vel: 70, gate: 0.06, kit: 'o'),
    (at: a0 + 1.4, slot: \steps, kind: \repeat, note: 37, vel: 90, lane: 1, which: \main, kit: 'k')]);
rec.logEvent(\breakStart, (), a0 + 2.0);
rec.logEvent(\breakEnd, (), a0 + 3.0);
rec.logEvent(\drumsOn, (on: false), a0 + 4.0);
wavs.do { |w| ~srTouch.(rec.paths[w], "wav " ++ w) };

r = Routine { rec.stop(true) };
// Near, not equal: the wait is (stopAt - now) + closeWait, and stopAt - now is
// the start latency only to the rounding of the clock's time, which depends on
// when the run began (after a second of startup it is never exact).
~tNear.("the stop's first half runs at once and then waits until the WAVs have ended and closeWait more",
    r.next, LooperSessionRecorder.startLatency + LooperSessionRecorder.closeWait, 1e-9);
~tEq.("...not recording, the log still open (the set's tail), nothing decided yet, nothing renamed",
    [rec.recording, rec.logging, rec.finalPaths, rec.tempoInfo, rec.settled], [false, true, nil, nil, false]);
ids = sNew.collect(_[2]);
frees = stub[\bundles].last;
~tEq.("every synth is freed in one bundle", (frees !? { |b| b[1] } ? []).collect { |m| [m[0], m[1]] },
    ids.collect { |id| [11, id] });
~tNear.("...stamped the start latency after the stop, as frame 0 was after the start: stopAt",
    frees !? { |b| b[0] }, rec.stoppedAt + LooperSessionRecorder.startLatency, 1e-9);
~tNear.("...which the recorder knows", rec.stopAt, rec.stoppedAt + LooperSessionRecorder.startLatency, 1e-9);
// What the drums tell it meanwhile: heard before the WAVs end, it is the set's.
rec.logHits([(at: rec.stopAt - 0.15, slot: \steps, kind: \step, note: 38, vel: 80, lane: 1, which: \main, kit: 'k'),
    (at: rec.stopAt + 0.01, slot: \steps, kind: \step, note: 40, vel: 80, lane: 1, which: \main, kit: 'k')]);
~tEq.("in the tail, a hit heard before the WAVs end is the set's; one after is not",
    rec.loggedHits.collect(_[\note]).asArray, [36, 42, 36, 37, 38]);
~tEq.("...and so is the transport", [rec.logEvent(\drumsStop, (), rec.stopAt - 0.1), rec.logEvent(\breakStart, (), rec.stopAt)],
    [true, false]);
~tCheck.("the second half runs", { ~srRun.(r) });
~tEq.("then the tempo is the drums'", rec.tempoInfo !? { |t| [t[\from], t[\bpm]] }, [\drums, 165.0412]);
closes = stub[\msgs].select { |m| m[0].asString.contains("b_close") };
~tEq.("then every buffer is closed", closes.collect(_[1]), allocs.collect(_[1]));
~tEq.("every WAV has its final name, its contents unchanged",
    wavs.collect { |w| var p = d +/+ (stamp ++ label ++ w ++ ".wav"); [File.exists(p), File.exists(p) and: { File.readAllString(p) == ("wav " ++ w) }] },
    wavs.collect { [true, true] });
~tEq.("...and the stamp names are gone", wavs.count { |w| File.exists(d +/+ (stamp ++ "-" ++ w ++ ".wav")) }, 0);
~tEq.("the log too", [File.exists(d +/+ (stamp ++ label ++ "events.jsonl")), File.exists(d +/+ (stamp ++ "-events.jsonl"))],
    [true, false]);
~tEq.("the MIDI file is written under its final name", File.exists(d +/+ (stamp ++ label ++ "drums.mid")), true);
~tEq.("the recorder says where everything is now", [rec.settled, rec.paths == rec.finalPaths], [true, true]);
events = LooperSessionRecorder.readEvents(rec.paths[\events]);
~tEq.("the log ends with files, then sessionStop", events.keep(-2).collect(_[\ev]), ["files", "sessionStop"]);
~tEq.("...after the tail's hit and transport, and nothing heard once the WAVs had ended",
    events.select { |e| (e[\t] ? 0) > 60 }.collect { |e| [e[\ev], e[\note]] }, [["hit", 38], ["drumsStop", nil]]);
filesEv = events.detect { |e| e[\ev] == "files" } ? ();
~tEq.("the files event: every role and its final name", filesEv[\files],
    ().putPairs((wavs ++ [\events, \midi]).collect { |w|
        [w, stamp ++ label ++ switch(w, \events, { "events.jsonl" }, \midi, { "drums.mid" }, { w ++ ".wav" })] }.flatten(1)));
~tEq.("...the hint for Live",
    filesEv[\liveHint], LooperSessionRecorder.liveHint(rec.tempoInfo, 1.0, clock));
~tEq.("...which names the tempo, the signature and the drums' bar 1 in the files (half a block after audioAt's 1.000 s)",
    filesEv[\liveHint] !? { |h| h.copyRange(0, 61) }, "In Live: 165.04 BPM, 7/8. The drums' bar 1 is at 1.001 s (drop");
~tEq.("...and the numbers: bar 1 from audioAt",
    [filesEv[\tempo] !? { |t| [t[\bpm], t[\numerator], t[\denominator], t[\from]] }, filesEv[\bar1]],
    [[165.04, 7, 8, "drums"], 1.0]);
~tNear.("...and its place in the files", filesEv[\firstBar], 1.0 + lead, 0.0005);
~tNear.("...with the shift onto Live's bar lines", filesEv[\shift],
    LooperSessionRecorder.barShift(1.0 + lead, LooperSessionRecorder.barDur(165.04, 7, 8)), 0.0005);
~tEq.("...where the WAVs end on the log's axis; no length or clock, the WAVs being no sound files",
    [filesEv[\audioEnd], filesEv[\frames], filesEv[\clockPpm], rec.wavFrames, rec.clockRate],
    [(rec.stopAt - rec.startedAt).round(0.0001), nil, nil, nil, nil]);
back = LooperMidiFile.read(rec.paths[\midi]);
~tEq.("the MIDI file reads: three tracks", back[\tracks] !? (_.size), 3);
back[\tracks] !? { |trs|
    ~tEq.("at the set's tempo, in its signature", [trs[0].detect { |e| e[\meta] == 0x51 } !? (_[\data]),
        trs[0].detect { |e| e[\meta] == 0x58 } !? (_[\data])], [[0x05, 0x8C, 0x1C], [7, 3, 24, 8]]);
    ~tEq.("the drums' transport as markers, where each is in the files (the tail's drumsStop too)",
        trs[0].select { |e| e[\meta] == 0x06 }.collect { |e| [e[\tick], e[\text]] },
        [[1.0, "drums start 7/8 165.04 BPM"], [2.0, "break"], [3.0, "back"], [4.0, "drums off"],
            [rec.stopAt - 0.1 - a0, "drums stop"]].collect { |p| [LooperMidiFile.tickAt(p[0] + lead, 165.04), p[1]] });
    ~tEq.("the step and the roll on their lanes' channels, the repeat left out, the tail's step in",
        trs[1].select { |e| e[\status] == 0x90 }.collect { |e| [e[\tick], e[\chan], e[\note], e[\vel]] },
        [[1.0, 1, 36, 100], [1.2, 3, 42, 60], [rec.stopAt - 0.15 - a0, 2, 38, 80]].collect { |n|
            [LooperMidiFile.tickAt(n[0] + lead, 165.04)] ++ n.drop(1) });
    ~tEq.("the onset on channel 2",
        trs[2].select { |e| e[\status] == 0x90 }.collect { |e| [e[\tick], e[\chan], e[\note], e[\vel]] },
        [[LooperMidiFile.tickAt(1.3 + lead, 165.04), 1, 36, 70]]);
    ~tEq.("...as long as the gate it was logged with: 60 ms at 165.04 BPM, not the default's 20",
        trs[2].select { |e| e[\status] == 0x80 }.collect(_[\tick]),
        [LooperMidiFile.tickAt(1.3 + lead, 165.04) + LooperMidiFile.tickAt(0.06, 165.04)]);
    ~tEq.("every track runs to the set's end, where the WAVs end",
        trs.collect { |t| t.last[\tick] }.asSet.asArray, [LooperMidiFile.tickAt((rec.stopAt - a0) + lead, 165.04)]);
};
~tEq.("the set is found by its stamp", LooperSessionRecorder.findEvents(d, stamp), rec.paths[\events]);
found = [\master, \tap, \guitar, \onset, \events, \midi].collect { |w|
    LooperSessionRecorder.sessionPath(events, w, rec.paths[\events]) };
~tEq.("...and every file of it from its log", found, [\master, \tap, \guitar, \onset, \events, \midi].collect { |w| rec.paths[w] });
}.value;

// ---- taken names, failed renames ------------------------------------------------------
{
var d = dir +/+ "clash";
var stub = ~srStub.();
var rec, r, stamp, taken, guitarFinal, events, filesEv;
rec = LooperSessionRecorder(stub, d);
rec.target = Group.basicNew(stub, 7);
rec.stems = [(role: \guitar, channel: 30, numChannels: 1)];
~srRun.(Routine { rec.start(20, 16, (loop: (numerator: 4, denominator: 4, bpm: 120.0)), true) });
stamp = rec.stamp;
~srAge.(rec, 30);
[\master, \tap, \guitar].do { |w| ~srTouch.(rec.paths[w], "wav " ++ w) };
taken = d +/+ (stamp ++ "-120.00bpm-4-4-master.wav");
~srTouch.(taken, "someone else's");
File.delete(rec.paths[\tap]);
r = Routine { rec.stop(true) };
// The names are decided once the WAVs have ended, and a view is told at once
// (onChange), before anything is renamed: that is the moment to take one.
rec.onChange = { |x|
    if(guitarFinal.isNil and: { x.finalPaths.notNil }) {
        guitarFinal = x.finalPaths[\guitar];
        ~srTouch.(guitarFinal, "arrived meanwhile");
    };
};
~srRun.(r);
rec.onChange = nil;
~tEq.("a set whose name is taken moves to -2, all its files", [\master, \events].collect { |w| rec.finalPaths[w].basename },
    [stamp ++ "-2-120.00bpm-4-4-master.wav", stamp ++ "-2-120.00bpm-4-4-events.jsonl"]);
~tAssert.("(a name was taken after it was decided)", guitarFinal.notNil);
~tEq.("the file that had the name is untouched", File.readAllString(taken), "someone else's");
~tEq.("the master went to its -2 name", File.exists(rec.finalPaths[\master]) and: {
    File.readAllString(rec.finalPaths[\master]) == "wav master" }, true);
~tEq.("a name taken after it was decided is not overwritten: that file keeps its stamp name",
    [File.readAllString(guitarFinal), rec.paths[\guitar].basename, File.exists(rec.paths[\guitar])],
    ["arrived meanwhile", stamp ++ "-guitar.wav", true]);
~tEq.("a file never written is not renamed, and the others are",
    [rec.paths[\tap].basename, File.exists(rec.finalPaths[\events])], [stamp ++ "-tap.wav", true]);
events = LooperSessionRecorder.readEvents(rec.paths[\events]);
filesEv = events.detect { |e| e[\ev] == "files" } ? ();
~tEq.("the files event names where each was meant to go", filesEv[\files] !? { |f| f[\guitar] }, guitarFinal.basename);
~tEq.("a reader still finds the set's own guitar, under its stamp name",
    LooperSessionRecorder.sessionPath(events, \guitar, rec.paths[\events]), d +/+ (stamp ++ "-guitar.wav"));
~tEq.("...and a tap that was never there is nowhere", LooperSessionRecorder.sessionPath(events, \tap, rec.paths[\events]), nil);
~tEq.("no MIDI file without a drum hit", [rec.finalPaths[\midi], filesEv[\files] !? { |f| f[\midi] }], [nil, nil]);
}.value;

// ---- a .mid's name taken after it was decided ------------------------------------------
// The .mid is written last, after the renames, and it never overwrites either:
// its final name found taken, it goes under the set's stamp name (the post
// window says so), where a reader of the log looks first, so that it finds the
// set's own .mid and not the file that has its name; both names taken, the set
// has no .mid.
{
// A set with one step at 120 in 4/4, stopped; `take` runs once its names are
// decided and before anything is renamed or written (a view is told then).
var mk = { |d, take|
    var stub = ~srStub.();
    var rec = LooperSessionRecorder(stub, d);
    var a0;
    ~srRun.(Routine { rec.start(20, 16, nil, true) });
    ~srAge.(rec, 10);
    a0 = rec.audioAt;
    rec.logEvent(\drumsStart, (bpm: 120.0, numerator: 4, denominator: 4), a0 + 1.0);
    rec.logHits([(at: a0 + 1.0, slot: \steps, kind: \step, note: 36, vel: 100, lane: 0, which: \main, kit: 'k')]);
    [\master, \tap].do { |w| ~srTouch.(rec.paths[w], "wav " ++ w) };
    rec.onChange = { |x| if(x.finalPaths.notNil and: { x.settled.not }) { take.(x); take = nil } };
    ~srRun.(Routine { rec.stop(true) });
    rec.onChange = nil;
    rec
};
var d = dir +/+ "midi-taken";
var rec, own, taken, events, filesEv;
rec = mk.(d, { |x| taken = x.finalPaths[\midi]; ~srTouch.(taken, "someone else's") });
own = d +/+ (rec.stamp ++ "-drums.mid");
~tAssert.("(the .mid's final name, with the set's tempo, was taken after it was decided)",
    taken.notNil and: { taken.basename == (rec.stamp ++ "-120.00bpm-4-4-drums.mid") }, taken);
~tEq.("a .mid's name taken after it was decided is not overwritten", taken !? { |p| File.readAllString(p) }, "someone else's");
~tEq.("...the set's .mid goes under its stamp name, and the recorder says so", [rec.paths[\midi], rec.settled], [own, true]);
~tEq.("...and it is the set's: its step", LooperMidiFile.read(own)[\tracks] !? { |t|
    t[1].select { |e| e[\status] == 0x90 }.collect(_[\note]) }, [36]);
events = LooperSessionRecorder.readEvents(rec.paths[\events]);
filesEv = events.detect { |e| e[\ev] == "files" } ? ();
~tEq.("...while the files event names where it was meant to go", filesEv[\files] !? { |f| f[\midi] }, taken !? (_.basename));
~tEq.("...and a reader of the log finds the set's own .mid, not the file under that name",
    LooperSessionRecorder.sessionPath(events, \midi, rec.paths[\events]), own);
d = dir +/+ "midi-both-taken";
rec = mk.(d, { |x|
    ~srTouch.(x.finalPaths[\midi], "A");
    ~srTouch.(x.finalPaths[\midi].dirname +/+ (x.stamp ++ "-drums.mid"), "B");
});
~tEq.("both names taken: neither is overwritten, and the set has no .mid",
    [File.readAllString(rec.finalPaths[\midi]), File.readAllString(d +/+ (rec.stamp ++ "-drums.mid")), rec.paths[\midi], rec.settled],
    ["A", "B", nil, true]);
~tEq.("...nor is one written anywhere else", (LooperSessionRecorder.globQuote(d) +/+ "*.mid").pathMatch.size, 2);
}.value;

// ---- a view follows the stop to the names on disk ---------------------------------------
// onChange is how the Perform pane learns that a stop is done: until then it
// shows the names decided, after it the names the files have. So a stop's last
// word comes after the renames, settled, naming the master where it is on
// disk: under its final name, or, that name taken meanwhile, under the stamp
// name it kept (not the other file that has the final name).
{
var go = { |takeIt|
    var d = dir +/+ (if(takeIt) { "onchange-taken" } { "onchange" });
    var stub = ~srStub.();
    var rec = LooperSessionRecorder(stub, d);
    var seen = List.new;
    ~srRun.(Routine { rec.start(20, 16, (loop: (numerator: 4, denominator: 4, bpm: 120.0)), true) });
    ~srAge.(rec, 10);
    [\master, \tap].do { |w| ~srTouch.(rec.paths[w], "wav " ++ w) };
    rec.onChange = { |x|
        if(takeIt and: { x.finalPaths.notNil } and: { File.exists(x.finalPaths[\master]).not }) {
            ~srTouch.(x.finalPaths[\master], "arrived meanwhile");
        };
        seen.add([x.settled, x.paths[\master].basename,
            x.paths[\master] !? { |p| if(File.exists(p)) { File.readAllString(p) } }]);
    };
    ~srRun.(Routine { rec.stop(true) });
    rec.onChange = nil;
    [rec.stamp, seen]
};
var plain = go.(false), taken = go.(true);
~tEq.("a view is told last after the renames: settled, the master under its final name",
    plain[1].last, [true, plain[0] ++ "-120.00bpm-4-4-master.wav", "wav master"]);
~tEq.("...and with the master's final name taken meanwhile, under the stamp name it kept, not the other file's",
    taken[1].last, [true, taken[0] ++ "-master.wav", "wav master"]);
}.value;

// ---- a Live rig's set; a set with no tempo ------------------------------------------------
{
var d = dir +/+ "live";
var stub = ~srStub.();
var rec = LooperSessionRecorder(stub, d);
var stamp, sNew, events, filesEv;
~srRun.(Routine { rec.start(0, 16, (loop: (numerator: 7, denominator: 8, k: 2, bpm: 100.0)), true) });
stamp = rec.stamp;
sNew = stub[\bundles].detect { |b| b[1].any { |m| m[0] == 9 } } !? { |b| b[1] } ? [];
~tEq.("a Live rig records the master and the tap, from one bundle, at the tail of the default group",
    sNew.collect { |m| [m[1], m[3], m[4]] }, [[\looperSessionMaster, 1, 1], [\looperSessionTap, 1, 1]]);
~srAge.(rec, 30);
[\master, \tap].do { |w| ~srTouch.(rec.paths[w], "wav " ++ w) };
rec.logEvent(\take, (result: (numerator: 4, denominator: 4, bpm: 130.0), applied: true));
~srRun.(Routine { rec.stop(true) });
~tEq.("its files are named for the loop in force when it began",
    [\master, \tap, \events].collect { |w| rec.paths[w].basename },
    [stamp ++ "-100.00bpm-7-8-master.wav", stamp ++ "-100.00bpm-7-8-tap.wav", stamp ++ "-100.00bpm-7-8-events.jsonl"]);
events = LooperSessionRecorder.readEvents(rec.paths[\events]);
filesEv = events.detect { |e| e[\ev] == "files" } ? ();
~tEq.("...with no MIDI file (Live records its own) and the plain hint",
    [rec.paths[\midi], filesEv[\liveHint]], [nil, "In Live: 100.00 BPM, 7/8. Drop the files at 1.1.1."]);

stub = ~srStub.();
rec = LooperSessionRecorder(stub, d);
~srRun.(Routine { rec.start(0, 16, (threshold: 0.5), true) });
stamp = rec.stamp;
~srAge.(rec, 10);
[\master, \tap].do { |w| ~srTouch.(rec.paths[w], "wav " ++ w) };
~srRun.(Routine { rec.stop(true) });
~tEq.("a set in which nothing was analysed keeps its stamp names",
    [\master, \tap, \events].collect { |w| rec.paths[w].basename },
    [stamp ++ "-master.wav", stamp ++ "-tap.wav", stamp ++ "-events.jsonl"]);
events = LooperSessionRecorder.readEvents(rec.paths[\events]);
filesEv = events.detect { |e| e[\ev] == "files" } ? ();
~tEq.("...says so in its files event, with no hint", [filesEv[\files] !? { |f| f[\tap] }, filesEv[\liveHint], filesEv[\tempo]],
    [stamp ++ "-tap.wav", nil, nil]);
~tEq.("...and is settled", rec.settled, true);
}.value;

// ---- an SA set with drum hits and no tempo ------------------------------------------------
// One strum: a take with too few onsets for any meter (no bpm, no signature),
// logged as the Looper logs it, with Onset notes on, so the onset kit plays
// its hit and nothing in the set has a tempo. The stop still runs to its end,
// and the .mid is written, at 120 BPM in 4/4, under the stamp name.
{
var d = dir +/+ "notempo";
var stub = ~srStub.();
var rec = LooperSessionRecorder(stub, d);
var lead = LooperSessionRecorder.frame0Lead(stub);
var a0, stamp, take, events, filesEv, back;
~srRun.(Routine { rec.start(20, 16, (threshold: 0.5), true) });
stamp = rec.stamp;
~srAge.(rec, 10);
a0 = rec.audioAt;
take = Looper.resultForLog(Looper.snapAnalysisToLoop(MeterAnalyzer.analyze(2.6, [0.0], [0.9]), 3.0));
rec.logEvent(\take, (result: take, applied: true), a0 + 3.0);
rec.logHits([(at: a0 + 3.4, slot: \onset, kind: \onset, note: 36, vel: 70, gate: 0.02, kit: 'o')]);
[\master, \tap].do { |w| ~srTouch.(rec.paths[w], "wav " ++ w) };
~tEq.("(a one-onset take has no tempo, so the set has none)", [take[\error], take[\bpm], rec.chosenTempo],
    [\insufficientOnsets, nil, nil]);
~tCheck.("a set with drum hits and no tempo stops without a throw", { ~srRun.(Routine { rec.stop(true) }); true });
~tEq.("...and runs to its end: settled, its .mid under the stamp name",
    [rec.settled, rec.paths[\midi] !? (_.basename)], [true, stamp ++ "-drums.mid"]);
events = LooperSessionRecorder.readEvents(rec.paths[\events]);
filesEv = events.detect { |e| e[\ev] == "files" } ? ();
~tEq.("...which the files event names, with no tempo and no hint",
    [filesEv[\files] !? { |f| f[\midi] }, filesEv[\tempo], filesEv[\liveHint]], [stamp ++ "-drums.mid", nil, nil]);
back = rec.paths[\midi] !? { |p| LooperMidiFile.read(p) } ? ();
~tEq.("...at 120 BPM (07 A1 20), in 4/4",
    back[\tracks] !? { |t| [t[0].detect { |e| e[\meta] == 0x51 } !? (_[\data]),
        t[0].detect { |e| e[\meta] == 0x58 } !? (_[\data])] },
    [[0x07, 0xA1, 0x20], [4, 2, 24, 8]]);
~tEq.("...its onset on channel 2, where it is in the WAVs at that tempo",
    back[\tracks] !? { |t| t[2].select { |e| e[\status] == 0x90 }.collect { |e| [e[\tick], e[\chan]] } },
    [[LooperMidiFile.tickAt(3.4 + lead, 120), 1]]);
~tEq.("...and a reader of the log finds it", LooperSessionRecorder.sessionPath(events, \midi, rec.paths[\events]),
    d +/+ (stamp ++ "-drums.mid"));
}.value;

// ---- two drums segments, through the stop ------------------------------------------------
// The drums start at 165.04 in 7/8, and a 4/4 reading at 120 lands half a
// minute in: everything the stop decides follows the first, the files' names,
// the hint's bar 1, the .mid's tempo, signature and every tick, the landing's
// hit too, and the landing is a marker.
{
var d = dir +/+ "segments";
var stub = ~srStub.();
var rec = LooperSessionRecorder(stub, d);
var lead = LooperSessionRecorder.frame0Lead(stub);
var a0, stamp, back;
~srRun.(Routine { rec.start(20, 16, nil, true) });
stamp = rec.stamp;
~srAge.(rec, 60);
a0 = rec.audioAt;
rec.logEvent(\drumsStart, (bpm: 165.0412, numerator: 7, denominator: 8, n16: 28, loopDur: 10.1792), a0 + 1.0);
rec.logHits([(at: a0 + 1.0, slot: \steps, kind: \step, note: 36, vel: 100, lane: 0, which: \main, kit: 'k')]);
rec.logEvent(\drumsSegment, (bpm: 120.0, numerator: 4, denominator: 4, n16: 16, loopDur: 2.0), a0 + 30.0);
rec.logHits([(at: a0 + 30.0, slot: \steps, kind: \step, note: 38, vel: 90, lane: 1, which: \main, kit: 'k')]);
[\master, \tap].do { |w| ~srTouch.(rec.paths[w], "wav " ++ w) };
~srRun.(Routine { rec.stop(true) });
~tEq.("two drums segments: every file is named for the first, not the landing",
    [\master, \tap, \events, \midi].collect { |w| rec.paths[w] !? (_.basename) },
    [\master, \tap].collect { |w| stamp ++ "-165.04bpm-7-8-" ++ w ++ ".wav" }
        ++ [stamp ++ "-165.04bpm-7-8-events.jsonl", stamp ++ "-165.04bpm-7-8-drums.mid"]);
~tAssert.("...the hint is the first's, with its bar 1 where the drums started",
    (rec.liveHint ? "").beginsWith("In Live: 165.04 BPM, 7/8. The drums' bar 1 is at 1.001 s"), rec.liveHint);
back = rec.paths[\midi] !? { |p| LooperMidiFile.read(p) } ? ();
~tEq.("...the .mid at the first's tempo and in its signature, the landing a marker",
    back[\tracks] !? { |t| [t[0].detect { |e| e[\meta] == 0x51 } !? (_[\data]),
        t[0].detect { |e| e[\meta] == 0x58 } !? (_[\data]), t[0].select { |e| e[\meta] == 0x06 }.collect(_[\text])] },
    [[0x05, 0x8C, 0x1C], [7, 3, 24, 8], ["drums start 7/8 165.04 BPM", "reading 4/4 120.00 BPM"]]);
~tEq.("...and every note at that tempo, the landing's too",
    back[\tracks] !? { |t| t[1].select { |e| e[\status] == 0x90 }.collect(_[\tick]) },
    [1.0, 30.0].collect { |s| LooperMidiFile.tickAt(s + lead, 165.04) });
}.value;

// ---- a double stomp: two sets of one second ------------------------------------------------
// The stamp has a resolution of one second, and a second set's files must not
// open over the first's while they are still being written.
{
var d = dir +/+ "double";
var stub = ~srStub.();
var rec = LooperSessionRecorder(stub, d);
var s0;
File.mkdir(d);
s0 = Date.getDate.stamp;
~srTouch.(d +/+ (s0 ++ "-master.wav"), "the first set's");
~srRun.(Routine { rec.start(0, 16, nil, true) });
// (Should the clock have passed into the next second meanwhile, that stamp is
// fresh anyway: either way never the taken one.)
~tAssert.("a set started in the same second as one already in the folder takes -2",
    (rec.stamp != s0) and: { rec.stamp.beginsWith(s0).not or: { rec.stamp == (s0 ++ "-2") } }, "got " ++ rec.stamp);
~tEq.("...so none of its files is the first set's", rec.paths.values.asArray.any { |p| p.basename.beginsWith(s0 ++ "-master") }, false);
~srRun.(Routine { rec.stop(true) });
~tEq.("...which is untouched", File.readAllString(d +/+ (s0 ++ "-master.wav")), "the first set's");
}.value;

// ---- a stop in the start's gap -------------------------------------------------------------
// A start is asynchronous (its buffers are opened before any synth exists);
// a stop that arrives meanwhile must start nothing, close each buffer once,
// and wait for the start to let go before it renames anything.
{
var stub = ~srStub.();
var rec, r1, r2;
stub[\sync] = { |self| 0.01.wait; self };
rec = LooperSessionRecorder(stub, dir +/+ "gap");
r1 = Routine { rec.start(0, 16, nil, true) };
r1.next;
r2 = Routine { rec.stop(true) };
~tEq.("the stop waits while the start is still opening its files", r2.next, 0.05);
~srRun.(r1);
~srRun.(r2);
~tEq.("a stop in the start's gap starts no synth", stub[\bundles].count { |b| b[1].any { |m| m[0] == 9 } }, 0);
~tEq.("...closes each buffer once", stub[\msgs].count { |m| m[0].asString.contains("b_close") }, 2);
~tEq.("...and there is no frame 0", rec.audioAt, nil);
~srRun.(Routine { rec.start(0, 16, nil, true) });
~tEq.("a start after it is a set of its own, with its synths", [rec.recording,
    stub[\bundles].count { |b| b[1].any { |m| m[0] == 9 } }], [true, 1]);
~srRun.(Routine { rec.stop(true) });
}.value;

// ---- a stop inside the start's latency ------------------------------------------------------
// A double press: the start's bundle is out, stamped 0.2 s ahead, and the stop
// comes before that moment. Its frees must come after the start's in the
// server's queue, or they find no node and the DiskOuts run on, writing into
// the next set's buffers; stamped the same latency after the stop, they never
// come before.
{
var stub = ~srStub.();
var rec = LooperSessionRecorder(stub, dir +/+ "inside");
var starts, frees;
~srRun.(Routine { rec.start(0, 16, nil, true) });
~srRun.(Routine { rec.stop(true) });
starts = stub[\bundles].detect { |b| b[1].any { |m| m[0] == 9 } };
frees = stub[\bundles].detect { |b| b[1].any { |m| m[0] == 11 } };
~tAssert.("(a start and its stop at once)", starts.notNil and: { frees.notNil });
~tAssert.("a stop inside the start's latency frees the synths no earlier than they start, and after them in the queue",
    (starts.notNil and: { frees.notNil }) and: { frees[0] >= starts[0] }
        and: { stub[\bundles].indexOf(frees) > stub[\bundles].indexOf(starts) },
    [starts !? (_[0]), frees !? (_[0])]);
~tEq.("...every one of them", frees !? { |b| b[1].collect(_[1]) }, starts !? { |b| b[1].collect(_[2]) });
}.value;

// ---- a set started while the last one's tail is open ------------------------------------------
// PC 20 twice in quick succession: the stopped set's log is still open (its
// WAVs have not ended yet). The new set takes the log; the stopped one is
// ended there and then with what it had been told, and its files, names and
// .mid finish as ever: its own hits and markers in its .mid, none of the new
// set's, which go to new lists (never the old ones emptied: the stopped set
// still holds those until its .mid is written).
{
var d = dir +/+ "restart";
var stub = ~srStub.();
var rec = LooperSessionRecorder(stub, d);
var lead = LooperSessionRecorder.frame0Lead(stub);
var rA, stampA, a0, b0, eventsA, listsA, back, notes, marks, filesA;
~srRun.(Routine { rec.start(20, 16, nil, true) });
stampA = rec.stamp;
~srAge.(rec, 30);
a0 = rec.audioAt;
rec.logEvent(\drumsStart, (bpm: 120.0, numerator: 4, denominator: 4), a0 + 1.0);
rec.logHits([(at: a0 + 1.0, slot: \steps, kind: \step, note: 36, vel: 100, lane: 0),
    (at: a0 + 1.5, slot: \steps, kind: \step, note: 42, vel: 90, lane: 1)]);
[\master, \tap].do { |w| ~srTouch.(rec.paths[w], "A " ++ w) };
eventsA = rec.paths[\events];
listsA = [rec.loggedHits, rec.markers];
rA = Routine { rec.stop(true) };
rA.next;
~tEq.("(the stopped set's log still open)", rec.logging, true);
~srRun.(Routine { rec.start(20, 16, nil, true) });
~tAssert.("the new set has a stamp of its own", rec.stamp != stampA, rec.stamp);
~tEq.("the stopped set's log was ended at the new start: files, then sessionStop",
    LooperSessionRecorder.readEvents(eventsA).keep(-2).collect(_[\ev]), ["files", "sessionStop"]);
filesA = LooperSessionRecorder.readEvents(eventsA).detect { |e| e[\ev] == "files" } ? ();
~tEq.("...naming its own files, with its own tempo", filesA[\files] !? { |f| [f[\master], f[\midi]] },
    [stampA ++ "-120.00bpm-4-4-master.wav", stampA ++ "-120.00bpm-4-4-drums.mid"]);
~tEq.("the new set's hits and markers are new lists, not the stopped set's emptied",
    [rec.loggedHits !== listsA[0], rec.markers !== listsA[1], rec.loggedHits.size, rec.markers.size], [true, true, 0, 0]);
b0 = rec.audioAt;
rec.logEvent(\drumsStart, (bpm: 90.0, numerator: 3, denominator: 4), b0 + 0.01);
rec.logHits([(at: b0 + 0.01, slot: \steps, kind: \step, note: 38, vel: 80, lane: 2)]);
~srRun.(rA);
back = LooperMidiFile.read(d +/+ (stampA ++ "-120.00bpm-4-4-drums.mid"));
notes = back[\tracks] !? { |t| t[1].select { |e| e[\status] == 0x90 }.collect { |e| [e[\tick], e[\note]] } };
marks = back[\tracks] !? { |t| t[0].select { |e| e[\meta] == 0x06 }.collect(_[\text]) };
~tEq.("the stopped set's .mid holds its own notes, none of the new set's", notes,
    [[1.0, 36], [1.5, 42]].collect { |n| [LooperMidiFile.tickAt(n[0] + lead, 120), n[1]] });
~tEq.("...and its own markers", marks, ["drums start 4/4 120.00 BPM"]);
~tEq.("...and its WAVs have their names", [\master, \tap].collect { |w|
    File.exists(d +/+ (stampA ++ "-120.00bpm-4-4-" ++ w ++ ".wav")) }, [true, true]);
~tEq.("the new set records on, holding only its own",
    [rec.recording, rec.logging, rec.loggedHits.collect(_[\note]).asArray, rec.markers.collect(_[\text]).asArray],
    [true, true, [38], ["drums start 3/4 90.00 BPM"]]);
[\master, \tap].do { |w| ~srTouch.(rec.paths[w], "B " ++ w) };
~srRun.(Routine { rec.stop(true) });
}.value;

// ---- the WAVs' clock -----------------------------------------------------------------------------
// The interface's crystal is not the Mac's clock, and the WAVs are on the
// crystal. Once the server has closed them, the stop reads how many frames it
// wrote between the two stamped bundles and places the .mid's notes by that:
// at 20 ppm a set's last notes would otherwise be 24 ms off its stems by
// minute twenty.
{
var cls = LooperSessionRecorder;
var d = dir +/+ "clock";
var stub = ~srStub.();
var rec = LooperSessionRecorder(stub, d);
var lead = cls.frame0Lead(stub), frames = 96150, a0, rate, back, notes, filesEv;
var wav = { |path, n, chans|
    var sf = SoundFile.new.headerFormat_("WAV").sampleFormat_("int24").numChannels_(chans).sampleRate_(48000);
    sf.openWrite(path);
    sf.writeData(FloatArray.newClear(n * chans));
    sf.close;
};
~tNear.("frame 0 is expected half a block before audioAt, less half a sample", lead, 31.5 / 48000, 1e-12);
~tNear.("a moment's place in the WAVs: from audioAt, at the clock's rate, after the lead",
    cls.wavTime(1210.0, 10.0, (rate: 1 + 20e-6, lead: lead)), (1200 * (1 + 20e-6)) + lead, 1e-9);
~tEq.("...with no clock, from audioAt", cls.wavTime(12.5, 10.0, nil), 2.5);
~tNear.("twenty minutes at 20 ppm: 1152 frames more than 48 kHz, and the rate says so",
    cls.clockRate(57601152, 0, 1200, 48000) ? 0, 1 + 20e-6, 1e-12);
~tEq.("a length a block off either way is still a rate (each end is the start of a block)",
    [cls.clockRate(57600064, 0, 1200, 48000).notNil, cls.clockRate(57599936, 0, 1200, 48000).notNil], [true, true]);
~tEq.("a file cut short, no length, no span: no rate",
    [cls.clockRate(57000000, 0, 1200, 48000), cls.clockRate(nil, 0, 1200, 48000), cls.clockRate(100, 5, 5, 48000)],
    [nil, nil, nil]);
~tEq.("what the stop says", cls.clockSentence(1 + 20e-6, 57601152, 0, 1200, 48000),
    "The interface's clock ran +20.0 ppm against the Mac's (to 1.1 ppm, from the WAVs' 57601152 frames); the .mid follows it.");
// A two-second set whose WAVs are real files, 150 frames longer than 48 kHz
// would be: its step 1.9 s in is where that clock puts it. Its master was cut
// short (a disk that could not keep up), the first file the stop reads: the
// clock comes from the longest, the tap, all a set's WAVs being as long.
~srRun.(Routine { rec.start(20, 16, nil, true) });
~srAge.(rec, 2);
a0 = rec.audioAt;
rec.logEvent(\drumsStart, (bpm: 120.0, numerator: 4, denominator: 4), a0);
rec.logHits([(at: a0 + 1.9, slot: \steps, kind: \step, note: 36, vel: 100, lane: 0)]);
wav.(rec.paths[\master], frames - 32768, 2);
wav.(rec.paths[\tap], frames, 1);
~srRun.(Routine { rec.stop(true) });
rate = frames / ((rec.stopAt - a0) * 48000);
~tNear.("(a two-second set)", rec.stopAt - a0, 2.0, 1e-6);
~tEq.("the stop read the WAVs' length: the longest, a master cut short not taken for the clock", rec.wavFrames, frames);
~tNear.("...and the clock from it", rec.clockRate ? 0, rate, 1e-12);
back = LooperMidiFile.read(rec.paths[\midi]);
notes = back[\tracks] !? { |t| t[1].select { |e| e[\status] == 0x90 }.collect(_[\tick]) };
~tEq.("the step is in the .mid where that clock puts it in the WAVs", notes, [LooperMidiFile.tickAt((1.9 * rate) + lead, 120)]);
~tAssert.("...which is not where the Mac's clock would", notes != [LooperMidiFile.tickAt(1.9 + lead, 120)], notes);
filesEv = LooperSessionRecorder.readEvents(rec.paths[\events]).detect { |e| e[\ev] == "files" } ? ();
~tEq.("the files event has the length and the clock", [filesEv[\frames], filesEv[\clockPpm]],
    [frames, ((rate - 1) * 1e6).round(0.01)]);
~tNear.("...and how closely a set this long can tell it: a block over its length",
    filesEv[\clockPpmRes], (64 / 96000) * 1e6, 0.051);
}.value;

// ---- one recorder, three sets ----------------------------------------------------------------
// The Looper keeps one recorder all evening (Looper.sessionRec), so whatever a
// set's end is decided from starts empty with every set — the hits, the
// markers, the drums' segments, the analysis that applied — and so does what
// the last set's stop decided and measured. Set A: the drums at 165.04 in 7/8
// over a 4/4 loop at 120, its WAVs real files whose length is read. Set B: no
// drums, a take in 7/8 at 100, no hit. Set C: a take in 3/4 at 90, one onset.
{
var d = dir +/+ "evening";
var stub = ~srStub.();
var rec = LooperSessionRecorder(stub, d);
var lead = LooperSessionRecorder.frame0Lead(stub);
var wav = { |path, n, chans|
    var sf = SoundFile.new.headerFormat_("WAV").sampleFormat_("int24").numChannels_(chans).sampleRate_(48000);
    sf.openWrite(path);
    sf.writeData(FloatArray.newClear(n * chans));
    sf.close;
};
var a0, stampA, stampB, stampC, back;
~srRun.(Routine { rec.start(20, 16, (loop: (numerator: 4, denominator: 4, bpm: 120.0)), true) });
stampA = rec.stamp;
~srAge.(rec, 2);
a0 = rec.audioAt;
rec.logEvent(\drumsStart, (bpm: 165.0412, numerator: 7, denominator: 8, n16: 28, loopDur: 10.1792), a0 + 0.5);
rec.logHits([(at: a0 + 0.5, slot: \steps, kind: \step, note: 36, vel: 100, lane: 0, which: \main, kit: 'k')]);
rec.logEvent(\breakStart, (), a0 + 1.0);
wav.(rec.paths[\master], 96150, 2);
wav.(rec.paths[\tap], 96150, 1);
~srRun.(Routine { rec.stop(true) });
~tEq.("(set A: named for its drums, with its .mid, the length of its WAVs read and a clock from it)",
    [rec.paths[\master].basename, rec.paths[\midi] !? (_.basename), rec.wavFrames, rec.clockRate.notNil],
    [stampA ++ "-165.04bpm-7-8-master.wav", stampA ++ "-165.04bpm-7-8-drums.mid", 96150, true]);

~srRun.(Routine { rec.start(20, 16, (threshold: 0.5), true) });
stampB = rec.stamp;
~tEq.("a second set on the same recorder begins with nothing of the first's to decide from: no hits, markers, drums segments or analysis",
    [rec.loggedHits.size, rec.markers.size, rec.drumsTempos.size, rec.analysisTempo, rec.chosenTempo], [0, 0, 0, nil, nil]);
~tEq.("...and with none of the first's end: no tempo, hint or final names, no stop, no WAV length or clock",
    [rec.tempoInfo, rec.liveHint, rec.finalPaths, rec.stoppedAt, rec.stopAt, rec.wavFrames, rec.clockRate, rec.settled],
    [nil, nil, nil, nil, nil, nil, nil, true]);
~srAge.(rec, 30);
rec.logEvent(\take, (result: (numerator: 7, denominator: 8, k: 2, bpm: 100.0), applied: true));
[\master, \tap].do { |w| ~srTouch.(rec.paths[w], "B " ++ w) };
~srRun.(Routine { rec.stop(true) });
~tEq.("...named for its own take, not for the first set's drums or loop",
    [\master, \tap, \events].collect { |w| rec.paths[w].basename },
    [stampB ++ "-100.00bpm-7-8-master.wav", stampB ++ "-100.00bpm-7-8-tap.wav", stampB ++ "-100.00bpm-7-8-events.jsonl"]);
~tEq.("...with its own hint", rec.liveHint, "In Live: 100.00 BPM, 7/8. Drop the files at 1.1.1.");
~tEq.("...and no .mid: it had no drum hit, and the first set's are not its",
    [rec.finalPaths[\midi], (LooperSessionRecorder.globQuote(d) +/+ (stampB ++ "-*.mid")).pathMatch], [nil, []]);

~srRun.(Routine { rec.start(20, 16, (threshold: 0.5), true) });
stampC = rec.stamp;
~srAge.(rec, 20);
rec.logEvent(\take, (result: (numerator: 3, denominator: 4, k: 1, bpm: 90.0), applied: true));
rec.logHits([(at: rec.audioAt + 3.0, slot: \onset, kind: \onset, note: 38, vel: 70, gate: 0.02, kit: 'o')]);
[\master, \tap].do { |w| ~srTouch.(rec.paths[w], "C " ++ w) };
~srRun.(Routine { rec.stop(true) });
back = rec.paths[\midi] !? { |p| LooperMidiFile.read(p) } ? ();
~tEq.("a third set's .mid: its own name and tempo, its one onset, and no step or marker of the first set's",
    [rec.paths[\midi] !? (_.basename), back[\tracks] !? { |t| [t[0].select { |e| e[\meta] == 0x06 }.collect(_[\text]),
        t[1].count { |e| e[\status] == 0x90 }, t[2].select { |e| e[\status] == 0x90 }.collect(_[\tick])] }],
    [stampC ++ "-90.00bpm-3-4-drums.mid", [[], 0, [LooperMidiFile.tickAt(3.0 + lead, 90)]]]);
}.value;

// ---- a sessions folder named with glob's characters -------------------------------------------
{
var d = dir +/+ "Gigs [2026] back\\slash";
var base = SystemClock.seconds - 100;
var w = LooperSessionRecorder(nil, d);
var log = d +/+ "261001_090000-120.00bpm-4-4-events.jsonl";
File.mkdir(d);
w.instVarPut(\startedAt, base);
w.prOpenLog(log);
w.logEvent(\session, (stamp: "261001_090000"), base);
w.prCloseLog;
~srTouch.(d +/+ "261001_090000-120.00bpm-4-4-tap.wav", "tap");
~tEq.("in a folder named with [ ] and a backslash, a renamed set is found by its stamp",
    LooperSessionRecorder.findEvents(d, "261001_090000"), log);
~tEq.("...and its tap by stamp and role",
    LooperSessionRecorder.sessionPath(LooperSessionRecorder.readEvents(log), \tap, log),
    d +/+ "261001_090000-120.00bpm-4-4-tap.wav");
~tEq.("...and a second set of that second gets -2", LooperSessionRecorder.freshStamp(d, "261001_090000"),
    "261001_090000-2");
}.value;

// ---- readers: old sets and renamed ones ----------------------------------------------------
{
var d = dir +/+ "readers";
var base = SystemClock.seconds - 100;
var log = { |path, lines|
    var w = LooperSessionRecorder(nil, d);
    w.instVarPut(\startedAt, base);
    w.prOpenLog(path);
    lines.do { |l| w.logEvent(l[0], l[1], base + l[2]) };
    w.prCloseLog;
};
var events;
File.mkdir(d);
// An old set: stamp names, no files event, the paths in its header.
~srTouch.(d +/+ "260928_183000-tap.wav", "old tap");
log.(d +/+ "260928_183000-events.jsonl", [[\session, (stamp: "260928_183000", tap: d +/+ "260928_183000-tap.wav"), 0],
    [\sessionStop, (), 5]]);
~tEq.("an old set is found by its stamp", LooperSessionRecorder.findEvents(d, "260928_183000"), d +/+ "260928_183000-events.jsonl");
events = LooperSessionRecorder.readEvents(d +/+ "260928_183000-events.jsonl");
~tEq.("...its tap by the header's path", LooperSessionRecorder.sessionPath(events, \tap, d +/+ "260928_183000-events.jsonl"),
    d +/+ "260928_183000-tap.wav");
~tEq.("...and no MIDI file, which old sets never had",
    LooperSessionRecorder.sessionPath(events, \midi, d +/+ "260928_183000-events.jsonl"), nil);
// A set moved to another folder: its header points where it was.
~srTouch.(d +/+ "260929_100000-tap.wav", "moved tap");
log.(d +/+ "260929_100000-events.jsonl", [[\session, (stamp: "260929_100000", tap: "/nowhere/260929_100000-tap.wav"), 0]]);
events = LooperSessionRecorder.readEvents(d +/+ "260929_100000-events.jsonl");
~tEq.("a set moved to another folder: its tap beside its log",
    LooperSessionRecorder.sessionPath(events, \tap, d +/+ "260929_100000-events.jsonl"), d +/+ "260929_100000-tap.wav");
// A renamed set whose log names nothing but its stamp, beside a second set
// of the same second.
~srTouch.(d +/+ "261001_090000-120.00bpm-4-4-tap.wav", "renamed tap");
~srTouch.(d +/+ "261001_090000-2-120.00bpm-4-4-tap.wav", "the second set's tap");
log.(d +/+ "261001_090000-120.00bpm-4-4-events.jsonl",
    [[\session, (stamp: "261001_090000", tap: d +/+ "261001_090000-tap.wav"), 0]]);
~tEq.("a renamed set is found by its stamp",
    LooperSessionRecorder.findEvents(d, "261001_090000"), d +/+ "261001_090000-120.00bpm-4-4-events.jsonl");
events = LooperSessionRecorder.readEvents(d +/+ "261001_090000-120.00bpm-4-4-events.jsonl");
~tEq.("...and its tap by stamp and role, not the second set's",
    LooperSessionRecorder.sessionPath(events, \tap, d +/+ "261001_090000-120.00bpm-4-4-events.jsonl"),
    d +/+ "261001_090000-120.00bpm-4-4-tap.wav");
~tEq.("a set that is not there is nil", LooperSessionRecorder.findEvents(d, "261231_235959"), nil);
}.value;
~tRemoveTree.(dir);
}.value;
