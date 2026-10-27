// Megalooper SA's drum effects (docs/dev/megalooper-sa.md, Phase 4): the audio
// devices the Live set put after its drums, rebuilt in SC, plus the laws of
// Kit-Carbon's Beat Repeat, which MegaSADrums emulates in its scheduler.
//
//   \megaSADrumsFx  the 'drums' group's Hybrid Reverb, an insert on the steps'
//                   bus: true-stereo convolution with the set's impulse
//                   responses ("Early Reflections / Ableton Studio Backwards",
//                   presets/sa/drums/kits/_ir/), 10 ms predelay, an 80 Hz low
//                   cut on the wet, Live's linear Dry/Wet (15.08 % in the set).
//   \megaSAOnsetFx  the One Hit Kit's 'Drum Machines Audio Effect' chain as its
//                   macros play it: the Auto Filter's drive, Utility, a
//                   parallel Compressor, EQ Three, the 'Squash' Compressor and
//                   the Limiter.
//
// Every stage is a class method that builds its part of a graph, so the NRT
// check can render a stage on its own, and the arithmetic in them (the
// predelay, the compressors' gain computer, the EQ's band sum, the soft clip,
// the band edges) is written once for numbers and UGens alike and tested with
// numbers (scripts/tests/test-megadrums-fx.scd). What the defs do in scsynth
// is checked by scripts/sa/nrt-drums-fx.scd.
//
// These are approximations of Live's devices, from the set's stored values
// and Live's manual (the Phase 4 reviews); none has been compared with Live by
// ear yet.
MegaSADrumsFx {

    // ---- SynthDefs --------------------------------------------------------

    // Called by MegaSADrums.loadSynthDefs. They build with no server.
    *loadSynthDefs {
        // The four buffers are the impulse responses' spectra (preparePartConv),
        // in the order of irKeys. They have no usable default: one left out must
        // fail loudly (PartConv posts and stays silent) rather than convolve
        // with whatever buffer 0 holds. With irOn 0 the synth is exactly its
        // input, whatever the buffers: MegaSADrums starts it so on a zero
        // spectrum and replaces it once the real ones are in.
        SynthDef(\megaSADrumsFx, { |in, out, mix = 0.1508, irOn = 0,
            ll = 16777215, lr = 16777215, rl = 16777215, rr = 16777215|
            Out.ar(out, this.reverb(In.ar(in, 2), mix, irOn, [ll, lr, rl, rr]));
        }).add;
        SynthDef(\megaSAOnsetFx, { |in, out|
            Out.ar(out, this.onsetChain(In.ar(in, 2)));
        }).add;
    }

    // ---- The drums' reverb (Hybrid Reverb) ---------------------------------
    // Live's Hybrid Reverb at Blend 0 is its convolution engine alone, and the
    // set's response is a true-stereo pair, so four partitioned convolutions:
    // each input side through the two responses that start from it. Its EQ
    // comes after the engine, on the reverb only: a low cut at 80 Hz (slope
    // index 1 of Live's 6..96 dB/oct, read as 12). Its Dry/Wet is linear (as
    // Live's Delay and Echo document theirs), so at 15.08 % the dry is 0.849
    // and the wet 0.151. The impulse responses' own level is already set in
    // the files: tools/export-live-set.py scaled them to unit energy per output
    // for a centred input (Live evidently normalises a response's level).

    // The four responses, input side to output side, as ir.json names them.
    *irKeys { ^#[\ll, \lr, \rl, \rr] }

    // ir.json's format this build reads.
    *irVersion { ^1 }

    // PartConv's partition is half its FFT, and it answers one partition
    // minus a block late: 448 samples at 1024 and a block of 64 (measured in
    // NRT, SC 3.14.1). 1024 keeps that under the 10 ms predelay at 48 kHz; the
    // help file's 2048 alone would be 20 ms. The partition must hold at least
    // two blocks (fftSize >= 256 at a block of 64).
    *fftSize { ^1024 }

    // Hybrid Reverb's predelay in the set, in seconds.
    *predelay { ^0.010 }

    // The wet's own delay in samples, so that PartConv's latency plus it is the
    // predelay: 32 at 48 kHz with a block of 64. Below 0 (44.1 kHz) PartConv
    // alone is already later than the predelay, and the graph adds nothing.
    *wetDelaySamples { |sampleRate, blockSize|
        ^((this.predelay * sampleRate).round) - ((this.fftSize / 2) - blockSize)
    }

    *lowCut { ^80 }

    // The reverb on a stereo signal. mix: Live's Dry/Wet, 0..1, linear;
    // irOn: 0 passes `dry` exactly, mix or no mix; specs: the four spectra.
    // The wet sums are finite (PartConv), so dry * 1 + wet * 0 is dry to the
    // bit.
    *reverb { |dry, mix, irOn, specs|
        var sr = SampleRate.ir;
        var delay = this.wetDelaySamples(sr, BlockSize.ir).max(0);
        var late = DelayN.ar(dry, 0.05, delay / sr);
        var wetIn = (dry * (delay <= 0)) + (late * (delay > 0));
        var fft = this.fftSize;
        var wet = [
            PartConv.ar(wetIn[0], fft, specs[0]) + PartConv.ar(wetIn[1], fft, specs[2]),
            PartConv.ar(wetIn[0], fft, specs[1]) + PartConv.ar(wetIn[1], fft, specs[3])
        ];
        // A knob turned while the drums play must not step the level.
        var m = Lag.kr(mix.clip(0, 1), 0.05) * (irOn > 0);
        wet = HPF.ar(wet, this.lowCut);
        ^(dry * (1 - m)) + (wet * m)
    }

    // Where the impulse responses are: kitDir/_ir/ir.json, its four mono files
    // relative to kitDir. (path:, files: [ll, lr, rl, rr] absolute, rate:), or
    // nil with the reason in `warnings` (a List). Reads ir.json only; parseJSON
    // answers numbers as Strings, so the version and rate are checked as text.
    *irInfo { |kitDir, warnings|
        var notes = warnings ?? { List.new };
        var path, data, version, files, paths;
        if(kitDir.isNil) { notes.add("no kits folder"); ^nil };
        path = kitDir.standardizePath +/+ "_ir" +/+ "ir.json";
        if(File.exists(path).not) { notes.add("no " ++ path); ^nil };
        data = try { File.readAllString(path).parseJSON } { |err|
            notes.add("ir.json is not JSON — " ++ err.errorString);
            nil
        };
        if(data.isKindOf(Dictionary).not) { notes.add("ir.json is not a JSON object"); ^nil };
        version = this.prInt(this.prGet(data, \version));
        if(version.notNil and: { version > this.irVersion }) {
            notes.add("ir.json version " ++ version ++ " is newer than this build (" ++ this.irVersion ++ ")");
            ^nil
        };
        files = this.prGet(data, \files);
        if(files.isKindOf(Dictionary).not) { notes.add("ir.json names no files"); ^nil };
        paths = this.irKeys.collect { |k|
            var f = this.prGet(files, k);
            if(f.isKindOf(String) and: { f.notEmpty }) { MegaSAKit.absolutePath(kitDir, f) } { nil }
        };
        if(paths.any(_.isNil)) {
            notes.add("ir.json does not name all of " ++ this.irKeys.join(", "));
            ^nil
        };
        ^(path: path, files: paths, rate: this.prNum(this.prGet(data, \rate)))
    }

    // Read the impulse responses onto `server` and prepare their spectra.
    // action.(specs): the four spectral buffers, in irKeys order, or nil (no
    // response, or the server would not read it; posted). The files are taken
    // as they are, already scaled and at 48 kHz; on a server at another rate
    // each is resampled once in the language (posted: about a second of
    // interpreter time) and goes in through a temporary file. reader.(server,
    // path, done) reads one file into a Buffer and calls done.(buffer), or
    // done.(nil); by default Buffer.read. PartConv.calcBufSize needs the
    // buffer's numFrames, which a read knows once its /b_info is in, so the
    // spectra are allocated after a sync, prepared, and synced again: PartConv
    // takes its spectra only when its synth starts. The time-domain buffers
    // are freed after that; the spectra hold everything PartConv reads.
    // Inline in a Routine (the syncs wait there); from any other thread it
    // runs in one of its own on SystemClock. Answers the Routine, or nil.
    *loadIR { |server, kitDir, action, reader|
        var job = { this.prLoadIR(server, kitDir, action, reader) };
        if(thisThread.isKindOf(Routine)) { job.value; ^nil };
        ^Routine(job).play(SystemClock)
    }

    *prLoadIR { |server, kitDir, action, reader|
        var warnings = List.new;
        var info = this.irInfo(kitDir, warnings);
        var rate = (server !? { |s| s.sampleRate }) ? 48000;
        var bufs, specs, temps = List.new, fail, said = false;
        fail = { |why|
            ("MegaSADrumsFx: no drum reverb (" ++ why ++ "); the drums play dry.").warn;
            bufs !? { bufs.do { |b| b !? { b.free } } };
            temps.do { |p| File.delete(p) };
            action.value(nil);
        };
        if(info.isNil) { ^fail.(warnings.join("; ")) };
        reader = reader ?? { { |srv, path, done| Buffer.read(srv, path, action: done) } };
        bufs = Array.newClear(info[\files].size);
        info[\files].do { |path, i|
            var head = MegaSAKit.probeFile(path), data, temp;
            case
            { head.isNil } { ^fail.("cannot read " ++ PathName(path).fileName) }
            { head[\numChannels] != 1 } {
                ^fail.(PathName(path).fileName ++ " has " ++ head[\numChannels]
                    ++ " channels; PartConv takes mono responses")
            }
            { (head[\sampleRate] - rate).abs > 0.5 } {
                if(said.not) {
                    said = true;
                    ("MegaSADrumsFx: the drum reverb's responses are at " ++ head[\sampleRate]
                        ++ " Hz and the server at " ++ rate ++ "; resampling them in the language.").warn;
                };
                data = this.prReadMono(path, head[\numFrames]);
                if(data.isNil) { ^fail.("cannot read " ++ PathName(path).fileName) };
                // The process id too: UniqueID counts from 1000 in every
                // sclang, so two at once (a test run beside SA) would share it.
                temp = PathName.tmp +/+ ("megasa-ir-" ++ (try { thisProcess.pid } { 0 }) ++ "-" ++ UniqueID.next ++ ".wav");
                if(this.prWriteMono(temp, this.resampleIR(data, head[\sampleRate], rate), rate).not) {
                    ^fail.("cannot write a resampled response to " ++ temp)
                };
                temps.add(temp);
                reader.value(server, temp, { |b| bufs[i] = b });
            }
            { reader.value(server, path, { |b| bufs[i] = b }) };
        };
        server.sync;
        temps.do { |p| File.delete(p) };
        temps = List.new;
        if(bufs.any { |b| b.isNil or: { b.numFrames.isNil } or: { b.numFrames < 1 } }) {
            ^fail.("the server did not read the responses")
        };
        specs = bufs.collect { |b| Buffer.alloc(server, PartConv.calcBufSize(this.fftSize, b).asInteger, 1) };
        server.sync;
        specs.do { |s, i| s.preparePartConv(bufs[i], this.fftSize) };
        server.sync;
        bufs.do { |b| b.free };
        action.value(specs);
    }

    // A mono file's samples, or nil.
    *prReadMono { |path, frames|
        var sf = try { SoundFile.openRead(path) } { nil };
        var data;
        if(sf.isNil) { ^nil };
        data = FloatArray.newClear(frames);
        sf.readData(data);
        sf.close;
        ^data
    }

    *prWriteMono { |path, data, rate|
        var sf = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(1).sampleRate_(rate);
        if(sf.openWrite(path).not) { ^false };
        sf.writeData(data.as(FloatArray));
        sf.close;
        ^true
    }

    // An impulse response from one rate to another: resampled (resample), and
    // scaled by fromRate / toRate, since a kernel sampled more densely sums
    // more taps; so it filters at the new rate as it did at the old one.
    *resampleIR { |data, fromRate, toRate|
        ^this.resample(data, fromRate, toRate) * (fromRate / toRate)
    }

    // Band-limited resampling: a Hann-windowed sinc, `halfWidth` source taps
    // each side (at the lower of the two rates), its cut-off at 0.97 of the
    // lower Nyquist, each output's weights normalised to sum to 1 (so a DC
    // signal stays DC). round(n * toRate / fromRate) samples. Pure; slow in
    // sclang (a 0.3 s response: well under a second), so once, at load.
    *resample { |data, fromRate, toRate, halfWidth = 16|
        var ratio = fromRate / toRate;
        var scale = (toRate / fromRate).min(1);
        var cut = 0.97 * scale;
        var reach = (halfWidth / scale).ceil.asInteger;
        var n = data.size;
        var size = ((n / ratio).round).asInteger.max(1);
        var out = FloatArray.newClear(size);
        var j = 0, t, base, sum, weight, i, x, w, acc;
        while { j < size } {
            t = j * ratio;
            base = t.floor.asInteger;
            sum = 0;
            acc = 0;
            i = base - reach + 1;
            while { i <= (base + reach) } {
                x = (t - i) * cut;
                w = if(x.abs < 1e-9) { 1 } { sin(pi * x) / (pi * x) };
                weight = w * (0.5 + (0.5 * cos(pi * ((t - i) / (reach + 1)))));
                if((i >= 0) and: { i < n }) { acc = acc + (data[i] * weight) };
                sum = sum + weight;
                i = i + 1;
            };
            out[j] = if(sum.abs > 1e-12) { acc / sum } { 0 };
            j = j + 1;
        };
        ^out
    }

    // ---- The onset kit's chain ('Drum Machines Audio Effect') --------------
    // In chain order, as the rack's macros play it ([live] §4, [rv-fid] 6):
    //   1. Auto Filter, MS2 circuit, cutoff fully open, Drive +10.2 dB (macro
    //      3): its drive stands here as a tanh after the gain, the filter
    //      itself being open and its resonance negligible
    //   2. Utility -7.91 dB (the same macro: it takes most of the drive back)
    //   3. Compressor at 22 % wet: threshold -16.75 dB, 4.06:1, knee 6 dB,
    //      attack 44.75 ms, release 113 ms, Makeup on (taken as the static
    //      makeup for its ratio and threshold, +12.6 dB) and Output +0.99 dB,
    //      both on the wet: it lifts what is under the threshold by about
    //      5 dB and leaves loud peaks nearly alone
    //   4. EQ Three: +1.84 dB under 250 Hz, +2.54 dB over 2.5 kHz
    //   5. Compressor 'Squash': threshold -3.54 dB, 2.313:1, knee 2 dB, attack
    //      2 ms, Output +1.197 dB; Live's auto release taken as 150 ms, its
    //      sidechain EQ (mode 5 at 300 Hz, unverified) left out
    //   6. Limiter: +1.1 dB, ceiling -0.3 dB, here a soft clip with no
    //      look-ahead: the onset kit plays on the loop's time and a look-ahead
    //      would make it late
    // The Saturator and the Delay are off in the set. The followers are
    // MegaSAFx.follow's (Amplitude.ar, whose times are real; Amplitude.kr's run
    // 64x fast on an audio input), and each gain is ramped across its block
    // (K2A) rather than stepped.
    //
    // compMix: stage 3's wet share; the NRT check renders the chain with it at
    // 0 to hear what the parallel compressor adds.
    *onsetChain { |sig, compMix = 0.22|
        var comp = this.onsetComp, eq = this.onsetEq, limit = this.onsetLimit;
        sig = (sig * this.onsetDriveDb.dbamp).tanh;
        sig = sig * this.onsetUtilityDb.dbamp;
        sig = (sig * (1 - compMix))
            + (this.compressor(sig, comp, this.makeupDb(comp[\thresholdDb], comp[\ratio])) * compMix);
        sig = this.eqThree(sig, eq[\lowDb], eq[\midDb], eq[\highDb], eq[\lowFreq], eq[\highFreq]);
        sig = this.compressor(sig, this.onsetSquash, 0);
        sig = this.softClip(sig * limit[\gainDb].dbamp, limit[\ceilingDb].dbamp,
            (limit[\ceilingDb] - limit[\kneeDb]).dbamp);
        ^Sanitize.ar(sig)
    }

    *onsetDriveDb { ^10.2 }
    *onsetUtilityDb { ^-7.91 }
    *onsetComp {
        ^(thresholdDb: -16.75, ratio: 4.06, kneeDb: 6, attack: 0.04475, release: 0.113, outputDb: 0.99, mix: 0.22)
    }
    *onsetEq { ^(lowDb: 1.84, midDb: 0, highDb: 2.54, lowFreq: 250, highFreq: 2500) }
    *onsetSquash {
        ^(thresholdDb: -3.54, ratio: 2.313, kneeDb: 2, attack: 0.002, release: 0.15, outputDb: 1.197)
    }
    // The soft clip is transparent up to kneeDb under the ceiling.
    *onsetLimit { ^(gainDb: 1.1, ceilingDb: -0.3, kneeDb: 3) }

    // A feed-forward compressor on a mono or stereo signal (linked: the
    // louder side drives both): `settings` as onsetComp, makeupDb on top of
    // its output gain.
    *compressor { |sig, settings, makeupDb = 0|
        var peak = if(sig.isArray) { sig.collect(_.abs).reduce(\max) } { sig.abs };
        var level = MegaSAFx.follow(peak, settings[\attack], settings[\release]);
        var gainDb = this.compGainDb(level.max(1e-6).ampdb, settings[\thresholdDb], settings[\ratio],
            settings[\kneeDb], makeupDb, settings[\outputDb]);
        ^sig * K2A.ar(gainDb.dbamp)
    }

    // The gain computer, in dB: a soft knee `kneeDb` wide around the
    // threshold (quadratic through it), then 1/ratio above. levelDb is the
    // detector's level. For numbers and UGens alike (no comparisons).
    *compGainDb { |levelDb, thresholdDb, ratio, kneeDb, makeupDb = 0, outputDb = 0|
        ^(makeupDb + outputDb) - (this.kneeCurve(levelDb - thresholdDb, kneeDb) * (1 - (1 / ratio)))
    }

    // How far over the threshold a level counts, `over` dB away from it: 0
    // below the knee, `over` above it, (over + knee/2)^2 / (2 knee) inside.
    // Continuous, with a continuous slope.
    *kneeCurve { |over, knee|
        var w = knee.max(1e-6);
        ^((((over + (w / 2)).clip(0, w)).squared) / (2 * w)) + ((over - (w / 2)).max(0))
    }

    // Live's Makeup, taken as the static gain that puts a full-scale level
    // back at 0 dB: (0 - threshold) * (1 - 1/ratio). +12.6 dB for stage 3.
    *makeupDb { |thresholdDb, ratio| ^thresholdDb.neg * (1 - (1 / ratio)) }

    // EQ Three: 24 dB/oct bands (two Butterworth stages each) at its two
    // crossovers, the middle band whatever the outer two leave.
    *eqThree { |sig, lowDb, midDb, highDb, lowFreq, highFreq|
        var low = LPF.ar(LPF.ar(sig, lowFreq), lowFreq);
        var high = HPF.ar(HPF.ar(sig, highFreq), highFreq);
        ^this.eqThreeMix(sig, low, high, lowDb.dbamp, midDb.dbamp, highDb.dbamp)
    }

    // The three bands summed, the middle one being full - low - high, written
    // as full * midGain plus the outer bands' differences: at 0 dB on every
    // band that is `full` to the bit, whatever the crossovers do.
    *eqThreeMix { |full, low, high, lowGain, midGain, highGain|
        ^((full * midGain) + (low * (lowGain - midGain))) + (high * (highGain - midGain))
    }

    // A soft clip that is exact up to `knee` and approaches `ceiling` (both
    // amplitudes) along a tanh with slope 1 there; it never goes over the
    // ceiling (it reaches it only where tanh rounds to 1). For numbers and
    // UGens alike.
    *softClip { |x, ceiling, knee|
        var room = (ceiling - knee).max(1e-9);
        ^x.sign * (x.abs.min(knee) + (room * ((x.abs - knee).max(0) / room).tanh))
    }

    // ---- Beat Repeat (Kit-Carbon's 15 pads, all alike) --------------------
    // The set's values ([rv-res] 1, labels from Live's own tables): Interval
    // 2 Bars (a Bar being 4 quarter notes in any meter), Offset 6/16, Grid
    // 1/16, Gate 6/16 (the slice plus 5 repeats), Chance 0.2362 per pad per
    // capture, Decay 0.29365, Pitch -1 st with Pitch Decay 0.11905, Mix mode
    // (the dry passes), Volume 0 dB, and the band filter on pads 36-40 only.
    // In quarter notes from the transport's origin; MegaSADrums turns them
    // into its grid (a quarter is 480 ticks, a 16th one s16).

    *beatRepeatChance { ^0.236220479 }
    // The Interval in bars, where the drums capture on the reading's bars
    // (MegaSADrums.repeatGrid \bars).
    *beatRepeatBars { ^2 }
    *beatRepeatInterval { ^8 }
    *beatRepeatOffset { ^1.5 }
    *beatRepeatGrid { ^0.25 }
    *beatRepeatGate { ^1.5 }
    *beatRepeatDecay { ^0.29365 }
    *beatRepeatPitch { ^1 }
    *beatRepeatPitchDecay { ^0.11905 }
    *beatRepeatFilterFreq { ^1515.18 }
    // The filter's width, read as octaves (its unit is not documented): about
    // 610 Hz to 3.76 kHz around 1515 Hz.
    *beatRepeatFilterWidth { ^2.625 }

    // How many repeats follow the slice: the gate over the grid, less the
    // slice itself.
    *beatRepeatCount { ^((this.beatRepeatGate / this.beatRepeatGrid).round.asInteger - 1).max(0) }

    // The tick (480 a quarter note, from the origin) of capture point c.
    *captureTick { |c|
        ^((this.beatRepeatOffset + (c * this.beatRepeatInterval)) * 480).round.asInteger
    }

    // The first capture point at or after `tick`.
    *captureIndexAt { |tick|
        ^((((tick - this.captureTick(0)) / (this.beatRepeatInterval * 480)) - 1e-9).ceil).asInteger.max(0)
    }

    // Repeat k's level (1 = the slice's): Volume * exp(-10 * Decay^2 * t),
    // t = k grids in quarter notes (Live's helper; the time unit is the
    // medium-confidence part). About -1.9 dB per repeat.
    *beatRepeatLevel { |k|
        ^((-10 * (this.beatRepeatDecay ** 2)) * (k * this.beatRepeatGrid)).exp
    }

    // Repeat k's playback rate: Pitch semitones down, then Pitch Decay's
    // factor per repeat. Beat Repeat pitches by resampling, so a repeat lasts
    // grid / rate.
    *beatRepeatRate { |k|
        ^(2 ** (this.beatRepeatPitch.neg / 12)) * ((1 - (0.1 * this.beatRepeatPitchDecay)) ** k)
    }

    // When the repeats play, for a grid of `grid` seconds: [start, length] per
    // repeat k = 1.., in seconds after the capture point. Contiguous from the
    // slice's end, each grid / rate long, the last cut at the gate (6/16:
    // the fifth runs past it at these rates).
    *beatRepeatTimes { |grid|
        var gate = grid * (this.beatRepeatGate / this.beatRepeatGrid);
        var start = grid, out = List.new;
        (1 .. this.beatRepeatCount).do { |k|
            var len = grid / this.beatRepeatRate(k);
            if(start < (gate - 1e-9)) { out.add([start, len.min(gate - start)]) };
            start = start + len;
        };
        ^out.asArray
    }

    // The band filter as a high-pass and a low-pass (the manual's "combined
    // low-pass and high-pass filter"), 12 dB/oct each in the voice. Its edges
    // from a centre and a width in octaves: centre * 2 ** (+-width / 2). The
    // voice takes the width as rq, the band over its centre, which gives the
    // same edges back (bandEdges).
    *bandRq { |octaves| ^(2 ** (octaves / 2)) - (2 ** (octaves.neg / 2)) }

    // The edges, [low, high], of the band of reciprocal Q `rq` round `freq`:
    // high - low = freq * rq, low * high = freq ** 2. For numbers and UGens.
    *bandEdges { |freq, rq|
        var half = rq * 0.5;
        var root = (half.squared + 1).sqrt;
        ^[freq * (root - half), freq * (root + half)]
    }

    // ---- JSON values (parseJSON answers them as Strings) ------------------

    *prGet { |dict, key| ^dict[key.asString] ?? { dict[key.asSymbol] } }

    *prNum { |v|
        var x = case
            { v.isNumber } { v }
            { v.isKindOf(String) and: { "^-?[0-9]+(\\.[0-9]+)?([eE][-+]?[0-9]+)?$".matchRegexp(v) } } { v.asFloat }
            { nil };
        ^if(x.notNil and: { x.isNaN.not } and: { x.abs != inf }) { x } { nil }
    }

    *prInt { |v|
        var x = this.prNum(v);
        ^if(x.notNil and: { (x - x.round).abs < 1e-9 }) { x.round.asInteger } { nil }
    }
}
