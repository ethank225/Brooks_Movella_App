//
//  DotDefine.h
//  DotSdk
//
//  Created by Nick Yang on 2019/5/13.
//  Copyright © 2023 Movella. All rights reserved.
//

#ifndef DotDefine_h
#define DotDefine_h

#import <Foundation/Foundation.h>


extern NSString * const kCBAdvDataLocalName;
extern NSString * const kCBAdvDataManufacturerData;
extern NSInteger const XSDotDevicePoolCapacityMax;
extern float const XSDotDeviceConnectDuration;
extern float const XSDotDeviceScanDuration;

/**
 *  Bluetooth state of phone
 *
 *  Equivalent to CBManagerState, CBCentralManagerState and CBPeripheralManagerState.
 *  The purpose is to solve the compatibility problem of CBCentralManager.state type in different versions of iOS.
 */
typedef NS_ENUM(NSInteger, XSDotManagerState)
{
    XSDotManagerStateUnknown      = 0,//CBManagerStateUnknown
    XSDotManagerStateResetting,       //CBManagerStateResetting
    XSDotManagerStateUnsupported,     //CBManagerStateUnsupported
    XSDotManagerStateUnauthorized,    //CBManagerStateUnauthorized
    XSDotManagerStatePoweredOff,      //CBManagerStatePoweredOff
    XSDotManagerStatePoweredOn,       //CBManagerStatePoweredOn
};

/**
 *  The sensor calibration type
 */
typedef NS_ENUM(NSInteger, XSDotDeviceCalibrationType)
{
    XSDotDeviceCalibrationType1Step   = 1,
    XSDotDeviceCalibrationType4Steps  = 4,
    XSDotDeviceCalibrationType7Steps  = 7,
    
    XSDotDeviceCalibrationTypeDefault = XSDotDeviceCalibrationType7Steps,
};

/**
 *  The MFM result type after done the mfm process.
 */
typedef NS_ENUM(NSUInteger, XSDotMFMResultTpye)
{
    XSDotMFMResultFailed = 0,
    XSDotMFMResultBad,
    XSDotMFMResultAcceptable,
    XSDotMFMResultGood,
};

/**
 *  Payload mode of Measurement
 */
typedef NS_ENUM(NSInteger,XSBleDevicePayloadMode)
{
    XSBleDevicePayloadDefault = 0,
    XSBleDevicePayloadInertialHighFidelityWithMag,
    XSBleDevicePayloadExtendedQuaternion,
    XSBleDevicePayloadCompleteQuaternion,
    XSBleDevicePayloadOrientationEuler,
    XSBleDevicePayloadOrientationQuaternion,
    XSBleDevicePayloadFreeAcceleration,
    XSBleDevicePayloadExtendedEuler, //new payload
    XSBleDevicePayloadMFM = 15,
    XSBleDevicePayloadCompleteEuler,
    XSBleDevicePayloadHighFidelityNoMag,
    XSBleDevicePayloadDeltaQuantitiesWithMag,
    XSBleDevicePayloadDeltaQuantitiesNoMag,
    XSBleDevicePayloadRateQuantitiesWithMag,
    XSBleDevicePayloadRateQuantitiesNoMag,
    XSBleDevicePayloadCustomMode1, //new payload
    XSBleDevicePayloadCustomMode2, //new payload
    XSBleDevicePayloadCustomMode3, //new payload
    XSBleDevicePayloadCustomMode4, //new payload
    XSBleDevicePayloadCustomMode5 //new payload
};

/**
 *  The data of exporting recording data from recording file
 *  @see DotDevice.exportDataFormat
 */
typedef NS_ENUM(NSUInteger, XSRecordingData)
{
    XSRecordingDataTimestamp = 0x00,
    XSRecordingDataQuaternion,
    XSRecordingDataIq,
    XSRecordingDataIv, // 0x03
    XSRecordingDataEulerAngles,
    XSRecordingDataDq,
    XSRecordingDataDv,
    XSRecordingDataAcceleration,
    XSRecordingDataAngularVelocity,
    XSRecordingDataMagneticField,
    XSRecordingDataStatus,//0x0a
    XSRecordingDataClipCountAcc,
    XSRecordingDataClipCountGyr,
};

/**
 *  Sensor heading reset status
 */
typedef NS_ENUM(NSUInteger, XSHeadingStatus)
{
    XSHeadingStatusXrmHeading = 1,
    XSHeadingStatusXrmDefaultAlignment = 7,
    XSHeadingStatusXrmNone
};

/**
 *  The BLE message ID
 */
typedef NS_ENUM(NSUInteger, DotBleMessageId)
{
    DotBleMessageRecording = 1,
    DotBleMessageSync
};

/**
 *  The BLE recording message ID
 */
typedef NS_ENUM(NSUInteger, DotBleMessageRecordingId)
{
    XSBleMessageRecordingEarseFlash = 0x30,
    XSBleMessageRecordingEraseFlashDone,
    XSBleMessageRecordingStoreFlashInfo,
    XSBleMessageRecordingStoreFlashInfoDone,
    XSBleMessageRecordingFlashFull,
    XSBleMessageRecordingInvalidFlashFormat,
    
    XSBleMessageRecordingStartRecording = 0x40,
    XSBleMessageRecordingStopRecording,
    XSBleMessageRecordingGetRecordingTime,
    XSBleMessageRecordingRecordingTime,
    
    XSBleMessageRecordingGetFlashInfo = 0x50,
    XSBleMessageRecordingFlashInfo,
    XSBleMessageRecordingFlashInfoDone,
    
    XSBleMessageRecordingGetExportFileInfo = 0x60,
    XSBleMessageRecordingExportFileInfo,
    XSBleMessageRecordingExportFileInfoDone,
    XSBleMessageRecordingExportNoFile,
    
    XSBleMessageRecordingGetExportFileData = 0x70,
    XSBleMessageRecordingExportFileData,
    XSBleMessageRecordingExportFileDataDone,
    XSBleMessageRecordingStopExportFileData
};

/**
 *  The BLE sync message ID
 */
typedef NS_ENUM(NSUInteger, DotBleMessageSyncId)
{
    XSBleMessageSyncStopSync = 0x50,
    XSBleMessageSyncGetSyncStatus = 0x51
};

/**
 *  The sensor report type
 */
typedef NS_ENUM(NSUInteger, XSBleDeviceReportType)
{
    XSBleDeviceReportTypeSuccessful = 0,
    XSBleDeviceReportTypePowerOff,
    XSBleDeviceReportTypeDeviceBusy,
    XSBleDeviceReportTypeIllegalCommand,
    XSBleDeviceReportTypePowerSaving,
    XSBleDeviceReportTypeButtonCallback,
    XSBleDeviceFilterProfileTotalNumber,
    XSBleDeviceFilterProfileProperty,
};

#pragma mark - Notification keywords
/*
 Notification keywords.
 If there is return data, use NSNotification.object to return.
 */

/// Notification of Bluetooth state update
extern NSString * const kDotNotificationManagerStateDidUpdate;

/// Notification of Connect succeeded, return DotDevice *.
extern NSString * const kDotNotificationDeviceConnectSucceeded;

/// Notification of Connect failed, return DotDevice *.
extern NSString * const kDotNotificationDeviceConnectFailed;

/// Notification of Connection break, return DotDevice *.
extern NSString * const kDotNotificationDeviceDidDisconnect;

/// Notification of Battery information update, return DotDevice *.
extern NSString * const kDotNotificationDeviceBatteryDidUpdate;

/// Notification of Firmware version read, return DotDevice *.
extern NSString * const kDotNotificationDeviceFirmwareVersionDidRead;

/// Notification of  Sensor name read, return DotDevice *.
extern NSString * const kDotNotificationDeviceNameDidRead;

/// Notification of  Sensor Mac address read, return DotDevice *.
extern NSString * const kDotNotificationDeviceMacAddressDidRead;

/// Notification of Start to connect sensor, return nil.
extern NSString * const kDotNotificationDeviceConnectionDidStart;

/// Notification of  Logger path , when start logging return NSString *.
extern NSString * const kDotNotificationDeviceLoggingPath;

/// Notification of Recording state changed , when connect sensor this will be notify.
extern NSString * const kDotNotificationDeviceRecordingStateUpdate;

/// Notification of sensor connection has been done. All properties initialized.
extern NSString * const kDotNotificationDeviceInitialized;

//@"Movella DOT"
extern NSString * const kDotDeviceSpecialName;

#endif /* DotDefine_h */
