const string PageUID = "AutosaveGhosts";
uint g_numSaved = 0;
bool permissionsOkay = false;

void Main() {
    CheckRequiredPermissions();
    MLHook::RequireVersionApi('0.3.2');
    @hook = AutosaveGhostEvents();
    startnew(InitCoro);
}

void CheckRequiredPermissions() {
    permissionsOkay = Permissions::CreateLocalReplay()
        && Permissions::PlayAgainstReplay()
        && Permissions::OpenReplayEditor();
    if (!permissionsOkay) {
        NotifyWarn("You appear not to have club access.\n\nThis plugin won't work, sorry :(.");
        while(true) { sleep(10000); } // do nothing forever
    }
}

void OnDestroyed() { _Unload(); }
void OnDisabled() { _Unload(); }
void _Unload() {
    trace('_Unload, unloading hooks and removing injected ML');
    // MLHook::UnregisterMLHooksAndRemoveInjectedML();
    MLHook::UnregisterMLHookFromAll(hook);
    MLHook::RemoveInjectedMLFromPlayground(PageUID);
}

AutosaveGhostEvents@ hook = null;
void InitCoro() {
    if (!permissionsOkay) return;
    // MLHook::RegisterMLHook(hook);
    MLHook::RegisterMLHook(hook, PageUID + "_SavedGhost");
    sleep(50);
    // ml load
    MLHook::InjectManialinkToPlayground(PageUID, AUTOSAVEGHOSTS_SCRIPT_TXT, true);
    startnew(MainCoro);
    sleep(200);
    UpdateAllMLVariables(); // send stuff to ML in case we're loading while in a map; but wait a few frames
}

void MainCoro() {
    if (!permissionsOkay) return;
    startnew(WatchForValidationReplays);
    while (true) {
        yield();
        if (lastMap != CurrentMap) {
            lastMap = CurrentMap;
            OnMapChange();
        }
    }
}

void WatchForValidationReplays() {
    while (true) {
        yield();
        if (!S_SaveValidationReplays || !S_AutosaveActive) continue;
        // check for editor too b/c we only care about validation replays here
        auto editor = cast<CGameCtnEditorFree>(GetApp().Editor);
        auto pgScript = cast<CSmArenaRulesMode>(GetApp().PlaygroundScript);
        if (editor is null || pgScript is null) continue;
        CheckForNewGhosts(pgScript.DataFileMgr);
    }
}

dictionary seenValidationGhosts;
uint lastNbValidationGhosts;
void CheckForNewGhosts(CGameDataFileManagerScript@ dfm) {
    if (lastNbValidationGhosts == dfm.Ghosts.Length) return;
    lastNbValidationGhosts = dfm.Ghosts.Length;
    trace('nb validation ghosts: ' + lastNbValidationGhosts);
    CGameGhostScript@[] toSave;
    for (uint i = 0; i < dfm.Ghosts.Length; i++) {
        auto ghost = dfm.Ghosts[i];
        if (seenValidationGhosts.Exists(ghost.IdName)) continue;
        seenValidationGhosts[ghost.IdName] = true;
        auto time = ghost.Result.Time;
        if (seenValidationGhosts.Exists('time:' + time)) continue;
        seenValidationGhosts['time:' + time] = true;
        toSave.InsertLast(ghost);
    }
    for (uint i = 0; i < toSave.Length; i++) {
        auto ghost = toSave[i];
        int saveWindowMs = GetSaveWindowMs();
        if (!(saveWindowMs < 0 || ghost.Result.Time <= saveWindowMs)) continue;
        auto savePath = GetValidationGhostFileName(ghost);
        dfm.Replay_Save(savePath, GetApp().RootMap, ghost);
        g_numSaved++;
        NotifySaved(savePath);
        startnew(RefreshPbFilterSoon);
        yield();
    }
}

const string GetValidationGhostFileName(CGameGhostScript@ ghost) {
    string name = Text::StripFormatCodes(ghost.Nickname);
    auto time = ghost.Result.Time;
    auto date = GetApp().PlaygroundScript.System.CurrentLocalDateText.Replace("/", "-").Replace(":", "-");
    auto mapName = Text::StripFormatCodes(GetApp().RootMap.MapInfo.Name);
    if (S_FileNameDateAtEnd) {
        return "AutosavedGhosts\\" + mapName + "-validation\\" + mapName + "-" + name + "-" + time + "ms-" + date + ".Replay.gbx";
    }
    return "AutosavedGhosts\\" + mapName + "-validation\\" + date + "-" + mapName + "-" + name + "-" + time + "ms.Replay.gbx";
}

void OnMapChange() {
    startnew(UpdateAllMLVariables);
}

void UpdateAllMLVariables() {
    UpdateMLAutosaveActive();
    UpdateMLSaveFilter();
}

void ToggleAutosaveActive() {
    S_AutosaveActive = !S_AutosaveActive;
    UpdateMLAutosaveActive();
}

// crucially: used in UpdateMLAutosaveActive
bool get_AutosaveCurrentlyActive() {
    if (!S_AutosaveActive) return false;
    if (S_DisableForLocal && GetApp().PlaygroundScript !is null) return false;
    auto si = cast<CTrackManiaNetworkServerInfo>(GetApp().Network.ServerInfo);
    // don't save if we're in an archivist game mode
    if (si is null || si.CurGameModeStr.Contains("_Archivist_")) return false;
    return true;
}

void UpdateMLAutosaveActive() {
    MLHook::Queue_MessageManialinkPlayground(PageUID, {"AutosaveActive", AutosaveCurrentlyActive ? "True" : "False"});
}

// Gets map UID and TA mode variant for score lookups.
bool TryGetCurrentMapInfo(string &out mapUid, string &out gameMode) {
    auto map = GetApp().RootMap;
    if (map is null || map.MapInfo is null) return false;
    mapUid = map.MapInfo.MapUid;
    gameMode = map.MapInfo.TMObjective_NbClones > 0 ? "TimeAttackClone" : "TimeAttack";
    return mapUid.Length > 0;
}

// Reads the current map personal best time from the score manager.
int GetCurrentMapPersonalBest() {
    string mapUid, gameMode;
    if (!TryGetCurrentMapInfo(mapUid, gameMode)) return -1;
    auto network = cast<CTrackManiaNetwork>(GetApp().Network);
    if (network is null || network.ClientManiaAppPlayground is null) {
        return -1;
    }
    auto scoreMgr = network.ClientManiaAppPlayground.ScoreMgr;
    if (scoreMgr is null) return -1;
    return scoreMgr.Map_GetRecord_v2(0x100, mapUid, "PersonalBest", "", gameMode, "");
}

// Computes the max save time based on PB and selected threshold.
int GetSaveWindowMs() {
    if (!S_OnlySaveNearPb) return -1;
    int pbMs = GetCurrentMapPersonalBest();
    if (pbMs <= 0) return -1;
    float nearPbValue = Math::Max(0.0f, S_NearPbValue);
    if (S_NearPbUnit == PBUnitType::Seconds) {
        return pbMs + int(nearPbValue * 1000.0f + 0.5f);
    }
    return pbMs + int(float(pbMs) * nearPbValue / 100.0f + 0.5f);
}


// Pushes PB filter state and threshold to the injected ML script.
void UpdateMLSaveFilter() {
    int saveWindowMs = GetSaveWindowMs();
    bool filterEnabled = S_OnlySaveNearPb && saveWindowMs >= 0;
    MLHook::Queue_MessageManialinkPlayground(PageUID, {"PbFilterEnabled", filterEnabled ? "True" : "False"});
    MLHook::Queue_MessageManialinkPlayground(PageUID, {"MaxSaveTimeMs", tostring(saveWindowMs)});
    MLHook::Queue_MessageManialinkPlayground(PageUID, {"FileNameDateAtEnd", S_FileNameDateAtEnd ? "True" : "False"});
}

// Refreshes the PB filter shortly after a save to follow PB updates.
void RefreshPbFilterSoon() {
    sleep(1500);
    UpdateMLSaveFilter();
}

void ForceSaveAllGhosts() {
    NotifyForceSave();
    MLHook::Queue_MessageManialinkPlayground(PageUID, {"ResetAndSaveAll"});
    UpdateAllMLVariables();
}

/* Hook Outgoing Notification Events */
class AutosaveGhostEvents : MLHook::HookMLEventsByType {
    AutosaveGhostEvents() {
        super(PageUID);
        startnew(CoroutineFunc(this.MainCoro));
    }

    MLHook::PendingEvent@[] pending;
    void MainCoro() {
        while (true) {
            yield();
            while (pending.Length > 0) {
                ProcessEvent(pending[pending.Length - 1]);
                pending.RemoveLast();
            }
        }
    }

    void OnEvent(MLHook::PendingEvent@ event) override {
        pending.InsertLast(event);
    }

    void ProcessEvent(MLHook::PendingEvent@ event) {
        if (event.type.EndsWith("SavedGhost")) {
            OnSavedGhost(event);
        }
    }

    void OnSavedGhost(MLHook::PendingEvent@ event) {
        g_numSaved++;
        if (event.data.Length < 0) {
            warn("OnSavedGhost didn't get a file name!");
        } else {
            NotifySaved(event.data[0]);
        }
        startnew(RefreshPbFilterSoon);
    }

    // void OnSavedGhost(MLHook::PendingEvent@ event) {
    // }
}

void NotifySaved(const string &in filename) {
    string msg = "Saved ghost and replay: " + filename;
    UI::ShowNotification(Meta::ExecutingPlugin().Name, msg, vec4(.1, .6, .3, .3), 7500);
    trace(msg);
}
void NotifyForceSave() {
    string msg = "Force-saving all of your ghosts (if none show up, there probably are none atm)";
    UI::ShowNotification(Meta::ExecutingPlugin().Name, msg, vec4(.1, .6, .3, .3), 7500);
    trace(msg);
}

void NotifyWarn(const string &in msg) {
    UI::ShowNotification(Meta::ExecutingPlugin().Name, msg, vec4(1, .5, .1, .5), 10000);
    warn(msg);
}


/** Called when a setting in the settings panel was changed. */
void OnSettingsChanged() {
    if (!permissionsOkay) return;
    UpdateAllMLVariables();
}

const string get_HotkeyStr() {
    return S_HotkeyEnabled ? tostring(S_Hotkey) : "";
}

bool i_shiftKeyDown = false;
/** Called whenever a key is pressed on the keyboard. See the documentation for the [`VirtualKey` enum](https://openplanet.dev/docs/api/global/VirtualKey). */
UI::InputBlocking OnKeyPress(bool down, VirtualKey key) {
    if (!permissionsOkay) return UI::InputBlocking::DoNothing;
    if (key == VirtualKey::Shift) i_shiftKeyDown = down;
    if (down) {
        if (S_HotkeyEnabled && key == S_Hotkey) {
            ToggleAutosaveActive();
        }
    }
    return UI::InputBlocking::DoNothing;
}

void RenderInterface() {
}

void RenderMenu() {
    if (!permissionsOkay) return;
    if (UI::MenuItem("\\$f22" + Icons::Circle + "\\$z Autosave Ghosts", HotkeyStr, S_AutosaveActive)) {
        ToggleAutosaveActive();
    }
}

bool isMenuMainHovered = false;
/** Render function called every frame intended only for menu items in the main menu of the `UI`.*/
void RenderMenuMain() {
    if (!permissionsOkay) return;
    isMenuMainHovered = false;
    bool shouldRender = S_MenuBarQuickToggleOff && S_AutosaveActive || S_MenuBarQuickToggleOn && !S_AutosaveActive;
    if (!shouldRender) return;

	string label, recColor, labelColor;
	if (Time::Stamp % 2 == 1 && S_OscillateColors) {
		recColor = "\\$822";
		labelColor = "\\$666";
	} else {
		recColor = "\\$f22";
		labelColor = "\\$z";
	}

	if (S_MenuBarFloatOnRight) {
		label = S_AutosaveActive
			? (recColor + Icons::Circle + labelColor + " REC (" + g_numSaved + ")")
			: ("\\$dd3" + Icons::Pause + " REC");
	} else {
		label = S_AutosaveActive
			? ("\\$f22" + Icons::Circle + "\\$z Autosaving Ghosts (" + g_numSaved + ")")
			: ("\\$dd3" + Icons::Pause + "\\$z Autosave Ghosts");
	}

	auto pos = UI::GetCursorPos();
	if (S_MenuBarFloatOnRight) {
        auto textSize = UI::MeasureString(label);
		UI::SetCursorPos(vec2(UI::GetWindowSize().x - textSize.x - S_MenuBarFloatOffset - UI::GetStyleVarVec2(UI::StyleVar::WindowPadding).x * 1.5, pos.y));
	}

	bool wasClicked = UI::MenuItem(label, HotkeyStr);

	if (S_MenuBarFloatOnRight) {
		UI::SetCursorPos(pos);
	}

    string hotkeyExtra = S_HotkeyEnabled ? "\n\\$bbbHotkey: " + HotkeyStr + "\\$z" : "";
    string mainTooltip = (S_AutosaveActive ? "Click to disable autosaving new ghosts.\nShift click to force-save a replay of all current personal ghosts." : "Click to start autosaving new ghosts.");
    AddSimpleTooltip(mainTooltip + hotkeyExtra);
    if (wasClicked && S_AutosaveActive && i_shiftKeyDown) {
        startnew(ForceSaveAllGhosts);
    } else if (wasClicked && !i_shiftKeyDown) {
        ToggleAutosaveActive();
    }
}

string lastMap = "";
string get_CurrentMap() {
    auto map = GetApp().RootMap;
    if (map is null) return "";
    // return map.EdChallengeId;
    return map.MapInfo.MapUid;
}

string get_MapNameSafe() {
    auto map = GetApp().RootMap;
    if (map is null) return "";
    return Text::StripFormatCodes(map.MapName);
}

string get_CurrentDateText() {
    auto mpsapi = cast<CGameManiaPlanet>(GetApp()).ManiaPlanetScriptAPI;
    return mpsapi.CurrentLocalDateText.Replace("/", "-").Replace(":", "-");
}

/*

settings

*/

[Setting category="Autosave Ghosts" name="Autosave Active?" description="While active, this plugin will autosave replays. When not active, it will sit in the background, biding its time, waiting for you to reactivate it."]
bool S_AutosaveActive = true;

[Setting category="Autosave Ghosts" name="Autosave Validation Replays?" description="When validating a map, validation replays will be automatically saved."]
bool S_SaveValidationReplays = true;


enum PBUnitType {
    Percent,
    Seconds
}

[Setting category="PB Filter" name="Enable Near-PB Filter" description="Only save runs within the chosen threshold of the personal best"]
bool S_OnlySaveNearPb = false;

[Setting category="PB Filter" drag min=0 max=100 name="PB Threshold" description="Threshold value in the selected unit (percent or seconds)"]
float S_NearPbValue = 2.0f;

[Setting category="PB Filter" name="PB Unit" description="Unit used for the threshold"]
PBUnitType S_NearPbUnit = PBUnitType::Percent;

[Setting category="Autosave Ghosts" name="Put Date At End Of File Name" description="Append the date to autosaved ghost file names instead of prefixing it."]
bool S_FileNameDateAtEnd = false;


[Setting category="Autosave Ghosts" name="MenuBar Quick Toggle Off" description="Show a button in the main menu bar to quickly toggle autosaving off (stop saving replays)."]
bool S_MenuBarQuickToggleOff = true;

[Setting category="Autosave Ghosts" name="MenuBar Quick Toggle On" description="Show a button in the main menu bar to quickly toggle autosaving on (start saving replays)."]
bool S_MenuBarQuickToggleOn = false;

[Setting category="Autosave Ghosts" name="Compact MenuBar" description="Show the menubar toggle on the right-hand side of the Overlay. You will need to manually adjust the offset to accomodate other plugins (like Clock)"]
bool S_MenuBarFloatOnRight = false;

[Setting category="Autosave Ghosts" drag name="Compact MenuBar Blink (.5Hz)" description="If compact MenuBar is enabled, the MenuBar item will darken and lighten on a .5 Hz cycle. No effect if compact MenuBar is disabled."]
bool S_OscillateColors = true;

[Setting category="Autosave Ghosts" drag min=0 max=3000 name="Compact MenuBar Offset" description="How far over to put the recording indicator. A value of 200 works well for the Clock plugin."]
int S_MenuBarFloatOffset = 200;

[Setting category="Autosave Ghosts" name="Disable for Local Runs" description="When checked, replays will not be autosaved for local runs."]
bool S_DisableForLocal = false;

[Setting category="Autosave Ghosts" name="Hotkey Enabled" description="The hotkey will only work if this is checked."]
bool S_HotkeyEnabled = true;

[Setting category="Autosave Ghosts" name="Hotkey" description="Hotkey to toggle saving or not."]
VirtualKey S_Hotkey = VirtualKey::F7;
