// The transport on Megalooper SA (docs/dev/megalooper-sa.md, Phase 4): the
// drums. In Live the Looper sent Live a MIDI clock, a Start aimed at a loop
// boundary and a Stop, and Live's drums followed; here the Start is the
// drums' bar 1 on that boundary, the Stop theirs, and they take the tempo
// from the loop, so no clock runs. MegaSADrums.attach makes it the Looper's
// transport (Looper.transport): a sibling of LiveMidiTransport (LoopTransport),
// driven by the same transport code (the boundary with a beat of pre-roll,
// the readings' count and their Start where no boundary in reach carries the
// bar line, Stop in \full, transportMode \off for no drums and \startOnly
// for drums that keep running after a stop).
//
// Until 2026-11-09 it posed as the Looper's MIDI port: a MIDIOut's every call,
// a latency that added the Live sync trim back to cancel the Looper's Live
// arithmetic, and a 24-a-quarter clock routine calling a no-op.
//
// The drums must answer:
//
//   alive                          false once the drums are freed: every call
//                                  here is then a no-op (on a reboot the old
//                                  Looper is freed after the new MegaSA and
//                                  still calls stop on its old transport)
//   lead                           seconds the drums decide ahead of the audio
//   transportStart(now)            a Start: the drums' bar 1 is the loop
//                                  boundary nearest now + latency
//   transportStop(now)             a Stop
//
// `now` is the calling thread's time, thisThread.seconds. MegaSADrums supplies
// all of these; the tests use an Event.
MegaSATransport : LoopTransport {
    var <drums;
    // The Start on its way: a routine waiting for `lead` before the boundary.
    var startRoutine;
    var <running = false;

    *new { |drums| ^super.new.prInit(drums) }
    prInit { |aDrums| drums = aDrums }

    alive { ^drums.notNil and: { drums.alive == true } }
    routine { ^startRoutine }
    connected { ^drums.notNil }

    // A Start relocates nothing here: mid-recording a later analysis or a
    // reading restarts the drums on the loop all the same.
    startsRelocate { ^false }

    // How early a Start goes: the drums decide `lead` ahead of the audio.
    latency { ^if(this.alive) { drums.lead ? 0 } { 0 } }

    // The drums' bar 1 on the first boundary from origin a beat of pre-roll
    // on (as Live's, so the same boundary), the Start sent `lead` before it.
    start { |bpm, alignDur, origin|
        var now = SystemClock.seconds, latency = this.latency, boundary, startAt;
        if(this.alive.not) { ^this };
        startRoutine !? { |r| r.stop };
        this.prReset(bpm);
        boundary = LoopTransport.startBoundary(now, bpm, alignDur, origin ? now, latency);
        // No meter: a beat on, phase unaligned.
        startAt = if(boundary.notNil) { boundary - latency } { now + (60 / bpm) };
        running = true;
        startRoutine = Routine {
            if(startAt > SystemClock.seconds) { (startAt - SystemClock.seconds).wait };
            startRoutine = nil;
            if(this.alive) { drums.transportStart(thisThread.seconds) };
            boundary !? { |b| this.prStarted(b) };
        }.play(SystemClock);
    }

    startNow { if(this.alive) { drums.transportStart(thisThread.seconds) } }

    stop {
        startRoutine !? { |r| r.stop };
        startRoutine = nil;
        running = false;
        if(this.alive) { drums.transportStop(thisThread.seconds) };
    }

    free { |sendStop = false|
        if(sendStop) { ^this.stop };
        startRoutine !? { |r| r.stop };
        startRoutine = nil;
        running = false;
    }

    forget { startRoutine = nil; running = false }
}
