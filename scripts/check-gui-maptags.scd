// megalooper — does every control on screen carry its MIDI Map tag, and does
// map mode lay a mask over each? Without a rig: the whole window is built and
// never shown, with the SA rig's tabs, against a Looper with no server, a
// MegaSA whose server is a recording stub and real drums reading the shipped
// kits, as check-gui-effects.scd and check-gui-drums.scd build theirs. No
// MIDI responder is registered and no MIDIClient made. It exits 0 or 1.
//
//   /Applications/SuperCollider.app/Contents/MacOS/sclang scripts/check-gui-maptags.scd
//
// Checked: every tagged view (~mapTag, gui-const.scd) names a control the
// router has (setup-miditargets.scd); every control on a tab is tagged there,
// but for the few with no widget (listed below, with why); map mode lays one
// mask over every tagged view, a click on one arms its control, and leaving
// takes every mask and every resize hook away. A Drums knob's tag follows the
// pattern and page shown, so the tags are read with each of them shown.
//
// Nothing is written to the real preset folders or to ~/Library/Application
// Support/SuperCollider/megalooper: both go to a scratch folder named for this
// process.
(
var scripts = Looper.repoRoot +/+ "scripts";
var kitDir = Looper.repoRoot +/+ "presets" +/+ "sa" +/+ "drums" +/+ "kits";
var pass = 0, fail = 0, fails = List.new;
var ok = { |label, cond, detail|
    if(cond == true) { pass = pass + 1; ("  ok    " ++ label).postln }
    { fail = fail + 1; fails.add(label ++ " — " ++ (detail ? ""));
      ("  FAIL  " ++ label ++ " — " ++ (detail ? "")).postln };
};
var section = { |label, f|
    ("== " ++ label ++ " ==").postln;
    try { f.value } { |err| ok.(label ++ ": ran to the end", false, err.errorString) };
};
var reader = { |srv, path, done|
    done.((bufnum: 100, path: path, numChannels: 2, sampleRate: 48000, numFrames: 48000)) };
var msgs = List.new, stub, sstub, m, d, plug, tmp, now = 1000.0;
// The controls with no widget of their own, and why. Every other control
// whose tab the window has must be tagged on it.
var noWidget = IdentityDictionary[
    'live.record' -> "Live's arrangement record: no widget, mapped from the list"
];

(scripts +/+ "tests" +/+ "_harness.scd").load;
[
    "setup-routing.scd", "setup-midi.scd", "setup-model.scd", "setup-sa.scd", "setup-miditargets.scd", "setup-midimap.scd",
    "gui-const.scd", "gui-theme.scd", "gui-presets.scd", "gui-status.scd", "gui-perform.scd",
    "gui-bbcut.scd", "gui-granular.scd", "gui-analysis.scd", "gui-sa.scd", "gui-midimap.scd", "gui-mapmode.scd",
    "gui-effects.scd", "gui-drums.scd", "gui-synth.scd", "gui-rig.scd", "gui-calibrate.scd",
    "gui-shell.scd", "gui-wiring.scd"
].do { |f| (scripts +/+ f).load };
tmp = ~tTempPath.("check-gui-maptags");
File.mkdir(tmp);
~midiUserRootOverride = tmp +/+ "user";
~midiWriteSync = true;
~saFxPresetDir = tmp +/+ "fx";
~saDrumsPresetDir = tmp +/+ "drum-presets";
~saSynthPresetDir = tmp +/+ "synth-presets";
File.mkdir(~saFxPresetDir);
File.mkdir(~saDrumsPresetDir);
~midiNow = { now };
~routingProfile = \sa;
~rp = ~routingProfiles[\sa];
~looper = ~tLooper.();
~liveRecordToggle = { };

// MegaSA as the Effects tab sees it (check-gui-effects.scd), with real drums
// on a stub server as the Drums tab sees them (check-gui-drums.scd).
// A real MegaSA on the harness's recording stub (~tMegaSA), its plugin one that
// failed to open, a Looper attached for the loop's effects. Its own drums
// make way for the ones below.
stub = ~tStubServer.();
msgs = stub[\msgs];
// With a bass input, as on the duo's rig, so the bass's strip has its widgets.
m = ~tMegaSA.(stub, ~tFakePlugin.(\failed), nil, nil, nil, nil, 1);
Routine { m.attachLooper(~looper) }.next;
m.drums.free;
sstub = ~tStubServer.();
d = MegaSADrums((server: sstub));
d.prUseBusses;
d.wallClock = { now };
d.sender = { |t, msgs| };
d.kitDir = kitDir;
d.kitReader = reader;
d.setKit(\steps, 'carbon-layer');
d.setKit(\onset, 'one-hit');
m.instVarPut(\drums, d);
~megaSA = m;

~midiSources = IdentityDictionary[1001 -> ["TSMEGA", "TSMEGA"]];
~midiTargets = ~midiTargetsBuild.();
~midiMap = ~midiMapLoad.("tsmega")[\map];
~midiKept = ~midiMap;
~midiMapFrom = \shipped;
~midiMapWarning = nil;
~midiUndo = List.new;
~midiListenFrom.(~midiSettingsRead.());

Routine {
    var tick = { 0.2.wait };
    var tags, ids, unknown, covered, missing, byTab, tabs, pages, mask, e, k, hooked;
    section.("the window builds, never shown", {
        ~mapTags = List.new;
        ~buildGuiWindow.(false);
        tick.();
        ok.("the window is built", ~guiWindow.notNil and: { ~guiWindow.isClosed.not });
        ok.("with the SA rig's tabs", ~guiPaneOrder.includes(\effects) and: { ~guiPaneOrder.includes(\drums) },
            ~guiPaneOrder.asString);
        // The effects and the drums each have a view of their own: a page of
        // the stack and a tab. Two panes of one view share one more ancestor
        // (the page) than two panes of different views do.
        { var shared = { |a, b|
              var pa = ~guiPaneHolders[a].parents ? [], pb = ~guiPaneHolders[b].parents ? [];
              pa.count { |p| pb.includes(p) } };
          ok.("SA's views: Perform, Sound, FX, Drums, Synth, Setup and the wizard",
              ~guiViewOrder == [\perform, \sound, \fx, \drums, \synth, \setup, \calibrate], ~guiViewOrder.asString);
          ok.("a tab for each but the wizard", ~guiViewOrder.reject { |v| v == \calibrate }.every { |v| ~guiTabButtons[v].notNil }
              and: { ~guiTabButtons[\calibrate].isNil });
          ok.("the Drums pane is on a page of its own, apart from the Effects' as Perform's is",
              (shared.(\effects, \drums) == shared.(\effects, \perform)) and: { shared.(\effects, \drums) > 0 }
                  and: { shared.(\cutter, \grains) == (shared.(\effects, \drums) + 3) },
              [shared.(\effects, \drums), shared.(\effects, \perform), shared.(\cutter, \grains)].asString);
          ~guiSelectView.(\drums);
          ok.("key 4's view is the Drums", (~guiView == \drums) and: { ~guiStack.index == ~guiViewOrder.indexOf(\drums) },
              [~guiView, ~guiStack.index].asString);
          ~guiSelectView.(\perform) }.value;
        // The map bar, hidden, must not set the window's width: the screen
        // does (1440 pt, or less on a smaller one).
        ok.("no wider than asked: the map bar doesn't widen it",
            ~guiWindow.bounds.width <= 1440, ~guiWindow.bounds.width.asString);
    });

    section.("Perform's Synth column", {
        var w = ~megaSA.wave, d = ~megaSA.drums, cut = MegaSAWave.param(\waveCutoff);
        ok.("Perform has a column for the synth, after the drums'", ~performColumns[\synth].notNil
            and: { ~performSynthTile.notNil } and: { ~performSynthTile.isClosed.not });
        d.setNotesOn(false);
        ~performSynthTile.valueAction_(1);
        ok.("its tile switches the note sequencer", d.notesOn == true);
        ~performSynthCutoff.valueAction_(cut[\spec].unmap(1000));
        ok.("its Cutoff bar sets the Wave synth", (w[\waveCutoff] - 1000).abs < 1, w[\waveCutoff].asString);
        ~performPaintSynth.();
        ok.("...and reads it back", ~performSynthCutoffLabel.string == "1000 Hz", ~performSynthCutoffLabel.string);
        ok.("its line says the key, the rate and what plays", ~performColumns[\synth][\note].string == "C Minor · 1/16 · Wave synth",
            ~performColumns[\synth][\note].string);
        w.reset;
        d.setNotesOn(false);
        ~performPaintSynth.();
        ok.("switched off, its tile is dark", ~performSynthTile.value == 0);
    });

    section.("every tag names a control", {
        tags = ~mapLiveTags.();
        ("  " ++ tags.size ++ " views tagged").postln;
        ok.("views are tagged", tags.size > 0, tags.size.asString);
        unknown = tags.select { |t| var id = t[1].value; id.isNil or: { ~midiTargets[id].isNil } };
        ok.("each names a control the router has", unknown.isEmpty,
            unknown.collect { |t| t[1].value.asString ++ " on a " ++ t[0].class }.asString);
        // A Drums knob's tag, read with each pattern and page shown.
        covered = IdentitySet.new;
        pages = (MegaSASteps.pages ? [\chance]);
        [\main, \break].do { |pattern|
            pages.do { |page|
                ~drumsPattern = pattern;
                ~drumsPage = page;
                tags.do { |t| t[1].value !? { |id| covered.add(id) } };
            };
        };
        ~drumsPattern = \main;
        ~drumsPage = pages.first;
        // The Effects editor shows one effect at a time, built when its tile
        // is selected: each one's, in turn.
        k = ~effectsSelected;
        // The plugin's page has its sends' tiles.
        (MegaSAFx.keys ++ [\bias]).do { |key|
            ~effectsSelect.(key);
            ~mapLiveTags.().do { |t| t[1].value !? { |id| covered.add(id) } };
        };
        ~effectsSelect.(k);
        ok.("the plugin's eight sends are tagged on its page",
            (1..8).every { |n| covered.includes(("sa.fxSend.plugin1." ++ n).asSymbol) },
            covered.asArray.select { |id| id.asString.beginsWith("sa.fxSend") }.sort.asString);
        // Every control on a tab this window has, by tab. A trim has a knob
        // only for a pad the lanes play, the onset pad and the steps kit's
        // layers (~drumsTrimRow): the others are mapped from the list.
        tabs = ~guiPaneOrder.collect { |k| ~guiPaneLabels[k] } ++ ["Header"];
        missing = ~midiTargets.keys.asArray.sort.select { |id|
            var t = ~midiTargets[id], s = id.asString, parts = s.split($.), shown = true;
            if(s.beginsWith("sa.drums.trim.")) { shown = ~drumsWidgets[~drumsTrimKey.(parts[3].asSymbol, parts[4].asInteger)].notNil };
            // Layer knobs are the steps kit's only.
            if(s.beginsWith("sa.drums.groupTrim.")) {
                shown = (parts[3] == "steps") and: { ~drumsWidgets[~drumsGroupKey.(parts[4].asSymbol)].notNil } };
            tabs.includesEqual(t[\path]) and: { shown } and: { covered.includes(id).not } and: { noWidget[id].isNil }
        };
        byTab = IdentityDictionary.new;
        missing.do { |id| var tab = ~midiTargets[id][\path].asSymbol; byTab.put(tab, (byTab[tab] ? []).add(id)) };
        byTab.keysValuesDo { |tab, list| ("  not tagged on " ++ tab ++ " (" ++ list.size ++ "): " ++ list.join(", ")).postln };
        ok.("every control on a tab is tagged there (" ++ covered.size ++ " controls tagged)", missing.isEmpty,
            missing.size.asString ++ " not tagged");
        ok.("the controls with no widget are not tagged either", noWidget.keys.every { |id| covered.includes(id).not });
    });

    // Ids alone can't tell a tag on the wrong view: each tag is checked on its
    // view. Its class must fit its control's kind, and a slider, knob, box or
    // menu is moved and the control its tag names must follow, with each
    // drum pattern shown and each Effects editor built. A switch or a trigger
    // is not pressed: the model may refuse it (the cutter with no meter), and
    // some start things (recording the set).
    section.("each tag is on a view of its kind, and the view drives the control it names", {
        var fits = { |view, kind|
            case
            // The stage window's own: a tile is a button, a segmented row a
            // menu, a bar a slider (classes/LooperTile.sc, LooperSeg.sc,
            // LooperBar.sc).
            { view.isKindOf(Button) or: { view.isKindOf(LooperTile) } } { [\toggle, \trigger].includes(kind) }
            { view.isKindOf(PopUpMenu) or: { view.isKindOf(LooperSeg) } } { kind == \choice }
            { view.isKindOf(NumberBox) } { [\step, \continuous].includes(kind) }
            { view.isKindOf(Slider) or: { view.isKindOf(Knob) } or: { view.isKindOf(LooperBar) } } {
                [\continuous, \step].includes(kind) }
            { false }
        };
        // Nil if moving the view moves its control as its law says, else why not.
        var drive = { |view, t|
            var after, want, pos, v;
            case
            { view.isKindOf(PopUpMenu) or: { view.isKindOf(LooperSeg) } } {
                v = if((t[\get].value ? 0) == 1) { 0 } { 1 };
                view.valueAction = v;
                after = t[\get].value;
                if(after == v) { nil } { "item " ++ v ++ " gave " ++ after }
            }
            { view.isKindOf(Slider) or: { view.isKindOf(Knob) } or: { view.isKindOf(LooperBar) } } {
                pos = if(((t[\get].value !? { |x| t[\toPos].value(x) } ? 0) - 0.3).abs < 0.1) { 0.7 } { 0.3 };
                view.valueAction = pos;
                after = t[\get].value;
                want = t[\fromPos].value(pos);
                if(after.notNil and: { (t[\toPos].value(after) - t[\toPos].value(want)).abs < 0.08 }) { nil }
                    { "position " ++ pos ++ " made it " ++ after ++ ", not " ++ want }
            }
            { view.isKindOf(NumberBox) } {
                v = t[\fromPos].value(0.35);
                if(t[\kind] == \step) { v = v.round.asInteger };
                view.valueAction = v;
                after = t[\get].value;
                if(after.notNil and: { (after - v).abs < 0.51 }) { nil } { v.asString ++ " made it " ++ after }
            }
            { nil }
        };
        var wrong = List.new, driven = 0, misfit = List.new, nameless = List.new, run, key0 = ~effectsSelected;
        run = {
            ~mapLiveTags.().do { |tg|
                var id = tg[1].value, t = id !? { |i| ~midiTargets[i] }, why;
                if(t.isNil) { nameless.add(id.asString ++ " on a " ++ tg[0].class) };
                if(t.notNil) {
                    if(fits.(tg[0], t[\kind]).not) { misfit.add(id.asString ++ " (" ++ t[\kind] ++ ") on a " ++ tg[0].class) };
                    if((t[\available].value != false) and: { t[\kind] != \toggle } and: { t[\kind] != \trigger }) {
                        why = try { drive.(tg[0], t) } { |err| "threw: " ++ err.errorString };
                        driven = driven + 1;
                        why !? { wrong.add(id.asString ++ ": " ++ why) };
                    };
                };
            };
        };
        [\main, \break].do { |pattern| ~drumsShowPattern.(pattern); run.() };
        ~drumsShowPattern.(\main);
        MegaSAFx.keys.do { |key| ~effectsSelect.(key); run.() };
        ~effectsSelect.(key0);
        misfit = misfit.asSet.asArray.sort;
        wrong = wrong.asSet.asArray.sort;
        ok.("every tag, with each pattern shown and each editor built, names a control the router has",
            nameless.isEmpty, nameless.asSet.asArray.sort.join("; "));
        ok.("every tagged view's class fits its control's kind", misfit.isEmpty, misfit.join("; "));
        ok.("every tagged slider, knob, box and menu drives the control it names (" ++ driven ++ " moved)",
            wrong.isEmpty and: { driven > 100 }, wrong.join("; "));
        // A control shown twice is tagged on both views.
        e = { |view| ~mapTags.detect { |tg| tg[0] === view } !? { |tg| tg[1].value } };
        ok.("each view of a control shown twice carries its tag", [
            [~bbcutButton, 'looper.bbcut'], [~bbcutPaneButton, 'looper.bbcut'],
            [~granularPerformButton, 'looper.granular'], [~granularOnButton, 'looper.granular'],
            [~granularSlider, 'looper.granularMorph'], [~feedbackSlider, 'looper.feedback'],
            [~saRigLevels[\drums][\slider], 'sa.level.drums'], [~drumsLevels[\drums][\slider], 'sa.level.drums'],
            [~saRigLevels[\drums][\mute], 'sa.mute.drums'], [~drumsLevels[\drums][\mute], 'sa.mute.drums'],
            [~saRigLevels[\onsetKit][\slider], 'sa.level.onsetKit'], [~drumsLevels[\onsetKit][\slider], 'sa.level.onsetKit']
        ].every { |pair| pair[0].notNil and: { e.(pair[0]) == pair[1] } });
    });

    section.("map mode lays a mask over every tagged view", {
        tags = ~mapLiveTags.();
        ~mapModeOn.();
        tick.();
        ok.("map mode is on", ~mapMode == true);
        ok.("one mask per tagged view", ~mapMasks.size == tags.size, ~mapMasks.size.asString ++ " of " ++ tags.size);
        ok.("each is its view's child", ~mapMasks.every { |x| x[\mask].parent === x[\view] });
        ok.("each says what drives its control, the TSMega's PC 4 on Trigger among them",
            ~mapMasks.any { |x| (x[\tag].value == 'looper.trigger') and: { x[\label].string == "PC 4" } },
            ~mapMasks.detect { |x| x[\tag].value == 'looper.trigger' } !? { |x| x[\label].string } ? "no Trigger mask");
        ok.("the header's hint row is the map bar", ~guiHintShows == \mapBar, ~guiHintShows.asString);
        mask = ~mapMasks.detect { |x| x[\tag].value == 'looper.feedback' };
        ok.("Feedback has a mask", mask.notNil);
        mask !? { |x|
            k = x[\mask].mouseDownAction.value(x[\mask], 5, 5, 0, 0, 1);
            tick.();
            ok.("a click on it arms Feedback, and the mask keeps the press (its action answers true)",
                ((~midiLearning !? { |l| l[\target] }) == 'looper.feedback') and: { k == true });
            ok.("...its mask turns amber", x[\tint] == \armed, x[\tint].asString);
        };
        ~mapEscape.();
        tick.();
        ok.("Esc disarms", ~midiLearning.isNil);
        hooked = ~mapMasks.collect { |x| x[\view] };
        e = ~mapMasks.collect { |x| x[\mask] };
        ~mapModeLeave.();
        tick.();
        ok.("leaving, with nothing changed, asks nothing", ~mapMode == false);
        ok.("...and leaves no mask", ~mapMasks.isEmpty and: { e.every(_.isClosed) }, e.reject(_.isClosed).size.asString);
        ok.("...and no resize hook", hooked.every { |v| v.onResize.isNil }, hooked.select { |v| v.onResize.notNil }.size.asString);
        ok.("the hint row is the keys again", ~guiHintShows == \text);
    });

    // A kit loaded: the controls are made again (~midiTargetsRefresh), so its
    // pads have trims, under its names; the old kit's stay, not there now.
    section.("a kit loaded brings its pads' trims", {
        var trims = { |kind| ~midiTargets.keys.select { |id| id.asString.beginsWith("sa.drums." ++ kind ++ ".steps.") } };
        var row = { var tv = ~midiGui[\list];
            (0 .. (tv.numItems - 1)).collect { |i| tv.itemAt(i).strings }.detect { |r| r[1].beginsWith("36 ") } };
        var before, gone, kit, ids, name;
        // A binding on a trim, to see the Rig tab's list follow the kit.
        ~midiMapEdit.(~midiMap.adding((msg: \cc, num: 61, target: 'sa.drums.trim.steps.36')));
        tick.();
        // carbon-layer to core-808: other pad names, and no layer.
        before = trims.(\groupTrim);
        d.setKit(\steps, 'core-808');
        0.5.wait;
        kit = d.kitFor(\steps);
        ok.("the steps kit is core-808 now", kit.notNil and: { kit.key == 'core-808' }, kit !? { |x| x.key.asString } ? "none");
        kit !? { |x|
            ids = x.notes.collect { |n| ("sa.drums.trim.steps." ++ n).asSymbol };
            ok.("every one of its pads has a trim, named as the kit names it", ids.every { |id|
                ~midiTargets[id].notNil and: { ~midiTargets[id][\label].contains(x.padName(id.asString.split($.).last.asInteger) ? "") } },
                ids.reject { |id| ~midiTargets[id].notNil }.asString);
            name = x.padName(36) ? "";
            ok.("...and the Rig tab's list says the new name on a binding to one", row.value !? { |r| r[1].contains(name) } ? false,
                (row.value ? []).asString ++ " / " ++ name);
        };
        ok.("the old kit's layer trim is kept, not there now", before.notEmpty
            and: { before.every { |id| ~midiTargets[id].notNil and: { ~midiTargets[id][\available].value == false } } },
            before.asString);
        // core-808 to carbon, which has no pad 50.
        before = trims.(\trim);
        d.setKit(\steps, 'carbon');
        0.5.wait;
        ids = (d.kitFor(\steps) !? { |x| x.notes } ? []).collect { |n| ("sa.drums.trim.steps." ++ n).asSymbol };
        gone = before.reject { |id| ids.includes(id) };
        ok.("a pad the new kit lacks keeps its trim, not there now", gone.notEmpty
            and: { gone.every { |id| ~midiTargets[id].notNil and: { ~midiTargets[id][\available].value == false } } },
            gone.asString);
        d.setKit(\steps, 'carbon-layer');
        0.5.wait;
        ~midiMapUndo.();
        tick.();
    });

    // The window's own keyDownAction and mouseDownAction, called as Qt calls
    // them (view, char, modifiers, unicode, keycode, key; view, x, y,
    // modifiers, button, clicks), not the functions behind them.
    section.("the window's own keys and clicks", {
        var view = ~guiWindow.view, orig = view.mouseDownAction, calls = 0, real;
        var count = { real = ~mapBackgroundClick; ~mapBackgroundClick = { calls = calls + 1; real.() } };
        view.keyDownAction.value(view, $m, 1048576, 109, 46, 77);
        tick.();
        ok.("Cmd+M, through the window's keyDownAction, turns map mode on", ~mapMode == true);
        mask = ~mapMasks.detect { |x| x[\tag].value == 'looper.feedback' };
        mask[\mask].mouseDownAction.value(mask[\mask], 5, 5, 0, 0, 1);
        tick.();
        ok.("...a click on Feedback's mask arms it", (~midiLearning !? { |l| l[\target] }) == 'looper.feedback');
        view.mouseDownAction.value(view, 300, 3, 0, 0, 1);
        tick.();
        ok.("a click on the window's background disarms", ~midiLearning.isNil and: { ~mapMode == true });
        view.keyDownAction.value(view, 27.asAscii, 0, 27, 53, ~mapKeyEscape);
        tick.();
        ok.("Esc, through the window's keyDownAction, leaves; the window's mouseDownAction is what it was",
            (~mapMode == false) and: { view.mouseDownAction === orig });
        ~mapModeOn.();
        ~mapModeOff.();
        ~mapModeOn.();
        count.();
        view.mouseDownAction.value(view, 300, 3, 0, 0, 1);
        ~mapBackgroundClick = real;
        ok.("on, off and on again: one click on the background is one call", calls == 1, calls.asString);
        // gui-mapmode.scd loaded again while map mode is on (the IDE): it
        // leaves first, and gives the window its action back.
        (scripts +/+ "gui-mapmode.scd").load;
        ok.("loaded again in map mode: map mode is left, and the window's mouseDownAction is what it was",
            (~mapMode == false) and: { view.mouseDownAction === orig });
        ~mapModeOn.();
        calls = 0;
        count.();
        view.mouseDownAction.value(view, 300, 3, 0, 0, 1);
        ~mapBackgroundClick = real;
        ok.("...and on again, a click is one call, not one that calls itself", calls == 1, calls.asString);
        ~mapModeOff.();
        ok.("off: no wrapper left", view.mouseDownAction === orig);
    });

    // A segmented switch shows the option clicked. The model's repaint comes
    // at once from a click (a defer on the GUI's own thread runs there and
    // then), and the switch once put its old value back after it, so every
    // switch showed the option before the click.
    section.("the switches show what was clicked", {
        var click = { |seg, index|
            var v = seg[\view], w = v.bounds.width / seg[\labels].size;
            v.mouseDown((index + 0.5) * w, 10, 0, 0, 1);
            v.mouseUp((index + 0.5) * w, 10, 0, 0);
        };
        var tabSub = { |i| ~bbcutVoiceTabsHolder.children.select { |c| c.isKindOf(LooperTile) }[i] !? { |t| t.sub } ? "" };
        var procTile, procName, was = [~looper.inChannelCount, ~looper.bbcutMode];
        // (The New loop switch keeps its choice in settings.json: caught here, never written.)
        var wasPrefSave = ~guiPrefSave, kept;
        ~wireLooperController.();
        click.(~inChannelSeg, 1);
        tick.();
        ok.("Input: Stereo clicked, the looper records two channels and the switch says Stereo",
            [~looper.inChannelCount, ~inChannelSeg[\view].value] == [2, 1], [~looper.inChannelCount, ~inChannelSeg[\view].value].asString);
        click.(~inChannelSeg, 0);
        tick.();
        ok.("...Mono clicked, one channel, and the switch says Mono",
            [~looper.inChannelCount, ~inChannelSeg[\view].value] == [1, 0], [~looper.inChannelCount, ~inChannelSeg[\view].value].asString);
        ~guiPrefSave = { |key, value| kept = [key, value] };
        ok.("New loop: the switch is on the Setup view, at Drums play", ~saNewLoopSeg.notNil and: { ~saNewLoopSeg[\view].value == 0 });
        click.(~saNewLoopSeg, 1);
        tick.();
        ok.("...Drums off clicked, a new loop starts with the drums off, and that is kept",
            (~megaSA.drums.newLoopOff == true) and: { kept == ["drumsNewLoop", "off"] }, [~megaSA.drums.newLoopOff, kept].asString);
        click.(~saNewLoopSeg, 0);
        tick.();
        ok.("...Drums play clicked, they play again", (~megaSA.drums.newLoopOff == false) and: { kept == ["drumsNewLoop", "play"] },
            [~megaSA.drums.newLoopOff, kept].asString);
        ~guiPrefSave = wasPrefSave;
        click.(~bbcutModeSegSound, 0);
        tick.();
        ok.("the cutter's mode: Mix clicked, the looper mixes and the switch says Mix",
            [~looper.bbcutMode, ~bbcutModeSegSound[\view].value] == [\mix, 0], [~looper.bbcutMode, ~bbcutModeSegSound[\view].value].asString);
        click.(~bbcutModeSegSound, 2);
        tick.();
        ok.("...Gate clicked, Gate", [~looper.bbcutMode, ~bbcutModeSegSound[\view].value] == [\gate, 2]);
        ~looper.inChannelCount = was[0];
        ~looper.bbcutMode = was[1];
        // The transport's row says what the Looper's transport drives here.
        ok.("the transport row is Live's on a Live rig, the drums' on SA, and none on standalone",
            [~rigTransportWords.(~routingProfiles[\bhTsMega])[\label], ~rigTransportWords.(~routingProfiles[\saSystem])[\label],
                ~rigTransportWords.(~routingProfiles[\standalone])] == ["Live transport", "Drums follow the loop", nil]);
        ok.("...and this window, on SA, shows the drums' row", ~transportModeSeg.notNil and: { ~transportModeSeg[\labels].last == "Off" });
        // A voice's tab names its procedure as soon as it changes.
        ~bbcutSelVoice = 0;
        ~renderBBCutVoiceMenu.();
        ~renderBBCutEditor.();
        tick.();
        procName = ~looper.bbcutProcSpecs.keys.asArray.sort.collect { |k| ~looper.bbcutProcSpecs[k][\name] }
            .detect { |nm| tabSub.(0).contains(nm).not };
        procTile = { var found; var walk = { |v| v.children.do { |c|
            if(c.isKindOf(LooperTile) and: { c.states.notNil } and: { c.states.first.first == procName }) { found = c }; walk.(c) } };
            walk.(~bbcutEditorHolder); found }.value;
        procTile !? { |t| t.action.value(t) };
        tick.();
        ok.("a procedure picked shows on its voice's tab at once, no other voice clicked",
            procTile.notNil and: { tabSub.(0).contains(procName) }, [procName, tabSub.(0)].asString);
    });

    // The server's load, in the top bar on every view.
    section.("the CPU tile", {
        var srv = ~looper.server, look = { [~guiCpuTile.states[0][0], ~guiCpuTile.sub, ~guiCpuTile.states[0][1]] };
        var near = { |a, b| a.notNil and: { [a.red - b.red, a.green - b.green, a.blue - b.blue].every { |x| x.abs < 0.01 } } };
        ok.("the top bar has it, between the tabs and the theme", ~guiCpuTile.notNil and: { ~guiCpuTile.isClosed.not });
        srv[\avgCPU] = 12.4;
        srv[\peakCPU] = 30.2;
        ~guiCpuPaint.();
        ok.("it says the average, the peak under it", look.value.keep(2) == ["CPU 12%", "peak 30%"], look.value.asString);
        ok.("...in ink while the peak is under the mark", near.(look.value[2], ~gt[\ink]));
        srv[\peakCPU] = 75;
        ~guiCpuPaint.();
        ok.("...and red past " ++ ~guiCpuWarn ++ " %", near.(look.value[2], ~gt[\rec]) and: { look.value[1] == "peak 75%" });
        srv[\avgCPU] = 100;
        srv[\peakCPU] = 100;
        ~guiCpuPaint.();
        ok.("...and 100% fits in it", ("CPU 100%".bounds(~guiMono.(13, true)).width + 8) <= ~guiCpuTile.bounds.width,
            [~guiCpuTile.bounds.width, "CPU 100%".bounds(~guiMono.(13, true)).width].asString);
        // SA's six tabs take the wordmark's name at 1440 (gui-shell.scd): the
        // rest stays.
        ok.("at the 1440 it is laid out for the top bar holds everything but the wordmark's name",
            ((~guiTopBarFull ? 99999) - 124) <= 1440, ~guiTopBarFull.asString);
        srv[\avgCPU] = nil;
        srv[\peakCPU] = nil;
        ~guiCpuPaint.();
        ok.("with no server answering it says so", look.value.keep(2) == ["CPU –", "no server"], look.value.asString);
        ok.("the effects' status line has no CPU of its own now", (~effectsStatus.()[0] ? "").contains("CPU").not);
    });

    // What the UI review of 2026-10-14 found (docs/dev/device-chains.md 13.23).
    section.("the review's six faults", {
        var walk, all = List.new, menus, widest, tile, fake, rect, was;
        walk = { |v| all.add(v); v.children.do { |c| walk.(c) } };
        ~guiSideRows.do { |row, i|
            ok.("a view of columns needs no more than the 1440 pt the window is laid out for (row " ++ i ++ ")",
                (row[0].getProperty(\minimumWidth) ? 99999) <= 1440, row[0].getProperty(\minimumWidth).asString);
        };
        // The Cutter column is 197 pt inside at 1440 (measured on a screenshot).
        ok.("Perform's Cutter column: the intensity's name and its two numbers fit side by side",
            ~performArcLabel.string.contains("arc").not and: {
                (~performArcLabel.string.bounds(~guiSans.(14)).width + 8
                    + ~performArcValue.string.bounds(~guiMono.(14, true)).width) <= 197 },
            [~performArcLabel.string, ~performArcValue.string].asString);
        ok.("...and the arc is said in their tooltip", ~performArcValue.toolTip.asString.contains("full arc"));
        ok.("a tile's name in map mode is its name without its binding",
            (~mapTileName.("○ Record set · PC 20") == "○ Record set") and: { ~mapTileName.("Trigger") == "Trigger" });
        tile = LooperTile().fixedSize_(Size(200, 52));
        fake = View().fixedSize_(Size(200, 52));
        rect = ~mapLabelRect.(tile, (bounds: Rect(0, 0, 200, 52)));
        ok.("...and its binding goes under the name, not over it", rect.top >= 26 and: { rect.height >= 20 }, rect.asString);
        rect = ~mapLabelRect.(fake, (bounds: Rect(0, 0, 200, 52)));
        ok.("...while a control that is not a tile has its binding in the middle", rect == Rect(0, 0, 200, 52), rect.asString);
        tile.remove; fake.remove;
        was = [~midiLearning, ~mapKeeping, ~mapLeaving];
        ~midiLearning = nil; ~mapKeeping = false; ~mapLeaving = false;
        ok.("map mode's bar says Esc once: the line under it doesn't", ~mapBarSub.().contains("Esc").not, ~mapBarSub.());
        ~midiLearning = was[0]; ~mapKeeping = was[1]; ~mapLeaving = was[2];
        walk.(~guiPaneHolders[\drums]);
        menus = all.select { |v| v.isKindOf(PopUpMenu) and: { (v.items ? []).any { |i| i.contains("Carbon") } } };
        widest = menus.collect { |m| m.items.collect { |i| i.bounds(~guiSans.(13)).width }.maxItem + 30 - m.bounds.width }.maxItem;
        ok.("the Drums lanes' note menus show their notes whole", menus.size >= 8 and: { widest <= 0 },
            [menus.size, widest].asString);
        ok.("the Drums preset bar's resting line reads as words", ~presetFamilies[\saDrums][\statusIdle].contains("— none —").not);
        ok.("the footer names the keys the tabs have, and the wizard's",
            ~guiKeysHint.() == "keys 1–5 7 views · 6 calibrate · T theme · H help", ~guiKeysHint.());
        was = ~guiViewOrder;
        ~guiViewOrder = ~guiViewOrderFor.(false);
        ok.("...without SA too", ~guiKeysHint.() == "keys 1 2 5 views · 6 calibrate · T theme · H help", ~guiKeysHint.());
        ~guiViewOrder = was;
    });

    section.("the review's design changes", {
        var key = MegaSAFx.guitarKeys.first, tile = ~effectsTiles[key][\select], m = ~megaSA, was, shown, field;
        ok.("Perform has the mixer's strips too, in a table of their own",
            [\guitar, \loop, \master].every { |k| ~saPerformLevels[k].notNil }
                and: { ~saPerformLevels[\guitar][\slider] !== ~saRigLevels[\guitar][\slider] },
            ~saPerformLevels.keys.asArray.asString);
        m.setLevel(\loop, -12.dbamp);
        tick.();
        ok.("...and a level set anywhere shows on both", (~saPerformLevels[\loop][\readout].string == "-12.0 dB")
            and: { ~saRigLevels[\loop][\readout].string == "-12.0 dB" },
            [~saPerformLevels[\loop][\readout].string, ~saRigLevels[\loop][\readout].string].asString);
        m.setLevel(\loop, 1);
        ok.("Perform's Effects column counts the drums' chain as well", ~performFxDrumsLabel.string.contains(" of "),
            ~performFxDrumsLabel.string);
        was = m.fx(key);
        ~effectsPress = (tile: tile, x: 30, y: 30);
        tile.action.value(tile, 0);
        ok.("a click on an effect's block away from its square shows it and never switches it",
            (~effectsSelected == key) and: { m.fx(key) == was }, [~effectsSelected, m.fx(key)].asString);
        tile.action.value(tile, 0);
        ok.("...not even a second one on the block shown", m.fx(key) == was);
        ~effectsSwitchedAt = nil;
        ~effectsPress = (tile: tile, x: tile.bounds.width - 12, y: 10);
        tile.action.value(tile, 0);
        ok.("its square switches it", m.fx(key) == was.not, [was, m.fx(key)].asString);
        tile.action.value(tile, 0);
        ok.("...and a second press within 0.4 s is let go (a double-click is one switch)", m.fx(key) == was.not);
        ~effectsSwitchedAt = nil;
        tile.action.value(tile, 0);
        ok.("...a later one switches it back", m.fx(key) == was);
        ok.("the square says on or off", tile.sw == (if(m.fx(key)) { "■" } { "□" }), tile.sw.asString);
        ~effectsPress = nil;
        field = ~presetFamilies[\saDrums][\nameField];
        ok.("a preset bar's empty name field says what goes in it",
            field.getProperty(\placeholderText) == "Name a new preset, then Save new", field.getProperty(\placeholderText).asString);
        ok.("...a sound, on the effects' bar", ~presetFamilies[\saFx][\nameField].getProperty(\placeholderText)
            == "Name a new sound, then Save new");
        ok.("MIDI MAP, off, has the bar's own outline, not the blue one", ~mapButton.border == ~gt[\line]);
        ok.("...with the help switch in it too", ((~guiTopBarFull ? 99999) - 124) <= 1440, ~guiTopBarFull.asString);
        // A window never shown answers false to every view's visible: a
        // stand-in among the help lines says what each of them was told.
        shown = (isClosed: false, said: nil, visible_: { |self, flag| self[\said] = flag; self });
        ok.("the help lines are many", ~guiHelpViews.size >= 8, ~guiHelpViews.size.asString);
        ~guiHelp.(shown);
        ok.("...a new one, with them shown, is left shown", shown[\said].isNil);
        ~guiHelpToggle.();
        tick.();
        ok.("H hides them all", (shown[\said] == false) and: { ~guiHelpTile.sub == "off" }
            and: { ~guiHelpViews.every { |v| v === shown or: { v.visible == false } } });
        ok.("...and keeps that for the next start", ~guiPrefSaved.("help") == "hidden", ~guiPrefSaved.("help").asString);
        ~guiHelpToggle.();
        tick.();
        ok.("...and shows them again", (shown[\said] == true) and: { ~guiHelpTile.sub.isNil });
        ~guiHelpViews.remove(shown);
        ok.("the Drums lanes say Length, Delay and Mute, not L, D and M", {
            var walk, all = List.new;
            walk = { |v| all.add(v); v.children.do { |c| walk.(c) } };
            walk.(~guiPaneHolders[\drums]);
            all.any { |v| v.isKindOf(StaticText) and: { v.string == "Length" } }
                and: { all.any { |v| v.isKindOf(StaticText) and: { v.string == "Delay" } } }
                and: { all.any { |v| v.isKindOf(StaticText) and: { v.string == "L" } }.not }
        }.value);
    });

    section.("the logo", {
        var g = ~guiLogoGeometry.(), wasL = ~looper, wasP = ~guiLoopPhase, near = { |a, b| (a - b).abs < 1e-3 };
        ok.("the top bar's first tile holds the Möbius loop", ~guiLogo.notNil and: { ~guiLogo.isClosed.not }
            and: { ~guiLogo.bounds.width == 56 });
        ok.("a narrow window takes the name away, never the loop",
            (~guiTopBarShed.first[0] !== ~guiLogo) and: { ~guiTopBarShed.first[0].string == "MEGALOOPER" });
        ok.("its lemniscate: 200 pieces, closed, from (1, 0)", (g[\order].size == 200) and: { g[\p].size == 201 }
            and: { near.(g[\p][0][0], 1) and: { near.(g[\p][0][1], 0) } } and: { near.(g[\p][200][0], 1) });
        ok.("...its normals one long", g[\n].every { |v| near.(v.squared.sum, 1) });
        ok.("...drawn far first: the lobe crossing under comes before the one over",
            sin(g[\t][g[\order].first]) < -0.99 and: { sin(g[\t][g[\order].last]) > 0.99 });
        ~looper = (loopDuration: 4);
        ~guiLogoPhase = 0;
        ~guiLoopPhase = 1;
        ~guiLogoTurn.();
        ok.("a quarter into the loop, the twist is a quarter round", near.(~guiLogoPhase, 0.5pi), ~guiLogoPhase.asString);
        ~guiLoopPhase = 3;
        ~guiLogoTurn.();
        ok.("...three quarters, three quarters", near.(~guiLogoPhase, 1.5pi), ~guiLogoPhase.asString);
        ~guiLoopPhase = nil;
        ~guiLogoTurn.();
        ok.("stopped, it stands", near.(~guiLogoPhase, 1.5pi), ~guiLogoPhase.asString);
        ~looper = (loopDuration: 0);
        ~guiLogoTurn.();
        ok.("with no loop it rests", ~guiLogoPhase == 0, ~guiLogoPhase.asString);
        ~looper = wasL;
        ~guiLoopPhase = wasP;
    });

    ~guiWindow.close;
    tick.();
    ~tRemoveTree.(tmp);
    "".postln;
    if(fail == 0) { ("MAP TAGS CHECK PASSED — " ++ pass ++ " checks").postln }
    { ("MAP TAGS CHECK FAILED — " ++ fail ++ " of " ++ (pass + fail)).postln;
      fails.do { |f| ("  " ++ f).postln } };
    if(fail == 0) { 0.exit } { 1.exit };
}.play(AppClock);
)
