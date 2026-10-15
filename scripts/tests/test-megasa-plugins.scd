// The plugin catalog (MegaSAPlugins; docs/dev/device-chains.md, phase 5): what
// the browser offers of what a scan found, which entry a sound's plugin
// names, the layout an entry is hosted in, the scan's message and command,
// and the scripts' rule that nothing is scanned while a loop plays. No
// server and no scan here: the scan itself is scripts/sa/nrt-plugin-scan.scd's.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-megasa-plugins");

{
var scripts = thisProcess.nowExecutingPath.dirname.dirname;
var root = ~tTempPath.("megasa-plugins");
var e = { |key, name, vendor, format, ins, outs, synth = false, bridged = false, uid = ""|
    (key: key, name: name, vendor: vendor, format: format, ins: ins, outs: outs, synth: synth, bridged: bridged,
        uid: uid, version: "1", path: "/abs/x/" ++ key)
};
var vst = \VSTPlugin.asClass;
var all, got, msg, saved, why, make, sound, fakes, m, run, heard, made, again, d, maker, amp, markers, waiting;

all = [
    e.("Amp", "Amp", "Acme", "vst2", 2, 2, false, false, "A001"),
    e.("Amp.vst3", "Amp", "Acme", "vst3", 2, 2, false, false, "A3"),
    e.("Old Verb", "Old Verb", "Acme", "vst2", 2, 2, false, true, "V001"),
    e.("Old Verb.vst3", "old verb", "ACME", "vst3", 2, 2, false, false, "V3"),
    e.("Intel Only", "Intel Only", "Past", "vst2", 1, 2, false, true, "I001"),
    e.("Piano", "Piano", "Keys", "vst3", 2, 2, true, false, "P3"),
    e.("Tone Gen", "Tone Gen", "Keys", "vst2", 0, 2, false, false, "T001"),
    e.("Surround", "Surround", "Wide", "vst3", 6, 6, false, false, "S3")
];

// ---- what the browser offers -------------------------------------------------------
got = MegaSAPlugins.offered(all);
~tEq.("the browser offers effects only: no instrument, nothing without an input",
    [got.any { |x| x[\key] == "Piano" }, got.any { |x| x[\key] == "Tone Gen" }], [false, false]);
~tEq.("of a plugin there as a VST3 and as a bridged VST2, the VST3 alone; a native VST2 stays beside its VST3",
    got.collect { |x| x[\key] }, ["Amp", "Amp.vst3", "Old Verb.vst3", "Intel Only", "Surround"]);
~tEq.("a bridged plugin with no other build is offered greyed, with the reason; the others have none, and the catalog is not written on",
    [got.detect { |x| x[\key] == "Intel Only" }[\why].isString, got.count { |x| x[\why].notNil }, all.any { |x| x[\why].notNil }],
    [true, 1, false]);

// ---- which entry a sound's plugin names ---------------------------------------------
~tEq.("a sound's plugin is found by its key in its format",
    MegaSAPlugins.find(all, (key: "Amp", format: "vst2"))[\uid], "A001");
~tEq.("...from the text a sound's file holds too",
    MegaSAPlugins.find(all, "{\"key\": \"Amp.vst3\", \"format\": \"vst3\", \"name\": \"Amp\"}")[\uid], "A3");
~tEq.("...by its uid when its key changed",
    MegaSAPlugins.find(all, (key: "Amp (moved)", format: "vst2", uid: "A001", name: "x", vendor: "y"))[\key], "Amp");
~tEq.("...by name, vendor and format when both changed",
    MegaSAPlugins.find(all, (key: "?", uid: "?", name: "Surround", vendor: "Wide", format: "vst3"))[\key], "Surround");
~tEq.("...never across formats: a VST2's state is not a VST3's",
    [MegaSAPlugins.find(all, (key: "?", uid: "?", name: "Surround", vendor: "Wide", format: "vst2")),
        MegaSAPlugins.find(all, (key: "Amp", format: "vst3", uid: "?", name: "?", vendor: "?")),
        MegaSAPlugins.find(all, (key: "?", format: "vst3", uid: "A001", name: "?", vendor: "?"))], [nil, nil, nil]);
~tEq.("one not installed here is not found; nor is nothing, nor text that is no object",
    [MegaSAPlugins.find(all, (key: "Gone", format: "vst2", uid: "G1", name: "Gone", vendor: "Nobody")),
        MegaSAPlugins.find(all, nil), MegaSAPlugins.find(all, "not json")], [nil, nil, nil]);
~tEq.("an empty uid matches nothing",
    MegaSAPlugins.find(all ++ [e.("No Uid", "No Uid", "N", "vst2", 2, 2)], (key: "?", uid: "", format: "vst2", name: "?", vendor: "?")), nil);
~tEq.("what a sound says of its plugin reads the same from its text and from MegaSAPlugin's answer",
    [MegaSAPlugins.identityOf("{\"key\": \"Amp\", \"uid\": \"A001\", \"more\": 3}"), MegaSAPlugins.identityOf((key: "Amp", uid: "A001", more: 3))],
    [(key: "Amp", uid: "A001"), (key: "Amp", uid: "A001")]);

// ---- the layout an entry is hosted in ----------------------------------------------
~tEq.("a plugin is hosted on its main busses, held to the chain's one or two channels",
    [[1, 2], [2, 2], [6, 6], [1, 1], [2, 0]].collect { |io| MegaSAPlugins.layoutOf((ins: io[0], outs: io[1])) },
    [[1, 2], [2, 2], [2, 2], [1, 1], [2, 1]]);
~tEq.("...each a layout MegaSAPlugin has a SynthDef for",
    [[1, 2], [6, 6], [2, 0], [1, 1]].every { |io| MegaSAPlugin.layouts.includesEqual(MegaSAPlugins.layoutOf((ins: io[0], outs: io[1]))) }, true);

// ---- no cache, no catalog -----------------------------------------------------------
~tEq.("with no scan yet there is no catalog, and nothing throws",
    [MegaSAPlugins.hasCache(root), MegaSAPlugins.read(root), MegaSAPlugins.hasCache(nil), MegaSAPlugins.read(nil)], [false, [], false, []]);

// ---- the scan -----------------------------------------------------------------------
if(vst.isNil) { ~tSkip.("the scan's message and score", "VSTPlugin is not installed here") } {
    msg = MegaSAPlugins.searchMsg(root +/+ "plugins", ["/abs/x/plugs"]);
    ~tEq.("the scan is VSTPlugin's search over the folders given, its cache written where it is told",
        [msg[0], msg[1], msg.includesEqual("/abs/x/plugs"), msg.last == (root +/+ "plugins")], ['/cmd', '/vst_search', true, true]);
    ~tEq.("...each plugin given 20 s to answer, and probed one at a time",
        [msg[4], MegaSAPlugins.probeTimeout, msg[2] == vst.searchMsg(["/abs/x/plugs"], (save: true, parallel: false))[2],
            msg[2] == vst.searchMsg(["/abs/x/plugs"], (save: true, parallel: true))[2]], [20, 20, true, false]);
    ~tEq.("the scan's score is written, and the cache's folder made",
        [MegaSAPlugins.writeScore(root +/+ "scan.osc", root +/+ "plugins", ["/abs/x/plugs"]), File.exists(root +/+ "scan.osc"),
            File.exists(root +/+ "plugins")], [true, true, true]);
};
// The server's program is beside SuperCollider's resources on macOS and on
// the shell's path on Linux.
File.mkdir(root +/+ "res");
File.use(root +/+ "res" +/+ "scsynth", "w", { |f| f.write("#!/bin/sh") });
~tEq.("the scan's server is the one beside SuperCollider's resources where there is one, else the shell's own scsynth",
    [MegaSAPlugins.scsynthPath(root +/+ "res"), MegaSAPlugins.scsynthPath(root +/+ "nothing-here")],
    [root +/+ "res" +/+ "scsynth", "scsynth"]);
~tAssert.("...and the scan starts that one", MegaSAPlugins.scanCommand("/abs/x/a.osc", "/abs/x/o.wav").beginsWith(MegaSAPlugins.scsynthPath.shellQuote));
got = MegaSAPlugins.scanCommand("/abs/x/a b.osc", "/abs/x/out.wav");
~tEq.("the offline server's command: scsynth -N on the score, no input, a port far from the language's",
    [got.contains("scsynth"), got.contains(" -N "), got.contains("a b.osc"), got.contains(" _ "), got.contains("-u 57997")],
    [true, true, true, true, true]);

// ---- a chain's plugin device opens what its sound names -----------------------------
if(vst.isNil) { ~tSkip.("a plugin's device opens what its sound names", "VSTPlugin is not installed here") } {
    MegaSA.loadSynthDefs;
    // A MegaSA from a sound whose plugin is `identity`, with `catalog`, on a
    // rig set up for the plugin at `path`: [it, what its plugin was made for, its plugin's device].
    make = { |identity, catalog, path|
        var srv = ~tStubServer.(), sound = MegaSASound.default("Amp"), plug = ~tFakePlugin.(\open), m;
        identity !? { |i| sound.device(\plugin1).put(\plugin, i) };
        m = ~tMegaSA.(srv, plug, path, sound, catalog);
        [m, srv[\pluginMadeWith], m.device(\plugin1)]
    };
    got = make.((key: "Amp", format: "vst2", uid: "A001", name: "Amp", vendor: "Acme"), all, "/abs/x/Rig.vst");
    ~tEq.("a plugin's device opens the catalog's entry for the plugin its sound names, by its key",
        [got[1], got[2].plugin.notNil, (got[0].instVarAt(\holds)[\guitar] ? []).includes(\opening).not], ["Amp", true, true]);
    got[0].free;
    got = make.((key: "Amp (moved)", format: "vst2", uid: "A001", name: "x", vendor: "y"), all, "/abs/x/Rig.vst");
    ~tEq.("...found by its id when its key is another now", got[1], "Amp");
    got[0].free;
    got = make.((key: "Amp", format: "vst2", uid: "A001"), [], "/abs/x/Rig.vst");
    ~tEq.("with nothing scanned yet it opens the rig's own plugin, as before the catalog", got[1], "/abs/x/Rig.vst");
    got[0].free;
    got = make.(nil, all, "/abs/x/Rig.vst");
    ~tEq.("a sound that names no plugin (one from before the chains) opens the rig's own too", got[1], "/abs/x/Rig.vst");
    got[0].free;
    got = make.((key: "Gone", format: "vst2", uid: "G1", name: "Gone", vendor: "Nobody"), all, "/abs/x/Rig.vst");
    ~tEq.("a plugin this Mac has not is not opened: its device stays in the chain with no plugin, the guitar is not held, and the sound still names it",
        [got[1], got[2].notNil, got[2].plugin, (got[0].instVarAt(\holds)[\guitar] ? []).includes(\opening),
            MegaSAPlugins.identityOf(got[0].sound.device(\plugin1)[\plugin])[\key]],
        [nil, true, nil, false, "Gone"]);
    got[0].free;
    got = make.((key: "Intel Only", format: "vst2", uid: "I001"), all, "/abs/x/Rig.vst");
    ~tEq.("nor is one that would need the bridge", [got[1], got[2].plugin], [nil, nil]);
    got[0].free;

    // ---- several plugins, each with its own state ------------------------------------
    // Two on the guitar chain: an amp and, after it, a reverb. One fake each.
    sound = MegaSASound.default("Amp");
    sound.device(\plugin1).put(\plugin, (key: "Amp", format: "vst2", uid: "A001", name: "Amp", vendor: "Acme"));
    sound.track(\guitar).put(\devices, sound.devices(\guitar) ++ [(id: \plugin2, type: \plugin, name: "Verb", on: true,
        layout: [2, 2], plugin: (key: "Surround", format: "vst3", uid: "S3", name: "Surround", vendor: "Wide"))]);
    sound.nextIds.put(\plugin, 3);
    fakes = IdentityDictionary.new;
    m = ~tMegaSA.(~tStubServer.(), { |synth, id, pth|
        var f = ~tFakePlugin.(\open, pth.asString);
        fakes.put(pth.asSymbol, f);
        f
    }, "/abs/x/Rig.vst", sound, all);
    run = { m.instVarAt(\bankRoutine) !? { |r| 60.do { r.next } } };
    ~tEq.("every plugin device of a sound is made for the plugin it names, and opened",
        [fakes.keys.asArray.sort, m.pluginDevices.collect(_.id), fakes.values.collect { |f| f[\opened] }, fakes.values.collect { |f| f[\state] }],
        [['Amp', 'Surround'], [\plugin1, \plugin2], [1, 1], [\open, \open]]);
    ~tEq.("...the guitar let go once the last of them has answered", (m.instVarAt(\holds)[\guitar] ? []).includes(\opening), false);
    got = nil;
    m.writeSound(root +/+ "two.json", "two", true, nil, { |ok, w| got = [ok, w] }, true, "261010_120000");
    run.value;
    ~tEq.("a sound written has every open plugin write its own state, each named by its device",
        [got, fakes['Amp'][\saves], fakes['Surround'][\saves],
            MegaSASound.read(root +/+ "two.json").devices(\guitar).select { |d| d[\type] == \plugin }.collect { |d| d[\state][\file] },
            File.exists(root +/+ "two.states" +/+ "plugin1-261010_120000.fxp"), File.exists(root +/+ "two.states" +/+ "plugin2-261010_120000.fxp")],
        [[true, nil], 1, 1, ["plugin1-261010_120000.fxp", "plugin2-261010_120000.fxp"], true, true]);
    fakes['Surround'][\saveFails] = true;
    got = nil;
    m.writeSound(root +/+ "two.json", "two", true, nil, { |ok, w| got = [ok, w] }, true, "261010_120001");
    run.value;
    ~tEq.("one plugin that does not save its state stops the write: the file stays as it was",
        [got[0], got[1].asString.contains("Verb"),
            MegaSASound.read(root +/+ "two.json").devices(\guitar).select { |d| d[\type] == \plugin }.collect { |d| d[\state][\file] }],
        [false, true, ["plugin1-261010_120000.fxp", "plugin2-261010_120000.fxp"]]);
    fakes['Surround'][\saveFails] = false;
    fakes.do { |f| f[\loaded] = nil };
    got = nil;
    m.applySound(MegaSASound.read(root +/+ "two.json"), { |ok, notes| got = [ok, notes] });
    run.value;
    ~tEq.("a recall has every open plugin take its own state",
        [got, fakes['Amp'][\loaded] !? { |p| p.basename }, fakes['Surround'][\loaded] !? { |p| p.basename }],
        [[true, []], "plugin1-261010_120000.fxp", "plugin2-261010_120000.fxp"]);
    // Built from that sound, each opens with its own state.
    made = List.new;
    again = ~tMegaSA.(~tStubServer.(), { |synth, id, pth| var f = ~tFakePlugin.(\open, pth.asString); made.add(f); f },
        "/abs/x/Rig.vst", MegaSASound.read(root +/+ "two.json"), []);
    ~tEq.("built from that sound, each plugin opens with its own state",
        made.collect { |f| f[\openedWith] !? { |x| x[\path].basename } }.asArray,
        ["plugin1-261010_120000.fxp", "plugin2-261010_120000.fxp"]);
    again.free;
    File.delete(root +/+ "two.states" +/+ "plugin2-261010_120000.fxp");
    got = nil;
    m.applySound(MegaSASound.read(root +/+ "two.json"), { |ok, notes| got = [ok, notes] });
    run.value;
    ~tEq.("...and says not ok when one of them did not", got[0], false);
    // The guitar is held until the last of its plugins has answered its open.
    m.instVarPut(\openings, IdentitySet[m.device(\plugin1), m.device(\plugin2)]);
    m.hold(\guitar, \opening);
    m.prOpenAnswered(m.device(\plugin1));
    got = [(m.instVarAt(\holds)[\guitar] ? []).includes(\opening)];
    m.prOpenAnswered(m.device(\plugin2));
    ~tEq.("the guitar is held until the last of its plugins has answered its open",
        got ++ [(m.instVarAt(\holds)[\guitar] ? []).includes(\opening)], [true, false]);
    // A burst of recalls ends on the last for each plugin, not for all of them.
    heard = List.new;
    m.prStateJob(\load, \program, root +/+ "two.states" +/+ "plugin1-261010_120000.fxp", { |ok| heard.add([\first, ok]) }, m.device(\plugin1));
    m.prStateJob(\load, \program, root +/+ "two.states" +/+ "plugin1-261010_120000.fxp", { |ok| heard.add([\amp, ok]) }, m.device(\plugin1));
    m.prStateJob(\load, \program, root +/+ "two.states" +/+ "plugin1-261010_120000.fxp", { |ok| heard.add([\verb, ok]) }, m.device(\plugin2));
    m.prStateJob(\load, \program, root +/+ "two.states" +/+ "plugin1-261010_120000.fxp", { |ok| heard.add([\ampAgain, ok]) }, m.device(\plugin1));
    run.value;
    ~tEq.("a load that waits is replaced by a later one for the same plugin only",
        heard.asArray, [[\amp, false], [\first, true], [\verb, true], [\ampAgain, true]]);
    m.free;

    // ---- a plugin added from the catalog ---------------------------------------------
    amp = (key: "Amp", format: "vst2", uid: "A001", name: "Amp", vendor: "Acme");
    fakes = IdentityDictionary.new;
    maker = { |synth, id, pth| var f = ~tFakePlugin.(\open, pth.asString); fakes.put(pth.asSymbol, f); f };
    sound = MegaSASound.default("Amp");
    sound.device(\plugin1).put(\plugin, amp);
    m = ~tMegaSA.(~tStubServer.(), maker, "/abs/x/Rig.vst", sound, all);
    Routine { m.attachLooper(~tLooper.()) }.next;
    d = m.insertPlugin(\guitar, nil, "Surround");
    ~tEq.("a plugin is added by its key in the catalog: a device of its own, in the layout of its busses, named after it",
        [d !? { |x| [x.id, x.layout, x.name] }, m.guitarChain.ids.last, fakes['Surround'].notNil, m.device(\plugin2) !? { |x| x.plugin === fakes['Surround'] }],
        [[\plugin2, [2, 2], "Surround"], \plugin2, true, true]);
    ~tEq.("...opened only once its synth is on the server, not in the edit itself; the sound names it from the start",
        [fakes['Surround'][\opened], MegaSAPlugins.identityOf(d.fileExtras !? { |x| x[\plugin] }) !? { |i| i[\key] }, m.prPluginTarget(d)],
        [0, "Surround", "Surround"]);
    m.prOpenPlugin(d);
    ~tEq.("...then open, with nothing held for it", [fakes['Surround'][\state], (m.instVarAt(\holds)[\guitar] ? []).size], [\open, 0]);
    ~tEq.("what the catalog has not, what needs the bridge and what is no effect are refused; so is a plugin with no key",
        [m.insertPlugin(\guitar, nil, "Gone"), m.insertPlugin(\guitar, nil, "Intel Only"), m.insertPlugin(\guitar, nil, "Piano"),
            m.insertPlugin(\guitar, nil, "Tone Gen"), m.insertDevice(\guitar, nil, \plugin), m.guitarChain.ids.last], [nil, nil, nil, nil, nil, \plugin2]);
    m.undo;
    ~tEq.("undo parks it, still open", [m.guitarChain.ids.includes(\plugin2), m.limboDevices.collect(_.id), fakes['Surround'][\state]], [false, [\plugin2], \open]);
    m.redo;
    ~tEq.("...and redo brings the same plugin back", [m.guitarChain.ids.last, m.device(\plugin2).plugin === fakes['Surround'], m.limboDevices], [\plugin2, true, []]);
    ~tEq.("it moves to the loop chain as any device does", [m.moveDevice(\plugin2, \loop, 0), m.loopChain.ids.first, m.pluginDevices.collect(_.id)], [true, \plugin2, [\plugin1, \plugin2]]);
    m.free;

    // ---- a recall opens the plugins a sound names --------------------------------------
    fakes = IdentityDictionary.new;
    m = ~tMegaSA.(~tStubServer.(), maker, "/abs/x/Rig.vst", MegaSASound.default(nil), all);
    Routine { m.attachLooper(~tLooper.()) }.next;
    sound = MegaSASound.default(nil);
    // (Its state is the amp's of the sound written above.)
    sound.track(\loop).put(\devices, sound.devices(\loop) ++ [(id: \plugin1, type: \plugin, name: "Amp", on: true, layout: [2, 2], plugin: amp,
        state: (kind: \program, file: "plugin1-261010_120000.fxp"))]);
    sound.statesDir = root +/+ "two.states";
    got = nil;
    m.applySound(sound, { |ok, notes| got = [ok, notes] });
    ~tEq.("a recall of a sound with a plugin nothing hosts yet puts its device in and makes its plugin, on the chain the sound says, with nothing to say",
        [got, m.loopChain.ids.last, fakes['Amp'].notNil, fakes['Amp'] !? { |f| f[\opened] }], [[true, []], \plugin1, true, 0]);
    m.prOpenPlugin(m.device(\plugin1));
    ~tEq.("...opened a moment later, like one added by hand, with the sound's state",
        [fakes['Amp'][\state], fakes['Amp'][\openedWith] !? { |x| x[\path].basename }], [\open, "plugin1-261010_120000.fxp"]);
    m.free;

    // ---- a plugin that crashed megalooper while it opened ------------------------------
    // A marker is there while a plugin opens. The fake here answers when told.
    markers = root +/+ "opening";
    sound = MegaSASound.default("Amp");
    sound.device(\plugin1).put(\plugin, amp);
    fakes = IdentityDictionary.new;
    waiting = nil;
    maker = { |synth, id, pth|
        var f = ~tFakePlugin.(\open, pth.asString);
        f[\path] = pth;
        f[\open] = { |self, given, action| self[\state] = \opening; waiting = { self[\state] = \open; action.value(self, true) } };
        fakes.put(pth.asSymbol, f);
        f
    };
    m = ~tMegaSA.(~tStubServer.(), maker, "/abs/x/Rig.vst", sound, all, { |x| x.markerDir = markers });
    ~tEq.("while a plugin opens, a marker file says so", [(markers +/+ "*.opening").pathMatch.size, File.exists(markers +/+ "Amp.opening")], [1, true]);
    waiting.value;
    ~tEq.("...gone once it has answered", (markers +/+ "*.opening").pathMatch.size, 0);
    m.free;
    // Freed while its plugin still opens (the boot run again): no crash, so no marker.
    m = ~tMegaSA.(~tStubServer.(), maker, "/abs/x/Rig.vst", sound, all, { |x| x.markerDir = markers });
    got = [(markers +/+ "*.opening").pathMatch.size];
    m.free;
    ~tEq.("megalooper freed while a plugin still opens leaves no marker: the boot run again opens it",
        got ++ [(markers +/+ "*.opening").pathMatch.size], [1, 0]);
    // One left behind: megalooper stopped while that plugin was opening.
    File.use(markers +/+ "Amp.opening", "w", { |f| f.write("261010_230000") });
    fakes = IdentityDictionary.new;
    m = ~tMegaSA.(~tStubServer.(), maker, "/abs/x/Rig.vst", sound, all, { |x| x.markerDir = markers });
    ~tEq.("a marker left behind keeps that plugin closed at the next boot: its device stays, empty, the guitar is not held, the sound still names it",
        [fakes.size, m.device(\plugin1).notNil, m.device(\plugin1).plugin, (m.instVarAt(\holds)[\guitar] ? []).includes(\opening),
            MegaSAPlugins.identityOf(m.sound.device(\plugin1)[\plugin])[\key]],
        [0, true, nil, false, "Amp"]);
    ~tEq.("...and the marker is gone, so the boot after tries it again", File.exists(markers +/+ "Amp.opening"), false);
    ~tEq.("a marker's name is the plugin's key, with nothing in it a file name cannot hold",
        m.prMarkerPath("Sub/Dir: A b.vst3").basename, "Sub_Dir__A_b_vst3.opening");
    m.free;
    m = ~tMegaSA.(~tStubServer.(), maker, "/abs/x/Rig.vst", sound, all, { |x| x.markerDir = markers });
    ~tEq.("(which makes it and opens it)", [fakes.size, m.device(\plugin1).plugin.notNil], [1, true]);
    waiting.value;
    m.free;
    // With no folder given there is no marker, and nothing throws.
    fakes = IdentityDictionary.new;
    m = ~tMegaSA.(~tStubServer.(), maker, "/abs/x/Rig.vst", sound, all);
    waiting.value;
    ~tEq.("with no folder for them there are no markers", [fakes['Amp'][\state], (markers +/+ "*.opening").pathMatch.size], [\open, 0]);
    m.free;
};

// ---- MIDI to a plugin: its sends ---------------------------------------------------
// megalooper hears your controllers, a hosted plugin does not: a send passes
// the plugin a controller of its own, for the plugin's own MIDI learn.
~tEq.("a plugin has eight sends, each a controller of its own: CC 20 to 27",
    [MegaSA.pluginSends, (1..8).collect { |n| MegaSA.pluginSendCC(n) }], [8, (20..27)]);
if(\VSTPlugin.asClass.isNil) { ~tSkip.("a send reaches its plugin", "VSTPlugin is not installed here") } {
    var fake = ~tFakePlugin.(\open, "Amp"), sa2 = ~tMegaSA.(nil, fake), dead, sa3;
    ~tEq.("(a MegaSA with its plugin open)", [sa2.device(\plugin1) !? { |d| d.isPlugin }, fake[\state]], [true, \open]);
    ~tEq.("a send goes to its plugin as that controller, value 127 on channel 1",
        [sa2.pluginSend(\plugin1, 1), sa2.pluginSend(\plugin1, 8), fake[\controls]], [true, true, [[0, 20, 127], [0, 27, 127]]]);
    ~tEq.("there is no send 0, 9, 1.5 or none: nothing goes",
        [[0, 9, 1.5, nil].collect { |n| sa2.pluginSend(\plugin1, n) }, fake[\controls].size], [false ! 4, 2]);
    ~tEq.("a built-in effect has no sends, nor a device that is not there",
        [sa2.pluginSend(\delay, 1), sa2.pluginSend(\nothing, 1), fake[\controls].size], [false, false, 2]);
    sa2.free;
    dead = ~tFakePlugin.(\failed, "Amp");
    sa3 = ~tMegaSA.(nil, dead);
    ~tEq.("a plugin that is not open is sent nothing, and the send says so", [sa3.pluginSend(\plugin1, 1), dead[\controls]], [false, nil]);
    sa3.free;
};

// ---- the scripts --------------------------------------------------------------------
if(~saGuitarBank.isNil) { (scripts +/+ "setup-sa.scd").load };
saved = [~looper, ~saScanning, ~megaSA, ~saPlugins];
protect {
    ~megaSA = nil;
    ~saScanning = false;
    ~looper = (state: \playing);
    got = nil;
    why = { |x| if(MegaSAPlugins.available) { x } { "VSTPlugin is not installed" } };
    // (Over an empty scratch folder, should one ever start here.)
    ~tEq.("no scan while a loop plays", [~saScanPlugins.({ |ok, w, n| got = [ok, w, n] }, [root +/+ "none"]), got],
        [false, [false, why.("a loop is playing"), 0]]);
    ~looper = nil;
    ~saScanning = true;
    got = nil;
    ~saScanPlugins.({ |ok, w| got = [ok, w] }, [root +/+ "none"]);
    ~tEq.("...nor while one runs", got, [false, why.("a scan is running already")]);
    ~tEq.("the catalog is read from megalooper's folder, sa/plugins, here a scratch one with no scan in it",
        [~saPluginsDir.().endsWith("sa/plugins"), ~saPluginsDir.().beginsWith(PathName.tmp), ~saReadPlugins.(), ~saPlugins], [true, true, [], []]);
    ~saPlugins = all;
    ~tEq.("the keys megalooper can host are the offered ones that are not greyed", ~saPluginKeys.(), ["Amp", "Amp.vst3", "Old Verb.vst3", "Surround"]);
} {
    ~looper = saved[0]; ~saScanning = saved[1]; ~megaSA = saved[2]; ~saPlugins = saved[3];
    ~tRemoveTree.(root);
};
}.value;
