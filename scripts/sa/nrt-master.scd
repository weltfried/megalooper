// megalooper — the master's safety limiter, heard offline.
//
//     sclang scripts/sa/nrt-master.scd
//
// Megalooper SA's master (MegaSAMixer.masterGraph) limits the mix before its
// clip since 2026-11-12, when a rehearsal distorted: the lanes summed past
// the clip, which was all there was. This renders the real graph offline
// (scsynth -N on a far port; megalooper, if it runs, is not touched):
//
//   A  a mix at -6 dBFS: out as it came in, to the bit (but the first
//      block, which the limiter fades in over when the master is made)
//   B  silence, then a mix 6 dB over full scale for a second, then a quiet
//      one: the clip cuts only the first moment, the rest is turned down
//      under it; the quiet mix is back at its own level soon after
//   C  the left side 6 dB over, the right quiet: both turned down alike, so
//      the image holds
//   and B's two light signals (MegaSAMixer.lightSignals): the limiter's while
//   the mix is over, the clip's only at the start.
//
// Exits 0 if every check passed, 1 otherwise.
(
var sr = 48000, dur = 2.0, frames = (dur * sr).asInteger, inChans = 6, outChans = 8;
var tmp = PathName.tmp +/+ "megalooper-nrt-master-" ++ thisProcess.pid;
var osc = tmp +/+ "master.osc", wav = tmp +/+ "master.wav", src = tmp +/+ "input.wav";
var pass = 0, fail = 0, fails = List.new;
var ok = { |label, cond, detail|
    if(cond == true) { pass = pass + 1; ("  ok    " ++ label).postln } {
        fail = fail + 1;
        fails.add(label ++ (detail !? { |d| " — " ++ d } ? ""));
        ("  FAIL  " ++ label ++ (detail !? { |d| " — " ++ d } ? "")).postln;
    };
};
var masterDef = SynthDef(\megaNrtMaster, MegaSAMixer.masterGraph);
var probeDef = SynthDef(\megaNrtMasterLight, { |in, out|
    var sum = In.ar(in, 2);
    Out.ar(out, MegaSAMixer.lightSignals(sum, MegaSAMixer.safetyLimit(sum)));
});
var s = { |t| (t * sr).round.asInteger };
var noise = { |i, c| ((sin((i * 12.9898) + (c * 78.233)) * 43758.5453).frac * 2) - 1 };
var sine = { |i, f, amp| sin(i * 2pi * f / sr) * amp };
// Case B's mix: silence, 6 dB over, a quiet mix.
var hot = { |i, c| case { i < s.(0.2) } { 0 } { i < s.(1.2) } { sine.(i, 110 + (c * 55), 2.0) } { sine.(i, 220, 0.3) } };
var input = FloatArray.fill(frames * inChans, { |j|
    var i = j div: inChans, c = j % inChans;
    switch(c,
        0, { sine.(i, 220, 0.4) + (noise.(i, 0) * 0.1) },
        1, { sine.(i, 330, 0.4) + (noise.(i, 1) * 0.1) },
        2, { hot.(i, 0) }, 3, { hot.(i, 1) },
        4, { if(i < s.(0.2)) { 0 } { sine.(i, 110, 2.0) } },
        5, { if(i < s.(0.2)) { 0 } { sine.(i, 165, 0.3) } }
    )
});
var score, cmd, said, sf, data, out, inp, peak, clipped, firstClip, lastClip, ratio, oldClipped, limit, clip;

limit = MegaSAMixer.limitLevel;
clip = MegaSAMixer.clipLevel;
File.mkdir(tmp);
sf = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(inChans).sampleRate_(sr);
sf.openWrite(src);
sf.writeData(input);
sf.close;

score = [
    [0.0, [\d_recv, masterDef.asBytes]], [0.0, [\d_recv, probeDef.asBytes]],
    // The input's channel k is bus outChans + k; rec goes to a private bus.
    [0.0, [\s_new, \megaNrtMaster, 1000, 1, 0, \in, outChans + 0, \out, 0, \rec, 100]],
    [0.0, [\s_new, \megaNrtMaster, 1001, 1, 0, \in, outChans + 2, \out, 2, \rec, 102]],
    [0.0, [\s_new, \megaNrtMaster, 1002, 1, 0, \in, outChans + 4, \out, 4, \rec, 104]],
    [0.0, [\s_new, \megaNrtMasterLight, 1003, 1, 0, \in, outChans + 2, \out, 6]],
    // Every synth freed before the end (scsynth 3.14.1 can hang in its
    // offline cleanup otherwise).
    [dur - 0.05, [\n_free, 1000, 1001, 1002, 1003]],
    [dur, [\c_set, 0, 0]]
];
Score(score).writeOSCFile(osc);
cmd = "perl -e 'alarm shift; exec @ARGV' 120 " ++ MegaSAPlugins.scsynthPath.shellQuote ++ " -u " ++ (58500 + 200.rand)
    ++ " -N " ++ osc.shellQuote ++ " " ++ src.shellQuote ++ " " ++ wav.shellQuote ++ " " ++ sr
    ++ " WAV float -o " ++ outChans ++ " -i " ++ inChans ++ " 2>&1";
said = cmd.unixCmdGetStdOut;
sf = SoundFile.openRead(wav);

"== the master's safety limiter, offline ==".postln;
if(sf.isNil or: { sf.numFrames < (frames - s.(0.1)) }) {
    ("  FAIL  the render: " ++ said.split($\n).reject(_.isEmpty).keep(-4).join(" | ")).postln;
    sf !? { |f| f.close };
    fail = fail + 1;
} {
    data = FloatArray.newClear(sf.numFrames * outChans);
    sf.readData(data);
    sf.close;
    out = { |c, i| data[(i * outChans) + c] };
    inp = { |c, i| input[(i * inChans) + c] };
    // The largest |x| of output channel c over [from, to) seconds.
    peak = { |c, from, to| (s.(from) .. s.(to) - 1).inject(0, { |m, i| m.max(out.(c, i).abs) }) };
    // Frames of output channel c at the clip.
    clipped = { |c, from, to| (s.(from) .. s.(to) - 1).select { |i| out.(c, i).abs >= (clip - 1e-6) } };

    // ---- A: under the limit, untouched ----
    ok.("A: a mix at -6 dBFS comes out as it went in, to the bit, from the first block on",
        (64 .. s.(dur - 0.1) - 1).every { |i| (out.(0, i) == inp.(0, i)) and: { out.(1, i) == inp.(1, i) } },
        (64 .. s.(dur - 0.1) - 1).detect { |i| out.(0, i) != inp.(0, i) } !? { |i| "frame " ++ i ++ ": "
            ++ out.(0, i) ++ " for " ++ inp.(0, i) });

    // ---- B: 6 dB over ----
    {
        var cut = clipped.(2, 0.2, 1.2) ++ clipped.(3, 0.2, 1.2);
        oldClipped = (s.(0.2) .. s.(1.2) - 1).count { |i| (inp.(2, i).abs > clip) or: { inp.(3, i).abs > clip } };
        ok.("B: 6 dB over for a second, nothing leaves past the clip",
            peak.(2, 0, dur - 0.1).max(peak.(3, 0, dur - 0.1)) <= (clip + 1e-6));
        ok.("B: the clip cuts only its first moment (the first 10 ms), where the clip alone cut every cycle",
            cut.isEmpty.not and: { cut.every { |i| i < s.(0.21) } } and: { oldClipped > (sr * 0.5) },
            "cut " ++ cut.size ++ " frames, the last at " ++ (cut.maxItem ? 0 / sr).round(0.0001)
                ++ " s; the clip alone: " ++ oldClipped);
        // 20:1 over -1 dBFS makes 6 dB over -0.65 dBFS; the envelope's ripple
        // between a low sine's peaks lets them a little higher (measured
        // -0.41 dBFS at 110 Hz), still under the clip.
        ok.("B: from 20 ms on, held between the limit and the clip",
            { var p = peak.(2, 0.22, 1.2).max(peak.(3, 0.22, 1.2)); (p > limit) and: { p < (clip - 0.01) } }.value,
            "peak " ++ peak.(2, 0.22, 1.2).max(peak.(3, 0.22, 1.2)).ampdb.round(0.01) ++ " dBFS");
        ratio = peak.(2, 1.5, 1.9) / 0.3;
        ok.("B: the quiet mix after it is back at its own level within 0.3 s",
            (ratio - 1).abs < 0.005, "gain " ++ ratio.ampdb.round(0.01) ++ " dB");
    }.value;

    // ---- C: one side over ----
    {
        // The gain on each sample, where both sides are loud enough to read it.
        var worst = (s.(0.25) .. s.(1.2) - 1).inject(0, { |m, i|
            if((inp.(4, i).abs > 0.5) and: { inp.(5, i).abs > 0.1 }) {
                m.max(((out.(4, i) / inp.(4, i)) - (out.(5, i) / inp.(5, i))).abs)
            } { m }
        });
        ok.("C: the left side over, the right quiet: both turned down alike, sample for sample (the image holds)",
            worst < 1e-4, "the gains differ by up to " ++ worst);
    }.value;

    // ---- B's light signals ----
    {
        var over = { |from, to| (s.(from) .. s.(to) - 1).any { |i| out.(6, i) > 0.5 } };
        var cut = { |from, to| (s.(from) .. s.(to) - 1).any { |i| out.(7, i) > 0.5 } };
        ok.("the limiter's light signal: nothing before the mix goes over, on while it is over, off after",
            over.(0, 0.2).not and: { over.(0.2, 0.3) } and: { over.(1.0, 1.2) } and: { over.(1.25, 1.9).not });
        ok.("the clip's: only at the start of it",
            cut.(0, 0.2).not and: { cut.(0.2, 0.21) } and: { cut.(0.22, 1.9).not });
    }.value;
};
("== " ++ pass ++ " passed, " ++ fail ++ " failed ==").postln;
fails.do { |f| ("   " ++ f).postln };
[osc, wav, src].do { |f| if(File.exists(f)) { File.delete(f) } };
File.delete(tmp);
if(fail == 0) { "NRT MASTER OK".postln; 0.exit } { "NRT MASTER FAILED".postln; 1.exit };
)
