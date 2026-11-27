// megalooper — does the duo's timing have a groove the drums could take?
// (roadmap item 24, idea 3; docs/dev/sampler.md). A measurement, nothing
// built: for each recorded take with a reading and two bars or more, where
// its notes fall against the drums' grid, and whether the distance repeats
// from bar to bar at the same place in the bar (a groove) or scatters.
//
// The notes: each take's onsets, moved to where their attacks start in the
// loop's audio (LoopSlices.attackStarts on one pass of the loop stem), so the
// detector's lag (10-40 ms, changing with the attack) doesn't pass for
// timing. The grid: the drums', from the loop's start (the record press), the
// bar's unit (an eighth in 7/8) the loop's length over its units, halved
// (sixteenths in 7/8): a note is placed on the nearest half-unit and its
// distance from it is its timing. Positions are half-units within the bar
// (uneven bars bar by bar).
//
// Per take: the mean distance (the whole riff early or late against the
// press-anchored grid), and, with that taken out, each position's mean and
// spread, where it has two notes or more; and how much the positions explain:
// F, the spread of the positions' means against the spread within them, with
// the chance of an F that large if position meant nothing (2000 shuffles of
// the distances across the notes, seeded). A groove is a position that is
// consistently late or early by more than the notes scatter.
//
//     sclang scripts/groove-eval.scd
(
var root = thisProcess.nowExecutingPath.dirname.dirname, sessions = root +/+ "sessions";
var sr = 48000, takes = List.new, results = List.new, watchdog, stat, fmt, sd;
watchdog = Routine { 900.wait; "groove eval: timed out".postln; 1.exit }.play(AppClock);
thisThread.randSeed = 24;

// F of the distances `ds` grouped by `gs` (equal labels, one group): the
// spread of the groups' means against the spread within them.
stat = { |ds, gs|
    var groups = IdentityDictionary.new, n = ds.size, mean = ds.mean, between = 0, within = 0, p;
    ds.do { |d, i| groups[gs[i]] = (groups[gs[i]] ? List.new).add(d) };
    p = groups.size;
    groups.do { |g| var m = g.asArray.mean; between = between + (g.size * (m - mean).squared);
        g.do { |d| within = within + (d - m).squared } };
    if((p < 2) or: { (n - p) < 1 } or: { within <= 0 }) { nil } { (between / (p - 1)) / (within / (n - p)) }
};
// The standard deviation of `xs` (nil for fewer than two).
sd = { |xs| var m; if(xs.size < 2) { nil } { m = xs.mean; (xs.collect { |x| (x - m).squared }.sum / (xs.size - 1)).sqrt } };
fmt = { |x, d = 1| if(x.isNil) { "—" } { (if(x >= 0) { "+" } { "" }) ++ x.round(d).asString } };

(sessions +/+ "*-events.jsonl").pathMatch.sort.do { |path|
    var events, files, audio0;
    events = File.readAllString(path).split($\n).reject { |x| x.isEmpty or: { x.contains("\"ev\": \"hit\"") } }
        .collect { |x| try { MegaRemote.plain(MegaFiles.parseObject(x)) } { nil } }.reject(_.isNil);
    files = events.detect { |e| e[\ev] == "files" } !? { |e| e[\files] };
    audio0 = (events.detect { |e| e[\ev] == "audio" } !? { |e| e[\t] }) ? 0;
    events.select { |e| e[\ev] == "take" }.do { |t, i|
        var r = t[\result] ? (), ends, life, bars;
        ends = events.select { |e| #["clear", "stop", "sessionStop"].includesEqual(e[\ev]) and: { e[\t] > t[\t] } }
            .collect { |e| e[\t] };
        life = ((ends.minItem ? 1e9) - (t[\play] ? t[\t])) / t[\loopDur];
        bars = r[\bars] ?? { r[\k] !? { |k| r[\numerator] !? { |num| num ! k } } };
        if(r[\tau].notNil and: { (t[\onsets] ? []).size >= 8 } and: { bars.notNil } and: { bars.size >= 2 }
            and: { files.notNil } and: { files[\loop].notNil } and: { life >= 1 }) {
            takes.add((path: path, stamp: path.basename.keep(13), take: i + 1, t: t, bars: bars,
                loop: path.dirname +/+ files[\loop], audio0: audio0, pass: if(life >= 2) { 1 } { 0 }));
        };
    };
};
("" ++ takes.size ++ " takes with a reading, two bars or more and their loop").postln;

takes.do { |tk|
    var t = tk[\t], loopDur = t[\loopDur], n = (loopDur * sr).round.asInteger, sf, data, from, found, onsetFrames;
    var units = tk[\bars].sum, half = loopDur / units / 2, lines, place, hits, ds, gs, f, perms, pval, shown, m0, byPos;
    from = (((t[\play] ? t[\t]) + (tk[\pass] * loopDur) - tk[\audio0]) * sr).round.asInteger;
    sf = SoundFile.openRead(tk[\loop]);
    sf.seek(from, 0);
    data = FloatArray.newClear(n * sf.numChannels);
    sf.readData(data);
    onsetFrames = t[\onsets].select { |p| (p[0] >= 0) and: { p[0] < loopDur } }.collect { |p| (p[0] * sr).round.asInteger };
    found = LoopSlices.attackStarts(data, sr, onsetFrames, sf.numChannels);
    sf.close;
    // Bar lines in half-units, and a time's [bar, half-unit in its bar, distance s].
    lines = tk[\bars].inject([0], { |acc, b| acc.add(acc.last + (b * 2)) });
    place = { |secs|
        var g = (secs / half).round.asInteger, d = secs - (g * half), gg = g.mod(units * 2), b;
        b = (lines.indexOfGreaterThan(gg) ? lines.size) - 1;
        [b.max(0), gg - lines[b.max(0)], d]
    };
    hits = found[\starts].collect { |fr| place.(fr / sr) };
    ds = hits.collect { |h| h[2] * 1000 };
    m0 = ds.mean;
    // Positions with two notes or more, bar to bar; within a bar a position
    // is one note (a chord's two onsets would count twice otherwise).
    byPos = IdentityDictionary.new;
    hits.do { |h, i| byPos[h[1]] = (byPos[h[1]] ? List.new).add([h[0], ds[i] - m0]) };
    shown = byPos.keys.asArray.sort.select { |p| byPos[p].collect(_[0]).asSet.size >= 2 };
    gs = List.new; ds = List.new;
    shown.do { |p| byPos[p].do { |x| gs.add(p); ds.add(x[1]) } };
    f = stat.(ds.asArray, gs.asArray);
    pval = f !? { |obs|
        perms = (1 .. 2000).count { stat.(ds.asArray.scramble, gs.asArray) !? { |x| x >= obs } ? false };
        (perms + 1) / 2001
    };
    results.add((tk: tk, f: f, p: pval, n: ds.size, positions: shown.size,
        spread: if(shown.size >= 2) { sd.(shown.collect { |p| byPos[p].collect(_[1]).mean }) },
        within: if(ds.size > shown.size) { (shown.collect { |p| var xs = byPos[p].collect(_[1]), m = xs.mean;
            xs.collect { |x| (x - m).squared }.sum }.sum / (ds.size - shown.size)).sqrt }));
    ("\n" ++ tk[\stamp] ++ " take " ++ tk[\take] ++ ": " ++ t[\result][\numerator] ++ "/" ++ t[\result][\denominator]
        ++ " at " ++ t[\result][\bpm].round(0.1) ++ " BPM, bars " ++ tk[\bars].asString ++ ", " ++ found[\starts].size
        ++ " notes, a half-unit " ++ (half * 1000).round(0.1) ++ " ms").postln;
    ("  the riff against the press's grid: " ++ fmt.(m0) ++ " ms on average (" ++ (sd.(hits.collect { |h| h[2] * 1000 }) ? 0).round(0.1)
        ++ " ms spread)").postln;
    shown.do { |p|
        var xs = byPos[p].collect(_[1]);
        ("    position " ++ ((p div: 2) + 1) ++ (if(p.odd) { "+" } { " " }) ++ "  " ++ fmt.(xs.mean).padLeft(6) ++ " ms   "
            ++ xs.collect { |x| fmt.(x, 1) }.join(" ") ++ "  (" ++ xs.size ++ " bars)").postln;
    };
    ("  positions explain: F " ++ (f !? { |x| x.round(0.01) } ? "—") ++ ", chance without a groove "
        ++ (pval !? { |x| x.round(0.001) } ? "—") ++ " (" ++ ds.size ++ " notes at " ++ shown.size ++ " repeated positions)").postln;
};

"\nsummary: take, notes at repeated positions, the positions' means spread (ms), the notes' spread within a position (ms), F, chance".postln;
results.do { |r|
    ("  " ++ r[\tk][\stamp] ++ " " ++ r[\tk][\take] ++ "  " ++ r[\n].asString.padLeft(3) ++ "  "
        ++ (r[\spread] !? { |x| x.round(0.1) } ? "—").asString.padLeft(5) ++ "  "
        ++ (r[\within] !? { |x| x.round(0.1) } ? "—").asString.padLeft(5) ++ "  "
        ++ (r[\f] !? { |x| x.round(0.01) } ? "—").asString.padLeft(6) ++ "  "
        ++ (r[\p] !? { |x| x.round(0.001) } ? "—")).postln;
};
watchdog.stop;
"groove eval: done".postln;
0.exit;
)
