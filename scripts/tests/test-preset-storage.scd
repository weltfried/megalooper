// Preset storage: the part both families share.
//
// How a preset is STORED is one implementation — a JSON file per preset,
// nothing in it run (an SC literal until 2026-11-08, carried over once by
// Looper.migratePresets) — parameterised by Looper.prPresetFamilies. What a preset
// CONTAINS is per-family and covered by test-bbcut-presets.scd and
// test-granular-presets.scd. This file exercises the shared half, on real
// files in a temp directory, for both families through their named entry
// points.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-preset-storage");

{
// This run's own folder (~tTempPath): runs at the same time do not share it.
var root = ~tTempPath.("megalooper-preset-tests");
var l = ~tLooper.();
var families;

// ---- the family table names methods that exist -------------------------

// A typo in this table would only surface when someone clicked Save mid-gig,
// and would throw rather than warn.
families = Looper.prPresetFamilies;
~tEq.("both families are declared", families.keys.asArray.sort, [\bbcut, \granular]);
families.keysValuesDo { |key, f|
    ~tAssert.(key ++ ": has a label", f[\label].isString, "got " ++ f[\label]);
    ~tAssert.(key ++ ": names its file's format", f[\format].isString and: { f[\format].beginsWith("megalooper ") },
        "got " ++ f[\format]);
    ~tAssert.(key ++ ": orders its fields, the header first",
        f[\order].isArray and: { f[\order].keep(3) == [\version, \name, \savedAt] }, "got " ++ f[\order]);
    [\data, \version, \apply, \summary].do { |role|
        ~tAssert.(key ++ ": " ++ role ++ " names a real method",
            f[role].notNil and: { Looper.findRespondingMethodFor(f[role]).notNil },
            "Looper has no " ++ f[role]);
    };
};

// The summary lines go in the save confirmation, so they must survive being
// concatenated — an Integer leading a ++ chain is a throw in sclang.
~tCheck.("bbcut summary builds a string", {
    var out = l.prBBCutPresetSummary(l.bbcutPresetData("x"));
    if(out.isString.not) { Error("got a " ++ out.class).throw };
    out
});
~tCheck.("granular summary builds a string", {
    var out = l.prGranularPresetSummary(l.granularPresetData("x"));
    if(out.isString.not) { Error("got a " ++ out.class).throw };
    out
});

// ---- round trip on disk, both families ---------------------------------

if(File.exists(root)) { (root +/+ "*").pathMatch.do { |p|
    (p +/+ "*.scd").pathMatch.do { |f| File.delete(f) };
    (p +/+ "*.json").pathMatch.do { |f| File.delete(f) };
    (p +/+ MegaFiles.migratedMarker).pathMatch.do { |f| File.delete(f) };
} };

[
    // key, dir, a mutation to save, and how to read it back
    [\granular, "granular",
        { l.granularSize = 2.5; l.granularPitch = 7 },
        { l.granularSize = 1;   l.granularPitch = 0 },
        { [l.granularSize, l.granularPitch] }, [2.5, 7.0]],
    [\bbcut, "bbcut",
        { l.setVoiceProc(0, \warp);  l.setVoiceRatio(0, 2) },
        { l.setVoiceProc(0, \break); l.setVoiceRatio(0, 1) },
        { var v = ~tGet.(l, \bbcutVoices)[0]; [v[\proc], v[\ratio]] }, [\warp, 2.0]]
].do { |c|
    var key = c[0];
    var dir = root +/+ c[1];
    var save   = ("save"   ++ if(key == \bbcut) { "BBCut" } { "Granular" } ++ "Preset").asSymbol;
    var load   = ("load"   ++ if(key == \bbcut) { "BBCut" } { "Granular" } ++ "Preset").asSymbol;
    var del    = ("delete" ++ if(key == \bbcut) { "BBCut" } { "Granular" } ++ "Preset").asSymbol;
    var names  = (key.asString ++ "PresetNames").asSymbol;
    var path   = (key.asString ++ "PresetPath").asSymbol;
    var slug;

    if(names == \bbcutPresetNames) { names = \bbcutPresetNames };

    c[2].value;    // set the values to be saved
    slug = ~tCheck.(key ++ ": save writes a file", { l.perform(save, dir, "My Take 1") });
    ~tEq.(key ++ ": save returns the slug", slug, "my-take-1");
    ~tAssert.(key ++ ": the file is on disk",
        File.exists(l.perform(path, dir, "My Take 1")),
        l.perform(path, dir, "My Take 1"));
    ~tEq.(key ++ ": the preset is listed", l.perform(names, dir), ["my-take-1"]);

    c[3].value;    // move the values away
    ~tEq.(key ++ ": load reports success", l.perform(load, dir, slug), true);
    ~tEq.(key ++ ": load restores the values", c[4].value, c[5]);

    ~tEq.(key ++ ": delete reports success", l.perform(del, dir, slug), true);
    ~tEq.(key ++ ": the listing is empty again", l.perform(names, dir), []);
    ~tEq.(key ++ ": deleting again reports false", l.perform(del, dir, slug), false);
    ~tEq.(key ++ ": loading a missing preset reports false",
        l.perform(load, dir, "no-such-preset"), false);
    ~tEq.(key ++ ": saving with no directory reports nil",
        l.perform(save, nil, "anything"), nil);
    ~tEq.(key ++ ": listing a missing directory is empty",
        l.perform(names, root +/+ "does-not-exist"), []);
    ~tEq.(key ++ ": listing a nil directory is empty", l.perform(names, nil), []);

    // A hand-edited file that no longer parses must be refused, not thrown.
    File.use(dir +/+ "broken.json", "w") { |f| f.write("{ this is not ]] valid") };
    ~tEq.(key ++ ": an unparseable file is refused", l.perform(load, dir, "broken"), false);
    File.delete(dir +/+ "broken.json");

    // JSON that is no object, another family's preset, or one from a newer
    // megalooper: refused whole, before the validator sees it.
    [
        ["a parseable non-preset", "42"],
        ["a file of another kind", "{\"format\": \"megalooper drums\", \"version\": 1}"],
        ["the other family's preset", "{\"format\": \"" ++ Looper.prPresetFamilies[if(key == \bbcut) { \granular } { \bbcut }][\format] ++ "\"}"],
        ["a preset from a newer megalooper", "{\"format\": \"" ++ Looper.prPresetFamilies[key][\format] ++ "\", \"version\": 99}"]
    ].do { |x|
        File.use(dir +/+ "notapreset.json", "w") { |f| f.write(x[1]) };
        ~tEq.(key ++ ": " ++ x[0] ++ " is refused", l.perform(load, dir, "notapreset"), false);
    };
    File.delete(dir +/+ "notapreset.json");

    // An old .scd is no preset: never listed, never run, its name loads nothing.
    ~tPresetRan = nil;
    File.use(dir +/+ "trap.scd", "w") { |f| f.write("~tPresetRan = true; (version: 1, name: \"trap\")") };
    ~tEq.(key ++ ": an .scd beside the presets is not listed", l.perform(names, dir), []);
    ~tEq.(key ++ ": ...its name loads nothing, and nothing in it runs", [l.perform(load, dir, "trap"), ~tPresetRan], [false, nil]);
    File.delete(dir +/+ "trap.scd");

    // ---- the old presets carried over, once (Looper.migratePresets) ----
    c[2].value;
    File.use(dir +/+ "old-take.scd", "w") { |f|
        f.write("// an old preset\n" ++ l.perform((key ++ "PresetData").asSymbol, "Old Take").asCompileString) };
    File.use(dir +/+ "broken-old.scd", "w") { |f| f.write("( this is not ]] valid") };
    File.use(dir +/+ "throws-old.scd", "w") { |f|
        f.write("(version: 1, name: \"bad\", amp: nil.foo, voices: [(enabled: true, amp: 0.5)])") };
    c[3].value;
    {
        var oldText = MegaFiles.readText(dir +/+ "old-take.scd");
        var moved = Looper.migratePresets(key, dir);
        ~tEq.(key ++ ": the old presets that read are carried over; one that does not parse or throws is not",
            [moved, l.perform(names, dir)], [["old-take"], ["old-take"]]);
        ~tEq.(key ++ ": ...the old files stay where they are, as they were, and the folder is marked",
            [MegaFiles.readText(dir +/+ "old-take.scd") == oldText, File.exists(dir +/+ "broken-old.scd"),
                File.exists(dir +/+ "throws-old.scd"), MegaFiles.migrated(dir)], [true, true, true, true]);
        ~tEq.(key ++ ": ...the carried one loads, and plays as it did", [l.perform(load, dir, "old-take"), c[4].value], [true, c[5]]);
        ~tAssert.(key ++ ": ...written as this family's JSON",
            (MegaFiles.parseObject(MegaFiles.readText(dir +/+ "old-take.json")) !? { |o| o.at("format") })
                == Looper.prPresetFamilies[key][\format]);
        File.use(dir +/+ "later.scd", "w") { |f| f.write("~tPresetRan = true; (version: 1)") };
        ~tEq.(key ++ ": once marked, a folder is not carried over again: a .scd put there later is never run",
            [Looper.migratePresets(key, dir), ~tPresetRan, File.exists(dir +/+ "later.json")], [[], nil, false]);
        ["old-take.scd", "old-take.json", "broken-old.scd", "throws-old.scd", "later.scd", MegaFiles.migratedMarker]
            .do { |n| File.delete(dir +/+ n) };
        ~tEq.(key ++ ": a missing or nil folder carries nothing, and is not made",
            [Looper.migratePresets(key, root +/+ "nowhere"), File.exists(root +/+ "nowhere"), Looper.migratePresets(key, nil)],
            [[], false, []]);
    }.value;
};

// ---- kept for the next start (the Cutter's and the Grains' Start with this) ----
// What a preset holds, in a file of its own: written, read back at boot,
// and refused whole when it is not this family's, as a preset is.
[
    // family, keep, load, the file's name (~keptPartPath), then c[2..5] as above
    [\bbcut, \keepCutter, \loadKeptCutter, \cutter,
        { l.setVoiceProc(0, \warp);  l.setVoiceRatio(0, 2); l.bbcutMode = \gate },
        { l.setVoiceProc(0, \break); l.setVoiceRatio(0, 1); l.bbcutMode = \mix },
        { var v = ~tGet.(l, \bbcutVoices)[0]; [v[\proc], v[\ratio], l.bbcutMode] }, [\warp, 2.0, \gate]],
    [\granular, \keepGrains, \loadKeptGrains, \grains,
        { l.granularSize = 2.5; l.granularMorph = 0.4; l.granularEnv = 2; l.granularFollowChords = true },
        { l.granularSize = 1;   l.granularMorph = 0;   l.granularEnv = 0; l.granularFollowChords = false },
        { [l.granularSize, l.granularMorph, l.granularEnv, l.granularFollowChords] }, [2.5, 0.4, 2, true]]
].do { |c|
    var key = c[0], keep = c[1], load = c[2];
    var userDir = root +/+ "kept-" ++ key;
    var path = userDir +/+ "kept-" ++ c[3] ++ ".json";
    var wasOverride = ~midiUserRootOverride, wasLooper = ~looper;
    if(File.exists(path)) { File.delete(path) };

    c[4].value;
    ~tEq.(key ++ ": nothing kept, nothing is loaded and nothing moves", [l.perform(load, path), c[6].value], [false, c[7]]);
    ~tEq.(key ++ ": keep writes the file, its folder made", [l.perform(keep, path), File.exists(path)], [nil, true]);
    ~tAssert.(key ++ ": ...as this family's JSON",
        (MegaFiles.parseObject(MegaFiles.readText(path)) !? { |o| o.at("format") }) == Looper.prPresetFamilies[key][\format]);
    c[5].value;
    ~tEq.(key ++ ": loading what was kept puts it back", [l.perform(load, path), c[6].value], [true, c[7]]);
    ~tEq.(key ++ ": with no file given, keep says why and load answers false",
        [l.perform(keep, nil).isString, l.perform(load, nil)], [true, false]);

    // Refused whole, nothing moved: a file that does not parse, another
    // family's, one from a newer megalooper.
    [
        ["a file that does not parse", "{ this is not ]] valid"],
        ["the other family's file", "{\"format\": \"" ++ Looper.prPresetFamilies[if(key == \bbcut) { \granular } { \bbcut }][\format] ++ "\"}"],
        ["one from a newer megalooper", "{\"format\": \"" ++ Looper.prPresetFamilies[key][\format] ++ "\", \"version\": 99}"]
    ].do { |x|
        File.use(path, "w") { |f| f.write(x[1]) };
        c[5].value;
        ~tEq.(key ++ ": " ++ x[0] ++ " is refused, and nothing moves", [l.perform(load, path), c[6].value == c[7]], [false, false]);
    };
    File.delete(path);

    // The scripts' half (setup-model.scd): the file under your megalooper
    // folder, kept from ~looper, and read back for both at boot.
    if(~keepPart.isNil) { (thisProcess.nowExecutingPath.dirname.dirname +/+ "setup-model.scd").load };
    protect {
        ~midiUserRootOverride = userDir;
        ~looper = l;
        ~tEq.(key ++ ": ~keptPartPath is kept-" ++ c[3] ++ ".json in your megalooper folder", ~keptPartPath.(c[3]), path);
        c[4].value;
        ~tEq.(key ++ ": ~keepPart keeps it", [~keepPart.(c[3]), File.exists(path)], [nil, true]);
        c[5].value;
        ~loadKeptParts.();
        ~tEq.(key ++ ": ~loadKeptParts puts it back", c[6].value, c[7]);
        File.delete(path);
        ~looper = nil;
        ~tAssert.(key ++ ": with no looper, ~keepPart says why", ~keepPart.(c[3]).isString);
    } {
        ~midiUserRootOverride = wasOverride;
        ~looper = wasLooper;
    };
};
// The two read back at once, each from its own file: one kept leaves the
// other as it is.
{
    var userDir = root +/+ "kept-both", wasOverride = ~midiUserRootOverride, wasLooper = ~looper;
    protect {
        ~midiUserRootOverride = userDir;
        ~looper = l;
        l.granularSize = 3; l.bbcutMode = \insert;
        ~keepPart.(\grains);
        l.granularSize = 1; l.bbcutMode = \gate;
        ~loadKeptParts.();
        ~tEq.("only the grains kept: they come back, the cutter stays as it is", [l.granularSize, l.bbcutMode], [3.0, \gate]);
        File.delete(userDir +/+ "kept-grains.json");
    } {
        ~midiUserRootOverride = wasOverride;
        ~looper = wasLooper;
    };
}.value;

// Both families share the slug, so one name resolves to one file stem on
// either side — otherwise the two windows would disagree about what
// "already exists" means.
~tEq.("the two families agree on slugs",
    l.bbcutPresetSlug("Take 3 (fast)"), l.granularPresetSlug("Take 3 (fast)"));
~tEq.("...and on paths",
    l.bbcutPresetPath("/x", "Take 3 (fast)"), l.granularPresetPath("/x", "Take 3 (fast)"));

// ---- the GUI-side family specs -----------------------------------------
//
// Each window registers its half of the spec — a label, a help line, and the
// Looper selectors to call. A typo in one of those selectors would surface only
// when someone clicked the button, and would throw rather than warn, so it is
// worth the few lines to check here. The GUI files only DEFINE, so loading them
// opens no window.
{
    var dir = thisProcess.nowExecutingPath.dirname.dirname;
    var required = [\label, \statusIdle, \dirKey, \names, \slug,
                    \save, \load, \delete];
    if(~definePresetFamily.isNil) { (dir +/+ "gui-presets.scd").load };
    (dir +/+ "gui-bbcut.scd").load;
    if(~granularParams.isNil) { (dir +/+ "setup-granular.scd").load };
    (dir +/+ "gui-granular.scd").load;

    ~tEq.("both windows registered a preset family",
        ~presetFamilies.keys.asArray.sort, [\bbcut, \granular]);

    ~presetFamilies.keysValuesDo { |key, fam|
        required.do { |k|
            ~tAssert.(key ++ " spec: " ++ k ++ " is set", fam[k].notNil,
                "missing from the family spec");
        };
        // Every named selector must exist on Looper.
        [\names, \slug, \save, \load, \delete].do { |role|
            ~tAssert.(key ++ " spec: " ++ role ++ " names a real Looper method",
                Looper.findRespondingMethodFor(fam[role]).notNil,
                "Looper has no " ++ fam[role]);
        };
        // And the directory global must be one boot.scd actually sets.
        ~tAssert.(key ++ " spec: dirKey is a *PresetDir global",
            fam[\dirKey].asString.endsWith("PresetDir"),
            "got " ++ fam[\dirKey]);
        // Fresh state, so a rebuilt window starts from a known place.
        ~tEq.(key ++ " spec: items start at the sentinel only", fam[\items], [nil]);
        ~tEq.(key ++ " spec: nothing loaded yet", fam[\loaded], nil);
        ~tAssert.(key ++ " spec: nothing armed yet",
            fam[\saveArmed].not and: { fam[\deleteArmed].not }, "armed at rest");
    };

    // The two windows must not accidentally share a directory, or saving in one
    // would list in the other.
    ~tAssert.("the two families use different directories",
        ~presetFamilies[\bbcut][\dirKey] != ~presetFamilies[\granular][\dirKey],
        "both point at " ++ ~presetFamilies[\bbcut][\dirKey]);

    // presetWidget exists because `fam[\slot] = widget` evaluates to the EVENT,
    // not the widget — inline in a layout that would silently install the family
    // spec as a view. Assert it hands back what it was given.
    ~tCheck.("presetWidget returns the widget, not the family", {
        var token = "not-a-widget";
        var back = ~presetWidget.(\bbcut, \statusText, token);
        ~presetFamilies[\bbcut][\statusText] = nil;
        if(back != token) {
            Error("got a " ++ back.class ++ " back").throw
        };
        back
    });
}.value;

// Named wrappers: the GUI and check.scd address these, so they must exist and
// take no more arguments than their callers pass.
[
    \refreshBBCutPresetList, \refreshBBCutPresetButtons, \bbcutPresetSetStatus,
    \bbcutPresetArm, \bbcutPresetDisarm, \loadBBCutPreset, \saveBBCutPreset,
    \deleteBBCutPreset, \revertBBCutPreset,
    \refreshGranularPresetList, \refreshGranularPresetButtons,
    \granularPresetSetStatus, \granularPresetArm, \granularPresetDisarm,
    \loadGranularPreset, \saveGranularPreset, \deleteGranularPreset,
    \revertGranularPreset
].do { |sym|
    ~tAssert.(sym ++ " is a Function",
        currentEnvironment[sym].isKindOf(Function),
        "is a " ++ currentEnvironment[sym].class);
};
~tRemoveTree.(root);
}.value;
