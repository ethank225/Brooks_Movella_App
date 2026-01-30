//
//  DotConnectionManager.h
//  DotSdk
//
//  Created by Nick Yang on 2019/5/15.
//  Copyright © 2023 Movella. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "DotDevice.h"
#import "DotDefine.h"

/**
 *  The protocol of DotConnectionManager.
 *  You can use these methods to get all the scanning and connection status.
 */
@protocol DotConnectionDelegate <NSObject>
@optional
/**
 *  Bluetooth state changed
 *  @param managerState The XSDotManagerState state
 */
- (void)onManagerStateUpdate:(XSDotManagerState)managerState;

/**
 *  Scan completed.
 */
- (void)onScanCompleted;

/**
 *  Disconver a Xsend DOT  sensor when start scan.
 *  @param device The DotDevice object
 */
- (void)onDiscoverDevice:(DotDevice *_Nonnull)device;

/**
 *  Sensor connect succeeded
 *  @param device The DotDevice object
 */

- (void)onDeviceConnectSucceeded:(DotDevice *_Nonnull)device;
/**
 *  Sensor connect failed
 *  @param device The DotDevice object
 */

- (void)onDeviceConnectFailed:(DotDevice *_Nonnull)device;
/**
 *  Sensor disconnected
 *  @param device The DotDevice object
 */
- (void)onDeviceDisconnected:(DotDevice *_Nonnull)device;
@end


NS_ASSUME_NONNULL_BEGIN

/**
 *  This class manages the BLE connection of Movella DOT sensors.
 */
@interface DotConnectionManager : NSObject

/**
 *  Set the delegate
 *  @param delegate The DotConnectionDelegate object
 */
+ (void)setConnectionDelegate:(nullable id<DotConnectionDelegate>)delegate;

/**
 *  The current bluetooth state of phone
 *  @return The XSDotManagerState object
 */
+ (XSDotManagerState)managerState;

/**
 *  Phone Bluetooth is on
 *  @return The bluetooth state is power on
 */
+ (BOOL)managerStateIsPoweredOn;

/**
 *  Scan Movella DOT sensors
 */
+ (void)scan;

/**
 *  Stop scan Movella DOT sensors
 */
+ (void)stopScan;

/**
 *  Connect Movella DOT sensor
 *  @param device The DotDevice object
 */
+ (void)connect:(DotDevice *)device;

/**
 *  Disconnect a Movella DOT sensor
 *  @param device The DotDevice object
 */
+ (void)disconnect:(DotDevice *)device;

@end

NS_ASSUME_NONNULL_END
