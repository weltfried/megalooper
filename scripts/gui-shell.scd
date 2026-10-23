// megalooper — the one window: a top bar, the status band, four views and a
// footer (docs/dev/stage-ui.md).
//
// Loaded by boot.scd AFTER every pane file, because it calls their builders.
// Defines only, runs nothing. Entry point:
//   ~buildGuiWindow — closes any previous window and builds a fresh one against
//                     the EXISTING ~looper: top bar, status band and strip,
//                     every view and the footer. Safe to re-run; it never
//                     touches the model, so the recorded loop survives.
//                     Follow with ~wireLooperController.() to re-subscribe the
//                     widgets.
//
// THIS IS THE ONLY GUI FILE THAT CONSTRUCTS A Window, and it must never do so
// at load time — check.scd loads it headless, and a window opening there is the
// failure already documented for launcher.scd.
//
// Why one window, and why this one. Six windows meant six things that could end
// up behind Ableton or off the edge of a laptop screen; mid-take, the thing you
// need to read is then the thing you cannot find. The stage window is a laptop
// screen's worth (1440 × 900) laid out to be read from playing distance:
//   - the top bar: the views, the theme, the rig's MIDI lamp, MIDI MAP and SET
//     REC, on every view;
//   - on Perform, the status band: what the looper is doing (the state block),
//     what it decided about the take, what the input is doing, and the bar
//     grid with the playhead. On every other view it folds into a 56 px strip,
//     so the state, the take and the position never leave the screen;
//   - the views: Perform (the five layers, the actions, the macros), Sound
//     (the cutter and the grains), FX and Drums (Megalooper SA's), Setup
//     (analysis, the rig, calibration, MIDI in) and the Calibrate wizard. Keys
//     1-6 and the MIDI map's view controls switch them;
//   - the footer: the keys, and one status line ("Refused: …", typing, what
//     MIDI has to say). MIDI Map mode's bar opens above it.
//
// The panes are built ONCE and kept alive; switching views only changes which
// one the StackLayout shows. That is what lets ~wireLooperController hold direct
// references to widgets across every pane: a hidden pane's slider is still a
// live Qt object, so a MIDI CC arriving while you look at another view still
// lands somewhere real.
(
// ---- The panes and the views ------------------------------------------------------
// A pane is what a builder makes and swaps into its holder (~guiSwapPane);
// a view is what the stack shows, one or more panes side by side. Megalooper SA
// adds the Effects and Drums panes, each with a view of its own (the drums
// need the whole height to be edited); every other rig has neither, because Live has the effects and the drums there. Chosen
// when the window is built, since that is when the rig is known.
~guiPaneOrderFor = { |sa = false|
    if(sa == true) {
        [\perform, \cutter, \grains, \effects, \drums, \synth, \analysis, \rig, \calibrate]
    } {
        [\perform, \cutter, \grains, \analysis, \rig, \calibrate]
    }
};
~guiPaneOrder  = ~guiPaneOrderFor.(false);
~guiPaneLabels = (perform: "Perform", cutter: "Cutter", grains: "Grains",
    effects: "Effects", drums: "Drums", synth: "Synth", analysis: "Analysis", rig: "Rig", calibrate: "Calibrate");

~guiViewOrderFor = { |sa = false|
    if(sa == true) { [\perform, \sound, \fx, \drums, \synth, \setup, \calibrate] } { [\perform, \sound, \setup, \calibrate] }
};
~guiViewOrder = ~guiViewOrderFor.(false);
// The footer's resting line, on every view: the tabs' keys as the rig has
// them (1 2 5 without SA; 1–5 7 with: the Synth's 7 came after Calibrate's
// 6), Calibrate's, which has no tab, and the theme's. Runs of three or more
// keys as a–b.
~guiKeysHint = {
    var tabs = ~guiViewOrder.reject { |k| k == \calibrate }.collect { |k| ~guiViewNumbers[k] }.sort;
    var runs = List.new, run;
    tabs.do { |n| if(runs.notEmpty and: { runs.last.last == (n - 1) }) { runs.last.add(n) } { runs.add(List[n]) } };
    run = runs.collect { |r| if(r.size > 2) { r.first.asString ++ "–" ++ r.last } { r.join(" ") } }.join(" ");
    "keys " ++ run ++ " views"
        ++ (if(~guiViewOrder.includes(\calibrate)) { " · " ++ ~guiViewNumbers[\calibrate] ++ " calibrate" } { "" })
        ++ " · T theme · H help"
};
~guiViewLabels = (perform: "Perform", sound: "Sound", fx: "FX", drums: "Drums", synth: "Synth", setup: "Setup",
    calibrate: "Calibrate");
// Fixed whatever the rig, so a key and a program change mean the same view
// everywhere: 3 and 4 are simply not there without SA.
~guiViewNumbers = (perform: 1, sound: 2, fx: 3, drums: 4, setup: 5, calibrate: 6, synth: 7);
~guiViewPanes = (perform: [\perform], sound: [\cutter, \grains], fx: [\effects], drums: [\drums], synth: [\synth],
    setup: [\analysis, \rig], calibrate: [\calibrate]);
// The Calibrate wizard is reached from Setup and goes back to it: its tab is
// Setup's.
~guiViewTab = (calibrate: \setup);
~guiView = \perform;

// The view a pane is in, and that view's place in the stack. What the timers
// of a pane ask ("is my pane showing?"), as they did of the old tabs.
~guiViewOf = { |pane| ~guiViewPanes.keys.detect { |v| ~guiViewPanes[v].includes(pane) } ? pane };
~guiTabIndex = { |key| ~guiViewOrder.indexOf(~guiViewOf.(key)) };

// Which views carry activity dots, and how to ask the model. Reading the MODEL
// rather than a widget is the point: the dot has to be right for a view you
// cannot see, which is exactly when a widget's value is the thing you cannot
// trust.
~guiPaneActive = (
    cutter:   { ~looper !? { |l| l.bbcut } ? false },
    grains:   { ~looper !? { |l| l.granularOn } ? false },
    // Any of SA's effects switched on.
    effects:  { ~megaSA !? { |m| m.fxOn.includes(true) } ? false },
    // SA's drums sounding: the steps on (PC 17) AND the transport playing.
    // `on` alone is true from boot, so it would light the tab all the time.
    drums:    { ((~drumsModel !? { |f| f.value }) !? { |d| d.on and: { d.playing } }) ? false },
    // The note sequencer sounding: on, and the transport playing.
    synth:    { ((~synthModel !? { |f| f.value }) !? { |d| d.notesOn and: { d.playing } }) ? false },
    // Lit while a calibration is part-done, so a wizard abandoned halfway
    // through says so from whichever view you are looking at.
    calibrate: { ~calibrator !? { |c|
        (c.stepIndex > 0) and: { c.isComplete.not } } ? false }
);
// Each view's dots: a pane and the colour it lights in.
~guiViewDots = (sound: [[\cutter, \cut], [\grains, \grain]], fx: [[\effects, \fx]], drums: [[\drums, \drum]],
    synth: [[\synth, \synth]],
    setup: [[\calibrate, \armed]]);

~guiPaneHolders = ~guiPaneHolders ? IdentityDictionary.new;
~guiTabButtons  = ~guiTabButtons  ? IdentityDictionary.new;

// Swap a freshly built pane into its holder. Called by every ~buildXPane.
//
// The StackLayout itself is built once and NEVER mutated: its children are the
// views, and index/count stay fixed for the life of the window. That is the
// invariant that keeps the tabs honest — StackLayout has insert but no removal,
// and Qt's insertWidget silently bumps currentIndex, so a rebuild that went
// through the stack would be one forgotten line away from a tab pointing at the
// wrong view with nothing to check it against.
//
// Instead each pane has a HOLDER whose single child is the pane. A fresh View
// each time is required because Qt refuses a second layout_ on a view.
//
// Nil-guarded on the holder so a pane builder stays callable with no shell at
// all — which is how check.scd and the headless tests reach these files.
~guiSwapPane = { |key, view|
    ~guiPaneHolders[key] !? { |holder|
        holder.children.copy.do { |c| c.remove };
        holder.layout.add(view);
    };
    view
};

// ---- The tabs ---------------------------------------------------------------------------
// One per view but Calibrate: its number, its name, and its parts' dots, each
// filled in its layer's colour while that part runs. Drawn rather than a
// Button: Qt's buttons won't take the flat inverted look, and a dot is a
// square in a colour, which a label can't hold.
~guiTabFont = { |current| ~guiSans.(15, current == true) };
// Compact (~guiTopBarFit, in a narrow window): no number, a narrower margin.
// The dots stay: they say which parts are running.
~guiTabCompact = false;
~guiTabWidth = { |key, compact|
    var n = ~guiViewNumbers[key].asString.bounds(~guiMono.(11)).width;
    var label = (~guiViewLabels[key] ? key.asString).bounds(~guiTabFont.(true)).width;
    var dots = (~guiViewDots[key] ? []).size;
    var tail = if(dots > 0) { 10 + (dots * 11) } { 0 };
    if((compact ? ~guiTabCompact) == true) { (28 + label + tail).ceil } { (44 + n + 10 + label + tail).ceil }
};
~guiTab = { |key|
    var tab = UserView().canFocus_(false).fixedWidth_(~guiTabWidth.(key))
        .toolTip_(~guiViewLabels[key] ++ " · key " ++ ~guiViewNumbers[key])
        .drawFunc_({ |v|
            var b = v.bounds, h = b.height;
            var current = (~guiViewTab[~guiView] ? ~guiView) == key;
            var ink = if(current) { ~gt[\bg] } { ~gt[\ink] };
            var compact = ~guiTabCompact == true;
            var x = if(compact) { 14 } { 22 }, nfont = ~guiMono.(11), font = ~guiTabFont.(current);
            var label = ~guiViewLabels[key] ? key.asString;
            var num = ~guiViewNumbers[key].asString;
            var active;
            if(current) { Pen.fillColor = ~gt[\ink]; Pen.addRect(Rect(0, 0, b.width, h)); Pen.fill };
            if(compact.not) {
                Pen.stringInRect(num, Rect(x, 0, 30, h), nfont, Color(ink.red, ink.green, ink.blue, 0.6),
                    QAlignment(\left));
                x = x + num.bounds(nfont).width + 10;
            };
            Pen.stringInRect(label, Rect(x, 0, b.width - x, h), font, ink, QAlignment(\left));
            x = x + label.bounds(~guiTabFont.(true)).width + 10;
            (~guiViewDots[key] ? []).do { |d|
                active = ~guiPaneActive[d[0]] !? { |f| f.value } ? false;
                if(active) {
                    Pen.fillColor = ~gt[d[1]];
                    Pen.addRect(Rect(x, (h / 2) - 4, 8, 8));
                    Pen.fill;
                } {
                    Pen.strokeColor = ~gt[\mute];
                    Pen.width = 1;
                    Pen.addRect(Rect(x + 0.5, (h / 2) - 3.5, 7, 7));
                    Pen.stroke;
                };
                x = x + 11;
            };
        })
        .mouseDownAction_({ ~guiSelectView.(key); true });
    ~guiTabButtons[key] = tab;
    tab
};

// Paint the tabs: which view is showing, and which parts are running.
~guiRefreshTabs = {
    ~guiTabButtons.do { |t| if(t.isClosed.not) { t.refresh } };
};
// The parts' state, as the dots show it: for the checks, which can't see a
// paint.
~guiTabActive = { |view|
    (~guiViewDots[view] ? []).collect { |d| ~guiPaneActive[d[0]] !? { |f| f.value } ? false }
};

// Show a view. The status band is Perform's; every other view gets the strip.
~guiSelectView = { |key|
    var i = ~guiViewOrder.indexOf(key);
    if(i.isNil) {
        if(key == \fx) { ~guiSay.("No FX on this rig: Live has them", \info) };
        if(key == \drums) { ~guiSay.("No Drums on this rig: Live has them", \info) };
        if(key == \synth) { ~guiSay.("No Synth on this rig: it is Megalooper SA's", \info) };
    } {
        ~guiView = key;
        ~guiStack !? { |st| st.index = i };
        ~statusBand !? { |b| if(b.isClosed.not) { b.visible_(key == \perform) } };
        ~statusStrip !? { |b| if(b.isClosed.not) { b.visible_(key != \perform) } };
        ~guiRefreshTabs.();
        ~statusRepaintGrids !? { |f| f.value };
        ~guiFooterRefresh.();
        // The MIDI monitor and the analysis readout repaint only while seen;
        // now seen, they catch up at once.
        ~midiMonitorDirty = true;
        ~analysisDirty = true;
        // DEFERRED, and that matters. Hiding a view that contains the focus
        // widget makes Qt hand focus to the next visible focusable widget —
        // plausibly the incoming view's preset-name field, which would then
        // swallow every single-key shortcut and sit there looking like it was
        // asked to. A synchronous grab happens BEFORE Qt's transfer and gets
        // undone by it.
        { ~guiWindow !? { |w| if(w.isClosed.not) { w.view.focus(true) } } }.defer(0);
    };
};
// A pane's view, shown: what the older code asks for ("show the Cutter").
~guiSelectTab = { |key| ~guiSelectView.(~guiViewOf.(key)) };

// ---- The footer: the keys, and one line of status ---------------------------------------
// The status line shows one thing, in this order: the typing indicator; a
// message said in the last 2.6 s (~guiSay: "Refused: …" on \rec, anything
// else in ink); what MIDI has to say (a map that could not be read, an input
// switched off or gone: docs/dev/midi-map.md 8.5); then the resting line. One
// function decides, so nothing can leave a stale message up.
~guiTyping = false;
~guiToast = nil;
~guiSay = { |msg, kind|
    ~guiToast = (msg: msg.asString, kind: kind ? \info, at: Main.elapsedTime);
    ~guiFooterRefresh.();
};
~guiSetTyping = { |flag|
    ~guiTyping = flag == true;
    ~guiHintRowRefresh.();
};
~guiFooterRefresh = {
    var midi = ~midiAttention !? { |f| f.value };
    var st = ~guiFooterStatus;
    var toast = ~guiToast;
    var text, ink, fill;
    if(toast.notNil and: { (Main.elapsedTime - toast[\at]) > 2.6 }) { ~guiToast = nil; toast = nil };
    case
    { ~guiTyping == true } {
        text = "Typing… Enter or Esc to release the keyboard"; ink = ~gt[\onacc]; fill = ~gt[\armed];
    }
    { toast.notNil } {
        text = toast[\msg];
        if(toast[\kind] == \bad) { ink = Color.white; fill = ~gt[\rec] } { ink = ~gt[\ink]; fill = nil };
    }
    { midi.notNil } {
        text = midi[0];
        if(midi[1] == \note) { ink = ~gt[\onacc]; fill = ~gt[\armed] } { ink = Color.white; fill = ~gt[\rec] };
    }
    {
        text = ~guiKeysHint.();
        ink = ~gt[\mute]; fill = nil;
    };
    if(st.notNil and: { st.isClosed.not } and: { [text, ink, fill] != ~guiFooterPainted }) {
        ~guiFooterPainted = [text, ink, fill];
        st.states_([[text, ink, fill]]);
        st.fixedWidth_((text.bounds(~guiMono.(12, true)).width + 24).ceil.min(760));
    };
    ~guiFooterShown = text;
};

// The map bar (gui-mapmode.scd) opens above the footer while MIDI Map mode is
// on, and stays shut while a name field has the keyboard (a field losing it
// can't put the bar back over what you type: docs/dev/midi-map.md 7.1).
// ~guiHintShows says which shows, for the checks: a view in a window never
// shown answers false to `visible` whatever it was told.
~guiHintRowRefresh = {
    var barView = (~mapBar ? ())[\view];
    var bar = (~mapMode == true) and: { ~guiTyping != true } and: { barView.notNil } and: { barView.isClosed.not };
    ~guiHintShows = \text;
    if(barView.notNil and: { barView.isClosed.not }) {
        barView.visible_(bar);
        if(bar) { ~guiHintShows = \mapBar; ~mapBarRefresh !? { |f| f.value } };
    };
    ~keyHintText !? { |t| if(t.isClosed.not) { t.string_(~keyHintString) } };
    ~mapButtonPaint !? { |f| f.value };
    ~guiFooterRefresh.();
};

// ---- Keys --------------------------------------------------------------------------------
// MIDI Map mode's come first (gui-mapmode.scd): Cmd+M, and while it is on Esc,
// Delete and Cmd+Z. A letter with Cmd or Ctrl held is no shortcut, so Cmd+M
// can't multiply nor Cmd+C clear. `key` is Qt's key code; the letters go by the
// character, as they always have. 1-7 show the views, T switches the theme,
// and Esc on the wizard goes back to Setup.
~guiKeyEscape = 16r1000000;
~guiKeyDown = { |char, modifiers, key|
    var held = modifiers.notNil and: { modifiers.isCmd or: { modifiers.isCtrl } };
    var view = ~guiViewNumbers.keys.detect { |v| char.notNil and: { ~guiViewNumbers[v].asString == char.asString } };
    case
    { (~mapKeyDown !? { |f| f.value(char, modifiers, key) }) == true } { true }
    // Esc lets go of an effect's tile being dragged (gui-effects.scd).
    { (key == ~guiKeyEscape) and: { (~effectsDragCancel !? { |f| f.value }) == true } } { true }
    // Cmd+Z and Shift+Cmd+Z undo and redo a chain edit, on the effects' view
    // only (map mode's keys came first).
    { held and: { char.notNil } and: { char.toLower == $z } and: { ~guiView == \fx } and: { ~megaSA.notNil } } {
        if(modifiers.isShift) { ~megaSA.redo } { ~megaSA.undo };
        true
    }
    { held } { nil }
    { view.notNil } { ~guiSelectView.(view); true }
    { (key == ~guiKeyEscape) and: { ~guiView == \calibrate } } { ~guiSelectView.(\setup); true }
    { char == $t } { { ~guiThemeToggle.() }.defer(0); true }
    { char == $h } { ~guiHelpToggle.(); true }
    { char == $r } { ~looper !? { |l| l.trigger } }
    { char == $s } { ~looper !? { |l| l.stopPlayback } }
    { char == $m } { ~looper !? { |l| l.multiply } }
    { char == $u } { ~looper !? { |l| l.undo } }
    { char == $v } { ~looper !? { |l| l.reverse } }
    { char == $g } { ~looper !? { |l| l.toggleGranular } }
    { char == $b } { ~looper !? { |l| l.bbcut = l.bbcut.not } }
    { char == $k } { ~looper !? { |l| l.fireBreak } }
    { char == $d } { ~looper !? { |l| l.toggleDissolve } }
    { char == $c } { ~looper !? { |l| l.clear } }
    { char == $n } { ~looper !? { |l| l.recordNextLoop } }
    { char == $a } { ~looper !? { |l| l.nextReading } }
    { char == $e } { ~doExport.value };
};

// ---- The loop position ----------------------------------------------------------------
~guiPositionHz = 20;      // polls (and repaints) per second
~guiReadingShown = nil;   // [pending reading, index, loops left] last painted
~guiLoopPos    = nil;     // last Looper.loopPositionAt result
~guiLoopPhase  = nil;     // last raw phase, seconds; nil = no loop playing
~guiLoopDirty  = false;
~guiLoopKey    = nil;     // what the last repaint was of: [phase, state, length, take, break]

// What the readings add to the take: a countdown while one is armed, the
// reading in force when it is not the analyser's own, or the runner-up when
// the analyser's margin was narrow — under a tenth of a point the answer is
// right one time in three and the runner-up nearly as often
// (docs/dev/meter-perception.md), which is exactly when the footswitch is wanted.
~guiReadingSuffix = { |l|
    var pend = l.pendingReading;
    var n = l.readingCount;
    var loops, up;
    case
        { pend.notNil } {
            loops = ((pend[\at] - SystemClock.seconds) / l.loopDuration.max(1e-6))
                .ceil.asInteger.max(1);
            "  →  " ++ Looper.prReadingString(pend[\result]) ++ " · lands in "
                ++ loops ++ " loop" ++ (if(loops > 1) { "s" } { "" })
        }
        { l.readingIndex > 0 } { " · reading " ++ (l.readingIndex + 1) ++ "/" ++ n }
        { (l.readingMargin ? 1) < 0.1 } {
            up = l.runnerUp;
            (up !? { " · or " ++ MeterAnalyzer.sigString(up)
                ++ " @ " ++ (up[\bpm] ? 0).round(0.1) ++ "?" }) ? ""
        }
        { "" }
};

// The take in full, one line: what the analyser decided about the loop now
// playing. The strip's tooltip, and the post window's words.
~guiTakeString = {
    var l = ~looper;
    var r = l !? { |lp| lp.lastResult };
    if(l.isNil or: { r.isNil }) {
        "no take analysed — record a loop"
    } {
        if(r[\error].notNil) {
            // A length-anchored take HAS a meter, but it is the user's fallback
            // rather than anything detected, and prHasValidMeter rejects it.
            // Saying so is the difference between trusting the number and
            // knowing to re-record — and it is the same condition that makes
            // enableBBCut refuse.
            if(r[\error] == \lengthAnchored) {
                MeterAnalyzer.sigString(r)
                    ++ " @ " ++ (r[\bpm] ? 0).round(0.1) ++ " BPM · "
                    ++ (r[\k] ? 1) ++ " bars · anchored, no beat found (no cutter)"
            } {
                "no meter — " ++ r[\error] ++ " (no cutter)"
            }
        } {
            MeterAnalyzer.sigString(r)
                ++ " @ " ++ (r[\bpm] ? 0).round(0.1) ++ " BPM · "
                ++ (r[\k] ? 1) ++ " bars" ++ (if(r[\from] == \hand) { " by hand" } { "" })
                ++ ~guiReadingSuffix.(l)
        }
    }
};

// ---- AI apps -----------------------------------------------------------------------------
// The footer's Revert while an AI app's change can be taken back, with how
// many; and the Setup view's switch, as the switch stands.
~guiAiTileMake = {
    LooperTile().cycles_(false).font_(~guiMono.(12, true)).fixedHeight_(22).pad_(10)
        .states_([["↶ Revert AI change", ~gt[\ink], nil]]).visible_(false)
        .toolTip_("Takes back the newest change an AI app made: the drums, the synth or the effects\n"
            "as they were before it. Click again for the one before.")
        .action_({ ~remoteRevert !? { |f| f.value } })
};
~guiAiPaint = {
    var n = (~megaRemote !? { |r| r.changeCount }) ? 0, tile = ~guiAiTile;
    if(tile.notNil and: { tile.isClosed.not }) {
        tile.states_([["↶ Revert AI change" ++ (if(n > 1) { " (" ++ n ++ ")" } { "" }), ~gt[\ink], nil]]);
        if(tile.visible != (n > 0)) { tile.visible_(n > 0) };
    };
    ~guiSegSet.(~remoteSeg, (~megaRemote.notNil).binaryValue);
};

// ---- The top bar ----------------------------------------------------------------------
// The server's load, as the CPU tile says it: [average, peak], whole percent,
// or nil while no server answers. Past ~guiCpuWarn the tile turns red: the
// mark MegaSA calls an effect heavy at.
~guiCpuWarn = MegaSA.cpuWarn;
~guiCpuNow = {
    var srv = (~looper !? { |l| l.server }) ?? { Server.default };
    var avg = try { srv.avgCPU }, peak = try { srv.peakCPU };
    if(avg.isNumber and: { peak.isNumber } and: { (try { srv.serverRunning } ? true) != false }) {
        [avg.round(1).asInteger, peak.round(1).asInteger]
    }
};
~guiCpuPaint = {
    var now = ~guiCpuNow.(), tile = ~guiCpuTile, hot;
    if(tile.notNil and: { tile.isClosed.not } and: { now != ~guiCpuPainted }) {
        ~guiCpuPainted = now;
        hot = now.notNil and: { now[1] > ~guiCpuWarn };
        tile.states_([[if(now.isNil) { "CPU –" } { "CPU " ++ now[0] ++ "%" },
            if(hot) { ~gt[\rec] } { ~gt[\ink] }, nil]])
            .sub_(if(now.isNil) { "no server" } { "peak " ++ now[1] ++ "%" });
    };
};

~guiTopBar = {
    var rule = { ~guiRule.(true) };
    var wordmark, wordmarkText, wordmarkRule, rigView, rigRule, bar;
    var theme = LooperTile().states_([["◐", ~gt[\mute], nil]]).font_(~guiMono.(16, true))
        .fixedSize_(Size(52, 52)).toolTip_("Theme: dark or light, for the stage's light · T")
        .action_({ { ~guiThemeToggle.() }.defer(0) });
    var rig = (~routingProfile ? "—").asString.toUpper;
    // The help lines' switch, beside the theme's.
    var help = ~guiHelpTile = LooperTile().cycles_(false).font_(~guiMono.(16, true)).subFont_(~guiMono.(10, false))
        .pad_(2).fixedSize_(Size(52, 52)).toolTip_("Help lines: the sentences that explain a page, shown or hidden · H")
        .action_({ ~guiHelpToggle.() });
    ~guiMidiLamp = StaticText().string_("●").font_(~guiMono.(12, true)).stringColor_(~gt[\mute]);
    ~guiSessionRecTip = nil;
    ~guiSessionRecLabel = LooperTile().cycles_(false).align_(\center).fixedHeight_(52).minWidth_(200)
        .font_(~guiMono.(15, true)).subFont_(~guiMono.(11, false)).pad_(16)
        .action_({ ~looper !? { |l| l.toggleSessionRecording } });
    ~sessionRecButton = ~midiTip.(~guiSessionRecLabel, 'looper.sessionRecording',
        "Write the whole set to disk: what the room heard plus the dry guitar.\n"
            "Independent of the transport — it records the playing that PRODUCES\n"
            "the first loop, which Live's arrangement cannot.\n"
            "This does NOT arm Live: its arrangement record is a separate switch,\n"
            "because it cannot start until the transport does.");
    ~guiTabButtons = IdentityDictionary.new;
    ~guiTabCompact = false;
    // What the bar gives up when the window is too narrow for all of it, first
    // the wordmark, then the rig's name: ~guiTopBarFit hides them in that order
    // and brings them back. The tabs, the theme, the MIDI map and the SET REC
    // tile stay: the last says a set is being written, so it is never hidden.
    // The Möbius loop, then the name: 190 together. A narrow window takes
    // the name away and the loop stays. With SA's six tabs that is already so
    // at the 1440 the bar was laid out for (the Synth's tab took the name's
    // place); a wider screen has both.
    ~guiLogo = UserView().fixedSize_(Size(56, 52)).acceptsMouse_(false).drawFunc_({ |v| ~guiLogoPaint.(v) });
    wordmarkText = ~guiMonoText.("MEGALOOPER", 15, ~gt[\ink]).align_(\left).fixedWidth_(116);
    wordmark = View().layout_(HLayout(~guiLogo, wordmarkText).margins_([6, 0, 4, 0]).spacing_(8));
    wordmarkRule = rule.();
    // The server's load, on every view: its average, its peak under it.
    // 80 wide: what the bar has free between the tabs and the theme at the
    // 1440 it is laid out for, so the wordmark stays.
    ~guiCpuTile = LooperTile().cycles_(false).align_(\center).fixedHeight_(52).fixedWidth_(80)
        .font_(~guiMono.(13, true)).subFont_(~guiMono.(11, false)).pad_(4)
        .toolTip_("The audio server's load: its average, and its peak under it. Red past "
            ++ ~guiCpuWarn ++ " %: near 100 % the sound breaks up.");
    ~guiCpuPainted = nil;
    ~guiCpuPaint.();
    // Two lines that say what they are: the rig, and MIDI's lamp ("SA ●" alone
    // read as nothing).
    rigView = View().fixedWidth_(104).toolTip_("The rig in use, and MIDI arriving from it: the lamp lights at each message")
        .layout_(VLayout(
            HLayout(nil, ~guiMonoText.("RIG " ++ rig, 11, ~gt[\mute]), nil).margins_(0),
            HLayout(nil, ~guiMonoText.("MIDI", 11, ~gt[\mute]), ~guiMidiLamp, nil).margins_(0).spacing_(6)
        ).margins_([0, 8, 0, 8]).spacing_(2));
    rigRule = rule.();
    bar = View().background_(~gt[\bg]).fixedHeight_(52).layout_(HLayout(*([
        wordmark,
        wordmarkRule
    ] ++ ~guiViewOrder.reject { |v| v == \calibrate }.collect { |v| [~guiTab.(v), rule.()] }.flatten(1) ++ [
        nil,
        rule.(), ~guiCpuTile,
        rule.(), theme,
        rule.(), help,
        rigRule,
        rigView,
        rule.(),
        ~buildMapButton !? { |f| f.value } ?? { View().fixedWidth_(0) },
        rule.(),
        ~guiSessionRecLabel
    ])).margins_(0).spacing_(0));
    // The widths they take, and the bar's own without them: what the window
    // must give for each to stay (a rule is 1 px).
    ~guiTopBarShed = [
        [wordmarkText, wordmarkText, 124],
        [rigView, rigRule, 105]
    ];
    // (The CPU tile stays with the tabs: it is what a player watches.)
    ~guiTopBarFull = bar.minSizeHint.width;
    ~guiHelpPaint.();
    // What compact tabs would give back, the last thing to go.
    ~guiTopBarTabSave = ~guiTabButtons.keys.sum { |k| ~guiTabWidth.(k, false) - ~guiTabWidth.(k, true) };
    bar
};

// Hide what a window of `width` cannot hold, from the first to give way. The
// window's own width decides, not what is left: a hidden item frees its width
// and a test on that would show it again at once.
~guiTopBarFit = { |width|
    var need = ~guiTopBarFull ? 0, compact;
    ~guiTopBarShed.do { |item|
        var show = width >= need;
        item.keep(2).do { |v| if(v.isClosed.not and: { v.visible != show }) { v.visible_(show) } };
        if(show.not) { need = need - item[2] };
    };
    compact = width < need;
    if(compact != (~guiTabCompact == true)) {
        ~guiTabCompact = compact;
        ~guiTabButtons.keysValuesDo { |k, t| if(t.isClosed.not) { t.fixedWidth_(~guiTabWidth.(k)) } };
        ~guiRefreshTabs.();
    };
};

// The SET REC tile: what the recorder is doing, and the file it writes to,
// on every view. "Recording" with no path on screen is exactly the claim this
// feature must never make without evidence (gui-perform.scd, ~sessionRecString).
~guiSessionRecPaint = {
    var l = ~looper, secs, tile = ~guiSessionRecLabel, on, text, sub, rec, tip;
    if(tile.notNil and: { tile.isClosed.not }) {
        on = l.notNil and: { l.sessionRecording };
        rec = l !? { |lp| lp.sessionRec };
        sub = ~sessionRecShort !? { |f| f.value } ? "";
        if(on) {
            secs = l.sessionElapsed.floor.asInteger;
            text = "● SET REC " ++ (secs div: 60) ++ ":" ++ (secs mod: 60).asString.padLeft(2, "0");
            tile.states_([[text, Color.white, ~gt[\rec]]]);
        } {
            tip = ~midiProgram.('looper.sessionRecording') !? { |n| " · PC " ++ n } ? "";
            tile.states_([["○ Record set" ++ tip, ~gt[\mute], nil]]);
        };
        // The file, cut to the tile from its start (the stamp is the least
        // telling part); in full in the tooltip, with what a set leaves.
        tile.sub_(if(sub.size > 34) { "…" ++ sub.copyToEnd(sub.size - 33) } { sub });
        // What drives it too, as ~midiTip would have said: this tooltip
        // replaces that one. Set only when it changes: this runs 4 times a second.
        tip = (~sessionRecString !? { |f| f.value } ? "") ++ "\n" ++ (~sessionHintString !? { |f| f.value } ? "")
            ++ (~midiWords.('looper.sessionRecording') !? { |w| "\nMIDI: " ++ w } ? "");
        if(tip != ~guiSessionRecTip) { ~guiSessionRecTip = tip; tile.toolTip_(tip) };
        ~guiSessionRecShown = text ? "";
    };
};

// Give each row of columns (~guiSideRows) the width its columns need: each
// column's own minimum, scaled up by its share of the row's stretch, so that
// every one of them gets at least its minimum when the row is exactly as wide.
// ---- The logo ----------------------------------------------------------------------------
// A Möbius loop: a flat ribbon on a lemniscate, crossing itself once, with
// one half-twist, where its width goes through nothing and the side shown
// flips. While the loop plays the twist travels round once a pass: its
// phase, ~guiLogoPhase, follows the playhead (backwards when the loop plays
// in reverse). Stopped, it stands where it was; with no loop it rests at 0.
~guiLogoPhase = 0;
~guiLogoGeom = nil;
// The lemniscate once: its points, their normals (each from its two
// neighbours, so neighbouring pieces meet without a seam), and the pieces'
// order, far first: the lobe through t = pi/2 passes over the one through
// 3pi/2.
~guiLogoGeometry = { |n = 200|
    var at = { |t| var d = 1 + (sin(t) ** 2); [cos(t) / d, (sin(t) * cos(t)) / d] };
    var ts = (0..n).collect { |k| 2pi * k / n };
    var normal = { |t|
        var d = at.(t + 0.001) - at.(t - 0.001), l = d.squared.sum.sqrt.max(1e-9);
        [d[1].neg / l, d[0] / l]
    };
    (t: ts, step: 2pi / n, p: ts.collect(at), n: ts.collect(normal),
        order: (0..n - 1).sort { |x, y| sin(ts[x] + (pi / n)) < sin(ts[y] + (pi / n)) })
};
~guiLogoPaint = { |view|
    var b = view.bounds, scale = ((b.width.min(b.height * 1.9)) - 6) / 2.3;
    var cx = b.width / 2, cy = b.height / 2, w0 = 0.15, ph = ~guiLogoPhase ? 0;
    var ink = ~gt[\ink], dim = ~gt[\bg].blend(~gt[\ink], 0.35);
    var g = ~guiLogoGeom ?? { ~guiLogoGeom = ~guiLogoGeometry.() };
    g[\order].do { |k|
        var d0 = (g[\t][k] - ph).wrap(0, 2pi), d1 = d0 + g[\step];
        var wa = w0 * cos(d0 / 2), wb = w0 * cos(d1 / 2);
        var p0 = g[\p][k], p1 = g[\p][k + 1], n0 = g[\n][k], n1 = g[\n][k + 1];
        var pts = [p0 + (n0 * wa), p1 + (n1 * wb), p1 - (n1 * wb), p0 - (n0 * wa)]
            .collect { |q| Point(cx + (q[0] * scale), cy + (q[1] * scale)) };
        var col = if(cos((d0 + (g[\step] / 2)) / 2) >= 0) { ink } { dim };
        Pen.moveTo(pts[0]);
        pts.drop(1).do { |pt| Pen.lineTo(pt) };
        Pen.lineTo(pts[0]);
        Pen.fillColor = col;
        Pen.strokeColor = col;
        Pen.width = 0.5;
        Pen.fillStroke;
    };
};
// From the position poll: the playhead's place in the loop, as the twist's.
// Repainted only when it moved enough to see.
~guiLogoTurn = {
    var secs = ~guiLoopPhase, dur = (~looper !? { |x| x.loopDuration }) ? 0, ph;
    ph = case
        { dur <= 0 } { 0 }
        { secs.notNil } { 2pi * (secs / dur).wrap(0, 1) }
        { ~guiLogoPhase ? 0 };
    if((ph - (~guiLogoPhase ? 0)).abs > 0.01) {
        ~guiLogoPhase = ph;
        ~guiLogo !? { |v| if(v.isClosed.not) { v.refresh } };
    };
};

// The help switch: "?" in ink while the lines show, faded with "off" under it.
~guiHelpPaint = {
    ~guiHelpTile !? { |t|
        if(t.isClosed.not) {
            if(~guiHelpShown != false) { t.states_([["?", ~gt[\ink], nil]]).sub_(nil) }
            { t.states_([["?", ~gt[\mute], nil]]).sub_("off") };
        };
    };
};

~guiSideRowsFit = {
    ~guiSideRows.do { |row|
        var canvas = row[0], cols = row[1];
        var total = cols.sum { |c| c[1] };
        if(canvas.isClosed.not) {
            canvas.minWidth_((cols.collect { |c| c[0].minSizeHint.width * total / c[1] }.maxItem
                + (cols.size - 1)).ceil)
        };
    };
};

// ---- The window ---------------------------------------------------------------------------
// `show` false builds the window without showing it: the headless checks
// (check-gui-maptags.scd) read its views, and must not take the screen.
~buildGuiWindow = { |show = true|
    var topBar, gen, views, viewsHolder, footer, holder, scroll, row, sideRow;
    var winRect = Rect(0, 0, 1440, 900);
    // A rebuild (the theme) opens where the player had put the window.
    var oldBounds = ~guiWindow !? { |w| if(w.isClosed.not) { w.bounds } };

    // Qt runs a window's onClose after close has returned, by which time
    // the new panes below exist, and the old window's teardowns would undo
    // their wiring. So the old window is torn down here, and loses its onClose.
    ~guiWindow !? { |w|
        if(w.isClosed.not) {
            w.onClose = nil;
            ~guiTeardowns.keysValuesDo { |k, f| f.value };
            w.close;
        };
    };
    ~guiGen = ~guiGen + 1;
    gen = ~guiGen;
    ~guiThemeSet.(~guiThemeName);
    // Before the stack and the tabs, which are both built from them.
    ~guiPaneOrder = ~guiPaneOrderFor.(~rp !? { |r| r[\sa] == true } ? false);
    ~guiViewOrder = ~guiViewOrderFor.(~rp !? { |r| r[\sa] == true } ? false);
    if(~guiViewOrder.includes(~guiView).not) { ~guiView = \perform };
    // A holder from an earlier window whose rig had a pane this one lacks
    // would otherwise outlive it: rebuilds would still land in it.
    ~guiPaneHolders = IdentityDictionary.new;
    ~guiPaneOrder.do { |k|
        ~guiPaneHolders[k] = View().background_(~gt[\bg]).layout_(VLayout().margins_(0).spacing_(0));
    };

    // ---- The views ----------------------------------------------------------------------
    // Each pane lives in a ScrollView, so the tallest of them still works on a
    // smaller screen and simply expands on a large display.
    //
    // hasHorizontalScroller_(false) is not a preference. A wrapping
    // StaticText's height depends on its width; inside a scroll area an
    // appearing vertical scrollbar changes that width, which changes the
    // required height, which can change whether the scrollbar is needed.
    // Pinning the canvas to the viewport width ends the argument.
    scroll = { |key| ~guiScroll.(~guiPaneHolders[key]) };
    // A view of columns side by side. Each column scrolls up and down on its own
    // and is pinned to its width, so a window narrower than they need would
    // cut the right-hand ones off with no way to reach them. The row's canvas is
    // given the width they need once the panes are built (~guiSideRowsFit), and
    // a narrower window scrolls sideways. `cols`: [content view, stretch].
    ~guiSideRows = List.new;
    sideRow = { |cols|
        var canvas = View().background_(~gt[\bg]).layout_(HLayout(*cols.collect { |c, i|
            [[~guiScroll.(c[0]), stretch: c[1]]] ++ if(i < (cols.size - 1)) { [~guiRule.(true)] } { [] }
        }.flatten(1)).margins_(0).spacing_(0));
        ~guiSideRows.add([canvas, cols]);
        ScrollView().hasBorder_(false).hasVerticalScroller_(false).background_(~gt[\bg]).canvas_(canvas)
    };
    views = ~guiViewOrder.collect { |v|
        switch(v,
            \perform, { View().layout_(VLayout(scroll.(\perform)).margins_(0).spacing_(0)) },
            \sound, { View().layout_(VLayout(sideRow.([
                [~guiPaneHolders[\cutter], 115], [~guiPaneHolders[\grains], 100]
            ])).margins_(0).spacing_(0)) },
            // The effects and the drums each on a view of their own,
            // scrolling: together the drums had too little height to edit.
            \fx, { View().layout_(VLayout(scroll.(\effects)).margins_(0).spacing_(0)) },
            \drums, { View().layout_(VLayout(scroll.(\drums)).margins_(0).spacing_(0)) },
            \synth, { View().layout_(VLayout(scroll.(\synth)).margins_(0).spacing_(0)) },
            // The third column scrolls too, though it fits: a view's minimum
            // height must stay small. Qt can count a view's minimum against the
            // band of the view before it while views switch fast, and the
            // window grows past the screen and never shrinks.
            \setup, { View().layout_(VLayout(sideRow.([
                [~guiPaneHolders[\analysis], 110],
                [~guiPaneHolders[\rig], 100],
                [View().background_(~gt[\bg]).layout_(VLayout(
                    ~buildCalibrateSummary !? { |f| f.value } ?? { View() },
                    ~guiRule.(),
                    [~buildMidiMonitorPanel.(), stretch: 1]
                ).margins_(0).spacing_(0)), 90]
            ])).margins_(0).spacing_(0)) },
            \calibrate, { View().layout_(VLayout(scroll.(\calibrate)).margins_(0).spacing_(0)) }
        )
    };
    // Mode 0 (\stackOne) hides the views that are not current, and it is left
    // at Qt's default deliberately. In \stackAll every view stays
    // visible-but-behind, where a TextField on a view you cannot see can take
    // keyboard focus and eat every shortcut while looking like nothing is
    // wrong.
    ~guiViews = views;
    ~guiStack = StackLayout(*views);
    viewsHolder = View().layout_(~guiStack);

    // ---- The status band and the strip ---------------------------------------------------
    ~statusBand = ~buildStatusBand.();
    ~statusStrip = ~buildStatusStrip.();

    // ---- The footer ----------------------------------------------------------------------
    ~keyHintText = ~guiMonoText.(~keyHintString, 12, ~gt[\mute], true);
    // An explicit minimum, or the line that doesn't wrap asks for all of itself and,
    // with a long status beside it, widens the window past the screen: the
    // keys give way (clipped at the right), the status doesn't.
    ~keyHintText.minWidth_(10);
    ~keyHintText.setProperty(\wordWrap, false);
    ~guiFooterStatus = LooperTile().cycles_(false).font_(~guiMono.(12, true)).fixedHeight_(22).pad_(10)
        .states_([[""]]);
    ~guiFooterPainted = nil;
    // Revert, beside the line that says what an AI app changed.
    ~guiAiTile = ~guiAiTileMake.();
    footer = View().background_(~gt[\bg]).fixedHeight_(32).layout_(HLayout(
        [~keyHintText, stretch: 1], ~guiFooterStatus, ~guiAiTile
    ).margins_([24, 0, 24, 0]).spacing_(20));

    topBar = ~guiTopBar.();

    // ---- Window ---------------------------------------------------------------------------
    ~guiWindow = Window("megalooper", oldBounds ?? { ~fitOnScreen.(winRect.moveTo(0, 0)) })
        .background_(~gt[\bg]);
    ~guiWindow.view.palette_(~guiPalette.());
    // The whole window sits in one scroll area. Its canvas is as wide as the
    // window, or as the top bar and bands need if that is more, so a window
    // narrower than the layout (a tile, a small laptop) scrolls sideways
    // instead of cutting the right-hand end off. The panes below keep their own
    // scrolling and their pinned width (see ~guiScroll).
    ~guiWindow.layout_(VLayout(
        ScrollView().hasBorder_(false).background_(~gt[\bg]).canvas_(View().background_(~gt[\bg]).layout_(VLayout(
            topBar,
            ~guiRule.(),
            ~statusBand,
            ~statusStrip,
            [viewsHolder, stretch: 1],
            ~buildMapBar !? { |f| f.value } ?? { View().fixedHeight_(0) },
            ~guiRule.(),
            footer
        ).margins_(0).spacing_(0)))
    ).margins_(0).spacing_(0));

    // The top bar gives up its wordmark and the rig's name as the window narrows,
    // and the status band and strip take narrower columns.
    ~guiWindow.view.onResize = { var w = ~guiWindow.view.bounds.width; ~guiTopBarFit.(w); ~guiStatusFit.(w); ~performFit.(w) };

    // Panes are built AFTER the holders exist, and each one swaps itself in.
    ~buildPerformPane.();
    ~buildBBCutPane.();
    ~buildGranularPane.();
    if(~guiPaneOrder.includes(\effects)) { ~buildEffectsPane !? { |f| f.value } };
    if(~guiPaneOrder.includes(\drums)) { ~buildDrumsPane !? { |f| f.value } };
    if(~guiPaneOrder.includes(\synth)) { ~buildSynthPane !? { |f| f.value } };
    ~buildAnalysisPane.();
    ~buildRigPane.();
    ~buildCalibratePane.();
    // A MIDI map that could not be loaded says so from the first moment.
    ~guiHintRowRefresh.();
    // Once the panes exist: the fits act on what they built.
    ~guiSideRowsFit.();
    ~guiWindow.view.onResize.value;

    if(show != false) {
        ~guiWindow.front;

        // One deferred focus grab for the whole window. The panes each used to
        // do their own after their own .front; in one window that would be five
        // deferred grabs racing, with the last to land winning.
        { ~guiWindow.view.focus(true) }.defer(0.1);
    };

    ~guiWindow.view.keyDownAction = { |view, char, modifiers, unicode, keycode, key|
        ~guiKeyDown.(char, modifiers, key)
    };

    // Everything a pane registered as needing undoing. Keyed, so a re-load
    // replaces an entry rather than stacking a second copy, and fired here
    // rather than from five separate onClose hooks.
    ~guiWindow.onClose_({
        ~guiTeardowns.keysValuesDo { |k, f| f.value };
    });

    // ---- The CPU tile, once a second, for as long as this window lives ----------------
    AppClock.sched(0, {
        if(gen != ~guiGen or: { ~guiWindow.isNil } or: { ~guiWindow.isClosed }) { nil } { ~guiCpuPaint.(); 1 }
    });

    // ---- Position poll ----------------------------------------------------------------
    // queryLoopPhase is a control-bus round trip, so its answer arrives on the
    // OSC thread and may touch only data. The repaint happens here, one tick
    // later — 50 ms behind at 20 Hz, which is under the eye's threshold for a
    // bar that takes a second or two to cross.
    ~guiPositionRoutine = AppClock.sched(0, {
        if(gen != ~guiGen
            or: { ~guiWindow.isNil } or: { ~guiWindow.isClosed }) {
            nil   // retired: unschedule
        } {
            ~looper !? { |l|
                l.queryLoopPhase { |secs|
                    // What the grid and the words are painted from: unchanged
                    // (no loop, a stopped one), nothing is repainted. A take
                    // being recorded counts its seconds with no phase.
                    var key = [secs, l.state, l.loopDuration, l.lastResult.identityHash, l.onBreak];
                    if((key != ~guiLoopKey) or: { l.state == \recording }) {
                        ~guiLoopKey = key;
                        ~guiLoopDirty = true;
                    };
                    ~guiLoopPhase = secs;
                    // Folded from 0 rather than from nil when there is no
                    // playhead, so the GRID still resolves: a stopped loop
                    // should still show how long it is and how it divides.
                    // The fill and the playhead are drawn only when
                    // ~guiLoopPhase is real, so this cannot fake a position.
                    ~guiLoopPos = Looper.loopPositionAt(
                        secs ? 0, l.lastResult, l.loopDuration);
                };
            };
            if(~guiLoopDirty) {
                ~guiLoopDirty = false;
                ~statusRepaintGrids !? { |f| f.value };
            };
            ~guiLogoTurn.();
            // The take is repainted here rather than from a notification
            // because there is no single event that means "the analysis result
            // changed": it lands from stopRecordStartPlay, from an overdub
            // detection, and from a chain handoff. Comparing the Event identity
            // costs nothing and cannot miss a path.
            ~looper !? { |l|
                // The readings add three things the identity test cannot see:
                // a reading armed or landed, and the loops left until it lands,
                // which changes once per pass.
                var readingKey = [l.pendingReading, l.readingIndex,
                    l.pendingReading !? { |p|
                        ((p[\at] - SystemClock.seconds) / l.loopDuration.max(1e-6)).ceil }];
                if((l.lastResult !== ~guiLastResultShown)
                    or: { readingKey != ~guiReadingShown }) {
                    ~guiLastResultShown = l.lastResult;
                    ~guiReadingShown = readingKey;
                    ~statusPaintTake !? { |f| f.value };
                };
            };
            // Four times a second: the set-recording clock, the state block's
            // counting lines (a break's countdown, the recording's seconds,
            // the dissolve) and the Perform tiles that count. It must never
            // depend on the view shown.
            ~guiSlowTick = ((~guiSlowTick ? 0) + 1) % 5;
            if(~guiSlowTick == 0) {
                ~guiSessionRecPaint.();
                ~statusPaintCounting !? { |f| f.value };
                ~guiFooterRefresh.();
                // Perform's columns and tiles, from the model: most change on a
                // notification, but some have none (what Undo would drop, a
                // multiplied loop's length). A tile, a bar or a label left as
                // it is costs nothing, so this only catches what moved.
                if(~guiView == \perform) { ~performRefreshAll !? { |f| f.value } };
            };
            // The rig's MIDI lamp: lit for a moment after a message arrives.
            if((Main.elapsedTime - (~guiMidiSeenAt ? -1)) < 0.15) {
                if(~guiMidiLit != true) { ~guiMidiLit = true; ~guiMidiLamp !? { |t| t.stringColor_(~gt[\play]) } };
            } {
                if(~guiMidiLit == true) { ~guiMidiLit = false; ~guiMidiLamp !? { |t| t.stringColor_(~gt[\mute]) } };
            };
            // The onset lamp: decay one step, and repaint only when the
            // picture actually differs. Between hits on a silent input that is
            // two float comparisons a tick and no Qt traffic at all. Driven
            // from here rather than from ~analysisPush because the feed runs on
            // the OSC thread, which must never touch a view.
            if(~analysisFlash.notNil) {
                if(~analysisFlash > 0.01) {
                    ~analysisFlash = ~analysisFlash * (~analysisFlashDecay ? 0.55);
                } {
                    ~analysisFlash = 0;
                };
                if(~analysisFlash != (~guiOnsetFlashShown ? 0)) {
                    ~guiOnsetFlashShown = ~analysisFlash;
                    ~statusRepaintLamps !? { |f| f.value };
                };
            };
            // The level meter is always live — it is the answer to "is anything
            // reaching the machine", which must not depend on the view.
            // Repainted only when the bar would actually move: this routine
            // runs at 20 Hz and the feed arrives at 15. 0.002 is below one
            // pixel on a 300 px bar.
            if((((~analysisLevel ? 0) - (~guiLevelShown ? 0)).abs) > 0.002) {
                ~guiLevelShown = (~analysisLevel ? 0);
                ~statusRepaintMeters !? { |f| f.value };
            };
            ~guiPositionHz.reciprocal
        };
    });

    ~guiSelectView.(~guiView);
    ~statusRefreshAll.();
    ~guiSessionRecPaint.();
    ~guiRefreshTabs.();
    // A window built again (the theme) shows Revert if there is one to do.
    ~guiAiPaint.();
    ~guiWindow
};
)
