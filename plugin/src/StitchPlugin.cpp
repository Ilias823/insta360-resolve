// Insta360 Stitch: OpenFX plugin skeleton.
//
// Takes the side-by-side dual-fisheye compound clip made by tools/ingest.py and turns it
// into either an equirectangular 360 picture or a flat view through a virtual camera
// (reframe). Resolve stretches the clip to the timeline frame, so the plugin works in
// normalised coordinates and the output is always the size of the input. Frame geometry and calibration problems are recorded in
// ~/Library/Logs/Insta360Stitch.log.

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <atomic>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <chrono>
#include <set>
#include <vector>
#include <string>

#include "ofxDrawSuite.h"
#include "ofxsImageEffect.h"
#include "ofxsInteract.h"
#include "ofxsProcessing.h"
#include "ofxsSupportPrivate.h"

#include "Calibration.h"
#include "LensDecoder.h"
#include "StitchKernel.h"
#include "ProgressWindow.h"
#include "ClipTag.h"
#include "Motion.h"
#include "Registry.h"
#include "Tracker.h"
#include "Updater.h"

#define kPluginName "Insta360 Stitch"
#define kPluginGrouping "Insta360"
#define kPluginDescription "Stitches and reframes Insta360 X5 360 footage. Free and open source; support it at " kDonateUrl
#define kPluginIdentifier "org.insta360resolve.Stitch"
#define kPluginVersionMajor 0
#define kPluginVersionMinor 1

#define kParamView "view"
#define kParamCalibration "calibrationFile"
#define kParamBlend "blendWidth"
#define kParamGainMatch "matchLenses"
#define kParamAutoDistance "autoStitchDistance"
#define kParamStitchDistance "stitchDistance"
#define kParamPan "pan"
#define kParamTilt "tilt"
#define kParamRoll "roll"
#define kParamFov "fieldOfView"
#define kParamDistance "distance"
#define kParamSubjectSize "subjectSize"
#define kParamTrackLength "trackLength"
#define kParamTrackToEnd "trackToEnd"
#define kParamShowBox "showSubjectBox"
#define kParamNoDistortion "removeDistortion"
#define kDewarpMaxFov 100.0 // widest view a straight-line lens shows without stretching (Insta360's Dewarp stops there too)
#define kParamAbout "about"
#define kParamDonate "donate"
#define kDonateUrl "https://ko-fi.com/ilias823"
#define kParamCheckUpdate "checkForUpdates"
#define kUpdateRepo "Ilias823/insta360-resolve" // GitHub repository whose releases are checked
#ifndef PLUGIN_VERSION
#define PLUGIN_VERSION "0.0.0" // set by the Makefile from Info.plist
#endif
#define kParamTrack "trackSubject"
#define kParamBoxX "subjectX"
#define kParamBoxY "subjectY"
#define kParamOverlayTip "overlayTip"
#define kParamBaseDistance "baseDistance"
#define kParamStabilize "stabilization"
#define kParamSmoothness "smoothness"
#define kParamLevel "levelHorizon"
#define kParamFullRes "fullResolution"
#define kFullResMinSize 480 // smaller renders, such as thumbnails, use Resolve's picture
#define kFullResGiveUp 8     // frames that did not match the decoded file before an instance stops decoding
#define kTagAttempts 30 // frames tried before deciding a clip has no tag (imported before tags existed)

// The overlay counts as visible if the viewer drew it this recently.
#define kOverlaySeenSeconds 3.0

static double SecondsNow()
{
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

// When the viewer last drew the on-screen controls; it only does so in Open FX Overlay mode.
// Shared by all instances: Resolve may draw with a different instance than the one whose
// button was pressed.
static std::atomic<double> s_OverlayDrawn{0.0};

#define kFovMin 10.0

// Order of the View menu; the kernel modes are numbered differently.
static const int kViewModes[] = {eModeStitch, eModeReframe, eModeSource, eModeSourceTint};

////////////////////////////////////////////////////////////////////////////////

// Writes each distinct message once per session, so a playing timeline does not flood the log.
static void LogOnce(const std::string& p_Message)
{
    static std::mutex mutex;
    static std::set<std::string> seen;

    std::lock_guard<std::mutex> lock(mutex);
    if (!seen.insert(p_Message).second)
    {
        return;
    }

    const char* home = getenv("HOME");
    const std::string path = std::string(home ? home : "/tmp") + "/Library/Logs/Insta360Stitch.log";
    if (FILE* f = fopen(path.c_str(), "a"))
    {
        fprintf(f, "%s\n", p_Message.c_str());
        fclose(f);
    }
}

////////////////////////////////////////////////////////////////////////////////

class StitchProcessor : public OFX::ImageProcessor
{
public:
    explicit StitchProcessor(OFX::ImageEffect& p_Instance) : OFX::ImageProcessor(p_Instance), m_SrcImg(nullptr), m_Params() {}

    void setSrcImg(OFX::Image* p_SrcImg) { m_SrcImg = p_SrcImg; }
    void setParams(const StitchParams& p_Params) { m_Params = p_Params; }
    void setLensImages(const LensImages* p_Lenses, std::shared_ptr<FullResCheck> p_Check)
    {
        m_Lenses = p_Lenses;
        m_Check = p_Check;
    }

    void processImagesMetal() override;
    void multiThreadProcessImages(OfxRectI p_ProcWindow) override;

private:
    OFX::Image* m_SrcImg;
    StitchParams m_Params;
    const LensImages* m_Lenses = nullptr;
    std::shared_ptr<FullResCheck> m_Check;
};

void StitchProcessor::processImagesMetal()
{
    const float* input = static_cast<const float*>(m_SrcImg->getPixelData());
    float* output = static_cast<float*>(_dstImg->getPixelData());

    if (!RunStitchMetalKernel(_pMetalCmdQ, m_Params, input, output, m_Lenses, m_Check))
    {
        LogOnce("ERROR: Metal kernel failed to build; see Resolve's console output");
        OFX::throwSuiteStatusException(kOfxStatFailed);
    }
}

// This plugin is Metal-only; there is no CPU implementation of the stitch.
void StitchProcessor::multiThreadProcessImages(OfxRectI /*p_ProcWindow*/)
{
    LogOnce("ERROR: host asked for CPU rendering; Insta360 Stitch needs Metal");
    OFX::throwSuiteStatusException(kOfxStatErrUnsupported);
}

////////////////////////////////////////////////////////////////////////////////

// One-click looks, like the view buttons in Insta360 Studio. These are this plugin's own
// settings chosen to resemble those looks, not Insta360's exact values.
// The menu shows the style matching the current Field of View and Distance, and switches to
// Custom as soon as either is changed by hand.
struct ViewStyle
{
    const char* label;
    double fov, distance;
    bool lookDown;
};

#define kParamStyle "viewStyle"
#define kStyleCustom 0

static const ViewStyle kViewStyles[] = {
    {"Custom", 0.0, 0.0, false},
    {"Tiny Planet", 300.0, 1.0, true},
    {"Mega View", 150.0, 0.8, false},
    {"Ultra Wide", 130.0, 0.5, false},
    {"Dewarp", 110.0, 0.25, false},
    {"Linear", 85.0, 0.0, false},
};
static const int kViewStyleCount = sizeof(kViewStyles) / sizeof(kViewStyles[0]);

class StitchPlugin : public OFX::ImageEffect
{
public:
    explicit StitchPlugin(OfxImageEffectHandle p_Handle);

    void render(const OFX::RenderArguments& p_Args) override;
    void changedParam(const OFX::InstanceChangedArgs& p_Args, const std::string& p_ParamName) override;

private:
    void applyStyle(int p_Style);
    void loadCalibration(double p_Time, LensCalibration p_Lenses[2]);

    // The clip this effect is on, from its tag: > 0 known, 0 not read yet, -1 none.
    int clipId() const { return m_ClipId.load(); }
    void noteTag(int p_Id);
    ClipFiles clipFiles();
    // Stabilisation for a frame: rotation from the stabilised view to the camera. False when off
    // or when the clip has no motion data.
    bool stabilization(double p_Time, double p_R[9]);
    void trackSubject(double p_Time);
    // Field of view and distance actually used: Remove Distortion turns the lens straight.
    void viewLens(double p_Time, double& p_Fov, double& p_Distance) const
    {
        p_Fov = m_Fov->getValueAtTime(p_Time);
        p_Distance = m_Distance->getValueAtTime(p_Time);
        if (m_NoDistortion->getValueAtTime(p_Time))
        {
            p_Fov = fmin(p_Fov, kDewarpMaxFov);
            p_Distance = 0.0;
        }
    }
    void checkForUpdates();
    int matchingStyle(double p_Time) const;

public:

private:
    // Does not own the following pointers
    OFX::Clip* m_DstClip;
    OFX::Clip* m_SrcClip;
    OFX::ChoiceParam* m_View;
    OFX::StringParam* m_CalibrationFile;
    OFX::DoubleParam* m_BlendWidth;
    OFX::BooleanParam* m_GainMatch;
    OFX::BooleanParam* m_AutoDistance;
    OFX::DoubleParam* m_StitchDistance;
    OFX::DoubleParam* m_Pan;
    OFX::DoubleParam* m_Tilt;
    OFX::DoubleParam* m_Roll;
    OFX::DoubleParam* m_Fov;
    OFX::DoubleParam* m_Distance;
    OFX::ChoiceParam* m_Style;
    OFX::DoubleParam* m_SubjectSize;
    OFX::DoubleParam* m_TrackLength;
    OFX::BooleanParam* m_TrackToEnd;
    OFX::BooleanParam* m_ShowBox;
    OFX::BooleanParam* m_NoDistortion;
    OFX::DoubleParam* m_BoxX;
    OFX::DoubleParam* m_BoxY;
    OFX::DoubleParam* m_BaseDistance;
    bool m_ApplyingStyle = false;
    OFX::ChoiceParam* m_Stabilize;
    OFX::DoubleParam* m_Smoothness;
    OFX::BooleanParam* m_Level;
    OFX::BooleanParam* m_FullRes;
    std::shared_ptr<FullResCheck> m_FullResCheck = std::make_shared<FullResCheck>();
    std::atomic<int> m_ClipId{0};
    std::atomic<int> m_TagAttempts{0};
    std::mutex m_ClipMutex;
    ClipFiles m_ClipFiles;
    bool m_ClipFilesRead = false;
};

StitchPlugin::StitchPlugin(OfxImageEffectHandle p_Handle)
    : ImageEffect(p_Handle)
{
    m_DstClip = fetchClip(kOfxImageEffectOutputClipName);
    m_SrcClip = fetchClip(kOfxImageEffectSimpleSourceClipName);
    m_View = fetchChoiceParam(kParamView);
    m_CalibrationFile = fetchStringParam(kParamCalibration);
    m_BlendWidth = fetchDoubleParam(kParamBlend);
    m_GainMatch = fetchBooleanParam(kParamGainMatch);
    m_AutoDistance = fetchBooleanParam(kParamAutoDistance);
    m_StitchDistance = fetchDoubleParam(kParamStitchDistance);
    m_StitchDistance->setEnabled(!m_AutoDistance->getValue());
    m_Pan = fetchDoubleParam(kParamPan);
    m_Tilt = fetchDoubleParam(kParamTilt);
    m_Roll = fetchDoubleParam(kParamRoll);
    m_Fov = fetchDoubleParam(kParamFov);
    m_Distance = fetchDoubleParam(kParamDistance);
    m_Style = fetchChoiceParam(kParamStyle);
    m_SubjectSize = fetchDoubleParam(kParamSubjectSize);
    m_TrackLength = fetchDoubleParam(kParamTrackLength);
    m_TrackToEnd = fetchBooleanParam(kParamTrackToEnd);
    m_ShowBox = fetchBooleanParam(kParamShowBox);
    m_NoDistortion = fetchBooleanParam(kParamNoDistortion);
    m_TrackLength->setEnabled(!m_TrackToEnd->getValue());
    m_BoxX = fetchDoubleParam(kParamBoxX);
    m_BoxY = fetchDoubleParam(kParamBoxY);
    m_BaseDistance = fetchDoubleParam(kParamBaseDistance);
    m_Stabilize = fetchChoiceParam(kParamStabilize);
    m_Smoothness = fetchDoubleParam(kParamSmoothness);
    m_Level = fetchBooleanParam(kParamLevel);
    m_FullRes = fetchBooleanParam(kParamFullRes);
}

void StitchPlugin::noteTag(int p_Id)
{
    if (p_Id > 0)
    {
        m_ClipId.store(p_Id);
        char line[64];
        snprintf(line, sizeof(line), "clip tag %06x", p_Id);
        LogOnce(line);
    }
    else if (++m_TagAttempts >= kTagAttempts && m_ClipId.load() == 0)
    {
        m_ClipId.store(-1);
        LogOnce("a clip without a tag (imported before 0.2): factory calibration, no stabilisation");
    }
}

ClipFiles StitchPlugin::clipFiles()
{
    std::lock_guard<std::mutex> lock(m_ClipMutex);
    if (!m_ClipFilesRead && clipId() > 0)
    {
        m_ClipFiles = LookupClip(clipId());
        m_ClipFilesRead = true;
        if (!m_ClipFiles.found)
        {
            LogOnce("ERROR: clip tag found but the clip is not registered on this Mac; import it here");
        }
    }
    return m_ClipFiles;
}

bool StitchPlugin::stabilization(double p_Time, double p_R[9])
{
    int mode = 0;
    m_Stabilize->getValueAtTime(p_Time, mode);
    if (mode == 0 || clipId() <= 0)
    {
        return false;
    }
    const ClipFiles files = clipFiles();
    const std::shared_ptr<const MotionData> motion = files.motion.empty() ? nullptr : MotionData::Load(files.motion);
    if (!motion)
    {
        return false;
    }
    motion->viewToCamera(p_Time, mode, m_Smoothness->getValueAtTime(p_Time), m_Level->getValueAtTime(p_Time), p_R);
    return true;
}

// ~/Library/Application Support/Insta360Stitch/default-calibration.json, written by tools/ingest.py.
// Read again only when the file changes, since this runs for every frame.
static bool DefaultCalibration(std::string& p_Raw)
{
    static std::mutex mutex;
    static std::string cached;
    static struct timespec cachedTime = {0, 0};

    const char* home = getenv("HOME");
    const std::string path = std::string(home ? home : "") + "/Library/Application Support/Insta360Stitch/default-calibration.json";
    struct stat info;
    if (!home || stat(path.c_str(), &info) != 0)
    {
        return false;
    }

    std::lock_guard<std::mutex> lock(mutex);
    if (info.st_mtimespec.tv_sec != cachedTime.tv_sec || info.st_mtimespec.tv_nsec != cachedTime.tv_nsec)
    {
        std::string raw;
        cached = ReadCalibrationFile(path, raw) ? raw : "";
        cachedTime = info.st_mtimespec;
    }
    if (cached.empty())
    {
        return false;
    }
    p_Raw = cached;
    return true;
}

void StitchPlugin::loadCalibration(double p_Time, LensCalibration p_Lenses[2])
{
    std::string calibrationPath;
    m_CalibrationFile->getValueAtTime(p_Time, calibrationPath);
    std::string raw = kNominalX5Calibration;
    const ClipFiles files = calibrationPath.empty() ? clipFiles() : ClipFiles();
    if (files.found && ReadCalibrationFile(files.info, raw))
    {
        LogOnce("using the clip's own calibration (from its tag)");
    }
    else if (calibrationPath.empty())
    {
        // The import tool leaves the latest imported clip's calibration here; cameras differ, so
        // that is a better default than the built-in values (which come from one particular X5).
        if (DefaultCalibration(raw))
        {
            LogOnce("no calibration file set; using the last imported camera's calibration");
        }
        else
        {
            raw = kNominalX5Calibration;
            LogOnce("no calibration file set; using the built-in X5 values");
        }
    }
    else if (!ReadCalibrationFile(calibrationPath, raw))
    {
        LogOnce("ERROR: could not read calibration from " + calibrationPath + "; using the built-in X5 values");
    }
    if (!ParseCalibration(raw, p_Lenses))
    {
        LogOnce("ERROR: calibration in " + calibrationPath + " is not a 2-lens calibration; using the built-in X5 values");
        ParseCalibration(kNominalX5Calibration, p_Lenses);
    }
}

// Follows whatever is in the box at the centre of the view, from the current frame forward,
// and writes Pan and Tilt keyframes that keep it centred. Stops at the end of the clip, after
// Track Length, when the subject is lost, or when the user cancels.
void StitchPlugin::trackSubject(double p_Time)
{
    if (!m_ShowBox->getValue())
    {
        m_ShowBox->setValue(true);
        sendMessage(OFX::Message::eMessageMessage, "", "The yellow box is on now: put it on the subject and press Track Subject again.");
        return;
    }
    if (SecondsNow() - s_OverlayDrawn.load() > kOverlaySeenSeconds)
    {
        sendMessage(OFX::Message::eMessageMessage, "",
                    "Turn on Open FX Overlay (viewer menu, bottom-left), drag the yellow box onto the subject, then press Track Subject.");
        return;
    }

    LensCalibration lenses[2];
    loadCalibration(p_Time, lenses);

    // Direction of the subject: the centre of the yellow box, through the current view.
    const OfxRectD rod = m_SrcClip->getRegionOfDefinition(p_Time);
    const double rodW = rod.x2 - rod.x1, rodH = rod.y2 - rod.y1;
    StitchParams view = {};
    double fov, distance;
    viewLens(p_Time, fov, distance);
    const double camPan = m_Pan->getValueAtTime(p_Time), camTilt = m_Tilt->getValueAtTime(p_Time);
    FillViewParams(camPan, camTilt, m_Roll->getValueAtTime(p_Time), fov, distance,
                   (rodW > 0.0 && rodH > 0.0) ? rodW / rodH : 16.0 / 9.0, view);
    double ray[3];
    ViewPointToRay(view, m_BoxX->getValueAtTime(p_Time), 1.0 - m_BoxY->getValueAtTime(p_Time), ray);
    const double len = sqrt(ray[0] * ray[0] + ray[1] * ray[1] + ray[2] * ray[2]);
    double pan = atan2(ray[0], ray[2]) * 180.0 / M_PI;
    double tilt = asin(fmin(fmax(-ray[1] / len, -1.0), 1.0)) * 180.0 / M_PI;
    pan += 360.0 * round((camPan - pan) / 360.0);
    // Pan and Tilt aim the stabilised view; the tracker works in the footage itself. These turn
    // directions between the two for a frame (identity without stabilisation).
    auto toCamera = [&](double p_At, double p_Pan, double p_Tilt, double& p_CamPan, double& p_CamTilt) {
        double s[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
        stabilization(p_At, s);
        const double v[3] = {cos(p_Tilt * M_PI / 180.0) * sin(p_Pan * M_PI / 180.0), -sin(p_Tilt * M_PI / 180.0),
                             cos(p_Tilt * M_PI / 180.0) * cos(p_Pan * M_PI / 180.0)};
        const double c[3] = {s[0] * v[0] + s[1] * v[1] + s[2] * v[2], s[3] * v[0] + s[4] * v[1] + s[5] * v[2],
                             s[6] * v[0] + s[7] * v[1] + s[8] * v[2]};
        p_CamPan = atan2(c[0], c[2]) * 180.0 / M_PI;
        p_CamTilt = asin(fmin(fmax(-c[1], -1.0), 1.0)) * 180.0 / M_PI;
    };
    auto toView = [&](double p_At, double p_CamPan, double p_CamTilt, double p_NearPan, double& p_Pan, double& p_Tilt) {
        double s[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
        stabilization(p_At, s);
        const double c[3] = {cos(p_CamTilt * M_PI / 180.0) * sin(p_CamPan * M_PI / 180.0), -sin(p_CamTilt * M_PI / 180.0),
                             cos(p_CamTilt * M_PI / 180.0) * cos(p_CamPan * M_PI / 180.0)};
        const double v[3] = {s[0] * c[0] + s[3] * c[1] + s[6] * c[2], s[1] * c[0] + s[4] * c[1] + s[7] * c[2],
                             s[2] * c[0] + s[5] * c[1] + s[8] * c[2]};
        p_Pan = atan2(v[0], v[2]) * 180.0 / M_PI;
        p_Pan += 360.0 * round((p_NearPan - p_Pan) / 360.0);
        p_Tilt = asin(fmin(fmax(-v[1], -1.0), 1.0)) * 180.0 / M_PI;
    };

    // The camera keeps the same offset from the subject, so the subject stays where the box is.
    const double offsetPan = camPan - pan, offsetTilt = camTilt - tilt;
    // The box's angular width, measured through the view (curved views make it differ from
    // a simple share of the field of view).
    const double boxHalf = 0.5 * m_SubjectSize->getValueAtTime(p_Time) / 100.0;
    const double boxU = m_BoxX->getValueAtTime(p_Time), boxV = 1.0 - m_BoxY->getValueAtTime(p_Time);
    const double longSide = fmax(rodW, rodH) > 0.0 ? fmax(rodW, rodH) : 1.0;
    double left[3], right[3];
    ViewPointToRay(view, boxU - boxHalf * longSide / fmax(rodW, 1.0), boxV, left);
    ViewPointToRay(view, boxU + boxHalf * longSide / fmax(rodW, 1.0), boxV, right);
    const double dot = (left[0] * right[0] + left[1] * right[1] + left[2] * right[2]) /
                       sqrt((left[0] * left[0] + left[1] * left[1] + left[2] * left[2]) * (right[0] * right[0] + right[1] * right[1] + right[2] * right[2]));
    SubjectTracker tracker(lenses, acos(fmin(fmax(dot, -1.0), 1.0)) * 180.0 / M_PI);

    // The clip's last frame: the earlier of where the footage and where this clip's output end
    // (a trimmed clip uses only part of its footage).
    const OfxRangeD srcRange = m_SrcClip->getFrameRange(), dstRange = m_DstClip->getFrameRange();
    double timelineStart = 0.0, timelineEnd = 0.0;
    timeLineGetBounds(timelineStart, timelineEnd);
    char ranges[160];
    snprintf(ranges, sizeof(ranges), "track ranges: source %.0f-%.0f output %.0f-%.0f timeline %.0f-%.0f start %.0f",
             srcRange.min, srcRange.max, dstRange.min, dstRange.max, timelineStart, timelineEnd, p_Time);
    LogOnce(ranges);
    // Resolve reports the used part of a trimmed clip as the timeline bounds, in source frames.
    const bool trimmed = timelineEnd > timelineStart && timelineEnd <= srcRange.max + 0.5 && timelineStart >= srcRange.min - 0.5;
    const double clipStart = trimmed ? timelineStart : srcRange.min;
    const double clipEnd = trimmed ? timelineEnd : (dstRange.max > dstRange.min ? fmin(srcRange.max, dstRange.max) : srcRange.max);
    const double fps = m_SrcClip->getFrameRate() > 0.0 ? m_SrcClip->getFrameRate() : 30.0;
    const double end = m_TrackToEnd->getValueAtTime(p_Time) ? clipEnd : fmin(clipEnd, p_Time + m_TrackLength->getValueAtTime(p_Time) * fps);

    auto fetch = [&](double p_At, std::unique_ptr<OFX::Image>& p_Image, FrameView& p_View) {
        p_Image.reset(m_SrcClip->fetchImage(p_At));
        if (!p_Image.get() || !p_Image->getPixelData() || p_Image->getPixelDepth() != OFX::eBitDepthFloat ||
            p_Image->getPixelComponents() != OFX::ePixelComponentRGBA)
        {
            return false;
        }
        const OfxRectI b = p_Image->getBounds();
        p_View = {static_cast<const unsigned char*>(p_Image->getPixelData()), b.x2 - b.x1, b.y2 - b.y1, long(p_Image->getRowBytes()), true};
        return true;
    };

    std::unique_ptr<OFX::Image> image;
    FrameView frame;
    if (!fetch(p_Time, image, frame))
    {
        LogOnce("ERROR: Resolve did not hand over the current frame for tracking");
        sendMessage(OFX::Message::eMessageError, "", "Tracking failed: Resolve did not provide the video frames.");
        return;
    }
    if (clipId() == 0)
    {
        // The tag tells which clip's motion data to use; read it from this frame if not yet known.
        float brightness[ClipTag::kBits];
        for (int bit = 0; bit < ClipTag::kBits; ++bit)
        {
            int x, y;
            ClipTag::CellCentre(bit, frame.width, frame.height, x, y);
            const int row = frame.bottomUp ? frame.height - 1 - y : y;
            const float* px = reinterpret_cast<const float*>(frame.data + long(row) * frame.rowBytes) + x * 4;
            brightness[bit] = 0.299f * px[0] + 0.587f * px[1] + 0.114f * px[2];
        }
        noteTag(ClipTag::Decode(brightness));
    }
    double camSubjectPan, camSubjectTilt;
    toCamera(p_Time, pan, tilt, camSubjectPan, camSubjectTilt);
    tracker.start(frame, camSubjectPan, camSubjectTilt);
    double camPanNow = camSubjectPan, camTiltNow = camSubjectTilt;

    const auto started = std::chrono::steady_clock::now();
    std::vector<double> times = {p_Time}, pans = {pan}, tilts = {tilt};
    enum { eEnd, eLost, eCancelled, eNoFrame } stop = eEnd;
    size_t lastGood = 0; // last frame whose match could be trusted
    progressStart("Tracking subject");
    ProgressWindow window;
    window.open("Tracking Subject");
    const double total = fmax(end - p_Time, 1.0);
    for (double t = p_Time + 1.0; t <= end; t += 1.0)
    {
        const double done = t - p_Time - 1.0;
        const double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count();
        char status[128];
        if (done >= 5.0)
        {
            snprintf(status, sizeof(status), "Frame %.0f of %.0f  ·  about %.0f s left", done + 1.0, total,
                     elapsed / done * (total - done));
        }
        else
        {
            snprintf(status, sizeof(status), "Frame %.0f of %.0f", done + 1.0, total);
        }
        if (!progressUpdate((t - p_Time) / total) || !window.update((t - p_Time) / total, status))
        {
            stop = eCancelled;
            break;
        }
        if (!fetch(t, image, frame))
        {
            stop = eNoFrame;
            break;
        }
        double confidence = 0.0;
        if (!tracker.step(frame, camPanNow, camTiltNow, confidence))
        {
            stop = eLost;
            break;
        }
        toView(t, camPanNow, camTiltNow, pans.back(), pan, tilt);
        times.push_back(t);
        pans.push_back(pan);
        tilts.push_back(tilt);
        if (SubjectTracker::isConfident(confidence))
        {
            lastGood = times.size() - 1;
        }
    }
    if (stop == eLost)
    {
        // Keyframes end where the subject was last seen clearly, not where the tracker gave up.
        times.resize(lastGood + 1);
        pans.resize(lastGood + 1);
        tilts.resize(lastGood + 1);
    }
    window.close();
    progressEnd();
    image.reset();

    if (times.size() < 2)
    {
        sendMessage(OFX::Message::eMessageMessage, "", stop == eLost ? "Lost the subject straight away: make the box fit it more snugly and try again."
                                                                   : "Tracking stopped straight away. Nothing was changed.");
        return;
    }

    // Smooth out frame-to-frame jitter, then key every other frame (and the last one).
    const int radius = 3;
    std::vector<double> smoothPan(pans.size()), smoothTilt(tilts.size());
    for (size_t i = 0; i < pans.size(); ++i)
    {
        double sp = 0.0, st = 0.0;
        int n = 0;
        for (int k = -radius; k <= radius; ++k)
        {
            const long j = long(i) + k;
            if (j >= 0 && j < long(pans.size()))
            {
                sp += pans[j];
                st += tilts[j];
                ++n;
            }
        }
        smoothPan[i] = i == 0 ? pans[0] : sp / n;
        smoothTilt[i] = i == 0 ? tilts[0] : st / n;
    }

    beginEditBlock("Track Subject");
    for (OFX::DoubleParam* param : {m_Pan, m_Tilt})
    {
        // Replace earlier tracking over the same stretch, keep everything else.
        for (int k = int(param->getNumKeys()) - 1; k >= 0; --k)
        {
            const double kt = param->getKeyTime(k);
            if (kt >= p_Time && kt <= times.back())
            {
                param->deleteKeyAtTime(kt);
            }
        }
    }
    for (size_t i = 0; i < times.size(); ++i)
    {
        if (i % 2 == 0 || i + 1 == times.size())
        {
            m_Pan->setValueAtTime(times[i], i == 0 ? camPan : smoothPan[i] + offsetPan);
            m_Tilt->setValueAtTime(times[i], i == 0 ? camTilt : fmin(fmax(smoothTilt[i] + offsetTilt, -90.0), 90.0));
        }
    }
    endEditBlock();

    // Where tracking ended, as a time into the clip, so the user can find the spot again.
    const double into = (times.back() - clipStart) / fps;
    char at[32];
    snprintf(at, sizeof(at), "%d:%02d", int(into) / 60, int(into) % 60);
    char message[512];
    switch (stop)
    {
    case eEnd:
        snprintf(message, sizeof(message), "Tracked to the end of the clip (%.1f s). If the view drifts somewhere, "
                 "go there, put the box back on the subject and press Track Subject.", (times.size() - 1) / fps);
        break;
    case eLost:
        snprintf(message, sizeof(message), "Lost the subject at %s into the clip; the keyframes stop there.\n"
                 "Go to that moment, put the box back on the subject and press Track Subject to continue.", at);
        break;
    case eCancelled:
        snprintf(message, sizeof(message), "Stopped at %s into the clip; the keyframes stop there.", at);
        break;
    case eNoFrame:
        snprintf(message, sizeof(message), "Resolve stopped providing frames at %s into the clip; the keyframes stop there.", at);
        break;
    }
    LogOnce(std::string("track: ") + message);
    sendMessage(OFX::Message::eMessageMessage, "", message);
}

// Asks GitHub for the latest release and offers to download and open its installer.
void StitchPlugin::checkForUpdates()
{
    const ReleaseInfo release = FetchLatestRelease(kUpdateRepo);
    if (!release.ok)
    {
        sendMessage(OFX::Message::eMessageMessage, "", "Could not check for updates: " + release.error + ".");
        return;
    }
    if (CompareVersions(release.version, PLUGIN_VERSION) <= 0)
    {
        sendMessage(OFX::Message::eMessageMessage, "", std::string("You have the latest version (") + PLUGIN_VERSION + ").");
        return;
    }

    std::string notes = release.notes.substr(0, 400);
    for (char& c : notes)
    {
        c = c == '<' ? '(' : c == '>' ? ')' : c;
    }
    if (release.notes.size() > 400)
    {
        notes += "...";
    }
    std::string text = "Version " + release.version + " is available (you have " PLUGIN_VERSION ").";
    if (!notes.empty())
    {
        text += "\n\n" + notes;
    }
    if (release.pkgUrl.empty())
    {
        sendMessage(OFX::Message::eMessageMessage, "", text + "\n\nOpening the release page.");
        OpenWithSystem(release.pageUrl);
        return;
    }

    const OFX::Message::MessageReplyEnum reply = sendMessage(OFX::Message::eMessageQuestion, "", text + "\n\nDownload and install it now?");
    if (reply == OFX::Message::eMessageReplyNo)
    {
        return;
    }
    if (reply != OFX::Message::eMessageReplyYes)
    {
        OpenWithSystem(release.pageUrl); // Resolve could not ask: let the user download it from the page
        return;
    }

    std::string error;
    const std::string pkg = DownloadToDownloads(release.pkgUrl, error);
    if (pkg.empty())
    {
        sendMessage(OFX::Message::eMessageMessage, "", "The download failed: " + error + ". Opening the release page instead.");
        OpenWithSystem(release.pageUrl);
        return;
    }
    sendMessage(OFX::Message::eMessageMessage, "",
                "Downloaded to your Downloads folder. The installer opens next: quit DaVinci Resolve, follow the installer, then open Resolve again.");
    OpenWithSystem(pkg);
}

void StitchPlugin::applyStyle(int p_Style)
{
    const ViewStyle& style = kViewStyles[p_Style];
    m_ApplyingStyle = true;
    beginEditBlock(style.label);
    m_Fov->setValue(style.fov);
    m_Distance->setValue(style.distance);
    m_BaseDistance->setValue(style.distance);
    if (style.lookDown)
    {
        m_Tilt->setValue(-90.0);
    }
    else if (fabs(m_Tilt->getValue()) > 60.0)
    {
        m_Tilt->setValue(0.0); // coming back from a tiny planet: look at the horizon again
    }
    endEditBlock();
    m_ApplyingStyle = false;
}

int StitchPlugin::matchingStyle(double p_Time) const
{
    const double fov = m_Fov->getValueAtTime(p_Time);
    const double distance = m_Distance->getValueAtTime(p_Time);
    for (int i = 1; i < kViewStyleCount; ++i)
    {
        if (fabs(fov - kViewStyles[i].fov) < 0.05 && fabs(distance - kViewStyles[i].distance) < 0.0005)
        {
            return i;
        }
    }
    return kStyleCustom;
}

void StitchPlugin::changedParam(const OFX::InstanceChangedArgs& p_Args, const std::string& p_ParamName)
{
    if (m_ApplyingStyle)
    {
        return;
    }

    if (p_ParamName == kParamTrack)
    {
        trackSubject(p_Args.time);
    }
    else if (p_ParamName == kParamDonate)
    {
        OpenWithSystem(kDonateUrl); // only when the button is pressed
    }
    else if (p_ParamName == kParamCheckUpdate)
    {
        checkForUpdates();
    }
    else if (p_ParamName == kParamAutoDistance)
    {
        m_StitchDistance->setEnabled(!m_AutoDistance->getValue());
    }
    else if (p_ParamName == kParamTrackToEnd)
    {
        m_TrackLength->setEnabled(!m_TrackToEnd->getValue());
    }
    else if (p_ParamName == kParamStyle)
    {
        int style = kStyleCustom;
        m_Style->getValueAtTime(p_Args.time, style);
        if (style > kStyleCustom && style < kViewStyleCount)
        {
            applyStyle(style);
        }
    }
    else if (p_ParamName == kParamFov || p_ParamName == kParamDistance)
    {
        if (p_ParamName == kParamDistance)
        {
            // A Distance chosen by hand is the look to come back to when zooming in again.
            const double chosen = m_Distance->getValueAtTime(p_Args.time);
            m_BaseDistance->setValue(chosen);
            // Wide views need a minimum curve (AutoDistance), so below it the slider would change
            // nothing: put it back at the minimum, so it always shows what is used.
            const double minimum = AutoDistance(m_Fov->getValueAtTime(p_Args.time));
            if (chosen < minimum - 1e-4)
            {
                m_ApplyingStyle = true;
                m_Distance->setValue(minimum);
                m_ApplyingStyle = false;
            }
        }
        else
        {
            // Zooming out curves the picture just enough to keep the edges natural, and zooming
            // back in returns to the chosen Distance, with the slider showing what is used.
            const double wanted = fmax(m_BaseDistance->getValue(), AutoDistance(m_Fov->getValueAtTime(p_Args.time)));
            if (fabs(wanted - m_Distance->getValueAtTime(p_Args.time)) > 1e-4)
            {
                m_ApplyingStyle = true;
                m_Distance->setValue(wanted);
                m_ApplyingStyle = false;
            }
        }

        // Keep the menu honest: it names a style only while the view still matches it.
        int shown = kStyleCustom;
        m_Style->getValueAtTime(p_Args.time, shown);
        const int match = matchingStyle(p_Args.time);
        if (match != shown)
        {
            m_ApplyingStyle = true;
            m_Style->setValue(match);
            m_ApplyingStyle = false;
        }
    }
}

void StitchPlugin::render(const OFX::RenderArguments& p_Args)
{
    if ((m_DstClip->getPixelDepth() != OFX::eBitDepthFloat) || (m_DstClip->getPixelComponents() != OFX::ePixelComponentRGBA))
    {
        OFX::throwSuiteStatusException(kOfxStatErrUnsupported);
    }

    std::unique_ptr<OFX::Image> dst(m_DstClip->fetchImage(p_Args.time));
    std::unique_ptr<OFX::Image> src(m_SrcClip->fetchImage(p_Args.time));
    if (!dst.get() || !src.get())
    {
        OFX::throwSuiteStatusException(kOfxStatFailed);
    }
    if ((src->getPixelDepth() != dst->getPixelDepth()) || (src->getPixelComponents() != dst->getPixelComponents()))
    {
        OFX::throwSuiteStatusException(kOfxStatErrValue);
    }

    const OfxRectI& sb = src->getBounds();
    const OfxRectI& db = dst->getBounds();
    const OfxRectD rod = m_SrcClip->getRegionOfDefinition(p_Args.time);
    char line[512];
    snprintf(line, sizeof(line),
             "render: src %dx%d  dst %dx%d  clip extent %.0fx%.0f  window %dx%d  scale %.3fx%.3f  %s",
             sb.x2 - sb.x1, sb.y2 - sb.y1, db.x2 - db.x1, db.y2 - db.y1,
             rod.x2 - rod.x1, rod.y2 - rod.y1,
             p_Args.renderWindow.x2 - p_Args.renderWindow.x1, p_Args.renderWindow.y2 - p_Args.renderWindow.y1,
             p_Args.renderScale.x, p_Args.renderScale.y,
             p_Args.isEnabledMetalRender ? "Metal" : "CPU");
    LogOnce(line);

    if ((sb.x1 != db.x1) || (sb.x2 != db.x2) || (sb.y1 != db.y1) || (sb.y2 != db.y2))
    {
        LogOnce("ERROR: source and output frames differ in size; cannot stitch");
        OFX::throwSuiteStatusException(kOfxStatFailed);
    }

    StitchParams params = {};
    params.width = sb.x2 - sb.x1;
    params.height = sb.y2 - sb.y1;
    params.flipY = 1; // OpenFX images are stored bottom row first

    int view = 0;
    m_View->getValueAtTime(p_Args.time, view);
    params.mode = kViewModes[view >= 0 && view < 4 ? view : 0];

    // Which clip this is, from the tag the import put in its corners (read once, on the GPU).
    if (clipId() == 0 && p_Args.isEnabledMetalRender && p_Args.pMetalCmdQ)
    {
        noteTag(ReadClipTagMetal(p_Args.pMetalCmdQ, params, static_cast<const float*>(src->getPixelData())));
    }
    double stab[9];
    if ((params.mode == eModeStitch || params.mode == eModeReframe) && stabilization(p_Args.time, stab))
    {
        params.stabilize = 1;
        for (int i = 0; i < 9; ++i)
        {
            params.stab[i] = float(stab[i]);
        }
    }

    if (params.mode == eModeReframe)
    {
        // The buffer can be squeezed (thumbnails are), so the shape of the view comes from the clip.
        const double rodW = rod.x2 - rod.x1, rodH = rod.y2 - rod.y1;
        const double aspect = (rodW > 0.0 && rodH > 0.0) ? rodW / rodH : double(params.width) / params.height;
        double fov, distance;
        viewLens(p_Args.time, fov, distance);
        FillViewParams(m_Pan->getValueAtTime(p_Args.time), m_Tilt->getValueAtTime(p_Args.time), m_Roll->getValueAtTime(p_Args.time),
                       fov, distance, aspect, params);
    }
    params.blendBand = float(sin(m_BlendWidth->getValueAtTime(p_Args.time) * 0.5 * M_PI / 180.0));
    params.gainMatch = m_GainMatch->getValueAtTime(p_Args.time) ? 1 : 0;
    params.autoDistance = m_AutoDistance->getValueAtTime(p_Args.time) ? 1 : 0;
    params.invDistance = float(1.0 / fmax(m_StitchDistance->getValueAtTime(p_Args.time), 0.1));

    // Full resolution: Resolve only gives the effect as many pixels as the timeline has, so read
    // the lenses from the clip's own files when that is more. Resolve's picture stays the fallback.
    LensImages lensImages;
    // The kernel checks that the decoded frame is the one Resolve passed in; where it never is,
    // such as in Fusion, whose time counts from the start of the comp, decoding is a waste.
    const bool neverMatched = m_FullResCheck->matched == 0 && m_FullResCheck->mismatched >= kFullResGiveUp;
    if (neverMatched)
    {
        char check[160];
        snprintf(check, sizeof(check), "full resolution: the decoded frames do not match Resolve's (difference %.3f); "
                 "using Resolve's picture for this effect", double(m_FullResCheck->lastDiff));
        LogOnce(check);
    }
    if ((params.mode == eModeStitch || params.mode == eModeReframe) && m_FullRes->getValueAtTime(p_Args.time) && !neverMatched &&
        p_Args.isEnabledMetalRender && p_Args.pMetalCmdQ && clipId() > 0 && std::max(params.width, params.height) >= kFullResMinSize)
    {
        const ClipFiles files = clipFiles();
        if (files.lensA.empty() || files.lensB.empty())
        {
            LogOnce("full resolution: the clip's lens files are not registered; using Resolve's picture");
        }
        else if (!AcquireLensImages(p_Args.pMetalCmdQ, files.lensA, files.lensB, int(lround(p_Args.time)), lensImages))
        {
            LogOnce("ERROR: full resolution: cannot decode " + files.lensA + " / " + files.lensB + "; using Resolve's picture");
        }
        else if (lensImages.width > params.width / 2 || lensImages.height > params.height)
        {
            params.fullRes = 1;
            params.lensWidth = lensImages.width;
            params.lensHeight = lensImages.height;
            // The seam analysis is tuned to lenses about 1000 pixels across.
            params.seamLod = float(std::max(0.0, log2(lensImages.width / 960.0)));
            params.yuvScale = lensImages.bits > 8 ? float(65535.0 / (1023.0 * 64.0)) : 1.0f; // 10-bit sits in the top of 16
            params.chromaMid = lensImages.bits > 8 ? float(512.0 / 1023.0) : float(128.0 / 255.0);
            char sizes[128];
            snprintf(sizes, sizeof(sizes), "full resolution: lenses %dx%d %d-bit for a %dx%d frame",
                     lensImages.width, lensImages.height, lensImages.bits, params.width, params.height);
            LogOnce(sizes);
        }
    }

    LensCalibration lenses[2];
    loadCalibration(p_Args.time, lenses);
    if (params.fullRes != 0)
    {
        FillLensParams(lenses, 2 * params.lensWidth, params.lensHeight, params.lens);
    }
    else
    {
        FillLensParams(lenses, params.width, params.height, params.lens);
    }
    FillLensOffset(lenses, params);

    StitchProcessor processor(*this);
    processor.setDstImg(dst.get());
    processor.setSrcImg(src.get());
    processor.setParams(params);
    processor.setLensImages(params.fullRes != 0 ? &lensImages : nullptr, m_FullResCheck);
    processor.setGPURenderArgs(p_Args);
    processor.setRenderWindow(p_Args.renderWindow);
    processor.process();
}

////////////////////////////////////////////////////////////////////////////////

// On-screen controls for the Reframe view, shown when the viewer is in Open FX Overlay mode:
// drag the picture to aim the camera, drag the knob on the right edge to zoom.
class ReframeInteract : public OFX::OverlayInteract
{
public:
    ReframeInteract(OfxInteractHandle p_Handle, OFX::ImageEffect* p_Effect)
        : OFX::OverlayInteract(p_Handle), m_Drag(eDragNone), m_Last()
    {
        m_SrcClip = p_Effect->fetchClip(kOfxImageEffectSimpleSourceClipName);
        m_View = p_Effect->fetchChoiceParam(kParamView);
        m_Pan = p_Effect->fetchDoubleParam(kParamPan);
        m_Tilt = p_Effect->fetchDoubleParam(kParamTilt);
        m_Roll = p_Effect->fetchDoubleParam(kParamRoll);
        m_Fov = p_Effect->fetchDoubleParam(kParamFov);
        m_Distance = p_Effect->fetchDoubleParam(kParamDistance);
        m_SubjectSize = p_Effect->fetchDoubleParam(kParamSubjectSize);
        m_ShowBox = p_Effect->fetchBooleanParam(kParamShowBox);
        m_NoDistortion = p_Effect->fetchBooleanParam(kParamNoDistortion);
        m_BoxX = p_Effect->fetchDoubleParam(kParamBoxX);
        m_BoxY = p_Effect->fetchDoubleParam(kParamBoxY);
        m_Effect = p_Effect;
    }

    bool draw(const OFX::DrawArgs& p_Args) override;
    bool penDown(const OFX::PenArgs& p_Args) override;
    bool penMotion(const OFX::PenArgs& p_Args) override;
    bool penUp(const OFX::PenArgs& p_Args) override;

private:
    enum Drag { eDragNone, eDragAim, eDragZoom, eDragBox, eDragBoxCorner };

    // Where the zoom control sits, in the same coordinates as the pen. Sizes are given in
    // screen pixels (converted with the viewer's pixel scale) so the control looks the same
    // at any viewer zoom.
    struct Layout
    {
        OfxRectD frame;
        OfxPointD px; // one screen pixel
        double trackX, trackTop, trackBottom, hitLeft;
    };

    bool isReframing(double p_Time) const
    {
        int view = 0;
        m_View->getValueAtTime(p_Time, view);
        return view >= 0 && view < 4 && kViewModes[view] == eModeReframe;
    }

    double maxFov(double p_Time) const
    {
        // Wide views curve automatically (AutoDistance), so every angle is usable, unless the
        // lens is kept straight.
        return m_NoDistortion->getValueAtTime(p_Time) ? kDewarpMaxFov : 340.0;
    }

    Layout layout(double p_Time, const OfxPointD& p_PixelScale) const
    {
        Layout l;
        l.frame = m_SrcClip->getRegionOfDefinition(p_Time);
        l.px = p_PixelScale;
        const double h = l.frame.y2 - l.frame.y1;
        l.trackX = l.frame.x2 - 34.0 * l.px.x;
        l.hitLeft = l.trackX - 26.0 * l.px.x;
        l.trackTop = l.frame.y1 + 0.78 * h;
        l.trackBottom = l.frame.y1 + 0.22 * h;
        return l;
    }

    // The subject box, in the same coordinates as the pen.
    struct Box
    {
        double cx, cy, half;
    };

    Box box(const Layout& p_Layout, double p_Time) const
    {
        const double w = p_Layout.frame.x2 - p_Layout.frame.x1, h = p_Layout.frame.y2 - p_Layout.frame.y1;
        return {p_Layout.frame.x1 + m_BoxX->getValueAtTime(p_Time) * w, p_Layout.frame.y1 + m_BoxY->getValueAtTime(p_Time) * h,
                0.5 * m_SubjectSize->getValueAtTime(p_Time) / 100.0 * fmax(w, h)};
    }

    void setFovFromPen(const Layout& p_Layout, double p_Y, double p_Time)
    {
        // Top of the track is zoomed in (narrow view), bottom is zoomed out.
        double t = (p_Layout.trackTop - p_Y) / (p_Layout.trackTop - p_Layout.trackBottom);
        t = fmin(fmax(t, 0.0), 1.0);
        m_Fov->setValue(kFovMin + t * (maxFov(p_Time) - kFovMin));
    }

    OFX::ImageEffect* m_Effect;
    OFX::Clip* m_SrcClip;
    OFX::ChoiceParam* m_View;
    OFX::DoubleParam* m_Pan;
    OFX::DoubleParam* m_Tilt;
    OFX::DoubleParam* m_Roll;
    OFX::DoubleParam* m_Fov;
    OFX::DoubleParam* m_Distance;
    OFX::DoubleParam* m_SubjectSize;
    OFX::BooleanParam* m_ShowBox;
    OFX::BooleanParam* m_NoDistortion;
    OFX::DoubleParam* m_BoxX;
    OFX::DoubleParam* m_BoxY;
    Drag m_Drag;
    OfxPointD m_Last;
};

static void DrawDisc(OfxDrawContextHandle p_Context, double p_X, double p_Y, double p_Rx, double p_Ry)
{
    OfxPointD points[32];
    for (int i = 0; i < 32; ++i)
    {
        const double a = i * 2.0 * M_PI / 32.0;
        points[i] = {p_X + p_Rx * cos(a), p_Y + p_Ry * sin(a)};
    }
    OFX::Private::gDrawSuite->draw(p_Context, kOfxDrawPrimitivePolygon, points, 32);
}

bool ReframeInteract::draw(const OFX::DrawArgs& p_Args)
{
    s_OverlayDrawn.store(SecondsNow());
    OfxDrawContextHandle context = OFX::Private::gDrawSuite ? p_Args.context : nullptr;
    if (!context || !isReframing(p_Args.time))
    {
        return false;
    }

    const Layout l = layout(p_Args.time, p_Args.pixelScale);
    const double fovMax = maxFov(p_Args.time);
    const double fov = fmin(fmax(m_Fov->getValueAtTime(p_Args.time), kFovMin), fovMax);
    const double knobY = l.trackTop - (fov - kFovMin) / (fovMax - kFovMin) * (l.trackTop - l.trackBottom);
    const double halfW = 5.0 * l.px.x;
    const auto* draw = OFX::Private::gDrawSuite;

    // Track: a dark bar, filled light from the bottom up to the knob.
    const OfxRGBAColourF shade = {0.0f, 0.0f, 0.0f, 0.55f};
    const OfxRGBAColourF light = {1.0f, 1.0f, 1.0f, 0.85f};
    draw->setColour(context, &shade);
    const OfxPointD back[] = {{l.trackX - halfW - l.px.x, l.trackBottom - l.px.y}, {l.trackX + halfW + l.px.x, l.trackTop + l.px.y}};
    draw->draw(context, kOfxDrawPrimitiveRectangle, back, 2);
    draw->setColour(context, &light);
    const OfxPointD fill[] = {{l.trackX - halfW + l.px.x, l.trackBottom}, {l.trackX + halfW - l.px.x, knobY}};
    draw->draw(context, kOfxDrawPrimitiveRectangle, fill, 2);

    // Knob: a white disc with a dark rim.
    DrawDisc(context, l.trackX, knobY, 12.0 * l.px.x, 12.0 * l.px.y);
    draw->setColour(context, &shade);
    draw->setLineWidth(context, 2.0f);
    const OfxPointD rim[] = {{l.trackX - 12.0 * l.px.x, knobY - 12.0 * l.px.y}, {l.trackX + 12.0 * l.px.x, knobY + 12.0 * l.px.y}};
    draw->draw(context, kOfxDrawPrimitiveEllipse, rim, 2);

    // Subject box for tracking: corner marks, a dot in the middle and a label.
    if (m_ShowBox->getValueAtTime(p_Args.time))
    {
        const Box b = box(l, p_Args.time);
        const double cx = b.cx, cy = b.cy, half = b.half;
        const double arm = half * 0.35;
        const OfxRGBAColourF yellow = {1.0f, 0.85f, 0.2f, 0.9f};
        draw->setColour(context, &yellow);
        draw->setLineWidth(context, 2.0f);
        for (int sx = -1; sx <= 1; sx += 2)
        {
            for (int sy = -1; sy <= 1; sy += 2)
            {
                const OfxPointD corner = {cx + sx * half, cy + sy * half};
                const OfxPointD lines[] = {corner, {corner.x - sx * arm, corner.y}, corner, {corner.x, corner.y - sy * arm}};
                draw->draw(context, kOfxDrawPrimitiveLines, lines, 4);
            }
        }
        DrawDisc(context, cx, cy, 3.0 * l.px.x, 3.0 * l.px.y);
        const OfxPointD tag[] = {{cx - half, cy + half + 8.0 * l.px.y}};
        draw->drawText(context, "Subject", tag, kOfxDrawTextAlignmentLeft);
    }

    // Labels sit left of the track so they stay inside the picture.
    char value[32];
    snprintf(value, sizeof(value), "%.0f\xC2\xB0", fov);
    draw->setColour(context, &light);
    const OfxPointD zoomLabel[] = {{l.trackX - 44.0 * l.px.x, l.trackTop + 12.0 * l.px.y}};
    draw->drawText(context, "Zoom", zoomLabel, kOfxDrawTextAlignmentLeft);
    const OfxPointD valueLabel[] = {{l.trackX - 40.0 * l.px.x, l.trackBottom - 26.0 * l.px.y}};
    draw->drawText(context, value, valueLabel, kOfxDrawTextAlignmentLeft);
    return true;
}

bool ReframeInteract::penDown(const OFX::PenArgs& p_Args)
{
    if (!isReframing(p_Args.time))
    {
        return false;
    }

    const Layout l = layout(p_Args.time, p_Args.pixelScale);
    const OfxPointD& pen = p_Args.penPosition;
    if (pen.x < l.frame.x1 || pen.x > l.frame.x2 || pen.y < l.frame.y1 || pen.y > l.frame.y2)
    {
        return false;
    }

    m_Effect->beginEditBlock("Reframe");
    m_Last = pen;
    const Box b = box(l, p_Args.time);
    const double grab = 14.0; // screen pixels around a corner that pick it up
    // A hidden box cannot be grabbed: every drag in the picture then aims the view.
    const bool boxShown = m_ShowBox->getValueAtTime(p_Args.time);
    const bool nearCorner = boxShown && fabs(fabs(pen.x - b.cx) - b.half) < grab * l.px.x && fabs(fabs(pen.y - b.cy) - b.half) < grab * l.px.y;
    const bool insideBox = boxShown && fabs(pen.x - b.cx) < b.half && fabs(pen.y - b.cy) < b.half;
    if (pen.x >= l.hitLeft)
    {
        m_Drag = eDragZoom;
        setFovFromPen(l, pen.y, p_Args.time);
    }
    else if (nearCorner)
    {
        m_Drag = eDragBoxCorner;
    }
    else if (insideBox)
    {
        m_Drag = eDragBox;
    }
    else
    {
        m_Drag = eDragAim;
    }
    requestRedraw();
    return true;
}

bool ReframeInteract::penMotion(const OFX::PenArgs& p_Args)
{
    if (m_Drag == eDragNone)
    {
        return false;
    }

    const Layout l = layout(p_Args.time, p_Args.pixelScale);
    const OfxPointD& pen = p_Args.penPosition;
    const double w = l.frame.x2 - l.frame.x1, h = l.frame.y2 - l.frame.y1;
    if (m_Drag == eDragZoom)
    {
        setFovFromPen(l, pen.y, p_Args.time);
    }
    else if (m_Drag == eDragBox)
    {
        // Move the box with the hand, keeping it inside the picture.
        const Box b = box(l, p_Args.time);
        const double marginX = b.half / w, marginY = b.half / h;
        m_BoxX->setValue(fmin(fmax(m_BoxX->getValue() + (pen.x - m_Last.x) / w, marginX), 1.0 - marginX));
        m_BoxY->setValue(fmin(fmax(m_BoxY->getValue() + (pen.y - m_Last.y) / h, marginY), 1.0 - marginY));
    }
    else if (m_Drag == eDragBoxCorner)
    {
        // Resize around the centre: the corner follows the hand.
        const Box b = box(l, p_Args.time);
        const double half = fmax(fabs(pen.x - b.cx), fabs(pen.y - b.cy));
        m_SubjectSize->setValue(fmin(fmax(200.0 * half / fmax(w, h), 5.0), 60.0));
    }
    else
    {
        // The picture follows the hand: dragging right turns the camera left, dragging up tips it down.
        const double w = l.frame.x2 - l.frame.x1, h = l.frame.y2 - l.frame.y1;
        const double fov = fmin(fmax(m_Fov->getValueAtTime(p_Args.time), kFovMin), maxFov(p_Args.time));
        const double degPerPixel = fov / fmax(w, h);
        double dx = (pen.x - m_Last.x) * degPerPixel;
        double dy = (pen.y - m_Last.y) * degPerPixel; // pen y points up

        // With the horizon rolled, screen directions are rotated relative to pan and tilt.
        const double roll = m_Roll->getValueAtTime(p_Args.time) * M_PI / 180.0;
        const double ax = dx * cos(roll) + dy * sin(roll);
        const double ay = -dx * sin(roll) + dy * cos(roll);

        const double tilt = fmin(fmax(m_Tilt->getValueAtTime(p_Args.time) - ay, -90.0), 90.0);
        // Near straight up or down a sideways drag sweeps more pan; keep it from running away.
        const double panGain = 1.0 / fmax(cos(tilt * M_PI / 180.0), 0.25);
        m_Pan->setValue(m_Pan->getValueAtTime(p_Args.time) - ax * panGain);
        m_Tilt->setValue(tilt);
    }
    m_Last = pen;
    requestRedraw();
    return true;
}

bool ReframeInteract::penUp(const OFX::PenArgs& /*p_Args*/)
{
    if (m_Drag == eDragNone)
    {
        return false;
    }
    m_Drag = eDragNone;
    m_Effect->endEditBlock();
    requestRedraw();
    return true;
}

class ReframeInteractDescriptor : public OFX::DefaultEffectOverlayDescriptor<ReframeInteractDescriptor, ReframeInteract>
{
};

////////////////////////////////////////////////////////////////////////////////

class StitchPluginFactory : public OFX::PluginFactoryHelper<StitchPluginFactory>
{
public:
    StitchPluginFactory() : OFX::PluginFactoryHelper<StitchPluginFactory>(kPluginIdentifier, kPluginVersionMajor, kPluginVersionMinor) {}

    void describe(OFX::ImageEffectDescriptor& p_Desc) override;
    void describeInContext(OFX::ImageEffectDescriptor& p_Desc, OFX::ContextEnum p_Context) override;
    OFX::ImageEffect* createInstance(OfxImageEffectHandle p_Handle, OFX::ContextEnum p_Context) override;
};

void StitchPluginFactory::describe(OFX::ImageEffectDescriptor& p_Desc)
{
    p_Desc.setLabels(kPluginName, kPluginName, kPluginName);
    p_Desc.setPluginGrouping(kPluginGrouping);
    p_Desc.setPluginDescription(kPluginDescription);

    p_Desc.addSupportedContext(OFX::eContextFilter);
    p_Desc.addSupportedContext(OFX::eContextGeneral);
    p_Desc.addSupportedBitDepth(OFX::eBitDepthFloat);

    p_Desc.setSingleInstance(false);
    p_Desc.setHostFrameThreading(false);
    p_Desc.setSupportsMultiResolution(false);
    p_Desc.setSupportsTiles(false);
    p_Desc.setTemporalClipAccess(false);
    p_Desc.setRenderTwiceAlways(false);
    p_Desc.setSupportsMultipleClipPARs(false);

    p_Desc.setSupportsMetalRender(true);

    // The stitch moves pixels, so the host must not treat this as a per-pixel colour operation.
    p_Desc.setNoSpatialAwareness(false);

    p_Desc.setOverlayInteractDescriptor(new ReframeInteractDescriptor());

    // Icon for hosts that show one: files in the bundle's Resources, vector first.
    p_Desc.getPropertySet().propSetString(kOfxPropIcon, kPluginIdentifier ".svg", 0, false);
    p_Desc.getPropertySet().propSetString(kOfxPropIcon, kPluginIdentifier ".png", 1, false);
}

void StitchPluginFactory::describeInContext(OFX::ImageEffectDescriptor& p_Desc, OFX::ContextEnum /*p_Context*/)
{
    OFX::ClipDescriptor* srcClip = p_Desc.defineClip(kOfxImageEffectSimpleSourceClipName);
    srcClip->addSupportedComponent(OFX::ePixelComponentRGBA);
    srcClip->setTemporalClipAccess(false);
    srcClip->setSupportsTiles(false);
    srcClip->setIsMask(false);

    OFX::ClipDescriptor* dstClip = p_Desc.defineClip(kOfxImageEffectOutputClipName);
    dstClip->addSupportedComponent(OFX::ePixelComponentRGBA);
    dstClip->setSupportsTiles(false);

    OFX::PageParamDescriptor* page = p_Desc.definePageParam("Controls");

    OFX::ChoiceParamDescriptor* view = p_Desc.defineChoiceParam(kParamView);
    view->setLabels("View", "View", "View");
    view->setHint("Stitched 360 gives the whole sphere, for 360 delivery. Reframe gives a normal flat picture you aim with the controls below. The source views show the clip before stitching.");
    view->appendOption("Stitched 360");
    view->appendOption("Reframe");
    view->appendOption("Source");
    view->appendOption("Source, Lenses Tinted");
    view->setDefault(1); // Reframe, the usual way to work with 360 footage
    view->setAnimates(false);
    page->addChild(*view);

    OFX::BooleanParamDescriptor* fullRes = p_Desc.defineBooleanParam(kParamFullRes);
    fullRes->setLabels("Full Resolution", "Full Resolution", "Full Resolution");
    fullRes->setHint("Reads the lenses from the clip's own files at the full recorded resolution, as sharp as Insta360 Studio, "
                     "instead of from Resolve, which only passes on as many pixels as the timeline has. Turn off if playback "
                     "is too slow on this Mac. Grades applied before this effect do not reach the full resolution picture.");
    fullRes->setDefault(true);
    fullRes->setAnimates(false);
    page->addChild(*fullRes);

    OFX::GroupParamDescriptor* stabilize = p_Desc.defineGroupParam("stabilizeGroup");
    stabilize->setLabels("Stabilization", "Stabilization", "Stabilization");
    stabilize->setHint("Uses the camera's motion sensor, like Insta360's FlowState. Needs a clip imported with "
                       "Insta360 Import 0.2 or later; timelapse clips have no motion data.");

    OFX::ChoiceParamDescriptor* stabMode = p_Desc.defineChoiceParam(kParamStabilize);
    stabMode->setLabels("Stabilization", "Stabilization", "Stabilization");
    stabMode->setHint("Smooth removes shake but follows where you turn the camera. Locked Direction keeps looking "
                      "the same way as at the start of the clip, whatever the camera does.");
    stabMode->appendOption("Off");
    stabMode->appendOption("Smooth");
    stabMode->appendOption("Locked Direction");
    stabMode->setDefault(1);
    stabMode->setAnimates(false);
    stabMode->setParent(*stabilize);
    page->addChild(*stabMode);

    OFX::DoubleParamDescriptor* smoothness = p_Desc.defineDoubleParam(kParamSmoothness);
    smoothness->setLabels("Smoothness", "Smoothness", "Smoothness");
    smoothness->setHint("How calmly Smooth follows the camera: seconds of movement averaged. Higher is steadier.");
    smoothness->setDefault(1.0);
    smoothness->setRange(0.1, 5.0);
    smoothness->setDisplayRange(0.1, 5.0);
    smoothness->setIncrement(0.1);
    smoothness->setAnimates(false);
    smoothness->setParent(*stabilize);
    page->addChild(*smoothness);

    OFX::BooleanParamDescriptor* level = p_Desc.defineBooleanParam(kParamLevel);
    level->setLabels("Level Horizon", "Level Horizon", "Level Horizon");
    level->setHint("Keeps the horizon straight, using the camera's sense of gravity.");
    level->setDefault(true);
    level->setAnimates(false);
    level->setParent(*stabilize);
    page->addChild(*level);

    OFX::GroupParamDescriptor* reframe = p_Desc.defineGroupParam("reframe");
    reframe->setLabels("Reframe", "Reframe", "Reframe");
    reframe->setHint("The virtual camera used when View is set to Reframe.");

    OFX::ChoiceParamDescriptor* styleMenu = p_Desc.defineChoiceParam(kParamStyle);
    styleMenu->setLabels("View Style", "View Style", "View Style");
    styleMenu->setHint("One-click looks like Insta360 Studio's: Tiny Planet, Mega View, Ultra Wide, Dewarp, Linear. "
                       "Shows Custom once Field of View or Distance is changed by hand.");
    for (int i = 0; i < kViewStyleCount; ++i)
    {
        styleMenu->appendOption(kViewStyles[i].label);
    }
    styleMenu->setDefault(4); // Dewarp, which matches the slider defaults below
    styleMenu->setAnimates(false);
    styleMenu->setParent(*reframe);
    page->addChild(*styleMenu);

    struct Slider { const char* name; const char* label; const char* hint; double def, min, max, displayMin, displayMax, increment; };
    const Slider sliders[] = {
        {kParamFov, "Field of View", "How much of the scene fits across the longer side of the frame, in degrees. Above 100 the picture curves automatically so the edges do not stretch.", 110.0, kFovMin, 340.0, kFovMin, 340.0, 0.1},
        {kParamDistance, "Distance", "How far the camera sits behind the centre of the sphere: 0 keeps straight lines straight, towards 1 the picture curves like an action camera. Fields of view above 100 degrees need some curve, so there it cannot go below a minimum (about 0.6 at 200 degrees).", 0.25, 0.0, 1.0, 0.0, 1.0, 0.01},
        {kParamPan, "Pan", "Turns the view left and right, in degrees. Keeps going past 180 for full spins.", 0.0, -3600.0, 3600.0, -180.0, 180.0, 0.1},
        {kParamTilt, "Tilt", "Tips the view up and down, in degrees.", 0.0, -180.0, 180.0, -90.0, 90.0, 0.1},
        {kParamRoll, "Roll", "Rotates the horizon, in degrees.", 0.0, -3600.0, 3600.0, -180.0, 180.0, 0.1},
    };
    for (const Slider& s : sliders)
    {
        OFX::DoubleParamDescriptor* param = p_Desc.defineDoubleParam(s.name);
        param->setLabels(s.label, s.label, s.label);
        param->setHint(s.hint);
        param->setDefault(s.def);
        param->setRange(s.min, s.max);
        param->setDisplayRange(s.displayMin, s.displayMax);
        param->setIncrement(s.increment);
        param->setParent(*reframe);
        page->addChild(*param);
    }

    OFX::BooleanParamDescriptor* noDistortion = p_Desc.defineBooleanParam(kParamNoDistortion);
    noDistortion->setLabels("Remove Distortion", "Remove Distortion", "Remove Distortion");
    noDistortion->setHint("Keeps straight lines straight, like Insta360's Dewarp / linear view: the curve is taken out "
                          "and the view is limited to 100 degrees so the edges do not stretch. Turn off to get your "
                          "Field of View and Distance back.");
    noDistortion->setDefault(false);
    noDistortion->setParent(*reframe);
    page->addChild(*noDistortion);

    OFX::GroupParamDescriptor* tracking = p_Desc.defineGroupParam("tracking");
    tracking->setLabels("Subject Tracking", "Subject Tracking", "Subject Tracking");
    tracking->setHint("With the viewer in Open FX Overlay mode, drag the yellow box onto the subject and press Track Subject. "
                      "The view follows it from this frame on, as Pan and Tilt keyframes, keeping it where the box is.");

    OFX::BooleanParamDescriptor* showBox = p_Desc.defineBooleanParam(kParamShowBox);
    showBox->setLabels("Show Subject Box", "Show Subject Box", "Show Subject Box");
    showBox->setHint("Shows the yellow box used to pick a subject for tracking. Turn it off while you only aim the view; "
                     "pressing Track Subject turns it back on.");
    showBox->setDefault(false);
    showBox->setAnimates(false);
    showBox->setParent(*tracking);
    page->addChild(*showBox);

    OFX::DoubleParamDescriptor* subjectSize = p_Desc.defineDoubleParam(kParamSubjectSize);
    subjectSize->setLabels("Subject Size", "Subject Size", "Subject Size");
    subjectSize->setHint("Size of the yellow box, as a percentage of the view. Make it fit the subject snugly.");
    subjectSize->setDefault(20.0);
    subjectSize->setRange(5.0, 60.0);
    subjectSize->setDisplayRange(5.0, 60.0);
    subjectSize->setIncrement(1.0);
    subjectSize->setAnimates(false);
    subjectSize->setParent(*tracking);
    page->addChild(*subjectSize);

    OFX::DoubleParamDescriptor* trackLength = p_Desc.defineDoubleParam(kParamTrackLength);
    trackLength->setLabels("Track Length", "Track Length", "Track Length");
    trackLength->setHint("How many seconds to track at most, from the current frame. Used when Until End of Clip is off.");
    trackLength->setDefault(10.0);
    trackLength->setRange(1.0, 600.0);
    trackLength->setDisplayRange(1.0, 60.0);
    trackLength->setIncrement(1.0);
    trackLength->setAnimates(false);
    trackLength->setParent(*tracking);
    page->addChild(*trackLength);

    OFX::BooleanParamDescriptor* toEnd = p_Desc.defineBooleanParam(kParamTrackToEnd);
    toEnd->setLabels("Until End of Clip", "Until End of Clip", "Until End of Clip");
    toEnd->setHint("Track all the way to the end of the clip (or until the subject is lost), instead of for Track Length seconds.");
    toEnd->setDefault(true);
    toEnd->setAnimates(false);
    toEnd->setParent(*tracking);
    page->addChild(*toEnd);

    for (const char* name : {kParamBoxX, kParamBoxY})
    {
        // Where the yellow box is, 0..1 across the frame (y from the bottom). Set by dragging it.
        OFX::DoubleParamDescriptor* position = p_Desc.defineDoubleParam(name);
        position->setLabels(name, name, name);
        position->setDefault(0.5);
        position->setRange(0.0, 1.0);
        position->setAnimates(false);
        position->setIsSecret(true);
        position->setParent(*tracking);
        page->addChild(*position);
    }

    OFX::StringParamDescriptor* tip = p_Desc.defineStringParam(kParamOverlayTip);
    tip->setLabels("Needs", "Needs", "Needs");
    tip->setStringType(OFX::eStringTypeLabel);
    tip->setDefault("Viewer: Open FX Overlay");
    tip->setAnimates(false);
    tip->setParent(*tracking);
    page->addChild(*tip);

    OFX::PushButtonParamDescriptor* track = p_Desc.definePushButtonParam(kParamTrack);
    track->setLabels("Track Subject", "Track Subject", "Track Subject");
    track->setHint("Follow the subject in the yellow box from this frame forward. Needs the viewer in Open FX Overlay mode.");
    track->setParent(*tracking);
    page->addChild(*track);

    OFX::DoubleParamDescriptor* baseDistance = p_Desc.defineDoubleParam(kParamBaseDistance);
    baseDistance->setLabels("Base Distance", "Base Distance", "Base Distance");
    baseDistance->setDefault(0.25); // matches the Distance default
    baseDistance->setRange(0.0, 1.0);
    baseDistance->setAnimates(false);
    baseDistance->setIsSecret(true);
    page->addChild(*baseDistance);

    OFX::StringParamDescriptor* calibration = p_Desc.defineStringParam(kParamCalibration);
    calibration->setLabels("Calibration File", "Calibration File", "Calibration File");
    calibration->setHint("The .json file the import wrote next to a clip's lens files. Leave empty to use the calibration of the "
                         "camera you imported from last, which is right unless you edit clips from several cameras.");
    calibration->setStringType(OFX::eStringTypeFilePath);
    calibration->setFilePathExists(true);
    calibration->setAnimates(false);
    page->addChild(*calibration);

    OFX::DoubleParamDescriptor* blend = p_Desc.defineDoubleParam(kParamBlend);
    blend->setLabels("Seam Blend Width", "Seam Blend Width", "Seam Blend Width");
    blend->setHint("Width in degrees of the cross-fade between the two lenses. The lenses only overlap by about 12 degrees, "
                   "and wider fades show close subjects twice.");
    blend->setDefault(4.0);
    blend->setRange(0.1, 30.0);
    blend->setDisplayRange(0.1, 30.0);
    blend->setIncrement(0.1);
    page->addChild(*blend);

    OFX::BooleanParamDescriptor* gainMatch = p_Desc.defineBooleanParam(kParamGainMatch);
    gainMatch->setLabels("Match Lenses", "Match Lenses", "Match Lenses");
    gainMatch->setHint("Evens out brightness and colour differences between the two lenses at the seam, measured on every frame.");
    gainMatch->setDefault(true);
    page->addChild(*gainMatch);

    OFX::BooleanParamDescriptor* autoDistance = p_Desc.defineBooleanParam(kParamAutoDistance);
    autoDistance->setLabels("Auto Stitch Distance", "Auto Stitch Distance", "Auto Stitch Distance");
    autoDistance->setHint("Finds how far away things are along the seam on every frame and lines the lenses up there, "
                          "so that people close to the camera are not cut. Turn off to use Stitch Distance instead.");
    autoDistance->setDefault(true);
    page->addChild(*autoDistance);

    OFX::DoubleParamDescriptor* stitchDistance = p_Desc.defineDoubleParam(kParamStitchDistance);
    stitchDistance->setLabels("Stitch Distance", "Stitch Distance", "Stitch Distance");
    stitchDistance->setHint("Distance in metres at which the two lenses line up, when Auto Stitch Distance is off. "
                            "Things nearer or further away show a small step at the seam.");
    stitchDistance->setDefault(2.0);
    stitchDistance->setRange(0.3, 1000.0);
    stitchDistance->setDisplayRange(0.3, 10.0);
    stitchDistance->setIncrement(0.1);
    page->addChild(*stitchDistance);

    OFX::GroupParamDescriptor* about = p_Desc.defineGroupParam("aboutGroup");
    about->setLabels("About", "About", "About");
    about->setOpen(false);

    OFX::StringParamDescriptor* aboutText = p_Desc.defineStringParam(kParamAbout);
    aboutText->setLabels("Insta360 Stitch", "Insta360 Stitch", "Insta360 Stitch");
    aboutText->setStringType(OFX::eStringTypeLabel);
    aboutText->setDefault("Version " PLUGIN_VERSION ", free and open source");
    aboutText->setAnimates(false);
    aboutText->setParent(*about);
    page->addChild(*aboutText);

    OFX::PushButtonParamDescriptor* update = p_Desc.definePushButtonParam(kParamCheckUpdate);
    update->setLabels("Check for Updates", "Check for Updates", "Check for Updates");
    update->setHint("Looks on GitHub for a newer version and offers to install it. Nothing is checked unless you press this.");
    update->setParent(*about);
    page->addChild(*update);

    OFX::PushButtonParamDescriptor* donate = p_Desc.definePushButtonParam(kParamDonate);
    donate->setLabels("Support on Ko-fi", "Support on Ko-fi", "Support on Ko-fi");
    donate->setHint("Opens " kDonateUrl " in your browser. Thank you!");
    donate->setParent(*about);
    page->addChild(*donate);
}

OFX::ImageEffect* StitchPluginFactory::createInstance(OfxImageEffectHandle p_Handle, OFX::ContextEnum /*p_Context*/)
{
    return new StitchPlugin(p_Handle);
}

void OFX::Plugin::getPluginIDs(OFX::PluginFactoryArray& p_FactoryArray)
{
    static StitchPluginFactory stitchPlugin;
    p_FactoryArray.push_back(&stitchPlugin);
}
