// The meter analyser against every labelled take there is, under variants of
// its settings, side by side (2026-11-06, the whole loop's fit):
//   truth   training-data/*.json, labelled at export (Setup › Analysis ›
//           export, the meter and bars you name)
//   uneven  scripts/tests/fixtures/uneven-takes.json, the duo's uneven bars
//   hand    first takes in sessions/ moved by the next-reading switch: the
//           reading they settled on
//   played  first takes played on as heard: a weak label, the stage's reading
//   anch    the same, where that reading was the length-anchored fallback
// Verdicts as strength-check.scd's: yes, ≈ (the same tempo and beats in the
// loop, in other bars), no. The fixture and sessions/ are private; without
// them those groups are empty. Each take goes through the Looper's own path
// (analyze with its lead-in, then snapAnalysisToLoop), with the set's
// fallback meter.
//
//     sclang -u 58xxx scripts/meter-eval.scd       (a far port, beside megalooper)
//     ~evalVariants = [["name", [\classvar, value, ...]], ...]; then load it
// The default compares the analyser without and with the whole loop's fit.
(
var repo = thisProcess.nowExecutingPath !? { |p| p.dirname.dirname } ?? { Looper.repoRoot };
var ma = MeterAnalyzer;
var items = List.new, analyse, sameReading, gridSame, verdict, word, show, variants, table, groups;
var parseFallback;
AppClock.sched(600, { "watchdog: exiting".postln; 1.exit; nil });

parseFallback = { |s| var p = (s ? "7/8").asString.split($/); [p[0].asInteger, p[1].asInteger] };

// ---- the takes -------------------------------------------------------------
(repo +/+ "training-data/*.json").pathMatch.sort.do { |path|
    var d = File.readAllString(path).parseJSON, ai = d["analyzerInput"], t = d["groundTruth"];
    var first = (d["firstOnsetSec"] ? 0).asFloat;
    var on = ai["onsets"].collect(_.asFloat), st = ai["strengths"].collect(_.asFloat);
    var dur = ai["loopDur"].asFloat + first;
    var num = t["numerator"].asInteger, den = t["denominator"].asInteger, k = t["bars"].asInteger;
    items.add((name: d["name"].asString, group: \truth, dur: dur,
        onsets: on.collect { |x, i| [x + first, st[i]] }, pitches: nil, fallback: [7, 8], fallbackBars: 0,
        label: (numerator: num, denominator: den, k: k, bpm: 240 * num * k / (den * dur))));
};
{
    var path = repo +/+ "scripts/tests/fixtures/uneven-takes.json";
    if(File.exists(path)) {
        File.readAllString(path).parseJSON.do { |tk|
            var dur = tk["dur"].asFloat, bars = tk["bars"].collect(_.asInteger), den = tk["denominator"].asInteger;
            var label = ma.putBars((denominator: den, bpm: 240 * bars.sum / (den * dur)), bars);
            items.add((name: tk["set"].asString ++ "u", group: \uneven, dur: dur,
                onsets: tk["onsets"].collect { |p| [p[0].asFloat, p[1].asFloat] },
                pitches: tk["pitches"].collect { |p| p.collect(_.asFloat) },
                fallback: [7, 8], fallbackBars: 0, label: label));
        };
    };
}.value;
(LooperSessionRecorder.globQuote(repo +/+ "sessions") +/+ "*-events.jsonl").pathMatch.sort.do { |path|
    var events = LooperSessionRecorder.readEvents(path);
    var header = events.detect { |e| e[\ev] == "session" } ? ();
    LooperSessionRecorder.takesFrom(events).do { |tk, i|
        var lb = tk[\label], on = tk[\onsets].asArray;
        var anch = lb.notNil and: { lb[\error].notNil } and: { lb[\error].asString == "lengthAnchored" }
            and: { tk[\outcome] != \corrected };
        if((tk[\kind] == \take) and: { lb.notNil } and: { lb[\numerator].notNil } and: { lb[\error].isNil or: { anch } }
            and: { tk[\dur].notNil } and: { on.size >= 2 }) {
            items.add((name: PathName(path).fileName.keep(13) ++ "#" ++ i,
                group: case { anch } { \anch } { tk[\outcome] == \corrected } { \hand } { \played },
                dur: tk[\dur].asFloat, onsets: on.collect { |p| [p[0].asFloat, p[1].asFloat] },
                pitches: tk[\pitches] !? { |ps| ps.collect { |p| p.collect(_.asFloat) } },
                fallback: parseFallback.(header[\fallback]), fallbackBars: (header[\fallbackBars] ? 0).asInteger,
                firstLogged: tk[\firstOnset], label: lb));
        };
    };
};

// ---- the Looper's own path ---------------------------------------------------
analyse = { |it|
    var on = it[\onsets], first = on[0][0], r;
    ma.fallbackNum = it[\fallback][0]; ma.fallbackDenom = it[\fallback][1]; ma.fallbackBars = it[\fallbackBars];
    r = ma.analyze(it[\dur] - first, on.collect { |p| p[0] - first }, on.collect { |p| p[1] },
        leadIn: first, pitches: it[\pitches]);
    MeterDecision.snapAnalysisToLoop(r, it[\dur])
};
sameReading = { |a, b|
    a.notNil and: { b.notNil } and: { a[\numerator] == b[\numerator] } and: { a[\denominator] == b[\denominator] }
        and: { (a[\k] ? 1) == (b[\k] ? 1) } and: { ma.barsOf(a) == ma.barsOf(b) }
};
gridSame = { |a, b|
    a.notNil and: { b.notNil } and: { sameReading.(a, b).not }
        and: { a[\bpm].notNil } and: { b[\bpm].notNil } and: { a[\numerator].notNil } and: { b[\numerator].notNil }
        and: { ((a[\bpm] - b[\bpm]).abs / a[\bpm].max(1e-6)) < 0.03 }
        and: { ((ma.unitsOf(a) / a[\denominator]) - (ma.unitsOf(b) / b[\denominator])).abs < 1e-6 }
};
verdict = { |r, ref| case { sameReading.(r, ref) } { \yes } { gridSame.(r, ref) } { \grid } { \no } };
word = { |v| switch(v, \yes, { "yes" }, \grid, { "≈" }, { "no" }) };
show = { |r| if(r.isNil or: { r[\numerator].isNil }) { "none" } {
    MeterDecision.readingString(r) ++ (if(r[\error].notNil) { " (anch)" } { "" }) } };

// ---- variants ----------------------------------------------------------------
// Each: [name, settings]: classvar setter -> value, applied before its run and
// put back after. The first is today's.
variants = ~evalVariants ? [["first fit", [\wholeLoop, false]], ["whole loop", [\wholeLoop, true]]];
table = variants.collect { |v|
    var saved = v[1].clump(2).collect { |kv| [kv[0], ma.perform(kv[0].asGetter)] };
    var out;
    v[1].clump(2).do { |kv| ma.perform(kv[0].asSetter, kv[1]) };
    out = items.collect { |it| var r = analyse.(it); [r, verdict.(r, it[\label])] };
    saved.do { |kv| ma.perform(kv[0].asSetter, kv[1]) };
    out
};

// ---- report --------------------------------------------------------------------
groups = [\truth, \uneven, \hand, \played, \anch];
("takes: " ++ groups.collect { |g| g ++ " " ++ items.count { |it| it[\group] == g } }.join(", ")).postln;
"".postln;
("group".padRight(8) ++ variants.collect { |v| v[0].padRight(18) }.join).postln;
groups.do { |g|
    var idx = items.selectIndices { |it| it[\group] == g };
    (g.asString.padRight(8) ++ variants.collect { |v, vi|
        var vs = idx.collect { |i| table[vi][i][1] };
        (vs.count(_ == \yes).asString ++ " yes " ++ vs.count(_ == \grid) ++ "≈ " ++ vs.count(_ == \no) ++ " no").padRight(18)
    }.join).postln;
};
"".postln;
"-- every take whose verdict differs between variants, and every truth/hand take:".postln;
items.do { |it, i|
    var vs = table.collect { |t| t[i][1] };
    if(vs.asSet.size > 1 or: { #[\truth, \hand].includes(it[\group]) }) {
        (it[\name].padRight(18) ++ it[\group].asString.padRight(7) ++ ("label " ++ show.(it[\label])).padRight(26)
            ++ variants.collect { |v, vi| (word.(vs[vi]) ++ " " ++ show.(table[vi][i][0])).padRight(30) }.join
            ++ "  [" ++ it[\onsets].size ++ " on]").postln;
    };
};
"EVAL DONE".postln;
0.exit;
)
