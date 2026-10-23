// The synth's instrument plugin (MegaSA.setInstrument, docs/dev/synth.md
// Phase 4): an instrument of the catalog played by the note sequencer in
// place of the Wave synth, on the harness's recording stub with a fake
// plugin that says which MIDI it was asked to send. Its synth and where it
// is, the notes as timestamped note-ons and note-offs, a cancelled note's
// note-off at its stamp, nothing while it is not open, back to the Wave
// synth, and its choice and sound kept with the synth.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-megasa-instrument");

{
var stub = ~tStubServer.(), sa, d, fake, made = List.new, l, w = 91.9, sent = List.new, said = List.new, f;
var midi, inst, dir = ~tTempPath.("instrument"), was = MegaFiles.rootOverride, data;
var run = { |to| while { w < (to - 1e-9) } { w = w + 0.01; d.pump(w) } };
var midiOf = { |list| list.collect { |b| b[1].select { |m| m[0] == \midi }.collect { |m| [b[0], m[1], m[2], m[3]] } }.flatten(1) };
MegaSA.loadSynthDefs;
sa = ~tMegaSA.(stub);
d = sa.drums;
fake = { |state| var p = ~tFakePlugin.(state, "Fake Synth");
    p[\midiMsg] = { |self, status, a, b| [\midi, status, a, b] };
    p[\stateExtension] = ".fxp";
    made.add(p);
    p };
sa.pluginMaker = { |synth, id, path| fake.(\open).put(\madeFor, [synth, id, path]) };
sa.catalog = [(key: "Fake Synth", name: "Fake Synth", synth: true, bridged: false),
    (key: "Bridged Synth", name: "Bridged Synth", synth: true, bridged: true),
    (key: "Some Fx", name: "Some Fx", synth: false, bridged: false)];
f = { |obj, what ... args| if(what == \instrument) { said.add(args) } };
sa.addDependant(f);

~tEq.("the instruments to choose: the catalog's instruments, none bridged", sa.instrumentEntries.collect(_[\key]), ["Fake Synth"]);
~tEq.("the Wave synth plays by default", sa.instrumentKey, nil);
stub[\msgs].clear;
~tEq.("an instrument chosen", sa.setInstrument("Fake Synth"), true);
inst = stub[\msgs].detect { |m| (m[0] == 9) and: { m[1] == \megaSAInstrument } };
~tAssert.("...in a synth of its own at the head of the sequencer's group, onto the synth's bus",
    inst.notNil and: { inst[3] == 0 } and: { inst[4] == d.synthGroup.nodeID }
        and: { ().putPairs(inst.copyToEnd(5))[\out] == sa.synthBus.index }, inst.asString);
~tEq.("...made for its key and opened", [made.last[\madeFor][1..2], made.last[\opened]], [[\plugin, "Fake Synth"], 1]);
~tEq.("...and said: open (the fake answers at once), and chosen", said.keep(-2).asArray, [["Fake Synth", true], ["Fake Synth"]]);

// Its notes.
l = ~tLooper.();
~tPut.(l, \state, \playing);
~tPut.(l, \loopFrames, 96000);
~tPut.(l, \loopStartTime, 90.0);
~tPut.(l, \lastResult, (numerator: 4, denominator: 4, k: 1, bpm: 120, loopDur: 2.0));
d.wallClock = { w };
d.sender = { |at, msgs| sent.add([at, msgs]) };
d.attach(l);
d.setNoteValues(\length, [100] ++ (50 ! 15));
d.setNotesOn(true, w);
d.transportStart(w);
run.(92.3);
midi = midiOf.(sent);
~tAssert.("notes were sent as MIDI, no Wave synth voice", midi.notEmpty
    and: { sent.collect(_[1]).flatten(1).every { |m| (m[0] != \s_new) or: { m[1] != \megaSAWaveVoice } } });
~tEq.("a note-on at the note's stamp, channel 1, its pitch and velocity",
    midi.select { |m| m[1] == 144 }.keep(2).collect { |m| [m[0].round(1e-6), m[2], m[3]] }, [[92.02, 60, 100], [92.145, 67, 100]]);
~tEq.("its note-off at its end; held 100 %, 2 ms after the next one's on (legato on a mono patch)",
    midi.select { |m| m[1] == 128 }.keep(2).collect { |m| [m[0].round(1e-6), m[2]] },
    [[92.02 + 0.125 + 0.002, 60], [92.145 + 0.0625, 67]]);
sent.clear;
d.setNotesOn(false, 92.33);
run.(92.6);
midi = midiOf.(sent);
~tAssert.("switched off: each note already sent from then on gets its note-off at its own stamp",
    midi.notEmpty and: { midi.every { |m| (m[1] == 128) } } and: { midi.any { |m| (m[0] - 92.395).abs < 1e-6 } },
    midi.collect { |m| [m[0].round(1e-6), m[1], m[2]] }.asString);

// Not open: nothing is sent.
sa.pluginMaker = { |synth, id, path| fake.(\failed) };
sa.setInstrument("Fake Synth");
sent.clear;
d.setNotesOn(true, w);
run.(93.0);
~tEq.("a plugin that did not open plays nothing", midiOf.(sent), []);

// Back to the Wave synth.
stub[\msgs].clear;
sent.clear;
sa.setInstrument(nil);
~tAssert.("the Wave synth again: the plugin's synth goes", stub[\msgs].any { |m| m[0] == 11 });
run.(93.4);
~tAssert.("...and its voices play the notes", sent.collect(_[1]).flatten(1).any { |m| (m[0] == \s_new) and: { m[1] == \megaSAWaveVoice } });

// Kept with the synth: the instrument and its sound beside the file.
sa.pluginMaker = { |synth, id, path| fake.(\open) };
sa.setInstrument("Fake Synth");
MegaFiles.rootOverride = dir;
protect {
    ~tEq.("Keep writes the synth", sa.keepSynth, true);
    data = MegaSASynthFile.read(MegaSA.defaultKeptSynthPath);
    ~tEq.("...naming the instrument and its sound, which the plugin wrote beside it",
        [data[\instrument], data[\instrumentState], File.exists(MegaSA.defaultKeptSynthPath.dirname +/+ "synth.fxp")],
        ["Fake Synth", "synth.fxp", true]);
    sa.setInstrument(nil);
    ~tEq.("the next boot starts with it, its sound loaded", [sa.loadKeptSynth, sa.instrumentKey,
        made.last[\openedWith] !? { |x| x[\path].basename }], [true, "Fake Synth", "synth.fxp"]);
    sa.setInstrument(nil);
    sa.keepSynth;
    ~tEq.("kept with the Wave synth, it says none", MegaSASynthFile.read(MegaSA.defaultKeptSynthPath)[\instrument], nil);
} {
    MegaFiles.rootOverride = was;
    ~tRemoveTree.(dir);
};
sa.removeDependant(f);
sa.free;
}.value;
