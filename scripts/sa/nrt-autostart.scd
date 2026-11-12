// megalooper — Autostart's recorder, heard offline.
//
//     sclang scripts/sa/nrt-autostart.scd
//
// Autostart (Looper.autostart) waits with a recorder of its own
// (LooperSynthDefs.recAutoGraph): the take starts on the sample the analysis
// input's level rises through the start level, once it has stayed under it
// for `quiet` seconds, and its frame 0 is `lead` seconds before that sample.
// This renders the real graph offline (scsynth -N on a far port; megalooper,
// if it runs, is not touched) and reads back what each recorder wrote.
//
// The recorded input is a RAMP, the input's own sample index (k / 2^17, exact
// in a float), so a buffer frame says which input sample it holds: where the
// take begins, to the sample, and that no frame was dropped or doubled.
// The analysis inputs, one per case, the level at -40 dBFS (0.01):
//
//   0 a hum at -70 dBFS, then a note at 0.5 s: starts on it, the lead before it
//   1 loud from the start (a guitar still ringing), 0.15 s under, loud again
//     at 0.45 s (not under long enough), 0.4 s under, a note at 1.0 s: starts
//     at 1.0 s, not before
//   2 a note at -46 dBFS, under the level: nothing written
//   3 the level at -1 dBFS when a note comes at 0.5 s: nothing; set to -40
//     at 0.6 s while that note still rings (as Looper.startLevelDb_ does
//     while it waits): nothing, the quiet is asked for again; the note dies
//     at 0.8 s, and a note at 1.1 s starts it
//   4 case 0 on the stereo def (\looperRecAuto): both channels, the ramp and
//     the note, the lead before it
//
// Exits 0 if every check passed, 1 otherwise.
(
var sr = 48000, dur = 1.5, lead = 0.005, leadFrames = (lead * sr).round.asInteger, scale = 2 ** 17;
var tmp = PathName.tmp +/+ "megalooper-nrt-autostart-" ++ thisProcess.pid;
var osc = tmp +/+ "autostart.osc", wav = tmp +/+ "autostart.wav", src = tmp +/+ "input.wav";
var after = { |i| tmp +/+ "after-" ++ i ++ ".wav" };
var pass = 0, fail = 0, fails = List.new;
var ok = { |label, cond, detail|
    if(cond == true) { pass = pass + 1; ("  ok    " ++ label).postln } {
        fail = fail + 1;
        fails.add(label ++ (detail !? { |d| " — " ++ d } ? ""));
        ("  FAIL  " ++ label ++ (detail !? { |d| " — " ++ d } ? "")).postln;
    };
};
var monoDef = SynthDef(\looperRecAutoMono, LooperSynthDefs.recAutoGraph(true));
var stereoDef = SynthDef(\looperRecAuto, LooperSynthDefs.recAutoGraph(false));
var frames = (dur * sr).asInteger, inChans = 5;
// Deterministic noise in -1..1.
var noise = { |i, c| ((sin((i * 12.9898) + (c * 78.233)) * 43758.5453).frac * 2) - 1 };
var hum = { |i, c| noise.(i, c) * 0.000316 };
// A note from sample `at`: a sine at `amp`, starting at its peak (a step, so
// the level crosses on its first sample), dying away over `decay` seconds.
var note = { |i, at, amp, decay = 1|
    if(i >= at) { cos((i - at) * 2pi * 220 / sr) * amp * (1 - ((i - at) / (sr * decay))).max(0) } { 0 } };
var s = { |t| (t * sr).round.asInteger };
var cases = [
    // [def, analysis channel, the note's sample (nil: none expected), the
    // level it is made with, [[time, level], ...] set while it waits]
    [\looperRecAutoMono, 1, s.(0.5), 0.01],
    [\looperRecAutoMono, 2, s.(1.0), 0.01],
    [\looperRecAutoMono, 3, nil, 0.01],
    [\looperRecAutoMono, 4, s.(1.1), -1.dbamp, [[0.6, 0.01]]],
    [\looperRecAuto, 1, s.(0.5), 0.01]
];
// Case 1's input: ringing, under, ringing, under, a note.
var ringing = { |i|
    case
    { i < s.(0.3) } { sin(i * 2pi * 110 / sr) * 0.2 }
    { i < s.(0.45) } { 0 }
    { i < s.(0.6) } { sin(i * 2pi * 110 / sr) * 0.2 }
    { note.(i, s.(1.0), 0.3) }
};
var input = FloatArray.fill(frames * inChans, { |j|
    var i = j div: inChans, c = j % inChans;
    switch(c,
        0, { i / scale },
        1, { hum.(i, c) + note.(i, s.(0.5), 0.3) },
        2, { hum.(i, c) + ringing.(i) },
        3, { hum.(i, c) + note.(i, s.(0.5), 0.005) },
        4, { hum.(i, c) + note.(i, s.(0.5), 0.3, 0.3) + note.(i, s.(1.1), 0.3) }
    )
});
var score, cmd, said, sf, got;

File.mkdir(tmp);
sf = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(inChans).sampleRate_(sr);
sf.openWrite(src);
sf.writeData(input);
sf.close;

score = [[0.0, [\d_recv, monoDef.asBytes]], [0.0, [\d_recv, stereoDef.asBytes]]]
    ++ cases.collect { |c, i| [0.0, [\b_alloc, i, frames, 2]] }
    ++ cases.collect { |c, i|
        [0.0, [\s_new, c[0], 1000 + i, 1, 0, \bufnum, i, \in, 0, \ana, c[1],
            \startLevel, c[3], \quiet, 0.2, \lead, lead, \tapGainBus, -1, \onsetThreshold, 0.5]] }
    ++ cases.collect { |c, i| (c[4] ? []).collect { |e| [e[0], [\n_set, 1000 + i, \startLevel, e[1]]] } }.flatten(1)
    // Every synth freed before the end (scsynth 3.14.1 can hang in its offline
    // cleanup otherwise), then each buffer written as its recorder left it.
    ++ [[dur - 0.1, [\n_free] ++ cases.collect { |c, i| 1000 + i }]]
    ++ cases.collect { |c, i| [dur - 0.05, [\b_write, i, after.(i), "wav", "float"]] }
    ++ [[dur, [\c_set, 0, 0]]];
Score(score).writeOSCFile(osc);
cmd = "perl -e 'alarm shift; exec @ARGV' 120 " ++ MegaSAPlugins.scsynthPath.shellQuote ++ " -u " ++ (58500 + 200.rand)
    ++ " -N " ++ osc.shellQuote ++ " " ++ src.shellQuote ++ " " ++ wav.shellQuote ++ " " ++ sr
    ++ " WAV float -o 2 -i " ++ inChans ++ " 2>&1";
said = cmd.unixCmdGetStdOut;

// Each buffer, interleaved stereo, or nil.
got = cases.collect { |c, i|
    var f = SoundFile.openRead(after.(i)), d;
    f !? {
        d = FloatArray.newClear(f.numFrames * f.numChannels);
        f.readData(d);
        f.close;
        d
    }
};

"== Autostart's recorder, offline ==".postln;
if(got.any(_.isNil)) {
    ("  FAIL  the render: " ++ said.split($\n).reject(_.isEmpty).keep(-4).join(" | ")).postln;
    fail = fail + 1;
} {
    cases.do { |c, i|
        var d = got[i], n = d.size div: 2;
        var left = { |k| d[k * 2] }, right = { |k| d[(k * 2) + 1] };
        // The first frame written, and the input sample it holds.
        var first = (0 .. n - 1).detect { |k| left.(k) != 0 };
        var held = first !? { |k| (left.(k) * scale).round.asInteger };
        // Where frame 0 sits in the input: the sample before the first held
        // when frame 0 is the one left unwritten.
        var zero = held !? { |h| h - first };
        var name = "case " ++ i ++ " (" ++ c[0] ++ ")";
        if(c[2].isNil) {
            ok.(name ++ ": nothing written", first.isNil,
                first !? { |k| "frame " ++ k ++ " holds input sample " ++ held });
        } {
            ok.(name ++ ": the take starts", first.notNil);
            if(first.notNil) {
                ok.(name ++ ": frame 0 is the lead before the note (" ++ leadFrames ++ " samples, give or take 2)",
                    (zero - (c[2] - leadFrames)).abs <= 2,
                    "frame 0 holds input sample " ++ zero ++ ", the note is at " ++ c[2]
                        ++ ": " ++ (c[2] - zero) ++ " samples before it");
                ok.(name ++ ": frame 0 itself is written", first == 0, "the first frame written is " ++ first);
                // Every frame from the first to the render's end: the next
                // input sample, none dropped or doubled.
                {
                    var last = n - 1, bad;
                    var end = (first .. last).detect { |k| left.(k) == 0 } ? n;
                    bad = (first .. end - 1).detect { |k| (left.(k) * scale).round.asInteger != (zero + k) };
                    ok.(name ++ ": every frame the next input sample, " ++ (end - first) ++ " of them",
                        bad.isNil and: { (end - first) >= (sr * 0.25) },
                        bad !? { |k| "frame " ++ k ++ " holds " ++ (left.(k) * scale).round ++ ", not " ++ (zero + k) });
                    // It records until it is freed (dur - 0.1).
                    ok.(name ++ ": it records until it is freed",
                        ((zero + end) - (s.(dur - 0.1) - leadFrames)).abs <= 128,
                        "the last frame written holds input sample " ++ (zero + end - 1));
                }.value;
                if(c[0] == \looperRecAuto) {
                    // The right channel: the analysis channel 1, the note,
                    // delayed as the left.
                    ok.(name ++ ": the right channel is input 1 at the same lead",
                        (0 .. sr div: 10).every { |k|
                            (right.(first + k) - input[((zero + first + k) * inChans) + 1]).abs < 1e-6 });
                };
            };
        };
    };
};
("== " ++ pass ++ " passed, " ++ fail ++ " failed ==").postln;
fails.do { |f| ("   " ++ f).postln };
([osc, wav, src] ++ cases.collect { |c, i| after.(i) }).do { |f| if(File.exists(f)) { File.delete(f) } };
File.delete(tmp);
if(fail == 0) { "NRT AUTOSTART OK".postln; 0.exit } { "NRT AUTOSTART FAILED".postln; 1.exit };
)
