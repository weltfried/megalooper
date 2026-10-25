// megalooper — routing profiles and the boot-time audio guards.
//
// Loaded by boot.scd; defines only, runs nothing. boot.scd picks the profile
// (~routingProfile) and calls ~applyRoutingProfile BEFORE s.boot, then
// ~checkSampleRate once the server is up.
//
// A profile is one rig: which audio device, how many channels, and where the
// three SC<->Live stereo pairs sit. The full setup recipe for every rig — the
// TotalMix loopback, the Loopback bridge, the BlackHole aggregates — is in
// docs/routing.md. Read that before adding or debugging a rig.
(
// The rig to boot when nothing else says otherwise: boot.scd takes it as its
// default, and launcher.scd preselects it in the menu on the first launch (it
// remembers your choice after that). saSystem is megalooper's one rig of its
// own: Megalooper SA, with its effect chains and drums, on the system's
// default input and output, so it is right on any Mac with nothing to set up.
// A rig of yours (profiles.scd, below the table) can be named here instead.
~defaultRoutingProfile = \saSystem;

// device: exact CoreAudio name (ServerOptions.devices lists them). Channels
// are 0-indexed stereo pairs: inChannel = SC reads Live's processed guitar;
// outChannel = SC writes the loop to Live; returnChannel = SC reads Live's
// processed loop (loop-chaining) — must differ from inChannel or overdubs
// feed back.
//
// analysisChannel is different in kind: a SINGLE (mono) input channel that only
// the onset/pitch detection reads. It is the guitar's OWN hardware input on this
// device — SC and Live both have the device open, so SC can read the dry guitar
// straight from the interface. Nothing about Live is involved: no pre-FX track,
// no extra loopback pair, and no FX smearing the attacks the meter fit depends
// on. nil on a rig where SC cannot see the guitar's input. See "The clean
// analysis tap" in docs/routing.md.
//
// sessionChannel is a fifth role and the only one nothing plays: a STEREO
// input pair carrying LIVE'S MASTER back to SC, so the session recorder can
// write what the room heard rather than the loop alone. nil on saSystem, which
// has no Live; a Live rig sets it once the set has the track: it needs a track in the
// Ableton set (Audio From: Resampling, Monitor: In, Audio To: Ext. Out on the
// chosen pair), and a rig that has the number set but not the track records
// SILENCE into the master file — which you would only discover after the gig.
// Set it per rig once the Live side exists; until then the recorder writes the
// dry tap alone and the Perform tab says so. See "Recording the set" in
// docs/routing.md.
//
// bassChannel (SA rigs only) is the bass's hardware input, a SINGLE (mono)
// channel like the analysis tap: Megalooper SA plays it through a chain of its
// own (the FX view's BASS row) onto a strip of its own. nil (or absent) on a
// rig with no bass; the bass then has no strip and its row is not shown. It
// must be an input the profile asks for, and neither the guitar's input nor
// the analysis tap. Nothing records it into the loop yet.
//
// numInChans is optional and defaults to numChans. It exists because the
// analysis tap is the one thing SC needs from the HARDWARE block above the
// virtual device, and asking for those channels on the OUTPUT side too would
// hand SC a path to the speakers (the footgun the \bh* rigs deliberately
// removed). Inputs grow; outputs stay put. sampleRate is optional and only
// drives the post-boot warning, unless setSampleRate is true: then the device
// is switched to it before the boot (see \sa). hardwareBufferSize is optional
// too; a profile without it boots at whatever buffer size the server options
// held before any profile was applied.
//
// midiMap: names the MIDI map a rig starts with (presets/midi/<name>.json, or
// a map of yours with that name: docs/dev/midi-map.md 8.4). What you choose on the
// Rig tab's MIDI section is kept in settings.json and wins. saSystem names
// none: a stranger's keyboard should do nothing until it is mapped. A rig of
// yours may name a map of yours.
//
// sa: true makes boot.scd build Megalooper SA's mixer around the Looper
// (scripts/setup-sa.scd), and live: false says the rig has no Live at all, so
// the Live preflight has nothing to check, and the Calibrate view's wizard is
// the one without Live, which keeps what it finds for the rig.
//
// Two timing values are per-rig because they ARE per-rig — they depend on the
// round trip through that rig's device and buffers, so a number calibrated on
// one is wrong on the next:
//   latencyMs       overdub latency compensation ("Overdub lat" slider)
//   abletonSyncMs   MIDI-clock offset to Live ("Live sync" slider); optional,
//                   defaults to 0, may be negative (negative pulls Live earlier)
//   chainRecOffsetMs   where the loop-chain recorder starts relative to the loop
//                   boundary, ms, negative = earlier; optional, defaults to 0.
//                   Per-rig, and the one value here that is MEASURED rather than
//                   dialled by ear: chain a loop and run
//                   scripts/check-chain-align.scd, then set this to exactly the
//                   offset it reports.
//   onsetNoteOffsetMs  timing trim for the onset notes ("Offset" in the onset
//                   analysis window); optional, defaults to 0, negative sends
//                   them earlier. Per-rig because the loop's audio crosses the
//                   virtual device and Live's input buffer while the notes go
//                   straight over IAC — that gap is this rig's, not the code's.
//   onsetThreshold  Onsets.kr detection threshold; optional, defaults to 0.5.
//                   Per-rig because how noisy the guitar input is depends on the
//                   interface and the tap. Tune it live in the Onset analysis
//                   window against the scope, then write the number back.
// Both are only STARTING values: setup-model.scd pushes them into the Looper at
// boot and the GUI sliders then adjust them live. When you re-calibrate a rig by
// ear, write the number back here so the next boot starts where you left off.
~routingProfiles = (
    // Megalooper SA on whatever interface you have: the system's default input
    // and output, the guitar on input 1, the mix on outputs 1/2, at the
    // device's own rate and block size: nothing is switched or forced.
    //
    // `device: \systemDefault` is a SENTINEL, not a device name.
    // ~applyRoutingProfile maps it to `s.options.device = nil`, which makes SC
    // omit -H entirely so scsynth opens the default input AND the default
    // output: on a laptop the mic and the speakers are two separate CoreAudio
    // devices, and no single device name can name both.
    //
    // No MIDI map is named, so none is assumed: map your own controller on the Setup
    // view.
    //
    // latencyMs 30 is a placeholder for the overdub round trip: the loop's
    // master limiter's 20 ms plus about 10 ms for a direct interface at 64 to
    // 128 frames. Run the Calibrate view's latency step, or dial it by ear.
    // memSize: the effects' delay lines and PitchLoop's memory need the 64 MB
    // pool, as on \sa. Both sides of the guitar chain are recorded, as on \sa.
    // No bassChannel: on a laptop the system's input 2 is its microphone. A
    // rig with a bass on input 2 says bassChannel: 1 in a profile of its own.
    //
    // audioSettings: true makes these the defaults under what you choose in
    // the launcher (settings.json's "audio": the input and output devices,
    // the instrument's and the bass's inputs, the buffer): ~audioProfile
    // below turns the two into the profile the boot uses. With nothing
    // chosen it is the system's default input and output, as written here.
    saSystem: (
        device: \systemDefault, numChans: 2, numInChans: 2,
        inChannel: 0, outChannel: nil, returnChannel: nil,
        analysisChannel: 0,
        sessionChannel: nil,
        inChannelCount: 2, latencyMs: 30, chainRecOffsetMs: 20,
        memSize: 65536,
        sa: true, live: false, audioSettings: true)
);

// The tests' rigs (scripts/tests/fixtures/routing-profiles.scd, which the
// harness hands over): nothing else sets this.
~routingProfilesExtra !? { |extra| ~routingProfiles.putAll(extra) };

// Your own rigs: profiles.scd in your megalooper folder, one Event literal
// with a profile per key (docs/routing.md, "Adding a rig"). Read at every
// load of this file, the launcher's and the boot's, through the same reader
// as the presets, so a mistake in it is reported and megalooper starts with
// its own rigs. A profile of yours with saSystem's name replaces it.
~userRoutingProfilesPath = { MegaFiles.userRoot +/+ "profiles.scd" };
~userRoutingProfiles = {
    var path = ~userRoutingProfilesPath.(), data, ok;
    if(File.exists(path).not) { () } {
        data = Looper.readPresetFile(path, { |why|
            ("megalooper: your rigs in " ++ path ++ " were not read: " ++ why ++ ".").warn });
        case
        { data.isNil } { () }
        { data.isKindOf(Dictionary).not } {
            ("megalooper: " ++ path ++ " should hold one Event of profiles, ( myRig: (...) ); it was not read.").warn;
            ()
        }
        {
            ok = ();
            data.keysValuesDo { |k, rp|
                if(rp.isKindOf(Dictionary) and: { rp[\device].notNil }) { ok.put(k.asSymbol, rp) } {
                    ("megalooper: the rig " ++ k ++ " in " ++ path ++ " names no device; it was left out.").warn
                }
            };
            ok
        }
    }
};
~routingProfiles.putAll(~userRoutingProfiles.());

// What a rig brings, as the launcher says it under its menu: megalooper's
// saSystem and your own rigs sit side by side there, and this line is where
// one finds out which has the effect chains and the drums.
~routingProfileSays = { |key|
    var rp = ~routingProfiles[key];
    case
    { rp.isNil } { "" }
    { rp[\sa] == true } { "Megalooper SA: the looper with its effect chains (FX), its drums and its synth." }
    { rp[\live] == false } { "The looper alone: no effect chains, no drums, no Live." }
    { true } { "The looper beside Ableton Live." }
};

// The server options a profile may set beyond device and channels. What the
// options held before the FIRST profile was applied is kept, so a profile that
// leaves one out boots with that rather than with whatever the previous profile
// in this session asked for (64 frames on an aggregate Live shares is a
// different rig). The launcher's Buffer menu (~launcherBufferSize, frames)
// goes before the profile's: a slower computer needs a bigger buffer on any
// rig.
~applyServerOptions = { |rp|
    ~serverOptionsBefore = ~serverOptionsBefore ?? {
        (hardwareBufferSize: s.options.hardwareBufferSize, sampleRate: s.options.sampleRate,
            memSize: s.options.memSize)
    };
    s.options.hardwareBufferSize = ~launcherBufferSize ?? { rp[\hardwareBufferSize] }
        ?? { ~serverOptionsBefore[\hardwareBufferSize] };
    s.options.sampleRate = if(rp[\setSampleRate] == true) { rp[\sampleRate] }
        { ~serverOptionsBefore[\sampleRate] };
    s.options.memSize = rp[\memSize] ?? { ~serverOptionsBefore[\memSize] ? 8192 };
};

// The audio devices by name, as CoreAudio lists them. SuperCollider can list
// none on Linux, where JACK or PipeWire holds the interface (the primitive
// fails there): empty then, and never a throw. The launcher asks here too.
~audioDeviceNames = {
    if(MegaFiles.isLinux) { [] } { ((try { ServerOptions.devices }) ? []).collect { |d| d.asString } }
};

// Switch a device's nominal rate before the boot, through tools/coreaudio.py,
// which waits until the device reports the new rate. Answers true on success.
// Fails while another program holds the device, which for \sa means Live.
~switchDeviceRate = { |name, rate|
    var tool = (~megalooperRoot ?? { Looper.repoRoot }) +/+ "tools" +/+ "coreaudio.py";
    var said = ("python3 " ++ tool.quote ++ " set-rate " ++ name.asString.quote
        ++ " --rate " ++ rate ++ " 2>&1").unixCmdGetStdOut.stripWhiteSpace;
    ("    " ++ said).postln;
    said.contains("error").not
};

// Resolve a profile into ~rp + the ~inChannel/~outChannel/~returnChannel/
// ~analysisChannel the rest of the boot reads, and write the server options.
// ~analysisChannel may be nil (rig with no clean tap); the Looper then analyses
// its recorded input, as it did before the tap existed. MUST be called before
// s.boot — device and channel count are fixed at boot time.
//
// Guard: the selected profile's audio device must actually be present, else
// SuperCollider silently boots on the DEFAULT device with the wrong channel
// count and every SC<->Live route is broken. Fail loudly instead. SC truncates
// long / non-ASCII device names, so match leniently (either string contained in
// the other) rather than requiring an exact hit.
~applyRoutingProfile = { |profileName|
    var rp = ~routingProfiles[profileName];
    var found;
    if(rp.isNil) {
        Error("megalooper: unknown routing profile '" ++ profileName
            ++ "'. Known: " ++ ~routingProfiles.keys.asArray.join(", ")).throw;
    };
    // saSystem: under the audio settings (the launcher's, or settings.json's).
    if(rp[\audioSettings] == true) {
        rp = ~audioProfile.(rp, ~launcherAudio ?? { ~audioSettingsRead.() }, ~audioDevicesNow.());
    };

    ~rp            = rp;
    ~audioDevice   = rp[\device];
    ~inChannel       = rp[\inChannel];
    ~outChannel      = rp[\outChannel];
    ~returnChannel   = rp[\returnChannel];
    ~analysisChannel = rp[\analysisChannel];
    ~sessionChannel  = rp[\sessionChannel];
    ~bassChannel     = rp[\bassChannel];

    // \systemDefault means "whatever CoreAudio is defaulting to". Setting the
    // option to nil makes SC omit -H, so scsynth opens the default INPUT and the
    // default OUTPUT — which on a laptop are two different devices, so there is
    // no name to look up and nothing to guard against.
    ~systemDefaultDevice = ~audioDevice == \systemDefault;
    // A pair chosen in the audio settings opens its input and its output
    // apart (-H "in" "out"); scsynth joins the two itself.
    if(rp[\inDevice].notNil) {
        s.options.inDevice = rp[\inDevice];
        s.options.outDevice = rp[\outDevice];
    } {
        s.options.device = if(~systemDefaultDevice) { nil } { ~audioDevice };
    };
    // Inputs may reach higher than outputs to expose the analysis tap — see the
    // numInChans note on the table above.
    s.options.numInputBusChannels  = rp[\numInChans] ? rp[\numChans];
    s.options.numOutputBusChannels = rp[\numChans];
    ~applyServerOptions.(rp);

    // The audio settings' devices were looked up already (~audioProfile),
    // and one not connected gave way to the system's.
    found = ~systemDefaultDevice or: { rp[\inDevice].notNil } or: {
        ~audioDeviceNames.().any { |d|
            var listed = d.asString, want = ~audioDevice.asString;
            (listed == want) or: { listed.contains(want) } or: { want.contains(listed) }
        }
    };
    ~deviceFound = found;
    if(found.not) {
        "".postln;
        "!!! ==================== megalooper ROUTING ERROR ====================".postln;
        ("!!! Profile '" ++ profileName ++ "' needs audio device \""
            ++ ~audioDevice ++ "\" — NOT FOUND.").postln;
        case
            // A profile that lists its aggregate's members is one.
            { rp[\members].notNil } {
                "!!! In Audio MIDI Setup, create an Aggregate Device with that EXACT name:".postln;
                ("!!!   " ++ rp[\members].join(", ") ++ ", in that order.").postln;
                "!!!   Clock Source = the interface, Drift Correction on every other row,".postln;
                "!!!   48 kHz throughout. Full recipe is in docs/routing.md.".postln;
                "!!! (Or switch ~routingProfile to the rig you actually have plugged in.)".postln;
            }
            { true } {
                "!!! Connect/power on the interface, or change ~routingProfile in boot.scd.".postln;
            };
        "!!! Audio devices available right now:".postln;
        ~audioDeviceNames.().do { |d, i| ("!!!     " ++ i ++ ": " ++ d).postln };
        if(MegaFiles.isLinux) {
            "!!! On Linux megalooper knows no device by name: JACK or PipeWire has the".postln;
            "!!! interface. Use the saSystem rig, or a profile of your".postln;
            "!!! own with device: \\systemDefault (docs/linux.md).".postln;
        };
        "!!! =================================================================".postln;
        Error("megalooper: audio device '" ++ ~audioDevice ++ "' not found for profile '"
            ++ profileName ++ "'. Boot aborted — see the banner above.").throw;
    };
    rp
};

// Post-boot check. A profile may declare the rate its rig is wired for.
// Mismatches are the classic aggregate-device trap: every member has to run at
// ONE rate or CoreAudio silently resamples the odd one out — and this machine
// has devices sitting at both 44.1 and 48 kHz. Warn rather than abort; the rig
// still makes sound, it just is not the one that was set up.
// ===========================================================================
// VSTPlugin preflight — what an SA rig needs to host its plugin
//
// SA hosts its guitar plugin through VSTPlugin. On a stranger's Mac three
// things go wrong silently: it is not installed (SA then plays its built-in
// effects with no amp); its release ships VSTPlugin_supernova.scx beside
// VSTPlugin.scx, and scsynth loads both, whose duplicate Cocoa classes risk a
// crash in the plugin's window; and a copy downloaded in a browser is
// quarantined, so macOS refuses VSTPlugin.scx and its `host` (which probes
// every plugin) without saying why. Answers what it found, as notes.
~vstPluginFacts = {
    var cls = \VSTPlugin.asClass;
    var dir = cls !? { |c| c.filenameSymbol.asString.dirname.dirname +/+ "plugins" };
    // The quarantine is macOS's alone.
    var quarantined = { |path|
        MegaFiles.isMac and: { File.exists(path) } and: {
            ("xattr -p com.apple.quarantine " ++ path.shellQuote ++ " 2>/dev/null").unixCmdGetStdOut.size > 0 }
    };
    (
        installed: cls.notNil,
        version: cls !? { |c| [c.versionMajor, c.versionMinor, c.versionBugfix] },
        dir: dir,
        supernova: dir.notNil and: { File.exists(dir +/+ "VSTPlugin_supernova.scx") },
        quarantined: dir !? { |d| ["VSTPlugin.scx", "host"].select { |f| quarantined.(d +/+ f) } } ? []
    )
};

~checkVSTPlugin = { |profileName|
    var rp = ~routingProfiles[profileName];
    var notes = List.new, facts;
    if(rp.notNil and: { rp[\sa] == true }) {
        facts = try { ~vstPluginFacts.() } { |err|
            ("megalooper: the VSTPlugin preflight failed (" ++ err.errorString ++ "); skipping it.").warn;
            nil
        };
        facts !? { |f|
            case
            { f[\installed].not } {
                notes.add("VSTPlugin is not installed: SA plays its built-in effects, and the instrument has no amp "
                    ++ "plugin. ./tools/install.sh fetches it (or by hand: docs/standalone.md, Plugins).");
            }
            { true } {
                if(f[\version].notNil and: { (f[\version][0] != 0) or: { f[\version][1] != 6 } }) {
                    notes.add("VSTPlugin " ++ f[\version].join(".") ++ " is installed; megalooper is built and "
                        ++ "tested on 0.6.2.");
                };
                if(f[\supernova]) {
                    notes.add("VSTPlugin_supernova.scx sits beside VSTPlugin.scx in " ++ f[\dir]
                        ++ ": delete it. scsynth loads every .scx, and the two copies' Cocoa classes risk a crash "
                        ++ "in the plugin's window.");
                };
                if(f[\quarantined].notEmpty) {
                    notes.add("macOS has quarantined " ++ f[\quarantined].join(" and ") ++ " (a browser download), "
                        ++ "so it refuses them and no plugin opens. Run: xattr -dr com.apple.quarantine "
                        ++ f[\dir].dirname.shellQuote);
                };
            };
        };
        if(notes.notEmpty) {
            ("megalooper: VSTPlugin preflight for '" ++ profileName ++ "'").postln;
            notes.do { |n| ("    " ++ n).warn };
        };
    };
    notes.asArray
};

// Device preflight — what CoreAudio and Live ACTUALLY have
// ===========================================================================
// The existing guard above checks that a device with the right NAME exists.
// That is not enough, and the gap is exactly where the aggregates bite:
//
//   * `ServerOptions.devices` gives names alone.
//   * `s.options.numInputBusChannels` is what we ASKED for, never what CoreAudio
//     granted. Ask a degraded 16-channel aggregate for 17 inputs and SC boots
//     perfectly happily — the analysis tap just reads a bus nothing ever fills,
//     for the rest of the session, in silence.
//   * Nothing in SC can see what LIVE opened, and the two apps sharing one
//     device is the entire premise of every \bh* rig.
//
// So: ask the system. `system_profiler SPAudioDataType -json` costs ~0.2 s and
// sclang parses JSON itself, so there is nothing to install.

// name(Symbol) -> (name:, in:, out:, rate:). Empty if system_profiler is
// unavailable; every caller treats that as "cannot check" and lets boot proceed
// rather than blocking a gig on a diagnostic.
~audioDeviceInfo = {
    var found = IdentityDictionary.new;
    // macOS's own list: another system has none to read, and every caller
    // takes an empty answer as "cannot check".
    if(MegaFiles.isMac.not) { found } {
    try {
        var raw = "system_profiler SPAudioDataType -json 2>/dev/null".unixCmdGetStdOut;
        raw.parseJSON["SPAudioDataType"][0]["_items"].do { |it|
            var name = it["_name"].asString;
            found.put(name.asSymbol, (
                name: name,
                in:   (it["coreaudio_device_input"]  ? 0).asInteger,
                out:  (it["coreaudio_device_output"] ? 0).asInteger,
                rate: (it["coreaudio_device_srate"]  ? 0).asInteger,
                // Which devices the system is currently defaulting to. Only the
                // \systemDefault profile cares, and it cares a lot: scsynth
                // refuses to boot when the default input and output run at
                // different rates, which is the out-of-the-box state on plenty
                // of Macs.
                defaultIn:  it["coreaudio_default_audio_input_device"].notNil,
                defaultOut: it["coreaudio_default_audio_output_device"].notNil));
        };
    } { |err|
        ("megalooper: could not read the CoreAudio device list ("
            ++ err.errorString ++ ") — skipping the device preflight.").warn;
    };
    found
    }
};

// SC truncates long / non-ASCII device names, so every name comparison here is
// lenient the same way the boot guard is: either string containing the other.
~audioNameMatches = { |a, b|
    var x = a.asString, y = b.asString;
    (x == y) or: { x.contains(y) } or: { y.contains(x) }
};

~audioDeviceFind = { |info, name|
    info.detect { |d| ~audioNameMatches.(d[\name], name) }
};

// ---- The audio settings ------------------------------------------------------
// docs/dev/audio-settings.md. On saSystem (audioSettings: true) you choose the
// input and output devices, the instrument's input, the bass's and the buffer
// in the launcher, rather than writing a profile. They are kept in
// settings.json as "audio": {"inDevice", "outDevice", "inChannel",
// "bassChannel", "hardwareBufferSize"}, every one optional, the devices by
// the name SuperCollider gives them (what -H takes), the inputs counted from 0.

// The devices there are, for the menus and for ~audioProfile: (inputs:,
// outputs:, each [(name:, channels:)], channels nil where CoreAudio did not
// say; defaultIn:, defaultOut:, the system's defaults by SuperCollider's
// name, or nil). Empty off macOS, where JACK or PipeWire chooses.
~audioDevicesNow = {
    var info, list, sideOf, defaultOf;
    if(MegaFiles.isMac.not) { (inputs: [], outputs: []) } {
        info = ~audioDeviceInfo.();
        list = { |names, side|
            (names ? []).collect { |n| (name: n.asString, channels: ~audioDeviceFind.(info, n) !? { |d| d[side] }) }
        };
        defaultOf = { |entries, flag|
            info.detect { |d| d[flag] == true } !? { |d|
                entries.detect { |e| ~audioNameMatches.(e[\name], d[\name]) } !? { |e| e[\name] } }
        };
        sideOf = (inputs: list.((try { ServerOptions.inDevices }), \in),
            outputs: list.((try { ServerOptions.outDevices }), \out));
        sideOf.put(\defaultIn, defaultOf.(sideOf[\inputs], \defaultIn));
        sideOf.put(\defaultOut, defaultOf.(sideOf[\outputs], \defaultOut));
        sideOf
    }
};

// The profile the boot uses: `base` (saSystem) under `audio` (the settings,
// an Event of the five), against `devices` (~audioDevicesNow's). Never
// throws, and never refuses: a device not connected gives way to the system's
// default for that side, an input past the device's inputs to input 1 (the
// bass's to none), and each is said in the answer's audioNotes. With one side
// chosen, the other is the system's default by its name; with neither, the
// profile is the system's default input and output, as saSystem always was.
// Pure, so the tests hand it their own device lists.
~audioProfile = { |base, audio, devices|
    var rp = base.copy, notes = List.new, a = audio ? (), d = devices ? (inputs: [], outputs: []);
    var pick = { |entries, name| name !? { |n| (entries ? []).detect { |e| ~audioNameMatches.(e[\name], n) } } };
    var named = { |x| if(x.notNil and: { x.asString.notEmpty }) { x.asString } };
    var inName = named.(a[\inDevice]), outName = named.(a[\outDevice]);
    var inDev, outDev, inCount, inCh, bass;
    if(inName.notNil) {
        inDev = pick.(d[\inputs], inName);
        if(inDev.isNil) {
            notes.add("The input " ++ inName.quote ++ " is not connected: the system's default input instead.");
            inName = nil;
        };
    };
    if(outName.notNil) {
        outDev = pick.(d[\outputs], outName);
        if(outDev.isNil) {
            notes.add("The output " ++ outName.quote ++ " is not connected: the system's default output instead.");
            outName = nil;
        };
    };
    if(inName.notNil or: { outName.notNil }) {
        inDev = inDev ?? { pick.(d[\inputs], d[\defaultIn]) };
        outDev = outDev ?? { pick.(d[\outputs], d[\defaultOut]) };
        if(inDev.isNil or: { outDev.isNil }) {
            notes.add("The system's default " ++ (if(inDev.isNil) { "input" } { "output" })
                ++ " has no name here: both are the system's defaults.");
            inName = nil;
            outName = nil;
        };
    } {
        // Only to count its inputs.
        inDev = pick.(d[\inputs], d[\defaultIn]);
    };
    inCount = inDev !? { |x| x[\channels] };
    inCh = (a[\inChannel] ? 0).asInteger;
    if((inCh < 0) or: { inCount.notNil and: { inCh >= inCount } }) {
        notes.add("The instrument's input " ++ (inCh + 1) ++ " is not on " ++ (inDev !? { |x| x[\name].quote } ? "the input")
            ++ ": input 1 instead.");
        inCh = 0;
    };
    bass = a[\bassChannel] !? { |b| b.asInteger };
    if(bass.notNil and: { (bass < 0) or: { bass == inCh } or: { inCount.notNil and: { bass >= inCount } } }) {
        notes.add(if(bass == inCh) { "The bass's input is the instrument's: no bass this time." } {
            "The bass's input " ++ (bass + 1) ++ " is not on " ++ (inDev !? { |x| x[\name].quote } ? "the input")
                ++ ": no bass this time." });
        bass = nil;
    };
    rp[\inChannel] = inCh;
    rp[\analysisChannel] = inCh;
    rp[\bassChannel] = bass;
    rp[\numChans] = 2;
    rp[\numInChans] = [2, inCh + 1, (bass ? 0) + 1].maxItem;
    if(inName.isNil and: { outName.isNil }) {
        rp[\device] = \systemDefault;
        rp[\inDevice] = nil;
        rp[\outDevice] = nil;
    } {
        rp[\inDevice] = inDev[\name];
        rp[\outDevice] = outDev[\name];
        rp[\device] = if(inDev[\name] == outDev[\name]) { inDev[\name] } { inDev[\name] ++ " → " ++ outDev[\name] };
    };
    a[\hardwareBufferSize] !? { |n| rp[\hardwareBufferSize] = n.asInteger };
    rp[\audioNotes] = notes.asArray;
    rp
};

// The settings as kept, or () when there are none. settings.json is
// setup-midimap.scd's (~midiSettingsPath); its numbers come back from
// parseJSON as strings.
~audioSettingsKeys = #[\inDevice, \outDevice, \inChannel, \bassChannel, \hardwareBufferSize];
~audioSettingsRead = {
    var path = (~midiSettingsPath !? { |f| f.value }) ?? { MegaFiles.userRoot +/+ "settings.json" };
    var text = if(File.exists(path)) { try { File.readAllString(path) } };
    var d = text !? { |t| try { t.parseJSON } };
    var a = if(d.isKindOf(Dictionary)) { d["audio"] };
    var out = ();
    if(a.isKindOf(Dictionary)) {
        a["inDevice"] !? { |x| out[\inDevice] = x.asString };
        a["outDevice"] !? { |x| out[\outDevice] = x.asString };
        [\inChannel, \bassChannel, \hardwareBufferSize].do { |k|
            a[k.asString] !? { |x| if(x.isString.not or: { x.notEmpty and: { x.every { |c| c.isDecDigit or: { c == $- } } } }) {
                out[k] = x.asInteger } } };
    };
    out
};

// Kept in settings.json (setup-midimap.scd's writer, which keeps everything
// else there as it was). `sync` waits for the file: the launcher starts the
// boot right after, and the boot reads the settings again.
~audioSettingsWrite = { |audio, sync = false|
    var s = ~midiSettingsNow.(), raw = Dictionary.new, out = Dictionary.new, was = ~midiWriteSync;
    (s[\raw] ? ()).keysValuesDo { |k, v| raw.put(k, v) };
    ~audioSettingsKeys.do { |k| audio[k] !? { |v| out.put(k.asString, v) } };
    raw.put("audio", out);
    s[\raw] = raw;
    ~midiWriteSync = sync;
    protect {
        ~midiSettingsSave.({ |ok, why| if(ok != true) { ("megalooper: the audio settings were not kept: " ++ (why ? "")).warn } });
    } { ~midiWriteSync = was };
};

// The devices a profile plays on, in words: the Rig page's Device row.
~audioDeviceLabel = { |rp|
    case
    { rp.isNil } { "—" }
    { rp[\inDevice].notNil } {
        if(rp[\inDevice] == rp[\outDevice]) { rp[\inDevice] } { rp[\inDevice] ++ " → " ++ rp[\outDevice] } }
    { rp[\device] == \systemDefault } { "System default input and output" }
    { rp[\device].asString }
};

// Pre-boot health check for the profile's device. Run it AFTER
// ~applyRoutingProfile (it reads, and may amend, what that set up) and BEFORE
// s.boot — channel counts are fixed the moment the server starts.
//
// Aborts only when the SC<->Live pairs themselves cannot exist. A missing
// analysis tap degrades instead: the loop is unaffected, so it drops to
// analysing the recorded input — which is what tap-less rigs have always done —
// and says so, rather than ending the session over a diagnostic.
~checkAudioDevice = { |profileName|
    // The profile the boot resolved, for the rig it boots: saSystem's comes
    // from the audio settings and is not the table's.
    var rp    = (if(profileName == ~routingProfile) { ~rp }) ?? { ~routingProfiles[profileName] };
    var info  = ~audioDeviceInfo.();
    var dev   = ~audioDeviceFind.(info, rp[\device]);
    var wantOut = rp[\numChans];
    var wantIn  = rp[\numInChans] ? rp[\numChans];
    var notes = List.new;

    // What the audio settings could not have as chosen, and what took its place.
    (rp[\audioNotes] ? []).do { |n| ("!!! megalooper: " ++ n).postln; notes.add(n) };

    if(rp[\inDevice].notNil) { ~checkAudioPair.(rp, info, profileName, notes) } {
    if(rp[\device] == \systemDefault) {
        // No device name to look up — it is whatever CoreAudio is defaulting to.
        // There is exactly one thing worth checking, and it is not the channel
        // count: on a stock Mac the default INPUT and the default OUTPUT are two
        // separate devices, and scsynth flatly refuses to boot when they run at
        // different rates —
        //     "Input sample rate is 44100, but output is 48000. Mismatched
        //      sample rates are not supported."
        // That is the out-of-the-box state on plenty of Macs (built-in mic at
        // 44.1k, speakers at 48k), and the message names no fix. Say it here,
        // before the boot, in terms of the two devices actually involved.
        var inDev  = info.detect { |d| d[\defaultIn] == true and: { d[\in] > 0 } };
        var outDev = info.detect { |d| d[\defaultOut] == true and: { d[\out] > 0 } };
        "".postln;
        ("megalooper: profile '" ++ profileName
            ++ "' uses the system default input and output.").postln;
        inDev  !? { |d| ("    in  : " ++ d[\name] ++ "  " ++ d[\rate] ++ " Hz").postln };
        outDev !? { |d| ("    out : " ++ d[\name] ++ "  " ++ d[\rate] ++ " Hz").postln };
        if(inDev.notNil and: { outDev.notNil }
            and: { inDev[\rate] > 0 } and: { outDev[\rate] > 0 }
            and: { inDev[\rate] != outDev[\rate] }) {
            "".postln;
            "!!! ============== megalooper SAMPLE RATE MISMATCH ==============".postln;
            ("!!! '" ++ inDev[\name] ++ "' records at " ++ inDev[\rate]
                ++ " Hz but '" ++ outDev[\name] ++ "' plays at "
                ++ outDev[\rate] ++ " Hz.").postln;
            "!!! scsynth does not support that and will REFUSE TO BOOT.".postln;
            "!!!".postln;
            "!!! Fix it with one command — this sets the input to match the".postln;
            "!!! output, which is the rate you actually hear:".postln;
            "!!!".postln;
            "!!!     python3 tools/coreaudio.py match-default-rates".postln;
            "!!!".postln;
            "!!! Or by hand: Audio MIDI Setup, select each of those two devices".postln;
            ("!!! and set both Format rates to " ++ outDev[\rate] ++ " Hz.").postln;
            "!!! =============================================================".postln;
            notes.add("default in/out sample rates differ");
        };
        // Megalooper SA has its own return channel, and sends MIDI clock to
        // an IAC bus when there is one: only a plain default rig lacks both.
        if(rp[\sa] != true) {
            "    Loop chaining and MIDI clock are off on this rig — see docs/routing.md.".postln;
        };
        // Built-in mic into built-in speakers is a feedback loop, and the looper
        // plays back while it records. Worth one line before it howls.
        "    >>> Use headphones. A built-in mic feeding the speakers will feed back.".postln;
        if(notes.isEmpty) { "    device ok".postln };
        "".postln;
    } {
    if(info.isEmpty) {
        // Nothing to check against; the name guard above already ran.
    } {
        if(dev.isNil) {
            ("megalooper: '" ++ rp[\device] ++ "' is not in the CoreAudio device "
                "list, though SC lists it. Skipping the channel preflight.").warn;
        } {
            "".postln;
            ("megalooper: device preflight for '" ++ profileName ++ "'").postln;
            ("    " ++ dev[\name] ++ ": " ++ dev[\in] ++ " in, " ++ dev[\out]
                ++ " out, " ++ dev[\rate] ++ " Hz").postln;
            ("    profile wants: " ++ wantIn ++ " in, " ++ wantOut ++ " out"
                ++ (rp[\sampleRate] !? { |r| ", " ++ r ++ " Hz" } ? "")).postln;

            // ---- fatal: the SC<->Live block does not fit -------------------
            if(dev[\out] < wantOut or: { dev[\in] < rp[\numChans] }) {
                "".postln;
                "!!! ================= megalooper DEVICE DEGRADED =================".postln;
                ("!!! '" ++ dev[\name] ++ "' has " ++ dev[\in] ++ " in / " ++ dev[\out]
                    ++ " out, but profile '" ++ profileName ++ "' needs at least "
                    ++ rp[\numChans] ++ " of each for the SC<->Live pairs.").postln;
                "!!! A sub-device has dropped out of the aggregate. Booting would".postln;
                "!!! give you a looper whose every route is silently wrong.".postln;
                rp[\members] !? { |want|
                    "!!! Expected members, and whether CoreAudio can see them now:".postln;
                    want.do { |m|
                        var present = ~audioDeviceFind.(info, m);
                        ("!!!     " ++ if(present.notNil) { "ok      " } { "MISSING " }
                            ++ m ++ present !? { |d|
                                "  (" ++ d[\in] ++ " in, " ++ d[\out] ++ " out, "
                                ++ d[\rate] ++ " Hz)" } ? "").postln;
                    };
                };
                "!!! Fix it in Audio MIDI Setup: re-add the missing member, keep".postln;
                "!!! BlackHole 16ch FIRST, then reboot the aggregate's owner app.".postln;
                "!!! ============================================================".postln;
                Error("megalooper: '" ++ dev[\name] ++ "' is missing channels the '"
                    ++ profileName ++ "' profile needs. Boot aborted — see above.").throw;
            };

            // ---- degrade: only the analysis tap is missing -----------------
            if(dev[\in] < wantIn) {
                "".postln;
                ("!!! megalooper: '" ++ dev[\name] ++ "' has only " ++ dev[\in]
                    ++ " input channels; the clean analysis tap needs " ++ wantIn
                    ++ ".").postln;
                "!!! The instrument's own input has dropped out of the aggregate. The".postln;
                "!!! LOOP is unaffected, so this is not fatal — but onset detection".postln;
                "!!! now falls back to the processed input it records, which fits a".postln;
                "!!! pulse grid worse, so expect more meter mis-detection.".postln;
                "".postln;
                ~analysisChannel = nil;
                s.options.numInputBusChannels = dev[\in].min(wantIn);
                notes.add("analysis tap disabled");
                if(~bassChannel.notNil and: { ~bassChannel >= dev[\in] }) {
                    ("!!! The bass's input (" ++ (~bassChannel + 1) ++ ") is not there either: "
                        ++ "the bass has no strip this time.").postln;
                    ~bassChannel = nil;
                    notes.add("bass input disabled");
                };
            };

            // ---- sample rate, BEFORE the boot rather than after ------------
            // A profile that owns its device outright (setSampleRate: no Live,
            // no aggregate) just switches it; the warning below is for rigs
            // whose rate Live and Audio MIDI Setup own.
            rp[\sampleRate] !? { |want|
                if(dev[\rate] > 0 and: { dev[\rate] != want } and: { rp[\setSampleRate] == true }) {
                    ("    switching " ++ dev[\name] ++ " from " ++ dev[\rate] ++ " to "
                        ++ want ++ " Hz").postln;
                    if(~switchDeviceRate.(dev[\name], want).not) {
                        ("!!! megalooper: could not switch '" ++ dev[\name] ++ "' to " ++ want
                            ++ " Hz. Quit any program using it (a DAW, say), or set it in Audio "
                            ++ "MIDI Setup.").postln;
                        notes.add("could not switch the sample rate");
                    };
                };
                if(dev[\rate] > 0 and: { dev[\rate] != want } and: { rp[\setSampleRate] != true }) {
                    "".postln;
                    ("!!! megalooper: '" ++ dev[\name] ++ "' is at " ++ dev[\rate]
                        ++ " Hz; profile '" ++ profileName ++ "' is built for "
                        ++ want ++ " Hz.").postln;
                    "!!! Set the aggregate AND every member to the same rate in Audio".postln;
                    "!!! MIDI Setup, and match it in Live. A member at a different rate".postln;
                    "!!! is resampled by CoreAudio, which is what makes an aggregate".postln;
                    "!!! crackle, drift, and need a reboot to come back.".postln;
                    notes.add("sample-rate mismatch");
                };
            };

            // ---- members: present, and all at one rate ---------------------
            rp[\members] !? { |want|
                var mismatched = List.new;
                want.do { |m|
                    var found = ~audioDeviceFind.(info, m);
                    if(found.isNil) {
                        ("!!! megalooper: aggregate member '" ++ m ++ "' is NOT present. "
                            "The aggregate still has enough channels, which means the "
                            "remaining members have SHIFTED DOWN to fill the gap — every "
                            "channel above it is now something else.").postln;
                        notes.add("member '" ++ m ++ "' missing");
                    } {
                        if(found[\rate] > 0 and: { found[\rate] != dev[\rate] }) {
                            mismatched.add(m ++ " at " ++ found[\rate] ++ " Hz");
                        };
                    };
                };
                if(mismatched.notEmpty) {
                    ("!!! megalooper: members running at a different rate than the "
                        ++ "aggregate's " ++ dev[\rate] ++ " Hz: "
                        ++ mismatched.join(", ")).postln;
                    "!!! CoreAudio resamples those, and a resampled member is the".postln;
                    "!!! usual cause of an aggregate that works until it does not.".postln;
                    notes.add("member rate mismatch");
                };
            };

            if(notes.isEmpty) {
                "    device ok".postln;
            } {
                ("    PROBLEMS: " ++ notes.join(" · ")).postln;
            };
            "".postln;
        };
    };
    };
    };
    notes.asArray
};

// The input and output devices the audio settings chose: what they are, and
// the one thing that stops a pair, two sample rates (scsynth refuses to start
// on them, as on the system's defaults).
~checkAudioPair = { |rp, info, profileName, notes|
    var inDev = ~audioDeviceFind.(info, rp[\inDevice]), outDev = ~audioDeviceFind.(info, rp[\outDevice]);
    var says = { |d, side| d !? { |x| "  " ++ x[side] ++ (if(side == \in) { " in, " } { " out, " }) ++ x[\rate] ++ " Hz" } ? "" };
    "".postln;
    ("megalooper: '" ++ profileName ++ "' on the devices chosen in the audio settings.").postln;
    ("    in  : " ++ rp[\inDevice] ++ says.(inDev, \in) ++ ", the instrument on input " ++ (rp[\inChannel] + 1)
        ++ (rp[\bassChannel] !? { |b| ", the bass on input " ++ (b + 1) } ? "")).postln;
    ("    out : " ++ rp[\outDevice] ++ says.(outDev, \out) ++ ", the mix on outputs 1 and 2").postln;
    if(inDev.notNil and: { outDev.notNil } and: { inDev[\rate] > 0 } and: { outDev[\rate] > 0 }
        and: { inDev[\rate] != outDev[\rate] }) {
        "".postln;
        "!!! ============== megalooper SAMPLE RATE MISMATCH ==============".postln;
        ("!!! '" ++ inDev[\name] ++ "' records at " ++ inDev[\rate] ++ " Hz but '" ++ outDev[\name]
            ++ "' plays at " ++ outDev[\rate] ++ " Hz.").postln;
        "!!! scsynth does not support that and will REFUSE TO START.".postln;
        ("!!! In Audio MIDI Setup, set both to the same rate (" ++ outDev[\rate] ++ " Hz, say), or").postln;
        ("!!!     python3 tools/coreaudio.py set-rate " ++ inDev[\name].quote ++ " --rate " ++ outDev[\rate]).postln;
        "!!! =============================================================".postln;
        notes.add("input and output sample rates differ");
    };
    if(notes.isEmpty) { "    devices ok".postln };
    "".postln;
};

// ---- What LIVE opened ------------------------------------------------------
// SC cannot ask Live anything, but Live writes its whole audio state to its own
// log every time that state changes, so the newest block is current. It is only
// as fresh as Live's last change, which is why the timestamp is reported too.
~liveAudioState = {
    var path = "ls -t ~/Library/Preferences/Ableton/*/Log.txt 2>/dev/null | head -1"
        .unixCmdGetStdOut.stripWhiteSpace;
    var state = nil;
    if(path.notEmpty and: { File.exists(path) }) {
        // Later lines overwrite earlier ones, so what survives the walk is the
        // most recent state Live logged.
        var grab = { |line, key|
            line.find(key) !? { |i| line.copyToEnd(i + key.size).stripWhiteSpace }
        };
        state = (log: path);
        File.readAllString(path).split($\n).do { |line|
            if(line.contains("Audio In Out:")) {
                grab.(line, "Input Device:") !? { |v|
                    state[\inDevice] = v;
                    state[\at] = line.copyRange(0, 18);
                };
                grab.(line, "Output Device:")   !? { |v| state[\outDevice] = v };
                grab.(line, "Input Channels:")  !? { |v| state[\inChans]  = v.asInteger };
                grab.(line, "Output Channels:") !? { |v| state[\outChans] = v.asInteger };
                grab.(line, "Sample Rate:")     !? { |v| state[\rate]     = v.asInteger };
            };
        };
    };
    state
};

// Live logs a device as `NAME (n In, m Out)`. The names have parentheses of
// their own, so strip from the LAST " (" rather than the first.
~liveDeviceName = { |raw|
    var cut = raw !? { |r| r.findAll(" (") !? { |all| all.last } };
    if(cut.notNil) { raw.copyRange(0, cut - 1) } { raw }
};

// Compare what Live opened against the profile SC is about to boot. Warnings
// only — SC cannot fix Live, and Live may legitimately not be running yet.
~checkLiveAudio = { |profileName|
    var rp = ~routingProfiles[profileName];
    var st = ~liveAudioState.();
    var notes = List.new;
    // A rig with no SC<->Live relationship has nothing here to check. Without
    // this, saSystem reports Live as being "on a different device" — which is
    // true, irrelevant, and alarming on the one profile that is meant to just
    // work. Live may well be open and configured for some other rig. The same
    // goes for any profile that declares live: false.
    if(rp[\device] == \systemDefault or: { rp[\live] == false }) {
        // Nothing to say. The profile does not talk to Live at all.
    } {
    if(st.isNil or: { st[\inDevice].isNil }) {
        "megalooper: no Ableton log found — skipping the Live audio check.".postln;
    } {
        var liveIn  = ~liveDeviceName.(st[\inDevice]);
        var liveOut = ~liveDeviceName.(st[\outDevice]);
        "".postln;
        ("megalooper: Live's audio state, as of " ++ (st[\at] ? "?")).postln;
        ("    in  " ++ st[\inDevice]).postln;
        ("    out " ++ st[\outDevice]).postln;
        ("    " ++ (st[\rate] ? "?") ++ " Hz").postln;

        // The documented footgun, and it looks like it works.
        if(~audioNameMatches.(liveIn, liveOut).not) {
            "".postln;
            "!!! ============== megalooper: LIVE IS SPLIT IN TWO ==============".postln;
            ("!!! Live's INPUT device is  '" ++ liveIn ++ "'").postln;
            ("!!! Live's OUTPUT device is '" ++ liveOut ++ "'").postln;
            "!!! Two different aggregates means BlackHole is open in TWO CLOCK".postln;
            "!!! DOMAINS at once, each drift-correcting against a different".postln;
            "!!! master. It looks like it works — BlackHole is ch 1-16 of both,".postln;
            "!!! so the SC<->Live pairs still line up — and then it crackles,".postln;
            "!!! time-stretches, or goes silent, and only a reboot clears it.".postln;
            "!!! Set Live's Input AND Output to the SAME aggregate.".postln;
            "!!! (docs/routing.md, 'Do not split Live across two of these')".postln;
            "!!! ==========================================================".postln;
            notes.add("Live split across two devices");
        };

        // Both apps must be on the SAME device — that is the whole premise.
        if(~audioNameMatches.(liveIn, rp[\device]).not) {
            "".postln;
            ("!!! megalooper: SC is booting on '" ++ rp[\device]
                ++ "' but Live's input is '" ++ liveIn ++ "'.").postln;
            "!!! The SC<->Live pairs only meet if BOTH apps open the same device.".postln;
            notes.add("Live on a different device than SC");
        };

        rp[\sampleRate] !? { |want|
            if(st[\rate].notNil and: { st[\rate] != want }) {
                ("!!! megalooper: Live is at " ++ st[\rate] ++ " Hz, profile '"
                    ++ profileName ++ "' expects " ++ want ++ " Hz.").postln;
                notes.add("Live sample-rate mismatch");
            };
        };

        if(notes.isEmpty) { "    Live looks consistent with this profile".postln };
        "".postln;
        "  Reminder, because SC cannot see it and it fails silently:".postln;
        "  Live's Input Config / Output Config are PER DEVICE. Switching Live to a".postln;
        "  different aggregate does NOT carry the enabled 17/18 pair across — you".postln;
        "  have to enable it again for the new device, or Live simply cannot see".postln;
        "  the instrument on ch 17 while SC reads it perfectly.".postln;
        "".postln;
    };
    };
    notes.asArray
};

~checkSampleRate = {
    ~rp[\sampleRate] !? { |want|
        if(s.sampleRate.notNil and: { s.sampleRate.round != want }) {
            "".postln;
            ("!!! megalooper: '" ++ ~audioDevice ++ "' is running at "
                ++ s.sampleRate.round ++ " Hz, but profile '" ++ ~routingProfile
                ++ "' expects " ++ want ++ " Hz.").postln;
            if(~rp[\setSampleRate] == true) {
                "!!! The switch before the boot did not hold. Quit any program using".postln;
                "!!! the device, set it in Audio MIDI Setup, and boot again.".postln;
            } {
                "!!! Set the aggregate AND every device inside it to the same rate in".postln;
                "!!! Audio MIDI Setup, and match it in Live — otherwise the SC<->Live".postln;
                "!!! pairs get resampled and the loop drifts against Live.".postln;
            };
            "".postln;
        };
    };
};
)
