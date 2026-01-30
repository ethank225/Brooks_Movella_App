//
//  DotDevicePool.h
//  DotSdk
//
//  Created by Nick Yang on 2019/6/18.
//  Copyright © 2023 Movella. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "DotDevice.h"

NS_ASSUME_NONNULL_BEGIN

extern NSInteger const XSDotDevicePoolCapacityMax;

/**
 *  This class manages the reconnection behavior of sensors. When reconnection is enabled,
 *  you need to bind the sensor to activate the reconnection function after connecting a sensor.
 *  Unbind it after disconnecting the sensor, otherwise a reconnection will be initialized.
 */
@interface DotDevicePool : NSObject
/**
 * Inquire sensor with peripheral to check if it is in the connection  pool.
 * @param peripheral the CBPeripheral object
 */
+ (DotDevice *)inquireDeviceWithPeripheral:(CBPeripheral *)peripheral;

/**
 * Add sensors to the bound device pool
 * @param devices The DotDevice  array
 */
+ (void)bindDevices:(NSArray <DotDevice *>*)devices;

/**
 * Add a sensor to the bound device pool
 * @param device The DotDevice object
 */
+ (BOOL)bindDevice:(DotDevice *)device;

/**
 * Remove sensor from the bound device pool
 * @param device The DotDevice object
 */
+ (void)unbindDevice:(DotDevice *)device;

/**
 * Remove all sensors from the bound device pool
 */
+ (void)unbindAllDevices;

/**
 * Get all bound sensors
 * @return All bound sensors array
 */
+ (NSArray <DotDevice *>*)allBoundDevices;

/**
 * Get the ota sensors , after the sensor just done ota ,this will be return.
 * @return The ota devices array
 */
+ (NSArray <DotDevice *>*)allOtaDevices;

/**
 * Add a ota sensor to ota device array
 * @param device The ota object
 */
+ (void)addOtaDevice:(DotDevice *)device;
@end


@interface DotDevicePool (Connection)

/**
 *  Check the sensor if it is in the connected device pool. The connected device pool is a array that sensor has been connected .
 *  @param peripheral The CBPeripheral object
 */
+ (DotDevice *)heldDeviceWithPeripheral:(CBPeripheral *)peripheral;

/**
 *  Add a sensor to connected device pool, Prevent the same sensor from connecting multiple times
 *  @param device The DotDevice object
 */
+ (void)holdDevice:(DotDevice *)device;

/**
 *  Release a sensor from connected device list, if a sensor has disconnected ,we must release it.
 *  @param device The DotDevice object
 */
+ (void)releaseDevice:(DotDevice *)device;

/**
 *  The bluetooth state of phone updated (Turn on or turn off bluetooth)
 */
+ (void)onCentralStateUpdated;
@end

NS_ASSUME_NONNULL_END
