# Autosave Ghosts

**This plugin requires _MLHook_ -- you must install that, too.**

This plugin will autosave a playable `.Replay.gbx` file for ghosts that you generate, even in online servers.
By default it saves every finished run, but you can optionally restrict it to runs that are close to your current PB on the map.
But the run must be completed (it does not save partial runs).
To save partial runs (that aren't able to be played against), see [Autosave Replays for MediaTracker](https://openplanet.dev/plugin/autosavereplaysformt).

Works in:
* Ranked
* COTD Quali and KO
* Local campaign (*note:* was previously unreliable, please report any bugs; if you need an alternate solution, see [Replay Recorder](https://openplanet.dev/plugin/replayrecorder))

Does not work in:
* Royal

Save path: `Trackmania\Replays\AutosavedGhosts\<MapName>\<Date>-<MapName>-<Nickname>-<RaceTime>.Replay.gbx`

How it works:
When you complete a run, even in online servers, a ghost is generated in `app.Network.ClientManiaAppPlayground.DataFileMgr.Ghosts`.
Calling `app.Network.ClientManiaAppPlayground.DataFileMgr.Replay_Save` on these ghosts will generate a valid replay (*valid* meaning: there is 1 ghost and you can is it via 'Play > Local > Against Replay').
~~AFAIK, you can't save these ghosts using `DataFileMgr.Replay_Save` _from AngelScript_.~~ (Actually, I think you can; a future version will be refactored to do this.)
If you call `DataFileMgr.Save_Replay` from ManiaLink, then it does generate a playable replay.
This plugin automatically detects new ghosts, filters out duplicates (like your PB ghost) and external ghosts (e.g., the WR ghost), and saves the remaining ghosts.

Propz to @Orange for asking the question that lead to this plugin: ghost CP times in MLFeed.

License: Public Domain

Authors: XertroV

Suggestions/feedback: @XertroV on Openplanet discord

Code/issues: [https://github.com/XertroV/tm-autosave-ghosts](https://github.com/XertroV/tm-autosave-ghosts)

GL HF
