//
//  MultiConsumerFIFO.h
//  KaraokeRecorder
//
//  Created by qiudong on 2019/11/9.
//  Copyright © 2019 Cyllenge. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

//@protocol MultiConsumerFIFODelegate <NSObject>
//
//@end

@interface MultiConsumerFIFO : NSObject

/**
 * Totoal consumers = 1 master consumer + $slaveConsumers slave consumer
 * Master consumer: The consumer who master the data pulling, meaning that it get its data consecutively without dropping
 * Slave consumers: Consumers who are expected to get their data with possible loss or out of order
 */
-(instancetype) initWithCapacity:(NSUInteger)capacity slaveConsumers:(int)slaveConsumers;/// delegate:(id<MultiConsumerFIFODelegate>)delegate;

-(NSUInteger) pullData:(void*)buffer length:(NSUInteger)length consumer:(int)consumer waitForComplete:(BOOL)waitForComplete;

-(NSUInteger) appendData:(const void*)buffer length:(NSUInteger)length overwriteIfFull:(BOOL)overwriteIfFull waitForSpace:(BOOL)waitForSpace;

-(void) finish;

@end

NS_ASSUME_NONNULL_END
