// The loop's key (LoopKey, LooperKey; docs/dev/synth.md 6, "Key from the
// loop"): the fit on chroma made by hand (the set, the root, the mode's
// name, the core when unsure), the bar lines and the tuning, the whole
// analysis on synthetic takes at the capture's 12 kHz (a riff, chords, a
// guitar tuned sharp), and the Looper's part with a stand-in capture,
// reader and clock: a take heard, an overdub adding to it, a take closed
// after another began (dropped), an undo, a clear.
//
// The settings themselves were chosen on 300 synthetic takes by
// scripts/key-eval.scd; this holds the code to what was measured there.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-loop-key");

// A synthetic take at 12 kHz: guitar-like notes (8 partials, a weak
// fundamental, decaying), `cents` sharp; notes are [midi, start, seconds].
~lkTake = { |notes, dur, cents = 0, sr = 12000|
    var sig = Signal.newClear((dur * sr).asInteger);
    notes.do { |nt|
        var s0 = (nt[1] * sr).asInteger, n = (nt[2] * sr).asInteger.min(sig.size - s0);
        var f = (nt[0] + (cents / 100)).midicps, sum;
        if(n > 0) {
            sum = Signal.newClear(n);
            8.do { |k|
                var fk = f * (k + 1), ak = (if(k == 0) { 0.4 } { 1 }) / (k + 1);
                if(fk < 5000) {
                    sum = sum + ((Signal.series(n, 0, 2pi * fk / sr).sin * Signal.series(n, 0, -3 / n).exp) * ak);
                };
            };
            sig.overDub(sum * 0.2, s0);
        };
    };
    sig
};
// An E minor pentatonic riff in 8ths at 120 BPM, E on every bar line (a bar
// is 2 s from 0.1).
~lkRiff = { |dur = 8|
    var notes = List.new, pat = [40, 43, 45, 47, 50, 52, 50, 47], t = 0.1, i = 0;
    while { t < (dur - 0.3) } { notes.add([pat[i % 8], t, 0.25]); t = t + 0.25; i = i + 1 };
    notes.asArray
};
~lkBars = (tau: 0.5, sub: 1, numerator: 4, denominator: 4, k: 4, bpm: 120, loopDur: 8);

// ---------------------------------------------------------------- the fit --
{
var c = LoopKey, ns = c.normSum(_), g, k, flat;
var chroma = { |pcs, w = 1| var a = Array.fill(12, 0.0); pcs.do { |pc| a[pc] = w }; a };
var evOn = { |pc| var a = Array.fill(12, 0.0); a[pc] = 1; a };

g = c.fit(ns.(chroma.([4, 7, 9, 11, 2])), evOn.(4));
~tEq.("five notes of E minor pentatonic, E home: E Minor pentatonic", [g[\pcs], g[\root], g[\name]],
    [[2, 4, 7, 9, 11], 4, "Minor pentatonic"]);
~tNear.("...all of the chroma inside", g[\inside], 1, 1e-9);
g = c.fit(ns.(chroma.([0, 2, 4, 5, 7, 9, 11])), evOn.(0));
~tEq.("all seven white notes, C home: C Major (seven notes are worth their cost)",
    [g[\pcs], g[\root], g[\name]], [[0, 2, 4, 5, 7, 9, 11], 0, "Major"]);
g = c.fit(ns.(chroma.([0, 2, 4, 5, 7, 9, 11])), evOn.(2));
~tEq.("...D home: D Dorian, the same notes", [g[\root], g[\name]], [2, "Dorian"]);
~tAssert.("...and the runner-up behind it", g[\margin] > 0, g[\margin].asString);
~tEq.("the scales' names: Dorian from D of the white notes, nothing for a set no scale has",
    [c.scaleName([0, 2, 4, 5, 7, 9, 11], 2), c.scaleIndex([0, 2, 4, 5, 7, 9, 11], 2), c.scaleName([0, 1, 2], 0)],
    ["Dorian", 2, nil]);
~tEq.("the intervals of a set above its root, from 0 up", c.intervals([2, 4, 7, 9, 11], 4), [0, 3, 5, 7, 10]);
~tEq.("each family's modes named once, at any transposition", c.famNames[0], ["Major", "Dorian", "Phrygian",
    "Lydian", "Mixolydian", "Minor", "Locrian"]);

// Unsure: no scale holds 70 % of it, so the root, its fifth and its third.
flat = Array.fill(12, 1.0).put(2, 2.0);
k = c.keyOf((all: flat, one: evOn.(2), bar: evOn.(2), low: evOn.(2), tune: [1, 0], seconds: 8));
~tEq.("a chroma no scale holds: unsure, only the root, the stronger third (the minor on a tie) and the fifth",
    [k[\core], k[\root], k[\pcs], k[\intervals], k[\name], k[\scale]], [true, 2, [2, 5, 9], [0, 3, 7], nil, nil]);
~tAssert.("...what the fit heard is kept beside it", k[\heard][\pcs].size >= 5, k[\heard].asString);
~tEq.("...in words", c.words(k), "D: D F A (unsure)");
~tEq.("nothing heard: no key", [c.keyOf(nil), c.keyOf(c.emptyEvidence)], [nil, nil]);
k = c.keyOf((all: chroma.([4, 7, 9, 11, 2]), one: evOn.(4), bar: evOn.(4), low: evOn.(4), tune: [1, 0], seconds: 8));
~tEq.("a key's fields", [k[\root], k[\pcs], k[\intervals], k[\name], k[\scale], k[\core], k[\cents], k[\chroma][4]],
    [4, [2, 4, 7, 9, 11], [0, 3, 5, 7, 10], "Minor pentatonic", 11, false, 0, 1.0]);
~tEq.("...in words", c.words(k), "E Minor pentatonic");
~tEq.("a set of its own in words: its notes from the root", c.words((root: 9, pcs: [0, 2, 4, 9], core: false)), "A: A C D E");
}.value;

// --------------------------------------------------- bar lines, the tuning --
{
var c = LoopKey;
~tEqArray.("bar lines from the first note, every bar of the reading", c.barLinesOf(
    (tau: 0.5, sub: 1, numerator: 4, k: 2), 0.2, 8), [0.2, 2.2, 4.2, 6.2], 1e-9);
~tEqArray.("...uneven bars bar by bar (7+7+7+8 eighths)", c.barLinesOf(
    (tau: 0.25, sub: 1, numerator: 7, bars: [7, 7, 7, 8]), 0, 8), [0, 1.75, 3.5, 5.25, 7.25], 1e-9);
~tEq.("...no meter: the first note alone", [c.barLinesOf(nil, 0.3, 8), c.barLinesOf((error: \noFit), 0.3, 8)],
    [[0.3], [0.3]]);
~tEq.("the notes on the bar lines: within 80 ms of one", c.barNotes([0.1, 0.35, 2.12, 2.5, 4.2], [0.1, 2.1, 4.1], 0.1),
    [0.1, 2.12]);
~tEq.("...no onsets: the first note", c.barNotes([], [0.1], 0.3), [0.3]);
~tNear.("the tuning: peaks 20 cents sharp read 0.2 of a semitone", c.tuneOf(c.tuneVector(
    [[440 * (2 ** (0.2 / 12)), 1], [880 * (2 ** (0.2 / 12)), 0.5]])), 0.2, 1e-6);
~tNear.("...30 cents flat, -0.3", c.tuneOf(c.tuneVector([[220 * (2 ** (-0.3 / 12)), 1]])), -0.3, 1e-6);
~tEq.("...nothing heard: 0", c.tuneOf([0, 0]), 0);
~tEq.("the FFT is 341 ms at any rate", [c.fftSize(12000), c.fftSize(48000), c.fftSize(44100)], [4096, 16384, 16384]);
}.value;

// ----------------------------------------------------- the whole analysis --
{
var c = LoopKey, riff = ~lkRiff.(8), ons = riff.collect(_[1]), sig, ev, k, chords, t0;
sig = ~lkTake.(riff, 8, 18);
t0 = Main.elapsedTime;
ev = c.evidenceOf(sig, 12000, ons, c.barLinesOf(~lkBars, 0.1, 8), 0.1, nil);
k = c.keyOf(ev);
~tEq.("a riff of E minor pentatonic, E on the bar lines: E Minor pentatonic", c.words(k), "E Minor pentatonic");
~tAssert.("...most of what it played is inside", k[\inside] > 0.8, k[\inside].asString);
~tAssert.("...a guitar 18 cents sharp reads within 6 of that", (k[\cents] - 18).abs <= 6, k[\cents].asString);
~tAssert.("...and 8 s are heard in well under a second", (Main.elapsedTime - t0) < 1, (Main.elapsedTime - t0).asString);
~tEq.("...the evidence: 8 s, a first note and bar lines heard", [ev[\seconds], ev[\one].sum > 0, ev[\bar].sum > 0],
    [8.0, true, true]);
// Strummed chords, two seconds each: Am Dm Em Am, the A in the bass first.
chords = [[45, 52, 57, 60, 64], [50, 57, 62, 65, 69], [40, 47, 52, 55, 59], [45, 52, 57, 60, 64]];
sig = ~lkTake.(chords.collect { |ch, i| ch.collect { |m, j| [m, (i * 2) + 0.1 + (j * 0.012), 1.9] } }.flatten(1), 8);
k = c.keyOf(c.evidenceOf(sig, 12000, [0.1, 2.1, 4.1, 6.1], c.barLinesOf(~lkBars, 0.1, 8), 0.1, nil));
// The notes are what keep the synth out of a clash, and they are right; the
// root is not: E Phrygian, the same notes from E. The low E string puts its
// fundamental and its octave under 200 Hz where A2 has its fundamental
// alone, and the low cue hears E. The root is the weak half (65 % on the
// corpus, 27 % where it is not on the bar lines): held here as it is.
~tEq.("chords Am Dm Em Am: the notes of A minor (heard from E: the low string's partials)", [k[\pcs], k[\root]],
    [[0, 2, 4, 5, 7, 9, 11], 4]);
~tEq.("a second of silence: nothing heard", c.evidenceOf(Signal.newClear(12000), 12000, [], [0], 0, nil), nil);
}.value;

// ------------------------------------------------- the Looper's part (flow) --
// A Looper made without a server; the part's capture, reader, clock and
// runner stood in for: the capture is an Event, the reader hands the
// signal its buffer holds, the clock is set by hand, the hearing runs at
// once and never waits.
{
var l = ~tLooper.(), k = l.keyPart, now = 100.0, said = List.new, synths = List.new, held = IdentityDictionary.new;
var takeBuf = (bufnum: 900, numFrames: 30 * 12000), dubBuf = (bufnum: 901, numFrames: 30 * 12000);
var riff = ~lkRiff.(8), ons = riff.collect(_[1]), ctl, snap, words = { LoopKey.words(l.loopKey) };
k.instVarPut(\takeBuf, takeBuf);
k.instVarPut(\dubBuf, dubBuf);
k.starter = { |kind, buf| var s = (kind: kind, buf: buf, freed: false); synths.add(s); s };
k.stopper = { |s| s[\freed] = true };
k.clock = { now };
k.reader = { |buf, frames, action| action.value(held[buf[\bufnum]].copyRange(0, frames - 1)) };
k.runner = { |fn| fn.value };
k.slice = inf;
ctl = SimpleController(l).put(\loopKey, { |obj, what, key| said.add(key) });

held.put(900, ~lkTake.(riff, 8, 18));
k.takeStarted(0);
~tEq.("a take: its capture starts, on the take's buffer", synths.collect { |s| [s[\kind], s[\buf][\bufnum]] }, [[\take, 900]]);
now = 108.0;
l.instVarPut(\state, \recording);
l.prFreeRecorder;
~tEq.("...and stops with the recorder", synths[0][\freed], true);
k.analyseTake(8, ons, 0.1, ~lkBars);
~tEq.("...heard once the reading is in: the Looper's loopKey, said once", [words.(), said.size], ["E Minor pentatonic", 1]);
~tAssert.("...the guitar's tuning with it", (l.loopKey[\cents] - 18).abs <= 6, l.loopKey[\cents].asString);

// An overdub of F# and C#, the notes Dorian adds: the key from both.
snap = k.takeState;
held.put(901, ~lkTake.([[42, 0.1, 1.5], [49, 1.6, 1.5], [54, 3.1, 1.5], [61, 4.6, 1.5], [42, 6.1, 1.5]], 8));
now = 110.0;
k.overdubStarted;
~tEq.("an overdub: its capture on the overdub's buffer", [synths.last[\kind], synths.last[\buf][\bufnum]], [\overdub, 901]);
now = 118.0;
k.overdubEnded;
~tEq.("...ended: heard, and its notes added to the take's: E Dorian", [synths.last[\freed], words.()], [true, "E Dorian"]);
~tEq.("...the root still the take's", l.loopKey[\root], 4);
k.restoreTake(snap);
~tEq.("an undo brings back the key its snapshot had, and says it", [words.(), said.last !? { |x| LoopKey.words(x) }],
    ["E Minor pentatonic", "E Minor pentatonic"]);

// An overdub ended any other way (a Stop) is dropped unheard.
said.clear;
now = 120.0;
k.overdubStarted;
now = 125.0;
k.stateChanged(\stopped);
~tEq.("an overdub stopped: its capture freed, nothing heard", [synths.last[\freed], said.size, words.()],
    [true, 0, "E Minor pentatonic"]);
k.overdubEnded;
~tEq.("...an end after that does nothing", said.size, 0);

// A take closed after another began: its analysis is dropped.
held.put(900, ~lkTake.([[45, 0.1, 7.5], [52, 0.1, 7.5], [57, 0.1, 7.5]], 8));
k.takeStarted(0);
now = 133.0;
k.takeStopped;
k.takeStarted(0);
k.analyseTake(8, [0.1], 0.1, ~lkBars);
~tEq.("a take's analysis after a new take began: dropped", [said.size, words.()], [0, "E Minor pentatonic"]);
now = 141.0;
k.takeStopped;
k.analyseTake(8, [0.1], 0.1, ~lkBars);
~tEq.("...the new take's is heard (an A chord: A, its third and fifth, or more)", [said.size, l.loopKey[\root]], [1, 9]);
held.put(900, Signal.newClear(8 * 12000));
k.takeStarted(0);
now = 149.0;
k.takeStopped;
k.analyseTake(8, [], nil, nil);
~tEq.("a silent take: no key, said", [said.size, said.last, l.loopKey], [2, nil, nil]);
k.takeStarted(0);
now = 149.3;
k.takeStopped;
k.analyseTake(0.3, [], nil, nil);
~tEq.("a take under half a second: not heard, nothing said", said.size, 2);

held.put(900, ~lkTake.(riff, 8));
k.takeStarted(0);
now = 158.0;
k.takeStopped;
k.analyseTake(8, ons, 0.1, ~lkBars);
~tEq.("the Looper's undo snapshot carries the key and the take's evidence",
    [k.takeState[\key] == l.loopKey, k.takeState[\keyTake].notNil, k.takeState[\keyDubs]], [true, true, nil]);
~tEq.("a Clear forgets the key and says so", [said.size, { k.clear; l.loopKey }.value, said.last, said.size], [3, nil, nil, 4]);
snap = LooperKey.logFields((root: 4, pcs: [2, 4, 7, 9, 11], name: "Minor pentatonic",
    core: false, heard: (pcs: [2, 4, 7, 9, 11], name: "Minor pentatonic"), inside: 0.85891, margin: 0.022219,
    cents: 14, chroma: [1]), \take);
~tEq.("the log's fields for a key", snap.atAll(#[\from, \root, \pcs, \name, \heard, \cents]),
    [\take, 4, [2, 4, 7, 9, 11], "Minor pentatonic", [2, 4, 7, 9, 11], 14]);
~tEqArray.("...inside and the margin rounded", [snap[\inside], snap[\margin]], [0.859, 0.0222], 1e-9);
~tEq.("...no key", LooperKey.logFields(nil, \clear), (from: \clear, key: nil));
ctl.remove;
}.value;

// A Looper made without init has a part with no buffers: its takes and
// overdubs capture nothing and say nothing (every stub Looper in the tests).
{
var l = ~tLooper.(), said = List.new, ctl = SimpleController(l).put(\loopKey, { said.add(1) });
l.keyPart.takeStarted(0);
l.keyPart.takeStopped;
l.keyPart.analyseTake(8, [0.1], 0.1, ~lkBars);
l.keyPart.overdubStarted;
l.keyPart.overdubEnded;
~tEq.("no buffers: nothing captured, nothing heard, nothing said", [l.loopKey, said.size], [nil, 0]);
ctl.remove;
}.value;

// The AI's set_synth (MegaRemote.takeOverKey): a root or scale it gives
// takes over from the loop's key as one chosen by hand does.
{
var key = (root: 4, scale: 11), drums = (loopKey: key, notes: (fromLoop: true));
var take = { |g| MegaRemote.takeOverKey(g, drums) };
~tEq.("the AI gives a scale while the loop's key is followed: from its root, fromLoop off",
    take.((scale: 2)), (scale: 2, root: 4, fromLoop: false));
~tEq.("...a root: in the key's scale", take.((root: 7)), (root: 7, scale: 11, fromLoop: false));
~tEq.("...both: as given", take.((root: 2, scale: 1)), (root: 2, scale: 1, fromLoop: false));
~tEq.("...fromLoop given says itself", take.((root: 2, fromLoop: true)), (root: 2, fromLoop: true));
~tEq.("...neither: nothing taken over", take.((swing: 0.2)), (swing: 0.2));
drums[\notes][\fromLoop] = false;
~tEq.("...not following: as given", take.((root: 2)), (root: 2));
~tEq.("the AI's context says the key in words and numbers", MegaRemote.loopKeyOf((root: 4, pcs: [2, 4, 7, 9, 11],
    name: "Minor pentatonic", scale: 11, inside: 0.857, core: false, cents: 18))[\words], "E Minor pentatonic");
}.value;

// ------------------------------------------------------------ sections --
// A loop whose key changes: its bars (gridOf, barIndexOf), the cheapest cut
// into runs (cut), the sections it makes (sectionsOf), on evidence made by
// hand and on synthetic riffs, and through the Looper's part.
{
var c = LoopKey, g, costs, ev, secs, bar, zero = { Array.fill(12, 0.0) }, chroma;
chroma = { |pcs| var a = zero.(); pcs.do { |pc| a[pc] = 1 }; a };
g = c.gridOf((tau: 0.5, sub: 1, numerator: 4, k: 4, loopDur: 8), 0.1, 8);
~tEq.("a reading's bars: from the loop's start, every bar", [g[\first], g[\period], g[\starts]], [0.1, 8, [0, 2.0, 4.0, 6.0]]);
~tEqArray.("...uneven bars bar by bar", c.gridOf((tau: 0.25, sub: 1, numerator: 7, bars: [7, 7, 7, 8]), 0, 7.25)[\starts],
    [0, 1.75, 3.5, 5.25], 1e-9);
~tEqArray.("...a loop of two readings' length (multiplied): its bars twice",
    c.gridOf((tau: 0.5, sub: 1, numerator: 4, k: 2, loopDur: 4), 0, 8)[\starts], [0, 2, 4, 6], 1e-9);
~tEq.("...no meter: no bars", [c.gridOf(nil, 0, 8), c.gridOf((error: \noFit), 0, 8)], [nil, nil]);
~tEq.("the bar a moment is in: counted from the first note, what comes before it the last bar's, round the loop",
    [0.05, 0.1, 2.2, 7.9, 8.15].collect { |p| c.barIndexOf(g, p) }, [3, 0, 1, 3, 0]);

costs = [[0, 0.3, 0.7], [0, 0, 0.3]];
~tEq.("the cut: two runs where they fit better by more than tau", c.cut(costs, 0.05), [[0, 1], [1, 2]]);
~tEq.("...one where they do not", c.cut(costs, 0.2), [[0, 2]]);

// By hand: two bars of E minor pentatonic, two of A minor pentatonic.
bar = { |pcs, root| (all: chroma.(pcs), one: zero.(), bar: chroma.([root]), low: chroma.([root])) };
ev = c.sumOf([bar.([4, 7, 9, 11, 2], 4), bar.([4, 7, 9, 11, 2], 4), bar.([9, 0, 2, 4, 7], 9), bar.([9, 0, 2, 4, 7], 9)])
    .put(\tune, [1, 0]).put(\bars, [bar.([4, 7, 9, 11, 2], 4), bar.([4, 7, 9, 11, 2], 4), bar.([9, 0, 2, 4, 7], 9),
        bar.([9, 0, 2, 4, 7], 9)]);
secs = c.sectionsOf(ev);
~tEq.("E minor pentatonic for two bars, A minor pentatonic for two: two sections",
    secs !? { |ss| ss.collect { |sc| [sc[\from], sc[\to], c.words(sc[\key])] } },
    [[0, 2, "E Minor pentatonic"], [2, 4, "A Minor pentatonic"]]);
~tEq.("...where the whole loop's one key is one section's pentatonic: the other's bars hear a note outside theirs",
    [c.keyOf(ev)[\pcs].size, [[2, 4, 7, 9, 11], [0, 2, 4, 7, 9]].includesEqual(c.keyOf(ev)[\pcs])], [5, true]);
ev[\bars] = [bar.([4, 7, 9, 11, 2], 4), bar.([4, 7, 9, 11, 2], 4), bar.([4, 6, 7, 9, 11, 0, 2], 4), bar.([4, 6, 7, 9, 11, 0, 2], 4)];
ev.putAll(c.sumOf(ev[\bars]));
~tEq.("two bars of the pentatonic, two of all of E minor: a cut costing nothing (tau 0) is one section, for "
    "the pentatonic is in the scale", c.sectionsOf(ev, 0), nil);
~tEq.("...kept apart only with no merging (\\none)", c.sectionsOf(ev, 0, nil, nil, \none) !? { |ss| ss.size }, 2);
ev[\bars] = ev[\bars].collect { |b| bar.([4, 7, 9, 11, 2], 4) };
ev.putAll(c.sumOf(ev[\bars]));
~tEq.("four bars of one scale: no sections", c.sectionsOf(ev), nil);
~tEq.("no bars (no meter): no sections", c.sectionsOf(ev.copy.put(\bars, nil)), nil);
~tEq.("sections in words", LooperKey.sectionWords([(from: 0, to: 2, key: (root: 4, pcs: [2, 4, 7, 9, 11],
    name: "Minor pentatonic")), (from: 2, to: 3, key: (root: 9, pcs: [0, 2, 4, 7, 9], name: "Minor pentatonic"))]),
    "bars 1–2 E Minor pentatonic, 3 A Minor pentatonic");
}.value;

// Synthetic riffs: E minor pentatonic, then the same riff a whole step up
// (F# minor pentatonic: two notes change). Moved a fourth up instead (A
// minor pentatonic) only B becomes C, a note this riff plays once a bar, and
// it stays one key: a change of one quiet note is not worth a section.
~lkMoving = { |dur = 8, by = 2|
    var notes = List.new, pat = [40, 43, 45, 47, 50, 52, 50, 47], t = 0.1, i = 0;
    while { t < (dur - 0.3) } { notes.add([pat[i % 8] + (if(t >= 4.1) { by } { 0 }), t, 0.25]); t = t + 0.25; i = i + 1 };
    notes.asArray
};
{
var c = LoopKey, riff = ~lkMoving.(8), ons = riff.collect(_[1]), g = c.gridOf(~lkBars, 0.1, 8), ev, secs;
ev = c.evidenceOf(~lkTake.(riff, 8), 12000, ons, c.barLinesOf(~lkBars, 0.1, 8), 0.1, nil, g);
secs = c.sectionsOf(ev);
~tEq.("a riff of E minor pentatonic moved up to F# after two bars: heard as two sections",
    secs !? { |ss| ss.collect { |sc| [sc[\from], sc[\to], sc[\key][\root]] } }, [[0, 2, 4], [2, 4, 6]]);
~tEq.("...each bar's evidence adds up to the loop's", [ev[\bars].size,
    (ev[\bars].collect { |b| b[\all].sum }.sum - ev[\all].sum).abs < (1e-9 * ev[\all].sum)], [4, true]);
ev = c.evidenceOf(~lkTake.(~lkRiff.(8), 8), 12000, ~lkRiff.(8).collect(_[1]), c.barLinesOf(~lkBars, 0.1, 8), 0.1, nil, g);
~tEq.("the riff that stays in E: one key, no sections", c.sectionsOf(ev), nil);
}.value;

// Through the Looper's part: the key carries its sections, each with where
// its first bar line is in the loop.
{
var l = ~tLooper.(), k = l.keyPart, now = 100.0, held = IdentityDictionary.new, riff = ~lkMoving.(8), key, snap;
k.instVarPut(\takeBuf, (bufnum: 900, numFrames: 30 * 12000));
k.instVarPut(\dubBuf, (bufnum: 901, numFrames: 30 * 12000));
k.starter = { |kind, buf| (kind: kind, buf: buf) };
k.stopper = { |s| };
k.clock = { now };
k.reader = { |buf, frames, action| action.value(held[buf[\bufnum]].copyRange(0, frames - 1)) };
k.runner = { |fn| fn.value };
k.slice = inf;
held.put(900, ~lkTake.(riff, 8, 18));
k.takeStarted(0);
now = 108.0;
k.takeStopped;
k.analyseTake(8, riff.collect(_[1]), 0.1, ~lkBars);
key = l.loopKey;
~tEq.("a moving take: its key has sections, each at its first bar line in the loop, round the take's loop",
    [key[\sections] !? { |ss| ss.collect { |sc| [sc[\from], sc[\at], sc[\key][\root]] } }, key[\period]],
    [[[0, 0, 4], [2, 4.0, 6]], 8]);
~tEq.("...and the sections keep the loop's tuning in its key", (key[\cents] - 18).abs <= 6, true);
~tEq.("...in the log", LooperKey.logFields(key, \take)[\sections].collect(_.keep(3)), [[0, 2, 4], [2, 4, 6]]);
snap = k.takeState;
~tEq.("...the undo snapshot keeps its bars", snap[\keyGrid] !? { |g| g[\starts] }, [0, 2.0, 4.0, 6.0]);
k.clear;
k.restoreTake(snap);
~tEq.("...and brings them back", [l.loopKey[\sections].size, k.takeState[\keyGrid].notNil], [2, true]);
}.value;
