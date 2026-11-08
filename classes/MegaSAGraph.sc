// megalooper — Megalooper SA's frame on the server: its busses and its
// groups, in the order MegaSA's header draws them (the guitar group before
// the default group, where the Looper plays; the drum group, the mixer group
// and the record group after it), and the named anchors the Looper and the
// recorder read: the SoundIn channel that lands on a private bus, the
// strips' busses, the stems.
//
// A part of MegaSA (docs/dev/architecture.md 5, step 9; MegaSA's own until
// 2026-11-08), made in its init: the busses are allocated at once, in the
// language, so they exist the moment MegaSA returns (setup-sa.scd points the
// Looper at them before the Looper's synths start); the groups are made in
// MegaSA's build (makeGroups). MegaSA's bus, group and channel methods are
// its facade.
MegaSAGraph {
    var server, bass;
    var <guitarBus, <bassBus, <loopBus, <loopFxBus, <masterBus, <recordBus;
    // What the note sequencer's instrument plays onto, stereo, and its chain
    // works on before the synth's strip.
    var <synthBus;
    // The drums' busses, stereo: what their voices play onto (stepsBus,
    // onsetBus) and what their effects hand the two strips (stepsOutBus,
    // onsetOutBus).
    var <stepsBus, <stepsOutBus, <onsetBus, <onsetOutBus;
    // Each strip's signal after its fader, stereo, by strip (\guitar, \loop,
    // \drums, \onsetKit, \synth, and \bass on a rig with a bass input): the
    // set's stems, which the session recorder records beside the master
    // (stemSpecs). Only its strip writes one, and they sum to masterBus.
    var <stemBusses;
    var <guitarGroup, <mixerGroup, <drumGroup, <recordGroup;

    // `bass`: whether the rig has a bass input (its strip and its stem).
    *new { |server, bass = false| ^super.newCopyArgs(server, bass == true).init }

    // In this order, so every bus keeps the index it had before the bass and
    // the synth came: theirs are allocated after the others.
    init {
        guitarBus = Bus.audio(server, 2);
        loopBus   = Bus.audio(server, 2);
        loopFxBus = Bus.audio(server, 2);
        masterBus = Bus.audio(server, 2);
        recordBus = Bus.audio(server, 2);
        stepsBus    = Bus.audio(server, 2);
        stepsOutBus = Bus.audio(server, 2);
        onsetBus    = Bus.audio(server, 2);
        onsetOutBus = Bus.audio(server, 2);
        bassBus = Bus.audio(server, 2);
        synthBus = Bus.audio(server, 2);
        stemBusses = IdentityDictionary.new;
        ([\guitar, \loop, \drums, \onsetKit] ++ (if(bass) { [\bass] } { [] }) ++ [\synth])
            .do { |k| stemBusses.put(k, Bus.audio(server, 2)) };
    }

    // The groups around the default group, in the order the header says.
    makeGroups {
        guitarGroup = Group.before(server.defaultGroup);
        mixerGroup  = Group.after(server.defaultGroup);
        drumGroup   = Group.before(mixerGroup);
        recordGroup = Group.after(mixerGroup);
    }

    // The strips' sources, in the mixer's order: strip, bus, ...
    stripBusses {
        ^[\guitar, guitarBus] ++ (if(bass) { [\bass, bassBus] } { [] })
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

    // A strip's synth arguments for its stem: [\stem, index], or none.
    stemArgs { |key|
        var index = this.stemBus(key) !? { |b| b.index };
        ^if(index.isNumber and: { index > 0 }) { [\stem, index] } { [] }
    }

    free {
        [guitarGroup, mixerGroup, drumGroup, recordGroup].do { |g| g !? (_.free) };
        [guitarBus, bassBus, synthBus, loopBus, loopFxBus, masterBus, recordBus,
            stepsBus, stepsOutBus, onsetBus, onsetOutBus].do { |b| b !? (_.free) };
        stemBusses.do { |b| b !? (_.free) };
    }
}
