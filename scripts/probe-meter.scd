// megalooper — the meter analyser's PERCEPTION MAP.
//
// A perturbation experiment, not a test. It asks the analyser what it HEARS
// across the whole space of things a duo might play into it — every standard
// meter at every tempo over one, two and four bars — and then damages each
// take the way a room does: timing jitter, dropped hits, ghost onsets, flams,
// wrong or absent accents, the second record press landing early or late, a
// late first note. It also plays it things that have no right answer (a bar of
// 7/8 followed by a bar of 4/4, a hemiola, a rubato take, bar lines alone) and
// records what it says anyway.
//
// Nothing here asserts. The question is not "is it right" but "where does the
// answer flip, which wrong answers are stable, and what does it do when the
// input is outside anything it was built for". Those stable wrong answers are
// the analyser's attractors, and knowing them is how a player learns to play
// TO the detector — the way one learns a resonant room. The findings, with the
// reasoning, are written up in docs/dev/meter-perception.md; this file is how they
// are re-derived after the analyser changes.
//
// Everything goes through the REAL decision path — MeterAnalyzer.analyze on the
// post-first-onset span, then Looper.snapAnalysisToLoop on the full take — with
// the onsets prepared exactly as stopRecordStartPlay prepares them, and the
// detector's own mingap (~107 ms) applied to the synthetic onsets, because the
// detector could never have reported two hits closer than that. The fallback
// meter is set to 7/8 as setup-model.scd sets it, so a length-anchored take
// reads as the app would show it.
//
// Run headless — no server, no audio:
//
//     /Applications/SuperCollider.app/Contents/MacOS/sclang scripts/probe-meter.scd
//
// or evaluate the block in the IDE. Knobs, set BEFORE evaluating:
//
//     ~probeQuick  = true;           // a fraction of the sweep, for a smoke run
//     ~probeSeed   = 1;              // the RNG seed for the stochastic damage
//     ~probeReps   = 5;              // repetitions of each stochastic damage
//     ~probeTempos = [60, 120];      // quarter-note BPM points to sweep
//     ~probeBars   = [1, 2];         // bar counts per take
//     ~probeCsv    = "/path.csv";    // every trial as one row, for analysis elsewhere
//     ~probeSkipMetric = true;       // only the takes with no right answer (fast)
//     ~probeOnly   = "7/8";          // only the families whose name contains this
//
// What is and is not modelled. Onsets are POINTS: there is no audio here, so
// what Onsets.kr does to a real attack is out of scope — the detector's output
// is what is being damaged, not its input. The clean rows are therefore an
// idealised ear (every hit exactly on its grid point), and the jitter rows are
// closer to what a take looks like. Accents follow the metrical role of each
// hit (downbeat loudest, group heads next), which is how a template-matching
// analyser would like them; a guitarist's accents are not that tidy, which is
// what the flat and inverted rows are for.
//
// The lock that protects refactoring is scripts/tests/test-meter-corpus.scd,
// and the tuning number against real loops is scripts/eval_meter_analyzer.scd.
// This is the third instrument: the one that says what the analyser is like.

(
var quick    = ~probeQuick ? false;
var seed     = ~probeSeed ? 20260925;
var tempos   = ~probeTempos ? (if(quick) { [65, 95, 130, 185] }
                                        { [55, 65, 75, 85, 95, 105, 115, 130, 145, 165, 185, 210] });
var barsList = ~probeBars ? (if(quick) { [1, 2] } { [1, 2, 4] });
var reps     = ~probeReps ? (if(quick) { 1 } { 3 });
var csvPath  = ~probeCsv ? ((Platform.defaultTempDir ? "/tmp") +/+ "megalooper-probe-meter.csv");
var verbose  = ~probeVerbose ? true;   // one progress line per family, so a long run shows it is alive
var trace    = ~probeTrace ? false;    // one line per TRIAL, before it runs — for finding a hang
var only     = ~probeOnly;             // run just the families (and specials) whose name contains this
var skipMetric = ~probeSkipMetric ? false;   // specials only — the metric sweep is the slow part
var started  = Main.elapsedTime;
var analyses = 0, analyseTime = 0;
var savedNum, savedDenom, savedBars, savedCands;
var mingap = 0.107;   // Onsets.kr mingap 20 frames at 256-sample hops, 48 kHz
var families, specials, perts, ritard;
var unitOf, buildTake, tidy, perturb, decide, classify, answerOf, codeOf;
var rankOf, marginOf, altsOf;
var rows = List.new, byKey = Dictionary.new, keyOf;
var runTrial, sweepMetric, sweepSpecials;
var grid, pct, section, report, writeCsv;
var sigOf = { |r| "" ++ r[\numerator] ++ "/" ++ r[\denominator] };

// ------------------------------------------------------------ families ------
// Positions are in DENOMINATOR units within one bar (eighths for x/8, quarters
// for x/4); acc is the salience of each hit, 0..1, by its metrical role.
families = [
    (name: "2/4 quarters",      num: 2,  denom: 4, pos: [0, 1],                acc: [1, 0.5]),
    (name: "3/4 waltz",         num: 3,  denom: 4, pos: [0, 1, 2],             acc: [1, 0.5, 0.5]),
    (name: "4/4 quarters",      num: 4,  denom: 4, pos: [0, 1, 2, 3],          acc: [1, 0.5, 0.7, 0.5]),
    (name: "4/4 eighths",       num: 4,  denom: 4, pos: (0..7) / 2,
        acc: [1, 0.3, 0.5, 0.3, 0.7, 0.3, 0.5, 0.3]),
    (name: "4/4 offbeats",      num: 4,  denom: 4, pos: [0, 1.5, 2, 3.5],      acc: [1, 0.6, 0.8, 0.6]),
    (name: "5/4",               num: 5,  denom: 4, pos: (0..4),                acc: [1, 0.5, 0.7, 0.5, 0.5]),
    (name: "6/4",               num: 6,  denom: 4, pos: (0..5),                acc: [1, 0.5, 0.5, 0.7, 0.5, 0.5]),
    (name: "7/4",               num: 7,  denom: 4, pos: (0..6),                acc: [1, 0.5, 0.5, 0.5, 0.7, 0.5, 0.5]),
    (name: "5/8 (2+3)",         num: 5,  denom: 8, pos: (0..4),                acc: [1, 0.3, 0.7, 0.3, 0.3]),
    (name: "6/8 compound",      num: 6,  denom: 8, pos: (0..5),                acc: [1, 0.3, 0.3, 0.7, 0.3, 0.3]),
    (name: "7/8 (2+2+3)",       num: 7,  denom: 8, pos: (0..6),                acc: [1, 0.3, 0.7, 0.3, 0.7, 0.3, 0.3]),
    (name: "7/8 (3+2+2)",       num: 7,  denom: 8, pos: (0..6),                acc: [1, 0.3, 0.3, 0.7, 0.3, 0.7, 0.3]),
    (name: "7/8 heads only",    num: 7,  denom: 8, pos: [0, 2, 4],             acc: [1, 0.7, 0.7]),
    (name: "9/8 compound",      num: 9,  denom: 8, pos: (0..8),
        acc: [1, 0.3, 0.3, 0.7, 0.3, 0.3, 0.7, 0.3, 0.3]),
    (name: "11/8 (2+2+2+2+3)",  num: 11, denom: 8, pos: (0..10),
        acc: [1, 0.3, 0.7, 0.3, 0.7, 0.3, 0.7, 0.3, 0.7, 0.3, 0.3]),
    (name: "12/8 compound",     num: 12, denom: 8, pos: (0..11),
        acc: [1, 0.3, 0.3, 0.7, 0.3, 0.3, 0.7, 0.3, 0.3, 0.7, 0.3, 0.3])
];

// Seconds per denominator unit at a quarter-note BPM — the same tempo the
// analyser reports (240 * k * num / (denom * loopDur)), so truth and answer are
// in one currency.
unitOf = { |denom, bpm| if(denom == 8) { 30 / bpm } { 60 / bpm } };

buildTake = { |fam, bpm, bars|
    var unit   = unitOf.(fam[\denom], bpm);
    var barDur = fam[\num] * unit;
    var onsets = List.new;
    bars.do { |b|
        fam[\pos].do { |p, i|
            onsets.add([(b * barDur) + (p * unit), fam[\acc][i]]);
        };
    };
    (onsets: onsets.asArray, loopSecs: bars * barDur, unit: unit,
        truth: (num: fam[\num], denom: fam[\denom], bars: bars, bpm: bpm))
};

// Things with no right answer, or a right answer the analyser's vocabulary
// cannot express. Each generator returns the same shape buildTake does; a nil
// truth num means "report what it said, do not score it".
ritard = { |bpm, bars, amount|
    var unit0 = 60 / bpm;
    var acc = [1, 0.3, 0.5, 0.3, 0.7, 0.3, 0.5, 0.3];
    var onsets = List.new, t = 0, count = bars * 8;
    count.do { |i|
        var frac = i / count;
        onsets.add([t, acc[i % 8]]);
        t = t + ((unit0 / 2) * (1 + (amount * frac)));
    };
    (onsets: onsets.asArray, loopSecs: t, unit: unit0,
        truth: (num: 4, denom: 4, bars: bars, bpm: nil))
};

specials = [
    (name: "bar lines only (4/4)", gen: { |bpm, bars|
        var unit = 60 / bpm, barDur = 4 * unit;
        (onsets: Array.fill(bars, { |b| [b * barDur, 1.0] }),
            loopSecs: bars * barDur, unit: unit,
            truth: (num: 4, denom: 4, bars: bars, bpm: bpm))
    }),
    (name: "hemiola 3:2 in 4/4", gen: { |bpm, bars|
        var unit = 60 / bpm, barDur = 4 * unit;
        var pos = [0, 1, 2, 3, 4/3, 8/3], acc = [1, 0.5, 0.5, 0.5, 0.6, 0.6];
        var onsets = List.new;
        bars.do { |b| pos.do { |p, i| onsets.add([(b * barDur) + (p * unit), acc[i]]) } };
        (onsets: onsets.asArray, loopSecs: bars * barDur, unit: unit,
            truth: (num: 4, denom: 4, bars: bars, bpm: bpm))
    }),
    (name: "duo: 4/4 eighths + free bass", gen: { |bpm, bars|
        var unit = 60 / bpm, barDur = 4 * unit;
        var acc = [1, 0.3, 0.5, 0.3, 0.7, 0.3, 0.5, 0.3];
        var onsets = List.new;
        bars.do { |b|
            8.do { |i| onsets.add([(b * barDur) + (i * unit / 2), acc[i]]) };
            4.do { onsets.add([(b * barDur) + rrand(0.0, barDur), rrand(0.3, 0.6)]) };
        };
        (onsets: onsets.asArray, loopSecs: bars * barDur, unit: unit,
            truth: (num: 4, denom: 4, bars: bars, bpm: bpm))
    }),
    (name: "7/8 then 4/4, per pair", gen: { |bpm, bars|
        var unit = 30 / bpm;
        var accA = [1, 0.3, 0.7, 0.3, 0.7, 0.3, 0.3];
        var accB = [1, 0.3, 0.5, 0.3, 0.7, 0.3, 0.5, 0.3];
        var onsets = List.new, t = 0;
        bars.do {
            7.do { |i| onsets.add([t + (i * unit), accA[i]]) };
            t = t + (7 * unit);
            8.do { |i| onsets.add([t + (i * unit), accB[i]]) };
            t = t + (8 * unit);
        };
        (onsets: onsets.asArray, loopSecs: t, unit: unit,
            truth: (num: nil, denom: nil, bars: nil, bpm: bpm))
    }),
    (name: "ritardando 10% (4/4 8ths)", gen: { |bpm, bars| ritard.(bpm, bars, 0.10) }),
    (name: "ritardando 25% (4/4 8ths)", gen: { |bpm, bars| ritard.(bpm, bars, 0.25) }),
    (name: "rubato, no pulse", gen: { |bpm, bars|
        var unit = 60 / bpm, loopSecs = bars * 4 * unit;
        var n = (bars * 6).max(4);
        (onsets: Array.fill(n, { [rrand(0.0, loopSecs), rrand(0.2, 1.0)] }),
            loopSecs: loopSecs, unit: unit,
            truth: (num: nil, denom: nil, bars: nil, bpm: bpm))
    })
];

// ------------------------------------------------------------- damage -------
// One row per kind of harm a take meets on the way from the hands to the
// analyser. `random` marks the ones that need repetitions. Jitter is in
// MILLISECONDS, not in pulses: hands are late by an absolute amount, and the
// analyser's tolerance is relative (0.2 tau), so the same hands cost more at a
// fast tempo — that asymmetry is one of the things being mapped.
perts = [
    (name: "clean"),
    (name: "jitter 10 ms",     jitterMs: 10,  random: true),
    (name: "jitter 25 ms",     jitterMs: 25,  random: true),
    (name: "jitter 50 ms",     jitterMs: 50,  random: true),
    (name: "drop 20%",         drop: 0.2,     random: true),
    (name: "drop 40%",         drop: 0.4,     random: true),
    (name: "ghosts 2",         ghosts: 2,     random: true),
    (name: "ghosts 4",         ghosts: 4,     random: true),
    (name: "ghosts 8",         ghosts: 8,     random: true),
    (name: "flams 2",          flams: 2,      random: true),
    (name: "accents flat",     accents: \flat),
    (name: "accents inverted", accents: \inverted),
    (name: "no strengths",     accents: \none),
    (name: "stop -150 ms",     endErr: -0.15),
    (name: "stop -60 ms",      endErr: -0.06),
    (name: "stop +60 ms",      endErr: 0.06),
    (name: "stop +150 ms",     endErr: 0.15),
    (name: "stop +400 ms",     endErr: 0.40),
    (name: "lead 40 ms",       lead: 0.04),
    (name: "lead 150 ms",      lead: 0.15),
    // The bundle a real take carries all at once.
    (name: "human",            jitterMs: 12, drop: 0.15, ghosts: 2, endErrRand: 0.08,
        lead: 0.03, random: true)
];

// Sort, drop what falls outside the take, and apply the detector's mingap: two
// hits closer than ~107 ms are ONE event to Onsets.kr, and the louder reading
// is what the accent test would have seen (prFoldOverdubOnsets does the same).
tidy = { |onsets, loopSecs|
    var sorted = onsets.select { |p| (p[0] >= 0) and: { p[0] < loopSecs } }
        .sort { |a, b| a[0] < b[0] };
    var merged = List.new;
    sorted.do { |p|
        if(merged.notEmpty and: { (p[0] - merged.last[0]) < mingap }) {
            merged.last[1] = max(merged.last[1], p[1]);
        } {
            merged.add([p[0], p[1]]);
        };
    };
    merged
};

perturb = { |take, spec|
    var onsets   = List.newFrom(take[\onsets].collect { |p| p.copy });
    var loopSecs = take[\loopSecs];
    var lead     = spec[\lead] ? 0;
    var endErr   = spec[\endErr] ? 0;
    var peak;
    spec[\endErrRand] !? { |e| endErr = endErr + rrand(e.neg, e) };
    // A hit that jitters to before the record press is not lost, it is heard at
    // the press: the recorder starts there and the detector reports the attack
    // a frame or two later. Without the max, the first hit of every take — at
    // time 0 by construction — fell before the press half the time and the
    // tidy step below deleted it, so the jitter rows were measuring a missing
    // downbeat and not late hands. Found 2026-09-27 when 10 ms scored worse
    // than 25 ms; the map's first edition carried it.
    spec[\jitterMs] !? { |ms|
        var sigma = ms / 1000;
        onsets = onsets.collect { |p|
            [(p[0] + 0.0.gauss(sigma).clip(sigma * -3, sigma * 3)).max(0), p[1]]
        };
    };
    // Any hit may be missed, the downbeat included; a take keeps at least two.
    spec[\drop] !? { |prob|
        var kept = onsets.reject { prob.coin };
        if(kept.size < 2) { kept = onsets.copyRange(0, 1) };
        onsets = kept;
    };
    peak = onsets.collect { |p| p[1] }.maxItem ? 1;
    // Ghosts: the detector firing on noise or a decay — low salience, anywhere.
    spec[\ghosts] !? { |n|
        n.do {
            onsets.add([rrand(0.0, loopSecs), peak * rrand(0.05, 0.35)]);
        };
    };
    // Flams: a second trigger just past the mingap after a real hit.
    spec[\flams] !? { |n|
        n.do {
            var parent = onsets.choose;
            onsets.add([parent[0] + rrand(0.11, 0.17), parent[1] * rrand(0.3, 0.6)]);
        };
    };
    switch(spec[\accents],
        \flat,     { onsets = onsets.collect { |p| [p[0], 0.5] } },
        \inverted, {
            var lo = onsets.collect { |p| p[1] }.minItem;
            onsets = onsets.collect { |p| [p[0], (peak + lo) - p[1]] };
        }
    );
    // The first note lands `lead` after the record press; the stop press lands
    // `endErr` off the true end. frame 0 is the press, as in the Looper.
    onsets   = onsets.collect { |p| [p[0] + lead, p[1]] };
    loopSecs = loopSecs + lead + endErr;
    (onsets: tidy.(onsets, loopSecs).asArray, loopSecs: loopSecs,
        noStrengths: spec[\accents] == \none)
};

// The Looper's own preparation (stopRecordStartPlay): onsets relative to the
// first, the analysed span is what follows it, and the snap sees the full take.
decide = { |onsets, loopSecs, noStrengths|
    var first = if(onsets.isEmpty) { 0 } { onsets[0][0] };
    var rel   = onsets.collect { |p| p[0] - first };
    var str   = if(noStrengths) { nil } { onsets.collect { |p| p[1] } };
    var t0    = Main.elapsedTime, r;
    r = MeterAnalyzer.analyze(loopSecs - first, rel, str, leadIn: first);
    r = Looper.snapAnalysisToLoop(r, loopSecs);
    analyseTime = analyseTime + (Main.elapsedTime - t0);
    analyses = analyses + 1;
    r
};

// A length-anchored result is classified as the FALLBACK before anything else,
// even when the fallback meter happens to equal the truth: 7/8 out of a 7/8
// take that fit no grid is a setting agreeing with the input, not a detection.
classify = { |r, truth|
    var sigOk = truth[\num].notNil and: { r[\numerator] == truth[\num] }
        and: { r[\denominator] == truth[\denom] };
    var barOk = truth[\bars].notNil and: { r[\k] == truth[\bars] };
    var ratio = if(truth[\bars].notNil and: { r[\k].notNil }) { r[\k] / truth[\bars] } { nil };
    case
        { r[\error] == \insufficientOnsets } { \insufficient }
        { r[\error] == \lengthAnchored }     { \fallback }
        { truth[\num].isNil }                { \open }
        { sigOk.not }                        { \meter }
        { barOk }                            { \right }
        { ratio == 2 }                       { \double }
        { ratio == 0.5 }                     { \half }
        { \bars }
};

codeOf = { |cls|
    (right: ".", fallback: "F", insufficient: "i", meter: "M",
        double: "2", half: "h", bars: "B", open: "?")[cls]
};

// Where the truth sits in the analyser's OWN ranking: 1 when the answer is
// right, otherwise the position of the first alternative that snaps to the
// truth's meter and bar count, nil when it is not offered at all. A fallback
// offers nothing. This is the number that decides whether a "next reading"
// footswitch is worth building (roadmap item 9).
rankOf = { |r, truth, loopSecs|
    var found = nil;
    if(truth[\num].notNil and: { r[\candidates].notNil }) {
        r[\candidates].do { |c, i|
            var s;
            if(found.isNil) {
                s = Looper.snapAnalysisToLoop(c.copy, loopSecs);
                if((s[\numerator] == truth[\num]) and: { s[\denominator] == truth[\denom] }
                    and: { s[\k] == truth[\bars] }) { found = i + 1 };
            };
        };
    };
    found
};

// How far ahead the answer was: its score minus the runner-up's. nil when there
// was no runner-up. Small margins are the near-ties the map talked about.
marginOf = { |r|
    var c = r[\candidates];
    if(c.notNil and: { c.size >= 2 }) { c[0][\score] - c[1][\score] } { nil }
};

// The second and third readings, snapped, as short strings for the CSV.
altsOf = { |r, loopSecs|
    (r[\candidates] ? []).drop(1).keep(2).collect { |c|
        var s = Looper.snapAnalysisToLoop(c.copy, loopSecs);
        sigOf.(s) ++ " x" ++ s[\k] ++ (if((s[\sub] ? 1) > 1) { " sub" ++ s[\sub] } { "" })
    }
};

answerOf = { |r|
    if(r[\error] == \insufficientOnsets) {
        "insufficient (" ++ r[\onsetCount] ++ " onsets)"
    } {
        sigOf.(r) ++ " x" ++ r[\k] ++ " @" ++ (r[\bpm] ? 0).round(0.1)
            ++ (if((r[\sub] ? 1) > 1) { " sub" ++ r[\sub] } { "" })
            ++ (if(r[\error] == \lengthAnchored) { " (fallback)" } { "" })
    }
};

keyOf = { |famName, bpm, bars, pertName, rep|
    famName ++ "|" ++ bpm ++ "|" ++ bars ++ "|" ++ pertName ++ "|" ++ rep
};

// `bpm` and `bars` are the SWEEP's values — what was asked for — and key the
// row; `take[\truth]` is what the take really is and scores it. They differ for
// the specials, whose truth may have no tempo or no bar count at all.
runTrial = { |famName, take, spec, rep, bpm, bars, special = false|
    var p, r, cls, row, rank, margin, alts;
    if(trace) {
        ("    " ++ keyOf.(famName, bpm, bars, spec[\name], rep)).postln;
    };
    p = perturb.(take, spec);
    if(trace) {
        ("      damaged: " ++ p[\onsets].size ++ " onsets over "
            ++ p[\loopSecs].round(0.001) ++ " s"
            ++ (if(p[\noStrengths]) { ", no strengths" } { "" })).postln;
        ("      input: " ++ p[\onsets].collect { |o| [o[0].round(1e-6), o[1].round(1e-4)] }
            .asCompileString ++ " loopSecs " ++ p[\loopSecs]).postln;
    };
    r      = decide.(p[\onsets], p[\loopSecs], p[\noStrengths]);
    cls    = classify.(r, take[\truth]);
    rank   = rankOf.(r, take[\truth], p[\loopSecs]);
    margin = marginOf.(r);
    alts   = altsOf.(r, p[\loopSecs]);
    row = (family: famName, bpm: bpm, bars: bars,
        pert: spec[\name], rep: rep, truth: take[\truth], result: r,
        answer: answerOf.(r), cls: cls, onsetCount: p[\onsets].size,
        special: special, rank: rank, margin: margin, alts: alts,
        ncand: (r[\candidates] ? []).size,
        // The answer without its tempo, so answers at different tempos group.
        short: if(r[\error] == \insufficientOnsets) { "insufficient" } {
            sigOf.(r) ++ " x" ++ r[\k]
                ++ (if((r[\sub] ? 1) > 1) { " sub" ++ r[\sub] } { "" })
                ++ (if(r[\error] == \lengthAnchored) { " (fallback)" } { "" })
        });
    rows.add(row);
    byKey[keyOf.(famName, bpm, bars, spec[\name], rep)] = row;
    row
};

sweepMetric = {
    var run = if(only.isNil) { families } {
        families.select { |f| f[\name].contains(only.asString) } };
    run.do { |fam|
        if(verbose) { ("  sweeping " ++ fam[\name] ++ " ...").postln };
        tempos.do { |bpm|
            barsList.do { |bars|
                var take = buildTake.(fam, bpm, bars);
                perts.do { |spec|
                    var n = if(spec[\random] == true) { reps } { 1 };
                    n.do { |rep| runTrial.(fam[\name], take, spec, rep, bpm, bars) };
                };
            };
        };
    };
};

// The specials get the clean take and the human bundle only: the question for
// them is "what does it say", not "how far can it be pushed".
sweepSpecials = {
    var chosen = [perts[0], perts.last];
    var run = if(only.isNil) { specials } {
        specials.select { |f| f[\name].contains(only.asString) } };
    run.do { |sp|
        if(verbose) { ("  sweeping " ++ sp[\name] ++ " ...").postln };
        tempos.do { |bpm|
            [1, 2].do { |bars|
                var take = sp[\gen].value(bpm, bars);
                chosen.do { |spec|
                    var n = if(spec[\random] == true) { reps } { 1 };
                    n.do { |rep| runTrial.(sp[\name], take, spec, rep, bpm, bars, true) };
                };
            };
        };
    };
};

// ------------------------------------------------------------- report -------
pct = { |n, d| if(d > 0) { ((n / d) * 100).round.asInteger.asString.padLeft(4) } { "   -" } };

section = { |title|
    "".postln;
    ("== " ++ title).postln;
    "".postln;
};

grid = { |title, cellFn|
    var nameW = 20;
    (title).postln;
    ("".padRight(nameW) ++ tempos.collect { |b| b.asString.padLeft(4) }.join).postln;
    families.do { |fam|
        (fam[\name].padRight(nameW)
            ++ tempos.collect { |b| (cellFn.(fam, b) ? " ").padLeft(4) }.join).postln;
    };
};

report = {
    // The sixteen metric families only. The specials are scored where they can
    // be, but they are wrong by construction and have their own section.
    var metricRows = rows.select { |row| row[\special].not };
    var cleanRows  = metricRows.select { |row| row[\pert] == "clean" };

    section.("The clean map: one code per family x tempo, exact hits, exact stop press");
    ("  .  right meter, right bar count      F  no grid fit: the FALLBACK meter (7/8 here)")
        .postln;
    ("  M  a grid fit with the wrong meter    2  right meter, twice the bars (double tempo)")
        .postln;
    ("  h  right meter, half the bars          B  right meter, some other bar count")
        .postln;
    ("  i  fewer than two onsets").postln;
    "".postln;
    barsList.do { |bars|
        grid.("-- " ++ bars ++ " bar" ++ (if(bars > 1) { "s" } { "" }) ++ " recorded --",
            { |fam, bpm|
                var row = byKey[keyOf.(fam[\name], bpm, bars, "clean", 0)];
                row !? { codeOf.(row[\cls]) }
            });
        "".postln;
    };

    section.("What the wrong clean cells actually said");
    families.do { |fam|
        var wrong = cleanRows.select { |row|
            (row[\family] == fam[\name]) and: { row[\cls] != \right } };
        var counts = Dictionary.new;
        if(wrong.notEmpty) {
            wrong.do { |row|
                var k = row[\short] ++ " from " ++ row[\bars] ++ " bar(s)";
                counts[k] = (counts[k] ? 0) + 1;
            };
            (fam[\name].padRight(20) ++ counts.keys.asArray.sort.collect { |k|
                k ++ " x" ++ counts[k] }.join(", ")).postln;
        };
    };

    section.("Damage: how each kind of harm moves the answer (all metric families, tempos, bar counts)");
    ("  " ++ "damage".padRight(18) ++ "trials".padLeft(7) ++ "right%".padLeft(7)
        ++ "meter%".padLeft(7) ++ "bars%".padLeft(7) ++ "fallb%".padLeft(7)
        ++ "insuf%".padLeft(7)).postln;
    perts.do { |spec|
        var sel = metricRows.select { |row| row[\pert] == spec[\name] };
        var n = sel.size;
        var c = { |cls| sel.count { |row| row[\cls] == cls } };
        var barsWrong = c.(\bars) + c.(\double) + c.(\half);
        ("  " ++ spec[\name].padRight(18) ++ n.asString.padLeft(7)
            ++ pct.(c.(\right), n).padLeft(7) ++ pct.(c.(\meter), n).padLeft(7)
            ++ pct.(barsWrong, n).padLeft(7) ++ pct.(c.(\fallback), n).padLeft(7)
            ++ pct.(c.(\insufficient), n).padLeft(7)).postln;
    };

    // The whole passed list is ranked for this run (maxCandidates is lifted
    // below), so "absent" means the truth passed the fit nowhere — or the take
    // fell to the fallback, which offers nothing.
    section.("Ranked readings: where the truth sits in the analyser's own list (16 families)");
    ("  " ++ "damage".padRight(18) ++ "trials".padLeft(7) ++ "1st%".padLeft(6)
        ++ "2nd%".padLeft(6) ++ "3rd%".padLeft(6) ++ "4-8%".padLeft(6) ++ "9+%".padLeft(6)
        ++ "absent%".padLeft(8) ++ "  of absent, fallback%" ++ "  readings".padLeft(10)).postln;
    ["clean", "jitter 10 ms", "jitter 25 ms", "drop 20%", "ghosts 4",
        "accents flat", "stop +150 ms", "human"].do { |pname|
        var sel = metricRows.select { |row| row[\pert] == pname };
        var n = sel.size;
        var at = { |k| sel.count { |row| row[\rank] == k } };
        var mid = sel.count { |row| row[\rank].notNil and: { row[\rank] >= 4 } and: { row[\rank] <= 8 } };
        var deep = sel.count { |row| row[\rank].notNil and: { row[\rank] >= 9 } };
        var absent = sel.count { |row| row[\rank].isNil };
        var absentFb = sel.count { |row| row[\rank].isNil and: { row[\cls] == \fallback } };
        var meanCand = if(n > 0) { (sel.collect { |row| row[\ncand] }.sum / n).round(0.1) } { 0 };
        ("  " ++ pname.padRight(18) ++ n.asString.padLeft(7)
            ++ pct.(at.(1), n).padLeft(6) ++ pct.(at.(2), n).padLeft(6)
            ++ pct.(at.(3), n).padLeft(6) ++ pct.(mid, n).padLeft(6) ++ pct.(deep, n).padLeft(6)
            ++ pct.(absent, n).padLeft(8) ++ pct.(absentFb, absent).padLeft(12)
            ++ meanCand.asString.padLeft(20)).postln;
    };
    "".postln;
    ("  wrong meters only, human bundle: where the truth was offered").postln;
    {
        var sel = metricRows.select { |row| (row[\pert] == "human") and: { row[\cls] == \meter } };
        var n = sel.size;
        ("    2nd " ++ pct.(sel.count { |row| row[\rank] == 2 }, n)
            ++ "   3rd " ++ pct.(sel.count { |row| row[\rank] == 3 }, n)
            ++ "   4th-8th " ++ pct.(sel.count { |row| row[\rank].notNil and: { row[\rank] >= 4 } and: { row[\rank] <= 8 } }, n)
            ++ "   9th+ " ++ pct.(sel.count { |row| row[\rank].notNil and: { row[\rank] >= 9 } }, n)
            ++ "   passed the fit nowhere " ++ pct.(sel.count { |row| row[\rank].isNil }, n)
            ++ "   (" ++ n ++ " wrong meters)").postln;
    }.value;
    "".postln;
    ("  bar-count errors only, human bundle (right meter, wrong bars): 2nd "
        ++ pct.(metricRows.count { |row| (row[\pert] == "human") and: { [\double, \half, \bars].includes(row[\cls]) } and: { row[\rank] == 2 } },
            metricRows.count { |row| (row[\pert] == "human") and: { [\double, \half, \bars].includes(row[\cls]) } })
        ++ "   top 3 " ++ pct.(metricRows.count { |row| (row[\pert] == "human") and: { [\double, \half, \bars].includes(row[\cls]) } and: { row[\rank].notNil } and: { row[\rank] <= 3 } },
            metricRows.count { |row| (row[\pert] == "human") and: { [\double, \half, \bars].includes(row[\cls]) } })).postln;

    section.("Per family under the human bundle: the truth within the top readings");
    ("  " ++ "family".padRight(20) ++ "trials".padLeft(7) ++ "1st%".padLeft(6)
        ++ "top2%".padLeft(7) ++ "top3%".padLeft(7) ++ "absent%".padLeft(8)).postln;
    families.do { |fam|
        var sel = metricRows.select { |row|
            (row[\pert] == "human") and: { row[\family] == fam[\name] } };
        var n = sel.size;
        var within = { |k| sel.count { |row| row[\rank].notNil and: { row[\rank] <= k } } };
        ("  " ++ fam[\name].padRight(20) ++ n.asString.padLeft(7)
            ++ pct.(within.(1), n).padLeft(6) ++ pct.(within.(2), n).padLeft(7)
            ++ pct.(within.(3), n).padLeft(7)
            ++ pct.(sel.count { |row| row[\rank].isNil }, n).padLeft(8)).postln;
    };

    section.("Margin between the answer and the runner-up: is it a confidence signal? (human bundle)");
    ("  " ++ "margin".padRight(14) ++ "trials".padLeft(7) ++ "answer right%".padLeft(14)
        ++ "runner-up right%".padLeft(18)).postln;
    [[0, 0.01], [0.01, 0.03], [0.03, 0.06], [0.06, 0.1], [0.1, 100]].do { |b|
        var sel = metricRows.select { |row|
            (row[\pert] == "human") and: { row[\margin].notNil }
                and: { row[\margin] >= b[0] } and: { row[\margin] < b[1] } };
        var n = sel.size;
        var label = if(b[1] > 1) { b[0].asString ++ " and up" } { b[0].asString ++ " - " ++ b[1] };
        ("  " ++ label.padRight(14) ++ n.asString.padLeft(7)
            ++ pct.(sel.count { |row| row[\rank] == 1 }, n).padLeft(14)
            ++ pct.(sel.count { |row| row[\rank] == 2 }, n).padLeft(18)).postln;
    };

    section.("Ghost bias: does noise push x/4 takes towards x/8 answers?");
    ("  " ++ "damage".padRight(18) ++ "truth".padLeft(6) ++ "trials".padLeft(7)
        ++ "right%".padLeft(7) ++ "fallb%".padLeft(7) ++ "wrong meters, by denominator".padLeft(32)).postln;
    ["clean", "ghosts 2", "ghosts 4", "ghosts 8", "flams 2", "human"].do { |pname|
        [4, 8].do { |denom|
            var sel = metricRows.select { |row|
                (row[\pert] == pname) and: { row[\truth][\denom] == denom } };
            var n = sel.size;
            var wrong = sel.select { |row| row[\cls] == \meter };
            var to4 = wrong.count { |row| row[\result][\denominator] == 4 };
            var to8 = wrong.count { |row| row[\result][\denominator] == 8 };
            ("  " ++ pname.padRight(18) ++ ("x/" ++ denom).padLeft(6) ++ n.asString.padLeft(7)
                ++ pct.(sel.count { |row| row[\cls] == \right }, n).padLeft(7)
                ++ pct.(sel.count { |row| row[\cls] == \fallback }, n).padLeft(7)
                ++ ("to x/4: " ++ to4 ++ "   to x/8: " ++ to8).padLeft(32)).postln;
        };
    };

    section.("Attractors: the wrong meters that keep coming back (all damage rows)");
    {
        var counts = Dictionary.new;
        metricRows.select { |row| row[\cls] == \meter }.do { |row|
            var k = (row[\truth][\num].asString ++ "/" ++ row[\truth][\denom]).padRight(6)
                ++ " heard as " ++ sigOf.(row[\result]).padRight(6)
                ++ (if((row[\result][\sub] ? 1) > 1) { " sub" ++ row[\result][\sub] } { "     " });
            counts[k] = (counts[k] ? 0) + 1;
        };
        counts.keys.asArray.sort { |a, b| counts[a] > counts[b] }.keep(16).do { |k|
            ("  " ++ k ++ counts[k].asString.padLeft(6)).postln;
        };
    }.value;

    section.("Where the fit gives up: fallback rate by tempo under the human bundle");
    ("  " ++ "bpm".padRight(8) ++ "x/4 fallb%".padLeft(12) ++ "x/8 fallb%".padLeft(12)
        ++ "x/4 right%".padLeft(12) ++ "x/8 right%".padLeft(12)).postln;
    tempos.do { |bpm|
        var line = "  " ++ bpm.asString.padRight(8);
        [4, 8].do { |denom|
            var sel = metricRows.select { |row|
                (row[\pert] == "human") and: { row[\bpm] == bpm } and: { row[\truth][\denom] == denom } };
            line = line ++ pct.(sel.count { |row| row[\cls] == \fallback }, sel.size).padLeft(12);
        };
        [4, 8].do { |denom|
            var sel = metricRows.select { |row|
                (row[\pert] == "human") and: { row[\bpm] == bpm } and: { row[\truth][\denom] == denom } };
            line = line ++ pct.(sel.count { |row| row[\cls] == \right }, sel.size).padLeft(12);
        };
        line.postln;
    };

    section.("Per family under the human bundle: what survives a real take");
    ("  " ++ "family".padRight(20) ++ "trials".padLeft(7) ++ "right%".padLeft(7)
        ++ "meter%".padLeft(7) ++ "bars%".padLeft(7) ++ "fallb%".padLeft(7)).postln;
    families.do { |fam|
        var sel = metricRows.select { |row|
            (row[\pert] == "human") and: { row[\family] == fam[\name] } };
        var n = sel.size;
        var c = { |cls| sel.count { |row| row[\cls] == cls } };
        ("  " ++ fam[\name].padRight(20) ++ n.asString.padLeft(7)
            ++ pct.(c.(\right), n).padLeft(7) ++ pct.(c.(\meter), n).padLeft(7)
            ++ pct.(c.(\bars) + c.(\double) + c.(\half), n).padLeft(7)
            ++ pct.(c.(\fallback), n).padLeft(7)).postln;
    };

    section.("Things with no right answer: what it says anyway (clean take, 2 bars or 2 pairs)");
    specials.do { |sp|
        (sp[\name]).postln;
        tempos.do { |bpm|
            var row = byKey[keyOf.(sp[\name], bpm, 2, "clean", 0)];
            var human = byKey[keyOf.(sp[\name], bpm, 2, "human", 0)];
            row !? {
                ("    " ++ bpm.asString.padLeft(4) ++ "  " ++ row[\answer].padRight(28)
                    ++ "  human: " ++ (human !? { |h| h[\answer] } ? "-")).postln;
            };
        };
    };

    section.("Cost");
    (analyses.asString ++ " analyses in " ++ analyseTime.round(0.01) ++ " s ("
        ++ (analyseTime / analyses.max(1) * 1000).round(0.1) ++ " ms each); whole run "
        ++ (Main.elapsedTime - started).round(0.01) ++ " s; seed " ++ seed
        ++ (if(quick) { "; QUICK sweep" } { "" })).postln;
};

writeCsv = {
    var f = File.open(csvPath, "w");
    f.write("family,bpm,bars,pert,rep,onsets,got_num,got_denom,got_k,got_sub,got_bpm,error,class,answer,rank,margin,alt2,alt3,readings\n");
    rows.do { |row|
        var r = row[\result];
        var alts = row[\alts] ? [];
        f.write([row[\family].quote, row[\bpm], row[\bars] ? "", row[\pert].quote, row[\rep],
            row[\onsetCount], r[\numerator] ? "", r[\denominator] ? "", r[\k] ? "",
            r[\sub] ? "", r[\bpm] !? { |b| b.round(0.01) } ? "", r[\error] ? "",
            row[\cls], row[\answer].quote, row[\rank] ? "",
            row[\margin] !? { |m| m.round(0.0001) } ? "",
            (alts[0] ? "").quote, (alts[1] ? "").quote, row[\ncand]].join(",") ++ "\n");
    };
    f.close;
    ("raw trials: " ++ csvPath).postln;
};

// ---------------------------------------------------------------- run -------
savedNum   = MeterAnalyzer.fallbackNum;
savedDenom = MeterAnalyzer.fallbackDenom;
savedBars  = MeterAnalyzer.fallbackBars;
savedCands = MeterAnalyzer.maxCandidates;
MeterAnalyzer.fallbackNum   = 7;
MeterAnalyzer.fallbackDenom = 8;
MeterAnalyzer.fallbackBars  = 0;
// The whole ranked list, so "where does the truth sit" is answered for every
// reading that passed the fit, not only the top few the app keeps.
MeterAnalyzer.maxCandidates = 144;
thisThread.randSeed = seed;

("probe-meter: " ++ families.size ++ " families x " ++ tempos.size ++ " tempos x "
    ++ barsList.size ++ " bar counts x " ++ perts.size ++ " kinds of damage, "
    ++ reps ++ " rep(s) each where random; seed " ++ seed).postln;
try {
    if(skipMetric.not) { sweepMetric.() };
    if(verbose) { "  metric sweep done".postln };
    sweepSpecials.();
    if(verbose) { "  specials done".postln };
    report.();
    writeCsv.();
} { |err|
    ("probe-meter: " ++ err.class ++ ": " ++ (err.errorString ? "?")).postln;
    err.reportError;
};

MeterAnalyzer.fallbackNum   = savedNum;
MeterAnalyzer.fallbackDenom = savedDenom;
MeterAnalyzer.fallbackBars  = savedBars;
MeterAnalyzer.maxCandidates = savedCands;

// Headless the exit is essential (see eval_meter_analyzer.scd); in the IDE it
// would kill the interpreter mid-session.
if(Platform.ideName != "scide") { 0.exit };
)
