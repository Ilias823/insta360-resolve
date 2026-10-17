// MediaTool: the video work the import needs, done with macOS's own AVFoundation, so that
// importing clips needs no ffmpeg. It ships inside the plugin bundle next to TrackProgress.
//
//   MediaTool probe <clip>                   video streams and duration, as JSON
//   MediaTool split <clip> <lensA> <lensB>   copy each video stream to its own .mov, without
//                                            re-encoding; prints "progress <0..1>" lines
//   MediaTool frame <video> <seconds> <size> one frame scaled to size x size, raw 8-bit RGB on stdout
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>

#include <cstdio>
#include <unistd.h>
#include <vector>

// AVFoundation goes by the file extension, and does not know Insta360's .insv (which is an
// ordinary MP4 inside). A temporary link with an .mp4 name lets it open the file.
static AVURLAsset* OpenAsset(NSString* p_Path)
{
    NSURL* url = [NSURL fileURLWithPath:p_Path].URLByStandardizingPath; // absolute, for the link below
    NSString* ext = p_Path.pathExtension.lowercaseString;
    if (![ext isEqualToString:@"mov"] && ![ext isEqualToString:@"mp4"])
    {
        NSString* link = [NSTemporaryDirectory() stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"mediatool-%d-%@.mp4", getpid(), NSUUID.UUID.UUIDString]];
        if ([NSFileManager.defaultManager createSymbolicLinkAtPath:link withDestinationPath:url.path error:nil])
        {
            url = [NSURL fileURLWithPath:link];
            atexit_b(^{
                [NSFileManager.defaultManager removeItemAtPath:link error:nil];
            });
        }
    }
    return [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
}

static NSArray<AVAssetTrack*>* VideoTracks(AVURLAsset* p_Asset)
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [p_Asset tracksWithMediaType:AVMediaTypeVideo];
#pragma clang diagnostic pop
}

static int Fail(NSString* p_Message)
{
    fprintf(stderr, "%s\n", p_Message.UTF8String);
    return 1;
}

static int Probe(NSString* p_Path)
{
    AVURLAsset* asset = OpenAsset(p_Path);
    NSArray<AVAssetTrack*>* tracks = VideoTracks(asset);
    if (tracks.count == 0)
    {
        return Fail([NSString stringWithFormat:@"no video found in %@", p_Path.lastPathComponent]);
    }

    NSMutableArray* streams = [NSMutableArray array];
    for (NSUInteger i = 0; i < tracks.count; ++i)
    {
        AVAssetTrack* track = tracks[i];
        // Frame rate as an exact fraction (30000/1001), from the duration of one frame.
        const CMTime frame = track.minFrameDuration;
        NSString* rate = CMTIME_IS_VALID(frame) && frame.value > 0
                             ? [NSString stringWithFormat:@"%d/%lld", frame.timescale, frame.value]
                             : [NSString stringWithFormat:@"%.0f/1", track.nominalFrameRate];
        long long frames = 0;
        if (track.canProvideSampleCursors)
        {
            AVSampleCursor* cursor = [track makeSampleCursorAtFirstSampleInDecodeOrder];
            frames = cursor ? 1 + [cursor stepInDecodeOrderByCount:INT64_MAX] : 0;
        }
        if (frames <= 0)
        {
            frames = llround(CMTimeGetSeconds(track.timeRange.duration) * track.nominalFrameRate);
        }
        [streams addObject:@{@"index": @(i), @"width": @(llround(track.naturalSize.width)),
                             @"height": @(llround(track.naturalSize.height)), @"r_frame_rate": rate,
                             @"nb_frames": @(frames)}];
    }
    NSDictionary* result = @{@"duration": @(CMTimeGetSeconds(asset.duration)), @"streams": streams};
    NSData* json = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    fwrite(json.bytes, 1, json.length, stdout);
    printf("\n");
    return 0;
}

static int Split(NSString* p_Path, NSArray<NSString*>* p_Outputs)
{
    AVURLAsset* asset = OpenAsset(p_Path);
    NSArray<AVAssetTrack*>* tracks = VideoTracks(asset);
    if (tracks.count != p_Outputs.count)
    {
        return Fail([NSString stringWithFormat:@"%@: expected %lu video streams, found %lu", p_Path.lastPathComponent,
                     (unsigned long)p_Outputs.count, (unsigned long)tracks.count]);
    }

    // One passthrough export per lens, both running at once: the samples are copied, not re-encoded.
    NSMutableArray<AVAssetExportSession*>* sessions = [NSMutableArray array];
    for (NSUInteger i = 0; i < tracks.count; ++i)
    {
        AVMutableComposition* composition = [AVMutableComposition composition];
        AVMutableCompositionTrack* lane = [composition addMutableTrackWithMediaType:AVMediaTypeVideo
                                                                   preferredTrackID:kCMPersistentTrackID_Invalid];
        NSError* error = nil;
        if (![lane insertTimeRange:tracks[i].timeRange ofTrack:tracks[i] atTime:kCMTimeZero error:&error])
        {
            return Fail([NSString stringWithFormat:@"cannot read lens %lu: %@", (unsigned long)i + 1, error.localizedDescription]);
        }
        AVAssetExportSession* session = [AVAssetExportSession exportSessionWithAsset:composition
                                                                          presetName:AVAssetExportPresetPassthrough];
        session.outputURL = [NSURL fileURLWithPath:p_Outputs[i]];
        session.outputFileType = AVFileTypeQuickTimeMovie;
        [NSFileManager.defaultManager removeItemAtPath:p_Outputs[i] error:nil];
        [sessions addObject:session];
    }

    dispatch_group_t group = dispatch_group_create();
    for (AVAssetExportSession* session in sessions)
    {
        dispatch_group_enter(group);
        [session exportAsynchronouslyWithCompletionHandler:^{
            dispatch_group_leave(group);
        }];
    }
    while (dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) != 0)
    {
        float done = 0.0f;
        for (AVAssetExportSession* session in sessions)
        {
            done += session.progress / sessions.count;
        }
        printf("progress %.4f\n", done);
        fflush(stdout);
    }

    for (AVAssetExportSession* session in sessions)
    {
        if (session.status != AVAssetExportSessionStatusCompleted)
        {
            return Fail([NSString stringWithFormat:@"copying %@ failed: %@", session.outputURL.lastPathComponent,
                         session.error.localizedDescription ?: @"unknown error"]);
        }
    }
    printf("progress 1.0000\n");
    return 0;
}

static int Frame(NSString* p_Path, double p_Seconds, int p_Size)
{
    AVURLAsset* asset = OpenAsset(p_Path);
    AVAssetImageGenerator* generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    generator.requestedTimeToleranceBefore = kCMTimeZero;
    generator.requestedTimeToleranceAfter = kCMTimeZero;
    generator.appliesPreferredTrackTransform = NO;

    NSError* error = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CGImageRef image = [generator copyCGImageAtTime:CMTimeMakeWithSeconds(p_Seconds, 600000) actualTime:nil error:&error];
#pragma clang diagnostic pop
    if (!image)
    {
        return Fail([NSString stringWithFormat:@"cannot read a frame at %.3f s: %@", p_Seconds, error.localizedDescription]);
    }

    // Scale into an RGBX buffer, then drop the unused byte.
    std::vector<unsigned char> rgbx(size_t(p_Size) * p_Size * 4), rgb(size_t(p_Size) * p_Size * 3);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(rgbx.data(), p_Size, p_Size, 8, size_t(p_Size) * 4, space,
                                                 kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, CGRectMake(0, 0, p_Size, p_Size), image);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    CGImageRelease(image);

    for (size_t i = 0; i < size_t(p_Size) * p_Size; ++i)
    {
        rgb[i * 3] = rgbx[i * 4];
        rgb[i * 3 + 1] = rgbx[i * 4 + 1];
        rgb[i * 3 + 2] = rgbx[i * 4 + 2];
    }
    return fwrite(rgb.data(), 1, rgb.size(), stdout) == rgb.size() ? 0 : 1;
}

int main(int argc, const char** argv)
{
    @autoreleasepool
    {
        NSString* command = argc > 1 ? @(argv[1]) : @"";
        if ([command isEqualToString:@"probe"] && argc == 3)
        {
            return Probe(@(argv[2]));
        }
        if ([command isEqualToString:@"split"] && argc >= 5)
        {
            NSMutableArray* outputs = [NSMutableArray array];
            for (int i = 3; i < argc; ++i)
            {
                [outputs addObject:@(argv[i])];
            }
            return Split(@(argv[2]), outputs);
        }
        if ([command isEqualToString:@"frame"] && argc == 5)
        {
            return Frame(@(argv[2]), atof(argv[3]), atoi(argv[4]));
        }
        fprintf(stderr, "usage: MediaTool probe <clip> | split <clip> <out1> <out2> | frame <video> <seconds> <size>\n");
        return 2;
    }
}
