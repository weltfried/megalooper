// Onset-note replay: pattern building and velocity mapping.
//
// Pure arithmetic on [time, strength] pairs, so all of it runs with no server.
// The routine that SENDS the notes is not covered here — it needs a clock, a
// MIDI port and a running engine synth — but everything it reads is.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-onset-notes");

{
var l = ~tLooper.();
var pairs;

// ---- prBuildOnsetPattern -------------------------------------------------

// Strength is normalised against the take's own loudest hit, and hits at or
// past patternDur are dropped: the analysis snaps a take to whole bars and
// that can cut the tail off what was actually played.
l.prBuildOnsetPattern([[0.0, 0.9], [0.5, 0.3], [2.5, 1.0], [-0.1, 0.5]], 2.0);
~tEq.("drops onsets outside the loop", l.onsetNoteCount, 2);
~tEq.("records the pattern period", l.onsetNotePatternDur, 2.0);
~tEqArray.("normalises against the take's peak",
    ~tGet.(l, \onsetNotePattern), [[0.0, 1.0], [0.5, 1/3]], 1e-9);

// Unsorted input must come out in time order or the replay routine's cursor
// scan (detectIndex on p[0] >= cursor) picks the wrong starting hit.
l.prBuildOnsetPattern([[1.5, 0.2], [0.1, 0.8], [0.9, 0.5]], 2.0);
~tEqArray.("sorts by time",
    ~tGet.(l, \onsetNotePattern).collect { |p| p[0] }, [0.1, 0.9, 1.5], 1e-9);

// A hit exactly at patternDur belongs to the NEXT pass, not this one.
l.prBuildOnsetPattern([[0.0, 1.0], [2.0, 1.0]], 2.0);
~tEq.("boundary hit at patternDur is excluded", l.onsetNoteCount, 1);

// Degenerate inputs must yield an empty pattern rather than throwing or, worse,
// leaving a stale pattern from the previous take in place.
l.prBuildOnsetPattern([[0.0, 1.0]], 2.0);
l.prBuildOnsetPattern(nil, 2.0);
~tEq.("nil pairs clear the pattern", l.onsetNoteCount, 0);
l.prBuildOnsetPattern([[0.0, 1.0]], 2.0);
l.prBuildOnsetPattern([], 2.0);
~tEq.("no pairs clear the pattern", l.onsetNoteCount, 0);
l.prBuildOnsetPattern([[0.0, 1.0]], 2.0);
l.prBuildOnsetPattern([[0.0, 1.0]], 0);
~tEq.("zero period clears the pattern", l.onsetNoteCount, 0);
l.prBuildOnsetPattern([[0.0, 1.0]], 2.0);
l.prBuildOnsetPattern([[0.0, 1.0]], nil);
~tEq.("nil period clears the pattern", l.onsetNoteCount, 0);
~tEq.("cleared pattern also clears its period", l.onsetNotePatternDur, nil);

// A silent analysis tap reports onsets with zero strength. Dividing by that
// peak would give nan velocities, so it must be refused outright.
l.prBuildOnsetPattern([[0.0, 0.0], [0.5, 0.0]], 2.0);
~tEq.("all-zero strengths clear the pattern", l.onsetNoteCount, 0);

// ---- prOnsetVelocity -----------------------------------------------------

l = ~tLooper.();
~tEq.("loudest hit maps to velHi", l.prOnsetVelocity(1.0), l.onsetNoteVelHi);
~tEq.("silence maps to velLo", l.prOnsetVelocity(0.0), l.onsetNoteVelLo);
~tEq.("a hit below the dynamic range floors at velLo",
    l.prOnsetVelocity(30.neg.dbamp / 2), l.onsetNoteVelLo);
~tCheck.("velocity is monotonic in strength", {
    var vels = [0.01, 0.1, 0.3, 0.6, 1.0].collect { |r| l.prOnsetVelocity(r) };
    if(vels.every { |v, i| (i == 0) or: { v >= vels[i - 1] } }.not) {
        Error("not monotonic: " ++ vels).throw
    };
    vels
});

// Every velocity must be a legal MIDI value whatever the controls are set to,
// including the inverted case where a user drags Lo above Hi.
l.onsetNoteVelLo = 120; l.onsetNoteVelHi = 20;
~tAssert.("inverted velLo/velHi still yields legal MIDI",
    [0.0, 0.01, 0.5, 1.0].collect { |r| l.prOnsetVelocity(r) }
        .every { |v| v.isInteger and: { v >= 1 } and: { v <= 127 } },
    "expected every velocity in 1..127");

// The headline design property: velocity comes from strength RELATIVE to the
// take's own peak, in dB. Turning the interface gain up must therefore move
// every velocity by nothing at all — otherwise the drum part changes character
// whenever the preamp moves, and that was the whole reason for normalising.
l = ~tLooper.();
pairs = [[0.0, 0.8], [0.4, 0.2], [0.8, 0.5], [1.2, 0.05]];
l.prBuildOnsetPattern(pairs, 2.0);
~tCheck.("gain independence: 10x quieter take gives identical velocities", {
    var loud = ~tGet.(l, \onsetNotePattern).collect { |p| l.prOnsetVelocity(p[1]) };
    var quiet;
    l.prBuildOnsetPattern(pairs.collect { |p| [p[0], p[1] * 0.1] }, 2.0);
    quiet = ~tGet.(l, \onsetNotePattern).collect { |p| l.prOnsetVelocity(p[1]) };
    if(loud != quiet) {
        Error("loud " ++ loud ++ " != quiet " ++ quiet).throw
    };
    loud
});

// ---- onsetNoteChance: thinning the part ----------------------------------
//
// The draws are made once per take and then only compared against the chance,
// which is what makes the thinned part repeat exactly and the slider monotonic.
// These assert both ends are EXACT (a draw is in [0, 1) and the test is `<`),
// that the waterline only ever rises, and that reading the state never moves it.

l = ~tLooper.();
l.prBuildOnsetPattern(
    (0..19).collect { |i| [i * 0.1, 1.0] }, 2.0);
~tEq.("a fresh pattern starts at full chance", l.onsetNoteChance, 1.0);
~tEq.("chance 1 plays every hit", l.onsetNotePlayingCount, l.onsetNoteCount);
l.onsetNoteChance = 0;
~tEq.("chance 0 plays nothing", l.onsetNotePlayingCount, 0);
l.onsetNoteChance = 1;
~tEq.("back at 1 every hit returns", l.onsetNotePlayingCount, l.onsetNoteCount);

// The draws must live in [0, 1), or the two ends above stop being exact.
l.prBuildOnsetPattern((0..19).collect { |i| [i * 0.1, 1.0] }, 2.0);
~tAssert.("every draw is in [0, 1)",
    ~tGet.(l, \onsetNoteRolls).every { |r| r >= 0 and: { r < 1 } },
    ~tGet.(l, \onsetNoteRolls).asString);
~tEq.("one draw per hit",
    ~tGet.(l, \onsetNoteRolls).size, l.onsetNoteCount);

// Reading is not rolling: the panel repaints on every model notification, and a
// count that moved each time it was asked would make the readout a liar.
l.onsetNoteChance = 0.5;
~tEq.("the playing count is stable across reads",
    l.onsetNotePlayingCount, l.onsetNotePlayingCount);

// The waterline property, and the reason the draws are stored rather than
// re-rolled: raising the chance may ADD hits but must never take one away.
~tCheck.("raising the chance only ever adds hits", {
    var last = -1;
    (0..20).do { |i|
        var n;
        l.onsetNoteChance = i / 20;
        n = l.onsetNotePlayingCount;
        if(n < last) {
            Error("chance " ++ (i / 20) ++ " plays " ++ n
                ++ ", down from " ++ last).throw
        };
        last = n;
    };
    last
});

// Re-rolling keeps the take and its timing; only which hits sound changes.
l.onsetNoteChance = 1;
~tCheck.("re-roll leaves the pattern and period untouched", {
    var before = ~tGet.(l, \onsetNotePattern).deepCopy;
    var dur = l.onsetNotePatternDur;
    l.rerollOnsetNotes;
    if(~tGet.(l, \onsetNotePattern) != before) { Error("pattern changed").throw };
    if(l.onsetNotePatternDur != dur) { Error("period changed").throw };
    if(l.onsetNotePlayingCount != l.onsetNoteCount) {
        Error("chance 1 stopped playing everything").throw
    };
    before.size
});

// Roughly the right density. Loose on purpose — this asserts the chance is used
// as a probability at all, not that a particular seed came out near the mean.
l = ~tLooper.();
l.prBuildOnsetPattern((0..399).collect { |i| [i * 0.005, 1.0] }, 2.0);
l.onsetNoteChance = 0.5;
~tAssert.("chance 0.5 plays roughly half of 400 hits",
    l.onsetNotePlayingCount.inclusivelyBetween(150, 250),
    l.onsetNotePlayingCount.asString ++ " of 400");

// A pattern assembled from outside carries no draws. Silence would be the wrong
// guess there, so a missing draw reads as 0 and sounds at any chance above 0.
l = ~tLooper.();
~tPut.(l, \onsetNotePattern, [[0.0, 1.0], [0.5, 1.0]]);
~tPut.(l, \onsetNotePatternDur, 2.0);
~tEq.("a pattern with no draws still plays at full chance",
    l.onsetNotePlayingCount, 2);
l.onsetNoteChance = 0;
~tEq.("and is still silenced at chance 0", l.onsetNotePlayingCount, 0);

// The draws index into the pattern, so undo has to restore them together with
// it — otherwise the restored take gets thinned by the newer take's dice.
l = ~tLooper.();
l.prBuildOnsetPattern((0..19).collect { |i| [i * 0.1, 1.0] }, 2.0);
// Events answer any selector by key lookup, so a one-key Event is the whole
// buffer undo needs: it does nothing with the audio here but copy it back.
~tPut.(l, \buffer,     (copyData: { |self, other| self }));
~tPut.(l, \undoBuffer, (copyData: { |self, other| self }));
~tCheck.("undo restores the draws with the pattern they belong to", {
    var snap = (
        onsetNotePattern: ~tGet.(l, \onsetNotePattern),
        onsetNotePatternDur: l.onsetNotePatternDur,
        onsetNoteRolls: ~tGet.(l, \onsetNoteRolls).deepCopy,
        // \playing, so undo takes its restore branch rather than the teardown
        // one — this is about what it carries across, not about transport.
        startFrame: 0, loopFrames: 0, lastResult: nil, state: \playing
    );
    var want = snap.onsetNoteRolls;
    ~tPut.(l, \undoState, snap);
    // A later take overwrites both, exactly as a real one would.
    l.prBuildOnsetPattern((0..4).collect { |i| [i * 0.1, 1.0] }, 2.0);
    l.undo;
    if(~tGet.(l, \onsetNoteRolls) != want) {
        Error("draws not restored: " ++ ~tGet.(l, \onsetNoteRolls)
            ++ " != " ++ want).throw
    };
    want.size
});

// Clearing the pattern must clear the draws with it, or the next pattern built
// from outside inherits the previous take's dice.
l = ~tLooper.();
l.prBuildOnsetPattern((0..19).collect { |i| [i * 0.1, 1.0] }, 2.0);
l.prBuildOnsetPattern(nil, 2.0);
~tEq.("clearing the pattern clears the draws",
    ~tGet.(l, \onsetNoteRolls), nil);

// ---- setters clip to MIDI's legal ranges ---------------------------------

l = ~tLooper.();
l.onsetNote = 999;      ~tEq.("note clips high", l.onsetNote, 127);
l.onsetNote = -5;       ~tEq.("note clips low", l.onsetNote, 0);
l.onsetNote = 36.7;     ~tEq.("note truncates to an integer", l.onsetNote, 36);
l.onsetNoteChannel = 99; ~tEq.("channel clips to 15", l.onsetNoteChannel, 15);
l.onsetNoteChannel = -1; ~tEq.("channel clips to 0", l.onsetNoteChannel, 0);
l.onsetNoteVelLo = 0;   ~tEq.("velLo clips to 1 (0 would be a note-off)",
    l.onsetNoteVelLo, 1);
l.onsetNoteDynRange = 0; ~tEq.("dynRange clips to 1 (0 would divide by zero)",
    l.onsetNoteDynRange, 1);
l.onsetNoteOffsetMs = 9999;
~tEq.("offset clips to the box's +/-500", l.onsetNoteOffsetMs, 500);
l.onsetNoteChance = 5;  ~tEq.("chance clips to 1", l.onsetNoteChance, 1);
l.onsetNoteChance = -1; ~tEq.("chance clips to 0", l.onsetNoteChance, 0);
}.value;
