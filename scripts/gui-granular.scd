// megalooper — the Grains pane: everything Warp1 is doing, exposed.
//
// Loaded by boot.scd; defines only, runs nothing. Entry point:
//   ~buildGranularPane — builds a fresh Grains pane against the EXISTING
//                        ~looper and swaps it into the shell's holder. Safe to
//                        re-run: it never touches the model, so the recorded
//                        loop and a running granular layer both survive it.
//                        Follow with ~wireLooperController.() to re-subscribe.
//
// NOTE for anyone editing this file: everything above ~buildGranularPane must
// stay at top level and side-effect-free. tests/test-ranges.scd and
// tests/test-preset-bar.scd load this file ALONE, with no shell and no window,
// and assert on ~granularParams / ~granularMapValue / the preset family. A
// top-level call to ~guiSwapPane or ~fitOnScreen would take both files down.
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

// Slider position (0..1) <-> parameter value. Everything goes through its
// ControlSpec except the bipolar ones: Scan's useful range is a hair either
// side of zero (0.05 extra passes per loop is already an audible drift), and a
// plain linear +/-2 slider buries that inside one pixel of centre. Those get a
// squared, symmetric law instead, which spreads the small values out and still
// reaches the ends.
~granularMapValue = { |p, v|
    if(p[\bipolar] == true) {
        var x = (v * 2) - 1;
        x.sign * x.squared * p[\spec].maxval
    } {
        p[\spec].map(v)
    };
};

~granularUnmapValue = { |p, val|
    if(p[\bipolar] == true) {
        var x = (val / p[\spec].maxval).clip(-1, 1);
        ((x.sign * x.abs.sqrt) + 1) * 0.5
    } {
        p[\spec].unmap(val)
    };
};

// Whole-number params (Pitch) read badly as "-12.0", so they print as integers.
~granularFormat = { |p, val|
    var str = if(p[\round] >= 1) {
        val.round(1).asInteger.asString
    } {
        val.round(p[\round]).asString
    };
    str ++ (p[\unit] ? "")
};

// ---- The parameter table --------------------------------------------------
// Every row of the window comes from here, and so does the MVC wiring in
// gui-main.scd — adding a parameter means adding one entry, a matching setter
// on Looper and a SynthDef arg, and nothing else.
//
// `default` is the value Reset restores and is deliberately NEUTRAL: with all
// of them at default the layer sounds exactly as it did when morph was the only
// control. `noReset` keeps the meta-control out of that (resetting the tweaks
// should not also throw away a performed drone/rhythm position).
//
// The two multipliers get GEOMETRIC ranges (1/8..8, 1/4..4) so that the centre
// of the slider — and CC 64 — is exactly 1x, i.e. morph untouched. An off-centre
// neutral makes a multiplier impossible to return to by feel.
~granularParams = [
    (key: \granularMorph, label: "Morph", spec: ControlSpec(0, 1, \lin, 0, 0),
        round: 0.01, default: 0, noReset: true,
        tip: "The meta-control, mirrored from the main window.\n"
            "0 = frozen drone: long overlapped grains, static read point.\n"
            "1 = pulsed scan: one grain per detected beat, reading through the\n"
            "loop in time, so the granulator's rhythm matches what you played.\n"
            "Everything below bends whatever this asks for."),
    (key: \granularAmp, label: "Level", spec: ControlSpec(0, 1, \lin, 0, 0.7),
        round: 0.01, default: 0.7,
        tip: "Level of the granular layer, summed with the engine before the\n"
            "master limiter. This used to be fixed at 0.7 — the layer arrived\n"
            "at whatever volume it arrived at and you balanced it in Live."),
    (key: \granularPitch, label: "Pitch", spec: ControlSpec(-24, 24, \lin, 1, 0),
        round: 1, unit: " st", default: 0,
        tip: "Grain transposition in semitones. The read pointer is untouched,\n"
            "so this pitches the layer WITHOUT changing how fast it moves\n"
            "through the loop — -12 is an octave-down pad under the same take."),
    (key: \granularDetune, label: "Detune", spec: ControlSpec(0, 12, 3, 0, 0),
        round: 0.01, unit: " st", default: 0,
        tip: "Random detune drawn afresh for EVERY grain, +/- this many\n"
            "semitones. Under ~0.2 it thickens like a chorus; past a few\n"
            "semitones the loop shatters into pitched confetti."),
    (key: \granularSize, label: "Grain size", spec: ControlSpec(0.125, 8, \exp, 0, 1),
        round: 0.01, unit: " x", default: 1,
        tip: "Grain length as a MULTIPLE of what morph asks for (0.4 s at the\n"
            "drone end, one beat at the pulsed end). Below about 0.2x grains\n"
            "stop carrying pitch and start reading as texture."),
    (key: \granularDensity, label: "Density", spec: ControlSpec(0.25, 4, \exp, 0, 1),
        round: 0.01, unit: " x", default: 1,
        tip: "Overlapping grain count, as a multiple of morph's (6 drone,\n"
            "1 pulsed). Thickness — and the CPU bill: this is the parameter\n"
            "that runs the server up, so the result is clipped at 16 overlaps."),
    (key: \granularSizeRand, label: "Size rand", spec: ControlSpec(0, 1, \lin, 0, 0.1),
        round: 0.01, default: 0.1,
        tip: "Warp1's windowRandRatio: how much grain LENGTH varies from grain\n"
            "to grain. A little breaks up the comb filtering that perfectly\n"
            "regular overlaps produce; 1.0 is, per the UGen's own docs,\n"
            "probably too random."),
    (key: \granularPosition, label: "Position", spec: ControlSpec(0, 1, \lin, 0, 0),
        round: 0.001, default: 0,
        tip: "Where in the loop the grains read from, as a fraction of the loop\n"
            "region. At the drone end this IS the freeze point — sweep it to\n"
            "walk the drone through the recording by hand. It wraps, so it can\n"
            "never read past the end of the loop."),
    (key: \granularScan, label: "Scan", spec: ControlSpec(-2, 2, \lin, 0, 0),
        round: 0.01, unit: " /loop", default: 0, bipolar: true,
        tip: "EXTRA passes through the loop per loop duration, ADDED to morph's\n"
            "own (0 at the drone end, 1 at the pulsed end).\n"
            "0 leaves morph in charge · small values drift a frozen drone\n"
            "· negative runs the read head backwards · -1 exactly freezes a\n"
            "fully pulsed scan · 1 doubles it."),
    (key: \granularSpray, label: "Spray", spec: ControlSpec(0, 500, 4, 0, 0),
        round: 0.1, unit: " ms", default: 0,
        tip: "Per-grain read-position randomness in milliseconds. Unlike the\n"
            "tiny jitter morph applies at the drone end, this survives at the\n"
            "pulsed end — it is how you loosen a locked grid without giving up\n"
            "the beat. It blurs across the loop seam on purpose.")
];

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
~granularEnvHints = [
    "Smooth and symmetrical, the default.",
    "Flat top, short fades. Thicker drones, harder pulses.",
    "Instant attack, long decay. Every grain becomes a little hit.",
    "Reversed percussive. Attacks are erased, so even a plucked loop smears into a pad."
];
~granularPaintEnv = { |val|
    ~granularEnvSeg !? { |s| ~guiSegSet.(s, val) };
    ~granularEnvHint !? { |t|
        if(t.isClosed.not) {
            t.string_((Looper.granularEnvNames[val] ? "") ++ ": " ++ (~granularEnvHints[val] ? ""));
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

~granularRefreshAll = {
    ~looper !? { |l|
        ~granularParams.do { |p| ~granularRefreshOne.(p[\key], l.perform(p[\key])) };
        ~granularPaintEnv.(l.granularEnv);
        ~granularPaintHeader.();
    };
};

// Neutral again: every bend back to its default, meta-control left alone.
~granularResetTweaks = {
    ~looper !? { |l|
        ~granularParams.do { |p|
            if(p[\noReset] != true) { l.perform(p[\key].asSetter, p[\default]) };
        };
        l.granularEnv = 0;
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
        .action_({ |sl|
            ~looper.perform(p[\key].asSetter, ~granularMapValue.(p, sl.value));
        }), ("looper." ++ p[\key]).asSymbol, p[\tip]);
    var text = ~guiMonoText.(~granularFormat.(p, val), 14, ~gt[\ink]).align_(\right);
    ~granularWidgets.put(p[\key], (slider: slider, label: text, param: p));
    VLayout(
        HLayout(~guiText.(p[\label], 14, ~gt[\mute]).toolTip_(p[\tip]), nil, text).margins_(0),
        slider
    ).spacing_(3).margins_(0)
};

// Look a param up by key so the sections below can be written in reading order
// rather than in table order.
~granularParamAt = { |key| ~granularParams.detect { |p| p[\key] == key } };
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
        menu: "Saved granular setups: morph plus every control below, including the window shape.\n"
            "Choosing one recalls it straight away — a running granular layer follows without stopping.",
        rescan: "Rescan your presets (granular/ in your megalooper folder) for files added or removed outside megalooper.",
        name: "File name for Save. Anything but letters and digits becomes '-', so \"Frozen Cathedral\"\n"
            "saves as frozen-cathedral.scd.",
        save: "Write every control here to granular/<name>.scd in your megalooper folder. Reads 'Overwrite' when the\n"
            "name matches an existing preset; that one needs a second click to confirm.",
        delete: "Delete the selected preset file. Click once to arm, again to confirm. The running\n"
            "granular layer keeps playing."
    ));
    // Mirrors the G key and the footswitch. The model is the authority:
    // pressing this with no loop recorded is refused and the tile stays dark.
    ~granularOnButton = ~midiTip.(LooperTile().cycles_(false).font_(~guiMono.(14, true))
        .fixedSize_(Size(96, 34)).border_(~gt[\grain])
        .action_({ ~looper.toggleGranular }),
        'looper.granular',
        "Toggle the granular layer (key G). Refused, and left off, while no loop is recorded.");
    // The window shapes, from Looper.granularEnvNames, one tile each.
    ~granularEnvSeg = ~guiSeg.(Looper.granularEnvNames,
        (gap: 6, height: 38, fill: \grain, ink: \onacc, base: \bg, font: ~guiSans.(15, true),
            action: { |i| ~looper.granularEnv = i }));
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

    pane.layout_(VLayout(
        ~guiBand.(\grain),
        View().fixedHeight_(58).layout_(HLayout(
            ~guiTitle.("Grains", 26),
            ~granularOnButton,
            ~mapTag.(LooperTile().states_([["Reset tweaks", ~gt[\mute], nil]]).cycles_(false)
                .font_(~guiSans.(14)).fixedHeight_(30).fixedWidth_(110)
                .action_({ ~granularResetTweaks.() }),
                'looper.granularResetTweaks',
                "Put every control below back to neutral, so morph alone shapes the sound again.\n"
                    "Morph itself is left where you performed it."),
            nil,
            [preset[\menu].minWidth_(220), stretch: 1]
        ).margins_([22, 0, 22, 0]).spacing_(14)),
        ~guiRule.(),
        View().layout_(VLayout(preset[\edit]).margins_([22, 10, 22, 10])),
        ~guiRule.(),
        HLayout(
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
        ).margins_(0).spacing_(0),
        ~guiRule.(),
        View().layout_(VLayout(
            ~guiCaption.("GRAIN WINDOW", 11),
            ~granularEnvSeg[\view],
            ~granularEnvHint
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
)
