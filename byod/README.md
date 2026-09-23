# saml2aws Playwright driver setup (personal devices)

If you use saml2aws' **Browser** login on your own laptop, it fails on a clean
machine before it ever opens a browser:

```
could not install driver: got non 200 status code: 404 (404 Not Found)
from https://playwright.azureedge.net/builds/driver/playwright-1.47.2-win32_x64.zip
```

saml2aws downloads a [Playwright](https://playwright.dev/) driver from a Microsoft
CDN that has been retired, so every attempt returns 404. The scripts here build
that driver from its original sources instead, which gets Browser login working.

Nothing needs Node, npm, or administrator rights.

> **Company-managed device?** This is already handled for you. If `saml2aws login`
> still fails, contact IT — running these scripts would put a second driver on top
> of the managed one.

---

## Before you start

| You need | Windows | macOS |
|---|---|---|
| saml2aws CLI | `choco install saml2aws` | `brew install saml2aws` |
| Google Chrome | required | required |
| Internet access to | `registry.npmjs.org`, `nodejs.org` | `registry.npmjs.org`, `nodejs.org` |

These scripts stage the *driver* only. They report on saml2aws and Chrome but do
not install either. Chrome is a real requirement: Playwright browsers are not part
of the driver, so `browser_type=chrome` uses the Chrome you already have.

Apple Silicon and Intel Macs are both supported and detected automatically.
Windows is x64 only.

---

## Windows

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-Saml2awsPlaywrightDriver-User.ps1
```

Then **open a new terminal** and run `saml2aws login` as usual.

Options:

```powershell
# leave your environment variables alone - see "If you use Playwright yourself"
.\Install-Saml2awsPlaywrightDriver-User.ps1 -SkipEnvironmentVariable

# re-download if something looks broken
.\Install-Saml2awsPlaywrightDriver-User.ps1 -Force
```

---

## macOS

```bash
chmod +x install-playwright-driver-macos.sh
./install-playwright-driver-macos.sh
```

Then **open a new terminal** and run `saml2aws login` as usual.

Options:

```bash
./install-playwright-driver-macos.sh --skip-env   # do not touch shell profiles
./install-playwright-driver-macos.sh --force      # re-download
./install-playwright-driver-macos.sh --help
```

---

## Check it worked

```bash
saml2aws login -a <your-account> --verbose
```

Chrome should open. To inspect what was staged:

```powershell
# Windows
echo $env:PLAYWRIGHT_DRIVER_PATH
& "$env:PLAYWRIGHT_DRIVER_PATH\ms-playwright-go\1.47.2\node.exe" `
  "$env:PLAYWRIGHT_DRIVER_PATH\ms-playwright-go\1.47.2\package\cli.js" --version
```

```bash
# macOS
echo "$PLAYWRIGHT_DRIVER_PATH"
"$PLAYWRIGHT_DRIVER_PATH/ms-playwright-go/1.47.2/node" \
  "$PLAYWRIGHT_DRIVER_PATH/ms-playwright-go/1.47.2/package/cli.js" --version
```

Both should print `Version 1.47.2`.

---

## What the scripts change

These run on your personal machine, so here is exactly what they touch.

| | Windows | macOS |
|---|---|---|
| Driver files | `%LOCALAPPDATA%\saml2aws\playwright-driver` | `~/Library/Application Support/saml2aws/playwright-driver` |
| Environment | `PLAYWRIGHT_DRIVER_PATH` for your user account | `export` line appended to `~/.zshrc` |
| Administrator rights | none | none |
| Disk used | about 200 MB | about 200 MB |
| Downloaded | about 30 MB | about 40 MB |

Nothing is installed system-wide, no services are created, and no other
application is modified. Re-running is safe — the script validates the existing
driver and exits early if it is already good.

### If you use Playwright yourself

`PLAYWRIGHT_DRIVER_PATH` is read by **any** Go application using Playwright, not
just saml2aws. If you do your own Playwright work and would rather not set it
globally, run with `-SkipEnvironmentVariable` (Windows) or `--skip-env` (macOS).
The script then prints a `browser_driver_dir` line to add to your `~/.saml2aws`
profile, which applies to saml2aws only.

---

## Removing it

```powershell
# Windows
Remove-Item "$env:LOCALAPPDATA\saml2aws\playwright-driver" -Recurse -Force
[Environment]::SetEnvironmentVariable('PLAYWRIGHT_DRIVER_PATH', $null, 'User')
```

```bash
# macOS
rm -rf "$HOME/Library/Application Support/saml2aws/playwright-driver"
# then remove the two lines marked "# saml2aws playwright driver" from ~/.zshrc
```

---

## Troubleshooting

| Symptom | What to do |
|---|---|
| Still getting the 404 | The version may not match. Run `saml2aws login -a <account> --verbose` and read the version in the 404 URL. If it is not `1.47.2`, re-run with `-PlaywrightVersion <ver>` or `--playwright-version <ver>`. |
| `saml2aws: command not found` | The driver is staged but saml2aws itself is not installed. See [Before you start](#before-you-start). |
| Works in one terminal, not another | Environment changes only apply to **new** terminals. Close and reopen. |
| Download fails | A network or proxy is blocking `registry.npmjs.org` or `nodejs.org`. Try another network. |
| Chrome warning | Install Chrome, or change `browser_type` in your `~/.saml2aws` profile. |
| Version check fails after staging | Interrupted download. Re-run with `-Force` or `--force`. |
| macOS says the file is not executable | `chmod +x install-playwright-driver-macos.sh` |

Currently staged: **Playwright 1.47.2**, **Node 20.17.0**. Both can be overridden
with `-PlaywrightVersion` / `-NodeVersion` on Windows and
`--playwright-version` / `--node-version` on macOS.

---

## Verifying your download

If you downloaded a single file rather than cloning, check it matches:

```
Install-Saml2awsPlaywrightDriver-User.ps1
  SHA256  95D4D49EA837F7B11C4409329CAB0675ED91FE116945166803B8923F4C6696A1

install-playwright-driver-macos.sh
  SHA256  731B2C87F6B123A2AFE1F3E226892F0E65550C28D2D2447533EA0EA993892EB0
```

```powershell
Get-FileHash .\Install-Saml2awsPlaywrightDriver-User.ps1 -Algorithm SHA256
```

```bash
shasum -a 256 install-playwright-driver-macos.sh
```
