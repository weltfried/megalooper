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

// The Looper's break silences the synth as it silences the loop: from the
// moment heard (the stomp less the loop's 20 ms) to the boundary it resumes
// on. The Main | BREAK switch by hand changes the drums' pattern only.
{
var fx = ~nsMake.(), d = fx[\drums], ns, before;
d.setNotesOn(true, 91.0);
~nsStart.(fx, 92.0);
~nsRun.(fx, 93.2);
d.breakOpened(93.32);
d.breakEndsAt(94.0, 93.33);
~nsRun.(fx, 95.0);
ns = ~nsSounding.(fx[\log]).collect(_[\grid]);
~tAssert.("notes were sent around the break", ns.size > 8);
~tEq.("a break: no note in the hole (93.3 to 94.0), the notes before it and from its end on play",
    [ns.select { |t| (t >= 93.3) and: { t < 94.0 } }, ns.includes(93.25), ns.select { |t| t >= 94.0 }.keep(2).round(1e-6)],
    [[], true, [94.0, 94.125]]);
~tEq.("...the hits it cancelled were the ones decided ahead in the hole",
    ~nsNotes.(fx[\log]).select(_[\cancelled]).every { |n| (n[\grid] >= 93.3) and: { n[\grid] < 94.0 } }, true);
before = ~nsSounding.(fx[\log]).size;
d.setBreakPattern(true, 95.02);
~nsRun.(fx, 96.0);
ns = ~nsSounding.(fx[\log]).collect(_[\grid]).select { |t| (t >= 95.0) and: { t < 96.0 } };
~tEq.("the Break pattern switched in by hand: the drums change, the synth plays on",
    [d.breakActive, ns.size], [true, 8]);
d.setBreakPattern(false, 96.0);
d.breakOpened(96.52);
d.breakClosed(96.77);
~nsRun.(fx, 97.5);
ns = ~nsSounding.(fx[\log]).collect(_[\grid]).select { |t| (t >= 96.0) and: { t < 97.5 } };
~tEq.("a break cut short (a stop or a clear): the synth from the moment heard on",
    ns.round(1e-6), [96.0, 96.125, 96.25, 96.375, 96.75, 96.875, 97.0, 97.125, 97.25, 97.375]);
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

// Keep the dice (docs/dev/roadmap.md item 20, the light cone): every Start
// draws new dice; kept, the seed heard is every Start's, and a preset or Keep
// carries it.
{
var fx = ~nsMake.(seed: nil), d = fx[\drums], played, first, second, third, notes, data;
// Each Start's first bar, from its own start, as [step, note, amp].
played = { |from, to|
    ~nsSounding.(fx[\log]).select { |n| (n[\grid] >= (from - 1e-9)) and: { n[\grid] < (to - 1e-9) } }
        .collect { |n| [((n[\grid] - from) / 0.125).round.asInteger, n[\note], n[\amp].round(1e-6)] }
};
d.setNoteSetting(\scaleOn, false);
d.setNoteValues(\pitch, (0..15));
d.setNoteSetting(\direction, \random);
d.setNoteLaneSetting(\velocity, \own, true);
d.setNoteLaneSetting(\velocity, \direction, \random);
d.setNotesOn(true, 91.0);
~tEq.("the dice are new every Start to begin with", d.keptDice, nil);
~nsStart.(fx, 92.0);
~nsRun.(fx, 94.0);
first = played.(92.0, 94.0);
d.transportStop(94.0);
d.keepDice(true);
~tEq.("Keep: the seed of the Start heard is kept", d.keptDice, d.lastSeed);
~nsStart.(fx, 96.0);
~nsRun.(fx, 98.0);
second = played.(96.0, 98.0);
~tAssert.("notes were sent at both Starts", (first.size > 8) and: { second.size > 8 });
~tEq.("...and the next Start plays the same notes, from bar 1", second, first);
d.transportStop(98.0);
d.keepDice(false);
~nsStart.(fx, 100.0);
~nsRun.(fx, 102.0);
third = played.(100.0, 102.0);
~tAssert.("let go, the next Start draws new ones", third != first);
d.setDice(4242);
data = d.presetData("x");
~tEq.("a preset holds the seed kept, false for new dice", [data[\dice], { d.setDice(nil); d.presetData("y")[\dice] }.value],
    [4242, false]);
notes = List.new;
~tEq.("...and puts it back", [d.applyPresetData(data, notes), d.keptDice], [true, 4242]);
~tEq.("...false lets it go", [d.applyPresetData(data.copy.put(\dice, false), notes), d.keptDice], [true, nil]);
d.setDice(7);
~tEq.("...one that is no seed is said and the dice in force stay",
    [d.applyPresetData(data.copy.put(\dice, "x"), notes), d.keptDice, notes.any { |n| n.contains("dice") }], [true, 7, true]);
~tAssert.("...and the file says it", d.presetText(d.presetData("z")).contains("\"dice\": 7"));
d.free;
}.value;

// ------------------------------------------------------- from the loop --
// The loop's key (LoopKey.keyOf, the Looper's \loopKey; docs/dev/synth.md 6):
// decide takes it while the pattern follows it, the drums land it on the
// next bar line and hand its tuning to every note, and a root or scale
// chosen by hand takes over from it.
{
var c = MegaSANoteSeq, pat = c.defaultPattern, st, out, key = (root: 4, intervals: [0, 3, 5, 7, 10]);
var line = { |p, k| st = nil; (0..15).collect { |i| out = c.decide(p, i, st, { 0 }, k); st = out[\state]; out[\note][\note] } };
~tEq.("a fresh pattern follows the loop's key", [pat[\fromLoop], c.settingNames.includes(\fromLoop)], [true, true]);
~tEq.("...with no key it plays its own root and scale", line.(pat, nil),
    [60, 67, 72, 67, 63, 67, 70, 67, 60, 67, 72, 70, 68, 67, 63, 62]);
~tEq.("...with E minor pentatonic: pitch 0 is E, every pitch snapped down to the key's notes", line.(pat, key),
    [64, 71, 76, 71, 67, 71, 74, 71, 64, 71, 76, 74, 71, 71, 67, 64]);
~tEq.("...a set of its own (E, G, B: unsure) snaps the same way", line.(pat, (root: 4, intervals: [0, 3, 7])),
    [64, 71, 76, 71, 67, 71, 71, 71, 64, 71, 76, 71, 71, 71, 67, 64]);
~tEq.("...with Scale off, plain semitones from the key's root", line.(pat.copy.put(\scaleOn, false), key),
    [64, 71, 76, 71, 67, 71, 74, 71, 64, 71, 76, 74, 72, 71, 67, 66]);
~tEq.("...not followed (fromLoop off), the key counts for nothing", line.(pat.copy.put(\fromLoop, false), key),
    line.(pat, nil));
~tEq.("fromLoop is a switch", [c.cleanSetting(\fromLoop, false), c.cleanSetting(\fromLoop, 1)], [false, nil]);
}.value;

{
var fx = ~nsMake.(), d = fx[\drums], ns, said = List.new, cents = List.new, ctl;
var key = (root: 4, intervals: [0, 3, 5, 7, 10], pcs: [2, 4, 7, 9, 11], name: "Minor pentatonic", scale: 11,
    cents: 18, core: false);
ctl = SimpleController(d).put(\loopKey, { |obj, what, k, at| said.add([k, at]) });
d.noteVoice = { |rec, where| cents.add([rec[\grid], rec[\cents]]); MegaSADrums.toneMsgs(rec, where) };
d.setNotesOn(true, 91.0);
~nsStart.(fx, 92.0);
~nsRun.(fx, 93.05);
d.setLoopKey(key);
~tEq.("a key heard while the drums play: said, with the bar line it lands on", said.size, 1);
~tNear.("...the next bar line past the lead (93.05 + 0.106: 94.0)", said[0][1], 94.0, 1e-6);
~tEq.("...in force from the line, not before", [d.loopKeyAt(93.99), d.loopKeyAt(94.0) !? { |k| k[\root] }], [nil, 4]);
~nsRun.(fx, 95.0);
ns = ~nsSounding.(fx[\log]);
~tEq.("...the notes before the line in the pattern's own C minor, from it in E minor pentatonic",
    [ns.select { |n| (n[\grid] >= 93.0) and: { n[\grid] < 94.0 } }.collect(_[\note]),
        ns.select { |n| (n[\grid] >= 94.0) and: { n[\grid] < 95.0 } }.collect(_[\note])],
    [[60, 67, 72, 70, 68, 67, 63, 62], [64, 71, 76, 71, 67, 71, 74, 71]]);
~tEq.("...and every note from it carries the loop's tuning, those before none",
    [cents.select { |x| x[0] < 94.0 }.collect(_[1]).asSet.asArray, cents.select { |x| x[0] >= 94.0 }.collect(_[1]).asSet.asArray],
    [[0], [18]]);
~tEq.("what it plays from now: the key's root and notes, the key followed",
    d.noteKeyInForce(94.5).atAll(#[\root, \intervals, \name, \scale]), [4, [0, 3, 5, 7, 10], "Minor pentatonic", 11]);
d.setLoopKey(key.copy);
~tEq.("the same key again: nothing said", said.size, 1);

// A scale chosen by hand takes over from the loop's key, from its root.
d.setNoteSetting(\scale, 2);
~tEq.("a scale chosen by hand: from the loop's root, From the loop off",
    d.notes.atAll(#[\root, \scale, \fromLoop]), [4, 2, false]);
~tEq.("...what it plays now is the pattern's own", d.noteKeyInForce(94.5).atAll(#[\root, \name, \key]), [4, "Dorian", nil]);
d.setNoteSetting(\fromLoop, true);
d.setNoteSetting(\root, 7);
~tEq.("a root chosen by hand: in the loop's scale, From the loop off", d.notes.atAll(#[\root, \scale, \fromLoop]),
    [7, 11, false]);
d.setNoteSetting(\fromLoop, true);
d.setLoopKey(key.copy.putAll((intervals: [0, 3, 7], pcs: [4, 7, 11], name: nil, scale: nil, core: true)));
d.setNoteSetting(\root, 2);
~tEq.("...with a set of its own, the pattern's scale stays", d.notes.atAll(#[\root, \scale, \fromLoop]), [2, 11, false]);
d.setNoteSetting(\fromLoop, true);
d.setNoteSetting(\root, "E");
~tEq.("...a root that is none changes nothing", [d.notes[\fromLoop], d.notes[\root]], [true, 2]);

// No loop: the key goes at the next line too; the transport stopped, at once.
d.setLoopKey(nil);
~tEq.("the key gone (a Clear): said, landing on a line", [said.last[0], said.last[1].notNil], [nil, true]);
d.transportStop(96.0);
~nsRun.(fx, 96.5);
d.setLoopKey(key);
~tEq.("with the transport stopped a key is in at once", [said.last[1], d.loopKeyAt(96.5) !? { |k| k[\root] }], [nil, 4]);
ctl.remove;
d.free;
}.value;

// The drums take the Looper's key as they attach, and follow its \loopKey.
{
var fx = ~nsMake.(), d = fx[\drums], l = fx[\looper], key = (root: 9, intervals: [0, 2, 3, 5, 7, 8, 10], cents: -5);
l.keyPart.instVarPut(\key, key);
d.attach(l);
~tEq.("attached: the Looper's key", d.loopKey[\root], 9);
l.changed(\loopKey, nil);
~tEq.("...and its \\loopKey followed", d.loopKey, nil);
d.free;
}.value;

// A loop that changes key: each bar plays in its section's key, from the
// bar line (Changes, loopChanges, on); off, the loop's one key.
{
var fx = ~nsMake.(92.0, 4.0), d = fx[\drums], ns, inBar;
var e = (root: 4, intervals: [0, 3, 5, 7, 10], pcs: [2, 4, 7, 9, 11], name: "Minor pentatonic", scale: 11, core: false);
var a = (root: 9, intervals: [0, 3, 5, 7, 10], pcs: [0, 2, 4, 7, 9], name: "Minor pentatonic", scale: 11, core: false);
var key = (root: 4, intervals: [0, 2, 3, 5, 7, 8, 10], pcs: [0, 2, 4, 6, 7, 9, 11], name: "Minor", scale: 1, core: false,
    cents: 10, sections: [(from: 0, to: 1, at: 0, key: e), (from: 1, to: 2, at: 2.0, key: a)], period: 4.0);
~tPut.(fx[\looper], \lastResult, (numerator: 4, denominator: 4, k: 2, bpm: 120, loopDur: 4.0));
d.setLoopKey(key, 90.0);
d.setNotesOn(true, 91.0);
~nsStart.(fx, 92.0);
~nsRun.(fx, 96.0);
ns = ~nsSounding.(fx[\log]);
inBar = { |t0| ns.select { |n| (n[\grid] >= (t0 - 1e-6)) and: { n[\grid] < (t0 + 2 - 1e-6) } }.collect(_[\note]).keep(4) };
~tAssert.("notes were sent over two passes of a two-bar loop", ns.size > 24, ns.size.asString);
~tEq.("a loop in E minor pentatonic, then A minor pentatonic: bar 1 plays from E, bar 2 from A, every pass",
    [inBar.(92.0), inBar.(94.0), inBar.(96.0 - 2)], [[64, 71, 76, 71], [69, 76, 81, 76], [69, 76, 81, 76]]);
~tEq.("...what plays now is the section's key, with the loop's tuning",
    [d.loopKeyAt(92.5)[\root], d.loopKeyAt(94.5)[\root], d.loopKeyAt(94.5)[\cents]], [4, 9, 10]);
d.setNoteSetting(\loopChanges, false);
~nsRun.(fx, 100.0);
ns = ~nsSounding.(fx[\log]);
~tEq.("Changes off: both bars in the loop's one key (E minor), from E",
    [inBar.(98.0), inBar.(98.0 + 2)].collect { |x| x.first }, [64, 64]);
d.free;
}.value;
