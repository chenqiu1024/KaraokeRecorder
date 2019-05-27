//
//  AudioUnitManager.h
//  KaraokeRecorder
//
//  Created by DOM QIU on 2019/5/27.
//  Copyright © 2019 Cyllenge. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol AudioUnitManagerDelegate <NSObject>

-(void) audioUnitManagerDidReceiveAudioData:(void*)data length:(int)length busNumber:(int)busNumber;
//-(void) audioUnitManagerDidStopRecording;

@end


@interface AudioUnitManager : NSObject

@property (nonatomic, strong) id<AudioUnitManagerDelegate> delegate;

-(void) startPlaying;
-(void) stopPlaying;

-(void) startRecording;
-(void) stopRecording;

@end

NS_ASSUME_NONNULL_END
