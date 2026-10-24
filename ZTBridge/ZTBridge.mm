#import "ZTBridge.h"
#include "ZeroTierOne.h"
#include "version.h"

#include <arpa/inet.h>
#include <sys/stat.h>
#include <sys/types.h>

// 核心编译版本（ZEROTIER_ONE_VERSION_* 宏）
static NSString* const kAppGroupID = @"group.cn.imgozi.i.PlanetPort";

// 类扩展前置：C 回调函数需要访问这些属性
@interface ZTBridge ()
@property (nonatomic, assign) ZT_Node* node;
@property (nonatomic, copy) NSString* dataStorePath;
@property (nonatomic, strong) dispatch_queue_t callbackQueue;
@end

@implementation ZTNodeStatusData
@end

@implementation ZTPeerData
@end

@implementation ZTNetworkConfigData
@end

// MARK: - 工具函数

static int64_t ztNowMillis() {
    return (int64_t)([[NSDate date] timeIntervalSince1970] * 1000.0);
}

/// ZeroTier 的 InetAddress 语义：IP 装在 sockaddr 的地址字段，
/// 前缀长度装在 port 字段（网络字节序）。
static NSString* ztInetAddrToString(const struct sockaddr_storage* ss) {
    char buf[INET6_ADDRSTRLEN] = {0};
    if (ss->ss_family == AF_INET) {
        const struct sockaddr_in* sa4 = (const struct sockaddr_in*)ss;
        if (inet_ntop(AF_INET, &sa4->sin_addr, buf, sizeof(buf))) {
            return [NSString stringWithFormat:@"%s/%u", buf, (unsigned)ntohs(sa4->sin_port)];
        }
    } else if (ss->ss_family == AF_INET6) {
        const struct sockaddr_in6* sa6 = (const struct sockaddr_in6*)ss;
        if (inet_ntop(AF_INET6, &sa6->sin6_addr, buf, sizeof(buf))) {
            return [NSString stringWithFormat:@"%s/%u", buf, (unsigned)ntohs(sa6->sin6_port)];
        }
    }
    return @"";
}

/// 仅输出 IP。用于路由 via；ZeroTier 规定 via 的 port 字段无意义。
static NSString* ztInetIPToString(const struct sockaddr_storage* ss) {
    char buf[INET6_ADDRSTRLEN] = {0};
    if (ss->ss_family == AF_INET) {
        const struct sockaddr_in* sa4 = (const struct sockaddr_in*)ss;
        if (inet_ntop(AF_INET, &sa4->sin_addr, buf, sizeof(buf)))
            return [NSString stringWithUTF8String:buf];
    } else if (ss->ss_family == AF_INET6) {
        const struct sockaddr_in6* sa6 = (const struct sockaddr_in6*)ss;
        if (inet_ntop(AF_INET6, &sa6->sin6_addr, buf, sizeof(buf)))
            return [NSString stringWithUTF8String:buf];
    }
    return @"";
}

/// 物理路径地址（真实端口）转 "ip:port"
static NSString* ztSockAddrToString(const struct sockaddr_storage* ss) {
    char buf[INET6_ADDRSTRLEN] = {0};
    if (ss->ss_family == AF_INET) {
        const struct sockaddr_in* sa4 = (const struct sockaddr_in*)ss;
        if (inet_ntop(AF_INET, &sa4->sin_addr, buf, sizeof(buf))) {
            return [NSString stringWithFormat:@"%s:%u", buf, (unsigned)ntohs(sa4->sin_port)];
        }
    } else if (ss->ss_family == AF_INET6) {
        const struct sockaddr_in6* sa6 = (const struct sockaddr_in6*)ss;
        if (inet_ntop(AF_INET6, &sa6->sin6_addr, buf, sizeof(buf))) {
            return [NSString stringWithFormat:@"[%s]:%u", buf, (unsigned)ntohs(sa6->sin6_port)];
        }
    }
    return @"";
}

/// 状态对象 → 状态文件路径
static NSString* ztStateFilePath(NSString* home, enum ZT_StateObjectType type, const uint64_t id[2]) {
    switch (type) {
        case ZT_STATE_OBJECT_IDENTITY_PUBLIC:
            return [home stringByAppendingPathComponent:@"identity.public"];
        case ZT_STATE_OBJECT_IDENTITY_SECRET:
            return [home stringByAppendingPathComponent:@"identity.secret"];
        case ZT_STATE_OBJECT_PLANET:
            return [home stringByAppendingPathComponent:@"planet"];
        case ZT_STATE_OBJECT_MOON:
            return [[home stringByAppendingPathComponent:@"moons.d"]
                stringByAppendingPathComponent:[NSString stringWithFormat:@"%016llx.moon", id[0]]];
        case ZT_STATE_OBJECT_PEER:
            return [[home stringByAppendingPathComponent:@"peers.d"]
                stringByAppendingPathComponent:[NSString stringWithFormat:@"%10llu", id[0]]];
        case ZT_STATE_OBJECT_NETWORK_CONFIG:
            return [[home stringByAppendingPathComponent:@"networks.d"]
                stringByAppendingPathComponent:[NSString stringWithFormat:@"%016llx.conf", id[0]]];
        default:
            return nil;
    }
}

/// Planet 重定向 hook：支持从 datastore/planets 中选择多份私有 Planet。
/// 旧版 planet_use_custom + planet.custom 仍作为升级兜底。
static NSString* ztHookedPath(NSString* rawPath, enum ZT_StateObjectType type) {
    NSUserDefaults* d = [[NSUserDefaults alloc] initWithSuiteName:kAppGroupID];
    if (type == ZT_STATE_OBJECT_PLANET) {
        if (d && [d boolForKey:@"planet_use_custom"]) {
            NSString* fileName = [d stringForKey:@"planet_active_file"];
            if (fileName.length > 0 &&
                [fileName rangeOfString:@"/"].location == NSNotFound &&
                [fileName rangeOfString:@".."].location == NSNotFound) {
                NSString* home = [rawPath stringByDeletingLastPathComponent];
                return [[home stringByAppendingPathComponent:@"planets"]
                    stringByAppendingPathComponent:fileName];
            }
            return [[rawPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"planet.custom"];
        }
    }

    // 网络配置、Moon 和 Peer 缓存属于当前 Planet，避免相同 ID 在不同世界间串数据。
    if (type == ZT_STATE_OBJECT_MOON || type == ZT_STATE_OBJECT_PEER ||
        type == ZT_STATE_OBJECT_NETWORK_CONFIG) {
        NSString* planetId = [d stringForKey:@"planet_active_id"] ?: @"official";
        NSCharacterSet* invalid = [[NSCharacterSet characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"] invertedSet];
        if (planetId.length == 0 || [planetId rangeOfCharacterFromSet:invalid].location != NSNotFound) {
            planetId = @"official";
        }
        NSString* stateDirectory = [rawPath stringByDeletingLastPathComponent];
        NSString* home = [stateDirectory stringByDeletingLastPathComponent];
        NSString* kindDirectory = [stateDirectory lastPathComponent];
        return [[[[home stringByAppendingPathComponent:@"planet-state"]
            stringByAppendingPathComponent:planetId]
            stringByAppendingPathComponent:kindDirectory]
            stringByAppendingPathComponent:[rawPath lastPathComponent]];
    }
    return rawPath;
}

// MARK: - C 回调

static void ztStatePut(ZT_Node* node, void* uptr, void* tptr,
                       enum ZT_StateObjectType type, const uint64_t id[2],
                       const void* data, int len) {
    ZTBridge* bridge = (__bridge ZTBridge*)uptr;
    NSString* path = ztStateFilePath(bridge.dataStorePath, type, id);
    if (!path) return;
    path = ztHookedPath(path, type);

    if (len < 0) {
        // -1 表示删除
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        return;
    }
    NSString* dir = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSData* d = [NSData dataWithBytes:data length:(unsigned)len];
    NSError* err = nil;
    [d writeToFile:path options:NSDataWritingAtomic error:&err];
    if (!err && type == ZT_STATE_OBJECT_IDENTITY_SECRET) {
        // 私钥收紧权限
        chmod(path.fileSystemRepresentation, 0600);
    }
}

static int ztStateGet(ZT_Node* node, void* uptr, void* tptr,
                      enum ZT_StateObjectType type, const uint64_t id[2],
                      void* outBuffer, unsigned int outBufferSize) {
    ZTBridge* bridge = (__bridge ZTBridge*)uptr;
    NSString* path = ztStateFilePath(bridge.dataStorePath, type, id);
    if (!path) return -1;
    path = ztHookedPath(path, type);

    NSData* d = [[NSFileManager defaultManager] contentsAtPath:path];
    if (!d || (unsigned)d.length > outBufferSize) return -1;
    memcpy(outBuffer, d.bytes, d.length);
    return (int)d.length;
}

static int ztWirePacketSend(ZT_Node* node, void* uptr, void* tptr, int64_t localSocket,
                            const struct sockaddr_storage* remoteAddress,
                            const void* packetData, unsigned int packetLength, unsigned int ttl) {
    ZTBridge* bridge = (__bridge ZTBridge*)uptr;
    if (!bridge.onSendPacket) return -1;
    NSData* data = [NSData dataWithBytes:packetData length:packetLength];
    NSData* addr = [NSData dataWithBytes:remoteAddress length:sizeof(struct sockaddr_storage)];
    return bridge.onSendPacket(data, addr);
}

static void ztVirtualNetworkFrame(ZT_Node* node, void* uptr, void* tptr, uint64_t nwid,
                                  void** nuptr, uint64_t srcMac, uint64_t dstMac,
                                  unsigned int etherType, unsigned int vlanId,
                                  const void* frameData, unsigned int frameLength) {
    ZTBridge* bridge = (__bridge ZTBridge*)uptr;
    if (!bridge.onFrame) return;
    NSData* frame = [NSData dataWithBytes:frameData length:frameLength];
    uint32_t et = etherType, vl = vlanId;
    uint64_t sm = srcMac, dm = dstMac, nw = nwid;
    dispatch_async(bridge.callbackQueue, ^{
        if (bridge.onFrame) bridge.onFrame(nw, sm, dm, et, vl, frame);
    });
}

static ZTNetworkConfigData* ztConvertNetworkConfig(const ZT_VirtualNetworkConfig* cfg) {
    ZTNetworkConfigData* d = [[ZTNetworkConfigData alloc] init];
    d.nwid = cfg->nwid;
    d.name = [NSString stringWithUTF8String:cfg->name ? cfg->name : ""];
    d.status = (int32_t)cfg->status;
    d.type = (int32_t)cfg->type;
    d.mac = cfg->mac;
    d.mtu = cfg->mtu;
    d.broadcastEnabled = cfg->broadcastEnabled != 0;
    d.bridge = cfg->bridge != 0;

    NSMutableArray* addrs = [NSMutableArray array];
    for (unsigned int i = 0; i < cfg->assignedAddressCount; ++i) {
        NSString* s = ztInetAddrToString(&cfg->assignedAddresses[i]);
        if (s.length) [addrs addObject:s];
    }
    d.assignedAddrs = addrs;

    NSMutableArray* routes = [NSMutableArray array];
    for (unsigned int i = 0; i < cfg->routeCount; ++i) {
        const ZT_VirtualNetworkRoute* r = &cfg->routes[i];
        NSString* target = ztInetAddrToString(&r->target);
        if (!target.length) continue;
        NSString* via = ztInetIPToString(&r->via);
        if (via.length) {
            [routes addObject:[NSString stringWithFormat:@"%@ via %@", target, via]];
        } else {
            [routes addObject:target];
        }
    }
    d.routes = routes;

    // DNS：ZT_VirtualNetworkDNS.server_addr，空 family 结束
    NSMutableArray* dns = [NSMutableArray array];
    for (unsigned int i = 0; i < ZT_MAX_DNS_SERVERS; ++i) {
        const struct sockaddr_storage* s = &cfg->dns.server_addr[i];
        if (s->ss_family != AF_INET && s->ss_family != AF_INET6) break;
        // DNS server 地址的 port 字段无意义，直接取 IP
        char buf[INET6_ADDRSTRLEN] = {0};
        if (s->ss_family == AF_INET) {
            const struct sockaddr_in* sa4 = (const struct sockaddr_in*)s;
            if (inet_ntop(AF_INET, &sa4->sin_addr, buf, sizeof(buf)))
                [dns addObject:[NSString stringWithUTF8String:buf]];
        } else {
            const struct sockaddr_in6* sa6 = (const struct sockaddr_in6*)s;
            if (inet_ntop(AF_INET6, &sa6->sin6_addr, buf, sizeof(buf)))
                [dns addObject:[NSString stringWithUTF8String:buf]];
        }
    }
    d.dns = dns;
    return d;
}

static int ztVirtualNetworkConfig(ZT_Node* node, void* uptr, void* tptr, uint64_t nwid,
                                  void** nuptr, enum ZT_VirtualNetworkConfigOperation op,
                                  const ZT_VirtualNetworkConfig* cfg) {
    ZTBridge* bridge = (__bridge ZTBridge*)uptr;
    ZTNetworkConfigData* d = ztConvertNetworkConfig(cfg);
    dispatch_async(bridge.callbackQueue, ^{
        if (bridge.onNetworkConfig) bridge.onNetworkConfig(nwid, (int32_t)op, d);
    });
    return 0; // 0 = 成功；非 0 会使网络进入 PORT_ERROR
}

static void ztEvent(ZT_Node* node, void* uptr, void* tptr, enum ZT_Event event, const void* meta) {
    ZTBridge* bridge = (__bridge ZTBridge*)uptr;
    NSString* name = nil;
    uint64_t nwid = 0;
    switch (event) {
        case ZT_EVENT_UP:                 name = @"UP"; break;
        case ZT_EVENT_ONLINE:             name = @"ONLINE"; break;
        case ZT_EVENT_OFFLINE:            name = @"OFFLINE"; break;
        case ZT_EVENT_DOWN:               name = @"DOWN"; break;
        case ZT_EVENT_FATAL_ERROR_IDENTITY_COLLISION: name = @"FATAL_ERROR_IDENTITY_COLLISION"; break;
        case ZT_EVENT_TRACE:              name = @"TRACE"; break;
        case ZT_EVENT_USER_MESSAGE:       name = @"USER_MESSAGE"; break;
        case ZT_EVENT_REMOTE_TRACE:       name = @"REMOTE_TRACE"; break;
        default:                          name = @"UNKNOWN"; break;
    }
    // 网络相关事件 meta 为 nwid（1.16 事件枚举已不再细分 NETWORK_*，预留）
    if (meta) {
        // 仅 USER_MESSAGE/REMOTE_TRACE 等 payload 不是 nwid 的事件保持 0
    }
    dispatch_async(bridge.callbackQueue, ^{
        if (bridge.onEvent) bridge.onEvent(name, nwid);
    });
}

// MARK: - ZTBridge 实现

@implementation ZTBridge {
}

+ (NSString*)coreVersion {
    return [NSString stringWithFormat:@"%d.%d.%d",
        ZEROTIER_ONE_VERSION_MAJOR, ZEROTIER_ONE_VERSION_MINOR, ZEROTIER_ONE_VERSION_REVISION];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _callbackQueue = dispatch_queue_create("zt.callback", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)startWithDataStorePath:(NSString*)path {
    self.dataStorePath = path;
    // 建 moons.d / peers.d / networks.d 目录
    for (NSString* sub in @[@"moons.d", @"peers.d", @"networks.d"]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByAppendingPathComponent:sub]
                                  withIntermediateDirectories:YES attributes:nil error:nil];
    }

    ZT_Node_Callbacks cbs = {};
    cbs.version = 0;
    cbs.statePutFunction = &ztStatePut;
    cbs.stateGetFunction = &ztStateGet;
    cbs.wirePacketSendFunction = &ztWirePacketSend;
    cbs.virtualNetworkFrameFunction = &ztVirtualNetworkFrame;
    cbs.virtualNetworkConfigFunction = &ztVirtualNetworkConfig;
    cbs.eventCallback = &ztEvent;

    ZT_Node_Config cfg = {}; // enableEncryptedHello=0, lowBandwidthMode=0

    enum ZT_ResultCode rc = ZT_Node_new(&_node, &cfg, (__bridge void*)self, NULL, &cbs, ztNowMillis());
    if (rc != ZT_RESULT_OK) {
        _node = NULL;
        return NO;
    }
    int64_t deadline = 0;
    ZT_Node_processBackgroundTasks(_node, NULL, ztNowMillis(), &deadline);
    return YES;
}

- (void)shutdown {
    if (_node) {
        ZT_Node_delete(_node);
        _node = NULL;
    }
}

- (BOOL)isRunning {
    return _node != NULL;
}

- (int32_t)join:(uint64_t)nwid {
    if (!_node) return ZT_RESULT_FATAL_ERROR_INTERNAL;
    return ZT_Node_join(_node, nwid, NULL, NULL);
}

- (int32_t)leave:(uint64_t)nwid {
    if (!_node) return ZT_RESULT_FATAL_ERROR_INTERNAL;
    void* uptr = NULL;
    return ZT_Node_leave(_node, nwid, &uptr, NULL);
}

- (int32_t)orbit:(uint64_t)worldId seed:(uint64_t)seed {
    if (!_node) return ZT_RESULT_FATAL_ERROR_INTERNAL;
    return ZT_Node_orbit(_node, NULL, worldId, seed);
}

- (int32_t)deorbit:(uint64_t)worldId {
    if (!_node) return ZT_RESULT_FATAL_ERROR_INTERNAL;
    return ZT_Node_deorbit(_node, NULL, worldId);
}

- (uint64_t)nodeAddress {
    if (!_node) return 0;
    return ZT_Node_address(_node);
}

- (nullable ZTNodeStatusData*)nodeStatus {
    if (!_node) return nil;
    ZT_NodeStatus st;
    ZT_Node_status(_node, &st);
    ZTNodeStatusData* d = [[ZTNodeStatusData alloc] init];
    d.address = st.address;
    d.publicIdentity = [NSString stringWithUTF8String:st.publicIdentity ? st.publicIdentity : ""];
    d.online = st.online != 0;
    return d;
}

- (NSArray<ZTPeerData*>*)peers {
    if (!_node) return @[];
    ZT_PeerList* list = ZT_Node_peers(_node);
    if (!list) return @[];
    NSMutableArray* out = [NSMutableArray arrayWithCapacity:list->peerCount];
    for (unsigned long i = 0; i < list->peerCount; ++i) {
        const ZT_Peer* p = &list->peers[i];
        ZTPeerData* d = [[ZTPeerData alloc] init];
        d.address = p->address;
        d.role = (int32_t)p->role;
        d.latency = p->latency;
        d.version = [NSString stringWithFormat:@"%d.%d.%d", p->versionMajor, p->versionMinor, p->versionRev];
        // 优选物理路径：取第一条有效 path（显示优选路径）
        d.path = @"";
        for (unsigned int j = 0; j < p->pathCount; ++j) {
            NSString* s = ztSockAddrToString(&p->paths[j].address);
            if (s.length) { d.path = s; break; }
        }
        [out addObject:d];
    }
    ZT_Node_freeQueryResult(_node, list);
    return out;
}

- (nullable ZTNetworkConfigData*)networkConfig:(uint64_t)nwid {
    if (!_node) return nil;
    ZT_VirtualNetworkConfig* cfg = ZT_Node_networkConfig(_node, nwid);
    if (!cfg) return nil;
    ZTNetworkConfigData* d = ztConvertNetworkConfig(cfg);
    ZT_Node_freeQueryResult(_node, cfg);
    return d;
}

- (int32_t)processWirePacket:(NSData*)data remoteAddr:(NSData*)remoteAddr {
    if (!_node || data.length == 0 || remoteAddr.length < sizeof(struct sockaddr_storage)) {
        return ZT_RESULT_FATAL_ERROR_INTERNAL;
    }
    int64_t deadline = 0;
    return ZT_Node_processWirePacket(_node, NULL, ztNowMillis(), -1,
        (const struct sockaddr_storage*)remoteAddr.bytes, data.bytes,
        (unsigned int)data.length, &deadline);
}

- (int32_t)processVirtualNetworkFrame:(uint64_t)nwid srcMac:(uint64_t)srcMac dstMac:(uint64_t)dstMac
                             etherType:(uint32_t)etherType vlanId:(uint32_t)vlanId frame:(NSData*)frame {
    if (!_node || frame.length == 0) return ZT_RESULT_FATAL_ERROR_INTERNAL;
    int64_t deadline = 0;
    return ZT_Node_processVirtualNetworkFrame(_node, NULL, ztNowMillis(), nwid,
        srcMac, dstMac, etherType, vlanId, frame.bytes, (unsigned int)frame.length, &deadline);
}

- (int32_t)multicastSubscribe:(uint64_t)nwid group:(uint64_t)group adi:(uint64_t)adi {
    if (!_node) return ZT_RESULT_FATAL_ERROR_INTERNAL;
    return ZT_Node_multicastSubscribe(_node, NULL, nwid, group, (unsigned long)adi);
}

- (int64_t)processBackgroundTasks {
    if (!_node) return 0;
    int64_t deadline = 0;
    enum ZT_ResultCode rc = ZT_Node_processBackgroundTasks(_node, NULL, ztNowMillis(), &deadline);
    if (rc != ZT_RESULT_OK) return 0;
    return deadline;
}

@end
