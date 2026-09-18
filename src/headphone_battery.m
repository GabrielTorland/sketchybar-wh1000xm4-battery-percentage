// headphone-battery — read the battery level of Sony headphones on macOS.
//
// macOS does not expose the battery level of a Bluetooth *audio* device through
// any public interface: system_profiler, the IORegistry and the Bluetooth
// preference files only ever know about HID devices such as keyboards and mice.
// Sony headphones do report their battery, but only over Sony's own protocol,
// spoken on an RFCOMM channel the headset advertises as "Serial HPC" (as in
// Headphones Connect, the name of Sony's phone app).
//
// The protocol frames look like this:
//
//     3E <dataType> <seq> <length:4 BE> <payload...> <checksum> 3C
//
// The checksum is the sum of every byte between the markers, modulo 256. Any
// 3E/3C/3D occurring inside that range is escaped as 3D followed by the byte
// with bit 4 cleared, so that the frame markers stay unambiguous.
//
// Two behaviours are not obvious from the frame format alone, and both will
// leave you staring at a silent socket:
//
//   * The headphones ignore every request until the protocol handshake
//     (payload 00 00) has been sent and answered.
//   * Every data frame received must be acknowledged, or the headset keeps
//     retransmitting it and never proceeds to anything else.
//
// Asking for the battery is payload 10 00; the answer is 11 00 <percent>
// <charging>.
//
// SPDX-License-Identifier: MIT

#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import <CoreAudio/CoreAudio.h>
#include <sys/stat.h>
#include <unistd.h>
#include <time.h>

static const uint8_t START_MARKER  = 0x3E;
static const uint8_t END_MARKER    = 0x3C;
static const uint8_t ESCAPE_MARKER = 0x3D;
static const uint8_t ESCAPE_MASK   = 0xEF;

static const uint8_t TYPE_ACK      = 0x01;
static const uint8_t TYPE_DATA_MDR = 0x0C;

static const uint8_t CMD_GET_PROTOCOL = 0x00;
static const uint8_t CMD_RET_PROTOCOL = 0x01;
// Sony's protocol comes in two generations. The first is spoken by the
// WH-1000XM4 and its contemporaries, the second by the XM5 and later. They
// share the framing and the handshake, and differ only in the opcodes.
static const uint8_t CMD_GET_BATTERY  = 0x10;
static const uint8_t CMD_RET_BATTERY  = 0x11;
static const uint8_t CMD_NTFY_BATTERY = 0x13;

static const uint8_t CMD_V2_GET_BATTERY  = 0x22;
static const uint8_t CMD_V2_RET_BATTERY  = 0x23;
static const uint8_t CMD_V2_NTFY_BATTERY = 0x25;

static const uint8_t BATTERY_SINGLE   = 0x00;

// The generation is announced by the length of the handshake reply: four bytes
// of payload for the first, eight for the second.
static const NSUInteger PROTOCOL_V2_REPLY_LENGTH = 8;

// Sony publishes its control service under one of two UUIDs, one per protocol
// generation. Matching the UUID rather than the service name is what the
// established reverse-engineering projects do, and it is the only part of the
// record that is documented to be stable across models. The RFCOMM channel
// number varies by model and firmware, so it is always read from the record.
static NSString *const SERVICE_UUID_V1 = @"96CC203E506846ADB32DE316F5E069BA";
static NSString *const SERVICE_UUID_V2 = @"956C7B26D49A4BA8B03FB17D393CB6E2";

static const NSTimeInterval RETRY_EVERY = 0.5;

// A failed read is usually a passing Bluetooth hiccup rather than a headset
// that has gone away, so an existing reading is kept rather than erased. It is
// only given up on once it is old enough to be misleading.
static const NSTimeInterval STALE_AFTER = 30 * 60;

typedef NS_ENUM(int, ExitCode) {
    EXIT_OK             = 0,
    EXIT_NO_DEVICE      = 1,  // nothing connected that matches
    EXIT_NO_SERVICE     = 2,  // connected, but no control channel advertised
    EXIT_NO_CHANNEL     = 3,  // the control channel refused to open
    EXIT_NO_REPLY       = 4,  // opened, but the headset never answered
    EXIT_USAGE          = 64
};

static BOOL verbose = NO;

static void trace(const char *dir, NSData *frame) {
    if (!verbose) return;
    const uint8_t *b = frame.bytes;
    fprintf(stderr, "%s %lu:", dir, (unsigned long)frame.length);
    for (NSUInteger i = 0; i < frame.length; i++) fprintf(stderr, " %02X", b[i]);
    fprintf(stderr, "\n");
}

static NSData *MDRFrame(uint8_t type, uint8_t seq, NSData *payload) {
    NSMutableData *body = [NSMutableData data];
    [body appendBytes:&type length:1];
    [body appendBytes:&seq length:1];
    uint32_t n = (uint32_t)payload.length;
    uint8_t len[4] = { (n >> 24) & 0xFF, (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF };
    [body appendBytes:len length:4];
    [body appendData:payload];

    const uint8_t *b = body.bytes;
    uint8_t sum = 0;
    for (NSUInteger i = 0; i < body.length; i++) sum += b[i];
    [body appendBytes:&sum length:1];

    NSMutableData *out = [NSMutableData data];
    [out appendBytes:&START_MARKER length:1];
    b = body.bytes;
    for (NSUInteger i = 0; i < body.length; i++) {
        uint8_t c = b[i];
        if (c == START_MARKER || c == END_MARKER || c == ESCAPE_MARKER) {
            uint8_t esc = ESCAPE_MARKER, masked = c & ESCAPE_MASK;
            [out appendBytes:&esc length:1];
            [out appendBytes:&masked length:1];
        } else {
            [out appendBytes:&c length:1];
        }
    }
    [out appendBytes:&END_MARKER length:1];
    return out;
}

#pragma mark - Talking to the headset

@interface MDRClient : NSObject <IOBluetoothRFCOMMChannelDelegate>
@property (nonatomic) NSMutableData *rx;
@property (nonatomic) int battery;
@property (nonatomic) BOOL charging;
@property (nonatomic) BOOL done;
@property (nonatomic) uint8_t txSeq;
@property (nonatomic) BOOL protocolV2;
@property (nonatomic, weak) IOBluetoothRFCOMMChannel *channel;
@end

@implementation MDRClient

- (instancetype)init {
    if ((self = [super init])) { _rx = [NSMutableData data]; _battery = -1; }
    return self;
}

- (void)send:(uint8_t)type payload:(NSData *)payload seq:(uint8_t)seq {
    if (!self.channel) return;
    NSData *frame = MDRFrame(type, seq, payload);
    trace("TX", frame);
    [self.channel writeSync:(void *)frame.bytes length:(UInt16)frame.length];
}

- (void)sendData:(NSData *)payload {
    [self send:TYPE_DATA_MDR payload:payload seq:self.txSeq];
    self.txSeq ^= 1;
}

- (void)requestBattery {
    uint8_t req[2] = { self.protocolV2 ? CMD_V2_GET_BATTERY : CMD_GET_BATTERY, BATTERY_SINGLE };
    [self sendData:[NSData dataWithBytes:req length:2]];
}

- (void)rfcommChannelOpenComplete:(IOBluetoothRFCOMMChannel *)ch status:(IOReturn)error {
    if (verbose) fprintf(stderr, "open complete: 0x%08X\n", error);
    if (error != kIOReturnSuccess) { self.done = YES; return; }
    self.channel = ch;
    uint8_t hello[2] = { CMD_GET_PROTOCOL, 0x00 };
    [self sendData:[NSData dataWithBytes:hello length:2]];
}

- (void)rfcommChannelClosed:(IOBluetoothRFCOMMChannel *)ch {
    if (verbose) fprintf(stderr, "channel closed by peer\n");
    self.done = YES;
}

- (void)rfcommChannelData:(IOBluetoothRFCOMMChannel *)ch data:(void *)data length:(size_t)len {
    if (verbose) {
        NSData *d = [NSData dataWithBytes:data length:len];
        trace("RX", d);
    }
    [self.rx appendBytes:data length:len];
    [self parse];
}

- (void)handlePayload:(const uint8_t *)payload length:(NSUInteger)plen seq:(uint8_t)seq {
    // Unacknowledged frames are retransmitted indefinitely, so acknowledge
    // everything, including the notifications we have no interest in.
    [self send:TYPE_ACK payload:[NSData data] seq:(uint8_t)(1 - seq)];
    if (plen < 1) return;

    BOOL isBattery = (payload[0] == CMD_RET_BATTERY  || payload[0] == CMD_NTFY_BATTERY ||
                      payload[0] == CMD_V2_RET_BATTERY || payload[0] == CMD_V2_NTFY_BATTERY);

    // The headset interleaves unsolicited notifications (playback state, noise
    // cancelling and so on) with replies, so react to the battery answer
    // wherever it appears rather than expecting a strict order.
    if (isBattery && plen >= 3 && payload[2] <= 100) {
        self.battery = payload[2];
        self.charging = (plen >= 4) ? (payload[3] == 0x01) : NO;
        self.done = YES;
    } else if (payload[0] == CMD_RET_PROTOCOL) {
        self.protocolV2 = (plen >= PROTOCOL_V2_REPLY_LENGTH);
        if (verbose) {
            fprintf(stderr, "-- protocol generation %d (handshake reply %lu bytes)\n",
                    self.protocolV2 ? 2 : 1, (unsigned long)plen);
        }
        [self requestBattery];
    }
}

- (void)parse {
    const uint8_t *b = self.rx.bytes;
    NSUInteger n = self.rx.length, i = 0, consumed = 0;

    while (i < n) {
        while (i < n && b[i] != START_MARKER) i++;
        if (i >= n) break;
        NSUInteger end = i + 1;
        while (end < n && b[end] != END_MARKER) end++;
        if (end >= n) break; // frame still arriving

        NSMutableData *body = [NSMutableData data];
        for (NSUInteger j = i + 1; j < end; j++) {
            uint8_t c = b[j];
            if (c == ESCAPE_MARKER && j + 1 < end) {
                uint8_t v = b[++j] | (uint8_t)~ESCAPE_MASK;
                [body appendBytes:&v length:1];
            } else {
                [body appendBytes:&c length:1];
            }
        }

        if (body.length >= 7) {
            const uint8_t *p = body.bytes;
            if (p[0] != TYPE_ACK) [self handlePayload:p + 6 length:body.length - 7 seq:p[1]];
        }
        i = end + 1;
        consumed = i;
    }
    if (consumed > 0) [self.rx replaceBytesInRange:NSMakeRange(0, consumed) withBytes:NULL length:0];
}
@end

#pragma mark - Finding the right headset

// The name of the device macOS is currently playing through. Used so that the
// battery shown belongs to whatever you are actually listening with.
static NSString *DefaultOutputDeviceName(void) {
    AudioObjectID dev = kAudioObjectUnknown;
    UInt32 size = sizeof(dev);
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, &dev) != noErr)
        return nil;

    CFStringRef name = NULL;
    size = sizeof(name);
    addr.mSelector = kAudioObjectPropertyName;
    if (AudioObjectGetPropertyData(dev, &addr, 0, NULL, &size, &name) != noErr) return nil;
    return (__bridge_transfer NSString *)name;
}

static BOOL RecordMatchesUUID(IOBluetoothSDPServiceRecord *rec, NSString *hex) {
    unsigned char bytes[16];
    for (int i = 0; i < 16; i++) {
        unsigned int b = 0;
        sscanf([[hex substringWithRange:NSMakeRange(i * 2, 2)] UTF8String], "%2x", &b);
        bytes[i] = (unsigned char)b;
    }
    IOBluetoothSDPUUID *uuid = [IOBluetoothSDPUUID uuidWithBytes:bytes length:16];
    return [rec hasServiceFromArray:@[ uuid ]];
}

static BluetoothRFCOMMChannelID ControlChannel(IOBluetoothDevice *dev) {
    BluetoothRFCOMMChannelID cid = 0;
    // SDP results are cached by the system, so the first pass is usually free;
    // only query the device if the cache has nothing useful.
    for (int attempt = 0; attempt < 2 && cid == 0; attempt++) {
        if (attempt == 1) {
            [dev performSDPQuery:nil];
            [NSThread sleepForTimeInterval:1.0];
        }
        // A device may advertise both generations; the newer one wins, which is
        // the same preference the reference implementations apply.
        for (NSString *uuid in @[ SERVICE_UUID_V2, SERVICE_UUID_V1 ]) {
            for (IOBluetoothSDPServiceRecord *rec in [dev services]) {
                if (!RecordMatchesUUID(rec, uuid)) continue;
                if ([rec getRFCOMMChannelID:&cid] == kIOReturnSuccess && cid != 0) break;
                cid = 0;
            }
            if (cid != 0) break;
        }
    }
    return cid;
}


// True when the file already holds a reading recent enough to go on showing.
static BOOL FreshReadingExists(NSString *path) {
    struct stat st;
    if (stat(path.UTF8String, &st) != 0) return NO;
    if (st.st_size == 0) return NO;
    return (time(NULL) - st.st_mtime) < (time_t)STALE_AFTER;
}

static void usage(void) {
    fprintf(stderr,
        "usage: headphone-battery [options]\n"
        "\n"
        "Reads the battery level of connected Sony headphones over Bluetooth.\n"
        "With no options, reports the headphones currently selected as the\n"
        "audio output device, and exits quietly if they are not.\n"
        "\n"
        "options:\n"
        "  -d, --device <name>   match a paired device by name substring\n"
        "                        instead of using the current output device\n"
        "  -a, --any             use the first connected device that answers,\n"
        "                        whether or not it is the output device\n"
        "  -j, --json            print {\"device\":..,\"percent\":..,\"charging\":..}\n"
        "  -l, --list            list connected devices and their control channel\n"
        "  -t, --timeout <secs>  give up after this long (default 5)\n"
        "  -o, --output <path>   write the reading to a file instead of stdout,\n"
        "                        atomically, emptying it when there is nothing\n"
        "                        to report\n"
        "  -v, --verbose         trace the protocol exchange on stderr\n"
        "  -w, --watch           stay running and re-read whenever the audio\n"
        "                        output device changes, which is when the\n"
        "                        answer changes\n"
        "  -n, --notify <cmd>    in watch mode, run <cmd> after the reading\n"
        "                        changes, e.g. to nudge a status bar\n"
        "  -i, --interval <sec>  in watch mode, re-read this often as a\n"
        "                        backstop (default 300)\n"
        "  -h, --help            show this message\n"
        "\n"
        "exit codes:\n"
        "  0 success   1 no matching device   2 no control channel\n"
        "  3 channel would not open   4 no reply   64 usage error\n");
}

// Talking to Bluetooth can block before the run loop ever starts — most
// notably when the process is not permitted to use it, where CoreBluetooth
// waits forever rather than failing. The run loop deadline cannot help there,
// so the timeout is also armed as a signal.
static void OnAlarm(int sig) {
    (void)sig;
    // A hang is treated like any other failed read: the previous reading is
    // left alone, because a headset that is still being listened through has
    // not stopped having a battery just because one attempt jammed. The sweep
    // at startup is what eventually clears a reading that stopped being true.
    _exit(EXIT_NO_REPLY);
}

// Written by rename so that a reader never sees a half-written file.
static int WriteAtomically(NSString *path, NSString *contents) {
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *tmp = [path stringByAppendingFormat:@".%d.tmp", getpid()];
    if (![contents writeToFile:tmp atomically:NO encoding:NSUTF8StringEncoding error:NULL]) return -1;
    if (rename(tmp.UTF8String, path.UTF8String) != 0) { unlink(tmp.UTF8String); return -1; }
    return 0;
}


// Nothing to report is reported as emptiness rather than silence, so a reader
// can tell "not listening through these" from "never ran".
#define GONE(code) do { if (output) WriteAtomically(output, @""); return (code); } while (0)

// A read that fails while the headset is still the output device is a
// different thing from the headset being absent: erasing the reading would
// make the widget flicker away on every transient radio problem.
#define UNREAD(code) do { \
    if (output && !FreshReadingExists(output)) WriteAtomically(output, @""); \
    return (code); \
} while (0)

// One complete attempt: work out whether there is anything worth reporting,
// and if so go and ask the headset. Split out of main so that watch mode can
// repeat it without re-entering the process.
static int ReadOnce(NSString *wanted, BOOL any, BOOL json,
                    NSString *output, NSTimeInterval timeout) {
  @autoreleasepool {
    // Clear a reading that has aged out before doing anything that might hang,
    // so that even a permanently unreachable headset stops being reported
    // rather than freezing at its last known level.
    if (output && !FreshReadingExists(output)) {
        struct stat st;
        if (stat(output.UTF8String, &st) == 0 && st.st_size > 0) WriteAtomically(output, @"");
    }

    // Generous relative to the run loop deadline: this is the last resort for
    // a call that never returns, not the normal way to give up. Disarmed on
    // the way out so that it cannot fire while the watcher sits idle.
    signal(SIGALRM, OnAlarm);
    alarm((unsigned)(timeout * 2) + 5);

    // Default behaviour: whatever you are listening through right now.
    if (!wanted && !any) {
        wanted = DefaultOutputDeviceName();
        if (!wanted) { alarm(0); GONE(EXIT_NO_DEVICE); }
    }

    NSMutableArray<IOBluetoothDevice *> *candidates = [NSMutableArray array];
    for (IOBluetoothDevice *d in [IOBluetoothDevice pairedDevices]) {
        if (![d isConnected]) continue;
        NSString *nm = [d name] ?: @"";
        if (wanted && [nm rangeOfString:wanted].location == NSNotFound) continue;
        [candidates addObject:d];
    }
    if (candidates.count == 0) { alarm(0); GONE(EXIT_NO_DEVICE); }

    int lastError = EXIT_NO_DEVICE;
    for (IOBluetoothDevice *dev in candidates) {
        BluetoothRFCOMMChannelID cid = ControlChannel(dev);
        if (cid == 0) { lastError = EXIT_NO_SERVICE; continue; }

        MDRClient *client = [[MDRClient alloc] init];
        IOBluetoothRFCOMMChannel *ch = nil;
        if (verbose) fprintf(stderr, "opening %s channel %d\n",
                             ([dev name] ?: @"?").UTF8String, cid);
        IOReturn rc = [dev openRFCOMMChannelAsync:&ch withChannelID:cid delegate:client];
        if (verbose) fprintf(stderr, "open call returned: 0x%08X\n", rc);
        if (rc != kIOReturnSuccess) { lastError = EXIT_NO_CHANNEL; continue; }

        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
        NSDate *nextRetry = [NSDate dateWithTimeIntervalSinceNow:RETRY_EVERY];
        while (!client.done && [deadline timeIntervalSinceNow] > 0) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            // The handshake reply occasionally gets lost among the headset's
            // own notifications; asking again is harmless and settles it.
            if (client.channel && [nextRetry timeIntervalSinceNow] <= 0) {
                [client requestBattery];
                nextRetry = [NSDate dateWithTimeIntervalSinceNow:RETRY_EVERY];
            }
        }
        [ch closeChannel];

        if (client.battery < 0) { lastError = EXIT_NO_REPLY; continue; }

        NSString *name = [dev name] ?: @"";
        NSString *reading = json
            ? [NSString stringWithFormat:@"{\"device\":\"%@\",\"percent\":%d,\"charging\":%s}\n",
                                         name, client.battery, client.charging ? "true" : "false"]
            : [NSString stringWithFormat:@"%d\n", client.battery];

        alarm(0);
        if (output) {
            if (WriteAtomically(output, reading) != 0) return EXIT_USAGE;
        } else {
            fputs(reading.UTF8String, stdout);
        }
        return EXIT_OK;
    }
    alarm(0);
    UNREAD(lastError);
  }
}

static int ListDevices(void) {
    for (IOBluetoothDevice *d in [IOBluetoothDevice pairedDevices]) {
        if (![d isConnected]) continue;
        BluetoothRFCOMMChannelID cid = ControlChannel(d);
        printf("%-28s %s\n", ([d name] ?: @"(unnamed)").UTF8String,
               cid ? [NSString stringWithFormat:@"control channel %d", cid].UTF8String
                   : "no control channel");
    }
    return EXIT_OK;
}


// Whether there is a connected, matching device that is also what you are
// listening through. Answering this needs only the list of paired devices, no
// connection to any of them, so it is safe to ask the instant the route
// changes and it cannot disturb the headset.
static BOOL TargetPresent(NSString *wanted, BOOL any) {
    if (!wanted && !any) {
        wanted = DefaultOutputDeviceName();
        if (!wanted) return NO;
    }
    for (IOBluetoothDevice *d in [IOBluetoothDevice pairedDevices]) {
        if (![d isConnected]) continue;
        NSString *nm = [d name] ?: @"";
        if (wanted && [nm rangeOfString:wanted].location == NSNotFound) continue;
        return YES;
    }
    return NO;
}

// The watcher exists because the answer changes the moment you switch what you
// are listening through, and nothing about polling can be both prompt and
// cheap. macOS will say so immediately, so the work is done on being told
// rather than on a timer, and the bar is nudged only when the answer actually
// changed.
@interface Watcher : NSObject
@property (nonatomic, copy) NSString *wanted, *output, *notify;
@property (nonatomic) BOOL any, json;
@property (nonatomic) NSTimeInterval timeout, interval;
@property (nonatomic) BOOL busy;
@property (nonatomic, strong) NSMutableArray<NSTimer *> *pending;
@end

@implementation Watcher

- (NSString *)currentReading {
    if (!self.output) return @"";
    NSString *c = [NSString stringWithContentsOfFile:self.output
                                            encoding:NSUTF8StringEncoding error:NULL];
    return c ?: @"";
}

- (void)refresh {
    // A read spins a run loop of its own while it waits, which lets the timers
    // below fire straight back into here. Two reads at once is not merely
    // wasteful: the headset serves one control connection at a time, so they
    // knock each other out and both come back empty handed.
    if (self.busy) {
        if (verbose) fprintf(stderr, "refresh: skipped, one already running\n");
        return;
    }
    self.busy = YES;

    NSString *before = [self currentReading];
    int rc = ReadOnce(self.wanted, self.any, self.json, self.output, self.timeout);
    NSString *after = [self currentReading];
    self.busy = NO;

    if (verbose) fprintf(stderr, "refresh: rc=%d %s\n", rc,
                         [before isEqual:after] ? "(unchanged)" : "(changed)");

    // Once there is a reading the rest of the chasing is pointless. Only a
    // real reading stops it: a headset that has just become the output device
    // often reports itself as not there yet, and giving up on that would be
    // giving up exactly when the retries are the point.
    if (rc == EXIT_OK) [self cancelPending];

    // Only worth waking anything up if what a reader would see is different.
    if (![before isEqual:after] && self.notify) system(self.notify.UTF8String);
}

- (void)cancelPending {
    for (NSTimer *t in self.pending) [t invalidate];
    [self.pending removeAllObjects];
}

// A headset that has just become the output device is often not ready to talk
// yet: the audio link comes up before the control channel will answer. So a
// change is chased a few times over the following seconds rather than asked
// about once and given up on.
- (void)deviceChanged {
    [self cancelPending];

    // Losing the headset is known at once and needs nothing from Bluetooth, so
    // the answer can be put right immediately.
    if (!TargetPresent(self.wanted, self.any)) {
        [self refresh];
        return;
    }

    // Gaining it is not symmetrical. The headset will not entertain a control
    // connection while the audio route is still settling, and asking too early
    // does not simply fail: it wedges the channel, so every later attempt fails
    // too until the link is torn down. Hence the wait before the first ask.
    for (NSNumber *delay in @[ @5.0, @12.0, @30.0 ]) {
        NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:delay.doubleValue
                                                      target:self
                                                    selector:@selector(refresh)
                                                    userInfo:nil
                                                     repeats:NO];
        [self.pending addObject:t];
    }
}

- (void)start {
    self.pending = [NSMutableArray array];

    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectAddPropertyListenerBlock(
        kAudioObjectSystemObject, &addr, dispatch_get_main_queue(),
        ^(UInt32 n, const AudioObjectPropertyAddress *a) {
            (void)n; (void)a;
            if (verbose) fprintf(stderr, "output device changed\n");
            [self deviceChanged];
        });

    // A slow backstop, for the level falling as you listen and for anything the
    // notification does not cover.
    [NSTimer scheduledTimerWithTimeInterval:self.interval
                                     target:self
                                   selector:@selector(refresh)
                                   userInfo:nil
                                    repeats:YES];

    [self refresh];
    [[NSRunLoop currentRunLoop] run];
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *wanted = nil, *output = nil, *notify = nil;
        BOOL any = NO, json = NO, list = NO, watch = NO;
        NSTimeInterval timeout = 5.0, interval = 300.0;

        for (int i = 1; i < argc; i++) {
            NSString *a = [NSString stringWithUTF8String:argv[i]];
            if ([a isEqual:@"-h"] || [a isEqual:@"--help"]) { usage(); return EXIT_OK; }
            else if ([a isEqual:@"-a"] || [a isEqual:@"--any"]) any = YES;
            else if ([a isEqual:@"-j"] || [a isEqual:@"--json"]) json = YES;
            else if ([a isEqual:@"-l"] || [a isEqual:@"--list"]) list = YES;
            else if ([a isEqual:@"-v"] || [a isEqual:@"--verbose"]) verbose = YES;
            else if ([a isEqual:@"-w"] || [a isEqual:@"--watch"]) watch = YES;
            else if ([a isEqual:@"-d"] || [a isEqual:@"--device"]) {
                if (++i >= argc) { usage(); return EXIT_USAGE; }
                wanted = [NSString stringWithUTF8String:argv[i]];
            } else if ([a isEqual:@"-t"] || [a isEqual:@"--timeout"]) {
                if (++i >= argc) { usage(); return EXIT_USAGE; }
                timeout = atof(argv[i]);
            } else if ([a isEqual:@"-o"] || [a isEqual:@"--output"]) {
                if (++i >= argc) { usage(); return EXIT_USAGE; }
                output = [NSString stringWithUTF8String:argv[i]];
            } else if ([a isEqual:@"-n"] || [a isEqual:@"--notify"]) {
                if (++i >= argc) { usage(); return EXIT_USAGE; }
                notify = [NSString stringWithUTF8String:argv[i]];
            } else if ([a isEqual:@"-i"] || [a isEqual:@"--interval"]) {
                if (++i >= argc) { usage(); return EXIT_USAGE; }
                interval = atof(argv[i]);
            } else { usage(); return EXIT_USAGE; }
        }

        if (list) return ListDevices();

        if (watch) {
            if (interval <= 0) { usage(); return EXIT_USAGE; }
            Watcher *w = [[Watcher alloc] init];
            w.wanted = wanted; w.output = output; w.notify = notify;
            w.any = any; w.json = json; w.timeout = timeout; w.interval = interval;
            [w start];
            return EXIT_OK; // not reached
        }

        return ReadOnce(wanted, any, json, output, timeout);
    }
}
