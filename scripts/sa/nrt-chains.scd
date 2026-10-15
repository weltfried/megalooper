// Megalooper SA, device chains (docs/dev/device-chains.md, phases A and 1): the
// guitar chain and the loop chain AS MEGASA BUILDS THEM, a synth per device,
// rendered offline against verbatim copies of the chain SynthDefs the effects
// were built with before the chains became devices, sample for sample.
//
//     /Applications/SuperCollider.app/Contents/MacOS/sclang scripts/sa/nrt-chains.scd
//
// One score per scenario holds both sides at once:
//   - MegaSA's own tree: a real MegaSA built on a stub server that writes
//     every message into the score (as scripts/sa/nrt-drums.scd does), a
//     Looper fixture attached, so the loop's effects go where attachLooper
//     puts them. Whatever MegaSA makes of the chains (one synth each until
//     phase 1, a synth per device since) is what is rendered.
//   - The reference: \megaSAGuitarIn, \megaSAGuitarFx and \megaSALoopFx as
//     they were before the split, copied here under their own names: each
//     effect's slot in the Live set's order, written out here.
// The guitar is the loudest 8 s of the 29 Sep dry tap, as the hardware input
// (the render's input file). The loop is that window as a stereo signal (the
// right side 3 ms later), written onto each side's loop bus by a player
// synth. Both sides read their inputs from busses, as the real defs do: a
// UGen fed straight from a PlayBuf would start from another first value, and
// the Auto Filter's follower and the loop's effects then differ for their
// first 107-116 ms for that reason alone (device-chains.md, Appendix B).
//
// Scenarios, with the effects' randomness at 0 (the Delay's modulation depth,
// PitchLoop's Rand R, the Echo's wobble, Redux's jitter; the Auto Filter's
// wave stays Ramp Up), checked for 0 differing samples:
//   1. every effect of both chains on;
//   2. each effect alone, the guitar's and the loop's in turn;
// then, with the randomness on (the random UGens draw from a stream that every
// synth in the score shares, so two copies of one SynthDef differ too): the
// RMS of each side within 0.25 dB. Measured over 8 renders (2026-10-10): two
// copies of the one-synth guitar chain differ by up to 0.099 dB, the split
// chain from the one-synth one by up to 0.103 dB. A smoke test only: it sees
// a chain gone silent or blown up with the randomness on, not how much
// randomness there is (a break that sent the random settings 4-10x larger
// passed it; two random renders differ by nearly the signal's own level, so
// no statistic of one render tells them apart). The settings reaching each
// synth exactly is test-megasa's to check;
// then, with VSTPlugin installed, a plugin device that never opens (not
// ready): the guitar chain as if there were no plugin, sample for sample;
// and, if BIAS FX 2 (VST2) and a bank in presets/sa/biasfx are on this Mac,
// every guitar effect on into Bias FX with that bank, opened by score messages
// through MegaSA's pluginMaker, against the reference's own instance, from
// 1 s on (the plugins open while the first blocks run); Bias FX open with
// its device switched off: no plugin, sample for sample (the open's ready
// never undoes the player's off); and Bias FX open but never told it is
// ready (its bank still loading): no plugin either.
//
// Every synth is freed inside the score (a memory-owning synth still running
// when an NRT render ends hangs scsynth 3.14.1 for good). scsynth runs on a
// far UDP port, under a watchdog. Prints PASS or FAIL per check and NRT CHAINS
// PASSED at the end; exits 1 on any failure.
(
var sr = 48000, numOut = 10, numIn = 1, dur = 8.0;
// The real-time pool the \sa profile asks for (setup-routing.scd): scsynth's
// default 8 MB does not hold MegaSA's tree and the reference beside it, and a
// failed allocation silences or corrupts the effect that asked.
var memKB = 65536;
// A Server object for the VSTPluginControllers' bookkeeping only (they watch
// their synth's end through it): nothing boots, and no port is bound.
var bookServer;
var repo = (thisProcess.nowExecutingPath !? { |p| if(p[0] == $/) { p.dirname.dirname.dirname } }) ?? { Looper.repoRoot };
// Beside SuperCollider's resources on macOS, on the shell's path on Linux.
var scsynth = MegaSAPlugins.scsynthPath;
var tmpDir = (Platform.defaultTempDir ? "/tmp") +/+ "megalooper-sa"
    +/+ ("nrt-chains-" ++ Date.getDate.stamp ++ "-" ++ thisProcess.pid);
var takeTap = repo +/+ "sessions" +/+ "260929_100616-tap.wav";
var biasPath = "/Library/Audio/Plug-Ins/VST/BIAS FX 2.vst";
// Output channels: 0-1 SA's master (unused here), then the taps.
var chProdGuitar = 2, chProdLoop = 4, chRefGuitar = 6, chRefLoop = 8;
var fails = 0, passes = 0, skips = 0;
var check, skip, say, makeStub, buildScore, render, readAll, compare, rmsDb, loudest, writeWav;
var refDefs, scenario, runScenario, quiet, gIn, loopIn, offset, bank, allOn, across, blockOf, jump;

check = { |label, cond, detail|
    if(cond == true) { passes = passes + 1; ("  PASS  " ++ label).postln } {
        fails = fails + 1;
        ("  FAIL  " ++ label ++ (detail !? { |d| " — " ++ d } ? "")).postln;
    };
    cond == true
};
skip = { |label, why| skips = skips + 1; ("  SKIP  " ++ label ++ " — " ++ why).postln };
say = { |line| ("  " ++ line).postln };

// A stub server that writes every message into rig[\log] as [score time,
// [msg, ...]]. Node IDs count up from 2000; audio busses start after the
// render's outputs and inputs, as on scsynth.
makeStub = { |rig|
    var opts = ServerOptions.new.numOutputBusChannels_(numOut).numInputBusChannels_(numIn).memSize_(memKB);
    var srv = (sampleRate: sr, latency: 0.2, options: opts,
        controlBusAllocator: ContiguousBlockAllocator(16384),
        audioBusAllocator: ContiguousBlockAllocator(1024, 0, numOut + numIn),
        bufferAllocator: ContiguousBlockAllocator(1024));
    srv[\sendMsg] = { |self ... args| rig[\log].add([rig[\wall], [args]]); self };
    srv[\listSendMsg] = { |self, msg| rig[\log].add([rig[\wall], [msg.asArray]]); self };
    srv[\sendBundle] = { |self, time ... args| rig[\log].add([rig[\wall] + (time ? 0), args]); self };
    srv[\listSendBundle] = { |self, time, list| rig[\log].add([rig[\wall] + (time ? 0), list.asArray]); self };
    srv[\sync] = { |self| self };
    srv[\nextNodeID] = { |self| var id = (self[\lastNodeID] ? 1999) + 1; self[\lastNodeID] = id; id };
    srv[\nextBufferNumber] = { |self, n = 1| self[\bufferAllocator].alloc(n) };
    srv[\defaultGroup] = Group.basicNew(srv, 1);
    srv
};

// The score: every SynthDef a /s_new names, then every logged message in time
// order (sent order breaking ties), then a /g_freeAll for each of the root's
// groups before the end, which frees every synth there is.
buildScore = { |rig, endT|
    var entries = List.new, defs = IdentitySet.new, seq = 0, out, roots = List[1];
    rig[\log].do { |e|
        var msgs = e[1].reject { |m| (m[0] == \c_get) or: { m[0] == "/c_get" } };
        msgs.do { |m|
            if((m[0] == 9) or: { m[0] == \s_new } or: { m[0] == "/s_new" }) { defs.add(m[1].asSymbol) };
            // Groups added to the root, whatever the add action, are freed whole.
            if(m[0] == 21) { m.copyToEnd(1).clump(3).do { |t| if((t[2] == 0) or: { t[1] > 1 }) { roots.add(t[0]) } } };
        };
        if(msgs.notEmpty) { entries.add([e[0], seq, msgs]); seq = seq + 1 };
    };
    entries = entries.asArray.sort { |a, b| (a[0] < b[0]) or: { (a[0] == b[0]) and: { a[1] <= b[1] } } };
    out = defs.asArray.sort.collect { |n|
        var desc = SynthDescLib.global[n];
        if(desc.isNil) { Error("no SynthDef " ++ n).throw };
        [0.0, [\d_recv, desc.def.asBytes]]
    };
    out = out ++ entries.collect { |e| [e[0].max(0)] ++ e[2] };
    roots.asArray.reverse.do { |g| out = out.add([endT - 0.01, [\g_freeAll, g]]) };
    out.add([endT, [\c_set, 0, 0]])
};

render = { |name, score, endT|
    var osc = tmpDir +/+ name ++ ".osc", wav = tmpDir +/+ name ++ ".wav", cmd, said, sf, n, bad;
    var want = (endT * sr).floor.asInteger;
    Score(score).writeOSCFile(osc);
    cmd = "/usr/bin/time -p perl -e 'alarm shift; exec @ARGV' 600 " ++ scsynth.quote
        ++ " -u " ++ (58800 + 150.rand) ++ " -m " ++ memKB ++ " -N " ++ osc.quote ++ " " ++ gIn.quote ++ " " ++ wav.quote
        ++ " " ++ sr ++ " WAV float -o " ++ numOut ++ " -i " ++ numIn ++ " 2>&1";
    said = cmd.unixCmdGetStdOut;
    bad = said.split($\n).select { |line| line.contains("FAILURE") or: { line.contains("late ") }
        or: { line.contains("alloc") } or: { line.contains("memory") } };
    bad.do { |line| say.("scsynth: " ++ line) };
    File.delete(osc);
    sf = SoundFile.openRead(wav);
    n = sf !? { |f| var k = f.numFrames; f.close; k };
    if(n.isNil or: { n < want }) {
        Error(name ++ ": " ++ (n !? { |k| "a short render, " ++ k ++ " of " ++ want ++ " frames" } ? "no render")
            ++ " (scsynth: " ++ said.split($\n).reject(_.isEmpty).keep(-4).join(" | ") ++ ")").throw;
    };
    (wav: wav, bad: bad)
};

readAll = { |path|
    var sf = SoundFile.openRead(path), data;
    if(sf.isNil) { Error("no render at " ++ path).throw };
    data = FloatArray.newClear(sf.numFrames * sf.numChannels);
    sf.readData(data);
    sf.close;
    (data: data, frames: (data.size / numOut).asInteger)
};

// Two stereo taps, sample for sample from `from` to `to` (seconds, the end if
// nil): how many samples differ, the largest difference, the first frame that
// differs.
compare = { |res, chA, chB, from = 0, to|
    var d = res[\data], diffs = 0, maxD = 0, first, i = (from * sr).asInteger, a, b, x;
    var n = if(to.isNil) { res[\frames] } { (to * sr).asInteger.min(res[\frames]) };
    while { i < n } {
        2.do { |c|
            a = d[(i * numOut) + chA + c];
            b = d[(i * numOut) + chB + c];
            x = (a - b).abs;
            if(x > 0) { diffs = diffs + 1; if(first.isNil) { first = i } };
            if(x > maxD) { maxD = x };
        };
        i = i + 1;
    };
    (diffs: diffs, max: maxD, first: first, samples: (n - (from * sr).asInteger) * 2)
};

rmsDb = { |res, ch, from = 0|
    var d = res[\data], n = res[\frames], sum = 0, i = (from * sr).asInteger, k = 0, x;
    while { i < n } {
        2.do { |c| x = d[(i * numOut) + ch + c]; sum = sum + (x * x) };
        k = k + 2;
        i = i + 1;
    };
    (sum / k.max(1)).sqrt.max(1e-12).ampdb
};

// The start (seconds) of the loudest `secs` of a file, a second at a time.
loudest = { |path, secs|
    var sf = SoundFile.openRead(path), chunk, energy, best = 0, bestSum = -1, total;
    chunk = FloatArray.newClear(sr * sf.numChannels);
    total = (sf.numFrames / sr).floor.asInteger;
    energy = total.collect { sf.readData(chunk); chunk.sum { |x| x * x } };
    sf.close;
    (0 .. (total - secs).max(0)).do { |s|
        var sum = energy.copyRange(s, (s + secs - 1).min(total - 1)).sum;
        if(sum > bestSum) { bestSum = sum; best = s };
    };
    best
};

writeWav = { |path, data, chans|
    var sf = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(chans).sampleRate_(sr);
    if(sf.openWrite(path).not) { Error("cannot write " ++ path).throw };
    sf.writeData(data.as(FloatArray));
    sf.close;
    path
};

// ------------------------------------------------------------ reference --
// Today's two chain SynthDefs, as MegaSA.loadSynthDefs had them before the
// chains became devices, under names of their own: each effect in its slot,
// in the Live set's order, spelled out here rather than taken from
// MegaSAFx.guitarPre and loopChain, so that what MegaSA builds can change
// while the reference cannot. Only the effects' own DSP (MegaSAFx.shifter
// and the rest) and the slot are shared. The players put the loop input on a
// bus: in MegaSA's tree onto its loopBus, in the reference's onto one of its
// own.
refDefs = {
    var guitar = { |sig|
        sig = MegaSAFx.slot(sig, \shifterOn, MegaSAFx.shifter(sig));
        sig = MegaSAFx.slot(sig, \delayOn, MegaSAFx.delay(sig));
        sig = MegaSAFx.slot(sig, \filterOn, MegaSAFx.filter(sig));
        MegaSAFx.slot(sig, \pitchLoopOn, MegaSAFx.pitchLoop(sig))
    };
    var loop = { |sig|
        sig = MegaSAFx.slot(sig, \echoOn, MegaSAFx.echo(sig));
        sig = MegaSAFx.slot(sig, \saturatorOn, MegaSAFx.saturator(sig));
        MegaSAFx.slot(sig, \reduxOn, MegaSAFx.redux(sig))
    };
    SynthDef(\nrtChainsRefGuitarIn, { |in = 0, out|
        Out.ar(out, guitar.(SoundIn.ar(in)) ! 2);
    }).add;
    SynthDef(\nrtChainsRefGuitarFx, { |in = 0, out, bypass = 0|
        Out.ar(out, Sanitize.ar(\VSTPlugin.asClass.ar(guitar.(SoundIn.ar(in)), 1, bypass, id: \bias)) ! 2);
    }).add;
    SynthDef(\nrtChainsRefLoopFx, { |in, out|
        Out.ar(out, loop.(In.ar(in, 2)));
    }).add;
    SynthDef(\nrtChainsPlayer, { |buf, out|
        Out.ar(out, PlayBuf.ar(2, buf, BufRateScale.kr(buf)));
    }).add;
    SynthDef(\nrtChainsTap, { |in, out|
        Out.ar(out, In.ar(in, 2));
    }).add;
};

// What a scenario sets: on (effect key -> 0 or 1) and the randomness.
quiet = (delayModDepth: 0, pitchLoopRandL: 0, pitchLoopRandR: 0, echoWobble: 0, reduxJitter: 0);

// One scenario: MegaSA's tree and the reference in one score. `on`: the
// device ids switched on (\plugin1 among them for its plugin to be heard);
// `settings`: setting name -> value on top of the defaults; `plugin`: nil
// (none), \bias (Bias FX into the guitar chain, on both sides when \plugin1
// is on, else on MegaSA's alone), \biasUnready (Bias FX opened on MegaSA's
// side and never told it is ready) or \idle (a plugin device on MegaSA's
// side whose plugin never opens). `later`: { |sa| } answering [time, msg]
// pairs to put in MegaSA's side of the score. `edits`: [time, { |sa| }]
// pairs, chain edits made so that their first bundle lands at that time;
// `refAt`: [time, msg] pairs for the reference's synths (9001 the guitar's,
// 9003 the loop's).
runScenario = { |name, on, settings, plugin, later, edits, refAt, fromSound = false|
    var rig = (log: List.new, wall: 0.0);
    var stub = makeStub.(rig), sa, l, loopBuf, refG, refL, refGBus, refLBus, prodPlayer, refPlayer;
    var args, gArgs, lArgs, res, score, ctrlOf, refCtrl, refDef;
    var withBias = [\bias, \biasUnready].includes(plugin);
    var path = case { withBias } { biasPath } { plugin == \idle } { "/nowhere/Idle.vst" };
    var refBias = (plugin == \bias) and: { on.includes(\plugin1) };
    var snd;
    thisThread.seconds = 0;
    // `fromSound`: the switches and settings go in as a sound, written to
    // its text and read back, and MegaSA is built from that, as a boot
    // builds it from the kept sound; else they are set on the default chains.
    if(fromSound) {
        snd = MegaSASound.default(path !? { "plugin" });
        snd.devices.do { |d|
            d.put(\on, on.includes(d[\id]));
            d[\settings] !? { |own| settings.keysValuesDo { |k, v| if(own.includesKey(k)) { own.put(k, MegaSAFx.constrain(k, v)) } } };
        };
        snd = MegaSASound.parse(snd.fileString);
    };
    sa = MegaSA(stub, 0, 0, path, if(withBias) { bank }, snd);
    sa.instVarAt(\builder) !? { |r| r.stop };
    // Bias FX opened by score messages: VSTPlugin's query (it probes the
    // plugin before /open), the open, the bank, then the bypass off, as
    // MegaSAPlugin does once the bank is in. Its controller is the score's
    // only: nothing answers it.
    ctrlOf = { |synth, id|
        \VSTPluginController.asClass.new(Synth.basicNew(synth.defName, bookServer, synth.nodeID), id,
            synthDef: SynthDescLib.global[synth.defName.asSymbol].def)
    };
    if(withBias) {
        sa.pluginMaker = { |synth, id, pth|
            var c = ctrlOf.(synth, id);
            (state: \closed, name: "BIAS FX 2", bank: nil, loadSec: 0, latency: 0,
                open: { |self, bankFile, action|
                    rig[\log].add([0.001, [\VSTPlugin.asClass.prQueryMsg(pth, tmpDir +/+ "prod-query.ini")]]);
                    rig[\log].add([0.002, [c.openMsg(pth, editor: false)]]);
                    bankFile !? { |b| rig[\log].add([0.003, [c.readBankMsg(b)]]) };
                    if(plugin == \bias) { rig[\log].add([0.004, [[15, synth.nodeID] ++ MegaSAPlugin.readyArgs(true)]]) };
                    self[\state] = \open;
                    action.value(self, true);
                },
                bypass: { |self, flag| }, editor: { |self| }, loadBank: { |self, f, a| a.value(self, false) },
                saveBank: { |self, f, a| a.value(self, false) })
        };
    };
    // A plugin that never answers: its device stays not ready.
    if(plugin == \idle) {
        sa.pluginMaker = { |synth, id, pth|
            (state: \closed, name: "Idle", bank: nil, loadSec: 0, latency: 0, open: { |self, b, action| self[\state] = \opening },
                bypass: { |self, flag| }, editor: { |self| }, setTempo: { |self, bpm| })
        };
    };
    if(fromSound.not) {
        sa.devices.do { |d| sa.setFx(d.id, on.includes(d.id)) };
        settings.keysValuesDo { |k, v| sa.setFxParam(k, v) };
    };
    sa.prBuild;
    // The plugin's open, which MegaSA runs on a routine of its own after the
    // build: here at once, so its messages are in this score.
    sa.instVarAt(\opener) !? { |r| r.stop };
    sa.prOpenPlugin;
    // The Looper fixture, attached as on SA, so the loop's effects go where
    // attachLooper puts them. Its master is not made: the loop input is
    // played onto loopBus directly, at the head of the default group.
    l = ~tLooper.(sr);
    l.instVarPut(\server, stub);
    loopBuf = Buffer.new(stub, (dur * sr).asInteger, 2, stub.nextBufferNumber(1));
    rig[\log].add([0, [[\b_allocRead, loopBuf.bufnum, loopIn, 0, -1]]]);
    prodPlayer = Synth.head(stub[\defaultGroup], \nrtChainsPlayer, [\buf, loopBuf.bufnum, \out, sa.loopBus.index]);
    Routine { sa.attachLooper(l) }.next;
    // Every device has a node to reach, one /s_new in the score.
    check.(name ++ ": every device is in MegaSA's score, a synth each",
        (sa.devices.size == (MegaSAFx.keys.size + path.notNil.binaryValue)) and: {
        sa.devices.every { |d| var n = d.node; n.notNil and: {
            rig[\log].count { |e| e[1].count { |m| (m[0] == 9) and: { m[2] == n.nodeID } } > 0 } == 1 } } },
        sa.devices.collect { |d| [d.id, d.node] }.asString);
    later !? { |f| f.(sa).do { |e| rig[\log].add([e[0], [e[1]]]) } };
    // The reference, in a group of its own after everything MegaSA made,
    // with the switches and settings the scenario asks for, taken from the
    // scenario: read back from MegaSA, a switch it lost would be lost on both
    // sides, and every check would pass on two dry chains.
    refGBus = Bus.audio(stub, 2);
    refLBus = Bus.audio(stub, 4);
    args = { |keys| keys.collect { |k|
        [(k ++ "On").asSymbol, on.includes(k).binaryValue] ++ MegaSAFx.paramsOf(k).collect { |p|
            [p[\name], MegaSAFx.constrain(p[\name], settings[p[\name]] ? p[\spec].default)] }
    }.flat };
    check.(name ++ ": MegaSA holds the switches and settings asked for",
        MegaSAFx.keys.every { |k| (sa.fx(k) == on.includes(k)) and: { MegaSAFx.paramsOf(k).every { |p|
            sa.fxParam(p[\name]) == MegaSAFx.constrain(p[\name], settings[p[\name]] ? p[\spec].default) } } });
    gArgs = [\in, 0, \out, refGBus.index, \beatDur, sa.beatDur] ++ args.(MegaSAFx.guitarKeys);
    lArgs = [\in, refLBus.index, \out, refLBus.index + 2, \beatDur, sa.beatDur] ++ args.(MegaSAFx.loopKeys);
    rig[\log].add([0, [[21, 9000, 1, 0]]]);
    refDef = if(refBias) { \nrtChainsRefGuitarFx } { \nrtChainsRefGuitarIn };
    rig[\log].add([0, [[9, refDef, 9001, 1, 9000] ++ gArgs]]);
    rig[\log].add([0, [[9, \nrtChainsPlayer, 9002, 1, 9000, \buf, loopBuf.bufnum, \out, refLBus.index]]]);
    // The loop's reference reads refLBus and writes the two channels after it.
    rig[\log].add([0, [[9, \nrtChainsRefLoopFx, 9003, 1, 9000] ++ lArgs]]);
    if(refBias) {
        refCtrl = \VSTPluginController.asClass.new(Synth.basicNew(refDef, bookServer, 9001), \bias, synthDef: SynthDescLib.global[refDef].def);
        rig[\log].add([0.001, [\VSTPlugin.asClass.prQueryMsg(biasPath, tmpDir +/+ "ref-query.ini")]]);
        rig[\log].add([0.002, [refCtrl.openMsg(biasPath, editor: false)]]);
        rig[\log].add([0.003, [refCtrl.readBankMsg(bank)]]);
    };
    refAt !? { |list| list.do { |e| rig[\log].add([e[0], [e[1]]]) } };
    // The edits, after the check above: each made at the logical time that
    // puts its first bundle at its own.
    edits !? { |list|
        list.do { |e|
            rig[\wall] = e[0] - MegaSA.editLatency;
            thisThread.seconds = rig[\wall];
            e[1].(sa);
        };
        rig[\wall] = 0.0;
        thisThread.seconds = 0;
    };
    // The taps, last of all.
    rig[\log].add([0, [[21, 9100, 1, 0]]]);
    [[sa.guitarBus.index, chProdGuitar], [sa.loopFxBus.index, chProdLoop],
     [refGBus.index, chRefGuitar], [refLBus.index + 2, chRefLoop]].do { |p, i|
        rig[\log].add([0, [[9, \nrtChainsTap, 9101 + i, 1, 9100, \in, p[0], \out, p[1]]]]);
    };
    score = buildScore.(rig, dur);
    res = readAll.(render.(name, score, dur)[\wav]);
    sa.free;
    res
};

// ---------------------------------------------------------------- main --
{
    var res, c, gOn, lOn, rmsG, rmsL;
    case
    { File.exists(scsynth).not } { check.("scsynth is there", false, scsynth) }
    { File.exists(takeTap).not } { check.("the 29 Sep tap is there", false, takeTap) }
    {
        File.mkdir(tmpDir);
        (repo +/+ "scripts" +/+ "tests" +/+ "_harness.scd").load;
        MegaSA.loadSynthDefs;
        refDefs.();
        bookServer = Server(\nrtChainsBook, NetAddr("127.0.0.1", 58998),
            ServerOptions.new.numOutputBusChannels_(numOut).numInputBusChannels_(numIn));
        offset = loudest.(takeTap, dur.asInteger);
        // The guitar window as the render's input file, and the loop's
        // stereo window (the right side 3 ms later) for the players.
        {
            var sf = SoundFile.openRead(takeTap), mono, stereo, n = (dur * sr).asInteger, lag = (0.003 * sr).asInteger;
            mono = FloatArray.newClear(n);
            sf.seek((offset * sr).asInteger, 0);
            sf.readData(mono);
            sf.close;
            gIn = writeWav.(tmpDir +/+ "guitar-in.wav", mono, 1);
            stereo = FloatArray.newClear(n * 2);
            n.do { |i| stereo[i * 2] = mono[i]; stereo[(i * 2) + 1] = if(i >= lag) { mono[i - lag] } { 0 } };
            loopIn = writeWav.(tmpDir +/+ "loop-in.wav", stereo, 2);
        }.value;
        say.("input: the 29 Sep tap, " ++ dur ++ " s from " ++ offset ++ " s");

        "== every effect on, randomness at 0 ==".postln;
        res = runScenario.("all-on", MegaSAFx.keys, quiet);
        allOn = res;
        c = compare.(res, chProdGuitar, chRefGuitar);
        check.("the guitar chain is the reference's, sample for sample", c[\diffs] == 0,
            c[\diffs].asString ++ " of " ++ c[\samples] ++ " differ, max " ++ c[\max] ++ ", first frame " ++ c[\first]);
        c = compare.(res, chProdLoop, chRefLoop);
        check.("the loop chain is the reference's, sample for sample", c[\diffs] == 0,
            c[\diffs].asString ++ " of " ++ c[\samples] ++ " differ, max " ++ c[\max] ++ ", first frame " ++ c[\first]);
        check.("...and neither is silent", (rmsDb.(res, chProdGuitar) > -60) and: { rmsDb.(res, chProdLoop) > -60 },
            [rmsDb.(res, chProdGuitar), rmsDb.(res, chProdLoop)].asString);

        "== built from a sound ==".postln;
        res = runScenario.("from-sound", MegaSAFx.keys, quiet, nil, nil, nil, nil, true);
        c = compare.(res, chProdGuitar, chRefGuitar);
        check.("built from a sound's text, the guitar chain is the reference's, sample for sample", c[\diffs] == 0,
            c[\diffs].asString ++ " of " ++ c[\samples] ++ " differ, max " ++ c[\max] ++ ", first frame " ++ c[\first]);
        c = compare.(res, chProdLoop, chRefLoop);
        check.("...and the loop chain", c[\diffs] == 0,
            c[\diffs].asString ++ " of " ++ c[\samples] ++ " differ, max " ++ c[\max] ++ ", first frame " ++ c[\first]);
        check.("...and neither is silent", (rmsDb.(res, chProdGuitar) > -60) and: { rmsDb.(res, chProdLoop) > -60 },
            [rmsDb.(res, chProdGuitar), rmsDb.(res, chProdLoop)].asString);

        "== each effect alone ==".postln;
        4.do { |i|
            gOn = MegaSAFx.guitarKeys[i];
            lOn = MegaSAFx.loopKeys[i];
            res = runScenario.("alone-" ++ i, [gOn, lOn].reject(_.isNil), quiet);
            c = compare.(res, chProdGuitar, chRefGuitar);
            check.(gOn ++ " alone, guitar chain", c[\diffs] == 0,
                c[\diffs].asString ++ " differ, max " ++ c[\max] ++ ", first frame " ++ c[\first]);
            lOn !? {
                c = compare.(res, chProdLoop, chRefLoop);
                check.(lOn ++ " alone, loop chain", c[\diffs] == 0,
                    c[\diffs].asString ++ " differ, max " ++ c[\max] ++ ", first frame " ++ c[\first]);
            };
        };

        "== every effect on, randomness on ==".postln;
        res = runScenario.("random", MegaSAFx.keys, ());
        rmsG = [rmsDb.(res, chProdGuitar), rmsDb.(res, chRefGuitar)];
        rmsL = [rmsDb.(res, chProdLoop), rmsDb.(res, chRefLoop)];
        check.("the guitar chain's RMS is the reference's within 0.25 dB", (rmsG[0] - rmsG[1]).abs <= 0.25, rmsG.asString);
        check.("the loop chain's RMS is the reference's within 0.25 dB", (rmsL[0] - rmsL[1]).abs <= 0.25, rmsL.asString);

        "== chain edits ==".postln;
        // NRT carries out a bundle at the start of the block its time falls
        // in: a window ends at the block before an edit's second bundle.
        blockOf = { |secs| ((secs * sr) / 64).floor * 64 / sr };
        // The largest jump between two samples of the loop chain's output in
        // a window: a click shows as one larger than the signal's own.
        jump = { |res, a, b, tap = (chProdLoop)| var d = res[\data], m = 0, i = (a * sr).asInteger + 1;
            while { i < (b * sr).asInteger } { 2.do { |ch| m = m.max((d[(i * numOut) + tap + ch]
                - d[((i - 1) * numOut) + tap + ch]).abs) }; i = i + 1 };
            m };
        // A remove switches the device off and parks it a fade later, by
        // which time its slot passes the chain through exactly (XFade2's pan
        // is quantized: past 36 ms of the 30 ms fade it is fully dry): the
        // same, sample for sample, as its footswitch off.
        res = runScenario.("remove", MegaSAFx.keys, quiet, nil, nil,
            [[3.0, { |sa| sa.removeDevice(\saturator) }]], [[3.0, [15, 9003, \saturatorOn, 0]]]);
        c = compare.(res, chProdLoop, chRefLoop);
        check.("a remove is its device's footswitch off, sample for sample", c[\diffs] == 0,
            c[\diffs].asString ++ " of " ++ c[\samples] ++ " differ, max " ++ c[\max] ++ ", first frame " ++ c[\first]);
        // A device that is off moves at once, and changes nothing: within
        // its chain, and to the other one (the Shifter onto the loop).
        res = runScenario.("move-off", MegaSAFx.keys.reject { |k| [\saturator, \shifter].includes(k) }, quiet, nil, nil,
            [[3.0, { |sa| sa.moveDevice(\saturator, \loop, 2) }], [4.0, { |sa| sa.moveDevice(\shifter, \loop, 0) }]]);
        c = compare.(res, chProdLoop, chRefLoop);
        check.("moving a device that is off changes nothing, sample for sample", c[\diffs] == 0,
            c[\diffs].asString ++ " of " ++ c[\samples] ++ " differ, max " ++ c[\max] ++ ", first frame " ++ c[\first]);
        c = compare.(res, chProdGuitar, chRefGuitar);
        check.("...nor the chain it left", c[\diffs] == 0,
            c[\diffs].asString ++ " of " ++ c[\samples] ++ " differ, max " ++ c[\max] ++ ", first frame " ++ c[\first]);
        // An insert fades a new device in: its synth made switched off, its
        // switch birthGap later in a bundle of its own (a switch in the
        // s_new's bundle would start its Lag on: wet from the first sample).
        // Until that switch, the chain without it; then its footswitch on,
        // but from a cold start: its filters' state is new. Measured
        // 2026-10-10: -24 dB away in its first 0.1 s, under -160 dB after,
        // exact from 0.5 s.
        res = runScenario.("insert", MegaSAFx.keys.reject { |k| k == \saturator }, quiet, nil, nil,
            [[0.1, { |sa| sa.removeDevice(\saturator) }], [3.0, { |sa| sa.insertDevice(\loop, 1, \saturator) }]],
            [[3.0 + MegaSA.birthGap, [15, 9003, \saturatorOn, 1]]]);
        c = compare.(res, chProdLoop, chRefLoop, 0, blockOf.(3.0 + MegaSA.birthGap));
        check.("until an insert's switch, the chain without the device, sample for sample: its synth made off, dry",
            c[\diffs] == 0, c[\diffs].asString ++ " differ, first frame " ++ c[\first]);
        c = compare.(res, chProdLoop, chRefLoop, 3.1);
        check.("...from 0.1 s after it, its footswitch on to within -120 dB", c[\max] < -120.dbamp,
            c[\max].max(1e-12).ampdb.round(0.1).asString ++ " dB");
        // (The saturator's own edge is bigger than the dry loop's: the
        // reference, its footswitch going on at the same moment, has it too.)
        check.("...and no click as it comes in: no larger a jump than the footswitch's",
            jump.(res, 2.99, 3.2) <= (jump.(res, 2.99, 3.2, chRefLoop) * 1.01),
            [jump.(res, 2.99, 3.2), jump.(res, 2.99, 3.2, chRefLoop)].asString);
        say.("insert: " ++ compare.(res, chProdLoop, chRefLoop, 3.0, 3.1)[\max].max(1e-12).ampdb.round(0.1)
            ++ " dB from the footswitch in its first 0.1 s");
        // Undo of a remove: the device freed at the remove, built anew,
        // empty, at the undo, as an insert is: its synth made switched off,
        // its switch birthGap later.
        res = runScenario.("undo-remove", MegaSAFx.keys, quiet, nil, nil,
            [[2.0, { |sa| sa.removeDevice(\saturator) }], [4.0, { |sa| sa.undo }]],
            [[2.0, [15, 9003, \saturatorOn, 0]], [4.0 + MegaSA.birthGap, [15, 9003, \saturatorOn, 1]]]);
        c = compare.(res, chProdLoop, chRefLoop, 0, blockOf.(4.0 + MegaSA.birthGap));
        check.("until the undo's switch, the remove is its footswitch off, sample for sample", c[\diffs] == 0,
            c[\diffs].asString ++ " differ, first frame " ++ c[\first]);
        say.("undo-remove: " ++ compare.(res, chProdLoop, chRefLoop, 4.0, 4.1)[\max].max(1e-12).ampdb.round(0.1)
            ++ " dB from the footswitch in its first 0.1 s");
        c = compare.(res, chProdLoop, chRefLoop, 4.1);
        check.("...from 0.1 s after the undo, its footswitch on again to within -120 dB", c[\max] < -120.dbamp,
            c[\max].max(1e-12).ampdb.round(0.1).asString ++ " dB");
        // A move of a device that is on: off, moved a fade later, on again.
        res = runScenario.("move-on", MegaSAFx.keys, quiet, nil, nil,
            [[3.0, { |sa| sa.moveDevice(\saturator, \loop, 2) }]], [[3.0, [15, 9003, \saturatorOn, 0]]]);
        c = compare.(res, chProdLoop, chRefLoop, 0, blockOf.(3.0 + MegaSA.fadeTime));
        check.("a move of a device that is on: until it is moved, its footswitch off, sample for sample", c[\diffs] == 0,
            c[\diffs].asString ++ " differ, first frame " ++ c[\first]);
        check.("...and no click around the move", jump.(res, 2.99, 3.2) <= jump.(res, 2.0, 2.99),
            [jump.(res, 2.0, 2.99), jump.(res, 2.99, 3.2)].asString);

        "== a plugin device not ready ==".postln;
        if(\VSTPlugin.asClass.isNil) { skip.("a plugin device not ready", "VSTPlugin is not installed") } {
            res = runScenario.("idle", MegaSAFx.keys ++ [\plugin1], quiet, \idle);
            c = compare.(res, chProdGuitar, chRefGuitar);
            check.("a plugin device on but not ready passes the guitar chain through, sample for sample", c[\diffs] == 0,
                c[\diffs].asString ++ " of " ++ c[\samples] ++ " differ, max " ++ c[\max] ++ ", first frame " ++ c[\first]);
        };

        "== into Bias FX ==".postln;
        bank = [repo +/+ "presets" +/+ "sa" +/+ "biasfx" +/+ "current.fxb"]
            .detect { |p| File.exists(p) } ?? { (repo +/+ "presets" +/+ "sa" +/+ "biasfx" +/+ "*.fxb").pathMatch.sort.first };
        case
        { \VSTPlugin.asClass.isNil } { skip.("Bias FX", "VSTPlugin is not installed") }
        { File.exists(biasPath).not } { skip.("Bias FX", "no plugin at " ++ biasPath) }
        { bank.isNil } { skip.("Bias FX", "no bank in presets/sa/biasfx") }
        {
            res = runScenario.("bias", MegaSAFx.guitarKeys ++ [\plugin1], quiet, \bias);
            c = compare.(res, chProdGuitar, chRefGuitar, 1.0);
            check.("every guitar effect into Bias FX, its bank in, is the reference's from 1 s on", c[\diffs] == 0,
                c[\diffs].asString ++ " of " ++ c[\samples] ++ " differ, max " ++ c[\max] ++ ", first frame " ++ c[\first]);
            // The same effects with no plugin, from the first scenario: had
            // Bias FX passed the guitar through, the two would be one signal.
            across = {
                var d1 = res[\data], d2 = allOn[\data], n = res[\frames].min(allOn[\frames]), i = sr, k = 0, x;
                while { i < n } {
                    2.do { |c| x = d1[(i * numOut) + chProdGuitar + c] - d2[(i * numOut) + chProdGuitar + c];
                        if(x != 0) { k = k + 1 } };
                    i = i + 1;
                };
                k / ((n - sr) * 2).max(1)
            }.value;
            check.("...and Bias FX played: not the same effects without it (most samples differ)", across > 0.9,
                across.round(0.001).asString ++ " of the samples differ");
            // Bias FX opens and is told it is ready, but the player switched
            // its device off: what is heard is the chain without it. At 4 s
            // the player switches it on, and from then on it is heard: so it
            // was open and playing all along, not missing.
            res = runScenario.("bias-off", MegaSAFx.guitarKeys, quiet, \bias,
                { |sa| [[4.0, [15, sa.fxNode(\plugin1).nodeID, \on, 1]]] });
            c = compare.(res, chProdGuitar, chRefGuitar, 0, 4.0);
            check.("Bias FX open, its device switched off: the guitar chain without it, sample for sample", c[\diffs] == 0,
                c[\diffs].asString ++ " of " ++ c[\samples] ++ " differ, max " ++ c[\max] ++ ", first frame " ++ c[\first]);
            c = compare.(res, chProdGuitar, chRefGuitar, 4.1);
            check.("...and switched on at 4 s it is heard", (c[\diffs] / c[\samples].max(1)) > 0.9,
                c[\diffs].asString ++ " of " ++ c[\samples] ++ " differ");
            // Open, its device on, but not ready: what VSTPlugin's own
            // pass-through cannot stand in for, since Bias FX is processing.
            // Told it is ready at 4 s, it is heard from then on.
            res = runScenario.("bias-unready", MegaSAFx.guitarKeys ++ [\plugin1], quiet, \biasUnready,
                { |sa| [[4.0, [15, sa.fxNode(\plugin1).nodeID] ++ MegaSAPlugin.readyArgs(true)]] });
            c = compare.(res, chProdGuitar, chRefGuitar, 0, 4.0);
            check.("Bias FX open, its device on but not told it is ready: the guitar chain without it, sample for sample",
                c[\diffs] == 0,
                c[\diffs].asString ++ " of " ++ c[\samples] ++ " differ, max " ++ c[\max] ++ ", first frame " ++ c[\first]);
            c = compare.(res, chProdGuitar, chRefGuitar, 4.0 + (64 / sr));
            check.("...and told it is ready at 4 s it is heard within a block", (c[\diffs] / c[\samples].max(1)) > 0.9,
                c[\diffs].asString ++ " of " ++ c[\samples] ++ " differ");
        };
    };
}.try { |err|
    check.("the run finished", false, err.class.asString ++ ": " ++ (err.errorString ? "?"));
};

(tmpDir +/+ "*").pathMatch.do { |p| File.delete(p) };
File.delete(tmpDir);
"".postln;
(passes.asString ++ " passed, " ++ fails ++ " failed" ++ if(skips > 0) { ", " ++ skips ++ " skipped" } { "" }).postln;
if(fails == 0) { "NRT CHAINS PASSED".postln; 0.exit } { "NRT CHAINS FAILED".postln; 1.exit };
)
