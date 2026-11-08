// megalooper — the loop's onsets as a drum part: the loop's own detected
// onsets, replayed every pass as MIDI notes (or handed to a sink that plays
// them, Megalooper SA's drums), so a drum rack, a sampler or the onset kit
// plays the rhythm that was actually played.
//
// The loop's own detected onsets, replayed every pass as MIDI notes, so Live
// can trigger a drum rack or sampler from the rhythm that was actually
// played. This is the STORED pattern, not a live trigger: it is built once
// from the analysis and then repeats in lockstep with the audio, which is
// what makes it survive you stopping playing.
//
// A part of the Looper (docs/dev/architecture.md 5, step 8; the Looper's own
// until 2026-11-08): it holds the Looper and asks it what the loop is doing
// (enginePlaying, speed, passStart, midiOut), and says its changes as the
// Looper's (looper.changed: \onsetNotes, \onsetNotePattern, ...), so every
// listener hears them as before. The Looper's onsetNote* methods are its
// facade: the Looper builds the pattern from a take (buildPattern), starts
// and stops it where the loop starts and stops, and keeps it with a take for
// undo (takeState, restoreTake).
LooperOnsetNotes {
    var looper;
    var <onsetNotes = false;
    // Channel 2 (0-based 1). It kept clear of the per-bar marker note that used
    // to go out on channel 1; that marker is gone, but the default stays where
    // every rig here is already mapped.
    var <onsetNote = 36, <onsetNoteChannel = 1;
    var <onsetNoteVelLo = 40, <onsetNoteVelHi = 127;
    // Velocity is mapped over this many dB below the loop's LOUDEST hit. Linear
    // on amplitude piles nearly every guitar onset at the top of the range; dB
    // is how the dynamics actually read. Small = compressed, large = wider.
    var <onsetNoteDynRange = 30;
    var <onsetNoteGateMs = 20;
    // Timing trim, ms, NEGATIVE = send earlier. Per-rig, and for the same reason
    // latencyMs and abletonSyncMs are: the loop's audio and the notes reach your
    // ears down different paths, and only the rig knows the difference between
    // them. The loop goes SC -> the virtual device -> Live -> out (two buffers
    // that the notes never see); the notes go SC -> IAC -> Live, where they are
    // quantised to Live's next audio block and then run through whatever delay
    // compensation the set has. None of that is knowable from here, so it is a
    // number you set by ear or by measurement and write back into the profile.
    var <onsetNoteOffsetMs = 0;
    // [[phase, strengthRatio], ...] — phase in seconds from the loop's start,
    // ratio 0..1 against the loudest hit (so it is independent of input gain).
    // Velocity is computed at SEND time from the ratio, which is why changing the
    // velocity controls takes effect without rebuilding or restarting anything.
    //
    // The period is the pattern's OWN, deliberately not loopFrames: multiply and
    // loop chaining lengthen the loop by an integer factor and COPY the audio
    // with it, so a pattern that keeps its original period tiles across the
    // longer loop exactly as the audio does.
    var onsetNotePattern, <onsetNotePatternDur;
    // Probability that any one onset is actually sent, 0..1. Thins the drum part
    // without touching the pattern: at 0.5 about half the hits play, at 0 none,
    // at 1 all of them, and the analysed pattern itself is never edited — so
    // sweeping back up to 1 restores exactly what was played.
    var <onsetNoteChance = 1.0;
    // One uniform 0..1 draw per hit, PARALLEL to onsetNotePattern and drawn with
    // it. A hit plays while its draw is below onsetNoteChance.
    //
    // Stored rather than rolled per pass, which is the whole design of this
    // control: the onset part is a stable clip that repeats exactly (see the
    // pattern's own note above), and re-rolling every pass would turn it into a
    // different rhythm every time round. So the dice are thrown ONCE, and the
    // chance slider then only raises or lowers the waterline over them —
    // dragging it is monotonic, and 0.5 -> 0.6 ADDS hits rather than reshuffling
    // the ones already sounding. rerollOnsetNotes throws them again on demand.
    //
    // Parallel to the pattern rather than a third element inside it because the
    // pattern's [time, strength] shape is read by calibrate-measure.scd and
    // asserted element by element in tests/test-onset-notes.scd.
    var onsetNoteRolls;
    var onsetNoteRoutine;
    // [channel, note] while a gate is open, so a routine stopped mid-note can
    // release exactly the note it started. Nothing else would ever clear it.
    var onsetNoteSounding;
    // Who plays the onset notes instead of the MIDI routine, or nil (every Live
    // profile): Megalooper SA's drums, which play them on their own onset kit
    // as timestamped server bundles rather than as MIDI notes sent on time from
    // a routine. Answers startOnsets(looper, pattern, period) and
    // stopOnsets(looper); startOnsetNotes and stopOnsetNotes hand it the part
    // at the same moments they would start or stop the routine, so every
    // restart point here (a respawn, an analysis, the end of a break, undo, the
    // offset and the switch) still drives it.
    var <>onsetNoteSink;
    // The half-time part: [the pattern it was made from, its hits at that
    // speed, its period, the speed], kept so a restart onto the same grid is one.
    var halfOnsets;

    *new { |looper| ^super.newCopyArgs(looper) }

    // The part of a take, for undo: the pattern and its dice belong to the
    // audio they were analysed from. The chance is not here: it is a live
    // control, like the velocity range, not a property of the take.
    takeState { ^(onsetNotePattern: onsetNotePattern, onsetNotePatternDur: onsetNotePatternDur, onsetNoteRolls: onsetNoteRolls) }
    restoreTake { |st|
        onsetNotePattern = st[\onsetNotePattern];
        onsetNotePatternDur = st[\onsetNotePatternDur];
        onsetNoteRolls = st[\onsetNoteRolls];
    }

    // The onsets MeterAnalyzer fits its grid to are also, straightforwardly, a
    // drum part: they are exactly where the attacks were. Replaying them out of
    // midiOut every loop pass lets Live trigger a drum rack or sampler from what
    // was actually played, in phase with the audio and the MIDI clock it is
    // already following.
    //
    // Deliberately a STORED pattern rather than a live trigger off the detector.
    // A live trigger stops the moment you stop playing and carries the detector's
    // ~15-25 ms latency; the loop's pattern repeats forever, dead in time, and
    // costs nothing while it runs.

    count { ^onsetNotePattern !? { |p| p.size } ? 0 }

    clearPattern {
        onsetNotePattern = nil;
        onsetNotePatternDur = nil;
        onsetNoteRolls = nil;
        this.stop;
        looper.changed(\onsetNotePattern, 0);
    }

    // Build the replay pattern from [time, strength] pairs measured from the
    // LOOP's start. Strength is normalised against the loudest hit in the take
    // rather than kept absolute: an absolute mapping would need recalibrating
    // every time the interface gain moved, and the musical information here is
    // which hits were loud RELATIVE to the others.
    buildPattern { |pairs, patternDur|
        var kept, peak;
        onsetNotePattern = nil;
        onsetNotePatternDur = nil;
        onsetNoteRolls = nil;
        if(pairs.isNil or: { patternDur.isNil } or: { patternDur <= 0 }) {
            looper.changed(\onsetNotePattern, 0);
            ^this
        };
        // Onsets past the end are outside the loop: the analysis snaps the take
        // to whole bars and that can cut the tail off what was played.
        kept = pairs.asArray.select { |p| p[0] >= 0 and: { p[0] < patternDur } };
        peak = if(kept.isEmpty) { 0 } { kept.collect { |p| p[1] }.maxItem };
        if(kept.isEmpty or: { peak <= 0 }) {
            looper.changed(\onsetNotePattern, 0);
            ^this
        };
        onsetNotePattern = kept
            .collect { |p| [p[0], (p[1] / peak).clip(0, 1)] }
            .sort { |a, b| a[0] < b[0] };
        onsetNotePatternDur = patternDur;
        // A new take is a new roll: the draws belong to this pattern and mean
        // nothing against the previous one, which had a different length.
        onsetNoteRolls = Array.fill(onsetNotePattern.size) { 1.0.rand };
        looper.changed(\onsetNotePattern, onsetNotePattern.size);
    }

    // Does hit `i` sound at the current chance? One place, because the replay
    // routine and the readout must never disagree about which hits play.
    //
    // A missing draw reads as 0, so it sounds at any chance above 0: the pattern
    // was assembled from outside (the headless fixtures do exactly that) and
    // silence would be the wrong guess. The comparison is strictly `<`, which is
    // what makes the two ends exact — a draw is in [0, 1), so chance 1 sends
    // every hit and chance 0 sends none.
    plays { |i|
        ^(((onsetNoteRolls !? { |r| r.at(i) }) ? 0) < onsetNoteChance)
    }

    // How many of the pattern's hits the current chance actually sends. The
    // panel shows this beside the total: "12 hits" over a part playing four of
    // them is the one claim a thinned pattern must not still make.
    playingCount {
        var n = 0;
        onsetNotePattern !? { |p|
            p.size.do { |i| if(this.plays(i)) { n = n + 1 } };
        };
        ^n
    }

    // Throw the dice again: the same hits at the same chance, a different subset
    // of them. Deliberately a button rather than something that happens every
    // pass — see onsetNoteRolls for why.
    reroll {
        onsetNotePattern !? { |p|
            onsetNoteRolls = Array.fill(p.size) { 1.0.rand };
        };
        looper.changed(\onsetNoteChance, onsetNoteChance);
    }

    // Strength ratio (0..1 against the take's loudest hit) -> MIDI velocity.
    // Evaluated per note at SEND time, which is why the velocity controls take
    // effect live without rebuilding the pattern or restarting the routine.
    velocity { |ratio|
        var db   = ratio.max(1e-5).ampdb;                       // <= 0
        var norm = ((db + onsetNoteDynRange) / onsetNoteDynRange).clip(0, 1);
        ^(onsetNoteVelLo + ((onsetNoteVelHi - onsetNoteVelLo) * norm))
            .round.asInteger.clip(1, 127)
    }


    start {
        var pattern = onsetNotePattern;
        var period  = onsetNotePatternDur;
        var speed = looper.speed, midiOut = looper.midiOut;
        var ok;
        // At half-time the part is the loop's at its speed: every hit and the
        // pass twice as long, counted from where the pass began (passStart).
        // Kept, so a restart onto the same grid (a break's end) is one.
        if((speed != 1) and: { pattern.notNil } and: { period.notNil }) {
            if(halfOnsets.isNil or: { halfOnsets[0] !== onsetNotePattern } or: { halfOnsets[3] != speed }) {
                halfOnsets = [onsetNotePattern, onsetNotePattern.collect { |h| h.copy.put(0, h[0] / speed) },
                    period / speed, speed];
            };
            pattern = halfOnsets[1];
            period = halfOnsets[2];
        };
        // `looper.enginePlaying.not` is the honest test for "the loop's audio is
        // playing": stopPlayback and clear both nil it, and it is already set by
        // the time spawnEngine calls this. Gating on it is what stops the toggle
        // from firing a drum part into Live over a stopped looper — and it lets
        // this stay a single call from spawnEngine rather than one after every
        // prSetState(\playing) in the file.
        ok = (looper.enginePlaying.not or: { onsetNotes.not }
            or: { pattern.isNil } or: { pattern.isEmpty }
            or: { period.isNil } or: { period <= 0 }).not;
        // A sink takes the part over before the stop below: stopOnsetNotes
        // would tell it to stop, and every restart point would then cut and
        // re-send what it had already scheduled. It is handed the same guard,
        // minus a MIDI port it does not need, and keeps its own part where
        // nothing changed. A routine started before the sink was attached is
        // stopped, so the part never plays twice.
        if(onsetNoteSink.notNil) {
            this.stopMidi;
            ^if(ok) { onsetNoteSink.startOnsets(looper, pattern, period) }
                { onsetNoteSink.stopOnsets(looper) }
        };
        this.stop;
        if(ok.not or: { midiOut.isNil }) { ^this };
        onsetNoteRoutine = Routine {
            // Phase-align to the AUDIO. This is started more than once per take —
            // by spawnEngine before the analysis exists, then again by
            // startTempoClocks once it does — so it has to pick up MID-PASS from
            // wherever the loop currently is. Idling until the next boundary
            // instead would send the first pass after every recording out silent.
            // Subtracting the trim moves the pattern's read point FORWARD, so a
            // negative offset makes every hit fire that much earlier.
            var cursor = (SystemClock.seconds
                - (looper.passStart ? SystemClock.seconds)
                - (onsetNoteOffsetMs / 1000)).mod(period);
            var from = pattern.detectIndex { |p| p[0] >= cursor } ? pattern.size;
            inf.do {
                pattern.size.do { |i|
                    // `from` skips the hits this pass has already gone past. A
                    // (from..size-1) range would count DOWNWARDS when from ==
                    // size, replaying the pass backwards.
                    if(i >= from) {
                        var hit  = pattern[i];
                        var next = if(i + 1 < pattern.size) { pattern[i + 1][0] } { period };
                        // Never let a gate run into the next hit: two noteOns
                        // before the noteOff and Live holds the first one.
                        // Measured against the next hit in the PATTERN, not the
                        // next one that sounds, so muting a neighbour never
                        // changes how long a note is held.
                        var gate = (onsetNoteGateMs / 1000).min((next - hit[0]) * 0.5);
                        // Latched, so changing note or channel mid-gate cannot
                        // release a different note than the one that was struck.
                        var chan = onsetNoteChannel, note = onsetNote;
                        // prOnsetPlays reads the draw and the chance LIVE rather
                        // than off the snapshot above, so moving the slider or
                        // re-rolling lands on the next hit without restarting the
                        // routine and losing its phase against the audio.
                        //
                        // A skipped hit costs nothing and leaves `cursor` where
                        // it was: the next one that sounds still waits out its
                        // own distance from the last note actually sent.
                        if(this.plays(i)) {
                            (hit[0] - cursor).max(0).wait;
                            onsetNoteSounding = [chan, note];
                            midiOut.noteOn(chan, note, this.velocity(hit[1]));
                            gate.wait;
                            midiOut.noteOff(chan, note, 0);
                            onsetNoteSounding = nil;
                            cursor = hit[0] + gate;
                        };
                    };
                };
                (period - cursor).max(0).wait;
                cursor = 0;
                from = 0;
            };
        }.play(SystemClock);
    }

    stop {
        // Every stop point here (the break, stopPlayback, clearing the
        // pattern, the switch, free) stops a sink's part too.
        onsetNoteSink !? { |k| k.stopOnsets(looper) };
        this.stopMidi;
    }

    // The MIDI routine's half of a stop.
    stopMidi {
        onsetNoteRoutine !? { |r| r.stop };
        onsetNoteRoutine = nil;
        // Stopping between noteOn and noteOff leaves the note stuck on in Live,
        // and nothing else will ever come along to clear it.
        onsetNoteSounding !? { |pair|
            looper.midiOut !? { |m| m.noteOff(pair[0], pair[1], 0) };
        };
        onsetNoteSounding = nil;
    }

    // ---- Settable controls -------------------------------------------------
    onsetNotes_ { |flag|
        onsetNotes = flag;
        if(flag) { this.start } { this.stop };
        looper.changed(\onsetNotes, onsetNotes);
    }

    // Note and channel are read per hit inside the routine, so these need no
    // restart — but they still notify, or a view that did not originate the
    // change never learns about it.
    onsetNote_ { |val|
        onsetNote = val.asInteger.clip(0, 127);
        looper.changed(\onsetNote, onsetNote);
    }

    onsetNoteChannel_ { |val|
        onsetNoteChannel = val.asInteger.clip(0, 15);
        looper.changed(\onsetNoteChannel, onsetNoteChannel);
    }

    onsetNoteVelLo_ { |val|
        onsetNoteVelLo = val.asInteger.clip(1, 127);
        looper.changed(\onsetNoteVelLo, onsetNoteVelLo);
    }

    onsetNoteVelHi_ { |val|
        onsetNoteVelHi = val.asInteger.clip(1, 127);
        looper.changed(\onsetNoteVelHi, onsetNoteVelHi);
    }

    onsetNoteDynRange_ { |val|
        onsetNoteDynRange = val.clip(1, 90);
        looper.changed(\onsetNoteDynRange, onsetNoteDynRange);
    }

    onsetNoteGateMs_ { |val|
        onsetNoteGateMs = val.clip(1, 1000);
        looper.changed(\onsetNoteGateMs, onsetNoteGateMs);
    }

    // Read live per hit inside the replay routine, like note and channel, so
    // this needs no restart: the part thins or fills from the next hit on.
    onsetNoteChance_ { |val|
        onsetNoteChance = val.clip(0, 1);
        looper.changed(\onsetNoteChance, onsetNoteChance);
    }

    // Read once when the routine is built, so it takes a restart — and a restart
    // re-aligns from loopStartTime, which means the new offset lands on the very
    // next hit instead of at the next loop boundary. Dial it while playing.
    onsetNoteOffsetMs_ { |val|
        onsetNoteOffsetMs = val.clip(-500, 500);
        this.start;
        looper.changed(\onsetNoteOffsetMs, onsetNoteOffsetMs);
    }
}
