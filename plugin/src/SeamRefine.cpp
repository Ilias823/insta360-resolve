// Measures how far lens B is off at the stitch seam and fits a correction to its calibration.
// C++ port of tools/refine_seam.py (the reference), so that tools/ingest.py can refine every clip
// without numpy or OpenCV. It ships inside the plugin bundle, next to TrackProgress.
//
// Reads frame pairs on stdin, lens A then lens B, each kWorkSize x kWorkSize 8-bit RGB (for
// example straight from ffmpeg), and prints the fit for lens B as one line of JSON:
//   SeamRefine calibration_raw frameCount < frames.rgb
// The calibration string should be the factory one; the fit is relative to it.
#include <dispatch/dispatch.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include "Calibration.h"

// Same constants as refine_seam.py.
static const int kWorkSize = 1920;          // lens images are analysed at this size
static const int kColumns = 512, kRows = 24, kBins = 32;
static const double kBandDeg = 4.0;
static const int kInvDistances = 33;        // -1.5 .. 2.5 1/m across the seam; below 0 is a calibration error
static const int kAlongSteps = 21;          // -1 .. 1 degree along the seam
static const double kSensorWidth = 5376.0;  // as in Calibration.cpp
static const double kCropWidth = 5312.0;
static const double kDegToRad = M_PI / 180.0;

struct Vec3
{
    double x, y, z;
};

static Vec3 Normalized(Vec3 p_V)
{
    const double n = sqrt(p_V.x * p_V.x + p_V.y * p_V.y + p_V.z * p_V.z);
    return {p_V.x / n, p_V.y / n, p_V.z / n};
}

static Vec3 TurnedAroundZ(Vec3 p_V, double p_Deg)
{
    const double c = cos(p_Deg * kDegToRad), s = sin(p_Deg * kDegToRad);
    return {c * p_V.x - s * p_V.y, s * p_V.x + c * p_V.y, p_V.z};
}

static double InvDistance(int p_I)
{
    return -1.5 + 4.0 * p_I / (kInvDistances - 1);
}

static double AlongDeg(int p_J)
{
    return -1.0 + 2.0 * p_J / (kAlongSteps - 1);
}

// Where a rig-space ray lands in one lens image, as stitch_poc.py project() computes it.
class LensProjection
{
public:
    LensProjection(const LensCalibration& p_Lens, int p_Index, double p_VideoWidth)
        : m_Lens(p_Lens), m_VideoWidth(p_VideoWidth)
    {
        // R = Ry(yaw) * Rx(pitch), with the second lens facing backwards; the rows of the
        // rig-to-lens rotation are the columns of R.
        const double yaw = (p_Lens.yaw + (p_Index == 1 ? 180.0 : 0.0)) * kDegToRad;
        const double pitch = p_Lens.pitch * kDegToRad;
        const double cy = cos(yaw), sy = sin(yaw), cp = cos(pitch), sp = sin(pitch);
        const double r[3][3] = {{cy, sy * sp, sy * cp}, {0.0, cp, -sp}, {-sy, cy * sp, cy * cp}};
        for (int row = 0; row < 3; ++row)
        {
            for (int col = 0; col < 3; ++col)
            {
                m_Rot[row][col] = r[col][row];
            }
        }
    }

    // Returns false where the ray falls outside the usable image circle.
    bool project(Vec3 p_Ray, double& p_U, double& p_V) const
    {
        const double x = m_Rot[0][0] * p_Ray.x + m_Rot[0][1] * p_Ray.y + m_Rot[0][2] * p_Ray.z;
        const double y = m_Rot[1][0] * p_Ray.x + m_Rot[1][1] * p_Ray.y + m_Rot[1][2] * p_Ray.z;
        const double z = m_Rot[2][0] * p_Ray.x + m_Rot[2][1] * p_Ray.y + m_Rot[2][2] * p_Ray.z;
        const double den = z + m_Lens.xi;
        const bool front = den > 1e-6;
        const double mx = x / (front ? den : 1.0), my = y / (front ? den : 1.0);
        const double* d = m_Lens.d;
        const double r2 = mx * mx + my * my, r4 = r2 * r2;
        const double rad = 1.0 + d[0] * r2 + d[1] * r4 + d[2] * r2 * r4 + d[3] * r4 * r4;
        const double xd = mx * rad + 2.0 * d[5] * mx * my + d[6] * (r2 + 2.0 * mx * mx) + d[7] * r2 + d[8] * r4;
        const double yd = my * rad + d[5] * (r2 + 2.0 * my * my) + 2.0 * d[6] * mx * my + d[9] * r2 + d[10] * r4;
        const double fs = m_VideoWidth / kCropWidth, cs = m_VideoWidth / kSensorWidth;
        p_U = m_Lens.fx * fs * xd + m_Lens.cx * cs;
        p_V = m_Lens.fy * fs * yd + m_Lens.cy * cs;
        return front && hypot(p_U - m_VideoWidth / 2.0, p_V - m_VideoWidth / 2.0) < m_VideoWidth / 2.0 * 0.975;
    }

private:
    LensCalibration m_Lens;
    double m_VideoWidth;
    double m_Rot[3][3];
};

// Brightness (mean of the channels) at a point, exactly as cv2.remap (OpenCV 5, INTER_LINEAR)
// samples in refine_seam.py: pixel centres at whole numbers, black outside the image, linear in x
// then y in single precision, channels rounded to 8 bit.
static float SampleLuma(const unsigned char* p_Image, double p_U, double p_V)
{
    const float u = float(p_U), v = float(p_V);
    const float fx = floorf(u), fy = floorf(v);
    const int x0 = int(fx), y0 = int(fy);
    const float tx = u - fx, ty = v - fy;
    auto at = [&](int p_X, int p_Y, int p_C) {
        const bool inside = p_X >= 0 && p_Y >= 0 && p_X < kWorkSize && p_Y < kWorkSize;
        return inside ? float(p_Image[(size_t(p_Y) * kWorkSize + p_X) * 3 + p_C]) : 0.0f;
    };
    float sum = 0.0f;
    for (int c = 0; c < 3; ++c)
    {
        const float top = at(x0, y0, c) + (at(x0 + 1, y0, c) - at(x0, y0, c)) * tx;
        const float bottom = at(x0, y0 + 1, c) + (at(x0 + 1, y0 + 1, c) - at(x0, y0 + 1, c)) * tx;
        sum += rintf(top + (bottom - top) * ty);
    }
    return sum / 3.0f;
}

// Median as numpy computes it: the mean of the two middle values for an even count.
static double Median(std::vector<double> p_Values)
{
    std::sort(p_Values.begin(), p_Values.end());
    const size_t n = p_Values.size();
    return n % 2 ? p_Values[n / 2] : 0.5 * (p_Values[n / 2 - 1] + p_Values[n / 2]);
}

// Best (1/distance, along-seam degrees) per bin for one frame pair.
static void MeasureFrame(const unsigned char* p_A, const unsigned char* p_B, const LensCalibration p_Lenses[2],
                         double* p_QBest, double* p_AlongBest)
{
    const LensProjection lensA(p_Lenses[0], 0, kWorkSize), lensB(p_Lenses[1], 1, kWorkSize);
    const Vec3 half = {p_Lenses[1].t[0] / 2.0, p_Lenses[1].t[1] / 2.0, p_Lenses[1].t[2] / 2.0};
    const int perBin = kColumns / kBins;

    // Seam rays: kColumns around the seam, kRows across it within +-kBandDeg.
    std::vector<Vec3> rays(kRows * kColumns);
    for (int row = 0; row < kRows; ++row)
    {
        const double z = sin(kBandDeg * kDegToRad) * ((row + 0.5) / kRows * 2.0 - 1.0);
        const double c = sqrt(1.0 - z * z);
        for (int col = 0; col < kColumns; ++col)
        {
            const double phi = (col + 0.5) / kColumns * 2.0 * M_PI;
            rays[row * kColumns + col] = {c * cos(phi), c * sin(phi), z};
        }
    }

    // cost[(i * kAlongSteps + j) * kBins + bin]; each candidate distance runs on its own core.
    std::vector<double> cost(size_t(kInvDistances) * kAlongSteps * kBins);
    double* costOut = cost.data(); // blocks capture C++ objects as const copies
    const Vec3* rayIn = rays.data();
    const size_t rayCount = rays.size();
    dispatch_apply(kInvDistances, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t p_I) {
        const double q = InvDistance(int(p_I));
        std::vector<float> lumaA(rayCount);
        std::vector<char> validA(rayCount);
        std::vector<Vec3> rayB(rayCount);
        for (size_t k = 0; k < rayCount; ++k)
        {
            const Vec3 r = rayIn[k];
            double u, v;
            validA[k] = lensA.project(Normalized({r.x + half.x * q, r.y + half.y * q, r.z + half.z * q}), u, v);
            lumaA[k] = SampleLuma(p_A, u, v);
            rayB[k] = Normalized({r.x - half.x * q, r.y - half.y * q, r.z - half.z * q});
        }
        for (int j = 0; j < kAlongSteps; ++j)
        {
            double sum[kBins] = {}, count[kBins] = {};
            for (size_t k = 0; k < rayCount; ++k)
            {
                double u, v;
                const bool ok = lensB.project(TurnedAroundZ(rayB[k], AlongDeg(j)), u, v) && validA[k];
                if (ok)
                {
                    const int bin = int(k % kColumns) / perBin;
                    sum[bin] += fabsf(lumaA[k] - SampleLuma(p_B, u, v));
                    count[bin] += 1.0;
                }
            }
            for (int bin = 0; bin < kBins; ++bin)
            {
                costOut[(p_I * kAlongSteps + j) * kBins + bin] = sum[bin] / std::max(count[bin], 1.0);
            }
        }
    });

    // First lowest cost, in the same order as numpy's argmin.
    for (int bin = 0; bin < kBins; ++bin)
    {
        int best = 0;
        for (int c = 1; c < kInvDistances * kAlongSteps; ++c)
        {
            if (cost[size_t(c) * kBins + bin] < cost[size_t(best) * kBins + bin])
            {
                best = c;
            }
        }
        p_QBest[bin] = InvDistance(best / kAlongSteps);
        p_AlongBest[bin] = AlongDeg(best % kAlongSteps);
    }
}

// Least squares solution of p_J * x = p_R for p_J with m rows and n columns (row-major),
// by Householder QR. Overwrites p_J and p_R.
static void SolveLeastSquares(std::vector<double>& p_J, std::vector<double>& p_R, int p_M, int p_N, double* p_X)
{
    for (int k = 0; k < p_N; ++k)
    {
        double norm = 0.0;
        for (int i = k; i < p_M; ++i)
        {
            norm += p_J[i * p_N + k] * p_J[i * p_N + k];
        }
        norm = sqrt(norm);
        if (norm == 0.0)
        {
            continue;
        }
        const double alpha = p_J[k * p_N + k] > 0 ? -norm : norm;
        std::vector<double> v(p_M, 0.0);
        for (int i = k; i < p_M; ++i)
        {
            v[i] = p_J[i * p_N + k];
        }
        v[k] -= alpha;
        double vv = 0.0;
        for (int i = k; i < p_M; ++i)
        {
            vv += v[i] * v[i];
        }
        // Reflect the remaining columns and the right-hand side.
        for (int col = k; col <= p_N; ++col)
        {
            double dot = 0.0;
            for (int i = k; i < p_M; ++i)
            {
                dot += v[i] * (col < p_N ? p_J[i * p_N + col] : p_R[i]);
            }
            const double f = 2.0 * dot / vv;
            for (int i = k; i < p_M; ++i)
            {
                (col < p_N ? p_J[i * p_N + col] : p_R[i]) -= f * v[i];
            }
        }
    }
    for (int k = p_N - 1; k >= 0; --k)
    {
        double s = p_R[k];
        for (int col = k + 1; col < p_N; ++col)
        {
            s -= p_J[k * p_N + col] * p_X[col];
        }
        p_X[k] = p_J[k * p_N + k] != 0.0 ? s / p_J[k * p_N + k] : 0.0;
    }
}

// Fits lens B (yaw, pitch, cx, cy) and a parallax common to the whole seam (1/m) to the median
// shifts, by Gauss-Newton. p_QBest and p_AlongBest hold kBins values per frame.
class SeamFit
{
public:
    SeamFit(const LensCalibration p_Lenses[2], const std::vector<double>& p_QBest, const std::vector<double>& p_AlongBest)
        : m_Factory(p_Lenses[1])
    {
        const int frames = int(p_QBest.size()) / kBins;
        for (int bin = 0; bin < kBins; ++bin)
        {
            std::vector<double> q(frames), along(frames);
            for (int f = 0; f < frames; ++f)
            {
                q[f] = p_QBest[f * kBins + bin];
                along[f] = p_AlongBest[f * kBins + bin];
            }
            m_QMedian[bin] = Median(q);
            m_AlongMedian[bin] = Median(along);
            std::vector<double> qDev(frames), alongDev(frames);
            for (int f = 0; f < frames; ++f)
            {
                qDev[f] = fabs(q[f] - m_QMedian[bin]);
                alongDev[f] = fabs(along[f] - m_AlongMedian[bin]);
            }
            // Bins where the frames disagree (moving people close to the camera) count less.
            m_Weight[bin] = 1.0 / (0.05 + Median(alongDev) + 0.3 * Median(qDev));
            const double phi = (bin + 0.5) / kBins * 2.0 * M_PI;
            m_Seam[bin] = {cos(phi), sin(phi), 0.0};
        }
        m_Half = {m_Factory.t[0] / 2.0, m_Factory.t[1] / 2.0, m_Factory.t[2] / 2.0};
    }

    // Weighted residuals in lens B pixels (3840 wide): u for every bin, then v.
    void residual(const double p_X[5], double* p_Out) const
    {
        double u[kBins], v[kBins], tu[kBins], tv[kBins];
        model(p_X, u, v);
        target(p_X[4], tu, tv);
        for (int bin = 0; bin < kBins; ++bin)
        {
            p_Out[bin] = (u[bin] - tu[bin]) * sqrt(m_Weight[bin]);
            p_Out[kBins + bin] = (v[bin] - tv[bin]) * sqrt(m_Weight[bin]);
        }
    }

    // Median distance between model and target over the seam, unweighted.
    double misalignment(const double p_X[5]) const
    {
        double u[kBins], v[kBins], tu[kBins], tv[kBins];
        model(p_X, u, v);
        target(p_X[4], tu, tv);
        std::vector<double> d(kBins);
        for (int bin = 0; bin < kBins; ++bin)
        {
            d[bin] = hypot(u[bin] - tu[bin], v[bin] - tv[bin]);
        }
        return Median(d);
    }

    void solve(double p_X[5]) const
    {
        const int m = 2 * kBins, n = 5;
        std::fill(p_X, p_X + n, 0.0);
        for (int iteration = 0; iteration < 50; ++iteration)
        {
            std::vector<double> r(m), jac(size_t(m) * n), shifted(m);
            residual(p_X, r.data());
            for (int k = 0; k < n; ++k)
            {
                double x[5];
                std::copy(p_X, p_X + n, x);
                x[k] += 1e-4;
                residual(x, shifted.data());
                for (int i = 0; i < m; ++i)
                {
                    jac[i * n + k] = (shifted[i] - r[i]) / 1e-4;
                }
            }
            for (double& value : r)
            {
                value = -value;
            }
            double step[5];
            SolveLeastSquares(jac, r, m, n, step);
            double largest = 0.0;
            for (int k = 0; k < n; ++k)
            {
                p_X[k] += step[k];
                largest = std::max(largest, fabs(step[k]));
            }
            if (largest < 1e-6)
            {
                break;
            }
        }
    }

private:
    // Lens B pixel positions as the plugin computes them, with the correction p_X applied.
    void model(const double p_X[5], double* p_U, double* p_V) const
    {
        LensCalibration lens = m_Factory;
        lens.yaw += p_X[0];
        lens.pitch += p_X[1];
        lens.cx += p_X[2];
        lens.cy += p_X[3];
        const LensProjection projection(lens, 1, 3840.0);
        for (int bin = 0; bin < kBins; ++bin)
        {
            const Vec3 s = m_Seam[bin];
            projection.project(Normalized({s.x - m_Half.x * p_X[4], s.y - m_Half.y * p_X[4], s.z - m_Half.z * p_X[4]}),
                               p_U[bin], p_V[bin]);
        }
    }

    // Where lens B should be sampled: the measured shift, less a parallax common to the whole seam.
    void target(double p_Q0, double* p_U, double* p_V) const
    {
        const LensProjection projection(m_Factory, 1, 3840.0);
        for (int bin = 0; bin < kBins; ++bin)
        {
            const Vec3 s = m_Seam[bin];
            const double q = m_QMedian[bin] - p_Q0;
            const Vec3 ray = Normalized({s.x - m_Half.x * q, s.y - m_Half.y * q, s.z - m_Half.z * q});
            projection.project(TurnedAroundZ(ray, m_AlongMedian[bin]), p_U[bin], p_V[bin]);
        }
    }

    LensCalibration m_Factory;
    Vec3 m_Half;
    Vec3 m_Seam[kBins];
    double m_QMedian[kBins], m_AlongMedian[kBins], m_Weight[kBins];
};

int main(int argc, char** argv)
{
    if (argc != 3)
    {
        fprintf(stderr, "usage: SeamRefine calibration_raw frameCount < frames.rgb\n"
                        "  frames: lens A then lens B for each frame, %dx%d 8-bit RGB\n", kWorkSize, kWorkSize);
        return 2;
    }
    LensCalibration lenses[2];
    if (!ParseCalibration(argv[1], lenses))
    {
        fprintf(stderr, "not a 2-lens calibration string\n");
        return 1;
    }
    const int frames = atoi(argv[2]);
    if (frames < 1)
    {
        fprintf(stderr, "need at least one frame\n");
        return 2;
    }

    const size_t frameBytes = size_t(kWorkSize) * kWorkSize * 3;
    std::vector<unsigned char> a(frameBytes), b(frameBytes);
    std::vector<double> qBest(size_t(frames) * kBins), alongBest(size_t(frames) * kBins);
    for (int f = 0; f < frames; ++f)
    {
        if (fread(a.data(), 1, frameBytes, stdin) != frameBytes || fread(b.data(), 1, frameBytes, stdin) != frameBytes)
        {
            fprintf(stderr, "cannot read frame pair %d from stdin\n", f);
            return 1;
        }
        MeasureFrame(a.data(), b.data(), lenses, &qBest[size_t(f) * kBins], &alongBest[size_t(f) * kBins]);
    }

    const SeamFit fit(lenses, qBest, alongBest);
    double x[5];
    fit.solve(x);
    const double factoryOnly[5] = {0.0, 0.0, 0.0, 0.0, x[4]};
    printf("{\"lens\": 1, \"yaw\": %.6f, \"pitch\": %.6f, \"cx\": %.4f, \"cy\": %.4f, \"inv_distance\": %.4f, "
           "\"frames\": %d, \"misalignment_px\": [%.3f, %.3f]}\n",
           x[0], x[1], x[2], x[3], x[4], frames, fit.misalignment(factoryOnly), fit.misalignment(x));
    return 0;
}
