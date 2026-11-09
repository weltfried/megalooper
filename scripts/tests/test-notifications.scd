// What the models say, listed (docs/dev/architecture.md 3.6 and 5, step 6):
// each model with a `*notifications` table answers for every `changed` its
// class says, and says nothing the table does not list. The window, MIDI, the
// drums, the AI apps and the action log listen to these, and the action log
// writes them into a set's log, so a symbol renamed or added unlisted is a
// contract broken without a word. Read from the class's source: every
// `this.changed(\symbol` and `this.prNotify(\symbol` (the drums' sayer) outside
// comments, and the symbols a class passes to its own helper (the Looper's
// prSetGranular).

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-notifications");

{
var root = thisProcess.nowExecutingPath.dirname.dirname.dirname;
var code = { |file|
    (File.readAllString(root +/+ "classes" +/+ file) ? "").split($\n).collect { |line|
        var cut = line.find("//");
        if(cut.isNil) { line } { line.copyRange(0, cut - 1) }
    }.join("\n")
};
// Every `this.changed(\x` in the source, and every symbol passed as the third
// argument of `sayer(` (the notification a helper says for its caller).
// A class's parts (the Looper's, split out of it: docs/dev/architecture.md 5,
// step 8) say its changes as `looper.changed(\x`, read with the class.
var saidIn = { |file, sayer|
    var text = (if(file.isString) { [file] } { file }).collect { |f| code.(f) }.join("\n");
    var syms = (text.findRegexp("(?:this|looper|sa)\\.changed\\(\\\\[a-zA-Z]+") ++ text.findRegexp("(?:this|drums)\\.prNotify\\(\\\\[a-zA-Z]+"))
        .collect { |m| m[1].split($\\).last.asSymbol }.asSet;
    sayer !? {
        text.findRegexp(sayer ++ "\\(\\\\[a-zA-Z]+, [a-zA-Z]+, \\\\[a-zA-Z]+").do { |m|
            syms.add(m[1].split($\\).last.asSymbol) };
    };
    syms
};
var check = { |name, table, said|
    var listed = table.keys;
    var unlisted = said.reject { |k| listed.includes(k) };
    var unsaid = listed.reject { |k| said.includes(k) };
    var malformed = table.keys.reject { |k|
        var e = table[k];
        e.isKindOf(Array) and: { e.size == 3 } and: { [\state, \event].includes(e[0]) }
            and: { e[1].isKindOf(Array) } and: { e[1].every(_.isKindOf(Symbol)) } and: { e[2].isKindOf(String) }
    };
    ~tAssert.(name ++ ": the scan finds what it says", said.size > 0, said.size.asString);
    ~tAssert.(name ++ ": everything it says is listed", unlisted.isEmpty, "unlisted: " ++ unlisted.asArray.sort);
    ~tAssert.(name ++ ": everything listed is said", unsaid.isEmpty, "never said: " ++ unsaid.asArray.sort);
    ~tAssert.(name ++ ": each entry is [\\state or \\event, [argument names], words]", malformed.isEmpty,
        malformed.asArray.sort.asString);
};
var actions = File.readAllString(root +/+ "scripts" +/+ "setup-actions.scd") ? "";
var looperSkip, looperParts, saParts, drumsParts;

// The Looper's parts: each says its changes as the Looper's, held to the
// Looper's table here.
looperParts = ["LooperOnsetNotes", "LooperChainRecorder", "LooperGrains", "LooperCutter"];
check.("Looper", Looper.notifications, saidIn.(["Looper.sc"] ++ looperParts.collect { |n| n ++ ".sc" }, "prSetGranular"));
~tEq.("a part of the Looper says its changes as the Looper's (looper.changed), never as its own, which nobody hears",
    looperParts.select { |n| code.(n ++ ".sc").findRegexp("this\\.changed\\(").notEmpty }, []);
~tEq.("the Looper lists 65 notifications", Looper.notifications.size, 65);
// MegaSA's parts likewise (step 9).
saParts = ["MegaSAMixer", "MegaSAStateJobs", "MegaSAGraph"];
check.("MegaSA", MegaSA.notifications, saidIn.(["MegaSA.sc"] ++ saParts.collect { |n| n ++ ".sc" }));
~tEq.("a part of MegaSA says its changes as MegaSA's (sa.changed), never as its own",
    saParts.select { |n| code.(n ++ ".sc").findRegexp("this\\.changed\\(").notEmpty }, []);
// The drums' parts likewise (step 9): they say the drums' changes through
// drums.prNotify.
drumsParts = ["MegaSADrumsPresets", "MegaSADrumsKits"];
check.("MegaSADrums", MegaSADrums.notifications, saidIn.(["MegaSADrums.sc"] ++ drumsParts.collect { |n| n ++ ".sc" }));
[MegaSADevice, MegaSAPlugin, MegaSAWave, LooperCalibrator, MegaRemote, MegaSAKit].do { |c|
    check.(c.name.asString, c.notifications, saidIn.(c.name.asString ++ ".sc"));
};
// Every class that says something has a table, so a new model can't be added
// unlisted.
{
    var classes = (root +/+ "classes" +/+ "*.sc").pathMatch.collect { |p| PathName(p).fileNameWithoutExtension }
        .select { |n| saidIn.(n ++ ".sc").notEmpty }.reject { |n| (looperParts ++ saParts ++ drumsParts).includesEqual(n) };
    var without = classes.reject { |n| n.asSymbol.asClass.respondsTo(\notifications) };
    ~tAssert.("every class that says changes lists them", without.isEmpty, "without a table: " ++ without.join(", "));
}.value;

// The action log leaves some of the Looper's out of a set's log by name
// (setup-actions.scd): each is one the Looper says.
looperSkip = (actions.find("parts.put(\\looper") !? { |i|
    var from = actions.find("skip: #[", offset: i), to;
    to = from !? { actions.find("]", offset: from) };
    (from.notNil and: { to.notNil }).if {
        actions.copyRange(from, to).findRegexp("\\\\[a-zA-Z]+").collect { |x| x[1].drop(1).asSymbol } } { [] }
}) ? [];
~tAssert.("the action log's skip list for the Looper is read", looperSkip.size > 5, looperSkip.asString);
~tAssert.("...and names only notifications the Looper says",
    looperSkip.every { |k| Looper.notifications.includesKey(k) },
    looperSkip.reject { |k| Looper.notifications.includesKey(k) }.asString);
}.value;
