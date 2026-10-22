// megalooper — does the Effects pane build, and does it stay honest? Without a
// rig: the pane is built from real Qt views against a MegaSA whose server is a
// recording stub, the widgets and the model are driven against each other,
// and it exits 0 or 1. It needs no server, no audio device and no Bias FX, so
// it runs wherever sclang does; check-gui.scd covers the same pane on the SA
// rig itself, with the real plugin.
//
//   /Applications/SuperCollider.app/Contents/MacOS/sclang scripts/check-gui-effects.scd
//
// Nothing here is written to the real preset folders.
(
var scripts = Looper.repoRoot +/+ "scripts";
var tmp = PathName.tmp +/+ "megalooper-gui-effects-" ++ UniqueID.next;
var msgs = List.new;
var stub, m, looper, pane, fam, pass = 0, fail = 0, fails = List.new;
var ok = { |label, cond, detail|
    if(cond == true) { pass = pass + 1; ("  ok    " ++ label).postln }
    { fail = fail + 1; fails.add(label ++ " — " ++ (detail ? ""));
      ("  FAIL  " ++ label ++ " — " ++ (detail ? "")).postln };
};
var lastSet = { |node, name|
    var found;
    msgs.do { |msg|
        if((msg[0] == 15) and: { msg[1] == node.nodeID }) {
            msg.copyToEnd(2).pairsDo { |k, v| if(k == name) { found = v } };
        };
    };
    found
};
// A real MegaSA on the harness's recording stub (~tMegaSA), its guitar's plugin
// one that failed to open: the pane must still build, and a preset saved now
// must carry no bank. A Looper attached, so the loop's effects exist.
(scripts +/+ "tests" +/+ "_harness.scd").load;
// A write here is on disk when its call returns, so a check can read it.
MegaFiles.alwaysSync = true;
stub = ~tStubServer.();
msgs = stub[\msgs];

["setup-routing.scd", "setup-midi.scd", "setup-sa.scd", "gui-const.scd", "gui-theme.scd", "gui-presets.scd",
    "gui-sa.scd", "gui-effects.scd", "gui-shell.scd"].do { |f| (scripts +/+ f).load };
MegaSA.loadSynthDefs;
~rp = (sa: true);
~saFxPresetDir = tmp;
File.mkdir(tmp);

m = ~tMegaSA.(stub, ~tFakePlugin.(\failed));
looper = ~tLooper.();
Routine { m.attachLooper(looper) }.next;
~megaSA = m;

Routine {
    var tick = { 0.15.wait };
    "== build ==".postln;
    ~effectsSelected = MegaSAFx.guitarKeys.first;
    pane = ~buildEffectsPane.();
    tick.();
    ok.("the pane builds", pane.notNil and: { pane.isClosed.not });
    ok.("a tile per effect, plus Bias FX", ~effectsTiles.size == (MegaSAFx.keys.size + 1),
        ~effectsTiles.size.asString);
    ok.("the editor shows the selected effect's settings",
        ~effectsWidgets.size == MegaSAFx.paramsOf(~effectsSelected).size, ~effectsWidgets.size.asString);
    ok.("the Bias FX tile says it failed", ~effectsBiasTileStatus.sub.beginsWith("failed"),
        ~effectsBiasTileStatus.sub);

    "== every effect's editor ==".postln;
    MegaSAFx.keys.do { |key|
        ~effectsSelect.(key);
        tick.();
        ok.(key ++ ": one widget per setting", ~effectsWidgets.size == MegaSAFx.paramsOf(key).size,
            ~effectsWidgets.keys.asArray.asString);
        ok.(key ++ ": every readout shows the model's value",
            MegaSAFx.paramsOf(key).every { |p|
                ~effectsWidgets[p[\name]][\readout].string == ~effectsFormat.(p, m.fxParam(p[\name]))
            });
        ok.(key ++ ": its tile is the selected one, outlined in ink and saying so",
            (~effectsTiles[key][\select].border == ~gt[\ink])
                and: { ~effectsTiles[key][\select].sub.contains("editing") },
            ~effectsTiles[key][\select].sub);
    };
    ~effectsSelect.(\bias);
    tick.();
    ok.("Bias FX's page builds", ~effectsBiasStatus.notNil
        and: { ~effectsBiasStatus.string.contains("failed") }, (~effectsBiasStatus !? (_.string)).asString);

    // The plugin's sends: megalooper hears the controllers, the plugin does
    // not, so a tile passes it one for its own MIDI learn.
    "== MIDI to the plugin ==".postln;
    {
        var found = List.new, plug = m.device(\plugin1).plugin, said;
        var walk = { |v| v.children.do { |c|
            if(c.isKindOf(LooperTile) and: { c.states.notNil } and: { "12345678".contains(c.states[0][0].asString) }
                and: { c.states[0][0].asString.size == 1 }) { found.add(c) };
            walk.(c) } };
        walk.(~effectsEditorHolder);
        ok.("the plugin's page has its eight sends, 1 to 8", found.collect { |t| t.states[0][0] } == (1..8).collect(_.asString),
            found.collect { |t| t.states[0][0] }.asString);
        ok.("...each tagged as its control, for MIDI Map mode", (found.size == 8) and: { (1..8).every { |n|
            ~mapTags.any { |e| (e[0] === found[n - 1]) and: { e[1].value == ("sa.fxSend.plugin1." ++ n).asSymbol } } } });
        ok.("...and its tip says which controller it sends", (found.size == 8) and: { found[2].toolTip.contains("controller 22") },
            (found[2] !? (_.toolTip)).asString);
        if(found.size == 8) {
            found[2].doAction;
            tick.();
            said = ~presetFamily.(\saFx)[\statusText].string;
            ok.("a send to a plugin that is not open sends nothing, and the bar says so",
                plug[\controls].isNil and: { said.contains("not open") }, said);
            plug[\state] = \open;
            found[2].doAction;
            found[7].doAction;
            ok.("to one that is open a tile sends its controller, value 127 on channel 1",
                plug[\controls] == [[0, 22, 127], [0, 27, 127]], plug[\controls].asString);
            plug[\state] = \failed;
            plug[\controls] = nil;
        };
    }.value;

    "== the racks' variations ==".postln;
    {
        var menuIn = { |view|
            var found;
            var walk = { |v| v.children.do { |c|
                if(c.isKindOf(PopUpMenu) and: { c.items.first == "Variation…" }) { found = c };
                walk.(c) } };
            walk.(view);
            found
        };
        var menu;
        ~effectsSelect.(\shifter);
        tick.();
        ok.("an effect outside a rack has no variation menu", menuIn.(~effectsEditorHolder).isNil);
        ~effectsSelect.(\delay);
        tick.();
        menu = menuIn.(~effectsEditorHolder);
        ok.("a rack's effect has one, listing its variations",
            menu.notNil and: { menu.items.includesEqual("short") and: { menu.items.includesEqual("as saved") } },
            (menu !? { |mm| mm.items }).asString);
        menu.valueAction_(menu.items.indexOfEqual("short"));
        tick.();
        ok.("recalling 'short' sets its tap (84 ms)", (m.fxParam(\delayTimeR) - 0.0843).abs < 0.001,
            m.fxParam(\delayTimeR).asString);
        ok.("and the knob shows it", ~effectsWidgets[\delayTimeR][\readout].string.contains("84"),
            ~effectsWidgets[\delayTimeR][\readout].string);
        menu.valueAction_(menu.items.indexOfEqual("as saved"));
        tick.();
        ok.("'as saved' is the start again", m.fxEdited(\delay).not);
    }.value;

    "== knobs write the model, the model paints the knobs ==".postln;
    MegaSAFx.keys.do { |key|
        var p = MegaSAFx.paramsOf(key).detect { |q| q[\choices].isNil };
        var node = m.fxNode(key);
        var w, want;
        ~effectsSelect.(key);
        tick.();
        w = ~effectsWidgets[p[\name]];
        w[\knob].valueAction_(0.3);
        tick.();
        want = MegaSAFx.constrain(p[\name], p[\spec].map(0.3));
        ok.(p[\name] ++ ": the knob moves the model", (m.fxParam(p[\name]) - want).abs < 1e-4,
            m.fxParam(p[\name]).asString ++ " want " ++ want);
        ok.(p[\name] ++ ": which reaches its chain", lastSet.(node, p[\name]) == m.fxParam(p[\name]),
            lastSet.(node, p[\name]).asString);
        ok.(p[\name] ++ ": the readout follows", w[\readout].string == ~effectsFormat.(p, want), w[\readout].string);
        ok.(key ++ ": the tile marks the edit", ~effectsTiles[key][\select].states[0][0].contains("•"),
            ~effectsTiles[key][\select].states[0][0]);
        m.setFxParam(p[\name], p[\spec].map(0.8));
        tick.();
        ok.(p[\name] ++ ": the model moves the knob",
            (w[\knob].value - ~effectsUnmap.(p, m.fxParam(p[\name]))).abs < 1e-3, w[\knob].value.asString);
        // Held: the model must not pull the knob from under the hand.
        ~effectsHeld = p[\name];
        w[\knob].value = 0.5;
        m.setFxParam(p[\name], p[\spec].map(0.1));
        tick.();
        ok.(p[\name] ++ ": a held knob is not moved by the model", w[\knob].value == 0.5, w[\knob].value.asString);
        ok.(p[\name] ++ ": but its readout is", w[\readout].string == ~effectsFormat.(p, m.fxParam(p[\name])));
        w[\knob].mouseUpAction.value(w[\knob]);
        ok.(p[\name] ++ ": let go, the knob shows the setting",
            (w[\knob].value - ~effectsUnmap.(p, m.fxParam(p[\name]))).abs < 1e-3, w[\knob].value.asString);
        ok.(p[\name] ++ ": and nothing is held", ~effectsHeld.isNil);
        // A double-click is the Live set's value.
        w[\knob].mouseDownAction.value(w[\knob], 5, 5, 0, 0, 2);
        tick.();
        ok.(p[\name] ++ ": a double-click is the Live set's value", m.fxParam(p[\name]) == p[\spec].default,
            m.fxParam(p[\name]).asString);
        w[\knob].mouseUpAction.value(w[\knob]);
        m.resetFx(key);
        tick.();
        ok.(key ++ ": Live values clears the tile's mark",
            ~effectsTiles[key][\select].states[0][0].contains("•").not);
    };
    MegaSAFx.params.select { |p| p[\choices].notNil }.do { |p|
        var w;
        ~effectsSelect.(p[\fx]);
        tick.();
        w = ~effectsWidgets[p[\name]];
        w[\menu].valueAction_(0);
        tick.();
        ok.(p[\name] ++ ": the menu sets the choice", m.fxParam(p[\name]) == p[\choices][0][0],
            m.fxParam(p[\name]).asString);
        m.setFxParam(p[\name], p[\choices].last[0]);
        tick.();
        ok.(p[\name] ++ ": the model moves the menu", w[\menu].value == (p[\choices].size - 1),
            w[\menu].value.asString);
        m.resetFx(p[\fx]);
    };

    "== the footswitches ==".postln;
    MegaSAFx.keys.do { |key|
        m.toggleFx(key);
        tick.();
        ok.(key ++ ": a footswitch lights its tile", ~effectsTiles[key][\on].value == 1);
        ~effectsTiles[key][\on].valueAction_(0);
        tick.();
        ok.(key ++ ": the tile switches it off again", m.fx(key).not);
    };

    ok.("an empty folder's menu says there are no sounds yet", ~presetNoneText.(\saFx) == "— no sounds yet —", ~presetNoneText.(\saFx));
    ok.("the bar over the chains calls its files sounds, not presets",
        ~presetFamily.(\saFx)[\menu].parent.children.any { |c| c.isKindOf(StaticText) and: { c.string == "sound" } },
        ~presetFamily.(\saFx)[\menu].parent.children.select { |c| c.isKindOf(StaticText) }.collect(_.string).asString);

    "== the first plugin's name ==".postln;
    if(m.device(\plugin1).notNil) {
        m.renameDevice(\plugin1, "Neural Amp");
        tick.();
        ok.("a first plugin that is not Bias FX is called by its own name: in the pane's words and on its tile",
            (~effectsPluginWord.() == "Neural Amp") and: { ~effectsTitle.(\bias) == "Neural Amp" }
                and: { ~effectsTiles[\bias][\select].states[0][0].contains("Neural Amp") },
            [~effectsPluginWord.(), ~effectsTiles[\bias][\select].states[0][0]].asString);
        m.renameDevice(\plugin1, "BIAS FX 2");
        tick.();
        ok.("...and Bias FX as it always was", (~effectsPluginWord.() == "Bias FX")
            and: { ~effectsTiles[\bias][\select].states[0][0] == "Bias FX" }, ~effectsTiles[\bias][\select].states[0][0]);
    } { ok.("the first plugin is in a chain here", false) };

    "== the status line ==".postln;
    {
        var status = ~effectsStatus.();
        ok.("the status line names a plugin that is not simply open, and wants attention for one that failed",
            status[0].contains("BIAS FX 2: failed") and: { status[1] }, status.asString);
        ok.("...and says nothing of drum hits while none was dropped", status[0].contains("dropped").not);
        m.drums.instVarPut(\dropped, 3);
        ~effectsPaintStatus.();
        ok.("drum hits the language dropped are counted there, and the line under the rows shows it",
            ~effectsStatus.()[0].contains("3 drum hits dropped") and: { ~effectsStatusText.string.contains("3 drum hits dropped") },
            ~effectsStatusText.string);
        m.drums.instVarPut(\dropped, 0);
        ~megaSA = nil;
        ok.("with no Megalooper SA the line is empty", ~effectsStatus.() == ["", false]);
        ~megaSA = m;
        ~effectsPaintStatus.();
    }.value;

    "== diagnostics ==".postln;
    {
        // (Read, never copied: a check must not write over your clipboard.)
        var text = ~effectsDiagnostics.();
        ok.("the diagnostics name the build, the three chains with every device and its switch, and each plugin's state",
            text.contains("megalooper diagnostics") and: { text.contains("build: ") } and: { text.contains("guitar chain:") }
                and: { text.contains("loop chain:") } and: { text.contains("drums chain:") } and: { m.devices.every { |d| text.contains("  " ++ d.id ++ " (") } }
                and: { text.contains("BIAS FX 2: failed") } and: { text.contains("status: ") },
            text);
        ok.("...and ⋯ offers to copy them, whatever is being edited", ~effectsDeviceItems.(nil).collect { |it| it[\label] } == ["Copy diagnostics"]);
    }.value;

    "== chain edits by menu ==".postln;
    {
        var items, n, id, keep = ~guiView, was = ~saPlugins;
        var find = { |list, label| list.detect { |it| it[\label] == label } };
        var shown = { |list| list.collect { |it| [it[\label], it[\enabled]] } };
        ok.("there are three rows: the guitar's, the loop's and the drums'", ~effectsTracks.() == [\guitar, \loop, \drums]
            and: { ~effectsTracks.().every { |t| ~effectsRowHolders[t].notNil and: { ~effectsRowHolders[t].isClosed.not } } });
        ok.("each row ends in a + tile", ~effectsTracks.().every { |t|
            (~effectsPlusTiles ? ())[t].notNil and: { ~effectsPlusTiles[t].isClosed.not } });
        items = ~effectsAddItems.(\loop);
        ok.("+ offers every built-in effect, and the scan last",
            (items.select { |it| it[\section] == \builtin }.collect { |it| it[\label] } == MegaSAFx.keys.collect { |k| MegaSAFx.title(k) })
                and: { items.last[\section] == \scan }, shown.(items).asString);
        n = m.loopChain.devices.size;
        find.(items, MegaSAFx.title(\filter))[\action].value;
        tick.();
        id = m.loopChain.devices.last.id;
        ok.("picking one adds it at the end of that chain, with a tile of its own",
            (m.loopChain.devices.size == (n + 1)) and: { m.loopChain.devices.last.type == \filter } and: { ~effectsTiles[id].notNil }, id.asString);
        items = ~effectsDeviceItems.(id);
        ok.("⋯ for the last device of a chain: left, not right, each other chain, Remove, Reset",
            shown.(items) == [["Move left", true], ["Move right", false], ["Move to the guitar chain", true],
                ["Move to the drums chain", true], ["Remove", true], ["Reset", true],
                ["Copy diagnostics", true]],
            shown.(items).asString);
        find.(items, "Move left")[\action].value;
        tick.();
        ok.("Move left puts it one place earlier", m.loopChain.devices.indexOf(m.device(id)) == (n - 1),
            m.loopChain.devices.collect(_.id).asString);
        find.(~effectsDeviceItems.(id), "Move to the guitar chain")[\action].value;
        tick.();
        ok.("Move to the other chain puts it at that chain's end", m.guitarChain.devices.last.id == id,
            m.guitarChain.devices.collect(_.id).asString);
        ~guiView = \fx;
        ~guiKeyDown.($z, 1048576, 0);
        tick.();
        ok.("Cmd+Z undoes a chain edit, on the effects' view", m.loopChain.devices.includes(m.device(id)));
        ~guiKeyDown.($Z, 1048576 | 131072, 0);
        tick.();
        ok.("Shift+Cmd+Z does it again", m.guitarChain.devices.last.id == id);
        ~guiView = \perform;
        ~guiKeyDown.($z, 1048576, 0);
        tick.();
        ok.("...and neither does anything on another view", m.guitarChain.devices.last.id == id);
        ~guiView = keep;
        find.(~effectsDeviceItems.(id), "Remove")[\action].value;
        tick.();
        ok.("Remove takes it out, and its tile with it", m.device(id).isNil and: { ~effectsTiles[id].isNil });
        ok.("⋯ for the plugin's tile offers its window, not Reset",
            ~effectsDeviceItems.(\bias).any { |it| it[\label] == "Open its window" }
                and: { ~effectsDeviceItems.(\bias).any { |it| it[\label] == "Reset" }.not },
            shown.(~effectsDeviceItems.(\bias)).asString);
        ~saPlugins = [
            (key: "Verb", name: "Verb", vendor: "Wide", format: "vst3", ins: 2, outs: 2, synth: false, bridged: false,
                uid: "V3", version: "1", path: "/abs/x/Verb.vst3"),
            (key: "Old", name: "Old", vendor: "Past", format: "vst2", ins: 2, outs: 2, synth: false, bridged: true,
                uid: "O1", version: "1", path: "/abs/x/Old.vst"),
            (key: "Keys", name: "Keys", vendor: "Wide", format: "vst3", ins: 0, outs: 2, synth: true, bridged: false,
                uid: "K3", version: "1", path: "/abs/x/Keys.vst3")
        ];
        items = ~effectsAddItems.(\guitar).select { |it| it[\section] == \plugin };
        ok.("+ lists this Mac's plugins under their vendors: one it cannot host greyed with the reason, an instrument not at all",
            items.collect { |it| [it[\label], it[\group], it[\enabled], it[\why].notNil] }
                == [["Verb", "Wide", true, false], ["Old", "Past", false, true]],
            items.collect { |it| [it[\label], it[\group], it[\enabled]] }.asString);
        // The menu itself, made and read but never put up.
        items = ~effectsMenuOf.(~effectsAddItems.(\guitar));
        ok.("the + menu: the built-ins, a line, a submenu per vendor, a line, the scan; the one megalooper cannot host greyed, with why",
            (items.actions.size == (MegaSAFx.keys.size + 5))
                and: { items.actions[MegaSAFx.keys.size + 1].menu.isKindOf(Menu) } and: { items.actions[MegaSAFx.keys.size + 1].string == "Wide" }
                and: { items.actions[MegaSAFx.keys.size + 1].menu.actions.collect(_.string) == ["Verb"] }
                and: { items.actions[MegaSAFx.keys.size + 2].menu.actions.first.enabled.not }
                and: { items.actions[MegaSAFx.keys.size + 2].menu.actions.first.string.contains("(built for") }
                and: { items.actions.last.string.contains("Scan") },
            items.actions.collect { |x| x.string }.asString);
        items.destroy;
        ok.("no items, no menu", ~effectsMenuOf.([]).isNil);
        ~saPlugins = was;
        m.insertPlugin(\loop, nil, "Nothing there");
        tick.();
        ok.("an edit megalooper refuses is said in the bar", ~presetFamily.(\saFx)[\statusText].string.contains("Not done"),
            ~presetFamily.(\saFx)[\statusText].string);
    }.value;

    "== a further plugin ==".postln;
    if(\VSTPlugin.asClass.notNil) {
        // (No scan here: the catalog is handed in.)
        m.instVarPut(\catalog, [(key: "Verb", name: "Verb", vendor: "Wide", format: "vst3", ins: 2, outs: 2, synth: false,
            bridged: false, uid: "V3", version: "1", path: "/abs/x/Verb.vst3")]);
        m.insertPlugin(\loop, nil, "Verb");
        tick.();
        ok.("a plugin added from the catalog has a tile of its own, named after it",
            (~effectsPluginTiles[\plugin2] !? { |t| t.states[0][0] }) == "Verb", ~effectsPluginTiles.keys.asArray.asString);
        ok.("...beside the first plugin's tile, which stays the amp's", ~effectsTiles[\bias].notNil and: { ~effectsTiles[\plugin2].isNil });
        ~effectsPluginTiles[\plugin2].doAction;
        tick.();
        ok.("a click on it selects it: its page is shown, with the button for its own window, and its tile says so",
            (~effectsSelected == \plugin2) and: { ~effectsPluginTiles[\plugin2].sub.contains("editing") }
                and: { ~effectsEditorHolder.children.any { |v| v.children.any { |c| c.isKindOf(LooperTile) and: { c.states[0][0] == "Open its window" } } } },
            [~effectsSelected, ~effectsPluginTiles[\plugin2].sub].asString);
        ok.("...and ⋯ acts on it: it can be moved and removed, and has its window, not Reset",
            ~effectsDeviceItems.(\plugin2).collect { |it| it[\label] }
                == ["Move left", "Move right", "Move to the guitar chain", "Move to the drums chain", "Remove", "Open its window",
                    "Copy diagnostics"],
            ~effectsDeviceItems.(\plugin2).collect { |it| it[\label] }.asString);
        m.undo;
        tick.();
        ok.("...and gone when the plugin is", ~effectsPluginTiles[\plugin2].isNil, ~effectsPluginTiles.keys.asArray.asString);
        m.instVarPut(\catalog, nil);
    };
    "== sounds through the bar ==".postln;
    fam = ~presetFamily.(\saFx);
    ~presetRefreshList.(\saFx);
    ok.("an empty folder disables the menu", fam[\menu].enabled.not);
    {
        var p = MegaSAFx.paramsOf(MegaSAFx.loopKeys.last).first;
        m.setFxParam(p[\name], p[\spec].map(0.7));
        fam[\nameField].string_("Gui Check");
        ~presetSave.(\saFx);
        tick.();
        ok.("Save writes the sound", File.exists(tmp +/+ "gui-check.json"));
        ok.("...and says so once it is written, not before", fam[\statusText].string.contains("Saved gui-check"), fam[\statusText].string);
        ok.("...both chains, every device", { var x = MegaSASound.read(tmp +/+ "gui-check.json");
            x.isString.not and: { x.devices.collect { |d| d[\id] } == m.devices.collect(_.id) } and: { x.name == "Gui Check" } }.value);
        ok.("with the plugin down, no state beside it", File.exists(tmp +/+ "gui-check.states").not);
        // The model answers a recall inside the bar's own load: its note is the last word.
        m.changed(\soundLoaded, "gui-check", true, ["a device was left out"]);
        ~presetSetStatus.(\saFx, "Loaded gui-check");
        tick.();
        ok.("a recall's note outlasts the bar's own Loaded", fam[\statusText].string.contains("a device was left out"), fam[\statusText].string);
        ok.("the menu selects it", fam[\items][fam[\menu].value] == "gui-check",
            fam[\menu].items.asString);
        m.resetFx(p[\fx]);
        ok.("Revert brings it back", ~presetRevert.(\saFx).notNil
            and: { (m.fxParam(p[\name]) - MegaSAFx.constrain(p[\name], p[\spec].map(0.7))).abs < 1e-4 },
            m.fxParam(p[\name]).asString);
        ~presetDelete.(\saFx);
        ok.("Delete asks first", File.exists(tmp +/+ "gui-check.json"));
        ~presetDelete.(\saFx);
        ok.("and deletes on the second click", File.exists(tmp +/+ "gui-check.json").not);
        m.resetFx(p[\fx]);
    }.value;

    // A tile moves by dragging it. The mouse handlers are driven as Qt
    // drives them: a press on the tile, moves and a release with the
    // pointer's place in the pressed tile's own coordinates.
    "== dragging a tile ==".postln;
    {
        var r = { |x, y, w = 182, h = 58| Rect(x, y, w, h) };
        var rows = [(track: \guitar, area: Rect(100, 100, 900, 60), tiles: [r.(104, 101), r.(310, 101), r.(516, 101)]),
            (track: \loop, area: Rect(100, 190, 900, 60), tiles: [r.(104, 191)])];
        var at = { |x, y| ~effectsDropAt.(Point(x, y), rows) };
        var ids = { |track| m.chainFor(track).devices.collect(_.id) };
        var tileOf = { |id| var c = m.chainOf(m.device(id)); ~effectsRowTiles[c.track][c.devices.indexOf(m.device(id))] };
        // The pointer's place for a drop into `gap` of `track`, as the pressed tile sees it.
        var toGap = { |tile, track, gap|
            var rects = ~effectsRowTiles[track].collect(_.absoluteBounds), area = ~effectsRowHolders[track].absoluteBounds;
            var x = case { rects.isEmpty } { area.left + 20 } { gap >= rects.size } { rects.last.right + 5 } { rects[gap].left - 3 };
            var y = if(rects.isEmpty) { area.center.y } { rects[0].center.y };
            Point(x, y) - tile.absoluteBounds.leftTop
        };
        var drag = { |id, track, gap, release = true|
            var tile = tileOf.(id), p, took;
            tile.mouseDownAction.value(tile, 20, 20, 0, 0, 1);
            p = toGap.(tile, track, gap);
            tile.mouseMoveAction.value(tile, 60, 24, 0);
            tile.mouseMoveAction.value(tile, p.x, p.y, 0);
            if(release) { took = tile.mouseUpAction.value(tile, p.x, p.y, 0, 0); tick.() };
            took
        };
        // A colour read back through Qt's palette comes back in 8 bits.
        var near = { |a, b| a.notNil and: { [a.red - b.red, a.green - b.green, a.blue - b.blue].every { |x| x.abs < 0.01 } } };
        var before, took, marked, tile, geo;
        ok.("a drop goes into the gap the pointer is at: before the first tile, between two, after the last",
            [at.(90, 120), at.(300, 130), at.(420, 130), at.(990, 130)]
                == [(track: \guitar, gap: 0), (track: \guitar, gap: 1), (track: \guitar, gap: 2), (track: \guitar, gap: 3)],
            [at.(90, 120), at.(300, 130), at.(420, 130), at.(990, 130)].asString);
        ok.("...on the row the pointer is on or nearest to, and on none far from both",
            [at.(300, 92), at.(300, 172), at.(300, 178), at.(300, 262), at.(300, 300), at.(300, 20)].collect { |x| x !? { |t| t[\track] } }
                == [\guitar, \guitar, \loop, \loop, nil, nil],
            [at.(300, 92), at.(300, 172), at.(300, 178), at.(300, 262), at.(300, 300), at.(300, 20)].asString);
        ok.("a drop beside where the tile is moves nothing; past it, one place less; onto the other chain, the gap's own place",
            [~effectsDropIndex.(\guitar, 1, \guitar, 1), ~effectsDropIndex.(\guitar, 1, \guitar, 2), ~effectsDropIndex.(\guitar, 1, \guitar, 0),
                ~effectsDropIndex.(\guitar, 1, \guitar, 3), ~effectsDropIndex.(\guitar, 1, \loop, 3)] == [nil, nil, 0, 2, 3]);
        geo = ~effectsRowGeometry.();
        ok.("the rows know where their tiles are on screen: in order, left to right, the loop's under the guitar's",
            geo.every { |row| var lefts = row[\tiles].collect { |t| t.left };
                (row[\tiles].size == m.chainFor(row[\track]).devices.size) and: { lefts == lefts.asSet.asArray.sort } }
                and: { geo[0][\tiles][0].top < geo[1][\tiles][0].top },
            geo.collect { |row| row[\tiles].collect { |t| [t.left, t.top] } }.asString);
        ok.("a gap before each tile and one after the last, the empty drums row's one gap too", ~effectsTracks.().every { |t|
            ~effectsGaps[t].size == (m.chainFor(t).devices.size + 1) });
        // Along its chain.
        before = ids.(\guitar);
        took = drag.(before[0], \guitar, 2);
        ok.("a tile dragged past its neighbour takes its place, and the rows follow",
            (ids.(\guitar) == ([before[1], before[0]] ++ before.drop(2))) and: { took == true }, ids.(\guitar).asString);
        ok.("...the drag was no click: nothing was selected or switched by it", m.fx(before[0]) == false);
        m.undo;
        tick.();
        ok.("...and Cmd+Z puts it back, as after the menu's move", ids.(\guitar) == before, ids.(\guitar).asString);
        // Onto the other chain.
        took = drag.(before[1], \loop, 0);
        ok.("dragged onto the other chain it goes there, at the gap",
            (ids.(\loop).first == before[1]) and: { ids.(\guitar).includes(before[1]).not }, [ids.(\guitar), ids.(\loop)].asString);
        m.undo;
        tick.();
        // Onto the drums' chain, which starts empty: its row is one gap wide.
        took = drag.(before[1], \drums, 0);
        ok.("dragged onto the empty drums row it goes onto the drums' chain, with its tile in that row",
            (ids.(\drums) == [before[1]]) and: { ids.(\guitar).includes(before[1]).not } and: { took == true }
                and: { ~effectsRowTiles[\drums].size == 1 }, [ids.(\guitar), ids.(\drums)].asString);
        ok.("...and ⋯ offers it the way to the other two", ~effectsDeviceItems.(before[1]).collect { |it| it[\label] }
            .select { |l| l.beginsWith("Move to") } == ["Move to the guitar chain", "Move to the loop chain"]);
        m.undo;
        tick.();
        ok.("...and Cmd+Z takes it back to the guitar's", (ids.(\guitar) == before) and: { ids.(\drums).isEmpty }
            and: { ~effectsRowTiles[\drums].isEmpty }, [ids.(\guitar), ids.(\drums)].asString);
        // + on the drums' row.
        { var item = ~effectsAddItems.(\drums).detect { |it| it[\label] == MegaSAFx.title(\saturator) }, id;
          item[\action].value;
          tick.();
          id = ids.(\drums).first;
          ok.("+ on the drums' row adds an effect to the drums' chain, with a tile and an editor of its own",
              (ids.(\drums).size == 1) and: { m.device(id).type == \saturator } and: { ~effectsTiles[id].notNil }, ids.(\drums).asString);
          m.undo;
          tick.();
          ok.("...and undo takes it off again", ids.(\drums).isEmpty and: { ~effectsTiles[id].isNil });
        }.value;
        // The mark, and letting go.
        tile = tileOf.(before[0]);
        drag.(before[0], \guitar, 3, false);
        marked = { [\guitar, \loop].collect { |t| ~effectsGaps[t].collect { |gap| near.(gap.background, ~gt[\fx]) } } };
        ok.("while it is dragged its tile is hatched and one gap is marked: where a drop would go",
            tile.hatch and: { marked.value == [(0..before.size).collect { |i| i == 3 }, false ! (ids.(\loop).size + 1)] },
            marked.value.asString);
        ok.("...and the bar says what is moving", ~presetFamily.(\saFx)[\statusText].string.contains("Moving"),
            ~presetFamily.(\saFx)[\statusText].string);
        ok.("Esc lets go of it: no mark, no hatch", (~guiKeyDown.(27.asAscii, 0, ~guiKeyEscape) == true)
            and: { marked.value.flat.includes(true).not } and: { tile.hatch.not });
        took = tile.mouseUpAction.value(tile, 700, 20, 0, 0);
        tick.();
        ok.("...and the release after it moves nothing, and is no click", (ids.(\guitar) == before) and: { took == true },
            ids.(\guitar).asString);
        ok.("with no drag in hand Esc is not taken", ~effectsDragCancel.() == false);
        // A press that does not travel is a click.
        tile = tileOf.(before[0]);
        tile.mouseDownAction.value(tile, 20, 20, 0, 0, 1);
        tile.mouseMoveAction.value(tile, 24, 22, 0);
        took = tile.mouseUpAction.value(tile, 24, 22, 0, 0);
        ok.("a press that travels a few pixels is still a click: the handlers leave it to the tile",
            took.isNil and: { tile.hatch.not } and: { ids.(\guitar) == before });
        // Dropped where it is.
        took = drag.(before[0], \guitar, 1);
        ok.("dropped beside where it is, nothing moves and nothing is added to undo", (ids.(\guitar) == before) and: { took == true });
    }.value;

    "== the chains' edits ==".postln;
    // The rows follow MegaSA's chains: a tile per device, in order, the
    // plugin's the Bias FX tile; a further device's editor drives that device.
    {
        var rowKeys = { |track|
            var canvas = ~effectsRowHolders[track] !? { |h| h.canvas };
            // (The + at the row's end is no device's tile.)
            var tiles = canvas !? { |c| c.children.select { |v|
                v.isKindOf(LooperTile) and: { (~effectsPlusTiles ? ()).values.any { |x| x === v }.not } } } ? [];
            tiles.collect { |t| ~effectsTiles.keys.detect { |k| ~effectsTiles[k][\select] === t } }
        };
        var keysOf = { |chain| chain.devices.collect { |d| if(d.isPlugin) { \bias } { d.id } } };
        var noPlugin = m.devices.any(_.isPlugin).not;
        var rebuilds = 0, realBuild = ~effectsBuildRows, d2, w, before, p;
        ok.("the rows are the chains, a tile per device in order",
            (rowKeys.(\guitar) == keysOf.(m.guitarChain)) and: { rowKeys.(\loop) == keysOf.(m.loopChain) },
            [rowKeys.(\guitar), rowKeys.(\loop)].asString);
        d2 = m.insertDevice(\guitar, 2, \delay);
        tick.();
        ok.("an insert puts its tile in its row, where it went", rowKeys.(\guitar) == keysOf.(m.guitarChain),
            rowKeys.(\guitar).asString);
        ok.("...a tile per device, and none for a plugin that is not there", ~effectsTiles.size == m.devices.size,
            ~effectsTiles.size.asString);
        ok.("...named after it, and on, as it came in", (~effectsTiles[\delay2][\select].states[0][0] == "Dual Delay 2")
            and: { ~effectsTiles[\delay2][\select].value == 1 }, ~effectsTiles[\delay2][\select].states[0][0]);
        m.setParam(\delay2, \delayTimeR, 0.2);
        m.setFxParam(\delayTimeR, 0.9);
        ~effectsSelect.(\delay2);
        tick.();
        p = MegaSAFx.param(\delayTimeR);
        w = ~effectsWidgets[\delayTimeR];
        ok.("its editor shows its own settings, not the first Delay's", (~effectsWidgets.size == MegaSAFx.paramsOf(\delay).size)
            and: { w[\readout].string == ~effectsFormat.(p, 0.2) }, w[\readout].string);
        w[\knob].valueAction_(0.3);
        tick.();
        ok.("its knob moves it, and only it", ((m.param(\delay2, \delayTimeR) - MegaSAFx.constrain(\delayTimeR, p[\spec].map(0.3))).abs < 1e-6)
            and: { (m.fxParam(\delayTimeR) - 0.9).abs < 1e-6 } and: { lastSet.(d2.node, \delayTimeR) == m.param(\delay2, \delayTimeR) },
            [m.param(\delay2, \delayTimeR), m.fxParam(\delayTimeR)].asString);
        before = w[\readout].string;
        m.setFxParam(\delayTimeR, 0.05);
        tick.();
        ok.("the first Delay's setting moved leaves the second's knobs alone", w[\readout].string == before, w[\readout].string);
        ok.("...and marks the first Delay's tile", ~effectsTiles[\delay][\select].states[0][0].contains("•"));
        ok.("its tile, its knobs and its Reset are tagged for the MIDI map, under its own id",
            ['sa.fxOn.delay2', 'sa.fx.delay2.delayTimeR', 'sa.fxReset.delay2'].every { |id|
                ~mapTags.any { |e| (e[1] == id) and: { e[0].isClosed.not } } },
            ~mapTags.collect { |e| e[1] }.select { |id| id.asString.contains("delay2") }.asString);
        // (The MIDI map is not loaded here: what the pane asks of it is.)
        ~checkAsked = List.new;
        ~midiTargetsRefresh = { |family| ~checkAsked.add(family) };
        ~effectsChainChanged.();
        ~midiTargetsRefresh = nil;
        ok.("...and a chain edit has the effects' controls, and only them, made again for the MIDI map",
            ~checkAsked.asArray == [\effects], ~checkAsked.asString);
        ok.("...and the button that puts its settings back reads Reset",
            ~mapTags.detect { |e| (e[1] == 'sa.fxReset.delay2') and: { e[0].isClosed.not } } !? { |e|
                (e[0].tryPerform(\states) !? { |st| st[0][0] }) ? e[0].tryPerform(\string) } == "Reset");
        m.setParam(\delay2, \delayTimeR, 0.4);
        tick.();
        ok.("its setting moved from outside paints its knob (the device says so)", w[\readout].string == ~effectsFormat.(p, 0.4),
            w[\readout].string);
        ok.("...and marks its tile", ~effectsTiles[\delay2][\select].states[0][0].contains("•"));
        // Its type's variations are megalooper's presets for the type: a
        // further Delay has them too, and they move it alone.
        {
            var found, walk = { |v| v.children.do { |c|
                if(c.isKindOf(PopUpMenu) and: { c.items.first == "Variation…" }) { found = c };
                walk.(c) } };
            walk.(~effectsEditorHolder);
            before = m.fxParam(\delayTimeR);
            found !? { |menu| menu.valueAction_(menu.items.indexOfEqual("short")) };
            tick.();
            ok.("a further Delay has its type's variations, and one moves it alone",
                found.notNil and: { (m.param(\delay2, \delayTimeR) - 0.0843).abs < 0.001 } and: { m.fxParam(\delayTimeR) == before },
                [m.param(\delay2, \delayTimeR), m.fxParam(\delayTimeR)].asString);
        }.value;
        m.resetFx(\delay2);
        tick.();
        ok.("Live values puts it back", m.fxEdited(\delay2).not and: { m.fxEdited(\delay) }
            and: { w[\readout].string == ~effectsFormat.(p, p[\spec].default) }, w[\readout].string);
        m.renameDevice(\delay2, "Slap");
        tick.();
        ok.("a rename names its tile", ~effectsTiles[\delay2][\select].states[0][0] == "Slap",
            ~effectsTiles[\delay2][\select].states[0][0]);
        m.moveDevice(\delay2, \loop, 1);
        tick.();
        ok.("a move to the other chain takes its tile out of one row and into the other",
            rowKeys.(\guitar).includes(\delay2).not and: { rowKeys.(\loop) == keysOf.(m.loopChain) },
            [rowKeys.(\guitar), rowKeys.(\loop)].asString);
        ok.("...the editor still shows it", ~effectsSelected == \delay2 and: { ~effectsWidgets[\delayTimeR].notNil });
        m.removeDevice(\delay2);
        tick.();
        ok.("a remove takes its tile away, and the editor moves to a device still there",
            ~effectsTiles[\delay2].isNil and: { m.device(~effectsSelected).notNil }, ~effectsSelected.asString);
        ok.("...no widget of the old editor is left behind", ~effectsWidgets.values.every { |x| x[\readout].isClosed.not });
        before = ~effectsWidgets.collect { |x| x[\readout].string };
        ok.("...a removed device's setting throws nothing",
            try { d2.setParam(\delayMix, 0.1); true } { |err| err.errorString.postln; false });
        tick.();
        ok.("...and paints nothing: the editor's readouts as they were, its tile still gone",
            (~effectsWidgets.collect { |x| x[\readout].string } == before) and: { ~effectsTiles[\delay2].isNil },
            ~effectsSelected.asString);
        m.undo;
        tick.();
        ok.("undo brings its tile back", rowKeys.(\loop) == keysOf.(m.loopChain), rowKeys.(\loop).asString);
        // Edits in a burst rebuild the rows once.
        ~effectsBuildRows = { rebuilds = rebuilds + 1; realBuild.value };
        m.insertDevice(\loop, nil, \redux);
        m.insertDevice(\loop, nil, \redux);
        m.insertDevice(\loop, nil, \redux);
        tick.();
        ~effectsBuildRows = realBuild;
        ok.("three edits in a row rebuild the rows once", rebuilds == 1, rebuilds.asString);
        ok.("...ending as the chains are", rowKeys.(\loop) == keysOf.(m.loopChain), rowKeys.(\loop).asString);
        // A long chain scrolls in its row: the pane wants no more width.
        6.do { m.insertDevice(\guitar, nil, \saturator) };
        tick.();
        ok.("a row of " ++ m.guitarChain.devices.size ++ " devices scrolls: the pane still fits 1440 px",
            ~effectsPane.minSizeHint.width <= 1440, ~effectsPane.minSizeHint.width.asString);
        if(noPlugin.not) {
            ~effectsSelect.(\bias);
            tick.();
            m.removeDevice(\plugin1);
            tick.();
            ok.("a removed plugin's tile goes as any effect's does: the guitar row is its effects, with no tile left reading none",
                (rowKeys.(\guitar) == keysOf.(m.guitarChain)) and: { rowKeys.(\guitar).includes(\bias).not }
                    and: { ~effectsTiles[\bias].isNil } and: { ~effectsBiasTileStatus.isNil },
                rowKeys.(\guitar).asString);
            ok.("...and the editor moves from its page to a device still there",
                (~effectsSelected != \bias) and: { m.device(~effectsSelected).notNil }, ~effectsSelected.asString);
            ok.("...+ still ends the row, to add one again", ~effectsPlusTiles[\guitar].notNil
                and: { ~effectsRowHolders[\guitar].canvas.children.includes(~effectsPlusTiles[\guitar]) });
            m.undo;
            tick.();
            ok.("...undo brings the plugin's tile back as it was, where it was",
                (rowKeys.(\guitar) == keysOf.(m.guitarChain)) and: { rowKeys.(\guitar).includes(\bias) }
                and: { ~effectsBiasTileStatus.notNil } and: { ~effectsBiasTileStatus.sub.beginsWith("failed") },
                (~effectsBiasTileStatus !? { |t| t.sub }).asString);
            // Open, but held off for its latency: the tile and the line say
            // so, and why, on the plugin's own \latency.
            ~effectsSelect.(\bias);
            tick.();
            m.guitarPlugin.put(\state, \open).put(\held, "it adds 10.7 ms of latency");
            m.guitarPlugin.changed(\latency, 512);
            tick.();
            ok.("a plugin held off for its latency: its tile says held, its line why",
                ~effectsBiasTileStatus.sub.beginsWith("held") and: { ~effectsBiasStatus.string.contains("10.7 ms") },
                [~effectsBiasTileStatus.sub, ~effectsBiasStatus.string].asString);
            m.guitarPlugin.put(\state, \failed).put(\held, nil);
            m.guitarPlugin.changed(\state, \failed);
            tick.();
        };
        // At most as many as undo keeps: one refused shows as a failure.
        (MegaSA.undoMax + 1).do { if(m.canUndo) { m.undo } };
        tick.();
        ok.("every edit undone, the rows are the default chains again", (rowKeys.(\guitar) == keysOf.(m.guitarChain))
            and: { m.guitarChain.ids.keep(4) == MegaSAFx.guitarKeys }
            and: { m.canUndo.not }, rowKeys.(\guitar).asString);
        m.setFxParam(\delayTimeR, p[\spec].default);
        // A default device's Live values is a MIDI target, its tip kept up
        // to date with what it is bound to; a further device's is not.
        ~effectsSelect.(\delay);
        tick.();
        ok.("a default device's Live values is tagged for the MIDI map, with its tip",
            ~mapTags.any { |e| (e[1] == 'sa.fxReset.delay') and: { e[0].isClosed.not }
                and: { e[0].toolTip.contains("starting value") } });
        // A further device left in a chain for the teardown, its controller on.
        d2 = m.insertDevice(\loop, nil, \delay);
        tick.();
        ok.("(a further device in a chain has the pane's controller)", d2.dependants.notNil and: { d2.dependants.notEmpty });
    }.value;

    "== Start with this, its mark, and a recovery ==".postln;
    {
        var label = { ~effectsKeepButton.states[0][0] }, target;
        m.markKept;
        m.setFxParam(\delayMix, 0.111);
        0.5.wait;
        m.markKept;
        tick.();
        ok.("Keep's mark goes when the chains are kept, whoever kept them", label.() == "Start with this", label.());
        m.setFxParam(\delayMix, MegaSAFx.param(\delayMix)[\spec].default);
        m.markKept;
        ~effectsPaintKeep.();
        ok.("with the chains as kept, Start with this has no mark", label.() == "Start with this", label.());
        m.setFxParam(\delayMix, 0.123);
        0.5.wait;
        ok.("a setting moved marks it, a moment later", label.() == "Start with this •", label.());
        m.setFx(\delay, m.fx(\delay).not);
        m.setFxParam(\delayMix, MegaSAFx.param(\delayMix)[\spec].default);
        0.5.wait;
        ok.("moved back, with a footswitch pressed meanwhile, the mark goes", label.() == "Start with this", label.());
        m.setFxParam(\delayMix, 0.123);
        0.5.wait;
        ~effectsKeepButton.action.value(~effectsKeepButton);
        tick.();
        ok.("Start with this writes the kept sound, under the scratch root", ~saKeptPath.().beginsWith(PathName.tmp)
            and: { MegaSASound.read(~saKeptPath.()) !? { |x| x.isString.not and: { x.device(\delay)[\settings][\delayMix] == 0.123 } } },
            ~saKeptPath.());
        ok.("...clears its mark, and says so", (label.() == "Start with this") and: { fam[\statusText].string.contains("Kept") },
            [label.(), fam[\statusText].string].asString);
        ok.("with nothing to recover, Recover is not shown", ~effectsRecoverShown == false);
        target = MegaSASound.parse(m.sound("recovery").fileString);
        target.track(\loop).put(\devices, target.devices(\loop).reverse);
        ~saRecovery = target;
        ~effectsPaintKeep.();
        ok.("a boot's offer shows it", ~effectsRecoverShown == true);
        ~effectsRecoverButton.action.value(~effectsRecoverButton);
        tick.();
        tick.();
        ok.("Recover recalls the chains offered, and is gone again",
            (m.loopChain.ids == target.devices(\loop).collect { |d| d[\id] }) and: { ~effectsRecoverShown == false }
                and: { ~saRecovery.isNil }, m.loopChain.ids.asString);
        ok.("...the rows follow", ~effectsTiles.size == (m.devices.size + m.devices.any(_.isPlugin).not.binaryValue));
    }.value;

    "== teardown, and a rig with no SA ==".postln;
    ~guiTeardowns[\effects].value;
    ok.("the controllers are gone", m.dependants.isNil or: { m.dependants.isEmpty },
        m.dependants.asString);
    ok.("...the devices' too, a further one and parked plugins included", (m.devices ++ m.limboDevices).every { |x|
        x.dependants.isNil or: { x.dependants.isEmpty } } and: { m.devices.any { |x| x.id != x.type } });
    m.setFxParam(MegaSAFx.params.first[\name], MegaSAFx.params.first[\spec].map(0.5));
    tick.();
    ok.("and a notification after it finds nothing to paint", ~effectsWidgets.isEmpty);
    ~megaSA = nil;
    pane = ~buildEffectsPane.();
    ok.("without SA the pane is a note", pane.children.any { |c|
        c.isKindOf(StaticText) and: { c.string.contains("SA profile") } });

    "== a rig with a bass ==".postln;
    {
        var stubB = ~tStubServer.(), mb, lb, paneB, d, h0, h1, items;
        // The height the pane wants without the bass's row, for the one it
        // adds (measured on m's pane, built again for it).
        ~megaSA = m;
        h0 = ~buildEffectsPane.().minSizeHint.height;
        ~guiTeardowns[\effects].value;
        mb = ~tMegaSA.(stubB, nil, nil, nil, nil, nil, 1);
        lb = ~tLooper.();
        Routine { mb.attachLooper(lb) }.next;
        ~megaSA = mb;
        ~effectsSelected = nil;
        paneB = ~buildEffectsPane.();
        tick.();
        ok.("with a bass input there is a BASS row, under the guitar's",
            (~effectsTracks.() == [\guitar, \bass, \loop, \drums]) and: { ~effectsRowHolders[\bass].notNil }
                and: { ~effectsRowHolders[\bass].isClosed.not }
                and: { ~effectsRowHolders[\bass].absoluteBounds.top > ~effectsRowHolders[\guitar].absoluteBounds.top }
                and: { ~effectsRowHolders[\bass].absoluteBounds.top < ~effectsRowHolders[\loop].absoluteBounds.top },
            ~effectsTracks.().asString);
        ok.("...ending in a + tile that adds to the bass chain", (~effectsPlusTiles ? ())[\bass].notNil
            and: { ~effectsAddItems.(\bass).any { |it| it[\section] == \builtin } });
        d = mb.insertDevice(\bass, nil, \saturator);
        tick.();
        ok.("an effect inserted there gets its tile in the bass row",
            d.notNil and: { ~effectsTiles[d.id].notNil }
                and: { ~effectsRowHolders[\bass].canvas.children.any { |v| v === ~effectsTiles[d.id][\select] } },
            (d !? { |x| x.id }).asString);
        items = ~effectsDeviceItems.(\delay).collect { |it| it[\label] };
        ok.("a guitar effect's menu offers the bass chain", items.any { |x| x == "Move to the bass chain" }, items.asString);
        h1 = paneB.minSizeHint.height;
        ("  the pane wants " ++ h1 ++ " px high with the bass's row, " ++ h0 ++ " without").postln;
        ok.("...and the pane still fits 1440 px wide", paneB.minSizeHint.width <= 1440, paneB.minSizeHint.width.asString);
        // Perform's levels, side by side: six strips now.
        {
            var levels = ~buildSAPerformLevels.(), w = levels !? { |v| v.minSizeHint.width };
            ("  Perform's levels want " ++ w ++ " px wide with the bass's strip").postln;
            ok.("Perform's levels have the bass's strip, and fit 1440 px", ~saPerformLevels[\bass].notNil
                and: { w.notNil and: { w <= 1440 } }, w.asString);
            ok.("...whose slider sets the bass's level", { ~saPerformLevels[\bass][\slider].valueAction_(~saLevelSpec.unmap(-6));
                (mb.level(\bass).ampdb - -6).abs < 1e-6 }.value, mb.level(\bass).ampdb.asString);
            ~guiTeardowns[\saPerform].value;
        }.value;
        ~guiTeardowns[\effects].value;
        ~megaSA = nil;
        mb.free;
    }.value;

    ~tRemoveTree.(tmp);
    ~tRemoveTree.(~tTrapRoot);
    "".postln;
    if(fail == 0) { ("EFFECTS PANE CHECK PASSED — " ++ pass ++ " checks").postln }
    { ("EFFECTS PANE CHECK FAILED — " ++ fail ++ " of " ++ (pass + fail)).postln;
      fails.do { |f| ("  " ++ f).postln } };
    if(fail == 0) { 0.exit } { 1.exit };
}.play(AppClock);
)
