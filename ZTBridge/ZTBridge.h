#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ZTNodeStatusData : NSObject
@property (nonatomic, assign) uint64_t address;
@property (nonatomic, copy) NSString* publicIdentity;
@property (nonatomic, assign) BOOL online;
@end

@interface ZTPeerData : NSObject
@property (nonatomic, assign) uint64_t address;
@property (nonatomic, assign) int32_t role;       // ZT_PeerRole: 0 leaf / 1 moon / 2 planet
@property (nonatomic, copy) NSString* version;
@property (nonatomic, assign) int32_t latency;    // ms，-1 未知
@property (nonatomic, copy) NSString* path;       // 优选物理路径 "ip:port"，空为 relay
@end

@interface ZTNetworkConfigData : NSObject
@property (nonatomic, assign) uint64_t nwid;
@property (nonatomic, copy) NSString* name;
@property (nonatomic, assign) int32_t status;     // ZT_VirtualNetworkStatus
@property (nonatomic, assign) int32_t type;       // ZT_VirtualNetworkType
@property (nonatomic, assign) uint64_t mac;
@property (nonatomic, assign) uint32_t mtu;
@property (nonatomic, assign) BOOL broadcastEnabled;
@property (nonatomic, assign) BOOL bridge;
@property (nonatomic, copy) NSArray<NSString*>* assignedAddrs; // "ip/prefix"
@property (nonatomic, copy) NSArray<NSString*>* routes;        // "dest/prefix" 或 "dest/prefix via gw"
@property (nonatomic, copy) NSArray<NSString*>* dns;          // server ip（不含端口）
@end

/// ZeroTier C 核心的 OC++ 薄包装。
/// 回调统一 hop 到内部串行队列后再调 Swift 闭包（对应 Android JNIEnvGuard 的线程安全处理）。
@interface ZTBridge : NSObject

@property (nonatomic, copy, nullable) void (^onEvent)(NSString* event, uint64_t nwid);
/// 帧数据不含以太网头（C API 语义：MAC/ethertype/vlanId 独立传参）
@property (nonatomic, copy, nullable) void (^onFrame)(uint64_t nwid, uint64_t srcMac, uint64_t dstMac,
                                                      uint32_t etherType, uint32_t vlanId, NSData* frame);
@property (nonatomic, copy, nullable) void (^onNetworkConfig)(uint64_t nwid, int32_t op, ZTNetworkConfigData* cfg);
/// 参数1=包数据，参数2=序列化的 sockaddr_storage；返回 sendto 结果（0 成功）
@property (nonatomic, copy, nullable) int32_t (^onSendPacket)(NSData* data, NSData* remoteAddr);

/// 核心编译版本（ZEROTIER_ONE_VERSION_* 宏）
+ (NSString*)coreVersion;

/// 启动核心；dataStorePath 为状态文件根目录（App Group datastore/）
- (BOOL)startWithDataStorePath:(NSString*)path;
- (void)shutdown;
- (BOOL)isRunning;

- (int32_t)join:(uint64_t)nwid;
- (int32_t)leave:(uint64_t)nwid;
- (int32_t)orbit:(uint64_t)worldId seed:(uint64_t)seed;
- (int32_t)deorbit:(uint64_t)worldId;
- (uint64_t)nodeAddress;
- (nullable ZTNodeStatusData*)nodeStatus;
- (NSArray<ZTPeerData*>*)peers;
- (nullable ZTNetworkConfigData*)networkConfig:(uint64_t)nwid;
- (int32_t)processWirePacket:(NSData*)data remoteAddr:(NSData*)remoteAddr;
/// 帧数据不含以太网头；MAC/ethertype/vlanId 独立传参（C API 语义）
- (int32_t)processVirtualNetworkFrame:(uint64_t)nwid srcMac:(uint64_t)srcMac dstMac:(uint64_t)dstMac
                             etherType:(uint32_t)etherType vlanId:(uint32_t)vlanId frame:(NSData*)frame;
- (int32_t)multicastSubscribe:(uint64_t)nwid group:(uint64_t)group adi:(uint64_t)adi;
/// 驱动一次后台任务，返回下一次 deadline（ms epoch）；失败返回 0
- (int64_t)processBackgroundTasks;

@end

NS_ASSUME_NONNULL_END
