// Meter-analysis evaluation harness.
//
// Scores MeterAnalyzer against the labelled loops exported by the GUI (see
// Looper.exportTrainingLoop) and prints a per-loop PASS/FAIL plus a summary
// accuracy — so a tweak to the analyzer's classvars or scoring yields an
// immediate before/after number. This is the TUNING tool; the pass/fail lock
// that protects refactoring lives in scripts/tests/test-meter-corpus.scd.
//
// Run: select this whole block in the IDE and evaluate, OR
//     /Applications/SuperCollider.app/Contents/MacOS/sclang scripts/eval_meter_analyzer.scd
// No server or audio needed — pure onset replay. Point it at any folder by
// setting ~trainingDir first:
//     ~trainingDir = "/path/to/some/loops"; then evaluate this file.
(
    var dir, files, total = 0, sigOk = 0, barOk = 0, bpmOk = 0;
    var savedNum, savedDenom, savedBars;

    // Reproduce the runtime fallback meter (setup-model.scd sets 7/8) so
    // length-anchored takes are scored the way the app actually decided them.
    // Restored at the end — these are class variables.
    savedNum   = MeterAnalyzer.fallbackNum;
    savedDenom = MeterAnalyzer.fallbackDenom;
    savedBars  = MeterAnalyzer.fallbackBars;
    MeterAnalyzer.fallbackNum   = 7;
    MeterAnalyzer.fallbackDenom = 8;
    MeterAnalyzer.fallbackBars  = 0;

    dir = ~trainingDir ? (
        thisProcess.nowExecutingPath !? { |p| p.dirname.dirname +/+ "training-data" }
            ?? { Looper.repoRoot +/+ "training-data" });

    if(File.exists(dir).not) {
        ("Eval: training-data directory not found: " ++ dir).warn;
    } {
        files = (dir +/+ "*.json").pathMatch.sort;
        if(files.isEmpty) {
            ("Eval: no .json sidecars in " ++ dir
                ++ " — export some labelled loops first.").postln;
        } {
            ("=== Evaluating " ++ files.size ++ " loop(s) in " ++ dir
                ++ " ===").postln;
            files.do { |path|
                var d     = File.readAllString(path).parseJSON;
                var ai    = d["analyzerInput"];
                var truth = d["groundTruth"];
                var full  = d["loopDurSec"].asFloat;
                var wantNum   = truth["numerator"].asInteger;
                var wantDenom = truth["denominator"].asInteger;
                var wantBars  = truth["bars"].asInteger;
                var wantBpm   = truth["bpm"].asFloat;
                var r, sigMatch, barMatch, bpmMatch;

                // Analyse the post-onset span, then hand the result to the
                // Looper's OWN snapping decision. Calling the real method
                // rather than reproducing it is the point: this file used to
                // carry its own copy, which could drift from the app and score
                // a take differently from the way it was actually decided.
                r = MeterAnalyzer.analyze(
                    ai["loopDur"].asFloat,
                    ai["onsets"].collect { |v| v.asFloat },
                    ai["strengths"].collect { |v| v.asFloat });
                r = Looper.snapAnalysisToLoop(r, full);

                sigMatch = (r.numerator == wantNum)
                    and: { r.denominator == wantDenom };
                barMatch = (r.k == wantBars);
                bpmMatch = r.bpm.notNil and: { (r.bpm - wantBpm).abs < 2.0 };
                total = total + 1;
                if(sigMatch) { sigOk = sigOk + 1 };
                if(barMatch) { barOk = barOk + 1 };
                if(bpmMatch) { bpmOk = bpmOk + 1 };

                ("[" ++ (sigMatch.if("PASS", "FAIL")) ++ "] "
                    ++ PathName(path).fileNameWithoutExtension
                    ++ "\n        want " ++ wantNum ++ "/" ++ wantDenom
                        ++ " " ++ wantBars ++ "bars @ " ++ wantBpm ++ " bpm"
                    ++ "\n        got  " ++ (r.numerator ? "?") ++ "/"
                        ++ (r.denominator ? "?") ++ " " ++ (r.k ? "?") ++ "bars @ "
                        ++ (r.bpm !? { |b| b.round(0.1) } ? "?") ++ " bpm"
                    ++ (barMatch.if("", " [bars off]"))
                    ++ (bpmMatch.if("", " [bpm off]"))
                    ++ (r.error !? { |e| " (" ++ e ++ ")" } ? "")).postln;
            };
            ("=== " ++ total ++ " loops: signature " ++ sigOk ++ "/" ++ total
                ++ ", bars " ++ barOk ++ "/" ++ total
                ++ ", bpm " ++ bpmOk ++ "/" ++ total ++ " ===").postln;
        };
    };

    MeterAnalyzer.fallbackNum   = savedNum;
    MeterAnalyzer.fallbackDenom = savedDenom;
    MeterAnalyzer.fallbackBars  = savedBars;

    // Headless, exiting is essential: without it sclang idles forever and,
    // because its stdout is block-buffered when redirected, the run produces a
    // hang and no output at all. In the IDE it must NOT exit — that would kill
    // the interpreter mid-session, loop and all.
    if(Platform.ideName != "scide") { 0.exit };
)
