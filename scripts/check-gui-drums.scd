// megalooper — does the Drums pane build, and does it stay honest? Without a
// rig: the pane is built from real Qt views against a REAL MegaSADrums on the
// test harness's recording stub server (no build: prUseBusses), its kits read
// from presets/sa/drums/kits/ through a reader standing in for Buffer.read,
// and a stub MegaSA (an Event) holding the drums and their two mixer strips.
// The widgets and the model are driven against each other, the step lanes
// through their own mouse handlers at known coordinates (a pane that is never
// shown has no other way in: it never paints), and it exits 0 or 1. It needs
// no server and no audio device. It opens one window, transparent, for a
// moment: to measure that eight tabs leave the window 620 pt wide.
// check-gui.scd covers the same pane on the SA rig itself, painted.
//
//   /Applications/SuperCollider.app/Contents/MacOS/sclang scripts/check-gui-drums.scd
//
// Nothing here is written to the real preset folders. Its scratch folder is
// named for this process (its pid) and the time it started: UniqueID counts
// from the same number in every sclang, so two runs at once would share a
// folder named with it alone, and the first to finish would delete it.
(
var scripts = Looper.repoRoot +/+ "scripts";
var kitDir = Looper.repoRoot +/+ "presets" +/+ "sa" +/+ "drums" +/+ "kits";
var tmp = PathName.tmp +/+ ("megalooper-gui-drums-" ++ thisProcess.pid ++ "-" ++ Date.getDate.stamp);
var stub, d, m, levels, mutes, sent = List.new, now = 1000.0;
var pane, fam, w, h, pass = 0, fail = 0, fails = List.new;
var ok = { |label, cond, detail|
    if(cond == true) { pass = pass + 1; ("  ok    " ++ label).postln }
    { fail = fail + 1; fails.add(label ++ " — " ++ (detail ? ""));
      ("  FAIL  " ++ label ++ " — " ++ (detail ? "")).postln };
};
// A section that throws is one failure, not a hang: headless, an uncaught
// error leaves sclang idling with nothing printed.
var section = { |label, f|
    ("== " ++ label ++ " ==").postln;
    try { f.value } { |err| ok.(label ++ ": ran to the end", false, err.errorString) };
};
// Buffer.read, answering at once with a stand-in: the kits load \ready from
// their real files' headers, and nothing reaches a server.
var reader = { |srv, path, done|
    done.((bufnum: 100, path: path, numChannels: 2, sampleRate: 48000, numFrames: 48000)) };
var isNote = { |view| view.children.any { |c| c.isKindOf(StaticText) and: { c.string.contains("SA profile") } } };
var findButton = { |view, label|
    var found;
    var walk = { |v| v.children.do { |c|
        if((c.isKindOf(Button) or: { c.isKindOf(LooperTile) }) and: { c.states.notNil }
            and: { c.states.first.first == label }) { found = c };
        walk.(c) } };
    walk.(view);
    found
};
var tick = { 0.15.wait };
// The pump as its routine runs it, every 10 ms of wall time up to `to`.
var run = { |to| while { now < (to - 1e-9) } { now = (now + 0.01).min(to); d.pump(now) } };
// A colour read back through Qt's palette comes back in 8 bits.
var near = { |a, b| a.notNil and: { [a.red - b.red, a.green - b.green, a.blue - b.blue].every { |x| x.abs < 0.01 } } };

(scripts +/+ "tests" +/+ "_harness.scd").load;   // ~tStubServer
["setup-routing.scd", "setup-midi.scd", "setup-sa.scd", "gui-const.scd", "gui-theme.scd", "gui-presets.scd",
    "gui-analysis.scd", "gui-sa.scd", "gui-drums.scd", "gui-shell.scd"].do { |f| (scripts +/+ f).load };
~rp = (sa: true);
~saDrumsPresetDir = tmp;
File.mkdir(tmp);
// The reader below stands in for the kits' audio, which a clone does not
// have: the pane must not hide itself for that. "no kits on this Mac" has
// the real question back.
~drumsKitsHereReal = ~drumsKitsHere;
~drumsKitsHere = { true };
// The shell would set these when it builds the window.
~guiPaneOrder = ~guiPaneOrderFor.(true);
~guiStack = nil;
~looper = nil;
w = ~drumsCellWidth;
h = ~drumsLaneHeight;

stub = ~tStubServer.();
d = MegaSADrums((server: stub));
d.prUseBusses;
d.wallClock = { now };
d.sender = { |t, msgs| sent.add([t, msgs]) };
d.randSeed = 11;
d.kitDir = kitDir;
d.kitReader = reader;
d.setKit(\steps, 'carbon-layer');
d.setKit(\onset, 'one-hit');
// MegaSA as the Drums tab sees it: its drums, and the levels and mutes of its
// strips, the drums' two among them, notifying as MegaSA does.
levels = (guitar: 1, loop: 1, master: 1, drums: 0.2951209, onsetKit: 0.164059);
mutes = (guitar: false, loop: false, drums: false, onsetKit: false);
m = (drums: d, levels: levels, mutes: mutes);
m[\level] = { |self, key| levels[key] };
m[\setLevel] = { |self, key, amp| levels.put(key, amp.max(0)); self.changed(\level, key, levels[key]) };
m[\mute] = { |self, key| mutes[key] };
m[\setMute] = { |self, key, flag| mutes.put(key, flag == true); self.changed(\mute, key, mutes[key]) };
~megaSA = m;

Routine {
    section.("build", {
        ~drumsPattern = \main;
        ~drumsPage = \chance;
        pane = ~buildDrumsPane.();
        tick.();
        ok.("the pane builds", pane.notNil and: { pane.isClosed.not });
        ok.("the kits load ready from their files", (d.kitState(\steps) == \ready) and: { d.kitState(\onset) == \ready },
            [d.kitState(\steps), d.kitState(\onset)].asString
                ++ " (no kit audio here? python3 tools/export-live-set.py kits)");
        ok.("four step lanes, sixteen cells wide and a lane high, although never shown", (~drumsLanes.size == 4)
            and: { ~drumsLanes.every { |v| (v.bounds.width == (~drumsCellWidth * 16))
                and: { v.bounds.height == ~drumsLaneHeight } } },
            ~drumsLanes.collect { |v| v.bounds }.asString);
        ok.("a widget for every pattern setting", ~drumsParamNames.every { |n| ~drumsWidgets[n].notNil });
        ok.("a label, Note, Alt, L, Lock, D and M on every lane", (0..3).every { |lane|
            [\label, \note, \altNote, \len, \lock, \delay, \mute].every { |k|
                ~drumsWidgets[~drumsLaneKey.(k, lane)].notNil } });
        ok.("the lanes are named from the steps kit", ~drumsWidgets[\label0][\view].string == d.padName(\steps, 42),
            ~drumsWidgets[\label0][\view].string);
        ok.("the note menus list pads 36..51, named from the kit",
            (~drumsWidgets[\note0][\view].items.size == 16)
                and: { ~drumsWidgets[\note0][\view].items[6] == ("42 " ++ d.padName(\steps, 42) ++ " · F#1") }
                and: { ~drumsWidgets[\note0][\view].items[0].beginsWith("36 ") }
                and: { ~drumsWidgets[\note0][\view].items[0].endsWith(" · C1") },
            ~drumsWidgets[\note0][\view].items[6]);
        ok.("Note and Alt show the lanes' pads", (~drumsWidgets[\note0][\view].value == (42 - 36))
            and: { ~drumsWidgets[\altNote1][\view].value == (50 - 36) });
        ok.("the kit menus show the kits asked for", (~drumsWidgets[\kit_steps][\view].items[~drumsWidgets[\kit_steps][\view].value]
            == "Kit-Carbon + layer") and: {
            ~drumsWidgets[\kit_onset][\view].items[~drumsWidgets[\kit_onset][\view].value] == "One Hit Kit" });
        ok.("their lines say ready", ~drumsWidgets[\kitLine_steps][\view].string.beginsWith("ready")
            and: { ~drumsWidgets[\kitLine_onset][\view].string.beginsWith("ready") },
            ~drumsWidgets[\kitLine_steps][\view].string);
        ok.("the onset line names the pad the onset notes play",
            ~drumsWidgets[\kitLine_onset][\view].string.contains(d.padName(\onset, 36)),
            ~drumsWidgets[\kitLine_onset][\view].string);
        ok.("Kit-Carbon offers Beat Repeat, lit as the drums have it", ~drumsWidgets[\repeats][\view].enabled
            and: { ~drumsWidgets[\repeats][\view].value == (d.repeats == true).binaryValue },
            [d.repeats, ~drumsWidgets[\repeats][\view].value].asString);
        ok.("Main and Chance are the tiles selected", (~drumsTiles[\main].states[0][2] == ~gt[\ink])
            and: { ~drumsTiles[\chance].states[0][2] == ~gt[\ink] }
            and: { ~drumsTiles[\break].states[0][2] == ~gt[\bg] });
        ok.("nothing is marked edited", ~drumsTiles.every { |b| b.states[0][0].contains("•").not });
        ok.("a layer trim for the KJ stand-ins", ~drumsWidgets[~drumsGroupKey.(\layer)].notNil);
        ok.("none for Kit-Carbon, the main group", ~drumsWidgets[~drumsGroupKey.(\carbon)].isNil);
        ok.("a trim for every pad the lanes play", [36, 37, 38, 40, 41, 42, 44, 50].every { |n|
            ~drumsWidgets[~drumsTrimKey.(\steps, n)].notNil });
        ok.("and none for a pad nothing plays", ~drumsWidgets[~drumsTrimKey.(\steps, 39)].isNil);
        ok.("the onset pad's trim", ~drumsWidgets[~drumsTrimKey.(\onset, 36)].notNil);
        ok.("rows for the drums' two strips", ~drumsLevels[\drums].notNil and: { ~drumsLevels[\onsetKit].notNil });
        ok.("their sliders show the levels", (~drumsLevels[\drums][\slider].value
            - ~saLevelSpec.unmap(levels[\drums].ampdb)).abs < 1e-3);
        ok.("the timing is the Main pattern's", ~drumsWidgets[\timingTitle][\view].string.contains("Main"));
        ok.("the clock menu shows its Clock Speed", ~drumsWidgets[\clockSpeed][\view].value == 3);
        ok.("the reverb shows the set's 15.08 %", ~drumsWidgets[\reverbMix][\readout].string == "15.1 %",
            ~drumsWidgets[\reverbMix][\readout].string);
        // Never built (no server), the drums' reverb is \none: dry.
        ok.("but these drums are not built, so the Reverb row is greyed",
            ~drumsWidgets[\reverbMix][\view].enabled.not
                and: { near.(~drumsWidgets[\reverbMix][\readout].stringColor, ~gt[\mute]) }
                and: { near.(~drumsWidgets[\reverbMix][\view].background, ~gt[\line]) },
            [d.reverbState, ~drumsWidgets[\reverbMix][\view].enabled].asString);
        ok.("the Offset row is not", ~drumsWidgets[\offsetMs][\view].enabled
            and: { near.(~drumsWidgets[\offsetMs][\view].background, ~gt[\line]).not });
        ok.("and the line under it says why, in red", (~drumsWidgets[\reverbState][\view].string
            == "dry: the drums are not built (see the post window)")
                and: { near.(~drumsWidgets[\reverbState][\view].stringColor, ~gt[\rec]) },
            ~drumsWidgets[\reverbState][\view].string);
    });

    section.("the arithmetic", {
        // In cells of ~drumsCellWidth px.
        ok.("x 0 is step 0, a hair short of a cell too, a cell step 1", (~drumsStepAt.(0) == 0)
            and: { ~drumsStepAt.(~drumsCellWidth - 0.1) == 0 } and: { ~drumsStepAt.(~drumsCellWidth) == 1 });
        ok.("the last pixel is step 15", ~drumsStepAt.((~drumsCellWidth * 16) - 1) == 15);
        ok.("past either end, the end's step", (~drumsStepAt.(-5) == 0)
            and: { ~drumsStepAt.((~drumsCellWidth * 16) + 120) == 15 });
        ok.("the top seventh is 6", (~drumsValueAt.(0, 48) == 6) and: { ~drumsValueAt.(6, 48) == 6 }
            and: { ~drumsValueAt.(7, 48) == 5 });
        ok.("half way is 3, the bottom 0", (~drumsValueAt.(24, 48) == 3) and: { ~drumsValueAt.(47, 48) == 0 });
        ok.("above and below the strip, 6 and 0", (~drumsValueAt.(-10, 48) == 6) and: { ~drumsValueAt.(90, 48) == 0 });
        ok.("a playhead column wraps on the page's length", (~drumsColumnAt.(13, 16) == 13)
            and: { ~drumsColumnAt.(13, 12) == 1 } and: { ~drumsColumnAt.(-3, 16) == 13 });
        ok.("a choice reads as its label", ~drumsFormat.(MegaSASteps.paramSpec(\clockSpeed), 3) == "100 %");
        ok.("a dial in its units, a centred one signed",
            (~drumsFormat.(MegaSASteps.paramSpec(\shuffle1), 29.3825111) == "29.4 %")
                and: { ~drumsFormat.(MegaSASteps.paramSpec(\shuffle8), 29.7032642) == "+29.7 %" }
                and: { ~drumsFormat.(MegaSASteps.paramSpec(\shuffle2), -39.5962143) == "-39.6 %" });
        ok.("a switch On or Off", (~drumsFormat.(MegaSASteps.paramSpec(\autoRetrigger), true) == "On")
            and: { ~drumsFormat.(MegaSASteps.paramSpec(\autoRetrigger), false) == "Off" });
        ok.("a tooltip is ours alone: the original device's help text is Ableton's, not quoted",
            ~drumsTip.("Ours.", \mute) == "Ours.");
        ok.("...nor on any lane setting", ~drumsWidgets[\lock0][\view].toolTip.contains("\"").not,
            ~drumsWidgets[\lock0][\view].toolTip);
        { var walk, words = List.new, said;
          walk = { |v|
              v.toolTip !? { |t| words.add(t) };
              if(v.respondsTo(\states) and: { v.states.notNil }) { v.states.do { |st| words.add(st[0].asString) } };
              if(v.respondsTo(\items) and: { v.items.notNil }) { words.addAll(v.items) };
              if(v.isKindOf(StaticText)) { words.add(v.string ? "") };
              v.children.do { |c| walk.(c) } };
          walk.(~guiPaneHolders[\drums] ?? { pane });
          said = words.select { |w| ["Rhythmic Steps", "Beat Repeat", "BEAT REPEAT"].any { |n| w.contains(n) } };
          ok.("no Ableton device name on the pane: it says Step sequencer and Repeats", said.isEmpty and: { words.size > 50 },
              said.asArray.asString) }.value;
    });

    section.("the step lanes, by mouse", {
        var lane0 = ~drumsLanes[0], breakBefore = d.patterns[\break].deepCopy;
        var veloBefore = d.patterns[\main][\steps][\velo].deepCopy, refreshes, snap;
        var row = { 16.collect { |i| d.step(\main, \chance, 0, i) } };
        var chance0, live, y1, before4, before5, want;
        lane0.mouseDownAction.value(lane0, (3 * w) + 5, 1, 0, 0, 1);
        ok.("a click at the top of a step sets 6", d.step(\main, \chance, 0, 3) == 6, d.step(\main, \chance, 0, 3).asString);
        lane0.mouseMoveAction.value(lane0, (4 * w) + 5, h - 1, 0);
        ok.("dragging to the bottom of the next sets it to 0", d.step(\main, \chance, 0, 4) == 0);
        lane0.mouseMoveAction.value(lane0, (5 * w) + 5, h / 2, 0);
        ok.("half way up is 3", d.step(\main, \chance, 0, 5) == 3);
        (6..9).do { |i| lane0.mouseMoveAction.value(lane0, (i * w) + 15, 3, 0) };
        ok.("a drag across paints the run", (6..9).every { |i| d.step(\main, \chance, 0, i) == 6 });
        lane0.mouseMoveAction.value(lane0, (16 * w) + 40, -30, 0);
        ok.("dragged out past the end and above, the last step is 6", d.step(\main, \chance, 0, 15) == 6);
        lane0.mouseDownAction.value(lane0, (3 * w) + 5, 1, 0, 0, 2);
        ok.("a double-click puts the Live set's value back",
            d.step(\main, \chance, 0, 3) == d.liveStep(\main, \chance, 0, 3));
        tick.();
        ok.("the edit marks the Main tile and the Chance page", ~drumsTiles[\main].states[0][0].contains("•")
            and: { ~drumsTiles[\chance].states[0][0].contains("•") });
        ok.("but not a page it did not touch", ~drumsTiles[\velo].states[0][0].contains("•").not);
        ok.("nothing else moved", (d.patterns[\break] == breakBefore)
            and: { d.patterns[\main][\steps][\velo] == veloBefore });

        // Qt sends a drag about once a display frame: a quick swipe arrives
        // as events 60 px apart and more, two cells and more.
        "-- a quick swipe".postln;
        chance0 = row.();
        d.setSteps(\main, \chance, 0, 0 ! 16);
        // Written for 30 px cells, scaled to the pane's.
        lane0.mouseDownAction.value(lane0, 5 * (~drumsCellWidth / 30), 1, 0, 0, 1);
        [65, 125, 245].do { |x| lane0.mouseMoveAction.value(lane0, x * (~drumsCellWidth / 30), 1, 0) };
        ok.("a quick swipe paints every step it crossed", row.().keep(9) == (6 ! 9), row.().asString);
        ok.("and none past the pointer", row.().drop(9) == (0 ! 7), row.().asString);
        d.setSteps(\main, \chance, 0, 0 ! 16);
        // From the middle of step 0 to the middle of step 6: the steps
        // between are read at even heights, whatever the cells' width.
        lane0.mouseDownAction.value(lane0, 0.5 * w, h - 1, 0, 0, 1);
        lane0.mouseMoveAction.value(lane0, 6.5 * w, 1, 0);
        ok.("one jump up a diagonal paints the ramp it crossed", row.().keep(7) == [0, 1, 2, 3, 4, 5, 6],
            row.().asString);
        d.setSteps(\main, \chance, 0, 0 ! 16);
        lane0.mouseDownAction.value(lane0, (14 * w) + 15, 1, 0, 0, 1);
        lane0.mouseMoveAction.value(lane0, (2 * w) + 15, 1, 0);
        ok.("and right to left", (row.().copyRange(2, 14) == (6 ! 13)) and: { row.()[1] == 0 }
            and: { row.()[15] == 0 }, row.().asString);

        "-- a double-click, then a tremor".postln;
        live = d.liveStep(\main, \chance, 0, 3);
        // A height whose value is not the Live set's, over a lane holding
        // neither, so whatever a move paints shows.
        y1 = if(live == 6) { h - 1 } { 1 };
        d.setSteps(\main, \chance, 0, (if(~drumsValueAt.(y1, h) == 6) { 0 } { 3 }) ! 16);
        lane0.mouseDownAction.value(lane0, (3 * w) + 5, y1, 0, 0, 1);
        lane0.mouseDownAction.value(lane0, (3 * w) + 5, y1, 0, 0, 2);
        ok.("a double-click on step 3 puts its Live value back", d.step(\main, \chance, 0, 3) == live);
        lane0.mouseMoveAction.value(lane0, (3 * w) + 6, y1 + 1, 0);
        ok.("a 1 px move before the release keeps it", d.step(\main, \chance, 0, 3) == live,
            [live, d.step(\main, \chance, 0, 3)].asString);
        before4 = d.step(\main, \chance, 0, 4);
        before5 = d.step(\main, \chance, 0, 5);
        lane0.mouseMoveAction.value(lane0, (5 * w) + 5, y1, 0);
        ok.("so does a drag after it: the lane waits for the next press",
            (d.step(\main, \chance, 0, 3) == live) and: { d.step(\main, \chance, 0, 4) == before4 }
                and: { d.step(\main, \chance, 0, 5) == before5 }, row.().asString);
        want = if(before5 == 6) { 0 } { 6 };
        lane0.mouseDownAction.value(lane0, (5 * w) + 5, if(want == 6) { 1 } { h - 1 }, 0, 0, 1);
        ok.("which paints again", d.step(\main, \chance, 0, 5) == want);
        d.setSteps(\main, \chance, 0, chance0);
        tick.();

        "-- repaints".postln;
        refreshes = ~drumsLaneRefreshes ? 0;
        // A value the step does not have.
        want = if(d.step(\main, \chance, 0, 10) == 6) { 0 } { 6 };
        lane0.mouseDownAction.value(lane0, (10 * w) + 5, if(want == 6) { 1 } { h - 1 }, 0, 0, 1);
        tick.();
        ok.("an edited step repaints its lane", (~drumsLaneRefreshes ? 0) == (refreshes + 1),
            ((~drumsLaneRefreshes ? 0) - refreshes).asString);
        refreshes = ~drumsLaneRefreshes;
        lane0.mouseMoveAction.value(lane0, (10 * w) + 6, if(want == 6) { 2 } { h - 2 }, 0);
        tick.();
        ok.("dragging over the same value repaints nothing", ~drumsLaneRefreshes == refreshes);
        d.setStep(\main, \velo, 2, 0, 1);
        d.setStep(\break, \chance, 2, 0, 1);
        tick.();
        ok.("a step of a page or a pattern not shown repaints no lane", ~drumsLaneRefreshes == refreshes,
            (~drumsLaneRefreshes - refreshes).asString);
        snap = d.patterns.deepCopy;
        ~drumsShowPage.(\velo);
        tick.();
        ok.("a page switch repaints the four lanes", ~drumsLaneRefreshes >= (refreshes + 4));
        ok.("and changes nothing in the model", d.patterns == snap);
        ok.("its tile is selected, its hint shown", (~drumsTiles[\velo].states[0][2] == ~gt[\ink])
            and: { ~drumsWidgets[\pageHint][\view].string.beginsWith("Velo") });
        ok.("the edited Velo page has its dot now", ~drumsTiles[\velo].states[0][0].contains("•"));
        lane0.mouseDownAction.value(lane0, (2 * w) + 5, 1, 0, 0, 1);
        ok.("and a click sets a velocity", (d.step(\main, \velo, 0, 2) == 6)
            and: { d.step(\main, \chance, 0, 2) == snap[\main][\steps][\chance][0][2] });
        refreshes = ~drumsLaneRefreshes;
        snap = d.patterns.deepCopy;
        ~drumsShowPattern.(\break);
        tick.();
        ok.("a pattern switch repaints the lanes", ~drumsLaneRefreshes >= (refreshes + 4));
        ok.("and changes nothing in the model", d.patterns == snap);
        ok.("the timing shows the Break pattern's", ~drumsWidgets[\timingTitle][\view].string.contains("Break"));
        ok.("its tile is selected", ~drumsTiles[\break].states[0][2] == ~gt[\ink]);
        lane0.mouseDownAction.value(lane0, (1 * w) + 5, h - 2, 0, 0, 1);
        ok.("a click now edits the Break pattern", (d.step(\break, \velo, 0, 1) == 0)
            and: { d.step(\main, \velo, 0, 1) == snap[\main][\steps][\velo][0][1] });
        ~drumsShowPattern.(\main);
        ~drumsShowPage.(\chance);
        tick.();
    });

    section.("knobs: the held guard and the double-click", {
        var kw = ~drumsWidgets[\shuffle3], p = MegaSASteps.paramSpec(\shuffle3), want;
        kw[\view].valueAction_(0.25);
        tick.();
        want = MegaSASteps.constrainParam(\shuffle3, p[\spec].map(0.25));
        ok.("the knob moves the model", (d.param(\main, \shuffle3) - want).abs < 1e-6, d.param(\main, \shuffle3).asString);
        ok.("of the pattern shown only", d.param(\break, \shuffle3) == MegaSASteps.livePattern(\break)[\shuffle][2]);
        ok.("the readout follows", kw[\readout].string == ~drumsFormat.(p, want), kw[\readout].string);
        d.setParam(\main, \shuffle3, 10);
        tick.();
        ok.("the model moves the knob", (kw[\view].value - p[\spec].unmap(10)).abs < 1e-3, kw[\view].value.asString);
        ~drumsHeld = \shuffle3;
        kw[\view].value = 0.9;
        d.setParam(\main, \shuffle3, -20);
        tick.();
        ok.("a held knob is not moved by the model", kw[\view].value == 0.9, kw[\view].value.asString);
        ok.("but its readout is", kw[\readout].string == ~drumsFormat.(p, -20.0), kw[\readout].string);
        kw[\view].mouseUpAction.value(kw[\view]);
        ok.("let go, the knob shows the setting", (kw[\view].value - p[\spec].unmap(-20)).abs < 1e-3);
        ok.("and nothing is held", ~drumsHeld.isNil);
        kw[\view].mouseDownAction.value(kw[\view], 5, 5, 0, 0, 2);
        tick.();
        ok.("a double-click is the Live set's value", (d.param(\main, \shuffle3) - p[\spec].default).abs < 1e-6,
            d.param(\main, \shuffle3).asString);
        kw[\view].mouseUpAction.value(kw[\view]);
        d.setParam(\main, \shuffleLength, 4);
        tick.();
        ok.("dials past the Shuffle Length are disabled", (5..8).every { |n|
            ~drumsWidgets[("shuffle" ++ n).asSymbol][\view].enabled.not }
            and: { (1..4).every { |n| ~drumsWidgets[("shuffle" ++ n).asSymbol][\view].enabled } });
        ok.("the Global dial never is", ~drumsWidgets[\globalShuffle][\view].enabled);
        ok.("the length box shows it", ~drumsWidgets[\shuffleLength][\view].value == 4);
        ~drumsWidgets[\shuffleLength][\view].valueAction_(7);
        tick.();
        ok.("the box moves the model", d.param(\main, \shuffleLength) == 7);
        ok.("and the dials come back to it", ~drumsWidgets[\shuffle7][\view].enabled
            and: { ~drumsWidgets[\shuffle8][\view].enabled.not });
        ~drumsWidgets[\globalShuffle][\view].valueAction_(1);
        tick.();
        ok.("Global Shuffle to 100 %", d.param(\main, \globalShuffle) == 100, d.param(\main, \globalShuffle).asString);
        d.setParam(\break, \globalShuffle, 50);
        ~drumsShowPattern.(\break);
        tick.();
        ok.("the Break pattern's own timing shows with it", (~drumsWidgets[\globalShuffle][\view].value - 0.5).abs < 1e-3);
        ~drumsShowPattern.(\main);
        tick.();
        ok.("and the Main pattern's again", (~drumsWidgets[\globalShuffle][\view].value - 1).abs < 1e-3);
    });

    section.("menus, boxes and switches, both ways", {
        var nm = ~drumsWidgets[\note1][\view], am = ~drumsWidgets[\altNote2][\view];
        var cm = ~drumsWidgets[\clockSpeed][\view], rm = ~drumsWidgets[\rollRate][\view];
        var rb = ~drumsWidgets[\autoRetrigger][\view], rt = ~drumsWidgets[\autoTriggerRate][\view];
        var lb = ~drumsWidgets[\len0][\view], lk = ~drumsWidgets[\lock0][\view];
        var db = ~drumsWidgets[\delay0][\view], mb = ~drumsWidgets[\mute3][\view];
        nm.valueAction_(40 - 36);
        tick.();
        ok.("the Note menu sets the lane's pad", d.laneParam(\main, 1, \note) == 40);
        ok.("and the lane's label names it", ~drumsWidgets[\label1][\view].string == d.padName(\steps, 40),
            ~drumsWidgets[\label1][\view].string);
        d.setLaneParam(\main, 1, \note, 45);
        tick.();
        ok.("the model moves the Note menu", nm.value == (45 - 36), nm.value.asString);
        am.valueAction_(51 - 36);
        ok.("the Alt menu sets the alternative pad", d.laneParam(\main, 2, \altNote) == 51);
        d.setLaneParam(\main, 2, \altNote, 50);
        tick.();
        ok.("the model moves the Alt menu", am.value == (50 - 36));
        cm.valueAction_(0);
        ok.("the Clock menu sets Clock Speed", d.param(\main, \clockSpeed) == 0);
        d.setParam(\main, \clockSpeed, 5);
        tick.();
        ok.("the model moves it", cm.value == 5);
        rm.valueAction_(7);
        ok.("the Roll menu sets Roll Rate", d.param(\main, \rollRate) == 7);
        d.setParam(\main, \rollRate, 2);
        tick.();
        ok.("the model moves it", rm.value == 2);
        rb.valueAction_(0);
        ok.("Retrig switches Auto Retrigger off", d.param(\main, \autoRetrigger) == false);
        d.setParam(\main, \autoRetrigger, true);
        tick.();
        ok.("the model lights it again", rb.value == 1);
        rt.valueAction_(3);
        ok.("the rate menu sets Auto Trigger Rate", d.param(\main, \autoTriggerRate) == 3);
        d.setParam(\main, \autoTriggerRate, 1);
        tick.();
        ok.("the model moves it", rt.value == 1);
        lb.valueAction_(8);
        tick.();
        ok.("L sets the page's length", (d.length(\main, \chance, 0) == 8) and: { lb.value == 8 });
        ok.("other pages keep theirs", d.length(\main, \velo, 0) == 16);
        lk.valueAction_(1);
        tick.();
        ok.("Lock locks the lane", d.laneParam(\main, 0, \lock) == true);
        ok.("and L shows its Global Len", lb.value == 16, lb.value.asString);
        lb.valueAction_(12);
        tick.();
        ok.("L locked sets the Global Len", (d.laneParam(\main, 0, \globalLength) == 12)
            and: { d.length(\main, \chance, 0) == 8 });
        ok.("which every page then plays", d.effectiveLength(\main, \velo, 0) == 12);
        lk.valueAction_(0);
        tick.();
        ok.("unlocked, the page's own length is back", lb.value == 8);
        lb.mouseDownAction.value(lb, 5, 5, 0, 0, 2);
        tick.();
        ok.("a double-click on L is the Live set's 16", (d.length(\main, \chance, 0) == 16) and: { lb.value == 16 });
        db.valueAction_(20);
        ok.("D sets the lane's delay", d.laneParam(\main, 0, \delay) == 20);
        d.setLaneParam(\main, 0, \delay, 7.5);
        tick.();
        ok.("the model moves it", db.value == 7.5);
        db.mouseDownAction.value(db, 5, 5, 0, 0, 2);
        ok.("a double-click on D is the Live set's 0", d.laneParam(\main, 0, \delay) == 0);
        mb.valueAction_(1);
        tick.();
        ok.("M mutes the lane", d.laneParam(\main, 3, \mute) == true);
        ok.("and greys its label", near.(~drumsWidgets[\label3][\view].stringColor, ~gt[\mute]),
            ~drumsWidgets[\label3][\view].stringColor.asString);
        d.setLaneParam(\main, 3, \mute, false);
        tick.();
        ok.("the model unlights it", mb.value == 0);
        ~drumsShowPattern.(\break);
        tick.();
        ok.("the Break pattern's lanes show their own settings", (nm.value == (37 - 36)) and: { cm.value == 3 }
            and: { mb.value == 0 });
        ~drumsShowPattern.(\main);
        tick.();
    });

    // The device's two dice on every lane: for that lane, on the page shown.
    section.("a lane's dice", {
        var tiles = { |label| var out = List.new; var walk = { |v| v.children.do { |c|
            if(c.isKindOf(LooperTile) and: { c.states.notNil } and: { c.states[0][0] == label }) { out.add(c) }; walk.(c) } };
            walk.(pane); out };
        var lane = { |page, n| (0..15).collect { |i| d.step(\main, page, n, i) } };
        var big = tiles.("Rand"), small = tiles.("Rand ±1"), before, after, others;
        // What the dice touch here, put back at the end: the sections after
        // this one go on from the pattern as it was.
        var was = [lane.(\chance, 1), lane.(\velo, 1)];
        ~drumsPattern = \main;
        ~drumsShowPage.(\chance);
        tick.();
        ok.("every lane has its two dice: Rand ±1 and Rand", (big.size == 4) and: { small.size == 4 }, [big.size, small.size].asString);
        ok.("...which say what they do", (big.size == 4) and: { big[0].toolTip.contains("every step") }
            and: { small[0].toolTip.contains("one up") });
        if((big.size == 4) and: { small.size == 4 }) {
            thisThread.randSeed = 4711;
            before = lane.(\chance, 1);
            others = [lane.(\chance, 0), lane.(\chance, 2), lane.(\velo, 1)];
            small[1].doAction;
            tick.();
            after = lane.(\chance, 1);
            ok.("Rand ±1 moves every step of its lane by one at most, and some of them", (after != before)
                and: { (after - before).every { |x| x.abs <= 1 } } and: { after.every { |v| (0..6).includes(v) } },
                [before, after].asString);
            ok.("...on the page shown only, and no other lane", others == [lane.(\chance, 0), lane.(\chance, 2), lane.(\velo, 1)]);
            ok.("...and the lane's view shows it", (~drumsLaneValue !? { |f| f.(1, 0) } ? after[0]) == after[0]);
            before = after;
            big[1].doAction;
            tick.();
            after = lane.(\chance, 1);
            ok.("Rand gives every step of its lane a new value from 0 to 6", (after != before) and: { after.every { |v| (0..6).includes(v) } }
                and: { (after - before).any { |x| x.abs > 1 } }, [before, after].asString);
            ok.("...again on the page shown only, and no other lane", others == [lane.(\chance, 0), lane.(\chance, 2), lane.(\velo, 1)]);
            ~drumsShowPage.(\velo);
            tick.();
            before = lane.(\velo, 1);
            others = lane.(\chance, 1);
            big[1].doAction;
            tick.();
            ok.("with another page shown the dice are that page's", (lane.(\velo, 1) != before) and: { lane.(\chance, 1) == others });
            ok.("the pattern counts as edited, as after any edit by hand", d.edited(\main));
            ~drumsShowPage.(\chance);
            d.setSteps(\main, \chance, 1, was[0]);
            d.setSteps(\main, \velo, 1, was[1]);
            tick.();
        };
    });

    section.("Live pattern", {
        var live = findButton.(pane, "Reset pattern");
        ok.("there is a Live pattern button", live.notNil);
        ok.("the Main pattern is edited", d.edited(\main));
        live.doAction;
        tick.();
        ok.("Live pattern puts the pattern shown back", d.edited(\main).not);
        ok.("its tile's dot goes", ~drumsTiles[\main].states[0][0].contains("•").not);
        ok.("the other pattern keeps its edits", d.edited(\break));
        ok.("and the menus show the Live set's again", (~drumsWidgets[\clockSpeed][\view].value == 3)
            and: { ~drumsWidgets[\note1][\view].value == (37 - 36) });
        d.resetPattern(\break);
        tick.();
    });

    section.("kits", {
        var km = ~drumsWidgets[\kit_steps][\view], om = ~drumsWidgets[\kit_onset][\view], rb, repeats0;
        ok.("both kit menus offer — none —", (km.items[0] == "— none —") and: { om.items[0] == "— none —" });
        ok.("and say what it is: silent, kept so by presets and Keep",
            km.toolTip.contains("— none —: no kit") and: { om.toolTip.contains("presets and Keep keep it") },
            om.toolTip);
        km.valueAction_(km.items.indexOfEqual("Kit-Carbon"));
        tick.();
        ok.("the kit menu sets the steps kit", d.kit(\steps) == \carbon, d.kit(\steps).asString);
        ok.("which loads ready", d.kitState(\steps) == \ready);
        ok.("a pad it lacks reads (empty) in the menus", ~drumsWidgets[\altNote1][\view].items[50 - 36].contains("(empty)"),
            ~drumsWidgets[\altNote1][\view].items[50 - 36]);
        ok.("a kit of one group has no layer trim", ~drumsWidgets[~drumsGroupKey.(\layer)].isNil);
        ok.("and no trim for the pad it lacks", ~drumsWidgets[~drumsTrimKey.(\steps, 50)].isNil);
        d.setKit(\steps, 'core-808');
        tick.();
        ok.("the model moves the menu", km.items[km.value] == "808 Core Kit", km.items[km.value]);
        ok.("a kit without Beat Repeat offers none", ~drumsWidgets[\repeats][\view].enabled.not
            and: { ~drumsWidgets[\repeats][\view].states[0][0].contains("no repeats") });
        ok.("the lanes are named from it", ~drumsWidgets[\label0][\view].string == d.padName(\steps, 42),
            ~drumsWidgets[\label0][\view].string);
        km.valueAction_(0);
        tick.();
        ok.("none: the steps go silent", d.kit(\steps).isNil and: { d.kitState(\steps) == \unset });
        ok.("and the line says so", ~drumsWidgets[\kitLine_steps][\view].string.beginsWith("no kit"));
        ok.("with no kit nothing is trimmed", ~drumsWidgets.keys.every { |k|
            k.asString.beginsWith("trim_steps").not and: { k.asString.beginsWith("trimGroup").not } });
        d.setKit(\steps, \nosuchkit);
        tick.();
        ok.("a kit that is not there: missing, in red", ~drumsWidgets[\kitLine_steps][\view].string.beginsWith("missing")
            and: { near.(~drumsWidgets[\kitLine_steps][\view].stringColor, ~gt[\rec]) },
            ~drumsWidgets[\kitLine_steps][\view].string);
        ok.("and the status line says so", ~presetFamily.(\saDrums)[\statusText].string.contains("missing"),
            ~presetFamily.(\saDrums)[\statusText].string);
        d.setKit(\steps, 'carbon-layer');
        tick.();
        ok.("back: Kit-Carbon + layer, its layer trim and Beat Repeat",
            (km.items[km.value] == "Kit-Carbon + layer") and: { ~drumsWidgets[~drumsGroupKey.(\layer)].notNil }
                and: { ~drumsWidgets[\repeats][\view].enabled });
        // Lit from the model, whatever the drums start with.
        rb = ~drumsWidgets[\repeats][\view];
        repeats0 = d.repeats;
        rb.valueAction_(1);
        tick.();
        ok.("the switch turns Beat Repeat on", (d.repeats == true) and: { rb.states[rb.value][0] == "REPEATS" });
        rb.valueAction_(0);
        tick.();
        ok.("and off", (d.repeats == false) and: { rb.states[rb.value][0] == "Repeats off" });
        d.setRepeats(true);
        tick.();
        ok.("the model turns it on", rb.value == 1);
        d.setRepeats(false);
        tick.();
        ok.("and off again", rb.value == 0);
        d.setRepeats(repeats0);
        tick.();
        ok.("its tip says why it starts off: Live's recordings stuttered rarely",
            rb.toolTip.contains("12 minutes") and: { rb.toolTip.contains("starts off") }, rb.toolTip);
        om.valueAction_(om.items.indexOfEqual("808 Core Kit"));
        tick.();
        ok.("the onset menu sets the onset kit", d.kit(\onset) == 'core-808');
        ok.("its pad's trim follows the kit", ~drumsWidgets[~drumsTrimKey.(\onset, 36)].notNil
            and: { ~drumsWidgets[\kitLine_onset][\view].string.contains(d.padName(\onset, 36)) });
        d.setKit(\onset, 'one-hit');
        tick.();
        ok.("the model moves the onset menu", om.items[om.value] == "One Hit Kit");
    });

    section.("trims", {
        var lt = ~drumsWidgets[~drumsGroupKey.(\layer)], pt = ~drumsWidgets[~drumsTrimKey.(\steps, 42)];
        var ot = ~drumsWidgets[~drumsTrimKey.(\onset, 36)];
        lt[\view].valueAction_(0.5);
        tick.();
        ok.("the layer knob trims the KJ layer", d.groupTrim(\steps, \layer) == ~drumsTrimSpec.map(0.5),
            d.groupTrim(\steps, \layer).asString);
        d.setGroupTrim(\steps, \layer, -12);
        tick.();
        ok.("the model moves it", (lt[\view].value - ~drumsTrimSpec.unmap(-12)).abs < 1e-3);
        ok.("and its readout", lt[\readout].string == "-12.0", lt[\readout].string);
        pt[\view].valueAction_(1);
        tick.();
        ok.("a pad's knob trims the pad", d.padTrim(\steps, 42) == 12);
        ok.("its readout signed", pt[\readout].string == "+12.0", pt[\readout].string);
        pt[\view].mouseDownAction.value(pt[\view], 5, 5, 0, 0, 2);
        pt[\view].mouseUpAction.value(pt[\view]);
        ok.("a double-click puts it back to 0 dB", d.padTrim(\steps, 42) == 0);
        ot[\view].valueAction_(0);
        ok.("the onset pad's knob trims the onset kit's pad", d.padTrim(\onset, 36) == -24);
        d.setLaneParam(\main, 0, \note, 51);
        d.setLaneParam(\break, 0, \note, 51);
        tick.();
        ok.("a lane's new pad gets a trim", ~drumsWidgets[~drumsTrimKey.(\steps, 51)].notNil);
        ok.("one nothing plays any more loses its", ~drumsWidgets[~drumsTrimKey.(\steps, 42)].isNil);
        d.resetPattern(\main);
        d.resetPattern(\break);
        tick.();
        ok.("and it comes back with the pad", ~drumsWidgets[~drumsTrimKey.(\steps, 42)].notNil
            and: { ~drumsWidgets[~drumsTrimKey.(\steps, 51)].isNil });
        d.setGroupTrim(\steps, \layer, 0);
        d.setPadTrim(\onset, 36, 0);
    });

    section.("the on switch, the break and the tab's dot", {
        var on = ~drumsWidgets[\on][\view], brk = ~drumsWidgets[\breakActive][\view];
        ok.("on at boot, as in the set", (d.on == true) and: { on.value == 1 });
        ok.("no dot while nothing plays", ~guiPaneActive[\drums].value == false);
        d.setOn(false);
        tick.();
        ok.("PC 17 off unlights the switch", on.value == 0);
        on.valueAction_(1);
        tick.();
        ok.("the switch turns the drums on", d.on == true);
        d.setBreakPattern(true);
        tick.();
        ok.("the Break pattern in force lights BREAK", (brk.value == 1) and: { d.breakActive });
        brk.valueAction_(0);
        tick.();
        ok.("Main by hand", d.breakActive.not and: { brk.value == 0 });
        brk.valueAction_(1);
        ok.("and BREAK by hand, lit by what the drums did", d.breakActive and: { brk.value == 1 });
        d.setBreakPattern(false);
        tick.();
        ok.("Main again", brk.value == 0);
    });

    section.("the playhead", {
        var refreshes;
        d.setAnalysis((numerator: 4, denominator: 4, k: 1, bpm: 120));
        d.transportStart(now);
        tick.();
        ok.("on and playing dot the tab", ~guiPaneActive[\drums].value == true);
        d.setOn(false);
        ok.("off, no dot", ~guiPaneActive[\drums].value == false);
        d.setOn(true);
        tick.();
        run.(now + 0.2);
        ok.("the drums decide and send steps", sent.notEmpty, sent.size.asString);
        ok.("none of them late", d.dropped == 0, d.dropped.asString);
        ~drumsPollPlayhead.();
        ok.("the playhead is the shown pattern's first step", ~drumsPlayhead.notNil
            and: { ~drumsPlayhead[\which] == \main } and: { ~drumsPlayhead[\n] == 0 }, ~drumsPlayhead.asString);
        ok.("heard: drums on, and the pattern in force", ~drumsPlayheadHeard == true);
        refreshes = ~drumsLaneRefreshes;
        ~drumsPollPlayhead.();
        ok.("polled again on the same step, nothing repaints", ~drumsLaneRefreshes == refreshes);
        run.(now + 0.125);
        ~drumsPollPlayhead.();
        ok.("the next step repaints the four lanes", ~drumsLaneRefreshes == (refreshes + 4),
            (~drumsLaneRefreshes - refreshes).asString);
        ok.("one step on", ~drumsPlayhead[\n] == 1, ~drumsPlayhead.asString);
        ~drumsShowPattern.(\break);
        ok.("the Break pattern's playhead runs too, not heard", (~drumsPlayhead[\which] == \break)
            and: { ~drumsPlayheadHeard == false });
        ~drumsShowPattern.(\main);
        // A stand-in for the shell's StackLayout, on the Perform tab.
        ~guiStack = (index: 0);
        ~drumsPollPlayhead.();
        refreshes = ~drumsLaneRefreshes;
        run.(now + 0.125);
        ~drumsPollPlayhead.();
        ok.("while another tab shows, the playhead is not read", ~drumsPlayhead.isNil
            and: { ~drumsLaneRefreshes == refreshes });
        ~guiStack = (index: ~guiTabIndex.(\drums));
        ~drumsPollPlayhead.();
        ok.("back on the Drums tab, it is", ~drumsPlayhead.notNil and: { ~drumsPlayhead[\n] == 2 },
            ~drumsPlayhead.asString);
        ~guiStack = nil;
        d.transportStop(now);
        tick.();
        ok.("stopped, no playhead", ~drumsPlayhead.isNil, ~drumsPlayhead.asString);
        ok.("and no dot", ~guiPaneActive[\drums].value == false);
    });

    section.("levels, reverb and offset", {
        var lw = ~drumsLevels[\drums], rig, rv = ~drumsWidgets[\reverbMix], of = ~drumsWidgets[\offsetMs];
        var ds, rs, rl, irKits, red = ~gt[\rec];
        var at = { |slider, db| (slider.value - ~saLevelSpec.unmap(db)).abs < 1e-3 };
        var dbs = { [ds, rs].collect { |s| ~saLevelSpec.map(s.value) }.asString };
        lw[\slider].valueAction_(~saLevelSpec.unmap(-6));
        tick.();
        ok.("the slider sets the drums' level", (levels[\drums] - (-6).dbamp).abs < 1e-6, levels[\drums].ampdb.asString);
        ok.("its readout follows", lw[\readout].string == "-6.0 dB", lw[\readout].string);
        m.setLevel(\drums, (-20).dbamp);
        tick.();
        ok.("a level moved elsewhere moves the slider", (lw[\slider].value - ~saLevelSpec.unmap(-20)).abs < 1e-3);
        lw[\slider].mouseDownAction.value(lw[\slider], 10, 5, 0, 0, 1);
        ok.("a press holds that slider, not its strip", ~saLevelHeld === lw[\slider]);
        lw[\slider].value = 0.9;
        m.setLevel(\drums, (-30).dbamp);
        tick.();
        ok.("the model does not move it while the mouse holds it", lw[\slider].value == 0.9);
        ok.("though its readout does", lw[\readout].string == "-30.0 dB", lw[\readout].string);
        lw[\slider].mouseUpAction.value(lw[\slider], 10, 5, 0, 0);
        ok.("let go, it shows the level", ((lw[\slider].value - ~saLevelSpec.unmap(-30)).abs < 1e-3)
            and: { ~saLevelHeld.isNil });
        lw[\mute].valueAction_(1);
        ok.("Mute mutes the strip", mutes[\drums] == true);
        m.setMute(\drums, false);
        tick.();
        ok.("the model unmutes it", lw[\mute].value == 0);
        ~drumsLevels[\onsetKit][\slider].valueAction_(~saLevelSpec.unmap(-15.5));
        ok.("the onset kit's slider sets its strip", (levels[\onsetKit] - (-15.5).dbamp).abs < 1e-6);
        rig = ~buildSARigSection.();
        tick.();
        ok.("the Rig has the drums' strips too", [\guitar, \loop, \drums, \onsetKit, \master].every { |k|
            ~saRigLevels[k].notNil }, ~saRigLevels.keys.asArray.asString);
        ok.("in mixer order, the master last, the master with no Mute", (~saRigLevels[\master][\mute].isNil)
            and: { ~saRigLevels[\drums][\mute].notNil });
        m.setLevel(\drums, (-12).dbamp);
        tick.();
        ok.("one level, both tabs", ((~saRigLevels[\drums][\slider].value - ~saLevelSpec.unmap(-12)).abs < 1e-3)
            and: { (lw[\slider].value - ~saLevelSpec.unmap(-12)).abs < 1e-3 });

        // A drag as the mouse makes it: press, moves (each \level painted
        // while the slider is held), release.
        "-- a drag on one tab, the other tab's slider".postln;
        ds = lw[\slider];
        rs = ~saRigLevels[\drums][\slider];
        ds.mouseDownAction.value(ds, 10, 5, 0, 0, 1);
        ds.valueAction_(~saLevelSpec.unmap(-20));
        tick.();
        ok.("a drag on the Drums tab moves the Rig's slider as it goes", at.(rs, -20), dbs.());
        ds.valueAction_(~saLevelSpec.unmap(-25));
        tick.();
        ds.mouseUpAction.value(ds, 10, 5, 0, 0);
        tick.();
        ok.("let go, both tabs show where it ended", at.(ds, -25) and: { at.(rs, -25) }
            and: { ~saRigLevels[\drums][\readout].string == "-25.0 dB" }, dbs.());
        rs.mouseDownAction.value(rs, 10, 5, 0, 0, 1);
        rs.valueAction_(~saLevelSpec.unmap(-3));
        tick.();
        ok.("and a drag on the Rig moves the Drums tab's", at.(ds, -3), dbs.());
        m.setLevel(\drums, (-40).dbamp);
        tick.();
        ok.("the model moves every slider of the strip but the one under the hand",
            at.(rs, -3) and: { at.(ds, -40) }, dbs.());
        rs.mouseUpAction.value(rs, 10, 5, 0, 0);
        tick.();
        ok.("let go, that one shows the level too", at.(rs, -40) and: { ~saLevelHeld.isNil }, dbs.());
        ~saRigLevels[\loop][\slider].valueAction_(~saLevelSpec.unmap(-3));
        tick.();
        ok.("the Rig's own rows still set their strips", ((levels[\loop] - (-3).dbamp).abs < 1e-6)
            and: { ~saRigLevels[\loop][\readout].string == "-3.0 dB" });
        ~guiTeardowns[\sa].value;
        rv[\view].valueAction_(0.5);
        tick.();
        ok.("the reverb slider sets the mix", d.reverbMix == 0.5);
        ok.("its readout in %", rv[\readout].string == "50.0 %", rv[\readout].string);
        d.setReverbMix(0.25);
        tick.();
        ok.("the model moves it", (rv[\view].value - 0.25).abs < 1e-3);
        rv[\view].mouseDownAction.value(rv[\view], 5, 5, 0, 0, 2);
        rv[\view].mouseUpAction.value(rv[\view]);
        ok.("a double-click is the set's 15.08 %", d.reverbMix == 0.1508);

        // Only \ready is wet; the pane follows the drums' \reverb.
        "-- the reverb's state".postln;
        rl = ~drumsWidgets[\reverbState][\view];
        d.prReverbState(\loading);
        tick.();
        ok.("loading: the Reverb row is greyed, its line says so", rv[\view].enabled.not
            and: { rl.string == "loading the impulse responses…" } and: { near.(rl.stringColor, ~guiHintColor) },
            rl.string);
        d.prReverbState(\ready);
        tick.();
        ok.("ready: wet, the slider live and its readout in ink", rv[\view].enabled
            and: { near.(rv[\readout].stringColor, ~guiInk) } and: { rl.string.beginsWith("wet") }
            and: { near.(rl.stringColor, ~guiHintColor) }, rl.string);
        ok.("its groove dark again, as the strips' are", near.(rv[\view].background, lw[\slider].background),
            [rv[\view].background, lw[\slider].background].asString);
        ok.("and the mix still reads as it is", rv[\readout].string == "15.1 %", rv[\readout].string);
        d.prReverbState(\dry);
        tick.();
        ok.("dry once built: greyed again, its line in red", rv[\view].enabled.not
            and: { near.(rv[\readout].stringColor, ~gt[\mute]) }
            and: { near.(rv[\view].background, ~gt[\line]) } and: { rl.string.beginsWith("dry") }
            and: { near.(rl.stringColor, red) }, rl.string);
        ok.("saying why for these drums' own kits folder", rl.string == ~drumsReverbLine.(d), rl.string);
        // Which dry it is comes from the kits folder: one with no _ir/ and one
        // with an ir.json, each read through an Event standing in for the drums.
        irKits = tmp +/+ "ir-kits";
        File.mkdir(irKits);
        File.mkdir(irKits +/+ "_ir");
        File.use(irKits +/+ "_ir" +/+ "ir.json", "w", { |f|
            f.write("{\"version\": 1, \"rate\": 48000, \"files\": {\"ll\": \"_ir/ll.wav\", "
                "\"lr\": \"_ir/lr.wav\", \"rl\": \"_ir/rl.wav\", \"rr\": \"_ir/rr.wav\"}}") });
        ok.("with no impulse responses in the folder, the line says where they come from",
            ~drumsReverbLine.((reverbState: \dry, kitDir: tmp))
                == "dry: no impulse responses (python3 tools/export-live-set.py kits)",
            ~drumsReverbLine.((reverbState: \dry, kitDir: tmp)));
        ok.("with them there, that they did not load",
            ~drumsReverbLine.((reverbState: \dry, kitDir: irKits))
                == "dry: the impulse responses did not load (see the post window)",
            ~drumsReverbLine.((reverbState: \dry, kitDir: irKits)));
        File.delete(irKits +/+ "_ir" +/+ "ir.json");
        File.delete(irKits +/+ "_ir");
        File.delete(irKits);
        d.prReverbState(\none);
        tick.();
        ok.("not built again: greyed, and the line says so", rv[\view].enabled.not
            and: { rl.string == "dry: the drums are not built (see the post window)" }, rl.string);
        of[\view].valueAction_(~drumsOffsetSpec.unmap(10));
        tick.();
        ok.("the offset slider sets the offset", d.offsetMs == 10, d.offsetMs.asString);
        ok.("its readout in ms", of[\readout].string == "+10.0 ms", of[\readout].string);
        d.setOffsetMs(-5);
        tick.();
        ok.("the model moves it", (of[\view].value - ~drumsOffsetSpec.unmap(-5)).abs < 1e-3);
        of[\view].mouseDownAction.value(of[\view], 5, 5, 0, 0, 2);
        of[\view].mouseUpAction.value(of[\view]);
        ok.("a double-click is 0", d.offsetMs == 0);
    });

    section.("Keep", {
        var saved = ~saKeepDrums, kept = 0;
        fam = ~presetFamily.(\saDrums);
        ~saKeepDrums = { kept = kept + 1; true };
        ~drumsKeep.();
        ok.("Keep keeps through ~saKeepDrums, and says so", (kept == 1)
            and: { fam[\statusText].string == "Kept: the next boot starts with these drums." },
            fam[\statusText].string);
        // A slot set to — none — is kept empty: the next boot leaves it silent.
        d.setKit(\onset, nil);
        tick.();
        ~drumsKeep.();
        ok.("with a kit slot empty, Keep says it keeps it so",
            fam[\statusText].string == "Kept: the next boot starts with these drums, with no onset kit.",
            fam[\statusText].string);
        d.setKit(\steps, nil);
        tick.();
        ~drumsKeep.();
        ok.("both empty, both", fam[\statusText].string == "Kept: the next boot starts with these drums, with no kits.",
            fam[\statusText].string);
        d.setKit(\steps, 'carbon-layer');
        d.setKit(\onset, 'one-hit');
        tick.();
        ok.("Keep's tip says so too", findButton.(pane, "Start with this").toolTip.contains("— none — is kept so"),
            findButton.(pane, "Start with this").toolTip);
        ok.("as the preset menu's tip says a preset keeps it, and the bar's resting line says what Save keeps",
            fam[\statusIdle].contains("the kits and their trims") and: { fam[\menu].toolTip.contains("— none — comes back empty") },
            fam[\statusIdle]);
        ~saKeepDrums = { false };
        ~drumsKeep.();
        ok.("and says when it could not", fam[\statusText].string.contains("not kept"), fam[\statusText].string);
        ~saKeepDrums = nil;
        ~drumsKeep.();
        ok.("or when nothing keeps the drums", fam[\statusText].string.contains("no ~saKeepDrums"),
            fam[\statusText].string);
        ~saKeepDrums = saved;
    });

    section.("presets through the bar", {
        fam = ~presetFamily.(\saDrums);
        ~presetRefreshList.(\saDrums);
        ok.("an empty folder disables the menu", fam[\menu].enabled.not);
        if(d.respondsTo(\savePreset).not) {
            "  (these drums keep no presets yet: the round trip is skipped)".postln;
            ok.("with no preset methods the bar stays empty", fam[\items] == [nil]);
        } {
            d.setStep(\main, \velo, 2, 5, 1);
            d.setPadTrim(\steps, 42, 3);
            d.setReverbMix(0.3);
            fam[\nameField].string_("Gui Check");
            ~presetSave.(\saDrums);
            ok.("Save writes the preset", File.exists(tmp +/+ "gui-check.scd"));
            ok.("the menu selects it", fam[\items][fam[\menu].value] == "gui-check", fam[\menu].items.asString);
            d.resetPattern(\main);
            d.setPadTrim(\steps, 42, 0);
            d.setReverbMix(0.1508);
            tick.();
            ok.("Live pattern undoes the edit", d.step(\main, \velo, 2, 5) == d.liveStep(\main, \velo, 2, 5));
            ok.("Revert brings it back", ~presetRevert.(\saDrums).notNil and: { d.step(\main, \velo, 2, 5) == 1 },
                d.step(\main, \velo, 2, 5).asString);
            tick.();
            ok.("and the tiles show it", ~drumsTiles[\main].states[0][0].contains("•"));
            // A recall goes through the model's setters, so every widget it
            // touches repaints: a pad's trim and the reverb as well.
            ok.("the trim knob shows the recalled trim",
                ~drumsWidgets[~drumsTrimKey.(\steps, 42)][\readout].string == "+3.0",
                ~drumsWidgets[~drumsTrimKey.(\steps, 42)][\readout].string);
            ok.("the reverb shows the recalled mix", ~drumsWidgets[\reverbMix][\readout].string == "30.0 %",
                ~drumsWidgets[\reverbMix][\readout].string);
            d.setPadTrim(\steps, 42, 0);
            d.setReverbMix(0.1508);
            ~presetDelete.(\saDrums);
            ok.("Delete asks first", File.exists(tmp +/+ "gui-check.scd"));
            ~presetDelete.(\saDrums);
            ok.("and deletes on the second click", File.exists(tmp +/+ "gui-check.scd").not);
            d.resetPattern(\main);
            tick.();
        };
    });

    section.("a reload", {
        var repeats0 = d.repeats, rb;
        ok.("built, the pane listens to the drums and the MegaSA", d.dependants.notEmpty and: { m.dependants.notEmpty });
        (scripts +/+ "gui-drums.scd").load;
        ok.("a reload removes the old pane's controllers first", d.dependants.isEmpty and: { m.dependants.isEmpty },
            [d.dependants.size, m.dependants.size].asString);
        // Built with Beat Repeat the other way round from the drums' default:
        // the new button must paint the model, not a state of its own.
        d.setRepeats(repeats0.not);
        pane = ~buildDrumsPane.();
        tick.();
        ok.("and the pane builds again", pane.isClosed.not and: { ~drumsLanes.size == 4 } and: { d.dependants.notEmpty });
        ok.("showing what it showed", ~drumsTiles[\main].states[0][2] == ~gt[\ink]);
        rb = ~drumsWidgets[\repeats][\view];
        ok.("its Beat Repeat button lit from the drums' switch, either way",
            (rb.value == (d.repeats == true).binaryValue)
                and: { rb.states[rb.value][0] == (if(d.repeats) { "REPEATS" } { "Repeats off" }) },
            [d.repeats, rb.value].asString);
        d.setRepeats(repeats0);
        tick.();
        ok.("and back", rb.value == (repeats0 == true).binaryValue);
    });

    section.("teardown, and a rig with no drums", {
        ~guiTeardowns[\drums].value;
        ok.("the teardown leaves the drums no dependants", d.dependants.isEmpty, d.dependants.asString);
        ok.("nor the MegaSA", m.dependants.isEmpty, m.dependants.asString);
        d.setStep(\main, \chance, 0, 0, 5);
        m.setLevel(\drums, 0.5);
        tick.();
        ok.("and a notification after it finds nothing to paint", ~drumsWidgets.isEmpty
            and: { ~drumsLevels.isEmpty } and: { ~drumsLanes.isEmpty } and: { ~drumsLaneDrag.isEmpty });
        d.resetPattern(\main);
        ~megaSA = nil;
        pane = ~buildDrumsPane.();
        ok.("without SA the pane is a note", isNote.(pane));
        ~megaSA = (levels: levels);
        pane = ~buildDrumsPane.();
        ok.("so it is with a MegaSA that has no drums", isNote.(pane));
        ~megaSA = m;
    });

    // A clone has the kits' maps and none of their samples: the drums are
    // hidden, and say what brings them.
    section.("no kits on this Mac", {
        var dir = tmp +/+ "nokits", d2, texts, hadAudio;
        var words = { |view| var out = ""; var walk = { |v| v.children.do { |c|
            if(c.isKindOf(StaticText)) { out = out ++ c.string }; walk.(c) } }; walk.(view); out };
        File.mkdir(dir);
        File.use(dir +/+ "mine.json", "w", { |f|
            f.write("{ \"version\": 1, \"key\": \"mine\", \"name\": \"Mine\", \"pads\": { \"36\": { \"name\": \"Kick\", "
                ++ "\"choke\": 0, \"retrigger\": false, \"layers\": [ { \"file\": \"mine/k.wav\", "
                ++ "\"vel\": { \"law\": \"operator\", \"amount\": 1 } } ] } } }") });
        d2 = MegaSADrums((server: stub));
        d2.kitDir = dir;
        ~drumsKitsHere = ~drumsKitsHereReal;
        ok.("a kit whose samples are not here is no kit to play", (d2.kitKeys == [\mine]) and: { d2.kitsWithAudio.isEmpty }
            and: { ~drumsKitsHere.(d2).not }, d2.kitsWithAudio.asString);
        ~megaSA = (drums: d2, levels: levels, mutes: mutes);
        pane = ~buildDrumsPane.();
        tick.();
        texts = words.(pane);
        ok.("the pane is a note then: hidden, why, and the two ways to a kit",
            texts.contains("The drums are hidden")
                and: { texts.contains(if(MegaFiles.isMac) { "export-live-set.py kits" } { "copied here" }) }
                and: { texts.contains("docs/drums.md") } and: { texts.contains(dir) }, texts);
        // Off macOS there is no Live to export from: the note names the copy.
        protect {
            MegaFiles.platformOverride = \linux;
            ok.("off macOS the note says a Mac's kits can be copied, and names no Mac here",
                ~drumsNoKitsText.(d2).contains("copied here") and: { ~drumsNoKitsText.(d2).contains("this Mac").not }
                    and: { ~drumsNoKitsText.(d2).contains("docs/drums.md") } and: { ~drumsNoKitsText.(d2).contains(dir) },
                ~drumsNoKitsText.(d2));
            MegaFiles.platformOverride = \osx;
            ok.("on macOS it names Live's export", ~drumsNoKitsText.(d2).contains("export-live-set.py kits")
                and: { ~drumsNoKitsText.(d2).contains("this Mac") }, ~drumsNoKitsText.(d2));
        } { MegaFiles.platformOverride = nil };
        ok.("...with no lane, no kit menu and no preset bar: its one tile is the Import button",
            findButton.(pane, "Start with this").isNil and: { pane.children.select { |c| c.isKindOf(UserView) }
                .collect { |c| if(c.isKindOf(LooperTile)) { c.states.first.first } { c.class.name } } == ["Import samples…"] },
            pane.children.select { |c| c.isKindOf(UserView) }.collect { |c| c.class.name }.asString);
        // The sample arrives while megalooper runs: the next build has the drums.
        File.mkdir(dir +/+ "mine");
        File.use(dir +/+ "mine" +/+ "k.wav", "w", { |f| f.write("RIFF") });
        ok.("a sample put there counts at the next build, with the folder read again",
            ~drumsKitsHere.(d2) and: { d2.kitsWithAudio == [\mine] }, d2.kitsWithAudio.asString);
        ok.("an Event standing in for the drums is never hidden", ~drumsKitsHere.((kitKeys: [])));
        File.delete(dir +/+ "mine" +/+ "k.wav");
        File.delete(dir +/+ "mine");
        File.delete(dir +/+ "mine.json");
        File.delete(dir);
        d2.free;
        ~drumsKitsHere = { true };
        ~megaSA = m;
        pane = ~buildDrumsPane.();
        tick.();
        ok.("with kits the pane is the drums again", words.(pane).contains("The drums are hidden").not
            and: { ~drumsWidgets[\label0].notNil });
    });

    // "Import samples…": a folder of one-shots becomes a kit the Steps part
    // plays, with no restart. The dialog and the tool are stood in for first;
    // then the real tool runs once on samples made here.
    section.("importing a kit", {
        var root = tmp +/+ "imp", kits = root +/+ "drums" +/+ "kits", src = root +/+ "My Kit!";
        var wasAsk = ~drumsImportAsk, wasRunner = ~drumsImportRunner, wasPython = ~drumsImportPython;
        var d3, m3, ran = List.new, asked = 0, done, button, line, r, waited = 0, key, python;
        var words = { |view| var out = ""; var walk = { |v| v.children.do { |c|
            if(c.isKindOf(StaticText)) { out = out ++ c.string }; walk.(c) } }; walk.(view); out };
        var menuOf = { |slot| ~drumsWidgets[~drumsKitKey.(slot)][\view] };
        var tone = { |path, freq|
            var f = SoundFile.new.headerFormat_("WAV").sampleFormat_("int16").numChannels_(1).sampleRate_(48000);
            f.openWrite(path);
            f.writeData(FloatArray.fill(2400, { |i| sin(2pi * freq * i / 48000) * (1 - (i / 2400)) * 0.5 }));
            f.close;
        };
        var fakeKit = { |k, source|
            File.mkdir(kits +/+ k);
            tone.(kits +/+ k +/+ "k.wav", 60);
            File.use(kits +/+ k ++ ".json", "w", { |f|
                f.write("{ \"version\": 1, \"key\": \"" ++ k ++ "\", \"name\": \"My Kit!\", \"source\": \"" ++ source
                    ++ "\", \"pads\": { \"36\": { \"name\": \"Kick\", \"choke\": 0, \"retrigger\": false, "
                    ++ "\"layers\": [ { \"file\": \"" ++ k ++ "/k.wav\", \"vel\": { \"law\": \"operator\", \"amount\": 1 } } ] } } }") });
        };
        protect {
            File.mkdir(kits);
            File.mkdir(src);
            // ---- the rules ----
            ok.("a folder's name becomes a key the tool takes",
                [~drumsImportSlug.("My Kit!"), ~drumsImportSlug.("  808 (Clean) v2 "), ~drumsImportSlug.("---"), ~drumsImportSlug.("Übung")]
                    .every { |k| "^[a-z0-9][a-z0-9-]*$".matchRegexp(k) }
                    and: { ~drumsImportSlug.("My Kit!") == "my-kit" } and: { ~drumsImportSlug.("  808 (Clean) v2 ") == "808-clean-v2" }
                    and: { ~drumsImportSlug.("---") == "kit" },
                [~drumsImportSlug.("My Kit!"), ~drumsImportSlug.("  808 (Clean) v2 "), ~drumsImportSlug.("---"), ~drumsImportSlug.("Übung")].asString);
            r = ~drumsImportReport.("my-kit", 0, "my-kit  36  kick   Kick.wav\nmy-kit  unmapped: weird.wav\n"
                ++ "my-kit  unmapped: sub/odd one.wav\n/x/my-kit.json  (My Kit!: 1 pads, 1 files, 3 kB; 1 copied)\n");
            ok.("what the tool said is read: done, and the files it could not place",
                r[\ok] and: { r[\unmapped] == ["weird.wav", "sub/odd one.wav"] }, r.asString);
            r = ~drumsImportReport.("my-kit", 1, "kits: no sound files in ~/x\n");
            ok.("...or why it stopped, in the tool's words", r[\ok].not and: { r[\why] == "no sound files in ~/x" }, r.asString);
            ok.("...its last line when it broke, and something when it said nothing",
                (~drumsImportReport.("k", 1, "Traceback\n  File x\nValueError: bad\n")[\why] == "ValueError: bad")
                    and: { ~drumsImportReport.("k", 2, "")[\why] == "the tool said nothing (exit 2)" });
            ok.("a long list of unplaced files is cut short",
                ~drumsImportText.("K", 3, (1..6).collect { |i| "f" ++ i ++ ".wav" }).contains("f4.wav and 2 more")
                    and: { ~drumsImportText.("K", 3, []).contains("Not placed").not }
                    and: { ~drumsImportText.("K", 3, []).contains("K: 3 pads") });

            // ---- the button, with the dialog and the tool stood in for ----
            d3 = MegaSADrums((server: stub));
            d3.prUseBusses;
            d3.wallClock = { now };
            d3.sender = { |t, msgs| };
            d3.kitDir = kits;
            d3.kitReader = reader;
            m3 = m.copy;
            m3[\drums] = d3;
            ~megaSA = m3;
            ~drumsKitsHere = ~drumsKitsHereReal;
            ~drumsImportSaid = "";
            ~drumsImportAsk = { |action| asked = asked + 1; action.(src) };
            ~drumsImportRunner = { |cmd, dn| ran.add(cmd); done = dn };
            ~drumsImportPython = { "/usr/bin/python3" };
            pane = ~buildDrumsPane.();
            tick.();
            button = findButton.(pane, "Import samples…");
            ok.("with no kit here the note has the Import button, and says what it takes",
                words.(pane).contains("The drums are hidden") and: { button.notNil }
                    and: { words.(pane).contains("Import samples… below") }
                    and: { button.toolTip.contains("kick") }, words.(pane));
            button.valueAction_(0);
            tick.();
            ok.("pressing it asks for a folder and runs the tool on it, into the kits folder the drums read",
                (asked == 1) and: { ran.size == 1 } and: { ran[0].contains("export-live-set.py") }
                    and: { ran[0].contains(" kits --folder " ++ src.shellQuote ++ " --key 'my-kit' --out " ++ root.shellQuote) }
                    and: { ran[0].beginsWith("'/usr/bin/python3' ") }, ran.asString);
            ok.("while the tool runs the button is off and the line says so",
                button.enabled.not and: { words.(pane).contains("Importing My Kit! …") } and: { ~drumsImporting });
            button.valueAction_(0);
            ~drumsImport.(src);
            ok.("...and a second import does not start", ran.size == 1, ran.size.asString);
            // The tool stops: nothing changes but the line.
            done.(1, "kits: no sound files in " ++ src ++ "\n");
            tick.();
            ok.("a tool that stops says why in the line, in its own words, and the button is back",
                words.(pane).contains("Not imported: no sound files in " ++ src) and: { button.enabled }
                    and: { ~drumsImportBad } and: { ~drumsImporting.not } and: { d3.kit(\steps).isNil }, words.(pane));
            // The tool makes the kit.
            button.valueAction_(0);
            fakeKit.("my-kit", src);
            done.(0, "my-kit  36  kick   k.wav\nmy-kit  unmapped: weird.wav\n");
            tick.();
            pane = ~drumsPane;
            ok.("a kit the tool made brings the drums: the pane is the drums now, no note",
                (ran.size == 2) and: { words.(pane).contains("The drums are hidden").not } and: { ~drumsWidgets[\label0].notNil });
            ok.("...the Steps part plays it, and the onset part too, which had no kit",
                (d3.kit(\steps) == 'my-kit') and: { d3.kit(\onset) == 'my-kit' } and: { d3.kitState(\steps) == \ready },
                [d3.kit(\steps), d3.kit(\onset), d3.kitState(\steps)].asString);
            ok.("...both kit menus list it and show it", [\steps, \onset].every { |slot|
                menuOf.(slot).items.includesEqual("My Kit!") and: { menuOf.(slot).item == "My Kit!" } },
                [\steps, \onset].collect { |slot| [menuOf.(slot).items, menuOf.(slot).item] }.asString);
            line = words.(pane);
            button = findButton.(pane, "Import samples…");
            ok.("...and the line by the button, now under the kit menus, says so and names the file it could not place",
                line.contains("Imported My Kit!: 1 pad. The Steps part plays it.") and: { line.contains("Not placed: weird.wav") }
                    and: { button.notNil } and: { button.enabled } and: { ~drumsImportBad.not }, line);
            // The same folder again is the same kit; another folder of that name is not.
            ok.("the same folder again replaces its own kit; another folder of that name gets a key of its own",
                (~drumsImportKey.(d3, src) == "my-kit") and: { ~drumsImportKey.(d3, src ++ "/") == "my-kit" }
                    and: { ~drumsImportKey.(d3, root +/+ "elsewhere" +/+ "My Kit!") == "my-kit-2" },
                [~drumsImportKey.(d3, src), ~drumsImportKey.(d3, root +/+ "elsewhere" +/+ "My Kit!")].asString);
            // An onset kit chosen, or emptied by choice, stays.
            d3.setKit(\onset, nil);
            button.valueAction_(0);
            done.(0, "my-kit  36  kick   k.wav\n");
            tick.();
            ok.("an onset part emptied by choice stays empty", d3.kit(\onset).isNil and: { d3.kit(\steps) == 'my-kit' },
                d3.kit(\onset).asString);
            // A tool that says it is done and made nothing megalooper reads.
            button = findButton.(~drumsPane, "Import samples…");
            ~drumsImportAsk = { |action| action.(root +/+ "Other") };
            button.valueAction_(0);
            done.(0, "");
            tick.();
            ok.("a tool that made no kit is said too", words.(~drumsPane).contains("Not imported: the tool made no kit other")
                and: { ~drumsImportBad } and: { d3.kit(\steps) == 'my-kit' }, words.(~drumsPane));
            // No python3, and a kits folder the tool cannot write to.
            ~drumsImportPython = { nil };
            button.valueAction_(0);
            ok.("without python3 it says so and runs nothing", words.(~drumsPane).contains("python3 is not installed")
                and: { ran.size == 4 } and: { ~drumsImporting.not }, ran.size.asString);
            ~drumsImportPython = { "/usr/bin/python3" };
            d3.kitDir = tmp +/+ "nokits-elsewhere";
            ok.("a kits folder that is no drums/kits folder is refused: the tool would write elsewhere",
                ~drumsImportOut.(d3).isNil and: { ~drumsImportCommand.(d3, src, "x").isNil });
            ~drumsImport.(src);
            ok.("...and said", ~drumsImportSaid.contains("is not a drums/kits folder") and: { ran.size == 4 }, ~drumsImportSaid);
            d3.kitDir = kits;
            ok.("a cancelled dialog does nothing", { ~drumsImport.(nil); ran.size == 4 }.value);

            // ---- the real tool, once ----
            python = wasPython.value;
            if(python.isNil) { "  skip  the real tool — no python3 here".postln } {
                File.delete(kits +/+ "my-kit" +/+ "k.wav");
                File.delete(kits +/+ "my-kit");
                File.delete(kits +/+ "my-kit.json");
                d3.setKit(\steps, nil);
                d3.rescanKits;
                tone.(src +/+ "Kick 1.wav", 60);
                tone.(src +/+ "Snare.wav", 200);
                tone.(src +/+ "Hat closed.wav", 6000);
                tone.(src +/+ "weird thing.wav", 440);
                ~drumsImportPython = wasPython;
                ~drumsImportRunner = wasRunner;
                ~drumsImportAsk = { |action| action.(src) };
                done = nil;
                findButton.(~drumsPane, "Import samples…").valueAction_(0);
                while { ~drumsImporting and: { waited < 60 } } { 0.25.wait; waited = waited + 0.25 };
                tick.();
                key = 'my-kit';
                ok.("the real tool, run from the button on four samples made here, ends within a minute",
                    ~drumsImporting.not and: { ~drumsImportBad.not }, ~drumsImportSaid);
                ok.("...it wrote the kit and copied the samples into the kits folder",
                    File.exists(kits +/+ "my-kit.json") and: { File.exists(kits +/+ "my-kit" +/+ "Kick 1.wav") }
                        and: { d3.kitsWithAudio == [key] }, d3.kitsWithAudio.asString);
                ok.("...kick, snare and hat are on their pads", [36, 38, 42].every { |n| d3.kitInfo(key)[\pads].includes(n) },
                    d3.kitInfo(key)[\pads].asString);
                ok.("...the Steps part plays it", (d3.kit(\steps) == key) and: { d3.kitState(\steps) == \ready },
                    [d3.kit(\steps), d3.kitState(\steps)].asString);
                ok.("...and the line names the file it could not place",
                    ~drumsImportSaid.contains("Imported My Kit!: 3 pads") and: { ~drumsImportSaid.contains("Not placed: weird thing.wav") },
                    ~drumsImportSaid);
                ok.("...and a second import of the folder is the same kit, not a second one",
                    ~drumsImportKey.(d3, src) == "my-kit", ~drumsImportKey.(d3, src));
            };
        } {
            ~drumsImportAsk = wasAsk;
            ~drumsImportRunner = wasRunner;
            ~drumsImportPython = wasPython;
            ~drumsImporting = false;
            ~drumsImportSaid = "";
            ~drumsImportBad = false;
            d3 !? { d3.free };
            ("rm -rf " ++ root.shellQuote).unixCmdGetStdOut;
            ~drumsKitsHere = { true };
            ~megaSA = m;
            pane = ~buildDrumsPane.();
            tick.();
        };
        ok.("with the first drums back the pane is theirs, the button under the kit menus",
            ~drumsWidgets[\label0].notNil and: { findButton.(pane, "Import samples…").notNil });
    });

    // The stage window's top bar (gui-shell.scd): Megalooper SA adds the FX
    // and the Drums views, and their tabs must fit with the rest at 1440 pt.
    section.("SA's view in the top bar", {
        var views = ~guiViewOrderFor.(true), tabs, total;
        ~guiPaneOrder = ~guiPaneOrderFor.(true);
        ok.("SA's panes put Drums after Effects", ~guiPaneOrder
            == [\perform, \cutter, \grains, \effects, \drums, \analysis, \rig, \calibrate]);
        ok.("labelled Drums", ~guiPaneLabels[\drums] == "Drums");
        ok.("SA's views put FX and Drums between Sound and Setup",
            views == [\perform, \sound, \fx, \drums, \setup, \calibrate], views.asString);
        ok.("each holds one pane: the drums have a view of their own, with its whole height",
            (~guiViewPanes[\fx] == [\effects]) and: { ~guiViewPanes[\drums] == [\drums] });
        ok.("a rig without SA has neither", ~guiViewOrderFor.(false) == [\perform, \sound, \setup, \calibrate]);
        { var was = ~guiViewOrder;
          ~guiViewOrder = views;
          ok.("the Drums pane's view comes right after the Effects'",
              [~guiViewOf.(\effects), ~guiViewOf.(\drums), ~guiTabIndex.(\effects), ~guiTabIndex.(\drums)] == [\fx, \drums, 2, 3],
              [~guiViewOf.(\effects), ~guiViewOf.(\drums), ~guiTabIndex.(\effects), ~guiTabIndex.(\drums)].asString);
          ~guiViewOrder = was }.value;
        ok.("the keys: 3 the effects, 4 the drums, 5 Setup, 6 the wizard, on every rig",
            [\fx, \drums, \setup, \calibrate].collect { |v| ~guiViewNumbers[v] } == [3, 4, 5, 6]);
        ok.("each tab dots its own part", (~guiViewDots[\fx] == [[\effects, \fx]]) and: { ~guiViewDots[\drums] == [[\drums, \drum]] });
        ok.("the tabs read FX and Drums", [~guiViewLabels[\fx], ~guiViewLabels[\drums]] == ["FX", "Drums"]);
        tabs = views.reject { |v| v == \calibrate };
        // The tabs, the logo and wordmark, CPU, ◐, ?, the rig's lamp, MIDI
        // MAP, SET REC and their rules.
        total = tabs.sum { |v| ~guiTabWidth.(v) } + 190 + 80 + 52 + 52 + 104 + 150 + 200 + (tabs.size + 7);
        ok.("the tabs and the top bar's tiles fit 1440 pt", total <= 1440, total.asString);
        ok.("each tab holds its number, its name and its dots", tabs.every { |v|
            ~guiTabWidth.(v) >= ((~guiViewLabels[v].bounds(~guiTabFont.(true)).width)
                + ((~guiViewDots[v] ? []).size * 11) + 44) },
            tabs.collect { |v| ~guiTabWidth.(v) }.asString);
    });

    (tmp +/+ "*").pathMatch.do { |p| File.delete(p) };
    File.delete(tmp);
    "".postln;
    if(fail == 0) { ("DRUMS PANE CHECK PASSED — " ++ pass ++ " checks").postln }
    { ("DRUMS PANE CHECK FAILED — " ++ fail ++ " of " ++ (pass + fail)).postln;
      fails.do { |f| ("  " ++ f).postln } };
    if(fail == 0) { 0.exit } { 1.exit };
}.play(AppClock);
)
