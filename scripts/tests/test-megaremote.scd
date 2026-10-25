// megalooper as a tool for an AI app (MegaRemote, docs/dev/ai-tool.md, Phase 0):
// who may ask (127.0.0.1 and this boot's token, an id that names nothing
// but its own two files), what is answered (ping, the context, what every
// setting means), the drums, the synth and the chains it may change and
// take back (a pattern merged over the one playing, the steps' kit, the note
// sequence, the Wave synth, the sequencer's switch, built-in effects in, out,
// moved, set and switched, the grains' settings, window and switch, the
// cutter's voices, mode and switch, revert across all of them, presets and
// sounds saved), and that
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
~tEq.("describe with no topic lists the topics", got.at("result").at("topics"), ["drums", "synth", "effects", "grains", "cutter"]);
got = ask.(r, "{\"command\": \"describe\", \"args\": {\"topic\": \"kazoo\"}}");
~tEq.("...a topic there is not is refused", [got.at("ok"), got.at("error").contains("drums, synth, effects, grains, cutter")], [false, true]);

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

// ---- the take, on the bar grid ---------------------------------------------------------------
// 7+7+7+8/8 at 120 quarter notes a minute: an eighth is 0.25 s, a sixteenth
// 0.125 s, the bars 14, 14, 14 and 16 sixteenths, the loop 7.25 s.
looper.instVarPut(\lastResult, (numerator: 7, denominator: 8, bpm: 120, k: 4, sub: 1, tau: 0.25, loopDur: 7.25,
    bars: [7, 7, 7, 8], chordSegments: [(start: 0, rootName: "E", scaleName: "Minor"), (start: 3.5, rootName: "A", scaleName: "Minor")]));
~tEq.("no take before its onsets", MegaRemote.loopOf(looper).at("take"), nil);
looper.instVarPut(\onsets, List[[0.0, 1.0], [0.37, 0.4], [1.75, 0.9], [5.26, 0.5], [7.24, 0.3]]);
looper.instVarPut(\pitchSamples, List[[0.02, 82.41, 0.5], [0.05, 82.0, 0.5], [0.06, 440, 0], [1.78, 110.0, 0.4]]);
o = MegaRemote.loopOf(looper).at("take");
~tEq.("the take: a grid of sixteenths per bar, X strong, x a hit; a hit at the loop's very end is its start",
    [o.at("sixteenthsPerBar"), o.at("bars").collect { |b| b.at("grid") }],
    [[14, 14, 14, 16], ["X..x..........", "X.............", "..............", "x..............."]]);
~tEq.("...each bar's hits: where, how strong against the loudest, and the pitch heard (sounding readings only)",
    [o.at("bars")[0].at("hits").collect { |h| [h.at("at"), h.at("strength"), h.at("note")] },
        o.at("bars")[1].at("hits").collect { |h| [h.at("at"), h.at("note")] }, o.at("bars")[2].at("hits")],
    [[[0, 1.0, "E2"], [3, 0.4, nil], [0, 0.3, nil]], [[0, "A2"]], []]);
~tEq.("...and the chords heard, by bar and sixteenth",
    o.at("chords").collect { |c| [c.at("bar"), c.at("at"), c.at("chord")] }, [[1, 0, "E Minor"], [3, 0, "A Minor"]]);
looper.instVarPut(\lastResult, (numerator: 7, denominator: 8, bpm: 120, k: 4, sub: 1, tau: 0.25, loopDur: 14.5,
    bars: [7, 7, 7, 8], downbeatPhase: 0.25));
o = MegaRemote.loopOf(looper).at("take");
// From a downbeat 0.25 s (two sixteenths) in: the hit at 0 s is two
// sixteenths before beat one, the last bar's 15th; 1.75 s is bar 1's 13th.
~tEq.("a loop grown to two cycles counts both; an overdub's reading counts from its downbeat, a hit before it wrapping to the end",
    [o.at("sixteenthsPerBar"), o.at("bars")[0].at("grid"), o.at("bars").last.at("grid")],
    [[14, 14, 14, 16, 14, 14, 14, 16], ".x..........X.", "..............X."]);
looper.instVarPut(\lastResult, (numerator: 7, denominator: 32, bpm: 120, k: 1, sub: 1, tau: 0.0625, loopDur: 0.4375));
~tEq.("...a reading in 32nds has no sixteenth grid", MegaRemote.loopOf(looper).at("take"), nil);
looper.instVarPut(\onsets, List.new);
looper.instVarPut(\pitchSamples, List.new);

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

// ---- the grains and the cutter, changed and taken back -------------------------------------
{
var l, r, got, o, src, said, dirs, before, cutBefore, refusals, rows;
var ask = { |remote, text| MegaFiles.parseObject(MegaFiles.json(remote.handle(text))) };
var scripts = thisProcess.nowExecutingPath.dirname.dirname;
if(~granularParams.isNil) { (scripts +/+ "gui-granular.scd").load };
l = ~tLooper.();
said = List.new;
dirs = ~tTempPath.("megaremote-looper-presets");
src = (looper: l, grainsPresetDir: dirs +/+ "granular", cutterPresetDir: dirs +/+ "bbcut", grainParams: ~granularParams,
    say: { |m| said.add(m) });
r = MegaRemote({ src });

// ---- describe
got = ask.(r, "{\"command\": \"describe\", \"args\": {\"topic\": \"grains\"}}").at("result");
o = got.at("settings").detect { |row| row.at("name") == "pitch" };
~tEq.("the grains: every setting with the range it is held to, the window's range, units and tip; the windows",
    [got.at("settings").size, o.at("label"), o.at("min"), o.at("max"), o.at("windowMin"), o.at("windowMax"), o.at("units"),
        o.at("tip").contains("semitones"), o.at("tip").contains("\n"), got.at("windows").size, got.at("windows")[3].at("name"),
        got.at("about").contains("morph")],
    [Looper.granularPresetFields.size, "Pitch", -48, 48, -24, 24, "st", true, false, 4, "Swell", true]);
~tEq.("...without the window's rows, the ranges alone",
    MegaRemote.describe("grains", ()).at("settings").collect { |row| [row.at("min"), row.at("tip")] }.first, [0, nil]);
got = ask.(r, "{\"command\": \"describe\", \"args\": {\"topic\": \"cutter\"}}").at("result");
o = got.at("procedures").detect { |p| p.at("key") == "break" };
~tEq.("the cutter: its procedures with their parameters, live or not, the pedal's; the synths, the effects, the modes",
    [got.at("procedures").collect { |p| p.at("key") }, o.at("pedal"), o.at("params").size,
        o.at("params")[1].at("whole"), o.at("params")[1].at("live"), o.at("params")[0].at("tip").isString,
        got.at("synths").collect(_.first), got.at("effects").size, got.at("modes").collect(_.first)],
    [["break", "bbcut11", "warp", "choose", "sqpusher"], "cutchance", 6, true, true, true,
        ["cutbuf1", "cutbuf2", "cutbuf3"], 6, ["mix", "insert", "gate"]]);
~tEq.("...and with no looper running, from a fresh one's tables",
    MegaRemote.describe("cutter", ()).at("procedures").size, 5);

// ---- the context
got = ask.(r, "{\"command\": \"context\"}").at("result");
~tEq.("the context: the grains (off, their settings, window, the arc's intensity) and the cutter (off, mode, one voice)",
    [got.at("grains").at("on"), got.at("grains").at("settings").at("amp"), got.at("grains").at("window"),
        got.at("grains").at("intensity"), got.at("cutter").at("on"), got.at("cutter").at("mode"),
        got.at("cutter").at("voices").size, got.at("cutter").at("voices")[0].at("proc"),
        got.at("cutter").at("voices")[0].at("params").keys.asArray.sort],
    [false, 0.7, "Hann (built in)", 1.0, false, "insert", 1, "break",
        ["cutchance", "maxblock", "minblock", "phraselength", "repeats", "rollchance"]]);

// ---- the grains
before = MegaFiles.json(MegaRemote.grainsOf(l));
got = ask.(r, "{\"command\": \"set_grains\", \"args\": {\"settings\": {\"pitch\": -12, \"spray\": 9000, \"morph\": 0.25}, \"window\": \"percussive\"}}");
~tEq.("set_grains sets the settings named and the window, says a value held to its range, leaves the rest",
    [got.at("ok"), l.granularPitch, l.granularSpray, l.granularMorph, l.granularEnv, l.granularAmp,
        got.at("result").at("corrections"), got.at("result").at("window"), r.changeCount],
    [true, -12, 2000, 0.25, 2, 0.7, ["grains.spray 9000 -> 2000.0"], "Percussive", 1]);
got = ask.(r, "{\"command\": \"set_grains\", \"args\": {\"on\": true}}");
~tEq.("...on with no loop recorded is refused by the looper, and the answer says so",
    [got.at("ok"), l.granularOn, got.at("result").at("corrections").first.contains("no loop recorded")], [true, false, true]);
refusals = [
    "{\"command\": \"set_grains\", \"args\": {}}",
    "{\"command\": \"set_grains\", \"args\": {\"settings\": {\"wobble\": 1}}}",
    "{\"command\": \"set_grains\", \"args\": {\"settings\": {\"pitch\": \"low\"}}}",
    "{\"command\": \"set_grains\", \"args\": {\"settings\": [1]}}",
    "{\"command\": \"set_grains\", \"args\": {\"window\": \"Gauss\"}}",
    "{\"command\": \"set_grains\", \"args\": {\"on\": 1}}"
].collect { |t| ask.(r, t) };
~tEq.("refused, changing nothing: nothing given, a setting that is none, a value no number, a window that is none, a switch no flag",
    refusals.collect { |x| x.at("ok") } ++ [r.changeCount, l.granularPitch], (false ! refusals.size) ++ [2, -12]);
got = ask.(r, "{\"command\": \"revert\", \"args\": {\"count\": 2}}");
~tEq.("revert puts the grains back as they were, window too",
    [got.at("ok"), MegaFiles.json(MegaRemote.grainsOf(l)) == before, l.granularEnv],
    [true, true, 0]);

// ---- the cutter
cutBefore = MegaFiles.json(MegaRemote.cutterOf(l));
got = ask.(r, "{\"command\": \"set_cutter\", \"args\": {\"voices\": [{\"params\": {\"cutchance\": 0.5, \"repeats\": 20}}, "
    "{\"proc\": \"warp\", \"ratio\": 1.5, \"fx\": [\"bpf\", \"rev\"], \"params\": {\"accel\": 1.2}}], \"mode\": \"gate\"}}");
o = l.bbcutVoices;
~tEq.("set_cutter merges a voice's params, adds a voice with its own procedure (its defaults under what is given), sets the mode",
    [got.at("ok"), o.size, o[0][\params][\cutchance], o[0][\params][\minblock], o[0][\params][\repeats],
        o[1][\proc], o[1][\ratio], o[1][\fx], o[1][\params][\accel], o[1][\params][\phraselength], l.bbcutMode],
    [true, 2, 0.5, 2, 8, \warp, 1.5, [\bpf, \rev], 1.2, 12, \gate]);
~tEq.("...says a value held to its range, and answers the cutter as it now stands",
    [got.at("result").at("corrections"), got.at("result").at("voices").size, got.at("result").at("voices")[1].at("fx")],
    [["voices[0].params.repeats 20 -> 8"], 2, ["bpf", "rev"]]);
got = ask.(r, "{\"command\": \"set_cutter\", \"args\": {\"voices\": [null, {\"fx\": []}], \"voiceCount\": 3}}");
~tEq.("...null keeps a voice, fx given replaces the list, voiceCount adds a new voice",
    [got.at("ok"), l.bbcutVoices.size, l.bbcutVoices[0][\params][\cutchance], l.bbcutVoices[1][\fx], l.bbcutVoices[1][\proc],
        l.bbcutVoices[2][\proc]],
    [true, 3, 0.5, [], \warp, \break]);
got = ask.(r, "{\"command\": \"set_cutter\", \"args\": {\"on\": true}}");
~tEq.("...on with no analysed take is refused by the looper, and the answer says so",
    [got.at("ok"), l.bbcut, got.at("result").at("corrections").first.contains("analysed take")], [true, false, true]);
refusals = [
    "{\"command\": \"set_cutter\", \"args\": {}}",
    "{\"command\": \"set_cutter\", \"args\": {\"mode\": \"blend\"}}",
    "{\"command\": \"set_cutter\", \"args\": {\"voiceCount\": 5}}",
    "{\"command\": \"set_cutter\", \"args\": {\"voices\": [null, null], \"voiceCount\": 1}}",
    "{\"command\": \"set_cutter\", \"args\": {\"voices\": {\"proc\": \"warp\"}}}",
    "{\"command\": \"set_cutter\", \"args\": {\"voices\": [{\"proc\": \"shuffle\"}]}}",
    "{\"command\": \"set_cutter\", \"args\": {\"voices\": [{\"synth\": \"cutbuf9\"}]}}",
    "{\"command\": \"set_cutter\", \"args\": {\"voices\": [{\"fx\": [\"flanger\"]}]}}",
    "{\"command\": \"set_cutter\", \"args\": {\"voices\": [{\"speed\": 2}]}}",
    "{\"command\": \"set_cutter\", \"args\": {\"voices\": [{\"ratio\": \"fast\"}]}}",
    // accel is warp's, not break's (voice 1 plays break)
    "{\"command\": \"set_cutter\", \"args\": {\"voices\": [{\"params\": {\"accel\": 1}}]}}",
    // Valid but for its last part: nothing of it may happen.
    "{\"command\": \"set_cutter\", \"args\": {\"mode\": \"mix\", \"on\": \"yes\"}}"
].collect { |t| ask.(r, t) };
~tEq.("refused whole, changing nothing: nothing given, a mode, a count, more voices than the count, a list no list, a procedure, a synth, an effect, a member, a value, a parameter of another procedure, or one part wrong",
    refusals.collect { |x| x.at("ok") } ++ [l.bbcutMode, l.bbcutVoices.size], (false ! refusals.size) ++ [\gate, 3]);
~tAssert.("...each saying why", refusals.every { |x| x.at("error").isString and: { x.at("error").size > 10 } },
    refusals.collect { |x| x.at("error") }.join(" | "));
got = ask.(r, "{\"command\": \"revert\", \"args\": {\"count\": 3}}");
~tEq.("revert puts the cutter back: its voices and its mode",
    [got.at("ok"), MegaFiles.json(MegaRemote.cutterOf(l)) == cutBefore, l.bbcutMode, r.changeCount], [true, true, \insert, 0]);

// ---- presets
protect {
    got = ask.(r, "{\"command\": \"save_grains_preset\", \"args\": {\"name\": \"AI Drone\"}}");
    ~tEq.("save_grains_preset writes the grains as a preset in the Grains view's folder",
        [got.at("ok"), got.at("result").at("saved"), l.granularPresetNames(src[\grainsPresetDir])], [true, "ai-drone", ["ai-drone"]]);
    got = ask.(r, "{\"command\": \"save_cutter_preset\", \"args\": {\"name\": \"AI Chop\"}}");
    ~tEq.("save_cutter_preset writes the cutter as a preset in the Cutter view's folder, and it reads back",
        [got.at("ok"), got.at("result").at("saved"), l.bbcutPresetNames(src[\cutterPresetDir]),
            l.loadBBCutPreset(src[\cutterPresetDir], "ai-chop")], [true, "ai-chop", ["ai-chop"], true]);
    ~tEq.("...a name taken is refused unless overwrite is true",
        [ask.(r, "{\"command\": \"save_cutter_preset\", \"args\": {\"name\": \"AI Chop\"}}").at("ok"),
            ask.(r, "{\"command\": \"save_cutter_preset\", \"args\": {\"name\": \"AI Chop\", \"overwrite\": true}}").at("ok"),
            ask.(r, "{\"command\": \"save_grains_preset\", \"args\": {\"name\": \"AI Drone\"}}").at("ok")],
        [false, true, false]);
} { ~tRemoveTree.(dirs) };
~tEq.("every grains and cutter change, revert and save was said in the status line",
    [said.count { |m| m.contains("grains") }, said.count { |m| m.contains("cutter") }], [2 + 1 + 1, 3 + 1 + 2]);
~tEq.("with no looper the grains and the cutter are refused",
    ["set_grains", "set_cutter", "save_grains_preset", "save_cutter_preset"].collect { |c|
        MegaRemote({ () }).handle("{\"command\": \"" ++ c ++ "\", \"args\": {\"name\": \"x\", \"on\": true}}").at(\error)
            .contains("no looper") },
    [true, true, true, true]);
}.value;
