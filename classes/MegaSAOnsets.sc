// megalooper — the take's onsets for the devices that read them (the Rhythm
// Echo, MegaSAFx.rhythmEcho; docs/dev/rhythm-echo.md, roadmap item 23 idea 4).
//
// The server buffers such a device reads, and the controls that go with
// them, kept up with the Looper's onset pattern (LooperOnsetNotes: each
// onset's time from the loop's start and its strength against the loudest,
// over the take's own period, `patternDur`; a multiplied loop holds it more
// than once):
//
//   onsetsBuf  the onsets' times over the whole loop, seconds, rising,
//              unused slots 1e9 (groupSlots of them)
//   gainsBuf   each one's gain: the square root of its strength, so an echo
//              keeps the riff's accents without the quiet ones vanishing
//   irRaw      one period of taps at the onsets after the first, timed from
//              it, at the loop's speed, moved MegaSAFx.rhythmEchoLatency
//              frames earlier for PartConv's own delay; at most
//              rhythmEchoMaxLoop seconds
//   irBuf      irRaw prepared for PartConv (b_gen PreparePartConv), the one
//              the devices read. PartConv keeps its data from its start, so
//              it is rewritten IN PLACE, the echoes ducked (\irReady 0) over it.
//
// MegaSA makes one before any chain is built, so a device that reads onsets
// never starts on buffer 0 (which could be a loop of minutes: IndexInBetween
// would search it every block, PartConv take it for its IR). The chains carry
// its `args` to such a device's start (MegaSAChain.onsetArgs) and hear each
// change as a set on their group.
MegaSAOnsets {
    var server, <onsetsBuf, <gainsBuf, <irRaw, <irBuf;
    // What the buffers hold now, as controls (\loopDur ... \irReady).
    var <loopDur = 0, <onsetCount = 0, <patternDur = 0, <perPattern = 0, <speed = 1;
    // An update on its way: the latest asked for waits for the one running.
    var routine, pending, lastKey;
    // Whom to tell: { |controls| }, each chain's group set (MegaSA's).
    var <>tell;

    *new { |server| ^super.newCopyArgs(server).init }

    *irFrames { |sampleRate| ^(MegaSAFx.rhythmEchoMaxLoop * sampleRate).asInteger }
    *partSize { |sampleRate|
        var fft = MegaSAFx.rhythmEchoFft;
        ^fft * (this.irFrames(sampleRate) / (fft / 2)).roundUp.asInteger
    }

    init {
        var sr = server.sampleRate ? 48000, slots = LooperSynthDefs.groupSlots;
        onsetsBuf = Buffer.alloc(server, slots, 1);
        gainsBuf = Buffer.alloc(server, slots, 1);
        irRaw = Buffer.alloc(server, this.class.irFrames(sr), 1);
        irBuf = Buffer.alloc(server, this.class.partSize(sr), 1);
    }

    free {
        routine !? { |r| r.stop };
        routine = nil;
        [onsetsBuf, gainsBuf, irRaw, irBuf].do { |b| b !? { b.free } };
    }

    // The controls a device starts with: the buffers and what they hold.
    args {
        ^[\onsetsBuf, onsetsBuf.bufnum, \gainsBuf, gainsBuf.bufnum, \irBuf, irBuf.bufnum,
            \loopDur, loopDur, \onsetCount, onsetCount, \patternDur, patternDur, \perPattern, perPattern,
            \speed, speed, \irReady, 1]
    }

    // ---- Pure, for the tests ----------------------------------------------------

    // The whole loop's onsets from one period's: [times, gains, count], the
    // pattern laid end to end over the loop (a multiplied loop), at most
    // groupSlots of them, padded to groupSlots (times 1e9, gains 0).
    *table { |pattern, patternDur, loopSecs|
        var slots = LooperSynthDefs.groupSlots, times = List.new, gains = List.new, reps, count;
        if(pattern.isNil or: { pattern.isEmpty } or: { (patternDur ? 0) <= 0 } or: { (loopSecs ? 0) <= 0 }) {
            ^[Array.fill(slots, 1e9), Array.fill(slots, 0), 0]
        };
        reps = (loopSecs / patternDur).round.asInteger.max(1);
        reps.do { |k|
            pattern.do { |p|
                var t = p[0] + (k * patternDur);
                if((t < loopSecs) and: { times.size < slots }) { times.add(t); gains.add(p[1].clip(0, 1).sqrt) };
            };
        };
        count = times.size;
        ^[times.asArray ++ Array.fill(slots - count, 1e9), gains.asArray ++ Array.fill(slots - count, 0), count]
    }

    // The IR's taps, [frame, gain] pairs: the onsets after the first, timed
    // from it, at `speed` (half-time: twice as far apart), moved PartConv's
    // delay earlier; those that fall before 0 or past the IR are left out.
    *taps { |pattern, speed = 1, sampleRate = 48000|
        var frames = this.irFrames(sampleRate), out = List.new, t0;
        if(pattern.isNil or: { pattern.size < 2 }) { ^[] };
        t0 = pattern[0][0];
        pattern.drop(1).do { |p|
            var at = (((p[0] - t0) / speed.abs.max(0.25)) * sampleRate).round.asInteger - MegaSAFx.rhythmEchoLatency;
            if((at >= 0) and: { at < frames }) { out.add([at, p[1].clip(0, 1).sqrt]) };
        };
        ^out.asArray
    }

    // ---- Following the Looper ---------------------------------------------------

    // The Looper's pattern now (none: no echo), from a Routine or not: a
    // change already in force is let be; one asked for while another runs
    // waits for it, and only the latest is done.
    follow { |pattern, patternDur, loopSecs, loopSpeed|
        var key = [pattern, patternDur, loopSecs, loopSpeed];
        if(key == lastKey) { ^this };
        lastKey = key;
        pending = key;
        if(routine.isNil) {
            routine = Routine {
                var job;
                while { pending.notNil } {
                    job = pending;
                    pending = nil;
                    this.prApply(*job);
                };
                routine = nil;
            }.play(SystemClock);
        };
    }

    // Duck the echoes, rewrite the IR in place and prepare it, then the
    // onsets, then say what they hold.
    prApply { |pattern, pDur, loopSecs, loopSpeed|
        var sr = server.sampleRate ? 48000;
        var table = this.class.table(pattern, pDur, loopSecs);
        var taps = this.class.taps(pattern, loopSpeed ? 1, sr);
        tell !? { |f| f.value([\irReady, 0]) };
        0.06.wait;
        irRaw.zero;
        server.sync;
        if(taps.notEmpty) { server.listSendMsg([\b_set, irRaw.bufnum] ++ taps.flatten) };
        server.listSendMsg([\b_gen, irBuf.bufnum, "PreparePartConv", irRaw.bufnum, MegaSAFx.rhythmEchoFft]);
        server.sync;
        onsetsBuf.setn(0, table[0]);
        gainsBuf.setn(0, table[1]);
        server.sync;
        loopDur = if(table[2] > 0) { loopSecs } { 0 };
        onsetCount = table[2];
        patternDur = pDur ? 0;
        perPattern = (pattern ? []).size;
        speed = loopSpeed ? 1;
        tell !? { |f| f.value(this.args.drop(6)) };
    }
}
