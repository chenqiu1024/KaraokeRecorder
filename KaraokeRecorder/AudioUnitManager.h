//
//  AudioUnitManager.h
//  KaraokeRecorder
//
//  Created by DOM QIU on 2019/5/27.
//  Copyright © 2019 Cyllenge. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class AudioUnitManager;
@protocol AudioUnitManagerDelegate <NSObject>

-(void) audioUnitManager:(AudioUnitManager*)auMgr didReceiveAudioData:(void*)data length:(int)length channel:(int)channel;

@optional
-(void) audioUnitManager:(AudioUnitManager*)auMgr willFillPlaybackAudioData:(void*)data length:(int)length channel:(int)channel;

@end


@interface AudioUnitManager : NSObject

@property (nonatomic, strong) id<AudioUnitManagerDelegate> delegate;

@property (nonatomic, assign, readonly) float micphoneSampleRate;
@property (nonatomic, assign, readonly) float audioSourceSampleRate;
@property (nonatomic, assign, readonly) float recorderSampleRate;

-(void) startPlaying;
-(void) stopPlaying;

-(void) startRecording;
-(void) stopRecording;

-(void) addAudioData:(void*)data length:(int)length channel:(int)channel;

+(NSData*) makeInterleavedSteroAudioDataFromMonoData:(const void*)data length:(NSUInteger)length;

@end

NS_ASSUME_NONNULL_END
