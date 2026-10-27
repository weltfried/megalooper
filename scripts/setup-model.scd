// megalooper — the Looper instance, its analysis defaults, and the callbacks
// that push results out to Live.
//
// Loaded by boot.scd; defines only, runs nothing. Two entry points:
//   ~setupLooper    — frees any previous Looper and builds a fresh one from ~rp.
//                     DESTRUCTIVE: Looper:free frees the loop buffers, so this
//                     is the one setup step that throws away a recording. Needs
//                     ~midiOut, so run ~setupMidiIO first.
//   ~wireLooperCallbacks — onAnalysis / onChordChange, plus the break's macro CC
//                     out to Live. Non-destructive; re-run it alone to change
//                     what happens after an analysis without losing the loop.
//                     It reads ~midiOut only when a break fires, and nil-guards
//                     it, so the load order with ~setupMidiIO does not matter.
//
// The callbacks touch GUI widgets (~exportNumField, ~rootLabel, ~exportDenoms)
// that gui-main.scd creates. That is safe in either load order because they are
// closures — nothing is read until a loop is actually analysed — and every
// widget access is nil-guarded so a callback firing before the window exists is
// a no-op rather than an error.
(
~ableton = NetAddr("127.0.0.1", 11000);

// ---- Live's arrangement record (Program Change 21) -----------------------
//
// The PRODUCTION copy of a set, and the counterpart to megalooper's own session
// recorder (Program Change 20, LooperSessionRecorder). Two switches, not one,
// because they cannot start at the same moment and pretending otherwise would
// make one of them lie:
//
//   PC 20  writes megalooper's two files and starts the INSTANT you press it —
//          including the playing that produces the first loop.
//   PC 21  arms Live's Arrangement Record. Live cannot record before the
//          transport rolls, and the transport cannot roll until a loop has been
//          analysed, because megalooper is the phase master and Live's 1.1.1 is
//          defined by the first loop. So this one waits, by construction.
//
// `record_mode` is Live's global Arrangement Record button. Set while the
// transport is stopped it ARMS; the recording begins when the MIDI Start
// arrives. Looper refuses to send a second Start while ITS session recording is
// running (see startTempoClocks) — so for a set you intend to keep, press both.
//
// The state here is OPTIMISTIC: nothing reads Live back, so this is what we last
// told it, not what it is. Toggling Live's record button by hand desyncs it, and
// one more press puts it right. Reading it back would mean an OSC listener on
// 11001 and a reply to wait for, which is more machinery than a footswitch that
// posts what it sent.
//
// UNVERIFIED ON THE RIG: whether Live under EXT sync treats record_mode = 1
// while stopped as "arm" or as "start now". If it starts immediately, this
// belongs on the transport edge instead.
~liveRecording = false;

~liveRecordSet = { |on|
    ~liveRecording = on;
    ~ableton.sendMsg("/live/song/set/record_mode", if(on) { 1 } { 0 });
    ("Live arrangement record " ++ if(on) { "ARMED" } { "off" }
        ++ "  (record_mode " ++ if(on) { 1 } { 0 } ++ " -> AbletonOSC)").postln;
    ~midiLogLine !? { |log|
        log.("liveRec-> record_mode=" ++ if(on) { 1 } { 0 } ++ " (to Live)") };
    on
};

~liveRecordToggle = { ~liveRecordSet.(~liveRecording.not) };

~setupLooper = {
    ~looper !? { |l| l.free };
    ~looper = Looper(s, ~midiOut);
    ~looper.inChannel     = ~inChannel;
    ~looper.outChannel    = ~outChannel;
    ~looper.returnChannel = ~returnChannel;
    // Session recorder: where the set is written, and the pair Live's master
    // comes back on (nil on a rig with no such pair — the dry tap is still
    // recorded, and startSessionRecording says which files it opened).
    ~looper.sessionDir     = ~sessionDir;
    ~looper.sessionChannel = ~sessionChannel;
    // Dry guitar tap for onset/pitch detection: the guitar's own hardware input
    // on the shared device, read directly, with Live nowhere in the path. nil on
    // a rig where SC cannot see that input, and the Looper then analyses its
    // recorded input instead. If the channel is wrong the tap is silent, no
    // onsets are detected and every loop falls back to the anchored meter below —
    // stopRecordStartPlay says so explicitly when that happens. The GUI's
    // "Analysis in" menu switches back to the processed input at any time.
    ~looper.analysisChannel = ~analysisChannel;
    ~looper.metronome     = false;
    // Recording width and the two timing offsets come from the routing profile
    // (~rp). Set before the GUI is built so the Input menu and both sliders
    // initialise to these values. Recalibrate per rig by ear (see "Calibrating
    // overdub latency" in docs/manual.md) and write the numbers back into the
    // profile — they depend on that rig's round trip, so they do not carry over.
    ~looper.inChannelCount = ~rp[\inChannelCount];
    ~looper.latencyMs      = ~rp[\latencyMs];
    // Live-sync offset is per-rig for the same reason latency is: it cancels
    // that rig's MIDI-clock follower lag. Optional in the profile — 0 means "no
    // offset", i.e. the behaviour of every rig that has not been calibrated yet.
    // Set before the GUI is built, so the bipolar slider opens at this value.
    ~looper.abletonSyncMs  = ~rp[\abletonSyncMs] ? 0;
    // Onset detection threshold. Optional per rig; 0.5 is the value validated
    // offline against the training loops. Raise it for a noisy input that throws
    // ghost onsets, lower it for quiet or soft playing that gets missed.
    ~looper.onsetThreshold = ~rp[\onsetThreshold] ? 0.5;
    // Third per-rig timing value, same story as the two above: the loop's audio
    // and the onset notes travel different paths to the ear, and only this rig
    // knows the gap. Negative sends the notes earlier.
    ~looper.onsetNoteOffsetMs = ~rp[\onsetNoteOffsetMs] ? 0;
    // Fourth per-rig timing value: where the loop-chain recorder starts relative
    // to the boundary. Measured with scripts/check-chain-align.scd, not guessed.
    ~looper.chainRecOffsetMs  = ~rp[\chainRecOffsetMs] ? 0;
    // A rig without Live keeps what its calibration found in your megalooper
    // folder (the Calibrate view), and those numbers win over the profile's:
    // nothing has to be pasted into it.
    // On saSystem the setup's own, else a rig of yours on its device, else
    // saSystem's (~rp[\calibrationKeys], setup-routing.scd).
    LooperCalibrator.applyKeptAtStart(~looper, ~rp, ~rp[\calibrationKeys] ?? { ~routingProfile },
        ~userRoot ?? { MegaFiles.userRoot }) !? { |said| said.postln };

    // Fallback meter for short / percussive / rubato loops whose expressive
    // timing fits no pulse grid: the loop is treated as whole bars of this
    // meter and the tempo is derived from its length (see MeterAnalyzer
    // anchorToLength). Defaults to 7/8 to match the odd-meter percussive loops
    // here; change it live in the GUI. bars 0 = auto (nearest ~110 BPM).
    MeterAnalyzer.fallbackNum   = 7;
    MeterAnalyzer.fallbackDenom = 8;
    MeterAnalyzer.fallbackBars  = 0;
};

~wireLooperCallbacks = {
    // The break, out to Live as a CC. Both edges are sent, absolutely: 0 when
    // the hole opens, 127 when the loop returns on the downbeat. Live's rack
    // has the two Rhythmic Steps devices on one macro, so this alone swaps the
    // pattern for exactly the length of the break.
    //
    // A SimpleController rather than a call inside fireBreak/endBreak, because
    // the break has four ways in (note 68, program 7, the GUI button, a
    // cancel from stop/clear) and \break is the one place they all pass
    // through. Its own controller, not the GUI's: this has to work on a rig
    // running headless, and ~wireLooperController needs the window.
    //
    // NOT deferred, unlike every GUI handler: this is a MIDI send, so the
    // MIDIdef thread it arrives on is the right one to leave on, and AppClock
    // would only add jitter to the edge that lands on the downbeat.
    ~breakController !? { |c| c.remove };
    ~breakController = SimpleController(~looper)
        .put(\break, { |looper, what, val|
            var cc = if(val) { 0 } { 127 };
            ~midiOut !? { |m|
                m.control(~pcCcChannel, ~breakMacroCc, cc);
                // Outgoing, so it never reaches ~midiLogLine's responders — and
                // without it a rack that does not move leaves you guessing
                // whether SC sent or Live never mapped.
                ~midiLogLine !? { |log|
                    log.("break->  cc=" ++ ~breakMacroCc ++ " val=" ++ cc
                        ++ " chan=" ++ ~pcCcChannel ++ " (to Live)") };
            };
        });

    ~looper.onAnalysis = { |r|
        if(r.bpm.notNil) {
            var bars = if(r.k > 1) { " over " ++ r.k ++ " bars" } { "" };
            var tag  = if(r.error == \lengthAnchored) { " (loop-locked)" } { "" };
            ("=> " ++ MeterAnalyzer.sigString(r)
                ++ " @ " ++ r.bpm.round(0.1) ++ " BPM"
                ++ bars ++ tag
                ++ " (" ++ r.onsetCount ++ " onsets, N=" ++ r.n ++ ")").postln;
            ~ableton.sendMsg("/live/song/set/tempo", r.bpm.asFloat);
            // Megalooper SA's loop echo is synced to the loop the same way,
            // and its drums keep the whole reading (MegaSA.setAnalysis).
            ~megaSA !? { |m| m.setAnalysis(r) };
            // Uneven bars go to Live as one bar per cycle of them (29/8 for
            // 7 7 7 8), so its bar line still meets the loop's
            // (Looper.barTicksOf). Live takes numerators up to 99.
            ~ableton.sendMsg("/live/song/set/signature_numerator",
                MeterAnalyzer.cycleOf(MeterAnalyzer.barsOf(r)).sum.asInteger.clip(1, 99));
            ~ableton.sendMsg("/live/song/set/signature_denominator", r.denominator.asInteger);
        } {
            ("=> " ++ r.error ++ " (" ++ r.onsetCount ++ " onsets)").postln
        };
        // Pre-fill the training-export fields with the analyzer's guess so the
        // user only has to correct mistakes before exporting the ground truth.
        {
            ~exportNumField   !? { r.numerator   !? { ~exportNumField.value_(r.numerator) } };
            ~exportBarsField  !? { ~exportBarsField.value_((r.k ? 1).max(1)) };
            (~exportDenomField.notNil and: { r.denominator.notNil }) .if {
                var idx = ~exportDenoms.indexOf(r.denominator.asInteger);
                idx !? { ~exportDenomField.value_(idx) };
            };
        }.defer;
        if(r.chordSegments.notNil and: { r.chordSegments.size > 0 }) {
            var summary = r.chordSegments.collect { |seg|
                seg.rootName ++ " " ++ seg.scaleName
                    ++ "@" ++ seg.start.round(0.01)
            }.join(" → ");
            ("=> " ++ r.chordSegments.size ++ " chord(s): "
                ++ summary).postln;
        } {
            "=> no chords detected".postln;
            { ~rootLabel !? { |t| t.string_("—") } }.defer;
        };
        // The Grains view's Chords line: what this take gives them to follow.
        { ~granularPaintChords !? { |f| f.() } }.defer;
    };

    // Drives Live's scale system from the chord routine. Looper's
    // startChordRoutine fires this at each segment boundary during playback,
    // looping with the buffer.
    ~looper.onChordChange = { |seg|
        ~ableton.sendMsg("/live/song/set/root_note", seg.root.asInteger);
        ~ableton.sendMsg("/live/song/set/scale_name", seg.scaleName);
        { ~rootLabel !? { |t| t.string_(seg.rootName ++ " " ++ seg.scaleName) } }.defer;
    };
};
)
