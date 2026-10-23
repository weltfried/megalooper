// The note sequencer (MegaSANoteSeq, docs/dev/synth.md): its rules, worked
// by hand (the lanes' directions, conditions, the scale, a step's note,
// ratchets, swing, the settings' ranges and the edit tools), and its part of
// the drums' pump (MegaSADrums' Notes part) on the harness's recording stub
// server with an injected wall clock and sender: notes on the grid, the
// switch, restarts, rate edits, a stop, a reading landing, and the dice.
//
// Every check on what was sent first asserts that something was.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-megasa-noteseq");

// ---------------------------------------------------------------- rules --
{
var c = MegaSANoteSeq;
var walk = { |dir, len, n, u|
    var prev, out = List.new;
    n.do { |k| prev = c.position(dir, k, len, prev, u.value(k)); out.add(prev) };
    out.asArray
};
var pat, st, notes, out, vs, plays;

~tEq.("Forward: round and round", walk.(\forward, 4, 8, 0), [0, 1, 2, 3, 0, 1, 2, 3]);
~tEq.("Backward: from the last step down", walk.(\backward, 4, 8, 0), [3, 2, 1, 0, 3, 2, 1, 0]);
~tEq.("Alternate: there and back, the ends once each", walk.(\alternate, 4, 9, 0), [0, 1, 2, 3, 2, 1, 0, 1, 2]);
~tEq.("...a lane of one step stays", walk.(\alternate, 1, 3, 0), [0, 0, 0]);
~tEq.("Snake going up turns back at the end", walk.(\snake, 4, 8, 0.9), [0, 1, 2, 3, 2, 3, 2, 3]);
~tEq.("...going down turns back at the start", walk.(\snake, 4, 4, 0.1), [0, 1, 0, 1]);
vs = walk.(\snake, 8, 200, { 1.0.rand });
~tAssert.("...a step of one each time, never outside the lane",
    vs.differentiate.drop(1).every { |d| d.abs == 1 } and: { vs.every { |p| (p >= 0) and: { p < 8 } } }, vs.keep(20).asString);
~tEq.("Random: the draw picks the step", [0, 0.24, 0.25, 0.99].collect { |u| c.position(\random, 5, 4, nil, u) }, [0, 0, 1, 3]);

plays = { |cond| (0..5).collect { |p| c.conditionPlays(cond, p) } };
~tEq.("condition 0 and 1 always play", [plays.(0), plays.(1)], [true ! 6, true ! 6]);
~tEq.("condition 2: every second pass, the first included", plays.(2), [true, false, true, false, true, false]);
~tEq.("condition 3: once in three", plays.(3), [true, false, false, true, false, false]);
~tEq.("condition -1 never plays", plays.(-1), false ! 6);
~tEq.("condition -2: all but every second", plays.(-2), [false, true, false, true, false, true]);
~tEq.("condition -3: all but once in three", plays.(-3), [false, true, true, false, true, true]);

vs = c.scales[1][1];
~tEq.("a note outside the scale snaps down to the scale (C minor)", [61, 64, 66, 71, 72].collect { |n| c.snap(n, 0, vs) }, [60, 63, 65, 70, 72]);
~tEq.("...in D minor C# is C", c.snap(61, 2, vs), 60);
~tEq.("...below the root too", c.snap(-1, 0, vs), -2);
~tEq.("35 scales, each from 0 upwards",
    [c.scales.size, c.scales.every { |s| (s[1][0] == 0) and: { s[1] == s[1].copy.sort } and: { s[1].last < 12 } }], [35, true]);

// A step's note.
pat = c.defaultPattern;
~tAssert.("every value of the fresh pattern is in its lane's range (an edit would clip it otherwise)",
    c.laneNames.every { |k| var sp = c.laneSpecs[k]; pat[\lanes][k][\values].every { |v| (v >= sp[0]) and: { v <= sp[1] } } });
notes = (0..15).collect { |k| out = c.decide(pat, k, st, { 0 }); st = out[\state]; out[\note][\note] };
~tEq.("the fresh pattern: a minor line from the root, its pitches in the scale",
    notes, [60, 67, 72, 67, 63, 67, 70, 67, 60, 67, 72, 70, 68, 67, 63, 62]);
~tEq.("...each at velocity 100, 74 % of the step, on time, once",
    c.decide(pat, 0, nil, { 0 })[\note].atAll(#[\vel, \length, \shift, \ratchet]), [100, 0.74, 0, 0]);
pat[\root] = 2;
~tEq.("pitch 0 is the root: D for a root of D", c.decide(pat, 0, nil, { 0 })[\note][\note], 62);
pat[\scaleOn] = false;
pat[\lanes][\pitch][\values][1] = 1;
~tEq.("...without the scale a pitch is the semitones above it", c.decide(pat, 1, nil, { 0 })[\note][\note], 63);
pat[\lanes][\octave][\values][1] = -1;
pat[\octave] = 2;
~tEq.("the octave lane and the pattern's octave add", c.decide(pat, 1, nil, { 0 })[\note][\note], 63 + 12);
pat = c.defaultPattern;
pat[\steps][3] = false;
pat[\lanes][\velocity][\values][4] = 0;
~tEq.("a step off, or at velocity 0, plays nothing", [3, 4].collect { |k| c.decide(pat, k, nil, { 0 })[\note] }, [nil, nil]);
pat[\lanes][\length][\values][5] = 0;
~tEq.("...a length of 0 still plays, at 1 % of the step", c.decide(pat, 5, nil, { 0 })[\note][\length], 0.01);

// The condition counts the passes of its lane.
pat = c.defaultPattern;
pat[\lanes][\condition][\values][0] = 2;
st = nil;
plays = List.new;
48.do { |k| out = c.decide(pat, k, st, { 0 }); st = out[\state]; if((k % 16) == 0) { plays.add(out[\note].notNil) } };
~tEq.("condition 2 on step 1: its first pass, not its second, its third", plays.asArray, [true, false, true]);
pat[\lanes][\condition].putAll((own: true, first: 1, last: 4));
st = nil;
plays = List.new;
16.do { |k| out = c.decide(pat, k, st, { 0 }); st = out[\state]; if(out[\lanes][\condition] == 0) { plays.add(out[\note].notNil) } };
~tEq.("...a condition lane of its own goes round on its own length", plays.asArray, [true, false, true, false]);
st = nil;
plays = [0, 1, 2, 0, 1].collect { |k| out = c.decide(pat, k, st, { 0 }); st = out[\state]; out[\state][\pass] };
~tEq.("...a restart (the count from 0 again) is a new pass", plays, [0, 0, 0, 1, 1]);

// A lane of its own.
pat = c.defaultPattern;
pat[\lanes][\pitch].putAll((own: true, first: 2, last: 4));
st = nil;
vs = (0..7).collect { |k| out = c.decide(pat, k, st, { 0 }); st = out[\state]; [out[\main], out[\lanes][\pitch], out[\lanes][\velocity]] };
~tEq.("a lane of its own (steps 2-4) plays its own round; the others follow the sequence",
    vs, [[0, 1, 0], [1, 2, 1], [2, 3, 2], [3, 1, 3], [4, 2, 4], [5, 3, 5], [6, 1, 6], [7, 2, 7]]);
pat[\lanes][\pitch][\direction] = \backward;
~tEq.("...with its own direction", (0..3).collect { |k| c.decide(pat, k, nil, { 0 })[\lanes][\pitch] }, [3, 2, 1, 3]);
pat = c.defaultPattern.putAll((first: 5, last: 8, direction: \alternate));
~tEq.("the sequence's own range and direction", (0..6).collect { |k| c.decide(pat, k, nil, { 0 })[\main] }, [4, 5, 6, 7, 6, 5, 4]);

// Time.
~tEq.("ratchet r: r + 1 hits through the step", [c.ratchetTimes(0), c.ratchetTimes(3)], [[0], [0, 0.25, 0.5, 0.75]]);
pat = c.defaultPattern;
~tEq.("a step of 1/16 is 120 ticks, 1/4 480", [c.stepTicks(pat), c.stepTicks(pat.copy.put(\division, 2))], [120, 480]);
~tEq.("...triplet two thirds, dotted half as long again",
    [c.stepTicks(pat.copy.put(\triplet, true)), c.stepTicks(pat.copy.put(\dotted, true))], [80, 180]);
pat[\swing] = 1.0;
~tEq.("swing: the odd steps late, by up to 0.498 of a step", [0, 1, 2, 3].collect { |g| c.swingTicks(pat, g, 120) }, [0, 0.498 * 120, 0, 0.498 * 120]);

// Settings.
pat = c.defaultPattern;
~tEq.("a setting is stored in its range", [c.putSetting(pat, \swing, 2), c.putSetting(pat, \root, 14), c.putSetting(pat, \division, 4.4)], [1.0, 11, 4]);
~tEq.("...one it does not take is refused", [c.putSetting(pat, \direction, \sideways), c.putSetting(pat, \nope, 1), pat[\direction]], [nil, nil, \forward]);
c.putSetting(pat, \stepCount, 8);
~tEq.("8 steps: the sequence and its lanes end at 8 at the latest", [pat[\last], pat[\lanes][\pitch][\last]], [8, 8]);
c.putSetting(pat, \first, 12);
~tEq.("...a first step past the last is the last", pat[\first], 8);
~tEq.("a lane value is clipped to its lane's range", [c.putValue(pat, \pitch, 0, 30), c.putValue(pat, \ratchet, 0, -1), c.putValue(pat, \pitch, 16, 0)], [12, 0, nil]);

// The edit tools work on the steps a lane plays.
pat = c.defaultPattern;
pat[\first] = 1;
pat[\last] = 4;
vs = pat[\lanes][\pitch][\values];
~tEq.("rotate: the span one step later, the last to the first", c.rotatedValues(pat, \pitch, 1), [vs[3], vs[0], vs[1], vs[2]] ++ vs.copyToEnd(4));
~tEq.("nudge: up within the range", c.nudgedValues(pat, \pitch, 3).keep(4), [3, 10, 12, 10]);
~tEq.("scramble keeps the values", c.scrambledValues(pat, \pitch).keep(4).sort, vs.keep(4).sort);
pat[\last] = 16;
vs = 50.collect { c.randomValues(pat, \velocity) }.flat;
~tAssert.("random velocities stay under the top, within the range (60)", vs.every { |v| (v >= 67) and: { v <= 127 } }, vs.minItem.asString);
vs = 50.collect { c.randomValues(pat, \pitch) }.flat;
~tAssert.("random pitches go either side of 0", (vs.minItem < 0) and: { vs.maxItem > 0 } and: { vs.every { |v| v.abs <= 12 } });
~tEq.("set all, and reset", [c.allValues(pat, \octave, 9).asSet.asArray, c.resetValues(pat, \length).asSet.asArray], [[3], [74]]);
~tAssert.("copyPattern copies the lanes", { var q = c.copyPattern(pat); q[\lanes][\pitch][\values][0] = 99; pat[\lanes][\pitch][\values][0] != 99 }.value);
}.value;

// ------------------------------------------------------------ in the pump --
// A drums object on the stub, attached to a stub Looper playing a 2 s loop of
// 4/4 at 120 BPM from lam (a 16th is 0.125 s), every bundle logged as [time
// (nil: at once), msgs, wall]. No kits: nothing but the sequencer sounds.
~nsMake = { |lam = 90.0, loopDur = 2.0, seed = 1234|
    var fx = (log: List.new, wall: lam);
    var stub = ~tStubServer.();
    var l = ~tLooper.();
    var d;
    ~tPut.(l, \state, \playing);
    ~tPut.(l, \loopFrames, (loopDur * 48000).round.asInteger);
    ~tPut.(l, \loopStartTime, lam);
    ~tPut.(l, \lastResult, (numerator: 4, denominator: 4, k: 1, bpm: 120, loopDur: loopDur));
    ~tPut.(l, \phaseBus, Bus(\control, 7, 1, stub));
    d = MegaSADrums((server: stub));
    d.prUseBusses;
    d.wallClock = { fx[\wall] };
    d.sender = { |t, msgs| fx[\log].add([t, msgs, fx[\wall]]) };
    d.randSeed = seed;
    d.attach(l);
    fx.putAll((stub: stub, looper: l, drums: d))
};
~nsStart = { |fx, b|
    fx[\wall] = b - 0.1;
    fx[\drums].transportStart(b - 0.1);
};
~nsRun = { |fx, to, step = 0.01|
    var w = fx[\wall];
    while { w < (to - 1e-9) } {
        w = (w + step).min(to);
        fx[\wall] = w;
        fx[\drums].pump(w);
    };
};
// Every test-tone note sent, in order: (time:, grid:, note:, dur:, ring:,
// choke:, group:, out:, hitId:, cancelled:, wall:). A /c_set of its cancel
// bus to 1 after it cancels it.
~nsNotes = { |log|
    var out = List.new, owner = IdentityDictionary.new;
    log.do { |b|
        b[1].do { |m|
            var a, n;
            if(m[0] == \c_set) {
                m.copyToEnd(1).pairsDo { |bus, v| if(v == 1) { owner[bus] !? { |o| o[\cancelled] = true } } };
            };
            if((m[0] == \s_new) and: { m[1] == \megaSANoteTone }) {
                a = ().putPairs(m.copyToEnd(5));
                n = (time: b[0], grid: b[0] - 0.02, note: a[\freq].cpsmidi.round.asInteger, dur: a[\dur],
                    amp: a[\amp], ring: a[\cancelBus], choke: a[\chokeBus], group: m[4], out: a[\out],
                    hitId: a[\hitId], cancelled: false, wall: b[2]);
                out.add(n);
                owner.put(a[\cancelBus], n);
            };
        };
    };
    out
};
~nsSounding = { |log| ~nsNotes.(log).reject { |n| n[\cancelled] } };
// Step indices of grid times from t0 at `step` seconds a step.
~nsSteps = { |notes, t0, step = 0.125| notes.collect { |n| ((n[\grid] - t0) / step).round(1e-6) } };

{
var fx = ~nsMake.(), d = fx[\drums], ns, t;
~nsStart.(fx, 92.0);
~nsRun.(fx, 93.0);
~tEq.("the sequencer starts switched off: the transport plays, no note sounds", [d.playing, ~nsNotes.(fx[\log]).size], [true, 0]);
d.setNotesOn(true, 93.0);
~nsRun.(fx, 95.0);
ns = ~nsSounding.(fx[\log]);
~tAssert.("switched on, notes were sent", ns.size > 0);
~tEqArray.("...one a 16th, from the first step heard after the switch", ns.collect(_[\grid]).keep(4),
    [93.0, 93.125, 93.25, 93.375], 1e-9);
~tEq.("...the fresh pattern's line where the bar is: half a bar in, from its 9th step", ns.keep(16).collect(_[\note]),
    [60, 67, 72, 70, 68, 67, 63, 62, 60, 67, 72, 67, 63, 67, 70, 67]);
~tNear.("...each held 74 % of its 16th", ns[0][\dur], 0.74 * 0.125, 1e-9);
~tEq.("...into the synth's group and bus, on the sequencer's own cancel ring and choke bus",
    [ns[0][\group], ns[0][\out], ns.every { |n| (n[\ring] >= 3114) and: { n[\ring] < 4138 } }, ns[0][\choke]], [1004, 24, true, 4138]);
~tEq.("...one hit id each", ns.collect(_[\hitId]).asSet.size, ns.size);
~tEq.("...and the playhead says where it is", d.notePlayheadAt(94.0 + 1e-6) !? { |h| [h[\n], h[\main], h[\lanes][\pitch]] },
    [16, 0, 0]);
t = fx[\log].size;
d.setNotesOn(false, 95.02);
~nsRun.(fx, 96.0);
ns = ~nsNotes.(fx[\log]);
~tEq.("switched off: the notes from the moment heard are cancelled, those before stay",
    [ns.select { |n| n[\grid] >= 95.0 }.every(_[\cancelled]), ns.select { |n| n[\grid] < 95.0 }.any(_[\cancelled])], [true, false]);
~tEq.("...and no more are sent", ~nsNotes.(fx[\log].copyToEnd(t)).size, 0);
d.setNotesOn(true, 96.0);
~nsRun.(fx, 96.2);
fx[\drums].transportStop(96.27);
~nsRun.(fx, 97.0);
ns = ~nsSounding.(fx[\log]).select { |n| n[\grid] >= 96.0 };
~tEq.("a Stop: the notes before the moment heard play, none from it", ns.collect(_[\grid]).round(1e-6), [96.0, 96.125]);
d.free;
}.value;

// Restarts, ratchets, the shift, swing, a rate edit.
{
var run = { |setup, to = 96.0|
    var fx = ~nsMake.(), d = fx[\drums];
    setup.(d);
    d.setNotesOn(true, 91.0);
    ~nsStart.(fx, 92.0);
    ~nsRun.(fx, to);
    d.free;
    ~nsSounding.(fx[\log])
};
var ns, pitches;
pitches = (0..15).collect { |i| i };
ns = run.({ |d| d.setNoteSetting(\scaleOn, false); d.setNoteValues(\pitch, pitches); d.setNoteSetting(\last, 12) });
~tEq.("a 12-step sequence restarts on every bar line (the default)",
    ns.keep(20).collect(_[\note]) - 60, (0..11) ++ (0..3) ++ (0..3));
ns = run.({ |d| d.setNoteSetting(\scaleOn, false); d.setNoteValues(\pitch, pitches); d.setNoteSetting(\last, 12);
    d.setNoteSetting(\restart, \off) });
~tEq.("...with no restart it goes round on its own", ns.keep(20).collect(_[\note]) - 60, (0..11) ++ (0..7));
ns = run.({ |d| d.setNoteSetting(\scaleOn, false); d.setNoteValues(\pitch, pitches); d.setNoteSetting(\last, 12);
    d.setNoteSetting(\division, 3); d.setNoteSetting(\restart, \loop) }, 98.0);
~tEq.("...on \\loop, every pass of the loop (2 s, eight 8ths)", ns.keep(10).collect(_[\note]) - 60, (0..7) ++ (0..1));

ns = run.({ |d| d.setNoteValues(\ratchet, [3] ++ (0 ! 15)); d.setNoteValues(\shift, [0, 50] ++ (0 ! 14)) }, 92.5);
~tEqArray.("ratchet 3: the step four times through it, then a step shifted half a 16th late",
    ns.keep(5).collect(_[\grid]), [92.0, 92.03125, 92.0625, 92.09375, 92.1875], 1e-9);
~tEq.("...each hit of a ratchet held as long as the step's length says", ns.keep(4).collect(_[\dur]).asSet.size, 1);

ns = run.({ |d| d.setNoteSetting(\swing, 1.0) }, 92.6);
~tEqArray.("swing: every second 16th late by half a 16th, near enough",
    ns.keep(4).collect(_[\grid]), [92.0, 92.125 + (0.498 * 0.125), 92.25, 92.375 + (0.498 * 0.125)], 1e-9);
}.value;
{
var fx = ~nsMake.(), d = fx[\drums], ns;
d.setNotesOn(true, 91.0);
~nsStart.(fx, 92.0);
~nsRun.(fx, 92.43);
d.setNoteSetting(\division, 3);
~nsRun.(fx, 93.5);
ns = ~nsSounding.(fx[\log]);
~tEqArray.("a rate edit: the 16ths decided play, then 8ths from the next 8th on the loop's grid",
    ns.collect(_[\grid]).select { |t| t < 93.1 }, [92.0, 92.125, 92.25, 92.375, 92.5, 92.75, 93.0], 1e-9);
d.free;
}.value;

// A reading landing without a restart: the step count goes on, the steps
// after it on the new 16th; nothing doubles, nothing sent is cancelled.
{
var fx = ~nsMake.(), d = fx[\drums], l = fx[\looper], ns;
var r34 = (numerator: 3, denominator: 4, k: 1, bpm: 90, loopDur: 2.0);
d.setNotesOn(true, 91.0);
~nsStart.(fx, 92.0);
~nsRun.(fx, 93.0);
d.readingArmed((index: 1, result: r34, at: 96.0, loops: 1, restart: false), 93.0);
~nsRun.(fx, 96.0);
~tPut.(l, \readingIndex, 1);
d.setAnalysis(r34, 96.0);
d.readingCleared(96.0);
~nsRun.(fx, 98.2);
ns = ~nsNotes.(fx[\log]);
~tAssert.("notes were sent", ns.size > 0);
~tEqArray.("a reading landing: the old 16ths up to it, the new from it (3/4 in the loop: 12)",
    ns.collect(_[\grid]).select { |t| (t > 95.6) and: { t < 96.4 } }, [95.625, 95.75, 95.875, 96.0, 96 + (1 / 6), 96 + (2 / 6)], 1e-9);
~tEq.("...nothing sent was cancelled, nothing sent twice", [ns.count(_[\cancelled]), ns.collect { |n| n[\grid].round(1e-6) }.asSet.size == ns.size], [0, true]);
~tEq.("...and a bar of 3/4 restarts the line after 12 16ths",
    [96 + (11 / 6), 98.0].collect { |t| d.notePlayheadAt(t + 1e-6) !? { |h| h[\main] } }, [11, 0]);
d.free;
}.value;

// The dice: a function of the seed and the step.
{
var notesOf = { |seed, cut|
    var fx = ~nsMake.(seed: seed), d = fx[\drums], ns;
    d.setNoteSetting(\scaleOn, false);
    d.setNoteValues(\pitch, (0..15));
    d.setNoteSetting(\direction, \random);
    d.setNoteLaneSetting(\velocity, \own, true);
    d.setNoteLaneSetting(\velocity, \direction, \snake);
    d.setNotesOn(true, 91.0);
    ~nsStart.(fx, 92.0);
    if(cut) {
        ~nsRun.(fx, 92.6);
        // A rewind from 92.62: the step at 92.625, decided and sent, is
        // cancelled and decided again.
        d.prRequest([\rewind, 92.62]);
    };
    ~nsRun.(fx, 94.0);
    ns = ~nsSounding.(fx[\log]).collect { |n| [n[\grid].round(1e-6), n[\note], n[\amp].round(1e-6)] };
    if(cut) { ~nsRewound = ~nsNotes.(fx[\log]).select { |n| (n[\grid] - 92.625).abs < 1e-6 }.collect(_[\cancelled]) };
    d.free;
    ns
};
var a = notesOf.(7, false), b = notesOf.(7, false), e = notesOf.(8, false), r = notesOf.(7, true);
~tAssert.("Random and Snake: notes were sent", a.size > 8);
~tEq.("...the same seed draws the same line", a, b);
~tAssert.("...another seed another", a != e);
~tEq.("...a rewind cancels the step it takes back and sends it again", ~nsRewound, [true, false]);
~tEq.("...and steps decided again after a rewind decide the same way", r, a);
}.value;
