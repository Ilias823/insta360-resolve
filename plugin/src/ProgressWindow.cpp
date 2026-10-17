#include "ProgressWindow.h"

#include <chrono>
#include <cstring>
#include <dlfcn.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char** environ;

// .../Insta360Stitch.ofx.bundle/Contents/MacOS/Insta360Stitch.ofx -> .../Contents/Resources/TrackProgress
static std::string HelperPath()
{
    Dl_info info;
    if (!dladdr(reinterpret_cast<void*>(&HelperPath), &info) || !info.dli_fname)
    {
        return "";
    }
    std::string path = info.dli_fname;
    for (int i = 0; i < 2; ++i)
    {
        const size_t slash = path.rfind('/');
        if (slash == std::string::npos)
        {
            return "";
        }
        path.resize(slash);
    }
    return path + "/Resources/TrackProgress";
}

static double Now()
{
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

ProgressWindow::~ProgressWindow()
{
    close();
}

void ProgressWindow::open(const std::string& p_Title)
{
    const std::string path = HelperPath();
    int toHelper[2], fromHelper[2];
    if (path.empty() || access(path.c_str(), X_OK) != 0 || pipe(toHelper) != 0)
    {
        return;
    }
    if (pipe(fromHelper) != 0)
    {
        ::close(toHelper[0]);
        ::close(toHelper[1]);
        return;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, toHelper[0], STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, fromHelper[1], STDOUT_FILENO);
    for (int fd : {toHelper[0], toHelper[1], fromHelper[0], fromHelper[1]})
    {
        posix_spawn_file_actions_addclose(&actions, fd);
    }
    char* argv[] = {const_cast<char*>(path.c_str()), const_cast<char*>(p_Title.c_str()), nullptr};
    const int status = posix_spawn(&m_Pid, path.c_str(), &actions, nullptr, argv, environ);
    posix_spawn_file_actions_destroy(&actions);

    ::close(toHelper[0]);
    ::close(fromHelper[1]);
    if (status != 0)
    {
        m_Pid = -1;
        ::close(toHelper[1]);
        ::close(fromHelper[0]);
        return;
    }
    m_ToHelper = toHelper[1];
    m_FromHelper = fromHelper[0];
    fcntl(m_ToHelper, F_SETNOSIGPIPE, 1); // a closed window must not take Resolve down with SIGPIPE
    fcntl(m_FromHelper, F_SETFL, fcntl(m_FromHelper, F_GETFL) | O_NONBLOCK);
}

bool ProgressWindow::update(double p_Fraction, const std::string& p_Text)
{
    if (m_ToHelper < 0)
    {
        return true;
    }

    char buffer[256];
    const ssize_t got = read(m_FromHelper, buffer, sizeof(buffer) - 1);
    if (got > 0)
    {
        buffer[got] = '\0';
        m_Cancelled = m_Cancelled || strstr(buffer, "cancel") != nullptr;
    }

    // About ten updates a second is plenty for a progress bar.
    const double now = Now();
    if (now - m_LastSent >= 0.1)
    {
        m_LastSent = now;
        const std::string line = "p " + std::to_string(p_Fraction) + " " + p_Text + "\n";
        if (write(m_ToHelper, line.data(), line.size()) < 0)
        {
            close(); // the window was closed some other way; carry on without it
        }
    }
    return !m_Cancelled;
}

void ProgressWindow::close()
{
    if (m_ToHelper >= 0)
    {
        const char done[] = "done\n";
        (void)write(m_ToHelper, done, sizeof(done) - 1);
        ::close(m_ToHelper);
        m_ToHelper = -1;
    }
    if (m_FromHelper >= 0)
    {
        ::close(m_FromHelper);
        m_FromHelper = -1;
    }
    if (m_Pid > 0)
    {
        // Give the window a moment to close by itself, then make sure it is gone.
        for (int i = 0; i < 20 && waitpid(m_Pid, nullptr, WNOHANG) == 0; ++i)
        {
            usleep(10000);
        }
        if (waitpid(m_Pid, nullptr, WNOHANG) == 0)
        {
            kill(m_Pid, SIGTERM);
            waitpid(m_Pid, nullptr, 0);
        }
        m_Pid = -1;
    }
}
