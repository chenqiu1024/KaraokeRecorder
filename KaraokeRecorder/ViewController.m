//
//  ViewController.m
//  KaraokeRecorder
//
//  Created by DOM QIU on 2019/5/27.
//  Copyright © 2019 Cyllenge. All rights reserved.
//

#import "ViewController.h"
#import "AudioUnitManager.h"

@interface ViewController () <AudioUnitManagerDelegate>
{
    NSMutableArray<NSMutableData* >* _recordAudioDatas;
}

@property (nonatomic, strong) AudioUnitManager* auMgr;

-(IBAction)onRecordButtonPressed:(id)sender;
-(IBAction)onPlayButtonPressed:(id)sender;

@end

@implementation ViewController

-(void) audioUnitManager:(AudioUnitManager*)auMgr didReceiveAudioData:(void*)data length:(int)length channel:(int)channel {
    for (NSUInteger i=_recordAudioDatas.count; i<=channel; ++i)
    {
        [_recordAudioDatas addObject:[[NSMutableData alloc] init]];
    }
    NSMutableData* destBuffer = _recordAudioDatas[channel];
    [destBuffer appendBytes:data length:length];
}
/*
-(void) audioUnitManager:(AudioUnitManager*)auMgr willFillPlaybackAudioData:(void*)data length:(int)length channel:(int)channel {
    const float Frequencies[] = {660, 420};
    static NSUInteger totalSampleCounts[] = {0, 0};
    int samples = length / 2;
    int16_t* pDst = data;
    for (int iSample=0; iSample<samples; iSample+=2)
    {
        for (int iC=0; iC<2; ++iC)
        {
            float phase = Frequencies[iC] * M_PI * 2 * (++totalSampleCounts[iC]) / auMgr.sampleRate;
            *(pDst++) = (int16_t) (sinf(phase) * 16384);
        }
    }
}
//*/
- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view.
    _auMgr = [[AudioUnitManager alloc] init];
    _auMgr.delegate = self;
}

-(IBAction)onRecordButtonPressed:(id)sender {
    UIButton* button = (UIButton*) sender;
    if (0 == button.tag)
    {
        _recordAudioDatas = [[NSMutableArray alloc] init];
        
        [_auMgr startRecording];
        
        button.tag = 1;
        [button setTitle:@"Stop Recording" forState:UIControlStateNormal];
    }
    else if (1 == button.tag)
    {
        [_auMgr stopRecording];
        
        NSString* docPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
        for (NSUInteger i=0; i<_recordAudioDatas.count; ++i)
        {
            NSString* destPath = [docPath stringByAppendingPathComponent:[NSString stringWithFormat:@"channel%ld.pcm", i]];
            NSData* data = _recordAudioDatas[i];
            [data writeToFile:destPath atomically:YES];
        }
        
        button.tag = 0;
        [button setTitle:@"Start Recording" forState:UIControlStateNormal];
    }
}

-(IBAction)onPlayButtonPressed:(id)sender {
    UIButton* button = (UIButton*) sender;
    if (0 == button.tag)
    {
        [_auMgr startPlaying];
        NSLog(@"#AudioUnit# Start playing");
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSString* docPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
            NSString* srcPath = [docPath stringByAppendingPathComponent:[NSString stringWithFormat:@"channel%d.pcm", 0]];
            if ([[NSFileManager defaultManager] fileExistsAtPath:srcPath])
            {
                NSData* data = [NSData dataWithContentsOfFile:srcPath];
                data = [AudioUnitManager makeInterleavedSteroAudioDataFromMonoData:data.bytes length:data.length];
                [self.auMgr addAudioData:(void*)data.bytes length:(int)data.length channel:0];
            }
            else
            {
                const float Frequencies[] = {660, 420};
                static NSUInteger totalSampleCounts[] = {0, 0};
                int samples = 65536;
                void* data = malloc(samples * 2);
                int16_t* pDst = data;
                for (int iSample=0; iSample<samples; iSample+=2)
                {
                    for (int iC=0; iC<2; ++iC)
                    {
                        float phase = Frequencies[iC] * M_PI * 2 * (++totalSampleCounts[iC]) / self.auMgr.sampleRate;
                        *(pDst++) = (int16_t) (sinf(phase) * 16384);
                    }
                }
                
                [self.auMgr addAudioData:data length:(sizeof(int16_t) * samples) channel:0];
                free(data);
            }
        });
        
        button.tag = 1;
        [button setTitle:@"Stop Playing" forState:UIControlStateNormal];
    }
    else if (1 == button.tag)
    {
        [_auMgr stopPlaying];
        button.tag = 0;
        [button setTitle:@"Start Playing" forState:UIControlStateNormal];
    }
}

@end
