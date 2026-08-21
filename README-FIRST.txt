GUSTAV'S ARK: SURVIVAL ASCENDED SERVER

EASIEST METHOD
Double-click "ASA Server Manager" on the Windows desktop.

The manager provides:
- Start, safe stop, restart, update + restart, and safe backup
- Server name, current official ASA maps, player limit, and guided rates
- Cross-platform CurseForge mod management for PC/PS5/Xbox
- Private-server options and permanent admin Account IDs
- PS5 admin commands and balanced Aberration FPS commands
- A password-safe offline advisor for files, crossplay, resources, rates, mods,
  networking, and backups (it never changes Windows Firewall or the router)
- An Open guide button for the complete offline handbook

QUICK CHEAT SHEET
Start server: Start server
Stop safely: Safe stop
Restart: Restart
Update: Update + restart
Change map: Safe backup, choose Map, Save basic settings, then Restart
Change rates: Guided rates
Add/remove mods: Manage mods (use cross-platform CurseForge Project IDs)
Check server health: Run offline server advisor
Give permanent admin: PS5 admin + performance help, Manage permanent admins
Reset wild dinos: PS5 admin + performance help, Copy wild dino reset
Back up save: Safe backup

RELIABILITY AND RECOVERY
- Settings are written atomically, so a failed write keeps the old file intact.
- The previous version of each edited file is retained beside it as a .bak file.
- Every manager save also creates a dated snapshot under backups\ConfigHistory.
- A disposable automated GUI test suite is available in Test-ASA-Manager.ps1.
- The latest successful test report is test-results\LATEST-PASS.txt.
- The map selector includes current released ASA level names through Genesis_WP.
- Do not run the full Steam ASA client on this host while the server is running;
  16 GB RAM is not enough for both reliably. Join from PS5 instead.

AUTOMATIC DAILY SAFETY
- Windows runs DailyMaintenance.ps1 every day at 04:00.
- Connected players receive restart warnings at 60, 30, and 10 seconds before
  manual restarts, updates, backup restarts, and daily maintenance.
- It safely stops ASA, creates and verifies a full backup, updates official ASA server App 2430930,
  and keeps the newest 14 daily backups.
- It then restarts once, automatically updates/validates CurseForge mods, and uses
  -ForceRespawnDinos to refresh untamed wild creatures only.
- Results are recorded in DailyMaintenance-last-result.txt and DailyMaintenance.log.
- If ASA was already stopped, it creates the backup but does not unexpectedly start the server.

ADDING MODS
- Send CurseForge ASA links directly to Codex, or paste them into MOD-REVIEW-QUEUE.txt.
- Codex will verify PS5 cross-platform support, dependencies, conflicts, and load order.
- Mods will be installed in small tested batches with a world backup before each batch.
- The manager writes the reviewed Project IDs to -mods= and ASA downloads/updates
  them automatically during server startup.

IMPORTANT
- The current map is Aberration_WP. Changing maps does not delete the old map save.
- Use Safe backup before changing maps or making a large mod change.
- Only install ASA mods explicitly marked cross-platform if PS5 players must join.
- The server admin password stays in GameUserSettings.ini and is not repeated here.

MANUAL FALLBACKS
Start: StartServer.bat
Safe stop: StopServer.bat
Restart: RestartServer.bat
Update while stopped: UpdateServer.bat
Backup while stopped: BackupServer.bat

NETWORK (ALREADY CONFIGURED)
Windows Firewall and the router forward UDP 7777, 7778, and 27015 to
the server's static Ethernet address 192.168.1.179. This was restored and
verified on 18 August 2026 so DHCP no longer moves the forwarding target.
Local RCON is enabled for safe automated shutdowns,
but TCP 27020 has no inbound allow rule and is not forwarded by the router.

INSTALL FOLDER
C:\Users\Gustav\Documents\Codex\ASA_Server
