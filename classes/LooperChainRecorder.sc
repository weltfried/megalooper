// megalooper — loop chaining, the capture: record a new loop (the guitar and
// the processed loop's return, on inChannel) over the one playing, a whole
// number of its passes long so tempo and signature carry over, starting and
// ending on its boundaries, then hand it to the Looper on a boundary, which
// swaps it in as the active loop (Looper.prSwapInNextLoop). One button
// (Rec next loop) drives it through Looper.recordNextLoop:
//   idle -> armed (the capture starts at the next boundary) -> recording ->
//   stopping (a press: it ends at the boundary closing this pass) -> the
//   swap -> idle; a press while armed cancels.
//
// A part of the Looper (docs/dev/architecture.md 5, step 8; the Looper's own
// until 2026-11-08): it holds the Looper, asks it for the loop it records
// over (server, loopFrames, loopStartTime, the input and return channels)
// and says its changes as the Looper's (looper.changed: \nextRecState,
// \chainRecOffsetMs). It keeps the second buffer: the capture's scratch,
// which the swap gives to the Looper as its loop while the Looper's old loop
// becomes the scratch for the next capture. The Looper's recordNextLoop,
// armNextLoopRecord, cancelNextLoopRecord, nextRecState and chainRecOffsetMs
// are its facade.
LooperChainRecorder {
    var looper;
    // The scratch buffer, and the recorder writing into it, and the routine
    // waiting for its boundaries.
    var nextBuffer, nextRecSynth, nextRecRoutine;
    // Where the chain recorder starts, relative to the loop boundary, in ms.
    // NEGATIVE starts it earlier. Default 0 = the old behaviour exactly.
    //
    // It exists because the chained loop can land rotated inside its own buffer,
    // and nothing here can derive by how much: the recorder finds its boundary
    // from `loopStartTime` (which carries whatever skew that has) and records
    // audio that arrived a round trip after it was played. Measure it with
    // scripts/check-chain-align.scd and set this to exactly what it reports —
    // the tool's sign and this one are deliberately the same.
    var <chainRecOffsetMs = 0;
    // The recorder outlives the swap when the offset is POSITIVE, finishing the
    // tail it started late for. Held here rather than in a closure so a teardown
    // or a cancel in that window can still reach it.
    var nextRecTail;
    var <nextRecState = \idle, nextRecStopRequested = false, nextRecReps = 0;

    *new { |looper| ^super.newCopyArgs(looper) }

    // The scratch, as long as the Looper's own loop buffer (its init).
    allocBuffer { |server, frames| nextBuffer = Buffer.alloc(server, frames, 2) }

    // The calibrated chain-record trim in seconds, clipped to under a loop
    // either way so the shifted start cannot cross a neighbouring boundary and
    // land the recording a whole repetition out.
    recOffset { |loopSecs|
        ^(chainRecOffsetMs / 1000).clip(loopSecs * -0.9, loopSecs * 0.9)
    }

    // Seconds to wait, from `phaseInLoop` into the current pass, before the
    // chain recorder starts: the NEXT loop boundary, shifted by `off`.
    //
    // Deliberately NOT .mod(loopSecs). That collapses the wait to nearly zero
    // whenever a positive offset pushes it past a whole loop, starting the
    // recorder at THIS boundary instead of the next one. Only a negative result
    // needs rescuing, and it needs a whole loop added.
    //
    // Pure on purpose. This arithmetic got the chained loops wrong once, and
    // inline in the Routine below — next to Synth.tail and the buffer — there
    // was no way to test it. See scripts/tests/test-chain-timing.scd.
    startWait { |loopSecs, phaseInLoop, off|
        var wait = (loopSecs - phaseInLoop) + off;
        if(wait < 0) { wait = wait + loopSecs };
        ^wait
    }

    // Set this to exactly what scripts/check-chain-align.scd reports.
    chainRecOffsetMs_ { |val|
        chainRecOffsetMs = val.clip(-2000, 2000);
        looper.changed(\chainRecOffsetMs, chainRecOffsetMs);
    }

    // A recorder running hears the return where it is now.
    returnChannel_ { |ch| nextRecSynth !? { |s| s.set(\ret, ch) } }

    // Armed: the capture starts at the next loop boundary. The Looper has
    // checked there is a loop and a return to chain from (armNextLoopRecord).
    arm {
        var server = looper.server, loopFrames = looper.loopFrames;
        var ld = loopFrames / server.sampleRate;
        var defName = if(looper.inChannelCount == 1) { \looperRecPlainMono } { \looperRecPlain };
        nextRecStopRequested = false;
        nextRecReps = 0;
        nextRecState = \armed;
        nextBuffer.zero;
        looper.changed(\nextRecState, \armed);
        "Next loop: armed — recording starts at next loop boundary.".postln;
        nextRecRoutine = Routine {
            var off = this.recOffset(ld);
            var firstRep = true;
            // Wait to the next loop boundary off the same wall-clock reference
            // BBCut uses (loopStartTime = audio start of the current engine),
            // shifted by the calibrated offset.
            var phaseInLoop = (SystemClock.seconds
                - (looper.loopStartTime ? SystemClock.seconds)) % ld;
            this.startWait(ld, phaseInLoop, off).wait;
            nextRecSynth = Synth.tail(server, defName, [
                \bufnum, nextBuffer.bufnum,
                \in, looper.inChannel,
                \ret, looper.returnChannel
            ]);
            nextRecState = \recording;
            looper.changed(\nextRecState, \recording);
            "Next loop: recording...".postln;
            // Count completed reps; a stop request takes effect at the boundary
            // that closes the current rep. Also bail if the buffer would overflow.
            //
            // The rep grid stays on the TRUE boundaries — only the first wait
            // absorbs the offset — so the swap still happens exactly on a loop
            // boundary and the handoff stays gapless.
            while { nextRecStopRequested.not } {
                if(firstRep) { (ld - off).wait; firstRep = false } { ld.wait };
                nextRecReps = nextRecReps + 1;
                if((nextRecReps + 1) * loopFrames > nextBuffer.numFrames) {
                    "Next loop: scratch buffer full — stopping.".warn;
                    nextRecStopRequested = true;
                };
            };
            this.finish(off);
        }.play(SystemClock);
    }

    // A press while recording: the capture ends at the boundary closing this
    // pass.
    requestStop {
        nextRecStopRequested = true;
        nextRecState = \stopping;
        looper.changed(\nextRecState, \stopping);
        "Next loop: will stop at the end of the current loop.".postln;
    }

    // The capture ends on a boundary: the recorder goes (or finishes the tail
    // it started late for), and the Looper swaps the capture in
    // (prSwapInNextLoop), giving back its old loop as the next scratch.
    finish { |off = 0|
        var n = nextRecReps.max(1);
        var newFrames = n * looper.loopFrames, sr = looper.server.sampleRate;
        // A recorder that started LATE (positive offset) is still short of the
        // final rep, so let it finish the tail; one that started early already
        // has everything and is freed here as before. It writes into what is
        // about to become the ACTIVE buffer, but the new engine below reads from
        // frame 0 while the write head is a whole loop further on.
        this.freeTail;
        nextRecSynth !? { |syn|
            if(off > 0) {
                nextRecTail = syn;
                SystemClock.sched(off, { this.freeTail; nil });
            } {
                syn.free;
            };
        };
        nextRecSynth = nil;
        nextRecRoutine = nil;
        nextBuffer = looper.prSwapInNextLoop(nextBuffer, n);
        nextRecState = \idle;
        nextRecStopRequested = false;
        looper.changed(\nextRecState, \idle);
        ("Next loop active: " ++ n ++ "x current loop ("
            ++ (newFrames / sr).round(0.01) ++ " s).").postln;
    }

    freeTail {
        nextRecTail !? { |s| s.free };
        nextRecTail = nil;
    }

    cancel {
        var wasActive = #[\armed, \recording, \stopping].includes(nextRecState);
        nextRecRoutine !? { |r| r.stop }; nextRecRoutine = nil;
        nextRecSynth !? { |s| s.free }; nextRecSynth = nil;
        this.freeTail;
        nextRecStopRequested = false;
        if(nextRecState != \idle) {
            nextRecState = \idle;
            looper.changed(\nextRecState, \idle);
        };
        if(wasActive) { "Next loop: cancelled.".postln };
    }

    // The Looper freed: the capture stops, the scratch goes.
    free {
        nextRecRoutine !? { |r| r.stop };
        nextRecSynth !? { |s| s.free };
        this.freeTail;
        nextBuffer !? { |b| b.free };
    }

    // Cmd-period freed every node and stopped every routine: forget them.
    forget {
        nextRecSynth = nil;
        nextRecRoutine = nil;
    }
}
