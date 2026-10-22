// Megalooper SA's fourth chain, the bass's: on a rig with a bass input
// (the profile's bassChannel) it reads that input onto a bus of its own,
// plays its effects there, in the guitar group after the guitar's chain, and
// reaches the master through a strip of its own, after the guitar's, with a
// stem in the set's recording. The Looper still records the guitar alone. On
// a rig without one the chain is there all the same, on silence, so a sound's
// bass devices are kept, but there is no strip, no level, no mute and no
// stem. A sound holds the chain only when it holds something.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-megasa-bass");

{
var stub, sa, l, t, kids, bc, d, n, bundles, said, heard, sound, text, again, bare, old, stub2, sa2, argsOf;

heard = { |obj, fn|
    var got = List.new, f = { |o, what ... more| got.add([what] ++ more) };
    obj.addDependant(f);
    protect { fn.value } { obj.removeDependant(f) };
    got.asArray
};
argsOf = { |node| ~tStartArgs.(stub, node) };

MegaSA.loadSynthDefs;

// ---- a rig without a bass input ---------------------------------------------------
stub = ~tStubServer.();
sa = ~tMegaSA.(stub);
bc = sa.bassChain;
t = ~tNodeTree.(stub);
~tEq.("without a bass input the bass chain is there all the same, empty, on a bus of its own",
    [sa.bassIn, bc.track, bc.ids, bc.bus === sa.bassBus, sa.chainFor(\bass) === bc, bc.built],
    [nil, \bass, [], true, true, true]);
~tEq.("...in the guitar group after the guitar's chain, so before the Looper",
    (t[\children][sa.guitarGroup.nodeID] ? []).asArray, [sa.guitarChain.group.nodeID, bc.group.nodeID]);
~tEq.("...its source feeding nothing: the effects work on silence",
    (t[\children][bc.group.nodeID] ? []).asArray.collect { |x| t[\defs][x] }, [\megaSAChainOn]);
~tEq.("...and no strip, level, mute or stem",
    [sa.strips[\bass], sa.level(\bass), sa.mute(\bass), sa.stemBus(\bass), sa.stemSpecs.collect { |x| x[\role] }],
    [nil, nil, nil, nil, [\guitar, \loop, \drums, \onset]]);
~tEq.("the strips are the four of before", sa.stripBusses.clump(2).collect(_[0]), [\guitar, \loop, \drums, \onsetKit]);
sa.free;

// ---- a rig with one ---------------------------------------------------------------
stub = ~tStubServer.();
sa = ~tMegaSA.(stub, nil, nil, nil, nil, nil, 1);
// The loop's chain needs a Looper: a recall waits for every chain.
Synth.tail(stub[\defaultGroup], \looperMaster);
l = ~tLooper.();
Routine { sa.attachLooper(l) }.next;
bc = sa.bassChain;
t = ~tNodeTree.(stub);
~tEq.("with a bass input on 2 (SoundIn 1) the chain reads it onto its bus",
    [sa.bassIn, (t[\children][bc.group.nodeID] ? []).asArray.collect { |x| t[\defs][x] }, argsOf.(bc.source)],
    [1, [\megaSAChainIn], (in: 1, bus: sa.bassBus.index)]);
~tEq.("...in the guitar group after the guitar's chain",
    (t[\children][sa.guitarGroup.nodeID] ? []).asArray, [sa.guitarChain.group.nodeID, bc.group.nodeID]);
~tAssert.("its bus is none of the others", ([sa.guitarBus, sa.loopBus, sa.loopFxBus, sa.masterBus, sa.recordBus,
    sa.stepsBus, sa.stepsOutBus, sa.onsetBus, sa.onsetOutBus].collect(_.index) ++ sa.stemBusses.values.collect(_.index))
    .includes(sa.bassBus.index).not);
~tEq.("the Looper still records the guitar chain alone", sa.looperInChannel, sa.soundInChannel(sa.guitarBus));
~tEq.("the strips in mixer order, the bass's after the guitar's",
    sa.stripBusses.clump(2).collect(_[0]), [\guitar, \bass, \loop, \drums, \onsetKit]);
~tEq.("...the bass's reading its bus, at 0 dB, unmuted, onto its own stem bus",
    [\in, \amp, \mute, \stem].collect { |k| argsOf.(sa.strips[\bass])[k] },
    [sa.bassBus.index, 1, 0, sa.stemBus(\bass).index]);
~tEq.("...into the master with the others", argsOf.(sa.strips[\bass])[\out], sa.masterBus.index);
~tEq.("the set records a bass stem, after the guitar's",
    sa.stemSpecs.collect { |x| [x[\role], x[\numChannels]] },
    [[\guitar, 2], [\bass, 2], [\loop, 2], [\drums, 2], [\onset, 2]]);
~tEq.("...from its strip's stem bus", sa.stemSpecs[1][\channel], sa.soundInChannel(sa.stemBus(\bass)));
~tAssert.("...which the session recorder takes", LooperSessionRecorder.stemProblem(sa.stemSpecs[1], nil).isNil);
said = heard.(sa, { sa.setLevel(\bass, 0.5) });
~tEq.("its level is set on its strip and said", [stub[\msgs].last, said], [[15, sa.strips[\bass].nodeID, \amp, 0.5], [[\level, \bass, 0.5]]]);
sa.setMute(\bass, true);
~tEq.("...and its mute", [stub[\msgs].last, sa.muted(\bass)], [[15, sa.strips[\bass].nodeID, \mute, 1], true]);
sa.setMute(\bass, false);

// ---- edits, as on the other chains ----------------------------------------------
n = stub[\bundles].size;
said = heard.(sa, { d = sa.insertDevice(\bass, nil, \saturator) });
bundles = stub[\bundles].copyToEnd(n).asArray;
~tEq.("an effect goes onto the bass chain", [d !? { [d.type, d.on] }, bc.ids, sa.chainOf(d) === bc],
    [[\saturator, true], [d.id], true]);
~tEq.("...said as \\chain for the bass", said.select { |x| x[0] == \chain }, [[\chain, \bass, \insert, d.id, 0]]);
~tEq.("...its synth after the chain's source, on the bass's bus",
    bundles[0][1].collect { |x| x.keep(5) ++ [x[x.indexOf(\bus) + 1]] },
    [[9, d.defName, d.node.nodeID, 3, bc.source.nodeID, sa.bassBus.index]]);
~tEq.("a device moves from the guitar's chain to the bass's, to the place asked",
    { sa.moveDevice(\delay, \bass, 0); [bc.ids, sa.guitarChain.ids.includes(\delay), sa.chainOf(sa.device(\delay)).track] }.value,
    [[\delay, d.id], false, \bass]);
t = ~tNodeTree.(stub);
~tEq.("...and the server's order is the chain's", (t[\children][bc.group.nodeID] ? []).asArray,
    [bc.source.nodeID] ++ bc.devices.collect { |x| x.node.nodeID });
~tEq.("undo puts it back on the guitar's", { sa.undo; [bc.ids, sa.guitarChain.ids.includes(\delay)] }.value, [[d.id], true]);
sa.setTempo(100);
~tAssert.("the tempo reaches the bass chain too",
    stub[\msgs].any { |x| (x[0] == 15) and: { x[1] == bc.group.nodeID } and: { x[2] == \beatDur } });
~tEq.("a session's header has the bass chain and its delay",
    [sa.sessionInfo[\chains].collect { |c| c[\track] }, sa.sessionInfo[\chains][3][\devices].collect { |x| x[\id] }, sa.sessionInfo[\lb]],
    [[\guitar, \loop, \drums, \bass], [d.id], bc.latency(sa.sampleRate) / sa.sampleRate]);

// ---- in a sound ----------------------------------------------------------------
sound = sa.sound("with bass");
text = sound.fileString;
~tAssert.("a sound holds the bass chain when something is on it", text.contains("{\"track\": \"bass\", \"devices\": [")
    and: { sound.devices(\bass).collect { |x| x[\id] } == [d.id] }, text);
again = MegaSASound.parse(text);
~tAssert.("...and reads back the same, with nothing to say", again.isKindOf(MegaSASound) and: { again.fileString == text }
    and: { again.problems.isEmpty }, again.asString);
sa.removeDevice(d.id);
bare = sa.sound("bare");
~tAssert.("with nothing on the bass the file has no bass chain: it is the file an older megalooper wrote and reads",
    bare.fileString.contains("\"bass\"").not, bare.fileString);
old = MegaSASound.parse(bare.fileString);
~tAssert.("a sound from before the bass had a chain reads without a word, its bass chain empty",
    old.isKindOf(MegaSASound) and: { old.problems.isEmpty } and: { old.devices(\bass).isEmpty }, old.problems.asString);
~tAssert.("recalling the sound with the bass's effect puts it back on the bass chain",
    { sa.applySound(again, nil, false); bc.ids == [d.id] }.value, bc.ids.asString);
sa.free;
~tAssert.("free takes the chain off the server", bc.built.not);

// ---- that sound on a rig without a bass input --------------------------------------
stub = ~tStubServer.();
sa2 = ~tMegaSA.(stub, nil, nil, again);
~tEq.("on a rig without a bass input the sound's bass devices are built, on silence",
    [sa2.bassChain.ids, sa2.bassChain.devices.every { |x| x.node.notNil }, sa2.strips[\bass]], [[d.id], true, nil]);
~tEq.("...and a sound saved there keeps them", sa2.sound("kept").devices(\bass).collect { |x| x[\id] }, [d.id]);
sa2.free;
}.value;
