#pragma once

#include <string>

#include "StitchKernel.h"

// One lens of the Insta360 calibration string (27 values per lens, see tools/insv_trailer.py).
struct LensCalibration
{
    double xi, fx, fy, cx, cy;
    double yaw, pitch, roll; // degrees
    double t[3];             // lens position, metres; the second lens's is relative to the first
    double d[13];            // k1 k2 k3 k4 (unused) p1 p2 s1 s2 s3 s4 ...
};

// Calibration of the X5 this project was developed with. Used when no file is given;
// good enough to see a picture, but every camera has its own values.
extern const char* kNominalX5Calibration;

// Parses "2_<27 values>_<27 values>...". Returns false if the string is not a 2-lens calibration.
bool ParseCalibration(const std::string& p_Raw, LensCalibration p_Lenses[2]);

// Reads the "calibration_raw" value from a sidecar .json written by tools/ingest.py.
bool ReadCalibrationFile(const std::string& p_Path, std::string& p_Raw);

// Rotation of a view in the rig frame (x right, y down, z forward): R = Ry(pan) * Rx(tilt) * Rz(roll),
// degrees, row-major. Pan turns right, tilt looks up, roll turns clockwise.
void ViewRotation(double p_Pan, double p_Tilt, double p_Roll, double p_R[9]);

// Widest field of view, in degrees, that the reframe camera can show at a given distance.
double MaxFieldOfView(double p_Distance);

// Least distance a field of view needs to look natural: up to 100 degrees a linear lens is
// fine, beyond that the picture has to curve more and more to avoid stretched edges.
double AutoDistance(double p_Fov);

// Sets up the virtual camera for eModeReframe. Angles in degrees: pan to the right, tilt up,
// roll clockwise. p_Fov is the field of view across the longer side, p_Aspect the output width / height.
void FillViewParams(double p_Pan, double p_Tilt, double p_Roll, double p_Fov, double p_Distance, double p_Aspect, StitchParams& p_Params);

// Rig-space direction seen at a point of the reframed view; p_U and p_V run 0..1 across the
// frame, p_V from the top. Same maths as the Metal kernel.
void ViewPointToRay(const StitchParams& p_Params, double p_U, double p_V, double p_Ray[3]);

// Fills StitchParams::lens for a side-by-side frame of the given size. The two axes are scaled
// separately, because hosts also render squeezed frames (Resolve's thumbnails are 16:9).
void FillLensParams(const LensCalibration p_Lenses[2], int p_FrameWidth, int p_FrameHeight, float* p_Out);

// Fills StitchParams::lensOffset: where the second lens sits relative to the first, in the rig frame.
void FillLensOffset(const LensCalibration p_Lenses[2], StitchParams& p_Params);
