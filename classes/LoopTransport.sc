// megalooper — the transport that follows the loop: started on a loop
// boundary once a take's tempo is known, kept at the reading's tempo, started
// again where a reading lands that no boundary in reach can carry, and
// stopped. The Looper drives one (Looper.transport); two kinds answer it, as
// siblings (docs/dev/architecture.md 5, step 10):
//
//   LiveMidiTransport   Live, through a MIDI port: a 24-a-quarter clock
//                       stream and a Start aimed at the boundary, early by
//                       the port's latency, nudged by the Live sync trim
//   MegaSATransport     Megalooper SA's drums: their bar 1 on the boundary
//
// Until 2026-11-09 the Looper ran Live's clock itself and SA's drums posed as
// a MIDI port, adding the Live sync trim to their latency to cancel the
// Looper's Live arithmetic.
//
// Both keep the transport's count the same way, which is what a reading asks
// to find a boundary its bar line meets: clockTicksAtRef ticks (24 a quarter)
// had gone at clockRefTime, clockTickRate a second since; nil until a Start
// goes out on a known boundary. A TIME rather than a loop index, so a chain
// handoff or a multiply that moves loopStartTime cannot stale it.
//
// A transport answers:
//
//   connected                  something to drive (a port; the drums)
//   startsRelocate             whether a Start relocates something worth
//                              protecting: Live's arrangement jumps to 1.1.1,
//                              so mid-recording a later analysis or reading
//                              keeps its Start to itself; SA's drums just
//                              begin their bar on the loop
//   running                    started and not stopped (\startOnly keeps it
//                              running across the loop's stop)
//   start(bpm, alignDur, origin)   start, the bar line on the first loop
//                              boundary from origin a beat of pre-roll on
//   startNow                   a Start now: the bar line on the boundary it
//                              reaches (a reading that restarts it)
//   landTempo(bpm, at, restart, recording)   a reading lands at `at`
//   ticksAt(t)                 the count at t, or nil
//   stop                       stop, and say so (\full)
//   free(sendStop)             stop running, saying so only if asked
//   forget                     Cmd-period stopped its routines already
//   routine                    the routine it runs (Live's clock, SA's Start
//                              on its way), or nil: the offline renders step
//                              it at its logical times
//   syncMs_(ms)                Live's sync trim (the others ignore it)
LoopTransport {
    var <clockTicksAtRef, <clockRefTime, <clockTickRate;
    // A tick's length: the clock reads it every tick, so a reading moves the
    // tempo from the boundary it lands on.
    var <clockPeriod;

    connected { ^true }
    startsRelocate { ^true }
    running { ^this.subclassResponsibility(thisMethod) }
    routine { ^nil }
    syncMs_ { |ms| }

    // The loop boundary a Start puts the bar line on: the first from origin
    // at least a beat of pre-roll past now + latency (ceil, so never a partial
    // pass). nil with no loop length to align to.
    *startBoundary { |now, bpm, alignDur, origin, latency = 0|
        var target, m;
        if(alignDur.isNil or: { alignDur <= 0 }) { ^nil };
        origin = origin ? now;
        target = now + (60 / bpm) + latency;
        m = (((target - origin) / alignDur).ceil).max(0);
        ^origin + (m * alignDur)
    }

    // The count at t: nil until a Start has gone out on a known boundary, or
    // once the transport stopped.
    ticksAt { |t|
        ^if(clockRefTime.notNil and: { this.running }) {
            clockTicksAtRef + ((t - clockRefTime) * clockTickRate)
        }
    }

    // A reading lands at `at` with the tempo bpm: a new period from that
    // tick, and the count's reference moved to it, so the next reading finds
    // the bar line again. When no boundary in reach could carry it
    // (restart), Start goes out again — unless a Start relocates something
    // and a session is being recorded, when it would overwrite the take: the
    // bar line is then left where it falls, the tempo still right.
    landTempo { |bpm, at, restart, recording|
        if(clockRefTime.notNil) {
            clockTicksAtRef = clockTicksAtRef + ((at - clockRefTime) * clockTickRate);
            clockRefTime    = at;
        };
        clockPeriod   = 60 / (bpm * 24);
        clockTickRate = 1 / clockPeriod;
        if(restart == true) {
            if(this.startsRelocate and: { recording == true }) {
                ("Reading landed; the set is being recorded, so no Start — "
                    "the transport's bar line may sit off the loop's.").postln;
            } {
                this.startNow;
                clockTicksAtRef = 0;
                clockRefTime    = at;
            };
        };
    }

    // A new tempo, and no count until a Start goes out on a boundary.
    prReset { |bpm|
        clockPeriod = 60 / (bpm * 24);
        clockTicksAtRef = nil; clockRefTime = nil; clockTickRate = nil;
    }

    // The Start went out for `boundary`: the count begins there.
    prStarted { |boundary|
        clockTicksAtRef = 0;
        clockRefTime    = boundary;
        clockTickRate   = 1 / clockPeriod;
    }

    startNow { ^this.subclassResponsibility(thisMethod) }
}

// Live, through a MIDI port. Live only locks its external tempo once a stream
// of MIDI Clock pulses is flowing, so a Start must NOT go cold: a cold Start
// makes Live begin at its last tempo and catch up over the first bar. So the
// clock streams at once, and the Start goes on the boundary
// (LoopTransport.startBoundary, at least a beat of pre-roll away) so Live's
// 1.1.1 lands where it should. The Looper passes the LOOP period, not a bar:
// any repetition will do, never mid-take, so the wait is up to a loop, and
// the clock keeps Live's tempo locked meanwhile. The Start is aimed early by
// the port's latency (so it is RECEIVED on the boundary) and by the sync trim
// (negative pulls Live earlier, to cancel its ~10-20 ms lag as a follower).
LiveMidiTransport : LoopTransport {
    // { the port } (the Looper's midiOut, which the tests swap for a stub).
    var portFunc;
    var midiClockRoutine;
    // The sync trim in ms, and seconds of it still to fold into the ticks.
    var <syncMs = 0, clockNudge = 0;

    *new { |portFunc| ^super.new.prInit(portFunc) }
    prInit { |aPortFunc| portFunc = aPortFunc }

    port { ^portFunc.value }
    connected { ^this.port.notNil }
    running { ^midiClockRoutine.notNil }
    routine { ^midiClockRoutine }

    // While the clock runs, the CHANGE goes into the stream as a phase nudge,
    // drained over a few ticks, so Live's clock-follower slews to the new
    // offset live, without a jarring re-Start; the next Start takes it whole.
    // A more negative trim shortens the coming ticks, advancing Live.
    syncMs_ { |ms|
        if(midiClockRoutine.notNil) { clockNudge = clockNudge + ((ms - syncMs) / 1000) };
        syncMs = ms;
    }

    start { |bpm, alignDur, origin|
        var syncOff = syncMs / 1000;
        midiClockRoutine !? { |r| r.stop };
        clockNudge = 0;
        this.prReset(bpm);
        midiClockRoutine = Routine {
            var port     = this.port;
            var latency  = (port !? { |p| p.latency }) ? 0;
            var started  = false;
            var boundary = LoopTransport.startBoundary(SystemClock.seconds, bpm, alignDur,
                origin ? SystemClock.seconds, latency);
            // No meter: warm the clock up, then Start, phase unaligned.
            var startAt  = if(boundary.notNil) { (boundary - latency) + syncOff }
                { SystemClock.seconds + (60 / bpm) + syncOff };
            inf.do {
                var nudge;
                if(started.not and: { SystemClock.seconds >= startAt }) {
                    port !? { |p| p.start };
                    started = true;
                    // The count begins at the boundary the Start was aimed at.
                    boundary !? { |b| this.prStarted(b) };
                };
                port !? { |p| p.midiClock };
                // A bounded slice of a pending sync nudge, the rest carried to
                // later ticks, so a large move slews (a blip of at most half a
                // tick) instead of glitching.
                nudge = clockNudge.clip(clockPeriod * -0.5, clockPeriod * 0.5);
                clockNudge = clockNudge - nudge;
                (clockPeriod + nudge).max(0).wait;
            };
        }.play(SystemClock);
    }

    startNow { this.port !? { |m| m.start } }

    // MIDI Clock and Stop travel together: stopping the clock without a Stop
    // makes Live lose sync and turn its external sync off.
    stop {
        midiClockRoutine !? { |r| r.stop };
        midiClockRoutine = nil;
        this.port !? { |m| m.stop };
    }

    free { |sendStop = false|
        midiClockRoutine !? { |r| r.stop };
        midiClockRoutine = nil;
        if(sendStop) { this.port !? { |m| m.stop } };
    }

    forget { midiClockRoutine = nil }
}
