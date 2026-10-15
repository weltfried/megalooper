// Megalooper SA, Phase 0 spike (headless): can scsynth host BIAS FX 2?
//
//     /Applications/SuperCollider.app/Contents/MacOS/sclang scripts/sa/spike-biasfx-nrt.scd
//     ~spikeTap = "/path/x-tap.wav";            // input; default: the newest dry tap in sessions/
//     ~spikePreset = "/path/x.fxb";             // default: the first presets/sa/biasfx/*.fxb
//     ~spikePreset = false;                     // no preset: the VST3, at its default sound
//     ~spikePlugin = "/path/Plugin.vst";        // override the plugin either way
//
// With a preset (tools/export-live-set.py biasfx writes them from the Live
// set), the plugin is the VST2 build hosted mono, 1 in / 1 out, exactly as the
// Live set hosts it, and the bank is loaded into it: the render is the Live
// set's own guitar sound. Without one, the VST3 at its default sound.
//
// Renders the loudest 30 s of a recorded dry tap through the plugin in scsynth
// non-realtime, hosted by VSTPlugin the way SA would host it, and reports:
//   - whether VSTPlugin can probe and open the plugin at all,
//   - the plugin's buses, parameter and program counts,
//   - whether the output is processed audio: not silent, not the input, and
//     no stretches muted while the guitar plays (how a plugin in demo mode or
//     without a license usually shows itself),
//   - what one second of audio costs: CPU time (user + sys, so disk waits do
//     not count) of a 2 s render against a 122 s one, so the plugin's load
//     time cancels out. The realtime figures come from spike-biasfx-rig.scd
//     on the interface.
//
// The tap is the guitar exactly as Live's guitar track receives it (the same
// hardware input), so the render hears what BIAS FX hears on stage. The 30 s
// render lands in sessions/sa-spike/ for listening. No audio device is
// touched, so this runs beside a playing instrument. Needs VSTPlugin in
// Extensions.
(
var repo = thisProcess.nowExecutingPath !? { |p| p.dirname.dirname.dirname } ?? { Looper.repoRoot };
var presetPath = if(~spikePreset == false) { nil } {
    ~spikePreset ?? { (repo +/+ "presets" +/+ "sa" +/+ "biasfx" +/+ "*.fxb").pathMatch.sort.first }
};
var plugPath = ~spikePlugin ?? {
    if(presetPath.notNil) { "/Library/Audio/Plug-Ins/VST/BIAS FX 2.vst" }
        { "/Library/Audio/Plug-Ins/VST3/BIAS FX 2.vst3" }
};
// The Live set hosts BIAS FX mono; a stereo plugin is fed dual mono, as Live
// feeds a mono input to a stereo plugin.
var numChans = if(presetPath.notNil) { 1 } { 2 };
// Beside SuperCollider's resources on macOS, on the shell's path on Linux.
var scsynth = MegaSAPlugins.scsynthPath;
var outDir = repo +/+ "sessions" +/+ "sa-spike";
var tmpDir = (Platform.defaultTempDir ? "/tmp") +/+ "megalooper-sa";
var headless = Platform.ideName != "scide";
var listenDur = 30, shortDur = 2, costDur = 122;
// A render that has not finished after this long is a plugin waiting on
// something it will never get headless (a login window, a dialog).
var watchdogSec = 300;
// Muting check, per 100 ms window: the guitar is playing above this...
var playingDb = -40;
// ...and the plugin put out less than this.
var mutedDb = -70;
var failures = 0;
var fail, fmtDb, loudestWindow, readFrames, chanStats, windowDb, render, reportScsynth;
var tapPath, rate, offset, def, server, synth, ctrl, infoPath, desc, stem, outPath;
var shortRun, listenRun, costRun, inData, outData, inStats, outStats, inWin, outWin;
var muted, processed, perSec;

fail = { |msg| ("SPIKE FAIL: " ++ msg).postln; failures = failures + 1 };
fmtDb = { |a| if(a <= 0) { "-inf dB" } { a.ampdb.round(0.1).asString ++ " dB" } };

// Where in the tap the playing is: the start (in seconds) of the window of
// `dur` seconds with the most energy, scanned a second at a time.
loudestWindow = { |path, dur|
    var sf = SoundFile.new, sr, secs, energy, chunk, best = 0, bestSum = -1, sum;
    sf.openRead(path);
    sr = sf.sampleRate;
    secs = (sf.numFrames / sr).floor.asInteger;
    chunk = FloatArray.newClear(sr.asInteger * sf.numChannels);
    energy = secs.collect {
        sf.readData(chunk);
        chunk.sum { |x| x * x }
    };
    sf.close;
    (0 .. (secs - dur).max(0)).do { |s|
        sum = energy.copyRange(s, (s + dur - 1).min(secs - 1)).sum;
        if(sum > bestSum) { bestSum = sum; best = s };
    };
    best
};

// [interleaved data, channels] of `numFrames` frames from `startFrame`.
readFrames = { |path, startFrame, numFrames|
    var sf = SoundFile.new, data, n;
    if(sf.openRead(path).not) { nil } {
        n = numFrames.min(sf.numFrames - startFrame);
        sf.seek(startFrame, 0);
        data = FloatArray.newClear(n * sf.numChannels);
        sf.readData(data);
        sf.close;
        [data, sf.numChannels]
    }
};

// Peak, RMS, crest factor and zero crossings per second of one channel.
// Distortion shows as more crossings and a changed crest factor; a plugin that
// passes audio through leaves both where they were.
chanStats = { |data, nch, c|
    var n = (data.size / nch).asInteger;
    var peak = 0, sum = 0, zc = 0, prev = 0, x, rms;
    n.do { |i|
        x = data[(i * nch) + c];
        peak = peak.max(x.abs);
        sum = sum + (x * x);
        if((x >= 0) != (prev >= 0)) { zc = zc + 1 };
        prev = x;
    };
    rms = (sum / n.max(1)).sqrt;
    (peak: peak, rms: rms, crestDb: if(rms > 0) { (peak / rms).ampdb } { 0 },
        zcr: zc / (n / rate))
};

// The level of channel `c` in consecutive windows of `win` frames, in dB.
windowDb = { |data, nch, c, win|
    var n = (data.size / nch).asInteger;
    var sum, x;
    (n / win).floor.asInteger.collect { |w|
        sum = 0;
        win.do { |i|
            x = data[(((w * win) + i) * nch) + c];
            sum = sum + (x * x);
        };
        (sum / win).sqrt.max(1e-9).ampdb
    }
};

// One non-realtime render of `dur` seconds: probe the plugin (writing its
// description to infoPath), start the synth, open the plugin in it, play the
// tap window through, looping it for renders longer than the window.
// Answers (said: scsynth's output, wall: seconds, cpu: user + sys seconds).
render = { |dur, outFile|
    var osc = tmpDir +/+ "spike.osc";
    var score = [
        [0.0, [\d_recv, def.asBytes]],
        [0.0, [\b_allocRead, 0, tapPath, (offset * rate).asInteger, (listenDur * rate).asInteger]],
        // VSTPlugin's own query message (what VSTPluginController:open sends
        // in realtime before /open), so the plugin is probed before it opens.
        [0.001, VSTPlugin.prQueryMsg(plugPath, infoPath)],
        [0.002, [\s_new, \saSpikeBias, 1000, 0, 0, \buf, 0]],
        [0.003, ctrl.openMsg(plugPath, editor: false)]
    ] ++ (presetPath !? { [[0.004, ctrl.readBankMsg(presetPath)]] } ?? { [] }) ++ [
        // Freed before the end, never left to the render's own cleanup: a
        // synth that owns memory and is still running when an NRT render ends
        // hangs scsynth 3.14.1 there for good (seen 2026-10-05 with DelayC,
        // PitchShift, LocalBuf), and no signal can end it until a reboot.
        [dur + 0.003, [\n_free, 1000]],
        [dur + 0.004, [\c_set, 0, 0]]
    ];
    var cmd, t, said, cpu = 0;
    Score(score).writeOSCFile(osc);
    // time(1) outside, so it measures scsynth itself; perl's alarm survives
    // the exec, so the watchdog signals scsynth and not some parent of it.
    // It cannot end a process stuck in its own cleanup (see the n_free above).
    cmd = "/usr/bin/time -p perl -e 'alarm shift; exec @ARGV' " ++ watchdogSec ++ " "
        ++ scsynth.quote ++ " -N " ++ osc.quote ++ " _ " ++ outFile.quote ++ " "
        ++ rate.asInteger ++ " WAV float -o 2 -i 0 2>&1";
    t = Main.elapsedTime;
    said = cmd.unixCmdGetStdOut;
    t = Main.elapsedTime - t;
    said.split($\n).do { |line|
        if(line.beginsWith("user ") or: { line.beginsWith("sys ") }) {
            cpu = cpu + line.split($ ).last.asFloat
        };
    };
    (said: said, wall: t, cpu: cpu)
};

// scsynth's chatter minus the boot banner, the score trace and time(1): what
// VSTPlugin and the plugin itself said.
reportScsynth = { |said|
    said.split($\n).do { |line|
        if(line.size > 0 and: {
            #["Found ", "Number of", "SuperCollider", "Using vector", "PublishPortToRendezvous",
                "start time", "nextOSCPacket", "real ", "user ", "sys ", "<CFData"]
                .any { |w| line.beginsWith(w) }.not
        }) { ("  scsynth: " ++ line).postln };
    };
};

// ---------------------------------------------------------------- set up --
tapPath = ~spikeTap ?? { (repo +/+ "sessions" +/+ "*-tap.wav").pathMatch.sort.last };
case
{ File.exists(scsynth).not } { fail.("scsynth not found at " ++ scsynth) }
{ \VSTPlugin.asClass.isNil } { fail.("VSTPlugin is not installed (no VSTPlugin class)") }
{ File.exists(plugPath).not } { fail.("no plugin at " ++ plugPath) }
{ tapPath.isNil or: { File.exists(tapPath).not } } { fail.("no dry tap to play (sessions/*-tap.wav)") };

if(failures == 0) {
    if(File.exists(tmpDir).not) { File.mkdir(tmpDir) };
    if(File.exists(outDir).not) { File.mkdir(outDir) };
    rate = SoundFile.use(tapPath, { |sf| sf.sampleRate });
    offset = loudestWindow.(tapPath, listenDur);
    stem = PathName(tapPath).fileNameWithoutExtension;
    outPath = outDir +/+ stem ++ "-biasfx"
        ++ (presetPath !? { "-" ++ PathName(presetPath).fileNameWithoutExtension } ? "") ++ ".wav";
    infoPath = tmpDir +/+ "plugin-info.ini";
    ("Plugin: " ++ plugPath ++ ", " ++ numChans ++ " in / " ++ numChans ++ " out").postln;
    ("Preset: " ++ (presetPath ? "none (the plugin's default sound)")).postln;
    ("Input:  " ++ tapPath ++ ", " ++ listenDur ++ " s from " ++ offset ++ " s, "
        ++ rate.asInteger ++ " Hz").postln;
    ("Host:   scsynth " ++ ("file -b " ++ scsynth.quote).unixCmdGetStdOut.split($\n).first
        ++ ", VSTPlugin " ++ [VSTPlugin.versionMajor, VSTPlugin.versionMinor,
            VSTPlugin.versionBugfix].join(".")).postln;

    def = SynthDef(\saSpikeBias, { |buf|
        var sig = PlayBuf.ar(1, buf, BufRateScale.kr(buf), loop: 1);
        var out = VSTPlugin.ar(sig ! numChans, numChans, id: \bias);
        Out.ar(0, if(numChans == 1) { out ! 2 } { out });
    });
    // A Server object only for node bookkeeping: nothing boots.
    server = Server(\saSpikeNrt, NetAddr("127.0.0.1", 57999),
        ServerOptions.new.numOutputBusChannels_(2).numInputBusChannels_(0));
    synth = Synth.basicNew(\saSpikeBias, server, 1000);
    ctrl = VSTPluginController(synth, synthDef: def);

    // ------------------------------------------------------------ render --
    "\n== short render (% s: probe + load) ==".format(shortDur).postln;
    File.delete(infoPath);
    shortRun = render.(shortDur, tmpDir +/+ "short.wav");
    reportScsynth.(shortRun[\said]);
    ("  wall % s, cpu % s".format(shortRun[\wall].round(0.01), shortRun[\cpu].round(0.01))).postln;
    if(shortRun[\wall] >= (watchdogSec - 1)) {
        fail.("scsynth hit the " ++ watchdogSec ++ " s watchdog: the plugin is waiting on something")
    };

    if(failures == 0) {
        if(File.exists(infoPath).not) {
            fail.("the probe wrote no description: VSTPlugin could not load the plugin");
        } {
            desc = File.use(infoPath, "r", { |f| VSTPluginDesc.prParse(CollStream(f.readAllString)) });
            "\n== plugin ==".postln;
            desc.print;
            // The first few only: an amp suite can expose hundreds.
            desc.parameters.keep(8).do { |p, i| ("  parameter " ++ i ++ ": " ++ p.name).postln };
            desc.programs.keep(8).do { |p, i| ("  program " ++ i ++ ": '" ++ p.name ++ "'").postln };
        };
    };

    if(failures == 0) {
        "\n== listening render (% s) ==".format(listenDur).postln;
        listenRun = render.(listenDur, outPath);
        ("  wall % s, cpu % s".format(listenRun[\wall].round(0.01), listenRun[\cpu].round(0.01))).postln;
        "\n== cost render (% s, the window looped) ==".format(costDur).postln;
        costRun = render.(costDur, tmpDir +/+ "cost.wav");
        ("  wall % s, cpu % s".format(costRun[\wall].round(0.01), costRun[\cpu].round(0.01))).postln;
        if(max(listenRun[\wall], costRun[\wall]) >= (watchdogSec - 1)) {
            fail.("scsynth hit the " ++ watchdogSec ++ " s watchdog: the plugin is waiting on something")
        };
    };

    // ----------------------------------------------------------- compare --
    if(failures == 0) {
        inData = readFrames.(tapPath, (offset * rate).asInteger, (listenDur * rate).asInteger);
        outData = readFrames.(outPath, 0, (listenDur * rate).asInteger);
        if(outData.isNil) { fail.("no rendered file at " ++ outPath) };
    };
    if(failures == 0) {
        inStats = chanStats.(inData[0], inData[1], 0);
        outStats = outData[1].collect { |c| chanStats.(outData[0], outData[1], c) };
        "\n== audio ==".postln;
        ([["in", inStats]] ++ outStats.collect { |s, i| [["out L", "out R"][i], s] }).do { |row|
            ("  %  peak %  rms %  crest % dB  crossings %/s".format(
                row[0].padRight(5), fmtDb.(row[1][\peak]).padLeft(9),
                fmtDb.(row[1][\rms]).padLeft(9), row[1][\crestDb].round(0.1),
                row[1][\zcr].round(1))).postln;
        };
        if(inStats[\peak] < 0.03) {
            ("  note: the tap peaks at " ++ fmtDb.(inStats[\peak])
                ++ ", a starved tap: BIAS FX heard a quiet guitar").postln;
        };
        if(inStats[\peak] > 0.99) {
            "  note: the tap reaches full scale: the guitar input may be clipping".postln;
        };
        // Per 100 ms: windows where the guitar plays but nothing comes out.
        inWin = windowDb.(inData[0], inData[1], 0, (rate / 10).asInteger);
        outWin = windowDb.(outData[0], outData[1], 0, (rate / 10).asInteger);
        muted = inWin.size.min(outWin.size).collect { |w|
            (inWin[w] > playingDb) and: { outWin[w] < mutedDb }
        }.count { |m| m };
        ("  muted while playing: % of % windows of 100 ms".format(
            muted, inWin.count { |db| db > playingDb })).postln;
        processed = (outStats[0][\rms] > 0.0003) and: {
            ((outStats[0][\crestDb] - inStats[\crestDb]).abs > 1)
            or: { ((outStats[0][\zcr] / inStats[\zcr].max(1)) - 1).abs > 0.2 }
            or: { ((outStats[0][\rms].ampdb) - (inStats[\rms].ampdb)).abs > 1 }
        };
        case
        { outStats[0][\rms] <= 0.0003 } { fail.("the output is silent") }
        { muted > 0 } { fail.("the output drops out while the guitar plays: demo mode or no license?") }
        { processed.not } { fail.("the output looks like the input: the plugin did not process") }
        { "  the output is processed audio".postln };
    };

    if(failures == 0) {
        perSec = (costRun[\cpu] - shortRun[\cpu]) / (costDur - shortDur);
        "\n== cost ==".postln;
        ("  % s of CPU per s of audio: about % % of one core".format(
            perSec.round(0.0001), (perSec * 100).round(0.1), "%")).postln;
        ("  (check: the 30 s render gives % %)".format(
            (((listenRun[\cpu] - shortRun[\cpu]) / (listenDur - shortDur)) * 100).round(0.1), "%")).postln;
        "  non-realtime, 64-sample blocks; under Rosetta if scsynth is x86_64".postln;
        ("\nListen: " ++ outPath).postln;
    };
    server.remove;
};

if(failures == 0) { "\nSPIKE PASS".postln } { "\nSPIKE FAILED".postln };
// Headless, exiting is essential: without it sclang idles forever. In the IDE
// it must NOT exit, which would kill the interpreter mid-session.
if(headless) { if(failures > 0) { 1.exit } { 0.exit } };
)
