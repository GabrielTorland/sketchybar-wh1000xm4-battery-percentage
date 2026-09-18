# sketchybar-headphone-battery

Show the battery level of your Sony headphones in [sketchybar](https://github.com/FelixKratz/SketchyBar)
as a headphones icon and a percentage.

The widget appears only while the headphones are connected *and* selected as the
audio output device, and collapses to nothing the rest of the time.

## Why

macOS shows the battery of a Bluetooth mouse or keyboard, but never of Bluetooth
*audio*. It is not in `system_profiler`, `ioreg`, or any preferences plist.

Sony headphones do report it, over the proprietary protocol their Headphones
Connect app speaks. This tool speaks just enough of that protocol to ask one
question.

## Supported devices

| Device | Status |
| --- | --- |
| WH-1000XM4 | Verified on hardware |
| WH-1000XM3/XM2, WH-H900N, WF-1000XM3, WF-SP800N | Same protocol generation, untested |
| WH-1000XM5/XM6, WF-1000XM5, LinkBuds S | Implemented, untested |
| Non-Sony headphones | Not supported |

The protocol has two generations that differ only in the opcode used to ask for
the battery. The tool detects which one it is talking to and asks accordingly.
The second generation is built from two reverse-engineering projects that agree
byte for byte, but I have no such device to test against — if you do,
`headphone-battery -d <name> --verbose` prints the exchange, and either outcome
is worth an issue.

Earbuds report a level per bud and one for the case. Sources contradict each
other on the layout of those replies, so the tool asks only for the combined
level.

## Requirements

macOS 14+ (tested on 26.5.2, Apple Silicon), Xcode Command Line Tools, sketchybar,
and a supported pair of headphones. No permission prompts and nothing runs as
root.

## Install

```sh
git clone https://github.com/GabrielTorland/sketchybar-wh1000xm4-battery-percentage.git
cd sketchybar-wh1000xm4-battery-percentage
make install
```

This builds `headphone-battery` into `~/.local/bin` and installs a launchd agent
that refreshes the reading every five minutes. Use `PREFIX=/usr/local` to install
elsewhere, and `make uninstall` to remove everything.

Check that it worked:

```sh
$ cat ~/.cache/headphone-battery.json
{"device":"WH-1000XM4","percent":68,"charging":false}
```

### Why an agent instead of a sketchybar script

Because sketchybar cannot do this itself. Bluetooth is unavailable to the
processes it spawns: `IOBluetooth` either blocks forever inside
`IOBluetoothCoreBluetoothCoordinator` or opens a channel that never answers. The
same binary works immediately from a terminal or a launchd agent, so this is
about *which process is asking*.

The agent therefore does the Bluetooth work and writes the reading to
`~/.cache/headphone-battery.json`; the widget only reads that file. The bar never
blocks on Bluetooth, and the widget costs a file read. The file is written
atomically and emptied whenever the headphones are not what you are listening
through.

## sketchybar setup

Both versions read the cache file, show the item only when the headphones are the
output device, and colour the label as the battery drops. Changing output device
refreshes the bar within a few seconds instead of waiting out the interval.

### Lua ([SbarLua](https://github.com/FelixKratz/SbarLua))

```sh
cp sketchybar/headphone_battery.lua ~/.config/sketchybar/items/
```

```lua
require("items.headphone_battery")
```

Paths, interval, colours and thresholds are in a config block at the top of the
file. The module returns the item, so it can join an existing bracket:

```lua
local headphones = require("items.headphone_battery")
sbar.add("bracket", "widgets.volume", { headphones.name, volume.name })
```

### Shell

```sh
cp sketchybar/headphone_battery.sh ~/.config/sketchybar/plugins/
chmod +x ~/.config/sketchybar/plugins/headphone_battery.sh
```

Then add the item from `sketchybar/sketchybarrc.example` to your `sketchybarrc`.
Thresholds and colours come from environment variables listed at the top of the
script.

### Icon

The examples use the SF Symbols `headphones` glyph, `U+100448`, which needs
nothing installed. The Nerd Font equivalent is `nf-md-headphones`, `U+F02CB`.

## Usage

With no options, `headphone-battery` reports the headphones currently selected as
the output device and exits quietly if they are not. A reading takes under a
second.

| Option | Meaning |
| --- | --- |
| `-d`, `--device <name>` | Match a paired device by name substring |
| `-a`, `--any` | Use the first connected device that answers |
| `-j`, `--json` | Print `{"device":..,"percent":..,"charging":..}` |
| `-l`, `--list` | List connected devices and their control channel |
| `-t`, `--timeout <secs>` | Give up after this long (default 5) |
| `-o`, `--output <path>` | Write the reading to a file atomically |
| `-v`, `--verbose` | Trace the protocol exchange on stderr |

Exit codes: `0` success, `1` no matching device, `2` no control channel,
`3` channel would not open, `4` no reply, `64` usage error.

## How it works

The headphones advertise an RFCOMM service carrying framed messages:

```
3E <type> <seq> <length:4 BE> <payload> <checksum> 3C
```

The checksum is the sum of the bytes between the markers, and `3E`/`3C`/`3D` are
escaped inside the body. The battery query is a two-byte payload — `10 00` on the
first generation, `22 00` on the second — answered with
`<opcode> 00 <percent> <charging>`.

The service is found by UUID (`96CC203E-...` for the first generation,
`956C7B26-...` for the second) rather than by name, and the channel number is
read from the SDP record because it varies by model. The generation is then
settled by the handshake reply: four bytes of payload for the first, eight for
the second.

Three things are not obvious from the framing, and each leaves you staring at a
silent socket:

1. The headphones ignore everything until the handshake payload `00 00` arrives.
2. Every frame they send must be acknowledged, including notifications you never
   asked for, or they retransmit forever.
3. An unsupported request is acknowledged and then never answered, so every
   request needs a timeout.

They also interleave notifications with replies, so the tool watches for the
battery opcode wherever it appears rather than assuming order.

The control channel takes one client at a time, so running the binary by hand
while the agent happens to be reading will fail; it succeeds on the next poll.
The five-minute interval is a conservative choice, not a documented requirement —
no rate limit is published anywhere.

## Troubleshooting

**Nothing printed, exit code 1.** The headphones are not the current output
device. Use `-d <name>` to read them anyway.

**Exit code 2.** No control channel found. Check what is visible:

```sh
$ headphone-battery --list
WH-1000XM4                   control channel 9
```

**Exit code 4, or intermittent failures.** Trace the exchange with
`--verbose`. A trace that stops after the handshake means the device did not
recognise the battery request.

**Exit code 4 with no trace output at all.** If `--verbose` prints

```
opening WH-1000XM4 channel 9
open call returned: 0x00000000
```

and then nothing, the connection was accepted by the system but the headset
never completed it. The control channel on the headset has wedged: it will go
on serving audio while silently ignoring every new control connection.

This happens when a previous client exited without closing the channel. The
headset only lets go once the Bluetooth link itself is torn down, so
reconnecting is what clears it:

* turn the headphones off and on again, or
* disconnect and reconnect them in **System Settings > Bluetooth**.

macOS may move audio output to another device while they are disconnected, so
check the output device afterwards. `--list` keeps working throughout, because
it reads the service record rather than opening a connection — so `--list`
succeeding while a read fails is itself a sign of this state.

**The widget stays empty.** Check the agent and the file it writes:

```sh
launchctl print gui/$(id -u)/io.github.gabrieltorland.headphone-battery | grep 'last exit'
cat ~/.cache/headphone-battery.json
```

`last exit code = 1` means the headphones were not the output device when it last
ran. Force a fresh reading with `launchctl kickstart -k
gui/$(id -u)/io.github.gabrieltorland.headphone-battery`.

An empty file means "nothing to report" and is what makes the widget collapse.
The file is only emptied when the headphones genuinely are not the output
device; a failed read leaves the previous reading in place instead, so a brief
radio problem does not make the widget disappear. A reading that cannot be
refreshed for 30 minutes is dropped rather than left to go stale.

Note that sketchybar stops updating an item whose `drawing` is `off`, so an item
that hides itself that way never comes back. Both versions here collapse to
`width=0` instead, which is invisible but keeps polling.

**Do not call the binary from a sketchybar script.** It will not work — see
[above](#why-an-agent-instead-of-a-sketchybar-script).

## Acknowledgements

The protocol is documented by the projects that reverse-engineered it, above all
[Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge), the reference
for the framing, service UUIDs and version detection, and
[mos9527/SonyHeadphonesClient](https://github.com/mos9527/SonyHeadphonesClient)
for the command tables. Not affiliated with or endorsed by Sony.

## License

MIT — see [LICENSE](LICENSE).
