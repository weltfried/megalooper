// What a boot does with Megalooper SA's sound (scripts/setup-sa.scd,
// docs/dev/device-chains.md phase 3): the kept sound made once from the files of
// before the chains, read before MegaSA is built, Start with this, the recovery
// file, sounds under a name, and a type's variations on any device of it.
// Your Application Support folder and the repo's presets are never touched:
// both are scratch folders here.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-sa-sounds");

{
var scripts = thisProcess.nowExecutingPath.dirname.dirname;
var vst = \VSTPlugin.asClass;
var root = ~tTempPath.("sa-sounds"), old = root +/+ "old-biasfx";
var was = (root: ~midiUserRootOverride, sync: ~midiWriteSync, megaSA: ~megaSA, looper: ~looper, refused: ~saKeptRefused);
var bankDir, kept, states, text, got, sound, read, sa, plug, stub, run, d, n, before, fresh, settings, ctx, logged, line, m;

if(~saMigrate.isNil) { (scripts +/+ "setup-sa.scd").load };
bankDir = ~saGuitarBankDir;
~midiUserRootOverride = root +/+ "user";
~midiWriteSync = true;
~saGuitarBankDir = { old };
~megaSA = nil;
~looper = nil;
~saKeptRefused = nil;
kept = ~saKeptPath.();
states = MegaSASound.statesDirFor(kept);
// A fresh user folder for the next case.
fresh = { ~tRemoveTree.(root +/+ "user"); ~tRemoveTree.(old); File.mkdir(old) };
run = { |megaSA| megaSA.instVarAt(\bankRoutine) !? { |r| 12.do { r.next } } };
MegaSA.loadSynthDefs;

~tAssert.("the sound's files are under the scratch root here, never your own folder",
    kept.beginsWith(PathName.tmp) and: { ~saSoundsDir.().beginsWith(root) } and: { ~saRecoveryPath.().beginsWith(root) }
        and: { ~saKeptBackupDir.().beginsWith(root) }, kept);
~tEq.("...in its sa folder", [kept, ~saSoundsDir.(), ~saRecoveryPath.(), ~saKeptBackupDir.()].collect { |p| p.drop((root +/+ "user").size + 1) },
    ["sa/kept.json", "sa/sounds", "sa/recovery.json", "sa/backups/kept"]);

// ---- the migration -------------------------------------------------------------------
// Nothing from before, no plugin: megalooper's default chains.
fresh.();
got = ~saMigrate.(nil);
sound = MegaSASound.read(kept);
~tEq.("with nothing kept before and no plugin, the kept sound is megalooper's default chains",
    [got, sound.isString, sound.devices(\guitar).collect { |x| x[\id] }, sound.devices(\loop).collect { |x| x[\id] }, sound.name],
    [kept, false, MegaSAFx.guitarKeys, MegaSAFx.loopKeys, "kept"]);
~tAssert.("...every effect off at its default", sound.devices.every { |x| x[\on].not
    and: { MegaSAFx.paramsOf(x[\type]).every { |p| x[\settings][p[\name]] == p[\spec].default } } });
text = MegaFiles.readText(kept);
~tEq.("run again it does nothing: the kept sound being there is the marker", [~saMigrate.("BIAS FX 2"), MegaFiles.readText(kept)], [nil, text]);

// The settings and the bank kept before the chains.
fresh.();
settings = MegaSAFx.defaults;
settings.put(\filterFreq, 1238.17);
settings.put(\echoMix, 0.42);
File.use(old +/+ "current.scd", "w", { |f| f.write("( version: 1, name: \"current\", savedAt: \"261009_133721\", filterFreq: 1238.17, echoMix: 0.42, delayFeedback: 99, wahWah: 3 )") });
File.use(old +/+ "current.fxb", "w", { |f| f.write("kept bank") });
File.use(old +/+ "guitar-rig-model-t-no-gain.fxb", "w", { |f| f.write("live bank") });
got = ~saMigrate.("BIAS FX 2");
sound = MegaSASound.read(kept);
~tEq.("what was kept before the chains becomes the kept sound: the default chains with the plugin",
    [got, sound.devices(\guitar).collect { |x| x[\id] }, sound.devices(\loop).collect { |x| x[\id] }],
    [kept, MegaSAFx.guitarKeys ++ [\plugin1], MegaSAFx.loopKeys]);
~tEq.("...with its settings, each held to its range, the rest at their defaults",
    [sound.device(\filter)[\settings][\filterFreq], sound.device(\echo)[\settings][\echoMix], sound.device(\delay)[\settings][\delayFeedback],
        sound.device(\delay)[\settings][\delayMix]],
    [1238.17, 0.42, MegaSAFx.constrain(\delayFeedback, 99), MegaSAFx.param(\delayMix)[\spec].default]);
~tEq.("...its plugin's state the kept bank, copied beside the sound",
    [sound.device(\plugin1)[\state], MegaFiles.readText(states +/+ "current.fxb"), sound.statePath(sound.device(\plugin1))],
    [(kind: \bank, file: "current.fxb"), "kept bank", states +/+ "current.fxb"]);
~tEq.("...and the old files where they were, as they were",
    [MegaFiles.readText(old +/+ "current.fxb"), File.exists(old +/+ "current.scd"), File.exists(old +/+ "guitar-rig-model-t-no-gain.fxb")],
    ["kept bank", true, true]);
text = MegaFiles.readText(kept);
File.use(old +/+ "current.fxb", "w", { |f| f.write("another bank") });
~tEq.("the migration run twice takes effect once", [~saMigrate.("BIAS FX 2"), MegaFiles.readText(kept), MegaFiles.readText(states +/+ "current.fxb")],
    [nil, text, "kept bank"]);

// Only the Live export; and settings that do not read.
fresh.();
File.use(old +/+ "guitar-rig-model-t-no-gain.fxb", "w", { |f| f.write("live bank") });
~saMigrate.("BIAS FX 2");
sound = MegaSASound.read(kept);
~tEq.("with only the Live export, the default settings and that bank",
    [sound.device(\plugin1)[\state][\file], MegaFiles.readText(states +/+ "guitar-rig-model-t-no-gain.fxb"),
        sound.device(\filter)[\settings][\filterFreq]],
    ["guitar-rig-model-t-no-gain.fxb", "live bank", MegaSAFx.param(\filterFreq)[\spec].default]);
fresh.();
File.use(old +/+ "current.scd", "w", { |f| f.write("( version: 1, oops") });
File.use(old +/+ "current.fxb", "w", { |f| f.write("kept bank") });
~tCheck.("settings that do not parse do not stop the migration", { ~saMigrate.("BIAS FX 2") });
sound = MegaSASound.read(kept);
~tEq.("...the default settings then, and still the bank", [sound.device(\filter)[\settings][\filterFreq], sound.device(\plugin1)[\state][\file]],
    [MegaSAFx.param(\filterFreq)[\spec].default, "current.fxb"]);
fresh.();
File.use(old +/+ "current.scd", "w", { |f| f.write("( version: 99, filterFreq: 1238.17 )") });
~saMigrate.(nil);
~tEq.("settings from a newer preset format are not taken", MegaSASound.read(kept).device(\filter)[\settings][\filterFreq],
    MegaSAFx.param(\filterFreq)[\spec].default);
fresh.();
File.use(old +/+ "current.fxb", "w", { |f| f.write("kept bank") });
~saMigrate.(nil);
~tEq.("with no plugin on the rig, no plugin device and no bank copied", [MegaSASound.read(kept).device(\plugin1), File.exists(states)], [nil, false]);

// ---- the kept sound at boot ------------------------------------------------------------
fresh.();
~tEq.("nothing kept: nothing read, nothing refused", ~saReadKept.(), ());
~saMigrate.(nil);
read = ~saReadKept.();
~tEq.("a kept sound reads", [read[\sound].class, read[\refused], read[\sound].statesDir], [MegaSASound, nil, states]);
text = MegaFiles.readText(kept).replace("\"version\": 1", "\"version\": 2");
File.use(kept, "w", { |f| f.write(text) });
read = ~saReadKept.();
~tAssert.("one from a newer megalooper is refused whole: no sound, and why", read[\sound].isNil and: { read[\refused].isString }
    and: { read[\refused].contains("newer megalooper") }, read.asString);
// Unreadable, with backups: the newest that reads.
File.mkdir(~saKeptBackupDir.());
File.use(~saKeptBackupDir.() +/+ "261010_100001.json", "w", { |f| f.write(MegaSASound.default(nil, "older").fileString) });
File.use(~saKeptBackupDir.() +/+ "261010_100002.json", "w", { |f| f.write(MegaSASound.default(nil, "newer").fileString) });
File.use(~saKeptBackupDir.() +/+ "261010_100003.json", "w", { |f| f.write("{ torn") });
File.use(kept, "w", { |f| f.write("{\"format\": \"megalooper sound\", \"tracks\": [") });
read = ~saReadKept.();
~tEq.("a kept sound that does not read falls back to the newest backup that does, its states the kept folder's",
    [read[\sound] !? (_.name), read[\refused], read[\sound] !? (_.statesDir)], ["newer", nil, states]);
File.delete(kept);
read = ~saReadKept.();
~tEq.("a kept sound that is missing, with backups there, starts from the newest that reads", read[\sound] !? (_.name), "newer");
~tEq.("...and the migration leaves it at that: a backup is a marker too", [~saMigrate.(nil), File.exists(kept)], [nil, false]);
File.use(kept, "w", { |f| f.write("{\"format\": \"megalooper sound\", \"tracks\": [") });
~tRemoveTree.(~saKeptBackupDir.());
~tEq.("...with no backup that reads, megalooper's own chains", ~saReadKept.(), ());

if(vst.isNil) { ~tSkip.("Start with this, the recovery file and sounds under a name", "VSTPlugin is not installed here") } {
// ---- Start with this ---------------------------------------------------------------------------
fresh.();
File.use(old +/+ "current.fxb", "w", { |f| f.write("kept bank") });
~saMigrate.("BIAS FX 2");
read = ~saReadKept.();
plug = ~tFakePlugin.(\open);
stub = ~tStubServer.();
sa = ~tMegaSA.(stub, plug, nil, read[\sound]);
Routine { sa.attachLooper(~tLooper.()) }.next;
sa.statesAllowed = { ~saLoopStopped.() };
sa.markKept;
~megaSA = sa;
~saWatchRecovery.();
~tEq.("built from the kept sound, the plugin opens with the migrated bank",
    [plug[\openedWith], sa.guitarChain.ids.last, sa.dirty], [(kind: \bank, path: states +/+ "current.fxb"), \plugin1, false]);
sa.setParam(\filter, \filterFreq, 900);
~tEq.("(a setting moved: unkept)", sa.dirty, true);
got = nil;
~saKeepSound.({ |ok, why, withStates| got = [ok, why, withStates] });
run.(sa);
sound = MegaSASound.read(kept);
~tEq.("Start with this, the loop stopped: the chains and the plugin's state are kept",
    [got, sound.device(\filter)[\settings][\filterFreq], sound.device(\plugin1)[\state][\kind],
        File.exists(sound.statePath(sound.device(\plugin1))), sa.dirty],
    [[true, nil, true], 900, \program, true, false]);
~tEq.("...the sound kept before is the backup, and the bank it names is still there",
    [(~saKeptBackupDir.() +/+ "*.json").pathMatch.size, File.exists(states +/+ "current.fxb")], [1, true]);
// While the loop plays: the text only.
~looper = (state: \playing);
before = sound.device(\plugin1)[\state][\file];
sa.setParam(\filter, \filterFreq, 700);
got = nil;
~saKeepSound.({ |ok, why, withStates| got = [ok, why, withStates] });
sound = MegaSASound.read(kept);
~tEq.("Start with this while the loop plays: the chains are kept, the plugin's state stays the one last kept, and the action is told",
    [got, sound.device(\filter)[\settings][\filterFreq], sound.device(\plugin1)[\state][\file], plug[\saves]], [[true, nil, false], 700, before, 1]);
~looper = (state: \stopped);
~tEq.("stopped counts as stopped; recording does not", [~saLoopStopped.(), { ~looper = (state: \recording); ~saLoopStopped.() }.value,
    { ~looper = (state: \empty); ~saLoopStopped.() }.value, { ~looper = nil; ~saLoopStopped.() }.value], [true, false, true, true]);
// A kept sound from a newer megalooper is never written over.
~saKeptRefused = "it is from a newer megalooper (version 2; this one reads 1)";
text = MegaFiles.readText(kept);
got = nil;
~saKeepSound.({ |ok, why, withStates| got = [ok, why.contains("newer")] });
~tEq.("Start with this writes nothing over a kept sound from a newer megalooper", [got, MegaFiles.readText(kept)], [[false, true], text]);
~saKeptRefused = nil;
~megaSA = nil;
got = nil;
~saKeepSound.({ |ok, why| got = [ok, why.isString] });
~tEq.("...nor without SA running", got, [false, true]);
~megaSA = sa;

// Kept without the rig's plugin, the next boot would host none: said, and mended on disk.
if(File.exists(~saGuitarPlugin)) {
    ~tEq.("with the plugin in the guitar chain, nothing is amiss", [~saPluginLeftOut.(), ~saRestorePlugin.()], [false, false]);
    sa.removeDevice(\plugin1);
    got = nil;
    ~saKeepSound.({ |ok, why, withStates, bare| got = [ok, bare] });
    ~tEq.("Start with this with the plugin removed keeps the chains, and says the next boot hosts none",
        [got, MegaSASound.read(kept).device(\plugin1)], [[true, true], nil]);
    ~tEq.("~saRestorePlugin puts it back into the kept sound on disk, from the one kept before, its state with it",
        [~saRestorePlugin.(), MegaSASound.read(kept).devices(\guitar).last[\id], MegaSASound.read(kept).device(\plugin1)[\state].notNil,
            File.exists(MegaSASound.read(kept).statePath(MegaSASound.read(kept).device(\plugin1)))],
        [true, \plugin1, true, true]);
    ~tEq.("...changing nothing that runs, and only once", [sa.guitarPlugin, sa.limboDevices.collect(_.id), ~saRestorePlugin.()], [nil, [\plugin1], false]);
    sa.undo;
    got = nil;
    ~saKeepSound.({ |ok, why, withStates, bare| got = [ok, bare] });
    run.(sa);
    ~tEq.("(the plugin back by undo, and kept so)", [got, sa.guitarChain.ids.last, sa.dirty], [[true, false], \plugin1, false]);
} { ~tSkip.("Start with this without the rig's plugin, and ~saRestorePlugin", "no plugin at " ++ ~saGuitarPlugin) };

// Recover's offer is over before its answer is given: the pane paints its tile from it.
~saRecovery = sa.sound("recovery");
got = nil;
~saRecallRecovery.({ |ok, notes| got = [ok, ~saRecovery.isNil] });
~tEq.("Recover answers once its offer is over", got, [true, true]);
~saRecoveryPending = true;
~saWatchRecovery.();
~tEq.("a new watch starts with no write pending: a Cmd-period drops the one waited on", ~saRecoveryPending, false);

// ---- the recovery file -----------------------------------------------------------------------
~tEq.("with the chains as kept there is no recovery file", File.exists(~saRecoveryPath.()), false);
d = sa.insertDevice(\loop, nil, \delay);
sound = MegaSASound.read(~saRecoveryPath.());
~tEq.("a chain edit that leaves the chains unkept writes them to the recovery file",
    [sound.isString, sound.devices(\loop).collect { |x| x[\id] }.last, MegaSASound.read(kept).device(d.id)], [false, d.id, nil]);
sa.undo;
~tEq.("...edited back to what is kept, the file goes", File.exists(~saRecoveryPath.()), false);
sa.moveDevice(\echo, \loop, 2);
~tEq.("...a move writes it again", File.exists(~saRecoveryPath.()), true);
got = nil;
~saKeepSound.({ |ok| got = ok });
run.(sa);
~tEq.("...and Start with this, which keeps them, removes it", [got, File.exists(~saRecoveryPath.()), sa.dirty], [true, false, false]);
// A boot that finds one.
sa.insertDevice(\guitar, 0, \redux);
text = MegaFiles.readText(~saRecoveryPath.());
sa.undo;
File.mkdir(~saRecoveryPath.().dirname);
File.use(~saRecoveryPath.(), "w", { |f| f.write(text) });
got = ~saRecoveryOffer.();
~tEq.("a boot that finds chain edits not kept offers them, and loads nothing",
    [got.class, ~saRecovery === got, sa.guitarChain.ids.first, got.statesDir], [MegaSASound, true, \shifter, states]);
n = nil;
before = plug[\loaded];
~saRecallRecovery.({ |ok, notes| n = [ok, notes] });
~tEq.("...taken, the chains are the recovered ones, at once: the plugin's own sound is left as it is",
    [sa.guitarChain.ids.first, sa.guitarChain.ids.size, n !? (_.first), ~saRecovery, plug[\loaded] == before, sa.held(\guitar)],
    [\redux2, MegaSAFx.guitarKeys.size + 2, true, nil, true, []]);
~tEq.("...and with nothing offered there is nothing to take", ~saRecallRecovery.({ }), false);
// One that is the chains as they stand is no offer.
File.use(~saRecoveryPath.(), "w", { |f| f.write(sa.sound("recovery").fileString) });
~tEq.("a recovery file that is the chains as they stand is deleted, not offered", [~saRecoveryOffer.(), File.exists(~saRecoveryPath.())], [nil, false]);
File.use(~saRecoveryPath.(), "w", { |f| f.write("{ torn") });
~tEq.("...so is one that does not read", [~saRecoveryOffer.(), File.exists(~saRecoveryPath.())], [nil, false]);
// One from a newer megalooper is left as it is: not offered, not deleted, not written over.
text = "{\"format\": \"megalooper sound\", \"version\": 9, \"tracks\": [], \"more\": true}";
File.use(~saRecoveryPath.(), "w", { |f| f.write(text) });
~tEq.("a recovery file from a newer megalooper is not offered", [~saRecoveryOffer.(), ~saRecoveryRefused], [nil, true]);
sa.insertDevice(\loop, nil, \saturator);
~saRecoveryClear.();
~tEq.("...nor deleted, nor written over by an edit", MegaFiles.readText(~saRecoveryPath.()), text);
sa.undo;
File.delete(~saRecoveryPath.());
~tEq.("...moved away, edits are saved again, with no new boot", [{ sa.insertDevice(\loop, nil, \saturator); File.exists(~saRecoveryPath.()) }.value, ~saRecoveryRefused], [true, false]);
sa.undo;
// An offer that cannot be taken stays.
m = MegaSA(~tCountIds.(~tStubServer.()), 0, 0);
m.instVarAt(\builder) !? { |x| x.stop };
~megaSA = m;
~saRecovery = MegaSASound.default(nil);
~saRecovery.track(\loop).put(\devices, ~saRecovery.devices(\loop).reverse);
got = nil;
~tEq.("an offer that cannot be taken (a chain not built) stays an offer", [~saRecallRecovery.({ |ok| got = ok }), got, ~saRecovery.notNil], [false, false, true]);
m.free;
~megaSA = sa;
~saRecovery = nil;

// An edit after an offer is the answer: the offer is over.
File.use(~saRecoveryPath.(), "w", { |f| f.write(MegaSASound.default("BIAS FX 2").fileString) });
~saRecoveryOffer.();
d = sa.insertDevice(\loop, nil, \saturator);
~tEq.("an edit after an offer drops it: the file follows the chains again",
    [~saRecovery, MegaSASound.read(~saRecoveryPath.()).devices(\loop).collect { |x| x[\id] }.last], [nil, d.id]);

// ---- sounds under a name ----------------------------------------------------------------------
MegaFiles.alwaysSync = true;
~looper = nil;
~tEq.("an empty sounds folder lists nothing", sa.soundNames(~saSoundsDir.()), []);
before = sa.guitarChain.ids ++ sa.loopChain.ids;
got = nil;
sa.addDependant({ |o, what ... more| if([\soundSaved, \soundLoaded].includes(what)) { got = [what] ++ more } });
~tEq.("a sound saved under a name answers its slug", sa.saveSound(~saSoundsDir.(), "Warm Wah!"), "warm-wah");
run.(sa);
~tEq.("...written with the plugin's state, the loop being stopped, and said",
    [sa.soundNames(~saSoundsDir.()), got.keep(3), got[4], (~saSoundsDir.() +/+ "warm-wah.states" +/+ "*.fxp").pathMatch.size,
        MegaSASound.read(sa.soundPath(~saSoundsDir.(), "warm-wah")).name],
    [["warm-wah"], [\soundSaved, "warm-wah", true], true, 1, "Warm Wah!"]);
sa.applySound(MegaSASound.default("BIAS FX 2"), { });
run.(sa);
got = nil;
~tEq.("recalled, the chains are the saved ones again", [sa.loadSound(~saSoundsDir.(), "warm-wah"), sa.guitarChain.ids ++ sa.loopChain.ids], [true, before]);
run.(sa);
~tEq.("...and it says so once the plugin's state is in", got.keep(3), [\soundLoaded, "warm-wah", true]);
~tEq.("a sound that is not there is not recalled", sa.loadSound(~saSoundsDir.(), "nothing"), false);
File.use(~saSoundsDir.() +/+ "future.json", "w", { |f| f.write("{\"format\": \"megalooper sound\", \"version\": 9, \"tracks\": []}") });
before = sa.guitarChain.ids;
~tEq.("...nor one from a newer megalooper: nothing changes", [sa.loadSound(~saSoundsDir.(), "future"), sa.guitarChain.ids], [false, before]);
~tEq.("a sound deleted takes its states with it",
    [sa.deleteSound(~saSoundsDir.(), "warm-wah"), File.exists(~saSoundsDir.() +/+ "warm-wah.json"), File.exists(~saSoundsDir.() +/+ "warm-wah.states"),
        sa.deleteSound(~saSoundsDir.(), "warm-wah")],
    [true, false, false, false]);
sa.releaseDependants;
MegaFiles.alwaysSync = false;

// ---- a type's variations, on any device of it ---------------------------------------------------
~saWatchRecovery.();
d = sa.copyDevice(\delay) ?? { sa.insertDevice(\guitar, nil, \delay) };
before = sa.fxParam(\delayTimeR);
~tEq.("a variation goes to the device named, a further Delay too", [~saApplyVariation.(d.id, "short"), sa.param(d.id, \delayTimeR).round(0.0001),
    sa.fxParam(\delayTimeR)], [true, 0.0843, before]);
~tEq.("...the first Delay's by its own id, as before", [~saApplyVariation.(\delay, "short"), sa.fxParam(\delayTimeR).round(0.0001)], [true, 0.0843]);
~tEq.("...none for a device that is not there, or a name its type has not", [~saApplyVariation.(\nothing, "short"), ~saApplyVariation.(\delay, "no such")],
    [false, false]);

// ---- your own variations: saved, replaced, refused, deleted -----------------------------------------
{
    var got, said = { |ok, why| got = [ok, why] }, path = ~saUserVariationsFile.();
    ~saFxVariations = ~saLoadFxVariations.();
    ~tEq.("with none saved, a type's variations are the Live set's alone", ~saFxVariations[\delay].collect { |v| v[2] }.asSet.asArray, [false]);
    ~tAssert.("yours go to your folder's sa/fx-variations.json, never the repo's",
        path.beginsWith(root) and: { path.endsWith("sa/fx-variations.json") } and: { ~saFxVariationsFile.() != path }, path);
    sa.setParam(\delay, \delayMix, 0.25);
    sa.setParam(\delay, \delayTimeR, 0.6);
    ~saSaveVariation.(\delay, "  wide ", said);
    ~tEq.("Save variation keeps the device's settings under the name typed, trimmed", [got, File.exists(path)], [[true, \saved], true]);
    ~tEq.("...listed after the Live set's, as yours", ~saFxVariations[\delay].last.keep(1) ++ [~saFxVariations[\delay].last[2]], ["wide", true]);
    ~tEq.("...with every setting", ~saFxVariations[\delay].last[1].keys.asArray.sort, sa.device(\delay).settings.keys.asArray.sort);
    sa.resetFx(\delay);
    ~tEq.("recalling it puts every setting back", [~saApplyVariation.(\delay, "wide"), sa.fxParam(\delayMix), sa.fxParam(\delayTimeR).round(1e-6)],
        [true, 0.25, 0.6]);
    ~tEq.("...on a further Delay too", [~saApplyVariation.(d.id, "wide"), sa.param(d.id, \delayMix)], [true, 0.25]);
    sa.setParam(\delay, \delayMix, 0.5);
    ~saSaveVariation.(\delay, "wide", said);
    ~tEq.("saving under the same name replaces it", [got, ~saFxVariations[\delay].count { |v| v[0] == "wide" }, ~saFxVariations[\delay].last[1][\delayMix]],
        [[true, \replaced], 1, 0.5]);
    ~saSaveVariation.(\delay, "short", said);
    ~tEq.("a name the Live set's variations of the type use is refused", got, [false, "'short' is a variation from the Live set"]);
    ~saSaveVariation.(\delay, "   ", said);
    ~tEq.("...and no name", got, [false, "it needs a name"]);
    ~saSaveVariation.(\nothing, "x", said);
    ~tEq.("...and no device", got[0], false);
    ~saSaveVariation.(\shifter, "up", said);
    ~tEq.("an effect the Live set has no variations of gets yours", [got, ~saFxVariations[\shifter].collect { |v| v[0] }], [[true, \saved], ["up"]]);
    ~tEq.("the file reads back as saved, the Live set's first, then yours",
        [~saLoadFxVariations.()[\delay].select { |v| v[2] }.collect { |v| [v[0], v[1][\delayMix]] }, ~saLoadFxVariations.()[\delay].first[2]],
        [[["wide", 0.5]], false]);
    ~saDeleteVariation.(\delay, "wide", said);
    ~tEq.("Delete removes one of yours", [got[0], ~saFxVariations[\delay].any { |v| v[0] == "wide" }, ~saFxVariations[\shifter].size], [true, false, 1]);
    ~saDeleteVariation.(\delay, "short", said);
    ~tEq.("...never one of the Live set's", [got[0], ~saFxVariations[\delay].any { |v| v[0] == "short" }], [false, true]);
    ~saDeleteVariation.(\shifter, "up", said);
    ~tEq.("with the last one deleted the file holds none", [got[0], ~saOwnVariations.().values.every(_.isEmpty), ~saLoadFxVariations.()[\shifter]],
        [true, true, nil]);
}.value;
// ---- a session's header and its log ---------------------------------------------------------------
// The header carries the sound's name, both chains with every switch and
// setting, each chain's delay and the build; the log every footswitch and
// chain edit.
~looper = ~tLooper.();
~saBuildId = "git test-build";
~looper.sessionExtras = { ~saSessionExtras.() };
ctx = ~looper.prSessionContext;
~tEq.("a session's header names the sound and the build, and says whether the chains are as kept",
    [ctx[\sound], ctx[\build], ctx[\soundKept]], [sa.soundName, "git test-build", sa.dirty.not]);
~tEq.("...and carries the four chains, a device each, in order",
    [ctx[\chains].collect { |c| c[\track] }, ctx[\chains].collect { |c| c[\devices].collect { |x| x[\id] } }],
    [[\guitar, \loop, \drums, \bass], [sa.guitarChain.ids, sa.loopChain.ids, sa.drumsChain.ids, sa.bassChain.ids]]);
d = ctx[\chains][0][\devices].detect { |x| x[\id] == \delay };
~tEq.("...each with its type, switch and every setting", [d[\type], d[\on], d[\settings]], [\delay, sa.fx(\delay), sa.device(\delay).settings]);
d = ctx[\chains][0][\devices].detect { |x| x[\type] == \plugin };
~tEq.("...the plugin with its layout and the file its state is in", [d[\layout], d[\state]], [[1, 1], sa.device(\plugin1).state[\file]]);
~tEq.("...and each chain's delay in seconds", [ctx[\lg], ctx[\ll]],
    [sa.guitarChain.latency(48000) / 48000, sa.loopChain.latency(48000) / 48000]);
~tAssert.("...beside what the Looper says itself", ctx[\threshold].notNil and: { ctx[\state] == \empty } and: { ctx[\fallback].notNil });
line = MegaFiles.parseObject(LooperSessionRecorder.json(ctx));
~tAssert.("the header is JSON that reads, the chains a list in it", line.isKindOf(MegaJsonObject) and: { line.at("chains").isKindOf(Array) }
    and: { line.at("chains")[0].at("devices").size == sa.guitarChain.devices.size }, line.asString);
~looper.sessionExtras = { (state: \hijacked, threshold: -1, more: 7) };
ctx = ~looper.prSessionContext;
~tEq.("what is added never replaces a field of the Looper's own", [ctx[\state], ctx[\threshold] == -1, ctx[\more]], [\empty, false, 7]);
~looper.sessionExtras = { Error("extras on fire").throw };
~tAssert.("...and its failing costs the header nothing", { ~looper.prSessionContext[\state] == \empty }.value);
~looper.sessionExtras = { 17 };
~tAssert.("...nor does one that answers no Event", { ~looper.prSessionContext[\state] == \empty }.value);
~megaSA = nil;
~tEq.("without SA there is nothing to add", ~saSessionExtras.(), nil);
~megaSA = sa;
logged = List.new;
~looper.instVarPut(\sessionRec, (logEvent: { |self, ev, fields| logged.add([ev, fields]); true }));
~saWatchSession.();
sa.setFx(\delay, sa.fx(\delay).not);
d = sa.insertDevice(\loop, nil, \redux);
~tEq.("a footswitch goes to the session's log", logged[0], [\fx, (id: \delay, on: sa.fx(\delay))]);
~tEq.("...and a chain edit, with the chain's ids after it", logged[1],
    [\fxChain, (track: \loop, op: \insert, id: d.id, index: sa.loopChain.indexOf(d), ids: sa.loopChain.ids)]);
~saSessionController !? { |c| c.remove };
~saSessionController = nil;
n = logged.size;
sa.setFx(\delay, sa.fx(\delay).not);
~tEq.("...and nothing once the watch is taken off", logged.size, n);
~saBuildId = nil;
~tAssert.("the build is git's description of the checkout, or nothing", { var b = ~saBuild.(); b.isNil or: { b.beginsWith("git ") and: { b.size > 4 } } }.value);

~saRecoveryController !? { |c| c.remove };
~saRecoveryController = nil;
sa.free;
};

// Everything as it was.
~saGuitarBankDir = bankDir;
~midiUserRootOverride = was[\root];
~midiWriteSync = was[\sync];
~megaSA = was[\megaSA];
~looper = was[\looper];
~saKeptRefused = was[\refused];
~saRecovery = nil;
~tRemoveTree.(root);
~tAssert.("the scratch folder is gone again", File.exists(root).not);
}.value;
