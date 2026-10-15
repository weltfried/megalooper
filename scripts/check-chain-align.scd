// megalooper — is a CHAINED loop aligned with the loop it was recorded over?
//
// Evaluate in the RUNNING session IMMEDIATELY AFTER a chain swap ("Rec next
// loop" / key N), before overdubbing:
//
//     ~chainAlign.();
//
// A chained loop is n whole copies of the loop underneath it, so there are two
// separate things that can be wrong, and they sound different:
//
//   * every copy rotated by the SAME amount -> the recording window is offset.
//     Fixed with ~looper.chainRecOffsetMs; the tool prints the number.
//   * copies rotated by DIFFERENT amounts, or a loop region that is not an exact
//     multiple of the old loop -> the copies are not evenly spaced, and the loop
//     jumps once per pass. No single offset can fix that.
//
// So it measures EACH copy, not just the first. The measurement is on envelopes
// (transient alignment is an envelope property, and it keeps this cheap), and it
// is entirely inside SC — buffer against buffer — so it is independent of Live,
// of the note offset, and of everything downstream.
//
// It reports the number to put into `~looper.chainRecOffsetMs` — the tool's sign
// and that setter's are deliberately the same, so it can be typed straight in.
(
~chainAlignEnv = { |raw, hop, step|
    var n = (raw.size / 2 / hop).asInteger;
    Array.fill(n, { |k|
        var peak = 0, base = k * hop * 2;
        (0, step .. hop - 1).do { |j|
            var i = base + (j * 2);
            var m = ((raw[i] ? 0) + (raw[i + 1] ? 0)).abs;
            if(m > peak) { peak = m };
        };
        peak
    })
};

~chainAlignNorm = { |a|
    var mean = a.sum / a.size.max(1);
    var c = a.collect { |x| x - mean };
    var mag = (c.collect { |x| x * x }.sum).sqrt;
    if(mag > 0) { c.collect { |x| x / mag } } { c }
};

// Verified against known shifts: a positive lag means b's content arrives LATER.
~chainAlignCorr = { |a, b, maxLag|
    var best = 0, bestScore = -2;
    (maxLag.neg .. maxLag).do { |d|
        var sum = 0;
        a.size.do { |i|
            var j = i - d;
            if(j >= 0 and: { j < a.size }) { sum = sum + (b[i] * a[j]) };
        };
        if(sum > bestScore) { bestScore = sum; best = d };
    };
    [best, bestScore]
};

~chainAlign = { |maxShiftMs = 300, hopMs = 2, maxSecs = 4|
    var l = ~looper;
    if(l.isNil) {
        "~chainAlign: no ~looper.".warn;
    } {
        var newBuf    = l.instVarAt(\buffer);
        var oldBuf    = l.instVarAt(\nextBuffer);
        var undo      = l.instVarAt(\undoState);
        var curFrames = l.instVarAt(\loopFrames);
        var sr        = l.server.sampleRate;
        var oldFrames = undo !? { |u| u[\loopFrames] };

        case
        { newBuf.isNil or: { oldBuf.isNil } } {
            "~chainAlign: buffers not allocated yet.".warn }
        { oldFrames.isNil or: { oldFrames == 0 } } {
            "~chainAlign: no undo snapshot — chain a loop first.".warn }
        { sr.isNil or: { sr == 0 } } { "~chainAlign: server is not running.".warn }
        { true } {
            Routine {
                // loadToFloatArray takes FRAME counts and hands back interleaved
                // samples, which is why every index below steps by 2. Called from
                // inside a Routine it runs inline, so these reads are sequential.
                var want   = oldFrames.min((maxSecs * sr).asInteger);
                var hop    = (hopMs / 1000 * sr).asInteger.max(1);
                var step   = (hop / 12).asInteger.max(1);
                var exact  = curFrames / oldFrames;
                var copies = exact.round.asInteger.max(1);
                var maxLag = (maxShiftMs / hopMs).asInteger.max(1);
                var oldEnv, results;

                if(oldFrames == curFrames) {
                    ("~chainAlign: the undo snapshot is the same length as the current "
                        "loop, so it probably is NOT from a chain swap. Run this right "
                        "after chaining, before overdubbing — an overdub takes its own "
                        "snapshot and overwrites it.").warn;
                };
                ("~chainAlign: " ++ copies ++ " copy/copies of "
                    ++ (oldFrames / sr).round(0.01) ++ " s, comparing "
                    ++ (want / sr).round(0.01) ++ " s of each…").postln;

                oldBuf.loadToFloatArray(0, want, { |raw|
                    oldEnv = ~chainAlignNorm.(~chainAlignEnv.(raw, hop, step));
                });
                maxLag = maxLag.min(oldEnv.size - 2).max(1);

                results = Array.fill(copies, { |k|
                    var e, r;
                    newBuf.loadToFloatArray(k * oldFrames, want, { |raw|
                        e = ~chainAlignNorm.(~chainAlignEnv.(raw, hop, step));
                    });
                    r = ~chainAlignCorr.(oldEnv, e, maxLag);
                    [r[0] * hopMs, r[1]]
                });

                {
                    var offs    = results.collect { |r| r[0] };
                    var corrs   = results.collect { |r| r[1] };
                    var spread  = offs.maxItem - offs.minItem;
                    var weakest = corrs.minItem;
                    var first   = offs[0];
                    "".postln;
                    "=== chained-loop alignment ===".postln;
                    ("  resolution : " ++ hopMs ++ " ms   searched +/-"
                        ++ (maxLag * hopMs) ++ " ms").postln;
                    ("  loop region: " ++ (curFrames / sr).round(0.001) ++ " s = "
                        ++ exact.round(0.0001) ++ " x the old loop"
                        ++ if((exact - exact.round).abs > 0.0005) {
                            "   <- NOT a whole multiple" } { "" }).postln;
                    "".postln;
                    results.do { |r, k|
                        ("  copy " ++ (k + 1).asString.padLeft(2) ++ " of " ++ copies
                            ++ " : offset " ++ r[0].asString.padLeft(5) ++ " ms"
                            ++ "   correlation " ++ r[1].round(0.001)).postln;
                    };
                    "".postln;
                    case
                    { weakest < 0.3 } {
                        ("  Correlation is too low on at least one copy to trust this. "
                            "Chain a loop where the old material is clearly audible "
                            "and try again.").postln }
                    { spread > (hopMs * 2) } {
                        // The case a single offset cannot fix.
                        ("  THE COPIES ARE NOT EVENLY SPACED — they differ by up to "
                            ++ spread ++ " ms.").postln;
                        ("  That is why the loop jumps once per pass and then holds: "
                            "each copy sits").postln;
                        ("  in a different place than the last. chainRecOffsetMs "
                            "shifts them ALL").postln;
                        ("  together, so no value of it can fix this — the rep spacing "
                            "itself is").postln;
                        ("  wrong. Send this table on rather than dialling anything.").postln }
                    { first.abs <= hopMs } {
                        "  Every copy is ALIGNED and evenly spaced.".postln;
                        ("  The chain recorder is doing its job — if the loop still "
                            "drifts against").postln;
                        ("  Live, the cause is downstream of the buffer.").postln }
                    { true } {
                        ("  Every copy is rotated by the same " ++ first
                            ++ " ms, so one offset fixes them all.").postln;
                        "  Try it now:".postln;
                        // Measured value is the RESIDUAL, so the new setting is the
                        // current one plus it; telling you the residual alone would
                        // undo the correction already in place.
                        ("      ~looper.chainRecOffsetMs = "
                            ++ (l.chainRecOffsetMs + first) ++ ";").postln;
                        "  then chain again and re-run this to confirm it reads ~0.".postln;
                        ("  Once it holds, write  chainRecOffsetMs: "
                            ++ (l.chainRecOffsetMs + first) ++ "  into this rig's").postln;
                        "  profile in scripts/setup-routing.scd so it survives a reboot.".postln };
                    "".postln;
                    // Named explicitly, because it decides what the numbers above
                    // MEAN: taken with the correction at 0 they are the raw error,
                    // taken with one in place they are what is left of it.
                    ("  Chain offset in effect for this take: " ++ l.chainRecOffsetMs
                        ++ " ms" ++ if(l.chainRecOffsetMs == 0) {
                            "   <- UNCORRECTED, so the offsets above are the raw error"
                        } { "   (so the offsets above are what is LEFT of it)" }).postln;
                    ("  For reference: Overdub lat " ++ l.latencyMs
                        ++ " ms, onset-note Offset " ++ l.onsetNoteOffsetMs
                        ++ " ms.").postln;
                    "".postln;
                }.defer;
            }.play(AppClock);
        };
    };
};
"~chainAlign.() ready — chain a loop, then run it.".postln;
)
