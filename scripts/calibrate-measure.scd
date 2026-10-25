// The calibration wizard's measuring half — the part that makes sound.
//
// LooperCalibrator holds the steps and the arithmetic and is covered by
// scripts/tests/test-calibrator.scd. Everything here needs a booted server, a
// real interface and (for three of the four) Ableton Live, so NONE of it is
// covered by the headless suite. This file is the thing to run on the rig.
//
// Load it and wire it into a calibrator:
//
//     ~calRegisterAll.(~calibrator);
//
// or drive one measurement straight from the IDE, which is the quickest way to
// find out whether a step is routed right:
//
//     ~calMeasureLatency.(~looper, { |r| r.postln });
//
// ---- the one thing that would make every number quietly wrong ---------------
//
// The burst is emitted into the looper's OWN output bus, not to the hardware
// channel. It therefore passes through `looperMaster` exactly as the loop does,
// and `Limiter.ar(sig, 0.95, 0.01)` in there delays what leaves by its 10 ms
// lookahead. A burst written straight to `outChannel` would skip that and read
// 10 ms short — a number that looks measured, is wrong by more than the ear can
// be, and stays wrong until somebody re-derives this. Routing through the bus
// also means the measurement follows the limiter if its settings ever change.

// ---------------------------------------------------------------- defs ------

~calDefsAdded = false;

~calAddDefs = {
    if(~calDefsAdded.not) {
        // A burst, and the input recorded from the instant it leaves. The burst's
        // position IN the recording is the round trip, with no clock arithmetic
        // and nothing to go out of step: one synth starts both.
        SynthDef(\looperCalBurst, { |out = 0, in = 0, bufnum = 0,
                                    amp = 0.2, freq = 1000|
            var env   = EnvGen.ar(Env.perc(0.0005, 0.02), Impulse.kr(0));
            var burst = SinOsc.ar(freq) * env * amp;
            RecordBuf.ar(SoundIn.ar([in, in + 1]), bufnum, loop: 0, doneAction: 2);
            Out.ar(out, burst.dup);
        }).add;

        // An input, recorded as it comes in, for its level.
        SynthDef(\looperCalLevel, { |in = 0, bufnum = 0|
            RecordBuf.ar(SoundIn.ar(in), bufnum, loop: 0, doneAction: 2);
        }).add;

        // Live's return, recorded alongside the loop's own read position. Both
        // land in one buffer from one RecordBuf, so they are sample-aligned by
        // construction — which is what lets the sync and note-offset steps avoid
        // reading a wall clock at all.
        //
        // The phase RAMP is recorded, not a trigger at the downbeat. The first
        // version marked the wrap with Trig1 and the language looked for that
        // pulse, which made the whole measurement depend on a loop boundary
        // happening to fall inside the recording window and on a 2 ms pulse
        // surviving envelope bucketing. Recording the ramp needs neither: the
        // very first sample of this channel says where in the loop the recording
        // started, so the first downbeat is (loopDur - that) seconds in, whether
        // or not a wrap is captured at all.
        //
        // phaseBus is a CONTROL bus carrying the read position in seconds
        // (Looper: Out.kr(phaseBus, A2K.kr(loopPhase) / BufSampleRate.kr)).
        SynthDef(\looperCalReturn, { |bufnum = 0, ret = 0, phaseBus = 0|
            var phase  = K2A.ar(In.kr(phaseBus));
            var signal = SoundIn.ar([ret, ret + 1]).sum;
            RecordBuf.ar([signal, phase], bufnum, loop: 0, doneAction: 2);
        }).add;

        ~calDefsAdded = true;
    };
};

// ------------------------------------------------------------- helpers ------

~calHopMs    = 0.5;      // envelope resolution, and therefore the answer's
~calMaxMs    = 200;      // how far out a round trip is still believable
~calTrials   = 8;

// Refuse early and say which precondition failed, rather than returning a
// number measured through a path that was not connected.
~calRequire = { |done, checks|
    var bad = checks.detect { |c| c[0].value.not };
    if(bad.notNil) { done.((ok: false, why: bad[1])); true } { false }
};

~calServerReady = { |looper|
    looper.notNil and: { looper.server.notNil } and: { looper.server.serverRunning }
};

// ----------------------------------------------------- which channel? -------

// Peak level on every input channel, so "which pair is that on?" is answered by
// looking instead of by guessing.
//
// This exists because the sync step cost an evening to the wrong question. SC
// can only hear Live on the loopback pairs, and only what a Live TRACK is
// routed to — Live's Master goes to the speakers and never reaches SC at all —
// so no amount of trying channels finds a metronome. Route something in Live,
// run this, and the channel it lands on is the one with a number beside it.
//
//     ~calScanInputs.();          // 4 s, prints every input channel
~calScanInputs = { |secs = 4|
    var srv = (~looper !? { |l| l.server }) ?? { Server.default };
    if(srv.serverRunning.not) { "~calScanInputs: the server is not running.".warn } {
        Routine {
            var n     = srv.options.numInputBusChannels;
            var peaks = Array.fill(n, 0);
            var name  = ("looperCalScan" ++ n).asSymbol;
            var resp, scan;
            // Channel count is fixed when a graph is built, so the def is named
            // for the count it was built with rather than taking it as an arg.
            SynthDef(name, {
                SendPeakRMS.kr(SoundIn.ar((0..(n - 1))), 10, 3, '/calScan');
            }).add;
            srv.sync;
            resp = OSCFunc({ |msg|
                // [path, nodeID, replyID, peak0, rms0, peak1, rms1, ...]
                n.do { |i|
                    var v = msg[3 + (i * 2)] ? 0;
                    if(v > peaks[i]) { peaks[i] = v };
                };
            }, '/calScan');
            ("~calScanInputs: listening on " ++ n
                ++ " input channels for " ++ secs ++ " s...").postln;
            scan = Synth(name, [], srv, \addToHead);
            secs.wait;
            resp.free;
            // Only the scan's own synth. This used to be srv.freeAll, which
            // freed every node on the server: the Looper's engine and master,
            // and on SA the guitar chain with Bias FX, the drums and the mixer,
            // with nothing to rebuild them, from one button in the middle of
            // a set.
            scan.free;
            "".postln;
            "=== input channels ===".postln;
            ("  (SC index / device channel / peak.  " ++ (~routingProfile ? "—")
                ++ ": in=" ++ (~inChannel ? "—") ++ " return="
                ++ (~returnChannel ? "—") ++ " analysis="
                ++ (~analysisChannel ? "—") ++ ")").postln;
            n.do { |i|
                var db = peaks[i].ampdb;
                if(peaks[i] > 0.0005) {
                    ("  ch " ++ i.asString.padLeft(2) ++ "  (device "
                        ++ (i + 1).asString.padLeft(2) ++ ")  "
                        ++ db.round(0.1).asString.padLeft(7) ++ " dB  "
                        ++ String.fill(((db + 60).max(0) / 2).asInteger, { $# })).postln;
                };
            };
            if(peaks.maxItem <= 0.0005) {
                "  nothing on any input channel at all.".postln;
            };
            "".postln;
        }.play(AppClock);
    };
};

// ------------------------------------------------------- the preflight ------

~calPreflight = { |looper, done|
    var profile = ~routingProfile;
    var live = (~rp !? { |r| r[\live] }) != false;
    Routine {
        var lines = List.new;
        var srv = looper !? { |l| l.server };
        if(~checkAudioDevice.notNil and: { profile.notNil }) {
            lines.add("device: " ++ (~checkAudioDevice.(profile) ? "checked"));
        } {
            lines.add("device: setup-routing.scd is not loaded, nothing to check");
        };
        if(live and: { ~checkLiveAudio.notNil } and: { profile.notNil }) {
            lines.add("live: " ++ (~checkLiveAudio.(profile) ? "checked"));
        };
        lines.add("profile: " ++ (profile ? "—"));
        srv !? { lines.add("server: " ++ (srv.sampleRate ? "?") ++ " Hz, block " ++ (srv.options.hardwareBufferSize ? "the device's")) };
        lines.add("analysis in: " ++ (looper !? { |l| l.analysisIn } ? "—"));
        // SA hosts plugins through VSTPlugin: what its start's check found.
        if((~rp !? { |r| r[\sa] }) == true) {
            lines.add("VSTPlugin: " ++ ((try { ~vstPluginFacts.() } !? { |f|
                if(f[\installed]) { "installed" ++ (f[\version] !? { |v| " (" ++ v.join(".") ++ ")" } ? "") } { "not installed" } }) ? "?"));
        };
        done.((ok: true, value: nil, notes: lines.asArray));
    }.play(AppClock);
};

// --------------------------------------------------- the overdub round trip --

// Emits a burst into the looper's output bus and times its return at
// `inChannel`, `~calTrials` times. See the note at the top about why it goes to
// the bus and not to the hardware channel.
~calMeasureLatency = { |looper, done|
    var l = looper;
    var refused = ~calRequire.(done, [
        [{ ~calServerReady.(l) }, "the server is not running"],
        [{ l.instVarAt(\outBus).notNil },
            "the looper has no output bus yet — boot it first"],
        // The loop leaves on exactly the path being measured, so it arrives
        // back on top of the burst and the correlation can lock onto it
        // instead — which reads as a much longer round trip than the real one.
        [{ l.state != \playing }, "stop the loop first. It travels the same path "
            "as the burst, so it lands on top of it and the measurement can "
            "lock onto the loop rather than onto the burst"]
    ]);
    if(refused.not) {
        // On SA the click comes back through the guitar chain, whose strip
        // would send it out again: a patched cable would be a feedback loop.
        // The strip is held while it measures; the Looper still hears the
        // chain, which is what is timed.
        ~megaSA !? { |m|
            var mine = ~calHoldSerial = (~calHoldSerial ? 0) + 1;
            m.hold(\guitar, \calibrate);
            // A measurement that breaks off must not leave the guitar silent.
            AppClock.sched(30, { if(~calHoldSerial == mine) { m.unhold(\guitar, \calibrate) }; nil });
        };
        Routine {
            var sr      = l.server.sampleRate;
            var hop     = (~calHopMs / 1000 * sr).asInteger.max(1);
            var frames  = ((~calMaxMs + 60) / 1000 * sr).asInteger;
            var maxLag  = (~calMaxMs / ~calHopMs).asInteger;
            var ref     = LooperCalibrator.normalize(
                LooperCalibrator.impulseEnvelope(
                    [0], frames / sr, ~calHopMs / 1000, 0.02));
            var buf     = Buffer.alloc(l.server, frames, 2);
            var trials  = List.new;
            var peak    = 0;
            var res;
            ~calAddDefs.();
            l.server.sync;
            ~calTrials.do { |i|
                var raw, env;
                buf.zero;
                l.server.sync;
                Synth(\looperCalBurst, [
                    \out,    l.instVarAt(\outBus).index,
                    \in,     l.inChannel,
                    \bufnum, buf.bufnum
                ], l.server, \addToHead);
                ((frames / sr) + 0.1).wait;
                buf.loadToFloatArray(0, frames, { |a| raw = a });
                env  = LooperCalibrator.envelope(raw, hop, 4, 2);
                peak = peak.max(env.maxItem);
                trials.add(
                    LooperCalibrator.bestLag(
                        ref, LooperCalibrator.normalize(env), maxLag));
                0.15.wait;
            };
            buf.free;
            ~megaSA !? { |m| m.unhold(\guitar, \calibrate) };
            // Silence and a weak correlation are different faults with different
            // fixes, and correlating noise against noise always produces SOME
            // number. Saying "too weak" when nothing came back at all sends you
            // to the level knob instead of to the routing.
            if(peak <= 0.0005) {
                done.((ok: false, why: if((~rp !? { |r| r[\live] }) != false) {
                    "nothing came back on ch " ++ l.inChannel
                    ++ " at all — the burst never completed the round trip. The "
                    "return leg is the one to check: something in Live has to "
                    "carry the instrument input back out to that pair, or SC never "
                    "hears it. ~calScanInputs.() while you make a noise into "
                    "the instrument input shows whether it arrives."
                } {
                    "nothing came back at all: the click never made the round trip. "
                    "Is the cable from output 1 in the instrument input? On a computer's "
                    "own speakers: is the volume up, and the microphone the input? "
                    "If it cannot be done, set it by ear on the Setup view and press "
                    "Start with this."
                }));
            } {
                res = LooperCalibrator.summarise(trials.asArray, ~calHopMs);
                if(res[\ok] != true) {
                    res = res.copy.put(\why, (res[\why] ? "")
                        ++ " Peak on ch " ++ l.inChannel ++ " was "
                        ++ peak.ampdb.round(0.1) ++ " dB, so something is "
                        "arriving — it just is not the burst.");
                };
                done.(res);
            };
        }.play(AppClock);
    };
};

// ---------------------------------------------------------- the input level --

// Eight seconds of the input meter detection listens to (the analysis input),
// recorded while the player plays hard, and what its peak says
// (LooperCalibrator.levelOf).
~calLevelSecs = 8;
~calMeasureLevel = { |looper, done|
    var l = looper;
    var refused = ~calRequire.(done, [
        [{ ~calServerReady.(l) }, "the server is not running"]
    ]);
    if(refused.not) {
        Routine {
            var sr = l.server.sampleRate, frames = (~calLevelSecs * sr).asInteger;
            var buf = Buffer.alloc(l.server, frames, 1), raw, res, ch = l.analysisIn;
            ~calAddDefs.();
            l.server.sync;
            Synth(\looperCalLevel, [\in, ch, \bufnum, buf.bufnum], l.server, \addToHead);
            (~calLevelSecs + 0.2).wait;
            buf.loadToFloatArray(0, frames, { |a| raw = a });
            l.server.sync;
            buf.free;
            res = LooperCalibrator.levelOf(raw);
            if(res[\verdict] == \silent) {
                res[\why] = res[\why] ++ " (input " ++ (ch + 1) ++ ")";
            };
            done.(res);
        }.play(AppClock);
    };
};

// ------------------------------------------------------ Live's downbeat ------

// Deinterleave one of these recordings into [audio, phase]. Both channels come
// back from one RecordBuf, so they are sample-aligned and no clock is involved.
~calSplit = { |raw| [raw.select { |v, i| i.even }, raw.select { |v, i| i.odd }] };

~calAnchor = { |phase, loopDur|
    LooperCalibrator.anchorFromPhase(phase, loopDur)
};

// What actually landed in the buffer, for when a step refuses and the message
// is not enough. Records `secs` on `ch` exactly as the listening steps do and
// prints both channels' vital signs.
//
//     ~calProbeReturn.(4);        // the channel the sync step is set to
~calProbeReturn = { |ch, secs = 2|
    var l = ~looper;
    if(~calServerReady.(l).not) { "~calProbeReturn: the server is not running.".warn } {
        Routine {
            var sr      = l.server.sampleRate;
            var frames  = (secs * sr).asInteger;
            var hop     = (~calHopMs / 1000 * sr).asInteger.max(1);
            var buf     = Buffer.alloc(l.server, frames, 2);
            var chan    = ch ? l.returnChannel;
            var raw, split, audio, phase;
            ~calAddDefs.();
            l.server.sync;
            Synth(\looperCalReturn, [
                \bufnum,   buf.bufnum,
                \ret,      chan,
                \phaseBus, l.instVarAt(\phaseBus) !? { |b| b.index } ? 0
            ], l.server, \addToHead);
            (secs + 0.2).wait;
            buf.loadToFloatArray(0, frames, { |a| raw = a });
            buf.free;
            split = ~calSplit.(raw);
            audio = LooperCalibrator.envelope(split[0], hop, 4, 1);
            phase = split[1];
            "".postln;
            ("=== return probe, ch " ++ chan ++ " ===").postln;
            ("  samples read   : " ++ raw.size ++ " ("
                ++ (raw.size / 2) ++ " frames of " ++ frames ++ " asked for)").postln;
            ("  audio peak     : " ++ audio.maxItem.ampdb.round(0.1) ++ " dB"
                ++ if(audio.maxItem <= 0.0005) { "   <- SILENT" } { "" }).postln;
            ("  audio crest    : " ++ LooperCalibrator.crest(audio).round(0.1)
                ++ "   (over 40 reads as distinct hits)").postln;
            ("  phase first    : " ++ (phase[0] ? 0).round(0.001) ++ " s").postln;
            ("  phase min/max  : " ++ phase.minItem.round(0.001) ++ " / "
                ++ phase.maxItem.round(0.001) ++ " s"
                ++ if(LooperCalibrator.phaseMoved(phase).not) {
                    "   <- NEVER MOVED" } { "" }).postln;
            ("  loop duration  : " ++ l.loopDuration.round(0.001) ++ " s").postln;
            ("  next downbeat  : "
                ++ LooperCalibrator.anchorFromPhase(phase, l.loopDuration)
                    .round(0.001) ++ " s into the recording").postln;
            "".postln;
        }.play(AppClock);
    };
};

// The guards both listening steps share, in the order the mistakes actually
// happen. Answers nil when everything is fine, or the Event to refuse with.
//
// Ordering is the whole point here. The first version checked for the downbeat
// FIRST, so a recording that captured nothing at all — by far the likeliest
// mistake, since it just means the channel is wrong — was reported as "no loop
// downbeat was captured", which sends you looking at the engine instead of at
// the routing.
~calCheckReturn = { |audio, phase, ch, wantHits = true|
    var crest;
    case
    { audio.maxItem <= 0.0005 } {
        (ok: false, why: "nothing arrived on ch " ++ ch ++ " at all. Check the "
            "routing in Live and press Scan inputs — the channel with a level "
            "on it is the one to put in the box.")
    }
    { (phase.maxItem - phase.minItem) <= 1e-6 } {
        (ok: false, why: "the loop's read position never moved during the "
            "recording, so there is nothing to line the audio up against. Is a "
            "loop actually playing?")
    }
    {
        crest = LooperCalibrator.crest(audio);
        wantHits and: { crest < 40 }
    } {
        (ok: false, why: "ch " ++ ch ++ " is carrying continuous audio (crest "
            ++ crest.round(0.1) ++ "), not distinct hits. That is almost "
            "certainly our own loop coming back — give this step a free "
            "loopback pair of its own, or mute the loop-return track.")
    }
    { true } { nil }
};

// Records the chosen channel next to the loop's own read position, then asks how
// far Live's click sits from our downbeat.
//
// The answer is a CORRECTION, not the new value: it reports where to move
// abletonSyncMs FROM WHERE IT IS, the same way ~chainAlign recommends a
// cumulative number, so running it twice converges instead of undoing itself.
~calMeasureSync = { |looper, done, cal|
    var l = looper;
    var ch = (cal !? { |c| c.listenChannel(\sync) }) ?? { l !? { |lp| lp.returnChannel } };
    var refused = ~calRequire.(done, [
        [{ ~calServerReady.(l) }, "the server is not running"],
        [{ l.state == \playing }, "record a loop first — there is no downbeat "
            "to compare Live's click against"],
        [{ l.loopDuration > 0 }, "the loop has no length"],
        [{ l.instVarAt(\phaseBus).notNil }, "the engine is not publishing its phase"]
    ]);
    if(refused.not) {
        Routine {
            var sr      = l.server.sampleRate;
            var loopDur = l.loopDuration;
            var dur     = (loopDur * 2).min(12);
            var frames  = (dur * sr).asInteger;
            var hop     = (~calHopMs / 1000 * sr).asInteger.max(1);
            var hopSecs = ~calHopMs / 1000;
            var maxLag  = (~calMaxMs / ~calHopMs).asInteger;
            var buf     = Buffer.alloc(l.server, frames, 2);
            var raw, split, audio, phase, bad, anchor, times, ref, res;
            ~calAddDefs.();
            l.server.sync;
            Synth(\looperCalReturn, [
                \bufnum,   buf.bufnum,
                \ret,      ch,
                \phaseBus, l.instVarAt(\phaseBus).index
            ], l.server, \addToHead);
            (dur + 0.2).wait;
            buf.loadToFloatArray(0, frames, { |a| raw = a });
            buf.free;
            split = ~calSplit.(raw);
            audio = LooperCalibrator.envelope(split[0], hop, 4, 1);
            phase = split[1];
            bad   = ~calCheckReturn.(audio, phase, ch, true);
            if(bad.notNil) { done.(bad) } {
                // Every downbeat in the window, from the phase the recording
                // started at. The click should sit on one of them.
                anchor = ~calAnchor.(phase, loopDur);
                times  = (0..4).collect { |i| anchor + (i * loopDur) }
                    .select { |t| t < dur };
                ref    = LooperCalibrator.normalize(
                    LooperCalibrator.impulseEnvelope(times, dur, hopSecs, 0.03));
                res    = LooperCalibrator.summarise([
                    LooperCalibrator.bestLag(
                        ref, LooperCalibrator.normalize(audio), maxLag)
                ], ~calHopMs, 0.2, 1e6);
                if(res[\ok] != true) { done.(res) } {
                    // Live late by L means pulling it earlier by L, added to
                    // wherever the offset already is.
                    done.((ok: true,
                        value: (l.abletonSyncMs - res[\value]),
                        measured: res[\value], quality: res[\quality],
                        notes: ["Live's click sits " ++ res[\value].round(0.1)
                            ++ " ms from the loop's downbeat",
                            "current offset " ++ l.abletonSyncMs
                                ++ " ms -> recommended "
                                ++ (l.abletonSyncMs - res[\value]).round(0.1)
                                ++ " ms"]));
                };
            };
        }.play(AppClock);
    };
};

// ------------------------------------------- the drum hits against the loop --

// The good one. The looper already knows exactly where it sent every onset
// note, so this correlates the recording against a KNOWN pattern rather than
// against a second recording — only one side of it carries any noise.
~calMeasureNoteOffset = { |looper, done, cal|
    var l = looper;
    var ch = (cal !? { |c| c.listenChannel(\noteOffset) }) ?? { l !? { |lp| lp.returnChannel } };
    var refused = ~calRequire.(done, [
        [{ ~calServerReady.(l) }, "the server is not running"],
        [{ l.state == \playing }, "record a loop first"],
        [{ l.onsetNotes }, "turn Onset notes on in the Analysis tab"],
        [{ l.onsetNoteCount > 0 }, "this take has no onset pattern to send"],
        [{ l.instVarAt(\phaseBus).notNil }, "the engine is not publishing its phase"]
    ]);
    if(refused.not) {
        Routine {
            var sr      = l.server.sampleRate;
            var loopDur = l.loopDuration;
            // The pattern keeps its OWN period — the loop it was built for —
            // and tiles across a multiplied loop, so hits repeat every `period`
            // while the phase ramp wraps every `loopDur`.
            var period  = (l.instVarAt(\onsetNotePatternDur) ? loopDur).max(1e-6);
            var dur     = (loopDur * 2).min(12);
            var frames  = (dur * sr).asInteger;
            var hop     = (~calHopMs / 1000 * sr).asInteger.max(1);
            var hopSecs = ~calHopMs / 1000;
            var maxLag  = (~calMaxMs / ~calHopMs).asInteger;
            var buf     = Buffer.alloc(l.server, frames, 2);
            var pattern = l.instVarAt(\onsetNotePattern) ? [];
            var raw, split, audio, phase, bad, anchor, times, ref, res;
            ~calAddDefs.();
            l.server.sync;
            Synth(\looperCalReturn, [
                \bufnum,   buf.bufnum,
                \ret,      ch,
                \phaseBus, l.instVarAt(\phaseBus).index
            ], l.server, \addToHead);
            (dur + 0.2).wait;
            buf.loadToFloatArray(0, frames, { |a| raw = a });
            buf.free;
            split = ~calSplit.(raw);
            audio = LooperCalibrator.envelope(split[0], hop, 4, 1);
            phase = split[1];
            bad   = ~calCheckReturn.(audio, phase, ch, true);
            if(bad.notNil) { done.(bad) } {
                anchor = ~calAnchor.(phase, loopDur);
                // Where every hit SHOULD be: the pattern tiled from the downbeat
                // the phase channel puts at `anchor`.
                times = (-1..4).collect { |pass|
                    pattern.collect { |pr| anchor + (pass * period) + pr[0] }
                }.flat.select { |t| (t >= 0) and: { t < dur } };
                ref = LooperCalibrator.normalize(
                    LooperCalibrator.impulseEnvelope(times, dur, hopSecs, 0.03));
                res = LooperCalibrator.summarise([
                    LooperCalibrator.bestLag(
                        ref, LooperCalibrator.normalize(audio), maxLag)
                ], ~calHopMs, 0.2, 1e6);
                if(res[\ok] != true) { done.(res) } {
                    done.((ok: true,
                        value: (l.onsetNoteOffsetMs - res[\value]),
                        measured: res[\value], quality: res[\quality],
                        notes: ["the drum hits land " ++ res[\value].round(0.1)
                            ++ " ms from where the loop's own onsets are",
                            "current offset " ++ l.onsetNoteOffsetMs
                                ++ " ms -> recommended "
                                ++ (l.onsetNoteOffsetMs - res[\value]).round(0.1)
                                ++ " ms"]));
                };
            };
        }.play(AppClock);
    };
};

// ------------------------------------------------- loop-chain alignment ------

// Delegates to the tool that has been measuring this since before the wizard
// existed. Loaded on demand, because boot.scd does not load the check-* scripts.
~calMeasureChain = { |looper, done|
    var l = looper;
    if(~chainAlign.isNil) {
        (Looper.repoRoot +/+ "scripts" +/+ "check-chain-align.scd").load;
    };
    if(~chainAlign.isNil) {
        done.((ok: false, why: "check-chain-align.scd would not load"));
    } {
        // ~chainAlign posts its findings and returns nothing, so the number is
        // read off the report rather than out of a callback. That is why this
        // step asks for confirmation instead of applying on its own.
        ~chainAlign.value;
        done.((ok: true, value: l.chainRecOffsetMs,
            notes: ["~chainAlign has posted its measurement above.",
                "Set 'Chain rec offset' to the CUMULATIVE number it recommends, "
                "then press Measure again — it should come back near zero."]));
    };
};

// ------------------------------------------------------------ wiring up ------

~calRegisterAll = { |cal|
    cal.register(\preflight,  ~calPreflight);
    cal.register(\level,      ~calMeasureLevel);
    cal.register(\latency,    ~calMeasureLatency);
    cal.register(\sync,       ~calMeasureSync);
    cal.register(\noteOffset, ~calMeasureNoteOffset);
    cal.register(\chain,      ~calMeasureChain);
    cal
};
