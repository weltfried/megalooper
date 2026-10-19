// Megalooper SA's drums, the half that needs no server: Rhythmic Steps' rules
// as MegaSASteps reconstructs them from the device's patch, the kits
// (MegaSAKit), the MIDI-port adapter the Looper drives (MegaSATransport), and
// the Looper's SA hooks. The scheduler that puts these on a clock, and the
// voices they play, are MegaSADrums' and have their own tests.
//
// Golden values at MID settings, not only at the ends: sclang has no operator
// precedence, so a formula transcribed with school precedence comes out right
// at velocity 127, sensitivity 0 or delay 0 and wrong everywhere in between.
// The tables and the patterns are checked against the device's own reading
// (the survey of Rhythmic Steps.amxd) and against presets/sa/rhythmic-steps.json.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-megadrums");

// ------------------------------------------------------------------ tables --
{
var st = MegaSASteps;
~tEq.("Clock Speed 0..5 in ticks at 480 a quarter", st.stepTicks, [240, 180, 150, 120, 90, 60]);
~tEq.("the set's Clock Speed 3 steps in 16ths", st.stepTicks[3], 120);
~tEq.("Roll Rate 0..8 in ticks", st.rollTicks, [360, 240, 160, 180, 120, 80, 90, 60, 40]);
~tEq.("the set's Roll Rate 5 (1/16t) is two thirds of a 16th", st.rollTicks[5], 80);
~tEq.("the velocities", st.velocities, [10, 29, 49, 68, 88, 107, 127]);
~tEq.("...are Max's [scale 0 6 10 127], truncated",
    (0..6).collect { |v| ((v * 19.5) + 10).floor.asInteger }, st.velocities.asArray);
~tEq.("the slide values, likewise", st.slideValues, [0, 21, 42, 63, 84, 105, 127]);
~tEq.("Clock Speed's labels", st.clockSpeedLabels, ["50 %", "66 %", "75 %", "100 %", "150 %", "200 %"]);
~tEq.("Roll Rate's labels", st.rollRateLabels,
    ["1/8.", "1/8", "1/8t", "1/16.", "1/16", "1/16t", "1/32.", "1/32", "1/32t"]);
~tEq.("Auto Trigger Rate's labels", st.autoTriggerRateLabels, ["1 Bar", "2 Bars", "3 Bars", "4 Bars"]);
~tEq.("the sub-lanes in the device's storage order", st.subs, [\chance, \velo, \alt, \roll, \slide]);
~tEq.("the pages the Drums tab shows", st.pages, [\chance, \alt, \velo, \roll]);
// The original device's own help texts are Ableton's, and not shipped.
~tAssert.("no copy of the device's help texts", st.respondsTo(\deviceTips).not);
}.value;

// --------------------------------------------------- velocity and rolls --
{
var st = MegaSASteps;
var table = [
    [10, [7, 4, 3, 2, 1, 1]], [29, [20, 14, 9, 6, 4, 3]], [49, [34, 24, 16, 11, 8, 5]],
    [68, [47, 33, 23, 16, 11, 8]], [88, [61, 43, 30, 21, 14, 10]], [107, [74, 52, 36, 25, 17, 12]],
    [127, [88, 62, 43, 30, 21, 14]]
];
~tEq.("a mid velocity step (3) plays 68", st.velocity(3), 68);
~tEq.("step 0 still sounds, at 10, and 6 is 127", [st.velocity(0), st.velocity(6)], [10, 127]);
~tEq.("out-of-range steps are held to 0..6", [st.velocity(-1), st.velocity(9)], [10, 127]);
// The device's [* 0.7] -> [i]: each extra hit 0.7 of the one before, truncated
// (the Phase 4 survey of its patch).
table.do { |row|
    ~tEq.("a roll from " ++ row[0] ++ " decays as the device's", st.rollVelocities(row[0], 6), row[1]);
};
~tEq.("a 2-hit roll from 68 (mid)", st.rollVelocities(68, 2), [47, 33]);
~tEq.("no roll adds nothing", st.rollVelocities(68, 0), []);
~tEqArray.("roll hits at 1/16t, a 16th of 75 ms: every 50 ms", st.rollTimes(2, 5, 0.075), [0.05, 0.1]);
~tEqArray.("...at 1/16: a 16th apart", st.rollTimes(3, 4, 0.075), [0.075, 0.15, 0.225]);
~tEqArray.("...at 1/8.: three 16ths apart", st.rollTimes(1, 0, 0.1), [0.3]);
}.value;

// ----------------------------------------------------------------- shuffle --
{
var st = MegaSASteps;
var set = st.livePattern(\main);
var full = st.shuffleOffsets(set[\shuffle], set[\shuffleLength], 100);
var half = st.shuffleOffsets(set[\shuffle], set[\shuffleLength], 50);
var none = st.shuffleOffsets(set[\shuffle], set[\shuffleLength], set[\globalShuffle]);
var straight;
~tEq.("one offset per step of the shuffle cycle", full.size, 7);
~tEqArray.("the set's dials at Global Shuffle 100 %", full,
    [0.235, 0.683, 1.772, 2.780, 3.683, 4.826, 6.163], 0.0005);
~tEq.("...fire at 0.25, 0.75, 2.0, 3.0, 3.75, 5.0 and 6.25 steps",
    (0..6).collect { |n| st.fireTick(n, 120, full, 7) / 120 }, [0.25, 0.75, 2.0, 3.0, 3.75, 5.0, 6.25]);
~tEq.("...on whole 1/64 ticks", (0..6).collect { |n| st.fireTick(n, 120, full, 7) },
    [30, 90, 240, 360, 450, 600, 750]);
~tEq.("...and the next cycle is the same, a cycle (7 steps) later",
    (7..13).collect { |n| st.fireTick(n, 120, full, 7) - 840 }, [30, 90, 240, 360, 450, 600, 750]);
~tEq.("at Global Shuffle 50 % (mid) half the shift",
    (0..6).collect { |n| st.fireTick(n, 120, half, 7) }, [30, 120, 240, 360, 480, 600, 750]);
~tEqArray.("...offsets 0.008 x dial x 50 %", half.copyRange(0, 1),
    [0.004 * set[\shuffle][0], 1 + (0.004 * set[\shuffle][1])], 1e-12);
~tEq.("the set's Global Shuffle 0 leaves the steps exactly where they were",
    none, [0, 1, 2, 3, 4, 5, 6]);
straight = st.stepTicks.every { |s|
    (0..199).every { |n| st.fireTick(n, s, none, 7) == (n * s) }
};
~tAssert.("...so step n fires on n * s at every Clock Speed: Live's own grid", straight);
~tAssert.("fireTick is an Integer", st.fireTick(5, 120, full, 7).isInteger);
}.value;

// --------------------------------------------- collisions and carrying on --
{
var st = MegaSASteps;
var pulled = st.shuffleOffsets([45, -45, 0, 0, 0, 0, 0, 0], 4, 100);
var flat = st.shuffleOffsets(nil, 4, 0);
var set = st.livePattern(\main);
var full = st.shuffleOffsets(set[\shuffle], 7, 100);
var s = st.stepTicks[4];
~tEq.("at Clock Speed 150 % two pulled-together steps land on one 1/64 tick",
    [st.fireTick(0, s, pulled, 4), st.fireTick(1, s, pulled, 4)], [60, 60]);
~tAssert.("...so the earlier never plays", st.skipsStep(0, s, pulled, 4));
~tAssert.("...and the later does", st.skipsStep(1, s, pulled, 4).not);
~tAssert.("...in every cycle", st.skipsStep(4, s, pulled, 4) and: { st.skipsStep(5, s, pulled, 4).not });
~tAssert.("nothing collides unshuffled, at any Clock Speed",
    st.stepTicks.every { |sp| (0..63).every { |n| st.skipsStep(n, sp, flat, 4).not } });
~tEq.("the first step after a tick, unshuffled", st.firstStepAfter(1000, 120, flat, 4), 9);
~tEq.("...exactly on a step's tick, the next one", st.firstStepAfter(960, 120, flat, 4), 9);
~tEq.("...before the origin, step 0", st.firstStepAfter(-50, 120, flat, 4), 0);
~tEq.("...shuffled: after tick 100, the step that fires at 240", st.firstStepAfter(100, 120, full, 7), 2);
// Clock Speed edits at bar 20 of 4/4 (tick 38400): the pattern carries on within
// a step instead of going silent for 20 bars or replaying 320 steps.
~tEq.("Clock Speed 100 -> 50 % at bar 20 carries on at step 161",
    st.firstStepAfter(38400, st.stepTicks[0], flat, 4), 161);
~tEq.("...100 -> 200 % at step 641", st.firstStepAfter(38400, st.stepTicks[5], flat, 4), 641);
~tAssert.("...each within one new step of the edit",
    [0, 5].every { |cs| var sp = st.stepTicks[cs], n = st.firstStepAfter(38400, sp, flat, 4);
        (st.fireTick(n, sp, flat, 4) - 38400) <= sp });
~tEq.("the step a tick falls in", [st.stepIndexAt(1080, 120), st.stepIndexAt(359.9999999, 120),
    st.stepIndexAt(1199, 120)], [9, 3, 9]);
}.value;

// ----------------------------------------------------------------- resync --
// Walked over the helpers as the scheduler will: every step's tick through
// resync, a resync wherever the lanes' origin moves to the step itself.
{
var st = MegaSASteps;
var walk = { |numerator, steps = 128, clockSpeed = 3, rate = 0, retrig = true|
    var s = st.stepTicks[clockSpeed], v = st.shuffleOffsets(nil, 4, 0), state, at = List.new, ls = List.new;
    steps.do { |n|
        state = st.resync(state, n, st.fireTick(n, s, v, 4), numerator, retrig, rate);
        if(retrig and: { state[\offset] == n }) { at.add(n) };
        ls.add(n - state[\offset]);
    };
    [at.asArray, ls.asArray]
};
var bars = { |ls, barLen, count| (0..(count - 1)).collect { |b|
    ls.copyRange(b * barLen, ((b + 1) * barLen) - 1).collect { |x| st.laneIndex(x, 16) } } };
var before, after;
~tEq.("4/4 resyncs on every bar line", walk.(4)[0], [0, 16, 32, 48, 64, 80, 96, 112]);
~tEq.("3/4: 0, 16, 24, 40, 48, ...", walk.(3)[0], [0, 16, 24, 40, 48, 64, 72, 88, 96, 112, 120]);
~tEq.("5/4: 0, 24, 40, 64, 80, ...", walk.(5)[0], [0, 24, 40, 64, 80, 104, 120]);
~tEq.("7/8: 0, 32, 56, 88, 112 (pseudo-bars of 7 quarters)", walk.(7)[0], [0, 32, 56, 88, 112]);
~tEq.("6/8: 0, 24, 48, ...", walk.(6)[0], [0, 24, 48, 72, 96, 120]);
~tEq.("7/8's 16-step lane through four bars, as the survey of the patch reads it",
    bars.(walk.(7)[1], 14, 5),
    [(0..13), [14, 15] ++ (0..11), (12..15) ++ (0..9), (10..15) ++ (0..7), (0..13)]);
~tEq.("3/4's: bar 2 is c d e f then 0-7, and it repeats every two bars",
    bars.(walk.(3)[1], 12, 3), [(0..11), (12..15) ++ (0..7), (0..11)]);
~tEq.("4/4 at Clock Speed 50 %: 8ths, still on the bar lines", walk.(4, 40, 0)[0], [0, 8, 16, 24, 32]);
~tEq.("Auto Trigger Rate 2 Bars in 4/4: every other bar", walk.(4, 128, 3, 1)[0], [0, 32, 64, 96]);
~tEq.("Auto Retrigger off: the lanes run on from the origin", walk.(7, 64, 3, 0, false)[1], (0..63));
before = (lastB: 3, armed: true, offset: 8);
after = st.resync(before, 16, 1920, 4, true, 0);
~tAssert.("resync answers a new state and leaves the old one alone",
    (after !== before) and: { before[\offset] == 8 } and: { before[\armed] == true });
~tEq.("...armed, it resyncs on the next multiple of 8", after[\offset], 16);
~tEq.("a resync waits for a multiple of 8",
    st.resync((lastB: 0, armed: true, offset: 0), 12, 1440, 3, true, 0)[\offset], 0);
}.value;

// SA's rule (resyncAtBar): the lanes start again ON the first step of every
// bar the caller names, uneven bars too.
{
var st = MegaSASteps;
// 16ths, 7 7 7 8 over 8: bars of 14, 14, 14 and 16 steps, 58 a loop.
var barOf = { |n| var w = n % 58; ((n div: 58) * 4) + [0, 14, 28, 42].count { |b| b <= w } - 1 };
var walk = { |rate = 0, retrig = true, armedAt|
    var state, at = List.new;
    120.do { |n|
        if(n == armedAt) { state = state.copy.put(\armed, true) };
        state = st.resyncAtBar(state, n, barOf.(n), retrig, rate);
        if(state[\offset] == n) { at.add(n) };
    };
    at.asArray
};
~tEq.("7 7 7 8: on every bar line, the long bar's 16 steps too", walk.(), [0, 14, 28, 42, 58, 72, 86, 100, 116]);
~tEq.("...every other bar at Rate 2 Bars", walk.(1), [0, 28, 58, 86, 116]);
~tEq.("...Auto Retrigger off: from the origin only", walk.(0, false), [0]);
~tEq.("...off, an armed state resyncs on the next bar line", walk.(0, false, 20), [0, 28]);
~tAssert.("it answers a new state", { |before| (st.resyncAtBar(before, 14, 1, true, 0) !== before)
    and: { before[\offset] == 0 } }.((lastB: 0, armed: false, offset: 0)));
}.value;

// --------------------------------------------------------- lane indexing --
{
var st = MegaSASteps;
var p = st.livePattern(\main);
~tEq.("a lane step wraps on the sub-lane's length", st.laneIndex(17, 16), 1);
~tEq.("a negative lane step still reads a step of the lane",
    [st.laneIndex(-1, 16), st.laneIndex(-17, 16), st.laneIndex(-3, 5)], [15, 15, 2]);
~tEq.("a 5-step sub-lane wraps on 5", (0..11).collect { |x| st.laneIndex(x, 5) },
    [0, 1, 2, 3, 4, 0, 1, 2, 3, 4, 0, 1]);
st.putLength(p, \chance, 0, 5);
~tEq.("a sub-lane plays its own length", st.effectiveLength(p, \chance, 0), 5);
st.putLaneParam(p, 0, \globalLength, 8);
~tEq.("setting the global length while unlocked changes nothing it plays",
    st.effectiveLength(p, \chance, 0), 5);
~tEq.("...and writes no sub-lane's length", p[\lengths][\chance][0], 5);
st.putLaneParam(p, 0, \lock, true);
~tEq.("locked, every page plays the global length", st.subs.collect { |sub| st.effectiveLength(p, sub, 0) },
    [8, 8, 8, 8, 8]);
~tEq.("...the other lanes keep theirs", st.effectiveLength(p, \chance, 1), 16);
st.putLaneParam(p, 0, \lock, false);
~tEq.("unlocking brings the sub-lane's own length back", st.effectiveLength(p, \chance, 0), 5);
}.value;

// ------------------------------------------------------------- decideStep --
{
var st = MegaSASteps;
var p = st.newPattern;
var calls = List.new;
var byKind = { |alts, chances| { |lane, kind| calls.add([lane, kind]); if(kind == \alt) { alts[lane] } { chances[lane] } } };
var hits, b;
// lane 0: chance 3, alt 2, velocity step 3, a 2-hit roll, 20 ms late (mid values)
st.putStep(p, \chance, 0, 0, 3);
st.putStep(p, \alt, 0, 0, 2);
st.putStep(p, \velo, 0, 0, 3);
st.putStep(p, \roll, 0, 0, 2);
st.putLaneParam(p, 0, \delay, 20);
st.putLaneParam(p, 0, \note, 42);
st.putLaneParam(p, 0, \altNote, 44);
// lane 1 chance 0 (never), lane 2 chance 6 (always), lane 3 chance 3
st.putStep(p, \chance, 2, 0, 6);
st.putStep(p, \chance, 3, 0, 3);
hits = st.decideStep(p, 0, byKind.([0, 0, 0, 0], [0, 0, 0, 0]));
~tEq.("the draws go lanes 3 to 0, alt before chance, every lane both",
    calls.asArray, [[3, \alt], [3, \chance], [2, \alt], [2, \chance], [1, \alt], [1, \chance], [0, \alt], [0, \chance]]);
~tEq.("four entries, index = lane", hits.size, 4);
~tAssert.("chance 0 never fires, even on a 0", hits[1].isNil);
hits = st.decideStep(p, 0, byKind.([0, 0, 0, 0], [3, 5, 5, 2]));
~tAssert.("a step fires only if its chance BEATS its die: 3 on a 3 does not", hits[0].isNil);
~tAssert.("chance 6 always fires, even on a 5", hits[2].notNil);
~tAssert.("chance 3 on a 2 fires", hits[3].notNil);
hits = st.decideStep(p, 0, byKind.([2, 0, 0, 0], [2, 0, 0, 0]));
~tEq.("what it plays: the note, the step's velocity, the roll and the delay",
    [hits[0][\note], hits[0][\vel], hits[0][\roll], hits[0][\delayMs], hits[0][\alt]], [42, 68, 2, 20.0, false]);
hits = st.decideStep(p, 0, byKind.([1, 0, 0, 0], [2, 0, 0, 0]));
~tEq.("alt is its own draw: alt 2 on a 1 plays the alternate pad", [hits[0][\note], hits[0][\alt]], [44, true]);
hits = st.decideStep(p, 0, byKind.([1, 0, 0, 0], [5, 0, 0, 0]));
~tAssert.("...and does not make a step fire", hits[0].isNil);
~tEq.("an unwritten velocity step plays the device's 4: 88", st.decideStep(p, 0, byKind.([0, 0, 0, 0], [0, 0, 0, 0]))[2][\vel], 88);
// sub-lane lengths and lock, read at the lane step given
st.putStep(p, \chance, 3, 5, 6);
st.putStep(p, \alt, 3, 2, 6);
st.putLaneParam(p, 3, \altNote, 41);
~tEq.("each sub-lane reads its own length: alt over 3 steps at lane step 5",
    { st.putLength(p, \alt, 3, 3); st.decideStep(p, 5, byKind.([5, 5, 5, 5], [5, 5, 5, 5]))[3][\note] }.value, 41);
~tEq.("...and over 16 it is step 5's own alt (0)",
    { st.putLength(p, \alt, 3, 16); st.decideStep(p, 5, byKind.([5, 5, 5, 5], [5, 5, 5, 5]))[3][\note] }.value,
    p[\note][3]);
st.putLaneParam(p, 3, \globalLength, 3);
st.putLaneParam(p, 3, \lock, true);
~tAssert.("locked to 3 steps, lane step 5 reads chance step 2 (0): silent",
    st.decideStep(p, 5, byKind.([5, 5, 5, 5], [5, 5, 5, 5]))[3].isNil);
st.putLaneParam(p, 2, \mute, true);
~tAssert.("a muted lane is still decided (mute is applied when a hit is emitted)",
    st.decideStep(p, 0, byKind.([0, 0, 0, 0], [0, 0, 0, 0]))[2].notNil);
// The set's break, step 1: the closed hat for sure, the pedal hat with P 1/2.
b = st.livePattern(\break);
hits = st.decideStep(b, 0, byKind.([5, 5, 5, 5], [5, 5, 5, 5]));
~tEq.("the break's step 1 on high dice: only lane 0, the closed hat at 88",
    hits.collect { |h| h !? { |x| [x[\note], x[\vel]] } }, [[42, 88], nil, nil, nil]);
~tEq.("...on low dice the pedal hat", st.decideStep(b, 0, byKind.([0, 0, 0, 0], [0, 0, 0, 0]))[0][\note], 44);
}.value;

// ------------------------------------------------------------------ dice --
{
var st = MegaSASteps;
var chi = { |counts, expect| counts.sum { |c| ((c - expect) ** 2) / expect } };
var seq = (0..999).collect { |n| st.dice(12345, \main, n, 0, \chance) };
var counts = Array.fill(6, 0), pairs, prev, x;
~tEq.("the dice are a pure function of their inputs", seq,
    (0..999).collect { |n| st.dice(12345, \main, n, 0, \chance) });
~tAssert.("every die is an Integer 0..5", seq.every { |d| d.isInteger and: { d >= 0 } and: { d <= 5 } });
~tAssert.("another seed throws other dice", seq != (0..999).collect { |n| st.dice(54321, \main, n, 0, \chance) });
~tAssert.("each kind, lane and pattern has its own die",
    [[\main, 0, \alt], [\main, 1, \chance], [\break, 0, \chance], [\main, 0, \repeat]].every { |k|
        seq != (0..999).collect { |n| st.dice(12345, k[0], n, k[1], k[2]) } });
// The hash leans on sclang's Integers wrapping at 32 bits; these come from a
// reference implementation of the same hash with explicit 32-bit masks.
~tEq.("the hash agrees with its reference implementation",
    [st.dice(12345, \main, 0, 0, \alt), st.dice(12345, \main, 0, 0, \chance), st.dice(12345, \break, 0, 0, \alt),
        st.dice(1, \main, 100, 3, \chance), st.dice(0, \main, 0, 0, \alt), st.dice(-7, \break, 999, 2, \repeat),
        st.dice(2147483647, \main, 123456, 1, \onset)], [0, 3, 4, 5, 5, 0, 0]);
~tEq.("...the first lane's chance dice at seed 12345", seq.keep(16), [3, 3, 0, 2, 5, 1, 1, 0, 0, 3, 0, 2, 0, 3, 5, 0]);
~tNear.("uniform is the same hash as a fraction", st.uniform(12345, \main, 0, 0, \chance), 0.5128612332046032, 1e-12);
~tAssert.("uniform stays in [0, 1)", (0..999).every { |n| var u = st.uniform(7, \main, n, 3, \repeat); (u >= 0) and: { u < 1 } });
// Uniform and independent, by chi-square at p = 0.001: 20.52 on 5 degrees of
// freedom, 66.62 on 35.
15000.do { |n| 4.do { |lane| x = st.dice(12345, \main, n, lane, \chance); counts[x] = counts[x] + 1 } };
~tAssert.("60000 dice are uniform (chi-square " ++ chi.(counts, 10000).round(0.01) ++ ", 5 dof)",
    chi.(counts, 10000) < 20.52, counts.asString);
pairs = Array.fill(36, 0);
prev = st.dice(12345, \main, 0, 0, \chance);
(1..60000).do { |n| x = st.dice(12345, \main, n, 0, \chance); pairs[(prev * 6) + x] = pairs[(prev * 6) + x] + 1; prev = x };
~tAssert.("consecutive steps' dice are independent (chi-square " ++ chi.(pairs, 60000 / 36).round(0.01) ++ ", 35 dof)",
    chi.(pairs, 60000 / 36) < 66.62);
pairs = Array.fill(36, 0);
60000.do { |n| var a = st.dice(12345, \main, n, 1, \alt), c = st.dice(12345, \main, n, 1, \chance);
    pairs[(a * 6) + c] = pairs[(a * 6) + c] + 1 };
~tAssert.("a step's alt and chance dice are independent (chi-square " ++ chi.(pairs, 60000 / 36).round(0.01) ++ ")",
    chi.(pairs, 60000 / 36) < 66.62);
pairs = Array.fill(36, 0);
60000.do { |n| var a = st.dice(12345, \main, n, 2, \chance), c = st.dice(12345, \break, n, 2, \chance);
    pairs[(a * 6) + c] = pairs[(a * 6) + c] + 1 };
~tAssert.("the two patterns' dice are independent (chi-square " ++ chi.(pairs, 60000 / 36).round(0.01) ++ ")",
    chi.(pairs, 60000 / 36) < 66.62);
}.value;

// ------------------------------------------- the Live patterns vs the JSON --
{
var root = thisProcess.nowExecutingPath.dirname.dirname.dirname;
var json = File.readAllString(root +/+ "presets" +/+ "sa" +/+ "rhythmic-steps.json").parseJSON;
var subNames = (chance: "Chance", velo: "Velo", alt: "Alt", roll: "Roll", slide: "Slide");
var lenNames = (chance: "Length Chance", velo: "Length Velocity", alt: "Length Alternate",
    roll: "Length Roll", slide: "Length Mod");
var int = { |s| s.asInteger }, flt = { |s| s.asFloat }, bool = { |s| (s == "1") or: { s == "true" } };
var p1, p2;
[[\main, 0, "Rhythmic Steps"], [\break, 1, "break"]].do { |row|
    var which = row[0], dev = json["devices"][row[1]];
    var lanes = dev["lanes"], params = dev["parameters"];
    var p = MegaSASteps.livePattern(which), bad = List.new, used = Set.new;
    var check = { |name, conv, want|
        used.add(name);
        if(params[name].isNil or: { conv.(params[name]) != want }) {
            bad.add(name ++ ": " ++ params[name] ++ " vs " ++ want);
        };
    };
    ~tEq.(which ++ ": the JSON's device is the " ++ row[2] ++ " branch", dev["branch"], row[2]);
    MegaSASteps.subs.do { |sub|
        4.do { |lane|
            var key = subNames[sub] ++ "-Steps[" ++ (lane + 1) ++ "]";
            if((lanes[key] ? []).collect(int) != p[\steps][sub][lane]) { bad.add(key) };
        };
    };
    4.do { |lane|
        var n = (lane + 1).asString;
        MegaSASteps.subs.do { |sub| check.(lenNames[sub] ++ " " ++ n, int, p[\lengths][sub][lane]) };
        check.("Global Length " ++ n, int, p[\globalLength][lane]);
        check.("Lock Length " ++ n, bool, p[\lock][lane]);
        check.("Pad Note " ++ n, int, p[\note][lane]);
        check.("Pad Alt Note " ++ n, int, p[\altNote][lane]);
        check.("Delay " ++ n, flt, p[\delay][lane]);
        check.("Mute " ++ n, bool, p[\mute][lane]);
    };
    8.do { |i| check.("Shuffle " ++ (i + 1), flt, p[\shuffle][i]) };
    check.("Clock Speed", int, p[\clockSpeed]);
    check.("Roll Rate", int, p[\rollRate]);
    check.("Shuffle Length", int, p[\shuffleLength]);
    check.("Global Shuffle", flt, p[\globalShuffle]);
    check.("Auto Retrigger", bool, p[\autoRetrigger]);
    check.("Auto Trigger Rate", int, p[\autoTriggerRate]);
    ~tAssert.(which ++ ": every field equals rhythmic-steps.json's", bad.isEmpty, bad.asArray.asString);
    ~tEq.(which ++ ": all 20 step lists were compared", lanes.size, 20);
    ~tAssert.(which ++ ": every parameter in the file was read (Timing Page is Push's only)",
        (params.keys.asArray.reject { |k| used.includes(k) or: { k == "Timing Page" } }).isEmpty,
        params.keys.asArray.reject { |k| used.includes(k) }.asString);
    ~tEq.(which ++ ": and the pattern has no field the file lacks",
        p.keys.asArray.sort, [\altNote, \autoRetrigger, \autoTriggerRate, \clockSpeed, \delay, \globalLength,
            \globalShuffle, \lengths, \lock, \mute, \note, \rollRate, \shuffle, \shuffleLength, \steps]);
};
p1 = MegaSASteps.livePattern(\main);
p1[\steps][\chance][0].put(0, 0);
p1[\note].put(0, 51);
p2 = MegaSASteps.livePattern(\main);
~tEq.("each call answers a fresh copy", [p2[\steps][\chance][0][0], p2[\note][0]], [4, 42]);
~tCheck.("an unknown pattern warns rather than throws", { MegaSASteps.livePattern(\fill) });
~tAssert.("...and answers nil", MegaSASteps.livePattern(\fill).isNil);
}.value;

// ------------------------------------------ what the two devices play --
{
var st = MegaSASteps;
var m = st.livePattern(\main), b = st.livePattern(\break);
var same, c;
same = { |x, y|
    case
    { x.isKindOf(Dictionary) } {
        y.isKindOf(Dictionary) and: { x.keys.asArray.sort == y.keys.asArray.sort }
            and: { x.keys.asArray.every { |k| same.(x[k], y[k]) } }
    }
    { x.isKindOf(Array) } { y.isKindOf(Array) and: { x.size == y.size } and: { x.every { |e, i| same.(e, y[i]) } } }
    { x == y }
};
~tAssert.("the break plays only its first lane", (1..3).every { |l| b[\steps][\chance][l].every { |v| v == 0 } });
~tEq.("...on steps 1, 5, 9 and 13, always", b[\steps][\chance][0], [6, 0, 0, 0, 6, 0, 0, 0, 6, 0, 0, 0, 6, 0, 0, 0]);
~tEq.("...at 88, 88, 29, 88: a soft beat 3", [0, 4, 8, 12].collect { |i| st.velocity(b[\steps][\velo][0][i]) },
    [88, 88, 29, 88]);
~tEq.("...the pedal hat (its alternate, 44) with P 1/2 on steps 1 and 13, never on 5 and 9",
    [[0, 4, 8, 12].collect { |i| b[\steps][\alt][0][i] }, b[\altNote][0]], [[3, 0, 0, 3], 44]);
~tEq.("...and step 13 adds a 2-hit 1/16t roll at 61 and 43",
    [b[\steps][\roll][0][12], st.rollTicks[b[\rollRate]],
        st.rollVelocities(st.velocity(b[\steps][\velo][0][12]), b[\steps][\roll][0][12])], [2, 80, [61, 43]]);
c = m.deepCopy;
c[\steps].put(\chance, b[\steps][\chance].deepCopy);
~tAssert.("the two devices differ only in their chance steps", same.(c, b));
~tAssert.("...and do differ there", same.(m, b).not);
// The main device, as the survey of the set read it.
~tEq.("main lane 1's chances (k/6)", m[\steps][\chance][0], [4, 1, 3, 2, 6, 0, 0, 4, 0, 6, 0, 4, 0, 1, 3, 2]);
~tEq.("...its velocities", m[\steps][\velo][0].collect { |v| st.velocity(v) },
    [88, 88, 29, 10, 88, 29, 68, 10, 29, 29, 49, 49, 88, 127, 88, 127]);
~tEq.("...its rolls", m[\steps][\roll][0], [0, 2, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 2, 2, 1, 0]);
~tEq.("lane 2, the sidestick: 1/6 on steps 4, 5, 7, 9, 13, 15, 16",
    (0..15).select { |i| m[\steps][\chance][1][i] == 1 } + 1, [4, 5, 7, 9, 13, 15, 16]);
~tEq.("lane 3, the snare: 2/3 on step 5 only, alternate 40 with P 5/6",
    [(0..15).select { |i| m[\steps][\chance][2][i] > 0 } + 1, m[\steps][\chance][2][4], m[\steps][\alt][2][4],
        m[\altNote][2]], [[5], 4, 5, 40]);
~tEq.("lane 4, the kick: 2/3, 1/3, 1/3, 1/3 on steps 1, 5, 9, 13, never its alternate",
    [[0, 4, 8, 12].collect { |i| m[\steps][\chance][3][i] }, m[\steps][\alt][3].every { |v| v == 0 }],
    [[4, 2, 2, 2], true]);
~tEq.("lanes 3 and 4 always play 88", [2, 3].collect { |l| m[\steps][\velo][l].every { |v| st.velocity(v) == 88 } },
    [true, true]);
~tAssert.("Slide is 0 everywhere", [m, b].every { |p| p[\steps][\slide].every { |l| l.every { |v| v == 0 } } });
~tEq.("the notes the patterns play", [m[\note], m[\altNote]], [[42, 37, 38, 36], [44, 50, 40, 41]]);
}.value;

// ------------------------------------------------------------- a new one --
{
var st = MegaSASteps;
var n = st.newPattern;
~tEq.("a new device's pads", [n[\note], n[\altNote]], [[39, 42, 38, 36], [37, 46, 40, 41]]);
~tAssert.("its steps are 0, its velocity steps 4",
    st.subs.every { |sub| n[\steps][sub].every { |l| l.every { |v| v == (if(sub == \velo) { 4 } { 0 }) } } });
~tEq.("its timing at the device's own defaults",
    [n[\clockSpeed], n[\rollRate], n[\shuffleLength], n[\globalShuffle], n[\autoRetrigger], n[\autoTriggerRate]],
    [3, 7, 4, 100.0, false, 0]);
n[\lengths][\chance].put(0, 3);
~tEq.("every list is its own", n[\lengths][\velo][0], 16);
~tAssert.("it plays nothing", st.decideStep(st.newPattern, 0, { 0 }).every(_.isNil));
}.value;

// --------------------------------------------------------------- settings --
{
var st = MegaSASteps;
var m = st.livePattern(\main), b = st.livePattern(\break);
var p = st.livePattern(\main);
var warn = List.new, data, clean;
~tEq.("the pattern settings", st.paramSpecs.collect { |r| r[\name] },
    [\clockSpeed, \rollRate, \autoRetrigger, \autoTriggerRate, \shuffleLength, \globalShuffle]
        ++ (1..8).collect { |i| ("shuffle" ++ i).asSymbol });
~tAssert.("every row has a label, a spec and a tip",
    st.paramSpecs.every { |r| r[\label].notNil and: { r[\spec].isKindOf(ControlSpec) } and: { r[\tip].size > 20 } });
~tAssert.("every setting's default is the Live set's value",
    st.paramSpecs.every { |r| st.constrainParam(r[\name], r[\spec].default) == st.getParam(m, r[\name]) });
~tAssert.("...which both devices share", st.paramSpecs.every { |r| st.getParam(m, r[\name]) == st.getParam(b, r[\name]) });
~tEq.("menus carry the device's labels",
    [\clockSpeed, \rollRate, \autoTriggerRate].collect { |k| st.paramSpec(k)[\choices].collect { |c| c[1] } },
    [st.clockSpeedLabels, st.rollRateLabels, st.autoTriggerRateLabels].collect(_.asArray));
~tEq.("Shuffle 1 only goes forward, the others both ways",
    [st.paramSpec(\shuffle1)[\spec].minval, st.paramSpec(\shuffle1)[\centered] == true,
        st.paramSpec(\shuffle5)[\spec].minval, st.paramSpec(\shuffle5)[\centered]], [0, false, -50, true]);
~tEq.("lane settings", st.laneParamSpecs.collect { |r| r[\name] },
    [\note, \altNote, \delay, \mute, \lock, \globalLength, \length]);
~tEq.("...pads 36..51, delay 0..50 ms, lengths 2..16",
    [\note, \altNote, \delay, \globalLength, \length].collect { |k| var s = st.laneParamSpec(k)[\spec]; [s.minval, s.maxval] },
    [[36, 51], [36, 51], [0, 50], [2, 16], [2, 16]]);
~tAssert.("...each with the set's four lane values",
    [\note, \altNote, \delay, \mute, \lock, \globalLength].every { |k| st.laneParamSpec(k)[\live] == m[k] });
~tEq.("values are held to their rows",
    [st.constrainParam(\clockSpeed, 9), st.constrainParam(\rollRate, 2.6), st.constrainParam(\globalShuffle, 50),
        st.constrainParam(\shuffle2, -60), st.constrainParam(\shuffle1, -10), st.constrainParam(\shuffleLength, 1)],
    [5, 3, 50.0, -50.0, 0.0, 2]);
~tEq.("...switches are Booleans", [st.constrainParam(\autoRetrigger, 0), st.constrainParam(\autoRetrigger, true),
    st.constrainLaneParam(\mute, 1)], [false, true, true]);
~tEq.("...lane values: a 20 ms delay (mid), a pad held to 51, a length held to 2",
    [st.constrainLaneParam(\delay, 20), st.constrainLaneParam(\note, 60), st.constrainLaneParam(\length, 1)],
    [20.0, 51, 2]);
~tEq.("...and anything else is refused", [st.constrainParam(\clockSpeed, "fast"), st.constrainParam(\autoRetrigger, "on"),
    st.constrainParam(\clockSpeed, 0/0), st.constrainParam(\nope, 1), st.constrainStep(\x)], [nil, nil, nil, nil, nil]);
~tEq.("a step value is 0..6", [st.constrainStep(9), st.constrainStep(-2), st.constrainStep(3.4)], [6, 0, 3]);
~tEq.("putParam stores and answers what it stored", [st.putParam(p, \shuffle3, 12.5), p[\shuffle][2],
    st.putParam(p, \clockSpeed, 1), p[\clockSpeed]], [12.5, 12.5, 1, 1]);
~tEq.("...and getParam reads it back", [st.getParam(p, \shuffle3), st.getParam(p, \clockSpeed)], [12.5, 1]);
~tEq.("puts refuse what is not there", [st.putParam(p, \nope, 1), st.putLaneParam(p, 4, \note, 40),
    st.putLength(p, \wobble, 0, 8), st.putStep(p, \chance, 0, 16, 3), st.putStep(p, \chance, 0, 1, "x")],
    [nil, nil, nil, nil, nil]);
~tEq.("...and change nothing when they do", [p[\note], p[\steps][\chance][0][1]], [[42, 37, 38, 36], 1]);
// cleanPattern: a preset read back, fail-soft by field.
data = st.livePattern(\main);
data[\steps][\chance][0].put(3, 9);
data[\note].put(1, "snare");
data.put(\clockSpeed, 4);
data[\shuffle].put(2, 10.5);
data.put(\bogus, 1);
data.removeAt(\rollRate);
clean = st.cleanPattern(data, \main, warn);
~tEq.("a preset's setting in range goes in", clean[\clockSpeed], 4);
~tNear.("...a shuffle dial too", clean[\shuffle][2], 10.5);
~tEq.("a step out of range is held to 6", clean[\steps][\chance][0][3], 6);
~tEq.("a pad that is no number keeps the Live set's", clean[\note][1], 37);
~tEq.("a setting the file lacks takes the Live set's", clean[\rollRate], 5);
~tEq.("the corrections are reported: the range, the pad, the stray key", warn.size, 3);
~tAssert.("...naming each", warn.any { |w| w.contains("steps chance") } and: { warn.any { |w| w.contains("note[1]") } }
    and: { warn.any { |w| w.contains("bogus") } }, warn.asArray.asString);
~tEq.("the data is not touched", data[\steps][\chance][0][3], 9);
warn = List.new;
clean = st.cleanPattern(42, \break, warn);
~tAssert.("not an Event: the Live set's pattern, and a warning",
    (clean[\steps][\chance][0][0] == 6) and: { warn.size == 1 }, warn.asArray.asString);
}.value;

// --------------------------------------------------------------------- kits --
{
var tmp = ~tTempPath.("megadrums-test");
var warn = List.new, kit, ev, path, layer, hat, kick, k2, stub, cache, reads, states, seen, ctl, never;
var writeWav = { |p, chans, rate, frames|
    var sf = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(chans).sampleRate_(rate);
    sf.openWrite(p);
    sf.writeData(Signal.fill(frames * chans, { 0.1 }));
    sf.close;
};
var text = "{ \"version\": 1, \"key\": \"t-kit\", \"name\": \"Test Kit\", \"description\": \"one line\",
  \"source\": \"~/nowhere\", \"notes\": [\"made by hand\", \"for the test\"],
  \"groups\": { \"carbon\": \"Kit-Carbon\", \"layer\": \"The layer\" },
  \"pads\": {
    \"42\": { \"name\": \"Hat\", \"choke\": 1, \"retrigger\": false, \"pan\": -0.25, \"gainDb\": -3.5,
              \"fit\": { \"db\": -10.1, \"r2\": 0.996 }, \"beatRepeat\": true, \"repeatFilter\": false,
              \"layers\": [ { \"group\": \"carbon\", \"file\": \"carbon/hat.wav\", \"gainDb\": -10.1, \"transpose\": 2.0,
                              \"velLo\": 1, \"velHi\": 127, \"startFrames\": 0, \"lenSecs\": 0.05, \"drive\": 0.0,
                              \"vel\": { \"law\": \"operator\", \"amount\": 0.62 } },
                            { \"group\": \"layer\", \"file\": \"carbon/kick.wav\", \"gainDb\": -19, \"velLo\": 64,
                              \"velHi\": 127, \"vel\": { \"law\": \"simpler\", \"amount\": 0.25 } } ] },
    \"36\": { \"name\": \"Kick\", \"pan\": \"left\", \"choke\": 0.5, \"retrigger\": \"yes\", \"extra\": 1,
              \"layers\": [ { \"file\": \"carbon/kick.wav\", \"velLo\": 200, \"vel\": { \"law\": \"weird\" } } ] },
    \"38\": { \"name\": \"Empty\", \"layers\": [ { \"gainDb\": 1 } ] },
    \"x\": { \"layers\": [] },
    \"99\": { \"layers\": [ { \"file\": \"carbon/fake.aif\" } ] } } }";
File.mkdir(tmp);
File.mkdir(tmp +/+ "carbon");
writeWav.(tmp +/+ "carbon" +/+ "hat.wav", 1, 44100, 4410);
writeWav.(tmp +/+ "carbon" +/+ "kick.wav", 2, 48000, 9600);
File.use(tmp +/+ "carbon" +/+ "fake.aif", "w", { |f| f.write("FORM not audio") });
path = tmp +/+ "t-kit.json";
File.use(path, "w", { |f| f.write(text) });

kit = ~tCheck.("a kit file is read", { MegaSAKit.read(path, warn) });
~tAssert.("...into a kit", kit.isKindOf(MegaSAKit));
kit !? {
    hat = kit.pad(42)[\layers][0];
    kick = kit.pad(42)[\layers][1];
    ~tEq.("its key, name and description", [kit.key, kit.name, kit.description, kit.version],
        ['t-kit', "Test Kit", "one line", 1]);
    ~tEq.("the exporter's notes, as remarks", kit.remarks, ["made by hand", "for the test"]);
    ~tAssert.("...which are no stray key", warn.every { |w| w.contains("notes").not }, warn.asArray.asString);
    ~tEq.("the pads that hold a playable layer, by note", kit.notes, [36, 42, 99]);
    ~tEq.("numbers come in as numbers, from parseJSON's Strings",
        [kit.pad(42)[\choke], kit.pad(42)[\pan], kit.pad(42)[\gainDb], hat[\gainDb], hat[\transpose], hat[\lenSecs],
            kick[\gainDb], kick[\velLo]], [1, -0.25, -3.5, -10.1, 2.0, 0.05, -19.0, 64]);
    ~tEq.("switches as Booleans", [kit.pad(42)[\beatRepeat], kit.pad(42)[\repeatFilter], kit.pad(42)[\retrigger]],
        [true, false, false]);
    ~tEq.("the velocity laws as Symbols", [hat[\vel][\law], hat[\vel][\amount], kick[\vel][\law], kick[\vel][\amount]],
        [\operator, 0.62, \simpler, 0.25]);
    ~tEq.("the fit as read", [kit.pad(42)[\fit][\db], kit.pad(42)[\fit][\r2]], [-10.1, 0.996]);
    ~tEq.("groups by key, with their names", [kit.groupKeys, kit.groupName(\carbon)], [[\carbon, \layer, \main], "Kit-Carbon"]);
    ~tEq.("a layer with no group in a two-group kit goes to \\main", kit.pad(36)[\layers][0][\group], \main);
    ~tEq.("pad names", [kit.padName(42), kit.padName(99), kit.padName(50)], ["Hat", "Pad 99", nil]);
    ~tEq.("bad fields take their defaults", [kit.pad(36)[\pan], kit.pad(36)[\choke], kit.pad(36)[\retrigger],
        kit.pad(36)[\layers][0][\vel][\law]], [0.0, 0, false, \none]);
    ~tEq.("...ranges are held", kit.pad(36)[\layers][0][\velLo], 127);
    ~tAssert.("...and each says so", ["pad 36: pan", "pad 36: choke", "pad 36: retrigger", "velLo 200",
        "vel law", "pad 38: layer 0: no file", "pad 38: no playable layer", "pad x is not a note",
        "ignored: pad 36: extra"].every { |s| warn.any { |w| w.contains(s) } }, warn.asArray.asString);
    ~tEq.("the kit keeps its corrections", kit.warnings.size, warn.size);
    ~tAssert.("Beat Repeat: this kit has it", kit.hasRepeats);
    ~tEq.("every layer that sounds at velocity 100 (layering)", kit.layersFor(42, 100).size, 2);
    ~tEq.("...at 10 only the one whose range holds it", kit.layersFor(42, 10), [hat]);
    ~tEq.("...and on a note with no pad, none", kit.layersFor(50, 100), []);
    ~tEq.("the distinct files, in note order", kit.files, ["carbon/kick.wav", "carbon/hat.wav", "carbon/fake.aif"]);
    ~tEq.("...absolute given the kits folder", kit.files(tmp).first, (tmp +/+ "carbon/kick.wav").standardizePath);
    ~tEq.("a file starting with ~ or / is used as it stands",
        [MegaSAKit.absolutePath(tmp, "~/x.wav"), MegaSAKit.absolutePath(tmp, "/a/b.wav")],
        ["~/x.wav".standardizePath, "/a/b.wav"]);
};
~tEq.("the kits in a folder, by file name", MegaSAKit.keysIn(tmp), ['t-kit']);
~tAssert.("...and where one is", File.exists(MegaSAKit.fileFor(tmp, 't-kit'))
    and: { PathName(MegaSAKit.fileFor(tmp, 't-kit')).fileName == "t-kit.json" });

// The arithmetic, at mid values.
~tNear.("Simpler's Vel > Vol at 0.5, velocity 96: +5.79 dB", MegaSAKit.velDb(\simpler, 0.5, 96), 5.79047619047619, 1e-9);
~tEq.("...0 dB at the pivot, 64", MegaSAKit.velDb(\simpler, 0.5, 64), 0.0);
~tNear.("...+5.7 dB at 127 for the KJ layer's 0.25", MegaSAKit.velDb(\simpler, 0.25, 127), 5.7, 1e-9);
~tNear.("...-11.4 dB at 1 for 0.5", MegaSAKit.velDb(\simpler, 0.5, 1), -11.4, 1e-9);
~tEq.("...and no amplitude factor", MegaSAKit.velAmp(\simpler, 0.5, 96), 1);
~tNear.("Operator's placeholder at 0.5, velocity 64: 0.752", MegaSAKit.velAmp(\operator, 0.5, 64), 0.7519685039370079, 1e-12);
~tNear.("...1 at 127, 0.43 at 10 for the hats' 0.62",
    MegaSAKit.velAmp(\operator, 0.62, 127) + MegaSAKit.velAmp(\operator, 0.62, 10), 1.4288188976377953, 1e-12);
~tEq.("...and no dB", MegaSAKit.velDb(\operator, 0.62, 10), 0);
~tEq.("\\none: no response", [MegaSAKit.velDb(\none, 0.5, 10), MegaSAKit.velAmp(\none, 0.5, 10)], [0, 1]);
~tNear.("a law given as a String works the same", MegaSAKit.velDb("simpler", 0.5, 96), 5.79047619047619, 1e-9);
// The curve: a(v) ** p * a(88) ** (1 - p), a(v) = velDb.dbamp * velAmp, so
// p bends the slope about velocity 88 and leaves the level there. Golden at
// 10, 49, 88 and 127, for the hats' Operator 0.62 and the KJ layer's Simpler
// 0.25, at p = 1 (the law itself) and p = 2.4 (the hats' fitted slope).
~tEqArray.("velFactor, Operator 0.62, curve 1: the law itself", [10, 49, 88, 127].collect { |v|
    MegaSAKit.velFactor(\operator, 0.62, 1, v) }, [0.4288188976377953, 0.6192125984251968, 0.8096062992125984, 1.0], 1e-12);
~tEqArray.("...curve 2.4: steeper, the same at 88", [10, 49, 88, 127].collect { |v|
    MegaSAKit.velFactor(\operator, 0.62, 2.4, v) },
    [0.17614647982670575, 0.42543385914292176, 0.8096062992125984, 1.3440535428852647], 1e-12);
~tEqArray.("velFactor, Simpler 0.25, curve 1", [10, 49, 88, 127].collect { |v| MegaSAKit.velFactor(\simpler, 0.25, 1, v) },
    [0.5697892951384084, 0.8553480254163789, 1.2840189361682888, 1.9275249131909362], 1e-12);
~tEqArray.("...curve 2.4", [10, 49, 88, 127].collect { |v| MegaSAKit.velFactor(\simpler, 0.25, 2.4, v) },
    [0.18268979384338702, 0.4843316577920443, 1.2840189361682888, 3.40408189701001], 1e-12);
~tEqArray.("...no curve given is curve 1", [10, 127].collect { |v| MegaSAKit.velFactor(\operator, 0.62, nil, v) },
    [0.4288188976377953, 1.0], 1e-12);
~tNear.("ampFor takes a layer's curve: the gains in dB times velFactor",
    MegaSAKit.ampFor((gainDb: -10.1, vel: (law: \operator, amount: 0.62, curve: 2.4)), (gainDb: 0), 10, 1.5, -2),
    (-10.6).dbamp * 0.17614647982670575, 1e-12);
{
    var w = List.new;
    var k = MegaSAKit.fromData((key: "curved", pads: (
        42: (layers: [(file: "h.wav", vel: (law: "operator", amount: 0.62, curve: 2.4))]),
        44: (layers: [(file: "p.wav", vel: (law: "operator", amount: 0.37, curve: 9))]),
        46: (layers: [(file: "o.wav", vel: (law: "operator", amount: 0.37, curve: "steep"))]),
        36: (layers: [(file: "k.wav", vel: (law: "simpler", amount: 0.25))]))), w);
    ~tEq.("a kit's layer reads its curve", k.pad(42)[\layers][0][\vel][\curve], 2.4);
    ~tEq.("...held to 0.25..6, one that is no number back to 1, none given 1",
        [44, 46, 36].collect { |n| k.pad(n)[\layers][0][\vel][\curve] }, [6, 1.0, 1.0]);
    ~tAssert.("...each correction said", ["vel curve 9", "vel curve \"steep\""].every { |x| w.any { |line| line.contains(x) } }
        and: { w.every { |line| line.contains("ignored").not } }, w.asArray);
}.value;
kit !? {
    ~tNear.("ampFor: (layer + pad + group trim + pad trim + vel) dB, times the law's factor",
        kit.ampFor(hat, kit.pad(42), 64, -2, 1.5), 0.1365786263101892, 1e-12);
    ~tNear.("...Simpler's law at velocity 96, no trims", MegaSAKit.ampFor(kick, kit.pad(42), 96), 0.10465546333411165, 1e-12);
    ~tNear.("the rate is the transpose alone (+2 st), never BufRateScale", kit.rateFor(hat), 1.122462048309373, 1e-12);
    ~tEq.("...an octave down is half, none is 1", [MegaSAKit.rateFor((transpose: -12)), MegaSAKit.rateFor(())], [0.5, 1]);
    ~tNear.("a layer's duration is lenSecs at its rate", kit.durFor(hat), 0.04454493590701697, 1e-12);
    ~tEq.("...0 (to the end) without one", kit.durFor(kick), 0);
};
~tEq.("load states", [MegaSAKit.loadState(5, 0, 0), MegaSAKit.loadState(5, 2, 0), MegaSAKit.loadState(5, 5, 0),
    MegaSAKit.loadState(5, 2, 3), MegaSAKit.loadState(5, 0, 5), MegaSAKit.loadState(0, 0, 0), MegaSAKit.loadState(5, 1, 1)],
    [\ready, \partial, \missing, \failed, \failed, \missing, \partial]);

// Loading, with a reader standing in for Buffer.read.
kit !? {
    stub = ~tStubServer.();
    cache = IdentityDictionary.new;
    reads = List.new;
    states = List.new;
    seen = List.new;
    ctl = SimpleController(kit).put(\state, { |k, what, st| seen.add(st) });
    ~tCheck.("a kit loads", { kit.load(stub, tmp, cache, { |k, st| states.add(st) },
        { |srv, p, done| reads.add(p); done.((path: p)) }) });
    ~tEq.("the files that exist were read, each once", reads.collect { |p| PathName(p).fileName }.asArray,
        ["kick.wav", "hat.wav"]);
    ~tEq.("the one that cannot be read is missing", kit.missing.collect { |p| PathName(p).fileName }.asArray, ["fake.aif"]);
    ~tEq.("the action hears \\loading, then the state", states.asArray, [\loading, \partial]);
    ~tEq.("...and so do the kit's dependants", seen.asArray, [\loading, \partial]);
    ~tEq.("the kit is partial and playable", [kit.state, kit.isPlayable], [\partial, true]);
    ~tEq.("every buffer went into the caller's cache", cache.size, 2);
    ~tEq.("a layer finds its buffer", kit.bufferFor(hat)[\path], (tmp +/+ "carbon/hat.wav").standardizePath);
    ~tEq.("the files' headers: mono at 44.1 kHz, 4410 frames",
        [kit.infoFor(hat)[\numChannels], kit.infoFor(hat)[\sampleRate], kit.infoFor(hat)[\numFrames]], [1, 44100, 4410]);
    ~tEq.("...which voice: mono or stereo", [kit.channelsFor(hat), kit.channelsFor(kick)], [1, 2]);
    ~tNear.("how long a voice rings: lenSecs at its rate", kit.soundingDur(hat), 0.05 / (2 ** (2 / 12)), 1e-12);
    ~tNear.("...or the rest of the file", kit.soundingDur(kick), 0.2, 1e-9);
    ~tEq.("a missing file's layer has no buffer", kit.bufferFor(kit.pad(99)[\layers][0]), nil);
    reads = List.new;
    states = List.new;
    kit.load(stub, tmp, cache, { |k, st| states.add(st) }, { |srv, p, done| reads.add(p); done.((path: p)) });
    ~tEq.("loaded again, the cache serves it: nothing is read", reads.size, 0);
    ~tEq.("...and it settles the same", states.asArray, [\loading, \partial]);
    ctl.remove;
    k2 = MegaSAKit.fromData((key: "solo", pads: (36: (layers: [(file: "carbon/kick.wav")]))), List.new);
    ~tEq.("data in hand (an Event, real values) makes a kit too", [k2.key, k2.notes, k2.groupKeys], [\solo, [36], [\main]]);
    states = List.new;
    k2.load(stub, tmp, nil, { |k, st| states.add(st) }, { |srv, p, done| done.(nil) });
    ~tEq.("a server that will not read the file: failed", [states.asArray, k2.failed.size], [[\loading, \failed], 1]);
    states = List.new;
    k2.load(stub, tmp, IdentityDictionary.new, { |k, st| states.add(st) }, { |srv, p, done| done.((path: p)) });
    ~tEq.("every file in: ready", states.asArray, [\loading, \ready]);
    states = List.new;
    never = MegaSAKit.fromData((key: "never", pads: (36: (layers: [(file: "carbon/hat.wav")]))), List.new);
    never.load(stub, tmp, IdentityDictionary.new, { |k, st| states.add(st) }, { |srv, p, done| });
    ~tEq.("a read that never answers leaves it loading", [states.asArray, never.state], [[\loading], \loading]);
    never.instVarAt(\syncRoutine) !? { |r| r.next };
    ~tEq.("...until one sync settles it: failed", [states.asArray, never.state], [[\loading, \failed], \failed]);
    // Two loads sharing a file, one table of reads in flight: the second waits
    // for the first's read rather than reading the file again, and both kits
    // get the one buffer. A read that never answers is let go of at the first
    // load's sync, and the load waiting for it hears that it failed.
    {
        var inFlight = IdentityDictionary.new, pend = List.new, c2 = IdentityDictionary.new, sa = List.new, sb = List.new;
        var ka = MegaSAKit.fromData((key: "sa", pads: (36: (layers: [(file: "carbon/hat.wav")]))), List.new);
        var kb = MegaSAKit.fromData((key: "sb", pads: (36: (layers: [(file: "carbon/hat.wav")]),
            38: (layers: [(file: "carbon/kick.wav")]))), List.new);
        var hatPath = (tmp +/+ "carbon/hat.wav").standardizePath;
        ka.load(stub, tmp, c2, { |k, st| sa.add(st) }, { |srv, p, done| pend.add([p, done]) }, inFlight);
        kb.load(stub, tmp, c2, { |k, st| sb.add(st) }, { |srv, p, done| pend.add([p, done]) }, inFlight);
        ~tEq.("loads sharing a file with reads in flight: it is read once", pend.collect { |r| PathName(r[0]).fileName }.asArray,
            ["hat.wav", "kick.wav"]);
        pend.do { |r| r[1].value((path: r[0], bufnum: pend.indexOf(r))) };
        ~tEq.("...and both kits play the one buffer, ready", [ka.bufferFor(ka.pad(36)[\layers][0]) === kb.bufferFor(kb.pad(36)[\layers][0]),
            c2.size, sa.last, sb.last, inFlight.size], [true, 2, \ready, \ready, 0]);
        pend = List.new;
        sa = List.new;
        sb = List.new;
        ka.load(stub, tmp, IdentityDictionary.new, { |k, st| sa.add(st) }, { |srv, p, done| pend.add([p, done]) }, inFlight);
        kb.load(stub, tmp, IdentityDictionary.new, { |k, st| sb.add(st) }, { |srv, p, done| pend.add([p, done]) }, inFlight);
        ~tEq.("a read that never answers: waited for, not sent twice", [pend.size, inFlight.includesKey(hatPath.asSymbol)], [2, true]);
        ka.instVarAt(\syncRoutine) !? { |r| r.next };
        ~tEq.("...let go of at its load's sync", [sa.last, inFlight.includesKey(hatPath.asSymbol)], [\failed, false]);
        pend.do { |r| if(PathName(r[0]).fileName == "kick.wav") { r[1].value((path: r[0], bufnum: 9)) } };
        ~tEq.("...the load that waited for it hearing it failed, and settling with what it has",
            [sb.last, kb.failed.collect { |p| PathName(p).fileName }.asArray], [\partial, ["hat.wav"]]);
    }.value;
};

// Refusals.
warn = List.new;
~tAssert.("a missing kit file: nil", MegaSAKit.read(tmp +/+ "nope.json", warn).isNil and: { warn.size == 1 });
File.use(tmp +/+ "bad.json", "w", { |f| f.write("{ this is not json") });
warn = List.new;
~tAssert.("a file that is not JSON: nil, and a reason",
    ~tCheck.("...without a throw", { MegaSAKit.read(tmp +/+ "bad.json", warn) }).isNil and: { warn.size >= 1 },
    warn.asArray.asString);
warn = List.new;
~tAssert.("a newer version: nil", MegaSAKit.fromData((version: 2, key: "v2",
    pads: (36: (layers: [(file: "a.wav")]))), warn).isNil and: { warn.any { |w| w.contains("newer") } });
warn = List.new;
~tAssert.("no playable pad: nil", MegaSAKit.fromData((key: "empty", pads: (36: (layers: []))), warn).isNil
    and: { warn.any { |w| w.contains("no playable pad") } }, warn.asArray.asString);
warn = List.new;
~tAssert.("not an object: nil", MegaSAKit.fromData([1, 2], warn).isNil and: { warn.size == 1 });
File.use(tmp +/+ "other.json", "w", { |f| f.write("{ \"version\": 1, \"key\": \"elsewhere\", \"pads\": { \"36\": { \"layers\": [ { \"file\": \"a.wav\" } ] } } }") });
warn = List.new;
~tEq.("a key that is not its file's name: the file's wins", MegaSAKit.read(tmp +/+ "other.json", warn).key, \other);
~tAssert.("...and says so", warn.any { |w| w.contains("elsewhere") });
~tCheck.("with no list given the warnings are posted, not thrown",
    { MegaSAKit.fromData((key: "loud", pads: (36: (pan: 9, layers: [(file: "a.wav")])))) });

(tmp +/+ "carbon" +/+ "*").pathMatch.do { |p| File.delete(p) };
File.delete(tmp +/+ "carbon");
(tmp +/+ "*").pathMatch.do { |p| File.delete(p) };
File.delete(tmp);
}.value;

// ------------------------------------------------------- the transport port --
{
var fake = (alive: true, lead: 0.1, looper: (abletonSyncMs: 30), log: List.new);
var t, now, l, sink;
fake[\transportStart] = { |self, at| self[\log].add([\start, at]); self };
fake[\transportStop] = { |self, at| self[\log].add([\stop, at]); self };
fake[\onsetNoteOn] = { |self, note, vel, at| self[\log].add([\note, note, vel, at]); self };
t = MegaSATransport(fake);
~tNear.("latency: the drums' lead plus the Live sync trim", t.latency, 0.13, 1e-12);
fake[\looper] = (abletonSyncMs: -20);
~tNear.("...a negative trim too", t.latency, 0.08, 1e-12);
fake[\looper] = nil;
~tNear.("...no looper: the lead alone", t.latency, 0.1, 1e-12);
now = thisThread.seconds;
t.start;
~tEq.("start reaches the drums", fake[\log].last[0], \start);
~tNear.("...with the caller's time", fake[\log].last[1], now, 0.01);
t.stop;
~tEq.("stop likewise", fake[\log].last[0], \stop);
t.noteOn(1, 36, 100);
~tEq.("a note on goes to the onset kit", fake[\log].last.copyRange(0, 2), [\note, 36, 100]);
~tNear.("...lead from now", fake[\log].last[3], now + 0.1, 0.01);
fake[\log] = List.new;
~tCheck.("everything else a MIDI port answers is a no-op", {
    t.noteOn(1, 36, 0); t.noteOff(1, 36, 0); t.midiClock; t.control(15, 100, 0); t.program(0, 17);
    t.bend(0, 8192); t.touch(0, 10); t.polyTouch(0, 36, 10); t.allNotesOff(0); t.continue; t.reset;
    t.songPtr(0); t.songSelect(0); t.smpte; t.sysex(Int8Array[]);
});
~tEq.("...a note at velocity 0 included (a note-off)", fake[\log].size, 0);
fake[\alive] = false;
t.start; t.stop; t.noteOn(1, 36, 100);
~tEq.("once the drums are freed every call is a no-op", fake[\log].size, 0);
~tEq.("...and latency is 0", t.latency, 0);
~tCheck.("with no drums at all, too", { var n = MegaSATransport(nil); n.start; n.stop; n.noteOn(1, 36, 9); n.latency });
// The Looper's own stop reaches the drums through it, and its sink.
fake[\alive] = true;
l = ~tLooper.();
sink = (log: List.new);
sink[\startOnsets] = { |self, looper, pattern, period| self[\log].add(\start); self };
sink[\stopOnsets] = { |self, looper| self[\log].add(\stop); self };
~tPut.(l, \midiOut, t);
l.onsetNoteSink = sink;
~tCheck.("a looper stops with the port and sink in place", { l.stopPlayback });
~tEq.("stopPlayback in \\full sends the drums a Stop", fake[\log].collect(_[0]).asArray, [\stop]);
~tEq.("...and stops the sink's onset part", sink[\log].asArray, [\stop]);
}.value;

// ------------------------------------------------------- the Looper's hooks --
{
var l = ~tLooper.();
var midi = (log: List.new, latency: 0);
var sink = (log: List.new);
var syn, step;
midi[\noteOn] = { |self, ch, note, vel| self[\log].add([\on, ch, note, vel]); self };
midi[\noteOff] = { |self, ch, note, vel| self[\log].add([\off, ch, note, vel]); self };
sink[\startOnsets] = { |self, looper, pattern, period| self[\log].add([\start, looper, pattern, period]); self };
sink[\stopOnsets] = { |self, looper| self[\log].add([\stop, looper]); self };
// Walk the MIDI routine to its next noteOn (it waits 0 before the first one).
step = { 4.do { if(midi[\log].isEmpty) { ~tGet.(l, \onsetNoteRoutine) !? { |r| r.next } } } };
syn = ~tStubSynth.(l, \looperEngineMono);
~tPut.(l, \midiOut, midi);
~tPut.(l, \engineSynth, syn);
~tPut.(l, \loopStartTime, SystemClock.seconds);
~tPut.(l, \onsetNotePattern, [[0.0, 1.0], [0.5, 0.5]]);
~tPut.(l, \onsetNotePatternDur, 1.0);
~tPut.(l, \onsetNotes, true);
~tEq.("the loop's anchor is readable", l.loopStartTime, ~tGet.(l, \loopStartTime));
~tPut.(l, \phaseBus, Bus(\control, 7, 1, ~tGet.(l, \server)));
~tEq.("...and its phase bus", l.phaseBus.index, 7);
~tEq.("onsetPlays is prOnsetPlays", [l.onsetPlays(0), l.onsetPlays(1)], [l.prOnsetPlays(0), l.prOnsetPlays(1)]);
~tEq.("onsetVelocity is prOnsetVelocity: 0.5 of the loudest is 110, 0.1 is 69",
    [l.onsetVelocity(0.5), l.onsetVelocity(0.1)], [110, 69]);
~tEq.("no sink by default (every Live profile)", l.onsetNoteSink, nil);

// No sink: the MIDI routine, exactly as before.
l.startOnsetNotes;
~tAssert.("with no sink the MIDI routine starts, as before", ~tGet.(l, \onsetNoteRoutine).notNil);
step.();
~tEq.("...and its first hit goes out as a MIDI note", midi[\log].first, [\on, 1, 36, 127]);
l.stopOnsetNotes;
~tEq.("stopping mid-gate still releases the note", midi[\log].last, [\off, 1, 36, 0]);
~tAssert.("...and leaves no routine", ~tGet.(l, \onsetNoteRoutine).isNil);

// A sink: it gets the part, and no MIDI goes anywhere.
l.startOnsetNotes;
~tAssert.("(a MIDI routine running before the sink is attached)", ~tGet.(l, \onsetNoteRoutine).notNil);
midi[\log] = List.new;
l.onsetNoteSink = sink;
l.startOnsetNotes;
~tEq.("a sink is handed the part: the looper, the pattern and its period",
    sink[\log].collect { |e| [e[0], e[1] === l, e[2], e[3]] }.asArray, [[\start, true, [[0.0, 1.0], [0.5, 0.5]], 1.0]]);
~tAssert.("...and is not told to stop first (each restart would cut its part)",
    sink[\log].every { |e| e[0] != \stop });
~tAssert.("the MIDI routine is stopped, so the part never plays twice", ~tGet.(l, \onsetNoteRoutine).isNil);
~tEq.("...and no MIDI note goes out", midi[\log].select { |e| e[0] == \on }.size, 0);
sink[\log] = List.new;
~tPut.(l, \midiOut, nil);
l.startOnsetNotes;
~tEq.("a sink needs no MIDI port", sink[\log].collect(_[0]).asArray, [\start]);
~tPut.(l, \midiOut, midi);
// The guard, minus the port: anything off tells the sink to stop.
[[\onsetNotes, false], [\engineSynth, nil], [\onsetNotePattern, []], [\onsetNotePatternDur, nil],
    [\onsetNotePatternDur, 0]].do { |change|
    var was = ~tGet.(l, change[0]);
    sink[\log] = List.new;
    ~tPut.(l, change[0], change[1]);
    l.startOnsetNotes;
    ~tEq.("with " ++ change[0] ++ " " ++ change[1].asCompileString ++ " the sink is told to stop",
        sink[\log].collect { |e| [e[0], e[1] === l] }.asArray, [[\stop, true]]);
    ~tPut.(l, change[0], was);
};
sink[\log] = List.new;
l.stopOnsetNotes;
~tEq.("stopOnsetNotes stops the sink's part", sink[\log].collect(_[0]).asArray, [\stop]);
sink[\log] = List.new;
l.onsetNotes = false;
~tEq.("so does switching onset notes off (PC 16)", sink[\log].collect(_[0]).asArray, [\stop]);
sink[\log] = List.new;
l.onsetNotes = true;
~tEq.("...and on again starts it", sink[\log].collect(_[0]).asArray, [\start]);
sink[\log] = List.new;
l.onsetNoteOffsetMs = 7;
~tEq.("a new offset hands the part over again, without a stop", sink[\log].collect(_[0]).asArray, [\start]);
l.onsetNoteSink = nil;
l.stopOnsetNotes;
}.value;

// ------------------------------------------------- startsRelocate (Live off) --
// Copied from test-session-recorder.scd's transport guard and test-reading.scd's
// landing: in Live a Start mid-recording would overwrite the arrangement take,
// so the Looper keeps it to itself; on SA (startsRelocate false) it goes out.
{
var l = ~tLooper.();
var result = (numerator: 4, denominator: 4, tau: 0.5, sub: 1, k: 1, bpm: 120, loopDur: 2.0, downbeatOffset: 0);
var sentinel;
l.metronome = false;
~tEq.("a Start relocates by default, on every Live profile", l.startsRelocate, true);
~tPut.(l, \midiOut, ());
~tPut.(l, \midiClockRoutine, Routine {});
sentinel = ~tGet.(l, \midiClockRoutine);
l.sessionRec.instVarPut(\recording, true);
l.startTempoClocks(result);
~tAssert.("by default a later analysis keeps its Start to itself mid-recording",
    ~tGet.(l, \midiClockRoutine) === sentinel);
l.startsRelocate = false;
l.startTempoClocks(result);
~tAssert.("with startsRelocate false it restarts the transport while a session recording runs",
    ~tGet.(l, \midiClockRoutine) !== sentinel);
l.sessionRec.instVarPut(\recording, false);
~tGet.(l, \midiClockRoutine) !? { |r| r.stop };
}.value;
{
var l = ~tLooper.();
var midi = (log: List.new, latency: 0);
var result = (numerator: 3, denominator: 4, tau: 0.25, sub: 2, k: 1, bpm: 120, loopDur: 3.0, downbeatOffset: 0);
var land;
midi[\start] = { |self| self[\log].add(\start); self };
midi[\midiClock] = { |self| self };
~tPut.(l, \state, \playing);
~tPut.(l, \loopFrames, (3.0 * 48000).asInteger);
~tPut.(l, \loopStartTime, SystemClock.seconds);
~tPut.(l, \lastResult, result);
~tPut.(l, \midiOut, midi);
~tPut.(l, \midiClockRoutine, Routine { 1.wait });
~tPut.(l, \clockTicksAtRef, 0);
~tPut.(l, \clockRefTime, SystemClock.seconds - 3.0);
~tPut.(l, \clockTickRate, 48);
~tPut.(l, \clockPeriod, 1 / 48);
// A landing whose boundary has passed, driven through a routine as the real
// one runs inside readingRoutine (see prStopRoutine).
land = { |relocate|
    var r;
    ~tPut.(l, \pendingReading, (index: 1, result: result, at: SystemClock.seconds - 0.01, loops: 1, restart: true));
    l.startsRelocate = relocate;
    r = Routine { l.prLandReading(~tGet.(l, \readingSeq)) };
    ~tPut.(l, \readingRoutine, r);
    r.next;
};
l.sessionRec.instVarPut(\recording, true);
land.(true);
~tEq.("by default a landing that needs a Start keeps it to itself mid-recording", midi[\log].size, 0);
~tAssert.("...and still lands", l.pendingReading.isNil and: { l.readingIndex == 1 });
land.(false);
~tEq.("with startsRelocate false it sends the Start", midi[\log].asArray, [\start]);
~tNear.("...and counts Live's ticks from that boundary", ~tGet.(l, \clockTicksAtRef), 0, 1e-9);
l.sessionRec.instVarPut(\recording, false);
}.value;

// --------------------------------------------------------- the stub server --
{
var stub = ~tStubServer.();
var r, b;
r = Routine { stub.sendBundle(0.25, [\s_new, \x, -1, 1, 1], [\n_set, 5, \amp, 1]) };
r.next;
~tEq.("the stub records a bundle: its messages", stub[\bundles].last[1], [[\s_new, \x, -1, 1, 1], [\n_set, 5, \amp, 1]]);
~tNear.("...at the sender's logical time plus its delta", stub[\bundles].last[0], thisThread.seconds + 0.25, 0.01);
b = Bus.control(stub, 2);
b.set(0.5, 0.25);
~tEq.("Bus works on it: distinct indices, and a set lands as a bundle now",
    [Bus.control(stub, 1).index != b.index, stub[\bundles].last[1]], [true, [["/c_set", b.index, 0.5, b.index + 1, 0.25]]]);
~tEq.("its latency, sync and options", [stub.latency, stub.sync === stub, stub.options.blockSize], [0.2, true, 64]);
~tEq.("sendMsg still records into msgs alone", { stub.sendMsg(\c_set, 3, 1); [stub[\msgs].last, stub[\bundles].size] }.value,
    [[\c_set, 3, 1], 2]);
}.value;
