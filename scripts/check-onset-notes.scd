// megalooper — why are no onset notes reaching Live?
//
// Evaluate this file (or paste the block) in the RUNNING session, after
// recording a loop. It touches nothing: it only reads state and, on request,
// sends test notes.
//
//     ~onsetNoteReport.();   // where does the chain break?
//     ~onsetNoteTest.();     // 8 notes straight out of midiOut, bypassing everything
//
// The chain has five links, and only the first three are in SuperCollider:
//
//   1. onsets detected while recording      -> Looper's `onsets` list
//   2. a pattern built from them            -> onsetNoteCount > 0
//   3. the replay routine running           -> needs the toggle ON and a playing loop
//   4. the notes leaving on the IAC bus     -> ~onsetNoteTest proves this
//   5. LIVE ACCEPTING THEM                  -> see the note at the bottom
//
// Link 5 is the one that looks like a megalooper bug and is not: Live's MIDI
// input ports have SEPARATE toggles for Sync and Track, and a port enabled only
// for Sync passes MIDI Clock perfectly while silently discarding every note.
(
~onsetNoteReport = {
    var l = ~looper;
    var say = { |label, value| ("  " ++ label.padRight(22) ++ value).postln };
    var problems = List.new;

    "".postln;
    "=== onset notes: where does it break? ===".postln;

    if(l.isNil) {
        "  ~looper is nil — nothing is running. Boot first.".postln;
    } {
        var rawOnsets = l.instVarAt(\onsets);
        var engine    = l.instVarAt(\engineSynth);
        var routine   = l.instVarAt(\onsetNoteRoutine);
        var out       = l.midiOut;

        "-- 1. detection --".postln;
        say.("state",          l.state);
        say.("onsets last take", (rawOnsets !? { |o| o.size } ? 0).asString
            ++ "  (cleared at each new recording)");
        say.("onset threshold", l.onsetThreshold);
        say.("analysis input",  "SC channel " ++ l.analysisIn
            ++ if(l.analysisChannel.notNil and: { l.analysisChannel != l.inChannel }) {
                " (clean tap)" } { " (same as recorded input)" });
        if((rawOnsets !? { |o| o.size } ? 0) == 0) {
            problems.add("No onsets were detected on the last take. Open the onset "
                "analysis window, turn the Monitor on and play: if the level bar stays "
                "flat the analysis input is silent (wrong channel), and if it moves "
                "but the lamp never flashes the threshold is too high.");
        };

        "-- 2. pattern --".postln;
        say.("hits in pattern",  l.onsetNoteCount);
        say.("pattern period",   (l.onsetNotePatternDur ? "none").asString ++ " s");
        if(l.onsetNoteCount == 0 and: { (rawOnsets !? { |o| o.size } ? 0) > 0 }) {
            problems.add("Onsets were detected but no pattern was built. That means "
                "the deferred analysis did not finish against this engine — record "
                "the loop again and watch the post window for errors.");
        };

        "-- 3. replay routine --".postln;
        say.("toggle (onsetNotes)", l.onsetNotes);
        say.("engine playing",      engine.notNil);
        say.("routine running",     routine.notNil);
        if(l.onsetNotes.not) {
            problems.add("THE TOGGLE IS OFF. It is opt-in and defaults to off — "
                "click 'Onset notes' at the bottom of the onset analysis window.");
        };
        if(engine.isNil) {
            problems.add("No loop is playing, so nothing is being replayed. The "
                "pattern only runs while the loop's audio does.");
        };

        "-- 4. MIDI out --".postln;
        if(out.isNil) {
            problems.add("~looper.midiOut is nil — no MIDI is leaving SC at all, "
                "including the clock. Re-run ~setupMidiIO.().");
            say.("midiOut", "NIL");
        } {
            say.("note",         l.onsetNote.asString ++ "  (Live shows note 60 as C3)");
            say.("channel",      (l.onsetNoteChannel + 1).asString
                ++ "  (1-16 as Live counts them)");
            say.("velocity",     l.onsetNoteVelLo.asString ++ "-" ++ l.onsetNoteVelHi
                ++ " over " ++ l.onsetNoteDynRange ++ " dB");
            // A diagnostic that throws is no diagnostic, and midiOut is only a
            // real MIDIOut in a properly booted session.
            if(out.isKindOf(MIDIOut)) {
                say.("midiOut uid",     out.uid);
                say.("midiOut latency", out.latency.asString
                    ++ if(out.latency > 0) { "  <- should be 0; notes will lag" } { "" });
                // nil before MIDIClient.init, and nil.do would call the block
                // with nil rather than skipping it.
                MIDIClient.destinations !? { |dests|
                    dests.do { |d|
                        if(d.uid == out.uid) {
                            say.("destination", d.device ++ " / " ++ d.name);
                        };
                    };
                };
            } {
                say.("midiOut", "not a MIDIOut: " ++ out.class);
            };
        };
    };

    "".postln;
    if(problems.isEmpty) {
        "  Everything on the SC side looks right.".postln;
        "  Run ~onsetNoteTest.() and watch Live's MIDI-in indicator (top right).".postln;
        "  If that shows nothing either, the problem is link 5 — see below.".postln;
    } {
        "  PROBLEMS FOUND:".postln;
        problems.do { |p, i| ("  " ++ (i + 1) ++ ". " ++ p).postln };
    };
    "".postln;
    "  Link 5, in LIVE (Preferences -> Link/Tempo/MIDI):".postln;
    "    * The IAC input's TRACK toggle must be ON. Sync and Track are separate:".postln;
    "      a port set up only for Sync passes MIDI Clock and drops every note.".postln;
    "    * A MIDI track needs Input = that IAC bus, the matching channel (or All),".postln;
    "      and Monitor set to In (or the track armed).".postln;
    ("  The break's macro CC (" ++ (~breakMacroCc ? 100) ++ ", channel 16) goes out of the same port, so if").postln;
    "  Live never sees that one either, it is link 5.".postln;
    "".postln;
};

// Straight out of midiOut, bypassing the pattern, the routine and the toggle.
// If Live's MIDI-in indicator does not flicker during this, nothing megalooper
// does to its notes can matter — the problem is the port or the track.
~onsetNoteTest = { |reps = 8|
    var l = ~looper;
    if(l.isNil or: { l.midiOut.isNil }) {
        "~onsetNoteTest: no ~looper.midiOut to send on.".warn;
    } {
        Routine {
            var chan = l.onsetNoteChannel, note = l.onsetNote;
            ("Sending " ++ reps ++ " notes: note " ++ note ++ " on channel "
                ++ (chan + 1) ++ ". Watch Live's MIDI-in indicator.").postln;
            reps.do { |i|
                l.midiOut.noteOn(chan, note, 100);
                0.12.wait;
                l.midiOut.noteOff(chan, note, 0);
                0.13.wait;
            };
            "Done. Nothing in Live = the port or the track, not megalooper.".postln;
        }.play(SystemClock);
    };
};

~onsetNoteReport.();
)
