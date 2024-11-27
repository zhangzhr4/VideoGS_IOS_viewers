//
//  OpencvTest.h
//  MetalSplat
//
//  Created by WH X on 2024/4/29.
//

#ifndef OpencvTest_h
#define OpencvTest_h

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

@interface OpencvTest : NSObject

//    + (UIImage *)processImage:(UIImage*)inputImage;
    + (NSArray<UIImage *> *)processVideo:(NSString *)url frameRate:(NSInteger)frameRate;

@end

#endif /* OpencvTest_h */
