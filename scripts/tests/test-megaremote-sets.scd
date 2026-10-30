// What the AI sees beyond the settings (docs/dev/roadmap.md item 20, "the AI
// as the experimenter"): in the context, how the bars are grouped, where the
// playhead is and what is about to land (`now`), and its own changes by
// label; the drums' description as their Retrig stands; and the sets recorded
// before, read only: list_sets and get_set over a folder of two logs written
// here, as LooperSessionRecorder writes them.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-megaremote-sets");

{
var ask = { |remote, text| MegaFiles.parseObject(MegaFiles.json(remote.handle(text))) };
var dir = ~tTempPath.("remote-sets"), l, r, got, o, take, r78, json78, json148, lines, events;
File.mkdir(dir);

// ---- the context ---------------------------------------------------------------
// Two bars of 7/8 at 120 (an eighth 0.25 s), 1.1 s into a pass.
r78 = (numerator: 7, denominator: 8, tau: 0.25, sub: 1, k: 2, loopDur: 3.5, bpm: 120, n: 14, phase: 0, accent: 0.6234);
l = ~tLooper.();
~tPut.(l, \state, \playing);
~tPut.(l, \loopFrames, (3.5 * 48000).asInteger);
~tPut.(l, \lastResult, r78);
~tPut.(l, \loopStartTime, SystemClock.seconds - 1.1);
r = MegaRemote({ (looper: l, sa: nil, profile: \sa, sessionDir: dir) });
got = ask.(r, "{\"command\": \"context\"}").at("result");
~tEq.("the reading says how each bar is grouped: 2+2+3 in 7/8", got.at("loop").at("reading").at("groups"),
    [[2, 2, 3], [2, 2, 3]]);
~tEq.("...how its loud hits fit the meter's strong beats, as the analyser scored it",
    [got.at("loop").at("reading").at("accentFit"), got.at("loop").at("reading").at("barLineAccent")], [0.623, nil]);
~tEq.("...for uneven bars, the bar lines against the mean hit; none for bars given by hand or a fallback",
    [MegaRemote.accentOf(r78.copy.putAll((bars: [7, 7, 7, 8], accent: 1.347))),
        MegaRemote.accentOf(r78.copy.put(\from, \hand)), MegaRemote.accentOf(r78.copy.put(\error, \lengthAnchored))],
    [[\barLineAccent, 1.35], [], []]);
o = got.at("now");
~tEq.("now: 1.1 s in, bar 1, beat 5, the third group's first beat, at full speed",
    [o.at("playing"), o.at("bar"), o.at("beat"), o.at("group"), o.at("groupBeat"), o.at("halfTime"), o.at("speed")],
    [true, 1, 5, 3, 1, "off", 1]);
~tEq.("...the arc and the break as they stand", [o.at("intensity"), o.at("onBreak"), o.at("dissolving")],
    [l.intensity, false, false]);
~tEq.("...and its own changes, by label: none yet", got.at("aiChangeLabels"), []);
~tPut.(l, \nextRecState, \armed);
o = ask.(r, "{\"command\": \"context\"}").at("result").at("now").at("coming");
~tEq.("what is coming: the next loop's recording, on the boundary 2.4 s away",
    [o.size, o[0].at("what"), (o[0].at("inSeconds") - 2.4).abs < 0.05], [1, "recordNextLoop", true]);
~tPut.(l, \nextRecState, \idle);
r = MegaRemote({ (looper: l, sa: nil, playhead: { 2.0 }) });
o = ask.(r, "{\"command\": \"context\"}").at("result").at("now");
~tEq.("...from the window's playhead where there is one: 2 s in is bar 2's second beat",
    [o.at("bar"), o.at("beat"), o.at("group"), o.at("groupBeat")], [2, 2, 1, 2]);
~tPut.(l, \state, \stopped);
o = ask.(r, "{\"command\": \"context\"}").at("result").at("now");
~tEq.("...stopped, no playhead to say", [o.at("playing"), o.at("bar"), o.at("coming")], [false, nil, []]);

// ---- the drums' bar lines, as Retrig stands --------------------------------------------
~tAssert.("the drums' description: lanes restart at every bar line with Retrig on, the default",
    MegaRemote.describeDrums((retrigAt: \barLine)).at("about").contains("restart at every bar line"), "");
~tAssert.("...and run on across them with it off", MegaRemote.describeDrums((retrigAt: \live)).at("about")
    .contains("Retrig is off"), "");

// ---- the sets recorded before ---------------------------------------------------------
json78 = "{\"numerator\": 7, \"denominator\": 8, \"tau\": 0.25, \"sub\": 1, \"k\": 2, \"loopDur\": 3.5, "
    "\"bpm\": 120.0, \"score\": 0.8, \"accent\": 0.5}";
json148 = "{\"numerator\": 14, \"denominator\": 8, \"tau\": 0.25, \"sub\": 1, \"k\": 1, \"loopDur\": 3.5, "
    "\"bpm\": 120.0, \"score\": 0.7}";
lines = [
    "{\"t\": 0.0, \"ev\": \"session\", \"date\": \"Tue Oct 20 10:00:00 2026\", \"build\": \"test\", \"fallback\": \"7/8\"}",
    "{\"t\": 2.0, \"ev\": \"recordStart\", \"threshold\": 0.5}",
    "{\"t\": 5.5, \"ev\": \"take\", \"applied\": true, \"result\": " ++ json78 ++ ", \"candidates\": [" ++ json78
        ++ ", " ++ json148 ++ "], \"onsets\": [[0.0, 1.0], [0.5, 0.5], [1.0, 0.5], [1.75, 0.9]], \"threshold\": 0.5}",
    "{\"t\": 6.0, \"ev\": \"hit\", \"kind\": \"step\", \"slot\": \"steps\", \"which\": \"main\"}",
    "{\"t\": 6.1, \"ev\": \"hit\", \"kind\": \"onset\", \"slot\": \"onset\", \"which\": \"main\"}",
    "{\"t\": 9.0, \"ev\": \"readingArmed\", \"index\": 1, \"of\": 2, \"via\": \"next\", \"landsAt\": 12.5, \"reading\": "
        ++ json148 ++ "}",
    "{\"t\": 12.5, \"ev\": \"readingLanded\", \"index\": 1, \"reading\": " ++ json148 ++ "}",
    "{\"t\": 20.0, \"ev\": \"threshold\", \"value\": 0.4}",
    "{\"t\": 30.0, \"ev\": \"audio\"}",
    "{\"t\": 62.0, \"ev\": \"sessionStop\", \"elapsed\": 62.0}"
];
File.use(dir +/+ "261020_100000-120.00bpm-7-8-events.jsonl", "w", { |f| lines.do { |x| f.write(x ++ "\n") } });
File.use(dir +/+ "261019_090000-events.jsonl", "w", { |f|
    f.write("{\"t\": 0.0, \"ev\": \"session\", \"date\": \"Mon Oct 19 09:00:00 2026\"}\n");
    f.write("{\"t\": 30.0, \"ev\": \"sessionStop\", \"elapsed\": 30.0}\n") });
r = MegaRemote({ (looper: l, sa: nil, sessionDir: dir) });

got = ask.(r, "{\"command\": \"list_sets\"}").at("result");
~tEq.("list_sets: the sets, newest first, by id", got.at("sets").collect { |x| x.at("id") },
    ["261020_100000-120.00bpm-7-8", "261019_090000"]);
o = got.at("sets")[0];
~tEq.("...when, how long, each take's time and reading",
    [o.at("day"), o.at("started"), o.at("minutes"), o.at("takes").collect { |t| [t.at("at"),
        t.at("reading").at("signature"), t.at("reading").at("bpm"), t.at("reading").at("bars")] }],
    ["Tue Oct 20", "10:00:00", 1.0, [["10:00:05", "7/8", 120.0, [7, 7]]]]);
~tEq.("...the readings' accent fit too, as logged", o.at("takes")[0].at("reading").at("accentFit"), 0.5);
~tEq.("...what the players changed, and the drums' hits counted",
    [o.at("readingsArmed"), o.at("readingsLanded"), o.at("readingsCancelled"), o.at("thresholdChanges"), o.at("drumHits")],
    [1, 1, 0, 1, 2]);
got = ask.(r, "{\"command\": \"list_sets\", \"args\": {\"limit\": 1}}").at("result");
~tEq.("...a limit, and how many more there are", [got.at("sets").size, got.at("more")], [1, 1]);

got = ask.(r, "{\"command\": \"get_set\", \"args\": {\"id\": \"261020_100000\"}}");
~tEq.("get_set by the stamp alone", [got.at("ok"), got.at("result").at("id")], [true, "261020_100000-120.00bpm-7-8"]);
events = got.at("result").at("events");
~tEq.("...its records in time, the recorder's own (audio) and the hits left out",
    events.collect { |e| e.at("event") }, ["recordStart", "take", "readingArmed", "readingLanded", "threshold", "sessionStop"]);
take = events[1];
~tEq.("...a take: the reading applied, its runner-up, at the clock",
    [take.at("at"), take.at("reading").at("signature"), take.at("alternatives").collect { |a| a.at("signature") },
        take.at("onsets")], ["10:00:05", "7/8", ["14/8"], 4]);
~tEq.("...and what it played on that reading's grid, in sixteenths: X strong, x a hit",
    take.at("played").at("bars").collect { |b| b.at("grid") }, ["X...x...x.....", "X............."]);
~tEq.("...the reading the players armed, when it was to land, and that it did",
    [events[2].at("via"), events[2].at("lands"), events[2].at("reading").at("signature"), events[3].at("reading").at("signature")],
    ["next", "10:00:12", "14/8", "14/8"]);
~tEq.("...a threshold moved, with its value", events[4].at("value"), 0.4);
~tEq.("...and the drums' hits, counted by what played them",
    [got.at("result").at("drumHits").at("total"), got.at("result").at("drumHits").at("main"),
        got.at("result").at("drumHits").at("onsetKit")], [2, 1, 1]);
got = ask.(r, "{\"command\": \"get_set\", \"args\": {\"id\": \"261020_100000\", \"grids\": false}}");
~tEq.("...grids false leaves what was played out", got.at("result").at("events")[1].at("played"), nil);
~tEq.("no id, a path, a set there is not: refused",
    ["{\"command\": \"get_set\"}", "{\"command\": \"get_set\", \"args\": {\"id\": \"../x\"}}",
        "{\"command\": \"get_set\", \"args\": {\"id\": \"990101\"}}"].collect { |q| ask.(r, q).at("ok") }, [false, false, false]);
r = MegaRemote({ (looper: l, sa: nil, sessionDir: nil) });
~tEq.("with no sessions folder, no sets", ask.(r, "{\"command\": \"list_sets\"}").at("result").at("sets"), []);

// ---- a set recorded with every action (MegaActionLog) ------------------------------------
// Its first lines say how every part was set; then the changes, a state once
// a part settled, and an AI app's change among the players'.
lines = [
    "{\"t\": 0.0, \"ev\": \"session\", \"date\": \"Wed Oct 21 20:00:00 2026\", \"actions\": true, \"view\": \"perform\"}",
    "{\"t\": 0.05, \"ev\": \"state\", \"part\": \"drums\", \"state\": {\"drums\": {\"on\": true, \"stepsKit\": \"core-808\"}, \"synth\": {\"notesOn\": false}}}",
    "{\"t\": 0.06, \"ev\": \"state\", \"part\": \"looper\", \"state\": {\"cutter\": {\"on\": false}, \"grains\": {\"on\": false}, \"looper\": {\"intensity\": 1.0}}}",
    "{\"t\": 4.0, \"ev\": \"act\", \"args\": [true], \"part\": \"looper\", \"what\": \"granular\"}",
    "{\"t\": 4.5, \"ev\": \"act\", \"args\": [0.6], \"part\": \"looper\", \"what\": \"granularMorph\"}",
    "{\"t\": 6.5, \"ev\": \"state\", \"part\": \"looper\", \"state\": {\"cutter\": {\"on\": false}, \"grains\": {\"on\": true, \"morph\": 0.6}, \"looper\": {\"intensity\": 1.0}}}",
    "{\"t\": 10.0, \"ev\": \"act\", \"args\": [\"main\", \"chance\", 0, 3, 5], \"by\": \"ai\", \"part\": \"drums\", \"what\": \"step\"}",
    "{\"t\": 11.0, \"ev\": \"act\", \"args\": [\"drums\"], \"part\": \"window\", \"what\": \"view\"}",
    "{\"t\": 20.0, \"ev\": \"sessionStop\", \"elapsed\": 20.0}"
];
File.use(dir +/+ "261021_200000-events.jsonl", "w", { |f| lines.do { |x| f.write(x ++ "\n") } });
r = MegaRemote({ (looper: l, sa: nil, sessionDir: dir) });
o = ask.(r, "{\"command\": \"list_sets\"}").at("result").at("sets")[0];
~tEq.("list_sets: a set recorded with every action says so, and how many changes it holds",
    [o.at("id"), o.at("everyAction"), o.at("actions")], ["261021_200000", true, 4]);
~tEq.("...one recorded before says not", ask.(r, "{\"command\": \"list_sets\"}").at("result").at("sets")[1].at("everyAction"), false);
got = ask.(r, "{\"command\": \"get_set\", \"args\": {\"id\": \"261021_200000\"}}").at("result");
events = got.at("events");
~tEq.("get_set: the changes in time, each with its part, what, args and whose; the states left out",
    [got.at("everyAction"), events.collect { |e| [e.at("seconds"), e.at("part"), e.at("what"), e.at("by")] }],
    [true, [[4.0, "looper", "granular", "player"], [4.5, "looper", "granularMorph", "player"], [10.0, "drums", "step", "ai"],
        [11.0, "window", "view", "player"], [20.0, nil, nil, nil]]]);
~tEq.("...a change's arguments as they were", events[2].at("args"), ["main", "chance", 0, 3, 5]);
got = ask.(r, "{\"command\": \"get_set\", \"args\": {\"id\": \"261021_200000\", \"from\": 4.2, \"to\": 10.5}}").at("result");
~tEq.("...from and to: only the seconds between", got.at("events").collect { |e| e.at("what") }, ["granularMorph", "step"]);
~tEq.("...and from given as anything but seconds is refused",
    ask.(r, "{\"command\": \"get_set\", \"args\": {\"id\": \"261021_200000\", \"from\": \"x\"}}").at("ok"), false);

got = ask.(r, "{\"command\": \"get_set_state\", \"args\": {\"id\": \"261021_200000\", \"at\": 5}}").at("result");
~tEq.("get_set_state at 5 s: the set's first states, and the changes since that they do not hold yet",
    [got.at("grains").at("on"), got.at("drums").at("stepsKit"), got.at("synth").at("notesOn"),
        got.at("changedSince").collect { |e| e.at("what") }], [false, "core-808", false, ["granular", "granularMorph"]]);
~tEq.("...when each was written", [got.at("asOf").at("grains"), got.at("asOf").at("drums")], [0.06, 0.05]);
got = ask.(r, "{\"command\": \"get_set_state\", \"args\": {\"id\": \"261021_200000\", \"at\": 12}}").at("result");
~tEq.("...at 12 s: the grains as they settled at 6.5 s, and only what came after",
    [got.at("grains").at("morph"), got.at("asOf").at("grains"), got.at("changedSince").collect { |e| [e.at("what"), e.at("by")] }],
    [0.6, 6.5, [["step", "ai"], ["view", "player"]]]);
~tEq.("...the members in get_context's order", got.keys.select { |k| #["drums", "synth", "grains", "cutter", "looper"].includesEqual(k) },
    ["drums", "synth", "grains", "cutter", "looper"]);
~tEq.("...a set recorded without every action, or no second asked for: refused",
    [ask.(r, "{\"command\": \"get_set_state\", \"args\": {\"id\": \"261020_100000\", \"at\": 5}}").at("ok"),
        ask.(r, "{\"command\": \"get_set_state\", \"args\": {\"id\": \"261021_200000\"}}").at("ok")], [false, false]);

// The context: what the players and the AI just changed, with Log every action on.
r = MegaRemote({ (looper: l, sa: nil, recent: { [[2.5, \looper, \granular, [true], nil],
    [0.5, \drums, \step, [\main, \chance, 0, 3, 5], "ai"]] }) });
o = ask.(r, "{\"command\": \"context\"}").at("result").at("recent").at("changes");
~tEq.("the context's recent changes: how long ago, the part, what, args, and whose",
    o.collect { |c| [c.at("secondsAgo"), c.at("part"), c.at("what"), c.at("args"), c.at("by")] },
    [[2.5, "looper", "granular", [true], "player"], [0.5, "drums", "step", ["main", "chance", 0, 3, 5], "ai"]]);
r = MegaRemote({ (looper: l, sa: nil) });
~tEq.("...none with it off", ask.(r, "{\"command\": \"context\"}").at("result").at("recent"), nil);
~tRemoveTree.(dir);
}.value;
