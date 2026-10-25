// megalooper — Megalooper SA's section of the Rig pane: the mixer's levels and
// mutes. The effects, Bias FX's window and the presets moved to the Effects
// pane (gui-effects.scd), the drums to the Drums pane (gui-drums.scd); what
// stays here is set once per rig, like the rest of the Rig pane.
//
// Loaded by boot.scd; defines only, runs nothing. ~buildRigPane calls
// ~buildSARigSection, which answers an empty, hidden view on a rig that is not
// SA. Reads ~rp and ~megaSA, so it is built after both exist. The Drums pane
// builds its two strips' rows with ~saLevelRow too, so a fader is one widget
// wherever it shows, and both follow MegaSA's \level and \mute, a drag on the
// other tab included.
(
// Levels in dB on the sliders, amplitudes in the model. -60 is as good as off.
~saLevelSpec = ControlSpec(-60, 6, \lin, 0.5, 0, " dB");

// The slider the mouse is holding: its strip's \level does not move it under
// the hand (the readout still follows), so the drag and the model never fight
// over it. The slider, not the strip: the same strip's slider on the other
// tab is not under the hand, so it follows the drag like any other change.
~saLevelHeld = nil;

~saStripLabels = (guitar: "Instrument:", bass: "Bass:", loop: "Loop:", drums: "Drums:", onsetKit: "Onset kit:",
    synth: "Synth:", master: "Master:");

~saLevelText = { |amp| (amp ? 0).ampdb.max(-60).round(0.5).asString ++ " dB" };

// Paint a row of `table` (strip -> (slider:, readout:, mute:)) from the model.
~saPaintLevel = { |table, key, amp|
    table[key] !? { |w|
        if(w[\slider].isClosed.not) {
            if(w[\slider] !== ~saLevelHeld) {
                w[\slider].value = ~saLevelSpec.unmap((amp ? 0).ampdb.max(-60));
            };
            w[\readout].string_(~saLevelText.(amp));
        };
    };
};

// What a strip's Mute shows: what the strip gets, the player's mute or a hold
// (MegaSA.muted; a plugin opening, its bank loading, its sound not loaded).
// An Event standing in for MegaSA (the checks) answers nil to muted.
~saMutedOf = { |m, key| m !? { (m.muted(key) ? m.mute(key)) } };

~saPaintMute = { |table, key, flag|
    table[key] !? { |w|
        w[\mute] !? { |b| if(b.isClosed.not) { b.value = (flag == true).binaryValue } };
    };
};

// One strip's row: its name, the dB slider, the readout and, for a strip with
// a mute (the master has none: muting it is the interface's knob), its Mute.
// The widgets go into `table` for ~saPaintLevel and ~saPaintMute. The slider
// writes the model only; MegaSA's \level paints it back, here and on any other
// tab showing the same strip. The slider and the Mute are tagged for MIDI Map
// mode here, so a strip maps the same from either tab.
~saLevelRow = { |m, key, label, table, labelWidth = 130, tip, compact = false|
    var readout = ~guiMonoText.("", 13, ~gt[\ink]).fixedWidth_(70).align_(\right);
    var slider = ~mapTag.(~guiBar.(\ink, 16)
        .action_({ |sl| m.setLevel(key, ~saLevelSpec.map(sl.value).dbamp) })
        .mouseDownAction_({ |sl| ~saLevelHeld = sl; nil })
        .mouseUpAction_({ |sl|
            if(~saLevelHeld === sl) { ~saLevelHeld = nil };
            // Now the hand is off it, show where the level really is.
            ~saPaintLevel.(table, key, m.level(key));
            nil
        }),
        ("sa.level." ++ key).asSymbol, tip);
    var mute = if(m.mute(key).notNil) {
        ~mapTag.(LooperTile().border_(~gt[\line]).font_(~guiSans.(13)).fixedSize_(Size(70, 26))
            .states_([["Mute", ~gt[\ink], nil], ["Muted", Color.white, ~gt[\rec]]])
            .action_({ |b| m.setMute(key, b.value == 1) }),
            ("sa.mute." ++ key).asSymbol,
            "Silence this strip without moving its level; every tab showing it agrees. It also shows\n"
                "Muted while the strip is held: its plugin opening or loading its sound. A plugin whose\n"
                "sound did not load holds it until you unmute it.")
    };
    table.put(key, (slider: slider, readout: readout, mute: mute));
    ~saPaintLevel.(table, key, m.level(key));
    ~saPaintMute.(table, key, ~saMutedOf.(m, key));
    // Compact (Perform's strips, side by side): the name and the readout
    // over the slider and its Mute.
    if(compact) {
        VLayout(
            HLayout(~guiLabel.(label.replace(":", ""), 14).toolTip_(tip ? ""), nil, readout).spacing_(6),
            HLayout([slider, stretch: 1], mute ?? { View().fixedWidth_(70) }).spacing_(8)
        ).spacing_(4)
    } {
        HLayout(
            ~guiLabel.(label.replace(":", ""), 14).fixedWidth_(labelWidth).toolTip_(tip ? ""),
            slider,
            readout,
            mute ?? { View().fixedWidth_(70) }
        ).spacing_(10)
    }
};

// The controllers this section hangs on the model, removed with the window
// (the shell fires every teardown from onClose) and before a rebuild.
~saRigLevels = IdentityDictionary.new;
~guiTeardowns = ~guiTeardowns ? ();
~guiTeardowns[\sa] = {
    (~saGuiControllers ? []).do(_.remove);
    ~saGuiControllers = [];
    ~saRigLevels = IdentityDictionary.new;
};

// The same strips on Perform, side by side under the layers, with a table and
// controllers of their own (the Setup section's teardown runs at its build).
~saPerformLevels = IdentityDictionary.new;
~guiTeardowns[\saPerform] = {
    (~saPerformControllers ? []).do(_.remove);
    ~saPerformControllers = [];
    ~saPerformLevels = IdentityDictionary.new;
};
~buildSAPerformLevels = {
    var m = ~megaSA, keys;
    ~guiTeardowns[\saPerform].value;
    if(~rp.notNil and: { ~rp[\sa] == true } and: { m.notNil }) {
        keys = [\guitar, \bass, \loop, \drums, \onsetKit, \synth, \master].select { |k| m.level(k).notNil };
        ~saPerformControllers = [
            SimpleController(m)
                .put(\level, { |obj, what, key, amp| { ~saPaintLevel.(~saPerformLevels, key, amp) }.defer })
                .put(\mute, { |obj, what, key| { ~saPaintMute.(~saPerformLevels, key, ~saMutedOf.(m, key)) }.defer })
                .put(\hold, { |obj, what, key| { ~saPaintMute.(~saPerformLevels, key, ~saMutedOf.(m, key)) }.defer })
        ];
        View().background_(~gt[\panel]).layout_(VLayout(
            ~guiCaption.("LEVELS · ALSO ON SETUP", 11),
            HLayout(*keys.collect { |k|
                [~saLevelRow.(m, k, ~saStripLabels[k], ~saPerformLevels, nil, nil, true), stretch: 1] }).spacing_(28)
        ).margins_([16, 10, 16, 12]).spacing_(8))
    }
};

// Whether a new loop starts with the drums playing or off (PC 17 switched
// off as the take starts: the transport still runs, PC 17 brings them in on
// the grid). Kept in settings.json (~saDrumsNewLoopSet).
~saNewLoopRow = { |d|
    var tip = "What the drums do when you record a new loop.\n"
        "Drums play: they start with the loop, as in Live's set.\n"
        "Drums off: they keep time but stay silent until you switch them on\n"
        "(PC 17, or the switch on the Drums view). Overdubs leave them as they are.";
    ~saNewLoopSeg = ~guiSeg.(["Drums play", "Drums off"], (height: 28, font: ~guiSans.(13),
        action: { |i| ~saDrumsNewLoopSet.(i == 1) }));
    ~guiSegSet.(~saNewLoopSeg, (d.newLoopOff == true).binaryValue);
    HLayout(
        ~guiLabel.("New loop", 14).fixedWidth_(~rigLabelWidth ? 130).toolTip_(tip),
        ~saNewLoopSeg[\view].fixedWidth_(220).toolTip_(tip),
        nil
    ).spacing_(10)
};

~buildSARigSection = {
    var view = View();
    var m = ~megaSA;
    var keys;
    ~guiTeardowns[\sa].value;
    if(~rp.notNil and: { ~rp[\sa] == true } and: { m.notNil }) {
        // In mixer order, the master last. The drums' two strips are there
        // only on a MegaSA that has them, the bass's on a rig with its input.
        keys = [\guitar, \bass, \loop, \drums, \onsetKit, \synth, \master].select { |k| m.level(k).notNil };
        view.layout_(VLayout(*(
            [~guiCaption.("MEGALOOPER SA · LEVELS", 11)]
            ++ keys.collect { |k| ~saLevelRow.(m, k, ~saStripLabels[k], ~saRigLevels, ~rigLabelWidth ? 130) }
            ++ (m.drums !? { |d| [~saNewLoopRow.(d)] } ? [])
            ++ [~guiHint.(if(keys.includes(\drums)) {
                "The effects and their sounds are on the FX view (3), the drums on the Drums view (4)."
            } {
                "The effects and their sounds are on the FX view (3)."
            })]
        )).margins_(0).spacing_(8));
        // A level moved on another tab (the Drums tab's strips) moves it here.
        // MegaSA unmutes the guitar once Bias FX is open (the window may
        // already be up by then), and mutes it while a preset loads its bank:
        // both have to show here.
        ~saGuiControllers = [
            SimpleController(m)
                .put(\level, { |obj, what, key, amp|
                    { ~saPaintLevel.(~saRigLevels, key, amp) }.defer
                })
                .put(\mute, { |obj, what, key, flag|
                    { ~saPaintMute.(~saRigLevels, key, ~saMutedOf.(m, key)) }.defer
                })
                .put(\hold, { |obj, what, key|
                    { ~saPaintMute.(~saRigLevels, key, ~saMutedOf.(m, key)) }.defer
                })
        ];
    } {
        view.visible_(false);
    };
    view
};
)
