//
//  OpencvTest.m
//  MetalSplat
//
//  Created by WH X on 2024/4/29.
//

#include <opencv2/opencv.hpp>
#include "OpencvTest.h"


using namespace cv;
using namespace std;

@implementation OpencvTest : NSObject
+ (void)checkURLAccessibility:(NSString *)url completion:(void (^)(BOOL accessible))completionHandler {
    NSURL *requestURL = [NSURL URLWithString:url];
    NSURLSession *session = [NSURLSession sharedSession];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requestURL];
    [request setHTTPMethod:@"HEAD"];

    NSURLSessionDataTask *dataTask = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse && httpResponse.statusCode == 200) {
            completionHandler(YES);
        } else {
            completionHandler(NO);
        }
    }];
    [dataTask resume];
}

+ (NSArray<UIImage *> *)processVideo:(NSString *)url frameRate:(NSInteger)frameRate {
    
    NSString *filePath = [[NSBundle mainBundle] pathForResource:url ofType:nil];
//    NSString *filePath = url;

    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        NSLog(@"Video file does not exist at the specified bundle path.");
        return @[];
    }
    
//    NSLog(filePath);
    
    std::string urllink = [filePath UTF8String];
    
//    std::string urllink = [url UTF8String];
    
    cv::VideoCapture videoCapture(urllink);
    if (!videoCapture.isOpened()) {
        NSLog(@"Failed to open video URL.");
        return @[];
    }
    
    videoCapture.set(cv::CAP_PROP_FPS, frameRate);
    
    cv::Mat frame;
    NSMutableArray<UIImage *> *images = [NSMutableArray array];
    while (videoCapture.read(frame)) {
        cv::cvtColor(frame, frame, cv::COLOR_BGR2GRAY);
        
        NSData *data = [NSData dataWithBytes:frame.data length:frame.total() * frame.elemSize()];
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceGray();
        CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
        CGImageRef imageRef = CGImageCreate(frame.cols, frame.rows, 8, 8 * frame.elemSize(),
                                            frame.step[0], colorSpace, kCGBitmapByteOrderDefault, provider, NULL, false,
                                            kCGRenderingIntentDefault);
        
        UIImage *image = [UIImage imageWithCGImage:imageRef];
        [images addObject:image];
        
        CGImageRelease(imageRef);
        CGDataProviderRelease(provider);
        CGColorSpaceRelease(colorSpace);
    }
    
    return [images copy];
}

//+ (void)processVideo:(NSString *)url frameRate:(NSInteger)frameRate completion:(void (^)(NSArray<UIImage *> *))completion {
//    NSURL *videoURL = [NSURL URLWithString:url];
//    NSURLSessionDownloadTask *downloadTask = [[NSURLSession sharedSession] downloadTaskWithURL:videoURL completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
//        if (error) {
//            NSLog(@"Download error: %@", error);
//            dispatch_async(dispatch_get_main_queue(), ^{
//                completion(@[]);
//            });
//            return;
//        }
//
//        NSString *localPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[response suggestedFilename]];
//        NSError *fileError;
//        [[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:localPath] error:&fileError];
//
//        if (fileError) {
//            NSLog(@"File error: %@", fileError);
//            dispatch_async(dispatch_get_main_queue(), ^{
//                completion(@[]);
//            });
//            return;
//        }
//
//        std::string urllink = [localPath UTF8String];
//        cv::VideoCapture videoCapture(urllink);
//        if (!videoCapture.isOpened()) {
//            NSLog(@"Failed to open video URL.");
//            dispatch_async(dispatch_get_main_queue(), ^{
//                completion(@[]);
//            });
//            return;
//        }
//
//        videoCapture.set(cv::CAP_PROP_FPS, frameRate);
//
//        cv::Mat frame;
//        NSMutableArray<UIImage *> *images = [NSMutableArray array];
//        while (videoCapture.read(frame)) {
//            cv::cvtColor(frame, frame, cv::COLOR_BGR2GRAY);
//
//            NSData *data = [NSData dataWithBytes:frame.data length:frame.total() * frame.elemSize()];
//            CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceGray();
//            CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
//            CGImageRef imageRef = CGImageCreate(frame.cols, frame.rows, 8, 8 * frame.elemSize(), frame.step[0], colorSpace, kCGBitmapByteOrderDefault, provider, NULL, false, kCGRenderingIntentDefault);
//
//            UIImage *image = [UIImage imageWithCGImage:imageRef];
//            [images addObject:image];
//
//            CGImageRelease(imageRef);
//            CGDataProviderRelease(provider);
//            CGColorSpaceRelease(colorSpace);
//        }
//
//        [[NSFileManager defaultManager] removeItemAtPath:localPath error:nil];
//        dispatch_async(dispatch_get_main_queue(), ^{
//            completion([images copy]);
//        });
//    }];
//    [downloadTask resume];
//}

@end
