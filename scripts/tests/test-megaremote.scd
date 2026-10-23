// megalooper as a tool for an AI app (MegaRemote, docs/dev/ai-tool.md, Phase 0):
// who may ask (127.0.0.1 and this boot's token, an id that names nothing
// but its own two files), what is answered (ping, the context, what every
// setting means), the drums, the synth and the chains it may change and
// take back (a pattern merged over the one playing, the steps' kit, the note
// sequence, the Wave synth, the sequencer's switch, built-in effects in, out,
// moved, set and switched, revert across all of them, presets and sounds
// saved), and that
// every answer is JSON that reads back. The OSC
// round trip itself is tools/megalooper-mcp.py's check
// (tools/test-megalooper-mcp.py).

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-megaremote");

{
var ask, r, got, o, ctx, stub, sa, looper, here, there, ids, path, text, other, reading;
var d, before, beforeBreak, kits, presets, said, src, wp, notesBefore, waveBefore, onBefore;

// The request's text answered, as it reads back from its JSON.
ask = { |remote, text| MegaFiles.parseObject(MegaFiles.json(remote.handle(text))) };

// ---- the requests ------------------------------------------------------------------
r = MegaRemote({ (looper: nil, sa: nil, profile: \sa) });
got = ask.(r, "{\"command\": \"ping\"}");
~tEq.("a ping is answered with the format, its version and the pid",
    [got.at("ok"), got.at("result").at("format"), got.at("result").at("version"), got.at("result").at("pid")],
    [true, "megalooper remote", 1, thisProcess.pid]);
got = ask.(r, "{\"command\": \"tune the guitar\"}");
~tEq.("a command there is not is refused, naming those there are",
    [got.at("ok"), got.at("error").contains("ping, context, describe, set_drum_pattern, set_synth, set_chain")], [false, true]);
got = ask.(r, "tune the guitar");
~tEq.("...as is a request that is not JSON", [got.at("ok"), got.at("error").contains("not JSON")], [false, true]);
got = ask.(r, nil);
~tEq.("...or none at all (the request file was gone)", [got.at("ok"), got.at("error").contains("empty")], [false, true]);
got = ask.(r, "{\"command\": \"describe\", \"args\": [1]}");
~tEq.("...and args that are not an object", [got.at("ok"), got.at("error")], [false, "args must be an object"]);

// ---- describe ----------------------------------------------------------------------
got = ask.(r, "{\"command\": \"describe\"}");
~tEq.("describe with no topic lists the topics", got.at("result").at("topics"), ["drums", "synth", "effects"]);
got = ask.(r, "{\"command\": \"describe\", \"args\": {\"topic\": \"kazoo\"}}");
~tEq.("...a topic there is not is refused", [got.at("ok"), got.at("error").contains("drums, synth, effects")], [false, true]);

got = ask.(r, "{\"command\": \"describe\", \"args\": {\"topic\": \"drums\"}}").at("result");
o = got.at("settings").detect { |row| row.at("name") == "clockSpeed" };
~tEq.("the drums: every pattern setting, with its range, its choices and its tip",
    [got.at("settings").size, o.at("min"), o.at("max"), o.at("choices")[3], o.at("tip").contains("16th")],
    [MegaSASteps.paramSpecs.size, 0, 5, [3, "100 %"], true]);
~tEq.("...the lane settings, the pages, the step values, and how a pattern works",
    [got.at("laneSettings").size, got.at("pages"), got.at("stepValues").at("max"),
        got.at("velocities"), got.at("about").contains("bar line")],
    [MegaSASteps.laneParamSpecs.size, ["chance", "velo", "alt", "roll", "slide"], 6,
        MegaSASteps.velocities.asArray, true]);
o = got.at("laneSettings").detect { |row| row.at("name") == "mute" };
~tEq.("...a switch says it is one, and has no range", [o.at("switch"), o.at("min")], [true, nil]);

got = ask.(r, "{\"command\": \"describe\", \"args\": {\"topic\": \"synth\"}}").at("result");
~tEq.("the synth: its lanes with their ranges, the scales, the divisions, the Wave synth's settings",
    [got.at("lanes").collect { |l| l.at("name") }, got.at("lanes")[0].at("min"), got.at("lanes")[0].at("max"),
        got.at("scales").size, got.at("scales")[1], got.at("divisions")[4], got.at("wave").size],
    [MegaSANoteSeq.laneNames.collect(_.asString), -12, 12, MegaSANoteSeq.scales.size,
        [1, "Minor", [0, 2, 3, 5, 7, 8, 10]], [4, "1/16"], MegaSAWave.params.size]);

got = ask.(r, "{\"command\": \"describe\", \"args\": {\"topic\": \"effects\"}}").at("result");
o = got.at("effects").detect { |e| e.at("key") == "shifter" };
~tEq.("the effects: every type, its chain, what it does, and its settings",
    [got.at("effects").size, o.at("track"), o.at("about"), o.at("settings").size],
    [MegaSAFx.types.size, "guitar", MegaSAFx.type(\shifter)[\blurb], MegaSAFx.paramsOf(\shifter).size]);
o = o.at("settings").detect { |row| row.at("name") == "shifterCoarse" };
~tEq.("...a setting as the window has it: range, step, units, bipolar, the tip on one line",
    [o.at("min"), o.at("max"), o.at("step"), o.at("units"), o.at("bipolar"), o.at("tip").contains("\n")],
    [-24, 24, 1, "st", true, false]);

// ---- the context -------------------------------------------------------------------
got = ask.(r, "{\"command\": \"context\"}").at("result");
~tEq.("with no Looper and no SA the context says so, with nulls",
    [got.at("profile"), got.at("standalone"), got.at("loop"), got.at("drums"), got.at("chains"), got.includesKey("tempo")],
    ["sa", false, nil, nil, nil, true]);

looper = ~tLooper.();
reading = (numerator: 7, denominator: 8, bpm: 132.5, k: 4, sub: 1, n: 29, tau: 0.2264, loopDur: 6.566,
    bars: [7, 7, 7, 8], phase: 0, onsetCount: 40);
looper.instVarPut(\lastResult, reading);
looper.instVarPut(\state, \playing);
o = MegaRemote.loopOf(looper);
~tEq.("the loop: its state and its reading, uneven bars as the window shows them",
    [o.at("state"), o.at("reading").at("signature"), o.at("reading").at("bars"), o.at("reading").at("barCount"),
        o.at("reading").at("bpm"), o.at("reading").at("loopSeconds"), o.at("reading").at("byHand")],
    ["playing", "7+7+7+8/8", [7, 7, 7, 8], 4, 132.5, 6.566, false]);
looper.instVarPut(\lastResult, (numerator: 7, denominator: 8, bpm: 140, k: 2, sub: 1, loopDur: 3.43, from: \hand));
o = MegaRemote.loopOf(looper).at("reading");
~tEq.("...even bars are listed all the same, and a reading given by hand says so",
    [o.at("signature"), o.at("bars"), o.at("byHand")], ["7/8", [7, 7], true]);
looper.instVarPut(\lastResult, (numerator: nil, denominator: nil, bpm: nil, error: \insufficientOnsets));
~tEq.("...a reading that found nothing is none", MegaRemote.loopOf(looper).at("reading"), nil);

stub = ~tStubServer.();
sa = ~tCheck.("a MegaSA is made on the stub", { MegaSA(stub) });
if(sa.notNil) {
    looper.instVarPut(\lastResult, reading);
    r = MegaRemote({ (looper: looper, sa: sa, profile: \sa) });
    text = MegaFiles.json(r.handle("{\"command\": \"context\"}"));
    got = MegaFiles.parseObject(text);
    ~tAssert.("the whole context is JSON that reads back", got.isKindOf(MegaJsonObject), text.keep(200));
    ctx = got.at("result");
    ~tEq.("...the profile, the loop's reading", [ctx.at("standalone"), ctx.at("loop").at("reading").at("signature")],
        [true, "7+7+7+8/8"]);
    o = ctx.at("drums").at("patterns").at("main");
    ~tEq.("...both drum patterns, every page of every lane as the model holds it",
        [o.at("steps").at("chance"), o.at("steps").at("velo"), o.at("note"), o.at("clockSpeed"),
            ctx.at("drums").at("patterns").at("break").at("note")],
        [sa.drums.patterns[\main][\steps][\chance], sa.drums.patterns[\main][\steps][\velo],
            sa.drums.patterns[\main][\note], sa.drums.patterns[\main][\clockSpeed], sa.drums.patterns[\break][\note]]);
    ~tEq.("...the drums' switches and their kits",
        [ctx.at("drums").at("on"), ctx.at("drums").at("breakActive"), ctx.at("drums").at("kits").class],
        [sa.drums.on, false, Array]);
    o = ctx.at("synth");
    ~tEq.("...the note sequence, and what plays it",
        [o.at("notes").at("lanes").at("pitch").at("values"), o.at("notes").at("scale"), o.at("instrument"),
            o.at("wave").size],
        [sa.drums.notes[\lanes][\pitch][\values], sa.drums.notes[\scale], "wave", sa.wave.settings.size]);
    ids = ctx.at("chains").collect { |c| [c.at("track"), c.at("devices").collect { |d| d.at("id") }] };
    ~tEq.("...every chain, its devices in order", ids,
        sa.chains.collect { |c| [c.track.asString, c.devices.collect { |d| d.id.asString }.asArray] });
    o = ctx.at("chains")[0].at("devices")[0];
    ~tEq.("...each with its switch and its settings",
        [o.at("on"), o.at("settings").at("shifterCoarse")], [sa.guitarChain.devices[0].on,
            sa.guitarChain.devices[0].param(\shifterCoarse)]);
    sa.free;
};

// ---- merging what the AI gives over what is there ------------------------------------
o = (steps: (chance: [[0, 0, 0], [1, 1, 1]], velo: [[4, 4, 4], [4, 4, 4]]), note: [42, 38], clockSpeed: 3);
got = MegaRemote.mergePattern(o, MegaRemote.plain(MegaFiles.parseObject(
    "{\"steps\": {\"chance\": [null, [6, null]]}, \"note\": [36], \"clockSpeed\": null, \"swing\": 2}")));
~tEq.("a member given replaces, one left out or null keeps, a short list changes its first items, a new member comes in",
    [got[\steps][\chance], got[\steps][\velo], got[\note], got[\clockSpeed], got[\swing]],
    [[[0, 0, 0], [6, 1, 1]], [[4, 4, 4], [4, 4, 4]], [36, 38], 3, 2]);
~tEq.("...and what was there is not touched", o[\steps][\chance], [[0, 0, 0], [1, 1, 1]]);
~tEq.("a JSON object is an Event with Symbol keys, its null members left out",
    MegaRemote.plain(MegaFiles.parseObject("{\"a\": {\"b\": [1, {\"c\": true}]}, \"n\": null}")),
    (a: (b: [1, (c: true)])));

// ---- the drums, changed and taken back ---------------------------------------------------
stub = ~tStubServer.();
sa = ~tCheck.("a MegaSA for the drums is made on the stub", { MegaSA(stub) });
if(sa.notNil) {
    d = sa.drums;
    // A kit asked for is the drums' at once; its buffers never come here.
    d.kitReader = { |path, done| };
    kits = d.kitKeys;
    presets = ~tTempPath.("megaremote-presets");
    said = List.new;
    src = (looper: nil, sa: sa, profile: \sa, drumsPresetDir: presets, say: { |m| said.add(m) });
    r = MegaRemote({ src });
    before = d.patterns[\main].deepCopy;
    beforeBreak = d.patterns[\break].deepCopy;

    got = ask.(r, "{\"command\": \"set_drum_pattern\", \"args\": {\"pattern\": {\"steps\": {\"chance\": [null, [6, 0, 6]]}}}}");
    ~tEq.("a pattern given is merged over the main one: lane 1's first three chance steps, nothing else",
        [got.at("ok"), d.patterns[\main][\steps][\chance][1].keep(3), d.patterns[\main][\steps][\chance][1].drop(3),
            d.patterns[\main][\steps][\chance][0], d.patterns[\main][\steps][\velo], d.patterns[\break]],
        [true, [6, 0, 6], before[\steps][\chance][1].drop(3), before[\steps][\chance][0], before[\steps][\velo], beforeBreak]);
    ~tEq.("...the answer: the pattern as it now plays, no corrections, one change to revert",
        [got.at("result").at("which"), got.at("result").at("pattern").at("steps").at("chance")[1].keep(3),
            got.at("result").at("corrections"), got.at("result").at("aiChanges")],
        ["main", [6, 0, 6], [], 1]);

    got = ask.(r, "{\"command\": \"set_drum_pattern\", \"args\": {\"which\": \"break\", \"pattern\": {\"steps\": {\"velo\": [[9]]}, \"clockSpeed\": 2, \"bogus\": 1}}}");
    ~tEq.("the break's: a value out of range is held to it, a field there is not ignored, and both are said",
        [d.patterns[\break][\steps][\velo][0][0], d.patterns[\break][\clockSpeed], got.at("result").at("corrections").size,
            got.at("result").at("corrections").any { |c| c.contains("bogus") }, d.patterns[\main][\steps][\chance][1].keep(3)],
        [6, 2, 2, true, [6, 0, 6]]);

    ~tEq.("refused, changing nothing: a which there is not, nothing to change, a pattern that is no object, a kit there is not",
        [
            "{\"command\": \"set_drum_pattern\", \"args\": {\"which\": \"fill\", \"pattern\": {}}}",
            "{\"command\": \"set_drum_pattern\", \"args\": {}}",
            "{\"command\": \"set_drum_pattern\"}",
            "{\"command\": \"set_drum_pattern\", \"args\": {\"pattern\": [1]}}",
            "{\"command\": \"set_drum_pattern\", \"args\": {\"kit\": \"no-such-kit\"}}"
        ].collect { |t| ask.(r, t).at("ok") } ++ [r.changeCount],
        [false, false, false, false, false, 2]);
    ~tAssert.("...a kit there is not is answered with those there are",
        ask.(r, "{\"command\": \"set_drum_pattern\", \"args\": {\"kit\": \"no-such-kit\"}}").at("error").contains(kits[0].asString));

    if(kits.size >= 2) {
        o = kits.detect { |k| k != d.kit(\steps) };
        other = d.kit(\steps);
        got = ask.(r, "{\"command\": \"set_drum_pattern\", \"args\": {\"kit\": \"" ++ o ++ "\"}}");
        ~tEq.("a kit given is the steps' kit, and the pattern stays",
            [got.at("ok"), d.kit(\steps), got.at("result").at("kit"), d.patterns[\main][\steps][\chance][1].keep(3)],
            [true, o, o.asString, [6, 0, 6]]);
        got = ask.(r, "{\"command\": \"revert\"}");
        ~tEq.("revert takes the newest change back: the kit was the one before",
            [got.at("ok"), d.kit(\steps), got.at("result").at("reverted"), r.changeCount], [true, other, ["drums' kit"], 2]);
    } { ~tSkip.("a kit given is the steps' kit", "fewer than two kits in " ++ d.kitDir) };

    o = ask.(r, "{\"command\": \"context\"}").at("result");
    ~tEq.("the context says how many changes revert can take back", o.at("aiChanges"), 2);
    got = ask.(r, "{\"command\": \"revert\", \"args\": {\"count\": 5}}");
    ~tEq.("revert of more than there are takes them all back, newest first: both patterns as they were",
        [got.at("ok"), got.at("result").at("reverted"), d.patterns[\main], d.patterns[\break], r.changeCount],
        [true, ["drums' break pattern", "drums' main pattern"], before, beforeBreak, 0]);
    got = ask.(r, "{\"command\": \"revert\"}");
    ~tEq.("...then there is nothing to revert", [got.at("ok"), got.at("error").contains("nothing to revert")], [false, true]);
    ~tEq.("...and a count that is no whole number is refused",
        ask.(r, "{\"command\": \"revert\", \"args\": {\"count\": 0}}").at("ok"), false);

    40.do { |i| r.handle("{\"command\": \"set_drum_pattern\", \"args\": {\"pattern\": {\"delay\": [" ++ (i % 50) ++ "]}}}") };
    ~tEq.("at most 32 changes are kept, the oldest go", r.changeCount, MegaRemote.changesMax);
    r.revert(nil);
    ~tEq.("...each change was snapshotted on its own", d.patterns[\main][\delay][0], 38.0);
    ~tEq.("every change and revert was said in the window's status line",
        [said.size, said[0].contains("main pattern"), said.last.contains("reverted")], [3 + 2 + 40 + 1, true, true]);

    got = ask.(r, "{\"command\": \"save_drum_preset\", \"args\": {\"name\": \"AI Groove\"}}");
    ~tEq.("save_drum_preset writes the drums as a preset in the Drums view's folder",
        [got.at("ok"), got.at("result").at("saved"), File.exists(presets +/+ "ai-groove.scd")],
        [true, "ai-groove", true]);
    got = ask.(r, "{\"command\": \"save_drum_preset\", \"args\": {\"name\": \"AI Groove\"}}");
    ~tEq.("...a name taken is refused", [got.at("ok"), got.at("error").contains("overwrite")], [false, true]);
    ~tEq.("...unless overwrite is true; no name, or no folder, is refused",
        [ask.(r, "{\"command\": \"save_drum_preset\", \"args\": {\"name\": \"AI Groove\", \"overwrite\": true}}").at("ok"),
            ask.(r, "{\"command\": \"save_drum_preset\", \"args\": {\"name\": \"  \"}}").at("ok"),
            MegaRemote({ (sa: sa) }).handle("{\"command\": \"save_drum_preset\", \"args\": {\"name\": \"x\"}}")
                .at(\ok)],
        [true, false, false]);
    ~tEq.("...and it reads back as the drums are", d.loadPreset(presets, "ai-groove"), true);

    // ---- the synth ----
    r.handle("{\"command\": \"revert\", \"args\": {\"count\": 99}}");
    src[\synthPresetDir] = presets +/+ "synth";
    wp = MegaSAWave.params.detect { |p| p[\choices].isNil and: { p[\bool] != true } };
    notesBefore = MegaSANoteSeq.copyPattern(d.notes);
    waveBefore = sa.wave.settings.copy;
    onBefore = d.notesOn;
    got = ask.(r, "{\"command\": \"set_synth\", \"args\": {\"notes\": {\"lanes\": {\"pitch\": {\"values\": [0, 3, 7]}}, "
        "\"root\": 2, \"swing\": 50, \"direction\": \"backward\", \"bogus\": 1, \"steps\": [false]}}}");
    ~tEq.("the note pattern given is merged over the one playing: three pitches, the root, the direction, the first step off",
        [got.at("ok"), d.notes[\lanes][\pitch][\values].keep(3), d.notes[\lanes][\pitch][\values].drop(3),
            d.notes[\root], d.notes[\direction], d.notes[\steps][0], d.notes[\steps].drop(1), d.notes[\lanes][\velocity]],
        [true, [0, 3, 7], notesBefore[\lanes][\pitch][\values].drop(3), 2, \backward, false,
            notesBefore[\steps].drop(1), notesBefore[\lanes][\velocity]]);
    o = got.at("result").at("corrections");
    ~tEq.("...what was held to its range, and what is no setting, is said",
        [d.notes[\swing], o.any { |c| c.contains("notes.swing 50 -> 1.0") }, o.any { |c| c.contains("notes.bogus is no setting") }, o.size],
        [1.0, true, true, 2]);
    got = ask.(r, "{\"command\": \"set_synth\", \"args\": {\"wave\": {\"" ++ wp[\name] ++ "\": 1e9}, \"on\": true}}");
    ~tEq.("a Wave setting given is held to its range, and the sequencer switched on",
        [got.at("ok"), sa.wave.settings[wp[\name]], d.notesOn, got.at("result").at("corrections").size,
            sa.wave.settings.keys.reject { |k| k == wp[\name] }.every { |k| sa.wave.settings[k] == waveBefore[k] }],
        [true, wp[\spec].maxval, true, 1, true]);
    ~tEq.("refused, changing nothing: nothing to change, notes or wave that are no object, an on that is no switch",
        [
            "{\"command\": \"set_synth\", \"args\": {}}",
            "{\"command\": \"set_synth\", \"args\": {\"notes\": 3}}",
            "{\"command\": \"set_synth\", \"args\": {\"wave\": [1]}}",
            "{\"command\": \"set_synth\", \"args\": {\"on\": 1}}"
        ].collect { |t| ask.(r, t).at("ok") } ++ [r.changeCount],
        [false, false, false, false, 2]);
    before = d.patterns[\main].deepCopy;
    r.handle("{\"command\": \"set_drum_pattern\", \"args\": {\"pattern\": {\"mute\": [true]}}}");
    got = ask.(r, "{\"command\": \"revert\", \"args\": {\"count\": 3}}");
    ~tEq.("revert across the drums and the synth: each as it was before the earliest change taken back, newest named first",
        [got.at("result").at("reverted"), d.patterns[\main], d.notes, sa.wave.settings, d.notesOn, r.changeCount],
        [["drums' main pattern", "synth's Wave settings and sequencer switch", "synth's note pattern"],
            before, notesBefore, waveBefore, onBefore, 0]);
    got = ask.(r, "{\"command\": \"save_synth_preset\", \"args\": {\"name\": \"AI Line\"}}");
    ~tEq.("save_synth_preset writes the synth as a preset in the Synth view's folder, and it reads back",
        [got.at("ok"), got.at("result").at("saved"), sa.synthPresetNames(src[\synthPresetDir]),
            sa.loadSynthPreset(src[\synthPresetDir], "ai-line")],
        [true, "ai-line", ["ai-line"], true]);
    ~tEq.("...a name taken is refused unless overwrite is true",
        [ask.(r, "{\"command\": \"save_synth_preset\", \"args\": {\"name\": \"AI Line\"}}").at("ok"),
            ask.(r, "{\"command\": \"save_synth_preset\", \"args\": {\"name\": \"AI Line\", \"overwrite\": true}}").at("ok")],
        [false, true]);

    ~tEq.("with no drums every change is refused",
        ["set_drum_pattern", "set_synth", "revert", "save_drum_preset", "save_synth_preset"].collect { |c|
            MegaFiles.json(MegaRemote({ () }).handle("{\"command\": \"" ++ c ++ "\", \"args\": {\"name\": \"x\", \"kit\": \"y\"}}"))
                .contains("runs without Megalooper SA") },
        [true, true, true, true, true]);
    ~tRemoveTree.(presets);
    sa.free;
};

// ---- who may ask -------------------------------------------------------------------
~tEq.("an id is letters, digits and dashes, 1 to 64 of them",
    ["a-1", "A", "x" ! 64, "", "x" ! 65, "../x", "a/b", "a.b", "a b"].collect { |s|
        MegaRemote.idOk(if(s.isKindOf(Array)) { s.join } { s }) },
    [true, true, true, false, false, false, false, false, false]);
~tEq.("only 127.0.0.1 is local",
    [NetAddr("127.0.0.1", 1), NetAddr("192.168.1.5", 1), NetAddr("0.0.0.0", 1), nil].collect { |a| MegaRemote.isLocal(a) },
    [true, false, false, false]);
o = MegaRemote.newToken;
~tEq.("a token is 32 hex digits, and a new one each time",
    [o.size, o.every { |c| c.isDecDigit or: { "abcdef".includes(c) } }, o == MegaRemote.newToken], [32, true, false]);

protect {
    MegaFiles.alwaysSync = true;
    r = MegaRemote({ (looper: nil, sa: nil, profile: \sa) });
    r.start(57999);
    here = NetAddr("127.0.0.1", 50000);
    there = NetAddr("192.168.1.5", 50000);
    o = MegaFiles.parseObject(MegaFiles.readText(MegaRemote.handshakePath));
    ~tEq.("start writes the handshake: the port, this boot's token, the pid, where the files go",
        [o.at("format"), o.at("port"), o.at("token"), o.at("pid"), o.at("oscPath"), o.at("dir")],
        ["megalooper remote", 57999, r.token, thisProcess.pid, "/megalooper/remote", MegaRemote.dir]);
    ~tEq.("...for you alone to read (mode 600)",
        ("ls -l " ++ MegaRemote.handshakePath.shellQuote).unixCmdGetStdOut.keep(10), "-rw-------");
    ~tAssert.("...and listens", OSCdef.all[\megalooperRemote].notNil and: { OSCdef.all[\megalooperRemote].enabled });

    path = { |id| File.use(MegaRemote.requestPath(id), "w", { |f| f.write("{\"command\": \"ping\"}") }) };
    path.("t-1");
    r.receive([MegaRemote.oscPath, r.token, 't-1'], here);
    got = MegaFiles.parseObject(MegaFiles.readText(MegaRemote.replyPath("t-1")));
    ~tEq.("a request from here with the token is answered in its reply file, and its request goes",
        [got.isKindOf(MegaJsonObject) and: { got.at("ok") }, File.exists(MegaRemote.requestPath("t-1"))], [true, false]);
    path.("t-2");
    r.receive([MegaRemote.oscPath, r.token, 't-2'], there);
    r.receive([MegaRemote.oscPath, "0" ! 32, 't-2'], here);
    r.receive([MegaRemote.oscPath, nil, 't-2'], here);
    ~tEq.("...from elsewhere, or with a wrong token or none, it is not even read",
        [File.exists(MegaRemote.replyPath("t-2")), File.exists(MegaRemote.requestPath("t-2"))], [false, true]);
    r.receive([MegaRemote.oscPath, r.token, '../remote']);
    r.receive([MegaRemote.oscPath, r.token, '../remote'], here);
    ~tAssert.("...an id that would name another file is dropped, and the handshake stays",
        File.exists(MegaRemote.handshakePath) and: { File.exists(MegaRemote.dir +/+ "../remote.reply.json").not });

    other = MegaRemote({ () });
    other.start(57998);
    ~tAssert.("a second start (boot.scd run again) takes the handshake over, with a token of its own",
        MegaFiles.readText(MegaRemote.handshakePath).contains(other.token) and: { other.token != r.token });
    ~tEq.("...and clears the requests and replies left over", (MegaRemote.dir +/+ "*.json").pathMatch, []);
    r.stop;
    ~tAssert.("the first one stopping leaves the second's handshake alone",
        MegaFiles.readText(MegaRemote.handshakePath).contains(other.token));
    other.stop;
    ~tEq.("the second one stopping removes it, and the listener goes",
        [File.exists(MegaRemote.handshakePath), OSCdef.all[\megalooperRemote]], [false, nil]);
} {
    MegaFiles.alwaysSync = false;
    r !? { |x| x.stop };
    other !? { |x| x.stop };
};
}.value;

// ---- the chains, changed and taken back -------------------------------------------------
{
var vst = \VSTPlugin.asClass, stub, sa, l, r, got, o, src, sounds, said, lp, g, before, onBefore, onNow, refusals;
var ask = { |remote, text| MegaFiles.parseObject(MegaFiles.json(remote.handle(text))) };
MegaSA.loadSynthDefs;
stub = ~tStubServer.();
sa = ~tMegaSA.(stub, if(vst.notNil) { ~tFakePlugin.(\open) });
Synth.tail(stub[\defaultGroup], \looperMaster);
l = ~tLooper.();
Routine { sa.attachLooper(l) }.next;
g = sa.guitarChain;
lp = sa.loopChain;
sounds = ~tTempPath.("megaremote-sounds");
said = List.new;
src = (sa: sa, soundDir: sounds, say: { |m| said.add(m) });
r = MegaRemote({ src });
before = sa.sound.contentString;
onNow = { sa.devices.collect { |d| [d.id, d.on] } };
onBefore = onNow.();

got = ask.(r, "{\"command\": \"set_chain\", \"args\": {\"insert\": [{\"track\": \"loop\", \"type\": \"delay\", \"index\": 1, "
    "\"settings\": {\"delayFeedback\": 0.3, \"delayMix\": 7}}]}}");
~tEq.("an insert puts a built-in effect where asked, with its settings, and says its id and place",
    [got.at("ok"), lp.ids, got.at("result").at("inserted")[0].at("id"), got.at("result").at("inserted")[0].at("index"),
        sa.param(\delay2, \delayFeedback), sa.fx(\delay2)],
    [true, [\echo, \delay2, \saturator, \redux], "delay2", 1, 0.3, true]);
~tEq.("...a setting held to its range is said", [sa.param(\delay2, \delayMix), got.at("result").at("corrections")],
    [1.0, ["delay2.delayMix 7 -> 1.0"]]);

got = ask.(r, "{\"command\": \"set_chain\", \"args\": {\"remove\": [\"redux\"], \"move\": [{\"id\": \"saturator\", \"index\": 0}], "
    "\"settings\": {\"shifter\": {\"shifterCoarse\": 7}}, \"on\": {\"shifter\": true, \"echo\": false}}}");
~tEq.("remove, move, settings and switches in one change, in that order",
    [got.at("ok"), lp.ids, sa.param(\shifter, \shifterCoarse), sa.fx(\shifter), sa.fx(\echo), got.at("result").at("corrections")],
    [true, [\saturator, \echo, \delay2], 7, true, false, []]);
~tEq.("...the answer holds the chains as they now stand",
    got.at("result").at("chains").detect { |c| c.at("track") == "loop" }.at("devices").collect { |d| d.at("id") },
    ["saturator", "echo", "delay2"]);

refusals = [
    "{\"command\": \"set_chain\", \"args\": {}}",
    "{\"command\": \"set_chain\", \"args\": {\"remove\": [\"nothing\"]}}",
    "{\"command\": \"set_chain\", \"args\": {\"remove\": \"echo\"}}",
    "{\"command\": \"set_chain\", \"args\": {\"insert\": [{\"track\": \"loop\", \"type\": \"flanger\"}]}}",
    "{\"command\": \"set_chain\", \"args\": {\"insert\": [{\"track\": \"vocals\", \"type\": \"delay\"}]}}",
    "{\"command\": \"set_chain\", \"args\": {\"insert\": [{\"track\": \"loop\", \"type\": \"delay\", \"index\": -1}]}}",
    "{\"command\": \"set_chain\", \"args\": {\"insert\": [{\"track\": \"loop\", \"type\": \"delay\", \"settings\": {\"echoMix\": 1}}]}}",
    "{\"command\": \"set_chain\", \"args\": {\"settings\": {\"echo\": {\"echoMix\": \"loud\"}}}}",
    "{\"command\": \"set_chain\", \"args\": {\"settings\": {\"echo\": {\"shifterCoarse\": 3}}}}",
    "{\"command\": \"set_chain\", \"args\": {\"on\": {\"echo\": 1}}}",
    "{\"command\": \"set_chain\", \"args\": {\"remove\": [\"echo\"], \"move\": [{\"id\": \"echo\", \"index\": 0}]}}",
    // Valid but for its last part: nothing of it may happen.
    "{\"command\": \"set_chain\", \"args\": {\"settings\": {\"echo\": {\"echoMix\": 0.1}}, \"on\": {\"nothing\": true}}}"
].collect { |t| ask.(r, t) };
~tEq.("refused whole, changing nothing: nothing given, a device, a type, a track, an index, a setting, a value or a switch that is none, a device moved after it is removed, or one part wrong",
    refusals.collect { |x| x.at("ok") } ++ [r.changeCount, lp.ids, sa.param(\echo, \echoMix) != 0.1],
    (false ! refusals.size) ++ [2, [\saturator, \echo, \delay2], true]);
~tAssert.("...each saying why", refusals.every { |x| x.at("error").isString and: { x.at("error").size > 10 } },
    refusals.collect { |x| x.at("error") }.join(" | "));
if(vst.notNil) {
    ~tEq.("a plugin is never taken out, nor its own settings set",
        [ask.(r, "{\"command\": \"set_chain\", \"args\": {\"remove\": [\"plugin1\"]}}").at("error").contains("plugin"),
            ask.(r, "{\"command\": \"set_chain\", \"args\": {\"settings\": {\"plugin1\": {\"x\": 1}}}}").at("error").contains("plugin"),
            sa.device(\plugin1).notNil],
        [true, true, true]);
} { ~tSkip.("a plugin is never taken out", "VSTPlugin is not installed") };

got = ask.(r, "{\"command\": \"revert\", \"args\": {\"count\": 2}}");
~tEq.("revert puts the chains back: devices, places, settings and every switch",
    [got.at("ok"), got.at("result").at("reverted"), lp.ids, sa.sound.contentString == before, onNow.() == onBefore],
    [true, ["chains (removed, moved, settings, switches)", "chains (inserted)"], [\echo, \saturator, \redux], true, true]);
r.handle("{\"command\": \"set_chain\", \"args\": {\"on\": {\"shifter\": true}, \"settings\": {\"delay\": {\"delayFeedback\": 0.5}}}}");
r.handle("{\"command\": \"revert\"}");
~tEq.("...a change of switches and settings alone too (a recall of the same devices flips no switch)",
    [sa.sound.contentString == before, onNow.() == onBefore], [true, true]);

protect {
    MegaFiles.alwaysSync = true;
    // Without the plugin's own state, which the fake plugin would answer
    // only when stepped: the sound's file is then written at once.
    sa.statesAllowed = { false };
    got = ask.(r, "{\"command\": \"save_sound\", \"args\": {\"name\": \"AI Wash\"}}");
    ~tEq.("save_sound writes the chains as a sound in the Effects view's folder",
        [got.at("ok"), got.at("result").at("saved"), sa.soundNames(sounds)], [true, "ai-wash", ["ai-wash"]]);
    ~tEq.("...a name taken is refused unless overwrite is true",
        [ask.(r, "{\"command\": \"save_sound\", \"args\": {\"name\": \"AI Wash\"}}").at("ok"),
            ask.(r, "{\"command\": \"save_sound\", \"args\": {\"name\": \"AI Wash\", \"overwrite\": true}}").at("ok")],
        [false, true]);
} { MegaFiles.alwaysSync = false };
~tEq.("every chain change and revert was said in the status line",
    said.select { |m| m.contains("chains") }.size, 3 + 2 + 2);
~tEq.("with no SA the chains are refused",
    ["set_chain", "save_sound"].collect { |c|
        MegaRemote({ () }).handle("{\"command\": \"" ++ c ++ "\", \"args\": {\"name\": \"x\", \"on\": {}}}").at(\error)
            .contains("without Megalooper SA") },
    [true, true]);
~tRemoveTree.(sounds);
sa.free;
}.value;

