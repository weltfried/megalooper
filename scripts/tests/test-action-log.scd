// Log every action (MegaActionLog, setup-actions.scd): what is heard, what is
// written and when, what a knob turned costs in lines, whose a change was,
// and a part's state once it has settled. A fake clock and scheduler for the
// rules; a real LooperSessionRecorder writing a real file for the lines; the
// real Looper, MegaSA and drums (on a stub server) for the wiring.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-action-log");

{
var t = 100.0, due = List.new, now = { t }, sched, until, rec, written, batches, model, other, log, aiNow;
var makeLog = { |parts|
    var l = MegaActionLog(parts, { rec }, { aiNow }, now, sched);
    l.player = { |r| r.do {} };
    l
};
// What is due runs in time order, the clock moved to each, up to `to`.
sched = { |delta, fn| due.add([t + delta, fn]) };
until = { |to|
    var next;
    while { next = due.asArray.sort { |a, b| a[0] <= b[0] }.first; next.notNil and: { next[0] <= to } } {
        due.remove(next);
        t = next[0];
        next[1].value;
    };
    t = to;
};
written = List.new;
batches = 0;
rec = (logging: true,
    logEvents: { |self, list| batches = batches + 1; written.addAll(list) },
    logEvent: { |self, ev, f| written.add([ev, f, t]) });
model = Object.new;
other = Object.new;

// ---- what is heard, and when it is written -------------------------------------
log = makeLog.((knobs: (model: model), pads: (model: other)));
model.changed(\morph, 0.4);
~tEq.("off: a part's change is not heard", [due.size, log.recent.size], [0, 0]);
log.start;
model.changed(\morph, 0.4);
~tEq.("on: a change waits for the batch, written a tenth of a second later", [written.size, due.size], [0, 1]);
until.(t + 0.1);
~tEq.("...in one batch: an act line with its part, what and the value, at the change's time",
    [batches, written.collect(_[0]), written[0][1], written[0][2]], [1, [\act], [\args, [0.4], \part, \knobs, \what, \morph], 100.0]);

// A knob turned: 60 changes a second, ten lines a second, the newest value at its own time.
written.clear; batches = 0;
60.do { |i| until.(t + (1/60)); model.changed(\morph, i / 60) };
until.(t + 0.1);
~tEq.("a knob turned for a second: ten lines or eleven, one batch each, the last the newest value",
    [(written.size >= 10) and: { written.size <= 11 }, batches == written.size, written.last[1][1]], [true, true, [59 / 60]]);
~tEq.("...in time order", written.collect(_[2]) == written.collect(_[2]).copy.sort, true);

// Two controls at once are two lines; one changed twice is one, the newer.
written.clear;
model.changed(\level, \loop, 0.5);
model.changed(\level, \drums, 0.6);
model.changed(\level, \loop, 0.7);
until.(t + 0.1);
~tEq.("two strips: two lines, the loop's newer value kept",
    written.collect { |w| w[1][1] }.asArray.sort { |a, b| a[0].asString <= b[0].asString }, [[\drums, 0.6], [\loop, 0.7]]);

// A name last says which, not to what: both patterns changed at once are two.
written.clear;
other.changed(\steps, \main);
other.changed(\steps, \break);
other.changed(\kit, \steps, 'core-909');
other.changed(\kit, \steps, 'core-808');
until.(t + 0.1);
~tEq.("both patterns' bulk changes are two lines, and a kit named twice is two",
    written.collect { |w| w[1][1] }.asArray.sort { |a, b| a.asString <= b.asString },
    [[\break], [\main], [\steps, 'core-808'], [\steps, 'core-909']]);
log.stop;

// ---- skip, bare, logged, ids ------------------------------------------------------
written.clear;
log = makeLog.((knobs: (model: model, skip: #[\lamp], bare: #[\voices], logged: #[\fx], ids: (lane: 1))));
log.start;
model.changed(\lamp, 0.9);
model.changed(\voices, [(proc: \warp), (proc: \stutter)]);
model.changed(\fx, \delay, true);
model.changed(\lane, 2, \note, 36);
model.changed(\lane, 2, \note, 38);
until.(t + 0.1);
~tEq.("skipped: neither written nor kept", log.recent.any { |e| e[2] == \lamp }, false);
~tEq.("bare: written without its arguments", written.detect { |w| w[1].includes(\voices) } !? { |w| w[1] },
    [\part, \knobs, \what, \voices]);
~tEq.("logged elsewhere: kept for the AI, not written",
    [log.recent.any { |e| e[2] == \fx }, written.any { |w| w[1].includes(\fx) }], [true, false]);
~tEq.("ids: a lane's settings coalesce per lane, whatever the name before the value",
    written.select { |w| w[1].includes(\lane) }.collect { |w| w[1][1] }, [[2, \note, 38]]);

// ---- whose -------------------------------------------------------------------------
written.clear;
aiNow = "ai";
model.changed(\morph, 0.2);
aiNow = nil;
until.(t + 0.1);
~tEq.("a change made while an AI app is answered says by: ai", written[0][1], [\args, [0.2], \by, "ai", \part, \knobs, \what, \morph]);

// ---- the recent ones, for the AI -------------------------------------------------------
~tEq.("recentWithin: seconds ago, part, what, args, by",
    log.recentWithin(5).last.drop(1), [\knobs, \morph, [0.2], "ai"]);
t = t + 120;
~tEq.("...and only within the time asked", log.recentWithin(60).size, 0);
MegaActionLog.keep.do { |i| model.changed(("c" ++ i).asSymbol, i); until.(t + 0.1) };
~tEq.("at most `keep` are kept", log.recent.size, MegaActionLog.keep);

// ---- stopped, or no set recording ----------------------------------------------------------
written.clear;
model.changed(\morph, 0.3);
log.stop;
~tEq.("stop writes what waited", written.size, 1);
model.changed(\morph, 0.31);
until.(t + 0.2);
~tEq.("...and listens no more", written.size, 1);
rec[\logging] = false;
written.clear;
log = makeLog.((knobs: (model: model, state: { (knobs: (morph: 0.5)) })));
log.start;
model.changed(\morph, 0.6);
until.(t + 5);
~tEq.("no set recording: nothing written, no state, but kept for the AI",
    [written.size, log.recent.size], [0, 1]);
log.stop;
rec[\logging] = true;

// ---- a part's state, once it has settled ----------------------------------------------------
written.clear;
log = makeLog.((knobs: (model: model, state: { (knobs: (morph: 0.5)) }), pads: (model: other)));
log.start;
model.changed(\morph, 0.6);
until.(t + 1.5);
model.changed(\morph, 0.7);
until.(t + 1.9);
~tEq.("no state while the part keeps changing (1.5 s, then another change, 1.9 s later)",
    written.count { |w| w[0] == \state }, 0);
until.(t + 0.3);
~tEq.("...one, two seconds after its last change: the part and its state as JSON",
    written.select { |w| w[0] == \state }.collect { |w| [w[1][0], w[1][1], w[1][2], w[1][3].value] },
    [[\part, \knobs, \state, "{\"knobs\": {\"morph\": 0.5}}"]]);
other.changed(\morph, 1);
until.(t + 3);
~tEq.("a part with no state writes none", written.count { |w| w[0] == \state }, 1);
written.clear;
log.writeStates;
~tEq.("writeStates: every part with a state (a set has started)",
    written.collect { |w| w[1][1] }, [\knobs]);
log.stop;
}.value;

// ---- the lines, as the recorder writes them ----------------------------------------------------
{
var dir = ~tTempPath.("action-log-lines"), path, rec, lines, pauses = 0, s;
File.mkdir(dir);
path = dir +/+ "set-events.jsonl";
rec = LooperSessionRecorder(nil, dir);
rec.prOpenLog(path);
rec.logEvents([[\act, [\args, [\loop, 0.5], \part, \sa, \what, \level], nil],
    [\state, [\part, \drums, \state, Ref("{\"drums\": {\"on\": true}}")], nil]]);
lines = File.readAllString(path).split($\n).reject(_.isEmpty);
~tEq.("an act line: its pairs in their order", lines[0].copyToEnd(lines[0].find("\"ev\"")),
    "\"ev\": \"act\", \"args\": [\"loop\", 0.5], \"part\": \"sa\", \"what\": \"level\"}");
~tEq.("a state line: a Ref's JSON put in as it is", lines[1].copyToEnd(lines[1].find("\"ev\"")),
    "\"ev\": \"state\", \"part\": \"drums\", \"state\": {\"drums\": {\"on\": true}}}");
rec.instVarAt(\logFile).close;
rec.instVarPut(\logFile, nil);
~tEq.("no log open: logEvents says so", rec.logEvents([[\act, [\what, \x], nil]]), false);
s = CollStream(String.new);
LooperSessionRecorder.jsonOn(s, (a: [1, 2], b: (c: "q\"t")), { pauses = pauses + 1 });
~tEq.("jsonOn: the same text, with a pause after every member", [s.contents, pauses],
    ["{\"a\": [1, 2], \"b\": {\"c\": \"q\\\"t\"}}", 3]);
~tEq.("...and as json gives it", LooperSessionRecorder.json((a: [1, 2], b: (c: "q\"t"))), s.contents);
}.value;

// ---- the wiring: the real parts --------------------------------------------------------------------
{
var l = ~tLooper.(), m = ~tMegaSA.(), d = m.drums, dir = ~tTempPath.("action-log-wiring"), path, rec, log, acts, remote, answer, before;
(Looper.repoRoot +/+ "scripts" +/+ "setup-actions.scd").load;
~looper = l;
~megaSA = m;
File.mkdir(dir);
path = dir +/+ "set-events.jsonl";
rec = LooperSessionRecorder(nil, dir);
rec.prOpenLog(path);
log = MegaActionLog(~actionsParts.(), { rec }, { if(MegaRemote.applying.notNil) { "ai" } });
log.player = { |r| r.do {} };
log.start;
m.setFxParam(\delayMix, 0.25);
m.setLevel(\loop, 0.5);
l.granularMorph = 0.75;
d.setStep(\main, \chance, 0, 3, 5);
log.prFlush;
acts = File.readAllString(path).split($\n).reject(_.isEmpty).collect { |x| MegaRemote.plain(MegaFiles.parseObject(x)) };
~tEq.("an effect's setting, a strip's level, the grains' morph and a drum step, as the parts say them",
    acts.collect { |a| [a[\part], a[\what]] }.asArray.sort { |a, b| a.asString <= b.asString },
    [["drums", "step"], ["looper", "granularMorph"], ["sa", "fxSetting"], ["sa", "level"]]);
~tEq.("...the effect's setting with its device, name and value",
    acts.detect { |a| a[\what] == "fxSetting" } !? { |a| a[\args] }, ["delay", "delayMix", 0.25]);
~tEq.("...and every one the players'", acts.any { |a| a[\by].notNil }, false);
~tEq.("SA's own fx line is not doubled: a switch is logged by setup-sa.scd, kept here for the AI",
    MegaActionLog.new(~actionsParts.()).parts[\sa][\logged].includes(\fx), true);
// An AI app's change: the grains' morph through MegaRemote, which sets the
// grains as a whole (each setting it puts says so).
remote = MegaRemote({ (looper: l, sa: m) });
before = File.readAllString(path).split($\n).reject(_.isEmpty).size;
answer = remote.handle("{\"command\": \"set_grains\", \"args\": {\"settings\": {\"morph\": 0.1}}}");
log.prFlush;
acts = File.readAllString(path).split($\n).reject(_.isEmpty).drop(before).collect { |x| MegaRemote.plain(MegaFiles.parseObject(x)) };
~tEq.("an AI app's change is written by: ai, the morph among them",
    [answer.at("ok"), acts.detect { |a| a[\what] == "granularMorph" } !? { |a| a[\args] }, acts.collect { |a| a[\by] }.asSet.asArray],
    [true, [0.1], ["ai"]]);
~tEq.("...and the request over, the next is the players' again", MegaRemote.applying, nil);
// The states, as a set's first lines.
log.writeStates;
acts = File.readAllString(path).split($\n).reject(_.isEmpty).collect { |x| MegaRemote.plain(MegaFiles.parseObject(x)) }
    .select { |a| a[\ev] == "state" };
~tEq.("writeStates: the drums (with the synth), the Looper, SA and the Wave synth",
    acts.collect { |a| a[\part] }.asArray.sort, ["drums", "looper", "sa", "wave"]);
~tEq.("...each holding what it says", acts.collect { |a| a[\state].keys.asArray.collect(_.asString).sort }.asArray
    .sort { |a, b| a.asString <= b.asString }, [["chains", "mixer"], ["cutter", "grains", "looper"], ["drums", "synth"], ["synth"]]);
~tEq.("...the drums' step as set", acts.detect { |a| a[\part] == "drums" } !? { |a|
    a[\state][\drums][\patterns][\main][\steps][\chance][0][3] }, 5);
log.stop;
acts = File.readAllString(path).split($\n).reject(_.isEmpty).size;
m.setLevel(\loop, 0.9);
log.prFlush;
~tEq.("stopped: a change is heard no more", File.readAllString(path).split($\n).reject(_.isEmpty).size, acts);
rec.instVarAt(\logFile).close;
}.value;
