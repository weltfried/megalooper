// Megalooper SA: the instrument around the Looper when no Live is running
// (docs/dev/megalooper-sa.md). It owns the server-side frame the Looper plays in:
//
//   [guitar group]   the guitar chain (guitarChain, a MegaSAChain): the
//                    hardware input onto guitarBus, then each effect before
//                    the amp and Bias FX (if there is a plugin), one synth per
//                    device, each working on guitarBus in place. Then the
//                    bass chain (bassChain): the bass's input, if the rig has
//                    one, onto bassBus, and its effects on it
//   [default group]  every Looper synth, untouched: they all live here. After
//                    the Looper's master synth, the loop's chain (loopChain,
//                    attached once the Looper is up): loopBus copied onto
//                    loopFxBus, then the loop's effects on loopFxBus
//   [drum group]     the drums (MegaSADrums): Rhythmic Steps' voices onto
//                    stepsBus and the onset kit's onto onsetBus, then the
//                    drums' chain (drumsChain) on stepsBus, then their
//                    effects, onto stepsOutBus and onsetOutBus; then the
//                    note sequencer's voices (the Wave synth, wave) onto
//                    synthBus and the synth's chain (synthChain) on it
//   [mixer group]    one strip per source (the guitar, the loop, the drums,
//                    the onset kit and the synth), each also onto its own stem bus,
//                    then the master to the interface and to recordBus
//   [record group]   the session recorder's synths, which record recordBus
//                    and the stems (stemSpecs)
//
// The guitar group runs BEFORE the default group, so the Looper records what
// the chain made in the same block. The bass chain is there for the same
// reason, though nothing records it yet: the Looper records the guitar only. The loop's chain runs right after the
// Looper's master synth, in a group of its own inside the default group, so
// the loop-chain recorder, which the Looper adds to the tail of the default
// group later, hears the processed loop as it did from Live. The drum group runs after the default group, so the drums' drift
// probe reads the loop's phase as the engine left it in that block, and
// before the mixer, so the strips take the drums in the same block. The mixer
// runs AFTER the default group, and the record group after the mixer. Nothing
// puts the drums on guitarBus or loopFxBus: the Looper never records them, as
// Live's return of the loop never held its drums either.
//
// The Looper's audio needs no change for any of it: its inChannel,
// returnChannel and sessionChannel are SoundIn channels that land on the
// private busses here (soundInChannel below), and its outChannel is loopBus.
// scripts/setup-sa.scd sets all four. What it sent Live, the drums take
// instead (attachLooper, MegaSADrums.attach): the drums' transport
// (MegaSATransport) becomes its MIDI port, so its own Starts, Stops and
// bar-line waits drive the drums as they drove Live's; the drums become its
// onsetNoteSink, so its onset notes play the onset kit; and its
// startsRelocate goes false, since a Start relocates nothing here.
//
// Like the Looper, it does not survive Cmd-period: nothing re-creates its
// nodes. Re-run boot.scd.
MegaSA {
    var <server, <guitarIn, <hwOut, <pluginPath, <bankPath;
    // The bass's hardware input (a SoundIn channel), or nil on a rig with
    // none: its chain is then built all the same, on silence, so a sound's
    // bass devices are kept, but there is no bass strip.
    var <bassIn;
    // This Mac's plugins as the last scan found them (MegaSAPlugins' entries),
    // or nil: what a plugin's device is looked up in (prPluginTarget), and
    // what insertPlugin adds from. Set anew after a scan.
    var <>catalog;
    // The guitar chain's plugin devices that have not answered their open
    // yet: the guitar is held until none is left.
    var openings;
    // The folder a marker file is written into while a plugin opens, or nil
    // for none. A plugin is hosted in the server itself, so one that crashes
    // while it opens takes the server down, at every boot again. Its marker
    // is then still there at the next boot, which leaves that plugin closed,
    // says so, and removes the marker: the boot after tries it once more.
    var <>markerDir;
    var <guitarBus, <bassBus, <loopBus, <loopFxBus, <masterBus, <recordBus;
    // What the note sequencer's instrument plays onto, stereo, and its chain
    // works on before the synth's strip.
    var <synthBus;
    // The drums' busses, stereo: what their voices play onto (stepsBus,
    // onsetBus) and what their effects hand the two strips (stepsOutBus,
    // onsetOutBus).
    var <stepsBus, <stepsOutBus, <onsetBus, <onsetOutBus;
    // Each strip's signal after its fader, stereo, by strip (\guitar, \loop,
    // \drums, \onsetKit, and \bass on a rig with a bass input): the set's stems, which the session recorder records
    // beside the master (stemSpecs). Only its strip writes one, and they sum
    // to masterBus.
    var <stemBusses;
    var <guitarGroup, <mixerGroup, <drumGroup, <recordGroup;
    // The guitar's chain and the loop's (MegaSAChain): their devices in order,
    // each with its switch and its settings, and once built their synths. The
    // guitar's: the Shifter, the Delay, the Auto Filter and PitchLoop89, then
    // the plugin (\plugin1, Bias FX) if there is one. The loop's: the Echo,
    // the Saturator and Redux. Each default device's id is its effect's key
    // (MegaSAFx.keys). They start as the Live set left them: every effect
    // off, every setting at the set's value; the plugin on.
    var <guitarChain, <loopChain, <drumsChain, <bassChain, <synthChain;
    // The Wave synth (MegaSAWave): its tables, its settings, its notes.
    var <wave;
    // What plays the note sequencer: nil for the Wave synth, else the
    // catalog key of an instrument plugin (setInstrument), hosted by
    // `instrument` (a MegaSAPlugin) in instrumentSynth, at the head of the
    // drums' synth group, onto synthBus.
    var <instrumentKey, <instrument, instrumentSynth;
    var <strips, <masterSynth;
    // The chains' edits (insertDevice and the rest, below): removed plugins
    // parked in limboGroup, a paused group made at the first such removal,
    // still open, for undo to bring back (oldest first in limbo; a removed
    // built-in is freed, and undo builds it anew); the undo
    // and redo lists of the edits; the next number each type's ids go on
    // from, never lowered, so a removed delay2 is never reborn as another
    // device its footswitch would then drive; and when the last edit's
    // bundles have all landed (edits never overlap: each starts after the
    // one before, so the places they send are the places there are).
    var <limboGroup, limbo, undoList, redoList, <nextIds, editsBusyUntil = -inf;
    // Each chain's delay (frames) as last said with \latency (track, seconds).
    var lastLatency;
    // Rhythmic Steps and the onset kit (MegaSADrums). Made with this object,
    // so their model (the patterns, PC 17's switch) is there at once; their
    // server side goes up in prBuild, after the groups.
    var <drums;
    // Amplitude per strip, plus \master. Mutes are per strip only: muting the
    // master is the interface's volume knob.
    var <levels, <mutes;
    // One beat of the loop's tempo, for the echo and the auto filter's LFO; set
    // by every analysis. And the tempo itself in BPM, nil until a reading has
    // given one: what each plugin is told, also once it opens or a bank job
    // ends (a plugin busy or not yet open misses a tempo sent meanwhile).
    var <beatDur = 0.6, <tempo;
    var <ready = false;
    // init's routine (prBuild). free stops it if it has not finished, so a
    // MegaSA freed early builds nothing afterwards.
    var builder;
    // The plugin's state is being read or written, one job at a time: those
    // asked for meanwhile wait in pendingBank, in order. A save is never
    // dropped; a load replaces one still waiting, so a burst of recalls ends
    // on the last. The guitar strip is held (\bank) while a job runs.
    var bankBusy = false, pendingBank;
    // What the sound MegaSA was built from or last recalled held beyond the
    // devices (MegaSASound's unknown fields and tracks), for the next sound
    // written from the chains; and what Keep's mark compares against
    // (MegaSASound.contentString of the sound last kept or read).
    var soundExtras, <>keptContent;
    // The name of the sound the chains were built from, last recalled or
    // last saved as: what a session's header calls them.
    var <soundName;
    // Whether the plugin's state may be written now, asked at every save: a
    // function. Writing it suspends the plugin, and the guitar's DI would be
    // heard, so setup-sa.scd answers true only while the loop is stopped. With
    // none set, yes.
    var <>statesAllowed;
    // Why a strip is held silent apart from the player's own mute (mutes):
    // strip -> the IdentitySet of its reasons, \opening (the guitar's plugin
    // is opening, and until it is its device passes the DI through: a blast at
    // full scale), \bank (its bank is being read or written, which suspends
    // it) or \state (it opened, but its saved sound did not load, so it would
    // play its default patch, not yours). The strip is muted while the
    // player's mute is on or it has a reason. Nothing but the player touches
    // the player's mute; \state is the one reason the player lets go, by
    // unmuting the strip.
    var holds;
    // False once freed: what comes back afterwards (a plugin's open, a bank
    // job) finds nothing to act on.
    var <alive = true;
    // The routines that open the guitar's plugin after the build and run its
    // bank jobs; free stops them.
    var opener, bankRoutine;
    // How the guitar's plugin is made, given (synth, id, path), the synth
    // being its device's: MegaSAPlugin's own constructor unless something
    // else is set before the build. The
    // tests and the offline renders hand in a plugin of their own here, one
    // that opens into a score or has failed, instead of a VSTPluginController
    // waiting on a server that never answers.
    var <>pluginMaker;

    // pluginPath: the guitar's plugin (Bias FX), or nil for no plugin.
    // bankPath: a bank to load into it once it is open, or nil.
    // sound: the chains to build (a MegaSASound: the kept sound), or nil for
    // megalooper's default chains. With a sound the chains are its devices,
    // the plugin is hosted in its guitar chain's plugin device (none there,
    // none hosted) and opens with that device's state.
    // bassIn: the bass's hardware input, or nil for none.
    *new { |server, guitarIn = 0, hwOut = 0, pluginPath, bankPath, sound, catalog, bassIn|
        ^super.newCopyArgs(server, guitarIn, hwOut, pluginPath, bankPath).init(sound, catalog, bassIn)
    }

    // The strips in mixer order, each with the bus it reads: the drums' and
    // the onset kit's take their effects' output. The bass's, after the
    // guitar's, only on a rig with a bass input.
    stripBusses {
        ^[\guitar, guitarBus] ++ (if(bassIn.notNil) { [\bass, bassBus] } { [] })
            ++ [\loop, loopFxBus, \drums, stepsOutBus, \onsetKit, onsetOutBus, \synth, synthBus]
    }

    // The Looper reads every input with SoundIn, and SoundIn.ar(ch) is
    // In.ar(NumOutputBuses + ch): a "channel" past the hardware inputs reads a
    // private bus. This is the channel that lands on `bus`.
    soundInChannel { |bus| ^bus.index - server.options.numOutputBusChannels }
    // The Looper's recorded input: the guitar chain.
    looperInChannel { ^this.soundInChannel(guitarBus) }
    // Its loop-chaining return: the loop after its effects.
    returnInChannel { ^this.soundInChannel(loopFxBus) }
    // Its session recorder's "master": the mix as it leaves for the interface.
    recordInChannel { ^this.soundInChannel(recordBus) }

    // A strip's stem bus (stemBusses), or nil.
    stemBus { |key| ^stemBusses !? { |t| t[key] } }

    // What the session recorder records beside the master and the dry tap
    // (LooperSessionRecorder.stems; setup-sa.scd hands it over): every strip
    // after its fader, as heard, as (role:, channel:, numChannels:), the
    // channel being the SoundIn channel that lands on the strip's stem bus.
    // Every stem is its strip's two sides, the guitar's too: a stereo device
    // or plugin on its chain is recorded as it plays (today's chain is dual
    // mono, so its sides hold the same). The onset kit's strip is the onset
    // stem. A strip whose bus did not allocate has no stem, nor has the bass
    // on a rig without its input.
    stemSpecs {
        ^[[\guitar, \guitar, 2], [\bass, \bass, 2], [\loop, \loop, 2], [\drums, \drums, 2], [\onset, \onsetKit, 2],
            [\synth, \synth, 2]].collect { |row|
            var bus = this.stemBus(row[1]);
            if(bus.notNil and: { bus.index.notNil }) {
                (role: row[0], channel: this.soundInChannel(bus), numChannels: row[2])
            }
        }.reject(_.isNil)
    }

    init { |sound, plugins, bass|
        catalog = plugins;
        bassIn = bass;
        // The drums' two strips start where Live's faders were: the drums
        // group at -10.6 dB, the One Hit Kit's track at -15.7 dB.
        // The synth's at -6 dB.
        levels = (guitar: 1, loop: 1, drums: 0.2951209247, onsetKit: 0.1640589684, synth: 0.5011872336, master: 1);
        // Every strip starts with the player's mute off. The guitar's is held
        // while its plugin opens (holds, above), and let go once the plugin
        // has answered: open, or failed, in which case dry is better than
        // nothing.
        mutes = (guitar: false, loop: false, drums: false, onsetKit: false, synth: false);
        // The bass has a strip only with an input to play it. A plugin
        // opening on its chain holds nothing: until it is open its device
        // passes the bass through, as the drums' and the loop's do.
        if(bassIn.notNil) { levels.put(\bass, 1); mutes.put(\bass, false) };
        // Without VSTPlugin there is no plugin to host: the guitar plays its
        // built-in effects without it, and the post window says why.
        if(pluginPath.notNil and: { \VSTPlugin.asClass.isNil }) {
            ("MegaSA: VSTPlugin is not installed, so " ++ PathName(pluginPath).fileNameWithoutExtension
                ++ " cannot be hosted; the instrument plays without it.").warn;
            pluginPath = nil;
        };
        holds = IdentityDictionary.new;
        if(pluginPath.notNil and: { sound.isNil or: { sound.devices(\guitar).any { |d| d[\type] == \plugin } } }) {
            holds.put(\guitar, IdentitySet[\opening]) };
        pendingBank = List.new;
        strips = IdentityDictionary.new;
        limbo = List.new;
        undoList = List.new;
        redoList = List.new;
        // A default device's id is its type's key, its first; further ones
        // go on from 2. A type in no chain to begin with (MegaSAFx.extraKeys)
        // has its key free: its first device takes it. Plugins are plugin1,
        // plugin2, ...
        nextIds = IdentityDictionary.new;
        MegaSAFx.keys.do { |k| nextIds.put(k, 2) };
        MegaSAFx.extraKeys.do { |k| nextIds.put(k, 1) };
        nextIds.put(\plugin, if(pluginPath.notNil) { 2 } { 1 });
        sound !? { |x| x.nextIds.keysValuesDo { |k, v| nextIds.put(k, max(nextIds[k] ? 1, v)) } };
        // The drums' model needs no server: the patterns, the kit folder and
        // PC 17's switch exist before anything is built, so setup-sa.scd and
        // the Drums tab can talk to it from here on.
        drums = MegaSADrums(this);
        // Its settings exist at once too; its tables go up in prBuild.
        wave = MegaSAWave(server);
        drums.noteVoice = { |rec, where| wave.voiceMsgs(rec, where) };
        // Busses are allocated in the language, so they exist the moment this
        // returns: setup-sa.scd points the Looper at them before the Looper's
        // own synths start.
        guitarBus = Bus.audio(server, 2);
        loopBus   = Bus.audio(server, 2);
        loopFxBus = Bus.audio(server, 2);
        masterBus = Bus.audio(server, 2);
        recordBus = Bus.audio(server, 2);
        stepsBus    = Bus.audio(server, 2);
        stepsOutBus = Bus.audio(server, 2);
        onsetBus    = Bus.audio(server, 2);
        onsetOutBus = Bus.audio(server, 2);
        // After the others, so theirs stay where they were before the bass.
        bassBus = Bus.audio(server, 2);
        synthBus = Bus.audio(server, 2);
        stemBusses = IdentityDictionary.new;
        ([\guitar, \loop, \drums, \onsetKit] ++ (if(bassIn.notNil) { [\bass] } { [] }) ++ [\synth])
            .do { |k| stemBusses.put(k, Bus.audio(server, 2)) };
        this.prMakeChains(sound);
        // The guitar is held while a plugin on its chain opens: only if one
        // will (prPluginTarget), whichever plugin that is.
        if(guitarChain.devices.any { |d| d.isPlugin and: { this.prPluginTarget(d).notNil } }) {
            holds.put(\guitar, IdentitySet[\opening]) } { holds.removeAt(\guitar) };
        // Cmd-period frees every node and nothing builds them again: it says
        // so (cmdPeriod, below) instead of leaving SA silent with no word.
        CmdPeriod.add(this);
        builder = Routine { this.prBuild }.play;
    }

    // The four chains, in the model only: the guitar's from the hardware
    // input, the loop's from the Looper's output, the drums' on the bus
    // Rhythmic Steps' voices play onto, the bass's from its input (with none,
    // a source that feeds nothing: its effects work on silence). With no
    // sound they are as the Live set had them: the guitar's four effects,
    // then its plugin, dual mono 1->1 as the Live set hosts Bias FX (no
    // plugin, no device), the loop's three effects, and nothing on the drums
    // or the bass. With a sound they are the
    // sound's devices, in its order, with its switches, settings and names.
    prMakeChains { |sound|
        guitarChain = MegaSAChain(\guitar, guitarBus, \megaSAChainIn, [\in, guitarIn]);
        loopChain = MegaSAChain(\loop, loopFxBus, \megaSAChainCopy, [\in, loopBus.index]);
        drumsChain = MegaSAChain(\drums, stepsBus, \megaSAChainOn, []);
        bassChain = if(bassIn.notNil) { MegaSAChain(\bass, bassBus, \megaSAChainIn, [\in, bassIn]) }
            { MegaSAChain(\bass, bassBus, \megaSAChainOn, []) };
        synthChain = MegaSAChain(\synth, synthBus, \megaSAChainOn, []);
        if(sound.isNil) {
            MegaSAFx.guitarKeys.do { |k| guitarChain.add(MegaSADevice(k, k)) };
            pluginPath !? { |p|
                guitarChain.add(MegaSADevice.plugin(\plugin1, [1, 1], PathName(p).fileNameWithoutExtension, true));
            };
            MegaSAFx.loopKeys.do { |k| loopChain.add(MegaSADevice(k, k)) };
        } {
            this.chains.do { |c| sound.devices(c.track).do { |spec| c.add(this.prDeviceFrom(spec, sound)) } };
            soundExtras = this.prExtrasFrom(sound);
            soundName = sound.name;
        };
        lastLatency = IdentityDictionary.new;
        this.chains.do { |c| lastLatency.put(c.track, c.latency(this.sampleRate)) };
    }

    // A chain's delay changed (an edit, a plugin's report): \latency (track,
    // seconds), once per change, for each chain whose delay is another now.
    prLatencyCheck {
        lastLatency !? { |last|
            this.chains.do { |c|
                var frames = c.latency(this.sampleRate);
                if(frames != last[c.track]) {
                    last.put(c.track, frames);
                    this.changed(\latency, c.track, frames / this.sampleRate);
                };
            };
        };
    }

    // What MegaSA hears from its plugins (it is their dependant): a latency
    // reported.
    update { |obj, what ... args| if(what == \latency) { this.prLatencyCheck } }

    // The server side, from init's routine: the SynthDefs, the groups in their
    // order, the guitar chain, the drums, the strips and the master, then
    // ready. A test steps it on a stub server, whose sync answers at once.
    prBuild {
        this.class.loadSynthDefs;
        server.sync;
        guitarGroup = Group.before(server.defaultGroup);
        mixerGroup  = Group.after(server.defaultGroup);
        drumGroup   = Group.before(mixerGroup);
        recordGroup = Group.after(mixerGroup);
        guitarChain.build(guitarGroup, \addToHead, beatDur);
        // After the guitar's, in the same group: before the Looper too.
        bassChain.build(guitarGroup, \addToTail, beatDur);
        // The plugin is made now, in its device's synth, so it is there to
        // ask from the start; it is opened after the build (prOpenPlugin),
        // because its probe can hold the build for seconds on a first boot,
        // and ready must not wait. The bass chain's open with the guitar's.
        this.prMakePlugins(guitarChain);
        this.prMakePlugins(bassChain);
        this.prBuildDrums;
        this.prBuildDrumsChain;
        this.prBuildSynth;
        this.stripBusses.pairsDo { |key, bus|
            strips.put(key, Synth.tail(mixerGroup, \megaSAStrip, [
                \in, bus.index, \out, masterBus.index,
                \amp, levels[key], \mute, this.muted(key).binaryValue
            ] ++ this.prStemArgs(key)));
        };
        masterSynth = Synth.tail(mixerGroup, \megaSAMaster, [
            \in, masterBus.index, \out, hwOut, \rec, recordBus.index,
            \amp, levels[\master]
        ]);
        server.sync;
        ready = true;
        "MegaSA ready.".postln;
        if(this.pluginDevices.notEmpty) {
            opener = Routine { this.pluginDevices.do { |d| this.prOpenPlugin(d) } }.play };
    }

    // The plugins of a chain's plugin devices, made in their synths: each for
    // what its sound names (prPluginTarget), or left without one. The
    // guitar's are opened after the build, and the guitar is held until each
    // has answered; with none to wait for, it is let go here.
    prMakePlugins { |chain|
        chain.devices.do { |d|
            var target;
            if(d.isPlugin and: { d.plugin.isNil }) {
                target = this.prPluginTarget(d);
                case
                { target.isNil } { this.prPluginMissing(d) }
                { this.prTakeMarker(target) } {
                    ("MegaSA: " ++ d.name ++ " was being opened when megalooper last stopped, so it may have crashed it. "
                        ++ "It stays closed this time and its chain plays without it; its sound is kept. "
                        ++ "The next boot tries it again. To leave it out for good, remove it and Start with this.").warn;
                }
                { this.prMakePlugin(d, target) };
                if((chain === guitarChain) and: { d.plugin.notNil }) {
                    openings = (openings ?? { IdentitySet.new }).add(d) };
            };
        };
        if((chain === guitarChain) and: { (openings ? []).isEmpty }) { this.unhold(\guitar, \opening) };
    }

    // The marker of the plugin an open names (its key or path), or nil.
    prMarkerPath { |key|
        ^markerDir !? { |dir| dir +/+ key.asString.collect { |c| if(c.isAlphaNum) { c } { $_ } } ++ ".opening" }
    }

    // Written before a plugin's open, removed once it has answered.
    prMark { |device, flag|
        var file = device !? { |d| d.plugin } !? { |p| p.path } !? { |key| this.prMarkerPath(key) };
        file !? {
            if(flag) {
                File.mkdir(markerDir);
                File.use(file, "w", { |f| f.write(Date.getDate.stamp) });
            } { if(File.exists(file)) { File.delete(file) } };
        };
    }

    // Whether a marker was left for `key`: an open that never answered. It is
    // removed here, so it keeps its plugin closed for one boot.
    prTakeMarker { |key|
        var file = this.prMarkerPath(key);
        ^if(file.notNil and: { File.exists(file) }) { File.delete(file); true } { false }
    }

    // A plugin's device has answered its open, or cannot be opened: the
    // guitar is let go once none of its chain's is left to answer.
    prOpenAnswered { |device|
        this.prMark(device, false);
        openings !? { |set| set.remove(device) };
        if((openings ? []).isEmpty) { this.unhold(\guitar, \opening) };
    }

    // The guitar's plugin, made through pluginMaker (MegaSAPlugin's own
    // constructor unless something else was set) in its device's synth. One
    // that cannot be made costs the plugin only: its device passes the
    // guitar through, and the guitar is let go.
    prMakePlugin { |device, path|
        device.plugin = try {
            (pluginMaker ? { |synth, id, pth| MegaSAPlugin(synth, id, pth) }).value(device.node, \plugin, path)
        } { |err|
            ("MegaSA: " ++ PathName(path).fileNameWithoutExtension ++ " could not be made ("
                ++ err.errorString ++ "); the instrument plays without it.").warn;
            nil
        };
        device.plugin !? { |p| p.addDependant(this) };
    }

    // What a plugin's device opens, or nil:
    //   - the catalog's entry for the plugin its sound names, by its key: the
    //     server, which has read the catalog, then needs no probe, and a
    //     plugin that moved is still found;
    //   - the rig's own plugin, by its path, for a sound that names none (one
    //     from before the chains) and while nothing was scanned yet: as it
    //     was before the catalog;
    //   - nil for a plugin this Mac has not, or one that would need
    //     VSTPlugin's bridge.
    prPluginTarget { |device|
        var named = device.fileExtras !? { |x| x[\plugin] };
        var entry = named !? { MegaSAPlugins.find(catalog ? [], named) };
        ^case
        { entry.notNil } { if(entry[\bridged] == true) { nil } { entry[\key] } }
        { named.isNil or: { (catalog ? []).isEmpty } } { pluginPath }
        { nil }
    }

    // A plugin's device with nothing to open: it stays in its chain and
    // passes it through, and what its sound says of it, its state included,
    // is written back as it came.
    prPluginMissing { |device|
        var named = device.fileExtras !? { |x| x[\plugin] };
        var entry = named !? { MegaSAPlugins.find(catalog ? [], named) };
        case
        { \VSTPlugin.asClass.isNil } { }
        { entry.notNil } {
            ("MegaSA: " ++ device.name ++ " is built for another processor and would need VSTPlugin's bridge, "
                ++ "which megalooper does not use yet: the chain plays without it, and its sound is kept.").warn;
        }
        { named.notNil } {
            ("MegaSA: " ++ device.name ++ " is not among this Mac's plugins (scan again if it was installed since): "
                ++ "the chain plays without it, and its sound is kept.").warn;
        };
    }

    // Every device that hosts a plugin now, on either chain.
    pluginDevices { ^this.devices.select { |d| d.plugin.notNil } }

    // The guitar's plugin (MegaSAPlugin, in \plugin1's synth), or nil.
    guitarPlugin { ^this.prPluginDevice !? { |d| d.plugin } }

    // The guitar chain's device that hosts the plugin, or nil (none, or it
    // was removed: parked, it is in limbo).
    prPluginDevice { ^guitarChain !? { |c| c.devices.detect { |d| d.plugin.notNil } } }

    // What the plugin opens with: its device's state, from the sound MegaSA
    // was built from, else the bank MegaSA was given, else nothing.
    prOpenState { |device|
        var dev = device ? this.prPluginDevice, state = dev !? { |d| d.state };
        ^if(state.notNil and: { state[\path].notNil }) { (kind: state[\kind], path: state[\path]) } {
            // The bank of before the chains is the guitar's first plugin's.
            if(dev === this.prPluginDevice) { bankPath }
        }
    }

    // Open the guitar's plugin and load its bank (MegaSAPlugin.open), on a
    // routine of its own after the build. The guitar stays held until it
    // answers: open, failed, or nothing within MegaSAPlugin's timeout.
    prOpenPlugin { |device|
        var dev = device ? this.prPluginDevice, plug = dev !? { |d| d.plugin };
        if(plug.isNil or: { alive.not }) { ^this };
        this.prMark(dev, true);
        try {
            plug.open(this.prOpenState(dev), { |p, ok| if(alive) { this.prPluginOpened(p, ok, dev) } });
        } { |err|
            ("MegaSA: " ++ plug.name ++ " did not open (" ++ err.errorString
                ++ "); its chain plays without it.").warn;
            this.prOpenAnswered(dev);
        };
    }

    prPluginOpened { |plug, ok, device|
        var dev = device ? this.prPluginDevice;
        tempo !? { |t| plug.setTempo(t) };
        plug.held !? { |why| ("MegaSA: " ++ plug.name ++ " opened, but " ++ why ++ "; the instrument plays without it.").warn };
        case
        { ok } {
            ("MegaSA: " ++ plug.name ++ " open in " ++ (plug.loadSec ? 0).round(0.1)
                ++ " s" ++ (plug.bank !? { |b| ", its sound from " ++ PathName(b).fileName } ? "")
                ++ ".").postln;
        }
        // Open, but the bank did not go in: it would play its default patch,
        // not your sound, so the guitar stays held until you unmute it.
        { plug.state == \open } {
            ("MegaSA: " ++ plug.name ++ " opened, but its sound ("
                ++ (this.prOpenState(dev) !? { |x| PathName(if(x.isString) { x } { x[\path] }).fileName } ? "its bank")
                ++ ") did not load" ++ if(guitarChain.devices.includes(dev)) {
                    "; the instrument is held. Unmute it to play the plugin's own default sound." } {
                    ": it plays its own default sound." }).warn;
            if(guitarChain.devices.includes(dev)) { this.hold(\guitar, \state) };
        };
        this.prOpenAnswered(dev);
    }

    // The drums' server side in the drum group (MegaSADrums.build: their
    // control busses, voice groups and effects). Whatever goes wrong costs the
    // drums only: ready must still be reached, or setup-sa.scd would wait for
    // it for ever. build posts its own failures; this catches what gets past.
    prBuildDrums {
        try {
            drums.build(drumGroup, stepsBus, stepsOutBus, onsetBus, onsetOutBus, synthBus);
        } { |err|
            ("MegaSA: the drums were not built (" ++ err.errorString
                ++ "); SA plays on without them.").warn;
        };
    }

    // The drums' chain, on stepsBus: after the voices, which have written the
    // bus by then, and right before the drums' effects synth, which reads it.
    // So a device on it is heard before the drums' reverb, and the onset kit,
    // on a bus of its own, does not pass through it. With no drums built it
    // goes to the drum group's tail and works on silence: every chain is
    // built then all the same, and a sound can be recalled. Its plugins are
    // made here and opened with the guitar's; nothing is held for them.
    prBuildDrumsChain {
        var fx = drums !? { |d| d.fxSynth };
        if(fx.notNil) { drumsChain.build(fx, \addBefore, beatDur) } { drumsChain.build(drumGroup, \addToTail, beatDur) };
        this.prMakePlugins(drumsChain);
        // A device switched on there (a delay's repeats) may sound with no
        // hit, so the drums' reverb stays awake for it (MegaSADrums.prRestFx).
        // Read at each pump: a sound may bring another chain.
        drums !? { |d| d.stepsHeld = { drumsChain.notNil and: { drumsChain.devices.any(_.on) } } };
    }

    // The Wave synth's tables, and the synth's chain at the drum group's
    // tail: after the sequencer's voices, which have written synthBus by
    // then, and before the mixer. Its plugins are made here and opened with
    // the guitar's. A failure costs the synth only.
    prBuildSynth {
        try { wave.build } { |err|
            ("MegaSA: the Wave synth's tables were not made (" ++ err.errorString ++ "); the synth stays silent.").warn;
        };
        synthChain.build(drumGroup, \addToTail, beatDur);
        this.prMakePlugins(synthChain);
    }

    // The second half of the setup, once the Looper is up: the loop's chain
    // right after its master synth, in a group of its own at the tail of the
    // default group at this moment, before anything else the Looper adds
    // there (a chain built anywhere else would leave the loop-chain recorder,
    // which reads loopFxBus from that group's tail, recording silence), its
    // session recorder moved after the mixer, and the drums attached: they
    // become its MIDI port and its onset-note sink, and follow its break,
    // readings, reverse and state (MegaSADrums.attach). A chain built for an
    // earlier Looper goes first; the new one starts from the devices as they
    // stand, once the edits on their way have landed: the bundles they sent
    // name the synths this frees. Called from a Routine.
    attachLooper { |looper|
        if(editsBusyUntil > thisThread.seconds) { ((editsBusyUntil - thisThread.seconds) + 0.01).wait };
        // The loop's phase, to every chain, for a device on the beat (the
        // Slicer): the loop's bar 1 beat 1 is the drums' too.
        looper.phaseBus !? { |b| this.chains.do { |c| c.setPhaseBus(b.index) } };
        loopChain.build(server.defaultGroup, \addToTail, beatDur);
        looper.sessionRec.target = recordGroup;
        drums !? { |d| d.attach(looper) };
        server.sync;
        // The loop chain's plugins, once their synths are there. Nothing is
        // held for them: until one is open its device passes the loop through.
        this.prMakePlugins(loopChain);
        loopChain.devices.do { |d| if(d.plugin.notNil and: { d.plugin.state == \closed }) { this.prOpenPlugin(d) } };
    }

    // A strip's stem bus as its starting \stem, or nothing: the def's default,
    // 0, writes no stem at all. Only a positive index goes in, so no strip
    // ever writes a bus it was not given, let alone a negative one.
    prStemArgs { |key|
        var index = this.stemBus(key) !? { |b| b.index };
        ^if(index.isNumber and: { index > 0 }) { [\stem, index] } { [] }
    }

    *loadSynthDefs {
        // The chains: what feeds each (the hardware input, the Looper's
        // output), a device per built-in effect, a pass-through for a type
        // this build does not know (MegaSAFx), and, with VSTPlugin installed,
        // a device per plugin layout (MegaSAPlugin); without it SA hosts no
        // plugin.
        MegaSAFx.addDeviceDefs;
        MegaSAPlugin.addSynthDefs;
        MegaSAPlugin.addInstrumentDef;
        // One mixer strip: level and mute onto the master bus, lagged so a
        // fader move or a mute never clicks, and the same signal onto its
        // stem bus, `stem`, for the session recorder: the strip as it reaches
        // the master. XOut, not Out: at a crossfade of 0 it writes nothing at
        // all, and the crossfade is 0 for a strip given no stem bus (`stem`
        // 0, the interface's first output, which is never one), so such a
        // strip leaves every bus but the master's as it was. At 1 it writes
        // the strip alone onto its bus, which nothing else writes.
        SynthDef(\megaSAStrip, { |in, out, amp = 1, mute = 0, stem = 0|
            var sig = In.ar(in, 2) * Lag.kr(amp * (1 - mute), 0.02);
            Out.ar(out, sig);
            XOut.ar(stem, stem > 0, sig);
        }).add;
        // The master: level, then a hard clip as the last safety before the
        // interface. Not Limiter: its lookahead delays the signal, and the
        // guitar's monitoring passes through here. The same signal goes to
        // `rec` for the session recorder.
        SynthDef(\megaSAMaster, { |in, out = 0, rec, amp = 1|
            var sig = (In.ar(in, 2) * Lag.kr(amp, 0.02)).clip2(0.98);
            Out.ar(out, sig);
            Out.ar(rec, sig);
        }).add;
        // The drums' voices, their drift probe and their effects, and the
        // Wave synth's voice.
        MegaSADrums.loadSynthDefs;
        MegaSAWave.loadSynthDefs;
    }

    // In a Routine. A build that stopped (an error, posted above) would
    // otherwise keep the boot waiting for ever, with nothing on screen.
    waitForReady { |timeout = 60|
        var waited = 0;
        while { ready.not and: { alive } and: { waited < timeout } } { 0.05.wait; waited = waited + 0.05 };
        if(ready.not) {
            ("MegaSA: not ready after " ++ timeout ++ " s (its build stopped; see the post window above). "
                ++ "The boot goes on without it.").warn;
        };
        ^this
    }

    // Cmd-period has freed every node, SA's among them, and nothing makes them
    // again: say so, and stop answering ready.
    cmdPeriod {
        if(alive and: { ready }) {
            ready = false;
            "MegaSA: Cmd-period freed every node, so SA is silent; run boot.scd again to rebuild it.".warn;
        };
    }

    // key: a strip (\guitar, \bass, \loop, \drums, \onsetKit) or \master. Amplitude,
    // not dB.
    level { |key| ^levels[key] }

    setLevel { |key, amp|
        if(levels.includesKey(key).not) {
            ("MegaSA: no strip " ++ key ++ "; strips are "
                ++ levels.keys.asArray.sort.join(", ")).warn;
        } {
            levels.put(key, amp.max(0));
            this.prNode(key) !? { |n| n.set(\amp, levels[key]) };
            this.changed(\level, key, levels[key]);
        };
    }

    mute { |key| ^mutes[key] }

    setMute { |key, flag|
        var held;
        if(mutes.includesKey(key).not) {
            ("MegaSA: no strip " ++ key ++ " to mute; strips are "
                ++ mutes.keys.asArray.sort.join(", ")).warn;
        } {
            mutes.put(key, flag == true);
            // Unmuting a strip held because its plugin's sound did not load is
            // the player's choice to hear the plugin as it is.
            held = holds !? { |h| h[key] };
            if((flag != true) and: { held.notNil } and: { held.includes(\state) }) {
                held.remove(\state);
                this.changed(\hold, key, this.held(key));
            };
            this.prSendMute(key);
            this.changed(\mute, key, mutes[key]);
        };
    }

    prNode { |key| ^if(key == \master) { masterSynth } { strips[key] } }

    // ---- Holds -----------------------------------------------------------
    // A strip's reasons for being held (holds, above), sorted.
    held { |key| ^(holds !? { |h| h[key] } ? []).asArray.sort }

    // What the strip is told: muted while the player's mute is on or it is
    // held. The mute buttons and the MIDI lights show this.
    muted { |key| ^(mutes !? { |m| m[key] == true } ? false) or: { this.held(key).notEmpty } }

    // Hold a strip for `reason`, or let it go; each says \hold (key, reasons)
    // when it changes something.
    hold { |key, reason|
        var set;
        holds = holds ?? { IdentityDictionary.new };
        set = holds[key] ?? { holds.put(key, IdentitySet.new); holds[key] };
        if(set.includes(reason).not) {
            set.add(reason);
            this.prSendMute(key);
            this.changed(\hold, key, this.held(key));
        };
    }

    unhold { |key, reason|
        var set = holds !? { |h| h[key] };
        if(set.notNil and: { set.includes(reason) }) {
            set.remove(reason);
            this.prSendMute(key);
            this.changed(\hold, key, this.held(key));
        };
    }

    prSendMute { |key|
        strips !? { |s| s[key] !? { |n| n.set(\mute, this.muted(key).binaryValue) } };
    }

    // ---- The synth: presets and Keep ---------------------------------------
    // The note sequencer's pattern (drums.notes) and the Wave synth's
    // settings together, as one file (MegaSASynthFile): the Synth view's
    // presets, <dir>/<slug>.json, and what Keep writes for the next boot. The
    // sequencer's switch and the Synth strip are not in it.

    *defaultKeptSynthPath { ^MegaFiles.userRoot +/+ "sa" +/+ "kept-synth" +/+ "synth.json" }

    // ---- The instrument ------------------------------------------------------
    // The Wave synth (key nil) or an instrument plugin of the catalog (its
    // key): the plugin is made in a synth of its own, opened (with `state`,
    // (kind:, path:), if given) and from then on the sequencer's notes go to
    // it as MIDI, note-on at the note's stamp and note-off at its end, on
    // channel 1. Until it is open the notes are not sent. Notifies
    // \instrument, key (and again with the open's answer). Answers whether
    // it was taken.
    instrumentEntries { ^(catalog ? []).select { |e| (e[\synth] == true) and: { e[\bridged] != true } } }

    setInstrument { |key, state|
        var synthGroup = drums !? { |d| d.synthGroup };
        if(key.notNil and: { key.asString.isEmpty }) { key = nil };
        instrumentSynth !? { |x| x.free };
        instrumentSynth = nil;
        instrument !? { |p| p.removeDependant(this) };
        instrument = nil;
        instrumentKey = key;
        if(key.notNil) {
            if(synthGroup.isNil or: { (\VSTPlugin.asClass.isNil and: { pluginMaker.isNil }) }) {
                ("MegaSA: " ++ key ++ " cannot be hosted here (no VSTPlugin, or no synth group); the Wave synth plays.").warn;
                instrumentKey = nil;
            } {
                instrumentSynth = Synth.head(synthGroup, \megaSAInstrument, [\out, synthBus.index]);
                instrument = try {
                    (pluginMaker ? { |synth, id, pth| MegaSAPlugin(synth, id, pth) }).value(instrumentSynth, \plugin, key)
                } { |err| ("MegaSA: " ++ key ++ " could not be made (" ++ err.errorString ++ ").").warn; nil };
                if(instrument.isNil) {
                    instrumentSynth.free;
                    instrumentSynth = nil;
                    instrumentKey = nil;
                } {
                    tempo !? { |t| instrument.setTempo(t) };
                    instrument.open(state, { |p, ok| if(alive) { tempo !? { |t| p.setTempo(t) }; this.changed(\instrument, key, ok) } });
                };
            };
        };
        drums !? { |d| d.noteVoice = if(instrumentKey.isNil) { { |rec, where| wave.voiceMsgs(rec, where) } }
            { { |rec, where| this.prInstrumentMsgs(rec, where) } } };
        this.changed(\instrument, instrumentKey);
        ^instrumentKey == key
    }

    // A note for the plugin: (msgs:, after:, cancel:), as MegaSADrums.prEmitNote
    // takes it. Nothing until it is open. A note held to its very end (100 %)
    // lets go 2 ms after the next one starts, so a mono patch hears legato.
    prInstrumentMsgs { |rec, where|
        var p = instrument, on, off;
        if(p.isNil or: { p.state != \open }) { ^[] };
        on = p.midiMsg(144, rec[\note].asInteger, rec[\vel].asInteger.clip(1, 127));
        off = p.midiMsg(128, rec[\note].asInteger, 0);
        if(on.isNil or: { off.isNil }) { ^[] };
        ^(msgs: [on], after: [[rec[\gate] + (if(rec[\tie] == true) { 0.002 } { 0 }), [off]]], cancel: [off])
    }

    // The instrument's window, if it has one.
    instrumentEditor { instrument !? { |p| p.editor } }

    synthPresetSlug { |name| ^Looper.presetSlug(name) }

    synthPresetNames { |dir|
        if(dir.isNil or: { File.exists(dir).not }) { ^[] };
        ^(dir +/+ "*.json").pathMatch.collect { |p| PathName(p).fileNameWithoutExtension }.sort
    }

    // Answers the slug, or nil if nothing was written.
    saveSynthPreset { |dir, name|
        var slug;
        if(dir.isNil or: { drums.isNil }) { "MegaSA synth preset: no directory given.".warn; ^nil };
        slug = this.synthPresetSlug(name);
        ^if(this.prWriteSynth(dir +/+ slug ++ ".json", name)) { slug }
    }

    // True once applied; false, with nothing changed, if the file is missing
    // or is no synth file.
    loadSynthPreset { |dir, slug, warnings|
        if(dir.isNil) { ^false };
        ^this.prReadSynth(dir +/+ slug ++ ".json", warnings)
    }

    deleteSynthPreset { |dir, slug|
        var path = dir !? { dir +/+ slug ++ ".json" };
        if(path.isNil or: { File.exists(path).not }) { ^false };
        File.delete(path);
        ^true
    }

    // Keep the synth for the next boot. True once written.
    keepSynth { |path| ^this.prWriteSynth(path ?? { this.class.defaultKeptSynthPath }, "kept") }

    // The kept synth, at boot: false (and nothing said) when nothing was kept.
    loadKeptSynth { |path, warnings|
        path = path ?? { this.class.defaultKeptSynthPath };
        if(File.exists(path).not) { ^false };
        ^this.prReadSynth(path, warnings)
    }

    prWriteSynth { |path, name|
        var why, statePath, inst = instrument;
        if(drums.isNil or: { wave.isNil }) { ^false };
        // The instrument's own sound beside the file, written by the plugin
        // (a moment later: the plugin answers on its own).
        if(inst.notNil and: { inst.state == \open }) {
            File.mkdir(path.dirname);
            statePath = path.splitext[0] ++ inst.stateExtension;
            inst.saveState(\program, statePath, { |p, ok|
                if(ok.not) { ("MegaSA: the instrument's sound was not written to " ++ statePath ++ ".").warn } });
        };
        why = MegaFiles.writeNow(path, MegaSASynthFile.text(name, drums.notes, wave.settings, wave.tableName,
            instrumentKey, statePath !? { |p| p.basename }),
            { |text| if(MegaFiles.parseObject(text).isString) { "it does not read back" } });
        if(why.notNil) { ("MegaSA: the synth was not written to " ++ path ++ " (" ++ why ++ ").").warn; ^false };
        ^true
    }

    prReadSynth { |path, warnings|
        var data = MegaSASynthFile.read(path, warnings);
        if(data.isNil or: { drums.isNil }) { ^false };
        drums.setNotes(data[\notes]);
        wave.setAll(data[\wave]);
        // The instrument, with its sound from beside the file if it kept one.
        if((data[\instrument] != instrumentKey) or: { data[\instrumentState].notNil }) {
            this.setInstrument(data[\instrument], data[\instrumentState] !? { |n|
                (kind: \program, path: path.dirname +/+ n) });
        };
        // Your table, by its name in your wavetables folder; one gone from
        // there leaves the set Analog's, and says so.
        if(data[\table] != wave.tableName) {
            (wave.loadTableNamed(data[\table]) !? { |r| if(r.isString) {
                ("MegaSA: the synth's table " ++ data[\table] ++ " did not load (" ++ r ++ "); Your table plays Analog's.").warn;
                wave.clearTable } });
        };
        ^true
    }

    // ---- Devices ---------------------------------------------------------
    // The chains there are (none on a MegaSA made without its init), and
    // every device in them, the guitar's first.
    chains { ^[guitarChain, loopChain, drumsChain, bassChain, synthChain].reject(_.isNil) }

    devices { ^this.chains.collect { |c| c.devices.asArray }.flatten(1) }

    // A device by its id, or nil.
    device { |id|
        var found;
        this.chains.do { |c| if(found.isNil) { found = c.device(id) } };
        ^found
    }

    // key: a device's id. The default devices' are their effects' keys
    // (MegaSAFx.keys): the guitar's (\shifter, \delay, \filter, \pitchLoop)
    // and the loop's (\echo, \saturator, \redux).
    fx { |key| ^this.device(key) !? { |d| d.on } }

    setFx { |key, flag|
        var d = this.device(key);
        if(d.isNil) {
            ("MegaSA: no effect " ++ key ++ "; there are " ++ this.devices.collect(_.id).join(", ")).warn;
        } {
            d.setOn(flag == true);
            this.changed(\fx, key, d.on);
        };
    }

    // An unknown key goes on to setFx, which says so.
    toggleFx { |key| this.setFx(key, (this.fx(key) ? false).not) }

    // Every built-in device's switch, id -> on, a fresh dictionary: the
    // footswitches. The plugin's is not among them; it has none.
    fxOn {
        var on = IdentityDictionary.new;
        this.devices.do { |d| if(d.isPlugin.not) { on.put(d.id, d.on) } };
        ^on
    }

    // The node a device's switch and settings are sent to, its synth, or nil
    // before its chain is built (the loop's, before a Looper is attached).
    // The tests find an effect's messages through it, so they say what
    // reaches the effect, not how the chains are made of synths.
    fxNode { |key| ^this.device(key) !? { |d| d.node } }

    // One effect setting (a name in MegaSAFx.params, e.g. \filterFreq or
    // \reduxBits) of the default device of its effect, kept to its range,
    // sent to that device's synth and announced as \fxParam for the Effects
    // tab. Kept across boots by a sound, or by Start with this.
    fxParam { |name| ^MegaSAFx.param(name) !? { |p| this.device(p[\fx]) !? { |d| d.param(name) } } }

    setFxParam { |name, value|
        var p = MegaSAFx.param(name);
        var d = p !? { this.device(p[\fx]) };
        case
        { p.isNil } {
            ("MegaSA: no effect setting " ++ name ++ "; they are MegaSAFx.params").warn;
        }
        { value.isNumber.not or: { value.isNaN } } {
            ("MegaSA: " ++ name ++ " needs a number, not " ++ value).warn;
        }
        { d.isNil } {
            ("MegaSA: no " ++ MegaSAFx.title(p[\fx]) ++ " to set " ++ name ++ " on").warn;
        } {
            this.prSetParam(d, name, value);
        };
    }

    // A device's setting, announced as \fxParam when the device is its
    // effect's default (its id is its type), whose settings are named alone.
    // One that moves its delay (the Shifter's pitch) says \latency too.
    prSetParam { |device, name, value|
        device.setParam(name, value);
        if(device.id == device.type) { this.changed(\fxParam, name, device.param(name)) };
        this.prLatencyCheck;
    }

    // Every default device's settings, name -> value, a fresh dictionary.
    fxParams {
        var all = IdentityDictionary.new;
        this.devices.do { |d| if(d.id == d.type) { d.settings.keysValuesDo { |k, v| all.put(k, v) } } };
        ^all
    }

    // Every setting of one device back to the Live set's value.
    resetFx { |key|
        this.device(key) !? { |d| d.params.do { |p| this.prSetParam(d, p[\name], p[\spec].default) } };
    }

    // Every setting of one device at a random value (MegaSAFx.randomValue),
    // but the levels it ends on (MegaSAFx.randomKeeps), for trying sounds
    // out; Reset brings the starting values back. A plugin's settings are in
    // its own window, so a plugin's device has none to draw. Its switch is
    // left as it is. Answers the device, or nil for no such id.
    randomizeFx { |key|
        ^this.device(key) !? { |d|
            d.params.do { |p|
                if(MegaSAFx.randomKeeps.includes(p[\name]).not) { this.prSetParam(d, p[\name], MegaSAFx.randomValue(p)) } };
            d
        }
    }

    // Has any setting of this device moved off the Live set's value? Within a
    // millionth: a value that came back through a file or a 32-bit control is
    // not an edit.
    fxEdited { |key| ^(this.device(key) !? { |d| d.edited }) ? false }

    // Any device's setting by its id and the setting's name (MegaSAFx.params'
    // names): the one address for every device, the second Delay's too. A
    // default device's change is announced as \fxParam, as setFxParam's;
    // every device says its own \param.
    param { |id, name| ^this.device(id) !? { |d| d.param(name) } }

    setParam { |id, name, value|
        var d = this.device(id);
        case
        { d.isNil } { ("MegaSA: no device " ++ id ++ " to set " ++ name ++ " on").warn }
        { d.settings.includesKey(name).not } { ("MegaSA: " ++ id ++ " has no setting " ++ name).warn }
        { value.isNumber.not or: { value.isNaN } } { ("MegaSA: " ++ name ++ " needs a number, not " ++ value).warn }
        { this.prSetParam(d, name, value) };
    }

    // ---- Edits (docs/dev/device-chains.md, sections 5 and 6) --------------------
    // Every edit is decided on the model first and refused, with \refused
    // (what, why) and nothing sent, if it cannot be done. Then the model
    // changes, the server gets its part as stamped bundles that ride the
    // device's 30 ms cross-fade (switched off; fadeTime later moved, freed
    // or parked; then switched back on), MegaSA says \chain (track, op, id,
    // index), and the edit goes on the undo list. A device that is off moves
    // at once. A removed built-in is freed, and its undo builds it anew,
    // empty, as an insert does; a removed plugin is parked, its plugin still
    // open, because it cannot be built anew before phase 5. Undo and redo
    // cover the chains' structure only, not settings or switches, as the MIDI
    // map's undo covers map edits only.

    // The pieces of an edit's timing: how long a device's switch takes to
    // fade (its slot's 30 ms Lag, then some), and how far ahead the first
    // bundle is stamped, so it lands on time, never late.
    *fadeTime { ^0.045 }
    *editLatency { ^0.05 }
    // How long after a new synth its switch may go (prPlace): a few blocks,
    // so the two never land in one.
    *birthGap { ^0.01 }
    // How many edits undo keeps.
    *undoMax { ^64 }
    // The real-time pool the Looper, the cutter and the drums take, which the
    // chains' devices may not. Measured offline (scripts/sa/nrt-memory.sh,
    // 2026-10-10): a whole SA set renders in 6.7 MB, 4.4 MB of it the default
    // chains' devices; the cutter's four voices with their comb and reverb add
    // up to 3.4 MB that set does not hold, the take recorder, the monitors and
    // the grains 0.2 MB. About 5.9 MB in all, doubled for the pool's
    // fragmentation and for what one set does not show.
    *memReserve { ^12 * 1024 * 1024 }
    // The server's CPU: above the first an insert is said to be heavy, above
    // the second refused.
    *cpuWarn { ^60 }
    *cpuRefuse { ^85 }

    chainFor { |track|
        ^case { track == \guitar } { guitarChain } { track == \loop } { loopChain } { track == \drums } { drumsChain }
            { track == \bass } { bassChain } { track == \synth } { synthChain }
    }

    chainOf { |device| ^this.chains.detect { |c| c.devices.includes(device) } }

    // The plugins' devices parked for undo, oldest first.
    limboDevices { ^limbo.asArray }

    canUndo { ^undoList.notEmpty }
    canRedo { ^redoList.notEmpty }

    sampleRate { ^server.sampleRate ? 48000 }

    // The real-time pool, in bytes: what the chains' devices may take (the
    // server's pool less the reserve), and what the devices that have a synth
    // take, the parked plugins' included.
    memoryBudget { ^(((server.options !? { |o| o.memSize }) ? 8192) * 1024) - this.class.memReserve }

    memoryUsed { ^(this.devices ++ limbo).select { |d| d.node.notNil }.sum { |d| d.memBytes(this.sampleRate) } }

    // A new device of a built-in `type` at `index` (the end if nil) of the
    // `track` chain (\guitar, \loop, \drums, \bass), with settings `given` on top of the
    // type's defaults, switched on (it fades in). Answers the device, or nil
    // if it was refused.
    insertDevice { |track, index, type, given, on = true|
        var chain = this.chainFor(track), row = MegaSAFx.type(type), d, why, cpu;
        cpu = if(chain.notNil and: { row.notNil }) { this.prCpuWhy };
        why = case
        { chain.isNil } { "there is no " ++ track ++ " chain" }
        { chain.built.not } { "the " ++ track ++ " chain is not built yet" }
        { type == \plugin } { "a plugin is added by its key in the catalog: insertPlugin(track, index, key)" }
        { row.isNil } { "there is no effect type " ++ type }
        { cpu.notNil } { cpu }
        { this.prRoomFor(row[\memBytes].value(this.sampleRate)).not } { this.prMemoryWhy(row[\memBytes].value(this.sampleRate)) };
        if(why.notNil) { ^this.prRefuse(\insert, type ++ ": " ++ why) };
        d = MegaSADevice(this.prNewId(type), type, given);
        d.rename(this.prNameFor(d.id, type));
        d.prCopyOn(on, nil);
        index = (index ? chain.devices.size).clip(0, chain.devices.size);
        this.prPlace(d, chain, index);
        this.prRecord((op: \insert, device: d, to: [track, index]));
        this.changed(\chain, track, \insert, d.id, index);
        this.prLatencyCheck;
        ^d
    }

    // A plugin from the catalog into a chain, while a loop plays or not.
    // `key` is its entry's in the catalog. Its device goes in at once and
    // passes the chain through; the plugin is opened in it a moment later,
    // once its synth is on the server, and is heard when it has opened.
    // Answers the device, or nil.
    insertPlugin { |track, index, key, on = true|
        var chain = this.chainFor(track), d, why, cpu;
        var entry = (catalog ? []).detect { |e| e[\key] == key.asString };
        cpu = if(chain.notNil and: { entry.notNil }) { this.prCpuWhy };
        why = case
        { chain.isNil } { "there is no " ++ track ++ " chain" }
        { chain.built.not } { "the " ++ track ++ " chain is not built yet" }
        { \VSTPlugin.asClass.isNil } { "VSTPlugin is not installed" }
        { entry.isNil } { "it is not among this Mac's plugins (scan again if it was installed since)" }
        { entry[\bridged] == true } { "it is built for another processor and would need VSTPlugin's bridge" }
        { (entry[\synth] == true) or: { entry[\ins] < 1 } } { "it is no effect: it takes no input" }
        { cpu.notNil } { cpu };
        if(why.notNil) { ^this.prRefuse(\insert, key ++ ": " ++ why) };
        d = MegaSADevice.plugin(this.prNewId(\plugin), MegaSAPlugins.layoutOf(entry), entry[\name], on);
        // What a sound keeps of it, from the start: it is written even before it has opened.
        d.fileExtras = (plugin: MegaSAPlugins.identityOf(entry));
        index = (index ? chain.devices.size).clip(0, chain.devices.size);
        this.prPlace(d, chain, index);
        this.prMakePlugin(d, entry[\key]);
        this.prOpenAfterEdit(d);
        this.prRecord((op: \insert, device: d, to: [track, index]));
        this.changed(\chain, track, \insert, d.id, index);
        this.prLatencyCheck;
        ^d
    }

    // A plugin's open, sent once its device's synth is on the server: after
    // the bundle that makes it (prPlace), and a moment more. Not if it was
    // taken out again meanwhile, or is open already.
    prOpenAfterEdit { |device|
        var wait = ((device.pendingUntil ? 0) - thisThread.seconds).max(0) + 0.1;
        SystemClock.sched(wait, {
            if(alive and: { this.devices.includes(device) } and: { device.plugin.notNil }
                and: { device.plugin.state == \closed }) { this.prOpenPlugin(device) };
            nil
        });
    }

    // A copy of a device, its settings and its switch, at `index` of `track`
    // (by default right after it, in its own chain). Answers the copy, or nil.
    copyDevice { |id, track, index|
        var d = this.device(id), from, chain, why, c, cpu;
        from = d !? { this.chainOf(d) };
        chain = this.chainFor(track ? (from !? (_.track)));
        cpu = if(chain.notNil and: { d.notNil }) { this.prCpuWhy };
        why = case
        { d.isNil } { "there is no device " ++ id }
        { chain.isNil } { "there is no " ++ track ++ " chain" }
        { chain.built.not } { "the " ++ chain.track ++ " chain is not built yet" }
        { d.isPlugin } { "a plugin is not copied yet: add it again from the catalog" }
        { d.typeRow.isNil } { "its type is unknown to this build" }
        { cpu.notNil } { cpu }
        { this.prRoomFor(d.memBytes(this.sampleRate)).not } { this.prMemoryWhy(d.memBytes(this.sampleRate)) };
        if(why.notNil) { ^this.prRefuse(\copy, id ++ ": " ++ why) };
        c = d.copyAs(this.prNewId(d.type), nil);
        c.rename(this.prNameFor(c.id, d.type));
        index = (index ?? { if(chain === from) { from.indexOf(d) + 1 } { chain.devices.size } }).clip(0, chain.devices.size);
        this.prPlace(c, chain, index);
        this.prRecord((op: \insert, device: c, to: [chain.track, index]));
        this.changed(\chain, chain.track, \insert, c.id, index);
        this.prLatencyCheck;
        ^c
    }

    // A device out of its chain: a built-in freed, a plugin parked, for undo
    // either way. Answers true, or false if it was refused.
    removeDevice { |id|
        var d = this.device(id), chain, index, why;
        chain = d !? { this.chainOf(d) };
        why = case
        { d.isNil } { "there is no device " ++ id }
        { chain.built.not } { "its chain is not built yet" };
        if(why.notNil) { this.prRefuse(\remove, id ++ ": " ++ why); ^false };
        index = chain.indexOf(d);
        this.prTakeOut(d);
        this.prRecord((op: \remove, device: d, from: [chain.track, index]));
        this.changed(\chain, chain.track, \remove, id, index);
        this.prLatencyCheck;
        ^true
    }

    // A device to `index` of `track` (its own chain if nil), counted with it
    // out of its chain: 0 is the first place. Answers true, or false.
    moveDevice { |id, track, index|
        var d = this.device(id), from, to, fromIndex, why, last;
        from = d !? { this.chainOf(d) };
        to = this.chainFor(track ? (from !? (_.track)));
        why = case
        { d.isNil } { "there is no device " ++ id }
        { to.isNil } { "there is no " ++ track ++ " chain" }
        { from.built.not or: { to.built.not } } { "its chain or the one it goes to is not built yet" };
        if(why.notNil) { this.prRefuse(\move, id ++ ": " ++ why); ^false };
        fromIndex = from.indexOf(d);
        last = to.devices.size - if(to === from) { 1 } { 0 };
        index = (index ? last).clip(0, last);
        if((to === from) and: { index == fromIndex }) { ^true };
        this.prShift(d, to, index);
        this.prRecord((op: \move, device: d, from: [from.track, fromIndex], to: [to.track, index]));
        this.changed(\chain, to.track, \move, id, index);
        this.prLatencyCheck;
        ^true
    }

    // A device's name, as its panel and its MIDI labels show it.
    renameDevice { |id, name|
        var d = this.device(id), chain;
        if(d.isNil) { this.prRefuse(\rename, "there is no device " ++ id); ^false };
        chain = this.chainOf(d);
        d.rename(name);
        this.changed(\chain, chain.track, \rename, id, chain.indexOf(d));
        ^true
    }

    // The last edit undone, or the last undone one done again. Each answers
    // true, or false with nothing to undo or redo, or if it was refused (a
    // device to be built anew where there is no room for it, or a plugin
    // whose synth has gone).
    undo {
        var r = undoList.last;
        if(r.isNil or: { this.prApply(r, true).not }) { ^false };
        undoList.pop;
        redoList.add(r);
        ^true
    }

    redo {
        var r = redoList.last;
        if(r.isNil or: { this.prApply(r, false).not }) { ^false };
        redoList.pop;
        undoList.add(r);
        ^true
    }

    // One edit's record applied forwards (redo) or backwards (undo): taken
    // out, placed or moved, said as \chain.
    prApply { |r, backwards|
        var d = r[\device], op = r[\op], at = if(backwards) { r[\from] } { r[\to] };
        var out = ((op == \insert) and: { backwards }) or: { (op == \remove) and: { backwards.not } };
        var chain = at !? { this.chainFor(at[0]) }, from = this.chainOf(d), why;
        why = case
        { out and: { from.isNil } } { d.id ++ " is in no chain" }
        { out.not and: { chain.isNil or: { chain.built.not } } } { "the chain it goes to is not built" }
        { (op == \move) and: { from.isNil } } { d.id ++ " is in no chain" }
        { (op != \move) and: { out.not } and: { from.notNil } } { d.id ++ " is in a chain already" }
        { (op != \move) and: { out.not } and: { d.node.isNil } and: { d.isPlugin } }
            { "its plugin was closed: add it again from the catalog" }
        { (op != \move) and: { out.not } and: { d.node.isNil } and: {
            this.prRoomFor(d.memBytes(this.sampleRate)).not } } { this.prMemoryWhy(d.memBytes(this.sampleRate)) };
        if(why.notNil) { this.prRefuse(if(backwards) { \undo } { \redo }, why); ^false };
        case
        { out } {
            at = [from.track, from.indexOf(d)];
            this.prTakeOut(d);
            this.changed(\chain, at[0], \remove, d.id, at[1]);
        }
        { op == \move } {
            this.prShift(d, chain, at[1]);
            this.changed(\chain, at[0], \move, d.id, at[1]);
        } {
            this.prPlace(d, chain, at[1]);
            this.changed(\chain, at[0], \insert, d.id, at[1]);
        };
        this.prLatencyCheck;
        ^true
    }

    // ---- The edits' server side -----------------------------------------
    // When the next edit's first bundle may land: on time, and a millisecond
    // after the last edit's bundles and after whatever was last sent
    // `device`'s synth (a footswitch pressed during the edit before,
    // sendToSynth). Never at the same instant: two stamps worked out at
    // different moments can come out a rounding apart, in either order.
    prEditStart { |device|
        ^[thisThread.seconds + this.class.editLatency, editsBusyUntil + 0.001,
            ((device !? { device.pendingUntil }) ? -inf) + 0.001].maxItem
    }

    prSend { |at, msgs| server.sendBundle((at - thisThread.seconds).max(0), *msgs) }

    // In at `index`: a device with no synth (a new one, or a built-in
    // removed and brought back, empty) gets one, made switched off; a parked
    // plugin comes back from limbo onto this chain's bus, told the tempo it
    // missed there. Then its switch, if it is on, fades it in. A new synth's switch goes birthGap after it, in a
    // bundle of its own: a synth's UGens start at its first block, after the
    // whole bundle that made it, so a switch in that bundle would start its
    // Lag already on, wet from the first sample.
    prPlace { |device, chain, index|
        var t0 = this.prEditStart(device), t1 = t0, anchor, msgs, node;
        chain.insertModel(device, index);
        limbo.remove(device);
        anchor = chain.anchorFor(chain.indexOf(device));
        if(device.node.isNil) {
            this.prSend(t0, [device.newOffMsg(server, anchor, chain.bus.index, beatDur)]
                ++ this.prPhaseMsgs(device, chain));
            t1 = t0 + this.class.birthGap;
            if(device.on) { this.prSend(t1, device.switchMsgs(true)) };
        } {
            node = device.node.nodeID;
            msgs = [[19, node, anchor.nodeID], [15, node, \bus, chain.bus.index]]
                ++ if(device.followsTempo) { [[15, node, \beatDur, beatDur]] } { [] }
                ++ this.prPhaseMsgs(device, chain);
            if(device.on) { msgs = msgs ++ device.switchMsgs(true) };
            this.prSend(t0, msgs);
            device.plugin !? { |p| tempo !? { |t| p.setTempo(t) } };
        };
        device.pendingUntil = t1;
        editsBusyUntil = t1;
    }

    // Out of its chain: switched off, and once it has faded, a built-in's
    // synth freed (its memory with it; an undo builds it anew), a plugin's
    // moved into the paused limbo group, where it runs no more and waits,
    // still open, for an undo.
    prTakeOut { |device|
        var t0 = this.prEditStart(device), t1 = t0;
        this.chainOf(device) !? { |c| c.removeModel(device) };
        device.node !? { |n|
            if(device.on) { this.prSend(t0, [device.switchMsg(false)]); t1 = t0 + this.class.fadeTime };
            if(device.isPlugin) {
                limboGroup ?? {
                    limboGroup = Group.after(recordGroup);
                    limboGroup.run(false);
                };
                this.prSend(t1, [[23, limboGroup.nodeID, n.nodeID]]);
                limbo.add(device);
            } {
                this.prSend(t1, [[11, n.nodeID]]);
                device.forget;
            };
        };
        device.pendingUntil = t1;
        editsBusyUntil = t1;
    }

    // To `index` of `chain`: switched off, and once it has faded, after its
    // new neighbour (onto that chain's bus if it is the other one), then
    // switched back on.
    prShift { |device, chain, index|
        var from = this.chainOf(device), t0 = this.prEditStart(device), t1 = t0, msgs, node;
        from.removeModel(device);
        chain.insertModel(device, index);
        device.node !? { |n|
            node = n.nodeID;
            if(device.on) { this.prSend(t0, [device.switchMsg(false)]); t1 = t0 + this.class.fadeTime };
            msgs = [[19, node, chain.anchorFor(chain.indexOf(device)).nodeID]];
            if(chain !== from) { msgs = msgs.add([15, node, \bus, chain.bus.index]) };
            if(device.on) { msgs = msgs ++ device.switchMsgs(true) };
            this.prSend(t1, msgs);
        };
        device.pendingUntil = t1;
        editsBusyUntil = t1;
    }

    // An edit on the undo list. A new edit drops the redo list. A parked
    // plugin stays parked while MegaSA lives, undo or no undo: it cannot be
    // opened anew before phase 5, and a recall may want it back.
    prRecord { |r|
        undoList.add(r);
        while { undoList.size > this.class.undoMax } { undoList.removeAt(0) };
        redoList = List.new;
    }

    // Whether `bytes` more fit the budget.
    prRoomFor { |bytes| ^bytes <= (this.memoryBudget - this.memoryUsed) }

    prMemoryWhy { |bytes|
        ^"it needs " ++ (bytes / 1048576).round(0.1) ++ " MB of the real-time pool and "
            ++ ((this.memoryBudget - this.memoryUsed).max(0) / 1048576).round(0.1) ++ " MB are free"
    }

    // Nil if the server's CPU has room, else why not; above cpuWarn the post
    // window says the server is busy.
    prCpuWhy {
        var peak = server.peakCPU, avg = server.avgCPU;
        if(peak.isNumber and: { peak > this.class.cpuRefuse }) { ^"the server's CPU peaks at " ++ peak.round(1) ++ " %" };
        if(avg.isNumber and: { avg > this.class.cpuWarn }) {
            ("MegaSA: the server's CPU is at " ++ avg.round(1) ++ " % on average; a device more may crackle.").warn;
        };
        ^nil
    }

    prRefuse { |what, why|
        ("MegaSA: " ++ what ++ " refused: " ++ why ++ ".").warn;
        this.changed(\refused, what, why);
        ^nil
    }

    // The loop's phase for a device that follows it, as its chain has it.
    prPhaseMsgs { |device, chain|
        ^if(device.followsPhase and: { chain.phaseBus.notNil } and: { device.node.notNil }) {
            [[15, device.node.nodeID, \phaseBus, chain.phaseBus]] } { [] }
    }

    // A further device's name: its type's title and its number, "Delay 2".
    prNameFor { |id, type| ^MegaSAFx.nameFor(id, type) }

    // The marks a sound keeps: all but those of a type in no chain to begin
    // with whose key is still free (1), which every sound would otherwise
    // carry for nothing.
    prMarksToKeep { ^nextIds.reject { |v, k| (v <= 1) and: { MegaSAFx.extraKeys.includes(k) } } }

    // The next id of a type, from its high-water mark: 1 is the type's key
    // itself, the first device of a type in no chain to begin with.
    prNewId { |type|
        var n = nextIds[type] ? 2, id, known = (this.devices ++ limbo).collect(_.id);
        if((n <= 1) and: { known.includes(type).not }) { nextIds.put(type, 2); ^type };
        n = n.max(2);
        while { id = (type ++ n).asSymbol; known.includes(id) } { n = n + 1 };
        nextIds.put(type, n + 1);
        ^id
    }

    // ---- Sounds (docs/dev/device-chains.md, section 11) --------------------------
    // A sound is both chains as a document (MegaSASound): which devices, in
    // which order, their names, switches and settings, and the file the
    // plugin's state is in. `sound` answers the chains as they stand;
    // writeSound puts them on disk; MegaSA is built from one (*new), and
    // applySound recalls one onto the running chains.

    *backupsKept { ^5 }

    // The chains as they stand, as a sound called `name`.
    sound { |name = "sound"|
        var x = soundExtras ? ();
        ^MegaSASound(name, Date.getDate.stamp, this.prMarksToKeep,
            this.chains.collect { |c|
                (track: c.track, devices: c.devices.collect { |d| this.prSpecOf(d) }.asArray,
                    extras: (x[\tracks] ? ())[c.track] ? [])
            } ++ (x[\rawTracks] ? []),
            x[\top] ? [])
    }

    // What a session's header says of the chains as a set begins: the
    // sound's name and whether the chains are still as kept, both chains with
    // every device's switch and settings (so a take can be rendered through
    // its own chain again), and each chain's delay in seconds (Lg, Ll, Ld, Lb).
    sessionInfo {
        var sr = this.sampleRate;
        ^(sound: soundName, soundKept: this.dirty.not,
            lg: (guitarChain !? { |c| c.latency(sr) / sr }) ? 0, ll: (loopChain !? { |c| c.latency(sr) / sr }) ? 0,
            ld: (drumsChain !? { |c| c.latency(sr) / sr }) ? 0,
            lb: (bassChain !? { |c| c.latency(sr) / sr }) ? 0,
            ls: (synthChain !? { |c| c.latency(sr) / sr }) ? 0,
            chains: this.chains.collect { |c|
                (track: c.track, devices: c.devices.collect { |d|
                    var e = (id: d.id, type: d.type, name: d.name, on: d.on);
                    if(d.isPlugin) {
                        e.put(\layout, d.layout);
                        d.state !? { |st| e.put(\state, st[\file]) };
                    } { e.put(\settings, d.settings.copy) };
                    e
                }.asArray)
            })
    }

    // Whether the chains or their settings differ from the sound last kept
    // (Keep's mark). The switches and the plugin's own knobs do not count.
    dirty { ^keptContent.notNil and: { this.sound.contentString != keptContent } }

    // The chains as they stand are the kept ones from here on.
    markKept { |sound|
        keptContent = (sound ?? { this.sound }).contentString;
        this.changed(\kept);
    }

    prExtrasFrom { |sound|
        var perTrack = IdentityDictionary.new;
        sound.tracks.do { |t| if(t[\raw].isNil) { perTrack.put(t[\track], t[\extras] ? []) } };
        ^(top: sound.extras, tracks: perTrack, rawTracks: sound.tracks.select { |t| t[\raw].notNil })
    }

    prExtrasOf { |spec|
        ^(extras: spec[\extras], settingsExtras: spec[\settingsExtras], stateExtras: spec[\stateExtras],
            plugin: spec[\plugin], raw: spec[\raw])
    }

    // A device made from a sound's entry, in the model only.
    prDeviceFrom { |spec, sound|
        var d = if(spec[\type] == \plugin) { MegaSADevice.plugin(spec[\id], spec[\layout], spec[\name], spec[\on]) }
            { MegaSADevice(spec[\id], spec[\type], spec[\settings]) };
        // (A name megalooper itself gave before 1.0 is today's: MegaSAFx.nameNow.)
        d.prCopyOn(spec[\on], if(spec[\type] == \plugin) { spec[\name] } { MegaSAFx.nameNow(spec[\id], spec[\type], spec[\name]) });
        d.fileExtras = this.prExtrasOf(spec);
        spec[\state] !? { |x| d.state = (kind: x[\kind], file: x[\file], path: sound.statePath(spec)) };
        ^d
    }

    // A device as a sound's entry.
    prSpecOf { |d|
        var x = d.fileExtras ? (), spec;
        if(x[\raw].notNil) { ^(id: d.id, type: d.type, name: d.name, on: d.on, raw: x[\raw]) };
        spec = (id: d.id, type: d.type, name: d.name, on: d.on, extras: x[\extras] ? []);
        if(d.isPlugin) {
            spec.put(\layout, d.layout);
            // What the plugin says it is, once open; until then what the file said.
            (d.plugin !? { |p| p.identity } ?? { x[\plugin] }) !? { |p| spec.put(\plugin, p) };
            d.state !? { |st|
                spec.put(\state, (kind: st[\kind], file: st[\file]));
                spec.put(\stateExtras, x[\stateExtras] ? []);
            };
            x[\settingsExtras] !? { |more| spec.put(\settingsExtras, more) };
        } {
            spec.put(\settings, d.settings.copy);
            spec.put(\settingsExtras, x[\settingsExtras] ? []);
        };
        ^spec
    }

    // ---- sounds under a name, as the preset bar asks for them ---------------
    // In `dir`, a sound is <slug>.json with its states in <slug>.states. The
    // names are the Looper's slugs, as every preset's.
    soundPath { |dir, name| ^dir +/+ this.fxPresetSlug(name) ++ ".json" }

    soundNames { |dir|
        if(dir.isNil or: { File.exists(dir).not }) { ^[] };
        ^(dir +/+ "*.json").pathMatch.collect { |p| PathName(p).fileNameWithoutExtension }.sort
    }

    // The chains as a sound called `name` in `dir`. Answers its slug at once
    // (nil with no folder); the file is written after this returns, the
    // plugin's state with it if statesAllowed. Says \soundSaved (slug, ok,
    // why, withStates) when it is, or is not; `action` gets the same.
    saveSound { |dir, name, action|
        var slug, withStates = statesAllowed.value != false;
        if(dir.isNil) { "MegaSA sound: no folder given.".warn; ^nil };
        slug = this.fxPresetSlug(name);
        this.writeSound(this.soundPath(dir, name), name.asString, withStates, nil, { |ok, why|
            if(ok.not) { ("MegaSA: the sound " ++ slug ++ " was not saved: " ++ why ++ ".").warn };
            this.changed(\soundSaved, slug, ok, why, withStates);
            action.value(ok, why, withStates);
        });
        ^slug
    }

    // The sound `name` of `dir` recalled onto the chains (applySound). False,
    // with nothing changed, if its file is missing or refused. Says
    // \soundLoaded (slug, ok, notes) once the plugin's state is in, or is not.
    loadSound { |dir, name, action|
        var slug = this.fxPresetSlug(name), path = this.soundPath(dir, name), sound = MegaSASound.read(path);
        if(sound.isString) {
            ("MegaSA: the sound " ++ path.basename ++ " is not recalled: " ++ sound ++ ".").warn;
            ^false
        };
        sound.problems.do { |p| ("MegaSA: the sound " ++ path.basename ++ ": " ++ p ++ ".").warn };
        ^this.applySound(sound, { |ok, notes|
            this.changed(\soundLoaded, slug, ok, notes);
            action.value(ok, notes);
        })
    }

    // A sound's file and its states. False if there was none.
    deleteSound { |dir, name|
        var path = this.soundPath(dir, name), states = MegaSASound.statesDirFor(path);
        if(File.exists(path).not) { ^false };
        File.delete(path);
        if(File.exists(states)) {
            (states +/+ "*").pathMatch.do { |p| File.delete(p) };
            File.delete(states);
        };
        ^true
    }

    // The chains to the file at `path`, as a sound called `name`, with one
    // commit point:
    //   1. with `withStates`, the plugin writes its state to a new stamped
    //      file in the sound's states folder (<path less .json>.states);
    //      without, the sound names the state file it had, copied in if it
    //      lies elsewhere. A state is written only while stopped, or the
    //      guitar's DI would be heard: the caller says which.
    //   2. the text goes through the atomic writer, read back, the file it
    //      replaces copied to `backupDir` first if one is given;
    //   3. only then, and only if step 1 wrote a new state, are the state
    //      files nobody names any more deleted (the sound, its backups and
    //      the devices as they stand name theirs), and the backups trimmed.
    // Whatever fails before step 2 has moved the file leaves the old sound
    // whole. Refused, with nothing written: a file there from a newer
    // megalooper, and a sound that would name a state of the open plugin
    // that is on disk no more (written anew once the loop is stopped).
    // `action` gets (ok, why, the sound written). `sync` waits for the
    // file's move (the tests'); `stamp` is the tests' too.
    writeSound { |path, name = "sound", withStates = true, backupDir, action, sync = false, stamp|
        var statesDir = MegaSASound.statesDirFor(path);
        var devs = this.pluginDevices.select { |d| d.plugin.state == \open }, files, there, saveNext;
        var write = { |wroteState|
            var sound, text, gone;
            this.prGatherStates(statesDir);
            gone = devs.detect { |d| d.state.notNil and: { File.exists(statesDir +/+ d.state[\file]).not } };
            if(gone.notNil) {
                // The way to mend it first: a status line cuts the end.
                action.value(false, "stop the loop and save again: " ++ gone.name
                    ++ "'s own sound is on disk no more (" ++ gone.state[\file] ++ ")");
            } {
                sound = this.sound(name).named(name, stamp);
                text = sound.fileString;
                MegaFiles.write(path, text, { |read|
                    var back = MegaSASound.parse(read ? "");
                    case
                    { back.isString } { "it did not read back: " ++ back }
                    { back.devices.size != sound.devices.size } {
                        "it read back with " ++ back.devices.size ++ " devices, not " ++ sound.devices.size }
                }, backupDir !? { |b| b +/+ stamp ++ ".json" }, { |ok, why|
                    if(ok) {
                        sound.statesDir = statesDir;
                        soundName = name.asString;
                        backupDir !? { |b| MegaFiles.trim(b, "*.json", this.class.backupsKept) };
                        if(wroteState) { this.prSweepStates(statesDir, sound, backupDir) };
                    };
                    action.value(ok, why, sound);
                }, sync, true);
            };
        };
        // The stamp names the state file and the backup: a second's.
        stamp = stamp ?? { Date.getDate.stamp };
        there = if(File.exists(path)) { MegaSASound.read(path) };
        if(there.isString and: { there.contains("newer megalooper") }) {
            ^action.value(false, "the file there " ++ there.drop(3) ++ ": it is not written over")
        };
        if(withStates and: { devs.notEmpty }) {
            File.mkdir(statesDir);
            // Every open plugin writes its own, one after another. A name
            // of its own for each: a second write in one second gets a count.
            files = devs.collect { |d|
                var count = 1, file = d.id ++ "-" ++ stamp ++ d.plugin.stateExtension;
                while { File.exists(statesDir +/+ file) } {
                    count = count + 1;
                    file = d.id ++ "-" ++ stamp ++ "-" ++ count ++ d.plugin.stateExtension;
                };
                file
            };
            saveNext = { |i|
                if(i >= devs.size) { write.value(true) } {
                    this.prStateJob(\save, \program, statesDir +/+ files[i], { |ok|
                        if(ok) {
                            devs[i].state = (kind: \program, file: files[i], path: statesDir +/+ files[i]);
                            saveNext.value(i + 1);
                        } { action.value(false, devs[i].name ++ " did not save its state") };
                    }, devs[i]);
                };
            };
            saveNext.value(0);
        } { write.value(false) };
    }

    // Every state file a device names is in `statesDir`: one that lies
    // elsewhere (the kept sound's, for a sound saved under a name) is copied.
    // The device goes on naming where it lay: that copy is the older one.
    prGatherStates { |statesDir|
        this.devices.do { |d|
            d.state !? { |st|
                var here = statesDir +/+ st[\file];
                if(st[\path].notNil and: { st[\path] != here } and: { File.exists(st[\path]) } and: { File.exists(here).not }) {
                    File.mkdir(statesDir);
                    File.copy(st[\path], here);
                };
            }
        };
    }

    // The state files in `statesDir` that nobody names are deleted: neither
    // `sound`, nor a backup in `backupDir`, nor a device as it stands now (a
    // save already on its way has written its own). Only files of a kind
    // megalooper writes.
    prSweepStates { |statesDir, sound, backupDir|
        var named = Set.new;
        sound.stateFiles.do { |f| named.add(f) };
        (this.devices ++ limbo).do { |d| d.state !? { |st| named.add(st[\file]) } };
        backupDir !? { |b|
            (b +/+ "*.json").pathMatch.do { |p|
                (MegaFiles.readText(p) ? "").findRegexp("\"file\" *: *\"([^\"/]+)\"").clump(2).do { |pair|
                    pair[1] !? { |group| named.add(group[1]) } };
            };
        };
        (statesDir +/+ "*").pathMatch.do { |p|
            if(named.includes(p.basename).not and: { ["fxp", "fxb", "vstpreset"].includesEqual(p.splitext[1]) }) { File.delete(p) };
        };
    }

    // A sound onto the running chains: a recall.
    //   - The same devices in the same places: only settings, names and the
    //     plugin's state go across. No switch is flipped.
    //   - Other devices or another order: built-ins are added (with the
    //     sound's switch), removed and moved as edits are, on the cross-fade,
    //     while a loop plays. A plugin the sound has not is parked; one it
    //     has and that is parked comes back. A plugin that would have to be
    //     opened is left out, and said (phase 5). Undo starts anew.
    // Answers true, or false if it was refused (a chain not built).
    // `action` gets (ok, notes): ok false if the plugin's state did not load,
    // notes what was left out. `withState` false leaves the plugin's own
    // sound as it is (a recovery's: its chains, not a state to load again).
    applySound { |sound, action, withState = true|
        var structural = sound.sameStructureAs(this.sound).not, notes = List.new, loads, loadNext, allOk, fresh;
        if(structural and: { this.chains.any { |c| c.built.not } }) {
            this.prRefuse(\recall, "a chain is not built yet");
            ^false
        };
        fresh = if(structural) { this.prRestructure(sound, notes) } { [] };
        sound.devices.do { |x|
            this.device(x[\id]) !? { |d|
                if(d.type == x[\type]) {
                    x[\settings] !? { |settings|
                        settings.keysValuesDo { |k, v| if(d.param(k) != v) { this.prSetParam(d, k, v) } } };
                    if(d.isPlugin.not and: { d.name != MegaSAFx.nameNow(x[\id], x[\type], x[\name]) }) {
                        this.renameDevice(d.id, MegaSAFx.nameNow(x[\id], x[\type], x[\name])) };
                    if(d.isPlugin and: { d.name != x[\name] }) { this.renameDevice(d.id, x[\name]) };
                    d.fileExtras = this.prExtrasOf(x);
                    // A plugin that is not open cannot take the sound's
                    // state now: its device names it all the same, so the
                    // sound saved back still has its own.
                    // One still opening opens with the state it was handed,
                    // so its device goes on naming that. Either way it is said.
                    // (Not one this recall has just put in: it opens with the sound's state.)
                    if(withState and: { x[\state].notNil } and: { fresh.includes(d).not }
                        and: { d.plugin.isNil or: { d.plugin.state != \open } }) {
                        if(d.plugin.isNil or: { #[\failed, \crashed].includes(d.plugin.state) }) {
                            d.state = (kind: x[\state][\kind], file: x[\state][\file], path: sound.statePath(x));
                        };
                        d.plugin !? { |p| notes.add(d.name ++ " is " ++ p.state ++ ", so its own sound was not loaded") };
                    };
                };
            };
        };
        soundExtras = this.prExtrasFrom(sound);
        soundName = sound.name;
        sound.nextIds.keysValuesDo { |k, v| nextIds.put(k, max(nextIds[k] ? 1, v)) };
        if(structural) {
            undoList = List.new;
            redoList = List.new;
            this.chains.do { |c| this.changed(\chain, c.track, \recall, nil, nil) };
            this.prLatencyCheck;
        };
        notes.do { |n| ("MegaSA: recall: " ++ n ++ ".").warn };
        // Every open plugin takes its own state from the sound, one after
        // another; the answer comes after the last.
        loads = if(withState.not) { [] } {
            this.pluginDevices.select { |d|
                var x = sound.device(d.id);
                (d.plugin.state == \open) and: { x.notNil } and: { x[\state].notNil } and: { sound.statePath(x).notNil }
            }
        };
        allOk = true;
        loadNext = { |i|
            var d, x, p;
            if(i >= loads.size) { action.value(allOk, notes.asArray) } {
                d = loads[i];
                x = sound.device(d.id);
                p = sound.statePath(x);
                this.prStateJob(\load, x[\state][\kind], p, { |ok|
                    if(ok) { d.state = (kind: x[\state][\kind], file: x[\state][\file], path: p) } { allOk = false };
                    loadNext.value(i + 1);
                }, d);
            };
        };
        loadNext.value(0);
        ^true
    }

    // The chains made the sound's: what it has not goes out, then each chain
    // is put in the sound's order, a device at a time, each an edit of its
    // own on the cross-fade.
    prRestructure { |sound, notes|
        var find = { |spec| (this.devices ++ limbo).detect { |d| (d.id == spec[\id]) and: { d.type == spec[\type] } } };
        var keep = IdentitySet.new, made = IdentitySet.new;
        sound.devices.do { |spec| find.(spec) !? { |d| keep.add(d) } };
        this.devices.do { |d| if(keep.includes(d).not) { this.prTakeOut(d) } };
        this.chains.do { |chain|
            var at = 0;
            sound.devices(chain.track).do { |spec|
                var d = find.(spec), from, why, target;
                from = d !? { this.chainOf(d) };
                case
                { d.isNil and: { spec[\type] == \plugin } } {
                    // A plugin the sound names and nothing here hosts: its
                    // device goes in, and the plugin is opened in it with
                    // the sound's state. One this Mac has not leaves the
                    // device empty, and the sound keeps what it says of it.
                    d = this.prDeviceFrom(spec, sound);
                    this.prPlace(d, chain, at);
                    at = at + 1;
                    made.add(d);
                    target = this.prPluginTarget(d);
                    if(target.notNil) { this.prMakePlugin(d, target); this.prOpenAfterEdit(d) } {
                        this.prPluginMissing(d);
                        notes.add(spec[\name] ++ " is not among this Mac's plugins: its place and its sound are kept");
                    };
                }
                { d.isNil } {
                    d = this.prDeviceFrom(spec, sound);
                    why = if(this.prRoomFor(d.memBytes(this.sampleRate)).not) { this.prMemoryWhy(d.memBytes(this.sampleRate)) };
                    if(why.notNil) { notes.add(spec[\id] ++ " is left out: " ++ why) } {
                        this.prPlace(d, chain, at);
                        at = at + 1;
                    };
                }
                { from.isNil } {
                    // A parked plugin, back from limbo.
                    this.prPlace(d, chain, at);
                    at = at + 1;
                }
                {
                    if((from !== chain) or: { chain.indexOf(d) != at }) { this.prShift(d, chain, at) };
                    at = at + 1;
                };
            };
        };
        // The plugin devices made here: each opens with the sound's state.
        ^made
    }

    // ---- The settings file of before the chains ---------------------------
    // Until the chains a preset was every effect setting as one SC literal
    // (<slug>.scd) with Bias FX's bank beside it (<slug>.fxb). A sound
    // (MegaSASound) is what megalooper saves now. What stays is that file's
    // version, which the one-time migration reads the old kept settings by
    // (scripts/setup-sa.scd), and the rule that names a file.
    *fxPresetVersion { ^1 }

    fxPresetSlug { |name| ^Looper.presetSlug(name) }

    // Bias FX's bank from a file while it runs. `action` gets ok.
    loadGuitarBank { |file, action|
        if(this.guitarPlugin.isNil or: { this.guitarPlugin.state != \open }) {
            ("MegaSA: no Bias FX open to load " ++ PathName(file).fileName ++ " into.").warn;
            ^action.value(false)
        };
        this.prBankJob(\load, file, action);
    }

    prBankJob { |what, file, action| this.prStateJob(what, \bank, file, action) }

    // Reading or writing the plugin's state suspends it, and a plugin that
    // is busy may pass the guitar through dry: a DI at full scale is a blast.
    // So the guitar strip is muted around every job, and jobs run one at a
    // time, in the order they were asked for. `what` is \save or \load,
    // `kind` \program or \bank. A save always runs. A load asked for while
    // another still waits replaces it (that one's action gets false), so a
    // burst of recalls ends on the last.
    prStateJob { |what, kind, file, action, device|
        var dev = device ? this.prPluginDevice;
        var job = [what, kind, file, action, dev];
        // Only the guitar is muted around a job: a loop-chain plugin that is
        // busy passes the loop through, which is no blast.
        var onGuitar = { |j| j[4].notNil and: { guitarChain.devices.includes(j[4]) } };
        if(bankBusy) {
            if(what == \load) {
                pendingBank.copy.do { |old|
                    if((old[0] == \load) and: { old[4] === dev }) { pendingBank.remove(old); old[3].value(false) } };
            };
            pendingBank.add(job);
            ^this
        };
        bankBusy = true;
        if(onGuitar.(job) or: { dev.isNil }) { this.hold(\guitar, \bank) };
        bankRoutine = Routine {
            while { job.notNil and: { alive } } {
                var done = false, ok = false, waited = 0, plug;
                var reply = { |p, jobOk| ok = jobOk; done = true };
                if(onGuitar.(job)) { this.hold(\guitar, \bank) };
                0.05.wait;   // the strip's 20 ms fade, then some
                // The plugin as it is now: one an edit has removed since the
                // job was asked for has no state to give or take.
                plug = job[4] !? { |d| if(this.devices.includes(d)) { d.plugin } };
                case
                { plug.isNil or: { plug.state != \open } } { reply.(nil, false) }
                { job[0] == \save } { plug.saveState(job[1], job[2], reply) }
                { plug.loadState(job[1], job[2], reply) };
                while { done.not and: { waited < 30 } } { 0.05.wait; waited = waited + 0.05 };
                job[3].value(ok);
                // A plugin that has not answered in 30 s may still be busy,
                // and its late answer would be taken for the next job's, so
                // the waiting ones are dropped rather than sent into that.
                if(done.not) {
                    ("MegaSA: " ++ (plug !? { |p| p.name } ? "the plugin") ++ " did not answer in 30 s with " ++ PathName(job[2]).fileName
                        ++ "; a later job may still find it busy.").warn;
                    pendingBank.do { |p| p[3].value(false) };
                    pendingBank.clear;
                    job = nil;
                } {
                    job = if(pendingBank.isEmpty) { nil } { pendingBank.removeAt(0) };
                };
            };
            this.prBankJobsDone;
        }.play(SystemClock);
    }

    // The last bank job has answered: the plugin, no longer busy, is told the
    // tempo it may have missed meanwhile, and the guitar is let go.
    prBankJobsDone {
        bankBusy = false;
        if(alive) {
            tempo !? { |t| this.pluginDevices.do { |d| d.plugin.setTempo(t) } };
            this.unhold(\guitar, \bank);
        };
    }

    // The loop's tempo, for the effects that follow it: the echo's times and
    // the auto filter's synced LFO, through each chain's group, and each
    // plugin's host tempo. A device an edit is still making or bringing back
    // is not in its group yet: it gets the beat stamped after the edit.
    setTempo { |bpm|
        if(bpm.notNil and: { bpm > 0 }) {
            tempo = bpm;
            beatDur = 60 / bpm;
            this.chains.do { |c| c.setTempo(beatDur, bpm) };
            this.devices.do { |d|
                if(d.followsTempo and: { d.node.notNil } and: { d.pending }) {
                    d.sendToSynth([15, d.node.nodeID, \beatDur, beatDur]) } };
            this.changed(\tempo, bpm);
        };
    }

    // A reading of the loop, as the Looper's onAnalysis hands it over
    // (setup-model.scd): its tempo for the effects, and the whole result for
    // the drums, which keep it for a Start that finds no reading on the
    // Looper. A running transport is not moved by it: the drums take a new
    // grid from the readings the Looper lands and the Starts it sends.
    setAnalysis { |result|
        if(result.isNil) { ^this };
        this.setTempo(result.bpm);
        drums !? { |d| d.setAnalysis(result) };
    }

    // ---- MIDI to a plugin ---------------------------------------------------
    // What a plugin switches by MIDI (Bias FX's scenes, a pedal in it) it
    // learns itself, from a controller it hears. It hears none here: your
    // controllers are megalooper's. So each plugin device has eight sends,
    // each a controller of its own, value 127 on channel 1. The MIDI map
    // puts a footswitch on a send (sa.fxSend.<id>.<n>), and the plugin's own
    // MIDI learn hears the controller it sends. CC 20 to 27: undefined in
    // the MIDI standard, so no plugin gives them a meaning of its own.
    *pluginSends { ^8 }
    *pluginSendCC { |n| ^19 + n }

    // Send `n` (1..8) of the plugin device `id`. Answers whether it went:
    // not for a device that is none, is no plugin, or is not open.
    pluginSend { |id, n|
        var d = this.device(id);
        if(d.isNil or: { d.isPlugin.not } or: { d.plugin.isNil } or: { n.isInteger.not }
            or: { (n < 1) or: { n > this.class.pluginSends } }) { ^false };
        ^d.plugin.sendControl(0, this.class.pluginSendCC(n), 127) == true
    }

    // The guitar plugin's own window (Bias FX's editor).
    guitarEditor {
        if(this.guitarPlugin.isNil) { "MegaSA: no instrument plugin; the instrument is dry.".warn }
            { this.guitarPlugin.editor };
    }

    free {
        // An open still on its way is given up here, not crashed: its marker
        // goes, or the next boot (the boot run again) would leave it closed.
        this.devices.do { |d| this.prMark(d, false) };
        alive = false;
        CmdPeriod.remove(this);
        // A build still under way builds nothing more, a plugin not yet asked
        // to open is not, and a bank job stops.
        [builder, opener, bankRoutine].do { |r| r !? { if(r !== thisThread) { r.stop } } };
        builder = nil;
        opener = nil;
        bankRoutine = nil;
        // The drums first: they stop deciding hits and let go of the Looper's
        // notifications before anything they play into goes. The Looper keeps
        // their port and their onset sink, which do nothing from now on: on a
        // reboot the old Looper is freed after the new MegaSA is up, and it is
        // still calling them (its MIDI clock every tick).
        drums !? (_.free);
        (this.devices ++ (limbo ? [])).do { |d| d.plugin !? { |p| p.removeDependant(this) } };
        this.chains.do(_.free);
        limboGroup !? (_.free);
        limbo !? { |l| l.do(_.forget); limbo = List.new };
        undoList = List.new;
        redoList = List.new;
        strips.do(_.free);
        masterSynth !? (_.free);
        [guitarGroup, mixerGroup, drumGroup, recordGroup].do { |g| g !? (_.free) };
        wave !? { |w| w.free };
        [guitarBus, bassBus, synthBus, loopBus, loopFxBus, masterBus, recordBus,
            stepsBus, stepsOutBus, onsetBus, onsetOutBus].do { |b| b !? (_.free) };
        stemBusses.do { |b| b !? (_.free) };
        ready = false;
    }
}
