//
//  AudioUnitManager.h
//  KaraokeRecorder
//
//  Created by DOM QIU on 2019/5/27.
//  Copyright © 2019 Cyllenge. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@class AudioUnitManager;
@protocol AudioUnitManagerDelegate <NSObject>

-(void) audioUnitManager:(AudioUnitManager*)auMgr didReceiveAudioData:(void*)data length:(int)length channel:(int)channel;

@optional
-(void) audioUnitManager:(AudioUnitManager*)auMgr postFillPlaybackAudioData:(void*)data length:(int)length channel:(int)channel;

@end


@interface AudioUnitManager : NSObject

@property (nonatomic, strong) id<AudioUnitManagerDelegate> delegate;

@property (nonatomic, assign, readonly) float ioSampleRate;
@property (nonatomic, assign, readonly) float audioSourceSampleRate;
@property (nonatomic, assign, readonly) float recordingSampleRate;

+(instancetype) sharedInstance;

-(instancetype) initWithMediaSourceSpec:(AudioStreamBasicDescription)mediaSourceSpec recordingOutputSpec:(AudioStreamBasicDescription)recordingOutputSpec;

-(void) startPlaying;
-(void) startPlayingFromAudioSource:(float)audioSourceSampleRate;
-(void) startPlayingWithCompletionHandler:(void(^)(void))completion;
-(void) startPlaying:(id<AudioUnitManagerDelegate>)delegate;
-(void) stopPlaying;

-(void) startRecording:(id<AudioUnitManagerDelegate>)delegate;
-(void) stopRecording;

-(void) finish;

-(void) addAudioData:(NSData*)monoData;

-(void) addAudioData:(const void*)data length:(NSUInteger)length channel:(int)channel;

+(NSData*) makeInterleavedSteroAudioDataFromMonoData:(const void*)data length:(NSUInteger)length;

-(void) startAUGraphIfNecessary;
-(void) startAUGraphIfNecessary:(float)audioSourceSampleRate;
-(void) stopAUGraphIfNecessary;

@end

NS_ASSUME_NONNULL_END
