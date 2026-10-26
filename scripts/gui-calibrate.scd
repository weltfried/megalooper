// megalooper — Calibrate: the wizard that turns four by-ear numbers into four
// measured ones, and its summary on the Setup view.
//
// Loaded by boot.scd; defines only, runs nothing. Entry points:
//   ~buildCalibratePane    — builds the wizard (view 6) against the EXISTING
//                            ~looper and swaps it into the shell's holder.
//                            Safe to re-run.
//   ~buildCalibrateSummary — the Setup view's block: the steps, how many are
//                            done, and the way into the wizard.
//
// It is a view rather than its own window because megalooper is one window,
// and the reason for that rule holds here too: a wizard you have to go and
// find is a wizard nobody runs. It is reached from Setup (its summary, or key
// 5) and goes back there (Esc) because it is the one thing you touch before a
// gig rather than during one.
//
// The wizard reads left to right: every step, with where you are and what is
// answered; the step you are on — why it matters, what it needs in the room,
// what to do, and the buttons; and this rig's numbers, with the line to copy
// into the profile.
//
// This file draws and nothing else. The steps, the order, what each one needs
// in the room and what to do with the answer all live in LooperCalibrator,
// which is covered by scripts/tests/test-calibrator.scd; the measuring lives in
// scripts/calibrate-measure.scd, which needs the rig. So everything here paints
// from the model and never from its own widgets — the same rule the status
// band follows, and for the same reason: a step that REFUSED must not leave a
// tick beside it.
(
~calMarks = (
    done:    "✓",
    failed:  "✕",
    skipped: "–",
    running: "▶",
    pending: nil
);

// The mark's square: filled \play when done, \rec when it failed, \ink for the
// step you are on, \panel2 for the rest.
~calMarkLook = { |st, current|
    case
    { st == \done } { [~gt[\play], ~gt[\onacc]] }
    { st == \failed } { [~gt[\rec], Color.white] }
    { current } { [~gt[\ink], ~gt[\bg]] }
    { [~gt[\panel2], ~gt[\mute]] }
};

// A need in two words, for its chip; the whole sentence is its tooltip.
~calNeedShort = (guitar: "instrument", cable: "cable", noLoop: "no loop", live: "Live", loop: "loop",
    drumrack: "drum rack", cueOut: "cue out", quietReturn: "return muted", return: "return");
// Whether the looper can say a need is met: a loop playing or not. Nil where
// only the room knows.
// Whether this rig has Live: every profile but those that say live: false
// (SA's and standalone). Without Live the wizard is LooperCalibrator's
// noLiveSteps, and what it finds is kept for the rig in your megalooper folder.
~calLive = { (~rp !? { |r| r[\live] }) != false };

~calNeedMet = { |key|
    var playing = ~looper !? { |l| (l.state == \playing) or: { l.state == \overdubbing } };
    case
    { key == \live } { ~calLive.() }
    { playing.isNil } { nil }
    { key == \loop } { playing }
    { key == \noLoop } { playing.not }
    { nil }
};

// The calibrator is created once and kept, so switching views mid-wizard does
// not throw away what has been measured. The measuring script is loaded on
// demand rather than by boot.scd: it is only ever wanted here, and loading it
// adds no SynthDefs until a measurement actually asks for them.
~calibrateEnsure = {
    var scripts = ~megalooperScripts ? (Looper.repoRoot +/+ "scripts");
    if(~calibrator.isNil) {
        ~calibrator = LooperCalibrator.new(~looper, ~calLive.());
        if(~calLive.().not) {
            ~calibrator.keptPath = LooperCalibrator.keptPathIn(~userRoot ?? { MegaFiles.userRoot });
            // Under the audio settings, the setup (its devices and buffer).
            ~calibrator.rig = ~rp !? { |r| r[\calibrationKey] } ?? { ~routingProfile };
        };
    };
    if(~calRegisterAll.isNil) { (scripts +/+ "calibrate-measure.scd").load };
    ~calRegisterAll !? { |f| f.value(~calibrator) };
    ~calibrator
};

// What this rig keeps, as a line: the values and when they were kept. Under
// the audio settings it is the setup's (its devices and buffer), and with
// nothing kept for it, what it starts from instead.
~calKeptLine = { |c|
    var e = c !? { c.kept }, stamp, setup = ~rp !? { |r| r[\calibrationKey] }, from;
    if(e.isNil) {
        if(setup.isNil) { "Nothing kept yet: this rig starts with its profile's numbers." } {
            from = c !? { |x| x.keptPath } !? { |p| LooperCalibrator.keptKeyOf(p, (~rp[\calibrationKeys] ? []).drop(1)) };
            "Nothing kept yet for " ++ setup ++ ": it starts with " ++ (case
                { from.notNil } { "the numbers kept for " ++ from }
                { ~rp[\inheritRig].notNil } { "your rig " ++ ~rp[\inheritRig] ++ "'s numbers" }
                { "saSystem's numbers" }) ++ "."
        }
    } {
        stamp = e[\savedAt] !? { |t| if(t.size >= 11) { "20" ++ t[0..1] ++ "-" ++ t[2..3] ++ "-" ++ t[4..5] ++ " " ++ t[7..8] ++ ":" ++ t[9..10] } { t } };
        (if(setup.notNil) { "Every start on " ++ setup ++ " begins with: " } { "Every start begins with: " }) ++ [
            e[\onsetThreshold] !? { |v| "onset threshold " ++ v.round(0.01) },
            e[\latencyMs] !? { |v| "overdub latency " ++ v.round(0.1) ++ " ms" }
        ].reject(_.isNil).join(", ") ++ (stamp !? { |t| ". Kept " ++ t ++ "." } ? ".")
    }
};
// Forget what this rig keeps: back to its profile's numbers, now and at the
// next start.
~calForget = {
    ~calibrator !? { |c| c.forget };
    ~looper !? { |l| ~rp !? { |r|
        l.latencyMs = r[\latencyMs] ? 0;
        l.onsetThreshold = r[\onsetThreshold] ? 0.5;
    } };
    ~calibrateRefresh.();
};

// One step's row: its mark, its title, "optional". Clicking it goes there.
~calStepRow = { |i, step, big|
    LooperTile().cycles_(false).align_(\left).pad_(if(big) { 64 } { 34 })
        .font_(~guiSans.(if(big) { 16 } { 14 }))
        .fixedHeight_(if(big) { 52 } { 26 })
        .sw_(if(big and: { step[\optional] == true }) { "optional" } { nil })
        .swFont_(~guiMono.(11, true))
        .action_({ ~calibrator !? { |c| c.goTo(i) }; ~calibrateRefresh.() })
};
// The mark: a square drawn under the row's label.
~calStepMark = { |row, mark, look, big|
    var size = if(big) { 26 } { 22 }, x = if(big) { 22 } { 0 };
    row.drawFunc_({ |v|
        var b = v.bounds;
        row.prDraw;
        Pen.fillColor = look[0];
        Pen.addRect(Rect(x, (b.height - size) / 2, size, size));
        Pen.fill;
        mark !? { |m| Pen.stringCenteredIn(m, Rect(x, (b.height - size) / 2, size, size),
            ~guiMono.(if(big) { 13 } { 12 }, true), look[1]) };
    });
    row.refresh;
};

// ---- The summary, on Setup ---------------------------------------------------------
~buildCalibrateSummary = {
    var cal = ~calibrateEnsure.();
    ~calSummaryRows = cal.steps.collect { |s, i| ~calStepRow.(i, s, false) };
    ~calSummaryProgress = ~guiMonoText.("", 12, ~gt[\mute]).align_(\right);
    View().background_(~gt[\bg]).layout_(VLayout(*([
        HLayout(~guiTitle.("Calibrate", 24), nil, ~calSummaryProgress).margins_(0)
    ] ++ ~calSummaryRows ++ [
        LooperTile().states_([["Open the wizard", ~gt[\bg], ~gt[\ink]]]).cycles_(false).align_(\left)
            .font_(~guiSans.(15, true)).fixedHeight_(40).sw_(~guiViewNumbers[\calibrate].asString).swFont_(~guiMono.(12, true))
            .toolTip_("The steps one at a time: why, what it needs, what to do, and the numbers. Key 6.")
            .action_({ ~guiSelectView.(\calibrate) })
    ])).margins_([22, 20, 22, 16]).spacing_(9))
};

// ---- The wizard ----------------------------------------------------------------------
~buildCalibratePane = {
    var pane = View().background_(~gt[\bg]);
    var cal  = ~calibrateEnsure.();
    var button = { |label, action, primary = false|
        LooperTile().states_([[label, if(primary) { ~gt[\bg] } { ~gt[\ink] }, if(primary) { ~gt[\ink] } { nil }]])
            .cycles_(false).border_(if(primary) { nil } { ~gt[\line] }).font_(~guiSans.(16, primary))
            .fixedHeight_(48).pad_(22).action_(action)
    };
    var left, centre, right;

    // No generation counter here, deliberately. ~guiGen belongs to the SHELL —
    // it guards the position/level repaint routine — and a pane builder that
    // bumped it would stop that routine dead at boot, because this pane is
    // built from inside ~buildGuiWindow. This pane has no timer of its own to
    // protect: it repaints on notifications, and the controller below is
    // removed on rebuild and on close, so nothing can fire into dead widgets.

    // One row per step, always visible. Seeing the whole procedure — and
    // which parts of it are answered — is most of what makes this legible to
    // somebody who has never calibrated a rig before.
    ~calStepRows = cal.steps.collect { |s, i| ~calStepRow.(i, s, true) };
    ~calResetButton = LooperTile().states_([["Start over", ~gt[\mute], nil]]).cycles_(false).align_(\left)
        .font_(~guiSans.(14)).fixedHeight_(48).pad_(22)
        .action_({ ~calibrator !? { |c| c.reset }; ~calibrateRefresh.() });
    left = View().fixedWidth_(330).layout_(VLayout(*([
        View().layout_(HLayout(~guiTitle.("Calibrate", 24), nil,
            LooperTile().states_([["Esc · back", ~gt[\mute], nil]]).cycles_(false).font_(~guiMono.(12, true))
                .fixedSize_(Size(96, 26)).action_({ ~guiSetupShow !? { |f| f.value(\rig) } ?? { ~guiSelectView.(\setup) } })
        ).margins_([22, 20, 22, 10]))
    ] ++ ~calStepRows.collect { |r| [~guiRule.(), r] }.flatten(1) ++ [
        ~guiRule.(), nil, ~guiRule.(), ~calResetButton
    ])).margins_(0).spacing_(0));

    // ---- the step you are on --------------------------------------------------------
    ~calStepLine = ~guiCaption.("");
    ~calTitleLabel = ~guiText.("", 44, nil, true);
    ~calWhyView = ~guiText.("", 18, nil, false);
    ~calNeedsHolder = View().layout_(HLayout().margins_(0));
    ~calTodoHolder = View().layout_(VLayout().margins_(0));
    // Which input this step listens to: per step, and shown only for the steps
    // that record something, because the two of them want different pairs:
    // the metronome arrives wherever Live's Cue Out points, the drum rack
    // wherever its track is routed.
    ~calListenBox = NumberBox()
        .canFocus_(false)
        .clipLo_(0).clipHi_(255).step_(1).scroll_step_(1).decimals_(0)
        .font_(~guiMono.(14, true)).background_(~gt[\panel]).normalColor_(~gt[\ink]).align_(\center)
        .fixedSize_(Size(56, 30))
        .toolTip_("The SC input channel this step records. SC channel N is device channel N+1, "
            "so Cue Out on 5/6 is channel 4.")
        .action_({ |nb| ~calibrator !? { |c| c.setListenChannel(nil, nb.value) } });
    ~calScanButton = LooperTile().states_([["Scan inputs", ~gt[\ink], nil]]).border_(~gt[\line]).cycles_(false)
        .font_(~guiSans.(14)).fixedSize_(Size(120, 30))
        .toolTip_("Print the peak level on every input channel for four seconds, so you can see "
            "which one carries the signal.")
        .action_({ ~calScanInputs !? { |f| f.value } });
    ~calListenView = View().layout_(HLayout(~guiText.("Listen on channel", 15, ~gt[\mute]), ~calListenBox,
        ~calScanButton, nil).margins_(0).spacing_(12));
    ~calBackButton = button.("← Back", { ~calibrator !? { |c| c.back }; ~calibrateRefresh.() });
    ~calRunButton = button.("Measure", {
        ~calibrator !? { |c|
            if(c.current[\manual] == true) {
                c.confirm;
                ~calibrateRefresh.();
            } {
                // The refresh comes from the controller below, so a
                // measurement that takes ten seconds still repaints when it
                // lands rather than when it was started.
                c.run;
            };
        };
    }, true);
    ~calApplyButton = button.("Apply", { ~calibrator !? { |c| c.apply }; ~calibrateRefresh.() })
        .toolTip_("Write the measured value onto the running looper, so you can hear it before you believe it.");
    // Without Live: the value as it stands, set by ear on the Setup view,
    // kept for the rig (confirm).
    ~calKeepButton = button.("Start with this", { ~calibrator !? { |c| c.confirm }; ~calibrateRefresh.() })
        .toolTip_("Keep the value as it is now, set by ear on the Setup view: the next start begins with it.");
    ~calSkipButton = button.("Skip", { ~calibrator !? { |c| c.skip }; ~calibrateRefresh.() });
    ~calNextButton = button.("Next →", { ~calibrator !? { |c| c.advance }; ~calibrateRefresh.() })
        .border_(~gt[\ink]).font_(~guiSans.(16, true));
    ~calResultLabel = ~guiMonoText.("", 14, ~gt[\play]);
    ~calWhyNotLabel = ~guiText.("", 14, ~gt[\rec]);
    centre = View().layout_(VLayout(
        ~calStepLine,
        ~calTitleLabel,
        ~calWhyView.maxWidth_(720),
        ~calNeedsHolder,
        ~guiCaption.("WHAT TO DO"),
        ~calTodoHolder.maxWidth_(760),
        ~calListenView,
        nil,
        ~calResultLabel,
        ~calWhyNotLabel,
        HLayout(~calBackButton, ~calRunButton, ~calApplyButton, ~calKeepButton, ~calSkipButton, nil, ~calNextButton)
            .margins_(0).spacing_(10)
    ).margins_([40, 30, 40, 30]).spacing_(18));

    // ---- this rig's numbers ------------------------------------------------------------
    ~calValueRows = cal.calibratedFields.collect { |f|
        (field: f, key: ~guiText.("", 15, ~gt[\mute]), value: ~guiMonoText.("", 20, ~gt[\ink]).align_(\right))
    };
    ~calProfileView = TextView()
        .editable_(false)
        .canFocus_(false)
        .hasVerticalScroller_(false)
        .fixedHeight_(96)
        .background_(~gt[\panel])
        .font_(~guiMono.(12, false));
    ~calKeptText = nil;
    right = View().fixedWidth_(360).layout_(VLayout(*([
        ~guiCaption.("THIS RIG · " ++ (~routingProfile ? "—").asString)
    ] ++ ~calValueRows.collect { |r|
        View().layout_(VLayout(HLayout(r[\key], nil, r[\value]).margins_(0), ~guiRule.()).margins_(0).spacing_(10))
    } ++ if(cal.live) { [
        ~guiText.("Measured values apply when you press Apply. Blue means it was measured this session "
            "and still needs writing back into the profile.", 13, ~gt[\mute]),
        nil,
        ~guiCaption.("FOR ~routingProfiles"),
        ~calProfileView
    ] } {
        ~calProfileView = nil;
        [
            ~guiHelp.(~guiText.("A value is used when you press Apply, Done or Start with this, and kept for this rig "
                "in your megalooper folder. Blue means it was measured this session.", 13, ~gt[\mute])),
            nil,
            ~guiCaption.("KEPT FOR THIS RIG"),
            ~calKeptText = ~guiText.("", 14, ~gt[\ink]),
            LooperTile().states_([["Forget", ~gt[\ink], nil]]).border_(~gt[\line]).cycles_(false)
                .font_(~guiSans.(14)).fixedSize_(Size(110, 32))
                .toolTip_("Forget what this rig keeps: it goes back to its profile's numbers, now and at the next start.")
                .action_({ ~calForget.() })
        ]
    })).margins_([22, 24, 22, 24]).spacing_(14));

    pane.layout_(HLayout(left, ~guiRule.(true), [centre, stretch: 1], ~guiRule.(true), right)
        .margins_(0).spacing_(0));

    // Async results land from a Routine, so the repaint is deferred rather than
    // called from the button that started it. Keyed teardown so re-loading this
    // file replaces the controller instead of stacking a second one.
    ~calController !? { |c| c.remove };
    ~calRepaint = {
        // A repaint already deferred when the window closed would otherwise
        // land on destroyed widgets. The refresh itself stays unguarded, so it
        // is still callable with no window at all — which is how check.scd
        // proves it is safe before its pane exists.
        { if(~guiWindow.notNil and: { ~guiWindow.isClosed.not }) {
            ~calibrateRefresh.()
        } }.defer
    };
    ~calController = SimpleController(cal)
        .put(\status,  { ~calRepaint.() })
        .put(\step,    { ~calRepaint.() })
        .put(\applied, { ~calRepaint.() })
        .put(\reset,   { ~calRepaint.() })
        .put(\kept,    { ~calRepaint.() });
    ~guiTeardowns[\calibrate] = { ~calController !? { |c| c.remove }; ~calController = nil };

    ~guiSwapPane.(\calibrate, pane);
    ~calibrateRefresh.();
    ~calibratePane = pane;
    pane
};

// Everything the wizard and the summary show, painted from the calibrator.
// Nil-guarded throughout so it stays callable before the views exist — which
// is how a rebuild, and check.scd, reach this file.
~calibrateRefresh = {
    ~calibrator !? { |c|
        var step    = c.current;
        var key     = c.currentKey;
        var st      = c.statusOf(key);
        var res     = c.resultOf(key);
        var manual  = (step[\manual] == true);
        var running = (st == \running);
        var hasValue = res.notNil and: { res[\ok] == true } and: {
            res[\value].notNil } and: { step[\field].notNil };
        var open = { |v| v.notNil and: { v.isClosed.not } };
        var done = c.steps.count { |s| #[\done, \skipped].includes(c.statusOf(s[\key])) };

        // The whole procedure, with what has been answered: the wizard's rows
        // and the summary's.
        [[~calStepRows, true], [~calSummaryRows, false]].do { |pair|
            pair[0] !? { |rows|
                c.steps.do { |s, i|
                    rows[i] !? { |row|
                        var sst = c.statusOf(s[\key]);
                        var current = i == c.stepIndex;
                        var look = ~calMarkLook.(sst, current);
                        if(open.(row)) {
                            row.states_([[s[\title], if(current or: { sst == \done }) { ~gt[\ink] } { ~gt[\mute] },
                                if(current and: { pair[1] }) { ~gt[\panel] } { nil }]]);
                            ~calStepMark.(row, ~calMarks[sst] ?? { (i + 1).asString }, look, pair[1]);
                        };
                    };
                };
            };
        };
        ~calSummaryProgress !? { |t| if(open.(t)) { t.string_(done.asString ++ " of " ++ c.stepCount ++ " done") } };
        ~guiRefreshTabs !? { |f| f.value };

        ~calStepLine !? { |t|
            if(open.(t)) { t.string_("STEP " ++ (c.stepIndex + 1) ++ " OF " ++ c.stepCount
                ++ (if(step[\optional] == true) { " · OPTIONAL" } { "" })
                ++ (if(LooperCalibrator.runsOn(step, ~calLive.()).not) { " · MEASURES LIVE: NOT ON THIS RIG" } { "" })) };
        };
        ~calTitleLabel !? { |t| if(open.(t)) { t.string_(step[\title]) } };
        ~calWhyView !? { |v| if(open.(v)) { v.string_(step[\why] ? "") } };

        // What it needs in the room: a chip each, ✓ or ✕ where the looper
        // can tell, a plain box where only the room knows.
        // Both lists are one inner view, made anew each time: removing a
        // view takes its layout item with it, but a spring or a row's own
        // layout added to the holder would stay, and pile up a refresh at a time.
        ~calNeedsHolder !? { |h|
            if(open.(h)) {
                h.children.copy.do(_.remove);
                h.layout.add(View().layout_(HLayout(*(
                    LooperCalibrator.needsFor(step, ~calLive.()).collect { |n|
                        var met = ~calNeedMet.(n);
                        var c2 = case { met == true } { ~gt[\play] } { met == false } { ~gt[\rec] } { ~gt[\line] };
                        LooperTile().states_([[(case { met == true } { "✓ " } { met == false } { "✕ " }
                            { "☐ " }) ++ (~calNeedShort[n] ? n.asString), ~gt[\ink], nil]]).cycles_(false)
                            .border_(c2).font_(~guiMono.(13, true)).fixedHeight_(28)
                            .minWidth_((((~calNeedShort[n] ? n.asString).size * 9) + 44))
                            .toolTip_(LooperCalibrator.needLabel(n, ~calLive.()))
                    }
                    ++ (if(LooperCalibrator.needsFor(step, ~calLive.()).isEmpty) {
                        [~guiLabel.("Nothing in the room: this one runs anywhere.", 14)] } { [] })
                    ++ [nil]
                )).margins_(0).spacing_(8)));
            };
        };

        ~calTodoHolder !? { |h|
            if(open.(h)) {
                h.children.copy.do(_.remove);
                h.layout.add(View().layout_(VLayout(*(step[\todo] ? []).collect { |line, i|
                    HLayout(
                        ~guiMonoText.((i + 1).asString.padLeft(2, "0"), 15, ~gt[\mute]).fixedWidth_(34),
                        ~guiText.(line, 16)
                    ).margins_(0).spacing_(8)
                }).margins_(0).spacing_(12)));
            };
        };

        // A manual step has nothing to measure; it asks you to go and do
        // something and then reads back what you did.
        // A step that measures Live cannot run on a rig without it (SA).
        ~calRunButton !? { |b|
            var runs = LooperCalibrator.runsOn(step, ~calLive.());
            if(open.(b)) {
                b.states_([[
                    case
                        { runs.not } { "Not on this rig" }
                        { running } { "Measuring…" }
                        { manual }  { "Done" }
                        { true }    { "Measure" },
                    if(running) { ~gt[\onacc] } { ~gt[\bg] },
                    if(running) { ~gt[\armed] } { ~gt[\ink] }
                ]]);
                b.enabled_(running.not and: { runs });
                b.toolTip_(if(runs) { "" } { "This step measures Live, and this rig has none: skip it. "
                    "On SA its value is the SA profile's own." });
            };
        };
        ~calListenView !? { |v| if(open.(v)) { v.visible_(step[\listens] == true) } };
        ~calListenBox !? { |nb|
            // value_ rather than valueAction_: painting the box must not look
            // like the player just set it.
            if(open.(nb)) { c.listenChannel !? { |ch| nb.value_(ch) } };
        };
        ~calApplyButton !? { |b| if(open.(b)) { b.visible_(hasValue) } };
        ~calKeepButton !? { |b| if(open.(b)) {
            b.visible_(c.keeps and: { step[\field].notNil } and: { manual.not });
            b.enabled_(running.not);
        } };
        ~calSkipButton !? { |b| if(open.(b)) { b.enabled_(running.not) } };
        ~calBackButton !? { |b| if(open.(b)) { b.enabled_(c.stepIndex > 0) } };
        ~calNextButton !? { |b| if(open.(b)) { b.enabled_(c.stepIndex < (c.stepCount - 1)) } };

        ~calResultLabel !? { |t|
            var str = "";
            var col = ~gt[\mute];
            if(open.(t)) {
                if(res.notNil and: { res[\peakDb].notNil }) {
                    // The input level: the loudest hit, good or not.
                    col = if(res[\ok] == true) { ~gt[\play] } { ~gt[\rec] };
                    str = "loudest hit " ++ res[\peakDb] ++ " dBFS";
                } {
                if(res.notNil) {
                    if(res[\ok] == true) {
                        col = ~gt[\play];
                        str = if(res[\value].notNil) {
                            var applied = (step[\field].notNil) and: {
                                (~looper !? { |l| l.perform(step[\field]) })
                                    == res[\value]
                            };
                            (step[\field] ? "").asString ++ " = "
                                ++ res[\value].round(0.1).asString
                                ++ if(res[\spread].notNil) {
                                    "   (spread " ++ res[\spread].round(0.1)
                                        ++ " ms, correlation "
                                        ++ (res[\quality] ? 0).round(0.01) ++ ")"
                                } { "" }
                                ++ if(applied) { "   ✓ applied" }
                                    { "   — press Apply to use it" }
                        } { "done" };
                    } {
                        col = ~gt[\rec];
                        str = "could not measure it";
                    };
                };
                };
                t.string_(str);
                t.stringColor_(col);
            };
        };

        // The refusal in full. This is the useful half of a failed step: every
        // one of them names the precondition that was not met.
        ~calWhyNotLabel !? { |t|
            var notes = res !? { |r| r[\notes] };
            if(open.(t)) {
                t.string_(
                    if(res.notNil and: { res[\ok] != true }) { (res[\why] ? "").asString }
                    { if(notes.notNil) { notes.join("   ") } { "" } });
                t.stringColor_(
                    if(res.notNil and: { res[\ok] != true }) { ~gt[\rec] }
                    { ~gt[\mute] });
            };
        };

        // This rig's numbers: \loop where measured this session, the row of
        // the step you are on in \ink.
        ~calValueRows !? { |rows|
            rows.do { |r|
                var f = r[\field], v = c.valueFor(f);
                var names = (onsetThreshold: "Onset threshold", latencyMs: "Overdub latency",
                    abletonSyncMs: "Live sync", onsetNoteOffsetMs: "Onset note offset",
                    chainRecOffsetMs: "Chain rec offset");
                if(open.(r[\key])) {
                    r[\key].string_(names[f] ? f.asString)
                        .stringColor_(if(step[\field] == f) { ~gt[\ink] } { ~gt[\mute] });
                    r[\value].string_(if(v.isNil) { "—" } {
                        if(f == \onsetThreshold) { v.round(0.01).asString } {
                            (if(v > 0) { "+" } { "" }) ++ v.round(0.1).asString ++ " ms" } })
                        .stringColor_(if(c.wasMeasured(f)) { ~gt[\loop] } { ~gt[\ink] });
                };
            };
        };
        ~calProfileView !? { |v| if(open.(v)) { v.string_(c.profileLine) } };
        ~calKeptText !? { |v| if(open.(v)) { v.string_(~calKeptLine.(c)) } };
    };
};
)
