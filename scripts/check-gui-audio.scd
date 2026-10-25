// megalooper — the Rig page's AUDIO section (gui-rig.scd, docs/dev/audio-settings.md):
// on saSystem the input and output devices, the instrument's and the bass's
// inputs and the buffer, chosen as in the launcher, and Apply and restart,
// which only a change wakes and only a second click fires; on a rig of yours
// its name and device. Real Qt views against a device list of the check's
// own; the restart itself (~audioApply) is caught, never run. It exits 0 or 1.
// MEGALOOPER_SHOT=<path.png> also writes a picture of the section.
//
//   /Applications/SuperCollider.app/Contents/MacOS/sclang scripts/check-gui-audio.scd
(
var scripts = Looper.repoRoot +/+ "scripts";
var pass = 0, fail = 0, fails = List.new, w, section, said = List.new, applied = List.new, why, devs, texts;
var ok = { |label, cond, detail|
    if(cond == true) { pass = pass + 1; ("  ok    " ++ label).postln }
    { fail = fail + 1; fails.add(label ++ " — " ++ (detail ? ""));
      ("  FAIL  " ++ label ++ " — " ++ (detail ? "")).postln };
};
(scripts +/+ "tests" +/+ "_harness.scd").load;
["setup-routing.scd", "setup-midi.scd", "setup-sa.scd", "setup-miditargets.scd", "setup-midimap.scd",
    "gui-const.scd", "gui-theme.scd", "gui-presets.scd", "gui-rig.scd"].do { |f|
    (scripts +/+ f).load;
};
~rigLabelWidth = 130;
devs = (
    inputs: [(name: "MacBook Pro Microphone", channels: 1), (name: "Interface", channels: 4)],
    outputs: [(name: "MacBook Pro Speakers", channels: 2), (name: "Interface", channels: 4)],
    defaultIn: "MacBook Pro Microphone", defaultOut: "MacBook Pro Speakers");
~audioDevicesNow = { devs };
~audioApply = { |audio| applied.add(audio); why };
~guiSay = { |msg, kind| said.add([msg, kind]) };
// Every StaticText's words in a view, to find what it says.
texts = { |v| var out = List.new, walk = { |x| if(x.isKindOf(StaticText)) { out.add(x.string) }; x.children.do(walk) };
    walk.(v); out };

Routine {
    var tick = { 0.15.wait };
    var build = { |profile, audio|
        w !? { |x| x.close };
        ~routingProfile = profile;
        ~rp = if(~routingProfiles[profile][\audioSettings] == true) { ~audioProfile.(~routingProfiles[profile], audio, devs) }
            { ~routingProfiles[profile] };
        section = ~rigAudioSection.();
        w = Window("audio check", Rect(0, 0, 760, 330));
        w.layout = VLayout(section, nil);
        w.alpha_(0).front;
    };
    "== saSystem: what plays ==".postln;
    build.(\saSystem, (inDevice: "Interface", outDevice: "Interface", inChannel: 1));
    tick.();
    ok.("the menus show what plays: the interface both ways, the instrument on input 2, no bass, the device's buffer",
        [~rigInDevMenu.item, ~rigOutDevMenu.item, ~rigInstMenu.item, ~rigBassMenu.item, ~rigBufferMenu.item]
            == ["Interface  ·  4 in", "Interface  ·  4 out", "Input 2", "None", "the device's own"],
        [~rigInDevMenu.item, ~rigOutDevMenu.item, ~rigInstMenu.item, ~rigBassMenu.item, ~rigBufferMenu.item].asString);
    ok.("...the inputs offered are the interface's four", ~rigInstMenu.items.size == 4 and: { ~rigBassMenu.items.size == 5 });
    ok.("...and with nothing changed there is nothing to apply", ~rigAudioApply.enabled.not);

    "== a change ==".postln;
    ~rigBassMenu.valueAction = 3;
    tick.();
    ok.("a bass on input 3 wakes Apply and restart", ~rigAudioApply.enabled and: { ~rigAudioApply.string == "Apply and restart" });
    ~rigAudioApply.doAction;
    tick.();
    ok.("one click only asks again, and restarts nothing", ~rigAudioApply.string == "Click again to restart" and: { applied.isEmpty });
    ~rigAudioApply.doAction;
    tick.();
    ok.("the second restarts on the menus' audio", applied.size == 1 and: {
        [\inDevice, \outDevice, \inChannel, \bassChannel, \hardwareBufferSize].collect { |k| applied[0][k] }
            == ["Interface", "Interface", 1, 2, nil] }, applied.asString);
    ok.("...says so, and waits", said.last[0].contains("Starting again on Interface") and: { ~rigAudioApply.enabled.not },
        said.asString);

    "== refused ==".postln;
    build.(\saSystem, (inDevice: "Interface", outDevice: "Interface", inChannel: 1));
    tick.();
    why = "Stop Record set first: a restart would end it";
    ~rigBufferMenu.valueAction = 3;
    ~rigAudioApply.doAction;
    ~rigAudioApply.doAction;
    tick.();
    ok.("a restart refused says why in the status line, and Apply stays", said.last == [why, \bad]
        and: { ~rigAudioApply.enabled } and: { ~rigAudioApply.string == "Apply and restart" }, said.last.asString);
    why = nil;

    "== the input device ==".postln;
    ~rigBufferMenu.valueAction = 0;
    ~rigInDevMenu.valueAction = 0;
    tick.();
    ok.("the system's default input, the one-input microphone: one input offered, the instrument on it",
        ~rigInstMenu.items == ["Input 1"] and: { ~rigInstMenu.value == 0 } and: { ~rigBassMenu.items == ["None", "Input 1"] }
            and: { ~rigAudioApply.enabled });
    ~rigInDevMenu.valueAction = 2;
    ~rigInstMenu.valueAction = 1;
    tick.();
    ok.("...back on the interface and input 2: nothing to apply again", ~rigAudioApply.enabled.not);

    "== the second click waits four seconds ==".postln;
    ~rigOutDevMenu.valueAction = 1;
    applied.clear;
    ~rigAudioApply.doAction;
    4.3.wait;
    ok.("unanswered, it is Apply and restart again, and nothing restarted",
        ~rigAudioApply.string == "Apply and restart" and: { applied.isEmpty });
    ~rigAudioApply.doAction;
    ok.("...so the next click only asks again", ~rigAudioApply.string == "Click again to restart" and: { applied.isEmpty });

    "== what gave way ==".postln;
    build.(\saSystem, (inDevice: "Gone", inChannel: 3));
    tick.();
    ok.("a device not connected and an input not there are said on the page",
        texts.(section).any { |t| t.contains("not connected") and: { t.contains("input 1 instead") } }, texts.(section).asString);
    ok.("...and the menus show what plays instead: the system's default, input 1",
        ~rigInDevMenu.value == 0 and: { ~rigInstMenu.value == 0 } and: { ~rigAudioApply.enabled.not });
    "MEGALOOPER_SHOT".getenv !? { |p| Image.fromWindow(w.view).write(p, "png") };

    "== a rig of yours ==".postln;
    build.(\sa, nil);
    tick.();
    ok.("its name and device, which its profile says, and no menus", texts.(section).includesEqual("sa")
        and: { texts.(section).includesEqual("TSMEGA") } and: { ~statusDeviceLabel.notNil }, texts.(section).asString);

    w.close;
    ("\n" ++ pass ++ " passed, " ++ fail ++ " failed").postln;
    fails.do { |f| ("FAILED: " ++ f).postln };
    if(fail == 0) { "CHECK-GUI-AUDIO PASSED".postln; 0.exit } { 1.exit };
}.play(AppClock);
)
