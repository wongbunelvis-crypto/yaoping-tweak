// 遥屏 · 被控端插件
// 作用：连公网上中转，收 iPad 发来的触控指令，注入到系统（真的点下去）。
// 装好后重启桌面（respring）即生效，不需要打开任何 App。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <notify.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <string.h>

// ---------- 私有 IO HID 注入 ----------

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

// 自己定义，避免依赖 IOKit 私有头
typedef int32_t KxFixed;
typedef struct { UInt32 hi; UInt32 lo; } KxTime;   // 与 AbsoluteTime(UnsignedWide) 同布局

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
extern void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef client, IOHIDEventRef event);
extern IOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef allocator, KxTime timeStamp,
                                                    int transducerType, uint32_t index, uint32_t identity,
                                                    uint32_t eventMask, uint32_t buttonMask,
                                                    KxFixed x, KxFixed y, KxFixed z,
                                                    KxFixed tipPressure, KxFixed twist,
                                                    Boolean range, Boolean touch, int options);
extern IOHIDEventRef IOHIDEventCreateDigitizerFingerEventWithQuality(CFAllocatorRef allocator, KxTime timeStamp,
                                                                     uint32_t index, uint32_t identity, uint32_t eventMask,
                                                                     KxFixed x, KxFixed y, KxFixed z,
                                                                     KxFixed tipPressure, KxFixed twist, KxFixed quality,
                                                                     Boolean range, Boolean touch, int options);
extern void IOHIDEventAppendEvent(IOHIDEventRef parent, IOHIDEventRef child, int options);
extern void IOHIDEventSetIntegerValue(IOHIDEventRef event, uint32_t field, int value);

static IOHIDEventSystemClientRef gHID = NULL;

// 字段常量（避免引入私有头）
enum {
    kFieldDigitizerIsDisplayIntegrated = 0x00050000 + 0x14,
};

static void kxLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], s];
    NSString *path = @"/var/mobile/yaoping.log";
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    @try { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; }
    @catch (NSException *e) {}
    [fh closeFile];
}

static void kxInject(CGFloat px, CGFloat py, int phase) {
    // phase: 0=按下 1=移动 2=抬起
    if (!gHID) gHID = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!gHID) { kxLog(@"HID client 创建失败"); return; }

    uint32_t mask;
    Boolean range = 1, touch = 1;
    if (phase == 0)      mask = 0x03;          // range + touch
    else if (phase == 1) mask = 0x04;          // position
    else                 mask = 0x03, range = 0, touch = 0;

    AbsoluteTime raw = mach_absolute_time();
    KxTime ts;
    ts.hi = (UInt32)(((uint64_t)raw) >> 32);
    ts.lo = (UInt32)((uint64_t)raw);
    KxFixed fx = (KxFixed)(px * 16.0);
    KxFixed fy = (KxFixed)(py * 16.0);

    IOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEventWithQuality(
        kCFAllocatorDefault, ts, 1, 2, mask, fx, fy, 0, 0, 0, 0, range, touch, 0);
    if (!finger) return;
    IOHIDEventRef hand = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, ts, 3 /* hand */, 0, 0, 0, 0, 0, 0, 0, 0, 0, range, touch, 0);
    if (!hand) { CFRelease(finger); return; }
    IOHIDEventAppendEvent(hand, finger, 0);
    IOHIDEventSetIntegerValue(finger, kFieldDigitizerIsDisplayIntegrated, 1);
    IOHIDEventSetIntegerValue(hand, kFieldDigitizerIsDisplayIntegrated, 1);
    IOHIDEventSystemClientDispatchEvent(gHID, hand);
    CFRelease(hand);
    CFRelease(finger);
}

// ---------- 极简 MQTT（明文 1883，只用于收指令） ----------

static int gSock = -1;

static void mqttSendRaw(const unsigned char *bytes, size_t len) {
    if (gSock < 0) return;
    write(gSock, bytes, len);
}

static void mqttSendConnect(const char *clientId) {
    size_t idLen = strlen(clientId);
    unsigned char body[128];
    int p = 0;
    body[p++] = 0x00; body[p++] = 0x04; body[p++] = 'M'; body[p++] = 'Q'; body[p++] = 'T'; body[p++] = 'T';
    body[p++] = 0x04;
    body[p++] = 0x02;
    body[p++] = 0x00; body[p++] = 0x3C;
    body[p++] = 0x00; body[p++] = (unsigned char)idLen;
    memcpy(body + p, clientId, idLen);
    p += (int)idLen;

    unsigned char pkt[160];
    pkt[0] = 0x10;
    pkt[1] = (unsigned char)p;
    memcpy(pkt + 2, body, p);
    mqttSendRaw(pkt, p + 2);
}

static void mqttSubscribe(void) {
    unsigned char pkt[128];
    int p = 0;
    pkt[p++] = 0x82;
    pkt[p++] = 15;                 // 剩余长度
    pkt[p++] = 0x00; pkt[p++] = 0x01;
    pkt[p++] = 0x00; pkt[p++] = 13;  // topic 长度 13
    const char *t = "yaoping/+/t";
    memcpy(pkt + p, t, 13);
    p += 13;
    pkt[p++] = 0x00;
    mqttSendRaw(pkt, p);
}

static void handleCommand(const char *payload) {
    char phase;
    float nx, ny;
    if (sscanf(payload, "%c %f %f", &phase, &nx, &ny) != 3) return;
    if (nx < 0 || nx > 1 || ny < 0 || ny > 1) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWin = nil;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) { keyWin = w; break; }
        }
        UIScreen *scr = [UIScreen mainScreen];
        CGFloat w = scr.bounds.size.width;
        CGFloat h = scr.bounds.size.height;
        CGFloat px = nx * w;
        CGFloat py = ny * h;
        int ph = 0;
        if (phase == 'm') ph = 1;
        else if (phase == 'u') ph = 2;
        kxInject(px, py, ph);
        kxLog(@"注入 %c (%.0f, %.0f) screen %.0fx%.0f win %@", phase, px, py, w, h, keyWin);
    });
}

static void mqttLoop(void) {
    struct hostent *he = gethostbyname("broker.emqx.io");
    if (!he) { kxLog(@"DNS 失败"); return; }

    gSock = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(1883);
    memcpy(&addr.sin_addr, he->h_addr_list[0], sizeof(struct in_addr));
    if (connect(gSock, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        kxLog(@"连接失败 errno=%d", errno);
        close(gSock); gSock = -1; return;
    }
    kxLog(@"TCP 已连接");

    NSString *cid = [NSString stringWithFormat:@"j%@", [[NSUUID UUID].UUIDString substringToIndex:8]];
    mqttSendConnect(cid.UTF8String);

    unsigned char buf[8192];
    BOOL sub = NO;
    time_t lastPing = time(NULL);

    while (gSock > 0) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(gSock, &rfds);
        struct timeval tv = {1, 0};
        int r = select(gSock + 1, &rfds, NULL, NULL, &tv);
        if (r > 0) {
            ssize_t n = read(gSock, buf, sizeof(buf));
            if (n <= 0) { kxLog(@"断开"); break; }
            for (ssize_t i = 0; i < n; i++) {
                unsigned char h = buf[i];
                int type = h >> 4;
                if (type == 2 && !sub) { sub = YES; mqttSubscribe(); kxLog(@"已订阅"); }
                else if (type == 3) {
                    // PUBLISH qos0: 跳过剩余长度(1字节，本项目够用)
                    int payloadStart = (int)i + 2;
                    // 跳过 topic
                    unsigned char tl = buf[i + 1];
                    int tlen = buf[payloadStart] * 256 + buf[payloadStart + 1];
                    // 找消息结束（遇到下一个包起始字节不可靠，这里简化为取到 buffer 末尾）
                    int ps = payloadStart + 2 + tlen;
                    if (ps < n) {
                        char msg[64];
                        int len = (int)(n - ps);
                        if (len > 63) len = 63;
                        memcpy(msg, buf + ps, len);
                        msg[len] = 0;
                        handleCommand(msg);
                    }
                }
            }
        }
        if (time(NULL) - lastPing > 40) {
            unsigned char ping[2] = {0xC0, 0x00};
            mqttSendRaw(ping, 2);
            lastPing = time(NULL);
        }
    }
    if (gSock > 0) { close(gSock); gSock = -1; }
}

__attribute__((constructor)) static void kxInit(void) {
    kxLog(@"插件已载入");
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (1) {
            mqttLoop();
            sleep(5);
        }
    });
}
