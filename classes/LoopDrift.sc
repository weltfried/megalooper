// megalooper — how late the loop's audio runs behind the timeline's grid:
// the drift estimate dHat, moved by probes of the engine's phase.
//
// Every language-side layer counts the loop from loopStartTime, a logical
// SystemClock time; the loop runs on the interface's crystal, the language
// on the host's clock: 20 ppm is 1.2 ms a minute, and a loop can play for
// twenty. dHat is how much later than the grid the loop is heard: a stamp
// adds it (SA's drums: MegaSADrums.prStampDelta), the grid never does. A
// probe reads the engine's phase at a known time; its error against the
// model moves dHat a quarter of the way, at most 2 ms, or all of it once two
// in a row are over 10 ms (the loop moved, it did not drift).
//
// The loop's timeline's (LoopTimeline.drift), the drums' own until
// 2026-11-09 (docs/dev/architecture.md 5, step 10). SA's drums send the
// probes, a one-block synth at the head of their group after the engine, on
// their pump every 2 s, and hand the answers here; what keeps time with the
// loop reads dHat.
LoopDrift {
    var <dHat = 0, <lastProbeError, bigErrors = 0;
    // The probes on their way: id -> (time:, lam:, spawn:, reverse:, speed:).
    var probes, probeSerial = 0;
    // What a probe must not have been sent across: a new engine, a reverse
    // landing, a speed change. The engine's anchor, and when it began.
    var spawnCount = 0, reverseCount = 0, speedCount = 0, lastLam, lastSpawnAt;

    *new { ^super.new.init }
    init { probes = IdentityDictionary.new }

    // ---- Pure arithmetic (every input an argument) -------------------------

    // How far the loop's audio is ahead of the model at probe time (e > 0: the
    // loop is earlier than modelled), within half a 16th. `value` is the
    // engine's phase as the probe read it: A2K holds a block's first sample,
    // and the probe's time is dithered over the block, so on average it is
    // 31.5 samples later than that.
    *probeError { |value, sampleRate, probeTime, lam, dHat, loopDur, s16|
        var phiHat = value + (31.5 / sampleRate);
        var model = ((probeTime - lam) - dHat) % loopDur;
        ^(phiHat - model).wrap(s16.neg / 2, s16 / 2)
    }

    // One probe's correction: [new dHat, consecutive large errors]. A quarter
    // of the error, at most 2 ms; the whole error once two in a row exceed
    // 10 ms (the loop moved, it did not drift).
    *driftStep { |dHat, err, bigCount|
        var big = if(err.abs > 0.010) { bigCount + 1 } { 0 };
        ^if(big >= 2) { [dHat - err, 0] } { [dHat - (0.25 * err).clip(-0.002, 0.002), big] }
    }

    // ---- The estimate ----------------------------------------------------------

    // A probe sent for `time` over the engine anchored at lam: its id.
    sent { |time, lam|
        probeSerial = (probeSerial % 16777215) + 1;
        probes.put(probeSerial, (time: time, lam: lam, spawn: spawnCount, reverse: reverseCount,
            speed: speedCount));
        ^probeSerial
    }

    // A probe's answer: the engine's phase `value` (seconds into the loop),
    // `arrival` the wall time it came. Kept only if the loop's model holds
    // (`valid`), it came within 30 ms of its time, nothing about the loop
    // changed since it was sent, and it is not within 50 ms of the engine's
    // start. lam and loopDur: the loop now; s16At: { |t| a 16th at t }.
    answer { |id, value, arrival, valid, lam, loopDur, sampleRate, s16At|
        var p = probes.removeAt(id), err, step;
        if(p.isNil or: { value.isNil }) { ^this };
        if(valid.not or: { arrival > (p[\time] + 0.03) } or: { p[\lam] != lam }
            or: { p[\spawn] != spawnCount } or: { p[\reverse] != reverseCount } or: { p[\speed] != speedCount }
            or: { (p[\time] - (lastSpawnAt ? inf.neg)) < 0.05 } or: { loopDur <= 0 }) { ^this };
        err = this.class.probeError(value, sampleRate, p[\time], lam, dHat, loopDur, s16At.value(p[\time]));
        lastProbeError = err;
        step = this.class.driftStep(dHat, err, bigErrors);
        dHat = step[0];
        bigErrors = step[1];
    }

    // The engine anchored at lam: a new one (the anchor moved) has its own
    // start lag, so dHat from 0. Answers whether it was new.
    engine { |lam|
        if(lam.notNil and: { lam != lastLam }) {
            lastLam = lam;
            lastSpawnAt = lam;
            spawnCount = spawnCount + 1;
            dHat = 0;
            bigErrors = 0;
            ^true
        };
        ^false
    }

    // Probing begins (the drums attaching) over the engine as it is.
    from { |lam|
        lastLam = lam;
        lastSpawnAt = lam;
    }

    // Probes sent before `before` that never came back, forgotten.
    prune { |before|
        if(probes.notEmpty) {
            probes.keys.select { |id| probes[id][\time] < before }.do { |id| probes.removeAt(id) };
        };
    }

    // A reverse landed, or the speed changed: a probe sent across it is
    // thrown away.
    reversed { reverseCount = reverseCount + 1 }
    speedChanged { speedCount = speedCount + 1 }
}
