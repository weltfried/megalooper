// Megalooper SA's device chains (docs/dev/device-chains.md, phase 1): the type
// table, the device SynthDefs and the rules every one of them keeps, the
// devices and chains as models, and the chains as MegaSA builds them on a
// recording stub: the tree, what each synth starts with, a new Looper's
// chain, the tempo, the plugin's two switches. How the chains sound is
// scripts/sa/nrt-chains.scd's to check: the split chains against the one-synth
// chains they replaced, sample for sample.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-megasa-chains");

{
var types = MegaSAFx.types;
var vst = \VSTPlugin.asClass;
var fingerprint, baseline, ctlName, dependsOn, outsOf, fadesOf, deviceDescs, pluginDescs, d, p, c, b, t, sa, stub, l, l2;
var fake, gIds, lIds, before, sent, oldGroup, oldNodes, args, heard, said, n, made, m, srv;
var calls, pending, bankAction, late, plug, lats, dev, sent2;

// ---------------------------------------------------------- the types --
~tEq.("a type per effect, in chain order", types.collect(_[\key]), MegaSAFx.keys);
~tEq.("the guitar's types are built for the guitar chain, the loop's for the loop's",
    types.collect(_[\track]), MegaSAFx.guitarKeys.collect { \guitar } ++ MegaSAFx.loopKeys.collect { \loop });
~tEq.("the guitar's are written mono, the loop's stereo",
    types.collect(_[\width]), MegaSAFx.guitarKeys.collect { \mono } ++ MegaSAFx.loopKeys.collect { \stereo });
~tAssert.("each has its title, a blurb and its switch, <key>On",
    types.every { |t| (t[\title] == MegaSAFx.title(t[\key])) and: { t[\blurb].size > 20 }
        and: { t[\switch] == (t[\key] ++ "On").asSymbol } and: { MegaSAFx.type(t[\key]) === t } });
~tAssert.("a folded panel's knobs are settings of the type's own",
    types.every { |t| t[\mainKnobs].notEmpty and: { t[\mainKnobs].every { |k|
        (MegaSAFx.param(k) !? { |q| q[\fx] == t[\key] }) == true } } },
    types.collect { |t| t[\key] -> t[\mainKnobs] }.asString);
~tEq.("the types with delay lines or buffers take memory, the others none",
    types.select { |t| t[\memBytes].value(48000) > 0 }.collect(_[\key]), [\shifter, \delay, \pitchLoop, \echo]);
~tEq.("...the Delay's four 2.7 s lines at 48 kHz, 512 KB each, as scsynth rounds them",
    MegaSAFx.type(\delay)[\memBytes].value(48000), 4 * 524288);
~tAssert.("...twice that at 96 kHz",
    MegaSAFx.type(\delay)[\memBytes].value(96000) == (2 * MegaSAFx.type(\delay)[\memBytes].value(48000)));
~tEq.("the Shifter delays 2 samples at its default, as measured", MegaSAFx.type(\shifter)[\latency].value((), 48000), 2);
~tNear.("...about 10 ms at +7 st in Grain, its 40 ms window", MegaSAFx.type(\shifter)[\latency].value((shifterCoarse: 7, shifterCents: 0), 48000),
    0.01 * 48000, 10);
~tEq.("...and a 1024-frame FFT frame in FFT mode, whatever the shift",
    [0, 7, -12].collect { |st| MegaSAFx.type(\shifter)[\latency].value((shifterCoarse: st, shifterCents: 0, shifterMode: 1), 48000) },
    [1024, 1024, 1024]);
~tAssert.("...and as much down as up a ratio's distance: more at +12 than at -12",
    MegaSAFx.type(\shifter)[\latency].value((shifterCoarse: 12), 48000)
        > MegaSAFx.type(\shifter)[\latency].value((shifterCoarse: -12), 48000));
~tAssert.("the other types delay nothing, whatever their settings",
    types.reject { |t| t[\key] == \shifter }.every { |t|
        [t[\latency].value((), 48000), t[\latency].value(MegaSAFx.defaults, 96000)] == [0, 0] });

// ------------------------------------------------- the device SynthDefs --
MegaSA.loadSynthDefs;
// The control a graph input reads, by name, or nil if it reads none.
ctlName = { |def, input|
    var i;
    if(input.isKindOf(OutputProxy) and: { input.source.isKindOf(Control) }) {
        i = input.source.specialIndex + input.outputIndex;
        def.allControlNames.detect { |cn| cn.index == i } !? { |cn| cn.name.asSymbol }
    }
};
// The controls a graph input depends on, through every UGen it reads, sorted.
dependsOn = { |def, input|
    var found = IdentitySet.new, seen = IdentitySet.new, walk;
    walk = { |x|
        var name = ctlName.(def, x), src = if(x.isKindOf(OutputProxy)) { x.source } { x };
        case
        { name.notNil } { found.add(name) }
        { src.isKindOf(UGen) and: { seen.includes(src).not } } { seen.add(src); (src.inputs ? []).do(walk) };
    };
    walk.(input);
    found.asArray.sort
};
// Every UGen of a graph that writes a bus (LocalOut writes the synth's own,
// which the Delay and the Echo feed back through).
outsOf = { |def| def.children.select { |u| u.isKindOf(AbstractOut) and: { u.isKindOf(LocalOut).not } } };
deviceDescs = MegaSAFx.keys.collect { |k| SynthDescLib.global[MegaSAFx.deviceDefName(k)] };
pluginDescs = if(vst.isNil) { [] } {
    MegaSAPlugin.layouts.collect { |io| SynthDescLib.global[MegaSAPlugin.defName(io[0], io[1])] }
};
~tAssert.("a SynthDef per type, named after it", deviceDescs.every(_.notNil)
    and: { deviceDescs.collect { |x| x.name.asSymbol } == [\megaSADevShifter, \megaSADevDelay, \megaSADevFilter,
        \megaSADevPitchLoop, \megaSADevEcho, \megaSADevSaturator, \megaSADevRedux] });
if(vst.isNil) { ~tSkip.("the plugin devices' SynthDefs", "VSTPlugin is not installed here") } {
    ~tAssert.("a plugin device's SynthDef per layout, 1->1, 1->2, 2->1, 2->2", pluginDescs.every(_.notNil),
        pluginDescs.asString);
};
// The rules every device keeps (device-chains.md, section 5), the built-ins',
// the pass-through's and the plugins'.
(deviceDescs ++ [SynthDescLib.global[\megaSADevNull]] ++ pluginDescs).reject(_.isNil).do { |desc|
    var def = desc.def, name = desc.name;
    var outs = outsOf.(def), ins = def.children.select { |u| [In, InFeedback].includes(u.class) };
    var plugs = if(vst.isNil) { [] } { def.children.select { |u| u.isKindOf(vst) } };
    ~tAssert.(name ++ " writes its chain's bus with ReplaceOut, once, and nothing else: Out would add to it",
        (outs.size == 1) and: { outs[0].class == ReplaceOut } and: { ctlName.(def, outs[0].inputs[0]) == \bus }
            and: { (outs[0].inputs.size - 1) == 2 },
        outs.collect { |u| u.class.name ++ "(" ++ ctlName.(def, u.inputs[0]) ++ ")" }.asString);
    ~tAssert.(name ++ " reads that bus once, both sides",
        (ins.size == 1) and: { ins[0].class == In } and: { ctlName.(def, ins[0].inputs[0]) == \bus }
            and: { ins[0].channels.size == 2 },
        ins.collect { |u| u.class.name }.asString);
    ~tAssert.(name ++ " starts off: a device made without its switch passes its chain through",
        desc.controls.select { |x| [\on, \ready].includes(x.name.asSymbol)
            or: { x.name.asString.endsWith("On") } }.every { |x| x.defaultValue == 0 }
            and: { desc.controls.any { |x| x.name.asSymbol == \bus } },
        desc.controls.collect { |x| x.name -> x.defaultValue }.asString);
    plugs.do { |u|
        var readers = def.children.select { |x| (x.inputs ? []).any { |i|
            (i === u) or: { i.isKindOf(OutputProxy) and: { i.source === u } } } };
        ~tAssert.(name ++ ": what its VSTPlugin puts out goes through Sanitize before anything hears it",
            readers.notEmpty and: { readers.every { |x| x.class == Sanitize } },
            readers.collect { |x| x.class.name }.asString);
    };
};
MegaSAFx.keys.do { |k|
    var desc = SynthDescLib.global[MegaSAFx.deviceDefName(k)];
    var names = desc !? { |x| x.controlNames.collect(_.asSymbol) } ? [];
    var want = [\bus, MegaSAFx.switchName(k)] ++ MegaSAFx.paramsOf(k).collect(_[\name])
        ++ if(MegaSAFx.type(k)[\followsTempo]) { [\beatDur] } { [] };
    ~tEq.(k ++ "'s device has its bus, its switch, its settings and, if it follows the tempo, the beat: no other control",
        names.asSet, want.asSet);
};
// Each device's cross-fade, what it writes to each side: dry against wet on
// its switch alone. A plugin's on the player's switch times the plugin's
// readiness, its dry path delayed by the latency, its wet path the plugin's.
// (An effect may cross-fade inside, as the Auto Filter's morph does.)
fadesOf = { |def| (outsOf.(def).first !? { |o| o.inputs.copyToEnd(1) } ? []).select { |u| u.class == XFade2 } };
MegaSAFx.keys.do { |k|
    var def = SynthDescLib.global[MegaSAFx.deviceDefName(k)] !? (_.def);
    var fades = def !? { |x| fadesOf.(x) } ? [];
    ~tAssert.(k ++ "'s device cross-fades both sides on its own switch, and nothing else",
        (fades.size == 2) and: { fades.every { |u| dependsOn.(def, u.inputs[2]) == [MegaSAFx.switchName(k)] } }
            and: { fades.every { |u| dependsOn.(def, u.inputs[0]) == [\bus] } },
        fades.collect { |u| [dependsOn.(def, u.inputs[0]), dependsOn.(def, u.inputs[2])] }.asString);
};
// The types that sleep (MegaSAFx.sleepWhenFaded): their synth pauses itself
// once switched off and faded, on its switch alone. The others, which
// remember what they play, never pause.
~tEq.("the types that sleep while off: Envelope Filter, Drive and Crusher",
    MegaSAFx.keys.select { |k| MegaSAFx.type(k)[\sleeps] == true }, [\filter, \saturator, \redux]);
MegaSAFx.keys.do { |k|
    var def = SynthDescLib.global[MegaSAFx.deviceDefName(k)] !? (_.def);
    var pauses = def !? { |x| x.children.select { |u| u.class == PauseSelf } } ? [];
    if(MegaSAFx.type(k)[\sleeps] == true) {
        ~tAssert.(k ++ "'s synth pauses itself, on its switch alone",
            (pauses.size == 1) and: { dependsOn.(def, pauses[0].inputs[0]) == [MegaSAFx.switchName(k)] },
            pauses.collect { |u| dependsOn.(def, u.inputs[0]) }.asString);
    } {
        ~tEq.(k ++ "'s synth never pauses itself", pauses.size, 0);
    };
};
// The width rule: the dry path is the two sides as they came, each to its
// own; a mono type's one effect, heard from (L + R) / 2, goes to both; a
// stereo type's sides are each their own. (On the dual-mono guitar chain a
// render cannot tell these apart, so the graph is read.)
MegaSAFx.keys.do { |k|
    var def = SynthDescLib.global[MegaSAFx.deviceDefName(k)] !? (_.def);
    var fades = def !? { |x| fadesOf.(x) } ? [];
    var inn = def !? { |x| x.children.detect { |u| u.class == In } };
    var sum = def !? { |x| x.children.detect { |u| u.isKindOf(BinaryOpUGen) and: { u.operator == '+' }
        and: { inn.notNil } and: { (u.inputs[0] === inn.channels[0]) and: { u.inputs[1] === inn.channels[1] } } } };
    var half = sum !? { def.children.detect { |u| u.isKindOf(BinaryOpUGen) and: { u.operator == '*' }
        and: { u.inputs[0] === sum } and: { u.inputs[1] == 0.5 } } };
    ~tAssert.(k ++ "'s dry path is the two sides as they came, each to its own side",
        (fades.size == 2) and: { inn.notNil } and: { fades.every { |u, i| u.inputs[0] === inn.channels[i] } });
    if(MegaSAFx.type(k)[\width] == \mono) {
        ~tAssert.(k ++ " is mono: it hears (L + R) / 2 and writes its one effect to both sides",
            (fades.size == 2) and: { fades[0].inputs[1] === fades[1].inputs[1] } and: { half.notNil });
    } {
        ~tAssert.(k ++ " is stereo: each side its own", (fades.size == 2) and: { fades[0].inputs[1] !== fades[1].inputs[1] });
    };
};
pluginDescs.reject(_.isNil).do { |desc|
    var fades = fadesOf.(desc.def);
    ~tAssert.(desc.name ++ " cross-fades on the player's switch times the plugin's readiness: an open never undoes an off",
        (fades.size == 2) and: { fades.every { |u| dependsOn.(desc.def, u.inputs[2]) == [\on, \ready] } },
        fades.collect { |u| dependsOn.(desc.def, u.inputs[2]) }.asString);
    // The lags on the way to that cross-fade: the player's switch's alone.
    ~tAssert.("...the player's switch fading over a lag, the plugin's readiness switching within a block (no lag on it)",
        fades.notEmpty and: { fades.every { |u|
            var lags = List.new, seen = IdentitySet.new, walk;
            walk = { |x| var src = if(x.isKindOf(OutputProxy)) { x.source } { x };
                if(src.isKindOf(UGen) and: { seen.includes(src).not }) {
                    seen.add(src);
                    if([Lag, Lag2, Lag3, LagUD, Lag2UD, Lag3UD, VarLag, Ramp].any { |c| src.isKindOf(c) }) { lags.add(src) };
                    (src.inputs ? []).do(walk) } };
            walk.(u.inputs[2]);
            lags.notEmpty and: { lags.every { |g| dependsOn.(desc.def, g.inputs[0]) == [\on] } }
        } });
    ~tAssert.("...its dry path each side of the bus as it came (or delayed by the latency)",
        (fades.size == 2) and: { desc.def.children.detect { |u| u.class == In } !? { |inn|
            fades.every { |u, i| (u.inputs[0].class == Select) and: { u.inputs[0].inputs[1] === inn.channels[i] } } } ? false });
    ~tAssert.("...its dry path the bus delayed by the latency, its wet path the plugin's, bypassed or not, and hard-bypassed once its switch has faded out",
        fades.notEmpty and: { fades.every { |u| (dependsOn.(desc.def, u.inputs[0]) == [\bus, \lat])
            and: { dependsOn.(desc.def, u.inputs[1]) == [\bus, \bypass, \on] } } },
        fades.collect { |u| [dependsOn.(desc.def, u.inputs[0]), dependsOn.(desc.def, u.inputs[1])] }.asString);
};
pluginDescs.reject(_.isNil).do { |desc|
    ~tEq.(desc.name ++ " has the bus, the player's switch, the plugin's readiness, VSTPlugin's bypass and the latency",
        desc.controlNames.collect(_.asSymbol), [\bus, \on, \ready, \bypass, \lat]);
    ~tAssert.("...and hosts one VSTPlugin, \\plugin to MegaSAPlugin",
        (desc.def.children.count { |u| u.isKindOf(vst) } == 1) and: { desc.metadata[\vstplugins].notNil }
            and: { desc.metadata[\vstplugins].includesKey(\plugin) });
};
~tEq.("the guitar's source: the hardware input, dual mono, onto the chain's bus",
    SynthDescLib.global[\megaSAChainIn] !? { |x| [x.controlNames.collect(_.asSymbol),
        outsOf.(x.def).collect(_.class), outsOf.(x.def).collect { |u| u.inputs.copyToEnd(1).asSet.size }] },
    [[\in, \bus], [Out], [1]]);
~tEq.("the loop's: the Looper's output copied onto the chain's bus",
    SynthDescLib.global[\megaSAChainCopy] !? { |x| [x.controlNames.collect(_.asSymbol), outsOf.(x.def).collect(_.class)] },
    [[\in, \bus], [Out]]);

// The bytes of each, as scsynth gets them: the graphs nrt-chains.scd found
// equal to the one-synth chains, sample for sample (2026-10-10). A graph that
// moves must pass nrt-chains again before its bytes are pasted here; the
// plugins' also move with VSTPlugin's version (0.6.2 here). Pitch Loops' moved
// on 2026-10-11 (Rand. L, the right voice's LFO, Feedback), and passed.
// Pitch Loops: each voice has an LFO and a random distance, and the two feed
// back. What the Live set did not use starts at nothing, so a sound from
// before them plays as it did.
~tEq.("Pitch Loops has the left voice's random distance, the right voice's LFO and Feedback, each starting at nothing",
    [\pitchLoopRandL, \pitchLoopLfoR, \pitchLoopFeedback].collect { |n| MegaSAFx.param(n) !? { |p| p[\spec].default } }, [0, 0, 0]);
~tEq.("...the right LFO's rate at 1 Hz, and Feedback held under 1", [MegaSAFx.param(\pitchLoopLfoRateR)[\spec].default,
    MegaSAFx.param(\pitchLoopFeedback)[\spec].maxval], [1, 0.9]);
~tAssert.("...its device's synth takes each of them",
    [\pitchLoopRandL, \pitchLoopLfoRateR, \pitchLoopLfoR, \pitchLoopFeedback].every { |n|
        (SynthDescLib.global[\megaSADevPitchLoop] !? { |x| x.controlNames.collect(_.asSymbol) } ? []).includes(n) });
~tEq.("...and its memory counts the feedback's own short buffer",
    MegaSAFx.type(\pitchLoop)[\memBytes].(48000), (288000 * 4) + (2048 * 4) + (2 * 512 * 96));
fingerprint = { |bytes|
    var acc = 0;
    bytes.do { |x, i| acc = (acc * 31 + x + i) % 1000000007 };
    [bytes.size, acc]
};
// Filter, Drive and Crusher moved 2026-10-15: they pause themselves once
// switched off (MegaSAFx.sleepWhenFaded); the plugins' hard-bypass VSTPlugin
// once switched off. Deliberate, and nrt-chains passes on them.
baseline = (
    'megaSAChainIn': [216, 30983118],
    'megaSAChainCopy': [151, 298444183],
    'megaSADevNull': [144, 992001537],
    'megaSADevShifter': [3148, 917785194],
    'megaSADevDelay': [2246, 880224587],
    'megaSADevFilter': [4302, 917590315],
    'megaSADevPitchLoop': [5137, 789196505],
    'megaSADevEcho': [4036, 513022876],
    'megaSADevSaturator': [3088, 619047135],
    'megaSADevRedux': [2908, 323508165],
    'megaSADevPlugin11': [1176, 349604764],
    'megaSADevPlugin12': [1214, 700342614],
    'megaSADevPlugin21': [1098, 929643650],
    'megaSADevPlugin22': [1136, 573272804]
);
baseline.keys.asArray.sort.do { |name|
    var desc = SynthDescLib.global[name];
    if(name.asString.beginsWith("megaSADevPlugin") and: { vst.isNil }) { ~tSkip.(name ++ "'s graph", "no VSTPlugin") } {
        ~tEq.(name ++ ": its graph is the one nrt-chains checked", desc !? { |x| fingerprint.(x.def.asBytes) }, baseline[name]);
    };
};

// ------------------------------------------------------ the device model --
d = MegaSADevice(\delay, \delay);
~tEq.("a device starts with its type's settings, the Live set's", d.settings.keys.asArray.sort,
    MegaSAFx.paramsOf(\delay).collect(_[\name]).sort);
~tAssert.("...at their defaults, and off", MegaSAFx.paramsOf(\delay).every { |q| d.param(q[\name]) == q[\spec].default }
    and: { d.on == false } and: { d.edited.not });
~tEq.("its synth is its type's, its switch its type's", [d.defName, d.switchName, d.status], [\megaSADevDelay, \delayOn, \ok]);
d.setParam(\delayMix, 5);
~tEq.("a setting is held to its range", d.param(\delayMix), 1);
~tAssert.("...which, the Delay's default, is no edit", d.edited.not);
d.setParam(\delayMix, 0.4);
~tAssert.("...and anything else is", d.edited);
d = MegaSADevice(\delay, \delay, (delayMix: 0.5, wahWah: 3, delayTimeR: "far"));
~tEq.("given settings are taken where they are its own and a number", [d.param(\delayMix), d.settings.includesKey(\wahWah),
    d.param(\delayTimeR)], [0.5, false, MegaSAFx.param(\delayTimeR)[\spec].default]);
~tEq.("...and not NaN, which a corrupt file could hold", MegaSADevice(\delay, \delay, (delayMix: 0/0)).param(\delayMix),
    MegaSAFx.param(\delayMix)[\spec].default);
~tEq.("it starts on its bus with its switch and settings in panel order, the beat only if it follows the tempo",
    d.startArgs(40, 0.5), [\bus, 40, \delayOn, 0] ++ MegaSAFx.paramsOf(\delay).collect { |q| [q[\name], d.param(q[\name])] }.flat);
~tEq.("...the Auto Filter follows it", MegaSADevice(\filter, \filter).startArgs(40, 0.5).keep(-2), [\beatDur, 0.5]);
heard = List.new;
d.addDependant({ |obj, what ... more| heard.add([what] ++ more) });
d.setOn(true);
d.setParam(\delayMix, 0.25);
~tEq.("it says its own \\on and \\param", heard.asArray, [[\on, true], [\param, \delayMix, 0.25]]);
d.releaseDependants;
d = MegaSADevice(\wah, \wah);
~tEq.("a type this build does not know passes its chain through, and says so",
    [d.defName, d.status, d.params, d.startArgs(40, 0.5)], [\megaSADevNull, \missing, [], [\bus, 40, \wahOn, 0]]);
p = MegaSADevice.plugin(\plugin1, [1, 2], "Thing");
// Without VSTPlugin there is no plugin SynthDef to name: the device passes
// its chain through, as a type this build does not know does.
~tEq.("a plugin device: its layout's synth (the pass-through without VSTPlugin), on, the player's switch `on`, starting not ready",
    [p.defName, p.on, p.switchName, p.name, p.startArgs(40, 0.5)],
    [if(\VSTPlugin.asClass.notNil) { \megaSADevPlugin12 } { \megaSADevNull }, true, \on, "Thing", [\bus, 40, \on, 1, \ready, 0]]);
~tEq.("...failed while it has no plugin, its delay 0, its memory its dry path's DelayN, both sides",
    [p.status, p.latency, p.memBytes(48000)], [\failed, 0, 2 * MegaSAFx.lineBytes((MegaSAPlugin.maxLatency * 48000) + 1)]);
p.plugin = (state: \opening, latency: 32, dryDelay: 32);
~tEq.("...opening while its plugin opens, its delay the one its dry path follows", [p.status, p.latency], [\opening, 32]);
p.plugin = (state: \open, latency: 512, dryDelay: 0, held: "it adds 10.7 ms");
~tEq.("...held off for its latency: none of it added, its dry path left as it was", [p.status, p.latency], [\held, 0]);
p.plugin = (state: \open, latency: 0, dryDelay: 0);
~tEq.("...ok once open", p.status, \ok);

c = MegaSAChain(\guitar, Bus(\audio, 40, 2, (options: ServerOptions.new)), \megaSAChainIn, [\in, 0]);
[\shifter, \delay].do { |k| c.add(MegaSADevice(k, k)) };
c.add(p);
~tEq.("a chain holds its devices in order", c.ids, [\shifter, \delay, \plugin1]);
~tAssert.("...by id", (c.device(\delay).type == \delay) and: { c.device(\echo).isNil });
~tEq.("...its delay and its memory their sums", [c.latency(48000), c.memBytes(48000)],
    [2 + 0, (MegaSAFx.type(\shifter)[\memBytes].value(48000) + MegaSAFx.type(\delay)[\memBytes].value(48000)) + p.memBytes(48000)]);
~tEq.("...and it is not on the server until built", [c.built, c.group, c.source], [false, nil, nil]);

// -------------------------------------------- the chains, as MegaSA builds them --
stub = ~tStubServer.();
fake = ~tFakePlugin.(\open);
sa = ~tMegaSA.(stub, fake);
// What the Looper's init puts at the default group's tail on a rig: its master.
Synth.tail(stub[\defaultGroup], \looperMaster);
l = ~tLooper.();
Routine { sa.attachLooper(l) }.next;
t = ~tNodeTree.(stub);
gIds = MegaSAFx.guitarKeys ++ if(vst.notNil) { [\plugin1] } { [] };
lIds = MegaSAFx.loopKeys;
~tEq.("the guitar chain: its four effects, then the plugin (with VSTPlugin)", sa.guitarChain.ids, gIds);
~tEq.("the loop chain: its three", sa.loopChain.ids, lIds);
~tEq.("MegaSA knows them all, the guitar's first", sa.devices.collect(_.id), gIds ++ lIds);
~tEq.("the guitar chain is a group of its own, the guitar group's first child, the bass chain's after it",
    (t[\children][sa.guitarGroup.nodeID] ? []).asArray, [sa.guitarChain.group.nodeID, sa.bassChain.group.nodeID]);
~tEq.("...holding the input first, then a synth per device in chain order",
    (t[\children][sa.guitarChain.group.nodeID] ? []).asArray,
    [sa.guitarChain.source.nodeID] ++ sa.guitarChain.devices.collect { |x| x.node.nodeID });
~tEq.("...each its type's SynthDef", (t[\children][sa.guitarChain.group.nodeID] ? []).asArray.collect { |x| t[\defs][x] },
    [\megaSAChainIn] ++ sa.guitarChain.devices.collect(_.defName));
~tAssert.("the loop chain is a group in the default group, after the Looper's master, last there",
    (t[\parent][sa.loopChain.group.nodeID] == 1) and: { t[\children][1].last == sa.loopChain.group.nodeID }
        and: { t[\defs][t[\children][1][t[\children][1].size - 2]] == \looperMaster },
    t[\children][1].asString);
~tEq.("...holding the Looper's output copied first, then its devices in order",
    (t[\children][sa.loopChain.group.nodeID] ? []).asArray.collect { |x| t[\defs][x] },
    [\megaSAChainCopy, \megaSADevEcho, \megaSADevSaturator, \megaSADevRedux]);
~tEq.("the guitar's input reads the hardware input onto guitarBus", ~tStartArgs.(stub, sa.guitarChain.source),
    (in: 0, bus: sa.guitarBus.index));
~tEq.("the loop's copies loopBus onto loopFxBus", ~tStartArgs.(stub, sa.loopChain.source),
    (in: sa.loopBus.index, bus: sa.loopFxBus.index));
~tAssert.("every device starts on its chain's bus, its switch and settings as they stand, the beat if it follows the tempo",
    sa.chains.every { |ch| ch.devices.every { |x|
        var a = ~tStartArgs.(stub, x.node);
        (a[\bus] == ch.bus.index) and: { a[x.switchName] == x.on.binaryValue }
            and: { x.params.every { |q| a[q[\name]] == x.param(q[\name]) } }
            and: { a.includesKey(\beatDur) == x.followsTempo }
            and: { a.size == x.startArgs(0, 0).size.div(2) }
    } });
if(vst.notNil) {
    args = ~tStartArgs.(stub, sa.fxNode(\plugin1));
    ~tEq.("the plugin's device starts on and not ready: the plugin says when it is", [args[\on], args[\ready]], [1, 0]);
    ~tAssert.("...its plugin the one made for it", sa.guitarPlugin === fake);
    // Made in its device's synth, for the VSTPlugin UGen named \plugin there.
    srv = ~tCountIds.(~tStubServer.());
    srv[\defaultGroup] = Group.basicNew(srv, 1);
    m = MegaSA(srv, 0, 0, "/x/Thing.vst");
    m.instVarAt(\builder) !? { |r| r.stop };
    m.pluginMaker = { |synth, id, path| made = [synth, id, path]; ~tFakePlugin.(\failed) };
    Routine { m.prBuild }.next;
    m.instVarAt(\opener) !? { |r| r.stop };
    ~tEq.("the plugin is made in its device's synth, as \\plugin, from its path",
        made !? { [made[0] === m.fxNode(\plugin1), made[1], made[2]] }, [true, \plugin, "/x/Thing.vst"]);
    ~tEq.("...its device named after it", m.device(\plugin1).name, "Thing");
    m.free;
    // One that cannot be made: its device stays, a synth in its place in the
    // chain, on and never ready, so it passes the guitar through.
    srv = ~tCountIds.(~tStubServer.());
    srv[\defaultGroup] = Group.basicNew(srv, 1);
    m = MegaSA(srv, 0, 0, "/x/Thing.vst");
    m.instVarAt(\builder) !? { |r| r.stop };
    m.pluginMaker = { |synth, id, path| Error("a plugin on fire").throw };
    Routine { m.prBuild }.next;
    m.instVarAt(\opener) !? { |r| r.stop };
    args = ~tStartArgs.(srv, m.fxNode(\plugin1));
    ~tEq.("a plugin that cannot be made keeps its device: last in the chain, its synth on and not ready, failed",
        [m.guitarChain.ids.last, m.fxNode(\plugin1).notNil, args[\on], args[\ready], m.device(\plugin1) !? (_.status), m.guitarPlugin],
        [\plugin1, true, 1, 0, \failed, nil]);
    m.free;
};
~tEq.("the footswitches are the built-ins', the plugin not among them", sa.fxOn.keys.asArray.sort, MegaSAFx.keys.sort);
~tEq.("every setting is there by its name", sa.fxParams.keys.asArray.sort, MegaSAFx.params.collect(_[\name]).sort);
sa.fxParams.put(\filterFreq, 1);
~tEq.("...in a dictionary of its own: changing it changes nothing", sa.fxParam(\filterFreq),
    MegaSAFx.param(\filterFreq)[\spec].default);

// ---- the plugin's switches ----------------------------------------------
if(vst.isNil) { ~tSkip.("the plugin's switches", "VSTPlugin is not installed here") } {
    // What `model` (sa unless given) said while `fn` ran.
    heard = { |fn, model|
        var got = List.new, f = { |obj, what ... more| got.add([what] ++ more) }, who = model ? sa;
        who.addDependant(f);
        protect { fn.value } { who.removeDependant(f) };
        got.asArray
    };
    said = heard.({ sa.setFx(\plugin1, false) });
    ~tEq.("the player switches the plugin off on its device's `on`, said once as \\fx",
        [stub[\msgs].last, said, sa.fx(\plugin1)], [[15, sa.fxNode(\plugin1).nodeID, \on, 0], [[\fx, \plugin1, false]], false]);
    sa.setFx(\plugin1, true);
    b = MegaSAPlugin.newCopyArgs(Synth.basicNew(\megaSADevPlugin11, stub, 7777), \plugin, "/x/Thing.vst");
    b.bypass(false);
    ~tEq.("MegaSAPlugin says ready with `ready` and VSTPlugin's bypass off, never touching `on`",
        stub[\msgs].last, [15, 7777, \bypass, 0, \ready, 1]);
    b.bypass(true);
    ~tEq.("...and not ready, VSTPlugin soft-bypassed", stub[\msgs].last, [15, 7777, \bypass, 2, \ready, 0]);
    // Its controller stood in for: what MegaSAPlugin asks of VSTPlugin.
    calls = List.new;
    b.instVarPut(\controller, (
        open: { |self, path, editor, verbose, action| calls.add([\open, path]); pending = action },
        readBank: { |self, path, action| calls.add([\readBank, path]); bankAction = action },
        setTempo: { |self, bpm| calls.add([\tempo, bpm]) }));
    [\closed, \opening, \failed, \crashed].do { |st| b.instVarPut(\state, st); b.setTempo(120) };
    ~tEq.("...tells a plugin that is not open no tempo", calls.asArray, []);
    b.instVarPut(\state, \open);
    b.setTempo(120);
    ~tEq.("...and one that is open the tempo, once", calls.asArray, [[\tempo, 120]]);
    // A MIDI controller, for the plugin's own MIDI learn: through VSTPlugin's
    // MIDI, and only while the plugin is open.
    b.controller.put(\midi, { |self| (control: { |me, chan, num, val| calls.add([\cc, chan, num, val]) }) });
    calls = List.new;
    ~tEq.("a plugin that is not open is sent no MIDI controller, and the send says so",
        [[\closed, \opening, \failed, \crashed].collect { |st| b.instVarPut(\state, st); b.sendControl(0, 20, 127) }, calls.asArray],
        [false ! 4, []]);
    b.instVarPut(\state, \open);
    ~tEq.("...one that is open gets it as VSTPlugin's MIDI: channel, number, value (127 if none is given)",
        [b.sendControl(0, 20, 127), b.sendControl(1, 27), calls.asArray], [true, true, [[\cc, 0, 20, 127], [\cc, 1, 27, 127]]]);
    ~tEq.("...and none without a number", [b.sendControl(0, nil), calls.size], [false, 2]);
    // The open: ready only once the plugin is open and its bank in, and before
    // the answer, which lets the guitar go.
    calls = List.new;
    b.instVarPut(\state, \closed);
    b.open(nil, { |p, ok| calls.add([\answer, ok, stub[\msgs].last]) });
    ~tEq.("an open starts not ready, VSTPlugin soft-bypassed", [calls.asArray, stub[\msgs].last],
        [[[\open, "/x/Thing.vst"]], [15, 7777, \bypass, 2, \ready, 0]]);
    pending.value(nil, true);
    ~tEq.("...and once open says ready, before it answers", calls.asArray,
        [[\open, "/x/Thing.vst"], [\answer, true, [15, 7777, \bypass, 0, \ready, 1]]]);
    calls = List.new;
    b.open("/x/sound.fxb", { |p, ok| calls.add([\answer, ok, stub[\msgs].last]) });
    pending.value(nil, true);
    ~tEq.("with a bank: open, still not ready until the bank is in", [calls.asArray, stub[\msgs].last],
        [[[\open, "/x/Thing.vst"], [\readBank, "/x/sound.fxb"]], [15, 7777, \bypass, 2, \ready, 0]]);
    bankAction.value(nil, true);
    ~tEq.("...then ready, then the answer", calls.asArray.last, [\answer, true, [15, 7777, \bypass, 0, \ready, 1]]);
    calls = List.new;
    b.open(nil, { |p, ok| calls.add([\answer, ok, stub[\msgs].last]) });
    pending.value(nil, false);
    ~tEq.("an open that fails never says ready", [calls.asArray.last, b.state],
        [[\answer, false, [15, 7777, \bypass, 2, \ready, 0]], \failed]);

    // Latency (device-chains.md, section 7): read in the open's own answer,
    // where VSTPlugin already knows it. Within 64 samples the dry path is
    // delayed by as much; past it the plugin is held off, never heard, until
    // compensation comes in release 1.2.
    calls = List.new;
    lats = List.new;
    b.controller[\latency] = 512;
    b.addDependant({ |o, what, x| if(what == \latency) { lats.add(x) } });
    n = stub[\msgs].size;
    b.open(nil, { |p, ok| calls.add([\answer, ok]) });
    pending.value(nil, true);
    sent2 = stub[\msgs].copyToEnd(n).asArray;
    ~tEq.("a plugin reporting 512 samples opens and answers, but is held off: never once told it is ready",
        [calls.asArray, b.held.notNil, sent2.any { |m| m.includes(\ready) and: { m[m.indexOf(\ready) + 1] == 1 } }, lats.asArray],
        [[[\open, "/x/Thing.vst"], [\answer, true]], true, false, [512]]);
    ~tAssert.("...the reason says how much it would add", b.held.contains("10.7 ms"), b.held);
    dev = MegaSADevice.plugin(\plugin9, [1, 1], "Thing");
    dev.plugin = b;
    ~tEq.("...its device held", dev.status, \held);
    n = stub[\msgs].size;
    b.prLatencyChanged(32);
    ~tEq.("reporting 32 later, it is heard, its dry path delayed by as much",
        [b.held, stub[\msgs].copyToEnd(n).asArray, b.dryDelay], [nil, [[15, 7777, \lat, 32], [15, 7777, \bypass, 0, \ready, 1]], 32]);
    ~tEq.("...its device ok, its delay that", [dev.status, dev.latency], [\ok, 32]);
    n = stub[\msgs].size;
    b.prLatencyChanged(128);
    ~tEq.("128 while it plays: held off at once, the dry path left as it was, and so the device's delay",
        [b.held.notNil, stub[\msgs].copyToEnd(n).asArray, b.dryDelay, dev.latency],
        [true, [[15, 7777, \bypass, 2, \ready, 0]], 32, 32]);
    n = stub[\msgs].size;
    b.prLatencyChanged(nil);
    ~tEq.("none reported counts as 0: heard, with no delay", stub[\msgs].copyToEnd(n).asArray,
        [[15, 7777, \lat, 0], [15, 7777, \bypass, 0, \ready, 1]]);
    ~tEq.("...each report said as \\latency", lats.asArray, [512, 32, 128, 0]);
    b.instVarPut(\state, \opening);
    n = stub[\msgs].size;
    b.prLatencyChanged(16);
    ~tEq.("a report while it opens sets the dry path, and makes it ready no sooner than the open does",
        stub[\msgs].copyToEnd(n).asArray, [[15, 7777, \lat, 16]]);
    b.releaseDependants;

    // MegaSA says a chain's delay, once per change: from its plugin's report
    // and from an edit.
    plug = ~tFakePlugin.(\open);
    m = ~tMegaSA.(nil, plug);
    Routine { m.attachLooper(~tLooper.()) }.next;
    said = heard.({ plug[\latency] = 32; plug[\dryDelay] = 32; plug.changed(\latency, 32); plug.changed(\latency, 32) }, m);
    ~tEq.("a plugin's latency changes the guitar chain's delay: \\latency (track, seconds), once",
        said, [[\latency, \guitar, (2 + 32) / 48000]]);
    said = heard.({ plug[\latency] = 512; plug[\held] = "it adds 10.7 ms"; plug.changed(\latency, 512) }, m);
    ~tEq.("...one that holds it off changes nothing: the chain is delayed as before",
        [said, m.device(\plugin1).status], [[], \held]);
    plug[\latency] = 32;
    plug[\held] = nil;
    said = heard.({ m.setFxParam(\shifterCoarse, 7) }, m);
    ~tEq.("...a Shifter's pitch moves its delay, and says so with its setting",
        said.collect(_.first), [\fxParam, \latency]);
    m.resetFx(\shifter);
    said = heard.({ m.insertDevice(\guitar, 0, \shifter) }, m);
    ~tEq.("...and so does an edit that adds a delay (a Shifter: 2 samples)",
        said.select { |x| x[0] == \latency }, [[\latency, \guitar, (2 + 2 + 32) / 48000]]);
    said = heard.({ m.insertDevice(\loop, 0, \redux) }, m);
    ~tEq.("...an edit that adds none says nothing of it", said.select { |x| x[0] == \latency }, []);
    m.free;
};

// ---- the tempo ------------------------------------------------------------
before = stub[\msgs].size;
sa.setTempo(120);
sent = stub[\msgs].copyToEnd(before).asArray;
~tEq.("a tempo is one n_set of the beat to each chain's group", sent,
    [[15, sa.guitarChain.group.nodeID, \beatDur, 0.5], [15, sa.loopChain.group.nodeID, \beatDur, 0.5],
        [15, sa.drumsChain.group.nodeID, \beatDur, 0.5], [15, sa.bassChain.group.nodeID, \beatDur, 0.5],
        [15, sa.synthChain.group.nodeID, \beatDur, 0.5]]);
if(vst.notNil) { ~tEq.("...and the plugin's own tempo, which it reads instead of a control", fake[\tempo], 120) };
~tAssert.("...which reaches every device that reads the beat, each in one of those groups",
    sa.devices.select(_.followsTempo).notEmpty and: { sa.devices.select(_.followsTempo).every { |x|
        [sa.guitarChain.group.nodeID, sa.loopChain.group.nodeID].includes(t[\parent][x.node.nodeID]) } });

// A plugin still opening misses a reading's tempo, and is told it once open;
// and once its bank jobs are done, since a busy plugin misses it too.
if(vst.notNil) {
    plug = ~tFakePlugin.(\open);
    plug[\open] = { |self, bankFile, action| self[\state] = \opening; late = action };
    m = ~tMegaSA.(nil, plug);
    m.setTempo(150);
    ~tEq.("a reading while the plugin opens does not reach it", plug[\tempo], nil);
    plug[\state] = \open;
    late.value(plug, true);
    ~tEq.("...it is told the tempo once it has opened", plug[\tempo], 150);
    plug[\tempo] = nil;
    m.hold(\guitar, \bank);
    m.prBankJobsDone;
    ~tEq.("...and again when its bank jobs are done, the guitar let go", [plug[\tempo], m.held(\guitar)], [150, []]);
    m.free;
};

// ---- a new Looper's chain ---------------------------------------------------
sa.setFx(\echo, true);
sa.setFxParam(\echoMix, 0.3);
oldGroup = sa.loopChain.group.nodeID;
oldNodes = [sa.loopChain.source.nodeID] ++ sa.loopChain.devices.collect { |x| x.node.nodeID };
l2 = ~tLooper.();
Routine { sa.attachLooper(l2) }.next;
t = ~tNodeTree.(stub);
~tAssert.("a second Looper's chain replaces the first: its group gone, every synth in it with it",
    t[\parent][oldGroup].isNil and: { oldNodes.every { |x| t[\parent][x].isNil } });
~tAssert.("...the new one in the default group, at its tail", (t[\children][1].last == sa.loopChain.group.nodeID)
    and: { sa.loopChain.group.nodeID != oldGroup });
args = ~tStartArgs.(stub, sa.fxNode(\echo));
~tEq.("...the Echo starting as the player left it", [args[\echoOn], args[\echoMix]], [1, 0.3]);
~tEq.("...the same devices, in new synths", [sa.loopChain.ids, sa.loopChain.devices.every { |x| oldNodes.includes(x.node.nodeID).not }],
    [lIds, true]);
~tEq.("...in order: the copy first, then the Echo, the Saturator and Redux",
    (t[\children][sa.loopChain.group.nodeID] ? []).asArray,
    [sa.loopChain.source.nodeID] ++ sa.loopChain.devices.collect { |x| x.node.nodeID });
~tEq.("...their SynthDefs", (t[\children][sa.loopChain.group.nodeID] ? []).asArray.collect { |x| t[\defs][x] },
    [\megaSAChainCopy, \megaSADevEcho, \megaSADevSaturator, \megaSADevRedux]);

// ---- free -----------------------------------------------------------------
gIds = [sa.guitarChain.group.nodeID, sa.loopChain.group.nodeID];
n = stub[\msgs].size;
sa.free;
~tAssert.("free takes both chains' groups off the server", gIds.every { |g|
    stub[\msgs].copyToEnd(n).any { |m| (m[0] == 11) and: { m.includes(g) } } });
~tAssert.("...and no device has a synth any more, its model kept",
    sa.devices.every { |x| x.node.isNil } and: { sa.devices.size == (MegaSAFx.keys.size + vst.notNil.binaryValue) });

// ---- a MegaSA made without its init ----------------------------------------
sa = MegaSA.newCopyArgs(nil, 0, 0);
~tEq.("made without its init it has no chains, and answers as if empty",
    [sa.chains, sa.devices, sa.fx(\delay), sa.fxOn.size, sa.fxParams.size, sa.fxEdited(\delay), sa.fxNode(\delay)],
    [[], [], nil, 0, 0, false, nil]);
~tCheck.("...and takes a tempo and a switch without throwing", { sa.setTempo(100); sa.setFx(\delay, true) });
}.value;
