// Preset storage: the part both families share.
//
// How a preset is STORED is one implementation — a file per preset holding a
// single SC literal — parameterised by Looper.prPresetFamilies. What a preset
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
    [\data, \string, \apply, \summary].do { |role|
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

    // A hand-edited file that no longer parses must be refused, not thrown:
    // .interpret on a broken literal raises, and these files invite editing.
    File.use(dir +/+ "broken.scd", "w") { |f| f.write("( this is not ]] valid") };
    ~tEq.(key ++ ": an unparseable file is refused", l.perform(load, dir, "broken"), false);
    File.delete(dir +/+ "broken.scd");

    // A file that parses to something that is not a preset reaches the
    // validator, which rejects by file rather than throwing.
    File.use(dir +/+ "notapreset.scd", "w") { |f| f.write("42") };
    ~tEq.(key ++ ": a parseable non-preset is refused",
        l.perform(load, dir, "notapreset"), false);
    File.delete(dir +/+ "notapreset.scd");

    // A file whose code throws while the literal is half built, read where
    // the answer is an operand. Run on the caller's stack, the half-built
    // literal stayed there: this came out as a Symbol (the key it had
    // reached), and inside an array literal it threw. Looper.readPresetFile
    // runs it on a Routine's own.
    File.use(dir +/+ "throws.scd", "w") { |f|
        f.write("(version: 1, name: \"bad\", amp: nil.foo, voices: [(enabled: true, amp: 0.5)])") };
    ~tEq.(key ++ ": a preset that throws while it is read, in an expression: 1000 + load(...).binaryValue is 1000",
        1000 + (l.perform(load, dir, "throws").binaryValue), 1000);
    ~tEq.(key ++ ": ...and inside a literal the caller is building", [\before, l.perform(load, dir, "throws"), \after],
        [\before, false, \after]);
    File.delete(dir +/+ "throws.scd");
};

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
