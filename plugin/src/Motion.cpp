#include "Motion.h"

#include <cmath>
#include <cstring>
#include <fstream>
#include <map>
#include <mutex>

namespace
{
struct Mat
{
    double m[9];
    double operator()(int r, int c) const { return m[r * 3 + c]; }
};

Mat FromQuat(const float* q)
{
    const double w = q[0], x = q[1], y = q[2], z = q[3];
    return {{1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w),
             2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w),
             2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)}};
}

Mat Mul(const Mat& a, const Mat& b)
{
    Mat r{};
    for (int i = 0; i < 3; ++i)
        for (int j = 0; j < 3; ++j)
            r.m[i * 3 + j] = a(i, 0) * b(0, j) + a(i, 1) * b(1, j) + a(i, 2) * b(2, j);
    return r;
}

Mat Transposed(const Mat& a)
{
    return {{a(0, 0), a(1, 0), a(2, 0), a(0, 1), a(1, 1), a(2, 1), a(0, 2), a(1, 2), a(2, 2)}};
}

void Apply(const Mat& a, const double v[3], double out[3])
{
    for (int i = 0; i < 3; ++i)
        out[i] = a(i, 0) * v[0] + a(i, 1) * v[1] + a(i, 2) * v[2];
}

void Normalise(double v[3])
{
    const double n = sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (n > 1e-12)
        for (int i = 0; i < 3; ++i)
            v[i] /= n;
}

// Smallest rotation turning unit vector a onto unit vector b.
Mat RotationBetween(const double a[3], const double b[3])
{
    const double c[3] = {a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]};
    const double cosA = a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
    if (cosA < -0.999999)
        return {{1, 0, 0, 0, -1, 0, 0, 0, -1}};
    const double k = 1.0 / (1.0 + cosA);
    return {{c[0] * c[0] * k + cosA, c[0] * c[1] * k - c[2], c[0] * c[2] * k + c[1],
             c[1] * c[0] * k + c[2], c[1] * c[1] * k + cosA, c[1] * c[2] * k - c[0],
             c[2] * c[0] * k - c[1], c[2] * c[1] * k + c[0], c[2] * c[2] * k + cosA}};
}
}

std::shared_ptr<const MotionData> MotionData::Load(const std::string& p_Path)
{
    static std::mutex mutex;
    static std::map<std::string, std::shared_ptr<const MotionData>> cache;

    std::lock_guard<std::mutex> lock(mutex);
    const auto it = cache.find(p_Path);
    if (it != cache.end())
    {
        return it->second;
    }

    std::shared_ptr<MotionData> data;
    std::ifstream file(p_Path, std::ios::binary);
    char magic[8];
    uint32_t count = 0;
    float fps = 0.0f;
    if (file.read(magic, 8) && memcmp(magic, "I360MOT1", 8) == 0 && file.read(reinterpret_cast<char*>(&count), 4) &&
        file.read(reinterpret_cast<char*>(&fps), 4) && count > 0 && count < 10000000)
    {
        std::vector<float> values(size_t(count) * 7);
        if (file.read(reinterpret_cast<char*>(values.data()), std::streamsize(values.size() * sizeof(float))))
        {
            data = std::make_shared<MotionData>();
            data->m_Fps = fps > 0.0f ? fps : 30.0;
            data->m_Quats.resize(size_t(count) * 4);
            data->m_Up.resize(size_t(count) * 3);
            for (uint32_t i = 0; i < count; ++i)
            {
                memcpy(&data->m_Quats[i * 4], &values[i * 7], 4 * sizeof(float));
                memcpy(&data->m_Up[i * 3], &values[i * 7 + 4], 3 * sizeof(float));
            }
        }
    }
    cache[p_Path] = data;
    return data;
}

void MotionData::viewToCamera(double p_Frame, int p_Mode, double p_Smoothness, bool p_Level, double p_R[9]) const
{
    const int n = frames();
    const int k = std::max(0, std::min(n - 1, int(lround(p_Frame))));
    const Mat camera = FromQuat(&m_Quats[size_t(k) * 4]); // camera -> world (world = first frame's camera)

    // Level: which way is up in the world, from the accelerometer averaged over about two
    // seconds (also absorbs slow gyro drift), turned onto the picture's up (-y).
    Mat level = {{1, 0, 0, 0, 1, 0, 0, 0, 1}};
    if (p_Level)
    {
        const int half = std::max(1, int(m_Fps));
        double up[3] = {0, 0, 0};
        for (int j = std::max(0, k - half); j <= std::min(n - 1, k + half); ++j)
        {
            double world[3];
            const double cam[3] = {m_Up[j * 3], m_Up[j * 3 + 1], m_Up[j * 3 + 2]};
            Apply(FromQuat(&m_Quats[size_t(j) * 4]), cam, world);
            for (int i = 0; i < 3; ++i)
                up[i] += world[i];
        }
        Normalise(up);
        const double screenUp[3] = {0, -1, 0};
        level = RotationBetween(up, screenUp);
    }

    // Where the view looks, in the (levelled) world.
    Mat view;
    if (p_Mode == 2)
    {
        view = {{1, 0, 0, 0, 1, 0, 0, 0, 1}}; // locked: the direction of the first frame
    }
    else
    {
        // Smooth: the camera's direction averaged over a window, weighted towards the middle.
        const int half = std::max(0, int(p_Smoothness * m_Fps));
        const double sigma = std::max(1.0, half / 2.0);
        double forward[3] = {0, 0, 0}, down[3] = {0, 0, 0};
        for (int j = std::max(0, k - half); j <= std::min(n - 1, k + half); ++j)
        {
            const double w = exp(-0.5 * (j - k) * (j - k) / (sigma * sigma));
            const Mat c = Mul(level, FromQuat(&m_Quats[size_t(j) * 4]));
            for (int i = 0; i < 3; ++i)
            {
                forward[i] += w * c(i, 2);
                down[i] += w * c(i, 1);
            }
        }
        if (p_Level)
        {
            down[0] = 0;
            down[1] = 1;
            down[2] = 0;
            forward[1] = 0; // keep the view's heading, drop its tilt: the horizon stays level
        }
        Normalise(forward);
        // Orthonormal basis: z forward, y down (made perpendicular), x = y cross z.
        const double dot = down[0] * forward[0] + down[1] * forward[1] + down[2] * forward[2];
        for (int i = 0; i < 3; ++i)
            down[i] -= dot * forward[i];
        Normalise(down);
        const double right[3] = {down[1] * forward[2] - down[2] * forward[1], down[2] * forward[0] - down[0] * forward[2],
                                 down[0] * forward[1] - down[1] * forward[0]};
        view = {{right[0], down[0], forward[0], right[1], down[1], forward[1], right[2], down[2], forward[2]}};
    }

    // view -> levelled world -> world -> camera
    const Mat result = Mul(Transposed(camera), Mul(Transposed(level), view));
    memcpy(p_R, result.m, sizeof(result.m));
}
