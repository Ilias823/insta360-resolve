#include "Tracker.h"

#include <cmath>
#include <cstring>

static const int kTemplateSize = 48;  // pixels across the subject box
static const int kSearchScale = 3;    // the search area is this many boxes wide
static const double kLostConfidence = 0.33;
static const int kLostFrames = 12;     // frames in a row below kLostConfidence before giving up
static const double kUpdateConfidence = 0.6;
static const float kTemplateBlend = 0.15f;
static const double kMotionPenalty = 0.35;  // score lost per (box width)^2 away from the prediction
static const double kMaxJump = 0.6;         // largest believable move per frame, in box widths

static const double kDegToRad = M_PI / 180.0;

// Rig-space direction of a view at pan/tilt (degrees), and of a point on its image plane.
static void ViewRay(double p_Pan, double p_Tilt, double p_U, double p_V, double p_Ray[3])
{
    double r[9];
    ViewRotation(p_Pan, p_Tilt, 0.0, r);
    const double c[3] = {p_U, p_V, 1.0};
    for (int i = 0; i < 3; ++i)
    {
        p_Ray[i] = r[i * 3] * c[0] + r[i * 3 + 1] * c[1] + r[i * 3 + 2] * c[2];
    }
}

// Same lens model as the Metal kernel (MetalKernel.mm). Returns false outside the image circle.
static bool ProjectToLens(const float* p_Lens, int p_TileW, int p_TileH, const double p_Ray[3], double& p_X, double& p_Y)
{
    const float* o = p_Lens;
    const double lx = o[eLensRot + 0] * p_Ray[0] + o[eLensRot + 1] * p_Ray[1] + o[eLensRot + 2] * p_Ray[2];
    const double ly = o[eLensRot + 3] * p_Ray[0] + o[eLensRot + 4] * p_Ray[1] + o[eLensRot + 5] * p_Ray[2];
    const double lz = o[eLensRot + 6] * p_Ray[0] + o[eLensRot + 7] * p_Ray[1] + o[eLensRot + 8] * p_Ray[2];
    const double n = sqrt(lx * lx + ly * ly + lz * lz);
    const double den = lz / n + o[eLensXi];
    if (den <= 1e-6)
    {
        return false;
    }
    const double x = lx / n / den, y = ly / n / den;
    const double r2 = x * x + y * y, r4 = r2 * r2;
    const double radial = 1.0 + o[eLensK1] * r2 + o[eLensK2] * r4 + o[eLensK3] * r2 * r4 + o[eLensK4] * r4 * r4;
    const double xd = x * radial + 2.0 * o[eLensP1] * x * y + o[eLensP2] * (r2 + 2.0 * x * x) + o[eLensS1] * r2 + o[eLensS2] * r4;
    const double yd = y * radial + o[eLensP1] * (r2 + 2.0 * y * y) + 2.0 * o[eLensP2] * x * y + o[eLensS3] * r2 + o[eLensS4] * r4;
    p_X = o[eLensFx] * xd + o[eLensCx];
    p_Y = o[eLensFy] * yd + o[eLensCy];
    const double rx = (p_X - p_TileW * 0.5) / (p_TileW * 0.5), ry = (p_Y - p_TileH * 0.5) / (p_TileH * 0.5);
    return rx * rx + ry * ry < 0.975 * 0.975;
}

static const float* PixelAt(const FrameView& p_Frame, int p_Lens, double p_X, double p_Y)
{
    const int tileW = p_Frame.width / 2;
    const int x = int(fmin(fmax(p_X, 0.0), tileW - 1.0)) + p_Lens * tileW;
    const int yTop = int(fmin(fmax(p_Y, 0.0), p_Frame.height - 1.0));
    const int row = p_Frame.bottomUp ? p_Frame.height - 1 - yTop : yTop;
    return reinterpret_cast<const float*>(p_Frame.data + long(row) * p_Frame.rowBytes) + x * 4;
}

// Patches hold the three colour channels one after the other. Each channel is made zero mean
// and unit norm, so matches do not depend on brightness or contrast but colour still counts.
static void Normalise(std::vector<float>& p_Patch)
{
    const size_t plane = p_Patch.size() / 3;
    for (int c = 0; c < 3; ++c)
    {
        float* v = &p_Patch[c * plane];
        double sum = 0.0;
        for (size_t i = 0; i < plane; ++i)
        {
            sum += v[i];
        }
        const float mean = float(sum / plane);
        double sq = 0.0;
        for (size_t i = 0; i < plane; ++i)
        {
            v[i] -= mean;
            sq += double(v[i]) * v[i];
        }
        const float scale = sq > 1e-12 ? float(1.0 / sqrt(sq)) : 0.0f;
        for (size_t i = 0; i < plane; ++i)
        {
            v[i] *= scale;
        }
    }
}

SubjectTracker::SubjectTracker(const LensCalibration p_Lenses[2], double p_SubjectDeg)
    : m_SubjectDeg(fmin(fmax(p_SubjectDeg, 2.0), 50.0)), m_Pan(0), m_Tilt(0), m_VelPan(0), m_VelTilt(0),
      m_LowFrames(0), m_LensFrameW(0), m_LensFrameH(0)
{
    m_Lenses[0] = p_Lenses[0];
    m_Lenses[1] = p_Lenses[1];
}

void SubjectTracker::renderPatch(const FrameView& p_Frame, double p_Pan, double p_Tilt, double p_HalfAngle, int p_Size, std::vector<float>& p_Out)
{
    if (p_Frame.width != m_LensFrameW || p_Frame.height != m_LensFrameH)
    {
        FillLensParams(m_Lenses, p_Frame.width, p_Frame.height, m_Lens);
        m_LensFrameW = p_Frame.width;
        m_LensFrameH = p_Frame.height;
    }

    const double extent = tan(p_HalfAngle * kDegToRad);
    const int tileW = p_Frame.width / 2;
    const size_t plane = size_t(p_Size) * p_Size;
    p_Out.assign(plane * 3, 0.0f);
    for (int j = 0; j < p_Size; ++j)
    {
        for (int i = 0; i < p_Size; ++i)
        {
            const double u = ((i + 0.5) / p_Size * 2.0 - 1.0) * extent;
            const double v = ((j + 0.5) / p_Size * 2.0 - 1.0) * extent;
            double ray[3];
            ViewRay(p_Pan, p_Tilt, u, v, ray);

            // Lens A faces +z; use the lens the ray points into, the other one as a fallback.
            const int first = ray[2] >= 0.0 ? 0 : 1;
            double x, y;
            for (int k = 0; k < 2; ++k)
            {
                const int lens = k == 0 ? first : 1 - first;
                if (ProjectToLens(m_Lens + lens * eLensSlotCount, tileW, p_Frame.height, ray, x, y))
                {
                    const float* px = PixelAt(p_Frame, lens, x, y);
                    for (int c = 0; c < 3; ++c)
                    {
                        p_Out[c * plane + size_t(j) * p_Size + i] = px[c];
                    }
                    break;
                }
            }
        }
    }
}

bool SubjectTracker::isConfident(double p_Confidence)
{
    return p_Confidence >= kLostConfidence;
}

void SubjectTracker::start(const FrameView& p_Frame, double p_Pan, double p_Tilt)
{
    m_Pan = p_Pan;
    m_Tilt = p_Tilt;
    m_VelPan = m_VelTilt = 0.0;
    m_LowFrames = 0;
    renderPatch(p_Frame, m_Pan, m_Tilt, m_SubjectDeg / 2.0, kTemplateSize, m_Template);
    Normalise(m_Template);
}

bool SubjectTracker::step(const FrameView& p_Frame, double& p_Pan, double& p_Tilt, double& p_Confidence)
{
    // Search around where the subject should be if it keeps moving the same way.
    const double predPan = m_Pan + m_VelPan;
    const double predTilt = fmin(fmax(m_Tilt + m_VelTilt, -89.0), 89.0);
    const int n = kTemplateSize * kSearchScale;
    const double searchHalf = atan(kSearchScale * tan(m_SubjectDeg / 2.0 * kDegToRad)) / kDegToRad;
    std::vector<float> search;
    renderPatch(p_Frame, predPan, predTilt, searchHalf, n, search);

    // Integral images of each channel of the search patch give every window's mean and spread cheaply.
    const int t = kTemplateSize;
    const size_t searchPlane = size_t(n) * n, templatePlane = size_t(t) * t;
    std::vector<double> sum(3 * (n + 1) * (n + 1), 0.0), sq(3 * (n + 1) * (n + 1), 0.0);
    for (int c = 0; c < 3; ++c)
    {
        double* S = &sum[c * (n + 1) * (n + 1)];
        double* Q = &sq[c * (n + 1) * (n + 1)];
        const float* v = &search[c * searchPlane];
        for (int y = 0; y < n; ++y)
        {
            for (int x = 0; x < n; ++x)
            {
                const double a = v[size_t(y) * n + x];
                S[(y + 1) * (n + 1) + x + 1] = a + S[y * (n + 1) + x + 1] + S[(y + 1) * (n + 1) + x] - S[y * (n + 1) + x];
                Q[(y + 1) * (n + 1) + x + 1] = a * a + Q[y * (n + 1) + x + 1] + Q[(y + 1) * (n + 1) + x] - Q[y * (n + 1) + x];
            }
        }
    }

    const int span = n - t + 1;
    const double centre = (span - 1) * 0.5;
    std::vector<float> score(size_t(span) * span, -1.0f);
    double best = -2.0, bestNcc = -1.0;
    int bestX = span / 2, bestY = span / 2;
    for (int oy = 0; oy < span; ++oy)
    {
        for (int ox = 0; ox < span; ++ox)
        {
            double ncc = 0.0;
            for (int c = 0; c < 3; ++c)
            {
                const double* S = &sum[c * (n + 1) * (n + 1)];
                const double* Q = &sq[c * (n + 1) * (n + 1)];
                auto box = [&](const double* a) {
                    return a[(oy + t) * (n + 1) + ox + t] - a[oy * (n + 1) + ox + t] - a[(oy + t) * (n + 1) + ox] + a[oy * (n + 1) + ox];
                };
                const double s1 = box(S), s2 = box(Q);
                const double var = s2 - s1 * s1 / (t * t);
                if (var < 1e-9)
                {
                    continue;
                }
                // The template has zero mean, so the window's own mean drops out of the product.
                double dot = 0.0;
                for (int y = 0; y < t; ++y)
                {
                    const float* a = &search[c * searchPlane + size_t(oy + y) * n + ox];
                    const float* b = &m_Template[c * templatePlane + size_t(y) * t];
                    for (int x = 0; x < t; ++x)
                    {
                        dot += a[x] * b[x];
                    }
                }
                ncc += dot / sqrt(var) / 3.0;
            }

            // Prefer matches near where the subject was expected: subjects do not teleport.
            const double dx = (ox - centre) / t, dy = (oy - centre) / t;
            const double d2 = dx * dx + dy * dy;
            const double value = d2 > kMaxJump * kMaxJump ? -1.0 : ncc - kMotionPenalty * d2;
            score[size_t(oy) * span + ox] = float(value);
            if (value > best)
            {
                best = value;
                bestNcc = ncc;
                bestX = ox;
                bestY = oy;
            }
        }
    }
    p_Confidence = fmax(bestNcc, 0.0);

    if (bestNcc < kLostConfidence)
    {
        // Not convincing: stay put and stop extrapolating, but keep looking for a while.
        m_VelPan *= 0.5;
        m_VelTilt *= 0.5;
        p_Pan = m_Pan;
        p_Tilt = m_Tilt;
        return ++m_LowFrames < kLostFrames;
    }
    m_LowFrames = 0;

    // Sub-pixel peak from a parabola through the neighbouring scores.
    auto refine = [&](int i, float l, float c, float r) {
        const float d = l - 2.0f * c + r;
        return (i > 0 && i < span - 1 && fabsf(d) > 1e-6f) ? 0.5f * (l - r) / d : 0.0f;
    };
    const float c = score[size_t(bestY) * span + bestX];
    const double fx = bestX + refine(bestX, bestX > 0 ? score[size_t(bestY) * span + bestX - 1] : c, c,
                                     bestX < span - 1 ? score[size_t(bestY) * span + bestX + 1] : c);
    const double fy = bestY + refine(bestY, bestY > 0 ? score[size_t(bestY - 1) * span + bestX] : c, c,
                                     bestY < span - 1 ? score[size_t(bestY + 1) * span + bestX] : c);

    // Centre of the best window -> direction in the rig -> pan and tilt.
    const double extent = tan(searchHalf * kDegToRad);
    const double u = ((fx + t * 0.5) / n * 2.0 - 1.0) * extent;
    const double v = ((fy + t * 0.5) / n * 2.0 - 1.0) * extent;
    double ray[3];
    ViewRay(predPan, predTilt, u, v, ray);
    const double len = sqrt(ray[0] * ray[0] + ray[1] * ray[1] + ray[2] * ray[2]);
    double pan = atan2(ray[0], ray[2]) / kDegToRad;
    const double tilt = asin(fmin(fmax(-ray[1] / len, -1.0), 1.0)) / kDegToRad;
    pan += 360.0 * round((m_Pan - pan) / 360.0); // keep pan continuous across +-180

    m_VelPan = 0.6 * m_VelPan + 0.4 * (pan - m_Pan);
    m_VelTilt = 0.6 * m_VelTilt + 0.4 * (tilt - m_Tilt);
    m_Pan = pan;
    m_Tilt = tilt;

    // Let the remembered appearance follow slow changes (turning, light), but only from good matches.
    if (bestNcc > kUpdateConfidence)
    {
        std::vector<float> now;
        renderPatch(p_Frame, m_Pan, m_Tilt, m_SubjectDeg / 2.0, kTemplateSize, now);
        Normalise(now);
        for (size_t i = 0; i < m_Template.size(); ++i)
        {
            m_Template[i] = (1.0f - kTemplateBlend) * m_Template[i] + kTemplateBlend * now[i];
        }
        Normalise(m_Template);
    }

    p_Pan = m_Pan;
    p_Tilt = m_Tilt;
    return true;
}
