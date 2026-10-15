// megalooper — the Cutter: the left half of the Sound view.
//
// Loaded by boot.scd; defines only, runs nothing. Entry point:
//   ~buildBBCutPane — builds a fresh Cutter pane against the EXISTING ~looper,
//                     rescans presets from disk and swaps the pane into the
//                     shell's holder. Safe to re-run: it never touches the
//                     model, so the recorded loop and the running cutter both
//                     survive a GUI rebuild.
//
// Under the cutter's colour bar: its switch, Mix/Insert/Gate and its preset;
// then a tab per voice; then the selected voice — its procedure (the list, the
// three with an "arc" tag are the ones the pedal drives), cut synth and ratio
// on the left, the procedure's parameters, the voice's level and pan, and its
// effects on the right. Every option of seven or fewer is a row of tiles, so
// every choice is one click and all of them are in sight.
//
// Structural changes (proc/synth/fx/ratio/add/remove/select) rebuild the
// voice's panel via ~renderBBCutEditor; live changes (amp/pan/params) just
// write to the model. The model rebuilds the running cutter itself when
// needed. The hint lines the old pane carried under every row are the
// controls' tooltips now, word for word.
//
// The preset CRUD below is GUI glue only — the actual read/write/validate lives
// on Looper (bbcutPresetNames / bbcutPresetSlug / save / load / deleteBBCutPreset).
// ~bbcutPresetDir is set by boot.scd; the class can't derive it because it is
// compiled through a symlink in Extensions, so the path is passed in at call time.
(
~bbcutSelVoice    = 0;
~bbcutRatios      = [1, 3/2, 2/3, 4/3, 3/4, 1/2, 2];
~bbcutRatioLabels = ["1:1", "3:2", "2:3", "4:3", "3:4", "1:2", "2:1"];
~bbcutSynthLabels = ["Buf 1", "Buf 2", "Buf 3"];
~bbcutSynthHints  = ["raw PlayBuf, may click", "enveloped grain per cut", "keeps original pitch"];

// ---- Preset bar -----------------------------------------------------------
// The bar's behaviour — menu, name field, two-click Save/Delete, status line —
// is gui-presets.scd's, shared with the other presets. This is the cutter's
// half of the family spec: a label, one line of help text, and which Looper
// methods to call.
~definePresetFamily.(\bbcut, (
    label:      "BBCut",
    statusIdle: "Pick a preset to recall it live · Save writes voices + mix mode",
    dirKey:     \bbcutPresetDir,
    names:      \bbcutPresetNames,
    slug:       \bbcutPresetSlug,
    save:       \saveBBCutPreset,
    load:       \loadBBCutPreset,
    delete:     \deleteBBCutPreset
));

// Named wrappers. These are what the wiring and check.scd address, and
// `~saveBBCutPreset.()` reads better on a button's action than
// `~presetSave.(\bbcut)`. One line each, no logic.
~bbcutPresetSetStatus      = { |str, isError = false|
    ~presetSetStatus.(\bbcut, str, isError) };
~refreshBBCutPresetList    = { ~presetRefreshList.(\bbcut) };
~refreshBBCutPresetButtons = { ~presetRefreshButtons.(\bbcut) };
~bbcutPresetDisarm         = { ~presetDisarm.(\bbcut) };
~bbcutPresetArm            = { |which, msg| ~presetArm.(\bbcut, which, msg) };
~loadBBCutPreset           = { |slug| ~presetLoad.(\bbcut, slug) };
~saveBBCutPreset           = { ~presetSave.(\bbcut) };
~deleteBBCutPreset         = { ~presetDelete.(\bbcut) };
~revertBBCutPreset         = { ~presetRevert.(\bbcut) };

// ---- The header ------------------------------------------------------------------
// The switch and the mode, painted from the model like Perform's.
~bbcutPaintHeader = {
    ~looper !? { |l|
        ~bbcutPaneButton !? { |b|
            if(b.isClosed.not) {
                b.states_([["OFF · B", ~gt[\mute], nil], ["ON · B", ~gt[\onacc], ~gt[\cut]]]);
                b.value_(l.bbcut.binaryValue);
            };
        };
        ~guiSegSet.(~bbcutModeSegSound, [\mix, \insert, \gate].indexOf(l.bbcutMode) ? 1);
    };
};

// ---- The voice tabs --------------------------------------------------------------
// One tab per voice ("Voice 2  3:2 · SQPusher1"), the selected one underlined in
// the cutter's colour; + voice and remove voice. Rebuilt into their holder when
// the voices change. (Its name is the old menu's: the wiring calls it.)
~renderBBCutVoiceMenu = {
    var l = ~looper, n = l.bbcutVoiceCount, h = ~bbcutVoiceTabsHolder, tabs;
    var ratioText = { |r|
        var i = ~bbcutRatios.collect { |x| (x - r).abs };
        ~bbcutRatioLabels[i.indexOf(i.minItem) ? 0]
    };
    ~bbcutSelVoice = ~bbcutSelVoice.clip(0, n - 1);
    if(h.notNil and: { h.isClosed.not }) {
        h.children.copy.do { |c| c.remove };
        tabs = n.collect { |i|
            var v = l.bbcutVoices[i];
            var sel = i == ~bbcutSelVoice;
            var name = (l.bbcutProcSpecs[v[\proc]] !? { |s| s[\name] }) ? v[\proc].asString;
            LooperTile().states_([["Voice " ++ (i + 1), if(sel) { ~gt[\ink] } { ~gt[\mute] }, nil]])
                .cycles_(false).align_(\left).pad_(20)
                .font_(~guiSans.(15, sel)).fixedHeight_(46)
                .underline_(if(sel) { ~gt[\cut] } { nil })
                .sub_(ratioText.(v[\ratio]) ++ " · " ++ name)
                .subFont_(~guiMono.(11, true))
                .minWidth_(((("Voice " ++ (i + 1)).bounds(~guiSans.(15, true)).width)
                    .max((ratioText.(v[\ratio]) ++ " · " ++ name).bounds(~guiMono.(11, true)).width) + 44).ceil)
                .toolTip_("Edit voice " ++ (i + 1) ++ ". Each voice is an independent cutter with its own "
                    "procedure, synth, effects, clock ratio and mix position, all reading the same loop buffer.")
                .action_({ ~bbcutSelVoice = i; { ~renderBBCutVoiceMenu.(); ~renderBBCutEditor.() }.defer })
        };
        h.layout.add(HLayout(*(tabs ++ [
            LooperTile().states_([["+ voice", ~gt[\mute], nil]]).cycles_(false).font_(~guiSans.(15))
                .fixedHeight_(46).fixedWidth_(96)
                .toolTip_("Add another cutter voice, layered over the same loop (four at most).")
                .action_({
                    ~looper.addBBCutVoice;
                    ~bbcutSelVoice = ~looper.bbcutVoiceCount - 1;
                    { ~renderBBCutVoiceMenu.(); ~renderBBCutEditor.() }.defer;
                }),
            nil,
            LooperTile().states_([["remove voice", ~gt[\mute], nil]]).cycles_(false).font_(~guiSans.(14))
                .fixedHeight_(46).fixedWidth_(120)
                .toolTip_("Remove the selected voice.")
                .action_({
                    ~looper.removeBBCutVoice(~bbcutSelVoice);
                    { ~renderBBCutVoiceMenu.(); ~renderBBCutEditor.() }.defer;
                })
        ])).spacing_(0).margins_(0));
    };
    // What the old menu was: the voice tabs' holder, for the checks.
    ~bbcutVoiceMenu = h;
};

// ---- The voice ------------------------------------------------------------------------
// A parameter row: the label, the bar, the value. Integers step; a parameter
// the cutter only reads when it is built is written when the mouse lets go,
// so a drag rebuilds it once rather than at every step.
~bbcutParamRow = { |entry, cur, live, isDensity|
    var lo = entry[\lo], hi = entry[\hi];
    var isInt = (entry[\int] ? false) == true;
    var fmt = { |x| if(isInt) { x.round.asInteger.asString } { x.round(0.01).asString } };
    var value = ~guiMonoText.(fmt.(cur), 14, ~gt[\ink]).align_(\right).fixedWidth_(128);
    var tip = (entry[\hint] ? entry[\label]) ++ "\n"
        ++ "Range " ++ lo ++ "–" ++ hi ++ ", default " ++ entry[\default] ++ ". "
        ++ if(live) { "Applies at the next phrase boundary." } { "Changing it rebuilds the cutter, when you let go." }
        ++ if(isDensity) {
            "\nThe Arc pedal scales this one: the bar is the value at FULL arc (what presets\n"
            "save), the tick what the cutter uses now. The pedal takes it down towards " ++ lo ++ "."
        } { "" };
    var bar = ~guiBar.(\cut, if(isDensity) { 22 } { 16 })
        .step_(if(isInt) { 1 / (hi - lo) } { 0 })
        .value_((cur - lo) / (hi - lo))
        .toolTip_(tip);
    var mapped = { |sl|
        var m = lo + (sl.value * (hi - lo));
        // Qt's own quantisation lands on n/(hi-lo) with the usual float fuzz,
        // so round before storing.
        if(isInt) { m.round.asInteger.clip(lo, hi) } { m }
    };
    if(isDensity) { bar.inset_(4) };
    bar.action_({ |sl|
        value.string_(fmt.(mapped.(sl)) ++ if(isDensity) { ~bbcutDensityTail.() } { "" });
        if(live) { ~looper.setVoiceParam(~bbcutSelVoice, entry[\key], mapped.(sl)) };
    });
    if(live.not) {
        bar.mouseUpAction_({ |sl| ~looper.setVoiceParam(~bbcutSelVoice, entry[\key], mapped.(sl)); nil });
    };
    if(isDensity) {
        ~bbcutDensityLabel = value;
        ~bbcutDensityBar = bar;
        ~bbcutDensityEntry = entry;
    };
    HLayout(~guiText.(entry[\label], 15).fixedWidth_(120).toolTip_(tip), [bar, stretch: 1], value)
        .spacing_(14).margins_(0)
};

// What the arc leaves of the density, after its stored value: "  arc 0.33".
~bbcutDensityTail = {
    var applied = ~looper !? { |l| l.voiceDensity(~bbcutSelVoice) };
    if(applied.notNil) { "  arc " ++ applied.round(0.01) } { "" }
};

// Build the selected voice's panel and swap it into the holder. A new view
// each time means each view's layout is only ever set once (re-setting a
// layout on an existing view is refused by Qt).
~renderBBCutEditor = {
    var l        = ~looper;
    var v        = l.bbcutVoices[~bbcutSelVoice];
    var spec     = l.bbcutProcSpecs[v[\proc]];
    var procKeys = l.bbcutProcOrder;
    var synthKeys = l.bbcutSynthKeys;
    var fxKeys   = l.bbcutFxOrder;
    var editor   = View().background_(~gt[\bg]);
    var ratioIdx = ~bbcutRatios.collect { |r| (r - v[\ratio]).abs };
    var synthIdx = synthKeys.indexOf(v[\synth]) ? 1;
    var caption = { |str| ~guiCaption.(str, 11) };
    var procs, synthSeg, ratioSeg, left, right, rows, fxTiles, ampBar, panBar, ampValue, panValue;

    // ---- left: procedure, cut synth, ratio --------------------------------------
    procs = procKeys.collect { |k|
        var ps = l.bbcutProcSpecs[k], sel = k == v[\proc];
        LooperTile().states_([[ps[\name], if(sel) { ~gt[\bg] } { ~gt[\ink] }, if(sel) { ~gt[\ink] } { nil }]])
            .cycles_(false).align_(\left).pad_(18).fixedHeight_(36).font_(~guiSans.(15, sel))
            .sw_(if(ps[\intensityKey].notNil) { "arc" } { nil })
            .toolTip_((ps[\desc] ? "") ++ if(ps[\intensityKey].notNil) { "\nThe Arc pedal drives it." } {
                "\nIt reads its params once when built: the Arc pedal leaves it alone." })
            .action_({
                // The lit one again would reset the voice to the procedure's defaults.
                if(sel.not) { ~looper.setVoiceProc(~bbcutSelVoice, k); { ~renderBBCutVoiceMenu.(); ~renderBBCutEditor.() }.defer } })
    };
    synthSeg = ~guiSeg.(~bbcutSynthLabels, (gap: 4, height: 32, font: ~guiMono.(13, true),
        action: { |i| ~looper.setVoiceSynth(~bbcutSelVoice, synthKeys[i]); { ~renderBBCutEditor.() }.defer }));
    ~guiSegSet.(synthSeg, synthIdx);
    synthSeg[\view].toolTip_("How each cut slice is played back from the loop buffer.\n"
        "CutBuf1: one PlayBuf, cheapest, no envelope (can click).\n"
        "CutBuf2: a fresh enveloped grain per cut — the default.\n"
        "CutBuf3: event-aware playback, keeps the original pitch at any tempo.");
    ratioSeg = ~guiSeg.(~bbcutRatioLabels, (gap: 4, height: 32, columns: 4, font: ~guiMono.(13, true),
        action: { |i| ~looper.setVoiceRatio(~bbcutSelVoice, ~bbcutRatios[i]); { ~renderBBCutEditor.() }.defer;
            { ~renderBBCutVoiceMenu.() }.defer }));
    ~guiSegSet.(ratioSeg, ratioIdx.indexOf(ratioIdx.minItem) ? 0);
    ratioSeg[\view].toolTip_("This voice's cut clock relative to the loop tempo. Voices at different ratios\n"
        "stay phase-locked to the same downbeat, so they form true polyrhythms (3:2 = three cuts\n"
        "against two).");
    left = View().fixedWidth_(240).layout_(VLayout(*([
        View().layout_(VLayout(caption.("PROCEDURE")).margins_([18, 14, 18, 6]))
    ] ++ procs ++ [
        View().layout_(VLayout(
            caption.("CUT SYNTH"), synthSeg[\view],
            ~guiHelp.(~guiText.(synthKeys[synthIdx].asString.replace("cutbuf", "CutBuf") ++ ": " ++ (~bbcutSynthHints[synthIdx] ? ""),
                12, ~gt[\mute])),
            caption.("RATIO · VS LOOP TEMPO"), ratioSeg[\view],
            nil
        ).margins_([18, 16, 18, 12]).spacing_(6)),
        nil
    ])).margins_(0).spacing_(0));

    // ---- right: the procedure's parameters, level, pan, effects --------------------
    // Rebuilt below only if this procedure has a parameter the arc drives, so
    // a stale label from the previous voice can never survive a re-render.
    ~bbcutDensityLabel = nil;
    ~bbcutDensityBar = nil;
    ~bbcutDensityEntry = nil;
    rows = spec[\params].collect { |entry|
        ~bbcutParamRow.(entry, v[\params][entry[\key]] ? entry[\default],
            (spec[\live] ? []).includes(entry[\key]), spec[\intensityKey] == entry[\key])
    };
    ampValue = ~guiMonoText.(v[\amp].round(0.01).asString, 14, ~gt[\ink]).align_(\right).fixedWidth_(128);
    ampBar = ~guiBar.(\cut, 16).value_(v[\amp])
        .toolTip_("Level of this voice against the dry loop and the other voices. Takes effect immediately.")
        .action_({ |sl| ~looper.setVoiceAmp(~bbcutSelVoice, sl.value); ampValue.string_(sl.value.round(0.01).asString) });
    panValue = ~guiMonoText.(v[\pan].round(0.01).asString, 14, ~gt[\ink]).align_(\right).fixedWidth_(128);
    panBar = ~guiBar.(\cut, 16).origin_(0.5).neutral_(0.5).value_((v[\pan] + 1) / 2)
        .toolTip_("Stereo position: far left … centre … far right. Takes effect immediately.")
        .action_({ |sl| var p = (sl.value * 2) - 1;
            ~looper.setVoicePan(~bbcutSelVoice, p); panValue.string_(p.round(0.01).asString) });
    fxTiles = fxKeys.collect { |k|
        var fs = l.bbcutFxSpecs[k], lit = v[\fx].includes(k);
        LooperTile().states_([[fs[\name], if(lit) { ~gt[\onacc] } { ~gt[\ink] }, if(lit) { ~gt[\cut] } { nil }]])
            .cycles_(false).align_(\left).pad_(12).fixedHeight_(34).font_(~guiSans.(14, true))
            .border_(if(lit) { ~gt[\cut] } { ~gt[\line] })
            .sw_(fs[\short] ? "").swFont_(~guiSans.(12))
            .toolTip_(fs[\desc] ? fs[\name])
            .action_({
                var fx = v[\fx].copy;
                if(fx.includes(k)) { fx.remove(k) } { fx = fx.add(k) };
                ~looper.setVoiceFx(~bbcutSelVoice, fx);
                { ~renderBBCutEditor.() }.defer;
            })
    };
    right = View().layout_(VLayout(*([
        ~guiHelp.(~guiText.(spec[\desc] ? "", 14, ~gt[\mute]))
    ] ++ rows ++ [
        HLayout(~guiText.("Amp", 15).fixedWidth_(120), [ampBar, stretch: 1], ampValue).spacing_(14).margins_(0),
        HLayout(~guiText.("Pan", 15).fixedWidth_(120), [panBar, stretch: 1], panValue).spacing_(14).margins_(0),
        ~guiHelp.(~guiText.(if(spec[\intensityKey].notNil) {
            "The tick is what the cutter uses right now; the bar is the value at full arc, which is what presets save."
        } { "This procedure reads its params once when it is built, so the Arc pedal leaves it alone." },
            13, ~gt[\mute])),
        nil,
        ~guiRule.(),
        caption.("VOICE EFFECTS"),
        GridLayout.rows(*fxTiles.clump(3)).hSpacing_(6).vSpacing_(6)
    ])).margins_([22, 14, 22, 16]).spacing_(13));

    editor.layout = HLayout(left, ~guiRule.(true), [right, stretch: 1]).margins_(0).spacing_(0);
    ~bbcutEditorHolder.children.copy.do { |c| c.remove };
    ~bbcutEditorHolder.layout.add(editor);
    ~bbcutRefreshDensity.();
};

// What the cutter is using for its arc-driven parameter, right now: the tick
// on its bar and the reading beside it, and the bar at the stored value (a
// preset or MIDI may have moved it). Repainted from the \intensity and
// \bbcutVoices handlers and after every render; a no-op when the selected
// procedure has no such parameter, or when the pane is not built.
~bbcutRefreshDensity = {
    ~bbcutDensityLabel !? { |t|
        var l = ~looper, entry = ~bbcutDensityEntry, v, stored, applied;
        if(t.isClosed.not and: { l.notNil } and: { entry.notNil }) {
            v = l.bbcutVoices[~bbcutSelVoice];
            stored = (v !? { |vv| vv[\params][entry[\key]] }) ? entry[\default];
            applied = l.voiceDensity(~bbcutSelVoice);
            t.string_(stored.round(0.01).asString ++ ~bbcutDensityTail.());
            ~bbcutDensityBar !? { |b|
                if(b.isClosed.not) {
                    b.tick_(applied !? { |a| (a - entry[\lo]) / (entry[\hi] - entry[\lo]) });
                    if(b.held.not) { b.value_((stored - entry[\lo]) / (entry[\hi] - entry[\lo])) };
                };
            };
        };
    };
};

// ---- Pane -----------------------------------------------------------------
~buildBBCutPane = {
    var pane = View().background_(~gt[\bg]);
    var preset;
    // Deferred preset routines from a previous build would otherwise keep
    // writing into the widgets this rebuild is about to destroy. Closing the
    // window used to do this; nothing closes when a pane is replaced.
    ~presetStopTimers.(\bbcut);
    ~bbcutEditorHolder = View().layout_(VLayout().margins_(0).spacing_(0));
    ~bbcutVoiceTabsHolder = View().layout_(VLayout().margins_(0).spacing_(0));
    preset = ~guiPresetParts.(\bbcut, (
        menu: "Saved cutter setups: every voice (procedure, cut synth, effects, ratio, amp, pan,\n"
            "params) plus the Mix/Insert/Gate mode. Choosing one recalls it straight away — the\n"
            "voices are rebuilt on the next beat, the dry loop keeps playing.",
        rescan: "Rescan your presets (bbcut/ in your megalooper folder) for files added or removed outside megalooper.",
        name: "File name for Save. Anything but letters and digits becomes '-', so \"Broken 3/2\"\n"
            "is saved as broken-3-2.scd.",
        save: "Write the current voices + mix mode to bbcut/<name>.scd in your megalooper folder. Reads 'Overwrite'\n"
            "when the name matches an existing preset; that one needs a second click to confirm.",
        delete: "Delete the selected preset file. Click once to arm, again to confirm. The running\n"
            "cutter keeps playing whatever it is playing."
    ));
    // The cutter's own master switch. Perform carries a second one; both write
    // the same flag and the model paints both, so they cannot disagree. Two of
    // them is deliberate: you want it under your hand while performing AND at
    // the top of the pane where you are editing what it switches on.
    ~bbcutPaneButton = ~midiTip.(LooperTile().cycles_(false).font_(~guiMono.(14, true))
        .fixedSize_(Size(96, 34)).border_(~gt[\cut])
        .action_({ ~looper.bbcut = ~looper.bbcut.not }),
        'looper.bbcut', "Master switch for the cutter — same as the B key.");
    ~bbcutModeSegSound = ~guiSeg.(["Mix", "Insert", "Gate"], (height: 32, font: ~guiSans.(14),
        action: { |i| ~looper !? { |lp| lp.bbcutMode = [\mix, \insert, \gate][i] } }));
    ~mapTag.(~bbcutModeSegSound[\view], 'looper.bbcutMode',
        "Mix = dry + cuts · Insert = dry ducks under repeats · Gate = cuts only");
    pane.layout_(VLayout(
        ~guiBand.(\cut),
        View().fixedHeight_(58).layout_(HLayout(
            ~guiTitle.("Cutter", 26),
            ~bbcutPaneButton,
            ~bbcutModeSegSound[\view].fixedWidth_(220),
            nil,
            [preset[\menu].minWidth_(240), stretch: 1]
        ).margins_([22, 0, 22, 0]).spacing_(14)),
        ~guiRule.(),
        View().layout_(VLayout(preset[\edit]).margins_([22, 10, 22, 10])),
        ~guiRule.(),
        ~bbcutVoiceTabsHolder,
        ~guiRule.(),
        [~bbcutEditorHolder, stretch: 1]
    ).margins_(0).spacing_(0));
    ~refreshBBCutPresetList.();
    ~renderBBCutVoiceMenu.();
    ~renderBBCutEditor.();
    ~bbcutPaintHeader.();

    ~bbcutPane = pane;
    ~guiSwapPane.(\cutter, pane);
    pane
};
)
