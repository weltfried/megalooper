// megalooper — the MVC wiring, and the export action the keyboard shares.
//
// Loaded LAST by boot.scd; defines only, runs nothing. Entry points:
//   ~doExport             — export the current loop using the export fields
//   ~wireLooperController — SimpleController subscriptions. Must run AFTER the
//                           window and all its panes exist: it wires widgets
//                           from the status band and from every pane file.
//
// Setters on ~looper fire `this.changed(\key, val)`; SimpleController.put
// dispatches. Updates are .defer'd so they always land on AppClock — a MIDIdef
// callback fires from a different thread, and touching a Qt view from there is
// a crash rather than a glitch.
//
// EVERY widget reach is nil-guarded. The window is built once and the panes
// once each, so most of these guards never fire in a healthy session — but a
// pane builder that throws half way leaves its globals pointing at destroyed Qt
// objects, and an unguarded handler would then throw on every model event for
// the rest of the session, which is a far worse failure than a control that
// quietly stops tracking. The painters (gui-status.scd, gui-perform.scd) guard
// themselves.
(
// Export the current loop using whatever is in the export fields. Shared by the
// Export button (Setup) and the 'e' key binding; evaluated at call time so the
// fields need only exist by then.
~doExport = {
    ~exportNameField !? {
        ~looper !? { |l|
            l.exportTrainingLoop(
                ~trainingDataDir,
                ~exportNameField.string,
                ~exportNumField.value.asInteger,
                ~exportDenoms[~exportDenomField.value],
                ~exportBarsField.value.asInteger);
        };
    };
};

// A bar and its readout from the model, unless the mouse is holding the bar:
// the drag and the model would fight over it.
~wireBar = { |bar, label, pos, text|
    bar !? { |b| if(b.isClosed.not and: { (b.respondsTo(\held) and: { b.held }).not }) { b.value = pos } };
    label !? { |t| if(t.isClosed.not) { t.string_(text) } };
};

// A paint that a knob or a pedal can ask for a hundred times a second runs at
// most once per 50 ms: the first ask schedules it, the asks after it until it
// runs join it. Painters check their views, so one landing after a rebuild is
// harmless.
~guiSoonQueued = IdentitySet.new;
~guiSoon = { |key, f|
    if(~guiSoonQueued.includes(key).not) {
        ~guiSoonQueued.add(key);
        AppClock.sched(0.05, { ~guiSoonQueued.remove(key); f.value; nil });
    };
};

~wireLooperController = {
    ~looperController !? { |c| c.remove };
    ~looperController = SimpleController(~looper)
        // The state block says the feedback while overdubbing, and only then.
        .put(\feedback, { |looper, what, val|
            { ~wireBar.(~feedbackSlider, ~feedbackLabel, val, val.round(0.01).asString);
              if(looper.state == \overdubbing) { ~statusPaintLook.() } }.defer;
        })
        .put(\masterAmp, { |looper, what, val|
            { ~wireBar.(~masterAmpSlider, ~masterAmpLabel, val, val.round(0.01).asString) }.defer;
        })
        // Morph appears on Perform and on Sound, so it is the one granular
        // parameter with a hand-written handler; the rest are wired
        // generically below.
        .put(\granularMorph, { |looper, what, val|
            { ~wireBar.(~granularSlider, ~granularLabel, val, val.round(0.01).asString);
              ~granularRefreshOne !? { |f| f.(\granularMorph, val) };
              ~performPaintGrains !? { |f| f.() } }.defer;
        })
        .put(\bbcut, { |looper, what, val|
            { ~performPaintCutter !? { |f| f.() };
              ~bbcutPaintHeader !? { |f| f.() };
              // The Sound tab carries a dot while the cutter runs, so it is
              // visible with the view hidden — which is when you need it.
              ~guiRefreshTabs !? { |f| f.() } }.defer;
        })
        // The set recorder. Both surfaces write to the model, so a footswitch
        // press paints the tile and a click is indistinguishable from a
        // footswitch press — the same contract every other toggle here has.
        .put(\sessionRecording, { |looper, what, val|
            { ~guiSessionRecPaint !? { |f| f.() } }.defer;
        })
        .put(\bbcutMode, { |looper, what, val|
            { ~performPaintCutter !? { |f| f.() };
              ~bbcutPaintHeader !? { |f| f.() } }.defer;
        })
        // One coarse refresh per wholesale state change (preset recall today,
        // any other bulk path later). Deliberately NOT a rebuild on
        // \bbcutVoices: that fires from setVoiceAmp/setVoicePan on every pixel
        // of a slider drag, and ~renderBBCutEditor removes and rebuilds the
        // whole panel — it would destroy the slider under the mouse mid-gesture.
        .put(\bbcutState, { |looper, what, val|
            // Voice tabs FIRST: they clamp ~bbcutSelVoice, so a preset with
            // fewer voices can't leave the editor reading a nil voice.
            { ~renderBBCutVoiceMenu    !? { |f| f.() };
              ~renderBBCutEditor       !? { |f| f.() };   // repaints the arc readout
              ~refreshBBCutPresetButtons !? { |f| f.() };
              ~performPaintCutter !? { |f| f.() } }.defer;
        })
        // Perform's Cutter column and the density row: a drag on a voice's
        // amp or pan says this per pixel, so at most every 50 ms.
        .put(\bbcutVoices, { |looper, what, val|
            ~guiSoon.(\cutter, { ~performPaintCutter !? { |f| f.() }; ~bbcutRefreshDensity !? { |f| f.() } });
        })
        .put(\nextRecState, { |looper, what, val|
            { ~performPaintActions !? { |f| f.() } }.defer;
        })
        .put(\declickMs, { |looper, what, val|
            { ~wireBar.(~declickSlider, ~declickLabel, val / ~declickMax, val.round(0.1).asString ++ " ms") }.defer;
        })
        .put(\abletonSyncMs, { |looper, what, val|
            { ~wireBar.(~syncSlider, ~syncLabel, (val / (2 * ~syncMax)) + 0.5,
                (if(val > 0) { "+" } { "" }) ++ val.round(0.1).asString ++ " ms") }.defer;
        })
        .put(\latencyMs, { |looper, what, val|
            { ~wireBar.(~latencySlider, ~latencyLabel, val / ~latencyMax, val.round(0.1).asString ++ " ms") }.defer;
        })
        // nil, or the recorded input itself, both mean "no clean tap" — item 0.
        .put(\analysisChannel, { |looper, what, val|
            var idx = if(val.notNil and: { val != looper.inChannel }) { 1 } { 0 };
            { ~analysisSourceMenu !? { |m| m.value = idx };
              ~statusAnalysisLabel !? { |t|
                t.string_(if(idx == 1) {
                    "Clean tap · dry ch " ++ (val + 1)
                } {
                    "Same as input (processed)"
                }) } }.defer;
        })
        // ---- the status band (gui-status.scd) and Perform's tiles ----------------------
        .put(\state, { |looper, what, val|
            { ~statusPaintState !? { |f| f.() };
              ~statusPaintTake !? { |f| f.() };
              ~performPaintLoop !? { |f| f.() };
              ~performPaintActions !? { |f| f.() } }.defer;
        })
        // A break is the looper deliberately going silent. With no indicator
        // that is indistinguishable from the audio having failed, which is the
        // last ambiguity you want on stage: the state block wears the hatch.
        .put(\break, { |looper, what, val|
            { ~statusPaintState !? { |f| f.() };
              ~performPaintCounting !? { |f| f.() } }.defer;
        })
        .put(\intensity, { |looper, what, val|
            { ~wireBar.(~intensitySlider, ~intensityLabel, val, val.round(0.01).asString) }.defer;
            // The Cutter's density row shows the value at FULL arc, so the
            // reading beside it has to follow the pedal or that row would be
            // telling only half the truth. The pedal is swept all set long:
            // at most every 50 ms.
            ~guiSoon.(\cutter, { ~performPaintCutter !? { |f| f.() }; ~bbcutRefreshDensity !? { |f| f.() } });
        })
        // Only the edges: the 30 Hz \dissolvePos stream is painted by the
        // shell's own poll, not by a deferred handler per frame.
        .put(\dissolving, { |looper, what, val|
            { ~statusPaintState !? { |f| f.() };
              ~performPaintCounting !? { |f| f.() } }.defer;
        })
        .put(\dissolveBars, { |looper, what, val|
            { ~dissolveBarsField !? { |f| if(f.isClosed.not) { f.value = val } };
              ~performPaintCounting !? { |f| f.() } }.defer;
        })
        .put(\breakLoops, { |looper, what, val|
            { ~breakLoopsField !? { |f| if(f.isClosed.not) { f.value = val } };
              ~performPaintCounting !? { |f| f.() } }.defer;
        })
        // A reading armed (val is the pending Event) or landed / cancelled
        // (nil). The countdown is painted by the shell's poll.
        .put(\reading, { |looper, what, val|
            { ~statusPaintTake !? { |f| f.() } }.defer;
        })
        .put(\readingIndex, { |looper, what, val|
            { ~statusPaintTake !? { |f| f.() } }.defer;
        })
        .put(\reverse, { |looper, what, val|
            { ~performPaintLoop !? { |f| f.() } }.defer;
        })
        .put(\granular, { |looper, what, val|
            { ~performPaintGrains !? { |f| f.() };
              ~granularPaintHeader !? { |f| f.() };
              ~guiRefreshTabs !? { |f| f.() } }.defer;
        })
        // An action the Looper would not take, from any surface: the footer
        // says so for 2.6 s, and the tile it was asked from stays dark.
        .put(\refused, { |looper, what, action, why|
            { ~guiSay !? { |f| f.("Refused: " ++ (why ? action), \bad) } }.defer;
        })
        // ---- Setup: analysis (gui-analysis.scd) -----------------------------------------
        .put(\onsetThreshold, { |looper, what, val|
            { ~wireBar.(~onsetThresholdSlider, ~onsetThresholdLabel,
                ~onsetThresholdSpec.unmap(val), val.round(0.01).asString);
              ~wireBar.(~analysisThresholdBar, ~analysisThresholdLabel,
                ~onsetThresholdSpec.unmap(val), val.round(0.01).asString);
              ~statusPaintThreshold !? { |f| f.() } }.defer;
        })
        .put(\analysisMonitor, { |looper, what, val|
            { ~analysisPaintMonitor !? { |f| f.() } }.defer;
        })
        .put(\analyzeOverdubs, { |looper, what, val|
            { ~overdubDetectButton !? { |b| if(b.isClosed.not) { b.value = if(val) { 1 } { 0 } } } }.defer;
        })
        // A successful overdub detection: report it where the tuning happens.
        // onAnalysis already handles Live and the export fields, and the
        // status band's take picks the new result up on its next poll.
        .put(\overdubDetected, { |looper, what, r|
            var txt = r[\numerator].asString ++ "/" ++ r[\denominator]
                ++ " @ " ++ r[\bpm].round(0.1) ++ " BPM · " ++ r[\k] ++ " bars · "
                ++ r[\onsetCount] ++ " onsets";
            { ~overdubDetectLabel !? { |t| if(t.isClosed.not) { t.string_(txt) } } }.defer;
        })
        .put(\transportMode, { |looper, what, val|
            { ~transportModeSeg !? { |s| ~guiSegSet.(s, ~transportModes.indexOf(val) ? 0) };
              ~performPaintActions !? { |f| f.() } }.defer;
        })
        .put(\inChannelCount, { |looper, what, val|
            { ~inChannelSeg !? { |s| ~guiSegSet.(s, ~inChannelCounts.indexOf(val) ? 0) } }.defer;
        });

    // ---- onset notes (gui-analysis.scd) ------------------------------------
    // Every one of these repaints the same small panel, so they share a single
    // handler rather than each carrying its own widget list. \onsetNotePattern
    // is the model telling us a take was analysed and the pattern changed size.
    [\onsetNotes, \onsetNote, \onsetNoteChannel, \onsetNoteVelLo, \onsetNoteVelHi,
     \onsetNoteDynRange, \onsetNoteGateMs, \onsetNoteOffsetMs,
     \onsetNoteChance, \onsetNotePattern].do { |key|
        ~looperController.put(key, { |looper, what, val|
            { ~onsetNotesRefresh !? { |f| f.() } }.defer;
        });
    };

    // ---- granular (gui-granular.scd, and Perform's Grains column) ---------
    // One handler per exposed parameter, generated from the same table that
    // renders the Grains pane, so adding a granular control never means
    // remembering to come back here. Morph is skipped: it has the hand-written
    // handler above, and SimpleController.put REPLACES by key — a second one
    // would silently orphan Perform's bar.
    //
    // Nil-guarded on the whole table: gui-granular.scd is optional, and a
    // session that never loaded it just gets no granular subscriptions.
    ~granularParams !? { |params|
        params.do { |p|
            if(p[\key] != \granularMorph) {
                ~looperController.put(p[\key], { |looper, what, val|
                    { ~granularRefreshOne !? { |f| f.(what, val) };
                      if(what == \granularAmp) { ~performPaintGrainAmp !? { |f| f.(val) } };
                      if(what == \granularPitch) { ~performPaintGrains !? { |f| f.() } } }.defer;
                });
            };
        };
        ~looperController.put(\granularEnv, { |looper, what, val|
            { ~granularEnvSeg !? { |s| ~granularPaintEnv !? { |f| f.(val) } };
              ~performPaintGrains !? { |f| f.() } }.defer;
        });
    };
};
)
