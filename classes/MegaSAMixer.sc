// megalooper — Megalooper SA's mixer: one strip per source (the guitar, the
// bass on a rig with a bass input, the loop, the drums, the onset kit, the
// synth), each with its level and the player's mute, then the master to the
// interface and the recorder; and the holds, a strip's reasons for being
// silent apart from the player's mute.
//
// A part of MegaSA (docs/dev/architecture.md 5, step 9; MegaSA's own until
// 2026-11-08): it holds the MegaSA and says its changes as MegaSA's
// (sa.changed: \level, \mute, \hold), so the window, MIDI's send-back and
// the action log hear them as before. MegaSA builds the strips into its
// mixer group (build) and its level, mute and hold methods are the facade.
MegaSAMixer {
    var sa;
    // Amplitude per strip, plus \master. Mutes are per strip only: muting the
    // master is the interface's volume knob.
    var <levels, <mutes;
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
    // The strips' synths by strip, and the master's.
    var <strips, <masterSynth;

    // `bass`: whether the rig has a bass input, which alone gives the bass a
    // strip.
    *new { |sa, bass = false| ^super.newCopyArgs(sa).init(bass) }

    init { |bass|
        // The drums' two strips start where Live's faders were: the drums
        // group at -10.6 dB, the One Hit Kit's track at -15.7 dB.
        // The synth's at -6 dB. The loop's at -3 dB since 2026-11-07, when
        // the Looper level (0.7 before its limiter, into the Loop chain) went
        // and the looper went to unity: the chain hears the loop as played,
        // the mix hears it as loud as before, and a hot take with the drums
        // stays off the master's clip. The values are defaultLevels', below.
        levels = this.class.defaultLevels;
        levels.removeAt(\bass);
        // Every strip starts with the player's mute off. The guitar's is held
        // while its plugin opens (holds, above), and let go once the plugin
        // has answered: open, or failed, in which case dry is better than
        // nothing.
        mutes = (guitar: false, loop: false, drums: false, onsetKit: false, synth: false);
        // The bass has a strip only with an input to play it. A plugin
        // opening on its chain holds nothing: until it is open its device
        // passes the bass through, as the drums' and the loop's do.
        if(bass == true) { levels.put(\bass, this.class.defaultLevels[\bass]); mutes.put(\bass, false) };
        holds = IdentityDictionary.new;
        strips = IdentityDictionary.new;
    }

    // Where every strip starts, megalooper's own (amplitudes; the comment in
    // init says why each): what a start begins with unless levels were kept
    // for the rig (setup-sa.scd, Start with this under Levels), and what
    // Reset there goes back to. A new Event each call: the caller's own.
    *defaultLevels {
        ^(guitar: 1, bass: 1, loop: 0.7079457844, drums: 0.2951209247, onsetKit: 0.1640589684,
            synth: 0.5011872336, master: 1)
    }

    // The guitar held while a plugin on its chain opens, before anything is
    // built (MegaSA's init): nothing is said, nothing listens yet.
    startOpening { |flag|
        if(flag) { holds.put(\guitar, IdentitySet[\opening]) } { holds.removeAt(\guitar) };
    }

    // The strips onto `masterBus`, in order (`busPairs`: strip, bus, ...),
    // each also onto its stem (`stemArgs`, a function of the strip), and the
    // master to the interface and the recorder: at the tail of `group`.
    build { |group, busPairs, masterBus, hwOut, recordBus, stemArgs|
        busPairs.pairsDo { |key, bus|
            strips.put(key, Synth.tail(group, \megaSAStrip, [
                \in, bus.index, \out, masterBus.index,
                \amp, levels[key], \mute, this.muted(key).binaryValue
            ] ++ stemArgs.value(key)));
        };
        masterSynth = Synth.tail(group, \megaSAMaster, [
            \in, masterBus.index, \out, hwOut, \rec, recordBus.index,
            \amp, levels[\master]
        ]);
    }

    free {
        strips.do(_.free);
        masterSynth !? (_.free);
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
            this.node(key) !? { |n| n.set(\amp, levels[key]) };
            sa.changed(\level, key, levels[key]);
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
                sa.changed(\hold, key, this.held(key));
            };
            this.sendMute(key);
            sa.changed(\mute, key, mutes[key]);
        };
    }

    node { |key| ^if(key == \master) { masterSynth } { strips[key] } }

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
            this.sendMute(key);
            sa.changed(\hold, key, this.held(key));
        };
    }

    unhold { |key, reason|
        var set = holds !? { |h| h[key] };
        if(set.notNil and: { set.includes(reason) }) {
            set.remove(reason);
            this.sendMute(key);
            sa.changed(\hold, key, this.held(key));
        };
    }

    sendMute { |key|
        strips !? { |s| s[key] !? { |n| n.set(\mute, this.muted(key).binaryValue) } };
    }
}
