// megalooper — Megalooper SA's mixer as Perform shows it: its levels and
// mutes (~buildSAPerformLevels), with Reset and Start with this, which keeps
// the levels for the rig (setup-sa.scd). The effects, Bias FX's window and the presets
// are on the Effects pane (gui-effects.scd), the drums on the Drums pane
// (gui-drums.scd) and their New loop switch on Perform; Setup's Rig page keeps
// only a line saying where they are.
//
// Loaded by boot.scd; defines only, runs nothing. ~buildRigPane calls
// ~buildSARigSection, which answers an empty, hidden view on a rig that is not
// SA. Reads ~rp and ~megaSA, so it is built after both exist. The Drums pane
// builds its two strips' rows with ~saLevelRow too, so a fader is one widget
// wherever it shows, and both follow MegaSA's \level and \mute, a drag on the
// other tab included.
(

// The slider the mouse is holding: its strip's \level does not move it under
// the hand (the readout still follows), so the drag and the model never fight
// over it. The slider, not the strip: the same strip's slider on the other
// tab is not under the hand, so it follows the drag like any other change.
~saLevelHeld = nil;



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

// ---- The meters and the master's light (2026-11-12) ------------------------------
// A rehearsal distorted with every lane up: the lanes summed past the master's
// clip. Each strip's peak as it reaches the master (MegaSA.meter, read off its
// stem fifteen times a second) shows as a bar under its fader, on its own
// scale, -60 to 0 dBFS: green, amber from -6, red from -1, where the master's
// safety limiter starts. After a peak the bar falls 24 dB a second, so a hit
// stays readable. The master's light, where the strips have their Mute: CLIP
// dark while all is well, LIMIT amber while the limiter turns the mix down,
// CLIP red when the clip still cut it (MegaSA.masterLight, held a second).
~saMeterShown = ~saMeterShown ? IdentityDictionary.new;
~saMeterFallDb = 24;
~saMeterDb = { |amp| (amp ? 0).max(1e-6).ampdb.max(-60) };
~saMeterColor = { |db| case { db >= -1 } { ~gt[\rec] } { db >= -6 } { ~gt[\armed] } { ~gt[\play] } };
~saDrawMeter = { |v, key|
    var b = v.bounds, db = ~saMeterShown[key] ? -60;
    Pen.fillColor = ~gt[\panel2];
    Pen.addRect(Rect(0, 0, b.width, b.height));
    Pen.fill;
    Pen.fillColor = ~saMeterColor.(db);
    Pen.addRect(Rect(0, 0, (b.width * ((db + 60) / 60).clip(0, 1)).round, b.height));
    Pen.fill;
};
// The tables showing strips now (Perform's, the Drums view's, the Synth view's).
~saMeterTables = { [~saPerformLevels, ~drumsLevels, ~synthLevels].reject(_.isNil) };
~saMeterViews = { |key|
    ~saMeterTables.().collect { |t| t[key] !? { |w| w[\meter] } }.reject { |v| v.isNil or: { v.isClosed } }
};
// A reading (MegaSA.onMeters, deferred): each strip's bar to its new peak or
// down by its fall, repainted where it moved by a quarter of a dB or more.
~saPaintMeters = { |m|
    var now = SystemClock.seconds, dt = (now - (~saMeterPaintedAt ? now)).clip(0, 1);
    ~saMeterPaintedAt = now;
    m !? { ~saLevelKeys.do { |k|
        var was = ~saMeterShown[k] ? -60;
        var db = ~saMeterDb.(m.meter(k)).max(was - (~saMeterFallDb * dt));
        ~saMeterShown[k] = db;
        if((db - was).abs >= 0.25) { ~saMeterViews.(k).do(_.refresh) };
    } };
};
~saLightWords = (ok: "CLIP", limit: "LIMIT", clip: "CLIP");
~saDrawMasterLight = { |v|
    var light = (~megaSA !? { |m| m.masterLight }) ? \ok, b = v.bounds;
    Pen.fillColor = switch(light, \clip, { ~gt[\rec] }, \limit, { ~gt[\armed] }, { ~gt[\panel2] });
    Pen.addRect(Rect(0, 0, b.width, b.height));
    Pen.fill;
    Pen.strokeColor = ~gt[\line];
    Pen.width = 1;
    Pen.addRect(Rect(0.5, 0.5, b.width - 1, b.height - 1));
    Pen.stroke;
    Pen.stringCenteredIn(~saLightWords[light] ? "CLIP", Rect(0, 0, b.width, b.height), ~guiMono.(12, true),
        switch(light, \clip, { Color.white }, \limit, { ~gt[\onacc] }, { ~gt[\mute] }));
};
~saPaintMasterLight = {
    ~saMeterTables.().do { |t| t[\master] !? { |w| w[\light] !? { |v| if(v.isClosed.not) { v.refresh } } } };
};

// One strip's row: its name, the dB slider with its meter under it, the
// readout and, for a strip with a mute (the master has none: muting it is the
// interface's knob), its Mute; the master has its light there instead.
// The widgets go into `table` for ~saPaintLevel, ~saPaintMute and the meters. The slider
// writes the model only; MegaSA's \level paints it back, here and on any other
// tab showing the same strip. The slider and the Mute are tagged for MIDI Map
// mode here, so a strip maps the same from either tab.
~saLevelRow = { |m, key, label, table, labelWidth = 130, tip, compact = false|
    var readout = ~guiMonoText.("", 13, ~gt[\ink]).fixedWidth_(70).align_(\right);
    var slider = ~mapTag.(~guiBar.(\ink, 16)
        .action_({ |sl| ~controlDo.(("sa.level." ++ key).asSymbol, \position, sl.value, \gui) })
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
            .action_({ |b| ~controlDo.(("sa.mute." ++ key).asSymbol, \set, b.value == 1, \gui) }),
            ("sa.mute." ++ key).asSymbol,
            "Silence this strip without moving its level; every tab showing it agrees. It also shows\n"
                "Muted while the strip is held: its plugin opening or loading its sound. A plugin whose\n"
                "sound did not load holds it until you unmute it.")
    };
    var meter = UserView().canFocus_(false).fixedHeight_(4)
        .drawFunc_({ |v| ~saDrawMeter.(v, key) })
        .toolTip_("The strip's peak as it reaches the master, -60 to 0 dB: amber from -6, red from -1,\n"
            "where the master's limiter starts. Turn the loudest strips down when the master's light\n"
            "comes on.");
    var light = if(key == \master) {
        UserView().canFocus_(false).fixedSize_(Size(70, 26))
            .drawFunc_({ |v| ~saDrawMasterLight.(v) })
            .toolTip_("The mix as it leaves: dark while all is well; LIMIT (amber) while the master's limiter\n"
                "turns it down, at -1 dB; CLIP (red) when a sudden peak still reached the clip, which\n"
                "distorts. It stays lit a second. Turn the loudest strips down, as their meters show.")
    };
    // The slider over its meter: no taller than the Mute beside them.
    var fader = VLayout(slider, meter).spacing_(3).margins_(0);
    table.put(key, (slider: slider, readout: readout, mute: mute, meter: meter, light: light));
    ~saPaintLevel.(table, key, m.level(key));
    ~saPaintMute.(table, key, ~saMutedOf.(m, key));
    // Compact (Perform's strips, side by side): the name and the readout
    // over the slider and its Mute.
    if(compact) {
        VLayout(
            HLayout(~guiLabel.(label.replace(":", ""), 14).toolTip_(tip ? ""), nil, readout).spacing_(6),
            HLayout([fader, stretch: 1], mute ?? { light ?? { View().fixedWidth_(70) } }).spacing_(8)
        ).spacing_(4)
    } {
        HLayout(
            ~guiLabel.(label.replace(":", ""), 14).fixedWidth_(labelWidth).toolTip_(tip ? ""),
            fader,
            readout,
            mute ?? { light ?? { View().fixedWidth_(70) } }
        ).spacing_(10)
    }
};

// The mixer's strips on Perform, side by side under the layers, with a table
// and controllers of their own, removed with the window (the shell fires
// every teardown from onClose) and before a rebuild. Setup has none: the
// Drums and Synth views have their own parts' strips.
~guiTeardowns = ~guiTeardowns ? ();
~saPerformLevels = IdentityDictionary.new;
~guiTeardowns[\saPerform] = {
    ~guiUnwatch.(\saPerform);
    ~megaSA !? { |m| m.onMeters = nil };
    ~saPerformLevels = IdentityDictionary.new;
};
// Start with this's mark: a dot while the levels differ from what a start on
// this rig begins with (setup-sa.scd, ~saLevelsDirty), as the effects' has.
~saLevelsKeepPaint = {
    ~saLevelsKeepButton !? { |b| if(b.isClosed.not) {
        b.states_([[if((~saLevelsDirty !? { |f| f.value }) == true) { "Start with this •" } { "Start with this" },
            ~gt[\ink], ~gt[\panel]]]) } };
};
// On LEVELS' caption line, at its right: Reset to megalooper's own, and Start
// with this, which keeps them for this rig (setup-sa.scd). Tiles no taller
// than the caption, and half the gap under it: any more height pushes the
// strips' Mutes off the bottom of a laptop's window, and a column beside
// Master widens the row and cuts the actions' words off.
~saLevelsButtons = {
    var small = { |label, width, tip, action|
        LooperTile().border_(~gt[\line]).font_(~guiSans.(11)).fixedHeight_(18).fixedWidth_(width).pad_(6)
            .cycles_(false).states_([[label, ~gt[\ink], ~gt[\panel]]]).toolTip_(tip).action_(action)
    };
    var own = ~saLevelKeys.select { |k| ~megaSA.level(k).notNil }.collect { |k|
        ~saStripLabels[k].replace(":", "") ++ " " ++ ~saLevelDb.(MegaSA.defaultLevels[k]) ++ " dB" }.join(", ");
    ~saLevelsKeepButton = small.("Start with this", 116,
        "Keep the levels as they are now for this rig (" ++ (~saLevelsRig.() ? "this one") ++ "): the next start\n"
            "on it begins with them instead of megalooper's own. The mutes are not kept.",
        { ~saKeepLevels.({ |ok, why| {
            if(ok) { ~guiSay.("Levels kept for " ++ ~saLevelsRig.() ++ ": the next start on it begins with them.") }
                { ~guiSay.("The levels were not kept: " ++ (why ? "the file was not written") ++ ".", \bad) };
            ~saLevelsKeepPaint.();
        }.defer }) });
    ~saLevelsKeepPaint.();
    ~saLevelsResetButton = small.("Reset", 56, "megalooper's own levels, now: " ++ own ++ ".\n"
        "Start with this keeps them for the next start too.", { ~saResetLevels.() });
    HLayout(~guiCaption.("LEVELS", 11), nil, ~saLevelsResetButton, ~saLevelsKeepButton).spacing_(8).margins_(0)
};
~buildSAPerformLevels = {
    var m = ~megaSA, keys;
    ~guiTeardowns[\saPerform].value;
    if(~rp.notNil and: { ~rp[\sa] == true } and: { m.notNil }) {
        keys = ~saLevelKeys.select { |k| m.level(k).notNil };
        ~guiWatch.(\saPerform, m, (
            level: { |obj, what, key, amp| ~saPaintLevel.(~saPerformLevels, key, amp); ~saLevelsKeepPaint.() },
            mute: { |obj, what, key| ~saPaintMute.(~saPerformLevels, key, ~saMutedOf.(m, key)) },
            hold: { |obj, what, key| ~saPaintMute.(~saPerformLevels, key, ~saMutedOf.(m, key)) },
            masterLight: { ~saPaintMasterLight.() }
        ));
        // Every reading paints the meters, here and on the Drums and Synth views.
        m.onMeters = { { ~saPaintMeters.(~megaSA) }.defer };
        View().background_(~gt[\panel]).layout_(VLayout(
            ~saLevelsButtons.(),
            HLayout(*keys.collect { |k|
                [~saLevelRow.(m, k, ~saStripLabels[k], ~saPerformLevels, nil, nil, true), stretch: 1] }).spacing_(28)
        ).margins_([16, 10, 16, 12]).spacing_(4))
    }
};

// Setup's Rig page, Megalooper SA's part: where things are. The levels and
// the drums' New loop switch are Perform's.
~buildSARigSection = {
    var view = View();
    var m = ~megaSA;
    if(~rp.notNil and: { ~rp[\sa] == true } and: { m.notNil }) {
        view.layout_(VLayout(
            ~guiHint.(if(m.drums.notNil) {
                "The levels and the drums' New loop are on Perform (1), the effects and their sounds on the FX view (3), "
                    "the rest of the drums on the Drums view (4)."
            } {
                "The levels are on Perform (1), the effects and their sounds on the FX view (3)."
            })
        ).margins_(0).spacing_(8));
    } {
        view.visible_(false);
    };
    view
};
)
