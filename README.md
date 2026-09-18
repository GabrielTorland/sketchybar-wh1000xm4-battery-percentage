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
that keeps the reading up to date. Use `PREFIX=/usr/local` to install elsewhere,
and `make uninstall` to remove everything.

The agent nudges sketchybar by running `sketchybar --trigger
headphone_battery_change`. `make install` fills in the path it found; override it
with `SKETCHYBAR=/path/to/sketchybar` if yours lives somewhere unusual.

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

### Why it watches rather than polls

The reading changes when you switch what you are listening through, and macOS
says so the moment it happens. So the agent runs continuously, listens for
that, and raises a sketchybar event when the answer actually changed. Polling
cannot do the same job: an interval short enough to feel immediate would mean
pestering the headphones constantly, and one long enough to be polite leaves
the bar wrong for minutes at a time.

Putting the headphones down is reflected within a second, because that needs no
Bluetooth at all -- only which device macOS is playing through. Picking them up
again takes a few seconds longer, for the reason in the next paragraph.

Timing matters more than it looks. A headset that has just become the output
device will not accept a control connection while the audio route is still
settling, and asking too early does not merely fail: it wedges the control
channel, so every later attempt fails too until the Bluetooth link is rebuilt.
The agent therefore waits a few seconds before its first question, and never
asks two at once, since the headset serves one control connection at a time.

## sketchybar setup

Both versions read the cache file, show the item only when the headphones are the
output device, and colour the label as the battery drops. Both listen for the
`headphone_battery_change` event the agent raises, so the bar follows the
headphones rather than a timer; the update interval is only a backstop.

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
| `-w`, `--watch` | Stay running and re-read when the output device changes |
| `-n`, `--notify <cmd>` | In watch mode, run `<cmd>` when the reading changes |
| `-i`, `--interval <sec>` | In watch mode, the backstop re-read (default 300) |

Watch mode is how the installed agent runs:

```sh
headphone-battery --watch --json -o ~/.cache/headphone-battery.json \
                  --notify 'sketchybar --trigger headphone_battery_change'
```

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
launchctl print gui/$(id -u)/io.github.gabrieltorland.headphone-battery | grep state
cat ~/.cache/headphone-battery.json
```

The agent stays running, so `state = running` is what you want to see. If it is
not there at all, `make install` again. To watch it work, stop it and run the
same command by hand:

```sh
launchctl bootout gui/$(id -u)/io.github.gabrieltorland.headphone-battery
headphone-battery --watch --json -o ~/.cache/headphone-battery.json --verbose
```

Then change output device and watch what it decides. `make install` puts it
back.

An empty file means "nothing to report" and is what makes the widget collapse.
The file is only emptied when the headphones genuinely are not the output
device; a failed read leaves the previous reading in place instead, so a brief
radio problem does not make the widget disappear. A reading that cannot be
refreshed for 30 minutes is dropped rather than left to go stale.

**The item never comes back once hidden.** sketchybar stops updating an item
whose `drawing` is `off`, so an item that hides itself that way is hidden for
good. Both versions here collapse to `width=0` instead, which is invisible but
still runs. They also zero the side paddings, because an item of zero width
still pads itself and will push a surrounding bracket into its neighbour.

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
