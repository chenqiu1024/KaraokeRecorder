//
//  MultiConsumerFIFO.m
//  KaraokeRecorder
//
//  Created by qiudong on 2019/11/9.
//  Copyright © 2019 Cyllenge. All rights reserved.
//

#import "MultiConsumerFIFO.h"

@interface MultiConsumerFIFO ()

@property (nonatomic, weak) id<MultiConsumerFIFODelegate> delegate;

@property (nonatomic, strong) NSCondition* cond;

@property (nonatomic, assign) void* buffer;
@property (nonatomic, assign) NSUInteger capacity;
@property (nonatomic, assign) NSUInteger slaveConsumersCount;

@property (nonatomic, assign) NSUInteger writeLocation;
@property (nonatomic, assign) NSUInteger* readLocations;

@property (nonatomic, assign) NSUInteger bytesPulled;//For the master consumer
@property (nonatomic, assign) NSUInteger bytesFilled;//For the master consumer

@end

@implementation MultiConsumerFIFO

-(void) dealloc {
    free(_buffer);
    free(_readLocations);
}

-(instancetype) initWithCapacity:(NSUInteger)capacity slaveConsumers:(int)slaveConsumers delegate:(id<MultiConsumerFIFODelegate>)delegate {
    if (self = [super init])
    {
        _delegate = delegate;
        
        _buffer = malloc(capacity);
        _capacity = capacity;
        _slaveConsumersCount = slaveConsumers;
        
        _readLocations = malloc(sizeof(NSUInteger) * (slaveConsumers + 1));
        memset(_readLocations, 0, sizeof(NSUInteger) * (slaveConsumers + 1));
        
        _writeLocation = 0;
        
        _bytesPulled = 0;
        _bytesFilled = 0;
        
        _cond = [[NSCondition alloc] init];
    }
    return self;
}

-(NSUInteger) pullData:(void*)buffer length:(NSUInteger)length consumer:(int)consumer waitForComplete:(BOOL)waitForComplete {
    return 0;//TODO:
}

-(NSUInteger) appendData:(const void*)buffer length:(NSUInteger)length overwriteIfFull:(BOOL)overwriteIfFull {
    if (overwriteIfFull)
    {
        NSUInteger offset = 0;
        while (_writeLocation + length - offset >= _capacity)
        {
            memcpy(_buffer, buffer + offset, _capacity - _writeLocation);
            offset += (_capacity - _writeLocation);
            _writeLocation = 0;
        }
        memcpy(_buffer, buffer + offset, length - offset);
        _writeLocation += (length - offset);
    }
    else
    {
        //TODO:
    }
    
    return length;
}

@end
