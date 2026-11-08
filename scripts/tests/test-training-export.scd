// The labelled-loop export (LooperTrainingExport, the Looper's until
// 2026-11-08): the file name from the labels, the sidecar's fields, and that
// a sidecar written now reads back, with parseJSON as the offline harnesses
// read it (meter-eval.scd, eval_meter_analyzer.scd, test-meter-corpus.scd),
// as the one a take of the corpus was written with: a take rebuilt from a
// sidecar in training-data/ and written again carries the same analyser input.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-training-export");

{
var root = thisProcess.nowExecutingPath.dirname.dirname.dirname;
var dir = ~tTempPath.("training-export");
var corpus = (root +/+ "training-data" +/+ "*.json").pathMatch.sort;
// parseJSON answers numbers as Strings: back to Integers and Floats as written.
var old, take, path, back, why, num = { |x| var t = x.asString; if(t.includes($.) or: { t.includes($e) }) { t.asFloat } { t.asInteger } };

~tEq.("a name keeps letters and digits; spaces, '_' and '-' become '-'; none left is loop",
    [LooperTrainingExport.safeName("My take_1!"), LooperTrainingExport.safeName("§§"), LooperTrainingExport.safeName("")],
    ["My-take-1", "loop", "loop"]);
~tEq.("the file name says the labels, the tempo they imply and the time",
    LooperTrainingExport.baseName("gerade", 4, 4, 2, 105, "260717-141813"), "gerade_4-4_2bars_105bpm_260717-141813");
~tEq.("the tempo is the labels' over the measured length (a corpus take: 2 bars of 4/4 in 4.575 s)",
    LooperTrainingExport.bpmOf(4, 4, 2, 219606 / 48000), 105);
~tEq.("no loop, nothing exported", LooperTrainingExport.export((loopFrames: 0), dir, "x", 4, 4, 1), nil);

~tAssert.("the corpus holds sidecars to check against", corpus.notEmpty, (root +/+ "training-data").asString);
corpus.do { |file|
    old = File.readAllString(file).parseJSON;
    take = (
        loopFrames: num.(old["loopFrames"]).asInteger, sampleRate: num.(old["sampleRate"]),
        onsets: old["rawOnsets"].collect { |p| [num.(p[0]), num.(p[1])] },
        loopDur: num.(old["analyzerInput"]["loopDur"]) + num.(old["firstOnsetSec"]),
        lastResult: old["detected"] !? { |d| var e = (); d.keysValuesDo { |k, v| e.put(k.asSymbol, if(k == "error") { v } { v !? { num.(v) } }) }; e }
    );
    path = dir +/+ PathName(file).fileName;
    why = LooperTrainingExport.writeSidecar(path, take, old["name"],
        old["groundTruth"]["numerator"].asInteger, old["groundTruth"]["denominator"].asInteger,
        old["groundTruth"]["bars"].asInteger, old["groundTruth"]["bpm"].asInteger, old["exportedAt"]);
    back = (MegaFiles.readText(path) ? "").parseJSON;
    ~tEq.(PathName(file).fileName ++ ": written again, it reads back with parseJSON, labelled, and says its format",
        [why, back["name"], back["groundTruth"]["numerator"], back["groundTruth"]["bars"], back["exportedAt"], back["format"]],
        [nil, old["name"], old["groundTruth"]["numerator"], old["groundTruth"]["bars"], old["exportedAt"], LooperTrainingExport.format]);
    ~tAssert.("...the analyser's input as it was: its length, every onset and strength",
        (num.(back["analyzerInput"]["loopDur"]) - num.(old["analyzerInput"]["loopDur"])).abs < 1e-9
            and: { back["analyzerInput"]["onsets"].size == old["analyzerInput"]["onsets"].size }
            and: { [back["analyzerInput"]["onsets"], old["analyzerInput"]["onsets"]].flop.every { |p| (num.(p[0]) - num.(p[1])).abs < 1e-9 } }
            and: { [back["analyzerInput"]["strengths"], old["analyzerInput"]["strengths"]].flop.every { |p| (num.(p[0]) - num.(p[1])).abs < 1e-9 } },
        back["analyzerInput"].asString.keep(200));
    ~tEq.("...and the analyser's answer, an error as a word",
        [back["detected"] !? { |d| d["error"] }, back["detected"] !? { |d| d["numerator"] }],
        [old["detected"] !? { |d| d["error"] }, old["detected"] !? { |d| d["numerator"] }]);
};

take = (loopFrames: 48000, sampleRate: 48000, onsets: [], loopDur: 1.0, lastResult: nil);
back = LooperTrainingExport.sidecar(take, "empty", 4, 4, 1, 240, "x");
~tEq.("a take with no onsets and no reading: an empty input, null for the answer",
    [back[\firstOnsetSec], back[\analyzerInput][\onsets], back[\analyzerInput][\loopDur], back[\detected]], [0, [], 1.0, nil]);
~tRemoveTree.(dir);
}.value;
