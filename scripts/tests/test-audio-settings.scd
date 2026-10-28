// The audio settings (docs/dev/audio-settings.md): saSystem's devices and
// inputs chosen in the launcher instead of written in a profile. The profile
// they make (~audioProfile) against a device list of the test's own, what
// gives way when a device is gone or an input is not there, the settings kept
// in settings.json beside the others, the server options a pair writes, and
// the one thing that stops a pair: two sample rates.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-audio-settings");

{
var scripts = thisProcess.nowExecutingPath.dirname.dirname;
var base, devs, rp, path, d, saved, notes, info, wasDevicesNow, wasLauncherAudio;
// An Event as sorted [key, value] pairs, to compare.
var pairs = { |e| e.keys.asArray.sort.collect { |k| [k, e[k]] } };
(scripts +/+ "setup-routing.scd").load;
if(~midiSettingsNow.isNil) { (scripts +/+ "setup-midimap.scd").load };
base = ~routingProfiles[\saSystem];
devs = (
    inputs: [(name: "MacBook Pro Microphone", channels: 1), (name: "Interface", channels: 4),
        (name: "Das Zwölfer Microphon", channels: 1), (name: "Mystery", channels: nil)],
    outputs: [(name: "MacBook Pro Speakers", channels: 2), (name: "Interface", channels: 4)],
    defaultIn: "MacBook Pro Microphone", defaultOut: "MacBook Pro Speakers");

~tEq.("saSystem takes its devices and inputs from the audio settings", base[\audioSettings], true);

// ---- the profile the settings make
rp = ~audioProfile.(base, (), devs);
~tEq.("nothing chosen: the system's default input and output, the instrument on input 1, as saSystem always was",
    [rp[\device], rp[\inDevice], rp[\outDevice], rp[\inChannel], rp[\analysisChannel], rp[\bassChannel],
        rp[\numInChans], rp[\numChans], rp[\audioNotes]],
    [\systemDefault, nil, nil, 0, 0, nil, 2, 2, []]);
~tEq.("...and saSystem's own values stay (SA, its pool, its latency, both sides recorded)",
    [rp[\sa], rp[\live], rp[\memSize], rp[\latencyMs], rp[\inChannelCount]], [true, false, 65536, 30, 2]);

rp = ~audioProfile.(base, (inDevice: "Interface", outDevice: "Interface", inChannel: 2, bassChannel: 3,
    hardwareBufferSize: 128), devs);
~tEq.("an interface for both: its name, the instrument on input 3 (analysed dry there), the bass on 4, the inputs it needs, the buffer",
    [rp[\device], rp[\inDevice], rp[\outDevice], rp[\inChannel], rp[\analysisChannel], rp[\bassChannel],
        rp[\numInChans], rp[\hardwareBufferSize], rp[\audioNotes]],
    ["Interface", "Interface", "Interface", 2, 2, 3, 4, 128, []]);
~tEq.("...saSystem itself is not changed", [base[\inChannel], base[\device], base[\inDevice]], [0, \systemDefault, nil]);

rp = ~audioProfile.(base, (outDevice: "Interface"), devs);
~tEq.("only the output chosen: the input is the system's default, by its name",
    [rp[\inDevice], rp[\outDevice], rp[\device], rp[\audioNotes]],
    ["MacBook Pro Microphone", "Interface", "MacBook Pro Microphone → Interface", []]);
rp = ~audioProfile.(base, (inDevice: "Das Zwölfer Microphone"), devs);
~tEq.("a name SuperCollider shortens is found, and kept as SuperCollider says it (what -H takes)",
    [rp[\inDevice], rp[\outDevice], rp[\audioNotes]], ["Das Zwölfer Microphon", "MacBook Pro Speakers", []]);

rp = ~audioProfile.(base, (inDevice: "Gone", outDevice: "Interface"), devs);
~tEq.("an input not connected gives way to the system's default input, and says so",
    [rp[\inDevice], rp[\outDevice], rp[\audioNotes].size, rp[\audioNotes][0].contains("not connected")],
    ["MacBook Pro Microphone", "Interface", 1, true]);
rp = ~audioProfile.(base, (inDevice: "Gone", outDevice: "Away"), devs);
~tEq.("...neither connected: the system's defaults, both said",
    [rp[\device], rp[\inDevice], rp[\audioNotes].size], [\systemDefault, nil, 2]);
rp = ~audioProfile.(base, (outDevice: "Interface"), devs.copy.put(\defaultIn, nil));
~tEq.("...a default with no name here (CoreAudio not read): both the system's defaults",
    [rp[\device], rp[\audioNotes].size, rp[\audioNotes][0].contains("no name")], [\systemDefault, 1, true]);

rp = ~audioProfile.(base, (inDevice: "Interface", inChannel: 7, bassChannel: 9), devs);
~tEq.("an input past the device's: the instrument on input 1, the bass none, each said",
    [rp[\inChannel], rp[\bassChannel], rp[\numInChans], rp[\audioNotes].size,
        rp[\audioNotes].every { |n| n.contains("Interface") }],
    [0, nil, 2, 2, true]);
rp = ~audioProfile.(base, (inDevice: "Interface", inChannel: 1, bassChannel: 1), devs);
~tEq.("...the bass on the instrument's input: no bass (it would play the instrument twice)",
    [rp[\inChannel], rp[\bassChannel], rp[\audioNotes].size, rp[\audioNotes][0].contains("instrument's")], [1, nil, 1, true]);
rp = ~audioProfile.(base, (bassChannel: 1), devs);
~tEq.("...a bass on input 2 of a laptop's one-input microphone: none",
    [rp[\device], rp[\bassChannel], rp[\audioNotes].size], [\systemDefault, nil, 1]);
rp = ~audioProfile.(base, (inDevice: "Mystery", inChannel: 5, bassChannel: 6), devs);
~tEq.("...a device whose inputs CoreAudio did not count: taken as chosen",
    [rp[\inChannel], rp[\bassChannel], rp[\numInChans], rp[\audioNotes]], [5, 6, 7, []]);
~tAssert.("every profile made keeps check.scd's rules: the tap and the bass inside the inputs asked for, the bass never the instrument's",
    [(), (inDevice: "Interface", inChannel: 3, bassChannel: 0), (inDevice: "Mystery", inChannel: 5, bassChannel: 6),
        (inDevice: "Interface", inChannel: 9, bassChannel: 9), (bassChannel: 0)].every { |a|
        var p = ~audioProfile.(base, a, devs);
        (p[\analysisChannel] < p[\numInChans]) and: { p[\bassChannel].isNil or: {
            (p[\bassChannel] < p[\numInChans]) and: { p[\bassChannel] != p[\inChannel] } } } });

~tEq.("the devices in words: the Rig page's Device row",
    [~audioDeviceLabel.(~audioProfile.(base, (), devs)), ~audioDeviceLabel.(~audioProfile.(base, (inDevice: "Interface", outDevice: "Interface"), devs)),
        ~audioDeviceLabel.(~audioProfile.(base, (outDevice: "Interface"), devs)), ~audioDeviceLabel.((device: "TSMEGA")), ~audioDeviceLabel.(nil)],
    ["System default input and output", "Interface", "MacBook Pro Microphone → Interface", "TSMEGA", "—"]);

// ---- kept in settings.json, beside what else is there
path = ~midiSettingsPath.();
File.mkdir(path.dirname);
File.use(path, "w", { |f| f.write("{\"format\": \"megalooper settings\", \"version\": 1, \"midi\": {\"maps\": {\"saSystem\": \"keys-and-knobs\"}}, "
    "\"gui\": {\"theme\": \"light\"}}") });
~midiSettings = nil;
~tEq.("no audio settings yet: none", pairs.(~audioSettingsRead.()), []);
~audioSettingsWrite.((inDevice: "Interface", outDevice: "MacBook Pro Speakers", inChannel: 2, bassChannel: 0,
    hardwareBufferSize: 256), true);
~tEq.("written and read back: the devices by name, the inputs and the buffer as numbers",
    pairs.(~audioSettingsRead.()), pairs.((inDevice: "Interface", outDevice: "MacBook Pro Speakers", inChannel: 2, bassChannel: 0,
        hardwareBufferSize: 256)));
d = File.readAllString(path).parseJSON;
~tEq.("...and the settings beside them stay: the theme, the rig's MIDI map",
    [d["gui"]["theme"], d["midi"]["maps"]["saSystem"]], ["light", "keys-and-knobs"]);
~audioSettingsWrite.((inDevice: "Interface"), true);
~tEq.("written again: what is left out is gone (the system's default, no bass)", pairs.(~audioSettingsRead.()), [[\inDevice, "Interface"]]);
File.use(path, "w", { |f| f.write("{\"format\": \"megalooper settings\", \"audio\": {\"inChannel\": \"two\", \"inDevice\": \"Interface\"}}") });
~tEq.("...a value that is no number is left out, not read as 0", pairs.(~audioSettingsRead.()), [[\inDevice, "Interface"]]);
File.use(path, "w", { |f| f.write("not json") });
~tEq.("...a file that does not read: no audio settings", pairs.(~audioSettingsRead.()), []);
File.delete(path);
~midiSettings = nil;

// ---- what a pair writes into the server's options
saved = [s.options.inDevice, s.options.outDevice, s.options.numInputBusChannels, s.options.numOutputBusChannels,
    s.options.hardwareBufferSize, s.options.sampleRate, s.options.memSize, ~serverOptionsBefore,
    ~rp, ~audioDevice, ~inChannel, ~analysisChannel, ~bassChannel, ~outChannel, ~returnChannel, ~sessionChannel,
    ~systemDefaultDevice, ~deviceFound];
wasDevicesNow = ~audioDevicesNow;
wasLauncherAudio = ~launcherAudio;
protect {
    ~audioDevicesNow = { devs };
    ~launcherAudio = (inDevice: "Interface", outDevice: "MacBook Pro Speakers", inChannel: 1, bassChannel: 3);
    ~applyRoutingProfile.(\saSystem);
    ~tEq.("saSystem under the launcher's choice: the input and output devices apart, the inputs it needs",
        [s.options.inDevice, s.options.outDevice, s.options.numInputBusChannels, s.options.numOutputBusChannels,
            ~inChannel, ~analysisChannel, ~bassChannel, ~rp[\inDevice], ~deviceFound],
        ["Interface", "MacBook Pro Speakers", 4, 2, 1, 1, 3, "Interface", true]);
    ~launcherAudio = ();
    ~applyRoutingProfile.(\saSystem);
    ~tEq.("...nothing chosen: no device named, so scsynth opens the system's defaults",
        [s.options.inDevice, s.options.outDevice, s.options.numInputBusChannels, ~audioDevice],
        [nil, nil, 2, \systemDefault]);
    ~launcherAudio = (inDevice: "Gone");
    ~tEq.("...a device not connected does not stop the start", ~applyRoutingProfile.(\saSystem)[\audioNotes].size, 1);
} {
    ~audioDevicesNow = wasDevicesNow;
    ~launcherAudio = wasLauncherAudio;
    s.options.inDevice = saved[0]; s.options.outDevice = saved[1];
    s.options.numInputBusChannels = saved[2]; s.options.numOutputBusChannels = saved[3];
    s.options.hardwareBufferSize = saved[4]; s.options.sampleRate = saved[5]; s.options.memSize = saved[6];
    ~serverOptionsBefore = saved[7];
    ~rp = saved[8]; ~audioDevice = saved[9]; ~inChannel = saved[10]; ~analysisChannel = saved[11];
    ~bassChannel = saved[12]; ~outChannel = saved[13]; ~returnChannel = saved[14]; ~sessionChannel = saved[15];
    ~systemDefaultDevice = saved[16]; ~deviceFound = saved[17];
};

// ---- Apply and restart: what goes, in what order, and when it refuses
{
    var keys = #[\looper, \megaSA, \megaRemote, \audioRestartQuit, \audioRestartLater, \audioRestartBoot,
        \launcherAudio, \launcherBufferSize, \audioRestarting, \audioRestarted];
    var order = List.new, quitDone, was = keys.collect { |k| currentEnvironment[k] }, remote, looper, ticking;
    var choice = (inDevice: "Interface", outDevice: "Interface", inChannel: 1, hardwareBufferSize: 256);
    protect {
        ~midiSettings = nil;
        ~audioRestarting = false;
        // Real ones (Object's own free and stop do nothing, so an Event can't
        // stand in): a Looper with a routine of its own running, whose free
        // stops it, and a MegaRemote listening, in the harness's scratch folder.
        ~looper = (sessionRecording: true);
        looper = ~tLooper.();
        ticking = Routine { loop { 1.yield } };
        ticking.next;
        looper.instVarPut(\clickRoutine, ticking);
        remote = MegaRemote({ () }).start(58999);
        ~megaRemote = remote;
        ~megaSA = ();
        ~audioRestartQuit = { |done| order.add(\quit); quitDone = done };
        ~audioRestartBoot = { order.add(\boot) };
        ~audioRestartLater = { |f| f.value };
        ~tEq.("a set being recorded refuses the restart, and nothing goes",
            [~audioApply.(choice), order.asArray], ["Stop Record set first: a restart would end it", []]);
        ~looper = looper;
        ~tEq.("otherwise: the AI's listener stops, the looper is freed (its routines stop), it and SA go, the server quits, and nothing boots yet",
            [~audioApply.(choice), remote.started, ticking.next, ~looper, ~megaSA, order.asArray],
            [nil, false, nil, nil, nil, [\quit]]);
        ~tEq.("...the choice is kept, and handed to the boot as the launcher's is",
            [~audioSettingsRead.()[\inDevice], ~audioSettingsRead.()[\hardwareBufferSize], ~launcherAudio[\inChannel],
                ~launcherBufferSize], ["Interface", 256, 1, 256]);
        ~tEq.("...a second Apply while it starts again is refused",
            ~audioApply.(choice), "megalooper is starting again already");
        quitDone.value;
        ~tEq.("the server gone, the boot runs (and will say it started again), and a later Apply may restart again",
            [order.last, ~audioRestarted, ~audioRestarting], [\boot, true, false]);
    } {
        keys.do { |k, i| currentEnvironment.put(k, was[i]) };
        File.delete(~midiSettingsPath.());
        ~midiSettings = nil;
    };
}.value;

// ---- the setup's calibration, and what it starts from without one
{
    var profiles = (saSystem: base,
        liveRig: (device: "Interface", numChans: 2, live: true, latencyMs: 40),
        sa: (device: "Interface", numChans: 2, sa: true, live: false, latencyMs: 9, onsetThreshold: 0.4),
        elsewhere: (device: "Elsewhere", numChans: 2, sa: true, latencyMs: 5));
    var both = (inDevice: "Interface", outDevice: "Interface", hardwareBufferSize: 64), p, looper, root, said, maps, settings;
    ~tEq.("the setup in words, its calibration's key: the devices (the system's by their names) and the buffer",
        [~audioProfile.(base, both, devs)[\calibrationKey], ~audioProfile.(base, (), devs)[\calibrationKey],
            ~audioProfile.(base, (outDevice: "Interface"), devs)[\calibrationKey],
            ~audioProfile.(base, (), devs.copy.put(\defaultIn, nil).put(\defaultOut, nil))[\calibrationKey]],
        ["Interface @ 64 frames", "MacBook Pro Microphone → MacBook Pro Speakers @ the device's buffer",
            "MacBook Pro Microphone → Interface @ the device's buffer",
            "system default input → system default output @ the device's buffer"]);
    p = ~audioInherit.(~audioProfile.(base, both, devs), profiles, \saSystem);
    ~tEq.("on the device a rig of yours names, both ways: that rig (one with SA first), its starting numbers, and where the calibration is looked for",
        [p[\inheritRig], p[\latencyMs], p[\onsetThreshold], p[\calibrationKeys]],
        [\sa, 9, 0.4, ["Interface @ 64 frames", \sa, \saSystem]]);
    p = ~audioInherit.(~audioProfile.(base, (inDevice: "Interface"), devs), profiles, \saSystem);
    ~tEq.("...the interface in and the speakers out is another setup: no rig of yours, saSystem's numbers",
        [p[\inheritRig], p[\latencyMs], p[\calibrationKeys]],
        [nil, 30, ["Interface → MacBook Pro Speakers @ the device's buffer", \saSystem]]);
    p = ~audioInherit.(~audioProfile.(base, (), devs), profiles, \saSystem);
    ~tEq.("...and so is the system's default", [p[\inheritRig], p[\calibrationKeys].size], [nil, 2]);

    // The calibration kept, looked for in order.
    root = MegaFiles.userRoot;
    File.mkdir(root);
    File.use(LooperCalibrator.keptPathIn(root), "w", { |f| f.write("{\"format\": \"megalooper calibration\", \"version\": 1, "
        "\"rigs\": {\"sa\": {\"latencyMs\": 12}, \"saSystem\": {\"latencyMs\": 30}}}") });
    p = ~audioInherit.(~audioProfile.(base, both, devs), profiles, \saSystem);
    looper = ~tLooper.();
    said = LooperCalibrator.applyKeptAtStart(looper, p, p[\calibrationKeys], root);
    ~tEq.("nothing kept for the setup: the rig of yours' kept numbers, said", [looper.latencyMs, said.contains("kept for sa")], [12, true]);
    LooperCalibrator.keep(LooperCalibrator.keptPathIn(root), p[\calibrationKey], \latencyMs, 15);
    said = LooperCalibrator.applyKeptAtStart(looper, p, p[\calibrationKeys], root);
    ~tEq.("...once the setup keeps its own, those", [looper.latencyMs, said.contains("Interface @ 64 frames")], [15, true]);
    p = ~audioInherit.(~audioProfile.(base, (inDevice: "Interface"), devs), profiles, \saSystem);
    LooperCalibrator.applyKeptAtStart(looper, p, p[\calibrationKeys], root);
    ~tEq.("...another setup with none: saSystem's from before", looper.latencyMs, 30);
    ~tEq.("...and a rig name alone still works as it did", [LooperCalibrator.keptKeyOf(LooperCalibrator.keptPathIn(root), \sa),
        LooperCalibrator.keptKeyOf(LooperCalibrator.keptPathIn(root), [\none, nil])], [\sa, nil]);
    File.delete(LooperCalibrator.keptPathIn(root));

    // The MIDI map taken over, once.
    protect {
        ~midiSettings = nil;
        settings = ~midiSettingsNow.();
        settings[\maps].put(\sa, "tsmega").put(\saSystem, "keys-and-knobs");
        p = ~audioInherit.(~audioProfile.(base, both, devs), profiles, \saSystem);
        said = ~audioAdoptMap.(p, \saSystem);
        ~tEq.("saSystem on the rig's device takes over its map from a shipped one, and says so",
            [settings[\maps][\saSystem], said], ["tsmega", "MIDI map tsmega, as your rig sa on Interface uses it"]);
        ~tEq.("...once: the next start has nothing to say", ~audioAdoptMap.(p, \saSystem), nil);
        File.mkdir(~midiUserDir.());
        File.use(~midiUserDir.() +/+ "mine.json", "w", { |f| f.write("{}") });
        settings[\maps].put(\saSystem, "mine");
        ~tEq.("...never over a map of your own", [~audioAdoptMap.(p, \saSystem), settings[\maps][\saSystem]], [nil, "mine"]);
        ~tEq.("...nor on a setup no rig of yours names",
            ~audioAdoptMap.(~audioInherit.(~audioProfile.(base, (), devs), profiles, \saSystem), \saSystem), nil);
    } {
        File.delete(~midiUserDir.() +/+ "mine.json");
        File.delete(~midiSettingsPath.());
        ~midiSettings = nil;
    };
}.value;

// ---- the pair's preflight
info = IdentityDictionary[
    'Interface' -> (name: "Interface", in: 4, out: 4, rate: 44100),
    'MacBook Pro Speakers' -> (name: "MacBook Pro Speakers", in: 0, out: 2, rate: 48000)];
rp = ~audioProfile.(base, (inDevice: "Interface", outDevice: "MacBook Pro Speakers"), devs);
notes = List.new;
~checkAudioPair.(rp, info, \saSystem, notes);
~tEq.("two sample rates are said before the start: scsynth refuses them", notes.asArray, ["input and output sample rates differ"]);
info['Interface'][\rate] = 48000;
notes = List.new;
~checkAudioPair.(rp, info, \saSystem, notes);
~tEq.("...one rate: nothing to say", notes.asArray, []);
}.value;

// ---- the buffer the server runs at
// A chosen buffer is the server's, and the device is not asked: CoreAudio
// keeps the size per program, so a device asked from here never says what
// scsynth asked for. None chosen, it says what a program that asks for none
// gets (tools/coreaudio.py; here a stand-in in a root of the test's own that
// answers as the real one does, so no device is touched).
{
var dir = ~tTempPath.("audio-buffer"), wasRoot = ~megalooperRoot, opts, b;
var run = { |buffer, outDevice|
    opts = ServerOptions.new;
    opts.hardwareBufferSize = buffer;
    opts.outDevice = outDevice;
    ~audioBufferRunning.((options: opts))
};
~megalooperRoot = dir;
protect {
    b = run.(64, "Interface");
    ~tEq.("a chosen buffer is the server's, the device not asked (the root has no tool)", [b[\frames], b[\own]], [64, false]);
    ~tEq.("...the boot line says it, and the rig block", [~audioBufferRunningLabel.(b), ~audioBufferRunningShort.(b)],
        ["64 frames", "BUF 64"]);
    if(MegaFiles.isMac) {
        File.mkdir(dir +/+ "tools");
        File.use(dir +/+ "tools" +/+ "coreaudio.py", "w", { |f| f.write(
            "import json, sys\n"
            "a = sys.argv[1:]\n"
            "if a[0] == 'defaults':\n"
            "    print(json.dumps({'input': {'name': 'Mic'}, 'output': {'name': 'Default Out'}, 'agree': True}))\n"
            "elif a[0] == 'latency' and a[1:3] == [a[1], '--json']:\n"
            "    print(json.dumps({'buffer_now': {'Interface': 512, 'Default Out': 256}.get(a[1], 0), 'name': a[1]}))\n") });
        b = run.(nil, "Interface");
        ~tEq.("none chosen: the output device's own, as the device says it", [b[\frames], b[\own]], [512, true]);
        ~tEq.("...the boot line says whose, the rig block the size", [~audioBufferRunningLabel.(b), ~audioBufferRunningShort.(b)],
            ["512 frames (the device's own)", "BUF 512"]);
        ~tEq.("the system's default output: asked by its name", run.(nil, nil)[\frames], 256);
        b = run.(nil, "Gone");
        ~tEq.("a device that says nothing usable: no size, and the words say so",
            [b[\frames], b[\own], ~audioBufferRunningLabel.(b), ~audioBufferRunningShort.(b)],
            [nil, true, "the device's own", "BUF –"]);
    } {
        ~tSkip.("the device's own buffer", "CoreAudio only");
    };
    ~tEq.("no reading at all (a window built without a boot)", [~audioBufferRunningLabel.(nil), ~audioBufferRunningShort.(nil)],
        ["the device's own", "BUF –"]);
} {
    ~megalooperRoot = wasRoot;
    ~tRemoveTree.(dir);
};
}.value;
