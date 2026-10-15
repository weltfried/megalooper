// Megalooper SA, Phase 0 spike on the rig: BIAS FX 2 hosted by scsynth in
// realtime, guitar in, speakers out, no Live.
//
// Open in the SuperCollider IDE and evaluate the block (Cmd-Return). Quit Live
// first (or mute its guitar track), or you hear the guitar twice.
//
//     ~rigDevice = "TSMEGA";       // the CoreAudio device, in and out (default TSMEGA)
//     ~rigBuffer = 64;             // hardware buffer in frames; run 64, then 128
//     ~rigGuitarIn = 0;            // the guitar's input on that device
//     ~rigPreset = "/path/x.fxb";  // default: the first presets/sa/biasfx/*.fxb
//     ~rigStop.();                 // stop and free the spike's server (a new run
//                                  // does this itself before it boots)
//
// It runs on its own server (port 57140), so a megalooper session on the
// default server is left alone. It answers what the headless spike
// (spike-biasfx-nrt.scd) cannot:
//   1. does scsynth drive this device's outputs? Live cannot drive TSMEGA's
//      (docs/routing.md); silence or a crash here means SA needs an aggregate
//      with another output, the way the TSMega rig has one.
//   2. how long does BIAS FX take to load here, and does its editor open?
//   3. the latency the plugin reports, and the round trip it makes with
//      CoreAudio's figures for this device (tools/coreaudio.py latency).
//   4. how much of the audio callback it takes while you play (30 s).
//   5. does its state survive a save and a reload? SA's presets will do that.
// And the one only you can answer: does it feel and sound like Live?
//
// The plugin is the VST2 build, mono, loaded with the bank exported from the
// Live set, which is how the Live set hosts it.
(
var repo = thisProcess.nowExecutingPath !? { |p| p.dirname.dirname.dirname } ?? { Looper.repoRoot };
var device = ~rigDevice ? "TSMEGA";
var buffer = ~rigBuffer ? 64;
var guitarIn = ~rigGuitarIn ? 0;
var plugPath = "/Library/Audio/Plug-Ins/VST/BIAS FX 2.vst";
var presetPath = ~rigPreset ?? { (repo +/+ "presets" +/+ "sa" +/+ "biasfx" +/+ "*.fxb").pathMatch.sort.first };
var outDir = repo +/+ "sessions" +/+ "sa-spike";
var roundTripPath = outDir +/+ "rig-roundtrip.fxb";
var playSec = 30;
// Readings this early belong to the plugin settling after the preset loads,
// not to the playing; they are reported apart.
var settleSec = 2;
var coreAudio, server, synth, ctrl, cond, said, rate;
var loadSec, loaded = false, bankOk, saveOk, reloadOk, avg = List.new;
var peak = 0, peakAt, settlePeak = 0, alive = true;
var ms = { |frames| (frames * 1000 / (rate ? 48000)).round(0.01) };

// CoreAudio's own figures for the device at this buffer size. Also the check
// that the device is there at all: scsynth falls back to the default devices
// when the name is missing, and the MacBook's mic into an amp sim into its
// speakers is a feedback loop.
said = ("python3 " ++ (repo +/+ "tools" +/+ "coreaudio.py").quote ++ " latency "
    ++ device.quote ++ " --buffer " ++ buffer ++ " --json").unixCmdGetStdOut;
coreAudio = if(said.size > 2) { try { said.parseJSON } { nil } } { nil };

case
{ coreAudio.isNil } {
    ("SA RIG: no audio device matches \"" ++ device ++ "\". Connect it, or set ~rigDevice "
        ++ "(python3 tools/coreaudio.py list shows the names).").warn
}
// coreaudio.py also accepts a unique part of a name, and with the interface
// unplugged "TSMEGA" would land on the MegaLoop BH (TSMega) aggregate.
{ coreAudio["name"] != device } {
    ("SA RIG: \"" ++ device ++ "\" matched \"" ++ coreAudio["name"]
        ++ "\". Set ~rigDevice to the exact name you mean.").warn
}
{ \VSTPlugin.asClass.isNil } { "SA RIG: VSTPlugin is not installed.".warn }
{ presetPath.isNil } { "SA RIG: no preset; run python3 tools/export-live-set.py biasfx".warn }
{
    rate = coreAudio["rate"].asFloat;
    if(File.exists(outDir).not) { File.mkdir(outDir) };
    // A previous run's server holds the port until ~rigStop.() is called, and
    // a new one cannot boot beside it ("address in use"). Worse, the new Server
    // object then quietly attaches to the OLD process, so the run measures the
    // old buffer size. Stop whatever is there first: ours through ~rigStop, an
    // orphan (left behind by a class library recompile) with a plain /quit.
    ~rigStop !? { ~rigStop.() };
    NetAddr("127.0.0.1", 57140).sendMsg("/quit");
    Server.named[\saRig] !? { |old| old.remove };
    server = Server(\saRig, NetAddr("127.0.0.1", 57140));
    server.options.device = coreAudio["name"];
    server.options.hardwareBufferSize = buffer;
    server.options.sampleRate = rate;
    server.options.numInputBusChannels = 2;
    server.options.numOutputBusChannels = 2;
    ~rigServer = server;
    ~rigStop = { ~rigTask !? (_.stop); ~rigServer !? { |s| s.quit; s.remove }; ~rigServer = nil };

    // A second for the old process to let go of the port.
    { 1.wait; server.waitForBoot {
        // A clip, not Limiter: Limiter's lookahead delays the signal, which
        // is exactly what this spike measures.
        SynthDef(\saRigBias, { |in = 0, level = 0.5|
            var sig = VSTPlugin.ar(SoundIn.ar(in), 1, id: \bias);
            Out.ar(0, (sig * level).clip2(0.9) ! 2);
        }).add;
        server.sync;
        synth = Synth(\saRigBias, [\in, guitarIn], server);
        ctrl = VSTPluginController(synth);
        ~rigCtrl = ctrl;

        // 2. load time and editor
        cond = Condition.new;
        loadSec = Main.elapsedTime;
        ctrl.open(plugPath, editor: true, action: { |c, ok| loaded = ok; cond.unhang });
        cond.hang;
        loadSec = Main.elapsedTime - loadSec;
        if(loaded.not) {
            "SA RIG: BIAS FX did not open; see the post window above.".warn;
        } {
            cond = Condition.new;
            ctrl.readBank(presetPath, { |c, ok| bankOk = ok; cond.unhang });
            cond.hang;
            { ctrl.editor(true) }.defer;

            // 5. state round trip: what SA's own preset storage will rely on
            cond = Condition.new;
            ctrl.writeBank(roundTripPath, { |c, ok| saveOk = ok; cond.unhang });
            cond.hang;
            cond = Condition.new;
            ctrl.readBank(roundTripPath, { |c, ok| reloadOk = ok; cond.unhang });
            cond.hang;

            "\n== Megalooper SA rig spike ==".postln;
            ("device:  % at % Hz, buffer % frames".format(coreAudio["name"], rate.asInteger, buffer)).postln;
            ("plugin:  loaded in % s, editor %, preset % (%)".format(loadSec.round(0.1),
                if(ctrl.haveEditor) { "yes" } { "NO" },
                if(bankOk == true) { "loaded" } { "FAILED" },
                PathName(presetPath).fileName)).postln;
            ("latency: CoreAudio in % + out % frames, plugin % frames: round trip % frames = % ms".format(
                coreAudio["input"]["total"], coreAudio["output"]["total"], ctrl.latency ? 0,
                coreAudio["round_trip"].asInteger + (ctrl.latency ? 0),
                ms.(coreAudio["round_trip"].asInteger + (ctrl.latency ? 0)))).postln;
            ("state:   save %, reload %".format(
                if(saveOk == true) { "ok" } { "FAILED" },
                if(reloadOk == true) { "ok" } { "FAILED" })).postln;
            ("\nPlay now: % s of CPU readings follow. Silence means scsynth cannot drive "
                ++ "this device's outputs.").format(playSec).postln;

            // 4. the audio callback's load while the guitar plays. A server
            // that has gone stops reporting and its last figures stay put, so
            // readings stop with it rather than repeating stale numbers.
            ~rigTask = Routine {
                (playSec * 2).do { |i|
                    var t = (i + 1) / 2, p;
                    0.5.wait;
                    if(alive and: { server.serverRunning.not }) {
                        alive = false;
                        "SA RIG: the server stopped; no more CPU readings.".warn;
                    };
                    if(alive) {
                        p = server.peakCPU;
                        avg.add(server.avgCPU);
                        if(t <= settleSec) { settlePeak = settlePeak.max(p) } {
                            if(p > peak) { peak = p; peakAt = t };
                        };
                        if((i + 1) % 10 == 0) {
                            ("  % s: avg % %, peak % %".format(t,
                                server.avgCPU.round(0.1), "%", p.round(0.1), "%")).postln;
                        };
                    };
                };
                if(alive) {
                    ("cpu:     avg % %, peak % % at % s, of the audio callback over % s".format(
                        avg.mean.round(0.1), "%", peak.round(0.1), "%", peakAt, playSec)).postln;
                    ("         first % s, while the plugin settles: peak % %".format(
                        settleSec, settlePeak.round(0.1), "%")).postln;
                };
                ("\nKeep playing as long as you like; ~rigCtrl.editor to reopen the window, "
                    ++ "~rigStop.() to finish. To compare, set ~rigBuffer = 128; and evaluate "
                    ++ "the block again: it stops this run first.").postln;
            }.play(AppClock);
        };
    } }.fork(AppClock);
};
)
