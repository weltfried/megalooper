// megalooper — the onset-analysis window: tune detection against live playing.
//
// Loaded by boot.scd; defines only, runs nothing. Entry point:
//   ~buildAnalysisPane — builds a fresh Analysis pane against the EXISTING
//                        ~looper and swaps it into the shell's holder. Safe to
//                        re-run; it never touches the loop. Follow with
//                        ~wireLooperController.() to re-subscribe its widgets.
//
// This file owns the monitor FEED — the state the onset lamp is drawn from and
// the OSC callback that fills it — plus the pane holding everything you only
// look at between takes: the monitor toggle and counts, overdub detection,
// onset notes, the pitch-segmentation knobs, the fallback meter, and the
// training-data export.
//
// The lamp itself and the threshold slider are NOT here. They are in the window
// header (gui-shell.scd), above the tab strip, because the threshold is tuned
// while playing and anything you have to leave Perform to reach is a thing you
// set once and then stop thinking about. This file keeps the state; the shell
// decays it and draws it.
//
// Why this exists: `MeterAnalyzer` never hears audio, only onset times. When
// detection admits ghost onsets or misses real hits, meter detection fails and
// the loop falls back to the anchored meter — the documented root cause of
// straight 4/4 takes coming out 7/8. The threshold is the lever, and tuning it
// blind is guesswork. So: turn the monitor on, play, and watch what it detects.
//
// It is also where the onsets get USED for something other than meter fitting:
// the Onset notes row at the bottom replays the loop's own onsets out of midiOut
// as MIDI notes, so Live can trigger a drum rack from the rhythm that was played.
//
// The feed comes from Looper's \looperAnalysisMonitor, which mirrors the
// recorder's detection chain exactly. What the lamp shows is what the next take
// will detect. If you change detection in one, change it in the other.
//
// WHY A LAMP AND NOT A WAVEFORM: this pane used to draw a scrolling envelope
// with the onsets marked on it, and it was the single most expensive thing in
// the GUI — 120 Pen calls per repaint, fed at 60 Hz, measured wrecking the
// language-side MIDI clock whenever this tab was on screen (docs/dev/roadmap.md,
// "MIDI clock jitter"). The picture was not worth that: tuning the threshold
// only ever asked ONE question of it — did this hit fire, and did anything fire
// between hits — and a lamp answers that exactly, while drawing nothing at all
// in the silence between onsets. It is also small enough to live in the header,
// which the scope never could be.
//
// NOTE ON HONESTY: the lamp shows the DETECTOR's output, not the detection
// function. Onsets whitens its internal odf before comparing it to the
// threshold, so there is no meaningful curve to plot the threshold against
// (measured: raw odf averaged ~1.4 while a threshold of 0.5 was firing only on
// real hits). What is shown is what actually fired, which is the honest signal.
(
// ---- Monitor state --------------------------------------------------------
// Scalars, not a ring buffer. The old scope kept 360 frames and rebuilt two
// arrays of that size on EVERY frame at 60 Hz (`drop(1).add`), which is 43,200
// allocated slots a second thrown away — that churn cost as much as the drawing
// did, and it ran whether or not this tab was visible, because the header's
// level meter reads this same feed.
~analysisStatsHz  = 5;    // readout updates per second
// Lamp brightness multiplier per decay step. The step is taken by the shell's
// ~guiPositionRoutine, which runs at ~guiPositionHz (20 Hz), so 0.55 is full
// brightness to barely-there in about 200 ms and fully out in 400 — a blink,
// not a lit indicator, so a run of hits reads as flicker rather than a light
// someone left on. Change ~guiPositionHz and this needs changing with it.
~analysisFlashDecay = 0.55;

~analysisLevel        = 0;    // most recent level, for the meters
~analysisPeak         = 0;    // decaying peak, for the dB readout
~analysisDirty        = false;
~analysisOnsetCount   = 0;
~analysisLastStrength = 0;
// Lamp brightness, 0..1: snapped to 1 by an onset here, decayed and drawn by
// the shell (the lamp itself is in the window header). It lives with the rest
// of the monitor state because this file owns the feed, not because it owns
// the view.
~analysisFlash        = 0;

// Called from Looper's OSC responder: for every level frame (15 Hz, onset
// false) and once per detected onset (sparse, onset true). Runs off the
// language's OSC thread: touch data only, never a view.
~analysisPush = { |level, onset, strength|
    ~analysisLevel = level;
    // ~0.98^15 per second ≈ a 2 s half-life, matching what the old 0.995-per-
    // frame decay gave at 60 Hz. Onset frames step it too; they are rare enough
    // not to matter.
    ~analysisPeak = max(~analysisPeak * 0.98, level);
    if(onset) {
        ~analysisOnsetCount = ~analysisOnsetCount + 1;
        ~analysisLastStrength = strength;
        ~analysisFlash = 1.0;
    };
    ~analysisDirty = true;
};

~analysisResetStats = {
    ~analysisOnsetCount = 0;
    ~analysisLastStrength = 0;
    ~analysisPeak = 0;
    ~analysisLevel = 0;
    ~analysisFlash = 0;
    ~analysisDirty = true;
};

// Note names in ABLETON's octave numbering (middle C = C3, so note 60 is C3 and
// the drum rack's first pad, 36, is C1). SC's own convention is an octave higher;
// matching Live is what makes the number in this window agree with the pad you
// are about to drop a sample onto.
~midiNoteName = { |num|
    var names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];
    names[num.asInteger % 12] ++ (num.asInteger.div(12) - 2)
};

// The onset-notes readout: how many hits are in the pattern and how long one
// pass of it is. Empty is the normal state until a take has been analysed, so it
// says so rather than showing a bare 0.
~onsetNotesRefresh = {
    // Unlike the rest of this file's refreshes, this one is driven by MODEL
    // notifications — and a take gets analysed whether or not this pane has
    // been built. A Qt view outlives its parent as a destroyed object that
    // throws on the first property write, so check before touching any.
    // Testing the PANE covers all its widgets at once: View:-remove recurses
    // into its children, marking every one of them closed.
    if(~analysisPane.notNil and: { ~analysisPane.isClosed.not }) {
    ~looper !? { |l|
        var count = l.onsetNoteCount;
        var dur   = l.onsetNotePatternDur;
        ~onsetNotesButton !? { |b| b.value = if(l.onsetNotes) { 1 } { 0 } };
        ~onsetNoteField !? { |f| f.value = l.onsetNote };
        ~onsetNoteNameLabel !? { |t| t.string_(~midiNoteName.(l.onsetNote)) };
        ~onsetNoteChanField !? { |f| f.value = l.onsetNoteChannel + 1 };
        ~onsetNoteVelLoField !? { |f| f.value = l.onsetNoteVelLo };
        ~onsetNoteVelHiField !? { |f| f.value = l.onsetNoteVelHi };
        ~onsetNoteDynField !? { |f| f.value = l.onsetNoteDynRange };
        ~onsetNoteGateField !? { |f| f.value = l.onsetNoteGateMs };
        ~onsetNoteOffsetField !? { |f| f.value = l.onsetNoteOffsetMs };
        ~onsetNoteChanceSlider !? { |sl| if(sl.held.not) { sl.value = l.onsetNoteChance } };
        ~onsetNoteChanceLabel !? { |t|
            t.string_((l.onsetNoteChance * 100).round.asInteger.asString ++ " %") };
        ~onsetNotesLabel !? { |t|
            // Say how many hits SOUND, not just how many were detected: at any
            // chance below 1 the pattern's own size is not what Live hears.
            var playing = l.onsetNotePlayingCount;
            t.string_(
                (~midiWords.('looper.onsetNotes') !? { |w| w.split($,).first ++ " · " } ? "")
                ++ if(count == 0) {
                    "no pattern yet"
                } {
                    (if(playing == count) { count.asString ++ " hits" } { playing.asString ++ " of " ++ count ++ " hits" })
                        ++ " · " ++ (dur ? 0).round(0.01) ++ " s/pass"
                });
        };
    };
    };
};

// The monitor's switch, from the model.
~analysisPaintMonitor = {
    ~looper !? { |l|
        ~analysisMonitorButton !? { |b|
            if(b.isClosed.not) {
                b.value = if(l.analysisMonitorOn) { 1 } { 0 };
            };
        };
    };
};

// Push model state into the widgets. Needed because the builder starts the
// monitor before ~wireLooperController has subscribed, so the notification that
// would paint the switch fires into the void and the view would open claiming
// "monitor off" while it is plainly running.
~analysisRefreshAll = {
    ~looper !? { |l|
        ~analysisThresholdBar !? { |sl| sl.value = ~onsetThresholdSpec.unmap(l.onsetThreshold) };
        ~analysisThresholdLabel !? { |t| t.string_(l.onsetThreshold.round(0.01).asString) };
        ~analysisPaintMonitor.();
        ~overdubDetectButton !? { |b| b.value = if(l.analyzeOverdubs) { 1 } { 0 } };
    };
    ~onsetNotesRefresh.();
};

// Monitoring costs an always-on FFT and reads the input, so it must not outlive
// the window. It is deliberately NOT stopped when you switch away from this
// view: the status band's input meter reads ~analysisPeak, which only this
// feed fills, and a level meter that goes dead whenever you look at another
// view is worse than useless. Registered at load time so a re-load replaces it
// rather than stacking, and self-initialising so this file stays loadable on
// its own (see the same note in gui-granular.scd).
~guiTeardowns = ~guiTeardowns ? ();
~guiTeardowns[\analysis] = {
    ~looper !? { |l| l.stopAnalysisMonitor; l.onMonitor = nil };
};

// ---- Builders -------------------------------------------------------------
// A box for a count, in the stage look.
~analysisBox = { |nb, width = 56|
    nb.canFocus_(false).font_(~guiMono.(15, true)).background_(~gt[\panel])
        .normalColor_(~gt[\ink]).align_(\left).fixedSize_(Size(width, 26))
};
// A cell of the onset notes' grid: a caption over its control.
~analysisCell = { |label, control|
    View().background_(~gt[\bg]).layout_(VLayout(~guiText.(label, 12, ~gt[\mute]), control)
        .margins_([10, 8, 10, 8]).spacing_(2))
};
// A line of the lower block: the label left, the controls right.
// The Bars-by-hand field to the Looper: "7 7 7 8", "7,7,7,8" or "7+7+7+8".
// Anything that is not a whole number reads as 0, which offerBars refuses
// out loud.
~analysisOfferBars = {
    var words = ~analysisBarsField !? { |f| f.string.replace(",", " ").replace("+", " ")
        .split($ ).reject { |w| w.isEmpty } } ? [];
    ~looper !? { |l| l.offerBars(words.collect { |w| w.asInteger },
        ~exportDenoms[(~analysisBarsDenom !? { |m| m.value }) ? 2]) };
};
~analysisLine = { |label, controls|
    HLayout(*([~guiLabel.(label, 14), nil] ++ controls)).margins_(0).spacing_(6)
};
// A switch in a tile: off is outlined, on is filled `key`.
~analysisSwitch = { |offLabel, onLabel, key, width|
    LooperTile().states_([[offLabel, ~gt[\ink], nil], [onLabel, ~gt[\onacc], ~gt[key ? \ink]]])
        .border_(~gt[\line]).font_(~guiMono.(13, true)).fixedSize_(Size(width ? 64, 28))
};

// ---- Pane -----------------------------------------------------------------
// The left column of the Setup view: the monitor and its counts, the
// threshold, overdub detection, onset notes, the pitch knobs, the fallback
// meter and the training export.
~buildAnalysisPane = {
    // Captured per build. The moment a newer pane bumps the global, the redraw
    // timer below stops — otherwise rebuilding this pane would leave the old
    // timer running against the views the rebuild just destroyed.
    var gen, pane = View().background_(~gt[\bg]);
    var stat = { |big, small| View().layout_(VLayout(big, ~guiText.(small, 12, ~gt[\mute])).margins_(12).spacing_(2)) };
    var grid;
    ~analysisGen = ~analysisGen + 1;
    gen = ~analysisGen;

    ~analysisMonitorButton = ~mapTag.(LooperTile().states_([["○ monitor off", ~gt[\mute], nil],
        ["● monitor on", ~gt[\play], nil]]).font_(~guiMono.(12, true)).fixedSize_(Size(130, 24)).align_(\left).pad_(0)
        .action_({ |b|
            ~looper !? { |l|
                if(b.value == 1) { l.startAnalysisMonitor } { l.stopAnalysisMonitor };
            };
        }), 'looper.analysisMonitor',
        "The analysis monitor: the input level, the onset lamp and the counts. It runs for the\n"
            "session; the status band's meter and lamp need it.");
    ~analysisPeakLabel = ~guiMonoText.("—", 26, ~gt[\ink]);
    ~analysisCountLabel = ~guiMonoText.("0", 26, ~gt[\ink]);
    ~analysisStrengthLabel = ~guiMonoText.("—", 26, ~gt[\ink]);
    // What the old readout line said, for the checks and the tooltip.
    ~analysisStatsLabel = ~analysisPeakLabel;
    ~analysisThresholdBar = ~mapTag.(~guiBar.(\ink, 16)
        .value_(~onsetThresholdSpec.unmap(~looper !? { |l| l.onsetThreshold } ? 0.5))
        .action_({ |sl| ~looper !? { |l| l.onsetThreshold = ~onsetThresholdSpec.map(sl.value) } }),
        'looper.onsetThreshold');
    ~analysisThresholdLabel = ~guiMonoText.("", 14, ~gt[\ink]);
    ~analysisThresholdCaption = ~guiLabel.("", 14);
    ~midiWatch.(~analysisThresholdCaption, { |t|
        t.string_("Onset threshold" ++ (~midiWords.('looper.onsetThreshold') !? { |w| " · " ++ w.split($,).first } ? "")
            ++ " · exponential") });

    // ---- Overdub meter detection -----------------------------------------
    // For loops that open atmospheric: take one has no beat, so no meter is
    // found and Live is never started. Overdub a rhythmic pattern and the
    // meter is derived from THAT, against the loop's fixed length.
    ~overdubDetectButton = ~mapTag.(~analysisSwitch.("OFF", "ON", \ink)
        .value_(if(~looper.notNil and: { ~looper.analyzeOverdubs }) { 1 } { 0 })
        .action_({ |b| ~looper !? { |l| l.analyzeOverdubs = (b.value == 1) } }),
        'looper.analyzeOverdubs',
        "Derive the meter from a rhythmic OVERDUB when the first take had no beat.\n"
            "Runs when you end an overdub, but only while the loop still has no meter — so it\n"
            "cannot change the tempo under you mid-performance. Detect now runs it at once, on the\n"
            "last overdub, even when the loop has a meter.");
    ~overdubDetectLabel = ~guiMonoText.("", 12, ~gt[\mute]);

    // ---- Onset notes ----------------------------------------------------------------
    // The other thing to do with detected onsets: send them to Live as a drum
    // part. The pattern is built once per analysis and replayed every loop pass
    // in phase with the audio, so it is a stable MIDI clip rather than a live
    // trigger that dies when you stop playing.
    ~onsetNotesButton = ~midiTip.(~analysisSwitch.("OFF", "ON", \play)
        .value_(if(~looper.notNil and: { ~looper.onsetNotes }) { 1 } { 0 })
        .action_({ |b| ~looper !? { |l| l.onsetNotes = (b.value == 1) } }),
        'looper.onsetNotes',
        "Replay the loop's detected onsets out of midiOut as MIDI notes, so Live (or the\n"
            "onset kit) can trigger a drum from the rhythm you played. Locked to the loop, not to\n"
            "your playing: it keeps going when you stop, and it repeats exactly.");
    ~onsetNotesLabel = ~guiMonoText.("—", 12, ~gt[\mute]).align_(\right);
    ~onsetNotesLabel.setProperty(\wordWrap, false);
    ~onsetNoteField = ~mapTag.(~analysisBox.(NumberBox()
        .clipLo_(0).clipHi_(127).step_(1).scroll_step_(1).decimals_(0)
        .value_(~looper !? { |l| l.onsetNote } ? 36)
        .action_({ |nb| ~looper !? { |l| l.onsetNote = nb.value } }), 46),
        'looper.onsetNote',
        "MIDI note number every onset sends. 36 (C1) is the first pad of Live's Drum Rack.\n"
            "Octave numbering here matches Live's, not SC's.");
    ~onsetNoteNameLabel = ~guiMonoText.(~midiNoteName.(~looper !? { |l| l.onsetNote } ? 36), 13, ~gt[\mute]);
    // Shown 1-16 because that is what Live shows; the model keeps the 0-15
    // that every MIDIOut call actually wants.
    ~onsetNoteChanField = ~analysisBox.(NumberBox()
        .toolTip_("MIDI channel, numbered 1-16 as Live shows it. Defaults to 2, which is where the\n"
            "rigs here are mapped; the onsets are the only notes on this IAC bus.")
        .clipLo_(1).clipHi_(16).step_(1).scroll_step_(1).decimals_(0)
        .value_((~looper !? { |l| l.onsetNoteChannel } ? 1) + 1)
        .action_({ |nb| ~looper !? { |l| l.onsetNoteChannel = nb.value - 1 } }));
    ~onsetNoteVelLoField = ~mapTag.(~analysisBox.(NumberBox()
        .clipLo_(1).clipHi_(127).step_(1).scroll_step_(1).decimals_(0)
        .value_(~looper !? { |l| l.onsetNoteVelLo } ? 40)
        .action_({ |nb| ~looper !? { |l| l.onsetNoteVelLo = nb.value } }), 44),
        'looper.onsetNoteVelLo',
        "Velocity of the QUIETEST hit — the floor everything at or below the dynamic range is sent at.");
    ~onsetNoteVelHiField = ~mapTag.(~analysisBox.(NumberBox()
        .clipLo_(1).clipHi_(127).step_(1).scroll_step_(1).decimals_(0)
        .value_(~looper !? { |l| l.onsetNoteVelHi } ? 127)
        .action_({ |nb| ~looper !? { |l| l.onsetNoteVelHi = nb.value } }), 44),
        'looper.onsetNoteVelHi',
        "Velocity of the LOUDEST hit in the loop. Velocities are relative to that peak, so they\n"
            "do not shift when you change the interface gain.");
    ~onsetNoteDynField = ~mapTag.(~analysisBox.(NumberBox()
        .clipLo_(1).clipHi_(90).step_(1).scroll_step_(1).decimals_(0)
        .value_(~looper !? { |l| l.onsetNoteDynRange } ? 30)
        .action_({ |nb| ~looper !? { |l| l.onsetNoteDynRange = nb.value } })),
        'looper.onsetNoteDynRange',
        "How many dB below the loop's loudest hit maps to the minimum velocity. Small =\n"
            "compressed, every hit near the top. Large = wide, quiet ghost notes stay quiet.");
    ~onsetNoteGateField = ~mapTag.(~analysisBox.(NumberBox()
        .clipLo_(1).clipHi_(1000).step_(1).scroll_step_(5).decimals_(0)
        .value_(~looper !? { |l| l.onsetNoteGateMs } ? 20)
        .action_({ |nb| ~looper !? { |l| l.onsetNoteGateMs = nb.value } })),
        'looper.onsetNoteGateMs',
        "How long each note is held. Drum racks and one-shot samplers ignore this; anything\n"
            "gated does not. Automatically shortened so a gate can never run into the next hit.");
    ~onsetNoteOffsetField = ~analysisBox.(NumberBox()
        .toolTip_("Timing trim. NEGATIVE sends the notes EARLIER. The loop and the notes reach your\n"
            "ears down different paths, so they need lining up per rig, like Overdub latency and\n"
            "Live sync do. Takes effect on the next hit, so dial it while playing.")
        .clipLo_(-500).clipHi_(500).step_(1).scroll_step_(1).decimals_(0)
        .value_(~looper !? { |l| l.onsetNoteOffsetMs } ? 0)
        .action_({ |nb| ~looper !? { |l| l.onsetNoteOffsetMs = nb.value } }));
    // Thin the part without editing the pattern. The dice are thrown once per
    // take, so this bar only raises and lowers a waterline over them: dragging
    // it is monotonic and never reshuffles the hits already sounding.
    ~onsetNoteChanceSlider = ~mapTag.(~guiBar.(\play, 12)
        .value_(~looper !? { |l| l.onsetNoteChance } ? 1)
        .action_({ |sl| ~looper !? { |l| l.onsetNoteChance = sl.value } }),
        'looper.onsetNoteChance',
        "How likely each onset is to be sent: 100 % is every hit as played, 0 % silence. Which\n"
            "hits drop out is fixed per take, so the thinned part still repeats exactly. Re-roll\n"
            "for a different subset. Takes effect on the next hit.");
    ~onsetNoteChanceLabel = ~guiMonoText.("", 15, ~gt[\ink]);
    grid = GridLayout.rows(
        [~analysisCell.("Note", HLayout(~onsetNoteField, ~onsetNoteNameLabel).margins_(0).spacing_(6)),
            ~analysisCell.("Ch", ~onsetNoteChanField),
            ~analysisCell.("Vel", HLayout(~onsetNoteVelLoField, ~guiText.("–", 14, ~gt[\mute]),
                ~onsetNoteVelHiField).margins_(0).spacing_(4)),
            ~analysisCell.("Dynamics · dB", ~onsetNoteDynField)],
        [~analysisCell.("Offset · ms", ~onsetNoteOffsetField),
            ~analysisCell.("Gate · ms", ~onsetNoteGateField),
            ~analysisCell.("Chance", VLayout(~onsetNoteChanceLabel, ~onsetNoteChanceSlider).margins_(0).spacing_(4)),
            ~analysisCell.("Dice", ~mapTag.(LooperTile().states_([["Re-roll", ~gt[\ink], nil]]).border_(~gt[\line])
                .cycles_(false).font_(~guiSans.(14)).fixedHeight_(26)
                .action_({ ~looper !? { |l| l.rerollOnsetNotes } }),
                'looper.rerollOnsetNotes',
                "Throw the dice again: the same hits at the same chance, a different subset of them.\n"
                    "Does not touch the loop, the pattern or the audio."))]
    ).hSpacing_(1).vSpacing_(1).margins_(1);

    // ---- Training-data export -------------------------------------------------------
    // Label the current loop with its correct name + signature + bar length
    // and write it (WAV + JSON) to ~trainingDataDir. The fields auto-fill from
    // the analyzer's guess after each recording (see onAnalysis in
    // setup-model.scd) so only corrections are needed.
    // One of the focusable widgets in the window (everything else is
    // canFocus_(false)), so while it holds focus it eats every keystroke and
    // the single-key shortcuts are dead. Enter (commit) and Escape both hand
    // focus back to the window view.
    ~exportNameField = TextField()
        .font_(~guiSans.(14)).background_(~gt[\panel]).stringColor_(~gt[\ink])
        .string_("")
        .action_({ ~guiWindow !? { |w| w.view.focus(true) } })
        .focusGainedAction_({ |v|
            v.background_(~gt[\armed]).stringColor_(~gt[\onacc]);
            ~guiSetTyping !? { |f| f.(true) };
        })
        .focusLostAction_({ |v|
            v.background_(~gt[\panel]).stringColor_(~gt[\ink]);
            ~guiSetTyping !? { |f| f.(false) };
        })
        // 27 = Escape: leave the field without committing. Returning true
        // consumes the event; every other key returns nil so Qt's default text
        // handling still types the character.
        .keyDownAction_({ |v, char, mods, uni|
            if(uni == 27) {
                ~guiWindow !? { |w| w.view.focus(true) }; true
            } { nil };
        });
    ~exportNumField = ~analysisBox.(NumberBox()
        .clipLo_(1).clipHi_(32).step_(1).scroll_step_(1).decimals_(0)
        .value_(MeterAnalyzer.fallbackNum), 40);
    ~exportDenomField = PopUpMenu().canFocus_(false).font_(~guiMono.(13, true))
        .background_(~gt[\panel]).stringColor_(~gt[\ink])
        .fixedWidth_(56)
        .items_(~exportDenoms.collect(_.asString))
        .value_((~exportDenoms.indexOf(MeterAnalyzer.fallbackDenom)) ? 1);
    ~exportBarsField = ~analysisBox.(NumberBox()
        .clipLo_(1).clipHi_(64).step_(1).scroll_step_(1).decimals_(0)
        .value_(1), 40);

    // ---- Bars by hand -----------------------------------------------------------------
    // One cycle of uneven bars, "7 7 7 8" (spaces, commas or +), over the
    // denominator beside it. Looper.offerBars makes a reading of the loop as it
    // is and lands it on the next boundary like the next reading; the drums and
    // the bar grid follow it, and Revert goes back. Until detection finds
    // uneven bars by itself, this is how to hear them. Focus as the name field's.
    ~analysisBarsField = TextField()
        .font_(~guiMono.(14, true)).background_(~gt[\panel]).stringColor_(~gt[\ink])
        .string_("7 7 7 8").fixedWidth_(120)
        .toolTip_("One cycle of the loop's bars, in units of the denominator beside it:\n"
            "7 7 7 8 over 8 is three bars of 7/8 and one of 8/8. Enter or Set bars lands\n"
            "it on the next loop boundary; the loop's length sets the tempo.")
        .action_({ ~analysisOfferBars.(); ~guiWindow !? { |w| w.view.focus(true) } })
        .focusGainedAction_({ |v|
            v.background_(~gt[\armed]).stringColor_(~gt[\onacc]);
            ~guiSetTyping !? { |f| f.(true) };
        })
        .focusLostAction_({ |v|
            v.background_(~gt[\panel]).stringColor_(~gt[\ink]);
            ~guiSetTyping !? { |f| f.(false) };
        })
        .keyDownAction_({ |v, char, mods, uni|
            if(uni == 27) {
                ~guiWindow !? { |w| w.view.focus(true) }; true
            } { nil };
        });
    ~analysisBarsDenom = PopUpMenu().canFocus_(false).font_(~guiMono.(13, true))
        .background_(~gt[\panel]).stringColor_(~gt[\ink])
        .fixedWidth_(56)
        .items_(~exportDenoms.collect(_.asString))
        .value_((~exportDenoms.indexOf(8)) ? 2);

    pane.layout_(VLayout(
        HLayout(~guiTitle.("Analysis", 24), ~analysisMonitorButton, nil,
            LooperTile().states_([["Reset counts", ~gt[\mute], nil]]).cycles_(false).font_(~guiSans.(13))
                .fixedSize_(Size(100, 24)).action_({ ~analysisResetStats.() })
        ).margins_(0).spacing_(12),
        View().background_(~gt[\line]).layout_(HLayout(
            View().background_(~gt[\bg]).layout_(VLayout(stat.(~analysisPeakLabel, "peak dB")).margins_(0)),
            View().background_(~gt[\bg]).layout_(VLayout(stat.(~analysisCountLabel, "onsets since reset")).margins_(0)),
            View().background_(~gt[\bg]).layout_(VLayout(stat.(~analysisStrengthLabel, "last strength")).margins_(0))
        ).margins_(1).spacing_(1)),
        VLayout(HLayout(~analysisThresholdCaption, nil, ~analysisThresholdLabel).margins_(0),
            ~analysisThresholdBar).spacing_(5).margins_(0),
        View().layout_(VLayout(
            HLayout(~guiLabel.("Overdub meter detection", 15, ~gt[\ink]), nil,
                ~mapTag.(LooperTile().states_([["Detect now", ~gt[\ink], nil]]).border_(~gt[\line]).cycles_(false)
                    .font_(~guiSans.(13)).fixedSize_(Size(96, 28))
                    .action_({ ~looper !? { |l| l.detectMeterFromOverdub(true) } }),
                    'looper.detectMeterFromOverdub',
                    "Re-run detection on the last overdub's onsets now, even if the loop already has a meter."),
                ~overdubDetectButton).margins_(0).spacing_(8),
            ~overdubDetectLabel,
            ~guiRule.()
        ).margins_(0).spacing_(6)),
        HLayout(~guiLabel.(case { (~rp !? { |r| r[\live] }) != false } { "Onset notes → Live" }
            { (~rp !? { |r| r[\sa] }) == true } { "Onset notes → onset kit" } { "Onset notes" }, 16, ~gt[\ink], true), nil, ~onsetNotesLabel, ~onsetNotesButton)
            .margins_(0).spacing_(10),
        View().background_(~gt[\line]).layout_(grid),
        ~guiRule.(),
        // ---- Pitch segmentation, the fallback, the export ------------------------
        // Writes to PitchAnalyzer's classvars and ~looper.chordMinPerWindow take
        // effect on the NEXT recorded loop: chord segmentation runs at stop-
        // record time, not live. The fallback meter is what a take that fits
        // no pulse grid is anchored to; bars 0 = auto.
        ~analysisLine.("Pitch range · Hz", [
            ~analysisBox.(NumberBox().clipLo_(1).clipHi_(20000).step_(1).scroll_step_(1).decimals_(0)
                .value_(PitchAnalyzer.hzLo).action_({ |nb| PitchAnalyzer.hzLo = nb.value }), 64),
            ~guiText.("–", 14, ~gt[\mute]),
            ~analysisBox.(NumberBox().clipLo_(1).clipHi_(20000).step_(10).scroll_step_(10).decimals_(0)
                .value_(PitchAnalyzer.hzHi).action_({ |nb| PitchAnalyzer.hzHi = nb.value }), 64)
        ]),
        ~analysisLine.("Min samples · total / per window", [
            ~analysisBox.(NumberBox().clipLo_(1).clipHi_(1000).step_(1).scroll_step_(1).decimals_(0)
                .value_(PitchAnalyzer.minSamples)
                .action_({ |nb| PitchAnalyzer.minSamples = nb.value.asInteger }), 56),
            ~guiText.("/", 14, ~gt[\mute]),
            ~analysisBox.(NumberBox().clipLo_(1).clipHi_(1000).step_(1).scroll_step_(1).decimals_(0)
                .value_(~looper !? { |l| l.chordMinPerWindow } ? 4)
                .action_({ |nb| ~looper !? { |l| l.chordMinPerWindow = nb.value.asInteger } }), 56)
        ]),
        ~analysisLine.("Fallback meter / bars", [
            PopUpMenu().canFocus_(false).font_(~guiMono.(13, true))
                .background_(~gt[\panel]).stringColor_(~gt[\ink]).fixedWidth_(76)
                .toolTip_("What a take that fits NO pulse grid is anchored to. The loop is kept exactly\n"
                    "this many bars of this meter, so it still lines up with Live.")
                .items_(~fallbackMeterLabels)
                .value_((~fallbackMeters.detectIndex { |m|
                    (m[0] == MeterAnalyzer.fallbackNum) and: { m[1] == MeterAnalyzer.fallbackDenom } }) ? 0)
                .action_({ |menu|
                    var m = ~fallbackMeters[menu.value];
                    MeterAnalyzer.fallbackNum   = m[0];
                    MeterAnalyzer.fallbackDenom = m[1];
                }),
            ~analysisBox.(NumberBox()
                .toolTip_("0 = auto: pick the bar count that lands nearest 110 BPM.")
                .clipLo_(0).clipHi_(MeterAnalyzer.maxFallbackBars).step_(1).scroll_step_(1).decimals_(0)
                .value_(MeterAnalyzer.fallbackBars)
                .action_({ |nb| MeterAnalyzer.fallbackBars = nb.value.asInteger }), 44)
        ]),
        ~analysisLine.("Bars by hand · one cycle", [
            ~analysisBarsField, ~guiText.("/", 14, ~gt[\mute]), ~analysisBarsDenom,
            LooperTile().states_([["Set bars", ~gt[\ink], nil]]).border_(~gt[\line]).cycles_(false)
                .font_(~guiSans.(13)).fixedSize_(Size(86, 26))
                .toolTip_("Give the loop these bars, from the next loop boundary.")
                .action_({ ~analysisOfferBars.() })
        ]),
        // Exporting a take is what you do when the detector got it WRONG, and
        // the correction typed here is the label tuning is scored against.
        ~guiLabel.("Training-data export · name, signature, bars", 14),
        HLayout(
            [~exportNameField, stretch: 1], ~exportNumField, ~guiText.("/", 14, ~gt[\mute]),
            ~exportDenomField, ~exportBarsField, ~guiText.("bars", 13, ~gt[\mute]),
            LooperTile().states_([["Export · E", ~gt[\ink], nil]]).border_(~gt[\line]).cycles_(false)
                .font_(~guiSans.(13)).fixedSize_(Size(86, 26))
                .toolTip_("Write the loop and this label to training-data/ (key E).")
                .action_({ ~doExport.value })
        ).margins_(0).spacing_(6),
        // Absorbs the slack when the view is taller than the controls, so the
        // rows stay packed at the top instead of spreading out.
        nil
    ).margins_([22, 20, 22, 20]).spacing_(16));

    ~analysisPane = pane;
    ~guiSwapPane.(\analysis, pane);

    // Feed the lamp from the model. Assigning the slot (rather than the Looper
    // knowing about views) keeps every view out of the class.
    ~looper !? { |l| l.onMonitor = ~analysisPush };

    // The readout timer. All it does is rebuild three numbers, so it runs at
    // the rate they are worth re-reading rather than at a frame rate.
    //
    // Three ways to stop: a newer pane exists (gen), the window is gone, or the
    // pane was destroyed without either.
    ~analysisStatsRoutine = AppClock.sched(0, {
        if(gen != ~analysisGen
            or: { ~guiWindow.isNil } or: { ~guiWindow.isClosed }
            or: { ~analysisPane.isNil } or: { ~analysisPane.isClosed }) {
            nil   // retired: unschedule
        } {
            // The feed keeps filling whatever view is up — ~analysisPush is
            // plain data on the OSC thread, and the status band's meter and
            // lamp depend on it — but these numbers are only worth rebuilding
            // when someone can see them.
            if(~analysisDirty and: {
                ~guiPaneSeen.(\analysis)
            }) {
                ~analysisDirty = false;
                // Silence is a dash, as everywhere else, not -99.0.
                ~analysisPeakLabel !? { |t| t.string_(if(~analysisPeak.ampdb < -90) { "—" }
                    { ~analysisPeak.ampdb.round(0.1).asString }) };
                ~analysisCountLabel !? { |t| t.string_(~analysisOnsetCount.asString) };
                ~analysisStrengthLabel !? { |t| t.string_(~analysisLastStrength.round(0.01).asString) };
            };
            ~analysisStatsHz.reciprocal
        };
    });

    // Start monitoring straight away: this pane always exists, so the monitor
    // runs for the session — see ~guiTeardowns above for why that is
    // deliberate rather than an oversight.
    ~looper !? { |l| l.startAnalysisMonitor };
    ~analysisRefreshAll.();
    pane
};
)
