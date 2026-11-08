// Meter detection against the recorded corpus in training-data/.
//
// This is the refactoring safety net that synthetic grids cannot be: real
// onsets off a real guitar, replayed through the REAL decision path — the same
// Looper:snapAnalysisToLoop that stopRecordStartPlay calls. The baseline below
// locks what the app decides TODAY, so any change to MeterAnalyzer, to the
// snapping, or to the fallback shows up here as a named loop rather than as a
// vague feeling that detection got worse.
//
// It is a LOCK, not an endorsement: where a loop disagrees with the ground
// truth in its filename, that is recorded as a known issue, and this file's job
// is to tell you when one of them MOVES. Since 2026-11-06 the whole loop's fit
// (MeterAnalyzer.wholeLoop) reads five of the seven right; gerade-3 is still
// 12/8, and gerade-4, played as one bar of 8/4, comes out as two of 4/4, the
// same beats: 8/4 is not a meter the analyser looks for.
//
// scripts/eval_meter_analyzer.scd is the tuning counterpart — same corpus,
// prints accuracy for before/after comparison instead of asserting.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-meter-corpus");

{
// What the app decides today: name -> [numerator, denominator, bars, error].
// To add a loop, export it, run this file, and paste the reported line in.
var baseline = (
    'gerade':      [4,  4, 2, nil],
    'gerade-2':    [4,  4, 2, nil],
    'gerade-3':    [12, 8, 2, nil],
    'gerade-4':    [4,  4, 2, nil],
    'gerade-5':    [4,  4, 1, nil],
    'gerade-6':    [4,  4, 4, nil],
    'ikebana2000': [5,  8, 4, nil]
);
// Ground truth is in the filename, and where the baseline disagrees with it the
// mismatch is a known issue rather than a test failure.
var wantSig = 0, wantBars = 0, total = 0, unlocked = 0;
var dir, files;
var origNum   = MeterAnalyzer.fallbackNum;
var origDenom = MeterAnalyzer.fallbackDenom;
var origBars  = MeterAnalyzer.fallbackBars;

// setup-model.scd sets 7/8 at boot, so length-anchored takes must be scored
// against that or this file would measure a configuration nobody plays.
MeterAnalyzer.fallbackNum   = 7;
MeterAnalyzer.fallbackDenom = 8;
MeterAnalyzer.fallbackBars  = 0;

dir = thisProcess.nowExecutingPath.dirname.dirname.dirname +/+ "training-data";
files = (dir +/+ "*.json").pathMatch.sort;

~tAssert.("the corpus is present", files.notEmpty,
    "no .json sidecars under " ++ dir);

files.do { |path|
    var d = File.readAllString(path).parseJSON;
    var ai = d["analyzerInput"];
    var name = d["name"].asString;
    var key = name.asSymbol;
    var want = baseline[key];
    var full = d["loopDurSec"].asFloat;
    var truth = d["groundTruth"];
    var r, got;

    // The real path: analyse the post-onset span, then snap to the take's
    // actual length. Calling Looper's own method rather than reproducing it is
    // the point — a private copy of this decision could drift from the app and
    // score a take differently from the way it was actually decided.
    r = MeterAnalyzer.analyze(
        ai["loopDur"].asFloat,
        ai["onsets"].collect { |v| v.asFloat },
        ai["strengths"].collect { |v| v.asFloat },
        leadIn: (d["firstOnsetSec"] ? 0).asFloat);
    r = MeterDecision.snapAnalysisToLoop(r, full);
    got = [r[\numerator], r[\denominator], r[\k], r[\error]];
    total = total + 1;

    if(want.isNil) {
        // A newly exported loop. Reported, not failed: collecting training data
        // should not break the build, but the baseline does need locking before
        // this loop protects anything.
        unlocked = unlocked + 1;
        ("  new   " ++ name ++ " — baseline not locked, add: '" ++ name
            ++ "': " ++ got.asCompileString).postln;
    } {
        ~tEq.(name ++ ": detection unchanged", got, want);
    };

    // Independently of the lock, track accuracy against the filename's truth so
    // the summary below is about musical correctness, not just stability.
    if((r[\numerator] == truth["numerator"].asInteger)
        and: { r[\denominator] == truth["denominator"].asInteger }) {
        wantSig = wantSig + 1;
    };
    // The bars, or the same beats in other bars (two of 4/4 for one of 8/4):
    // the loop's length in the reading's beats is what must hold.
    if((r[\k] == truth["bars"].asInteger) or: {
        r[\numerator].notNil and: { ((r[\numerator] * r[\k] / r[\denominator])
            - (truth["numerator"].asInteger * truth["bars"].asInteger / truth["denominator"].asInteger)).abs < 1e-9 } }) {
        wantBars = wantBars + 1 };
};

// Bar count is the part that must not regress: it decides the loop's LENGTH, so
// getting it wrong makes the loop the wrong duration, which is audible
// immediately. It is currently perfect and should stay that way (counting the
// same beats in other bars as right: see above).
~tEq.("bar count is right for every loop in the corpus", wantBars, total);

// Signature accuracy is the known-weak number. Locked so an improvement gets
// noticed and a regression cannot hide behind "detection was always like that".
// 1 of 4 until 2026-11-06; the whole loop's fit made it 5 of 7 (gerade-3's
// 12/8 and gerade-4's 8/4 are the two).
~tXfail.("signature accuracy is still 5 of " ++ total,
    wantSig == 5,
    wantSig.asString ++ "/" ++ total ++ " — gerade-3 reads 12/8; 8/4 (gerade-4) is no meter the analyser looks for");

if(unlocked > 0) {
    ("  " ++ unlocked ++ " loop(s) not yet in the baseline").postln;
};

MeterAnalyzer.fallbackNum   = origNum;
MeterAnalyzer.fallbackDenom = origDenom;
MeterAnalyzer.fallbackBars  = origBars;
}.value;
