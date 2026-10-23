// A sound as a document (MegaSASound, docs/dev/device-chains.md section 11): the
// default chains, the round trip through its JSON text, what this build does
// not know going back byte for byte, a newer file refused whole, the
// fail-soft rules for a file somebody edited, the ids' marks, state files as
// plain names, the migration's sound, and what Keep's mark compares.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-megasa-sound");

{
var s, t, text, again, why, d, raws, base, other, wrap, guitar, loop;

// A whole file around the two chains' device lists (JSON text each).
wrap = { |guitarDevices, loopDevices, more = ""|
    "{\"format\": \"megalooper sound\", \"version\": 1, \"name\": \"t\", \"tracks\": ["
        ++ "{\"track\": \"guitar\", \"devices\": [" ++ guitarDevices ++ "]}, "
        ++ "{\"track\": \"loop\", \"devices\": [" ++ loopDevices ++ "]}]" ++ more ++ "}"
};

// ---- the default chains ---------------------------------------------------------
s = MegaSASound.default("BIAS FX 2");
~tEq.("the default guitar chain: its four effects, then the plugin", s.devices(\guitar).collect { |x| x[\id] },
    MegaSAFx.guitarKeys ++ [\plugin1]);
~tEq.("the default loop chain: its three", s.devices(\loop).collect { |x| x[\id] }, MegaSAFx.loopKeys);
~tAssert.("every effect off at its type's defaults, the plugin on, 1 in 1 out",
    s.devices.every { |x| if(x[\type] == \plugin) { x[\on] and: { x[\layout] == [1, 1] } } {
        x[\on].not and: { MegaSAFx.paramsOf(x[\type]).every { |p| x[\settings][p[\name]] == p[\spec].default } } } });
~tEq.("the next ids: 2 for every effect, and for the plugin", [MegaSAFx.keys.collect { |k| s.nextIds[k] }.asSet.asArray, s.nextIds[\plugin]],
    [[2], 2]);
t = MegaSASound.default(nil);
~tEq.("with no plugin there is none, and the first would be plugin1", [t.device(\plugin1), t.nextIds[\plugin]], [nil, 1]);

// ---- the round trip ---------------------------------------------------------------
text = s.named("kept", "261010_101500").fileString;
~tAssert.("a sound's text says what it is first", text.beginsWith("{\"format\": \"megalooper sound\", \"version\": 1,\n \"name\": \"kept\", \"savedAt\": \"261010_101500\","), text.keep(120));
~tEq.("...a device a line", text.split($\n).count { |line| line.contains("\"id\": ") }, s.devices.size);
again = MegaSASound.parse(text);
~tAssert.("it reads back", again.isKindOf(MegaSASound), again.asString);
~tEq.("...with nothing to say about it", again.problems.asArray, []);
~tEq.("...the same name, stamp and next ids", [again.name, again.savedAt, again.nextIds], ["kept", "261010_101500", s.nextIds]);
~tAssert.("...the same devices, in order, with every setting",
    (again.devices.collect { |x| [x[\id], x[\type], x[\name], x[\on], x[\layout]] }
        == s.devices.collect { |x| [x[\id], x[\type], x[\name], x[\on], x[\layout]] })
    and: { again.devices.every { |x| x[\settings].isNil or: { x[\settings] == s.device(x[\id])[\settings] } } });
~tEq.("...and writes the same text again", again.fileString, text);
// Values with many digits: written, read and written again, the same text.
t = MegaSASound.default(nil);
t.device(\filter)[\settings].put(\filterFreq, 311.0913);
t.device(\saturator)[\settings].put(\saturatorDrive, 6.499551);
t.device(\redux)[\settings].put(\reduxRate, 7240.085839);
~tEq.("settings with many digits survive two round trips as the same text",
    MegaSASound.parse(MegaSASound.parse(t.fileString).fileString).fileString, t.fileString);
~tNear.("...and the same value within a file's 14 digits", MegaSASound.parse(t.fileString).device(\redux)[\settings][\reduxRate],
    7240.085839, 1e-9);

// ---- what this build does not know ------------------------------------------------
raws = (
    top: "{\"a\": [1, 2.50, true],  \"b\": null}",
    member: "\"#ff0000\"",
    setting: "0.250",
    wah: "{\"id\": \"wah1\", \"type\": \"wah\", \"on\": true, \"sweep\": 3.0e1, \"settings\": {\"wahQ\": 2}}",
    keys: "{\"track\": \"keys\", \"devices\": [], \"x\": 1}",
    stateMore: "[1,2,  3]",
    identity: "{\"key\": \"BIAS FX 2\", \"vendor\": \"Positive Grid\",  \"format\": \"vst2\", \"uid\": \"12345678\", \"version\": \"1200\"}",
    pluginSettings: "{\"gain\": 0.5}"
);
text = "{\"format\": \"megalooper sound\", \"version\": 1, \"name\": \"odd\", \"theme\": " ++ raws[\top] ++ ",\n"
    ++ " \"tracks\": [{\"track\": \"guitar\", \"mood\": 7, \"devices\": [\n"
    ++ "  {\"id\": \"delay\", \"type\": \"delay\", \"on\": true, \"color\": " ++ raws[\member]
        ++ ", \"settings\": {\"delayMix\": 0.5, \"delayFuture\": " ++ raws[\setting] ++ "}},\n"
    ++ "  " ++ raws[\wah] ++ ",\n"
    ++ "  {\"id\": \"plugin1\", \"type\": \"plugin\", \"name\": \"BIAS FX 2\", \"on\": true, \"layout\": [1, 1], \"plugin\": "
        ++ raws[\identity] ++ ", \"state\": {\"kind\": \"program\", \"file\": \"plugin1-a.fxp\", \"crc\": " ++ raws[\stateMore]
        ++ "}, \"settings\": " ++ raws[\pluginSettings] ++ "}]},\n"
    ++ " " ++ raws[\keys] ++ ",\n {\"track\": \"loop\", \"devices\": []}]}";
s = MegaSASound.parse(text);
~tAssert.("a sound with entries this build does not know still reads", s.isKindOf(MegaSASound), s.asString);
again = s.fileString;
raws.keysValuesDo { |k, raw|
    ~tAssert.("what it does not know goes back byte for byte: " ++ k, again.contains(raw), again);
};
~tAssert.("...a track's own unknown field too", again.contains("\"mood\": 7"));
~tEq.("...and reading that writes the same text again", MegaSASound.parse(again).fileString, again);
d = s.device(\wah1);
~tEq.("a device of a type this build has not is kept, in its place, with its id, type and switch",
    [s.devices(\guitar).collect { |x| x[\id] }, d[\type], d[\on], d[\raw]], [[\delay, \wah1, \plugin1], \wah, true, raws[\wah]]);
~tEq.("a track it has not is kept, and is none of its chains", [s.tracks.collect { |x| x[\track] }, s.devices.size],
    [[\guitar, \keys, \loop, \drums, \bass, \synth], 3]);
~tEq.("the known setting beside an unknown one is read", s.device(\delay)[\settings][\delayMix], 0.5);
~tEq.("a plugin's state: its kind and its file", s.device(\plugin1)[\state], (kind: \program, file: "plugin1-a.fxp"));
~tEq.("...in the sound's own list of state files", s.stateFiles, ["plugin1-a.fxp"]);

// ---- refused whole -----------------------------------------------------------------
[["", "empty"], ["nonsense", "not JSON"], ["{\"format\": \"megalooper midi map\", \"version\": 1, \"tracks\": []}", "not a megalooper sound"],
 ["{\"format\": \"megalooper sound\", \"version\": 1}", "tracks are not a list"],
 ["{\"format\": \"megalooper sound\", \"version\": 1, \"tracks\": {}}", "tracks are not a list"],
 ["{\"format\": \"megalooper sound\", \"version\": \"one\", \"tracks\": []}", "version can't be read"]].do { |pair|
    why = MegaSASound.parse(pair[0]);
    ~tAssert.("refused: " ++ pair[1], why.isString and: { why.contains(pair[1]) }, why.asString);
};
why = MegaSASound.parse("{\"format\": \"megalooper sound\", \"version\": 2, \"tracks\": [], \"future\": true}");
~tAssert.("a sound from a newer build is refused whole, and says so", why.isString and: { why.contains("newer megalooper") }, why.asString);
~tAssert.("a missing file is refused too", MegaSASound.read(~tTrapRoot +/+ "nothing" +/+ "kept.json").isString);

// ---- a file somebody edited ----------------------------------------------------------
s = MegaSASound.parse(wrap.(
    "{\"id\": \"delay\", \"type\": \"delay\", \"on\": \"yes\", \"settings\": {\"delayMix\": 7, \"delayFeedback\": \"lots\", \"delayTimeR\": null}}, "
    ++ "{\"id\": \"delay\", \"type\": \"delay\"}, {\"id\": \"de-lay\", \"type\": \"delay\"}, {\"type\": \"delay\"}, "
    ++ "{\"id\": \"filter\"}, 17, {\"id\": \"shifter\", \"type\": \"shifter\"}",
    "{\"id\": \"echo\", \"type\": \"echo\", \"on\": true}"));
~tAssert.("an edited file still reads", s.isKindOf(MegaSASound), s.asString);
~tEq.("...the devices that make sense are kept, in order", [s.devices(\guitar).collect { |x| x[\id] }, s.devices(\loop).collect { |x| x[\id] }],
    [[\delay, \shifter], [\echo]]);
d = s.device(\delay);
~tEq.("a setting out of range is held to it", d[\settings][\delayMix], MegaSAFx.constrain(\delayMix, 7));
~tEq.("one that is no number takes its default", [d[\settings][\delayFeedback], d[\settings][\delayTimeR]],
    [MegaSAFx.param(\delayFeedback)[\spec].default, MegaSAFx.param(\delayTimeR)[\spec].default]);
~tAssert.("a setting the file lacks takes its default, silently",
    MegaSAFx.paramsOf(\shifter).every { |p| s.device(\shifter)[\settings][p[\name]] == p[\spec].default });
~tEq.("a switch that is neither true nor false is off", d[\on], false);
~tAssert.("every correction is said",
    ["range", "delayFeedback is no number", "delayTimeR is no number", "there already", "its id is none", "has no type", "is no object", "neither true nor false"]
        .every { |x| s.problems.any { |p| p.contains(x) } }, s.problems.asArray.asString);
s = MegaSASound.parse("{\"format\": \"megalooper sound\", \"tracks\": [{\"track\": \"loop\", \"devices\": []}, "
    ++ "{\"track\": \"loop\", \"devices\": [{\"id\": \"echo\", \"type\": \"echo\"}]}, {\"devices\": []}, 3]}");
~tEq.("a file with no version is version 1; a chain it lacks is empty, one written twice counts once",
    [s.devices(\guitar), s.devices(\loop), s.problems.any { |p| p.contains("no guitar chain") }, s.problems.any { |p| p.contains("written twice") }],
    [[], [], true, true]);

// ---- state files are plain names --------------------------------------------------------
[["\"../other/x.fxp\"", false], ["\"/abs/x/y.fxp\"", false], ["\".hidden\"", false], ["\"\"", false], ["7", false],
 ["\"plugin1-261010_101500.fxp\"", true]].do { |pair|
    s = MegaSASound.parse(wrap.("{\"id\": \"plugin1\", \"type\": \"plugin\", \"state\": {\"kind\": \"program\", \"file\": " ++ pair[0] ++ "}}", ""));
    ~tEq.("a state file " ++ pair[0] ++ if(pair[1]) { " is taken" } { " is not: a sound names no path" },
        [s.device(\plugin1)[\state].notNil, s.problems.any { |p| p.contains("plain file") }], [pair[1], pair[1].not]);
};
s = MegaSASound.parse(wrap.("{\"id\": \"plugin1\", \"type\": \"plugin\", \"layout\": [4, 9], \"state\": {\"kind\": \"chunk\", \"file\": \"a.bin\"}}", ""));
~tEq.("a state of a kind this build does not read is none; a layout it cannot host is 1 in 1 out",
    [s.device(\plugin1)[\state], s.device(\plugin1)[\layout]], [nil, [1, 1]]);
s = MegaSASound.parse(wrap.("{\"id\": \"plugin1\", \"type\": \"plugin\", \"layout\": [1, 2], \"state\": {\"kind\": \"bank\", \"file\": \"current.fxb\"}}", ""));
s.statesDir = MegaSASound.statesDirFor("/x/sa/kept.json");
~tEq.("a bank is a state too (the migration's), found in the folder beside the sound's file",
    [s.device(\plugin1)[\state][\kind], s.device(\plugin1)[\layout], s.statePath(s.device(\plugin1))],
    [\bank, [1, 2], "/x/sa/kept.states/current.fxb"]);
~tEq.("...no folder, no path", MegaSASound.parse(s.fileString).statePath(s.device(\plugin1)), nil);

// ---- the ids' marks ---------------------------------------------------------------------
s = MegaSASound.parse(wrap.("{\"id\": \"delay\", \"type\": \"delay\"}, {\"id\": \"delay5\", \"type\": \"delay\"}, {\"id\": \"plugin1\", \"type\": \"plugin\"}",
    "{\"id\": \"echo\", \"type\": \"echo\"}", ", \"nextIds\": {\"delay\": 3, \"redux\": 9, \"echo\": \"x\", \"wah\": 4}"));
~tEq.("a type's next id is the file's, never under what its devices use, nor under megalooper's start",
    [s.nextIds[\delay], s.nextIds[\redux], s.nextIds[\echo], s.nextIds[\wah], s.nextIds[\plugin], s.nextIds[\shifter]], [6, 9, 2, 4, 2, 2]);

// ---- the migration's sound ---------------------------------------------------------------
t = MegaSAFx.defaults;
t.put(\filterFreq, 1238.17);
t.put(\delayFeedback, 99);
t.put(\notASetting, 1);
s = MegaSASound.fromSettings(t, "BIAS FX 2");
~tEq.("settings from before the chains become the default chains with those settings, each held to its range",
    [s.devices.collect { |x| x[\id] }, s.device(\filter)[\settings][\filterFreq], s.device(\delay)[\settings][\delayFeedback], s.name],
    [MegaSAFx.guitarKeys ++ [\plugin1] ++ MegaSAFx.loopKeys, 1238.17, MegaSAFx.constrain(\delayFeedback, 99), "kept"]);
~tAssert.("...every effect still off, as a preset of then left the switches alone", s.devices.every { |x| (x[\type] == \plugin) or: { x[\on].not } });

// ---- what Keep's mark compares --------------------------------------------------------------
base = MegaSASound.default("BIAS FX 2");
other = MegaSASound.parse(base.fileString);
other.device(\delay).put(\on, true);
other.device(\plugin1).put(\state, (kind: \program, file: "plugin1-b.fxp"));
other.device(\plugin1).put(\plugin, (key: "BIAS FX 2", version: "2.6.1"));
~tEq.("a switch, a state file, what a plugin says it is, a name or a stamp is no unkept edit",
    other.named("x", "261231_000000").contentString, base.contentString);
other = MegaSASound.parse(base.fileString);
other.device(\delay)[\settings].put(\delayMix, 0.9);
~tAssert.("a setting is", other.contentString != base.contentString);
other = MegaSASound.parse(base.fileString);
other.device(\delay).put(\name, "Slap");
~tAssert.("...a device's name is", other.contentString != base.contentString);
guitar = base.devices(\guitar);
other = MegaSASound("o", nil, base.nextIds, [(track: \guitar, devices: guitar.rotate(1)), base.track(\loop)]);
~tAssert.("...the order is", other.contentString != base.contentString);
~tEq.("the same devices in the same places are the same structure, whatever their settings; another order is not",
    [MegaSASound.parse(base.fileString).sameStructureAs(base), other.sameStructureAs(base)], [true, false]);
}.value;
