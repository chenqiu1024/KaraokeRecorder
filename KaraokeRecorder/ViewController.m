//
//  ViewController.m
//  KaraokeRecorder
//
//  Created by DOM QIU on 2019/5/27.
//  Copyright © 2019 Cyllenge. All rights reserved.
//

#import "ViewController.h"
#import "AudioUnitManager.h"

@interface ViewController ()
{
    AudioUnitManager* _auMgr;
}

//@property (nonatomic, strong) IBOutlet UIButton* recordButton;
//@property (nonatomic, strong) IBOutlet UIButton* playButton;

-(IBAction)onRecordButtonPressed:(id)sender;
-(IBAction)onPlayButtonPressed:(id)sender;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view.
    _auMgr = [[AudioUnitManager alloc] init];
}

-(IBAction)onRecordButtonPressed:(id)sender {
    UIButton* button = (UIButton*) sender;
    if (0 == button.tag)
    {
//        [_auMgr startPlaying];
        button.tag = 1;
        [button setTitle:@"Stop Recording" forState:UIControlStateNormal];
    }
    else if (1 == button.tag)
    {
//        [_auMgr stopPlaying];
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
