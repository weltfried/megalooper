// Records the whole set to disk, from the stomp, with no relationship to the
// transport at all.
//
// WHY THIS IS NOT DONE IN LIVE. Live's 1.1.1 is defined by the first loop:
// megalooper is the phase master and cannot send MIDI Start until it knows the
// tempo and where the downbeat falls, which it cannot know until a take has
// been committed. So Live's arrangement cannot contain the playing that
// PRODUCED the first loop — there is no grid to record it against yet, and a
// MIDI Start arriving later would relocate Live to its cue point and overwrite
// whatever had been captured. A recorder that answers to nothing but a
// footswitch sidesteps the whole argument (docs/dev/roadmap.md, "Record the set").
//
// THE FILES, because they are read by different people:
//
//   …-master.wav   what the room heard. Stereo, from `mixChannel` — Live's
//                  master, routed back to a spare input pair, or Megalooper
//                  SA's own mix. NOT SC's output on a Live rig: that is the
//                  loop alone, without the guitar, the drum racks or anything
//                  else Live adds.
//   …-tap.wav      the dry guitar, mono, from the same clean analysis tap the
//                  onset detector reads. Nobody listens to this one. It exists
//                  so detection can be re-run offline at any threshold — every
//                  gig becomes labelled corpus, which is the largest lever on
//                  meter detection that does not involve touching
//                  MeterAnalyzer.
//   …-<stem>.wav   on Megalooper SA, the parts of the mix as they were heard
//                  (`stems`, from MegaSA: the guitar, the loop, the drums, the
//                  onset kit), post-fader, so they sum to the master. A set can
//                  be mixed again without the instrument that played it.
//   …-events.jsonl what happened, one JSON object per line: every record
//                  press, every take with the onsets it was analysed from and
//                  the readings it was offered, every next-reading press and
//                  where it landed, every threshold change, and on SA every
//                  drum hit that sounded and the drums' transport. Times are
//                  seconds from the stomp; the `audio` line says where the
//                  WAVs' frame 0 sits on that axis, and the `files` event where
//                  they end, how many frames they hold and how fast the
//                  interface's clock ran against the Mac's (see wavTime).
//                  Without it the tap is audio
//                  nobody can place a take in, and the eight sets recorded
//                  before it existed are exactly that. Looper writes it through
//                  `logEvent`, the drums through `logHits`; `readEvents` and
//                  `takesFrom` turn it back into labelled takes for
//                  scripts/replay-session.scd.
//   …-drums.mid    on SA, the drum hits as a MIDI file (LooperMidiFile), for
//                  Live's racks: see "The MIDI file" below.
//
// THE NAMES carry the set's tempo and time signature, so the set can be taken
// into Live and Live set from the file name:
//
//     261007_143012-165.04bpm-7-8-master.wav
//
// The tempo is not known when the set starts — the first loop has not been
// played yet — so every file is opened under its stamp
// (261007_143012-master.wav) and renamed when the set stops (see stop). A set
// in which no tempo was ever in force keeps the stamp names.
//
// The master and the tap are int24 WAV: this is an archive, and the extra byte
// per sample costs 50% of a disk that a set does not come close to filling;
// neither can pass full scale (the master is recorded after its clip, the tap is
// a converter's input). The stems are 32-bit float WAV: a strip runs after its
// fader (up to +6 dB) and before the master's level and clip, so a hot one is
// over full scale on its bus while the room hears it clean, and int24 would
// flat-top it there. Float keeps what the bus held, so the stems still sum to
// the master.
//
// Either input channel may be nil on a rig that lacks it, and the files that
// can be are written rather than none. What is NOT allowed is starting with
// nothing at all, because a session recorder that silently records nothing is
// worse than one that refuses.
LooperSessionRecorder {
    // DiskOut's ring buffer, in frames. Must be a power of two and at least
    // twice the hardware block size; 65536 is the size SC's own examples use
    // and is about 1.4 s of slack at 48 k, which is far more than a language
    // hiccup can cost a disk-writing thread.
    classvar <>bufFrames = 65536;
    // How far ahead the one bundle that starts every file is stamped, and the
    // one that ends them. Every DiskOut synth starts in the same control
    // block, so frame 0 is one moment in every file and the stems line up with
    // the master to the sample; every one ends in the same block too. The
    // server's own default latency, which is what a bundle sent from the
    // language needs to arrive before its time.
    classvar <>startLatency = 0.2;
    // From the moment the synths are freed (stopAt) to closing the files: the
    // last of each WAV has to reach the disk first, and closing underneath it
    // truncates the tail. Far longer than that takes, and by then every drum
    // hit heard before stopAt has been told to the log too (MegaSADrums tells
    // a hit logLag after it is heard). Paid once per set.
    classvar <>closeWait = 0.3;
    // How long a stop waits for the server to say the files are closed before
    // it reads their length (see prSync): a server that does not answer in
    // that time is gone, and the set is finished without it.
    classvar <>syncTimeout = 2;
    // An onset hit's note length when the drums do not say (the Looper's
    // onsetNoteGateMs default), in seconds.
    classvar <>onsetGate = 0.02;

    var <server;
    // Where the files go. A var rather than a constructor argument so a rig can
    // move it between sets without rebuilding anything. A set keeps the folder
    // it started in.
    var <>dir;
    var <recording = false;
    // Wall-clock start, for the elapsed-time readout. SystemClock.seconds, like
    // every other "when did this happen" in Looper. Also the zero of the event
    // log's time axis.
    var <startedAt, <stoppedAt;
    // The set's stamp, the start of every name: the date and time of the
    // stomp, with -2, -3 after it for a second set started in the same second.
    var <stamp;
    // role -> path of every file of the set being recorded (or of the last
    // one): \master, \tap, each stem's role, \events, and \midi once written.
    // Where each file IS: the stamp names until the stop has renamed them.
    var <paths;
    // role -> path decided at the stop, the names the files are given.
    var <finalPaths;
    // False from the stop until the files have their final names (or failed
    // to get them), so a view can tell the names decided from the names on disk.
    var <settled = true;
    // The parts of the mix recorded beside the master: an Array of Events
    // (role:, channel: a SoundIn channel, numChannels: 1 or 2). Empty on a Live
    // rig; Megalooper SA sets it (MegaSA.stemSpecs). Read at start, so a set
    // keeps the stems it started with.
    var <stems;
    // The moment the DiskOut synths start, on the same clock as every event:
    // the timestamp of the bundle that starts them. DiskOut records whole
    // control blocks, from the start of the block that bundle runs in, so the
    // WAVs' frame 0 is up to a block before it (frame0Lead).
    var <audioAt;
    // The moment they end: the timestamp of the bundle that frees them,
    // startLatency after the stop (see stop). nil until a set stops.
    var <stopAt;
    // What the last set's WAVs said once closed: how many frames they hold,
    // and the interface's clock against the Mac's that makes (clockRate); nil
    // until measured, and the rate nil when the length said nothing.
    var <wavFrames, <clockRate;
    // Called with this recorder after every state change, so a view can follow
    // without this class knowing one exists — the same contract Looper's
    // onMonitor uses.
    var <>onChange;
    // Where the recording synths go: nil is the tail of the default group, as
    // always. Megalooper SA records its mixer's output, which is written after
    // the default group, so it points this at a group after its mixer — read any
    // earlier in the block, the bus would still be empty.
    var <>target;
    // The set's tempo and signature, decided once it has ended (chosenTempo,
    // see prSettleLog), and the sentence the stop says about it for Live.
    var <tempoInfo, <liveHint;
    // What the log has been told this set, kept for the end: every drum hit
    // that sounded (for the MIDI), the markers (the drums' transport), the
    // drums' segments and the first analysis that applied (for the tempo).
    // A start makes them NEW Lists, never clears the old ones: a set that has
    // just stopped still holds those (its `set`) until its .mid is written.
    var <loggedHits, <markers, <drumsTempos, <analysisTempo;
    // The set that has stopped while its log is still open (its tail, from the
    // stop until its WAVs have ended: see stop), as stop's `set`; nil otherwise.
    var closing;
    // The set's files while it records: Events (role:, path:, channel:,
    // numChannels:, buf:, synth:).
    var files;
    // Shared with the routine that opens the files, so the stop can wait for
    // it: (flag: true) until it is done.
    var starting;
    // The event log, open while a set is being recorded and until its WAVs
    // have ended (closing).
    var logFile;

    *new { |server, dir|
        ^super.new.initLooperSessionRecorder(server, dir)
    }

    initLooperSessionRecorder { |srv, d|
        server = srv;
        dir = d;
        stems = [];
        files = List.new;
        loggedHits = List.new;
        markers = List.new;
        drumsTempos = List.new;
    }

    // Two defs rather than one with a channel count, for the same reason Looper
    // instantiates its recorder graph twice: SoundIn's channel count is fixed
    // when the graph is built, so it can never be an argument. The stereo one
    // records the master and every stereo stem, the mono one the tap and every
    // mono stem.
    *loadSynthDefs {
        SynthDef(\looperSessionMaster, { |bufnum, ch = 0|
            DiskOut.ar(bufnum, SoundIn.ar([ch, ch + 1]));
        }).add;
        SynthDef(\looperSessionTap, { |bufnum, ch = 0|
            DiskOut.ar(bufnum, SoundIn.ar(ch));
        }).add;
    }

    *defFor { |numChannels| ^if(numChannels == 1) { \looperSessionTap } { \looperSessionMaster } }

    // ===================================================================
    // Names
    // ===================================================================
    // Pure, so the naming can be checked without a server — and so the GUI can
    // show where a recording WILL land before it is started.

    // The paths a set started now would open, under its stamp: the master, the
    // tap and the log, plus a WAV for each of `roles` (the stems).
    *pathsFor { |dir, stamp, roles|
        var out = (
            master: dir +/+ this.nameFor(stamp, nil, "master", "wav"),
            tap:    dir +/+ this.nameFor(stamp, nil, "tap", "wav"),
            events: dir +/+ this.nameFor(stamp, nil, "events", "jsonl")
        );
        (roles ? []).do { |r| out.put(r.asSymbol, dir +/+ this.nameFor(stamp, nil, r, "wav")) };
        ^out
    }

    // A role's name part and extension: the log is .jsonl, the MIDI file is
    // the drums' .mid (role \midi, beside the drums' .wav), everything else a
    // .wav named for its role.
    *fileOf { |role|
        ^switch(role.asSymbol,
            \events, { ["events", "jsonl"] },
            \midi,   { ["drums", "mid"] },
            { [role.asString, "wav"] })
    }

    // <stamp>-<bpm>bpm-<num>-<den>-<role>.<ext>, or <stamp>-<role>.<ext> when
    // there is no tempo to name.
    *nameFor { |stamp, tempoInfo, role, ext|
        var label = tempoInfo !? { |t| this.tempoLabel(t[\bpm], t[\numerator], t[\denominator]) };
        ^stamp.asString ++ (label !? { |l| "-" ++ l } ? "") ++ "-" ++ role.asString ++ "." ++ ext.asString
    }

    // "165.04bpm-7-8": the tempo with exactly two decimals, which is Live's
    // tempo precision (so the number can be typed in as it reads), and the
    // signature. nil for anything that is not a tempo and a signature.
    *tempoLabel { |bpm, num, den|
        if(bpm.isNumber.not or: { num.isNumber.not } or: { den.isNumber.not }) { ^nil };
        if((bpm != bpm) or: { bpm <= 0 } or: { bpm == inf } or: { num < 1 } or: { den < 1 }) { ^nil };
        ^this.bpmString(bpm) ++ "bpm-" ++ num.asInteger ++ "-" ++ den.asInteger
    }

    // The tempo as Live can hold it: 0.01 BPM. The file name, the MIDI file's
    // tempo and the ticks of every note in it all use this one number.
    *roundBpm { |bpm| ^(bpm * 100).round / 100 }
    *bpmString { |bpm| ^this.fixed(this.roundBpm(bpm), 2) }

    // `x` with exactly `decimals` decimals: 165 is "165.00", 0.3829 is
    // "0.383". Float:asString drops trailing zeros, and a file name that is
    // sometimes 165.0 and sometimes 165.04 sorts and reads badly.
    *fixed { |x, decimals = 2|
        var scale = 10 ** decimals;
        var n = (x.abs * scale).round;
        var whole = (n / scale).floor;
        var frac = (n - (whole * scale)).round.asInteger;
        ^(if((x < 0) and: { n > 0 }) { "-" } { "" }) ++ whole.asInteger.asString
            ++ (if(decimals > 0) { "." ++ frac.asString.padLeft(decimals, "0") } { "" })
    }

    // The paths a stopping set's files are given, role -> path. Never a name
    // that is already taken, apart from by the set's own files (`own`: a set
    // with no tempo keeps its names, and they are its own): if any is, the
    // whole set moves to <stamp>-2, then -3, so its files keep one stamp and
    // stay together.
    *finalPaths { |dir, stamp, tempoInfo, roles, own|
        var mine = (own ? []).collect(_.asString);
        var n = 1, s, out, taken;
        while {
            s = if(n == 1) { stamp.asString } { stamp.asString ++ "-" ++ n };
            out = ();
            roles.do { |role|
                var f = this.fileOf(role);
                out.put(role.asSymbol, dir +/+ this.nameFor(s, tempoInfo, f[0], f[1]));
            };
            taken = out.values.any { |p| File.exists(p) and: { mine.includesEqual(p).not } };
            taken and: { n < 100 }
        } {
            n = n + 1;
        };
        ^out
    }

    // A stamp no file in `dir` uses yet: `stamp`, or stamp-2, -3 when a set
    // was started in the same second (a double stomp). Without it the second
    // set's files would open over the first's while they are still being
    // written.
    *freshStamp { |dir, stamp|
        var n = 1, s = stamp.asString;
        while { (this.globQuote(dir +/+ s) ++ "-*").pathMatch.notEmpty and: { n < 100 } } {
            n = n + 1;
            s = stamp.asString ++ "-" ++ n;
        };
        ^s
    }

    // `path` with what glob(3) reads as a pattern made literal, for the
    // folder part of a pathMatch: sclang globs with GLOB_QUOTE on macOS, so a
    // backslash makes the next character itself. Without it a sessions folder
    // under "Gigs [2026]" (a character class) or a backslash finds nothing.
    *globQuote { |path|
        var out = "";
        path.asString.do { |c|
            if("[]*?\\".includes(c)) { out = out ++ "\\" };
            out = out ++ c.asString;
        };
        ^out
    }

    // A session file's name taken apart: (stamp:, role:, ext:), plus bpm:,
    // numerator: and denominator: when it carries a tempo; nil when it is no
    // name of this shape. How a reader finds a set's files by stamp whatever
    // tempo they were renamed with.
    *parseName { |name|
        var base = name.asString.basename;
        var dot = base.findBackwards(".");
        var ext, parts, i;
        if(dot.isNil or: { dot == 0 }) { ^nil };
        ext = base.copyToEnd(dot + 1);
        parts = base.copyRange(0, dot - 1).split($-);
        if(parts.size < 2) { ^nil };
        i = parts.detectIndex { |p| this.prBpmToken(p) };
        if(i.notNil and: { i >= 1 } and: { parts.size == (i + 4) }
            and: { this.prDigits(parts[i + 1]) } and: { this.prDigits(parts[i + 2]) }) {
            ^(stamp: parts.copyRange(0, i - 1).join("-"), bpm: parts[i].drop(-3).asFloat,
                numerator: parts[i + 1].asInteger, denominator: parts[i + 2].asInteger,
                role: parts[i + 3], ext: ext)
        };
        ^(stamp: parts.copyRange(0, parts.size - 2).join("-"), role: parts.last, ext: ext)
    }

    *prBpmToken { |s|
        ^s.endsWith("bpm") and: { s.size > 3 } and: {
            s.drop(-3).every { |c| c.isDecDigit or: { c == $. } } } and: { s.drop(-3).any(_.isDecDigit) }
    }
    *prDigits { |s| ^s.notEmpty and: { s.every(_.isDecDigit) } }

    // ===================================================================
    // Stems
    // ===================================================================

    // Each spec is checked and a bad one is left out with a warning, so one
    // wrong entry costs that stem rather than the set.
    stems_ { |specs|
        var kept = List.new, seen = IdentitySet.new, why;
        (specs ? []).do { |sp|
            why = LooperSessionRecorder.stemProblem(sp, seen);
            if(why.notNil) {
                ("Session recording: a stem was left out (" ++ why ++ ").").warn;
            } {
                seen.add(sp[\role].asSymbol);
                kept.add((role: sp[\role].asSymbol, channel: sp[\channel].asInteger,
                    numChannels: sp[\numChannels].asInteger));
            };
        };
        stems = kept.asArray;
    }

    // Why a stem spec cannot be recorded, as a phrase, or nil. Its role names
    // its file, so it is one plain word, none of the recorder's own and not
    // twice; its channel is a SoundIn channel, never negative (no negative bus
    // index may reach the server); one or two channels.
    *stemProblem { |spec, seen|
        var role, ch, n;
        if(spec.isKindOf(Dictionary).not) { ^"not an Event: " ++ spec };
        role = spec[\role];
        ch = spec[\channel];
        n = spec[\numChannels];
        if(role.isNil or: { role.asString.isEmpty } or: { role.asString.every(_.isAlphaNum).not }) {
            ^"its role must be one plain word, not " ++ role
        };
        if(#[\master, \tap, \events, \midi].includes(role.asSymbol)) {
            ^role.asString ++ " is one of the recorder's own files"
        };
        if(seen.notNil and: { seen.includes(role.asSymbol) }) { ^role.asString ++ " is there twice" };
        if(ch.isNumber.not or: { ch < 0 }) { ^role.asString ++ ": no SoundIn channel (" ++ ch ++ ")" };
        if((n != 1) and: { n != 2 }) { ^role.asString ++ ": 1 or 2 channels, not " ++ n };
        ^nil
    }

    // ===================================================================
    // Start and stop
    // ===================================================================

    // Why a start would be refused, as a sentence, or nil if it would not.
    // Split out from `start` so every refusal is testable without a server and
    // so the button can explain itself before it is pressed.
    prRefusal { |masterChannel, tapChannel|
        if(recording) { ^"already recording" };
        if(dir.isNil) { ^"no session directory set" };
        if(masterChannel.isNil and: { tapChannel.isNil } and: { stems.isEmpty }) {
            ^"this rig has neither a session input nor an analysis tap — "
            "there would be nothing to record"
        };
        ^nil
    }

    // Start every file. Returns false and says why if it will not. `context`
    // is what the looper knows as the set begins — threshold, channels, the
    // fallback meter, a loop already in force — and goes into the log's header.
    //
    // Asynchronous by necessity: a DiskOut synth must not exist before its
    // buffer has been opened for writing, so the synths are created after a
    // sync. `recording` is set HERE rather than in the routine, so a stop
    // arriving in the gap is seen by the routine and honoured — the same
    // wanted/exists split startAnalysisMonitor uses. `inline` runs that half on
    // the calling thread, which must then be a Routine: the tests step it on a
    // stub server.
    start { |masterChannel, tapChannel, context, inline = false|
        var refusal = this.prRefusal(masterChannel, tapChannel);
        var mine, flag;
        if(refusal.notNil) {
            ("Session recording: " ++ refusal ++ ".").warn;
            ^false
        };
        // The last set stopped a moment ago and its log is still open (its
        // tail): it ends now, decided with what it has been told so far, so
        // this set can have the log. Its WAVs, its names and its .mid finish
        // as they would have (prFinish).
        closing !? { |set| this.prSettleLog(set) };
        if(File.exists(dir).not) { File.mkdir(dir) };
        stamp = LooperSessionRecorder.freshStamp(dir, Date.getDate.stamp);
        mine = List.new;
        masterChannel !? { |ch| mine.add((role: \master, channel: ch, numChannels: 2)) };
        tapChannel !? { |ch| mine.add((role: \tap, channel: ch, numChannels: 1)) };
        stems.do { |sp|
            mine.add((role: sp[\role], channel: sp[\channel], numChannels: sp[\numChannels], stem: true));
        };
        paths = ();
        mine.do { |f|
            f.put(\path, dir +/+ LooperSessionRecorder.nameFor(stamp, nil, f[\role], "wav"));
            paths.put(f[\role], f[\path]);
        };
        paths.put(\events, dir +/+ LooperSessionRecorder.nameFor(stamp, nil, "events", "jsonl"));
        files = mine;
        finalPaths = nil;
        settled = true;
        tempoInfo = nil;
        liveHint = nil;
        loggedHits = List.new;
        markers = List.new;
        drumsTempos = List.new;
        analysisTempo = nil;
        startedAt  = SystemClock.seconds;
        stoppedAt  = nil;
        audioAt    = nil;
        stopAt     = nil;
        wavFrames  = nil;
        clockRate  = nil;
        recording  = true;
        starting = (flag: true);
        flag = starting;
        this.prChanged;
        this.prOpenLog(paths[\events]);
        this.prLogHeader(stamp, masterChannel, tapChannel, context);
        if(inline) { this.prOpenAudio(mine, flag) } {
            Routine { this.prOpenAudio(mine, flag) }.play(SystemClock)
        };
        ^true
    }

    // The files, then the synths. Every buffer is allocated and opened before
    // any synth exists, and then every synth starts from ONE bundle, stamped
    // `startLatency` ahead: the server starts them all in the same control
    // block, so frame 0 is one moment in every file — the stems line up with
    // the master to the sample — and audioAt, the bundle's own stamp, is that
    // moment on the log's clock, to the block (frame0Lead). The stems are
    // float, the master and the tap int24 (see the header).
    prOpenAudio { |mine, flag|
        var msgs;
        mine.do { |f| f.put(\buf, Buffer.alloc(server, LooperSessionRecorder.bufFrames, f[\numChannels])) };
        server.sync;
        mine.do { |f|
            f[\buf].write(f[\path], "wav", if(f[\stem] == true) { "float" } { "int24" }, 0, 0, true)
        };
        server.sync;
        // A stop in the gap (or a stop and a new start): undo the allocation
        // rather than starting synths nobody asked for.
        if(recording and: { mine === files }) {
            msgs = mine.collect { |f|
                var synth = Synth.basicNew(LooperSessionRecorder.defFor(f[\numChannels]), server);
                f.put(\synth, synth);
                synth.newMsg(target ? server, [\bufnum, f[\buf].bufnum, \ch, f[\channel]], \addToTail)
            }.asArray;
            audioAt = SystemClock.seconds + LooperSessionRecorder.startLatency;
            server.sendBundle(LooperSessionRecorder.startLatency, *msgs);
            this.logEvent(\audio, (), audioAt);
            ("Session recording started:"
                ++ (mine.collect { |f| f[\path] } ++ [paths[\events]]).collect { |p| "\n  " ++ p }.join).postln;
        } {
            this.prCloseFiles(mine);
        };
        flag.put(\flag, false);
    }

    // Stop. The WAVs end the way they began: ONE bundle frees every DiskOut
    // synth, stamped startLatency ahead, so they all end in the same control
    // block, at a moment known on the log's clock (stopAt) — which is what
    // lets the WAVs' length say how fast the interface's clock ran (see
    // clockRate) — and always after the start's bundle, even for a stop inside
    // its latency (an immediate free would reach the server first, find no
    // node, and leave the DiskOuts writing into the next set's buffers).
    //
    // Until stopAt the files are still recording, so the set is still
    // happening: its log stays open (its tail, `closing`) and keeps what the
    // drums tell it about those last moments, a hit logLag after it is heard.
    // Nothing is decided here: once the WAVs have ended and the server has let
    // go of them, the set's tempo and names are decided from everything that
    // sounded in them, the log gets its last words and every file its name
    // (prFinish). `inline` as start's.
    stop { |inline = false|
        var frees, set;
        if(recording.not) { ^false };
        recording = false;
        stoppedAt = SystemClock.seconds;
        // Marked as recording with no set behind it (a test does that): there
        // is nothing to name or to close.
        if(paths.isNil or: { paths[\events].isNil }) { this.prChanged; ^true };
        // sendBundle stamps from the same logical time, so stopAt is the
        // bundle's own stamp, and never before audioAt (that was stamped from
        // an earlier moment, the same latency ahead).
        stopAt = stoppedAt + LooperSessionRecorder.startLatency;
        frees = files.collect { |f| f[\synth] !? { |x| x.freeMsg } }.reject(_.isNil).asArray;
        if(frees.notEmpty) { server.sendBundle(LooperSessionRecorder.startLatency, *frees) };
        files.do { |f| f.put(\synth, nil) };
        finalPaths = nil;
        settled = false;
        set = (stamp: stamp, files: files, paths: paths, hits: loggedHits, markers: markers,
            audioAt: audioAt, startedAt: startedAt, stoppedAt: stoppedAt, stopAt: stopAt,
            starting: starting);
        closing = set;
        this.prChanged;
        if(inline) { this.prFinish(set) } { Routine { this.prFinish(set) }.play(SystemClock) };
        ^true
    }

    // The stop's second half, in a routine of its own: everything it touches
    // is in `set`, so a new set started meanwhile is left alone.
    prFinish { |set|
        var waited = 0;
        // A start whose files were still opening when the stop came finishes
        // first (it closes them itself); five seconds is a server that is gone.
        while { (set[\starting] !? { |s| s[\flag] } ? false) and: { waited < 5 } } {
            0.05.wait;
            waited = waited + 0.05;
        };
        // Until the synths are freed, and closeWait more.
        (((set[\stopAt] - SystemClock.seconds).max(0)) + LooperSessionRecorder.closeWait).wait;
        this.prCloseFiles(set[\files]);
        this.prMeasureClock(set);
        this.prSettleLog(set);
        this.prRename(set);
        this.prWriteMidi(set);
        if(paths === set[\paths]) { settled = true };
        this.prPostStop(set);
        this.prChanged;
    }

    // The set's end, once everything that sounded in it has been told (from
    // prFinish), or now, for a set started meanwhile that needs the log (from
    // start): its tempo and signature (chosenTempo, up to stopAt), every
    // file's final name and what to tell Live. The log gets a last `files`
    // event saying so — role -> the name each file will have, the tempo, the
    // hint, bar 1 and the shift, where the WAVs end (audioEnd), their length
    // and the clock they were measured to run at — and `sessionStop`, and is
    // closed. Once only. Called only while this recorder's tempo, hits and
    // log are still the set's: a start calls it before it resets them.
    prSettleLog { |set|
        var tempo, bar1, hint, roles, fp, names, fields;
        var clock = (rate: set[\rate] ? 1, lead: set[\lead] ? 0);
        if(set[\logSettled] == true) { ^this };
        set[\logSettled] = true;
        if(closing === set) { closing = nil };
        tempo = this.chosenTempo(set[\stopAt] ? set[\stoppedAt]);
        bar1 = LooperSessionRecorder.bar1Of(tempo, set[\audioAt]);
        hint = LooperSessionRecorder.liveHint(tempo, bar1, clock);
        roles = set[\files].collect { |f| f[\role] }.asArray ++ [\events];
        if(LooperSessionRecorder.hasNotes(set[\hits])) { roles = roles ++ [\midi] };
        fp = LooperSessionRecorder.finalPaths(set[\paths][\events].dirname, set[\stamp], tempo, roles,
            set[\paths].values.asArray);
        set.put(\tempo, tempo).put(\hint, hint).put(\finalPaths, fp);
        if(paths === set[\paths]) {
            tempoInfo = tempo;
            liveHint = hint;
            finalPaths = fp;
        };
        names = ();
        fp.keysValuesDo { |role, p| names.put(role, p.basename) };
        fields = (files: names);
        hint !? { |h| fields.put(\liveHint, h) };
        tempo !? { |t| fields.put(\tempo, LooperSessionRecorder.tempoForLog(t)) };
        if(bar1.notNil) {
            fields.put(\bar1, bar1.round(0.001));
            fields.put(\firstBar, LooperSessionRecorder.wavTime(
                LooperSessionRecorder.firstBarLine(tempo, bar1), 0, clock).round(0.001));
            fields.put(\shift, LooperSessionRecorder.liveShift(tempo, bar1, clock).round(0.001));
        };
        if(set[\audioAt].notNil) { set[\stopAt] !? { |t| fields.put(\audioEnd, (t - set[\startedAt]).round(0.0001)) } };
        set[\frames] !? { |n| fields.put(\frames, n) };
        set[\rate] !? { |r|
            fields.put(\clockPpm, ((r - 1) * 1e6).round(0.01));
            // How closely a set this long can tell: a block over its length.
            fields.put(\clockPpmRes, LooperSessionRecorder.clockResolution(set[\audioAt], set[\stopAt],
                server !? { |s| s.sampleRate }, LooperSessionRecorder.blockSizeOf(server)).round(0.1));
        };
        this.prWrite(\files, fields, set[\stoppedAt]);
        this.prWrite(\sessionStop, (elapsed: set[\stoppedAt] - set[\startedAt]), set[\stoppedAt]);
        this.prCloseLog;
        this.prChanged;
    }

    // How the set's WAVs place a moment of the log's clock (wavTime): frame 0
    // half a block before audioAt (frame0Lead), and the interface's clock from
    // their length once the server has closed them (clockRate). Into `set`, as
    // lead:, frames: and rate:. Every WAV of a set has the same length, so the
    // longest is read: one cut short (a disk that could not keep up) is said,
    // not taken for the clock.
    prMeasureClock { |set|
        var lengths, bs = LooperSessionRecorder.blockSizeOf(server);
        set[\lead] = LooperSessionRecorder.frame0Lead(server);
        if(set[\audioAt].isNil) { ^this };
        if(this.prSync.not) {
            "Session recording: the server did not say the files were closed; the .mid assumes the interface's clock is the Mac's.".warn;
            ^this
        };
        lengths = set[\files].collect { |f| LooperSessionRecorder.wavFrames(f[\path]) }.reject(_.isNil);
        if(lengths.notEmpty and: { (lengths.maxItem - lengths.minItem) > bs }) {
            ("Session recording: the set's WAVs are not all as long (" ++ lengths.minItem ++ " to "
                ++ lengths.maxItem ++ " frames); one may have been cut short. The clock is read from the longest.").warn;
        };
        set[\frames] = if(lengths.isEmpty) { nil } { lengths.maxItem };
        set[\rate] = LooperSessionRecorder.clockRate(set[\frames], set[\audioAt], set[\stopAt],
            server.sampleRate, bs);
        if(paths === set[\paths]) {
            wavFrames = set[\frames];
            clockRate = set[\rate];
        };
    }

    // Every command sent before now carried out (the WAVs' closes, so their
    // headers hold their lengths), from a Routine, by the server's /synced
    // within syncTimeout: true when it came. Server:sync waits for ever, and a
    // stop must not hang on a server that is gone. Anything that is not a
    // Server (a test's stub) is asked its own sync.
    prSync {
        var cond, done = false;
        if(server.isKindOf(Server).not) { server.sync; ^true };
        cond = Condition(false);
        Routine { server.sync; done = true; cond.test = true; cond.signal }.play(SystemClock);
        SystemClock.sched(LooperSessionRecorder.syncTimeout, { cond.test = true; cond.signal; nil });
        cond.wait;
        ^done
    }

    prCloseFiles { |list|
        list.do { |f|
            f[\buf] !? { |b| b.close; b.free };
            f.put(\buf, nil);
        };
    }

    // Every file of the set to its final name, through one shell. A move never
    // overwrites (mv -n, and a name found taken is not tried); a file still
    // being written when it is renamed keeps being written, since the server
    // writes through its handle and not its name. A file that cannot be moved
    // keeps its stamp name and the post window says so: the `files` event
    // already names where it was meant to go, and every reader looks under
    // both. Answers how many failed.
    //
    // The moves are written to the shell's stdin rather than given as one
    // command line: String:systemCmd copies its command into a buffer of about
    // a thousand characters, and a set's eight moves of two long paths each
    // are longer than that, cut off mid-quote. Pipe:close waits for the shell,
    // so the files are where they will be when this returns, some tens of ms
    // later.
    prRename { |set|
        var moves = List.new, failed = List.new, shell;
        set[\finalPaths].keysValuesDo { |role, dst|
            var src = set[\paths][role];
            if(src.notNil and: { src != dst }) { moves.add([role, src, dst]) };
        };
        moves = moves.reject { |m|
            var why = case
                { File.exists(m[1]).not } { "it is not on disk" }
                { File.exists(m[2]) } { "that name is taken" }
                { nil };
            why !? { |w| failed.add(m ++ [w]) };
            why.notNil
        };
        if(moves.notEmpty) {
            shell = Pipe.new("sh", "w");
            if(shell.isOpen) {
                moves.do { |m| shell.write("mv -n " ++ m[1].shellQuote ++ " " ++ m[2].shellQuote ++ " 2>/dev/null\n") };
                shell.close;
            };
        };
        moves.do { |m|
            if(File.exists(m[2]) and: { File.exists(m[1]).not }) {
                set[\paths].put(m[0], m[2]);
            } {
                failed.add(m ++ ["the move did not happen"]);
            };
        };
        failed.do { |m|
            ("Session recording: " ++ m[1].basename ++ " was not renamed to " ++ m[2].basename
                ++ " (" ++ m[3] ++ "); it keeps its stamp name.").warn;
        };
        ^failed.size
    }

    // The set's MIDI file (midiTracks) under its final name, if the set has a
    // note for it. Built and written a few hundred notes at a time
    // (prBreathe): a long set is tens of thousands, and the drums may still be
    // playing when it stops.
    prWriteMidi { |set|
        var path = set[\finalPaths][\midi];
        var tempo = set[\tempo];
        var pace = { LooperSessionRecorder.prBreathe };
        var built, ok;
        if(path.isNil) { ^this };
        if(tempo.isNil) {
            "Session recording: no tempo was in force in this set; its .mid is at 120 BPM, 4/4.".warn;
            tempo = (bpm: 120, numerator: 4, denominator: 4, from: \none);
        };
        if(File.exists(path)) {
            path = path.dirname +/+ LooperSessionRecorder.nameFor(set[\stamp], nil, "drums", "mid");
            if(File.exists(path)) {
                ("Session recording: " ++ set[\finalPaths][\midi].basename ++ " and " ++ path.basename
                    ++ " are both taken; no .mid was written.").warn;
                ^this
            };
            ("Session recording: " ++ set[\finalPaths][\midi].basename ++ " is taken; the set's .mid is "
                ++ path.basename ++ ".").warn;
        };
        // A hit heard between the stomp and frame 0 is in the log, not in the
        // WAVs, so not here either (`early`): a set started while the drums
        // play always has some, and that is no news.
        built = LooperSessionRecorder.midiTracks(set[\stamp], tempo, set[\audioAt] ? set[\startedAt],
            set[\hits], set[\markers], set[\stopAt] ? set[\stoppedAt], pace,
            (rate: set[\rate] ? 1, lead: set[\lead] ? 0));
        ok = LooperMidiFile.write(path, built[\tracks], nil, built[\endTick], pace);
        if(ok) { set[\paths].put(\midi, path) };
    }

    // One line per file, where it is now, then what to set Live to, then the
    // clock the WAVs ran on.
    prPostStop { |set|
        var order = set[\files].collect { |f| f[\role] }.asArray ++ [\events, \midi];
        var shown = order.collect { |r| set[\paths][r] }.select { |p| p.notNil and: { File.exists(p) } };
        ("Session recording stopped (" ++ (set[\stoppedAt] - set[\startedAt]).round(0.1) ++ " s):"
            ++ shown.collect { |p| "\n  " ++ p }.join).postln;
        (set[\hint] ?? {
            "No tempo was in force while this set was recorded, so its files keep their stamp names."
        }).postln;
        LooperSessionRecorder.clockSentence(set[\rate], set[\frames], set[\audioAt], set[\stopAt],
            server !? { |s| s.sampleRate }, LooperSessionRecorder.blockSizeOf(server)) !? { |s| s.postln };
    }

    // Lets the rest of the language run, from a Routine: the drums decide their
    // hits a tenth of a second ahead from a SystemClock routine, which must get
    // its turn while a set's MIDI file is built. Rescheduled from NOW, not from
    // this routine's logical time, which lags behind while it computes.
    *prBreathe {
        if(thisThread.isKindOf(Routine)) {
            ((Main.elapsedTime - thisThread.seconds).max(0) + 0.001).wait;
        };
    }

    // Seconds captured: counting while it runs, and FROZEN at the final length
    // once stopped, so the readout keeps saying how long the set was instead of
    // counting on into a recording that has ended.
    elapsed {
        ^startedAt !? { |t| (stoppedAt ? SystemClock.seconds) - t } ? 0
    }

    masterPath { ^paths !? { |p| p[\master] } }
    tapPath    { ^paths !? { |p| p[\tap] } }
    eventsPath { ^paths !? { |p| p[\events] } }

    prChanged { onChange.value(this) }

    free {
        if(recording) { this.stop };
    }

    // ===================================================================
    // The set's tempo and signature
    // ===================================================================
    // The first that applied while the set was being recorded. The drums' own
    // grid first: on SA the first segment of theirs that sounded (drumsStart,
    // or drumsSegment), at its exact tempo, 15 / s16 — the tempo the drum hits
    // in the MIDI file were played at. Otherwise the first analysis: the loop
    // in force when the set began (the header's), else the first take, overdub
    // detection or reading that applied. Followed from what is logged
    // (prFollow), so it works on every profile and needs no hook anywhere else.

    chosenTempo { |until|
        var limit = (until ? stoppedAt) ? SystemClock.seconds;
        var d = drumsTempos.detect { |t| t[\at] <= (limit + 1e-6) };
        ^d ? analysisTempo
    }

    // (bpm:, numerator:, denominator:, from:, at:) of an analysis result, or
    // nil for one with no tempo and signature to name (a take that fit no
    // grid and was not anchored).
    *tempoOf { |result, from, at|
        var bpm, num, den;
        if(result.isKindOf(Dictionary).not) { ^nil };
        bpm = result[\bpm];
        num = result[\numerator];
        den = result[\denominator];
        if(this.tempoLabel(bpm, num, den).isNil) { ^nil };
        ^(bpm: bpm.asFloat, numerator: num.asInteger, denominator: den.asInteger, from: from, at: at)
    }

    // The same from a drumsStart / drumsSegment: its bpm (15 / s16, exact), or
    // 15 * n16 / loopDur when it carries only those.
    *drumsTempoOf { |fields, at|
        var bpm = fields[\bpm];
        if(bpm.isNil and: { fields[\n16].isNumber } and: { fields[\loopDur].isNumber }
            and: { fields[\loopDur] > 0 }) {
            bpm = (15 * fields[\n16]) / fields[\loopDur];
        };
        ^this.tempoOf((bpm: bpm, numerator: fields[\numerator], denominator: fields[\denominator]),
            \drums, at)
    }

    *tempoForLog { |t|
        ^(bpm: this.roundBpm(t[\bpm]), exactBpm: t[\bpm], numerator: t[\numerator],
            denominator: t[\denominator], from: t[\from])
    }

    // Where the drums' bar 1 falls, on the log's clock from audioAt: the
    // drums' segment that gave the set its tempo. Negative for drums already
    // playing when the set began, as far back as that segment's start. nil
    // when the tempo is not the drums'.
    *bar1Of { |tempo, audioAt|
        if(tempo.isNil or: { tempo[\from] != \drums } or: { audioAt.isNil }) { ^nil };
        ^tempo[\at] - audioAt
    }

    // One bar at `bpm` (quarter notes per minute) in num/den.
    *barDur { |bpm, num, den| ^(num * (4 / den)) * (60 / bpm) }

    // How far to move a set right so that a bar line `bar1` seconds into it
    // lands on Live's bar lines, which start at 1.1.1: 0 up to a bar.
    *barShift { |bar1, barDur| ^(barDur - bar1.mod(barDur)).mod(barDur) }

    // The drums' first bar line from audioAt, on the log's clock: bar 1
    // itself, or, for drums already playing (bar1 < 0), the first of THEIR
    // bar lines from there, stepped back at their own bar (the exact tempo,
    // 15 / s16): Live's rounded one would add the rounding's drift over every
    // bar they played before the set, tens of ms after a few minutes.
    *firstBarLine { |tempo, bar1|
        if(bar1.isNil) { ^nil };
        ^if(bar1 >= 0) { bar1 } {
            bar1.mod(this.barDur(tempo[\bpm], tempo[\numerator], tempo[\denominator]))
        }
    }

    // How far to move the set's files right in Live, at the file name's tempo,
    // so that the drums' first bar line in them (its place in the WAVs:
    // wavTime with the set's `clock`) is on Live's bar lines.
    *liveShift { |tempo, bar1, clock|
        if(bar1.isNil) { ^nil };
        ^this.barShift(this.wavTime(this.firstBarLine(tempo, bar1), 0, clock),
            this.barDur(this.roundBpm(tempo[\bpm]), tempo[\numerator], tempo[\denominator]))
    }

    // What the stop tells the player for Live, as a sentence: the tempo and
    // signature, and where the drums' bar 1 is in the files with how far to
    // move them to put it on Live's bar lines. nil with no tempo. `bar1` on
    // the log's clock from audioAt (bar1Of), `clock` the set's (wavTime).
    *liveHint { |tempo, bar1, clock|
        var bpm, num, den, barDur, shift, head, drop, first;
        if(tempo.isNil) { ^nil };
        bpm = this.roundBpm(tempo[\bpm]);
        num = tempo[\numerator];
        den = tempo[\denominator];
        head = "In a DAW: " ++ this.fixed(bpm, 2) ++ " BPM, " ++ num ++ "/" ++ den ++ ".";
        if(bar1.isNil) { ^head ++ " Drop the files at bar 1." };
        barDur = this.barDur(bpm, num, den);
        first = this.wavTime(this.firstBarLine(tempo, bar1), 0, clock);
        shift = this.liveShift(tempo, bar1, clock);
        drop = if((shift < 0.0005) or: { (barDur - shift) < 0.0005 }) {
            "drop the files at bar 1; the drums are on the DAW's bar lines there"
        } {
            "drop the files at bar 1; to put the drums on the DAW's bar lines, move everything right by "
                ++ this.fixed(shift, 3) ++ " s"
        };
        ^if(bar1 >= 0) {
            head ++ " The drums' bar 1 is at " ++ this.fixed(first, 3) ++ " s (" ++ drop ++ ")."
        } {
            head ++ " The drums were already playing; their first bar line in the files is at "
                ++ this.fixed(first, 3) ++ " s (" ++ drop ++ ")."
        }
    }

    // ===================================================================
    // The WAVs' clock
    // ===================================================================
    // The log, the drums' stamps and audioAt are on the language's clock, the
    // Mac's; the WAVs are on the interface's, a frame per sample of its
    // crystal. The server plays a bundle at the sample whose time on the Mac's
    // clock is its stamp, so a hit t seconds after audioAt is t * rate seconds
    // into the WAVs, where rate is the crystal's samples per Mac second over
    // nominal: 20 ppm off is 24 ms by minute twenty, which a .mid driving
    // Live's drums against the stems cannot have. And DiskOut starts and stops
    // at the start of a control block, so frame 0 is up to a block before
    // audioAt.

    // Where moment `t` of the log's clock is in a set's WAVs, in seconds from
    // their frame 0: `frame0` the set's audioAt, `clock` (rate:, lead:) or nil
    // for neither (rate 1, lead 0). The error is under half a block anywhere
    // in a set, however long (see clockRate).
    *wavTime { |t, frame0, clock|
        var rate = clock !? { |c| c[\rate] } ? 1;
        var lead = clock !? { |c| c[\lead] } ? 0;
        ^((t - frame0) * rate) + lead
    }

    // How far before audioAt frame 0 is expected, in seconds: anywhere in the
    // block audioAt falls in, so its middle, half a block less half a sample.
    *frame0Lead { |server|
        var sr = server !? { |s| s.sampleRate };
        if(sr.isNumber.not or: { sr <= 0 }) { ^0 };
        ^((this.blockSizeOf(server) - 1) / 2) / sr
    }

    *blockSizeOf { |server|
        ^server !? { |s| s.options !? { |o| o.blockSize } } ? 64
    }

    // A WAV's length in frames, or nil for no sound file there. The server
    // writes the length into the header when it closes the file.
    *wavFrames { |path|
        var sf, n;
        if(path.isNil or: { File.exists(path).not }) { ^nil };
        sf = SoundFile.openRead(path);
        if(sf.isNil) { ^nil };
        n = sf.numFrames;
        sf.close;
        ^n
    }

    // The interface's clock against the Mac's, over nominal, from what the
    // server wrote between the two stamped bundles: `frames` from audioAt to
    // stopAt. Each end is the start of the control block its bundle ran in,
    // so the count is off by under a block either way; with frame 0 put half
    // a block before audioAt (frame0Lead), a moment placed with this rate is
    // then within half a block of where the WAVs hold it anywhere in the set,
    // however long it ran. nil when the length says nothing: no file, no
    // span, or further off than a block and 1000 ppm (a file cut short: no
    // crystal is that far off).
    *clockRate { |frames, audioAt, stopAt, sampleRate, blockSize = 64|
        var nominal;
        if(frames.isNumber.not or: { audioAt.isNumber.not } or: { stopAt.isNumber.not }
            or: { sampleRate.isNumber.not } or: { sampleRate <= 0 }) { ^nil };
        nominal = (stopAt - audioAt) * sampleRate;
        if(nominal < blockSize) { ^nil };
        if((frames - nominal).abs > (blockSize + (nominal * 1e-3))) { ^nil };
        ^frames / nominal
    }

    // How closely a set from audioAt to stopAt can tell the clock, in ppm: a
    // block over its length (each end is good to a block). nil for no span.
    *clockResolution { |audioAt, stopAt, sampleRate, blockSize = 64|
        var nominal;
        if(audioAt.isNumber.not or: { stopAt.isNumber.not } or: { sampleRate.isNumber.not }) { ^nil };
        nominal = (stopAt - audioAt) * sampleRate;
        ^if(nominal > 0) { (blockSize / nominal) * 1e6 } { nil }
    }

    // What the stop says about it: the clock in ppm with how closely a set of
    // this length can tell (clockResolution), or why there is none. nil for a
    // set that recorded nothing.
    *clockSentence { |rate, frames, audioAt, stopAt, sampleRate, blockSize = 64|
        if(audioAt.isNil) { ^nil };
        if(rate.isNil) {
            ^"The WAVs' length could not be read, so the .mid assumes the interface's clock is the Mac's."
        };
        ^"The interface's clock ran " ++ (if(rate >= 1) { "+" } { "" }) ++ this.fixed((rate - 1) * 1e6, 1)
            ++ " ppm against the Mac's (to " ++ this.fixed(this.clockResolution(audioAt, stopAt, sampleRate, blockSize), 1)
            ++ " ppm, from the WAVs' " ++ frames ++ " frames); the .mid follows it."
    }

    // What a logged event tells the stop: an analysis that applied, the
    // drums' segments, their transport's markers for the MIDI file.
    prFollow { |ev, f, at|
        switch(ev,
            \session,       { this.prOfferAnalysis(f[\loop] ?? { f[\take] !? { |tk| tk[\result] } }, \loop, at) },
            \take,          { if(f[\applied] != false) { this.prOfferAnalysis(f[\result], \take, at) } },
            \overdubDetect, { if((f[\outcome] ? "").asSymbol == \applied) {
                this.prOfferAnalysis(f[\result], \overdub, at) } },
            \readingLanded, { this.prOfferAnalysis(f[\reading], \reading, at) },
            // The segment in force when the set began (inForce) did not start
            // here: its marker, at tick 0, says the drums were playing.
            \drumsStart,    { this.prDrumsSegment(f, at,
                if(f[\inForce] == true) { "drums playing" } { "drums start" }) },
            \drumsSegment,  { this.prDrumsSegment(f, at, "reading") },
            \drumsStop,     { this.prMark(at, "drums stop") },
            \drumsOn,       { this.prMark(at, if(LooperSessionRecorder.prFlag(f)) { "drums on" } { "drums off" }) },
            \breakStart,    { this.prMark(at, "break") },
            \breakEnd,      { this.prMark(at, "back") }
        );
    }

    prOfferAnalysis { |result, from, at|
        if(analysisTempo.isNil) { analysisTempo = LooperSessionRecorder.tempoOf(result, from, at) };
    }

    prDrumsSegment { |f, at, word|
        var t = LooperSessionRecorder.drumsTempoOf(f, at);
        if(t.isNil) { ^this };
        drumsTempos.add(t);
        this.prMark(at, word ++ " " ++ t[\numerator] ++ "/" ++ t[\denominator] ++ " "
            ++ LooperSessionRecorder.bpmString(t[\bpm]) ++ " BPM");
    }

    prMark { |at, text| markers.add((at: at, text: text)) }

    // drumsOn's flag, under whichever key it came.
    *prFlag { |f|
        var v = f[\on] ?? { f[\flag] ?? { f[\value] } };
        ^(v == true) or: { v == 1 } or: { v == "true" }
    }

    // ===================================================================
    // The event log
    // ===================================================================
    // One JSON object per line, appended and flushed as it happens, so a set
    // that ends in a crash keeps every event up to the crash. The first line
    // is the header (`session`), the last is `sessionStop`, after `files`;
    // between them Looper writes what the analyser decided and what the player
    // did about it, and the drums what they played. Times are seconds from the
    // stomp that started the set. Open through the set's tail too (from the
    // stop until its WAVs end, see stop), for what was heard in those last
    // moments: then only what happened before stopAt is the set's.

    logging { ^logFile.notNil }

    // Whether moment `at` is still the set's: always while it records; in its
    // tail, before its WAVs end.
    prTakes { |at| ^closing.isNil or: { at < closing[\stopAt] } }

    // A SystemClock moment on the log's axis; nil for no moment.
    logTime { |seconds| ^seconds !? { |s| s - (startedAt ? s) } }

    prOpenLog { |path|
        this.prCloseLog;
        logFile = File(path, "w");
        if(logFile.isOpen.not) {
            ("Session recording: could not open " ++ path
                ++ " — this set will have no event log.").warn;
            logFile = nil;
        };
    }

    prCloseLog {
        logFile !? { |f| f.close };
        logFile = nil;
    }

    // The header: the stamp, the sample rate, every file the set opened (the
    // stems with their roles and channels) and what the looper knows.
    prLogHeader { |stamp, masterChannel, tapChannel, context|
        var fields = (
            stamp: stamp,
            date: Date.getDate.asString,
            sampleRate: server !? { |s| s.sampleRate },
            master: paths[\master],
            tap: paths[\tap],
            events: paths[\events],
            masterChannel: masterChannel,
            tapChannel: tapChannel
        );
        var stemList = files.select { |f| f[\stem] == true }.collect { |f|
            (role: f[\role], channel: f[\channel], numChannels: f[\numChannels], path: f[\path])
        }.asArray;
        if(stemList.notEmpty) { fields.put(\stems, stemList) };
        context !? { |c| c.keysValuesDo { |k, v| fields.put(k, v) } };
        this.logEvent(\session, fields, startedAt);
    }

    // Append one event: {"t": <seconds from the stomp>, "ev": "<kind>", ...}.
    // `fields` is an Event; `at` the SystemClock moment the event belongs to
    // when that is not now — a take's stop press, a reading's boundary, the
    // drums' segment start. Keys are written sorted so two equal events are two
    // equal lines. Returns false when no log is open, which is the case
    // whenever no set is being recorded, so callers need not ask first; and
    // for a moment after a stopped set's WAVs ended (prTakes).
    logEvent { |ev, fields, at|
        var when;
        if(logFile.isNil) { ^false };
        when = at ? SystemClock.seconds;
        if(this.prTakes(when).not) { ^false };
        this.prWrite(ev, fields, when);
        ^true
    }

    // No log open (it could not be opened): nothing.
    prWrite { |ev, fields, when|
        if(logFile.isNil) { ^this };
        logFile.write(this.prLine(ev, fields, when));
        logFile.flush;
        this.prFollow(ev.asSymbol, fields ? (), when);
    }

    prLine { |ev, fields, at|
        var t = this.logTime(at).round(0.0001);
        var line = "{\"t\": " ++ t ++ ", \"ev\": " ++ LooperSessionRecorder.jsonString(ev);
        var keys;
        fields !? { |f|
            keys = f.keys.asArray.sort { |a, b| a.asString <= b.asString };
            keys.do { |k|
                line = line ++ ", " ++ LooperSessionRecorder.jsonString(k.asString)
                    ++ ": " ++ LooperSessionRecorder.json(f[k]);
            };
        };
        ^line ++ "}\n"
    }

    // The drums' hits that sounded, one `hit` line each, from MegaSADrums once
    // they have played: an Array of Events (at:, slot: \steps | \onset, kind:
    // \step | \roll | \repeat | \onset, note:, vel:, lane:, which: \main |
    // \break, kit:, gate:), `at` the ABSOLUTE language time the hit was heard
    // (its stamp) and `gate` an onset note's length in seconds. On the log's
    // axis like everything else and in time order within the call, written
    // with ONE flush for the whole call — the drums send one batch per pump,
    // and a flush per hit would be a flush every few milliseconds. Kept for the
    // MIDI file too. False when no set is being recorded; in a stopped set's
    // tail, a hit heard once its WAVs had ended is left out (prTakes).
    logHits { |hits|
        var given = (hits ? []).asArray;
        var list = given.select { |h| h.isKindOf(Dictionary) and: { h[\at].isNumber } };
        if(logFile.isNil) { ^false };
        if(list.size < given.size) {
            ("Session recording: " ++ (given.size - list.size)
                ++ " drum hit(s) with no time were not logged.").warn;
        };
        list = list.select { |h| this.prTakes(h[\at]) };
        if(list.isEmpty) { ^true };
        list = LooperMidiFile.sortedBy(list, \at);
        logFile.write(list.collect { |h| this.prLine(\hit, this.prHitFields(h), h[\at]) }.join);
        logFile.flush;
        list.do { |h| loggedHits.add(this.prKeptHit(h)) };
        ^true
    }

    prHitFields { |h|
        var f = ();
        #[\slot, \kind, \note, \vel, \lane, \which, \kit, \gate].do { |k| h[k] !? { |v| f.put(k, v) } };
        ^f
    }

    prKeptHit { |h|
        var f = (at: h[\at]);
        #[\slot, \kind, \note, \vel, \lane, \gate].do { |k| h[k] !? { |v| f.put(k, v) } };
        ^f
    }

    // Any value as JSON. Events and Dictionaries become objects with sorted
    // keys, Symbols become strings, nil and non-finite numbers become null —
    // the one token every reader accepts for "no value".
    *json { |v|
        ^case
        { v.isNil }                    { "null" }
        { v.isKindOf(Boolean) }        { v.asString }
        { v.isNumber }                 {
            if((v != v) or: { v.abs == inf }) { "null" } { v.asString }
        }
        { v.isString }                 { this.jsonString(v) }
        { v.isKindOf(Symbol) }         { this.jsonString(v.asString) }
        { v.isKindOf(Dictionary) }     {
            var keys = v.keys.asArray.sort { |a, b| a.asString <= b.asString };
            "{" ++ keys.collect { |k|
                this.jsonString(k.asString) ++ ": " ++ this.json(v[k])
            }.join(", ") ++ "}"
        }
        { v.isSequenceableCollection } {
            "[" ++ v.collect { |x| this.json(x) }.join(", ") ++ "]"
        }
        { this.jsonString(v.asString) }
    }

    *jsonString { |s|
        ^"\"" ++ s.asString
            .replace("\\", "\\\\").replace("\"", "\\\"")
            .replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
            ++ "\""
    }

    // ===================================================================
    // The MIDI file
    // ===================================================================
    // The drums as Live's Rhythmic Steps device and the onset part sent them,
    // so a set's .mid drives Live's own racks (Kit-Carbon, the One Hit Kit)
    // again, in sync with the WAVs:
    //
    //   track 0  "megalooper <stamp>": the tempo, the signature, and markers
    //            for the drums' transport ("drums start 7/8 165.04 BPM", a
    //            "reading 4/4 …" at each landing, "break" / "back", "drums
    //            off" / "drums on", "drums stop")
    //   track 1  "Step sequencer": every step and roll hit, on MIDI channel
    //            lane + 2 (lane 0 on channel 2 … lane 3 on channel 5) as the
    //            device sends them, a 16th long or up to a tick before the
    //            same note on the same channel comes again
    //   track 2  "Onset notes": the onset kit's hits on channel 2, each as
    //            long as its gate
    //
    // ONE tempo for the whole file, the set's (chosenTempo) at Live's 0.01 BPM,
    // and every tick computed at exactly that tempo from where the hit is in
    // the WAVs (wavTime: from their frame 0, on the interface's clock): with
    // Live at that tempo every note plays where its hit is in the stems,
    // within half a tick and half a block, however long the set and however
    // often its tempo changed — a tempo map would have Live following it, and
    // a stem can only follow one. Later tempos are markers. Beat Repeat's
    // repeats were an audio effect in Live, not notes, so they are not here; a
    // velocity is held to 1..127.

    // Whether a set's hits hold a note for the MIDI file.
    *hasNotes { |hits|
        ^hits.any { |h| #[\step, \roll, \onset].includes(h[\kind] !? { |k| k.asSymbol }) }
    }

    // The three tracks for LooperMidiFile.bytes, as (tracks:, endTick:,
    // early: hits before frame 0, left out, steps:, onsets:, bpm:). Pure.
    // Times on the log's clock, placed in the WAVs through `clock` (wavTime;
    // nil for none) from `frame0`, the set's audioAt. `pace` as
    // LooperMidiFile.noteEvents's.
    *midiTracks { |stamp, tempo, frame0, hits, markers, endAt, pace, clock|
        var bpm = this.roundBpm(tempo[\bpm]);
        var sixteenth = LooperMidiFile.division div: 4;
        var steps = List.new, onsets = List.new, early = 0, count = 0;
        var tickOf, conductor, stepsTrack, onsetTrack, endTick, kind, tick, gate;
        tickOf = { |t| LooperMidiFile.tickAt(this.wavTime(t, frame0, clock), bpm) };
        hits.do { |h|
            kind = h[\kind] !? { |k| k.asSymbol };
            if(#[\step, \roll, \onset].includes(kind) and: { h[\at].isNumber } and: { h[\note].isNumber }) {
                tick = tickOf.(h[\at]);
                if(tick < 0) { early = early + 1 } {
                    if(kind == \onset) {
                        gate = this.prGateSeconds(h[\gate]);
                        onsets.add((tick: tick, chan: 1, note: h[\note].round.asInteger.clip(0, 127),
                            vel: (h[\vel] ? 100).round.asInteger.clip(1, 127),
                            dur: LooperMidiFile.tickAt(gate, bpm).max(1)));
                    } {
                        steps.add((tick: tick, chan: ((h[\lane] ? 0).asInteger + 1).clip(1, 15),
                            note: h[\note].round.asInteger.clip(0, 127),
                            vel: (h[\vel] ? 100).round.asInteger.clip(1, 127), dur: sixteenth));
                    };
                };
            };
            count = count + 1;
            if(pace.notNil and: { (count % 500) == 0 }) { pace.value };
        };
        conductor = [[0, LooperMidiFile.trackName("megalooper " ++ stamp)],
            [0, LooperMidiFile.tempo(bpm)],
            [0, LooperMidiFile.timeSignature(tempo[\numerator], tempo[\denominator])]]
            ++ LooperMidiFile.sortedBy((markers ? []).asArray, \at).collect { |m|
                [tickOf.(m[\at]).max(0), LooperMidiFile.marker(m[\text])]
            };
        stepsTrack = [[0, LooperMidiFile.trackName("Step sequencer")]] ++ LooperMidiFile.noteEvents(steps, pace);
        onsetTrack = [[0, LooperMidiFile.trackName("Onset notes")]] ++ LooperMidiFile.noteEvents(onsets, pace);
        endTick = tickOf.(endAt ? frame0).max(0);
        [conductor, stepsTrack, onsetTrack].do { |tr| endTick = endTick.max(tr.last[0]) };
        ^(tracks: [conductor, stepsTrack, onsetTrack], endTick: endTick, early: early, bpm: bpm,
            steps: steps.size, onsets: onsets.size)
    }

    // An onset hit's gate in seconds. The Looper's own unit is milliseconds
    // (onsetNoteGateMs, held to 1..1000), so a gate over a second can only be
    // that and is read as such.
    *prGateSeconds { |gate|
        if(gate.isNumber.not or: { gate <= 0 }) { ^this.onsetGate };
        ^if(gate > 1) { gate / 1000 } { gate }
    }

    // ===================================================================
    // Reading a set back
    // ===================================================================

    // Every event of a log, in file order, as Events with Symbol keys and
    // numbers as numbers — String:parseJSON hands every scalar back as a
    // String, so this converts what looks like a number and leaves the rest
    // (a stamp like "260928_183000" stays text). A line that will not parse —
    // a crash mid-write leaves one — is skipped and counted, never fatal.
    *readEvents { |path|
        var events = List.new, bad = 0;
        if(File.exists(path).not) { ^[] };
        File.readAllString(path).split($\n).do { |line|
            var parsed;
            if(line.stripWhiteSpace.notEmpty) {
                parsed = try { line.parseJSON } { nil };
                if(parsed.isKindOf(Dictionary)) {
                    events.add(this.prFromJSON(parsed));
                } {
                    bad = bad + 1;
                };
            };
        };
        if(bad > 0) {
            ("Session events: " ++ bad ++ " unreadable line(s) in " ++ path).warn;
        };
        ^events.asArray
    }

    *prFromJSON { |v|
        var e;
        case
        { v.isNil }                    { ^nil }
        { v.isString }                 { ^this.prJSONScalar(v) }
        { v.isKindOf(Dictionary) }     {
            e = ();
            v.keysValuesDo { |k, x| e[k.asSymbol] = this.prFromJSON(x) };
            ^e
        }
        { v.isSequenceableCollection } { ^v.collect { |x| this.prFromJSON(x) } };
        ^v
    }

    *prJSONScalar { |s|
        if(s == "true") { ^true };
        if(s == "false") { ^false };
        if(s.notEmpty
            and: { s.every { |c| "0123456789.-+eE".includes(c) } }
            and: { s.any { |c| c.isDecDigit } }) {
            ^if(s.any { |c| ".eE".includes(c) }) { s.asFloat } { s.asInteger }
        };
        ^s
    }

    // The log of the set `stamp` in `dir`, under its stamp name or renamed
    // with any tempo; nil if there is none. Old sets (stamp names only) and new
    // ones alike.
    *findEvents { |dir, stamp|
        var exact = dir +/+ (stamp.asString ++ "-events.jsonl");
        if(File.exists(exact)) { ^exact };
        ^(this.globQuote(dir) +/+ (stamp.asString ++ "-*-events.jsonl")).pathMatch.sort.detect { |p|
            (this.parseName(p) ? ())[\stamp] == stamp.asString
        }
    }

    // Where a set's file for `role` (\master, \tap, a stem's role, \events,
    // \midi) is now, from its log; nil if it is nowhere. In this order: the
    // path it was opened under (the header's), because a file still there is
    // one whose rename did not happen — or a set from before the names
    // carried a tempo — and is the set's own whatever has since taken its new
    // name; then the name the stop gave it (the `files` event) beside the log;
    // then the opened name beside the log (a set moved to another folder);
    // then any file of the set's stamp and role, whatever its tempo.
    *sessionPath { |events, role, eventsPath|
        var header = events.detect { |e| e[\ev] == "session" } ? ();
        var filesEv = events.reverse.detect { |e| e[\ev] == "files" };
        var here = eventsPath !? { |p| p.dirname };
        var tries = List.new, logged, named, stampOf, part, found;
        role = role.asSymbol;
        if(role == \events) { eventsPath !? { |p| tries.add(p) } };
        // The .mid is never opened under its stamp name, so that name beside
        // the log is one it fell back to (its final name was taken; then the
        // file under the final name is someone else's) or a set with no tempo.
        if((role == \midi) and: { eventsPath.notNil } and: { header[\stamp].notNil }) {
            tries.add(eventsPath.dirname +/+ this.nameFor(header[\stamp], nil, "drums", "mid"));
        };
        logged = this.prLoggedPath(header, role);
        named = filesEv !? { |fe| fe[\files] !? { |m| m[role] } };
        logged !? { |p| tries.add(p.asString) };
        here !? { |d|
            named !? { |b| tries.add(d +/+ b.asString.basename) };
            logged !? { |p| tries.add(d +/+ p.asString.basename) };
        };
        found = tries.detect { |p| File.exists(p) };
        if(found.notNil or: { here.isNil }) { ^found };
        stampOf = header[\stamp] ?? { eventsPath !? { |p| this.parseName(p) !? { |n| n[\stamp] } } };
        if(stampOf.isNil) { ^nil };
        part = this.fileOf(role);
        ^(this.globQuote(here) +/+ (stampOf.asString ++ "*-" ++ part[0] ++ "." ++ part[1])).pathMatch.sort.detect { |p|
            this.parseName(p) !? { |n|
                (n[\stamp] == stampOf.asString) and: { n[\role] == part[0] } and: { n[\ext] == part[1] }
            } ? false
        }
    }

    // The path a header gives a role: its own field for the master, the tap
    // and the log, the stems list for a stem.
    *prLoggedPath { |header, role|
        if(#[\master, \tap, \events].includes(role)) { ^header[role] };
        ^(header[\stems] ? []).detect { |s| (s[\role] ? "").asSymbol == role } !? { |s| s[\path] }
    }

    // The takes of a set and what the player made of each, from its events.
    // One Event per take: where it sits in the tap (`start`, `dur`, seconds
    // from the stomp), the reading the analyser gave (`result`), the onsets it
    // heard and the threshold in force, its ranked list, and the OUTCOME:
    //
    //   \accepted   played on as heard; `label` is the analyser's own reading,
    //               a weak label — right, or wrong and not noticed
    //   \corrected  the next-reading switch moved it; `label` is the reading it
    //               settled on, and the analyser was wrong on this take. Bars
    //               given by hand (Looper.offerBars) are a label once armed:
    //               the player said what was played, and a set stopped before
    //               the next boundary would otherwise lose it (`byHand`)
    //   \reverted   moved and moved back: wrong, and no reading fitted, so no
    //               label — the analyser did not have the truth on its list
    //   \discarded  undone before it was played; no label
    //
    // An overdub detection that gave a loop its meter is listed too, as kind
    // \overdub: it is an analysis in its own right, and the switch can move it
    // like any other. The replay does not re-run those yet.
    //
    // A loop already playing when the set began comes out as kind \inForce,
    // from the header's `take`: the analyser's input and answer without the
    // audio (the take was recorded before the tap started), and `settled` is
    // the reading that was in force, so a loop already moved by the switch is
    // corrected from the first line. Readings pressed during the set attach
    // to it like to any take.
    *takesFrom { |events|
        var takes = List.new;
        var stack = List.new;    // analyses in force, the newest last
        var cur, close, tk;
        cur = { if(stack.isEmpty) { nil } { stack.last } };
        close = { |by, at|
            stack.do { |x| if(x[\end].isNil) { x[\end] = at; x[\endedBy] = by } };
            stack.clear;
        };
        events.do { |ev|
            var t = ev[\t];
            var kind = (ev[\ev] ? "").asSymbol;
            switch(kind,
                \session, {
                    ev[\take] !? { |tk0|
                        tk = (kind: \inForce, index: takes.size, t: t, start: nil,
                            dur: tk0[\dur], loopDur: tk0[\loopDur] ? ev[\loopDur],
                            threshold: tk0[\threshold], firstOnset: tk0[\firstOnset],
                            onsets: tk0[\onsets] ? [], pitches: tk0[\pitches], result: tk0[\result],
                            candidates: tk0[\candidates] ? [],
                            fromOverdub: tk0[\fromOverdub] == true,
                            presses: 0, settled: tk0[\reading] ? 0,
                            settledReading: ev[\loop] ? tk0[\result], readings: List.new);
                        takes.add(tk);
                        stack.add(tk);
                    };
                },
                \recordStart, { close.(\newTake, t) },
                \take, {
                    tk = (kind: \take, index: takes.size, start: ev[\start], t: t,
                        dur: ev[\dur], loopDur: ev[\loopDur], threshold: ev[\threshold],
                        firstOnset: ev[\firstOnset], onsets: ev[\onsets] ? [], pitches: ev[\pitches],
                        result: ev[\result], candidates: ev[\candidates] ? [],
                        applied: ev[\applied], tapPeakDb: ev[\tapPeakDb], inPeakDb: ev[\inPeakDb],
                        presses: 0, settled: 0,
                        settledReading: ev[\result], readings: List.new);
                    takes.add(tk);
                    stack.add(tk);
                },
                \overdubDetect, {
                    if((ev[\outcome] ? "").asSymbol == \applied) {
                        tk = (kind: \overdub, index: takes.size, t: t,
                            dur: ev[\loopDur], loopDur: ev[\loopDur],
                            onsets: ev[\onsets] ? [], result: ev[\result],
                            candidates: ev[\candidates] ? [], presses: 0, settled: 0,
                            settledReading: ev[\result], readings: List.new);
                        takes.add(tk);
                        stack.add(tk);
                    };
                },
                \readingArmed, {
                    cur.value !? { |c|
                        c[\presses] = c[\presses] + 1;
                        c[\lastArmed] = ev;
                    };
                },
                \readingLanded, {
                    cur.value !? { |c|
                        c[\settled] = ev[\index];
                        c[\settledReading] = ev[\reading];
                        c[\readings].add(ev);
                        c[\lastArmed] = nil;
                    };
                },
                // An undo whose snapshot was taken with no loop playing undid a
                // take; one taken while playing undid an overdub, a multiply or
                // a chain, and the take stands.
                \undo, {
                    if(stack.notEmpty
                        and: { #[\empty, \stopped].includes((ev[\state] ? "").asSymbol) }) {
                        tk = stack.removeAt(stack.size - 1);
                        tk[\end] = t;
                        tk[\endedBy] = \undo;
                        tk[\outcome] = \discarded;
                    };
                },
                \clear,       { close.(\clear, t) },
                \sessionStop, { close.(\sessionStop, t) }
            );
        };
        takes.do { |x|
            // Bars given by hand, armed last and not landed before the take
            // ended: what the player said was played.
            x[\lastArmed] !? { |a|
                if(((a[\via] ? "").asSymbol == \hand) and: { a[\reading].notNil }) {
                    x[\settled] = a[\index] ? -1;
                    x[\settledReading] = a[\reading];
                    x[\byHand] = true;
                };
            };
            x.removeAt(\lastArmed);
            if(x[\outcome] != \discarded) {
                x[\outcome] = case
                    { x[\settled] != 0 } { \corrected }
                    { x[\presses] > 0 }  { \reverted }
                    { \accepted };
            };
            x[\label] = switch(x[\outcome],
                \corrected, { x[\settledReading] },
                \accepted,  { x[\result] },
                { nil });
            x[\readings] = x[\readings].asArray;
        };
        ^takes.asArray
    }
}
