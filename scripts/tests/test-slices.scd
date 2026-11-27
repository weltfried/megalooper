// LoopSlices: the loop cut into slices at its notes (roadmap item 24,
// docs/dev/sampler.md). Where each slice starts — the reported onsets moved to
// where the attacks really are in the loop's audio — and the table the server
// finds a slice in. Pure: synthetic plucks at known frames, no server.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-slices");

{
var sr = 48000, n = sr * 2, ms = { |x| (x * sr / 1000).round.asInteger };
// Plucks at these frames: a 1 ms rise, then a decay, over a quiet noise floor,
// the last close enough to the seam that its tail rings round into frame 0.
var attacks = [0.1, 0.42, 0.7, 0.95, 1.31, 1.62, 1.9].collect { |s| (s * sr).asInteger };
var loud = [1, 0.5, 0.8, 0.3, 1, 0.6, 0.9];
var mono, pluck, res, late, early, ghost, starts, t, sl, okAll, worst, dist, merged;
thisThread.randSeed = 24;
mono = FloatArray.fill(n, { 0.0003.rand2 });
pluck = { |buf, at, amp|
    var len = (0.4 * sr).asInteger, rise = ms.(1), x;
    len.do { |i|
        x = sin(2pi * 220 * i / sr) * amp * (i / rise).min(1) * exp(i.neg / (0.08 * sr));
        buf[(at + i).mod(n)] = buf[(at + i).mod(n)] + x;
    };
};
attacks.do { |a, i| pluck.(mono, a, loud[i]) };
// How far each start is from its attack, ms (negative: before it).
dist = { |st| st.collect { |s, i| (s - attacks[i]) / sr * 1000 } };

// ---- the attacks found ----------------------------------------------------------
// The detector late (reported 15 ms after each attack): the loop's audio sits
// before the reports.
late = ~tCheck.("reported 15 ms late: searched", { LoopSlices.attackStarts(mono, sr, attacks + ms.(15)) });
late !? {
    ~tEq.("...one slice per note", late[\starts].size, attacks.size);
    ~tNear.("...the take's distance found: about -15 ms", late[\offset] / sr * 1000, -15, 3);
    worst = dist.(late[\starts]);
    ~tAssert.("...every start at most 8 ms before its attack and never after it",
        worst.every { |d| (d <= 0) and: { d >= -8 } }, "got " ++ worst.round(0.1));
    ~tEq.("...every attack found", late[\found].every(_.value), true);
};
// A chain's latency (reported 25 ms before each attack): the loop sits after.
early = ~tCheck.("reported 25 ms early: searched", { LoopSlices.attackStarts(mono, sr, attacks - ms.(25)) });
early !? {
    ~tNear.("...the distance: about +25 ms", early[\offset] / sr * 1000, 25, 3);
    worst = dist.(early[\starts]);
    ~tAssert.("...every start at most 8 ms before its attack and never after it",
        worst.every { |d| (d <= 0) and: { d >= -8 } }, "got " ++ worst.round(0.1));
};
// A longer chain (reported 40 ms early): past the second look's reach
// without the take's distance, so this one needs it.
res = ~tCheck.("reported 40 ms early: searched", { LoopSlices.attackStarts(mono, sr, attacks - ms.(40)) });
res !? {
    worst = dist.(res[\starts]);
    ~tAssert.("...every start at most 8 ms before its attack and never after it",
        worst.every { |d| (d <= 0) and: { d >= -8 } }, "got " ++ worst.round(0.1));
};
// The same reports without the search would cut every attack in two: the
// test can fail.
~tAssert.("(cut at the reports, the starts would sit 25 ms before: the check above can fail)",
    dist.(attacks - ms.(25)).every { |d| d >= -8 }.not);
// A pluck right at frame 0, the attack's front across the seam.
res = ~tCheck.("an attack on the seam: searched", {
    var m = FloatArray.fill(n, { 0.0003.rand2 });
    pluck.(m, 0, 1); pluck.(m, ms.(900), 1);
    LoopSlices.attackStarts(m, sr, [ms.(15), ms.(915)])
});
res !? {
    ~tAssert.("...its start just before the seam, round the loop (n - 8 ms .. n - 1, or 0)",
        (res[\starts].last >= (n - ms.(8))) or: { res[\starts].first == 0 },
        "got " ++ res[\starts]);
};
// A slow attack (a 15 ms swell, its level the square of the time): what
// matters is that nothing audible of it is left in the slice before. Its
// first ms are below the floor, so the start may come a little into it, but
// no further than where it reaches -30 dB (about 2.7 ms).
res = ~tCheck.("a swelled attack: searched", {
    var m = FloatArray.fill(n, { 0.0003.rand2 }), len = (0.4 * sr).asInteger, swell = ms.(15), at = ms.(600);
    pluck.(m, ms.(200), 1);
    len.do { |i| m[at + i] = m[at + i] + (sin(2pi * 330 * i / sr) * (i / swell).min(1).squared * exp(i.neg / (0.1 * sr))) };
    LoopSlices.attackStarts(m, sr, [ms.(215), at + ms.(15)])
});
res !? {
    ~tAssert.("...it starts at most 8 ms before the swell, and before it reaches -30 dB",
        (((res[\starts][1] - ms.(600)) / ms.(15)).max(0).squared <= -30.dbamp)
            and: { (res[\starts][1] - ms.(600)) >= ms.(8).neg },
        "got " ++ ((res[\starts][1] - ms.(600)) / sr * 1000).round(0.1) ++ " ms");
};
// A low note held under the attack (82 Hz, a period of 12 ms, not dying
// away): a short window's level dips twice a period, every dip as low as the
// next, and the start must stay by the attack rather than land on one of the
// dips before it.
res = ~tCheck.("an attack over a held low note: searched", {
    var m = FloatArray.fill(n, { 0.0003.rand2 }), len = ms.(1500);
    len.do { |i| m[ms.(100) + i] = m[ms.(100) + i] + (sin(2pi * 82.4 * i / sr) * 0.3 * (i / 48).min(1)) };
    pluck.(m, ms.(700), 1);
    LoopSlices.attackStarts(m, sr, [ms.(115), ms.(715)])
});
res !? {
    ~tAssert.("...it starts at most 4 ms before its attack and never after it",
        ((res[\starts][1] - ms.(700)) <= 0) and: { (res[\starts][1] - ms.(700)) >= ms.(4).neg },
        "got " ++ ((res[\starts][1] - ms.(700)) / sr * 1000).round(0.1) ++ " ms");
};
// A ghost onset: reported where nothing starts (in the middle of a decay).
ghost = ~tCheck.("a ghost onset among the notes: searched", {
    LoopSlices.attackStarts(mono, sr, (attacks + ms.(15)).insert(3, (0.82 * sr).asInteger + ms.(15)))
});
ghost !? {
    ~tEq.("...no attack found for it", ghost[\found][3], false);
    ~tNear.("...it starts 10 ms before reported + distance",
        (ghost[\moved][3] / sr * 1000), ghost[\offset] / sr * 1000 - 10, 1.01);
    ~tEq.("...the real notes still found", ghost[\found].reject { |f, i| i == 3 }.every(_.value), true);
};
res = ~tCheck.("no onsets: searched", { LoopSlices.attackStarts(mono, sr, []) });
~tEq.("...no slices", res !? { |r| r[\starts] }, []);

// Stereo, as the loop's buffer comes: the same starts as its one-channel mean.
res = ~tCheck.("stereo, interleaved: searched", {
    var st = FloatArray.newClear(n * 2);
    n.do { |f| st[f * 2] = mono[f] * 1.5; st[(f * 2) + 1] = mono[f] * 0.5 };
    LoopSlices.attackStarts(st, sr, attacks + ms.(15), 2)
});
~tEq.("...the starts of its mean", res !? { |r| r[\starts] }, late !? { |r| r[\starts] });
// The pause: called as the search goes, once a look per onset.
res = 0;
LoopSlices.attackStarts(mono, sr, attacks + ms.(15), 1, { res = res + 1 });
~tEq.("the pause called twice an onset (each look)", res, attacks.size * 2);

// ---- merging -------------------------------------------------------------------
~tEq.("starts sorted round the loop, the same frame once", LoopSlices.merged([500, 100, 100, n + 300], n, 0), [100, 300, 500]);
~tEq.("starts nearer than the gap: the earlier kept", LoopSlices.merged([100, 120, 400, 700], n, 50), [100, 400, 700]);
~tEq.("...round the seam the last is the earlier", LoopSlices.merged([10, 900, n - 20], n, 50), [900, n - 20]);

// ---- the table -----------------------------------------------------------------
t = LoopSlices.table([300, 100, 700], 1000);
~tEq.("the table: the starts, two repeats either side", t, [-700, -300, 100, 300, 700, 1100, 1300]);
~tEq.("one start: the table still has its neighbours", LoopSlices.table([400], 1000), [-1600, -600, 400, 1400, 2400]);
~tEq.("two starts", LoopSlices.table([200, 600], 1000), [-800, -400, 200, 600, 1200, 1600]);
~tEq.("no starts: no table", LoopSlices.table([], 1000), nil);
res = LoopSlices.table((0 .. (LoopSlices.maxSlices * 2) - 1) * 10, 100000);
~tEq.("twice maxSlices: every other kept, from the first", [res.size - 4, res[2], res[3]], [LoopSlices.maxSlices, 0, 20]);
res = LoopSlices.table((0 .. LoopSlices.maxSlices * 2) * 10, 100000);
~tEq.("...one more: every third", [res.size - 4, res[2], res[3]], [171, 0, 30]);
sl = { |p| LoopSlices.sliceAt(t, p) };
~tEq.("a frame inside a slice: its start, end and the start before", sl.(450), [300, 700, 100]);
~tEq.("a slice's first frame is its own", sl.(300), [300, 700, 100]);
~tEq.("before the first start: the last slice, across the seam", sl.(50), [-300, 100, -700]);
~tEq.("after the last start: the last slice, across the seam", sl.(999), [700, 1100, 300]);
// Every frame of a loop is in exactly one slice, and the slices tile it.
okAll = (0 .. 999).every { |p| var s = sl.(p); (s[0] <= p) and: { p < s[1] } and: { (s[1] - s[0]) > 0 } };
~tEq.("every frame lies in its slice", okAll, true);
t = LoopSlices.padded(LoopSlices.table([300, 100, 700], 1000));
~tEq.("padded to the server's buffer: maxSlices + 4", t.size, LoopSlices.maxSlices + 4);
okAll = true;
t.doAdjacentPairs { |a, b| if(b < a) { okAll = false } };
~tEq.("...never falling (IndexInBetween searches it in order)", okAll, true);
~tEq.("...the padding past every frame", t.last, 1e9);

// ---- one channel --------------------------------------------------------------
~tEqArray.("stereo to one channel: the mean", LoopSlices.monoOf(FloatArray[1, 0, 0.5, 0.5, -1, 1], 2).asArray, [0.5, 0.5, 0]);
}.value;
