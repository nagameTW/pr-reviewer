# Running on Windows (WSL2)

The reviewer runs inside WSL2, the Linux environment built into Windows. WSL2
is not in CI. The steps below follow Microsoft's WSL documentation and are
checked only on the maintainer's own machine. If something differs, please open
an issue.

The service needs systemd (`systemd=true` in `/etc/wsl.conf`; `prreview setup`
tells you when it is off). It stops when WSL shuts down. Step 4 keeps WSL
running while you are logged in to Windows. Until the service is set up, you can
review one PR at a time with `prreview once --pr owner/repo#N`.

1. **Install WSL2 with Ubuntu.** In PowerShell: `wsl --install -d Ubuntu`.
   Run `wsl --version`; 2.6 or newer is recommended (`wsl --update`). The
   distribution has to run under WSL 2, since WSL 1 has no systemd:
   `wsl -l -v` shows its version, and `wsl --set-version Ubuntu 2` converts
   it.
2. **Turn on systemd in Ubuntu**, so the reviewer can run as a service. New
   Ubuntu installs have it already. Otherwise add this to `/etc/wsl.conf`:

   ```ini
   [boot]
   systemd=true
   ```

   Then run `wsl --shutdown` in PowerShell and open Ubuntu again. Inside
   Ubuntu, also run:

   ```bash
   sudo apt install dbus-user-session
   sudo loginctl enable-linger "$USER"
   ```

3. **Follow the Linux steps inside Ubuntu:** install the tools, clone into
   your Linux home directory (`~`, not `/mnt/c`), and run `./prreview setup`.
   Answer `y` at the background service step, or run `./prreview start`
   after setup. Step 4 keeps that service running, so it needs one.
4. **Keep WSL running.** WSL shuts Ubuntu down about 15 seconds after the last
   Windows program using it closes, and a running service does not count.
   Two changes keep the reviewer alive while you are logged in to Windows:
   - In `%UserProfile%\.wslconfig` on the Windows side (WSL 2.5.7 or newer),
     then `wsl --shutdown`:

     ```ini
     [general]
     instanceIdleTimeout=-1
     ```

   - Start Ubuntu once at every Windows login, so the service starts with it.
     In PowerShell:

     ```powershell
     $a = New-ScheduledTaskAction -Execute 'wsl.exe' -Argument '-d Ubuntu --exec /bin/true'
     $t = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
     Register-ScheduledTask -TaskName 'pr-reviewer' -Action $a -Trigger $t
     ```

     A console window may flash briefly at login.

The reviewer stops when you log out of Windows and pauses while the PC
sleeps. It picks up again at the next login or wake-up.

