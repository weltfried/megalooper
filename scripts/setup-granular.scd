// megalooper — the granular layer's parameters: the table every one of its
// controls comes from, their laws and readouts, and Reset tweaks. Moved out of
// the Grains pane (gui-granular.scd, which builds its rows from it), because
// MIDI (setup-miditargets.scd), the AI apps (setup-remote.scd) and the tests
// read it too, and none of them should need a pane loaded to know what a
// granular setting is (docs/dev/architecture.md, 5, step 2).
//
// Loaded by boot.scd through parts.scd; defines only, runs nothing.
(
// Slider position (0..1) <-> parameter value. Everything goes through its
// ControlSpec except the bipolar ones: Scan's useful range is a hair either
// side of zero (0.05 extra passes per loop is already an audible drift), and a
// plain linear +/-2 slider buries that inside one pixel of centre. Those get a
// squared, symmetric law instead, which spreads the small values out and still
// reaches the ends.
~granularMapValue = { |p, v|
    var x;
    if(p[\bipolar] == true) {
        x = (v * 2) - 1;
        x.sign * x.squared * p[\spec].maxval
    } {
        p[\spec].map(v)
    };
};

~granularUnmapValue = { |p, val|
    var x;
    if(p[\bipolar] == true) {
        x = (val / p[\spec].maxval).clip(-1, 1);
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
// Every row of the Grains pane comes from here, and so do its MIDI controls
// (setup-miditargets.scd), the AI's grains (setup-remote.scd) and the window's
// wiring (gui-wiring.scd): adding a parameter means adding one entry, a
// matching setter on Looper and a SynthDef arg, and nothing else.
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
    (key: \granularAmp, label: "Level", spec: ControlSpec(0, 1, \lin, 0, 0.3),
        round: 0.01, default: 0.3,
        tip: "Level of the granular layer, summed with the engine before the\n"
            "master limiter. 0.3 by default."),
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

// Look a param up by key so the sections below can be written in reading order
// rather than in table order.
~granularParamAt = { |key| ~granularParams.detect { |p| p[\key] == key } };

// Neutral again: every bend back to its default, meta-control left alone.
~granularResetTweaks = {
    ~looper !? { |l|
        ~granularParams.do { |p|
            if(p[\noReset] != true) { l.perform(p[\key].asSetter, p[\default]) };
        };
        l.granularEnv = 0;
        l.granularFollowChords = false;
    };
};
)
