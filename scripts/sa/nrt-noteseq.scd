// The note sequencer (MegaSANoteSeq, docs/dev/synth.md, Phase 1) in scsynth,
// non-realtime (headless): MegaSADrums' Notes part decides a line on the
// drums' grid and its test tone (\megaSANoteTone) plays it; beside it a click
// on every 16th of the loop's grid, 20 ms after it (the loop's own delay, the
// Limiter's look-ahead), as the loop's clicks would be heard. Read back:
//
//   1. every note starts on its 16th's click, to the sample (OffsetOut; the
//      tone's envelope starts at 0, so its first sample that is not 0 is
//      the one after the stamp);
//   2. a ratchet's hits at their thirds of the step, a shifted step a
//      quarter of a step after its click, and with swing every second 16th
//      late by swing * 0.498 of one;
//   3. the notes switched off after they were sent are cancelled: from the
//      moment heard on nothing sounds;
//   4. the tone stays under full scale, and every sample is a number.
//
//     /Applications/SuperCollider.app/Contents/MacOS/sclang scripts/sa/nrt-noteseq.scd
//
// The drums object runs on a stub server whose bundles go into the score at
// their stamps (its sender hook) and its pump is stepped by hand, every 10 ms
// of a wall clock that is a number here. No audio device is touched; the
// score and the render go to a folder of this run's own, deleted at the end.
// Prints PASS or FAIL per check and NRT NOTESEQ PASSED at the end; exits 1 on
// any failure.
(
var sr = 48000, endT = 7.0, lam = 1.0, loopDur = 2.0, s16 = 0.125, delay = MegaSADrums.loopAudioDelay;
var scsynth = MegaSAPlugins.scsynthPath;
var tmpDir = (Platform.defaultTempDir ? "/tmp") +/+ "megalooper-sa"
    +/+ ("nrt-noteseq-" ++ Date.getDate.stamp ++ "-" ++ thisProcess.pid);
var oscPath = tmpDir +/+ "nrt-noteseq.osc", outPath = tmpDir +/+ "nrt-noteseq.wav";
var numOut = 3, watchdogSec = 60, minFrames = (endT * sr).floor.asInteger;
var group = 1001, ring = 100, choke = 99;
var swingFrom = 3.0, offAt = 5.0;
var fails = 0, passes = 0;
var check, tail, stub, looper, d, wall = 0.9, score, cmd, said, sf, data, frames, sample, firstNonZero;
var sent, sounding, cancelled, clear, onsetOf, offsets, clickAt, peak, finite, kinds, late, want, after, silentFrom;

check = { |label, ok, detail|
    if(ok == true) { passes = passes + 1; ("  PASS  " ++ label).postln } {
        fails = fails + 1;
        ("  FAIL  " ++ label ++ (detail !? { |dt| " — " ++ dt } ? "")).postln;
    };
};
tail = { |text| (text ? "").split($\n).reject(_.isEmpty).keep(-4).join(" | ") };

try {
    MegaSADrums.loadSynthDefs;
    if(SynthDescLib.global[\megaSANoteTone].isNil) { Error("the test tone's SynthDef did not build").throw };
    File.mkdir(tmpDir);

    // The drums, on a stub, a Looper fixture playing a 2 s loop of 4/4 at
    // 120 BPM from lam (a 16th is 0.125 s).
    stub = (sampleRate: sr, latency: 0.2, options: ServerOptions.new, sync: { |self| self },
        sendMsg: { |self| self }, sendBundle: { |self| self });
    looper = Looper.newCopyArgs;
    looper.instVarPut(\server, stub);
    looper.instVarPut(\state, \playing);
    looper.instVarPut(\loopFrames, (loopDur * sr).round.asInteger);
    looper.instVarPut(\loopStartTime, lam);
    looper.instVarPut(\lastResult, (numerator: 4, denominator: 4, k: 1, bpm: 120, loopDur: loopDur));
    d = MegaSADrums((server: stub));
    d.prUseBusses(synthBus: 0, synthGrp: group, synthRing: ring, synthChoke: choke);
    d.wallClock = { wall };
    score = List.new;
    d.sender = { |t, msgs| score.add([t ? wall, msgs]) };
    d.randSeed = 77;
    d.attach(looper);

    // The line: every step at half its length, step 6 a ratchet of 2 at 10 %,
    // step 10 a quarter of a step late; no scale, so the notes are plain.
    d.setNoteSetting(\scaleOn, false);
    d.setNoteValues(\length, Array.fill(16, 50).put(5, 10));
    d.setNoteValues(\ratchet, Array.fill(16, 0).put(5, 2));
    d.setNoteValues(\shift, Array.fill(16, 0).put(9, 25));
    d.setNotesOn(true, wall);
    d.transportStart(wall);
    while { wall < (endT - 0.3) } {
        wall = wall + 0.01;
        // Swing from swingFrom's bar on (decided 100 ms ahead: set before),
        // and the sequencer off at offAt, once its notes there are sent.
        if((wall - (swingFrom - 0.2)).abs < 0.005) { d.setNoteSetting(\swing, 0.5) };
        if((wall - (offAt - 0.05)).abs < 0.005) { d.setNotesOn(false, offAt + delay) };
        d.pump(wall);
    };

    // What was sent, and what of it a /c_set cancelled after.
    sent = List.new;
    score.do { |e|
        e[1].do { |m|
            var a;
            if((m[0] == \s_new) and: { m[1] == \megaSANoteTone }) {
                a = ().putPairs(m.copyToEnd(5));
                sent.add((time: e[0], ring: a[\cancelBus], dur: a[\dur], cancelled: false));
            };
            if(m[0] == \c_set) {
                m.copyToEnd(1).pairsDo { |bus, v|
                    if(v == 1) { sent.reverse.detect { |n| n[\ring] == bus } !? { |n| n[\cancelled] = true } };
                };
            };
        };
    };
    sounding = sent.reject(_[\cancelled]);
    cancelled = sent.select(_[\cancelled]);

    score = [[0.0, [\d_recv, SynthDescLib.global[\megaSANoteTone].def.asBytes]],
        [0.0, [\d_recv, SynthDef(\nrtGridClick, { |out| OffsetOut.ar(out, Impulse.ar(0)); FreeSelf.kr(Impulse.kr(0)) }).asBytes]],
        [0.0, [\g_new, group, 0, 0]],
        [0.0, [\c_setn, choke, 1025] ++ Array.fill(1025, 0)]]
        ++ ((((endT - 0.5) - lam) / s16).floor.asInteger + 1).collect { |k|
            [(lam + (k * s16)) + delay, [\s_new, \nrtGridClick, -1, 1, group, \out, 2]]
        }
        ++ score.collect { |e| [e[0]] ++ e[1] }.asArray
        ++ [[endT - 0.1, [\g_freeAll, group]], [endT, [\c_set, 0, 0]]];
    score = score.collect { |e, i| [e, i] }.sort { |a, b| (a[0][0] < b[0][0]) or: { (a[0][0] == b[0][0]) and: { a[1] < b[1] } } }
        .collect { |p| p[0] };
    Score(score).writeOSCFile(oscPath);

    cmd = "perl -e 'alarm shift; exec @ARGV' " ++ watchdogSec ++ " " ++ scsynth.quote ++ " -u " ++ (58800 + 150.rand) ++ " -N "
        ++ oscPath.quote ++ " _ " ++ outPath.quote ++ " " ++ sr ++ " WAV float -o " ++ numOut ++ " -i 0 2>&1";
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
    sample = { |c, i| if((i >= 0) and: { i < frames }) { data[(i * numOut) + c] } { 0 } };
    firstNonZero = { |c, from, to| (from .. to).detect { |i| sample.(c, i) != 0 } };
    // A note's first sample that is not 0, looked for from 2 ms before its stamp.
    onsetOf = { |n| var k = (n[\time] * sr).round.asInteger; firstNonZero.(0, k - 96, k + 480) };
    clickAt = { |g| var k = ((g + delay) * sr).round.asInteger; firstNonZero.(2, k - 2, k + 2) };

    "== the note sequencer ==".postln;
    check.("notes were sent and sounded: 32 steps and two ratchets", sounding.size == 36, sounding.size.asString);
    // Each sounding note against the 16th it belongs to: plain, ratchet,
    // shifted or swung, by where its grid time falls.
    kinds = sounding.collect { |n|
        var g = n[\time] - delay, k = (g - lam) / s16, step = k.floor.asInteger, frac = k - step;
        if(frac > 0.999) { step = step + 1; frac = 0 };
        (n: n, g: g, step: step, frac: frac, base: lam + (step * s16))
    };
    // A note the one before still rings into (a swung ratchet's last hit:
    // the mono choke ends it there) has no silence to start from: left out.
    clear = kinds.select { |e, i|
        (i == 0) or: { var p = kinds[i - 1][\n]; ((p[\time] + p[\dur]) + 0.02 + (64 / sr)) < (e[\n][\time] - 0.002) }
    };
    offsets = clear.collect { |e| (onsetOf.(e[\n]) ? -1e9) - (clickAt.(e[\base]) ? 1e9) };
    want = clear.collect { |e| (e[\frac] * s16 * sr).round.asInteger + 1 };
    late = (offsets - want).abs;
    check.("every note's first sound is the sample after its stamp, on its 16th's click or where its offset puts it ("
        ++ clear.size ++ " notes; " ++ (kinds.size - clear.size) ++ " start inside the one before, left out)",
        (clear.size >= 32) and: { late.every { |x| x <= 1 } }, "worst " ++ late.maxItem ++ " samples off; offsets " ++ offsets.keep(6));
    check.("...a ratchet's hits at thirds of the step", kinds.select { |e| (e[\step] % 16) == 5 }.collect { |e|
        (e[\frac] * 3).round(1e-6) }.keep(3) == [0, 1, 2], kinds.select { |e| (e[\step] % 16) == 5 }.collect(_[\frac]).keep(3).asString);
    check.("...a shifted step a quarter of a step late", kinds.detect { |e| (e[\step] % 16) == 9 } !? { |e| (e[\frac] - 0.25).abs < 1e-6 },
        (kinds.detect { |e| (e[\step] % 16) == 9 } !? { |e| e[\frac] }).asString);
    after = kinds.select { |e| (e[\g] >= swingFrom) and: { e[\g] < offAt } and: { e[\step].odd } and: { (e[\step] % 16) != 5 } and: { (e[\step] % 16) != 9 } };
    check.("...and with swing 50 % every second 16th late by 0.249 of one",
        after.notEmpty and: { after.every { |e| (e[\frac] - 0.249).abs < 1e-6 } }, after.collect(_[\frac]).keep(4).asString);
    check.("...the even ones on their clicks", kinds.select { |e| (e[\g] >= swingFrom) and: { e[\step].even } }.every { |e| e[\frac] == 0 });
    check.("switched off: what was sent from that moment was cancelled", cancelled.notEmpty and: {
        cancelled.every { |n| n[\time] >= (offAt + delay - 1e-6) } }, cancelled.size.asString ++ " cancelled");
    silentFrom = ((offAt + delay) * sr).round.asInteger;
    check.("...and nothing sounds from then on",
        firstNonZero.(0, silentFrom + 4800, frames - 1).isNil and: { sounding.every { |n| n[\time] < (offAt + delay) } },
        "a sample at " ++ firstNonZero.(0, silentFrom + 4800, frames - 1));
    peak = 0;
    finite = true;
    frames.do { |i| var x = sample.(0, i); if((x != x) or: { x.abs == inf }) { finite = false } { peak = peak.max(x.abs) } };
    check.("the tone stays under full scale, every sample a number", finite and: { peak < 1 } and: { peak > 0.05 }, "peak " ++ peak);
    ("  measured: " ++ sounding.size ++ " notes, " ++ cancelled.size ++ " cancelled; onsets "
        ++ late.maxItem ++ " samples from where they belong at worst; peak " ++ peak.round(1e-4)).postln;
} { |err|
    fails = fails + 1;
    ("  FAIL  " ++ err.errorString.replace("ERROR: ", "")).postln;
    if(err.class !== Error) { err.reportError };
};
d !? { d.free };
(tmpDir +/+ "*").pathMatch.do { |p| File.delete(p) };
File.delete(tmpDir);
(passes.asString ++ " passed, " ++ fails ++ " failed").postln;
if(fails == 0) { "NRT NOTESEQ PASSED".postln; 0.exit } { "NRT NOTESEQ FAILED".postln; 1.exit };
)
