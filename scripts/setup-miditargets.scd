// megalooper — the controls a MIDI binding can drive: every one, by id, with
// what it is and how to drive it. The router (setup-midimap.scd) looks a
// binding's control up here when a message arrives; the Rig tab's MIDI section
// lists them. docs/dev/midi-map.md, section 4, is the design: every control its
// table 4.2 names is here, and none of those 4.3 leaves out.
//
// Loaded by boot.scd; defines only, runs nothing. One entry point:
//   ~midiTargetsBuild — answers every control, as an IdentityDictionary
//                       id -> Event. ~setupMidiBindings calls it. Given
//                       \effects it answers SA's effects' controls alone,
//                       for ~midiTargetsRefresh after a chain edit.
(
// ---- The controls ------------------------------------------------------------
// Every control a binding can drive, by id, as an Event:
//   id, label, path   the id a map keeps (never reused; a renamed model keeps
//                     its old id), what the control is called (its widget's
//                     words) and where it is (its pane: "Perform",
//                     "Grains", "Cutter", "Analysis", "Effects", "Drums",
//                     "Rig", "Live", or "Window" for the views themselves)
//   group             optional: a heading within the tab, for the picker
//                     ("Delay", "Main pattern", "Main pattern, lane 3")
//   kind              \trigger, \toggle, \continuous, \step or \choice
//   fire              a trigger's action
//   flip              a toggle's own toggle: the model's, which carries the
//                     gesture's logic, where it has one; get and set its state
//   get, set          a level's, count's or choice's value, in its own units
//                     (a choice's is the index of its item; a mixer strip's
//                     level is in dB, as its slider shows it)
//   fromPos, toPos    its law, position 0..1 to value and back: the law its
//                     widget moves on, so a knob and the mouse agree. A
//                     count's runs over its box's range in whole steps (the
//                     router rounds a \step's value); a choice's spreads the
//                     travel over its items as the router does
//                     (LooperMidiMap.choiceIndex) and gives an item's middle
//                     back
//   items             a choice's items, as Strings, as its menu shows them:
//                     an Array, or a function answering one where the menu
//                     follows the model (a drum lane's pads, named by the kit)
//   format            a value as its widget shows it, for the list: every
//                     level, count and choice has one, through the widget's
//                     own formatter where it has one. It never throws: a nil
//                     value (no model) reads as a dash
//   available         whether it is there now; missing is yes. For SA's
//                     effects: whether their device is in one of MegaSA's
//                     chains now (docs/dev/device-chains.md, phase 2), so a
//                     removed or parked device's binding drives nothing and
//                     is greyed
//   why               optional: why it is not there now, in words, for the
//                     list (SA's effects: "Delay 2 is not in the chains now")
// Everything is looked up when a message arrives (~looper, ~megaSA, the laws),
// as the responders always did, so a rebuilt Looper or pane needs nothing
// registered again. A control whose table, law or model is not loaded yet is
// simply not available until it is, and its get and format still answer
// without throwing. Every control acts through its model's own methods, whose
// notifications the window follows, so a knob moves a widget as the mouse
// does; none calls a widget.
//
// Ids are dotted and lower camel, made from the model's own names: a Looper
// property's (its setter's and its notification's), a MegaSAFx setting's, a
// mixer strip's, a drum pattern's (\main, \break) and page's. Drum lanes are
// numbered 1-4, as the Drums tab and the device number them. The drums' knobs
// and lane settings edit "the pattern shown" on the Drums tab; here the
// pattern, and an L box's page, are in the id, fixed when a mapping is made
// (docs/dev/midi-map.md, decision 16).
//
// The trims are the one family made from what is loaded: a pad's trim for
// every pad of the kit each drum slot holds when this runs, and a layer's trim
// for each of its layer groups (every group but its main one, as the Drums tab
// offers them: ~drumsLayerGroups). The kit is the one the slot was given, read
// from its file if it is still loading. A trim follows its slot: it drives
// whatever kit is in force there, and is not there while that kit has no such
// pad or group, or another one is still loading. A kit with other pads gets
// their trims when this runs again (~setupMidiBindings.()).
~midiTargetsBuild = { |only|
    var t = IdentityDictionary.new;
    var looper = { ~looper.notNil };
    var granularKeys = List.new;
    var add = { |id, label, path, kind, fields|
        fields.put(\id, id).put(\label, label).put(\path, path).put(\kind, kind);
        t.put(id, fields);
    };
    // A readout from a formatter: nil (no model) is a dash, and a formatter
    // not loaded, or one that does not take the value, shows the value as it
    // is rather than throwing.
    var shown = { |f|
        { |v| if(v.isNil) { "—" } { ((try { f.value(v) } { nil }) ? v).asString } }
    };
    // A choice's law and readout, over its items as they are when asked.
    var choice = { |fields|
        var count = { (fields[\items].value ? []).size.max(1) };
        fields.put(\fromPos, { |c| LooperMidiMap.choiceIndex(c, count.value) });
        fields.put(\toPos, { |i| ((i ? 0) + 0.5) / count.value });
        fields.put(\format, shown.({ |i| (fields[\items].value ? [])[i.asInteger] }));
        fields
    };
    // Two decimals: the header's labels and the Grains tab's Morph.
    var hundredths = shown.({ |v| v.round(0.01).asString });
    // The Grains tab's sections (gui-granular.scd), for the picker.
    var granularGroups = (granularMorph: "Blend", granularAmp: "Blend",
        granularPitch: "Pitch", granularDetune: "Pitch", granularSize: "Grain", granularDensity: "Grain",
        granularSizeRand: "Grain", granularEnv: "Grain",
        granularPosition: "Read position", granularScan: "Read position", granularSpray: "Read position");
    // Megalooper SA's drums, or nil: no SA, or a MegaSA from before it had
    // them. An Event standing in for MegaSA answers `drums` by key.
    var drums = { ~megaSA !? { |m| if(m.isKindOf(Dictionary) or: { m.respondsTo(\drums) }) { m.drums } } };
    var hasDrums = { drums.value.notNil };
    // Whether SA's chains hold the device `id` now: MegaSA answers its switch,
    // nil for one it has not (removed, parked, or no SA at all).
    var fxThere = { |id| (~megaSA !? { |m| m.fx(id) }).notNil };
    // What a device goes by: its name in MegaSA's chains (a sound may have
    // renamed it), else its effect's title.
    var fxName = { |id| (~megaSA !? { |m| try { m.device(id).name } }) ? MegaSAFx.title(id) };
    // Why a device's controls do nothing now, asked when the list is drawn.
    var fxWhy = { |id, name|
        { if(~megaSA.isNil) { "Megalooper SA is not running" } { name ++ " is not in the chains now" } }
    };
    // A device's switch: its footswitch.
    var addSwitch = { |id, name|
        add.(("sa.fxOn." ++ id).asSymbol, name, "Effects", \toggle, (group: name,
            flip: { if(fxThere.(id)) { ~megaSA.toggleFx(id) } }, get: { ~megaSA !? { |m| m.fx(id) } },
            set: { |on| if(fxThere.(id)) { ~megaSA.setFx(id, on) } }, available: { fxThere.(id) },
            why: fxWhy.(id, name)));
    };
    var stripNames = (guitar: "Guitar", bass: "Bass", loop: "Loop", drums: "Drums", onsetKit: "Onset kit", master: "Master");
    var patternNames = (main: "Main", break: "Break");
    var pageNames = (chance: "Chance", alt: "Alt", velo: "Velo", roll: "Roll");
    var slotNames = (steps: "Steps kit", onset: "Onset kit");
    var laneLabels = (note: "Note", altNote: "Alt", delay: "D (delay)", mute: "M (mute)", lock: "Lock");
    var looperFamily, effectsFamily, mixerFamily, drumsFamily, trimsFamily, windowFamily;
    var addCount, addFx, addReset, fxFurther, fxPlugins, addLevel, addMute, addTiming, addLane, addTrims, addPadTrim, addGroupTrim;
    var stripLabel, inForce, trimLaw, trimText;

    // ---- Phase 1: the controls today's numbers drive ---------------------------
    // The 36 the old responders drove (docs/dev/midi-map.md, 11.1). Their ids,
    // kinds and actions are what test-midi-equivalence.scd holds the router
    // to: keep them as they are.

    // The transport and the set: one press, one action.
    [
        ['looper.trigger', "Trigger", { ~looper.trigger }, "Transport"],
        ['looper.stop', "Stop", { ~looper.stopPlayback }, "Transport"],
        ['looper.multiply', "Multiply", { ~looper.multiply }, "Transport"],
        ['looper.undo', "Undo", { ~looper.undo }, "Transport"],
        ['looper.clear', "Clear", { ~looper.clear }, "Transport"],
        ['looper.recordNextLoop', "Record next loop", { ~looper.recordNextLoop }, "Next loop"],
        ['looper.break', "Break", { ~looper.fireBreak }, "Break"],
        ['looper.nextReading', "Next reading", { ~looper.nextReading }, "Reading"]
    ].do { |e| add.(e[0], e[1], "Perform", \trigger, (group: e[3], fire: e[2], available: looper)) };

    // Switches: a press flips one through the model's own toggle.
    add.('looper.reverse', "Reverse", "Perform", \toggle, (group: "Transport",
        flip: { ~looper.reverse }, get: { ~looper !? { |l| l.reverseFlag } }, available: looper));
    add.('looper.dissolve', "Dissolve", "Perform", \toggle,
        (group: "Actions", flip: { ~looper.toggleDissolve },
            get: { ~looper !? { |l| l.dissolving or: { l.dissolvePos > 0 } } }, available: looper));
    add.('looper.sessionRecording', "Record the set", "Perform", \toggle, (group: "Record the set",
        flip: { ~looper.toggleSessionRecording }, get: { ~looper !? { |l| l.sessionRecording } },
        available: looper));
    add.('looper.granular', "Granular", "Perform", \toggle, (group: "Layers",
        flip: { ~looper.toggleGranular }, get: { ~looper !? { |l| l.granularOn } }, available: looper));
    add.('looper.bbcut', "BBCut", "Perform", \toggle, (group: "Layers",
        flip: { ~looper.bbcut = ~looper.bbcut.not }, get: { ~looper !? { |l| l.bbcut } },
        set: { |on| ~looper.bbcut = on }, available: looper));
    add.('looper.onsetNotes', "Onset notes", "Analysis", \toggle, (group: "Onset notes",
        flip: { ~looper.onsetNotes = ~looper.onsetNotes.not }, get: { ~looper !? { |l| l.onsetNotes } },
        set: { |on| ~looper.onsetNotes = on }, available: looper));
    // Live's arrangement record, over AbletonOSC (setup-model.scd). What we
    // last told Live, not what it is: nothing reads it back.
    add.('live.record', "Live arrangement record", "Live", \toggle,
        (flip: { ~liveRecordToggle.() }, get: { ~liveRecording },
            set: { |on| ~liveRecordSet.(on) }, available: { ~liveRecordToggle.notNil }));

    // Levels, over a knob's whole travel. Straight 0..1, as CC 118 has always
    // set morph, not through ~granularParams. Each reads as its slider's label
    // does, to two decimals (gui-shell.scd, gui-wiring.scd).
    [
        ['looper.feedback', "Overdub feedback", "Perform", \feedback],
        ['looper.intensity', "Arc / intensity", "Perform", \intensity],
        ['looper.granularMorph', "Granular morph", "Grains", \granularMorph]
    ].do { |e|
        var key = e[3];
        add.(e[0], e[1], e[2], \continuous, (group: granularGroups[key] ?? {
                (feedback: "Loop", intensity: "Macros")[key] },
            get: { ~looper !? { |l| l.perform(key) } }, set: { |v| ~looper.perform(key.asSetter, v) },
            fromPos: { |c| c }, toPos: { |v| v }, format: hundredths, available: looper));
    };
    // The threshold on the header slider's exponential law (gui-const.scd).
    add.('looper.onsetThreshold', "Onset threshold", "Perform", \continuous, (group: "Macros",
        get: { ~looper !? { |l| l.onsetThreshold } }, set: { |v| ~looper.onsetThreshold = v },
        fromPos: { |c| ~onsetThresholdSpec.map(c) }, toPos: { |v| ~onsetThresholdSpec.unmap(v) },
        format: hundredths,
        available: { ~looper.notNil and: { ~onsetThresholdSpec.notNil } }));
    // The granular layer's parameters, on the Grains tab's laws: its row of
    // ~granularParams (gui-granular.scd), looked up when a message arrives, so
    // without that table they do nothing. Every key the CC block names, and
    // every row of the table if it is loaded by now. They read as their rows
    // do (~granularFormat).
    // (~granularCcMap is the old numbers' table, in the legacy test file only.)
    ([\granularAmp] ++ (~granularCcMap ? []) ++ (~granularParams ? []).collect { |p| p[\key] }).do { |k|
        if((k != \granularMorph) and: { granularKeys.includes(k).not }) { granularKeys.add(k) };
    };
    granularKeys.do { |key|
        var row = { (~granularParams ? []).detect { |p| p[\key] == key } };
        add.(("looper." ++ key).asSymbol, (row.value !? { |p| p[\label] }) ? key.asString, "Grains",
            \continuous, (group: granularGroups[key],
                get: { ~looper !? { |l| l.perform(key) } }, set: { |v| ~looper.perform(key.asSetter, v) },
                fromPos: { |c| ~granularMapValue.(row.value, c) },
                toPos: { |v| ~granularUnmapValue.(row.value, v) },
                format: shown.({ |v| ~granularFormat.(row.value, v) }),
                available: { ~looper.notNil and: { row.value.notNil } }));
    };

    // Megalooper SA's effects and its drums' steps (MegaSA, MegaSADrums).
    MegaSAFx.keys.do { |key| addSwitch.(key, fxName.(key)) };
    add.('sa.drums.on', "Drums", "Drums", \toggle, (
        flip: { ~megaSA.drums.toggleOn }, get: { drums.value !? { |d| d.on } },
        set: { |on| ~megaSA.drums.setOn(on) },
        available: { ~megaSA.notNil and: { ~megaSA.drums.notNil } }));

    // ---- Phase 2: the rest of table 4.2 ------------------------------------------
    // Family by family, each made in `try`: one that can't be made is said in
    // the post window and left out, and the others, the 36 above among them,
    // still come.

    // The Looper's other controls, where its widgets are: Perform, the header,
    // Grains and Analysis.
    looperFamily = {
        var modes = [\mix, \insert, \gate];
        add.('looper.revertReading', "Revert", "Perform", \trigger, (group: "Reading",
            fire: { ~looper !? { |l| l.revertReading } }, available: looper));
        // The Analysis tab's Detect now: past the already-has-a-meter gate,
        // not past the quality guards.
        add.('looper.detectMeterFromOverdub', "Detect now", "Analysis", \trigger, (group: "Overdub detection",
            fire: { ~looper !? { |l| l.detectMeterFromOverdub(true) } }, available: looper));
        add.('looper.rerollOnsetNotes', "Re-roll", "Analysis", \trigger, (group: "Onset notes",
            fire: { ~looper !? { |l| l.rerollOnsetNotes } }, available: looper));
        // The Grains tab's Reset tweaks: every bend back to its default, the
        // meta-control left alone. Its own function, which writes the model
        // only (gui-granular.scd).
        add.('looper.granularResetTweaks', "Reset tweaks", "Grains", \trigger, (
            fire: { ~granularResetTweaks.value },
            available: { ~looper.notNil and: { ~granularResetTweaks.notNil } }));
        // The monitor has no toggle of its own: its button starts or stops it.
        add.('looper.analysisMonitor', "Monitor", "Analysis", \toggle, (
            flip: { ~looper !? { |l|
                if(l.analysisMonitorOn == true) { l.stopAnalysisMonitor } { l.startAnalysisMonitor } } },
            get: { ~looper !? { |l| l.analysisMonitorOn } },
            set: { |on| ~looper !? { |l| if(on == true) { l.startAnalysisMonitor } { l.stopAnalysisMonitor } } },
            available: looper));
        add.('looper.analyzeOverdubs', "Overdub detect", "Analysis", \toggle, (group: "Overdub detection",
            flip: { ~looper !? { |l| l.analyzeOverdubs = (l.analyzeOverdubs == true).not } },
            get: { ~looper !? { |l| l.analyzeOverdubs } },
            set: { |on| ~looper !? { |l| l.analyzeOverdubs = (on == true) } },
            available: looper));
        // The header's Master slider, straight 0..1, read as its label reads.
        add.('looper.masterAmp', "Master", "Perform", \continuous, (group: "Macros",
            get: { ~looper !? { |l| l.masterAmp } }, set: { |v| ~looper !? { |l| l.masterAmp = v } },
            fromPos: { |c| c }, toPos: { |v| v }, format: hundredths, available: looper));
        // The onset notes' Chance slider, straight 0..1, read as a percentage
        // as its label is (gui-analysis.scd).
        add.('looper.onsetNoteChance', "Chance", "Analysis", \continuous, (group: "Onset notes",
            get: { ~looper !? { |l| l.onsetNoteChance } }, set: { |v| ~looper !? { |l| l.onsetNoteChance = v } },
            fromPos: { |c| c }, toPos: { |v| v },
            format: shown.({ |v| (v * 100).round.asInteger.asString ++ "%" }), available: looper));
        // The Grains tab's Window menu: an index into Looper.granularEnvNames,
        // which is what the menu lists.
        add.('looper.granularEnv', "Window", "Grains", \choice, choice.((group: "Grain",
            items: Looper.granularEnvNames,
            get: { ~looper !? { |l| l.granularEnv } },
            set: { |i| ~looper !? { |l| l.granularEnv = i } },
            available: looper)));
        // Perform's mode menu beside the cutter's switch, in its order.
        add.('looper.bbcutMode', "BBCut mode", "Perform", \choice, choice.((group: "Layers",
            items: ["Mix", "Insert", "Gate"],
            get: { ~looper !? { |l| modes.indexOf(l.bbcutMode) } },
            set: { |i| ~looper !? { |l| modes[i] !? { |m| l.bbcutMode = m } } },
            available: looper)));
        [
            // id, label, tab, group, the property, its box's range (the
            // model's own), the unit its box's neighbour shows
            ['looper.dissolveBars', "Dissolve bars", "Perform", "Actions", \dissolveBars, 1, 64, ""],
            ['looper.breakLoops', "Loops", "Perform", "Break", \breakLoops, 1, 8, ""],
            ['looper.onsetNote', "Note", "Analysis", "Onset notes", \onsetNote, 0, 127, nil],
            ['looper.onsetNoteVelLo', "Vel low", "Analysis", "Onset notes", \onsetNoteVelLo, 1, 127, ""],
            ['looper.onsetNoteVelHi', "Vel high", "Analysis", "Onset notes", \onsetNoteVelHi, 1, 127, ""],
            ['looper.onsetNoteDynRange', "Dynamics", "Analysis", "Onset notes", \onsetNoteDynRange, 1, 90, " dB"],
            ['looper.onsetNoteGateMs', "Gate", "Analysis", "Onset notes", \onsetNoteGateMs, 1, 1000, " ms"]
        ].do { |row| addCount.(row) };
    };
    // A count, over its box's range in whole steps (gui-shell.scd,
    // gui-perform.scd, gui-analysis.scd). The onset note reads as its box and
    // the note name beside it do.
    addCount = { |row|
        var key = row[4], unit = row[7];
        var spec = ControlSpec(row[5], row[6], \lin, 1);
        add.(row[0], row[1], row[2], \step, (group: row[3],
            get: { ~looper !? { |l| l.perform(key) } },
            set: { |v| ~looper !? { |l| l.perform(key.asSetter, v) } },
            fromPos: { |c| spec.map(c) }, toPos: { |v| spec.unmap(v) },
            format: shown.(if(unit.isNil) {
                { |n| n.round.asInteger.asString ++ ((~midiNoteName !? { |f| " · " ++ f.(n) }) ? "") }
            } {
                { |n| n.round.asInteger.asString ++ unit }
            }),
            available: looper));
    };

    // Megalooper SA's effect settings and each effect's "Reset", made from the
    // chains (docs/dev/device-chains.md, section 10):
    //   - the default devices' under today's ids (sa.fx.delayMix,
    //     sa.fxReset.delay), whether their device is in a chain or not, so the
    //     shipped map and yours never name a control this megalooper has not;
    //   - every further device of MegaSA's chains under its own id
    //     (sa.fxOn.delay2, sa.fx.delay2.delayMix, sa.fxReset.delay2). A plugin
    //     has no switch and no knobs yet: its switch comes with its tile, its
    //     knobs after 1.0;
    //   - every plugin device's eight sends (sa.fxSend.plugin1.1 ..8): each
    //     sends the plugin a MIDI controller, for the plugin's own MIDI learn
    //     (MegaSA.pluginSend). A footswitch on a send switches whatever the
    //     plugin learnt it for: a scene of Bias FX, a pedal in it.
    // Each is named by its device ("Delay 2"), so no two rows read alike.
    effectsFamily = {
        MegaSAFx.params.do { |p| addFx.(p, nil, fxName.(p[\fx])) };
        MegaSAFx.keys.do { |key| addReset.(key, fxName.(key)) };
        fxFurther.value.do { |d|
            addSwitch.(d[\id], d[\name]);
            MegaSAFx.paramsOf(d[\type]).do { |p| addFx.(p, d[\id], d[\name]) };
            addReset.(d[\id], d[\name]);
        };
        fxPlugins.value.do { |d|
            (1..MegaSA.pluginSends).do { |n|
                add.(("sa.fxSend." ++ d[\id] ++ "." ++ n).asSymbol, "Send " ++ n ++ " (CC " ++ MegaSA.pluginSendCC(n) ++ ")",
                    "Effects", \trigger, (group: d[\name],
                        fire: { if(fxThere.(d[\id])) { ~megaSA.pluginSend(d[\id], n) } },
                        available: { fxThere.(d[\id]) }, why: fxWhy.(d[\id], d[\name])));
            };
        };
    };
    // The plugin devices of MegaSA's chains, as (id, name). None with no
    // MegaSA, or with something standing in for one.
    fxPlugins = {
        (try { ~megaSA.devices.select { |d| d.isPlugin }.collect { |d| (id: d.id, name: d.name.asString) } }) ? []
    };
    // The built-in devices of MegaSA's chains beyond the default ones, as (id,
    // type, name). None with no MegaSA, or with something standing in for one.
    fxFurther = {
        (try {
            ~megaSA.devices.select { |d| d.isPlugin.not and: { MegaSAFx.keys.includes(d.id).not } }
                .collect { |d| (id: d.id, type: d.type, name: d.name.asString) }
        }) ? []
    };
    addReset = { |id, name|
        add.(("sa.fxReset." ++ id).asSymbol, "Reset", "Effects", \trigger, (group: name,
            fire: { if(fxThere.(id)) { ~megaSA.resetFx(id) } }, available: { fxThere.(id) }, why: fxWhy.(id, name)));
    };
    // One setting, as the Effects tab draws it (gui-effects.scd): one picked
    // from a list is a menu of its choices' labels, every other one a knob on
    // its ControlSpec (~effectsMap and ~effectsUnmap, which are the spec's own
    // curve, so the spec stands for them while gui-effects.scd is not loaded),
    // read through ~effectsFormat. A knob set in whole steps (Coarse, Pitch L
    // and R, Bit Depth) is a count. Through setFxParam (a further device's:
    // setParam), which holds a value to its range and step and notifies
    // \fxParam. `dev` is a further device's id, nil for the default one.
    addFx = { |p, dev, title|
        var name = p[\name], spec = p[\spec], choices = p[\choices], fx = dev ? p[\fx], fields, values;
        var id = (if(dev.isNil) { "sa.fx." ++ name } { "sa.fx." ++ dev ++ "." ++ name }).asSymbol;
        var get = if(dev.isNil) { { ~megaSA !? { |m| m.fxParam(name) } } } { { ~megaSA !? { |m| try { m.param(dev, name) } } } };
        var set = if(dev.isNil) { { |v| ~megaSA.setFxParam(name, v) } } { { |v| ~megaSA.setParam(dev, name, v) } };
        fields = (group: title, available: { fxThere.(fx) }, why: fxWhy.(fx, title));
        if(choices.notNil) {
            values = choices.collect { |pair| pair[0] };
            fields.put(\items, choices.collect { |pair| pair[1] });
            fields.put(\get, { get.value !? { |v| values.indexIn(v) } });
            fields.put(\set, { |i| if(fxThere.(fx)) { choices[i] !? { |pair| set.(pair[0]) } } });
            add.(id, p[\label], "Effects", \choice, choice.(fields));
        } {
            fields.put(\get, get);
            fields.put(\set, { |v| if(fxThere.(fx)) { set.(v) } });
            fields.put(\fromPos, { |c| if(~effectsMap.notNil) { ~effectsMap.(p, c) } { spec.map(c) } });
            fields.put(\toPos, { |v| if(~effectsUnmap.notNil) { ~effectsUnmap.(p, v) } { spec.unmap(v) } });
            fields.put(\format, shown.({ |v| ~effectsFormat.(p, v) }));
            add.(id, p[\label], "Effects", if(spec.step >= 1) { \step } { \continuous }, fields);
        };
    };

    // The mixer, as the Rig tab's Megalooper SA section shows it (gui-sa.scd),
    // in its order: every strip's level, and the mute of every strip but the
    // master's. The drums' two strips are on the Drums tab too. The bass's
    // are there only on a rig with a bass input.
    mixerFamily = {
        [\guitar, \bass, \loop, \drums, \onsetKit, \master].do { |k| addLevel.(k) };
        [\guitar, \bass, \loop, \drums, \onsetKit].do { |k| addMute.(k) };
    };
    stripLabel = { |k| ((~saStripLabels !? { |names| names[k] }) ? stripNames[k] ? k).asString.replace(":", "") };
    // A level as its slider moves it (~saLevelRow): in dB on ~saLevelSpec's
    // travel, set as the amplitude MegaSA keeps, and read as ~saLevelText
    // reads it. Until gui-sa.scd is loaded it is not there, and its law
    // stands still rather than throwing.
    addLevel = { |k|
        add.(("sa.level." ++ k).asSymbol, stripLabel.(k) ++ " level", "Rig", \continuous, (group: "Megalooper SA",
            get: { ~megaSA !? { |m| m.level(k) !? { |a| a.ampdb.max(-60) } } },
            set: { |db| ~megaSA !? { |m| m.setLevel(k, db.dbamp) } },
            fromPos: { |c| (~saLevelSpec !? { |s| s.map(c) }) ? c },
            toPos: { |db| (~saLevelSpec !? { |s| s.unmap(db) }) ? db },
            format: shown.({ |db| ~saLevelText.(db.dbamp) }),
            available: { ~saLevelSpec.notNil and: { (~megaSA !? { |m| m.level(k) }).notNil } }));
    };
    addMute = { |k|
        add.(("sa.mute." ++ k).asSymbol, stripLabel.(k) ++ " mute", "Rig", \toggle, (group: "Megalooper SA",
            // What the strip gets, holds included (MegaSA.muted): a held
            // strip shows muted, and a flip unmutes it.
            flip: { ~megaSA !? { |m| m.setMute(k, ((m.muted(k) ? m.mute(k)) == true).not) } },
            get: { ~megaSA !? { |m| m.muted(k) ? m.mute(k) } },
            set: { |on| ~megaSA !? { |m| m.setMute(k, on == true) } },
            available: { (~megaSA !? { |m| m.mute(k) }).notNil }));
    };

    // The drums, as the Drums tab shows them (gui-drums.scd): which pattern
    // plays, Beat Repeat, the reverb, each pattern back as the Live set has
    // it, and each pattern's timing and lanes.
    drumsFamily = {
        // The header's Main | BREAK switch, by hand until the Looper's next
        // break edge, from the moment heard. Lit by what the drums did.
        add.('sa.drums.breakPattern', "Break plays", "Drums", \toggle, (
            flip: { drums.value !? { |d| d.setBreakPattern((d.breakActive == true).not) } },
            get: { drums.value !? { |d| d.breakActive } },
            set: { |on| drums.value !? { |d| d.setBreakPattern(on == true) } },
            available: hasDrums));
        // There only while the steps kit in force has Beat Repeat, as the tab's
        // switch is: elsewhere it says "no repeats" and takes no click.
        add.('sa.drums.repeats', "Repeats", "Drums", \toggle, (group: "Kits",
            flip: { drums.value !? { |d| d.setRepeats((d.repeats == true).not) } },
            get: { drums.value !? { |d| d.repeats } },
            set: { |on| drums.value !? { |d| d.setRepeats(on == true) } },
            available: { (drums.value !? { |d| d.kitFor(\steps) !? { |k| k.hasRepeats } }) == true }));
        // The Reverb slider on ~drumsReverbSpec, read as its readout reads.
        add.('sa.drums.reverbMix', "Reverb", "Drums", \continuous, (group: "Mix",
            get: { drums.value !? { |d| d.reverbMix } },
            set: { |v| drums.value !? { |d| d.setReverbMix(v) } },
            fromPos: { |c| (~drumsReverbSpec !? { |s| s.map(c) }) ? c },
            toPos: { |v| (~drumsReverbSpec !? { |s| s.unmap(v) }) ? v },
            format: shown.({ |v| (v * 100).round(0.1).asString ++ " %" }),
            available: { ~drumsReverbSpec.notNil and: { hasDrums.value } }));
        [\main, \break].do { |which|
            add.(("sa.drums.livePattern." ++ which).asSymbol, "Reset pattern", "Drums", \trigger, (
                group: patternNames[which] ++ " pattern",
                fire: { drums.value !? { |d| d.resetPattern(which) } }, available: hasDrums));
            MegaSASteps.paramSpecs.do { |p| addTiming.(which, p) };
            [0, 1, 2, 3].do { |lane| addLane.(which, lane) };
        };
    };
    // One timing setting of a pattern, as the tab draws the pattern shown's:
    // Clock, Roll and Retrig Rate are menus, Retrig an On/Off switch, Shuffle
    // Len a box in whole steps, Global and the eight dials knobs on their
    // ControlSpecs, read through ~drumsFormat. Through setParam, which
    // notifies \param.
    addTiming = { |which, p|
        var name = p[\name], spec = p[\spec], choices = p[\choices], fields, values;
        var id = ("sa.drums." ++ which ++ "." ++ name).asSymbol;
        fields = (group: patternNames[which] ++ " pattern", available: hasDrums);
        case
        { p[\bool] == true } {
            fields.put(\flip, { drums.value !? { |d| d.setParam(which, name, (d.param(which, name) == true).not) } });
            fields.put(\get, { drums.value !? { |d| d.param(which, name) } });
            fields.put(\set, { |on| drums.value !? { |d| d.setParam(which, name, on == true) } });
            add.(id, p[\label], "Drums", \toggle, fields);
        }
        { choices.notNil } {
            values = choices.collect { |pair| pair[0] };
            fields.put(\items, choices.collect { |pair| pair[1] });
            fields.put(\get, { drums.value !? { |d| values.indexOfEqual(d.param(which, name)) } });
            fields.put(\set, { |i| drums.value !? { |d| choices[i] !? { |pair| d.setParam(which, name, pair[0]) } } });
            add.(id, p[\label], "Drums", \choice, choice.(fields));
        }
        {
            fields.put(\get, { drums.value !? { |d| d.param(which, name) } });
            fields.put(\set, { |v| drums.value !? { |d| d.setParam(which, name, v) } });
            fields.put(\fromPos, { |c| spec.map(c) });
            fields.put(\toPos, { |v| spec.unmap(v) });
            fields.put(\format, shown.({ |v| ~drumsFormat.(p, v) }));
            add.(id, p[\label], "Drums", if(spec.step >= 1) { \step } { \continuous }, fields);
        };
    };
    // A lane's settings (lane 0..3, numbered 1..4), as the tab's lane rows
    // draw them for the pattern shown: Note and Alt are menus of pads 36..51
    // named by the steps kit (~drumsNoteItems), D a box in half milliseconds
    // over the lane setting's range, M and Lock On/Off switches, and L, per
    // page, the page's length, or the lane's Global Len while Lock is on (the
    // L box's rule, ~drumsSetLength, with its pattern and page fixed here).
    // Through setLaneParam and setLength, which notify \lane and \length.
    addLane = { |which, lane|
        var n = lane + 1;
        var base = "sa.drums." ++ which ++ ".lane" ++ n;
        var group = patternNames[which] ++ " pattern, lane " ++ n;
        var delayRow = MegaSASteps.laneParamSpec(\delay), lengthRow = MegaSASteps.laneParamSpec(\length);
        var delaySpec = ControlSpec(delayRow[\spec].minval, delayRow[\spec].maxval, \lin, 0.5);
        [\note, \altNote].do { |name|
            add.((base ++ "." ++ name).asSymbol, laneLabels[name], "Drums", \choice, choice.((group: group,
                items: { (~drumsNoteItems !? { |f| f.(drums.value) }) ?? { (36..51).collect(_.asString) } },
                get: { drums.value !? { |d| d.laneParam(which, lane, name) !? { |v| (v - 36).clip(0, 15) } } },
                set: { |i| drums.value !? { |d| d.setLaneParam(which, lane, name, i + 36) } },
                available: hasDrums)));
        };
        add.((base ++ ".delay").asSymbol, laneLabels[\delay], "Drums", \continuous, (group: group,
            get: { drums.value !? { |d| d.laneParam(which, lane, \delay) } },
            set: { |v| drums.value !? { |d| d.setLaneParam(which, lane, \delay, v) } },
            fromPos: { |c| delaySpec.map(c) }, toPos: { |v| delaySpec.unmap(v) },
            format: shown.({ |v| ~drumsFormat.(delayRow, v) }), available: hasDrums));
        [\mute, \lock].do { |name|
            add.((base ++ "." ++ name).asSymbol, laneLabels[name], "Drums", \toggle, (group: group,
                flip: { drums.value !? { |d|
                    d.setLaneParam(which, lane, name, (d.laneParam(which, lane, name) == true).not) } },
                get: { drums.value !? { |d| d.laneParam(which, lane, name) } },
                set: { |on| drums.value !? { |d| d.setLaneParam(which, lane, name, on == true) } },
                available: hasDrums));
        };
        MegaSASteps.pages.do { |page|
            add.((base ++ ".length." ++ page).asSymbol, "L (" ++ (pageNames[page] ? page) ++ ")", "Drums", \step,
                (group: group,
                    get: { drums.value !? { |d| d.effectiveLength(which, page, lane) } },
                    set: { |v| drums.value !? { |d|
                        if(d.laneParam(which, lane, \lock) == true) { d.setLaneParam(which, lane, \globalLength, v) }
                            { d.setLength(which, page, lane, v) } } },
                    fromPos: { |c| lengthRow[\spec].map(c) }, toPos: { |v| lengthRow[\spec].unmap(v) },
                    format: shown.({ |v| ~drumsFormat.(lengthRow, v) }), available: hasDrums));
        };
    };

    // The trims of the kits the two slots hold now (see the top of the file),
    // on ~drumsTrimSpec, read through ~drumsDbText, as the tab's trim knobs.
    // Through setPadTrim and setGroupTrim, which notify \padTrim and
    // \groupTrim and keep them per kit.
    trimsFamily = {
        drums.value !? { |d| [\steps, \onset].do { |slot| addTrims.(d, slot) } };
    };
    // The kit a slot holds: the one in force, or, while the one it was given
    // is still loading, that one read from its file.
    addTrims = { |d, slot|
        var key = d.kit(slot), kit, groups;
        if(key.notNil) {
            kit = d.kitFor(slot);
            if(kit.isNil or: { kit.key != key }) {
                kit = d.kitDir !? { |dir| MegaSAKit.read(MegaSAKit.fileFor(dir, key), List.new) };
            };
        };
        kit !? { |k|
            k.notes.do { |note| addPadTrim.(slot, note, k.padName(note)) };
            groups = (~drumsLayerGroups !? { |f| f.(k) }) ? [];
            groups.do { |g| addGroupTrim.(slot, g, k.groupName(g)) };
        };
    };
    // The kit in force in a slot, if it is the one the slot was given: while
    // another loads there is nothing honest to trim (~drumsKitInForce).
    inForce = { |slot| drums.value !? { |d| d.kitFor(slot) !? { |k| if(k.key == d.kit(slot)) { k } } } };
    trimLaw = [{ |c| (~drumsTrimSpec !? { |s| s.map(c) }) ? c }, { |db| (~drumsTrimSpec !? { |s| s.unmap(db) }) ? db }];
    trimText = shown.({ |db| ~drumsDbText.(db) });
    addPadTrim = { |slot, note, name|
        add.(("sa.drums.trim." ++ slot ++ "." ++ note).asSymbol,
            if(name.notNil) { note.asString ++ " " ++ name } { note.asString }, "Drums", \continuous, (
                group: slotNames[slot] ++ " trims",
                get: { drums.value !? { |d| d.padTrim(slot, note) } },
                set: { |db| drums.value !? { |d| d.setPadTrim(slot, note, db) } },
                fromPos: trimLaw[0], toPos: trimLaw[1], format: trimText,
                available: { ~drumsTrimSpec.notNil and: {
                    (inForce.(slot) !? { |k| k.pad(note).notNil }) == true } }));
    };
    addGroupTrim = { |slot, group, name|
        add.(("sa.drums.groupTrim." ++ slot ++ "." ++ group).asSymbol, "Layer: " ++ (name ? group), "Drums",
            \continuous, (
                group: slotNames[slot] ++ " trims",
                get: { drums.value !? { |d| d.groupTrim(slot, group) } },
                set: { |db| drums.value !? { |d| d.setGroupTrim(slot, group, db) } },
                fromPos: trimLaw[0], toPos: trimLaw[1], format: trimText,
                available: { ~drumsTrimSpec.notNil and: {
                    (inForce.(slot) !? { |k| k.groupKeys.includes(group) }) == true } }));
    };

    // The views of the stage window (docs/dev/stage-ui.md): a press shows one, as
    // keys 1-6 do. Ids by the view's name, not its number, so a mapping
    // survives a renumbering. FX and Drums are there only where the window
    // has them (Megalooper SA). The window is the GUI's: the press is deferred to
    // AppClock, as every view change must be.
    windowFamily = {
        [[\perform, "Perform"], [\sound, "Sound"], [\fx, "FX"], [\drums, "Drums"], [\setup, "Setup"],
            [\calibrate, "Calibrate"]].do { |v|
            add.(("gui.view." ++ v[0]).asSymbol, "Show " ++ v[1], "Window", \trigger, (group: "Views",
                fire: { { ~guiSelectView !? { |f| f.(v[0]) } }.defer },
                available: { ~guiWindow.notNil and: { ~guiViewOrder.notNil }
                    and: { ~guiViewOrder.includes(v[0]) } }));
        };
    };

    [
        [\looper, looperFamily], [\effects, effectsFamily], [\mixer, mixerFamily],
        [\drums, drumsFamily], [\trims, trimsFamily], [\window, windowFamily]
    ].do { |pair|
        if(only.isNil or: { only == pair[0] }) { try { pair[1].value } { |err|
            ("megalooper: MIDI controls: the " ++ pair[0] ++ " family could not be made ("
                ++ (if(err.respondsTo(\errorString)) { err.errorString } { err.asString })
                ++ "); its controls are left out.").warn;
        } };
    };
    // One family asked for: its controls alone (the effects' switches are made
    // above, with the first 36).
    if(only == \effects) { t = t.select { |x, id| id.asString.beginsWith("sa.fx") } };
    t
};
)
