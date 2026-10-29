// The effects in no chain to begin with (MegaSAFx.extraKeys, docs/dev/
// rc600-picks.md, Phase 4): the Utility ones (EQ, Compressor, Noise Gate). In
// no chain at first; the first inserted takes its type's key as its id, as a
// default device has, so its switch and settings answer to sa.fxOn.eq and
// sa.fx.eqLow; a further one goes on from 2; a sound keeps their marks only
// once one was made. What they sound like is scripts/sa/nrt-utility.scd's.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-megasa-utility");

{
var scripts = thisProcess.nowExecutingPath.dirname.dirname;
var sa, d, d2, d3, fresh, targets, was = ~megaSA;
if(~midiTargetsBuild.isNil) { (scripts +/+ "setup-miditargets.scd").load };

fresh = ~tMegaSA.(~tStubServer.());
~tEq.("no chain holds one to begin with", MegaSAFx.extraKeys.collect { |k| fresh.device(k) }, nil ! MegaSAFx.extraKeys.size);
~tAssert.("...and a sound of the chains carries no mark for them",
    MegaSAFx.extraKeys.every { |k| fresh.sound("x").fileString.contains("\"" ++ k ++ "\"").not }, "a mark written");
~tEq.("they are in the + menu's Utility, Texture and Space groups", MegaSAFx.extraKeys.collect { |k| MegaSAFx.type(k)[\group] },
    ["Utility", "Utility", "Utility", "Texture", "Texture", "Texture", "Texture", "Texture", "Space"]);
fresh.free;

sa = ~tMegaSA.(~tStubServer.());
d = sa.insertDevice(\guitar, nil, \eq);
~tEq.("the first EQ inserted has the type's key as its id, and its title as its name", [d.id, d.name], [\eq, "EQ"]);
d2 = sa.insertDevice(\guitar, nil, \eq);
~tEq.("...a second goes on from 2", [d2.id, d2.name], [\eq2, "EQ 2"]);
~tEq.("its settings answer by name, through the first, at their defaults", sa.fxParam(\eqLowGain), 0);
sa.setFxParam(\eqLowGain, 6);
sa.setFx(\eq, true);
~tEq.("...and are set so; its switch too", [sa.fxParam(\eqLowGain), sa.fx(\eq), d2.param(\eqLowGain)], [6, true, 0]);
~tAssert.("a sound of the chains keeps its mark: the next one is 3",
    sa.sound("x").fileString.contains("\"eq\": 3"), sa.sound("x").fileString.keep(300));
sa.removeDevice(\eq);
d3 = sa.insertDevice(\guitar, nil, \eq);
~tEq.("removed (undo can bring it back), its id is not given again", d3.id, \eq3);
d = sa.insertDevice(\guitar, 0, \noiseGate);
~tEq.("a Noise Gate first in the guitar chain, before the rest, its key as its id",
    [d.id, sa.guitarChain.ids.first], [\noiseGate, \noiseGate]);
~tEq.("...a Compressor's key is still free", sa.insertDevice(\guitar, nil, \compressor).id, \compressor);

// The Slicer follows the loop's phase: a chain that has it (attachLooper
// gives every chain the Looper's) passes it to a Slicer put in, in the same
// bundle; a moved one is told it again; an EQ, which doesn't follow it, isn't.
sa.guitarChain.setPhaseBus(37);
d = sa.insertDevice(\guitar, nil, \slicer);
~tEq.("a Slicer put in a chain with the loop's phase is sent its bus", ~tLastSet.(sa, d.node, \phaseBus), 37);
~tEq.("...and is on the beat: it follows the tempo too", [d.followsPhase, d.followsTempo], [true, true]);
~tEq.("...an EQ isn't sent it", ~tLastSet.(sa, sa.insertDevice(\guitar, nil, \eq).node, \phaseBus), nil);
sa.guitarChain.setPhaseBus(41);
~tEq.("a chain given another bus sends its group the new one", ~tLastSet.(sa, sa.guitarChain.group, \phaseBus), 41);

// Its MIDI controls reach the device with the type's key, once there is one.
~megaSA = sa;
targets = ~midiTargetsBuild.(\effects);
~tEq.("its controls: the switch, Reset and Random, and every setting, by the type's key",
    ['sa.fxOn.noiseGate', 'sa.fxReset.noiseGate', 'sa.fxRandom.noiseGate', 'sa.fx.noiseGateThreshold']
        .collect { |id| targets[id].notNil }, [true, true, true, true]);
~tEq.("...there while the device is; an EQ's first removed, not",
    [targets['sa.fxOn.noiseGate'][\available].value, targets['sa.fxOn.eq'][\available].value], [true, false]);
~tAssert.("...and a further one, eq2, has its own, as a second Delay does",
    targets['sa.fx.eq2.eqLowGain'].notNil, "no sa.fx.eq2.eqLowGain");
targets['sa.fx.noiseGateThreshold'][\set].value(-40);
~tEq.("a knob on its setting moves it", sa.fxParam(\noiseGateThreshold), -40);
~megaSA = was;
sa.free;
}.value;

// The Compressor's side chain: its Key, itself or one of the chains, whose
// busses every chain gives a keyed device's synth as it starts (\keyBuses,
// MegaSAFx.keySignal). What it does with them is nrt-utility.scd's.
{
var sa, srv, d, want, log, iNew, iSet, held;
var key = MegaSAFx.param(\compressorKey);
// The key busses an s_new started a node with: the values between [ and ]
// after \keyBuses (an array goes out in scsynth's bracket form), or nil.
var keyArgs = { |srv, node|
    var msg = node !? { |n| srv[\writes].collect(_[1]).detect { |m| (m[0] == 9) and: { m[2] == n.nodeID } } };
    var at = msg !? { |m| m.indexOf(\keyBuses) };
    at !? { msg.copyRange(at + 2, msg.indexOf($]) - 1) }
};
~tEq.("the Compressor's Key and Key Filter come last in its panel, at Itself and 20 kHz",
    MegaSAFx.paramsOf(\compressor).collect(_[\name]).keep(-2)
        ++ [key[\spec].default, MegaSAFx.param(\compressorKeyFilter)[\spec].default],
    [\compressorKey, \compressorKeyFilter, 0, 20000]);
~tEq.("...the Key a menu: itself, then each chain in the order the server runs them",
    key[\choices].collect(_[1]), ["Itself", "Instrument", "Bass", "Loop", "Drums", "Synth"]);
~tEq.("...one choice per key track, 1 on", key[\choices].drop(1).collect(_[0]), (1 .. MegaSAFx.keyTracks.size));
~tEq.("only the Compressor is keyed", MegaSAFx.typeKeys.select { |k| MegaSAFx.type(k)[\keyed] == true }, [\compressor]);

srv = ~tStubServer.();
sa = ~tMegaSA.(srv, nil, nil, nil, nil, nil, 1);
want = [sa.guitarBus, sa.bassBus, sa.loopFxBus, sa.stepsBus, sa.synthBus].collect(_.index);
~tEq.("the key busses: the instrument's, the bass's, the loop's after its chain, the drums' and the synth's",
    MegaSAFx.keyTracks.collect { |t| sa.chainFor(t).bus.index }, want);
~tEq.("...and every chain holds them all", sa.chains.collect(_.keyBuses), want ! sa.chains.size);
d = sa.insertDevice(\guitar, nil, \compressor);
~tEq.("a Compressor put in a chain starts with them", keyArgs.(srv, d.node), want);
~tEq.("...an EQ, which has no key, doesn't", keyArgs.(srv, sa.insertDevice(\guitar, nil, \eq).node), nil);
sa.moveDevice(d.id, \bass, 0);
~tEq.("...one moved to another chain keeps the same ones: no new synth", [sa.chainOf(d).track, keyArgs.(srv, d.node)],
    [\bass, want]);
sa.setParam(d.id, \compressorKey, 4);
~tEq.("its Key is a setting, sent as one", ~tLastSet.(sa, d.node, \compressorKey), 4);
sa.bassChain.build(sa.guitarChain.group, \addToTail, 0.5);
~tEq.("a chain built again starts its Compressor with them too, and its Key as it stands",
    [keyArgs.(srv, d.node), ~tStartArgs.(srv, d.node)[\compressorKey]], [want, 4]);
held = (1 .. 20).collect { sa.randomizeFx(d.id); d.param(\compressorKey) };
~tEq.("Random leaves the Key, which chain it hears, where it is", held.asSet.asArray, [4]);

// The loop's phase reaches a device that follows it on a chain built after
// the phase was given (the loop's, built once the Looper is attached): the
// group hears it once the devices are in it.
d = sa.insertDevice(\guitar, nil, \slicer);
sa.guitarChain.setPhaseBus(37);
sa.guitarChain.build(srv[\defaultGroup], \addBefore, 0.5);
log = srv[\writes].collect(_[1]);
iNew = log.detectIndex { |m| (m[0] == 9) and: { m[2] == d.node.nodeID } };
iSet = log.detectIndex { |m| (m[0] == 15) and: { m[1] == sa.guitarChain.group.nodeID } and: { m.includes(\phaseBus) } };
~tAssert.("a chain built with the loop's phase sends its group the phase after its devices' synths",
    iNew.notNil and: { iSet.notNil } and: { iSet > iNew }, [iNew, iSet].asString);
sa.free;
}.value;
