// The plugins megalooper can host: the catalog (docs/dev/device-chains.md, 8.1).
//
// VSTPlugin's own search runs inside the server: it holds the server's queue
// of asynchronous commands for the whole scan and has no timeout by default.
// So megalooper scans without the live server:
//   *scan          an offline scsynth (-N) runs VSTPlugin's search, one plugin
//                  at a time with a timeout each, and writes VSTPlugin's cache
//                  file into the folder it is given (megalooper's own);
//   *read          the language reads that file, with no server;
//   *readCacheMsg  the live server is told to read it too, at boot, which
//                  spares each open its probe as long as the open names the
//                  plugin by its key (VSTPlugin resolves symlinks in every
//                  path, so a path may not match; a key does).
//
// An entry is an Event, data only:
//   key            what an open names
//   name, vendor, version, uid, path
//   format         "vst2" or "vst3" (VSTPlugin hosts no Audio Units)
//   ins, outs      the channels of its main input and output
//   synth          an instrument
//   bridged        built for another CPU: it would run through VSTPlugin's
//                  bridge, in a process of its own
//
// Without VSTPlugin installed there is no catalog: every method answers
// empty or nil, and megalooper hosts no plugin.
MegaSAPlugins {
    // Seconds a plugin gets to answer its probe before the scan gives it up.
    *probeTimeout { ^20 }

    *available { ^\VSTPlugin.asClass.notNil }

    // Whether `cacheDir` holds a scan's result.
    *hasCache { |cacheDir| ^cacheDir.notNil and: { (cacheDir +/+ "cache_*.ini").pathMatch.notEmpty } }

    // The message that scans `dirs` (nil: the system's plugin folders) and
    // writes the cache into `cacheDir`; and the one that has a server read it.
    *searchMsg { |cacheDir, dirs|
        ^\VSTPlugin.asClass !? { |v|
            v.searchMsg(dirs, (save: true, parallel: false, timeout: this.probeTimeout, cacheFileDir: cacheDir), false)
        }
    }

    *readCacheMsg { |cacheDir| ^\VSTPlugin.asClass !? { |v| v.readCacheMsg(cacheDir) } }

    // The scan as a score file for an offline server. Answers whether it was
    // written (not without VSTPlugin).
    *writeScore { |scorePath, cacheDir, dirs|
        var msg = this.searchMsg(cacheDir, dirs);
        if(msg.isNil) { ^false };
        File.mkdir(cacheDir);
        Score([[0.0, msg], [1.0, [\c_set, 0, 0]]]).write(scorePath);
        ^File.exists(scorePath)
    }

    // The offline server's command line: no input, a throwaway sound file,
    // and a port far from the language's and the live server's. What it
    // says goes to `logPath` if one is given: which plugins it probed, and
    // what each answered.
    // The server's program: beside SuperCollider's resources on macOS, on
    // the shell's path elsewhere (Linux installs it in /usr/bin).
    *scsynthPath { |dir|
        var here = (dir ?? { Platform.resourceDir }) +/+ "scsynth";
        ^if(File.exists(here)) { here } { "scsynth" }
    }

    *scanCommand { |scorePath, soundPath, port = 57997, logPath|
        ^this.scsynthPath.shellQuote ++ " -u " ++ port ++ " -N " ++ scorePath.shellQuote
            ++ " _ " ++ soundPath.shellQuote ++ " 48000 WAV int16 -o 1 -i 0"
            ++ if(logPath.notNil) { " > " ++ logPath.shellQuote ++ " 2>&1" } { "" }
    }

    // Where a scan into `cacheDir` leaves what the offline server said.
    *logPath { |cacheDir| ^cacheDir +/+ "scan.log" }

    // Scan, then call `action` with (ok, why). It runs beside megalooper and
    // touches nothing of the live server; `action` comes when it has ended.
    *scan { |cacheDir, dirs, action, port = 57997|
        var stamp = thisProcess.pid.asString ++ "-" ++ UniqueID.next;
        var score = PathName.tmp +/+ "megalooper-scan-" ++ stamp ++ ".osc";
        var sound = PathName.tmp +/+ "megalooper-scan-" ++ stamp ++ ".wav";
        if(this.writeScore(score, cacheDir, dirs).not) { ^action.value(false, "VSTPlugin is not installed") };
        // Its output goes to a file, never to a pipe nobody reads: with the
        // pipe unixCmd gives it, the offline server died at its first line
        // and the scan "ended" at once, with nothing found. And a scan has
        // worked when its catalog is there, whatever the exit code says: a
        // server killed by a signal answers 0 too.
        this.scanCommand(score, sound, port, this.logPath(cacheDir)).unixCmd({ |code|
            [score, sound].do { |f| if(File.exists(f)) { File.delete(f) } };
            case
            { code != 0 } { action.value(false, "the scan ended with code " ++ code ++ " (see " ++ this.logPath(cacheDir) ++ ")") }
            { this.hasCache(cacheDir).not } { action.value(false, "the scan wrote no catalog (see " ++ this.logPath(cacheDir) ++ ")") }
            { action.value(true) };
        }, false);
    }

    // Every plugin the last scan found, as entries sorted by name: read from
    // the cache with no server. Empty with no cache or no VSTPlugin.
    *read { |cacheDir|
        var v = \VSTPlugin.asClass, dict, seen = Set.new;
        if(v.isNil or: { this.hasCache(cacheDir).not }) { ^[] };
        dict = try { v.readPlugins(cacheDir) } { nil };
        ^(dict ? ()).values.asArray.collect { |d| try { this.entryOf(d) } { nil } }
            .select { |e| e.notNil and: { seen.includes(e[\key]).not } and: { seen.add(e[\key]); true } }
            .sort { |a, b| a[\name].toLower <= b[\name].toLower }
    }

    // A VSTPluginDesc as an entry.
    *entryOf { |d|
        var channels = { |busses| ((busses ? []).first !? { |b| b.channels }) ? 0 };
        ^(key: d.key.asString, name: (d.name ? d.key).asString, vendor: (d.vendor ? "").asString,
            version: (d.version ? "").asString, uid: (d.id ? "").asString, path: (d.path ? "").asString,
            format: if((d.sdkVersion ? "").asString.find("VST 3").notNil) { "vst3" } { "vst2" },
            ins: channels.(d.inputs), outs: channels.(d.outputs),
            synth: d.synth == true, bridged: d.bridged == true)
    }

    // What the browser offers of `entries`: effects only, so no instrument
    // and nothing without an input. Of a plugin that is there as a VST3 and
    // as a bridged VST2, the VST3 alone. A bridged one is offered greyed,
    // with \why: megalooper hosts plugins in the server itself for now.
    *offered { |entries|
        var effects = entries.select { |e| e[\synth].not and: { e[\ins] > 0 } };
        var native3 = effects.select { |e| (e[\format] == "vst3") and: { e[\bridged].not } };
        ^effects.reject { |e|
            (e[\format] == "vst2") and: { e[\bridged] } and: { native3.any { |n| this.sameProduct(n, e) } }
        }.collect { |e|
            if(e[\bridged]) {
                e.copy.put(\why, "built for another processor (Intel): it would need VSTPlugin's bridge, which megalooper does not use yet")
            } { e }
        }
    }

    *sameProduct { |a, b|
        ^(a[\name].toLower == b[\name].toLower) and: { a[\vendor].toLower == b[\vendor].toLower }
    }

    // What a sound says its plugin is, as an Event of Strings (key, name,
    // vendor, format, uid, version, path): from the JSON text a sound's file
    // holds, or from what MegaSAPlugin answers. nil for nothing readable.
    *identityOf { |x|
        var o, pick = { |f|
            var e = ();
            #[\key, \name, \vendor, \format, \uid, \version, \path].do { |k| f.(k) !? { |v| e.put(k, v.asString) } };
            e
        };
        ^case
        { x.isNil } { nil }
        { x.isString } {
            o = MegaFiles.parseObject(x);
            if(o.isString) { nil } { pick.({ |k| o.at(k.asString) }) }
        }
        { pick.({ |k| x[k] ?? { x[k.asString] } }) }
    }

    // The entry a sound's plugin names, or nil: not in the catalog (not
    // installed here, or not scanned yet). By its key in its format; else by
    // its uid in its format; else by name, vendor and format, which a plugin
    // moved or installed anew keeps.
    *find { |entries, identity|
        var id = this.identityOf(identity), same;
        if(id.isNil) { ^nil };
        same = { |e, k| id[k].notNil and: { e[k] == id[k] } };
        ^entries.detect { |e| same.(e, \key) and: { id[\format].isNil or: { same.(e, \format) } } }
            ?? { entries.detect { |e| (id[\uid] ? "").notEmpty and: { same.(e, \uid) } and: { same.(e, \format) } } }
            ?? { entries.detect { |e| same.(e, \name) and: { same.(e, \vendor) } and: { same.(e, \format) } } }
    }

    // The layout megalooper hosts an entry in: its main busses, held to the
    // chain's one or two channels. A device may say otherwise (Bias FX, 2->2
    // by its own account, is hosted 1->1 as the Live set did).
    *layoutOf { |entry| ^[entry[\ins].clip(1, 2), entry[\outs].clip(1, 2)] }
}
