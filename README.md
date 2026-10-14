# macfan

Live fan speed and temperature in your terminal, with arrow-key fan control.
One small binary, no dependencies, no background processes, no system files touched.

```
macfan                                                        13:02:41

 Fan 0   2996 rpm  ███████████░░░░░░░░░░░░░  target  3000  manual
 Fan 1   2996 rpm  ███████████░░░░░░░░░░░░░  target  3000  manual

 CPU 72.9°C   GPU 47.7°C   Hottest 73.3°C (Tp1K)

 ↑↓ ±100   ←→ ±500   d default   q quit (restores default)        target 3000 rpm
```

## Install

From source (needs the Xcode Command Line Tools, `xcode-select --install`):

```sh
git clone https://github.com/shrsijan/macfan.git && cd macfan
make install            # puts macfan in /usr/local/bin; PREFIX=~/.local make install for a user install
```

Or run it in place without installing: `./macfan`.

Uninstall with `make uninstall`, or delete `/usr/local/bin/macfan`.
## Use

```sh
macfan                  # watch speeds and temperatures
sudo macfan             # same, plus ↑/↓ to set fan speed
```

Keys: `↑`/`↓` change the target by 100 rpm, `←`/`→` by 500, `d` hands the fans
back to the system, `q` quits and does the same. Speeds are clamped to the
range the fan's firmware reports, so you cannot stall or over-drive a fan.

One-off commands:

```sh
sudo macfan set 100%           # all fans to max, then exit
sudo macfan set 3000 --fan 1   # one fan, exact rpm
sudo macfan default            # hand control back to macOS
macfan status                  # print once
macfan --interval 2 --step 250 # dashboard with different refresh/step
macfan > fans.log              # piped output is one line per tick
```

Every command prints the current speeds and temperatures

## Stopping

```sh
sudo macfan default
```

Resets every fan's mode and clears the firmware unlock flag, then reads the
keys back and retries until the firmware confirms it has control again.
macfan keeps no state, so after this nothing of it remains in effect. A reboot
resets everything too.

## How it works

Reads and writes go through the public `AppleSMC` IOKit interface, the same
one every Mac fan utility uses. No kernel extensions, no private frameworks.
Temperature sensors are discovered by walking the SMC key table, so no
per-model key list is needed. Only these keys are ever written:

| Key | Purpose |
|-----|---------|
| `F[placeholder_ID]Md` / `F[placeholder_ID]md` | per-fan mode: 0 auto, 1 manual, 3 system (thermalmonitord) |
| `F[placeholder_ID]Tg` | per-fan target rpm |
| `Ftst` | global unlock, M3 and later (set while manual, cleared on default) |
| `FS! ` | Intel force bitmask |

### Platform notes

* **M1/M2**: manual mode is a direct write.
* **M3 and later**: `thermalmonitord` holds the fans in mode 3 and rejects
  manual mode until `Ftst` is set. macfan handles this and waits for the
  firmware to yield, which is why the first adjustment shows "unlocking fan
  control…" for a few seconds. Fans legitimately idle at 0 rpm on these Macs.
* **Intel**: `fpe2` values and the `FS!` bitmask follow the documented
  protocol but have not been run on real hardware.
* Sleep/wake may hand control back to the firmware; press ↑/↓ again to re-assert.

Tested on a MacBook Pro (Mac15,6, M3 Pro) running macOS 27.

## Releasing

`make release` builds a universal (Apple Silicon + Intel) binary and writes
`dist/macfan-<version>-macos.tar.gz` with its SHA-256, ready to attach to a
GitHub release. `Formula/macfan.rb` is a Homebrew formula; fill in the
repository URL to let people `brew install` it.

## License

MIT
