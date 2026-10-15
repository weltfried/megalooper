// megalooper — does `loopStartTime` agree with where the loop's audio actually is?
//
// Evaluate in the RUNNING session while a loop is PLAYING (no chaining needed):
//
//     ~loopPhaseCheck.();
//
// Why this matters. `loopStartTime` is the wall-clock reference EVERYTHING
// phase-aligned uses: the onset notes, BBCut's clock, the MIDI-clock Start, and
// the loop boundary the chain recorder waits for. `spawnEngine` now sets it to
// plain `SystemClock.seconds`, because `Synth.new` sends its s_new immediately
// and applies no latency of its own.
//
// It used to add `server.latency` on top of that, which put the reference ~185 ms
// in the FUTURE relative to the audio it described; everything aligned to it
// inherited the error and absorbed it into its own calibration. Fixed 2026-09-07.
// This script is what proved it and is what would catch a regression.
//
// The engine already publishes its true read position on `phaseBus`, in seconds.
// So this asks the server where the loop actually is, asks `loopStartTime` where
// it thinks the loop is, and prints the difference. No ears involved.
(
~loopPhaseCheck = { |samples = 8, gapSecs = 0.15|
    var l = ~looper;
    if(l.isNil) {
        "~loopPhaseCheck: no ~looper.".warn;
    } {
        var bus        = l.instVarAt(\phaseBus);
        var loopFrames = l.instVarAt(\loopFrames);
        var sr         = l.server.sampleRate;

        case
        { bus.isNil } { "~loopPhaseCheck: no phase bus — boot first.".warn }
        { sr.isNil or: { sr == 0 } } { "~loopPhaseCheck: server is not running.".warn }
        { loopFrames.isNil or: { loopFrames == 0 } } {
            "~loopPhaseCheck: no loop recorded.".warn }
        { l.state != \playing and: { l.state != \overdubbing } } {
            ("~loopPhaseCheck: the loop is not playing (state "
                ++ l.state ++ ") — phaseBus only moves while it is.").warn }
        { true } {
            Routine {
                var ld    = loopFrames / sr;
                var diffs = List.new;
                ("~loopPhaseCheck: sampling " ++ samples ++ " times over "
                    ++ (samples * gapSecs).round(0.1) ++ " s…").postln;
                samples.do {
                    var actual, at, got = false, waited = 0, predicted, diff;
                    // The timestamp is taken INSIDE the callback, at the moment
                    // the reply lands — the /c_get round trip adds a few ms, which
                    // is nothing against the 200 ms this is looking for.
                    bus.get({ |v| actual = v; at = SystemClock.seconds; got = true });
                    // Polled rather than a Condition: a responder that answers
                    // synchronously would unhang before we could hang, and
                    // deadlock the routine.
                    while { got.not and: { waited < 0.2 } } {
                        0.005.wait; waited = waited + 0.005;
                    };
                    if(got) {
                        predicted = (at - (l.instVarAt(\loopStartTime) ? at)).mod(ld);
                        // Wrapped to +/- half a loop, so a difference either side
                        // of the boundary reads as a small signed number, not ~ld.
                        diff = (actual - predicted + (ld / 2)).mod(ld) - (ld / 2);
                        diffs.add(diff);
                    };
                    gapSecs.wait;
                };
                {
                    // MEDIAN, not mean. The noise here is one-sided: a late
                    // /c_get reply timestamps the sample later than it was taken,
                    // which only ever biases a reading DOWNWARD. One such reply in
                    // eight drags a mean by tens of ms while leaving the median
                    // untouched — and the whole point is a number you can compare
                    // against s.latency.
                    var sorted = diffs.asArray.sort;
                    var mean   = if(diffs.isEmpty) { 0 } { sorted[sorted.size div: 2] };
                    var spread = if(diffs.isEmpty) { 0 } { sorted.last - sorted.first };
                    var avg    = if(diffs.isEmpty) { 0 } { diffs.sum / diffs.size };
                    "".postln;
                    "=== loop phase vs loopStartTime ===".postln;
                    ("  loop length      : " ++ ld.round(0.001) ++ " s").postln;
                    ("  s.latency        : " ++ l.server.latency
                        ++ "   (NOT added to loopStartTime — a positive median "
                        ++ "near this value means the bug is back)").postln;
                    ("  samples (ms)     : "
                        ++ sorted.collect { |d| (d * 1000).round(0.1) }
                        ++ "   (sorted)").postln;
                    ("  MEDIAN           : " ++ (mean * 1000).round(0.1) ++ " ms"
                        ++ "   <- use this one").postln;
                    ("  mean / max       : " ++ (avg * 1000).round(0.1) ++ " / "
                        ++ (sorted.last * 1000).round(0.1) ++ " ms").postln;
                    ("  spread           : " ++ (spread * 1000).round(0.1)
                        ++ " ms" ++ if(spread > 0.02) {
                            "   (late OSC replies read LOW; the median ignores them)"
                        } { "" }).postln;
                    "".postln;
                    if(diffs.isEmpty) {
                        "  The phase bus never answered — is the server running?".postln;
                    } {
                    if(mean.abs < 0.005) {
                        "  loopStartTime AGREES with the audio.".postln;
                        "  Whatever is drifting is not this reference.".postln;
                    } {
                        // Sign matters and the old wording got it backwards: a
                        // NEGATIVE median means the audio starts AFTER
                        // loopStartTime, not before it.
                        ("  The audio starts " ++ (mean.abs * 1000).round(0.1) ++ " ms "
                            ++ if(mean > 0) { "BEFORE" } { "AFTER" }
                            ++ " loopStartTime.").postln;
                        "".postln;
                        // A small negative residual is EXPECTED and is not a bug:
                        // the s_new has to reach the server, the engine starts on
                        // the next control block, and the /c_get reply comes back
                        // late — all of which read as the audio starting slightly
                        // after the timestamp. Only a large skew is a defect.
                        if(mean < 0 and: { mean > -0.05 }) {
                            ("  That is a normal residual, not a defect: the s_new has "
                                "to reach the").postln;
                            ("  server, the engine starts on the next control block, and "
                                "the /c_get").postln;
                            ("  reply itself comes back a few ms late. Nothing to chase "
                                "below ~30 ms.").postln;
                        } {
                        ("  So every routine aligned to it — onset notes, BBCut, the "
                            "MIDI-clock").postln;
                        ("  Start, and the boundary the chain recorder waits for — is "
                            "out by").postln;
                        "  that much, and each will be absorbing it into its own trim.".postln;
                        // One-sided again: the measurement can only land at or
                        // BELOW s.latency, never above it, so the window is too.
                        // Tolerant on BOTH sides: a one-sided `mean <= latency`
                        // bound drops this line for a reading a hair over, which
                        // is exactly when it is most worth printing.
                        if((mean > 0)
                            and: { ((l.server.latency ? 0) - mean).abs < 0.05 }) {
                            "".postln;
                            ("  That is s.latency (" ++ l.server.latency
                                ++ " s) almost exactly, which is the whole of the "
                                "explanation:").postln;
                            ("  spawnEngine is adding it to loopStartTime while "
                                "Synth.new sends immediately.").postln;
                        };
                        };
                    };
                    };
                    "".postln;
                }.defer;
            }.play(AppClock);
        };
    };
};
"~loopPhaseCheck.() ready — play a loop, then run it.".postln;
)
