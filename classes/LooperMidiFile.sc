// Standard MIDI Files, built and read in memory: what a recorded set's drums
// become for a DAW.
//
// The session recorder writes one per set (LooperSessionRecorder, the drums'
// hits as they sounded), so a set can be taken into Live afterwards and played
// back through the racks that made the sound there. Everything here is a pure
// class method, bytes in and bytes out: the encodings, and the arithmetic that
// decides where a note lands (tickAt) and when it ends (noteEvents), are
// testable without a file. *write puts the bytes on disk; *parse reads them
// back, for the tests: it understands what *bytes writes plus the common rest
// (running status, sysex), not every corner of the format.
//
// THE SHAPE, fixed: format 1 (a conductor track, then the note tracks), 480
// ticks per quarter note, delta times as variable-length quantities, no
// running status (every event carries its own status byte, so any reader and
// any hex dump agrees on where an event starts), every track closed by End of
// Track. A track is given as [tick, bytes] pairs with ABSOLUTE ticks; *track
// orders them stably and writes the deltas, so no caller does delta
// arithmetic.
//
// Channels are 0-based here, as in the bytes: MIDI channel 2 is 1.
LooperMidiFile {

    *division { ^480 }

    // ---- encodings ------------------------------------------------------------

    // A variable-length quantity: seven bits per byte, most significant first,
    // every byte but the last with its top bit set. The format allows four
    // bytes, 0x0FFFFFFF at most: at 480 ticks a quarter and 200 BPM that is
    // more than 46 hours of delta, so a value past it is a bug upstream, held
    // there with a warning rather than written as garbage.
    *vlq { |n|
        var v, out;
        v = n.asInteger;
        if(v < 0) {
            ("MIDI file: a negative delta (" ++ n ++ ") was written as 0.").warn;
            v = 0;
        };
        if(v > 0x0FFFFFFF) {
            ("MIDI file: a delta of " ++ n ++ " ticks is past the format's limit; held there.").warn;
            v = 0x0FFFFFFF;
        };
        out = [v.bitAnd(0x7F)];
        v = v >> 7;
        while { v > 0 } {
            out = out.addFirst(v.bitAnd(0x7F).bitOr(0x80));
            v = v >> 7;
        };
        ^out
    }

    // Big-endian integers, as the header and the tempo carry them.
    *u16 { |n| ^[(n >> 8).bitAnd(255), n.bitAnd(255)] }
    *u24 { |n| ^[(n >> 16).bitAnd(255), (n >> 8).bitAnd(255), n.bitAnd(255)] }
    *u32 { |n| ^[(n >> 24).bitAnd(255), (n >> 16).bitAnd(255), (n >> 8).bitAnd(255), n.bitAnd(255)] }

    // A string's bytes. String:ascii answers signed values for anything past
    // 127 (a UTF-8 sequence), so they are folded back into 0..255.
    *text { |str| ^str.asString.ascii.collect { |b| b.bitAnd(255) } }

    // A meta event: FF, its type, the data's length as a VLQ, the data.
    *meta { |type, data| ^[0xFF, type] ++ this.vlq(data.size) ++ data }

    *trackName { |name| ^this.meta(0x03, this.text(name)) }
    *marker { |str| ^this.meta(0x06, this.text(str)) }
    *endOfTrack { ^[0xFF, 0x2F, 0x00] }

    // Microseconds per quarter note, the only way the format states a tempo.
    // Rounded to the microsecond: at 165.04 BPM that is 363548 (of 363548.23),
    // which reads back as 165.04010 BPM. A DAW that takes the tempo from the
    // file is that close, which puts a note twenty minutes in 0.76 ms (a tick)
    // early; one set by hand from the file name is exact, and the ticks are
    // computed at that tempo (see tickAt).
    *usPerQuarter { |bpm| ^(60e6 / bpm).round.asInteger.clip(1, 0xFFFFFF) }
    *tempo { |bpm| ^this.meta(0x51, this.u24(this.usPerQuarter(bpm))) }

    // nn dd cc bb: the numerator, the denominator as a power of two, MIDI
    // clocks per metronome click (24, one quarter note) and 32nds per quarter
    // (8). A denominator that is no power of two cannot be said in this format;
    // the nearest one is written, with a warning.
    *timeSignature { |num, den|
        var dd = den.asFloat.log2.round.asInteger.max(0);
        if((2 ** dd) != den) {
            ("MIDI file: " ++ num ++ "/" ++ den ++ " has no power-of-two denominator; written as "
                ++ num ++ "/" ++ (2 ** dd).asInteger ++ ".").warn;
        };
        ^this.meta(0x58, [num.asInteger.clip(1, 255), dd.clip(0, 255), 24, 8])
    }

    *noteOn { |chan, note, vel| ^[0x90.bitOr(chan.asInteger.bitAnd(15)), note.asInteger.bitAnd(127), vel.asInteger.bitAnd(127)] }
    *noteOff { |chan, note, vel = 0| ^[0x80.bitOr(chan.asInteger.bitAnd(15)), note.asInteger.bitAnd(127), vel.asInteger.bitAnd(127)] }

    // ---- time -----------------------------------------------------------------

    // The tick of a moment `seconds` after the file's zero, at `bpm`:
    // seconds * (bpm / 60) quarter notes, `division` ticks each, rounded. A
    // file has ONE tempo here, so a DAW playing it at exactly that tempo puts
    // every note at its second, within half a tick (0.38 ms at 165 BPM), over
    // any length: nothing accumulates, each tick is computed from the zero.
    // Whose seconds is the caller's to say: a set's are the WAVs' (see
    // LooperSessionRecorder.wavTime), not the clock the hits were stamped on.
    *tickAt { |seconds, bpm, division|
        ^((seconds * (bpm / 60)) * (division ? this.division)).round.asInteger
    }

    // Notes, as (tick:, chan:, note:, vel:, dur:) Events, into [tick, bytes]
    // pairs in the order they are to be written. Each note ends `dur` ticks
    // after it starts, or one tick before the next note-on of the same note on
    // the same channel if that comes sooner, and lasts at least one tick: two
    // note-ons of one key before its note-off leave a DAW holding the first
    // one, and a note-off at the very tick of the next note-on is read by some
    // as ending the new note. Two notes of one key on one tick are one note,
    // at the louder velocity. At any one tick the note-offs come before the
    // note-ons, so an end and a start that fall together never swap.
    //
    // A single pass with a short list of pending note-offs: the notes arrive
    // sorted by tick (they are sorted here, stably, if not), and a note-off is
    // never more than `dur` after its note-on, so the list holds only the
    // notes still sounding. `pace`, if given, is called every few hundred
    // notes: a long set is tens of thousands of them, and a caller in a
    // Routine can let the rest of the language run between slices.
    *noteEvents { |notes, pace|
        var list = this.sortedBy(notes.asArray, \tick);
        var out = List.new, pending = List.new, open = Dictionary.new;
        var i = 0, seq = 0, count = 0;
        var flush, insert, group, t, n, key, same, prev, entry;
        // pending: [offTick, seq, bytes, onTick, key], sorted by (offTick, seq).
        flush = { |upTo|
            while { pending.notEmpty and: { pending[0][0] <= upTo } } {
                out.add([pending[0][0], pending[0][2]]);
                pending.removeAt(0);
            };
        };
        insert = { |e|
            var at = pending.detectIndex { |p|
                (p[0] > e[0]) or: { (p[0] == e[0]) and: { p[1] > e[1] } }
            } ? pending.size;
            pending.insert(at, e);
        };
        while { i < list.size } {
            t = list[i][\tick];
            // Every note starting on this tick, one per key, in arrival order.
            group = List.new;
            while { (i < list.size) and: { list[i][\tick] == t } } {
                n = list[i];
                key = (n[\chan].asInteger * 128) + n[\note].asInteger;
                same = group.detect { |g| g[\key] == key };
                if(same.notNil) {
                    same[\vel] = same[\vel].max(n[\vel].asInteger);
                    same[\dur] = same[\dur].max(n[\dur].asInteger);
                } {
                    group.add((key: key, chan: n[\chan].asInteger, note: n[\note].asInteger,
                        vel: n[\vel].asInteger, dur: n[\dur].asInteger));
                };
                i = i + 1;
            };
            // A key still sounding ends a tick before it starts again (and at
            // least a tick after its own start).
            group.do { |g|
                prev = open[g[\key]];
                if(prev.notNil and: { prev[0] >= t } and: { pending.includes(prev) }) {
                    pending.remove(prev);
                    prev[0] = (t - 1).max(prev[3] + 1);
                    insert.(prev);
                };
            };
            flush.(t);
            group.do { |g|
                entry = [t + g[\dur].max(1), seq, this.noteOff(g[\chan], g[\note]), t, g[\key]];
                seq = seq + 1;
                out.add([t, this.noteOn(g[\chan], g[\note], g[\vel])]);
                insert.(entry);
                open.put(g[\key], entry);
                count = count + 1;
                if(pace.notNil and: { (count % 500) == 0 }) { pace.value };
            };
        };
        flush.(inf);
        ^out.asArray
    }

    // ---- the file ---------------------------------------------------------------

    // One MTrk chunk from [tick, bytes] pairs, ordered by tick and, within a
    // tick, as given. End of Track goes at `endTick`, or at the last event if
    // that is later: a file whose tracks all end at the set's length opens in a
    // DAW as clips of that length.
    *track { |events, endTick, pace|
        var list = this.sortedBy(events.asArray, 0);
        var data = List.new, last = 0;
        list.do { |e, i|
            var tick = e[0].asInteger.max(last);
            data.addAll(this.vlq(tick - last));
            data.addAll(e[1]);
            last = tick;
            if(pace.notNil and: { (i % 2000) == 1999 }) { pace.value };
        };
        data.addAll(this.vlq((endTick ? last).asInteger.max(last) - last));
        data.addAll(this.endOfTrack);
        ^this.text("MTrk") ++ this.u32(data.size) ++ data.asArray
    }

    // The whole file: the header (format 1, the number of tracks, the
    // division), then each track, as signed bytes (Int8Array, what File:write
    // puts on disk unchanged). `tracks` is an Array of [tick, bytes] lists.
    *bytes { |tracks, division, endTick, pace|
        var body = List.new, out;
        body.addAll(this.text("MThd"));
        body.addAll(this.u32(6));
        body.addAll(this.u16(1));
        body.addAll(this.u16(tracks.size));
        body.addAll(this.u16(division ? this.division));
        tracks.do { |t| body.addAll(this.track(t, endTick, pace)) };
        out = Int8Array.newClear(body.size);
        body.do { |b, i|
            out[i] = if(b > 127) { b - 256 } { b };
            if(pace.notNil and: { (i % 20000) == 19999 }) { pace.value };
        };
        ^out
    }

    // Write the file; false, with a warning, when it cannot be opened.
    *write { |path, tracks, division, endTick, pace|
        var data = this.bytes(tracks, division, endTick, pace);
        var file = File(path, "wb");
        if(file.isOpen.not) {
            ("MIDI file: could not write " ++ path ++ ".").warn;
            ^false
        };
        file.write(data);
        file.close;
        ^true
    }

    // ---- reading back -------------------------------------------------------------

    *read { |path|
        var file, data;
        if(File.exists(path).not) { ^(error: "no such file: " ++ path) };
        file = File(path, "rb");
        if(file.isOpen.not) { ^(error: "could not open " ++ path) };
        data = Int8Array.newClear(file.length);
        file.read(data);
        file.close;
        ^this.parse(data)
    }

    // A file's contents as (format:, division:, tracks:), each track an Array
    // of events with ABSOLUTE ticks: (tick:, delta:, bytes:) plus, for a meta
    // event, meta: (its type) and data:, for a text one also text:, and for a
    // channel message status: (high nibble), chan: and data:, with note: and
    // vel: for a note. An Event with error: (a sentence) when the bytes are not
    // a file this reads. Pure: no file is touched.
    *parse { |bytes|
        var b = bytes.asArray.collect { |x| x.asInteger.bitAnd(255) };
        var pos = 14, tracks = List.new, k = 0, ntrks, end, got;
        if((b.size < 14) or: { this.prStr4(b, 0) != "MThd" }) { ^(error: "no MThd header") };
        if(this.prU32At(b, 4) != 6) { ^(error: "a header of " ++ this.prU32At(b, 4) ++ " bytes, not 6") };
        ntrks = this.prU16At(b, 10);
        while { k < ntrks } {
            if(this.prStr4(b, pos) != "MTrk") { ^(error: "track " ++ k ++ ": no MTrk at byte " ++ pos) };
            end = (pos + 8) + this.prU32At(b, pos + 4);
            if(end > b.size) { ^(error: "track " ++ k ++ " runs past the end of the data") };
            got = this.prParseTrack(b, pos + 8, end);
            if(got.isString) { ^(error: "track " ++ k ++ ": " ++ got) };
            tracks.add(got);
            pos = end;
            k = k + 1;
        };
        ^(format: this.prU16At(b, 8), division: this.prU16At(b, 12), tracks: tracks.asArray)
    }

    // One track's events from b[pos..end-1], or a sentence saying what is wrong.
    *prParseTrack { |b, pos, end|
        var events = List.new, tick = 0, running, d, start, status, ev, need, lenAt;
        while { pos < end } {
            d = this.prVlqAt(b, pos, end);
            if(d.isNil) { ^"a broken delta at byte " ++ pos };
            tick = tick + d[0];
            pos = d[1];
            start = pos;
            status = b[pos];
            case
            { status == 0xFF } {
                lenAt = this.prVlqAt(b, pos + 2, end);
                if(lenAt.isNil or: { (lenAt[1] + lenAt[0]) > end }) { ^"a broken meta event at byte " ++ pos };
                ev = (tick: tick, delta: d[0], meta: b[pos + 1],
                    data: b.copyRange(lenAt[1], (lenAt[1] + lenAt[0]) - 1));
                if(ev[\meta].inclusivelyBetween(1, 7)) { ev[\text] = ev[\data].collect(_.asAscii).join };
                pos = lenAt[1] + lenAt[0];
                running = nil;
            }
            { (status == 0xF0) or: { status == 0xF7 } } {
                lenAt = this.prVlqAt(b, pos + 1, end);
                if(lenAt.isNil or: { (lenAt[1] + lenAt[0]) > end }) { ^"a broken sysex at byte " ++ pos };
                ev = (tick: tick, delta: d[0], sysex: b.copyRange(lenAt[1], (lenAt[1] + lenAt[0]) - 1));
                pos = lenAt[1] + lenAt[0];
                running = nil;
            } {
                // A channel message, with its own status byte or the last
                // one's (running status, which *bytes never writes).
                if(status < 0x80) {
                    if(running.isNil) { ^"a data byte with no status at byte " ++ pos };
                    status = running;
                } {
                    pos = pos + 1;
                    running = status;
                };
                need = if(#[0xC0, 0xD0].includes(status.bitAnd(0xF0))) { 1 } { 2 };
                if((pos + need) > end) { ^"a cut-off message at byte " ++ start };
                ev = (tick: tick, delta: d[0], status: status.bitAnd(0xF0), chan: status.bitAnd(0x0F),
                    data: b.copyRange(pos, (pos + need) - 1));
                if(#[0x80, 0x90].includes(ev[\status])) { ev[\note] = ev[\data][0]; ev[\vel] = ev[\data][1] };
                pos = pos + need;
            };
            ev[\bytes] = b.copyRange(start, pos - 1);
            events.add(ev);
        };
        if(events.isEmpty or: { events.last[\meta] != 0x2F }) { ^"it does not end with End of Track" };
        ^events.asArray
    }

    // [value, the position after it], or nil past `end` or past four bytes.
    *prVlqAt { |b, at, end|
        var v = 0, n = 0, done = false, p = at;
        while { done.not and: { p < end } and: { n < 4 } } {
            v = (v << 7) + b[p].bitAnd(0x7F);
            done = b[p] < 0x80;
            p = p + 1;
            n = n + 1;
        };
        ^if(done) { [v, p] } { nil }
    }

    *prStr4 { |b, at| ^if((at + 4) > b.size) { "" } { b.copyRange(at, at + 3).collect(_.asAscii).join } }
    *prU16At { |b, at| ^(b[at] << 8) + b[at + 1] }
    *prU32At { |b, at| ^(((b[at] << 24) + (b[at + 1] << 16)) + (b[at + 2] << 8)) + b[at + 3] }

    // ---- helpers ----------------------------------------------------------------

    // `list` ordered by each element's `key` (an index or a Symbol), ties in
    // the order given. Answered as it is when it is already in order, which is
    // the case for everything the recorder hands over: a sort of tens of
    // thousands of notes is a quarter of a second of the language, and the
    // drums are still playing then.
    *sortedBy { |list, key|
        var sorted = true, i = 1;
        while { sorted and: { i < list.size } } {
            if(list[i - 1][key] > list[i][key]) { sorted = false };
            i = i + 1;
        };
        if(sorted) { ^list };
        ^list.collect { |x, j| [x, j] }.sort { |a, b|
            if(a[0][key] != b[0][key]) { a[0][key] < b[0][key] } { a[1] <= b[1] }
        }.collect { |p| p[0] }
    }
}
