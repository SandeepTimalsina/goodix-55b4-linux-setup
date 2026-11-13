# Goodix 27c6:55b4 setup

`setup-goodix55b4.sh` automates this reader's Linux setup on x86_64 Fedora and Ubuntu KDE systems. Run it from a terminal:

```bash
chmod +x setup-goodix55b4.sh
./setup-goodix55b4.sh
```

It requests administrator access, downloads the distro-matched `libfprint-goodix55b4` package, checks its SHA-256 against the release manifest, checks the sensor firmware and PSK, then enrolls and verifies the right index finger. It supports display-manager PAM services named `plasmalogin` and `sddm`.

The script asks before replacing the distro's `libfprint`, before changing the sensor, and before editing the login PAM file. If the sensor needs provisioning, the community utility may erase and flash firmware 10041 and replace the Windows Hello pairing key. It has no backup of the old firmware or key, and its authors warn that flashing can damage the reader. If Windows fingerprint login is still used, disable its fingerprint driver before booting Windows after provisioning; it may re-provision the sensor.

The PAM change adds `pam_fprintd` before the current password stack, keeping password login as fallback. At the login greeter, select your user, leave the password field empty, and press Enter to start a fingerprint scan. The script does not configure GNOME/GDM or enable fingerprint authentication for sudo.

## Reverting

- If a prior `/etc/pam.d/<service>` file existed, the script saves it as `/etc/pam.d/<service>.before-goodix55b4`; restore it with `sudo cp -a`.
- If the script created `/etc/pam.d/plasmalogin` or `/etc/pam.d/sddm`, remove that local override with `sudo rm /etc/pam.d/<service>` to resume using the vendor file.
- Restore Fedora's library with `sudo dnf swap libfprint-goodix55b4 libfprint`. On Ubuntu, reinstall the distro library with `sudo apt install libfprint-2-2`.
- The script cannot restore the old sensor firmware or Windows pairing key.

The driver package is built by the community project and is unsigned. The script checks it against the SHA-256 file published alongside that release. A package is available only when the latest release contains an asset for the installed Fedora or Ubuntu version.
