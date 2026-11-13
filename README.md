# Goodix 27c6:55b4 setup

Automates setup of the Goodix 27c6:55b4 fingerprint reader on x86_64 Fedora and Ubuntu KDE systems.

## Install and run

Clone this repository, then run:

```bash
cd goodix-55b4-linux-setup
chmod +x setup-goodix55b4.sh
./setup-goodix55b4.sh
```

The script requests administrator access and installs the matching community `libfprint-goodix55b4` package. It checks the downloaded package SHA-256 against the release manifest, probes sensor firmware and PSK, enrolls the right index finger, and runs a verification scan. It can optionally configure a reversible PAM login override for Plasma Login Manager or SDDM.

The script asks before replacing distro `libfprint`, modifying sensor firmware/PSK, or editing PAM. A matching package must exist in the community project's latest release for your Fedora or Ubuntu version.

## Important sensor warning

If provisioning is needed, the community utility may erase and flash firmware 10041 and replace the Windows Hello pairing key. The old firmware and key are not backed up. The utility's authors warn that flashing can damage the reader. Windows fingerprint login may stop working, and Windows drivers can re-provision the sensor. Do not proceed with the explicit `FLASH-AND-REPROVISION` prompt unless you accept these risks.

## Login behavior

The optional PAM change adds `pam_fprintd` before the existing password stack, so password login remains available. At the greeter, select your user, leave the password field empty, and press Enter to start a scan. GNOME/GDM and fingerprint authentication for sudo are not configured by this script.

## Reverting changes

- Restore a prior PAM file from `/etc/pam.d/<service>.before-goodix55b4` with `sudo cp -a`.
- If the script created the PAM file, remove the local override with `sudo rm /etc/pam.d/<service>`.
- Fedora: restore the stock library with `sudo dnf swap libfprint-goodix55b4 libfprint`.
- Ubuntu: reinstall the stock library with `sudo apt install libfprint-2-2`.
- Sensor firmware and the Windows pairing key cannot be restored by this script.

See [README-setup-goodix55b4.md](README-setup-goodix55b4.md) for full notes.
