// One track's chain of devices (docs/dev/device-chains.md, sections 5 and 6): a
// group of its own, the two-channel bus the chain works on, the synth that
// feeds that bus first in every block (its source: the hardware input, or the
// Looper's output copied), and the devices in order, each a synth after the
// one before it in the group, reading the bus and writing it back with
// ReplaceOut. So the order of the synths is the chain's order.
//
// The model, its devices with their switches and settings, exists from the
// moment the chain is made. build puts it on the server; free takes it off
// again and keeps the model, so the next build (the loop's, for the next
// Looper) starts from the devices as they stand. MegaSA's edits change the
// model here and send the server its part (the node a device goes after:
// anchorFor), as stamped bundles of their own.
MegaSAChain {
    var <track, <bus, <sourceDef, <sourceArgs, <devices;
    var <group, <source;

    // track: \guitar, \loop, \drums or \bass. bus: a two-channel audio Bus.
    // sourceDef and sourceArgs: the source's SynthDef (\megaSAChainIn,
    // \megaSAChainCopy, \megaSAChainOn) and its controls but the bus.
    *new { |track, bus, sourceDef, sourceArgs|
        ^super.newCopyArgs(track, bus, sourceDef, sourceArgs ? []).init
    }

    init { devices = List.new }

    // A device at the end of the chain, in the model only.
    add { |device| devices.add(device); ^device }

    // In the model only: a device in at `index` (0 the first), or out.
    insertModel { |device, index| devices.insert(index.clip(0, devices.size), device); ^device }

    removeModel { |device| devices.remove(device); ^device }

    indexOf { |device| ^devices.indexOf(device) }

    device { |id| ^devices.detect { |d| d.id == id } }

    // The node a device at `index` runs right after: the nearest one before
    // it that has a synth (one whose build failed has none), or the source.
    // Nil until built.
    anchorFor { |index|
        var i = index - 1;
        while { (i >= 0) and: { devices[i].node.isNil } } { i = i - 1 };
        ^if(i < 0) { source } { devices[i].node }
    }

    ids { ^devices.collect(_.id).asArray }

    built { ^group.notNil }

    // On the server: a group added to `target` by `addAction`, the source at
    // its head, then every device in order, each with the chain's bus and
    // the beat. A chain already built is freed first.
    build { |target, addAction = \addToTail, beatDur = 0.6|
        this.free;
        group = Group(target, addAction);
        source = Synth.head(group, sourceDef, sourceArgs ++ [\bus, bus.index]);
        // A device that cannot be built costs that device only: the rest of
        // the chain comes up, in order, and the post window says which.
        devices.do { |d|
            try { d.build(group, \addToTail, bus.index, beatDur) } { |err|
                d.forget;
                ("MegaSA: " ++ d.name ++ " (" ++ d.id ++ ") was not built on the " ++ track ++ " chain ("
                    ++ err.errorString ++ "); the chain plays without it.").warn;
            };
        };
        ^group
    }

    // One n_set of the beat to the group, which reaches every device that
    // reads it (a device's own settings never go this way: two devices of a
    // type share their controls' names), and the tempo to each plugin, which
    // reads no synth control.
    setTempo { |beatDur, bpm|
        group !? { |g| g.set(\beatDur, beatDur) };
        devices.do { |d| d.plugin !? { |p| p.setTempo(bpm) } };
    }

    // The chain's delay in frames, and what its synths take from the real-
    // time pool: the sums of its devices'.
    latency { |sampleRate = 48000| ^devices.sum { |d| d.latency(sampleRate) } }

    memBytes { |sampleRate = 48000| ^devices.sum { |d| d.memBytes(sampleRate) } }

    // Off the server: the group goes, and with it the source and every
    // device's synth. The model stays.
    free {
        group !? (_.free);
        group = nil;
        source = nil;
        devices.do(_.forget);
    }

    printOn { |stream| stream << "MegaSAChain(" << track << ", " << this.ids << ")" }
}
