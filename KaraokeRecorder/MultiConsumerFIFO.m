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
@property (nonatomic, assign) int slaveConsumersCount;

@property (nonatomic, assign) NSUInteger writeLocation;
@property (nonatomic, assign) NSUInteger* readLocations;

@property (nonatomic, assign) NSUInteger* filledBytesCounts;

@end

@implementation MultiConsumerFIFO

-(void) dealloc {
    free(_buffer);
    free(_readLocations);
    free(_filledBytesCounts);
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
        
        _filledBytesCounts = malloc(sizeof(NSUInteger) * (slaveConsumers + 1));
        memset(_filledBytesCounts, 0, sizeof(NSUInteger) * (slaveConsumers + 1));
        
        _cond = [[NSCondition alloc] init];
    }
    return self;
}

-(NSUInteger) pullData:(void*)buffer length:(NSUInteger)length consumer:(int)consumer waitForComplete:(BOOL)waitForComplete {
    NSUInteger offset = 0;
    if (0 == consumer)
    {
        return 0;//TODO:
    }
    else
    {
        NSUInteger bytesToRead = length - offset;
        while (_filledBytesCounts[consumer] > 0)
        {
            bytesToRead = bytesToRead < _filledBytesCounts[consumer] ? bytesToRead : _filledBytesCounts[consumer];
            NSUInteger bytesRead = bytesToRead;
            while (_readLocations[consumer] + bytesToRead >= _capacity)
            {
                NSUInteger segmentLength = _capacity - _readLocations[consumer];
                memcpy(buffer + offset, _buffer + _readLocations[consumer], segmentLength);
                _readLocations[consumer] = 0;
                offset += segmentLength;
                bytesToRead -= segmentLength;
            }
            memcpy(buffer + offset, _buffer + _readLocations[consumer], bytesToRead);
            _readLocations[consumer] += bytesToRead;
            offset += bytesToRead;
            
            [_cond lock];
            {
                _filledBytesCounts[consumer] -= bytesRead;
                [_cond broadcast];
            }
            [_cond unlock];
        }
        
        bytesToRead = length - offset;
        if (bytesToRead > 0)
        {
            NSUInteger bytesRead = bytesToRead;
            while (_readLocations[consumer] + bytesToRead >= _capacity)
            {
                NSUInteger segmentLength = _capacity - _readLocations[consumer];
                memset(buffer + offset, 0, segmentLength);
                _readLocations[consumer] = 0;
                offset += segmentLength;
                bytesToRead -= segmentLength;
            }
            memset(buffer + offset, 0, bytesToRead);
            _readLocations[consumer] += bytesToRead;
            offset += bytesToRead;
            
            [_cond lock];
            {
                _filledBytesCounts[consumer] -= bytesRead;
                [_cond broadcast];
            }
            [_cond unlock];
        }
        
        return length;
    }
}

-(NSUInteger) appendData:(const void*)buffer length:(NSUInteger)length overwriteIfFull:(BOOL)overwriteIfFull waitForSpace:(BOOL)waitForSpace {
    NSUInteger offset = 0;
    if (overwriteIfFull)
    {
        while (_writeLocation + length - offset >= _capacity)
        {
            memcpy(_buffer + _writeLocation, buffer + offset, _capacity - _writeLocation);
            offset += (_capacity - _writeLocation);
            _writeLocation = 0;
        }
        memcpy(_buffer + _writeLocation, buffer + offset, length - offset);
        _writeLocation += (length - offset);
        
        [_cond lock];
        {
            for (int i = _slaveConsumersCount; i >= 0; --i)
            {
                _filledBytesCounts[i] += length;
            }
            [_cond broadcast];
        }
        [_cond unlock];
        
        return length;
    }
    else if (waitForSpace)
    {
        while (offset < length)
        {
            NSUInteger bytesToWrite = _capacity - _filledBytesCounts[0];
            [_cond lock];
            {
                while (bytesToWrite <= 0)
                {
                    [_cond wait];
                    bytesToWrite = _capacity - _filledBytesCounts[0];
                }
            }
            [_cond unlock];
                
            bytesToWrite = bytesToWrite < length ? bytesToWrite : length;
            NSUInteger bytesFilled = bytesToWrite;
            while (_writeLocation + bytesToWrite >= _capacity)
            {
                NSUInteger segmentLength = _capacity - _writeLocation;
                memcpy(_buffer + _writeLocation, buffer + offset, segmentLength);
                _writeLocation = 0;
                offset += segmentLength;
                bytesToWrite -= segmentLength;
            }
            memcpy(_buffer + _writeLocation, buffer + offset, bytesToWrite);
            _writeLocation += bytesToWrite;
            offset += bytesToWrite;
            
            [_cond lock];
            {
                for (int i = _slaveConsumersCount; i >= 0; --i)
                {
                    _filledBytesCounts[i] += bytesFilled;
                }
                [_cond broadcast];
            }
            [_cond unlock];
        }
        return length;
    }
    else
    {
        NSUInteger bytesToWrite = _capacity - _filledBytesCounts[0];
        bytesToWrite = bytesToWrite < length ? bytesToWrite : length;
        while (_writeLocation + bytesToWrite >= _capacity)
        {
            NSUInteger segmentLength = _capacity - _writeLocation;
            memcpy(_buffer + _writeLocation, buffer + offset, segmentLength);
            _writeLocation = 0;
            offset += segmentLength;
            bytesToWrite -= segmentLength;
        }
        memcpy(_buffer + _writeLocation, buffer + offset, bytesToWrite);
        _writeLocation += bytesToWrite;
        offset += bytesToWrite;
        
        [_cond lock];
        {
            for (int i = _slaveConsumersCount; i >= 0; --i)
            {
                _filledBytesCounts[i] += offset;
            }
            [_cond broadcast];
        }
        [_cond unlock];
        
        return offset;
    }
}

@end
