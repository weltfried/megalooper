// megalooper — the Grains pane: everything Warp1 is doing, exposed.
//
// Loaded by boot.scd; defines only, runs nothing. Entry point:
//   ~buildGranularPane — builds a fresh Grains pane against the EXISTING
//                        ~looper and swaps it into the shell's holder. Safe to
//                        re-run: it never touches the model, so the recorded
//                        loop and a running granular layer both survive it.
//                        Follow with ~wireLooperController.() to re-subscribe.
//
// The parameters themselves, their laws and Reset tweaks are setup-granular.scd's:
// this file builds the pane from them.
//
// NOTE for anyone editing this file: everything above ~buildGranularPane must
// stay at top level and side-effect-free. tests/test-preset-bar.scd loads this
// file with no shell and no window and asserts on the preset family. A
// top-level call to ~guiSwapPane or ~fitOnScreen would take it down.
//
// Why this exists: the layer had exactly one control, `morph`, which slides the
// whole texture between a frozen drone and a beat-locked pulsed scan by lerping
// four hidden parameters at once. That is a great performance control and a
// terrible sound-design one — there was no way to ask for "the pulsed grid, but
// an octave down and sprayed loose". So morph still sets the BASE of the
// texture, and every control here BENDS that base from a neutral default.
//
// Nothing here writes to a widget: bars write to the model, and the
// SimpleController in gui-wiring.scd writes back here. That is what keeps a
// MIDI CC, the Reset button and the slider itself all showing the same number.
(
~granularLabelWidth = 82;

// ---- Preset bar -----------------------------------------------------------
// The bar itself — menu, name field, two-click Save/Delete, status line — is
// gui-presets.scd, shared with the cutter window, because it is the same job
// and muscle memory should carry between the two. This is the granulator's half
// of the family spec: a label, one line of help text, and which Looper methods
// to call. State and widgets live in the family, not in globals here.
~definePresetFamily.(\granular, (
    label:      "Granular",
    statusIdle: "Pick a preset to recall it live · Save writes every control below",
    dirKey:     \granularPresetDir,
    names:      \granularPresetNames,
    slug:       \granularPresetSlug,
    save:       \saveGranularPreset,
    load:       \loadGranularPreset,
    delete:     \deleteGranularPreset
));

// Named wrappers — what gui-main.scd and check.scd address. One line each.
~granularPresetSetStatus      = { |str, isError = false|
    ~presetSetStatus.(\granular, str, isError) };
~refreshGranularPresetList    = { ~presetRefreshList.(\granular) };
~refreshGranularPresetButtons = { ~presetRefreshButtons.(\granular) };
~granularPresetDisarm         = { ~presetDisarm.(\granular) };
~granularPresetArm            = { |which, msg| ~presetArm.(\granular, which, msg) };
~loadGranularPreset           = { |slug| ~presetLoad.(\granular, slug) };
~saveGranularPreset           = { ~presetSave.(\granular) };
~deleteGranularPreset         = { ~presetDelete.(\granular) };
~revertGranularPreset         = { ~presetRevert.(\granular) };
// ---- View state -----------------------------------------------------------
// key -> (slider:, label:, param:). Emptied on close so a controller callback
// arriving after the window is gone finds nothing to write to, rather than
// throwing on a destroyed view.
~granularWidgets = IdentityDictionary.new;

// Push one model value into its row. Called from the SimpleController, so a
// change from ANY surface — this bar, Perform's, a MIDI CC, Reset — lands here.
// The bar the mouse holds is left where the hand is.
~granularRefreshOne = { |key, val|
    ~granularWidgets !? { |d|
        d[key] !? { |w|
            if(w[\slider].isClosed.not) {
                if((w[\slider].respondsTo(\held) and: { w[\slider].held }).not) {
                    w[\slider].value = ~granularUnmapValue.(w[\param], val);
                };
                w[\label].string_(~granularFormat.(w[\param], val));
            };
        };
    };
};

// The window's tiles, and the line under them.
~granularEnvHints = LooperGrains.envHints;
~granularPaintEnv = { |val|
    ~granularEnvSeg !? { |s| ~guiSegSet.(s, val) };
    ~granularEnvHint !? { |t|
        if(t.isClosed.not) {
            t.string_((LooperGrains.envNames[val] ? "") ++ ": " ++ (~granularEnvHints[val] ? ""));
        };
    };
};

// Following the chords (Looper.granularFollowChords): its two tiles, and the
// line under them, which says what the take gives the grains to follow.
~granularChordNames = { |l|
    var segs = (l !? { |x| x.lastResult } !? { |r| r[\chordSegments] }) ? [];
    segs.collect { |s| (s[\rootName] ? "?") ++ (if(s[\scale] == \minor) { "m" } { "" }) }
};
~granularPaintChords = {
    var l = ~looper, names = ~granularChordNames.(l), on = l.notNil and: { l.granularFollowChords };
    ~granularChordsSeg !? { |s| ~guiSegSet.(s, on.binaryValue) };
    ~granularChordsHint !? { |t|
        if(t.isClosed.not) {
            t.string_(case
                { names.size < 2 } {
                    (if(on) { "Follow chords" } { "As played" }) ++ ": this take has "
                        ++ (if(names.isEmpty) { "no chords heard" } { "one chord, " ++ names[0] }) ++ ", so there is nothing to follow."
                }
                { on } { "Follow chords: the grains move with " ++ names.keep(8).join(" → ")
                    ++ (if(names.size > 8) { " …" } { "" }) ++ ", from the chord where they read." }
                { "As played: the grains sound the loop where they read. This take's chords: "
                    ++ names.keep(8).join(" → ") ++ (if(names.size > 8) { " …" } { "" }) ++ "." });
        };
    };
};

// The switch at the top, from the model.
~granularPaintHeader = {
    ~looper !? { |l|
        ~granularOnButton !? { |b|
            if(b.isClosed.not) {
                b.states_([["OFF · G", ~gt[\mute], nil], ["ON · G", ~gt[\onacc], ~gt[\grain]]]);
                b.value_(l.granularOn.binaryValue);
            };
        };
    };
};

// The engine tiles and the Clock's (docs/dev/microsound.md): which engine,
// its line, and the grid. The Clock's title is greyed while Cloud plays (a
// plain View has no alpha), and its controls still set: a switch starts
// from them.
// Cloud's sections are not dimmed for the Clock: Level, Pitch, Detune,
// Position and Spray are both engines'; the tips say which are Cloud's only.
~granularDivisionWords = LooperGrains.divisions.collect { |d|
    if(d >= 1) { d.asInteger.asString } { "1/" ++ (1 / d).round(1).asInteger } };
~granularPaintClock = {
    var l = ~looper, clock;
    l !? {
        clock = l.granularEngine == 1;
        ~granularEngineSeg !? { |s| ~guiSegSet.(s, l.granularEngine) };
        ~granularEngineHint !? { |t| if(t.isClosed.not) { t.string_(LooperGrains.engineHints[l.granularEngine] ? "") } };
        ~granularDivisionSeg !? { |s| ~guiSegSet.(s, LooperGrains.divisions.minIndex { |d| (d - l.granularDivision).abs }) };
        ~granularGroupsSeg !? { |s| ~guiSegSet.(s, l.granularGroups.binaryValue) };
        ~granularClockTitle !? { |t| if(t.isClosed.not) {
            t.string_(if(clock) { "Clock" } { "Clock · plays when the engine is Clock" })
                .stringColor_(if(clock) { ~gt[\ink] } { ~gt[\mute] })
        } };
    };
};

~granularRefreshAll = {
    ~looper !? { |l|
        ~granularParams.do { |p| ~granularRefreshOne.(p[\key], l.perform(p[\key])) };
        ~granularPaintEnv.(l.granularEnv);
        ~granularPaintChords.();
        ~granularPaintClock.();
        ~granularPaintHeader.();
    };
};

// ---- Row + section builders -----------------------------------------------
// A row: the label and the value over a bar in the grains' colour, with a
// thin mark where the control is neutral (its default: morph alone shapes the
// sound there). A bipolar control fills from its middle.
~granularRow = { |p|
    var val    = ~looper.perform(p[\key]);
    var zero   = if(p[\spec].minval < 0) { ~granularUnmapValue.(p, 0) } { 0 };
    // Its tooltip ends with what drives it in the MIDI map.
    var slider = ~midiTip.(~guiBar.(\grain, 16)
        .origin_(zero)
        .neutral_(~granularUnmapValue.(p, p[\default]))
        .inset_(3)
        .fixedHeight_(22)
        .value_(~granularUnmapValue.(p, val))
        // Writes to the model ONLY. The controller paints the label, so the
        // number you read is always the number the synth was given.
        .action_({ |sl| ~controlDo.(("looper." ++ p[\key]).asSymbol, \position, sl.value, \gui) }),
        ("looper." ++ p[\key]).asSymbol, p[\tip]);
    var text = ~guiMonoText.(~granularFormat.(p, val), 14, ~gt[\ink]).align_(\right);
    ~granularWidgets.put(p[\key], (slider: slider, label: text, param: p));
    VLayout(
        HLayout(~guiText.(p[\label], 14, ~gt[\mute]).toolTip_(p[\tip]), nil, text).margins_(0),
        slider
    ).spacing_(3).margins_(0)
};

// The rows by key (~granularParamAt, setup-granular.scd), so the sections below
// can be written in reading order rather than in table order.
~granularRowFor  = { |key| ~granularRow.(~granularParamAt.(key)) };

// A section: its title, what drives its controls ("CC 118 · CC 119"), its
// rows, under a hint as its title's tooltip.
~granularSection = { |title, hint, keys|
    var cc = ~guiMonoText.("", 11, ~gt[\mute]).align_(\right);
    ~midiWatch.(cc, { |t|
        t.string_(keys.collect { |k| ~midiWords.(("looper." ++ k).asSymbol) !? { |w| w.split($,).first } }
            .reject(_.isNil).join(" · "))
    });
    View().layout_(VLayout(*([
        HLayout(~guiText.(title, 18, nil, true).toolTip_(hint), nil, cc).margins_(0)
    ] ++ keys.collect { |k| ~granularRowFor.(k) } ++ [nil])).margins_([22, 16, 22, 16]).spacing_(13))
};

// A controller callback arriving after the window is gone must find an empty
// table, not a destroyed Qt view — MIDI CC 40-47 route through
// ~granularRefreshOne, so without this every message after a close would throw.
// Registered at load time; the shell fires it from ~guiWindow.onClose.
//
// Self-initialising rather than assuming gui-const.scd has been loaded, because
// tests/test-ranges.scd and tests/test-preset-bar.scd load THIS FILE ALONE. A
// bare `~guiTeardowns[\granular] = ...` throws there on a nil registry and takes
// the whole test file down with it.
~guiTeardowns = ~guiTeardowns ? ();
~guiTeardowns[\granular] = { ~granularWidgets = IdentityDictionary.new };

// ---- Pane -----------------------------------------------------------------
// The right half of the Sound view: the switch, Reset tweaks and the preset
// under the grains' colour bar; the four sections two by two; the grain
// window as four tiles.
~buildGranularPane = {
    var pane = View().background_(~gt[\bg]);
    var preset, rule = { ~guiRule.(true) };
    // Deferred preset routines from a previous build would otherwise keep
    // writing into the widgets this rebuild is about to destroy.
    ~presetStopTimers.(\granular);
    // Rebuilt from scratch below; anything still in here points at views this
    // build is replacing.
    ~granularWidgets = IdentityDictionary.new;
    preset = ~guiPresetParts.(\granular, (
        menu: "Saved granular setups: morph plus every control below, including the window shape and Chords.\n"
            "Choosing one recalls it straight away — a running granular layer follows without stopping.",
        rescan: "Rescan your presets (granular/ in your megalooper folder) for files added or removed outside megalooper.",
        name: "File name for Save. Anything but letters and digits becomes '-', so \"Frozen Cathedral\"\n"
            "saves as frozen-cathedral.json.",
        save: "Write every control here to granular/<name>.json in your megalooper folder. Reads 'Overwrite' when the\n"
            "name matches an existing preset; that one needs a second click to confirm.",
        delete: "Delete the selected preset file. Click once to arm, again to confirm. The running\n"
            "granular layer keeps playing."
    ), (
        which: \grains,
        said: "Kept: the next start begins with every control as it is now.",
        tip: "Keep morph and every control here, the window shape and Chords too, as they are\n"
            "now: the next start begins with them instead of megalooper's own. The grains'\n"
            "switch is not in it: they start off, as ever."
    ));
    // Mirrors the G key and the footswitch. The model is the authority:
    // pressing this with no loop recorded is refused and the tile stays dark.
    ~granularOnButton = ~midiTip.(LooperTile().cycles_(false).font_(~guiMono.(14, true))
        .fixedSize_(Size(96, 34)).border_(~gt[\grain])
        .action_({ ~controlDo.('looper.granular', \press, nil, \gui) }),
        'looper.granular',
        "Toggle the granular layer (key G). Refused, and left off, while no loop is recorded.");
    // The window shapes, from LooperGrains.envNames, one tile each.
    ~granularEnvSeg = ~guiSeg.(LooperGrains.envNames,
        (gap: 6, height: 38, fill: \grain, ink: \onacc, base: \bg, font: ~guiSans.(15, true),
            action: { |i| ~controlDo.('looper.granularEnv', \set, i, \gui) }));
    ~granularEnvMenu = ~mapTag.(~granularEnvSeg[\view], 'looper.granularEnv',
        "Grain envelope shape.\n"
            "Hann: Warp1's own, smooth and symmetrical — the default.\n"
            "Plateau: flat top with short fades. More energy per grain, squarer edges:\n"
            "  thicker drones, harder pulses.\n"
            "Percussive: instant attack, long decay. Every grain becomes a little hit — this\n"
            "  is what makes the pulsed end read as rhythm rather than as texture.\n"
            "Swell: the same shape backwards. Attacks are erased, so even a plucked loop\n"
            "  smears into pad.");
    ~granularEnvHint = ~guiHelp.(~guiText.("", 13, ~gt[\mute]));
    // The take's chords: the grains as the loop sounds where they read, or
    // transposed with the changes.
    ~granularChordsSeg = ~guiSeg.(["As played", "Follow chords"],
        (gap: 6, height: 38, fill: \grain, ink: \onacc, base: \bg, font: ~guiSans.(15, true),
            action: { |i| ~controlDo.('looper.granularFollowChords', \set, i, \gui) }));
    ~mapTag.(~granularChordsSeg[\view], 'looper.granularFollowChords',
        "As played (the default): the grains sound the loop where they read, as they always did.\n"
            "Follow chords: they are transposed by the interval from the chord where they read to the\n"
            "chord the loop plays now, the nearer way round, so a drone frozen in one chord follows\n"
            "the changes. At morph 1 they read where the loop is, and nothing moves. The chords are\n"
            "the take's, as the analysis heard them.");
    ~granularChordsHint = ~guiHelp.(~guiText.("", 13, ~gt[\mute]));
    // The engine: Cloud (Warp1, as the grains always were) | Clock.
    ~granularEngineSeg = ~guiSeg.(LooperGrains.engineNames,
        (gap: 6, height: 38, fill: \grain, ink: \onacc, base: \bg, font: ~guiSans.(15, true),
            action: { |i| ~controlDo.('looper.granularEngine', \set, i, \gui) }));
    ~mapTag.(~granularEngineSeg[\view], 'looper.granularEngine',
        "Cloud (the default): the grains as a texture, a drone at Morph 0 and a pulse locked to the\n"
            "loop at 1, everything below bending it.\n"
            "Clock: grains started on a clock of their own, locked to the loop: so many a beat, or one\n"
            "on every beat group of the reading (7/8 as 2+2+3), on the grid or scattered into a cloud.\n"
            "Switching while the grains play changes over at once.");
    ~granularEngineHint = ~guiHelp.(~guiText.("", 13, ~gt[\mute]));
    // The Clock's grid: grains per beat (the count's beat: an eighth in 7/8),
    // or a grain per beat group.
    ~granularDivisionSeg = ~guiSeg.(~granularDivisionWords,
        (gap: 4, height: 34, fill: \grain, ink: \onacc, base: \bg, font: ~guiMono.(14, true),
            action: { |i| ~controlDo.('looper.granularDivision', \set, i, \gui) }));
    ~mapTag.(~granularDivisionSeg[\view], 'looper.granularDivision',
        "The Clock: grains per beat, on the beat's grid from the downbeat. The beat is the one the\n"
            "count on Perform counts: an eighth in 7/8, a quarter in 4/4. Groups plays over this.");
    ~granularGroupsSeg = ~guiSeg.(["Grid", "Groups"],
        (gap: 6, height: 34, fill: \grain, ink: \onacc, base: \bg, font: ~guiSans.(15, true),
            action: { |i| ~controlDo.('looper.granularGroups', \set, i, \gui) }));
    ~mapTag.(~granularGroupsSeg[\view], 'looper.granularGroups',
        "The Clock. Grid: Per beat grains a beat. Groups: one grain on every beat group of the reading,\n"
            "as long as its group times Length: 7/8 plays 2+2+3, uneven bars bar by bar. With no reading\n"
            "there are no groups, and the grid plays.");

    pane.layout_(VLayout(
        ~guiBand.(\grain),
        View().fixedHeight_(58).layout_(HLayout(
            ~guiTitle.("Grains", 26),
            ~granularOnButton,
            ~mapTag.(LooperTile().states_([["Reset tweaks", ~gt[\mute], nil]]).cycles_(false)
                .font_(~guiSans.(14)).fixedHeight_(30).fixedWidth_(110)
                .action_({ ~controlDo.('looper.granularResetTweaks', \press, nil, \gui) }),
                'looper.granularResetTweaks',
                "Put every control below back to neutral, so morph alone shapes the sound again.\n"
                    "Morph itself is left where you performed it."),
            nil,
            [preset[\menu].minWidth_(220), stretch: 1]
        ).margins_([22, 0, 22, 0]).spacing_(14)),
        ~guiRule.(),
        View().layout_(VLayout(preset[\edit]).margins_([22, 10, 22, 10])),
        ~guiRule.(),
        View().layout_(VLayout(
            ~guiCaption.("ENGINE", 11),
            ~granularEngineSeg[\view],
            ~granularEngineHint
        ).margins_([22, 16, 22, 16]).spacing_(8)),
        ~guiRule.(),
        View().layout_(HLayout(
            [View().layout_(VLayout(
                ~granularClockTitle = ~guiText.("Clock", 18, nil, true)
                    .toolTip_("The Clock engine's grid: how many grains a beat, or one a beat group"),
                ~guiCaption.("PER BEAT", 11),
                ~granularDivisionSeg[\view],
                ~guiCaption.("ON", 11),
                ~granularGroupsSeg[\view],
                nil
            ).margins_([22, 16, 22, 16]).spacing_(8)), stretch: 1],
            rule.(),
            [~granularSection.("Grains",
                "The Clock's grains: on the grid or scattered, and how long",
                [\granularScatter, \granularLength]), stretch: 1]
        ).margins_(0).spacing_(0)),
        ~guiRule.(),
        View().layout_(VLayout(HLayout(
            [~granularSection.("Blend",
                "Morph sets the base texture · Level balances it against the dry loop",
                [\granularMorph, \granularAmp]), stretch: 1],
            rule.(),
            [~granularSection.("Pitch",
                "Transposition is fixed per grain · detune is redrawn for every grain",
                [\granularPitch, \granularDetune]), stretch: 1]
        ).margins_(0).spacing_(0),
        ~guiRule.(),
        HLayout(
            [~granularSection.("Grain",
                "Size and density multiply what morph asks for — 1 x is morph untouched",
                [\granularSize, \granularDensity, \granularSizeRand]), stretch: 1],
            rule.(),
            [~granularSection.("Read position",
                "Where in the loop grains come from, and how the read point moves",
                [\granularPosition, \granularScan, \granularSpray]), stretch: 1]
        ).margins_(0).spacing_(0)).margins_(0).spacing_(0)),
        ~guiRule.(),
        View().layout_(VLayout(
            ~guiCaption.("GRAIN WINDOW", 11),
            ~granularEnvSeg[\view],
            ~granularEnvHint
        ).margins_([22, 16, 22, 16]).spacing_(8)),
        ~guiRule.(),
        View().layout_(VLayout(
            ~guiCaption.("CHORDS", 11),
            ~granularChordsSeg[\view],
            ~granularChordsHint
        ).margins_([22, 16, 22, 16]).spacing_(8)),
        nil
    ).margins_(0).spacing_(0));

    ~granularPane = pane;
    ~guiSwapPane.(\grains, pane);

    ~granularRefreshAll.();
    // Rescan on the way in, so presets added on disk show up.
    ~refreshGranularPresetList.();
    pane
};

// ---- What the Grains pane hears from the Looper (~guiWatch, gui-wiring.scd) ----------
// One handler per parameter of the table its rows come from, so adding a
// granular control never means coming back here.
~granularWatch = {
    var chords = { ~granularPaintChords !? { |f| f.() } };
    var handlers = (
        granular: { ~granularPaintHeader !? { |f| f.() } },
        granularEnv: { |looper, what, val| ~granularEnvSeg !? { ~granularPaintEnv !? { |f| f.(val) } } },
        granularFollowChords: chords,
        granularEngine: { ~granularPaintClock !? { |f| f.() } },
        granularDivision: { ~granularPaintClock !? { |f| f.() } },
        granularGroups: { ~granularPaintClock !? { |f| f.() } },
        // What the take gives them to follow: a new result, another reading,
        // a loop recorded or cleared.
        result: chords, readingIndex: chords, state: chords
    );
    (~granularParams ? []).do { |p|
        handlers.put(p[\key], { |looper, what, val| ~granularRefreshOne !? { |f| f.(what, val) } });
    };
    ~guiUnwatch.(\granular);
    ~guiWatch.(\granular, ~looper, handlers);
};
)
