# Remote desktop and startup

Two remote GUIs are installed. They are not the same service.

| Path | What you get | How you connect |
|------|----------------|-----------------|
| Chrome Remote Desktop | GNOME on Xorg, AMD wallpaper and dock | https://remotedesktop.google.com |
| GNOME Remote Desktop | GDM login on the console session | RDP client to port **3389** |

xrdp is not installed. `~/.xsession` still starts XFCE and must not be used by Chrome Remote Desktop.

## What starts at boot

The machine boots to `graphical.target`.

1. **GDM** owns `seat0` on tty1. That greeter is GNOME on Wayland. Nobody is logged in there until someone sits at the console.
2. **`chrome-remote-desktop@eric.service`** is a system unit (`User=eric`). It is enabled and starts without a local login. It is not a user unit.

```bash
systemctl status chrome-remote-desktop@eric.service
journalctl -u chrome-remote-desktop@eric.service -b
```

The unit sets `XDG_SESSION_TYPE=x11` and runs:

```text
/opt/google/chrome-remote-desktop/chrome-remote-desktop --start --new-session
```

`--new-session` re-execs the login shell (`zsh`, so `~/.zprofile` is read), then the host starts its own virtual X server on display `:20` (`DUMMY0`). It does not attach to the GDM seat.

## Chrome Remote Desktop session

The host runs `~/.chrome-remote-desktop-session` when that file exists. The copy in this repo is `config/chrome-remote-desktop-session`. `bin/install-chrome-remote-desktop.sh` installs it to `~/.chrome-remote-desktop-session`.

```sh
unset XDG_MENU_PREFIX
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=GNOME
export XDG_SESSION_DESKTOP=gnome
export DESKTOP_SESSION=gnome-xorg
exec /etc/X11/Xsession /usr/bin/gnome-session
```

That is GNOME Shell on Xorg: Adwaita, dark color scheme, red accent, the Ryzen AI Halo wallpaper, and dash-to-dock on the left. Same desktop as a console login. The console login itself is Wayland; this remote session is Xorg because that is the display the host creates.

Restart the service after changing the session file. The open client disconnects and can reconnect.

```bash
sudo systemctl restart chrome-remote-desktop@eric.service
```

### Do not enable Wayland mode

`CHROME_REMOTE_DESKTOP_USE_WAYLAND` makes the host launch `gnome-session` with `XDG_SESSION_TYPE=wayland` and no X server. GNOME Shell still comes up as an X11 compositor, because logind recorded the CRD login as type `x11` (the systemd unit environment). Shell then exits with `Unable to open display, DISPLAY not set`. The service restarts, hits the same failure, and loops.

`~/.zprofile` must not export `CHROME_REMOTE_DESKTOP_USE_WAYLAND`. The login shell is the only place that variable would reach the service. A comment in `~/.zprofile` records why it stays unset.

### Do not use `~/.xsession`

If `~/.chrome-remote-desktop-session` is missing, the host runs its session chooser, which follows `/etc/X11/Xsession`. That script executes `~/.xsession` when the file exists. `~/.xsession` is the old xrdp desktop:

```sh
export XDG_CURRENT_DESKTOP=XFCE
exec startxfce4
```

That session is the XFCE factory theme (GTK theme `Xfce`, icons `Tango`) and the XFCE mouse wallpaper (`/usr/share/backgrounds/xfce/xfce-x.svg`). `~/.xsessionrc` only sets `GDK_BACKEND=x11` for that path.

XFCE also wrote those theme values into the user dconf database, so a later GNOME login looked the same. Restored on 2026-10-08:

```bash
gsettings reset org.gnome.desktop.interface gtk-theme
gsettings reset org.gnome.desktop.interface icon-theme
gsettings reset org.gnome.desktop.interface font-name
gsettings reset org.gnome.desktop.interface cursor-theme
gsettings reset org.gnome.desktop.interface cursor-size
gsettings reset org.gnome.desktop.wm.preferences button-layout
gsettings reset org.gnome.desktop.wm.preferences action-middle-click-titlebar
```

After the reset, theme and icons are Adwaita, buttons are `:minimize,maximize,close`, and the wallpaper is the Halo image from the AMD gschema override.

### Limits versus a console login

- The login keyring stays locked. CRD never receives the Linux password, so GNOME shows "Authentication required". Cancel dismisses it.
- The host sets `LD_LIBRARY_PATH` to the Mesa software drivers for this session. Programs started from the remote desktop use software OpenGL. Processes started outside the session (LM Studio, the Cloudflare tunnel) do not.
- Only one GNOME Shell can run for this user. A console login while this remote session is connected makes one of them fail ("Oh no!"). Stop CRD before logging in on the seat.

```bash
sudo systemctl stop chrome-remote-desktop@eric.service
```

GDM can also refuse a local login while CRD is running. The host logs that warning at start.

## Install and pair

```bash
~/dev/amd-halo/bin/install-chrome-remote-desktop.sh
```

The script installs the package, repairs a broken `EPILOG` string in the upstream Python file if that bug is present, installs the GNOME session file, and adds `/opt/google/chrome-remote-desktop` to `PATH` in `~/.bashrc` and `~/.zshrc`.

Pairing needs a browser on another machine. The host is already paired on this box; repeat this only for a new Google account or a new PIN.

1. Open https://remotedesktop.google.com/headless and choose **Add machine**.
2. Run the command it prints, and set a PIN of at least 6 digits.

Or:

```bash
DISPLAY= /opt/google/chrome-remote-desktop/start-host \
  --code="<OAuth_code_from_Google>" \
  --redirect-url="https://remotedesktop.google.com/_/oauthredirect" \
  --name=$(hostname)
```

Connect from the Chrome Remote Desktop app or https://remotedesktop.google.com with the same Google account. CRD does not listen on port 3389.

## GNOME Remote Desktop (port 3389)

This is the other GUI. It is system RDP in front of GDM, not Chrome Remote Desktop.

```bash
~/dev/amd-halo/bin/install-gnome-rdp.sh
```

The client asks twice: the RDP gate (same Linux user and password; an empty gate is Windows error **0x4**), then the GDM login. Accept the self-signed certificate. User-level `org.gnome.desktop.remote-desktop.rdp enable` stays false. The listener is `gnome-remote-desktop.service`.

```bash
systemctl status gnome-remote-desktop.service
ss -ltn | grep 3389
```

A second full GNOME Shell for the same user goes black if a local or CRD GNOME session is already up. Disconnect, then reconnect.

## Troubleshooting

Session file in use:

```bash
journalctl -u chrome-remote-desktop@eric.service -b --no-pager \
  | grep 'Launching X session'
```

Expect `~/.chrome-remote-desktop-session`. `Launching wayland server` means `CHROME_REMOTE_DESKTOP_USE_WAYLAND` is set; remove it and restart the system unit.

Desktop check from another login:

```bash
tr '\0' '\n' < /proc/$(pgrep -u eric -x gnome-shell | head -1)/environ \
  | grep -E '^(XDG_CURRENT_DESKTOP|XDG_SESSION_TYPE|DISPLAY)='
```

Expect `XDG_CURRENT_DESKTOP=GNOME`, `XDG_SESSION_TYPE=x11`, and `DISPLAY=:20` (the display number can move).
