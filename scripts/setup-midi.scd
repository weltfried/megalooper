// megalooper — MIDI I/O: the inputs, the IAC output, and the log.
//
// Loaded by boot.scd; defines only, runs nothing. One entry point:
//   ~setupMidiIO       — MIDIClient, input connections, the IAC output (~midiOut).
//                        Must run BEFORE ~setupLooper: the Looper is constructed
//                        with ~midiOut and sends its MIDI clock through it.
// Which message does what is a MIDI map now (presets/midi/, or yours, made on
// the Rig tab: docs/dev/midi-map.md), and the responders, the proxy to Live and
// the log's use are the router's, in setup-midimap.scd. The numbers that were
// here until 2026-10-08 are the TSMega's map (since 2026-10-25 a test fixture,
// tests/fixtures/midi/tsmega.json, and the duo's own) and keys-and-knobs.json,
// and a copy is kept with the old responders in tests/legacy-midi-bindings.scd.
(
// ---- What megalooper sends Live on its own -----------------------------------
// OUTGOING, not a controller binding: the one CC megalooper sends to Live on
// its own initiative. Live's rack has two Rhythmic Steps devices on a macro,
// and this picks which one plays — 0 while the break is open, 127 when the loop
// comes back. That drum rack is NOT fed by the onset notes and keeps playing
// through a break, which is the point: the room hears a different pattern in
// the hole, and the original one returns with the loop.
//
// Absolute values rather than a toggle, so a macro nudged by hand is corrected
// by the next break instead of inverted for the rest of the set. Sent on
// ~pcCcChannel for the same reason the proxied program changes are: nothing the
// controller forwards can ever collide with it.
//
// MOVED off 20 on 2026-09-22, when the session recorder took program 20. Every
// program change is proxied to Live as CC number = program number on this same
// channel, so a break macro on CC 20 would have been flipped by every stomp of
// the record footswitch. 100 is clear of every program number this rig uses and
// is likely to use. check.scd asserts that no shipped map binds program 100.
// If you have an old Ableton set, this is the one control that needs re-mapping.
~breakMacroCc    = 100;

~midiLog = true;  // set false in the IDE to silence the POST WINDOW only

// One formatter, two sinks. ~midiLog gates only the post window; the status
// window's monitor always receives, which is the point of having it — you can
// silence the post spam and still watch the controller. ~midiMonitorPush is
// defined by gui-status.scd and stays nil when that window was never built, so
// this file has no dependency on the GUI existing.
~midiLogLine = { |line|
    if(~midiLog) { line.postln };
    ~midiMonitorPush !? { |push| push.(line) };
};

// Live's MIDI-map mode can't learn Program Change, so we translate each PC
// into a CC Live CAN map. The CC number = the program number, sent on a
// dedicated channel (16, 0-indexed 15) so it never clashes with the real
// CCs the controller already forwards on its own channel.
~pcCcChannel = 15;

// ---- MIDI I/O ------------------------------------------------------------
~setupMidiIO = {
    MIDIClient.init;
    // Start from a clean slate. Re-running boot.scd in a live interpreter
    // otherwise re-registers every MIDIdef on top of the existing shared
    // dispatchers; churning their internal function-lists across re-runs can
    // corrupt one (seen as "Message 'put' not understood. RECEIVER: 1" thrown
    // from FunctionList during program-change dispatch). Freeing first means
    // each boot rebuilds the responders from scratch.
    MIDIdef.freeAll;
    // Connect every MIDI source EXCEPT our own IAC loopback bus. We send clock,
    // transport, and proxied controller data OUT to IAC; an IAC bus is a
    // loopback, so if we also listened to it every forwarded message would echo
    // straight back into SC's handlers — re-firing the looper bindings and
    // double-triggering record (start → immediate stop → 0 onsets). So we leave
    // the IAC source out of the input connections entirely.
    MIDIClient.sources.do { |src|
        if(src.device.contains("IAC").not) {
            MIDIIn.connect(0, src);
        };
    };

    ~midiOut = nil;
    MIDIClient.destinations.do { |dest|
        if(dest.device.contains("IAC") and: { ~midiOut.isNil }) {
            ~midiOut = MIDIOut.newByName(dest.device, dest.name);
            ~midiOut.latency = 0;
            ("MIDI clock => " ++ dest.device ++ " / " ++ dest.name).postln;
        };
    };
    if(~midiOut.isNil) {
        (if(MegaFiles.isMac) { "No IAC bus found. MIDI clock disabled." } {
            "MIDI clock disabled: megalooper sends it to macOS's IAC bus, which this system has not." }
            ++ " Available destinations:").postln;
        MIDIClient.destinations.do { |dest, i|
            ("  " ++ i ++ ": " ++ dest.device ++ " / " ++ dest.name).postln;
        };
    };
};
)
