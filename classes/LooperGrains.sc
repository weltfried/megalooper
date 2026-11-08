// megalooper — the grains: a Warp1 layer over the loop, from a frozen drone
// (morph 0) to a beat-locked pulsed scan (morph 1), every control bending
// that base (the \looperGranular graph, LooperSynthDefs), with the take's
// chords if asked (granularFollowChords), and its presets' data.
//
// `granularMorph` stays the meta-control: it sets the BASE of the texture
// (window size, overlaps, scan rate, jitter) between frozen drone and
// beat-locked pulse. Everything below BENDS that base, and every default is
// NEUTRAL — an untouched instrument sounds exactly as it did before these
// existed. See the \looperGranular SynthDef for how each one folds in.
//
// A part of the Looper (docs/dev/architecture.md 5, step 8; the Looper's own
// until 2026-11-08): it holds the Looper and asks it what the grains read
// (prGrainSource: the buffer, the loop's span, the bus, the engine to follow;
// prGranularTau, prGrainRate, prGranularMix: the pulse, the rate, the arc's
// level) and says its changes as the Looper's (looper.changed). The Looper's
// granular* methods are its facade, and the Looper tells it when the loop
// moves under it (follow, lock, setRate, setTau, applyMix, off).
LooperGrains {
    var looper;
    var granularSynth;
    var <granularMorph = 0;
    var <granularAmp = 0.3;        // layer level, 0..1
    var <granularPitch = 0;        // grain transposition, semitones
    var <granularDetune = 0;       // +/- semitones of PER-GRAIN random detune
    var <granularSize = 1;         // grain-window multiplier on morph's base
    var <granularDensity = 1;      // overlap multiplier on morph's base
    var <granularSizeRand = 0.1;   // Warp1 windowRandRatio, 0..1
    var <granularPosition = 0;     // read point within the loop region, 0..1
    var <granularScan = 0;         // EXTRA passes through the loop per loopDur
    var <granularSpray = 0;        // absolute position spray, ms
    var <granularEnv = 0;          // index into LooperGrains.envNames
    // Off: the grains play the loop as it sounds where they read (as they
    // always did). On: transposed with the take's chord changes (roadmap
    // item 8; the \looperGranular graph).
    var <granularFollowChords = false;
    var granularEnvBufs;

    *new { |looper| ^super.newCopyArgs(looper) }

    // Grain-window shapes offered by the granular layer. Index 0 is Warp1's own
    // built-in Hann (envbufnum -1, so it needs no buffer); the rest are the Envs
    // in prGranularEnvShapes, index-aligned from 1. The GUI renders the menu
    // straight from this, so adding a shape means editing both, in step.
    *envNames { ^["Hann (built in)", "Plateau", "Percussive", "Swell"] }

    // What each shape does, index-aligned with the names: the line under the
    // Grains view's tiles, and what an AI app is told (MegaRemote).
    *envHints {
        ^[
            "Smooth and symmetrical, the default.",
            "Flat top, short fades. Thicker drones, harder pulses.",
            "Instant attack, long decay. Every grain becomes a little hit.",
            "Reversed percussive. Attacks are erased, so even a plucked loop smears into a pad."
        ]
    }

    *envShapes {
        ^[
            // Plateau: short fades around a flat top. More energy per grain than
            // Hann and a squarer edge — thicker drones, harder pulses.
            Env([0, 1, 1, 0], [0.15, 0.7, 0.15], \sin),
            // Percussive: instant attack, long decay. Turns each grain into a
            // little hit, which is what makes the pulsed end read as rhythm.
            Env([0, 1, 0], [0.02, 0.98], [\lin, -4]),
            // Swell: the same shape backwards — grains fade IN, so attacks are
            // erased entirely and even a plucked loop smears into pad.
            Env([0, 1, 0], [0.98, 0.02], [4, \lin])
        ]
    }

    // ===================================================================
    // Granular presets
    // ===================================================================
    // Same shape as the BBCut presets above, deliberately: one JSON file per
    // preset ("megalooper granular"), and `dir` passed in rather than derived
    // because this class is compiled through a symlink in Extensions.
    //
    // One table drives the file's field order, the validator's ranges and the
    // apply, so those three cannot drift apart — which is the failure mode a
    // hand-written serialiser has after the second parameter is added.
    // The ranges match the setters' own clips.
    *presetFields {
        ^[
            // file key,  model accessor,     lo,    hi,   default
            [\morph,    \granularMorph,      0,     1,    0],
            [\amp,      \granularAmp,        0,     1,    0.3],
            [\pitch,    \granularPitch,    -48,    48,    0],
            [\detune,   \granularDetune,     0,    24,    0],
            [\size,     \granularSize,       0.01, 16,    1],
            [\density,  \granularDensity,    0.01, 16,    1],
            [\sizeRand, \granularSizeRand,   0,     1,    0.1],
            [\position, \granularPosition,   0,     1,    0],
            [\scan,     \granularScan,      -8,     8,    0],
            [\spray,    \granularSpray,      0,  2000,    0]
        ]
    }

    *presetFormat { ^"megalooper granular" }

    // The window shapes in buffers on the server (index 0, Warp1's own Hann,
    // needs none): allocated in the Looper's init, then filled after a sync.
    allocEnvBufs { |server| granularEnvBufs = LooperGrains.envShapes.collect { Buffer.alloc(server, 1024, 1) } }
    fillEnvBufs { granularEnvBufs.do { |b, i| b.sendCollection(LooperGrains.envShapes[i].discretize(1024)) } }

    // The loop moved under the grains, or the arc did: told by the Looper.
    lock { granularSynth !? { |g| g.set(\locked, 1) } }
    setRate { |rate| granularSynth !? { |g| g.set(\rate, rate) } }
    setTau { |tau| granularSynth !? { |g| g.set(\tau, tau) } }
    applyMix { granularSynth !? { |g| g.set(\amp, granularAmp * looper.prGranularMix) } }
    // Off with the loop (a stop, the arc's end): said only if they were on.
    off {
        granularSynth !? { |g| g.free; looper.changed(\granular, false) };
        granularSynth = nil;
    }
    // Cmd-period freed the synth; the Looper freed: the synth and the buffers go.
    forget { granularSynth = nil }
    free {
        granularSynth !? { |g| g.free };
        granularSynth = nil;
        granularEnvBufs !? { |bufs| bufs.do { |b| b.free } };
    }

    presetSummary { |data|
        ^"morph " ++ data[\morph].round(0.01) ++ ", " ++ data[\env]
    }

    presetVersion { ^1 }

    presetData { |name|
        var data = (
            version: this.presetVersion,
            name:    (name ? "").asString,
            savedAt: Date.getDate.stamp,
            // Stored by NAME, not by index. The index is a position in
            // granularEnvNames, so inserting a window shape would silently
            // re-point every preset saved before it at a different envelope.
            env:     LooperGrains.envNames[granularEnv].asString,
            followChords: granularFollowChords
        );
        LooperGrains.presetFields.do { |f|
            data[f[0]] = this.perform(f[1]).asFloat;
        };
        ^data
    }

    // The file's text: one field a line (MegaFiles.jsonText).
    presetText { |data|
        ^MegaFiles.eventText(data, LooperGrains.presetFormat, Looper.prPresetFamilies[\granular][\order])
    }

    // Fail-soft by field, reject by file — the same contract the BBCut
    // validator uses, and for the same reason: these files are hand-editable
    // and far more often STALE than corrupt. Pure, so a rejection happens
    // before any model state has been touched.
    validatePreset { |data, warnings|
        var clean, envName, envIdx;
        if(data.isKindOf(Dictionary).not) {
            warnings.add("not a preset (expected an Event)");
            ^nil
        };
        if((data[\version] ? 1).asInteger > this.presetVersion) {
            warnings.add("version " ++ data[\version] ++ " is newer than this build ("
                ++ this.presetVersion ++ ")");
            ^nil
        };
        clean = (
            version: this.presetVersion,
            name:    (data[\name] ? "").asString
        );
        LooperGrains.presetFields.do { |f|
            var key = f[0], lo = f[2], hi = f[3], default = f[4];
            var val = data[key];
            if(val.isNumber and: { val.isNaN.not }) {
                var out = val.clip(lo, hi).asFloat;
                if(out != val.asFloat) {
                    warnings.add(key.asString ++ " " ++ val ++ " -> " ++ out ++ " (range)");
                };
                clean[key] = out;
            } {
                // A missing field is the ordinary case for a preset saved by an
                // older build, so it is only worth a warning when something IS
                // there and is not a number.
                if(val.notNil) {
                    warnings.add(key.asString ++ " not a number -> " ++ default);
                };
                clean[key] = default.asFloat;
            };
        };
        // Resolve the window shape by name, case-insensitively; anything
        // unrecognised falls back to Warp1's own Hann rather than guessing.
        envName = (data[\env] ? "").asString;
        envIdx = LooperGrains.envNames.detectIndex { |n|
            n.asString.toLower == envName.toLower
        };
        if(envIdx.isNil) {
            if(envName.isEmpty.not) {
                warnings.add("unknown window '" ++ envName ++ "' -> "
                    ++ LooperGrains.envNames[0]);
            };
            envIdx = 0;
        };
        clean[\env] = envIdx;
        // Following the chords: true or false; a preset from before it had
        // none, and plays as it did then.
        clean[\followChords] = case
            { data[\followChords].isNil } { false }
            { (data[\followChords] == true) or: { data[\followChords] == false } } { data[\followChords] }
            { warnings.add("followChords " ++ data[\followChords].asCompileString ++ " is not true or false -> false"); false };
        ^clean
    }

    // Recall. Goes through the SETTERS, never the vars, so every change reaches
    // a running granular synth and fires its own notification — which is what
    // makes the window follow a recall without this method knowing a view exists.
    applyPreset { |data|
        var warnings = List.new;
        var clean = this.validatePreset(data, warnings);
        if(clean.isNil) {
            ("Granular preset rejected — " ++ warnings.join("; ")).warn;
            ^false
        };
        LooperGrains.presetFields.do { |f|
            this.perform(f[1].asSetter, clean[f[0]]);
        };
        this.granularEnv = clean[\env];
        this.granularFollowChords = clean[\followChords];
        if(warnings.notEmpty) {
            ("Granular preset '" ++ clean[\name] ++ "': " ++ warnings.size
                ++ " correction(s) — " ++ warnings.join("; ")).warn;
        };
        ^true
    }

    // Granular has no flag of its own — the layer exists exactly while its synth
    // does. Expose that as a proper query so views don't have to guess.
    on { ^granularSynth.notNil }

    toggle {
        var tau, args, src;
        if(granularSynth.notNil) {
            granularSynth.free; granularSynth = nil;
            "Granular off.".postln;
            looper.changed(\granular, false);
            ^this
        };
        // Refused, so the layer is still off — say so anyway, or a view that
        // optimistically flipped its indicator on the keypress stays wrong.
        src = looper.prGrainSource;
        if(src[\loopFrames] == 0) {
            "Granular: no loop recorded.".postln;
            looper.changed(\granular, false);
            ^looper.prRefused(\granular, "no loop recorded")
        };
        tau = looper.prGranularTau;
        args = [
            \bufnum, src[\buffer].bufnum,
            \out, src[\out],
            \startFrame, src[\startFrame],
            \loopFrames, src[\loopFrames],
            \tau, tau,
            // The pulsed scan follows the ENGINE's read position (see the
            // \looperGranular graph). It therefore goes AFTER the engine in the
            // node order, to read this block's position rather than the last
            // one's, and that is still before the master, which reads the bus
            // this writes. Over a stopped loop there is no engine to follow:
            // the layer goes at the head and scans freely until spawnEngine
            // locks it.
            \phaseBus, src[\phaseBus],
            \locked, src[\engine].notNil.asInteger,
            \rate, looper.prGrainRate
        ] ++ this.args ++ this.chordArgs.flatten(1);
        granularSynth = src[\engine] !? { |e| Synth.after(e, \looperGranular, args) }
            ?? { Synth(\looperGranular, args, src[\server]) };
        ("Granular on. tau=" ++ tau.round(0.001)
            ++ " morph=" ++ granularMorph.round(0.01)
            ++ (if(src[\engine].notNil) { ", locked to the loop" } { ", free (loop stopped)" })
            ).postln;
        looper.changed(\granular, true);
    }

    // The grains read what the engine reads. Their synth is given the buffer,
    // its start, the loop's length and the pulse when spawned; every change of
    // those that spawns no grains synth sends them here: Record next loop's
    // swap of the two buffers (spawnEngine), multiply, undo, a take's
    // analysis, an overdub's and a reading's landing. Without it the grains
    // went on reading the old loop after a swap, in the buffer the next
    // capture then recorded into (roadmap item 20, found on the way).
    follow {
        var chords;
        granularSynth !? { |g|
            var src = looper.prGrainSource;
            chords = this.chordArgs;
            g.set(*([\startFrame, src[\startFrame], \loopFrames, src[\loopFrames], \tau, looper.prGranularTau]
                ++ (src[\buffer] !? { |b| [\bufnum, b.bufnum] } ? []) ++ chords[0]));
            g.setn(*chords[1]);
        };
    }

    // The take's chords for the grains (granularFollowChords): [the switch
    // and the length the segments cover, as set pairs; their starts and
    // roots, as setn pairs of chordSlots values]. Unused starts lie past any
    // time. A take of fewer than two chords has none to follow (period 0).
    chordArgs {
        var lastResult = looper.lastResult;
        var segs = (lastResult !? { |r| r[\chordSegments] }) ? [];
        var period = if(segs.size < 2) { 0 } { (lastResult[\chordPeriod] ?? { lastResult[\loopDur] }) ? 0 };
        var starts = Array.fill(LooperSynthDefs.chordSlots, 1e9), roots = Array.fill(LooperSynthDefs.chordSlots, 0);
        segs.keep(LooperSynthDefs.chordSlots).do { |seg, i| starts[i] = seg[\start] ? 0; roots[i] = seg[\root] ? 0 };
        ^[[\follow, granularFollowChords.binaryValue, \chordPeriod, period], [\chordStarts, starts, \chordRoots, roots]]
    }

    // The grains with the chords (true) or as the loop sounds where they read
    // (false, as they always were).
    granularFollowChords_ { |flag|
        granularFollowChords = flag == true;
        granularSynth !? { |g| g.set(\follow, granularFollowChords.binaryValue) };
        looper.changed(\granularFollowChords, granularFollowChords);
    }

    // The whole granular control set as synth args, in ONE place, so a fresh
    // synth always starts from what the sliders currently say — toggling the
    // layer off and on cannot quietly reset it to defaults.
    args {
        ^[
            \morph,    granularMorph,   \amp,      granularAmp * looper.prGranularMix,
            \pitch,    granularPitch,   \detune,   granularDetune,
            \size,     granularSize,    \density,  granularDensity,
            \sizeRand, granularSizeRand, \position, granularPosition,
            \scan,     granularScan,    \sprayMs,  granularSpray,
            \envbuf,   this.envBuf
        ]
    }

    // Menu index 0 means Warp1's built-in Hann, which is the -1 sentinel rather
    // than a buffer. Falls back to it if the window buffers are not allocated
    // yet (a granular toggle racing construction).
    envBuf {
        var buf = granularEnvBufs !? { |a| a[granularEnv - 1] };
        ^if(granularEnv > 0 and: { buf.notNil }) { buf.bufnum } { -1 }
    }

    // Every granular setter does the same three things, and doing them by hand
    // ten times is ten chances to forget the notification and desync a view.
    prSetGranular { |key, val, notification|
        granularSynth !? { |syn| syn.set(key, val) };
        looper.changed(notification, val);
    }

    // Rhythm/drone meta-control: sets the base every parameter below bends.
    granularMorph_ { |val|
        granularMorph = val.clip(0, 1);
        this.prSetGranular(\morph, granularMorph, \granularMorph);
    }

    // Level of the granular layer against the engine, pre-limiter.
    // The stored level, which is what the GUI shows. What reaches the synth is
    // this times the arc's granular multiplier, so the slider keeps meaning
    // "the level at full intensity" rather than drifting under the pedal.
    granularAmp_ { |val|
        granularAmp = val.clip(0, 1);
        looper.prApplyMixes;
        looper.changed(\granularAmp, granularAmp);
    }

    // Grain transposition in semitones. The pointer is unaffected, so this
    // pitches the layer without changing how fast it reads the loop.
    granularPitch_ { |val|
        granularPitch = val.clip(-48, 48);
        this.prSetGranular(\pitch, granularPitch, \granularPitch);
    }

    // Random detune applied afresh to each grain, +/- this many semitones.
    // Small values thicken (chorus); large ones shatter the loop into confetti.
    granularDetune_ { |val|
        granularDetune = val.clip(0, 24);
        this.prSetGranular(\detune, granularDetune, \granularDetune);
    }

    // Grain length as a multiple of what morph asks for. Below ~0.2 the grains
    // stop carrying pitch and start reading as texture.
    granularSize_ { |val|
        granularSize = val.clip(0.01, 16);
        this.prSetGranular(\size, granularSize, \granularSize);
    }

    // Overlap count as a multiple of morph's. Thickness — and the CPU bill.
    granularDensity_ { |val|
        granularDensity = val.clip(0.01, 16);
        this.prSetGranular(\density, granularDensity, \granularDensity);
    }

    // Warp1's windowRandRatio: how much grain LENGTH varies grain to grain.
    // A little breaks up the comb filtering of perfectly regular overlaps.
    granularSizeRand_ { |val|
        granularSizeRand = val.clip(0, 1);
        this.prSetGranular(\sizeRand, granularSizeRand, \granularSizeRand);
    }

    // Where in the loop the grains read from, 0..1 of the loop region. At the
    // drone end (no scan) this IS the freeze point — sweep it to move the drone
    // through the recording by hand.
    granularPosition_ { |val|
        granularPosition = val.clip(0, 1);
        this.prSetGranular(\position, granularPosition, \granularPosition);
    }

    // EXTRA passes through the loop per loop duration, added to morph's own.
    // 0 leaves morph in charge; small values drift a drone; negative runs the
    // read head backwards; -1 exactly cancels a fully pulsed scan.
    granularScan_ { |val|
        granularScan = val.clip(-8, 8);
        this.prSetGranular(\scan, granularScan, \granularScan);
    }

    // Absolute per-grain position randomness in ms. Unlike morph's own jitter
    // this survives at the pulsed end, which is how you loosen a locked grid.
    granularSpray_ { |val|
        granularSpray = val.clip(0, 2000);
        this.prSetGranular(\sprayMs, granularSpray, \granularSpray);
    }

    // Grain window shape — index into LooperGrains.envNames.
    granularEnv_ { |val|
        granularEnv = val.asInteger.clip(0, LooperGrains.envNames.size - 1);
        granularSynth !? { |syn| syn.set(\envbuf, this.envBuf) };
        looper.changed(\granularEnv, granularEnv);
    }
}
