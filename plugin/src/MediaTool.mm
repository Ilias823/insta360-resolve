// MediaTool: the video work the import needs, done with macOS's own AVFoundation, so that
// importing clips needs no ffmpeg. It ships inside the plugin bundle next to TrackProgress.
//
//   MediaTool probe <clip>                   video streams and duration, as JSON
//   MediaTool split <clip> <lensA> <lensB>   copy each video stream to its own .mov, without
//                                            re-encoding; the clip's sound goes with lens A;
//                                            prints "progress <0..1>" lines
//   MediaTool frame <video> <seconds> <size> one frame scaled to size x size, raw 8-bit RGB on stdout
//   MediaTool still <image> <frames> <rate> <out.mov>
//                                            a still image (with transparency) as a ProRes 4444 movie of
//                                            exactly <frames> frames at <rate> (e.g. 30000/1001)
//   MediaTool photo <photo.insp> <frames> <rate> <lensA> <lensB>
//                                            each lens of an Insta360 photo as an HEVC movie of
//                                            <frames> frames; prints "progress <0..1>" lines
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <VideoToolbox/VideoToolbox.h>

#include <algorithm>
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
    NSDictionary* result = @{@"duration": @(CMTimeGetSeconds(asset.duration)), @"streams": streams,
                             @"audio": @([asset tracksWithMediaType:AVMediaTypeAudio].count)};
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
        // The clip's sound goes with lens A, so that the clip built from the lenses has it.
        for (AVAssetTrack* sound in i == 0 ? [asset tracksWithMediaType:AVMediaTypeAudio] : @[])
        {
            AVMutableCompositionTrack* soundLane = [composition addMutableTrackWithMediaType:AVMediaTypeAudio
                                                                            preferredTrackID:kCMPersistentTrackID_Invalid];
            if (![soundLane insertTimeRange:sound.timeRange ofTrack:sound atTime:sound.timeRange.start error:&error])
            {
                return Fail([NSString stringWithFormat:@"cannot read the sound: %@", error.localizedDescription]);
            }
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

static CGImageRef ReadImage(NSString* p_Image)
{
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:p_Image], nil);
    CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, nil) : nil;
    if (source)
    {
        CFRelease(source);
    }
    return image;
}

// A key frame every 30 frames and no reordering, like the camera (see LensDecoder.mm).
static const int kLensKeyFrameInterval = 30;

// p_Count frames of the same picture as HEVC, starting with a key frame: compressed sample
// buffers in decode order, or an empty array if the encoder failed.
static NSArray* EncodeLensFrames(CVPixelBufferRef p_Pixels, int p_Count, int64_t p_Duration, int32_t p_Timescale)
{
    NSMutableArray* frames = [NSMutableArray array];
    VTCompressionSessionRef session = nil;
    if (VTCompressionSessionCreate(nil, int32_t(CVPixelBufferGetWidth(p_Pixels)), int32_t(CVPixelBufferGetHeight(p_Pixels)),
                                   kCMVideoCodecType_HEVC, nil, nil, nil, nil, nil, &session) != noErr)
    {
        return frames;
    }
    VTSessionSetProperty(session, kVTCompressionPropertyKey_Quality, (__bridge CFTypeRef)@0.95);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@(kLensKeyFrameInterval));
    VTSessionSetProperty(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    // Twice as fast on an M5 for a still picture, with the same quality (about 50 dB PSNR either way).
    VTSessionSetProperty(session, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2);
    bool failed = false;
    for (int i = 0; i < p_Count && !failed; ++i)
    {
        NSDictionary* options = i == 0 ? @{(id)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES} : nil;
        const OSStatus status = VTCompressionSessionEncodeFrameWithOutputHandler(
            session, p_Pixels, CMTimeMake(i * p_Duration, p_Timescale), CMTimeMake(p_Duration, p_Timescale),
            (__bridge CFDictionaryRef)options, nil, ^(OSStatus p_Status, VTEncodeInfoFlags, CMSampleBufferRef p_Sample) {
                if (p_Status == noErr && p_Sample)
                {
                    @synchronized(frames)
                    {
                        [frames addObject:(__bridge id)p_Sample];
                    }
                }
            });
        failed = status != noErr;
    }
    VTCompressionSessionCompleteFrames(session, kCMTimeInvalid);
    VTCompressionSessionInvalidate(session);
    CFRelease(session);
    if (failed || int(frames.count) != p_Count)
    {
        [frames removeAllObjects];
    }
    return frames;
}

// Writes p_Image (released here) as a movie of exactly p_Frames frames at p_Rate.
// p_Lens: an Insta360 lens picture, as HEVC like the camera's own lens streams; otherwise a
// picture with transparency, as ProRes 4444.
static int WriteStillMovie(CGImageRef p_Image, long p_Frames, NSString* p_Rate, NSString* p_Output, bool p_Lens,
                           void (^p_Progress)(double) = nil)
{
    CGImageRef image = p_Image;
    const size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    NSArray<NSString*>* rate = [p_Rate componentsSeparatedByString:@"/"];
    const int32_t timescale = rate.count == 2 ? rate[0].intValue : int32_t(p_Rate.doubleValue * 1000);
    const int64_t duration = rate.count == 2 ? rate[1].longLongValue : 1000;
    if (timescale <= 0 || duration <= 0 || p_Frames <= 0)
    {
        CGImageRelease(image);
        return Fail(@"bad frame count or rate");
    }

    CVPixelBufferRef pixels = nil;
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixels);
    CVPixelBufferLockBaseAddress(pixels, 0);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pixels), width, height, 8, CVPixelBufferGetBytesPerRow(pixels),
                                                 space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGContextClearRect(context, CGRectMake(0, 0, width, height));
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    CVPixelBufferUnlockBaseAddress(pixels, 0);
    CGImageRelease(image);

    // A lens picture: every frame is the same, so one key-frame interval is encoded and its
    // compressed frames are written again and again (each interval starts with a key frame, so
    // the copies decode on their own). Encoding all of them took about 30 s a photo.
    NSArray* gop = nil;
    if (p_Lens)
    {
        gop = EncodeLensFrames(pixels, int(std::min<long>(p_Frames, kLensKeyFrameInterval)), duration, timescale);
        if (gop.count == 0)
        {
            CVPixelBufferRelease(pixels);
            return Fail(@"HEVC encoding failed");
        }
    }

    [NSFileManager.defaultManager removeItemAtPath:p_Output error:nil];
    NSError* error = nil;
    AVAssetWriter* writer = [AVAssetWriter assetWriterWithURL:[NSURL fileURLWithPath:p_Output] fileType:AVFileTypeQuickTimeMovie error:&error];
    AVAssetWriterInput* input = p_Lens
        ? [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:nil
              sourceFormatHint:CMSampleBufferGetFormatDescription((__bridge CMSampleBufferRef)gop[0])]
        : [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
              AVVideoCodecKey: AVVideoCodecTypeAppleProRes4444, AVVideoWidthKey: @(width), AVVideoHeightKey: @(height)}];
    AVAssetWriterInputPixelBufferAdaptor* adaptor = p_Lens ? nil :
        [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
            sourcePixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                                          (id)kCVPixelBufferWidthKey: @(width), (id)kCVPixelBufferHeightKey: @(height)}];
    if (!writer || ![writer canAddInput:input])
    {
        CVPixelBufferRelease(pixels);
        return Fail([NSString stringWithFormat:@"cannot write %@: %@", p_Output, error.localizedDescription]);
    }
    // Without this the movie's time scale is 600, which cannot hold 1001/30000 exactly: Resolve would
    // then see 30 fps instead of 29.97 and skip a frame now and then.
    input.mediaTimeScale = timescale;
    writer.movieTimeScale = timescale;
    [writer addInput:input];
    [writer startWriting];
    [writer startSessionAtSourceTime:kCMTimeZero];

    for (long i = 0; i < p_Frames; ++i)
    {
        while (!input.readyForMoreMediaData)
        {
            usleep(1000);
        }
        bool appended = false;
        if (p_Lens)
        {
            CMSampleTimingInfo timing = {CMTimeMake(duration, timescale), CMTimeMake(i * duration, timescale), CMTimeMake(i * duration, timescale)};
            CMSampleBufferRef copy = nil;
            CMSampleBufferCreateCopyWithNewTiming(nil, (__bridge CMSampleBufferRef)gop[i % gop.count], 1, &timing, &copy);
            appended = copy && [input appendSampleBuffer:copy];
            if (copy)
            {
                CFRelease(copy);
            }
        }
        else
        {
            appended = [adaptor appendPixelBuffer:pixels withPresentationTime:CMTimeMake(i * duration, timescale)];
        }
        if (!appended)
        {
            CVPixelBufferRelease(pixels);
            return Fail([NSString stringWithFormat:@"writing %@ failed: %@", p_Output, writer.error.localizedDescription]);
        }
        if (p_Progress)
        {
            p_Progress(double(i + 1) / p_Frames);
        }
    }
    CVPixelBufferRelease(pixels);
    [input markAsFinished];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [writer endSessionAtSourceTime:CMTimeMake(p_Frames * duration, timescale)];
    [writer finishWritingWithCompletionHandler:^{
        dispatch_semaphore_signal(done);
    }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    return writer.status == AVAssetWriterStatusCompleted ? 0 : Fail(writer.error.localizedDescription ?: @"writing failed");
}

// Resolve keeps a still image on a timeline for at most a few seconds, so the clip tag is turned
// into a movie of exactly the clip's length.
static int Still(NSString* p_Image, long p_Frames, NSString* p_Rate, NSString* p_Output)
{
    CGImageRef image = ReadImage(p_Image);
    if (!image)
    {
        return Fail([NSString stringWithFormat:@"cannot read %@", p_Image]);
    }
    return WriteStillMovie(image, p_Frames, p_Rate, p_Output, false);
}

// An Insta360 photo (.insp) is a JPEG with the two lenses side by side. Each lens becomes a
// movie like the lens files of a video clip, so a photo is imported and stitched like a clip.
static int Photo(NSString* p_Photo, long p_Frames, NSString* p_Rate, NSString* p_LensA, NSString* p_LensB)
{
    CGImageRef image = ReadImage(p_Photo);
    if (!image)
    {
        return Fail([NSString stringWithFormat:@"cannot read %@", p_Photo]);
    }
    const size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    if (width != 2 * height)
    {
        CGImageRelease(image);
        return Fail([NSString stringWithFormat:@"%@ is %zux%zu, not two lenses side by side", p_Photo.lastPathComponent, width, height]);
    }
    NSArray<NSString*>* outputs = @[p_LensA, p_LensB];
    for (size_t i = 0; i < 2; ++i)
    {
        CGImageRef lens = CGImageCreateWithImageInRect(image, CGRectMake(i * height, 0, height, height));
        const int status = lens ? WriteStillMovie(lens, p_Frames, p_Rate, outputs[i], true, ^(double p_Done) {
            printf("progress %.4f\n", (i + p_Done) / 2.0);
            fflush(stdout);
        }) : Fail(@"cannot crop the lenses");
        if (status != 0)
        {
            CGImageRelease(image);
            return status;
        }
    }
    CGImageRelease(image);
    return 0;
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
        if ([command isEqualToString:@"still"] && argc == 6)
        {
            return Still(@(argv[2]), atol(argv[3]), @(argv[4]), @(argv[5]));
        }
        if ([command isEqualToString:@"photo"] && argc == 7)
        {
            return Photo(@(argv[2]), atol(argv[3]), @(argv[4]), @(argv[5]), @(argv[6]));
        }
        if ([command isEqualToString:@"frame"] && argc == 5)
        {
            return Frame(@(argv[2]), atof(argv[3]), atoi(argv[4]));
        }
        fprintf(stderr, "usage: MediaTool probe <clip> | split <clip> <out1> <out2> | frame <video> <seconds> <size> | "
                        "still <image> <frames> <rate> <out.mov> | photo <photo.insp> <frames> <rate> <lensA> <lensB>\n");
        return 2;
    }
}
