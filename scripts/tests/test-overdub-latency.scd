// The overdub latency from the round trip the audio devices report: the
// start (setup-model.scd's ~latencyStart), what the Calibrate view keeps as
// its difference to it (LooperCalibrator), the chains' delay it follows
// (~latencyFollow), the line the Rig page and the wizard show, and, on a
// Mac, what tools/coreaudio.py answers for the devices this machine has.
//
// No server: the looper is an Event (it answers latencyMs by key), MegaSA
// runs on the harness's stub, and the kept numbers go to a file of the
// test's own.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-overdub-latency");

{
    var scripts = Looper.repoRoot +/+ "scripts";
    var tmp = PathName.tmp +/+ ("megalooper-test-latency-" ++ thisProcess.pid), path = tmp +/+ "calibration.json";
    var looper, rp, said, cal, kept, m, plug, start, srv, rt;
    // These define only: no server, no window.
    (scripts +/+ "setup-routing.scd").load;
    (scripts +/+ "setup-model.scd").load;
    File.mkdir(tmp);
    protect {
        // ---- the rule a start follows ----------------------------------------------
        ~tEq.("nothing kept: the report",
            LooperCalibrator.startLatency(52.5, nil).atAll([\latencyMs, \correctionMs, \from]), [52.5, 0, \reported]);
        ~tEq.("a correction kept: added to the report",
            LooperCalibrator.startLatency(52.5, (latencyCorrectionMs: -4.5, latencyMs: 30)).atAll([\latencyMs, \correctionMs, \from]),
            [48.0, -4.5, \correction]);
        ~tEq.("a latency kept with no correction (an older megalooper's): as it was, its difference the correction",
            LooperCalibrator.startLatency(52.5, (latencyMs: 30)).atAll([\latencyMs, \correctionMs, \from]), [30, -22.5, \kept]);
        ~tEq.("...never below 0", LooperCalibrator.startLatency(5, (latencyCorrectionMs: -9))[\latencyMs], 0);
        ~tEq.("the correction is kept beside the looper's own values, and is none of them",
            [LooperCalibrator.keptFields.includes(\latencyCorrectionMs), LooperCalibrator.looperFields.includes(\latencyCorrectionMs)],
            [true, false]);

        // ---- the start ---------------------------------------------------------------
        ~megaSA = nil;
        ~routingProfile = \saSystem;
        ~latencyReport = (interfaceMs: 51.5625, inMs: 32.85, outMs: 18.71);
        rp = (live: false, calibrationKey: "Mic → Speakers @ 64 frames");
        ~tNear.("without chains the round trip reported is the devices'", ~latencyReportedMs.(), 51.5625, 1e-9);
        looper = (latencyMs: 30);
        said = ~latencyStart.(looper, rp, tmp);
        ~tNear.("a start with nothing kept takes the report", looper[\latencyMs], 51.5625, 1e-9);
        ~tAssert.("...and says so", said.notNil and: { said.contains("51.6 ms") } and: { said.contains("kept").not }, said.asString);
        LooperCalibrator.keep(path, rp[\calibrationKey], \latencyCorrectionMs, 3.5);
        looper = (latencyMs: 30);
        said = ~latencyStart.(looper, rp, tmp);
        ~tNear.("...with a correction kept for this setup, the report plus it", looper[\latencyMs], 55.0625, 1e-9);
        ~tAssert.("...and says that too", said.contains("+3.5 ms as kept"), said);
        LooperCalibrator.keep(path, \saSystem, \latencyCorrectionMs, 20);
        looper = (latencyMs: 30);
        ~latencyStart.(looper, (live: false, calibrationKey: "Interface @ 64 frames"), tmp);
        ~tNear.("...but not one kept for another setup or the rig it inherits from", looper[\latencyMs], 51.5625, 1e-9);
        looper = (latencyMs: 30);
        ~latencyStart.(looper, (live: false), tmp);
        ~tNear.("a profile's own rig (no setup) keeps under its name", looper[\latencyMs], 71.5625, 1e-9);
        looper = (latencyMs: 33);
        ~tEq.("a Live rig is left as it was", [~latencyStart.(looper, (live: true, calibrationKey: "x"), tmp), looper[\latencyMs]],
            [nil, 33]);
        ~latencyReport = nil;
        looper = (latencyMs: 33);
        ~tEq.("...and so is a start with no report (not a Mac)", [~latencyStart.(looper, rp, tmp), looper[\latencyMs]], [nil, 33]);
        ~tEq.("...whose line says nothing", ~latencyReportedLine.(33), nil);
        ~latencyReport = (interfaceMs: 20);

        // ---- the line --------------------------------------------------------------------
        ~tEq.("the line: the report and its parts",
            ~latencyReportedLine.(20), "Reported 20.0 ms: the audio device 20.0, the effects 0.0.");
        ~tAssert.("...and how far the latency set is from it",
            ~latencyReportedLine.(17.6).endsWith("Overdub latency is set 2.4 ms below it.")
                and: { ~latencyReportedLine.(25).endsWith("set 5.0 ms above it.") }, ~latencyReportedLine.(17.6));

        // ---- the chains, and following them ---------------------------------------------
        plug = ~tFakePlugin.(\open);
        m = ~tMegaSA.(nil, plug);
        Routine { m.attachLooper(~tLooper.()) }.next;
        ~megaSA = m;
        ~tNear.("the chains add nothing while their delays are off", ~latencyReportedMs.(), 20, 1e-9);
        looper = (latencyMs: 0);
        ~latencyStart.(looper, (live: false, calibrationKey: "chains"), tmp);
        ~tNear.("a start", looper[\latencyMs], 20, 1e-9);
        m.setFx(\shifter, true);
        ~tNear.("the Shifter switched on: its 2 samples on top", looper[\latencyMs], 20 + (2000 / 48000), 1e-9);
        ~tNear.("...in the report too", ~latencyReportedMs.(), 20 + (2000 / 48000), 1e-9);
        plug[\latency] = 32;
        plug[\dryDelay] = 32;
        plug.changed(\latency, 32);
        ~tNear.("a plugin reporting a latency on the instrument chain", looper[\latencyMs], 20 + (34000 / 48000), 1e-9);
        looper[\latencyMs] = 30;
        m.setFx(\shifter, false);
        ~tNear.("...a latency set by hand moves by the change from where it is", looper[\latencyMs], 30 - (2000 / 48000), 1e-9);
        m.insertDevice(\drums, 0, \shifter);
        ~tNear.("the drums' chain is not on the round trip", looper[\latencyMs], 30 - (2000 / 48000), 1e-9);
        m.insertDevice(\loop, 0, \shifter);
        ~tNear.("the loop's is: it is heard through it", looper[\latencyMs], 30, 1e-9);
        ~latencyStart.((latencyMs: 0), (live: true), tmp);
        m.setFx(\shifter, true);
        ~tNear.("a start lets the looper before it go", looper[\latencyMs], 30, 1e-9);
        m.free;

        // ---- what the wizard keeps ----------------------------------------------------
        File.delete(path);
        looper = (latencyMs: 30, onsetThreshold: 0.5);
        cal = LooperCalibrator(looper, false).keptPath_(path).rig_('Mic → Speakers @ 64 frames');
        ~tEq.("with nothing reported the round trip step is not optional", cal.stepAt(\latency)[\optional], false);
        cal.reported = { 51.5 };
        ~tEq.("with a report it is", [cal.stepAt(\latency)[\optional], cal.steps.select { |s| s[\optional] == true }.size], [true, 1]);
        ~tAssert.("...which completes the wizard without it", { 3.do { cal.skip }; cal.isComplete }.value);
        ~tEq.("...and the class's steps are as they were", LooperCalibrator.stepAt(\latency)[\optional], false);
        cal.reset;
        cal.register(\latency, { |l, done| done.((ok: true, value: 48.25)) });
        cal.goTo(3);
        cal.run;
        cal.apply;
        kept = LooperCalibrator.readKept(path)['Mic → Speakers @ 64 frames'];
        ~tEq.("a measured round trip is kept, with its difference to the report",
            [kept[\latencyMs], kept[\latencyCorrectionMs], looper[\latencyMs]], [48.25, -3.25, 48.25]);
        looper[\latencyMs] = 55;
        cal.confirm;
        kept = LooperCalibrator.readKept(path)['Mic → Speakers @ 64 frames'];
        ~tEq.("...and one set by ear, with Start with this", [kept[\latencyMs], kept[\latencyCorrectionMs]], [55, 3.5]);
        looper = (latencyMs: 0);
        LooperCalibrator.applyKept(looper, path, 'Mic → Speakers @ 64 frames');
        ~tEq.("applying what is kept sets the looper's values only", [looper[\latencyMs], looper[\latencyCorrectionMs]], [55, nil]);
        ~tAssert.("...and the start line names only those",
            LooperCalibrator.applyKeptAtStart((latencyMs: 0), (live: false), 'Mic → Speakers @ 64 frames', tmp)
                !? { |s| s.contains("Correction").not } ? false);
        cal.reported = { nil };
        File.delete(path);
        looper[\latencyMs] = 40;
        cal.goTo(3);
        cal.confirm;
        ~tEq.("with no report only the latency is kept",
            LooperCalibrator.readKept(path)['Mic → Speakers @ 64 frames'].keys.asArray.sort, [\latencyMs, \savedAt]);

        // ---- the report itself, on a Mac ------------------------------------------------
        if(MegaFiles.isMac) {
            srv = (options: ServerOptions.new.hardwareBufferSize_(64));
            rt = ~audioRoundTripReported.(srv);
            // A Mac with no audio device at all answers nil; every other one
            // answers its default input's way in and default output's way out.
            if(rt.notNil) {
                ~tNear.("on this Mac the report is the way in and the way out", rt[\interfaceMs], rt[\inMs] + rt[\outMs], 1e-6);
                ~tEq.("...at the buffer asked for", [rt[\buffer], rt[\own]], [64, false]);
                ~tAssert.("...each at least one buffer long", (rt[\inMs] >= (64000 / 48000 * 0.9)) and: { rt[\outMs] > 0 },
                    rt.asString);
                ~tAssert.("...and named", rt[\inName].size > 0 and: { rt[\outName].size > 0 });
            } { "  (no default audio devices here: the report is not checked)".postln };
            srv.options.inDevice = "no such device anywhere";
            ~tEq.("a device that is not there: no report", ~audioRoundTripReported.(srv), nil);
        };
    } {
        ~latencyFollower !? { |c| c.remove };
        ~latencyReport = nil;
        ~megaSA = nil;
        if(File.exists(path)) { File.delete(path) };
        File.delete(tmp);
    };
}.value;
