//
//  main.m — MINHDUC app entry (Fl0rk-style dual mode)
//
//  argv[1] == "-hud"  → HUD overlay process (SpringBoard-hosted window)
//  otherwise          → normal config app UI (Game / Log / Settings tabs)
//
//  Exploit runs ONLY when user taps "Bắt đầu" — never at launch.
//

#import <UIKit/UIKit.h>
#import <string.h>
#import "MainApplication.h"
#import "MainApplicationDelegate.h"

int HUDMainEntry(int argc, char *argv[]); // esp/hud/HUDApp.mm

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "-hud") == 0) {
            return HUDMainEntry(argc, argv);
        }
        return UIApplicationMain(argc, argv,
                                 NSStringFromClass([MainApplication class]),
                                 NSStringFromClass([MainApplicationDelegate class]));
    }
}