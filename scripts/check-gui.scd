// megalooper — does the window actually build, and does it stay honest?
//
// The headless suite (scripts/tests/) cannot answer this: it runs without a
// server and without Qt, so everything it checks about the GUI is language-side
// logic. check.scd cannot answer it either — it LOADS every gui file precisely
// to prove none of them opens a window. So this one boots a rig for real, builds
// the real window, asserts on the live Qt objects, tears it down and exits
// 0 or 1. Run it after touching anything under scripts/gui-*.scd.
//
//   /Applications/SuperCollider.app/Contents/MacOS/sclang scripts/check-gui.scd
//
// It briefly opens a window; that is the point. It picks the rig the same way
// boot.scd does, so set ~checkGuiProfile first to test a specific one:
//
//   ~checkGuiProfile = \bhBuiltin;   // then load this file
//
// Two more settings, for a run beside a megalooper that is playing: a server of
// its own (~checkGuiServer, a Server on another port; the default one is the
// megalooper's, and this quits its server at the end), and ~checkGuiQuiet,
// which shows the window fully transparent so it takes nothing from the
// screen. Your settings.json is never written: the theme switch it checks is
// kept in a scratch folder.
//
// NOTE the assertions below deliberately drive things the model REFUSES with no
// loop recorded (the cutter), because "a refused action leaves the display
// telling the truth" is the contract the whole status header rests on, and it is
// only testable when the refusal actually happens.
~root = Looper.repoRoot;
~megalooperRoot = ~root;
~megalooperScripts = ~root +/+ "scripts";
~trainingDataDir   = ~root +/+ "training-data";
~bbcutPresetDir    = ~root +/+ "presets" +/+ "bbcut";
~granularPresetDir = ~root +/+ "presets" +/+ "granular";
~saFxPresetDir     = ~root +/+ "presets" +/+ "sa" +/+ "fx";
~saDrumsPresetDir  = ~root +/+ "presets" +/+ "sa" +/+ "drum-presets";

~pass = 0; ~fail = 0; ~fails = List.new;
~ok = { |label, cond, detail|
    if(cond == true) { ~pass = ~pass + 1; ("  ok    " ++ label).postln }
    { ~fail = ~fail + 1; ~fails.add(label ++ " — " ++ (detail ? ""));
      ("  FAIL  " ++ label ++ " — " ++ (detail ? "")).postln };
};

[
    "setup-routing.scd", "setup-midi.scd", "setup-model.scd", "setup-sa.scd", "setup-miditargets.scd", "setup-midimap.scd",
    "gui-const.scd", "gui-theme.scd", "gui-presets.scd", "gui-status.scd", "gui-perform.scd",
    "gui-bbcut.scd", "gui-granular.scd", "gui-analysis.scd", "gui-sa.scd", "gui-midimap.scd", "gui-mapmode.scd",
    "gui-effects.scd", "gui-drums.scd", "gui-rig.scd", "gui-calibrate.scd",
    "gui-shell.scd", "gui-wiring.scd"
].do { |f| (~megalooperScripts +/+ f).load };
// It sends nothing back to a controller, whatever settings.json says
// (docs/dev/midi-map.md 5.7): what it does to the controls is no player's.
~midiBackOpen = { \dead };

~checkGuiServer !? { |srv| Server.default = srv; s = srv };
~midiUserRootOverride = PathName.tmp +/+ "megalooper-checkgui-" ++ thisProcess.pid ++ "-" ++ Date.getDate.stamp;
File.mkdir(~midiUserRootOverride);

// Same rule as boot.scd: an explicit choice wins, otherwise the table's default.
~routingProfile = ~checkGuiProfile ? ~defaultRoutingProfile;
~applyRoutingProfile.(~routingProfile);
s.boot;
s.waitForBoot {
    ~setupMidiIO.();
    // As boot.scd: SA's mixer before the Looper, its loop effects after.
    if(~rp[\sa] == true) { ~setupSA.() } { ~megaSA !? { |m| m.free }; ~megaSA = nil };
    ~setupLooper.();
    ~wireLooperCallbacks.();
    ~looper.waitForReady;
    if(~rp[\sa] == true) { ~setupSALooper.() };
    ~setupMidiBindings.();

    if(~checkGuiQuiet == true) {
        ~buildGuiWindow.(false);
        ~guiWindow.alpha_(0).visible_(true);
    } {
        ~buildGuiWindow.();
    };
    ~wireLooperController.();
    0.5.wait;

    "== structure ==".postln;
    ~ok.("window exists and is open", ~guiWindow.notNil and: { ~guiWindow.isClosed.not });
    // Counted off the orders rather than written out, so adding a view or a
    // pane cannot leave these asserting yesterday's number.
    ~ok.("stack has one child per view", ~guiStack.count == ~guiViewOrder.size,
        "count " ++ ~guiStack.count ++ " of " ++ ~guiViewOrder.size);
    // SC 3.14.1's Qt getters of enum properties fail (_QObject_GetProperty),
    // StackLayout.mode among them, so where it cannot answer, the mode is
    // checked by what it does: \stackOne shows the current view alone,
    // \stackAll every one.
    ~ok.("stack is in stackOne mode (hidden views cannot steal focus)",
        try { ~guiStack.mode == 0 } {
            ~guiViews.every { |v, i| v.visible == (i == ~guiStack.index) }
        },
        "visible: " ++ ~guiViews.collect { |v| v.visible }.asString);
    ~ok.("the window is a laptop screen's, no wider", ~guiWindow.bounds.width <= 1440,
        ~guiWindow.bounds.width.asString);
    ~guiPaneOrder.do { |k|
        ~ok.("holder " ++ k ++ " holds exactly one pane",
            ~guiPaneHolders[k].children.size == 1,
            "children " ++ ~guiPaneHolders[k].children.size);
    };
    ~ok.("one tab per view but the wizard",
        ~guiTabButtons.size == (~guiViewOrder.size - 1),
        ~guiTabButtons.size.asString ++ " of " ++ (~guiViewOrder.size - 1));

    "== every view and pane selectable ==".postln;
    ~tmpWin = ~guiWindow.bounds.height;
    ~guiViewOrder.do { |v, i|
        ~guiSelectView.(v);
        ~ok.("show " ++ v ++ " -> index " ++ i, ~guiStack.index == i, "index " ++ ~guiStack.index);
    };
    ~guiPaneOrder.do { |k|
        ~guiSelectTab.(k);
        ~ok.("a pane shows its view: " ++ k, ~guiStack.index == ~guiTabIndex.(k), "index " ++ ~guiStack.index);
    };
    // The band is Perform's; every other view has the strip.
    ~guiSelectView.(\perform);
    0.1.wait;
    // Views switched back to back: Qt can count one view's minimum against
    // the band of the one before, and a window that grows never shrinks.
    ~ok.("switching views fast leaves the window its height", ~guiWindow.bounds.height <= ~tmpWin,
        ~guiWindow.bounds.height.asString + "vs" + ~tmpWin.asString);
    ~ok.("Perform shows the status band, not the strip", ~statusBand.visible and: { ~statusStrip.visible.not });
    ~guiSelectView.(\sound);
    0.1.wait;
    ~ok.("another view shows the strip, not the band", ~statusStrip.visible and: { ~statusBand.visible.not });
    // Keys 1-6, and Esc from the wizard.
    ~guiKeyDown.($1, 0, 49);
    ~ok.("key 1 shows Perform", ~guiView == \perform);
    ~guiKeyDown.($5, 0, 53);
    ~ok.("key 5 shows Setup", ~guiView == \setup);
    ~guiKeyDown.($6, 0, 54);
    ~ok.("key 6 shows the wizard", ~guiView == \calibrate);
    ~ok.("whose tab is Setup's", ~guiTabButtons[\calibrate].isNil);
    ~guiKeyDown.(nil, 0, ~guiKeyEscape);
    ~ok.("Esc goes back to Setup", ~guiView == \setup);
    ~guiKeyDown.($3, 0, 51);
    ~ok.("key 3 is FX only where SA has it", if(~guiViewOrder.includes(\fx)) { ~guiView == \fx } {
        (~guiView == \setup) and: { (~guiToast !? { |t| t[\msg] } ? "").contains("FX") } },
        ~guiView.asString);
    ~guiKeyDown.($5, 0, 53);
    ~guiKeyDown.($4, 0, 52);
    ~ok.("key 4 is Drums only where SA has it", if(~guiViewOrder.includes(\drums)) { ~guiView == \drums } {
        (~guiView == \setup) and: { (~guiToast !? { |t| t[\msg] } ? "").contains("Drums") } },
        ~guiView.asString);
    // On as before for what follows: the effects' view where there is one.
    if(~guiViewOrder.includes(\fx)) { ~guiSelectView.(\fx) };
    ~guiToast = nil;

    "== widgets from every pane are alive ==".postln;
    ([[\statusStateLabel, ~statusStateLabel], [\statusStateStrip, ~statusStateStrip],
     [\guiPositionView, ~guiPositionView], [\guiPositionStrip, ~guiPositionStrip],
     [\guiLevelView, ~guiLevelView], [\guiLevelStrip, ~guiLevelStrip],
     [\feedbackSlider, ~feedbackSlider], [\masterAmpSlider, ~masterAmpSlider],
     [\granularSlider, ~granularSlider], [\keyHintText, ~keyHintText], [\guiFooterStatus, ~guiFooterStatus],
     [\nextLoopButton, ~nextLoopButton], [\bbcutButton, ~bbcutButton],
     [\bbcutPaneButton, ~bbcutPaneButton], [\bbcutVoiceMenu, ~bbcutVoiceMenu],
     [\onsetThresholdSlider, ~onsetThresholdSlider],
     [\guiOnsetLampView, ~guiOnsetLampView], [\exportNameField, ~exportNameField],
     [\latencySlider, ~latencySlider], [\syncSlider, ~syncSlider],
     [\declickSlider, ~declickSlider], [\midiMonitorView, ~midiMonitorView],
     [\analysisSourceMenu, ~analysisSourceMenu],
     [\breakButton, ~breakButton], [\breakLoopsField, ~breakLoopsField],
     [\intensitySlider, ~intensitySlider], [\dissolveButton, ~dissolveButton],
     [\sessionRecButton, ~sessionRecButton], [\guiSessionRecLabel, ~guiSessionRecLabel],
     [\dissolveBarsField, ~dissolveBarsField], [\mapButton, ~mapButton], [\guiTakeLabel, ~guiTakeLabel]
    // The transport's row: Live's, or the drums' on SA; standalone has none.
    ] ++ if(~rigTransportWords.(~rp).notNil) { [[\transportModeMenu, ~transportModeMenu]] } { [] }).do { |pair|
        ~ok.(pair[0].asString ++ " alive",
            pair[1].notNil and: { pair[1].isClosed.not });
    };
    ~ok.("bbcut editor rendered", ~bbcutEditorHolder.children.size == 1);
    ~ok.("granular widget table populated", ~granularWidgets.size > 0,
        ~granularWidgets.size.asString);

    "== model -> view with the pane HIDDEN ==".postln;
    // Perform shows: the Analysis pane (on Setup) is hidden.
    ~guiSelectView.(\perform);
    0.2.wait;
    // The cutter and the granular layer both REFUSE to start without a recorded
    // loop (and rightly so), which makes them useless for testing the view
    // path. The analysis monitor is deliberately independent of transport, so
    // it is the one part that can be toggled on an empty looper.
    ~looper.stopAnalysisMonitor; 0.3.wait;
    ~ok.("hidden Analysis pane's monitor switch followed the model off",
        ~analysisMonitorButton.value == 0, ~analysisMonitorButton.value.asString);
    ~looper.startAnalysisMonitor; 0.3.wait;
    ~ok.("hidden Analysis pane's monitor switch followed the model on",
        ~analysisMonitorButton.value == 1, ~analysisMonitorButton.value.asString);

    // Setup shows from here on: Perform and Sound are hidden.
    ~guiSelectView.(\setup);
    0.2.wait;
    // And the refusal itself must be visible: asking for the cutter with no
    // loop must leave every switch saying off, not optimistically lit, and
    // the footer saying why.
    ~guiToast = nil;
    ~looper.bbcut = true; 0.3.wait;
    ~ok.("a REFUSED bbcut leaves Perform's switch honest", ~bbcutButton.value == 0, ~bbcutButton.value.asString);
    ~ok.("...and the Cutter's own", ~bbcutPaneButton.value == 0, ~bbcutPaneButton.value.asString);
    ~ok.("a REFUSED bbcut leaves the Sound tab undotted", ~guiTabActive.(\sound)[0] == false);
    ~ok.("the footer says it was refused, and why", ~guiFooterShown.beginsWith("Refused: "), ~guiFooterShown);
    ~guiToast = nil;

    "== breaks ==".postln;
    // Same contract: a break with nothing playing must leave the state block
    // un-hatched, because a hatched block and genuinely broken audio look
    // identical.
    ~looper.fireBreak; 0.3.wait;
    ~ok.("a REFUSED break leaves the state block honest", ~statusShown[\hatch] != true,
        ~statusShown[\label].asString);
    ~ok.("a REFUSED break leaves its tile unlit", ~breakButton.hatch.not);
    ~ok.("the looper is not stuck on a break", ~looper.onBreak.not);
    ~ok.("and the footer says why", ~guiFooterShown.beginsWith("Refused"), ~guiFooterShown);
    // The Perform pane is hidden here (Setup is showing), so this also
    // checks the model reaches a pane that is not on screen.
    ~looper.breakLoops = 2; 0.3.wait;
    ~ok.("hidden Perform pane's break-loops field followed the model",
        ~breakLoopsField.value == 2, ~breakLoopsField.value.asString);
    ~ok.("and the Break tile's line", ~breakButton.sub.beginsWith("2 loops"), ~breakButton.sub);
    ~ok.("breakLoops clips rather than trusting the input",
        { ~looper.breakLoops = 99; ~looper.breakLoops }.value == 8,
        ~looper.breakLoops.asString);

    "== the arc ==".postln;
    // The default has to be invisible: a rig with no pedal connected must sound
    // exactly as it did before the macro existed.
    ~ok.("intensity defaults to full, so no pedal means no change",
        ~looper.intensity == 1, ~looper.intensity.asString);
    ~ok.("the Arc macro agrees with the model",
        ~intensitySlider.value == 1, ~intensitySlider.value.asString);
    // Arrives on CC 11 from the pedal; the bar must follow it, and it does
    // NOT touch the stored granular level.
    ~looper.intensity = 0.4; 0.3.wait;
    ~ok.("the pedal moves the Arc macro",
        (~intensitySlider.value - 0.4).abs < 0.01, ~intensitySlider.value.asString);
    ~ok.("the pedal leaves the stored granular level alone",
        ~looper.granularAmp == 0.7, ~looper.granularAmp.asString);
    ~ok.("heel takes the grains to nothing and leaves the cutter's level alone",
        { ~looper.intensity = 0; (~looper.prGranularMix == 0) and: { ~looper.prBBCutMix == 1 } }.value);
    ~ok.("heel leaves the dry loop at full",  ~looper.prLoopMix == 1);
    ~looper.intensity = 1; 0.2.wait;
    // Same honesty contract as the cutter and the break.
    ~looper.startDissolve; 0.3.wait;
    ~ok.("a REFUSED dissolve leaves its tile unlit", ~dissolveButton.sub.contains("%").not,
        ~dissolveButton.sub);
    ~ok.("and the looper is not stuck dissolving", ~looper.dissolving.not);
    ~ok.("and the arc is back at 0", ~looper.dissolvePos == 0);
    ~looper.dissolveBars = 16; 0.3.wait;
    ~ok.("dissolve-bars field followed the model",
        ~dissolveBarsField.value == 16, ~dissolveBarsField.value.asString);

    "== intensity drives cutter density ==".postln;
    // The Cutter pane is hidden (Setup is showing), which is the point: the
    // reading beside the density bar has to track the pedal even when nobody
    // is looking at it, or it will be wrong the moment you switch back.
    ~looper.setVoiceProc(0, \break);
    ~looper.setVoiceParam(0, \cutchance, 0.8);
    ~looper.intensity = 1; 0.3.wait;
    ~ok.("at full arc the cutter gets what was dialled in",
        (~looper.voiceDensity(0) - 0.8).abs < 1e-9, ~looper.voiceDensity(0).asString);
    ~ok.("the hidden Cutter pane's readout agrees",
        ~bbcutDensityLabel.notNil and: { ~bbcutDensityLabel.string.contains("arc 0.8") },
        (~bbcutDensityLabel !? { |t| t.string }).asString);
    ~looper.intensity = 0.25; 0.3.wait;
    ~ok.("quarter arc scales the density down",
        (~looper.voiceDensity(0) - 0.2).abs < 1e-9, ~looper.voiceDensity(0).asString);
    ~ok.("the readout followed the pedal while hidden",
        ~bbcutDensityLabel.string.contains("arc 0.2"), ~bbcutDensityLabel.string);
    ~ok.("and its tick with it, while the bar stays at the stored value",
        ((~bbcutDensityBar.tick - 0.2).abs < 1e-6) and: { (~bbcutDensityBar.value - 0.8).abs < 1e-6 },
        [~bbcutDensityBar.tick, ~bbcutDensityBar.value].asString);
    ~ok.("and the STORED value is untouched, so the bar is not lying",
        (~looper.bbcutVoices[0][\params][\cutchance] - 0.8).abs < 1e-9,
        ~looper.bbcutVoices[0][\params][\cutchance].asString);
    ~ok.("Perform's Cutter column shows both", ~performArcValue.string == "0.2 / 0.8",
        ~performArcValue.string);
    // warp has no parameter the arc can drive without a rebuild.
    ~looper.setVoiceProc(0, \warp); 0.3.wait;
    ~ok.("a procedure with no arc-driven parameter reports none",
        ~looper.voiceDensity(0).isNil, ~looper.voiceDensity(0).asString);
    ~looper.setVoiceProc(0, \break);
    ~looper.intensity = 1; 0.3.wait;

    "== per-pane rebuild in place ==".postln;
    ~buildBBCutPane.();
    ~buildAnalysisPane.();
    0.3.wait;
    ~ok.("stack still has one child per view after two pane rebuilds",
        ~guiStack.count == ~guiViewOrder.size,
        "count " ++ ~guiStack.count ++ " of " ++ ~guiViewOrder.size);
    ~ok.("cutter holder still holds exactly one pane",
        ~guiPaneHolders[\cutter].children.size == 1,
        ~guiPaneHolders[\cutter].children.size.asString);
    ~ok.("analysis holder still holds exactly one pane",
        ~guiPaneHolders[\analysis].children.size == 1);
    ~ok.("window survived the rebuilds", ~guiWindow.isClosed.not);
    ~ok.("analysis generation advanced", ~analysisGen > 1, ~analysisGen.asString);

    "== position readout with no loop ==".postln;
    0.3.wait;
    ~ok.("no loop reports no phase", ~guiLoopPhase.isNil, ~guiLoopPhase.asString);
    ~ok.("empty looper reports no loop, not a stopped one",
        ~looper.loopDuration == 0, ~looper.loopDuration.asString);
    ~ok.("loopPositionAt tolerates a nil phase on an empty looper",
        Looper.loopPositionAt(nil, ~looper.lastResult, ~looper.loopDuration)[\bar].isNil);
    ~ok.("the strip says no take", ~guiTakeLabel.string == "no take", ~guiTakeLabel.string);
    ~ok.("the band's take says none yet", ~guiTakeHead.string == "TAKE · NONE YET", ~guiTakeHead.string);
    ~ok.("the position says no loop", ~statusPositionWords.()[0] == "NO LOOP");

    "== a timed break really ends (live server, real routine) ==".postln;
    // The headless suite drives endBreak through a routine synchronously; this
    // is the same path with a real Synth, a real SystemClock routine and real
    // wall-clock waiting — the closest thing to stamping the footswitch.
    //
    // Faked up rather than recorded: a 0.3 s loop keeps the check quick, and
    // what is being tested is the resume, not the recording. With no engine
    // synth there is no playhead to read, so queryLoopPhase answers nil and the
    // break takes the conservative path — a whole pass assumed remaining. Two
    // loops asked for, so that pass plus one more: 0.6 s. (Two rather than the
    // default one, so there is a comfortable window to observe it open in.)
    ~looper.instVarPut(\state, \playing);
    ~looper.instVarPut(\loopFrames, (0.3 * 48000).asInteger);
    ~looper.instVarPut(\lastResult, (numerator: 4, denominator: 4, tau: 0.075,
        sub: 1, k: 1, downbeatOffset: 0));
    ~looper.breakLoops = 2;
    ~ok.("the fake take is a 0.3 s loop",
        (~looper.loopDuration - 0.3).abs < 1e-6, ~looper.loopDuration.asString);
    ~looper.fireBreak;
    0.1.wait;
    ~ok.("the break opened", ~looper.onBreak);
    ~ok.("the state block wears the hatch", (~statusShown[\hatch] == true) and: { ~statusShown[\label] == "BREAK" },
        ~statusShown[\label].asString);
    ~ok.("and the Break tile too", ~breakButton.hatch, ~breakButton.sub);
    ~ok.("a resume time was published for the countdown",
        ~looper.breakEndsAt.notNil, ~looper.breakEndsAt.asString);
    // Still muted at 0.4 s: a bar-length break, and a one-loop break too, would
    // already be over by now — this is waiting out the second pass.
    0.3.wait;
    ~ok.("still silent after 0.4 s — it is waiting for a loop boundary, not a bar",
        ~looper.onBreak, "onBreak " ++ ~looper.onBreak.asString);
    // The countdown is the 4 Hz repaint's (the resume time is published
    // after the break opens), so it is read here, not at 0.1 s.
    ~ok.("the Break tile counts down", ~breakButton.hatch and: { ~breakButton.sub.beginsWith("back in") },
        ~breakButton.sub);
    1.0.wait;   // well past the 0.6 s break
    ~ok.("THE LOOP COMES BACK — break ended on its own", ~looper.onBreak.not);
    ~ok.("the state block's hatch went", ~statusShown[\hatch] != true, ~statusShown[\label].asString);
    ~ok.("the break tile cleared", ~breakButton.hatch.not);
    // Put the fixture back so the teardown checks below see an empty looper.
    ~looper.instVarPut(\state, \empty);
    ~looper.instVarPut(\loopFrames, 0);
    ~looper.instVarPut(\lastResult, nil);
    ~statusPaintState.();

    "== the theme ==".postln;
    // The rebuild holds the language (and the MIDI clock) for 65-80 ms, so a
    // loop that moves refuses it: T sits beside R.
    ~looper.instVarPut(\state, \playing);
    ~tmpWin = ~guiWindow;
    ~guiKeyDown.($t, 0, 84);
    0.3.wait;
    ~ok.("T with a loop playing: refused, the window left alone",
        (~guiThemeName == \dark) and: { ~guiWindow === ~tmpWin }, ~guiThemeName.asString);
    ~ok.("and the footer says why", ~guiFooterShown.asString.beginsWith("Refused: the theme"),
        ~guiFooterShown.asString);
    ~looper.instVarPut(\state, \empty);
    ~guiToast = nil;
    // T rebuilds the window in the other theme, kept in settings.json (a
    // scratch one here); the model is untouched, the view shown kept, and the
    // window where it was. With a settings.json already there, read from
    // disk as on a rig: parseJSON's Dictionaries have no room for a key they
    // lack, and the theme's "gui" is one (it failed so on the rig, and left
    // the old window half recoloured).
    File.use(~midiSettingsPath.(), "w", { |f| f.write("{\"format\": \"megalooper settings\", "
        "\"version\": 1,\n \"midi\": {\"maps\": {\"sa\": \"tsmega\"},\n  \"listen\": {},\n  "
        "\"sendBack\": {\"Faderfox UC4\": true},\n  \"hysteresis\": 1, \"takeover\": \"none\"}}\n") });
    ~midiSettings = nil;
    ~guiSelectView.(\sound);
    ~tmpWin = ~guiWindow.bounds;
    ~tmpOld = ~guiWindow;
    ~guiKeyDown.($t, 0, 84);
    1.0.wait;
    if(~checkGuiQuiet == true) { ~guiWindow.alpha_(0) };
    ~ok.("T switches to the light theme", ~guiThemeName == \light, ~guiThemeName.asString);
    ~ok.("in a new window, on the view it showed",
        (~guiWindow !== ~tmpOld) and: { ~tmpOld.isClosed } and: { ~guiWindow.isClosed.not } and: { ~guiView == \sound });
    ~ok.("the new window wears the light theme",
        ((~guiWindow.view.background.asArray - ~guiThemes[\light][\bg].asArray).abs.maxItem < 0.01),
        ~guiWindow.view.background.asString);
    ~ok.("where the old one stood", ~guiWindow.bounds == ~tmpWin,
        ~guiWindow.bounds.asString + "vs" + ~tmpWin.asString);
    ~ok.("and keeps it for the next boot", ~guiThemeSaved.() == \light, ~guiThemeSaved.().asString);
    ~tmpOld = File.readAllString(~midiSettingsPath.());
    ~ok.("settings.json says light, and kept the rest", ~tmpOld.contains("\"theme\": \"light\"")
        and: { ~tmpOld.contains("Faderfox UC4") }, ~tmpOld);
    ~ok.("the model went on: the analysis monitor still runs", ~looper.analysisMonitorOn);
    ~guiThemeToggle.();
    1.0.wait;
    if(~checkGuiQuiet == true) { ~guiWindow.alpha_(0) };
    ~ok.("and back", (~guiThemeName == \dark) and: { ~guiThemeSaved.() == \dark });

    // Megalooper SA's Effects pane, on the SA rig only (~checkGuiProfile = \sa):
    // the same contracts as above — the model reaches a hidden pane, the
    // widgets write to the model only — plus a preset round trip through the
    // real Bias FX.
    // A function of its own, with arguments rather than vars inside the if:
    // sclang 3.13 could miscompile a var declared in an inlined branch.
    if(~rp[\sa] == true) { { |tmp, m, slug, second, plugs, scanned, done, waited, entries, d, got|
        "== Megalooper SA: the Effects pane ==".postln;
        ~ok.("the Effects tab is there on SA", ~guiPaneOrder.includes(\effects));
        ~ok.("its holder holds the pane", ~guiPaneHolders[\effects].children.size == 1);
        ~ok.("a tile per effect, plus Bias FX", ~effectsTiles.size == (MegaSAFx.keys.size + 1),
            ~effectsTiles.size.asString);
        ~guiSelectTab.(\rig); 0.2.wait;
        m.setFx(\redux, true); 0.3.wait;
        ~ok.("a footswitch lights its tile while the pane is hidden",
            ~effectsTiles[\redux][\on].value == 1, ~effectsTiles[\redux][\on].value.asString);
        ~ok.("and dots the FX tab", ~guiTabActive.(\fx)[0] == true);
        m.setFx(\redux, false); 0.3.wait;
        ~ok.("off again, tile and tab", (~effectsTiles[\redux][\on].value == 0)
            and: { ~guiTabActive.(\fx)[0] == false });
        ~guiSelectTab.(\effects);
        ~effectsSelect.(\filter); 0.2.wait;
        m.setFxParam(\filterFreq, 1000); 0.3.wait;
        ~ok.("the model moves the readout", ~effectsWidgets[\filterFreq][\readout].string.contains("1000"),
            ~effectsWidgets[\filterFreq][\readout].string);
        ~effectsWidgets[\filterFreq][\knob].valueAction_(0.5); 0.3.wait;
        ~ok.("the knob moves the model",
            (m.fxParam(\filterFreq) - MegaSAFx.param(\filterFreq)[\spec].map(0.5)).abs < 0.01,
            m.fxParam(\filterFreq).asString);
        ~ok.("the tile marks the edit", ~effectsTiles[\filter][\select].string.contains("•"),
            ~effectsTiles[\filter][\select].string);
        slug = m.saveSound(tmp, "Check GUI");
        2.0.wait;   // the plugin writes its state, then the file is moved into place
        ~ok.("a sound saves both chains", File.exists(tmp +/+ "check-gui.json"), slug.asString);
        ~ok.("and the plugin's own state beside it", (tmp +/+ "check-gui.states" +/+ "*").pathMatch.notEmpty);
        m.resetFx(\filter); 0.3.wait;
        ~ok.("Reset puts the effect back", m.fxEdited(\filter).not);
        ~ok.("and clears the tile's mark", ~effectsTiles[\filter][\select].string.contains("•").not);
        ~ok.("the sound recalls the edit", (m.loadSound(tmp, "check-gui") == true)
            and: { (m.fxParam(\filterFreq) - MegaSAFx.param(\filterFreq)[\spec].map(0.5)).abs < 0.01 });
        3.0.wait;   // the plugin's state load, with the guitar muted around it
        ~ok.("and the guitar is unmuted after the state load", m.mute(\guitar).not);
        m.resetFx(\filter);
        m.deleteSound(tmp, "check-gui");
        ~ok.("a deleted sound takes its states along",
            File.exists(tmp +/+ "check-gui.json").not and: { File.exists(tmp +/+ "check-gui.states").not });
        // The chains edited by menu, on the real server (docs/dev/device-chains.md, phase 6).
        slug = [m.loopChain.devices.size, ~guiView];
        ~effectsAddItems.(\loop).detect { |it| it[\label] == MegaSAFx.title(\delay) }[\action].value;
        0.6.wait;
        ~ok.("+ adds an effect at the end of the loop chain, with its tile",
            (m.loopChain.devices.size == (slug[0] + 1)) and: { m.loopChain.devices.last.type == \delay }
                and: { ~effectsTiles[m.loopChain.devices.last.id].notNil }, m.loopChain.devices.collect(_.id).asString);
        ~guiSelectView.(\fx); 0.3.wait;
        ~guiKeyDown.($z, 1048576, 0);
        0.6.wait;
        ~ok.("Cmd+Z on the effects' view takes it out again", m.loopChain.devices.size == slug[0],
            m.loopChain.devices.collect(_.id).asString);
        ~guiSelectView.(slug[1]); 0.3.wait;
        ~effectsPaintStatus.();
        ~guiCpuPainted = nil;
        ~guiCpuPaint.();
        ~ok.("the top bar's CPU tile shows the server's load", ~guiCpuTile.states[0][0].contains("%"), ~guiCpuTile.states[0][0]);
        ~ok.("the diagnostics name the build and both real chains",
            ~effectsDiagnostics.().contains("build: ") and: { ~effectsDiagnostics.().contains("guitar chain:") }
                and: { ~effectsDiagnostics.().contains("Hz, CPU") }, ~effectsDiagnostics.());
        // A second plugin, for real (docs/dev/device-chains.md, phase 5): found by
        // a scan beside the running server, added to the loop chain, opened,
        // parked by undo, back by redo, and written with a state of its own.
        // Skipped, and said, without VSTPlugin or without that plugin
        // (~checkGuiSecondPlugin names another).
        second = ~checkGuiSecondPlugin ? "/Library/Audio/Plug-Ins/VST3/Ozone Imager 2.vst3";
        if(MegaSAPlugins.available and: { File.exists(second) } and: { m.guitarPlugin.notNil }) {
            plugs = tmp +/+ "plugs";
            // (A run that stopped half-way may have left one: the folder's name repeats.)
            ("/bin/rm -rf " ++ plugs.shellQuote ++ " " ++ (tmp +/+ "catalog").shellQuote).systemCmd;
            File.mkdir(plugs);
            ("/bin/ln -s " ++ second.shellQuote ++ " " ++ (plugs +/+ second.basename).shellQuote).systemCmd;
            MegaSAPlugins.scan(tmp +/+ "catalog", [plugs], { |ok| done = ok; scanned = true });
            waited = 0;
            while { (scanned != true) and: { waited < 90 } } { 0.25.wait; waited = waited + 0.25 };
            entries = MegaSAPlugins.read(tmp +/+ "catalog");
            ~ok.("a scan beside the running server finds the plugin, and megalooper can host it",
                (done == true) and: { entries.size == 1 } and: { MegaSAPlugins.offered(entries).any { |e| e[\why].isNil } },
                [done, waited, entries].asString);
            s.sendMsg(*MegaSAPlugins.readCacheMsg(tmp +/+ "catalog"));
            0.5.wait;
            m.catalog = entries;
            d = entries.first !? { |e| m.insertPlugin(\loop, nil, e[\key]) };
            waited = 0;
            while { d.notNil and: { d.plugin.notNil } and: { #[\open, \failed, \crashed].includes(d.plugin.state).not }
                and: { waited < 45 } } { 0.25.wait; waited = waited + 0.25 };
            ~ok.("added to the loop chain, it opens on the real server", d.notNil and: { d.plugin.notNil } and: { d.plugin.state == \open },
                [d !? { |x| x.id }, d !? { |x| x.plugin !? { |pl| pl.state } }, waited].asString);
            0.5.wait;
            ~ok.("...with a tile of its own, and no marker left behind",
                (d.notNil and: { (~effectsPluginTiles ? ())[d.id].notNil })
                    and: { (m.markerDir.isNil) or: { (m.markerDir +/+ "*.opening").pathMatch.isEmpty } },
                (~effectsPluginTiles ? ()).keys.asArray.asString);
            ~ok.("the guitar's plugin is still open beside it", m.guitarPlugin.state == \open, m.guitarPlugin.state.asString);
            m.undo;
            0.6.wait;
            ~ok.("undo parks it, still open", d.notNil and: { m.loopChain.devices.includes(d).not } and: { d.plugin.state == \open });
            m.redo;
            0.6.wait;
            ~ok.("redo brings the same plugin back", d.notNil and: { m.loopChain.devices.includes(d) } and: { d.plugin.state == \open });
            got = nil;
            m.writeSound(tmp +/+ "two.json", "two", true, nil, { |ok, why| got = [ok, why] });
            waited = 0;
            while { got.isNil and: { waited < 30 } } { 0.25.wait; waited = waited + 0.25 };
            ~ok.("a sound written then has each plugin write a state of its own",
                ((got ? [false])[0] == true) and: { (tmp +/+ "two.states" +/+ "*").pathMatch.size == 2 },
                [got, (tmp +/+ "two.states" +/+ "*").pathMatch.collect(_.basename)].asString);
            ~ok.("...the second one's in its own format, named by its device",
                (tmp +/+ "two.states" +/+ (d.id ++ "-*")).pathMatch.any { |f| f.endsWith(d.plugin.stateExtension) },
                (tmp +/+ "two.states" +/+ "*").pathMatch.collect(_.basename).asString);
            d !? { m.removeDevice(d.id) };
            0.6.wait;
            ("/bin/rm -rf " ++ (tmp +/+ "plugs").shellQuote ++ " " ++ (tmp +/+ "catalog").shellQuote ++ " "
                ++ (tmp +/+ "two.json").shellQuote ++ " " ++ (tmp +/+ "two.states").shellQuote).systemCmd;
        } { ("  (no second plugin to host: " ++ second ++ " is not here, or VSTPlugin or the guitar's plugin is missing; the two-plugin check is skipped)").postln };
        File.delete(tmp);
    }.value(PathName.tmp +/+ "megalooper-checkgui-fx-" ++ UniqueID.next, ~megaSA) };

    // Megalooper SA's Drums pane, on the SA rig only: the tab's dot from the
    // model while the pane is hidden, then the step lanes PAINTED once it
    // shows (a hidden view never paints, which is why check-gui-drums.scd can
    // only drive their mouse handlers) and a step set through one. A MegaSA
    // without drums, or a Mac where no kit has its samples, shows the note
    // pane, and the rest is skipped.
    if(~rp[\sa] == true) { { |d, wasPlaying, paints, lane, before, want, level, ds, rs|
        "== Megalooper SA: the Drums pane ==".postln;
        ~ok.("the Drums tab is there on SA", ~guiPaneOrder.includes(\drums));
        ~ok.("its holder holds the pane", ~guiPaneHolders[\drums].children.size == 1);
        if(d.isNil or: { ~drumsKitsHere.(d).not }) {
            (if(d.isNil) { "  (this MegaSA has no drums" } { "  (no kit here has its samples" }
                ++ ": the pane is the note, the rest is skipped)").postln;
        } {
            ~guiSelectTab.(\rig); 0.2.wait;
            wasPlaying = d.playing;
            // No loop plays here, so `playing` is put in by hand for the
            // dot; nothing is scheduled from it.
            d.instVarPut(\playing, true);
            d.setOn(true); 0.3.wait;
            ~ok.("on and playing dot the hidden Drums tab", ~guiTabActive.(\drums)[0] == true);
            d.setOn(false); 0.3.wait;
            ~ok.("off clears the dot", ~guiTabActive.(\fx)[1] == false);
            ~ok.("and the hidden pane's switch followed the model", ~drumsWidgets[\on][\view].value == 0);
            d.instVarPut(\playing, wasPlaying);
            d.setOn(true); 0.3.wait;
            ~ok.("on but not playing, no dot", wasPlaying or: { ~guiTabActive.(\fx)[1] == false });
            paints = ~drumsPaints ? 0;
            ~guiSelectTab.(\drums); 0.5.wait;
            ~ok.("the lanes paint once the tab shows", (~drumsPaints ? 0) > paints,
                ((~drumsPaints ? 0) - paints).asString);
            // A value it does not have yet (kept drums may have set it):
            // the top of the step is 6, its bottom 0.
            lane = ~drumsLanes[0];
            before = d.step(~drumsPattern, ~drumsPage, 0, 0);
            want = if(before == 6) { 0 } { 6 };
            paints = ~drumsPaints;
            lane.mouseDownAction.value(lane, 5, if(want == 6) { 1 } { ~drumsLaneHeight - 1 }, 0, 0, 1);
            0.3.wait;
            ~ok.("a click on a lane sets its step", d.step(~drumsPattern, ~drumsPage, 0, 0) == want,
                d.step(~drumsPattern, ~drumsPage, 0, 0).asString);
            ~ok.("and repaints it", ~drumsPaints > paints);
            d.setStep(~drumsPattern, ~drumsPage, 0, 0, before);
            // One fader on two tabs (gui-sa.scd): a drag on the Drums tab's
            // Drums strip moves the Rig's as it goes, and both stay where it
            // ended. The level is put back after.
            ds = ~drumsLevels[\drums] !? { |w| w[\slider] };
            rs = ~saRigLevels[\drums] !? { |w| w[\slider] };
            if(ds.isNil or: { rs.isNil }) {
                "  (the Drums strip is not on both tabs: the fader check is skipped)".postln;
            } {
                level = ~megaSA.level(\drums);
                ds.mouseDownAction.value(ds, 10, 5, 0, 0, 1);
                ds.valueAction_(~saLevelSpec.unmap(-25));
                0.3.wait;
                ~ok.("a drag on the Drums tab's fader moves the Rig's as it goes",
                    (rs.value - ~saLevelSpec.unmap(-25)).abs < 1e-3, ~saLevelSpec.map(rs.value).asString);
                ds.mouseUpAction.value(ds, 10, 5, 0, 0);
                0.3.wait;
                ~ok.("and both stay where it ended", ((ds.value - ~saLevelSpec.unmap(-25)).abs < 1e-3)
                    and: { (rs.value - ~saLevelSpec.unmap(-25)).abs < 1e-3 },
                    [ds, rs].collect { |s| ~saLevelSpec.map(s.value) }.asString);
                ~megaSA.setLevel(\drums, level);
                0.3.wait;
            };
            // Only a reverb with its impulse responses in is wet: the row is
            // live then, and greyed with its reason otherwise.
            ~ok.("the Reverb row says what the drums' reverb does (" ++ d.reverbState ++ ")",
                ((~drumsWidgets[\reverbState] !? { |w| w[\view].string }) == ~drumsReverbLine.(d))
                    and: { ~drumsWidgets[\reverbMix][\view].enabled == (d.reverbState == \ready) },
                ~drumsWidgets[\reverbState] !? { |w| w[\view].string });
            ~guiSelectTab.(\rig);
        };
    }.value(~drumsModel !? { |f| f.value }) };

    "== teardown ==".postln;
    ~guiWindow.close;
    // The scratch folder, whole: since the sounds live there it holds folders
    // too (sa/, with the kept sound), which File.delete leaves behind.
    if(~midiUserRootOverride.beginsWith(PathName.tmp) and: { ~midiUserRootOverride.contains("megalooper-checkgui-") }) {
        ("/bin/rm -rf " ++ ~midiUserRootOverride.shellQuote).systemCmd;
    };
    0.4.wait;
    ~ok.("onMonitor cleared on close", ~looper.onMonitor.isNil);
    ~ok.("analysis monitor stopped on close", ~looper.analysisMonitorOn.not);

    "".postln;
    if(~fail == 0) {
        ("GUI CHECK PASSED — " ++ ~pass ++ " checks").postln;
    } {
        ("GUI CHECK FAILED — " ++ ~fail ++ " of " ++ (~pass + ~fail)).postln;
        ~fails.do { |f| ("  " ++ f).postln };
    };
    ~looper.free;
    s.quit;
    0.5.wait;
    if(~fail == 0) { 0.exit } { 1.exit };
};
