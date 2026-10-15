// megalooper's files, the part every kind of file shares (docs/dev/device-chains.md,
// section 4.1 and 11): where your own files live, reading and writing JSON
// without losing what this build does not know, and a write that never
// leaves half a file.
//
// The user root is ~/Library/Application Support/SuperCollider/megalooper,
// beside the MIDI maps. A test moves it to a scratch folder (rootOverride;
// scripts/tests/_harness.scd does so for every test) and asserts that it did.
MegaFiles {
    classvar <>rootOverride;
    // True makes every write wait for its move (a test's: a synchronous test
    // never gives an asynchronous write the chance to finish).
    classvar <>alwaysSync = false;
    classvar writes = 0;
    // A test's stand-in for the system megalooper runs on (\osx, \linux).
    classvar <>platformOverride;

    *userRoot { ^rootOverride ?? { Platform.userAppSupportDir +/+ "megalooper" } }

    // ---- the system --------------------------------------------------------
    // megalooper grew up on macOS and asks it things no other system
    // answers: CoreAudio's device list, the quarantine flag, its clipboard.
    // Whoever asks one of those asks here first.
    *platform { ^platformOverride ?? { thisProcess.platform.name } }
    *isMac { ^this.platform == \osx }
    *isLinux { ^this.platform == \linux }

    // The first of `names` that is a command on this system, as the shell
    // finds it: its path, or nil when none is there. A name with a slash is
    // a path and is taken if the file is there.
    *commandPath { |names|
        (names ? []).do { |name|
            var found = if(name.asString.contains("/")) {
                if(File.exists(name.asString)) { name.asString } { "" }
            } {
                ("command -v " ++ name.asString.shellQuote ++ " 2>/dev/null").unixCmdGetStdOut.stripWhiteSpace
            };
            if(found.notEmpty) { ^found };
        };
        ^nil
    }

    // The command that takes text on its standard input and puts it on the
    // clipboard, or nil when this system has none megalooper knows: macOS's
    // pbcopy; on Linux wl-copy (Wayland), xclip or xsel (X11).
    *clipboardCommand {
        var tools = if(this.isMac) { [["/usr/bin/pbcopy", ""], ["pbcopy", ""]] } {
            [["wl-copy", ""], ["xclip", " -selection clipboard"], ["xsel", " --clipboard --input"]] };
        tools.do { |t|
            this.commandPath([t[0]]) !? { |path| ^path.shellQuote ++ t[1] };
        };
        ^nil
    }

    // ---- reading ---------------------------------------------------------
    // A file's text, or nil when it is missing or unreadable.
    *readText { |path|
        ^if(path.notNil and: { File.exists(path) }) { try { File.readAllString(path) } }
    }

    // JSON text read into values that keep their kind: an object is a
    // MegaJsonObject (its members in the file's order, each with the text it
    // was written as), a list an Array, a string a String, a number an
    // Integer or a Float, true and false Booleans, null nil. sclang's own
    // parseJSON answers every one of those as a String, so a number this
    // build does not know could not be written back as it came.
    //
    // Answers the object, or a String saying why the text was refused. A
    // megalooper file is always an object.
    *parseObject { |text|
        var reader, value;
        if(text.isNil or: { text.size == 0 }) { ^"it is empty" };
        reader = MegaJsonReader(text);
        value = reader.read;
        if(reader.error.notNil) { ^"it is not JSON (" ++ reader.error ++ ")" };
        if(value.isKindOf(MegaJsonObject).not) { ^"it is not a JSON object" };
        ^value
    }

    // The format and version rules every megalooper file follows: `object`
    // (from parseObject) must name `format`; a file with no version is
    // version 1; one from a newer build is refused whole, so it is never
    // written over by a build that would drop what it holds. Answers the
    // version (an Integer), or a String saying why not.
    *versionOf { |object, format, newest = 1, what = "megalooper file"|
        var version;
        if(object.at("format") != format) { ^"it is not a " ++ what };
        version = object.at("version") ? 1;
        if(version.isKindOf(Integer).not) { ^"its version can't be read" };
        if(version > newest) {
            ^"it is from a newer megalooper (version " ++ version ++ "; this one reads " ++ newest ++ ")"
        };
        ^version
    }

    // ---- writing ---------------------------------------------------------
    *jsonString { |s|
        var out = String.new;
        out = out.add($");
        s.asString.do { |c|
            var code = c.ascii;
            case
            { c == $\\ } { out = out ++ "\\\\" }
            { c == $" } { out = out ++ "\\\"" }
            { c == $\n } { out = out ++ "\\n" }
            { c == $\r } { out = out ++ "\\r" }
            { c == $\t } { out = out ++ "\\t" }
            { (code >= 0) and: { code < 32 } } { out = out ++ "\\u" ++ code.asHexString(4) }
            { out = out.add(c) };
        };
        ^out.add($")
    }

    // A number as JSON has it: null for inf and NaN, which JSON cannot say.
    *jsonNumber { |x|
        ^if((x != x) or: { x.abs == inf }) { "null" } { x.asString }
    }

    // Any value on one line: an object's members in their own order
    // (MegaJsonObject) or sorted by key (a Dictionary), nil as null.
    *json { |v|
        ^case
        { v.isNil } { "null" }
        { v.isKindOf(Boolean) } { v.asString }
        { v.isNumber } { this.jsonNumber(v) }
        { v.isKindOf(String) or: { v.isKindOf(Symbol) } } { this.jsonString(v.asString) }
        { v.isKindOf(MegaJsonObject) } {
            "{" ++ v.keys.collect { |k, i| this.jsonString(k) ++ ": " ++ this.json(v.values[i]) }.join(", ") ++ "}"
        }
        { v.isKindOf(Dictionary) } {
            "{" ++ v.keys.asArray.sort { |a, b| a.asString < b.asString }.collect { |k|
                this.jsonString(k.asString) ++ ": " ++ this.json(v[k]) }.join(", ") ++ "}"
        }
        { v.isKindOf(SequenceableCollection) } { "[" ++ v.collect { |x| this.json(x) }.asArray.join(", ") ++ "]" }
        { this.jsonString(v.asString) }
    }

    // `text` to `path`, whole or not at all: written beside it under a name
    // of this process's own, read back (`check`, a function of the text read
    // that answers nil when it is good, else why not), the file it replaces
    // copied to `backup` if one is named and there is one, then moved into
    // place. Until that move the old file is untouched. With `keepBackup`,
    // a backup already there stays: of two writes in one second, whose
    // backups share a name, the first one's holds the older file (a sound's
    // backup keeps a plugin's state file alive, so the older one must not
    // go); without, the later write's copy replaces it, as the MIDI map's
    // always did. `action` gets true, or false and why. The copy and the
    // move are a shell's: asynchronous, so the language's clocks keep time,
    // unless `sync`. The temporary file is this process's and this write's
    // own, so two megaloopers, or two writes on their way, never share one.
    *write { |path, text, check, backup, action, sync = false, keepBackup = false|
        var tmp = path ++ ".tmp" ++ thisProcess.pid ++ "-" ++ (writes = writes + 1), why, cmd, done;
        why = try {
            File.mkdir(path.dirname);
            File.use(tmp, "w", { |f| f.write(text) });
            check !? { |c| c.value(this.readText(tmp)) }
        } { |err| err.errorString };
        if(why.notNil) {
            if(File.exists(tmp)) { File.delete(tmp) };
            action.value(false, why);
        } {
            cmd = "";
            if(backup.notNil and: { File.exists(path) } and: { keepBackup.not or: { File.exists(backup).not } }) {
                File.mkdir(backup.dirname);
                cmd = "/bin/cp -p " ++ path.shellQuote ++ " " ++ backup.shellQuote ++ " && ";
            };
            cmd = cmd ++ "/bin/mv -f " ++ tmp.shellQuote ++ " " ++ path.shellQuote;
            done = { |code|
                if(code == 0) { action.value(true) } {
                    if(File.exists(tmp)) { File.delete(tmp) };
                    action.value(false, "the move failed (" ++ code ++ ")")
                }
            };
            if(sync or: { alwaysSync == true }) { done.(cmd.systemCmd) } { cmd.unixCmd(done, false) };
        };
    }

    // The same, at once: nil when it is written, else why not.
    *writeNow { |path, text, check, backup|
        var result;
        this.write(path, text, check, backup, { |ok, why| result = if(ok) { nil } { why ? "it was not written" } }, true);
        ^result
    }

    // ---- a folder of yours, first made -------------------------------------
    // What megalooper once kept in its own folder (the repo) and now keeps in
    // yours: `to` is made, and the files of `from` matching `pattern` are
    // copied into it. Once: `to` being there is the marker, so a file you
    // delete later does not come back. Copied, never moved: what lay in
    // `from` stays. Answers the names copied (none when `from` holds none),
    // or nil when `to` was there and nothing was done.
    *adopt { |from, to, pattern = "*.scd"|
        var paths;
        if(File.exists(to)) { ^nil };
        File.mkdir(to);
        if(File.exists(to).not) { ^nil };
        paths = if(from.notNil and: { File.exists(from) }) { (from +/+ pattern).pathMatch.sort } { [] };
        ^paths.select { |p| (try { File.copy(p, to +/+ p.basename); true } { false }) == true }
            .collect { |p| p.basename }
    }

    // The files of `dir` matching `pattern`, newest first by name (a stamp
    // sorts by time), all but the first `keep` deleted. Answers those kept.
    *trim { |dir, pattern = "*.json", keep = 5|
        var all = (dir +/+ pattern).pathMatch.sort.reverse;
        all.drop(keep).do { |p| File.delete(p) };
        ^all.keep(keep)
    }
}

// A JSON object as it stood in its file: its members in order, each value
// with the text it was written as (`raws`), and the object's own text
// (`raw`), so what this build does not know goes back byte for byte. A name
// written twice is kept twice; `at` answers the last.
MegaJsonObject {
    var <keys, <values, <raws, <>raw;

    *new { ^super.new.init }

    init {
        keys = List.new;
        values = List.new;
        raws = List.new;
    }

    add { |key, value, rawText|
        keys.add(key.asString);
        values.add(value);
        raws.add(rawText);
    }

    prIndex { |key|
        var name = key.asString, found;
        keys.do { |k, i| if(k == name) { found = i } };
        ^found
    }

    at { |key| ^this.prIndex(key) !? { |i| values[i] } }
    rawAt { |key| ^this.prIndex(key) !? { |i| raws[i] } }
    includesKey { |key| ^this.prIndex(key).notNil }
    size { ^keys.size }

    // fn gets (key, value, raw text) per member, in the file's order.
    keysValuesDo { |fn| keys.do { |k, i| fn.value(k, values[i], raws[i]) } }
}

// JSON text read one value at a time (MegaFiles.parseObject). Strict: what
// JSON does not allow is an error, said in `error` with where it stands.
MegaJsonReader {
    var text, pos = 0, size, <error;

    *new { |text| ^super.newCopyArgs(text).init }

    init { size = text.size }

    // The document's value. On an error it answers nil and `error` says why
    // (a document that is null answers nil with no error).
    read {
        var value;
        try {
            this.prSkip;
            value = this.prValue(0);
            this.prSkip;
            if(pos < size) { this.prFail("text after its end") };
        } { |err|
            error = error ?? { err.errorString };
            value = nil;
        };
        ^value
    }

    prFail { |why|
        error = why ++ " at character " ++ pos;
        Error(error).throw;
    }

    prSkip {
        var c;
        while { (pos < size) and: { c = text[pos]; (c == $ ) or: { c == $\n } or: { c == $\r } or: { c == $\t } } } {
            pos = pos + 1;
        };
    }

    prValue { |depth|
        var c;
        if(pos >= size) { this.prFail("it ends early") };
        if(depth > 64) { this.prFail("it is nested too deep") };
        c = text[pos];
        ^case
        { c == ${ } { this.prObject(depth) }
        { c == $[ } { this.prArray(depth) }
        { c == $" } { this.prString }
        { c == $t } { this.prWord("true", true) }
        { c == $f } { this.prWord("false", false) }
        { c == $n } { this.prWord("null", nil) }
        { (c == $-) or: { c.isDecDigit } } { this.prNumber }
        { this.prFail("an unexpected " ++ c) }
    }

    prWord { |word, value|
        if(text.copyRange(pos, pos + word.size - 1) != word) { this.prFail("an unknown word") };
        pos = pos + word.size;
        ^value
    }

    prNumber {
        var start = pos, slice, c;
        while { (pos < size) and: { c = text[pos]; c.isDecDigit or: { "-+.eE".includes(c) } } } { pos = pos + 1 };
        slice = text.copyRange(start, pos - 1);
        if("^-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][-+]?[0-9]+)?$".matchRegexp(slice).not) {
            pos = start;
            this.prFail("a number that is none");
        };
        // A whole number an Integer holds stays one; sclang's are 32 bits.
        ^if(slice.any { |x| ".eE".includes(x) } or: { slice.asFloat.abs > 2147483647 }) { slice.asFloat } { slice.asInteger }
    }

    prString {
        var start = pos + 1, out, c, plain = true;
        pos = start;
        // The common case, no escape: one slice.
        while { (pos < size) and: { c = text[pos]; (c != $") and: { c != $\\ } } } { pos = pos + 1 };
        if(pos >= size) { this.prFail("a string that never ends") };
        if(text[pos] == $") {
            pos = pos + 1;
            ^text.copyRange(start, pos - 2)
        };
        out = text.copyRange(start, pos - 1);
        while { (pos < size) and: { text[pos] != $" } } {
            c = text[pos];
            if(c == $\\) {
                pos = pos + 1;
                if(pos >= size) { this.prFail("a string that never ends") };
                c = text[pos];
                case
                { c == $n } { out = out.add($\n) }
                { c == $t } { out = out.add($\t) }
                { c == $r } { out = out.add($\r) }
                { c == $b } { out = out.add(8.asAscii) }
                { c == $f } { out = out.add(12.asAscii) }
                { (c == $") or: { c == $\\ } or: { c == $/ } } { out = out.add(c) }
                { c == $u } { out = out ++ this.prUnicode }
                { this.prFail("an unknown escape") };
                pos = pos + 1;
            } {
                out = out.add(c);
                pos = pos + 1;
            };
        };
        if(pos >= size) { this.prFail("a string that never ends") };
        pos = pos + 1;
        ^out
    }

    // \uXXXX at pos (on the u), as UTF-8; a surrogate pair is read as one.
    // Leaves pos on the escape's last digit.
    prUnicode {
        var code = this.prHex4(pos + 1), low;
        pos = pos + 4;
        if((code >= 0xD800) and: { code <= 0xDBFF } and: { text[pos + 1] == $\\ } and: { text[pos + 2] == $u }) {
            low = this.prHex4(pos + 3);
            if((low >= 0xDC00) and: { low <= 0xDFFF }) {
                code = 0x10000 + ((code - 0xD800) * 1024) + (low - 0xDC00);
                pos = pos + 6;
            };
        };
        ^this.prUtf8(code)
    }

    prHex4 { |at|
        var code = 0, d;
        if((at + 3) >= size) { this.prFail("a \\u escape cut short") };
        4.do { |i|
            d = text[at + i].digit;
            if(text[at + i].isAlphaNum.not or: { d > 15 }) { this.prFail("a \\u escape that is no hex") };
            code = (code * 16) + d;
        };
        ^code
    }

    prUtf8 { |code|
        var bytes = case
        { code < 0x80 } { [code] }
        { code < 0x800 } { [0xC0 + (code >> 6), 0x80 + (code & 0x3F)] }
        { code < 0x10000 } { [0xE0 + (code >> 12), 0x80 + ((code >> 6) & 0x3F), 0x80 + (code & 0x3F)] }
        { [0xF0 + (code >> 18), 0x80 + ((code >> 12) & 0x3F), 0x80 + ((code >> 6) & 0x3F), 0x80 + (code & 0x3F)] };
        ^String.newFrom(bytes.collect(_.asAscii))
    }

    prArray { |depth|
        var out = List.new;
        pos = pos + 1;
        this.prSkip;
        if((pos < size) and: { text[pos] == $] }) { pos = pos + 1; ^out.asArray };
        while {
            this.prSkip;
            out.add(this.prValue(depth + 1));
            this.prSkip;
            if(pos >= size) { this.prFail("a list that never ends") };
            text[pos] == $,
        } { pos = pos + 1 };
        if(text[pos] != $]) { this.prFail("a list with something else where a comma belongs") };
        pos = pos + 1;
        ^out.asArray
    }

    prObject { |depth|
        var out = MegaJsonObject.new, start = pos, key, from, value;
        pos = pos + 1;
        this.prSkip;
        if((pos < size) and: { text[pos] == $} }) {
            pos = pos + 1;
            out.raw = text.copyRange(start, pos - 1);
            ^out
        };
        while {
            this.prSkip;
            if((pos >= size) or: { text[pos] != $" }) { this.prFail("a member with no name") };
            key = this.prString;
            this.prSkip;
            if((pos >= size) or: { text[pos] != $: }) { this.prFail("a name with no colon") };
            pos = pos + 1;
            this.prSkip;
            from = pos;
            value = this.prValue(depth + 1);
            out.add(key, value, text.copyRange(from, pos - 1));
            this.prSkip;
            if(pos >= size) { this.prFail("an object that never ends") };
            text[pos] == $,
        } { pos = pos + 1 };
        if(text[pos] != $}) { this.prFail("an object with something else where a comma belongs") };
        pos = pos + 1;
        out.raw = text.copyRange(start, pos - 1);
        ^out
    }
}
