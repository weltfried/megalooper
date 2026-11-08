// megalooper — the plugins' state jobs: reading or writing a hosted plugin's
// state (its program or its bank) suspends it, and a plugin that is busy
// may pass the guitar through dry: a DI at full scale is a blast. So the
// guitar strip is held (\bank) around every job on a guitar plugin, and the
// jobs run one at a time, in the order they were asked for, across every
// plugin. A save always runs. A load asked for while another for the same
// device still waits replaces it (that one's action gets false), so a burst
// of recalls ends on the last. A plugin that has not answered in 30 s may
// still be busy, so the jobs waiting are dropped rather than sent into it.
//
// A part of MegaSA (docs/dev/architecture.md 5, step 9; MegaSA's own until
// 2026-11-08): it asks MegaSA for the plugin devices (the default one, the
// guitar chain's, the ones still there), holds and lets go of the guitar
// strip through it, and tells every plugin the tempo it may have missed once
// the last job has answered. MegaSA's prStateJob and prBankJob ask it.
MegaSAStateJobs {
    var sa;
    var <bankBusy = false, pendingBank, bankRoutine;

    *new { |sa| ^super.newCopyArgs(sa).init }
    init { pendingBank = List.new }

    // `what`: \save or \load; `kind`: \program or \bank; `device`: the
    // plugin's device (MegaSA's guitar plugin when nil). `action` gets ok.
    run { |what, kind, file, action, device|
        var dev = device ? sa.prPluginDevice;
        var job = [what, kind, file, action, dev];
        // Only the guitar is muted around a job: a loop-chain plugin that is
        // busy passes the loop through, which is no blast.
        var onGuitar = { |j| j[4].notNil and: { sa.guitarChain.devices.includes(j[4]) } };
        if(bankBusy) {
            if(what == \load) {
                pendingBank.copy.do { |old|
                    if((old[0] == \load) and: { old[4] === dev }) { pendingBank.remove(old); old[3].value(false) } };
            };
            pendingBank.add(job);
            ^this
        };
        bankBusy = true;
        if(onGuitar.(job) or: { dev.isNil }) { sa.hold(\guitar, \bank) };
        bankRoutine = Routine {
            while { job.notNil and: { sa.alive } } {
                var done = false, ok = false, waited = 0, plug;
                var reply = { |p, jobOk| ok = jobOk; done = true };
                if(onGuitar.(job)) { sa.hold(\guitar, \bank) };
                0.05.wait;   // the strip's 20 ms fade, then some
                // The plugin as it is now: one an edit has removed since the
                // job was asked for has no state to give or take.
                plug = job[4] !? { |d| if(sa.devices.includes(d)) { d.plugin } };
                case
                { plug.isNil or: { plug.state != \open } } { reply.(nil, false) }
                { job[0] == \save } { plug.saveState(job[1], job[2], reply) }
                { plug.loadState(job[1], job[2], reply) };
                while { done.not and: { waited < 30 } } { 0.05.wait; waited = waited + 0.05 };
                job[3].value(ok);
                // A plugin that has not answered in 30 s may still be busy,
                // and its late answer would be taken for the next job's, so
                // the waiting ones are dropped rather than sent into that.
                if(done.not) {
                    ("MegaSA: " ++ (plug !? { |p| p.name } ? "the plugin") ++ " did not answer in 30 s with " ++ PathName(job[2]).fileName
                        ++ "; a later job may still find it busy.").warn;
                    pendingBank.do { |p| p[3].value(false) };
                    pendingBank.clear;
                    job = nil;
                } {
                    job = if(pendingBank.isEmpty) { nil } { pendingBank.removeAt(0) };
                };
            };
            this.finished;
        }.play(SystemClock);
    }

    // The last job has answered: the plugins, no longer busy, are told the
    // tempo they may have missed meanwhile, and the guitar is let go.
    finished {
        bankBusy = false;
        if(sa.alive) {
            sa.tempo !? { |t| sa.pluginDevices.do { |d| d.plugin.setTempo(t) } };
            sa.unhold(\guitar, \bank);
        };
    }

    // MegaSA freed: the routine stops (unless it is the one freeing it).
    stop {
        bankRoutine !? { |r| if(r !== thisThread) { r.stop } };
        bankRoutine = nil;
    }
}
