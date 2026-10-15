// The MIDI responders megalooper had before its router (setup-midimap.scd):
// setup-midi.scd's ~setupMidiBindings and ~ccHysteresis, and setup-sa.scd's
// ~saClaimsProgram and ~setupSABindings, as of 2026-10-08 (the commit before
// the router), copied verbatim apart from the four names, which have
// "legacy" in front so they can't replace the real ones. And the numbers they
// were bound to, as setup-midi.scd and setup-sa.scd had them until the maps
// became files, with phase 1's ~midiMapFromConstants, which made a map of
// them (setup-midimap.scd, commit c733608): the shipped maps are pinned to it
// (test-midimap-store.scd).
//
// test-midi-equivalence.scd loads this and drives these responders and the
// router with the same messages: the router must do exactly what they did.
// Never loaded by megalooper itself, and not a test of its own: run-tests.scd
// does not list it. Its MIDIdefs have megalooper's old names, so it is only
// loaded where no megalooper runs, and everything it registers is freed again.
(
// ==== The numbers, as setup-midi.scd had them ====================================
// ---- Note / program / CC assignments -------------------------------------
// The controller's physical buttons. Notes and programs do the same jobs on
// different controllers; the CCs are continuous or latching controls.
~triggerNote  = 60;
~stopNote     = 61;
~multiplyNote = 62;
~undoNote     = 63;
~reverseNote  = 64;
~clearNote    = 65;
~bbcutNote    = 66;
~nextLoopNote = 67;
// Drop the looper out right now, so the room can play into the hole; it comes
// back on a loop downbeat. Fire-and-forget: one stomp opens the hole and it
// closes itself. Also on program 7 below, for the controller that sends PCs.
~breakNote    = 68;
// Arm the ending. Pressed again while it runs, it aborts and restores.
~dissolveNote = 69;
// Record the whole set to disk. A toggle, and the only control here that has
// nothing to do with the loop: it is pressed before the first note and again
// at the end of the night. See LooperSessionRecorder.
~sessionRecNote = 70;
// The next reading of the take: the meter the analyser scored second, then
// third, round to its own answer. Lands on a loop boundary where Live's bar
// line agrees, never on the press. One switch, because on realistic takes the
// runner-up is the truth in a third of the wrong meters (roadmap item 9,
// docs/dev/meter-perception.md). Also program 19 below, and key A.
~nextReadingNote = 71;

~triggerProgram  = 4;
~clearProgram    = 5;
// Loop chaining. It lived on CC 80 until 2026-09-23, when that footswitch died
// and the function had to move onto a working one. 6 was Stop; Stop keeps note
// 61, the S key and the GUI button, but has no program of its own any more, so
// a PC-only controller can no longer stop playback from the floor. If that ever
// bites, give Stop a program outside 4-21 rather than taking 6 back — the
// chaining switch is the one that gets stomped mid-set. Every number from 4 to
// 21 is taken: the looper's own below (19 is the next reading), and on
// Megalooper SA 8-12, 14, 15 and 17, its effects' and drums' footswitches
// (setup-sa.scd), the programs the Live set maps to the same effects and to
// its drum rack.
//
// Raw program number, like every other program here: what MIDIdef.program
// reports, not what a controller labelling its programs 1-128 prints.
~nextLoopProgram = 6;
// 7 used to be Multiply, which is a studio move rather than a stage one — it
// never got stomped, while the break wants a footswitch on both controllers.
// Multiply keeps note 62, the M key and the GUI button.
~breakProgram    = 7;
// TWO programs for the cutter: 8 has been declared here from the start, 18 is
// where the controller in use actually sends. A list rather than a rename, so
// the older mapping keeps working — drop the 8 if it ever gets in the way.
~bbcutPrograms   = [8, 18];
// The onset-note part on and off from the controller — the drum part Live plays
// from the loop's own rhythm, which until now could only be toggled from the
// Analysis tab. A toggle, not a momentary: one press starts it, the next stops
// it and releases any note still gated.
//
// Raw program number, exactly as MIDIdef.program reports it, like the five
// above. A controller that labels its programs 1-128 calls this one 17.
~onsetNotesProgram = 16;
// The two recorders, on adjacent footswitches. They are SEPARATE controls on
// purpose: one writes megalooper's own files and starts the instant you press
// it, the other arms Live's arrangement, which cannot begin until the transport
// does. Wiring them together would have made the second switch a lie about the
// first (see "Recording the set" in docs/manual.md).
~sessionRecProgram = 20;   // megalooper's own session recording
~liveRecordProgram = 21;   // Live's arrangement record, over AbletonOSC
// The next reading, for the PC-sending controller — same thing as note 71. One
// of the numbers the note above ~nextLoopProgram lists as free.
~nextReadingProgram = 19;
// The granular layer on and off. Also a toggle, and the only footswitch it has
// ever had — key G and the two GUI buttons were the whole of it. Refused while
// no loop is recorded, in which case the layer simply stays off.
~granularProgram   = 13;

~granularMorphCc = 118;
~feedbackCc      = 4;
// Onset detection threshold, on the knob rather than only in the header. It is
// the ceiling on meter detection AND on the onset-note drum part, and the only
// way to set it is to sweep it while playing and watch the lamp.
//
// CC 7 is the MIDI-standard Channel Volume. Nothing here cares, but the proxy
// forwards every CC it sees straight to Live (setup-midimap.scd), so a Live track with
// MIDI input enabled on this channel will ride its volume off the same knob.
// If that ever bites, change this number — nothing else depends on it.
~onsetThresholdCc = 7;
// The TSMega's expression pedal flickers: at rest it hops one step back and
// forth on its own (68, 69, 68 on the SA rig), a few times a second and then
// not for seconds. Every hop set the onset threshold, so a threshold set with
// the header slider went back to the pedal's within seconds. So the two CCs
// that pedal has sent, ~feedbackCc until 2026-09-18 and ~onsetThresholdCc
// since, ignore a step back (their bindings' hysteresis in the router,
// LooperMidiMap.hysteresis): a move counts if it
// is two steps or more, or one step on in the direction of the last. Replayed
// over the MIDI log, the resting pedal sets the threshold once per launch
// instead of up to 1,720 times, and a played pedal stays within a step of
// where it is. 0 lets every change through, as before. docs/dev/midi-map.md, 3.2.
~pedalCcHysteresis = 1;
// The expression pedal. CC 11 is the MIDI-standard Expression controller, which
// is what most pedals send out of the box. It drives the granular layer's level
// and the cutter's density; heel is the dry loop with a cutter that barely
// chops and no grains, toe is everything as dialled in.
~intensityCc     = 11;
// The Blend section of the granular window: morph above, level here. These two
// stay up at 118/119 beside each other; the rest of the layer moved down to the
// contiguous block below.
~granularAmpCc      = 119;

// Everything in the granular window's Pitch, Grain and Read position sections,
// on one contiguous CC block, in the order the window lists them. Eight controls,
// eight CCs, so a bank of eight knobs maps straight onto the three sections
// without the player having to remember which knob is which.
//
//     40 Pitch        41 Detune       (Pitch)
//     42 Grain size   43 Density      44 Size rand     (Grain)
//     45 Position     46 Scan         47 Spray         (Read position)
//
// The window's grain-envelope menu is deliberately not here: it picks one of
// four shapes, and a continuous CC is the wrong control for that.
//
// This is a TABLE rather than eight named variables because every entry is
// handled identically — the router's map takes it in one loop, and re-ordering
// or re-numbering is a one-line edit. To move the block somewhere else on your
// controller, change ~granularCcBase and re-run ~setupMidiBindings.().
// check.scd asserts every key here exists and that no two bindings collide.
~granularCcBase = 40;
~granularCcMap = [
    \granularPitch, \granularDetune,
    \granularSize, \granularDensity, \granularSizeRand,
    \granularPosition, \granularScan, \granularSpray
];

// ==== And setup-sa.scd's ===========================================================
// The footswitches: the programs the Live set mapped the effects to, which
// is what the controller sends. 8-11 are the guitar's, 12, 14 and 15 the
// loop's. 8 is also one of the cutter's two programs (~bbcutPrograms), so on
// SA it is the delay alone and the cutter keeps 18, the one the controller
// uses for it.
~saFxPrograms = IdentityDictionary[
    8 -> \delay, 9 -> \pitchLoop, 10 -> \filter, 11 -> \shifter,
    12 -> \echo, 14 -> \saturator, 15 -> \redux
];

// And the drums' steps on and off, the program that switched the Live set's
// Rhythmic Steps rack (as CC 17 on channel 16, through the proxy). A true
// toggle here: in Live the first press after a boot sent "on" to a rack that
// was already on, so it took two presses to stop the drums. The onset kit
// ignores it, as in Live.
~saDrumsProgram = 17;

// Does SA take this program change? The router's map (setup-midimap.scd)
// binds these programs to SA's effects and drums on SA, and leaves them out of
// the looper's own there.
~saClaimsProgram = { |program|
    (~rp !? { |r| r[\sa] == true } ? false)
        and: { ~saFxPrograms.includesKey(program) or: { program == ~saDrumsProgram } }
};


// ==== The map phase 1 made of them (setup-midimap.scd) ===========================
// ---- The map, from today's numbers ---------------------------------------------
// Phase 1 has no map file. The bindings are made from the numbers in
// setup-midi.scd and setup-sa.scd, in the order those list them, so changing
// one there and re-running ~setupMidiBindings still works. Any channel and any
// input, as always. On SA (~rp[\sa]) its effects' and drums' programs come in,
// and the looper keeps none of those numbers: PC 8 is the delay there, and the
// cutter keeps 18. The pedal's two CCs ignore its flicker (~pedalCcHysteresis,
// taken as a whole number of steps, 0 to 64).
//
// Where two of the looper's notes or programs share a number, the first one
// listed keeps it, as the responders' `case` did; check.scd says so. Two CCs on
// one number both act, as their two responders did.
~midiMapFromConstants = {
    var out = List.new, taken = Set.new;
    var sa = (~rp !? { |r| r[\sa] == true }) ? false;
    var add = { |msg, num, target, extra|
        var b;
        if(num.notNil) {
            b = (msg: msg, num: num, target: target);
            extra !? { |x| b.putAll(x) };
            out.add(b);
        };
    };
    var first = { |msg, num, target|
        var key = msg.asString ++ " " ++ num;
        if(num.notNil and: { taken.includes(key).not }) { taken.add(key); add.(msg, num, target) };
    };
    var steps = ~pedalCcHysteresis ? 1;
    var pedal = (hysteresis: if(steps.isNumber) { steps.floor.asInteger.clip(0, 64) } { 1 });

    [
        [~triggerNote, 'looper.trigger'], [~stopNote, 'looper.stop'],
        [~multiplyNote, 'looper.multiply'], [~undoNote, 'looper.undo'],
        [~reverseNote, 'looper.reverse'], [~clearNote, 'looper.clear'],
        [~bbcutNote, 'looper.bbcut'], [~breakNote, 'looper.break'],
        [~dissolveNote, 'looper.dissolve'], [~sessionRecNote, 'looper.sessionRecording'],
        [~nextLoopNote, 'looper.recordNextLoop'], [~nextReadingNote, 'looper.nextReading']
    ].do { |p| first.(\note, p[0], p[1]) };

    ([
        [~triggerProgram, 'looper.trigger'], [~clearProgram, 'looper.clear'],
        [~nextLoopProgram, 'looper.recordNextLoop'], [~breakProgram, 'looper.break']
    ] ++ (~bbcutPrograms ? []).collect { |p| [p, 'looper.bbcut'] } ++ [
        [~sessionRecProgram, 'looper.sessionRecording'], [~liveRecordProgram, 'live.record'],
        [~onsetNotesProgram, 'looper.onsetNotes'], [~granularProgram, 'looper.granular'],
        [~nextReadingProgram, 'looper.nextReading']
    ]).reject { |p| (~saClaimsProgram !? { |f| f.(p[0]) }) ? false }.do { |p| first.(\program, p[0], p[1]) };
    if(sa) {
        (~saFxPrograms ? ()).keys.asArray.sort.do { |p|
            add.(\program, p, ("sa.fxOn." ++ ~saFxPrograms[p]).asSymbol);
        };
        add.(\program, ~saDrumsProgram, 'sa.drums.on');
    };

    add.(\cc, ~granularMorphCc, 'looper.granularMorph');
    add.(\cc, ~granularAmpCc, 'looper.granularAmp');
    ~granularCcBase !? { |base|
        (~granularCcMap ? []).do { |key, i| add.(\cc, base + i, ("looper." ++ key).asSymbol) };
    };
    add.(\cc, ~feedbackCc, 'looper.feedback', pedal);
    add.(\cc, ~onsetThresholdCc, 'looper.onsetThreshold', pedal);
    add.(\cc, ~intensityCc, 'looper.intensity');
    out.asArray
};


// ==== The responders ================================================================

// A CC binding's hysteresis, kept per controller and channel: a function of
// a message's (val, chan, src) that answers whether it moves the control
// (LooperMidiMap.hysteresis). One per binding, made with the bindings, so
// re-running ~legacySetupMidiBindings starts each afresh. 0 steps lets every
// message through, the same value again included, as before.
~legacyCcHysteresis = { |steps|
    var moves = IdentityDictionary.new;   // src -> [last, dir] per channel
    if((steps ? 1) <= 0) { { true } } {
        { |val, chan, src|
            var key = src ? 0;
            var byChan = moves[key];
            var was, move;
            if(byChan.isNil) { byChan = Array.newClear(16); moves.put(key, byChan) };
            was = byChan[chan ? 0];
            move = LooperMidiMap.hysteresis(was !? { |w| w[0] }, (was !? { |w| w[1] }) ? 0, val, steps);
            if(move.notNil) { byChan.put(chan ? 0, move) };
            move.notNil
        }
    }
};

// ---- Responders ----------------------------------------------------------
~legacySetupMidiBindings = {
    // The pedal's two bindings ignore its flicker (~pedalCcHysteresis).
    var feedbackMoves = ~legacyCcHysteresis.(~pedalCcHysteresis);
    var thresholdMoves = ~legacyCcHysteresis.(~pedalCcHysteresis);

    MIDIdef.noteOn(\midiLogNoteOn, { |vel, num, chan|
        ~midiLogLine.("noteOn   num=" ++ num ++ " vel=" ++ vel ++ " chan=" ++ chan);
    });
    MIDIdef.noteOff(\midiLogNoteOff, { |vel, num, chan|
        ~midiLogLine.("noteOff  num=" ++ num ++ " vel=" ++ vel ++ " chan=" ++ chan);
    });
    MIDIdef.cc(\midiLogCc, { |val, num, chan|
        ~midiLogLine.("cc       num=" ++ num ++ " val=" ++ val ++ " chan=" ++ chan);
    });
    // Program changes were logged inline in the looper's own binding below, which
    // meant they were only seen when they hit a mapped program. Log them here
    // with everything else instead, mapped or not.
    MIDIdef.program(\midiLogProgram, { |num, chan|
        ~midiLogLine.("program  prog=" ++ num ++ " chan=" ++ chan);
    });

    // ---- MIDI proxy: forward all controller messages to Live ----------
    // Re-send every incoming MIDI message out ~midiOut (the IAC bus Live
    // listens on), so the one external controller drives both the looper and
    // Live. ~midiOut already carries SC's MIDI clock + transport, so Live's
    // input gets clock and control data on the same port.
    //
    // We MUST skip messages whose source is the IAC bus itself: connectAll
    // listens to every source, so without this filter SC would hear its own
    // forwarded output and loop forever.
    // No sources before MIDIClient.init, as in the headless tests.
    ~iacSources = (MIDIClient.sources ? [])
        .select { |s| s.device.contains("IAC") }
        .collect { |s| s.uid };
    ~midiProxy = ~midiProxy ? true;  // set false in the IDE to disable proxying

    ~proxyOk = { |src| ~midiProxy and: { ~midiOut.notNil } and: { ~iacSources.includes(src).not } };

    // A "Device On" in Live is a toggle, so we alternate the value
    // (127 -> 0 -> 127 ...) per program on each press, giving Live a clean
    // on/off. If Live's state ever drifts (you toggled it by hand), the next
    // two presses resync it.
    ~pcCcState = IdentityDictionary.new;

    MIDIdef.noteOn(\proxyNoteOn, { |vel, num, chan, src|
        if(~proxyOk.(src)) { ~midiOut.noteOn(chan, num, vel) };
    });
    MIDIdef.noteOff(\proxyNoteOff, { |vel, num, chan, src|
        if(~proxyOk.(src)) { ~midiOut.noteOff(chan, num, vel) };
    });
    MIDIdef.cc(\proxyCc, { |val, num, chan, src|
        if(~proxyOk.(src)) { ~midiOut.control(chan, num, val) };
    });
    MIDIdef.program(\proxyProgram, { |num, chan, src|
        var on;
        if(~proxyOk.(src)) {
            ~midiOut.program(chan, num);   // raw PC too (Live ignores it; looper uses it)
            on = (~pcCcState[num] ? false).not;
            ~pcCcState[num] = on;
            ~midiOut.control(~pcCcChannel, num, if(on) { 127 } { 0 });
        };
    });
    MIDIdef.bend(\proxyBend, { |val, chan, src|
        if(~proxyOk.(src)) { ~midiOut.bend(chan, val) };
    });
    MIDIdef.touch(\proxyTouch, { |val, chan, src|
        if(~proxyOk.(src)) { ~midiOut.touch(chan, val) };
    });
    MIDIdef.polytouch(\proxyPolytouch, { |val, num, chan, src|
        if(~proxyOk.(src)) { ~midiOut.polyTouch(chan, num, val) };
    });

    // ---- Looper bindings ----------------------------------------------
    MIDIdef.cc(\looperGranularMorph, { |val|
        ~looper.granularMorph = val / 127;
    }, ccNum: ~granularMorphCc);

    // The rest of the granular CCs go through the SAME map the GUI sliders use
    // (from ~granularParams in gui-granular.scd), so a CC sweep and a mouse drag
    // cover the same range with the same law — Grain size is exponential in both
    // or in neither. Nil-guarded on the table: without that file loaded these
    // responders exist and quietly do nothing, rather than throwing per message.
    ~granularCcAction = { |key|
        { |val|
            ~granularParams !? { |params|
                params.detect { |p| p[\key] == key } !? { |p|
                    ~looper.perform(key.asSetter, ~granularMapValue.(p, val / 127));
                };
            };
        };
    };

    MIDIdef.cc(\looperGranularAmp,
        ~granularCcAction.(\granularAmp), ccNum: ~granularAmpCc);

    // One responder per entry in ~granularCcMap, numbered from ~granularCcBase.
    // The MIDIdef key is derived from the parameter name so each stays its own
    // responder — MIDIdef.freeAll in ~setupMidiIO clears the previous set, so
    // re-running this after changing the table leaves nothing stale behind.
    ~granularCcMap.do { |key, i|
        MIDIdef.cc(("looperCc_" ++ key).asSymbol,
            ~granularCcAction.(key), ccNum: ~granularCcBase + i);
    };

    MIDIdef.cc(\looperFeedback, { |val, num, chan, src|
        if(feedbackMoves.(val, chan, src)) { ~looper.feedback = val / 127 };
    }, ccNum: ~feedbackCc);

    // Onset threshold, through the SAME exponential spec the header slider
    // uses (gui-const.scd), so the knob and the slider cover one range with one
    // law — most of the travel at the low end, where the settings worth
    // telling apart are. A second copy of the curve here would drift from it.
    //
    // Nil-guarded on the spec for the same reason the granular block above is
    // guarded on its table: setup-midi.scd loads BEFORE gui-const.scd and has
    // to stay loadable on its own, so without it this responder exists and
    // quietly does nothing rather than throwing once per message.
    MIDIdef.cc(\looperOnsetThreshold, { |val, num, chan, src|
        ~onsetThresholdSpec !? { |spec|
            if(thresholdMoves.(val, chan, src)) {
                ~looper.onsetThreshold = spec.map(val / 127);
            };
        };
    }, ccNum: ~onsetThresholdCc);

    // The expression pedal. Straight 0..1 with no curve: the arc's own shape
    // lives in the mix functions on Looper, and bending it here as well would
    // make the pedal's feel depend on where that shaping happened.
    MIDIdef.cc(\looperIntensity, { |val|
        ~looper.intensity = val / 127;
    }, ccNum: ~intensityCc);

    MIDIdef.noteOn(\looperBindings, { |vel, num|
        case
            { num == ~triggerNote }  { ~looper.trigger }
            { num == ~stopNote }     { ~looper.stopPlayback }
            { num == ~multiplyNote } { ~looper.multiply }
            { num == ~undoNote }     { ~looper.undo }
            { num == ~reverseNote }  { ~looper.reverse }
            { num == ~clearNote }    { ~looper.clear }
            // 66 and program 8 were declared here from the start and never had
            // a branch, so the cutter footswitch docs/manual.md documents has never
            // actually worked.
            { num == ~bbcutNote }    { ~looper.bbcut = ~looper.bbcut.not }
            { num == ~breakNote }    { ~looper.fireBreak }
            { num == ~dissolveNote } { ~looper.toggleDissolve }
            // Nothing else here is a set-level control; this one is, and it is
            // deliberately reachable from the same pedalboard as the transport.
            { num == ~sessionRecNote } { ~looper.toggleSessionRecording }
            { num == ~nextLoopNote } { ~looper.recordNextLoop }
            // Fire-and-forget like the break: one stomp arms the next reading,
            // another while it is armed moves on to the one after.
            { num == ~nextReadingNote } { ~looper.nextReading };
    });

    MIDIdef.program(\looperProgramBindings, { |program, chan|
        case
            // Megalooper SA's guitar effects take a few programs of their own
            // (setup-sa.scd); one of them is also a cutter program here.
            { ~legacySaClaimsProgram !? { |f| f.(program) } ? false } { }
            { program == ~triggerProgram }  { ~looper.trigger }
            { program == ~clearProgram }    { ~looper.clear }
            // Was Stop until 2026-09-23; see ~nextLoopProgram above.
            // recordNextLoop is itself a toggle, so one stomp is one action
            // (arm, then stop, then arm again) — same as note 67 and key N.
            { program == ~nextLoopProgram } { ~looper.recordNextLoop }
            { program == ~breakProgram }    { ~looper.fireBreak }
            { ~bbcutPrograms.includes(program) }
                                            { ~looper.bbcut = ~looper.bbcut.not }
            { program == ~sessionRecProgram } { ~looper.toggleSessionRecording }
            // Live's recorder, not ours: it goes out over AbletonOSC, so it is
            // defined in setup-model.scd beside the rest of the Live traffic.
            // Nil-guarded like the granular table above — without that file
            // loaded this branch does nothing rather than throwing per press.
            { program == ~liveRecordProgram } {
                ~liveRecordToggle !? { |f| f.() } }
            { program == ~onsetNotesProgram } {
                ~looper.onsetNotes = ~looper.onsetNotes.not }
            { program == ~granularProgram } { ~looper.toggleGranular }
            { program == ~nextReadingProgram } { ~looper.nextReading };
    });
};

// Does SA take this program change? The looper's own bindings
// (setup-midi.scd) skip the ones it does.
~legacySaClaimsProgram = { |program|
    (~rp !? { |r| r[\sa] == true } ? false)
        and: { ~saFxPrograms.includesKey(program) or: { program == ~saDrumsProgram } }
};

~legacySetupSABindings = {
    MIDIdef.program(\saFxBindings, { |program|
        ~saFxPrograms[program] !? { |key| ~megaSA !? { |m| m.toggleFx(key) } };
        if(program == ~saDrumsProgram) { ~megaSA !? { |m| m.drums !? { |d| d.toggleOn } } };
    });
};
)
