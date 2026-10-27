// megalooper — headless test suite.
//
//     /Applications/SuperCollider.app/Contents/MacOS/sclang scripts/tests/run-tests.scd
//
// No server, no windows, no MIDI, no audio hardware. Exits non-zero on any
// failure, so it works as a pre-commit hook alongside scripts/check.scd:
//
//     check.scd      the boot scripts parse, load and define what boot calls
//     run-tests.scd  the model's logic still does what it did
//
// Run one file on its own by evaluating it in the IDE — each test file loads
// the harness itself — or from here:
//
//     ~tOnly = "test-chain-timing"; then run this file.
//
// What is and is not covered: everything here is pure language-side logic plus
// source-level guards. Nothing that needs scsynth is tested — SynthDef graphs,
// real onset detection, actual latency and the GUI all still need the rig. See
// test-source-guards.scd for how the untestable duplication is held in check.
(
var dir = thisProcess.nowExecutingPath !? { |p| p.dirname }
    ?? { Looper.repoRoot +/+ "scripts" +/+ "tests" };
var files = [
    "test-megafiles.scd",
    "test-synthdefs.scd",
    "test-onset-notes.scd",
    "test-grains-follow.scd",
    "test-chain-timing.scd",
    "test-preset-storage.scd",
    "test-preset-bar.scd",
    "test-granular-presets.scd",
    "test-session-recorder.scd",
    "test-bbcut-presets.scd",
    "test-loop-position.scd",
    "test-beat-count.scd",
    "test-count-lights.scd",
    "test-halftime.scd",
    "test-break.scd",
    "test-arc.scd",
    "test-reading.scd",
    "test-gesture-fuzz.scd",
    "test-calibrator.scd",
    "test-meter-analyzer.scd",
    "test-meter-corpus.scd",
    "test-uneven-bars.scd",
    "test-ranges.scd",
    "test-megasa-sound.scd",
    "test-megasa.scd",
    "test-megasa-chains.scd",
    "test-megasa-utility.scd",
    "test-megasa-edits.scd",
    "test-megasa-drumchain.scd",
    "test-megasa-bass.scd",
    "test-megasa-random.scd",
    "test-megasa-noteseq.scd",
    "test-megasa-wave.scd",
    "test-megasa-instrument.scd",
    "test-megasa-keep.scd",
    "test-megaremote.scd",
    "test-megaremote-sets.scd",
    "test-sa-sounds.scd",
    "test-megasa-plugins.scd",
    "test-theme-contrast.scd",
    "test-megadrums.scd",
    "test-megadrums-sched.scd",
    "test-megadrums-fx.scd",
    "test-megadrums-newloop.scd",
    "test-session-midi.scd",
    "test-midimap.scd",
    "test-miditargets.scd",
    "test-midi-equivalence.scd",
    "test-midimap-learn.scd",
    "test-midimap-store.scd",
    "test-midiback.scd",
    "test-audio-settings.scd",
    "test-source-guards.scd"
];
var started = Main.elapsedTime;
var failed;

(dir +/+ "_harness.scd").load;
~tReset.();

if(~tOnly.notNil) {
    files = files.select { |f| f.contains(~tOnly.asString) };
    if(files.isEmpty) {
        ("run-tests: ~tOnly = " ++ ~tOnly ++ " matched no file.").warn;
    };
};

files.do { |f|
    var counted = { (((~tState[\pass] + ~tState[\fail]) + ~tState[\xfail]) + ~tState[\xpass]) + (~tState[\skip] ? 0) };
    var before = counted.value;
    // The node IDs the default server has handed out: one is taken here, so a
    // file that made none leaves the next one just after it (_harness.scd's
    // trap; a node made there would have been made on a running megalooper).
    var trapBefore = Server.default.nextNodeID, trapMade;
    // Each file is protected on its own. An unhandled throw inside one must not
    // take the rest of the run down with it — and in a headless run it would do
    // worse than that: sclang would never reach the exit below, so it would
    // idle forever with its block-buffered stdout unflushed, and the run would
    // produce a hang and no output rather than a failure.
    try {
        (dir +/+ f).load;
    } { |err|
        ~tState[\file] = f;
        ~tFail.("file did not finish",
            err.class.asString ++ ": " ++ (err.errorString ? "?"));
    };
    // A file that does not parse is no throw: load posts the parse error and
    // runs nothing, and the run would pass without it.
    if(counted.value == before) {
        ~tState[\file] = f;
        ~tFail.("file ran no assertion", "does it parse? (a parse error is posted above)");
    };
    trapMade = (Server.default.nextNodeID - trapBefore) - 1;
    if(trapMade != 0) {
        ~tState[\file] = f;
        ~tFail.("file made nodes on the default server",
            trapMade.asString ++ " node(s): a test names no server somewhere (Group.tail(nil), Synth(\\x) with no "
            ++ "target). Outside the test harness that server is a running megalooper's.");
    };
};

failed = ~tReport.();
("ran in " ++ (Main.elapsedTime - started).round(0.01) ++ " s").postln;

if(failed == 0) {
    "TESTS PASSED".postln;
    0.exit;
} {
    ("TESTS FAILED — " ++ failed ++ " assertion(s)").postln;
    1.exit;
};
)
