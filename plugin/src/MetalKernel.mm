#import <Metal/Metal.h>

#include <mutex>
#include <unordered_map>

#include "ClipTag.h"
#include "LensDecoder.h"
#include "StitchKernel.h"

static const char* kKernelSource = R"METAL(
#include <metal_stdlib>
using namespace metal;

#define LENS_SLOTS 24

// Seam analysis; tools/stitch_poc.py (seam_tables) uses the same constants.
#define SEAM_COLUMNS 256        // samples around the seam ...
#define SEAM_ROWS 32            // ... and across it, within +-SEAM_BAND_DEG (the lenses overlap about +-6)
#define SEAM_BAND_DEG 4.0
#define SEAM_BINS 64            // table entries around the seam; entry SEAM_BINS holds the global gain
#define SEAM_FADE_DEG 30.0      // the corrections fade out between the band edge and this distance from the seam
#define GAIN_SIGMA_DEG 15.0     // smoothing of the gain along the seam
#define GAIN_PRIOR 64.0         // pulls entries with few usable samples towards the global gain
#define DEPTH_STEPS 12          // candidate stitch distances, evenly spaced in 1 / distance ...
#define MAX_INV_DISTANCE 2.5    // ... from infinity to 0.4 m
#define DEPTH_SIGMA_DEG 12.0    // the match of each candidate is pooled over this much of the seam
#define DEPTH_PRIOR 0.05        // cost per 1/m away from DEFAULT_INV_DISTANCE: keeps flat areas put and frames steady
#define DEFAULT_INV_DISTANCE 0.5
#define DEPTH_TABLE_SIGMA_DEG 4.0
#define MATCH_GRID 32           // points per side and lens where the decoded lenses are compared with the input
#define MATCH_MAX_DIFF 0.04     // mean brightness difference above which the decoded frame is not the input's

struct StitchParams
{
    int width;
    int height;
    int mode;
    int flipY;
    float blendBand;
    float distance;
    float planeX;
    float planeY;
    float camRot[9];
    int gainMatch;
    int autoDistance;
    float invDistance;
    float lensOffset[3];
    float lens[2 * LENS_SLOTS];
    int stabilize;
    float stab[9];
    int fullRes;
    int lensWidth;
    int lensHeight;
    float seamLod;
    float yuvScale;
    float chromaMid;
};

// Where the lens pictures come from: Resolve's input buffer, or with fullRes the lens files
// decoded at full resolution, as luma and chroma textures per lens (LensDecoder.mm).
struct Source
{
    bool decoded; // fullRes and the decoded frame matches the input; otherwise read the input
    const device float* input;
    texture2d<float> luma0;
    texture2d<float> chroma0;
    texture2d<float> luma1;
    texture2d<float> chroma1;
};

// Size of one lens picture being sampled.
static float2 LensSize(constant StitchParams& p)
{
    return p.fullRes != 0 ? float2(float(p.lensWidth), float(p.lensHeight)) : float2(float(p.width / 2), float(p.height));
}

static float4 ReadPixel(const device float* p_Input, int p_Index)
{
    return float4(p_Input[p_Index], p_Input[p_Index + 1], p_Input[p_Index + 2], p_Input[p_Index + 3]);
}

// Bilinear sample of one lens tile; x, y are pixel-centre coordinates inside the tile, y from the top.
static float4 SampleLens(const device float* p_Input, constant StitchParams& p, int p_Lens, float2 p_Pos)
{
    const int tileW = p.width / 2;
    const float2 base = floor(p_Pos);
    const float2 f = p_Pos - base;
    float4 sum = float4(0.0);
    for (int j = 0; j < 2; ++j)
    {
        for (int i = 0; i < 2; ++i)
        {
            const int x = int(base.x) + i;
            const int y = int(base.y) + j;
            if (x < 0 || y < 0 || x >= tileW || y >= p.height)
            {
                continue;
            }
            const int row = p.flipY != 0 ? p.height - 1 - y : y;
            const float w = (i == 0 ? 1.0 - f.x : f.x) * (j == 0 ? 1.0 - f.y : f.y);
            sum += w * ReadPixel(p_Input, (row * p.width + p_Lens * tileW + x) * 4);
        }
    }
    return sum;
}

// Sample of a decoded lens at pixel-centre position p_Pos (y from the top), converted to RGB.
// With p_Lod < 0 the mip level comes from the footprint p_Dx, p_Dy of an output pixel in lens
// pixels, with anisotropic filtering; otherwise it is mip level p_Lod.
static float3 SampleDecoded(texture2d<float> p_Luma, texture2d<float> p_Chroma, constant StitchParams& p, float2 p_Pos,
                            float2 p_Dx, float2 p_Dy, float p_Lod)
{
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge, max_anisotropy(8));
    const float2 size = LensSize(p);
    const float2 uv = (p_Pos + 0.5) / size;
    // HEVC 4:2:0 chroma sits on even columns, between rows.
    const float2 uvChroma = (float2(p_Pos.x * 0.5, (p_Pos.y - 0.5) * 0.5) + 0.5) / (size * 0.5);
    float y;
    float2 c;
    if (p_Lod < 0.0)
    {
        const gradient2d grad(p_Dx / size, p_Dy / size);
        y = p_Luma.sample(s, uv, grad).r;
        c = p_Chroma.sample(s, uvChroma, grad).rg;
    }
    else
    {
        y = p_Luma.sample(s, uv, level(p_Lod)).r;
        c = p_Chroma.sample(s, uvChroma, level(p_Lod)).rg;
    }
    // Full range BT.709, as the X5 records.
    y *= p.yuvScale;
    c = c * p.yuvScale - p.chromaMid;
    return float3(y + 1.5748 * c.y, y - 0.187324 * c.x - 0.468124 * c.y, y + 1.8556 * c.x);
}

// Position in a lens tile of the input buffer for a position in a decoded lens.
static float2 InputPos(constant StitchParams& p, float2 p_Pos)
{
    return (p_Pos + 0.5) * float2(float(p.width / 2), float(p.height)) / LensSize(p) - 0.5;
}

static float3 SampleSource(Source p_Src, constant StitchParams& p, int p_Lens, float2 p_Pos, float2 p_Dx, float2 p_Dy, float p_Lod)
{
    if (p.fullRes == 0)
    {
        return SampleLens(p_Src.input, p, p_Lens, p_Pos).rgb;
    }
    if (!p_Src.decoded)
    {
        return SampleLens(p_Src.input, p, p_Lens, InputPos(p, p_Pos)).rgb;
    }
    return p_Lens == 0 ? SampleDecoded(p_Src.luma0, p_Src.chroma0, p, p_Pos, p_Dx, p_Dy, p_Lod)
                       : SampleDecoded(p_Src.luma1, p_Src.chroma1, p, p_Pos, p_Dx, p_Dy, p_Lod);
}

// For the seam analysis, which is tuned to pictures about 1000 pixels across.
static float3 SeamSample(Source p_Src, constant StitchParams& p, int p_Lens, float2 p_Pos)
{
    return SampleSource(p_Src, p, p_Lens, p_Pos, float2(0.0), float2(0.0), p.seamLod);
}

// Projects a rig-space ray into a lens tile (MEI fisheye model). Returns false outside the image circle.
static bool ProjectToLens(constant StitchParams& p, int p_Lens, float3 p_Ray, thread float2& p_Pos)
{
    const int o = p_Lens * LENS_SLOTS;
    const float3 local = float3(dot(float3(p.lens[o + 15], p.lens[o + 16], p.lens[o + 17]), p_Ray),
                                dot(float3(p.lens[o + 18], p.lens[o + 19], p.lens[o + 20]), p_Ray),
                                dot(float3(p.lens[o + 21], p.lens[o + 22], p.lens[o + 23]), p_Ray));
    const float den = local.z + p.lens[o + 4];
    if (den <= 1e-6)
    {
        return false;
    }

    const float x = local.x / den;
    const float y = local.y / den;
    const float r2 = x * x + y * y;
    const float r4 = r2 * r2;
    const float k1 = p.lens[o + 5], k2 = p.lens[o + 6], k3 = p.lens[o + 7], k4 = p.lens[o + 8];
    const float p1 = p.lens[o + 9], p2 = p.lens[o + 10];
    const float s1 = p.lens[o + 11], s2 = p.lens[o + 12], s3 = p.lens[o + 13], s4 = p.lens[o + 14];
    const float radial = 1.0 + k1 * r2 + k2 * r4 + k3 * r2 * r4 + k4 * r4 * r4;
    const float xd = x * radial + 2.0 * p1 * x * y + p2 * (r2 + 2.0 * x * x) + s1 * r2 + s2 * r4;
    const float yd = y * radial + p1 * (r2 + 2.0 * y * y) + 2.0 * p2 * x * y + s3 * r2 + s4 * r4;

    p_Pos = float2(p.lens[o + 0] * xd + p.lens[o + 2], p.lens[o + 1] * yd + p.lens[o + 3]);

    // Image circle test, per axis so that squeezed frames work too.
    const float2 radius = LensSize(p) * 0.5;
    return length((p_Pos - radius) / radius) < 0.975;
}

// Direction from lens A (p_Sign 1) or lens B (-1) to the point at 1 / p_InvDistance metres along
// p_Ray. The rig centre sits halfway between the lenses, so each lens takes half the parallax.
static float3 LensRay(constant StitchParams& p, float3 p_Ray, float p_InvDistance, float p_Sign)
{
    const float3 halfOffset = 0.5 * float3(p.lensOffset[0], p.lensOffset[1], p.lensOffset[2]);
    return normalize(p_Ray + p_Sign * p_InvDistance * halfOffset);
}

static float3 SeamRay(int p_Column, int p_Row)
{
    const float phi = (float(p_Column) + 0.5) / SEAM_COLUMNS * 2.0 * M_PI_F;
    const float z = sin(SEAM_BAND_DEG * M_PI_F / 180.0) * ((float(p_Row) + 0.5) / SEAM_ROWS * 2.0 - 1.0);
    const float s = sqrt(1.0 - z * z);
    return float3(s * cos(phi), s * sin(phi), z);
}

// Angle between two seam columns, wrapped to -pi..pi.
static float ColumnAngle(int p_A, int p_B)
{
    const float d = float(p_A - p_B) / SEAM_COLUMNS * 2.0 * M_PI_F;
    return d - 2.0 * M_PI_F * rint(d / (2.0 * M_PI_F));
}

// Measures the seam once per frame and fills a table around it: per-channel gain lens A / lens B
// in rgb and 1 / stitch distance in w, plus the global gain in entry SEAM_BINS.
// 1. stitch distance per column: the candidate where the lenses agree best across the seam,
//    pooled along the seam, with a small pull towards the default distance;
// 2. colour of both lenses at that distance, leaving out near black, clipped and mismatched samples.
// Runs as one threadgroup; each thread handles whole columns.
kernel void SeamKernel(constant StitchParams& p [[buffer(1)]],
                       const device float* p_Input [[buffer(0)]],
                       device float4* p_Table [[buffer(2)]],
                       texture2d<float> p_Luma0 [[texture(0)]],
                       texture2d<float> p_Chroma0 [[texture(1)]],
                       texture2d<float> p_Luma1 [[texture(2)]],
                       texture2d<float> p_Chroma1 [[texture(3)]],
                       uint tid [[thread_position_in_threadgroup]],
                       uint count [[threads_per_threadgroup]])
{
    threadgroup float costSum[SEAM_COLUMNS * DEPTH_STEPS];
    threadgroup ushort costCount[SEAM_COLUMNS * DEPTH_STEPS];
    threadgroup float colQ[SEAM_COLUMNS];
    threadgroup float4 colA[SEAM_COLUMNS]; // rgb sums, w = number of samples used
    threadgroup float4 colB[SEAM_COLUMNS];
    threadgroup float2 matchSum[256]; // per thread: brightness difference, points

    // With fullRes, first check that the decoded frame is the one in the input: the host's time
    // is not always the frame in the file (in Fusion it counts from the start of the comp).
    // Both are compared at the input's resolution, inside the image circles.
    bool decoded = false;
    if (p.fullRes != 0)
    {
        const Source probe = {true, p_Input, p_Luma0, p_Chroma0, p_Luma1, p_Chroma1};
        const float2 size = LensSize(p);
        const float2 footprint = size / float2(float(p.width / 2), float(p.height));
        float2 sum = float2(0.0);
        for (uint i = tid; i < 2 * MATCH_GRID * MATCH_GRID; i += count)
        {
            const int lens = int(i) / (MATCH_GRID * MATCH_GRID);
            const int cell = int(i) % (MATCH_GRID * MATCH_GRID);
            const float2 uv = (float2(float(cell % MATCH_GRID), float(cell / MATCH_GRID)) + 0.5) / MATCH_GRID;
            if (length(uv * 2.0 - 1.0) > 0.85)
            {
                continue;
            }
            const float2 pos = uv * size - 0.5;
            const float3 weights = float3(0.2126, 0.7152, 0.0722);
            const float a = dot(SampleSource(probe, p, lens, pos, float2(footprint.x, 0.0), float2(0.0, footprint.y), -1.0), weights);
            const float b = dot(SampleLens(p_Input, p, lens, InputPos(p, pos)).rgb, weights);
            sum += float2(abs(a - b), 1.0);
        }
        matchSum[tid] = sum;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        float2 total = float2(0.0);
        for (uint t = 0; t < count; ++t)
        {
            total += matchSum[t];
        }
        const float diff = total.x / max(total.y, 1.0);
        decoded = diff < MATCH_MAX_DIFF;
        if (tid == 0)
        {
            p_Table[SEAM_BINS + 1] = float4(decoded ? 1.0 : 0.0, diff, 0.0, 0.0);
        }
    }
    const Source src = {decoded, p_Input, p_Luma0, p_Chroma0, p_Luma1, p_Chroma1};

    const float stepQ = MAX_INV_DISTANCE / (DEPTH_STEPS - 1);
    if (p.autoDistance != 0)
    {
        for (uint c = tid; c < SEAM_COLUMNS; c += count)
        {
            for (int k = 0; k < DEPTH_STEPS; ++k)
            {
                float sum = 0.0;
                int n = 0;
                for (int r = 0; r < SEAM_ROWS; ++r)
                {
                    const float3 ray = SeamRay(int(c), r);
                    float2 posA, posB;
                    if (ProjectToLens(p, 0, LensRay(p, ray, k * stepQ, 1.0), posA) &&
                        ProjectToLens(p, 1, LensRay(p, ray, k * stepQ, -1.0), posB))
                    {
                        const float3 a = SeamSample(src, p, 0, posA);
                        const float3 b = SeamSample(src, p, 1, posB);
                        sum += abs((a.r + a.g + a.b) - (b.r + b.g + b.b)) / 3.0;
                        ++n;
                    }
                }
                costSum[c * DEPTH_STEPS + k] = sum;
                costCount[c * DEPTH_STEPS + k] = ushort(n);
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        const float sigma = DEPTH_SIGMA_DEG * M_PI_F / 180.0;
        for (uint c = tid; c < SEAM_COLUMNS; c += count)
        {
            float sum[DEPTH_STEPS], n[DEPTH_STEPS];
            for (int k = 0; k < DEPTH_STEPS; ++k)
            {
                sum[k] = 0.0;
                n[k] = 0.0;
            }
            for (int o = 0; o < SEAM_COLUMNS; ++o)
            {
                const float d = ColumnAngle(o, int(c)) / sigma;
                const float w = exp(-0.5 * d * d);
                for (int k = 0; k < DEPTH_STEPS; ++k)
                {
                    sum[k] += w * costSum[o * DEPTH_STEPS + k];
                    n[k] += w * float(costCount[o * DEPTH_STEPS + k]);
                }
            }
            float cost[DEPTH_STEPS];
            int best = 0;
            for (int k = 0; k < DEPTH_STEPS; ++k)
            {
                cost[k] = sum[k] / max(n[k], 1e-6) + DEPTH_PRIOR * abs(k * stepQ - DEFAULT_INV_DISTANCE);
                best = cost[k] < cost[best] ? k : best;
            }
            // Refine between candidates with a parabola through the best one and its neighbours.
            float shift = 0.0;
            if (best > 0 && best < DEPTH_STEPS - 1)
            {
                const float curve = cost[best - 1] - 2.0 * cost[best] + cost[best + 1];
                shift = curve > 1e-9 ? clamp(0.5 * (cost[best - 1] - cost[best + 1]) / curve, -0.5, 0.5) : 0.0;
            }
            colQ[c] = (float(best) + shift) * stepQ;
        }
    }
    else
    {
        for (uint c = tid; c < SEAM_COLUMNS; c += count)
        {
            colQ[c] = p.invDistance;
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint c = tid; c < SEAM_COLUMNS; c += count)
    {
        float4 sumA = float4(0.0), sumB = float4(0.0);
        for (int r = 0; r < SEAM_ROWS && p.gainMatch != 0; ++r)
        {
            const float3 ray = SeamRay(int(c), r);
            float2 posA, posB;
            if (!ProjectToLens(p, 0, LensRay(p, ray, colQ[c], 1.0), posA) || !ProjectToLens(p, 1, LensRay(p, ray, colQ[c], -1.0), posB))
            {
                continue;
            }
            const float3 a = SeamSample(src, p, 0, posA);
            const float3 b = SeamSample(src, p, 1, posB);
            const float la = (a.r + a.g + a.b) / 3.0, lb = (b.r + b.g + b.b) / 3.0;
            if (la > 0.02 && lb > 0.02 && la < 0.95 && lb < 0.95 && la < 2.0 * lb && lb < 2.0 * la)
            {
                sumA += float4(a, 1.0);
                sumB += float4(b, 1.0);
            }
        }
        colA[c] = sumA;
        colB[c] = sumB;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    float4 totalA = float4(0.0), totalB = float4(0.0);
    for (int c = 0; c < SEAM_COLUMNS; ++c)
    {
        totalA += colA[c];
        totalB += colB[c];
    }
    const bool measured = totalA.w > 0.0;
    const float3 meanA = totalA.rgb / max(totalA.w, 1.0), meanB = totalB.rgb / max(totalB.w, 1.0);
    const float3 overall = measured ? clamp(meanA / max(meanB, 1e-6), 0.5, 2.0) : float3(1.0);
    const float gainSigma = GAIN_SIGMA_DEG * M_PI_F / 180.0, depthSigma = DEPTH_TABLE_SIGMA_DEG * M_PI_F / 180.0;
    for (uint k = tid; k < SEAM_BINS; k += count)
    {
        const float centre = (float(k) + 0.5) / SEAM_BINS * 2.0 * M_PI_F;
        float3 sumA = GAIN_PRIOR * meanA, sumB = GAIN_PRIOR * meanB;
        float q = 0.0, qWeight = 0.0;
        for (int c = 0; c < SEAM_COLUMNS; ++c)
        {
            float d = (float(c) + 0.5) / SEAM_COLUMNS * 2.0 * M_PI_F - centre;
            d -= 2.0 * M_PI_F * rint(d / (2.0 * M_PI_F));
            const float w = exp(-0.5 * (d / gainSigma) * (d / gainSigma));
            sumA += w * colA[c].rgb;
            sumB += w * colB[c].rgb;
            const float wq = exp(-0.5 * (d / depthSigma) * (d / depthSigma));
            q += wq * colQ[c];
            qWeight += wq;
        }
        const float3 gain = measured ? clamp(sumA / max(sumB, 1e-6), 0.5, 2.0) : float3(1.0);
        p_Table[k] = float4(gain, q / qWeight);
    }
    if (tid == 0)
    {
        p_Table[SEAM_BINS] = float4(overall, 0.0);
    }
}

// Table value around the seam for a ray.
static float4 TableAt(const device float4* p_Table, float3 p_Ray)
{
    float f = atan2(p_Ray.y, p_Ray.x) / (2.0 * M_PI_F) * SEAM_BINS - 0.5;
    f -= SEAM_BINS * floor(f / SEAM_BINS);
    const float k = floor(f);
    const int k0 = int(k) % SEAM_BINS;
    return mix(p_Table[k0], p_Table[(k0 + 1) % SEAM_BINS], f - k);
}

// 1 within the measured band around the seam, fading to 0 at SEAM_FADE_DEG from it.
static float NearSeam(float3 p_Ray)
{
    const float lo = sin(SEAM_BAND_DEG * M_PI_F / 180.0), hi = sin(SEAM_FADE_DEG * M_PI_F / 180.0);
    return clamp((hi - abs(p_Ray.z)) / (hi - lo), 0.0, 1.0);
}

// Direction in the rig frame (x right, y down, z forward) seen at an output pixel, x and y from the
// top left, stabilisation applied.
static float3 OutputRay(constant StitchParams& p, float2 p_Pixel)
{
    const float2 uv = (p_Pixel + 0.5) / float2(float(p.width), float(p.height));
    float3 ray;
    if (p.mode == 0)
    {
        // Equirectangular: the whole sphere.
        const float lon = uv.x * 2.0 * M_PI_F - M_PI_F;
        const float lat = M_PI_F / 2.0 - uv.y * M_PI_F;
        ray = float3(cos(lat) * sin(lon), -sin(lat), cos(lat) * cos(lon));
    }
    else
    {
        // Virtual camera "distance" behind the sphere centre, looking along +z: follow its ray
        // through this point of the image plane to the sphere, then rotate into the rig frame.
        const float2 plane = (uv * 2.0 - 1.0) * float2(p.planeX, p.planeY);
        const float d = p.distance;
        const float r2 = dot(plane, plane);
        const float t = (d + sqrt(max(1.0 + r2 * (1.0 - d * d), 0.0))) / (r2 + 1.0);
        const float3 cam = float3(plane * t, t - d); // unit length
        ray = float3(dot(float3(p.camRot[0], p.camRot[1], p.camRot[2]), cam),
                     dot(float3(p.camRot[3], p.camRot[4], p.camRot[5]), cam),
                     dot(float3(p.camRot[6], p.camRot[7], p.camRot[8]), cam));
    }

    if (p.stabilize != 0)
    {
        // Stabilisation: the view stays put while the camera moves, so turn the ray into the camera.
        ray = float3(dot(float3(p.stab[0], p.stab[1], p.stab[2]), ray),
                     dot(float3(p.stab[3], p.stab[4], p.stab[5]), ray),
                     dot(float3(p.stab[6], p.stab[7], p.stab[8]), ray));
    }
    return ray;
}

kernel void StitchKernel(constant StitchParams& p [[buffer(1)]],
                         const device float* p_Input [[buffer(0)]],
                         const device float4* p_Table [[buffer(2)]],
                         device float* p_Output [[buffer(8)]],
                         texture2d<float> p_Luma0 [[texture(0)]],
                         texture2d<float> p_Chroma0 [[texture(1)]],
                         texture2d<float> p_Luma1 [[texture(2)]],
                         texture2d<float> p_Chroma1 [[texture(3)]],
                         uint2 id [[thread_position_in_grid]])
{
    if (id.x >= uint(p.width) || id.y >= uint(p.height))
    {
        return;
    }

    const int index = (int(id.y) * p.width + int(id.x)) * 4;
    float4 px;

    if (p.mode == 0 || p.mode == 3)
    {
        // Output pixel -> direction in the rig frame (x right, y down, z forward).
        const int yTop = p.flipY != 0 ? p.height - 1 - int(id.y) : int(id.y);
        const float3 ray = OutputRay(p, float2(float(id.x), float(yTop)));

        // Each lens looks at the point at the stitch distance, so that things at that distance line up.
        const float4 seam = TableAt(p_Table, ray);
        const float near = NearSeam(ray);
        float2 posA, posB;
        const bool okA = ProjectToLens(p, 0, LensRay(p, ray, seam.w * near, 1.0), posA);
        const bool okB = ProjectToLens(p, 1, LensRay(p, ray, seam.w * near, -1.0), posB);

        // Lens A looks along +z; cross-fade in a narrow band around the z = 0 seam. Smoothstep,
        // so that the fade has no kink at the band edges.
        float wA = smoothstep(-p.blendBand, p.blendBand, ray.z);
        wA = okA ? (okB ? wA : 1.0) : 0.0;
        const float wB = okB ? (okA ? 1.0 - wA : 1.0) : 0.0;

        // Meet in the middle: lens A down by the square root of the gain, lens B up by it.
        const float3 overall = p_Table[SEAM_BINS].rgb;
        const float3 root = p.gainMatch != 0 ? sqrt(overall + (seam.rgb - overall) * near) : float3(1.0);
        // The seam pass found whether the decoded frame is the input's.
        const Source src = {p.fullRes != 0 && p_Table[SEAM_BINS + 1].x > 0.5, p_Input, p_Luma0, p_Chroma0, p_Luma1, p_Chroma1};
        // Footprint of this output pixel in each lens, for filtering the full resolution pictures:
        // where the neighbouring pixels land.
        float2 dxA = float2(0.0), dyA = float2(0.0), dxB = float2(0.0), dyB = float2(0.0);
        if (src.decoded)
        {
            const float3 rayX = OutputRay(p, float2(float(id.x) + 1.0, float(yTop)));
            const float3 rayY = OutputRay(p, float2(float(id.x), float(yTop) + 1.0));
            float2 q;
            dxA = okA && ProjectToLens(p, 0, LensRay(p, rayX, seam.w * near, 1.0), q) ? q - posA : float2(0.0);
            dyA = okA && ProjectToLens(p, 0, LensRay(p, rayY, seam.w * near, 1.0), q) ? q - posA : float2(0.0);
            dxB = okB && ProjectToLens(p, 1, LensRay(p, rayX, seam.w * near, -1.0), q) ? q - posB : float2(0.0);
            dyB = okB && ProjectToLens(p, 1, LensRay(p, rayY, seam.w * near, -1.0), q) ? q - posB : float2(0.0);
        }
        float3 sum = float3(0.0);
        if (wA > 0.0)
        {
            sum += wA * SampleSource(src, p, 0, posA, dxA, dyA, -1.0) / root;
        }
        if (wB > 0.0)
        {
            sum += wB * SampleSource(src, p, 1, posB, dxB, dyB, -1.0) * root;
        }
        px = float4(sum / max(wA + wB, 1e-6), 1.0);
    }
    else
    {
        px = ReadPixel(p_Input, index);
        if (p.mode == 2)
        {
            const bool left = int(id.x) < p.width / 2;
            px.rgb *= left ? float3(1.0, 0.5, 0.5) : float3(0.5, 0.5, 1.0);
            if (int(id.y) < p.height / 8)
            {
                px.rgb *= 0.25; // marks buffer row 0, to show which way up the host stores frames
            }
        }
    }

    p_Output[index]     = px.r;
    p_Output[index + 1] = px.g;
    p_Output[index + 2] = px.b;
    p_Output[index + 3] = px.a;
}
// Brightness at the centres of the clip tag's 32 cells (positions computed on the CPU, ClipTag.h).
kernel void TagKernel(constant StitchParams& p [[buffer(1)]],
                      const device float* p_Input [[buffer(0)]],
                      constant int2* p_Cells [[buffer(2)]],
                      device float* p_Out [[buffer(3)]],
                      uint i [[thread_position_in_grid]])
{
    if (i >= 32)
    {
        return;
    }
    const int2 c = clamp(p_Cells[i], int2(0, 0), int2(p.width - 1, p.height - 1));
    const int row = p.flipY != 0 ? p.height - 1 - c.y : c.y;
    const float4 px = ReadPixel(p_Input, (row * p.width + c.x) * 4);
    p_Out[i] = dot(px.rgb, float3(0.299, 0.587, 0.114));
}
)METAL";

struct Pipelines
{
    id<MTLComputePipelineState> stitch;
    id<MTLComputePipelineState> seam;
    id<MTLComputePipelineState> tag;
    id<MTLTexture> placeholder; // bound in place of the decoded lenses when they are not used
};

static std::mutex s_PipelineMutex;
static std::unordered_map<void*, Pipelines> s_Pipelines; // one set per command queue

static id<MTLComputePipelineState> BuildPipeline(id<MTLLibrary> p_Library, NSString* p_Name)
{
    NSError* err = nil;
    id<MTLFunction> function = [p_Library newFunctionWithName:p_Name];
    id<MTLComputePipelineState> pipeline = [p_Library.device newComputePipelineStateWithFunction:function error:&err];
    [function release];
    if (!pipeline)
    {
        fprintf(stderr, "Insta360Stitch: Metal pipeline %s failed to build: %s\n", p_Name.UTF8String, err.localizedDescription.UTF8String);
    }
    return pipeline;
}

static Pipelines PipelinesForQueue(id<MTLCommandQueue> p_Queue)
{
    std::lock_guard<std::mutex> lock(s_PipelineMutex);

    const auto it = s_Pipelines.find((void*)p_Queue);
    if (it != s_Pipelines.end())
    {
        return it->second;
    }

    NSError* err = nil;
    id<MTLDevice> device = p_Queue.device;
    id<MTLLibrary> library = [device newLibraryWithSource:@(kKernelSource) options:[[MTLCompileOptions new] autorelease] error:&err];
    if (!library)
    {
        fprintf(stderr, "Insta360Stitch: Metal library failed to build: %s\n", err.localizedDescription.UTF8String);
        return Pipelines{nil, nil, nil, nil};
    }

    MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:1 height:1 mipmapped:NO];
    Pipelines pipelines = {BuildPipeline(library, @"StitchKernel"), BuildPipeline(library, @"SeamKernel"), BuildPipeline(library, @"TagKernel"),
                           [device newTextureWithDescriptor:desc]};
    [library release];
    if (!pipelines.stitch || !pipelines.seam || !pipelines.tag)
    {
        [pipelines.stitch release];
        [pipelines.seam release];
        [pipelines.tag release];
        [pipelines.placeholder release];
        return Pipelines{nil, nil, nil, nil};
    }

    s_Pipelines[(void*)p_Queue] = pipelines;
    return pipelines;
}

int ReadClipTagMetal(void* p_CmdQ, const StitchParams& p_Params, const float* p_Input)
{
    id<MTLCommandQueue> queue = static_cast<id<MTLCommandQueue>>(p_CmdQ);
    const Pipelines pipelines = PipelinesForQueue(queue);
    if (!pipelines.tag)
    {
        return -1;
    }

    int cells[ClipTag::kBits * 2];
    for (int bit = 0; bit < ClipTag::kBits; ++bit)
    {
        ClipTag::CellCentre(bit, p_Params.width, p_Params.height, cells[bit * 2], cells[bit * 2 + 1]);
    }
    id<MTLBuffer> out = [queue.device newBufferWithLength:ClipTag::kBits * sizeof(float) options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
    [encoder setComputePipelineState:pipelines.tag];
    [encoder setBuffer:reinterpret_cast<id<MTLBuffer>>(const_cast<float*>(p_Input)) offset:0 atIndex:0];
    [encoder setBytes:&p_Params length:sizeof(StitchParams) atIndex:1];
    [encoder setBytes:cells length:sizeof(cells) atIndex:2];
    [encoder setBuffer:out offset:0 atIndex:3];
    [encoder dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(ClipTag::kBits, 1, 1)];
    [encoder endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];

    float brightness[ClipTag::kBits];
    memcpy(brightness, out.contents, sizeof(brightness));
    [out release];
    return ClipTag::Decode(brightness);
}

bool RunStitchMetalKernel(void* p_CmdQ, const StitchParams& p_Params, const float* p_Input, float* p_Output, const LensImages* p_Lenses,
                          std::shared_ptr<FullResCheck> p_Check)
{
    id<MTLCommandQueue> queue = static_cast<id<MTLCommandQueue>>(p_CmdQ);
    const Pipelines pipelines = PipelinesForQueue(queue);
    if (!pipelines.stitch)
    {
        return false;
    }

    // With Metal rendering the host hands us MTLBuffers in place of pixel pointers.
    id<MTLBuffer> srcBuf = reinterpret_cast<id<MTLBuffer>>(const_cast<float*>(p_Input));
    id<MTLBuffer> dstBuf = reinterpret_cast<id<MTLBuffer>>(p_Output);

    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
    commandBuffer.label = @"Insta360Stitch";

    // Per-frame seam table, filled on the GPU by the first pass and read by the second; the
    // command buffer keeps it alive until both have run.
    // With full resolution the CPU reads the result of the frame check from it afterwards.
    const bool decoded = p_Params.fullRes != 0 && p_Lenses;
    id<MTLBuffer> tableBuf = [queue.device newBufferWithLength:(kSeamBins + 2) * 4 * sizeof(float)
                                                       options:decoded ? MTLResourceStorageModeShared : MTLResourceStorageModePrivate];

    id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
    [encoder setBuffer:srcBuf offset:0 atIndex:0];
    [encoder setBuffer:tableBuf offset:0 atIndex:2];
    [encoder setBuffer:dstBuf offset:0 atIndex:8];
    StitchParams params = p_Params;
    params.fullRes = decoded ? 1 : 0;
    [encoder setBytes:&params length:sizeof(StitchParams) atIndex:1];
    for (int i = 0; i < 4; ++i)
    {
        [encoder setTexture:decoded ? static_cast<id<MTLTexture>>(p_Lenses->textures[i]) : pipelines.placeholder atIndex:i];
    }
    if (decoded)
    {
        // The decoded lenses must live until the GPU has read them.
        std::shared_ptr<void> owner = p_Lenses->owner;
        [tableBuf retain];
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> p_Done) {
            (void)owner;
            const float* check = static_cast<const float*>(tableBuf.contents) + (kSeamBins + 1) * 4;
            if (p_Check && p_Done.status == MTLCommandBufferStatusCompleted)
            {
                (check[0] > 0.5f ? p_Check->matched : p_Check->mismatched)++;
                p_Check->lastDiff = check[1];
            }
            [tableBuf release];
        }];
    }

    if (p_Params.mode == eModeStitch || p_Params.mode == eModeReframe)
    {
        [encoder setComputePipelineState:pipelines.seam];
        const NSUInteger threads = MIN(pipelines.seam.maxTotalThreadsPerThreadgroup, NSUInteger(256));
        [encoder dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(threads, 1, 1)];
    }

    [encoder setComputePipelineState:pipelines.stitch];
    const NSUInteger exeWidth = pipelines.stitch.threadExecutionWidth;
    const MTLSize groupSize = MTLSizeMake(exeWidth, 1, 1);
    const MTLSize groups = MTLSizeMake((p_Params.width + exeWidth - 1) / exeWidth, p_Params.height, 1);
    [encoder dispatchThreadgroups:groups threadsPerThreadgroup:groupSize];

    [encoder endEncoding];
    [commandBuffer commit];
    [tableBuf release];
    return true;
}
