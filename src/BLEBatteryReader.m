// BLEBatteryReader.m — reads GATT Battery Service (0x180F / 0x2A19) for Professor 1.
#import "BLEBatteryReader.h"

@interface BLEBatteryReader () <CBCentralManagerDelegate, CBPeripheralDelegate>
@property (nonatomic, strong) CBCentralManager *central;
@property (nonatomic, strong) CBPeripheral *targetPeripheral;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic) int batteryPercent;
@end

@implementation BLEBatteryReader

- (instancetype)init {
    self = [super init];
    if (self) {
        _batteryPercent = -1;
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (void)start {
    if (!self.central) {
        self.central = [[CBCentralManager alloc] initWithDelegate:self queue:dispatch_get_main_queue()];
    }
    if (!self.pollTimer) {
        // Poll every 30 seconds to refresh battery level if not pushed via notify
        self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:30.0
                                                          target:self
                                                        selector:@selector(pollTick:)
                                                        userInfo:nil
                                                         repeats:YES];
    }
}

- (void)stop {
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    if (self.targetPeripheral && self.central) {
        [self.central cancelPeripheralConnection:self.targetPeripheral];
    }
    self.targetPeripheral = nil;
    self.batteryPercent = -1;
}

- (void)refresh {
    [self checkConnectedPeripherals];
}

- (void)pollTick:(NSTimer *)timer {
    (void)timer;
    [self checkConnectedPeripherals];
}

- (void)checkConnectedPeripherals {
    if (self.central.state != CBManagerStatePoweredOn) return;
    CBUUID *hidUUID = [CBUUID UUIDWithString:@"1812"];
    CBUUID *battUUID = [CBUUID UUIDWithString:@"180F"];
    NSArray *connected = [self.central retrieveConnectedPeripheralsWithServices:@[hidUUID, battUUID]];
    for (CBPeripheral *p in connected) {
        if ([p.name containsString:@"Professor"]) {
            self.targetPeripheral = p;
            p.delegate = self;
            if (p.state != CBPeripheralStateConnected) {
                [self.central connectPeripheral:p options:nil];
            } else {
                [p discoverServices:@[battUUID]];
            }
            return;
        }
    }
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    if (central.state == CBManagerStatePoweredOn) {
        [self checkConnectedPeripherals];
    } else {
        self.batteryPercent = -1;
        if (self.batteryUpdateHandler) self.batteryUpdateHandler(-1);
    }
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    [peripheral discoverServices:@[[CBUUID UUIDWithString:@"180F"]]];
}

- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    if (peripheral == self.targetPeripheral) {
        self.batteryPercent = -1;
        if (self.batteryUpdateHandler) self.batteryUpdateHandler(-1);
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if (error) return;
    for (CBService *s in peripheral.services) {
        if ([s.UUID.UUIDString isEqualToString:@"180F"]) {
            [peripheral discoverCharacteristics:@[[CBUUID UUIDWithString:@"2A19"]] forService:s];
        }
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    if (error) return;
    for (CBCharacteristic *c in service.characteristics) {
        if ([c.UUID.UUIDString isEqualToString:@"2A19"]) {
            [peripheral readValueForCharacteristic:c];
            if (c.properties & CBCharacteristicPropertyNotify) {
                [peripheral setNotifyValue:YES forCharacteristic:c];
            }
        }
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (error) return;
    if ([characteristic.UUID.UUIDString isEqualToString:@"2A19"] && characteristic.value.length > 0) {
        uint8_t batt = ((const uint8_t *)characteristic.value.bytes)[0];
        if (batt <= 100) {
            self.batteryPercent = (int)batt;
            if (self.batteryUpdateHandler) {
                self.batteryUpdateHandler((int)batt);
            }
        }
    }
}

@end
