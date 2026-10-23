// The Wave synth (MegaSAWave, docs/dev/synth.md Phase 2) in scsynth,
// non-realtime (headless): its tables made by the server from the messages
// MegaSAWave sends, and its voice (\megaSAWaveVoice) played by the messages
// MegaSAWave makes for a note. Read back:
//
//   1. aliasing: the saw, filter open, held at pitches through the bands up
//      to 3.7 kHz; the energy off its harmonics, against the whole, from an
//      8192-point spectrum, under a floor. The same measure on a naive saw
//      (LFSaw) at 3.5 kHz shows that it would see aliasing;
//   2. glide: a sine sliding from 220 to 440 Hz over 0.2 s, its pitch read
//      from its zero crossings: 220 before, 440 after, rising between, at
//      the half-way point near the exponential's 311 Hz;
//   3. mono: a second note on the same choke bus ends the first: 30 ms
//      after it starts, nothing is left at the first one's pitch;
//   4. legato: a note started legato keeps the level where the one before
//      was (no new attack); started anew it attacks to full level again;
//   5. a cancelled note writes nothing; every sample is a number, under full
//      scale.
//
//     /Applications/SuperCollider.app/Contents/MacOS/sclang scripts/sa/nrt-wave.scd
//
// No audio device is touched; the score and the render go to a folder of
// this run's own, deleted at the end. Prints PASS or FAIL per check and NRT
// WAVE PASSED at the end; exits 1 on any failure.
(
var sr = 48000, endT = 5.0, numOut = 14;
var scsynth = MegaSAPlugins.scsynthPath;
var tmpDir = (Platform.defaultTempDir ? "/tmp") +/+ "megalooper-sa"
    +/+ ("nrt-wave-" ++ Date.getDate.stamp ++ "-" ++ thisProcess.pid);
var oscPath = tmpDir +/+ "nrt-wave.osc", outPath = tmpDir +/+ "nrt-wave.wav";
var watchdogSec = 120, minFrames = (endT * sr).floor.asInteger;
var group = 1000, fails = 0, passes = 0, hit = 0;
var check, tail, w, note, score, cmd, said, sf, data, frames, sample, chan, aliasDb, zc, pitchAt, goertzel, peaks;
var aliasNotes = #[40, 64, 88, 100, 105, 106], aliasAt, aliasDbs, naiveDb, floorDb = -60;
var gA = 0.3, gB = 0.7, mC = 0.3, mD = 0.6, lE = 0.3, lF = 0.6, nG = 0.3, nH = 0.6;
var pitches, mid, rest, before, levels, flat, bump, finite, peak;

check = { |label, ok, detail|
    if(ok == true) { passes = passes + 1; ("  PASS  " ++ label).postln } {
        fails = fails + 1;
        ("  FAIL  " ++ label ++ (detail !? { |dt| " — " ++ dt } ? "")).postln;
    };
};
tail = { |text| (text ? "").split($\n).reject(_.isEmpty).keep(-4).join(" | ") };

try {
    MegaSAWave.loadSynthDefs;
    File.mkdir(tmpDir);
    // The synth, its tables from buffer 0, as MegaSA would have built them.
    w = MegaSAWave((sampleRate: sr));
    w.instVarPut(\base, 0);
    w.instVarPut(\built, true);
    // One note's message at time t onto `out`, with a cancel bus of its own
    // and the choke bus of its channel: rec as MegaSADrums makes it.
    note = { |t, out, midi, dur, from, legato = false, settings|
        hit = hit + 1;
        w.reset;
        (settings ? ()).keysValuesDo { |k, v| w.set(k, v) };
        // The voice is stereo: check c is the pair from 2c, its left read.
        [t] ++ w.voiceMsgs((note: midi, vel: 127, gate: dur, from: from, legato: legato),
            (group: group, out: out * 2, ring: 100 + hit, choke: 200 + out, hitId: hit))
    };
    score = [[0.0, [\d_recv, SynthDescLib.global[\megaSAWaveVoice].def.asBytes]],
        [0.0, [\d_recv, SynthDef(\nrtNaiveSaw, { |out, freq = 3520, dur = 0.5|
            OffsetOut.ar(out, LFSaw.ar(freq) * 0.25 * EnvGen.kr(Env.linen(0.001, dur, 0.01), doneAction: 2)) }).asBytes]],
        [0.0, [\g_new, group, 0, 0]],
        [0.0, [\c_setn, 100, 120] ++ Array.fill(120, 0)],
        [0.0, [\c_setn, 200, 10] ++ Array.fill(10, 0)]]
        ++ MegaSAWave.tableMsgs(0).collect { |m| [0.0, m] };
    // 1: the saw (Analog, table 2) held, its filter wide open, no envelope to speak of.
    aliasAt = aliasNotes.collect { |n, i| 0.2 + (i * 0.6) };
    aliasNotes.do { |n, i|
        score = score.add(note.(aliasAt[i], 0, n, 0.5, nil, false, (waveAPos: 2 / 7, waveCutoff: 18000, waveResonance: 0,
            waveKeyTrack: 0, waveFilterEnv: 0, waveSustain: 1, waveAttack: 0.001, waveLevel: 0)));
    };
    score = score.add([0.2, [\s_new, \nrtNaiveSaw, -1, 1, group, \out, 2, \freq, 3520, \dur, 0.5]]);
    // 2: glide.
    score = score.add(note.(gA, 2, 57, 0.6, nil, false, (waveAPos: 0, waveCutoff: 18000, waveSustain: 1)));
    score = score.add(note.(gB, 2, 69, 0.6, 57, true, (waveAPos: 0, waveCutoff: 18000, waveSustain: 1, waveGlide: 0.2)));
    // 3: mono, not legato.
    score = score.add(note.(mC, 3, 57, 1.5, nil, false, (waveAPos: 0, waveCutoff: 18000, waveSustain: 1)));
    score = score.add(note.(mD, 3, 64, 0.6, 57, false, (waveAPos: 0, waveCutoff: 18000, waveSustain: 1)));
    // 4: legato keeps the level; anew it attacks again.
    score = score.add(note.(lE, 4, 57, 0.4, nil, false, (waveAPos: 0, waveCutoff: 18000, waveSustain: 0.5, waveDecay: 0.05)));
    score = score.add(note.(lF, 4, 64, 0.4, 57, true, (waveAPos: 0, waveCutoff: 18000, waveSustain: 0.5, waveDecay: 0.05)));
    score = score.add(note.(nG, 5, 57, 0.4, nil, false, (waveAPos: 0, waveCutoff: 18000, waveSustain: 0.5, waveDecay: 0.05)));
    score = score.add(note.(nH, 5, 57, 0.4, 57, false, (waveAPos: 0, waveCutoff: 18000, waveSustain: 0.5, waveDecay: 0.05)));
    // 5: cancelled.
    score = score.add(note.(1.0, 6, 60, 0.3, nil, false));
    score = score.add([0.9, [\c_set, 100 + hit, 1]]);
    score = score ++ [[endT - 0.1, [\g_freeAll, group]], [endT, [\c_set, 0, 0]]];
    score = score.collect { |e, i| [e, i] }.sort { |a, b| (a[0][0] < b[0][0]) or: { (a[0][0] == b[0][0]) and: { a[1] < b[1] } } }
        .collect { |p| p[0] };
    Score(score).writeOSCFile(oscPath);

    cmd = "perl -e 'alarm shift; exec @ARGV' " ++ watchdogSec ++ " " ++ scsynth.quote ++ " -u " ++ (58800 + 150.rand) ++ " -N "
        ++ oscPath.quote ++ " _ " ++ outPath.quote ++ " " ++ sr ++ " WAV float -o " ++ numOut ++ " -i 0 -m 65536 2>&1";
    said = cmd.unixCmdGetStdOut;
    said.split($\n).do { |line|
        if(line.contains("FAILURE") or: { line.contains("rror") } or: { line.contains("late") }) { ("  scsynth: " ++ line).postln };
    };
    sf = SoundFile.openRead(outPath);
    if(sf.isNil) { Error("no render (scsynth: " ++ tail.(said) ++ ")").throw };
    frames = sf.numFrames;
    if(frames < minFrames) { sf.close; Error("a short render, " ++ frames ++ " of " ++ minFrames ++ " frames").throw };
    data = FloatArray.newClear(frames * sf.numChannels);
    sf.readData(data);
    sf.close;
    sample = { |c, i| if((i >= 0) and: { i < frames }) { data[(i * numOut) + (c * 2)] } { 0 } };
    chan = { |c, from, n| Signal.fill(n, { |i| sample.(c, from + i) }) };

    // The share of a window's energy that is off the harmonics of f (each
    // +-6 bins, the window's main lobe), above 30 Hz, in dB.
    aliasDb = { |c, t, f|
        // Blackman-Harris (4 terms): its side lobes are 92 dB down, so the
        // leakage of the strong low partials does not read as aliasing.
        var n = 8192, x = chan.(c, (t * sr).round.asInteger, n) * Signal.fill(n, { |i|
            var a = 2pi * i / n; ((0.35875 - (0.48829 * cos(a))) + (0.14128 * cos(2 * a))) - (0.01168 * cos(3 * a)) });
        var spec = x.fft(Signal.newClear(n), Signal.fftCosTable(n)), mag, total = 0, off = 0, binHz = sr / n;
        mag = (spec.real.squared + spec.imag.squared).keep((n / 2).asInteger);
        mag.do { |m, b|
            var hz = b * binHz, k = (hz / f).round, near = (k >= 1) and: { (hz - (k * f)).abs <= (6 * binHz) };
            if(hz > 30) { total = total + m; if(near.not) { off = off + m } };
        };
        (off.max(1e-30) / total.max(1e-30)).ampdb / 2
    };
    // Positive-going zero crossings of channel c from t over d s, linearly
    // placed: the pitch between each pair.
    zc = { |c, t, d|
        var a = (t * sr).round.asInteger, b = ((t + d) * sr).round.asInteger, out = List.new, x0, x1;
        (a .. b).do { |i| x0 = sample.(c, i - 1); x1 = sample.(c, i);
            if((x0 < 0) and: { x1 >= 0 }) { out.add((i - 1) + (x0.neg / (x1 - x0))) } };
        out
    };
    pitchAt = { |c, t| var z = zc.(c, t - 0.01, 0.02); if(z.size < 2) { 0 } { (z.size - 1) / ((z.last - z.first) / sr) } };
    // The amplitude of frequency f in channel c over d s from t, through a
    // Hann window (so a neighbouring pitch does not leak into it).
    goertzel = { |c, t, d, f|
        var a = (t * sr).round.asInteger, n = (d * sr).round.asInteger, re = 0, im = 0, x;
        n.do { |i| x = sample.(c, a + i) * (0.5 - (0.5 * cos(2pi * i / n)));
            re = re + (x * cos(2pi * f * i / sr)); im = im + (x * sin(2pi * f * i / sr)) };
        (re.squared + im.squared).sqrt * 4 / n
    };
    // The peak level of channel c in each `step` s from t to t + d.
    peaks = { |c, t, d, step = 0.002|
        (0 .. ((d / step).floor.asInteger - 1)).collect { |k|
            var a = ((t + (k * step)) * sr).round.asInteger, m = 0;
            (step * sr).round.asInteger.do { |i| m = m.max(sample.(c, a + i).abs) };
            m
        }
    };

    "== the Wave synth ==".postln;
    // 1
    aliasDbs = aliasNotes.collect { |n, i| aliasDb.(0, aliasAt[i] + 0.2, n.midicps) };
    naiveDb = aliasDb.(1, 0.4, 3520);
    check.("the saw stays clean through the bands: off-harmonic energy under " ++ floorDb ++ " dB at every pitch",
        aliasDbs.every { |x| x < floorDb }, aliasNotes.collect { |n, i| n.midicps.round.asString ++ " Hz " ++ aliasDbs[i].round(0.1) }.join(", "));
    check.("...where a naive saw at 3.5 kHz aliases (the measure sees it)", naiveDb > -40, naiveDb.round(0.1).asString);
    // 2
    pitches = [gB - 0.02, gB + 0.1, gB + 0.25].collect { |t| pitchAt.(2, t) };
    check.("glide: 220 Hz before, 440 Hz after", ((pitches[0] - 220).abs < 2) and: { (pitches[2] - 440).abs < 2 }, pitches.round(0.1).asString);
    check.("...near the exponential's 311 Hz half-way", (pitches[1] - 311).abs < 15, pitches[1].round(0.1).asString);
    mid = (0 .. 9).collect { |k| pitchAt.(2, gB + 0.015 + (k * 0.018)) };
    check.("...rising all the way", mid.differentiate.drop(1).every { |x| x > -1 }, mid.round(1).asString);
    // 3
    rest = goertzel.(3, mD + 0.03, 0.1, 220);
    before = goertzel.(3, mC + 0.1, 0.1, 220);
    check.("mono: 30 ms after the second note starts, nothing is left of the first",
        (before > 0.1) and: { rest < (before * 0.001) }, "220 Hz before " ++ before.round(1e-4) ++ ", after " ++ rest.round(1e-6));
    check.("...and the second plays", goertzel.(3, mD + 0.03, 0.1, 64.midicps) > 0.1);
    // 4
    // In 5 ms windows: each holds a whole period of 220 Hz.
    levels = peaks.(4, lF - 0.03, 0.08, 0.005);
    flat = levels.maxItem / levels.minItem.max(1e-9);
    bump = peaks.(5, nH, 0.02).maxItem / peaks.(5, nH - 0.03, 0.02).maxItem.max(1e-9);
    check.("legato: the level holds across the change to the next pitch, within 30 %", flat < 1.3, "max/min " ++ flat.round(0.001));
    check.("...where a note started anew attacks to full level again", bump > 1.5, "peak after/before " ++ bump.round(0.01));
    // 5
    check.("a cancelled note writes nothing", (0 .. frames - 1).every { |i| sample.(6, i) == 0 });
    peak = 0;
    finite = true;
    [0, 2, 3, 4, 5].do { |c| frames.do { |i| var x = sample.(c, i); if((x != x) or: { x.abs == inf }) { finite = false } { peak = peak.max(x.abs) } } };
    check.("every sample a number, under full scale", finite and: { peak < 1 }, "peak " ++ peak);
    ("  measured: off-harmonic energy " ++ aliasDbs.round(0.1) ++ " dB (the naive saw " ++ naiveDb.round(0.1)
        ++ "); glide " ++ pitches.round(0.1) ++ " Hz; legato max/min " ++ flat.round(0.001) ++ ", anew " ++ bump.round(0.01)
        ++ "; peak " ++ peak.round(1e-4)).postln;
} { |err|
    fails = fails + 1;
    ("  FAIL  " ++ err.errorString.replace("ERROR: ", "")).postln;
    if(err.class !== Error) { err.reportError };
};
(tmpDir +/+ "*").pathMatch.do { |p| File.delete(p) };
File.delete(tmpDir);
(passes.asString ++ " passed, " ++ fails ++ " failed").postln;
if(fails == 0) { "NRT WAVE PASSED".postln; 0.exit } { "NRT WAVE FAILED".postln; 1.exit };
)
