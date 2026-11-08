// The app's own model (setup-app.scd): ~app says the state the setup scripts
// hold, and ~say what megalooper has to tell the player, to whoever listens
// (the window, gui-shell.scd's ~appWatch); with nobody listening, the words go
// to the post window. A part loaded again keeps the model and its listeners.
//
// docs/dev/architecture.md, 5, step 4.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-app");

{
var scripts = thisProcess.nowExecutingPath.dirname.dirname;
var heard = List.new, listener, first;
(scripts +/+ "setup-app.scd").load;
first = ~app;
~tAssert.("there is a model", ~app.notNil);
listener = { |obj, what ... args| heard.add([what] ++ args) };
~app.dependants.copy.do { |d| ~app.removeDependant(d) };
~say.("nobody listens");
~tEq.("with nobody listening the words go elsewhere, not to a listener", heard.asArray, []);
~app.addDependant(listener);
~say.("Copied", \info);
~tEq.("with a listener, the words and their kind are said to it", heard.asArray, [[\say, "Copied", \info]]);
heard.clear;
~app.changed(\aiApps, true);
~tEq.("the setup scripts' switches are said the same way", heard.asArray, [[\aiApps, true]]);
(scripts +/+ "setup-app.scd").load;
~tAssert.("a part loaded again keeps the model", ~app === first);
heard.clear;
~say.("still heard");
~tEq.("…and whoever listens to it", heard.asArray, [[\say, "still heard", nil]]);
~app.removeDependant(listener);
}.value;
