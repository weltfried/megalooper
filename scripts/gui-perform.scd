// megalooper — the Perform view: what you touch while the loop is running.
//
// Loaded by boot.scd; defines only, runs nothing. Entry point:
//   ~buildPerformPane — builds a fresh Perform pane against the EXISTING
//                       ~looper and swaps it into the shell's holder. Safe to
//                       re-run; it never touches the model, so the recorded
//                       loop survives. Follow with ~wireLooperController.().
//
// The rule for what belongs here: if you would reach for it with an instrument
// in your hands, it is on this view or in the status band above it. Everything
// set up once and then left alone is on Setup; everything dialled in while
// stopped is on Sound, FX or Drums.
//
// Left, a column per LAYER — Loop, Cutter, Grains and, on Megalooper SA,
// Effects, Drums and the Synth — each under a bar in its colour, with its switch, the two
// values worth grabbing, and a line saying what it is doing. A layer that is
// off loses its colour (the switch goes dark and dashed, the bar and the
// values fade), so a glance across the five says what is sounding. A name
// opens the view where the rest of that layer is.
//
// Right, the ACTIONS, each a tile with the key and the footswitch that fire
// it, and a second line saying what it will do now; a tile is lit only while
// what it started is live (Trigger while recording or overdubbing, Break with
// the hatch while the hole is open, Next reading while one is landing, Rec
// next loop while it waits or records, Dissolve while the ending runs). Under
// them the MACROS: master, the arc, and the onset threshold, which is tuned
// while playing, watching the lamp in the band.
//
// Every tile and bar writes to the model only, and is painted back from its
// notifications (gui-wiring.scd), so a refused action leaves it dark and a
// footswitch press lights it as a click does.
//
// This pane reads ~returnChannel, which ~applyRoutingProfile sets, so it cannot
// be built before the routing profile is resolved.
(
// ---- Small builders -------------------------------------------------------------------
// The words for a control's footswitch: its key, and the first binding the
// MIDI map has for it ("R · PC 4"). Kept as the map changes (~midiWatch).
~performSw = { |key, id|
    var w = ~midiWords.(id);
    var first = w !? { |s| s.split($,).first.stripWhiteSpace };
    (key ? "") ++ (if(key.notNil and: { first.notNil }) { " · " } { "" }) ++ (first ? "")
};

// A value row: the label left in \mute, the value right in mono, the bar under.
~performParam = { |label, valueView, bar|
    VLayout(
        HLayout(~guiLabel.(label, 14), nil, valueView).margins_(0).spacing_(6),
        bar
    ).spacing_(5).margins_(0)
};
~performValue = { |str|
    var t = ~guiMonoText.(str ? "—", 14, ~gt[\ink]).align_(\right);
    t.setProperty(\wordWrap, false);
    t
};

// A read-only bar: what a layer is doing, in its colour, not to be dragged.
~performReadBar = { |key| ~guiBar.(key, 14).acceptsMouse_(false) };

// One layer's column. `p` holds the parts: key (its colour), name, sw (a
// function painting its footswitch words), view (the view its name opens, or
// nil), toggle (the switch tile), rows (value rows), extra (more under them)
// and note (the line at the foot).
~performColumn = { |p|
    var band = View().background_(~gt[p[\key]]).fixedHeight_(8);
    var name = LooperTile().states_([[p[\name], ~gt[\ink], nil]]).cycles_(false).align_(\left)
        .font_(~guiSans.(22, true)).pad_(0).fixedHeight_(30)
        .toolTip_(p[\view] !? { |v| "Open " ++ ~guiViewLabels[v] ++ " · key " ++ ~guiViewNumbers[v] } ? "")
        .action_({ p[\view] !? { |v| ~guiSelectView.(v) } });
    var sw = ~guiMonoText.("", 11, ~gt[\mute]).align_(\right);
    var note = ~guiText.("", 13, ~gt[\mute]);
    // One line, however narrow the column (six on SA): it keeps to its corner.
    sw.setProperty(\wordWrap, false);
    p[\sw] !? { |f| ~midiWatch.(sw, { |t| t.string_(f.value) }) };
    ~performColumns[p[\key]] = (band: band, note: note);
    View().background_(~gt[\panel]).layout_(VLayout(*([
        band,
        View().layout_(HLayout([name, stretch: 1], sw).margins_([16, 12, 16, 0]).spacing_(6)),
        View().layout_(VLayout(p[\toggle]).margins_([16, 12, 16, 12])),
        View().layout_(VLayout(*(p[\rows] ++ (p[\extra] ? []) ++ [nil])).margins_([16, 0, 16, 12]).spacing_(14)),
        ~guiRule.(),
        View().minHeight_(58).layout_(VLayout(note, nil).margins_([16, 10, 16, 12]))
    ])).margins_(0).spacing_(0))
};

// A layer's colour, full or faded with its switch.
~performPaintBand = { |key, on|
    ~performColumns[key] !? { |c|
        if(c[\band].isClosed.not and: { c[\on] != on }) {
            c[\on] = on;
            c[\band].background_(if(on) { ~gt[key] } { ~gt[key].copy.alpha_(0.3) });
        };
    };
};
~performNote = { |key, str|
    ~performColumns[key] !? { |c| if(c[\note].isClosed.not) { c[\note].string_(str ? "") } };
};

// An action tile: the label, its footswitch words top right, the line under it.
~performAction = { |key, label, keyChar, id, action, tip|
    var tile = ~midiTip.(LooperTile().states_([[label, ~gt[\ink], ~gt[\panel]]]).cycles_(false)
        .border_(~gt[\line]).borderWidth_(2).align_(\left).font_(~guiSans.(17, true))
        // Both columns of tiles the same width: a long label is drawn smaller.
        .fixedHeight_(56).minWidth_(120).action_({ ~looper !? { |l| action.(l) } }), id, tip);
    ~midiWatch.(tile, { |t| t.sw_(~performSw.(keyChar, id)) });
    ~performActions[key] = tile;
    tile
};
// Paint an action tile: idle, or lit (fill, ink, border), with its line.
~performPaintAction = { |key, sub, look|
    ~performActions[key] !? { |t|
        if(t.isClosed.not) {
            t.states_([[t.string, look !? { |x| x[\ink] } ?? { ~gt[\ink] }, look !? { |x| x[\fill] } ?? { ~gt[\panel] }]]);
            t.border_(look !? { |x| x[\border] } ?? { ~gt[\line] });
            t.hatch_(look !? { |x| x[\hatch] == true } ? false);
            t.sub_(sub);
        };
    };
};

// A Wave synth setting as a bar to drag (0..1 along its knob's spec), held
// while the hand is on it so the four-a-second repaint leaves it be.
~performSynthBar = { |name, tip|
    var p = MegaSAWave.param(name);
    ~mapTag.(~guiBar.(\synth)
        .action_({ |sl| ~megaSA !? { |m| m.wave.set(name, p[\spec].map(sl.value)); ~performPaintSynth.() } })
        .mouseDownAction_({ |sl| ~performSynthHeld = name; nil })
        .mouseUpAction_({ |sl| ~performSynthHeld = nil; ~performPaintSynth.(); nil }),
        ("sa.synth." ++ name).asSymbol, tip)
};

// A macro row: the name, the bar, the value.
~performMacro = { |label, bar, value|
    HLayout(
        ~guiText.(label, 15).fixedWidth_(70),
        [bar, stretch: 1],
        value.fixedWidth_(52)
    ).spacing_(10).margins_(0)
};

// ---- The pane ----------------------------------------------------------------------------
~buildPerformPane = {
    var pane = View().background_(~gt[\bg]);
    var l = ~looper;
    var sa = ~rp.notNil and: { ~rp[\sa] == true } and: { ~megaSA.notNil };
    var columns, loopCol, cutCol, grainCol, fxCol, drumCol, synthCol, right, steppers;
    var stepper, levels;
    ~performColumns = IdentityDictionary.new;
    ~performActions = IdentityDictionary.new;

    // ---- Loop ----------------------------------------------------------------------------
    ~performLoopToggle = ~midiTip.(LooperTile().cycles_(false).font_(~guiMono.(16, true)).fixedHeight_(46)
        // The fourth: no loop, and reverse left on (Clear keeps it), so the
        // next take plays backwards. Shown, or a stray click arms it unseen.
        .states_([["EMPTY", ~gt[\mute], nil], ["FORWARD", Color.white, ~gt[\loop]], ["REVERSE", Color.white, ~gt[\loop]],
            ["EMPTY · REVERSE", ~gt[\loop], nil]])
        .action_({ ~looper !? { |lp| lp.reverse } }),
        'looper.reverse', "Play the loop backwards, or forwards again. Key V.");
    ~feedbackSlider = ~mapTag.(~guiBar.(\loop)
        .value_(l !? { |lp| lp.feedback } ? 1)
        .action_({ |sl| ~looper !? { |lp| lp.feedback = sl.value } }),
        'looper.feedback');
    ~feedbackLabel = ~performValue.((l !? { |lp| lp.feedback } ? 1).round(0.01).asString);
    ~performLengthBar = ~performReadBar.(\loop);
    ~performLengthLabel = ~performValue.("—");
    ~performMultiplyTile = ~midiTip.(LooperTile().states_([["× 2  Multiply", ~gt[\ink], nil]]).cycles_(false)
        .border_(~gt[\line]).font_(~guiSans.(14, true)).fixedHeight_(32).minWidth_(60)
        .action_({ ~looper !? { |lp| lp.multiply } }),
        'looper.multiply', "Extend the loop by a whole number of repetitions. Key M.");
    ~midiWatch.(~performMultiplyTile, { |t| t.sw_(~performSw.("M", 'looper.multiply')) });
    loopCol = ~performColumn.((key: \loop, name: "Loop",
        sw: { ~performSw.("V", 'looper.reverse') },
        toggle: ~performLoopToggle,
        rows: [
            ~performParam.("Feedback", ~feedbackLabel, ~feedbackSlider),
            ~performParam.("Length", ~performLengthLabel, ~performLengthBar)
        ],
        extra: [~performMultiplyTile]));

    // ---- Cutter ------------------------------------------------------------------------
    ~bbcutButton = ~midiTip.(~guiLayerTile.(\cut)
        .action_({ ~looper !? { |lp| lp.bbcut = lp.bbcut.not } }),
        'looper.bbcut', "Turn the breakbeat cutter on/off (key B). Refused, and left dark, with no analysed take.");
    // Mix vs the dry loop, à la Ableton Beat Repeat.
    ~bbcutModeSeg = ~guiSeg.(["Mix", "Insert", "Gate"], (height: 30, base: \panel,
        font: ~guiSans.(14),
        action: { |i| ~looper !? { |lp| lp.bbcutMode = [\mix, \insert, \gate][i] } }));
    ~mapTag.(~bbcutModeSeg[\view], 'looper.bbcutMode',
        "How the cutter sits against the dry loop:\n"
            "Mix: dry loop plus the cut repetitions on top.\n"
            "Insert: dry loop ducks to silence while a repetition plays.\n"
            "Gate: dry loop muted — you hear the cutter alone.");
    ~performArcBar = ~performReadBar.(\cut).inset_(3).fixedHeight_(20);
    // "now / at full arc": the words are in the tooltip, the column has no
    // room for them beside the numbers.
    ~performArcLabel = ~guiLabel.("Arc", 14);
    ~performArcValue = ~performValue.("—");
    [~performArcLabel, ~performArcValue].do { |v|
        v.toolTip_("The first voice's intensity: what the cutter uses now / its value at full arc.\n"
            "The Arc macro moves it between its low end and the value the voice keeps.") };
    cutCol = ~performColumn.((key: \cut, name: "Cutter", view: \sound,
        sw: { ~performSw.("B", 'looper.bbcut') },
        toggle: ~bbcutButton,
        rows: [
            VLayout(~guiText.("Mode", 14, ~gt[\mute]), ~bbcutModeSeg[\view]).spacing_(5).margins_(0),
            VLayout(HLayout(~performArcLabel, nil, ~performArcValue).margins_(0).spacing_(8), ~performArcBar)
                .spacing_(2).margins_(0)
        ]));

    // ---- Grains ------------------------------------------------------------------------
    ~granularPerformButton = ~midiTip.(~guiLayerTile.(\grain)
        .action_({ ~looper !? { |lp| lp.toggleGranular } }),
        'looper.granular', "Turn the granular layer on/off (key G). Refused, and left dark, with no loop.");
    // Writes to the model only; the SimpleController pushes value changes
    // back to bar and label, so CC 118 stays in sync.
    ~granularSlider = ~mapTag.(~guiBar.(\grain)
        .value_(l !? { |lp| lp.granularMorph } ? 0)
        .action_({ |sl| ~looper !? { |lp| lp.granularMorph = sl.value } }),
        'looper.granularMorph', "Morph: 0 the frozen drone, 1 the pulsed scan in time with the loop.");
    ~granularLabel = ~performValue.((l !? { |lp| lp.granularMorph } ? 0).round(0.01).asString);
    ~performGrainAmp = ~mapTag.(~guiBar.(\grain)
        .value_(l !? { |lp| lp.granularAmp } ? 0.7)
        .action_({ |sl| ~looper !? { |lp| lp.granularAmp = sl.value } }),
        'looper.granularAmp', "The granular layer's level against the dry loop.");
    ~performGrainAmpLabel = ~performValue.((l !? { |lp| lp.granularAmp } ? 0.7).round(0.01).asString);
    grainCol = ~performColumn.((key: \grain, name: "Grains", view: \sound,
        sw: { ~performSw.("G", 'looper.granular') },
        toggle: ~granularPerformButton,
        rows: [
            ~performParam.("Morph", ~granularLabel, ~granularSlider),
            ~performParam.("Level", ~performGrainAmpLabel, ~performGrainAmp)
        ]));

    // ---- Megalooper SA: Effects and Drums ----------------------------------------------
    if(sa) {
        ~performFxTile = LooperTile().cycles_(false).font_(~guiMono.(16, true)).fixedHeight_(46)
            .states_(~guiLayerStates.(\fx, "ON", "OFF")).border_(~gt[\line]).dashed_(true)
            .toolTip_("The effects are switched on the FX view and by their footswitches. Key 3.")
            .action_({ ~guiSelectView.(\fx) });
        ~performFxGuitar = ~performReadBar.(\fx);
        ~performFxGuitarLabel = ~performValue.("—");
        ~performFxLoop = ~performReadBar.(\fx);
        ~performFxLoopLabel = ~performValue.("—");
        ~performFxDrums = ~performReadBar.(\fx);
        ~performFxDrumsLabel = ~performValue.("—");
        // No footswitch words in its corner: each effect has its own (FX view).
        fxCol = ~performColumn.((key: \fx, name: "Effects", view: \fx, sw: { "" },
            toggle: ~performFxTile,
            rows: [
                ~performParam.("Instrument", ~performFxGuitarLabel, ~performFxGuitar),
                ~performParam.("Loop", ~performFxLoopLabel, ~performFxLoop),
                ~performParam.("Drums", ~performFxDrumsLabel, ~performFxDrums)
            ]));
        ~performDrumsTile = ~midiTip.(~guiLayerTile.(\drum)
            .action_({ ~drumsModel !? { |f| f.value !? { |d| d.setOn(d.on.not) } } }),
            'sa.drums.on', "The steps on or off, as their footswitch does.");
        ~performDrumsPattern = ~performReadBar.(\drum);
        ~performDrumsPatternLabel = ~performValue.("—");
        ~performDrumsKit = ~performReadBar.(\drum);
        ~performDrumsKitLabel = ~performValue.("—");
        drumCol = ~performColumn.((key: \drum, name: "Drums", view: \drums,
            sw: { ~performSw.(nil, 'sa.drums.on') },
            toggle: ~performDrumsTile,
            rows: [
                ~performParam.("Pattern", ~performDrumsPatternLabel, ~performDrumsPattern),
                ~performParam.("Kit", ~performDrumsKitLabel, ~performDrumsKit)
            ]));
        // The synth (gui-synth.scd): its switch, two of the Wave synth's
        // settings to play with, a new sound. With a plugin playing instead,
        // those three are the Wave synth's and grey.
        if(~megaSA.respondsTo(\wave)) {
            ~performSynthTile = ~midiTip.(~guiLayerTile.(\synth)
                .action_({ ~synthModel !? { |f| f.value !? { |d| d.setNotesOn(d.notesOn.not); ~performPaintSynth.() } } }),
                'sa.synth.on', "The note sequencer on or off, from the moment you hear it, as its footswitch does.");
            ~performSynthCutoff = ~performSynthBar.(\waveCutoff,
                "The Wave synth's filter: drag it while the line plays. Each note takes the cutoff\n"
                    "it starts with.");
            ~performSynthCutoffLabel = ~performValue.("—");
            ~performSynthPos = ~performSynthBar.(\waveAPos,
                "Oscillator A's place in its table: the sound's colour. Each note takes it as it starts.");
            ~performSynthPosLabel = ~performValue.("—");
            ~performSynthRandom = ~midiTip.(LooperTile().states_([["Random", ~gt[\ink], nil]]).cycles_(false)
                .border_(~gt[\line]).font_(~guiSans.(14, true)).fixedHeight_(32).minWidth_(60)
                .action_({ ~megaSA !? { |m| m.wave.randomize; ~performPaintSynth.() } }),
                'sa.synth.random', "Every setting of the Wave synth at random but its level and glide.");
            synthCol = ~performColumn.((key: \synth, name: "Synth", view: \synth,
                sw: { ~performSw.(nil, 'sa.synth.on') },
                toggle: ~performSynthTile,
                rows: [
                    ~performParam.("Cutoff", ~performSynthCutoffLabel, ~performSynthCutoff),
                    ~performParam.("Position", ~performSynthPosLabel, ~performSynthPos)
                ],
                extra: [~performSynthRandom]));
        } { ~performSynthTile = nil };
    } {
        ~performFxTile = nil;
        ~performDrumsTile = nil;
        ~performSynthTile = nil;
    };
    columns = [loopCol, cutCol, grainCol] ++ (if(sa) { [fxCol, drumCol] ++ (synthCol !? { [synthCol] } ? []) } { [] });

    // ---- Actions ---------------------------------------------------------------------------
    ~performAction.(\trigger, "Trigger", "R", 'looper.trigger', { |lp| lp.trigger },
        "Record / play / overdub — the one multi-purpose transport.");
    ~performAction.(\stop, "Stop", "S", 'looper.stop', { |lp| lp.stopPlayback }, "Stop playback.");
    ~breakButton = ~performAction.(\break, "Break", "K", 'looper.break', { |lp| lp.fireBreak },
        "Silence the looper from now until the downbeat the loop count below picks out.\n"
            "The loop keeps running underneath — only the output goes away — so Live stays\n"
            "in sync and the loop returns exactly where it would have been.");
    ~nextReadingButton = ~performAction.(\reading, "Next reading", "A", 'looper.nextReading',
        { |lp| lp.nextReading },
        "Move the take to the analyser's NEXT reading of it — the meter that scored second,\n"
            "then third, round to its own answer. Lands on a loop boundary where Live's bar line\n"
            "agrees, so nothing jumps; the audio and the onset notes never change.");
    ~dissolveButton = ~performAction.(\dissolve, "Dissolve", "D", 'looper.dissolve', { |lp| lp.toggleDissolve },
        "Run the ending over the bar count below; press again to abort and restore.\n"
            "The cutter goes first, then the body of the loop, and the grains last.");
    ~nextLoopButton = ~performAction.(\chain, "Rec next loop", "N", 'looper.recordNextLoop',
        { |lp| lp.recordNextLoop },
        if(~returnChannel.notNil) {
            "Record the next loop while this one plays. Starts and ends on a loop boundary,\n"
                "at a whole number of repetitions."
        } {
            "Loop chaining needs a return channel from Live; this rig has none."
        });
    // A rig with no return channel has nothing to chain FROM: inert and
    // labelled, rather than a tile that does nothing.
    ~nextLoopButton.enabled_(~returnChannel.notNil);
    ~performAction.(\undo, "Undo", "U", 'looper.undo', { |lp| lp.undo }, "Drop the last overdub.");
    // Destructive, and single-click — exactly like the C key and the
    // footswitch it mirrors. A confirmation here and not there would make the
    // tile the odd one out rather than the safe one.
    ~performAction.(\clear, "Clear", "C", 'looper.clear', { |lp| lp.clear },
        "Throw the loop away. Single click, like the key — there is no confirmation.");

    // The counts the Break and Dissolve tiles run over.
    stepper = { |id, lo, hi, val, set, tip|
        ~mapTag.(NumberBox().canFocus_(false)
            .clipLo_(lo).clipHi_(hi).step_(1).scroll_step_(1).decimals_(0)
            .font_(~guiMono.(14, true)).background_(~gt[\panel]).normalColor_(~gt[\ink])
            .fixedSize_(Size(52, 28)).align_(\center)
            .value_(val)
            .action_({ |nb| ~looper !? { |lp| set.(lp, nb.value) } }), id, tip)
    };
    ~breakLoopsField = stepper.('looper.breakLoops', 1, 8, l !? { |lp| lp.breakLoops } ? 1,
        { |lp, v| lp.breakLoops = v },
        "How many loop passes a break covers, counting the one you struck it in.\n"
            "So 1 — the default — comes back on the NEXT downbeat; 2 buys a full pass on top of it.");
    ~dissolveBarsField = stepper.('looper.dissolveBars', 1, 64, l !? { |lp| lp.dissolveBars } ? 8,
        { |lp, v| lp.dissolveBars = v }, "How many bars the ending takes.");
    steppers = HLayout(
        ~guiCaption.("BREAK LOOPS"), ~breakLoopsField, nil,
        ~guiCaption.("DISSOLVE BARS"), ~dissolveBarsField
    ).margins_(0).spacing_(8);

    // ---- Macros -------------------------------------------------------------------------------
    // Writes to the model only; the controller paints bar and label back.
    ~masterAmpSlider = ~mapTag.(~guiBar.(\ink, 16)
        .value_(l !? { |lp| lp.masterAmp } ? 0.7)
        .action_({ |sl| ~looper !? { |lp| lp.masterAmp = sl.value } }),
        'looper.masterAmp');
    ~masterAmpLabel = ~performValue.((l !? { |lp| lp.masterAmp } ? 0.7).round(0.01).asString);
    // The control the whole piece is shaped with.
    ~intensitySlider = ~midiTip.(~guiBar.(\ink, 16)
        .value_(l !? { |lp| lp.intensity } ? 1)
        .action_({ |sl| ~looper !? { |lp| lp.intensity = sl.value } }),
        'looper.intensity',
        "The expression pedal's control. Heel: the dry loop, with the cutter running but\n"
            "barely chopping and no grains. Toe: the cutter chopping as dialled in and the\n"
            "granular layer at its set level. It only SCALES — the stored controls keep\n"
            "meaning what they say, and the cutter's own level never moves with it.");
    ~intensityLabel = ~performValue.((l !? { |lp| lp.intensity } ? 1).round(0.01).asString);
    // Here and not on Setup, because tuning detection is not a between-takes
    // activity: the threshold is the ceiling on meter detection AND on the
    // onset-note drum part, and the only way to set it is to watch the lamp in
    // the band while playing.
    ~onsetThresholdSlider = ~midiTip.(~guiBar.(\ink, 16)
        .value_(~onsetThresholdSpec.unmap(l !? { |lp| lp.onsetThreshold } ? 0.5))
        .action_({ |sl| ~looper !? { |lp| lp.onsetThreshold = ~onsetThresholdSpec.map(sl.value) } }),
        'looper.onsetThreshold',
        "Onset detection threshold. Higher rejects more (noisy input, ghost onsets), lower\n"
            "admits more (quiet or soft playing). Live on the monitor AND a running recorder,\n"
            "so the next take detects what you just saw. The travel is exponential: most of\n"
            "it is the low end, where the decisions are.");
    ~onsetThresholdLabel = ~performValue.((l !? { |lp| lp.onsetThreshold } ? 0.5).round(0.01).asString);

    right = ~performRight = View().background_(~gt[\bg]).fixedWidth_(400).layout_(VLayout(
        ~guiCaption.("ACTIONS · FOOTSWITCH"),
        GridLayout.rows(
            [~performActions[\trigger], ~performActions[\stop]],
            [~performActions[\break], ~performActions[\reading]],
            [~performActions[\dissolve], ~performActions[\chain]],
            [~performActions[\undo], ~performActions[\clear]]
        ).hSpacing_(8).vSpacing_(8),
        steppers,
        ~guiCaption.("MACROS · DRAG"),
        ~performMacro.("Master", ~masterAmpSlider, ~masterAmpLabel),
        ~performMacro.("Arc", ~intensitySlider, ~intensityLabel),
        ~performMacro.("Onset", ~onsetThresholdSlider, ~onsetThresholdLabel),
        nil
    ).margins_([18, 14, 18, 12]).spacing_(10));

    // On SA the mixer's strips sit under the layers: levels are played, not
    // set up (they are on Setup as well, and both follow the model).
    levels = if(sa) { ~buildSAPerformLevels !? { |f| f.value } };
    pane.layout_(HLayout(
        [View().layout_(VLayout(*(
            [[View().layout_(HLayout(*(
                columns.collect { |c, i| [[c, stretch: 1]] ++ (if(i < (columns.size - 1)) { [~guiRule.(true)] } { [] }) }
                    .flatten(1)
            )).margins_(0).spacing_(0)), stretch: 1]]
            ++ (levels !? { |v| [~guiRule.(), v] } ? [])
        )).margins_(0).spacing_(0)), stretch: 1],
        ~guiRule.(true),
        right
    ).margins_(0).spacing_(0));

    // The recorder renames a set's files a moment after the stop, once the
    // server has let go of them: the SET REC tile follows them to their final
    // names.
    ~looper !? { |lp|
        lp.sessionRec.onChange = { { ~guiSessionRecPaint !? { |f| f.value } }.defer };
    };

    ~performPaneMin = pane.minSizeHint.width;
    ~performPane = pane;
    ~guiSwapPane.(\perform, pane);
    ~performRefreshAll.();
    pane
};

// The actions column takes 300 px, not 400, when the window is narrower than the
// pane is as designed (its tiles need about 285). Called with the window's
// width, as ~guiTopBarFit is.
~performFit = { |width|
    var to = if(width < (~performPaneMin ? 0)) { 300 } { 400 };
    ~performRight !? { |v| if(v.isClosed.not and: { v.bounds.width != to }) { v.fixedWidth_(to) } };
};

// ---- Painting ------------------------------------------------------------------------------
// Each painter reads the model and nothing else. Nil-guarded throughout: the
// model notifies at boot, before the pane exists.
~performPaintLoop = {
    var l = ~looper, has, dur;
    if(l.notNil and: { ~performLoopToggle.notNil } and: { ~performLoopToggle.isClosed.not }) {
        has = l.loopDuration > 0;
        dur = l.loopDuration;
        ~performLoopToggle.value_(case { has.not } { if(l.reverseFlag) { 3 } { 0 } } { l.reverseFlag } { 2 } { 1 });
        ~performLoopToggle.border_(if(has) { ~gt[\loop] } { ~gt[\line] }).dashed_(has.not);
        ~performPaintBand.(\loop, has);
        ~feedbackSlider !? { |b| b.dim_(if(has) { 1 } { 0.3 }) };
        ~performLengthBar.value_((dur / 20).clip(0, 1)).dim_(if(has) { 1 } { 0.3 });
        ~performLengthLabel.string_(if(has) { dur.round(0.01).asString ++ " s" } { "—" });
        ~performNote.(\loop, "Click to reverse (V). Multiply M, Undo U."
            ++ (case { l.reverseFlag.not } { "" } { has } { " Playing backwards." } { " The next take plays backwards." }));
    };
};

// The cutter's arc row: the one parameter the pedal scales on voice 1, the
// bar at the stored value (what presets save) and the tick at what the cutter
// uses now.
~performPaintCutter = {
    var l = ~looper, v, spec, key, entry, stored, applied, lo, hi, names;
    if(l.notNil and: { ~bbcutButton.notNil } and: { ~bbcutButton.isClosed.not }) {
        ~guiLayerPaint.(~bbcutButton, l.bbcut, \cut);
        ~performPaintBand.(\cut, l.bbcut);
        ~guiSegSet.(~bbcutModeSeg, [\mix, \insert, \gate].indexOf(l.bbcutMode) ? 1);
        v = l.bbcutVoices[0];
        spec = v !? { |vv| l.bbcutProcSpecs[vv[\proc]] };
        key = spec !? { |s| s[\intensityKey] };
        entry = key !? { |k| spec[\params].detect { |e| e[\key] == k } };
        if(entry.notNil) {
            lo = entry[\lo]; hi = entry[\hi];
            stored = v[\params][key] ? entry[\default];
            applied = l.voiceDensity(0) ? stored;
            ~performArcLabel.string_(entry[\label]);
            ~performArcValue.string_(applied.round(0.01).asString ++ " / " ++ stored.round(0.01));
            ~performArcBar.value_((stored - lo) / (hi - lo)).tick_((applied - lo) / (hi - lo));
        } {
            ~performArcLabel.string_("Arc");
            ~performArcValue.string_("not reached");
            ~performArcBar.value_(0).tick_(nil);
        };
        ~performArcBar.dim_(if(l.bbcut) { 1 } { 0.3 });
        names = l.bbcutVoices.collect { |vv| (l.bbcutProcSpecs[vv[\proc]] !? { |s| s[\name] }) ? vv[\proc].asString };
        ~performNote.(\cut, names.size.asString ++ " voice" ++ (if(names.size == 1) { "" } { "s" })
            ++ " · " ++ names.join(" + "));
    };
};

~performPaintGrains = {
    var l = ~looper, env, pitch;
    if(l.notNil and: { ~granularPerformButton.notNil } and: { ~granularPerformButton.isClosed.not }) {
        ~guiLayerPaint.(~granularPerformButton, l.granularOn, \grain);
        ~performPaintBand.(\grain, l.granularOn);
        [~granularSlider, ~performGrainAmp].do { |b| b !? { b.dim_(if(l.granularOn) { 1 } { 0.3 }) } };
        env = Looper.granularEnvNames[l.granularEnv] ? "";
        pitch = l.granularPitch.round(1).asInteger;
        ~performNote.(\grain, (if(l.granularMorph < 0.5) { "Toward drone" } { "Toward pulse" })
            ++ " · pitch " ++ (if(pitch > 0) { "+" } { "" }) ++ pitch ++ " st · " ++ env);
    };
};
// The grains' level, from the generic granular handler (gui-wiring.scd).
~performPaintGrainAmp = { |val|
    ~performGrainAmp !? { |b| if(b.isClosed.not and: { b.held.not }) { b.value_(val) } };
    ~performGrainAmpLabel !? { |t| if(t.isClosed.not) { t.string_(val.round(0.01).asString) } };
    ~performPaintGrains.();
};

// The effects that are on, from the chains as they stand: the built-ins of
// each, in their order (the plugin, always on, is the amp, not an effect
// here).
~performPaintFx = {
    var m = ~megaSA, on, guitar, loops, drums, names, allG, allL, allD;
    if(m.notNil and: { ~performFxTile.notNil } and: { ~performFxTile.isClosed.not }) {
        allG = (m.chainFor(\guitar) !? { |c| c.devices.reject(_.isPlugin) }) ? [];
        allL = (m.chainFor(\loop) !? { |c| c.devices.reject(_.isPlugin) }) ? [];
        allD = (m.chainFor(\drums) !? { |c| c.devices.reject(_.isPlugin) }) ? [];
        guitar = allG.select { |d| d.on };
        loops = allL.select { |d| d.on };
        drums = allD.select { |d| d.on };
        on = (guitar.size + loops.size + drums.size) > 0;
        ~performFxTile.states_(~guiLayerStates.(\fx, (guitar.size + loops.size + drums.size).asString ++ " ON", "OFF"))
            .value_(on.binaryValue).border_(if(on) { ~gt[\fx] } { ~gt[\line] }).dashed_(on.not);
        ~performPaintBand.(\fx, on);
        ~performFxGuitar.value_(guitar.size / allG.size.max(1)).dim_(if(on) { 1 } { 0.3 });
        ~performFxGuitarLabel.string_(guitar.size.asString ++ " of " ++ allG.size);
        ~performFxLoop.value_(loops.size / allL.size.max(1)).dim_(if(on) { 1 } { 0.3 });
        ~performFxLoopLabel.string_(loops.size.asString ++ " of " ++ allL.size);
        ~performFxDrums.value_(drums.size / allD.size.max(1)).dim_(if(on) { 1 } { 0.3 });
        ~performFxDrumsLabel.string_(drums.size.asString ++ " of " ++ allD.size);
        names = (guitar ++ loops ++ drums).collect { |d| d.name };
        ~performNote.(\fx, if(names.isEmpty) { "All bypassed" } { names.join(" › ") });
    };
};

~performPaintDrums = {
    var d = ~drumsModel !? { |f| f.value }, on, kit;
    if(~performDrumsTile.notNil and: { ~performDrumsTile.isClosed.not }) {
        on = (d !? { |dd| dd.on }) ? false;
        ~performDrumsTile.states_(~guiLayerStates.(\drum,
            if((d !? { |dd| dd.breakActive }) == true) { "BREAK" } { "MAIN" }, "OFF"));
        ~guiLayerPaint.(~performDrumsTile, on, \drum);
        ~performPaintBand.(\drum, on);
        ~performDrumsPattern.value_(if((d !? { |dd| dd.breakActive }) == true) { 1 } { 0.5 }).dim_(if(on) { 1 } { 0.3 });
        ~performDrumsPatternLabel.string_(if((d !? { |dd| dd.breakActive }) == true) { "Break" } { "Main" });
        kit = d !? { |dd| dd.kit(\steps) !? { |k| (~drumsKitName !? { |f| f.(dd, k) }) ? k.asString } };
        ~performDrumsKit.value_(if(kit.notNil) { 1 } { 0 }).dim_(if(on) { 1 } { 0.3 });
        ~performDrumsKitLabel.string_(kit ? "none");
        ~performNote.(\drum, if(d.isNil) { "No drums on this MegaSA." } {
            "Step sequencer · switches to the Break pattern on a break." });
    };
};

// The tiles' lines, and which are lit.
~performPaintActions = {
    var l = ~looper, st, brk, chain, left;
    if(l.notNil and: { ~performActions.notNil } and: { ~performActions[\trigger].notNil }) {
        st = l.state;
        brk = l.onBreak;
        ~performPaintAction.(\trigger,
            switch(st, \empty, "start recording", \recording, "close loop", \playing, "start overdub",
                \overdubbing, "back to play", \stopped, "play", ""),
            case
            { st == \recording } { (fill: ~gt[\rec], ink: Color.white, border: ~gt[\rec]) }
            { st == \overdubbing } { (fill: ~gt[\dub], ink: ~gt[\onacc], border: ~gt[\dub]) }
            { nil });
        ~performPaintAction.(\stop, case
            { l.transportMode != \full } { "stop playback" }
            { (~rp !? { |r| r[\live] }) != false } { "MIDI Stop to Live" }
            { (~rp !? { |r| r[\sa] }) == true } { "stop, the drums too" }
            { "stop playback" });
        ~performPaintCounting.();
        ~performPaintReading.();
        chain = l.nextRecState;
        ~performPaintAction.(\chain,
            if(~returnChannel.isNil) { "no return channel" } {
                switch(chain, \idle, "idle · on boundary", \armed, "armed · waiting", \recording, "recording…",
                    \stopping, "stopping…", "")
            },
            case
            { chain == \armed } { (fill: ~gt[\panel], ink: ~gt[\ink], border: ~gt[\armed]) }
            { chain == \recording } { (fill: ~gt[\rec], ink: Color.white, border: ~gt[\rec]) }
            { chain == \stopping } { (fill: ~gt[\panel2], ink: ~gt[\ink], border: ~gt[\rec]) }
            { nil });
        ~performPaintAction.(\undo, if(l.canUndo) { "drop last overdub" } { "nothing to undo" });
        ~performPaintAction.(\clear, "no confirmation", (fill: ~gt[\panel], ink: ~gt[\rec], border: ~gt[\rec]));
    };
};

// What counts: the break's countdown and the dissolve's progress.
~performPaintCounting = {
    var l = ~looper, left;
    if(l.notNil and: { ~performActions.notNil } and: { ~performActions[\break].notNil }) {
        if(l.onBreak) {
            left = l.breakEndsAt !? { |at| (at - SystemClock.seconds).max(0) };
            ~performPaintAction.(\break, if(left.notNil) { "back in " ++ left.round(0.1) ++ " s" } { "on a break" },
                (hatch: true, ink: Color.new255(243, 243, 241), border: ~gt[\ink]));
        } {
            ~performPaintAction.(\break, l.breakLoops.asString ++ " loop" ++ (if(l.breakLoops > 1) { "s" } { "" })
                ++ " · mutes all");
        };
        if(l.dissolving) {
            ~performPaintAction.(\dissolve, (l.dissolvePos * 100).round.asInteger.asString ++ "% · press to abort",
                (fill: ~gt[\ink], ink: ~gt[\bg], border: ~gt[\ink]));
        } {
            ~performPaintAction.(\dissolve, l.dissolveBars.asString ++ " bars · cutter first");
        };
    };
};

// Next reading: the one it would move to, or the one landing.
~performPaintReading = {
    var l = ~looper, pend, n, nx, r;
    if(l.notNil and: { ~performActions.notNil } and: { ~performActions[\reading].notNil }) {
        pend = l.pendingReading;
        n = l.readingCount;
        if(pend.notNil) {
            ~performPaintAction.(\reading, "→ " ++ Looper.prReadingString(pend[\result]) ++ " · lands on a loop",
                (fill: ~gt[\armed], ink: ~gt[\onacc], border: ~gt[\armed]));
        } {
            nx = if(n > 1) { Looper.readingFor(l.analysedResult, (l.readingIndex + 1) % n, l.loopDuration) };
            ~performPaintAction.(\reading,
                if(nx.notNil) { "try " ++ MeterAnalyzer.sigString(nx) } { "nothing else fits" },
                (fill: ~gt[\panel], ink: ~gt[\ink], border: ~gt[\armed]));
        };
    };
};

~performPaintSynth = {
    var m = ~megaSA, d = ~synthModel !? { |f| f.value }, w, on, plugin, n, bar, p;
    if(~performSynthTile.notNil and: { ~performSynthTile.isClosed.not } and: { m.notNil } and: { d.notNil }) {
        w = m.wave;
        on = d.notesOn == true;
        plugin = m.instrumentKey;
        ~performSynthTile.states_(~guiLayerStates.(\synth, "ON", "OFF"));
        ~guiLayerPaint.(~performSynthTile, on, \synth);
        ~performPaintBand.(\synth, on);
        [[\waveCutoff, ~performSynthCutoff, ~performSynthCutoffLabel], [\waveAPos, ~performSynthPos, ~performSynthPosLabel]].do { |row|
            p = MegaSAWave.param(row[0]);
            bar = row[1];
            if(bar.notNil and: { bar.isClosed.not }) {
                if(~performSynthHeld != row[0]) { bar.value_(p[\spec].unmap(w[row[0]])) };
                bar.dim_(if(on and: { plugin.isNil }) { 1 } { 0.3 });
                row[2].string_(if(plugin.isNil) { ~synthFormat !? { |f| f.(p, w[row[0]]) } ? w[row[0]].asString } { "—" });
            };
        };
        ~performSynthRandom !? { |t| if(t.isClosed.not) { t.enabled_(plugin.isNil) } };
        n = d.notes;
        ~performNote.(\synth, MegaSANoteSeq.rootNames[n[\root]]
            ++ (if(n[\scaleOn] == true) { " " ++ MegaSANoteSeq.scales[n[\scale]][0] } { "" })
            ++ " · " ++ MegaSANoteSeq.divisionNames[n[\division]]
            ++ (if(n[\triplet] == true) { "T" } { "" }) ++ (if(n[\dotted] == true) { "." } { "" })
            ++ " · " ++ (plugin !? { |k| PathName(k.asString).fileNameWithoutExtension } ? "Wave synth"));
    };
};

~performRefreshAll = {
    ~performPaintSynth.();
    ~performPaintLoop.();
    ~performPaintCutter.();
    ~performPaintGrains.();
    ~performPaintFx.();
    ~performPaintDrums.();
    ~performPaintActions.();
};

// What the SET REC tile says under it. Three states, and each one names a file
// or says why there is none, because "recording" with no path on screen is
// exactly the claim this feature must never make without evidence. While a set
// records its files carry the stamp; from the stop on, the name it is given
// (tempo and signature), then the name it has on disk.
~sessionRecString = {
    ~looper !? { |l|
        var rec = l.sessionRec;
        var stems = rec !? { |r| r.stems.size } ? 0;
        var what = (if(l.canRecordMaster) { "master + dry tap" } { "DRY TAP" })
            ++ (if(stems > 0) { " + " ++ stems ++ " stems" } { "" }) ++ " + events";
        var shown = { |paths| paths !? { |p| (p[\master] ? p[\tap]) !? { |x| x.basename } } };
        if(l.sessionRecording) {
            what ++ (if(l.canRecordMaster) { "" } { " ONLY" })
                ++ " -> " ++ (shown.(rec.paths) ? "?")
        } {
            if(rec.notNil and: { rec.startedAt.notNil }) {
                "last set: " ++ rec.elapsed.round(1).asInteger ++ " s"
                    ++ (shown.(if(rec.settled) { rec.paths } { rec.finalPaths ? rec.paths })
                        !? { |b| " -> " ++ b } ? "")
            } {
                if(l.canRecordMaster) {
                    "ready — " ++ what
                } {
                    "ready — dry tap + events only (no sessionChannel on this rig)"
                }
            }
        }
    } ? "—"
};

// The SET REC tile's line: the file being written, the last set's, or what a
// set would hold.
~sessionRecShort = {
    ~looper !? { |l|
        var rec = l.sessionRec;
        var shown = { |paths| paths !? { |p| (p[\master] ? p[\tap]) !? { |x| x.basename } } };
        case
        { l.sessionRecording } {
            "→ " ++ (shown.(rec.paths) ? "?") ++ (if(l.canRecordMaster) { "" } { " · dry tap only" })
        }
        { rec.notNil and: { rec.startedAt.notNil } } {
            "last: " ++ (shown.(if(rec.settled) { rec.paths } { rec.finalPaths ? rec.paths }) ? "?")
        }
        { if(l.canRecordMaster) { "master + dry tap + events" } { "dry tap + events" } }
    } ? ""
};

// What a set leaves, and how the names are made. On Megalooper SA (stems
// given to the recorder) the stems and the drums' .mid too.
~sessionHintString = {
    var stems = ~looper !? { |l| l.sessionRec.stems.collect { |st| st[\role] } } ? [];
    (if(stems.notEmpty) {
        "Per set: master, dry tap, stems (" ++ stems.join(", ") ++ "), the event log and the drums' .mid."
    } {
        "Per set: master (what the room heard), dry tap (to re-run detection offline), the event log."
    }) ++ "\nNamed at the stop with the tempo and signature to set Live to: "
        "<stamp>-165.04bpm-7-8-master.wav (no tempo: <stamp>-master.wav)."
};
)
