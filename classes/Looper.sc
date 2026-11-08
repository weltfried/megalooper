Looper {
    var <server, <bufDur, <>midiOut;
    var buffer, undoBuffer;
    var recSynth, engineSynth, granularSynth, masterSynth;
    var outBus;
    var clickRoutine, midiClockRoutine, chordRoutine;
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
    var overdubOnsets, overdubSynth, overdubResp, overdubSyncRoutine;
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
    // Does a Start relocate anything worth protecting? In Live it does: it
    // jumps the arrangement back to 1.1.1, so while a session recording runs a
    // later analysis or a reading keeps its Start to itself (startTempoClocks,
    // prLandReading). On Megalooper SA the Start goes to SA's own drums, which
    // just begin their bar on the loop, and the session recorder writes SC's
    // own files: MegaSA sets this false, so the drums' bar line follows the
    // loop there too. True is the behaviour every Live profile has always had.
    var <>startsRelocate = true;
    // ---- Onset notes -------------------------------------------------------
    // The loop's own detected onsets, replayed every pass as MIDI notes, so Live
    // can trigger a drum rack or sampler from the rhythm that was actually
    // played. This is the STORED pattern, not a live trigger: it is built once
    // from the analysis and then repeats in lockstep with the audio, which is
    // what makes it survive you stopping playing.
    var <onsetNotes = false;
    // Channel 2 (0-based 1). It kept clear of the per-bar marker note that used
    // to go out on channel 1; that marker is gone, but the default stays where
    // every rig here is already mapped.
    var <onsetNote = 36, <onsetNoteChannel = 1;
    var <onsetNoteVelLo = 40, <onsetNoteVelHi = 127;
    // Velocity is mapped over this many dB below the loop's LOUDEST hit. Linear
    // on amplitude piles nearly every guitar onset at the top of the range; dB
    // is how the dynamics actually read. Small = compressed, large = wider.
    var <onsetNoteDynRange = 30;
    var <onsetNoteGateMs = 20;
    // Timing trim, ms, NEGATIVE = send earlier. Per-rig, and for the same reason
    // latencyMs and abletonSyncMs are: the loop's audio and the notes reach your
    // ears down different paths, and only the rig knows the difference between
    // them. The loop goes SC -> the virtual device -> Live -> out (two buffers
    // that the notes never see); the notes go SC -> IAC -> Live, where they are
    // quantised to Live's next audio block and then run through whatever delay
    // compensation the set has. None of that is knowable from here, so it is a
    // number you set by ear or by measurement and write back into the profile.
    var <onsetNoteOffsetMs = 0;
    // [[phase, strengthRatio], ...] — phase in seconds from the loop's start,
    // ratio 0..1 against the loudest hit (so it is independent of input gain).
    // Velocity is computed at SEND time from the ratio, which is why changing the
    // velocity controls takes effect without rebuilding or restarting anything.
    //
    // The period is the pattern's OWN, deliberately not loopFrames: multiply and
    // loop chaining lengthen the loop by an integer factor and COPY the audio
    // with it, so a pattern that keeps its original period tiles across the
    // longer loop exactly as the audio does.
    var onsetNotePattern, <onsetNotePatternDur;
    // Probability that any one onset is actually sent, 0..1. Thins the drum part
    // without touching the pattern: at 0.5 about half the hits play, at 0 none,
    // at 1 all of them, and the analysed pattern itself is never edited — so
    // sweeping back up to 1 restores exactly what was played.
    var <onsetNoteChance = 1.0;
    // One uniform 0..1 draw per hit, PARALLEL to onsetNotePattern and drawn with
    // it. A hit plays while its draw is below onsetNoteChance.
    //
    // Stored rather than rolled per pass, which is the whole design of this
    // control: the onset part is a stable clip that repeats exactly (see the
    // pattern's own note above), and re-rolling every pass would turn it into a
    // different rhythm every time round. So the dice are thrown ONCE, and the
    // chance slider then only raises or lowers the waterline over them —
    // dragging it is monotonic, and 0.5 -> 0.6 ADDS hits rather than reshuffling
    // the ones already sounding. rerollOnsetNotes throws them again on demand.
    //
    // Parallel to the pattern rather than a third element inside it because the
    // pattern's [time, strength] shape is read by calibrate-measure.scd and
    // asserted element by element in tests/test-onset-notes.scd.
    var onsetNoteRolls;
    var onsetNoteRoutine;
    // [channel, note] while a gate is open, so a routine stopped mid-note can
    // release exactly the note it started. Nothing else would ever clear it.
    var onsetNoteSounding;
    // Who plays the onset notes instead of the MIDI routine, or nil (every Live
    // profile): Megalooper SA's drums, which play them on their own onset kit
    // as timestamped server bundles rather than as MIDI notes sent on time from
    // a routine. Answers startOnsets(looper, pattern, period) and
    // stopOnsets(looper); startOnsetNotes and stopOnsetNotes hand it the part
    // at the same moments they would start or stop the routine, so every
    // restart point here (a respawn, an analysis, the end of a break, undo, the
    // offset and the switch) still drives it.
    var <>onsetNoteSink;
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
    var <speed = 1, <halfTime = \off, <halfTimeAt, <passOrigin, <speedChangedAt;
    var halfTimeRoutine, halfTimeSeq = 0, halfTimeSentAt, halfOnsets;
    // A reverse armed for the next boundary (reverse): `reverseArmed`, and
    // `reverseAt` where it lands; reverseFlag flips there.
    var <reverseArmed = false, <reverseAt, reverseRoutine, reverseSeq = 0, reverseSentAt;
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
    // This counts fires, so a callback belonging to a break that was cancelled
    // or re-fired in the meantime knows to do nothing.
    var breakSeq = 0;
    var breakRoutine;
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
    var readingRoutine, readingSeq = 0;
    // The reading in force until a landing's `at`: lastResult swaps a little
    // before it (prLandReading), and countResult answers this meanwhile.
    var landingFrom;
    // Where Live's tick count stands: clockTicksAtRef ticks had gone out at
    // SystemClock time clockRefTime, and clockTickRate per second have gone out
    // since. Set by every aligned Start, moved by every reading that changes
    // the tempo. Kept as a TIME rather than a loop index, so a chain handoff
    // or a multiply that moves loopStartTime cannot stale it. Together they
    // say, for any future loop boundary, whether Live's bar line falls on it —
    // which is what decides where a reading lands. nil until a Start goes out.
    var clockTicksAtRef, clockRefTime, clockTickRate;
    // The clock's tick period, an ivar so a reading can move it live.
    var clockPeriod;
    // ---- Granular voice ----------------------------------------------------
    // `granularMorph` stays the meta-control: it sets the BASE of the texture
    // (window size, overlaps, scan rate, jitter) between frozen drone and
    // beat-locked pulse. Everything below BENDS that base, and every default is
    // NEUTRAL — an untouched instrument sounds exactly as it did before these
    // existed. See the \looperGranular SynthDef for how each one folds in.
    var <granularMorph = 0;
    var <granularAmp = 0.3;        // layer level, 0..1
    var <granularPitch = 0;        // grain transposition, semitones
    var <granularDetune = 0;       // +/- semitones of PER-GRAIN random detune
    var <granularSize = 1;         // grain-window multiplier on morph's base
    var <granularDensity = 1;      // overlap multiplier on morph's base
    var <granularSizeRand = 0.1;   // Warp1 windowRandRatio, 0..1
    var <granularPosition = 0;     // read point within the loop region, 0..1
    var <granularScan = 0;         // EXTRA passes through the loop per loopDur
    var <granularSpray = 0;        // absolute position spray, ms
    var <granularEnv = 0;          // index into Looper.granularEnvNames
    // Off: the grains play the loop as it sounds where they read (as they
    // always did). On: transposed with the take's chord changes (roadmap
    // item 8; the \looperGranular graph).
    var <granularFollowChords = false;
    var granularEnvBufs;
    var <transportMode = \full;
    var <latencyMs = 0;
    var <declickMs = 3;
    var <feedback = 1.0;
    var <>chordMinPerWindow = 3;
    var <bbcut = false;
    // How the cutter sits against the dry loop, mirroring Ableton Beat Repeat:
    //   \mix    — dry loop + cutter both audible (layered)
    //   \insert — dry loop passes, but ducks to silence for the duration of any
    //             repetition (repeats>1 / stutter); the cutter is only heard then
    //   \gate   — dry loop fully muted; only the cutter is heard (original toggle)
    // In \insert mode a LooperCutGate in each voice's chain writes `insertBus`
    // (1 while a repetition plays); the engine SynthDef reads it to duck the dry.
    var <bbcutMode = \insert;
    var insertBus;
    // Multi-voice cutter. `bbcutVoices` is a List of voice config Events (see
    // defaultBBCutVoice); each enabled voice becomes its own CutGroup + proc on
    // its own ExternalClock at baseBps * ratio, layered over one shared buffer
    // to produce polyrhythm. The spec tables drive both the proc/fx builders
    // and the GUI (so controls are rendered generically from `params`).
    var <bbcutVoices;
    var <bbcutProcSpecs, <bbcutProcOrder, <bbcutFxSpecs, <bbcutFxOrder;
    // Each voice owns its own server resources (BBCut2 inst, ExternalClock,
    // CutMixer) stashed on its config Event, so structural changes touch only
    // the affected voice. `bbcutBuffer` is the single shared snapshot buffer.
    var bbcutBuffer;
    var <bbcutEnabling = false;
    // enableBBCut's routine, waiting for the boundary to bring the cutter in:
    // kept, so a stop, a clear, a new take or free takes a cutter starting back.
    var bbcutEnableRoutine;
    // When the current engine started, in SystemClock (logical) seconds: the
    // anchor every language-side layer counts the loop from. Readable for
    // Megalooper SA's drums, which put their grid on it.
    var <loopStartTime;
    // MIDI-clock sync offset (ms, may be negative). Shifts WHEN SC sends the MIDI
    // Start + clock stream relative to the loop's audio, to cancel the ~10-20 ms
    // Live otherwise lags as a MIDI-clock follower: negative pulls Live earlier.
    // Applied to the Start timing at play (startMidiClock), and folded into the
    // running stream live via abletonSyncMs_ (clockNudge). See also Live's own
    // MIDI Clock Sync Delay preference for a per-input trim.
    var <abletonSyncMs = 0;
    var clockNudge = 0;   // seconds to fold into upcoming clock-tick waits (live shift)
    // Loop chaining: record a new loop (guitar + processed loop return from
    // Live, captured on inChannel) over the currently playing one, quantized to
    // loop boundaries, then swap it in as the active loop. nextBuffer is the
    // double-buffer scratch; the active `buffer` and `nextBuffer` are swapped on
    // handoff. nextRecState: \idle -> \armed -> \recording -> (swap) -> \idle.
    var nextBuffer, nextRecSynth, nextRecRoutine;
    // Where the chain recorder starts, relative to the loop boundary, in ms.
    // NEGATIVE starts it earlier. Default 0 = the old behaviour exactly.
    //
    // It exists because the chained loop can land rotated inside its own buffer,
    // and nothing here can derive by how much: the recorder finds its boundary
    // from `loopStartTime` (which carries whatever skew that has) and records
    // audio that arrived a round trip after it was played. Measure it with
    // scripts/check-chain-align.scd and set this to exactly what it reports —
    // the tool's sign and this one are deliberately the same.
    var <chainRecOffsetMs = 0;
    // The recorder outlives the swap when the offset is POSITIVE, finishing the
    // tail it started late for. Held here rather than in a closure so a teardown
    // or a cancel in that window can still reach it.
    var nextRecTail;
    var <nextRecState = \idle, nextRecStopRequested = false, nextRecReps = 0;
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

    // Grain-window shapes offered by the granular layer. Index 0 is Warp1's own
    // built-in Hann (envbufnum -1, so it needs no buffer); the rest are the Envs
    // in prGranularEnvShapes, index-aligned from 1. The GUI renders the menu
    // straight from this, so adding a shape means editing both, in step.
    *granularEnvNames { ^["Hann (built in)", "Plateau", "Percussive", "Swell"] }

    // What each shape does, index-aligned with the names: the line under the
    // Grains view's tiles, and what an AI app is told (MegaRemote).
    *granularEnvHints {
        ^[
            "Smooth and symmetrical, the default.",
            "Flat top, short fades. Thicker drones, harder pulses.",
            "Instant attack, long decay. Every grain becomes a little hit.",
            "Reversed percussive. Attacks are erased, so even a plucked loop smears into a pad."
        ]
    }

    *prGranularEnvShapes {
        ^[
            // Plateau: short fades around a flat top. More energy per grain than
            // Hann and a squarer edge — thicker drones, harder pulses.
            Env([0, 1, 1, 0], [0.15, 0.7, 0.15], \sin),
            // Percussive: instant attack, long decay. Turns each grain into a
            // little hit, which is what makes the pulsed end read as rhythm.
            Env([0, 1, 0], [0.02, 0.98], [\lin, -4]),
            // Swell: the same shape backwards — grains fade IN, so attacks are
            // erased entirely and even a plucked loop smears into pad.
            Env([0, 1, 0], [0.98, 0.02], [4, \lin])
        ]
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
            var envShapes = Looper.prGranularEnvShapes;
            buffer = Buffer.alloc(server, server.sampleRate * bufDur, 2);
            undoBuffer = Buffer.alloc(server, server.sampleRate * bufDur, 2);
            nextBuffer = Buffer.alloc(server, server.sampleRate * bufDur, 2);
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
            granularEnvBufs = envShapes.collect { Buffer.alloc(server, 1024, 1) };
            server.sync;
            granularEnvBufs.do { |b, i| b.sendCollection(envShapes[i].discretize(1024)) };
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
            granularEnv: [\state, [\index], "the grain window (Looper.granularEnvNames)"],
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
        engineSynth = nil; recSynth = nil; granularSynth = nil; masterSynth = nil;
        tapLevelSynth = nil; monitorSynth = nil; overdubSynth = nil; nextRecSynth = nil;
        clickRoutine = nil; midiClockRoutine = nil; chordRoutine = nil; breakRoutine = nil;
        dissolveRoutine = nil; readingRoutine = nil; halfTimeRoutine = nil; reverseRoutine = nil;
        bbcutEnableRoutine = nil; nextRecRoutine = nil; overdubSyncRoutine = nil;
        bbcutEnabling = false;
        if(bbcut) { bbcut = false; this.changed(\bbcut, false) };
        this.changed(\granular, false);
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
        this.prCancelBBCutEnable;
        if(bbcut) { this.disableBBCut };
        // A reading armed for the loop being replaced has nothing to land on.
        this.prCancelReading;
        this.snapshotForUndo;
        buffer.zero;
        onsets.clear;
        pitchSamples.clear;
        takeLevels = nil;
        this.prSetTapStarved(nil);
        // The replay pattern belongs to the take it was analysed from. Dropping
        // it here means the engine spawned below finds nothing to play until the
        // deferred analysis builds the new one, rather than replaying the
        // previous loop's rhythm over this one.
        this.prClearOnsetPattern;
        recStartTime = SystemClock.seconds;
        this.prTapLevelFollow;
        recSynth = Synth(defName, [
            \bufnum, buffer.bufnum,
            \in, inChannel,
            \ana, this.analysisIn,
            \onsetThreshold, onsetThreshold,
            \tapGainBus, this.prTapGainIndex
        ], server);
        this.prLogEvent(\recordStart,
            (threshold: onsetThreshold, ana: this.analysisIn, in: inChannel), recStartTime);
        this.prSetState(\recording);
        "Recording...".postln;
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
            if(nextRecState == \armed) { list.add((what: \recordNextLoop, at: this.prNextBoundaryAt(now))) };
            if(nextRecState == \stopping) { list.add((what: \recordNextLoopEnds, at: this.prNextBoundaryAt(now))) };
            if(bbcutEnabling and: { bbcut.not }) { list.add((what: \cutter, at: this.prNextBoundaryAt(now))) };
            if(halfTime == \armed) { list.add((what: \halfTime, at: halfTimeAt)) };
            if(halfTime == \releasing) { list.add((what: \halfTimeEnds, at: halfTimeAt)) };
            if(reverseArmed) { list.add((what: if(reverseFlag) { \forward } { \reverse }, at: reverseAt)) };
        };
        ^list.asArray
    }

    // The next loop boundary after `now`, counted from loopStartTime as the
    // reading, the next loop and the cutter count it; at half-time, the next
    // end of a half-speed pass, counted from where they began.
    prNextBoundaryAt { |now|
        var ld = this.wallPeriod, origin;
        origin = if((speed != 1) and: { passOrigin.notNil }) { passOrigin } { loopStartTime ? now };
        ^origin + ((((now - origin) / ld).floor + 1) * ld)
    }

    // A pass in wall time: the loop's length at the speed it plays.
    wallPeriod { ^this.loopDuration / speed }

    // Where a pass at the speed now began (one of them): loopStartTime, or at
    // half-time the boundary it landed on. The onset kit counts from it.
    passStart { ^if((speed != 1) and: { passOrigin.notNil }) { passOrigin } { loopStartTime } }

    // The speed after the next boundary, with what is armed: a landing or a
    // release.
    prSpeedAfterNext { ^switch(halfTime, \armed, { 0.5 }, \releasing, { 1 }, { speed }) }

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
            \gateMode, if(bbcut) { this.bbcutGateCode } { 0 }
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
        loopStartTime = SystemClock.seconds;
        // A granular layer toggled on over the stopped loop had no engine to
        // follow and scans freely; now there is one, and the new engine sits
        // ahead of it in the node order. See \looperGranular. And it reads
        // what this engine reads (Record next loop swapped the buffers).
        granularSynth !? { |g| g.set(\locked, 1) };
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
    // While a loop plays, fold the CHANGE into the running MIDI-clock stream as a
    // phase nudge (clockNudge, drained over a few ticks in startMidiClock) so
    // Live's clock-follower slews to the new offset live, without a jarring
    // re-Start. The value is also applied to the Start timing on the next play.
    // Sign: a more-negative offset shortens upcoming tick gaps, advancing Live.
    abletonSyncMs_ { |val|
        if(midiClockRoutine.notNil) {
            clockNudge = clockNudge + ((val - abletonSyncMs) / 1000);
        };
        abletonSyncMs = val;
        this.changed(\abletonSyncMs, abletonSyncMs);
    }

    declickFrames { ^(declickMs * server.sampleRate / 1000).asInteger }

    declickMs_ { |val|
        declickMs = val.max(0);
        engineSynth !? { |s| s.set(\declickFrames, this.declickFrames) };
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
        returnChannel !? { nextRecSynth !? { |s| s.set(\ret, returnChannel) } };
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
        overdubSyncRoutine !? { |r| r.stop };
        overdubSyncRoutine = Routine {
            var now  = (SystemClock.seconds - (loopStartTime ? SystemClock.seconds))
                .mod(loopSecs);
            var wait = (target - now).mod(loopSecs);
            ("Overdub detect: " ++ result[\numerator] ++ "/" ++ result[\denominator]
                ++ " @ " ++ result[\bpm].round(0.1) ++ " BPM over " ++ result[\k]
                ++ " bars from " ++ result[\onsetCount] ++ " onsets — the transport starts in "
                ++ wait.round(0.01) ++ " s.").postln;
            wait.wait;
            this.startTempoClocks(result);
        }.play(SystemClock);
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
        switch(nextRecState,
            \recording, {
                nextRecStopRequested = true;
                nextRecState = \stopping;
                this.changed(\nextRecState, \stopping);
                "Next loop: will stop at the end of the current loop.".postln;
            },
            \armed, { this.cancelNextLoopRecord },
            \stopping, { /* already closing out — ignore */ },
            {
                if(this.prAtHalfTime) { ^this.prRefused(\recordNextLoop, "half-time: end it first") };
                this.armNextLoopRecord
            }   // \idle / default
        );
    }

    // The calibrated chain-record trim in seconds, clipped to under a loop
    // either way so the shifted start cannot cross a neighbouring boundary and
    // land the recording a whole repetition out.
    prChainRecOffset { |loopSecs|
        ^(chainRecOffsetMs / 1000).clip(loopSecs * -0.9, loopSecs * 0.9)
    }

    // Seconds to wait, from `phaseInLoop` into the current pass, before the
    // chain recorder starts: the NEXT loop boundary, shifted by `off`.
    //
    // Deliberately NOT .mod(loopSecs). That collapses the wait to nearly zero
    // whenever a positive offset pushes it past a whole loop, starting the
    // recorder at THIS boundary instead of the next one. Only a negative result
    // needs rescuing, and it needs a whole loop added.
    //
    // Pure on purpose. This arithmetic got the chained loops wrong once, and
    // inline in the Routine below — next to Synth.tail and the buffer — there
    // was no way to test it. See scripts/tests/test-chain-timing.scd.
    prChainStartWait { |loopSecs, phaseInLoop, off|
        var wait = (loopSecs - phaseInLoop) + off;
        if(wait < 0) { wait = wait + loopSecs };
        ^wait
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
            play: this.prLogTime(loopStartTime),
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

    armNextLoopRecord {
        var sr = server.sampleRate;
        var ld = loopFrames / sr;
        var defName = if(inChannelCount == 1) { \looperRecPlainMono } { \looperRecPlain };
        if(this.canChainLoops.not) {
            "Next loop: this rig has no return channel, so loop chaining is off."
                .warn;
            ^this.prRefused(\recordNextLoop, "this rig has no return channel to chain from")
        };
        if(loopFrames == 0) { "Next loop: no loop playing.".warn; ^this.prRefused(\recordNextLoop, "no loop playing") };
        nextRecStopRequested = false;
        nextRecReps = 0;
        nextRecState = \armed;
        nextBuffer.zero;
        this.changed(\nextRecState, \armed);
        "Next loop: armed — recording starts at next loop boundary.".postln;
        nextRecRoutine = Routine {
            var off = this.prChainRecOffset(ld);
            var firstRep = true;
            // Wait to the next loop boundary off the same wall-clock reference
            // BBCut uses (loopStartTime = audio start of the current engine),
            // shifted by the calibrated offset.
            var phaseInLoop = (SystemClock.seconds
                - (loopStartTime ? SystemClock.seconds)) % ld;
            this.prChainStartWait(ld, phaseInLoop, off).wait;
            nextRecSynth = Synth.tail(server, defName, [
                \bufnum, nextBuffer.bufnum,
                \in, inChannel,
                \ret, returnChannel
            ]);
            nextRecState = \recording;
            this.changed(\nextRecState, \recording);
            "Next loop: recording...".postln;
            // Count completed reps; a stop request takes effect at the boundary
            // that closes the current rep. Also bail if the buffer would overflow.
            //
            // The rep grid stays on the TRUE boundaries — only the first wait
            // absorbs the offset — so the swap still happens exactly on a loop
            // boundary and the handoff stays gapless.
            while { nextRecStopRequested.not } {
                if(firstRep) { (ld - off).wait; firstRep = false } { ld.wait };
                nextRecReps = nextRecReps + 1;
                if((nextRecReps + 1) * loopFrames > nextBuffer.numFrames) {
                    "Next loop: scratch buffer full — stopping.".warn;
                    nextRecStopRequested = true;
                };
            };
            this.finishNextLoopRecord(off);
        }.play(SystemClock);
    }

    finishNextLoopRecord { |off = 0|
        var n = nextRecReps.max(1);
        var newFrames = n * loopFrames;
        var oldEngine = engineSynth;
        var tmp;
        // A recorder that started LATE (positive offset) is still short of the
        // final rep, so let it finish the tail; one that started early already
        // has everything and is freed here as before. It writes into what is
        // about to become the ACTIVE buffer, but the new engine below reads from
        // frame 0 while the write head is a whole loop further on.
        this.prFreeNextRecTail;
        nextRecSynth !? { |syn|
            if(off > 0) {
                nextRecTail = syn;
                SystemClock.sched(off, { this.prFreeNextRecTail; nil });
            } {
                syn.free;
            };
        };
        nextRecSynth = nil;
        nextRecRoutine = nil;
        // Snapshot the OLD loop first so Undo can revert the swap.
        this.snapshotForUndo;
        // A reading armed for the old loop has nothing to land on (multiply's).
        this.prCancelReading;
        // Double-buffer swap: the freshly recorded buffer becomes active; the
        // old active buffer becomes the scratch for the next capture.
        tmp = buffer; buffer = nextBuffer; nextBuffer = tmp;
        startFrame = 0;
        loopFrames = newFrames;
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
        nextRecState = \idle;
        nextRecStopRequested = false;
        this.changed(\nextRecState, \idle);
        ("Next loop active: " ++ n ++ "x current loop ("
            ++ (newFrames / server.sampleRate).round(0.01) ++ " s).").postln;
    }

    prFreeNextRecTail {
        nextRecTail !? { |s| s.free };
        nextRecTail = nil;
    }

    // Set this to exactly what scripts/check-chain-align.scd reports.
    chainRecOffsetMs_ { |val|
        chainRecOffsetMs = val.clip(-2000, 2000);
        this.changed(\chainRecOffsetMs, chainRecOffsetMs);
    }

    cancelNextLoopRecord {
        var wasActive = #[\armed, \recording, \stopping].includes(nextRecState);
        nextRecRoutine !? { |r| r.stop }; nextRecRoutine = nil;
        nextRecSynth !? { |s| s.free }; nextRecSynth = nil;
        this.prFreeNextRecTail;
        nextRecStopRequested = false;
        if(nextRecState != \idle) {
            nextRecState = \idle;
            this.changed(\nextRecState, \idle);
        };
        if(wasActive) { "Next loop: cancelled.".postln };
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

    // Build the proc / fx / synth spec tables and seed one default voice. The
    // spec build closures are pure (they take voice + totalBeats) so they can
    // be cached for the instance's lifetime.
    initBBCut {
        // Curated cut procedures. Each spec: a `name`, a one-line `desc` and
        // per-param `hint` strings (both rendered by the GUI, so the wording
        // lives with the thing it describes), the ordered `params`
        // (key/label/range/default/int) the GUI renders, the subset of params
        // that are `live` (re-read from the voice's params Event at a phrase
        // boundary via closures — changing them needs no rebuild), and a
        // `build` closure mapping the voice's params to the proc constructor.
        // Non-live params are read as plain numbers at build time, so changing
        // them rebuilds the cutter.
        bbcutProcOrder = [\break, \bbcut11, \warp, \choose, \sqpusher];
        bbcutProcSpecs = (
            // The house procedure (see LooperBreakProc): built for looped
            // playing rather than breakbeats — it mostly passes the loop
            // through and only sometimes repeats a block. Every param is read
            // per block through a closure, so all of them are live.
            break: (
                name: "Break/Repeat",
                desc: "Mostly plays the loop through; now and then repeats a whole block.",
                live: [\cutchance, \minblock, \maxblock, \repeats, \phraselength, \rollchance],
                // Which parameter the arc pedal drives: how MUCH the cutter is
                // chopping, as opposed to how loud it is. Must always be one of
                // `live` above and must be read through prVoiceDensity in the
                // build closure — check.scd asserts the first, test-source-guards
                // the second. A non-live key would respawn the voice on every
                // pedal movement.
                intensityKey: \cutchance,
                params: [
                    (key: \cutchance,   label: "Cut chance", lo: 0, hi: 1,  default: 0.25, int: false,
                        hint: "Chance per block of a repeat happening at all. 0 = never break up."),
                    (key: \minblock,    label: "Min block",  lo: 1, hi: 16, default: 2,    int: true,
                        hint: "Shortest chunk that can be repeated, in pulses (loop beats)."),
                    (key: \maxblock,    label: "Max block",  lo: 1, hi: 16, default: 4,    int: true,
                        hint: "Longest chunk. Set it equal to Min for a fixed block size."),
                    (key: \repeats,     label: "Repeats",    lo: 2, hi: 8,  default: 2,    int: true,
                        hint: "How many times the chunk plays: 2 = it plays, then repeats once."),
                    (key: \phraselength, label: "Phrase",    lo: 2, hi: 32, default: 8,    int: true, slider: true,
                        hint: "Phrase length in beats. Rounds to whole loop passes (keeps repeats aligned)."),
                    (key: \rollchance,  label: "Roll chance", lo: 0, hi: 1, default: 0,    int: false,
                        hint: "Chance a repeat is a double-speed roll instead of a plain repeat.")
                ],
                // Phrase is dialled in beats like every other proc, but the
                // value that reaches BBCut is SNAPPED to a whole number of loop
                // passes. That is not tidiness: repeats leave `offset` nil, so
                // BBCutBuffer reads at `phrasepos % beatlength`, and
                // newPhraseAccounting resets phrasepos to 0 at each phrase. A
                // phrase that is not a whole number of passes therefore restarts
                // the cutter's read head while the dry loop is mid-pass, and the
                // "beat-repeat pedal" illusion this proc exists for is gone.
                build: { |voice, totalBeats| var p = voice[\params];
                    LooperBreakProc.new(
                        cutchance:    { this.prVoiceDensity(voice, \cutchance) },
                        minblock:     { p[\minblock] },
                        maxblock:     { p[\maxblock] },
                        repeats:      { p[\repeats] },
                        rollchance:   { p[\rollchance] },
                        phraselength: {
                            totalBeats * ((p[\phraselength] ? 8) / totalBeats).round.max(1)
                        }
                    )
                }
            ),
            bbcut11: (
                name: "BBCutProc11",
                desc: "Classic breakbeat cutting: odd-length cuts with repeats, stutter to end a phrase.",
                live: [\sdiv, \phraselength, \stutterchance, \stutterspeed],
                // sdiv would be the other candidate, but it is the cut GRID:
                // scaling it changes the character rather than the amount, and
                // even at its floor the proc still cuts every phrase. Stutter is
                // the part that reads as intensity.
                intensityKey: \stutterchance,
                params: [
                    (key: \sdiv,          label: "Chop",    lo: 2, hi: 32, default: 8,   int: true,
                        hint: "Slices per loop pass — the cut grid. Higher = finer, busier chopping."),
                    (key: \phraselength,  label: "Phrase",  lo: 2, hi: 32, default: 24,  int: true, slider: true,
                        hint: "Phrase length in beats. Rounds to whole loop passes; new cut pattern each phrase."),
                    (key: \stutterchance, label: "Stutter", lo: 0, hi: 1,  default: 0.2, int: false,
                        hint: "Chance (0–1) that a phrase ends in a stutter — a repeating one-slice roll."),
                    (key: \stutterspeed,  label: "StutSpd", lo: 1, hi: 8,  default: 2,   int: true,
                        hint: "Stutter speed as a multiple of the chop grid (2 = twice as fast).")
                ],
                // barlength stays pinned to totalBeats — that is what makes a
                // "bar" one loop pass, and it is what `sdiv` (slices per loop
                // pass) is measured against, so moving it would silently change
                // what the Chop control means. Phrase is therefore dialled in
                // beats and converted to bars here. BBCutProc11 rounds
                // phrasebars to an integer itself (see its chooseblock), so the
                // effective phrase is always a whole number of loop passes —
                // the same snapping Break/Repeat does explicitly above.
                build: { |voice, totalBeats| var p = voice[\params];
                    BBCutProc11.new(
                        sdiv:          { p[\sdiv] },
                        barlength:     totalBeats,
                        phrasebars:    { ((p[\phraselength] ? 24) / totalBeats).max(1) },
                        stutterchance: { this.prVoiceDensity(voice, \stutterchance) },
                        stutterspeed:  { p[\stutterspeed] }
                    )
                }
            ),
            warp: (
                name: "WarpCutProc1",
                desc: "Aphex-style warp cutting: blocks are plain or rolls, often fast enough to sound pitched.",
                live: [\phraselength],
                params: [
                    // Phrase boundaries must land on the beat grid, so this is
                    // an integer; `slider` keeps it a (stepped) slider rather
                    // than the NumberBox ints normally get, because it is swept
                    // while listening rather than typed.
                    (key: \phraselength, label: "Phrase", lo: 2,   hi: 32,  default: 12,  int: true, slider: true,
                        hint: "Phrase length in beats before the next set of blocks is chosen."),
                    (key: \accel,        label: "Accel",  lo: 0.5, hi: 1.5, default: 0.9, int: false,
                        hint: "Roll shape: under 1 accelerates, over 1 decelerates. Rebuilds the cutter.")
                ],
                // accel is consumed raw (not .value'd) so it must be a number;
                // changing it rebuilds.
                build: { |voice, totalBeats| var p = voice[\params];
                    WarpCutProc1.new(phraselength: { p[\phraselength] }, accel: p[\accel])
                }
            ),
            choose: (
                name: "ChooseCutProc",
                desc: "Chosen cut sizes and repeats per phrase, with a roll allowed near the phrase end.",
                live: [\phraselength, \rollchance, \rollallowed],
                intensityKey: \rollchance,
                params: [
                    // Integer + stepped slider, as in WarpCutProc1 above.
                    (key: \phraselength, label: "Phrase",  lo: 2,   hi: 32, default: 16,  int: true, slider: true,
                        hint: "Phrase length in beats before new cut sizes are chosen."),
                    (key: \rollchance,   label: "RollPr",  lo: 0,   hi: 1,  default: 0.1, int: false,
                        hint: "Chance (0–1) of a roll near the end of each phrase."),
                    (key: \rollallowed,  label: "RollLen", lo: 0.5, hi: 8,  default: 2,   int: false,
                        hint: "Roll window: how many beats before the phrase end a roll may start.")
                ],
                build: { |voice, totalBeats| var p = voice[\params];
                    ChooseCutProc.new(
                        phraselength: { p[\phraselength] },
                        rollchance:   { this.prVoiceDensity(voice, \rollchance) },
                        rollallowed:  { p[\rollallowed] }
                    )
                }
            ),
            // No intensityKey for this one or for warp above, deliberately.
            // SQPusher1 takes `activity` as a plain value at build time (live is
            // empty), and WarpCutProc1 takes `accel` the same way, so driving
            // either from the pedal would respawn the voice on every CC message.
            // The arc still scales their LEVEL, which is the part that can move
            // without a rebuild.
            sqpusher: (
                name: "SQPusher1",
                desc: "Squarepusher-style: busy 4/4 bars with stored fills dropped in every few bars.",
                live: [],
                params: [
                    (key: \activity,     label: "Activity", lo: 0, hi: 1,  default: 0.1, int: false,
                        hint: "Chance of 16th- rather than 8th-note activity in normal bars."),
                    (key: \fillfreq,     label: "FillFreq", lo: 1, hi: 16, default: 4,   int: true,
                        hint: "A fill bar occurs every N bars."),
                    (key: \fillscramble, label: "FillScr",  lo: 0, hi: 1,  default: 0,   int: false,
                        hint: "Chance (0–1) that a fill is scrambled rather than played as stored.")
                ],
                build: { |voice, totalBeats| var p = voice[\params];
                    SQPusher1.new(
                        activity:     p[\activity],
                        fillfreq:     p[\fillfreq],
                        fillscramble: p[\fillscramble]
                    )
                }
            )
        );

        // Cut effects: simple on/off with musical defaults. Inserted between
        // the cut synth and the mixer in the CutGroup chain. `short` is the
        // inline legend under the buttons, `desc` the hover tooltip.
        bbcutFxOrder = [\bit, \comb, \bpf, \brf, \mod, \rev];
        bbcutFxSpecs = (
            bit:  (name: "Bit",  short: "8-bit crush",  desc: "Bitcrusher + sample-rate decimation, 8 bits.",
                build: { CutBit1.new(8) }),
            comb: (name: "Comb", short: "metallic ring", desc: "Comb filter, 12 ms delay / 0.4 s decay — metallic resonance.",
                build: { CutComb1.new(0.012, 0.4) }),
            bpf:  (name: "BPF",  short: "band-pass 1.2k", desc: "Band-pass filter at 1.2 kHz, rq 0.3 — thins the cuts.",
                build: { CutBPF1.new(1200, 0.3) }),
            brf:  (name: "BRF",  short: "notch 1.2k",   desc: "Band-reject notch at 1.2 kHz, rq 0.3 — hollows the cuts out.",
                build: { CutBRF1.new(1200, 0.3) }),
            mod:  (name: "Mod",  short: "ring mod",     desc: "Ring modulation at middle C (261.6 Hz), fully wet.",
                build: { CutMod1.new(1.0, 261.626) }),
            rev:  (name: "Rev",  short: "reverb",       desc: "Reverb on the cut slices (amount 0.4, send 0.4).",
                build: { CutRev1.new(0.4, 0.4) })
        );

        bbcutVoices = List[ this.defaultBBCutVoice ];
    }

    bbcutSynthKeys { ^[\cutbuf1, \cutbuf2, \cutbuf3] }

    // The procedure a new voice starts on, and what an unreadable one in a
    // preset falls back to: the house Break/Repeat proc, which leaves a loop
    // recognisable instead of chopping it continuously.
    defaultBBCutProc { ^\break }

    defaultParamsFor { |procSym|
        var spec = bbcutProcSpecs[procSym] ? bbcutProcSpecs[this.defaultBBCutProc];
        var p = ();
        spec[\params].do { |entry| p[entry[\key]] = entry[\default] };
        ^p
    }

    defaultBBCutVoice {
        ^(
            enabled: true,
            proc:    this.defaultBBCutProc,
            synth:   \cutbuf2,
            fx:      [],
            ratio:   1.0,
            amp:     1.0,
            pan:     0.0,
            params:  this.defaultParamsFor(this.defaultBBCutProc),
            // live server resources, set at spawn / cleared at free
            inst:    nil,   // BBCut2
            clock:   nil,   // ExternalClock
            mixer:   nil,   // CutMixer (for live amp/pan)
            respawnPending: false  // coalesces rapid structural changes
        )
    }

    bbcut_ { |flag|
        var want = flag.asBoolean;
        if(want == bbcut) { ^this };
        if(want) {
            this.enableBBCut;
        } {
            this.disableBBCut;
        };
    }

    // gateMode code passed to the engine SynthDef: 0 pass, 1 mute, 2 insert.
    bbcutGateCode {
        ^switch(bbcutMode, \gate, 1, \insert, 2, 0)
    }

    // True while the cutter should gate itself to the repetitions only — i.e.
    // in \insert mode, where the dry engine carries the straight material and
    // the cutter is heard only during rolls. In \mix / \gate the cutter runs full.
    bbcutInsertMode { ^(bbcutMode == \insert) }

    // Switch mix mode live (\mix / \insert / \gate). The engine picks up the
    // new duck/mute immediately; the cutter's own roll-gating is re-read per
    // block via the closures set at spawn, so no respawn is needed.
    bbcutMode_ { |mode|
        var want = mode.asSymbol;
        if([\mix, \insert, \gate].includes(want).not) { ^this };
        bbcutMode = want;
        if(bbcut) {
            engineSynth !? { |s| s.set(\gateMode, this.bbcutGateCode) };
        };
        this.changed(\bbcutMode, bbcutMode);
    }

    enableBBCut {
        var tau, totalBeats, loopDur, outBusIdx, path, baseBps;
        if(loopFrames == 0 or: { lastResult.isNil } or: { lastResult.tau.isNil }) {
            "BBCut: no analyzed loop available.".warn;
            ^this.prRefused(\bbcut, "the cutter needs an analysed take")
        };
        if(bbcutEnabling) { ^this };
        bbcutEnabling = true;

        tau = lastResult.tau;
        // Pulses-as-beats: the BBCut clock ticks once per detected pulse, and
        // beatlength = total pulses in the loop. For 7/8 (sub=1, k=1) that's
        // a 7-beat phrase; for 4/4 with eighth-note sub=2, an 8-beat phrase.
        totalBeats = MeterAnalyzer.unitsOf(lastResult) * lastResult.sub;
        loopDur = loopFrames / server.sampleRate;
        outBusIdx = outBus.index;
        baseBps = tau.reciprocal;
        // BBCutBuffer reads from a file, so the loop has to be written out
        // first. Platform.defaultTempDir rather than a hardcoded /tmp: it is the
        // same directory on macOS, but it is the one that is correct anywhere.
        path = (Platform.defaultTempDir ? "/tmp") +/+ "megalooper_bbcut.wav";
        // The cut synths play at clock.tempo / bps, and BBCutBuffer computes
        // bps from the file it is given (beats / duration). So the analysis has
        // to agree with the audio: loopDur == tau * totalBeats. If some path
        // resizes the loop without re-scaling the analysis, the ratio between
        // them IS the pitch error — 2.0 would cut an octave up — so name it
        // rather than let it come out as a mystery chipmunk.
        if((loopDur - (tau * totalBeats)).abs > (tau * 0.5)) {
            ("BBCut: loop is " ++ loopDur.round(0.01) ++ " s but the analysis says "
                ++ (tau * totalBeats).round(0.01) ++ " s (" ++ totalBeats
                ++ " beats x " ++ tau.round(0.001) ++ " s). Cuts will play "
                ++ (loopDur / (tau * totalBeats)).round(0.01)
                ++ "x too fast — re-record or re-analyze the loop.").warn;
        };

        bbcutEnableRoutine = Routine {
            var ready = Condition.new;
            var untilNextBoundary, sp, newBuffer, cutSpeed;
            // A cutter that cannot start (the loop cleared under it, a file
            // that would not write) leaves nothing half on: before, a throw
            // here kept bbcutEnabling true, and the cutter and half-time were
            // refused until the looper was built again.
            try {

                // The loop goes to disk and comes back BEFORE the wait, and running
                // voices — when this is a re-enable — keep playing until the
                // boundary; the swap below is then a teardown and a spawn in the
                // same instant. That is what lets a reading that changes the pulse
                // (prLandReading) put the new grid on the downbeat with no hole in
                // front of it. A first enable is unchanged: nothing was playing.
                buffer.write(path, "WAV", "int24", loopFrames, startFrame);
                server.sync;

                // eventlist=1 → cut start positions land on whole-beat (pulse)
                // boundaries inside the buffer, and CutBuf3 can use the analysis.
                // The fourth arg is an action closure fired once allocRead completes.
                newBuffer = BBCutBuffer(path, totalBeats, 1, { ready.unhang });
                ready.hang;

                // Phase-align to the next loop downbeat so cut beat 0 = loop
                // beat 0. `loopStartTime` is the wall time when the current
                // engineSynth was spawned — the true audio start, with no latency
                // adjustment (see spawnEngine; adding one is the 2026-09-07 bug). All
                // voices spawn right after this wait, so they share beat 0.
                // The next boundary, and the speed after it: at half-time
                // (rc600-picks.md, 3b) the end of a half-speed pass, and a landing
                // or an end of half-time armed for it, so the cutter comes in at
                // the speed the loop will play.
                cutSpeed = this.prSpeedAfterNext;
                untilNextBoundary = (this.prNextBoundaryAt(SystemClock.seconds) - SystemClock.seconds).max(0);
                untilNextBoundary.wait;

                this.teardownBBCut;
                bbcutBuffer = newBuffer;
                sp = this.bbcutSpawnParams(cutSpeed);
                bbcutVoices.do { |voice|
                    if(voice[\enabled]) {
                        this.spawnBBCutVoice(voice, sp);
                    };
                };

                engineSynth !? { |s| s.set(\gateMode, this.bbcutGateCode) };

                bbcut = true;
                bbcutEnabling = false;
                this.changed(\bbcut, true);
                ("BBCut on (" ++ totalBeats ++ " beats @ "
                    ++ baseBps.round(0.01) ++ " bps, "
                    ++ this.bbcutActiveVoiceCount ++ " voice(s)).").postln;
                bbcutEnableRoutine = nil;
            } { |err|
                bbcutEnabling = false;
                bbcutEnableRoutine = nil;
                err.reportError;
                this.prRefused(\bbcut, "the cutter could not start (" ++ err.errorString ++ ")");
            };
        }.play;
    }

    // Spawn params common to every voice this play, derived from the analysis.
    // `loopFrames`/`lastResult` are stable during playback. At half-time
    // (`cutSpeed` 0.5, the loop's speed by default) the cutter's clocks run at
    // half tempo, so its cuts play an octave down and twice as long, as the
    // loop does: `baseBps` scaled, `tau` a pulse in wall time.
    bbcutSpawnParams { |cutSpeed|
        var tau = lastResult.tau;
        cutSpeed = cutSpeed ? speed;
        ^(
            tau:        tau / cutSpeed,
            totalBeats: MeterAnalyzer.unitsOf(lastResult) * lastResult.sub,
            outBusIdx:  outBus.index,
            baseBps:    tau.reciprocal * cutSpeed
        )
    }

    bbcutActiveVoiceCount {
        ^bbcutVoices.count { |v| v[\inst].notNil }
    }

    // Build and start one voice, stashing its inst/clock/mixer on the voice.
    // numChannels=2 selects the stereo CutBuf/CutMixer SynthDef variants; the
    // mixer writes to our outBus so the master limiter still catches output.
    // The voice's ExternalClock is created once and REUSED across respawns
    // (its self-rescheduling tick is fragile to being stopped from another
    // thread); only its tempo is updated, so ratio changes take effect live.
    spawnBBCutVoice { |voice, sp|
        var spec   = bbcutProcSpecs[voice[\proc]] ? bbcutProcSpecs[\bbcut11];
        var synth  = this.bbcutBuildSynth(voice[\synth], bbcutBuffer);
        // The cutter carries the whole loop only in \gate; in \mix and \insert
        // the dry engine covers the straight material, so the cutter is heard
        // only during repetitions (rolls) — matching Ableton, where repetitions
        // are "added" (mix) or "inserted" (dry ducks) rather than replacing all.
        // `volume` (= voice amp) still tracks live edits via the mixer.
        var ampfunc = { |i, block|
            if(bbcutMode == \gate) { 1 } { if(block.cuts.size > 1) { 1 } { 0 } }
        };
        var mixer  = CutMixer(sp[\outBusIdx], voice[\amp] * this.prBBCutMix,
            ampfunc, voice[\pan]);
        // Drives the insert-duck bus (1 while a repetition plays). Emits no
        // audio; only active in \insert mode, so \mix / \gate are unaffected.
        var gate   = LooperCutGate(insertBus.index, { this.bbcutInsertMode });
        var fx     = (voice[\fx] ? []).collect { |k|
            var fs = bbcutFxSpecs[k]; fs !? { fs[\build].value }
        }.reject(_.isNil);
        var chain  = [gate, synth] ++ fx ++ [mixer];
        var group  = CutGroup(chain, nil, nil, 2);
        var tempo  = sp[\baseBps] * voice[\ratio];
        var clock  = voice[\clock];
        if(clock.isNil) {
            clock = ExternalClock(TempoClock(tempo));
            clock.play;
            voice[\clock] = clock;
        } {
            clock.tempo_(tempo);
        };
        voice[\mixer] = mixer;
        voice[\inst]  = BBCut2([group], spec[\build].value(voice, sp[\totalBeats])).play(clock);
    }

    // Free a voice's BBCut2 + its CutGroup (mixer), keeping the clock alive for
    // a respawn. BBCut2.stop sets alive=false (the clock drops it as a provider
    // at the next tick, before asking it for material), and BBCut2.free frees
    // its own CutGroup and bus — so we must NOT free the group ourselves.
    freeBBCutVoiceInst { |voice|
        voice[\inst] !? { |b| b.stop; b.free };
        voice[\inst]  = nil;
        voice[\mixer] = nil;
    }

    // Full free including the clock (teardown / remove voice / disable). Stop
    // the clock from within its OWN scheduling thread so its self-rescheduling
    // tick unschedules cleanly, instead of waking on a stopped clock (which
    // throws "clock is not running").
    freeBBCutVoice { |voice|
        var clock = voice[\clock];
        this.freeBBCutVoiceInst(voice);
        clock !? { |c|
            var tc = c.tempoclock;
            tc.sched(0, { tc.stop; nil });
        };
        voice[\clock] = nil;
    }

    bbcutBuildSynth { |sym, buf|
        ^switch(sym,
            \cutbuf1, { CutBuf1(buf) },
            \cutbuf2, { CutBuf2(buf) },
            \cutbuf3, { CutBuf3(buf) },
            { CutBuf2(buf) }
        )
    }

    disableBBCut {
        var wasOn = bbcut;
        this.teardownBBCut;
        engineSynth !? { |s| s.set(\gateMode, 0) };
        if(bbcut) {
            bbcut = false;
            this.changed(\bbcut, false);
        };
        if(wasOn) { "BBCut off.".postln };
    }

    teardownBBCut {
        bbcutVoices.do { |v| this.freeBBCutVoice(v) };
        bbcutBuffer !? { |b| b.free };
        bbcutBuffer = nil;
    }

    // A cutter starting (enableBBCut waiting for the boundary) taken back: a
    // stop, a clear, a new take, the looper freed. Before, a stop or a clear
    // during that wait was ignored (stopPlayback acted only if(bbcut)), and the
    // cutter came in over nothing.
    prCancelBBCutEnable {
        bbcutEnableRoutine = this.prStopRoutine(bbcutEnableRoutine);
        bbcutEnabling = false;
    }

    // Export the current loop to `dir` as a 24-bit WAV plus a JSON sidecar, for
    // building a labelled meter-analysis training set. `name`/`num`/`denom`/
    // `bars` are the user-supplied GROUND TRUTH: they are encoded in the
    // filename (name_sig_bars_bpm_time) and stored in the sidecar. The sidecar
    // also captures the exact onset data MeterAnalyzer.analyze saw (see
    // stopRecordStartPlay) plus the analyzer's own guess, so the analyzer can be
    // re-run and scored offline without the audio. bpm is DERIVED from the
    // ground-truth labels + measured loop length, not taken from the analyzer.
    // Analysis need NOT have succeeded — length-anchored / no-meter takes are the
    // most valuable to label. Mirrors the disk-write in enableBBCut; runs in a
    // Routine for server.sync.
    exportTrainingLoop { |dir, name, num, denom, bars|
        var sr, dur, bpm, safeName, stamp, base, wavPath, jsonPath;
        if(loopFrames == 0 or: { buffer.isNil }) {
            "Export: no loop to export.".warn;
            ^nil
        };
        num   = num.asInteger.max(1);
        denom = denom.asInteger.max(1);
        bars  = bars.asInteger.max(1);
        sr    = server.sampleRate;
        dur   = loopFrames / sr;
        // Ground-truth quarter-note BPM implied by the labels + measured length.
        bpm   = (bars * num * (4 / denom) / dur * 60).round.asInteger;

        // Sanitise the name to [A-Za-z0-9-] so '_' stays the field separator.
        safeName = String.new;
        name.asString.do { |ch|
            if(ch.isAlphaNum) {
                safeName = safeName ++ ch;
            } {
                if((ch == $ ) or: { ch == $_ } or: { ch == $- }) {
                    safeName = safeName ++ $-;
                };
            };
        };
        if(safeName.isEmpty) { safeName = "loop" };

        stamp = Date.getDate.stamp.replace("_", "-");
        base  = safeName ++ "_" ++ num ++ "-" ++ denom ++ "_"
            ++ bars ++ "bars_" ++ bpm ++ "bpm_" ++ stamp;
        wavPath  = dir +/+ base ++ ".wav";
        jsonPath = dir +/+ base ++ ".json";

        if(File.exists(dir).not) { File.mkdir(dir) };

        Routine {
            buffer.write(wavPath, "WAV", "int24", loopFrames, startFrame);
            server.sync;
            this.writeTrainingSidecar(jsonPath, name.asString,
                num, denom, bars, bpm, stamp);
            ("Exported training loop: " ++ base).postln;
            this.changed(\trainingExport, base);
        }.play(AppClock);
        ^base
    }

    // Write the JSON metadata companion to a training-loop WAV. Reconstructs the
    // exact analyzer inputs from the retained `onsets` (as stopRecordStartPlay
    // does at :269-270) so MeterAnalyzer.analyze(loopDur, onsets, strengths) can
    // be replayed verbatim; `detected` is the analyzer's guess (lastResult).
    writeTrainingSidecar { |path, name, num, denom, bars, bpm, stamp|
        var sr = server.sampleRate;
        var dur = loopFrames / sr;
        var firstOnset = if(onsets.isEmpty) { 0 } { onsets[0][0] };
        var relOnsets  = onsets.collect { |pair| pair[0] - firstOnset };
        var strengths  = onsets.collect { |pair| pair[1] };
        var rawPairs   = onsets.collect { |p| "[" ++ p[0] ++ ", " ++ p[1] ++ "]" };
        var fmtArr, jesc, det, jstr, file;

        fmtArr = { |arr| "[" ++ arr.collect({ |x| x.asString }).join(", ") ++ "]" };
        jesc   = { |s| MegaFiles.jsonString(s) };

        // The analyzer's guess at export time (may carry an \error symbol).
        det = if(lastResult.isNil) { "null" } {
            var errStr = if(lastResult.error.isNil)
                { "null" } { jesc.(lastResult.error) };
            "{ \"numerator\": " ++ (lastResult.numerator ? "null")
                ++ ", \"denominator\": " ++ (lastResult.denominator ? "null")
                ++ ", \"bpm\": " ++ (lastResult.bpm ? "null")
                ++ ", \"k\": " ++ (lastResult.k ? "null")
                ++ ", \"n\": " ++ (lastResult.n ? "null")
                ++ ", \"tau\": " ++ (lastResult.tau ? "null")
                ++ ", \"sub\": " ++ (lastResult.sub ? "null")
                ++ ", \"loopDur\": " ++ (lastResult.loopDur ? "null")
                ++ ", \"onsetCount\": " ++ (lastResult.onsetCount ? "null")
                ++ ", \"error\": " ++ errStr ++ " }";
        };

        jstr = "{\n"
            ++ "  \"name\": " ++ jesc.(name) ++ ",\n"
            ++ "  \"groundTruth\": { \"numerator\": " ++ num
                ++ ", \"denominator\": " ++ denom
                ++ ", \"bars\": " ++ bars
                ++ ", \"bpm\": " ++ bpm ++ " },\n"
            ++ "  \"loopDurSec\": " ++ dur ++ ",\n"
            ++ "  \"sampleRate\": " ++ sr ++ ",\n"
            ++ "  \"loopFrames\": " ++ loopFrames ++ ",\n"
            ++ "  \"firstOnsetSec\": " ++ firstOnset ++ ",\n"
            ++ "  \"analyzerInput\": { \"loopDur\": " ++ (loopDur - firstOnset)
                ++ ", \"onsets\": " ++ fmtArr.(relOnsets)
                ++ ", \"strengths\": " ++ fmtArr.(strengths) ++ " },\n"
            ++ "  \"rawOnsets\": " ++ fmtArr.(rawPairs) ++ ",\n"
            ++ "  \"detected\": " ++ det ++ ",\n"
            ++ "  \"exportedAt\": " ++ jesc.(stamp) ++ "\n"
            ++ "}\n";

        file = File(path, "w");
        if(file.isOpen) {
            file.write(jstr);
            file.close;
        } {
            ("Export: could not open " ++ path).warn;
        };
    }

    // Rebuild a single voice in place to pick up a structural change (proc /
    // synth / fx / ratio / non-live param) without disturbing the others.
    // Re-aligns to the next *beat* (≤ tau, not a whole loop) so the gap is a
    // splice rather than a long silence, and reuses the shared buffer (no disk
    // I/O). Coalesces rapid changes: while a respawn is pending, further calls
    // just mutate the config — the queued respawn reads the latest state.
    respawnBBCutVoice { |i|
        var voice = bbcutVoices[i];
        var sp;
        if(bbcut.not or: { bbcutBuffer.isNil } or: { voice.isNil }) { ^this };
        if(voice[\respawnPending] == true) { ^this };
        voice[\respawnPending] = true;
        sp = this.bbcutSpawnParams;
        Routine {
            var beatDur = sp[\tau];
            var elapsed = SystemClock.seconds - (this.passStart ? SystemClock.seconds);
            (beatDur - (elapsed % beatDur)).wait;
            voice[\respawnPending] = false;
            // Re-check after the wait: the voice may have been removed (preset
            // load, Remove button) or the cutter switched off meanwhile.
            // Without this we would build a clock + BBCut2 belonging to no
            // voice — unreachable by teardownBBCut and audible until recompile.
            // Collection:includes is an identity test, which is what we want:
            // two voices with identical settings are still two voices.
            if(bbcut and: { bbcutBuffer.notNil } and: { bbcutVoices.includes(voice) }) {
                // Keep the clock running — swap only the BBCut2 + its CutGroup.
                this.freeBBCutVoiceInst(voice);
                // A disabled voice frees and stays silent, so respawn is the one
                // uniform per-voice action: enable, disable, rebuild, first spawn.
                if(voice[\enabled] != false) { this.spawnBBCutVoice(voice, sp) };
            };
        }.play;
    }

    // ---- Voice management ----------------------------------------------

    bbcutVoiceCount { ^bbcutVoices.size }

    addBBCutVoice {
        var voice;
        if(bbcutVoices.size >= 4) {
            "BBCut: max 4 voices.".warn;
            ^this.prRefused(\bbcutVoices, "four voices at most")
        };
        voice = this.defaultBBCutVoice;
        bbcutVoices.add(voice);
        // Fade the new voice in on the next beat without touching the others.
        if(bbcut and: { bbcutBuffer.notNil }) {
            var sp = this.bbcutSpawnParams;
            Routine {
                var beatDur = sp[\tau];
                var elapsed = SystemClock.seconds - (this.passStart ? SystemClock.seconds);
                (beatDur - (elapsed % beatDur)).wait;
                this.spawnBBCutVoice(voice, sp);
            }.play;
        };
        this.changed(\bbcutVoices, bbcutVoices);
    }

    removeBBCutVoice { |i|
        if(bbcutVoices.size <= 1) {
            "BBCut: need at least one voice.".warn;
            ^this.prRefused(\bbcutVoices, "the cutter needs at least one voice")
        };
        if(i.notNil and: { i < bbcutVoices.size }) {
            // Free only this voice; the others keep playing uninterrupted.
            this.prRemoveBBCutVoiceAt(i);
            this.changed(\bbcutVoices, bbcutVoices);
        };
    }

    // Free + drop one voice, no guards and no notification: the shared body of
    // removeBBCutVoice and the preset loader (which reconciles counts in bulk
    // and notifies once at the end).
    prRemoveBBCutVoiceAt { |i|
        var voice = bbcutVoices[i];
        if(voice.isNil) { ^nil };
        this.freeBBCutVoice(voice);
        bbcutVoices.removeAt(i);
        ^voice
    }

    // ---- Per-voice structural setters (respawn that voice if running) ---

    setVoiceProc { |i, sym|
        var v = bbcutVoices[i];
        if(v.isNil or: { bbcutProcSpecs[sym].isNil }) { ^this };
        v[\proc] = sym;
        // Each proc has its own param set, so reset to that proc's defaults.
        v[\params] = this.defaultParamsFor(sym);
        this.respawnBBCutVoice(i);
        this.changed(\bbcutVoices, bbcutVoices);
    }

    setVoiceSynth { |i, sym|
        var v = bbcutVoices[i];
        if(v.isNil or: { this.bbcutSynthKeys.includes(sym).not }) { ^this };
        v[\synth] = sym;
        this.respawnBBCutVoice(i);
        this.changed(\bbcutVoices, bbcutVoices);
    }

    setVoiceFx { |i, symArray|
        var v = bbcutVoices[i];
        if(v.isNil) { ^this };
        v[\fx] = (symArray ? []).select { |k| bbcutFxSpecs[k].notNil };
        this.respawnBBCutVoice(i);
        this.changed(\bbcutVoices, bbcutVoices);
    }

    setVoiceRatio { |i, ratio|
        var v = bbcutVoices[i];
        if(v.isNil) { ^this };
        // Ratio sets the clock tempo, so it can only change by respawning.
        v[\ratio] = ratio.max(0.01);
        this.respawnBBCutVoice(i);
        this.changed(\bbcutVoices, bbcutVoices);
    }

    // ---- Per-voice live setters (no rebuild) ---------------------------

    setVoiceAmp { |i, amp|
        var v = bbcutVoices[i];
        if(v.isNil) { ^this };
        v[\amp] = amp.clip(0, 1);
        v[\mixer] !? { |m| m.volume_(v[\amp] * this.prBBCutMix) };
        this.changed(\bbcutVoices, bbcutVoices);
    }

    setVoicePan { |i, pan|
        var v = bbcutVoices[i];
        if(v.isNil) { ^this };
        v[\pan] = pan.clip(-1, 1);
        v[\mixer] !? { |m| m.panfunc_(v[\pan]) };
        this.changed(\bbcutVoices, bbcutVoices);
    }

    // Set a proc param on a voice. Live params (re-read via closures) take
    // effect at the next phrase with no respawn; others respawn that voice.
    setVoiceParam { |i, key, val|
        var v = bbcutVoices[i];
        var spec, entry;
        if(v.isNil) { ^this };
        spec = bbcutProcSpecs[v[\proc]] ? bbcutProcSpecs[\bbcut11];
        // Snap `int` params here rather than at each call site, so the GUI
        // widgets, a preset recall and the bbcut* setters below can't disagree.
        // A NumberBox hands back a Float even at step 1, so without this an
        // "integer" param stores 2.0 and BBCut does its arithmetic in floats.
        entry = (spec[\params] ? []).detect { |e| e[\key] == key };
        if(entry.notNil and: { entry[\int] == true }) {
            val = val.round.asInteger.clip(entry[\lo], entry[\hi]);
        };
        v[\params][key] = val;
        if((spec[\live] ? []).includes(key).not) { this.respawnBBCutVoice(i) };
        this.changed(\bbcutVoices, bbcutVoices);
    }

    // ---- Presets --------------------------------------------------------
    // A preset is the persistent half of the cutter: every voice's config plus
    // the mix mode. The runtime slots (inst / clock / mixer / respawnPending)
    // are server resources and are deliberately excluded — a preset describes
    // what to build, never what is currently built.
    //
    // On disk: one JSON file per preset (<slug>.json, "megalooper bbcut"),
    // nothing in it run (docs/dev/architecture.md 3.7; until 2026-11-08 an SC
    // literal, carried over once: Looper.migratePresets). Integers and Floats
    // survive the round trip; Symbols come back as Strings and the validator
    // makes them Symbols again, as it did for a hand-edited literal. Floats
    // store at ~14 digits, so a 2/3 ratio comes back as 0.66666666666667 —
    // inaudible, and the GUI's ratio menu selects by nearest match anyway.

    bbcutPresetVersion { ^1 }
    *bbcutPresetFormat { ^"megalooper bbcut" }

    // Plain Events / Arrays / Symbols / numbers only, as JSON holds them.
    bbcutPresetData { |name|
        ^(
            version: this.bbcutPresetVersion,
            name:    (name ? "").asString,
            savedAt: Date.getDate.stamp,
            mode:    bbcutMode,
            voices:  bbcutVoices.collect { |v| this.bbcutVoiceData(v) }.asArray
        )
    }

    bbcutVoiceData { |voice|
        ^(
            enabled: (voice[\enabled] != false),
            proc:    voice[\proc],
            synth:   voice[\synth],
            fx:      (voice[\fx] ? []).asArray.copy,
            ratio:   voice[\ratio].asFloat,
            amp:     voice[\amp].asFloat,
            pan:     voice[\pan].asFloat,
            params:  (voice[\params] ? ()).copy
        )
    }

    // The file's text: one field a line, a voice a line (MegaFiles.jsonText).
    bbcutPresetText { |data|
        ^MegaFiles.eventText(data, Looper.bbcutPresetFormat, Looper.prPresetFamilies[\bbcut][\order])
    }

    // Fail-soft by field, reject by file. A preset is user-editable text that
    // is more often STALE (saved before a proc gained a param) than corrupt, so
    // anything coercible to something musical is coerced, with one summary
    // warning. Only a file we cannot read as a preset at all is rejected — and
    // since this is a pure function returning a normalised copy, that rejection
    // happens before any model state is touched.
    prValidateBBCutPreset { |data, warnings|
        var voices, mode;
        if(data.isKindOf(Dictionary).not) {
            warnings.add("not a preset (expected an Event)");
            ^nil
        };
        if((data[\version] ? 1).asInteger > this.bbcutPresetVersion) {
            warnings.add("version " ++ data[\version] ++ " is newer than this build ("
                ++ this.bbcutPresetVersion ++ ")");
            ^nil
        };
        voices = data[\voices];
        // isString is tested separately because a String IS a Collection in
        // sclang: without it `voices: "x"` slips past this guard and the
        // .collect below throws PrimitiveFailedError from deep inside the voice
        // validator instead of rejecting the file. A hand-edited preset is the
        // realistic way in, and a validator whose whole job is to never throw
        // must not throw on one. See scripts/tests/test-bbcut-presets.scd.
        if(voices.isKindOf(Collection).not or: { voices.isString }
            or: { voices.isEmpty }) {
            warnings.add("no voices in preset");
            ^nil
        };
        voices = voices.asArray;
        if(voices.size > 4) {
            warnings.add("kept the first 4 of " ++ voices.size ++ " voices");
            voices = voices.keep(4);
        };
        mode = (data[\mode] ? bbcutMode).asSymbol;
        if([\mix, \insert, \gate].includes(mode).not) {
            warnings.add("unknown mode '" ++ mode ++ "', kept " ++ bbcutMode);
            mode = bbcutMode;
        };
        ^(
            version: this.bbcutPresetVersion,
            name:    (data[\name] ? "").asString,
            mode:    mode,
            voices:  voices.collect { |vd, i| this.prValidateBBCutVoiceData(vd, warnings, i) }
        )
    }

    prValidateBBCutVoiceData { |vd, warnings, idx|
        var proc, synth, fx, bad, spec, params;
        var tag = "voice " ++ (idx + 1) ++ ": ";
        // number-or-default with a range clip; nil, NaN and Strings all fall
        // back. Every correction is reported — a silently clamped value is how
        // a hand-edited preset ends up sounding wrong with no explanation.
        var num = { |val, key, default, lo, hi|
            var out;
            if(val.isNumber and: { val.isNaN.not }) {
                out = val.clip(lo, hi).asFloat;
                if(out != val) {
                    warnings.add(tag ++ key ++ " " ++ val ++ " -> " ++ out ++ " (range)");
                };
            } {
                if(val.notNil) { warnings.add(tag ++ key ++ " not a number -> " ++ default) };
                out = default;
            };
            out
        };
        if(vd.isKindOf(Dictionary).not) {
            warnings.add(tag ++ "not an Event, used defaults");
            ^this.bbcutVoiceData(this.defaultBBCutVoice)
        };
        proc = (vd[\proc] ? this.defaultBBCutProc).asSymbol;
        if(bbcutProcSpecs[proc].isNil) {
            warnings.add(tag ++ "unknown proc '" ++ proc ++ "' -> " ++ this.defaultBBCutProc);
            proc = this.defaultBBCutProc;
        };
        synth = (vd[\synth] ? \cutbuf2).asSymbol;
        if(this.bbcutSynthKeys.includes(synth).not) {
            warnings.add(tag ++ "unknown synth '" ++ synth ++ "' -> cutbuf2");
            synth = \cutbuf2;
        };
        fx  = (vd[\fx] ? []).asArray.collect(_.asSymbol);
        bad = fx.select { |k| bbcutFxSpecs[k].isNil };
        if(bad.notEmpty) { warnings.add(tag ++ "dropped fx " ++ bad.asCompileString) };
        fx  = fx.select { |k| bbcutFxSpecs[k].notNil };

        // Params are REBUILT from the (corrected) proc's spec rather than
        // trusted. That repairs stale files, drops params left over from
        // another proc, and — critically — guarantees the spec's build closure
        // never reads a nil, which would throw inside BBCut's own scheduling
        // thread and kill the voice with no visible cause. Clipping to [lo, hi]
        // is the only guard against a hand-typed `sdiv: 0`; the GUI clips at
        // the widget, so the model has never seen such values before.
        spec   = bbcutProcSpecs[proc];
        params = this.defaultParamsFor(proc);
        (vd[\params] ? ()).keysDo { |k|
            if(spec[\params].any { |e| e[\key] == k }.not) {
                warnings.add(tag ++ "dropped param '" ++ k ++ "' (not a " ++ proc ++ " param)");
            };
        };
        spec[\params].do { |entry|
            var val;
            var raw = (vd[\params] ? ())[entry[\key]];
            if(raw.isNumber.not or: { raw.isNaN }) {
                if(raw.notNil) { warnings.add(tag ++ entry[\key] ++ " not a number -> default") };
                val = entry[\default];
            } {
                val = raw.clip(entry[\lo], entry[\hi]);
                if(val != raw) {
                    warnings.add(tag ++ entry[\key] ++ " " ++ raw ++ " -> " ++ val ++ " (range)");
                };
            };
            params[entry[\key]] = if(entry[\int]) { val.round.asInteger } { val.asFloat };
        };
        ^(
            enabled: (vd[\enabled] != false),
            proc:    proc,
            synth:   synth,
            fx:      fx,
            // Clipped harder than setVoiceRatio (.max(0.01), no ceiling): that
            // setter's only caller is a menu topping out at 2:1, whereas a
            // hand-typed 100 here would run this voice's clock 100x.
            ratio:   num.(vd[\ratio], "ratio", 1.0,  0.01, 8.0),
            amp:     num.(vd[\amp],   "amp",   1.0,  0.0,  1.0),
            pan:     num.(vd[\pan],   "pan",   0.0, -1.0,  1.0),
            params:  params
        )
    }

    // Apply a preset to the live model: exactly one respawn per voice, exactly
    // one coarse notification, no teardown and no WAV rewrite. Safe with the
    // cutter off — respawnBBCutVoice returns immediately and the new config is
    // simply what enableBBCut will spawn next time.
    applyBBCutPreset { |data|
        var warnings = List.new;
        var clean    = this.prValidateBBCutPreset(data, warnings);
        if(clean.isNil) {
            ("BBCut preset rejected — " ++ warnings.join("; ")).warn;
            ^false
        };
        // Reconcile the voice count. Deliberately NOT addBBCutVoice: it spawns
        // the new voice itself, which would race the respawn below and leak a
        // BBCut2. The 1..4 limits are already enforced by the validator.
        while { bbcutVoices.size > clean[\voices].size } {
            this.prRemoveBBCutVoiceAt(bbcutVoices.size - 1);
        };
        while { bbcutVoices.size < clean[\voices].size } {
            bbcutVoices.add(this.defaultBBCutVoice);
        };
        // Mutate the EXISTING voice Events, never replace them: the GUI caches
        // `v = looper.bbcutVoices[i]` inside its control closures, and a
        // replacement would leave live widgets writing to a detached Event.
        clean[\voices].do { |vd, i| this.prWriteBBCutVoice(bbcutVoices[i], vd) };
        // Mode first (the spawn closures read it), then one respawn per voice;
        // voice[\respawnPending] already coalesces repeated calls.
        this.bbcutMode = clean[\mode];
        bbcutVoices.size.do { |i| this.respawnBBCutVoice(i) };
        this.changed(\bbcutVoices, bbcutVoices);  // MVC contract
        this.changed(\bbcutState, bbcutVoices);   // coarse: the GUI's rebuild hook
        if(warnings.notEmpty) {
            ("BBCut preset '" ++ clean[\name] ++ "': " ++ warnings.size
                ++ " correction(s) — " ++ warnings.join("; ")).warn;
        };
        ^true
    }

    // Copy one validated record into a live voice Event. Only persistent keys
    // are touched; inst / clock / mixer / respawnPending are left alone so a
    // running clock and any pending respawn survive the load.
    prWriteBBCutVoice { |voice, vd|
        voice[\enabled] = vd[\enabled];
        voice[\proc]    = vd[\proc];
        voice[\synth]   = vd[\synth];
        voice[\fx]      = vd[\fx].copy;     // never alias the preset record: the
        voice[\ratio]   = vd[\ratio];       // same data may be applied twice
        voice[\amp]     = vd[\amp];
        voice[\pan]     = vd[\pan];
        voice[\params]  = vd[\params].copy;
        // Amp/pan are the only fields that move without a rebuild. Push them
        // now (as setVoiceAmp/setVoicePan do) so the level is already right for
        // the beat before the splice instead of jumping at it.
        voice[\mixer] !? { |m| m.volume_(vd[\amp] * this.prBBCutMix); m.panfunc_(vd[\pan]) };
    }

    // ---- Preset files ---------------------------------------------------
    // `dir` is passed in rather than derived, for the same reason
    // exportTrainingLoop takes one: this class is compiled through a symlink in
    // Extensions, so its own file path cannot be walked back to the repo.

    // As exportTrainingLoop's sanitiser, minus its "_" restriction (there "_"
    // separates filename fields; here it does not), plus lowercasing so lookups
    // are deterministic on a case-insensitive volume.
    bbcutPresetSlug { |name| ^this.prPresetSlug(name) }

    prPresetSlug { |name| ^Looper.presetSlug(name) }

    // Class-side so a preset family outside the Looper (Megalooper SA's
    // effects, MegaSA) names its files by the same rule.
    *presetSlug { |name|
        var slug = String.new;
        name.asString.do { |ch|
            if(ch.isAlphaNum) {
                slug = slug ++ ch.toLower;
            } {
                if(slug.notEmpty and: { slug.last != $- }) { slug = slug ++ $- };
            };
        };
        while { slug.notEmpty and: { slug.last == $- } } {
            slug = slug.copyRange(0, slug.size - 2);
        };
        if(slug.isEmpty) { slug = "preset" };
        ^slug.keep(64)
    }

    // An SC literal file run the old way, on a Routine's own stack under try
    // (MegaFiles.runLiteral, which says why). No preset is read this way any
    // more: only your rigs (profiles.scd, code by design) and the files of
    // before the chains, carried over once.
    *readPresetFile { |path, why| ^MegaFiles.runLiteral(path, why) }

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
                format:  this.bbcutPresetFormat,
                what:    "megalooper BBCut preset",
                order:   #[\version, \name, \savedAt, \mode, \voices],
                version: \bbcutPresetVersion,
                data:    \bbcutPresetData,
                apply:   \applyBBCutPreset,
                summary: \prBBCutPresetSummary
            ),
            granular: (
                label:   "Granular",
                format:  this.granularPresetFormat,
                what:    "megalooper granular preset",
                order:   #[\version, \name, \savedAt, \env, \followChords]
                    ++ this.granularPresetFields.collect { |f| f[0] },
                version: \granularPresetVersion,
                data:    \granularPresetData,
                apply:   \applyGranularPreset,
                summary: \prGranularPresetSummary
            )
        )
    }

    // Slugs only, of the JSON files: an old .scd is not a preset any more
    // (migratePresets carries those over once), and a menu reads no file.
    presetNames { |dir|
        if(dir.isNil or: { File.exists(dir).not }) { ^[] };
        ^(dir +/+ "*.json").pathMatch
            .collect { |p| PathName(p).fileNameWithoutExtension }
            .sort
    }

    presetPath { |dir, name| ^dir +/+ this.prPresetSlug(name) ++ ".json" }

    prSavePreset { |family, dir, name|
        var f = Looper.prPresetFamilies[family];
        var slug, path, data, why;
        if(dir.isNil) { (f[\label] ++ " preset: no directory given.").warn; ^nil };
        slug = this.prPresetSlug(name);
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

    // One line each, for the save confirmation in the post window.
    prBBCutPresetSummary { |data|
        ^data[\voices].size.asString ++ " voice(s), " ++ data[\mode]
    }

    prGranularPresetSummary { |data|
        ^"morph " ++ data[\morph].round(0.01) ++ ", " ++ data[\env]
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

    // ===================================================================
    // Granular presets
    // ===================================================================
    // Same shape as the BBCut presets above, deliberately: one JSON file per
    // preset ("megalooper granular"), and `dir` passed in rather than derived
    // because this class is compiled through a symlink in Extensions.
    //
    // One table drives the file's field order, the validator's ranges and the
    // apply, so those three cannot drift apart — which is the failure mode a
    // hand-written serialiser has after the second parameter is added.
    // The ranges match the setters' own clips.
    *granularPresetFields {
        ^[
            // file key,  model accessor,     lo,    hi,   default
            [\morph,    \granularMorph,      0,     1,    0],
            [\amp,      \granularAmp,        0,     1,    0.3],
            [\pitch,    \granularPitch,    -48,    48,    0],
            [\detune,   \granularDetune,     0,    24,    0],
            [\size,     \granularSize,       0.01, 16,    1],
            [\density,  \granularDensity,    0.01, 16,    1],
            [\sizeRand, \granularSizeRand,   0,     1,    0.1],
            [\position, \granularPosition,   0,     1,    0],
            [\scan,     \granularScan,      -8,     8,    0],
            [\spray,    \granularSpray,      0,  2000,    0]
        ]
    }

    granularPresetVersion { ^1 }
    *granularPresetFormat { ^"megalooper granular" }

    granularPresetSlug  { |name| ^this.prPresetSlug(name) }
    granularPresetPath  { |dir, name| ^this.presetPath(dir, name) }
    granularPresetNames { |dir| ^this.presetNames(dir) }

    granularPresetData { |name|
        var data = (
            version: this.granularPresetVersion,
            name:    (name ? "").asString,
            savedAt: Date.getDate.stamp,
            // Stored by NAME, not by index. The index is a position in
            // granularEnvNames, so inserting a window shape would silently
            // re-point every preset saved before it at a different envelope.
            env:     Looper.granularEnvNames[granularEnv].asString,
            followChords: granularFollowChords
        );
        Looper.granularPresetFields.do { |f|
            data[f[0]] = this.perform(f[1]).asFloat;
        };
        ^data
    }

    // The file's text: one field a line (MegaFiles.jsonText).
    granularPresetText { |data|
        ^MegaFiles.eventText(data, Looper.granularPresetFormat, Looper.prPresetFamilies[\granular][\order])
    }

    // Fail-soft by field, reject by file — the same contract the BBCut
    // validator uses, and for the same reason: these files are hand-editable
    // and far more often STALE than corrupt. Pure, so a rejection happens
    // before any model state has been touched.
    prValidateGranularPreset { |data, warnings|
        var clean, envName, envIdx;
        if(data.isKindOf(Dictionary).not) {
            warnings.add("not a preset (expected an Event)");
            ^nil
        };
        if((data[\version] ? 1).asInteger > this.granularPresetVersion) {
            warnings.add("version " ++ data[\version] ++ " is newer than this build ("
                ++ this.granularPresetVersion ++ ")");
            ^nil
        };
        clean = (
            version: this.granularPresetVersion,
            name:    (data[\name] ? "").asString
        );
        Looper.granularPresetFields.do { |f|
            var key = f[0], lo = f[2], hi = f[3], default = f[4];
            var val = data[key];
            if(val.isNumber and: { val.isNaN.not }) {
                var out = val.clip(lo, hi).asFloat;
                if(out != val.asFloat) {
                    warnings.add(key.asString ++ " " ++ val ++ " -> " ++ out ++ " (range)");
                };
                clean[key] = out;
            } {
                // A missing field is the ordinary case for a preset saved by an
                // older build, so it is only worth a warning when something IS
                // there and is not a number.
                if(val.notNil) {
                    warnings.add(key.asString ++ " not a number -> " ++ default);
                };
                clean[key] = default.asFloat;
            };
        };
        // Resolve the window shape by name, case-insensitively; anything
        // unrecognised falls back to Warp1's own Hann rather than guessing.
        envName = (data[\env] ? "").asString;
        envIdx = Looper.granularEnvNames.detectIndex { |n|
            n.asString.toLower == envName.toLower
        };
        if(envIdx.isNil) {
            if(envName.isEmpty.not) {
                warnings.add("unknown window '" ++ envName ++ "' -> "
                    ++ Looper.granularEnvNames[0]);
            };
            envIdx = 0;
        };
        clean[\env] = envIdx;
        // Following the chords: true or false; a preset from before it had
        // none, and plays as it did then.
        clean[\followChords] = case
            { data[\followChords].isNil } { false }
            { (data[\followChords] == true) or: { data[\followChords] == false } } { data[\followChords] }
            { warnings.add("followChords " ++ data[\followChords].asCompileString ++ " is not true or false -> false"); false };
        ^clean
    }

    // Recall. Goes through the SETTERS, never the vars, so every change reaches
    // a running granular synth and fires its own notification — which is what
    // makes the window follow a recall without this method knowing a view exists.
    applyGranularPreset { |data|
        var warnings = List.new;
        var clean = this.prValidateGranularPreset(data, warnings);
        if(clean.isNil) {
            ("Granular preset rejected — " ++ warnings.join("; ")).warn;
            ^false
        };
        Looper.granularPresetFields.do { |f|
            this.perform(f[1].asSetter, clean[f[0]]);
        };
        this.granularEnv = clean[\env];
        this.granularFollowChords = clean[\followChords];
        if(warnings.notEmpty) {
            ("Granular preset '" ++ clean[\name] ++ "': " ++ warnings.size
                ++ " correction(s) — " ++ warnings.join("; ")).warn;
        };
        ^true
    }

    saveGranularPreset   { |dir, name| ^this.prSavePreset(\granular, dir, name) }
    loadGranularPreset   { |dir, name| ^this.prLoadPreset(\granular, dir, name) }
    deleteGranularPreset { |dir, name| ^this.prDeletePreset(\granular, dir, name) }

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
        overdubSyncRoutine !? { |r| r.stop };
        overdubSyncRoutine = nil;
        this.stopOverdubAnalysis;
        this.prCancelBBCutEnable;
        if(bbcut) { this.disableBBCut };
        engineSynth !? { |s| s.free };
        engineSynth = nil;
        granularSynth !? { |s| s.free; this.changed(\granular, false) };
        granularSynth = nil;
        clickRoutine !? { |r| r.stop };
        clickRoutine = nil;
        chordRoutine !? { |r| r.stop };
        chordRoutine = nil;
        this.stopOnsetNotes;
        // MIDI Clock and MIDI Stop travel together: only stop the clock when we also
        // send Stop, otherwise Live loses sync and turns off external sync.
        if(transportMode == \full) {
            midiClockRoutine !? { |r| r.stop };
            midiClockRoutine = nil;
            midiOut !? { |m| m.stop };
        };
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
        granularSynth !? { |s| s.set(\amp, granularAmp * this.prGranularMix) };
        bbcutVoices !? { |voices|
            voices.do { |v|
                v[\mixer] !? { |m| m.volume_(v[\amp] * this.prBBCutMix) };
            };
        };
    }

    // A density parameter as the CUTTER sees it, as opposed to as the GUI shows
    // it. The stored value is the value AT FULL INTENSITY; the pedal scales from
    // the parameter's own floor up to it. So heel is a cutter that is running
    // but barely chopping, and toe is exactly what was dialled in.
    //
    // Non-destructive by construction: nothing here writes to voice[\params], so
    // the Cutter pane's sliders and every saved preset keep the user's numbers.
    //
    // Only ever called from a build closure, which BBCut re-evaluates per block
    // — that is what makes the pedal take effect with no rebuild, and why only a
    // `live` parameter may be driven this way.
    prVoiceDensity { |voice, key|
        var spec   = bbcutProcSpecs[voice[\proc]];
        var entry  = spec !? { |sp| (sp[\params] ? []).detect { |e| e[\key] == key } };
        var floor  = (entry !? { |e| e[\lo] }) ? 0;
        var stored = voice[\params][key] ? floor;
        ^floor + ((stored - floor) * intensity)
    }

    // The density parameter of voice `i` as the cutter currently sees it, for
    // display beside the slider that shows the stored value. nil when the
    // voice's procedure has no parameter the arc can drive.
    voiceDensity { |i|
        var v   = bbcutVoices !? { |voices| voices[i] };
        var key = v !? { |vo| bbcutProcSpecs[vo[\proc]] !? { |sp| sp[\intensityKey] } };
        if(v.isNil or: { key.isNil }) { ^nil };
        ^this.prVoiceDensity(v, key)
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
        breakRoutine = this.prStopRoutine(breakRoutine);
        breakSeq = breakSeq + 1;
        seq = breakSeq;
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
            var dur = MeterDecision.breakDuration(phase, loopDur, n, reverseFlag, speed, this.prSpeedAfterNext);
            // A cancel or a re-fire in the meantime owns the gate now; this
            // callback belongs to a break that no longer exists.
            if((seq == breakSeq) and: { onBreak }) {
                breakEndsAt = SystemClock.seconds + dur;
                this.changed(\breakEndsAt, breakEndsAt);
                ("Break: " ++ dur.round(0.01) ++ " s, resuming on a loop downbeat.")
                    .postln;
                breakRoutine = Routine {
                    dur.wait;
                    this.endBreak;
                }.play(SystemClock);
            };
        };
        ^this
    }

    endBreak {
        // Via prStopRoutine, because the usual caller IS breakRoutine.
        breakRoutine = this.prStopRoutine(breakRoutine);
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
        breakRoutine = this.prStopRoutine(breakRoutine);
        breakEndsAt = nil;
        // Bumped so a phase callback still in flight cannot arm a resume for a
        // break that has just been cancelled.
        breakSeq = breakSeq + 1;
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
            after = if(((halfTimeAt ? inf) - at).abs < 1e-6) { this.prSpeedAfterNext } { speed };
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
        var seq;
        reverseRoutine = this.prStopRoutine(reverseRoutine);
        reverseSeq = reverseSeq + 1;
        seq = reverseSeq;
        reverseArmed = flag;
        reverseAt = if(flag) { at };
        if(flag) {
            reverseRoutine = Routine {
                (at - SystemClock.seconds).max(0).wait;
                this.prReverseLands(seq);
            }.play(SystemClock);
        };
        this.changed(\reverseArmed, reverseArmed);
    }

    // On the boundary, as the engine takes the direction.
    prReverseLands { |seq|
        if((seq != reverseSeq) or: { reverseArmed.not }) { ^this };
        reverseRoutine = nil;
        reverseArmed = false;
        reverseAt = nil;
        reverseFlag = reverseFlag.not;
        this.changed(\reverseArmed, false);
        this.prReverseSaid;
    }

    // The direction now, to the grains and whoever listens.
    prReverseSaid {
        granularSynth !? { |g| g.set(\rate, this.prGrainRate) };
        ("Reverse: " ++ reverseFlag).postln;
        this.changed(\reverse, reverseFlag);
    }

    // No reverse armed: a new engine starts in the direction now, a stop
    // has none to land on.
    prResetReverse {
        var was = reverseArmed;
        reverseRoutine = this.prStopRoutine(reverseRoutine);
        reverseSeq = reverseSeq + 1;
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
                { nextRecState != \idle } { "Rec next loop is on: overdub once the next loop is in" }
                { nil }
            },
            \multiply, {
                case
                { this.prAtHalfTime } { "half-time: end it first" }
                { (state == \empty) or: { state == \recording } or: { loopFrames == 0 } } { "no loop to multiply" }
                { nextRecState != \idle } { "Rec next loop is on" }
                { nil }
            },
            \halfTime, {
                case
                { state == \overdubbing } { "end the overdub first" }
                { (state != \playing) or: { this.loopDuration <= 0 } } { "half-time needs a loop playing" }
                { nextRecState != \idle } { "Rec next loop is on" }
                { bbcutEnabling } { "the cutter is starting" }
                { dissolving or: { dissolvePos > 0 } } { "a dissolve is on" }
                { nil }
            },
            { nil })
    }

    // The engine's speed, signed, as the grains scan by it.
    prGrainRate { ^(if(reverseFlag) { -1 } { 1 }) * speed }

    // How close to a boundary a press may come and still land on it. With the
    // cutter on it is respawned for the new speed, which writes the loop out
    // and reads it back first (enableBBCut): half a second.
    prHalfTimeMargin { ^if(bbcut) { 0.6 } { Looper.halfTimeMargin } }

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
        var seq;
        halfTimeRoutine = this.prStopRoutine(halfTimeRoutine);
        halfTimeSeq = halfTimeSeq + 1;
        seq = halfTimeSeq;
        halfTime = next;
        halfTimeAt = at;
        if(at.notNil) {
            halfTimeRoutine = Routine {
                // The cutter comes in again at the new speed on the boundary
                // (enableBBCut waits for it), as for a reading that changes
                // its pulse.
                ((at - 0.5) - SystemClock.seconds).max(0).wait;
                if((seq == halfTimeSeq) and: { bbcut } and: { bbcutEnabling.not }) { this.enableBBCut };
                (at - SystemClock.seconds).max(0).wait;
                this.prHalfTimeLands(seq);
            }.play(SystemClock);
        };
        this.changed(\halfTime, halfTime);
    }

    // On the boundary, as the engine takes the speed: half-time on, or over.
    // What keeps time with the loop follows: the onset kit and the chords.
    prHalfTimeLands { |seq|
        var at = halfTimeAt, landing = halfTime == \armed;
        if((seq != halfTimeSeq) or: { at.isNil }) { ^this };
        halfTimeRoutine = nil;
        speed = if(landing) { 0.5 } { 1 };
        passOrigin = if(landing) { at };
        speedChangedAt = at;
        halfTime = if(landing) { \on } { \off };
        halfTimeAt = nil;
        this.prLogEvent(\halfTime, (speed: speed, at: this.prLogTime(at)));
        ("Half-time " ++ (if(landing) { "on" } { "off" }) ++ ".").postln;
        this.changed(\halfTime, halfTime);
        this.changed(\speed, speed);
        this.startOnsetNotes;
        chordRoutine !? { this.startChordRoutine(lastResult) };
        // The grains scan as the loop moves, their pulse the loop's.
        granularSynth !? { |g|
            g.set(\rate, this.prGrainRate);
            lastResult !? { |r| r[\tau] !? { |t| g.set(\tau, t / speed) } };
        };
    }

    // Back to 1 at once, for a new engine (it plays at 1) and a stop.
    prResetHalfTime {
        var was = (halfTime != \off) or: { speed != 1 };
        halfTimeRoutine = this.prStopRoutine(halfTimeRoutine);
        halfTimeSeq = halfTimeSeq + 1;
        halfTimeSentAt = nil;
        if(was) {
            speed = 1;
            halfTime = \off;
            halfTimeAt = nil;
            passOrigin = nil;
            speedChangedAt = SystemClock.seconds;
            granularSynth !? { |g| g.set(\rate, this.prGrainRate) };
            this.changed(\halfTime, halfTime);
            this.changed(\speed, speed);
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
        var nextAt, period, ticksAtNext, ticksPerLoop, wait, restart, landAt, seq;
        if(result.isNil or: { loopSecs <= 0 }) { ^this };
        // Re-arming replaces: the reading after the pending one is what was
        // asked for, and two landings would fight over the clock.
        readingRoutine = this.prStopRoutine(readingRoutine);
        readingSeq = readingSeq + 1;
        seq = readingSeq;
        landingFrom = nil;
        // The next boundary, and the passes after it in wall time: at
        // half-time (armed, on or releasing) twice the loop's length.
        nextAt = this.prNextBoundaryAt(now);
        period = loopSecs / this.prSpeedAfterNext;
        // Where Live's tick count will stand at that boundary, if a Start has
        // gone out on a known boundary; otherwise every boundary is as good.
        if(clockRefTime.notNil and: { midiClockRoutine.notNil }) {
            ticksAtNext  = clockTicksAtRef + ((nextAt - clockRefTime) * clockTickRate);
            ticksPerLoop = period * clockTickRate;
        };
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
        readingRoutine = Routine {
            // A cutter respawn writes the loop out and reads it back before it
            // can wait for the boundary itself (enableBBCut): half a second
            // covers that. Otherwise the landing is the boundary.
            var lead = if(bbcut and: { MeterDecision.readingChangesCutter(lastResult, result) })
                { 0.5 } { 0.02 };
            ((landAt - lead) - SystemClock.seconds).max(0).wait;
            if(seq == readingSeq) { this.prLandReading(seq) };
        }.play(SystemClock);
        ^this
    }

    // Inside readingRoutine, a little before the boundary. The new result goes
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
        respawn = bbcut and: { MeterDecision.readingChangesCutter(lastResult, result) };
        landingFrom = lastResult;
        this.prSetResult(result);
        if(respawn) { this.enableBBCut };
        // Conditional, so a landing whose boundary has passed — which is how
        // the headless tests drive this — runs straight through without a yield.
        if(landAt > SystemClock.seconds) { (landAt - SystemClock.seconds).wait };
        if(seq != readingSeq) { ^this };   // cancelled or re-armed meanwhile
        readingIndex   = p[\index];
        pendingReading = nil;
        landingFrom    = nil;
        // The clock: a new period from this tick, and the tick reference moved
        // to this boundary so the next reading can find Live's bar line again.
        // When no boundary in reach could carry it, Start goes out again — the
        // relocation the first take does — unless a session recording is
        // running, when a Start would overwrite the take (see startTempoClocks)
        // and the bar line is left where it falls, tempo still right. Where a
        // Start relocates nothing (startsRelocate false: Megalooper SA), it
        // goes out regardless, and the drums' bar line stays on the loop's.
        if(midiClockRoutine.notNil and: { result[\bpm].notNil }) {
            if(clockRefTime.notNil) {
                clockTicksAtRef = clockTicksAtRef + ((landAt - clockRefTime) * clockTickRate);
                clockRefTime    = landAt;
            };
            clockPeriod   = 60 / (result[\bpm] * 24);
            clockTickRate = 1 / clockPeriod;
            if(p[\restart]) {
                if(startsRelocate and: { this.sessionRecording }) {
                    ("Reading landed; the set is being recorded, so no Start — "
                        "the transport's bar line may sit off the loop's.").postln;
                } {
                    midiOut !? { |m| m.start };
                    clockTicksAtRef = 0;
                    clockRefTime    = landAt;
                };
            };
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
        // Via prStopRoutine: this IS readingRoutine.
        readingRoutine = this.prStopRoutine(readingRoutine);
        this.changed(\reading, nil);
        this.changed(\readingIndex, readingIndex);
        this.prLogEvent(\readingLanded, (index: readingIndex, restart: p[\restart],
            reading: Looper.resultForLog(result)), landAt);
        ("Reading " ++ (readingIndex + 1) ++ "/" ++ this.readingCount ++ ": "
            ++ MeterDecision.readingString(result) ++ ".").postln;
        ^this
    }

    prCancelReading {
        readingRoutine = this.prStopRoutine(readingRoutine);
        // Bumped so a landing in flight belongs to a reading that no longer is.
        readingSeq = readingSeq + 1;
        landingFrom = nil;
        if(pendingReading.notNil) {
            this.prLogEvent(\readingCancelled, (index: pendingReading[\index]));
            pendingReading = nil;
            this.changed(\reading, nil);
        };
    }

    // Granular has no flag of its own — the layer exists exactly while its synth
    // does. Expose that as a proper query so views don't have to guess.
    granularOn { ^granularSynth.notNil }

    toggleGranular {
        var tau, args;
        if(granularSynth.notNil) {
            granularSynth.free; granularSynth = nil;
            "Granular off.".postln;
            this.changed(\granular, false);
            ^this
        };
        // Refused, so the layer is still off — say so anyway, or a view that
        // optimistically flipped its indicator on the keypress stays wrong.
        if(loopFrames == 0) {
            "Granular: no loop recorded.".postln;
            this.changed(\granular, false);
            ^this.prRefused(\granular, "no loop recorded")
        };
        tau = this.prGranularTau;
        args = [
            \bufnum, buffer.bufnum,
            \out, outBus.index,
            \startFrame, startFrame,
            \loopFrames, loopFrames,
            \tau, tau,
            // The pulsed scan follows the ENGINE's read position (see the
            // \looperGranular graph). It therefore goes AFTER the engine in the
            // node order, to read this block's position rather than the last
            // one's, and that is still before the master, which reads the bus
            // this writes. Over a stopped loop there is no engine to follow:
            // the layer goes at the head and scans freely until spawnEngine
            // locks it.
            \phaseBus, phaseBus.index,
            \locked, engineSynth.notNil.asInteger,
            \rate, this.prGrainRate
        ] ++ this.prGranularArgs ++ this.prGranularChordArgs.flatten(1);
        granularSynth = engineSynth !? { |e| Synth.after(e, \looperGranular, args) }
            ?? { Synth(\looperGranular, args, server) };
        ("Granular on. tau=" ++ tau.round(0.001)
            ++ " morph=" ++ granularMorph.round(0.01)
            ++ (if(engineSynth.notNil) { ", locked to the loop" } { ", free (loop stopped)" })
            ).postln;
        this.changed(\granular, true);
    }

    // The pulse the grains play at morph 1: the reading's, or a quarter of
    // the loop where there is none. At half-time a pulse lasts twice as long:
    // the pulsed grains too.
    prGranularTau {
        var tau = if(lastResult.notNil and: { lastResult.tau.notNil }) { lastResult.tau } {
            loopFrames / server.sampleRate / 4
        };
        ^tau / speed
    }

    // The grains read what the engine reads. Their synth is given the buffer,
    // its start, the loop's length and the pulse when spawned; every change of
    // those that spawns no grains synth sends them here: Record next loop's
    // swap of the two buffers (spawnEngine), multiply, undo, a take's
    // analysis, an overdub's and a reading's landing. Without it the grains
    // went on reading the old loop after a swap, in the buffer the next
    // capture then recorded into (roadmap item 20, found on the way).
    prGranularFollow {
        var chords;
        granularSynth !? { |g|
            chords = this.prGranularChordArgs;
            g.set(*([\startFrame, startFrame, \loopFrames, loopFrames, \tau, this.prGranularTau]
                ++ (buffer !? { |b| [\bufnum, b.bufnum] } ? []) ++ chords[0]));
            g.setn(*chords[1]);
        };
    }

    // The take's chords for the grains (granularFollowChords): [the switch
    // and the length the segments cover, as set pairs; their starts and
    // roots, as setn pairs of chordSlots values]. Unused starts lie past any
    // time. A take of fewer than two chords has none to follow (period 0).
    prGranularChordArgs {
        var segs = (lastResult !? { |r| r[\chordSegments] }) ? [];
        var period = if(segs.size < 2) { 0 } { (lastResult[\chordPeriod] ?? { lastResult[\loopDur] }) ? 0 };
        var starts = Array.fill(LooperSynthDefs.chordSlots, 1e9), roots = Array.fill(LooperSynthDefs.chordSlots, 0);
        segs.keep(LooperSynthDefs.chordSlots).do { |seg, i| starts[i] = seg[\start] ? 0; roots[i] = seg[\root] ? 0 };
        ^[[\follow, granularFollowChords.binaryValue, \chordPeriod, period], [\chordStarts, starts, \chordRoots, roots]]
    }

    // The grains with the chords (true) or as the loop sounds where they read
    // (false, as they always were).
    granularFollowChords_ { |flag|
        granularFollowChords = flag == true;
        granularSynth !? { |g| g.set(\follow, granularFollowChords.binaryValue) };
        this.changed(\granularFollowChords, granularFollowChords);
    }

    // The whole granular control set as synth args, in ONE place, so a fresh
    // synth always starts from what the sliders currently say — toggling the
    // layer off and on cannot quietly reset it to defaults.
    prGranularArgs {
        ^[
            \morph,    granularMorph,   \amp,      granularAmp * this.prGranularMix,
            \pitch,    granularPitch,   \detune,   granularDetune,
            \size,     granularSize,    \density,  granularDensity,
            \sizeRand, granularSizeRand, \position, granularPosition,
            \scan,     granularScan,    \sprayMs,  granularSpray,
            \envbuf,   this.prGranularEnvBuf
        ]
    }

    // Menu index 0 means Warp1's built-in Hann, which is the -1 sentinel rather
    // than a buffer. Falls back to it if the window buffers are not allocated
    // yet (a granular toggle racing construction).
    prGranularEnvBuf {
        var buf = granularEnvBufs !? { |a| a[granularEnv - 1] };
        ^if(granularEnv > 0 and: { buf.notNil }) { buf.bufnum } { -1 }
    }

    // Every granular setter does the same three things, and doing them by hand
    // ten times is ten chances to forget the notification and desync a view.
    prSetGranular { |key, val, notification|
        granularSynth !? { |syn| syn.set(key, val) };
        this.changed(notification, val);
    }

    // All settable parameters notify dependents via `this.changed(\key, val)`.
    // GUI and external surfaces subscribe with SimpleController(this).put(\key, fn)
    // and stay in sync regardless of where the change originated.

    // Rhythm/drone meta-control: sets the base every parameter below bends.
    granularMorph_ { |val|
        granularMorph = val.clip(0, 1);
        this.prSetGranular(\morph, granularMorph, \granularMorph);
    }

    // Level of the granular layer against the engine, pre-limiter.
    // The stored level, which is what the GUI shows. What reaches the synth is
    // this times the arc's granular multiplier, so the slider keeps meaning
    // "the level at full intensity" rather than drifting under the pedal.
    granularAmp_ { |val|
        granularAmp = val.clip(0, 1);
        this.prApplyMixes;
        this.changed(\granularAmp, granularAmp);
    }

    // Grain transposition in semitones. The pointer is unaffected, so this
    // pitches the layer without changing how fast it reads the loop.
    granularPitch_ { |val|
        granularPitch = val.clip(-48, 48);
        this.prSetGranular(\pitch, granularPitch, \granularPitch);
    }

    // Random detune applied afresh to each grain, +/- this many semitones.
    // Small values thicken (chorus); large ones shatter the loop into confetti.
    granularDetune_ { |val|
        granularDetune = val.clip(0, 24);
        this.prSetGranular(\detune, granularDetune, \granularDetune);
    }

    // Grain length as a multiple of what morph asks for. Below ~0.2 the grains
    // stop carrying pitch and start reading as texture.
    granularSize_ { |val|
        granularSize = val.clip(0.01, 16);
        this.prSetGranular(\size, granularSize, \granularSize);
    }

    // Overlap count as a multiple of morph's. Thickness — and the CPU bill.
    granularDensity_ { |val|
        granularDensity = val.clip(0.01, 16);
        this.prSetGranular(\density, granularDensity, \granularDensity);
    }

    // Warp1's windowRandRatio: how much grain LENGTH varies grain to grain.
    // A little breaks up the comb filtering of perfectly regular overlaps.
    granularSizeRand_ { |val|
        granularSizeRand = val.clip(0, 1);
        this.prSetGranular(\sizeRand, granularSizeRand, \granularSizeRand);
    }

    // Where in the loop the grains read from, 0..1 of the loop region. At the
    // drone end (no scan) this IS the freeze point — sweep it to move the drone
    // through the recording by hand.
    granularPosition_ { |val|
        granularPosition = val.clip(0, 1);
        this.prSetGranular(\position, granularPosition, \granularPosition);
    }

    // EXTRA passes through the loop per loop duration, added to morph's own.
    // 0 leaves morph in charge; small values drift a drone; negative runs the
    // read head backwards; -1 exactly cancels a fully pulsed scan.
    granularScan_ { |val|
        granularScan = val.clip(-8, 8);
        this.prSetGranular(\scan, granularScan, \granularScan);
    }

    // Absolute per-grain position randomness in ms. Unlike morph's own jitter
    // this survives at the pulsed end, which is how you loosen a locked grid.
    granularSpray_ { |val|
        granularSpray = val.clip(0, 2000);
        this.prSetGranular(\sprayMs, granularSpray, \granularSpray);
    }

    // Read once when the routine is built, so it takes a restart — and a restart
    // re-aligns from loopStartTime, which means the new offset lands on the very
    // next hit instead of at the next loop boundary. Dial it while playing.
    onsetNoteOffsetMs_ { |val|
        onsetNoteOffsetMs = val.clip(-500, 500);
        this.startOnsetNotes;
        this.changed(\onsetNoteOffsetMs, onsetNoteOffsetMs);
    }

    // Grain window shape — index into Looper.granularEnvNames.
    granularEnv_ { |val|
        granularEnv = val.asInteger.clip(0, Looper.granularEnvNames.size - 1);
        granularSynth !? { |syn| syn.set(\envbuf, this.prGranularEnvBuf) };
        this.changed(\granularEnv, granularEnv);
    }

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
    //      `midiClockRoutine` running until session shutdown — no
    //      `stopPlayback` in \full mode will ever come to clean it up. If this
    //      matters, gate cleanup inside `transportMode_`: on entering \off,
    //      send `midiOut.stop` and free `midiClockRoutine` so Live disengages
    //      cleanly instead of panicking on lost clock.
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

    // Whether the MIDI clock is going out to Live: the window holds back what
    // would stall the language (its theme's rebuild) while it does.
    midiClockRunning { ^midiClockRoutine.notNil }

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
        onsetNotePattern    = undoState.onsetNotePattern;
        onsetNotePatternDur = undoState.onsetNotePatternDur;
        onsetNoteRolls      = undoState.onsetNoteRolls;
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

    snapshotForUndo {
        buffer.copyData(undoBuffer);
        undoState = (
            startFrame: startFrame,
            loopFrames: loopFrames,
            lastResult: lastResult,
            // The reading cycle belongs to the analysis being snapshotted: undo
            // must bring back the list the undone take can cycle through, and
            // which reading it was on.
            analysedResult: analysedResult,
            readingIndex: readingIndex,
            state: state,
            // The replay pattern belongs to the buffer contents being snapshotted
            // here; without it, undo restores the audio and leaves the previous
            // take's rhythm playing over it.
            onsetNotePattern: onsetNotePattern,
            onsetNotePatternDur: onsetNotePatternDur,
            // The draws index into that pattern, so they are part of it: without
            // them undo would restore the old rhythm and thin it by the new
            // take's dice. onsetNoteChance is NOT here — it is a live control
            // like the velocity range, not a property of the take.
            onsetNoteRolls: onsetNoteRolls
        );
    }

    startTempoClocks { |result|
        if(metronome and: { result.tau.notNil }) {
            this.startClick(result.tau, MeterDecision.clickBars(result));
        };
        if(midiOut.notNil and: { result.bpm.notNil }) {
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
            if(startsRelocate and: { this.sessionRecording } and: { midiClockRoutine.notNil }) {
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
                    ((nextStart - seg[\start]) / speed).wait;
                };
            };
        }.play(SystemClock);
    }

    // ===================================================================
    // Onset notes — the loop's rhythm as MIDI
    // ===================================================================
    // The onsets MeterAnalyzer fits its grid to are also, straightforwardly, a
    // drum part: they are exactly where the attacks were. Replaying them out of
    // midiOut every loop pass lets Live trigger a drum rack or sampler from what
    // was actually played, in phase with the audio and the MIDI clock it is
    // already following.
    //
    // Deliberately a STORED pattern rather than a live trigger off the detector.
    // A live trigger stops the moment you stop playing and carries the detector's
    // ~15-25 ms latency; the loop's pattern repeats forever, dead in time, and
    // costs nothing while it runs.

    onsetNoteCount { ^onsetNotePattern !? { |p| p.size } ? 0 }

    prClearOnsetPattern {
        onsetNotePattern = nil;
        onsetNotePatternDur = nil;
        onsetNoteRolls = nil;
        this.stopOnsetNotes;
        this.changed(\onsetNotePattern, 0);
    }

    // Build the replay pattern from [time, strength] pairs measured from the
    // LOOP's start. Strength is normalised against the loudest hit in the take
    // rather than kept absolute: an absolute mapping would need recalibrating
    // every time the interface gain moved, and the musical information here is
    // which hits were loud RELATIVE to the others.
    prBuildOnsetPattern { |pairs, patternDur|
        var kept, peak;
        onsetNotePattern = nil;
        onsetNotePatternDur = nil;
        onsetNoteRolls = nil;
        if(pairs.isNil or: { patternDur.isNil } or: { patternDur <= 0 }) {
            this.changed(\onsetNotePattern, 0);
            ^this
        };
        // Onsets past the end are outside the loop: the analysis snaps the take
        // to whole bars and that can cut the tail off what was played.
        kept = pairs.asArray.select { |p| p[0] >= 0 and: { p[0] < patternDur } };
        peak = if(kept.isEmpty) { 0 } { kept.collect { |p| p[1] }.maxItem };
        if(kept.isEmpty or: { peak <= 0 }) {
            this.changed(\onsetNotePattern, 0);
            ^this
        };
        onsetNotePattern = kept
            .collect { |p| [p[0], (p[1] / peak).clip(0, 1)] }
            .sort { |a, b| a[0] < b[0] };
        onsetNotePatternDur = patternDur;
        // A new take is a new roll: the draws belong to this pattern and mean
        // nothing against the previous one, which had a different length.
        onsetNoteRolls = Array.fill(onsetNotePattern.size) { 1.0.rand };
        this.changed(\onsetNotePattern, onsetNotePattern.size);
    }

    // Does hit `i` sound at the current chance? One place, because the replay
    // routine and the readout must never disagree about which hits play.
    //
    // A missing draw reads as 0, so it sounds at any chance above 0: the pattern
    // was assembled from outside (the headless fixtures do exactly that) and
    // silence would be the wrong guess. The comparison is strictly `<`, which is
    // what makes the two ends exact — a draw is in [0, 1), so chance 1 sends
    // every hit and chance 0 sends none.
    prOnsetPlays { |i|
        ^(((onsetNoteRolls !? { |r| r.at(i) }) ? 0) < onsetNoteChance)
    }

    // How many of the pattern's hits the current chance actually sends. The
    // panel shows this beside the total: "12 hits" over a part playing four of
    // them is the one claim a thinned pattern must not still make.
    onsetNotePlayingCount {
        var n = 0;
        onsetNotePattern !? { |p|
            p.size.do { |i| if(this.prOnsetPlays(i)) { n = n + 1 } };
        };
        ^n
    }

    // Throw the dice again: the same hits at the same chance, a different subset
    // of them. Deliberately a button rather than something that happens every
    // pass — see onsetNoteRolls for why.
    rerollOnsetNotes {
        onsetNotePattern !? { |p|
            onsetNoteRolls = Array.fill(p.size) { 1.0.rand };
        };
        this.changed(\onsetNoteChance, onsetNoteChance);
    }

    // Strength ratio (0..1 against the take's loudest hit) -> MIDI velocity.
    // Evaluated per note at SEND time, which is why the velocity controls take
    // effect live without rebuilding the pattern or restarting the routine.
    prOnsetVelocity { |ratio|
        var db   = ratio.max(1e-5).ampdb;                       // <= 0
        var norm = ((db + onsetNoteDynRange) / onsetNoteDynRange).clip(0, 1);
        ^(onsetNoteVelLo + ((onsetNoteVelHi - onsetNoteVelLo) * norm))
            .round.asInteger.clip(1, 127)
    }

    // The two above under public names, for an onsetNoteSink: it decides each
    // hit itself and must agree with the routine about which hits play and
    // how loud.
    onsetPlays { |i| ^this.prOnsetPlays(i) }
    onsetVelocity { |ratio| ^this.prOnsetVelocity(ratio) }

    startOnsetNotes {
        var pattern = onsetNotePattern;
        var period  = onsetNotePatternDur;
        var ok;
        // At half-time the part is the loop's at its speed: every hit and the
        // pass twice as long, counted from where the pass began (passStart).
        // Kept, so a restart onto the same grid (a break's end) is one.
        if((speed != 1) and: { pattern.notNil } and: { period.notNil }) {
            if(halfOnsets.isNil or: { halfOnsets[0] !== onsetNotePattern } or: { halfOnsets[3] != speed }) {
                halfOnsets = [onsetNotePattern, onsetNotePattern.collect { |h| h.copy.put(0, h[0] / speed) },
                    period / speed, speed];
            };
            pattern = halfOnsets[1];
            period = halfOnsets[2];
        };
        // `engineSynth.isNil` is the honest test for "the loop's audio is
        // playing": stopPlayback and clear both nil it, and it is already set by
        // the time spawnEngine calls this. Gating on it is what stops the toggle
        // from firing a drum part into Live over a stopped looper — and it lets
        // this stay a single call from spawnEngine rather than one after every
        // prSetState(\playing) in the file.
        ok = (engineSynth.isNil or: { onsetNotes.not }
            or: { pattern.isNil } or: { pattern.isEmpty }
            or: { period.isNil } or: { period <= 0 }).not;
        // A sink takes the part over before the stop below: stopOnsetNotes
        // would tell it to stop, and every restart point would then cut and
        // re-send what it had already scheduled. It is handed the same guard,
        // minus a MIDI port it does not need, and keeps its own part where
        // nothing changed. A routine started before the sink was attached is
        // stopped, so the part never plays twice.
        if(onsetNoteSink.notNil) {
            this.prStopOnsetMidi;
            ^if(ok) { onsetNoteSink.startOnsets(this, pattern, period) }
                { onsetNoteSink.stopOnsets(this) }
        };
        this.stopOnsetNotes;
        if(ok.not or: { midiOut.isNil }) { ^this };
        onsetNoteRoutine = Routine {
            // Phase-align to the AUDIO. This is started more than once per take —
            // by spawnEngine before the analysis exists, then again by
            // startTempoClocks once it does — so it has to pick up MID-PASS from
            // wherever the loop currently is. Idling until the next boundary
            // instead would send the first pass after every recording out silent.
            // Subtracting the trim moves the pattern's read point FORWARD, so a
            // negative offset makes every hit fire that much earlier.
            var cursor = (SystemClock.seconds
                - (this.passStart ? SystemClock.seconds)
                - (onsetNoteOffsetMs / 1000)).mod(period);
            var from = pattern.detectIndex { |p| p[0] >= cursor } ? pattern.size;
            inf.do {
                pattern.size.do { |i|
                    // `from` skips the hits this pass has already gone past. A
                    // (from..size-1) range would count DOWNWARDS when from ==
                    // size, replaying the pass backwards.
                    if(i >= from) {
                        var hit  = pattern[i];
                        var next = if(i + 1 < pattern.size) { pattern[i + 1][0] } { period };
                        // Never let a gate run into the next hit: two noteOns
                        // before the noteOff and Live holds the first one.
                        // Measured against the next hit in the PATTERN, not the
                        // next one that sounds, so muting a neighbour never
                        // changes how long a note is held.
                        var gate = (onsetNoteGateMs / 1000).min((next - hit[0]) * 0.5);
                        // Latched, so changing note or channel mid-gate cannot
                        // release a different note than the one that was struck.
                        var chan = onsetNoteChannel, note = onsetNote;
                        // prOnsetPlays reads the draw and the chance LIVE rather
                        // than off the snapshot above, so moving the slider or
                        // re-rolling lands on the next hit without restarting the
                        // routine and losing its phase against the audio.
                        //
                        // A skipped hit costs nothing and leaves `cursor` where
                        // it was: the next one that sounds still waits out its
                        // own distance from the last note actually sent.
                        if(this.prOnsetPlays(i)) {
                            (hit[0] - cursor).max(0).wait;
                            onsetNoteSounding = [chan, note];
                            midiOut.noteOn(chan, note, this.prOnsetVelocity(hit[1]));
                            gate.wait;
                            midiOut.noteOff(chan, note, 0);
                            onsetNoteSounding = nil;
                            cursor = hit[0] + gate;
                        };
                    };
                };
                (period - cursor).max(0).wait;
                cursor = 0;
                from = 0;
            };
        }.play(SystemClock);
    }

    stopOnsetNotes {
        // Every stop point here (the break, stopPlayback, clearing the
        // pattern, the switch, free) stops a sink's part too.
        onsetNoteSink !? { |k| k.stopOnsets(this) };
        this.prStopOnsetMidi;
    }

    // The MIDI routine's half of a stop.
    prStopOnsetMidi {
        onsetNoteRoutine !? { |r| r.stop };
        onsetNoteRoutine = nil;
        // Stopping between noteOn and noteOff leaves the note stuck on in Live,
        // and nothing else will ever come along to clear it.
        onsetNoteSounding !? { |pair|
            midiOut !? { |m| m.noteOff(pair[0], pair[1], 0) };
        };
        onsetNoteSounding = nil;
    }

    // ---- Settable controls -------------------------------------------------
    onsetNotes_ { |flag|
        onsetNotes = flag;
        if(flag) { this.startOnsetNotes } { this.stopOnsetNotes };
        this.changed(\onsetNotes, onsetNotes);
    }

    // Note and channel are read per hit inside the routine, so these need no
    // restart — but they still notify, or a view that did not originate the
    // change never learns about it.
    onsetNote_ { |val|
        onsetNote = val.asInteger.clip(0, 127);
        this.changed(\onsetNote, onsetNote);
    }

    onsetNoteChannel_ { |val|
        onsetNoteChannel = val.asInteger.clip(0, 15);
        this.changed(\onsetNoteChannel, onsetNoteChannel);
    }

    onsetNoteVelLo_ { |val|
        onsetNoteVelLo = val.asInteger.clip(1, 127);
        this.changed(\onsetNoteVelLo, onsetNoteVelLo);
    }

    onsetNoteVelHi_ { |val|
        onsetNoteVelHi = val.asInteger.clip(1, 127);
        this.changed(\onsetNoteVelHi, onsetNoteVelHi);
    }

    onsetNoteDynRange_ { |val|
        onsetNoteDynRange = val.clip(1, 90);
        this.changed(\onsetNoteDynRange, onsetNoteDynRange);
    }

    onsetNoteGateMs_ { |val|
        onsetNoteGateMs = val.clip(1, 1000);
        this.changed(\onsetNoteGateMs, onsetNoteGateMs);
    }

    // Read live per hit inside the replay routine, like note and channel, so
    // this needs no restart: the part thins or fills from the next hit on.
    onsetNoteChance_ { |val|
        onsetNoteChance = val.clip(0, 1);
        this.changed(\onsetNoteChance, onsetNoteChance);
    }

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

    // Live only locks its external tempo once a stream of MIDI Clock pulses is
    // flowing, so we must NOT send Start cold: a cold Start makes Live begin at
    // its last/default tempo and only catch up over the first bar. So: stream
    // clock pulses immediately to lock the tempo, then send Start on the next
    // `alignDur` boundary (>= one beat of pre-roll away) so Live's 1.1.1 lands
    // where we want it. Callers pass the LOOP period, not a bar: any repetition
    // will do, but never mid-take. The wait is therefore up to one full loop —
    // that is the point, and the clock stream keeps Live's tempo locked while it
    // lasts. startAt is nudged earlier by midiOut.latency (so the Start is
    // RECEIVED on the boundary) and by abletonSyncMs (the Live-sync offset:
    // negative pulls Live earlier to cancel its ~10-20 ms follower lag).
    startMidiClock { |bpm, alignDur|
        var syncOff = abletonSyncMs / 1000;
        if(transportMode == \off) { ^this };
        midiClockRoutine !? { |r| r.stop };
        clockNudge  = 0;
        clockPeriod = 60 / (bpm * 24);
        // No Start has gone out on this stream yet, so no boundary is known to
        // carry Live's bar line; a reading armed before it does lands on the
        // next boundary regardless.
        clockTicksAtRef = nil; clockRefTime = nil; clockTickRate = nil;
        midiClockRoutine = Routine {
            var origin   = loopStartTime ? SystemClock.seconds;
            var latency  = midiOut.latency ? 0;
            var minPre   = 60 / bpm;   // one beat of pre-roll to lock the tempo
            var started  = false;
            var startAt, target, m, boundary;
            if(alignDur.notNil and: { alignDur > 0 }) {
                target = SystemClock.seconds + minPre + latency;
                // ceil, so a boundary closer than the pre-roll is skipped and we
                // take the next one — never a partial pass.
                m = (((target - origin) / alignDur).ceil).max(0);
                boundary = origin + (m * alignDur);
                startAt  = boundary - latency + syncOff;
            } {
                // No meter: warm up the clock, then Start (phase unaligned).
                startAt = SystemClock.seconds + minPre + syncOff;
            };
            inf.do {
                var nudge;
                if(started.not and: { SystemClock.seconds >= startAt }) {
                    midiOut.start;
                    started = true;
                    // Live's count begins at the boundary the Start was aimed
                    // at. prArmReading reads these to find the next boundary
                    // that carries Live's bar line.
                    if(boundary.notNil) {
                        clockTicksAtRef = 0;
                        clockRefTime    = boundary;
                        clockTickRate   = 1 / clockPeriod;
                    };
                };
                midiOut.midiClock;
                // Drain a bounded slice of any pending live sync nudge, carrying
                // the rest to later ticks so large slider moves slew smoothly
                // (a tempo blip of at most half a tick) instead of glitching.
                // clockPeriod is read per tick, so a reading moves the tempo
                // from the boundary it lands on.
                nudge = clockNudge.clip(clockPeriod * -0.5, clockPeriod * 0.5);
                clockNudge = clockNudge - nudge;
                (clockPeriod + nudge).max(0).wait;
            };
        }.play(SystemClock);
    }

    free {
        // First: a set being recorded must reach the disk even if the looper is
        // being torn down around it, and stop() is what closes the files.
        sessionRec !? { |r| r.free };
        CmdPeriod.remove(this);
        this.prCancelBBCutEnable;
        this.teardownBBCut;
        nextRecRoutine !? { |r| r.stop };
        nextRecSynth !? { |s| s.free };
        this.prFreeNextRecTail;
        recSynth !? { |s| s.free };
        engineSynth !? { |s| s.free };
        granularSynth !? { |s| s.free };
        masterSynth !? { |s| s.free };
        tapLevelSynth !? { |s| s.free };
        clickRoutine !? { |r| r.stop };
        midiClockRoutine !? { |r| r.stop };
        chordRoutine !? { |r| r.stop };
        breakRoutine !? { |r| r.stop };
        dissolveRoutine !? { |r| r.stop };
        readingRoutine !? { |r| r.stop };
        // Before 2026-11-08 free left these two running: a half-time landing
        // after free restarted the onset notes and sent MIDI.
        halfTimeRoutine = this.prStopRoutine(halfTimeRoutine);
        reverseRoutine = this.prStopRoutine(reverseRoutine);
        if(transportMode == \full) { midiOut !? { |m| m.stop } };
        buffer !? { |b| b.free };
        undoBuffer !? { |b| b.free };
        nextBuffer !? { |b| b.free };
        outBus !? { |b| b.free };
        phaseBus !? { |b| b.free };
        tapGainBus !? { |b| b.free };
        insertBus !? { |b| b.free };
        granularEnvBufs !? { |bufs| bufs.do { |b| b.free } };
        this.stopOnsetNotes;
        onsetResp !? { |r| r.free };
        pitchResp !? { |r| r.free };
        levelsResp !? { |r| r.free };
        tapLevelResp !? { |r| r.free };
        this.stopAnalysisMonitor;
        this.stopOverdubAnalysis;
        overdubSyncRoutine !? { |r| r.stop };
    }
}
