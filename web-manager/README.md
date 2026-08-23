# ASA Control Deck

Local-only companion for the existing Windows ASA Manager.

## Current phase

- Read-only dashboard.
- Reads only four allow-listed values from `server-config.cmd`.
- Shows the ASA process, map, capacity, mod count, host CPU/RAM/disk, and latest full-save backup.
- Registers no start, stop, restart, backup, update, mod, or configuration write endpoint.
- Does not change Windows Firewall or the router.
- Listens only on `127.0.0.1` during this phase, so it is not yet reachable from another device.

The original `ASA-Manager.ps1` remains the operational source of truth. This dashboard must not introduce a second configuration source.

## Development preview

Run the read-only status service from the repository root:

```powershell
.\web-manager\local-service\ASA-WebStatusService.ps1
```

Then run the UI from `web-manager`:

```powershell
npm run dev
```

Open `http://localhost:3000`.

For a one-click local production preview, double-click `Start-WebManager-Local.bat` in the repository root. Use `Stop-WebManager-Local.bat` to stop only the tracked dashboard processes.

## Security boundary for the next phase

Do not bind the service to the LAN until authentication, request forgery protection, rate limiting, a single-instance lock, and an explicit Windows Firewall review are implemented and tested. Write actions must call the original vetted scripts and retain Preview -> Confirm -> Backup -> Apply.
