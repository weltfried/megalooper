// Megalooper SA's third chain, the drums' (docs/dev/device-chains.md, section
// 13.19): there from the start and empty, on the bus Rhythmic Steps' voices
// play onto, built right before the drums' effects so a device is heard
// before the drums' reverb; it takes inserts, moves from the other chains,
// removes and undo as they do; and a sound holds it only when it holds
// something, so a sound with nothing on the drums is the file it always was.
// How a device on it sounds is scripts/sa/nrt-drums-fx.scd's to check.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-megasa-drumchain");

{
var vst = \VSTPlugin.asClass;
var stub, sa, l, t, d, kids, at, n, bundles, said, heard, text, sound, old, again, dc, bare, sa2, stub2, outsOf;

heard = { |obj, fn|
    var got = List.new, f = { |o, what ... more| got.add([what] ++ more) };
    obj.addDependant(f);
    protect { fn.value } { obj.removeDependant(f) };
    got.asArray
};
outsOf = { |def| def.children.select { |u| u.isKindOf(AbstractOut) } };

MegaSA.loadSynthDefs;
stub = ~tStubServer.();
sa = ~tMegaSA.(stub, if(vst.notNil) { ~tFakePlugin.(\open) });
Synth.tail(stub[\defaultGroup], \looperMaster);
l = ~tLooper.();
Routine { sa.attachLooper(l) }.next;
dc = sa.drumsChain;

// ---- there, empty, built before the drums' effects ---------------------------
~tEq.("the drums have a chain from the start: the third, empty, on the bus the steps' voices play onto",
    [sa.chains.collect(_.track), dc.track, dc.ids, dc.bus.index, sa.chainFor(\drums) === dc],
    [[\guitar, \loop, \drums, \bass], \drums, [], sa.stepsBus.index, true]);
~tEq.("a sound's chains are the same four", MegaSASound.trackNames, [\guitar, \loop, \drums, \bass]);
~tAssert.("it is built with the others", dc.built and: { sa.chains.every(_.built) });
t = ~tNodeTree.(stub);
kids = (t[\children][sa.drumGroup.nodeID] ? []).asArray;
at = kids.indexOf(dc.group.nodeID);
~tAssert.("the drums themselves were built here (their effects synth is there to stand before)", sa.drums.fxSynth.notNil);
~tAssert.("its group is in the drum group, right before the drums' effects, which hold their reverb",
    at.notNil and: { kids[at + 1] == sa.drums.fxSynth.nodeID }, [kids, at].asString);
~tAssert.("...and after the groups the voices play in: a device works on what they played in that block",
    at.notNil and: { [sa.drums.stepsGroup, sa.drums.repeatGroup, sa.drums.onsetGroup].every { |g| kids.indexOf(g.nodeID) < at } },
    kids.asString);
~tEq.("...holding its source alone", (t[\children][dc.group.nodeID] ? []).asArray.collect { |x| t[\defs][x] }, [\megaSAChainOn]);
~tEq.("the source feeds nothing, as the voices have written the bus: one control, the bus, and no output",
    SynthDescLib.global[\megaSAChainOn] !? { |x| [x.controlNames.collect(_.asSymbol), outsOf.(x.def).size] }, [[\bus], 0]);
~tEq.("...started on the steps' bus", ~tStartArgs.(stub, dc.source), (bus: sa.stepsBus.index));
~tAssert.("the onset kit's bus is another: its hits do not pass through the chain", sa.onsetBus.index != dc.bus.index);
~tEq.("a session's header has the drums' chain and its delay", [sa.sessionInfo[\chains].collect { |c| c[\track] }, sa.sessionInfo[\ld]],
    [[\guitar, \loop, \drums, \bass], 0]);

// ---- edits, as on the other chains --------------------------------------------
n = stub[\bundles].size;
said = heard.(sa, { d = sa.insertDevice(\drums, nil, \saturator) });
bundles = stub[\bundles].copyToEnd(n).asArray;
~tEq.("an effect goes onto the drums' chain", [d !? { [d.type, d.on] }, dc.ids, sa.chainOf(d) === dc],
    [[\saturator, true], [d.id], true]);
~tEq.("...said as \\chain for the drums", said.select { |x| x[0] == \chain }, [[\chain, \drums, \insert, d.id, 0]]);
~tEq.("...its synth after the chain's source, on the steps' bus",
    bundles[0][1].collect { |x| x.keep(5) ++ [x[x.indexOf(\bus) + 1]] },
    [[9, \megaSADevSaturator, d.node.nodeID, 3, dc.source.nodeID, sa.stepsBus.index]]);
~tEq.("a device moves from the loop's chain to the drums', to the place asked",
    { sa.moveDevice(\redux, \drums, 0); [dc.ids, sa.loopChain.ids.includes(\redux), sa.chainOf(sa.device(\redux)).track] }.value,
    [[\redux, d.id], false, \drums]);
t = ~tNodeTree.(stub);
~tEq.("...and the server's order is the chain's: the source, then its devices",
    (t[\children][dc.group.nodeID] ? []).asArray.collect { |x| t[\defs][x] }, [\megaSAChainOn, \megaSADevRedux, \megaSADevSaturator]);
~tAssert.("...still right before the drums' effects",
    { var k = (t[\children][sa.drumGroup.nodeID] ? []).asArray; k[k.indexOf(dc.group.nodeID) + 1] == sa.drums.fxSynth.nodeID }.value);
sa.setTempo(100);
~tAssert.("the tempo reaches the drums' chain too", stub[\msgs].any { |x| (x[0] == 15) and: { x[1] == dc.group.nodeID } and: { x[2] == \beatDur } });
~tEq.("a device moves back to the guitar's chain", { sa.moveDevice(\redux, \guitar, 0); [dc.ids, sa.guitarChain.ids.first] }.value,
    [[d.id], \redux]);
~tEq.("a device is removed from it, and undo brings it back there", { sa.removeDevice(d.id); again = dc.ids.copy; sa.undo; [again, dc.ids] }.value,
    [[], [d.id]]);

// ---- in a sound ------------------------------------------------------------------
sound = sa.sound("with drums");
text = sound.fileString;
~tAssert.("a sound holds the drums' chain when something is on it", text.contains("{\"track\": \"drums\", \"devices\": [")
    and: { sound.devices(\drums).collect { |x| x[\id] } == [d.id] }, text);
again = MegaSASound.parse(text);
~tAssert.("...and reads back the same, with nothing to say", again.isKindOf(MegaSASound) and: { again.fileString == text }
    and: { again.problems.isEmpty }, again.asString);
sa.removeDevice(d.id);
bare = sa.sound("bare");
~tAssert.("with nothing on the drums the file has no drums chain: it is the file an older megalooper wrote and reads",
    bare.fileString.contains("\"drums\"").not and: { bare.fileString.contains("{\"track\": \"loop\"") }, bare.fileString);
old = MegaSASound.parse(bare.fileString);
~tAssert.("a sound from before the drums had a chain reads without a word, its drums chain empty",
    old.isKindOf(MegaSASound) and: { old.problems.isEmpty } and: { old.devices(\drums).isEmpty }
        and: { old.fileString == bare.fileString }, old.problems.asString);
~tAssert.("...and is the same content as the chains with an empty drums chain: Keep's mark stays off",
    old.contentString == bare.contentString and: { bare.contentString.contains("drums").not }, bare.contentString);
~tAssert.("a sound that lacks the guitar's or the loop's chain still says so",
    MegaSASound.parse("{\"format\": \"megalooper sound\", \"version\": 1, \"tracks\": [{\"track\": \"guitar\", \"devices\": []}]}").problems
        .any { |p| p.contains("no loop chain") });

// ---- a recall brings the drums' devices --------------------------------------------
~tAssert.("recalling the sound with the drums' effect puts it back on the drums' chain",
    { sa.applySound(again, nil, false); dc.ids == [d.id] }.value, dc.ids.asString);
sa.free;
~tAssert.("free takes the chain off the server", dc.built.not);

// ---- built from a sound, and with no drums built -----------------------------------
stub2 = ~tStubServer.();
sa2 = ~tMegaSA.(stub2, nil, nil, again);
~tEq.("a MegaSA made from that sound starts with the device on its drums' chain, built",
    [sa2.drumsChain.ids, sa2.drumsChain.devices.every { |x| x.node.notNil }], [[d.id], true]);
sa2.free;
// The drums could not be built (their build posts why): the chain is built
// all the same, at the drum group's tail, so every chain is built and a
// sound can be recalled.
stub2 = ~tStubServer.();
sa2 = ~tMegaSA.(stub2);
sa2.drumsChain.free;
sa2.drums.instVarPut(\fxSynth, nil);
sa2.prBuildDrumsChain;
t = ~tNodeTree.(stub2);
~tAssert.("with no drums built the chain is built at the drum group's tail, and every chain is built",
    sa2.drums.fxSynth.isNil and: { sa2.drumsChain.built }
        and: { (t[\children][sa2.drumGroup.nodeID] ? []).asArray.last == sa2.drumsChain.group.nodeID },
    [sa2.drums.fxSynth, t[\children][sa2.drumGroup.nodeID]].asString);
sa2.free;
}.value;
