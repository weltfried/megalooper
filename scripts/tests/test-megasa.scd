// Megalooper SA's language-side half: the \sa routing profile, the server
// options it sets and gives back, the mixer's level and mute model, its
// SynthDefs, the drums it owns (MegaSADrums: made with it, built in its tree,
// handed the Looper, freed first), and the stems it hands the session recorder
// (its strips after their faders), on a recording stub. How it sounds is the
// rig's to check: Phase 1 in docs/dev/megalooper-sa.md.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-megasa");

{
var scripts = thisProcess.nowExecutingPath.dirname.dirname;
var rp, saved, m, master, strip, fx, tmp, stub;

if(~routingProfiles.isNil or: { ~applyServerOptions.isNil }) {
    (scripts +/+ "setup-routing.scd").load;
};
if(~saGuitarBank.isNil) { (scripts +/+ "setup-sa.scd").load };
if(~setupMidiIO.isNil) { (scripts +/+ "setup-midi.scd").load };
// The router, and the TSMega's shipped map, which gives SA's programs to its
// effects and drums.
if(~midiTargetsBuild.isNil) { (scripts +/+ "setup-miditargets.scd").load };
if(~midiRouteWith.isNil) { (scripts +/+ "setup-midimap.scd").load };
rp = ~routingProfiles[\sa];

// ---------------------------------------------------------------- profile --
~tAssert.("the \\sa profile exists", rp.notNil);
~tEq.("it names TSMEGA itself, no aggregate", rp[\device], "TSMEGA");
~tAssert.("it builds the SA mixer and has no Live",
    (rp[\sa] == true) and: { rp[\live] == false });
~tEq.("it records both sides of the guitar chain", rp[\inChannelCount], 2);
~tAssert.("it reads nothing back (no Live to return the loop)", rp[\returnChannel].isNil);
~tEq.("the guitar comes in on TSMEGA's input 1", rp[\inChannel], 0);
~tEq.("and the onset analysis reads that input dry", rp[\analysisChannel], 0);
~tAssert.("the loop has no hardware channel: it goes to the mixer", rp[\outChannel].isNil);
~tAssert.("its device is switched to 48 kHz before the boot",
    (rp[\sampleRate] == 48000) and: { rp[\setSampleRate] == true });
~tEq.("it boots at 64 frames", rp[\hardwareBufferSize], 64);

// ---------------------------------------------------- \saSystem --
// SA on whatever interface a stranger has: the system's default devices, the
// guitar on input 1, nothing switched or forced.
{
    var sys = ~routingProfiles[\saSystem];
    ~tAssert.("the \\saSystem profile exists", sys.notNil);
    sys !? {
        ~tAssert.("it is SA with no Live", (sys[\sa] == true) and: { sys[\live] == false });
        ~tEq.("on the system's default devices", sys[\device], \systemDefault);
        ~tEq.("the guitar on input 1, analysed dry there", [sys[\inChannel], sys[\analysisChannel]], [0, 0]);
        ~tEq.("...both sides of its chain recorded", sys[\inChannelCount], 2);
        ~tAssert.("it forces no rate and no block size",
            sys[\setSampleRate].isNil and: { sys[\sampleRate].isNil } and: { sys[\hardwareBufferSize].isNil });
        ~tEq.("it asks for SA's 64 MB pool", sys[\memSize], 65536);
        ~tAssert.("it names no MIDI map: none is assumed", sys[\midiMap].isNil);
        ~tEq.("its overdub latency starts at the master limiter's 20 ms plus a direct interface's 10",
            sys[\latencyMs], 30);
        ~tEq.("the Live preflight has nothing to say on it either", ~checkLiveAudio.(\saSystem), []);
    };
    // Two rigs on the system's default devices: the launcher says which one
    // has the effect chains and the drums.
    ~tAssert.("the launcher says an SA rig has the effect chains and the drums",
        [\sa, \saSystem].every { |k| var t = ~routingProfileSays.(k); t.contains("effect chains") and: { t.contains("drums") }
            and: { t.contains("saSystem").not } });
    ~tAssert.("...that standalone is the looper alone, and where the rest is",
        ~routingProfileSays.(\standalone).contains("looper alone") and: { ~routingProfileSays.(\standalone).contains("saSystem") });
    ~tAssert.("...and that every other rig plays beside Live",
        ~routingProfiles.keys.reject { |k| (k == \standalone) or: { ~routingProfiles[k][\sa] == true } }
            .every { |k| ~routingProfileSays.(k) == "The looper beside Ableton Live." });
    ~tEq.("...and nothing of a rig it does not know", ~routingProfileSays.(\noSuchRig), "");
}.value;

// --------------------------------------------------- VSTPlugin preflight --
// What a stranger's Mac gets wrong silently, said at boot on an SA profile,
// from facts stubbed here (the real ones read the disk and xattr).
{
    var real = ~vstPluginFacts, notes, facts;
    var with = { |f| ~vstPluginFacts = { f }; ~checkVSTPlugin.(\sa) };
    facts = (installed: true, version: [0, 6, 2], dir: "/x/Extensions/VSTPlugin/plugins", supernova: false, quarantined: []);
    ~tEq.("a sound install says nothing", with.(facts), []);
    notes = with.(facts.copy.put(\installed, false).put(\version, nil));
    ~tAssert.("no VSTPlugin is said: SA plays its built-ins", (notes.size == 1) and: { notes[0].contains("not installed") }, notes.asString);
    notes = with.(facts.copy.put(\supernova, true));
    ~tAssert.("a supernova copy beside it is said, with what to delete", (notes.size == 1) and: { notes[0].contains("VSTPlugin_supernova.scx") }, notes.asString);
    notes = with.(facts.copy.put(\quarantined, ["VSTPlugin.scx", "host"]));
    ~tAssert.("a quarantined copy is said, with the command that frees it",
        (notes.size == 1) and: { notes[0].contains("xattr -dr com.apple.quarantine") } and: { notes[0].contains("host") }, notes.asString);
    notes = with.(facts.copy.put(\version, [0, 7, 0]));
    ~tAssert.("another version is said", (notes.size == 1) and: { notes[0].contains("0.7.0") }, notes.asString);
    ~vstPluginFacts = { facts.copy.put(\installed, false) };
    ~tEq.("a rig that is not SA is not checked", ~checkVSTPlugin.(\bhTsMega), []);
    ~vstPluginFacts = real;
    ~tAssert.("the real facts read without throwing", ~tCheck.("(VSTPlugin's facts)", { ~vstPluginFacts.() }).notNil);
}.value;

// --------------------------------------------------------- server options --
// ~applyServerOptions writes the default server's options: keep and restore.
saved = [s.options.hardwareBufferSize, s.options.sampleRate, ~serverOptionsBefore, s.options.memSize];
~serverOptionsBefore = nil;
s.options.hardwareBufferSize = nil;
s.options.sampleRate = nil;
s.options.memSize = 8192;
~applyServerOptions.(rp);
~tEq.("\\sa asks for 64 frames", s.options.hardwareBufferSize, 64);
~tEq.("\\sa asks for 48 kHz", s.options.sampleRate, 48000);
~tEq.("\\sa asks for a 64 MB real-time pool, for its effects' delay lines", s.options.memSize, 65536);
~applyServerOptions.(~routingProfiles[\bhTsMega]);
~tEq.("the next profile gets the original buffer size back",
    s.options.hardwareBufferSize, nil);
~tEq.("and a profile that only EXPECTS a rate does not force one",
    s.options.sampleRate, nil);
~tEq.("and the pool it had", s.options.memSize, 8192);
s.options.hardwareBufferSize = saved[0];
s.options.sampleRate = saved[1];
~serverOptionsBefore = saved[2];
s.options.memSize = saved[3];

~tEq.("the Live preflight has nothing to say on \\sa", ~checkLiveAudio.(\sa), []);

// ------------------------------------------------------------- rate switch --
// The device preflight, with CoreAudio and the switch stubbed: a real switch
// would change the interface under whatever is using it.
{
    var realInfo = ~audioDeviceInfo, realSwitch = ~switchDeviceRate;
    var switched = List.new, holds = true, notes;
    var tsmega = (name: "TSMEGA", in: 2, out: 2, rate: 44100);
    ~switchDeviceRate = { |name, rate| switched.add([name.asString, rate]); holds };
    ~audioDeviceInfo = { IdentityDictionary[\TSMEGA -> tsmega] };
    notes = ~checkAudioDevice.(\sa);
    ~tEq.("the preflight switches TSMEGA from 44.1 to 48 kHz",
        switched.asArray, [["TSMEGA", 48000]]);
    ~tEq.("and reports nothing when the switch holds", notes, []);
    holds = false;
    notes = ~checkAudioDevice.(\sa);
    ~tAssert.("a switch that does not hold is reported",
        notes.includesEqual("could not switch the sample rate"), "notes: " ++ notes);
    switched = List.new;
    tsmega[\rate] = 48000;
    ~checkAudioDevice.(\sa);
    ~tEq.("a device already at 48 kHz is left alone", switched.asArray, []);
    // An aggregate Live shares is never switched, only warned about.
    ~audioDeviceInfo = {
        IdentityDictionary[
            'MegaLoop BH (TSMega)' -> (name: "MegaLoop BH (TSMega)", in: 18, out: 20, rate: 44100),
            \TSMEGA -> (name: "TSMEGA", in: 2, out: 2, rate: 44100),
            'BlackHole 16ch' -> (name: "BlackHole 16ch", in: 16, out: 16, rate: 44100),
            'MacBook Pro Speakers' -> (name: "MacBook Pro Speakers", in: 0, out: 2, rate: 44100)
        ]
    };
    notes = ~checkAudioDevice.(\bhTsMega);
    ~tEq.("\\bhTsMega is never switched", switched.asArray, []);
    ~tAssert.("but its mismatch is still reported",
        notes.includesEqual("sample-rate mismatch"), "notes: " ++ notes);
    ~audioDeviceInfo = realInfo;
    ~switchDeviceRate = realSwitch;
}.value;

// ------------------------------------------------------- not on macOS --
// What megalooper asks of macOS alone (CoreAudio's device list, the
// quarantine flag) it does not ask on Linux, where the asking itself fails.
{
    var names, info, facts;
    protect {
        MegaFiles.platformOverride = \linux;
        names = ~tCheck.("the device names are asked for on Linux without a throw", { ~audioDeviceNames.() });
        ~tEq.("...and are none: JACK or PipeWire has the interface there", names, []);
        info = ~tCheck.("the device preflight's list on Linux", { ~audioDeviceInfo.() });
        ~tEq.("...is empty, which every caller takes as: cannot check", info !? { |i| i.size }, 0);
        facts = ~tCheck.("VSTPlugin's facts on Linux", { ~vstPluginFacts.() });
        ~tEq.("...name nothing quarantined: the flag is macOS's", facts !? { |f| f[\quarantined] }, []);
    } { MegaFiles.platformOverride = nil };
    if(thisProcess.platform.name == \osx) {
        ~tAssert.("on macOS the device names are CoreAudio's, as Strings",
            ~audioDeviceNames.().isKindOf(Array) and: { ~audioDeviceNames.().every(_.isString) }, ~audioDeviceNames.().asString);
    };
}.value;

// ------------------------------------------------------------------ mixer --
// A real MegaSA on the harness's recording stub, its server side built
// (~tMegaSA): the levels and switches below are the ones it boots with.
m = ~tMegaSA.();
m.setLevel(\loop, -0.5);
~tEq.("a level never goes below 0", m.level(\loop), 0);
m.setLevel(\master, 0.7);
~tEq.("the master has a level of its own", m.level(\master), 0.7);
m.setMute(\guitar, true);
~tEq.("a mute holds", m.mute(\guitar), true);
~tCheck.("an unknown strip warns rather than throws",
    { m.setLevel(\theremin, 1); m.setMute(\master, true) });
~tEq.("and adds nothing", m.levels.keys.asArray.collect(_.asString).sort,
    ["drums", "guitar", "loop", "master", "onsetKit", "synth"]);

// ------------------------------------------------------- effect switches --
~tEq.("the guitar's effects, in the Live set's order",
    MegaSAFx.guitarKeys, [\shifter, \delay, \filter, \pitchLoop]);
~tEq.("the loop's effects, in the Live set's order",
    MegaSAFx.loopKeys, [\echo, \saturator, \redux]);
~tAssert.("every effect starts off, as the Live set left them", MegaSAFx.keys.every { |k| m.fx(k) == false });
m.setFx(\redux, true);
~tEq.("a loop effect switches like a guitar one", m.fx(\redux), true);
m.setFx(\redux, false);
m.setFx(\filter, true);
~tEq.("an effect switches on", m.fx(\filter), true);
m.toggleFx(\filter);
~tEq.("and a toggle switches it off", m.fx(\filter), false);
m.toggleFx(\pitchLoop);
~tEq.("a toggle from off is on", m.fx(\pitchLoop), true);
~tCheck.("an unknown effect warns rather than throws", { m.toggleFx(\wah) });
~tAssert.("and is not added", m.fxOn.includesKey(\wah).not);
// The footswitches are the TSMega's shipped map (presets/midi/tsmega.json):
// the programs the Live set mapped the effects and the drums' rack to. Read
// as shipped, from a scratch folder of yours: never the player's own map.
{
    var keep = ~midiUserRootOverride, map;
    var at = { |p| map !? { |x| x.lookup(\program, 0, p).collect { |s| s[\binding][\target] } } };
    ~midiUserRootOverride = ~tTempPath.("megasa-midi");
    map = ~midiMapLoad.("tsmega")[\map];
    ~midiUserRootOverride = keep;
    ~tEq.("PC 8, 9, 10, 11 are the delay, PitchLoop, filter, shifter",
        [8, 9, 10, 11].collect { |p| at.(p) }, [['sa.fxOn.delay'], ['sa.fxOn.pitchLoop'], ['sa.fxOn.filter'], ['sa.fxOn.shifter']]);
    ~tEq.("PC 12, 14, 15 are the loop's echo, saturator, redux",
        [12, 14, 15].collect { |p| at.(p) }, [['sa.fxOn.echo'], ['sa.fxOn.saturator'], ['sa.fxOn.redux']]);
    ~tEq.("PC 17 switches the drums' steps, as it switched the Live set's rack", at.(17), ['sa.drums.on']);
    ~tEq.("no program drives two things: PC 8 is the delay alone, and the cutter keeps 18",
        [map !? { |x| x.problems.size }, at.(8), at.(18)], [0, ['sa.fxOn.delay'], ['looper.bbcut']]);
}.value;
m.free;

// The Looper's SoundIn has to land on guitarBus: In.ar(numOutputs + channel).
// Bus arithmetic only, on a MegaSA with no server (newCopyArgs skips init).
m = MegaSA.newCopyArgs(nil, 0, 0);
stub = (options: ServerOptions.new.numOutputBusChannels_(2));
m.instVarPut(\server, stub);
m.instVarPut(\guitarBus, Bus(\audio, 4, 2, stub));
~tEq.("the Looper's input channel reads guitarBus through SoundIn",
    m.looperInChannel + stub.options.numOutputBusChannels, 4);
stub.options.numOutputBusChannels = 16;
m.instVarPut(\guitarBus, Bus(\audio, 40, 2, stub));
~tEq.("whatever the output count", m.looperInChannel, 24);
m.instVarPut(\loopFxBus, Bus(\audio, 44, 2, stub));
m.instVarPut(\recordBus, Bus(\audio, 48, 2, stub));
~tEq.("loop chaining reads the loop after its effects", m.returnInChannel, 28);
~tEq.("the session's master reads the mix", m.recordInChannel, 32);
m.setTempo(120);
~tEq.("the echo's beat follows the tempo", m.beatDur, 0.5);
m.setTempo(nil);
m.setTempo(0);
~tEq.("and ignores a reading with no tempo", m.beatDur, 0.5);
// Made without its init, as the GUI checks make one, it has no drums: what
// hands them anything must not mind.
~tCheck.("a MegaSA with no drums still takes a reading", { m.setAnalysis((bpm: 100, numerator: 4)) });
~tNear.("...its tempo reaching the effects", m.beatDur, 0.6, 1e-12);
~tCheck.("...and frees", { m.free });
~tAssert.("the session recorder's synths go where they always did unless told",
    LooperSessionRecorder(nil, nil).target.isNil);
~tEq.("the \\sa profile starts the chain recorder 20 ms late, for the master's limiter",
    rp[\chainRecOffsetMs], 20);

// --------------------------------------------------------------- bank pick --
tmp = ~tTempPath.("megasa-test-banks");
File.mkdir(tmp);
~tAssert.("no bank at all is nil, not an error", ~saGuitarBank.(tmp).isNil);
File.use(tmp +/+ "guitar-rig-model-t-no-gain.fxb", "w", { |f| f.write("x") });
~tEq.("the Live export is used when nothing was saved",
    PathName(~saGuitarBank.(tmp)).fileName, "guitar-rig-model-t-no-gain.fxb");
File.use(tmp +/+ "current.fxb", "w", { |f| f.write("x") });
~tEq.("a bank saved from SA wins over the Live export",
    PathName(~saGuitarBank.(tmp)).fileName, "current.fxb");
(tmp +/+ "*").pathMatch.do { |p| File.delete(p) };
File.delete(tmp);

// ------------------------------------------------------------- SynthDefs --
// The drums' defs go out of the library first, so it is MegaSA's call that
// brings them back.
[\megaSADrumVoice1, \megaSADrumVoice2, \megaSADrumsProbe, \megaSADrumsFx, \megaSAOnsetFx].do { |name|
    SynthDescLib.global.synthDescs.removeAt(name);
};
~tCheck.("MegaSA's SynthDefs build with no server", { MegaSA.loadSynthDefs });
~tAssert.("...the drums' with them",
    [\megaSADrumVoice1, \megaSADrumVoice2, \megaSADrumsProbe, \megaSADrumsFx, \megaSAOnsetFx]
        .every { |name| SynthDescLib.global[name].notNil });
[
    \megaSAStrip,    [\in, \out, \amp, \mute, \stem],
    \megaSAMaster,   [\in, \out, \rec, \amp]
].pairsDo { |name, controls|
    var desc = SynthDescLib.global[name];
    ~tAssert.(name ++ " is in the library", desc.notNil);
    desc !? { |d| ~tEq.(name ++ " has exactly its controls",
        d.controlNames.collect(_.asSymbol), controls) };
};
// Each effect is a device with a SynthDef of its own (test-megasa-chains.scd
// has the rest of their rules); what matters here is that every switch is
// there for MegaSA:setFx to reach.
MegaSAFx.keys.do { |k|
    var desc = SynthDescLib.global[MegaSAFx.deviceDefName(k)];
    var names = desc !? { |d| d.controlNames.collect(_.asSymbol) } ? [];
    ~tAssert.(MegaSAFx.deviceDefName(k) ++ " has its effect's switch, and its bus",
        names.includes((k ++ "On").asSymbol) and: { names.includes(\bus) }, "controls: " ++ names);
};
// ------------------------------------------------------ effect settings --
// MegaSAFx.params is the one table: the SynthDefs' controls, the Effects
// pane's knobs, the presets and their validation all read it, so it has to
// agree with the SynthDefs it describes.
{
    var params = MegaSAFx.params;
    var names = params.collect { |p| p[\name] };
    // Each setting's device: the SynthDef of its effect's type.
    var descOf = { |p| SynthDescLib.global[MegaSAFx.deviceDefName(p[\fx])] };
    var controlOf = { |desc, name| desc !? { |d| d.controls.detect { |c| c.name.asSymbol == name } } };
    ~tAssert.("every effect has settings", MegaSAFx.keys.every { |k| MegaSAFx.paramsOf(k).notEmpty });
    ~tEq.("no setting is listed twice", names.asSet.size, names.size);
    ~tAssert.("every setting belongs to an effect", params.every { |p| MegaSAFx.keys.includes(p[\fx]) });
    ~tAssert.("and is named after it, as the presets' files group them",
        params.every { |p| p[\name].asString.beginsWith(p[\fx].asString) },
        params.reject { |p| p[\name].asString.beginsWith(p[\fx].asString) }.collect(_[\name]));
    ~tAssert.("every label fits under a knob (12 characters)",
        params.every { |p| p[\label].size <= 12 }, params.select { |p| p[\label].size > 12 }.collect(_[\label]));
    ~tAssert.("every setting has a tip", params.every { |p| p[\tip].notNil and: { p[\tip].size > 10 } });
    ~tAssert.("every default lies in its range and on its step",
        params.every { |p| MegaSAFx.constrain(p[\name], p[\spec].default) == p[\spec].default },
        params.reject { |p| MegaSAFx.constrain(p[\name], p[\spec].default) == p[\spec].default }
            .collect { |p| p[\name] -> p[\spec].default });
    params.do { |p|
        var c = controlOf.(descOf.(p), p[\name]);
        // Controls are 32-bit floats: 520.1 comes back as 520.09998.
        ~tAssert.(p[\name] ++ " is a control of its effect's device, defaulting to the table's value",
            c.notNil and: { (c.defaultValue - p[\spec].default).abs
                <= (p[\spec].default.abs * 1e-6).max(1e-6) },
            if(c.isNil) { "no such control" } { "SynthDef " ++ c.defaultValue ++ ", table " ++ p[\spec].default });
    };
    ~tAssert.("...and of no other effect's: a setting is its own effect's alone",
        params.every { |p| MegaSAFx.keys.reject { |k| k == p[\fx] }.every { |k|
            controlOf.(SynthDescLib.global[MegaSAFx.deviceDefName(k)], p[\name]).isNil } });
    ~tAssert.("no setting is init-rate: every one can move while the effect plays",
        params.every { |p| controlOf.(descOf.(p), p[\name]) !? { |c| c.rate != \scalar } ? false });
    params.select { |p| p[\choices].notNil }.do { |p|
        var values = p[\choices].collect(_[0]);
        ~tAssert.(p[\name] ++ "'s choices are sorted and hold its default",
            (values == values.copy.sort) and: { values.includes(p[\spec].default) });
    };
}.value;

// The model, on a MegaSA whose server is the harness's recording stub: what
// it sends is readable with no scsynth.
{
    var stub = ~tStubServer.();
    var sa = ~tMegaSA.(stub);
    var looper = ~tLooper.();
    var seen = List.new, ctl, guitarP, loopP, before, msg;
    var tmp = ~tTempPath.("megasa-test-fx");
    var data, warnings, clean, slug, text, wrote, said, heard, l2, args, strip, sa2;
    // What MegaSA said while `fn` ran: [what, args...] per notification.
    heard = { |fn|
        var got = List.new;
        var f = { |obj, what ... more| got.add([what] ++ more) };
        sa.addDependant(f);
        protect { fn.value } { sa.removeDependant(f) };
        got.asArray
    };
    // The loop's effects come with a Looper, as on SA.
    Routine { sa.attachLooper(looper) }.next;
    ctl = SimpleController(sa).put(\fxParam, { |obj, what, name, val| seen.add([name, val]) });
    guitarP = MegaSAFx.paramsOf(MegaSAFx.guitarKeys.first).first;
    loopP = MegaSAFx.paramsOf(MegaSAFx.loopKeys.first).first;

    ~tEq.("every setting starts at the Live set's value",
        MegaSAFx.params.every { |p| sa.fxParam(p[\name]) == p[\spec].default }, true);
    ~tAssert.("and no effect counts as edited", MegaSAFx.keys.every { |k| sa.fxEdited(k).not });

    sa.setFxParam(guitarP[\name], guitarP[\spec].map(0.75));
    msg = stub[\msgs].last;
    ~tNear.("a setting is kept", sa.fxParam(guitarP[\name]),
        MegaSAFx.constrain(guitarP[\name], guitarP[\spec].map(0.75)), 1e-6);
    ~tAssert.("and sent to the guitar chain as n_set",
        (msg[0] == 15) and: { msg[1] == sa.fxNode(guitarP[\fx]).nodeID } and: { msg[2] == guitarP[\name] }, msg.asString);
    ~tEq.("and announced for the Effects pane", seen.last[0], guitarP[\name]);
    ~tAssert.("its effect now counts as edited", sa.fxEdited(guitarP[\fx]));
    sa.setFxParam(loopP[\name], loopP[\spec].map(0.25));
    msg = stub[\msgs].last;
    ~tAssert.("a loop effect's setting goes to the loop's chain",
        (msg[0] == 15) and: { msg[1] == sa.fxNode(loopP[\fx]).nodeID } and: { msg[2] == loopP[\name] }, msg.asString);
    ~tAssert.("...which is not the guitar's", sa.fxNode(loopP[\fx]).nodeID != sa.fxNode(guitarP[\fx]).nodeID);
    // One notification per change, in the shape the Effects pane and the MIDI
    // targets expect: \fx (key, flag), \fxParam (name, value).
    said = heard.({ sa.setFx(loopP[\fx], true) });
    ~tEq.("a switch says \\fx once, with the effect and its state", said, [[\fx, loopP[\fx], true]]);
    said = heard.({ sa.setFxParam(loopP[\name], loopP[\spec].map(0.25)) });
    ~tEq.("a setting says \\fxParam once, with its name and value", said, [[\fxParam, loopP[\name], sa.fxParam(loopP[\name])]]);
    said = heard.({ sa.setFx(loopP[\fx], false) });
    ~tEq.("...and off again", said, [[\fx, loopP[\fx], false]]);
    sa.setFxParam(guitarP[\name], guitarP[\spec].maxval * 10 + 1000);
    ~tEq.("a value past the range is held to it", sa.fxParam(guitarP[\name]),
        guitarP[\spec].clipHi.round(guitarP[\spec].step));
    before = stub[\msgs].size;
    ~tCheck.("an unknown setting warns rather than throws", { sa.setFxParam(\wahWah, 1) });
    ~tCheck.("so does a setting given no number", { sa.setFxParam(guitarP[\name], "loud") });
    ~tEq.("and neither sends anything", stub[\msgs].size, before);
    ~tAssert.("nor adds a setting", sa.fxParams.includesKey(\wahWah).not);

    sa.resetFx(guitarP[\fx]);
    ~tAssert.("Live values puts every setting of the effect back",
        MegaSAFx.paramsOf(guitarP[\fx]).every { |p| sa.fxParam(p[\name]) == p[\spec].default });
    ~tAssert.("and it no longer counts as edited", sa.fxEdited(guitarP[\fx]).not);
    ~tAssert.("the other chain's edit is left alone", sa.fxEdited(loopP[\fx]));

    // A new chain starts from the settings as they stand, switches included:
    // the loop's, made again for the next Looper.
    sa.setFx(loopP[\fx], true);
    l2 = ~tLooper.();
    Routine { sa.attachLooper(l2) }.next;
    args = ~tStartArgs.(stub, sa.fxNode(loopP[\fx]));
    ~tEq.("a new loop chain gets its switches", args[(loopP[\fx] ++ "On").asSymbol], 1);
    ~tNear.("and its settings as they are now", args[loopP[\name]], sa.fxParam(loopP[\name]), 1e-6);
    ~tAssert.("...every switch and setting of every loop effect, at its value now",
        MegaSAFx.loopKeys.every { |k|
            var a = ~tStartArgs.(stub, sa.fxNode(k));
            (a[(k ++ "On").asSymbol] == sa.fx(k).binaryValue) and: {
                MegaSAFx.paramsOf(k).every { |p| a[p[\name]].notNil and: { (a[p[\name]] - sa.fxParam(p[\name])).abs < 1e-6 } } }
        });
    ~tAssert.("...and the guitar chain's, at its build, every guitar effect's",
        MegaSAFx.guitarKeys.every { |k|
            var a = ~tStartArgs.(stub, sa.fxNode(k));
            a.includesKey((k ++ "On").asSymbol) and: { MegaSAFx.paramsOf(k).every { |p| a[p[\name]].notNil } }
        });
    sa.setFx(loopP[\fx], false);

    File.mkdir(tmp);

    // A bank job holds the guitar strip for a reason of its own, apart from
    // the player's mute, so a mute pressed meanwhile comes out right.
    strip = sa.strips[\guitar].nodeID;
    sa.hold(\guitar, \bank);
    ~tEq.("while a bank job runs the strip is held: told to mute", stub[\msgs].last, [15, strip, \mute, 1]);
    sa.setMute(\guitar, false);
    ~tEq.("...and stays muted when the player unmutes it", stub[\msgs].last, [15, strip, \mute, 1]);
    ~tEq.("but the player's mute is still off", sa.mute(\guitar), false);
    ~tEq.("...and the strip says why it is held", [sa.held(\guitar), sa.muted(\guitar)], [[\bank], true]);
    sa.unhold(\guitar, \bank);
    ~tEq.("with none running, the player's mute is what the strip gets", stub[\msgs].last, [15, strip, \mute, 0]);
    sa.setMute(\guitar, true);
    sa.hold(\guitar, \bank);
    sa.unhold(\guitar, \bank);
    ~tEq.("and a player's mute holds when a job ends", stub[\msgs].last, [15, strip, \mute, 1]);
    sa.setMute(\guitar, false);

    // ---- the racks' variations (presets/sa/fx-variations.json) ------------
    // The defaults ARE the racks' macros as the set left them: the file
    // tools/export-live-set.py writes and the table must agree, or one of them
    // was changed without the other.
    {
        var vars = ~saLoadFxVariations.();
        var savedMegaSA = ~megaSA;
        // What no macro drives sits in the file's 'fixed' block.
        var fixed = File.readAllString(~saFxVariationsFile.()).parseJSON["effects"];
        ~tAssert.("the racks' variations are read from the Live set's export",
            [\delay, \filter, \pitchLoop, \saturator, \redux].every { |k| vars[k].notNil },
            vars.keys.asArray.asString);
        vars.keysValuesDo { |fx, list|
            var saved = list.detect { |v| v[0] == "as saved" };
            fixed[fx.asString] !? { |e| e["fixed"].keysValuesDo { |k, x|
                saved !? { |sv| sv[1].put(k.asSymbol, x.asFloat) } } };
            ~tAssert.(fx ++ ": every setting a variation names is one of the effect's",
                list.every { |v| v[1].keys.every { |k| MegaSAFx.param(k).notNil
                    and: { MegaSAFx.param(k)[\fx] == fx } } });
            ~tAssert.(fx ++ ": 'as saved' is where its knobs start",
                saved.notNil and: { saved[1].keys.every { |k|
                    var want = MegaSAFx.param(k)[\spec].default;
                    (MegaSAFx.constrain(k, saved[1][k]) - want).abs <= (want.abs * 1e-4).max(1e-4)
                } },
                (saved !? { |s| s[1].keys.reject { |k| (MegaSAFx.constrain(k, s[1][k])
                    - MegaSAFx.param(k)[\spec].default).abs <= (MegaSAFx.param(k)[\spec].default.abs * 1e-4).max(1e-4) }
                    .collect { |k| k -> [s[1][k], MegaSAFx.param(k)[\spec].default] } }).asString);
        };
        ~megaSA = sa;
        sa.resetFx(\delay);
        ~tAssert.("recalling a variation answers true", ~saApplyVariation.(\delay, "short"));
        ~tNear.("and moves what its macros drive (the 'short' tap, 84 ms)", sa.fxParam(\delayTimeR), 0.0843, 0.001);
        ~tEq.("but leaves the rest", sa.fxParam(\delayModDepth), MegaSAFx.param(\delayModDepth)[\spec].default);
        ~tAssert.("'as saved' brings the start back", ~saApplyVariation.(\delay, "as saved")
            and: { sa.fxEdited(\delay).not });
        // Every rack: knock its first macro-driven setting off, recall 'as saved'.
        vars.keysValuesDo { |fx, list|
            var saved = list.detect { |v| v[0] == "as saved" };
            var name = saved !? { |sv| sv[1].keys.asArray.sort.first };
            name !? { |n|
                sa.setFxParam(n, MegaSAFx.param(n)[\spec].map(0.37));
                ~saApplyVariation.(fx, "as saved");
            };
            ~tAssert.(fx ++ ": after 'as saved' it no longer counts as edited", sa.fxEdited(fx).not,
                MegaSAFx.paramsOf(fx).select { |p| (sa.fxParam(p[\name]) - p[\spec].default).abs > 1e-6 }
                    .collect { |p| p[\name] -> sa.fxParam(p[\name]) }.asString);
        };
        ~tAssert.("an unknown variation answers false", ~saApplyVariation.(\delay, "nope").not);
        ~megaSA = savedMegaSA;
    }.value;
    // A value in the file that is no number is left out, not read as 0.
    {
        var realFile = ~saFxVariationsFile, path = tmp +/+ "variations.json", got;
        File.use(path, "w", { |f| f.write("{ \"effects\": { \"delay\": { \"variations\": [ { \"name\": \"odd\", "
            "\"settings\": { \"delayTimeR\": 0.25, \"delayMix\": \"loud\" } } ] } } }") });
        ~saFxVariationsFile = { path };
        got = ~saLoadFxVariations.();
        ~saFxVariationsFile = realFile;
        ~tEq.("a variation keeps its numbers and leaves out what is no number",
            got[\delay] !? { |v| [v[0][0], v[0][1][\delayTimeR], v[0][1].includesKey(\delayMix)] }, ["odd", 0.25, false]);
    }.value;
    ctl.remove;
    sa.free;
    (tmp +/+ "*").pathMatch.do { |p| File.delete(p) };
    File.delete(tmp);
}.value;

strip = SynthDescLib.global[\megaSAStrip];
~tAssert.("a strip passes sound until muted",
    strip.notNil and: { strip.controls.detect { |c| c.name.asSymbol == \mute }.defaultValue == 0 });
// Its stem: the very signal it sends the master (after its level and its
// mute, so a muted strip's stem is silent), onto its stem bus through XOut,
// whose crossfade is `stem > 0`: a strip given no stem bus (stem at its
// default, 0) writes nothing more, and never a negative bus. Here the graph,
// and the level it applies at given controls; what it writes takes scsynth.
{
    var def = strip !? { |d| d.def };
    var kids = def !? { |d| d.children } ? [];
    var out = kids.detect { |u| u.class == Out }, xout = kids.detect { |u| u.class == XOut };
    var stemCtl = strip !? { |d| d.controls.detect { |c| c.name.asSymbol == \stem } };
    var fade = xout !? { |x| x.inputs[1] };
    var ctlOf = { |input| input.isKindOf(OutputProxy) and: { input.source.isKindOf(Control) } };
    var nameOf, level, lags, rows, levels;
    ~tAssert.("a strip writes the master and its stem: one Out, one XOut",
        out.notNil and: { xout.notNil } and: { kids.count { |u| u.isKindOf(AbstractOut) } == 2 });
    ~tAssert.("...the stem the very signal the master gets, both sides (after the level and the mute)",
        out.notNil and: { xout.notNil } and: { (out.inputs.size - 1) == 2 } and: { (xout.inputs.size - 2) == 2 }
            and: { xout.inputs.copyToEnd(2).every { |u, i| u === out.inputs[i + 1] } });
    // The level each side gets, worked out from the graph at given controls: a
    // Lag found there says nothing of what it lags, and a strip that ignored
    // its mute (or doubled with it) would still have one. The control a graph
    // input reads, by its index; an expression's value at the controls in
    // `env`, nil if it reads anything else.
    nameOf = { |x|
        var i = x.source.specialIndex + x.outputIndex;
        def.allControlNames.detect { |c| c.index == i } !? { |c| c.name.asSymbol }
    };
    level = { |x, env|
        var a, b, c;
        case
        { x.isNumber } { x }
        { ctlOf.(x) } { env[nameOf.(x)] }
        { x.isKindOf(BinaryOpUGen) } {
            a = level.(x.inputs[0], env);
            b = level.(x.inputs[1], env);
            if(a.notNil and: { b.notNil }) { a.perform(x.operator, b) }
        }
        { x.isKindOf(UnaryOpUGen) } {
            a = level.(x.inputs[0], env);
            a !? { a.perform(x.operator) }
        }
        { x.isKindOf(MulAdd) } {
            a = level.(x.inputs[0], env);
            b = level.(x.inputs[1], env);
            c = level.(x.inputs[2], env);
            if(a.notNil and: { b.notNil } and: { c.notNil }) { (a * b) + c }
        }
        { nil }
    };
    // Each side's signal is the input times a Lag; what the Lag is given, at
    // [amp, mute], should be amp unmuted and nothing muted, at any level.
    lags = out !? { |o| o.inputs.copyToEnd(1).collect { |u|
        if(u.isKindOf(BinaryOpUGen) and: { u.operator == '*' }) { u.inputs.detect { |x| x.isKindOf(Lag) } } } } ? [];
    rows = [[0.5, 0, 0.5], [1, 0, 1], [2, 0, 2], [0.5, 1, 0], [1, 1, 0]];
    levels = lags.collect { |g| g !? { |x| rows.collect { |r| level.(x.inputs[0], (amp: r[0], mute: r[1])) } } };
    ~tAssert.("...that signal the input times its level, lagged: amp unmuted, nothing muted (so a muted strip's stem is silent too)",
        (lags.size == 2) and: { levels.every { |side| side.notNil and: { side.every { |v, i|
            v.notNil and: { (v - rows[i][2]).abs < 1e-9 } } } } },
        "at " ++ rows.collect(_.keep(2)) ++ ": " ++ levels);
    ~tAssert.("...onto the stem control's bus, crossfaded by stem > 0",
        xout.notNil and: { ctlOf.(xout.inputs[0]) } and: { fade.isKindOf(BinaryOpUGen) } and: { fade.operator == '>' }
            and: { fade.inputs[0] === xout.inputs[0] } and: { fade.inputs[1] == 0 });
    ~tEq.("...whose default is 0: no stem bus, no stem written", stemCtl !? { |c| c.defaultValue }, 0);
}.value;
// The guitar's plugin's device, 1->1 as the Live set hosts Bias FX.
fx = SynthDescLib.global[MegaSAPlugin.defName(1, 1)];
// Through asClass, so this file compiles where VSTPlugin is not installed
// (the plugin's SynthDefs then do not exist: SA hosts no plugin).
if(\VSTPlugin.asClass.isNil) {
    ~tSkip.("the guitar chain's plugin SynthDef", "VSTPlugin is not installed here");
} {
    ~tAssert.("the guitar's plugin device hosts one VSTPlugin, named \\plugin for MegaSAPlugin",
        fx.notNil and: { fx.metadata[\vstplugins].notNil }
            and: { fx.metadata[\vstplugins].includesKey(\plugin) }
            and: { fx.def.children.count { |u| u.isKindOf(\VSTPlugin.asClass) } == 1 });
    ~tAssert.("...whose output is sanitized before anything after it hears it",
        fx.notNil and: { fx.def.children.any { |u|
            var i = u.isKindOf(Sanitize).if { u.inputs.first };
            i.notNil and: { (i.isKindOf(OutputProxy) and: { i.source.isKindOf(\VSTPlugin.asClass) })
                or: { i.isKindOf(\VSTPlugin.asClass) } }
        } });
};
master = SynthDescLib.global[\megaSAMaster];
~tAssert.("no lookahead limiter in the master, which the guitar's monitoring passes",
    master.notNil and: { master.def.children.any { |u| u.isKindOf(Limiter) }.not });

// --------------------------------------------------------------- the drums --
// A real MegaSA on a recording stub, with the drums it owns: what exists the
// moment it is made, the tree its init routine builds (stepped here: the stub's
// sync answers at once), the drum strips, a reading reaching the drums, the
// Looper handed to them, PC 17 (through the router, as a controller's
// program change reaches it), and free taking them down first. The stub
// numbers its nodes in order, so the tree can be rebuilt from what was sent.
// MegaSA's own init routine never gets to run: free, at the end, stops it.
{
    var stub = ~tStubServer.();
    var savedMegaSA = ~megaSA, savedRp = ~rp;
    var sa, d, l, kids, busses, ids, r, pc, caught, n, frees, atFree, guitarFreed, seen, ctl, stems, specs;
    // The order a server would run what the recorded /g_new (21) and /s_new
    // (9) make: node -> its children, from the root (0), which holds the
    // default group (1). Add actions: 0 head, 1 tail, 2 before, 3 after.
    var tree = { |msgs|
        var children = IdentityDictionary[0 -> List[1], 1 -> List.new];
        var parent = IdentityDictionary[1 -> 0];
        msgs.do { |m|
            var id, action, target, siblings;
            if((m[0] == 21) or: { m[0] == 9 }) {
                if(m[0] == 21) { id = m[1]; action = m[2]; target = m[3] }
                    { id = m[2]; action = m[3]; target = m[4] };
                if(m[0] == 21) { children.put(id, List.new) };
                if(action < 2) {
                    siblings = children[target];
                    if(action == 0) { siblings.insert(0, id) } { siblings.add(id) };
                    parent.put(id, target);
                } {
                    siblings = children[parent[target]];
                    siblings.insert(siblings.indexOf(target) + (action - 2), id);
                    parent.put(id, parent[target]);
                };
            };
        };
        children
    };
    // A synth's starting controls, from its /s_new.
    var argsOf = { |node|
        var msg = node !? { stub[\msgs].detect { |m| (m[0] == 9) and: { m[2] == node.nodeID } } };
        (msg !? { |m| ().putPairs(m.copyToEnd(5)) }) ? ()
    };
    stub[\defaultGroup] = Group.basicNew(stub, 1);
    stub[\nextNodeID] = { |self|
        var id = (self[\lastNodeID] ? 1999) + 1;
        self[\lastNodeID] = id;
        id
    };

    sa = ~tCheck.("a MegaSA is made on the stub", { MegaSA(stub) });
    d = sa !? { |x| x.drums };
    ~tAssert.("its drums exist the moment it does: their model, their port, nothing built yet",
        d.isKindOf(MegaSADrums) and: { d.megaSA === sa } and: { d.server === stub }
            and: { d.alive } and: { d.transport.isKindOf(MegaSATransport) } and: { d.built.not });
    ~tEq.("the drums' strips start at Live's faders", [sa.level(\drums), sa.level(\onsetKit)],
        [0.2951209247, 0.1640589684]);
    ~tNear.("...the drums group's -10.6 dB", sa.level(\drums).ampdb, -10.6, 0.001);
    ~tNear.("...and the One Hit Kit's -15.7 dB", sa.level(\onsetKit).ampdb, -15.7, 0.001);
    ~tEq.("and are not muted", [sa.mute(\drums), sa.mute(\onsetKit)], [false, false]);
    ~tEq.("every strip has a level and a mute, the master a level only",
        [sa.levels, sa.mutes].collect { |t| t.keys.asArray.collect(_.asString).sort },
        [["drums", "guitar", "loop", "master", "onsetKit", "synth"], ["drums", "guitar", "loop", "onsetKit", "synth"]]);
    busses = [sa.stepsBus, sa.stepsOutBus, sa.onsetBus, sa.onsetOutBus];
    ~tAssert.("its four drum busses are stereo audio busses on its server, there at once",
        busses.every { |b| b.isKindOf(Bus) and: { b.rate == \audio } and: { b.numChannels == 2 }
            and: { b.server === stub } });
    ids = (busses ++ [sa.guitarBus, sa.loopBus, sa.loopFxBus, sa.masterBus, sa.recordBus]).collect(_.index);
    ~tEq.("...each a bus of its own", ids.asSet.size, 9);
    ~tEq.("the strips in mixer order, the synth's last", sa.stripBusses.clump(2).collect(_[0]), [\guitar, \loop, \drums, \onsetKit, \synth]);
    ~tAssert.("each with its bus: the drums' strips read their effects' output",
        [sa.guitarBus, sa.loopFxBus, sa.stepsOutBus, sa.onsetOutBus, sa.synthBus].every { |b, i| sa.stripBusses[(i * 2) + 1] === b });

    // ---- the stems ------------------------------------------------------------
    // Each strip after its fader, for the session recorder (stemSpecs, which
    // setup-sa.scd hands it): the set's guitar, loop, drums and onset kit as
    // heard, beside its master.
    stems = [\guitar, \loop, \drums, \onsetKit, \synth].collect { |k| sa.stemBus(k) };
    ~tAssert.("a stem bus per strip, a stereo audio bus on its server, there at once",
        stems.every { |b| b.isKindOf(Bus) and: { b.rate == \audio } and: { b.numChannels == 2 }
            and: { b.server === stub } });
    ~tEq.("...each a bus of its own, apart from the nine", (ids ++ stems.collect(_.index)).asSet.size, 14);
    specs = sa.stemSpecs;
    ~tEq.("the stems: the guitar, the loop, the drums, the onset kit and the synth, every one stereo, each from its strip's bus",
        specs, [
            (role: \guitar, channel: sa.soundInChannel(stems[0]), numChannels: 2),
            (role: \loop, channel: sa.soundInChannel(stems[1]), numChannels: 2),
            (role: \drums, channel: sa.soundInChannel(stems[2]), numChannels: 2),
            (role: \onset, channel: sa.soundInChannel(stems[3]), numChannels: 2),
            (role: \synth, channel: sa.soundInChannel(stems[4]), numChannels: 2)
        ]);
    ~tAssert.("...each channel a SoundIn channel that lands on that bus (In.ar(numOutputs + channel))",
        specs.notEmpty and: { specs.every { |sp, i| (sp[\channel] + stub.options.numOutputBusChannels) == stems[i].index } });

    // ---- the server side ----------------------------------------------------
    ~tCheck.("its server side builds on the stub", { Routine { sa.prBuild }.next });
    ~tEq.("...and it is ready, the drums built in its drum group", [sa.ready, d.built, d.drumGroup === sa.drumGroup],
        [true, true, true]);
    kids = ~tCheck.("...into a tree that can be rebuilt from what it sent", { tree.(stub[\msgs]) });
    kids !? {
        ~tEq.("guitar, engine (the default group), drums, mixer, recorder: in that order",
            kids[0].asArray, [sa.guitarGroup.nodeID, 1, sa.drumGroup.nodeID, sa.mixerGroup.nodeID,
                sa.recordGroup.nodeID]);
        ~tAssert.("the drums' voices are in the drum group",
            [d.stepsGroup, d.repeatGroup, d.onsetGroup].every { |g|
                g.notNil and: { (kids[sa.drumGroup.nodeID] ? []).includes(g.nodeID) } });
        ~tEq.("the mixer runs the five strips in order, then the master",
            (kids[sa.mixerGroup.nodeID] ? []).asArray,
            ([\guitar, \loop, \drums, \onsetKit, \synth].collect { |k| sa.strips[k] } ++ [sa.masterSynth])
                .collect { |x| x !? (_.nodeID) });
    };
    ~tEq.("the drums' strip starts at -10.6 dB, unmuted, on stepsOutBus",
        [\in, \amp, \mute].collect { |k| argsOf.(sa.strips[\drums])[k] }, [sa.stepsOutBus.index, 0.2951209247, 0]);
    ~tEq.("the onset kit's at -15.7 dB on onsetOutBus",
        [\in, \amp, \mute].collect { |k| argsOf.(sa.strips[\onsetKit])[k] }, [sa.onsetOutBus.index, 0.1640589684, 0]);
    ~tEq.("every strip starts writing its own stem bus",
        [\guitar, \loop, \drums, \onsetKit, \synth].collect { |k| argsOf.(sa.strips[k])[\stem] }, stems.collect(_.index));
    ~tEq.("...and the master none", argsOf.(sa.masterSynth)[\stem], nil);

    // ---- the strips, a reading -----------------------------------------------
    seen = List.new;
    ctl = SimpleController(sa).put(\level, { |obj, what, key, amp| seen.add([key, amp]) });
    sa.setLevel(\drums, 0.5);
    ~tEq.("a drums level goes to the drums' strip", stub[\msgs].last, [15, sa.strips[\drums].nodeID, \amp, 0.5]);
    ~tEq.("...and is announced, for the Rig and Drums tabs", seen.last, [\drums, 0.5]);
    sa.setMute(\onsetKit, true);
    ~tEq.("the onset kit mutes on its own strip", stub[\msgs].last, [15, sa.strips[\onsetKit].nodeID, \mute, 1]);
    sa.setMute(\onsetKit, false);
    sa.setLevel(\drums, 0.2951209247);
    ctl.remove;
    r = (bpm: 120, numerator: 7, denominator: 8, k: 2, loopDur: 3.5);
    ~tCheck.("a reading is handed over", { sa.setAnalysis(r) });
    ~tEq.("its tempo sets the effects' beat", sa.beatDur, 0.5);
    ~tAssert.("and the drums keep the whole reading", d.analysis === r);
    sa.setAnalysis((error: \tooFewOnsets, onsetCount: 2));
    ~tEq.("a reading with no tempo leaves the beat alone", sa.beatDur, 0.5);
    ~tCheck.("and no reading at all is nothing", { sa.setAnalysis(nil) });

    // ---- the Looper ------------------------------------------------------------
    // What the Looper's init puts at the default group's tail on a rig, its
    // master (Looper.sc), stood in for: the loop's effects must come after it.
    Synth.tail(stub[\defaultGroup], \looperMaster);
    l = ~tLooper.();
    ~tCheck.("a Looper attaches", { Routine { sa.attachLooper(l) }.next });
    ~tAssert.("its MIDI port is now the drums' transport, its onset notes their sink",
        (l.midiOut === d.transport) and: { l.onsetNoteSink === d });
    ~tEq.("and a Start relocates nothing on SA", l.startsRelocate, false);
    ~tAssert.("the drums follow that Looper", d.looper === l);
    ~tAssert.("its session recorder still goes after the mixer", l.sessionRec.target === sa.recordGroup);
    {
        // Inside the default group, after everything the Looper had put there
        // (its master, on a rig), so the loop-chain recorder, which the Looper
        // adds at that group's tail later, hears the processed loop.
        var t = ~tNodeTree.(stub), node = sa.fxNode(MegaSAFx.loopKeys.first);
        var up = node !? { t[\ancestors].(node.nodeID) } ? [];
        var top = if(up.first == 1) { node.nodeID } { up[(up.indexOf(1) ? 0) - 1] };
        ~tAssert.("and the loop's effects run in the default group, after what was there",
            node.notNil and: { up.includes(1) } and: { t[\children][1].last == top },
            [node, up, t[\children][1]].asString);
    }.value;

    // ---- PC 17 -----------------------------------------------------------------
    // The router's own route, with the map SA's numbers make, and no MIDIdef:
    // registering one would take over a running megalooper's.
    ~rp = ~routingProfiles[\sa];
    ~megaSA = sa;
    caught = IdentitySet.new;
    pc = ~tCheck.("SA's map and controls build", {
        var keep = ~midiUserRootOverride, map;
        var targets = ~midiTargetsBuild.();
        var sources = IdentityDictionary[1001 -> ["TSMEGA", "TSMEGA"]];
        ~midiUserRootOverride = ~tTempPath.("megasa-midi");
        map = ~midiMapLoad.("tsmega")[\map];
        ~midiUserRootOverride = keep;
        { |num| ~midiRouteWith.(map, targets, \program, 0, num, nil, 1001, sources, caught) }
    });
    pc !? {
        ~tCheck.("PC 17 arrives", { pc.(17) });
        ~tEq.("...and switches the drums' steps off", d.on, false);
        pc.(17);
        ~tEq.("...and on again: a true toggle, from the first press", d.on, true);
        pc.(10);
        ~tAssert.("an effect's program switches its effect and leaves the drums alone",
            d.on and: { sa.fx(\filter) });
        pc.(10);
        ~megaSA = nil;
        ~tCheck.("with no SA, PC 17 does nothing", { pc.(17) });
        ~tEq.("...and nothing the router reached threw", caught.asArray, []);
    };
    ~megaSA = savedMegaSA;
    ~rp = savedRp;

    // ---- free --------------------------------------------------------------------
    // Every /n_free noted with the drums' state at that moment.
    atFree = List.new;
    stub[\sendMsg] = { |self ... args|
        stub[\msgs].add(args);
        if(args[0] == 11) { atFree.add([args[1], d.alive, l.midiOut === d.transport]) };
        self
    };
    n = stub[\msgs].size;
    ~tCheck.("free", { sa.free });
    frees = stub[\msgs].copyToEnd(n).select { |m| m[0] == 11 }.collect { |m| m[1] };
    guitarFreed = atFree.detect { |e| e[0] == sa.guitarGroup.nodeID };
    ~tAssert.("free takes the drums down first: dead, before the guitar chain goes",
        guitarFreed.notNil and: { guitarFreed[1] == false } and: { guitarFreed[2] }, atFree.asString);
    // On a reboot the old Looper plays on until ~setupLooper frees it, after
    // the new MegaSA is up, its MIDI clock calling its port every tick.
    ~tEq.("the drums are dead and let go of the Looper, which keeps their port and sink, dead too",
        [d.alive, l.midiOut === d.transport, l.onsetNoteSink === d, d.transport.alive, l.startsRelocate],
        [false, true, true, false, true]);
    ~tCheck.("...so the old Looper's calls on them do nothing and throw nothing",
        { l.midiOut.midiClock; l.midiOut.start; l.midiOut.stop; l.startOnsetNotes; l.stopOnsetNotes });
    ~tAssert.("the drum group goes, and every drum bus", frees.includes(sa.drumGroup.nodeID)
        and: { busses.every { |b| b.index.isNil } });
    ~tAssert.("...and every stem bus", stems.every { |b| b.index.isNil });
    ~tEq.("and it is no longer ready", sa.ready, false);
}.value;

// ---- holds and the plugin's open (docs/dev/device-chains.md, phase B) -----------
// The guitar is held while its plugin opens, apart from the player's mute,
// which nothing but the player touches; a plugin whose sound did not load
// holds it until the player unmutes it; one that failed lets it play dry. The
// open runs after the build and has a timeout; what answers after free finds
// nothing to act on.
{
    var sa, plug, strip, late, msgsBefore, r, steps, got, calls, m, srv;
    // A plugin needs VSTPlugin; without it SA hosts none (checked above).
    if(\VSTPlugin.asClass.isNil) { ~tSkip.("the plugin's holds and open", "VSTPlugin is not installed here") } {
        // Opens at once, as a plugin that is installed and well.
        sa = ~tMegaSA.(nil, ~tFakePlugin.(\open));
        strip = sa.strips[\guitar];
        ~tEq.("with a plugin, the guitar strip starts held while it opens", ~tStartArgs.(sa.server, strip)[\mute], 1);
        ~tEq.("...and once it is open it is let go", [sa.held(\guitar), sa.muted(\guitar), ~tLastSet.(sa, strip, \mute)],
            [[], false, 0]);
        ~tEq.("...the plugin asked to open once", sa.guitarPlugin[\opened], 1);
        ~tEq.("...and the player's mute never moved", sa.mute(\guitar), false);
        sa.free;

        // Answers later, as a real one does: a mute pressed during the open
        // stays pressed (the open used to clear it).
        plug = ~tFakePlugin.(\open);
        plug[\open] = { |self, bankFile, action| self[\state] = \opening; late = action };
        sa = ~tMegaSA.(nil, plug);
        strip = sa.strips[\guitar];
        ~tEq.("while it opens the guitar is held", sa.held(\guitar), [\opening]);
        sa.setMute(\guitar, false);
        ~tEq.("...and the player cannot unmute it into the dry DI", ~tLastSet.(sa, strip, \mute), 1);
        sa.setMute(\guitar, true);
        plug[\state] = \open;
        late.value(plug, true);
        ~tEq.("a mute pressed during the open stays on once it is open", [sa.mute(\guitar), sa.muted(\guitar),
            ~tLastSet.(sa, strip, \mute), sa.held(\guitar)], [true, true, 1, []]);
        sa.setMute(\guitar, false);
        ~tEq.("...and the player's unmute plays it", ~tLastSet.(sa, strip, \mute), 0);
        sa.free;

        // Opens, but its sound does not load: it would play its default patch.
        plug = ~tFakePlugin.(\open);
        plug[\open] = { |self, bankFile, action| self[\state] = \open; action.value(self, false) };
        sa = ~tMegaSA.(nil, plug);
        strip = sa.strips[\guitar];
        ~tEq.("a plugin whose sound did not load holds the guitar", [sa.held(\guitar), ~tLastSet.(sa, strip, \mute)], [[\state], 1]);
        sa.setMute(\guitar, false);
        ~tEq.("...until the player unmutes it, to hear the plugin as it is", [sa.held(\guitar), ~tLastSet.(sa, strip, \mute)], [[], 0]);
        sa.free;

        // Fails to open: dry is better than nothing.
        sa = ~tMegaSA.(nil, ~tFakePlugin.(\failed));
        strip = sa.strips[\guitar];
        ~tEq.("a plugin that failed lets the guitar play dry", [sa.held(\guitar), ~tLastSet.(sa, strip, \mute)], [[], 0]);
        sa.free;

        // Freed while it opens: the late answer finds nothing to act on.
        plug = ~tFakePlugin.(\open);
        plug[\open] = { |self, bankFile, action| self[\state] = \opening; late = action };
        sa = ~tMegaSA.(nil, plug);
        sa.free;
        msgsBefore = sa.server[\msgs].size;
        plug[\state] = \open;
        ~tCheck.("an open that answers after free throws nothing", { late.value(plug, true) });
        ~tEq.("...and sends nothing", sa.server[\msgs].size, msgsBefore);

        // A plugin that cannot even be made costs the plugin only.
        srv = ~tCountIds.(~tStubServer.());
        srv[\defaultGroup] = Group.basicNew(srv, 1);
        m = MegaSA(srv, 0, 0, "/x/Broken.vst");
        m.instVarAt(\builder) !? { |x| x.stop };
        m.pluginMaker = { |synth, id, path| Error("a plugin on fire").throw };
        ~tCheck.("a plugin that cannot be made does not stop the build", { Routine { m.prBuild }.next });
        ~tEq.("...SA is ready, with no plugin, and the guitar is not held", [m.ready, m.guitarPlugin, m.held(\guitar)],
            [true, nil, []]);

        // Cmd-period: it says so and stops answering ready.
        m.cmdPeriod;
        ~tEq.("after Cmd-period SA is not ready", m.ready, false);
        m.free;
        ~tCheck.("...and a freed one ignores it", { m.cmdPeriod });

        // waitForReady gives up and says so, rather than keeping the boot waiting.
        m = MegaSA.newCopyArgs(nil, 0, 0);
        r = Routine { m.waitForReady(0.1); \done.yield };
        steps = 0;
        while { (r.next != \done) and: { steps < 20 } } { steps = steps + 1 };
        ~tAssert.("waitForReady gives up after its timeout", steps < 20, steps.asString ++ " steps");

        // MegaSAPlugin's own open: once only, a timeout, and no VSTPlugin.
        calls = List.new;
        plug = MegaSAPlugin.newCopyArgs(nil, \plugin, "/x/Bias.vst");
        plug.open(nil, { |p, ok| calls.add(ok) });
        ~tEq.("a plugin with no VSTPlugin controller answers failed at once", [calls.asArray, plug.state], [[false], \failed]);
        calls = List.new;
        plug.instVarPut(\state, \opening);
        plug.instVarPut(\openAnswered, false);
        plug.instVarPut(\openAction, { |p, ok| calls.add(ok) });
        plug.prOpenTimedOut(30);
        ~tEq.("an open that does not answer in time counts as failed", [calls.asArray, plug.state], [[false], \failed]);
        // The open's own answer arriving after its timeout (the controller's
        // callback, which still holds the action): nothing more is told.
        plug.instVarPut(\openAction, { |p, ok| calls.add(\late) });
        plug.prAnswerOpen(true);
        plug.prOpenTimedOut(30);
        ~tEq.("...and is answered once: a late answer or a second timeout changes nothing", calls.asArray, [false]);
    };
}.value;

// What MegaSA hands the drums' build, and what happens when the build throws:
// drums that only note what they were given, then fail. MegaSA must still get
// ready, its strips and master up (setup-sa.scd's waitForReady must never
// spin), the drums costing only the drums.
{
    var stub = ~tStubServer.();
    var sa, calls = List.new, want;
    stub[\defaultGroup] = Group.basicNew(stub, 1);
    sa = ~tCheck.("another MegaSA is made", { MegaSA(stub) });
    sa !? {
        sa.drums.free;
        sa.instVarPut(\drums, (build: { |self ... args| calls.add(args); Error("a drum kit on fire").throw }));
        ~tCheck.("drums whose build throws do not stop it", { Routine { sa.prBuild }.next });
        want = [sa.drumGroup, sa.stepsBus, sa.stepsOutBus, sa.onsetBus, sa.onsetOutBus, sa.synthBus];
        ~tAssert.("the build was given the drum group, the four drum busses and the synth's, in its order",
            (calls.size == 1) and: { calls[0].size == 6 } and: { calls[0].every { |x, i| x === want[i] } },
            calls.asString);
        ~tEq.("and it is ready, its five strips and its master up",
            [sa.ready, sa.strips.size, sa.masterSynth.notNil], [true, 5, true]);
        sa.instVarPut(\drums, nil);
        sa.free;
    };
}.value;

// A strip given no stem bus (one that did not allocate, or one that is no
// bus a strip may write) starts with no \stem at all: the def's default writes
// none. And the recorder is not told of a stem that is not there.
{
    var stub = ~tStubServer.();
    var sa, argsOf, loopFreed;
    stub[\defaultGroup] = Group.basicNew(stub, 1);
    stub[\nextNodeID] = { |self|
        var id = (self[\lastNodeID] ? 2999) + 1;
        self[\lastNodeID] = id;
        id
    };
    argsOf = { |node|
        var msg = node !? { stub[\msgs].detect { |m| (m[0] == 9) and: { m[2] == node.nodeID } } };
        (msg !? { |m| ().putPairs(m.copyToEnd(5)) }) ? ()
    };
    sa = ~tCheck.("a MegaSA whose stems did not all allocate", { MegaSA(stub) });
    sa !? {
        loopFreed = sa.stemBus(\loop);
        sa.stemBusses.removeAt(\loop);
        loopFreed.free;
        // The interface's first outputs are never a stem: bus 0 is not given.
        sa.stemBusses.put(\onsetKit, Bus(\audio, 0, 2, stub));
        ~tCheck.("...builds", { Routine { sa.prBuild }.next });
        ~tEq.("a strip with no stem bus starts with no \\stem (the def's 0: nothing written)",
            [argsOf.(sa.strips[\loop])[\stem], argsOf.(sa.strips[\onsetKit])[\stem]], [nil, nil]);
        ~tEq.("...the others with theirs", [\guitar, \drums].collect { |k| argsOf.(sa.strips[k])[\stem] },
            [sa.stemBus(\guitar).index, sa.stemBus(\drums).index]);
        ~tAssert.("...and never a negative or a missing bus", sa.strips.values.every { |s|
            argsOf.(s)[\stem].isNil or: { argsOf.(s)[\stem] > 0 } });
        sa.stemBusses.removeAt(\onsetKit);
        ~tEq.("the recorder is told only the stems there are", sa.stemSpecs.collect(_[\role]), [\guitar, \drums, \synth]);
        ~tCheck.("...and it frees", { sa.free });
    };
    ~tEq.("a MegaSA made without its init has no stems and says so",
        MegaSA.newCopyArgs(nil, 0, 0).stemSpecs, []);
}.value;

// The stems go to the session recorder whenever SA attaches the Looper
// (setup-sa.scd's ~setupSALooper, every boot: a new Looper is a new
// recorder), and on SA only. A fake recorder in the Looper takes them here as
// the real one does (LooperSessionRecorder.stems).
{
    var stub = ~tStubServer.();
    var saved = [~megaSA, ~looper, ~rp];
    var sa, l, fake, l2, fake2, l3, took;
    stub[\defaultGroup] = Group.basicNew(stub, 1);
    sa = ~tCheck.("a MegaSA for the stems' handover", { MegaSA(stub) });
    sa !? {
        Routine { sa.prBuild }.next;
        l = ~tLooper.();
        fake = ();
        ~tPut.(l, \sessionRec, fake);
        ~megaSA = sa;
        ~looper = l;
        ~rp = ~routingProfiles[\sa];
        ~tCheck.("~setupSALooper attaches the Looper", { Routine { ~setupSALooper.() }.next });
        ~tEq.("...and hands its session recorder SA's stems", fake[\stems], sa.stemSpecs);
        ~tAssert.("...which records after the mixer, as before", fake[\target] === sa.recordGroup);
        ~tAssert.("...the drums on that Looper", sa.drums.looper === l);
        // boot.scd never calls it on another rig; nothing would go if it did.
        l2 = ~tLooper.();
        fake2 = ();
        ~tPut.(l2, \sessionRec, fake2);
        ~rp = ~routingProfiles[\bhTsMega];
        ~saHandStems.(l2);
        ~tEq.("on a Live rig the recorder gets no stems: the master and the tap alone", fake2[\stems], nil);
        ~rp = ~routingProfiles[\sa];
        ~megaSA = nil;
        ~saHandStems.(l2);
        ~tEq.("...nor with no SA", fake2[\stems], nil);
        ~tCheck.("...where ~setupSALooper does nothing", { ~setupSALooper.() });
        ~megaSA = sa;
        ~tEq.("no Looper, no recorder: nothing, and no throw", ~tCheck.("(no Looper)", { ~saHandStems.(nil) }), nil);
        // The real recorder: once it records stems it takes these; one that
        // cannot is said, not thrown, and the set records without them.
        l3 = ~tLooper.();
        if(LooperSessionRecorder.findRespondingMethodFor(\stems_).notNil) {
            ~tEq.("a new recorder has no stems (a boot that is not SA leaves it so)", l3.sessionRec.stems.size, 0);
            ~saHandStems.(l3);
            ~tEq.("...and SA's are the real recorder's once handed", l3.sessionRec.stems, sa.stemSpecs);
        } {
            took = ~tCheck.("a recorder that takes no stems is said, not thrown", { ~saHandStems.(l3) });
            ~tAssert.("...the recorder answered all the same", took === l3.sessionRec);
        };
        sa.free;
    };
    ~megaSA = saved[0];
    ~looper = saved[1];
    ~rp = saved[2];
}.value;

// The drums at boot (setup-sa.scd), on a MegaSA on the stub with two small kits
// of its own in a temporary folder, where the kept drums go too: the kit folder,
// the default kit in each slot left empty or given a kit that is gone, the kept
// drums (none, then a file that is no kept state), Keep, and the post window's
// kit lines.
{
    var stub = ~tStubServer.();
    var tmp = ~tTempPath.("megasa-test-drums");
    var saved = [~megaSA, ~saDrumsKitDir, ~saDrumsDefaultKits, ~saKeptDrumsPath, ~saKeptDrumsBefore, ~midiUserRootOverride];
    var sa, d, got, ok, sa2;
    var write = { |path|
        var sf = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(1).sampleRate_(48000);
        sf.openWrite(path);
        sf.writeData(Signal.fill(480, { 0.1 }));
        sf.close;
    };
    var kit = { |key, name, file|
        File.use(tmp +/+ key ++ ".json", "w", { |f|
            f.write("{ \"version\": 1, \"key\": \"" ++ key ++ "\", \"name\": \"" ++ name
                ++ "\", \"pads\": { \"36\": { \"name\": \"Kick\", \"choke\": 0, \"retrigger\": false, "
                ++ "\"layers\": [ { \"file\": \"" ++ file
                ++ "\", \"vel\": { \"law\": \"operator\", \"amount\": 1 } } ] } } }");
        });
    };
    stub[\defaultGroup] = Group.basicNew(stub, 1);
    File.mkdir(tmp +/+ "t");
    write.(tmp +/+ "t" +/+ "a.wav");
    write.(tmp +/+ "t" +/+ "b.wav");
    kit.("ta", "Test A", "t/a.wav");
    kit.("tb", "Test B", "t/b.wav");
    ~saDrumsKitDir = { tmp };
    ~saDrumsDefaultKits = (steps: 'ta', onset: 'tb');
    // Where the kept drums live: in your megalooper folder (a scratch one
    // here), never in the repo.
    ~midiUserRootOverride = tmp +/+ "root";
    ~tEq.("the drums are kept in your megalooper folder, beside the kept sound",
        ~saKeptDrumsPath.(), tmp +/+ "root" +/+ "sa" +/+ "kept-drums" +/+ "drums.scd");
    ~tAssert.("...not in the repo, where they lay before",
        ~saKeptDrumsPath.().beginsWith(Looper.repoRoot).not and: { ~saKeptDrumsBefore.().beginsWith(Looper.repoRoot) });
    // The first boot copies what the repo's folder holds, once.
    ~saKeptDrumsBefore = { tmp +/+ "before" };
    File.mkdir(tmp +/+ "before");
    File.use(tmp +/+ "before" +/+ "drums.scd", "w", { |f| f.write("( old: true )") });
    ~tEq.("the first boot copies the kept drums over", ~saAdoptKeptDrums.(), ["drums.scd"]);
    ~tEq.("...whole, and the old file stays", [MegaFiles.readText(~saKeptDrumsPath.()), File.exists(tmp +/+ "before" +/+ "drums.scd")],
        ["( old: true )", true]);
    File.delete(~saKeptDrumsPath.());
    ~tEq.("...once: drums you threw away do not come back", [~saAdoptKeptDrums.(), File.exists(~saKeptDrumsPath.())], [nil, false]);
    ~midiUserRootOverride = saved[5];
    ~saKeptDrumsPath = { tmp +/+ "kept" +/+ "drums.scd" };
    File.use(tmp +/+ "before" +/+ "drums.scd", "w", { |f| f.write("( version: 1, oops") });
    sa = ~tCheck.("a MegaSA for the drums at boot", { MegaSA(stub) });
    d = sa !? { |x| x.drums };
    d !? {
        // Buffer.read, answering at once.
        d.kitReader = { |srv, path, done|
            done.((bufnum: 7, path: path, numChannels: 1, sampleRate: 48000, numFrames: 480));
        };
        ~megaSA = sa;
        ~tCheck.("the drums at boot", { ~setupSADrums.() });
        ~tEq.("the kits come from the folder setup-sa.scd names", d.kitDir, tmp);
        ~tEq.("with nothing kept, each slot gets its default kit", [d.kit(\steps), d.kit(\onset)], [\ta, \tb]);
        ~tEq.("...loaded", [d.kitState(\steps), d.kitState(\onset)], [\ready, \ready]);
        // megalooper ships the kits' maps, never their samples: a slot starts
        // on a kit that can sound here.
        ~tEq.("the kits with a sample of theirs on this Mac", d.kitsWithAudio, [\ta, \tb]);
        ~tEq.("a slot starts on its default kit while that kit's samples are here",
            [~saDrumsStartKit.(d, \steps), ~saDrumsStartKit.(d, \onset)], [\ta, \tb]);
        File.delete(tmp +/+ "t" +/+ "a.wav");
        d.rescanKits;
        ~tEq.("...on the first kit that has samples when its own has none",
            [d.kitsWithAudio, ~saDrumsStartKit.(d, \steps), ~saDrumsStartKit.(d, \onset)], [[\tb], \tb, \tb]);
        File.delete(tmp +/+ "t" +/+ "b.wav");
        d.rescanKits;
        ~tEq.("...and on its default when no kit has any: the slot is silent and says why",
            [d.kitsWithAudio, ~saDrumsStartKit.(d, \steps)], [[], \ta]);
        ~tEq.("a slot with no default gets none", { var was = ~saDrumsDefaultKits, got;
            ~saDrumsDefaultKits = (onset: 'tb'); got = ~saDrumsStartKit.(d, \steps); ~saDrumsDefaultKits = was; got }.value, nil);
        write.(tmp +/+ "t" +/+ "a.wav");
        write.(tmp +/+ "t" +/+ "b.wav");
        d.rescanKits;
        ~tEq.("the post window names a kit and its state", ~saDrumsKitLine.(\steps), "steps kit Test A: ready");
        // As if kept: the steps slot on a kit that is gone, the onset slot on
        // another kit than its default.
        d.setKit(\steps, 'gone');
        d.setKit(\onset, 'ta');
        ~setupSADrums.();
        ~tEq.("a slot whose kit is gone gets its default; one with a kit keeps it",
            [d.kit(\steps), d.kit(\onset)], [\ta, \ta]);
        d.setKit(\onset, nil);
        ~tEq.("an empty slot says so", ~saDrumsKitLine.(\onset), "no onset kit");
        ~tAssert.("the boot adopted what lay in the repo's folder: a file that is no kept state, and the boot went on",
            MegaFiles.readText(~saKeptDrumsPath.()) == "( version: 1, oops");
        File.delete(~saKeptDrumsPath.());
        ~tEq.("with nothing kept there is nothing to load", ~saLoadKeptDrums.(), false);
        File.mkdir(tmp +/+ "kept");
        File.use(~saKeptDrumsPath.(), "w", { |f| f.write("( version: 1, oops") });
        ok = ~tCheck.("a kept file that is no kept state does not stop the boot", { ~saLoadKeptDrums.() });
        ~tEq.("...and does not count as kept", ok, false);
        ~tAssert.("...the patterns as they were", d.edited(\main).not and: { d.edited(\break).not });
        File.delete(~saKeptDrumsPath.());
        ok = ~saKeepDrums.({ |flag| got = flag });
        ~tEq.("Keep's action hears what Keep answers", got, ok);
        if(d.respondsTo(\keep)) {
            ~tAssert.("...and the drums are kept where ~saKeptDrumsPath says",
                (ok == true) and: { File.exists(~saKeptDrumsPath.()) });
        } {
            ~tEq.("...false, while the drums cannot keep themselves", ok, false);
        };
        // A slot kept empty (the Drums tab's "— none —") stays empty at the
        // next boot: the kept drums say "none", and the boot gives its default
        // kit only to a slot they did not name.
        d.setKit(\steps, 'tb');
        d.setKit(\onset, nil);
        ok = ~saKeepDrums.();
        sa2 = ~tCheck.("the next boot's MegaSA", { MegaSA(stub) });
        sa2 !? {
            sa2.drums.kitReader = d.kitReader;
            ~megaSA = sa2;
            ~tCheck.("...its drums at boot", { ~setupSADrums.() });
            ~tEq.("a slot kept empty stays empty at the next boot, the other on its kept kit",
                [ok, sa2.drums.kit(\steps), sa2.drums.kit(\onset), sa2.drums.kitState(\onset), ~saDrumsKitLine.(\onset)],
                [true, \tb, nil, \unset, "no onset kit"]);
            ~megaSA = sa;
            sa2.free;
        };
    };
    ~megaSA = nil;
    got = nil;
    ~tEq.("with no SA, Keep answers false", ~saKeepDrums.({ |flag| got = flag }), false);
    ~tEq.("...and tells its action so", got, false);
    ~tEq.("there are no kept drums to load", ~saLoadKeptDrums.(), false);
    ~tEq.("and no kits to name", ~saDrumsKitLine.(\steps), "no steps kit");
    ~tCheck.("and the drums at boot are nothing", { ~setupSADrums.() });
    sa !? { |x| x.free };
    ~megaSA = saved[0];
    ~saDrumsKitDir = saved[1];
    ~saDrumsDefaultKits = saved[2];
    ~saKeptDrumsPath = saved[3];
    ~saKeptDrumsBefore = saved[4];
    (tmp +/+ "kept" +/+ "*").pathMatch.do { |p| File.delete(p) };
    [tmp +/+ "t" +/+ "a.wav", tmp +/+ "t" +/+ "b.wav", tmp +/+ "ta.json", tmp +/+ "tb.json",
        tmp +/+ "kept", tmp +/+ "t"].do { |p| if(File.exists(p)) { File.delete(p) } };
    ~tRemoveTree.(tmp);
}.value;
}.value;
