// Megalooper SA's drums (docs/dev/megalooper-sa.md, Phase 4): what Live played
// under the loop, without Live. Rhythmic Steps' two patterns (MegaSASteps), the
// steps' kit and the onset kit (MegaSAKit), the scheduler that puts them on the
// loop's own time base, and the voices that play them. MegaSA owns one: it
// builds the server side and attaches the Looper, which then drives the drums'
// transport through MegaSATransport (its MIDI port on SA) exactly as it drove
// Live's, and hands over its onset notes through Looper.onsetNoteSink.
//
// The server side (build):
//
//   drumGroup        MegaSA's, after the default group (where the engine runs)
//     [head]         the drift probe's one-block synths
//     stepsGroup     the steps' voices, each added to the tail -> stepsBus
//     repeatGroup    Beat Repeat's repeats -> stepsBus
//     onsetGroup     the onset kit's voices -> onsetBus
//     [tail]         \megaSADrumsFx  stepsBus -> stepsOutBus (the drums' reverb)
//                    \megaSAOnsetFx  onsetBus -> onsetOutBus (the One Hit Kit's chain)
//
// Voices go to the TAIL of their group, so voices starting in one block run in
// the order they were sent: lanes 3, 2, 1, 0 in a step, Live's last note winning
// a choke.
//
// ---- The time base ----
// Every hit has a GRID time g: the engine time at which the loop plays that
// position, counted from the Looper's nominal anchor (loopStartTime) and never
// corrected. The loop is heard 20 ms after its grid (the Limiter's look-ahead in
// the Looper's master); the drums' own path has none. So every hit is stamped
//
//     stamp = g + loopAudioDelay + dHat + (offsetMs / 1000)
//
// with the lane's delay and a roll's spacing already inside g, and dHat the
// drift probe's estimate of how late the loop's audio runs behind the nominal
// grid (it enters the stamp only, never the grid). The bundles are timestamped
// and the voices start with OffsetOut, so a hit lands on its sample.
//
// The grid comes in EPOCHS (a transport start: the Looper's Start, the drums'
// bar 1 on a loop boundary, the patterns' step counters from 0, new dice) and
// SEGMENTS within one (a reading landing without a restart: the step count
// goes on, the 16th and the numerator change; or the loop's half-time, where
// the 16th is twice as long). A 16th is the loop's length over the whole
// number of 16ths the reading in force gives it, over the loop's speed, so the
// grid can never walk against the loop.
//
// ---- The scheduler ----
// pump(wall), every pumpPeriod on SystemClock, decides in time order every event
// whose grid time is under wall + lead: the next step of BOTH patterns (both run
// always and draw their dice, as Live's switched-off device kept running; only
// the one in force at a hit's time is heard), every note a step fires (at the
// step plus its lane's delay) and every roll hit, and the onset part. Wall time
// (wallClock) decides what is still in the future; a bundle's delta is always
// stamp - thisThread.seconds, so the absolute stamp stays exact from any thread,
// however stale its logical time. A hit sounds iff, at its own grid time, its
// pattern is in force, the drums are on, the transport plays and its epoch is
// the one in force, and its stamp is still after wall + margin; a hit that
// would be later than that is dropped and counted, one warning per burst.
//
// What can change after hits are sent (a break, PC 17, a stop, a reading, a
// Start over a running transport) changes at a grid time t. Every sent hit owns
// one of 1024 cancel busses of its slot, which its voices latch in their first
// block, so one /c_set silences exactly that hit and no other. cut(t) re-judges
// exactly the hits decided at or after t whose stamps are still after wall +
// margin: those no longer wanted are cancelled, those now wanted are sent; hits
// before t, and hits too close to cancel, are left alone, so nothing doubles and
// nothing before t is lost. A change to the grid itself (a reading put in or
// taken out, an epoch) also rewinds the patterns to the first step at or after
// t and decides those steps again; the dice are a pure function of the step, so
// a step decided twice decides the same way.
//
// Nothing in the pump waits. A change asked for while it runs is queued and
// applied when it is done, and the notifications it raises go out after it
// returns.
//
// ---- The effects ----
// The steps' bus goes through the drums' reverb (Live's Hybrid Reverb) and the
// onset kit's through the One Hit Kit's chain, both MegaSADrumsFx's. Kit-Carbon's
// per-pad Beat Repeat is emulated here, in the scheduler (see the Beat Repeat
// section): SA replays what it knows was sounding in the captured slice.
// The patterns, kits, trims, Beat Repeat's switch, the reverb and the offset
// are kept in presets and in Keep (see Presets).
//
// ---- The session log ----
// While the Looper's session recorder logs a set, the drums tell it every hit
// that sounded and what their transport did, each once it has been heard (see
// the Session log section), so a set's log, and the MIDI file made from it,
// hold exactly what was played.
//
// ---- The note sequencer ----
// A third part of the pump (see The note sequencer below): MegaSANoteSeq's
// pattern stepped on the same grid, epochs and segments, its notes hits of
// their own slot (\synth) with cancel busses as the drums' have, judged by
// its own switch (notesOn) instead of PC 17, and silent in the Looper's
// break, as the loop is (not in the Main | BREAK switch by hand, which
// changes the drums' pattern and silences nothing).
//
// Like MegaSA it does not survive Cmd-period: nothing re-creates its nodes or
// its routine. Re-run boot.scd.
MegaSADrums {
    var <megaSA, <server;
    // False once freed: the transport port and the onset sink then do nothing
    // (on a reboot the old Looper is freed after the new MegaSA and still calls).
    var <alive = true;
    var <transport, <looper, controller;
    // The two patterns, \main and \break (MegaSASteps' Event), and the Live
    // set's, for liveStep and edited.
    var <patterns, livePatterns, timeShiftArm;
    // Where Auto Retrigger starts the lanes again. \barLine: on the first step
    // at or after every bar line of the reading, uneven bars too, so a 7/8 bar
    // plays 14 of a 16-step lane and an 8/8 bar all 16 (the duo's choice,
    // 2026-10-18). \live: as Live's device did, after every pseudo-bar of
    // <numerator> quarter notes on the next step that is a multiple of 8
    // (MegaSASteps.resync), so in 7/8 a lane reshapes itself over four bars.
    // Takes effect from the next step decided. Not kept in presets yet.
    var <retrigAt = \barLine;
    // PC 17, the pattern in force now, and whether the transport plays.
    var <on = true, <breakActive = false, <playing = false;
    // A new loop starts with the drums off: true switches PC 17 off as a
    // first take starts recording, so the loop's Start runs the transport
    // with the steps silent, and PC 17 (or the Drums view's switch) brings
    // them in on the grid. Overdubs and loop chaining start no new loop and
    // leave the switch as it is. The Setup view sets it, and settings.json
    // keeps it (setup-sa.scd, ~saDrumsNewLoop). False plays them, as Live's
    // set did.
    var <>newLoopOff = false;
    // Beat Repeat's switch starts OFF: in Live's recordings of the set its
    // Beat Repeats stutter about once in twelve minutes, where this emulation
    // of their dice would about once a minute. The kits keep their pads'
    // beatRepeat flags, and the Drums tab's switch (or a preset) turns it on.
    var <reverbMix = 0.1508, <offsetMs = 0, <repeats = false;
    // Kits: the folder, its index (scanKits), per slot the kit in force, the key
    // asked for, its state and the request serial; the buffers, shared by path,
    // with the last time a voice of each can end and when it is due to go, and
    // the reads still on their way (MegaSAKit.load: a load that needs a file
    // another is reading waits for that read).
    var <kitDir, kitIndex, kitObjects, kitRequested, kitStates, kitSerials, loadingKits;
    var <bufferCache, bufferEnds, bufferFreeAt, readsInFlight;
    // Per kit key: note -> dB, and group -> dB (the layer trim).
    var <padTrims, <groupTrims;
    // reader.(server, path, done) for MegaSAKit.load; nil: Buffer.read.
    var <>kitReader;
    var <lead = 0.1, <margin = 0.006, <pumpPeriod = 0.01;
    var <>wallClock, <>sender, <>randSeed, <>autoProbe = false;
    // The dice (keepDice): a seed every Start plays, or nil for new dice at
    // every Start; and the seed of the epoch last begun.
    var <keptDice, <lastSeed;
    var <dHat = 0, <lastProbeError, <dropped = 0, lastDropWall, lastPumpError;
    // The last analysis the Looper reported (setAnalysis): a start with no
    // Looper takes its grid from it.
    var <analysis;
    // The scheduler's state: epochs (each with its segments), per pattern the
    // cursor (the next step's state) and the log of decided steps, the hits not
    // yet decided (pending, in time order) and the decided ones (decided), the
    // playhead ring, and the condition histories ([[time, value], ...] from
    // inf.neg, in time order).
    var epochs, epochCount = 0, cursors, stepLogs, pending, <decided, playheads;
    var breakHist, onHist, playHist, breakEnd, rawEnd;
    // The Looper's break alone, true while its hole is heard: the pattern's
    // history (breakHist) is switched by hand too, and the synth keeps quiet
    // in the hole only (prWants).
    var holeHist;
    var pendingLanding;
    // The Looper's half-time still to land or end (at:, speed:), as an edge
    // in the grid (see Half-time), or nil.
    var halfEdge;
    var stepSerial = 0, recSerial = 0, onsetRunSerial = 0;
    var busy = false, jobs, queuedNotes;
    var onsetRun;
    // Where hits go: per slot the cancel ring's first bus, the choke block's
    // first bus, the output bus, and the groups' node IDs.
    var ringBases, chokeBases, outBusses, groupIds, ringSerials, hitSerials;
    var <drumGroup, <stepsGroup, <repeatGroup, <onsetGroup, <synthGroup, <fxSynth, <onsetFxSynth;
    var ringBusses, chokeBusses, pumpRoutine, probeResp, <built = false;
    // The drift probe.
    var probes, probeSerial = 0, nextProbeAt, spawnCount = 0, reverseCount = 0, speedCount = 0;
    var lastLam, lastSpawnAt, reversedSinceSpawn = false, bigErrors = 0;
    // The drums' reverb: the four spectra once in (else nil), the zero spectrum
    // it starts on, a load's serial, the effects' busses [in, out], and
    // whether build loads it (a real server only) through which reader.
    var <irBuffers, irDummy, irSerial = 0, fxBusses, <reverbState = \none;
    var <>irReader, <>autoIR = false;
    // The effects' sleep (prRestFx): per slot (\steps: the reverb, \onset:
    // the onset chain) when its last voice can have ended, and whether its
    // synth is paused. stepsHeld: a function, true while something may sound
    // through the reverb with no hit (MegaSA: a device on the drums' chain is
    // on), which keeps it awake.
    var fxQuietAt, <fxAsleep, <>stepsHeld;
    // Beat Repeat: the captures decided (their gates not yet over), the next
    // one to decide (epoch:, c:), the steps' hits that may still be sounding
    // (in grid order), its switch as a condition history, the chance per pad
    // per capture, and the repeats a rewind could no longer cancel.
    var <captures, captureCursor, repeatMemory, repeatHist, <>repeatChance, lockedRepeats;
    // Where Beat Repeat's capture points fall (setRepeatGrid): \bars, 6/16
    // into every second bar of the reading, uneven bars too; \live, as Live's
    // device did, 6/16 into every 8 quarter notes from the origin, which in
    // 7/8 walks across the bar lines.
    var <repeatGrid = \bars;
    // The session log: every hit sent, until it has been heard (logQueue);
    // what the log was last told of the transport (logState: nil until a
    // recording's first look); when a failing log was last posted.
    var logQueue, logState, lastLogError;
    // The note sequencer (MegaSANoteSeq, docs/dev/synth.md): its pattern,
    // its switch (and that as a condition history), its cursor, its log of
    // decided steps and their playheads, and noteVoice.(rec, where), the
    // OSC messages that play one note (nil: the test tone, \megaSANoteTone).
    var <notes, <notesOn = false, notesHist, noteCursor, noteLog, noteHeads, <>noteVoice;

    // megaSA: anything that answers `server` (MegaSA; a test passes an Event).
    *new { |megaSA| ^super.newCopyArgs(megaSA).init }

    init {
        server = megaSA !? { |m| m.server };
        patterns = (main: MegaSASteps.livePattern(\main), break: MegaSASteps.livePattern(\break));
        livePatterns = (main: MegaSASteps.livePattern(\main), break: MegaSASteps.livePattern(\break));
        // Live arms a resync on the first Clock Speed or Shuffle Length change
        // after the device loads, once per device (ResyncOnNextTimeShiftLoop).
        timeShiftArm = (main: true, break: true);
        kitDir = this.class.defaultKitDir;
        kitObjects = (steps: nil, onset: nil);
        kitRequested = (steps: nil, onset: nil);
        kitStates = (steps: \unset, onset: \unset);
        kitSerials = (steps: 0, onset: 0);
        loadingKits = (steps: nil, onset: nil);
        bufferCache = IdentityDictionary.new;
        bufferEnds = IdentityDictionary.new;
        bufferFreeAt = IdentityDictionary.new;
        fxQuietAt = IdentityDictionary.new;
        fxAsleep = IdentityDictionary.new;
        readsInFlight = IdentityDictionary.new;
        padTrims = IdentityDictionary.new;
        groupTrims = IdentityDictionary.new;
        wallClock = { Main.elapsedTime };
        // A nil time is a bundle to run at once.
        sender = { |absTime, msgs| server.sendBundle(absTime !? { |t| t - thisThread.seconds }, *msgs) };
        epochs = List.new;
        cursors = (main: nil, break: nil);
        stepLogs = (main: List.new, break: List.new);
        pending = List.new;
        decided = List.new;
        playheads = (main: List.new, break: List.new);
        breakHist = [[inf.neg, \main]];
        holeHist = [[inf.neg, false]];
        onHist = [[inf.neg, true]];
        playHist = [[inf.neg, false]];
        jobs = List.new;
        queuedNotes = List.new;
        ringSerials = (steps: 0, onset: 0, synth: 0);
        hitSerials = (steps: 0, onset: 0, synth: 0);
        probes = IdentityDictionary.new;
        captures = List.new;
        repeatMemory = List.new;
        repeatHist = [[inf.neg, repeats]];
        repeatChance = MegaSADrumsFx.beatRepeatChance;
        lockedRepeats = Dictionary.new;
        logQueue = List.new;
        notes = MegaSANoteSeq.defaultPattern;
        notesHist = [[inf.neg, false]];
        noteLog = List.new;
        noteHeads = List.new;
        transport = MegaSATransport(this);
        // Never on a stub, never in NRT: there is no loop to measure, and no
        // server to read the impulse responses.
        autoProbe = server.isKindOf(Server);
        autoIR = server.isKindOf(Server);
    }

    // presets/sa/drums/kits/ in the repository, or nil if it cannot be found.
    *defaultKitDir { ^try { Looper.repoRoot +/+ "presets" +/+ "sa" +/+ "drums" +/+ "kits" } { nil } }

    // The loop is heard this long after its grid: twice the Limiter's 10 ms in
    // the Looper's \looperMaster (its look-ahead delays by 2 x dur).
    // test-megadrums-sched.scd reads that Limiter and holds the two together.
    *loopAudioDelay { ^0.02 }

    // A hit, or a change of the transport, goes to the session log once it
    // was heard this long ago. A hit is cancelled only while its stamp is
    // still past wall + margin, so by then whether it sounded is settled.
    *logLag { ^0.05 }

    *paramSpecs { ^MegaSASteps.paramSpecs }
    *laneParamSpecs { ^MegaSASteps.laneParamSpecs }

    // The settings that move a pattern's steps in time: an edit re-derives the
    // next step from the song position (see prRetime).
    *timingParams { ^[\clockSpeed, \shuffleLength, \globalShuffle] ++ (1..8).collect { |n| ("shuffle" ++ n).asSymbol } }

    // ---- Pure arithmetic (every input an argument) -------------------------

    // The boundary a Start puts the drums' bar 1 on: the loop boundary nearest
    // now + latency (the Looper aims its Start `latency` before one), never one
    // in the past. With no loop, now + latency.
    *startBoundary { |now, latency, lam, loopDur|
        var b;
        if(loopDur.isNil or: { loopDur <= 0 } or: { lam.isNil }) { ^now + (latency ? 0) };
        b = lam + ((((now + (latency ? 0)) - lam) / loopDur).round * loopDur);
        if(b < (now - 0.001)) { b = b + loopDur };
        ^b
    }

    // The whole number of 16ths one loop holds under a reading: k bars of
    // numerator/denominator. Not the loop's length times the tempo, which need
    // not be whole for a reading whose pulse does not divide the loop.
    *sixteenthsFor { |result|
        var den = ((result !? { |r| r[\denominator] }) ? 4).asInteger.max(1);
        ^(((16 * MeterAnalyzer.unitsOf(result)) / den).round).asInteger.max(1)
    }

    // Where a reading's bars begin in one loop, in ticks (480 a quarter note)
    // from the loop's start: [0, 1680, 3360, 5040] for 7 7 7 8 over 8.
    *barStartTicks { |result|
        var den = ((result !? { |r| r[\denominator] }) ? 4).asInteger.max(1);
        var unit = 1920 / den;
        ^MeterAnalyzer.barsOf(result).inject([0], { |acc, b| acc.add(acc.last + (b * unit)) })
            .drop(-1).collect { |t| t.round.asInteger }
    }

    // A condition history is [[time, value], ...] in time order, its first
    // entry at inf.neg. The value in force at t (an edge at t counts from t).
    *historyAt { |hist, t|
        var i = hist.size - 1;
        while { (i > 0) and: { hist[i][0] > (t + 1e-9) } } { i = i - 1 };
        ^hist[i][1]
    }

    // The history with `value` in force from t on: every later edge goes.
    *historyFrom { |hist, t, value|
        var kept = hist.select { |e| e[0] < (t - 1e-9) };
        if(kept.isEmpty) { kept = [[inf.neg, hist[0][1]]] };
        if(this.historyAt(kept, t) != value) { kept = kept.add([t, value]) };
        ^kept
    }

    // When the value in force at t came in: its edge's time, inf.neg for the
    // first entry.
    *historyEdgeAt { |hist, t|
        var i = hist.size - 1;
        while { (i > 0) and: { hist[i][0] > (t + 1e-9) } } { i = i - 1 };
        ^hist[i][0]
    }

    // The history from `before` on: the value then becomes the first entry.
    *historyPruned { |hist, before|
        var i = 0;
        // The pump prunes 100 times a second: mostly there is nothing to do.
        if((hist.size < 2) or: { hist[1][0] > before }) { ^hist };
        while { ((i + 1) < hist.size) and: { hist[i + 1][0] <= before } } { i = i + 1 };
        ^[[inf.neg, hist[i][1]]] ++ hist.copyRange(i + 1, hist.size - 1)
    }

    // The loop boundary nearest x.
    *loopBoundaryNear { |x, lam, loopDur| ^lam + ((((x - lam) / loopDur).round) * loopDur) }

    // How far the loop's audio is ahead of the model at probe time (e > 0: the
    // loop is earlier than modelled), within half a 16th. `value` is the
    // engine's phase as the probe read it: A2K holds a block's first sample, and
    // the probe's time is dithered over the block, so on average it is 31.5
    // samples later than that.
    *probeError { |value, sampleRate, probeTime, lam, dHat, loopDur, s16|
        var phiHat = value + (31.5 / sampleRate);
        var model = ((probeTime - lam) - dHat) % loopDur;
        ^(phiHat - model).wrap(s16.neg / 2, s16 / 2)
    }

    // One probe's correction: [new dHat, consecutive large errors]. A quarter
    // of the error, at most 2 ms; the whole error once two in a row exceed
    // 10 ms (the loop moved, it did not drift).
    *driftStep { |dHat, err, bigCount|
        var big = if(err.abs > 0.010) { bigCount + 1 } { 0 };
        ^if(big >= 2) { [dHat - err, 0] } { [dHat - (0.25 * err).clip(-0.002, 0.002), big] }
    }

    // [bus, chokeOn] for a pad, `base` being its slot's choke block: 16 pad
    // busses for notes 36..51 (a retriggering pad chokes itself), 16 group
    // busses (a choke group's pads choke each other), and a scratch bus for a
    // pad that chokes nothing. Never a negative bus: In.kr and ReplaceOut.kr
    // read and write bus 0 for -1.
    *chokeFor { |pad, base|
        var note = pad[\note] ? 0, group = (pad[\choke] ? 0).asInteger;
        ^case
            { (group > 0) and: { group <= 16 } } { [(base + 16) + (group - 1), 1] }
            { (pad[\retrigger] == true) and: { note >= 36 } and: { note <= 51 } } { [base + (note - 36), 1] }
            { [base + 32, 0] }
    }

    // The first hit of an onset pattern ([[secs, ratio], ...] over `period`,
    // pass 0 starting at `base`) whose grid time is after gridMin: [pass, index].
    *onsetCursor { |pattern, period, base, gridMin|
        var m = (((gridMin - base) / period).floor).asInteger;
        var i = pattern.detectIndex { |h| ((base + (m * period)) + h[0]) > gridMin };
        ^if(i.isNil) { [m + 1, 0] } { [m, i] }
    }

    // Two bases of one period that play the same grid.
    *congruent { |a, b, period|
        var x = (a - b) / period;
        ^(x - x.round).abs < 1e-6
    }

    *prIndex { |bus| ^if(bus.isKindOf(Bus)) { bus.index } { bus } }

    // Two pattern values that differ, numbers within a millionth: a value
    // that came back through a file or a 32-bit control is no edit.
    *prDiffers { |a, b|
        ^case
            { a.isNumber and: { b.isNumber } } { (a - b).abs > ((b.abs * 1e-6).max(1e-9)) }
            { a.isKindOf(Dictionary) and: { b.isKindOf(Dictionary) } } {
                (a.size != b.size) or: { a.keys.any { |k| b.includesKey(k).not or: { this.prDiffers(a[k], b[k]) } } }
            }
            { a.isString or: { b.isString } } { a != b }
            { a.isKindOf(SequenceableCollection) and: { b.isKindOf(SequenceableCollection) } } {
                (a.size != b.size) or: { a.detectIndex { |x, i| this.prDiffers(x, b[i]) }.notNil }
            }
            { a != b }
    }

    // ---- SynthDefs --------------------------------------------------------

    // Called by MegaSA.loadSynthDefs, the only drum defs it needs to ask for:
    // the voices and the probe here, the effects from MegaSADrumsFx. They
    // build with no server.
    *loadSynthDefs {
        [1, 2].do { |chans|
            SynthDef(("megaSADrumVoice" ++ chans).asSymbol, this.prVoiceFunc(chans)).add;
        };
        // The drift probe: the engine's phase as the drums group (after the
        // engine) sees it in one block, then gone.
        SynthDef(\megaSADrumsProbe, { |phaseBus, id = 0|
            SendReply.kr(Impulse.kr(0), '/megaSADrumsProbe', [In.kr(phaseBus), id]);
            FreeSelf.kr(Impulse.kr(0));
        }).add;
        // \megaSADrumsFx (the steps' reverb) and \megaSAOnsetFx (the onset
        // kit's chain).
        MegaSADrumsFx.loadSynthDefs;
        SynthDef(\megaSANoteTone, this.prToneFunc).add;
    }

    // The note sequencer's test tone (until the Wave synth plays it): one
    // note, a filtered saw, mono by the drums' choke (any newer note of the
    // sequencer releases it) and cancelled by its hit's bus as a drum voice
    // is. dur: seconds the note is held.
    *prToneFunc {
        ^{ |out, freq = 440, amp = 0.2, dur = 0.1, cancelBus, chokeBus, hitId = 1, release = 0.02|
            var first = Impulse.kr(0);
            var ok = Latch.kr(In.kr(cancelBus) < 0.5, first);
            var choked, env, sig;
            ReplaceOut.kr(chokeBus, Select.kr(first * ok, [In.kr(chokeBus), hitId]));
            choked = SetResetFF.kr(((In.kr(chokeBus) - hitId).abs > 0.5) * (1 - first), 0);
            env = EnvGen.ar(Env.asr(0.003, 1, release), (1 - choked) * (Sweep.kr(0, 1) < dur), doneAction: 2);
            sig = LPF.ar(Saw.ar(freq) + SinOsc.ar(freq * 0.5, 0, 0.5), (freq * 6).clip(200, 12000));
            OffsetOut.ar(out, (sig * ((amp * ok) * env)).dup);
            FreeSelf.kr(1 - ok);
        }
    }

    // One layer of one hit, mono or stereo sample, stereo out.
    //   ok      the hit's cancel bus as it stands in the voice's first block: a
    //           cancelled hit multiplies its whole output by 0 (so it writes
    //           exactly nothing) and frees itself after that block.
    //   choke   order-free and latched: in its first block a voice writes its
    //           hit's id to its choke bus; from its second on, any other id
    //           there means a newer hit of its group started, and it releases
    //           over `release`. Voices of one hit share the id, so layers never
    //           choke each other; a newer hit with a lower id chokes too. The
    //           envelope runs at audio rate: it starts releasing in that second
    //           block, not a block later, and ends on a sample at 0 rather than
    //           on a block's step.
    //   dur     seconds to play (0: to the sample's end), gateLen a second limit
    //           for Beat Repeat's repeats, both closing the same envelope.
    //   drive   a pre-gain into tanh in dB (the One Hit Kit's Simpler drive).
    //   bp*     Beat Repeat's band filter on the repeats of pads 36-40: a
    //           high-pass and a low-pass, 12 dB/oct each, at the edges of the
    //           band of reciprocal Q bpRq round bpFreq (MegaSADrumsFx.bandEdges),
    //           as the manual describes its "combined low-pass and high-pass
    //           filter"; its slope is not documented.
    //   pan     a balance, -1..1, unity on both sides at the centre: in Live a
    //           mono sample plays dual mono at its own level, and the kits'
    //           gains assume so (Pan2 and Balance2 are both 3 dB down there).
    //           The far side falls along a quarter cosine, the near one stays.
    // BufRateScale is applied here: `rate` is the transpose alone.
    *prVoiceFunc { |chans|
        ^{ |out, buf, amp = 1, rate = 1, pan = 0, startFrames = 0, dur = 0, drive = 0,
            cancelBus, chokeBus, chokeOn = 0, hitId = 1, release = 0.005,
            bpOn = 0, bpFreq = 1515, bpRq = 2, gateLen = 0|
            var first = Impulse.kr(0);
            var ok = Latch.kr(In.kr(cancelBus) < 0.5, first);
            var sig = PlayBuf.ar(chans, buf, BufRateScale.ir(buf) * rate, startPos: startFrames, doneAction: 2);
            var elapsed = Sweep.kr(0, 1);
            var open = ((dur <= 0) + (elapsed < dur)).min(1) * ((gateLen <= 0) + (elapsed < gateLen)).min(1);
            var far = cos(pan.clip(-1, 1) * 0.5pi).max(0);
            var band = MegaSADrumsFx.bandEdges(bpFreq.clip(20, 20000), bpRq.clip(0.05, 8));
            var choked, env, gain;
            ReplaceOut.kr(chokeBus, Select.kr((first * ok) * chokeOn, [In.kr(chokeBus), hitId]));
            choked = SetResetFF.kr((((In.kr(chokeBus) - hitId).abs > 0.5) * (1 - first)) * chokeOn, 0);
            env = EnvGen.ar(Env.cutoff(release), (1 - choked) * open, doneAction: 2);
            sig = Select.ar(drive > 0, [sig, (sig * drive.dbamp).tanh]);
            sig = Select.ar(bpOn > 0, [sig, LPF.ar(HPF.ar(sig, band[0].clip(20, 20000)), band[1].clip(20, 20000))]);
            if(chans == 1) { sig = [sig, sig] };
            gain = (amp * ok) * env;
            OffsetOut.ar(out, [sig[0] * (gain * Select.kr(pan > 0, [1, far])),
                sig[1] * (gain * Select.kr(pan < 0, [1, far]))]);
            FreeSelf.kr(1 - ok);
        }
    }

    // ---- The patterns -----------------------------------------------------
    // which: \main or \break; sub: \chance \velo \alt \roll \slide; lane 0..3
    // (the device's lane 1 is 0); i 0..15. Getters answer nil for anything that
    // is not there; setters warn and change nothing.

    step { |which, sub, lane, i|
        ^if(this.prStepOk(which, sub, lane, i, false)) { patterns[which][\steps][sub][lane][i] }
    }

    // The value as stored, 0..6; notifies \step, which, sub, lane, i, v only
    // when it changed (a drag paints the same value many times).
    setStep { |which, sub, lane, i, v|
        var old, stored;
        if(this.prStepOk(which, sub, lane, i, true).not) { ^this };
        old = patterns[which][\steps][sub][lane][i];
        stored = MegaSASteps.putStep(patterns[which], sub, lane, i, v);
        if(stored.isNil) { ("MegaSADrums: a step is 0..6, not " ++ v.asCompileString).warn; ^this };
        if(stored != old) { this.prNotify(\step, which, sub, lane, i, stored) };
    }

    liveStep { |which, sub, lane, i|
        ^if(this.prStepOk(which, sub, lane, i, false)) { livePatterns[which][\steps][sub][lane][i] }
    }

    // A whole lane of one page: 16 values. Notifies \steps, which.
    setSteps { |which, sub, lane, array|
        if(this.prStepOk(which, sub, lane, 0, true).not) { ^this };
        if(array.isKindOf(SequenceableCollection).not or: { array.isString } or: { array.size != 16 }) {
            ("MegaSADrums: setSteps wants 16 values, not " ++ array.asCompileString).warn;
            ^this
        };
        array.do { |v, i|
            if(MegaSASteps.putStep(patterns[which], sub, lane, i, v).isNil) {
                ("MegaSADrums: step " ++ i ++ " " ++ v.asCompileString ++ " is not 0..6 (kept)").warn;
            };
        };
        this.prNotify(\steps, which);
    }

    // Randomize one lane of one page, as the device's two dice do
    // (MegaSASteps.randomized): `amount` \all for every step anew, \less for
    // every step moved by one at most. All 16 steps, whatever the length.
    // Notifies \steps, as setSteps does. `draw` is a test's dice.
    randomizeLane { |which, sub, lane, amount = \all, draw|
        var new;
        if(this.prStepOk(which, sub, lane, 0, true).not) { ^this };
        new = MegaSASteps.randomized(patterns[which][\steps][sub][lane], amount, draw);
        if(new.isNil) { ("MegaSADrums: randomize \\all or \\less, not " ++ amount.asCompileString).warn; ^this };
        this.setSteps(which, sub, lane, new);
    }

    // The page's own stored length, 2..16, whatever the lock.
    length { |which, sub, lane|
        ^if(this.prSubLaneOk(which, sub, lane, false)) { patterns[which][\lengths][sub][lane] }
    }

    // The length the page plays: the lane's global length while it is locked.
    effectiveLength { |which, sub, lane|
        ^if(this.prSubLaneOk(which, sub, lane, false)) { MegaSASteps.effectiveLength(patterns[which], sub, lane) }
    }

    // Notifies \length, which, sub, lane, v (always: the GUI repaints a value
    // that was held to the range).
    setLength { |which, sub, lane, n|
        var stored;
        if(this.prSubLaneOk(which, sub, lane, true).not) { ^this };
        stored = MegaSASteps.putLength(patterns[which], sub, lane, n);
        if(stored.isNil) { ("MegaSADrums: a length is 2..16, not " ++ n.asCompileString).warn; ^this };
        this.prNotify(\length, which, sub, lane, stored);
    }

    // \note \altNote (36..51), \delay (0..50 ms), \mute, \lock, \globalLength.
    laneParam { |which, lane, name|
        ^if(this.prLaneOk(which, lane, false)) { MegaSASteps.getLaneParam(patterns[which], lane, name) }
    }

    // Notifies \lane, which, lane, name, v.
    setLaneParam { |which, lane, name, v|
        var stored;
        if(this.prLaneOk(which, lane, true).not) { ^this };
        if((name == \length) or: { MegaSASteps.laneParamSpec(name).isNil }) {
            ("MegaSADrums: no lane setting " ++ name ++ "; they are \\note \\altNote \\delay \\mute "
                "\\lock \\globalLength (lengths: setLength)").warn;
            ^this
        };
        stored = MegaSASteps.putLaneParam(patterns[which], lane, name, v);
        if(stored.isNil) { ("MegaSADrums: " ++ name ++ " cannot be " ++ v.asCompileString).warn; ^this };
        this.prNotify(\lane, which, lane, name, stored);
    }

    // \clockSpeed \rollRate \shuffleLength \globalShuffle \autoRetrigger
    // \autoTriggerRate \shuffle1..8 (MegaSADrums.paramSpecs).
    param { |which, name|
        ^if(this.prWhichOk(which, false)) { MegaSASteps.getParam(patterns[which], name) }
    }

    // Notifies \param, which, name, v. An edit of the timing re-derives the next
    // step from the song position, as the device does (prRetime).
    setParam { |which, name, v|
        var old, stored;
        if(this.prWhichOk(which, true).not) { ^this };
        if(MegaSASteps.paramSpec(name).isNil) {
            ("MegaSADrums: no pattern setting " ++ name ++ "; they are MegaSADrums.paramSpecs").warn;
            ^this
        };
        old = MegaSASteps.getParam(patterns[which], name);
        stored = MegaSASteps.putParam(patterns[which], name, v);
        if(stored.isNil) { ("MegaSADrums: " ++ name ++ " cannot be " ++ v.asCompileString).warn; ^this };
        if((stored != old) and: { this.class.timingParams.includes(name) }) { this.prRetime(which, [name]) };
        this.prNotify(\param, which, name, stored);
    }

    // \barLine or \live (see the variable). Notifies \retrigAt.
    retrigAt_ { |mode|
        if(#[\barLine, \live].includes(mode).not) {
            ("MegaSADrums: retrigAt is \\barLine or \\live, not " ++ mode.asCompileString).warn;
            ^this
        };
        retrigAt = mode;
        this.prNotify(\retrigAt, mode);
    }

    // The Live set's pattern back. Notifies \pattern, which and \steps, which.
    resetPattern { |which|
        if(this.prWhichOk(which, true).not) { ^this };
        this.prReplacePattern(which, MegaSASteps.livePattern(which));
    }

    // A whole pattern from data (a preset's), fail-soft by field
    // (MegaSASteps.cleanPattern); `warnings` collects the corrections.
    setPattern { |which, data, warnings|
        if(this.prWhichOk(which, true).not) { ^this };
        this.prReplacePattern(which, MegaSASteps.cleanPattern(data, which, warnings));
    }

    // Has anything in the pattern moved off the Live set's?
    edited { |which|
        ^if(this.prWhichOk(which, false)) { this.class.prDiffers(patterns[which], livePatterns[which]) } { false }
    }

    // A whole pattern in (a preset, the kept drums, the Live set's). Before the
    // transport has ever played that is the device's stored state, which Live
    // restores before it arms the resync of the first Clock Speed or Shuffle
    // Length edit: such a load at boot leaves that edit still to come.
    prReplacePattern { |which, new|
        var old = patterns[which], arm = timeShiftArm[which];
        var moved = this.class.timingParams.select { |n|
            MegaSASteps.getParam(old, n) != MegaSASteps.getParam(new, n)
        };
        patterns[which] = new;
        if(moved.notEmpty) { this.prRetime(which, moved) };
        if(epochCount == 0) { timeShiftArm[which] = arm };
        this.prNotify(\pattern, which);
        this.prNotify(\steps, which);
    }

    // In the device the step index is a pure function of the song position, so
    // after a Clock Speed or shuffle edit the pattern carries on at the first
    // step whose new tick is after the last one decided, keeping its offset (the
    // device's stale offset). The first Clock Speed or Shuffle Length edit of a
    // pattern also arms a resync, as Live's does.
    prRetime { |which, names|
        var pat = patterns[which], cur = cursors[which], last = stepLogs[which].last, s, offs;
        if(cur.notNil and: { last.notNil } and: { last[\epoch] == cur[\epoch] }) {
            s = MegaSASteps.stepTicks[pat[\clockSpeed]];
            offs = MegaSASteps.shuffleOffsets(pat[\shuffle], pat[\shuffleLength], pat[\globalShuffle]);
            cur = cur.copy;
            cur[\n] = MegaSASteps.firstStepAfter(last[\tick], s, offs, pat[\shuffleLength]);
            cursors[which] = cur;
        };
        if(timeShiftArm[which] and: { names.includes(\clockSpeed) or: { names.includes(\shuffleLength) } }) {
            timeShiftArm[which] = false;
            if(cursors[which].notNil) {
                cur = cursors[which].copy;
                cur[\armed] = true;
                cursors[which] = cur;
            };
        };
    }

    prWhichOk { |which, loud|
        if(patterns.includesKey(which ? \none)) { ^true };
        if(loud) { ("MegaSADrums: no pattern " ++ which ++ "; there are \\main and \\break.").warn };
        ^false
    }

    prLaneOk { |which, lane, loud|
        if(this.prWhichOk(which, loud).not) { ^false };
        if(lane.isInteger and: { lane >= 0 } and: { lane <= 3 }) { ^true };
        if(loud) { ("MegaSADrums: no lane " ++ lane ++ "; lanes are 0..3.").warn };
        ^false
    }

    prSubLaneOk { |which, sub, lane, loud|
        if(this.prLaneOk(which, lane, loud).not) { ^false };
        if(MegaSASteps.subs.includes(sub)) { ^true };
        if(loud) { ("MegaSADrums: no page " ++ sub ++ "; pages are " ++ MegaSASteps.subs.join(", ") ++ ".").warn };
        ^false
    }

    prStepOk { |which, sub, lane, i, loud|
        if(this.prSubLaneOk(which, sub, lane, loud).not) { ^false };
        if(i.isInteger and: { i >= 0 } and: { i <= 15 }) { ^true };
        if(loud) { ("MegaSADrums: no step " ++ i ++ "; steps are 0..15.").warn };
        ^false
    }

    // ---- State ------------------------------------------------------------

    // PC 17: the steps on or off, from the moment heard (t - loopAudioDelay
    // on the grid). Always notifies \on, also when unchanged, so a toggle that
    // was refused still repaints its button. The onset kit ignores it, as in Live.
    setOn { |flag, now|
        var edge;
        if(alive.not) { ^this };
        now = now ?? { thisThread.seconds };
        edge = now - this.class.loopAudioDelay;
        on = flag == true;
        onHist = this.class.historyFrom(onHist, edge, on);
        this.prRequest([\cut, edge]);
        this.prNotify(\on, on);
    }

    toggleOn { |now| this.setOn(on.not, now) }

    // ---- The note sequencer (MegaSANoteSeq) --------------------------------
    // Its pattern is `notes`; edit it through these, which notify. Edits
    // reach the steps decided from then on (the lead, 100 ms, is already
    // decided), as the drums' do.

    // The sequencer on or off, from the moment heard. Notifies \notesOn.
    setNotesOn { |flag, now|
        var edge;
        if(alive.not) { ^this };
        now = now ?? { thisThread.seconds };
        edge = now - this.class.loopAudioDelay;
        notesOn = flag == true;
        notesHist = this.class.historyFrom(notesHist, edge, notesOn);
        this.prRequest([\cut, edge]);
        this.prNotify(\notesOn, notesOn);
    }

    // A setting of the pattern (MegaSANoteSeq.settingNames). Notifies
    // \noteSetting, name, value.
    setNoteSetting { |name, v|
        var old = notes[name], stored = MegaSANoteSeq.putSetting(notes, name, v);
        if(stored.isNil) {
            ("MegaSADrums: the note sequencer has no setting " ++ name ++ " taking " ++ v.asCompileString).warn;
            ^this
        };
        if((stored != old) and: { MegaSANoteSeq.timingSettings.includes(name) }) { this.prNoteRetime };
        this.prNotify(\noteSetting, name, stored);
    }

    // A lane's setting (MegaSANoteSeq.laneSettingNames). Notifies
    // \noteLaneSetting, lane, name, value.
    setNoteLaneSetting { |lane, name, v|
        var stored = MegaSANoteSeq.putLaneSetting(notes, lane, name, v);
        if(stored.isNil) {
            ("MegaSADrums: the note lane " ++ lane ++ " has no setting " ++ name ++ " taking " ++ v.asCompileString).warn;
            ^this
        };
        this.prNotify(\noteLaneSetting, lane, name, stored);
    }

    // One step's value of a lane, i 0..15. Notifies \noteValue, lane, i, v.
    setNoteValue { |lane, i, v|
        var stored = MegaSANoteSeq.putValue(notes, lane, i, v);
        if(stored.isNil) { ("MegaSADrums: no note lane value " ++ [lane, i, v]).warn; ^this };
        this.prNotify(\noteValue, lane, i, stored);
    }

    // A lane's 16 values at once (an edit tool's). Notifies \noteValues, lane.
    setNoteValues { |lane, values|
        if(MegaSANoteSeq.laneSpecs[lane].isNil or: { values.size != 16 }) {
            ("MegaSADrums: no note lane " ++ lane ++ " for " ++ values.size ++ " values").warn;
            ^this
        };
        values.do { |v, i| MegaSANoteSeq.putValue(notes, lane, i, v) };
        this.prNotify(\noteValues, lane);
    }

    // A step on or off, i 0..15. Notifies \noteStep, i, flag.
    setNoteStep { |i, flag|
        if(i.isInteger.not or: { i < 0 } or: { i > 15 } or: { flag.isKindOf(Boolean).not }) {
            ("MegaSADrums: no note step " ++ [i, flag]).warn;
            ^this
        };
        notes[\steps][i] = flag;
        this.prNotify(\noteStep, i, flag);
    }

    // A whole pattern (a copy of it). Notifies \notes.
    setNotes { |pat|
        var timing = MegaSANoteSeq.timingSettings.any { |k| pat[k] != notes[k] };
        notes = MegaSANoteSeq.copyPattern(pat);
        MegaSANoteSeq.keepRange(notes);
        if(timing) { this.prNoteRetime };
        this.prNotify(\notes);
    }

    // Where the sequencer is at grid time t (default: heard now), as (n:,
    // main:, lanes:), or nil where the transport does not play.
    notePlayheadAt { |t|
        var found;
        t = t ?? { this.gridNow };
        if(this.prPlayingAt(t).not) { ^nil };
        found = noteHeads.reverse.detect { |e| e[\time] <= (t + 1e-9) };
        ^found !? { |e| (n: e[\n], main: e[\main], lanes: e[\lanes]) }
    }

    // The step the patterns are on at grid time t (default: the one heard now),
    // as (which:, n:, ls:): the pattern in force there (or `which`'s), its step
    // index since the transport's start and its lane step. nil when the
    // transport does not play there.
    playheadAt { |t, which|
        var ring, found;
        t = t ?? { this.gridNow };
        if(this.prPlayingAt(t).not) { ^nil };
        which = which ?? { this.prPatternAt(t) };
        ring = playheads[which];
        if(ring.isNil) { ^nil };
        found = ring.reverse.detect { |e| e[\time] <= (t + 1e-9) };
        ^found !? { |e| (which: which, n: e[\n], ls: e[\ls]) }
    }

    // The grid time being heard now.
    gridNow { ^wallClock.value - this.prStampDelta }

    // ---- Kits -------------------------------------------------------------
    // slot: \steps (Rhythmic Steps' kit) or \onset (the onset notes' kit).

    // Every kit file in `dir`, read: key -> (key:, name:, description:,
    // source:, groups:, pads:, hasRepeats:, readable:, warnings:). Reading
    // never posts; a kit that does not read is listed with readable false.
    *scanKits { |dir|
        var out = IdentityDictionary.new;
        MegaSAKit.keysIn(dir).do { |key|
            var notes = List.new;
            var kit = MegaSAKit.read(MegaSAKit.fileFor(dir, key), notes);
            out.put(key, (key: key,
                name: (kit !? { |k| k.name }) ? key.asString,
                description: (kit !? { |k| k.description }) ? "",
                source: kit !? { |k| k.source },
                groups: kit !? { |k| k.groups },
                pads: (kit !? { |k| k.notes }) ? [],
                hasRepeats: (kit !? { |k| k.hasRepeats }) ? false,
                readable: kit.notNil,
                // megalooper ships a kit's map, never its samples: is one of
                // them on this Mac?
                audio: (kit !? { |k| k.files(dir).any { |p| File.exists(p) } }) ? false,
                warnings: notes.asArray));
        };
        ^out
    }

    // The reverb's impulse responses live in the kits folder (_ir/), so a new
    // folder once built reads them again.
    kitDir_ { |dir|
        var moved = dir != kitDir;
        kitDir = dir;
        kitIndex = nil;
        if(moved and: { built } and: { autoIR }) { this.reloadReverb };
    }

    kitKeys { ^this.prKitIndex.keys.asArray.sort }

    kitInfo { |key| ^key !? { |k| this.prKitIndex[k.asSymbol] } }

    // The kits that can sound on this Mac: those with a sample of theirs in
    // the kits folder. megalooper ships every kit's map and no audio (the
    // kits it was built on play Ableton's), so on a fresh clone there are
    // none, and the Drums pane says so and shows nothing else.
    kitsWithAudio { ^this.kitKeys.select { |k| this.kitInfo(k)[\audio] == true } }

    // Read the folder again (a kit added while running).
    rescanKits { kitIndex = nil; ^this.prKitIndex }

    prKitIndex { ^kitIndex ?? { kitIndex = this.class.scanKits(kitDir) } }

    // The key asked for last (the menu's), or nil.
    kit { |slot| ^if(this.prSlotOk(slot, false)) { kitRequested[slot] } }

    // The MegaSAKit playing in the slot, or nil.
    kitFor { |slot| ^if(this.prSlotOk(slot, false)) { kitObjects[slot] } }

    // Is the slot empty because it was asked to be (setKit(slot, nil): the
    // Drums tab's "— none —", a preset's or the kept drums' "none"), rather
    // than never given a kit? A boot fills only the slots never given one.
    kitEmptied { |slot|
        ^this.prSlotOk(slot, false) and: { kitRequested[slot].isNil } and: { kitSerials[slot] > 0 }
    }

    // How a preset names a slot without a kit.
    *noKit { ^"none" }

    kitState { |slot| ^if(this.prSlotOk(slot, false)) { kitStates[slot] } }

    // Load a kit by key and swap it in when its buffers are in: notifies \kit,
    // slot, key at once and \kitState, slot, state as it goes (\loading, then
    // \ready \partial \missing or \failed). action.(drums, state) hears the
    // final state. Each request has a serial: one overtaken by a later request
    // is dropped when it completes, its buffers freed if nothing else uses
    // them. The swap happens between two pumps, so no step plays half one kit.
    setKit { |slot, key, action|
        var serial, kit, path;
        if(alive.not or: { this.prSlotOk(slot, true).not }) { ^this };
        kitSerials[slot] = kitSerials[slot] + 1;
        serial = kitSerials[slot];
        if(key.isNil) {
            kitRequested[slot] = nil;
            kitObjects[slot] = nil;
            this.prNotify(\kit, slot, nil);
            this.prKitState(slot, \unset);
            this.prReleaseBuffers;
            action.value(this, \unset);
            ^this
        };
        key = key.asSymbol;
        kitRequested[slot] = key;
        this.prNotify(\kit, slot, key);
        path = kitDir !? { |d| MegaSAKit.fileFor(d, key) };
        kit = path !? { |p| MegaSAKit.read(p) };
        if(kit.isNil) {
            ("MegaSADrums: no kit " ++ key ++ " to read in " ++ kitDir ++ "; the " ++ slot
                ++ " kit is silent.").warn;
            kitObjects[slot] = nil;
            this.prKitState(slot, \missing);
            this.prReleaseBuffers;
            action.value(this, \missing);
            ^this
        };
        loadingKits[slot] = kit;
        this.prKitState(slot, \loading);
        kit.load(server, kitDir, bufferCache, { |k, state|
            if(state != \loading) { this.prKitLoaded(slot, serial, k, state, action) };
        }, kitReader, readsInFlight);
    }

    prKitLoaded { |slot, serial, kit, state, action|
        if(alive.not) {
            // Kits sharing a file share its buffer, and free freed the cache:
            // only what is still allocated.
            kit.buffers.do { |b| if(b.bufnum.notNil) { b.free } };
            ^this
        };
        if(loadingKits[slot] === kit) { loadingKits[slot] = nil };
        if(serial != kitSerials[slot]) {
            this.prReleaseBuffers;
            ^this
        };
        kitObjects[slot] = kit;
        this.prKitState(slot, state);
        this.prReleaseBuffers;
        action.value(this, state);
    }

    prKitState { |slot, state|
        kitStates[slot] = state;
        this.prNotify(\kitState, slot, state);
    }

    // The pads of the slot's kit, by note.
    pads { |slot| ^((this.kitFor(slot) !? { |k| k.notes }) ? []) }

    padName { |slot, note| ^this.kitFor(slot) !? { |k| k.padName(note) } }

    // A pad's trim in dB, -24..+12, kept per kit key. Notifies \padTrim, slot,
    // note, db.
    padTrim { |slot, note| ^((this.prTrimTable(padTrims, slot) !? { |t| t[note] }) ? 0) }

    setPadTrim { |slot, note, db|
        var table;
        if(this.prSlotOk(slot, true).not) { ^this };
        if(note.isNumber.not or: { db.isNumber.not } or: { db.isNaN }) {
            ("MegaSADrums: a pad trim is a note and dB, not " ++ [note, db].asCompileString).warn;
            ^this
        };
        table = this.prTrimTable(padTrims, slot, true);
        if(table.isNil) { ("MegaSADrums: no " ++ slot ++ " kit to trim.").warn; ^this };
        table.put(note.asInteger, db.clip(-24, 12));
        this.prNotify(\padTrim, slot, note.asInteger, table[note.asInteger]);
    }

    // A group's trim in dB, -24..+12, per kit key: the layer trim of a kit
    // with two (the KJ stand-ins under Kit-Carbon). Notifies \groupTrim, slot,
    // group, db.
    groupTrim { |slot, group| ^((this.prTrimTable(groupTrims, slot) !? { |t| t[group ? \none] }) ? 0) }

    setGroupTrim { |slot, group, db|
        var table;
        if(this.prSlotOk(slot, true).not) { ^this };
        if(group.isNil or: { db.isNumber.not } or: { db.isNaN }) {
            ("MegaSADrums: a group trim is a group and dB, not " ++ [group, db].asCompileString).warn;
            ^this
        };
        table = this.prTrimTable(groupTrims, slot, true);
        if(table.isNil) { ("MegaSADrums: no " ++ slot ++ " kit to trim.").warn; ^this };
        table.put(group.asSymbol, db.clip(-24, 12));
        this.prNotify(\groupTrim, slot, group.asSymbol, table[group.asSymbol]);
    }

    prTrimTable { |tables, slot, create = false|
        var key = this.kit(slot);
        if(key.isNil) { ^nil };
        if(create and: { tables[key].isNil }) { tables.put(key, IdentityDictionary.new) };
        ^tables[key]
    }

    // Beat Repeat on the kits that have it, from the moment heard (now -
    // loopAudioDelay on the grid, as PC 17): repeats from there on are
    // cancelled, or sent if still to come. Notifies \repeats, flag.
    setRepeats { |flag, now|
        var edge;
        repeats = flag == true;
        if(alive) {
            now = now ?? { thisThread.seconds };
            edge = now - this.class.loopAudioDelay;
            repeatHist = this.class.historyFrom(repeatHist, edge, repeats);
            this.prRequest([\cut, edge]);
        };
        this.prNotify(\repeats, repeats);
    }

    // Beat Repeat's capture points on the reading's bars (\bars) or on Live's
    // grid of 8 quarter notes (\live): see repeatGrid. From the next capture
    // whose slice has not ended; those decided keep their repeats. Notifies
    // \repeatGrid, mode.
    setRepeatGrid { |mode|
        var wall, ep;
        if(#[\bars, \live].includes(mode).not) {
            ("MegaSADrums: repeatGrid is \\bars or \\live, not " ++ mode.asCompileString).warn;
            ^this
        };
        if(mode == repeatGrid) { ^this };
        repeatGrid = mode;
        if(alive) {
            wall = wallClock.value;
            ep = this.prEpochAt(wall);
            ep !? { captureCursor = (epoch: ep[\id], c: this.prCaptureIndexAt(ep, (this.prTicksAt(ep, wall) - 120).max(0))) };
        };
        this.prNotify(\repeatGrid, mode);
    }

    prSlotOk { |slot, loud|
        if((slot == \steps) or: { slot == \onset }) { ^true };
        if(loud) { ("MegaSADrums: no kit slot " ++ slot ++ "; there are \\steps and \\onset.").warn };
        ^false
    }

    // Every cached buffer no kit in use (or being loaded) plays is freed a
    // second after its last voice can have ended.
    prReleaseBuffers {
        var wall = wallClock.value, used = this.prPathsInUse;
        bufferCache.keys.do { |path|
            if(used.includes(path)) { bufferFreeAt.removeAt(path) } {
                if(bufferFreeAt[path].isNil) {
                    bufferFreeAt.put(path, (wall + 1).max((bufferEnds[path] ? 0) + 1));
                };
            };
        };
    }

    // Each kit's files resolved against the folder it was loaded from, as its
    // buffers are cached: kitDir may have moved since.
    prPathsInUse {
        var used = IdentitySet.new;
        (kitObjects.values ++ loadingKits.values).do { |k|
            k !? { k.files(k.root).do { |p| used.add(p.asSymbol) } };
        };
        ^used
    }

    prFreeBuffers { |wall|
        var due, used;
        if(bufferFreeAt.isEmpty) { ^this };
        due = bufferFreeAt.keys.select { |path| bufferFreeAt[path] <= wall };
        if(due.isEmpty) { ^this };
        used = this.prPathsInUse;
        due.do { |path|
            bufferFreeAt.removeAt(path);
            if(used.includes(path).not) {
                bufferEnds.removeAt(path);
                bufferCache.removeAt(path) !? { |b| b.free };
            };
        };
    }

    // When the last voice of each buffer a hit plays can end.
    prNoteBufferUse { |kit, layers, stamp|
        layers.do { |layer|
            var path = kit.pathFor(layer).asSymbol;
            var end = stamp + ((kit.soundingDur(layer) ? 10) + 0.005);
            if((bufferEnds[path] ? inf.neg) < end) { bufferEnds.put(path, end) };
        };
    }

    // ---- Mix --------------------------------------------------------------
    // Both notify \mix, name, value.

    // The drums' reverb, 0..1, linear (Live's 15.08 %).
    setReverbMix { |v|
        if(v.isNumber.not or: { v.isNaN }) { ("MegaSADrums: reverbMix needs a number, not " ++ v).warn; ^this };
        reverbMix = v.clip(0, 1);
        fxSynth !? { |s| s.set(\mix, reverbMix) };
        this.prNotify(\mix, \reverbMix, reverbMix);
    }

    // Every hit later (or earlier) by this much, -15..+50 ms: the drums'
    // alignment to the loop as heard.
    setOffsetMs { |v|
        if(v.isNumber.not or: { v.isNaN }) { ("MegaSADrums: offsetMs needs a number, not " ++ v).warn; ^this };
        offsetMs = v.clip(-15, 50);
        this.prNotify(\mix, \offsetMs, offsetMs);
    }

    // ---- The dice ----------------------------------------------------------
    // Every random part of the steps (chance, alt, roll, slide), the note
    // sequencer's and Beat Repeat's draws are a pure function of the epoch's
    // seed and the step, and every Start (a new epoch) draws a new seed. Kept,
    // the seed heard now is every Start's from then on, so a variation the
    // duo liked comes back: the same notes from bar 1, Start after Start, and
    // after a boot when the drums are kept or saved with it.

    // true: keep the dice of the epoch last begun (new ones if none has);
    // false: new dice from the next Start. The epoch playing goes on as it
    // is either way.
    keepDice { |flag|
        this.setDice(if(flag == true) { keptDice ?? { lastSeed ?? { 2147483647.rand } } } { nil });
    }

    // A seed (an Integer, 0..2147483647) every Start plays from now on, or
    // nil (or false) for new dice every Start. From the next Start.
    setDice { |seed|
        seed = if(seed.isInteger and: { seed >= 0 }) { seed } { nil };
        if(seed != keptDice) {
            keptDice = seed;
            this.prNotify(\dice, keptDice);
        };
    }

    // ---- Presets and Keep -------------------------------------------------
    // One preset is the drums as a player sets them up: both patterns whole
    // (every page, the per-page lengths, the global lengths and locks, the
    // lanes' settings and the timing), the two kits by key, every pad and
    // group trim (per kit key, as they are kept), Beat Repeat's switch and
    // grid, the reverb, the offset and the dice (kept: the seed; false: new
    // ones); one SC literal in `dir`/<slug>.scd, written and read like
    // MegaSA's effects presets. Not in it: PC 17's on/off and the break, which are the
    // performance's, and the mixer's levels, which are MegaSA's. A preset
    // naming other kits switches to them (setKit).
    //
    // Loading fails soft by field, as the Looper's validators do (a
    // hand-edited file is far more often stale than corrupt): a value out of
    // range is held to it, a field that is not usable keeps what is playing
    // (a pattern's fields: the Live set's, MegaSASteps.cleanPattern), a key
    // that is no field is ignored, each said once in the post window (or put
    // into `warnings`, a List, when one is given). A file that is not a
    // preset, or is of a newer version, is refused whole and changes nothing.
    //
    // keep(path) is the same save in one file (sa/kept-drums/drums.scd in your megalooper folder by
    // default), which a boot loads with loadKept, as the effects' kept sound.

    *presetVersion { ^1 }

    *defaultKeptPath { ^MegaFiles.userRoot +/+ "sa" +/+ "kept-drums" +/+ "drums.scd" }

    presetSlug { |name| ^Looper.presetSlug(name) }

    presetPath { |dir, name| ^dir +/+ this.presetSlug(name) ++ ".scd" }

    // Slugs only: interpreting every file to name a menu would run whatever
    // code it holds.
    presetNames { |dir|
        if(dir.isNil or: { File.exists(dir).not }) { ^[] };
        ^(dir +/+ "*.scd").pathMatch.collect { |p| PathName(p).fileNameWithoutExtension }.sort
    }

    // Answers the slug, or nil if nothing was written.
    savePreset { |dir, name|
        var slug;
        if(dir.isNil) { "MegaSADrums preset: no directory given.".warn; ^nil };
        slug = this.presetSlug(name);
        if(this.prWritePreset(dir +/+ slug ++ ".scd", name).not) { ^nil };
        ("MegaSADrums preset saved: " ++ slug ++ " (" ++ this.prPresetSummary ++ ").").postln;
        ^slug
    }

    // True once applied; false, with nothing changed, if the file is missing
    // or not a preset.
    loadPreset { |dir, slug, warnings|
        if(dir.isNil) { "MegaSADrums preset: no directory given.".warn; ^false };
        ^this.prReadPreset(this.presetPath(dir, slug), warnings, true)
    }

    deletePreset { |dir, slug|
        var path;
        if(dir.isNil) { ^false };
        path = this.presetPath(dir, slug);
        if(File.exists(path).not) { ^false };
        File.delete(path);
        ^true
    }

    // Keep the drums for the next boot. True once written.
    keep { |path|
        path = path ?? { this.class.defaultKeptPath };
        if(path.isNil) { "MegaSADrums: nowhere to keep the drums.".warn; ^false };
        ^this.prWritePreset(path, "kept")
    }

    // The kept drums, at boot: false (and nothing said) when nothing was
    // kept, as the first boot finds it.
    loadKept { |path, warnings|
        path = path ?? { this.class.defaultKeptPath };
        if(path.isNil or: { File.exists(path).not }) { ^false };
        ^this.prReadPreset(path, warnings, true)
    }

    // What a preset holds, as an Event: kits as Strings (keys may have
    // dashes; "none" for a slot left without a kit, which an Event literal
    // could not hold as nil), trims as [kit, note or group, dB] rows.
    presetData { |name|
        var kitOf = { |slot| (kitRequested[slot] !? { |k| k.asString }) ? this.class.noKit };
        var rows = { |tables|
            var out = List.new;
            tables.keys.asArray.sort.do { |kit|
                tables[kit].keys.asArray.sort.do { |k|
                    out.add([kit.asString, if(k.isKindOf(Symbol)) { k.asString } { k }, tables[kit][k].asFloat]);
                };
            };
            out.asArray
        };
        ^(version: this.class.presetVersion, name: (name ? "").asString, savedAt: Date.getDate.stamp,
            stepsKit: kitOf.(\steps), onsetKit: kitOf.(\onset),
            repeats: repeats, reverbMix: reverbMix.asFloat, offsetMs: offsetMs.asFloat,
            dice: keptDice ? false, repeatGrid: repeatGrid.asString,
            padTrims: rows.(padTrims), groupTrims: rows.(groupTrims),
            main: patterns[\main].deepCopy, break: patterns[\break].deepCopy)
    }

    // The file: comments first and inside only (a trailing comment would
    // leave interpret answering nil), one field a line, the patterns a lane a
    // line.
    presetString { |data|
        var field = { |k, v| "    " ++ k ++ ": " ++ v };
        ^"// megalooper drums preset — a SuperCollider literal, safe to hand-edit.\n"
            ++ "// Out-of-range values are corrected on load (see the post window). The kits\n"
            ++ "// are named by key (presets/sa/drums/kits/<key>.json); trims are in dB, per kit.\n"
            ++ "(\n"
            ++ [
                field.(\version, data[\version]),
                field.(\name, data[\name].asCompileString),
                field.(\savedAt, data[\savedAt].asCompileString),
                "    // The kits (\"none\": no kit, a silent slot), the repeats, the reverb (0..1,\n"
                    "    // linear) and the offset (ms)\n"
                    ++ field.(\stepsKit, data[\stepsKit].asCompileString),
                field.(\onsetKit, data[\onsetKit].asCompileString),
                field.(\repeats, data[\repeats].asCompileString),
                "    // Where the repeats capture: \"bars\" (every 2 of the reading's) or \"live\" (8 quarters)\n"
                    ++ field.(\repeatGrid, (data[\repeatGrid] ? "bars").asString.asCompileString),
                field.(\reverbMix, data[\reverbMix].asCompileString),
                field.(\offsetMs, data[\offsetMs].asCompileString),
                "    // The dice: a seed every Start plays, or false for new dice every Start\n"
                    ++ field.(\dice, (data[\dice] ? false).asCompileString),
                "    // Trims: [kit, note, dB] and [kit, layer group, dB], -24..+12 dB\n"
                    ++ field.(\padTrims, data[\padTrims].asCompileString),
                field.(\groupTrims, data[\groupTrims].asCompileString),
                "    // The step sequencer's two patterns; lane 0 is the device's lane 1\n"
                    ++ field.(\main, this.prPatternString(data[\main], "    ")),
                field.(\break, this.prPatternString(data[\break], "    "))
            ].join(",\n") ++ "\n"
            ++ ")\n"
    }

    prPatternString { |p, pad|
        var in1 = pad ++ "    ", in2 = in1 ++ "    ", in3 = in2 ++ "    ";
        var subs = MegaSASteps.subs;
        ^"(\n"
            ++ in1 ++ "steps: (\n"
            ++ subs.collect { |sub|
                in2 ++ sub ++ ": [\n"
                    ++ p[\steps][sub].collect { |lane| in3 ++ lane.asCompileString }.join(",\n") ++ "\n"
                    ++ in2 ++ "]"
            }.join(",\n") ++ "\n"
            ++ in1 ++ "),\n"
            ++ in1 ++ "lengths: (" ++ subs.collect { |sub| sub ++ ": " ++ p[\lengths][sub].asCompileString }.join(", ")
            ++ "),\n"
            ++ #[\globalLength, \lock, \note, \altNote, \delay, \mute, \clockSpeed, \rollRate, \shuffle,
                \shuffleLength, \globalShuffle, \autoRetrigger, \autoTriggerRate].collect { |k|
                in1 ++ k ++ ": " ++ p[k].asCompileString
            }.join(",\n") ++ "\n"
            ++ pad ++ ")"
    }

    prWritePreset { |path, name|
        var file, dir = PathName(path).pathOnly;
        if(File.exists(dir).not) { File.mkdir(dir) };
        file = File(path, "w");
        if(file.isOpen.not) { ("MegaSADrums preset: could not write " ++ path).warn; ^false };
        file.write(this.presetString(this.presetData(name)));
        file.close;
        ^true
    }

    prReadPreset { |path, warnings, loud = true|
        var notes = List.new, data, clean;
        if(File.exists(path).not) {
            if(loud) { ("MegaSADrums preset: no such preset " ++ path.basename).warn };
            ^false
        };
        // On a stack of its own (Looper.readPresetFile): code that throws
        // must not leave half a literal on the caller's.
        data = Looper.readPresetFile(path, { |why| notes.add(why) });
        clean = this.prValidatePreset(data, notes);
        if(clean.isNil) {
            this.prPresetReport(path, warnings, "rejected — ", notes);
            ^false
        };
        this.prApplyPreset(clean);
        if(notes.notEmpty) { this.prPresetReport(path, warnings, notes.size.asString ++ " correction(s) — ", notes) };
        ^true
    }

    prPresetReport { |path, warnings, head, notes|
        if(warnings.notNil) { warnings.addAll(notes) } {
            ("MegaSADrums preset " ++ path.basename ++ ": " ++ head ++ notes.join("; ")).warn;
        };
    }

    // The whole check, before anything is touched: an Event of what to apply
    // (a field left out keeps what is playing), or nil to refuse the file.
    prValidatePreset { |data, notes|
        var clean, version, known;
        var number = { |key, lo, hi|
            var v = data[key];
            case
            { v.isNil } { nil }
            { v.isNumber.not or: { v.isNaN } or: { v.abs == inf } } {
                notes.add(key.asString ++ " " ++ v.asCompileString ++ " is not a number (kept)");
                nil
            }
            { (v < lo) or: { v > hi } } {
                notes.add(key.asString ++ " " ++ v ++ " -> " ++ v.clip(lo, hi) ++ " (range)");
                v.clip(lo, hi)
            }
            { v }
        };
        // A kit's key, \none for "none" (or false: the slot emptied on
        // purpose), or nil to keep the kit playing.
        var kitKey = { |key, slot|
            var v = data[key];
            case
            { v.isNil } { nil }
            { (v == false) or: { (v.isKindOf(String) or: { v.isKindOf(Symbol) }) and: { v.asString == this.class.noKit } } } {
                \none
            }
            { (v.isKindOf(String) or: { v.isKindOf(Symbol) }).not or: { v.asString.isEmpty } } {
                notes.add(key.asString ++ " " ++ v.asCompileString ++ " is not a kit's key (kept)");
                nil
            }
            { this.kitKeys.includes(v.asSymbol).not } {
                notes.add(key.asString ++ ": no kit " ++ v ++ " in " ++ kitDir ++ " (the " ++ slot ++ " kit stays)");
                nil
            }
            { v.asSymbol }
        };
        if(data.isKindOf(Dictionary).not) { notes.add("not a preset (expected an Event)"); ^nil };
        version = data[\version] ? 1;
        if(version.isNumber.not) { notes.add("its version " ++ version.asCompileString ++ " is not a number"); ^nil };
        if(version.asInteger > this.class.presetVersion) {
            notes.add("version " ++ version ++ " is newer than this build (" ++ this.class.presetVersion ++ ")");
            ^nil
        };
        clean = (name: (data[\name] ? "").asString);
        [\main, \break].do { |which|
            var said = List.new;
            if(data[which].isNil) {
                notes.add("no " ++ which ++ " pattern -> the default");
                clean.put(which, MegaSASteps.livePattern(which));
            } {
                clean.put(which, MegaSASteps.cleanPattern(data[which], which, said));
                said.do { |s| notes.add(which.asString ++ ": " ++ s) };
            };
        };
        clean.put(\stepsKit, kitKey.(\stepsKit, \steps));
        clean.put(\onsetKit, kitKey.(\onsetKit, \onset));
        clean.put(\padTrims, this.prCleanTrims(data[\padTrims], \padTrims, notes, { |k|
            if(k.isNumber and: { (k - k.round).abs < 1e-9 } and: { k >= 0 } and: { k <= 127 }) { k.round.asInteger }
        }));
        clean.put(\groupTrims, this.prCleanTrims(data[\groupTrims], \groupTrims, notes, { |k|
            if((k.isKindOf(String) or: { k.isKindOf(Symbol) }) and: { k.asString.notEmpty }) { k.asSymbol }
        }));
        case
        { data[\repeats].isNil } { }
        { (data[\repeats] == true) or: { data[\repeats] == false } } { clean.put(\repeats, data[\repeats]) }
        { notes.add("repeats " ++ data[\repeats].asCompileString ++ " is not true or false (kept)") };
        clean.put(\reverbMix, number.(\reverbMix, 0, 1));
        clean.put(\offsetMs, number.(\offsetMs, -15, 50));
        case
        { data[\dice].isNil } { }
        { data[\dice] == false } { clean.put(\dice, false) }
        { data[\dice].isInteger and: { data[\dice] >= 0 } } { clean.put(\dice, data[\dice]) }
        { notes.add("dice " ++ data[\dice].asCompileString ++ " is not a seed (0 or more) or false (kept)") };
        case
        { data[\repeatGrid].isNil } { }
        { #["bars", "live"].includesEqual(data[\repeatGrid].asString) } { clean.put(\repeatGrid, data[\repeatGrid].asSymbol) }
        { notes.add("repeatGrid " ++ data[\repeatGrid].asCompileString ++ " is not \"bars\" or \"live\" (kept)") };
        known = #[\version, \name, \savedAt, \main, \break, \stepsKit, \onsetKit, \padTrims, \groupTrims,
            \repeats, \repeatGrid, \reverbMix, \offsetMs, \dice];
        data.keys.do { |k| if(known.includes(k).not) { notes.add(k.asString ++ " is no drums field (ignored)") } };
        ^clean
    }

    // Trim rows [kit, key, dB] as the tables keep them (kit -> key -> dB), or
    // nil for no field (the trims in force stay). A row that is not usable is
    // dropped, a level out of -24..+12 held to it.
    prCleanTrims { |rows, label, notes, keyOf|
        var out;
        if(rows.isNil) { ^nil };
        if(rows.isKindOf(SequenceableCollection).not or: { rows.isString }) {
            notes.add(label.asString ++ " is not a list of [kit, key, dB] (the trims stay)");
            ^nil
        };
        out = IdentityDictionary.new;
        rows.do { |row|
            var kit, key, db;
            if(row.isKindOf(SequenceableCollection) and: { row.isString.not } and: { row.size == 3 }) {
                kit = row[0];
                key = keyOf.(row[1]);
                db = row[2];
            };
            if(((kit.isKindOf(String) or: { kit.isKindOf(Symbol) }) and: { kit.asString.notEmpty }).not
                or: { key.isNil } or: { db.isNumber.not } or: { db.isNaN } or: { db.abs == inf }) {
                notes.add(label.asString ++ " " ++ row.asCompileString ++ " is not [kit, key, dB] (dropped)");
            } {
                if((db < -24) or: { db > 12 }) {
                    notes.add(label.asString ++ " " ++ row.asCompileString ++ " -> " ++ db.clip(-24, 12) ++ " dB (range)");
                };
                if(out[kit.asSymbol].isNil) { out.put(kit.asSymbol, IdentityDictionary.new) };
                out[kit.asSymbol].put(key, db.clip(-24, 12).asFloat);
            };
        };
        ^out
    }

    // What presetData answered, applied as a preset file is: checked whole
    // first, and refused (false, nothing changed) if it does not hold.
    // `warnings`, a List, gets the corrections. An AI app's revert
    // (MegaRemote) puts the drums back so.
    applyPresetData { |data, warnings|
        var notes = List.new, clean = this.prValidatePreset(data, notes);
        warnings !? { |w| w.addAll(notes) };
        if(clean.isNil) { ^false };
        this.prApplyPreset(clean);
        ^true
    }

    // Apply a checked preset through the setters, so every change reaches
    // the server and its notification: the kits first (setKit, if it names
    // others), the trims (each one that moved for the kits in the slots
    // notified), the patterns, Beat Repeat and its grid, the reverb, the
    // offset and the dice.
    prApplyPreset { |clean|
        var oldPads = padTrims, oldGroups = groupTrims;
        [[\stepsKit, \steps], [\onsetKit, \onset]].do { |pair|
            var key = clean[pair[0]];
            case
            { key == \none } { if(this.kitEmptied(pair[1]).not) { this.setKit(pair[1], nil) } }
            { key.notNil and: { key != this.kit(pair[1]) } } { this.setKit(pair[1], key) };
        };
        clean[\padTrims] !? { |t| padTrims = t };
        clean[\groupTrims] !? { |t| groupTrims = t };
        [\steps, \onset].do { |slot|
            var key = this.kit(slot);
            key !? {
                this.prTrimsMoved(oldPads[key], padTrims[key]).do { |note|
                    this.prNotify(\padTrim, slot, note, this.padTrim(slot, note));
                };
                this.prTrimsMoved(oldGroups[key], groupTrims[key]).do { |group|
                    this.prNotify(\groupTrim, slot, group, this.groupTrim(slot, group));
                };
            };
        };
        [\main, \break].do { |which| this.prReplacePattern(which, clean[which]) };
        clean[\repeats] !? { |flag| if(flag != repeats) { this.setRepeats(flag) } };
        clean[\repeatGrid] !? { |mode| this.setRepeatGrid(mode) };
        clean[\reverbMix] !? { |v| this.setReverbMix(v) };
        clean[\offsetMs] !? { |v| this.setOffsetMs(v) };
        clean[\dice] !? { |v| this.setDice(v) };
    }

    // The keys whose trims differ between two tables (key -> dB, either nil).
    prTrimsMoved { |a, b|
        var keys = IdentitySet.new;
        a !? { a.keys.do { |k| keys.add(k) } };
        b !? { b.keys.do { |k| keys.add(k) } };
        ^keys.asArray.select { |k| ((a !? { |t| t[k] }) ? 0) != ((b !? { |t| t[k] }) ? 0) }
    }

    // For the post window: what a save holds, in a few words.
    prPresetSummary {
        var said = [\main, \break].collect { |w| w.asString ++ (if(this.edited(w)) { " edited" } { " as shipped" }) };
        ^said.join(", ") ++ "; kits " ++ (this.kit(\steps) ? "none") ++ " and " ++ (this.kit(\onset) ? "none")
    }

    // ---- The Looper -------------------------------------------------------

    // Listen to the Looper's break, readings, reverse, state and session
    // recording, and become its MIDI port and its onset-note sink. A Start
    // relocates nothing here, so the Looper may restart the drums during a
    // session recording too.
    attach { |aLooper|
        this.detach;
        if(alive.not or: { aLooper.isNil }) { ^this };
        looper = aLooper;
        controller = SimpleController(aLooper)
            .put(\break, { |obj, what, flag| if(flag == true) { this.breakOpened } { this.breakClosed } })
            .put(\breakEndsAt, { |obj, what, x| x !? { |v| this.breakEndsAt(v) } })
            .put(\reading, { |obj, what, p| if(p.notNil) { this.readingArmed(p) } { this.readingCleared } })
            .put(\reverse, { |obj, what, flag| this.prReversed(flag) })
            .put(\halfTime, { |obj, what, x| this.prHalfTimeChanged })
            .put(\speed, { |obj, what, x| this.prSpeedChanged(x) })
            .put(\state, { |obj, what, st|
                if((st == \recording) and: { newLoopOff } and: { on }) { this.setOn(false) };
                this.prCheckSpawn(wallClock.value) })
            .put(\sessionRecording, { |obj, what, flag| this.prSessionRecording(flag) });
        aLooper.midiOut = transport;
        aLooper.onsetNoteSink = this;
        aLooper.startsRelocate = false;
        lastLam = aLooper.loopStartTime;
        lastSpawnAt = lastLam;
        reversedSinceSpawn = aLooper.reverseFlag == true;
        logState = nil;
    }

    // Let go of the Looper, for another (attach) or none: its MIDI port and
    // its onset sink back to none, its Starts relocating again.
    detach {
        looper !? { |l|
            if(l.midiOut === transport) { l.midiOut = nil };
            if(l.onsetNoteSink === this) { l.onsetNoteSink = nil };
        };
        this.prLetGo;
    }

    prLetGo {
        controller !? { |c| c.remove };
        controller = nil;
        looper !? { |l| l.startsRelocate = true };
        looper = nil;
        logState = nil;
    }

    // ---- The transport (MegaSATransport's calls) --------------------------
    // Every `now` is the calling thread's time, thisThread.seconds by default.

    // A Start: the drums' bar 1 on the loop boundary nearest now + latency. A
    // new epoch from that boundary (the old one plays until then), with new
    // dice, the grid from the Looper's result in force (or a pending reading's
    // landing there). At a landing that restarts, the Start is its confirmation:
    // that origin went in when the reading was armed.
    transportStart { |now|
        var lam, loopDur, boundary, pl, result;
        if(alive.not) { ^this };
        now = now ?? { thisThread.seconds };
        lam = looper !? { |l| l.loopStartTime };
        loopDur = this.prLoopDur;
        boundary = this.class.startBoundary(now, transport.latency, lam, loopDur);
        pl = pendingLanding;
        if(pl.notNil and: { pl[\at].notNil } and: { (pl[\at] - boundary).abs < 0.001 }) {
            if(pl[\kind] == \epoch) { ^this };
            result = pl[\p][\result];
        };
        result = result ?? { (looper !? { |l| l.lastResult }) ?? { analysis } };
        this.prInstallEpoch(boundary, result, loopDur, nil);
    }

    // A Stop: the transport stops from the moment heard. Tails ring.
    transportStop { |now|
        var edge;
        if(alive.not) { ^this };
        now = now ?? { thisThread.seconds };
        edge = now - this.class.loopAudioDelay;
        playHist = this.class.historyFrom(playHist, edge, false);
        this.prRequest([\cut, edge]);
        if(playing) { playing = false; this.prNotify(\playing, false) };
    }

    // The Looper's latest analysis: kept, nothing more. A running transport is
    // re-segmented only by the readings it lands and the Starts it sends.
    setAnalysis { |result, now| analysis = result }

    // ---- The break ----------------------------------------------------------
    // The pattern in force switches where the loop goes silent: the Looper's
    // mute gate sits after its 20 ms limiter, so grid content from t - 0.020 on
    // is what the hole silences.

    // \break true at t (about the stomp).
    breakOpened { |t|
        var wall, old;
        if(alive.not) { ^this };
        t = t ?? { thisThread.seconds };
        wall = wallClock.value;
        rawEnd = nil;
        // A second stomp while the Looper's break is still in force (its end
        // is planned): the hole stays where the first opened it (moving its
        // start would let main hits back into it); only the planned end goes,
        // until the Looper says where the new one is. A stomp in the 20 ms
        // after a planned end, while the old break is still heard, is a new
        // break (the Looper has ended the old one): it carries the break on.
        if(breakEnd.notNil and: { this.prPatternAt(wall - this.class.loopAudioDelay) == \break }) {
            old = breakEnd;
            breakEnd = nil;
            breakHist = this.class.historyFrom(breakHist, old, \break);
            holeHist = this.class.historyFrom(holeHist, old, true);
            this.prRequest([\cut, old]);
        } {
            breakEnd = nil;
            breakHist = this.class.historyFrom(breakHist, t - this.class.loopAudioDelay, \break);
            holeHist = this.class.historyFrom(holeHist, t - this.class.loopAudioDelay, true);
            this.prRequest([\cut, t - this.class.loopAudioDelay]);
        };
        this.prUpdateBreakActive(wall);
    }

    // \breakEndsAt x: the Looper's resume time. It comes from the engine's own
    // phase (fireBreak: queryLoopPhase, then prBreakDuration), so a break
    // always ends on a boundary of the loop as the engine plays it. That is
    // loopStartTime's boundary nearest x while the loop's model holds (no
    // reverse since the engine started) and x is within half a 16th of it.
    // Otherwise the nearest 16th, which every real boundary sits on: after a
    // multiply struck on a pass its factor does not divide, the engine (not
    // respawned, its Phasor keeping its level as \loopFrames grows) wraps
    // whole old loops off loopStartTime's boundaries.
    breakEndsAt { |x, now|
        var lam, loopDur, b;
        if(alive.not or: { x.isNil }) { ^this };
        rawEnd = x;
        lam = looper !? { |l| l.loopStartTime };
        loopDur = this.prLoopDur;
        b = if(this.prLoopValid and: { lam.notNil } and: { loopDur > 0 }) {
            this.class.loopBoundaryNear(x, lam, loopDur)
        };
        breakEnd = if(b.notNil and: { (x - b).abs < (this.prSixteenthAt(x, loopDur) / 2) }) { b } {
            this.prNearestSixteenth(x)
        };
        breakHist = this.class.historyFrom(breakHist, breakEnd, \main);
        holeHist = this.class.historyFrom(holeHist, breakEnd, false);
        this.prRequest([\cut, breakEnd]);
        this.prUpdateBreakActive(wallClock.value);
    }

    // \break false at now: on time it is the planned end, which is in already;
    // otherwise (a stop or a clear cancelled it, or it ended early) the main
    // pattern comes back from the moment heard.
    breakClosed { |now|
        var wall, edge;
        if(alive.not) { ^this };
        now = now ?? { thisThread.seconds };
        wall = wallClock.value;
        if(rawEnd.notNil and: { wall >= (rawEnd - 0.001) }) {
            rawEnd = nil;
            breakEnd = nil;
        } {
            rawEnd = nil;
            breakEnd = nil;
            edge = now - this.class.loopAudioDelay;
            breakHist = this.class.historyFrom(breakHist, edge, \main);
            holeHist = this.class.historyFrom(holeHist, edge, false);
            this.prRequest([\cut, edge]);
        };
        this.prUpdateBreakActive(wall);
    }

    // The Drums tab's Main | BREAK switch: the same switch by hand, from the
    // moment heard (now defaults to wall time), until the Looper's next edge
    // (a planned end still brings the main pattern back).
    setBreakPattern { |flag, now|
        var wall, edge;
        if(alive.not) { ^this };
        wall = wallClock.value;
        now = now ? wall;
        edge = now - this.class.loopAudioDelay;
        breakHist = this.class.historyFrom(breakHist, edge, if(flag == true) { \break } { \main });
        if(breakEnd.notNil and: { breakEnd > edge }) {
            breakHist = this.class.historyFrom(breakHist, breakEnd, \main);
        };
        this.prRequest([\cut, edge]);
        this.prUpdateBreakActive(wall);
    }

    // ---- Readings -----------------------------------------------------------
    // The Looper publishes a reading's landing a loop or more ahead (\reading,
    // an Event: index, result, at, loops, restart). It goes in AHEAD, at its
    // time: a restart as a new epoch, otherwise a new segment of the epoch in
    // force (the step count goes on, the 16th and the numerator change). At the
    // landing the Start (if any) and the analysis are confirmations.

    readingArmed { |p, now|
        if(alive.not) { ^this };
        if(p.isNil) { ^this.readingCleared(now) };
        // One pending landing at a time: a re-arm replaces the one before.
        pendingLanding !? { |pl| pendingLanding = nil; this.prRemoveLanding(pl) };
        pendingLanding = (p: p, at: p[\at], index: p[\index], kind: \none);
        this.prInstallLanding(pendingLanding);
    }

    // A pending landing into the grid at its time, if the transport plays
    // there: a restart as a new epoch, otherwise a segment of the epoch in
    // force (an epoch a Start began right on the landing takes the reading's
    // grid from its start). Where the transport does not play, nothing: a
    // Start after the landing takes the Looper's grid, the reading's by then.
    // A restart onto an epoch begun on the landing is left to the Looper's
    // Start there, which begins it again on the reading's grid (so a reading
    // taken back leaves the first Start's epoch as it was).
    prInstallLanding { |pl|
        var at = pl[\at], p = pl[\p], ep, seg, tick, prev;
        ep = at !? { this.prEpochAt(at) };
        if(ep.isNil or: { this.prPlayingAt(at).not }) { ^this };
        if(p[\restart] == true) {
            if((ep[\t0] - at).abs < 1e-6) { ^this };
            pl[\target] = this.prInstallEpoch(at, p[\result], this.prLoopDur, p);
            pl[\kind] = \epoch;
        } {
            tick = this.prTicksAt(ep, at).round;
            prev = ep[\segs].select { |s| s[\t0] < (at - 1e-6) }.last ?? { ep[\segs].first };
            seg = this.prSegment(at, tick, p[\result], this.prLoopDur, this.prBarAt(prev, tick));
            pl[\replaced] = ep[\segs].select { |s| s[\t0] >= (at - 1e-6) };
            ep[\segs] = ep[\segs].reject { |s| s[\t0] >= (at - 1e-6) }.add(seg);
            pl[\target] = seg;
            pl[\epoch] = ep[\id];
            pl[\kind] = \segment;
            this.prRequest([\rewind, at]);
        };
        // A half-time edge after the landing went with the segments it replaced.
        this.prSyncEdges;
    }

    // A landing's segment out of its epoch again, and what it took the place
    // of (the first segment of an epoch begun on the landing) back.
    prUndoSegment { |pl|
        var ep = this.prEpoch(pl[\epoch]);
        ep !? {
            // Not a half-time edge still to come: prSyncEdges puts the one in
            // force back where it belongs now.
            ep[\segs] = (ep[\segs].reject { |s| s === pl[\target] }
                ++ (pl[\replaced] ? []).reject { |s| s[\edge] == \pending })
                .sort { |a, b| a[\t0] <= b[\t0] };
        };
    }

    // \reading nil: the pending reading landed, or it was cancelled (or
    // replaced). Landed: the Looper's reading is it and its time has come;
    // nothing to do. Cancelled: it comes out again and the drums decide again
    // from its time.
    readingCleared { |now|
        var pl = pendingLanding, wall;
        if(alive.not or: { pl.isNil }) { ^this };
        wall = wallClock.value;
        pendingLanding = nil;
        if((looper.isNil or: { looper.readingIndex == pl[\index] })
            and: { pl[\at].notNil } and: { wall >= (pl[\at] - 0.001) }) { ^this };
        this.prRemoveLanding(pl);
    }

    prRemoveLanding { |pl|
        case
        { pl[\kind] == \segment } {
            this.prUndoSegment(pl);
            // What comes back is timed again at the loop's speed, which half-time
            // may have changed since it went (prRetimeGrid rewinds from there).
            this.prSyncEdges;
            this.prRetimeGrid(pl[\at]);
        }
        { pl[\kind] == \epoch } {
            if(epochs.includes(pl[\target])) {
                epochs.remove(pl[\target]);
                this.prRequest([\rewind, pl[\at]]);
                this.prRequest([\cut, pl[\at]]);
            };
        };
    }

    // A new epoch at t0: an origin for both patterns' steps, new dice, the grid
    // from `result`. One already in at or after t0 is replaced. The transport
    // plays from t0. A reading still to land after t0 lands in it (a Start
    // between a reading's arm and its landing, as an overdub detection's: the
    // Looper sends no Start for a landing that does not restart, and a
    // restart's epoch went with those replaced). Answers the epoch.
    prInstallEpoch { |t0, result, loopDur, p|
        var seed, ep, gone, pl;
        seed = keptDice ?? { if(randSeed.notNil) { randSeed + epochCount } { 2147483647.rand } };
        lastSeed = seed;
        epochCount = epochCount + 1;
        ep = (id: epochCount, t0: t0, seed: seed, p: p,
            segs: List[this.prSegment(t0, 0, result, loopDur)]);
        gone = epochs.select { |e| e[\t0] >= (t0 - 1e-6) };
        epochs = List.newFrom(epochs.reject { |e| e[\t0] >= (t0 - 1e-6) });
        epochs.add(ep);
        if(pendingLanding.notNil and: { gone.includes(pendingLanding[\target]) }) {
            pendingLanding[\kind] = \none;
            pendingLanding[\target] = nil;
        };
        playHist = this.class.historyFrom(playHist, t0, true);
        this.prRequest([\rewind, t0]);
        this.prRequest([\cut, t0]);
        if(playing.not) { playing = true; this.prNotify(\playing, true) };
        pl = pendingLanding;
        if(p.isNil and: { pl.notNil } and: { pl[\at].notNil } and: { pl[\at] > (t0 + 1e-6) }) {
            if(pl[\kind] == \segment) { this.prUndoSegment(pl) };
            #[\target, \epoch, \replaced].do { |k| pl.removeAt(k) };
            pl[\kind] = \none;
            this.prInstallLanding(pl);
        };
        // A half-time still to come lands in the new epoch too.
        this.prSyncEdges;
        ^ep
    }

    // One grid segment from t0 (at tick tick0, 480 a quarter note): the 16th is
    // the loop's length over the reading's whole number of 16ths, and twice
    // that where the loop plays at half-time (speed, prSpeedAt; s16at1 the
    // 16th at its own speed). Its bar lines (barStarts, from tick0, every loop
    // again) are the reading's bars, uneven ones too, and bar0 is how many
    // bars the epoch had played before it, so the bar count goes on across a
    // landing (prBarAt).
    prSegment { |t0, tick0, result, loopDur, bar0 = 0|
        var n16 = this.class.sixteenthsFor(result);
        var bpm = result !? { |r| r[\bpm] };
        var dur = if((loopDur ? 0) > 0) { loopDur } { (result !? { |r| r[\loopDur] }) ? 0 };
        var s16 = if(dur > 0) { dur / n16 } { 15 / (bpm ? 120) };
        var speed = this.prSpeedAt(t0);
        if((dur > 0) and: { bpm.notNil } and: { (((dur * bpm) / 15).round).asInteger != n16 }) {
            ("MegaSADrums: this reading puts " ++ n16 ++ " sixteenths in the loop, its tempo "
                ++ (((dur * bpm) / 15).round).asInteger ++ "; the drums follow the bars.").warn;
        };
        ^(t0: t0, tick0: tick0, s16: s16 / speed, s16at1: s16, speed: speed, n16: n16, loopDur: dur,
            numerator: ((result !? { |r| r[\numerator] }) ? 4).asInteger.max(1),
            denominator: ((result !? { |r| r[\denominator] }) ? 4).asInteger.max(1),
            k: (result !? { |r| r[\k] }) ? 1,
            barStarts: this.class.barStartTicks(result), loopTicks: n16 * 120, bar0: bar0)
    }

    // The bar a tick is in, counted from the epoch's start: bar0, plus the
    // segment's bar lines at or before it.
    prBarAt { |seg, tick|
        var rel = ((tick - seg[\tick0]) + 1e-6).max(0);
        var starts = seg[\barStarts] ? [0], loopTicks = (seg[\loopTicks] ? 1920).max(1);
        var loops = (rel / loopTicks).floor, within = rel - (loops * loopTicks);
        ^(seg[\bar0] ? 0) + (loops.asInteger * starts.size)
            + ((starts.count { |s| s <= within }) - 1).max(0)
    }

    // ---- Half-time ------------------------------------------------------------
    // The drums play at the loop's speed (the duo's choice, 2026-10-28): at
    // half-time each 16th is twice as long, so a bar of the loop is still a bar
    // of theirs, and the synth's notes, on the same grid, follow. The sounds
    // keep their pitch. The Looper plans half-time a pass or more ahead
    // (\halfTime: armed, or ending, at halfTimeAt, one of its boundaries), so
    // it goes into the grid ahead, as a reading does: an EDGE, a segment like
    // the one in force there at the new speed. Taken back, it comes out. Every
    // segment from a change on is timed again at the speed the loop plays at
    // its start (prRetimeGrid), and the steps from there are decided again.

    // The loop's speed at grid time t, as half-time has it planned: the
    // Looper's now, or past a landing or an end still to come, the speed after.
    prSpeedAt { |t|
        var l = looper, at;
        if(l.isNil) { ^1 };
        at = l.halfTimeAt;
        if(at.notNil and: { t >= (at - 1e-6) }) {
            if(l.halfTime == \armed) { ^0.5 };
            if(l.halfTime == \releasing) { ^1 };
        };
        ^l.speed ? 1
    }

    // The Looper's \halfTime: the edge still to come, if any, follows its plan.
    // The one before stays where the Looper's speed changed on it (it landed:
    // the grid's history now); otherwise it was taken back, or put away by a
    // stop, and comes out, and the grid is timed again from it (a reading on
    // its boundary had the speed it planned, with no edge of its own).
    prHalfTimeChanged {
        var l = looper, at, landed, from;
        if(alive.not or: { l.isNil }) { ^this };
        halfEdge !? { |e|
            landed = ((l.speedChangedAt ? inf.neg) - e[\at]).abs < 0.001;
            if(landed) {
                epochs.do { |ep| ep[\segs].do { |s|
                    if((s[\edge] == \pending) and: { (s[\t0] - e[\at]).abs < 1e-6 }) { s[\edge] = \landed };
                } };
            } { from = e[\at] };
        };
        at = l.halfTimeAt;
        halfEdge = if(#[\armed, \releasing].includes(l.halfTime) and: { at.notNil }) {
            (at: at, speed: if(l.halfTime == \armed) { 0.5 } { 1 })
        };
        this.prSyncEdges(from);
    }

    // The edges still to come out of the grid, and the one planned now in, in
    // the epoch that plays at its time (unless a segment begins there already,
    // a reading landing on the same boundary, which prRetimeGrid gives the speed),
    // then the grid timed again from the first of them, or from `also` if
    // that is earlier.
    prSyncEdges { |also|
        var e = halfEdge, from = also ? inf, ep, prev, tick, seg, i;
        epochs.do { |x|
            x[\segs].do { |s| if(s[\edge] == \pending) { from = from.min(s[\t0]) } };
            x[\segs] = x[\segs].reject { |s| s[\edge] == \pending };
        };
        if(e.notNil) {
            from = from.min(e[\at]);
            ep = this.prEpochAt(e[\at]);
            if(ep.notNil and: { this.prPlayingAt(e[\at]) }
                and: { ep[\segs].every { |s| (s[\t0] - e[\at]).abs >= 1e-6 } }) {
                prev = this.prSegAtTime(ep, e[\at]);
                tick = this.prTicksAt(ep, e[\at]).round;
                seg = prev.copy.putAll((t0: e[\at], tick0: tick, bar0: this.prBarAt(prev, tick), edge: \pending));
                i = ep[\segs].detectIndex { |s| s[\t0] > e[\at] } ? ep[\segs].size;
                ep[\segs] = ep[\segs].insert(i, seg);
            };
        };
        if(from < inf) { this.prRetimeGrid(from) };
    }

    // Every segment from t on timed again: its first tick where the segment
    // before it puts its start, its bar count from there, its 16th at the
    // loop's speed there. Then the steps from t are decided again.
    prRetimeGrid { |t|
        var segs, prev;
        epochs.do { |ep|
            segs = ep[\segs];
            segs.do { |seg, i|
                if(seg[\t0] >= (t - 1e-6)) {
                    if(i > 0) {
                        prev = segs[i - 1];
                        seg[\tick0] = (prev[\tick0] + (((seg[\t0] - prev[\t0]) / prev[\s16]) * 120)).round;
                        seg[\bar0] = this.prBarAt(prev, seg[\tick0]);
                    };
                    seg[\speed] = this.prSpeedAt(seg[\t0]);
                    seg[\s16] = (seg[\s16at1] ? seg[\s16]) / seg[\speed];
                };
            };
        };
        this.prRequest([\rewind, t]);
    }

    // The loop's speed changed off its boundaries (half-time put away by a
    // stop, the drums running on after it): they follow from their next 16th.
    prFollowSpeedNow {
        var l = looper, t, ep, prev, tick, seg, i;
        if(alive.not or: { l.isNil } or: { halfEdge.notNil }) { ^this };
        t = wallClock.value + lead;
        ep = this.prEpochAt(t);
        if(ep.isNil or: { this.prPlayingAt(t).not }) { ^this };
        prev = this.prSegAtTime(ep, t);
        if(((prev[\speed] ? 1) - (l.speed ? 1)).abs < 1e-9) { ^this };
        tick = (this.prTicksAt(ep, t) / 120).ceil * 120;
        t = this.prTimeOfTick(ep, tick);
        seg = prev.copy.putAll((t0: t, tick0: tick, bar0: this.prBarAt(prev, tick), edge: \landed));
        i = ep[\segs].detectIndex { |s| s[\t0] > t } ? ep[\segs].size;
        ep[\segs] = ep[\segs].insert(i, seg);
        this.prRetimeGrid(t);
    }

    // ---- The onset sink (Looper.onsetNoteSink) ------------------------------

    // The Looper's onset part: hit i of pass m at grid base + (m * period) +
    // pattern[i][0], base = Looper.passStart + onsetNoteOffsetMs (at
    // half-time the pattern and period come twice as long). Played iff
    // looper.onsetPlays(i), at looper.onsetVelocity(ratio), on looper.onsetNote,
    // each read when the hit is decided. A restart onto the same grid (the same
    // pattern, period and a congruent base: every respawn, the end of a break)
    // changes nothing; any other cuts the part's hits still to come and starts
    // again from the first hit not yet too late.
    startOnsets { |aLooper, pattern, period, now|
        var wall, base, run, cursor;
        if(alive.not) { ^this };
        if(aLooper.isNil or: { pattern.isNil } or: { pattern.isEmpty } or: { period.isNil }
            or: { period <= 0 }) { ^this.stopOnsets(aLooper, now) };
        wall = wallClock.value;
        // Where the loop's passes begin: loopStartTime, or at half-time where
        // the half-speed passes began (Looper.passStart).
        base = (aLooper.passStart ? wall) + ((aLooper.onsetNoteOffsetMs ? 0) / 1000);
        run = onsetRun;
        if(run.notNil and: { run[\pattern] === pattern } and: { run[\period] == period }
            and: { this.class.congruent(base, run[\base], period) }) { ^this };
        onsetRunSerial = onsetRunSerial + 1;
        this.prRequest([\onsetCut, onsetRunSerial - 1]);
        cursor = this.class.onsetCursor(pattern, period, base, (wall + margin) - this.prStampDelta);
        onsetRun = (id: onsetRunSerial, looper: aLooper, pattern: pattern, period: period, base: base,
            m: cursor[0], i: cursor[1]);
        this.pump;
    }

    stopOnsets { |aLooper, now|
        if(alive.not) { ^this };
        onsetRun !? { |run|
            onsetRun = nil;
            this.prRequest([\onsetCut, run[\id]]);
        };
    }

    // One onset-kit hit at absolute time `at` (MegaSATransport's noteOn: a test
    // note sent by hand).
    onsetNoteOn { |note, vel, at|
        var wall, rec;
        if(alive.not or: { note.isNil } or: { vel.isNil }) { ^this };
        wall = wallClock.value;
        recSerial = recSerial + 1;
        rec = (id: recSerial, kind: \onset, slot: \onset, grid: at ?? { thisThread.seconds + lead },
            note: note.asInteger, vel: vel.asInteger.clip(1, 127), delta: 0, status: \done, emitted: false);
        this.prEvaluate(rec, wall);
        decided.add(rec);
    }

    // ---- The pump -----------------------------------------------------------

    // Decide every event whose grid time is under wall + lead, in time order.
    // Re-entrant calls do nothing; nothing here waits.
    pump { |wall|
        if(alive.not or: { busy }) { ^this };
        wall = wall ?? { wallClock.value };
        busy = true;
        {
            this.prHousekeeping(wall);
            this.prRun(wall, wall + lead);
            this.prDrainJobs(wall);
            this.prUpdateBreakActive(wall);
            this.prRestFx(wall);
        }.protect { busy = false };
        this.prFlushNotes;
    }

    prRun { |wall, horizon|
        var guard = 0, ev;
        ev = this.prNextEvent;
        while { ev.notNil and: { ev[\time] < horizon } and: { guard < 20000 } } {
            guard = guard + 1;
            this.prProcess(ev, wall);
            ev = this.prNextEvent;
        };
        if(guard >= 20000) {
            "MegaSADrums: 20000 events in one pump; the scheduler stopped there to stay alive.".warn;
        };
    }

    // The earliest event to decide: a step of either pattern, a hit already
    // fired (a note at its lane's delay, a roll hit), the onset part's next hit,
    // or a Beat Repeat capture. At equal times steps come first, then notes,
    // then rolls (a note cuts a roll hit at its own time).
    prNextEvent {
        var best, cand;
        [\main, \break].do { |w|
            cand = this.prPeekStep(w);
            if(cand.notNil and: { best.isNil or: { this.prBefore(cand, best) } }) { best = cand };
        };
        if(pending.notEmpty) {
            cand = (type: \record, time: pending[0][\grid], order: pending[0][\order], rec: pending[0]);
            if(best.isNil or: { this.prBefore(cand, best) }) { best = cand };
        };
        cand = this.prPeekOnset;
        if(cand.notNil and: { best.isNil or: { this.prBefore(cand, best) } }) { best = cand };
        cand = this.prBeatRepeatNext;
        if(cand.notNil and: { best.isNil or: { this.prBefore(cand, best) } }) { best = cand };
        cand = this.prPeekNote;
        if(cand.notNil and: { best.isNil or: { this.prBefore(cand, best) } }) { best = cand };
        ^best
    }

    prBefore { |a, b|
        ^(a[\time] < (b[\time] - 1e-9))
            or: { ((a[\time] - b[\time]).abs <= 1e-9) and: { a[\order] < b[\order] } }
    }

    prProcess { |ev, wall|
        switch(ev[\type],
            \step, { this.prDecideStep(ev, wall) },
            \record, { this.prProcessRecord(ev[\rec], wall) },
            \onset, { this.prProcessOnset(ev, wall) },
            \repeat, { this.prBeatRepeatProcess(ev, wall) },
            \note, { this.prDecideNote(ev, wall) }
        );
    }

    // A pattern's next step to decide, or nil: its cursor moved past steps the
    // shuffle collapses (they never play), onto the next epoch where one has
    // begun, and idle while the transport does not play.
    prPeekStep { |which|
        var pat = patterns[which], cur, ep, nextEp, s, offs, ls, n, tick, t, guard = 0, skip;
        if(epochs.isEmpty) { ^nil };
        cur = cursors[which] ?? { this.prFreshCursor(epochs.first) };
        s = MegaSASteps.stepTicks[pat[\clockSpeed]];
        ls = pat[\shuffleLength];
        offs = MegaSASteps.shuffleOffsets(pat[\shuffle], ls, pat[\globalShuffle]);
        while { guard < 64 } {
            guard = guard + 1;
            ep = this.prEpoch(cur[\epoch]);
            if(ep.isNil) {
                // Its epoch was taken out from under it: carry on from the one
                // in force now, from its start.
                cur = this.prFreshCursor(this.prEpochAt(wallClock.value) ?? { epochs.first });
                ep = this.prEpoch(cur[\epoch]);
            };
            n = cur[\n];
            skip = 0;
            while { MegaSASteps.skipsStep(n, s, offs, ls) and: { skip < 16 } } { n = n + 1; skip = skip + 1 };
            tick = MegaSASteps.fireTick(n, s, offs, ls);
            t = this.prTimeOfTick(ep, tick);
            nextEp = this.prEpochAfter(ep);
            case
            { nextEp.notNil and: { t >= (nextEp[\t0] - 1e-6) } } { cur = this.prFreshCursor(nextEp) }
            { this.prPlayingAt(t).not } {
                if(nextEp.isNil) { ^nil };
                cur = this.prFreshCursor(nextEp);
            }
            {
                ^(type: \step, order: if(which == \main) { 0 } { 0.5 }, time: t, which: which,
                    prior: cursors[which], cursor: cur, n: n, tick: tick, epoch: ep,
                    seg: this.prSegAtTick(ep, tick))
            };
        };
        ^nil
    }

    prFreshCursor { |ep| ^(epoch: ep[\id], n: 0, lastB: nil, armed: false, offset: 0) }

    // Decide one step: resync, the dice, and the notes it fires, queued at
    // their lanes' times. The step's stamp offset is taken once, so its lanes
    // and their rolls agree whichever of them a cut re-sends.
    prDecideStep { |pk, wall|
        var which = pk[\which], pat = patterns[which], cur = pk[\cursor], ep = pk[\epoch], seg = pk[\seg];
        var n = pk[\n], post, ls, hits, rec, delta, state, nominal;
        state = (lastB: cur[\lastB], armed: cur[\armed], offset: cur[\offset]);
        post = if(retrigAt == \live) {
            MegaSASteps.resync(state, n, pk[\tick], seg[\numerator], pat[\autoRetrigger], pat[\autoTriggerRate])
        } {
            // The step's own place, unshuffled: a shuffled step a hair over a
            // bar line still belongs to the bar it was written in.
            nominal = n * MegaSASteps.stepTicks[pat[\clockSpeed]];
            MegaSASteps.resyncAtBar(state, n, this.prBarAt(this.prSegAtTick(ep, nominal), nominal),
                pat[\autoRetrigger], pat[\autoTriggerRate])
        };
        ls = n - post[\offset];
        hits = MegaSASteps.decideStep(pat, ls, { |lane, kind| MegaSASteps.dice(ep[\seed], which, n, lane, kind) });
        stepSerial = stepSerial + 1;
        delta = this.prStampDelta;
        rec = (id: stepSerial, which: which, epoch: ep[\id], n: n, time: pk[\time], tick: pk[\tick],
            prior: pk[\prior], ls: ls, s16: seg[\s16], delta: delta);
        stepLogs[which].add(rec);
        playheads[which].add((time: pk[\time], n: n, ls: ls, epoch: ep[\id]));
        #[3, 2, 1, 0].do { |lane|
            var h = hits[lane];
            h !? {
                this.prQueue((kind: \step, slot: \steps, which: which, lane: lane, step: rec[\id],
                    epoch: ep[\id], n: n, grid: pk[\time] + (h[\delayMs] / 1000), note: h[\note],
                    vel: h[\vel], roll: h[\roll], rollRate: pat[\rollRate], s16: seg[\s16], delta: delta,
                    alt: h[\alt]));
            };
        };
        cursors[which] = (epoch: ep[\id], n: n + 1, lastB: post[\lastB], armed: post[\armed],
            offset: post[\offset]);
    }

    // A note or a roll hit at its time. A note first cuts its lane's roll hits
    // still to come (a NEW note restarts a roll), then starts its own.
    prProcessRecord { |rec, wall|
        var i = pending.indexOf(rec);
        i !? { pending.removeAt(i) };
        if(rec[\kind] == \step) {
            this.prCutRolls(rec, wall);
            this.prQueueRolls(rec);
        };
        this.prEvaluate(rec, wall);
        rec[\status] = \done;
        decided.add(rec);
    }

    prCutRolls { |note, wall|
        var cancel = List.new;
        var hit = { |r|
            (r[\kind] == \roll) and: { r[\which] == note[\which] } and: { r[\lane] == note[\lane] }
                and: { r[\src] != note[\id] } and: { r[\grid] >= (note[\grid] - 1e-9) }
        };
        pending.copy.do { |r|
            if(hit.(r)) {
                pending.remove(r);
                r[\status] = \cut;
                r[\cutBy] = note[\id];
                decided.add(r);
            };
        };
        // After a rewind the roll hits of a note that stays may already be
        // decided; the re-decided note cuts them as well.
        decided.do { |r|
            if((r[\status] == \done) and: { hit.(r) } and: { r[\stamp] > (wall + margin) }) {
                if(r[\emitted] == true) { cancel.add(r) };
                r[\status] = \cut;
                r[\cutBy] = note[\id];
            };
        };
        this.prCancel(cancel);
    }

    prQueueRolls { |note|
        var k = (note[\roll] ? 0).asInteger, times, vels;
        if(k <= 0) { ^this };
        times = MegaSASteps.rollTimes(k, note[\rollRate], note[\s16]);
        vels = MegaSASteps.rollVelocities(note[\vel], k);
        k.do { |j|
            this.prQueue((kind: \roll, slot: \steps, which: note[\which], lane: note[\lane],
                step: note[\step], src: note[\id], epoch: note[\epoch], n: note[\n], j: j + 1,
                grid: note[\grid] + times[j], note: note[\note], vel: vels[j], delta: note[\delta]));
        };
    }

    // Into the pending hits, in (time, kind, serial) order.
    prQueue { |rec|
        recSerial = recSerial + 1;
        rec[\id] = recSerial;
        rec[\order] = this.prOrder(rec);
        this.prPend(rec);
    }

    prPend { |rec|
        var i = pending.size;
        rec[\status] = \pending;
        rec[\emitted] = false;
        rec[\stamp] = nil;
        rec[\dropped] = nil;
        while { (i > 0) and: { this.prAfter(pending[i - 1], rec) } } { i = i - 1 };
        pending.insert(i, rec);
    }

    prOrder { |rec| ^switch(rec[\kind], \step, { 1 }, \roll, { 2 }, \onset, { 3 }, \repeat, { 4 }, { 5 }) }

    prAfter { |a, b|
        ^(a[\grid] > (b[\grid] + 1e-9))
            or: { ((a[\grid] - b[\grid]).abs <= 1e-9) and: {
                (a[\order] > b[\order]) or: { (a[\order] == b[\order]) and: { a[\id] > b[\id] } } } }
    }

    // Judge a decided hit at its own grid time and send it if it is wanted and
    // not too late.
    prEvaluate { |rec, wall|
        rec[\stamp] = rec[\grid] + rec[\delta];
        if(this.prWants(rec).not) { ^false };
        if(rec[\stamp] > (wall + margin)) { ^this.prEmit(rec) };
        this.prDropLate(rec, wall);
        ^false
    }

    prWants { |rec|
        var g = rec[\grid], ep, lane = rec[\lane];
        if(rec[\slot] == \synth) {
            ep = this.prEpochAt(g);
            ^(ep.notNil and: { ep[\id] == rec[\epoch] }) and: { this.prNotesOnAt(g) } and: { this.prPlayingAt(g) }
                and: { this.prHoleAt(g).not }
        };
        if(rec[\slot] != \steps) { ^true };
        ep = this.prEpochAt(g);
        ^(ep.notNil and: { ep[\id] == rec[\epoch] })
            and: { this.prPatternAt(g) == rec[\which] }
            and: { this.prOnAt(g) }
            and: { this.prPlayingAt(g) }
            and: { lane.isNil or: { (patterns[rec[\which]][\mute][lane] == true).not } }
            and: { this.prRepeatWants(rec) }
    }

    prDropLate { |rec, wall|
        rec[\dropped] = true;
        dropped = dropped + 1;
        if(lastDropWall.isNil or: { (wall - lastDropWall) > 1 }) {
            ("MegaSADrums: the language fell behind, so hits that would sound late are dropped "
                "(the first by " ++ (((wall + margin) - rec[\stamp]) * 1000).round(0.1) ++ " ms); "
                ++ dropped ++ " dropped so far.").warn;
        };
        lastDropWall = wall;
    }

    // Send one hit: its cancel bus cleared at once, then its layers' voices in
    // one bundle at its stamp, all sharing one hit id. A steps hit of a kit
    // with Beat Repeat is remembered, with the kit and the layers it played,
    // for the captures to come.
    prEmit { |rec|
        var slot = rec[\slot], kit, pad, layers, ring, hitId, msgs;
        if(rec[\kind] == \repeat) { ^this.prEmitRepeat(rec) };
        if(slot == \synth) { ^this.prEmitNote(rec) };
        kit = kitObjects[slot];
        if(kit.isNil or: { kit.isPlayable.not } or: { groupIds.isNil }) { ^false };
        pad = kit.pad(rec[\note]);
        layers = kit.layersFor(rec[\note], rec[\vel]);
        if(pad.isNil or: { layers.isEmpty }) { ^false };
        ring = this.prRingBus(slot);
        hitId = this.prHitId(slot);
        msgs = layers.collect { |layer| this.prVoiceMsg(rec, kit, pad, layer, ring, hitId) }.reject(_.isNil);
        if(msgs.isEmpty) { ^false };
        this.prSend(nil, [[\c_set, ring, 0]]);
        this.prWakeFx(slot, rec[\stamp] + layers.collect { |layer| kit.soundingDur(layer) ? 10 }.maxItem + 0.005);
        this.prSend(rec[\stamp], msgs);
        rec[\emitted] = true;
        rec[\ring] = ring;
        rec[\hitId] = hitId;
        rec[\voices] = msgs.size;
        rec[\kit] = kit.key;
        rec[\layers] = layers;
        rec[\kitObj] = kit;
        this.prNoteBufferUse(kit, layers, rec[\stamp]);
        if((slot == \steps) and: { kit.hasRepeats }) { this.prRemember(rec) };
        this.prQueueLog(rec);
        ^true
    }

    prVoiceMsg { |rec, kit, pad, layer, ring, hitId|
        var slot = rec[\slot], buf = kit.bufferFor(layer), choke;
        if(buf.isNil or: { buf.bufnum.isNil }) { ^nil };
        choke = this.class.chokeFor(pad, chokeBases[slot]);
        ^[\s_new, if((kit.channelsFor(layer) ? 1) >= 2) { \megaSADrumVoice2 } { \megaSADrumVoice1 },
            -1, 1, groupIds[rec[\group] ? slot],
            \out, outBusses[slot], \buf, buf.bufnum,
            \amp, kit.ampFor(layer, pad, rec[\vel], this.groupTrim(slot, layer[\group]), this.padTrim(slot, pad[\note])),
            \rate, kit.rateFor(layer), \pan, pad[\pan] ? 0, \startFrames, layer[\startFrames] ? 0,
            \dur, kit.durFor(layer), \drive, layer[\drive] ? 0,
            \cancelBus, ring, \chokeBus, choke[0], \chokeOn, choke[1], \hitId, hitId, \release, 0.005]
            ++ (rec[\voiceArgs] ? [])
    }

    // One immediate message for all of them.
    prCancel { |recs|
        var msg;
        if(recs.isEmpty) { ^this };
        msg = [\c_set];
        recs.do { |r|
            msg = msg ++ [r[\ring], 1];
            r[\emitted] = false;
            r[\cancelled] = true;
        };
        this.prSend(nil, [msg]);
        // A plugin's note: its note-off at its own stamp, after its note-on.
        recs.do { |r| r[\cancelMsgs] !? { |m| if(m.notEmpty) { this.prSend(r[\stamp], m) } } };
    }

    prSend { |absTime, msgs| sender.value(absTime, msgs) }

    prRingBus { |slot|
        var k = ringSerials[slot] % 1024;
        ringSerials[slot] = ringSerials[slot] + 1;
        ^ringBases[slot] + k
    }

    // Unique per slot, from 1, under 2 ** 24 (exact as a 32-bit float).
    prHitId { |slot|
        var id = (hitSerials[slot] % 16777215) + 1;
        hitSerials[slot] = hitSerials[slot] + 1;
        ^id
    }

    prStampDelta { ^(this.class.loopAudioDelay + dHat) + (offsetMs / 1000) }

    // ---- The onset part in the pump --------------------------------------

    prPeekOnset {
        var run = onsetRun, hit;
        if(run.isNil) { ^nil };
        hit = run[\pattern][run[\i]];
        ^(type: \onset, order: 3, time: (run[\base] + (run[\m] * run[\period])) + hit[0], m: run[\m], i: run[\i])
    }

    prProcessOnset { |ev, wall|
        var run = onsetRun, i = ev[\i], hit, l, rec;
        hit = run[\pattern][i];
        l = run[\looper];
        // On to the next one first: a hit that throws must not stall the part.
        if((i + 1) >= run[\pattern].size) {
            run[\i] = 0;
            run[\m] = run[\m] + 1;
        } {
            run[\i] = i + 1;
        };
        if(l.onsetPlays(i)) {
            recSerial = recSerial + 1;
            rec = (id: recSerial, kind: \onset, slot: \onset, run: run[\id], m: ev[\m], i: i, grid: ev[\time],
                note: l.onsetNote, vel: l.onsetVelocity(hit[1]), delta: this.prStampDelta,
                status: \done, emitted: false);
            this.prEvaluate(rec, wall);
            decided.add(rec);
        };
    }

    // ---- The note sequencer in the pump ------------------------------------
    // MegaSANoteSeq's steps on the drums' grid. A cursor is (epoch:, n:, s:,
    // n0:, tick0:, offset:, lastKey:, seq:): step n of the epoch (from 0) is
    // at tick tick0 + (n - n0) * s, s ticks a step (a rate change starts a
    // new n0 and tick0, prNoteRetime), plus its swing; offset is the step of
    // the last restart and lastKey what that restart followed (the bar, or
    // the loop's pass); seq is what MegaSANoteSeq.decide carries from step to
    // step. Its dice are a pure function of the epoch's seed and n, so a step
    // decided again after a rewind decides the same way.

    prFreshNoteCursor { |ep|
        ^(epoch: ep[\id], n: 0, s: MegaSANoteSeq.stepTicks(notes), n0: 0, tick0: 0, offset: 0,
            lastKey: nil, seq: nil)
    }

    // Step n's place on the grid of its rate, from the epoch's origin (whole
    // steps: the swing's even and odd).
    prNoteIndex { |cur| ^((cur[\tick0] / cur[\s]).round.asInteger + (cur[\n] - cur[\n0])) }

    prNoteNominal { |cur| ^cur[\tick0] + ((cur[\n] - cur[\n0]) * cur[\s]) }

    // The sequencer's next step to decide, or nil, as prPeekStep's.
    prPeekNote {
        var cur, ep, nextEp, tick, t, guard = 0;
        if(epochs.isEmpty) { ^nil };
        cur = noteCursor ?? { this.prFreshNoteCursor(epochs.first) };
        while { guard < 64 } {
            guard = guard + 1;
            ep = this.prEpoch(cur[\epoch]);
            if(ep.isNil) {
                cur = this.prFreshNoteCursor(this.prEpochAt(wallClock.value) ?? { epochs.first });
                ep = this.prEpoch(cur[\epoch]);
            };
            tick = this.prNoteNominal(cur) + MegaSANoteSeq.swingTicks(notes, this.prNoteIndex(cur), cur[\s]);
            t = this.prTimeOfTick(ep, tick);
            nextEp = this.prEpochAfter(ep);
            case
            { nextEp.notNil and: { t >= (nextEp[\t0] - 1e-6) } } { cur = this.prFreshNoteCursor(nextEp) }
            { this.prPlayingAt(t).not } {
                if(nextEp.isNil) { ^nil };
                cur = this.prFreshNoteCursor(nextEp);
            }
            {
                ^(type: \note, order: 0.75, time: t, prior: noteCursor, cursor: cur, tick: tick, epoch: ep,
                    seg: this.prSegAtTick(ep, tick))
            };
        };
        ^nil
    }

    // What restarts the sequence at its nominal tick: the bar it is in, the
    // loop's pass, or nothing.
    prNoteRestartKey { |ep, nominal|
        var seg = this.prSegAtTick(ep, nominal), rel;
        ^switch(notes[\restart],
            \bar, { this.prBarAt(seg, nominal) },
            \loop, {
                rel = ((nominal - seg[\tick0]) + 1e-6).max(0);
                [seg[\t0], (rel / (seg[\loopTicks] ? 1920).max(1)).floor]
            },
            { 0 })
    }

    // Decide one step and queue its note's hits (one, or a ratchet's), each
    // at the step's time plus its shift, held for its length.
    prDecideNote { |pk, wall|
        var cur = pk[\cursor], ep = pk[\epoch], seg = pk[\seg], n = cur[\n], nominal, key, offset;
        var out, rec, delta, stepDur, nt, times, last;
        nominal = this.prNoteNominal(cur);
        key = this.prNoteRestartKey(ep, nominal);
        offset = if(key != cur[\lastKey]) { n } { cur[\offset] };
        out = MegaSANoteSeq.decide(notes, n - offset, cur[\seq],
            { |slot, kind| MegaSASteps.uniform(ep[\seed], \notes, n, slot, kind) });
        stepSerial = stepSerial + 1;
        delta = this.prStampDelta;
        stepDur = (cur[\s] / 120) * seg[\s16];
        rec = (id: stepSerial, which: \notes, epoch: ep[\id], n: n, time: pk[\time], tick: pk[\tick],
            nominal: nominal, prior: pk[\prior], count: n - offset, main: out[\main], delta: delta);
        noteLog.add(rec);
        noteHeads.add((time: pk[\time], n: n, main: out[\main], lanes: out[\lanes], epoch: ep[\id]));
        nt = out[\note];
        last = cur[\last];
        if(nt.notNil) {
            times = MegaSANoteSeq.ratchetTimes(nt[\ratchet]);
            times.do { |f, j|
                var grid = pk[\time] + ((nt[\shift] + f) * stepDur), gate = nt[\length] * stepDur;
                // The note before (the sequence's, decided in time order), and
                // whether this is legato: another pitch while that one is
                // still held, or ends just as this starts (100 % long). A
                // ratchet's repeats and a repeated pitch attack again, as
                // SQ's retriggering notes do.
                this.prQueue((kind: \note, slot: \synth, which: \notes, step: rec[\id], epoch: ep[\id], n: n,
                    j: j, grid: grid, note: nt[\note], vel: nt[\vel], gate: gate, delta: delta,
                    tie: (nt[\length] >= 0.999) and: { j == (times.size - 1) },
                    from: last !? { |l| l[\note] }, legato: (j == 0) and: { last.notNil } and: { last[\note] != nt[\note] } and: { last[\end] > (grid - 1e-6) }));
                last = (note: nt[\note], end: grid + gate);
            };
        };
        noteCursor = (epoch: ep[\id], n: n + 1, s: cur[\s], n0: cur[\n0], tick0: cur[\tick0],
            offset: offset, lastKey: key, seq: out[\state], last: last);
    }

    // A rate edit: the count carries on from the first step of the new rate
    // after the last one decided.
    prNoteRetime {
        var cur = noteCursor, last = noteLog.last, s, k;
        if(cur.isNil or: { last.isNil } or: { last[\epoch] != cur[\epoch] }) { ^this };
        s = MegaSANoteSeq.stepTicks(notes);
        k = ((last[\nominal] + 1e-6) / s).floor + 1;
        noteCursor = cur.copy.put(\s, s).put(\n0, cur[\n]).put(\tick0, k * s);
    }

    // One note to the instrument: its cancel bus cleared at once, then its
    // voice at its stamp. noteVoice answers the messages to send at the
    // stamp, or (msgs:, after: [[seconds after the stamp, msgs], ...],
    // cancel: msgs): a plugin's note-on, its note-off after the gate, and
    // what undoes it, sent at its stamp if it is cancelled (a note-off: a
    // MIDI message sent cannot be taken back as a voice's cancel bus can).
    prEmitNote { |rec|
        var ring, hitId, msgs, voice, res, after = [];
        if(groupIds.isNil) { ^false };
        ring = this.prRingBus(\synth);
        hitId = this.prHitId(\synth);
        voice = noteVoice ? { |r, where| this.class.toneMsgs(r, where) };
        res = voice.value(rec, (ring: ring, hitId: hitId, choke: chokeBases[\synth],
            out: outBusses[\synth], group: groupIds[\synth])) ? [];
        if(res.isKindOf(Dictionary)) {
            msgs = res[\msgs] ? [];
            after = res[\after] ? [];
            rec[\cancelMsgs] = res[\cancel];
        } { msgs = res };
        if(msgs.isEmpty) { ^false };
        this.prSend(nil, [[\c_set, ring, 0]]);
        if(outBusses[\synth] == outBusses[\steps]) { this.prWakeFx(\steps, (rec[\stamp] + rec[\gate]) + 0.1) };
        this.prSend(rec[\stamp], msgs);
        after.do { |a| this.prSend(rec[\stamp] + a[0], a[1]) };
        rec[\emitted] = true;
        rec[\ring] = ring;
        rec[\hitId] = hitId;
        ^true
    }

    // The test tone's message for one note.
    *toneMsgs { |rec, where|
        ^[[\s_new, \megaSANoteTone, -1, 1, where[\group], \out, where[\out],
            \freq, rec[\note].midicps, \amp, 0.25 * ((rec[\vel] / 127).squared), \dur, rec[\gate],
            \cancelBus, where[\ring], \chokeBus, where[\choke], \hitId, where[\hitId]]]
    }

    // ---- Beat Repeat --------------------------------------------------------
    // Every Kit-Carbon pad has its own Beat Repeat in the set, all alike
    // (MegaSADrumsFx.beatRepeat*): every 2 bars of 4 quarter notes from the
    // transport's origin, 6/16 in (repeatGrid \live; on SA by default every 2
    // of the reading's bars, \bars), it draws its chance, and if it fires it
    // captures a 16th of the pad's output and plays it 5 times more, each a
    // little lower and quieter, until 6/16 after the capture point; the dry
    // passes (Mix mode). The capture points are counted in ticks from the
    // epoch's origin, so they go on across a landing that does not restart and
    // start again with every epoch: in 4/4 each falls on lane step 6 of the
    // patterns, in 7/8 the resyncs walk it over 6, 6, 14, 14, ...
    //
    // There is no audio here to capture, so SA replays what it knows sounded.
    // When the pump reaches a slice's end less the lead (every hit inside it
    // decided), each beatRepeat pad of the steps kit draws its die (a pure
    // function of the epoch's seed, the capture and the pad), and for each
    // that fires the slice is that pad's \carbon layers sounding in
    // [tc, tc + 16th): hits that start inside it, and tails of earlier hits
    // still sounding at tc that no newer hit of their choke group (the pad's
    // own, if it retriggers) has cut before tc; a cut inside the slice ends
    // that part there. Repeat k replays each of them from the same point of
    // its sample (a tail from where it was at tc; a hit inside the slice
    // after its offset into it over the rate), at the repeat's rate and level,
    // in the repeat group, choke-free, band-limited on the pads with
    // repeatFilter. The KJ stand-in layer is not repeated: in the set it is
    // another chain, outside the pads' Beat Repeats.
    //
    // One record per captured hit and repeat, kind \repeat, in the decided
    // table, judged like the hit it repeats at its own grid time (its pattern
    // in force, PC 17 on, the transport playing, its epoch) and by the Beat
    // Repeat switch there. Live's device would go on repeating across a break
    // or PC 17; here a repeat goes with its pattern, as a roll does. A cut
    // derives again every capture whose gate is not over, so the repeats
    // follow what the slice really held after it: a cancelled hit's repeats
    // go, a hit the cut sent gets its own. A rewind of the grid decides the
    // captures it reaches again.

    // The layers Beat Repeat replays: the pads' own chains in the set.
    *repeatGroup { ^\carbon }

    // The tick of capture point c in epoch ep: on Live's grid, 6/16 into
    // every 8 quarter notes from the origin (MegaSADrumsFx.captureTick); on
    // the bars, 6/16 into bar 2c, counted from the epoch's start across its
    // landings (a bar of 7/8, of 8/8, as the reading has them).
    prCaptureTick { |ep, c|
        ^if(repeatGrid == \live) { MegaSADrumsFx.captureTick(c) } {
            this.prTickOfBar(ep, c * MegaSADrumsFx.beatRepeatBars) + MegaSADrumsFx.captureTick(0)
        }
    }

    // The first capture point at or after `tick`.
    prCaptureIndexAt { |ep, tick|
        var c;
        if(repeatGrid == \live) { ^MegaSADrumsFx.captureIndexAt(tick) };
        c = (this.prBarAt(this.prSegAtTick(ep, tick), tick) div: MegaSADrumsFx.beatRepeatBars).max(0);
        while { this.prCaptureTick(ep, c) < (tick - 1e-9) } { c = c + 1 };
        ^c
    }

    // The tick bar b (counted from the epoch's start) begins on, in the
    // segment whose bars it is among: the last that began at or before it.
    prTickOfBar { |ep, b|
        var segs = ep[\segs], i = segs.size - 1, seg, starts, per, rel;
        while { (i > 0) and: { (segs[i][\bar0] ? 0) > b } } { i = i - 1 };
        seg = segs[i];
        starts = seg[\barStarts] ? [0];
        per = starts.size.max(1);
        rel = (b - (seg[\bar0] ? 0)).max(0);
        ^seg[\tick0] + ((rel div: per) * (seg[\loopTicks] ? 1920)) + starts[rel % per]
    }

    // The next capture point to decide, or nil: the cursor moves on to the
    // next epoch where one begins, and idles while the transport does not
    // play. Its time is the end of its slice.
    prBeatRepeatNext {
        var cur, ep, nextEp, tick, tc, wall, guard = 0;
        if(epochs.isEmpty) { ^nil };
        cur = captureCursor ?? { (epoch: epochs.first[\id], c: 0) };
        while { guard < 64 } {
            guard = guard + 1;
            ep = this.prEpoch(cur[\epoch]);
            if(ep.isNil) {
                // Its epoch was taken out from under it: carry on in the one in
                // force now, from the first capture whose slice (120 ticks, a
                // 16th) has not ended, and keep that, so a later call does not
                // derive it again from a later wall and pass a capture by.
                wall = wallClock.value;
                ep = this.prEpochAt(wall) ?? { epochs.first };
                cur = (epoch: ep[\id], c: this.prCaptureIndexAt(ep, (this.prTicksAt(ep, wall) - 120).max(0)));
                captureCursor = cur;
            };
            tick = this.prCaptureTick(ep, cur[\c]);
            tc = this.prTimeOfTick(ep, tick);
            nextEp = this.prEpochAfter(ep);
            case
            { nextEp.notNil and: { tc >= (nextEp[\t0] - 1e-6) } } { cur = (epoch: nextEp[\id], c: 0) }
            { this.prPlayingAt(tc).not } {
                if(nextEp.isNil) { ^nil };
                cur = (epoch: nextEp[\id], c: 0);
            }
            {
                ^(type: \repeat, order: 4, time: this.prTimeOfTick(ep, tick + 120), epoch: ep, c: cur[\c],
                    tc: tc, s16: this.prSegAtTime(ep, tc)[\s16])
            };
        };
        ^nil
    }

    // Decide one capture: the pads that fire, and their repeats.
    prBeatRepeatProcess { |ev, wall|
        var ep = ev[\epoch], kit = kitObjects[\steps], key = [ep[\id], ev[\c]], cap;
        captureCursor = (epoch: ep[\id], c: ev[\c] + 1);
        cap = (key: key, epoch: ep[\id], c: ev[\c], tc: ev[\tc], s16: ev[\s16], sliceEnd: ev[\time],
            gateEnd: ev[\tc] + (ev[\s16] * (MegaSADrumsFx.beatRepeatGate / MegaSADrumsFx.beatRepeatGrid)),
            kitObj: kit, pads: this.prRepeatPads(kit, ep[\seed], ev[\c]),
            recs: lockedRepeats.removeAt(key) ?? { Dictionary.new });
        captures.add(cap);
        if(cap[\pads].notEmpty or: { cap[\recs].notEmpty }) { this.prReconcile(cap, wall, true) };
    }

    // The pads whose Beat Repeat fires at capture c: every beatRepeat pad of
    // the kit whose own die falls under the chance.
    prRepeatPads { |kit, seed, c|
        if(kit.isNil or: { kit.hasRepeats.not }) { ^[] };
        ^kit.notes.select { |note|
            (kit.pad(note)[\beatRepeat] == true)
                and: { MegaSASteps.uniform(seed, \main, c, note, \repeat) < repeatChance }
        }
    }

    // A repeat is judged as the hit it repeats (prWants) and, here, by the
    // switch at its grid time and by that hit still sounding.
    prRepeatWants { |rec|
        ^(rec[\kind] != \repeat) or: {
            (this.class.historyAt(repeatHist, rec[\grid]) == true) and: { rec[\source][\emitted] == true }
        }
    }

    prBeatRepeatHook { |what, t, wall|
        switch(what,
            \cut, { captures.do { |cap| if(cap[\gateEnd] > (t - 1e-9)) { this.prReconcile(cap, wall, false) } } },
            \rewind, { this.prRepeatRewind(t, wall) }
        );
    }

    // Bring a capture's repeat records to what its slice now holds: those no
    // longer derived (or derived differently) are cancelled and dropped, new
    // ones are made and sent, the rest judged again; none whose stamp is
    // within wall + margin is touched. `first`: the capture's own decision,
    // where a repeat already too late counts as dropped.
    prReconcile { |cap, wall, first = false|
        var want = this.prRepeatPlans(cap), have = cap[\recs], line = wall + margin;
        var cancel = List.new, send = List.new;
        have.keys.asArray.do { |key|
            var rec = have[key], plan = want[key];
            if(rec[\stamp] > line) {
                if(plan.isNil or: { this.prPlanMoved(rec, plan) }) {
                    if(rec[\emitted] == true) { cancel.add(rec) };
                    have.removeAt(key);
                    decided.remove(rec);
                };
            } {
                want.removeAt(key);
            };
        };
        // In time order, as every other hit is decided and sent.
        want.keys.asArray.sort { |a, b| want[a][\grid] <= want[b][\grid] }.do { |key|
            var plan = want[key], rec = have[key], wants;
            if(rec.isNil) {
                rec = this.prRepeatRecord(plan);
                have.put(key, rec);
                decided.add(rec);
                if(first) { this.prEvaluate(rec, wall) } {
                    rec[\stamp] = rec[\grid] + rec[\delta];
                    if((rec[\stamp] > line) and: { this.prWants(rec) }) { send.add(rec) };
                };
            } {
                wants = this.prWants(rec);
                if(rec[\emitted] == true) {
                    if(wants.not) { cancel.add(rec) };
                } {
                    if(wants) { send.add(rec) };
                };
            };
        };
        this.prCancel(cancel);
        send.do { |rec| this.prEmit(rec) };
    }

    // What a capture's repeats are, from what the language knows sounded in
    // its slice: key -> plan, one per captured hit and repeat. The key names
    // the hit by what it is (epoch, pattern, lane, step, roll hit), so a hit
    // decided again after a rewind is the same hit.
    prRepeatPlans { |cap|
        var kit = cap[\kitObj], out = Dictionary.new, times, tc = cap[\tc], gateEnd = cap[\gateEnd];
        if(kit.isNil or: { cap[\pads].isEmpty }) { ^out };
        times = MegaSADrumsFx.beatRepeatTimes(cap[\s16]);
        cap[\pads].do { |note|
            this.prSliceOf(cap, kit, kit.pad(note)).do { |part|
                times.do { |when, i|
                    var k = i + 1, rateK = MegaSADrumsFx.beatRepeatRate(k);
                    var at = (tc + when[0]) + ((part[\start] - tc) / rateK);
                    var src = part[\source], plan;
                    if(at < (gateEnd - 1e-9)) {
                        plan = part[\layers].collect { |p| this.prRepeatVoice(kit, p, rateK, at, gateEnd) }
                            .reject(_.isNil);
                        if(plan.notEmpty) {
                            out.put([src[\epoch], src[\which], src[\lane], src[\n], src[\j] ? 0, src[\kind], note, k],
                                (grid: at, k: k, rateK: rateK, level: MegaSADrumsFx.beatRepeatLevel(k),
                                    which: src[\which], epoch: cap[\epoch], n: src[\n], note: note,
                                    vel: src[\vel], source: src, plan: plan, kitObj: kit));
                        };
                    };
                };
            };
        };
        ^out
    }

    // A pad's \carbon voices in a capture's slice, from repeatMemory:
    // (source:, start:, layers: [(layer:, offset:, len:)]), `offset` being how
    // far into its sample a voice is at `start` (seconds) and `len` how long it
    // sounds in the slice from there: to the slice's end, its sample's, or the
    // newer hit that cuts it, whichever comes first.
    prSliceOf { |cap, kit, pad|
        var tc = cap[\tc], sliceEnd = cap[\sliceEnd], note = pad[\note];
        var choke = this.class.chokeFor(pad, 0), group = this.class.repeatGroup;
        var out = List.new;
        repeatMemory.do { |src|
            var start, cutAt, parts;
            if((src[\note] == note) and: { src[\emitted] == true } and: { src[\kitObj] === kit }
                and: { src[\grid] < (sliceEnd - 1e-9) }) {
                cutAt = this.prCutAt(src, kit, choke, sliceEnd);
                if((src[\grid] >= (tc - 1e-9)) or: { cutAt.isNil } or: { cutAt > (tc + 1e-9) }) {
                    start = src[\grid].max(tc);
                    parts = (src[\layers] ? []).select { |l| l[\group] == group }.collect { |l|
                        var dur = kit.soundingDur(l), stop;
                        stop = [sliceEnd, cutAt ? inf,
                            if(dur.notNil) { src[\grid] + dur } { if(src[\grid] >= (tc - 1e-9)) { inf } { start } }].minItem;
                        if((stop - start) > 1e-6) { (layer: l, offset: start - src[\grid], len: stop - start) }
                    }.reject(_.isNil);
                    if(parts.notEmpty) { out.add((source: src, start: start, layers: parts)) };
                };
            };
        };
        ^out.asArray
    }

    // When a newer sounding hit of src's choke group (chokeFor: its group,
    // or the pad's own bus for a retriggering pad) starts, before `before`; nil
    // if none does, or the pad chokes nothing.
    prCutAt { |src, kit, choke, before|
        var at;
        if(choke[1] != 1) { ^nil };
        repeatMemory.do { |h|
            if((h !== src) and: { h[\emitted] == true } and: { h[\kitObj] === kit }
                and: { h[\grid] < (before - 1e-9) } and: { this.prNewer(h, src) }
                and: { (kit.pad(h[\note]) !? { |p| this.class.chokeFor(p, 0) }) == choke }) {
                if(at.isNil or: { h[\grid] < at }) { at = h[\grid] };
            };
        };
        ^at
    }

    // h started after s: later on the grid, or in the same place and sent
    // later (its voice then runs after s's in their block, and chokes it).
    prNewer { |h, s|
        ^(h[\grid] > (s[\grid] + 1e-9))
            or: { ((h[\grid] - s[\grid]).abs <= 1e-9) and: { (h[\hitId] ? 0) > (s[\hitId] ? 0) } }
    }

    // One voice of a repeat: the layer from the same point of its sample, at
    // the repeat's rate, for its part of the slice at that rate, and never past
    // the gate.
    prRepeatVoice { |kit, p, rateK, at, gateEnd|
        var layer = p[\layer], info = kit.infoFor(layer), rate = kit.rateFor(layer);
        if(info.isNil) { ^nil };
        ^(layer: layer, rate: rate * rateK,
            startFrames: (layer[\startFrames] ? 0) + ((p[\offset] * info[\sampleRate]) * rate),
            dur: p[\len] / rateK, gateLen: gateEnd - at)
    }

    prRepeatRecord { |plan|
        recSerial = recSerial + 1;
        ^(id: recSerial, kind: \repeat, slot: \steps, group: \repeat, which: plan[\which],
            epoch: plan[\epoch], n: plan[\n], k: plan[\k], grid: plan[\grid], note: plan[\note],
            vel: plan[\vel], level: plan[\level], rateK: plan[\rateK], source: plan[\source],
            plan: plan[\plan], kitObj: plan[\kitObj], delta: this.prStampDelta, order: 4,
            status: \done, emitted: false)
    }

    prPlanMoved { |rec, plan|
        ^((rec[\grid] - plan[\grid]).abs > 1e-9) or: { rec[\plan].size != plan[\plan].size }
            or: { rec[\plan].any { |v, i|
                var w = plan[\plan][i];
                (v[\layer] !== w[\layer]) or: { (v[\startFrames] - w[\startFrames]).abs > 1e-6 }
                    or: { (v[\dur] - w[\dur]).abs > 1e-9 } or: { (v[\gateLen] - w[\gateLen]).abs > 1e-9 }
            } }
    }

    // A repeat's voices in one bundle, like a hit's, but only while its kit is
    // the steps kit in force: a kit swapped in since plays no repeat of the old
    // one's sounds.
    prEmitRepeat { |rec|
        var kit = rec[\kitObj], pad, ring, hitId, msgs;
        if(kit.isNil or: { kit !== kitObjects[\steps] } or: { kit.isPlayable.not } or: { groupIds.isNil }) { ^false };
        pad = kit.pad(rec[\note]);
        if(pad.isNil) { ^false };
        ring = this.prRingBus(\steps);
        hitId = this.prHitId(\steps);
        msgs = rec[\plan].collect { |v| this.prRepeatVoiceMsg(rec, kit, pad, v, ring, hitId) }.reject(_.isNil);
        if(msgs.isEmpty) { ^false };
        this.prSend(nil, [[\c_set, ring, 0]]);
        // A repeat plays its slice at its own rate, within its dur and gate.
        this.prWakeFx(\steps, rec[\stamp] + rec[\plan].collect { |v|
            var natural = ((kit.soundingDur(v[\layer]) ? 10) * MegaSAKit.rateFor(v[\layer])) / (v[\rate] ? 1).abs.max(0.01);
            ([natural] ++ [v[\dur], v[\gateLen]].select { |x| x.notNil and: { x > 0 } }).minItem
        }.maxItem + 0.005);
        this.prSend(rec[\stamp], msgs);
        rec[\emitted] = true;
        rec[\ring] = ring;
        rec[\hitId] = hitId;
        rec[\voices] = msgs.size;
        rec[\kit] = kit.key;
        this.prNoteBufferUse(kit, rec[\plan].collect { |v| v[\layer] }, rec[\stamp]);
        this.prQueueLog(rec);
        ^true
    }

    prRepeatVoiceMsg { |rec, kit, pad, v, ring, hitId|
        var layer = v[\layer], buf = kit.bufferFor(layer), band;
        if(buf.isNil or: { buf.bufnum.isNil }) { ^nil };
        band = if(pad[\repeatFilter] == true) {
            [\bpOn, 1, \bpFreq, MegaSADrumsFx.beatRepeatFilterFreq,
                \bpRq, MegaSADrumsFx.bandRq(MegaSADrumsFx.beatRepeatFilterWidth)]
        } { [\bpOn, 0] };
        ^[\s_new, if((kit.channelsFor(layer) ? 1) >= 2) { \megaSADrumVoice2 } { \megaSADrumVoice1 },
            -1, 1, groupIds[\repeat],
            \out, outBusses[\steps], \buf, buf.bufnum,
            \amp, kit.ampFor(layer, pad, rec[\vel], this.groupTrim(\steps, layer[\group]),
                this.padTrim(\steps, pad[\note])) * rec[\level],
            \rate, v[\rate], \pan, pad[\pan] ? 0, \startFrames, v[\startFrames], \dur, v[\dur],
            \drive, layer[\drive] ? 0, \cancelBus, ring,
            \chokeBus, this.class.chokeFor((note: 0), chokeBases[\steps])[0], \chokeOn, 0,
            \hitId, hitId, \release, 0.005, \gateLen, v[\gateLen]] ++ band
    }

    // A steps hit that sounded, kept (in grid order) while it may still be
    // sounding: the captures read their slices and the chokes from here, the
    // decided table forgetting a hit half a second after its time.
    prRemember { |rec|
        var i = repeatMemory.size;
        if(rec[\remembered] == true) { ^this };
        rec[\remembered] = true;
        rec[\soundsUntil] = rec[\grid] + ((rec[\layers].collect { |l| rec[\kitObj].soundingDur(l) ? 0 }.maxItem) ? 0);
        while { (i > 0) and: { repeatMemory[i - 1][\grid] > rec[\grid] } } { i = i - 1 };
        repeatMemory.insert(i, rec);
    }

    // The grid changed from t on and the hits from there are decided again:
    // the memory lets go of those that went (a hit already too close to
    // cancel stays: it sounds, and the step decided again drops its double),
    // and every capture whose slice reaches t is decided again when the pump
    // gets back to it. Its repeats still to come are cancelled; those too
    // close to cancel are kept for it, so the capture decided again does not
    // send them twice.
    prRepeatRewind { |t, wall|
        var live = IdentitySet.new, undone, cancel = List.new;
        decided.do { |r| live.add(r) };
        pending.do { |r| live.add(r) };
        repeatMemory = List.newFrom(repeatMemory.select { |r|
            (r[\grid] < (t - 1e-9)) or: { live.includes(r) }
                or: { (r[\emitted] == true) and: { r[\stamp] <= (wall + margin) } }
        });
        undone = captures.select { |cap| cap[\sliceEnd] > (t + 1e-9) };
        if(undone.isEmpty) { ^this };
        undone.do { |cap|
            var keep = Dictionary.new;
            cap[\recs].keysValuesDo { |key, rec|
                if(rec[\stamp] > (wall + margin)) {
                    if(rec[\emitted] == true) { cancel.add(rec) };
                    decided.remove(rec);
                } { keep.put(key, rec) };
            };
            if(keep.notEmpty) { lockedRepeats.put(cap[\key], keep) };
        };
        this.prCancel(cancel);
        captures = List.newFrom(captures.reject { |cap| undone.includes(cap) });
        captureCursor = (epoch: undone.first[\epoch], c: undone.first[\c]);
    }

    // ---- Changes after the fact ------------------------------------------

    // A cut, a rewind or an onset cut: applied now, or after the pump or the
    // change in progress, and its notifications after that.
    prRequest { |job|
        jobs.add(job);
        if(busy.not) {
            busy = true;
            { this.prDrainJobs(wallClock.value) }.protect { busy = false };
            this.prFlushNotes;
        };
    }

    prDrainJobs { |wall|
        var guard = 0, job;
        while { jobs.notEmpty and: { guard < 1000 } } {
            guard = guard + 1;
            job = jobs.removeAt(0);
            switch(job[0],
                \cut, { this.prCutNow(job[1], wall) },
                \rewind, { this.prRewindNow(job[1], wall) },
                \onsetCut, { this.prOnsetCutNow(job[1], wall) }
            );
        };
    }

    // Re-judge every decided hit at or after t that can still be cancelled:
    // cancel those no longer wanted, send those wanted now. Beat Repeat's
    // repeats come after, from what the hits now are (prBeatRepeatHook).
    prCutNow { |t, wall|
        var cancel = List.new, send = List.new;
        decided.do { |rec|
            var want;
            if(((rec[\slot] == \steps) or: { rec[\slot] == \synth }) and: { rec[\kind] != \repeat }
                and: { rec[\status] == \done }
                and: { rec[\grid] >= (t - 1e-9) }
                and: { rec[\stamp].notNil } and: { rec[\stamp] > (wall + margin) }) {
                want = this.prWants(rec);
                if(rec[\emitted] == true) {
                    if(want.not) { cancel.add(rec) };
                } {
                    if(want) { send.add(rec) };
                };
            };
        };
        this.prCancel(cancel);
        send.do { |rec| this.prEmit(rec) };
        this.prBeatRepeatHook(\cut, t, wall);
    }

    // The grid changed from t on: the steps decided at or after t are decided
    // again from the state before the first of them. Their hits go (cancelled
    // where still possible), with every roll hit their notes started; roll hits
    // those notes cut come back. Hits of steps before t stay, and a re-decided
    // note cuts their rolls again (prCutRolls).
    prRewindNow { |t, wall|
        var removed = IdentitySet.new, dead = IdentitySet.new, cancel = List.new, back = List.new;
        var gone, i;
        [\main, \break].do { |which|
            var log = stepLogs[which], i;
            i = log.detectIndex { |s| s[\time] >= (t - 1e-9) };
            if(i.notNil) {
                cursors[which] = log[i][\prior];
                (i .. (log.size - 1)).do { |k| removed.add(log[k][\id]) };
                stepLogs[which] = List.newFrom(log.copyRange(0, i - 1));
                playheads[which] = List.newFrom(playheads[which].reject { |e| e[\time] >= (t - 1e-9) });
            };
        };
        i = noteLog.detectIndex { |s| s[\time] >= (t - 1e-9) };
        if(i.notNil) {
            noteCursor = noteLog[i][\prior];
            (i .. (noteLog.size - 1)).do { |k| removed.add(noteLog[k][\id]) };
            noteLog = List.newFrom(noteLog.copyRange(0, i - 1));
            noteHeads = List.newFrom(noteHeads.reject { |e| e[\time] >= (t - 1e-9) });
        };
        if(removed.isEmpty) { ^this };
        gone = { |r| ((r[\slot] == \steps) or: { r[\slot] == \synth }) and: { r[\step].notNil }
            and: { removed.includes(r[\step]) } };
        (decided ++ pending).do { |r| if(gone.(r) and: { r[\kind] == \step }) { dead.add(r[\id]) } };
        decided.do { |r|
            if(gone.(r) and: { r[\emitted] == true } and: { r[\stamp] > (wall + margin) }) { cancel.add(r) };
        };
        // (reject answers an Array, even of a List)
        decided = List.newFrom(decided.reject(gone));
        pending = List.newFrom(pending.reject(gone));
        decided.do { |r| if((r[\status] == \cut) and: { dead.includes(r[\cutBy]) }) { back.add(r) } };
        back.do { |r|
            decided.remove(r);
            r[\cutBy] = nil;
            this.prPend(r);
        };
        this.prCancel(cancel);
        this.prBeatRepeatHook(\rewind, t, wall);
    }

    // Cancel the onset part's hits of runs up to `upTo` still to come.
    prOnsetCutNow { |upTo, wall|
        this.prCancel(decided.select { |r|
            (r[\slot] == \onset) and: { r[\run].notNil } and: { r[\run] <= upTo }
                and: { r[\emitted] == true } and: { r[\stamp] > (wall + margin) }
        });
    }

    prNotify { |... args|
        if(busy) { queuedNotes.add(args) } { this.changed(*args) };
    }

    prFlushNotes {
        var ns;
        while { queuedNotes.notEmpty and: { busy.not } } {
            ns = queuedNotes;
            queuedNotes = List.new;
            ns.do { |a| this.changed(*a) };
        };
    }

    prUpdateBreakActive { |wall|
        var v = this.prPatternAt(wall - this.class.loopAudioDelay) == \break;
        if(v != breakActive) {
            breakActive = v;
            this.prNotify(\breakActive, v);
        };
    }

    // ---- Lookups --------------------------------------------------------------

    prPatternAt { |g| ^this.class.historyAt(breakHist, g) }
    prHoleAt { |g| ^this.class.historyAt(holeHist, g) }
    prOnAt { |g| ^this.class.historyAt(onHist, g) }
    prPlayingAt { |g| ^this.class.historyAt(playHist, g) }
    prNotesOnAt { |g| ^this.class.historyAt(notesHist, g) }

    prEpoch { |id| ^epochs.detect { |e| e[\id] == id } }

    // The epoch in force at g (one that starts at g is in force there).
    prEpochAt { |g|
        var i = epochs.size - 1;
        while { (i >= 0) and: { epochs[i][\t0] > (g + 1e-6) } } { i = i - 1 };
        ^if(i >= 0) { epochs[i] } { nil }
    }

    prEpochAfter { |ep|
        var i = epochs.indexOf(ep);
        ^if(i.notNil and: { (i + 1) < epochs.size }) { epochs[i + 1] } { nil }
    }

    prSegAtTick { |ep, tick|
        var segs = ep[\segs], i = segs.size - 1;
        while { (i > 0) and: { segs[i][\tick0] > (tick + 1e-6) } } { i = i - 1 };
        ^segs[i]
    }

    prSegAtTime { |ep, t|
        var segs = ep[\segs], i = segs.size - 1;
        while { (i > 0) and: { segs[i][\t0] > (t + 1e-9) } } { i = i - 1 };
        ^segs[i]
    }

    prTimeOfTick { |ep, tick|
        var seg = this.prSegAtTick(ep, tick);
        ^seg[\t0] + (((tick - seg[\tick0]) / 120) * seg[\s16])
    }

    prTicksAt { |ep, t|
        var seg = this.prSegAtTime(ep, t);
        ^seg[\tick0] + (((t - seg[\t0]) / seg[\s16]) * 120)
    }

    prNearestSixteenth { |x|
        var ep = this.prEpochAt(x);
        if(ep.isNil) { ^x };
        ^this.prTimeOfTick(ep, ((this.prTicksAt(ep, x) / 120).round) * 120)
    }

    // The 16th at t: the grid's, or the Looper's reading's, or a 16th of the loop.
    prSixteenthAt { |t, loopDur|
        var ep = this.prEpochAt(t);
        if(ep.notNil) { ^this.prSegAtTime(ep, t)[\s16] };
        ^loopDur / this.class.sixteenthsFor(looper !? { |l| l.lastResult })
    }

    prLoopDur { ^((looper !? { |l| l.loopDuration }) ? 0) }

    // ---- Housekeeping -------------------------------------------------------

    prHousekeeping { |wall|
        this.prCheckSpawn(wall);
        // Before the prune, which the log's look back (logLag) never reaches
        // past. A failing log must never cost the drums a pump.
        try { this.prLogSession(wall) } { |err| this.prLogFailed(err, wall) };
        this.prPrune(wall - 0.5);
        // Every 2 s on the dot (not 2 s after whichever pump got there), unless
        // it fell far behind.
        if(autoProbe and: { nextProbeAt.isNil or: { wall >= nextProbeAt } }) {
            nextProbeAt = if(nextProbeAt.isNil or: { (wall - nextProbeAt) > 2 }) { wall + 2 } { nextProbeAt + 2 };
            this.probe(wall);
        };
        this.prFreeBuffers(wall);
    }

    // Everything decided before `before` is forgotten, but the last step of
    // each pattern (a timing edit carries on from it).
    prPrune { |before|
        if(decided.notEmpty and: { decided[0][\grid] < before }) {
            decided = List.newFrom(decided.reject { |r| r[\grid] < before });
        };
        [\main, \break].do { |w|
            var log = stepLogs[w], ring = playheads[w];
            while { (log.size > 1) and: { log[0][\time] < before } } { log.removeAt(0) };
            while { ring.size > 64 } { ring.removeAt(0) };
        };
        while { (noteLog.size > 1) and: { noteLog[0][\time] < before } } { noteLog.removeAt(0) };
        while { noteHeads.size > 64 } { noteHeads.removeAt(0) };
        notesHist = this.class.historyPruned(notesHist, before);
        breakHist = this.class.historyPruned(breakHist, before);
        holeHist = this.class.historyPruned(holeHist, before);
        onHist = this.class.historyPruned(onHist, before);
        playHist = this.class.historyPruned(playHist, before);
        repeatHist = this.class.historyPruned(repeatHist, before);
        // A hit stays remembered while it may sound, and so does everything
        // after it (a newer hit may have cut it); one never sent goes at once.
        while { repeatMemory.notEmpty and: { repeatMemory[0][\grid] < before }
            and: { (repeatMemory[0][\emitted] != true) or: { repeatMemory[0][\soundsUntil] < before } } } {
            repeatMemory.removeAt(0);
        };
        if(captures.notEmpty and: { captures[0][\gateEnd] < before }) {
            captures = List.newFrom(captures.reject { |cap| cap[\gateEnd] < before });
        };
        if(lockedRepeats.notEmpty) {
            lockedRepeats.keys.asArray.do { |key|
                if(lockedRepeats[key].values.every { |r| r[\grid] < before }) { lockedRepeats.removeAt(key) };
            };
        };
        while { (epochs.size > 1) and: { epochs[1][\t0] < (before - 0.5) }
            and: { this.prEpochUsed(epochs[0][\id]).not } } { epochs.removeAt(0) };
        if(probes.notEmpty) {
            probes.keys.select { |id| probes[id][\time] < (before - 1) }.do { |id| probes.removeAt(id) };
        };
    }

    // An epoch stays while anything still names it: a pattern's cursor, a hit
    // still to decide, a logged step, or Beat Repeat's next capture. That one
    // moves on to a new epoch only once the new epoch's first capture is
    // decided, its slice end (1.75 quarter notes in) less the lead: at quarter
    // tempos under about 96 BPM, after the old epoch would otherwise go.
    prEpochUsed { |id|
        ^cursors.values.any { |c| c.notNil and: { c[\epoch] == id } }
            or: { noteCursor.notNil and: { noteCursor[\epoch] == id } }
            or: { noteLog.any { |s| s[\epoch] == id } }
            or: { captureCursor.notNil and: { captureCursor[\epoch] == id } }
            or: { pending.any { |r| r[\epoch] == id } }
            or: { stepLogs.values.any { |log| log.any { |s| s[\epoch] == id } } }
    }

    // ---- The session log ----------------------------------------------------
    // While the attached Looper's session recorder logs a set
    // (looper.sessionRec, LooperSessionRecorder), the drums tell it what they
    // played: every hit that sounded, once, in one batch a pump (logHits), and
    // what their transport did, as heard (logEvent). Nothing is told before it
    // was heard logLag ago, when nothing can take it back any more: a hit is
    // cancelled only while its stamp is past wall + margin, so by then its
    // last send stands (a hit cancelled and sent again, as PC 17 off and on
    // inside the lead does, sounded once; one cancelled for good never did),
    // and a break's planned end that a second stomp took away never came. A
    // hit heard before the recording began is not the set's.
    //
    // A hit: (at:, slot:, kind:, note:, vel:, lane:, which:, kit:, gate:). at
    // is its stamp, the absolute time it was heard; kind \step, \roll,
    // \repeat or \onset; a repeat's lane and pattern are those of the hit it
    // repeats; gate, for an onset hit only, is the Looper's onset-note gate in
    // seconds (what Live's notes were held for).
    //
    // The transport, each change at its own heard time (its grid time plus the
    // stamp's delta): drumsStart at an epoch's origin and drumsSegment at a
    // landing that does not restart, both with the grid from there (bpm, 15 /
    // s16 exactly; numerator, denominator, n16, loopDur; origin, that same
    // moment on the log's axis); drumsStop; drumsOn (on:) for PC 17; and
    // breakStart / breakEnd as the pattern in force switches. A recording that
    // begins while they play is told the state in force first: a drumsStart
    // (inForce: true) for the segment playing, from that segment's start, and
    // the break and PC 17's off, if in. The Looper's \sessionRecording brings
    // that at once. A set that stops is told on as long as its log is open:
    // its WAVs run on to the stop's stamped end, and so does what it is told
    // (the recorder keeps what was heard before that end).

    // From the pump's housekeeping, a hundred times a second: a pump with
    // nothing heard and nothing changed since the last makes nothing.
    prLogSession { |wall|
        var rec;
        if(looper.notNil) { rec = looper.sessionRec };
        if(rec.notNil and: { rec.logging == true }) {
            this.prLogTransport(wall, rec);
        } {
            logState = nil;
            rec = nil;
        };
        if(logQueue.notEmpty) { this.prLogHits(wall, rec) };
    }

    // A hit just sent, for the log to judge once it has been heard.
    prQueueLog { |rec|
        if(rec[\logQueued] != true) {
            rec[\logQueued] = true;
            logQueue.add(rec);
        };
    }

    // A hit's stamp. One decided again after a rewind waits without one for
    // a moment; it will have this one.
    prLogStamp { |r|
        var s = r[\stamp];
        ^if(s.notNil) { s } { r[\grid] + (r[\delta] ? 0) }
    }

    // Every hit sent that was heard logLag ago: those still emitted, which
    // sounded, to `rec` in one batch in time order, and all of them let go.
    // With no recorder logging (rec nil) they are let go untold.
    prLogHits { |wall, rec|
        var line = wall - this.class.logLag, i = 0, due = false, batch, keep;
        while { due.not and: { i < logQueue.size } } {
            due = this.prLogStamp(logQueue[i]) < line;
            i = i + 1;
        };
        if(due.not) { ^this };
        batch = List.new;
        keep = List.new;
        logQueue.do { |r|
            var stamp = this.prLogStamp(r);
            if(stamp < line) {
                if(rec.notNil and: { r[\emitted] == true } and: { (rec.logTime(stamp) ? 0) >= 0 }) {
                    batch.add(this.prHitEntry(r, stamp));
                };
            } {
                keep.add(r);
            };
        };
        logQueue = keep;
        if(batch.notEmpty) { rec.logHits(batch.asArray.sort { |a, b| a[\at] <= b[\at] }) };
    }

    prHitEntry { |r, stamp|
        ^(at: stamp, slot: r[\slot], kind: r[\kind], note: r[\note], vel: r[\vel],
            lane: r[\lane] ?? { r[\source] !? { |s| s[\lane] } }, which: r[\which], kit: r[\kit],
            gate: if(r[\slot] == \onset) { looper !? { |l| l.onsetNoteGateMs !? { |g| g / 1000 } } })
    }

    // What the transport did since the last look, judged on the grid at
    // logLag before the heard now: the epoch and segment in force there (nil
    // where it does not play), the pattern and PC 17. logState is what the
    // log was told last; mostly nothing has changed.
    prLogTransport { |wall, rec|
        var delta = this.prStampDelta, g = (wall - this.class.logLag) - delta;
        var st = logState, ep, seg, pat, onNow;
        if(this.prPlayingAt(g)) { ep = this.prEpochAt(g) };
        if(ep.notNil) { seg = this.prSegAtTime(ep, g) };
        pat = this.prPatternAt(g);
        onNow = this.prOnAt(g);
        if(st.notNil and: { st[\epoch] === ep } and: { st[\seg] === seg } and: { st[\pattern] == pat }
            and: { st[\on] == onNow }) { ^this };
        this.prLogChanges(st, ep, seg, pat, onNow, g, delta, rec);
        logState = (epoch: ep, seg: seg, pattern: pat, on: onNow);
    }

    // The changes from `st` to the state at g, in time order, each at its own
    // time. With no `st` (a recording's first look) the state in force goes
    // instead. An edge pruned away (a state in force since long before) is
    // said as of g.
    prLogChanges { |st, ep, seg, pat, onNow, g, delta, rec|
        var out = List.new, first;
        var edge = { |hist|
            var e = this.class.historyEdgeAt(hist, g);
            if(e == inf.neg) { g } { e }
        };
        if(st.isNil) {
            seg !? { |s| out.add([s[\t0], \drumsStart, this.prGridFields(s, delta, rec).put(\inForce, true)]) };
            if(pat == \break) { out.add([edge.(breakHist), \breakStart, ()]) };
            if(onNow.not) { out.add([edge.(onHist), \drumsOn, (on: false)]) };
        } {
            if(st[\epoch].notNil and: { ep.isNil }) { out.add([edge.(playHist), \drumsStop, ()]) };
            case
            { ep.notNil and: { ep !== st[\epoch] } } {
                first = this.prSegAtTime(ep, ep[\t0]);
                out.add([ep[\t0], \drumsStart, this.prGridFields(first, delta, rec)]);
                if(seg !== first) { out.add([seg[\t0], \drumsSegment, this.prGridFields(seg, delta, rec)]) };
            }
            { seg.notNil and: { seg !== st[\seg] } } {
                out.add([seg[\t0], \drumsSegment, this.prGridFields(seg, delta, rec)]);
            };
            if(pat != st[\pattern]) {
                out.add([edge.(breakHist), if(pat == \break) { \breakStart } { \breakEnd }, ()]);
            };
            if(onNow != st[\on]) { out.add([edge.(onHist), \drumsOn, (on: onNow)]) };
        };
        out.asArray.sort { |a, b| a[0] <= b[0] }.do { |e| rec.logEvent(e[1], e[2], e[0] + delta) };
    }

    // A segment's grid as the log gets it; origin is its start as heard, on
    // the log's axis. At half-time the loop's length is a pass's, so it agrees
    // with the tempo (15 * n16 / loopDur).
    prGridFields { |seg, delta, rec|
        ^(bpm: 15 / seg[\s16], numerator: seg[\numerator], denominator: seg[\denominator],
            n16: seg[\n16], loopDur: seg[\loopDur] / (seg[\speed] ? 1), origin: rec.logTime(seg[\t0] + delta))
    }

    // The Looper's \sessionRecording: a recording that begins is told the
    // state in force at once, so its log holds the drums' tempo from the
    // stomp on. From inside the pump it waits for the next look. One that
    // stops changes nothing here: its log stays open until its WAVs end (the
    // recorder's tail, LooperSessionRecorder.stop), and the drums go on
    // telling it what they play, as changes, for as long as it logs.
    prSessionRecording { |flag|
        var rec;
        if(alive.not or: { flag != true }) { ^this };
        logState = nil;
        if(busy.not) {
            if(looper.notNil) { rec = looper.sessionRec };
            if(rec.notNil and: { rec.logging == true }) {
                try { this.prLogTransport(wallClock.value, rec) } { |err| this.prLogFailed(err, wallClock.value) };
            };
        };
    }

    // Posted once in 10 s at most; the drums play on.
    prLogFailed { |err, wall|
        if(lastLogError.isNil or: { (wall - lastLogError) > 10 }) {
            ("MegaSADrums: the session log failed — " ++ err.errorString ++ "; the drums play on.").warn;
        };
        lastLogError = wall;
    }

    // ---- The drift probe ----------------------------------------------------
    // The loop runs on the interface's crystal, the language on the host's
    // clock: 20 ppm is 1.2 ms a minute, and a loop can play for twenty. Every
    // 2 s the drums read the engine's phase at a known time and pull dHat a
    // quarter of the way to it.

    // The loop's model holds: it plays forwards, at its own speed (not at
    // half-time, rc600-picks.md 3a: its phase then runs at half the wall's),
    // and has not been reversed since its engine started (a reverse shifts its
    // phase for good; that is not drift). Half-time starts and ends on the
    // loop's own boundaries, so the model holds again after it.
    prLoopValid {
        ^looper.notNil and: { #[\playing, \overdubbing].includes(looper.state) }
            and: { looper.speed == 1 }
            and: { looper.reverseFlag != true } and: { reversedSinceSpawn.not }
            and: { looper.loopStartTime.notNil } and: { looper.loopDuration > 0 }
    }

    prProbeValid { ^this.prLoopValid and: { looper.phaseBus.notNil } }

    // Send one probe now (the pump does every 2 s): the engine's phase read at
    // wall + 50 ms, dithered over one block. Answers its id, or nil.
    probe { |wall|
        var sr, when, id;
        wall = wall ?? { wallClock.value };
        if(alive.not or: { this.prProbeValid.not } or: { groupIds.isNil }) { ^nil };
        sr = (server !? { |s| s.sampleRate }) ? 48000;
        when = (wall + 0.05) + (64 / sr).rand;
        probeSerial = (probeSerial % 16777215) + 1;
        id = probeSerial;
        probes.put(id, (time: when, lam: looper.loopStartTime, spawn: spawnCount, reverse: reverseCount,
            speed: speedCount));
        this.prSend(when, [[\s_new, \megaSADrumsProbe, -1, 0, groupIds[\drum],
            \phaseBus, looper.phaseBus.index, \id, id]]);
        ^id
    }

    // A probe's answer: the engine's phase `value` (seconds into the loop),
    // `arrival` the wall time it came (default now). Kept only if it came within
    // 30 ms of its time, nothing about the loop changed since it was sent, and
    // it is not within 50 ms of the engine's start.
    probeReply { |id, value, arrival|
        var p, lam, loopDur, err, step;
        if(alive.not) { ^this };
        p = probes.removeAt(id);
        if(p.isNil or: { value.isNil }) { ^this };
        arrival = arrival ?? { wallClock.value };
        lam = looper !? { |l| l.loopStartTime };
        loopDur = this.prLoopDur;
        if(this.prProbeValid.not or: { arrival > (p[\time] + 0.03) } or: { p[\lam] != lam }
            or: { p[\spawn] != spawnCount } or: { p[\reverse] != reverseCount } or: { p[\speed] != speedCount }
            or: { (p[\time] - (lastSpawnAt ? inf.neg)) < 0.05 } or: { loopDur <= 0 }) { ^this };
        err = this.class.probeError(value, (server !? { |s| s.sampleRate }) ? 48000, p[\time], lam, dHat,
            loopDur, this.prSixteenthAt(p[\time], loopDur));
        lastProbeError = err;
        step = this.class.driftStep(dHat, err, bigErrors);
        dHat = step[0];
        bigErrors = step[1];
    }

    // A new engine (loopStartTime moved): its own start lag, so dHat from 0 and
    // a probe at once.
    prCheckSpawn { |wall|
        var lam = looper !? { |l| l.loopStartTime };
        if(lam.notNil and: { lam != lastLam }) {
            lastLam = lam;
            lastSpawnAt = lam;
            spawnCount = spawnCount + 1;
            reversedSinceSpawn = looper.reverseFlag == true;
            dHat = 0;
            bigErrors = 0;
            nextProbeAt = wall;
        };
    }

    prReversed { |flag|
        reverseCount = reverseCount + 1;
        if(flag == true) { reversedSinceSpawn = true };
    }

    // Half-time landed or ended: a probe sent across it is thrown away. A
    // speed the grid does not have yet (a stop's) the drums follow at once.
    prSpeedChanged { |x|
        speedCount = speedCount + 1;
        this.prFollowSpeedNow;
    }

    // ---- The server side ----------------------------------------------------

    // From MegaSA's init routine, after its groups: the cancel rings and choke
    // blocks (cleared: a boot.scd re-run hands back the same busses with their
    // old values), the voice groups, the drum effects and the probe's
    // responder, then the reverb's impulse responses, read in a routine of
    // their own: until they are in, the steps' effects pass their input dry.
    // A failure is posted and SA runs on without drums.
    build { |aDrumGroup, stepsBus, stepsOutBus, onsetBus, onsetOutBus, synthBus|
        try {
            // A drum group that is no node on the drums' own server is
            // refused before anything is taken. Group.tail(nil) is
            // Server.default's, and that is a RUNNING megalooper's scsynth
            // whenever one plays on this Mac: a test that built drums on a nil
            // group freed nodes 1000-1004 there (the meters, the guitar chain
            // with its plugin, the mixer, the drum group), silencing the
            // instrument mid-set.
            if(aDrumGroup.isKindOf(Node).not or: { aDrumGroup.server !== server }) {
                Error("no drum group on the drums' own server (" ++ aDrumGroup.asString ++ ")").throw
            };
            drumGroup = aDrumGroup;
            ringBusses = (steps: Bus.control(server, 1024), onset: Bus.control(server, 1024),
                synth: Bus.control(server, 1024));
            chokeBusses = (steps: Bus.control(server, 33), onset: Bus.control(server, 33),
                synth: Bus.control(server, 1));
            (ringBusses.values ++ chokeBusses.values).do { |b|
                server.sendBundle(nil, [\c_setn, b.index, b.numChannels] ++ Array.fill(b.numChannels, 0));
            };
            // The zero spectrum the reverb starts on: PartConv needs an
            // allocated buffer whose size its FFT divides, or it posts an error
            // for each of its four, so this one is in (synced) before the synth.
            irDummy = Buffer.alloc(server, MegaSADrumsFx.fftSize, 1);
            if(thisThread.isKindOf(Routine)) { server.sync };
            stepsGroup = Group.tail(drumGroup);
            repeatGroup = Group.tail(drumGroup);
            onsetGroup = Group.tail(drumGroup);
            fxBusses = [this.class.prIndex(stepsBus), this.class.prIndex(stepsOutBus)];
            fxSynth = Synth.tail(drumGroup, \megaSADrumsFx, this.prReverbArgs);
            onsetFxSynth = Synth.tail(drumGroup, \megaSAOnsetFx,
                [\in, this.class.prIndex(onsetBus), \out, this.class.prIndex(onsetOutBus)]);
            // The note sequencer's voices, after the drums' effects: onto the
            // synth's bus, which its chain (MegaSA's, after this group) works
            // on. With no synth bus they play into the steps' bus.
            synthGroup = Group.tail(drumGroup);
            this.prUseBusses(ringBusses[\steps].index, ringBusses[\onset].index,
                chokeBusses[\steps].index, chokeBusses[\onset].index,
                this.class.prIndex(stepsBus), this.class.prIndex(onsetBus),
                stepsGroup.nodeID, repeatGroup.nodeID, onsetGroup.nodeID, drumGroup.nodeID,
                synthRing: ringBusses[\synth].index, synthChoke: chokeBusses[\synth].index,
                synthBus: (synthBus !? { |b| this.class.prIndex(b) }) ?? { this.class.prIndex(stepsBus) },
                synthGrp: synthGroup.nodeID);
            probeResp = OSCFunc({ |msg| this.probeReply(msg[4].asInteger, msg[3]) },
                '/megaSADrumsProbe', server.addr);
            if(thisThread.isKindOf(Routine)) { server.sync };
            built = true;
            this.prReverbState(\dry);
            this.prStartPump;
            if(autoIR) { this.reloadReverb };
        } { |err|
            this.prFreeServerSide;
            ("MegaSADrums: the drums could not be built (" ++ err.errorString
                ++ "); megalooper plays on without them.").warn;
        };
    }

    // ---- The drums' reverb ---------------------------------------------------
    // reverbState: \none before build, \dry (built, no impulse responses yet,
    // or none to be had), \loading, \ready. Notified as \reverb, state.

    // Read the impulse responses from the kits folder's _ir/ and put them in:
    // the steps' effects synth is REPLACED in place by one on the new spectra
    // (PartConv takes its spectra only when its synth starts), and the spectra
    // it had go after it. In a routine of its own, or here with `inline` (from
    // a Routine: the loads sync). A load overtaken by another is dropped.
    reloadReverb { |inline = false|
        var serial, job;
        if(alive.not or: { built.not }) { ^this };
        irSerial = irSerial + 1;
        serial = irSerial;
        this.prReverbState(\loading);
        job = { MegaSADrumsFx.loadIR(server, kitDir, { |specs| this.prReverbLoaded(serial, specs) }, irReader) };
        if(inline) { job.value } { Routine(job).play(SystemClock) };
    }

    prReverbLoaded { |serial, specs|
        var old;
        if(alive.not or: { serial != irSerial } or: { fxSynth.isNil }) {
            specs.do { |b| b.free };
            ^this
        };
        if(specs.isNil) {
            this.prReverbState(if(irBuffers.isNil) { \dry } { \ready });
            ^this
        };
        old = irBuffers;
        irBuffers = specs;
        // The replace takes the old synth out as the new one goes in, before
        // the frees below reach the server: the old spectra are never read
        // after they are gone.
        fxSynth = Synth.replace(fxSynth, \megaSADrumsFx, this.prReverbArgs);
        // The new synth runs; the pump puts it to sleep again if all is quiet.
        fxAsleep.put(\steps, false);
        old.do { |b| b.free };
        this.prReverbState(\ready);
    }

    // The steps' effects' controls: the reverb on its spectra, or dry on the
    // zero one until they are in.
    prReverbArgs {
        var specs = irBuffers ?? { Array.fill(MegaSADrumsFx.irKeys.size, irDummy) };
        ^[\in, fxBusses[0], \out, fxBusses[1], \mix, reverbMix, \irOn, irBuffers.notNil.binaryValue]
            ++ MegaSADrumsFx.irKeys.collect { |k, i| [k, specs[i].bufnum] }.flat
    }

    prReverbState { |state|
        reverbState = state;
        this.prNotify(\reverb, state);
    }

    // ---- The effects' sleep -------------------------------------------------
    // The reverb (four convolutions, the costliest synth SA has) and the onset
    // chain run every block whether a drum sounds or not. Once the last voice
    // through one can have ended, and fxRest more for the reverb's tail
    // (0.3 s), the pump pauses its synth (n_run 0); the next hit for it wakes
    // it at once, before its voices are sent, which are stamped later. The
    // reverb stays awake while stepsHeld says something before it may sound
    // with no hit.
    *fxRest { ^1.0 }

    prFxNode { |slot| ^if(slot == \onset) { onsetFxSynth } { fxSynth } }

    // A hit for `slot` sounding until `end`.
    prWakeFx { |slot, end|
        var node = this.prFxNode(slot);
        if(end > (fxQuietAt[slot] ? inf.neg)) { fxQuietAt.put(slot, end) };
        if(node.notNil and: { fxAsleep[slot] == true }) {
            fxAsleep.put(slot, false);
            this.prSend(nil, [[12, node.nodeID, 1]]);
        };
    }

    prRestFx { |wall|
        [\steps, \onset].do { |slot|
            var node = this.prFxNode(slot), rest;
            if(node.notNil) {
                rest = (wall > ((fxQuietAt[slot] ? inf.neg) + this.class.fxRest))
                    and: { (slot == \onset) or: { (stepsHeld.value == true).not } };
                if(rest != (fxAsleep[slot] == true)) {
                    fxAsleep.put(slot, rest);
                    this.prSend(nil, [[12, node.nodeID, rest.not.binaryValue]]);
                };
            };
        };
    }

    // Where hits go, by bus and node ID, without building anything: build's
    // last step, and a stub test's first.
    prUseBusses { |stepsRing = 1000, onsetRing = 2024, stepsChoke = 3048, onsetChoke = 3081,
        stepsBus = 20, onsetBus = 22, stepsGrp = 1001, repeatGrp = 1002, onsetGrp = 1003, drumGrp = 1000,
        synthRing = 3114, synthChoke = 4138, synthBus = 24, synthGrp = 1004|
        ringBases = (steps: stepsRing, onset: onsetRing, synth: synthRing);
        chokeBases = (steps: stepsChoke, onset: onsetChoke, synth: synthChoke);
        outBusses = (steps: stepsBus, onset: onsetBus, synth: synthBus);
        groupIds = (steps: stepsGrp, repeat: repeatGrp, onset: onsetGrp, drum: drumGrp, synth: synthGrp);
    }

    prStartPump {
        pumpRoutine !? { |r| if(r !== thisThread) { r.stop } };
        pumpRoutine = Routine {
            while { alive } {
                try { this.pump(wallClock.value) } { |err| this.prPumpFailed(err) };
                pumpPeriod.wait;
            };
        }.play(SystemClock);
    }

    // A failing pump is posted once a second at most, and the routine goes on.
    prPumpFailed { |err|
        var wall = wallClock.value;
        if(lastPumpError.isNil or: { (wall - lastPumpError) > 1 }) {
            ("MegaSADrums: the pump failed — " ++ err.errorString).warn;
        };
        lastPumpError = wall;
    }

    // Everything goes: the routine, the Looper's controllers, the probe's
    // responder, the nodes (the groups take their voices with them), the
    // busses and every buffer. The Looper keeps the port and the sink, dead
    // now, so every call it still makes does nothing: on a reboot the old
    // Looper plays on, its MIDI clock calling its port every tick, until
    // ~setupLooper frees it after the new MegaSA is up (detach would leave it
    // calling nil).
    free {
        alive = false;
        this.prLetGo;
        this.prFreeServerSide;
        bufferCache.do { |b| b.free };
        bufferCache = IdentityDictionary.new;
        bufferFreeAt = IdentityDictionary.new;
        // A load still on its way frees what it brings (prKitLoaded).
        readsInFlight = IdentityDictionary.new;
        kitObjects = (steps: nil, onset: nil);
        onsetRun = nil;
        pending = List.new;
        captures = List.new;
        repeatMemory = List.new;
        lockedRepeats = Dictionary.new;
        logQueue = List.new;
        logState = nil;
    }

    // What build made, in reverse: the routine, the responder, the nodes, the
    // reverb's spectra (after the synth that reads them: the server takes
    // both in order) and the busses. Also what a failed build leaves.
    prFreeServerSide {
        pumpRoutine !? { |r| if(r !== thisThread) { r.stop } };
        pumpRoutine = nil;
        probeResp !? { |r| r.free };
        probeResp = nil;
        [fxSynth, onsetFxSynth, stepsGroup, repeatGroup, onsetGroup, synthGroup].do { |n| n !? { n.free } };
        fxSynth = nil;
        onsetFxSynth = nil;
        fxAsleep.clear;
        fxQuietAt.clear;
        stepsGroup = nil;
        repeatGroup = nil;
        onsetGroup = nil;
        synthGroup = nil;
        // A load still on its way frees what it brings (prReverbLoaded).
        irSerial = irSerial + 1;
        irBuffers.do { |b| b.free };
        irBuffers = nil;
        irDummy !? { |b| b.free };
        irDummy = nil;
        (ringBusses ? ()).do { |b| b.free };
        (chokeBusses ? ()).do { |b| b.free };
        ringBusses = nil;
        chokeBusses = nil;
        built = false;
        if(reverbState != \none) { this.prReverbState(\none) };
    }
}
