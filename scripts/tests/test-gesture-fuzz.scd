// Gesture fuzz: random sequences of what a foot and a hand can do mid-piece,
// checked against invariants that must hold whatever the order was.
//
// Every other file here tests a gesture somebody thought of. This one exists to
// find the ones nobody did. The vocabulary is small — thirty-odd footswitch,
// pedal and slider moves — but the ORDER is not, and both faults that have bitten
// on stage were order faults: a break armed across a stop, and a dissolve that
// stopped the routine it was running inside. Neither was found by a test; both
// were found by playing. A random walk over the same vocabulary is the cheapest
// way to play a few thousand takes before the gig does.
//
// The test therefore asserts PROPERTIES, not values. "The break lamp and the
// master gate always agree" is true of every sequence that exists; a fuzz run
// that finds a sequence where it is false has found something real, and the
// gesture list it prints is the reproduction.
//
// ---- what is real here, and what is modelled --------------------------------
//
// Real: every gesture marked below without a note is the same method call the
// footswitch, the CC handler or the slider makes. The levels are read back off
// STUB SYNTHS — real Synth objects bound to the stub server (~tStubSynth), so
// each `.set` lands as an /n_set in the server's message log. That is new, and
// it is what lets this file assert the thing test-break.scd had to write off:
// "masterSynth is nil in the fixture so the gate itself is unobservable."
//
// Modelled, and marked (M) in the gesture table: anything that needs wall-clock
// time or the server. A dissolve ramp is eight bars long, so `rampTo` applies
// "the ramp reached x" by hand, exactly as test-arc.scd does — the routine body
// that drives it is test-arc's job, not this file's. The cutter is switched on
// by setting the flag and handing each voice a stub mixer, because enableBBCut
// writes a WAV and syncs the server. A modelled gesture can only ever be as
// honest as its model, so each one is written to do precisely what the real
// path leaves behind and nothing more.
//
// ---- reading a failure ------------------------------------------------------
//
// One assertion per invariant, however many sequences run, so a failure here
// never buries the rest of the suite. The detail line carries the number of
// violations and the exact gesture sequence that produced the first one — paste
// that list into a deterministic test rather than leaving the fuzz to re-find it.
//
//     ~fuzzRuns = 5000;  ~fuzzSteps = 40;   // widen the search
//     ~fuzzSeed = 12345;                    // a different walk, repeatably

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-gesture-fuzz");

{
var runs  = ~fuzzRuns  ? 600;
var steps = ~fuzzSteps ? 24;
var seed  = ~fuzzSeed  ? 20260918;

var mixerStub, midiStub, rig, newEngine;
var weights;
var noteBalance, gateOf;
var rampTo, rampDone, cutterOn, newTake, stepDrums, takeResult, readingLands;
var gestures, invariants, restInvariants;
var violations, counts, seen, record, check;

// ---------------------------------------------------------------- stubs -----

// CutMixer stands in as an Event: `volume_` and `panfunc_` are not selectors
// Event answers itself, so they fall through to doesNotUnderstand and hit the
// keys below. (`set` and `free` ARE Event's own, which is why the synths above
// are real Synths and not Events.)
mixerStub = {
    var m = ();
    m[\volume_]  = { |self, v| self[\vol] = v; self };
    m[\panfunc_] = { |self, v| self[\pan] = v; self };
    m
};

// Everything the looper sends Live, in order, so a note left gated is visible.
midiStub = {
    var m = ();
    m[\log]     = List.new;
    m[\latency] = 0;
    m[\noteOn]  = { |self, ch, note, vel| self[\log].add([\on,  ch, note, vel]); self };
    m[\noteOff] = { |self, ch, note, vel| self[\log].add([\off, ch, note, vel]); self };
    m
};

newEngine = { |l|
    // What spawnEngine leaves behind for the arc: a synth carrying the level the
    // arc is currently at, a fresh loopStartTime, and a re-aligned onset part.
    var syn = ~tStubSynth.(l, \looperEngineMono);
    syn.set(\amp, l.prLoopMix);
    ~tPut.(l, \engineSynth, syn);
    ~tPut.(l, \loopStartTime, SystemClock.seconds);
    l.startOnsetNotes;
    l
};

// The take as the analyser returns it: the answer and its ranked list. The
// two alternatives keep the pulse AND the pulse count (7/4 at sub 2, 7/8 in
// one bar at sub 4), so a landing never asks for the cutter to be respawned —
// enableBBCut wants a server, and the reading's own logic is what is walked.
takeResult = {
    var answer = (numerator: 7, denominator: 8, tau: 0.125, sub: 2, k: 2,
        downbeatOffset: 0, bpm: 120, loopDur: 3.5, n: 28, score: 0.8);
    answer[\candidates] = [
        answer.copy,
        (numerator: 7, denominator: 4, tau: 0.125, sub: 2, k: 2, bpm: 240,
            loopDur: 3.5, n: 28, score: 0.7, phase: 0, downbeatOffset: 0, accent: 0,
            onsetCount: 4),
        (numerator: 7, denominator: 8, tau: 0.125, sub: 4, k: 1, bpm: 60,
            loopDur: 3.5, n: 28, score: 0.5, phase: 0, downbeatOffset: 0, accent: 0,
            onsetCount: 4)
    ];
    answer
};

// A looper mid-piece: a 7/8 take, two bars, 3.5 s at 48 k — the same fixture
// test-arc and test-break use, plus the synths and the cutter running.
rig = {
    var l = ~tLooper.();
    var take = takeResult.();
    ~tPut.(l, \state, \playing);
    ~tPut.(l, \loopFrames, (3.5 * 48000).asInteger);
    ~tPut.(l, \lastResult, take);
    ~tPut.(l, \analysedResult, take);
    ~tPut.(l, \midiOut, midiStub.());
    ~tPut.(l, \masterSynth,   ~tStubSynth.(l, \looperMaster));
    ~tPut.(l, \granularSynth, ~tStubSynth.(l, \looperGranular));
    // The shape prBuildOnsetPattern makes: [position in the loop, 0..1 strength].
    ~tPut.(l, \onsetNotePattern,
        [[0.0, 1.0], [0.9, 0.55], [1.75, 0.8], [2.6, 0.35]]);
    ~tPut.(l, \onsetNotePatternDur, 3.5);
    cutterOn.(l);
    newEngine.(l);
    l.prApplyMixes;      // every level starts consistent with the stored values
    l
};

// ------------------------------------------------------------- gestures -----

// (M) The dissolve routine's per-frame write. dissolvePos has no public setter
// on purpose — it belongs to the ramp — so this is the ramp, by hand.
rampTo = { |l, pos|
    if(l.dissolving) {
        ~tPut.(l, \dissolvePos, pos.clip(0, 1));
        l.prApplyMixes;
    };
};

// (M) The ramp reaching the end: the routine's last lines. It does NOT lower
// `dissolving` — that is startDissolve's contract, and the reason for it is the
// first thing this file found.
rampDone = { |l|
    if(l.dissolving) {
        ~tPut.(l, \dissolvePos, 1.0);
        l.prApplyMixes;
        if(l.dissolveStops) { l.stopPlayback };
    };
};

// (M) What enableBBCut leaves language-side. It also writes a WAV and syncs the
// server, neither of which exists here and neither of which the arc reads.
cutterOn = { |l|
    ~tPut.(l, \bbcut, true);
    l.bbcutVoices.do { |v| if(v[\mixer].isNil) { v[\mixer] = mixerStub.() } };
    l.prApplyMixes;
};

// (M) The player records again over a stopped or cleared looper.
newTake = { |l|
    var take = takeResult.();
    // What stopRecordStartPlay does to the readings: a pending one is
    // cancelled at the record press, and the fresh analysis is reading 0.
    l.prCancelReading;
    ~tPut.(l, \state, \playing);
    ~tPut.(l, \loopFrames, (3.5 * 48000).asInteger);
    ~tPut.(l, \lastResult, take);
    ~tPut.(l, \analysedResult, take);
    ~tPut.(l, \readingIndex, 0);
    ~tPut.(l, \onsetNotePattern,
        [[0.0, 1.0], [0.9, 0.55], [1.75, 0.8], [2.6, 0.35]]);
    ~tPut.(l, \onsetNotePatternDur, 3.5);
    newEngine.(l);
};

// A pending reading reaching its boundary. The boundary is put in the past so
// prLandReading runs straight through on this thread; the real routine it
// would have run inside is stopped by the landing itself.
readingLands = { |l|
    l.pendingReading !? { |p|
        p[\at] = SystemClock.seconds - 0.01;
        l.prLandReading(~tGet.(l, \readingSeq));
    };
};

// The drum part reaching its next hit. `.next` resumes the routine on this
// thread and returns at its next wait, so the pattern can be walked — including
// into the gap BETWEEN a noteOn and its noteOff — without spending wall time.
stepDrums = { |l|
    ~tGet.(l, \onsetNoteRoutine) !? { |r| r.next };
};

// name, weight, what the surface actually calls.
//
// The weights matter more than they look. A uniform walk over this vocabulary
// spends most of its length STOPPED — stop and clear are two of the draws, and
// almost everything interesting refuses to run unless a loop is playing — so a
// flat fuzz quietly tests the empty looper over and over. Weighting stop and
// clear down to what they are in a performance (once a piece, not once every
// twenty seconds) and the recovery up is what keeps the walk inside the state
// the instrument is actually played in.
gestures = [
    [\pedal,            4, { |l| l.intensity = 1.0.rand }],
    [\pedalHeel,        4, { |l| l.intensity = 0 }],
    [\pedalToe,         4, { |l| l.intensity = 1 }],
    [\setDissolveBars,  4, { |l| l.dissolveBars = (1..64).choose }],
    [\armDissolve,      4, { |l| l.startDissolve }],
    [\abortDissolve,    4, { |l| l.cancelDissolve }],
    [\rampTo,           4, { |l| rampTo.(l, 1.0.rand) }],
    [\rampDone,         4, { |l| rampDone.(l) }],
    [\dissolveStopsOn,  4, { |l| l.dissolveStops = true }],
    [\dissolveStopsOff, 4, { |l| l.dissolveStops = false }],
    [\setBreakLoops,    4, { |l| l.breakLoops = (1..8).choose }],
    [\fireBreak,        4, { |l| l.fireBreak }],
    [\endBreak,         4, { |l| l.endBreak }],
    [\reverse,          4, { |l| l.reverse }],
    [\onsetNotesOn,     4, { |l| l.onsetNotes = true }],
    [\onsetNotesOff,    4, { |l| l.onsetNotes = false }],
    [\stepDrums,        8, { |l| stepDrums.(l) }],
    [\onsetNote,        4, { |l| l.onsetNote = (24..48).choose }],
    [\onsetNoteChannel, 4, { |l| l.onsetNoteChannel = (0..15).choose }],
    [\onsetNoteOffset,  4, { |l| l.onsetNoteOffsetMs = (-50..50).choose }],
    [\onsetNoteGate,    4, { |l| l.onsetNoteGateMs = (1..200).choose }],
    [\feedback,         4, { |l| l.feedback = 1.0.rand }],
    [\granularLevel,    4, { |l| l.granularAmp = 1.0.rand }],
    [\granularMorph,    4, { |l| l.granularMorph = 1.0.rand }],
    [\masterAmp,        4, { |l| l.masterAmp = 1.0.rand }],
    [\voiceAmp,         4, { |l| l.setVoiceAmp(0, 1.0.rand) }],
    [\cutterOn,         4, { |l| cutterOn.(l) }],
    [\cutterOff,        4, { |l| l.disableBBCut }],
    [\startClock,       4, { |l| l.startMidiClock(103.2, 3.5) }],
    [\transportMode,    2, { |l| l.transportMode = [\full, \startOnly, \off].choose }],
    [\stop,             1, { |l| l.stopPlayback }],
    [\clear,            1, { |l| l.clear }],
    [\newTake,          6, { |l| newTake.(l) }],
    [\nextReading,      3, { |l| l.nextReading }],
    [\revertReading,    2, { |l| l.revertReading }],
    [\readingLands,     3, { |l| readingLands.(l) }]
];

// ----------------------------------------------------------- invariants -----
//
// Each returns a (possibly empty) list of reasons it does not hold. `ctx` holds
// whatever had to be snapshotted when the run started.

noteBalance = { |l|
    var open = 0;
    ~tGet.(l, \midiOut)[\log].do { |e|
        if(e[0] == \on) { open = open + 1 } { open = open - 1 };
    };
    open
};

// The SynthDef's own default is 1, so a gate never written is a gate wide open.
gateOf = { |l| ~tLastSet.(l, ~tGet.(l, \masterSynth), \breakAmp) ? 1 };

invariants = [
    [\every_control_stays_in_its_declared_range, { |l, ctx|
        var bad = List.new;
        if((l.intensity < 0) or: { l.intensity > 1 }) {
            bad.add("intensity " ++ l.intensity) };
        if((l.dissolvePos < 0) or: { l.dissolvePos > 1 }) {
            bad.add("dissolvePos " ++ l.dissolvePos) };
        if((l.breakLoops < 1) or: { l.breakLoops > 8 }) {
            bad.add("breakLoops " ++ l.breakLoops) };
        if((l.dissolveBars < 1) or: { l.dissolveBars > 64 }) {
            bad.add("dissolveBars " ++ l.dissolveBars) };
        bad
    }],

    [\every_mix_is_a_level, { |l, ctx|
        var bad = List.new;
        [[\loop, l.prLoopMix], [\cutter, l.prBBCutMix], [\grains, l.prGranularMix]]
            .do { |p|
                var v = p[1];
                if(v.isNumber.not or: { v.isNaN } or: { v < 0 } or: { v > 1 }) {
                    bad.add(p[0].asString ++ " mix is " ++ v);
                };
            };
        bad
    }],

    // The one that would strand a muted looper on stage, and the reason the
    // stub synths exist: whatever the header says about the break, the audible
    // gate says the same.
    [\the_break_lamp_and_the_master_gate_agree, { |l, ctx|
        var bad = List.new;
        var gate = gateOf.(l);
        if(l.onBreak and: { gate != 0 }) { bad.add("lamp on but gate at " ++ gate) };
        if(l.onBreak.not and: { gate != 1 }) { bad.add("lamp off but gate at " ++ gate) };
        bad
    }],

    [\a_lit_break_lamp_is_explained, { |l, ctx|
        var bad = List.new;
        if(l.onBreak and: { l.breakEndsAt.isNil }) {
            bad.add("BREAK lamp with no countdown to show") };
        if(l.onBreak and: { (l.state != \playing) and: { l.state != \overdubbing } }) {
            bad.add("BREAK lamp while " ++ l.state) };
        bad
    }],

    [\a_running_dissolve_is_explained, { |l, ctx|
        var bad = List.new;
        if(l.dissolving and: { ~tGet.(l, \dissolveRoutine).isNil }) {
            bad.add("dissolving with no ramp behind it") };
        if(l.dissolving and: { (l.state != \playing) and: { l.state != \overdubbing } }) {
            bad.add("dissolving while " ++ l.state) };
        bad
    }],

    // The manual's own standard (docs/manual.md): "a deliberate silence and genuinely broken
    // audio otherwise look identical". A dry loop at zero while the looper says
    // it is playing must therefore be a break or a dissolve — both of which
    // light a lamp. Anything else is silence the player cannot account for.
    [\silence_always_has_a_lamp_to_explain_it, { |l, ctx|
        var bad = List.new;
        if((l.state == \playing) and: { l.onBreak.not } and: { l.dissolving.not }
            and: { l.prLoopMix <= 0 }) {
            bad.add("playing, no lamp lit, dry loop at 0 (dissolvePos "
                ++ l.dissolvePos ++ ")");
        };
        bad
    }],

    // prApplyMixes is documented as the single writer of the three running
    // levels. If that is true then the running level is always exactly the
    // stored level times the arc — no gesture can leave one behind.
    [\the_running_levels_follow_the_stored_ones, { |l, ctx|
        var bad = List.new;
        ~tGet.(l, \engineSynth) !? { |syn|
            var want = l.prLoopMix;
            var got  = ~tLastSet.(l, syn, \amp);
            if(got.isNil or: { (got - want).abs > 1e-9 }) {
                bad.add("engine amp " ++ got ++ ", want " ++ want) };
        };
        ~tGet.(l, \granularSynth) !? { |syn|
            var want = l.granularAmp * l.prGranularMix;
            var got  = ~tLastSet.(l, syn, \amp);
            if(got.isNil or: { (got - want).abs > 1e-9 }) {
                bad.add("granular amp " ++ got ++ ", want " ++ want) };
        };
        l.bbcutVoices.do { |v, i|
            v[\mixer] !? { |m|
                var want = v[\amp] * l.prBBCutMix;
                var got  = m[\vol];
                if(got.isNil or: { (got - want).abs > 1e-9 }) {
                    bad.add("voice " ++ i ++ " at " ++ got ++ ", want " ++ want) };
            };
        };
        bad
    }],

    // Nothing the arc does may write to what the GUI shows and the presets save.
    [\the_arc_never_edits_a_stored_value, { |l, ctx|
        var bad = List.new;
        l.bbcutVoices.do { |v, i|
            var was = ctx[\params][i];
            if(was.notNil) {
                was.keysValuesDo { |k, want|
                    var got = v[\params][k];
                    if(got != want) {
                        bad.add("voice " ++ i ++ " " ++ k ++ ": " ++ want
                            ++ " -> " ++ got);
                    };
                };
            };
        };
        bad
    }],

    // A reading armed but not landed must have the routine that will land it
    // and a loop to land on; and the reading the header says is in force must
    // be the one lastResult carries, or the header lies about the meter.
    [\a_pending_reading_is_explained, { |l, ctx|
        var bad = List.new;
        var says = (l.lastResult !? { |r| r[\reading] }) ? 0;
        l.pendingReading !? { |p|
            if(~tGet.(l, \readingRoutine).isNil) {
                bad.add("pending reading with no routine to land it") };
            if((l.state != \playing) and: { l.state != \overdubbing }) {
                bad.add("pending reading while " ++ l.state) };
        };
        if(says != l.readingIndex) {
            bad.add("readingIndex " ++ l.readingIndex ++ " but lastResult says " ++ says);
        };
        bad
    }],

    // A noteOn that never gets its noteOff hangs in Live forever — nothing
    // downstream will ever come along and clear it.
    [\no_note_is_left_hanging_in_live, { |l, ctx|
        var bad = List.new;
        var open = noteBalance.(l);
        var held = if(~tGet.(l, \onsetNoteSounding).notNil) { 1 } { 0 };
        if(open != held) {
            bad.add("note balance " ++ open ++ " with "
                ++ held ++ " gated hit outstanding");
        };
        bad
    }]
];

// Checked once, after the sequence has been returned to rest the documented
// way. "The set moved on to the next piece" is the case none of these gestures
// was designed against, and it is the one a gig hits every twenty minutes.
restInvariants = [
    [\rest_leaves_the_looper_empty_and_quiet, { |l, ctx|
        var bad = List.new;
        if(l.state != \empty)       { bad.add("state " ++ l.state) };
        if(l.dissolving)            { bad.add("still dissolving") };
        if(l.dissolvePos != 0)      { bad.add("dissolvePos " ++ l.dissolvePos) };
        if(l.onBreak)               { bad.add("still on break") };
        if(l.breakEndsAt.notNil)    { bad.add("break countdown still published") };
        if(l.bbcut)                 { bad.add("cutter still on") };
        if(l.pendingReading.notNil) { bad.add("reading still pending") };
        bad
    }],

    [\rest_restores_the_master_gate, { |l, ctx|
        var bad = List.new;
        var gate = gateOf.(l);
        if(gate != 1) { bad.add("master break gate left at " ++ gate) };
        bad
    }],

    [\rest_leaves_no_routine_running, { |l, ctx|
        var bad = List.new;
        [\breakRoutine, \dissolveRoutine, \onsetNoteRoutine, \readingRoutine,
            \chordRoutine, \clickRoutine, \overdubSyncRoutine, \nextRecRoutine]
            .do { |name|
                if(~tGet.(l, name).notNil) {
                    bad.add(name.asString ++ " survived the clear") };
            };
        // The clock is the deliberate exception: outside \full it keeps running
        // so Live's external sync stays alive across a stop.
        if((l.transportMode == \full) and: { ~tGet.(l, \midiClockRoutine).notNil }) {
            bad.add("midiClockRoutine survived the clear in \\full");
        };
        bad
    }],

    [\rest_leaves_no_note_held_in_live, { |l, ctx|
        var bad = List.new;
        var open = noteBalance.(l);
        if(open != 0) { bad.add("note balance " ++ open ++ " after the clear") };
        bad
    }]
];

// ----------------------------------------------------------------- run ------

violations = IdentityDictionary.new;
counts     = IdentityDictionary.new;
seen       = IdentityDictionary.new;
weights    = gestures.collect { |g| g[1] }.normalizeSum;

record = { |key, trace, why|
    counts[key] = (counts[key] ? 0) + 1;
    if(violations[key].isNil) { violations[key] = [trace.asArray, why] };
    nil
};

check = { |set, l, ctx, trace|
    set.do { |inv|
        var bad = inv[1].value(l, ctx);
        if(bad.notEmpty) { record.(inv[0], trace, bad.join("; ")) };
    };
    nil
};

thisThread.randSeed = seed;

runs.do {
    var l     = rig.();
    var trace = List.new;
    var ctx   = (params: l.bbcutVoices.collect { |v| v[\params].copy });

    steps.do {
        var g = gestures.wchoose(weights);
        trace.add(g[0]);
        seen[g[0]] = true;
        // A gesture that throws is itself the finding: these run inside MIDI
        // responders and Routines, where a throw kills the handler silently and
        // the next stomp simply does nothing.
        try { g[2].value(l) } { |err|
            record.(\no_gesture_ever_throws, trace,
                g[0].asString ++ " threw " ++ err.class.asString
                    ++ ": " ++ (err.errorString ? "?"));
        };
        check.(invariants, l, ctx, trace);
    };

    trace.add(\clear);
    try { l.clear } { |err|
        record.(\no_gesture_ever_throws, trace,
            "clear threw " ++ err.class.asString ++ ": " ++ (err.errorString ? "?"));
    };
    check.(restInvariants, l, ctx, trace);
};

// -------------------------------------------------------------- report ------

([[\no_gesture_ever_throws, nil]] ++ invariants ++ restInvariants).do { |inv|
    var key = inv[0];
    var v   = violations[key];
    ~tAssert.(key.asString.replace("_", " "), v.isNil,
        v !? { |vv|
            (counts[key] ? 0).asString ++ " of " ++ (runs * steps)
                ++ " gestures — first after " ++ vv[0].asString ++ " — " ++ vv[1]
        });
};

// The fuzzer itself has to be checked: a gesture that never fires tests nothing,
// which is how a fuzz quietly stops covering the thing it was written for.
{
    var missed = gestures.collect { |g| g[0] }.reject { |name| seen[name] == true };
    ~tAssert.("every gesture in the vocabulary actually fired",
        missed.isEmpty, "never chosen: " ++ missed.asString);
}.value;

("  (" ++ runs ++ " sequences x " ++ steps ++ " gestures, seed " ++ seed ++ ")").postln;

}.value;
