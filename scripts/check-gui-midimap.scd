// megalooper — does the Rig pane's MIDI section build, and does it stay honest?
// Without a rig: the section is built from real Qt views, against the router
// with the TSMega's shipped map, a Looper with no server and no MIDIClient; the
// widgets and the router are driven against each other (learning included),
// and it exits 0 or 1. Messages are handed to the router's own route, so no
// MIDI responder is registered. Maps and settings go to a scratch folder,
// never to ~/Library/Application Support/SuperCollider/megalooper.
//
//   /Applications/SuperCollider.app/Contents/MacOS/sclang scripts/check-gui-midimap.scd
(
var scripts = Looper.repoRoot +/+ "scripts";
var pass = 0, fail = 0, fails = List.new, w, view, g, t = 1000.0, backSent = List.new;
var ok = { |label, cond, detail|
    if(cond == true) { pass = pass + 1; ("  ok    " ++ label).postln }
    { fail = fail + 1; fails.add(label ++ " — " ++ (detail ? ""));
      ("  FAIL  " ++ label ++ " — " ++ (detail ? "")).postln };
};
(scripts +/+ "tests" +/+ "_harness.scd").load;
["setup-routing.scd", "setup-midi.scd", "setup-sa.scd", "setup-miditargets.scd", "setup-midimap.scd",
    "gui-const.scd", "gui-theme.scd", "gui-presets.scd", "gui-granular.scd", "gui-sa.scd", "gui-midimap.scd", "gui-mapmode.scd",
    "gui-shell.scd"].do { |f|
    (scripts +/+ f).load;
};
~midiUserRootOverride = ~tTempPath.("check-gui-midimap");
~midiWriteSync = true;
~midiNow = { t };
~rigLabelWidth = 130;
~looper = ~tLooper.();
~megaSA = nil;
// Live's recorder is there (setup-model.scd, on every rig); a stub here.
~liveRecordToggle = { };
~routingProfile = \sa;
~rp = ~routingProfiles[\sa];
~midiSources = IdentityDictionary[1001 -> ["TSMEGA", "TSMEGA"], 1002 -> ["Faderfox UC4", "Faderfox UC4"]];
~midiTargets = ~midiTargetsBuild.();
~midiMap = ~midiMapLoad.("tsmega")[\map];
~midiKept = ~midiMap;
~midiMapFrom = \shipped;
~midiMapWarning = nil;
~midiUndo = List.new;
~midiListenFrom.(~midiSettingsRead.());
// The UC4 has an output, the TSMEGA none here. Sending back writes down what
// it sends, and its clock is the check's own ticks.
~midiDestinations = IdentityDictionary[2002 -> ["Faderfox UC4", "Faderfox UC4"]];
~midiBackOuts = IdentityDictionary.new;
~midiBackClock = { };
~midiBackOpen = { |uid|
    var o = ();
    [\control, \bend, \noteOn, \noteOff].do { |sel| o.put(sel, { |self ... args| backSent.add([uid, sel] ++ args); self }) };
    o
};

Routine {
    var tick = { 0.15.wait };
    var rows = { var tv = g[\list]; if(tv.numItems == 0) { [] } { (0 .. (tv.numItems - 1)).collect { |i| tv.itemAt(i).strings } } };
    var select = { |text| var i = rows.value.detectIndex { |r| r[0] == text };
        i !? { g[\list].currentItem = g[\list].itemAt(i) }; tick.(); i };
    var pc = { |num, src = 1001| ~midiRoute.(\program, 0, num, nil, src) };

    "== build ==".postln;
    view = ~buildMidiMapSection.();
    w = Window("MIDI section check", Rect(0, 0, 900, 700));
    w.layout = VLayout(view);
    g = ~midiGui;
    tick.();
    ok.("the section builds", view.notNil and: { view.isClosed.not });
    ok.("the list shows every binding of the map", g[\list].numItems == 20, g[\list].numItems.asString);
    ok.("...its rows in words", rows.value[0] == ["PC 4", "Trigger  ·  Perform", "", "", "", "TSMEGA"],
        rows.value[0].asString);
    ok.("...SA's controls greyed on a rig with no SA built (PC 8-12, 14, 15, 17), and Live's record (PC 21) on a rig without Live",
        (g[\greyed].size == 9) and: { ~midiGuiRow.(~midiGuiRows[g[\greyed].last])[1] == "live.record (this rig has no Live)" },
        g[\greyed].asString);
    ok.("...the effects' rows saying why, and a setting's row naming its device",
        { var rows = ~midiGuiRows.select { |b| b[\target].asString.beginsWith("sa.fxOn.") };
          rows.notEmpty and: { rows.every { |b| ~midiGuiRow.(b)[1].contains("(Megalooper SA is not running)") } }
              and: { ~midiGuiRow.(rows.first.copy.put(\target, 'sa.fx.delayMix'))[1].beginsWith("Dual Delay › ") } }.value,
        ~midiGuiRows.select { |b| b[\target].asString.beginsWith("sa.fx") }.collect { |b| ~midiGuiRow.(b)[1] }.asString);
    ok.("the map menu shows the shipped maps, this one chosen",
        (g[\mapMenu].items == ["keys-and-knobs", "tsmega"]) and: { g[\mapMenu].value == 1 }, g[\mapMenu].items.asString);
    ok.("the status says it is as shipped", g[\status].string.contains("as shipped"), g[\status].string);
    ok.("an input each, listened to", (g[\inputButtons] ? []).collect { |p| [p[0], p[1].value] }
        == [["Faderfox UC4", 1], ["TSMEGA", 1]], (g[\inputButtons] ? []).collect { |p| p[0] }.asString);
    ok.("Send back, for the input with an output only, off", (g[\backButtons] ? []).collect { |p| [p[0], p[1].value] }
        == [["Faderfox UC4", 0]], (g[\backButtons] ? []).collect { |p| p[0] }.asString);

    "== the editor follows the selection ==".postln;
    select.("CC 7");
    ok.("a knob's binding: its ends can be set, its hysteresis shown",
        g[\setMin].enabled and: { g[\hystMenu].enabled } and: { g[\hystMenu].value == 2 }
            and: { g[\switchMenu].enabled.not });
    select.("PC 4");
    ok.("a stomp's binding on a trigger: no ends, no switch type (a program change has no release)",
        g[\setMin].enabled.not and: { g[\switchMenu].enabled.not } and: { g[\remove].enabled });
    select.("CC 7");
    ~looper.onsetThreshold = 0.2;
    g[\setMin].valueAction = 0;
    tick.();
    ok.("Set Min takes the threshold where it is now", ~midiMap.bindingsFor('looper.onsetThreshold')[0][\min] == 0.2,
        ~midiMap.bindingsFor('looper.onsetThreshold')[0].asString);
    ok.("...and the list shows it, in the slider's own words", rows.value.detect { |r| r[0] == "CC 7" }[2] == "0.2",
        rows.value.detect { |r| r[0] == "CC 7" }.asString);
    ok.("the status says there are changes not kept", g[\status].string.contains("not kept"), g[\status].string);
    select.("PC 5");
    g[\remove].valueAction = 0;
    tick.();
    ok.("× removes the binding selected", (g[\list].numItems == 19) and: { ~midiMap.bindingsFor('looper.clear').isEmpty });
    g[\undo].valueAction = 0;
    tick.();
    ok.("Undo brings it back", g[\list].numItems == 20);
    select.("PC 4");
    g[\chan].valueAction = 2;
    tick.();
    ok.("the channel menu changes a binding's channel", ~midiMap.bindingsFor('looper.trigger')[0][\chan] == 1);
    g[\chan].valueAction = 0;
    tick.();
    ok.("...and 'any channel' takes it away", ~midiMap.bindingsFor('looper.trigger')[0][\chan].isNil);

    "== knobs: the defaults, takeover, hysteresis, input range ==".postln;
    {
        var undos = ~midiUndo.size, cc7 = { ~midiMap.bindingsFor('looper.onsetThreshold')[0] };
        var away = ~onsetThresholdSpec.map(0.9);
        // The Knobs row: the defaults for every knob mapping that names none,
        // the router's at once and kept in settings.json.
        ~midiDefaults = (hysteresis: 2, takeover: \pickup);
        ~midiGuiRefresh.();
        ok.("the Knobs row shows the defaults in force", (g[\defTake].value == 1) and: { g[\defHyst].value == 2 },
            [g[\defTake].value, g[\defHyst].value].asString);
        ~midiDefaults = ~midiKnobDefaults.copy;
        ~midiGuiRefresh.();
        ok.("...and the built-in ones again", (g[\defTake].value == 0) and: { g[\defHyst].value == 1 },
            [g[\defTake].value, g[\defHyst].value].asString);
        g[\defTake].valueAction = 1;
        g[\defHyst].valueAction = 0;
        tick.();
        ok.("the Knobs row sets the router's defaults: pick-up, no hysteresis",
            (~midiDefaults[\takeover] == \pickup) and: { ~midiDefaults[\hysteresis] == 0 },
            [~midiDefaults[\takeover], ~midiDefaults[\hysteresis]].asString);
        ok.("...and keeps them in settings.json", (~midiSettingsRead.()[\knobs][\takeover] == \pickup)
            and: { ~midiSettingsRead.()[\knobs][\hysteresis] == 0 });
        g[\defTake].valueAction = 0;
        g[\defHyst].valueAction = 1;
        tick.();
        ok.("...and back: jump to the knob, one step", (~midiDefaults[\takeover] == \none) and: { ~midiDefaults[\hysteresis] == 1 });
        select.("PC 4");
        ok.("a stomp's binding is no knob: no takeover, no hysteresis, no input range",
            g[\takeMenu].enabled.not and: { g[\hystMenu].enabled.not } and: { g[\sweep].enabled.not });
        select.("CC 7");
        ok.("the pedal's binding is a knob: its takeover, hysteresis and input range can be set",
            g[\takeMenu].enabled and: { g[\hystMenu].enabled } and: { g[\sweep].enabled }
                and: { g[\takeMenu].value == 0 } and: { g[\hystMenu].value == 2 } and: { g[\rangeText].string == "0–127" },
            [g[\takeMenu].value, g[\hystMenu].value, g[\rangeText].string].asString);
        g[\takeMenu].valueAction = 2;
        tick.();
        ok.("the takeover menu gives the binding its own: picks up", cc7.()[\takeover] == \pickup);
        ok.("...and the list says so", rows.value.detect { |r| r[0] == "CC 7" } !? { |r| r[4].contains("picks up") } ? false,
            (rows.value.detect { |r| r[0] == "CC 7" } ? []).asString);
        ~looper.onsetThreshold = away;
        [10, 12].do { |x| ~midiRoute.(\cc, 0, 7, x, 1001) };
        ok.("...and the router holds the pedal off a threshold it isn't at, the default none or not",
            (~looper.onsetThreshold - away).abs < 1e-9, ~looper.onsetThreshold.asString);
        select.("PC 4");
        ok.("...the menu shows another binding's, none of its own", g[\takeMenu].value == 0, g[\takeMenu].value.asString);
        select.("CC 7");
        ok.("...and this one's when it is selected again", g[\takeMenu].value == 2, g[\takeMenu].value.asString);
        g[\hystMenu].valueAction = 1;
        tick.();
        ok.("'no hysteresis' is a 0 of its own, not the default", cc7.()[\hysteresis] == 0, cc7.()[\hysteresis].asString);
        g[\hystMenu].valueAction = 0;
        tick.();
        ok.("'the default' takes the binding's own away", cc7.()[\hysteresis].isNil);
        // An input range, swept: the pedal heel to toe, then Done.
        g[\sweep].valueAction = 1;
        tick.();
        ok.("Sweep starts a sweep, and its button says Done", ~midiSweep.notNil and: { g[\sweep].value == 1 });
        // Another input's CC 7 is not the pedal's: the binding names the TSMEGA.
        [3, 40, 90, 126, 120].do { |x| ~midiRoute.(\cc, 0, 7, x, 1001) };
        [0, 127].do { |x| ~midiRoute.(\cc, 0, 7, x, 1002) };
        tick.();
        ok.("...the range text follows what the pedal sent, and no other input", g[\rangeText].string.contains("3–126"),
            g[\rangeText].string);
        // Its poll, five times a second, repaints the range alone: a menu the
        // player has open is left as it is.
        g[\takeMenu].value = 3;
        g[\rangeText].string_("");
        0.5.wait;
        ok.("...and its poll, five times a second, repaints the range alone: a menu open meanwhile is left as it is",
            (g[\takeMenu].value == 3) and: { g[\rangeText].string.contains("3–126") },
            [g[\takeMenu].value, g[\rangeText].string].asString);
        // From another row Done still ends it; Full is that row's, and it is
        // no knob; the text says what is swept.
        select.("PC 4");
        ok.("...and from another row, Done ends it, Full is that row's (off), and the text names what it sweeps",
            g[\sweep].enabled and: { g[\fullRange].enabled.not } and: { g[\rangeText].string.contains("CC 7") },
            [g[\sweep].enabled, g[\fullRange].enabled, g[\rangeText].string].asString);
        select.("CC 7");
        g[\sweep].valueAction = 0;
        tick.();
        ok.("Done: the binding's input range is what it sent, 3–126", (cc7.()[\inLo] == 3) and: { cc7.()[\inHi] == 126 }
            and: { ~midiSweep.isNil }, [cc7.()[\inLo], cc7.()[\inHi]].asString);
        ok.("...and the list says it", rows.value.detect { |r| r[0] == "CC 7" } !? { |r| r[4].contains("3–126") } ? false);
        g[\sweep].valueAction = 1;
        [60, 62].do { |x| ~midiRoute.(\cc, 0, 7, x, 1001) };
        g[\sweep].valueAction = 0;
        tick.();
        ok.("a sweep that hardly moved changes nothing, and says so", (cc7.()[\inLo] == 3)
            and: { g[\learnText].string.contains("Range not changed") }, g[\learnText].string);
        // A binding on one channel sweeps that channel only.
        g[\chan].valueAction = 1;
        tick.();
        g[\sweep].valueAction = 1;
        [20, 100].do { |x| ~midiRoute.(\cc, 0, 7, x, 1001) };
        [0, 127].do { |x| ~midiRoute.(\cc, 3, 7, x, 1001) };
        g[\sweep].valueAction = 0;
        tick.();
        ok.("a sweep notes its binding's channel only", (cc7.()[\inLo] == 20) and: { cc7.()[\inHi] == 100 },
            [cc7.()[\inLo], cc7.()[\inHi]].asString);
        // The binding changed while it swept: the range is not the new one's.
        g[\sweep].valueAction = 1;
        [10, 120].do { |x| ~midiRoute.(\cc, 0, 7, x, 1001) };
        g[\hystMenu].valueAction = 3;
        tick.();
        g[\sweep].valueAction = 0;
        tick.();
        ok.("a sweep whose mapping changed meanwhile changes nothing, and says so",
            (cc7.()[\inLo] == 20) and: { g[\learnText].string.contains("mapping changed") }, g[\learnText].string);
        // Left running, 20 s on it ends itself, and changes nothing.
        g[\sweep].valueAction = 1;
        [10, 120].do { |x| ~midiRoute.(\cc, 0, 7, x, 1001) };
        0.3.wait;
        t = t + 21;
        0.5.wait;
        ok.("a sweep left running ends itself 20 s on, changes nothing, and says so",
            ~midiSweep.isNil and: { cc7.()[\inLo] == 20 } and: { g[\learnText].string.contains("ended itself") }
                and: { g[\sweep].value == 0 },
            [~midiSweep.isNil, cc7.()[\inLo], g[\learnText].string, g[\sweep].value].asString);
        g[\fullRange].valueAction = 0;
        tick.();
        ok.("Full: the whole travel again", cc7.()[\inLo].isNil and: { cc7.()[\inHi].isNil });
        while { ~midiUndo.size > undos } { ~midiMapUndo.() };
        tick.();
        ok.("...and Undo takes it all back", (cc7.()[\takeover].isNil) and: { cc7.()[\hysteresis] == 1 }
            and: { cc7.()[\inLo].isNil } and: { cc7.()[\inHi].isNil } and: { cc7.()[\chan].isNil },
            [cc7.()[\takeover], cc7.()[\hysteresis], cc7.()[\inLo], cc7.()[\inHi], cc7.()[\chan]].asString);
    }.value;

    "== learning ==".postln;
    g[\pickTab].valueAction = g[\pickTab].items.indexOfEqual("Perform");
    tick.();
    g[\pickControl].value = g[\pickIds].indexOf('looper.multiply');
    g[\pickLearn].valueAction = 0;
    tick.();
    ok.("the picker arms the control picked", ~midiLearning.notNil and: { ~midiLearning[\target] == 'looper.multiply' });
    ok.("...and the section says so, with Cancel", g[\learnText].string.contains("Learning Multiply")
        and: { g[\learning] == true }, g[\learnText].string);
    pc.(30);
    t = t + 0.05;
    ~midiLearnLive.(t);
    tick.();
    ok.("a stomp learned: the list has PC 30 → Multiply", rows.value.any { |r| (r[0] == "PC 30 ch 1") and: { r[1].contains("Multiply") } },
        rows.value.collect(_.first).asString);
    ok.("...and the section says what it made", g[\learnText].string.contains("PC 30 ch 1 → Multiply"), g[\learnText].string);
    g[\pickLearn].valueAction = 0;
    pc.(4);
    t = t + 0.05;
    ~midiLearnLive.(t);
    tick.();
    ok.("learning a message Trigger has asks: Move it here, Both, Cancel",
        (g[\questionOpen] == true) and: { g[\learnText].string == "PC 4 ch 1 is Trigger's: move it to Multiply, use it for both, or cancel" },
        g[\learnText].string);
    g[\both].valueAction = 0;
    tick.();
    ok.("Both: PC 4 drives Trigger and Multiply", ~midiMap.lookup(\program, 0, 4).collect { |x| x[\binding][\target] }
        == ['looper.trigger', 'looper.multiply'], ~midiMap.lookup(\program, 0, 4).collect { |x| x[\binding][\target] }.asString);
    ok.("...and the question is gone", g[\questionOpen] == false);
    select.("PC 30 ch 1");
    g[\learn].valueAction = 0;
    tick.();
    ok.("Learn on a row arms its control", ~midiLearning !? { |l| l[\target] } == 'looper.multiply');
    g[\cancel].valueAction = 0;
    tick.();
    ok.("Cancel ends it, and nothing changed", ~midiLearning.isNil and: { g[\learnText].string == "Nothing changed" });

    "== keep, the maps, the inputs ==".postln;
    // Keep writes a new map, based on the shipped one: what the router keeps
    // of a knob goes on in it, so a pick-up pedal that holds the threshold
    // still holds it. (The pedal's binding has a Min of its own by now.)
    {
        var b = ~midiMap.bindingsFor('looper.onsetThreshold')[0], c = ~midiTargets['looper.onsetThreshold'];
        var at = { |x| LooperMidiMap.valueAt(x / 127, c[\fromPos], c[\toPos], b[\min], b[\max]) };
        ~midiDefaults = (hysteresis: 1, takeover: \pickup);
        ~looper.onsetThreshold = at.(64);
        [60, 62, 64].do { |x| ~midiRoute.(\cc, 0, 7, x, 1001) };
        g[\keep].valueAction = 0;
        tick.();
        [70, 76].do { |x| ~midiRoute.(\cc, 0, 7, x, 1001) };
        ok.("a pick-up pedal that holds the threshold still holds it after Keep",
            (~looper.onsetThreshold - at.(76)).abs < 1e-9, [~looper.onsetThreshold, at.(76)].asString);
        // ...and after choosing a map with the same mapping, and back.
        File.use(~midiMapPath.(~midiUserDir.(), "alt"), "w", { |f| f.write(~midiMap.renamed("alt").fileString) });
        ~midiGuiUseMap.("alt");
        tick.();
        [80].do { |x| ~midiRoute.(\cc, 0, 7, x, 1001) };
        ~midiGuiUseMap.("tsmega");
        tick.();
        [84].do { |x| ~midiRoute.(\cc, 0, 7, x, 1001) };
        ok.("...and after choosing a map with the same mapping, and back", (~midiMap.name == "tsmega")
            and: { (~looper.onsetThreshold - at.(84)).abs < 1e-9 }, [~midiMap.name, ~looper.onsetThreshold, at.(84)].asString);
        File.delete(~midiMapPath.(~midiUserDir.(), "alt"));
        // ...and when Reset loads it again (Reset to shipped's own load).
        ~midiGuiUseMapForce.("tsmega");
        tick.();
        [88].do { |x| ~midiRoute.(\cc, 0, 7, x, 1001) };
        ok.("...and when the map is loaded again, as Reset loads one", (~looper.onsetThreshold - at.(88)).abs < 1e-9,
            [~looper.onsetThreshold, at.(88)].asString);
        // Revert brings the pedal's binding back as kept, but not what was kept
        // of it then: its pedal moved since under the edited one, and an old
        // last position would make a crossing out of a move it never saw.
        ~midiBindingChange.(~midiMap.bindingsFor('looper.onsetThreshold')[0], (min: 0.1));
        ~looper.onsetThreshold = at.(0.7 * 127);
        [110, 115].do { |x| ~midiRoute.(\cc, 0, 7, x, 1001) };
        ~midiGuiRevert.();
        tick.();
        [101].do { |x| ~midiRoute.(\cc, 0, 7, x, 1001) };
        ok.("Revert after an edit of the pedal's own range makes no false catch",
            (~looper.onsetThreshold - at.(0.7 * 127)).abs < 1e-9, [~looper.onsetThreshold, at.(0.7 * 127)].asString);
    }.value;
    ~midiDefaults = ~midiKnobDefaults.copy;
    ok.("Keep writes the map as yours", File.exists(~midiMapPath.(~midiUserDir.(), "tsmega"))
        and: { g[\status].string.contains("yours") }, g[\status].string);
    ok.("...based on the shipped one, at its revision", (~midiMap.basedOn == "tsmega") and: { ~midiMap.revision == 1 });
    ok.("the map menu says it is yours", g[\mapMenu].items.includesEqual("tsmega (yours)"), g[\mapMenu].items.asString);
    ok.("Reset to shipped is offered now that there is one of yours", g[\reset].enabled);
    g[\reset].valueAction = 0;
    tick.();
    ok.("Reset asks first", (~midiGuiArm == \reset) and: { File.exists(~midiMapPath.(~midiUserDir.(), "tsmega")) });
    g[\reset].valueAction = 0;
    tick.();
    ok.("...and on the second click the shipped map is back, yours in the backups",
        File.exists(~midiMapPath.(~midiUserDir.(), "tsmega")).not and: { ~midiMapFrom == \shipped }
            and: { ~midiBackups.("tsmega").size == 1 } and: { g[\list].numItems == 20 });
    g[\mapMenu].valueAction = g[\mapMenu].items.indexOfEqual("keys-and-knobs");
    tick.();
    ok.("choosing another map loads it, and keeps the choice for this rig",
        (~midiMap.name == "keys-and-knobs") and: { g[\list].numItems == 23 }
            and: { ~midiSettingsRead.()[\maps][\sa] == "keys-and-knobs" });
    ~midiMapEdit.(~midiMap.adding((msg: \program, num: 99, target: 'looper.stop')));
    tick.();
    g[\mapMenu].valueAction = g[\mapMenu].items.indexOfEqual("tsmega");
    tick.();
    ok.("...but not over changes not kept", (~midiMap.name == "keys-and-knobs") and: { g[\learnText].string.contains("Keep or Revert") },
        g[\learnText].string);
    g[\revert].valueAction = 0;
    g[\revert].valueAction = 0;
    tick.();
    ok.("Revert, twice: back to the map as kept", ~midiMapDirty.().not and: { g[\list].numItems == 23 });
    // The write goes in the background, as on the rig: the button must show
    // what was clicked at once, and keep showing it.
    ~midiWriteSync = false;
    g[\inputButtons].detect { |p| p[0] == "Faderfox UC4" }[1].valueAction = 0;
    ok.("an input clicked off shows off at once, while settings.json is still being written",
        g[\inputButtons].detect { |p| p[0] == "Faderfox UC4" }[1].value == 0);
    1.0.wait;
    ok.("...and still does when the write is done, and it is not listened to",
        (g[\inputButtons].detect { |p| p[0] == "Faderfox UC4" }[1].value == 0) and: { ~midiListens.(1002).not }
            and: { ~midiListens.(1001) });
    ok.("...and settings.json says so", ~midiSettingsRead.()[\listen]["Faderfox UC4"] == false);
    ~midiWriteSync = true;

    "== load from, revert, a broken map, a fresh clone ==".postln;
    ~midiGuiUseMapForce.("tsmega");
    tick.();
    g[\inputButtons].detect { |p| p[0] == "TSMEGA" }[1].valueAction = 0;
    tick.();
    ok.("with the TSMega's map, the TSMEGA switched off: the status says its footswitches are off",
        g[\status].string.contains("TSMEGA is not listened to"), g[\status].string);
    g[\inputButtons].detect { |p| p[0] == "TSMEGA" }[1].valueAction = 1;
    tick.();
    ~midiGuiLoadFile.(~midiBackups.("tsmega")[0]);
    tick.();
    ok.("a backup loaded from a file keeps this map's name", (~midiMap.name == "tsmega") and: { ~midiMapDirty.() });
    g[\revert].valueAction = 0;
    g[\revert].valueAction = 0;
    tick.();
    ok.("Revert goes back to the map as it was, in memory", ~midiMapDirty.().not and: { ~midiMap.bindings.size == 20 });
    ~midiGuiLoadFile.(~midiBackups.("tsmega")[0]);
    g[\keep].valueAction = 0;
    tick.();
    ok.("Keep of a loaded backup writes it as tsmega, and this rig's choice is tsmega",
        File.exists(~midiMapPath.(~midiUserDir.(), "tsmega")) and: { ~midiSettingsRead.()[\maps][\sa] == "tsmega" });
    // A map of yours that couldn't be read, with no backup, as the boot leaves it.
    ~midiMap = LooperMidiMap([], "tsmega");
    ~midiKept = ~midiMap;
    ~midiMapFrom = nil;
    ~midiMapWarning = "MIDI map 'tsmega' could not be read — footswitches are off · Rig tab";
    ~midiMapWarningLevel = \error;
    ~midiChanged.(\map);
    tick.();
    ok.("a map that could not be read: the menu shows it, and Reset to shipped is there",
        (g[\mapMenu].items[g[\mapMenu].value] == "tsmega (yours)") and: { g[\reset].enabled }, g[\mapMenu].items.asString);
    g[\reset].valueAction = 0;
    g[\reset].valueAction = 0;
    tick.();
    ok.("...which puts the shipped one back", (~midiMapFrom == \shipped) and: { ~midiMap.bindings.size == 20 }
        and: { ~midiMapWarning.isNil });
    // A fresh clone: standalone, no map.
    ~routingProfile = \standalone;
    ~midiMap = LooperMidiMap([], nil);
    ~midiKept = ~midiMap;
    ~midiMapFrom = nil;
    ~midiMapWarning = "No MIDI map — Rig tab › MIDI to make one";
    ~midiMapWarningLevel = \note;
    ~midiChanged.(\map);
    tick.();
    ok.("a rig with no map shows (none), and nothing to keep", (g[\mapMenu].items[g[\mapMenu].value] == "(none)")
        and: { g[\keep].enabled.not });
    ~midiLearnArm.('looper.stop', true);
    pc.(40);
    t = t + 0.05;
    ~midiLearnLive.(t);
    tick.();
    ok.("...a mapping learned there can be kept", g[\keep].enabled and: { g[\status].string.contains("1 bindings") },
        g[\status].string);
    g[\keep].valueAction = 0;
    tick.();
    ok.("...as \"mine\", the rig's map from the next boot", (~midiMap.name == "mine")
        and: { File.exists(~midiMapPath.(~midiUserDir.(), "mine")) } and: { ~midiSettingsRead.()[\maps][\standalone] == "mine" });
    ~routingProfile = \sa;
    ~midiMapWarning = nil;
    ~midiGuiUseMapForce.("keys-and-knobs");
    tick.();
    g[\inputButtons].detect { |p| p[0] == "Faderfox UC4" }[1].valueAction = 1;
    tick.();

    "== send back ==".postln;
    // The knob box's map names no input and no channel: the UC4 is sent where
    // the Arc is once its CC 11 has come from it.
    g[\backButtons][0][1].valueAction = 1;
    tick.();
    ok.("Send back switched on: the UC4 is sent back to, and settings.json says so",
        ~midiBackSrcs.includes(1002) and: { ~midiSettingsRead.()[\sendBack]["Faderfox UC4"] == true }
            and: { g[\backButtons][0][1].value == 1 });
    ~midiRoute.(\cc, 0, 11, 64, 1002);
    t = t + 1;
    ~midiBackTick.(t);
    ok.("...an encoder that moved the Arc is sent nothing back for its own move", backSent.isEmpty, backSent.asString);
    ~looper.intensity = 0.25;
    t = t + 1;
    ~midiBackTick.(t);
    ok.("...and is sent the Arc's place once the mouse moves it",
        (backSent.size == 1) and: { backSent[0].keep(4) == [2002, \control, 0, 11] }
            and: { (~midiTargets['looper.intensity'][\toPos].(0.25) - (backSent[0][4] / 127)).abs <= (0.5 / 127) },
        backSent.asString);
    g[\inputButtons].detect { |p| p[0] == "Faderfox UC4" }[1].valueAction = 0;
    tick.();
    ok.("an input not listened to is not sent back to, and its switch is greyed",
        ~midiBackSrcs.isEmpty and: { g[\backButtons][0][1].enabled.not });
    g[\inputButtons].detect { |p| p[0] == "Faderfox UC4" }[1].valueAction = 1;
    g[\backButtons][0][1].valueAction = 0;
    tick.();
    ok.("...and switched off, nothing is", ~midiBackSrcs.isEmpty and: { g[\backButtons][0][1].enabled }
        and: { ~midiSettingsRead.()[\sendBack]["Faderfox UC4"] == false });
    backSent.clear;
    g[\backButtons][0][1].valueAction = 1;
    tick.();
    t = t + 1;
    ~midiBackTick.(t);
    ok.("switched on again, it is sent where the Arc is: what it shows is not known",
        (backSent.size == 1) and: { backSent[0].keep(4) == [2002, \control, 0, 11] }, backSent.asString);
    g[\backButtons][0][1].valueAction = 0;
    tick.();

    "== tooltips and labels read the map ==".postln;
    {
        var b = ~midiTip.(Button(), 'looper.trigger', "Trigger.");
        ok.("a tooltip ends with what drives its control", b.toolTip == ("Trigger.\nMIDI: " ++ ~midiWords.('looper.trigger')),
            b.toolTip.asString);
        ~midiMapEdit.(~midiMap.removing(~midiMap.bindingsFor('looper.trigger')));
        tick.();
        ok.("...and follows the map: unbound, it says nothing of MIDI", b.toolTip == "Trigger.", b.toolTip.asString);
        ~midiMapUndo.();
        tick.();
        ok.("...and back", b.toolTip.contains("MIDI: "), b.toolTip.asString);
        b.close;
    }.value;

    // The footer's status line (gui-shell.scd) says what MIDI has to say;
    // the keys beside it stay.
    "== the footer ==".postln;
    ~keyHintText = StaticText();
    ~guiToast = nil;
    ~midiMapWarning = "MIDI map 'tsmega' could not be read — footswitches are off · Rig tab";
    ~guiHintRowRefresh.();
    ok.("a map that could not be read is said in the footer's status line", ~guiFooterShown == ~midiMapWarning,
        ~guiFooterShown.asString);
    ~guiSetTyping.(true);
    ok.("...typing in a name field comes first", ~guiFooterShown.contains("Typing"));
    ~guiSetTyping.(false);
    ok.("...and after it, the warning again", ~guiFooterShown == ~midiMapWarning);
    ~midiMapWarning = nil;
    ~guiHintRowRefresh.();
    ok.("...and with nothing wrong, the keys beside the resting line", (~keyHintText.string == ~keyHintString)
        and: { ~guiFooterShown != (~midiAttention.() !? { |a| a[0] }) }, ~guiFooterShown.asString);

    "== MIDI Map mode ==".postln;
    {
        var win, knob, button, menu, box, slider, fnKnob, deep, late, extra, sv, bar, maskOf, click, key, calls, saved, err, m, before, cmd = 1048576;
        calls = List.new;
        maskOf = { |v| ~mapMasks.detect { |e| e[\view] === v } };
        click = { |v, mods = 0| var e = maskOf.(v); e[\mask].mouseDownAction.value(e[\mask], 5, 5, mods, 0, 1); tick.() };
        key = { |char, mods, code| var r = ~guiKeyDown.(char, mods, code); tick.(); r };
        ~midiGuiUseMapForce.("tsmega");
        ~mapTags = List.new;
        ~mapFnWatched = List.new;
        ~mapFlip = false;
        bar = ~buildMapBar.();
        ~keyHintText = StaticText().string_(~keyHintString);
        knob = ~mapTag.(Knob(), 'looper.feedback');
        button = ~mapTag.(Button().states_([["Trigger"]]), 'looper.trigger', "Trigger.");
        menu = ~mapTag.(PopUpMenu().items_(["Mix", "Insert", "Gate"]), 'looper.bbcutMode');
        box = ~mapTag.(NumberBox(), 'looper.breakLoops');
        slider = ~mapTag.(Slider().enabled_(false), 'looper.onsetThreshold');
        fnKnob = ~mapTag.(Knob(), { if(~mapFlip == true) { 'looper.intensity' } { 'looper.feedback' } }, "Either.");
        deep = ~mapTag.(Knob().fixedSize_(Size(40, 40)), 'looper.granularPitch');
        sv = ScrollView().hasBorder_(false).hasHorizontalScroller_(false).fixedSize_(Size(200, 200))
            .canvas_(View().layout_(VLayout(deep, View().fixedHeight_(2000)).margins_(0)));
        win = Window("map mode check", Rect(0, 0, 700, 400));
        win.layout = VLayout(~buildMapButton.(), bar, ~keyHintText, HLayout(knob, button, menu, box, slider, fnKnob), sv);
        tick.();
        // The top bar's MIDI MAP button (gui-mapmode.scd).
        ~mapButton.valueAction = 1;
        tick.();
        ok.("the MIDI MAP button turns map mode on, and shows it", (~mapMode == true) and: { ~mapButton.value == 1 });
        ok.("a mask over every tagged view", ~mapMasks.size == 7, ~mapMasks.size.asString);
        ok.("...each its view's child, as big as it", [knob, button, menu, box, slider, fnKnob, deep].every { |v|
            maskOf.(v) !? { |e| (e[\mask].parent === v) and: { e[\mask].bounds == v.bounds.moveTo(0, 0) } } ? false });
        ok.("...saying what drives its control: Trigger PC 4, Feedback CC 4, the disabled slider CC 7",
            (maskOf.(button)[\label].string == "PC 4") and: { maskOf.(knob)[\label].string == "CC 4" }
                and: { maskOf.(slider)[\label].string == "CC 7" } and: { maskOf.(menu)[\label].string == "" },
            [button, knob, slider, menu].collect { |v| maskOf.(v)[\label].string }.asString);
        ok.("...and in its tooltip, with the control's name", maskOf.(button)[\mask].toolTip.contains("Trigger")
            and: { maskOf.(button)[\mask].toolTip.contains("PC 4") }, maskOf.(button)[\mask].toolTip);
        ok.("the hint row is the map bar, saying what to do", (~guiHintShows == \mapBar)
            and: { ~mapBar[\textNow].contains("Click a control") }, ~mapBar[\textNow].asString);
        // What the hint row tells its two views, through stand-ins that keep
        // it: `visible` can't be read back from a window never shown.
        before = [~mapBar[\view], ~keyHintText];
        ~mapBar[\view] = (isClosed: false);
        ~keyHintText = (isClosed: false);
        ~guiHintRowRefresh.();
        ok.("the map bar opens above the footer, and the keys stay", (~mapBar[\view][\visible] == true)
            and: { ~keyHintText[\string] == ~keyHintString });
        ~guiTyping = true;
        ~guiHintRowRefresh.();
        ok.("...but typing in a name field comes first: the bar shut, the footer saying so",
            (~mapBar[\view][\visible] == false) and: { ~guiFooterShown.contains("Typing") });
        ~guiTyping = false;
        ~mapBar[\view] = before[0];
        ~keyHintText = before[1];
        ~guiHintRowRefresh.();
        // The mask keeps the mouse from the control under it because each of
        // its actions answers true: Qt then hands the press, the drag, the
        // release and the wheel to nobody else (a direct call can't show the
        // knob staying put; the rig check does).
        m = maskOf.(knob)[\mask];
        ok.("a mask's press, drag, release and wheel actions all answer true",
            [m.mouseUpAction.value(m, 5, 5, 0, 0), m.mouseMoveAction.value(m, 5, 5, 0),
                m.mouseWheelAction.value(m, 5, 5, 0, 0, 0)].every { |r| r == true });
        // Its size follows its view's through the view's onResize: in a window
        // never shown Qt sends no resize, so the hook is run here.
        ok.("while map mode is on, each view's onResize carries the mask's hook",
            [knob, button, menu, box, slider, fnKnob, deep].every { |v| v.onResize.notNil });
        box.fixedSize_(Size(61, 23));
        box.bounds = Rect(0, 0, 61, 23);
        box.onResize.value(box);
        ok.("...which sizes the mask and its label to the view", (maskOf.(box)[\mask].bounds == Rect(0, 0, 61, 23))
            and: { maskOf.(box)[\label].bounds == Rect(0, 0, 61, 23) }, maskOf.(box)[\mask].bounds.asString);

        m = maskOf.(knob)[\mask];
        before = m.mouseDownAction.value(m, 5, 5, 0, 0, 1);
        tick.();
        ok.("a click on Feedback's mask arms it, and the mask keeps the press (its action answers true)",
            ((~midiLearning !? { |l| l[\target] }) == 'looper.feedback') and: { before == true });
        ok.("...its mask turns amber, and so does every view of that control", (maskOf.(knob)[\tint] == \armed)
            and: { maskOf.(fnKnob)[\tint] == \armed } and: { maskOf.(button)[\tint] == \map });
        ok.("...and the map bar says so, with its countdown and Cancel",
            (~mapBar[\textNow] == "Learning Overdub feedback: Move it · 15 s") and: { ~mapBar[\shown].includes(\cancel) },
            ~mapBar[\textNow].asString);
        ~midiRoute.(\cc, 0, 21, 10, 1001);
        t = t + 0.1;
        ~midiRoute.(\cc, 0, 21, 20, 1001);
        t = t + 0.1;
        ~midiLearnLive.(t);
        tick.();
        ok.("a knob moved: CC 21 replaces Feedback's CC 4, keeping its hysteresis",
            (~midiMap.bindingsFor('looper.feedback').collect { |b| LooperMidiMap.describe(b) } == ["CC 21 ch 1"])
                and: { ~midiMap.bindingsFor('looper.feedback')[0][\hysteresis] == 1 },
            ~midiMap.bindingsFor('looper.feedback').asString);
        ok.("...the arm ends: the mask is blue again and says CC 21, its channel in the tooltip", ~midiLearning.isNil
            and: { maskOf.(knob)[\tint] == \map } and: { maskOf.(knob)[\label].string == "CC 21" }
            and: { maskOf.(knob)[\mask].toolTip.contains("CC 21 ch 1") }, maskOf.(knob)[\label].string);
        ok.("...and the map bar says what was made", ~mapBar[\textNow].contains("CC 21 ch 1 → Overdub feedback"),
            ~mapBar[\textNow].asString);

        click.(button, 131072);
        ~midiRoute.(\program, 0, 30, nil, 1001);
        t = t + 0.05;
        ~midiLearnLive.(t);
        tick.();
        ok.("Shift-click adds: Trigger answers PC 4 and PC 30, \"PC 4 +1\" on its mask",
            (maskOf.(button)[\label].string == "PC 4 +1") and: { maskOf.(button)[\mask].toolTip.contains("PC 4, PC 30 ch 1") },
            maskOf.(button)[\label].string);
        // On a narrow control a label wider than its mask starts at its left
        // edge, so "PC 4" shows, not its middle.
        before = button.bounds;
        button.bounds = Rect(0, 0, 20, 20);
        button.onResize.value(button);
        ok.("a label wider than its mask is aligned left, so its start shows", maskOf.(button)[\align] == \left,
            maskOf.(button)[\align].asString);
        button.bounds = before;
        button.onResize.value(button);
        ok.("...and centred again when it fits", maskOf.(button)[\align] == \center, maskOf.(button)[\align].asString);
        click.(knob);
        key.(nil, 0, ~mapKeyEscape);
        ok.("Esc disarms, and map mode stays, asking nothing", ~midiLearning.isNil and: { ~mapMode == true }
            and: { ~mapLeaving == false });
        click.(button);
        key.(nil, 0, ~mapKeyBackspace);
        ok.("Delete with Trigger armed takes all its MIDI away", ~midiMap.bindingsFor('looper.trigger').isEmpty
            and: { ~midiLearning.isNil } and: { maskOf.(button)[\label].string == "" });
        key.($z, cmd, 90);
        ok.("Cmd+Z brings it back", ~midiMap.bindingsFor('looper.trigger').size == 2);

        saved = ~looper;
        ~looper = (multiply: { calls.add(\multiply) }, trigger: { calls.add(\trigger) });
        key.($m, 0, 77);
        ok.("in map mode the keys still work: M multiplies", calls.size == 1);
        key.($r, cmd, 82);
        key.($r, 262144, 82);
        ok.("a letter with Cmd or Ctrl held is no shortcut: Cmd+R and Ctrl+R don't trigger", calls.size == 1,
            calls.asString);
        key.($m, cmd, 77);
        ~looper = saved;
        ok.("Cmd+M doesn't multiply", calls.size == 1);
        ok.("...it leaves, asking first, as there are changes not kept: Keep, Discard, Later",
            (~mapLeaving == true) and: { ~mapMode == true } and: { ~mapBar[\shown] == [\keepLeave, \discard, \later] },
            ~mapBar[\shown].asString);
        key.(nil, 0, ~mapKeyEscape);
        ok.("Esc on the question stays in map mode", (~mapLeaving == false) and: { ~mapMode == true });
        m = ~mapMasks.collect { |e| e[\mask] };
        ~mapBar[\done].valueAction = 0;
        tick.();
        ~mapBar[\later].valueAction = 0;
        tick.();
        ok.("Done, then Later: map mode is off, the changes stay, not kept", (~mapMode == false) and: { ~midiMapDirty.() }
            and: { ~mapButton.value == 0 } and: { g[\status].string.contains("not kept") }, g[\status].string);
        ok.("...no mask is left, and no resize hook", m.every(_.isClosed) and: { ~mapMasks.isEmpty }
            and: { [knob, button, menu, box, slider, fnKnob, deep].every { |v| v.onResize.isNil } });
        ok.("...and the hint row is the keys again", (~guiHintShows == \text) and: { ~keyHintText.string == ~keyHintString });
        before = ~midiMap;
        key.($z, cmd, 90);
        ok.("Cmd+Z outside map mode does nothing", ~midiMap === before);

        key.($m, cmd, 77);
        ok.("Cmd+M turns it on again", ~mapMode == true);
        ~mapBar[\done].valueAction = 0;
        tick.();
        ~mapBar[\discard].valueAction = 0;
        tick.();
        ok.("Done, then Discard: back to the map as kept, map mode off", (~mapMode == false) and: { ~midiMapDirty.().not }
            and: { ~midiMap.bindingsFor('looper.feedback').collect { |b| b[\num] } == [4] });
        ~midiMapUndo.();
        tick.();
        ok.("...and Undo brings the changes back", ~midiMapDirty.() and: { ~midiMap.bindingsFor('looper.trigger').size == 2 });
        ~mapModeOn.();
        tick.();
        // Keep that can't be written: map mode stays, and the bar says why.
        saved = ~midiMapKeep;
        ~midiMapKeep = { |map, action| action.value(false, "the disk is full") };
        ~mapBar[\done].valueAction = 0;
        tick.();
        ~mapBar[\keepLeave].valueAction = 0;
        tick.();
        ~midiMapKeep = saved;
        ok.("Done, then a Keep that can't be written: map mode stays, and the bar says why",
            (~mapMode == true) and: { ~mapLeaving == false } and: { ~mapBar[\textNow].contains("Not kept: the disk is full") },
            ~mapBar[\textNow].asString);
        // A learning from the Rig tab's list, while the question to leave is
        // open: the player is mapping, not leaving.
        ~mapModeLeave.();
        tick.();
        ~midiLearnArm.('looper.stop');
        tick.();
        ok.("a learning started from the Rig tab's list drops the question to leave",
            (~mapLeaving == false) and: { ~mapBar[\textNow].beginsWith("Learning Stop") } and: { ~mapBar[\shown] == [\cancel, \delete] },
            ~mapBar[\textNow].asString);
        ~midiLearnDisarm.("Nothing changed");
        tick.();
        tick.();
        ~mapBar[\done].valueAction = 0;
        tick.();
        // On the rig the write answers later, from the shell: until then the
        // question is answered, and a second Keep, Esc or Done does nothing.
        saved = ~midiMapKeep;
        calls = List.new;
        ~midiMapKeep = { |map, action| calls.add(map); AppClock.sched(0.6, { saved.(map, action); nil }) };
        ~mapBar[\keepLeave].valueAction = 0;
        tick.();
        ok.("Keep, written in the background: the bar says so, with no buttons", (~mapKeeping == true)
            and: { ~mapBar[\textNow].beginsWith("Keeping") } and: { ~mapBar[\shown] == [] }, ~mapBar[\textNow].asString);
        ~mapBar[\keepLeave].valueAction = 0;
        key.(nil, 0, ~mapKeyEscape);
        ~mapModeLeave.();
        ok.("...a second Keep, Esc or Done meanwhile does nothing", (calls.size == 1) and: { ~mapMode == true }
            and: { ~mapKeeping == true }, calls.size.asString);
        0.8.wait;
        ~midiMapKeep = saved;
        ok.("Done, then Keep: kept as yours, map mode off", (~mapMode == false) and: { ~midiMapDirty.().not }
            and: { File.exists(~midiMapPath.(~midiUserDir.(), "tsmega")) } and: { ~midiMapFrom == \yours });

        ~mapModeOn.();
        tick.();
        late = ~mapTag.(Knob(), 'looper.intensity');
        win.layout.add(late);
        tick.();
        ok.("a view tagged while map mode is on gets its mask", maskOf.(late).notNil);
        // Every list here is pruned with reject, which answers an Array, and a
        // full Array's add is lost: after a prune, views tagged by the dozen
        // (an Effects editor, the trims) must all keep their tag, their
        // tooltip's watch and their mask.
        ~mapLiveTags.();
        ~midiWatchRefresh.();
        ~mapRelabel.();
        ~mapRepaint.();
        extra = 40.collect { ~mapTag.(Knob(), 'looper.intensity', "Extra.") };
        tick.();
        ok.("after a prune, 40 views tagged keep their tags, their tooltips' watches and their masks",
            extra.every { |v| ~mapTags.any { |t| t[0] === v } } and: { extra.every { |v| ~midiWatched.any { |w| w[0] === v } } }
                and: { extra.every { |v| maskOf.(v).notNil } },
            [extra.count { |v| ~mapTags.any { |t| t[0] === v } }, extra.count { |v| maskOf.(v).notNil }].asString);
        extra.do(_.close);
        ok.("a tag that is a function says what drives the control it answers now",
            (maskOf.(fnKnob)[\label].string == "CC 21") and: { fnKnob.toolTip == "Either.\nMIDI: CC 21 ch 1" },
            fnKnob.toolTip.asString);
        ~mapFlip = true;
        ~mapRelabel.();
        ok.("...and, told it answers another one, says that one's", (maskOf.(fnKnob)[\label].string == "")
            and: { fnKnob.toolTip == "Either." }, fnKnob.toolTip.asString);
        before = [sv.visibleOrigin.y, deep.value];
        maskOf.(deep)[\mask].mouseWheelAction.value(maskOf.(deep)[\mask], 5, 5, 0, 0, -15);
        ok.("the wheel over a mask scrolls the pane, and leaves the knob alone",
            (sv.visibleOrigin.y == (before[0] + 60)) and: { deep.value == before[1] }, sv.visibleOrigin.asString);
        click.(knob);
        ~mapBackgroundClick.();
        ok.("a click elsewhere disarms", ~midiLearning.isNil and: { ~mapMode == true });

        // MIDI arrives on CoreMIDI's thread, where no view may be touched: a
        // program learned from a SystemClock routine (canCallOS false) must
        // reach the masks only through the deferred repaint.
        click.(button);
        SystemClock.sched(0, {
            try { ~midiRoute.(\program, 0, 41, nil, 1001); ~midiLearnLive.(t + 0.05) } { |e| err = e.errorString };
            nil
        });
        0.5.wait;
        t = t + 0.05;
        ok.("a program learned on the MIDI thread: nothing threw, and the mask and the list say PC 41",
            err.isNil and: { maskOf.(button)[\label].string == "PC 41" }
                and: { rows.value.any { |r| r[0] == "PC 41 ch 1" } }, err.asString);

        // gui-mapmode.scd loaded again while map mode is on (the IDE): it
        // leaves first, so no mask stays behind, and the header's bar is kept.
        m = ~mapMasks.collect { |e| e[\mask] };
        (scripts +/+ "gui-mapmode.scd").load;
        ok.("loading gui-mapmode.scd again in map mode leaves it first: no mask stays", (~mapMode == false)
            and: { m.notEmpty } and: { m.every(_.isClosed) } and: { ~mapBar[\view].notNil });
        ~mapModeOn.();
        tick.();
        ok.("...and map mode comes back, with its bar", (~mapMode == true) and: { ~guiHintShows == \mapBar }
            and: { maskOf.(knob).notNil });
        // Cmd-period clears AppClock and then runs its objects: the hook's
        // deferred call is what leaves (calling CmdPeriod.run here would stop
        // this check's own routine).
        ok.("in map mode a Cmd-period hook is registered", CmdPeriod.objects.includes(~mapCmdPeriod));
        m = ~mapCmdPeriod;
        click.(knob);
        m.value;
        tick.();
        ok.("Cmd-period leaves map mode, ending the learning, and its hook goes", (~mapMode == false)
            and: { ~midiLearning.isNil } and: { ~mapMasks.isEmpty } and: { CmdPeriod.objects.includes(m).not });
        ~mapModeOn.();
        tick.();
        click.(knob);
        ~guiTeardowns[\mapmode].value;
        ~guiTeardowns[\midimap].value;
        tick.();
        ok.("closing the window while armed ends map mode and the learning", (~mapMode == false) and: { ~midiLearning.isNil }
            and: { ~mapMasks.isEmpty });
        ~midiRoute.(\cc, 0, 21, 100, 1001);
        ok.("...and a later CC drives its control again", (~looper.feedback - (100 / 127)).abs < 0.001,
            ~looper.feedback.asString);
        win.close;
        g = ~midiGui;
    }.value;

    "== teardown ==".postln;
    ~midiLearnArm.('looper.stop');
    ~guiTeardowns[\midimap].value;
    ok.("closing the window ends a learning", ~midiLearning.isNil);
    w.close;
    ~tRemoveTree.(~midiUserRootOverride);
    "".postln;
    if(fail == 0) { ("MIDI SECTION CHECK PASSED — " ++ pass ++ " checks").postln }
    { ("MIDI SECTION CHECK FAILED — " ++ fail ++ " of " ++ (pass + fail)).postln;
      fails.do { |f| ("  " ++ f).postln } };
    if(fail == 0) { 0.exit } { 1.exit };
}.play(AppClock);
)
