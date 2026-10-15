// The arc: the expression pedal (intensity) and the ending (dissolve).
//
// Both axes are multipliers over three stored levels — the dry loop, the
// cutter, the granular layer — and the mix functions are pure, so the SHAPE of
// a performance is testable with no server. That shape is the musical content
// here: which thing leaves first is the difference between a piece ending and a
// fader going down.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-arc");

{
var playing = {
    var l = ~tLooper.();
    ~tPut.(l, \state, \playing);
    ~tPut.(l, \loopFrames, (3.5 * 48000).asInteger);
    ~tPut.(l, \lastResult, (numerator: 7, denominator: 8, tau: 0.125, sub: 2, k: 2,
        downbeatOffset: 0));
    l
};
// dissolvePos is ramp-driven and deliberately has no public setter.
var atDissolve = { |l, d| ~tPut.(l, \dissolvePos, d); l };
var mixes = { |l| [l.prLoopMix, l.prBBCutMix, l.prGranularMix] };

// ---- the default must be invisible ------------------------------------------
// A rig with no expression pedal connected has to behave exactly as it did
// before any of this existed, or the feature is a regression for anyone who
// does not own a pedal.
{
    var l = playing.();
    ~tNear.("intensity defaults to 1", l.intensity, 1.0, 1e-9);
    ~tNear.("dissolve defaults to 0", l.dissolvePos, 0.0, 1e-9);
    ~tEqArray.("with no pedal every level passes through untouched",
        mixes.(l), [1, 1, 1], 1e-9);
}.value;

// ---- intensity: the grains' level and the cutter's density ------------------
// The pedal takes the granular layer's level and the cutter's density (below)
// from nothing up to what was configured. It does NOT touch the cutter's level:
// it did until 2026-10-05, and a cutter thinned AND turned down read as the
// layer leaving rather than as it chopping less. The dry loop never moves.
{
    var l = playing.();
    l.intensity = 0;
    ~tEqArray.("heel: dry loop and cutter level at full, grains out",
        mixes.(l), [1, 1, 0], 1e-9);
    l.intensity = 0.5;
    ~tEqArray.("mid-pedal scales the grains, never the dry loop nor the cutter's level",
        mixes.(l), [1, 1, 0.5], 1e-9);
    l.intensity = 1;
    ~tEqArray.("toe is everything at the level it was configured to",
        mixes.(l), [1, 1, 1], 1e-9);
}.value;

{
    var l = playing.();
    l.intensity = -3;  ~tNear.("intensity clips at 0", l.intensity, 0.0, 1e-9);
    l.intensity = 99;  ~tNear.("intensity clips at 1", l.intensity, 1.0, 1e-9);
}.value;

// ---- the dissolve leaves in the right ORDER ---------------------------------
// Rhythm, then body, then haze. This ordering IS the ending; a dissolve that
// dropped the grains first would just be a fade with extra steps.
{
    var l = playing.();
    ~tNear.("the cutter is gone by 0.4",     atDissolve.(l, 0.4).prBBCutMix,    0.0, 1e-9);
    ~tAssert.("the dry loop is still audible when the cutter has gone",
        atDissolve.(l, 0.4).prLoopMix > 0, atDissolve.(l, 0.4).prLoopMix.asString);
    ~tAssert.("the grains are still at full when the cutter has gone",
        atDissolve.(l, 0.4).prGranularMix == 1, atDissolve.(l, 0.4).prGranularMix.asString);

    ~tNear.("the dry loop is gone by 0.6",   atDissolve.(l, 0.6).prLoopMix,     0.0, 1e-9);
    ~tAssert.("the grains outlive the dry loop",
        atDissolve.(l, 0.6).prGranularMix > 0,
        atDissolve.(l, 0.6).prGranularMix.asString);

    ~tEqArray.("at the end everything is silent",
        mixes.(atDissolve.(l, 1.0)), [0, 0, 0], 1e-9);
}.value;

// Nothing may come back up on the way down — a level that dipped and recovered
// would read as a mistake rather than as an ending.
{
    var l = playing.();
    var prev = [2, 2, 2];
    (0, 0.02 .. 1).do { |d|
        var now = mixes.(atDissolve.(l, d));
        now.do { |v, i|
            if(v > (prev[i] + 1e-9)) {
                ~tFail.("dissolve is monotonic",
                    "level " ++ i ++ " rose at d=" ++ d ++ ": "
                        ++ prev[i] ++ " -> " ++ v);
            };
        };
        prev = now;
    };
    ~tPass.("every level falls monotonically across the whole dissolve");
}.value;

// The pedal still scales what is left mid-dissolve: the two axes multiply
// rather than one overriding the other.
{
    var l = playing.();
    l.intensity = 0.5;
    atDissolve.(l, 0.2);
    ~tNear.("intensity still scales the grains mid-dissolve",
        l.prGranularMix, 0.5, 1e-9);
    ~tNear.("the dry loop is unaffected by intensity, only by the dissolve",
        l.prLoopMix, 1 - (0.2 / 0.6), 1e-9);
    ~tNear.("the cutter's level is unaffected by intensity, only by the dissolve",
        l.prBBCutMix, 1 - (0.2 / 0.4), 1e-9);
}.value;

// ---- intensity drives cutter DENSITY, not only level ------------------------
// The stored value is the value at full intensity; the pedal scales from the
// parameter's own floor up to it. Nothing here may write to voice[\params] —
// the Cutter pane's sliders and every saved preset must keep the user's numbers,
// or the GUI would be lying about what was dialled in.
{
    var l = playing.();
    var voice = { ~tGet.(l, \bbcutVoices)[0] };
    l.setVoiceProc(0, \break);
    l.setVoiceParam(0, \cutchance, 0.8);

    l.intensity = 1;
    ~tNear.("at full arc the cutter gets exactly what was dialled in",
        l.prVoiceDensity(voice.(), \cutchance), 0.8, 1e-9);
    l.intensity = 0.5;
    ~tNear.("half arc lands half way from the floor to it",
        l.prVoiceDensity(voice.(), \cutchance), 0.4, 1e-9);
    l.intensity = 0;
    ~tNear.("heel drops it to the parameter's own floor",
        l.prVoiceDensity(voice.(), \cutchance), 0.0, 1e-9);

    // The whole point of scaling rather than overwriting.
    ~tNear.("the stored value is untouched at every pedal position",
        voice.()[\params][\cutchance], 0.8, 1e-9);
}.value;

{
    // A floor that is not zero must be respected, or heel would push a
    // parameter below its own declared minimum.
    var l = playing.();
    var voice;
    l.setVoiceProc(0, \choose);
    voice = ~tGet.(l, \bbcutVoices)[0];
    l.setVoiceParam(0, \rollallowed, 8);   // lo is 0.5, not 0
    l.intensity = 0;
    ~tNear.("heel lands on the declared floor, not on zero",
        l.prVoiceDensity(voice, \rollallowed), 0.5, 1e-9);
    l.intensity = 1;
    ~tNear.("and full arc still lands on the stored value",
        l.prVoiceDensity(voice, \rollallowed), 8.0, 1e-9);
}.value;

{
    // Every declared intensityKey must be live, or moving the pedal would
    // respawn the voice on every CC message instead of being re-read per block.
    var l = playing.();
    var specs = l.bbcutProcSpecs;
    l.bbcutProcOrder.do { |proc|
        var spec = specs[proc];
        var key  = spec[\intensityKey];
        if(key.notNil) {
            ~tAssert.(proc.asString ++ ": its intensityKey is live",
                (spec[\live] ? []).includes(key),
                key.asString ++ " is not in " ++ (spec[\live] ? []).asString);
            ~tAssert.(proc.asString ++ ": its intensityKey is a real param",
                (spec[\params] ? []).any { |e| e[\key] == key },
                key.asString ++ " is not one of its params");
        };
    };
    ~tAssert.("at least one proc declares an intensityKey",
        l.bbcutProcOrder.any { |pr| specs[pr][\intensityKey].notNil });
}.value;

{
    // An unknown key must not throw — prVoiceDensity is called from inside
    // BBCut's own scheduling thread, where a throw kills the voice silently.
    var l = playing.();
    var voice = ~tGet.(l, \bbcutVoices)[0];
    ~tCheck.("an unknown density key does not throw",
        { l.prVoiceDensity(voice, \nosuchparam) });
}.value;

// ---- arming and aborting ----------------------------------------------------
{
    var l = playing.();
    l.dissolveBars = 0;   ~tEq.("dissolveBars clips up to 1",   l.dissolveBars, 1);
    l.dissolveBars = 999; ~tEq.("dissolveBars clips down to 64", l.dissolveBars, 64);
    l.dissolveBars = 8;   ~tEq.("dissolveBars accepts 8",        l.dissolveBars, 8);
}.value;

{
    var l = playing.();
    ~tPut.(l, \state, \empty);
    l.startDissolve;
    ~tAssert.("a dissolve with nothing playing is refused", l.dissolving.not);
    ~tNear.("and leaves the axis untouched", l.dissolvePos, 0.0, 1e-9);
}.value;

{
    var l = playing.();
    ~tPut.(l, \loopFrames, 0);
    ~tPut.(l, \lastResult, nil);
    l.startDissolve;
    ~tAssert.("a dissolve with no loop length is refused", l.dissolving.not);
}.value;

{
    // The reset that matters: a dissolve left at 1 would mean the NEXT loop
    // starts already silent, with the GUI showing full levels.
    var l = playing.();
    atDissolve.(l, 1.0);
    l.cancelDissolve;
    ~tNear.("cancelling resets the axis to 0", l.dissolvePos, 0.0, 1e-9);
    ~tEqArray.("and restores every level", mixes.(l), [1, 1, 1], 1e-9);
}.value;

// REGRESSION, found by test-gesture-fuzz.scd — the sequence was
// [dissolveStopsOff, …, armDissolve, …, rampDone].
//
// A ramp that runs to the end WITHOUT stopping playback leaves every level at
// zero and the loop still rolling. It used to lower `dissolving` on the way out,
// which said the ending was over while nothing was audible — and since both
// surfaces keyed "take it back" off that flag, the next press started a SECOND
// ending from silence instead of undoing the first. A looper reading PLAYING,
// no lamp lit, nothing to hear, and no gesture left that brings it back.
//
// `dissolving` now means "the ending is in effect", so the ramp running out
// leaves it up and only a cancel lowers it.
{
    var l = playing.();
    l.dissolveStops = false;
    l.startDissolve;
    atDissolve.(l, 1.0);              // the ramp reaches the end
    ~tEqArray.("a finished non-stopping dissolve leaves every level at zero",
        mixes.(l), [0, 0, 0], 1e-9);
    ~tAssert.("and says so, so the silence is explained on screen", l.dissolving);

    l.toggleDissolve;
    ~tEqArray.("pressing Dissolve again restores, rather than re-running the ending",
        mixes.(l), [1, 1, 1], 1e-9);
    ~tAssert.("and leaves no dissolve armed", l.dissolving.not);
    ~tNear.("with the axis back home", l.dissolvePos, 0.0, 1e-9);
}.value;

// The same state reached the other way: whatever leaves the axis down, the
// toggle's job is to bring it back rather than start a new ending from silence.
{
    var l = playing.();
    atDissolve.(l, 1.0);
    l.toggleDissolve;
    ~tEqArray.("an axis left down is restored by the toggle whatever put it there",
        mixes.(l), [1, 1, 1], 1e-9);
    ~tAssert.("and no dissolve is armed by that press", l.dissolving.not);
}.value;

// The default path must be exactly what it was: with dissolveStops on, the
// ramp's own stopPlayback has already reset the axis before anyone can press.
{
    var l = playing.();
    l.toggleDissolve;
    ~tAssert.("from rest the toggle arms a dissolve", l.dissolving);
    l.toggleDissolve;
    ~tAssert.("and pressing again aborts it", l.dissolving.not);
    ~tNear.("leaving the axis at home", l.dissolvePos, 0.0, 1e-9);
}.value;

{
    var l = playing.();
    l.dissolveBars = 64;      // long enough not to complete during the test
    l.startDissolve;
    ~tAssert.("startDissolve arms", l.dissolving);
    l.stopPlayback;
    ~tAssert.("stopPlayback cancels a running dissolve", l.dissolving.not);
    ~tNear.("and resets the axis", l.dissolvePos, 0.0, 1e-9);
}.value;

{
    var l = playing.();
    l.dissolveBars = 64;
    l.startDissolve;
    l.clear;
    ~tAssert.("clear cancels a running dissolve", l.dissolving.not);
}.value;

// The dissolve routine calls stopPlayback, which cancels the dissolve and so
// reaches for the very routine that is running. Same hazard as the break's
// endBreak — see the regression note in test-break.scd.
{
    var l = playing.();
    var reachedEnd = false;
    var r;
    ~tPut.(l, \dissolvePos, 0.5);
    ~tPut.(l, \dissolving, true);
    r = Routine { l.cancelDissolve; reachedEnd = true };
    ~tPut.(l, \dissolveRoutine, r);
    r.next;
    ~tAssert.("cancelDissolve survives running inside its own routine", reachedEnd);
    ~tNear.("and still resets the axis", l.dissolvePos, 0.0, 1e-9);
    ~tAssert.("and still clears the flag", l.dissolving.not);
}.value;

// ---- notifications ----------------------------------------------------------
{
    var l = playing.();
    var seen = List.new;
    var listener = SimpleController(l)
        .put(\intensity, { |o, what, val| seen.add(val) });
    l.intensity = 0.25;
    l.intensity = 0.75;
    ~tEqArray.("intensity notifies its dependents", seen.asArray, [0.25, 0.75], 1e-9);
    listener.remove;
}.value;

}.value;
