#pragma once

#include <string>
#include <sys/types.h>

// Shows a progress window outside Resolve (the TrackProgress helper in the bundle) while the
// plugin is busy, since Resolve's own interface does not update until the plugin returns.
// Everything fails quietly: without the helper the work simply runs without a window.
class ProgressWindow
{
public:
    ~ProgressWindow();

    void open(const std::string& p_Title);

    // Returns false once the user has pressed Cancel.
    bool update(double p_Fraction, const std::string& p_Text);

    void close();

private:
    pid_t m_Pid = -1;
    int m_ToHelper = -1;
    int m_FromHelper = -1;
    bool m_Cancelled = false;
    double m_LastSent = -1.0;
};
