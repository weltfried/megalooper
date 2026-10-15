// The set's MIDI file: the bytes, and where every note lands.
//
// The .mid a recorded set leaves (LooperSessionRecorder.midiTracks, written by
// LooperMidiFile) is only worth having if two things hold. Its bytes must be a
// file every DAW reads the same way, which is checked here byte for byte on a
// file small enough to write out by hand. And with Live at the tempo the file
// name gives, every note must play at the second its hit was heard in the
// recorded WAVs, at minute twenty as at minute one: so the ticks are computed
// at exactly that rounded tempo, from frame 0 of the WAVs, and that is pinned
// with a hit twenty minutes in.
//
// Nothing here needs a server or a file except the write and read at the end.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-session-midi");

{
var m = LooperMidiFile;
var dir = ~tTempPath.("megalooper-midi-tests");
// Bytes as 0..255, whatever they came as (Int8Array holds them signed).
var u8 = { |bytes| bytes.asArray.collect { |b| b.asInteger.bitAnd(255) } };
// The note events of a parsed track as [tick, status|chan, note, vel].
var notesOf = { |track| track.select { |e| e[\note].notNil }.collect { |e|
    [e[\tick], e[\status].bitOr(e[\chan]), e[\note], e[\vel]] } };
var tempo = (bpm: 165.0412, numerator: 7, denominator: 8);
var frame0 = 1000.0;
var built, back, tracks, bytes, want, hits, onsetTrack, stepsTrack, conductor, path, paced, r, n;

if(File.exists(dir).not) { File.mkdir(dir) };

// ---- variable-length quantities -----------------------------------------------
// Every delta time in the file is one. The edges are where a hand-rolled
// encoder goes wrong: the last value of each byte count and the first of the
// next.
~tEq.("0 is one byte", m.vlq(0), [0x00]);
~tEq.("127 is the largest one-byte value", m.vlq(127), [0x7F]);
~tEq.("128 takes two bytes: 81 00", m.vlq(128), [0x81, 0x00]);
~tEq.("0x3FFF is the largest two-byte value: FF 7F", m.vlq(0x3FFF), [0xFF, 0x7F]);
~tEq.("0x4000 takes three: 81 80 00", m.vlq(0x4000), [0x81, 0x80, 0x00]);
~tEq.("0x0FFFFFFF is the largest the format allows: FF FF FF 7F", m.vlq(0x0FFFFFFF), [0xFF, 0xFF, 0xFF, 0x7F]);
~tEq.("past it is held there rather than written as five bytes", m.vlq(0x10000000), [0xFF, 0xFF, 0xFF, 0x7F]);
~tEq.("a negative delta is written as 0", m.vlq(-3), [0x00]);

// ---- the events ---------------------------------------------------------------
~tEq.("a tempo is microseconds per quarter, three bytes: 120 BPM is 07 A1 20",
    m.tempo(120), [0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20]);
~tEq.("165.04 BPM is 363548 µs, 05 8C 1C", [m.usPerQuarter(165.04), m.tempo(165.04)],
    [363548, [0xFF, 0x51, 0x03, 0x05, 0x8C, 0x1C]]);
~tEq.("7/8: numerator, log2 of the denominator, 24 clocks a click, 8 32nds a quarter",
    m.timeSignature(7, 8), [0xFF, 0x58, 0x04, 0x07, 0x03, 0x18, 0x08]);
~tEq.("4/4 and 5/16", [m.timeSignature(4, 4), m.timeSignature(5, 16)],
    [[0xFF, 0x58, 0x04, 0x04, 0x02, 0x18, 0x08], [0xFF, 0x58, 0x04, 0x05, 0x04, 0x18, 0x08]]);
~tEq.("a marker is FF 06, its length, its text", m.marker("break"),
    [0xFF, 0x06, 0x05, 0x62, 0x72, 0x65, 0x61, 0x6B]);
~tEq.("a track name is FF 03", m.trackName("Onset notes"),
    [0xFF, 0x03, 0x0B] ++ "Onset notes".ascii);
~tEq.("a text of 200 bytes has a two-byte length", m.marker("x".dup(200).join).copyRange(0, 3),
    [0xFF, 0x06, 0x81, 0x48]);
~tEq.("End of Track", m.endOfTrack, [0xFF, 0x2F, 0x00]);
~tEq.("a note-on carries its channel, 0-based, in the status byte", m.noteOn(1, 36, 100), [0x91, 36, 100]);
~tEq.("a note-off likewise, with velocity 0", m.noteOff(4, 38), [0x84, 38, 0]);

// ---- a known tiny file, byte for byte -----------------------------------------
// A conductor (name, 120 BPM, 4/4) and one note a 16th long, both tracks ended
// at 480 ticks: small enough to write out by hand.
tracks = [
    [[0, m.trackName("t")], [0, m.tempo(120)], [0, m.timeSignature(4, 4)]],
    [[0, m.trackName("n")], [0, m.noteOn(1, 36, 100)], [120, m.noteOff(1, 36)]]
];
bytes = m.bytes(tracks, 480, 480);
want = [
    0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 1, 0, 2, 0x01, 0xE0,      // MThd, format 1, 2 tracks, 480
    0x4D, 0x54, 0x72, 0x6B, 0, 0, 0, 0x19,                           // MTrk, 25 bytes
        0x00, 0xFF, 0x03, 0x01, 0x74,
        0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20,
        0x00, 0xFF, 0x58, 0x04, 0x04, 0x02, 0x18, 0x08,
        0x83, 0x60, 0xFF, 0x2F, 0x00,                                // 480 ticks on: 83 60
    0x4D, 0x54, 0x72, 0x6B, 0, 0, 0, 0x12,                           // MTrk, 18 bytes
        0x00, 0xFF, 0x03, 0x01, 0x6E,
        0x00, 0x91, 0x24, 0x64,
        0x78, 0x81, 0x24, 0x00,                                      // 120 ticks: 78
        0x82, 0x68, 0xFF, 0x2F, 0x00                                 // 360 more: 82 68
];
~tEq.("the tiny file, byte for byte", u8.(bytes), want);
~tEq.("...as signed bytes, which File:write puts on disk unchanged", bytes.class, Int8Array);
~tEq.("a track's events are put in tick order, ties as given",
    u8.(m.track([[10, [0x91, 1, 1]], [0, [0x91, 2, 2]], [10, [0x81, 1, 0]]], nil)).copyRange(8, 20),
    [0x00, 0x91, 2, 2, 0x0A, 0x91, 1, 1, 0x00, 0x81, 1, 0, 0x00]);

// ---- reading it back ------------------------------------------------------------
back = m.parse(bytes);
~tEq.("it parses: format 1, 480 ticks a quarter, two tracks",
    [back[\error], back[\format], back[\division], back[\tracks].size], [nil, 1, 480, 2]);
back[\tracks] !? { |trs|
    ~tEq.("the conductor's events at their ticks", trs[0].collect { |e| [e[\tick], e[\meta]] },
        [[0, 0x03], [0, 0x51], [0, 0x58], [480, 0x2F]]);
    ~tEq.("...with its name as text", trs[0][0][\text], "t");
    ~tEq.("the note track: the note-on, its note-off a 16th later", notesOf.(trs[1]),
        [[0, 0x91, 36, 100], [120, 0x81, 36, 0]]);
    ~tEq.("every event's bytes come back as written", trs[1][1][\bytes], [0x91, 0x24, 0x64]);
};
{
    // A hand-made track with running status: on, then a second note on the
    // same status with no status byte of its own.
    var body = [0x00, 0x91, 0x24, 0x64, 0x78, 0x26, 0x50, 0x00, 0xFF, 0x2F, 0x00];
    var file = u8.(bytes).copyRange(0, 13).put(11, 1)
        ++ [0x4D, 0x54, 0x72, 0x6B] ++ m.u32(body.size) ++ body;
    var p = m.parse(file);
    ~tEq.("a track with running status reads as two notes", p[\tracks] !? { |t| notesOf.(t[0]) },
        [[0, 0x91, 36, 100], [120, 0x91, 38, 80]]);
}.value;
~tAssert.("garbage is an error, not a throw", m.parse([1, 2, 3])[\error].notNil);
~tAssert.("a file cut short is an error", m.parse(u8.(bytes).copyRange(0, 40))[\error].notNil);
~tAssert.("a track without End of Track is an error",
    m.parse(u8.(bytes).copyRange(0, 13).put(11, 1) ++ [0x4D, 0x54, 0x72, 0x6B, 0, 0, 0, 4, 0x00, 0x91, 0x24, 0x64])[\error].notNil);

// ---- ticks: at the rounded tempo, from frame 0 ----------------------------------
// The file's tempo is the set's at Live's 0.01 BPM, and the ticks are computed
// at exactly that tempo: with Live at 165.04 a note plays at the second it was
// heard. Ticks at the unrounded 165.0412 would put a hit twenty minutes in 12
// ticks (9 ms) late in Live, and the error would grow with the set.
~tEq.("ten seconds at 120 BPM is 9600 ticks", m.tickAt(10, 120), 9600);
~tEq.("twenty minutes at 165.04 is 1584384 ticks, exactly", m.tickAt(1200, 165.04), 1584384);
~tEq.("...and at 165.0412 it would have been 1584396", m.tickAt(1200, 165.0412), 1584396);
hits = [
    (at: frame0 + 1200.0, slot: \steps, kind: \step, note: 36, vel: 100, lane: 0, which: \main),
    (at: frame0 + 0.5, slot: \steps, kind: \step, note: 36, vel: 90, lane: 0, which: \main)
];
built = LooperSessionRecorder.midiTracks("261007_143012", tempo, frame0, hits, [], frame0 + 1201);
~tEq.("the set's file is at the tempo rounded to 0.01 BPM", built[\bpm], 165.04);
~tEq.("...and says so: 363548 µs a quarter", built[\tracks][0][1][1], m.tempo(165.04));
~tEq.("a hit twenty minutes after frame 0 lands on tick 1584384",
    built[\tracks][1].select { |e| e[1][0] == 0x91 }.collect(_[0]), [m.tickAt(0.5, 165.04), 1584384]);
~tEq.("...in tick order though it was handed over last", built[\tracks][1][1][0], 660);
~tEq.("every track ends at the set's end", built[\endTick], m.tickAt(1201, 165.04));
{
    // The twenty-minute note-on as the file holds it, back in seconds. At the
    // tempo the file's NAME gives (Live set to it by hand) it is the hit's
    // second, within half a tick. The FF 51 event can only say whole
    // microseconds, 363548 for 363548.23, so a DAW that takes its tempo from
    // the file hears it 0.76 ms early here, about a tick, and more as a set
    // goes on: within a millisecond is all that reading can promise.
    var nameBpm = LooperSessionRecorder.parseName(LooperSessionRecorder.nameFor("261007_143012", tempo, "drums", "mid"))
        !? { |p| p[\bpm] };
    var tick = built[\tracks][1].select { |e| e[1][0] == 0x91 }.collect(_[0]).maxItem;
    var us = built[\tracks][0].detect { |e| (e[1][0] == 0xFF) and: { e[1][1] == 0x51 } }
        !? { |e| ((e[1][3] << 16) + (e[1][4] << 8)) + e[1][5] };
    ~tNear.("the twenty-minute note-on, read back at the file name's tempo, is the hit's second, within half a tick",
        tick !? { |t| nameBpm !? { |b| (t / m.division) * (60 / b) } }, 1200.0, (0.5 / m.division) * (60 / 165.04));
    ~tNear.("...and at the tempo the file's FF 51 event states, within a millisecond: whole microseconds drift",
        tick !? { |t| us !? { |u| (t / m.division) * (u / 1e6) } }, 1200.0, 0.001);
}.value;

// ---- the conductor -------------------------------------------------------------
built = LooperSessionRecorder.midiTracks("261007_143012", tempo, frame0, [],
    [(at: frame0 + 2.0, text: "break"), (at: frame0 - 3.0, text: "drums start 7/8 165.04 BPM"),
        (at: frame0 + 4.0, text: "back")], frame0 + 10);
conductor = built[\tracks][0];
~tEq.("the conductor: the set's name, the tempo, the signature, then the markers",
    conductor.collect { |e| e[1][1] }, [0x03, 0x51, 0x58, 0x06, 0x06, 0x06]);
~tEq.("...named for the set", conductor[0][1], m.trackName("megalooper 261007_143012"));
~tEq.("...in 7/8", conductor[2][1], m.timeSignature(7, 8));
~tEq.("markers in time order; one before frame 0 sits at tick 0",
    conductor.copyToEnd(3).collect { |e| [e[0], e[1].copyToEnd(3).collect(_.asAscii).join] },
    [[0, "drums start 7/8 165.04 BPM"], [m.tickAt(2.0, 165.04), "break"], [m.tickAt(4.0, 165.04), "back"]]);
~tEq.("the note tracks are named and empty with no hits",
    [built[\tracks][1], built[\tracks][2]].collect { |t| t.collect { |e| e[1][1] } }, [[0x03], [0x03]]);

// ---- the Rhythmic Steps track: channels, lengths ------------------------------
// As the Live device sent them: lane 0 on MIDI channel 2 … lane 3 on channel 5
// (bytes 1..4). A note is a 16th (120 ticks) long, or ends a tick before the
// same note on the same channel comes again.
hits = [
    (at: frame0 + 1.0, kind: \step, note: 36, vel: 100, lane: 0),
    (at: frame0 + 1.0, kind: \step, note: 36, vel: 100, lane: 1),
    (at: frame0 + 1.0, kind: \step, note: 42, vel: 100, lane: 2),
    (at: frame0 + 1.0, kind: \roll, note: 42, vel: 70, lane: 3),
    (at: frame0 + 1.05, kind: \roll, note: 36, vel: 60, lane: 0),
    (at: frame0 + 1.05, kind: \step, note: 38, vel: 0, lane: 0),
    (at: frame0 + 1.05, kind: \repeat, note: 37, vel: 100, lane: 0),
    (at: frame0 + 1.10, kind: \step, note: 40, vel: 300, lane: 1)
];
built = LooperSessionRecorder.midiTracks("s", (bpm: 120, numerator: 4, denominator: 4), frame0, hits, [], frame0 + 2);
stepsTrack = built[\tracks][1];
n = m.tickAt(1.0, 120);
~tEq.("lanes 0..3 on channels 2..5: status bytes 91..94, a roll on its lane's channel",
    stepsTrack.select { |e| (e[0] == n) and: { e[1][0].bitAnd(0xF0) == 0x90 } }.collect { |e| e[1][0] },
    [0x91, 0x92, 0x93, 0x94]);
~tEq.("a note a 16th long when nothing comes after it",
    stepsTrack.detect { |e| e[1] == m.noteOff(2, 36) } !? { |e| e[0] - n }, 120);
~tEq.("the same note on the same channel 50 ms later ends it a tick before",
    stepsTrack.detect { |e| (e[1] == m.noteOff(1, 36)) and: { e[0] < (n + 120) } } !? { |e| e[0] },
    m.tickAt(1.05, 120) - 1);
~tEq.("...and its own note-on follows, ending a 16th on",
    stepsTrack.select { |e| e[1] == m.noteOff(1, 36) }.collect(_[0]), [m.tickAt(1.05, 120) - 1, m.tickAt(1.05, 120) + 120]);
~tEq.("the same note on another channel is not cut",
    stepsTrack.detect { |e| e[1] == m.noteOff(2, 36) } !? { |e| e[0] }, n + 120);
~tEq.("Beat Repeat's repeats are never notes", stepsTrack.any { |e| e[1][1] == 37 }, false);
~tEq.("velocities are held to 1..127",
    stepsTrack.select { |e| e[1][0].bitAnd(0xF0) == 0x90 }.collect { |e| [e[1][1], e[1][2]] }.select { |p| #[38, 40].includes(p[0]) },
    [[38, 1], [40, 127]]);
~tEq.("the steps and onsets counted", [built[\steps], built[\onsets]], [7, 0]);
~tEq.("a note-off never falls after the next note-on of its key",
    {
        var open = Dictionary.new, bad = 0;
        stepsTrack.do { |e|
            var key = (e[1][0].bitAnd(15) * 128) + e[1][1];
            if(e[1][0].bitAnd(0xF0) == 0x90) {
                if(open[key] == true) { bad = bad + 1 };
                open.put(key, true);
            };
            if(e[1][0].bitAnd(0xF0) == 0x80) { open.put(key, false) };
        };
        bad
    }.value, 0);

// ---- the Onset notes track: channel 2, the gate -------------------------------
hits = [
    (at: frame0 + 1.0, slot: \onset, kind: \onset, note: 36, vel: 80, gate: 0.02),
    (at: frame0 + 2.0, slot: \onset, kind: \onset, note: 36, vel: 80, gate: 0.0001),
    (at: frame0 + 3.0, slot: \onset, kind: \onset, note: 36, vel: 80),
    (at: frame0 + 4.0, slot: \onset, kind: \onset, note: 36, vel: 80, gate: 60)
];
built = LooperSessionRecorder.midiTracks("s", (bpm: 120, numerator: 4, denominator: 4), frame0, hits, [], frame0 + 5);
onsetTrack = built[\tracks][2];
~tEq.("onset notes on MIDI channel 2 (byte 1), on their own track",
    onsetTrack.select { |e| e[1][0].bitAnd(0xF0) == 0x90 }.collect { |e| e[1][0] }.asSet.asArray, [0x91]);
// The gate in ms is 60, not the default's 20, so read as such it cannot pass
// for the default.
~tEq.("each as long as its gate: 20 ms at 120 BPM is 19 ticks; at least one; the default 20 ms; a gate in ms read as such (60 ms, 58 ticks)",
    onsetTrack.select { |e| e[1][0] == 0x81 }.collect(_[0])
        - onsetTrack.select { |e| e[1][0] == 0x91 }.collect(_[0]),
    [19, 1, 19, 58]);
~tEq.("nothing of the onset part is on the steps track", built[\tracks][1].size, 1);

// ---- hits before frame 0 --------------------------------------------------------
built = LooperSessionRecorder.midiTracks("s", (bpm: 120, numerator: 4, denominator: 4), frame0,
    [(at: frame0 - 0.01, kind: \step, note: 36, vel: 100, lane: 0),
        (at: frame0, kind: \step, note: 36, vel: 100, lane: 0)], [], frame0 + 1);
~tEq.("a hit before frame 0 is left out and counted; one on it is tick 0",
    [built[\early], built[\tracks][1].select { |e| e[1][0] == 0x91 }.collect(_[0])], [1, [0]]);

// ---- pacing --------------------------------------------------------------------
// A long set is tens of thousands of notes, built while the drums may still
// be playing: the builder lets a caller in a Routine breathe every few hundred.
paced = 0;
hits = Array.fill(1200, { |i| (at: frame0 + (i * 0.125), kind: \step, note: 36 + (i % 4), vel: 100, lane: i % 4) });
built = LooperSessionRecorder.midiTracks("s", (bpm: 120, numerator: 4, denominator: 4), frame0, hits, [], frame0 + 151,
    { paced = paced + 1 });
~tEq.("1200 notes, all there", built[\steps], 1200);
~tAssert.("...and the pace was called along the way", paced >= 4, "called " ++ paced ++ " times");
r = Routine { LooperSessionRecorder.midiTracks("s", (bpm: 120, numerator: 4, denominator: 4), frame0, hits, [],
    frame0 + 151, { LooperSessionRecorder.prBreathe }) };
~tAssert.("in a Routine it yields rather than running to the end in one go", r.next.isNumber);
n = 0;
while { r.next.notNil and: { n < 1000 } } { n = n + 1 };
~tAssert.("...and finishes", n < 1000, "still running after 1000 steps");

// ---- writing and reading a file ----------------------------------------------------
// A set-sized file through the real writer, read back by the real parser.
hits = [
    (at: frame0 + 0.5, slot: \steps, kind: \step, note: 36, vel: 110, lane: 0, which: \main),
    (at: frame0 + 0.5, slot: \steps, kind: \step, note: 42, vel: 64, lane: 2, which: \main),
    (at: frame0 + 0.6, slot: \steps, kind: \roll, note: 42, vel: 50, lane: 2, which: \main),
    (at: frame0 + 0.75, slot: \steps, kind: \step, note: 38, vel: 96, lane: 1, which: \break),
    (at: frame0 + 0.8, slot: \steps, kind: \repeat, note: 37, vel: 100, lane: 3, which: \main),
    (at: frame0 + 1.0, slot: \onset, kind: \onset, note: 36, vel: 70, gate: 0.02)
];
built = LooperSessionRecorder.midiTracks("261007_143012", tempo, frame0, hits,
    [(at: frame0 + 0.5, text: "drums start 7/8 165.04 BPM"), (at: frame0 + 0.7, text: "break")], frame0 + 2);
path = dir +/+ "261007_143012-165.04bpm-7-8-drums.mid";
~tEq.("the file is written", m.write(path, built[\tracks], nil, built[\endTick]), true);
back = m.read(path);
~tEq.("...and reads back: format 1, 480, three tracks", [back[\error], back[\format], back[\division],
    back[\tracks] !? (_.size)], [nil, 1, 480, 3]);
back[\tracks] !? { |trs|
    ~tEq.("the track names", trs.collect { |t| t[0][\text] },
        ["megalooper 261007_143012", "Rhythmic Steps", "Onset notes"]);
    ~tEq.("the tempo, 363548 µs", trs[0].detect { |e| e[\meta] == 0x51 } !? { |e| e[\data] }, [0x05, 0x8C, 0x1C]);
    ~tEq.("the markers", trs[0].select { |e| e[\meta] == 0x06 }.collect { |e| [e[\tick], e[\text]] },
        [[m.tickAt(0.5, 165.04), "drums start 7/8 165.04 BPM"], [m.tickAt(0.7, 165.04), "break"]]);
    ~tEq.("the steps as they were given, without the repeat",
        notesOf.(trs[1]).select { |x| x[1].bitAnd(0xF0) == 0x90 },
        [[m.tickAt(0.5, 165.04), 0x91, 36, 110], [m.tickAt(0.5, 165.04), 0x93, 42, 64],
            [m.tickAt(0.6, 165.04), 0x93, 42, 50], [m.tickAt(0.75, 165.04), 0x92, 38, 96]]);
    ~tEq.("the onset", notesOf.(trs[2]).select { |x| x[1] == 0x91 }, [[m.tickAt(1.0, 165.04), 0x91, 36, 70]]);
    ~tEq.("every track ends at the set's end", trs.collect { |t| t.last[\tick] }.asSet.asArray, [built[\endTick]]);
    ~tEq.("the parse of the file is the parse of the bytes",
        trs.collect { |t| t.collect(_[\bytes]) },
        m.parse(m.bytes(built[\tracks], nil, built[\endTick]))[\tracks].collect { |t| t.collect(_[\bytes]) });
};
~tEq.("a path that cannot be written is false, not a throw",
    m.write(dir +/+ "no-such-folder" +/+ "x.mid", built[\tracks]), false);
~tEq.("a file that is not there reads as an error", m.read(dir +/+ "nope.mid")[\error].notNil, true);

// ---- two hits of one key on one tick ----------------------------------------------
// A step and a roll of lane 0, 0.2 ms apart, are one tick at 120 BPM, so one
// note: at the louder velocity, ended once, a tick before its key comes again.
// Left as two, the second note-on would leave a DAW holding the first, and the
// first's note-off would fall after the key's next note-on and cut that short.
built = LooperSessionRecorder.midiTracks("s", (bpm: 120, numerator: 4, denominator: 4), frame0,
    [(at: frame0 + 1.0, kind: \step, note: 36, vel: 60, lane: 0),
        (at: frame0 + 1.0002, kind: \roll, note: 36, vel: 100, lane: 0),
        (at: frame0 + 1.05, kind: \step, note: 36, vel: 80, lane: 0)], [], frame0 + 2);
~tEq.("two hits of one key on one tick are one note, the louder; its key again ends it a tick before, once",
    built[\tracks][1].select { |e| e[1][1] == 36 }.collect { |e| [e[0], e[1][0], e[1][2]] },
    [[960, 0x91, 100], [1007, 0x81, 0], [1008, 0x91, 80], [1128, 0x81, 0]]);
// On the onset track, three on one tick: as loud as the loudest and as long
// as the longest gate, which here is neither the first nor the last.
built = LooperSessionRecorder.midiTracks("s", (bpm: 120, numerator: 4, denominator: 4), frame0,
    [(at: frame0 + 1.0, slot: \onset, kind: \onset, note: 36, vel: 50, gate: 0.03),
        (at: frame0 + 1.0001, slot: \onset, kind: \onset, note: 36, vel: 90, gate: 0.05),
        (at: frame0 + 1.0002, slot: \onset, kind: \onset, note: 36, vel: 70, gate: 0.02)], [], frame0 + 2);
~tEq.("...on the onset track too: one note, the loudest, as long as the longest gate",
    built[\tracks][2].select { |e| e[1][1] == 36 }.collect { |e| [e[0], e[1][0], e[1][2]] },
    [[960, 0x91, 90], [960 + m.tickAt(0.05, 120), 0x81, 0]]);

~tRemoveTree.(dir);
}.value;
