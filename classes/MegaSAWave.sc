// Megalooper SA's Wave synth (docs/dev/synth.md, Phase 2): the monophonic
// wavetable synth the note sequencer plays. One MegaSA owns one: its tables
// on the server, its settings, and the OSC messages that play one note
// (voiceMsgs), which MegaSADrums sends at the note's stamp as it sends a
// drum hit (MegaSADrums.noteVoice).
//
// ---- The tables ----
// Four sets of eight tables each (sets), and a fifth of yours: an oscillator's position (0..1)
// morphs through a set's eight, VOsc crossfading between neighbours. Every
// table is made for nine octave bands (bandTops: the highest fundamental of
// each) with only the partials that stay under 20 kHz there, so a high note
// does not alias: a voice reads the band of the pitch it plays now. The
// server makes them itself (b_gen sine3: partial, amplitude, phase), so no
// sample data crosses the network: 360 buffers of 2048 points in wavetable
// form (4096 floats), about 5.9 MB, the last 72 the fifth set's, Your table
// (see Your table). Their numbers are consecutive from
// `base`, set by set, band by band (bufnum).
//
// ---- A note ----
// One voice per note, as a drum hit is one: its cancel bus (latched in its
// first block) and the sequencer's one choke bus make it monophonic. A newer
// note's voice writes its id to the choke bus and every older voice fades out
// over `xfade` (6 ms), so the line never overlaps. A note of a new pitch
// that starts while the one before is still held is legato (MegaSADrums
// decides): it comes in over the same 6 ms at the sustain level with no
// attack, and its modulation envelope does not start again either, as a
// mono synth's legato does; with glide it slides from the note before.
// Held for its length, it then releases over Release.
//
// Settings live here (settings, set), checked against params, a table in
// MegaSAFx.params' form (fx: \wave), so the views, Random and the variations
// can treat them as an effect's. A setting changed reaches the notes that
// start after it.
MegaSAWave {
    classvar paramList, paramIndex;
    var <server, <base, <settings, <built = false;
    // Your table (set 4, "Your table"): its partials, eight lists of
    // [partial, amplitude, phase] from a WAV (loadTable), and its name in
    // tableDir; nil until one is loaded, when the set plays Analog's.
    var <userPartials, <tableName;

    *new { |server| ^super.newCopyArgs(server).init }

    init {
        settings = IdentityDictionary.new;
        this.class.params.do { |p| settings.put(p[\name], p[\spec].default) };
    }

    // ---- The tables -------------------------------------------------------

    *tableSize { ^2048 }
    *morphs { ^8 }
    *bandTops { ^#[55, 110, 220, 440, 880, 1760, 3520, 7040, 14080] }
    *topPartialHz { ^20000 }

    *setNames { ^#["Analog", "Harmonics", "Vowels", "Organ", "Your table"] }
    *userSet { ^4 }

    *numBuffers { ^(this.setNames.size * this.bandTops.size) * this.morphs }

    // The buffer of table k of a set in a band, from base.
    *bufnum { |base, set, band, k| ^base + ((((set * this.bandTops.size) + band) * this.morphs) + k) }

    // The partials of table k (0..7) of a set, as [partial, amplitude,
    // phase] triples, every partial under `limit`.
    // `user`: your table's eight lists (set 4), else it is Analog's.
    *partials { |set, k, limit, user|
        var out = List.new, add, vowels, regs, d;
        limit = limit.asInteger.clip(1, 1000);
        if(set == this.userSet) {
            if(user.isNil) { ^this.partials(0, k, limit) };
            out = user[k].select { |p| p[0] <= limit };
            ^if(out.isEmpty) { [[1, 1, 0]] } { out }
        };
        add = { |n, amp, phase = 0| if((n <= limit) and: { amp.abs > 1e-5 }) { out.add([n, amp, phase]) } };
        switch(set,
            // Sine, triangle, saw, square, then narrowing pulses.
            0, {
                switch(k,
                    0, { add.(1, 1) },
                    1, { (1, 3 .. limit).do { |n| add.(n, (if(((n - 1) / 2) % 2 == 0) { 1 } { -1 }) / n.squared) } },
                    2, { (1 .. limit).do { |n| add.(n, 1 / n) } },
                    3, { (1, 3 .. limit).do { |n| add.(n, 1 / n) } },
                    {
                        d = #[0, 0, 0, 0, 0.3, 0.18, 0.1, 0.05][k];
                        (1 .. limit).do { |n| add.(n, sin(pi * n * d) / n, 0.5pi) };
                    });
            },
            // A saw's partials, more of them table by table: a filter opening.
            1, {
                (1 .. #[1, 2, 3, 5, 8, 13, 24, 64][k]).do { |n| add.(n, 1 / n) };
            },
            // Two formants each, for a fundamental of 110 Hz: u o a ae e i y er.
            2, {
                vowels = #[[300, 870], [500, 900], [750, 1200], [700, 1700], [450, 1900], [300, 2300],
                    [300, 1700], [500, 1400]];
                (1 .. limit.min(60)).do { |n|
                    var f = n * 110, v = vowels[k];
                    add.(n, (exp(((f - v[0]) / 150).squared.neg) + (0.7 * exp(((f - v[1]) / 220).squared.neg)))
                        + (0.08 / n));
                };
            },
            // Drawbar registrations of 16', 8', 5 1/3', 4', 2 2/3', 2', 1 3/5', 1 1/3', 1'.
            3, {
                regs = #[[0, 8, 0, 0, 0, 0, 0, 0, 0], [8, 8, 0, 0, 0, 0, 0, 0, 0], [8, 8, 8, 0, 0, 0, 0, 0, 0],
                    [8, 8, 8, 8, 0, 0, 0, 0, 0], [8, 0, 8, 0, 8, 0, 8, 0, 0], [8, 8, 8, 8, 8, 8, 0, 0, 0],
                    [6, 8, 8, 6, 0, 0, 0, 0, 8], [8, 8, 8, 8, 8, 8, 8, 8, 8]];
                // A table's fundamental is the 16' bar: the voice plays it an
                // octave down (setOctaves) so 8' sounds at the note.
                #[1, 2, 3, 4, 6, 8, 10, 12, 16].do { |n, i| add.(n, regs[k][i] / 8) };
            });
        // A band too high for any of a table's partials (the organ's 8' bar
        // alone, at the top) keeps its fundamental: never a silent table.
        if(out.isEmpty) { out.add([1, 1, 0]) };
        ^out.asArray
    }

    // Each set's octave as the voice plays its tables: the organ's
    // fundamental is its 16' bar, an octave under the note.
    *setOctaves { ^#[0, 0, 0, -1, 0] }

    // Every table's /b_alloc and /b_gen, from base (`sets`: only those;
    // `alloc` false: the /b_gen alone, over buffers already there).
    *tableMsgs { |base, user, sets, alloc = true|
        var msgs = List.new, n, limit;
        (sets ?? { (0 .. (this.setNames.size - 1)) }).do { |set|
            this.bandTops.do { |top, band|
                limit = (this.topPartialHz / top).floor.asInteger.min((this.tableSize / 2).asInteger - 1);
                this.morphs.do { |k|
                    n = this.bufnum(base, set, band, k);
                    if(alloc) { msgs.add([\b_alloc, n, this.tableSize * 2, 1]) };
                    // 1 normalize + 2 wavetable form + 4 clear first.
                    msgs.add([\b_gen, n, \sine3, 7] ++ this.partials(set, k, limit, user).flat);
                };
            };
        };
        ^msgs.asArray
    }

    // ---- Your table ---------------------------------------------------------
    // A wavetable WAV as Serum and Vital write them: one cycle of 2048 samples
    // after another (256 at most), the first channel read. Eight of its
    // cycles, spread evenly from the first to the last, become the set's
    // eight positions; a file of one cycle is all eight. A file shorter than
    // 2048 samples is one cycle, stretched to 2048. Each cycle is taken apart
    // into its partials (an FFT), and goes through the same bands as the
    // built-in tables, so it does not alias either.

    *tableDir { ^MegaFiles.userRoot +/+ "sa" +/+ "wavetables" }

    // The cycles of a file, as Signals of 2048, or a String saying why not.
    *cyclesOf { |path|
        var sf = SoundFile.new, n = this.tableSize, data, chans, frames, mono, count, sig;
        if(path.isNil or: { File.exists(path).not }) { ^"there is no such file" };
        if(sf.openRead(path).not) { ^"it is not a sound file SuperCollider can read" };
        chans = sf.numChannels;
        frames = sf.numFrames;
        if(frames < 16) { sf.close; ^"it is too short to hold a cycle" };
        data = FloatArray.newClear(frames.min(n * 256) * chans);
        sf.readData(data);
        sf.close;
        mono = Signal.fill(data.size div: chans, { |i| data[i * chans] });
        if(mono.size < n) {
            // One cycle, stretched (linear) to the table's size.
            sig = Signal.fill(n, { |i| var x = (i / n) * mono.size, a = x.floor.asInteger;
                mono[a % mono.size].blend(mono[(a + 1) % mono.size], x - a) });
            ^[sig]
        };
        count = mono.size div: n;
        ^Array.fill(count, { |c| Signal.fill(n, { |i| mono[(c * n) + i] }) })
    }

    // Eight lists of [partial, amplitude, phase] from the cycles: the
    // positions 0..7 read cycles spread evenly through them. A partial under
    // 1/10000 of its cycle's strongest is left out; a silent cycle is a sine.
    *analyse { |cycles|
        var n = this.tableSize, cos = Signal.fftCosTable(n);
        ^Array.fill(this.morphs, { |k|
            var c = cycles[((k * (cycles.size - 1)) / (this.morphs - 1)).round.asInteger];
            var spec = c.fft(Signal.newClear(n), cos), parts, top;
            // x = sum of (2/N)|X_m| sin(m t + phase), phase = atan2(re, -im).
            parts = (1 .. ((n / 2).asInteger - 1)).collect { |m|
                [m, (spec.real[m].squared + spec.imag[m].squared).sqrt * 2 / n, atan2(spec.real[m], spec.imag[m].neg)] };
            top = parts.collect(_[1]).maxItem;
            if(top <= 0) { [[1, 1, 0]] } { parts.select { |p| p[1] > (top * 1e-4) } }
        })
    }

    // Your table from a WAV: answers true, or a String saying why not (the
    // table is then as it was). Its tables on the server are made again at
    // once, if they are built. `name` is what it is kept as (the file's own
    // name by default). Notifies \waveTable, name.
    loadTable { |path, name|
        var cycles = this.class.cyclesOf(path);
        if(cycles.isString) { ^cycles };
        userPartials = this.class.analyse(cycles);
        tableName = name ?? { PathName(path).fileName };
        this.prSendUserTables;
        this.changed(\waveTable, tableName);
        ^true
    }

    // A WAV of yours, copied into tableDir (under its own name, or with a
    // number added if another file has it there; the same file again is not
    // copied twice) and loaded. Answers true, or
    // why not.
    importTable { |path|
        var dir = this.class.tableDir, base = PathName(path ? "").fileNameWithoutExtension, dst, n = 1, cycles;
        cycles = this.class.cyclesOf(path);
        if(cycles.isString) { ^cycles };
        File.mkdir(dir);
        dst = dir +/+ base ++ ".wav";
        // A file there by that name with the same bytes is this one again.
        while { File.exists(dst) and: { ("/usr/bin/cmp -s " ++ dst.shellQuote ++ " " ++ path.shellQuote).systemCmd != 0 } } {
            n = n + 1;
            dst = dir +/+ base ++ "-" ++ n ++ ".wav";
        };
        if(File.exists(dst).not) { File.copy(path, dst) };
        ^this.loadTable(dst, PathName(dst).fileName)
    }

    // A table kept in tableDir by its name: true, or why not.
    loadTableNamed { |name|
        if(name.isNil) { this.clearTable; ^true };
        ^this.loadTable(this.class.tableDir +/+ name, name)
    }

    // Your table back to none: the set plays Analog's. Notifies \waveTable.
    clearTable {
        userPartials = nil;
        tableName = nil;
        this.prSendUserTables;
        this.changed(\waveTable, nil);
    }

    prSendUserTables {
        if(built and: { base.notNil }) {
            this.class.tableMsgs(base, userPartials, [this.class.userSet], false).clump(16).do { |ms|
                server.sendBundle(nil, *ms) };
        };
    }

    // The tables on the server: a block of consecutive buffer numbers, then
    // the messages, a few at a time. From a Routine the last sync waits for
    // them; anywhere else they are on their way.
    build {
        var msgs;
        if(built) { ^this };
        base = server.bufferAllocator.alloc(this.class.numBuffers);
        if(base.isNil) { "MegaSAWave: no room for the wavetables; the Wave synth stays silent.".warn; ^this };
        msgs = this.class.tableMsgs(base, userPartials);
        msgs.clump(16).do { |ms| server.sendBundle(nil, *ms) };
        if(thisThread.isKindOf(Routine)) { server.sync };
        built = true;
    }

    free {
        if(base.notNil) {
            this.class.numBuffers.do { |i| server.sendMsg(\b_free, base + i) };
            server.bufferAllocator.free(base);
        };
        base = nil;
        built = false;
    }

    // ---- Settings ---------------------------------------------------------

    *params { ^paramList ?? { paramList = this.prParamTable } }

    *param { |name|
        paramIndex ?? {
            paramIndex = IdentityDictionary.new;
            this.params.do { |p| paramIndex.put(p[\name], p) };
        };
        ^paramIndex[name]
    }

    // A value held to its setting's range and step, or the nearest choice.
    *constrain { |name, value|
        var p = this.param(name), values;
        ^case
        { p.isNil } { nil }
        { value.isNumber.not } { nil }
        { p[\choices].notNil } {
            values = p[\choices].collect { |c| c[0] };
            values[values.indexIn(value)]
        }
        { p[\spec].constrain(value) }
    }

    // What Random leaves alone: the synth's level and the glide.
    *randomKeeps { ^#[\waveLevel, \waveGlide] }

    *randomValue { |p| ^MegaSAFx.randomValue(p) }

    // Stores a setting, answering the value stored or nil (no such setting).
    // Notifies \waveSetting, name, value.
    set { |name, value|
        var v = this.class.constrain(name, value);
        if(v.isNil) { ("MegaSAWave: no setting " ++ name ++ " taking " ++ value.asCompileString).warn; ^nil };
        settings.put(name, v);
        this.changed(\waveSetting, name, v);
        ^v
    }

    at { |name| ^settings[name] }

    // Every setting of `values` (name -> value) at once, each held to its
    // range; one this build has not is left out. Notifies \waveSettings.
    setAll { |values|
        values.keysValuesDo { |k, v| this.class.constrain(k, v) !? { |c| settings.put(k, c) } };
        this.changed(\waveSettings);
    }

    // Every setting back at its default. Notifies \waveSettings.
    reset {
        this.init;
        this.changed(\waveSettings);
    }

    // Every setting not kept at a random value. Notifies \waveSettings.
    randomize {
        this.class.params.do { |p|
            if(this.class.randomKeeps.includes(p[\name]).not) { settings.put(p[\name], this.class.randomValue(p)) };
        };
        this.changed(\waveSettings);
    }

    // ---- A note -----------------------------------------------------------

    // The /s_new for one note (MegaSADrums.noteVoice): rec has note:, vel:,
    // gate: (seconds), from: (the note before, or nil), legato:; where has
    // group:, out:, ring:, choke:, hitId:. Nothing before the tables are built.
    voiceMsgs { |rec, where|
        var s = settings, args;
        if(built.not or: { base.isNil }) { ^[] };
        args = [\out, where[\out], \base, base, \freq, rec[\note].midicps,
            \fromFreq, (rec[\from] ? rec[\note]).midicps, \amp, (rec[\vel] / 127).squared * 0.5,
            \dur, rec[\gate], \legato, (rec[\legato] == true).binaryValue,
            \cancelBus, where[\ring], \chokeBus, where[\choke], \hitId, where[\hitId]];
        this.class.params.do { |p| args = args ++ [p[\name], s[p[\name]]] };
        ^[[\s_new, \megaSAWaveVoice, -1, 1, where[\group]] ++ args]
    }

    *loadSynthDefs { SynthDef(\megaSAWaveVoice, this.prVoiceFunc).add }

    // The voice. Band b of a pitch f is the first whose top is at or above
    // it; read at control rate from the pitch it plays now, so a glide
    // moves through the bands.
    *prVoiceFunc {
        var nb = this.bandTops.size, k = this.morphs, octs = this.setOctaves;
        var bandOf = { |f| ((f.max(1) / this.bandTops[0]).log2.ceil).clip(0, nb - 1) };
        var osc = { |base, set, pos, f|
            var band = bandOf.(f);
            VOsc.ar((base + (((set * nb) + band) * k)) + (pos.clip(0, 1) * ((k - 1) - 0.001)), f)
        };
        ^{ |out, base = 0, freq = 220, fromFreq = 220, amp = 0.3, dur = 0.2, legato = 0,
            cancelBus, chokeBus, hitId = 1, xfade = 0.006,
            waveASet = 0, waveAPos = 0.3, waveAOctave = 0, waveALevel = 1, waveSpread = 0,
            waveBSet = 1, waveBPos = 0.5, waveBSemis = 0, waveBDetune = 7, waveBLevel = 0,
            waveSub = 0, waveNoise = 0,
            waveFilterType = 0, waveCutoff = 3000, waveResonance = 0.2, waveDrive = 0, waveFilterEnv = 0.3,
            waveKeyTrack = 0.5,
            waveAttack = 0.005, waveDecay = 0.3, waveSustain = 0.7, waveRelease = 0.15,
            waveModAttack = 0.005, waveModDecay = 0.4, waveModSustain = 0, waveModRelease = 0.2, waveModPos = 0,
            waveLfoRate = 0.5, waveLfoPos = 0, waveLfo2Rate = 5, waveVibrato = 0, waveLfo2Cutoff = 0,
            waveGlide = 0, waveLevel = 0|
            var first = Impulse.kr(0);
            var ok = Latch.kr(In.kr(cancelBus) < 0.5, first);
            var choked, held, env, menv, fade, f, lfo1, lfo2, fa, fb, setA, setB, sig, spreadOn, cut, rq, peak;
            ReplaceOut.kr(chokeBus, Select.kr(first * ok, [In.kr(chokeBus), hitId]));
            choked = SetResetFF.kr(((In.kr(chokeBus) - hitId).abs > 0.5) * (1 - first), 0);
            held = Sweep.kr(0, 1) < dur;
            // Legato: from the sustain level, no attack, the mod envelope held.
            peak = (1 - legato) + (legato * waveSustain);
            env = EnvGen.ar(Env([legato * waveSustain, peak, waveSustain, 0],
                [waveAttack * (1 - legato), waveDecay, waveRelease], [0, -4, -4], releaseNode: 2), held, doneAction: 2);
            menv = EnvGen.kr(Env([legato * waveModSustain, peak.max(legato * waveModSustain), waveModSustain, 0],
                [waveModAttack * (1 - legato), waveModDecay * (1 - legato), waveModRelease], [0, -4, -4], releaseNode: 2), held);
            fade = EnvGen.ar(Env.cutoff(xfade), 1 - choked, doneAction: 2);
            // A legato voice comes in over the same xfade as the one before
            // goes out, so the two never sound at once at full level.
            fade = fade * EnvGen.ar(Env([1 - legato, 1], [xfade]));
            lfo1 = SinOsc.kr(waveLfoRate);
            lfo2 = SinOsc.kr(waveLfo2Rate);
            f = EnvGen.kr(Env([fromFreq, fromFreq, freq], [0, waveGlide.max(0)], \exp));
            f = f * (2 ** ((lfo2 * waveVibrato) / 1200));
            setA = waveASet.clip(0, this.setNames.size - 1).round;
            setB = waveBSet.clip(0, this.setNames.size - 1).round;
            fa = f * (2 ** (waveAOctave + Select.kr(setA, octs)));
            fb = (f * (2 ** ((waveBSemis + (waveBDetune / 100)) / 12))) * (2 ** Select.kr(setB, octs));
            spreadOn = waveSpread > 0;
            sig = osc.(base, setA, (waveAPos + (lfo1 * waveLfoPos)) + (menv * waveModPos), fa);
            sig = sig + (spreadOn * 0.7 * (osc.(base, setA, waveAPos, fa * (2 ** (waveSpread / 1200)))
                + osc.(base, setA, waveAPos, fa * (2 ** (waveSpread.neg / 1200)))));
            sig = (sig * waveALevel / (1 + (spreadOn * 1.4)))
                + (osc.(base, setB, (waveBPos + (lfo1 * waveLfoPos)) + (menv * waveModPos), fb) * waveBLevel)
                + (SinOsc.ar(fa * 0.5) * waveSub) + (WhiteNoise.ar * waveNoise);
            sig = Select.ar(waveDrive > 0, [sig, (sig * waveDrive.dbamp).tanh]);
            cut = (waveCutoff * (2 ** (((menv * waveFilterEnv * 48) + (lfo2 * waveLfo2Cutoff)) / 12))
                * ((f / 261.63) ** waveKeyTrack)).clip(30, (SampleRate.ir * 0.45).min(18000));
            // RLPF, BPF and RHPF blow up once the cutoff (in radians a
            // sample) times rq passes pi: at 18 kHz, 48 kHz, that is an rq
            // over 1.33. Up to 1 holds at any cutoff under Nyquist.
            rq = waveResonance.clip(0, 1).linexp(0, 1, 1.0, 0.06);
            sig = Select.ar(waveFilterType.round.clip(0, 2), [RLPF.ar(sig, cut, rq), BPF.ar(sig, cut, rq) * 2, RHPF.ar(sig, cut, rq)]);
            sig = LeakDC.ar(sig) * ((((amp * ok) * env) * fade) * waveLevel.dbamp);
            OffsetOut.ar(out, [sig, sig]);
            FreeSelf.kr(1 - ok);
        }
    }

    *prParamTable {
        var sets = this.setNames.collect { |n, i| [i, n] };
        var p = { |name, label, spec, units, extra|
            (fx: \wave, name: name, label: label, spec: spec, units: units).putAll(extra ? ())
        };
        ^[
            p.(\waveASet, "A table", ControlSpec(0, sets.size - 1, \lin, 1, 0), nil, (choices: sets,
                tip: "Oscillator A's set of tables: Analog (sine, triangle, saw, square, pulses),\n"
                    "Harmonics (a saw's partials, more and more), Vowels, Organ (drawbars), or\n"
                    "Your table: a wavetable WAV of yours (Load table…).")),
            p.(\waveAPos, "A position", ControlSpec(0, 1, \lin, 0, 0.3), " %", (scale: 100,
                tip: "Where in its set A plays: the tables crossfade from one end to the other.")),
            p.(\waveAOctave, "A octave", ControlSpec(-2, 2, \lin, 1, 0), nil, (centered: true,
                tip: "Oscillator A, and the sub, octaves up or down.")),
            p.(\waveALevel, "A level", ControlSpec(0, 1, \lin, 0, 1), " %", (scale: 100)),
            p.(\waveSpread, "A unison", ControlSpec(0, 50, \lin, 0, 0), " ct", (
                tip: "Two more copies of A, this many cents above and below: 0 is one voice.")),
            p.(\waveBSet, "B table", ControlSpec(0, sets.size - 1, \lin, 1, 1), nil, (choices: sets)),
            p.(\waveBPos, "B position", ControlSpec(0, 1, \lin, 0, 0.5), " %", (scale: 100)),
            p.(\waveBSemis, "B semitones", ControlSpec(-24, 24, \lin, 1, 0), " st", (centered: true)),
            p.(\waveBDetune, "B detune", ControlSpec(-50, 50, \lin, 0, 7), " ct", (centered: true)),
            p.(\waveBLevel, "B level", ControlSpec(0, 1, \lin, 0, 0), " %", (scale: 100)),
            p.(\waveSub, "Sub", ControlSpec(0, 1, \lin, 0, 0), " %", (scale: 100,
                tip: "A sine an octave under oscillator A.")),
            p.(\waveNoise, "Noise", ControlSpec(0, 1, \amp, 0, 0), " %", (scale: 100)),
            p.(\waveFilterType, "Filter", ControlSpec(0, 2, \lin, 1, 0), nil,
                (choices: [[0, "Low-pass"], [1, "Band-pass"], [2, "High-pass"]])),
            p.(\waveCutoff, "Cutoff", ControlSpec(30, 18000, \exp, 0, 3000), " Hz"),
            p.(\waveResonance, "Resonance", ControlSpec(0, 1, \lin, 0, 0.2), " %", (scale: 100)),
            p.(\waveDrive, "Drive", ControlSpec(0, 24, \lin, 0, 0), " dB",
                (tip: "Into a soft clip before the filter: 0 is clean.")),
            p.(\waveFilterEnv, "Filter env", ControlSpec(-1, 1, \lin, 0, 0.3), " %", (scale: 100, centered: true,
                tip: "How far the mod envelope moves the cutoff: all the way is four octaves.")),
            p.(\waveKeyTrack, "Key track", ControlSpec(0, 1, \lin, 0, 0.5), " %", (scale: 100,
                tip: "How far the cutoff follows the note: 100 % keeps the same brightness on every note.")),
            p.(\waveAttack, "Attack", ControlSpec(0.001, 2, \exp, 0, 0.005), " ms", (scale: 1000)),
            p.(\waveDecay, "Decay", ControlSpec(0.005, 4, \exp, 0, 0.3), " ms", (scale: 1000)),
            p.(\waveSustain, "Sustain", ControlSpec(0, 1, \lin, 0, 0.7), " %", (scale: 100)),
            p.(\waveRelease, "Release", ControlSpec(0.005, 4, \exp, 0, 0.15), " ms", (scale: 1000)),
            p.(\waveModAttack, "Mod attack", ControlSpec(0.001, 2, \exp, 0, 0.005), " ms", (scale: 1000)),
            p.(\waveModDecay, "Mod decay", ControlSpec(0.005, 4, \exp, 0, 0.4), " ms", (scale: 1000)),
            p.(\waveModSustain, "Mod sustain", ControlSpec(0, 1, \lin, 0, 0), " %", (scale: 100)),
            p.(\waveModRelease, "Mod release", ControlSpec(0.005, 4, \exp, 0, 0.2), " ms", (scale: 1000)),
            p.(\waveModPos, "Mod position", ControlSpec(-1, 1, \lin, 0, 0), " %", (scale: 100, centered: true,
                tip: "How far the mod envelope moves both oscillators through their tables.")),
            p.(\waveLfoRate, "LFO 1 rate", ControlSpec(0.05, 20, \exp, 0, 0.5), " Hz"),
            p.(\waveLfoPos, "LFO 1 position", ControlSpec(0, 0.5, \lin, 0, 0), " %", (scale: 100,
                tip: "LFO 1 sweeps both oscillators' positions.")),
            p.(\waveLfo2Rate, "LFO 2 rate", ControlSpec(0.05, 20, \exp, 0, 5), " Hz"),
            p.(\waveVibrato, "Vibrato", ControlSpec(0, 100, \lin, 0, 0), " ct", (tip: "LFO 2 onto the pitch.")),
            p.(\waveLfo2Cutoff, "LFO 2 cutoff", ControlSpec(0, 24, \lin, 0, 0), " st", (tip: "LFO 2 onto the cutoff.")),
            p.(\waveGlide, "Glide", ControlSpec(0, 1, \lin, 0, 0), " ms", (scale: 1000,
                tip: "Every note slides from the one before over this long.")),
            p.(\waveLevel, "Level", ControlSpec(-36, 6, \lin, 0, -6), " dB")
        ]
    }
}
