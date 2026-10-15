// Megalooper SA's sounds on a recording stub (docs/dev/device-chains.md, phase 3):
// MegaSA built from a sound, the chains read back as one, a sound written
// with its one commit point (the plugin's state, the text, then the sweep),
// Keep's mark, a recall onto the running chains, and the plugin's state jobs.
// Every file is under a scratch folder.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-megasa-keep");

{
var vst = \VSTPlugin.asClass;
var root = ~tTempPath.("megasa-keep");
var kept = root +/+ "sa" +/+ "kept.json", states = root +/+ "sa" +/+ "kept.states", backups = root +/+ "sa" +/+ "backups" +/+ "kept";
var stub, sa, plug, sound, text, kids, want, run, heard, got, said, d, n, before, target, other, srv, m, late, order, identity, warm, future;

kids = { |srv, chain| (~tNodeTree.(srv)[\children][chain.group.nodeID] ? []).asArray };
want = { |chain| [chain.source.nodeID] ++ chain.devices.select { |x| x.node.notNil }.collect { |x| x.node.nodeID } };
// The plugin's state jobs run on a routine with waits: stepped here by hand
// (its clock later finds it done).
run = { |megaSA| megaSA.instVarAt(\bankRoutine) !? { |r| 12.do { r.next } } };
heard = { |obj, fn|
    var all = List.new, f = { |o, what ... more| all.add([what] ++ more) };
    obj.addDependant(f);
    protect { fn.value } { obj.removeDependant(f) };
    all.asArray
};

MegaSA.loadSynthDefs;
~tAssert.("this test's files are under a scratch folder", root.beginsWith(PathName.tmp));

if(vst.isNil) { ~tSkip.("sounds with a plugin", "VSTPlugin is not installed here") } {
// ---- built from a sound ------------------------------------------------------------
plug = ~tFakePlugin.(\open);
identity = MegaFiles.json(plug.identity);
text = "{\"format\": \"megalooper sound\", \"version\": 1,\n \"name\": \"kept\", \"savedAt\": \"261010_090000\",\n"
    ++ " \"nextIds\": {\"delay\": 3, \"echo\": 2, \"filter\": 2, \"pitchLoop\": 2, \"plugin\": 2, \"redux\": 2, \"saturator\": 2, \"shifter\": 2, \"wah\": 2},\n"
    ++ " \"tracks\": [\n"
    ++ "  {\"track\": \"guitar\", \"devices\": [\n"
    ++ "   " ++ MegaSASound.default(nil).prDeviceString(
            MegaSASound.deviceOfType(\delay2, \delay, (delayMix: 0.3)).put(\name, "Dual Delay 2").put(\on, true)) ++ ",\n"
    ++ "   " ++ MegaSASound.default(nil).prDeviceString(MegaSASound.deviceOfType(\shifter, \shifter).put(\extras, [["color", "\"#f00\""]])) ++ ",\n"
    ++ "   {\"id\": \"plugin1\", \"type\": \"plugin\", \"name\": \"BIAS FX 2\", \"on\": true, \"layout\": [1, 1], \"plugin\": " ++ identity
        ++ ", \"state\": {\"kind\": \"program\", \"file\": \"plugin1-a.fxp\"}},\n"
    ++ "   " ++ MegaSASound.default(nil).prDeviceString(MegaSASound.deviceOfType(\filter, \filter).put(\settingsExtras, [["filterFuture", "0.250"]])) ++ ",\n"
    ++ "   " ++ MegaSASound.default(nil).prDeviceString(MegaSASound.deviceOfType(\pitchLoop, \pitchLoop)) ++ "], \"mood\": 7},\n"
    ++ "  {\"track\": \"loop\", \"devices\": [\n"
    ++ "   " ++ MegaSASound.default(nil).prDeviceString(MegaSASound.deviceOfType(\redux, \redux)) ++ ",\n"
    ++ "   " ++ MegaSASound.default(nil).prDeviceString(MegaSASound.deviceOfType(\echo, \echo).put(\on, true)) ++ ",\n"
    ++ "   {\"id\": \"wah1\", \"type\": \"wah\", \"on\": true, \"sweep\": 3.0e1}]},\n"
    ++ "  {\"track\": \"bass\", \"devices\": []}],\n \"theme\": {\"a\": [1, 2.50]}}\n";
File.mkdir(states);
File.use(kept, "w", { |f| f.write(text) });
File.use(states +/+ "plugin1-a.fxp", "w", { |f| f.write("state a") });
sound = MegaSASound.read(kept);
~tAssert.("(the sound reads, and writes itself back as it was)", sound.isKindOf(MegaSASound) and: { sound.fileString == text }, sound.asString);
stub = ~tStubServer.();
sa = ~tMegaSA.(stub, plug, nil, sound);
Routine { sa.attachLooper(~tLooper.()) }.next;
~tEq.("MegaSA built from a sound: the chains are its devices, in its order",
    [sa.guitarChain.ids, sa.loopChain.ids], [[\delay2, \shifter, \plugin1, \filter, \pitchLoop], [\redux, \echo, \wah1]]);
~tEq.("...on the server too, a synth each", [kids.(stub, sa.guitarChain), kids.(stub, sa.loopChain)], [want.(sa.guitarChain), want.(sa.loopChain)]);
~tEq.("...each with its switch, its settings and its name",
    [~tStartArgs.(stub, sa.fxNode(\delay2))[\delayOn], ~tStartArgs.(stub, sa.fxNode(\delay2))[\delayMix], ~tStartArgs.(stub, sa.fxNode(\echo))[\echoOn],
        ~tStartArgs.(stub, sa.fxNode(\shifter))[\shifterOn], sa.device(\delay2).name, sa.fx(\delay2), sa.fx(\shifter)],
    [1, 0.3, 1, 0, "Dual Delay 2", true, false]);
// The effects went by other names before release 1.0, and sounds kept then hold them.
~tEq.("a name megalooper gave before 1.0 reads as the one it gives now; the player's own stays, and so does none",
    [MegaSAFx.nameNow(\delay, \delay, "Delay"), MegaSAFx.nameNow(\delay2, \delay, "Delay 2"), MegaSAFx.nameNow(\filter, \filter, "Auto Filter"),
        MegaSAFx.nameNow(\delay2, \delay, "Slap"), MegaSAFx.nameNow(\delay, \delay, "Delay 2"), MegaSAFx.nameNow(\redux, \redux, nil)],
    ["Dual Delay", "Dual Delay 2", "Envelope Filter", "Slap", "Delay 2", nil]);
other = MegaSASound.default(nil);
other.device(\delay).put(\name, "Delay");
other.device(\echo).put(\name, "My Echo");
m = ~tMegaSA.(nil, nil, nil, other);
~tEq.("a sound kept before 1.0 comes up with today's names, and is written back with them; a name of your own is kept",
    [m.device(\delay).name, m.device(\echo).name, m.sound.device(\delay)[\name], m.sound.device(\echo)[\name]],
    ["Dual Delay", "My Echo", "Dual Delay", "My Echo"]);
m.free;
~tEq.("...no default Delay or Saturator: the sound has none", [sa.device(\delay), sa.device(\saturator)], [nil, nil]);
~tEq.("...a device of a type this build has not passes its chain through, and says so",
    [sa.device(\wah1).status, ~tNodeTree.(stub)[\defs][sa.fxNode(\wah1).nodeID]], [\missing, \megaSADevNull]);
~tEq.("the plugin is hosted in the sound's plugin device, and opens with that device's state",
    [sa.guitarPlugin === plug, plug[\openedWith], plug[\bank], sa.held(\guitar)],
    [true, (kind: \program, path: states +/+ "plugin1-a.fxp"), states +/+ "plugin1-a.fxp", []]);
~tEq.("the chains read back as the sound they were built from, byte for byte, what this build does not know included",
    sa.sound("kept").named("kept", "261010_090000").fileString, text);
~tEq.("the ids go on from the sound's marks", sa.insertDevice(\guitar, nil, \delay) !? (_.id), \delay3);
sa.undo;

// A sound with no plugin hosts none, whatever the rig has.
other = ~tFakePlugin.(\open);
m = ~tMegaSA.(nil, other, nil, MegaSASound.default(nil));
~tEq.("a sound with no plugin hosts none: nothing is opened, the guitar is not held",
    [m.guitarPlugin, other[\opened], m.held(\guitar), m.guitarChain.ids], [nil, 0, [], MegaSAFx.guitarKeys]);
m.free;
// A sound with a plugin on a rig without one keeps its device, to write back.
m = ~tMegaSA.(nil, nil, nil, sound);
~tEq.("a sound's plugin on a rig with none: its device stays, failed, and nothing holds the guitar",
    [m.device(\plugin1) !? (_.status), m.guitarPlugin, m.held(\guitar)], [\failed, nil, []]);
~tAssert.("...and a sound written from there still names the plugin and its state",
    m.sound("x").fileString.contains(identity) and: { m.sound("x").fileString.contains("\"file\": \"plugin1-a.fxp\"") });
m.free;
// A state file that is gone: open, but the guitar stays held.
File.use(root +/+ "sa" +/+ "gone.json", "w", { |f| f.write(text.replace("plugin1-a.fxp", "plugin1-gone.fxp")) });
other = ~tFakePlugin.(\open);
m = ~tMegaSA.(nil, other, nil, MegaSASound.read(root +/+ "sa" +/+ "gone.json"));
~tEq.("a sound whose state file is gone: the plugin opens, and the guitar stays held until unmuted",
    [other[\state], m.held(\guitar)], [\open, [\state]]);
m.free;

// ---- a sound written -----------------------------------------------------------------
got = nil;
sa.setParam(\delay2, \delayMix, 0.6);
sa.writeSound(kept, "kept", true, backups, { |ok, why, snd| got = [ok, why, snd] }, true, "261010_100001");
~tEq.("a sound with its states is not written before the plugin has saved", [got, MegaFiles.readText(kept)], [nil, text]);
run.(sa);
~tEq.("then it is: the action gets true and the sound", [got !? { got[0] }, got !? { got[1] }, got !? { got[2].class }], [true, nil, MegaSASound]);
d = MegaSASound.read(kept);
~tEq.("...the file reads back as the chains: the setting moved, a new stamp",
    [d.device(\delay2)[\settings][\delayMix], d.savedAt, d.devices(\guitar).collect { |x| x[\id] }],
    [0.6, "261010_100001", [\delay2, \shifter, \plugin1, \filter, \pitchLoop]]);
~tEq.("...naming the state the plugin wrote just now, in the sound's own folder",
    [d.device(\plugin1)[\state], MegaFiles.readText(states +/+ "plugin1-261010_100001.fxp"), sa.device(\plugin1).state[\path]],
    [(kind: \program, file: "plugin1-261010_100001.fxp"), "fake state 1", states +/+ "plugin1-261010_100001.fxp"]);
~tEq.("...the file it replaced copied to the backups first", MegaFiles.readText(backups +/+ "261010_100001.json"), text);
~tAssert.("...and the state that backup names is still there: only what nobody names is swept",
    File.exists(states +/+ "plugin1-a.fxp"));
~tAssert.("...what this build does not know still in the file", d.fileString.contains("\"theme\": {\"a\": [1, 2.50]}")
    and: { d.fileString.contains("\"sweep\": 3.0e1") } and: { d.fileString.contains("\"filterFuture\": 0.250") });

// Without states (a loop plays): the text only, naming the state it had.
before = plug[\saves];
got = nil;
sa.setParam(\delay2, \delayMix, 0.7);
sa.writeSound(kept, "kept", false, backups, { |ok, why, snd| got = [ok, why] }, true, "261010_100002");
d = MegaSASound.read(kept);
~tEq.("a sound written without its states is written at once, and names the state it had",
    [got, plug[\saves] - before, d.device(\plugin1)[\state][\file], d.device(\delay2)[\settings][\delayMix]],
    [[true, nil], 0, "plugin1-261010_100001.fxp", 0.7]);

// A state the plugin cannot save: nothing changes on disk.
before = MegaFiles.readText(kept);
plug[\saveFails] = true;
got = nil;
sa.writeSound(kept, "kept", true, backups, { |ok, why, snd| got = [ok, why] }, true, "261010_100003");
run.(sa);
plug[\saveFails] = false;
~tEq.("a state that is not saved fails the whole write: the old file stays, and names a state that is there",
    [got !? { got[0] }, got !? { got[1].contains("did not save") }, MegaFiles.readText(kept) == before,
        sa.device(\plugin1).state[\file], File.exists(backups +/+ "261010_100003.json")],
    [false, true, true, "plugin1-261010_100001.fxp", false]);

// Backups are trimmed to five, and the states none of them names are swept.
(4..9).do { |i|
    sa.writeSound(kept, "kept", true, backups, { }, true, "26101" ++ "0_10000" ++ i);
    run.(sa);
};
~tEq.("the newest five backups are kept", (backups +/+ "*.json").pathMatch.collect { |p| p.basename }.sort,
    (5..9).collect { |i| "261010_10000" ++ i ++ ".json" });
~tEq.("...and only the states the sound and those five name: the oldest are gone",
    (states +/+ "*").pathMatch.collect { |p| p.basename }.sort, (4..9).collect { |i| "plugin1-261010_10000" ++ i ++ ".fxp" });
~tAssert.("no half-written file is left beside the sound", (root +/+ "sa" +/+ "kept.json.tmp*").pathMatch.isEmpty);

// A sound saved under a name carries its own copy of the state.
got = nil;
sa.writeSound(root +/+ "sa" +/+ "sounds" +/+ "warm.json", "Warm", false, nil, { |ok, why, snd| got = [ok, why] }, true, "261010_100010");
~tEq.("a sound saved under a name, without its states, gets its own copy of the state it names",
    [got, MegaFiles.readText(root +/+ "sa" +/+ "sounds" +/+ "warm.states" +/+ "plugin1-261010_100009.fxp"),
        MegaSASound.read(root +/+ "sa" +/+ "sounds" +/+ "warm.json").name],
    [[true, nil], MegaFiles.readText(states +/+ "plugin1-261010_100009.fxp"), "Warm"]);

// ---- writes that must not lose a state --------------------------------------------------
// Two writes in one second share a stamp.
before = MegaFiles.readText(kept);
sa.writeSound(kept, "kept", true, backups, { }, true, "261010_100020");
run.(sa);
sa.writeSound(kept, "kept", true, backups, { }, true, "261010_100020");
run.(sa);
~tEq.("two writes in one second: the backup is the file before the first, not written over by the second",
    MegaFiles.readText(backups +/+ "261010_100020.json"), before);
~tEq.("...each write's state had a file of its own; the first's, which nothing names any more, is swept",
    [File.exists(states +/+ "plugin1-261010_100020.fxp"), MegaSASound.read(kept).device(\plugin1)[\state][\file],
        File.exists(states +/+ "plugin1-261010_100020-2.fxp")],
    [false, "plugin1-261010_100020-2.fxp", true]);
// The sweep runs only after a write that wrote a new state.
File.use(states +/+ "stray.fxp", "w", { |f| f.write("nobody names me") });
sa.writeSound(kept, "kept", false, backups, { }, true, "261010_100021");
~tEq.("a write without its states sweeps nothing: it made no state to orphan", File.exists(states +/+ "stray.fxp"), true);
sa.writeSound(kept, "kept", true, backups, { }, true, "261010_100022");
run.(sa);
~tEq.("...the next one with them does", File.exists(states +/+ "stray.fxp"), false);
// What a device names now is spared, whatever the sound being swept for says.
File.use(states +/+ "plugin1-live.fxp", "w", { |f| f.write("on its way") });
before = sa.device(\plugin1).state;
sa.device(\plugin1).state = (kind: \program, file: "plugin1-live.fxp", path: states +/+ "plugin1-live.fxp");
sa.prSweepStates(states, MegaSASound.default(nil), nil);
~tEq.("the sweep spares the state a device names now (a save on its way has written its own)",
    [File.exists(states +/+ "plugin1-live.fxp"), (states +/+ "*.fxp").pathMatch.size], [true, 1]);
// A state named but on disk no more, the plugin open: said, nothing written.
sa.device(\plugin1).state = (kind: \program, file: "plugin1-gone.fxp", path: root +/+ "elsewhere" +/+ "plugin1-gone.fxp");
text = MegaFiles.readText(kept);
got = nil;
sa.writeSound(kept, "kept", false, backups, { |ok, why| got = [ok, why] }, true, "261010_100023");
~tEq.("a sound that would name a state that is on disk no more is not written, and says how to mend it",
    [got[0], got[1].contains("on disk no more"), got[1].contains("stop the loop"), MegaFiles.readText(kept) == text], [false, true, true, true]);
got = nil;
sa.writeSound(kept, "kept", true, backups, { |ok, why| got = [ok, why] }, true, "261010_100024");
run.(sa);
~tEq.("...with its states, the plugin writes a new one and all is well", [got, File.exists(sa.device(\plugin1).state[\path])], [[true, nil], true]);
// A file from a newer megalooper is never written over, under any name.
future = root +/+ "sa" +/+ "sounds" +/+ "future.json";
File.use(future, "w", { |f| f.write("{\"format\": \"megalooper sound\", \"version\": 9, \"tracks\": [], \"more\": true}") });
text = MegaFiles.readText(future);
got = nil;
sa.writeSound(future, "future", true, nil, { |ok, why| got = [ok, why] }, true, "261010_100025");
run.(sa);
~tEq.("a sound saved over one from a newer megalooper is refused: that file stays, and no state is written for it",
    [got[0], got[1].contains("newer megalooper"), MegaFiles.readText(future), File.exists(MegaSASound.statesDirFor(future))], [false, true, text, false]);
File.delete(future);
// Recalled while the plugin is not open, a sound keeps its own state when saved back.
warm = root +/+ "sa" +/+ "sounds" +/+ "warm.json";
target = MegaSASound.read(warm);
plug[\state] = \failed;
got = nil;
sa.applySound(target, { |ok, notes| got = [ok, notes] });
~tEq.("a recall while the plugin is not open: no state is loaded, but its device names the sound's own",
    [got[0], got[1].size, got[1][0].asString.contains("failed"), sa.device(\plugin1).state], [true, 1, true, (kind: \program, file: target.device(\plugin1)[\state][\file],
        path: MegaSASound.statesDirFor(warm) +/+ target.device(\plugin1)[\state][\file])]);
plug[\state] = \opening;
sa.device(\plugin1).state = (kind: \program, file: "handed.fxp", path: "/abs/x/handed.fxp");
got = nil;
sa.applySound(target, { |ok, notes| got = [ok, notes] });
~tEq.("a recall while the plugin is still opening leaves its device naming the state it opens with, and says so",
    [got[0], got[1].size, got[1][0].asString.contains("opening"), sa.device(\plugin1).state[\file]], [true, 1, true, "handed.fxp"]);
plug[\state] = \failed;
sa.applySound(target, { });
sa.writeSound(warm, "Warm", true, nil, { }, true, "261010_100026");
~tEq.("...saved back, it still names that state, and the file is still there",
    [MegaSASound.read(warm).device(\plugin1)[\state][\file], File.exists(sa.device(\plugin1).state[\path])],
    [target.device(\plugin1)[\state][\file], true]);
plug[\state] = \open;

// ---- Keep's mark ---------------------------------------------------------------------
~tEq.("before anything is kept there is no mark", sa.dirty, false);
// Keep's mark is the sound that was written, not the chains as they stand by then.
got = sa.sound;
sa.setParam(\delay2, \delayMix, 0.33);
sa.markKept(got);
~tEq.("Keep's mark is the sound it is given: a knob moved since stays unkept", sa.dirty, true);
sa.setParam(\delay2, \delayMix, 0.7);
sa.markKept;
~tEq.("kept, the chains are not dirty", sa.dirty, false);
sa.setFx(\shifter, true);
sa.setFx(\shifter, false);
sa.toggleFx(\echo);
~tEq.("a footswitch is no unkept edit", sa.dirty, false);
sa.setParam(\delay2, \delayMix, 0.1);
~tEq.("a setting is", sa.dirty, true);
sa.setParam(\delay2, \delayMix, 0.7);
~tEq.("...set back, it is not", sa.dirty, false);
sa.insertDevice(\loop, nil, \saturator);
~tEq.("an edit is", sa.dirty, true);
sa.undo;
~tEq.("...undone, it is not", sa.dirty, false);

// ---- a recall with the same devices ----------------------------------------------------
target = MegaSASound.parse(sa.sound("target").fileString);
target.statesDir = states;
target.device(\delay2)[\settings].put(\delayMix, 0.2);
target.device(\echo)[\settings].put(\echoMix, 0.9);
target.device(\echo).put(\on, false);
target.device(\shifter).put(\name, "Octaver");
File.use(states +/+ "plugin1-other.fxp", "w", { |f| f.write("another state") });
target.device(\plugin1).put(\state, (kind: \program, file: "plugin1-other.fxp"));
before = [stub[\bundles].size, sa.canUndo, sa.fx(\echo)];
got = nil;
said = heard.(sa, { n = sa.applySound(target, { |ok, notes| got = [ok, notes] }) });
~tEq.("a recall with the same devices answers true, and moves no synth", [n, stub[\bundles].size - before[0]], [true, 0]);
~tEq.("...each setting that differs goes to its own device",
    [~tLastSet.(sa, sa.fxNode(\delay2), \delayMix), ~tLastSet.(sa, sa.fxNode(\echo), \echoMix), sa.param(\delay2, \delayMix), sa.param(\echo, \echoMix)],
    [0.2, 0.9, 0.2, 0.9]);
~tEq.("...a name too, said as a rename", [sa.device(\shifter).name, said.select { |x| x[0] == \chain }.collect { |x| x[2] }], ["Octaver", [\rename]]);
~tEq.("...no switch is flipped, and undo is as it was", [sa.fx(\echo), sa.canUndo], [before[2], before[1]]);
~tEq.("...the plugin's state waits for its job", got, nil);
run.(sa);
~tEq.("...then loads, and the action gets true",
    [got, plug[\loaded], sa.device(\plugin1).state[\file]], [[true, []], states +/+ "plugin1-other.fxp", "plugin1-other.fxp"]);

// ---- a recall that changes the chains ----------------------------------------------------
target = MegaSASound.default("BIAS FX 2");
got = nil;
said = heard.(sa, { n = sa.applySound(target, { |ok, notes| got = [ok, notes] }) });
~tEq.("a recall of other chains: the chains are the sound's, in its order",
    [n, sa.guitarChain.ids, sa.loopChain.ids], [true, MegaSAFx.guitarKeys ++ [\plugin1], MegaSAFx.loopKeys]);
~tEq.("...on the server too", [kids.(stub, sa.guitarChain), kids.(stub, sa.loopChain)], [want.(sa.guitarChain), want.(sa.loopChain)]);
~tEq.("...the plugin is the same one, never closed", [sa.guitarPlugin === plug, plug[\opened]], [true, 1]);
~tEq.("...a device it brings is made with the sound's switch and settings",
    [sa.fx(\delay), ~tStartArgs.(stub, sa.fxNode(\delay))[\delayOn], ~tStartArgs.(stub, sa.fxNode(\delay))[\delayMix]],
    [false, 0, MegaSAFx.param(\delayMix)[\spec].default]);
~tEq.("...said as \\chain \\recall for each chain; undo starts anew",
    [said.select { |x| (x[0] == \chain) and: { x[2] == \recall } }.collect { |x| x[1] }, sa.canUndo, sa.canRedo], [[\guitar, \loop, \drums], false, false]);
~tEq.("...the ids' marks never go down: after delay3 came and went, the next Delay is delay4", sa.nextIds[\delay], 4);
~tEq.("...and the sound had no state to load", got, [true, []]);

// A sound without the plugin parks it; one with it brings it back.
n = sa.fxNode(\plugin1).nodeID;
sa.applySound(MegaSASound.default(nil), { });
~tEq.("a recall of a sound with no plugin parks it, still open",
    [sa.guitarChain.ids, sa.limboDevices.collect(_.id), sa.guitarPlugin, plug[\state]], [MegaSAFx.guitarKeys, [\plugin1], nil, \open]);
sa.applySound(MegaSASound.default("BIAS FX 2"), { });
~tEq.("...and a recall of one with it brings it back, in its own synth",
    [sa.guitarChain.ids.last, sa.fxNode(\plugin1).nodeID, sa.guitarPlugin === plug, sa.limboDevices], [\plugin1, n, true, []]);
~tEq.("...the server's chain the model's", kids.(stub, sa.guitarChain), want.(sa.guitarChain));

// A parked plugin a sound lists on the loop chain comes back there.
sa.applySound(MegaSASound.default(nil), { });
target = MegaSASound.default(nil);
target.track(\loop).put(\devices, target.devices(\loop) ++ [(id: \plugin1, type: \plugin, name: "BIAS FX 2", on: true, layout: [1, 1])]);
got = nil;
sa.applySound(target, { |ok, notes| got = notes });
~tEq.("a parked plugin a sound lists on the loop chain comes back there, in its own synth, with nothing to say",
    [sa.loopChain.ids, sa.limboDevices.collect(_.id), got.size, sa.fxNode(\plugin1).nodeID, sa.device(\plugin1).plugin === plug],
    [MegaSAFx.loopKeys ++ [\plugin1], [], 0, n, true]);
sa.applySound(MegaSASound.default("BIAS FX 2"), { });
~tEq.("(and back on the guitar's with a sound that has it there)", sa.guitarChain.ids.last, \plugin1);

// What a recall leaves out, it says.
stub[\options].memSize = ((sa.memoryUsed + MegaSA.memReserve) / 1024).ceil.asInteger + 1;
target = MegaSASound.parse(sa.sound("more").fileString);
target.track(\guitar).put(\devices, target.devices(\guitar) ++ [MegaSASound.deviceOfType(\delay9, \delay)]);
got = nil;
sa.applySound(target, { |ok, notes| got = [ok, notes] });
stub[\options].memSize = 65536;
~tEq.("a device there is no memory for is left out, and said", [sa.device(\delay9), got[0], got[1].size, got[1][0].contains("MB")], [nil, true, 1, true]);
m = ~tMegaSA.(nil, nil, nil, MegaSASound.default(nil));
Routine { m.attachLooper(~tLooper.()) }.next;
got = nil;
m.applySound(MegaSASound.default("BIAS FX 2"), { |ok, notes| got = [ok, notes] });
~tEq.("a plugin a recall cannot open here keeps its place, empty, and it is said: the rest is recalled, and the sound still has it",
    [m.guitarChain.ids, got[0], got[1].size, got[1][0].contains("not among this Mac's plugins"), m.device(\plugin1).plugin,
        m.sound.device(\plugin1) !? { |x| x[\name] }],
    [MegaSAFx.guitarKeys ++ [\plugin1], true, 1, true, nil, "BIAS FX 2"]);
m.free;
srv = ~tCountIds.(~tStubServer.());
m = MegaSA(srv, 0, 0);
m.instVarAt(\builder) !? { |x| x.stop };
srv[\defaultGroup] = Group.basicNew(srv, 1);
srv[\options].memSize = 65536;
Routine { m.prBuild }.next;
said = heard.(m, { n = m.applySound(MegaSASound.default(nil).named("x"), { }) });
~tEq.("before the Looper is attached, a recall of the same devices goes through", n, true);
target = MegaSASound.default(nil);
target.track(\loop).put(\devices, target.devices(\loop).reverse);
said = heard.(m, { n = m.applySound(target, { }) });
~tEq.("...one that changes the chains is refused, and says so: the loop's is not built",
    [n, said.collect(_.first), m.loopChain.ids], [false, [\refused], MegaSAFx.loopKeys]);
m.free;

// ---- the plugin's state jobs ---------------------------------------------------------------
// One at a time, in order. A save is never dropped; a load still waiting is
// replaced by a later one.
order = List.new;
late = List.new;
plug[\loadState] = { |self, kind, file, action| order.add([\load, file.basename]); late.add(action) };
plug[\saveState] = { |self, kind, file, action| order.add([\save, file.basename]); late.add(action) };
got = List.new;
sa.prStateJob(\load, \program, "/x/a.fxp", { |ok| got.add([\a, ok]) });
sa.prStateJob(\load, \program, "/x/b.fxp", { |ok| got.add([\b, ok]) });
sa.prStateJob(\save, \program, "/x/s.fxp", { |ok| got.add([\s, ok]) });
sa.prStateJob(\load, \program, "/x/c.fxp", { |ok| got.add([\c, ok]) });
~tEq.("a load asked for while another waits replaces it at once; the save stays", got.asArray, [[\b, false]]);
~tEq.("the guitar is held while jobs run", sa.held(\guitar), [\bank]);
4.do { run.(sa); late.pop !? { |f| f.value(plug, true) } };
run.(sa);
~tEq.("the jobs run one at a time, in the order asked: the first load, the save, the last load",
    [order.asArray, got.asArray], [[[\load, "a.fxp"], [\save, "s.fxp"], [\load, "c.fxp"]], [[\b, false], [\a, true], [\s, true], [\c, true]]]);
~tEq.("...and then the guitar is let go", sa.held(\guitar), []);
sa.free;
};

~tRemoveTree.(root);
~tAssert.("the scratch folder is gone again", File.exists(root).not);
}.value;
