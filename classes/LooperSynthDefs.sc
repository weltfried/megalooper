// megalooper — the Looper's sound, as graphs: every SynthDef a Looper plays,
// and the pieces they share. Pure class methods: they build with no server and
// no Looper, so an offline render (scripts/sa/nrt-*.scd, replay-session.scd,
// strength-check.scd) builds exactly what a take plays. Until 2026-11-08 these
// were the Looper's own (docs/dev/architecture.md 3.3 and 5, step 8); the
// Looper's loadSynthDefs asks for them here.
//
// test-source-guards.scd holds the shared pieces to one definition each (the
// onset chain, its strength and report, the tap gain, the input), and
// test-synthdefs.scd builds every def and checks its controls.
LooperSynthDefs {

    // ---- SynthDef graph pieces ------------------------------------------
    //
    // Shared by several defs below. They are called from INSIDE a graph
    // function, so the UGens they create — LocalBuf included — land in the
    // def being built.

    // The onset-detection chain, in ONE place.
    //
    // Four defs need it: both recorders, the analysis monitor that drives the
    // tuning lamp, and the overdub analyser. Each used to carry its own copy,
    // with a comment asking whoever edited one to remember the others. That
    // mattered more than it sounds — if the monitor detects differently from
    // the recorder then the lamp lies about what a take will actually detect,
    // and onset quality is the limiting factor on meter detection.
    //
    // threshold (default 0.5) + mingap 20 (~107 ms): the old 0.3 /
    // default-gap detection admitted near-silent ghost onsets and sub-100 ms
    // double-triggers on percussive guitar, which threw off the meter grid fit
    // (a straight 4/4 take mis-detected as 7/8). Validated offline against the
    // training-data loops — see scripts/eval_meter_analyzer.scd. The threshold
    // is an ARGUMENT so it can be tuned live against the input; mingap stays
    // fixed because Onsets sizes internal state from it.
    *onsetTrig { |sig, threshold|
        ^Onsets.kr(FFT(LocalBuf(512), sig), threshold, \rcomplex, mingap: 20)
    }

    // Onset salience: the RMS of the 70 ms that end onsetReportDelay after the
    // trigger, so of the hit from 40 ms before the detector fired (it fires
    // 10–40 ms after the attack) to 30 ms after. Read at onsetReport's
    // trigger. Feeds MeterAnalyzer's accent test, the onset notes' velocities
    // and the analysis window's readout, so the number on screen is only
    // honest while this is the same everywhere.
    //
    // Until 2026-11-05 this was Amplitude.kr(sig, 0.001, 0.1) at the trigger,
    // which runs 64 times too fast on an audio input: a 1.6 ms release, so it
    // read the waveform's phase. Measured (scripts/strength-check.scd): equal
    // synthetic hits spread 3–5 dB under it and 0.3–1.2 dB under this; on the
    // duo's riffs the same note in two bars correlated 0.02 under it and 0.26
    // under this; and gerade-3, a 4/4 read as 12/8, reads right. A window
    // that ends at the trigger needs no wait, but on sharp attacks it measures
    // the previous note. RunningSum keeps no drift: a quiet sine after an hour
    // of loud noise read within 0.3 % of its RMS.
    *onsetStrength { |sig| ^RunningSum.rms(sig, (SampleRate.ir * 0.07).round) }

    // How long after the trigger an onset is reported, seconds: the end of
    // onsetStrength's window. Every reply stamps the trigger's own time
    // (or loop position) latched AT the trigger, so only the message is late.
    *onsetReportDelay { ^0.03 }
    *onsetReport { |trig| ^TDelay.kr(trig, LooperSynthDefs.onsetReportDelay) }

    // The automatic level, as an analysis synth reads it: the tracker's gain
    // from `bus`, or unity with no bus (-1) or before the tracker has written
    // one (a control bus starts at 0).
    *tapGain { |bus|
        var raw = In.kr(bus.max(0));
        ^Select.kr((bus >= 0) * (raw > 0), [1, raw])
    }

    // The tap-level tracker (\looperTapLevel): one synth from boot, listening
    // to the analysis input and writing to a control bus the gain that brings
    // its recent peak to `target`. Why: at a fixed threshold Onsets.kr hears
    // the same take differently at another level (its whitening floor sits at
    // a fixed level), and 10 dB changed half of 20 labelled readings; scaled to
    // one peak first, a take reads the same at any level (measured 2026-11-05).
    //
    //   - A peak above the one held is taken at once: playing louder turns the
    //     gain down within a block.
    //   - The held peak is kept for `hold` seconds after the last one that
    //     reached it (longer than a bar, so a riff's accents keep it flat), then
    //     eases down at `decayDb` per second: playing quieter is followed
    //     within about ten seconds.
    //   - It eases only while someone plays: `body` (a 0.5 s envelope, so the
    //     gaps between notes count) over `gate` and within `window` of the
    //     held peak. Silence and hum hold it, so the gain cannot creep up to
    //     meet the noise between songs.
    //   - Nothing played yet: unity, which is detection as it was.
    //   - The gain stays within lo..hi (-12 to +40 dB): +30 left the
    //     quietest set heard (-31 dBFS peaks) a dB short, and one reading moved.
    // Analysis synths follow it live rather than latching it per take: the
    // first loud hit of a take corrects a gain left high by quiet playing.
    // Measured in NRT on a scripted input: -20 dBFS plucks +20 dB; a hit at
    // -6 drops it to +6 and 30 s of hum at -46 leave it there; back at -20 it
    // is +20 again within 7 s; 10 dB quieter is followed within 10 s. And
    // the 20 labelled takes, with the tracker warm (it heard the take once)
    // and the detector built from these helpers, read the same from -20 to
    // +6 dB: 207-208 onsets, no reading moved (the old chain: 87-222, 10-13
    // readings moved).
    // t_reset forgets the held peak (a new analysis input).
    *tapLevelGraph {
        ^{ |ana = 0, out = 0, target = 0.891, gate = 0.00316, window = 0.0316, hold = 4, decayDb = 2,
            lo = 0.25, hi = 100, replyRate = 2, t_reset = 0|
            var sig = SoundIn.ar(ana);
            var env = A2K.kr(Amplitude.ar(sig, 0.0005, 0.02));
            var body = A2K.kr(Amplitude.ar(sig, 0.0005, 0.5));
            var held = LocalIn.kr(1) * (t_reset <= 0);
            var playing = (body > gate) * (body > (held * window));
            var refresh = playing * (env >= held);
            var since = Sweep.kr(refresh, 1);
            var decayed = held * (decayDb.neg / ControlRate.ir).dbamp;
            var next = Select.kr(refresh, [Select.kr(playing * (since > hold), [held, decayed]), env]);
            var gain = Select.kr(next > 0, [1, (target / next.max(1e-6)).clip(lo, hi)]);
            LocalOut.kr(next);
            Out.kr(out, gain);
            SendReply.kr(Impulse.kr(replyRate), '/looperTapLevel', [gain, next]);
        }
    }

    // One hardware channel doubled, or a stereo pair.
    //
    // `mono` on this and the three builders below is a LANGUAGE-side flag, not
    // a SynthDef argument: SoundIn's channel count is fixed when the graph is
    // built, so this cannot be one def with a switch. Each builder is instead
    // instantiated twice, under the two names the rest of the class already
    // chooses between by inChannelCount.
    *input { |mono, ch|
        ^if(mono) { SoundIn.ar(ch).dup } { SoundIn.ar([ch, ch + 1]) }
    }

    // The recorder: fills the loop buffer while driving onset + pitch analysis.
    //
    // Analysis reads its OWN input, so a clean tap straight off the interface
    // can drive onset/pitch detection while the buffer records the processed
    // guitar from `in`. The tap is MONO on purpose: it is one hardware input
    // (the guitar), and reading `ana + 1` too would spill onto whatever sits
    // next — past the input block that is a private bus, and the looper's own
    // output bus is the first one allocated. With ana == in this analyses the
    // left channel rather than the old L+R sum; for a centred guitar that is
    // the same signal, and for a stereo-reverbed one it is if anything cleaner.
    *recGraph { |mono|
        ^{ |bufnum, in=0, ana=0, onsetThreshold=0.5, tapGainBus = -1|
            var sig = LooperSynthDefs.input(mono, in);
            var anaRaw = SoundIn.ar(ana);
            // The onsets and their strengths hear the tap at the automatic
            // level; the pitch and the levels below hear it as it arrives.
            var gain = LooperSynthDefs.tapGain(tapGainBus);
            var anaSig = anaRaw * gain;
            var trig = LooperSynthDefs.onsetTrig(anaSig, onsetThreshold);
            var time = Sweep.kr(1, 1);
            // Tartini emits [freq, hasFreq]; we tick a 25 Hz pulse gated by
            // hasFreq so SendReply only fires while a stable pitch is detected.
            var tartini = Tartini.kr(anaRaw);
            var pitchTrig = Impulse.kr(25) * tartini[1];
            var amp = Amplitude.kr(anaRaw);
            var onsetStrength = LooperSynthDefs.onsetStrength(anaSig);
            // Peak of the tap and of the recorded input over the take so far.
            // A tap 30 dB under the input is a starved analyser, and the "0
            // onsets" warning does not catch it once the threshold has been
            // lowered to chase it — four sets were analysed from 4 to 6 onsets
            // that way (roadmap item 6). Reported four times a second so the
            // language has the figure when the take ends, with the gain the
            // take is analysed at. Both peaks are the raw signals' through the
            // same envelope, so the comparison is like for like.
            var tapPeak = RunningMax.kr(Amplitude.kr(anaRaw, 0.001, 0.2), 0);
            var inPeak  = RunningMax.kr(Amplitude.kr(Mix(sig) * 0.5, 0.001, 0.2), 0);
            SendReply.kr(LooperSynthDefs.onsetReport(trig), '/looperOnset',
                [Latch.kr(time, trig), A2K.kr(onsetStrength)]);
            SendReply.kr(pitchTrig, '/looperPitch', [time, tartini[0], amp]);
            SendReply.kr(Impulse.kr(4), '/looperLevels', [tapPeak, inPeak, gain]);
            RecordBuf.ar(sig, bufnum, loop: 0);
        }
    }

    // Plain recorder for loop chaining: the guitar (in) summed with the
    // processed loop-return from Live (ret, its own stereo pair), no analysis.
    // The new loop inherits tempo/signature from the current one. ret lives on
    // different channels than in, so normal overdubs — which read in alone —
    // never re-record the loop's own output.
    *recPlainGraph { |mono|
        ^{ |bufnum, in=0, ret=0|
            var guitar = LooperSynthDefs.input(mono, in);
            var sig = guitar + SoundIn.ar([ret, ret + 1]);
            RecordBuf.ar(sig, bufnum, loop: 0);
        }
    }

    // How many chords of a take the grains can follow: the rest play as the
    // last of these.
    *chordSlots { ^32 }

    // The granular voice's graph (loadSynthDefs adds it as \looperGranular), a
    // class method as engineGraph is, so a render can build it with no
    // Looper (scripts/sa/nrt-grains.scd).
    *granularGraph {
        ^{ |bufnum, startFrame=0, loopFrames=44100,
             tau=0.5, morph=0, amp=0.3, out=0,
             pitch=0, detune=0, size=1, density=1,
             sizeRand=0.1, position=0, scan=0, sprayMs=0,
             envbuf= -1, phaseBus=0, locked=0, rate=1, follow=0, chordPeriod=0|
            var bufFrames = BufFrames.kr(bufnum);
            var bufSr = BufSampleRate.kr(bufnum);
            // Warp1's pointer is normalised over the WHOLE buffer, so any
            // absolute-time control has to convert through the buffer duration,
            // not the loop's.
            var bufSecs = bufFrames / bufSr;
            var loopDur = loopFrames / bufSr;
            var startNorm = startFrame / bufFrames;
            var loopNorm = loopFrames / bufFrames;
            var m = Lag.kr(morph.clip(0, 1), 0.1);
            var windowSize = ((((1 - m) * 0.4) + (m * tau))
                * Lag.kr(size, 0.1)).clip(0.001, 4);
            // Overlaps is clipped hard: Warp1 runs one grain stream per overlap,
            // and this is the parameter that runs the CPU up. 16 is already past
            // musically useful and keeps a full-tilt density slider from stalling
            // the server mid-take.
            var overlaps = ((((1 - m) * 6) + (m * 1))
                * Lag.kr(density, 0.1)).clip(0.5, 16);
            // Warp1 latches its per-grain values when a grain starts, and it
            // starts them at overlaps/windowSize. Stepping noise at that rate is
            // therefore per-GRAIN randomness (the classic granular shimmer and
            // spray) rather than one drift applied to the whole cloud at once.
            var grainRate = (overlaps / windowSize).clip(0.1, 500);
            // Passes through the loop region per loopDur. Negative scans backwards.
            // `rate` is the engine's, signed: -1 reversed, 0.5 at half-time
            // (docs/dev/rc600-picks.md, 3b). Morph's share of the scan moves as
            // the loop does; `scan`, the player's own drift, does not.
            var scanRate = ((m * rate) + Lag.kr(scan, 0.1)) / loopDur;
            var jitterAmt = (1 - m) * 0.005;
            var sprayAmt = Lag.kr(sprayMs.max(0), 0.1) / 1000 / bufSecs;
            // The scan pointer. `freeScan` is what this always was: a phasor at
            // scanRate from wherever the synth was spawned. At morph 1 that is
            // one pass per loop — but in whatever phase the toggle happened to
            // land on, so "grain N reads beat N" held only by luck, and every
            // toggle put the pulse somewhere else. Heard on the rig, 2026-09-25,
            // after docs/dev/signals.md read it off this graph.
            //
            // `lock` is the constant phase difference between where the dry
            // engine actually is — phaseBus, which it publishes in seconds —
            // and a one-pass-per-loop phasor started with this synth. Adding
            // morph's SHARE of it leaves the drone end and every intermediate
            // drift exactly as they were, up to a fixed phase shift, and makes
            // the pulsed end read exactly where the dry loop is reading: with
            // scan at 0 the two phasors are the same UGen from the same start,
            // and the sum reduces to the engine's own position. Reverse is
            // inherited the same way. Over a STOPPED loop there is no engine and
            // the bus is stale, so the layer is spawned with `locked` = 0 and
            // scans freely as before; spawnEngine sets it to 1 once the loop
            // plays. The wrap keeps the correction inside half a loop either
            // way, so morph's share of it is continuous.
            // `onePass` moves as the engine does (`rate`), so `lock` stays a
            // constant reversed or at half-time too; with it at 1 it drifted
            // whenever the engine didn't play forwards at 1, and morph's share
            // of it jumped once a pass.
            var enginePos = In.kr(phaseBus) / loopDur;
            var onePass   = LFSaw.kr(rate / loopDur, 1).range(0, 1);
            var lock      = (enginePos - onePass).wrap(-0.5, 0.5) * locked;
            var freeScan  = LFSaw.kr(scanRate, 1).range(0, 1);
            var scanPhase = (freeScan + (m * lock)).wrap(0, 1);
            var jitter = LFNoise2.kr(20).range(jitterAmt.neg, jitterAmt)
                + (LFNoise0.kr(grainRate) * sprayAmt);
            // Wrapped, so Position offsets WITHIN the loop region and can never
            // walk the pointer off its end into the rest of the buffer. Spray is
            // added outside the wrap on purpose: blurring across the loop seam is
            // the point of it.
            var frac = (scanPhase + Lag.kr(position, 0.1)).wrap(0, 1);
            var pointer = startNorm + (frac * loopNorm) + jitter;
            // Following the chords (granularFollowChords, roadmap item 8): the
            // grains transposed by the interval from the chord where they read
            // (frac) to the chord the loop plays now (the engine's phase), the
            // nearer way round (-6..+5 semitones). At morph 1 they read where
            // the loop is, so nothing moves; a drone frozen in one chord
            // follows the loop's changes. The chords are the take's segments
            // (Looper.prGranularChordArgs): their starts in seconds within the
            // length they were found in (chordPeriod: a multiplied loop repeats
            // it), unused slots past any time, and their roots as pitch
            // classes. Only while locked to a moving engine, and not within
            // 20 ms of the playhead, so the grains reading where it is never
            // flicker across a boundary. A loop of one chord moves nothing.
            var rootAt = { |secs|
                var p = secs.mod(chordPeriod.max(1e-3));
                Select.kr(((\chordStarts.kr(1e9 ! LooperSynthDefs.chordSlots) <= p).sum - 1).max(0),
                    \chordRoots.kr(0 ! LooperSynthDefs.chordSlots))
            };
            var readSecs = frac * loopDur, nowSecs = In.kr(phaseBus);
            var gap = (readSecs - nowSecs).mod(loopDur.max(1e-3));
            var away = gap.min(loopDur - gap) > 0.02;
            var shift = (((rootAt.(nowSecs) - rootAt.(readSecs)) + 6).mod(12) - 6)
                * (follow > 0) * locked * away * (chordPeriod > 0);
            var freqScale = (Lag.kr(pitch, 0.05) + shift
                + (LFNoise0.kr(grainRate) * Lag.kr(detune.max(0), 0.1))).midiratio;
            // interp 4 (cubic), up from the old 1 (none): with transposition now
            // exposed, no interpolation aliases audibly at anything but unity.
            var sig = Warp1.ar(2, bufnum, pointer, freqScale, windowSize,
                envbuf, overlaps, sizeRand.clip(0, 1), 4);
            Out.ar(out, sig * Lag.kr(amp.max(0), 0.05));
    }
    }

    // The engine: plays the loop, overdubs into it, publishes its phase.
    //
    // readInterp and writeInterp are BufRd's interpolation for what is played
    // and for what is written back. The defaults are the engine; the graph as
    // it was before 2026-10-27 is (2, 2), which scripts/sa/nrt-engine-rate.scd
    // builds to show its check catches what changed.
    *engineGraph { |mono, readInterp = 4, writeInterp = 1|
        ^{ |bufnum, in=0, startFrame=0, loopFrames=44100,
            amp=1.0, out=0, rate=1, recEnable=0,
            latencyFrames=0, feedback=1.0, declickFrames=0,
            gateMode=0, gateBus=0, phaseBus=0|
            var input = LooperSynthDefs.input(mono, in);
            // Half-time (docs/dev/rc600-picks.md, 3a): the playhead's speed is
            // `speed` (1 or 0.5) as it was when a reference that always runs
            // at ±1 last wrapped. Until half-time the engine and the reference
            // are the same Phasor, so a speed set at any time in a pass takes
            // over on the sample the loop starts again; at half speed the
            // engine wraps on every other reference wrap, so one set in the
            // second half of its pass takes over on the sample the pass ends.
            // The language picks the pass; the server picks the sample. An
            // audio-rate control, as K2A would ramp a new speed over the block
            // it came in and the latch could take a value between.
            var speed = \speed.ar(1);
            // The direction, ±1 (reverse, 2026-11-06), latched the same way:
            // a pass starts on the loop's seam in either direction, so one
            // set at any time in a pass takes over on the sample the next
            // begins, and the loop's boundaries stay where they were (the
            // drums' bar line with them). Flipped mid-pass, the playhead turned
            // where it was and every boundary after moved. A new engine
            // starts at rate 1 with its direction here; `rate` stays the
            // playback rate the offline checks drive.
            var dir = \dir.ar(1);
            var ref = Phasor.ar(0, rate * BufRateScale.kr(bufnum), startFrame, startFrame + loopFrames);
            var wrapped = (ref - Delay1.ar(ref)).abs > (loopFrames * 0.5);
            var speedNow = Latch.ar(speed, wrapped + Impulse.ar(0));
            var dirNow = Latch.ar(dir, wrapped + Impulse.ar(0));
            // An audio-rate trigger (DC, never fires): with a constant one
            // Phasor reads its rate once a block, and the speed would change
            // on the block after the wrap, not on it.
            var phase = Phasor.ar(DC.ar(0),
                rate * dirNow * speedNow * BufRateScale.kr(bufnum),
                startFrame,
                startFrame + loopFrames);
            // Cubic: at rate ±1 every position is a whole frame, where cubic
            // gives the sample itself, so normal and reverse playback are
            // exact; at any other rate it sounds better than linear.
            var existing = BufRd.ar(2, bufnum, phase, loop: 0, interpolation: readInterp);
            // Short fade in/out at the loop seam to kill the wrap-point click
            // (level jump from loop end back to start, plus any record on/off
            // transient baked into the buffer). loopPhase is 0..loopFrames
            // regardless of play direction, so both ends are covered.
            var loopPhase = phase - startFrame;
            var df = declickFrames.max(1);
            var declick = (loopPhase / df).min((loopFrames - loopPhase) / df).clip(0, 1);
            // Shift the write head backward (in playback direction) by the
            // round-trip audio latency so an overdub played in time with what's
            // heard lands at the matching loop position. Rounded to whole
            // frames, so the write head has the play head's fraction at any
            // rate (latencyFrames is whole; rate × it need not be).
            var writePhase = (phase - ((rate * dirNow) * latencyFrames).round - startFrame)
                .mod(loopFrames) + startFrame;
            // The sample under the write head, read back WITHOUT interpolation:
            // BufWr writes on every block, recording or not, so in playback
            // this must be an identity. At rate ±1 every position is a whole
            // frame and any interpolation is; at half speed each frame is
            // visited twice, and a linear read would write the average of it
            // and its neighbour back on the second visit — a half-sample shift
            // and a low-pass on every pass, for good.
            var atWrite = BufRd.ar(2, bufnum, writePhase, loop: 0, interpolation: writeInterp);
            // Feedback only applies while overdubbing — in pure playback the
            // buffer must pass through untouched (multiplier = 1).
            var writeFeedback = Select.kr(recEnable, [1.0, feedback]);
            // BBCut mix mode against the cutter: 0 = pass (off / \mix),
            // 1 = mute (\gate), 2 = insert (duck only while gateBus reports a
            // repetition). Lagged so the duck fades rather than clicks.
            var bbGate = Lag.kr(
                Select.kr(gateMode, [1, 0, 1 - In.kr(gateBus)]),
                0.005);
            // Publish where in the loop the playhead is, in seconds, for the
            // overdub analyser to latch at each onset. READ position, not write:
            // a note played along with what is heard arrives on the dry tap at
            // the moment the playhead is there, and its wet twin is written at
            // exactly that spot by the latency-shifted write head. So this is
            // where the played note lands in the buffer.
            Out.kr(phaseBus, A2K.kr(loopPhase) / BufSampleRate.kr(bufnum));
            BufWr.ar((atWrite * writeFeedback) + (input * recEnable),
                bufnum, writePhase);
            // Output the pre-overdub buffer content only — live input is not
            // monitored, so the player only hears their addition on the next
            // loop pass.
            Out.ar(out, existing * amp * declick * bbGate);
        }
    }

    *loadSynthDefs {
        SynthDef(\looperRec,     LooperSynthDefs.recGraph(false)).add;
        SynthDef(\looperRecMono, LooperSynthDefs.recGraph(true)).add;

        // Free-running analysis monitor for the onset-tuning lamp. It shares
        // the recorder's detection chain by construction rather than by hand,
        // which is the whole point: the lamp fires exactly when a real take
        // would detect a hit.
        //
        // TWO reports, on deliberately different clocks:
        //
        //   /looperMonitor       level only, at replyRate — the input meters.
        //                        15 Hz is as fast as a meter can be read; the
        //                        language pays for every one of these frames
        //                        (an OSC dispatch plus whatever the GUI does
        //                        with it), so the rate is the CPU bill.
        //   /looperMonitorOnset  one message per ONSET, sent on the trigger
        //                        itself, carrying its strength and the level
        //                        at that instant.
        //
        // Sending onsets on their own trigger rather than as a flag polled at
        // replyRate is what lets the level rate drop: the report no longer has
        // to be fast enough to catch a single-frame event. It is also strictly
        // more accurate — no Trig1 stretch, no frame quantisation, and no way
        // for two onsets inside one frame to be reported as one.
        // The level meter reads the input as it arrives; the onsets hear it
        // at the automatic level, as a take would. An onset is reported
        // onsetReportDelay after its trigger (the strength's window), which the
        // responder takes off the time it heard it.
        SynthDef(\looperAnalysisMonitor, { |ana=0, onsetThreshold=0.5, replyRate=15, tapGainBus = -1|
            var raw   = SoundIn.ar(ana);
            var sig   = raw * LooperSynthDefs.tapGain(tapGainBus);
            var trig  = LooperSynthDefs.onsetTrig(sig, onsetThreshold);
            var level = Amplitude.kr(raw, 0.005, 0.05);
            var strength = LooperSynthDefs.onsetStrength(sig);
            SendReply.kr(Impulse.kr(replyRate), '/looperMonitor', [level]);
            SendReply.kr(LooperSynthDefs.onsetReport(trig), '/looperMonitorOnset', [A2K.kr(strength), level]);
        }).add;

        // Overdub meter detection. Same chain again, but instead of a Sweep
        // timebase it latches the engine's published loop position at each
        // onset — so events arrive already in LOOP coordinates and no
        // wall-clock arithmetic is needed to fold several passes onto one grid.
        // Must run AFTER the engine in the node order (Synth.tail) or In.kr
        // reads the previous block's phase.
        SynthDef(\looperOverdubAnalysis, { |ana=0, onsetThreshold=0.5, phaseBus=0, tapGainBus = -1|
            var sig  = SoundIn.ar(ana) * LooperSynthDefs.tapGain(tapGainBus);
            var trig = LooperSynthDefs.onsetTrig(sig, onsetThreshold);
            var strength = LooperSynthDefs.onsetStrength(sig);
            var loopPos  = Latch.kr(In.kr(phaseBus), trig);
            SendReply.kr(LooperSynthDefs.onsetReport(trig), '/looperOverdubOnset', [loopPos, A2K.kr(strength)]);
        }).add;

        SynthDef(\looperTapLevel, LooperSynthDefs.tapLevelGraph).add;

        LooperSessionRecorder.loadSynthDefs;

        SynthDef(\looperRecPlain,     LooperSynthDefs.recPlainGraph(false)).add;
        SynthDef(\looperRecPlainMono, LooperSynthDefs.recPlainGraph(true)).add;

        SynthDef(\looperEngine,     LooperSynthDefs.engineGraph(false)).add;
        SynthDef(\looperEngineMono, LooperSynthDefs.engineGraph(true)).add;
        SynthDef(\looperClick, { |freq=900, amp=0.25|
            var env = EnvGen.kr(Env.perc(0.001, 0.04), doneAction: 2);
            Out.ar(0, (SinOsc.ar(freq) * env * amp).dup);
        }).add;

        // Brick-wall limiter on the summed output of engine + granular, at
        // unity: the loop goes on at the level it was played, and a sum too
        // hot comes out at 0.95 at most. Sits at the tail so it always runs
        // after the audio sources. Its level was a slider on Perform (Looper
        // level, 0.7 to start) until 2026-11-07: a level into the Loop chain
        // set nothing the Loop strip after it does not, so it went.
        SynthDef(\looperMaster, { |inBus, out=0, breakAmp=1|
            var sig = In.ar(inBus, 2);
            // The break gate. 5 ms is fast enough to feel instantaneous under
            // a foot and slow enough not to click.
            //
            // After the limiter, not before: muting ahead of it would pump the
            // gain reduction on the way in and out of every break.
            var gate = Lag.kr(breakAmp, 0.005);
            Out.ar(out, Limiter.ar(sig, 0.95, 0.01) * gate);
        }).add;

        // The granular voice. `morph` is still the meta-control — it sets the
        // BASE of the texture between frozen drone (0) and beat-locked pulsed
        // scan (1) — and every other control bends that base from a NEUTRAL
        // default, so the untouched synth is bit-for-bit the old one.
        //
        // Multiplicative where morph's base is never zero (size, density);
        // ADDITIVE where the base is zero at one pole (scan, spray). A
        // multiplier there would be dead exactly where you want the control:
        // no amount of scaling gets a frozen drone to drift.
        SynthDef(\looperGranular, LooperSynthDefs.granularGraph).add;
    }
}
