#pragma once

#include <memory>
#include <string>
#include <vector>

// Camera motion of a clip, from the .motion file the import writes (tools/insv_motion.py):
// per frame, the camera orientation relative to the first frame and the accelerometer's "up".
class MotionData
{
public:
    // Loaded once per file and shared; null if the file cannot be read.
    static std::shared_ptr<const MotionData> Load(const std::string& p_Path);

    int frames() const { return int(m_Quats.size() / 4); }
    double fps() const { return m_Fps; }
    // Seconds of recording per second of video: 1 for a normal clip, about 10 for a 10x hyperlapse.
    double speed() const { return m_Speed; }

    // Rotation (row-major) from the stabilised view to the camera, for frame p_Frame: rays of the
    // stabilised view times this give the directions to sample in the footage.
    //   p_Mode: 1 smooth (follows the camera's general direction), 2 locked direction
    //   p_Smoothness: seconds of motion averaged when smoothing; more on sped-up clips, whose
    //   frames are further apart in time and shake more from one to the next
    //   p_Level: keep the horizon level using the accelerometer
    void viewToCamera(double p_Frame, int p_Mode, double p_Smoothness, bool p_Level, double p_R[9]) const;

private:
    std::vector<float> m_Quats; // w x y z per frame
    std::vector<float> m_Up;    // x y z per frame
    double m_Fps = 30.0;
    double m_Speed = 1.0;
};
