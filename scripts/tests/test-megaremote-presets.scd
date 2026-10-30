// The player's own presets, loaded by the AI (MegaRemote's load_drum_preset
// and load_synth_preset, docs/dev/ai-tool.md section 15): the context lists
// the Drums and Synth views' presets and the one each shows as loaded; a
// load recalls a preset as the view's menu does, by its slug or the name it
// was saved under, selects it in the view, and is taken back by revert,
// which selects there what was shown before. A name there is not, no name, no
// folder, and a file that is no preset are refused, changing nothing. The
// synth's revert puts back your table and the instrument: a plugin a
// preset's instrument replaced comes back with the sound it wrote first (a
// fake plugin here, which answers at once, fails, or never answers).

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-megaremote-presets");

{
var ask = { |remote, text| MegaFiles.parseObject(MegaFiles.json(remote.handle(text))) };
var load = { |remote, command, name| ask.(remote, "{\"command\": \"" ++ command ++ "\", \"args\": {\"name\": \"" ++ name ++ "\"}}") };
var root = ~tTempPath.("megaremote-presets"), was = MegaFiles.rootOverride;
var stub = ~tStubServer.(), sa, d, r, got, o, src, said = List.new, shown = (), showCalls = List.new;
var drumsDir = root +/+ "drum-presets", synthDir = root +/+ "synth-presets", before, notesBefore, made = List.new;
var fake, sf, state, kept;
MegaSA.loadSynthDefs;
File.mkdir(root);
MegaFiles.rootOverride = root;
protect {
    sa = ~tMegaSA.(stub);
    d = sa.drums;
    // A kit asked for is the drums' at once; its buffers never come here.
    d.kitReader = { |path, done| };
    src = (looper: nil, sa: sa, profile: \sa, drumsPresetDir: drumsDir, synthPresetDir: synthDir,
        say: { |m| said.add(m) }, presetShown: { |part| shown[part] },
        showPreset: { |part, slug| showCalls.add([part, slug]); shown[part] = slug });

    // ---- the drums ----
    // A preset whose main pattern's first delay step is 17, saved through
    // another MegaRemote whose changes are then taken back.
    before = d.patterns[\main].deepCopy;
    r = MegaRemote({ src });
    r.handle("{\"command\": \"set_drum_pattern\", \"args\": {\"pattern\": {\"delay\": [17]}}}");
    d.savePreset(drumsDir, "Groove");
    r.handle("{\"command\": \"revert\"}");
    ~tEq.("(the drums are as they were, the preset holds the change)",
        [d.patterns[\main], showCalls.size], [before, 0]);

    r = MegaRemote({ src });
    got = ask.(r, "{\"command\": \"context\"}").at("result").at("drums");
    ~tEq.("the context lists the Drums view's presets, and none shown as loaded",
        [got.at("presets"), got.at("loadedPreset")], [["groove"], nil]);

    got = load.(r, "load_drum_preset", "Groove");
    ~tEq.("load_drum_preset by the name it was saved under: recalled, selected in the view, said, one change",
        [got.at("ok"), got.at("result").at("loaded"), d.patterns[\main][\delay][0], showCalls.asArray,
            said.last.contains("loaded the drum preset \"groove\""), got.at("result").at("aiChanges")],
        [true, "groove", 17.0, [[\drums, "groove"]], true, 1]);
    ~tEq.("...the answer holds the drums as they now are, no corrections",
        [got.at("result").at("drums").at("patterns").at("main").at("delay")[0], got.at("result").at("corrections")],
        [17.0, []]);
    ~tEq.("...and the context says it is the one shown",
        ask.(r, "{\"command\": \"context\"}").at("result").at("drums").at("loadedPreset"), "groove");

    r.handle("{\"command\": \"set_drum_pattern\", \"args\": {\"pattern\": {\"delay\": [3]}}}");
    got = ask.(r, "{\"command\": \"revert\"}");
    ~tEq.("a change after it, taken back: the preset as loaded, still selected (nothing to select again)",
        [got.at("ok"), d.patterns[\main][\delay][0], showCalls.size], [true, 17.0, 1]);

    File.use(drumsDir +/+ "bad.scd", "w", { |f| f.write("(version: 99, name: \"from later\")") });
    ~tEq.("refused, changing nothing: no name, a blank one, a preset there is not, a file that is no preset",
        [
            ask.(r, "{\"command\": \"load_drum_preset\", \"args\": {}}").at("ok"),
            load.(r, "load_drum_preset", "  ").at("ok"),
            load.(r, "load_drum_preset", "Funk").at("ok"),
            load.(r, "load_drum_preset", "bad").at("ok"),
            r.changeCount, d.patterns[\main][\delay][0], showCalls.size
        ],
        [false, false, false, false, 1, 17.0, 1]);
    ~tEq.("...a preset there is not is answered with those there are; a file that is no preset says it was not read",
        [load.(r, "load_drum_preset", "Funk").at("error"), load.(r, "load_drum_preset", "bad").at("error").contains("could not be read")],
        ["there is no drum preset \"Funk\"; there are bad, groove", true]);
    File.delete(drumsDir +/+ "bad.scd");

    got = load.(r, "load_drum_preset", "groove");
    ~tEq.("by its slug as the context lists it", [got.at("ok"), r.changeCount], [true, 2]);
    got = ask.(r, "{\"command\": \"revert\", \"args\": {\"count\": 2}}");
    ~tEq.("revert: the drums as they were before, nothing selected in the view again",
        [got.at("ok"), got.at("result").at("reverted"), d.patterns[\main], showCalls.last, shown[\drums]],
        [true, ["drum preset \"groove\"", "drum preset \"groove\""], before, [\drums, nil], nil]);

    ~tEq.("no folder, or an empty one, is said",
        [MegaRemote({ (sa: sa) }).handle("{\"command\": \"load_drum_preset\", \"args\": {\"name\": \"x\"}}").at(\error),
            MegaRemote({ (sa: sa, drumsPresetDir: root +/+ "none") })
                .handle("{\"command\": \"load_drum_preset\", \"args\": {\"name\": \"x\"}}").at(\error)],
        ["there is no folder for drum presets", "there is no drum preset \"x\"; there are none yet"]);

    // ---- the synth, on the Wave synth ----
    notesBefore = MegaSANoteSeq.copyPattern(d.notes);
    d.setNotes(MegaRemote.mergePattern(notesBefore, (root: 2)));
    sa.saveSynthPreset(synthDir, "Line");
    d.setNotes(notesBefore);
    got = ask.(r, "{\"command\": \"context\"}").at("result").at("synth");
    ~tEq.("the context lists the Synth view's presets", [got.at("presets"), got.at("loadedPreset")], [["line"], nil]);
    got = load.(r, "load_synth_preset", "Line");
    ~tEq.("load_synth_preset: the note pattern recalled, the sequencer's switch as it was, selected in the view",
        [got.at("ok"), d.notes[\root], d.notesOn, got.at("result").at("instrumentComing"), showCalls.last,
            got.at("result").at("synth").at("notes").at("root")],
        [true, 2, false, false, [\synth, "line"], 2]);
    got = ask.(r, "{\"command\": \"revert\"}");
    ~tEq.("...taken back: the pattern as it was, nothing selected", [got.at("ok"), d.notes, shown[\synth]], [true, notesBefore, nil]);

    // ---- your table ----
    sf = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(1).sampleRate_(48000);
    File.mkdir(MegaSAWave.tableDir);
    sf.openWrite(MegaSAWave.tableDir +/+ "saw.wav");
    sf.writeData(Signal.fill(2048, { |i| (1 .. 20).sum { |m| sin(m * 2pi * i / 2048) / m } }).as(FloatArray));
    sf.close;
    ~tEq.("(a table of yours)", sa.wave.loadTableNamed("saw.wav"), true);
    sa.saveSynthPreset(synthDir, "Saw");
    sa.wave.clearTable;
    load.(r, "load_synth_preset", "saw");
    ~tEq.("a preset with your table plays it", sa.wave.tableName, "saw.wav");
    got = ask.(r, "{\"command\": \"revert\"}");
    ~tEq.("...taken back: Analog's again", [got.at("ok"), sa.wave.tableName, got.at("result").at("corrections")], [true, nil, []]);

    // ---- an instrument plugin ----
    fake = { |how|
        var p = ~tFakePlugin.(\open, "Fake Synth");
        p[\midiMsg] = { |self, status, a, b| [\midi, status, a, b] };
        // \silent: it never answers a save; \fails: it answers that it failed.
        if(how == \silent) { p[\saveState] = { |self, kind, file, action| } };
        if(how == \fails) { p[\saveFails] = true };
        made.add(p);
        p
    };
    sa.pluginMaker = { |synth, id, path| fake.(\answers) };
    sa.setInstrument("Fake Synth");
    sa.saveSynthPreset(synthDir, "Plugged");
    sa.setInstrument(nil);

    got = load.(r, "load_synth_preset", "plugged");
    ~tEq.("a preset with a plugin, over the Wave synth: it plays, with the sound the preset kept, at once",
        [got.at("ok"), sa.instrumentKey, made.last[\openedWith] !? { |x| x[\path].basename }, got.at("result").at("instrumentComing")],
        [true, "Fake Synth", "plugged.fxp", false]);
    got = ask.(r, "{\"command\": \"revert\"}");
    ~tEq.("...taken back: the Wave synth again", [got.at("ok"), sa.instrumentKey, got.at("result").at("corrections")], [true, nil, []]);

    sa.setInstrument("Fake Synth");
    o = made.last;
    got = load.(r, "load_synth_preset", "line");
    state = (MegaRemote.statesDir +/+ "*.fxp").pathMatch;
    ~tEq.("a Wave preset over a plugin: the plugin's sound is written to the AI's folder first, then the Wave synth plays",
        [got.at("ok"), o[\saves], state.size, sa.instrumentKey, d.notes[\root]], [true, 1, 1, nil, 2]);
    got = ask.(r, "{\"command\": \"revert\"}");
    ~tEq.("...taken back: the plugin again, with the sound it had",
        [got.at("ok"), sa.instrumentKey, made.last[\openedWith] !? { |x| x[\path] }, got.at("result").at("corrections"), d.notes],
        [true, "Fake Synth", state[0], [], notesBefore]);

    sa.pluginMaker = { |synth, id, path| fake.(\fails) };
    sa.setInstrument("Fake Synth");
    load.(r, "load_synth_preset", "line");
    got = ask.(r, "{\"command\": \"revert\"}");
    ~tEq.("a plugin that could not write its sound: the preset still loaded, and the revert says the sound is not back",
        [got.at("ok"), sa.instrumentKey, got.at("result").at("corrections")],
        [true, "Fake Synth", ["Fake Synth is back with the sound it opens with: its own was not kept"]]);

    sa.pluginMaker = { |synth, id, path| fake.(\silent) };
    sa.setInstrument("Fake Synth");
    got = load.(r, "load_synth_preset", "line");
    ~tEq.("a plugin that does not answer: the preset's notes now, its instrument waits",
        [got.at("ok"), got.at("result").at("instrumentComing"), sa.instrumentKey, d.notes[\root]], [true, true, "Fake Synth", 2]);
    got = ask.(r, "{\"command\": \"revert\"}");
    ~tEq.("...a revert meanwhile lets it come in first, then puts the plugin back",
        [got.at("ok"), sa.instrumentKey, d.notes, got.at("result").at("corrections").size], [true, "Fake Synth", notesBefore, 1]);
    r.stop;
    ~tEq.("...and nothing waits any more", sa.instrumentKey, "Fake Synth");
    load.(r, "load_synth_preset", "line");
    kept = sa.instrumentKey;
    r.stop;
    ~tEq.("...and MegaRemote stopping lets it come in", [kept, sa.instrumentKey], ["Fake Synth", nil]);

    ~tEq.("with no synth, or no folder, a synth preset is refused",
        [MegaRemote({ () }).handle("{\"command\": \"load_synth_preset\", \"args\": {\"name\": \"x\"}}").at(\error)
            .contains("runs on a rig without"),
            MegaRemote({ (sa: sa) }).handle("{\"command\": \"load_synth_preset\", \"args\": {\"name\": \"x\"}}").at(\error)],
        [true, "there is no folder for synth presets"]);
    sa.free;
} {
    MegaFiles.rootOverride = was;
    ~tRemoveTree.(root);
};
}.value;
