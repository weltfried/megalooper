// megalooper — the controls' laws and readouts: how a position along a
// control's travel maps to its value, and how a value reads. The panes draw
// their knobs and readouts with them; the MIDI controls (setup-miditargets.scd)
// drive and show the same controls with the same ones, so a knob on a
// controller and the mouse agree. They lived in the gui files of the panes
// that drew them, and MIDI borrowed them from there (docs/dev/architecture.md,
// 5, step 2): a rig with no window, or a check that left a pane out, had
// controls that quietly changed or vanished.
//
// Loaded by boot.scd through parts.scd, before every pane; defines only, runs
// nothing. Pure: specs, words and functions of their arguments.
(
// ---- Drawn by gui-const.scd -----------------------------------------------------
// Onset threshold: the header slider's scale and the law it moves on. Onsets'
// useful range is roughly 0.1–1; 2.0 leaves headroom for a very noisy input.
// The floor matches Looper's own clip, so the slider's ends ARE the model's.
~onsetThresholdMin = 0.01;

~onsetThresholdMax = 2.0;

// EXPONENTIAL, not linear. Threshold is a level, and the settings worth
// distinguishing are bunched at the bottom: on a linear 0–2 slider everything
// from "admits ghost onsets" to "just right" lived in the first tenth of the
// travel, so setting a low threshold by hand meant nudging one pixel at a time.
// Exponential spends the travel where the decisions are: a nudge of 1% of the
// travel moves the threshold by about 5% of its CURRENT value wherever you are,
// so the control feels the same at 0.05 as at 1.0. Measured against the old
// linear slider, 1% of travel at 0.1 moves 0.005 instead of 0.02 — four times
// finer — at the cost of being coarser above ~0.4, which is the end nobody
// tunes in. The default 0.5 sits at about three quarters of the travel.
//
// One spec, mapped by the slider, the controller CC and the label alike: a
// second copy of this law anywhere would drift, and a knob that disagreed with
// the slider under it is worse than either.
~onsetThresholdSpec = ControlSpec(~onsetThresholdMin, ~onsetThresholdMax, \exp);

// Autostart's start level (Looper.startLevelDb), in dB on the input meter's
// scale, whole dB: Perform's bar and its MIDI control move along it, and the
// meter's mark sits where the bar does (gui-status.scd, ~statusStartMark).
~startLevelSpec = ControlSpec(Looper.startLevelMinDb, Looper.startLevelMaxDb, \lin, 1);
~startLevelWords = { |db| db.round.asInteger.asString ++ " dB" };

// ---- Drawn by gui-analysis.scd --------------------------------------------------
// Note names in ABLETON's octave numbering (middle C = C3, so note 60 is C3 and
// the drum rack's first pad, 36, is C1). SC's own convention is an octave higher;
// matching Live is what makes the number in this window agree with the pad you
// are about to drop a sample onto.
~midiNoteName = { |num|
    var names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];
    names[num.asInteger % 12] ++ (num.asInteger.div(12) - 2)
};

// ---- Drawn by gui-sa.scd --------------------------------------------------------
// Levels in dB on the sliders, amplitudes in the model. -60 is as good as off.
~saLevelSpec = ControlSpec(-60, 6, \lin, 0.5, 0, " dB");

~saStripLabels = (guitar: "Instrument:", bass: "Instrument 2:", loop: "Loop:", drums: "Drums:", onsetKit: "Onset kit:",
    synth: "Synth:", master: "Master:");

~saLevelText = { |amp| (amp ? 0).ampdb.max(-60).round(0.5).asString ++ " dB" };

// ---- Drawn by gui-drums.scd -----------------------------------------------------
~drumsTrimSpec = ControlSpec(-24, 12, \lin, 0.5, 0, " dB");

~drumsReverbSpec = ControlSpec(0, 1, \lin, 0, 0.1508);

~drumsDbText = { |db|
    var v = (db ? 0).round(0.5);
    (if(v > 0) { "+" } { "" }) ++ v.asString
};

// A setting as the device shows it: a choice's label, On or Off, or the number
// in its units, with as many decimals as its size deserves.
~drumsFormat = { |p, val|
    var c = p[\choices], shown;
    case
    { val.isNil } { "—" }
    { p[\bool] == true } { if(val == true) { "On" } { "Off" } }
    { c.notNil } { (c.detect { |pair| pair[0] == val } !? { |pair| pair[1] }) ? val.asString }
    {
        shown = case
            { p[\spec].step >= 1 } { val.round.asInteger.asString }
            { val.abs >= 10 } { val.round(0.1).asString }
            { val.round(0.01).asString };
        (if((p[\centered] == true) and: { val > 0 }) { "+" } { "" }) ++ shown ++ (p[\units] ? "")
    }
};

// "42 HiHat Closed Carbon · F#1": the note, the slot's pad on it ("(empty)"
// where the kit in force has none, nothing with no kit), and the note in
// Live's octave numbering (~midiNoteName, gui-analysis.scd) last, so a menu
// too narrow for all of it cuts the least telling part.
~drumsNoteText = { |d, note, slot = \steps|
    var name = d !? { |dd| dd.padName(slot, note) };
    var kit = d !? { |dd| dd.kitFor(slot) };
    var noteName = ~midiNoteName !? { |f| f.(note) };
    [note.asString, name ?? { if(kit.notNil) { "(empty)" } }].reject(_.isNil).join(" ")
        ++ ((noteName !? { |n| " · " ++ n }) ? "")
};

~drumsNoteItems = { |d| (36..51).collect { |n| ~drumsNoteText.(d, n) } };

// The groups a layer trim is for: every group but the kit's main one (the one
// most pads play first). Kit-Carbon + layer gets one, for the KJ stand-ins
// under Kit-Carbon, whose balance Live's files cannot tell (both sources are
// normalised); a kit of one group gets none.
~drumsLayerGroups = { |kit|
    var counts = IdentityDictionary.new, main;
    if(kit.groupKeys.size < 2) { [] } {
        kit.pads.do { |pad|
            pad[\layers].first !? { |l| counts.put(l[\group], (counts[l[\group]] ? 0) + 1) };
        };
        main = counts.keys.asArray.sort.maxItem { |g| counts[g] };
        kit.groupKeys.reject { |g| g == main }
    }
};

// ---- Drawn by gui-effects.scd ---------------------------------------------------
// A knob's travel is 0..1. Every setting goes through its ControlSpec, so the
// curve (exp for frequencies and times) is the table's, not this file's.
~effectsUnmap = { |p, val| p[\spec].unmap(val) };

~effectsMap = { |p, pos| p[\spec].map(pos) };

// The readout: the setting in the units the Live device shows (`scale` turns
// seconds into ms, 0..1 into %), as many decimals as the size deserves.
~effectsFormat = { |p, val|
    var c = p[\choices];
    var shown, text;
    if(c.notNil) {
        c[c.collect { |pair| pair[0] }.indexIn(val)][1]
    } {
        shown = val * (p[\scale] ? 1);
        text = case
            { p[\spec].step >= 1 and: { (p[\scale] ? 1) == 1 } } { shown.round.asInteger.asString }
            { shown.abs >= 100 } { shown.round.asInteger.asString }
            { shown.abs >= 10 } { shown.round(0.1).asString }
            { shown.round(0.01).asString };
        text ++ (p[\units] ? "")
    }
};

// ---- Drawn by gui-synth.scd -----------------------------------------------------
// A Wave synth setting as its readout says it: a choice by its name, else
// the value times its scale (seconds as ms, 0..1 as %), in its units.
~synthFormat = { |p, v|
    var x;
    case
    { v.isNil } { "—" }
    { p[\choices].notNil } { (p[\choices].detect { |c| c[0] == v } !? { |c| c[1] }) ? v.asString }
    {
        x = v * (p[\scale] ? 1);
        (if((p[\spec].step >= 1) or: { x.abs >= 100 }) { x.round.asInteger } { if(x.abs >= 10) { x.round(0.1) } { x.round(0.01) } }).asString
            ++ (p[\units] ? "")
    }
};
)
