// Checks the built bundle without a host application:
//   1. the binary loads and exposes the OpenFX entry points with the expected identifier
//   2. the Metal kernel builds and the source views produce the expected pixels
//
// With --stitch it runs the stitch on a raw float RGBA frame instead, so that
// tools/compare_metal.py can check the result against the Python reference:
//   test_plugin --stitch in.raw width height calibration.json|- out.raw flipY [pan tilt roll fov distance aspect]
//
// With --fullres it renders a frame of two lens files both ways, from the files decoded at full
// resolution and from a Resolve-like input (the same frame scaled to the timeline), and reports
// how much the colours differ, how much sharper full resolution is, and how long frames take:
//   test_plugin --fullres lensA.mov lensB.mov frame width height calibration.json|- out_prefix [pan tilt roll fov distance aspect]
//
// With --track it runs the subject tracker over numbered raw frames (frame_0000.raw, ...), or
// 8-bit RGB frames on stdin when dir is "-", and
// prints one line per frame: index pan tilt confidence
//   test_plugin --track dir width height count calibration.json|- pan tilt subjectDegrees
#import <AVFoundation/AVFoundation.h>
#import <Accelerate/Accelerate.h>
#import <Metal/Metal.h>

#include <chrono>

#include <cmath>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <string>
#include <vector>

#include "ofxCore.h"
#include "Calibration.h"
#include "LensDecoder.h"
#include "StitchKernel.h"
#include "Tracker.h"

static int s_Failures = 0;

static void Check(bool p_Ok, const char* p_What)
{
    printf("%s  %s\n", p_Ok ? "ok  " : "FAIL", p_What);
    s_Failures += p_Ok ? 0 : 1;
}

static bool RunKernelWith(id<MTLCommandQueue> p_Queue, const StitchParams& p_Params, const std::vector<float>& p_In, std::vector<float>& p_Out,
                          const LensImages* p_Lenses, std::shared_ptr<FullResCheck> p_Check = nullptr)
{
    const NSUInteger bytes = p_In.size() * sizeof(float);
    id<MTLBuffer> src = [p_Queue.device newBufferWithBytes:p_In.data() length:bytes options:MTLResourceStorageModeShared];
    id<MTLBuffer> dst = [p_Queue.device newBufferWithLength:bytes options:MTLResourceStorageModeShared];

    const bool ok = RunStitchMetalKernel(p_Queue, p_Params, reinterpret_cast<const float*>(src), reinterpret_cast<float*>(dst), p_Lenses, p_Check);

    // The kernel commits without waiting; an empty command buffer on the same queue flushes it.
    id<MTLCommandBuffer> sync = [p_Queue commandBuffer];
    [sync commit];
    [sync waitUntilCompleted];

    p_Out.assign(static_cast<float*>(dst.contents), static_cast<float*>(dst.contents) + p_In.size());
    [src release];
    [dst release];
    return ok;
}

static bool RunKernel(id<MTLCommandQueue> p_Queue, const StitchParams& p_Params, const std::vector<float>& p_In, std::vector<float>& p_Out)
{
    return RunKernelWith(p_Queue, p_Params, p_In, p_Out, nullptr);
}

static int StitchFile(int argc, char** argv)
{
    // An optional 15th argument holds a stabilisation rotation: 9 comma-separated numbers.
    if (argc != 8 && argc != 14 && argc != 15)
    {
        fprintf(stderr, "usage: test_plugin --stitch in.raw width height calibration.json|- out.raw flipY [pan tilt roll fov distance aspect]\n");
        return 2;
    }

    StitchParams params = {};
    params.width = atoi(argv[3]);
    params.height = atoi(argv[4]);
    params.mode = eModeStitch;
    params.flipY = atoi(argv[7]);
    params.blendBand = float(sin(2.0 * M_PI / 180.0));
    params.gainMatch = 1;
    params.autoDistance = 1;
    if (argc >= 14)
    {
        params.mode = eModeReframe;
        FillViewParams(atof(argv[8]), atof(argv[9]), atof(argv[10]), atof(argv[11]), atof(argv[12]), atof(argv[13]), params);
    }
    if (argc == 15)
    {
        params.stabilize = 1;
        const char* p = argv[14];
        for (int i = 0; i < 9; ++i)
        {
            params.stab[i] = float(strtod(p, const_cast<char**>(&p)));
            p += (*p == ',') ? 1 : 0;
        }
    }

    std::string raw = kNominalX5Calibration;
    if (strcmp(argv[5], "-") != 0 && !ReadCalibrationFile(argv[5], raw))
    {
        fprintf(stderr, "cannot read calibration from %s\n", argv[5]);
        return 1;
    }
    LensCalibration lenses[2];
    if (!ParseCalibration(raw, lenses))
    {
        fprintf(stderr, "calibration is not a 2-lens calibration\n");
        return 1;
    }
    FillLensParams(lenses, params.width, params.height, params.lens);
    FillLensOffset(lenses, params);

    std::vector<float> in(size_t(params.width) * params.height * 4), out;
    FILE* f = fopen(argv[2], "rb");
    if (!f || fread(in.data(), sizeof(float), in.size(), f) != in.size())
    {
        fprintf(stderr, "cannot read %zu floats from %s\n", in.size(), argv[2]);
        return 1;
    }
    fclose(f);

    @autoreleasepool
    {
        id<MTLCommandQueue> queue = [MTLCreateSystemDefaultDevice() newCommandQueue];
        if (!RunKernel(queue, params, in, out))
        {
            return 1;
        }
    }

    f = fopen(argv[6], "wb");
    if (!f || fwrite(out.data(), sizeof(float), out.size(), f) != out.size())
    {
        fprintf(stderr, "cannot write %s\n", argv[6]);
        return 1;
    }
    fclose(f);
    return 0;
}

// One frame of a lens file as 8-bit BGRA, converted by AVFoundation, scaled to p_W x p_H.
static bool DecodeScaled(const char* p_Path, int p_Frame, int p_W, int p_H, std::vector<uint8_t>& p_Out)
{
    @autoreleasepool
    {
        AVURLAsset* asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:@(p_Path)] options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
        AVAssetTrack* track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        AVAssetReader* reader = [AVAssetReader assetReaderWithAsset:asset error:nil];
        AVAssetReaderTrackOutput* output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track
            outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
        [reader addOutput:output];
        const CMTime duration = track.minFrameDuration;
        reader.timeRange = CMTimeRangeMake(CMTimeMultiplyByFloat64(duration, fmax(p_Frame - 0.5, 0.0)), kCMTimePositiveInfinity);
        [reader startReading];
        CMSampleBufferRef sample = [output copyNextSampleBuffer];
        if (!sample)
        {
            return false;
        }
        CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(sample);
        CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
        vImage_Buffer src = {CVPixelBufferGetBaseAddress(pixels), CVPixelBufferGetHeight(pixels), CVPixelBufferGetWidth(pixels),
                             CVPixelBufferGetBytesPerRow(pixels)};
        p_Out.resize(size_t(p_W) * p_H * 4);
        vImage_Buffer dst = {p_Out.data(), vImagePixelCount(p_H), vImagePixelCount(p_W), size_t(p_W) * 4};
        vImageScale_ARGB8888(&src, &dst, nullptr, kvImageHighQualityResampling);
        CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
        CFRelease(sample);
        [reader cancelReading];
        return true;
    }
}

static double Seconds()
{
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

static int FullResFile(int argc, char** argv)
{
    if (argc != 9 && argc != 15)
    {
        fprintf(stderr, "usage: test_plugin --fullres lensA.mov lensB.mov frame width height calibration.json|- out_prefix [pan tilt roll fov distance aspect]\n");
        return 2;
    }
    const int frame = atoi(argv[4]);
    StitchParams params = {};
    params.width = atoi(argv[5]);
    params.height = atoi(argv[6]);
    params.mode = eModeStitch;
    params.flipY = 1;
    params.blendBand = float(sin(2.0 * M_PI / 180.0));
    params.gainMatch = 1;
    params.autoDistance = 1;
    if (argc == 15)
    {
        params.mode = eModeReframe;
        FillViewParams(atof(argv[9]), atof(argv[10]), atof(argv[11]), atof(argv[12]), atof(argv[13]), atof(argv[14]), params);
    }
    std::string raw = kNominalX5Calibration;
    LensCalibration lenses[2];
    if ((strcmp(argv[7], "-") != 0 && !ReadCalibrationFile(argv[7], raw)) || !ParseCalibration(raw, lenses))
    {
        fprintf(stderr, "cannot read calibration from %s\n", argv[7]);
        return 1;
    }
    FillLensOffset(lenses, params);

    // Resolve-like input: each lens scaled to half the frame, side by side, bottom row first.
    const int tileW = params.width / 2;
    std::vector<float> in(size_t(params.width) * params.height * 4), outResolve, outFull;
    for (int lens = 0; lens < 2; ++lens)
    {
        std::vector<uint8_t> bgra;
        if (!DecodeScaled(argv[2 + lens], frame, tileW, params.height, bgra))
        {
            fprintf(stderr, "cannot decode frame %d of %s\n", frame, argv[2 + lens]);
            return 1;
        }
        for (int y = 0; y < params.height; ++y)
        {
            for (int x = 0; x < tileW; ++x)
            {
                const uint8_t* s = &bgra[(size_t(y) * tileW + x) * 4];
                float* d = &in[((size_t(params.height - 1 - y)) * params.width + lens * tileW + x) * 4];
                d[0] = s[2] / 255.0f;
                d[1] = s[1] / 255.0f;
                d[2] = s[0] / 255.0f;
                d[3] = 1.0f;
            }
        }
    }

    @autoreleasepool
    {
        id<MTLCommandQueue> queue = [MTLCreateSystemDefaultDevice() newCommandQueue];
        FillLensParams(lenses, params.width, params.height, params.lens);
        if (!RunKernel(queue, params, in, outResolve))
        {
            return 1;
        }

        double start = Seconds();
        LensImages images;
        if (!AcquireLensImages(queue, argv[2], argv[3], frame, images))
        {
            fprintf(stderr, "cannot decode the lens files at full resolution\n");
            return 1;
        }
        const double seek = Seconds() - start;
        StitchParams full = params;
        full.fullRes = 1;
        full.lensWidth = images.width;
        full.lensHeight = images.height;
        full.seamLod = float(std::max(0.0, log2(images.width / 960.0)));
        full.yuvScale = images.bits > 8 ? float(65535.0 / (1023.0 * 64.0)) : 1.0f;
        full.chromaMid = images.bits > 8 ? float(512.0 / 1023.0) : float(128.0 / 255.0);
        FillLensParams(lenses, 2 * images.width, images.height, full.lens);
        auto check = std::make_shared<FullResCheck>();
        RunKernelWith(queue, full, in, outFull, &images, check);
        printf("frame check: %s, difference %.4f\n", check->matched == 1 ? "matched" : "NOT matched", double(check->lastDiff));
        s_Failures += check->matched == 1 ? 0 : 1;

        // A frame other than the input's must be noticed, and the input used instead.
        LensImages other;
        std::vector<float> outOther;
        auto otherCheck = std::make_shared<FullResCheck>();
        if (AcquireLensImages(queue, argv[2], argv[3], frame + 45, other))
        {
            RunKernelWith(queue, full, in, outOther, &other, otherCheck);
            double worst = 0.0, total = 0.0;
            for (size_t i = 0; i < outOther.size(); ++i)
            {
                worst = fmax(worst, fabs(outOther[i] - outResolve[i]));
                total += fabs(outOther[i] - outResolve[i]);
            }
            printf("frame 45 later: %s, difference %.4f; output vs input path: mean %.4f max %.4f (8-bit levels)\n",
                   otherCheck->mismatched == 1 ? "rejected" : "NOT rejected", double(otherCheck->lastDiff),
                   total / outOther.size() * 255, worst * 255);
            s_Failures += otherCheck->mismatched == 1 ? 0 : 1;
        }

        // Playing on: decode and render the next frames as a timeline would.
        const int count = 60;
        start = Seconds();
        for (int i = 1; i <= count; ++i)
        {
            LensImages next;
            std::vector<float> scratch;
            if (!AcquireLensImages(queue, argv[2], argv[3], frame + i, next))
            {
                fprintf(stderr, "cannot decode frame %d\n", frame + i);
                return 1;
            }
            RunKernelWith(queue, full, in, scratch, &next);
        }
        const double perFrame = (Seconds() - start) / count;
        printf("lenses %dx%d %d-bit; first frame %.0f ms, then %.1f ms a frame (%.0f fps) at %dx%d\n",
               images.width, images.height, images.bits, seek * 1000, perFrame * 1000, 1.0 / perFrame, params.width, params.height);
    }

    // Colour: compare 16 x 16 pixel block averages, which leaves out the difference in sharpness.
    const int block = 16, bw = params.width / block, bh = params.height / block;
    double diff[3] = {}, mean[2][3] = {}, detail[2] = {};
    for (int by = 0; by < bh; ++by)
    {
        for (int bx = 0; bx < bw; ++bx)
        {
            double sums[2][3] = {};
            for (int y = by * block; y < (by + 1) * block; ++y)
            {
                for (int x = bx * block; x < (bx + 1) * block; ++x)
                {
                    for (int c = 0; c < 3; ++c)
                    {
                        sums[0][c] += outResolve[(size_t(y) * params.width + x) * 4 + c];
                        sums[1][c] += outFull[(size_t(y) * params.width + x) * 4 + c];
                    }
                }
            }
            for (int c = 0; c < 3; ++c)
            {
                diff[c] += fabs(sums[1][c] - sums[0][c]) / (block * block);
                mean[0][c] += sums[0][c] / (block * block);
                mean[1][c] += sums[1][c] / (block * block);
            }
        }
    }
    // Sharpness: mean difference between neighbouring pixels.
    for (int y = 0; y < params.height; ++y)
    {
        for (int x = 1; x < params.width; ++x)
        {
            const size_t i = (size_t(y) * params.width + x) * 4 + 1;
            detail[0] += fabs(outResolve[i] - outResolve[i - 4]);
            detail[1] += fabs(outFull[i] - outFull[i - 4]);
        }
    }
    const double n = double(bw) * bh;
    printf("mean RGB (8-bit levels): Resolve-like %.2f %.2f %.2f, full resolution %.2f %.2f %.2f\n",
           mean[0][0] / n * 255, mean[0][1] / n * 255, mean[0][2] / n * 255, mean[1][0] / n * 255, mean[1][1] / n * 255, mean[1][2] / n * 255);
    printf("colour difference of 16x16 block averages (8-bit levels): %.2f %.2f %.2f\n", diff[0] / n * 255, diff[1] / n * 255, diff[2] / n * 255);
    printf("detail (neighbour difference), full resolution / Resolve-like: %.2f\n", detail[1] / fmax(detail[0], 1e-9));

    for (int k = 0; k < 2; ++k)
    {
        const std::string path = std::string(argv[8]) + (k ? "_full.raw" : "_resolve.raw");
        const std::vector<float>& out = k ? outFull : outResolve;
        FILE* f = fopen(path.c_str(), "wb");
        if (!f)
        {
            return 1;
        }
        fwrite(out.data(), sizeof(float), out.size(), f);
        fclose(f);
    }
    return s_Failures == 0 ? 0 : 1;
}

static int TrackFiles(int argc, char** argv)
{
    if (argc != 10)
    {
        fprintf(stderr, "usage: test_plugin --track dir width height count calibration.json|- pan tilt subjectDegrees\n");
        return 2;
    }
    const int w = atoi(argv[3]), h = atoi(argv[4]), count = atoi(argv[5]);
    std::string raw = kNominalX5Calibration;
    if (strcmp(argv[6], "-") != 0 && !ReadCalibrationFile(argv[6], raw))
    {
        fprintf(stderr, "cannot read calibration from %s\n", argv[6]);
        return 1;
    }
    LensCalibration lenses[2];
    ParseCalibration(raw, lenses);

    // Frames come from numbered float files, or with dir "-" as 8-bit RGB from stdin
    // (for example piped straight from ffmpeg, so no frames need to be stored).
    std::vector<float> pixels(size_t(w) * h * 4);
    std::vector<unsigned char> rgb(size_t(w) * h * 3);
    const bool fromStdin = strcmp(argv[2], "-") == 0;
    auto load = [&](int i) {
        if (fromStdin)
        {
            if (fread(rgb.data(), 1, rgb.size(), stdin) != rgb.size())
            {
                return false;
            }
            for (size_t p = 0; p < size_t(w) * h; ++p)
            {
                pixels[p * 4] = rgb[p * 3] / 255.0f;
                pixels[p * 4 + 1] = rgb[p * 3 + 1] / 255.0f;
                pixels[p * 4 + 2] = rgb[p * 3 + 2] / 255.0f;
                pixels[p * 4 + 3] = 1.0f;
            }
            return true;
        }
        char path[1024];
        snprintf(path, sizeof(path), "%s/frame_%04d.raw", argv[2], i);
        FILE* f = fopen(path, "rb");
        const bool ok = f && fread(pixels.data(), sizeof(float), pixels.size(), f) == pixels.size();
        if (f)
        {
            fclose(f);
        }
        return ok;
    };
    const FrameView frame = {reinterpret_cast<const unsigned char*>(pixels.data()), w, h, long(w * 4 * sizeof(float)), false};

    double pan = atof(argv[7]), tilt = atof(argv[8]), confidence = 1.0;
    SubjectTracker tracker(lenses, atof(argv[9]));
    if (!load(0))
    {
        fprintf(stderr, "cannot read frame 0\n");
        return 1;
    }
    tracker.start(frame, pan, tilt);
    printf("0 %.3f %.3f 1.000\n", pan, tilt);
    for (int i = 1; i < count; ++i)
    {
        if (!load(i))
        {
            fprintf(stderr, "cannot read frame %d\n", i);
            return 1;
        }
        const bool going = tracker.step(frame, pan, tilt, confidence);
        printf("%d %.3f %.3f %.3f\n", i, pan, tilt, confidence);
        if (!going)
        {
            printf("lost\n");
            break;
        }
    }
    return 0;
}

int main(int argc, char** argv)
{
    if (argc >= 2 && strcmp(argv[1], "--track") == 0)
    {
        return TrackFiles(argc, argv);
    }
    if (argc >= 2 && strcmp(argv[1], "--fullres") == 0)
    {
        return FullResFile(argc, argv);
    }
    if (argc >= 2 && strcmp(argv[1], "--stitch") == 0)
    {
        return StitchFile(argc, argv);
    }
    if (argc < 2)
    {
        fprintf(stderr, "usage: test_plugin path/to/Insta360Stitch.ofx\n");
        return 2;
    }

    void* lib = dlopen(argv[1], RTLD_NOW);
    Check(lib != nullptr, "plugin binary loads");
    if (lib)
    {
        typedef int (*CountFn)(void);
        typedef OfxPlugin* (*GetFn)(int);
        CountFn count = (CountFn)dlsym(lib, "OfxGetNumberOfPlugins");
        GetFn get = (GetFn)dlsym(lib, "OfxGetPlugin");
        Check(count && get, "OpenFX entry points exported");
        if (count && get)
        {
            Check(count() == 1, "exactly one plugin in the bundle");
            OfxPlugin* plugin = get(0);
            printf("      identifier %s, version %d.%d, api %s\n", plugin->pluginIdentifier,
                   plugin->pluginVersionMajor, plugin->pluginVersionMinor, plugin->pluginApi);
            Check(std::string(plugin->pluginIdentifier) == "org.insta360resolve.Stitch", "plugin identifier");
        }
    }

    @autoreleasepool
    {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = [device newCommandQueue];
        Check(queue != nil, "Metal device available");

        const int w = 64, h = 32; // 2:1 like the real frame; not a multiple of the thread group width
        std::vector<float> in(w * h * 4), out;
        for (size_t i = 0; i < in.size(); ++i)
        {
            in[i] = float(i % 251) / 250.f;
        }

        StitchParams params = {};
        params.width = w;
        params.height = h;
        params.mode = eModeSource;
        Check(RunKernel(queue, params, in, out), "Metal kernel builds and runs");
        Check(out == in, "source view is identical to input");

        params.mode = eModeSourceTint;
        RunKernel(queue, params, in, out);
        bool tintOk = true;
        for (int y = 0; y < h && tintOk; ++y)
        {
            for (int x = 0; x < w && tintOk; ++x)
            {
                const int i = (y * w + x) * 4;
                const bool left = x < w / 2;
                const float dim = y < h / 8 ? .25f : 1.f;
                const float e[4] = {in[i] * (left ? 1.f : .5f) * dim, in[i + 1] * .5f * dim, in[i + 2] * (left ? .5f : 1.f) * dim, in[i + 3]};
                for (int c = 0; c < 4; ++c)
                {
                    tintOk = tintOk && std::fabs(out[i + c] - e[c]) < 1e-6f;
                }
            }
        }
        Check(tintOk, "tinted view: left half red, right half blue, first rows dark, alpha untouched");

        LensCalibration lenses[2];
        Check(ParseCalibration(kNominalX5Calibration, lenses), "built-in calibration parses");
        Check(!ParseCalibration("2_1.0_2.0", lenses), "truncated calibration is rejected");

        // Lens B 10% brighter and a little warmer than lens A: with Match Lenses on, both sides of the
        // seam meet at the geometric mean; with it off the step stays.
        {
            const int sw = 512, sh = 256;
            std::vector<float> flat(size_t(sw) * sh * 4), stitched;
            const float a[3] = {0.40f, 0.40f, 0.40f}, b[3] = {0.46f, 0.44f, 0.42f};
            for (int y = 0; y < sh; ++y)
            {
                for (int x = 0; x < sw; ++x)
                {
                    float* px = &flat[(size_t(y) * sw + x) * 4];
                    const float* c = x < sw / 2 ? a : b;
                    px[0] = c[0], px[1] = c[1], px[2] = c[2], px[3] = 1.f;
                }
            }
            StitchParams seam = {};
            seam.width = sw;
            seam.height = sh;
            seam.mode = eModeStitch;
            seam.blendBand = float(sin(2.0 * M_PI / 180.0));
            FillLensParams(lenses, sw, sh, seam.lens);
            FillLensOffset(lenses, seam);
            seam.autoDistance = 1;
            // Equirectangular columns at longitude +-80 (lens A side) and +-100 (lens B side), on the equator.
            auto at = [&](double p_Lon, int p_C) { return stitched[(size_t(sh / 2) * sw + int((p_Lon + 180.0) / 360.0 * sw)) * 4 + p_C]; };
            for (int match = 0; match < 2; ++match)
            {
                seam.gainMatch = match;
                RunKernel(queue, seam, flat, stitched);
                float step = 0.f, offMean = 0.f;
                for (int c = 0; c < 3; ++c)
                {
                    step = std::max(step, std::fabs(at(80.0, c) - at(100.0, c)));
                    offMean = std::max(offMean, std::fabs(at(80.0, c) - std::sqrt(a[c] * b[c])));
                }
                if (match)
                {
                    Check(step < 1e-3f && offMean < 1e-3f, "Match Lenses evens out a lens exposure difference at the seam");
                }
                else
                {
                    Check(step > 0.015f, "without Match Lenses the exposure step stays");
                }
            }
        }

        // The tracker starts from a point of the view; the view centre must be where the camera looks.
        StitchParams view = {};
        FillViewParams(40.0, -25.0, 10.0, 120.0, 0.5, 16.0 / 9.0, view);
        double ray[3];
        ViewPointToRay(view, 0.5, 0.5, ray);
        const double len = sqrt(ray[0] * ray[0] + ray[1] * ray[1] + ray[2] * ray[2]);
        const double rayPan = atan2(ray[0], ray[2]) * 180.0 / M_PI, rayTilt = asin(-ray[1] / len) * 180.0 / M_PI;
        Check(fabs(rayPan - 40.0) < 1e-6 && fabs(rayTilt + 25.0) < 1e-6, "view centre ray points along pan and tilt");
        ViewPointToRay(view, 0.9, 0.5, ray);
        Check(atan2(ray[0], ray[2]) * 180.0 / M_PI > 40.0, "a point right of centre lies further right");
    }

    printf("%s\n", s_Failures ? "FAILED" : "all checks passed");
    return s_Failures ? 1 : 0;
}
