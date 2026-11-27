// megalooper — the loop's notes (roadmap item 24, docs/dev/sampler.md): the
// Looper's part that cuts the loop into slices at its own attacks
// (LoopSlices) and keeps the engine's slice table, which the engine reads to
// shorten each note (Looper.noteLength) or turn it backwards in its own slot
// (Looper.toggleNotesBackwards; LooperSynthDefs.noteSlices).
//
//   - Once a take's reading is in (beside the onset notes' pattern: the take,
//     an overdub that gave the loop its meter), the loop's audio comes to the
//     language (reader: Buffer loadToFloatArray) and LoopSlices searches each
//     onset's real attack in a Routine that lets the clocks run every `slice`
//     seconds: the drums decide their hits 100 ms ahead on SystemClock. A take
//     of 30 onsets is ~0.1 s of work.
//   - The table goes to a buffer of its own on the server, and `slicesOn` to
//     the engine, in one bundle: a table replaced while the engine reads it
//     is replaced between two blocks. Until a take's table is in, slicesOn is
//     0 and the notes play as they are.
//   - The starts are kept for the loop length they were cut for (`period`):
//     a loop a whole number of those long (a multiply, the next loop over it)
//     plays them again in each, as the onset notes' pattern does. Another
//     length keeps those that fit.
//   - The next loop records the old one through its chain into a buffer of
//     its own, a chain's latency later: its slices are searched again in its
//     own audio, from the old starts.
//   - The pulse the note lengths count in is the reading's (its beat), sent
//     again with every reading.
//   - A new take drops them (its own come with its analysis); clear forgets
//     them; an undo brings back the ones its snapshot had (takeState).
//   - Something else changing the loop while a search runs (a take, a clear,
//     an undo) drops that search: its audio may already be another's.
//
// A part of the Looper (as LooperKey is): it asks the Looper for its server,
// its buffer and its engine, and says its changes as the Looper's.
LooperSlices {
    var looper;
    // The table's buffer on the server: LoopSlices.maxSlices + 4 frames.
    var <tableBuf;
    // The slices' starts, frames from the loop's start, for a loop `period`
    // frames long; nil for none. And the last search, for the log.
    var <starts, <period;
    // One more for every change of loop: a search started before it no
    // longer counts.
    var serial = 0;
    // How long the search works before it lets the clocks run, seconds.
    var <>slice = 0.003;
    // How the audio comes to the language: { |buf, from, frames, action| },
    // action.(FloatArray, interleaved stereo); how the search runs: { |fn| },
    // a Routine on SystemClock. A test hands its own.
    var <>reader, <>runner;

    *new { |looper| ^super.newCopyArgs(looper).init }

    init {
        reader = { |buf, from, frames, action| buf.loadToFloatArray(from, frames, { |data| action.value(data) }) };
        runner = { |fn| Routine(fn).play(SystemClock) };
    }

    allocBuffer { |server|
        tableBuf = Buffer.alloc(server, LoopSlices.maxSlices + 4, 1);
    }

    // Cmd-period: a search on its way is for an engine that is gone.
    forget { serial = serial + 1 }

    free {
        serial = serial + 1;
        tableBuf !? { |b| b.free };
        tableBuf = nil;
    }

    // How many slices a pass of the loop has now (0: none yet, or none).
    count { ^this.prTable !? { |t| t.size - 4 } ? 0 }

    // What a new engine is started with (Looper.spawnEngine): the table it
    // reads, whether one is in force, and the pulse.
    engineArgs {
        ^[\sliceBuf, tableBuf !? { |b| b.bufnum } ? 0, \slicesOn, this.prOn.binaryValue, \tauFrames, this.tauFrames]
    }

    // The reading's beat, frames (the note lengths count in it); half a
    // second with no reading.
    tauFrames {
        var r = looper.lastResult, sr = looper.server.sampleRate ? 48000;
        ^((r !? { |x| x[\tau] !? { |t| t * (x[\sub] ? 1) } }) ? 0.5) * sr
    }

    // ---- Cutting ----------------------------------------------------------------

    // The loop's slices, searched from `onsetFrames` (frames from the loop's
    // start, as reported) in its audio as it is now. `drop`: the slices in
    // force go at once (a new take's); otherwise they hold until the new ones
    // are in (an overdub's reading, the next loop).
    build { |onsetFrames, drop = true|
        var region = looper.prLoopRegion, mySerial, frames, sr;
        serial = serial + 1;
        mySerial = serial;
        if(drop) { starts = nil; period = nil; this.sync };
        frames = region[2];
        sr = looper.server.sampleRate ? 48000;
        if(onsetFrames.isNil or: { onsetFrames.isEmpty } or: { frames <= 0 } or: { region[0].isNil }) { ^this };
        reader.value(region[0], region[1], frames, { |data|
            runner.value({
                var mark = Main.elapsedTime, res;
                // Waits from now, not from the Routine's logical time, which
                // stands still while it works (LooperKey.prHear).
                var pause = {
                    if((Main.elapsedTime - mark) > slice) {
                        ((Main.elapsedTime - thisThread.seconds).max(0) + 0.001).wait;
                        mark = Main.elapsedTime;
                    };
                };
                res = LoopSlices.attackStarts(data, sr, onsetFrames, 2, pause);
                if(mySerial == serial) {
                    starts = res[\starts];
                    period = frames;
                    this.sync;
                    looper.prLogEvent(\slices, (count: starts.size, offsetMs: (res[\offset] / sr * 1000).round(0.1),
                        found: res[\found].count { |f| f == true }, onsets: res[\found].size));
                    ("Loop notes: " ++ starts.size ++ " slices, the loop's audio "
                        ++ (res[\offset] / sr * 1000).round(0.1) ++ " ms from the reported onsets.").postln;
                };
            });
        });
    }

    // The next loop's buffer (Looper.prSwapInNextLoop): the old starts, as
    // many times over as it is passes long, searched again in its own audio.
    // Until then the old ones play, repeated.
    rebuild {
        var all = this.prAllStarts;
        this.sync;
        all !? { |a| this.build(a, false) };
    }

    // ---- Sending ----------------------------------------------------------------

    // The table for the loop as it is now, and the pulse, to the server: the
    // table and slicesOn in one bundle.
    sync {
        var tbl = this.prTable, eng = looper.prEngineMsg(\slicesOn, tbl.notNil.binaryValue, \tauFrames, this.tauFrames);
        var msgs = List.new;
        if(tbl.notNil and: { tableBuf.notNil }) {
            msgs.add([\b_setn, tableBuf.bufnum, 0, LoopSlices.maxSlices + 4] ++ LoopSlices.padded(tbl));
        };
        eng !? { |m| msgs.add(m) };
        if(msgs.notEmpty) { looper.server.sendBundle(nil, *msgs.asArray) };
        looper.changed(\slices, this.count);
    }

    // The reading changed: its beat to the engine.
    follow {
        looper.prEngineMsg(\tauFrames, this.tauFrames) !? { |m| looper.server.sendMsg(*m) };
    }

    // ---- The loop gone, an undo -------------------------------------------------

    clear {
        serial = serial + 1;
        starts = nil;
        period = nil;
        this.sync;
    }

    // What an undo snapshot keeps (Looper.snapshotForUndo), and brings back.
    takeState { ^(sliceStarts: starts, slicePeriod: period) }

    restoreTake { |st|
        serial = serial + 1;
        starts = st[\sliceStarts];
        period = st[\slicePeriod];
        this.sync;
    }

    // ---- Inside ---------------------------------------------------------------

    prOn { ^this.prTable.notNil }

    // Every start in the loop as it is now: the period's, again in each
    // period of a loop a whole number of them long, or those that fit.
    prAllStarts {
        var n = looper.loopFrames, k;
        if(starts.isNil or: { period.isNil } or: { n <= 0 } or: { period <= 0 }) { ^nil };
        k = (n / period).round.asInteger.max(1);
        ^if((k * period) == n) { (0 .. k - 1).collect { |i| starts + (i * period) }.flat }
            { starts.select { |f| f < n } }
    }

    prTable {
        var all = this.prAllStarts, n = looper.loopFrames;
        if(all.isNil or: { all.isEmpty }) { ^nil };
        ^LoopSlices.table(all, n)
    }
}
