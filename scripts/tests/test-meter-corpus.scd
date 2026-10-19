// Meter detection against the recorded corpus in training-data/.
//
// This is the refactoring safety net that synthetic grids cannot be: real
// onsets off a real guitar, replayed through the REAL decision path — the same
// Looper:snapAnalysisToLoop that stopRecordStartPlay calls. The baseline below
// locks what the app decides TODAY, so any change to MeterAnalyzer, to the
// snapping, or to the fallback shows up here as a named loop rather than as a
// vague feeling that detection got worse.
//
// It is a LOCK, not an endorsement: three of the four loops currently disagree
// with the ground truth in their filename. Onset-detection quality is the known
// weak link, so those are recorded as known issues and this file's job is to
// tell you when one of them MOVES.
//
// scripts/eval_meter_analyzer.scd is the tuning counterpart — same corpus,
// prints accuracy for before/after comparison instead of asserting.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-meter-corpus");

{
// What the app decides today: name -> [numerator, denominator, bars, error].
// To add a loop, export it, run this file, and paste the reported line in.
var baseline = (
    'gerade':      [7,  8, 2, \lengthAnchored],
    'gerade-2':    [7,  8, 2, \lengthAnchored],
    'gerade-3':    [12, 8, 2, nil],
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
    r = Looper.snapAnalysisToLoop(r, full);
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
    if(r[\k] == truth["bars"].asInteger) { wantBars = wantBars + 1 };
};

// Bar count is the part that must not regress: it decides the loop's LENGTH, so
// getting it wrong makes the loop the wrong duration, which is audible
// immediately. It is currently perfect and should stay that way.
~tEq.("bar count is right for every loop in the corpus", wantBars, total);

// Signature accuracy is the known-weak number. Locked so an improvement gets
// noticed and a regression cannot hide behind "detection was always like that".
~tXfail.("signature accuracy is still 1 of " ++ total,
    wantSig == 1,
    wantSig.asString ++ "/" ++ total ++ " — onset quality is the known limit here");

if(unlocked > 0) {
    ("  " ++ unlocked ++ " loop(s) not yet in the baseline").postln;
};

MeterAnalyzer.fallbackNum   = origNum;
MeterAnalyzer.fallbackDenom = origDenom;
MeterAnalyzer.fallbackBars  = origBars;
}.value;
