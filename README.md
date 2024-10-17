# tas2781-fix-16IRX8H
A script to fix the audio problems on Legion Pro 7 16IRX8H on Linux.
This is a combination of solutions from [this thread](https://forums.lenovo.com/t5/Ubuntu/Ubuntu-and-legion-pro-7-16IRX8H-audio-issues/m-p/5210709), with an automatic installer to eliminate manual steps.

## Features

- Apply a fix to the TAS2781 chip when pipewire is activated
- Apply the fix when awaking from suspend

Tested on Arch Linux, kernel 6.11, KDE Plasma 6.

## Installation

### Dependencies
[socat](https://linux.die.net/man/1/socat), [jq](https://jqlang.github.io/jq/) and [i2c-tools](https://archive.kernel.org/oldwiki/i2c.wiki.kernel.org/index.php/I2C_Tools.html) must be installed before applying the fix. All are supported by mainstream package managers.

---
### Install

To install, simply run the following command:

```bash
curl -s https://raw.githubusercontent.com/DanielWeiner/tas2781-fix-16IRX8H/refs/heads/main/install.sh | bash -s --
```

Then make sure to **reboot your system.**

---

### Uninstall

To uninstall, run:

```bash
/usr/local/bin/tas2781-fix --uninstall
```

---

### Re-trigger the fix

To restart the service and re-trigger the fix, run:

```bash
systemctl --user restart tas2781-fix.service
```
