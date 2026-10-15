// Granular presets: capture, serialise, validate, recall.
//
// Preset files are plain SC literals and are documented as hand-editable, so
// the validator's contract is "fail soft by field, reject by file, never
// throw". These tests are mostly that contract.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-granular-presets");

{
var l = ~tLooper.();
var data, str, parsed, warnings;

// ---- capture -------------------------------------------------------------

l.granularMorph = 0.4; l.granularPitch = 7; l.granularSize = 2.5;
l.granularDensity = 3; l.granularScan = -1.5; l.granularSpray = 120;
data = l.granularPresetData("My Test");
~tEq.("captures every declared field",
    Looper.granularPresetFields.every { |f| data[f[0]].notNil }, true);
~tEq.("captures the name", data[\name], "My Test");
~tEq.("stamps the format version", data[\version], l.granularPresetVersion);
~tNear.("captures a set value", data[\pitch], 7.0, 1e-9);

// Window shape is stored by NAME, not index — inserting a shape into
// granularEnvNames would otherwise re-point every older preset at a different
// envelope, silently.
~tEq.("stores the window by name", data[\env], Looper.granularEnvNames[0]);
~tAssert.("the window name is not an index", data[\env].isString,
    "got a " ++ data[\env].class);

// ---- serialise and read back --------------------------------------------

str = l.granularPresetString(data);
parsed = ~tCheck.("the serialised preset compiles", { str.compile.value });
~tAssert.("...and yields an Event", parsed.isKindOf(Dictionary),
    "got a " ++ parsed.class);
~tEq.("round trip preserves size", parsed[\size], 2.5);
~tEq.("round trip preserves a negative value", parsed[\scan], -1.5);
~tAssert.("the file leads with comments, not a trailing one",
    str.beginsWith("//"),
    "a trailing comment would make interpret return nil");

// ---- recall --------------------------------------------------------------

l.granularSize = 1; l.granularDensity = 1; l.granularPitch = 0;
l.granularScan = 0; l.granularSpray = 0;
~tEq.("applying a good preset reports success", l.applyGranularPreset(parsed), true);
~tNear.("recall restores size", l.granularSize, 2.5, 1e-9);
~tNear.("recall restores density", l.granularDensity, 3.0, 1e-9);
~tNear.("recall restores pitch", l.granularPitch, 7.0, 1e-9);
~tNear.("recall restores a negative scan", l.granularScan, -1.5, 1e-9);
~tNear.("recall restores spray", l.granularSpray, 120.0, 1e-9);

// The LEVEL, end to end. Singled out because it is the field a player edits
// last — dial the layer in against the loop, then save — so it is the one that
// exposes any break in the capture/serialise/recall chain, and because it was
// reported missing from presets when the fault was actually the save button's
// expiring overwrite confirmation (see test-preset-bar.scd).
{
var level = ~tLooper.();
var captured, roundTripped;
level.granularAmp = 0.31;
captured = level.granularPresetData("level test");
~tNear.("capture stores the level", captured[\amp], 0.31, 1e-9);
roundTripped = level.granularPresetString(captured).compile.value;
~tNear.("the file round trips the level", roundTripped[\amp], 0.31, 1e-9);
level.granularAmp = 0.9;
level.applyGranularPreset(roundTripped);
~tNear.("recall restores the level", level.granularAmp, 0.31, 1e-9);
// A file from before the level existed as a field. It is silently defaulted
// rather than left alone, which is deliberate — a preset is the WHOLE layer,
// not a patch — but it means an old preset resets the level to 0.7.
level.granularAmp = 0.42;
level.applyGranularPreset((version: 1, name: "older build", env: "Hann", morph: 0.5));
~tNear.("a preset with no level field defaults it, not keeps it",
    level.granularAmp, 0.7, 1e-9);
}.value;

// Recall goes through the SETTERS, never the vars. That is what makes a running
// granular synth follow a recall and what makes every view update without the
// model knowing a view exists — so a preset value out of range still gets
// clipped on the way in.
~tCheck.("recall clips an out-of-range field through the setter", {
    var hostile = parsed.copy;
    hostile[\size] = 9999;
    l.applyGranularPreset(hostile);
    if(l.granularSize > 16) {
        Error("size " ++ l.granularSize ++ " escaped the setter's clip").throw
    };
    l.granularSize
});

// ---- the validator's contract -------------------------------------------

l = ~tLooper.();

// Reject by FILE: nothing recognisable as a preset may be applied at all.
[
    ["nil",             nil],
    ["a number",        42],
    ["a string",        "not a preset"],
    ["an array",        [1, 2, 3]],
    ["a future version", (version: 999, size: 1)]
].do { |c|
    var w = List.new;
    var got = ~tCheck.("rejects " ++ c[0] ++ " without throwing", {
        l.prValidateGranularPreset(c[1], w)
    });
    ~tEq.("...and returns nil for " ++ c[0], got, nil);
    ~tAssert.("...and says why for " ++ c[0], w.notEmpty, "no warning recorded");
};

// Fail soft by FIELD: a stale or hand-mangled field is corrected and reported,
// because these files are far more often out of date than corrupt.
{
var w = List.new;
var clean = ~tCheck.("cleans a mangled preset instead of rejecting it", {
    l.prValidateGranularPreset((
        version: 1, name: "Mangled",
        size: 9999,            // out of range -> clipped
        density: "loud",       // not a number -> default
        pitch: 0/0,            // NaN -> default
        scan: -99,             // out of range -> clipped
        env: "No Such Window"  // unknown -> Warp1's own Hann
    ), w)
});
~tAssert.("...returning a usable Event", clean.notNil, "got nil");
~tEq.("clips size to the field's maximum", clean[\size], 16.0);
~tEq.("falls back to the default for a non-numeric field", clean[\density], 1.0);
~tEq.("falls back to the default for NaN", clean[\pitch], 0.0);
~tEq.("clips scan to the field's minimum", clean[\scan], -8.0);
~tEq.("falls back to Hann for an unknown window", clean[\env], 0);
~tAssert.("records one warning per correction", w.size >= 5,
    "only " ++ w.size ++ " warnings for 5 corrections");
}.value;

// A field simply absent is the ORDINARY case for a preset written by an older
// build, so it takes the default silently — a warning there would cry wolf on
// every old file.
{
var w = List.new;
var clean = l.prValidateGranularPreset((version: 1, name: "Old Build"), w);
~tAssert.("a preset with no fields at all still validates", clean.notNil, "got nil");
~tEq.("missing fields take their defaults", clean[\size], 1.0);
~tEq.("missing fields are silent, not warnings", w.size, 0);
}.value;

// Window names come from a menu the user reads, so matching must not care
// about case.
{
var w = List.new;
var clean = l.prValidateGranularPreset(
    (version: 1, env: Looper.granularEnvNames[2].toUpper), w);
~tEq.("window names match case-insensitively", clean[\env], 2);
}.value;

// ---- slug and path ------------------------------------------------------

~tEq.("slug lowercases and hyphenates", l.granularPresetSlug("Hello World! 42"),
    "hello-world-42");
~tEq.("slug collapses runs of punctuation", l.granularPresetSlug("a -- b"), "a-b");
~tEq.("slug strips trailing punctuation", l.granularPresetSlug("Drone!!!"), "drone");
~tEq.("slug never comes out empty", l.granularPresetSlug("!!!"), "preset");
~tEq.("slug never comes out empty for an empty name",
    l.granularPresetSlug(""), "preset");
~tAssert.("slug is bounded so it cannot overflow a filename",
    l.granularPresetSlug(String.fill(400, $a)).size <= 64,
    "got " ++ l.granularPresetSlug(String.fill(400, $a)).size ++ " chars");
~tEq.("path is the slug under the given directory",
    l.granularPresetPath("/tmp/presets", "My Test"), "/tmp/presets/my-test.scd");

// Both preset families share prPresetSlug, so a name must resolve to the same
// file stem on either side — otherwise the two windows would disagree about
// what "already exists" means.
~tEq.("bbcut and granular slugs agree",
    l.granularPresetSlug("Take 3 (fast)"), l.bbcutPresetSlug("Take 3 (fast)"));
}.value;
