# sketchybar-headphone-battery

Show the battery level of your Sony headphones in [sketchybar](https://github.com/FelixKratz/SketchyBar).

```
􀑈 68%
```

The widget appears only while the headphones are connected *and* selected as the
audio output device, and collapses to nothing the rest of the time.

## Why this exists

macOS knows the battery level of a Bluetooth mouse, keyboard or trackpad, but not
of Bluetooth *audio* devices. The battery of a pair of headphones appears nowhere:
not in `system_profiler SPBluetoothDataType`, not in `ioreg`, not in
`com.apple.Bluetooth.plist`. Only iOS shows it, via a proprietary Apple extension
that macOS does not implement.

Sony headphones do report it — over Sony's own protocol, the one the
*Sony | Headphones Connect* app speaks. This tool speaks just enough of that
protocol to ask one question, and prints the answer.

## Requirements

- macOS 14 or later (developed and tested on macOS 26.5.2, Apple Silicon)
- Xcode Command Line Tools (`xcode-select --install`)
- [sketchybar](https://github.com/FelixKratz/SketchyBar), for the widget
- Supported Sony headphones, paired and connected

No permission prompts, and nothing needs to run as root: the tool uses public
`IOBluetooth` API and never touches the pairing database. It does install a
launchd agent, for reasons explained [below](#why-a-launchd-agent).

## Supported devices

| Device | Status |
| --- | --- |
| WH-1000XM4 | **Verified** on hardware |
| WH-1000XM3, WH-1000XM2, WH-H900N, WF-1000XM3, WF-SP800N | Same protocol generation — expected to work, untested |
| WH-1000XM5, WH-1000XM6, WF-1000XM5, LinkBuds S | Supported in code, **not yet tested on hardware** |
| Earbuds — per-bud and case levels | Not read; only the combined level |
| Non-Sony headphones | Not supported |

Sony's protocol comes in two generations, which share their framing and
handshake and differ only in the opcode used to ask for the battery. The tool
detects which one it is talking to from the handshake reply and asks
accordingly, so both are handled automatically.

The second-generation path is built from two independent reverse-engineering
projects that agree byte for byte, but I own no second-generation device to test
it against. If you have an XM5 or XM6, `headphone-battery -d <name> --verbose`
will print the exchange — a successful trace or a silent one are both worth an
issue.

Earbuds report a level per bud and one for the case, under inquired types this
tool does not request. The field order for those replies is contradictory
between sources, so rather than display something plausible but wrong, it asks
only for the combined level.

## Install

```sh
git clone https://github.com/GabrielTorland/sketchybar-wh1000xm4-battery-percentage.git
cd sketchybar-wh1000xm4-battery-percentage
make install
```

That builds `headphone-battery` into `~/.local/bin`, installs a launchd agent
that refreshes the reading every five minutes, and starts it. Override the
location with `make install PREFIX=/usr/local`.

Check that it worked:

```sh
cat ~/.cache/headphone-battery.json
{"device":"WH-1000XM4","percent":68,"charging":false}
```

`make uninstall` removes all three.

### Why a launchd agent

Because sketchybar cannot do this itself. Bluetooth is unavailable to the
processes sketchybar spawns: `IOBluetooth` either blocks forever inside
`IOBluetoothCoreBluetoothCoordinator` or opens a channel that never answers,
depending on what it is asked for. The same binary run from a terminal, or from
a launchd agent, works immediately — this is about which process is asking, not
what it is asking for.

So the agent owns the Bluetooth work and writes the reading to
`~/.cache/headphone-battery.json`, and the widget only ever reads that file.
Two things fall out of that, both good: the bar never blocks on Bluetooth, and
the widget costs a file read.

The file is written atomically, and is emptied whenever the headphones are not
what you are listening through — which is exactly when the widget should show
nothing.

## Usage

```
headphone-battery [options]
```

With no options it reports the headphones currently selected as the audio output
device, and exits quietly if they are not — which is what makes it convenient to
poll from a status bar.

| Option | Meaning |
| --- | --- |
| `-d`, `--device <name>` | Match a paired device by name substring instead of using the output device |
| `-a`, `--any` | Use the first connected device that answers, output device or not |
| `-j`, `--json` | Print `{"device":..,"percent":..,"charging":..}` |
| `-l`, `--list` | List connected devices and the control channel found for each |
| `-t`, `--timeout <secs>` | Give up after this long (default 5) |
| `-o`, `--output <path>` | Write the reading to a file, atomically, emptying it when there is nothing to report |
| `-v`, `--verbose` | Trace the protocol exchange on stderr |
| `-h`, `--help` | Show usage |

Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 1 | No matching device connected |
| 2 | Device has no control channel (unsupported model) |
| 3 | Control channel would not open |
| 4 | No reply before the timeout |
| 64 | Usage error |

A reading normally takes under a second.

## sketchybar integration

Both versions read the cache file the agent writes, show the item only when the
headphones are the output device, and colour the label as the battery drops.
Switching output device kicks the agent so the bar updates within a few seconds
rather than waiting out its interval.

> One detail worth knowing if you adapt this: sketchybar stops running the update
> script of an item whose `drawing` is `off`. An item that hid itself that way
> would never notice the headphones coming back. Both versions below collapse the
> item to `width=0` instead, which is invisible but keeps polling.

### Lua config ([SbarLua](https://github.com/FelixKratz/SbarLua))

```sh
cp sketchybar/headphone_battery.lua ~/.config/sketchybar/items/
```

```lua
require("items.headphone_battery")
```

The configuration block at the top of the file sets the binary path, poll
interval, colours and thresholds. The module returns the item, so it can also be
added to an existing bracket:

```lua
local headphones = require("items.headphone_battery")
sbar.add("bracket", "widgets.volume", { headphones.name, volume.name })
```

### Shell config

```sh
cp sketchybar/headphone_battery.sh ~/.config/sketchybar/plugins/
chmod +x ~/.config/sketchybar/plugins/headphone_battery.sh
```

Then add the item from `sketchybar/sketchybarrc.example` to your `sketchybarrc`.
Thresholds and colours are read from the environment — see the top of the script.

### The icon

The examples use `􀑈`, the SF Symbols `headphones` glyph (U+100448), which renders
with the system font and needs nothing installed. If you use a Nerd Font, `󰋋`
(`nf-md-headphones`, U+F02CB) is the equivalent.

## How it works

The headphones advertise an RFCOMM service carrying framed messages:

```
3E <type> <seq> <length:4 BE> <payload> <checksum> 3C
```

The checksum is the sum of the bytes between the markers, and `3E`/`3C`/`3D` are
escaped inside the body. The battery query is a two-byte payload — `10 00` on the
first protocol generation, `22 00` on the second — and the answer comes back as
`<ret opcode> 00 <percent> <charging>`.

The service is located by UUID rather than by name:
`96CC203E-5068-46AD-B32D-E316F5E069BA` for the first generation and
`956C7B26-D49A-4BA8-B03F-B17D393CB6E2` for the second. The RFCOMM channel number
varies by model and firmware, so it is always read from the SDP record rather
than assumed. Which generation is actually speaking is then settled by the
handshake reply, which is four bytes long for the first and eight for the second.

Three details are not obvious from the framing, and each one will leave you
staring at a silent socket:

1. The headphones ignore everything until you send the handshake payload `00 00`.
2. Every frame they send must be acknowledged, or they retransmit it forever and
   never move on. That includes notifications you never asked for.
3. A request the device does not support is acknowledged and then never answered.
   There is no error reply, so every request needs a timeout.

They also interleave unsolicited notifications — playback state, noise-cancelling
changes — with the reply you asked for, so the reply cannot be assumed to arrive
first. This tool watches for the battery opcode wherever it turns up.

The tool connects, asks, prints, and disconnects. It does not hold the channel
open.

### A note on polling

The control channel takes a single client at a time. While this tool is talking
to the headphones, another MDR client on the same Mac cannot be, and vice versa —
so if you run the binary by hand while the widget happens to be refreshing, one
of the two will fail. It will succeed on the next poll.

The default five-minute interval is a conservative choice rather than a documented
requirement; no rate limit is published anywhere. A battery gauge that moves in
whole percent has little reason to be read more often than that, and reading it
less often costs nothing.

## Troubleshooting

**Nothing is printed and the exit code is 1.** The headphones are not the current
output device. That is the intended behaviour; use `-d <name>` or `-a` to read them
anyway.

**The binary works but the widget stays empty.** Check the agent and the file it
writes:

```sh
launchctl print gui/$(id -u)/io.github.gabrieltorland.headphone-battery | grep -E 'state|last exit'
cat ~/.cache/headphone-battery.json
```

A `last exit code = 1` means the headphones were not the output device when it
last ran. Force a fresh reading with:

```sh
launchctl kickstart -k gui/$(id -u)/io.github.gabrieltorland.headphone-battery
```

If the widget never updates but the file is correct, the item is not polling —
see the note about `drawing=off` above.

**Exit code 2.** No control channel was found. Check what is visible:

```sh
headphone-battery --list
WH-1000XM4                   control channel 9
```

If your device is listed without a channel, it does not advertise either of the
Sony control services.

**Exit code 4, or intermittent failures.** Watch the exchange:

```sh
headphone-battery -d WH-1000XM4 --verbose
TX 11: 3E 0C 00 00 00 00 02 00 00 0E 3C
RX 13: 3E 0C 01 00 00 00 04 01 00 70 00 82 3C
-- protocol generation 1 (handshake reply 4 bytes)
TX 11: 3E 0C 01 00 00 00 02 10 00 1F 3C
RX 13: 3E 0C 00 00 00 00 04 11 00 0A 00 2B 3C
```

A trace that stops after the handshake means the device did not recognise the
battery request. An occasional failure is normal if something else is using the
control channel at that moment — see the note on polling above.

**The widget does not appear.** Run the binary by hand first. If that works,
check that the cache path at the top of the Lua file, or `HEADPHONE_BATTERY_CACHE`
for the shell version, matches the one the agent writes.

**Do not call the binary directly from a sketchybar script.** It will not work —
see [Why a launchd agent](#why-a-launchd-agent).

## Acknowledgements

The protocol is documented by the open-source projects that reverse-engineered
it, above all
[Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge), whose Sony
implementation is the reference for the framing, the service UUIDs and the
version detection, and
[mos9527/SonyHeadphonesClient](https://github.com/mos9527/SonyHeadphonesClient)
for the command tables. This project is not affiliated with or endorsed by Sony.

## License

MIT — see [LICENSE](LICENSE).
