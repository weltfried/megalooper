// megalooper — the loop's key, heard (docs/dev/synth.md 6, "Key from the
// loop", 2026-11-14): the Looper's part that records the dry tap while a
// take or an overdub is played and has LoopKey hear it, so the note
// sequencer can play in the loop's key (MegaSADrums.setLoopKey, "From the
// loop").
//
//   - While a take records, \looperKeyCapture (LooperSynthDefs.keyCaptureGraph)
//     writes the analysis input at 12 kHz into a buffer of its own; an
//     overdub's goes into a second, so the take's is never written over
//     while it is read.
//   - Once the take's reading is in (Looper.stopRecordStartPlay's deferred
//     analysis), the audio comes to the language (reader: Buffer
//     loadToFloatArray) and LoopKey hears it in a Routine that lets the
//     clocks run every `slice` seconds: the drums decide their hits from a
//     SystemClock routine 100 ms ahead. A 30 s take is ~0.2 s of work.
//   - An overdub's evidence adds to the take's (its chroma and its tuning;
//     the first note and the bar lines stay the take's), and the key is
//     heard again from both.
//   - Bar by bar too (2026-11-14, sections): the take's bars (its reading,
//     from the first note: `grid`) each gather their own evidence, an
//     overdub's placed on them by where the loop played (the timeline; not
//     at half-time or reversed, when it counts for the whole loop only), and
//     a riff that moves gets `sections` in its key (LoopKey.sectionsOf):
//     each with the loop position of its first bar line (`at`, seconds from
//     the loop's start, the drums' bar lines) and `period`, the take's loop.
//   - The key is the Looper's \loopKey (LoopKey.keyOf's Event, nil for
//     none), and goes into the set's log as a loopKey event. A new key comes
//     when its analysis is done: the old one holds until then. Clear
//     forgets it; an undo brings back the one its snapshot had (takeState).
//   - A capture started (another take) or the loop gone while an analysis
//     runs drops that analysis: its audio may already be another's.
//
// A part of the Looper (as LooperChainRecorder is): it asks the Looper for
// its server and analysis input and says its changes as the Looper's.
LooperKey {
    var looper;
    // The capture buffers, mono at LoopKey.rate: the take's and an overdub's.
    var takeBuf, dubBuf;
    // The capture running: (synth:, kind: \take or \overdub, at: when it
    // started (SystemClock), offset: seconds into the take of its frame 0),
    // or nil; and the take's last one, stopped: (seconds:, offset:).
    var capture, lastTake;
    // One more for every capture of a take and for the loop gone: an
    // analysis started before it no longer counts.
    var serial = 0;
    // The take's evidence and the overdubs' since (LoopKey.merge), and the
    // key heard from them.
    var takeEvidence, dubEvidence, <key;
    // The take's bars (LoopKey.gridOf), for its overdubs too; nil without a
    // meter (no sections then).
    var grid;
    // How long the analysis works before it lets the clocks run, seconds.
    var <>slice = 0.003;
    // How the audio comes to the language: { |buf, frames, action| },
    // action.(FloatArray). A test hands its own.
    var <>reader;
    // How a capture's synth is made and freed: { |kind, buf| synth },
    // { |synth| }; what the time is (SystemClock seconds); how the hearing
    // runs: { |fn| }, a Routine on SystemClock. A test hands its own (and a
    // slice of inf: it never waits).
    var <>starter, <>stopper, <>clock, <>runner;

    *new { |looper| ^super.newCopyArgs(looper).init }

    init {
        reader = { |buf, frames, action| buf.loadToFloatArray(0, frames, { |data| action.value(data) }) };
        starter = { |kind, buf|
            Synth(\looperKeyCapture, [\ana, looper.analysisIn, \buf, buf.bufnum, \rate, LoopKey.rate],
                looper.server)
        };
        stopper = { |synth| synth.free };
        clock = { SystemClock.seconds };
        runner = { |fn| Routine(fn).play(SystemClock) };
    }

    // The two buffers, `seconds` long each (the Looper's loop buffer's
    // length: a take is never longer; an overdub's first `seconds` count).
    allocBuffers { |server, seconds|
        var frames = (seconds * LoopKey.rate).ceil.asInteger.max(1);
        takeBuf = Buffer.alloc(server, frames, 1);
        dubBuf = Buffer.alloc(server, frames, 1);
    }

    // Cmd-period freed every node: the capture is gone.
    forget {
        capture = nil;
        serial = serial + 1;
    }

    // The Looper freed: the capture stops, the buffers go.
    free {
        this.prStop;
        serial = serial + 1;
        takeBuf !? { |b| b.free };
        dubBuf !? { |b| b.free };
        takeBuf = nil;
        dubBuf = nil;
    }

    // ---- Captures -----------------------------------------------------------

    // A take begins recording (a press, or Autostart's first note): its
    // capture from now, its frame 0 `offset` seconds into the take
    // (Autostart's take starts its lead before the note the language hears
    // of).
    takeStarted { |offset = 0|
        this.prStop;
        serial = serial + 1;
        lastTake = nil;
        this.prStart(\take, takeBuf, offset);
    }

    // The take's recorder freed (Looper.prFreeRecorder): closed or dropped.
    // Its length is kept for analyseTake.
    takeStopped {
        if(capture.notNil and: { capture[\kind] == \take }) {
            lastTake = (seconds: clock.value - capture[\at], offset: capture[\offset], serial: serial);
            this.prStop;
        };
    }

    overdubStarted {
        this.prStop;
        this.prStart(\overdub, dubBuf, 0);
    }

    // The overdub ended as an overdub (Looper.endOverdub): heard, and its
    // evidence added. Ended any other way (a Stop, an undo) it is dropped:
    // stateChanged.
    overdubEnded {
        var seconds, mySerial = serial, at, dubGrid;
        if(capture.isNil or: { capture[\kind] != \overdub }) { ^this };
        at = capture[\at];
        seconds = clock.value - at;
        this.prStop;
        dubGrid = grid !? { |g| this.prDubPosOf(at) !? { |f| g.copy.put(\posOf, f) } };
        this.prHear(dubBuf, seconds, 0, nil, nil, nil, dubGrid, { |ev, pause|
            if((mySerial == serial) and: { ev.notNil }) {
                dubEvidence = LoopKey.merge(dubEvidence, ev);
                this.prSetKey(\overdub, pause);
            };
        });
    }

    // Where the loop played, in the take's time, t seconds into an overdub
    // whose capture began at `at` (the loop's position: its frame 0 is the
    // take's); nil where that cannot be said simply (half-time, reversed,
    // no loop running).
    prDubPosOf { |at|
        var tl, loopSecs;
        if(looper.respondsTo(\timeline).not) { ^nil };
        tl = looper.timeline;
        loopSecs = looper.loopDuration ? 0;
        if((tl.speed != 1) or: { looper.reverseFlag == true } or: { tl.loopStartTime.isNil } or: { loopSecs <= 0 }) { ^nil };
        ^{ |t| tl.positionAt(at + t, loopSecs) }
    }

    // Every state the Looper goes into (prSetState): a capture whose
    // recording is over without its own end is dropped.
    stateChanged { |state|
        capture !? { |c|
            if(((c[\kind] == \take) and: { state != \recording })
                or: { (c[\kind] == \overdub) and: { state != \overdubbing } }) { this.prStop };
        };
    }

    prStart { |kind, buf, offset|
        var synth;
        if(buf.isNil) { ^this };
        synth = starter.value(kind, buf);
        capture = (synth: synth, kind: kind, buf: buf, at: clock.value, offset: offset);
    }

    prStop {
        capture !? { |c| c[\synth] !? { |s| stopper.value(s) } };
        capture = nil;
    }

    // ---- Hearing --------------------------------------------------------------

    // The take just closed, once its reading is in: dur its length, onsets
    // its onset times and first its first note's (seconds into the take),
    // result the reading (its bar lines; nil or without a meter: none).
    analyseTake { |dur, onsets, first, result|
        var take = lastTake, lines, f, g;
        if(take.isNil or: { take[\serial] != serial }) { ^this };
        f = first ?? { onsets.first } ? 0;
        lines = LoopKey.barLinesOf(result, f, dur);
        // The bars, from the first note, as long as the loop the reading
        // made (its length once snapped); the capture's time is the take's
        // less its offset.
        g = LoopKey.gridOf(result, f, (result !? { |r| r[\loopDur] }) ? dur);
        this.prHear(takeBuf, take[\seconds].min(dur), take[\offset], onsets, lines, first,
            g !? { |x| x.copy.put(\posOf, { |t| t + take[\offset] }) }, { |ev, pause|
                if(take[\serial] == serial) {
                    takeEvidence = ev;
                    dubEvidence = nil;
                    grid = g;
                    this.prSetKey(\take, pause);
                };
            });
    }

    // `seconds` of `buf` heard; done.(evidence or nil, pause) in the Routine
    // that heard it (pause lets the clocks run, for more work there), or at
    // once with nil for under half a second. Times are the take's, the
    // capture's frame 0 `offset` into it; grid (LoopKey.gridOf, its posOf
    // from the capture's time) gathers the bars' evidence too.
    prHear { |buf, seconds, offset, onsets, lines, first, grid, done|
        var frames = (seconds * LoopKey.rate).floor.asInteger;
        var shift = { |ts| ts !? { ts.collect { |t| t - offset } } };
        if(buf.isNil or: { frames < (LoopKey.rate * 0.5) }) { done.value(nil, nil); ^this };
        frames = frames.min(buf.numFrames ? frames);
        reader.value(buf, frames, { |data|
            runner.value({
                var mark = Main.elapsedTime, ev;
                // Waits from now, not from the Routine's logical time, which
                // stands still while it works (LooperSessionRecorder.prBreathe).
                var pause = {
                    if((Main.elapsedTime - mark) > slice) {
                        ((Main.elapsedTime - thisThread.seconds).max(0) + 0.001).wait;
                        mark = Main.elapsedTime;
                    };
                };
                ev = LoopKey.evidenceOf(Signal.newFrom(data), LoopKey.rate, shift.(onsets), shift.(lines),
                    first !? { |f| f - offset }, pause, grid);
                done.value(ev, pause);
            });
        });
    }

    // The key from the evidence there is, said if it changed (`from`: what
    // brought it, for the log).
    prSetKey { |from, pause|
        var ev = LoopKey.merge(takeEvidence, dubEvidence), k = LoopKey.keyOf(ev), secs;
        if(k.notNil and: { grid.notNil }) {
            secs = LoopKey.sectionsOf(ev, nil, pause);
            secs !? { k.put(\sections, secs.collect { |sc| sc.copy.put(\at, grid[\starts][sc[\from]]) })
                .put(\period, grid[\period]) };
        };
        if(k == key) { ^this };
        key = k;
        looper.prLogEvent(\loopKey, this.class.logFields(k, from));
        looper.changed(\loopKey, k);
        k !? { ("Loop key: " ++ LoopKey.words(k) ++ " (" ++ (k[\inside] * 100).round.asInteger
            ++ " % inside, tuning " ++ k[\cents] ++ " c)" ++ (k[\sections] !? { |ss| "; it changes: "
                ++ this.class.sectionWords(ss) } ? "") ++ ".").postln };
    }

    // A key's sections in words: "bars 1-2 E Minor pentatonic, 3-4 A Minor pentatonic".
    *sectionWords { |secs|
        ^"bars " ++ secs.collect { |sc|
            (sc[\from] + 1).asString ++ (if(sc[\to] > (sc[\from] + 1)) { "–" ++ sc[\to] } { "" }) ++ " "
                ++ LoopKey.words(sc[\key]) }.join(", ")
    }

    // A key as the set's log keeps it.
    *logFields { |k, from|
        if(k.isNil) { ^(from: from, key: nil) };
        ^(from: from, root: k[\root], pcs: k[\pcs], name: k[\name], core: k[\core],
            heard: k[\heard][\pcs], heardName: k[\heard][\name], inside: k[\inside].round(0.001),
            margin: k[\margin].round(0.0001), cents: k[\cents], chroma: k[\chroma],
            sections: k[\sections] !? { |ss| ss.collect { |sc| [sc[\from], sc[\to], sc[\key][\root], sc[\key][\pcs],
                sc[\key][\name]] } })
    }

    // ---- The loop gone, an undo -------------------------------------------------

    clear {
        this.prStop;
        serial = serial + 1;
        lastTake = nil;
        takeEvidence = nil;
        dubEvidence = nil;
        grid = nil;
        if(key.notNil) {
            key = nil;
            looper.prLogEvent(\loopKey, this.class.logFields(nil, \clear));
            looper.changed(\loopKey, nil);
        };
    }

    // What an undo snapshot keeps (Looper.snapshotForUndo), and brings back.
    takeState { ^(keyTake: takeEvidence, keyDubs: dubEvidence, key: key, keyGrid: grid) }

    restoreTake { |st|
        var old = key;
        serial = serial + 1;
        takeEvidence = st[\keyTake];
        dubEvidence = st[\keyDubs];
        grid = st[\keyGrid];
        key = st[\key];
        if(key != old) {
            looper.prLogEvent(\loopKey, this.class.logFields(key, \undo));
            looper.changed(\loopKey, key);
        };
    }
}
