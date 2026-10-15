// Megalooper SA: the plugin scan with an offline server, for real (headless).
//
//     /Applications/SuperCollider.app/Contents/MacOS/sclang scripts/sa/nrt-plugin-scan.scd
//
// A scratch folder holding a link to one plugin of this Mac (Bias FX's VST2
// if it is there, else the first VST3 or VST2 in /Library/Audio/Plug-Ins) is
// scanned as megalooper scans (MegaSAPlugins.writeScore and scanCommand:
// scsynth -N, never a realtime server), and the catalog is read back with no
// server:
//   1. the scan ends by itself and writes VSTPlugin's cache where it is told;
//   2. the catalog holds the plugin, with its key (the name an open uses),
//      its format and its channels;
//   3. it is found again by what a sound keeps of it;
//   4. the scan megalooper itself starts (asynchronous, its output to a log)
//      gives the same catalog.
// It skips, saying so, without VSTPlugin or without a plugin to scan.
(
var root = PathName.tmp +/+ "megalooper-nrt-scan-" ++ thisProcess.pid;
var plugs = root +/+ "plugs", cache = root +/+ "cache";
var passed = 0, failed = 0;
var ok = { |label, flag, info|
    if(flag == true) { passed = passed + 1; ("  ok    " ++ label).postln } {
        failed = failed + 1;
        ("  FAIL  " ++ label ++ " — " ++ (info ? "").asString).postln;
    };
};
var bare = { |p| if(p.last == $/) { p.drop(-1) } { p } };
var candidates = (["/Library/Audio/Plug-Ins/VST/BIAS FX 2.vst"] ++ "/Library/Audio/Plug-Ins/VST3/*.vst3".pathMatch
    ++ "/Library/Audio/Plug-Ins/VST/*.vst".pathMatch).collect { |p| bare.(p) };
var plugin = candidates.detect { |p| File.exists(p) };
var code, entries, entry, t0;

SystemClock.sched(300, { "NRT PLUGIN SCAN FAILED — it did not end in 300 s".postln; 1.exit; nil });
case
{ MegaSAPlugins.available.not } { "NRT PLUGIN SCAN PASSED — skipped: VSTPlugin is not installed here".postln }
{ plugin.isNil } { "NRT PLUGIN SCAN PASSED — skipped: no plugin in /Library/Audio/Plug-Ins to scan".postln }
{
    ("== the offline scan of " ++ plugin.basename ++ " ==").postln;
    File.mkdir(plugs);
    ("/bin/ln -s " ++ plugin.shellQuote ++ " " ++ (plugs +/+ plugin.basename).shellQuote).systemCmd;
    ok.("the scan's score is written", MegaSAPlugins.writeScore(root +/+ "scan.osc", cache, [plugs]));
    t0 = Main.elapsedTime;
    code = MegaSAPlugins.scanCommand(root +/+ "scan.osc", root +/+ "scan.wav", 57990 + 7.rand).systemCmd;
    ("  the scan took " ++ (Main.elapsedTime - t0).round(0.1) ++ " s").postln;
    ok.("the offline server ends by itself, with no error", code == 0, code);
    ok.("it wrote VSTPlugin's cache where it was told", MegaSAPlugins.hasCache(cache));
    entries = MegaSAPlugins.read(cache);
    entry = entries.first;
    ("  the catalog: " ++ entries.collect { |x| [x[\key], x[\format], x[\ins], x[\outs], x[\vendor]] }).postln;
    ok.("the catalog, read with no server, holds the plugin", entries.size == 1, entries.size);
    ok.("...with its key, its format and its channels",
        entry.notNil and: { entry[\key].notEmpty } and: { entry[\format] == if(plugin.endsWith(".vst3")) { "vst3" } { "vst2" } }
            and: { entry[\outs] > 0 } and: { entry[\path].notEmpty }, entry.asString);
    // (Its path is the one it was scanned through, here the link's: megalooper opens by key.)
    ok.("...its key the name an open uses, whatever folder it was scanned through",
        entry.notNil and: { [plugin.basename, plugin.basename.splitext[0]].includesEqual(entry[\key]) }, entry !? { |x| x[\key] });
    ok.("...found again by what a sound keeps of it",
        entry.notNil and: { MegaSAPlugins.find(entries, (key: entry[\key], format: entry[\format], uid: entry[\uid])) === entry });
    ok.("...and by its name when its key is another's",
        entry.notNil and: { MegaSAPlugins.find(entries, (key: "?", uid: "?", name: entry[\name], vendor: entry[\vendor], format: entry[\format])) === entry });
    ok.("the browser's rules take it without throwing", (try { MegaSAPlugins.offered(entries) } { nil }).isArray);
    // The same scan as megalooper itself starts it (MegaSAPlugins.scan):
    // beside the language, its answer later, its output in a log. This is
    // the path that once ended at once with nothing found.
    Routine {
        var done, t = Main.elapsedTime, again = cache ++ "-again";
        MegaSAPlugins.scan(again, [plugs], { |flag, why| done = [flag, why] });
        while { done.isNil and: { (Main.elapsedTime - t) < 120 } } { 0.25.wait };
        ok.("the scan megalooper itself starts, beside the language, ends well", done == [true, nil], done.asString);
        ok.("...its catalog holds the plugin too", MegaSAPlugins.read(again).collect { |x| x[\key] } == entries.collect { |x| x[\key] },
            MegaSAPlugins.read(again).asString);
        ok.("...and what the offline server said is kept beside it", (File.readAllString(MegaSAPlugins.logPath(again)) ? "").contains("VSTPlugin"));
        if(root.beginsWith(PathName.tmp) and: { root.contains("megalooper-nrt-scan-") }) { ("/bin/rm -rf " ++ root.shellQuote).systemCmd };
        (if(failed == 0) { "NRT PLUGIN SCAN PASSED — " ++ passed ++ " checks" } {
            "NRT PLUGIN SCAN FAILED — " ++ failed ++ " of " ++ (passed + failed) }).postln;
        0.exit;
    }.play(AppClock);
};
// (A skipped run leaves at once; a real one from its routine.)
if(MegaSAPlugins.available.not or: { plugin.isNil }) { 0.exit };
)
