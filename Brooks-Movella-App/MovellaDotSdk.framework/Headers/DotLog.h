//
//  DotLog.h
//  DotSdk
//
//  Created by Jayson on 2020/4/18.
//  Copyright © 2023 Movella. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifndef XSDotSDKLogTitle
#define XSDotSDKLogTitle     @"[XSDotSDK]"
#endif

/*
 Log when debug in development
*/

#ifdef DEBUG
#define NSLogObject(obj)            NSLog(@"%@", obj)
#define NSLogFunction()             NSLog(@"%s", __FUNCTION__)
#define NSLogFunctionWithInfo(obj)  NSLog(@"%s:%@", __FUNCTION__, obj)
#define NSLogFunctionFormat(format, args...)    NSLog(@"%s:" format, __FUNCTION__, args)
#else
#define NSLogObject(obj)                        if([DotLog isLogEnable]) { NSLog(@"%@ %@", XSDotSDKLogTitle, obj); }
#define NSLogFunction()                         if([DotLog isLogEnable]) { NSLog(@"%@ %s", XSDotSDKLogTitle, __FUNCTION__); }
#define NSLogFunctionWithInfo(obj)              if([DotLog isLogEnable]) { NSLog(@"%@ %s:%@", XSDotSDKLogTitle, __FUNCTION__, obj); }
#define NSLogFunctionFormat(format, args...)    if([DotLog isLogEnable]) { NSLog(@"%@ %s:" format, XSDotSDKLogTitle,  __FUNCTION__, args); }
#endif


/**
 *  Enable DotLog when you want to get debug information. Note that you need to disable it in released apps.
 */
@interface DotLog : NSObject

/**
 *  Set the log enable to open log in debug mode
 *  @param enable The enable flag
 */
+ (void)setLogEnable:(BOOL)enable;

/**
 *  Get current sdk log  status
 *  @return YES  the log is enable and NO the log is disable
 */
+ (BOOL)isLogEnable;

@end

NS_ASSUME_NONNULL_END
