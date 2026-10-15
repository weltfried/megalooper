// The granular window's parameter table against the model it drives.
//
// Three definitions of every granular parameter's range have to agree: the
// GUI's ControlSpec (what a slider can reach), the preset table's lo/hi (what
// can be saved and recalled), and the setter's own clip (what the model will
// hold). They are deliberately DIFFERENT — the slider offers a narrower,
// musically useful span — but they must NEST, or a value is reachable somewhere
// and unreachable somewhere else and the knob stops matching the sound.
//
// scripts/check.scd covers the other half of this contract: that every row
// names a getter and setter Looper actually has, and that each default is
// reachable on its slider.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-ranges");

{
var l, params;

// gui-granular.scd only DEFINES (that is the whole point of the scripts/ split),
// so loading it here is side-effect free — no window opens.
if(~granularParams.isNil) {
    (thisProcess.nowExecutingPath.dirname.dirname +/+ "gui-granular.scd").load;
};
l = ~tLooper.();
params = ~granularParams;

~tAssert.("the parameter table loaded", params.notNil and: { params.notEmpty },
    "~granularParams is " ++ params);

~tEq.("every granular parameter is saveable",
    params.size, Looper.granularPresetFields.size);

params.do { |p|
    var key = p[\key];
    var spec = p[\spec];
    var field = Looper.granularPresetFields.detect { |f| f[1] == key };
    var lo, hi;

    ~tAssert.(key ++ ": has a preset field", field.notNil,
        "no granularPresetFields row names " ++ key);

    if(field.notNil and: { spec.notNil }) {
        lo = field[2]; hi = field[3];

        // Slider range must fit inside the saveable range, or a position the
        // player can dial is a position a preset cannot record.
        ~tAssert.(key ++ ": slider range fits the saveable range",
            (spec.minval >= lo) and: { spec.maxval <= hi },
            "slider " ++ spec.minval ++ ".." ++ spec.maxval
                ++ " vs saveable " ++ lo ++ ".." ++ hi);

        // And the setter — the last word on what the model holds — must accept
        // both slider endpoints unchanged. This is the assertion that catches a
        // clip tightened in the class without the table being told.
        l.perform(key.asSetter, spec.minval);
        ~tNear.(key ++ ": the setter accepts the slider's minimum",
            l.perform(key), spec.minval, 1e-6);
        l.perform(key.asSetter, spec.maxval);
        ~tNear.(key ++ ": the setter accepts the slider's maximum",
            l.perform(key), spec.maxval, 1e-6);

        // The saveable endpoints must survive the setter too, or recalling an
        // older preset saved at the edge would silently move the value.
        l.perform(key.asSetter, lo);
        ~tNear.(key ++ ": the setter accepts the saveable minimum",
            l.perform(key), lo, 1e-6);
        l.perform(key.asSetter, hi);
        ~tNear.(key ++ ": the setter accepts the saveable maximum",
            l.perform(key), hi, 1e-6);
    };
};

// The slider position <-> value mapping must be a consistent pair. Scan uses a
// custom symmetric-squared law instead of a ControlSpec (a bipolar exp warp is
// impossible), so it is the one most likely to drift out of step.
//
// The invariant is idempotence in VALUE, not in position. Pitch's spec quantises
// to whole semitones on purpose, so a position maps to a rounded value and back
// to a slightly different position — that is correct behaviour, not drift. What
// must hold is that rendering a value onto the slider and reading it back gives
// the SAME value, or the knob would creep every time a view refreshed.
params.do { |p|
    ~tCheck.(p[\key] ++ ": value survives unmap/map", {
        var worst = 0;
        (0, 0.05 .. 1).do { |pos|
            var val = ~granularMapValue.(p, pos);
            var back = ~granularMapValue.(p, ~granularUnmapValue.(p, val));
            worst = max(worst, (back - val).abs);
        };
        if(worst > 1e-6) {
            Error("worst value drift " ++ worst
                ++ (if(p[\bipolar] == true) { " (bipolar law)" } { "" })).throw
        };
        worst
    });
};

// Round-tripping the other way: a VALUE the model holds must map back to a
// position on the slider, so the window can render whatever a preset recall or
// a MIDI CC put there.
params.do { |p|
    var vals = [p[\spec].minval, p[\default], p[\spec].maxval];
    ~tAssert.(p[\key] ++ ": model values map onto the slider",
        vals.every { |v| ~granularUnmapValue.(p, v).inclusivelyBetween(0, 1) },
        vals.collect { |v| ~granularUnmapValue.(p, v).round(1e-4) }.asString);
};

// ---- the onset threshold -------------------------------------------------
// Not a granular parameter, but the same contract and the same failure mode:
// one law shared by the header slider, MIDI CC 7 and the label, against a clip
// that lives in Looper. Unlike the granular table this one does NOT nest — the
// slider's ends ARE the model's, so every reachable threshold is settable by
// hand, and that is worth asserting rather than assuming.
if(~onsetThresholdSpec.isNil) {
    (thisProcess.nowExecutingPath.dirname.dirname +/+ "gui-const.scd").load;
};
~tAssert.("the threshold spec loaded", ~onsetThresholdSpec.notNil,
    "~onsetThresholdSpec is nil");
~tEq.("the slider's floor is the model's clip floor",
    ~onsetThresholdSpec.minval, 0.01);
~tEq.("the slider's ceiling is the model's clip ceiling",
    ~onsetThresholdSpec.maxval, 2.0);
~tCheck.("the threshold clips to exactly the slider's ends", {
    var lo = ~tLooper.(), hi = ~tLooper.();
    lo.onsetThreshold = -5; hi.onsetThreshold = 99;
    if(lo.onsetThreshold != ~onsetThresholdSpec.minval) {
        Error("floor: model " ++ lo.onsetThreshold
            ++ " vs slider " ++ ~onsetThresholdSpec.minval).throw
    };
    if(hi.onsetThreshold != ~onsetThresholdSpec.maxval) {
        Error("ceiling: model " ++ hi.onsetThreshold
            ++ " vs slider " ++ ~onsetThresholdSpec.maxval).throw
    };
    [lo.onsetThreshold, hi.onsetThreshold]
});
// Exponential, not linear: the point of the curve is that the low end gets
// most of the travel. Asserted as a property rather than by pinning numbers —
// the midpoint of an exponential span is its geometric mean, far below the
// arithmetic one — so retuning the ends cannot silently flip it back to linear.
~tAssert.("the threshold travel is exponential, not linear",
    ~onsetThresholdSpec.map(0.5) < (~onsetThresholdSpec.maxval * 0.25),
    "midpoint is " ++ ~onsetThresholdSpec.map(0.5).round(1e-4)
        ++ ", which is where a linear-ish law would put it");
~tAssert.("...so a low threshold gets more travel than a high one",
    (~onsetThresholdSpec.unmap(0.1) - ~onsetThresholdSpec.unmap(0.05))
        > (~onsetThresholdSpec.unmap(1.05) - ~onsetThresholdSpec.unmap(1.0)),
    "0.05->0.1 must span more slider than 1.0->1.05");
// A repaint must not creep the value: the SimpleController renders the model
// onto the slider on every change, so unmap/map has to be the identity.
~tCheck.("a threshold survives unmap/map, so a repaint cannot nudge it", {
    var worst = 0;
    [0.01, 0.03, 0.05, 0.1, 0.25, 0.5, 0.75, 1.0, 1.5, 2.0].do { |v|
        var back = ~onsetThresholdSpec.map(~onsetThresholdSpec.unmap(v));
        worst = max(worst, (back - v).abs);
    };
    if(worst > 1e-9) { Error("worst drift " ++ worst).throw };
    worst
});
// The whole CC range has to land inside the model's clip, or the top of the
// knob would sit on a value the slider cannot show.
~tAssert.("every MIDI CC 7 step lands on a settable threshold",
    (0..127).every { |cc|
        ~onsetThresholdSpec.map(cc / 127)
            .inclusivelyBetween(~onsetThresholdSpec.minval, ~onsetThresholdSpec.maxval)
    },
    "CC 0 -> " ++ ~onsetThresholdSpec.map(0)
        ++ ", CC 127 -> " ++ ~onsetThresholdSpec.map(1));
}.value;
