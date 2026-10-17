#include "Calibration.h"

#include <cmath>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <vector>

// The calibration is expressed on a sensor canvas of 2 x 5376 pixels. Focal lengths are
// relative to a 5312-wide crop; this value gave the best seam match (see tools/stitch_poc.py).
static const double kSensorWidth = 5376.0;
static const double kCropWidth = 5312.0;
static const int kValuesPerLens = 27;

// Lens B centre, yaw and pitch as refined by tools/refine_seam.py; the factory values were
// 8062.150, 2690.350, 0.323 and 0.447, which leave lens B about 20 px off at the seam.
const char* kNominalX5Calibration =
    "2_2.000000_4264.160_4266.470_2697.800_2693.370_-0.021_-0.155_89.784_0.000000_0.000000_0.000000"
    "_0.26931798_0.99488676_1.78469694_-7.65584230_0.00000000_0.00230029_-0.00049182_0.01725985"
    "_0.01396792_-0.01280056_-0.00447632_-0.03460722_-0.02751778_10752_5376_113"
    "_2.000000_4283.800_4284.060_8030.333_2677.938_-1.698_0.727_90.261_0.000364_0.000098_-0.031785"
    "_0.24678312_1.28443301_0.28077272_-5.51394606_0.00000000_-0.00124756_-0.00144671_-0.00035562"
    "_0.00113183_-0.00153601_0.00170881_0.00852254_0.00148579_10752_5376_113";

bool ParseCalibration(const std::string& p_Raw, LensCalibration p_Lenses[2])
{
    std::vector<double> v;
    std::stringstream ss(p_Raw);
    std::string token;
    while (std::getline(ss, token, '_'))
    {
        char* end = nullptr;
        const double value = strtod(token.c_str(), &end);
        if (end == token.c_str())
        {
            break;
        }
        v.push_back(value);
    }

    if (v.size() < 1 + 2 * kValuesPerLens || v[0] != 2.0)
    {
        return false;
    }

    for (int i = 0; i < 2; ++i)
    {
        const double* s = &v[1 + i * kValuesPerLens];
        LensCalibration& lens = p_Lenses[i];
        lens.xi = s[0];
        lens.fx = s[1];
        lens.fy = s[2];
        lens.cx = s[3] - i * kSensorWidth; // the second lens is stored offset by one sensor width
        lens.cy = s[4];
        lens.yaw = s[5];
        lens.pitch = s[6];
        lens.roll = s[7];
        for (int k = 0; k < 3; ++k)
        {
            lens.t[k] = s[8 + k];
        }
        for (int k = 0; k < 13; ++k)
        {
            lens.d[k] = s[11 + k];
        }
    }
    return true;
}

bool ReadCalibrationFile(const std::string& p_Path, std::string& p_Raw)
{
    std::ifstream file(p_Path);
    if (!file)
    {
        return false;
    }
    std::stringstream buffer;
    buffer << file.rdbuf();
    const std::string text = buffer.str();

    const std::string key = "\"calibration_raw\"";
    size_t pos = text.find(key);
    if (pos == std::string::npos)
    {
        return false;
    }
    pos = text.find('"', text.find(':', pos + key.size()));
    const size_t end = text.find('"', pos + 1);
    if (pos == std::string::npos || end == std::string::npos)
    {
        return false;
    }
    p_Raw = text.substr(pos + 1, end - pos - 1);
    return true;
}

void ViewRotation(double p_Pan, double p_Tilt, double p_Roll, double p_R[9])
{
    const double degToRad = M_PI / 180.0;
    const double cy = cos(p_Pan * degToRad), sy = sin(p_Pan * degToRad);
    const double cx = cos(p_Tilt * degToRad), sx = sin(p_Tilt * degToRad);
    const double cz = cos(p_Roll * degToRad), sz = sin(p_Roll * degToRad);
    const double r[9] = {
        cy * cz + sy * sx * sz, -cy * sz + sy * sx * cz, sy * cx,
        cx * sz,                cx * cz,                 -sx,
        -sy * cz + cy * sx * sz, sy * sz + cy * sx * cz, cy * cx};
    for (int i = 0; i < 9; ++i)
    {
        p_R[i] = r[i];
    }
}

double MaxFieldOfView(double p_Distance)
{
    // Edge directions reach the camera's horizon at 2 * acos(-distance); stay 20 degrees short of it.
    const double d = fmin(fmax(p_Distance, 0.0), 1.0);
    return fmin(2.0 * acos(-d) * 180.0 / M_PI - 20.0, 340.0);
}

double AutoDistance(double p_Fov)
{
    return fmin(fmax((p_Fov - 100.0) / 160.0, 0.0), 1.0);
}

void FillViewParams(double p_Pan, double p_Tilt, double p_Roll, double p_Fov, double p_Distance, double p_Aspect, StitchParams& p_Params)
{
    const double degToRad = M_PI / 180.0;

    // A direction at angle theta from the view axis lands at sin(theta) / (cos(theta) + distance)
    // on the image plane, so the half extent of the plane follows from half the field of view.
    const double d = fmin(fmax(fmax(p_Distance, AutoDistance(p_Fov)), 0.0), 1.0);
    const double halfFov = fmin(fmax(p_Fov, 1.0), MaxFieldOfView(d)) * degToRad / 2.0;
    const double plane = sin(halfFov) / (cos(halfFov) + d);
    p_Params.distance = float(d);
    // The field of view spans the longer side of the frame, so a vertical timeline shows the
    // same amount of the scene as a horizontal one turned on its side.
    const double aspect = fmax(p_Aspect, 1e-6);
    p_Params.planeX = float(aspect >= 1.0 ? plane : plane * aspect);
    p_Params.planeY = float(aspect >= 1.0 ? plane / aspect : plane);

    double r[9];
    ViewRotation(p_Pan, p_Tilt, p_Roll, r);
    for (int i = 0; i < 9; ++i)
    {
        p_Params.camRot[i] = float(r[i]);
    }
}

void ViewPointToRay(const StitchParams& p_Params, double p_U, double p_V, double p_Ray[3])
{
    const double px = (p_U * 2.0 - 1.0) * p_Params.planeX;
    const double py = (p_V * 2.0 - 1.0) * p_Params.planeY;
    const double d = p_Params.distance;
    const double r2 = px * px + py * py;
    const double t = (d + sqrt(fmax(1.0 + r2 * (1.0 - d * d), 0.0))) / (r2 + 1.0);
    const double cam[3] = {px * t, py * t, t - d};
    for (int i = 0; i < 3; ++i)
    {
        p_Ray[i] = p_Params.camRot[i * 3] * cam[0] + p_Params.camRot[i * 3 + 1] * cam[1] + p_Params.camRot[i * 3 + 2] * cam[2];
    }
}

void FillLensParams(const LensCalibration p_Lenses[2], int p_FrameWidth, int p_FrameHeight, float* p_Out)
{
    const double lensWidth = p_FrameWidth / 2.0;
    const double lensHeight = p_FrameHeight;
    const double degToRad = M_PI / 180.0;

    for (int i = 0; i < 2; ++i)
    {
        const LensCalibration& lens = p_Lenses[i];
        float* o = p_Out + i * eLensSlotCount;

        o[eLensFx] = float(lens.fx * lensWidth / kCropWidth);
        o[eLensFy] = float(lens.fy * lensHeight / kCropWidth);
        o[eLensCx] = float(lens.cx * lensWidth / kSensorWidth);
        o[eLensCy] = float(lens.cy * lensHeight / kSensorWidth);
        o[eLensXi] = float(lens.xi);
        o[eLensK1] = float(lens.d[0]);
        o[eLensK2] = float(lens.d[1]);
        o[eLensK3] = float(lens.d[2]);
        o[eLensK4] = float(lens.d[3]);
        o[eLensP1] = float(lens.d[5]);
        o[eLensP2] = float(lens.d[6]);
        o[eLensS1] = float(lens.d[7]);
        o[eLensS2] = float(lens.d[8]);
        o[eLensS3] = float(lens.d[9]);
        o[eLensS4] = float(lens.d[10]);

        // Lens orientation in the rig: R = Ry(yaw) * Rx(pitch), with the second lens facing backwards.
        // Roll is close to 90 degrees for both lenses and is not applied, as in the reference stitch.
        const double yaw = (lens.yaw + (i == 1 ? 180.0 : 0.0)) * degToRad;
        const double pitch = lens.pitch * degToRad;
        const double cy = cos(yaw), sy = sin(yaw), cp = cos(pitch), sp = sin(pitch);
        const double r[3][3] = {{cy, sy * sp, sy * cp}, {0.0, cp, -sp}, {-sy, cy * sp, cy * cp}};

        // The kernel needs rig-to-lens, which is the transpose.
        for (int row = 0; row < 3; ++row)
        {
            for (int col = 0; col < 3; ++col)
            {
                o[eLensRot + row * 3 + col] = float(r[col][row]);
            }
        }
    }
}

void FillLensOffset(const LensCalibration p_Lenses[2], StitchParams& p_Params)
{
    // The X5 lenses sit about 3 cm apart along the viewing axis. Matches tools/stitch_poc.py lens_offset().
    for (int k = 0; k < 3; ++k)
    {
        p_Params.lensOffset[k] = float(p_Lenses[1].t[k]);
    }
}
