// megalooper — the cutter: BBCut over the loop, one to four voices, each its
// own cut procedure, synth, effects and clock ratio over one shared snapshot
// of the loop, layered for polyrhythm (Mix, Insert or Gate against the dry
// loop), and its presets' data, validation and apply.
//
// A part of the Looper (docs/dev/architecture.md 5, step 8; the Looper's own
// until 2026-11-08): it holds the Looper and asks it for the loop it cuts
// (loopFrames, lastResult, server, speed, intensity; the next boundary and
// the speed after it; the arc's level, prBBCutMix) and for the engine's side
// of a cut (prEngineGate: duck or mute the dry loop; prWriteLoop: the loop to
// disk for BBCutBuffer; the out and insert busses), and says its changes as
// the Looper's (looper.changed: \bbcut, \bbcutMode, \bbcutVoices,
// \bbcutState). The Looper's bbcut* and voice methods are its facade.
LooperCutter {
    var looper;
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

    *new { |looper| ^super.newCopyArgs(looper).initBBCut }

    *presetFormat { ^"megalooper bbcut" }

    // Cmd-period freed every node and stopped every routine: the cutter is off.
    forget {
        bbcutEnableRoutine = nil;
        bbcutEnabling = false;
        if(bbcut) { bbcut = false; looper.changed(\bbcut, false) };
    }

    // The arc moved: every voice at its level times the arc's.
    applyMix {
        bbcutVoices !? { |voices|
            voices.do { |v| v[\mixer] !? { |m| m.volume_(v[\amp] * looper.prBBCutMix) } };
        };
    }

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
                        hint: "Chance a repeat is a double-looper.speed roll instead of a plain repeat.")
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
                // the part that reads as looper.intensity.
                intensityKey: \stutterchance,
                params: [
                    (key: \sdiv,          label: "Chop",    lo: 2, hi: 32, default: 8,   int: true,
                        hint: "Slices per loop pass — the cut grid. Higher = finer, busier chopping."),
                    (key: \phraselength,  label: "Phrase",  lo: 2, hi: 32, default: 24,  int: true, slider: true,
                        hint: "Phrase length in beats. Rounds to whole loop passes; new cut pattern each phrase."),
                    (key: \stutterchance, label: "Stutter", lo: 0, hi: 1,  default: 0.2, int: false,
                        hint: "Chance (0–1) that a phrase ends in a stutter — a repeating one-slice roll."),
                    (key: \stutterspeed,  label: "StutSpd", lo: 1, hi: 8,  default: 2,   int: true,
                        hint: "Stutter looper.speed as a multiple of the chop grid (2 = twice as fast).")
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
            // live looper.server resources, set at spawn / cleared at free
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
            looper.prEngineGate(this.bbcutGateCode);
        };
        looper.changed(\bbcutMode, bbcutMode);
    }

    enableBBCut {
        var tau, totalBeats, loopDur, outBusIdx, path, baseBps;
        if(looper.loopFrames == 0 or: { looper.lastResult.isNil } or: { looper.lastResult.tau.isNil }) {
            "BBCut: no analyzed loop available.".warn;
            ^looper.prRefused(\bbcut, "the cutter needs an analysed take")
        };
        if(bbcutEnabling) { ^this };
        bbcutEnabling = true;

        tau = looper.lastResult.tau;
        // Pulses-as-beats: the BBCut clock ticks once per detected pulse, and
        // beatlength = total pulses in the loop. For 7/8 (sub=1, k=1) that's
        // a 7-beat phrase; for 4/4 with eighth-note sub=2, an 8-beat phrase.
        totalBeats = MeterAnalyzer.unitsOf(looper.lastResult) * looper.lastResult.sub;
        loopDur = looper.loopFrames / looper.server.sampleRate;
        outBusIdx = looper.prOutBusIndex;
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
                looper.prWriteLoop(path);
                looper.server.sync;

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
                // The next boundary, and the looper.speed after it: at half-time
                // (rc600-picks.md, 3b) the end of a half-looper.speed pass, and a landing
                // or an end of half-time armed for it, so the cutter comes in at
                // the looper.speed the loop will play.
                cutSpeed = looper.prSpeedAfterNext;
                untilNextBoundary = (looper.prNextBoundaryAt(SystemClock.seconds) - SystemClock.seconds).max(0);
                untilNextBoundary.wait;

                this.teardownBBCut;
                bbcutBuffer = newBuffer;
                sp = this.bbcutSpawnParams(cutSpeed);
                bbcutVoices.do { |voice|
                    if(voice[\enabled]) {
                        this.spawnBBCutVoice(voice, sp);
                    };
                };

                looper.prEngineGate(this.bbcutGateCode);

                bbcut = true;
                bbcutEnabling = false;
                looper.changed(\bbcut, true);
                ("BBCut on (" ++ totalBeats ++ " beats @ "
                    ++ baseBps.round(0.01) ++ " bps, "
                    ++ this.bbcutActiveVoiceCount ++ " voice(s)).").postln;
                bbcutEnableRoutine = nil;
            } { |err|
                bbcutEnabling = false;
                bbcutEnableRoutine = nil;
                err.reportError;
                looper.prRefused(\bbcut, "the cutter could not start (" ++ err.errorString ++ ")");
            };
        }.play;
    }

    // Spawn params common to every voice this play, derived from the analysis.
    // `looper.loopFrames`/`looper.lastResult` are stable during playback. At half-time
    // (`cutSpeed` 0.5, the loop's looper.speed by default) the cutter's clocks run at
    // half tempo, so its cuts play an octave down and twice as long, as the
    // loop does: `baseBps` scaled, `tau` a pulse in wall time.
    bbcutSpawnParams { |cutSpeed|
        var tau = looper.lastResult.tau;
        cutSpeed = cutSpeed ? looper.speed;
        ^(
            tau:        tau / cutSpeed,
            totalBeats: MeterAnalyzer.unitsOf(looper.lastResult) * looper.lastResult.sub,
            outBusIdx:  looper.prOutBusIndex,
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
        var mixer  = CutMixer(sp[\outBusIdx], voice[\amp] * looper.prBBCutMix,
            ampfunc, voice[\pan]);
        // Drives the insert-duck bus (1 while a repetition plays). Emits no
        // audio; only active in \insert mode, so \mix / \gate are unaffected.
        var gate   = LooperCutGate(looper.prInsertBusIndex, { this.bbcutInsertMode });
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
        looper.prEngineGate(0);
        if(bbcut) {
            bbcut = false;
            looper.changed(\bbcut, false);
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
        bbcutEnableRoutine = looper.prStopRoutine(bbcutEnableRoutine);
        bbcutEnabling = false;
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
            var elapsed = SystemClock.seconds - (looper.passStart ? SystemClock.seconds);
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

    bbcutVoiceCount { ^bbcutVoices.size }

    addBBCutVoice {
        var voice;
        if(bbcutVoices.size >= 4) {
            "BBCut: max 4 voices.".warn;
            ^looper.prRefused(\bbcutVoices, "four voices at most")
        };
        voice = this.defaultBBCutVoice;
        bbcutVoices.add(voice);
        // Fade the new voice in on the next beat without touching the others.
        if(bbcut and: { bbcutBuffer.notNil }) {
            var sp = this.bbcutSpawnParams;
            Routine {
                var beatDur = sp[\tau];
                var elapsed = SystemClock.seconds - (looper.passStart ? SystemClock.seconds);
                (beatDur - (elapsed % beatDur)).wait;
                this.spawnBBCutVoice(voice, sp);
            }.play;
        };
        looper.changed(\bbcutVoices, bbcutVoices);
    }

    removeBBCutVoice { |i|
        if(bbcutVoices.size <= 1) {
            "BBCut: need at least one voice.".warn;
            ^looper.prRefused(\bbcutVoices, "the cutter needs at least one voice")
        };
        if(i.notNil and: { i < bbcutVoices.size }) {
            // Free only this voice; the others keep playing uninterrupted.
            this.prRemoveBBCutVoiceAt(i);
            looper.changed(\bbcutVoices, bbcutVoices);
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

    setVoiceProc { |i, sym|
        var v = bbcutVoices[i];
        if(v.isNil or: { bbcutProcSpecs[sym].isNil }) { ^this };
        v[\proc] = sym;
        // Each proc has its own param set, so reset to that proc's defaults.
        v[\params] = this.defaultParamsFor(sym);
        this.respawnBBCutVoice(i);
        looper.changed(\bbcutVoices, bbcutVoices);
    }

    setVoiceSynth { |i, sym|
        var v = bbcutVoices[i];
        if(v.isNil or: { this.bbcutSynthKeys.includes(sym).not }) { ^this };
        v[\synth] = sym;
        this.respawnBBCutVoice(i);
        looper.changed(\bbcutVoices, bbcutVoices);
    }

    setVoiceFx { |i, symArray|
        var v = bbcutVoices[i];
        if(v.isNil) { ^this };
        v[\fx] = (symArray ? []).select { |k| bbcutFxSpecs[k].notNil };
        this.respawnBBCutVoice(i);
        looper.changed(\bbcutVoices, bbcutVoices);
    }

    setVoiceRatio { |i, ratio|
        var v = bbcutVoices[i];
        if(v.isNil) { ^this };
        // Ratio sets the clock tempo, so it can only change by respawning.
        v[\ratio] = ratio.max(0.01);
        this.respawnBBCutVoice(i);
        looper.changed(\bbcutVoices, bbcutVoices);
    }

    setVoiceAmp { |i, amp|
        var v = bbcutVoices[i];
        if(v.isNil) { ^this };
        v[\amp] = amp.clip(0, 1);
        v[\mixer] !? { |m| m.volume_(v[\amp] * looper.prBBCutMix) };
        looper.changed(\bbcutVoices, bbcutVoices);
    }

    setVoicePan { |i, pan|
        var v = bbcutVoices[i];
        if(v.isNil) { ^this };
        v[\pan] = pan.clip(-1, 1);
        v[\mixer] !? { |m| m.panfunc_(v[\pan]) };
        looper.changed(\bbcutVoices, bbcutVoices);
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
        looper.changed(\bbcutVoices, bbcutVoices);
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
        ^MegaFiles.eventText(data, LooperCutter.presetFormat, Looper.prPresetFamilies[\bbcut][\order])
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
        looper.changed(\bbcutVoices, bbcutVoices);  // MVC contract
        looper.changed(\bbcutState, bbcutVoices);   // coarse: the GUI's rebuild hook
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
        voice[\mixer] !? { |m| m.volume_(vd[\amp] * looper.prBBCutMix); m.panfunc_(vd[\pan]) };
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
        ^floor + ((stored - floor) * looper.intensity)
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

    // One line each, for the save confirmation in the post window.
    prBBCutPresetSummary { |data|
        ^data[\voices].size.asString ++ " voice(s), " ++ data[\mode]
    }
}
