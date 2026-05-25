const string AUTOSAVEGHOSTS_SCRIPT_TXT = """
// one space indent otherwise they're treated as compiler preprocessor statements by openplanet
// note: now done in pre-proc-scripts.py
 #Const C_PageUID "AutosaveGhosts"
 #Include "TextLib" as TL


declare Text G_PreviousMapUid;

// settings and stuff from angelscript
declare Boolean AutosaveActive;
declare Boolean SetAutosaveActive;
declare Boolean PbFilterEnabled;
declare Integer MaxSaveTimeMs;
declare Boolean FileNameDateAtEnd;

// state
declare Integer[][][Integer] SeenTimes;
declare Integer NbLastSeen;
declare Integer OnlySaveAfter;

// logging function, should be "MLHook_LogMe_" + PageUID
Void MLHookLog(Text msg) {
    SendCustomEvent("MLHook_LogMe_"^C_PageUID, [msg]);
}

/// Convert a C++ array to a script array
Integer[] ToScriptArray(Integer[] _Array) {
	return _Array;
}

declare Boolean MapChanged;

Void CheckMapChange() {
    if (Map != Null && Map.MapInfo.MapUid != G_PreviousMapUid) {
        G_PreviousMapUid = Map.MapInfo.MapUid;
        MapChanged = True;
    } else {
        MapChanged = False;
    }
}

// state

Void ResetGhostsState() {
    NbLastSeen = 0;
    SeenTimes.clear();
    OnlySaveAfter = Now + 10000;
    MLHookLog("Reset ghosts state.");
}

// from angelscript

Void CheckIncoming() {
    declare Text[][] MLHook_Inbound_AutosaveGhosts for ClientUI;
    foreach (Event in MLHook_Inbound_AutosaveGhosts) {
        if (Event.count < 2) {
            if (Event[0] == "ResetAndSaveAll") {
                ResetGhostsState();
                OnlySaveAfter = 0;
            } else {
                MLHookLog("Skipped unknown incoming event: " ^ Event);
                continue;
            }
        } else if (Event[0] == "AutosaveActive") {
            AutosaveActive = Event[1] == "True";
            SetAutosaveActive = True;
        } else if (Event[0] == "PbFilterEnabled") {
            PbFilterEnabled = Event[1] == "True";
        } else if (Event[0] == "MaxSaveTimeMs") {
            MaxSaveTimeMs = TL::ToInteger(Event[1]);
        } else if (Event[0] == "FileNameDateAtEnd") {
            FileNameDateAtEnd = Event[1] == "True";
        } else {
            MLHookLog("Skipped unknown incoming event: " ^ Event);
            continue;
        }
        // MLHookLog("Processed Incoming Event: "^Event[0]);
    }
    MLHook_Inbound_AutosaveGhosts = [];
}

Text GetGhostFileName(CGhost Ghost) {
    declare Text Name = TL::StripFormatting(Ghost.Nickname);
    declare Integer GTime = Ghost.Result.Time;
    declare Text TheDate = TL::Replace(TL::Replace(System.CurrentLocalDateText, "/", "-"), ":", "-");
    declare Text MapName = TL::StripFormatting(Map.MapInfo.Name);
    if (FileNameDateAtEnd) {
        return "AutosavedGhosts\\" ^ MapName ^ "\\" ^ MapName ^ "-" ^ Name ^ "-" ^ GTime ^ "ms-" ^ TheDate ^ ".Replay.gbx";
    }
    return "AutosavedGhosts\\" ^ MapName ^ "\\" ^ TheDate ^ "-" ^ MapName ^ "-" ^ Name ^ "-" ^ GTime ^ "ms.Replay.gbx";
}

// will only return true for a ghost the first time it is seen
Boolean ShouldSaveGhost(CGhost Ghost) {
    if (Ghost.Nickname != LocalUser.Name) {
        return False; // only save the local user's ghosts; and not 'Personal Best' (b/c they're already saved)
    }
    if (PbFilterEnabled && MaxSaveTimeMs > 0 && Ghost.Result.Time > MaxSaveTimeMs) {
        return False;
    }
    if (!SeenTimes.existskey(Ghost.Result.Time)) {
        return True; // we don't have this time
    }
    declare Integer[] GhostCPs = ToScriptArray(Ghost.Result.Checkpoints);
    foreach (CpTimes in SeenTimes[Ghost.Result.Time]) { // inside the for loop we'll return if we find a reason to not save this ghost
        if (CpTimes.count != GhostCPs.count) continue; // CPs differ so can't be the same
        declare Boolean IsIdentical = True;
        for (i, 0, CpTimes.count - 1) {
            if (CpTimes[i] != GhostCPs[i]) { // if CP times differ, we'll always hit this
                IsIdentical = False; // so the ghosts differ
                break;
            }
        }
        if (IsIdentical) {
            return False; // if we find a match, return
        }
    }
    return True; // if we get here, we haven't seen this ghost before
}

Void RecordSeen(CGhost Ghost) {
    if (!SeenTimes.existskey(Ghost.Result.Time)) {
        SeenTimes[Ghost.Result.Time] = [];
    }
    SeenTimes[Ghost.Result.Time].add(ToScriptArray(Ghost.Result.Checkpoints));
}

// when we first load the plugin, any existing ghosts are ignored
Void OnFirstLoad() {
    NbLastSeen = DataFileMgr.Ghosts.count;
    foreach (Ghost in DataFileMgr.Ghosts) {
        RecordSeen(Ghost);
        yield;
    }
}

Void CheckGhostsCPData() {
    declare Integer NbGhosts = DataFileMgr.Ghosts.count;
    if (NbGhosts != NbLastSeen) {
        NbLastSeen = NbGhosts;
    }
    declare CGhost[] GhostsToSave;
    foreach (Ghost in DataFileMgr.Ghosts) {
        if (ShouldSaveGhost(Ghost)) {
            RecordSeen(Ghost);
            GhostsToSave.add(Ghost);
        }
    }
    // don't save ghosts in the first 10s of loading a map -- just record that we've seen them.
    // they'll ~never be new ghosts.
    if (Now > OnlySaveAfter && AutosaveActive) {
        foreach (Ghost in GhostsToSave) {
            declare Text ReplayFileName = GetGhostFileName(Ghost);
            DataFileMgr.Replay_Save(ReplayFileName, Map, Ghost);
            SendCustomEvent("MLHook_Event_" ^ C_PageUID ^ "_SavedGhost", [ReplayFileName]);
            MLHookLog("Saved Ghost: " ^ ReplayFileName);
            yield;
        }
    } else {
        MLHookLog("Skipping " ^ GhostsToSave.count ^ " ghosts due to OnlySaveAfter or AutosaveActive");
    }
}

Void OnMapChange() {
    // disabling reset ghosts state. reason: we don't care about clearing ghosts, that will help avoid saving the same things.
    // ResetGhostsState();
    // but we want to avoid resaving anything generated in the near future (like loading a pb ghost)
    OnlySaveAfter = Now + 15000;
}


main() {
    declare Integer LoopCounter = 0;
    MLHookLog("Starting AutosaveGhosts ML");
    yield;
    ResetGhostsState();
    OnFirstLoad();
    while (True) {
        yield;
        LoopCounter += 1;
        CheckIncoming();

        // main logic
        CheckGhostsCPData();
        CheckMapChange();
        if (MapChanged) OnMapChange();
    }
}
""";