//
//  AudioUnitManager.m
//  KaraokeRecorder
//
//  Created by DOM QIU on 2019/5/27.
//  Copyright © 2019 Cyllenge. All rights reserved.
//

#import "AudioUnitManager.h"
#import <AVFoundation/AVFoundation.h>

NSString* AudioUnitRenderActionFlagsString(AudioUnitRenderActionFlags flags) {
    NSDictionary* dict = @{@(kAudioUnitRenderAction_PostRender):@"PostRender"
                           ,@(kAudioUnitRenderAction_PreRender):@"PreRender"
                           ,@(kAudioUnitRenderAction_OutputIsSilence):@"Silence"
                           ,@(kAudioUnitRenderAction_PostRenderError):@"PostRenderError"
                           ,@(kAudioUnitRenderAction_DoNotCheckRenderArgs):@"NoCheck"
                           ,@(kAudioOfflineUnitRenderAction_Preflight):@"Preflight"
                           ,@(kAudioOfflineUnitRenderAction_Render):@"Render"
                           ,@(kAudioOfflineUnitRenderAction_Complete):@"Complete"
                           };
    NSMutableString* ret = [@"" mutableCopy];
    [dict enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
        int flag = [key intValue];
        if (flags & flag)
        {
            [ret appendFormat:(ret.length > 0 ? @"|%@" : @"%@"), obj];
        }
    }];
    return [NSString stringWithString:ret];
}

@interface AudioUnitManager ()

@property (nonatomic, assign) BOOL isAUGraphRunning;
@property (nonatomic, assign) BOOL isPlaying;
@property (nonatomic, assign) BOOL isRecording;

@property (nonatomic, assign) float micphoneSampleRate;
@property (nonatomic, assign) float audioSourceSampleRate;
@property (nonatomic, assign) float recorderSampleRate;

@property (nonatomic, assign) AUGraph auGraph;
@property (nonatomic, assign) AudioUnit ioUnit;
@property (nonatomic, assign) AudioUnit resampler0Unit;
@property (nonatomic, assign) AudioUnit resampler1Unit;
@property (nonatomic, assign) AudioBufferList* audioBufferList;
@property (nonatomic, strong) NSMutableArray<NSMutableData* >* playbackDatas;

@end

static OSStatus PlaybackCallbackProc(void* inRefCon
                                     , AudioUnitRenderActionFlags* ioActionFlags
                                     , const AudioTimeStamp* inTimeStamp
                                     , UInt32 inBusNumber
                                     , UInt32 inNumberFrames
                                     , AudioBufferList* __nullable ioData) {
    if (!ioData)
        return noErr;
    NSLog(@"#AudioUnit# Playback: actionFlags=0x%x, bufNumber=%d", *ioActionFlags, inBusNumber);
    if (!(*ioActionFlags & kAudioUnitRenderAction_PostRender) || inBusNumber != 1)
    {printf("\n#AudioUnit# Playback: return\n");
        return noErr;
    }
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
    
    if (auMgr.delegate && [auMgr.delegate respondsToSelector:@selector(audioUnitManager:willFillPlaybackAudioData:length:channel:)])
    {
        for (int iBuffer=0; iBuffer<ioData->mNumberBuffers; ++iBuffer)
        {
            AudioBuffer audioBuffer = ioData->mBuffers[iBuffer];
            NSLog(@"#AudioUnit# inBusNumber=%d, inNumberFrames=%d, audioBuffer[%d].size=%d, .channels=%d", inBusNumber, inNumberFrames, iBuffer, audioBuffer.mDataByteSize, audioBuffer.mNumberChannels);
            if (!audioBuffer.mData) continue;
            [auMgr.delegate audioUnitManager:auMgr willFillPlaybackAudioData:audioBuffer.mData length:audioBuffer.mDataByteSize channel:iBuffer];
            
            static NSUInteger totalBytesLength = 0;
            if (iBuffer == 0)
            {
                NSLog(@"#AudioUnit# totalBytesLength=%ld", totalBytesLength);
                totalBytesLength += audioBuffer.mDataByteSize;
            }
        }
    }
    else
    {
        for (int iBuffer=0; iBuffer<ioData->mNumberBuffers; ++iBuffer)
        {
            AudioBuffer audioBuffer = ioData->mBuffers[iBuffer];
            if (!audioBuffer.mData) continue;
            NSLog(@"#AudioUnit# inBusNumber=%d, inNumberFrames=%d, audioBuffer[%d].size=%d, .channels=%d", inBusNumber, inNumberFrames, iBuffer, audioBuffer.mDataByteSize, audioBuffer.mNumberChannels);
            NSMutableData* playbackData = (auMgr.playbackDatas && iBuffer < auMgr.playbackDatas.count) ? auMgr.playbackDatas[iBuffer] : nil;
            int consumedByteLength = playbackData ? (int)playbackData.length : 0;
            consumedByteLength = consumedByteLength < audioBuffer.mDataByteSize ? consumedByteLength : audioBuffer.mDataByteSize;
            if (consumedByteLength)
            {
                memcpy(audioBuffer.mData, playbackData.bytes, consumedByteLength);
                [playbackData replaceBytesInRange:NSMakeRange(0, consumedByteLength) withBytes:NULL length:0];
                
                if (playbackData.length == 0)
                    NSLog(@"#AudioUnit# AudioData[%d] EOF", iBuffer);
            }
            memset(audioBuffer.mData + consumedByteLength, 0, audioBuffer.mDataByteSize - consumedByteLength);

            static NSUInteger totalBytesLength = 0;
            if (iBuffer == 0)
            {
                NSLog(@"#AudioUnit# totalBytesLength=%ld", totalBytesLength);
                totalBytesLength += audioBuffer.mDataByteSize;
            }
        }
    }
    
    return noErr;
}

static OSStatus InputCallbackProc(void* inRefCon
                                     , AudioUnitRenderActionFlags* ioActionFlags
                                     , const AudioTimeStamp* inTimeStamp
                                     , UInt32 inBusNumber
                                     , UInt32 inNumberFrames
                                     , AudioBufferList* __nullable ioData) {
    AudioUnitManager* auMgr = (__bridge AudioUnitManager*) inRefCon;
    if (!auMgr.isRecording)
        return noErr;
    printf("\n#AudioUnit#.. Input: actionFlags=%s, (bus, frames)=(%d, %d)\n", AudioUnitRenderActionFlagsString(*ioActionFlags).UTF8String, inBusNumber, inNumberFrames);
    /*
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
    if (auMgr.delegate && [auMgr.delegate respondsToSelector:@selector(audioUnitManager:didReceiveAudioData:length:channel:)])
    {
        for (int i=0; i<numBuffers; ++i)
        {
            [auMgr.delegate audioUnitManager:auMgr didReceiveAudioData:auMgr.audioBufferList->mBuffers[i].mData length:auMgr.audioBufferList->mBuffers[i].mDataByteSize channel:i];
     
            static NSUInteger totalBytesLength = 0;
            if (i == 0)
            {
                NSLog(@"#AudioUnit# Recording: totalBytesLength=%ld, inNumberFrames=%d", totalBytesLength, inNumberFrames);
                totalBytesLength += auMgr.audioBufferList->mBuffers[i].mDataByteSize;
            }
        }
    }
    /*/
    // If not in kAudioUnitRenderAction_PostRender state, will be infinitely recursive calling:
    //if ((*ioActionFlags & kAudioUnitRenderAction_PreRender))
    //    return noErr;
    if (!(*ioActionFlags & kAudioUnitRenderAction_PostRender))
    {printf("\n#AudioUnit#.. Input: return\n");
        return noErr;
    }
    /*
    AudioUnitRenderActionFlags actionFlags = 0;///!!!kAudioUnitRenderAction_PostRender;
    AudioTimeStamp timeStamp = *inTimeStamp;
    //timeStamp.mRateScalar *= 2;
    //inNumberFrames /= 2;
    inNumberFrames = (inNumberFrames == 512 ? 256 : 512);
    printf("\n#AudioUnit#.. Input: Before AudioUnitRender(%s, %d);\n", AudioUnitRenderActionFlagsString(actionFlags).UTF8String, inNumberFrames);
    OSStatus result = AudioUnitRender(auMgr.resamplerUnit, &actionFlags, &timeStamp, 0, inNumberFrames, auMgr.audioBufferList);
    printf("\n#AudioUnit#.. Input: After AudioUnitRender(%s, %d)=%d;\n", AudioUnitRenderActionFlagsString(actionFlags).UTF8String, inNumberFrames, result);
    //OSStatus result = AudioUnitRender(auMgr.ioUnit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, auMgr.audioBufferList);
    NSLog(@"result=%d, inTimeStamp->mSampleTime=%f, inNumberFrames=%d. at %d in %s", result, inTimeStamp->mSampleTime, inNumberFrames, __LINE__, __PRETTY_FUNCTION__);
    //*/
    //NSLog(@"#AudioUnit# result=%d, ioActionFlags=0x%x, inBusNumber=%d, inNumberFrames=%d, inTimeStamp=%f, bufferList->mBuffers[0].mData=0x%lx... at %d in %s", result, *ioActionFlags, inBusNumber, inNumberFrames, inTimeStamp->mSampleTime, ((long*) auMgr.audioBufferList->mBuffers[0].mData)[0], __LINE__, __PRETTY_FUNCTION__);
    return noErr;
}

static OSStatus ResampleCallbackProc(void* inRefCon
                                  , AudioUnitRenderActionFlags* ioActionFlags
                                  , const AudioTimeStamp* inTimeStamp
                                  , UInt32 inBusNumber
                                  , UInt32 inNumberFrames
                                  , AudioBufferList* __nullable ioData) {
    AudioUnitManager* auMgr = (__bridge AudioUnitManager*) inRefCon;
    if (!auMgr.isRecording)
        return noErr;
    //printf("\n#AudioUnit#.. Resample: actionFlags=%s, (bus, frames)=(%d, %d)\n", AudioUnitRenderActionFlagsString(*ioActionFlags).UTF8String, inBusNumber, inNumberFrames);
    /*
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
     if (auMgr.delegate && [auMgr.delegate respondsToSelector:@selector(audioUnitManager:didReceiveAudioData:length:channel:)])
     {
     for (int i=0; i<numBuffers; ++i)
     {
     [auMgr.delegate audioUnitManager:auMgr didReceiveAudioData:auMgr.audioBufferList->mBuffers[i].mData length:auMgr.audioBufferList->mBuffers[i].mDataByteSize channel:i];
     
     static NSUInteger totalBytesLength = 0;
     if (i == 0)
     {
     NSLog(@"#AudioUnit# Recording: totalBytesLength=%ld, inNumberFrames=%d", totalBytesLength, inNumberFrames);
     totalBytesLength += auMgr.audioBufferList->mBuffers[i].mDataByteSize;
     }
     }
     }
     /*/
    if (!ioData)
        return noErr;
    if (*ioActionFlags & kAudioUnitRenderAction_PreRender)
        return noErr;
    if (!(*ioActionFlags & kAudioUnitRenderAction_PostRender))
        return noErr;
    
    if (auMgr.delegate && [auMgr.delegate respondsToSelector:@selector(audioUnitManager:didReceiveAudioData:length:channel:)])
    {
        for (int i=0; i<ioData->mNumberBuffers; ++i)
        {
            [auMgr.delegate audioUnitManager:auMgr didReceiveAudioData:ioData->mBuffers[i].mData length:ioData->mBuffers[i].mDataByteSize channel:i];
            
            static NSUInteger totalBytesLength = 0;
            if (i == 0)
            {
                //NSLog(@"#AudioUnit# ReSampler: totalBytesLength=%ld, inNumberFrames=%d", totalBytesLength, inNumberFrames);
                totalBytesLength += ioData->mBuffers[i].mDataByteSize;
            }
        }
    }
    //*/
    //NSLog(@"#AudioUnit# result=%d, ioActionFlags=0x%x, inBusNumber=%d, inNumberFrames=%d, inTimeStamp=%f, bufferList->mBuffers[0].mData=0x%lx... at %d in %s", result, *ioActionFlags, inBusNumber, inNumberFrames, inTimeStamp->mSampleTime, ((long*) auMgr.audioBufferList->mBuffers[0].mData)[0], __LINE__, __PRETTY_FUNCTION__);
    return noErr;
}

@implementation AudioUnitManager

-(void) onRouteChangeNotification:(NSNotification*)note {
    int reason = [[note.userInfo valueForKey:AVAudioSessionRouteChangeReasonKey] intValue];
    AVAudioSessionRouteDescription* previousRoute = (AVAudioSessionRouteDescription*) [note.userInfo valueForKey:AVAudioSessionRouteChangePreviousRouteKey];
    if (AVAudioSessionRouteChangeReasonOldDeviceUnavailable == reason)
    {
        //获取上一线路描述信息并获取上一线路的输出设备类型
        AVAudioSessionPortDescription* previousOutput = previousRoute.outputs[0];
        NSString* portType = previousOutput.portType;
        if ([portType isEqualToString:AVAudioSessionPortHeadphones])
        {
            [[AVAudioSession sharedInstance] overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:nil];
        }
    }
}

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
    
    _playbackDatas = nil;
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

-(void) open {
    /// Sample rate 8000Hz is NG for Bluetooth headphone, WHY?
    _micphoneSampleRate = 16000.f;
    _recorderSampleRate = 8000.f;
    _audioSourceSampleRate = 8000.f;
    
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
    
    // Set all AudioComponentDescription(s):
    AudioComponentDescription ioACDesc, resamplerACDesc;
    ioACDesc.componentType = kAudioUnitType_Output;
    // kAudioUnitSubType_VoiceProcessingIO enables echo cancellation, but mixes the stero channels as mono sound
    ioACDesc.componentSubType = kAudioUnitSubType_VoiceProcessingIO;
//    ioACDesc.componentSubType = kAudioUnitSubType_RemoteIO;
    ioACDesc.componentManufacturer = kAudioUnitManufacturer_Apple;
    ioACDesc.componentFlags = 0;
    ioACDesc.componentFlagsMask = 0;
    
    resamplerACDesc.componentType = kAudioUnitType_FormatConverter;
    resamplerACDesc.componentSubType = kAudioUnitSubType_AUConverter;
    resamplerACDesc.componentFlags = 0;
    resamplerACDesc.componentFlagsMask = 0;
    resamplerACDesc.componentManufacturer = kAudioUnitManufacturer_Apple;
    
    // Create the AUGraph:
    OSStatus result;
    AUNode ioNode, resampler0Node, resampler1Node;
    result = NewAUGraph(&_auGraph);
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    // Add AUNode(s):
    result = AUGraphAddNode(_auGraph, &ioACDesc, &ioNode);
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    result = AUGraphAddNode(_auGraph, &resamplerACDesc, &resampler0Node);
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    result = AUGraphAddNode(_auGraph, &resamplerACDesc, &resampler1Node);
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    // Connect the nodes:
    AUGraphConnectNodeInput(_auGraph, ioNode, 1, resampler0Node, 0);
    AUGraphConnectNodeInput(_auGraph, resampler0Node, 0, resampler1Node, 0);
    AUGraphConnectNodeInput(_auGraph, resampler1Node, 0, ioNode, 0);
    // Open the AUGraph, but it is not initialized(allocate resources) at this point:
    result = AUGraphOpen(_auGraph);
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    // Get the AudioUnit info:
    result = AUGraphNodeInfo(_auGraph, ioNode, &ioACDesc, &_ioUnit);
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    result = AUGraphNodeInfo(_auGraph, resampler0Node, &resamplerACDesc, &_resampler0Unit);
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    result = AUGraphNodeInfo(_auGraph, resampler1Node, &resamplerACDesc, &_resampler1Unit);
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    
    UInt32 flag = 1;
    result = AudioUnitSetProperty(_ioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &flag, sizeof(flag));
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    result = AudioUnitSetProperty(_ioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &flag, sizeof(flag));
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    
    // Set all AudioStreamBasicDescription(s):
    AudioStreamBasicDescription ioInputASBD;
    ioInputASBD.mSampleRate = _micphoneSampleRate;
    ioInputASBD.mFormatID = kAudioFormatLinearPCM;
    // kAudioFormatFlagIsNonInterleaved will create 1 AudioBuffer for each channel, while kAudioFormatFlagIsPacked will create 1 interleaved AudioBuffer for all 2 channels:
    ioInputASBD.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    ioInputASBD.mFramesPerPacket = 1;
    ioInputASBD.mChannelsPerFrame = 1;
    ioInputASBD.mBitsPerChannel = 16;
    
    ioInputASBD.mBytesPerFrame = ioInputASBD.mBitsPerChannel * ioInputASBD.mChannelsPerFrame / 8;
    ioInputASBD.mBytesPerPacket = ioInputASBD.mBytesPerFrame * ioInputASBD.mFramesPerPacket;
    
    AudioStreamBasicDescription ioOutputASBD = ioInputASBD;
    ioOutputASBD.mSampleRate = _audioSourceSampleRate;
    ioOutputASBD.mChannelsPerFrame = 2;
    ioOutputASBD.mBytesPerFrame = ioOutputASBD.mBitsPerChannel * ioOutputASBD.mChannelsPerFrame / 8;
    ioOutputASBD.mBytesPerPacket = ioOutputASBD.mBytesPerFrame * ioOutputASBD.mFramesPerPacket;
    
    AudioStreamBasicDescription resampler0OutputASBD = ioInputASBD;
    resampler0OutputASBD.mSampleRate = _recorderSampleRate;
    
    result = AudioUnitSetProperty(_ioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &ioInputASBD, sizeof(ioInputASBD));
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    // kAudioUnitScope_Input of element 0 of IO unit represents the input of Speaker:
    result = AudioUnitSetProperty(_ioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &ioOutputASBD, sizeof(ioOutputASBD));
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    result = AudioUnitSetProperty(_resampler0Unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &ioInputASBD, sizeof(ioInputASBD));
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    result = AudioUnitSetProperty(_resampler0Unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &resampler0OutputASBD, sizeof(resampler0OutputASBD));
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    result = AudioUnitSetProperty(_resampler1Unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &resampler0OutputASBD, sizeof(resampler0OutputASBD));
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    result = AudioUnitSetProperty(_resampler1Unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &ioOutputASBD, sizeof(ioOutputASBD));
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    
    // Not quite clear about what these settings are for:
    //flag = 0;
    //result = AudioUnitSetProperty(_ioUnit, kAudioUnitProperty_ShouldAllocateBuffer, kAudioUnitScope_Output, 1, &flag, sizeof(flag));
    //NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    
    UInt32 maximumFramesPerSlice = 2048;
    result = AudioUnitSetProperty(_ioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 1, &maximumFramesPerSlice, sizeof(maximumFramesPerSlice));
    
    AURenderCallbackStruct playbackCallback;
    playbackCallback.inputProc = PlaybackCallbackProc;
    playbackCallback.inputProcRefCon = (__bridge void* _Nullable) self;
    // Both the following 2 lines work for IO node output:
    //result = AudioUnitSetProperty(_ioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Global, 0, &playbackCallback, sizeof(playbackCallback));
    //result = AUGraphSetNodeInputCallback(_auGraph, ioNode, 0, &playbackCallback);
    result = AudioUnitAddRenderNotify(_ioUnit, PlaybackCallbackProc, (__bridge void* _Nullable) self);
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    /*
    AURenderCallbackStruct inputCallback;
    inputCallback.inputProc = InputCallbackProc;
    inputCallback.inputProcRefCon = (__bridge void* _Nullable) self;
    //result = AudioUnitSetProperty(_ioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &inputCallback, sizeof(inputCallback));
    result = AudioUnitAddRenderNotify(_ioUnit, InputCallbackProc, (__bridge void* _Nullable) self);
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    //*/
    AURenderCallbackStruct resampler1Callback;
    resampler1Callback.inputProc = ResampleCallbackProc;
    resampler1Callback.inputProcRefCon = (__bridge void* _Nullable) self;
    result = AudioUnitAddRenderNotify(_resampler0Unit, ResampleCallbackProc, (__bridge void* _Nullable) self);
    //result = AudioUnitSetProperty(_resampler1Unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &resampler1Callback, sizeof(resampler1Callback));
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    
    result = AUGraphInitialize(_auGraph);
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    CAShow(_auGraph);
    
    // Set AVAudioSessionRouteChangeNotification handler:
    // Set AVAudioSession;
    AVAudioSession* audioSession = [AVAudioSession sharedInstance];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onRouteChangeNotification:) name:AVAudioSessionRouteChangeNotification object:audioSession];
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
    [audioSession setPreferredSampleRate:_micphoneSampleRate error:nil];
    [audioSession setPreferredIOBufferDuration:0.064 error:nil];
    /* Only valid with AVAudioSessionCategoryPlayAndRecord.  Appropriate for Voice over IP
     (VoIP) applications.  Reduces the number of allowable audio routes to be only those
     that are appropriate for VoIP applications and may engage appropriate system-supplied
     signal processing.  Has the side effect of setting AVAudioSessionCategoryOptionAllowBluetooth */
    [audioSession setMode:AVAudioSessionModeVoiceChat error:nil];
    [audioSession setActive:YES error:nil];
}

-(void) startAUGraphIfNecessary {
    if (_isAUGraphRunning || !_auGraph)
        return;
    
    OSStatus result = AUGraphStart(_auGraph);
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    _isAUGraphRunning = YES;
}

-(void) stopAUGraphIfNecessary {
    if (!_isAUGraphRunning || !_auGraph)
        return;
    
    if (_isPlaying || _isRecording)
        return;
    
    OSStatus result = AUGraphStop(_auGraph);
    NSLog(@"result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    _isAUGraphRunning = NO;
}

-(void) startPlaying {
    _isPlaying = YES;
    [self startAUGraphIfNecessary];
}

-(void) stopPlaying {
    _isPlaying = NO;
    if (_playbackDatas)
    {
        _playbackDatas = nil;
    }
    [self stopAUGraphIfNecessary];
}

-(void) startRecording {
    _isRecording = YES;
    [self startAUGraphIfNecessary];
}

-(void) startRecording:(id<AudioUnitManagerDelegate>)delegate {
    _delegate = delegate;
    _isRecording = YES;
    [self startAUGraphIfNecessary];
}

-(void) stopRecording {
    _isRecording = NO;
    [self stopAUGraphIfNecessary];
}

+(NSData*) makeInterleavedSteroAudioDataFromMonoData:(const void*)data length:(NSUInteger)length {
    NSUInteger samples = length / sizeof(int16_t);
    int16_t* interleavedData = (int16_t*) malloc(length * 2);
    int16_t* pDst = interleavedData + samples * 2 - 2;
    const int16_t* pSrc = (const int16_t*)data + samples - 1;
    for (NSUInteger i=samples; i>0; --i)
    {
        pDst[0] = *pSrc;
        pDst[1] = *pSrc;
        pDst -= 2;
        pSrc -= 1;
    }
    NSData* ret = [NSData dataWithBytes:interleavedData length:length * 2];
    free(interleavedData);
    return ret;
}

-(void) addAudioData:(const void*)data length:(NSUInteger)length channel:(int)channel {
    if (!_isPlaying) return;
    if (!_playbackDatas) _playbackDatas = [[NSMutableArray alloc] init];
    for (NSUInteger i=_playbackDatas.count; i<=channel; ++i)
    {
        [_playbackDatas addObject:[[NSMutableData alloc] init]];
    }
    NSMutableData* destData = _playbackDatas[channel];
    [destData appendBytes:data length:length];
}

-(void) addAudioData:(NSData*)monoData {
    NSData* steroData = [AudioUnitManager makeInterleavedSteroAudioDataFromMonoData:monoData.bytes length:monoData.length];
    [self addAudioData:steroData.bytes length:steroData.length channel:0];
}

-(void) dealloc {
    [self close];
}

-(instancetype) init {
    if (self = [super init])
    {
        _isAUGraphRunning = NO;
        _isPlaying = NO;
        _isRecording = NO;
        [self open];
    }
    return self;
}

+(instancetype) sharedInstance {
    static AudioUnitManager* singleton = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        singleton = [[AudioUnitManager alloc] init];
    });
    return singleton;
}

@end
