//
//  LANScanner.m
//
//  Created by Michalis Mavris on 05/08/16.
//  Copyright © 2016 Miksoft. All rights reserved.
//

#import "LANProperties.h"
#import "PingOperation.h"
#import "MMLANScanner.h"
#import "MACOperation.h"
#import "MacFinder.h"
#import "Device.h"

@interface MMLANScanner ()
@property (nonatomic,strong) Device *device;
@property (nonatomic,strong) NSArray *ipsToPing;
@property (nonatomic,assign) float currentHost;
@property (nonatomic,strong) NSDictionary *brandDictionary;
@property (nonatomic,strong) NSOperationQueue *pingQueue;
@property (nonatomic,strong) NSOperationQueue *macQueue;
@property(nonatomic,assign,readwrite)BOOL isScanning;
@end

@implementation MMLANScanner {
    BOOL isFinished;
    BOOL isCancelled;
    
    
    NSNetServiceBrowser *_serviceBrowser;
    NSMutableArray<NSString *> * _serviceNames;
    NSMutableArray<Device *> * _devices;
    NSMutableArray<Device *> *_appledevs;
    NSLock *_appleDevsLock;
    NSRecursiveLock *_rsLock;
}

#pragma mark - Initialization method
-(instancetype)initWithDelegate:(id<MMLANScannerDelegate>)delegate {

    self = [super init];
    
    if (self) {
        //Setting the delegate
        self.delegate=delegate;
        
        //Initializing the dictionary that holds the Brands name for each MAC Address
        self.brandDictionary = [NSDictionary dictionaryWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"data" ofType:@"plist"]];
        
        //Initializing the NSOperationQueue
        self.pingQueue = [[NSOperationQueue alloc] init];
        self.macQueue = [[NSOperationQueue alloc] init];
        //Setting the concurrent operations to 25
        [self.pingQueue setMaxConcurrentOperationCount:25];
        [self.macQueue setMaxConcurrentOperationCount:25];
        [self.pingQueue setQualityOfService:NSQualityOfServiceUtility];
        [self.macQueue setQualityOfService:NSQualityOfServiceUtility];
        
        //Add observer to notify the delegate when queue is empty.
        [self.pingQueue addObserver:self forKeyPath:@"operations" options:0 context:nil];
        [self.macQueue addObserver:self forKeyPath:@"operations" options:0 context:nil];

        isFinished = NO;
        isCancelled = NO;
        self.isScanning = NO;
        
        _devices = [[NSMutableArray alloc] init];
        _serviceNames = [[NSMutableArray alloc] init];
        _appledevs = [[NSMutableArray alloc] init];
        _appleDevsLock = [[NSLock alloc] init];
        _rsLock = [[NSRecursiveLock alloc] init];

    }
    
    return self;
}

#pragma mark - Start/Stop ping
-(void)start {
    
    //In case the developer call start when is already running
    if (self.pingQueue.operationCount!=0 || self.macQueue.operationCount!=0) {
        [self stop];
    }

    isFinished = NO;
    isCancelled = NO;
    self.isScanning = YES;

    //Getting the local IP
    self.device = [LANProperties localIPAddress];
    
    //If IP is null then return
    if (!self.device) {
        [self.delegate lanScanDidFailedToScan];
        return;
    }
    
    [_appleDevsLock lock];
    [_devices removeAllObjects];
    [_serviceNames removeAllObjects];
    [_appledevs removeAllObjects];
    [_appleDevsLock unlock];
    
    //Getting the available IPs to ping based on our network subnet.
    self.ipsToPing = [LANProperties getAllHostsForIP:self.device.ipAddress andSubnet:self.device.subnetMask];

    //The counter of how much pings have been made
    self.currentHost=0;

    //Making a weak reference to self in order to use it from the completionBlocks in operation.
    MMLANScanner * __weak weakSelf = self;
    
    //Looping through IPs array and adding the operations to the queue
    for (NSString *ipStr in self.ipsToPing) {
        
        //The ping operation
        PingOperation *pingOperation = [[PingOperation alloc]initWithIPToPing:ipStr andCompletionHandler:^(NSError  * _Nullable error, NSString  * _Nonnull ip) {
            if (!weakSelf) {
                return;
            }
            //Since the first half of the operation is completed we will update our proggress by 0.5
            weakSelf.currentHost = weakSelf.currentHost + 0.5;
            
        }];
        
        //The Find MAC Address for each operation
        MACOperation *macOperation = [[MACOperation alloc] initWithIPToRetrieveMAC:ipStr andBrandDictionary:self.brandDictionary andCompletionHandler:^(NSError * _Nullable error, NSString * _Nonnull ip, Device * _Nonnull device) {
            
            if (!weakSelf) {
                return;
            }

            //Since the second half of the operation is completed we will update our proggress by 0.5
            weakSelf.currentHost = weakSelf.currentHost + 0.5;
            
            if (!error) {
                
                //Letting know the delegate that found a new device (on Main Thread)
                dispatch_async (dispatch_get_main_queue(), ^{
                    if ([weakSelf.delegate respondsToSelector:@selector(lanScanDidFindNewDevice:)]) {
                        [weakSelf.delegate lanScanDidFindNewDevice:device];
                        [_appleDevsLock lock];
                        [_devices addObject:device];
                        [_appleDevsLock unlock];
                    }
                });
            }
            
            //Letting now the delegate the process  (on Main Thread)
            dispatch_async (dispatch_get_main_queue(), ^{
                if ([weakSelf.delegate respondsToSelector:@selector(lanScanProgressPinged:from:)]) {
                    [weakSelf.delegate lanScanProgressPinged:self.currentHost from:[self.ipsToPing count]];
                }
            });
        }];
        
        [macOperation addDependency:pingOperation];
        [self.macQueue addOperation:macOperation];
        [self.pingQueue addOperation:pingOperation];
    }
    
    _serviceBrowser = [[NSNetServiceBrowser alloc] init];
    _serviceBrowser.delegate = self;
    [_serviceBrowser searchForServicesOfType:@"_services._dns-sd._udp." inDomain:@"local."];
}

-(void)stop {
    
    isCancelled = YES;
    [self.pingQueue cancelAllOperations];
    [self.pingQueue waitUntilAllOperationsAreFinished];
    [self.macQueue cancelAllOperations];
    [self.macQueue waitUntilAllOperationsAreFinished];
    self.isScanning = NO;
    [_serviceBrowser stop];
}

- (NSString *)_serviceIdentifier:(NSNetService *)service {
    NSString *name = service.name;
    NSString *type = service.type;
    
    if ([type hasSuffix:@"local."]) {
        type = [type substringToIndex:type.length - @"local.".length];
    }
    
    return [NSString stringWithFormat:@"%@.%@", name, type];
}

#pragma mark - Net service delegate

- (void)netServiceWillResolve:(NSNetService *)sender {
    //NSLog(@"netServiceWillResolve NSNetService = %@", sender.name);
}

- (void)netServiceDidResolveAddress:(NSNetService *)sender {
    NSString *ip = [self _ipAddress:sender.addresses[0]];
    NSLog(@"netServiceDidResolveAddress Host:IP %@:%@", sender.hostName, ip);
    
    Device* device = [[Device alloc] init];
    device.ipAddress = ip;
    device.hostname = [sender.hostName stringByReplacingOccurrencesOfString:@".local." withString:@""];
    //NSLog(@"_appledevs = %@", _appledevs);
    [_appleDevsLock lock];
    [_appledevs addObject:device];

    for (Device * appledev in _appledevs) {
        for (Device * dev in _devices) {
            if([dev.ipAddress isEqualToString:appledev.ipAddress]) {
                dev.hostname = appledev.hostname;
                [self.delegate lanScanDidUpdateDevice:dev];
                break;
            }
        }
    }
    [_appleDevsLock unlock];
}

- (void)netService:(NSNetService *)sender didNotResolve:(NSDictionary<NSString *, NSNumber *> *)errorDict {
    //NSLog(@"didNotResolve NSNetService = %@, errorDict = %@", sender.name, errorDict);
}


#pragma mark - Private methods

- (NSString *)_ipAddress:(NSData *)addrData {
    struct sockaddr *addr = (struct sockaddr *)addrData.bytes;
    char *s = NULL;
    NSString *ipAddress = nil;
    
    switch(addr->sa_family) {
        case AF_INET: {
            struct sockaddr_in *addr_in = (struct sockaddr_in *)addr;
            s = malloc(INET_ADDRSTRLEN);
            inet_ntop(AF_INET, &(addr_in->sin_addr), s, INET_ADDRSTRLEN);
            break;
        }
        case AF_INET6: {
            struct sockaddr_in6 *addr_in6 = (struct sockaddr_in6 *)addr;
            s = malloc(INET6_ADDRSTRLEN);
            inet_ntop(AF_INET6, &(addr_in6->sin6_addr), s, INET6_ADDRSTRLEN);
            break;
        }
        default:
            break;
    }
    
    if (s) {
        ipAddress = [NSString stringWithUTF8String:s];
        free(s);
    }
    
    return ipAddress;
}

#pragma mark - NSNetServiceBrowserDelegate

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didFindService:(NSNetService *)service moreComing:(BOOL)moreComing {
    //NSLog(@"didFindService name = %@, domain = %@, type = %@", service.name, service.domain, service.type);
    NSArray * serviceTypes = [[NSArray alloc] initWithObjects: @"_apple-mobdev2._tcp.", @"_smb._tcp.", @"_workstation._tcp.", @"_printer._tcp.", @"_ssh._tcp.", nil];
    
    if([@"." isEqualToString:service.domain]) {
        dispatch_async (dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            
            NSString *serviceType = [self _serviceIdentifier:service];
            if([serviceTypes containsObject:serviceType])
            {
                NSLog(@"serviceType = %@", serviceType);
                NSNetServiceBrowser *serviceBrowser = [[NSNetServiceBrowser alloc] init];
                serviceBrowser.delegate = self;
                [serviceBrowser scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
                [serviceBrowser searchForServicesOfType: serviceType inDomain:@"local."];
                [[NSThread currentThread] setQualityOfService:NSQualityOfServiceDefault];
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:5]];
            }
        });
        
    } else if([@"local." isEqualToString:service.domain]) {
        if(service.addresses.count > 0) {
            [self netServiceDidResolveAddress: service];
        } else {
            [_rsLock lock];
            if (![_serviceNames containsObject: service.name])
            {
                [_serviceNames addObject:service.name];
                [_rsLock unlock];

                [service scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
                [service setDelegate: self];
                [service resolveWithTimeout: 0];
                [[NSThread currentThread] setQualityOfService:NSQualityOfServiceDefault];
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:2]];
            } else {
                [_rsLock unlock];
            }
        }
    }
}

#pragma mark - NSOperationQueue Observer
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
   
    //Observing the NSOperationQueue and as soon as it finished we send a message to delegate
    if ([keyPath isEqualToString:@"operations"]) {
        
        if (self.pingQueue.operationCount == 0 && self.macQueue.operationCount == 0 && isFinished == NO) {
            
            [_appleDevsLock lock];
            for (Device * appledev in _appledevs) {
                for (Device * dev in _devices) {
                    if([dev.ipAddress isEqualToString:appledev.ipAddress]) {
                        dev.hostname = appledev.hostname;
                        [self.delegate lanScanDidUpdateDevice:dev];
                        break;
                    }
                }
            }
            [_appleDevsLock unlock];
            
            isFinished=YES;
            self.isScanning = NO;
            //Checks if is cancelled to sent the appropriate message to delegate
            MMLanScannerStatus currentStatus = isCancelled ? MMLanScannerStatusCancelled : MMLanScannerStatusFinished;
            
            //Letting know the delegate that the request is finished
            dispatch_async (dispatch_get_main_queue(), ^{
                if ([self.delegate respondsToSelector:@selector(lanScanDidFinishScanningWithStatus:)]) {
                    [self.delegate lanScanDidFinishScanningWithStatus:currentStatus];
                }
            });
        }
    }
}
#pragma mark - Dealloc
-(void)dealloc {
    //Removing the observer on dealloc
    [self.pingQueue removeObserver:self forKeyPath:@"operations"];
    [self.macQueue removeObserver:self forKeyPath:@"operations"];
}
@end
