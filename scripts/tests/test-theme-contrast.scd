// The themes' accent fills (gui-theme.scd): text on a fill is \onacc, and it
// must be readable on every one of them, in both themes, by WCAG's measure:
// a contrast of 4.5 to 1 or more. The light theme's "armed" and "dub" were
// under it until the device chains' phase 6.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-theme-contrast");

{
var scripts = thisProcess.nowExecutingPath.dirname.dirname;
var fills = #[\loop, \cut, \grain, \fx, \drum, \synth, \rec, \play, \dub, \armed, \map];
// A colour's relative luminance, and the contrast of two (WCAG 2).
var lum = { |c|
    var lin = { |v| if(v <= 0.03928) { v / 12.92 } { ((v + 0.055) / 1.055) ** 2.4 } };
    (0.2126 * lin.(c.red)) + (0.7152 * lin.(c.green)) + (0.0722 * lin.(c.blue))
};
var contrast = { |a, b|
    var la = lum.(a), lb = lum.(b);
    (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
};
var low;

if(~guiThemes.isNil) { (scripts +/+ "gui-theme.scd").load };

~tEq.("black on white is 21 to 1, and a colour on itself 1 to 1 (the measure itself)",
    [contrast.(Color.black, Color.white).round(0.01), contrast.(Color.grey, Color.grey)], [21.0, 1.0]);
~tEq.("both themes have every accent fill and the text that goes on it",
    [\dark, \light].collect { |name| (fills ++ [\onacc]).select { |k| ~guiThemes[name][k].isKindOf(Color).not } }, [[], []]);
[\dark, \light].do { |name|
    var theme = ~guiThemes[name];
    low = fills.select { |k| contrast.(theme[\onacc], theme[k]) < 4.5 }
        .collect { |k| [k, contrast.(theme[\onacc], theme[k]).round(0.01)] };
    ("  " ++ name ++ ": " ++ fills.collect { |k| k ++ " " ++ contrast.(theme[\onacc], theme[k]).round(0.1) }.join(", ")).postln;
    ~tEq.("in the " ++ name ++ " theme, text on every accent fill has a contrast of 4.5 to 1 or more", low, []);
};
~tEq.("the light theme's armed and dub are still what they are: amber and orange, red over green over no blue",
    [\armed, \dub].collect { |k| var c = ~guiThemes[\light][k]; (c.red > c.green) and: { c.green > c.blue } and: { c.blue == 0 } },
    [true, true]);
}.value;
