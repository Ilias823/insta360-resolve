// Decodes the lens files with AVFoundation (Apple's hardware HEVC decoder) for full resolution
// rendering; see LensDecoder.h. Built with ARC.
//
// The X5 writes a key frame every 60 frames and no B-frames, so a reader that is already
// positioned reads on cheaply (about 3 ms a frame for both lenses at 3840 x 3840), while a
// jump costs a new reader and decoding from the key frame before it (50 to 200 ms).

#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>

#include <chrono>
#include <cmath>
#include <deque>
#include <list>
#include <map>
#include <mutex>

#include "LensDecoder.h"

static const int kKeepDecoded = 4;     // recent frames kept per lens, for renders that arrive out of order
static const int kReadAheadLimit = 30; // frames read on rather than opening a new reader at the frame
static const int kKeepFrames = 3;      // frames kept on the GPU, for re-renders of the same frame
static const double kIdleSeconds = 10.0; // readers and frames unused this long are released

static double SecondsNow()
{
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

// Sequential reader for one lens file.
class LensReader
{
public:
    explicit LensReader(const std::string& p_Path) : m_Path(p_Path) {}
    ~LensReader() { close(); }

    // Frame p_Frame, retained (the caller releases it), or nullptr.
    CVPixelBufferRef frame(int p_Frame)
    {
        std::lock_guard<std::mutex> lock(m_Mutex);
        m_LastUsed = SecondsNow();
        if (CVPixelBufferRef kept = keptFrame(p_Frame))
        {
            return kept;
        }
        if (!m_Output || p_Frame < m_Next || p_Frame - m_Next > kReadAheadLimit)
        {
            if (!open(p_Frame))
            {
                return nullptr;
            }
        }
        while (m_Next <= p_Frame)
        {
            if (!readNext())
            {
                close();
                return nullptr;
            }
        }
        return keptFrame(p_Frame);
    }

    // Lets go of the decoder after a while without use.
    void releaseIfIdle(double p_Now)
    {
        std::lock_guard<std::mutex> lock(m_Mutex);
        if (p_Now - m_LastUsed > kIdleSeconds)
        {
            close();
        }
    }

    bool tenBit() const { return m_TenBit; }

private:
    CVPixelBufferRef keptFrame(int p_Frame)
    {
        for (const auto& kept : m_Kept)
        {
            if (kept.first == p_Frame)
            {
                return CVPixelBufferRetain(kept.second);
            }
        }
        return nullptr;
    }

    bool open(int p_Frame)
    {
        close();
        @autoreleasepool
        {
            AVURLAsset* asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:@(m_Path.c_str())]
                                                    options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
            AVAssetTrack* track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
            if (!track)
            {
                return false;
            }
            m_FrameDuration = track.minFrameDuration;
            if (!CMTIME_IS_VALID(m_FrameDuration) || CMTimeGetSeconds(m_FrameDuration) <= 0.0)
            {
                m_FrameDuration = CMTimeMakeWithSeconds(1.0 / fmax(track.nominalFrameRate, 1.0), 600000);
            }
            m_Start = track.timeRange.start;

            // Kept as recorded: 4:2:0, full range like the X5's files, 10-bit when the file is.
            CMFormatDescriptionRef format = (__bridge CMFormatDescriptionRef)track.formatDescriptions.firstObject;
            NSNumber* depth = format ? (__bridge NSNumber*)CMFormatDescriptionGetExtension(format, kCMFormatDescriptionExtension_BitsPerComponent) : nil;
            m_TenBit = depth && depth.intValue > 8;
            const OSType pixelFormat = m_TenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;

            NSError* err = nil;
            AVAssetReader* reader = [AVAssetReader assetReaderWithAsset:asset error:&err];
            AVAssetReaderTrackOutput* output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:@{
                (id)kCVPixelBufferPixelFormatTypeKey: @(pixelFormat),
                (id)kCVPixelBufferMetalCompatibilityKey: @YES,
                (id)kCVPixelBufferIOSurfacePropertiesKey: @{}}];
            output.alwaysCopiesSampleData = NO;
            if (!reader || ![reader canAddOutput:output])
            {
                return false;
            }
            [reader addOutput:output];
            // Start half a frame early, so that rounding in the timestamps cannot skip the frame.
            const CMTime at = CMTimeAdd(m_Start, CMTimeMultiplyByFloat64(m_FrameDuration, fmax(p_Frame - 0.5, 0.0)));
            reader.timeRange = CMTimeRangeMake(at, kCMTimePositiveInfinity);
            if (![reader startReading])
            {
                return false;
            }
            m_Reader = reader;
            m_Output = output;
            m_Next = p_Frame; // corrected by the first timestamp read
            return true;
        }
    }

    bool readNext()
    {
        @autoreleasepool
        {
            CMSampleBufferRef sample = [m_Output copyNextSampleBuffer];
            if (!sample)
            {
                return false;
            }
            CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(sample);
            if (pixels)
            {
                const CMTime pts = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample), m_Start);
                const int index = int(llround(CMTimeGetSeconds(pts) / CMTimeGetSeconds(m_FrameDuration)));
                m_Kept.emplace_back(index, CVPixelBufferRetain(pixels));
                if (int(m_Kept.size()) > kKeepDecoded)
                {
                    CVPixelBufferRelease(m_Kept.front().second);
                    m_Kept.pop_front();
                }
                m_Next = index + 1;
            }
            CFRelease(sample);
            return true;
        }
    }

    void close()
    {
        [m_Reader cancelReading];
        m_Reader = nil;
        m_Output = nil;
        for (auto& kept : m_Kept)
        {
            CVPixelBufferRelease(kept.second);
        }
        m_Kept.clear();
    }

    std::string m_Path;
    std::mutex m_Mutex;
    AVAssetReader* m_Reader = nil;
    AVAssetReaderTrackOutput* m_Output = nil;
    CMTime m_FrameDuration = kCMTimeInvalid;
    CMTime m_Start = kCMTimeZero;
    int m_Next = 0; // frame the reader returns next
    bool m_TenBit = false;
    std::deque<std::pair<int, CVPixelBufferRef>> m_Kept;
    double m_LastUsed = 0.0;
};

// Both lenses of a frame as mipmapped textures. The mip levels let the kernel filter properly
// when the output shows the lens smaller than it was recorded.
struct LensTextures
{
    id<MTLTexture> textures[4];
    int width = 0, height = 0;
    int bits = 8;
};

struct CachedFrame
{
    id<MTLDevice> device;
    std::string clip;
    int frame;
    double lastUsed;
    std::shared_ptr<LensTextures> textures;
};

static std::mutex s_Mutex;
static std::map<std::string, std::shared_ptr<LensReader>> s_Readers; // by file path
static std::list<CachedFrame> s_Frames;                             // most recently used first
static std::map<void*, CVMetalTextureCacheRef> s_TextureCaches;     // by MTLDevice

static std::shared_ptr<LensReader> ReaderFor(const std::string& p_Path)
{
    std::shared_ptr<LensReader>& reader = s_Readers[p_Path];
    if (!reader)
    {
        reader = std::make_shared<LensReader>(p_Path);
    }
    return reader;
}

// Releases idle readers and cached frames; runs every few seconds once decoding has started.
static void SweepIdle()
{
    const double now = SecondsNow();
    std::map<std::string, std::shared_ptr<LensReader>> readers;
    {
        std::lock_guard<std::mutex> lock(s_Mutex);
        readers = s_Readers;
        s_Frames.remove_if([now](const CachedFrame& p_Frame) { return now - p_Frame.lastUsed > kIdleSeconds; });
    }
    for (auto& reader : readers)
    {
        reader.second->releaseIfIdle(now);
    }
}

static void StartSweeping()
{
    static dispatch_source_t timer = nil;
    static std::once_flag once;
    std::call_once(once, []()
    {
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC);
        dispatch_source_set_event_handler(timer, ^{ SweepIdle(); });
        dispatch_resume(timer);
    });
}

// Copies one plane of a decoded frame into a new mipmapped texture, on p_Blit.
static id<MTLTexture> CopyPlane(id<MTLBlitCommandEncoder> p_Blit, CVMetalTextureCacheRef p_Cache, CVPixelBufferRef p_Pixels, int p_Plane,
                                MTLPixelFormat p_Format, CVMetalTextureRef& p_Source)
{
    const size_t w = CVPixelBufferGetWidthOfPlane(p_Pixels, p_Plane);
    const size_t h = CVPixelBufferGetHeightOfPlane(p_Pixels, p_Plane);
    if (CVMetalTextureCacheCreateTextureFromImage(nullptr, p_Cache, p_Pixels, nullptr, p_Format, w, h, p_Plane, &p_Source) != kCVReturnSuccess)
    {
        p_Source = nullptr;
        return nil;
    }
    id<MTLTexture> source = CVMetalTextureGetTexture(p_Source);
    MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:p_Format width:w height:h mipmapped:YES];
    desc.usage = MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModePrivate;
    id<MTLTexture> texture = [p_Blit.device newTextureWithDescriptor:desc];
    if (!source || !texture)
    {
        return nil;
    }
    [p_Blit copyFromTexture:source sourceSlice:0 sourceLevel:0 toTexture:texture destinationSlice:0 destinationLevel:0 sliceCount:1 levelCount:1];
    [p_Blit generateMipmapsForTexture:texture];
    return texture;
}

static std::shared_ptr<LensTextures> Upload(id<MTLCommandQueue> p_Queue, CVPixelBufferRef p_Pixels[2], bool p_TenBit)
{
    CVMetalTextureCacheRef cache = nullptr;
    {
        std::lock_guard<std::mutex> lock(s_Mutex);
        CVMetalTextureCacheRef& entry = s_TextureCaches[(__bridge void*)p_Queue.device];
        if (!entry)
        {
            CVMetalTextureCacheCreate(nullptr, nullptr, p_Queue.device, nullptr, &entry);
        }
        cache = entry;
    }
    if (!cache)
    {
        return nullptr;
    }

    auto images = std::make_shared<LensTextures>();
    images->width = int(CVPixelBufferGetWidth(p_Pixels[0]));
    images->height = int(CVPixelBufferGetHeight(p_Pixels[0]));
    images->bits = p_TenBit ? 10 : 8;
    CVMetalTextureRef sources[4] = {};
    bool ok = CVPixelBufferGetWidth(p_Pixels[1]) == size_t(images->width) && CVPixelBufferGetHeight(p_Pixels[1]) == size_t(images->height);
    id<MTLCommandBuffer> commandBuffer = [p_Queue commandBuffer];
    commandBuffer.label = @"Insta360Stitch lens upload";
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    for (int i = 0; i < 4 && ok; ++i)
    {
        const MTLPixelFormat format = p_TenBit ? (i % 2 ? MTLPixelFormatRG16Unorm : MTLPixelFormatR16Unorm)
                                               : (i % 2 ? MTLPixelFormatRG8Unorm : MTLPixelFormatR8Unorm);
        images->textures[i] = CopyPlane(blit, cache, p_Pixels[i / 2], i % 2, format, sources[i]);
        ok = images->textures[i] != nil;
    }
    [blit endEncoding];
    [commandBuffer commit];
    // Waiting keeps this simple: renders may come on other queues, and the decoded frames can
    // be released right after.
    [commandBuffer waitUntilCompleted];
    for (CVMetalTextureRef source : sources)
    {
        if (source)
        {
            CFRelease(source);
        }
    }
    CVMetalTextureCacheFlush(cache, 0);
    return ok && commandBuffer.status == MTLCommandBufferStatusCompleted ? images : nullptr;
}

bool AcquireLensImages(void* p_CmdQ, const std::string& p_LensA, const std::string& p_LensB, int p_Frame, LensImages& p_Images)
{
    id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)p_CmdQ;
    if (!queue || p_Frame < 0 || p_LensA.empty() || p_LensB.empty())
    {
        return false;
    }
    StartSweeping();
    const std::string clip = p_LensA + "\n" + p_LensB;

    std::shared_ptr<LensTextures> images;
    std::shared_ptr<LensReader> readers[2];
    {
        std::lock_guard<std::mutex> lock(s_Mutex);
        for (auto it = s_Frames.begin(); it != s_Frames.end(); ++it)
        {
            if (it->device == queue.device && it->frame == p_Frame && it->clip == clip)
            {
                it->lastUsed = SecondsNow();
                images = it->textures;
                s_Frames.splice(s_Frames.begin(), s_Frames, it);
                break;
            }
        }
        readers[0] = ReaderFor(p_LensA);
        readers[1] = ReaderFor(p_LensB);
    }

    if (!images)
    {
        // Both lenses at once; each reader has its own lock, so concurrent renders of other
        // frames wait only for the lens they need.
        CVPixelBufferRef pixels[2] = {};
        CVPixelBufferRef* decoded = pixels;
        LensReader* lens[2] = {readers[0].get(), readers[1].get()};
        LensReader** lensPtr = lens;
        dispatch_apply(2, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) {
            decoded[i] = lensPtr[i]->frame(p_Frame);
        });
        if (pixels[0] && pixels[1])
        {
            images = Upload(queue, pixels, readers[0]->tenBit());
        }
        for (CVPixelBufferRef p : pixels)
        {
            if (p)
            {
                CVPixelBufferRelease(p);
            }
        }
        if (!images)
        {
            return false;
        }

        std::lock_guard<std::mutex> lock(s_Mutex);
        s_Frames.push_front(CachedFrame{queue.device, clip, p_Frame, SecondsNow(), images});
        while (int(s_Frames.size()) > kKeepFrames)
        {
            s_Frames.pop_back();
        }
    }

    for (int i = 0; i < 4; ++i)
    {
        p_Images.textures[i] = (__bridge void*)images->textures[i];
    }
    p_Images.width = images->width;
    p_Images.height = images->height;
    p_Images.bits = images->bits;
    p_Images.owner = images;
    return true;
}
