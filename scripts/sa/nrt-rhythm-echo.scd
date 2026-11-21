// megalooper — the Rhythm Echo (MegaSAFx.rhythmEcho; docs/dev/rhythm-echo.md,
// roadmap item 23 idea 4), heard offline, its buffers given by hand as
// MegaSA gives them.
//
//     sclang scripts/sa/nrt-rhythm-echo.scd
//
// A loop of 2 s with onsets at 0, 0.5, 0.75 and 1.5 s, as loud as 1, 0.5,
// 0.8 and 0.6. Its IR: taps at the onsets after the first, timed from it,
// moved MegaSAFx.rhythmEchoLatency frames earlier for PartConv's own delay.
//
//   fromNote   Mode From the note, a click at 0.3 s: echoes at 0.8, 1.05,
//              1.8 s, as loud as their onsets
//   fromNote2  ...Repeats 2, Decay -6 dB: again a loop later, at half
//   noLoop     no loop (loopDur 0): the click alone
//   grid       Mode On the grid, a note at 0.3 s, the playhead moving from
//              the loop's start: the note again at 0.5, 0.75, 1.5 and 2.0 s
//              (the loop's onsets after it, one loop's worth), then not
//   grid2      ...Repeats 2: on the next loop's too, at -6 dB
//
// One render (scsynth -N on a far port); exits 0 if every check passed.
(
var sr = 48000, dur = 4.4, loopSecs = 2, fft = MegaSAFx.rhythmEchoFft;
var tmp = PathName.tmp +/+ "megalooper-nrt-recho-" ++ thisProcess.pid;
var osc = tmp +/+ "re.osc", wav = tmp +/+ "re.wav", clickPath = tmp +/+ "click.wav", notePath = tmp +/+ "note.wav",
    irPath = tmp +/+ "ir.wav";
var pass = 0, fail = 0, fails = List.new;
var ok = { |label, cond, detail|
    if(cond == true) { pass = pass + 1; ("  ok    " ++ label).postln } {
        fail = fail + 1;
        fails.add(label ++ (detail !? { |d| " — " ++ d } ? ""));
        ("  FAIL  " ++ label ++ (detail !? { |d| " — " ++ d } ? "")).postln;
    };
};
var onsets = [0, 0.5, 0.75, 1.5], gains = [1, 0.5, 0.8, 0.6];
var slots = LooperSynthDefs.groupSlots, irFrames = (MegaSAFx.rhythmEchoMaxLoop * sr).asInteger;
var partSize = fft * (irFrames / (fft / 2)).roundUp.asInteger;
var def = SynthDef(\nrtRecho, { |out, in| Out.ar(out, MegaSAFx.rhythmEcho(PlayBuf.ar(2, in))) });
var phaseDef = SynthDef(\nrtRechoPhase, { |out| Out.kr(out, Sweep.kr(0, 1).mod(loopSecs)) });
var common = [\onsetsBuf, 1, \gainsBuf, 2, \irBuf, 4, \loopDur, loopSecs, \onsetCount, onsets.size, \patternDur, loopSecs,
    \perPattern, onsets.size, \phaseBus, 50,
    \rhythmEchoLevel, 0, \rhythmEchoTone, 20000];
// [label, input buffer, args]
var cases = [
    [\fromNote, 0, [\rhythmEchoMode, 0]],
    [\fromNote2, 0, [\rhythmEchoMode, 0, \rhythmEchoRepeats, 2, \rhythmEchoDecay, -6]],
    [\noLoop, 0, [\rhythmEchoMode, 0, \loopDur, 0]],
    [\grid, 5, [\rhythmEchoMode, 1]],
    [\grid2, 5, [\rhythmEchoMode, 1, \rhythmEchoRepeats, 2, \rhythmEchoDecay, -6]]
];
var chans = cases.size * 2, score, said, sf, data, n, chan, idx, x, peaksNear, energy, ir, write;

File.mkdir(tmp);
write = { |path, chs, f|
    var s = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(chs).sampleRate_(sr);
    s.openWrite(path); s.writeData(f); s.close;
};
// A click of 0.5 at 0.3 s, both sides; and a note: 50 ms of 440 Hz at 0.5
// from 0.3 s, then silence.
write.(clickPath, 2, FloatArray.fill((dur * sr).asInteger * 2, { |j| if((j div: 2) == (0.3 * sr).asInteger) { 0.5 } { 0 } }));
write.(notePath, 2, FloatArray.fill((dur * sr).asInteger * 2, { |j|
    var i = j div: 2, t = (i / sr) - 0.3;
    if((t >= 0) and: { t < 0.05 }) { sin(2pi * 440 * t) * 0.5 } { 0 } }));
// The IR as MegaSA writes it.
ir = FloatArray.newClear(irFrames);
onsets.do { |o, i| var at = ((o - onsets[0]) * sr).round.asInteger - MegaSAFx.rhythmEchoLatency;
    if((i > 0) and: { at >= 0 } and: { at < irFrames }) { ir[at] = gains[i] } };
write.(irPath, 1, ir);

score = [
    [0.0, [\d_recv, def.asBytes]], [0.0, [\d_recv, phaseDef.asBytes]],
    [0.0, [\b_allocRead, 0, clickPath]], [0.0, [\b_allocRead, 5, notePath]],
    [0.0, [\b_alloc, 1, slots, 1]], [0.0, [\b_setn, 1, 0, slots] ++ onsets ++ (1e9 ! (slots - onsets.size))],
    [0.0, [\b_alloc, 2, slots, 1]], [0.0, [\b_setn, 2, 0, slots] ++ gains ++ (0 ! (slots - gains.size))],
    [0.0, [\b_allocRead, 3, irPath]],
    [0.0, [\b_alloc, 4, partSize, 1]], [0.0, [\b_gen, 4, "PreparePartConv", 3, fft]],
    [0.0, [\s_new, \nrtRechoPhase, 900, 0, 0, \out, 50]]
];
cases.do { |c, i|
    score = score.add([0.0, [\s_new, \nrtRecho, 1000 + i, 1, 0, \out, i * 2, \in, c[1]] ++ (common ++ c[2]).asOSCArgArray]);
};
score = score ++ [[dur - 0.01, [\n_free, 900] ++ cases.collect { |c, i| 1000 + i }], [dur, [\c_set, 0, 0]]];
Score(score).writeOSCFile(osc);
said = ("perl -e 'alarm shift; exec @ARGV' 300 " ++ MegaSAPlugins.scsynthPath.shellQuote ++ " -u " ++ (58500 + 200.rand)
    ++ " -m 262144 -N " ++ osc.shellQuote ++ " _ " ++ wav.shellQuote ++ " " ++ sr ++ " WAV float -o " ++ chans
    ++ " -i 0 2>&1").unixCmdGetStdOut;
sf = SoundFile.openRead(wav);
if(sf.isNil) {
    ("  FAIL  the render: " ++ said.split($\n).reject(_.isEmpty).keep(-4).join(" | ")).postln;
    "NRT RHYTHM ECHO FAILED — no render".postln;
    1.exit;
} {
    data = FloatArray.newClear(sf.numFrames * chans);
    sf.readData(data);
    sf.close;
    n = sf.numFrames;
    idx = { |label| cases.detectIndex { |c| c[0] == label } };
    chan = { |label, side = 0| var c = idx.(label); Array.fill(n, { |f| data[(f * chans) + (c * 2) + side] }) };
    // The largest |x| within 3 ms of each time, and where it is (seconds).
    peaksNear = { |xs, times|
        times.collect { |t| var a = ((t - 0.003) * sr).asInteger, b = ((t + 0.003) * sr).asInteger;
            var seg = xs.copyRange(a, b), m = seg.abs.maxIndex; [(a + m) / sr, seg[m].abs] }
    };
    // The RMS over 40 ms from a time.
    energy = { |xs, t| var seg = xs.copyRange((t * sr).asInteger, ((t + 0.04) * sr).asInteger); (seg.squared.sum / seg.size).sqrt };
    "== the Rhythm Echo, offline ==".postln;
    ok.("every render is finite", data.every { |v| v.isNaN.not and: { v.abs < inf } });
    x = peaksNear.(chan.(\fromNote), [0.8, 1.05, 1.8]);
    ok.("From the note: echoes where the riff's onsets fall after the click (0.8, 1.05, 1.8 s, to a sample)",
        x.every { |p, i| (p[0] - [0.8, 1.05, 1.8][i]).abs <= (1.5 / sr) }, x.collect(_[0]).round(0.00001).asString);
    ok.("...as loud as their onsets (0.25, 0.4, 0.3 of the click's 0.5)",
        x.every { |p, i| (p[1] - [0.25, 0.4, 0.3][i]).abs < 0.02 }, x.collect(_[1]).round(0.001).asString);
    ok.("...and nothing a loop later with one repeat", chan.(\fromNote).copyRange((2.6 * sr).asInteger, (4.0 * sr).asInteger).abs.maxItem < 0.01);
    x = peaksNear.(chan.(\fromNote2), [2.8, 3.05, 3.8]);
    ok.("Repeats 2, Decay -6 dB: the same again a loop later, at half",
        x.every { |p, i| ((p[0] - [2.8, 3.05, 3.8][i]).abs <= (1.5 / sr)) and: { (p[1] - ([0.25, 0.4, 0.3][i] * 0.5)).abs < 0.02 } },
        x.round(0.0001).asString);
    ok.("no loop: the click alone, no echo", chan.(\noLoop).copyRange((0.5 * sr).asInteger, (4.0 * sr).asInteger).abs.maxItem < 1e-4);
    ok.("...the click passes as it came", (chan.(\noLoop)[(0.3 * sr).asInteger] - 0.5).abs < 1e-6);
    // On the grid: the note again on the onsets after it, one loop's worth.
    x = [0.5, 0.75, 1.5, 2.0].collect { |t| energy.(chan.(\grid), t) };
    ok.("On the grid: the note again on the loop's onsets after it (0.5, 0.75, 1.5, 2.0 s)",
        x.every { |e| e > 0.05 }, x.round(0.001).asString);
    ok.("...and not before the note, nor on the next loop's with one repeat",
        [0.0, 2.5, 2.75, 3.5].every { |t| energy.(chan.(\grid), t) < 0.005 },
        [0.0, 2.5, 2.75, 3.5].collect { |t| energy.(chan.(\grid), t) }.round(0.0001).asString);
    x = [2.5, 2.75, 3.5].collect { |t| energy.(chan.(\grid2), t) / energy.(chan.(\grid2), t - 2) };
    ok.("Repeats 2: the next loop's too, at -6 dB", x.every { |r| (r - 0.5).abs < 0.06 }, x.round(0.01).asString);
    // Where the note's attack lands against each onset, ms: the repeat starts
    // 10 ms before where the note was heard, and Onsets hears it a few ms in.
    x = [0.5, 0.75, 1.5, 2.0].collect { |t| var xs = chan.(\grid), a = (t * sr).asInteger;
        var first = (a - 960 .. a + 960).detect { |f| xs[f].abs > 0.01 }; first !? { |f| ((f / sr) - t) * 1000 } };
    // Started 5 ms early: this note, heard 2.6 ms in, lands 2.4 ms late.
    ok.("...each repeat's attack within 6 ms of its onset (Onsets hears a note 0 to 11 ms in; a repeat starts 5 ms early)",
        x.every { |ms| ms.notNil and: { ms.abs <= 6 } }, x.collect { |v| v !? { v.round(0.1) } }.asString ++ " ms");
    ok.("both sides the same echo", cases.every { |c, i| var l = chan.(c[0], 0), r = chan.(c[0], 1);
        l.every { |v, f| (v - r[f]).abs < 1e-6 } });
    [osc, wav, clickPath, notePath, irPath].do { |f| if(File.exists(f)) { File.delete(f) } };
    File.delete(tmp);
    "".postln;
    if(fail == 0) { ("NRT RHYTHM ECHO PASSED — " ++ pass ++ " checks").postln; 0.exit } {
        ("NRT RHYTHM ECHO FAILED — " ++ fail ++ " of " ++ (pass + fail)).postln;
        fails.do { |f| ("  " ++ f).postln };
        1.exit;
    };
};
)
