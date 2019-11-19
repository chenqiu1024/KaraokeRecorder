//
//  AudioUnitManager.m
//  KaraokeRecorder
//
//  Created by DOM QIU on 2019/5/27.
//  Copyright © 2019 Cyllenge. All rights reserved.
//

#import "AudioUnitManager.h"
#import "MultiConsumerFIFO.h"
#import <AVFoundation/AVFoundation.h>

#define ENABLE_VERBOSE_AUDIOUNIT_LOGS

#ifdef ENABLE_VERBOSE_AUDIOUNIT_LOGS
#define LOG_V(...) NSLog(__VA_ARGS__)
#else
#define LOG_V(...)
#endif

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

@property (nonatomic, copy) void(^completionHandler)(void);

@property (nonatomic, assign) BOOL isAUGraphRunning;
@property (nonatomic, assign) BOOL isPlaying;
@property (nonatomic, assign) BOOL isRecording;

@property (nonatomic, assign) float ioSampleRate;
@property (nonatomic, assign) float audioSourceSampleRate;
@property (nonatomic, assign) float recordingSampleRate;

@property (nonatomic, assign) AUGraph auGraph;
@property (nonatomic, assign) AudioUnit ioUnit;
@property (nonatomic, assign) AudioUnit mixerUnit;
@property (nonatomic, assign) AudioUnit mediaResampler0Unit_m2r2;
@property (nonatomic, assign) AudioUnit mediaResampler1Unit_r2i2;
@property (nonatomic, assign) AudioUnit recordingResamplerUnit_i2r2;
@property (nonatomic, assign) AudioUnit outResamplerUnit_r2o2;
@property (nonatomic, assign) AudioBufferList* audioBufferList;
@property (nonatomic, strong) NSMutableArray<NSMutableData* >* playbackDatas;

@property (nonatomic, strong) NSArray<MultiConsumerFIFO* >* fifos;

@end

static OSStatus MediaSourceCallbackProc(void* inRefCon
                                     , AudioUnitRenderActionFlags* ioActionFlags
                                     , const AudioTimeStamp* inTimeStamp
                                     , UInt32 inBusNumber
                                     , UInt32 inNumberFrames
                                     , AudioBufferList* __nullable ioData) {
//    LOG_V(@"#AudioUnit# Playback: actionFlags=0x%x, busNumber=%d, frames=%d", *ioActionFlags, inBusNumber, inNumberFrames);
    if (inBusNumber == 1)
        return noErr;

    if (!ioData)
        return noErr;

//    if (!(*ioActionFlags & kAudioUnitRenderAction_PostRender))
//    {//printf("\n#AudioUnit# Playback: return\n");
//        return noErr;
//    }
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
    
    BOOL playOver = NO;
    for (int iBuffer=0; iBuffer<ioData->mNumberBuffers; ++iBuffer)
    {
        AudioBuffer audioBuffer = ioData->mBuffers[iBuffer];
        if (!audioBuffer.mData)
        {
            audioBuffer = auMgr.audioBufferList->mBuffers[iBuffer];
            ioData->mBuffers[iBuffer] = audioBuffer;
        }
        //LOG_V(@"#AudioUnit# inBusNumber=%d, inNumberFrames=%d, audioBuffer[%d].size=%d, .channels=%d", inBusNumber, inNumberFrames, iBuffer, audioBuffer.mDataByteSize, audioBuffer.mNumberChannels);
        NSMutableData* playbackData = (auMgr.playbackDatas && iBuffer < auMgr.playbackDatas.count) ? auMgr.playbackDatas[iBuffer] : nil;
        int consumedByteLength = playbackData ? (int)playbackData.length : 0;
        consumedByteLength = consumedByteLength < audioBuffer.mDataByteSize ? consumedByteLength : audioBuffer.mDataByteSize;
        if (consumedByteLength)
        {
            memcpy(audioBuffer.mData, playbackData.bytes, consumedByteLength);
            [playbackData replaceBytesInRange:NSMakeRange(0, consumedByteLength) withBytes:NULL length:0];
            
            if (playbackData.length == 0)
            {
                LOG_V(@"#AudioUnit# AudioData[%d] EOF", iBuffer);
                playOver = YES;
            }
        }
        memset(audioBuffer.mData + consumedByteLength, 0, audioBuffer.mDataByteSize - consumedByteLength);
        
//        static NSUInteger totalBytesLength = 0;
//        if (iBuffer == 0)
//        {
//            LOG_V(@"#AudioUnit# totalBytesLength=%ld", totalBytesLength);
//            totalBytesLength += audioBuffer.mDataByteSize;
//        }
    }
    
    if (auMgr.delegate && [auMgr.delegate respondsToSelector:@selector(audioUnitManager:postFillPlaybackAudioData:length:channel:)])
    {
        for (int iBuffer=0; iBuffer<ioData->mNumberBuffers; ++iBuffer)
        {
            AudioBuffer audioBuffer = ioData->mBuffers[iBuffer];
            if (!audioBuffer.mData)
            {
                audioBuffer = auMgr.audioBufferList->mBuffers[iBuffer];
                ioData->mBuffers[iBuffer] = audioBuffer;
            }
//            LOG_V(@"#AudioUnit# inBusNumber=%d, inNumberFrames=%d, audioBuffer[%d].size=%d, .channels=%d", inBusNumber, inNumberFrames, iBuffer, audioBuffer.mDataByteSize, audioBuffer.mNumberChannels);
            [auMgr.delegate audioUnitManager:auMgr postFillPlaybackAudioData:audioBuffer.mData length:audioBuffer.mDataByteSize channel:iBuffer];
            
//            static NSUInteger totalBytesLength = 0;
//            if (iBuffer == 0)
//            {
//                LOG_V(@"#AudioUnit# totalBytesLength=%ld", totalBytesLength);
//                totalBytesLength += audioBuffer.mDataByteSize;
//            }
        }
    }
    
    if (playOver && auMgr.completionHandler)
    {
        auMgr.completionHandler();
    }
    
    return noErr;
}

static OSStatus SaveResampledMediaCallbackProc(void* inRefCon
                                  , AudioUnitRenderActionFlags* ioActionFlags
                                  , const AudioTimeStamp* inTimeStamp
                                  , UInt32 inBusNumber
                                  , UInt32 inNumberFrames
                                  , AudioBufferList* __nullable ioData) {
    AudioUnitManager* auMgr = (__bridge AudioUnitManager*) inRefCon;
    if (!auMgr.isPlaying)
        return noErr;
    if (!ioData)
        return noErr;
    if (!(*ioActionFlags & kAudioUnitRenderAction_PostRender))
        return noErr;
    
    for (int i=0; i<ioData->mNumberBuffers; ++i)
    {
        if (!ioData->mBuffers[i].mData) continue;
        [auMgr.fifos[i] appendData:ioData->mBuffers[i].mData length:ioData->mBuffers[i].mDataByteSize overwriteIfFull:YES waitForSpace:NO];
        //static NSUInteger totalBytesLength = 0;
        //if (i == 0)
        //{
        //    LOG_V(@"#AudioUnit# ReSampler: totalBytesLength=%ld, inNumberFrames=%d", totalBytesLength, inNumberFrames);
        //    totalBytesLength += ioData->mBuffers[i].mDataByteSize;
        //}
    }
    //LOG_V(@"#AudioUnit# result=%d, ioActionFlags=0x%x, inBusNumber=%d, inNumberFrames=%d, inTimeStamp=%f, bufferList->mBuffers[0].mData=0x%lx... at %d in %s", result, *ioActionFlags, inBusNumber, inNumberFrames, inTimeStamp->mSampleTime, ((long*) auMgr.audioBufferList->mBuffers[0].mData)[0], __LINE__, __PRETTY_FUNCTION__);
    return noErr;
}

static OSStatus RecordingCallbackProc(void* inRefCon
                                  , AudioUnitRenderActionFlags* ioActionFlags
                                  , const AudioTimeStamp* inTimeStamp
                                  , UInt32 inBusNumber
                                  , UInt32 inNumberFrames
                                  , AudioBufferList* __nullable ioData) {
    AudioUnitManager* auMgr = (__bridge AudioUnitManager*) inRefCon;
//    if (!auMgr.isRecording)
//        return noErr;
    //printf("\n#AudioUnit#.. Resample: actionFlags=%s, (bus, frames)=(%d, %d)\n", AudioUnitRenderActionFlagsString(*ioActionFlags).UTF8String, inBusNumber, inNumberFrames);
    if (!ioData)
        return noErr;
    if (!(*ioActionFlags & kAudioUnitRenderAction_PostRender))
        return noErr;
//    if (!(*ioActionFlags & kAudioUnitRenderAction_PostRender))
//        return noErr;
    
    if (auMgr.isRecording && auMgr.delegate && [auMgr.delegate respondsToSelector:@selector(audioUnitManager:didReceiveAudioData:length:channel:)])
    {
        for (int i=0; i<ioData->mNumberBuffers; ++i)
        {
            if (!ioData->mBuffers[i].mData) continue;
            [auMgr.delegate audioUnitManager:auMgr didReceiveAudioData:ioData->mBuffers[i].mData length:ioData->mBuffers[i].mDataByteSize channel:i];
            
            //static NSUInteger totalBytesLength = 0;
            //if (i == 0)
            //{
            //    LOG_V(@"#AudioUnit# ReSampler: totalBytesLength=%ld, inNumberFrames=%d", totalBytesLength, inNumberFrames);
            //    totalBytesLength += ioData->mBuffers[i].mDataByteSize;
            //}
        }
    }
    return noErr;
}

static OSStatus PlayingCallbackProc(void* inRefCon
                                  , AudioUnitRenderActionFlags* ioActionFlags
                                  , const AudioTimeStamp* inTimeStamp
                                  , UInt32 inBusNumber
                                  , UInt32 inNumberFrames
                                  , AudioBufferList* __nullable ioData) {
    AudioUnitManager* auMgr = (__bridge AudioUnitManager*) inRefCon;
//    if (!auMgr.isRecording)
//        return noErr;
    //printf("\n#AudioUnit#.. Resample: actionFlags=%s, (bus, frames)=(%d, %d)\n", AudioUnitRenderActionFlagsString(*ioActionFlags).UTF8String, inBusNumber, inNumberFrames);
    if (!ioData)
        return noErr;
    if (!(*ioActionFlags & kAudioUnitRenderAction_PostRender))
        return noErr;
    if (!auMgr.isPlaying)
    {
        *ioActionFlags |= kAudioUnitRenderAction_OutputIsSilence;
        for (int iBuffer=0; iBuffer<ioData->mNumberBuffers; ++iBuffer)
        {
            AudioBuffer audioBuffer = ioData->mBuffers[iBuffer];
            if (!audioBuffer.mData) continue;
            memset(audioBuffer.mData, 0, audioBuffer.mDataByteSize);
        }
    }
    else
    {
        for (int i=0; i<ioData->mNumberBuffers; ++i)
        {
            if (!ioData->mBuffers[i].mData) continue;
            [auMgr.fifos[i] pullData:ioData->mBuffers[i].mData length:ioData->mBuffers[i].mDataByteSize consumer:0 waitForComplete:NO];
        }
    }
    return noErr;
}

static OSStatus RecordAndPlayCallbackProc(void* inRefCon
                                  , AudioUnitRenderActionFlags* ioActionFlags
                                  , const AudioTimeStamp* inTimeStamp
                                  , UInt32 inBusNumber
                                  , UInt32 inNumberFrames
                                  , AudioBufferList* __nullable ioData) {
    AudioUnitManager* auMgr = (__bridge AudioUnitManager*) inRefCon;
//    if (!auMgr.isRecording)
//        return noErr;
    //printf("\n#AudioUnit#.. Resample: actionFlags=%s, (bus, frames)=(%d, %d)\n", AudioUnitRenderActionFlagsString(*ioActionFlags).UTF8String, inBusNumber, inNumberFrames);
    if (!ioData)
        return noErr;
    if (!(*ioActionFlags & kAudioUnitRenderAction_PostRender))
        return noErr;
    
    if (auMgr.isRecording && auMgr.delegate && [auMgr.delegate respondsToSelector:@selector(audioUnitManager:didReceiveAudioData:length:channel:)])
    {
        for (int i=0; i<ioData->mNumberBuffers; ++i)
        {
            if (!ioData->mBuffers[i].mData) continue;
            [auMgr.delegate audioUnitManager:auMgr didReceiveAudioData:ioData->mBuffers[i].mData length:ioData->mBuffers[i].mDataByteSize channel:i];
            
            //static NSUInteger totalBytesLength = 0;
            //if (i == 0)
            //{
            //    LOG_V(@"#AudioUnit# ReSampler: totalBytesLength=%ld, inNumberFrames=%d", totalBytesLength, inNumberFrames);
            //    totalBytesLength += ioData->mBuffers[i].mDataByteSize;
            //}
        }
    }
    
    if (!auMgr.isPlaying)
    {
        *ioActionFlags |= kAudioUnitRenderAction_OutputIsSilence;
        for (int iBuffer=0; iBuffer<ioData->mNumberBuffers; ++iBuffer)
        {
            AudioBuffer audioBuffer = ioData->mBuffers[iBuffer];
            if (!audioBuffer.mData) continue;
            memset(audioBuffer.mData, 0, audioBuffer.mDataByteSize);
        }
    }
    else
    {
        for (int i=0; i<ioData->mNumberBuffers; ++i)
        {
            if (!ioData->mBuffers[i].mData) continue;
            [auMgr.fifos[i] pullData:ioData->mBuffers[i].mData length:ioData->mBuffers[i].mDataByteSize consumer:0 waitForComplete:NO];
        }
    }
    
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
    
    for (MultiConsumerFIFO* fifo in _fifos)
    {
        [fifo finish];
    }
    _fifos = nil;
    
    _playbackDatas = nil;
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

-(void) openWithMediaSourceSpec:(AudioStreamBasicDescription)mediaInputASBD recordingOutputSpec:(AudioStreamBasicDescription)recordOutputASBD {
    /// Sample rate 8000Hz is NG for Bluetooth headphone, WHY?
    /// Presume that the audio recording samplerate is the same as playback samplerate
    double preferredHardwareSampleRate;
    if ([[AVAudioSession sharedInstance] respondsToSelector:@selector(sampleRate)])
    {
        preferredHardwareSampleRate = [[AVAudioSession sharedInstance] sampleRate];
    }
    else
    {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        preferredHardwareSampleRate = [[AVAudioSession sharedInstance] currentHardwareSampleRate];
#pragma clang diagnostic pop
    }
    preferredHardwareSampleRate = 8000.f;///!!!
    _ioSampleRate = preferredHardwareSampleRate;
    
    _recordingSampleRate = recordOutputASBD.mSampleRate;
    _audioSourceSampleRate = mediaInputASBD.mSampleRate;
    
    int numBuffers = 2;
    _audioBufferList = (AudioBufferList*) malloc(sizeof(AudioBufferList) + sizeof(AudioBuffer) * (numBuffers - 1));
    _audioBufferList->mNumberBuffers = numBuffers;
    for (int i=0; i<numBuffers; ++i)
    {
        _audioBufferList->mBuffers[i].mNumberChannels = 1;
        _audioBufferList->mBuffers[i].mDataByteSize = 4096;
        _audioBufferList->mBuffers[i].mData = malloc(_audioBufferList->mBuffers[i].mDataByteSize);
        memset(_audioBufferList->mBuffers[i].mData, 0, _audioBufferList->mBuffers[i].mDataByteSize);
    }
    
    MultiConsumerFIFO* fifo0 = [[MultiConsumerFIFO alloc] initWithCapacity:64000 slaveConsumers:0];
    MultiConsumerFIFO* fifo1 = [[MultiConsumerFIFO alloc] initWithCapacity:64000 slaveConsumers:0];
    _fifos = @[fifo0, fifo1];
    
    // Set all AudioComponentDescription(s):
    AudioComponentDescription ioACDesc, resamplerACDesc, mixerACDesc;
    ioACDesc.componentType = kAudioUnitType_Output;
    // kAudioUnitSubType_VoiceProcessingIO enables echo cancellation, but mixes the stero channels as mono sound
//    ioACDesc.componentSubType = kAudioUnitSubType_VoiceProcessingIO;
    ioACDesc.componentSubType = kAudioUnitSubType_RemoteIO;
    ioACDesc.componentManufacturer = kAudioUnitManufacturer_Apple;
    ioACDesc.componentFlags = 0;
    ioACDesc.componentFlagsMask = 0;
    
    resamplerACDesc.componentType = kAudioUnitType_FormatConverter;
    resamplerACDesc.componentSubType = kAudioUnitSubType_AUConverter;
    resamplerACDesc.componentFlags = 0;
    resamplerACDesc.componentFlagsMask = 0;
    resamplerACDesc.componentManufacturer = kAudioUnitManufacturer_Apple;
    
    mixerACDesc.componentType = kAudioUnitType_Mixer;
    mixerACDesc.componentSubType = kAudioUnitSubType_MultiChannelMixer;
    mixerACDesc.componentFlags = 0;
    mixerACDesc.componentFlagsMask = 0;
    mixerACDesc.componentManufacturer = kAudioUnitManufacturer_Apple;
    
    // Create the AUGraph:
    OSStatus result;
    AUNode ioNode, mixerNode;
    AUNode mediaResampler0Node_m2r2;
    AUNode mediaResampler1Node_r2i2;
    AUNode recordingResamplerNode_i2r2;
    AUNode outResamplerNode_r2o2;
    result = NewAUGraph(&_auGraph);
    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    // Add AUNode(s):
    result = AUGraphAddNode(_auGraph, &ioACDesc, &ioNode);
    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    result = AUGraphAddNode(_auGraph, &resamplerACDesc, &mediaResampler0Node_m2r2);
    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    result = AUGraphAddNode(_auGraph, &resamplerACDesc, &mediaResampler1Node_r2i2);
    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    result = AUGraphAddNode(_auGraph, &resamplerACDesc, &recordingResamplerNode_i2r2);
    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    result = AUGraphAddNode(_auGraph, &resamplerACDesc, &outResamplerNode_r2o2);
    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    result = AUGraphAddNode(_auGraph, &mixerACDesc, &mixerNode);
    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    // Connect the nodes:
    AUGraphConnectNodeInput(_auGraph, ioNode, 1, mixerNode, 1);
    AUGraphConnectNodeInput(_auGraph, mediaResampler0Node_m2r2, 0, mediaResampler1Node_r2i2, 0);
    AUGraphConnectNodeInput(_auGraph, mediaResampler1Node_r2i2, 0, mixerNode, 0);
    AUGraphConnectNodeInput(_auGraph, mixerNode, 0, recordingResamplerNode_i2r2, 0);
    AUGraphConnectNodeInput(_auGraph, recordingResamplerNode_i2r2, 0, outResamplerNode_r2o2, 0);
    AUGraphConnectNodeInput(_auGraph, outResamplerNode_r2o2, 0, ioNode, 0);
    // Open the AUGraph, but it is not initialized(allocate resources) at this point:
    result = AUGraphOpen(_auGraph);
    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    // Get the AudioUnit info:
    result = AUGraphNodeInfo(_auGraph, ioNode, &ioACDesc, &_ioUnit);
    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    result = AUGraphNodeInfo(_auGraph, mediaResampler0Node_m2r2, &resamplerACDesc, &_mediaResampler0Unit_m2r2);
    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    result = AUGraphNodeInfo(_auGraph, mediaResampler1Node_r2i2, &resamplerACDesc, &_mediaResampler1Unit_r2i2);
    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    result = AUGraphNodeInfo(_auGraph, mixerNode, &mixerACDesc, &_mixerUnit);
    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    result = AUGraphNodeInfo(_auGraph, recordingResamplerNode_i2r2, &resamplerACDesc, &_recordingResamplerUnit_i2r2);
    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    result = AUGraphNodeInfo(_auGraph, outResamplerNode_r2o2, &resamplerACDesc, &_outResamplerUnit_r2o2);
    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    
    UInt32 flag = 1;
    result = AudioUnitSetProperty(_ioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &flag, sizeof(flag));
    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    result = AudioUnitSetProperty(_ioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &flag, sizeof(flag));
    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    
    // Set all AudioStreamBasicDescription(s):
    AudioStreamBasicDescription ioInputASBD;
    ioInputASBD.mSampleRate = _ioSampleRate;
    ioInputASBD.mFormatID = kAudioFormatLinearPCM;
    // kAudioFormatFlagIsNonInterleaved will create 1 AudioBuffer for each channel, while kAudioFormatFlagIsPacked will create 1 interleaved AudioBuffer for all 2 channels:
    ioInputASBD.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    ioInputASBD.mFramesPerPacket = 1;
    ioInputASBD.mChannelsPerFrame = 1;
    ioInputASBD.mBitsPerChannel = 16;
    
    ioInputASBD.mBytesPerFrame = ioInputASBD.mBitsPerChannel * ioInputASBD.mChannelsPerFrame / 8;
    ioInputASBD.mBytesPerPacket = ioInputASBD.mBytesPerFrame * ioInputASBD.mFramesPerPacket;
    
    AudioStreamBasicDescription ioOutputASBD = ioInputASBD;
    ioOutputASBD.mSampleRate = _ioSampleRate;
    ioOutputASBD.mChannelsPerFrame = 2;///
    ioOutputASBD.mBytesPerFrame = ioOutputASBD.mBitsPerChannel * ioOutputASBD.mChannelsPerFrame / 8;
    ioOutputASBD.mBytesPerPacket = ioOutputASBD.mBytesPerFrame * ioOutputASBD.mFramesPerPacket;
    
//    AudioStreamBasicDescription mediaResampler0InputASBD_m2;
//    mediaResampler0InputASBD_m2.mSampleRate = _audioSourceSampleRate;
//    mediaResampler0InputASBD_m2.mFormatID = kAudioFormatLinearPCM;
//    mediaResampler0InputASBD_m2.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
//    mediaResampler0InputASBD_m2.mFramesPerPacket = 1;
//    mediaResampler0InputASBD_m2.mChannelsPerFrame = 2;
//    mediaResampler0InputASBD_m2.mBitsPerChannel = 16;
//
//    mediaResampler0InputASBD_m2.mBytesPerFrame = mediaResampler0InputASBD_m2.mBitsPerChannel * mediaResampler0InputASBD_m2.mChannelsPerFrame / 8;
//    mediaResampler0InputASBD_m2.mBytesPerPacket = mediaResampler0InputASBD_m2.mBytesPerFrame * mediaResampler0InputASBD_m2.mFramesPerPacket;
//
//    AudioStreamBasicDescription mediaResampler0OutputASBD_r2 = mediaResampler0InputASBD_m2;
//    mediaResampler0OutputASBD_r2.mSampleRate = _recordingSampleRate;
    AudioStreamBasicDescription mediaResampler0InputASBD_m2 = mediaInputASBD;
    AudioStreamBasicDescription mediaResampler0OutputASBD_r2 = recordOutputASBD;
    
    AudioStreamBasicDescription mediaResampler1OutputASBD_i2 = mediaResampler0OutputASBD_r2;
    mediaResampler1OutputASBD_i2.mSampleRate = _ioSampleRate;
    
    AudioStreamBasicDescription recordingResamplerInputASBD_i2 = mediaResampler1OutputASBD_i2;
    AudioStreamBasicDescription recordingResamplerOutputASBD_r2 = recordingResamplerInputASBD_i2;
    recordingResamplerOutputASBD_r2.mSampleRate = _recordingSampleRate;
    
    AudioStreamBasicDescription outResamplerInputASBD_r2 = recordingResamplerOutputASBD_r2;
    
    result = AudioUnitSetProperty(_ioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &ioInputASBD, sizeof(ioInputASBD));
    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    // kAudioUnitScope_Input of element 0 of IO unit represents the input of Speaker:
    result = AudioUnitSetProperty(_ioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &ioOutputASBD, sizeof(ioOutputASBD));
    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
//    result = AudioUnitSetProperty(_resampler4MicUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &resampler4MicOutputASBD, sizeof(resampler4MicOutputASBD));
//    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    result = AudioUnitSetProperty(_mediaResampler0Unit_m2r2, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &mediaResampler0InputASBD_m2, sizeof(mediaResampler0InputASBD_m2));
    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    result = AudioUnitSetProperty(_mediaResampler0Unit_m2r2, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &mediaResampler0OutputASBD_r2, sizeof(mediaResampler0OutputASBD_r2));
    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    result = AudioUnitSetProperty(_mediaResampler1Unit_r2i2, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &mediaResampler1OutputASBD_i2, sizeof(mediaResampler1OutputASBD_i2));
    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    result = AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &recordingResamplerInputASBD_i2, sizeof(recordingResamplerInputASBD_i2));
    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    result = AudioUnitSetProperty(_recordingResamplerUnit_i2r2, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &recordingResamplerInputASBD_i2, sizeof(recordingResamplerInputASBD_i2));
    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    result = AudioUnitSetProperty(_recordingResamplerUnit_i2r2, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &recordingResamplerOutputASBD_r2, sizeof(recordingResamplerOutputASBD_r2));
    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    result = AudioUnitSetProperty(_outResamplerUnit_r2o2, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &outResamplerInputASBD_r2, sizeof(outResamplerInputASBD_r2));
    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    
    // Not quite clear about what these settings are for:
    //flag = 0;
    //result = AudioUnitSetProperty(_ioUnit, kAudioUnitProperty_ShouldAllocateBuffer, kAudioUnitScope_Output, 1, &flag, sizeof(flag));
    //LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    
    UInt32 maximumFramesPerSlice = 2048;
    result = AudioUnitSetProperty(_ioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 1, &maximumFramesPerSlice, sizeof(maximumFramesPerSlice));
    
    AURenderCallbackStruct mediaSourceCallback;
    mediaSourceCallback.inputProc = MediaSourceCallbackProc;
    mediaSourceCallback.inputProcRefCon = (__bridge void* _Nullable) self;
    // Both the following 2 lines work for IO node output:
    //result = AudioUnitSetProperty(_ioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Global, 0, &mediaSourceCallback, sizeof(mediaSourceCallback));
    //result = AUGraphSetNodeInputCallback(_auGraph, ioNode, 0, &mediaSourceCallback);
//    result = AudioUnitAddRenderNotify(_resampler4MediaUnit, MediaSourceCallbackProc, (__bridge void* _Nullable) self);///!!!
//    result = AudioUnitSetProperty(_resampler4MediaUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Global, 0, &mediaSourceCallback, sizeof(mediaSourceCallback));///!!!
    result = AUGraphSetNodeInputCallback(_auGraph, mediaResampler0Node_m2r2, 0, &mediaSourceCallback);///!!!
//    result = AudioUnitAddRenderNotify(_resampler4MicUnit, MediaSourceCallbackProc, (__bridge void* _Nullable) self);///!!!
    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    /*
    AURenderCallbackStruct inputCallback;
    inputCallback.inputProc = InputCallbackProc;
    inputCallback.inputProcRefCon = (__bridge void* _Nullable) self;
    //result = AudioUnitSetProperty(_ioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &inputCallback, sizeof(inputCallback));
    result = AudioUnitAddRenderNotify(_ioUnit, InputCallbackProc, (__bridge void* _Nullable) self);
    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    //*/
    result = AudioUnitAddRenderNotify(_recordingResamplerUnit_i2r2, RecordAndPlayCallbackProc, (__bridge void* _Nullable) self);///!!!
    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    
    result = AudioUnitAddRenderNotify(_mediaResampler0Unit_m2r2, SaveResampledMediaCallbackProc, (__bridge void* _Nullable) self);///!!!
    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    
//    result = AudioUnitAddRenderNotify(_ioUnit, PlayingCallbackProc, (__bridge void* _Nullable) self);///!!!
//    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    
    result = AUGraphInitialize(_auGraph);
    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
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
    
    [audioSession setCategory:AVAudioSessionCategoryPlayAndRecord withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker|AVAudioSessionCategoryOptionAllowBluetooth|AVAudioSessionCategoryOptionAllowBluetoothA2DP error:nil];///!!!
    [audioSession setPreferredSampleRate:_ioSampleRate error:nil];
    [audioSession setPreferredIOBufferDuration:0.064 error:nil];
    /* Only valid with AVAudioSessionCategoryPlayAndRecord.  Appropriate for Voice over IP
     (VoIP) applications.  Reduces the number of allowable audio routes to be only those
     that are appropriate for VoIP applications and may engage appropriate system-supplied
     signal processing.  Has the side effect of setting AVAudioSessionCategoryOptionAllowBluetooth */
    [audioSession setMode:AVAudioSessionModeVideoRecording error:nil];///!!!
//    [audioSession setMode:AVAudioSessionModeVoiceChat error:nil];///!!!
    [audioSession setActive:YES error:nil];
    
    [self startAUGraphIfNecessary];///!!!
}

-(void) startAUGraphIfNecessary {
    if (_isAUGraphRunning || !_auGraph)
        return;
    
    OSStatus result = AUGraphStart(_auGraph);
    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    _isAUGraphRunning = YES;
}

-(void) startAUGraphIfNecessary:(float)audioSourceSampleRate {
    if (!_auGraph)
        return;
    
    OSStatus result;
    if (_isAUGraphRunning)
    {
        result = AUGraphStop(_auGraph);
        LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    }
    
    _audioSourceSampleRate = audioSourceSampleRate;
    AudioStreamBasicDescription resampler4Media0InputASBD;
    resampler4Media0InputASBD.mSampleRate = _audioSourceSampleRate;
    resampler4Media0InputASBD.mFormatID = kAudioFormatLinearPCM;
    resampler4Media0InputASBD.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    resampler4Media0InputASBD.mFramesPerPacket = 1;
    resampler4Media0InputASBD.mChannelsPerFrame = 2;
    resampler4Media0InputASBD.mBitsPerChannel = 16;
    
    resampler4Media0InputASBD.mBytesPerFrame = resampler4Media0InputASBD.mBitsPerChannel * resampler4Media0InputASBD.mChannelsPerFrame / 8;
    resampler4Media0InputASBD.mBytesPerPacket = resampler4Media0InputASBD.mBytesPerFrame * resampler4Media0InputASBD.mFramesPerPacket;
    result = AudioUnitSetProperty(_mediaResampler0Unit_m2r2, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &resampler4Media0InputASBD, sizeof(resampler4Media0InputASBD));
    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    
    result = AUGraphStart(_auGraph);
    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    _isAUGraphRunning = YES;
}

-(void) stopAUGraphIfNecessary {
    if (!_isAUGraphRunning || !_auGraph)
        return;
    
//    if (_isPlaying || _isRecording)
//        return;
    
    OSStatus result = AUGraphStop(_auGraph);
    LOG_V(@"#AudioUnit# result=%d. at %d in %s", result, __LINE__, __PRETTY_FUNCTION__);
    _isAUGraphRunning = NO;
}

-(void) startPlaying {
    if (_playbackDatas)
    {
        _playbackDatas = nil;
    }
    _isPlaying = YES;
    [self startAUGraphIfNecessary];
}

-(void) startPlayingFromAudioSource:(float)audioSourceSampleRate {
    if (_playbackDatas)
    {
        _playbackDatas = nil;
    }
    _isPlaying = YES;
    [self startAUGraphIfNecessary:audioSourceSampleRate];
}

-(void) startPlayingWithCompletionHandler:(void(^)(void))completion {
    _completionHandler = completion;
    _isPlaying = YES;
    [self startAUGraphIfNecessary];
}

-(void) startPlaying:(id<AudioUnitManagerDelegate>)delegate {
    if (_playbackDatas)
    {
        _playbackDatas = nil;
    }
    _delegate = delegate;
    _isPlaying = YES;
    [self startAUGraphIfNecessary];
}

-(void) stopPlaying {
    _isPlaying = NO;
    if (_playbackDatas)
    {
        _playbackDatas = nil;
    }
//    [self stopAUGraphIfNecessary];
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
//    [self stopAUGraphIfNecessary];
}

-(void) finish {
    [self close];
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
//    if (!_isPlaying) return;
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

-(instancetype) initWithMediaSourceSpec:(AudioStreamBasicDescription)mediaSourceSpec recordingOutputSpec:(AudioStreamBasicDescription)recordingOutputSpec {
    if (self = [super init])
    {
        _isAUGraphRunning = NO;
        _isPlaying = NO;
        _isRecording = NO;
        [self openWithMediaSourceSpec:mediaSourceSpec recordingOutputSpec:recordingOutputSpec];
    }
    return self;
}

-(instancetype) init {
    if (self = [super init])
    {
        _isAUGraphRunning = NO;
        _isPlaying = NO;
        _isRecording = NO;
        
        _audioSourceSampleRate = 16000.f;
        _recordingSampleRate = 16000.f;
        
        AudioStreamBasicDescription mediaResampler0InputASBD_m2;
        mediaResampler0InputASBD_m2.mSampleRate = _audioSourceSampleRate;
        mediaResampler0InputASBD_m2.mFormatID = kAudioFormatLinearPCM;
        mediaResampler0InputASBD_m2.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        mediaResampler0InputASBD_m2.mFramesPerPacket = 1;
        mediaResampler0InputASBD_m2.mChannelsPerFrame = 2;
        mediaResampler0InputASBD_m2.mBitsPerChannel = 16;
        
        mediaResampler0InputASBD_m2.mBytesPerFrame = mediaResampler0InputASBD_m2.mBitsPerChannel * mediaResampler0InputASBD_m2.mChannelsPerFrame / 8;
        mediaResampler0InputASBD_m2.mBytesPerPacket = mediaResampler0InputASBD_m2.mBytesPerFrame * mediaResampler0InputASBD_m2.mFramesPerPacket;
        
        AudioStreamBasicDescription mediaResampler0OutputASBD_r2 = mediaResampler0InputASBD_m2;
        mediaResampler0OutputASBD_r2.mSampleRate = _recordingSampleRate;
        
        [self openWithMediaSourceSpec:mediaResampler0InputASBD_m2 recordingOutputSpec:mediaResampler0OutputASBD_r2];
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
