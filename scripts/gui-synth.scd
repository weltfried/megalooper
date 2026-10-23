// The Synth view (docs/dev/synth.md, Phase 3): Megalooper SA's note
// sequencer (MegaSANoteSeq, run by MegaSADrums on the drums' grid) and the
// Wave synth it plays (MegaSAWave), key 7, its tab after Drums.
//
//   the header      the sequencer's switch (its footswitch: sa.synth.on),
//                   Random and Reset for the sound, Start with this (Keep)
//   the preset bar  a pattern and its sound together (sa/synth-presets/)
//   Sequence        its rate, swing, how many steps, where it starts again,
//                   its direction and steps, the scale
//   the steps       sixteen steps on or off, the sequence's steps lit
//   the lanes       Pitch, Octave, Velocity, Length, Shift, Ratchet,
//                   Condition: sixteen values each, drawn as bars (from the
//                   middle for those either side of 0); each lane follows
//                   the sequence's steps, or (Own) its own first, last and
//                   direction; its tools: Random, rotate, nudge, reset
//   Wave synth      every setting, a knob (or a menu) each, in groups
//   Mix             the Synth strip
//
// Everything paints from the model (~synthPaint, the lane strips' draw
// functions) when the model says it changed: the sequencer and the synth
// notify, so MIDI, presets and the other views all show here.
(
~synthLabelWidth = 96;
~synthCellWidth = 46;
~synthLaneHeight = 40;
~synthStepHeight = 26;
~synthKnobWidth = 66;
~synthPlayheadHz = 20;

~synthModel = { ~megaSA !? { |m| m.drums } };
~synthWave = { ~megaSA !? { |m| if(m.respondsTo(\wave)) { m.wave } } };
~synthPresetModel = { ~megaSA };

~synthLaneLabels = (pitch: "Pitch", octave: "Octave", velocity: "Velocity", length: "Length", shift: "Shift",
    ratchet: "Ratchet", condition: "Condition");
~synthLaneTips = (
    pitch: "Semitones above the root (-12..12). With Scale on, a pitch outside the scale plays the\n"
        "scale's note below it.",
    octave: "Octaves up or down (-3..3), on top of the pitch.",
    velocity: "How hard the step plays (0..127); 0 plays nothing.",
    length: "How long the note is held, in % of a step. 100 % runs into the next note: legato, with\n"
        "no new attack and, with Glide, a slide.",
    shift: "How late the note is, in % of a step.",
    ratchet: "The step played this many more times, evenly through it (0..6).",
    condition: "When the step plays, counting the passes of this lane: 0 or 1 always; 2 every second\n"
        "pass (the first included), 3 every third...; -1 never; -2 all but every second, -3 all but\n"
        "every third..."
);
~synthDirectionLabels = (forward: "Forward", backward: "Backward", alternate: "Alternate", snake: "Snake",
    random: "Random");
~synthRestartLabels = (bar: "Every bar", loop: "Every loop", off: "Never");

~guiTeardowns = ~guiTeardowns ? ();
~synthGen = (~synthGen ? 0) + 1;
~synthControllers = ~synthControllers ? [];
~guiTeardowns[\synth] = {
    ~synthControllers.do(_.remove);
    ~synthControllers = [];
    ~synthWidgets = IdentityDictionary.new;
    ~synthLanes = IdentityDictionary.new;
    ~synthHeld = nil;
    ~synthPlayhead = nil;
    ~synthGen = ~synthGen + 1;
};
~synthWidgets = IdentityDictionary.new;
~synthLanes = IdentityDictionary.new;

// ---- Presets ---------------------------------------------------------------------
~definePresetFamily.(\saSynth, (
    label:      "Synth",
    statusIdle: "Pick a preset to recall it · Save keeps the pattern and the sound together",
    dirKey:     \saSynthPresetDir,
    names:      \synthPresetNames,
    slug:       \synthPresetSlug,
    save:       \saveSynthPreset,
    load:       \loadSynthPreset,
    delete:     \deleteSynthPreset,
    model:      { ~synthPresetModel.() },
    ext:        ".json"
));

// ---- Readouts --------------------------------------------------------------------
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

// ---- Model -> view ---------------------------------------------------------------
~synthPaint = { |key|
    var w = ~synthWidgets[key], view, v, i, en;
    if(w.notNil) {
        view = w[\view];
        if(view.notNil and: { view.isClosed.not }) {
            v = w[\get].value;
            switch(w[\kind],
                \knob, { if((~synthHeld != key) and: { v.notNil }) { view.value = w[\spec].unmap(v) } },
                \menu, {
                    i = w[\index].value(v);
                    if(i.notNil and: { i >= 0 } and: { i < view.items.size }) { view.value = i };
                },
                \button, { view.value = (v == true).binaryValue },
                \number, { if(v.notNil) { view.value = v } },
                \text, { view.string_((v ? "").asString) }
            );
            w[\readout] !? { |r| r.string_(w[\format].value(v)) };
            w[\enabled] !? { |f|
                en = f.value == true;
                view.enabled_(en);
                w[\readout] !? { |r| r.stringColor_(if(en) { ~guiInk } { ~gt[\mute] }) };
            };
        };
    };
};
~synthPaintAll = { ~synthWidgets.keys.do { |k| ~synthPaint.(k) }; ~synthRefreshLanes.() };
~synthRefreshLanes = {
    ~synthLanes.do { |v| if(v.isClosed.not) { ~synthLaneRefreshes = (~synthLaneRefreshes ? 0) + 1; v.refresh } };
};
~synthRefreshLane = { |lane| ~synthLanes[lane] !? { |v| if(v.isClosed.not) { v.refresh } } };

~synthVisible = { ~guiStack.isNil or: { ~guiStack.index == ~guiTabIndex.(\synth) } };
~synthPollPlayhead = { |force = false|
    var d = ~synthModel.(), ph;
    if(d.notNil and: { ~synthVisible.() }) { ph = if(d.notesOn) { d.notePlayheadAt } };
    if((force == true) or: { ph != ~synthPlayhead }) {
        ~synthPlayhead = ph;
        ~synthRefreshLanes.();
    };
};
~synthStartPlayhead = { |gen|
    AppClock.sched(0, {
        if((gen != ~synthGen) or: { ~guiWindow.isNil } or: { ~guiWindow.isClosed }
            or: { ~synthPane.isNil } or: { ~synthPane.isClosed }) { nil } {
            ~synthPollPlayhead.();
            ~synthPlayheadHz.reciprocal
        };
    });
};

// ---- Small widgets ---------------------------------------------------------------
~synthRowLabel = { |str, tip| ~guiText.(str, 14, ~gt[\mute]).fixedWidth_(~synthLabelWidth).toolTip_(tip ? "") };
~synthButton = { LooperTile().border_(~gt[\line]).font_(~guiSans.(13)).fixedHeight_(28).pad_(6) };
~synthMenu = { |m| m.canFocus_(false).font_(~guiSans.(13)).background_(~gt[\panel]).stringColor_(~gt[\ink]) };
~synthBox = { |nb| nb.canFocus_(false).font_(~guiMono.(13, true)).background_(~gt[\panel])
    .normalColor_(~gt[\ink]).align_(\center) };
~synthTitle = { |str| ~guiMonoText.(str.toUpper, 11, ~gt[\mute]) };
~synthRule = { View().layout_(VLayout(~guiRule.()).margins_([0, 8, 0, 8])) };
// A tool: one click, one action, no state.
~synthTool = { |label, width, tip, action|
    ~synthButton.().fixedSize_(Size(width, 26)).cycles_(false).font_(~guiSans.(12))
        .states_([[label, ~gt[\ink], ~gt[\panel]]]).toolTip_(tip ? "").action_(action)
};

// A pattern setting as a menu (`items`: [value, label] pairs).
~synthSettingMenu = { |name, items, width, tip, id|
    var menu = ~synthMenu.(PopUpMenu()).fixedWidth_(width).items_(items.collect(_[1]))
        .action_({ |mn| ~synthModel.() !? { |d| d.setNoteSetting(name, items[mn.value][0]) } });
    if(id.notNil) { ~mapTag.(menu, id, tip) } { menu.toolTip_(tip ? "") };
    ~synthWidgets.put(name, (kind: \menu, view: menu, get: { ~synthModel.() !? { |d| d.notes[name] } },
        index: { |v| items.collect(_[0]).indexOfEqual(v) }));
    menu
};
~synthSettingButton = { |name, label, width, tip|
    var b = ~synthButton.().fixedWidth_(width)
        .states_([[label, ~gt[\mute], nil], [label, ~gt[\onacc], ~gt[\synth]]]).toolTip_(tip ? "")
        .action_({ |bt| ~synthModel.() !? { |d| d.setNoteSetting(name, bt.value == 1) } });
    ~synthWidgets.put(name, (kind: \button, view: b, get: { ~synthModel.() !? { |d| d.notes[name] } }));
    b
};
~synthSettingBox = { |name, lo, hi, width, tip|
    var nb = ~synthBox.(NumberBox()).fixedWidth_(width).clipLo_(lo).clipHi_(hi)
        .step_(1).scroll_step_(1).decimals_(0).toolTip_(tip ? "")
        .action_({ |n| ~synthModel.() !? { |d| d.setNoteSetting(name, n.value.round.asInteger) } });
    ~synthWidgets.put(name, (kind: \number, view: nb, get: { ~synthModel.() !? { |d| d.notes[name] } }));
    nb
};

// One knob: label, knob, readout, as the Drums view's (gui-drums.scd).
// c: (key:, id:, label:, spec:, get:, set:, default:, format:, tip:, centered:).
~synthKnobCell = { |c|
    var readout = StaticText().align_(\center).font_(~guiMono.(11, true)).stringColor_(~guiInk);
    var knob = Knob().canFocus_(false).mode_(\vert)
        .color_([~gt[\panel2], ~gt[\synth], ~gt[\bg], ~gt[\ink]])
        .fixedSize_(Size(32, 32))
        .centered_(c[\centered] == true)
        .action_({ |k| c[\set].value(c[\spec].map(k.value)) })
        .mouseDownAction_({ |k, x, y, mods, button, clicks|
            ~synthHeld = c[\key];
            if(clicks == 2) { c[\set].value(c[\default] ? c[\spec].default); true } { nil }
        })
        .mouseUpAction_({ |k| ~synthHeld = nil; ~synthPaint.(c[\key]); nil });
    if(c[\id].notNil) { ~mapTag.(knob, c[\id], c[\tip] ? "") } { knob.toolTip_(c[\tip] ? "") };
    ~synthWidgets.put(c[\key], (kind: \knob, view: knob, readout: readout, get: c[\get],
        spec: c[\spec], format: c[\format]));
    ~synthPaint.(c[\key]);
    View().fixedWidth_(~synthKnobWidth).layout_(VLayout(
        StaticText().string_(c[\label]).align_(\center).toolTip_(c[\tip] ? "").font_(~guiSans.(12, true))
            .stringColor_(~gt[\ink]),
        HLayout(nil, knob, nil), readout).margins_(1).spacing_(1))
};

// ---- The header --------------------------------------------------------------------
~synthKeep = {
    if(~saKeepSynth.isNil) {
        ~presetSetStatus.(\saSynth, "Nothing keeps the synth in this build (no ~saKeepSynth in setup-sa.scd).", true);
    } {
        if(~saKeepSynth.value == true) {
            ~presetSetStatus.(\saSynth, "Kept: the next boot starts with this pattern and this sound.");
        } {
            ~presetSetStatus.(\saSynth, "The synth was not kept: see the post window.", true);
        };
    };
};
~synthHeaderRow = {
    var on = ~midiWatch.(~mapTag.(LooperTile().border_(~gt[\synth]).font_(~guiMono.(14, true))
        .fixedSize_(Size(130, 34))
        .action_({ |b| ~synthModel.() !? { |d| d.setNotesOn(b.value == 1) } }), 'sa.synth.on'), { |b|
            var tag = ~midiProgram.('sa.synth.on') !? { |n| " · PC " ++ n } ? "";
            var was = b.value;
            b.states_([["OFF" ++ tag, ~gt[\mute], nil], ["ON" ++ tag, ~gt[\onacc], ~gt[\synth]]]);
            b.value = was;
            b.toolTip_("The note sequencer on or off, from the moment you hear it. It plays on the drums'\n"
                "grid, from their bar 1, whether the drums themselves are on or not."
                ++ (~midiWords.('sa.synth.on') !? { |w| "\nMIDI: " ++ w } ? ""));
        });
    var random = ~mapTag.(~synthButton.().fixedSize_(Size(130, 34)).cycles_(false)
        .states_([["Random sound", ~gt[\ink], ~gt[\panel]]])
        .action_({ ~synthWave.() !? { |w| w.randomize } }), 'sa.synth.random',
        "Every setting of the Wave synth at random but its level and its glide: a new sound\n"
        "for the same line. Save a preset first to keep the one you have.");
    var reset = ~mapTag.(~synthButton.().fixedSize_(Size(120, 34)).cycles_(false)
        .states_([["Reset sound", ~gt[\ink], ~gt[\panel]]])
        .action_({ ~synthWave.() !? { |w| w.reset } }), 'sa.synth.reset',
        "Every setting of the Wave synth back as megalooper ships it. The pattern stays.");
    var keep = ~synthButton.().fixedSize_(Size(140, 34)).cycles_(false)
        .states_([["Start with this", ~gt[\ink], ~gt[\panel]]])
        .toolTip_("Keep the pattern and the sound as they are now: the next boot starts with them\n"
            "instead of megalooper's own. The switch and the Synth strip's level are not in it.")
        .action_({ ~synthKeep.() });
    ~synthWidgets.put(\notesOn, (kind: \button, view: on, get: { ~synthModel.() !? { |d| d.notesOn } }));
    HLayout(~guiTitle.("Synth", 26), on, nil, random, reset, keep).spacing_(14)
};

// ---- Sequence ------------------------------------------------------------------------
~synthSequenceRows = {
    var c = MegaSANoteSeq;
    var divisions = c.divisionNames.collect { |n, i| [i, n] };
    var dirs = c.directions.collect { |k| [k, ~synthDirectionLabels[k]] };
    var restarts = c.restarts.collect { |k| [k, ~synthRestartLabels[k]] };
    var swing = ~synthKnobCell.((key: \swing, id: 'sa.synth.swing', label: "Swing", spec: ControlSpec(0, 1, \lin, 0, 0),
        get: { ~synthModel.() !? { |d| d.notes[\swing] } },
        set: { |v| ~synthModel.() !? { |d| d.setNoteSetting(\swing, v) } },
        format: { |v| ((v ? 0) * 100).round.asInteger.asString ++ " %" },
        tip: "Every second step late, up to half a step: 0 plays them straight. Double-click: 0."));
    [
        ~synthTitle.("Sequence"),
        HLayout(
            ~synthRowLabel.("Rate"),
            ~synthSettingMenu.(\division, divisions, 80, "How long a step is: 1/16 by default.", 'sa.synth.division'),
            ~synthSettingButton.(\triplet, "Triplet", 76, "Two thirds as long: three steps where two were."),
            ~synthSettingButton.(\dotted, "Dotted", 76, "Half as long again."),
            View().fixedWidth_(10),
            ~synthRowLabel.("Steps").fixedWidth_(52),
            ~synthSettingMenu.(\stepCount, [[8, "8"], [16, "16"]], 60, "How many steps the pattern has."),
            ~synthRowLabel.("From").fixedWidth_(46),
            ~synthSettingBox.(\first, 1, 16, 46, "The first step the sequence plays."),
            ~synthRowLabel.("to").fixedWidth_(22),
            ~synthSettingBox.(\last, 1, 16, 46, "The last step the sequence plays."),
            ~synthSettingMenu.(\direction, dirs, 110, "Forward, Backward, Alternate (there and back), Snake (a step up or\n"
                "down at random) or Random."),
            View().fixedWidth_(10),
            ~synthRowLabel.("Restart").fixedWidth_(64),
            ~synthSettingMenu.(\restart, restarts, 110, "Where the sequence starts again from its first step: on every bar\n"
                "line of the loop (uneven bars too), every pass of the loop, or never (it runs on from the\n"
                "drums' start). Its condition passes count on either way."),
            nil, swing
        ).spacing_(8),
        HLayout(
            ~synthRowLabel.("Key"),
            ~synthSettingButton.(\scaleOn, "Scale", 76, "On: every pitch snaps down to the scale. Off: plain semitones."),
            ~synthSettingMenu.(\root, c.rootNames.collect { |n, i| [i, n] }, 70,
                "The key's root: pitch 0 plays it.", 'sa.synth.root'),
            ~synthSettingMenu.(\scale, c.scales.collect { |s, i| [i, s[0]] }, 210, "The scale the pitches snap to.",
                'sa.synth.scale'),
            ~synthRowLabel.("Octave").fixedWidth_(60),
            ~synthSettingBox.(\octave, -3, 3, 50, "The whole line octaves up or down."),
            nil
        ).spacing_(8)
    ]
};

// ---- The steps and the lanes ---------------------------------------------------------
// The sequence's steps (first..last), 0-based.
~synthMainSpan = { |d| ((d.notes[\first] - 1) .. (d.notes[\last] - 1)) };

~synthPaintSteps = {
    var d = ~synthModel.(), w = ~synthCellWidth, h = ~synthStepHeight, span, col, inSpan, on, exists;
    if(d.notNil) {
        span = ~synthMainSpan.(d);
        col = ~synthPlayhead !? { |p| p[\main] };
        16.do { |i|
            inSpan = span.includes(i);
            on = d.notes[\steps][i] == true;
            exists = i < d.notes[\stepCount];
            Pen.fillColor = if(exists and: { inSpan }) { ~gt[\panel2] } { ~gt[\panel] };
            Pen.addRect(Rect((i * w) + 2, 0, w - 3, h));
            Pen.fill;
            if(on and: { exists }) {
                Pen.fillColor = ~gt[\synth].copy.alpha_(if(inSpan) { 0.85 } { 0.3 });
                Pen.addRect(Rect((i * w) + 6, 4, w - 11, h - 8));
                Pen.fill;
            };
        };
        Pen.fillColor = ~gt[\ink];
        [4, 8, 12].do { |k| Pen.addRect(Rect(k * w, 0, 2, h)) };
        Pen.fill;
        col !? { |c|
            Pen.strokeColor = ~gt[\ink];
            Pen.width = 2;
            Pen.strokeRect(Rect((c * w) + 3, 1, w - 5, h - 2));
        };
    };
};
~synthStepsView = {
    var paintTo;
    var view = UserView().canFocus_(false).fixedSize_(Size(~synthCellWidth * 16, ~synthStepHeight))
        .background_(~gt[\panel])
        .toolTip_("A step on (lit) or off. Click to switch it; drag across to switch a run the same way.\n"
            "The sequence plays the steps from its first to its last; the frame is where it is.")
        .drawFunc_({ ~synthPaintSteps.() })
        .mouseDownAction_({ |uv, x|
            var d = ~synthModel.(), i = (x / ~synthCellWidth).floor.asInteger.clip(0, 15);
            d !? { paintTo = (d.notes[\steps][i] == true).not; d.setNoteStep(i, paintTo) };
            true
        })
        .mouseMoveAction_({ |uv, x|
            var d = ~synthModel.(), i = (x / ~synthCellWidth).floor.asInteger.clip(0, 15);
            if(d.notNil and: { paintTo.notNil } and: { (d.notes[\steps][i] == true) != paintTo }) { d.setNoteStep(i, paintTo) };
            true
        });
    ~synthLanes.put(\steps, view);
    view
};

// A lane's bars: from the middle for a lane either side of 0, else from the
// bottom; its steps outside its span dimmed; each value written in its cell;
// the playhead's column framed.
~synthPaintLane = { |lane|
    var d = ~synthModel.(), w = ~synthCellWidth, h = ~synthLaneHeight;
    var spec, lo, hi, zero, span, col, l, v, inSpan, x, top, bh;
    if(d.notNil) {
        spec = MegaSANoteSeq.laneSpecs[lane];
        lo = spec[0];
        hi = spec[1];
        zero = if(lo < 0) { h / 2 } { h };
        l = d.notes[\lanes][lane];
        span = MegaSANoteSeq.laneSpan(d.notes, lane);
        col = ~synthPlayhead !? { |p| p[\lanes] !? { |ls| ls[lane] } };
        16.do { |i|
            v = l[\values][i];
            inSpan = span.includes(i);
            x = i * w;
            Pen.fillColor = if(inSpan) { ~gt[\panel2] } { ~gt[\panel] };
            Pen.addRect(Rect(x + 2, 0, w - 3, h));
            Pen.fill;
            if(lo < 0) {
                bh = (v / hi) * (h / 2);
                top = if(v >= 0) { zero - bh } { zero };
                bh = bh.abs;
            } {
                bh = ((v - lo) / (hi - lo)) * h;
                top = h - bh;
            };
            if(bh > 0) {
                Pen.fillColor = ~gt[\synth].copy.alpha_(if(inSpan) { 0.75 } { 0.25 });
                Pen.addRect(Rect(x + 2, top, w - 3, bh));
                Pen.fill;
            };
            Pen.stringCenteredIn(v.asString, Rect(x + 2, 0, w - 3, 14), ~guiMono.(10), if(inSpan) { ~gt[\ink] } { ~gt[\mute] });
        };
        if(lo < 0) {
            Pen.fillColor = ~gt[\line];
            Pen.addRect(Rect(0, zero, w * 16, 1));
            Pen.fill;
        };
        Pen.fillColor = ~gt[\ink];
        [4, 8, 12].do { |k| Pen.addRect(Rect(k * w, 0, 2, h)) };
        Pen.fill;
        col !? { |c|
            Pen.strokeColor = ~gt[\ink];
            Pen.width = 2;
            Pen.strokeRect(Rect((c * w) + 3, 1, w - 5, h - 2));
        };
    };
};
// The value at height y of a lane's strip.
~synthValueAt = { |lane, y|
    var spec = MegaSANoteSeq.laneSpecs[lane], h = ~synthLaneHeight, f = ((h - y) / h).clip(0, 1);
    (spec[0] + (f * (spec[1] - spec[0]))).round.asInteger
};
~synthLaneView = { |lane|
    var set = { |x, y, clicks|
        var d = ~synthModel.(), i = (x / ~synthCellWidth).floor.asInteger.clip(0, 15);
        d !? { d.setNoteValue(lane, i, if(clicks == 2) { MegaSANoteSeq.laneSpecs[lane][2] } { ~synthValueAt.(lane, y) }) };
    };
    var view = UserView().canFocus_(false).fixedSize_(Size(~synthCellWidth * 16, ~synthLaneHeight))
        .background_(~gt[\panel])
        .toolTip_(~synthLaneTips[lane] ++ "\n\nClick or drag to set a step; drag across to paint. Double-click: the default.")
        .drawFunc_({ ~synthPaintLane.(lane) })
        .mouseDownAction_({ |uv, x, y, mods, button, clicks| set.(x, y, clicks); true })
        .mouseMoveAction_({ |uv, x, y| set.(x, y, 1); true });
    ~synthLanes.put(lane, view);
    view
};

// A lane's settings and tools.
~synthLaneControls = { |lane|
    var key = { |name| ("lane_" ++ lane ++ "_" ++ name).asSymbol };
    var get = { |name| { ~synthModel.() !? { |d| d.notes[\lanes][lane][name] } } };
    var setL = { |name, v| ~synthModel.() !? { |d| d.setNoteLaneSetting(lane, name, v) } };
    var own = { (get.(\own).value) == true };
    var values = { |f| ~synthModel.() !? { |d| d.setNoteValues(lane, f.(d.notes)) } };
    var ownB = ~synthButton.().fixedWidth_(56).font_(~guiSans.(12))
        .states_([["Follow", ~gt[\mute], nil], ["Own", ~gt[\onacc], ~gt[\synth]]])
        .toolTip_("Follow: the lane plays the sequence's steps. Own: its own first and last step\n"
            "and its own direction, so lanes of other lengths drift against each other.")
        .action_({ |b| setL.(\own, b.value == 1) });
    var first = ~synthBox.(NumberBox()).fixedWidth_(40).clipLo_(1).clipHi_(16).step_(1).scroll_step_(1).decimals_(0)
        .toolTip_("The lane's own first step.").action_({ |n| setL.(\first, n.value.round.asInteger) });
    var last = ~synthBox.(NumberBox()).fixedWidth_(40).clipLo_(1).clipHi_(16).step_(1).scroll_step_(1).decimals_(0)
        .toolTip_("The lane's own last step.").action_({ |n| setL.(\last, n.value.round.asInteger) });
    var dirs = MegaSANoteSeq.directions;
    var dir = ~synthMenu.(PopUpMenu()).fixedWidth_(100).items_(dirs.collect { |k| ~synthDirectionLabels[k] })
        .toolTip_("The lane's own direction.").action_({ |m| setL.(\direction, dirs[m.value]) });
    ~synthWidgets.put(key.(\own), (kind: \button, view: ownB, get: get.(\own)));
    ~synthWidgets.put(key.(\first), (kind: \number, view: first, get: get.(\first), enabled: own));
    ~synthWidgets.put(key.(\last), (kind: \number, view: last, get: get.(\last), enabled: own));
    ~synthWidgets.put(key.(\direction), (kind: \menu, view: dir, get: get.(\direction), enabled: own,
        index: { |v| dirs.indexOf(v) }));
    HLayout(ownB, first, last, dir,
        ~synthTool.("Random", 64, "Every step of the lane's span at random, within its range.",
            { values.({ |p| MegaSANoteSeq.randomValues(p, lane) }) }),
        ~synthTool.("◀", 28, "The lane's steps one step earlier, the first coming round to the end.",
            { values.({ |p| MegaSANoteSeq.rotatedValues(p, lane, -1) }) }),
        ~synthTool.("▶", 28, "The lane's steps one step later, the last coming round to the start.",
            { values.({ |p| MegaSANoteSeq.rotatedValues(p, lane, 1) }) }),
        ~synthTool.("▲", 28, "Every step of the span one up.", { values.({ |p| MegaSANoteSeq.nudgedValues(p, lane, 1) }) }),
        ~synthTool.("▼", 28, "Every step of the span one down.", { values.({ |p| MegaSANoteSeq.nudgedValues(p, lane, -1) }) }),
        ~synthTool.("Reset", 54, "Every step of the lane back to its default.", { values.({ |p| MegaSANoteSeq.resetValues(p, lane) }) })
    ).spacing_(4)
};

~synthLaneRows = {
    [~synthTitle.("Steps and lanes"),
        HLayout(~synthRowLabel.("Steps"), ~synthStepsView.(), nil).spacing_(8)]
    ++ MegaSANoteSeq.laneNames.collect { |lane|
        HLayout(~synthRowLabel.(~synthLaneLabels[lane], ~synthLaneTips[lane]), ~synthLaneView.(lane),
            ~synthLaneControls.(lane), nil).spacing_(8)
    }
};

// ---- Wave synth ------------------------------------------------------------------------
~synthWaveCell = { |name|
    var p = MegaSAWave.param(name), key = ("wave_" ++ name).asSymbol, menu;
    if(p[\choices].notNil) {
        menu = ~mapTag.(~synthMenu.(PopUpMenu()).fixedWidth_(110).items_(p[\choices].collect(_[1]))
            .action_({ |m| ~synthWave.() !? { |w| w.set(name, p[\choices][m.value][0]) } }), ("sa.synth." ++ name).asSymbol,
            p[\tip] ? "");
        ~synthWidgets.put(key, (kind: \menu, view: menu, get: { ~synthWave.() !? { |w| w[name] } },
            index: { |v| p[\choices].collect(_[0]).indexOfEqual(v) }));
        View().fixedWidth_(116).layout_(VLayout(
            StaticText().string_(p[\label]).align_(\center).font_(~guiSans.(12, true)).stringColor_(~gt[\ink]),
            menu, nil).margins_(1).spacing_(4))
    } {
        ~synthKnobCell.((key: key, id: ("sa.synth." ++ name).asSymbol, label: p[\label], spec: p[\spec],
            centered: p[\centered], tip: p[\tip],
            get: { ~synthWave.() !? { |w| w[name] } }, set: { |v| ~synthWave.() !? { |w| w.set(name, v) } },
            format: { |v| ~synthFormat.(p, v) }))
    }
};
~synthWaveGroups = [
    ["Oscillator A", [\waveASet, \waveAPos, \waveAOctave, \waveALevel, \waveSpread]],
    ["Oscillator B", [\waveBSet, \waveBPos, \waveBSemis, \waveBDetune, \waveBLevel]],
    ["Sub and noise", [\waveSub, \waveNoise]],
    ["Filter", [\waveFilterType, \waveCutoff, \waveResonance, \waveDrive, \waveFilterEnv, \waveKeyTrack]],
    ["Amp envelope", [\waveAttack, \waveDecay, \waveSustain, \waveRelease]],
    ["Mod envelope", [\waveModAttack, \waveModDecay, \waveModSustain, \waveModRelease, \waveModPos]],
    ["LFOs", [\waveLfoRate, \waveLfoPos, \waveLfo2Rate, \waveVibrato, \waveLfo2Cutoff]],
    ["Glide and level", [\waveGlide, \waveLevel]]
];
~synthWaveRows = {
    var group = { |g| VLayout(~synthTitle.(g[0]), HLayout(*(g[1].collect { |n| ~synthWaveCell.(n) } ++ [nil])).spacing_(2)).spacing_(4) };
    var gs = ~synthWaveGroups;
    [~synthTitle.("Wave synth · a mono wavetable synth"),
        HLayout(group.(gs[0]), View().fixedWidth_(24), group.(gs[1]), View().fixedWidth_(24), group.(gs[2]), nil),
        HLayout(group.(gs[3]), View().fixedWidth_(24), group.(gs[4]), nil),
        HLayout(group.(gs[5]), View().fixedWidth_(24), group.(gs[6]), View().fixedWidth_(24), group.(gs[7]), nil)]
};

// ---- Mix -------------------------------------------------------------------------------
~synthLevels = IdentityDictionary.new;
~synthMixRows = { |m|
    if(m.notNil and: { m.level(\synth).notNil } and: { ~saLevelRow.notNil }) {
        [~synthTitle.("Mix"), ~saLevelRow.(m, \synth, "Synth:", ~synthLevels, ~synthLabelWidth,
            "The Synth strip: the Wave synth after the SYNTH chain (the FX view's last row).")]
    } { [] }
};

// ---- Wiring ----------------------------------------------------------------------------
~synthWire = { |d, w, m|
    var lanes = { { ~synthRefreshLanes.() }.defer };
    var ctls = [
        SimpleController(d)
            .put(\notesOn, { { ~synthPaint.(\notesOn); ~synthPollPlayhead.(true); ~guiRefreshTabs !? { |f| f.value } }.defer })
            .put(\playing, { { ~synthPollPlayhead.(true); ~guiRefreshTabs !? { |f| f.value } }.defer })
            .put(\noteSetting, { |obj, what, name| { ~synthPaint.(name); ~synthPaintAll.() }.defer })
            .put(\noteLaneSetting, { { ~synthPaintAll.() }.defer })
            .put(\noteValue, { |obj, what, lane| { ~synthRefreshLane.(lane) }.defer })
            .put(\noteValues, { |obj, what, lane| { ~synthRefreshLane.(lane) }.defer })
            .put(\noteStep, { { ~synthRefreshLane.(\steps) }.defer })
            .put(\notes, { { ~synthPaintAll.() }.defer })
    ];
    w !? { ctls = ctls.add(SimpleController(w)
        .put(\waveSetting, { |obj, what, name| { ~synthPaint.(("wave_" ++ name).asSymbol) }.defer })
        .put(\waveSettings, { { ~synthPaintAll.() }.defer })) };
    m !? { ctls = ctls.add(SimpleController(m)
        .put(\level, { |obj, what, key, amp| { ~saPaintLevel !? { |f| f.(~synthLevels, key, amp) } }.defer })
        .put(\mute, { |obj, what, key| { ~saPaintMute !? { |f| f.(~synthLevels, key, ~saMutedOf.(m, key)) } }.defer })) };
    ctls
};

// ---- Pane ------------------------------------------------------------------------------
~buildSynthPane = {
    var pane = View().background_(~gt[\bg]);
    var d, w, m, gen;
    ~presetStopTimers.(\saSynth);
    ~guiTeardowns[\synth].value;
    ~synthLevels = IdentityDictionary.new;
    d = ~synthModel.();
    w = ~synthWave.();
    m = ~megaSA;
    gen = ~synthGen;
    if(d.isNil or: { d.respondsTo(\notes).not }) {
        pane.layout_(VLayout(
            ~guiBand.(\synth),
            HLayout(View().fixedWidth_(14), ~guiHint.("The synth is Megalooper SA's: start the megalooper "
                "with the SA profile to play it.")).margins_(8),
            nil).margins_(0).spacing_(0));
    } {
        pane.layout_(VLayout(
            ~guiBand.(\synth),
            View().layout_(VLayout(*(
                [~synthHeaderRow.(),
                    ~guiPresetBar.(\saSynth, (
                        menu: "Saved synths: the pattern (every step, lane and setting) and the Wave synth's\n"
                            "sound together. Choosing one recalls it at once. The switch and the level are not in it.",
                        name: "File name for Save. Anything but letters and digits becomes '-'.",
                        save: "Write the pattern and the sound as they are now to sa/synth-presets/<name>.json in\n"
                            "your megalooper folder. 'Overwrite' asks for a second click."
                    ))]
                ++ [~synthRule.()] ++ ~synthSequenceRows.()
                ++ [~synthRule.()] ++ ~synthLaneRows.()
                ++ (if(w.notNil) { [~synthRule.()] ++ ~synthWaveRows.() } { [] })
                ++ (~synthMixRows.(m) !? { |rows| if(rows.notEmpty) { [~synthRule.()] ++ rows } { [] } } ? [])
                ++ [~guiHint.("Drag a lane's bars up or down · drag across to paint · double-click for the "
                    "default · hover for what it does"), nil]
            )).margins_([22, 14, 22, 14]).spacing_(8))
        ).margins_(0).spacing_(0));
        ~synthControllers = ~synthWire.(d, w, m);
        ~synthPaintAll.();
    };
    ~synthPane = pane;
    ~guiSwapPane !? { |f| f.(\synth, pane) };
    if(d.notNil) {
        ~presetRefreshList.(\saSynth);
        ~synthStartPlayhead.(gen);
    };
    pane
};
)
