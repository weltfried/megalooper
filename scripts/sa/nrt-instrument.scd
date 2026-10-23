// The synth's instrument plugin (MegaSA.setInstrument, docs/dev/synth.md
// Phase 4) in scsynth, non-realtime (headless): the first instrument of this
// Mac's plugin catalog (megalooper's own scan, sa/plugins/), hosted in
// \megaSAInstrument as MegaSA hosts it, opened by its key, and played by the
// note sequencer (MegaSADrums' Notes part) through the same note-on and
// note-off messages MegaSA sends (MegaSA.prInstrumentMsgs's form). Read back:
//
//   1. it opened and made sound: every sample a number, something under
//      full scale and above silence;
//   2. every note starts where it is sent: its sound rises within two
//      blocks of its stamp (VSTPlugin hands MIDI over at a block's start),
//      out of the silence before it;
//   3. at its pitch: the zero crossings of its first 40 ms after the onset;
//   4. the note-offs end it: silence again (60 dB down) before the next.
//
//     /Applications/SuperCollider.app/Contents/MacOS/sclang scripts/sa/nrt-instrument.scd
//
// It skips, saying so, without VSTPlugin, without a scan, or with no
// instrument in it (tools/run-checks.sh then counts it as skipped). The
// plugin's patch is its own default. The controller that builds the
// messages is bound to a Server object of its own that nothing runs at: never
// the running megalooper's.
(
var sr = 48000, lam = 1.0, endT = 6.0, wall = 0.9, group = 1001, node = 1000, step = 0.5;
var scsynth = MegaSAPlugins.scsynthPath;
var cacheDir = MegaFiles.userRoot +/+ "sa" +/+ "plugins";
var tmpDir = (Platform.defaultTempDir ? "/tmp") +/+ "megalooper-sa" +/+ ("nrt-instrument-" ++ Date.getDate.stamp ++ "-" ++ thisProcess.pid);
var oscPath = tmpDir +/+ "nrt-instrument.osc", outPath = tmpDir +/+ "nrt-instrument.wav";
var fails = 0, passes = 0, entry, stubServer, ctl, stub, looper, d, score = List.new, cmd, said, sf, data, frames;
var sample, notes, onsets, worst, pitches, offs, peak, finite, tail, rms;
var check = { |label, ok, detail|
    if(ok == true) { passes = passes + 1; ("  PASS  " ++ label).postln } {
        fails = fails + 1;
        ("  FAIL  " ++ label ++ (detail !? { |dt| " — " ++ dt } ? "")).postln;
    };
};
tail = { |text| (text ? "").split($\n).reject(_.isEmpty).keep(-4).join(" | ") };

entry = if(MegaSAPlugins.available and: { MegaSAPlugins.hasCache(cacheDir) }) {
    MegaSAPlugins.read(cacheDir).detect { |e| (e[\synth] == true) and: { e[\bridged] != true } }
};
case
{ MegaSAPlugins.available.not } { "NRT INSTRUMENT PASSED — skipped: VSTPlugin is not installed here".postln; 0.exit }
{ entry.isNil } { "NRT INSTRUMENT PASSED — skipped: no instrument plugin in this Mac's scan (sa/plugins/)".postln; 0.exit };

try {
    ("== the note sequencer through " ++ entry[\key] ++ " ==").postln;
    MegaSAPlugin.addInstrumentDef;
    File.mkdir(tmpDir);
    stubServer = Server(("nrtInstrument" ++ thisProcess.pid).asSymbol, NetAddr("127.0.0.1", 59900 + 90.rand));
    ctl = VSTPluginController(Synth.basicNew(\megaSAInstrument, stubServer, node), \plugin);

    // The drums on a stub, a Looper fixture playing a 2 s loop of 4/4 at
    // 120 BPM; the sequencer in quarter notes, each 30 % long.
    stub = (sampleRate: sr, latency: 0.2, options: ServerOptions.new, sync: { |self| self },
        sendMsg: { |self| self }, sendBundle: { |self| self });
    looper = Looper.newCopyArgs;
    looper.instVarPut(\server, stub);
    looper.instVarPut(\state, \playing);
    looper.instVarPut(\loopFrames, (2.0 * sr).round.asInteger);
    looper.instVarPut(\loopStartTime, lam);
    looper.instVarPut(\lastResult, (numerator: 4, denominator: 4, k: 1, bpm: 120, loopDur: 2.0));
    d = MegaSADrums((server: stub));
    d.prUseBusses(synthBus: 0, synthGrp: group);
    d.wallClock = { wall };
    d.sender = { |t, msgs| score.add([t ? wall] ++ msgs) };
    d.noteVoice = { |rec, where|
        var off = ctl.midi.noteOffMsg(0, rec[\note].asInteger, 0);
        (msgs: [ctl.midi.noteOnMsg(0, rec[\note].asInteger, rec[\vel].asInteger.clip(1, 127))],
            after: [[rec[\gate] + (if(rec[\tie] == true) { 0.002 } { 0 }), [off]]], cancel: [off])
    };
    d.randSeed = 3;
    d.attach(looper);
    d.setNoteSetting(\division, 2);
    d.setNoteValues(\length, 30 ! 16);
    d.setNotesOn(true, wall);
    d.transportStart(wall);
    while { wall < (endT - 1.2) } { wall = wall + 0.01; d.pump(wall) };

    notes = List.new;
    score.do { |e| e.drop(1).do { |m| if((m[0] == '/u_cmd') and: { m[3] == '/midi_msg' } and: { (m[4][0] & 0xF0) == 0x90 }) {
        notes.add([e[0], m[4][1]]) } } };
    score = [
        [0.0, MegaSAPlugins.readCacheMsg(cacheDir)],
        [0.0, [\d_recv, SynthDescLib.global[\megaSAInstrument].def.asBytes]],
        [0.0, [\g_new, group, 0, 0]],
        [0.0, [\s_new, \megaSAInstrument, node, 0, group, \out, 0]],
        [0.05, ctl.openMsg(entry[\key], false)],
        [0.5, [\n_set, node, \ready, 1, \bypass, 0]]
    ] ++ score.asArray ++ [[endT - 0.2, ctl.closeMsg], [endT - 0.1, [\n_free, node]], [endT, [\c_set, 0, 0]]];
    score = score.collect { |e, i| [e, i] }.sort { |a, b| (a[0][0] < b[0][0]) or: { (a[0][0] == b[0][0]) and: { a[1] < b[1] } } }
        .collect { |p| p[0] };
    Score(score).writeOSCFile(oscPath);
    cmd = "perl -e 'alarm shift; exec @ARGV' 120 " ++ scsynth.quote ++ " -u " ++ (58800 + 150.rand) ++ " -N "
        ++ oscPath.quote ++ " _ " ++ outPath.quote ++ " " ++ sr ++ " WAV float -o 2 -i 0 -m 65536 2>&1";
    said = cmd.unixCmdGetStdOut;
    said.split($\n).do { |line| if(line.contains("FAILURE") or: { line.contains("rror") } or: { line.contains("could not") }) {
        ("  scsynth: " ++ line).postln } };
    sf = SoundFile.openRead(outPath);
    if(sf.isNil) { Error("no render (scsynth: " ++ tail.(said) ++ ")").throw };
    frames = sf.numFrames;
    data = FloatArray.newClear(frames * sf.numChannels);
    sf.readData(data);
    sf.close;
    sample = { |i| if((i >= 0) and: { i < frames }) { data[i * 2] } { 0 } };
    rms = { |t, dur| var a = (t * sr).round.asInteger, n = (dur * sr).round.asInteger;
        (((0 .. (n - 1)).sum { |k| sample.(a + k).squared }) / n).sqrt };

    peak = 0;
    finite = true;
    frames.do { |i| var x = sample.(i); if((x != x) or: { x.abs == inf }) { finite = false } { peak = peak.max(x.abs) } };
    check.("the sequencer sent notes", notes.size >= 6, notes.size.asString);
    check.(entry[\key] ++ " opened and played: every sample a number, under full scale, above silence",
        finite and: { peak < 1 } and: { peak > 0.01 }, "peak " ++ peak);
    // Each note's first sample over 1/100 of the peak, from 2 ms before its stamp.
    onsets = notes.collect { |n|
        var k = (n[0] * sr).round.asInteger;
        ((k - 96) .. (k + 4800)).detect { |i| sample.(i).abs > (peak * 0.01) } !? { |i| i - k } ? 99999 };
    worst = onsets.maxItem;
    check.("every note sounds from its stamp: within two blocks (MIDI goes in at a block's start)",
        onsets.every { |o| (o >= 0) and: { o <= 128 } }, "onsets (samples) " ++ onsets);
    pitches = notes.collect { |n|
        var a = ((n[0] + 0.01) * sr).round.asInteger, z = List.new, x0, x1;
        (a .. (a + (0.04 * sr).round.asInteger)).do { |i| x0 = sample.(i - 1); x1 = sample.(i);
            if((x0 < 0) and: { x1 >= 0 }) { z.add((i - 1) + (x0.neg / (x1 - x0))) } };
        if(z.size < 2) { 0 } { (z.size - 1) / ((z.last - z.first) / sr) }
    };
    check.("...at its pitch (zero crossings of its first 40 ms, within 3 %)",
        notes.every { |n, i| ((pitches[i] / n[1].midicps) - 1).abs < 0.03 },
        notes.collect { |n, i| [n[1].midicps.round(0.1), pitches[i].round(0.1)] }.asString);
    offs = notes.drop(-1).collect { |n, i| rms.(notes[i + 1][0] - 0.03, 0.02) / rms.(n[0] + 0.03, 0.05).max(1e-9) };
    check.("its note-off ends it: 60 dB down before the next note", offs.every { |r| r < 0.001 }, offs.collect { |r| r.ampdb.round(0.1) }.asString);
    ("  measured: " ++ notes.size ++ " notes; onsets " ++ onsets.minItem ++ ".." ++ worst ++ " samples after their stamps; peak "
        ++ peak.round(1e-4)).postln;
} { |err|
    fails = fails + 1;
    ("  FAIL  " ++ err.errorString.replace("ERROR: ", "")).postln;
    if(err.class !== Error) { err.reportError };
};
d !? { d.free };
(tmpDir +/+ "*").pathMatch.do { |p| File.delete(p) };
File.delete(tmpDir);
(passes.asString ++ " passed, " ++ fails ++ " failed").postln;
if(fails == 0) { "NRT INSTRUMENT PASSED".postln; 0.exit } { "NRT INSTRUMENT FAILED".postln; 1.exit };
)
