// MIDI maps as files, and the router using them (docs/dev/midi-map.md 8 and 6):
// the shipped maps, a map of yours, its backups, Keep, settings.json, which
// map a rig takes at boot, the inputs listened to, and learning through the
// router's own responders (arming, swallowing, the question about taking a
// message, Undo). On a scratch folder: nothing here may read or write the
// real ~/Library/Application Support/SuperCollider/megalooper. No MIDIClient.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-midimap-store");

{
var dir = thisProcess.nowExecutingPath.dirname;
var scripts = dir.dirname;
var root, saved, s, r, m, tsmega, keys, kept, path, yours, n, l, sent, lines, fn, feed, pc, t, before, midiLive;

if(~setupMidiIO.isNil) { (scripts +/+ "setup-midi.scd").load };
// The numbers megalooper was bound to before the maps were files, and the
// map phase 1 made of them.
if(~midiMapFromConstants.isNil) { (dir +/+ "legacy-midi-bindings.scd").load };
if(~saGuitarBank.isNil) { (scripts +/+ "setup-sa.scd").load };
if(~routingProfiles.isNil) { (scripts +/+ "setup-routing.scd").load };
if(~midiTargetsBuild.isNil) { (scripts +/+ "setup-miditargets.scd").load };
if(~midiRouteWith.isNil) { (scripts +/+ "setup-midimap.scd").load };
if(~onsetThresholdSpec.isNil) { (scripts +/+ "gui-const.scd").load };
if(~granularParams.isNil) { (scripts +/+ "gui-granular.scd").load };

saved = [~midiUserRootOverride, ~midiWriteSync, ~routingProfile, ~looper, ~midiOut, ~midiLog, ~midiMonitorPush,
    ~midiNow, ~midiSources, ~midiMap, ~midiTargets, ~midiKept, ~rp, ~megaSA, ~liveRecordToggle, ~midiDeaf];
root = ~tTempPath.("midimap-store");
protect {
    ~midiUserRootOverride = root;
    ~midiWriteSync = true;
    ~tAssert.("the folder of yours is the scratch one here", ~midiUserDir.().beginsWith(PathName.tmp));

    // ------------------------------------------------------------ shipped --
    tsmega = ~midiMapLoad.("tsmega");
    keys = ~midiMapLoad.("keys-and-knobs");
    ~tEq.("the TSMega's shipped map loads, as shipped, with no problems",
        [tsmega[\from], tsmega[\map] !? { |x| x.bindings.size }, tsmega[\warning], (tsmega[\problems] ? []).size],
        [\shipped, 20, nil, 0]);
    ~tAssert.("...answering only the TSMEGA", tsmega[\map].bindings.every { |b| b[\device] == "TSMEGA" });
    ~tEq.("the keys-and-knobs map: notes 60-71 and the knob CCs, any input",
        [keys[\map] !? { |x| x.bindings.size }, keys[\map].bindings.count { |b| b[\device].notNil }], [23, 0]);
    // What the shipped maps hold is today's numbers, and the decisions on them
    // (docs/dev/midi-map.md 13: 9, 10, 11): the TSMega's map has the programs and
    // the pedal, PC 8 is the delay everywhere, the notes and knobs are apart.
    ~rp = ~routingProfiles[\sa];
    m = ~midiMapFromConstants.();
    ~tEq.("together they hold exactly the bindings SA's numbers make",
        (tsmega[\map].bindings ++ keys[\map].bindings).collect { |b| [b[\msg], b[\num], b[\target], b[\hysteresis]] }
            .collect(_.asString).sort,
        m.collect { |b| [b[\msg], b[\num], b[\target], b[\hysteresis]] }.collect(_.asString).sort);
    // The two rigs for anyone's interface (standalone and saSystem) assume no
    // controller; every rig of the duo's starts with the TSMega's map.
    ~tEq.("every rig but standalone and saSystem starts with the TSMega's map",
        ~routingProfiles.keys.asArray.sort.collect { |k| [k, ~routingProfiles[k][\midiMap]] }.reject { |p| p[1] == "tsmega" },
        [[\saSystem, nil], [\standalone, nil]]);
    ~tEq.("the shipped maps are megalooper's: their names", ~midiMapNames.(~midiShippedDir.()),
        ["keys-and-knobs", "tsmega"]);

    // ----------------------------------------------------------- settings --
    s = ~midiSettingsRead.();
    ~tEq.("with no settings.json, the defaults: no choices, every input listened to, none sent back to",
        [s[\maps].size, s[\listen].size, s[\sendBack].size], [0, 0, 0]);
    ~tEq.("...and the knobs' defaults: one step of hysteresis, no takeover (decisions 7 and 15)",
        [s[\knobs][\hysteresis], s[\knobs][\takeover]], [1, \none]);
    s[\maps].put(\sa, "keys-and-knobs");
    s[\listen].put("Faderfox UC4", false);
    s[\sendBack].put("Faderfox UC4", true).put("TSMEGA", false);
    s[\knobs].put(\hysteresis, 2).put(\takeover, \pickup);
    ~midiSettingsWrite.(s, { |ok| r = ok });
    ~tEq.("settings.json is written", [r, File.exists(~midiSettingsPath.())], [true, true]);
    s = ~midiSettingsRead.();
    ~tEq.("...and read back", [s[\maps][\sa], s[\listen]["Faderfox UC4"], s[\knobs][\hysteresis], s[\knobs][\takeover]],
        ["keys-and-knobs", false, 2, \pickup]);
    ~tEq.("...sending back too, by device", [s[\sendBack]["Faderfox UC4"], s[\sendBack]["TSMEGA"]], [true, false]);
    ~midiDefaultsFrom.(s);
    ~tEq.("...and they are the router's defaults", [~midiDefaults[\hysteresis], ~midiDefaults[\takeover]], [2, \pickup]);
    ~midiDefaultsFrom.(~midiSettingsRead.().put(\knobs, nil));
    ~tEq.("...settings with none give the router the built-in ones", [~midiDefaults[\hysteresis], ~midiDefaults[\takeover]],
        [1, \none]);
    ~tEq.("a rig's choice in settings.json wins over its profile's", ~midiMapNameFor.(\sa, s), "keys-and-knobs");
    ~tEq.("...and a rig with none takes its profile's", ~midiMapNameFor.(\bhTsMega, s), "tsmega");
    ~tEq.("...and standalone none at all", ~midiMapNameFor.(\standalone, s), nil);
    File.use(~midiSettingsPath.(), "w", { |f| f.write("{\"format\": \"something else\"}") });
    s = ~midiSettingsRead.();
    ~tEq.("a settings.json that can't be read gives the defaults", [s[\maps].size, s[\listen].size], [0, 0]);
    File.use(~midiSettingsPath.(), "w", { |f| f.write("{\"format\": \"megalooper settings\", \"version\": 1, "
        ++ "\"midi\": {\"hysteresis\": \"lots\", \"takeover\": \"grab\"}}") });
    s = ~midiSettingsRead.();
    ~tEq.("knob defaults that can't be read are the built-in ones", [s[\knobs][\hysteresis], s[\knobs][\takeover]],
        [1, \none]);
    // What this build doesn't write itself is written back as it was; a newer
    // file is read but never written over.
    File.use(~midiSettingsPath.(), "w", { |f| f.write("{\"format\": \"megalooper settings\", \"version\": 1, "
        ++ "\"theme\": \"dark\", \"midi\": {\"maps\": {\"sa\": \"tsmega\"}, \"listen\": {}, \"lights\": \"off\", "
        ++ "\"sendBack\": {\"UC4\": true, \"Pad\": \"maybe\"}, \"takeover\": \"scale\"}}") });
    s = ~midiSettingsRead.();
    s[\listen].put("TSMEGA", true);
    ~midiSettingsWrite.(s, { |ok| r = ok });
    s = File.readAllString(~midiSettingsPath.()).parseJSON;
    ~tEq.("a field this build doesn't know survives a write, and one it knows is written once",
        [r, s["theme"], s["midi"]["lights"], s["midi"]["takeover"], s["midi"]["maps"]["sa"],
            File.readAllString(~midiSettingsPath.()).findAll("takeover").size],
        [true, "dark", "off", "scale", "tsmega", 1]);
    ~tEq.("...sending back too, once, and on only where it says true",
        [File.readAllString(~midiSettingsPath.()).findAll("sendBack").size, s["midi"]["sendBack"]["UC4"],
            s["midi"]["sendBack"]["Pad"]], [1, "true", "false"]);
    File.use(~midiSettingsPath.(), "w", { |f| f.write("{\"format\": \"megalooper settings\", \"version\": 2, "
        ++ "\"midi\": {\"maps\": {\"sa\": \"keys-and-knobs\"}}}") });
    s = ~midiSettingsRead.();
    ~tEq.("a settings.json from a newer megalooper is read for what this one knows", s[\maps][\sa], "keys-and-knobs");
    s[\maps].put(\sa, "tsmega");
    ~midiSettingsWrite.(s, { |ok| r = ok });
    ~tEq.("...and never written over", [r, File.readAllString(~midiSettingsPath.()).contains("\"version\": 2")], [false, true]);
    File.delete(~midiSettingsPath.());

    // ------------------------------------------------------- yours, Keep --
    m = tsmega[\map].adding((msg: \program, num: 30, device: "TSMEGA", target: 'looper.stop'))
        .renamed("tsmega", "tsmega", 1);
    ~midiMapKeep.(m, { |ok, why| r = [ok, why] });
    yours = ~midiMapPath.(~midiUserDir.(), "tsmega");
    ~tEq.("Keep writes your map", [r, File.exists(yours)], [[true, nil], true]);
    ~tEq.("...with no .tmp left behind", File.exists(yours ++ ".tmp"), false);
    r = ~midiMapLoad.("tsmega");
    ~tEq.("yours now hides the shipped one", [r[\from], r[\map].bindings.size], [\yours, 21]);
    ~tEq.("...and says what it was based on", [r[\map].basedOn, r[\map].revision], ["tsmega", 1]);
    ~tEq.("the first Keep had no old file to back up", ~midiBackups.("tsmega").size, 0);
    ~midiMapKeep.(m.adding((msg: \program, num: 31, device: "TSMEGA", target: 'looper.undo')), { |ok| r = ok });
    ~tEq.("the next Keep backs the old one up", ~midiBackups.("tsmega").size, 1);
    ~tEq.("...the one it replaced", LooperMidiMap.parse(~midiReadText.(~midiBackups.("tsmega")[0]))[\bindings].size, 21);
    // Old backups, as if from earlier Keeps: only the newest five stay.
    (1..6).do { |i| File.use(~midiBackupDir.() +/+ "tsmega" +/+ ("2601" ++ i ++ "_000000.json"), "w", { |f| f.write(m.fileString) }) };
    ~midiMapKeep.(m, { |ok| r = ok });
    ~tEq.("Keep leaves the newest five backups", ~midiBackups.("tsmega").size, 5);

    // A map of yours that can't be read gives way to its newest backup that
    // can, never to the shipped one.
    File.use(yours, "w", { |f| f.write("{\"format\": \"megalooper midi map\", \"bindings\": [") });
    r = ~midiMapLoad.("tsmega");
    ~tEq.("your map unreadable: its newest backup that reads is loaded, and the header says so",
        [r[\from], r[\map] !? { |x| x.bindings.size }, r[\warning].notNil], [\backup, 22, true]);
    ~midiBackups.("tsmega").do { |p| File.delete(p) };
    r = ~midiMapLoad.("tsmega");
    ~tEq.("...with no backup: no map at all, not the shipped one, and the header says the footswitches are off",
        [r[\map], r[\warning] !? { |w| w.contains("footswitches are off") }], [nil, true]);
    File.use(yours, "w", { |f| f.write("{\"format\": \"megalooper midi map\", \"version\": 7, \"bindings\": []}") });
    ~tEq.("a map of yours from a newer megalooper is not read either", ~midiMapLoad.("tsmega")[\map], nil);
    File.delete(yours);
    ~tEq.("with yours gone, the shipped one again", ~midiMapLoad.("tsmega")[\from], \shipped);
    r = ~midiMapLoad.(nil);
    ~tEq.("no map named: none, and the header says how to make one",
        [r[\map], r[\warning] !? { |w| w.contains("Setup") }], [nil, true]);
    ~tAssert.("a map nobody has is said", ~midiMapLoad.("nowhere")[\warning].contains("no MIDI map 'nowhere'"));

    // -------------------------------------------------- the router at boot --
    midiLive = AbstractResponderFunc.allEnabled.keys.any { |k| k.asString.beginsWith("MIDI") };
    case
    { midiLive and: { Platform.ideName == "none" } } {
        ~tFail.("no MIDI responder is registered before the router's tests, in a headless run",
            AbstractResponderFunc.allEnabled.keys.asArray.asString);
    }
    { midiLive } { ~tSkip.("the router with map files", "MIDI responders run in this interpreter (a megalooper?)") }
    {
        before = MIDIdef.all.keys;
        sent = List.new;
        lines = List.new;
        ~looper = ~tLooper.();
        ~megaSA = nil;
        ~midiOut = ();
        [\noteOn, \noteOff, \control, \program, \bend, \touch, \polyTouch].do { |sel|
            ~midiOut.put(sel, { |self ... args| sent.add([sel] ++ args); self });
        };
        ~midiLog = false;
        ~midiMonitorPush = { |line| lines.add(line) };
        ~routingProfile = \sa;
        ~rp = ~routingProfiles[\sa];
        ~midiMap = nil;
        protect {
            ~setupMidiBindings.();
            ~tEq.("at boot the rig takes its map: SA, the TSMega's as shipped",
                [~midiMap.name, ~midiMapFrom, ~midiMap.bindings.size, ~midiMapWarning], ["tsmega", \shipped, 20, nil]);
            // The inputs there are, as MIDIClient would list them.
            ~midiSources = IdentityDictionary[1001 -> ["TSMEGA", "TSMEGA"], 1002 -> ["Faderfox UC4", "Faderfox UC4"]];
            fn = { |name| MIDIdef.all[name] !? { |x| x.func } };
            pc = { |num, src = 1001| fn.(\midiInProgram).value(num, 0, src) };
            feed = { |vals, num, src = 1001| vals.do { |v| fn.(\midiInCc).value(v, num, 0, src) } };
            ~looper.onsetThreshold = 0.5;
            feed.([30], ~onsetThresholdCc);
            ~tNear.("the TSMEGA's pedal drives the threshold", ~looper.onsetThreshold, ~onsetThresholdSpec.map(30 / 127), 1e-9);
            feed.([90], ~onsetThresholdCc, 1002);
            ~tNear.("...another controller's CC 7 does not: the map answers only the TSMEGA",
                ~looper.onsetThreshold, ~onsetThresholdSpec.map(30 / 127), 1e-9);
            ~tEq.("...but it still goes on to Live, as everything does", sent.last, [\control, 0, 7, 90]);

            // Listening, from settings.json, by device name.
            s = ~midiSettingsRead.();
            s[\listen].put("Faderfox UC4", false);
            ~midiListenFrom.(s);
            sent.clear;
            lines.clear;
            feed.([10], 20, 1002);
            ~tEq.("an input not listened to goes nowhere near Live, and is logged as such",
                [sent.size, lines.last], [0, "cc       num=20 val=10 chan=0  (not listening)"]);
            ~midiListenFrom.(~midiSettingsRead.());

            // What the header says about MIDI.
            ~tEq.("with the TSMEGA listened to, the header has nothing to say", ~midiAttention.(), nil);
            s = ~midiSettingsRead.();
            s[\listen].put("TSMEGA", false);
            ~midiListenFrom.(s);
            ~tAssert.("a TSMEGA not listened to is said in red: its footswitches are off",
                ~midiAttention.() !? { |a| (a[1] == \error) and: { a[0].contains("TSMEGA is not listened to") } } ? false,
                ~midiAttention.().asString);
            ~midiListenFrom.(~midiSettingsRead.());
            n = ~midiSources;
            ~midiSources = IdentityDictionary[1002 -> ["Faderfox UC4", "Faderfox UC4"]];
            ~tAssert.("...and one not connected, in amber", ~midiAttention.() !? { |a|
                (a[1] == \note) and: { a[0].contains("TSMEGA is not connected") } } ? false, ~midiAttention.().asString);
            ~midiSources = IdentityDictionary.new;
            ~tEq.("...but not before MIDI lists any input at all", ~midiAttention.(), nil);
            ~midiSources = n;

            // -------------------------------------------------- learning --
            t = 1000.0;
            ~midiNow = { t };
            l = ~midiLearnArm.('looper.multiply');
            ~tAssert.("a control is armed", ~midiLearning.notNil and: { ~midiLearning[\target] == 'looper.multiply' });
            sent.clear;
            lines.clear;
            pc.(30);
            ~tEq.("while it is, a stomp is swallowed: nothing on to Live, logged as learning",
                [sent.size, lines.last], [0, "program  prog=30 chan=0  (learning)"]);
            t = t + 0.05;
            ~midiLearnLive.(t);
            ~tEq.("30 ms on, it is learned: PC 30 from the TSMEGA drives Multiply",
                ~midiMap.bindingsFor('looper.multiply').collect { |b| [b[\msg], b[\num], b[\chan], b[\device], b[\port]] },
                [[\program, 30, 0, "TSMEGA", nil]]);
            ~tEq.("...the learning is over, and says what it made", [~midiLearning, ~midiLearnNote],
                [nil, "PC 30 ch 1 → Multiply"]);
            ~tAssert.("...and the map has changes not kept", ~midiMapDirty.());
            ~midiMapUndo.();
            ~tEq.("Undo takes it back", ~midiMap.bindingsFor('looper.multiply'), []);
            ~tAssert.("...and then nothing is left to keep", ~midiMapDirty.().not);

            // Taking a message another control has: a question, not at once.
            ~midiLearnArm.('looper.multiply');
            pc.(4);
            t = t + 0.05;
            ~midiLearnLive.(t);
            ~tAssert.("learning PC 4, which is Trigger's, asks first", ~midiLearning.notNil and: { ~midiLearning[\question].notNil });
            ~tAssert.("...in words", ~midiLearnNote.contains("Trigger"));
            n = ~midiMap.bindings.size;
            pc.(4);
            ~tAssert.("a stomp of the same switch meanwhile doesn't answer it, and is swallowed",
                ~midiLearning[\question].notNil and: { ~midiMap.bindings.size == n });
            ~midiLearnAnswer.(\cancel);
            ~tEq.("Cancel: nothing changes", [~midiLearning, ~midiMap.bindings.size,
                ~midiMap.lookup(\program, 0, 4).collect { |x| x[\binding][\target] }], [nil, n, ['looper.trigger']]);
            ~midiLearnArm.('looper.multiply');
            pc.(4);
            t = t + 0.05;
            ~midiLearnLive.(t);
            ~midiLearnAnswer.(\both);
            ~tEq.("Both: PC 4 drives Trigger and Multiply", ~midiMap.lookup(\program, 0, 4).collect { |x| x[\binding][\target] },
                ['looper.trigger', 'looper.multiply']);
            ~tEq.("...the new one marked as meant to share (layer), so it isn't said twice",
                [~midiMap.bindingsFor('looper.multiply')[0][\layer], ~midiMap.problems.size], [true, 0]);
            ~midiMapUndo.();
            ~midiLearnArm.('looper.multiply');
            pc.(4);
            t = t + 0.05;
            ~midiLearnLive.(t);
            ~midiLearnAnswer.(\move);
            ~tEq.("Move it here: PC 4 is Multiply's, and Trigger's is gone",
                [~midiMap.lookup(\program, 0, 4).collect { |x| x[\binding][\target] }, ~midiMap.bindingsFor('looper.trigger').size],
                [['looper.multiply'], 0]);
            ~midiMapUndo.();
            ~midiLearnArm.('looper.multiply');
            pc.(4);
            t = t + 0.05;
            ~midiLearnLive.(t);
            t = t + 10.1;
            ~midiLearnLive.(t);
            ~tEq.("a question not answered in 10 s cancels itself: the old binding stays",
                [~midiLearning, ~midiMap.lookup(\program, 0, 4).collect { |x| x[\binding][\target] }],
                [nil, ['looper.trigger']]);
            ~midiLearnArm.('looper.multiply');
            t = t + 15.1;
            sent.clear;
            pc.(21);
            ~tEq.("an arm with nothing learned in 15 s ends at the next message, which then acts and goes to Live",
                [~midiLearning, sent.size], [nil, 2]);
            // A CC footswitch: two presses, counted. The TSMega sends 0
            // between presses, so the router has seen 0 before the arm.
            feed.([0], 80);
            ~midiLearnArm.('looper.reverse');
            feed.([64], 80);
            t = t + 0.5;
            feed.([0], 80);
            t = t + 1.6;
            ~midiLearnLive.(t);
            ~tEq.("a CC footswitch pressed twice is learned as one message a press",
                ~midiMap.bindingsFor('looper.reverse').collect { |b| [b[\msg], b[\num], b[\switch]] },
                [[\cc, 80, \oneMessage]]);
            // Counting a switch's presses holds that switch back, nothing else.
            // (The TSMega sends 0 between presses, so the router has seen it.)
            feed.([0], 81);
            ~midiLearnArm.('looper.dissolve');
            feed.([64], 81);
            t = t + 0.05;
            ~midiLearnLive.(t);
            sent.clear;
            lines.clear;
            pc.(21);
            ~tAssert.("while a switch's presses are counted, another stomp still acts and goes on to Live",
                ~midiLearning[\learner].counting and: { sent.size == 2 } and: { lines.last.contains("(learning)").not },
                [sent.size, lines.last].asString);
            feed.([0], 81);
            ~tAssert.("...while the counted one is held back", lines.last.contains("(learning)"), lines.last);
            ~midiLearnDisarm.(nil);
            // Learned again, the pedal keeps its hysteresis.
            ~midiLearnArm.('looper.onsetThreshold');
            feed.([20], 7);
            t = t + 0.05;
            ~midiLearnLive.(t);
            ~tEq.("the threshold learned again from CC 7 keeps the pedal's hysteresis",
                ~midiMap.bindingsFor('looper.onsetThreshold').collect { |b| [b[\num], b[\device], b[\hysteresis]] },
                [[7, "TSMEGA", 1]]);
            ~midiMapUndo.();
            // ...on another CC, its takeover and its swept travel too; on pitch
            // bend its takeover, but not a CC's travel, which is in other units.
            ~midiBindingChange.(~midiMap.bindingsFor('looper.onsetThreshold')[0], (takeover: \scale, inLo: 3, inHi: 126));
            ~midiLearnArm.('looper.onsetThreshold');
            feed.([20], 11);
            t = t + 0.1;
            feed.([30], 11);
            t = t + 0.05;
            ~midiLearnLive.(t);
            ~tEq.("...learned again on another CC, it keeps its takeover and its travel too",
                ~midiMap.bindingsFor('looper.onsetThreshold').collect { |b|
                    [b[\num], b[\takeover], b[\inLo], b[\inHi], b[\hysteresis]] },
                [[11, \scale, 3, 126, 1]]);
            ~midiLearnArm.('looper.onsetThreshold');
            fn.(\midiInBend).value(8000, 0, 1001);
            t = t + 0.1;
            fn.(\midiInBend).value(9000, 0, 1001);
            t = t + 0.05;
            ~midiLearnLive.(t);
            ~tEq.("...on pitch bend, its takeover, not a CC's travel",
                ~midiMap.bindingsFor('looper.onsetThreshold').collect { |b| [b[\msg], b[\takeover], b[\inLo], b[\inHi]] },
                [[\bend, \scale, nil, nil]]);
            ~midiBindingChange.(~midiMap.bindingsFor('looper.onsetThreshold')[0], (inLo: 100, inHi: 16000));
            ~midiLearnArm.('looper.onsetThreshold');
            fn.(\midiInBend).value(9500, 0, 1001);
            t = t + 0.05;
            ~midiLearnLive.(t);
            ~tEq.("...and learned again on pitch bend, a bend's travel",
                ~midiMap.bindingsFor('looper.onsetThreshold').collect { |b| [b[\msg], b[\inLo], b[\inHi]] },
                [[\bend, 100, 16000]]);
            5.do { ~midiMapUndo.() };
            ~tEq.("(Undo puts the pedal back)", ~midiMap.bindingsFor('looper.onsetThreshold').collect { |b|
                [b[\num], b[\takeover], b[\inLo]] }, [[7, nil, nil]]);
            // A control with a program change first and its pedal second takes
            // what it keeps from the pedal, the binding most like a CC.
            m = ~midiMap.bindingsFor('looper.onsetThreshold')[0];
            ~midiMapEdit.(~midiMap.removing([m]).adding((msg: \program, num: 22, device: "TSMEGA", target: 'looper.onsetThreshold'))
                .adding(m.copy.put(\hysteresis, 2).put(\inHi, 126).put(\takeover, \pickup)));
            ~midiLearnArm.('looper.onsetThreshold');
            feed.([20], 12);
            t = t + 0.1;
            feed.([30], 12);
            t = t + 0.05;
            ~midiLearnLive.(t);
            ~tEq.("...and with a program change before its pedal, what the pedal said, not the program change",
                ~midiMap.bindingsFor('looper.onsetThreshold').collect { |b| [b[\num], b[\hysteresis], b[\inHi], b[\takeover]] },
                [[12, 2, 126, \pickup]]);
            2.do { ~midiMapUndo.() };
            ~tEq.("(Undo puts the pedal back)", ~midiMap.bindingsFor('looper.onsetThreshold').collect { |b| b[\num] }, [7]);
            // Shift-click (add): another binding, the first kept.
            ~midiLearnArm.('looper.reverse', true);
            pc.(33);
            t = t + 0.05;
            ~midiLearnLive.(t);
            ~tEq.("added with Shift, a control keeps its other bindings",
                ~midiMap.bindingsFor('looper.reverse').size, 2);
            ~midiLearnArm.('looper.reverse');
            pc.(34);
            t = t + 0.05;
            ~midiLearnLive.(t);
            ~tEq.("...learned without, it has only the new one", ~midiMap.bindingsFor('looper.reverse').collect { |b| b[\num] }, [34]);
            // A Cmd-period ends a learning.
            ~midiLearnArm.('looper.reverse');
            ~midiCmdPeriodHook.value;
            ~tEq.("Cmd-period ends a learning", ~midiLearning, nil);

            // ----------------------------------------------- editing a binding --
            m = ~midiMap.bindingsFor('looper.reverse')[0];
            ~midiBindingChange.(m, (mode: \hold));
            ~tEq.("a binding's fields change", ~midiMap.bindingsFor('looper.reverse')[0][\mode], \hold);
            ~midiBindingChange.(~midiMap.bindingsFor('looper.reverse')[0], (mode: \remove));
            ~tEq.("...and \\remove takes one away", ~midiMap.bindingsFor('looper.reverse')[0][\mode], nil);
            n = ~midiMap.bindings.size;
            ~tEq.("a change that can't be used is refused, and said",
                [~midiBindingChange.(~midiMap.bindingsFor('looper.reverse')[0], (chan: 99)), ~midiLearnNote.contains("channel")],
                [nil, true]);
            m = ~midiMap.bindingsFor('looper.onsetThreshold')[0];
            ~looper.onsetThreshold = 0.2;
            ~midiBindingSetEnd.(m, \min);
            m = ~midiMap.bindingsFor('looper.onsetThreshold')[0];
            ~looper.onsetThreshold = 1.0;
            ~midiBindingSetEnd.(m, \max);
            m = ~midiMap.bindingsFor('looper.onsetThreshold')[0];
            ~tEq.("Set Min and Set Max take the control's value now", [m[\min], m[\max]], [0.2, 1.0]);
            ~midiBindingSwap.(m);
            m = ~midiMap.bindingsFor('looper.onsetThreshold')[0];
            ~tEq.("Swap turns them round", [m[\min], m[\max]], [1.0, 0.2]);
            ~midiBindingRemove.(m);
            ~tEq.("× removes a binding", ~midiMap.bindingsFor('looper.onsetThreshold'), []);

            // ------------------------------------------------- kept, at boot --
            ~midiMapKeep.(~midiMap, { |ok| r = ok });
            kept = ~midiMap.bindings.size;
            ~midiMap = nil;
            ~setupMidiBindings.();
            ~tEq.("Keep, then a boot: yours is the map", [~midiMapFrom, ~midiMap.bindings.size], [\yours, kept]);
            ~midiMapEdit.(~midiMap.adding((msg: \program, num: 40, device: "TSMEGA", target: 'looper.stop')));
            ~setupMidiBindings.();
            ~tEq.("a rebuild mid-set keeps changes not kept yet", ~midiMap.bindings.size, kept + 1);
            // The Knobs row's defaults, kept in settings.json, are the
            // router's from the boot on.
            s = ~midiSettingsRead.();
            s[\knobs].put(\hysteresis, 0).put(\takeover, \pickup);
            ~midiSettingsWrite.(s);
            ~midiSettings = nil;
            ~midiDefaults = ~midiKnobDefaults.copy;
            ~setupMidiBindings.();
            ~tEq.("the knobs' defaults in settings.json are the router's from the boot on",
                [~midiDefaults[\hysteresis], ~midiDefaults[\takeover]], [0, \pickup]);
            s[\knobs].put(\hysteresis, 1).put(\takeover, \none);
            ~midiSettingsWrite.(s);
            ~midiSettings = nil;
            ~midiDefaultsFrom.(~midiSettingsNow.());
            // A map of yours that can't be read, with no backup: no bindings,
            // but the map keeps its name, so the Rig tab can put the shipped one
            // back or keep a new one under it.
            ~midiBackups.("tsmega").do { |p| File.delete(p) };
            File.use(~midiMapPath.(~midiUserDir.(), "tsmega"), "w", { |f| f.write("{\"format\": \"megal") });
            ~midiMap = nil;
            ~setupMidiBindings.();
            ~tEq.("a map of yours that can't be read, and no backup: an empty map, under its name, and a warning",
                [~midiMap.name, ~midiMap.bindings.size, ~midiMapWarning.notNil], ["tsmega", 0, true]);
        } {
            ~midiLearning = nil;
            MIDIdef.all.keys.reject { |k| before.includes(k) }.do { |k| MIDIdef.all[k] !? { |x| x.free } };
        };
    };
} {
    ~tRemoveTree.(root);
    ~midiUserRootOverride = saved[0]; ~midiWriteSync = saved[1]; ~routingProfile = saved[2]; ~looper = saved[3];
    ~midiOut = saved[4]; ~midiLog = saved[5]; ~midiMonitorPush = saved[6]; ~midiNow = saved[7] ? { Main.elapsedTime };
    ~midiSources = saved[8]; ~midiMap = saved[9]; ~midiTargets = saved[10]; ~midiKept = saved[11]; ~rp = saved[12];
    ~megaSA = saved[13]; ~liveRecordToggle = saved[14]; ~midiDeaf = saved[15] ? IdentitySet.new;
};
~tAssert.("the scratch folder is gone again", File.exists(root).not);
}.value;
