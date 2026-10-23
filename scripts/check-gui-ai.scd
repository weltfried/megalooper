// megalooper — the window's side of AI apps (setup-remote.scd): the Setup
// view's switch lets one in and shuts it out, kept in settings.json; the
// footer's Revert shows while an AI change can be taken back, and takes it
// back. Real Qt views, a MegaSA on a stub server, no rig. The switch's
// settings.json and MegaRemote's handshake go to scratch folders, never to
// yours. It exits 0 or 1.
//
//   /Applications/SuperCollider.app/Contents/MacOS/sclang scripts/check-gui-ai.scd
(
var scripts = Looper.repoRoot +/+ "scripts";
var pass = 0, fail = 0, fails = List.new, w, section, tile, said = List.new, before, sa;
var ok = { |label, cond, detail|
    if(cond == true) { pass = pass + 1; ("  ok    " ++ label).postln }
    { fail = fail + 1; fails.add(label ++ " — " ++ (detail ? ""));
      ("  FAIL  " ++ label ++ " — " ++ (detail ? "")).postln };
};
(scripts +/+ "tests" +/+ "_harness.scd").load;
["setup-routing.scd", "setup-midi.scd", "setup-sa.scd", "setup-miditargets.scd", "setup-midimap.scd", "setup-remote.scd",
    "gui-const.scd", "gui-theme.scd", "gui-presets.scd", "gui-sa.scd", "gui-midimap.scd", "gui-mapmode.scd",
    "gui-rig.scd", "gui-shell.scd"].do { |f|
    (scripts +/+ f).load;
};
~midiUserRootOverride = ~tTempPath.("check-gui-ai");
~midiWriteSync = true;
MegaFiles.alwaysSync = true;
~rigLabelWidth = 130;
~looper = ~tLooper.();
sa = MegaSA(~tStubServer.());
sa.drums.kitReader = { |path, done| };
~megaSA = sa;
~routingProfile = \sa;
~rp = ~routingProfiles[\sa];
~megaRemote = nil;
~guiSay = { |msg, kind| said.add([msg, kind]) };

Routine {
    var tick = { 0.15.wait };
    "== the switch ==".postln;
    section = ~rigAiSection.();
    tile = ~guiAiTile = ~guiAiTileMake.();
    w = Window("AI check", Rect(0, 0, 700, 200));
    w.layout = VLayout(section, tile);
    // Shown, but see-through: a widget in a window never shown is never
    // visible, whatever it was told.
    w.alpha_(0).front;
    tick.();
    ok.("the section builds, the switch off with no settings.json saying otherwise",
        section.isClosed.not and: { ~remoteSeg[\view].value == 0 } and: { ~remoteOn.() == false });
    ~remoteApply.();
    ok.("...so nothing listens and no handshake is written",
        ~megaRemote.isNil and: { File.exists(MegaRemote.handshakePath).not });

    ~remoteSeg[\view].valueAction = 1;
    tick.();
    ok.("switched on: MegaRemote listens and writes its handshake, and the status line says so",
        ~megaRemote.notNil and: { ~megaRemote.started } and: { File.exists(MegaRemote.handshakePath) }
            and: { said.last[0].contains("may connect") });
    ok.("...kept in settings.json", ~midiSettingsRead.()[\raw]["gui"]["aiApps"] == "on",
        ~midiSettingsRead.()[\raw].asString);
    ok.("...the switch shows it", ~remoteSeg[\view].value == 1);

    "== Revert ==".postln;
    ok.("no AI change yet: Revert is hidden", tile.visible.not);
    before = sa.drums.patterns[\main].deepCopy;
    ~megaRemote.handle("{\"command\": \"set_drum_pattern\", \"args\": {\"pattern\": {\"mute\": [true]}}}");
    ~megaRemote.handle("{\"command\": \"set_drum_pattern\", \"args\": {\"pattern\": {\"mute\": [true, true]}}}");
    tick.();
    ok.("two AI changes: Revert shows, with how many", tile.visible and: { tile.states[0][0].contains("(2)") },
        tile.states[0][0]);
    tile.doAction;
    tick.();
    ok.("Revert takes the newest back", (sa.drums.patterns[\main][\mute] == [true, false, false, false])
        and: { ~megaRemote.changeCount == 1 }, sa.drums.patterns[\main][\mute].asString);
    ok.("...and shows the one left, without a count", tile.visible and: { tile.states[0][0].contains("(").not },
        tile.states[0][0]);
    tile.doAction;
    tick.();
    ok.("...then the one before: the drums as they were, and Revert hidden",
        (sa.drums.patterns[\main] == before) and: { tile.visible.not });

    "== shut out ==".postln;
    ~megaRemote.handle("{\"command\": \"set_drum_pattern\", \"args\": {\"pattern\": {\"mute\": [true]}}}");
    tick.();
    ~remoteSeg[\view].valueAction = 0;
    tick.();
    ok.("switched off: nothing listens, the handshake is gone, settings.json says off",
        ~megaRemote.isNil and: { File.exists(MegaRemote.handshakePath).not }
            and: { ~midiSettingsRead.()[\raw]["gui"]["aiApps"] == "off" });
    ok.("...and Revert goes with it (its changes stay as they are)",
        tile.visible.not and: { sa.drums.patterns[\main][\mute][0] == true });
    ~remoteRevert.();
    ok.("Revert with nothing let in does nothing", sa.drums.patterns[\main][\mute][0] == true);
    ~remoteSet.(true);
    ok.("on again: a new start, nothing to revert", ~megaRemote.notNil and: { ~megaRemote.changeCount == 0 }
        and: { ~remoteSeg[\view].value == 1 });
    ~remoteSet.(false);

    w.close;
    sa.free;
    MegaFiles.alwaysSync = false;
    ~tRemoveTree.(~midiUserRootOverride);
    ("\n" ++ pass ++ " passed, " ++ fail ++ " failed").postln;
    fails.do { |f| ("FAILED: " ++ f).postln };
    if(fail == 0) { "CHECK-GUI-AI PASSED".postln; 0.exit } { 1.exit };
}.play(AppClock);
)
