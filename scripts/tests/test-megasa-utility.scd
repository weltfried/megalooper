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
~tEq.("they are in the + menu's Utility and Texture groups", MegaSAFx.extraKeys.collect { |k| MegaSAFx.type(k)[\group] },
    ["Utility", "Utility", "Utility", "Texture", "Texture", "Texture", "Texture"]);
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
