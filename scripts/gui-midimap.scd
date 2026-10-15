// megalooper — the Rig pane's MIDI section: the inputs megalooper listens to,
// the map a rig uses, its bindings, and learning one (docs/dev/midi-map.md 7.3).
// Every mapping can be made from this list, a control with no widget among
// them. Clicking a control on screen to map it, as in Live, is MIDI Map mode
// (gui-mapmode.scd), switched on here.
//
// Loaded by boot.scd; defines only, runs nothing. ~buildRigPane calls
// ~buildMidiMapSection, which answers the section's view. Everything here
// reads the router's state (setup-midimap.scd) and calls its functions; the
// router tells it to repaint through ~midiChanged, deferred, so nothing here
// runs on the MIDI thread.
(
~midiGui = IdentityDictionary.new;      // the section's widgets
~midiGuiRows = [];                      // the bindings the list shows, in its order
~midiGuiArm = nil;                      // \revert or \reset while a two-click button waits

// Arm a two-click button. It disarms itself after 4 s, as the preset bar's
// Delete does: a revert that quietly doesn't happen fails safe, the map is
// still there (gui-presets.scd).
~midiGuiArmFor = { |which|
    ~midiGuiArm = which;
    AppClock.sched(4, { if(~midiGuiArm == which) { ~midiGuiArm = nil; ~midiChanged.(\map) }; nil });
};

// A value as its control's widget shows it.
~midiGuiFormat = { |target, v|
    case
    { v.isNil } { "" }
    { target.notNil and: { target[\format].notNil } } { try { target[\format].value(v).asString } { v.asString } }
    { v.isNumber } { v.round(0.001).asString }
    { v.asString }
};

// What kind of switch or mode a binding has, in words, and what it says of
// its own as a knob (what it doesn't say is the Knobs row's).
~midiGuiKindText = { |b|
    var sw = (oneMessage: "one message a press", pressRelease: "press and release", knob: "knob")[b[\switch] ? \x];
    var mode = (hold: "hold", follow: "follows")[b[\mode] ? \x];
    var hyst = case { b[\hysteresis].isNil } { nil } { b[\hysteresis] == 0 } { "no hysteresis" }
        { "hysteresis " ++ b[\hysteresis] };
    var take = (none: "jumps", pickup: "picks up", scale: "scales")[b[\takeover] ? \x];
    var range = if(b[\inLo].notNil or: { b[\inHi].notNil }) {
        (b[\inLo] ? 0).asString ++ "–" ++ (b[\inHi] ? LooperMidiMap.top(b[\msg])) };
    [sw, mode, hyst, take, range].reject(_.isNil).join(", ")
};

// The knobs' defaults (the Knobs row): for every knob mapping that names none.
// Kept in settings.json, and the router's at once.
~midiGuiDefault = { |key, value|
    var s = ~midiSettingsNow.();
    s[\knobs].put(key, value);
    ~midiDefaultsFrom.(s);
    ~midiSettingsSave.();
    ~midiChanged.(\defaults);
};

// A sweep's progress on the Rig tab, five times a second while it runs (the
// range's row only: the menus are left alone), and its end 20 s on if Done
// wasn't pressed, which changes nothing.
~midiGuiSweepPoll = {
    var gen = (~midiGuiSweepGen ? 0) + 1;
    ~midiGuiSweepGen = gen;
    AppClock.sched(0.2, {
        case
        { (gen != ~midiGuiSweepGen) or: { ~midiSweep.isNil } } { nil }
        { ~midiNow.() > ~midiSweep[\until] } {
            ~midiSweepEnd.(false, "Range not changed: the sweep ended itself, 20 s on without Done");
            nil
        }
        { ~midiGuiRefreshRange.(); 0.2 }
    });
};

// One row of the list: Message, Control, Min, Max, Kind, Input.
~midiGuiRow = { |b|
    var t = (~midiTargets ? ())[b[\target]];
    [
        LooperMidiMap.describe(b),
        // A control that is not there says why, where it can (SA's effects).
        if(t.isNil) { b[\target].asString ++ " (" ++ ~midiTargetWhy.(b[\target]) ++ ")" } {
            ~midiTargetWords.(t) ++ "  ·  " ++ t[\path]
                ++ (if(t[\why].notNil) { ~midiTargetWhy.(b[\target]) } !? { |w| "  (" ++ w ++ ")" } ? "") },
        ~midiGuiFormat.(t, b[\min]),
        ~midiGuiFormat.(t, b[\max]),
        ~midiGuiKindText.(b),
        b[\device] ?? { "any input" }
    ]
};

// Is the binding's control here now? A greyed row says it isn't.
~midiGuiLive = { |b|
    var t = (~midiTargets ? ())[b[\target]];
    t.notNil and: { (try { t[\available].value } { false }) != false }
};

~midiGuiSelected = {
    var tv = ~midiGui[\list];
    var item = tv !? { |v| if(v.isClosed) { nil } { v.currentItem } };
    item !? { |it| ~midiGuiRows[it.index] }
};

// The maps there are, shipped and yours, by name.
~midiGuiMapNames = {
    (~midiMapNames.(~midiShippedDir.()) ++ ~midiMapNames.(~midiUserDir.())).asSet.asArray.sort
};

// Choose another map for this rig, kept in settings.json. Not while the map
// has changes not kept: those would be lost.
~midiGuiUseMap = { |name|
    var loaded;
    if(~midiMapDirty.()) {
        ~midiLearnNote = "Keep or Revert the changes first";
    } {
        ~midiSettingsNow.()[\maps].put(~routingProfile ? \default, name);
        ~midiSettingsSave.();
        loaded = ~midiMapLoad.(name);
        ~midiMap = (loaded[\map] ?? { LooperMidiMap([], name) }).adopt(~midiMap);
        ~midiKept = ~midiMap;
        ~midiMapFrom = loaded[\from];
        ~midiMapWarning = loaded[\warning];
        ~midiMapWarningLevel = loaded[\level] ? \error;
        ~midiUndo = List.new;
        ~midiMapReport.(~midiMap, ~midiTargets ? (), ~midiMapFrom);
    };
    ~midiChanged.(\map);
};

// Keep the map as yours (8.2), and as this rig's map, so the next boot loads
// it whatever it was called. A map with no name yet (a rig that had none: a
// fresh clone's) is called "mine". A map taken from a shipped one says which,
// at which revision, so a newer shipped map can be offered later (8.3).
// `done`, if given, gets true once it is written, or false (MIDI Map mode
// leaves only on true).
~midiGuiKeep = { |done|
    var map = ~midiMap, shipped, name;
    if(map.isNil) { done.value(false) } {
        if(map.name.isNil) {
            name = "mine";
            if(~midiGuiMapNames.().includesEqual(name)) {
                name = (2..99).collect { |i| "mine-" ++ i }.detect { |n| ~midiGuiMapNames.().includesEqual(n).not } ? "mine";
            };
            map = map.renamed(name);
        };
        if(map.basedOn.isNil and: { ~midiMapFrom == \shipped }) {
            shipped = LooperMidiMap.parse(~midiReadText.(~midiMapPath.(~midiShippedDir.(), map.name)));
            map = map.renamed(map.name, map.name, if(shipped.isString) { nil } { shipped[\revision] });
        };
        ~midiMapKeep.(map, { |ok, why|
            if(ok) {
                ~midiMap = map.adopt(~midiMap);
                ~midiKept = map;
                ~midiMapFrom = \yours;
                ~midiMapWarning = nil;
                ~midiSettingsNow.()[\maps].put(~routingProfile ? \default, map.name.asString);
                ~midiSettingsSave.();
                ~midiLearnNote = "Kept as yours: the next boot starts with it";
            } {
                ~midiLearnNote = "Not kept: " ++ (why ? "the file could not be written");
            };
            ~midiChanged.(\map);
            done.value(ok);
        });
    };
};

// Back to the map as it was loaded or last kept (in memory: a map loaded from
// a file, not kept, has no file of its own to go back to).
~midiGuiRevert = {
    ~midiKept !? { |k|
        ~midiMap = k.adopt(~midiMap);
        ~midiUndo = List.new;
        ~midiLearnNote = "Back to the map as kept";
        ~midiChanged.(\map);
    };
};
~midiGuiReset = {
    var name = ~midiMap !? { |m| m.name };
    var yours = name !? { |n| ~midiMapPath.(~midiUserDir.(), n) };
    if(yours.notNil and: { File.exists(yours) }) {
        File.mkdir(~midiBackupDir.() +/+ name);
        File.copy(yours, ~midiBackupDir.() +/+ name +/+ (Date.localtime.stamp ++ ".json"));
        File.delete(yours);
    };
    name !? { ~midiGuiUseMapForce.(name) };
    ~midiLearnNote = "Back to the shipped map; yours is in the backups";
};
// Load a map by name whatever the changes (Revert and Reset discard them).
~midiGuiUseMapForce = { |name|
    var loaded = ~midiMapLoad.(name);
    ~midiMap = (loaded[\map] ?? { LooperMidiMap([], name) }).adopt(~midiMap);
    ~midiKept = ~midiMap;
    ~midiMapFrom = loaded[\from];
    ~midiMapWarning = loaded[\warning];
    ~midiMapWarningLevel = loaded[\level] ? \error;
    ~midiUndo = List.new;
    ~midiChanged.(\map);
};

// A map file from anywhere, a backup or one someone sent: its bindings become
// this map's, not kept until Keep, which keeps them under this map's name (a
// backup of tsmega, kept, is tsmega again). Undo takes them back.
~midiGuiLoadFile = { |path|
    var r = LooperMidiMap.parse(~midiReadText.(path));
    var map = ~midiMap;
    if(r.isString) {
        ~midiLearnNote = path.basename ++ " is not loaded: " ++ r;
    } {
        ~midiMapEdit.(LooperMidiMap(r[\bindings], (map !? { |m| m.name }) ?? { r[\name] !? { |n| if(n.isEmpty) { nil } { n } } },
            (map !? { |m| m.basedOn }) ? r[\basedOn], (map !? { |m| m.revision }) ? r[\revision]));
        ~midiLearnNote = path.basename ++ " is loaded: Keep it to use it from the next boot";
    };
    ~midiChanged.(\map);
};
~midiGuiLoadFrom = { Dialog.openPanel({ |path| ~midiGuiLoadFile.(path) }) };

// Listen to an input or not, by its device name, kept in settings.json. One
// not listened to is not sent back to either.
~midiGuiListen = { |device, on|
    var s = ~midiSettingsNow.();
    s[\listen].put(device, on);
    ~midiListenFrom.(s);
    ~midiBackFrom.(s);
    ~midiSettingsSave.();
    ~midiChanged.(\inputs);
};

// Send values and lights back to an input or not, by its device name, kept
// in settings.json (docs/dev/midi-map.md 5.7, ~midiBackSwitch).
~midiGuiSendBack = { |device, on|
    ~midiBackSwitch.(device, on);
    ~midiChanged.(\inputs);
};

// A controller plugged in after the boot: SuperCollider is not told, so a
// Rescan lists the inputs again and connects the new ones (docs/dev/midi-map.md
// 9); one no longer listed is gone. SuperCollider isn't told of one unplugged
// either, and a send to it goes nowhere without failing: plugged in again, it
// shows its own values until a Rescan, which sends it everything
// (~midiBackRescan).
~midiRescan = {
    var known = (~midiSources ? ()).keys;
    try {
        MIDIClient.list;
        ~midiSources = IdentityDictionary.new;
        ~midiClientSources.().do { |src|
            if(src.device.contains("IAC").not and: { known.includes(src.uid).not }) {
                // One unplugged at an earlier Rescan may still be connected
                // from before: not twice (MIDIIn.connectAll does the same).
                try { MIDIIn.disconnect(0, src) };
                MIDIIn.connect(0, src);
            };
            ~midiSources.put(src.uid, [src.device, src.name]);
        };
        ~midiListenFrom.(~midiSettingsNow.());
        ~midiBackRescan.();
    } { |err| ~midiLearnNote = "Rescan failed: " ++ err.errorString };
    ~midiChanged.(\inputs);
};

// The controls a mapping can be added to, by tab: tab -> [[label, id], ...].
~midiGuiPickable = {
    var byTab = IdentityDictionary.new;
    (~midiTargets ? ()).keysValuesDo { |id, t|
        var tab = (t[\path] ? "Other").asSymbol;
        var label = (t[\group] !? { |g| g ++ " › " } ? "") ++ t[\label];
        if(~midiGuiLive.((target: id))) {
            byTab.put(tab, (byTab[tab] ? []).add([label, id]));
        };
    };
    byTab.keysValuesDo { |tab, list| byTab.put(tab, list.sort { |a, b| a[0] < b[0] }) };
    byTab
};

~guiTeardowns = ~guiTeardowns ? ();
~guiTeardowns[\midimap] = {
    // Closing the window ends a learning (6.5).
    ~midiLearning = nil;
    ~midiGui = IdentityDictionary.new;
};

~buildMidiMapSection = {
    var view = View(), g = IdentityDictionary.new;
    // The stage look: a switch is a tile, a menu takes the theme's ground.
    var small = { LooperTile().border_(~gt[\line]).font_(~guiSans.(13)).fixedHeight_(26).pad_(8) };
    var menu = { |m| m.canFocus_(false).font_(~guiSans.(13)).background_(~gt[\panel]).stringColor_(~gt[\ink]) };
    var label = { |str| ~guiText.(str, 13, ~gt[\mute]).fixedWidth_(96) };
    var tabs, pick;
    ~midiGui = g;
    g[\view] = view;
    g[\inputs] = HLayout().margins_(0);
    g[\inputsView] = View().layout_(g[\inputs]);
    g[\backs] = HLayout().margins_(0);
    g[\backsView] = View().layout_(g[\backs]);
    g[\mapMenu] = menu.(PopUpMenu())
        .toolTip_("The MIDI map this rig uses. Yours hide the shipped ones of the same name.")
        .action_({ |m| ~midiGui[\mapNames] !? { |names| names[m.value] !? { |n| ~midiGuiUseMap.(n) } } });
    g[\keep] = small.().states_([["Keep"]])
        .toolTip_("Keep this map as yours: the next boot starts with it. Nothing is written before this.")
        .action_({ ~midiGuiKeep.() });
    g[\undo] = small.().states_([["Undo"]]).toolTip_("Take the last change back.")
        .action_({ ~midiMapUndo.() });
    g[\revert] = small.().states_([["Revert"], ["Sure?", ~gt[\onacc], ~gt[\armed]]])
        .toolTip_("Back to the map as kept: the changes since go. Click twice.")
        .action_({ |b|
            if(~midiGuiArm == \revert) { ~midiGuiArm = nil; ~midiGuiRevert.() } { ~midiGuiArmFor.(\revert) };
            ~midiChanged.(\map);
        });
    g[\reset] = small.().states_([["Reset to shipped"], ["Sure?", ~gt[\onacc], ~gt[\armed]]])
        .toolTip_("Back to the map as megalooper ships it; yours goes into the backups. Click twice.")
        .action_({ |b|
            if(~midiGuiArm == \reset) { ~midiGuiArm = nil; ~midiGuiReset.() } { ~midiGuiArmFor.(\reset) };
            ~midiChanged.(\map);
        });
    g[\loadFrom] = small.().states_([["Load from…"]])
        .toolTip_("Load a map file: from a backup, or one someone sent you.")
        .action_({ ~midiGuiLoadFrom.() });
    g[\status] = ~guiText.("", 13, ~gt[\mute]);
    g[\learnText] = ~guiText.("", 14);
    g[\cancel] = small.().states_([["Cancel"]]).action_({ ~midiLearnDisarm.("Nothing changed") });
    g[\move] = small.().states_([["Move it here"]]).action_({ ~midiLearnAnswer.(\move) });
    g[\both] = small.().states_([["Both"]]).action_({ ~midiLearnAnswer.(\both) });
    g[\list] = TreeView().canFocus_(false).minHeight_(180)
        .columns_(["Message", "Control", "Min", "Max", "Kind", "Input"]);
    g[\list].onItemChanged_({ ~midiGuiRefreshEditor.() });
    g[\learn] = small.().states_([["Learn"], ["Learning…", ~gt[\onacc], ~gt[\armed]]])
        .toolTip_("Arm this control: then move or press what is to drive it. It replaces this control's bindings.")
        .action_({ ~midiGuiSelected.() !? { |b| ~midiLearnArm.(b[\target]) }; ~midiChanged.(\learn) });
    g[\remove] = small.().states_([["×"]]).toolTip_("Remove this binding.")
        .action_({ ~midiGuiSelected.() !? { |b| ~midiBindingRemove.(b) } });
    g[\setMin] = small.().states_([["Set Min"]])
        .toolTip_("Put the control where the knob's low end should be, then press this.")
        .action_({ ~midiGuiSelected.() !? { |b| ~midiBindingSetEnd.(b, \min) } });
    g[\setMax] = small.().states_([["Set Max"]])
        .toolTip_("Put the control where the knob's high end should be, then press this.")
        .action_({ ~midiGuiSelected.() !? { |b| ~midiBindingSetEnd.(b, \max) } });
    g[\swap] = small.().states_([["Swap"]]).toolTip_("Turn the knob round: Min and Max change places.")
        .action_({ ~midiGuiSelected.() !? { |b| ~midiBindingSwap.(b) } });
    g[\chan] = menu.(PopUpMenu()).items_(["any channel"] ++ (1..16).collect { |c| "channel " ++ c })
        .action_({ |m| ~midiGuiSelected.() !? { |b|
            ~midiBindingChange.(b, (chan: if(m.value == 0) { \remove } { m.value - 1 })) } });
    g[\device] = menu.(PopUpMenu()).fixedWidth_(170)
        .action_({ |m| ~midiGuiSelected.() !? { |b|
            ~midiBindingChange.(b, if(m.value == 0) { (device: \remove, port: \remove) }
                { (device: g[\deviceNames][m.value - 1], port: \remove) }) } });
    g[\switchMenu] = menu.(PopUpMenu())
        .items_(["knob or pedal", "one message a press", "press and release"])
        .toolTip_("What kind of switch sends this CC: the TSMega's send one message a press.")
        .action_({ |m| ~midiGuiSelected.() !? { |b|
            ~midiBindingChange.(b, (switch: [\knob, \oneMessage, \pressRelease][m.value])) } });
    g[\modeMenu] = menu.(PopUpMenu()).items_(["press flips it", "on while held", "follows the switch"])
        .action_({ |m| ~midiGuiSelected.() !? { |b|
            ~midiBindingChange.(b, (mode: [\remove, \hold, \follow][m.value])) } });
    // A knob's own takeover and hysteresis, or the Knobs row's.
    g[\takeMenu] = menu.(PopUpMenu())
        .items_(["takeover: the default", "jumps to the knob", "picks up", "scales"])
        .toolTip_("What the knob does when its control is somewhere else (moved by the mouse, a preset):\n"
            "the control jumps to the knob; or waits until the knob gets to it (picks up);\n"
            "or meets the knob at the ends, moving by the share of the way left (scales).")
        .action_({ |m| ~midiGuiSelected.() !? { |b|
            ~midiBindingChange.(b, (takeover: [\remove, \none, \pickup, \scale][m.value])) } });
    g[\hystMenu] = menu.(PopUpMenu())
        .items_(["hysteresis: the default", "no hysteresis", "hysteresis 1", "hysteresis 2", "hysteresis 3"])
        .toolTip_("Steps a knob must turn back before it counts: 1 stops a pedal's one-step flicker.")
        .action_({ |m| ~midiGuiSelected.() !? { |b|
            ~midiBindingChange.(b, (hysteresis: [\remove, 0, 1, 2, 3][m.value])) } });
    // Its input range: what the knob or pedal sends at its two ends.
    g[\rangeText] = StaticText().fixedWidth_(190);
    g[\sweep] = small.().states_([["Sweep"], ["Done", ~gt[\onacc], ~gt[\armed]]])
        .toolTip_("Its input range: press this, move the knob or pedal from one end to the other, press Done.\n"
            "A pedal that stops short of 127 then still takes its control to the end.")
        .action_({
            if(~midiSweep.notNil) { ~midiSweepEnd.() } {
                ~midiGuiSelected.() !? { |b| ~midiSweepStart.(b); ~midiGuiSweepPoll.() } };
            ~midiChanged.(\sweep);
        });
    g[\fullRange] = small.().states_([["Full"]]).toolTip_("Its input range back to the whole travel.")
        .action_({ ~midiGuiSelected.() !? { |b| ~midiBindingChange.(b, (inLo: \remove, inHi: \remove)) } });
    // The knobs' defaults, for every knob mapping that names none.
    g[\defTake] = menu.(PopUpMenu()).items_(["jump to the knob", "pick up", "scale"])
        .toolTip_("What a knob does when its control is somewhere else, unless its mapping says.")
        .action_({ |m| ~midiGuiDefault.(\takeover, [\none, \pickup, \scale][m.value]) });
    g[\defHyst] = menu.(PopUpMenu()).items_(["no hysteresis", "hysteresis 1", "hysteresis 2", "hysteresis 3"])
        .toolTip_("Steps a knob must turn back before it counts, unless its mapping says.")
        .action_({ |m| ~midiGuiDefault.(\hysteresis, m.value) });
    // Add a mapping: a tab, then a control on it, then Learn.
    g[\pickTab] = menu.(PopUpMenu()).fixedWidth_(110)
        .action_({ ~midiGuiRefreshPicker.() });
    g[\pickControl] = menu.(PopUpMenu());
    g[\pickLearn] = small.().states_([["Learn"]])
        .toolTip_("Arm the control picked: then move or press what is to drive it. Its other bindings stay.")
        .action_({
            g[\pickIds] !? { |ids| ids[g[\pickControl].value ? 0] !? { |id| ~midiLearnArm.(id, true) } };
        });

    // MIDI Map mode (gui-mapmode.scd) is the top bar's MIDI MAP button, on
    // every view (docs/dev/stage-ui.md, replacing decision 2 of
    // docs/dev/midi-map.md): this section keeps the list, the editor and Add a
    // mapping.

    view.layout_(VLayout(
        ~guiText.("MIDI map", 18, nil, true),
        ~guiHelp.(~guiText.("MIDI MAP (top right) or Cmd+M: click a control anywhere, then move or press what is to "
            "drive it.", 13, ~gt[\mute])),
        HLayout(label.("Inputs"), [g[\inputsView], stretch: 1],
            small.().states_([["Rescan"]]).cycles_(false)
                .toolTip_("A controller plugged in since the boot is heard after this.")
                .action_({ ~midiRescan.() })).spacing_(8),
        HLayout(label.("Send back").toolTip_("Values and lights, to a controller that takes them."),
            [g[\backsView], stretch: 1]).spacing_(8),
        HLayout(label.("Map"), [g[\mapMenu], stretch: 1], g[\keep], g[\undo]).spacing_(6),
        HLayout(View().fixedWidth_(96), g[\revert], g[\reset], g[\loadFrom], nil).spacing_(6),
        HLayout(label.("Knobs").toolTip_("Unless a mapping says otherwise."), g[\defTake], g[\defHyst], nil)
            .spacing_(6),
        HLayout(View().fixedWidth_(96), [g[\status], stretch: 1]),
        HLayout(View().fixedWidth_(96), [g[\learnText], stretch: 1], g[\move], g[\both], g[\cancel]).spacing_(6),
        g[\list],
        HLayout(g[\learn], g[\remove], g[\setMin], g[\setMax], g[\swap], nil).spacing_(6),
        HLayout(g[\chan], g[\device], nil).spacing_(6),
        HLayout(g[\switchMenu], g[\modeMenu], nil).spacing_(6),
        HLayout(g[\takeMenu], g[\hystMenu], nil).spacing_(6),
        HLayout(label.("Input range"), g[\rangeText], g[\sweep], g[\fullRange], nil).spacing_(6),
        HLayout(label.("Add a mapping"), g[\pickTab], [g[\pickControl], stretch: 1], g[\pickLearn]).spacing_(6),
        ~guiText.("Learn arms a control: then move a knob, or press a switch (CC switches twice). "
            "Nothing is written before Keep.", 13, ~gt[\mute])
    ).margins_(0).spacing_(10));
    ~midiGuiRefresh.();
    view
};

~midiGuiRefreshPicker = {
    var g = ~midiGui, pick, tabs, ids, keepTab, keepId;
    if(g[\pickTab].notNil and: { g[\pickTab].isClosed.not }) {
        pick = ~midiGuiPickable.();
        tabs = pick.keys.asArray.sort;
        // What was picked stays picked through a repaint.
        keepTab = g[\pickTabs] !? { |t| t[g[\pickTab].value ? 0] };
        keepId = g[\pickIds] !? { |i| i[g[\pickControl].value ? 0] };
        if(g[\pickTabs] != tabs) {
            g[\pickTabs] = tabs;
            g[\pickTab].items_(tabs.collect(_.asString));
            g[\pickTab].value = (keepTab !? { |k| tabs.indexOf(k) }) ? 0;
        };
        ids = pick[tabs[g[\pickTab].value ? 0] ? \none] ? [];
        // Stale: the controls were made again (a kit loaded), names and all.
        if((g[\pickIds] != ids.collect { |p| p[1] }) or: { g[\pickStale] == true }) {
            g[\pickStale] = false;
            g[\pickIds] = ids.collect { |p| p[1] };
            g[\pickControl].items_(ids.collect { |p| p[0] });
            g[\pickControl].value = (keepId !? { |k| g[\pickIds].indexOf(k) }) ? 0;
        };
    };
};

// Is the binding a knob or a pedal on a level, a count or a choice? Then its
// takeover, its hysteresis (a CC's) and its input range can be set.
~midiGuiIsKnob = { |b|
    b.notNil and: { ~midiIsKnob.(b, (~midiTargets ? ())[b[\target]] !? { |t| t[\kind] }) }
};

// The input range's row: the selected binding's range, or a sweep's progress
// (naming what it sweeps when another row is selected). Done ends a sweep
// from any row; Full is the selected knob's.
~midiGuiRefreshRange = {
    var g = ~midiGui, b = ~midiGuiSelected.(), sw = ~midiSweep, knob;
    if(g[\rangeText].notNil and: { g[\rangeText].isClosed.not }) {
        knob = ~midiGuiIsKnob.(b);
        g[\sweep].enabled_(knob or: { sw.notNil });
        g[\fullRange].enabled_(knob);
        g[\sweep].value = sw.notNil.binaryValue;
        g[\rangeText].string_(case
            { sw.notNil } {
                "sweeping" ++ if(sw[\binding] === b) { "" } { " " ++ LooperMidiMap.describe(sw[\binding]) }
                    ++ ": " ++ (sw[\lo] !? { |lo| lo.asString ++ "–" ++ sw[\hi] } ? "move it")
            }
            { knob } { (b[\inLo] ? 0).asString ++ "–" ++ (b[\inHi] ? LooperMidiMap.top(b[\msg])) }
            { "" });
    };
};

// The editor follows the binding selected in the list.
~midiGuiRefreshEditor = {
    var g = ~midiGui, b = ~midiGuiSelected.(), t, cc, toggle, knob, devices;
    if(g[\learn].notNil and: { g[\learn].isClosed.not }) {
        t = b !? { (~midiTargets ? ())[b[\target]] };
        cc = b.notNil and: { b[\msg] == \cc };
        toggle = t.notNil and: { t[\kind] == \toggle };
        knob = ~midiGuiIsKnob.(b);
        g[\takeMenu].enabled_(knob);
        ~midiGuiRefreshRange.();
        [g[\learn], g[\remove], g[\chan], g[\device]].do { |w| w.enabled_(b.notNil) };
        [g[\setMin], g[\setMax], g[\swap]].do { |w|
            w.enabled_(t.notNil and: { [\continuous, \step].includes(t[\kind]) } and: { t[\get].notNil });
        };
        g[\switchMenu].enabled_(cc and: { t.notNil } and: { (t[\kind] == \trigger) or: { toggle } });
        g[\modeMenu].enabled_(toggle);
        g[\hystMenu].enabled_(knob and: { cc });
        devices = ((~midiSources ? ()).values.collect { |n| n[0] } ++ (b !? { |x| [x[\device]] } ? []))
            .reject(_.isNil).asSet.asArray.sort;
        g[\deviceNames] = devices;
        g[\device].items_(["any input"] ++ devices);
        b !? {
            g[\chan].value = (b[\chan] !? { |c| c + 1 }) ? 0;
            g[\device].value = (b[\device] !? { |d| devices.indexOfEqual(d) !? { |i| i + 1 } }) ? 0;
            g[\switchMenu].value = [\knob, \oneMessage, \pressRelease].indexOf(b[\switch] ? \knob) ? 0;
            g[\modeMenu].value = [\press, \hold, \follow].indexOf(b[\mode] ? \press) ? 0;
            g[\hystMenu].value = if(b[\hysteresis].isNil) { 0 } { b[\hysteresis].clip(0, 3) + 1 };
            g[\takeMenu].value = [nil, \none, \pickup, \scale].indexOf(b[\takeover]) ? 0;
        };
        g[\learn].value = (~midiLearning.notNil and: { b.notNil } and: { ~midiLearning[\target] == b[\target] }).binaryValue;
    };
};

// Everything the section shows, from the router's state. On AppClock only.
~midiGuiRefresh = {
    var g = ~midiGui, map = ~midiMap, names, l, q, status, row, sel, inputs, listen, newer, attention, backs, back;
    ~guiHintRowRefresh !? { |f| f.value };
    // Every tooltip and label that names a message, wherever it is, once per
    // map: they say what the map says, and this runs on every learning step
    // too. A view built since was painted when it was tagged.
    if(~midiWatchShownMap !== map) {
        ~midiWatchShownMap = map;
        ~midiWatchRefresh !? { |f| f.value };
    };
    // MIDI Map mode's masks (gui-mapmode.scd): what drives each, the armed one.
    ~mapRepaint !? { |f| f.value };
    if(g[\view].notNil and: { g[\view].isClosed.not }) {
        ~mapButtonPaint !? { |f| f.value };
        // The inputs, each with its Listen switch.
        inputs = (~midiSources ? ()).values.collect { |n| n[0] }.reject { |d| d.contains("IAC") }.asSet.asArray.sort;
        if(g[\inputNames] != inputs) {
            g[\inputNames] = inputs;
            g[\inputsView].children.do(_.remove);
            g[\inputButtons] = inputs.collect { |d|
                var b = LooperTile().border_(~gt[\line]).font_(~guiSans.(13)).fixedHeight_(26).pad_(8)
                    .states_([[d ++ ": not listened to", ~gt[\mute], nil], [d, ~gt[\onacc], ~gt[\play]]])
                    .toolTip_("Whether megalooper listens to " ++ d ++ ". Kept in settings.json.")
                    .action_({ |b| ~midiGuiListen.(d, b.value == 1) });
                g[\inputs].add(b);
                [d, b]
            };
            if(inputs.isEmpty) { g[\inputs].add(~guiText.("none connected", 13, ~guiHintColor)) };
        };
        // Send back, for each input with an output of its own (5.7).
        backs = inputs.select { |d| ~midiBackCan.(d) };
        if(g[\backNames] != backs) {
            g[\backNames] = backs;
            g[\backsView].children.do(_.remove);
            g[\backButtons] = backs.collect { |d|
                var b = LooperTile().border_(~gt[\line]).font_(~guiSans.(13)).fixedHeight_(26).pad_(8)
                    .states_([[d ++ ": off", ~gt[\mute], nil], [d ++ ": on", ~gt[\onacc], ~gt[\play]]])
                    .toolTip_("Whether megalooper sends " ++ d ++ " where each control it drives is: an encoder "
                        ++ "then goes on from where the mouse or a preset put it, and a button's light shows its "
                        ++ "switch. Only for an input listened to. Kept in settings.json.")
                    .action_({ |b| ~midiGuiSendBack.(d, b.value == 1) });
                g[\backs].add(b);
                [d, b]
            };
            if(backs.isEmpty) { g[\backs].add(StaticText().string_("no input takes MIDI back").stringColor_(~guiHintColor)) };
        };
        // From the settings in memory: the file's write may still be under way.
        listen = ~midiSettingsNow.()[\listen];
        (g[\inputButtons] ? []).do { |pair| pair[1].value = ((listen[pair[0]] ? true) == true).binaryValue };
        back = ~midiSettingsNow.()[\sendBack] ? Dictionary.new;
        (g[\backButtons] ? []).do { |pair|
            pair[1].value = (back[pair[0]] == true).binaryValue;
            pair[1].enabled = (listen[pair[0]] ? true) == true;
        };
        // The map. A rig with none yet (a fresh clone's) shows "(none)" until
        // its first Keep names one.
        names = ~midiGuiMapNames.();
        map !? { |m| if(m.name.notNil and: { names.includesEqual(m.name.asString).not }) { names = names ++ [m.name.asString] } };
        if(map.isNil or: { map.name.isNil }) { names = [nil] ++ names };
        g[\mapNames] = names;
        g[\mapMenu].items_(names.collect { |n|
            if(n.isNil) { "(none)" } {
                n ++ if(File.exists(~midiMapPath.(~midiUserDir.(), n))) { " (yours)" } { "" }
            }
        });
        g[\mapMenu].value = (map !? { |m| m.name !? { |n| names.indexOfEqual(n.asString) } }) ? 0;
        // A shipped map newer than the one yours started from (8.3).
        newer = map !? { |m| m.basedOn !? { |b|
            var r = LooperMidiMap.parse(~midiReadText.(~midiMapPath.(~midiShippedDir.(), b)));
            if(r.isString.not and: { (r[\revision] ? 0) > (m.revision ? 0) }) { r[\revision] }
        } };
        status = if(map.isNil or: { map.name.isNil and: { map.bindings.isEmpty } }) {
            "No map: Add a mapping below, then Keep"
        } {
            map.bindings.size.asString ++ " bindings · "
                ++ ((yours: "yours", backup: "your last backup", shipped: "as shipped")[~midiMapFrom ? \none] ? "not kept yet")
                ++ (map.basedOn !? { |b| ", based on " ++ b ++ (map.revision !? { |r| " (revision " ++ r ++ ")" } ? "") } ? "")
                ++ if(~midiMapDirty.() or: { map.name.isNil }) { " · changes not kept" } { "" }
                ++ (newer !? { |r| " · the shipped " ++ map.basedOn ++ " is at revision " ++ r
                    ++ " now: Reset to shipped takes it" } ? "")
        };
        // What the header says, said here too, unless the map has moved on
        // from a fresh clone's hint by now.
        attention = ~midiAttention.();
        if(attention.notNil and: { (attention[1] != \note) or: { map.isNil } or: { map.bindings.isEmpty } }) {
            status = attention[0];
        };
        g[\status].string_(status)
            .stringColor_(case
                { attention.notNil and: { attention[1] != \note } } { ~guiDanger }
                { attention.notNil or: { ~midiMapDirty.() } or: { newer.notNil } } { ~gt[\armed] }
                { ~guiHintColor });
        g[\keep].enabled_(map.notNil and: { map.name.notNil or: { map.bindings.notEmpty } });
        g[\defTake].value = [\none, \pickup, \scale].indexOf((~midiDefaults ? ())[\takeover] ? \none) ? 0;
        g[\defHyst].value = ((~midiDefaults ? ())[\hysteresis] ? 1).clip(0, 3);
        g[\undo].enabled_(~midiUndo.notEmpty);
        g[\revert].value = (~midiGuiArm == \revert).binaryValue;
        g[\reset].value = (~midiGuiArm == \reset).binaryValue;
        g[\reset].enabled_(map.notNil and: { map.name.notNil }
            and: { File.exists(~midiMapPath.(~midiShippedDir.(), map.name)) }
            and: { File.exists(~midiMapPath.(~midiUserDir.(), map.name)) });
        // Learning, and the question about taking a message.
        l = ~midiLearning;
        q = l !? { |x| x[\question] };
        g[\learnText].string_(case
            { q.notNil } { ~midiLearnNote ? "" }
            { l.notNil } { "Learning " ++ ~midiTargetLabel.(l[\target]) ++ ": " ++ (~midiLearnNote ? "") }
            { ~midiLearnNote ? "" })
            .stringColor_(if(l.notNil) { ~gt[\armed] } { ~guiInk ? Color.black });
        // (What the section means to show, kept for the checks: a view in a
        // window never shown answers false to `visible` whatever it was told.)
        g[\questionOpen] = q.notNil;
        g[\learning] = l.notNil;
        g[\move].visible_(q.notNil);
        g[\both].visible_(q.notNil);
        g[\cancel].visible_(l.notNil);
        // The list, rebuilt when the map changed.
        if(g[\shownMap] !== map) {
            sel = g[\list].currentItem !? { |it| it.index };
            g[\shownMap] = map;
            g[\list].clear;
            ~midiGuiRows = (map !? { |m| m.bindings } ? []).copy;
            g[\greyed] = List.new;
            ~midiGuiRows.do { |b, i|
                row = g[\list].addItem(~midiGuiRow.(b));
                if(~midiGuiLive.(b).not) {
                    (0..5).do { |c| row.setTextColor(c, ~gt[\mute]) };
                    g[\greyed].add(i);
                };
            };
            sel !? { |i| if(i < ~midiGuiRows.size and: { i >= 0 }) { g[\list].currentItem = g[\list].itemAt(i) } };
        };
        ~midiGuiRefreshEditor.();
        ~midiGuiRefreshPicker.();
    };
};
)
