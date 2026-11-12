Looper {
    var <server, <bufDur, <>midiOut;
    var buffer, undoBuffer;
    var recSynth, engineSynth, masterSynth;
    var outBus;
    var clickRoutine, chordRoutine;
    var <>onChordChange;
    // recStartTime: when the take started, on SystemClock — the window counts
    // the recording's seconds from it.
    var <state, onsets, <recStartTime, loopDur;
    var onsetResp, pitchResp;
    var pitchSamples;
    // [tap peak, input peak, tap gain], linear, over the take so far — the
    // recorder's /looperLevels, four times a second. nil until the first
    // report. A tap far under the input is a starved analyser; see
    // tapStarvedDb. The gain is the automatic level the take was analysed at.
    var takeLevels, levelsResp;
    // The automatic level in front of the onset detector (LooperSynthDefs.tapLevelGraph):
    // the tracker synth, the control bus it writes the gain to, which every
    // analysis synth reads, and the gain and held peak it last reported (2 Hz),
    // linear. tapLevelAna is the input the tracker is listening to.
    var <tapGainBus, tapLevelSynth, tapLevelResp, tapLevelAna, <tapGain = 1, <tapLevel;
    var <>onAnalysis;
    var <>metronome = true;
    var <>inChannel = 0, <outChannel = 0;
    var <inChannelCount = 1;
    // Clean guitar tap: a SINGLE input channel read ONLY by the onset/pitch
    // analysis. RecordBuf keeps recording the processed inChannel, so what you
    // hear and what gets looped are unchanged. Distortion and ambient FX smear
    // note attacks, and blurred onsets are the documented root cause of meter
    // mis-detection (a straight 4/4 take coming out 7/8) — Onsets.kr needs
    // something crisp. This is normally the guitar's own hardware input, which
    // SC can read directly off the shared device: no Live track, no extra
    // loopback pair, and nothing in the path to smear the attacks. nil = no tap;
    // the analysis then reads inChannel, as it did before. See analysisIn.
    var <analysisChannel;
    // Onsets.kr detection threshold, shared by the recorder and the monitor so
    // what the lamp shows is what a take would actually detect. Higher rejects
    // more (noisy input / ghost onsets), lower admits more (quiet or soft
    // playing). 0.5 with mingap 20 was validated offline against the training
    // loops. Verified modulatable on a running synth — Onsets reads it per block.
    // Since 2026-11-05 it is a Setup setting, not a stage control: at a fixed
    // threshold Onsets hears the same take differently at another level (10 dB
    // changed half the readings, measured), so the knob had been compensating
    // for the tap's level. The automatic level (LooperSynthDefs.tapLevelGraph) does that now.
    var <onsetThreshold = 0.5;
    // Free-running analysis monitor: the same detection chain as the recorder,
    // but recording nothing, so the threshold can be tuned against live playing
    // without committing a take. onMonitor is called with (level, onset, strength).
    // monitorWanted is the USER's intent, kept apart from monitorSynth (whether a
    // node exists) so a start requested before the SynthDefs land can be honoured
    // later — and cancelled by a stop in the meantime. See startAnalysisMonitor.
    var monitorSynth, monitorResp, monitorOnsetResp, monitorWanted = false;
    var <>onMonitor;
    // ---- Autostart -----------------------------------------------------------
    // For a player with no footswitch (2026-11-12, the duo's idea for the
    // release): with `autostart` on and no loop, the looper waits, and the
    // take starts on the first note. autostartSynth is the recorder waiting
    // (LooperSynthDefs.recAutoGraph): the note is the analysis input's level
    // rising through startLevelDb, the level the input meter is marked at,
    // after autostartQuiet seconds under it, and the take begins
    // autostartLeadMs before it, so the attack is whole and the downbeat on
    // it. The synth becomes the take's recorder on its /looperAutostart; the
    // stop stays a press (R, the Trigger tile, a footswitch), and R while it
    // waits starts a take by hand, as without it.
    var <autostart = false, <startLevelDb = -40, autostartSynth, autostartResp;
    // The room (roadmap item 12): the monitor's hits kept in the model, not
    // only lit by the lamp. A ring of the last liveOnsetMax, their times
    // (SystemClock seconds, as heard) and strengths in two Arrays made once
    // (a Float sits in its slot, so a hit allocates nothing); the level the
    // monitor last reported (15 Hz). Each hit is also said as \liveOnset
    // (time, strength).
    var liveOnsetTimes, liveOnsetStrengths, liveOnsetHead = 0, <liveOnsetCount = 0, <liveLevel;
    // The take in force was heard this many dB quieter on the analysis tap
    // than on the recorded input (tapStarvedDb), or nil: a starved analyser
    // fits its meter to whatever crossed the threshold, and the reading looks
    // like any other, so the window says it until the next take.
    var <tapStarvedGap;
    // ---- Overdub meter detection -------------------------------------------
    // For loops that start atmospheric: take one has no onsets, so no meter is
    // found and Live's transport is never started (correct — there is no beat to
    // follow). Overdub a rhythmic pattern and this derives the meter from THAT,
    // then starts Live. On by default since 2026-11-07: with the fallback
    // meter off (its default, MeterAnalyzer.fallbackOn), a take with no beat
    // has no meter, and an overdub is how it gets one. Gated on that: a loop
    // with a meter is never re-read (prHasValidMeter).
    var <analyzeOverdubs = true;
    // The loop is already a fixed length here, which makes the fit MORE
    // constrained than take one — but an atmospheric loop tends to be long, and
    // the default 4-bar enumeration cannot describe a 12 s pad at 120 BPM (six
    // bars). Measured: at the default limit that loop is reported as 12/8 at
    // 60 BPM — confidently wrong — and at 8 bars it comes out 4/4 at 120.
    var <overdubMaxBars = 8;
    // Guards against the other failure the wider search introduces: a fine grid
    // will always "fit" a handful of scattered onsets. Measured on synthetic
    // patterns, density 0.5 admits a real played pattern and rejects rubato,
    // while 0.6 starts rejecting genuine syncopation. Both provisional — they
    // want checking against real playing.
    var <overdubMinOnsets = 8;
    var <overdubMinDensity = 0.5;
    // [loopPhase, strength] per onset, in LOOP coordinates. Kept after the
    // overdub ends so "Detect now" can re-run on the same material.
    var overdubOnsets, overdubSynth, overdubResp;
    // The engine publishes its read position here so the overdub analyser can
    // latch it at each onset — loop coordinates with no clock arithmetic.
    // Readable because Megalooper SA's drums probe it to measure how far the
    // loop's audio has drifted from the language's clock (MegaSADrums).
    var <phaseBus;
    // Processed loop-return from Live, on its OWN stereo input pair (distinct
    // from inChannel/guitar). Only the loop-chaining recorder reads it; normal
    // overdubs read inChannel alone, so the loop's own output never feeds back.
    var <returnChannel = 0;
    // ---- Session recording -------------------------------------------------
    // Live's MASTER, routed back to a spare input pair, so the set can be
    // recorded as the room heard it. nil on a rig with no such pair. It is a
    // fourth channel role and it is READ-ONLY here: nothing plays it, nothing
    // analyses it, it is only ever written to disk.
    var <sessionChannel;
    // The recorder itself (see LooperSessionRecorder). Owned here rather than
    // by the scripts because it needs the server and the channel numbers, and
    // because the transport has to know when it is running — a MIDI Start sent
    // mid-recording would relocate Live and overwrite the take.
    var sessionRec;
    // More for a session's header, from whoever knows more than the Looper
    // (Megalooper SA: its sound and chains): a function answering an Event,
    // or nil. What it answers never replaces a field of the Looper's own, and
    // its failing costs the header nothing.
    var <>sessionExtras;
    // The transport that follows the loop (LoopTransport): Live's MIDI clock
    // through midiOut (LiveMidiTransport), made when first asked for, or
    // Megalooper SA's drums (MegaSATransport), which MegaSADrums.attach puts
    // here. Whether a Start relocates anything worth protecting is its own
    // (startsRelocate).
    var transport;
    // ---- Onset notes -------------------------------------------------------
    // The loop's detected onsets replayed every pass as MIDI notes (or by the
    // drums' onset kit): LooperOnsetNotes, held here and made when first asked
    // for (onsetNotesPart). The Looper's onsetNote* methods are its facade.
    var onsetNotesPart;
    var startFrame = 0, <loopFrames = 0;
    var <lastResult, undoState;
    var <reverseFlag = false;
    // ---- Half-time (docs/dev/rc600-picks.md, 3a) ------------------------------
    // The loop at half speed, an octave down, each pass twice as long, with
    // SA's drums at half tempo too (MegaSADrums' Half-time, the duo's choice
    // of 2026-10-28; they keep their pitch). `speed` is what the engine plays at, 1 or
    // 0.5; `halfTime` what a press does next: \off, \armed (lands on
    // halfTimeAt), \on, \releasing (back to 1 on halfTimeAt). Both edges are
    // the loop's own boundaries, so the passes stay on loopStartTime's grid:
    // a half-speed pass is two of its loops, counted from passOrigin. The
    // engine takes a new speed on the sample its reference wraps
    // (LooperSynthDefs.engineGraph), so the language only sends it in the right pass.
    // speed, passOrigin and speedChangedAt are the timeline's (LoopTimeline).
    var <halfTime = \off, <halfTimeAt;
    var halfTimeSentAt;
    // A reverse armed for the next boundary (reverse): `reverseArmed`, and
    // `reverseAt` where it lands; reverseFlag flips there.
    var <reverseArmed = false, <reverseAt, reverseSentAt;
    // ---- Breaks -------------------------------------------------------------
    // Drop the looper out so the room can play into the hole, then come back ON
    // A LOOP DOWNBEAT. This MUTES and never stops: stopPlayback would tear down
    // the MIDI clock and take Live's transport with it, and the whole point is
    // that the loop returns precisely where it would have been. Everything the
    // looper makes passes through masterSynth, so one gate there covers the
    // engine, the granular layer and every BBCut voice.
    //
    // The unit is LOOP PASSES, not bars. A fixed bar count resumed wherever it
    // happened to land, which put the loop back mid-phrase; what a break wants
    // is to hand the bar line back intact. So the hole opens on the stomp and
    // closes at a loop boundary — and the pass you struck it in COUNTS as the
    // first of them. breakLoops = 1, the default, therefore comes back on the
    // NEXT loop downbeat rather than the one after it.
    var <breakLoops = 1, <onBreak = false;
    // When the gate reopens, in SystemClock seconds — nil when no break is on.
    // A loop-length break can run 15 s in a slow 7/8, which is long enough that
    // "when does it come back?" needs an answer on screen.
    var <breakEndsAt;
    // Where the playhead is has to be ASKED for (a control-bus round trip), so
    // the resume is scheduled in a callback that lands a few ms after the mute.
    // The timeline's \break token says so, so a callback belonging to a break
    // that was cancelled or re-fired in the meantime knows to do nothing.
    // The latest time a gate write sent ahead is due on the server (endBreak's
    // reopening, 20 ms on), or nil: a write sent before then goes in again
    // just after it (prSetBreakGate).
    var breakGateAt;
    // ---- The arc ------------------------------------------------------------
    // Two axes over the same three output levels (dry loop, cutter, granular).
    //
    // `intensity` is the expression pedal: it takes the granular layer's LEVEL
    // and the cutter's DENSITY from nothing up to what was configured, and
    // leaves the dry loop and the cutter's own level alone. So heel is the dry
    // loop with a cutter that is running but barely chopping, toe is everything
    // as dialled in. It DEFAULTS TO 1 so a rig with no pedal connected behaves
    // exactly as it did before this existed — the pedal takes over the moment
    // it is touched, and never before.
    //
    // `dissolvePos` is the ending, run by a timed ramp rather than by hand, so
    // both hands are free for the last melody. Things leave in the order that
    // sounds like a piece ending rather than like a fade: the cutter first, then
    // the body of the loop, and the granular haze last.
    //
    // Both are MULTIPLIERS over the stored levels, never replacements. The
    // per-voice cutter mix and the granular level stay exactly where they were
    // set, so the GUI keeps telling the truth about them while the arc moves.
    var <intensity = 1.0;
    var <dissolvePos = 0.0, <dissolveLoops = 4, <dissolving = false;
    var <>dissolveStops = true;
    var dissolveRoutine;
    // ---- Readings -----------------------------------------------------------
    // The analyser returns every reading that passed the fit, ranked, the
    // answer first (MeterAnalyzer:analyze, `candidates`). `nextReading` — one
    // footswitch — moves the take to the next one, landing on a loop boundary
    // where Live's bar line will agree. Why one switch and a ranked list rather
    // than a menu: on realistic takes the runner-up is the truth in a third of
    // the wrong meters (docs/dev/meter-perception.md, "Where the truth sits").
    //
    // analysedResult is what the analyser HEARD, kept apart from lastResult
    // once a reading is applied, so the cycle has a home: index 0 is always the
    // way back. readingIndex is the reading in force.
    var <analysedResult;
    var <readingIndex = 0;
    // The reading armed but not yet landed — (index:, result:, at:, loops:,
    // restart:) — or nil. Published as \reading so the header can count down.
    var <pendingReading;
    // The reading in force until a landing's `at`: lastResult swaps a little
    // before it (prLandReading), and countResult answers this meanwhile.
    var landingFrom;
    // Where the transport's count stands (clockTicksAtRef, clockRefTime,
    // clockTickRate, clockPeriod) is the transport's own: LoopTransport.ticksAt
    // says, for any future loop boundary, whether its bar line falls on it,
    // which is what decides where a reading lands.
    // ---- Granular voice ----------------------------------------------------
    // The grains: LooperGrains, made when first asked for (grainsPart). The
    // Looper's granular* methods are its facade; what the grains read (the
    // buffer, the loop's span, the pulse, the rate, the arc's mix) the Looper
    // hands over (prGrainSource).
    var grainsPart;
    var <transportMode = \full;
    var <latencyMs = 0;
    var <declickMs = 3;
    var <feedback = 1.0;
    var <>chordMinPerWindow = 3;
    // The cutter: LooperCutter, made when first asked for (cutterPart). The
    // Looper's bbcut* and voice methods are its facade.
    var cutterPart;
    // In \insert mode a LooperCutGate in each of the cutter's voices writes
    // `insertBus` (1 while a repetition plays); the engine reads it to duck
    // the dry loop. The engine's, so the Looper's.
    var insertBus;
    // The loop's time (LoopTimeline): when the current engine started, in
    // SystemClock (logical) seconds, the anchor every language-side layer
    // counts the loop from (Megalooper SA's drums put their grid on it); the
    // speed and the passes; and what is armed on it. Made when first asked for.
    var timeline;
    // MIDI-clock sync offset (ms, may be negative). Shifts WHEN SC sends the MIDI
    // Start + clock stream relative to the loop's audio, to cancel the ~10-20 ms
    // Live otherwise lags as a MIDI-clock follower: negative pulls Live earlier.
    // A setting of the Looper's (calibrated, kept per rig), handed to Live's
    // transport (LiveMidiTransport.syncMs_), which applies it to the Start and
    // folds a change into the running stream. SA's drums ignore it. See also
    // Live's own MIDI Clock Sync Delay preference for a per-input trim.
    var <abletonSyncMs = 0;
    // Loop chaining, the capture: LooperChainRecorder, made when first asked
    // for (chainPart). It records the next loop over this one and hands it
    // over on a boundary; the swap is the Looper's (prSwapInNextLoop).
    var chainPart;
    // Construction is ASYNCHRONOUS: buffers, busses and SynthDefs reach the
    // server on init's own Routine, so an instance is not usable the instant
    // Looper() returns. Anything that sends s_new before this flips gets a silent
    // "SynthDef not found" from scsynth — a node that never exists while the
    // client-side Synth object looks perfectly alive. waitForReady is how a
    // caller running in a Routine (boot.scd) holds off until it is safe.
    var <ready = false;

    *new { |server, midiOut, bufDur=30|
        ^super.new.init(server, midiOut, bufDur)
    }

    // Where the repository lives, derived from where this class file actually is.
    //
    // Every script under scripts/ resolves its own paths from
    // thisProcess.nowExecutingPath, which is correct and needs nothing from here
    // — except that nowExecutingPath is nil when a block is PASTED into the IDE
    // rather than opened from disk. This is the fallback for that case, and it
    // beats a hardcoded absolute path because it is true on any machine.
    //
    // File.realpath matters: classes/ is normally reached through a symlink in
    // Extensions, so filenameSymbol reports the link and only realpath gives the
    // repo. Two .dirname hops then go classes/Looper.sc -> classes -> the root.
    *repoRoot {
        var here = File.realpath(this.filenameSymbol.asString);
        var root = here !? { here.dirname.dirname };
        if(root.isNil or: { File.exists(root +/+ "scripts").not }) {
            Error("megalooper: cannot locate the repository from "
                ++ this.filenameSymbol
                ++ " — there is no scripts/ beside classes/. If you COPIED "
                "classes/ into Extensions, replace it with a symlink to the "
                "repo (see install.sh).").throw;
        };
        ^root
    }

    init { |aServer, aMidiOut, aBufDur|
        server = aServer;
        midiOut = aMidiOut;
        bufDur = aBufDur;
        // Cmd-period frees every node and stops every routine: told, so the
        // looper can say so (cmdPeriod) instead of claiming a loop that plays.
        CmdPeriod.add(this);
        this.prSetState(\empty);
        onsets = List.new;
        pitchSamples = List.new;
        this.initBBCut;

        Routine {
            buffer = Buffer.alloc(server, server.sampleRate * bufDur, 2);
            undoBuffer = Buffer.alloc(server, server.sampleRate * bufDur, 2);
            this.chainPart.allocBuffer(server, server.sampleRate * bufDur);
            outBus = Bus.audio(server, 2);
            // "Insert"-mode duck flag: 1 while the cutter is playing a
            // repetition, 0 otherwise. Defaults to 0 so the dry loop passes
            // until a roll writes it. Read by the engine, written by LooperCutGate.
            // Shared across voices (last writer wins): with several polyrhythmic
            // voices the duck follows whichever wrote most recently rather than a
            // strict OR — fine for the usual single-voice case.
            insertBus = Bus.control(server, 1);
            phaseBus  = Bus.control(server, 1);
            // The analysis gain, written by the tap-level tracker. Unwritten
            // (0) reads as unity in LooperSynthDefs.tapGain, so a tracker that never started
            // leaves detection as it was rather than silencing it.
            tapGainBus = Bus.control(server, 1);
            // Grain windows for the granular layer, one buffer per shape.
            // Allocated empty here and FILLED AFTER the sync: Buffer.sendCollection
            // would send its data from a language-side /done callback that can
            // land after this sync, leaving a silent (all-zero) window buffer.
            this.grainsPart.allocEnvBufs(server);
            server.sync;
            this.grainsPart.fillEnvBufs;
            this.loadSynthDefs;
            server.sync;
            masterSynth = Synth.tail(server, \looperMaster, [
                \inBus, outBus.index,
                \out, outChannel
            ]);
            // At the head, so the analysis synths read this block's gain.
            tapLevelAna = this.analysisIn;
            tapLevelSynth = Synth.head(server, \looperTapLevel, [
                \ana, tapLevelAna,
                \out, tapGainBus.index
            ]);
            ready = true;
            "Looper ready.".postln;
            this.prAutostartFollow;
        }.play;

        overdubOnsets = List.new;

        onsetResp = OSCdef(\looperOnset, { |msg|
            if(state == \recording) {
                // [time, strength] — strength feeds the accent analysis.
                onsets.add([msg[3], msg[4]]);
            };
        }, '/looperOnset');

        pitchResp = OSCdef(\looperPitch, { |msg|
            if(state == \recording) {
                pitchSamples.add([msg[3], msg[4], msg[5]]);
            };
        }, '/looperPitch');

        levelsResp = OSCdef(\looperLevels, { |msg|
            if(state == \recording) { takeLevels = [msg[3], msg[4], msg[5]] };
        }, '/looperLevels');

        // The recorder waiting for the first note heard it: [cmd, node, id, lead].
        autostartResp = OSCdef(\looperAutostart, { |msg| this.prAutostartStarted(msg[1]) }, '/looperAutostart');

        // Said only when the gain moves by half a dB, so a window showing it
        // repaints twice a second at most and mostly not at all.
        tapLevelResp = OSCdef(\looperTapLevel, { |msg|
            var moved = (msg[3].max(1e-6).ampdb - tapGain.max(1e-6).ampdb).abs >= 0.5;
            tapLevel = msg[4];
            if(moved) {
                tapGain = msg[3];
                this.changed(\tapGain, tapGain);
            };
        }, '/looperTapLevel');
    }

    // The SynthDefs and the pieces they share are LooperSynthDefs' (since
    // 2026-11-08, docs/dev/architecture.md 5, step 8): pure, they build with
    // no server and no Looper.
    loadSynthDefs { LooperSynthDefs.loadSynthDefs }

    // EVERY state transition goes through here. Assigning `state` directly moves
    // the machine without telling anyone, which is exactly why nothing could
    // display it before — views had no event to subscribe to. Keep it that way:
    // if you add a transition, call this rather than touching `state`.
    prSetState { |newState|
        state = newState;
        this.changed(\state, newState);
        // No loop: Autostart waits; a loop: it does not.
        this.prAutostartFollow;
    }

    // The analysis in force, and \result said with it (the result, or nil):
    // the one place lastResult is written (a take, an overdub's meter, a
    // reading landing, a multiply or a chain scaling it, undo, clear). Before
    // 2026-11-08 nothing was said, the window polled the result's identity,
    // and only the onAnalysis slot heard of it, which undo, clear and multiply
    // never called (docs/dev/architecture.md 3.6).
    // Every notification a Looper says (`changed(what, args...)`): what it
    // carries, and whether it is a \state (its arguments are the new value; the
    // last one said is what holds) or an \event (something that happened). The
    // window, MIDI's send-back, the drums, the AI apps and the action log
    // listen, and the action log writes them into a set's log, so this is a
    // file format too. A test holds every `changed` in the class to this table
    // (test-notifications.scd). docs/dev/architecture.md 3.6.
    *notifications {
        ^(
            // ---- the transport
            state: [\state, [\state], "\\empty, \\recording, \\playing, \\overdubbing or \\stopped"],
            refused: [\event, [\action, \why], "an action it would not take, and why, in words"],
            nextRecState: [\state, [\state], "the next loop: \\idle, \\armed, \\recording or \\stopping"],
            reverse: [\state, [\backwards], "the loop plays backwards"],
            reverseArmed: [\state, [\armed], "the other direction is armed for the next boundary"],
            halfTime: [\state, [\state], "\\off, \\armed, \\on or \\ending"],
            speed: [\state, [\rate], "the engine's speed: 1, or 0.5 at half-time"],
            sessionRecording: [\state, [\on], "the set is being recorded"],
            transportMode: [\state, [\mode], "what goes to Live: \\full, \\startOnly or \\off"],
            // ---- the analysis
            result: [\state, [\result], "the reading in force (an Event), nil once cleared"],
            reading: [\state, [\pending], "a reading armed for a boundary (an Event), nil when none"],
            readingIndex: [\state, [\index], "which reading of the take is in force (0: the analyser's)"],
            chord: [\event, [\segment], "the chord the loop plays now (a segment Event)"],
            overdubDetected: [\event, [\result], "a meter read from an overdub"],
            tapStarved: [\state, [\gap], "the take was heard this many dB under the input on the tap, or nil"],
            tapGain: [\state, [\gain], "the automatic level in front of the onset detector, linear"],
            onsetThreshold: [\state, [\threshold], "the onset detector's threshold"],
            analysisMonitor: [\state, [\on], "the analysis monitor runs"],
            autostart: [\state, [\on], "with no loop, a take starts on the first note (Autostart)"],
            autostartWaiting: [\state, [\waiting], "no loop, and Autostart waits for the first note"],
            startLevelDb: [\state, [\db], "the level a first note rises through to start a take, dBFS"],
            liveOnset: [\event, [\time, \strength], "the monitor heard an onset (SystemClock seconds, 0..1)"],
            analyzeOverdubs: [\state, [\on], "overdubs are read for a meter while the loop has none"],
            trainingExport: [\event, [\base], "a labelled loop written: the path its files share"],
            // ---- the rig
            inChannelCount: [\state, [\count], "1 or 2 input channels"],
            analysisChannel: [\state, [\channel], "the clean tap's input, or nil"],
            outChannel: [\state, [\channel], "where the loop goes"],
            returnChannel: [\state, [\channel], "the processed loop's return, for the next loop"],
            sessionChannel: [\state, [\channel], "the master's return, for recording the set"],
            latencyMs: [\state, [\ms], "overdub latency"],
            abletonSyncMs: [\state, [\ms], "Live sync"],
            declickMs: [\state, [\ms], "the loop seam's fade"],
            chainRecOffsetMs: [\state, [\ms], "the next loop's record trim"],
            // ---- the loop's levels and the arc
            feedback: [\state, [\level], "overdub feedback, 0..1"],
            intensity: [\state, [\level], "the arc, 0..1"],
            break: [\state, [\on], "a break is on"],
            breakEndsAt: [\state, [\time], "when the break ends (SystemClock seconds), or nil"],
            breakLoops: [\state, [\loops], "loop passes a break covers"],
            dissolving: [\state, [\on], "a dissolve runs"],
            dissolvePos: [\state, [\position], "how far the dissolve is, 0..1 (30 times a second while it runs)"],
            dissolveLoops: [\state, [\loops], "loop passes the dissolve takes"],
            // ---- the cutter
            bbcut: [\state, [\on], "the cutter runs"],
            bbcutMode: [\state, [\mode], "\\mix, \\insert or \\gate"],
            bbcutState: [\event, [\voices], "the voices changed wholesale (a preset recalled)"],
            bbcutVoices: [\state, [\voices], "a voice's settings (said per pixel of a drag)"],
            // ---- the grains
            granular: [\state, [\on], "the grains play"],
            granularAmp: [\state, [\value], "their level"],
            granularMorph: [\state, [\value], "drone to pulse, 0..1"],
            granularPitch: [\state, [\value], "semitones"],
            granularDetune: [\state, [\value], "semitones of random detune"],
            granularSize: [\state, [\value], "grain size, a multiple of morph's"],
            granularSizeRand: [\state, [\value], "grain size randomness"],
            granularDensity: [\state, [\value], "density, a multiple of morph's"],
            granularPosition: [\state, [\value], "read position"],
            granularScan: [\state, [\value], "extra passes per loop"],
            granularSpray: [\state, [\value], "read-position spray, ms"],
            granularEnv: [\state, [\index], "the grain window (LooperGrains.envNames)"],
            granularFollowChords: [\state, [\on], "the grains follow the chords"],
            // ---- the onset notes
            onsetNotes: [\state, [\on], "the onset notes play"],
            onsetNote: [\state, [\note], "the note they play"],
            onsetNoteChannel: [\state, [\channel], "their MIDI channel, 0..15"],
            onsetNoteVelLo: [\state, [\velocity], "the quietest hit's velocity"],
            onsetNoteVelHi: [\state, [\velocity], "the loudest hit's velocity"],
            onsetNoteDynRange: [\state, [\db], "dB below the loudest that maps to the lowest velocity"],
            onsetNoteGateMs: [\state, [\ms], "how long a note is held"],
            onsetNoteOffsetMs: [\state, [\ms], "timing trim"],
            onsetNoteChance: [\state, [\chance], "how likely each hit sounds, 0..1"],
            onsetNotePattern: [\event, [\hits], "the pattern was built again: how many hits"]
        )
    }

    // Cmd-period has freed every synth of the looper's (the engine, the
    // master, the recorder, the grains, the cutter's voices) and stopped every
    // routine (the clocks, the onset notes, the chords), and nothing makes
    // them again. Before 2026-11-08 the looper went on saying it played, with
    // a MIDI clock running. Now it forgets the nodes and routines, says the
    // cutter and the grains are off and the loop stopped (its buffer is kept),
    // stops answering ready, and says what to do, as MegaSA does.
    cmdPeriod {
        if(ready.not) { ^this };
        ready = false;
        engineSynth = nil; recSynth = nil; masterSynth = nil; grainsPart !? { |g| g.forget };
        tapLevelSynth = nil; monitorSynth = nil; overdubSynth = nil; chainPart !? { |c| c.forget };
        clickRoutine = nil; chordRoutine = nil;
        dissolveRoutine = nil; this.timeline.forget; this.transport.forget;
        cutterPart !? { |c| c.forget };
        this.changed(\granular, false);
        if(autostartSynth.notNil) { autostartSynth = nil; this.changed(\autostartWaiting, false) };
        if((state != \empty) and: { state != \stopped }) { this.prSetState(\stopped) };
        "Looper: Cmd-period freed its synths and stopped its clocks, so the loop is silent; run boot.scd again (or Apply and restart) to rebuild it. The recorded loop is kept until then.".warn;
    }

    prSetResult { |r|
        lastResult = r;
        this.changed(\result, r);
    }

    // Multi-purpose transport, per Ableton's Looper spec.
    trigger {
        case
            { state == \empty }       { this.startRecord }
            { state == \recording }   { this.stopRecordStartPlay }
            { state == \playing }     { this.startOverdub }
            { state == \overdubbing } { this.endOverdub }
            { state == \stopped }     { this.startPlay };
    }

    startRecord {
        var defName = if(inChannelCount == 1) { \looperRecMono } { \looperRec };
        // A press while Autostart waits: a take by hand, as without it.
        if(autostartSynth.notNil) { this.prAutostartDisarm };
        this.prTakeBegins(true);
        buffer.zero;
        recStartTime = SystemClock.seconds;
        this.prTapLevelFollow;
        recSynth = Synth(defName, [
            \bufnum, buffer.bufnum,
            \in, inChannel,
            \ana, this.analysisIn,
            \onsetThreshold, onsetThreshold,
            \tapGainBus, this.prTapGainIndex
        ], server);
        this.prTakeStarted(());
    }

    // What a take's start does in the language, whether a press started it
    // (startRecord) or Autostart's first note (prAutostartStarted). `audio`:
    // the undo snapshot copies the buffer; Autostart's has nothing to copy
    // (there was no loop) while its take is being written into it.
    prTakeBegins { |audio|
        this.prCancelBBCutEnable;
        if(this.bbcut) { this.disableBBCut };
        // A reading armed for the loop being replaced has nothing to land on.
        this.prCancelReading;
        this.snapshotForUndo(audio);
        onsets.clear;
        pitchSamples.clear;
        takeLevels = nil;
        this.prSetTapStarved(nil);
        // The replay pattern belongs to the take it was analysed from. Dropping
        // it here means the engine spawned at the stop finds nothing to play
        // until the deferred analysis builds the new one, rather than
        // replaying the previous loop's rhythm over this one.
        this.prClearOnsetPattern;
    }

    prTakeStarted { |more|
        this.prLogEvent(\recordStart,
            (threshold: onsetThreshold, ana: this.analysisIn, in: inChannel).putAll(more), recStartTime);
        this.prSetState(\recording);
        "Recording...".postln;
    }

    // ===================================================================
    // Autostart — a take that starts on the first note
    // ===================================================================
    // See the variables' note. The level's range, dBFS: the input meter's.
    *startLevelMinDb { ^-60 }
    *startLevelMaxDb { ^0 }
    // Seconds the input must stay under the level before a note can start a
    // take: so a guitar still ringing after a Clear starts nothing, and a
    // note can (the gap before a first note is longer).
    *autostartQuiet { ^0.2 }
    // How far before the level's crossing the take begins, ms: past the
    // seam's fade-in (declickMs) and a moment for the attack under the level.
    autostartLeadMs { ^declickMs + 2 }

    autostart_ { |on|
        on = on == true;
        if(on != autostart) {
            autostart = on;
            this.changed(\autostart, on);
        };
        this.prAutostartFollow;
    }

    startLevelDb_ { |db|
        var old = startLevelDb;
        startLevelDb = db.clip(this.class.startLevelMinDb, this.class.startLevelMaxDb);
        autostartSynth !? { |s| s.set(\startLevel, startLevelDb.dbamp) };
        if(startLevelDb != old) { this.changed(\startLevelDb, startLevelDb) };
    }

    // Whether Autostart is waiting for the first note now.
    autostartWaiting { ^autostartSynth.notNil }

    // It waits while it is on, the looper is ready and has no loop; called
    // wherever one of those changes (prSetState, autostart_, the end of init).
    prAutostartFollow {
        var want = autostart and: { ready } and: { state == \empty } and: { buffer.notNil };
        case
        { want and: { autostartSynth.isNil } } { this.prAutostartArm }
        { want.not and: { autostartSynth.notNil } } { this.prAutostartDisarm };
    }

    // A loop's audio may still be on its way out of the buffer (a Clear's
    // zero, an undo's copy: asynchronous); zeroed again here, which is done
    // long before a note can start a take (autostartQuiet).
    prAutostartArm {
        var defName = if(inChannelCount == 1) { \looperRecAutoMono } { \looperRecAuto };
        this.prTapLevelFollow;
        buffer.zero;
        autostartSynth = Synth(defName, [
            \bufnum, buffer.bufnum,
            \in, inChannel,
            \ana, this.analysisIn,
            \onsetThreshold, onsetThreshold,
            \tapGainBus, this.prTapGainIndex,
            \startLevel, startLevelDb.dbamp,
            \quiet, this.class.autostartQuiet,
            \lead, this.autostartLeadMs / 1000
        ], server);
        this.changed(\autostartWaiting, true);
    }

    prAutostartDisarm {
        autostartSynth.free;
        autostartSynth = nil;
        this.changed(\autostartWaiting, false);
    }

    // The waiting recorder heard the first note and records: the take is
    // under way, as a press would have started it. A reply from a recorder
    // no longer waiting (disarmed as the note came) is ignored; it was freed.
    prAutostartStarted { |nodeID|
        if(autostartSynth.isNil or: { autostartSynth.nodeID != nodeID } or: { state != \empty }) { ^this };
        recSynth = autostartSynth;
        autostartSynth = nil;
        this.prTakeBegins(false);
        recStartTime = SystemClock.seconds;
        this.changed(\autostartWaiting, false);
        this.prTakeStarted((autostart: true, startLevelDb: startLevelDb, leadMs: this.autostartLeadMs));
    }

    // ===================================================================
    // Loop position — what a playhead display needs
    // ===================================================================
    // The engine already publishes its READ position, in seconds, on phaseBus
    // (see LooperSynthDefs.engineGraph), because the overdub analyser needs it. Nothing here
    // touches a SynthDef: the language just reads the bus that is already
    // written, so a position display costs one control-bus poll and no audio.

    // Where the playhead is, in seconds into the loop. ASYNCHRONOUS — Bus:get is
    // a /c_get round trip — so the value arrives in the callback, never as a
    // return value. nil means there is nothing to report (no engine, or no loop
    // recorded), which a caller must render as "no position" rather than as 0:
    // a playhead parked at the start and a playhead that does not exist are
    // different things.
    queryLoopPhase { |action|
        if(engineSynth.isNil or: { loopFrames <= 0 } or: { phaseBus.isNil }) {
            action.value(nil);
            ^this
        };
        phaseBus.get { |v| action.value(v) };
        ^this
    }

    // The loop's length in seconds; 0 when nothing is recorded. The authority is
    // loopFrames (what the engine actually plays), not lastResult[\loopDur]
    // (what the analyser proposed) — they differ until the snap lands.
    loopDuration {
        ^if(loopFrames > 0) { loopFrames / server.sampleRate } { 0 }
    }

    // Public form of prHasValidMeter: a real grid fit, as opposed to the
    // length-anchored fallback or no analysis at all. Exposed because refusing
    // to start the cutter (see enableBBCut) is only honest if the UI can say WHY.
    hasValidMeter { ^this.prHasValidMeter }

    // The reading the loop plays by now. lastResult, but for the moment
    // before a reading lands: it swaps 20 ms before the boundary, or half a
    // second when the cutter must be respawned for it (prLandReading), and
    // until the boundary the loop still plays by the one before.
    countResult { ^if(pendingReading.notNil) { landingFrom ? lastResult } { lastResult } }

    // What the count on Perform counts to: each event whose time is known
    // ahead, as (what:, at:), `at` in SystemClock seconds, the time the engine
    // plays it. A break's end; a reading landing; the next loop's record
    // starting, or ending once asked to; the cutter coming in; half-time
    // landing or ending. The cutter and the next loop wait for the next
    // boundary from loopStartTime, as they do themselves.
    upcoming { |now|
        var list = List.new;
        now = now ? SystemClock.seconds;
        breakEndsAt !? { |t| list.add((what: \break, at: t)) };
        pendingReading !? { |p| list.add((what: \reading, at: p[\at])) };
        if(this.loopDuration > 0) {
            if(this.nextRecState == \armed) { list.add((what: \recordNextLoop, at: this.prNextBoundaryAt(now))) };
            if(this.nextRecState == \stopping) { list.add((what: \recordNextLoopEnds, at: this.prNextBoundaryAt(now))) };
            if(this.bbcutEnabling and: { this.bbcut.not }) { list.add((what: \cutter, at: this.prNextBoundaryAt(now))) };
            if(halfTime == \armed) { list.add((what: \halfTime, at: halfTimeAt)) };
            if(halfTime == \releasing) { list.add((what: \halfTimeEnds, at: halfTimeAt)) };
            if(reverseArmed) { list.add((what: if(reverseFlag) { \forward } { \reverse }, at: reverseAt)) };
        };
        ^list.asArray
    }

    // The next loop boundary after `now`, counted from loopStartTime as the
    // reading, the next loop and the cutter count it; at half-time, the next
    // end of a half-speed pass, counted from where they began.
    prNextBoundaryAt { |now| ^this.timeline.nextBoundaryAt(now) }

    // A pass in wall time: the loop's length at the speed it plays.
    wallPeriod { ^this.timeline.wallPeriod }

    // Where a pass at the speed now began (one of them): loopStartTime, or at
    // half-time the boundary it landed on. The onset kit counts from it.
    passStart { ^this.timeline.passStart }

    // ---- The loop's time (LoopTimeline) ---------------------------------------
    timeline { ^timeline ?? { timeline = LoopTimeline({ this.loopDuration }) } }
    loopStartTime { ^this.timeline.loopStartTime }
    speed { ^this.timeline.speed }
    passOrigin { ^this.timeline.passOrigin }
    speedChangedAt { ^this.timeline.speedChangedAt }

    // The speed after the next boundary, with what is armed: a landing or a
    // release.
    prSpeedAfterNext { ^switch(halfTime, \armed, { 0.5 }, \releasing, { 1 }, { this.speed }) }

    stopRecordStartPlay {
        var sr         = server.sampleRate;
        var firstOnset = if(onsets.isEmpty) { 0 } { onsets[0][0] };
        // Freeze the analysis inputs: the deferred pass below reads them, and a
        // subsequent record must not clobber them mid-analysis.
        var onsetsSnap = onsets.copy;
        var pitchSnap  = pitchSamples.copy;
        var dur;
        // The press, kept here: a new take can move recStartTime before the
        // deferred analysis below gets to write this one to the set's log.
        var pressAt = recStartTime;
        var levelsSnap = takeLevels;

        loopDur = SystemClock.seconds - recStartTime;
        dur     = loopDur;
        recSynth.free; recSynth = nil;

        // Start playback IMMEDIATELY at the raw recorded length — do NOT wait for
        // the meter fit (MeterAnalyzer.analyze is tens to ~200 ms for dense
        // loops). The loop lives on the server, so it sounds the instant
        // spawnEngine's message lands; the analysis then runs DEFERRED and, once
        // done, snaps the loop LENGTH to whole bars and kicks off the Live/tempo
        // sync. The language blocking during that deferred analysis never
        // interrupts the already-playing audio. (frame 0 = record press, so any
        // leading silence / pickup is kept.)
        startFrame = 0;
        loopFrames = (dur * sr).asInteger;
        this.spawnEngine(0);
        this.prSetState(\playing);
        "Playing (analyzing…).".postln;

        // A clean tap pointed at the wrong channel is silent, so the recording
        // sounds perfect while the analysis sees NOTHING and every loop quietly
        // drops to the length-anchored fallback meter. That is the one confusing
        // failure mode this feature adds, so name it out loud.
        if(onsetsSnap.isEmpty and: { this.analysisIn != inChannel }) {
            ("Looper: 0 onsets, and analysis is on the clean tap (SC channel "
                ++ this.analysisIn ++ " = ch " ++ (this.analysisIn + 1)
                ++ "). If the loop itself recorded fine, that channel is silent — "
                ++ "check it is the instrument's input on this device, or set "
                ++ "\"Analysis in\" back to \"Same as input\".").warn;
        };

        {
            var eng = engineSynth;   // the synth we just spawned
            // Onsets measured RELATIVE to the first, so the pulse grid is phase-
            // aligned regardless of how much silence precedes the first note.
            var relOnsets = onsetsSnap.collect { |p| p[0] - firstOnset };
            var strengths = onsetsSnap.collect { |p| p[1] };
            // leadIn: the first take's bars count from the press, which turns
            // on the uneven-bars detection (MeterAnalyzer.analyzeUneven).
            var result = MeterAnalyzer.analyze(
                dur - firstOnset, relOnsets.asArray, strengths.asArray, leadIn: firstOnset,
                pitches: pitchSnap.asArray);
            var newFrames, applied;
            result = MeterDecision.snapAnalysisToLoop(result, dur);
            result[\snapRefused] !? { |x|
                ("Looper: " ++ x[\numerator] ++ "/" ++ x[\denominator] ++ " x" ++ x[\k]
                    ++ " would move the loop " ++ x[\moveMs] ++ " ms — kept its length, "
                    ++ (if(result[\error] == \noFit) { "with no meter" } {
                        "as " ++ MeterDecision.readingString(result)
                            ++ (if(result[\error].notNil) { " (length-anchored)" } { "" }) })
                    ++ ".").postln;
            };
            newFrames = (result.loopDur * sr).asInteger;
            // Chord/pitch segmentation over the full loop (cheap, ~0.1 ms).
            if(result.tau.notNil) {
                var beatDur = result.tau * (result.sub ? 1);
                result[\chordSegments] = PitchAnalyzer.analyzeSegments(
                    pitchSnap.asArray, beatDur, result.loopDur, chordMinPerWindow);
            } {
                result[\chordSegments] = [];
            };
            // The length the segments cover: a multiplied loop repeats them.
            result[\chordPeriod] = result.loopDur;
            this.prSetResult(result);
            // What the analyser heard, and the reading in force is its own.
            analysedResult = result;
            readingIndex = 0;
            // Apply only if the loop we spawned is still the live engine (guards
            // against a clear / stop / multiply / swap during the analysis gap).
            applied = engineSynth.notNil and: { engineSynth === eng };
            if(applied) {
                loopFrames = newFrames;
                engineSynth.set(\loopFrames, loopFrames);
                // Grains switched on during the analysis took the raw length
                // and a pulse of a quarter of it.
                this.prGranularFollow;
                // Built against the ENGINE's period rather than result.loopDur:
                // they differ by the frame rounding above, and over a long take
                // that difference is what would walk the pattern off the audio.
                this.prBuildOnsetPattern(onsetsSnap, newFrames / sr);
                onAnalysis.value(result);
                this.startTempoClocks(result);
            };
            this.prCheckTap(levelsSnap);
            // The take, to the set's log: what was heard, what was decided.
            this.prLogTake(result, dur, firstOnset, onsetsSnap, applied, pressAt, levelsSnap, pitchSnap);
        }.defer;
    }

    // A clean tap that heard the guitar far below the recorded input starved
    // the analyser, whatever the onset count says. Said out loud, in the post
    // window and as \tapStarved (the gap in dB, or nil for a tap that heard
    // the take), which the window shows until the next take: the reading it
    // produced looks like any other. `levels` is [tap peak, input peak].
    prCheckTap { |levels|
        var gap = if(this.analysisIn != inChannel) { Looper.tapStarvedDb(levels) };
        gap !? {
            ("Looper: the analysis tap heard this take " ++ gap.round(1)
                ++ " dB below the recorded input (tap peak "
                ++ Looper.prDb(levels[0]).round(1) ++ " dBFS, input "
                ++ Looper.prDb(levels[1]).round(1) ++ " dBFS). The analyser "
                "was starved and fitted the meter to whatever crossed the "
                "threshold; check the tap's gain or channel (Analysis in = SC "
                "channel " ++ this.analysisIn ++ ") before lowering the threshold.").warn;
        };
        this.prSetTapStarved(gap);
    }

    prSetTapStarved { |gap|
        if(gap != tapStarvedGap) {
            tapStarvedGap = gap;
            this.changed(\tapStarved, gap);
        };
    }

    startOverdub {
        this.prRefusal(\overdub) !? { |why| ^this.prRefused(\trigger, why) };
        if(engineSynth.notNil) {
            this.snapshotForUndo;
            engineSynth.set(\recEnable, 1);
            if(analyzeOverdubs) { this.startOverdubAnalysis };
            this.prSetState(\overdubbing);
            this.prLogEvent(\overdubStart, ());
            "Overdubbing.".postln;
        };
    }

    endOverdub {
        if(engineSynth.notNil) {
            engineSynth.set(\recEnable, 0);
            this.prSetState(\playing);
            this.prLogEvent(\overdubEnd, ());
            "Playing.".postln;
            if(analyzeOverdubs) {
                this.stopOverdubAnalysis;
                // Gated: only a loop that has no meter yet. Otherwise every
                // overdub would re-tempo Live mid-performance.
                this.detectMeterFromOverdub(false);
            };
        };
    }

    startPlay {
        if(loopFrames > 0) {
            this.prLogEvent(\play, ());
            this.spawnEngine(0);
            if(lastResult.notNil and: { lastResult.error.isNil }) {
                this.startTempoClocks(lastResult);
            };
            this.prSetState(\playing);
            "Playing.".postln;
        };
    }

    spawnEngine { |recEnable=0|
        var defName = if(inChannelCount == 1) { \looperEngineMono } { \looperEngine };
        // A new engine plays at speed 1, in the direction now: a reverse
        // armed for the old one is dropped.
        this.prResetHalfTime;
        this.prResetReverse;
        engineSynth = Synth(defName, [
            \bufnum, buffer.bufnum,
            \in, inChannel,
            \out, outBus.index,
            \startFrame, startFrame,
            \loopFrames, loopFrames,
            \rate, 1,
            \dir, if(reverseFlag) { -1 } { 1 },
            \recEnable, recEnable,
            \latencyFrames, this.latencyFrames,
            \feedback, feedback,
            \declickFrames, this.declickFrames,
            // If BBCut is already running when we respawn the engine (e.g.
            // after a multiply / undo while in playback), restore its mix mode
            // so we don't lose the duck/mute against the cut output.
            // Not a bare 1: a respawn mid-dissolve (a multiply or undo, say)
            // must come back at the level the arc is currently at.
            \amp, this.prLoopMix,
            \gateBus, insertBus.index,
            \phaseBus, phaseBus.index,
            \gateMode, if(this.bbcut) { this.bbcutGateCode } { 0 }
        ], server);
        // Wall time of the moment the loop's audio actually starts. `Synth.new`
        // sends its s_new IMMEDIATELY and applies no latency of its own, so that
        // moment is SystemClock.seconds and nothing else.
        //
        // This used to add `server.latency`, on the assumption the synth was
        // scheduled that far ahead. It is not — so the reference sat ~185 ms
        // LATER than the audio it claimed to describe (measured on the rig with
        // scripts/check-loop-phase.scd, median 183.5 ms against an s.latency of
        // 0.2). Everything phase-aligned to it inherited that: the onset notes,
        // BBCut's clock, the MIDI-clock Start, and the loop boundary the chain
        // recorder waits for — each quietly absorbing the same 185 ms into its
        // own calibration, which is why every per-rig trim had drifted to ~-130.
        //
        // Corrected 2026-09-07. Every timing value in setup-routing.scd moved by
        // roughly +185 ms as a result; see the note there.
        this.timeline.restart(SystemClock.seconds);
        // A granular layer toggled on over the stopped loop had no engine to
        // follow and scans freely; now there is one, and the new engine sits
        // ahead of it in the node order. See \looperGranular. And it reads
        // what this engine reads (Record next loop swapped the buffers).
        this.grainsPart.lock;
        this.prGranularFollow;
        // Every path that starts audio comes through here, so this is where the
        // onset-note pattern re-aligns — to the audio's own start, not to
        // whenever the caller got around to it.
        this.startOnsetNotes;
    }

    latencyFrames { ^(latencyMs * server.sampleRate / 1000).asInteger }

    latencyMs_ { |val|
        latencyMs = val.max(0);
        engineSynth !? { |s| s.set(\latencyFrames, this.latencyFrames) };
        this.changed(\latencyMs, latencyMs);
    }

    // Live-sync fine-tune (ms, may be negative — negative pulls Live earlier).
    // Live's transport folds the CHANGE into its running clock stream as a
    // phase nudge, so Live's clock-follower slews to the new offset live, and
    // aims the next Start by it (LiveMidiTransport.syncMs_).
    abletonSyncMs_ { |val|
        abletonSyncMs = val;
        this.transport.syncMs = val;
        this.changed(\abletonSyncMs, abletonSyncMs);
    }

    declickFrames { ^(declickMs * server.sampleRate / 1000).asInteger }

    declickMs_ { |val|
        declickMs = val.max(0);
        engineSynth !? { |s| s.set(\declickFrames, this.declickFrames) };
        // Autostart's lead clears the fade (autostartLeadMs).
        autostartSynth !? { |s| s.set(\lead, this.autostartLeadMs / 1000) };
        this.changed(\declickMs, declickMs);
    }

    inChannelCount_ { |n|
        if(#[1, 2].includes(n)) {
            inChannelCount = n;
            ("Input channels: " ++ n).postln;
            this.changed(\inChannelCount, n);
        } {
            ("Invalid inChannelCount: " ++ n ++ ". Use 1 or 2.").warn;
        };
    }

    feedback_ { |val|
        feedback = val.clip(0, 1);
        engineSynth !? { |s| s.set(\feedback, feedback) };
        this.changed(\feedback, feedback);
    }

    returnChannel_ { |val|
        returnChannel = val;
        // nil is legal (see canChainLoops) but cannot go into an OSC message, and
        // a nil return channel means there is no chain synth running to update.
        returnChannel !? { this.chainPart.returnChannel_(returnChannel) };
        this.changed(\returnChannel, val);
    }

    // The channel the analysis chain actually reads. A nil analysisChannel means
    // no clean tap is wired, and falling back to the recorded input keeps the
    // feature a no-op instead of feeding Onsets.kr a silent bus (which would look
    // like a musical problem: every loop dropping to the fallback meter).
    analysisIn { ^analysisChannel ? inChannel }

    // Point the analysis at the dry guitar input; nil (or inChannel itself) turns
    // the tap off. Pushed to a running recorder so it can be switched mid-take.
    analysisChannel_ { |val|
        analysisChannel = val;
        recSynth !? { |s| s.set(\ana, this.analysisIn) };
        monitorSynth !? { |s| s.set(\ana, this.analysisIn) };
        autostartSynth !? { |s| s.set(\ana, this.analysisIn) };
        this.prTapLevelFollow;
        this.changed(\analysisChannel, analysisChannel);
    }

    // ===================================================================
    // The automatic level in front of the onset detector
    // ===================================================================
    // See LooperSynthDefs.tapLevelGraph. The gain in dB, for a window or the log.
    tapGainDb { ^tapGain.max(1e-6).ampdb }

    // The bus an analysis synth reads its gain from, or -1 (unity) before
    // the Looper is ready.
    prTapGainIndex { ^tapGainBus !? { |b| b.index } ? -1 }

    // Point the tracker at the input the analysis reads, and forget the peak
    // it held for another one. Called where an analysis synth starts, as
    // well as by analysisChannel_: inChannel is a plain variable, so a rig
    // that moves it after boot is caught at the next take or monitor start.
    prTapLevelFollow {
        var ana = this.analysisIn;
        if(tapLevelSynth.notNil and: { ana != tapLevelAna }) {
            tapLevelSynth.set(\ana, ana, \t_reset, 1);
            tapLevelAna = ana;
        };
    }

    // ===================================================================
    // Onset detection threshold + the free-running analysis monitor
    // ===================================================================
    // Live on BOTH the running recorder and the monitor, so you can tune against
    // what you are playing and the lamp agrees with the next take. Clipped to a
    // sane span: 0 detects everything including silence, and past ~2 nothing
    // survives. Takes effect immediately — Onsets reads it per block.
    onsetThreshold_ { |val|
        var old = onsetThreshold;
        onsetThreshold = val.clip(0.01, 2.0);
        if(onsetThreshold != old) {
            this.prLogEvent(\threshold, (value: onsetThreshold));
        };
        recSynth     !? { |s| s.set(\onsetThreshold, onsetThreshold) };
        monitorSynth !? { |s| s.set(\onsetThreshold, onsetThreshold) };
        autostartSynth !? { |s| s.set(\onsetThreshold, onsetThreshold) };
        this.changed(\onsetThreshold, onsetThreshold);
    }

    analysisMonitorOn { ^monitorSynth.notNil }

    // Yield the CALLING ROUTINE until the async construction has finished. Only
    // valid inside a Routine (boot.scd runs in one, via s.waitForBoot); from the
    // top level it throws, which is the honest answer — there is nothing to wait
    // on there. Poll rather than a Condition so a Looper that is already ready
    // costs one test and no scheduling.
    waitForReady {
        while { ready.not } { 0.05.wait };
        ^this
    }

    // ===================================================================
    // Overdub meter detection
    // ===================================================================
    analyzeOverdubs_ { |flag|
        analyzeOverdubs = flag;
        if(flag.not) { this.stopOverdubAnalysis };
        this.changed(\analyzeOverdubs, analyzeOverdubs);
    }

    overdubOnsetCount { ^overdubOnsets.size }

    // A length-anchored fallback counts as NO meter — it is the "we found no
    // beat" result, which is exactly the atmospheric take this feature is for.
    prHasValidMeter { ^lastResult.notNil and: { lastResult[\error].isNil } }

    startOverdubAnalysis {
        if(overdubSynth.notNil) { ^this };
        overdubOnsets.clear;
        overdubResp = OSCdef(\looperOverdubOnset, { |msg|
            if(state == \overdubbing) { overdubOnsets.add([msg[3], msg[4]]) };
        }, '/looperOverdubOnset');
        this.prTapLevelFollow;
        overdubSynth = Synth.tail(server, \looperOverdubAnalysis, [
            \ana, this.analysisIn,
            \onsetThreshold, onsetThreshold,
            \phaseBus, phaseBus.index,
            \tapGainBus, this.prTapGainIndex
        ]);
    }

    stopOverdubAnalysis {
        overdubSynth !? { |s| s.free };
        overdubSynth = nil;
        overdubResp !? { |r| r.free };
        overdubResp = nil;
    }

    // Fold every collected onset into ONE loop pass and merge near-duplicates.
    // Playing the pattern several times lands the same hits on the same phases,
    // so this is what makes repetition STRENGTHEN the grid instead of flooding
    // the analyzer with points.
    prFoldOverdubOnsets { |loopSecs|
        var merged = List.new;
        var window = 0.03;   // two hits closer than 30 ms are one event
        var offset, sorted;
        // A WET analysis input hears a note one Live round trip after it was
        // played, while the loop position was sampled at the moment of hearing —
        // so the event belongs that much earlier in the loop. With the dry tap
        // there is no such lag and the latched position is already right.
        offset = if(this.analysisIn == inChannel) { latencyMs / 1000 } { 0 };
        sorted = overdubOnsets.asArray
            .collect { |p| [(p[0] - offset).mod(loopSecs), p[1]] }
            .sort { |a, b| a[0] < b[0] };
        sorted.do { |p|
            if(merged.notEmpty and: { (p[0] - merged.last[0]) < window }) {
                // Keep the loudest reading — the accent test needs salience.
                merged.last[1] = max(merged.last[1], p[1]);
            } {
                merged.add([p[0], p[1]]);
            };
        };
        ^merged.asArray
    }

    // Derive the meter from the overdub's onsets against the EXISTING loop
    // length. force = true is the "Detect now" button: it bypasses the
    // already-has-a-meter gate but not the quality guards. A press that finds
    // nothing is refused out loud (the footer), since Perform has no line of
    // its own to say so; the run at an overdub's end stays quiet.
    detectMeterFromOverdub { |force = false|
        var loopSecs = loopFrames / server.sampleRate;
        var folded, times, strengths, first, result, n;

        if(loopFrames <= 0) {
            "Overdub detect: no loop recorded.".warn;
            if(force) { this.prRefused(\detectMeterFromOverdub, "no loop recorded") };
            ^this
        };
        if(force.not and: { this.prHasValidMeter }) {
            "Overdub detect: loop already has a meter — skipping.".postln;
            this.prLogEvent(\overdubDetect, (outcome: \skipped, force: force));
            ^this
        };
        folded = this.prFoldOverdubOnsets(loopSecs);
        if(folded.size < overdubMinOnsets) {
            ("Overdub detect: " ++ folded.size ++ " onsets, need "
                ++ overdubMinOnsets ++ " — no beat found.").postln;
            this.prLogEvent(\overdubDetect,
                (outcome: \tooFew, force: force, onsetCount: folded.size));
            if(force) {
                this.prRefused(\detectMeterFromOverdub, "no beat in the last overdub: "
                    ++ folded.size ++ " onsets, " ++ overdubMinOnsets ++ " needed"
                    // Onsets are only gathered while the switch is on.
                    ++ (if(analyzeOverdubs) { "" } { " · Overdub meter is off" }))
            };
            ^this
        };
        // Anchor the grid at the first onset; accentAlign then recovers where the
        // downbeat sits inside it.
        first     = folded[0][0];
        times     = folded.collect { |p| p[0] - first };
        strengths = folded.collect { |p| p[1] };
        result = MeterAnalyzer.analyze(loopSecs, times, strengths,
            overdubMaxBars, overdubMinDensity);
        if(result[\error].notNil) {
            ("Overdub detect: no grid fits these " ++ folded.size
                ++ " onsets (" ++ result[\error] ++ ").").postln;
            this.prLogEvent(\overdubDetect, (outcome: \noFit, force: force,
                onsetCount: folded.size, error: result[\error]));
            if(force) {
                this.prRefused(\detectMeterFromOverdub,
                    "no meter fits the last overdub's " ++ folded.size ++ " onsets")
            };
            ^this
        };

        // Force the grid to divide the EXISTING loop EXACTLY. The fitted tau is
        // only within loopTolerance, and a tempo a hair off the loop length
        // drifts against Live over a few minutes. The loop cannot be resized
        // here — there is already audio in it.
        n = MeterAnalyzer.unitsOf(result) * result[\sub];
        result[\n]       = n;
        result[\tau]     = loopSecs / n;
        result[\bpm]     = 240 * MeterAnalyzer.unitsOf(result)
            / (result[\denominator] * loopSecs);
        result[\loopDur] = loopSecs;
        // Absolute position of the downbeat within the loop, for the transport.
        result[\downbeatPhase] =
            (first + (result[\downbeatOffset] ? 0)).mod(loopSecs);
        result[\fromOverdub] = true;

        this.prSetResult(result);
        analysedResult = result;
        readingIndex = 0;
        this.prCancelReading;
        // `folded` is already [[loopPhase, strength], ...] merged onto one pass,
        // which is exactly the pattern format — so a loop whose first take had no
        // attacks at all still gets onset notes, from the overdub that gave it
        // its meter.
        this.prBuildOnsetPattern(folded, loopSecs);
        this.prGranularFollow;
        onAnalysis.value(result);
        this.changed(\overdubDetected, result);
        this.prLogEvent(\overdubDetect, (outcome: \applied, force: force,
            loopDur: loopSecs, threshold: onsetThreshold, onsets: folded,
            result: Looper.resultForLog(result),
            candidates: (result[\candidates] ? []).collect { |c| Looper.resultForLog(c) }));
        this.prStartTransportAtPhase(result);
    }

    // Live's 1.1.1 has to land on the detected downbeat, so hold the transport
    // start until the loop next reaches that phase. Starting the moment analysis
    // finishes would drop Live's bar 1 wherever the player happened to stop.
    prStartTransportAtPhase { |result|
        var loopSecs = loopFrames / server.sampleRate;
        var target = result[\downbeatPhase] ? 0;
        var now = SystemClock.seconds;
        var wait = (target - this.timeline.positionAt(now, loopSecs)).mod(loopSecs);
        ("Overdub detect: " ++ result[\numerator] ++ "/" ++ result[\denominator]
            ++ " @ " ++ result[\bpm].round(0.1) ++ " BPM over " ++ result[\k]
            ++ " bars from " ++ result[\onsetCount] ++ " onsets — the transport starts in "
            ++ wait.round(0.01) ++ " s.").postln;
        this.timeline.armAt(\overdubTransport, now + wait, { this.startTempoClocks(result) });
    }

    // Start the tuning lamp's feed. Independent of transport: it runs whether
    // or not a loop exists, which is the point — you set the threshold before
    // committing a take. Idempotent.
    startAnalysisMonitor {
        if(monitorSynth.notNil) { ^this };
        // The analysis window opens the monitor as it is built, and at boot that
        // happens in the same pass that CONSTRUCTS the Looper — whose SynthDefs
        // are still in flight (see `ready`). The s_new then failed silently: the
        // button read "Monitoring" and the lamp stayed dark until you toggled
        // it by hand, which is what finally created the node. So record the
        // intent and start for real once the defs are live; a stop before then
        // clears monitorWanted and this never fires.
        monitorWanted = true;
        if(ready.not) {
            Routine {
                this.waitForReady;
                if(monitorWanted) { this.startAnalysisMonitor };
            }.play;
            ^this;
        };
        // Two feeds, one callback. onMonitor's (level, onset, strength)
        // signature is unchanged — the level feed reports no onset, the onset
        // feed carries the level sampled at the hit — so the GUI does not have
        // to know that the rate split happened at all.
        monitorResp = OSCdef(\looperMonitor, { |msg|
            this.prMonitorLevel(msg[3]);
        }, '/looperMonitor');
        monitorOnsetResp = OSCdef(\looperMonitorOnset, { |msg|
            // [strength, level] — reversed relative to onMonitor's arguments
            // because the strength is what this message exists to carry. It
            // arrives onsetReportDelay after the hit (the strength's window).
            this.prMonitorOnset(msg[3], msg[4], SystemClock.seconds - LooperSynthDefs.onsetReportDelay);
        }, '/looperMonitorOnset');
        this.prTapLevelFollow;
        monitorSynth = Synth.tail(server, \looperAnalysisMonitor, [
            \ana, this.analysisIn,
            \onsetThreshold, onsetThreshold,
            \tapGainBus, this.prTapGainIndex
        ]);
        this.changed(\analysisMonitor, true);
    }

    // ---- The room ----------------------------------------------------------
    // What the analysis monitor hears, held for the model (roadmap item 12):
    // the record pre-roll wants the last hit before a press (item 4), a
    // count-in or a break's resume the other player's hit (items 10, 2), an
    // ending paced by the room its density (1), the grains the room against
    // the players (18), a sequencer stepped by the players their hits (20).
    // None of them is built yet; they read it here, not from the lamp's
    // callback, which the Analysis pane owns.

    *liveOnsetMax { ^64 }

    // A hit the monitor heard at `time`, strength and level as its reply
    // carries them. A wet analysis input (the processed one) hears a note one
    // round trip late, as prFoldOverdubOnsets says: that is taken off.
    prMonitorOnset { |strength, level, time|
        var t = time - if(this.analysisIn == inChannel) { (latencyMs ? 0) / 1000 } { 0 };
        liveOnsetTimes ?? {
            liveOnsetTimes = Array.fill(this.class.liveOnsetMax, 0.0);
            liveOnsetStrengths = Array.fill(this.class.liveOnsetMax, 0.0);
        };
        liveOnsetTimes[liveOnsetHead] = t.asFloat;
        liveOnsetStrengths[liveOnsetHead] = (strength ? 0).asFloat;
        liveOnsetHead = (liveOnsetHead + 1) % this.class.liveOnsetMax;
        liveOnsetCount = (liveOnsetCount + 1).min(this.class.liveOnsetMax);
        liveLevel = level;
        this.changed(\liveOnset, t, strength);
        onMonitor.value(level, true, strength);
    }

    prMonitorLevel { |level|
        liveLevel = level;
        onMonitor.value(level, false, 0);
    }

    // The hits the monitor heard, oldest first, as [time, strength]: those
    // of the last `seconds` before `now` (all it holds for nil). A new Array
    // each call: for a reader, not for every block.
    liveOnsets { |seconds, now|
        var out = Array.new(liveOnsetCount), from, i, t;
        now = now ?? { SystemClock.seconds };
        from = if(seconds.isNil) { -inf } { now - seconds };
        liveOnsetCount.do { |k|
            i = (liveOnsetHead - liveOnsetCount + k) % this.class.liveOnsetMax;
            t = liveOnsetTimes[i];
            if((t >= from) and: { t <= (now + 1e-6) }) { out = out.add([t, liveOnsetStrengths[i]]) };
        };
        ^out
    }

    // The last hit at or before `before` (now by default), [time, strength],
    // or nil: what a record pre-roll snaps back to.
    lastLiveOnset { |before| ^this.liveOnsets(nil, before).last }

    // Hits a second over the last `seconds` (4 by default) before `now`.
    liveOnsetRate { |seconds = 4, now| ^this.liveOnsets(seconds, now).size / seconds.max(1e-6) }

    stopAnalysisMonitor {
        monitorWanted = false;
        monitorSynth !? { |s| s.free };
        monitorSynth = nil;
        monitorResp !? { |r| r.free };
        monitorResp = nil;
        monitorOnsetResp !? { |r| r.free };
        monitorOnsetResp = nil;
        this.changed(\analysisMonitor, false);
    }

    // ===================================================================
    // Loop chaining — record a new loop over the current one and swap in
    // ===================================================================
    // Single toggle, driven from one button:
    //   * idle      -> arm a capture that starts at the next loop boundary
    //   * recording -> request stop; the capture ends at the next boundary
    //   * armed     -> (recording not started yet) cancel the arm
    // The captured loop is forced to an integer number of current-loop reps,
    // so tempo and signature carry over unchanged. On handoff the new engine is
    // spawned phase-aligned to the boundary and the old engine is freed; the
    // MIDI clock / click / bar routines are left running, so Live's external
    // sync never sees an interruption.
    recordNextLoop {
        if(state != \playing) {
            "Next loop: needs a plain playing loop (end overdub / start play first).".warn;
            ^this.prRefused(\recordNextLoop, switch(state,
                \overdubbing, { "Rec next loop: end the overdub first" },
                \recording, { "Rec next loop: close the take first" },
                { "Rec next loop needs a loop playing" }))
        };
        switch(this.nextRecState,
            \recording, { this.chainPart.requestStop },
            \armed, { this.cancelNextLoopRecord },
            \stopping, { /* already closing out — ignore */ },
            {
                if(this.prAtHalfTime) { ^this.prRefused(\recordNextLoop, "half-time: end it first") };
                this.armNextLoopRecord
            }   // \idle / default
        );
    }

    // Live's master, coming back on a spare input pair, for the session
    // recorder. Pushed to nothing: a running recording keeps the channel it
    // started on, because swapping the input under an open file would splice
    // two different sources into one take with no mark where it happened.
    sessionChannel_ { |val|
        sessionChannel = val;
        this.changed(\sessionChannel, sessionChannel);
    }

    // Built on first use rather than in init, so it does not depend on
    // construction order — and so a Looper assembled field by field (the
    // headless fixture does exactly that) still has one. No directory yet; the
    // scripts set it (see ~sessionDir in boot.scd).
    sessionRec {
        ^sessionRec ?? { sessionRec = LooperSessionRecorder(server, nil) }
    }

    sessionDir     { ^this.sessionRec.dir }
    sessionDir_    { |path| this.sessionRec.dir = path }
    sessionRecording { ^this.sessionRec.recording }
    sessionElapsed   { ^this.sessionRec.elapsed }

    // Record the whole set to disk. Deliberately independent of the transport,
    // of the analysis and of Live: it starts on the stomp and it stops on the
    // stomp, and nothing else in this class can interrupt it. That is the whole
    // point — see the header of LooperSessionRecorder for why the set cannot be
    // captured in Live's arrangement from the first note.
    //
    // It does NOT arm Live's arrangement record. That is its own footswitch
    // (Program Change 21, ~liveRecordToggle in setup-model.scd), because the
    // two recorders cannot start at the same moment and a single switch would
    // have had to lie about one of them.
    startSessionRecording {
        var started = this.sessionRec.start(sessionChannel, this.analysisIn,
            this.prSessionContext);
        if(started) { this.changed(\sessionRecording, true) };
        ^started
    }

    stopSessionRecording {
        var stopped = this.sessionRec.stop;
        if(stopped) { this.changed(\sessionRecording, false) };
        ^stopped
    }

    toggleSessionRecording {
        ^if(this.sessionRecording) {
            this.stopSessionRecording
        } {
            this.startSessionRecording
        }
    }

    // Whether this rig can record what the ROOM heard, as opposed to only the
    // dry tap. nil sessionChannel is the profile saying "no pair carries Live's
    // master back to me" — the recording still happens, it is just the guitar
    // alone, and the GUI says so rather than implying a full mix.
    canRecordMaster { ^sessionChannel.notNil }

    // ---- the set's own record ----------------------------------------------
    // While a set is being recorded, everything the analyser decides and
    // everything the player does about it goes to the session's event log, the
    // third file beside the two WAVs (see LooperSessionRecorder). That is what
    // makes the dry tap a labelled corpus: a take the next-reading switch moved
    // is a take the analyser got wrong, and the reading it settled on is the
    // label. Every hook is a no-op when no set is being recorded.
    prLogEvent { |ev, fields, at|
        sessionRec !? { |r| r.logEvent(ev, fields, at) };
    }

    // A SystemClock moment on the log's axis, or nil when nothing is logging
    // or there is no such moment (a loop that has not started playing).
    prLogTime { |seconds|
        if(seconds.isNil) { ^nil };
        ^sessionRec !? { |r| if(r.logging) { r.logTime(seconds) } { nil } }
    }

    // What the log's header says about the instrument as the set began: the
    // threshold, the channels the analysis reads, the fallback meter (and
    // whether there is one), and the loop already in force if the recorder
    // was started mid-piece.
    prSessionContext {
        var ctx = (
            threshold: onsetThreshold,
            ana: this.analysisIn,
            in: inChannel,
            fallback: MeterAnalyzer.fallbackNum.asString ++ "/" ++ MeterAnalyzer.fallbackDenom,
            fallbackBars: MeterAnalyzer.fallbackBars,
            fallbackOn: MeterAnalyzer.fallbackOn,
            state: state
        );
        if(loopFrames > 0 and: { lastResult.notNil }) {
            ctx[\loop] = Looper.resultForLog(lastResult);
            ctx[\loopDur] = this.loopDuration;
            // The take the loop came from, as a take event would have carried
            // it: a set started over a playing loop — which is how the first
            // four logged sets were started — still yields the analyser's input,
            // and the readings pressed during the set still count as labels.
            ctx[\take] = this.prTakeInForce;
        };
        sessionExtras !? { |f|
            (try { f.value } { nil }) !? { |more|
                if(more.isKindOf(Dictionary)) {
                    more.keysValuesDo { |k, v| if(ctx.includesKey(k).not) { ctx.put(k, v) } };
                };
            };
        };
        ^ctx
    }

    // A take's pitch readings for the log, [time, Hz, amp] at 25 Hz while
    // there is a pitch: the uneven bars' notes, for the replay (about 5 KB a
    // take).
    *prPitchesForLog { |ps|
        ^(ps ? []).asArray.collect { |p| [p[0].round(0.001), p[1].round(0.1), p[2].round(0.0001)] }
    }

    // What the analyser was given for the loop in force, and what it answered:
    // the raw take length, the onsets from the press, the reading and its list,
    // and which reading is in force now. The audio is not in the tap, so the
    // replay can only re-run the analyser on these onsets, not re-detect them.
    prTakeInForce {
        var analysed = analysedResult ? lastResult;
        var pairs = onsets.asArray;
        ^(
            dur: loopDur,
            firstOnset: if(pairs.isEmpty) { 0 } { pairs[0][0] },
            onsets: pairs,
            pitches: Looper.prPitchesForLog(pitchSamples),
            threshold: onsetThreshold,
            result: Looper.resultForLog(analysed),
            candidates: (analysed[\candidates] ? []).collect { |c| Looper.resultForLog(c) },
            reading: readingIndex,
            loopDur: this.loopDuration,
            fromOverdub: analysed[\fromOverdub] == true
        )
    }

    // The analysis tap against the recorded input over a take, both as peak
    // amplitudes [tap, input]: the gap in dB when the tap sat `gapDb` or more
    // below an input that was actually there (above `floorDb`), else nil. Pure,
    // so the rule is testable; the recorder feeds it from /looperLevels and the
    // replay applies the same rule to the dB figures in the log.
    *tapStarvedDb { |levels, gapDb = 30, floorDb = -40|
        if(levels.isNil or: { levels.size < 2 }) { ^nil };
        ^this.tapStarvedFromDb(this.prDb(levels[0]), this.prDb(levels[1]), gapDb, floorDb)
    }

    *tapStarvedFromDb { |tapDb, inDb, gapDb = 30, floorDb = -40|
        if(tapDb.isNil or: { inDb.isNil }) { ^nil };
        if(inDb < floorDb) { ^nil };
        if((inDb - tapDb) < gapDb) { ^nil };
        ^(inDb - tapDb)
    }

    *prDb { |amp|
        ^if(amp.isNil or: { amp <= 0 }) { -120.0 } { amp.ampdb.max(-120.0) }
    }

    // The take as one event, stamped at the stop press: the record press and
    // the raw length, which place it in the tap; the onsets the detector
    // reported and the threshold they came through; the reading the analyser
    // gave and its ranked list; and where the loop's playback began, for an
    // overdub's phase later. `applied` is false when the loop was cleared or
    // replaced during the analysis gap — the analysis still happened.
    prLogTake { |result, dur, firstOnset, onsetPairs, applied, pressAt, levels, pitches|
        var fields;
        if(sessionRec.isNil or: { sessionRec.logging.not }) { ^this };
        fields = (
            start: sessionRec.logTime(pressAt),
            dur: dur,
            threshold: onsetThreshold,
            firstOnset: firstOnset,
            onsets: onsetPairs.asArray,
            pitches: Looper.prPitchesForLog(pitches),
            result: Looper.resultForLog(result),
            candidates: (result[\candidates] ? []).collect { |c| Looper.resultForLog(c) },
            loopDur: result[\loopDur],
            play: this.prLogTime(this.loopStartTime),
            applied: applied
        );
        // The tap against the input, so the replay can tell a starved take
        // from a threshold that was merely wrong.
        if(levels.notNil and: { levels.size >= 2 }) {
            fields[\tapPeakDb] = Looper.prDb(levels[0]).round(0.1);
            fields[\inPeakDb]  = Looper.prDb(levels[1]).round(0.1);
        };
        // The automatic level the take's onsets were heard at (its last
        // report), so the replay can render them at the same level.
        if(levels.notNil and: { levels.size >= 3 } and: { levels[2].notNil }) {
            fields[\tapGainDb] = levels[2].max(1e-6).ampdb.round(0.1);
        };
        this.prLogEvent(\take, fields, pressAt + dur);
    }

    // The keys of an analysis worth keeping on disk: the meter, the pulse, the
    // score, the downbeat. Not the chord segments and not the nested list —
    // the take event carries the candidates once, flat.
    *resultForLog { |r|
        var out = ();
        if(r.isNil) { ^nil };
        #[\numerator, \denominator, \k, \n, \sub, \tau, \bpm, \loopDur, \score,
            \error, \onsetCount, \phase, \downbeatOffset, \downbeatPhase, \accent,
            \fromOverdub, \reading, \snapRefused, \bars, \from, \gridFit, \wholeLoop].do { |key|
            r[key] !? { |v| out[key] = v };
        };
        ^out
    }

    // Whether this rig can chain loops at all. Chaining records what Live sends
    // back on returnChannel, so a rig with no return path (no Live, no loopback)
    // cannot do it. nil is the profile saying so, rather than a
    // channel number that would quietly record silence — or, worse, a private
    // bus carrying the looper's own output straight back in.
    canChainLoops { ^returnChannel.notNil }

    // The capture (LooperChainRecorder), made when first asked for: a Looper
    // made without init (the tests' newCopyArgs) has one too.
    chainPart { ^chainPart ?? { chainPart = LooperChainRecorder(this) } }

    // The facade: the window, MIDI, the AI and the tests ask the Looper.
    nextRecState { ^this.chainPart.nextRecState }
    chainRecOffsetMs { ^this.chainPart.chainRecOffsetMs }
    chainRecOffsetMs_ { |val| this.chainPart.chainRecOffsetMs_(val) }
    cancelNextLoopRecord { this.chainPart.cancel }
    finishNextLoopRecord { |off = 0| this.chainPart.finish(off) }
    prChainRecOffset { |loopSecs| ^this.chainPart.recOffset(loopSecs) }
    prChainStartWait { |loopSecs, phaseInLoop, off| ^this.chainPart.startWait(loopSecs, phaseInLoop, off) }
    prFreeNextRecTail { this.chainPart.freeTail }

    // Armed for the next boundary, given a loop and a return to chain from.
    armNextLoopRecord {
        if(this.canChainLoops.not) {
            "Next loop: this rig has no return channel, so loop chaining is off."
                .warn;
            ^this.prRefused(\recordNextLoop, "this rig has no return channel to chain from")
        };
        if(loopFrames == 0) { "Next loop: no loop playing.".warn; ^this.prRefused(\recordNextLoop, "no loop playing") };
        this.chainPart.arm;
    }

    // The capture lands on a boundary: `next` (the capture, `n` passes of the
    // loop long) becomes the loop, and the old loop's buffer is answered, the
    // scratch for the next capture. Undo can take the swap back.
    prSwapInNextLoop { |next, n|
        var oldEngine = engineSynth, old = buffer;
        // Snapshot the OLD loop first so Undo can revert the swap.
        this.snapshotForUndo;
        // A reading armed for the old loop has nothing to land on (multiply's).
        this.prCancelReading;
        buffer = next;
        startFrame = 0;
        loopFrames = n * loopFrames;
        // The capture is n whole reps of the old loop, so the meter and tempo
        // still hold — but the analysis has to grow with it or BBCut will cut
        // the longer file at the old beat count and pitch it up n times.
        this.prScaleResultLength(n);
        // The new loop plays forwards: said, or the window and the drums would
        // go on showing and following a reversed loop.
        if(reverseFlag) { reverseFlag = false; this.prReverseSaid };
        // Spawn the new engine FIRST (phase-aligned to this boundary via
        // spawnEngine's loopStartTime), then free the old one — no silent gap.
        // Tempo/MIDI clocks are intentionally left running: same tempo, so Live
        // stays in sync with no Start/Stop sent.
        this.spawnEngine(0);
        oldEngine !? { |s| s.free };
        this.prSetState(\playing);
        this.prLogEvent(\chain, (reps: n, loopDur: this.loopDuration));
        ^old
    }

    // ===================================================================
    // BBCut multi-voice cutter
    // ===================================================================
    // When enabled, takes a snapshot of the current loop region, writes it to
    // a shared BBCutBuffer, and layers one or more "voices" over it. Each voice
    // is its own CutGroup (cut synth -> effects -> mixer) driven by its own
    // cut procedure on its own ExternalClock running at baseBps * ratio. Voices
    // are phase-aligned to the same loop downbeat at spawn, so non-unity ratios
    // produce true polyrhythm (e.g. ratio 1.5 = 3 cuts against the base 2).
    // The straight-through engine output is muted while cutting; its Phasor
    // keeps running so toggling off is instantaneous and still in phase.
    // Subsequent overdubs/multiply/undo do NOT refresh the snapshot — toggle
    // off and on again to pick up new audio.

    // Export the current loop as labelled training data for the meter
    // analysis: a 24-bit WAV and a JSON sidecar with the labels (`name`, the
    // meter `num`/`denom`, `bars`: the ground truth), the onsets MeterAnalyzer
    // saw and its answer (LooperTrainingExport, the Looper's own until
    // 2026-11-08). Says \trainingExport (the files' shared name) once both are
    // written. Answers that name, or nil with no loop.

    // ---- The cutter is LooperCutter ------------------------------------------
    // The part, made when first asked for: a Looper made without init (the
    // tests' newCopyArgs) has one too.
    cutterPart { ^cutterPart ?? { cutterPart = LooperCutter(this) } }

    // The engine's side of a cut, for the part: duck or mute the dry loop
    // (0 pass, 1 mute, 2 insert), the loop to disk for BBCutBuffer, the busses.
    prEngineGate { |code| engineSynth !? { |s| s.set(\gateMode, code) } }
    prWriteLoop { |path| buffer.write(path, "WAV", "int24", loopFrames, startFrame) }
    prOutBusIndex { ^outBus.index }
    prInsertBusIndex { ^insertBus.index }

    // The facade: the window, MIDI, the AI, the presets and the tests ask the
    // Looper, which asks its part.
    bbcut { ^this.cutterPart.bbcut }
    bbcutMode { ^this.cutterPart.bbcutMode }
    bbcutVoices { ^this.cutterPart.bbcutVoices }
    bbcutProcSpecs { ^this.cutterPart.bbcutProcSpecs }
    bbcutProcOrder { ^this.cutterPart.bbcutProcOrder }
    bbcutFxSpecs { ^this.cutterPart.bbcutFxSpecs }
    bbcutFxOrder { ^this.cutterPart.bbcutFxOrder }
    bbcutEnabling { ^this.cutterPart.bbcutEnabling }
    initBBCut { this.cutterPart.initBBCut }
    bbcutSynthKeys { ^this.cutterPart.bbcutSynthKeys }
    defaultBBCutProc { ^this.cutterPart.defaultBBCutProc }
    defaultParamsFor { |procSym| ^this.cutterPart.defaultParamsFor(procSym) }
    defaultBBCutVoice { ^this.cutterPart.defaultBBCutVoice }
    bbcut_ { |flag| this.cutterPart.bbcut_(flag) }
    bbcutGateCode { ^this.cutterPart.bbcutGateCode }
    bbcutInsertMode { ^this.cutterPart.bbcutInsertMode }
    bbcutMode_ { |mode| this.cutterPart.bbcutMode_(mode) }
    enableBBCut { ^this.cutterPart.enableBBCut }
    bbcutSpawnParams { |cutSpeed| ^this.cutterPart.bbcutSpawnParams(cutSpeed) }
    bbcutActiveVoiceCount { ^this.cutterPart.bbcutActiveVoiceCount }
    spawnBBCutVoice { |voice, sp| this.cutterPart.spawnBBCutVoice(voice, sp) }
    freeBBCutVoiceInst { |voice| this.cutterPart.freeBBCutVoiceInst(voice) }
    freeBBCutVoice { |voice| this.cutterPart.freeBBCutVoice(voice) }
    bbcutBuildSynth { |sym, buf| ^this.cutterPart.bbcutBuildSynth(sym, buf) }
    disableBBCut { this.cutterPart.disableBBCut }
    teardownBBCut { this.cutterPart.teardownBBCut }
    prCancelBBCutEnable { this.cutterPart.prCancelBBCutEnable }
    respawnBBCutVoice { |i| this.cutterPart.respawnBBCutVoice(i) }
    bbcutVoiceCount { ^this.cutterPart.bbcutVoiceCount }
    addBBCutVoice { ^this.cutterPart.addBBCutVoice }
    removeBBCutVoice { |i| ^this.cutterPart.removeBBCutVoice(i) }
    prRemoveBBCutVoiceAt { |i| ^this.cutterPart.prRemoveBBCutVoiceAt(i) }
    setVoiceProc { |i, sym| this.cutterPart.setVoiceProc(i, sym) }
    setVoiceSynth { |i, sym| this.cutterPart.setVoiceSynth(i, sym) }
    setVoiceFx { |i, symArray| this.cutterPart.setVoiceFx(i, symArray) }
    setVoiceRatio { |i, ratio| this.cutterPart.setVoiceRatio(i, ratio) }
    setVoiceAmp { |i, amp| this.cutterPart.setVoiceAmp(i, amp) }
    setVoicePan { |i, pan| this.cutterPart.setVoicePan(i, pan) }
    setVoiceParam { |i, key, val| this.cutterPart.setVoiceParam(i, key, val) }
    bbcutPresetVersion { ^this.cutterPart.bbcutPresetVersion }
    bbcutPresetData { |name| ^this.cutterPart.bbcutPresetData(name) }
    bbcutVoiceData { |voice| ^this.cutterPart.bbcutVoiceData(voice) }
    bbcutPresetText { |data| ^this.cutterPart.bbcutPresetText(data) }
    prValidateBBCutPreset { |data, warnings| ^this.cutterPart.prValidateBBCutPreset(data, warnings) }
    prValidateBBCutVoiceData { |vd, warnings, idx| ^this.cutterPart.prValidateBBCutVoiceData(vd, warnings, idx) }
    applyBBCutPreset { |data| ^this.cutterPart.applyBBCutPreset(data) }
    prWriteBBCutVoice { |voice, vd| this.cutterPart.prWriteBBCutVoice(voice, vd) }
    prVoiceDensity { |voice, key| ^this.cutterPart.prVoiceDensity(voice, key) }
    voiceDensity { |i| ^this.cutterPart.voiceDensity(i) }
    prBBCutPresetSummary { |data| ^this.cutterPart.prBBCutPresetSummary(data) }

    exportTrainingLoop { |dir, name, num, denom, bars|
        if(loopFrames == 0 or: { buffer.isNil }) { "Export: no loop to export.".warn; ^nil };
        ^LooperTrainingExport.export(this.prExportTake, dir, name, num, denom, bars,
            { |base| this.changed(\trainingExport, base) })
    }

    // What the take is, for a part that writes it out (LooperTrainingExport):
    // the loop's frames in its buffer, the onsets as heard ([time, strength]
    // from the take's start), the reading, the take's own length.
    prExportTake {
        ^(buffer: buffer, loopFrames: loopFrames, startFrame: startFrame, sampleRate: server.sampleRate,
            onsets: onsets.copy, lastResult: lastResult, loopDur: loopDur, server: server)
    }

    // ---- Preset files ---------------------------------------------------
    // `dir` is passed in rather than derived, for the same reason
    // exportTrainingLoop takes one: this class is compiled through a symlink in
    // Extensions, so its own file path cannot be walked back to the repo.

    // A preset's file name, by the rule every family shares (MegaFiles.presetSlug).
    bbcutPresetSlug { |name| ^MegaFiles.presetSlug(name) }

    // ---- Shared preset storage ------------------------------------------
    //
    // The two families differ in what a preset CONTAINS, not in how it is
    // stored: one JSON file per preset (MegaFiles.writeEvent, whole or not at
    // all; MegaFiles.readEvent, nothing run). Storage is therefore written
    // once below, and this table is the whole difference between them:
    // `format` names the file's kind, `order` its fields' order, `what` the
    // kind in a refusal, `version` the newest this build reads (a method).
    //
    // `summary` names the method that describes a saved preset in one line for
    // the post window — the only other thing the two sides did differently.
    *prPresetFamilies {
        ^(
            bbcut: (
                label:   "BBCut",
                format:  LooperCutter.presetFormat,
                what:    "megalooper BBCut preset",
                order:   #[\version, \name, \savedAt, \mode, \voices],
                version: \bbcutPresetVersion,
                data:    \bbcutPresetData,
                apply:   \applyBBCutPreset,
                summary: \prBBCutPresetSummary
            ),
            granular: (
                label:   "Granular",
                format:  LooperGrains.presetFormat,
                what:    "megalooper granular preset",
                order:   #[\version, \name, \savedAt, \env, \followChords]
                    ++ LooperGrains.presetFields.collect { |f| f[0] },
                version: \granularPresetVersion,
                data:    \granularPresetData,
                apply:   \applyGranularPreset,
                summary: \prGranularPresetSummary
            )
        )
    }

    // The presets a folder holds, and a preset's file: MegaFiles' rules.
    presetNames { |dir| ^MegaFiles.presetNames(dir) }
    presetPath { |dir, name| ^MegaFiles.presetPath(dir, name) }

    prSavePreset { |family, dir, name|
        var f = Looper.prPresetFamilies[family];
        var slug, path, data, why;
        if(dir.isNil) { (f[\label] ++ " preset: no directory given.").warn; ^nil };
        slug = MegaFiles.presetSlug(name);
        path = this.presetPath(dir, slug);
        data = this.perform(f[\data], name);
        why = MegaFiles.writeEvent(path, data, f[\format], f[\order]);
        if(why.notNil) {
            (f[\label] ++ " preset: could not write " ++ path ++ " (" ++ why ++ ")").warn;
            ^nil
        };
        (f[\label] ++ " preset saved: " ++ slug ++ " ("
            ++ this.perform(f[\summary], data) ++ ").").postln;
        ^slug
    }

    prLoadPreset { |family, dir, name|
        var f = Looper.prPresetFamilies[family];
        var path = this.presetPath(dir, name);
        var data;
        if(File.exists(path).not) {
            (f[\label] ++ " preset: no such preset " ++ path.basename).warn;
            ^false
        };
        data = MegaFiles.readEvent(path, f[\format], this.perform(f[\version]), f[\what], { |why|
            (f[\label] ++ " preset: " ++ path.basename ++ ": " ++ why).warn;
        });
        if(data.isNil) { ^false };
        ^this.perform(f[\apply], data)
    }

    prDeletePreset { |family, dir, name|
        var path = this.presetPath(dir, name);
        if(File.exists(path).not) { ^false };
        File.delete(path);
        ^true
    }

    // A family's old presets in `dir` (SC literals, <slug>.scd) carried over
    // to JSON, once (MegaFiles.migrateFolder: each read the old way one last
    // time and written beside it; the .scd files stay where they are, for an
    // older megalooper, and a marker says the folder is done). Class-side: a
    // boot does it before there is a Looper. Answers the slugs carried over.
    *migratePresets { |family, dir|
        var f = this.prPresetFamilies[family];
        ^MegaFiles.migrateFolder(dir, { |old, json|
            MegaFiles.migrateFile(old, json, f[\format], f[\order], { |why|
                (f[\label] ++ " preset " ++ old.basename ++ " was not carried over to JSON (" ++ why
                    ++ "); it stays as it was, and is not read.").warn })
        })
    }

    // ---- Per-family entry points ----------------------------------------
    //
    // Kept as named methods rather than asking every caller to pass a family
    // symbol: the GUI, the MIDI bindings and check.scd all address these by
    // name, and `saveGranularPreset(dir, name)` reads better at a call site
    // than `savePreset(\granular, dir, name)`. One line each, no logic.

    bbcutPresetPath  { |dir, name| ^this.presetPath(dir, name) }
    bbcutPresetNames { |dir| ^this.presetNames(dir) }
    saveBBCutPreset   { |dir, name| ^this.prSavePreset(\bbcut, dir, name) }
    loadBBCutPreset   { |dir, name| ^this.prLoadPreset(\bbcut, dir, name) }
    deleteBBCutPreset { |dir, name| ^this.prDeletePreset(\bbcut, dir, name) }

    granularPresetSlug  { |name| ^MegaFiles.presetSlug(name) }
    granularPresetPath  { |dir, name| ^this.presetPath(dir, name) }
    granularPresetNames { |dir| ^this.presetNames(dir) }

    saveGranularPreset   { |dir, name| ^this.prSavePreset(\granular, dir, name) }
    loadGranularPreset   { |dir, name| ^this.prLoadPreset(\granular, dir, name) }
    deleteGranularPreset { |dir, name| ^this.prDeletePreset(\granular, dir, name) }

    // ---- Kept for the next start ----------------------------------------
    //
    // The Cutter's and the Grains' Start with this (since 2026-11-12): what a
    // preset of theirs holds (the cutter's voices and Mix/Insert/Gate; every
    // control of the grains), in a file of its own outside the presets'
    // folder, so it is never in the menu. A boot reads it back once the
    // Looper is ready. The switches are not in it: both start off, as ever.
    // `path` is passed in, as `dir` is above.
    keepCutter     { |path| ^this.prKeep(\bbcut, path) }
    loadKeptCutter { |path| ^this.prLoadKept(\bbcut, path) }
    keepGrains     { |path| ^this.prKeep(\granular, path) }
    loadKeptGrains { |path| ^this.prLoadKept(\granular, path) }

    // nil when written, else why not.
    prKeep { |family, path|
        var f = Looper.prPresetFamilies[family];
        if(path.isNil) { ^"no file given" };
        ^MegaFiles.writeEvent(path, this.perform(f[\data], "kept"), f[\format], f[\order])
    }

    // false, and nothing said, when nothing was kept; true once it is in;
    // false, said, when the file is not read (the part then starts as
    // megalooper ships it). A file with a value out of range is read, the
    // value corrected, as a preset's is.
    prLoadKept { |family, path|
        var f = Looper.prPresetFamilies[family], data;
        if(path.isNil or: { File.exists(path).not }) { ^false };
        data = MegaFiles.readEvent(path, f[\format], this.perform(f[\version]), f[\what], { |why|
            ("megalooper: what Start with this kept (" ++ path ++ ") is not read: " ++ why ++ ". "
                ++ if(family == \bbcut) { "The cutter starts as megalooper ships it." }
                    { "The grains start as megalooper ships them." }).warn;
        });
        if(data.isNil) { ^false };
        ^this.perform(f[\apply], data)
    }

    stopPlayback {
        if(#[\playing, \overdubbing, \recording].includes(state)) {
            this.prLogEvent(\stop, ());
        };
        // Before anything else: a break still counting down would otherwise
        // leave the master gate at 0 for the next loop. clear routes through
        // here too, so this one call covers both.
        this.prCancelBreak;
        this.prCancelDissolve;
        this.prCancelReading;
        this.cancelNextLoopRecord;
        this.prResetHalfTime;
        this.prResetReverse;
        // A detection may have a transport start queued for the next downbeat;
        // stopping the loop cancels it rather than firing into a stopped looper.
        this.timeline.cancel(\overdubTransport);
        this.stopOverdubAnalysis;
        this.prCancelBBCutEnable;
        if(this.bbcut) { this.disableBBCut };
        engineSynth !? { |s| s.free };
        engineSynth = nil;
        this.grainsPart.off;
        clickRoutine !? { |r| r.stop };
        clickRoutine = nil;
        chordRoutine !? { |r| r.stop };
        chordRoutine = nil;
        this.stopOnsetNotes;
        // The transport stops with the loop in \full only (in Live, MIDI Clock
        // and MIDI Stop travel together: the clock stops only with a Stop,
        // otherwise Live loses sync and turns off external sync).
        if(transportMode == \full) { this.transport.stop };
        if(state != \empty) { this.prSetState(\stopped) };
        "Stopped.".postln;
    }

    clear {
        this.prLogEvent(\clear, ());
        this.stopPlayback;
        buffer !? { |b| b.zero };
        startFrame = 0;
        loopFrames = 0;
        this.prSetResult(nil);
        analysedResult = nil;
        readingIndex = 0;
        undoState = nil;
        this.prClearOnsetPattern;
        this.prSetTapStarved(nil);
        this.prSetState(\empty);
        "Cleared.".postln;
    }

    // Stop a routine UNLESS we are running inside it.
    //
    // Routine:stop on the current thread is `nil.alwaysYield` — it does not
    // return. So a method that stops its own routine terminates on that line
    // and every line after it is dead code. That is not a subtle risk here: it
    // is exactly how a break came to mute the looper permanently. endBreak,
    // reached from inside breakRoutine after the wait, stopped that routine on
    // its first line and so never got to the line that reopens the gate.
    //
    // Returns nil so the caller can clear the slot in the same breath.
    prStopRoutine { |r|
        r !? { if(r !== thisThread) { r.stop } };
        ^nil
    }

    // ===================================================================
    // The arc — intensity and dissolve
    // ===================================================================
    // Pure functions of the two axes, so the shape of the ending is testable
    // without a server. Each returns a multiplier in 0..1.
    //
    // The thresholds are the composition: the cutter is gone by 0.4, the dry
    // loop by 0.6, the grains only at 1.0. That ordering is the whole point —
    // rhythm goes, then body, then the haze evaporates.
    //
    // The pedal reaches the cutter through its DENSITY (prVoiceDensity), not
    // its level. It used to do both, and on the rig that read as the layer
    // going away rather than as it chopping less — a cutter thinned to a few
    // repeats AND turned down is simply gone (2026-10-05). The dissolve still
    // takes the level out, because the ending is about leaving.
    prLoopMix     { ^(1 - (dissolvePos / 0.6)).clip(0, 1) }
    prBBCutMix    { ^(1 - (dissolvePos / 0.4)).clip(0, 1) }
    prGranularMix { ^intensity * (1 - ((dissolvePos - 0.5) / 0.5)).clip(0, 1) }

    // The single writer of the three running levels. Everything that changes a
    // stored level routes through here rather than setting a synth directly, so
    // there is exactly one place where "what was configured" is combined with
    // "where the arc is".
    prApplyMixes {
        engineSynth   !? { |s| s.set(\amp, this.prLoopMix) };
        this.grainsPart.applyMix;
        this.cutterPart.applyMix;
    }

    intensity_ { |val|
        intensity = val.clip(0, 1);
        this.prApplyMixes;
        this.changed(\intensity, intensity);
    }

    // How many loop passes the ending takes, 1..32. Passes, as a break
    // counts, not bars: the analyser merges bars (two of 6/8 are one of 12/8
    // to it), so "8 bars" could be sixteen of the player's; a pass is what
    // everyone hears (roadmap item 1, 2026-10-27).
    dissolveLoops_ { |n|
        dissolveLoops = n.asInteger.clip(1, 32);
        this.changed(\dissolveLoops, dissolveLoops);
    }

    // How long an ending of `loops` passes lasts, in seconds, at the speed
    // now: at half-time a pass lasts twice as long, so a dissolve can end a
    // piece there.
    dissolveDuration { |loops| ^this.wallPeriod * (loops ? dissolveLoops).asInteger.clip(1, 32) }

    // Run the ending. Armed once and then audible all the way down, which is
    // what lets the bass player hear it coming and play into it — the reason
    // nothing here is probabilistic.
    startDissolve { |loops|
        var n   = (loops ? dissolveLoops).asInteger.clip(1, 32);
        var dur = this.dissolveDuration(n);
        if((state != \playing) and: { state != \overdubbing }) {
            "Dissolve: nothing is playing.".warn;
            ^this.prRefused(\dissolve, "nothing playing")
        };
        if(dur <= 0) {
            "Dissolve: no loop length to measure it against.".warn;
            ^this.prRefused(\dissolve, "no loop length to measure it against")
        };
        dissolveRoutine = this.prStopRoutine(dissolveRoutine);
        dissolving = true;
        this.changed(\dissolving, true);
        ("Dissolving over " ++ n ++ " loop(s), " ++ dur.round(0.01) ++ " s.").postln;
        dissolveRoutine = Routine {
            var t0 = SystemClock.seconds;
            var hz = 30;
            while { dissolvePos < 1 } {
                dissolvePos = ((SystemClock.seconds - t0) / dur).clip(0, 1);
                this.prApplyMixes;
                this.changed(\dissolvePos, dissolvePos);
                hz.reciprocal.wait;
            };
            // The flag is deliberately NOT lowered here. `dissolving` means
            // "the ending is in effect", not "the ramp is still moving" — and
            // with dissolveStops off a ramp that has run out leaves every level
            // at zero with the loop still rolling. Lowering the flag there told
            // the header the ending was over while nothing was audible: a looper
            // reading PLAYING, no lamp lit, and the abort gesture — which keys
            // off this flag — starting a SECOND ending from silence instead of
            // restoring. Found by scripts/tests/test-gesture-fuzz.scd.
            //
            // stopPlayback routes through prCancelDissolve, which lowers the
            // flag and brings the axis home, so the stopping path still ends
            // with both clear. It also cancels the dissolve, which reaches for
            // this very routine; prStopRoutine is what makes that safe from in
            // here.
            if(dissolveStops) { this.stopPlayback };
        }.play(SystemClock);
        ^this
    }

    // Abort and restore. Also the reset path: a finished dissolve must not
    // leave the axis at 1, or the next loop would start already dissolved.
    prCancelDissolve {
        dissolveRoutine = this.prStopRoutine(dissolveRoutine);
        if(dissolving) {
            dissolving = false;
            this.changed(\dissolving, false);
        };
        if(dissolvePos != 0) {
            dissolvePos = 0;
            this.prApplyMixes;
            this.changed(\dissolvePos, 0);
        };
    }

    cancelDissolve { ^this.prCancelDissolve }

    // The Dissolve footswitch and the Dissolve button are ONE gesture — run the
    // ending, or take it back — and each used to spell out that condition for
    // itself, in scripts/setup-midi.scd and scripts/gui-shell.scd.
    //
    // The question it asks is about the ARC, not about the ramp: is anything
    // still taken away? `dissolving` answers that on its own now (see
    // startDissolve), and the axis is checked beside it so this stays right by
    // itself no matter what any future ramp leaves behind.
    toggleDissolve {
        if(dissolving or: { dissolvePos > 0 }) { ^this.prCancelDissolve };
        ^this.startDissolve
    }

    // ===================================================================
    // Breaks
    // ===================================================================
    breakLoops_ { |n|
        breakLoops = n.asInteger.clip(1, 8);
        this.changed(\breakLoops, breakLoops);
    }

    // Open the hole NOW — the mute is not quantised, so it lands exactly where
    // the foot did. Only the RESUME is on the grid.
    fireBreak { |loops|
        var n       = (loops ? breakLoops).asInteger.clip(1, 8);
        var loopDur = this.loopDuration;
        var seq;
        if((state != \playing) and: { state != \overdubbing }) {
            "Break: nothing is playing.".warn;
            ^this.prRefused(\break, "nothing playing")
        };
        if(loopDur <= 0) {
            "Break: no loop to break out of.".warn;
            ^this.prRefused(\break, "no loop to break out of")
        };
        // Re-firing mid-break restarts the count. Stacking a second resume
        // would let the first one unmute early, halfway through the new break.
        seq = this.timeline.claim(\break);
        this.prSetBreakGate(0);
        // The onset-note part is the looper's own voice, going out to Live as
        // MIDI. A break that left the drums playing would not be a break.
        this.stopOnsetNotes;
        onBreak = true;
        this.changed(\break, true);
        // Asking the engine where it is costs a /c_get round trip, so the
        // schedule is set up here rather than above. The gate is already shut by
        // this point; the few ms of latency only move the resume, and only by
        // less than a millisecond of loop position.
        this.queryLoopPhase { |phase|
            var dur = MeterDecision.breakDuration(phase, loopDur, n, reverseFlag, this.speed, this.prSpeedAfterNext);
            // A cancel or a re-fire in the meantime owns the gate now; this
            // callback belongs to a break that no longer exists.
            if(this.timeline.holds(\break, seq) and: { onBreak }) {
                breakEndsAt = SystemClock.seconds + dur;
                this.changed(\breakEndsAt, breakEndsAt);
                ("Break: " ++ dur.round(0.01) ++ " s, resuming on a loop downbeat.")
                    .postln;
                this.timeline.armAt(\break, breakEndsAt, { this.endBreak });
            };
        };
        ^this
    }

    endBreak {
        // The usual caller IS the break's arm: the timeline's cancel is safe
        // from inside it.
        this.timeline.cancel(\break);
        breakEndsAt = nil;
        // The gate sits after the master's limiter, whose look-ahead puts the
        // engine's downbeat at the gate 20 ms after the engine plays it: opened
        // now, it would let the last 20 ms of the pass before into the hole's
        // end. So it opens then, on a timestamped /n_set; the onset part and
        // the \break notification go now, as their own times are the engine's.
        this.prSetBreakGate(1, Looper.masterDelay);
        // Phase-aligns itself from loopStartTime, so it picks up mid-pass
        // exactly where the audio is; a no-op when onsetNotes is off.
        this.startOnsetNotes;
        if(onBreak) {
            onBreak = false;
            this.changed(\break, false);
        };
        ^this
    }

    // Reset the gate WITHOUT restarting the onset part, for paths that are
    // stopping the notes anyway. Load-bearing rather than tidy: a break left
    // armed across a stop would strand breakAmp at 0, and the NEXT loop would
    // play into a silent output with nothing on screen to explain it.
    prCancelBreak {
        // A new token, so a phase callback still in flight cannot arm a resume
        // for a break that has just been cancelled.
        this.timeline.cancel(\break);
        breakEndsAt = nil;
        this.prSetBreakGate(1);
        if(onBreak) {
            onBreak = false;
            this.changed(\break, false);
        };
    }

    // How long after the engine plays it the master's output carries it: its
    // Limiter's look-ahead, twice the Limiter's dur (10 ms). MegaSADrums'
    // loopAudioDelay is the same 20 ms, and test-megadrums-sched.scd reads the
    // Limiter to hold them together.
    *masterDelay { ^0.02 }

    // The break gate, \looperMaster's breakAmp. With no delay the write goes
    // out at once (the hole opens where the foot landed); with one, as a
    // bundle stamped that far on (endBreak's reopening). The server carries
    // out a bundle at its time, so a write sent while one is still due goes in
    // again just after it, in the same block, and the gate always ends as the
    // last write left it: a stomp in the 20 ms of a reopening keeps the gate
    // shut, a stop then opens it.
    prSetBreakGate { |value, delay = 0|
        var now = thisThread.seconds, at;
        masterSynth !? { |s|
            if(breakGateAt.notNil and: { breakGateAt < now }) { breakGateAt = nil };
            if(delay > 0) {
                at = now + delay;
                breakGateAt !? { |due| if(due >= at) { at = due + 1e-8 } };
                s.server.sendBundle(at - now, s.setMsg(\breakAmp, value));
                breakGateAt = at;
            } {
                s.set(\breakAmp, value);
                breakGateAt !? { |due|
                    s.server.sendBundle((due + 1e-8) - now, s.setMsg(\breakAmp, value));
                    breakGateAt = due + 1e-8;
                };
            };
        };
    }

    // ===================================================================
    // Reverse
    // ===================================================================
    // A press while a loop plays arms the other direction for the next
    // boundary, as half-time is armed: a pass starts on the loop's seam in
    // either direction, so landing there keeps every boundary where it was,
    // and the drums' bar line with them (flipped at once, the playhead turned
    // where it was, and the loop's start moved there for good). Armed, a
    // press takes it back, up to halfTimeMargin before it lands. The engine
    // is sent the direction now, or timed into the pass that ends on the
    // boundary, and takes it there to the sample (LooperSynthDefs.engineGraph). With no
    // loop playing it flips at once: the next take plays that way.
    reverse {
        var now = SystemClock.seconds, ld = this.loopDuration, at, after;
        if(reverseArmed) {
            if((reverseAt - now) < Looper.halfTimeMargin) { ^this.prRefused(\reverse, "the reverse lands now") };
            this.prSendDir(reverseFlag);
            ^this.prReverseArm(false)
        };
        if(engineSynth.isNil or: { ld <= 0 } or: { #[\playing, \overdubbing].includes(state).not }) {
            reverseFlag = reverseFlag.not;
            ^this.prReverseSaid
        };
        at = this.prNextBoundaryAt(now);
        // Too close, the boundary after: one pass at the speed after this
        // one (a half-time landing there makes it two loops long).
        if((at - now) < Looper.halfTimeMargin) {
            after = if(((halfTimeAt ? inf) - at).abs < 1e-6) { this.prSpeedAfterNext } { this.speed };
            at = at + (ld / after);
        };
        // The engine's reference wraps once a loop, whatever the speed: sent
        // after the last wrap before `at`, the direction is taken on `at`.
        this.prSendDir(reverseFlag.not, at - ld);
        this.prReverseArm(true, at);
    }

    // The engine's direction (reversed: true), sent no earlier than `after`
    // (a wall time; 10 ms on, so a wrap at `after` has passed) and after a
    // direction still on its way.
    prSendDir { |reversed, after|
        var now = thisThread.seconds, at = now, value = if(reversed) { -1 } { 1 };
        after !? { |a| at = at.max(a + 0.01) };
        reverseSentAt !? { |p| if(p > now) { at = at.max(p + 0.001) } };
        engineSynth !? { |e|
            if(at > now) { server.sendBundle(at - now, e.setMsg(\dir, value)) } { e.set(\dir, value) };
        };
        reverseSentAt = at;
    }

    // Armed for `at`, with a routine waiting for it, or not armed.
    prReverseArm { |flag, at|
        this.timeline.cancel(\reverse);
        reverseArmed = flag;
        reverseAt = if(flag) { at };
        if(flag) { this.timeline.armAt(\reverse, at, { |token| this.prReverseLands(token) }) };
        this.changed(\reverseArmed, reverseArmed);
    }

    // On the boundary, as the engine takes the direction.
    prReverseLands { |seq|
        if(this.timeline.holds(\reverse, seq).not or: { reverseArmed.not }) { ^this };
        reverseArmed = false;
        reverseAt = nil;
        reverseFlag = reverseFlag.not;
        this.changed(\reverseArmed, false);
        this.prReverseSaid;
    }

    // The direction now, to the grains and whoever listens.
    prReverseSaid {
        this.grainsPart.setRate(this.prGrainRate);
        ("Reverse: " ++ reverseFlag).postln;
        this.changed(\reverse, reverseFlag);
    }

    // No reverse armed: a new engine starts in the direction now, a stop
    // has none to land on.
    prResetReverse {
        var was = reverseArmed;
        this.timeline.cancel(\reverse);
        reverseSentAt = nil;
        reverseArmed = false;
        reverseAt = nil;
        if(was) { this.changed(\reverseArmed, false) };
    }

    // ===================================================================
    // Half-time
    // ===================================================================
    // A press: off, it is armed and lands on the next boundary; armed, the
    // arm is taken back; at half-time, it ends with the pass; ending, it
    // stays. The engine is sent the speed now, or timed into the pass that
    // ends on the boundary, and takes it there to the sample (LooperSynthDefs.engineGraph).
    // A message may come after a boundary closer than halfTimeMargin, so a
    // press then goes to the boundary after (and an arm or an end that close
    // can't be taken back).
    *halfTimeMargin { ^0.05 }

    toggleHalfTime {
        var now = SystemClock.seconds, ld = this.loopDuration, at, why;
        switch(halfTime,
            \off, {
                why = this.prHalfTimeRefusal;
                if(why.notNil) { ^this.prRefused(\halfTime, why) };
                at = this.prNextBoundaryAt(now);
                if((at - now) < this.prHalfTimeMargin) { at = at + ld };
                this.prSendSpeed(0.5, at - ld);
                this.prHalfTimeArm(\armed, at);
            },
            \armed, {
                if((halfTimeAt - now) < Looper.halfTimeMargin) { ^this.prRefused(\halfTime, "half-time lands now") };
                this.prSendSpeed(1);
                this.prHalfTimeArm(\off);
            },
            \on, {
                at = this.prNextBoundaryAt(now);
                if((at - now) < this.prHalfTimeMargin) { at = at + (2 * ld) };
                // In the pass's second half: its first half ends on a wrap of
                // the engine's reference, which would take it there.
                this.prSendSpeed(1, at - ld);
                this.prHalfTimeArm(\releasing, at);
            },
            \releasing, {
                if((halfTimeAt - now) < Looper.halfTimeMargin) { ^this.prRefused(\halfTime, "half-time ends now") };
                this.prSendSpeed(0.5);
                this.prHalfTimeArm(\on);
            }
        );
    }

    // Why half-time can't be armed now, or nil. A dissolve's bars were
    // measured at the speed it began at.
    prHalfTimeRefusal { ^this.prRefusal(\halfTime) }

    // Why an action can't be taken now, in words, or nil: one table that every
    // entry point with conditions asks (docs/dev/architecture.md, 5, step 5),
    // so two things that must not overlap refuse each other both ways. Rec
    // next loop already refused an overdub's playing ("end the overdub
    // first"); an overdub and a multiply now refuse a next loop's armed or
    // recording, where they used to break the swap: it set \playing over a
    // running overdub, and swapped in reps recorded at the old length.
    prRefusal { |action|
        ^switch(action,
            \overdub, {
                case
                { this.prAtHalfTime } { "half-time: end it before an overdub" }
                { this.nextRecState != \idle } { "Rec next loop is on: overdub once the next loop is in" }
                { nil }
            },
            \multiply, {
                case
                { this.prAtHalfTime } { "half-time: end it first" }
                { (state == \empty) or: { state == \recording } or: { loopFrames == 0 } } { "no loop to multiply" }
                { this.nextRecState != \idle } { "Rec next loop is on" }
                { nil }
            },
            \halfTime, {
                case
                { state == \overdubbing } { "end the overdub first" }
                { (state != \playing) or: { this.loopDuration <= 0 } } { "half-time needs a loop playing" }
                { this.nextRecState != \idle } { "Rec next loop is on" }
                { this.bbcutEnabling } { "the cutter is starting" }
                { dissolving or: { dissolvePos > 0 } } { "a dissolve is on" }
                { nil }
            },
            { nil })
    }

    // The engine's speed, signed, as the grains scan by it.
    prGrainRate { ^(if(reverseFlag) { -1 } { 1 }) * this.speed }

    // How close to a boundary a press may come and still land on it. With the
    // cutter on it is respawned for the new speed, which writes the loop out
    // and reads it back first (enableBBCut): half a second.
    prHalfTimeMargin { ^if(this.bbcut) { 0.6 } { Looper.halfTimeMargin } }

    // Half-time is armed, on or ending: what it refuses says so.
    prAtHalfTime { ^halfTime != \off }

    // The engine's speed, sent no earlier than `after` (a wall time; 10 ms on,
    // so a wrap at `after` has passed) and after a speed still on its way.
    prSendSpeed { |value, after|
        var now = thisThread.seconds, at = now;
        after !? { |a| at = at.max(a + 0.01) };
        halfTimeSentAt !? { |p| if(p > now) { at = at.max(p + 0.001) } };
        engineSynth !? { |e|
            if(at > now) { server.sendBundle(at - now, e.setMsg(\speed, value)) } { e.set(\speed, value) };
        };
        halfTimeSentAt = at;
    }

    // What a press leaves: the state, and the boundary it lands on (nil for
    // none), with a routine waiting for it.
    prHalfTimeArm { |next, at|
        this.timeline.cancel(\halfTime);
        halfTime = next;
        halfTimeAt = at;
        if(at.notNil) {
            this.timeline.armAt(\halfTime, at - 0.5, { |token|
                // The cutter comes in again at the new speed on the boundary
                // (enableBBCut waits for it), as for a reading that changes
                // its pulse.
                if(this.bbcut and: { this.bbcutEnabling.not }) { this.enableBBCut };
                if(at > SystemClock.seconds) { (at - SystemClock.seconds).wait };
                this.prHalfTimeLands(token);
            });
        };
        this.changed(\halfTime, halfTime);
    }

    // On the boundary, as the engine takes the speed: half-time on, or over.
    // What keeps time with the loop follows: the onset kit and the chords.
    prHalfTimeLands { |seq|
        var at = halfTimeAt, landing = halfTime == \armed;
        if(this.timeline.holds(\halfTime, seq).not or: { at.isNil }) { ^this };
        this.timeline.speedFrom(if(landing) { 0.5 } { 1 }, at, if(landing) { at });
        halfTime = if(landing) { \on } { \off };
        halfTimeAt = nil;
        this.prLogEvent(\halfTime, (speed: this.speed, at: this.prLogTime(at)));
        ("Half-time " ++ (if(landing) { "on" } { "off" }) ++ ".").postln;
        this.changed(\halfTime, halfTime);
        this.changed(\speed, this.speed);
        this.startOnsetNotes;
        chordRoutine !? { this.startChordRoutine(lastResult) };
        // The grains scan as the loop moves, their pulse the loop's.
        this.grainsPart.setRate(this.prGrainRate);
        lastResult !? { |r| r[\tau] !? { |t| this.grainsPart.setTau(t / this.speed) } };
    }

    // Back to 1 at once, for a new engine (it plays at 1) and a stop.
    prResetHalfTime {
        var was = (halfTime != \off) or: { this.speed != 1 };
        this.timeline.cancel(\halfTime);
        halfTimeSentAt = nil;
        if(was) {
            this.timeline.speedFrom(1, SystemClock.seconds, nil);
            halfTime = \off;
            halfTimeAt = nil;
            this.grainsPart.setRate(this.prGrainRate);
            this.changed(\halfTime, halfTime);
            this.changed(\speed, this.speed);
        };
    }

    // ===================================================================
    // Readings — the next one, on a boundary Live's bar line will meet
    // ===================================================================

    // How many readings this take has, the answer included. 0 with no analysis
    // or a fallback, which has nothing to offer.
    readingCount {
        ^((analysedResult !? { |a| a[\candidates] }) ? []).size
    }

    // The second reading, snapped to the loop, for the header's "or 7/4?".
    runnerUp { ^MeterDecision.readingFor(analysedResult, 1, this.loopDuration) }

    // The answer's score minus the runner-up's. Under a tenth of a point the
    // answer is right one time in three and the runner-up nearly as often
    // (docs/dev/meter-perception.md), which is when the header shows it.
    readingMargin {
        var c = analysedResult !? { |a| a[\candidates] };
        var next;
        if(c.isNil or: { c.size < 2 } or: { c[0][\score].isNumber.not }) { ^nil };
        // Uneven readings (detected, or given by hand) have no score to compare
        // with the meters': the margin is to the best meter after the answer.
        next = c.drop(1).detect { |x| x[\score].isNumber };
        ^next !? { |x| c[0][\score] - x[\score] }
    }

    // THE footswitch. Moves the take to the next reading in the analyser's own
    // ranking; pressed again while one is armed, it moves on to the reading
    // after that instead. Past the last it comes round to the analyser's
    // answer, so one switch is enough to get back. Nothing changes until a
    // loop boundary, and the header counts down to it — the bass player hears
    // it coming, like a break.
    nextReading {
        var n = this.readingCount;
        var from, target;
        if((state != \playing) and: { state != \overdubbing }) {
            "Next reading: nothing is playing.".warn;
            ^this.prRefused(\nextReading, "nothing playing")
        };
        if(n < 2) {
            (if(n == 0) { "Next reading: no grid fit this take — nothing to offer." }
                { "Next reading: only one reading fit this take." }).warn;
            ^this.prRefused(\nextReading, if(n == 0) { "no grid fit this take" } { "only one reading fit this take" })
        };
        from   = (pendingReading !? { |p| p[\index] }) ? readingIndex;
        target = (from + 1) % n;
        ^this.prArmReading(target)
    }

    // Back to what the analyser heard, on a boundary like any reading.
    revertReading {
        if(pendingReading.isNil and: { readingIndex == 0 }) { ^this };
        if((state != \playing) and: { state != \overdubbing }) { ^this.prCancelReading };
        ^this.prArmReading(0, \revert)
    }

    // Bars given by hand: `bars` one cycle of them in units of 1/denom, as
    // [7, 7, 7, 8] with 8. They become a reading of the loop as it is
    // (MeterAnalyzer.readingOfBars: the length decides the tempo, the reading
    // in force how many cycles), added to the take's readings after the
    // analyser's own and armed like the next one: it lands on a boundary,
    // the drums and the bar grid follow it, Revert goes back to the
    // analyser's answer, and the switch passes through it. Bars already on
    // the list (the detection's, or given before) arm that reading. For when
    // the detection did not find them.
    offerBars { |bars, denom = 8|
        var loopSecs = this.loopDuration;
        var analysed = analysedResult ? lastResult;
        var cycle, near, reading, cands, index;
        if((state != \playing) and: { state != \overdubbing }) {
            "Bars: nothing is playing.".warn;
            ^this.prRefused(\offerBars, "nothing playing")
        };
        cycle = (bars ? []).asArray.select { |b| b.isNumber }.collect { |b| b.asInteger };
        if(cycle.isEmpty or: { cycle.size > 16 } or: { cycle.any { |b| (b < 1) or: { b > 32 } } }
            or: { #[2, 4, 8, 16].includes(denom).not }) {
            ("Bars: " ++ bars.asCompileString ++ "/" ++ denom
                ++ " is not a bar list (1 to 16 bars of 1 to 32, over 2, 4, 8 or 16).").warn;
            ^this.prRefused(\offerBars, "not a bar list")
        };
        if(analysed.isNil or: { loopSecs <= 0 }) {
            "Bars: no take to give bars to.".warn;
            ^this.prRefused(\offerBars, "no take")
        };
        near = lastResult !? { |r| if(r[\error].isNil) { r[\bpm] } };
        reading = MeterAnalyzer.readingOfBars(loopSecs, cycle, denom, near,
            analysed[\onsetCount] ? 0);
        // Index 0 is always the analyser's answer: a take that fit no grid has
        // no list, so the list starts with the answer itself.
        cands = (analysed[\candidates] ?? { [analysed.copy] }).copy;
        // The same bars already on the list, detected or given before, are
        // armed as they are.
        index = cands.detectIndex { |c|
            MeterAnalyzer.isUneven(c) and: { c[\denominator] == denom }
                and: { MeterAnalyzer.cycleOf(MeterAnalyzer.barsOf(c)) == cycle } };
        if(index.isNil) {
            cands = cands.add(reading);
            index = cands.size - 1;
            // A copy, so the undo snapshot keeps the take's own list.
            analysedResult = analysed.copy.put(\candidates, cands);
        };
        ^this.prArmReading(index, \hand)
    }

    // Arm reading `index`: work out the boundary it lands on, publish it, and
    // schedule the landing.
    prArmReading { |index, via = \next|
        var loopSecs = this.loopDuration;
        var result   = MeterDecision.readingFor(analysedResult, index, loopSecs);
        var now      = SystemClock.seconds;
        var nextAt, period, ticksAtNext, ticksPerLoop, wait, restart, landAt, lead;
        if(result.isNil or: { loopSecs <= 0 }) { ^this };
        // Re-arming replaces: the reading after the pending one is what was
        // asked for, and two landings would fight over the clock.
        this.timeline.cancel(\reading);
        landingFrom = nil;
        // The next boundary, and the passes after it in wall time: at
        // half-time (armed, on or releasing) twice the loop's length.
        nextAt = this.prNextBoundaryAt(now);
        period = loopSecs / this.prSpeedAfterNext;
        // Where the transport's count will stand at that boundary, if a Start
        // has gone out on a known boundary; otherwise every boundary is as good.
        ticksAtNext  = this.transport.ticksAt(nextAt);
        ticksPerLoop = ticksAtNext !? { period * this.transport.clockTickRate };
        wait    = MeterDecision.readingWait(ticksAtNext, ticksPerLoop, MeterDecision.barTicksOf(result), 2);
        restart = wait.isNil;
        wait    = wait ? 1;
        landAt  = nextAt + ((wait - 1) * period);
        pendingReading = (index: index, result: result, at: landAt, loops: wait,
            restart: restart);
        this.changed(\reading, pendingReading);
        this.prLogEvent(\readingArmed, (index: index, of: this.readingCount, via: via,
            landsAt: this.prLogTime(landAt), loops: wait, restart: restart,
            reading: Looper.resultForLog(result)));
        ("Next reading: " ++ MeterDecision.readingString(result) ++ " in " ++ wait
            ++ " loop" ++ (if(wait > 1) { "s" } { "" })
            ++ (if(restart) { " — no boundary in reach carries the bar line, so Start goes out again" }
                { ", on the bar line" }) ++ ".").postln;
        // A cutter respawn writes the loop out and reads it back before it can
        // wait for the boundary itself (enableBBCut): half a second covers
        // that. Otherwise the landing is the boundary.
        lead = if(this.bbcut and: { MeterDecision.readingChangesCutter(lastResult, result) })
            { 0.5 } { 0.02 };
        this.timeline.armAt(\reading, landAt - lead, { |token| this.prLandReading(token) });
        ^this
    }

    // Inside the reading's arm, a little before the boundary. The new result goes
    // in first, so a cutter respawn — which waits for the boundary itself —
    // spawns on the new grid; then, ON the boundary, everything else that
    // follows the meter. pendingReading stays published until then, so the
    // header keeps counting down rather than announcing early.
    prLandReading { |seq|
        var p = pendingReading;
        var result, landAt, respawn;
        if(p.isNil) { ^this };
        result  = p[\result];
        landAt  = p[\at];
        respawn = this.bbcut and: { MeterDecision.readingChangesCutter(lastResult, result) };
        landingFrom = lastResult;
        this.prSetResult(result);
        if(respawn) { this.enableBBCut };
        // Conditional, so a landing whose boundary has passed — which is how
        // the headless tests drive this — runs straight through without a yield.
        if(landAt > SystemClock.seconds) { (landAt - SystemClock.seconds).wait };
        if(this.timeline.holds(\reading, seq).not) { ^this };   // cancelled or re-armed meanwhile
        readingIndex   = p[\index];
        pendingReading = nil;
        landingFrom    = nil;
        // The transport: a new period from this tick, its count's reference
        // moved to this boundary so the next reading finds its bar line again,
        // and when no boundary in reach could carry it, Start again — the
        // relocation the first take does — unless a session recording is
        // running and a Start relocates something (Live), when it would
        // overwrite the take (see startTempoClocks). SA's drums restart on the
        // loop regardless (LoopTransport.landTempo).
        if(this.transport.running and: { result[\bpm].notNil }) {
            this.transport.landTempo(result[\bpm], landAt, p[\restart], this.sessionRecording);
        };
        // The grains take the new pulse at once; the click restarts on it. The
        // onset notes are the hits that were played and never looked at the
        // meter; the dissolve counts passes, which no reading changes.
        this.prGranularFollow;
        if(clickRoutine.notNil and: { result[\tau].notNil }) {
            this.startClick(result[\tau], MeterDecision.clickBars(result));
        };
        // Live gets the tempo and the signature the way an analysis delivers
        // them, through the same callback.
        onAnalysis.value(result);
        // The arm is over (a test may have landed it by hand: its routine
        // goes too). Safe from inside it.
        this.timeline.cancel(\reading);
        this.changed(\reading, nil);
        this.changed(\readingIndex, readingIndex);
        this.prLogEvent(\readingLanded, (index: readingIndex, restart: p[\restart],
            reading: Looper.resultForLog(result)), landAt);
        ("Reading " ++ (readingIndex + 1) ++ "/" ++ this.readingCount ++ ": "
            ++ MeterDecision.readingString(result) ++ ".").postln;
        ^this
    }

    prCancelReading {
        // A new token, so a landing in flight belongs to a reading that no
        // longer is.
        this.timeline.cancel(\reading);
        landingFrom = nil;
        if(pendingReading.notNil) {
            this.prLogEvent(\readingCancelled, (index: pendingReading[\index]));
            pendingReading = nil;
            this.changed(\reading, nil);
        };
    }

    // ---- The grains (LooperGrains) -------------------------------------------
    // The part, made when first asked for: a Looper made without init (the
    // tests' newCopyArgs) has one too.
    grainsPart { ^grainsPart ?? { grainsPart = LooperGrains(this) } }

    // What the grains read, for the part: the buffer, where the loop is in it,
    // the bus they write, the engine they follow (nil over a stopped loop),
    // the bus its read position is on, the server.
    prGrainSource {
        ^(buffer: buffer, startFrame: startFrame, loopFrames: loopFrames, out: outBus !? { |b| b.index },
            phaseBus: phaseBus !? { |b| b.index }, engine: engineSynth, server: server)
    }

    // The facade: the window, MIDI, the AI, the presets and the tests ask the
    // Looper, which asks its part.
    granularMorph { ^this.grainsPart.granularMorph }
    granularAmp { ^this.grainsPart.granularAmp }
    granularPitch { ^this.grainsPart.granularPitch }
    granularDetune { ^this.grainsPart.granularDetune }
    granularSize { ^this.grainsPart.granularSize }
    granularDensity { ^this.grainsPart.granularDensity }
    granularSizeRand { ^this.grainsPart.granularSizeRand }
    granularPosition { ^this.grainsPart.granularPosition }
    granularScan { ^this.grainsPart.granularScan }
    granularSpray { ^this.grainsPart.granularSpray }
    granularEnv { ^this.grainsPart.granularEnv }
    granularFollowChords { ^this.grainsPart.granularFollowChords }
    granularMorph_ { |val| this.grainsPart.granularMorph_(val) }
    granularAmp_ { |val| this.grainsPart.granularAmp_(val) }
    granularPitch_ { |val| this.grainsPart.granularPitch_(val) }
    granularDetune_ { |val| this.grainsPart.granularDetune_(val) }
    granularSize_ { |val| this.grainsPart.granularSize_(val) }
    granularDensity_ { |val| this.grainsPart.granularDensity_(val) }
    granularSizeRand_ { |val| this.grainsPart.granularSizeRand_(val) }
    granularPosition_ { |val| this.grainsPart.granularPosition_(val) }
    granularScan_ { |val| this.grainsPart.granularScan_(val) }
    granularSpray_ { |val| this.grainsPart.granularSpray_(val) }
    granularEnv_ { |val| this.grainsPart.granularEnv_(val) }
    granularFollowChords_ { |flag| this.grainsPart.granularFollowChords_(flag) }
    granularOn { ^this.grainsPart.on }
    toggleGranular { ^this.grainsPart.toggle }
    granularPresetVersion { ^this.grainsPart.presetVersion }
    granularPresetData { |name| ^this.grainsPart.presetData(name) }
    granularPresetText { |data| ^this.grainsPart.presetText(data) }
    applyGranularPreset { |data| ^this.grainsPart.applyPreset(data) }
    prValidateGranularPreset { |data, warnings| ^this.grainsPart.validatePreset(data, warnings) }
    prGranularPresetSummary { |data| ^this.grainsPart.presetSummary(data) }
    // The Looper's own uses (the loop moved under the grains), and the tests'.
    prGranularFollow { this.grainsPart.follow }
    prGranularChordArgs { ^this.grainsPart.chordArgs }
    prGranularArgs { ^this.grainsPart.args }
    prGranularEnvBuf { ^this.grainsPart.envBuf }
    prSetGranular { |key, val, notification| this.grainsPart.prSetGranular(key, val, notification) }

    // The pulse the grains play at morph 1: the reading's, or a quarter of
    // the loop where there is none. At half-time a pulse lasts twice as long:
    // the pulsed grains too.
    prGranularTau {
        var tau = if(lastResult.notNil and: { lastResult.tau.notNil }) { lastResult.tau } {
            loopFrames / server.sampleRate / 4
        };
        ^tau / this.speed
    }

    // All settable parameters notify dependents via `this.changed(\key, val)`.
    // GUI and external surfaces subscribe with SimpleController(this).put(\key, fn)
    // and stay in sync regardless of where the change originated.

    outChannel_ { |val|
        outChannel = val;
        masterSynth !? { |s| s.set(\out, val) };
        this.changed(\outChannel, val);
    }

    // Live transport modes:
    //   \full       — send MIDI Start + Clock on play, MIDI Stop on looper stop
    //   \startOnly  — send MIDI Start + Clock on play, never send Stop; Clock
    //                 keeps running across looper stops so Live's EXT sync stays
    //                 alive (sending Stop without Clock-loss causes Live to
    //                 raise "MIDI sync signal has been lost" and disable EXT)
    //   \off        — send nothing; Live transport untouched
    //
    // Edge cases:
    //   1. MIDI Start always restarts Live from its cue point (typically 1.1.1).
    //      In \startOnly mode, recording a second loop while Live is still
    //      running will jump Live back to the top. To resume from the current
    //      playhead instead, swap `midiOut.start` for an AbletonOSC
    //      `/live/song/continue_playing` message.
    //   2. Switching transportMode mid-play is not handled gracefully. Going
    //      from \full or \startOnly to \off while a loop is playing leaves
    //      the transport's clock running until session shutdown — no
    //      `stopPlayback` in \full mode will ever come to clean it up. If this
    //      matters, gate cleanup inside `transportMode_`: on entering \off,
    //      stop the transport so Live disengages cleanly instead of panicking
    //      on lost clock.
    transportMode_ { |mode|
        if(#[\full, \startOnly, \off].includes(mode)) {
            transportMode = mode;
            ("Transport mode: " ++ mode).postln;
            this.changed(\transportMode, mode);
        } {
            ("Invalid transport mode: " ++ mode
                ++ ". Use \\full, \\startOnly, or \\off.").warn;
        };
    }

    multiply { |factor=2|
        var newFrames = loopFrames * factor;
        this.prRefusal(\multiply) !? { |why| ^this.prRefused(\multiply, why) };
        if((startFrame + newFrames) > buffer.numFrames) {
            ("Multiply would overflow buffer (need " ++ newFrames ++ " frames).").warn;
            ^this.prRefused(\multiply, "the loop would not fit the buffer")
        };
        this.snapshotForUndo;
        // A reading armed for the loop as it was would land at its length, on
        // its boundary, which is mid-pass in the longer one (the gesture fuzz
        // found it, 2026-11-08): taken back, as a new take and an undo take
        // theirs. Next reading arms one for the loop as it is now.
        this.prCancelReading;
        (1..(factor - 1)).do { |i|
            buffer.copyData(buffer,
                dstStartAt: startFrame + (loopFrames * i),
                srcStartAt: startFrame,
                numSamples: loopFrames);
        };
        loopFrames = newFrames;
        engineSynth !? { |s| s.set(\loopFrames, newFrames) };
        this.prScaleResultLength(factor);
        this.prGranularFollow;
        this.prLogEvent(\multiply, (factor: factor, loopDur: this.loopDuration));
        ("Multiplied to " ++ factor ++ "x.").postln;
    }

    // Re-scale the analysis after the loop got `factor` times longer without
    // being re-analyzed (multiply, next-loop capture). Same tempo and meter —
    // only the bar count, the pulse count and the length grow.
    //
    // This matters most to BBCut, which relies on the invariant
    //     loopDur == tau * (numerator * sub * k)
    // BBCutBuffer derives bps from the FILE it is handed (bps = beats/length),
    // and every cut synth plays at rate = clock.tempo / bps. Leave k describing
    // the old short loop while writing a file `factor` times longer and bps
    // comes out `factor` too low, so every cut plays `factor` times too fast —
    // a doubled loop cuts an octave up, a 4x next-loop two octaves up.
    //
    // Copies the Event first: snapshotForUndo stores lastResult BY REFERENCE,
    // so mutating in place would rewrite the undo state as well.
    prScaleResultLength { |factor|
        var f = factor.asInteger.max(1), r;
        if(lastResult.isNil or: { f == 1 }) { ^this };
        r = lastResult.copy;
        r[\k] = (r[\k] ? 1) * f;
        r[\n] = (r[\n] ? 1) * f;
        r[\bars] !? { |b| r[\bars] = (b ! f).flatten };
        // Take the length from the frames actually in play rather than
        // multiplying the old value, so it cannot drift from the audio.
        if(server.notNil and: { server.sampleRate.notNil } and: { loopFrames > 0 }) {
            r[\loopDur] = loopFrames / server.sampleRate;
        } {
            r[\loopDur] = (r[\loopDur] ? 0) * f;
        };
        this.prSetResult(r);
    }

    // What the take being played was heard to hold, for an AI app
    // (MegaRemote.takeOf): its onsets, [seconds from the record press,
    // strength], and its pitch readings, [seconds, Hz, amplitude], as the
    // analysis read them. A copy; empty before a first take, and from a new
    // record press on.
    takeOnsets { ^onsets.asArray.copy }
    takePitches { ^pitchSamples.asArray.copy }

    // Whether Undo has something to drop: the window says "nothing to undo"
    // rather than offering it.
    canUndo { ^undoState.notNil }

    // Whether the transport runs (Live's MIDI clock going out, SA's drums
    // started): the window holds back what would stall the language (its
    // theme's rebuild) while it does.
    midiClockRunning { ^this.transport.running }

    // ---- The transport (LoopTransport) ----------------------------------------
    // Live's, on midiOut, unless another was put here (SA's drums).
    transport {
        ^transport ?? { transport = LiveMidiTransport({ midiOut }).syncMs_(abletonSyncMs) }
    }
    // A new transport (SA's drums attaching; nil: Live's again, on midiOut).
    // The old one's clock stops, saying nothing.
    transport_ { |aTransport|
        transport !? { |t| if(t !== aTransport) { t.free(false) } };
        transport = aTransport;
    }
    // Whether a Start relocates something worth protecting (Live: the
    // arrangement jumps to 1.1.1), so mid-recording a later analysis or a
    // reading keeps its Start to itself. SA's drums answer false.
    startsRelocate { ^this.transport.startsRelocate }

    // An action this Looper would not take, said once to whoever listens: the
    // window puts "Refused: why" in its status line, whichever surface asked
    // (a key, a click or a footswitch). `what` is the action, `why` a few
    // words. Answers the Looper, so a refusal can return it.
    prRefused { |what, why|
        this.changed(\refused, what, why);
    }

    undo {
        if(this.prAtHalfTime) { ^this.prRefused(\undo, "half-time: end it first") };
        if(undoState.isNil) { ^this.prRefused(\undo, "nothing to undo") };
        // The state the snapshot was taken in says what is being undone: with
        // no loop playing it was a take, otherwise an overdub, multiply or
        // chain on a take that stands (see LooperSessionRecorder:takesFrom).
        this.prLogEvent(\undo, (state: undoState.state));
        undoBuffer.copyData(buffer);
        startFrame = undoState.startFrame;
        loopFrames = undoState.loopFrames;
        this.prSetResult(undoState.lastResult);
        analysedResult = undoState.analysedResult;
        readingIndex   = undoState.readingIndex ? 0;
        this.prCancelReading;
        this.onsetNotesPart.restoreTake(undoState);
        if(undoState.state == \empty) {
            this.stopPlayback;
            this.prSetState(\empty);
        } {
            engineSynth !? { |s|
                s.set(\startFrame, startFrame);
                s.set(\loopFrames, loopFrames);
                s.set(\recEnable, 0);
            };
            if(state == \overdubbing) { this.prSetState(\playing) };
            this.prGranularFollow;
            // Undo does not respawn the engine, so loopStartTime is untouched and
            // nothing else here would pick up the restored pattern.
            this.startOnsetNotes;
        };
        "Undo.".postln;
    }

    // `audio` false: a snapshot of no loop while a take is being written into
    // the buffer (Autostart's start), so the undo buffer is zeroed, which is
    // what a copy of no loop holds, rather than copied mid-take.
    snapshotForUndo { |audio = true|
        if(audio) { buffer.copyData(undoBuffer) } { undoBuffer.zero };
        undoState = (
            startFrame: startFrame,
            loopFrames: loopFrames,
            lastResult: lastResult,
            // The reading cycle belongs to the analysis being snapshotted: undo
            // must bring back the list the undone take can cycle through, and
            // which reading it was on.
            analysedResult: analysedResult,
            readingIndex: readingIndex,
            state: state
        // The onset notes' pattern and dice belong to the buffer contents
        // snapshotted here; without them, undo restores the audio and leaves
        // the previous take's rhythm playing over it (LooperOnsetNotes.takeState).
        ).putAll(this.onsetNotesPart.takeState);
    }

    startTempoClocks { |result|
        if(metronome and: { result.tau.notNil }) {
            this.startClick(result.tau, MeterDecision.clickBars(result));
        };
        if(this.transport.connected and: { result.bpm.notNil }) {
            var barDur = MeterDecision.cycleDur(result);
            // Live's Start is aligned to the LOOP, not to any bar. A loop is k
            // bars long, so only every k-th bar boundary is the true start of
            // the take — aligning to barDur drops Live's 1.1.1 into the middle
            // of it. Prefer the engine's own period (both callers set
            // loopFrames before getting here) so the grid is exactly what the
            // audio does rather than the pre-rounding estimate.
            var loopSecs = if(loopFrames > 0 and: { server.sampleRate.notNil }) {
                loopFrames / server.sampleRate
            } {
                result[\loopDur] ? barDur
            };
            // MIDI Start relocates Live to its cue point. That is correct for
            // the FIRST take — it is what puts Live's 1.1.1 on the music — and
            // destructive for every one after it while Live is recording the
            // arrangement: the playhead jumps to the top and the take is
            // overwritten from there. So once a session recording is running
            // and the clock is already going, a later analysis keeps its tempo
            // to itself. The loop plays, the meter is detected, the readouts
            // update; only the transport is left alone.
            //
            // Gated on the clock ALREADY RUNNING, not on the recording alone,
            // so arming the recorder before the first take cannot stop Live
            // from ever starting. And only where a Start relocates something
            // (startsRelocate): on Megalooper SA the Start is the drums' bar 1
            // and nothing else, so a later analysis restarts them on the loop
            // whether or not the set is being recorded.
            if(this.startsRelocate and: { this.sessionRecording } and: { this.transport.running }) {
                ("Session recording: not restarting the transport ("
                    ++ result.bpm.round(0.1) ++ " BPM detected). A MIDI Start "
                    "would jump it back to bar 1 and overwrite the take.").postln;
            } {
                this.startMidiClock(result.bpm, loopSecs);
            };
        };
        this.startChordRoutine(result);
        // Started again here, not only from spawnEngine: on a fresh take the
        // engine is spawned BEFORE the analysis exists, so at that point there
        // was no pattern to play. Restarting is phase-aligned and idempotent.
        this.startOnsetNotes;
    }

    // Walk the chord progression in lockstep with the loop. Each iteration of
    // the outer inf.do covers exactly one loopDur — the trailing wait after the
    // last segment closes the gap to loopDur, so segment 0 fires again exactly
    // on the next loop pass. Not phase-aligned to server.latency (matches the
    // existing clickRoutine pattern); fine for chord display and
    // for AbletonOSC since Live applies its own scale changes near-instantly.
    startChordRoutine { |result|
        var segments = result !? { |r| r[\chordSegments] };
        var loopSecs = result !? { |r| r.loopDur };
        chordRoutine !? { |r| r.stop };
        chordRoutine = nil;
        if(segments.isNil or: { segments.isEmpty } or: { loopSecs.isNil }) {
            ^this
        };
        chordRoutine = Routine {
            inf.do {
                segments.do { |seg, i|
                    var nextStart = if(i + 1 < segments.size) {
                        segments[i + 1][\start]
                    } { loopSecs };
                    onChordChange.value(seg);
                    // And to whoever listens (the window's key).
                    this.changed(\chord, seg);
                    // At half-time each segment lasts twice as long.
                    ((nextStart - seg[\start]) / this.speed).wait;
                };
            };
        }.play(SystemClock);
    }

    // ===================================================================
    // Onset notes — the loop's rhythm as MIDI (LooperOnsetNotes)
    // ===================================================================
    // The part, made when first asked for: a Looper made without init (the
    // tests' newCopyArgs) has one too.
    onsetNotesPart { ^onsetNotesPart ?? { onsetNotesPart = LooperOnsetNotes(this) } }

    // Whether the loop's audio is playing: the engine runs. stopPlayback and
    // clear take it away, and spawnEngine has made it by the time it starts
    // the onset notes. What the onset notes start against.
    enginePlaying { ^engineSynth.notNil }

    // The facade: the window, MIDI, the AI, the drums' sink and the tests ask
    // the Looper, which asks its part.
    onsetNotes { ^this.onsetNotesPart.onsetNotes }
    onsetNote { ^this.onsetNotesPart.onsetNote }
    onsetNoteChannel { ^this.onsetNotesPart.onsetNoteChannel }
    onsetNoteVelLo { ^this.onsetNotesPart.onsetNoteVelLo }
    onsetNoteVelHi { ^this.onsetNotesPart.onsetNoteVelHi }
    onsetNoteDynRange { ^this.onsetNotesPart.onsetNoteDynRange }
    onsetNoteGateMs { ^this.onsetNotesPart.onsetNoteGateMs }
    onsetNoteOffsetMs { ^this.onsetNotesPart.onsetNoteOffsetMs }
    onsetNoteChance { ^this.onsetNotesPart.onsetNoteChance }
    onsetNotePatternDur { ^this.onsetNotesPart.onsetNotePatternDur }
    onsetNoteSink { ^this.onsetNotesPart.onsetNoteSink }
    onsetNotes_ { |flag| this.onsetNotesPart.onsetNotes_(flag) }
    onsetNote_ { |val| this.onsetNotesPart.onsetNote_(val) }
    onsetNoteChannel_ { |val| this.onsetNotesPart.onsetNoteChannel_(val) }
    onsetNoteVelLo_ { |val| this.onsetNotesPart.onsetNoteVelLo_(val) }
    onsetNoteVelHi_ { |val| this.onsetNotesPart.onsetNoteVelHi_(val) }
    onsetNoteDynRange_ { |val| this.onsetNotesPart.onsetNoteDynRange_(val) }
    onsetNoteGateMs_ { |val| this.onsetNotesPart.onsetNoteGateMs_(val) }
    onsetNoteOffsetMs_ { |val| this.onsetNotesPart.onsetNoteOffsetMs_(val) }
    onsetNoteChance_ { |val| this.onsetNotesPart.onsetNoteChance_(val) }
    onsetNoteSink_ { |sink| this.onsetNotesPart.onsetNoteSink_(sink) }
    onsetNoteCount { ^this.onsetNotesPart.count }
    onsetNotePlayingCount { ^this.onsetNotesPart.playingCount }
    rerollOnsetNotes { this.onsetNotesPart.reroll }
    startOnsetNotes { this.onsetNotesPart.start }
    stopOnsetNotes { this.onsetNotesPart.stop }
    // For an onsetNoteSink, which decides each hit itself and must agree with
    // the routine about which hits play and how loud.
    onsetPlays { |i| ^this.onsetNotesPart.plays(i) }
    onsetVelocity { |ratio| ^this.onsetNotesPart.velocity(ratio) }
    // The Looper's own uses (a take's onsets, a clear), and the tests'.
    prBuildOnsetPattern { |pairs, patternDur| this.onsetNotesPart.buildPattern(pairs, patternDur) }
    prClearOnsetPattern { this.onsetNotesPart.clearPattern }
    prOnsetPlays { |i| ^this.onsetNotesPart.plays(i) }
    prOnsetVelocity { |ratio| ^this.onsetNotesPart.velocity(ratio) }
    prStopOnsetMidi { this.onsetNotesPart.stopMidi }

    // `bars`: pulses per bar, one entry per bar of the loop (MeterDecision.clickBars), or
    // one number for bars all alike. The accent falls on every bar line.
    startClick { |tau, bars|
        var lens = bars.asArray.collect { |b| b.asInteger.max(1) };
        var cycle = lens.sum;
        var lines = lens.inject([0], { |acc, b| acc.add(acc.last + b) }).drop(-1).asSet;
        clickRoutine !? { |r| r.stop };
        clickRoutine = Routine {
            var i = 0;
            inf.do {
                var isDownbeat = lines.includes(i % cycle);
                Synth(\looperClick, [
                    \freq, if(isDownbeat) { 1500 } { 900 },
                    \amp,  if(isDownbeat) { 0.5 }  { 0.2 }
                ], server);
                tau.wait;
                i = i + 1;
            };
        }.play(SystemClock);
    }

    // Start the transport on the loop: its bar line on the first loop boundary
    // at least a beat of pre-roll away (Callers pass the LOOP period, not a
    // bar: any repetition will do, never mid-take). Live's streams its clock
    // at once and aims the Start by its port's latency and the sync trim
    // (LiveMidiTransport); SA's drums begin their bar 1 there
    // (MegaSATransport). Nothing with transportMode \off.
    startMidiClock { |bpm, alignDur|
        if(transportMode == \off) { ^this };
        this.transport.start(bpm, alignDur, this.loopStartTime);
    }

    free {
        // First: a set being recorded must reach the disk even if the looper is
        // being torn down around it, and stop() is what closes the files.
        sessionRec !? { |r| r.free };
        CmdPeriod.remove(this);
        this.prCancelBBCutEnable;
        this.teardownBBCut;
        chainPart !? { |c| c.free };
        recSynth !? { |s| s.free };
        autostartSynth !? { |s| s.free };
        autostartSynth = nil;
        engineSynth !? { |s| s.free };
        grainsPart !? { |g| g.free };
        masterSynth !? { |s| s.free };
        tapLevelSynth !? { |s| s.free };
        clickRoutine !? { |r| r.stop };
        chordRoutine !? { |r| r.stop };
        dissolveRoutine !? { |r| r.stop };
        // Every arm: a break's end, a reading, half-time, a reverse, the
        // transport's start (before 2026-11-08 free left half-time and the
        // reverse running: a landing after free restarted the onset notes and
        // sent MIDI).
        this.timeline.cancelAll;
        this.transport.free(transportMode == \full);
        buffer !? { |b| b.free };
        undoBuffer !? { |b| b.free };
        outBus !? { |b| b.free };
        phaseBus !? { |b| b.free };
        tapGainBus !? { |b| b.free };
        insertBus !? { |b| b.free };
        this.stopOnsetNotes;
        onsetResp !? { |r| r.free };
        pitchResp !? { |r| r.free };
        levelsResp !? { |r| r.free };
        autostartResp !? { |r| r.free };
        tapLevelResp !? { |r| r.free };
        this.stopAnalysisMonitor;
        this.stopOverdubAnalysis;
    }
}
