#pragma once

#include <vector>

#include "Calibration.h"

// A frame of the side-by-side dual-fisheye clip, as RGBA float pixels.
struct FrameView
{
    const unsigned char* data; // first pixel of the first stored row
    int width;
    int height;
    long rowBytes;             // distance between stored rows, may be negative
    bool bottomUp;             // true when the first stored row is the bottom of the picture (OpenFX)
};

// Follows a subject through the 360 footage. Works on small flat views rendered around the
// subject, so it is unaffected by the fisheye distortion and the seam between the lenses:
// each frame it searches around where the subject is expected for the best match with its
// appearance (normalised cross-correlation), then slowly updates that appearance.
class SubjectTracker
{
public:
    // p_SubjectDeg: angular width of the box around the subject.
    SubjectTracker(const LensCalibration p_Lenses[2], double p_SubjectDeg);

    // Learns the subject's appearance at the given view direction (degrees).
    void start(const FrameView& p_Frame, double p_Pan, double p_Tilt);

    // Finds the subject in the next frame. Updates pan and tilt (degrees, pan kept continuous)
    // and returns the match quality, 0..1. Returns false once the subject has been lost.
    bool step(const FrameView& p_Frame, double& p_Pan, double& p_Tilt, double& p_Confidence);

    // Whether a step's match was good enough to trust its direction.
    static bool isConfident(double p_Confidence);

private:
    void renderPatch(const FrameView& p_Frame, double p_Pan, double p_Tilt, double p_HalfAngle, int p_Size, std::vector<float>& p_Out);

    LensCalibration m_Lenses[2];
    double m_SubjectDeg;
    std::vector<float> m_Template; // current appearance: zero-mean, unit-norm colour patch
    double m_Pan, m_Tilt;
    double m_VelPan, m_VelTilt;
    int m_LowFrames;
    int m_LensFrameW, m_LensFrameH;
    float m_Lens[2 * eLensSlotCount];
};
