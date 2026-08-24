# ASA Control Deck

Authenticated local/LAN companion for the existing Windows ASA Manager.

## Current phase

- Read-only dashboard.
- Reads only four allow-listed values from `server-config.cmd`.
- Shows the ASA process, map, capacity, mod count, host CPU/RAM/disk, and latest full-save backup.
- Registers no start, stop, restart, backup, update, mod, or configuration write endpoint.
- Uses password authentication with failed-login throttling.
- Does not change Windows Firewall or the router.
- Can bind either to `127.0.0.1` or the Windows PC's private default-route address.

The original `ASA-Manager.ps1` remains the operational source of truth. This dashboard must not introduce a second configuration source.

## Development preview

For a one-click local production preview, double-click `Start-WebManager-Local.bat`. For Mac/iPhone access on the same home network, double-click `Start-WebManager-LAN.bat`. The first start asks you to create a password (username: `gustav`). Use `Stop-WebManager-Local.bat` to stop only the tracked dashboard processes.

The LAN address is printed when the manager starts. A narrowly scoped Windows Firewall rule may still be required; it must not be created without Gustav's explicit approval. No router port-forward is needed or wanted.

## Security boundary

This private-LAN version uses browser Basic authentication over HTTP. The password is stored only as a slow PBKDF2 verifier, but HTTP itself is not encrypted; use it only on Gustav's trusted home LAN and never expose port 8415 through the router. Write actions remain unavailable. Future write actions must call the original vetted scripts and retain Preview -> Confirm -> Backup -> Apply.
