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
    AudioUnitManager* _auMgr;
    NSMutableArray<NSMutableData* >* _recordAudioDatas;
}

-(IBAction)onRecordButtonPressed:(id)sender;
-(IBAction)onPlayButtonPressed:(id)sender;

@end

@implementation ViewController

-(void) audioUnitManagerDidReceiveAudioData:(void *)data length:(int)length busNumber:(int)busNumber {
    for (NSUInteger i=_recordAudioDatas.count; i<=busNumber; ++i)
    {
        [_recordAudioDatas addObject:[[NSMutableData alloc] init]];
    }
    NSMutableData* destBuffer = _recordAudioDatas[busNumber];
    [destBuffer appendBytes:data length:length];
}

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
