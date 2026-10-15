// BBCut presets: capture, serialise, validate, recall.
//
// Same contract as the granular side — fail soft by field, reject by file,
// never throw — but with more to get wrong: a voice carries a proc, a synth, an
// fx chain and a per-proc parameter set, and the params are REBUILT from the
// proc's spec rather than trusted, because a nil reaching a build closure
// throws inside BBCut's own scheduling thread and kills the voice with no
// visible cause.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-bbcut-presets");

{
var l = ~tLooper.();
var data, str, parsed;

~tEq.("initBBCut gives one voice", l.bbcutVoiceCount, 1);

// ---- capture and round trip ---------------------------------------------

l.setVoiceProc(0, \warp);
l.setVoiceRatio(0, 2);
l.setVoiceAmp(0, 0.8);
l.setVoicePan(0, -0.5);
data = l.bbcutPresetData("Round Trip");
~tEq.("captures the name", data[\name], "Round Trip");
~tEq.("stamps the format version", data[\version], l.bbcutPresetVersion);
~tEq.("captures one voice", data[\voices].size, 1);
~tEq.("captures the proc", data[\voices][0][\proc], \warp);

str = l.bbcutPresetString(data);
parsed = ~tCheck.("the serialised preset compiles", { str.compile.value });
~tAssert.("...and yields an Event", parsed.isKindOf(Dictionary),
    "got a " ++ parsed.class);
~tAssert.("the file leads with comments, not a trailing one",
    str.beginsWith("//"),
    "a trailing comment would make interpret return nil");

l.setVoiceProc(0, \break); l.setVoiceRatio(0, 1); l.setVoiceAmp(0, 0.2);
l.setVoicePan(0, 0);
~tEq.("applying a good preset reports success", l.applyBBCutPreset(parsed), true);
{
var v = ~tGet.(l, \bbcutVoices)[0];
~tEq.("recall restores the proc", v[\proc], \warp);
~tNear.("recall restores the ratio", v[\ratio], 2.0, 1e-9);
~tNear.("recall restores the amp", v[\amp], 0.8, 1e-9);
~tNear.("recall restores the pan", v[\pan], -0.5, 1e-9);
}.value;

// ---- reject by file ------------------------------------------------------

[
    ["nil",              nil],
    ["a number",         42],
    ["a string",         "not a preset"],
    ["a future version", (version: 999, voices: [()])],
    ["no voices key",    (version: 1)],
    ["an empty voice list", (version: 1, voices: [])],
    // The regression: a String IS a Collection in sclang, so this used to slip
    // past the voices guard and throw PrimitiveFailedError from inside the
    // voice validator instead of being refused. Reachable by hand-editing a
    // preset file, which these files invite.
    ["voices as a string", (version: 1, voices: "break")],
    ["voices as a number", (version: 1, voices: 7)]
].do { |c|
    var w = List.new;
    var got = ~tCheck.("rejects " ++ c[0] ++ " without throwing", {
        l.prValidateBBCutPreset(c[1], w)
    });
    ~tEq.("...and returns nil for " ++ c[0], got, nil);
    ~tAssert.("...and says why for " ++ c[0], w.notEmpty, "no warning recorded");
};

// ---- fail soft by field --------------------------------------------------

{
var w = List.new;
var clean = ~tCheck.("cleans a mangled voice instead of rejecting the file", {
    l.prValidateBBCutPreset((
        version: 1, name: "Mangled",
        mode: \nosuchmode,
        voices: [(
            proc:  \nosuchproc,      // unknown -> the default proc
            synth: \nosuchsynth,     // unknown -> cutbuf2
            fx:    [\nosuchfx],      // unknown -> dropped
            ratio: 100,              // out of range -> clipped to 8
            amp:   -5,               // out of range -> clipped to 0
            pan:   "left",           // not a number -> default
            params: (cutchance: 99, nosuchparam: 1)
        )]
    ), w)
});
~tAssert.("...returning a usable Event", clean.notNil, "got nil");
~tEq.("unknown proc falls back to the default", clean[\voices][0][\proc],
    l.defaultBBCutProc);
~tEq.("unknown synth falls back to cutbuf2", clean[\voices][0][\synth], \cutbuf2);
~tEq.("unknown fx are dropped", clean[\voices][0][\fx], []);
~tEq.("ratio clips to 8", clean[\voices][0][\ratio], 8.0);
~tEq.("amp clips to 0", clean[\voices][0][\amp], 0.0);
~tEq.("non-numeric pan takes the default", clean[\voices][0][\pan], 0.0);
~tEq.("unknown mode falls back", clean[\mode], l.bbcutMode);
~tAssert.("every correction is reported", w.size >= 7,
    "only " ++ w.size ++ " warnings");
}.value;

// A voice that is not an Event at all still yields a playable default voice
// rather than nil, because one bad voice must not cost the whole file.
{
var w = List.new;
var clean = ~tCheck.("a non-Event voice becomes a default voice", {
    l.prValidateBBCutPreset((version: 1, voices: ["nope"]), w)
});
~tAssert.("...returning a usable Event", clean.notNil, "got nil");
~tEq.("...with the default proc", clean[\voices][0][\proc], l.defaultBBCutProc);
}.value;

// Params are rebuilt from the corrected proc's spec, so the build closure can
// never read a nil — the failure that kills a voice silently inside BBCut's
// scheduling thread.
{
var w = List.new;
var clean = l.prValidateBBCutPreset((version: 1, voices: [(proc: \break)]), w);
var spec = ~tGet.(l, \bbcutProcSpecs)[\break];
~tAssert.("every param of the proc's spec is present after validation",
    spec[\params].every { |e| clean[\voices][0][\params][e[\key]].notNil },
    "a nil param would throw inside BBCut's own thread");
~tAssert.("integer params come back as Integers",
    spec[\params].select { |e| e[\int] }.every { |e|
        clean[\voices][0][\params][e[\key]].isInteger },
    "a float where BBCut wants a count");
}.value;

// Params left over from another proc are dropped, not carried along — that is
// what repairs a preset saved before the proc was switched.
{
var w = List.new;
var clean = l.prValidateBBCutPreset(
    (version: 1, voices: [(proc: \break, params: (cutchance: 0.5, sdiv: 8))]), w);
~tEq.("a param from another proc is dropped",
    clean[\voices][0][\params][\sdiv], nil);
~tAssert.("...and the drop is reported",
    w.any { |s| s.asString.contains("sdiv") }, "no warning naming sdiv");
}.value;

// Four voices is the ceiling the model enforces; a fifth must be trimmed rather
// than accepted and then rejected later by addBBCutVoice.
{
var w = List.new;
var clean = l.prValidateBBCutPreset(
    (version: 1, voices: Array.fill(6, { (proc: \break) })), w);
~tEq.("keeps only the first 4 voices", clean[\voices].size, 4);
~tAssert.("...and says so", w.any { |s| s.asString.contains("4") },
    "no warning about the trim");
}.value;
}.value;
