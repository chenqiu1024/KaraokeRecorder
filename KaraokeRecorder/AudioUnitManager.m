//
//  AudioUnitManager.m
//  KaraokeRecorder
//
//  Created by DOM QIU on 2019/5/27.
//  Copyright © 2019 Cyllenge. All rights reserved.
//

#import "AudioUnitManager.h"
#import <AVFoundation/AVFoundation.h>

@interface AudioUnitManager ()

@property (nonatomic, assign) BOOL isPlaying;
@property (nonatomic, assign) BOOL isRecording;

@property (nonatomic, assign) float sampleRate;

@property (nonatomic, assign) AUGraph auGraph;
@property (nonatomic, assign) AudioUnit ioUnit;
@property (nonatomic, assign) AudioBufferList* audioBufferList;

@end

static OSStatus PlaybackCallbackProc(void* inRefCon
                                     , AudioUnitRenderActionFlags* ioActionFlags
                                     , const AudioTimeStamp* inTimeStamp
                                     , UInt32 inBusNumber
                                     , UInt32 inNumberFrames
                                     , AudioBufferList* __nullable ioData) {
    if (!ioData)
        return noErr;
    
    AudioUnitManager* auMgr = (__bridge AudioUnitManager*) inRefCon;
    if (!auMgr.isPlaying)
    {
        *ioActionFlags |= kAudioUnitRenderAction_OutputIsSilence;
        for (int iBuffer=0; iBuffer<ioData->mNumberBuffers; ++iBuffer)
        {
            AudioBuffer audioBuffer = ioData->mBuffers[iBuffer];
            if (!audioBuffer.mData) continue;
            memset(audioBuffer.mData, 0, audioBuffer.mDataByteSize);
        }
        
        return noErr;
    }
    
    const float Frequencies[] = {660, 420};
    static NSUInteger totalSampleCount = 0;
    int samples = ioData->mBuffers[0].mDataByteSize / 2;
    for (int iBuffer=0; iBuffer<ioData->mNumberBuffers; ++iBuffer)
    {
        AudioBuffer audioBuffer = ioData->mBuffers[iBuffer];
        if (!audioBuffer.mData) continue;
        int16_t* pDst = audioBuffer.mData;
        for (int iSample=0; iSample<samples; ++iSample)
        {
            float phase = Frequencies[iBuffer] * M_PI * 2 * (totalSampleCount + iSample) / auMgr.sampleRate;
            *(pDst++) = (int16_t) (sinf(phase) * 16384);
        }
    }
    totalSampleCount += samples;
    return noErr;
}

static OSStatus InputCallbackProc(void* inRefCon
                                     , AudioUnitRenderActionFlags* ioActionFlags
                                     , const AudioTimeStamp* inTimeStamp
                                     , UInt32 inBusNumber
                                     , UInt32 inNumberFrames
                                     , AudioBufferList* __nullable ioData) {
    AudioUnitManager* auMgr = (__bridge AudioUnitManager*) inRefCon;
    int numBuffers = 1;
    if (!auMgr.audioBufferList)
    {
        auMgr.audioBufferList = (AudioBufferList*) malloc(sizeof(AudioBufferList) + sizeof(AudioBuffer) * (numBuffers - 1));
        auMgr.audioBufferList->mNumberBuffers = numBuffers;
    }
    auMgr.audioBufferList->mNumberBuffers = numBuffers;
    for (int i=0; i<numBuffers; ++i)
    {
        auMgr.audioBufferList->mBuffers[i].mNumberChannels = 1;
        if (auMgr.audioBufferList->mBuffers[i].mDataByteSize < inNumberFrames * 2)
        {
            auMgr.audioBufferList->mBuffers[i].mDataByteSize = inNumberFrames * 2;
            if (auMgr.audioBufferList->mBuffers[i].mData)
            {
                free(auMgr.audioBufferList->mBuffers[i].mData);
            }
            auMgr.audioBufferList->mBuffers[i].mData = malloc(auMgr.audioBufferList->mBuffers[i].mDataByteSize);
            memset(auMgr.audioBufferList->mBuffers[i].mData, 0, auMgr.audioBufferList->mBuffers[i].mDataByteSize);
        }
        else
        {
            auMgr.audioBufferList->mBuffers[i].mDataByteSize = inNumberFrames * 2;
        }
    }
    OSStatus result = AudioUnitRender(auMgr.ioUnit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, auMgr.audioBufferList);
    //NSLog(@"#AudioUnit# result=%d, ioActionFlags=0x%x, inBusNumber=%d, inNumberFrames=%d, inTimeStamp=%f, bufferList->mBuffers[0].mData=0x%lx... at %d in %s", result, *ioActionFlags, inBusNumber, inNumberFrames, inTimeStamp->mSampleTime, ((long*) auMgr.audioBufferList->mBuffers[0].mData)[0], __LINE__, __PRETTY_FUNCTION__);
    return noErr;
}

@implementation AudioUnitManager

-(void) close {
    if (!_auGraph)
        return;
    
    AUGraphStop(_auGraph);
    AUGraphClose(_auGraph);
    _auGraph = NULL;
    
    for (int i=0; i<_audioBufferList->mNumberBuffers; ++i)
    {
        free(&_audioBufferList->mBuffers[i]);
    }
    free(_audioBufferList);
}

-(void) open {
    _sampleRate = 8000.f;
    
    int numBuffers = 1;
    _audioBufferList = (AudioBufferList*) malloc(sizeof(AudioBufferList) + sizeof(AudioBuffer) * (numBuffers - 1));
    _audioBufferList->mNumberBuffers = numBuffers;
    for (int i=0; i<numBuffers; ++i)
    {
        _audioBufferList->mBuffers[i].mNumberChannels = 1;
        _audioBufferList->mBuffers[i].mDataByteSize = 4096;
        _audioBufferList->mBuffers[i].mData = malloc(_audioBufferList->mBuffers[i].mDataByteSize);
        memset(_audioBufferList->mBuffers[i].mData, 0, _audioBufferList->mBuffers[i].mDataByteSize);
    }
    
    AudioStreamBasicDescription ioInputASBD;
    ioInputASBD.mSampleRate = _sampleRate;
    ioInputASBD.mFormatID = kAudioFormatLinearPCM;
    // kAudioFormatFlagIsNonInterleaved will create 1 AudioBuffer for each channel:
    ioInputASBD.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsNonInterleaved;
    ioInputASBD.mFramesPerPacket = 1;
    ioInputASBD.mChannelsPerFrame = 1;
    ioInputASBD.mBitsPerChannel = 16;
    AudioStreamBasicDescription ioOutputASBD = ioInputASBD;
    ioOutputASBD.mChannelsPerFrame = 2;
    
    ioInputASBD.mBytesPerFrame = ioInputASBD.mBitsPerChannel * ioInputASBD.mChannelsPerFrame / 8;
    ioInputASBD.mBytesPerPacket = ioInputASBD.mBytesPerFrame * ioInputASBD.mFramesPerPacket;
    
    ioOutputASBD.mBytesPerFrame = ioOutputASBD.mBitsPerChannel * ioOutputASBD.mChannelsPerFrame / 8;
    ioOutputASBD.mBytesPerPacket = ioOutputASBD.mBytesPerFrame * ioOutputASBD.mFramesPerPacket;
    
    AudioComponentDescription ioACDesc;
    ioACDesc.componentType = kAudioUnitType_Output;
    // kAudioUnitSubType_VoiceProcessingIO enables echo cancellation, but mixes the stero channels as mono sound
    ioACDesc.componentSubType = kAudioUnitSubType_VoiceProcessingIO;
    ioACDesc.componentManufacturer = kAudioUnitManufacturer_Apple;
    ioACDesc.componentFlags = 0;
    ioACDesc.componentFlagsMask = 0;
    
    OSStatus result;
    AUNode ioNode;
    result = NewAUGraph(&_auGraph);
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    result = AUGraphAddNode(_auGraph, &ioACDesc, &ioNode);
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    result = AUGraphOpen(_auGraph);
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    result = AUGraphNodeInfo(_auGraph, ioNode, &ioACDesc, &_ioUnit);
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    
    UInt32 flag = 1;
    result = AudioUnitSetProperty(_ioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &flag, sizeof(flag));
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    result = AudioUnitSetProperty(_ioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &flag, sizeof(flag));
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    result = AudioUnitSetProperty(_ioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &ioInputASBD, sizeof(ioInputASBD));
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    // kAudioUnitScope_Input of element 0 of IO unit represents the input of Speaker:
    result = AudioUnitSetProperty(_ioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &ioOutputASBD, sizeof(ioOutputASBD));
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    flag = 0;
    result = AudioUnitSetProperty(_ioUnit, kAudioUnitProperty_ShouldAllocateBuffer, kAudioUnitScope_Output, 1, &flag, sizeof(flag));
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    
    UInt32 maximumFramesPerSlick = 1024;
    result = AudioUnitSetProperty(_ioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 1, &maximumFramesPerSlick, sizeof(maximumFramesPerSlick));
    
    AURenderCallbackStruct playbackCallback;
    playbackCallback.inputProc = PlaybackCallbackProc;
    playbackCallback.inputProcRefCon = (__bridge void* _Nullable) self;
    // Both the following 2 lines work for output:
    result = AudioUnitSetProperty(_ioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Global, 0, &playbackCallback, sizeof(playbackCallback));
//    result = AUGraphSetNodeInputCallback(_auGraph, ioNode, 0, &playbackCallback);
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    
    AURenderCallbackStruct inputCallback;
    inputCallback.inputProc = InputCallbackProc;
    inputCallback.inputProcRefCon = (__bridge void* _Nullable) self;
    result = AudioUnitSetProperty(_ioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &inputCallback, sizeof(inputCallback));
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    
    result = AUGraphInitialize(_auGraph);
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    CAShow(_auGraph);
    
    AVAudioSession* audioSession = [AVAudioSession sharedInstance];
    [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionInterruptionNotification object:audioSession queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
        int reason = [[note.userInfo valueForKey:AVAudioSessionInterruptionTypeKey] intValue];
        switch (reason)
        {
            case AVAudioSessionInterruptionTypeBegan:
                [audioSession setActive:NO error:nil];
                break;
            case AVAudioSessionInterruptionTypeEnded:
                [audioSession setActive:YES error:nil];
                break;
            default:
                break;
        }
    }];
    
    [audioSession setCategory:AVAudioSessionCategoryPlayAndRecord withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker|AVAudioSessionCategoryOptionAllowBluetooth|AVAudioSessionCategoryOptionAllowBluetoothA2DP error:nil];
    [audioSession setPreferredSampleRate:_sampleRate error:nil];
    [audioSession setPreferredIOBufferDuration:0.064 error:nil];
    /* Only valid with AVAudioSessionCategoryPlayAndRecord.  Appropriate for Voice over IP
     (VoIP) applications.  Reduces the number of allowable audio routes to be only those
     that are appropriate for VoIP applications and may engage appropriate system-supplied
     signal processing.  Has the side effect of setting AVAudioSessionCategoryOptionAllowBluetooth */
    [audioSession setMode:AVAudioSessionModeVoiceChat error:nil];
    [audioSession setActive:YES error:nil];
}

-(void) startPlaying {
    _isPlaying = YES;
    
    OSStatus result = AUGraphStart(_auGraph);
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    
}

-(void) stopPlaying {
    if (!_auGraph)
        return;
    
    _isPlaying = NO;
    OSStatus result = AUGraphStop(_auGraph);
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    
}

-(void) dealloc {
    [self close];
}

-(instancetype) init {
    if (self = [super init])
    {
        [self open];
    }
    return self;
}

@end
