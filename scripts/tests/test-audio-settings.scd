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
