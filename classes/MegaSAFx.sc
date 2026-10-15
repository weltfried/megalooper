// The guitar's effects before the amp, in the Live set's order: Shifter,
// Delay (with the LFO beside it), Auto Filter, PitchLoop89; Bias FX comes
// after them (docs/dev/megalooper-sa.md, Phase 2). Then the loop's: Echo,
// Saturator, Redux (Phase 3). Each is rebuilt in SC from megalooper-slave.als
// as Live plays it: most of these devices sit in racks whose macros drive
// their knobs, and Live leaves a macro-driven knob's own stored value frozen,
// so the values here are the macros' (resolved through Live's own knob
// curves, fitted from its factory racks), not the stored ones the first
// rebuild copied. The racks' other macro variations are in
// presets/sa/fx-variations.json. These are approximations of Live's devices,
// to be judged by ear; every setting a player may move is a named control in
// the table below (*params), which MegaSA keeps and the Effects tab draws.
//
// Each effect is a device of its own (docs/dev/device-chains.md): one synth per
// effect, in its chain's group, reading the chain's bus and writing it back
// with ReplaceOut, so the synths' order is the chain's. Each sits in a slot
// that cross-fades between the dry and the effected signal on its own <key>On
// control, so a footswitch never clicks. All of them run all the time; a slot
// that is off costs its CPU, and a delay that comes on has its last moments
// already in its line.
//
// The guitar's are written mono: the chain feeds Bias FX, which the Live set
// hosts mono, so where a Live device had separate left and right sides they
// are summed. Their devices hear the sum of the chain's two sides and write
// their effect to both (the types' `width`, below). The loop's are stereo, as
// the Looper's output is.
MegaSAFx {
    classvar paramList, paramIndex, typeList;

    // Chain order, and the order of the switches in the GUI.
    *guitarKeys { ^[\shifter, \delay, \filter, \pitchLoop] }
    // The loop's, after the Looper (Phase 3), in the Live set's order on its
    // "looper guitar" track.
    *loopKeys { ^[\echo, \saturator, \redux] }
    *keys { ^this.guitarKeys ++ this.loopKeys }

    // What an effect is called. Megalooper's own names since release 1.0: the
    // effects were built after devices of Ableton Live and went by those
    // devices' names until then (titleBefore). The keys never changed, so
    // every MIDI map and every sound still finds its effect.
    *title { |key|
        ^(shifter: "Pitch Shift", delay: "Dual Delay", filter: "Envelope Filter", pitchLoop: "Pitch Loops",
            echo: "Tape Echo", saturator: "Drive", redux: "Crusher")[key] ?? { key.asString }
    }

    *titleBefore { |key|
        ^(shifter: "Shifter", delay: "Delay", filter: "Auto Filter", pitchLoop: "PitchLoop89",
            echo: "Echo", saturator: "Saturator", redux: "Redux")[key] ?? { key.asString }
    }

    // A device's name as megalooper gives it: its type's title, and for a
    // further one its number, "Dual Delay 2".
    *nameFor { |id, type, title|
        ^(title ?? { this.title(type) }) ++ if(id == type) { "" } { " " ++ id.asString.drop(type.asString.size) }
    }

    // A name read from a sound: the one megalooper gave the device before
    // 1.0 ("Delay", "Delay 2") becomes the one it gives now; any other name
    // is the player's own and stays.
    *nameNow { |id, type, name|
        ^if(name.notNil and: { name == this.nameFor(id, type, this.titleBefore(type)) }) { this.nameFor(id, type) } { name }
    }

    // Dry or effected, cross-faded over 30 ms. Sanitize first: an effect that
    // ever produced inf or NaN would otherwise poison the chain even switched
    // off, since the crossfade's 0 * NaN is NaN, and Bias FX after it.
    *slot { |dry, onName, wet|
        ^XFade2.ar(dry, Sanitize.ar(wet), (Lag.kr(onName.kr(0), 0.03) * 2) - 1)
    }

    // An envelope follower with the times it is given, at control rate.
    // Amplitude.kr on an audio signal runs its attack and release one block
    // (64x) faster than asked (measured in NRT, SC 3.14.1), which left the
    // first rebuild's 250 ms release at 4 ms. The audio-rate one has the real
    // times; they are for 20 dB.
    *follow { |sig, attack, release| ^A2K.kr(Amplitude.ar(sig, attack, release)) }

    // ---- The guitar's effects -------------------------------------------

    // Live's Shifter in pitch mode, not in a rack: coarse 0, fully wet. Fine is
    // the open question. Live stores 0.496 of a -1..1 range there, most likely
    // +50 ct (or +25), and in Live it followed CC 7, the threshold knob, which
    // SA does not do (decision 2026-10-05). The first rebuild read it as 0.5 ct,
    // nearly transparent, and SA keeps that until it is set by ear.
    //
    // Two ways to shift, Mode (2026-10-15): PitchShift, and FFT,
    // PV_PitchShift on 1024-frame frames. Live's 80 ms window smeared every
    // attack over about 21 ms; measured offline on plucks, 40 ms halves that at
    // the same latency, and the FFT smears a little less again with a steadier
    // pitch, about 8 ms later.
    //
    // PitchShift with its settings exposed, to play with (the same day): its
    // window is fixed when the synth starts, so one PitchShift runs for each of
    // shifterWindows and Window crossfades to the one picked (they are cheap: a
    // delay line each). Pitch and time spread are PitchShift's pitchDispersion
    // and timeDispersion, the latter a share of the window (it may not exceed
    // it). Everything runs all the time, so every switch is a 50 ms crossfade
    // that can be made while playing.
    *shifterWindows { ^#[0.01, 0.02, 0.03, 0.04, 0.06, 0.08, 0.12, 0.2] }

    *shifter { |sig|
        var semis = (\shifterCoarse.kr(0) + (\shifterCents.kr(0.5) / 100)).clip(-24, 24);
        var ratio = semis.midiratio;
        var pitchSpread = \shifterPitchSpread.kr(0), timeSpread = \shifterTimeSpread.kr(0);
        var grain = SelectX.ar(\shifterWindow.kr(3).lag(0.05),
            this.shifterWindows.collect { |w| PitchShift.ar(sig, w, ratio, pitchSpread, timeSpread * w) });
        var fft = IFFT(PV_PitchShift(FFT(LocalBuf(1024), sig), ratio));
        var wet = SelectX.ar(\shifterMode.kr(0).lag(0.05), [grain, fft]);
        var mix = \shifterMix.kr(1);
        ^(sig * (1 - mix)) + (wet * mix)
    }

    // Live's Delay as its rack ("verstimmer", the 'long' variation) plays it:
    // taps at 1 ms and 438 ms (left and right in Live), no feedback, fully
    // wet, the time modulated by a sine whose rate the M4L LFO beside it
    // wanders (9.45 Hz, depth 57.5 %, shape Stray, smoothed). The 1 ms tap is
    // a near-dry copy; the 438 ms one an echo the modulation detunes.
    //
    // Live stores neither how far its "Time 100 %" moves the delay time (here
    // +/-0.5 %) nor the curve of its Rate knob: the LFO's 57.5 % of the
    // 0.01-40 Hz range is taken as 0.01-1.2 Hz on a log knob. The taps are
    // summed at 0.55 each, so their peaks stay under full scale into Bias FX;
    // feedback (none in the set) runs through tanh so it cannot run away. Time
    // changes glide (Lag), as Live's Repitch does. LocalIn hears the previous
    // block, so what goes round is read one block (1.3 ms) early and each
    // repeat comes back after exactly its tap's time; below a block it cannot.
    *delay { |sig|
        var rate = LFDNoise3.kr(\delayLfoHz.kr(9.448819)).range(\delayLfoMin.kr(0.01), \delayLfoMax.kr(1.176184));
        var mod = SinOsc.kr(rate) * \delayModDepth.kr(0.005);
        var timeL = Lag.kr(\delayTimeL.kr(0.001), 0.1) * (1 + mod);
        var timeR = Lag.kr(\delayTimeR.kr(0.437855), 0.1) * (1 - mod);
        var back = LocalIn.ar(2).tanh * \delayFeedback.kr(0);
        var inL = sig + back[0];
        var inR = sig + back[1];
        var near = DelayC.ar(inL, 2.7, timeL);
        var far = DelayC.ar(inR, 2.7, timeR);
        var taps = (near + far) * 0.55;
        var mix = \delayMix.kr(1) * 0.5pi;
        LocalOut.ar([DelayC.ar(inL, 2.7, (timeL - ControlDur.ir).max(0)),
            DelayC.ar(inR, 2.7, (timeR - ControlDur.ir).max(0))]);
        // The rack's Delay mixes equal-loudness (its DryWetMode 1), taken here
        // as equal power; at the set's 100 % only the taps are heard.
        ^(sig * mix.cos) + (taps * mix.sin)
    }

    // Live 12's Auto Filter as its rack "filter" plays it: the Morph type
    // (low-pass through band-pass to high-pass, 24 dB), at Morph 16 % mostly
    // low-pass, about 311 Hz, resonance 31 %, the LFO a Ramp Up at one cycle
    // per beat (Triplet 3/8) and 89 %, the envelope at +76 % (1 ms attack,
    // 250 ms release), soft clip at the output, no makeup (Live has none).
    //
    // How far Live's 100 % moves the frequency is not documented: the LFO's is
    // taken as 3 octaves each way, the envelope's as 4 octaves. Sense (how hard
    // a pick must be to reach the top) is SA's own. Not built: Live's circuits
    // (the set uses MS2), the LFO's Morph (-90 % in the set) and its stereo
    // spin, and the LFO's lock to the bar: it runs at the loop's tempo but
    // from its own phase.
    *filter { |sig|
        var beats = \filterLfoBeats.kr(1);
        var rate = Select.kr(beats > 0,
            [\filterLfoHz.kr(1.00031), (beats.max(0.0625) * \beatDur.kr(0.6, 0.4)).reciprocal]);
        var lfo = Select.kr(\filterLfoWave.kr(4), [
            SinOsc.kr(rate),             // Sine
            LFTri.kr(rate),              // Triangle
            LFSaw.kr(rate).neg,          // Saw
            (LFPulse.kr(rate) * 2) - 1,  // Square
            LFSaw.kr(rate),              // Ramp Up
            LFSaw.kr(rate).neg,          // Ramp Down
            LFDNoise3.kr(rate * 2),      // Wander
            LFDNoise0.kr(rate * 2)       // S&H
        ]) * (\filterLfoAmount.kr(0.89187) * 3);
        var env = (this.follow(sig, 0.001, \filterRelease.kr(0.25)) * \filterSense.kr(3)).clip(0, 1);
        // Res 0 is a plain 24 dB slope, 100 % a Q of 20 on one of the two
        // stages (both resonating would peak at Q squared, +52 dB).
        var rq = 1.414 * ((0.05 / 1.414) ** \filterRes.kr(0.307884));
        // SC's RLPF, RHPF, BPF and BRF turn unstable once freq * rq passes
        // half the sample rate. The plain stage's rq is the widest, so the
        // cutoff stays under that: about 15 kHz at 48 kHz.
        var top = ((SampleRate.ir * 0.45) / 1.414).min(18000);
        var freq = (\filterFreq.kr(311.094842) * (2 ** ((env * (\filterEnvAmount.kr(0.756379) * 4)) + lfo)))
            .clip(30, top);
        var lp = RLPF.ar(RLPF.ar(sig, freq, rq), freq, 1.414);
        var bp = BPF.ar(BPF.ar(sig, freq, rq), freq, rq);
        var hp = RHPF.ar(RHPF.ar(sig, freq, rq), freq, 1.414);
        var notch = BRF.ar(BRF.ar(sig, freq, rq), freq, rq);
        var morph = SelectX.ar(\filterMorph.kr(0.1641) * 2, [lp, bp, hp]);
        var wet = Select.ar(\filterType.kr(4), [lp, hp, bp, notch, morph]);
        // SA's own, off as in Live: brings a quiet filtered sound back
        // towards the dry level (slow followers, at most 20x).
        var makeup = ((this.follow(sig, 0.05, 0.5) / this.follow(wet, 0.05, 0.5).max(0.0001))
            .clip(1, 20)) ** \filterMakeup.kr(0);
        ^(wet * makeup).tanh * \filterOutput.kr(0).dbamp
    }

    // PitchLoop89 as its rack ("pitchloop 7er") plays it: two voices reading
    // pieces of the last six seconds back out. The left voice reverses 289 ms
    // pieces a fifth up (+7 st, the rack's Macro 1), starting 796 ms back
    // (Macro 2) plus a sine LFO (1.98 Hz, up to 688 ms more, taken once per
    // piece); the right voice plays 289 ms pieces forwards an octave up, at
    // least 290 ms back (a pitched-up piece must not catch up with the input)
    // plus up to 33 ms at random. Both through a 50 Hz low cut and an 11 kHz
    // high cut at -5.5 dB, mixed equal-power, 37 % wet. The device's positions
    // are % of its 1.8375 s memory; here they are seconds.
    //
    // Pieces overlap twice with Hann windows, where PitchLoop89 butts them with
    // 25 ms crossfades at zero crossings, so the joins are softer. Live pans
    // the voices hard left and right into the mono Bias FX; here each comes in
    // at half, as a (L + R) / 2 fold would give. Hold, the Short and Back
    // switches and vibrato are not built.
    //
    // Each voice has what the other has: an LFO and a random distance on its
    // start (the set used the left's LFO and the right's random only, so the
    // other two start at nothing). Feedback (0 in the set) puts the two
    // voices back into the memory, after the filters and softened, so each
    // pass is shifted again. It goes one block late through a short buffer
    // of its own, as LocalIn would carry it: this effect cannot use LocalIn,
    // because the offline render (scripts/sa/nrt-chains.scd) builds one
    // SynthDef of the Delay and this, and a SynthDef has one LocalIn.
    //
    // A piece must never cross the write head. While a reversed piece plays
    // (2 * seg / ratio long), the distance behind the input grows by
    // 2 * seg * (1 + 1 / ratio); a forward one's changes by
    // 2 * seg * (1 / ratio - 1), shrinking when pitched up. The segment lengths
    // and positions are held to what keeps every piece inside the memory: six
    // seconds (PitchLoop89 has 1.84), so that low and long settings still fit.
    // At -24 st with the set's 289 ms pieces the reversed voice can reach about
    // 3 s back.
    *pitchLoop { |sig|
        // Cleared once: a LocalBuf comes from the real-time pool as whatever
        // was there, and the pieces read far back before it is first filled.
        var buf = LocalBuf(288000, 1).clear;
        var frames = BufFrames.ir(buf);
        var sr = SampleRate.ir;
        var bufDur = frames / sr;
        var write = Phasor.ar(0, 1, 0, frames);
        var mix = \pitchLoopMix.kr(0.37);
        var ratioL = \pitchLoopPitchL.kr(7).midiratio;
        var spanL = 2 * (1 + ratioL.reciprocal);
        var segL = \pitchLoopSegL.kr(0.2892).min((bufDur - 0.012) / spanL);
        var playL = segL / ratioL;
        var trigL = Impulse.ar(playL.reciprocal);
        var lfoL = ((SinOsc.kr(\pitchLoopLfoRateL.kr(1.978)) + 1) * 0.5) * \pitchLoopLfoL.kr(0.6876);
        var backL = (\pitchLoopPosL.kr(0.795768) + lfoL + TRand.ar(0, \pitchLoopRandL.kr(0), trigL))
            .clip(0.002, bufDur - (segL * spanL) - 0.01);
        var ratioR = \pitchLoopPitchR.kr(12).midiratio;
        var segR = \pitchLoopSegR.kr(0.2892)
            .min((bufDur - 0.012) / ((2 * (1 - ratioR.reciprocal).abs).max(1e-6)));
        var playR = segR / ratioR;
        var trigR = Impulse.ar(playR.reciprocal);
        // How far a forward piece closes on the input (negative: falls back).
        var drift = 2 * segR * (1 - ratioR.reciprocal);
        var lfoR = ((SinOsc.kr(\pitchLoopLfoRateR.kr(1)) + 1) * 0.5) * \pitchLoopLfoR.kr(0);
        var backR = (\pitchLoopPosR.kr(0.1302).max(drift.max(0) + 0.002) + lfoR
            + TRand.ar(0, \pitchLoopRandR.kr(0.0326), trigR))
            .min(bufDur - 0.01 - drift.neg.max(0));
        var hiCut = \pitchLoopHiCut.kr(11068);
        // The feedback's own short memory: what the voices were one block ago.
        var fbFrames = 2048;
        var fbBuf = LocalBuf(fbFrames, 1).clear;
        var fbWrite = Phasor.ar(0, 1, 0, fbFrames);
        var fed = BufRd.ar(1, fbBuf, (fbWrite - BlockSize.ir).wrap(0, fbFrames), 1, 1) * \pitchLoopFeedback.kr(0);
        var left, right, voices, wet;
        BufWr.ar(sig + fed, buf, write);
        left = GrainBuf.ar(1, trigL, playL * 2, buf, ratioL.neg,
            ((write - (backL * sr)) / frames).wrap(0, 1), 4);
        right = GrainBuf.ar(1, trigR, playR * 2, buf, ratioR,
            ((write - (backR * sr)) / frames).wrap(0, 1), 4);
        voices = LPF.ar(HPF.ar(left, 50), hiCut) + LPF.ar(HPF.ar(right, 50), hiCut);
        BufWr.ar((voices * 0.5).tanh, fbBuf, fbWrite);
        wet = voices * (0.5 * \pitchLoopOutput.kr(-5.45).dbamp);
        ^(sig * (mix * 0.5pi).cos) + (wet * (mix * 0.5pi).sin)
    }

    // ---- The loop's effects ---------------------------------------------
    // Stereo, as the Looper's output is; each effect runs per channel.

    // Live's Echo on the loop, not in a rack: Mid/Side, the mid line a dotted
    // 1/32 and the side line a dotted 1/8 at the loop's tempo, so on the mono
    // loop only the mid's slap is heard (about 68 ms at 165 BPM). Feedback
    // 16.7 %, the repeats band-limited to 520 Hz - 3.1 kHz, ducked under the
    // loop (-29 dB, 98 ms), wobble, a sine LFO on the time and the low-pass
    // (one cycle per two beats), a little reverb after the delay, the output
    // +6 dB on the wet, Dry/Wet 66 % linear. `beatDur` is one beat of the
    // loop's tempo; MegaSA sets it from every analysis, and it glides, as the
    // set's Repitch does.
    //
    // Dry/Wet is Live's linear crossfade, so with the Echo on the loop itself
    // drops to a third (Live's Output acts on the processed signal only, its
    // manual says). Not built: Live's recorded wobble curves (LFDNoise3 here),
    // the envelope half of its modulation (Env Mix 51 %), the filters'
    // resonance, the side line's +9.8 % offset; the duck is a fixed -14 dB.
    *echo { |sig|
        var beat = \beatDur.kr(0.6, 0.4);
        var times = [\echoBeatsL.kr(0.1875, 0.4), \echoBeatsR.kr(0.75, 0.4)] * beat;
        var wobble = LFDNoise3.kr([0.7, 0.9], \echoWobble.kr(0.234) * 0.0128);
        var lfo = SinOsc.kr(1 / (beat * 2), [0, 0.5pi]);
        var fb = LocalIn.ar(2);
        var duck = LagUD.kr(this.follow(sig.sum * 0.5, 0.005, 0.1) > \echoDuckThresh.kr(-29.06).dbamp,
            0.005, \echoDuckRelease.kr(0.0976));
        var ms = \echoMidSide.kr(1, 0.05);
        var x = (sig * (1 - ms)) + ([sig[0] + sig[1], sig[0] - sig[1]] * (ms * 0.5));
        var mix = \echoMix.kr(0.6587);
        var wet = DelayC.ar(x + (fb * \echoFeedback.kr(0.1667).clip(0, 0.9)), 2.5,
            times * (1 + wobble + (lfo * 0.002)));
        wet = LPF.ar(HPF.ar(wet, \echoHp.kr(520.1).clip(20, 18000)),
            (\echoLp.kr(3142.4) * (2 ** (lfo * 0.6))).clip(20, 18000));
        LocalOut.ar(wet);
        wet = (wet * (1 - ms)) + ([wet[0] + wet[1], wet[0] - wet[1]] * ms);
        wet = wet + (FreeVerb2.ar(wet[0], wet[1], 1, \echoReverbDecay.kr(0.273), 0.5)
            * \echoReverb.kr(0.198));
        wet = wet * (1 - (duck * 0.8)) * \echoOutput.kr(6.03).dbamp;
        ^(sig * (1 - mix)) + (wet * mix)
    }

    // Live's Saturator as its rack "wavetable" plays it: Medium Curve (a tanh
    // here), Drive +6.5 dB, the Color section with the lows (Amt Lo, a 250 Hz
    // shelf) +35.8 dB and a band around 108 Hz (Amt Hi) +8.6 dB, Output
    // -9.6 dB, 57 % wet. As in Live, the colour EQ is applied before the curve
    // and inverted after it, so it decides how hard each band distorts and the
    // tone stays roughly flat.
    //
    // The rack's macros as the set left them look like a press of its Rand
    // button; its own variations (guitar-playback, brutal, obertöne, ...) are
    // in presets/sa/fx-variations.json. The other curves are SC stand-ins for
    // Live's; Bass Shaper and Waveshaper are not built. No oversampling.
    *saturator { |sig|
        var base = \saturatorBase.kr(35.819816, 0.05);
        var freq = \saturatorFreq.kr(108.377052, 0.05);
        var width = \saturatorWidth.kr(0.843046, 0.05);
        var depth = \saturatorDepth.kr(8.635303, 0.05);
        var mix = \saturatorMix.kr(0.566929, 0.05);
        var x = BPeakEQ.ar(BLowShelf.ar(sig, 250, 1, base), freq, width, depth)
            * \saturatorDrive.kr(6.499551, 0.05).dbamp;
        x = Select.ar(\saturatorType.kr(3), [
            x.softclip,                        // Analog Clip (stand-in)
            x.clip2(0.5pi).sin,                // Soft Sine (stand-in)
            x.softclip,                        // Bass Shaper: not built, not offered
            x.tanh,                            // Medium Curve
            x / (((x.abs ** 4) + 1) ** 0.25),  // Hard Curve (stand-in)
            x.sin,                             // Sinoid Fold (stand-in)
            x.clip2(1)                         // Digital Clip
        ]);
        x = BPeakEQ.ar(BLowShelf.ar(x, 250, 1, base.neg), freq, width, depth.neg)
            * \saturatorOutput.kr(-9.628804, 0.05).dbamp;
        ^(sig * (1 - mix)) + (x * mix)
    }

    // Live 12's Redux as its rack "redux" plays it: about 7.2 kHz with a little
    // jitter, 5 bits with DC Shift, both filters off, 80 % wet. The sample and
    // hold is on the server's sample grid, so a rate is a whole number of
    // samples per step. DC Shift is a mid-rise quantizer (floor plus half a
    // step), which puts silence at +1/(2 * steps); LeakDC, which is SA's and not
    // Live's, takes that offset out before the speakers. The filters, when on,
    // are 24 dB low-passes at half the reduced rate (pre) and at that times
    // 2^Post Freq (post): Live's own are not documented. Live's Quantizer Shape
    // (3.9 % from the macros) is not built.
    *redux { |sig|
        var rate = \reduxRate.kr(7240.085839) * (1 + LFNoise0.kr(50, \reduxJitter.kr(0.0248)));
        var preCut = (rate * 0.5).clip(20, 18000);
        var postCut = ((rate * 0.5) * (2 ** \reduxPostOctaves.kr(-2.992126))).clip(20, 18000);
        var steps = 2 ** (\reduxBits.kr(5) - 1);
        var dc = \reduxDcShift.kr(1, 0.03);
        var mix = \reduxMix.kr(0.795276);
        var pre = sig + ((LPF.ar(LPF.ar(sig, preCut), preCut) - sig) * \reduxPreFilter.kr(0, 0.03));
        var held = Latch.ar(pre, Impulse.ar(rate));
        var q = (((held * steps) + (0.5 - (0.5 * dc))).floor + (0.5 * dc)) / steps;
        q = q + ((LPF.ar(LPF.ar(q, postCut), postCut) - q) * \reduxPostFilter.kr(0, 0.03));
        ^(sig * (1 - mix)) + (LeakDC.ar(q) * mix)
    }

    // ---- The types --------------------------------------------------------
    // One row per built-in device type (docs/dev/device-chains.md, section 4.1),
    // in chain order. Each type is its effect's key; the device of that type
    // a chain starts with has the key as its id too.
    //   title, blurb  the device's name and one line on what it does
    //   track         the chain it is built for: \guitar or \loop
    //   width         \mono: written for one channel. Its device hears the
    //                 sum of the chain's two sides, (L + R) / 2, and writes
    //                 its effect to both; the dry path stays the two sides.
    //                 \stereo: both sides, each its own.
    //   followsTempo  it reads \beatDur, which each chain's group is sent
    //   switch        its on/off control, <key>On
    //   mainKnobs     the settings a folded panel shows
    //   memBytes      { |sampleRate| } what its synth takes from the
    //                 real-time pool: its delay lines and buffers, as scsynth
    //                 allocates them (an estimate; scsynth reports nothing)
    //   latency       { |settings, sampleRate| } its delay in frames at these
    //                 settings, measured offline (device-chains.md, 13.1):
    //                 none but the Shifter's, which grows with the shift
    //   dsp           { |sig| } the effect, one of the methods above
    *types { ^typeList ?? { typeList = this.prTypeTable } }

    *type { |key| ^this.types.detect { |t| t[\key] == key } }

    *switchName { |key| ^(key ++ "On").asSymbol }

    // A delay line of `frames` as DelayC and PitchShift take it: the frames
    // and a block, rounded up to a power of two, in 32-bit floats.
    *lineBytes { |frames| ^(frames.ceil.asInteger + 64).nextPowerOfTwo * 4 }

    *prTypeTable {
        var none = { |settings, sr| 0 };
        ^[
            (key: \shifter, track: \guitar, width: \mono, followsTempo: false,
                blurb: "Shifts the guitar's pitch.",
                mainKnobs: [\shifterCoarse, \shifterCents, \shifterMix],
                dsp: { |sig| this.shifter(sig) },
                // Every window's line, and the FFT's frame and its IFFT's.
                memBytes: { |sr| this.shifterWindows.sum { |w| this.lineBytes((w * sr * 3) + 3) } + (1024 * 4 * 3) },
                // PitchShift: 2 samples unshifted; on average |ratio - 1| x half
                // the window more, sweeping within each window. FFT: a frame.
                latency: { |s, sr|
                    var ratio = ((s[\shifterCoarse] ? 0) + ((s[\shifterCents] ? 0.5) / 100)).clip(-24, 24).midiratio;
                    var w = this.shifterWindows[(s[\shifterWindow] ? 3).round.asInteger.clip(0, this.shifterWindows.size - 1)];
                    if((s[\shifterMode] ? 0) >= 0.5) { 1024 } { (2 + ((ratio - 1).abs * (w / 2) * sr)).floor.asInteger }
                }),
            (key: \delay, track: \guitar, width: \mono, followsTempo: false,
                blurb: "Two wobbling taps: a near-dry copy and a detuned echo.",
                mainKnobs: [\delayTimeR, \delayFeedback, \delayMix],
                dsp: { |sig| this.delay(sig) },
                memBytes: { |sr| this.lineBytes((2.7 * sr) + 1) * 4 },
                latency: none),
            (key: \filter, track: \guitar, width: \mono, followsTempo: true,
                blurb: "A filter your picking and a synced LFO move.",
                mainKnobs: [\filterFreq, \filterRes, \filterEnvAmount, \filterLfoAmount],
                dsp: { |sig| this.filter(sig) },
                memBytes: { |sr| 0 },
                latency: none),
            (key: \pitchLoop, track: \guitar, width: \mono, followsTempo: false,
                blurb: "Two voices replaying the last seconds: one reversed a fifth up, one an octave up.",
                mainKnobs: [\pitchLoopPitchL, \pitchLoopPitchR, \pitchLoopMix],
                dsp: { |sig| this.pitchLoop(sig) },
                // Its six-second LocalBuf, the feedback's short one, and two
                // GrainBufs' 512 grains (about 96 bytes each in 3.14).
                memBytes: { |sr| (288000 * 4) + (2048 * 4) + (2 * 512 * 96) },
                latency: none),
            (key: \echo, track: \loop, width: \stereo, followsTempo: true,
                blurb: "An echo on the loop: synced Mid/Side repeats, ducked under the loop.",
                mainKnobs: [\echoBeatsL, \echoFeedback, \echoMix],
                dsp: { |sig| this.echo(sig) },
                // Two lines and FreeVerb2's own.
                memBytes: { |sr| (this.lineBytes((2.5 * sr) + 1) * 2) + 102400 },
                latency: none),
            (key: \saturator, track: \loop, width: \stereo, followsTempo: false,
                blurb: "A drive with the lows driven hardest.",
                mainKnobs: [\saturatorDrive, \saturatorBase, \saturatorMix],
                dsp: { |sig| this.saturator(sig) },
                memBytes: { |sr| 0 },
                latency: none),
            (key: \redux, track: \loop, width: \stereo, followsTempo: false,
                blurb: "Fewer samples, fewer bits.",
                mainKnobs: [\reduxRate, \reduxBits, \reduxMix],
                dsp: { |sig| this.redux(sig) },
                memBytes: { |sr| 0 },
                latency: none)
        ].collect { |t|
            t.put(\title, this.title(t[\key]));
            t.put(\switch, this.switchName(t[\key]));
            t
        }
    }

    // ---- The devices' SynthDefs -------------------------------------------

    *deviceDefName { |key| ^("megaSADev" ++ key.asString.copy.put(0, key.asString[0].toUpper)).asSymbol }

    // One device of a built-in type: In from its chain's bus, its effect in
    // its slot, ReplaceOut onto the same bus, so the next device hears this
    // one's output and nothing else. A mono type hears (L + R) / 2 and writes
    // its effect to both sides, while the dry path stays the two sides as
    // they came. On the guitar chain, which is dual mono, that sum is exactly
    // the signal each effect had in the one-synth chain before the split; on a
    // stereo chain a mono device switched off leaves the stereo as it was.
    // Its switch starts off, so a device made without one passes its chain
    // through. `bus` must always be given: at its default, 0, it would write
    // the interface's outputs.
    *deviceDef { |key|
        var t = this.type(key);
        ^SynthDef(this.deviceDefName(key), { |bus|
            var dry = In.ar(bus, 2);
            var sig = if(t[\width] == \mono) { (dry[0] + dry[1]) * 0.5 } { dry };
            ReplaceOut.ar(bus, this.slot(dry, t[\switch], t[\dsp].value(sig)));
        })
    }

    // A device whose type this build does not know (a sound saved by a newer
    // one): it passes its chain through, so the order of the rest holds.
    *nullDef {
        ^SynthDef(\megaSADevNull, { |bus| ReplaceOut.ar(bus, In.ar(bus, 2)) })
    }

    // What feeds a chain: the hardware input, dual mono (the guitar's), or
    // another bus copied (the loop's, from the Looper's output). Each writes
    // the chain's bus first in every block, so Out overwrites it. The drums'
    // chain works on the bus its voices have written already in the block:
    // its source feeds nothing, and is there as the node the chain's first
    // device goes after.
    *sourceDefs {
        ^[
            SynthDef(\megaSAChainIn, { |in = 0, bus| Out.ar(bus, SoundIn.ar(in) ! 2) }),
            SynthDef(\megaSAChainCopy, { |in, bus| Out.ar(bus, In.ar(in, 2)) }),
            SynthDef(\megaSAChainOn, { |bus| })
        ]
    }

    *addDeviceDefs {
        this.sourceDefs.do(_.add);
        this.nullDef.add;
        this.types.do { |t| this.deviceDef(t[\key]).add };
    }

    // ---- The settings -----------------------------------------------------
    // One row per setting a player may move, in each device's panel order:
    // the effect, the control's name, the knob's label (the Live device's own
    // name), the range as a ControlSpec whose default is the control's
    // default in the DSP above (scripts/tests/test-megasa.scd checks they
    // agree), how the readout shows it (`scale` turns seconds into ms and 0..1
    // into %), `choices` for a setting picked from a list, `centered` for a
    // bipolar knob, and the tip. MegaSA keeps the values; the Effects tab
    // draws them.
    *params { ^paramList ?? { paramList = this.prParamTable } }

    *paramsOf { |key| ^this.params.select { |p| p[\fx] == key } }

    *param { |name|
        paramIndex ?? {
            paramIndex = IdentityDictionary.new;
            this.params.do { |p| paramIndex.put(p[\name], p) };
        };
        ^paramIndex[name]
    }

    // name -> default, a fresh dictionary each time.
    *defaults {
        var d = IdentityDictionary.new;
        this.params.do { |p| d.put(p[\name], p[\spec].default) };
        ^d
    }

    // A value held to a setting's range and step, or the nearest of its
    // choices. A name that is no setting passes through.
    *constrain { |name, value|
        var p = this.param(name);
        var values;
        ^case
            { p.isNil } { value }
            { p[\choices].notNil } {
                values = p[\choices].collect { |c| c[0] };
                values[values.indexIn(value)]
            }
            { p[\spec].constrain(value) }
    }

    *prParamTable {
        var divisions = [[0.0625, "1/64"], [1 / 12, "1/32 T"], [0.09375, "1/64 D"], [0.125, "1/32"],
            [1 / 6, "1/16 T"], [0.1875, "1/32 D"], [0.25, "1/16"], [1 / 3, "1/8 T"], [0.375, "1/16 D"],
            [0.5, "1/8"], [2 / 3, "1/4 T"], [0.75, "1/8 D"], [1, "1/4"], [4 / 3, "1/2 T"],
            [1.5, "1/4 D"], [2, "1/2"]];
        ^[
            // ---- Shifter
            (fx: \shifter, name: \shifterCoarse, label: "Coarse", units: " st", centered: true,
                spec: ControlSpec(-24, 24, \lin, 1, 0),
                tip: "Pitch shift in semitones: 0 by default. 12 is an octave;\n"
                    "big upward shifts get fizzy."),
            (fx: \shifter, name: \shifterCents, label: "Fine", units: " ct", centered: true,
                spec: ControlSpec(-100, 100, \lin, 0, 0.5),
                tip: "Fine pitch in cents: 0.5 ct by default. Set it by ear."),
            (fx: \shifter, name: \shifterMode, label: "Mode",
                spec: ControlSpec(0, 1, \lin, 1, 0), choices: [[0, "PitchShift"], [1, "FFT"]],
                tip: "How it shifts. PitchShift, the default: SuperCollider's grain shifter,\n"
                    "with the three settings beside this one. FFT: a steadier pitch and a\n"
                    "little less smear on attacks, about 8 ms later; those settings don't\n"
                    "touch it. Switching crossfades, so it can be done while playing."),
            (fx: \shifter, name: \shifterWindow, label: "Window",
                spec: ControlSpec(0, 7, \lin, 1, 3),
                choices: MegaSAFx.shifterWindows.collect { |w, i| [i, (w * 1000).round.asInteger.asString ++ " ms"] },
                tip: "PitchShift's grain length: 40 ms by default. Shorter smears attacks\n"
                    "less but buzzes on low notes; longer is smoother and smears more.\n"
                    "Every length runs at once, so switching crossfades."),
            (fx: \shifter, name: \shifterPitchSpread, label: "Pitch spread", units: " %", scale: 100,
                spec: ControlSpec(0, 0.25, \lin, 0, 0),
                tip: "PitchShift's pitch dispersion: each grain's pitch off the ratio by up to\n"
                    "this much, at random. 0 by default; a little thickens, a lot warbles."),
            (fx: \shifter, name: \shifterTimeSpread, label: "Time spread", units: " %", scale: 100,
                spec: ControlSpec(0, 1, \lin, 0, 0),
                tip: "PitchShift's time dispersion: each grain starts up to this share of\n"
                    "the window late, at random. 0 by default; some breaks up the\n"
                    "metallic comb of evenly spaced grains, a lot smears."),
            (fx: \shifter, name: \shifterMix, label: "Dry/Wet", units: " %", scale: 100,
                spec: ControlSpec(0, 1, \lin, 0, 1),
                tip: "Dry against shifted guitar: 100 % by default. In between:\n"
                    "a harmony at big shifts, a chorus at small ones."),

            // ---- Delay
            (fx: \delay, name: \delayTimeL, label: "L Time", units: " ms", scale: 1000,
                spec: ControlSpec(0.001, 2.5, \exp, 0, 0.001),
                tip: "The first tap, on the left: 1 ms by default, a near-dry copy."),
            (fx: \delay, name: \delayTimeR, label: "R Time", units: " ms", scale: 1000,
                spec: ControlSpec(0.001, 2.5, \exp, 0, 0.437855),
                tip: "The second tap, on the right: 438 ms by default. Changes glide,\n"
                    "so the pitch bends while you turn it."),
            (fx: \delay, name: \delayFeedback, label: "Feedback", units: " %", scale: 100,
                spec: ControlSpec(0, 0.9, \lin, 0, 0),
                tip: "Each tap back into itself: 0 % by default. Stops at 90 %, and the\n"
                    "repeats are softened so they cannot run away."),
            (fx: \delay, name: \delayMix, label: "Dry/Wet", units: " %", scale: 100,
                spec: ControlSpec(0, 1, \lin, 0, 1),
                tip: "100 % by default: only the two taps. Lower it to keep the plain note\n"
                    "under them (an equal-loudness mix)."),
            (fx: \delay, name: \delayModDepth, label: "LFO > Time", units: " %", scale: 100,
                spec: ControlSpec(0, 0.05, 3, 0, 0.005),
                tip: "How far the wobble pulls the taps' times, opposite ways:\n"
                    "+/-0.5 % by default."),
            (fx: \delay, name: \delayLfoHz, label: "LFO Rate", units: " Hz",
                spec: ControlSpec(0.05, 40, \exp, 0, 9.448819),
                tip: "How often the wobble picks a new speed: 9.45 Hz by default.\n"
                    "The speeds are random and glide from one to the next."),
            (fx: \delay, name: \delayLfoMin, label: "Wobble Min", units: " Hz",
                spec: ControlSpec(0.01, 10, \exp, 0, 0.01),
                tip: "The slowest wobble: 0.01 Hz by default."),
            (fx: \delay, name: \delayLfoMax, label: "Wobble Max", units: " Hz",
                spec: ControlSpec(0.01, 40, \exp, 0, 1.176184),
                tip: "The fastest wobble: about 1.2 Hz by default."),

            // ---- Auto Filter
            (fx: \filter, name: \filterType, label: "Type",
                spec: ControlSpec(0, 4, \lin, 1, 4),
                choices: [[0, "Low-pass"], [1, "High-pass"], [2, "Band-pass"], [3, "Notch"], [4, "Morph"]],
                tip: "The filter's type, all 24 dB per octave. Morph, the default,\n"
                    "slides from low-pass through band-pass to high-pass."),
            (fx: \filter, name: \filterFreq, label: "Frequency", units: " Hz",
                spec: ControlSpec(30, 18000, \exp, 0, 311.094842),
                tip: "Cutoff: 311 Hz by default. The envelope and the LFO move it from here."),
            (fx: \filter, name: \filterRes, label: "Res", units: " %", scale: 100,
                spec: ControlSpec(0, 1, \lin, 0, 0.307884),
                tip: "Resonance: 31 % by default."),
            (fx: \filter, name: \filterMorph, label: "Morph", units: " %", scale: 100,
                spec: ControlSpec(0, 1, \lin, 0, 0.1641),
                tip: "With Type Morph: 0 % low-pass, 50 % band-pass, 100 % high-pass.\n"
                    "16 % by default, so mostly low-pass."),
            (fx: \filter, name: \filterEnvAmount, label: "Envelope", units: " %", scale: 100, centered: true,
                spec: ControlSpec(-1, 1, \lin, 0, 0.756379),
                tip: "How far your picking opens the filter: +76 % by default.\n"
                    "100 % is 4 octaves."),
            (fx: \filter, name: \filterSense, label: "Sense", units: " x",
                spec: ControlSpec(0.5, 30, \exp, 0, 3),
                tip: "How hard a pick has to be to reach the top of the envelope; higher reacts\n"
                    "to softer playing."),
            (fx: \filter, name: \filterRelease, label: "Release", units: " ms", scale: 1000,
                spec: ControlSpec(0.01, 3, \exp, 0, 0.25),
                tip: "How fast the envelope lets go after a note: 250 ms by default."),
            (fx: \filter, name: \filterLfoWave, label: "LFO Wave",
                spec: ControlSpec(0, 7, \lin, 1, 4),
                choices: [[0, "Sine"], [1, "Triangle"], [2, "Saw"], [3, "Square"], [4, "Ramp Up"],
                    [5, "Ramp Down"], [6, "Wander"], [7, "S&H"]],
                tip: "The LFO's shape: Ramp Up by default."),
            (fx: \filter, name: \filterLfoAmount, label: "LFO Amt", units: " %", scale: 100,
                spec: ControlSpec(0, 1, \lin, 0, 0.89187),
                tip: "How far the LFO moves the filter: 89 % by default.\n"
                    "100 % is 3 octaves each way."),
            (fx: \filter, name: \filterLfoBeats, label: "LFO Sync",
                spec: ControlSpec(0, 8, \lin, 0, 1),
                choices: [[0, "Free"], [0.0625, "1/64"], [1 / 12, "1/32 T"], [0.09375, "1/64 D"],
                    [0.125, "1/32"], [1 / 6, "1/16 T"], [0.1875, "1/32 D"], [0.25, "1/16"],
                    [1 / 3, "1/8 T"], [0.375, "1/16 D"],
                    [0.5, "1/8"], [2 / 3, "1/4 T"], [0.75, "1/8 D"], [1, "1/4"], [4 / 3, "1/2 T"],
                    [1.5, "1/4 D"], [2, "1/2"], [3, "1/2 D"], [4, "1/1"], [8, "2/1"]],
                tip: "One LFO cycle per this note value at the loop's tempo: one per beat in the\n"
                    "set (Triplet 3/8). Free runs at LFO Rate. It runs from its own phase, not\n"
                    "locked to the bar."),
            (fx: \filter, name: \filterLfoHz, label: "LFO Rate", units: " Hz",
                spec: ControlSpec(0.05, 20, \exp, 0, 1.00031),
                tip: "The LFO's speed while Sync is Free: 1 Hz by default."),
            (fx: \filter, name: \filterMakeup, label: "Makeup", units: " %", scale: 100,
                spec: ControlSpec(0, 1, \lin, 0, 0),
                tip: "Brings a quiet filtered sound back towards the guitar's level,\n"
                    "up to 26 dB. 0 % by default."),
            (fx: \filter, name: \filterOutput, label: "Output", units: " dB",
                spec: ControlSpec(-24, 0, \lin, 0, 0),
                tip: "Level after the soft clip: 0 dB by default, and the top,\n"
                    "since more would clip into the amp after it."),

            // ---- PitchLoop89
            (fx: \pitchLoop, name: \pitchLoopMix, label: "Dry/Wet", units: " %", scale: 100,
                spec: ControlSpec(0, 1, \lin, 0, 0.37),
                tip: "Your guitar against the two voices, equal-power: 37 %."),
            (fx: \pitchLoop, name: \pitchLoopPitchL, label: "Pitch L", units: " st", centered: true,
                spec: ControlSpec(-24, 24, \lin, 1, 7),
                tip: "The reversed voice's transposition: +7 st, a fifth, by default."),
            (fx: \pitchLoop, name: \pitchLoopPosL, label: "Position L", units: " ms", scale: 1000,
                spec: ControlSpec(0.01, 1.5, \exp, 0, 0.795768),
                tip: "How far behind your playing each reversed piece starts: 796 ms by\n"
                    "default. Held to what fits the 6 s memory at the pitch and segment set."),
            (fx: \pitchLoop, name: \pitchLoopSegL, label: "Segment L", units: " ms", scale: 1000,
                spec: ControlSpec(0.02, 0.9, \exp, 0, 0.2892),
                tip: "How much audio each reversed piece holds: 289 ms (15.7 %), played in\n"
                    "less as the pitch goes up."),
            (fx: \pitchLoop, name: \pitchLoopLfoRateL, label: "LFO Rate L", units: " Hz",
                spec: ControlSpec(0.01, 10, \exp, 0, 1.978),
                tip: "The sine LFO moving the reversed voice's start: 1.98 Hz."),
            (fx: \pitchLoop, name: \pitchLoopLfoL, label: "LFO Depth L", units: " ms", scale: 1000,
                spec: ControlSpec(0, 1, \lin, 0, 0.6876),
                tip: "How much further back the LFO can push each reversed piece: up to 688 ms\n"
                    "(37.8 %), taken once per piece."),
            (fx: \pitchLoop, name: \pitchLoopRandL, label: "Rand. L", units: " ms", scale: 1000,
                spec: ControlSpec(0, 0.2, \lin, 0, 0),
                tip: "A random extra distance for each reversed piece: none by default."),
            (fx: \pitchLoop, name: \pitchLoopPitchR, label: "Pitch R", units: " st", centered: true,
                spec: ControlSpec(-24, 24, \lin, 1, 12),
                tip: "The second voice, played forwards: +12 st, an octave up."),
            (fx: \pitchLoop, name: \pitchLoopPosR, label: "Position R", units: " ms", scale: 1000,
                spec: ControlSpec(0.01, 1.5, \exp, 0, 0.1302),
                tip: "How far the octave voice trails: 130 ms by default. A pitched-up\n"
                    "voice is held far enough back not to catch up (290 ms at +12)."),
            (fx: \pitchLoop, name: \pitchLoopSegR, label: "Segment R", units: " ms", scale: 1000,
                spec: ControlSpec(0.02, 0.9, \exp, 0, 0.2892),
                tip: "Audio per piece of the octave voice: 289 ms, played in half that."),
            (fx: \pitchLoop, name: \pitchLoopLfoRateR, label: "LFO Rate R", units: " Hz",
                spec: ControlSpec(0.01, 10, \exp, 0, 1),
                tip: "The sine LFO moving the octave voice's start: 1 Hz by default.\n"
                    "Heard once LFO Depth R is up."),
            (fx: \pitchLoop, name: \pitchLoopLfoR, label: "LFO Depth R", units: " ms", scale: 1000,
                spec: ControlSpec(0, 1, \lin, 0, 0),
                tip: "How much further back the LFO can push each octave piece, taken once\n"
                    "per piece: none by default."),
            (fx: \pitchLoop, name: \pitchLoopRandR, label: "Rand. R", units: " ms", scale: 1000,
                spec: ControlSpec(0, 0.2, \lin, 0, 0.0326),
                tip: "A random extra distance for each octave piece: up to 33 ms (1.8 %)."),
            (fx: \pitchLoop, name: \pitchLoopFeedback, label: "Feedback", units: " %", scale: 100,
                spec: ControlSpec(0, 0.9, \lin, 0, 0),
                tip: "The two voices back into the memory, so each pass is shifted again and\n"
                    "the sound climbs: 0 % by default. Stops at 90 %, and the returns are\n"
                    "softened so they cannot run away."),
            (fx: \pitchLoop, name: \pitchLoopHiCut, label: "Hi Cut", units: " Hz",
                spec: ControlSpec(500, 18000, \exp, 0, 11068),
                tip: "High cut on both voices: about 11 kHz by default."),
            (fx: \pitchLoop, name: \pitchLoopOutput, label: "Output", units: " dB",
                spec: ControlSpec(-36, 6, \lin, 0, -5.45),
                tip: "Level of the two voices: -5.5 dB by default."),

            // ---- Echo
            (fx: \echo, name: \echoBeatsL, label: "L Synced",
                spec: ControlSpec(0.0625, 2, \exp, 0, 0.1875), choices: divisions,
                tip: "The first line's note value at the loop's tempo: a dotted 1/32, about\n"
                    "68 ms at 165 BPM. In Mid/Side it times the middle."),
            (fx: \echo, name: \echoBeatsR, label: "R Synced",
                spec: ControlSpec(0.0625, 2, \exp, 0, 0.75), choices: divisions,
                tip: "The second line: a dotted 1/8 by default. In Mid/Side\n"
                    "it times the sides, which are silent on a mono loop."),
            (fx: \echo, name: \echoMidSide, label: "Channels",
                spec: ControlSpec(0, 1, \lin, 1, 1), choices: [[0, "Stereo"], [1, "Mid/Side"]],
                tip: "The set runs Mid/Side, so on the mono loop only the first line is heard,\n"
                    "in the middle. Stereo puts the two lines left and right."),
            (fx: \echo, name: \echoFeedback, label: "Feedback", units: " %", scale: 100,
                spec: ControlSpec(0, 0.9, \lin, 0, 0.1667),
                tip: "How much of each repeat comes round again: 16.7 % by default. Stops at\n"
                    "90 %: nothing in the loop catches a runaway."),
            (fx: \echo, name: \echoHp, label: "HP Freq", units: " Hz",
                spec: ControlSpec(20, 18000, \exp, 0, 520.1),
                tip: "Cuts the lows from the repeats: 520 Hz by default."),
            (fx: \echo, name: \echoLp, label: "LP Freq", units: " Hz",
                spec: ControlSpec(20, 18000, \exp, 0, 3142.4),
                tip: "Cuts the highs from the repeats: 3.1 kHz, swept by the echo's LFO."),
            (fx: \echo, name: \echoDuckThresh, label: "Duck Thr", units: " dB",
                spec: ControlSpec(-60, 0, \lin, 0, -29.06),
                tip: "While the loop is louder than this, the repeats drop by 14 dB: -29 dB by\n"
                    "default. 0 dB never ducks."),
            (fx: \echo, name: \echoDuckRelease, label: "Duck Rel", units: " ms", scale: 1000,
                spec: ControlSpec(0.02, 1.5, \exp, 0, 0.0976),
                tip: "How soon the repeats come back after the loop falls: 98 ms."),
            (fx: \echo, name: \echoReverb, label: "Reverb", units: " %", scale: 100,
                spec: ControlSpec(0, 1, \lin, 0, 0.198),
                tip: "The echo's own reverb on the repeats, after the delay: 19.8 %."),
            (fx: \echo, name: \echoReverbDecay, label: "Rev Decay", units: " %", scale: 100,
                spec: ControlSpec(0, 1, \lin, 0, 0.273),
                tip: "How long that reverb rings: 27.3 % by default."),
            (fx: \echo, name: \echoWobble, label: "Wobble", units: " %", scale: 100,
                spec: ControlSpec(0, 1, \lin, 0, 0.234),
                tip: "Tape-like irregularity in the time, a random one: 23.4 % by default."),
            (fx: \echo, name: \echoOutput, label: "Output", units: " dB",
                spec: ControlSpec(-24, 12, \lin, 0, 6.03),
                tip: "Gain on the repeats: +6 dB by default."),
            (fx: \echo, name: \echoMix, label: "Dry/Wet", units: " %", scale: 100,
                spec: ControlSpec(0, 1, \lin, 0, 0.6587),
                tip: "A linear Dry/Wet, 66 % by default: while the Tape Echo is on, the loop\n"
                    "itself drops to a third and the repeats sit on top."),

            // ---- Saturator
            (fx: \saturator, name: \saturatorType, label: "Type",
                spec: ControlSpec(0, 6, \lin, 1, 3),
                choices: [[0, "Analog Clip"], [1, "Soft Sine"], [3, "Medium"], [4, "Hard Curve"],
                    [5, "Sinoid Fold"], [6, "Digital Clip"]],
                tip: "The curve: Medium, a tanh, by default."),
            (fx: \saturator, name: \saturatorDrive, label: "Amount", units: " dB",
                spec: ControlSpec(-36, 36, \lin, 0, 6.499551),
                tip: "Gain into the curve: +6.5 dB by default."),
            (fx: \saturator, name: \saturatorBase, label: "Amt Lo", units: " dB",
                spec: ControlSpec(-36, 36, \lin, 0, 35.819816),
                tip: "How much harder the lows hit the curve: +35.8 dB by default. It is\n"
                    "taken out again after the curve, so the lows distort, not boom."),
            (fx: \saturator, name: \saturatorFreq, label: "Frequency", units: " Hz",
                spec: ControlSpec(30, 18000, \exp, 0, 108.377052),
                tip: "Centre of the Amt Hi band: 108 Hz by default."),
            (fx: \saturator, name: \saturatorWidth, label: "Width", units: " %", scale: 100,
                spec: ControlSpec(0.05, 1, \lin, 0, 0.843046),
                tip: "Width of the Amt Hi band: 84 % by default."),
            (fx: \saturator, name: \saturatorDepth, label: "Amt Hi", units: " dB",
                spec: ControlSpec(-24, 24, \lin, 0, 8.635303),
                tip: "How much harder that band hits the curve: +8.6 dB by default, taken\n"
                    "out again after it."),
            (fx: \saturator, name: \saturatorOutput, label: "Output", units: " dB",
                spec: ControlSpec(-36, 0, \lin, 0, -9.628804),
                tip: "Level after the curve: -9.6 dB by default. Turn it down as Amount\n"
                    "goes up."),
            (fx: \saturator, name: \saturatorMix, label: "Dry/Wet", units: " %", scale: 100,
                spec: ControlSpec(0, 1, \lin, 0, 0.566929),
                tip: "The plain loop against the saturated one: 57 % by default."),

            // ---- Redux
            (fx: \redux, name: \reduxRate, label: "Sample Rate", units: " kHz", scale: 0.001,
                spec: ControlSpec(50, 40000, \exp, 0, 7240.085839),
                tip: "How often the loop is sampled: about 7.2 kHz by default.\n"
                    "Lower is grittier."),
            (fx: \redux, name: \reduxJitter, label: "Jitter", units: " %", scale: 100,
                spec: ControlSpec(0, 1, \amp, 0, 0.0248),
                tip: "Randomness in the sample rate: 2.5 % by default."),
            (fx: \redux, name: \reduxBits, label: "Bit Depth",
                spec: ControlSpec(1, 16, \lin, 1, 5),
                tip: "Fewer bits, coarser steps: 5 by default."),
            (fx: \redux, name: \reduxDcShift, label: "DC Shift",
                spec: ControlSpec(0, 1, \lin, 1, 1), choices: [[0, "Off"], [1, "On"]],
                tip: "On: even silence sits half a step off zero, so quiet playing buzzes\n"
                    "instead of cutting out. On by default."),
            (fx: \redux, name: \reduxPreFilter, label: "Pre-Filter",
                spec: ControlSpec(0, 1, \lin, 1, 0), choices: [[0, "Off"], [1, "On"]],
                tip: "Smooths the loop before it is sampled: less fizz and fewer stray\n"
                    "tones. Off by default."),
            (fx: \redux, name: \reduxPostFilter, label: "Post-Filter",
                spec: ControlSpec(0, 1, \lin, 1, 0), choices: [[0, "Off"], [1, "On"]],
                tip: "A low-pass after the crusher, at Post Freq. Off by default."),
            (fx: \redux, name: \reduxPostOctaves, label: "Post Freq", units: " oct", centered: true,
                spec: ControlSpec(-4, 4, \lin, 0, -2.992126),
                tip: "Where the post-filter cuts, in octaves from half the sample rate: -3 by\n"
                    "default. Heard only with Post-Filter on."),
            (fx: \redux, name: \reduxMix, label: "Dry/Wet", units: " %", scale: 100,
                spec: ControlSpec(0, 1, \lin, 0, 0.795276),
                tip: "The plain loop against the reduced one: 80 % by default.")
        ]
    }
}
