// One device in a chain (docs/dev/device-chains.md, section 6): an effect of a
// built-in type (MegaSAFx.types) or a plugin, its switch, its own settings,
// and the synth it runs in once its chain is built (MegaSAChain, which gives
// it its place and its bus). MegaSA is what the player and the MIDI targets
// talk to; it still says \fx and \fxParam for the default devices, as before
// the split. A device says its own \on and \param.
//
// Ids: a default device has its type's key as its id (\delay); the guitar's
// plugin is \plugin1.
MegaSADevice {
    var <id, <type, <name, <on = false, <settings, <node, <plugin;
    // A plugin's main-bus layout, [ins, outs] (MegaSAPlugin.layouts).
    var <layout;
    // Until when (logical time) an edit's bundles still make, move or switch
    // this device's synth: a footswitch pressed or a setting moved meanwhile
    // is stamped after them (sendToSynth), so it reaches the synth they make,
    // and the player's latest press wins (MegaSA's edits).
    var <>pendingUntil = -inf;
    // What a sound's file said of it that the model does not hold
    // (MegaSASound: extras, settingsExtras, stateExtras, the plugin's
    // identity as text, raw for a type this build has not), so a sound
    // written from the chains carries it on.
    var <>fileExtras;
    // Where a plugin's state was last read from or written to: (kind:
    // \program or \bank, file: its plain name, path: where it is), or nil.
    var <>state;

    // A device of a built-in type, every setting at its type's default (the
    // Live set's) unless `given` (name -> value) says otherwise: a number,
    // not NaN, held to its range.
    *new { |id, type, given| ^super.newCopyArgs(id, type).init(given) }

    // A plugin device: `name` is the plugin's. No settings of its own yet:
    // its knobs are the plugin's (release 1.2).
    *plugin { |id, layout, name, on = true|
        ^super.newCopyArgs(id, \plugin).init.prPlugin(layout, name, on)
    }

    init { |given|
        settings = IdentityDictionary.new;
        this.params.do { |p| settings.put(p[\name], p[\spec].default) };
        given !? { |g| g.keysValuesDo { |k, v|
            if(settings.includesKey(k) and: { v.isNumber } and: { v.isNaN.not }) { settings.put(k, MegaSAFx.constrain(k, v)) } } };
        name = MegaSAFx.title(type);
    }

    prPlugin { |aLayout, aName, flag|
        layout = aLayout ? [1, 1];
        name = aName ? "plugin";
        on = flag == true;
    }

    isPlugin { ^type == \plugin }

    // Its type's row (MegaSAFx.types), or nil for a plugin or a type this
    // build does not know.
    typeRow { ^if(this.isPlugin) { nil } { MegaSAFx.type(type) } }

    followsTempo { ^this.typeRow !? { |t| t[\followsTempo] } ? false }
    // Whether its synth reads the loop's phase (\phaseBus): the Slicer.
    followsPhase { ^this.typeRow !? { |t| t[\followsPhase] } ? false }
    // Whether its synth reads the chains' busses for its key (\keyBuses):
    // the Compressor.
    keyed { ^this.typeRow !? { |t| t[\keyed] } ? false }

    // The settings it has, in its panel's order (MegaSAFx.params' rows).
    params { ^if(this.typeRow.isNil) { [] } { MegaSAFx.paramsOf(type) } }

    // Its on/off control: <type>On for a built-in, `on` for a plugin.
    switchName { ^if(this.isPlugin) { \on } { MegaSAFx.switchName(type) } }

    defName {
        ^case
        // Without VSTPlugin there are no plugin SynthDefs: a plugin device a
        // sound holds passes its chain through, as an unknown type does.
        { this.isPlugin } { if(\VSTPlugin.asClass.notNil) { MegaSAPlugin.defName(layout[0], layout[1]) } { \megaSADevNull } }
        { this.typeRow.notNil } { MegaSAFx.deviceDefName(type) }
        { \megaSADevNull }
    }

    // Its synth's starting controls on `bus` (an index): the bus, the switch
    // as it stands, every setting in panel order, the beat for a type that
    // follows the tempo, and for a keyed one the chains' busses (keyBuses,
    // MegaSAChain's: one per MegaSAFx.keyTracks, the same for every chain,
    // so a device moved to another chain needs no new ones). A plugin starts
    // not ready: it is told it is once it has opened (MegaSAPlugin.bypass).
    startArgs { |bus, beatDur, keyBuses|
        var args = [\bus, bus, this.switchName, on.binaryValue];
        this.params.do { |p| args = args ++ [p[\name], settings[p[\name]]] };
        if(this.followsTempo) { args = args ++ [\beatDur, beatDur] };
        if(this.keyed and: { keyBuses.notNil }) { args = args ++ [\keyBuses, keyBuses] };
        if(this.isPlugin) { args = args ++ [\ready, 0] };
        ^args
    }

    // Its synth, added to `target` by `addAction`.
    build { |target, addAction, bus, beatDur, keyBuses|
        node = Synth(this.defName, this.startArgs(bus, beatDur, keyBuses), target, addAction);
        ^node
    }

    // Its synth made in a bundle (an edit's): the node named now, the s_new
    // answered, switched off, after `target` (a node), for its switch to be
    // turned on by a message of its own after it, so it fades in.
    newOffMsg { |server, target, bus, beatDur, keyBuses|
        var args = this.startArgs(bus, beatDur, keyBuses);
        args[args.indexOf(this.switchName) + 1] = 0;
        node = Synth.basicNew(this.defName, server);
        ^node.newMsg(target, args, \addAfter)
    }

    // The message that sets its synth's switch.
    switchMsg { |flag| ^[15, node.nodeID, this.switchName, (flag == true).binaryValue] }

    // Whether its synth pauses itself while switched off (its type's
    // `sleeps`, MegaSAFx.sleepWhenFaded).
    sleeps { ^(this.typeRow !? { |t| t[\sleeps] == true }) ? false }

    // The messages, for one bundle, that set its switch: switched on, a synth
    // that sleeps is woken first, in the same bundle, so it runs from the
    // block its switch goes on.
    switchMsgs { |flag|
        ^if((flag == true) and: { this.sleeps }) { [[12, node.nodeID, 1], this.switchMsg(true)] } { [this.switchMsg(flag)] }
    }

    // Its synth went with its chain's group: nothing is sent.
    forget { node = nil }

    // The plugin hosted in its synth (MegaSAPlugin, or nil if it could not be
    // made).
    plugin_ { |aPlugin| plugin = aPlugin }

    // \ok; for a plugin \opening, \failed or \crashed as its plugin is (or
    // \failed when none could be made), \held while its latency holds it off;
    // \missing for a type this build does not know.
    status {
        ^case
        { this.isPlugin } {
            plugin !? { |p|
                if((p.state == \open) and: { p.held.notNil }) { \held } {
                    (closed: \opening, opening: \opening, open: \ok)[p.state] ? p.state }
            } ? \failed
        }
        { this.typeRow.notNil } { \ok }
        { \missing }
    }

    setOn { |flag|
        on = flag == true;
        node !? { this.sendToSynth(*this.switchMsgs(on)) };
        this.changed(\on, on);
    }

    // Whether an edit's bundles are still on their way to its synth.
    pending { ^pendingUntil > thisThread.seconds }

    // Messages for its synth (it has one): at once, or while an edit is
    // pending stamped a millisecond after the last thing sent it, which moves
    // pendingUntil on, so the next edit, and the next press, land after it.
    // More than one go as one bundle.
    sendToSynth { |... msgs|
        var now = thisThread.seconds;
        case
        { pendingUntil > now } {
            pendingUntil = pendingUntil + 0.001;
            node.server.sendBundle(pendingUntil - now, *msgs);
        }
        { msgs.size > 1 } { node.server.sendBundle(nil, *msgs) }
        { node.server.sendMsg(*msgs[0]) };
    }

    // Its display name (the type's title, or the plugin's, until renamed).
    rename { |aName|
        name = aName.asString;
        this.changed(\name, name);
    }

    // A device of the same type, with these settings and this switch, as
    // `newId`, called `newName`.
    copyAs { |newId, newName| ^MegaSADevice(newId, type, settings.copy).prCopyOn(on, newName) }

    prCopyOn { |flag, aName| on = flag == true; aName !? { name = aName.asString } }

    param { |pname| ^settings[pname] }

    // A setting of its own, held to its range (MegaSAFx.constrain). The
    // caller checks the name and the number.
    setParam { |pname, value|
        settings.put(pname, MegaSAFx.constrain(pname, value));
        node !? { |n| this.sendToSynth([15, n.nodeID, pname, settings[pname]]) };
        this.changed(\param, pname, settings[pname]);
    }

    // Has any setting moved off its type's default? Within a millionth: a
    // value that came back through a file or a 32-bit control is no edit.
    edited {
        ^this.params.any { |p|
            var want = p[\spec].default;
            (settings[p[\name]] - want).abs > (want.abs * 1e-6).max(1e-9)
        }
    }

    // Its delay in frames at `sampleRate`: the type's (MegaSAFx.types), or
    // for a plugin the delay its dry path follows (MegaSAPlugin.dryDelay):
    // what it reports, unless that held it off, when its device adds none.
    latency { |sampleRate = 48000|
        ^if(this.isPlugin) { (plugin !? { |p| p.dryDelay }) ? 0 } {
            (this.typeRow !? { |t| t[\latency].value(settings, sampleRate) }) ? 0
        }
    }

    // What its synth takes from the real-time pool (an estimate). A plugin
    // allocates outside it, but its device's dry path is a DelayN on both
    // sides, which VSTPlugin's device SynthDef always has.
    memBytes { |sampleRate = 48000|
        ^if(this.isPlugin) { MegaSAFx.lineBytes((MegaSAPlugin.maxLatency * sampleRate) + 1) * 2 } {
            (this.typeRow !? { |t| t[\memBytes].value(sampleRate) }) ? 0 }
    }

    printOn { |stream| stream << "MegaSADevice(" << id << ", " << type << ")" }
}
