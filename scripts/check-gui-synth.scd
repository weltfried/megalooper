// megalooper — does the Synth pane build, and does it stay honest? Without a
// rig: the pane is built from real Qt views against a REAL MegaSA on the test
// harness's recording stub server (its drums with the note sequencer, its
// Wave synth), never shown. The widgets and the model are driven against each
// other, the lanes through their own mouse handlers at known coordinates, and
// it exits 0 or 1. No server, no audio device, no window shown.
//
//   /Applications/SuperCollider.app/Contents/MacOS/sclang scripts/check-gui-synth.scd
//
// Its presets and its Keep go to a scratch folder named for this process.
(
var scripts = Looper.repoRoot +/+ "scripts";
var tmp = PathName.tmp +/+ ("megalooper-gui-synth-" ++ thisProcess.pid ++ "-" ++ Date.getDate.stamp);
var stub, sa, d, wv, pane, fam, w, h, now = 1000.0, l, pass = 0, fail = 0, fails = List.new;
var ok = { |label, cond, detail|
    if(cond == true) { pass = pass + 1; ("  ok    " ++ label).postln }
    { fail = fail + 1; fails.add(label ++ " — " ++ (detail ? ""));
      ("  FAIL  " ++ label ++ " — " ++ (detail ? "")).postln };
};
var section = { |label, f|
    ("== " ++ label ++ " ==").postln;
    try { f.value } { |err| ok.(label ++ ": ran to the end", false, err.errorString) };
};
var findButton = { |view, label|
    var found;
    var walk = { |v| v.children.do { |c|
        if((c.isKindOf(Button) or: { c.isKindOf(LooperTile) }) and: { c.states.notNil }
            and: { c.states.first.first == label }) { found = found ? c };
        walk.(c) } };
    walk.(view);
    found
};
// Every tile with `label`, in layout order.
var findButtons = { |view, label|
    var found = List.new;
    var walk = { |v| v.children.do { |c|
        if((c.isKindOf(Button) or: { c.isKindOf(LooperTile) }) and: { c.states.notNil }
            and: { c.states.first.first == label }) { found.add(c) };
        walk.(c) } };
    walk.(view);
    found
};
var tick = { 0.1.wait };
var run = { |to| while { now < (to - 1e-9) } { now = (now + 0.01).min(to); d.pump(now) } };

(scripts +/+ "tests" +/+ "_harness.scd").load;   // ~tStubServer, ~tMegaSA, ~tLooper
(scripts +/+ "parts.scd").load;
~megalooperLoadParts.(scripts);
~rp = (sa: true);
File.mkdir(tmp);
~saSynthPresetDir = tmp +/+ "synth-presets";
~midiUserRootOverride = tmp;
~guiPaneOrder = ~guiPaneOrderFor.(true);
~guiStack = nil;
~looper = nil;
w = ~synthCellWidth;
h = ~synthLaneHeight;

MegaSA.loadSynthDefs;
stub = ~tStubServer.();
sa = ~tMegaSA.(stub);
d = sa.drums;
wv = sa.wave;
~megaSA = sa;

Routine {
    section.("build", {
        pane = ~buildSynthPane.();
        tick.();
        ok.("the pane builds", pane.notNil and: { pane.isClosed.not });
        ok.("the steps and seven lanes, sixteen cells wide, although never shown",
            (~synthLanes.size == 8) and: { ~synthLanes.every { |v| v.bounds.width == (w * 16) } }
                and: { MegaSANoteSeq.laneNames.every { |k| ~synthLanes[k].bounds.height == h } },
            ~synthLanes.collect { |v| v.bounds }.asString);
        ok.("a widget for every pattern setting, the switch and the swing",
            (MegaSANoteSeq.settingNames ++ [\notesOn]).every { |n| ~synthWidgets[n].notNil },
            (MegaSANoteSeq.settingNames ++ [\notesOn]).reject { |n| ~synthWidgets[n].notNil }.asString);
        ok.("a widget for every Wave synth setting", MegaSAWave.params.every { |p| ~synthWidgets[("wave_" ++ p[\name]).asSymbol].notNil });
        ok.("Own, first, last and direction on every lane", MegaSANoteSeq.laneNames.every { |lane|
            [\own, \first, \last, \direction].every { |k| ~synthWidgets[("lane_" ++ lane ++ "_" ++ k).asSymbol].notNil } });
        ok.("the switch shows off, the menus the fresh pattern",
            (~synthWidgets[\notesOn][\view].value == 0) and: { ~synthWidgets[\division][\view].value == 4 }
                and: { ~synthWidgets[\scale][\view].items[~synthWidgets[\scale][\view].value] == "Minor" });
        ok.("the cutoff knob reads 3000 Hz", ~synthWidgets[\wave_waveCutoff][\readout].string == "3000 Hz",
            ~synthWidgets[\wave_waveCutoff][\readout].string);
        ok.("the Synth strip's level row is there", ~synthLevels[\synth].notNil);
        ok.("a lane's own steps are greyed while it follows the sequence",
            ~synthWidgets[\lane_pitch_first][\view].enabled.not);
    });

    section.("model -> view", {
        d.setNotesOn(true);
        d.setNoteSetting(\division, 3);
        d.setNoteSetting(\root, 2);
        wv.set(\waveCutoff, 1000);
        wv.set(\waveFilterType, 2);
        tick.();
        ok.("the switch, the rate and the root follow the model",
            [~synthWidgets[\notesOn][\view].value, ~synthWidgets[\division][\view].value, ~synthWidgets[\root][\view].value] == [1, 3, 2]);
        ok.("a knob and its readout follow the synth",
            ((~synthWidgets[\wave_waveCutoff][\view].value - MegaSAWave.param(\waveCutoff)[\spec].unmap(1000)).abs < 1e-6)
                and: { ~synthWidgets[\wave_waveCutoff][\readout].string == "1000 Hz" },
            ~synthWidgets[\wave_waveCutoff][\readout].string);
        ok.("a menu setting too", ~synthWidgets[\wave_waveFilterType][\view].value == 2);
        d.setNoteLaneSetting(\pitch, \own, true);
        tick.();
        ok.("Own lights and lets the lane's steps be set",
            (~synthWidgets[\lane_pitch_own][\view].value == 1) and: { ~synthWidgets[\lane_pitch_first][\view].enabled });
        d.setNoteLaneSetting(\pitch, \own, false);
        wv.reset;
        tick.();
        ok.("Reset sound repaints every knob", ~synthWidgets[\wave_waveCutoff][\readout].string == "3000 Hz");
    });

    section.("view -> model", {
        var lane = ~synthLanes[\pitch], steps = ~synthLanes[\steps], before, tool;
        ~synthWidgets[\division][\view].valueAction_(5);
        ok.("the rate menu sets the sequencer", d.notes[\division] == 5);
        ~synthWidgets[\wave_waveResonance][\view].valueAction_(0.5);
        ok.("a knob sets the synth", (wv[\waveResonance] - 0.5).abs < 1e-6, wv[\waveResonance].asString);
        ~synthWidgets[\wave_waveASet][\view].valueAction_(2);
        ok.("a table menu sets the synth", wv[\waveASet] == 2);
        lane.mouseDownAction.value(lane, (3 * w) + 5, 0, 0, 0, 1);
        ok.("a click at the top of the pitch lane sets the step to +12", d.notes[\lanes][\pitch][\values][3] == 12);
        lane.mouseDownAction.value(lane, (3 * w) + 5, h, 0, 0, 1);
        ok.("...at the bottom to -12", d.notes[\lanes][\pitch][\values][3] == -12);
        lane.mouseMoveAction.value(lane, (5 * w) + 5, h / 2);
        ok.("a drag sets the step it crosses", d.notes[\lanes][\pitch][\values][5] == 0);
        lane.mouseDownAction.value(lane, (3 * w) + 5, 0, 0, 0, 2);
        ok.("a double-click puts its default back", d.notes[\lanes][\pitch][\values][3] == 0);
        steps.mouseDownAction.value(steps, (7 * w) + 5, 5);
        ok.("a click on a step switches it off", d.notes[\steps][7] == false);
        steps.mouseMoveAction.value(steps, (8 * w) + 5, 5);
        ok.("...a drag across switches the next the same way", d.notes[\steps][8] == false);
        steps.mouseDownAction.value(steps, (7 * w) + 5, 5);
        steps.mouseMoveAction.value(steps, (8 * w) + 5, 5);
        ok.("...and on again", (d.notes[\steps][7] == true) and: { d.notes[\steps][8] == true });
        before = d.notes[\lanes][\pitch][\values].copy;
        tool = findButtons.(pane, "▶")[0];
        tool.valueAction_(0);
        ok.("▶ on the pitch lane: every step one later", d.notes[\lanes][\pitch][\values] == before.rotate(1),
            d.notes[\lanes][\pitch][\values].asString);
        findButtons.(pane, "◀")[0].valueAction_(0);
        findButtons.(pane, "▲")[0].valueAction_(0);
        ok.("◀ back, ▲ every step up one, within the range", d.notes[\lanes][\pitch][\values] == before.collect { |v| (v + 1).min(12) });
        findButtons.(pane, "Reset")[0].valueAction_(0);
        ok.("Reset: the lane's defaults", d.notes[\lanes][\pitch][\values] == (0 ! 16));
        findButtons.(pane, "Random")[2].valueAction_(0);
        ok.("Random on the velocity lane: within its range", d.notes[\lanes][\velocity][\values].every { |v| (v >= 67) and: { v <= 127 } });
        findButton.(pane, "Random sound").valueAction_(0);
        ok.("Random sound draws a new sound, its level kept", wv[\waveLevel] == -6);
        findButton.(pane, "Reset sound").valueAction_(0);
        ok.("Reset sound: every default", MegaSAWave.params.every { |p| wv[p[\name]] == p[\spec].default });
        ~synthWidgets[\notesOn][\view].valueAction_(0);
        ok.("the switch switches the sequencer", d.notesOn == false);
    });

    section.("the playhead", {
        l = ~tLooper.();
        ~tPut.(l, \state, \playing);
        ~tPut.(l, \loopFrames, 96000);
        ~tPut.(l, \loopStartTime, now);
        ~tPut.(l, \lastResult, (numerator: 4, denominator: 4, k: 1, bpm: 120, loopDur: 2.0));
        d.wallClock = { now };
        d.sender = { |t, msgs| };
        d.attach(l);
        d.setNoteSetting(\division, 4);
        d.setNotesOn(true, now);
        d.transportStart(now);
        run.(now + 0.6);
        ~synthStack = nil;
        ~synthPollPlayhead.(true);
        ok.("while it plays, the playhead is the sequencer's", ~synthPlayhead.notNil and: { ~synthPlayhead[\main].isInteger },
            ~synthPlayhead.asString);
        d.setNotesOn(false, now);
        ~synthPollPlayhead.(true);
        ok.("switched off, none", ~synthPlayhead.isNil);
    });

    section.("presets and Keep", {
        fam = ~presetFamily.(\saSynth);
        d.setNoteValue(\pitch, 2, 7);
        wv.set(\waveCutoff, 777);
        fam[\nameField].string_("Gui Check");
        ~presetSave.(\saSynth);
        ok.("Save writes the preset", File.exists(~saSynthPresetDir +/+ "gui-check.json"));
        ok.("the menu selects it", fam[\items][fam[\menu].value] == "gui-check", fam[\menu].items.asString);
        d.setNoteValue(\pitch, 2, 0);
        wv.set(\waveCutoff, 3000);
        ~presetLoad.(\saSynth, "gui-check");
        tick.();
        ok.("Load brings the pattern and the sound back", (d.notes[\lanes][\pitch][\values][2] == 7)
            and: { (wv[\waveCutoff] - 777).abs < 0.5 }, [d.notes[\lanes][\pitch][\values][2], wv[\waveCutoff]].asString);
        ok.("...and the pane shows them", ~synthWidgets[\wave_waveCutoff][\readout].string == "777 Hz",
            ~synthWidgets[\wave_waveCutoff][\readout].string);
        findButton.(pane, "Start with this").valueAction_(0);
        ok.("Start with this keeps them for the next boot", File.exists(~saKeptSynthPath.()), ~saKeptSynthPath.());
        d.setNoteValue(\pitch, 2, 0);
        wv.set(\waveCutoff, 3000);
        ok.("...and a boot starts with them", ~saLoadKeptSynth.() and: { d.notes[\lanes][\pitch][\values][2] == 7 });
    });

    section.("the instrument", {
        var menu = ~synthWidgets[\instrument][\view], fake;
        ok.("the instrument menu starts on the Wave synth", (menu.items[0] == "Wave synth") and: { menu.value == 0 });
        sa.catalog = [(key: "Fake Synth", name: "Fake Synth", synth: true, bridged: false)];
        fake = ~tFakePlugin.(\open, "Fake Synth");
        fake[\midiMsg] = { |self, st, a, b| [\midi, st, a, b] };
        sa.pluginMaker = { fake };
        pane = ~buildSynthPane.();
        tick.();
        menu = ~synthWidgets[\instrument][\view];
        ok.("with an instrument scanned, it is in the menu", menu.items == ["Wave synth", "Fake Synth"], menu.items.asString);
        menu.valueAction_(1);
        tick.();
        ok.("choosing it plays it", sa.instrumentKey == "Fake Synth");
        ok.("...and the line says it is open", ~synthWidgets[\instrumentLine][\view].string == "open",
            ~synthWidgets[\instrumentLine][\view].string);
        sa.setInstrument(nil);
        tick.();
        ok.("back to the Wave synth from elsewhere: the menu follows", menu.value == 0);
    });

    section.("your table", {
        var dir = tmp +/+ "tables", sf = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(1);
        File.mkdir(dir);
        sf.openWrite(dir +/+ "mine.wav");
        sf.writeData(Signal.fill(2048, { |i| sin(2pi * i / 2048) }).as(FloatArray));
        sf.close;
        ok.("with none, the row says the set plays Analog's", ~synthWidgets[\tableName][\view].string.contains("Analog"));
        MegaFiles.rootOverride = tmp +/+ "user";
        ~synthImportTable.(dir +/+ "mine.wav");
        tick.();
        ok.("a table loaded: the row names it", ~synthWidgets[\tableName][\view].string == "mine.wav",
            ~synthWidgets[\tableName][\view].string);
        fam = ~presetFamily.(\saSynth);
        fam[\nameField].string_("With Table");
        ~presetSave.(\saSynth);
        wv.clearTable;
        tick.();
        ok.("None: back to none", wv.tableName.isNil and: { ~synthWidgets[\tableName][\view].string.contains("Analog") });
        ~presetLoad.(\saSynth, "with-table");
        tick.();
        ok.("a preset brings its table back", (wv.tableName == "mine.wav") and: { ~synthWidgets[\tableName][\view].string == "mine.wav" },
            wv.tableName.asString);
        ok.("a file that is no table: refused, said", ~synthImportTable.(dir +/+ "missing.wav").isString);
    });

    section.("the loop's key", {
        var key = (root: 4, pcs: [2, 4, 7, 9, 11], intervals: [0, 3, 5, 7, 10], name: "Minor pentatonic", scale: 11,
            inside: 0.86, margin: 0.02, core: false, cents: 18, heard: (pcs: [2, 4, 7, 9, 11], name: "Minor pentatonic"),
            chroma: [0, 0, 0.9, 0, 1, 0, 0.1, 0.6, 0, 0.5, 0, 0.8]);
        var words = { ~synthWidgets[\heard][\view].string };
        d.setNoteSetting(\fromLoop, true);
        tick.();
        ok.("From the loop has its switch, lit; nothing heard yet",
            (~synthWidgets[\fromLoop][\view].value == 1) and: { words.().beginsWith("nothing heard") }, words.());
        d.setLoopKey(key);
        tick.();
        ok.("a key heard: the menus show its root and scale", [~synthWidgets[\root][\view].value,
            ~synthWidgets[\scale][\view].value] == [4, 11],
            [~synthWidgets[\root][\view].value, ~synthWidgets[\scale][\view].value].asString);
        ok.("...and Heard says it, with its share and the tuning",
            words.() == "E Minor pentatonic  ·  86 % of it in the scale  ·  tuning +18 ct", words.());
        ok.("...its twelve bars paint", ~synthKeyView.notNil and: { ~synthKeyView.isClosed.not }
            and: { ~synthKeyView.bounds.width == 240 });
        ~synthWidgets[\scale][\view].valueAction_(2);
        tick.();
        ok.("a scale chosen from the menu: Dorian from the loop's root, From the loop off",
            (d.notes.atAll(#[\root, \scale, \fromLoop]) == [4, 2, false]) and: { ~synthWidgets[\fromLoop][\view].value == 0 }
                and: { words.().endsWith("not followed") },
            d.notes.atAll(#[\root, \scale, \fromLoop]).asString + words.());
        ~synthWidgets[\fromLoop][\view].valueAction_(1);
        tick.();
        ok.("...the switch on again follows the key", (d.notes[\fromLoop] == true) and: { ~synthWidgets[\scale][\view].value == 11 });
        d.setLoopKey(key.copy.putAll((period: 8.0, sections: [
            (from: 0, to: 2, at: 0, key: (root: 4, pcs: [2, 4, 7, 9, 11], name: "Minor pentatonic", scale: 11)),
            (from: 2, to: 4, at: 4.0, key: (root: 6, pcs: [1, 4, 6, 9, 11], name: "Minor pentatonic", scale: 11))])));
        tick.();
        ok.("a key that changes: Heard says its sections, bar by bar, and Changes is on",
            (words.() == "bars 1–2 E Minor pentatonic, 3–4 F# Minor pentatonic  ·  tuning +18 ct")
                and: { ~synthWidgets[\loopChanges][\view].value == 1 } and: { ~synthWidgets[\loopChanges][\view].enabled }, words.());
        ~synthWidgets[\loopChanges][\view].valueAction_(0);
        tick.();
        ok.("...Changes off: one key for the loop, said so", (d.notes[\loopChanges] == false)
            and: { words.().contains("changes not followed") }, words.());
        d.setNoteSetting(\fromLoop, false);
        tick.();
        ok.("...From the loop off greys Changes", ~synthWidgets[\loopChanges][\view].enabled.not);
        d.setNoteSetting(\fromLoop, true);
        d.setNoteSetting(\loopChanges, true);
        d.setLoopKey(nil);
        tick.();
        ok.("the key gone: the menus show the pattern's own again", (~synthWidgets[\scale][\view].value == 2)
            and: { words.().beginsWith("nothing heard") });
    });

    section.("the view", {
        var views = ~guiViewOrderFor.(true);
        ok.("SA's views: the Synth after the Drums", views == [\perform, \sound, \fx, \drums, \synth, \setup, \calibrate], views.asString);
        ok.("its key is 7, no other key moved", ~guiViewNumbers == (perform: 1, sound: 2, fx: 3, drums: 4, setup: 5, calibrate: 6, synth: 7));
        ~guiViewOrder = views;
        ok.("the footer says the keys as runs", ~guiKeysHint.().beginsWith("keys 1–5 7 views · 6 calibrate"), ~guiKeysHint.());
        ~guiViewOrder = ~guiViewOrderFor.(false);
        ok.("...and without SA as before", ~guiKeysHint.().beginsWith("keys 1 2 5 views"), ~guiKeysHint.());
        ok.("its tab dots the synth, in its colour", ~guiViewDots[\synth] == [[\synth, \synth]]);
    });

    sa.free;
    ~tRemoveTree.(tmp);
    "".postln;
    if(fail == 0) { ("SYNTH PANE CHECK PASSED — " ++ pass ++ " checks").postln }
    { ("SYNTH PANE CHECK FAILED — " ++ fail ++ " of " ++ (pass + fail)).postln;
      fails.do { |f| ("  " ++ f).postln } };
    if(fail == 0) { 0.exit } { 1.exit };
}.play(AppClock);
)
