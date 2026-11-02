#include "MotionBlur.h"

#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <Vision/Vision.h>

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <map>
#include <mutex>
#include <utility>

namespace
{
const int kFlowSize = 640; // longest side the movement is measured at

CVPixelBufferRef MakeBGRA(const unsigned char* p_Pixels, int p_Width, int p_Height)
{
    CVPixelBufferRef buffer = nullptr;
    NSDictionary* attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{}};
    if (CVPixelBufferCreate(kCFAllocatorDefault, p_Width, p_Height, kCVPixelFormatType_32BGRA, (CFDictionaryRef)attrs, &buffer) != kCVReturnSuccess)
    {
        return nullptr;
    }
    CVPixelBufferLockBaseAddress(buffer, 0);
    unsigned char* base = static_cast<unsigned char*>(CVPixelBufferGetBaseAddress(buffer));
    const size_t stride = CVPixelBufferGetBytesPerRow(buffer);
    for (int y = 0; y < p_Height; ++y)
    {
        memcpy(base + y * stride, p_Pixels + size_t(y) * p_Width * 4, size_t(p_Width) * 4);
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    return buffer;
}

// The small stitched frame as 8-bit BGRA.
std::vector<unsigned char> ToBGRA(id<MTLBuffer> p_Buffer, int p_Width, int p_Height)
{
    std::vector<unsigned char> out(size_t(p_Width) * p_Height * 4);
    const float* in = static_cast<const float*>(p_Buffer.contents);
    for (size_t i = 0; i < size_t(p_Width) * p_Height; ++i)
    {
        for (int c = 0; c < 3; ++c)
        {
            out[i * 4 + c] = (unsigned char)(std::min(std::max(in[i * 4 + 2 - c], 0.0f), 1.0f) * 255.0f + 0.5f);
        }
        out[i * 4 + 3] = 255;
    }
    return out;
}

id<MTLTexture> FlowTexture(id<MTLDevice> p_Device, const std::vector<float>& p_Flow, int p_Width, int p_Height)
{
    MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG32Float
                                                                                    width:p_Width
                                                                                   height:p_Height
                                                                                mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [p_Device newTextureWithDescriptor:desc];
    [texture replaceRegion:MTLRegionMake2D(0, 0, p_Width, p_Height) mipmapLevel:0 withBytes:p_Flow.data() bytesPerRow:size_t(p_Width) * 8];
    return texture;
}

// Vision's result, in units of its own.
bool MeasureFlow(const unsigned char* p_From, const unsigned char* p_To, int p_Width, int p_Height,
                 std::vector<float>& p_Flow, int& p_FlowWidth, int& p_FlowHeight)
{
    bool ok = false;
    @autoreleasepool
    {
        CVPixelBufferRef from = MakeBGRA(p_From, p_Width, p_Height);
        CVPixelBufferRef to = MakeBGRA(p_To, p_Width, p_Height);
        if (from && to)
        {
            VNGenerateOpticalFlowRequest* request = [[[VNGenerateOpticalFlowRequest alloc] initWithTargetedCVPixelBuffer:to options:@{}] autorelease];
            request.computationAccuracy = VNGenerateOpticalFlowRequestComputationAccuracyMedium;
            request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float;
            VNImageRequestHandler* handler = [[[VNImageRequestHandler alloc] initWithCVPixelBuffer:from options:@{}] autorelease];
            NSError* err = nil;
            if ([handler performRequests:@[ request ] error:&err] && request.results.count > 0)
            {
                CVPixelBufferRef flow = ((VNPixelBufferObservation*)request.results.firstObject).pixelBuffer;
                CVPixelBufferLockBaseAddress(flow, kCVPixelBufferLock_ReadOnly);
                p_FlowWidth = int(CVPixelBufferGetWidth(flow));
                p_FlowHeight = int(CVPixelBufferGetHeight(flow));
                p_Flow.resize(size_t(p_FlowWidth) * p_FlowHeight * 2);
                const char* base = static_cast<const char*>(CVPixelBufferGetBaseAddress(flow));
                const size_t stride = CVPixelBufferGetBytesPerRow(flow);
                for (int y = 0; y < p_FlowHeight; ++y)
                {
                    const float* row = reinterpret_cast<const float*>(base + y * stride);
                    for (int x = 0; x < p_FlowWidth; ++x)
                    {
                        p_Flow[(size_t(y) * p_FlowWidth + x) * 2] = row[x * 2];
                        p_Flow[(size_t(y) * p_FlowWidth + x) * 2 + 1] = row[x * 2 + 1];
                    }
                }
                CVPixelBufferUnlockBaseAddress(flow, kCVPixelBufferLock_ReadOnly);
                ok = true;
            }
        }
        if (from)
        {
            CVPixelBufferRelease(from);
        }
        if (to)
        {
            CVPixelBufferRelease(to);
        }
    }
    return ok;
}

// Vision's vectors come out shorter than the movement by a factor that is not documented
// (2.77 across and 2.41 down at 640x360), so measure it: a picture moved by a known amount, once
// per size. As a fraction of the picture per unit, across and down.
std::pair<float, float> FlowUnits(int p_Width, int p_Height)
{
    static std::mutex mutex;
    static std::map<std::pair<int, int>, std::pair<float, float>> known;
    std::lock_guard<std::mutex> lock(mutex);
    const auto it = known.find({p_Width, p_Height});
    if (it != known.end())
    {
        return it->second;
    }

    // Detail at many sizes that does not repeat, like a photograph.
    const int w = p_Width, h = p_Height, dx = std::max(2, w / 40), dy = std::max(2, h / 40);
    std::vector<float> noise(size_t(w + dx) * (h + dy), 127.0f);
    unsigned seed = 1;
    for (int size : {4, 8, 16, 32})
    {
        const int stride = (w + dx) / size + 2;
        std::vector<float> cells(size_t(stride) * ((h + dy) / size + 2));
        for (float& v : cells)
        {
            v = float(rand_r(&seed)) / RAND_MAX - 0.5f;
        }
        for (int y = 0; y < h + dy; ++y)
        {
            for (int x = 0; x < w + dx; ++x)
            {
                const int ix = x / size, iy = y / size;
                const float tx = float(x % size) / size, ty = float(y % size) / size;
                noise[size_t(y) * (w + dx) + x] += 60.0f * ((1 - ty) * ((1 - tx) * cells[iy * stride + ix] + tx * cells[iy * stride + ix + 1]) +
                                                            ty * ((1 - tx) * cells[(iy + 1) * stride + ix] + tx * cells[(iy + 1) * stride + ix + 1]));
            }
        }
    }
    std::vector<unsigned char> from(size_t(w) * h * 4), to(size_t(w) * h * 4);
    for (int y = 0; y < h; ++y)
    {
        for (int x = 0; x < w; ++x)
        {
            const size_t i = (size_t(y) * w + x) * 4;
            const float a = noise[size_t(y + dy) * (w + dx) + x + dx], b = noise[size_t(y) * (w + dx) + x]; // moved by +dx, +dy
            from[i] = from[i + 1] = from[i + 2] = (unsigned char)std::min(255.0f, std::max(0.0f, a));
            to[i] = to[i + 1] = to[i + 2] = (unsigned char)std::min(255.0f, std::max(0.0f, b));
            from[i + 3] = to[i + 3] = 255;
        }
    }

    std::pair<float, float> units(0.0f, 0.0f);
    std::vector<float> flow;
    int fw = 0, fh = 0;
    if (MeasureFlow(from.data(), to.data(), w, h, flow, fw, fh))
    {
        // Medians over the middle of the picture.
        std::vector<float> xs, ys;
        for (int y = fh / 4; y < 3 * fh / 4; ++y)
        {
            for (int x = fw / 4; x < 3 * fw / 4; ++x)
            {
                xs.push_back(flow[(size_t(y) * fw + x) * 2]);
                ys.push_back(flow[(size_t(y) * fw + x) * 2 + 1]);
            }
        }
        std::nth_element(xs.begin(), xs.begin() + xs.size() / 2, xs.end());
        std::nth_element(ys.begin(), ys.begin() + ys.size() / 2, ys.end());
        const float mx = xs[xs.size() / 2], my = ys[ys.size() / 2];
        if (mx > 0.0f && my > 0.0f)
        {
            units = {float(dx) / w / mx, float(dy) / h / my};
        }
    }
    known[{p_Width, p_Height}] = units;
    return units;
}
}

void MotionBlurSize(int p_Width, int p_Height, int& p_SmallWidth, int& p_SmallHeight)
{
    const double scale = std::min(1.0, double(kFlowSize) / std::max(p_Width, p_Height));
    p_SmallWidth = std::max(16, int(lround(p_Width * scale / 2.0)) * 2);
    p_SmallHeight = std::max(16, int(lround(p_Height * scale / 2.0)) * 2);
}

bool OpticalFlow(const unsigned char* p_From, const unsigned char* p_To, int p_Width, int p_Height,
                 std::vector<float>& p_Flow, int& p_FlowWidth, int& p_FlowHeight)
{
    const std::pair<float, float> units = FlowUnits(p_Width, p_Height);
    if (units.first <= 0.0f || !MeasureFlow(p_From, p_To, p_Width, p_Height, p_Flow, p_FlowWidth, p_FlowHeight))
    {
        return false;
    }
    for (size_t i = 0; i < p_Flow.size(); i += 2)
    {
        p_Flow[i] *= units.first;
        p_Flow[i + 1] *= units.second;
    }
    return true;
}

bool RunMotionBlur(void* p_CmdQ, int p_Width, int p_Height, bool p_Wrap, float p_Amount, const StitchParams p_Params[3],
                   const LensImages p_Lenses[3], const bool p_Have[3], const float* p_Input, float* p_Output)
{
    id<MTLCommandQueue> queue = static_cast<id<MTLCommandQueue>>(p_CmdQ);
    if (!p_Have[1] || (!p_Have[0] && !p_Have[2]))
    {
        return false;
    }
    const int w = p_Params[1].width, h = p_Params[1].height;

    // The three small frames, all at once.
    id<MTLBuffer> small[3] = {};
    for (int i = 0; i < 3; ++i)
    {
        if (p_Have[i])
        {
            small[i] = [queue.device newBufferWithLength:size_t(w) * h * 16 options:MTLResourceStorageModeShared];
            RunStitchMetalKernel(p_CmdQ, p_Params[i], p_Input, reinterpret_cast<float*>(small[i]), &p_Lenses[i]);
        }
    }
    id<MTLCommandBuffer> sync = [queue commandBuffer];
    [sync commit];
    [sync waitUntilCompleted];

    std::vector<unsigned char> pictures[3];
    for (int i = 0; i < 3; ++i)
    {
        if (p_Have[i])
        {
            pictures[i] = ToBGRA(small[i], w, h);
            [small[i] release];
        }
    }

    // Towards the previous and the next frame, in parallel; where there is no such frame, nothing moves.
    std::vector<float> flows[2];
    int flowW[2] = {1, 1}, flowH[2] = {1, 1};
    bool ok[2] = {true, true};
    std::vector<float>* flowsPtr = flows;
    int* flowWPtr = flowW;
    int* flowHPtr = flowH;
    bool* okPtr = ok;
    std::vector<unsigned char>* picturesPtr = pictures;
    const bool have[2] = {p_Have[0], p_Have[2]};
    const bool* havePtr = have;
    dispatch_apply(2, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) {
        if (havePtr[i])
        {
            okPtr[i] = OpticalFlow(picturesPtr[1].data(), picturesPtr[i == 0 ? 0 : 2].data(), w, h, flowsPtr[i], flowWPtr[i], flowHPtr[i]);
        }
        else
        {
            flowsPtr[i].assign(2, 0.0f);
        }
    });
    if (!ok[0] || !ok[1])
    {
        return false;
    }

    id<MTLTexture> previous = FlowTexture(queue.device, flows[0], flowW[0], flowH[0]);
    id<MTLTexture> next = FlowTexture(queue.device, flows[1], flowW[1], flowH[1]);
    const bool done = RunBlurKernel(p_CmdQ, p_Width, p_Height, p_Wrap, p_Amount, previous, next, p_Output);
    [previous release];
    [next release];
    return done;
}
