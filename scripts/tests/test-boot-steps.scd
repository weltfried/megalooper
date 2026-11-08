// The boot's steps (setup-boot.scd): boot.scd runs what follows the server as
// named steps, and the first that throws stops the boot there, says which
// step and why, and tells the launcher (~bootFailed), instead of leaving its
// window on "Booting…". Steps in order; the ones after a failure skipped; a
// hook that throws costs nothing; a step that waits in the boot's routine and
// then throws is caught all the same. Then boot.scd and launcher.scd as text:
// the boot runs its steps through this, and the launcher listens.
//
// docs/dev/architecture.md, 5, step 3.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-boot-steps");

{
var scripts = thisProcess.nowExecutingPath.dirname.dirname;
var ran = List.new, told = List.new, finished = 0, going, r, boot, launcher, saved;
(scripts +/+ "setup-boot.scd").load;
saved = [~bootFailed, ~bootFinished];
~bootFailed = { |step, err| told.add([step, err.errorString]) };
~bootFinished = { finished = finished + 1 };

~bootReset.();
~bootStep.("one", { ran.add(\one) });
~bootStep.("two", { ran.add(\two) });
~bootFinish.();
~tEq.("the steps run in order", ran.asArray, [\one, \two]);
~tEq.("…and a boot with none failing is done", ~bootStage, \done);
~tEq.("…and says so once", finished, 1);
~tEq.("…and tells no failure", told.asArray, []);

ran.clear; finished = 0;
~bootReset.();
~bootStep.("one", { ran.add(\one) });
going = ~bootStep.("two", { ran.add(\two); Error("on purpose").throw; ran.add(\never) });
~bootStep.("three", { ran.add(\three) });
~bootFinish.();
~tEq.("a step that throws stops the boot there", ran.asArray, [\one, \two]);
~tEq.("…and answers that the boot is not going", going, false);
~tEq.("…and is the stage the boot stopped at", ~bootStage, "two");
~tEq.("…and its failure is kept, step and error", [~bootFailure[\step], ~bootFailure[\error].errorString.contains("on purpose")], ["two", true]);
~tEq.("…and the launcher is told once, which step and why", told.size, 1);
~tAssert.("…with the error's words", told.first !? { |t| t[0] == "two" and: { t[1].contains("on purpose") } } ? false, told.asString);
~tEq.("…and the boot is not said to be done", finished, 0);

told.clear;
~bootReset.();
~tEq.("a new boot starts with no failure", [~bootStage, ~bootFailure], [nil, nil]);
~bootFailed = { |step, err| Error("the hook on fire").throw };
going = try { ~bootStep.("one", { nil.foo }); true } { false };
~tEq.("a hook that throws costs the boot nothing more", going, true);
~bootFailed = { |step, err| told.add([step, err.errorString]) };

// A step in the boot's routine that waits (MegaSA's waitForReady) and throws
// after: caught as well. A yield stands in for the wait, so the routine can be
// stepped here by hand.
ran.clear; told.clear;
~bootReset.();
r = Routine {
    ~bootStep.("waits", { ran.add(\before); nil.yield; ran.add(\after); Error("after the wait").throw });
    ~bootStep.("next", { ran.add(\next) });
    ran.add(\end);
};
r.next;
~tEq.("a step that waits is still running at its wait", ran.asArray, [\before]);
r.next;
~tEq.("…and throwing after the wait stops the boot there", ran.asArray, [\before, \after, \end]);
~tAssert.("…and is told", told.first !? { |t| t[0] == "waits" and: { t[1].contains("after the wait") } } ? false, told.asString);

boot = File.readAllString(scripts +/+ "boot.scd") ? "";
launcher = File.readAllString(scripts +/+ "launcher.scd") ? "";
~tAssert.("boot.scd starts each boot afresh", boot.contains("~bootReset.();"));
~tAssert.("…runs what follows the server as steps", boot.findRegexp("~bootStep\\.\\(\"").size >= 8,
    boot.findRegexp("~bootStep\\.\\(\"").size.asString);
~tAssert.("…and says when it is done", boot.contains("~bootFinish.();"));
~tAssert.("the launcher listens for a step that failed and for the end",
    launcher.contains("~bootFailed = {") and: { launcher.contains("~bootFinished = {") });

~bootFailed = saved[0]; ~bootFinished = saved[1];
~bootReset.();
}.value;
