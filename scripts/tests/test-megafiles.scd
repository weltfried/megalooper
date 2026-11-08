// megalooper's file kit (MegaFiles, docs/dev/device-chains.md section 11): the
// user root and its scratch stand-in for tests, JSON read with every value's
// kind, order and text kept, the format and version rules, the JSON writer,
// and the write that leaves the old file or the new one, never half.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-megafiles");

{
var root = ~tTempPath.("megafiles");
var o, g, text, path, backup, why, got, nasty, kept;

// ---- the root ---------------------------------------------------------------
~tAssert.("every test's user root is a scratch folder, never your own megalooper folder",
    MegaFiles.userRoot.beginsWith(PathName.tmp)
        and: { MegaFiles.userRoot.beginsWith(Platform.userAppSupportDir +/+ "megalooper").not },
    MegaFiles.userRoot);
~tEq.("...the harness's own, by this process", MegaFiles.userRoot, ~tTrapRoot);
~tAssert.("without an override it is the folder beside the MIDI maps",
    { var was = MegaFiles.rootOverride, real;
      MegaFiles.rootOverride = nil;
      real = MegaFiles.userRoot;
      MegaFiles.rootOverride = was;
      real == (Platform.userAppSupportDir +/+ "megalooper") }.value);

// ---- the system megalooper runs on ---------------------------------------------
// megalooper asks macOS things no other system answers; whoever asks one
// asks MegaFiles first, and a test can stand in for the other system.
~tEq.("the system is SuperCollider's own name for it", MegaFiles.platform, thisProcess.platform.name);
protect {
    MegaFiles.platformOverride = \linux;
    ~tEq.("a test can stand in for Linux", [MegaFiles.platform, MegaFiles.isLinux, MegaFiles.isMac], [\linux, true, false]);
    got = MegaFiles.clipboardCommand;
    ~tAssert.("on Linux the clipboard is wl-copy, xclip or xsel, never macOS's pbcopy; none of them is no clipboard",
        got.isNil or: { got.contains("pbcopy").not and: { ["wl-copy", "xclip", "xsel"].any { |n| got.contains(n) } } }, got.asString);
    MegaFiles.platformOverride = \osx;
    ~tEq.("...and for macOS", [MegaFiles.isLinux, MegaFiles.isMac], [false, true]);
} { MegaFiles.platformOverride = nil };
~tEq.("with no stand-in it is the real one again", MegaFiles.platform, thisProcess.platform.name);
if(thisProcess.platform.name == \osx) {
    ~tAssert.("on macOS the clipboard is pbcopy", (MegaFiles.clipboardCommand ? "").contains("pbcopy"), MegaFiles.clipboardCommand.asString);
};
~tAssert.("a command is found as the shell finds it: its path",
    (MegaFiles.commandPath(["megalooper-no-such-command", "sh"]) ? "").endsWith("/sh"), MegaFiles.commandPath(["sh"]).asString);
~tEq.("...the first that is there, of several; a path is taken as it stands if the file is there",
    [MegaFiles.commandPath(["/bin/megalooper-no-such", "/bin/sh"]), MegaFiles.commandPath(["megalooper-no-such-command"]), MegaFiles.commandPath(nil)],
    ["/bin/sh", nil, nil]);

// ---- reading ------------------------------------------------------------------
text = "{\"a\": 1, \"b\": 1.5, \"c\": \"x\", \"d\": true, \"e\": null,\n \"f\": [1, \"2\", false, [], {}],\n \"g\": {\"h\": -3e2,  \"i\":\"1200\"}}";
o = MegaFiles.parseObject(text);
~tAssert.("an object reads as an object", o.isKindOf(MegaJsonObject), o.asString);
~tEq.("...its members in the file's order", o.keys.asArray, ["a", "b", "c", "d", "e", "f", "g"]);
~tEq.("...a whole number an Integer, a fraction a Float", [o.at("a"), o.at("a").class, o.at("b"), o.at("b").class],
    [1, Integer, 1.5, Float]);
~tEq.("...a string a String, true a Boolean, null nil", [o.at("c"), o.at("d"), o.at("e"), o.includesKey("e")],
    ["x", true, nil, true]);
~tEq.("...a list an Array, each item its own kind", [o.at("f").keep(3), o.at("f")[3], o.at("f")[4].class],
    [[1, "2", false], [], MegaJsonObject]);
g = o.at("g");
~tEq.("...an object inside one, an exponent a Float, digits in quotes still a String",
    [g.at("h"), g.at("h").class, g.at("i")], [-300.0, Float, "1200"]);
~tEq.("every member keeps the text it was written as", [o.rawAt("b"), o.rawAt("e"), o.rawAt("g"), g.rawAt("h")],
    ["1.5", "null", "{\"h\": -3e2,  \"i\":\"1200\"}", "-3e2"]);
~tEq.("...and an object its own", [g.raw, o.raw], ["{\"h\": -3e2,  \"i\":\"1200\"}", text]);
~tEq.("a name it has not answers nil", [o.at("z"), o.rawAt("z"), o.includesKey("z")], [nil, nil, false]);
o = MegaFiles.parseObject("{\"k\": 1, \"k\": 2}");
~tEq.("a name written twice is kept twice; the last one counts", [o.size, o.at("k"), o.keys.asArray], [2, 2, ["k", "k"]]);
o = MegaFiles.parseObject("{\"s\": \"a\\\"b\\\\c\\nd\\t\\/\\u0041\\u00e9\\ud83d\\ude00\"}");
~tEq.("escapes are read: quote, backslash, newline, tab, slash, \\u as UTF-8, a pair as one",
    o.at("s"), "a\"b\\c\nd\t/A" ++ String.newFrom([0xC3, 0xA9, 0xF0, 0x9F, 0x98, 0x80].collect(_.asAscii)));
o = MegaFiles.parseObject("{\"big\": 3000000000, \"neg\": -7, \"zero\": 0, \"small\": 1e-05}");
~tEq.("a whole number past 32 bits is a Float, not a wrapped Integer", [o.at("big"), o.at("neg"), o.at("zero"), o.at("small")],
    [3000000000.0, -7, 0, 1e-05]);
~tEq.("an empty object reads", MegaFiles.parseObject("  {}\n").size, 0);

// What is not JSON is refused with a reason, never half read.
[["", "empty"], [nil, "empty"], ["[1]", "not a JSON object"], ["\"x\"", "not a JSON object"], ["{", "not JSON"],
 ["{\"a\": 01}", "not JSON"], ["{\"a\": 1,}", "not JSON"], ["{a: 1}", "not JSON"], ["a: 1", "not JSON"],
 ["{} x", "not JSON"], ["{\"a\": tru}", "not JSON"], ["{\"a\": \"x}", "not JSON"], ["{\"a\" 1}", "not JSON"],
 ["{\"a\": [1 2]}", "not JSON"], ["{\"a\": .5}", "not JSON"], ["{\"a\": \"\\q\"}", "not JSON"],
 ["{\"a\": \"\\u12\"}", "not JSON"]].do { |pair|
    why = MegaFiles.parseObject(pair[0]);
    ~tAssert.("refused: " ++ pair[0].asString.keep(16) ++ " (" ++ pair[1] ++ ")",
        why.isString and: { why.contains(pair[1]) }, why.asString);
};
~tAssert.("...and says where", MegaFiles.parseObject("{\"a\": 1,}").contains("character"));

// ---- the format and version rules ---------------------------------------------
o = MegaFiles.parseObject("{\"format\": \"megalooper thing\", \"version\": 1}");
~tEq.("a file of the format, at this build's version, answers its version", MegaFiles.versionOf(o, "megalooper thing", 1, "thing"), 1);
~tEq.("one with no version is version 1",
    MegaFiles.versionOf(MegaFiles.parseObject("{\"format\": \"megalooper thing\"}"), "megalooper thing", 1), 1);
~tAssert.("another format is refused, by name", MegaFiles.versionOf(o, "megalooper sound", 1, "megalooper sound")
    == "it is not a megalooper sound");
~tAssert.("a version that is no whole number is refused",
    MegaFiles.versionOf(MegaFiles.parseObject("{\"format\": \"megalooper thing\", \"version\": \"2\"}"), "megalooper thing", 1)
        == "its version can't be read");
why = MegaFiles.versionOf(MegaFiles.parseObject("{\"format\": \"megalooper thing\", \"version\": 7}"), "megalooper thing", 1);
~tAssert.("a file from a newer build is refused whole, and says both versions",
    why.isString and: { why.contains("newer") } and: { why.contains("7") } and: { why.contains("reads 1") }, why.asString);

// ---- writing JSON ----------------------------------------------------------------
nasty = "a\"b\\c\nd\re\tf" ++ 1.asAscii ++ "g/é";
~tEq.("a string is written so that it reads back as it was",
    MegaFiles.parseObject("{\"s\": " ++ MegaFiles.jsonString(nasty) ++ "}").at("s"), nasty);
~tEq.("...a control character as \\u", MegaFiles.jsonString("x" ++ 1.asAscii), "\"x\\u0001\"");
~tEq.("...as the MIDI map writes its own", LooperMidiMap.jsonString("a\"b\\c\nd"), MegaFiles.jsonString("a\"b\\c\nd"));
~tEq.("inf and NaN, which JSON cannot say, are null", [inf, -inf, 0 / 0, 3, 0.5, -2].collect { |x| MegaFiles.jsonNumber(x) },
    ["null", "null", "null", "3", "0.5", "-2"]);
o = MegaJsonObject.new;
o.add("zed", 1, "1");
o.add("alpha", [true, nil, \sym, "str", 2.5], "x");
~tEq.("an object's members go out in their own order", MegaFiles.json(o), "{\"zed\": 1, \"alpha\": [true, null, \"sym\", \"str\", 2.5]}");
~tEq.("...a Dictionary's sorted by name", MegaFiles.json((b: 1, a: (d: inf, c: "x"))), "{\"a\": {\"c\": \"x\", \"d\": null}, \"b\": 1}");
~tEq.("what was written reads back the same", MegaFiles.json(MegaFiles.parseObject(MegaFiles.json(o))), MegaFiles.json(o));
// One encoder (since 2026-11-08: the recorder's stream encoder folded in):
// the fast path for plain strings must not let a control character through.
~tEq.("the one encoder writes any string so it reads back, a control character as \\u, in a key too",
    [MegaFiles.parseObject(MegaFiles.json((s: nasty))).at("s"), MegaFiles.json("x" ++ 1.asAscii),
        MegaFiles.json(("k" ++ 1.asAscii).asSymbol), MegaFiles.json("g/é"), MegaFiles.json(Ref("[1,2]"))],
    [nasty, "\"x\\u0001\"", "\"k\\u0001\"", "\"g/é\"", "[1,2]"]);
{
    var s = CollStream(String.new), pauses = 0;
    MegaFiles.jsonOn(s, (a: [1, 2], b: (c: "q\"t")), { pauses = pauses + 1 });
    ~tEq.("...into a stream, pausing after every member, as json writes it",
        [s.contents, pauses], [MegaFiles.json((a: [1, 2], b: (c: "q\"t"))), 3]);
}.value;
got = 311.0913;
~tEq.("a number written and read is written the same again", MegaFiles.jsonNumber(MegaFiles.parseObject("{\"x\": "
    ++ MegaFiles.jsonNumber(got) ++ "}").at("x")), MegaFiles.jsonNumber(got));

// ---- the write ---------------------------------------------------------------------
path = root +/+ "deep" +/+ "thing.json";
backup = root +/+ "backups" +/+ "thing-1.json";
~tEq.("a write makes its folder and the file", [MegaFiles.writeNow(path, "{\"n\": 1}\n"), MegaFiles.readText(path)], [nil, "{\"n\": 1}\n"]);
~tAssert.("...and leaves nothing beside it", (path.dirname +/+ "*").pathMatch.size == 1, (path.dirname +/+ "*").pathMatch.asString);
~tEq.("a first write has nothing to back up", File.exists(backup), false);
~tEq.("the next one copies the old file to its backup first, then replaces it",
    [MegaFiles.writeNow(path, "{\"n\": 2}\n", nil, backup), MegaFiles.readText(backup), MegaFiles.readText(path)],
    [nil, "{\"n\": 1}\n", "{\"n\": 2}\n"]);
why = MegaFiles.writeNow(path, "{\"n\": 3", { |read| if(MegaFiles.parseObject(read).isString) { "it didn't read back" } });
~tEq.("a write that does not read back is refused with its reason: the old file stays, nothing is left beside it",
    [why, MegaFiles.readText(path), (path.dirname +/+ "*").pathMatch.size], ["it didn't read back", "{\"n\": 2}\n", 1]);
got = nil;
MegaFiles.write(path, "{\"n\": 4}\n", { |read| got = read; nil }, nil, { |ok, w| kept = [ok, w] }, true);
~tEq.("the check gets the text as it is on disk, and the action true", [got, kept, MegaFiles.readText(path)],
    ["{\"n\": 4}\n", [true, nil], "{\"n\": 4}\n"]);
MegaFiles.write(root +/+ "x.json", "{}", { |read| "no" }, nil, { |ok, w| kept = [ok, w] }, true);
~tEq.("...false and why when it is refused", kept, [false, "no"]);
~tEq.("a missing file reads as nil", [MegaFiles.readText(root +/+ "nothing.json"), MegaFiles.readText(nil)], [nil, nil]);
// The MIDI map's writer is this one.
~midiWriteFile !? { |f|
    ~midiWriteSync = true;
    f.(root +/+ "map.json", "{\"m\": 1}", nil, nil, { |ok, w| kept = [ok, w] });
    ~tEq.("the MIDI map's writer is this one", [kept, MegaFiles.readText(root +/+ "map.json")], [[true, nil], "{\"m\": 1}"]);
    ~midiWriteSync = false;
};

// ---- backups trimmed -----------------------------------------------------------------
File.mkdir(root +/+ "many");
(1..8).do { |i| File.use(root +/+ "many" +/+ ("26101" ++ i ++ ".json"), "w", { |f| f.write("{}") }) };
File.use(root +/+ "many" +/+ "note.txt", "w", { |f| f.write("x") });
got = MegaFiles.trim(root +/+ "many", "*.json", 5);
~tEq.("a trim keeps the newest five by name, and deletes the rest",
    [got.collect { |p| p.basename }, (root +/+ "many" +/+ "*.json").pathMatch.size, File.exists(root +/+ "many" +/+ "note.txt")],
    [["261018.json", "261017.json", "261016.json", "261015.json", "261014.json"], 5, true]);

// ---- a folder of yours, first made (the release: your presets leave the repo) ---------
File.mkdir(root +/+ "old");
["b.scd", "a.scd", "note.txt"].do { |n| File.use(root +/+ "old" +/+ n, "w", { |f| f.write("( n: \"" ++ n ++ "\" )") }) };
got = MegaFiles.adopt(root +/+ "old", root +/+ "deep" +/+ "mine");
~tEq.("a folder of yours that is not there is made, with what the old one holds of its kind",
    [got, (root +/+ "deep" +/+ "mine" +/+ "*").pathMatch.collect { |p| p.basename }.sort], [["a.scd", "b.scd"], ["a.scd", "b.scd"]]);
~tEq.("...copied whole", MegaFiles.readText(root +/+ "deep" +/+ "mine" +/+ "a.scd"), "( n: \"a.scd\" )");
~tEq.("...and never moved: the old files stay",
    (root +/+ "old" +/+ "*").pathMatch.collect { |p| p.basename }.sort, ["a.scd", "b.scd", "note.txt"]);
File.delete(root +/+ "deep" +/+ "mine" +/+ "a.scd");
File.use(root +/+ "deep" +/+ "mine" +/+ "b.scd", "w", { |f| f.write("mine now") });
~tEq.("once: with the folder there nothing is done", MegaFiles.adopt(root +/+ "old", root +/+ "deep" +/+ "mine"), nil);
~tEq.("...so a preset you deleted stays deleted, and one you changed stays yours",
    [File.exists(root +/+ "deep" +/+ "mine" +/+ "a.scd"), MegaFiles.readText(root +/+ "deep" +/+ "mine" +/+ "b.scd")], [false, "mine now"]);
~tEq.("with no old folder, yours is made empty",
    [MegaFiles.adopt(root +/+ "never", root +/+ "fresh"), File.exists(root +/+ "fresh"), MegaFiles.adopt(nil, root +/+ "fresh2")], [[], true, []]);
~tEq.("another kind of file by its pattern", MegaFiles.adopt(root +/+ "old", root +/+ "texts", "*.txt"), ["note.txt"]);
~tEq.("...or several kinds, each file once", MegaFiles.adopt(root +/+ "old", root +/+ "both", ["*.txt", "*.scd", "a.*"]),
    ["a.scd", "b.scd", "note.txt"]);

// ---- a preset's file: one rule for every family -----------------------------------
~tEq.("a name as a file name: lowercased, runs of anything else one '-', none at the ends, preset when empty, 64 at most",
    [MegaFiles.presetSlug("Take 3 (Fast)!"), MegaFiles.presetSlug("--a--b--"), MegaFiles.presetSlug("§§"), MegaFiles.presetSlug(String.fill(80, $a)).size],
    ["take-3-fast", "a-b", "preset", 64]);
File.mkdir(root +/+ "presets");
["b.json", "a.json", "old.scd", ".presets-json"].do { |n| File.use(root +/+ "presets" +/+ n, "w", { |f| f.write("{}") }) };
~tEq.("a folder's presets: its JSON files by slug, sorted; none for a folder that is not there",
    [MegaFiles.presetNames(root +/+ "presets"), MegaFiles.presetNames(root +/+ "nowhere"), MegaFiles.presetPath("/x", "My Take")],
    [["a", "b"], [], "/x/my-take.json"]);
~tEq.("...the rule every family names its files by: the cutter, the grains, the drums, the synth, the sounds",
    [Looper.newCopyArgs.bbcutPresetSlug("Take 3 (Fast)!"), Looper.newCopyArgs.granularPresetSlug("Take 3 (Fast)!"),
        MegaSADrums.newCopyArgs.presetSlug("Take 3 (Fast)!"), MegaSA.newCopyArgs.synthPresetSlug("Take 3 (Fast)!"),
        MegaSA.newCopyArgs.fxPresetSlug("Take 3 (Fast)!")], "take-3-fast" ! 5);

// ---- a preset as an Event (the drums', the cutter's, the grains') -----------------
{
    var data = (version: 1, name: "Take \"1\"", mode: \insert, lanes: [[1, 0], [0, 1]], voices: [(amp: 0.5, fx: [\rev])],
        empty: (), inner: (b: 2, a: 1), ratio: 2/3);
    var order = [\version, \name, \voices, \a];
    var text = MegaFiles.eventText(data, "megalooper test", order), back, said = List.new, lines;
    lines = text.split($\n);
    ~tEq.("an Event as a file: the format first, then the fields in the order given, the others sorted",
        lines.select { |l| l.beginsWith("  \"") }.collect { |l| l.stripWhiteSpace.split($:)[0] },
        ["format", "version", "name", "voices", "empty", "inner", "lanes", "mode", "ratio"].collect { |k| "\"" ++ k ++ "\"" });
    ~tEq.("...a list of lists or objects a line each, an empty object {}, a nested object in the same order",
        [lines.includesEqual("    [0, 1]"), lines.includesEqual("    {\"amp\": 0.5, \"fx\": [\"rev\"]}"),
            lines.includesEqual("  \"empty\": {},"), lines.includesEqual("    \"a\": 1,")], [true, true, true, true]);
    back = MegaFiles.eventOf(MegaFiles.parseObject(text));
    ~tEq.("...read back as the Event it was: Symbol keys, Arrays, numbers of their kind, Symbols as Strings",
        [back[\name], back[\mode], back[\lanes], back[\voices][0][\fx], back[\inner][\a].class, back[\empty] !? { |e| e.isKindOf(Dictionary) and: { e.isEmpty } }, back[\format]],
        ["Take \"1\"", "insert", [[1, 0], [0, 1]], ["rev"], Integer, true, "megalooper test"]);
    ~tNear.("...a Float to ~14 digits", back[\ratio], 2/3, 1e-12);
    path = root +/+ "events" +/+ "take.json";
    ~tEq.("writeEvent writes it whole, and readEvent reads it without its format",
        [MegaFiles.writeEvent(path, data, "megalooper test", order), MegaFiles.readEvent(path, "megalooper test", 1, "test file", { |w| said.add(w) }) !? { |e| [e[\name], e[\format]] }],
        [nil, ["Take \"1\"", nil]]);
    [
        ["a missing file", root +/+ "events" +/+ "none.json", nil, "it is not there or can't be read"],
        ["no JSON", root +/+ "events" +/+ "bad.json", "( version: 1 )", "it is not JSON"],
        ["another kind", root +/+ "events" +/+ "other.json", "{\"format\": \"megalooper drums\"}", "it is not a test file"],
        ["a newer version", root +/+ "events" +/+ "newer.json", "{\"format\": \"megalooper test\", \"version\": 2}", "it is from a newer megalooper"]
    ].do { |c|
        said = List.new;
        c[2] !? { |t| File.use(c[1], "w", { |f| f.write(t) }) };
        ~tAssert.("readEvent refuses " ++ c[0] ++ " whole, and says why",
            MegaFiles.readEvent(c[1], "megalooper test", 1, "test file", { |w| said.add(w) }).isNil
                and: { said.size == 1 } and: { said[0].beginsWith(c[3]) }, said.asString);
    };
}.value;

// ---- the old presets, SC literals, carried over once -------------------------------
{
    var dir = root +/+ "olds", said = List.new, moved;
    ~tMegaFilesRan = nil;
    File.mkdir(dir);
    File.use(dir +/+ "good.scd", "w", { |f| f.write("// a comment\n( version: 1, name: \"good\", mode: 'gate' )") });
    File.use(dir +/+ "throws.scd", "w", { |f| f.write("( version: 1, amp: nil.foo )") });
    File.use(dir +/+ "number.scd", "w", { |f| f.write("42") });
    File.use(dir +/+ "there.scd", "w", { |f| f.write("( version: 1, name: \"old\" )") });
    File.use(dir +/+ "there.json", "w", { |f| f.write("{\"format\": \"megalooper test\", \"name\": \"mine\"}") });
    ~tEq.("runLiteral: an SC literal run on a stack of its own; one that throws is nil, and the caller's sum is whole",
        [MegaFiles.runLiteral(dir +/+ "good.scd", { |w| said.add(w) }) !? { |e| e[\mode] },
            1000 + (MegaFiles.runLiteral(dir +/+ "throws.scd", { |w| said.add(w) }) ? 0), said.size],
        [\gate, 1000, 1]);
    said = List.new;
    moved = MegaFiles.migrateFolder(dir, { |old, json| MegaFiles.migrateFile(old, json, "megalooper test", [\version], { |w| said.add(old.basename) }) });
    ~tEq.("migrateFolder: each .scd carried over that reads as an Event (one already there counts, untouched); the others said",
        [moved, said.asArray.sort, MegaFiles.readEvent(dir +/+ "good.json", "megalooper test", 1, "test", nil) !? { |e| e[\mode] },
            MegaFiles.readText(dir +/+ "there.json").contains("mine")],
        [["good", "there"], ["number.scd", "throws.scd"], "gate", true]);
    ~tEq.("...the old files stay, and the folder is marked",
        [(dir +/+ "*.scd").pathMatch.size, MegaFiles.migrated(dir)], [4, true]);
    File.use(dir +/+ "later.scd", "w", { |f| f.write("~tMegaFilesRan = true; ( version: 1 )") });
    ~tEq.("...once: a .scd put there later is never run",
        [MegaFiles.migrateFolder(dir, { |old, json| MegaFiles.migrateFile(old, json, "megalooper test", nil, nil) }), ~tMegaFilesRan], [[], nil]);
    File.mkdir(root +/+ "olds-empty");
    ~tEq.("...a folder with nothing to carry is marked all the same; a missing one is not made",
        [MegaFiles.migrateFolder(root +/+ "olds-empty", nil), MegaFiles.migrated(root +/+ "olds-empty"),
            MegaFiles.migrateFolder(root +/+ "olds-none", nil), File.exists(root +/+ "olds-none")], [[], true, [], false]);
}.value;

// The boot's folders: everything megalooper saves goes under your folder. The
// repo's presets/ is named only as what the first boot copies from.
text = MegaFiles.readText(Looper.repoRoot +/+ "scripts" +/+ "boot.scd") ? "";
#["~bbcutPresetDir", "~granularPresetDir", "~saFxPresetDir", "~saDrumsPresetDir"].do { |name|
    var line = text.split($\n).detect { |l| l.beginsWith(name) and: { l.contains("=") } } ? "";
    ~tAssert.("the boot puts " ++ name ++ " in your megalooper folder, not in the repo",
        line.contains("~userRoot +/+") and: { line.contains("megalooperRoot").not }, line);
};
~tAssert.("...which is the scratch one when a test moved it",
    text.contains("~userRoot          = ~midiUserRootOverride ?? { MegaFiles.userRoot };"));
~tEq.("the boot names the repo's presets folder once: as what the first boot copies from",
    [text.findAll("~megalooperRoot +/+ \"presets\"").size, text.contains("MegaFiles.adopt(from, x[0], [\"*.json\", \"*.scd\"])")], [1, true]);
~tAssert.("...and carries the cutter's and the grains' old presets over to JSON after it",
    text.find("MegaFiles.adopt(from, x[0]") !? { |a| text.find("Looper.migratePresets(x[0], x[1])") !? { |m| m > a } } == true);

~tRemoveTree.(root);
~tAssert.("the scratch folder is gone again", File.exists(root).not);
}.value;
