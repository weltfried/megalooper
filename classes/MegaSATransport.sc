// The MIDI port the Looper drives on Megalooper SA (docs/dev/megalooper-sa.md,
// Phase 4). In Live the Looper sent Live a MIDI clock, a Start aimed at a loop
// boundary and a Stop, and its onset notes; Live's drums followed. On SA there
// is no Live: MegaSA.attachLooper sets looper.midiOut to one of these, so the
// Looper's own transport code (boundary alignment with a beat of pre-roll, the
// readings' waits for the bar line, Stop in \full, transportMode \off for no
// drums and \startOnly for drums that keep running after a stop) drives SA's
// drums exactly as it drove Live's. Nothing in Looper.sc had to learn about
// them for it.
//
// It answers everything a MIDIOut does and turns the four calls that matter
// into calls on the drums object, which must answer:
//
//   alive                          false once the drums are freed: every call
//                                  here is then a no-op (on a reboot the old
//                                  Looper is freed after the new MegaSA and
//                                  still calls stop on its old port)
//   lead                           seconds the drums decide ahead of the audio
//   looper                         the Looper attached, or nil
//   transportStart(now)            a MIDI Start: the drums' bar 1 is the loop
//                                  boundary nearest now + latency
//   transportStop(now)             a MIDI Stop
//   onsetNoteOn(note, vel, at)     one onset-kit hit at absolute time `at`
//
// `now` is the calling thread's time, thisThread.seconds. MegaSADrums supplies
// all of these; the tests use an Event.
//
// latency is what the Looper aims the Start early by, and it adds the Live
// sync trim to it, which it adds back after (startMidiClock: startAt =
// boundary - latency + abletonSyncMs). So answering lead + abletonSyncMs /
// 1000 lands every Start `lead` before its boundary whatever the trim, with
// the boundary itself still the Looper's.
//
// noteOn is the Looper's onset-note routine and ~onsetNoteTest: on SA the
// routine never runs (the drums play the onset part themselves, through
// Looper.onsetNoteSink), but a test note sent by hand still sounds, `lead`
// from now. A noteOn at velocity 0 is a note-off, as in MIDI.
MegaSATransport {
    var <drums;

    *new { |drums| ^super.newCopyArgs(drums) }

    alive { ^drums.notNil and: { drums.alive == true } }

    latency {
        var syncMs;
        if(this.alive.not) { ^0 };
        syncMs = (drums.looper !? { |l| l.abletonSyncMs }) ? 0;
        ^(drums.lead ? 0) + (syncMs / 1000)
    }

    start { if(this.alive) { drums.transportStart(thisThread.seconds) } }
    stop { if(this.alive) { drums.transportStop(thisThread.seconds) } }

    noteOn { |chan, note, veloc|
        if(this.alive and: { (veloc ? 0) > 0 }) {
            drums.onsetNoteOn(note, veloc, thisThread.seconds + (drums.lead ? 0));
        };
    }

    // The 24-a-quarter clock is Live's way of following the tempo; the drums
    // take the tempo from the loop. One-shots need no note-offs, and nothing
    // on SA listens for the rest.
    midiClock { }
    noteOff { |chan, note, veloc| }
    control { |chan, ctlNum, val| }
    program { |chan, num| }
    bend { |chan, val| }
    touch { |chan, val| }
    polyTouch { |chan, note, val| }
    allNotesOff { |chan| }
    continue { }
    reset { }
    songPtr { |songPtr| }
    songSelect { |song| }
    smpte { |frames, seconds, minutes, hours, frameRate| }
    sysex { |packet| }
}
