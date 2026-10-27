// megalooper — the Effects pane: Megalooper SA's effects, each with its switch
// and its settings as knobs, Bias FX's own window, and presets of the whole
// sound (docs/dev/megalooper-sa.md, Phase 6, brought forward).
//
// Loaded by boot.scd; defines only, runs nothing. Entry point:
//   ~buildEffectsPane — builds the pane against the EXISTING ~megaSA and swaps
//                       it into the shell's holder. Only an SA rig has the tab
//                       (gui-shell.scd), and the pane says so if it is built
//                       without one.
//
// The chains across the top read like the Live set's tracks: the guitar's
// devices in their order into Bias FX, then the loop's, a tile per device of
// MegaSA's chains (docs/dev/device-chains.md, phase 2): a device inserted, moved
// or removed (from the IDE, until the window gets its own menus) redraws the
// rows. A first click on a tile shows its settings in the editor below; a
// second switches it on or off, exactly as its footswitch does. The editor
// shows one device at a time, so the drums keep the rest of the view.
//
// A tile's key is its device's id (\delay, \delay2), but the plugin's is
// \bias, as it was before the chains: there is one plugin until the catalog
// comes (phase 5). Only the default devices' controls are tagged for the MIDI
// map: the targets of further ones come with phase 4.
//
// As everywhere in this GUI, a widget writes to the model only, and the
// model's notifications (MegaSA's \fx and \fxParam, the plugin's \state) paint
// it back. That is what keeps a footswitch, a preset recall, Reset and the
// knob itself all showing the same number.
(
~effectsCellWidth = 150;    // one setting: its label and readout over its bar
~effectsPerRow = 7;
~effectsLabelWidth = 64;    // the preset bar's labels
// The effect the editor shows. Survives a rebuild, so rebuilding the window
// does not throw away what you were tuning.
~effectsSelected = ~effectsSelected ? MegaSAFx.guitarKeys.first;

// One line per effect, under its title. What the rebuild is, in the words of
// the Live device it copies; the tips on the knobs say the rest.
~effectsBlurbs = (
    shifter: "A pitch shifter: a hair of detune, mostly the grain of its window",
    delay: "Two delay taps with an LFO beside them, wandering the modulation",
    filter: "An envelope wah: pick harder, the band goes up",
    pitchLoop: "An octave-up voice and a reversed one beside the dry",
    echo: "A tape echo on the loop, synced to its tempo, ducking under it",
    saturator: "A drive with the lows driven hardest",
    redux: "Fewer samples, fewer bits, gritty on purpose",
    eq: "Four bands and a low and a high cut, flat at its defaults",
    compressor: "Evens the level: above the threshold, turned down by the ratio",
    noiseGate: "Shuts between notes, so hum and hiss go with them",
    bias: "The amp: the plugin this rig is set up with, and its sound as kept here"
);

// ---- Value <-> knob -------------------------------------------------------
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

// ---- View state -----------------------------------------------------------
// Emptied on close and on every rebuild, so a notification arriving after the
// window is gone finds nothing to write to rather than a destroyed view.
// Re-loading this file removes the controllers a pane already hung on the
// model first, or they would stay subscribed with nothing to paint.
(~effectsControllers ? []).do(_.remove);
~effectsControllers = [];
// The editor's widgets, for the one device it shows (~effectsSelected).
~effectsWidgets = IdentityDictionary.new;   // setting -> (knob: or menu:, readout:, param:)
~effectsTiles = IdentityDictionary.new;     // device key -> (select:, on:)
// The rows' holders (scrolling, so more devices never widen the window), and
// the controllers on further devices, which say their settings themselves.
(~effectsDeviceControllers ? []).do(_.remove);
~effectsDeviceControllers = [];
~effectsRowHolders = ();
// The setting whose knob the mouse is holding. Its knob is not repositioned by
// the model while held: a stepped setting snapped back under the hand would
// never move.
~effectsHeld = nil;

~guiTeardowns = ~guiTeardowns ? ();
~guiTeardowns[\effects] = {
    ~effectsControllers.do(_.remove);
    ~effectsControllers = [];
    ~effectsDeviceControllers.do(_.remove);
    ~effectsDeviceControllers = [];
    ~effectsRowHolders = ();
    ~effectsChainPending = false;
    ~effectsWidgets = IdentityDictionary.new;
    ~effectsTiles = IdentityDictionary.new;
    ~effectsEditorHolder = nil;
    ~effectsStatusText = nil;
    ~effectsBiasStatus = nil;
    ~effectsBiasTileStatus = nil;
    ~effectsHeld = nil;
};

// The footswitch's program for an effect, as the MIDI map in use has it.
~effectsProgram = { |key| ~midiProgram.(("sa.fxOn." ++ key).asSymbol) };

// ---- Devices ----------------------------------------------------------------
// A tile's device: the plugin's for \bias, else the device with that id, or
// nil (no SA, or no such device any more).
~effectsDeviceOf = { |key|
    ~megaSA !? { |m| if(key == \bias) { m.devices.detect(_.isPlugin) } { m.device(key) } }
};
~effectsKeyOf = { |d| if(d.isPlugin) { \bias } { d.id } };
// Every built-in device's controls are the MIDI map's targets: the default
// ones' under today's ids (sa.fxOn.delay, sa.fx.delayMix), a further one's
// under its own (sa.fxOn.delay2, sa.fx.delay2.delayMix). The plugin's tile
// has none.
~effectsHasTargets = { |key| key != \bias };
~effectsParamTarget = { |dev, name|
    (if(MegaSAFx.typeKeys.includes(dev)) { "sa.fx." ++ name } { "sa.fx." ++ dev ++ "." ++ name }).asSymbol
};
// What the first plugin is called in the pane's words: "Bias FX" for Bias FX
// 2, as it always was here; another plugin by its device's name, so a
// stranger's amp is called what it is; "the plugin" while there is none.
~effectsPluginWord = {
    var d = ~megaSA !? { |m| m.devices.detect(_.isPlugin) };
    case
    { d.isNil } { "the plugin" }
    { d.name.asString.toUpper.contains("BIAS FX") } { "Bias FX" }
    { d.name.asString }
};
~effectsTitle = { |key|
    if(key == \bias) { if(~effectsPluginWord.() == "the plugin") { "Bias FX" } { ~effectsPluginWord.() } } { (~effectsDeviceOf.(key) !? { |d| d.name }) ? MegaSAFx.title(key) }
};

// ---- Sounds ---------------------------------------------------------------
// The shared bar (gui-presets.scd) over MegaSA's sounds (docs/dev/device-chains.md
// section 11): a sound is both chains, which devices in which order, every
// setting, and Bias FX's own sound. Recalling one that has the devices
// there are moves no switch; one with other devices changes the chains.
~definePresetFamily.(\saFx, (
    label:      "Sounds",
    caption:    "sound",
    statusIdle: "Pick a sound to recall it · Save keeps every chain, every knob and each plugin's sound",
    dirKey:     \saFxPresetDir,
    names:      \soundNames,
    slug:       \fxPresetSlug,
    save:       \saveSound,
    load:       \loadSound,
    delete:     \deleteSound,
    ext:        ".json",
    // The file is written once the plugin has saved its state: \soundSaved
    // (below) says when, and selects it.
    async:      true,
    model:      { ~megaSA }
));

// Start with this's mark: a dot while the chains or their settings differ from
// what was last kept (MegaSA.dirty). A footswitch is no unkept edit. Asked a
// moment after the last change, not at every step of a knob.
~effectsPaintKeep = {
    ~effectsKeepPending = false;
    ~effectsKeepButton !? { |b|
        if(b.isClosed.not) {
            b.states_([[if((~megaSA !? { |m| m.dirty }) == true) { "Start with this •" } { "Start with this" }, ~gt[\ink], ~gt[\panel]]]);
        };
    };
    // Chain edits a last run left unkept (setup-sa.scd's ~saRecovery): the
    // way back is shown while there is one.
    // (~effectsRecoverShown says which: a view's own `visible` answers
    // false while its window is not on screen, whatever it was set to.)
    ~effectsRecoverShown = ~saRecovery.notNil;
    ~effectsRecoverButton !? { |b| if(b.isClosed.not) { b.visible_(~effectsRecoverShown) } };
};
~effectsKeepSoon = {
    if(~effectsKeepPending != true) {
        ~effectsKeepPending = true;
        AppClock.sched(0.3, { if(~effectsKeepPending == true) { ~effectsPaintKeep.() }; nil });
    };
};

// ---- Model -> view --------------------------------------------------------
// A setting of the device `id` (by default the one its name belongs to: the
// default device of its effect, as \fxParam says). The editor's widgets are
// painted only when they are that device's: two Delays share the names.
~effectsRefreshParam = { |name, val, id|
    id = id ?? { MegaSAFx.param(name) !? { |p| p[\fx] } };
    if(id == ~effectsSelected) {
        ~effectsWidgets[name] !? { |w|
            w[\readout].string_(~effectsFormat.(w[\param], val));
            w[\menu] !? { |m|
                m.value = w[\param][\choices].collect { |pair| pair[0] }.indexIn(val) };
            w[\knob] !? { |k| if(~effectsHeld != name) { k.value = ~effectsUnmap.(w[\param], val) } };
        };
    };
    id !? { ~effectsRefreshTile.(id) };
};

// A tile: filled in the effects' colour while it is on, outlined in \ink while
// the editor shows it, its name marked with a dot while any of its settings is
// off the Live set's value; under the name whether it is on, whether it is
// being edited, and its footswitch.
~effectsRefreshTile = { |key|
    var m = ~megaSA;
    ~effectsTiles[key] !? { |t|
        var tile = t[\select];
        var sel = (key == ~effectsSelected);
        var title = ~effectsTitle.(key);
        var edited = (key != \bias) and: { m.notNil } and: { m.fxEdited(key) };
        var on = (key != \bias) and: { (m !? { |mm| mm.fx(key) }) == true };
        var label = title ++ if(edited) { " •" } { "" };
        var pc = if(~effectsHasTargets.(key)) { ~effectsProgram.(key) };
        var sub = if(key == \bias) { ~effectsBiasState.() } {
            if(on) { "ON" } { "off" } };
        if(tile.isClosed.not) {
            tile.states_([[label, ~gt[\ink], ~gt[\panel]], [label, ~gt[\onacc], ~gt[\fx]]]);
            tile.value_(on.binaryValue);
            tile.border_(case { sel } { ~gt[\ink] } { on } { ~gt[\fx] } { ~gt[\line] });
            tile.sub_(sub ++ if(sel) { " · editing" } { "" } ++ (pc !? { |n| " · PC " ++ n } ? ""));
            // The switch: a square, filled when on (not the plugin's tile: its
            // state is the line under it).
            if(key != \bias) { tile.sw_(if(on) { "■" } { "□" }) };
        };
    };
};

~effectsRefreshAll = {
    ~effectsDeviceOf.(~effectsSelected) !? { |d|
        d.params.do { |p| ~effectsRefreshParam.(p[\name], d.param(p[\name]), ~effectsKeyOf.(d)) };
    };
    ~effectsTiles.keysDo { |k| ~effectsRefreshTile.(k) };
};

// ---- Builders -------------------------------------------------------------
// One setting of the device `id` (by default the setting's own effect's
// default device): the label and the readout over a bar in the effects'
// colour (filled from the middle for one that is centred), or a menu for a
// choice. A double-click puts it back to the Live set's value.
~effectsKnobCell = { |p, id|
    var m = ~megaSA;
    var dev = id ? p[\fx];
    var val = m.param(dev, p[\name]);
    var readout = ~guiMonoText.(~effectsFormat.(p, val), 13, ~gt[\ink]).align_(\right);
    var control;
    if(p[\choices].notNil) {
        // A choice (the echo's synced divisions) is a menu: a bar between
        // eight note values is hard to land on by feel.
        control = PopUpMenu().canFocus_(false).font_(~guiSans.(13))
            .background_(~gt[\panel]).stringColor_(~gt[\ink])
            .items_(p[\choices].collect { |pair| pair[1] })
            .value_(p[\choices].collect { |pair| pair[0] }.indexIn(val))
            .action_({ |menu|
                ~megaSA !? { |mm| mm.setParam(dev, p[\name], p[\choices][menu.value][0]) } });
        ~effectsWidgets.put(p[\name], (menu: control, readout: readout, param: p));
    } {
        control = ~guiBar.(\fx, 14)
            .origin_(if(p[\centered] == true) { 0.5 } { 0 })
            .neutral_(if(p[\centered] == true) { 0.5 } { nil })
            .value_(~effectsUnmap.(p, val))
            .action_({ |k| ~megaSA !? { |mm| mm.setParam(dev, p[\name], ~effectsMap.(p, k.value)) } })
            .mouseDownAction_({ |k, x, y, mods, button, clicks|
                ~effectsHeld = p[\name];
                if(clicks == 2) {
                    ~megaSA !? { |mm| mm.setParam(dev, p[\name], p[\spec].default) };
                    true
                } { nil };
            })
            .mouseUpAction_({ |k|
                ~effectsHeld = nil;
                // Now the hand is off it, show where the setting really is.
                ~megaSA !? { |mm| mm.param(dev, p[\name]) !? { |v| k.value = ~effectsUnmap.(p, v) } };
                nil
            });
        ~effectsWidgets.put(p[\name], (knob: control, readout: readout, param: p));
    };
    // Either way, its tooltip ends with what drives it in the MIDI map.
    if(~effectsHasTargets.(dev)) { ~mapTag.(control, ~effectsParamTarget.(dev, p[\name]), p[\tip]) } {
        control.toolTip_(p[\tip]) };
    View().fixedWidth_(~effectsCellWidth).layout_(VLayout(
        HLayout(~guiText.(p[\label], 13, ~gt[\mute]).toolTip_(p[\tip]), nil, readout).margins_(0),
        control
    ).margins_(0).spacing_(4))
};

// One tile of the chain. Its square, top right, switches it on or off, as its
// footswitch does; a click anywhere else shows its settings below and never
// changes the sound (once a second click on the tile shown switched it, and
// looking at an effect on stage could change it). A double-click on the
// square is not two switches: one within 0.4 s of the last is let go. A value
// set from outside (the checks, MIDI Map's drive) sets its switch.
~effectsSwitchSize = 40;
~effectsOnSwitch = { |tile|
    var p = ~effectsPress;
    p.notNil and: { p[\tile] === tile } and: { p[\x] >= (tile.bounds.width - ~effectsSwitchSize) } and: { p[\y] < 32 }
};
~effectsTile = { |key|
    var tile = LooperTile().cycles_(false).align_(\left).pad_(12)
        .font_(~guiSans.(16, true)).subFont_(~guiMono.(11, true)).swFont_(~guiMono.(18, true))
        .fixedSize_(Size(182, 58)).borderWidth_(2)
        .action_({ |t, mods|
            case
            { mods.isNil } { ~megaSA !? { |mm| mm.setFx(key, t.value == 1) } }
            { ~effectsOnSwitch.(t) } {
                if((Main.elapsedTime - (~effectsSwitchedAt ? -1)) > 0.4) {
                    ~effectsSwitchedAt = Main.elapsedTime;
                    ~megaSA !? { |mm| mm.fx(key) !? { |on| mm.setFx(key, on.not) } } };
            }
            { ~effectsSelect.(key) };
        });
    if(~effectsHasTargets.(key)) { ~mapTag.(tile, ("sa.fxOn." ++ key).asSymbol) };
    // Its tooltip says what drives it, and follows the map when it changes.
    ~midiWatch.(tile, { |t|
        t.toolTip_("Click to show its settings below; its square, top right, switches it on or off, as its footswitch does"
            ++ (if(~effectsHasTargets.(key)) { ~midiWords.(("sa.fxOn." ++ key).asSymbol) } !? { |w| " (" ++ w ++ ")" } ? "")
            ++ ".");
        ~effectsRefreshTile.(key);
    });
    ~effectsTiles.put(key, (select: tile, on: tile));
    tile
};

~effectsBiasTile = {
    var tile = LooperTile().cycles_(false).align_(\left).pad_(12)
        .font_(~guiSans.(16, true)).subFont_(~guiMono.(11, true)).fixedSize_(Size(182, 58)).borderWidth_(2)
        .toolTip_(if(~effectsPluginWord.() == "Bias FX") { "The amp: Bias FX 2." } { ~effectsPluginWord.() ++ ", a plugin." }
            ++ " Click to show its controls below.")
        .action_({ ~effectsSelect.(\bias) });
    // What the plugin is doing ("open", "failed") is the tile's line.
    ~effectsBiasTileStatus = tile;
    ~effectsTiles.put(\bias, (select: tile));
    tile
};

// A further plugin's tile (the first plugin's is the \bias tile above): its
// name and what it is doing. A click selects it, as for any device: its page
// below has the button for its own window, and ⋯ moves or removes it. Kept in
// ~effectsPluginTiles by its device's id, with what paints it in
// ~effectsPluginPaints: painted anew when its plugin says \state and when the
// selection moves.
~effectsPluginState = { |d|
    d.plugin !? { |p| if((p.state == \open) and: { p.held.notNil }) { "held" } { p.state.asString } } ? "not on this Mac"
};
~effectsPluginTile = { |d|
    var tile = LooperTile().cycles_(false).align_(\left).pad_(12)
        .font_(~guiSans.(16, true)).subFont_(~guiMono.(11, true)).fixedSize_(Size(182, 58)).borderWidth_(2)
        .toolTip_(d.name ++ ", a plugin. Click to show its page below.")
        .action_({ ~effectsSelect.(d.id) });
    var paint = {
        var sel = (~effectsSelected == d.id);
        if(tile.isClosed.not) {
            tile.states_([[d.name, ~gt[\ink], ~gt[\panel]]]);
            tile.border_(if(sel) { ~gt[\ink] } { ~gt[\line] });
            tile.sub_(~effectsPluginState.(d) ++ if(sel) { " · editing" } { "" });
        };
    };
    paint.value;
    d.plugin !? { |p|
        ~effectsDeviceControllers = ~effectsDeviceControllers.add(SimpleController(p).put(\state, {
            // Its page says what it is doing too: made again if it is shown.
            { paint.value; ~effectsPaintStatus.(); if(~effectsSelected == d.id) { ~effectsSelect.(d.id) } }.defer
        }));
    };
    ~effectsPluginTiles = (~effectsPluginTiles ?? { IdentityDictionary.new }).put(d.id, tile);
    ~effectsPluginPaints = (~effectsPluginPaints ?? { IdentityDictionary.new }).put(d.id, paint);
    tile
};
// What a further plugin's page says of it.
~effectsPluginLine = { |d|
    d.plugin !? { |p|
        p.name ++ ": " ++ if((p.state == \open) and: { p.held.notNil }) { "open, but " ++ p.held } { p.state.asString }
            ++ (p.loadSec !? { |t| " · opened in " ++ t.round(0.1) ++ " s" } ? "")
    } ? (d.name ++ " is not on this Mac. Its place and its sound are kept.")
};

// "held" for a plugin open but held off for its latency (MegaSAPlugin.held),
// whose line then says why.
~effectsBiasState = {
    ~megaSA !? { |m| m.guitarPlugin !? { |p|
        if((p.state == \open) and: { p.held.notNil }) { "held" } { p.state.asString } } ? "none" } ? "—"
};

~effectsBiasLine = {
    ~megaSA !? { |m|
        m.guitarPlugin !? { |p|
            p.name ++ ": " ++ if((p.state == \open) and: { p.held.notNil }) { "open, but " ++ p.held } { p.state.asString }
                ++ (p.bank !? { |b| " · sound " ++ PathName(b).fileNameWithoutExtension } ? "")
                ++ (p.loadSec !? { |t| " · opened in " ++ t.round(0.1) ++ " s" } ? "")
        } ? "No plugin: the instrument plays dry."
    } ? "Megalooper SA is not running."
};

// A plugin's sends: eight tiles, each sending the plugin its MIDI controller
// (MegaSA.pluginSend). What the plugin does with one it learns itself, in its
// own window: megalooper hears your controllers, the plugin does not. A
// footswitch goes on a tile in MIDI Map mode, as on any control.
~effectsSendHint = "The numbers each send the plugin a MIDI controller. Teach the plugin with its own MIDI learn "
    "(press its Learn, then a number here), then put a footswitch on that number in MIDI MAP.";
~effectsSendRow = { |dev|
    var tiles = (1..MegaSA.pluginSends).collect { |n|
        var id = ("sa.fxSend." ++ dev.id ++ "." ++ n).asSymbol;
        var tip = "Sends " ++ dev.name ++ " the MIDI controller " ++ MegaSA.pluginSendCC(n)
            ++ " (value 127, channel 1), for the plugin's own MIDI learn.";
        var tile = LooperTile().states_([[n.asString, ~gt[\ink], ~gt[\panel]]]).border_(~gt[\line]).cycles_(false)
            .font_(~guiMono.(13, true)).fixedHeight_(28).fixedWidth_(44)
            .action_({
                ~megaSA !? { |m|
                    if(m.pluginSend(dev.id, n).not) {
                        ~presetSetStatus.(\saFx, dev.name ++ " is not open: nothing was sent.", true) };
                };
            });
        ~mapTag.(tile, id, tip);
        tile
    };
    HLayout(*([~guiText.("MIDI to the plugin", 13, ~gt[\mute]).fixedWidth_(172)] ++ tiles ++ [nil])).spacing_(8).margins_(0)
};

// The editor for one effect, or Bias FX's controls for \bias.
~effectsEditor = { |key|
    var m = ~megaSA;
    var view = View();
    var params, rows, small, dev, reset, random, tip;
    small = { |label, width, action, tip|
        LooperTile().states_([[label, ~gt[\ink], ~gt[\panel]]]).border_(~gt[\line]).cycles_(false)
            .font_(~guiSans.(13)).fixedHeight_(28).fixedWidth_(width).toolTip_(tip ? "").action_(action)
    };
    if(key == \bias) {
        dev = ~effectsDeviceOf.(\bias);
        view.layout_(VLayout(*([
            HLayout(
                ~guiText.(~effectsTitle.(\bias) ++ " ·", 16, nil, true).minWidth_(150),
                ~guiText.(if(~effectsPluginWord.() == "Bias FX") { ~effectsBlurbs[\bias] } {
                    "A plugin: its controls are in its own window." }, 13, ~gt[\mute]),
                nil
            ).spacing_(30).margins_(0),
            HLayout(
                View().fixedWidth_(150),
                ~effectsBiasStatus = ~guiMonoText.(~effectsBiasLine.(), 13, ~gt[\ink]),
                small.("Open its window", 130, { ~megaSA !? { |mm| mm.guitarEditor } },
                    if(~effectsPluginWord.() == "Bias FX") { "Bias FX's own editor: amps, cabinets, its pedals." } {
                        "The plugin's own editor." }),
                nil
            ).spacing_(30).margins_(0)]
            ++ if(dev.notNil) { [~effectsSendRow.(dev), ~guiText.(~effectsSendHint, 13, ~gt[\mute])] } { [] }
            ++ [~guiText.("Its sound is kept with every sound saved above, and by Start with this, while the loop is stopped.", 13, ~gt[\mute]),
            nil]
        )).margins_(0).spacing_(8));
    } {
      dev = ~effectsDeviceOf.(key);
      if(dev.notNil and: { dev.isPlugin }) {
        // A further plugin's page: what it is doing, and its own window.
        view.layout_(VLayout(
            HLayout(
                ~guiText.(dev.name ++ " ·", 16, nil, true).minWidth_(150),
                ~guiText.("A plugin: its controls are in its own window.", 13, ~gt[\mute]),
                nil
            ).spacing_(30).margins_(0),
            HLayout(
                ~guiMonoText.(~effectsPluginLine.(dev), 13, ~gt[\ink]),
                small.("Open its window", 130, { dev.plugin !? { |p| p.editor } }, "The plugin's own editor."),
                nil
            ).spacing_(30).margins_(0),
            ~effectsSendRow.(dev),
            ~guiText.(~effectsSendHint, 13, ~gt[\mute]),
            ~guiText.("Its sound is kept with every sound saved above, and by Start with this, while the loop is stopped.", 13, ~gt[\mute]),
            nil
        ).margins_(0).spacing_(8));
      } {
        params = dev !? { |d| d.params } ? [];
        rows = params.clump(~effectsPerRow).collect { |row|
            HLayout(*(row.collect { |p| ~effectsKnobCell.(p, key) } ++ [nil])).spacing_(30).margins_(0)
        };
        reset = small.("Reset", 104, { ~megaSA !? { |mm| mm.resetFx(key) } });
        // A device's reset is a MIDI target: its tip says what it is bound
        // to (~mapTag keeps that line up to date).
        tip = "Every setting of this effect back to its starting value, which each\n"
            "bar's tip gives. A double-click does it for one bar.";
        if(~effectsHasTargets.(key)) { ~mapTag.(reset, ("sa.fxReset." ++ key).asSymbol, tip) } { reset.toolTip_(tip) };
        // Random, beside it: every setting at once, to try sounds out.
        random = small.("Random", 104, { ~megaSA !? { |mm| mm.randomizeFx(key) } });
        tip = "Every setting of this effect at a random value, to try out sounds.\n"
            "The levels it ends on (Output, the filter's Makeup) stay where they are.\n"
            "Reset puts the starting values back; Save variation keeps one you like.";
        if(~effectsHasTargets.(key)) { ~mapTag.(random, ("sa.fxRandom." ++ key).asSymbol, tip) } { random.toolTip_(tip) };
        view.layout_(VLayout(*([
            HLayout(*([
                ~guiText.(~effectsTitle.(key) ++ " ·", 16, nil, true),
                ~guiText.(dev !? { |d| ~effectsBlurbs[d.type] } ? "", 13, ~gt[\mute]),
                nil,
                random, reset
            ])).spacing_(14).margins_(0)
        ] ++ (dev !? { |d| [~effectsVariationRow.(key, d, small)] } ? []) ++ rows ++ [nil])).margins_(0).spacing_(10));
      };
    };
    view
};

// An effect's variations: the menu, then a name and Save variation. The menu
// holds the Live set's variations of the device's type (recalling one moves
// only the settings that rack's macros drove), then yours (every setting),
// then a Delete for each of yours. Its first item is a label, so every
// variation stays one pick away, the one just recalled included. A Delay's
// variations are every Delay's. Save variation keeps the device's settings
// under the name typed (~saSaveVariation); on one of yours that name has, it
// says Replace. The editor is built again after a save or a delete, so the
// menu lists what is there.
~effectsVariationRow = { |key, dev, small|
    var list = (~saFxVariations !? { |v| v[dev.type] }) ? [];
    var own = list.select { |v| v[2] == true };
    var picks = list.collect { |v| [if(v[2] == true) { v[0] ++ "  · yours" } { v[0] }, \recall, v[0]] }
        ++ own.collect { |v| ["Delete: " ++ v[0], \delete, v[0]] };
    var menu, field, save, label, refresh;
    label = { |name| if(own.any { |v| v[0] == name }) { "Replace" } { "Save variation" } };
    refresh = { if(save.isClosed.not) { save.states_([[label.(field.string.stripWhiteSpace), ~gt[\ink], ~gt[\panel]]]) } };
    menu = PopUpMenu().canFocus_(false).fixedWidth_(220).font_(~guiSans.(13))
        .background_(~gt[\panel]).stringColor_(~gt[\ink])
        .toolTip_("This effect's variations: the ones megalooper ships ('starting values'\n"
            "is where these bars start; one moves only the settings its rack drove),\n"
            "then yours (every setting). Delete removes one of yours.")
        .items_([if(list.isEmpty) { "No variations yet" } { "Variation…" }] ++ picks.collect { |x| x[0] })
        .action_({ |mn|
            var pick = if(mn.value > 0) { picks[mn.value - 1] };
            case
            { pick.isNil } { }
            { pick[1] == \recall } {
                ~saApplyVariation.(key, pick[2]);
                field.string_(pick[2]);
                refresh.();
                mn.items = ["Recalled: " ++ pick[2]] ++ picks.collect { |x| x[0] };
                mn.value = 0;
            }
            { pick[1] == \delete } {
                ~saDeleteVariation.(dev.type, pick[2], { |ok, why|
                    {
                        if(ok) { ~guiSay.("Deleted the variation '" ++ pick[2] ++ "'", \info);
                            ~effectsSelect.(~effectsSelected) } {
                            ~guiSay.("The variation was not deleted: " ++ why, \bad);
                            mn.value = 0 };
                    }.defer;
                });
            };
        });
    field = TextField().font_(~guiSans.(14)).background_(~gt[\panel]).stringColor_(~gt[\ink])
        .fixedWidth_(180)
        .toolTip_("A name for these settings. Save variation keeps them under it, for every\n"
            "effect of this type; a name of yours already there is replaced.")
        .action_({ ~guiWindow !? { |w| w.view.focus(true) } })
        .focusGainedAction_({ |v|
            v.background_(~gt[\armed]).stringColor_(~gt[\onacc]);
            ~guiSetTyping !? { |f| f.(true) };
        })
        .focusLostAction_({ |v|
            v.background_(~gt[\panel]).stringColor_(~gt[\ink]);
            ~guiSetTyping !? { |f| f.(false) };
        })
        .keyDownAction_({ |v, char, mods, uni|
            if(uni == 27) { ~guiWindow !? { |w| w.view.focus(true) }; true } {
                // Deferred, so it reads the string Qt has just changed.
                { refresh.() }.defer(0);
                nil
            }
        });
    save = small.("Save variation", 130, {
        var name = field.string.stripWhiteSpace;
        ~saSaveVariation.(dev.id, name, { |ok, why|
            {
                if(ok) {
                    ~guiSay.((if(why == \replaced) { "Replaced" } { "Saved" }) ++ " the variation '" ++ name
                        ++ "' of " ++ MegaSAFx.title(dev.type), \info);
                    ~effectsSelect.(~effectsSelected);
                } { ~guiSay.("The variation was not saved: " ++ why, \bad) };
            }.defer;
        });
    }, "Keep this effect's settings, every one as it stands, as a variation\n"
        "under the name beside it. It is in your megalooper folder\n"
        "(sa/fx-variations.json), and in this menu for every effect of this type.");
    ~effectsVariationField = field;
    ~effectsVariationSave = save;
    ~effectsVariationMenu = menu;
    HLayout(menu, field, save, nil).spacing_(14).margins_(0)
};

// Show `key` in the editor. The old editor's widgets go from the table first:
// they are about to be destroyed.
~effectsSelect = { |key|
    ~effectsSelected = key;
    ~effectsHeld = nil;
    ~effectsBiasStatus = nil;
    ~effectsWidgets = IdentityDictionary.new;
    ~effectsEditorHolder !? { |h|
        h.children.copy.do { |c| c.remove };
        h.layout.add(~effectsEditor.(key));
    };
    ~effectsTiles.keysDo { |k| ~effectsRefreshTile.(k) };
    (~effectsPluginPaints ? ()).do { |f| f.value };
};

// ---- The rows ---------------------------------------------------------------
// Whether the editor may show `key`: the plugin's page, or a device in a
// chain. Else the first built-in of the guitar chain (or the loop's).
// \bias is the first plugin's key: there to select while a plugin is in the
// chains, and as the one page left when the chains hold nothing at all.
~effectsSelectable = { |key|
    ~effectsDeviceOf.(key).notNil or: { (key == \bias) and: { ~megaSA.isNil or: { ~megaSA.devices.isEmpty } } }
};
~effectsFirstKey = {
    ~megaSA !? { |m| m.devices.detect { |d| d.isPlugin.not } } !? { |d| d.id } ? \bias
};
// The chains the pane shows a row for, in the order of their rows: the bass's
// under the guitar's, the two inputs together, and only on a rig with a bass
// input (without one its chain plays silence, and its row would offer
// effects nobody hears); the synth's last, after the drums'.
~effectsTracks = {
    [\guitar, \bass, \loop, \drums, \synth].select { |t|
        MegaSASound.trackNames.includes(t) and: { (t != \bass) or: { (~megaSA !? { |m| m.bassIn }).notNil } } }
};
~effectsRowCaptions = (guitar: "INSTRUMENT", bass: "BASS", loop: "LOOP", drums: "DRUMS", synth: "SYNTH");

// ---- The status line ------------------------------------------------------------
// Under the rows: the drum hits the language had to drop, and every plugin
// that is not simply open (opening, held, failed, crashed, not on this Mac).
// The server's load is the top bar's CPU tile, on every view. Read once a second while the pane is there, and at once
// when a plugin says \state. ~effectsStatus answers [the line, whether
// something in it wants attention].
~effectsStatus = {
    var m = ~megaSA, parts = List.new, bad = false, dropped;
    if(m.isNil) { ["", false] } {
        dropped = (try { m.drums.dropped }) ? 0;
        if(dropped > 0) {
            parts.add(dropped.asString ++ if(dropped == 1) { " drum hit dropped" } { " drum hits dropped" });
            bad = true;
        };
        m.devices.select(_.isPlugin).do { |d|
            var state = ~effectsPluginState.(d);
            if(state != "open") {
                parts.add(d.name ++ ": " ++ state);
                if(#["opening", "closed"].includesEqual(state).not) { bad = true };
            };
        };
        [parts.join("  ·  "), bad]
    }
};
~effectsPaintStatus = {
    var status = ~effectsStatus.();
    ~effectsStatusText !? { |t|
        if(t.isClosed.not and: { status != ~effectsStatusPainted }) {
            ~effectsStatusPainted = status;
            t.string_(status[0]).stringColor_(if(status[1]) { ~gt[\rec] } { ~gt[\mute] });
        };
    };
};

// What to send along when something is wrong, as text: the build, the
// server's load, both chains with every device's switch and each plugin's
// state, the catalog's size and the status line. ⋯ copies it to the
// clipboard ("Copy diagnostics").
~effectsDiagnostics = {
    var m = ~megaSA, lines = List.new, offered;
    lines.add("megalooper diagnostics, " ++ Date.getDate.stamp);
    lines.add("build: " ++ ((try { ~saBuild.() }) ? "unknown") ++ " · SuperCollider " ++ Main.version
        ++ " · VSTPlugin " ++ if(MegaSAPlugins.available) { "installed" } { "not installed" });
    if(m.isNil) { lines.add("Megalooper SA is not running.") } {
        lines.add("server: " ++ ((try { m.server.sampleRate }) ? "?") ++ " Hz, CPU "
            ++ ((try { m.server.avgCPU.round(0.1) }) ? "?") ++ " % (peak " ++ ((try { m.server.peakCPU.round(0.1) }) ? "?") ++ " %)"
            ++ " · drum hits dropped: " ++ ((try { m.drums.dropped }) ? "?"));
        ~effectsTracks.().do { |track|
            var chain = m.chainFor(track);
            lines.add(track ++ " chain" ++ if(chain.notNil and: { chain.built.not }) { " (not built)" } { "" } ++ ":");
            (chain !? { |c| c.devices } ? []).do { |d|
                lines.add("  " ++ d.id ++ " (" ++ d.type ++ ") \"" ++ d.name ++ "\" " ++ if(d.on) { "on" } { "off" }
                    ++ if(d.isPlugin) { " · " ++ ~effectsPluginLine.(d) } { "" });
            };
        };
        offered = MegaSAPlugins.offered(~saPlugins ? []);
        lines.add("plugins found: " ++ (~saPlugins ? []).size ++ ", of which megalooper can host "
            ++ offered.count { |e| e[\why].isNil });
        lines.add("status: " ++ ~effectsStatus.()[0]);
        lines.add("sound: " ++ (m.soundName ? "none") ++ if(m.dirty) { " (not kept)" } { "" });
    };
    lines.join("\n")
};
// The text onto the clipboard (MegaFiles.clipboardCommand: pbcopy on macOS,
// wl-copy, xclip or xsel on Linux), said in the bar. With no such tool it
// goes to the post window, and the bar says where.
~effectsCopyDiagnostics = {
    var text = ~effectsDiagnostics.(), cmd = MegaFiles.clipboardCommand, pipe;
    if(cmd.isNil) {
        text.postln;
        ~presetSetStatus.(\saFx, "No clipboard tool here (wl-copy or xclip): the diagnostics are in the post window.", true);
    } {
        pipe = Pipe(cmd, "w");
        pipe.write(text);
        pipe.close;
        ~presetSetStatus.(\saFx, "Diagnostics copied: paste them where you report the problem.");
    };
};

// ---- Chain edits by menu ------------------------------------------------------
// The + at the end of each row adds to its chain; ⋯ acts on the device being
// edited (docs/dev/device-chains.md, section 9: release 1.0 is driven by menus).
// What each offers is data, an Array of (label:, enabled:, action:, and for
// the + menu section:, group:, why:), so it can be read and run without a
// menu on screen; ~effectsShowMenu puts it up.
//
// What the + of a chain offers: every built-in effect (the ones in no chain
// to begin with in their groups' submenus), then this Mac's plugins by vendor
// (one megalooper cannot host greyed, with the reason), then the scan.
~effectsAddItems = { |track|
    var plugins = MegaSAPlugins.offered(~saPlugins ? []);
    var twice = { |e| plugins.count { |x| MegaSAPlugins.sameProduct(x, e) } > 1 };
    // The default chains' types as they always were; the others by group
    // ("Utility", "Texture"), each a submenu.
    MegaSAFx.typeKeys.collect { |type|
        (label: MegaSAFx.title(type), section: \builtin, enabled: true, group: MegaSAFx.type(type)[\group],
            action: { ~megaSA !? { |m| m.insertDevice(track, nil, type) } })
    } ++ plugins.collect { |e|
        (label: e[\name] ++ if(twice.(e)) { " (" ++ e[\format].toUpper ++ ")" } { "" }, section: \plugin,
            group: if(e[\vendor].isEmpty) { "Other" } { e[\vendor] }, enabled: e[\why].isNil, why: e[\why],
            action: { ~megaSA !? { |m| m.insertPlugin(track, nil, e[\key]) } })
    } ++ [
        (label: if((~saPlugins ? []).isEmpty) { "Scan for plugins…" } { "Scan for plugins again…" }, section: \scan,
            enabled: MegaSAPlugins.available, why: if(MegaSAPlugins.available.not) { "VSTPlugin is not installed" },
            action: { ~effectsScan.() })
    ]
};
// What ⋯ offers for a tile's device: moves, Remove, and Random and Reset or, for a
// plugin, its own window; then, device or none, Copy diagnostics.
~effectsDeviceItems = { |key|
    var m = ~megaSA, d = ~effectsDeviceOf.(key), chain = d !? { m.chainOf(d) }, at;
    var pane = [(label: "Copy diagnostics", section: \pane, enabled: true, action: { ~effectsCopyDiagnostics.() })];
    if(chain.isNil) { pane } {
        at = chain.devices.indexOf(d);
        [
            (label: "Move left", section: \device, enabled: at > 0, action: { m.moveDevice(d.id, chain.track, at - 1) }),
            (label: "Move right", section: \device, enabled: at < (chain.devices.size - 1),
                action: { m.moveDevice(d.id, chain.track, at + 1) })
        ] ++ ~effectsTracks.().reject { |t| t == chain.track }.collect { |other|
            var there = m.chainFor(other);
            (label: "Move to the " ++ MegaSASound.trackLabel(other) ++ " chain", section: \device, enabled: there.notNil and: { there.built },
                action: { m.moveDevice(d.id, other, there.devices.size) })
        } ++ [
            (label: "Remove", section: \device, enabled: true, action: { m.removeDevice(d.id) })
        ] ++ if(d.isPlugin) {
            [(label: "Open its window", section: \device, enabled: d.plugin.notNil, action: { d.plugin !? { |p| p.editor } })]
        } {
            [(label: "Random", section: \device, enabled: true, action: { m.randomizeFx(d.id) }),
                (label: "Reset", section: \device, enabled: true, action: { m.resetFx(d.id) })]
        } ++ pane
    }
};
// The items as a menu: a line between sections, a submenu per group, a
// greyed item with its reason after its name. nil for no items.
// ~effectsShowMenu puts it up at the pointer.
~effectsShowMenu = { |items| ~effectsMenuOf.(items) !? { |menu| menu.front } };
~effectsMenuOf = { |items|
    var parts = List.new, groups = Dictionary.new, section;
    var actionOf = { |it|
        MenuAction(it[\label] ++ (it[\why] !? { |w| "  (" ++ w ++ ")" } ? ""), { it[\action].value }).enabled_(it[\enabled] != false)
    };
    items.do { |it|
        if(section.notNil and: { it[\section] != section } and: { parts.notEmpty }) { parts.add(MenuAction.separator) };
        section = it[\section];
        if(it[\group].isNil) { parts.add(actionOf.(it)) } {
            if(groups[it[\group]].isNil) {
                groups[it[\group]] = Menu().title_(it[\group]);
                parts.add(groups[it[\group]]);
            };
            groups[it[\group]].addAction(actionOf.(it));
        };
    };
    if(parts.notEmpty) { Menu(*parts) }
};
// The scan, from the + menu: said in the sounds bar, as its result is.
~effectsScan = {
    ~presetSetStatus.(\saFx, "Scanning for plugins, a moment for each…");
    ~saScanPlugins.({ |ok, why, count|
        {
            ~presetSetStatus.(\saFx, if(ok) { count.asString ++ " plugins found: each + lists those megalooper can host." } {
                "No scan: " ++ (why ? "see the post window") ++ "." }, ok.not);
        }.defer
    });
};
~effectsPlusTile = { |track|
    var tile = LooperTile().states_([["+", ~gt[\ink], ~gt[\panel]]]).border_(~gt[\line]).cycles_(false)
        .font_(~guiSans.(20, true)).fixedSize_(Size(44, 58))
        .toolTip_("Add an effect or a plugin at the end of the " ++ MegaSASound.trackLabel(track) ++ " chain.\n"
            "⋯, above, moves or removes the one being edited. Cmd+Z undoes.")
        .action_({ ~effectsShowMenu.(~effectsAddItems.(track)) });
    ~effectsPlusTiles = (~effectsPlusTiles ?? { IdentityDictionary.new }).put(track, tile);
    tile
};

// ---- Dragging a tile ---------------------------------------------------------------
// A tile moves by dragging it: along its chain, or onto the other one. The
// drag is megalooper's own (docs/dev/device-chains.md, section 9). Qt's has
// no hook for a drag that ends or leaves, so an insert mark could never be
// cleared. Here the pressed tile keeps the pointer (Qt sends a pressed view
// every move and the release, wherever the pointer is), places are compared
// on screen (absoluteBounds), and the drop is the menu's move
// (MegaSA.moveDevice), so it cross-fades and undoes as that does. A press
// that travels less than ~effectsDragSlop px is a click, as before. Esc
// cancels; so does a new press, and a rebuild of the rows.
~effectsDragSlop = 8;
// The drag in hand: (tile:, id:, x:, y: where it was pressed, moving:,
// cancelled:, rows: the tiles' places when it began to move, to: where a
// drop would go now, marked: the mark shown), or nil.
~effectsDrag = nil;

// Where a drop at the screen point `pt` goes: (track:, gap:), gap 0 before a
// row's first tile and n after its last. nil over no row. `rows` are (track:,
// area: the row as it shows, tiles: each tile's Rect in order), on screen.
// A row reaches 14 px past its top and bottom, so the pointer need not stay
// on the tiles; between two rows the nearer one has it.
~effectsDropAt = { |pt, rows|
    var near = rows.select { |r| (pt.y >= (r[\area].top - 14)) and: { pt.y <= (r[\area].bottom + 14) } };
    var row = near.sort { |a, b| (pt.y - a[\area].center.y).abs <= (pt.y - b[\area].center.y).abs }.first;
    row !? { (track: row[\track], gap: row[\tiles].count { |t| t.center.x < pt.x }) }
};
// The place a device ends at (MegaSA.moveDevice's index) when it is dropped
// into `gap` of `toTrack`, from place `from` of `fromTrack`. nil when that
// is where it is: the gaps on its own two sides.
~effectsDropIndex = { |fromTrack, from, toTrack, gap|
    if(fromTrack != toTrack) { gap } {
        if((gap == from) or: { gap == (from + 1) }) { nil } { if(gap > from) { gap - 1 } { gap } }
    }
};
// The rows as they are on screen now.
~effectsRowGeometry = {
    ~effectsTracks.().collect { |track|
        (track: track, area: ~effectsRowHolders[track].absoluteBounds,
            tiles: ((~effectsRowTiles ? ())[track] ? []).collect { |t| t.absoluteBounds })
    }
};
// The move a drop would make now: (track:, gap:, index:), or nil for none.
~effectsDropTarget = { |d|
    var to = d[\to], m = ~megaSA, dev = m !? { m.device(d[\id]) }, chain = dev !? { m.chainOf(dev) }, index;
    if(to.isNil or: { chain.isNil }) { nil } {
        index = ~effectsDropIndex.(chain.track, chain.devices.indexOf(dev), to[\track], to[\gap]);
        index !? { (track: to[\track], gap: to[\gap], index: index) }
    }
};
// The insert mark: the gap a drop would go into, in the effects' colour.
~effectsDragMark = { |to|
    (~effectsGaps ? ()).keysValuesDo { |track, gaps|
        gaps.do { |gap, i|
            if(gap.isClosed.not) {
                gap.background_(if(to.notNil and: { to[\track] == track } and: { to[\gap] == i }) { ~gt[\fx] } { ~gt[\bg] });
            };
        };
    };
};
~effectsDragEnd = {
    ~effectsDrag !? { |d| d[\tile] !? { |t| if(t.isClosed.not) { t.hatch_(false) } } };
    ~effectsDrag = nil;
    ~effectsDragMark.(nil);
};
// Esc while a tile is dragged: the drag is off, and the release does nothing.
// Answers whether there was one to cancel.
~effectsDragCancel = {
    var d = ~effectsDrag;
    if(d.notNil and: { d[\moving] == true } and: { d[\cancelled] != true }) {
        d[\cancelled] = true;
        d[\tile] !? { |t| if(t.isClosed.not) { t.hatch_(false) } };
        ~effectsDragMark.(nil);
        ~presetSetStatus.(\saFx, "Not moved.");
        true
    } { false }
};
// A tile that can be dragged. Its own click is untouched: these run first
// (LooperTile), and take the release only when the tile was dragged.
~effectsDraggable = { |tile, id|
    tile.mouseDownAction_({ |v, x, y, mods, button|
        // Where the press was: an effect's tile switches only from its square.
        ~effectsPress = (tile: v, x: x, y: y);
        ~effectsDragEnd.();
        if(button == 0) { ~effectsDrag = (tile: v, id: id, x: x, y: y, moving: false) };
        nil
    });
    tile.mouseMoveAction_({ |v, x, y|
        var d = ~effectsDrag;
        if(d.notNil and: { d[\tile] === v } and: { d[\cancelled] != true }) {
            if(d[\moving].not and: { ((x - d[\x]).abs max: (y - d[\y]).abs) > ~effectsDragSlop }) {
                d[\moving] = true;
                // Where the tiles are, read once: nothing moves them while
                // one is dragged, and a mouse move comes many times a second.
                d[\rows] = ~effectsRowGeometry.();
                v.hatch_(true);
                ~presetSetStatus.(\saFx, "Moving " ++ ((~megaSA !? { |m| m.device(id) } !? { |dev| dev.name }) ? id)
                    ++ ": drop it at the mark, on any chain. Esc cancels.");
            };
            if(d[\moving]) {
                d[\to] = ~effectsDropAt.(v.mapToGlobal(Point(x, y)), d[\rows]);
                // The mark is painted when it moves, not at every mouse move.
                if(~effectsDropTarget.(d) != d[\marked]) {
                    d[\marked] = ~effectsDropTarget.(d);
                    ~effectsDragMark.(d[\marked]);
                };
            };
        };
        nil
    });
    tile.mouseUpAction_({ |v, x, y|
        var d = ~effectsDrag, mine = d.notNil and: { d[\tile] === v }, dragged = mine and: { d[\moving] == true }, target;
        if(dragged and: { d[\cancelled] != true }) {
            d[\to] = ~effectsDropAt.(v.mapToGlobal(Point(x, y)), d[\rows] ?? { ~effectsRowGeometry.() });
            target = ~effectsDropTarget.(d);
            if(target.isNil) { ~presetSetStatus.(\saFx, "Not moved.") } {
                ~presetSetStatus.(\saFx, "");
                ~megaSA.moveDevice(d[\id], target[\track], target[\index]);
            };
        };
        if(mine) { ~effectsDragEnd.() };
        // A drag is no click: the tile neither selects nor switches.
        if(dragged) { true } { nil }
    });
    tile
};

// Both rows from the chains: a tile per device in its chain's order, the
// first plugin's the \bias tile, arrows between. With no plugin in the
// chains there is no plugin tile: a removed plugin's goes as any effect's
// does, and + adds one. (Before the chains the amp was a fixture, and its
// tile stayed, reading "none".) Each row
// scrolls sideways, so a long chain never widens the window. The further
// devices' own \param repaints their knobs (a default device's settings come
// as MegaSA's \fxParam).
~effectsBuildRows = {
    var m = ~megaSA;
    var arrow = { ~guiText.("›", 18, ~gt[\mute]).align_(\center).fixedWidth_(14) };
    var tilesOf, row, first;
    ~effectsDeviceControllers.do(_.remove);
    ~effectsDeviceControllers = [];
    ~effectsTiles = IdentityDictionary.new;
    ~effectsPluginTiles = IdentityDictionary.new;
    ~effectsPluginPaints = IdentityDictionary.new;
    ~effectsBiasTileStatus = nil;
    // A drag in hand ends with the tiles it was among.
    ~effectsDragEnd.();
    ~effectsRowTiles = IdentityDictionary.new;
    ~effectsGaps = IdentityDictionary.new;
    // The first plugin (the amp) has the \bias tile and its page; a further
    // one a tile of its own.
    first = m.devices.detect(_.isPlugin);
    tilesOf = { |chain| chain.devices.collect { |d|
        ~effectsDraggable.(
            case { d === first } { ~effectsBiasTile.() } { d.isPlugin } { ~effectsPluginTile.(d) } { ~effectsTile.(d.id) },
            d.id) } };
    ~effectsTracks.().do { |track|
        var chain = m.chainFor(track), tiles = tilesOf.(chain), gaps;
        // A gap before each tile and one after the last, where a dragged
        // tile can go: a sliver first, the arrows between, a space last.
        gaps = (0..tiles.size).collect { |i|
            case { i == 0 } { View().fixedWidth_(4) } { i == tiles.size } { View().fixedWidth_(10) } { arrow.() } };
        ~effectsRowTiles[track] = tiles;
        ~effectsGaps[track] = gaps;
        // (Its own background: a scroll view's canvas else takes Qt's, whatever the theme.)
        row = View().background_(~gt[\bg]).layout_(HLayout(*(
            tiles.collect { |t, i| [gaps[i], t] }.flatten(1) ++ [gaps.last, ~effectsPlusTile.(track), nil]
        )).spacing_(6).margins_(0));
        ~effectsRowHolders[track] !? { |h| if(h.isClosed.not) { h.canvas_(row) } };
    };
    m.devices.select { |d| d.id != d.type }.do { |d|
        ~effectsDeviceControllers = ~effectsDeviceControllers.add(SimpleController(d)
            .put(\param, { |obj, what, name, val| { ~effectsRefreshParam.(name, val, d.id); ~effectsKeepSoon.() }.defer }));
    };
    ~effectsTiles.keysDo { |k| ~effectsRefreshTile.(k) };
};

// A chain edit (MegaSA's \chain): once per burst, at the next AppClock tick,
// the MIDI list re-greyed, both rows rebuilt (a move names only the chain it
// went to), the editor rebuilt if what it showed is gone or was renamed (in
// ~effectsRenamed, every device renamed in the burst), and the plugin's line
// said again (an edit may have taken it out or brought it back).
~effectsChainChanged = {
    ~effectsChainPending = false;
    ~megaSA !? {
        // The effects' controls first, so a new device has its own before
        // its switch is tagged.
        ~midiTargetsRefresh !? { |f| f.(\effects) };
        ~effectsBuildRows.();
        if(~effectsSelectable.(~effectsSelected).not or: { (~effectsRenamed ? []).includes(~effectsSelected) }) {
            ~effectsSelect.(if(~effectsSelectable.(~effectsSelected)) { ~effectsSelected } { ~effectsFirstKey.() });
        };
        ~effectsRenamed = nil;
        ~effectsBiasStatus !? { |t| if(t.isClosed.not) { t.string_(~effectsBiasLine.()) } };
        ~effectsRefreshAll.();
        ~effectsPaintKeep.();
        ~guiRefreshTabs !? { |f| f.value };
        ~performPaintFx !? { |f| f.value };
    };
};

// ---- Pane -----------------------------------------------------------------
// The FX view, under the effects' colour bar: the
// sound's preset and Keep, the guitar's chain and the loop's, and the editor
// of the tile selected.
~buildEffectsPane = {
    var pane = View().background_(~gt[\bg]);
    var m = ~megaSA;
    var preset, rowOf;
    ~presetStopTimers.(\saFx);
    ~guiTeardowns[\effects].value;
    if(m.isNil) {
        pane.layout_(VLayout(
            ~guiBand.(\fx),
            HLayout(View().fixedWidth_(14), ~guiHint.("The effects are Megalooper SA's: start the megalooper "
                "with the SA profile to play them.")).margins_(8),
            nil).margins_(0).spacing_(0));
    } {
        // The selection may have come from a rig, or a chain, that had it.
        if(~effectsSelected.isNil or: { ~effectsSelectable.(~effectsSelected).not }) {
            ~effectsSelected = ~effectsFirstKey.() };
        // A row: its caption, then its tiles in a sideways scroll, as tall as
        // a tile and the scroller.
        rowOf = { |track, caption|
            ~effectsRowHolders[track] = ScrollView().hasBorder_(false).hasVerticalScroller_(false)
                .background_(~gt[\bg]).fixedHeight_(58 + 14);
            HLayout(~guiCaption.(caption).fixedWidth_(84), ~effectsRowHolders[track]).spacing_(6).margins_(0)
        };
        preset = ~guiPresetParts.(\saFx, (
            menu: "Saved sounds: every chain, every setting and each plugin's sound.\n"
                "Choosing one recalls it at once. One with other effects, or\n"
                "another order, changes the chains. The instrument mutes for a\n"
                "moment while a plugin on its chain loads its part.",
            name: "File name for Save. Anything but letters and digits becomes '-', "
                "so \"Warm Wah\" saves as warm-wah.json, in your megalooper folder.",
            save: "Write every chain and every setting to sa/sounds/<name>.json in your megalooper\n"
                "folder, and each plugin's sound beside it if the loop is stopped (else the\n"
                "one last kept). 'Overwrite' asks for a second click."
        ));
        ~effectsKeepButton = LooperTile().states_([["Start with this", ~gt[\ink], ~gt[\panel]]]).border_(~gt[\line])
            .cycles_(false).font_(~guiSans.(14)).fixedSize_(Size(140, 30))
            .toolTip_("Keep every chain, every setting and each plugin's sound as they are now:\n"
                "the next boot starts with them. A dot says there is something not kept\n"
                "yet. While the loop plays, a plugin's own sound stays as last kept.")
            .action_({
                ~saKeepSound.({ |ok, why, withStates, bare|
                    var plug = ~megaSA !? { |mm| mm.guitarPlugin };
                    {
                        case
                        { ok.not } { ~presetSetStatus.(\saFx, "Not kept: " ++ (why ? "see the post window") ++ ".", true) }
                        { bare == true } {
                            ~presetSetStatus.(\saFx, "Kept without a plugin on the instrument: the next boot hosts none. See the post window for the way back.", true);
                        }
                        { plug.isNil } { ~presetSetStatus.(\saFx, "Kept: the next boot starts with these chains.") }
                        { withStates == false } {
                            ~presetSetStatus.(\saFx,
                                "Kept the chains. " ++ ~effectsPluginWord.() ++ "'s own sound stays as last kept: stop the loop to keep it too.");
                        }
                        { plug.state != \open } {
                            ~presetSetStatus.(\saFx, "Kept the chains; " ++ ~effectsPluginWord.() ++ " is " ++ plug.state
                                ++ ", so its sound stays as kept before.", true);
                        }
                        { ~presetSetStatus.(\saFx, "Kept: the next boot starts with this sound.") };
                        ~effectsPaintKeep.();
                    }.defer
                });
            });
        // Shown only while a boot's offer stands (~saRecovery).
        ~effectsRecoverButton = LooperTile().states_([["Recover", ~gt[\ink], ~gt[\panel]]]).border_(~gt[\line])
            .cycles_(false).font_(~guiSans.(14)).fixedSize_(Size(84, 30))
            .toolTip_("The chains were edited and not kept when megalooper last stopped.\n"
                "This brings those chains back. An edit or Start with this drops them.")
            .action_({
                ~saRecallRecovery.({ |ok, notes|
                    {
                        ~presetSetStatus.(\saFx, if(ok == true) { "Recovered the chains of the last run: Start with this keeps them." }
                            { "The chains of the last run could not be recovered: see the post window." }, ok != true);
                        ~effectsPaintKeep.();
                    }.defer
                });
            });
        pane.layout_(VLayout(
            ~guiBand.(\fx),
            View().layout_(VLayout(
                HLayout(
                    ~guiTitle.("Effects", 26),
                    [~guiHelp.(~guiLabel.("Click a block to edit it, its square to switch it on or off. Drag it to move it. "
                        "Signal flows left to right.", 14)), stretch: 1],
                    preset[\menu].fixedWidth_(340),
                    ~effectsRecoverButton,
                    ~effectsMoreButton = LooperTile().states_([["⋯", ~gt[\ink], ~gt[\panel]]]).border_(~gt[\line])
                        .cycles_(false).font_(~guiSans.(18, true)).fixedSize_(Size(44, 30))
                        .toolTip_("The effect being edited: move it, remove it, reset it,\nor show a plugin's window. Cmd+Z undoes, Shift+Cmd+Z redoes.")
                        .action_({ ~effectsShowMenu.(~effectsDeviceItems.(~effectsSelected)) }),
                    ~effectsKeepButton
                ).spacing_(16).margins_(0),
                preset[\edit],
                // ---- the chains ------------------------------------------------
                VLayout(*~effectsTracks.().collect { |t| rowOf.(t, ~effectsRowCaptions[t]) }).spacing_(10).margins_(0),
                ~effectsStatusText = ~guiMonoText.("", 12, ~gt[\mute]),
                // ---- the editor --------------------------------------------------
                ~effectsEditorHolder = View().layout_(VLayout().margins_([0, 4, 0, 0])),
                nil
            ).margins_([22, 14, 22, 14]).spacing_(10))
        ).margins_(0).spacing_(0));
        ~effectsBuildRows.();
        // The status line, read once a second for as long as this pane's
        // text is there (a rebuilt pane starts its own).
        ~effectsStatusPainted = nil;
        ~effectsStatusGen = (~effectsStatusGen ? 0) + 1;
        {
            var gen = ~effectsStatusGen, text = ~effectsStatusText;
            AppClock.sched(0, {
                if((gen != ~effectsStatusGen) or: { text.isClosed }) { nil } { ~effectsPaintStatus.(); 1 }
            });
        }.value;
        ~effectsEditorHolder.layout.add(~effectsEditor.(~effectsSelected));
        // The footswitches, recalls and resets reach here through the model.
        ~effectsControllers = [
            SimpleController(m)
                .put(\kept, { { ~effectsPaintKeep.() }.defer })
                // An edit MegaSA refused (no memory, a plugin it cannot host)
                // is said where the eye is; it stays until the next message.
                .put(\refused, { |obj, what, kind, why| { ~presetSetStatus.(\saFx, "Not done: " ++ why ++ ".", true) }.defer })
                .put(\fx, { |obj, what, key, flag|
                    { ~effectsRefreshTile.(key); ~guiRefreshTabs !? { |f| f.value };
                        ~performPaintFx !? { |f| f.value } }.defer
                })
                .put(\fxParam, { |obj, what, name, val|
                    { ~effectsRefreshParam.(name, val); ~effectsKeepSoon.() }.defer
                })
                // A chain edit: the rows again, once per burst, at the next
                // AppClock tick (defer would run at once on AppClock or the
                // interpreter's thread, where the IDE's edits come from).
                .put(\chain, { |obj, what, track, op, id, index|
                    if(op == \rename) { ~effectsRenamed = (~effectsRenamed ?? { IdentitySet.new }).add(id) };
                    if(~effectsChainPending != true) {
                        ~effectsChainPending = true;
                        AppClock.sched(0, { if(~effectsChainPending == true) { ~effectsChainChanged.() }; nil });
                    };
                })
                // A sound's file is written, and a recalled one's Bias FX
                // part is in, after the bar has said "Saved" or "Loaded":
                // these say what did not go as that promised.
                .put(\soundSaved, { |obj, what, slug, ok, why, withStates|
                    {
                        // Selected first, read again second: the list would
                        // else call a sound it does not hold "gone".
                        if(ok == true) { ~presetFamilies[\saFx][\loaded] = slug };
                        ~presetRefreshList.(\saFx);
                        case
                        { ok != true } { ~presetSetStatus.(\saFx, "Not saved: " ++ slug ++ " (" ++ (why ? "see the post window") ++ ").", true) }
                        { (withStates == false) and: { m.guitarPlugin.notNil } } {
                            ~presetSetStatus.(\saFx, "Saved " ++ slug ++ ". Its " ++ ~effectsPluginWord.() ++ " sound is the one last kept: the loop was playing.");
                        }
                        { ~presetSetStatus.(\saFx, "Saved " ++ slug) };
                    }.defer
                })
                .put(\soundLoaded, { |obj, what, slug, ok, notes|
                    // Queued, not run at once: a recall with no plugin state to
                    // load answers before the bar has said its own "Loaded".
                    AppClock.sched(0, {
                        case
                        { ok != true } {
                            ~presetSetStatus.(\saFx, "Loaded " ++ slug ++ ", but not its " ++ ~effectsPluginWord.() ++ " sound"
                                ++ (m.guitarPlugin !? { |p| " (" ++ ~effectsPluginWord.() ++ " is " ++ p.state ++ ")" } ? "") ++ ".", true);
                        }
                        { (notes ? []).notEmpty } {
                            ~presetSetStatus.(\saFx, "Loaded " ++ slug ++ ", but: " ++ notes.first ++ ".", true);
                        };
                        ~effectsPaintKeep.();
                        nil
                    })
                })
        ] ++ (m.guitarPlugin !? { |plug|
            var paint = {
                {
                    ~effectsRefreshTile.(\bias);
                    ~effectsBiasStatus !? { |t| if(t.isClosed.not) { t.string_(~effectsBiasLine.()) } };
                }.defer
            };
            // \latency: a report may hold it off, or let it be heard again.
            [SimpleController(plug).put(\state, paint).put(\bank, paint).put(\latency, paint)]
        } ? []);
        ~effectsRefreshAll.();
        ~effectsPaintKeep.();
        if(~saRecovery.notNil) {
            ~presetSetStatus.(\saFx, "The chains were edited and not kept when megalooper last stopped: Recover brings them back.");
        };
    };
    ~effectsPane = pane;
    ~guiSwapPane.(\effects, pane);
    m !? { ~presetRefreshList.(\saFx) };
    pane
};
)
