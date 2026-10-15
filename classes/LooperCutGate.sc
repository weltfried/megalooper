// A tiny CutSynth spliced into each BBCut voice's chain to drive the "insert"
// duck: it writes a control bus that reports whether the block currently being
// rendered is a repetition (a chunk played more than once — repeats>1, which
// covers both ordinary rolls and stutters). The Looper's engine SynthDef reads
// that bus and mutes the dry loop while it reads 1, so the original signal only
// drops out for the duration of a repeat — Ableton Beat Repeat's "Insert" mode.
//
// It emits no audio of its own; it only schedules a timed /c_set at the start of
// each block, so its position in the chain doesn't matter. `enabledFunc` is
// polled per block so switching mix mode live simply stops/starts the writes
// (the engine ignores the bus outside insert mode anyway).
LooperCutGate : CutSynth {
    var <>busIndex, <>enabledFunc;

    *new { |busIndex, enabledFunc|
        ^super.new.initLooperCutGate(busIndex, enabledFunc)
    }

    initLooperCutGate { |bi, ef|
        busIndex = bi;
        enabledFunc = ef ? { true };
    }

    renderBlock { |block, clock|
        var rolling;
        if(enabledFunc.value.not) { ^this };
        // cuts.size == repeats (see BBCutProc11): >1 means the same chunk is
        // repeated, i.e. a repetition is playing.
        rolling = if(block.cuts.size > 1) { 1 } { 0 };
        // Scheduled at cumul[0] == 0, so the bus flips exactly at block start,
        // sent with server latency like every other BBCut cut message.
        block.addtimedmsgtocut(0, 0.0, 0.0, [\c_set, busIndex, rolling]);
    }
}
