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

// ---- The overdub latency: reported, corrected, followed ------------------
//
// On a rig without Live the overdub latency starts from the round trip the
// audio devices report (~latencyReport, read after the boot by
// setup-routing.scd's ~audioRoundTripReported), plus the delay of the two
// chains on that round trip: the loop's, which you hear it through, and the
// instrument's, which the looper records. A measurement, or the ear, on this
// setup is kept as its difference to that (latencyCorrectionMs, in
// calibration.json), the way Live keeps a Driver Error Compensation, so it
// still holds when the effects change. A chain whose delay changes (a plugin
// reporting one, the Shifter switched to FFT) moves the latency with it,
// whatever it started from. With no report (not a Mac, a Live rig) the
// start is the profile's or the kept one, as before.
~latencyChainTracks = #[\guitar, \loop];
// One chain's delay in ms, 0 without it.
~latencyChainMs = { |m, track|
    (m !? { |sa| sa.chainFor(track) !? { |c| c.latency(sa.sampleRate) * 1000 / sa.sampleRate } }) ? 0
};
~latencyChainsMs = { |m| ~latencyChainTracks.sum { |t| ~latencyChainMs.(m ?? { ~megaSA }, t) } };
// The round trip reported: the devices' and the chains', or nil.
~latencyReportedMs = { ~latencyReport !? { |r| r[\interfaceMs] + ~latencyChainsMs.() } };

// What is reported, in words, and how far `latencyMs` (the overdub latency
// set, or nil) is from it: "Reported 59.6 ms: the audio device 59.6, the
// effects 0.0. Overdub latency is set 2.4 ms below it." nil with no report.
~latencyReportedLine = { |latencyMs|
    var device = ~latencyReport !? { |r| r[\interfaceMs] };
    ~latencyReportedMs.() !? { |r|
        var off = latencyMs !? { |l| l - r };
        "Reported " ++ r.round(0.1) ++ " ms: the audio device " ++ device.round(0.1)
            ++ ", the effects " ++ (r - device).round(0.1) ++ "."
            ++ (off !? { |o| if(o.abs >= 0.05) { " Overdub latency is set "
                ++ o.abs.round(0.1) ++ " ms " ++ (if(o > 0) { "above" } { "below" }) ++ " it." } { "" } } ? "")
    }
};

// At a start, after the kept numbers: answers the line saying what it set,
// or nil. The correction is the one kept for this setup alone (the audio
// settings' devices and buffer, or a profile's rig): one kept for another
// setup or a rig the setup only inherits from was measured elsewhere.
~latencyStart = { |looper, rp, root|
    var reported = ~latencyReportedMs.(), own, start;
    ~latencyFollow.(looper, ~megaSA);
    if(reported.notNil and: { rp[\live] == false } and: { root.notNil }) {
        own = LooperCalibrator.readKept(LooperCalibrator.keptPathIn(root))[(rp[\calibrationKey] ?? { ~routingProfile }).asSymbol];
        start = LooperCalibrator.startLatency(reported, own);
        looper.latencyMs = start[\latencyMs];
        "megalooper: overdub latency " ++ start[\latencyMs].round(0.1) ++ " ms: the round trip reported, "
            ++ reported.round(0.1) ++ " ms" ++ (if(start[\correctionMs] != 0) {
                ", " ++ (if(start[\correctionMs] > 0) { "+" } { "" }) ++ start[\correctionMs].round(0.1)
                    ++ " ms as kept for this setup" } { "" }) ++ "."
    }
};

// A chain's delay moved: the latency moves with it. The last delay of each
// chain is kept here, so only a change counts.
~latencyFollow = { |looper, m|
    var last = IdentityDictionary.new;
    ~latencyFollower !? { |c| c.remove };
    ~latencyFollower = m !? { |sa|
        ~latencyChainTracks.do { |t| last.put(t, ~latencyChainMs.(sa, t)) };
        SimpleController(sa).put(\latency, { |who, what, track, secs|
            var was = last[track], now = secs * 1000;
            if(was.notNil and: { looper.notNil }) {
                last.put(track, now);
                looper.latencyMs = looper.latencyMs + (now - was);
            };
        })
    };
};

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
    // Then, where the devices report their round trip, the overdub latency
    // starts from it, and it follows the chains' delay from here on.
    ~latencyStart.(~looper, ~rp, ~userRoot ?? { MegaFiles.userRoot }) !? { |said| said.postln };

    // Fallback meter for short / percussive / rubato loops whose expressive
    // timing fits no pulse grid: the loop is treated as whole bars of this
    // meter and the tempo is derived from its length (see MeterAnalyzer
    // anchorToLength). Defaults to 7/8 to match the odd-meter percussive loops
    // here; change it live on Setup's Rig page. bars 0 = auto (nearest ~110
    // BPM). Whether there is a fallback at all is ~fallbackApply's, below.
    MeterAnalyzer.fallbackNum   = 7;
    MeterAnalyzer.fallbackDenom = 8;
    MeterAnalyzer.fallbackBars  = 0;
};

// ---- The fallback meter's switch ---------------------------------------------
// Whether a take that fits no pulse grid is kept as whole bars of the fallback
// meter (MeterAnalyzer.fallbackOn), or has no meter: the loop plays at its
// length, the drums wait, and the Overdub meter (on by default) finds one from
// an overdub. On Setup's Rig page (gui-rig.scd), kept in settings.json beside
// the theme; off unless switched on (2026-11-07).
//   ~fallbackApply.()    the switch as settings.json says (boot.scd, once the
//                        settings are read)
//   ~fallbackSet.(true)  on, kept; false off
~fallbackPrefKey = "fallbackMeter";
~fallbackDefault = "off";
~fallbackOnSaved = { ((~prefSaved !? { |f| f.value(~fallbackPrefKey) }) ? ~fallbackDefault) == "on" };
~fallbackApply = { MeterAnalyzer.fallbackOn = ~fallbackOnSaved.() };
// It tells MeterAnalyzer's dependants (the Rig page's switch, gui-rig.scd):
// a class variable sends nothing of itself.
~fallbackSet = { |on|
    MeterAnalyzer.fallbackOn = on == true;
    MeterAnalyzer.changed(\fallbackOn, MeterAnalyzer.fallbackOn);
    ~prefSave !? { |f| f.value(~fallbackPrefKey, if(on == true) { "on" } { "off" }, "the fallback meter's switch") };
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
            // (MeterDecision.barTicksOf). Live takes numerators up to 99.
            ~ableton.sendMsg("/live/song/set/signature_numerator",
                MeterAnalyzer.cycleOf(MeterAnalyzer.barsOf(r)).sum.asInteger.clip(1, 99));
            ~ableton.sendMsg("/live/song/set/signature_denominator", r.denominator.asInteger);
        } {
            ("=> " ++ (if(r.error == \noFit) { "no meter: nothing fits, the loop plays at its length" } { r.error })
                ++ " (" ++ r.onsetCount ++ " onsets)").postln
        };
        if(r.chordSegments.notNil and: { r.chordSegments.size > 0 }) {
            var summary = r.chordSegments.collect { |seg|
                seg.rootName ++ " " ++ seg.scaleName
                    ++ "@" ++ seg.start.round(0.01)
            }.join(" → ");
            ("=> " ++ r.chordSegments.size ++ " chord(s): "
                ++ summary).postln;
        } {
            "=> no chords detected".postln;
        };
        // The window hears of the result from the Looper itself (\result,
        // Looper.prSetResult), for this and for every other way it changes.
    };

    // Drives Live's scale system from the chord routine. Looper's
    // startChordRoutine fires this at each segment boundary during playback,
    // looping with the buffer.
    ~looper.onChordChange = { |seg|
        ~ableton.sendMsg("/live/song/set/root_note", seg.root.asInteger);
        ~ableton.sendMsg("/live/song/set/scale_name", seg.scaleName);
        // The window's key hears it from the Looper itself (\chord).
    };
};
)
