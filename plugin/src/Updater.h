#pragma once

#include <string>

// Checks the project's GitHub releases for a newer version of the plugin. Only runs when the
// user presses "Check for Updates"; nothing is sent anywhere otherwise.
struct ReleaseInfo
{
    bool ok = false;
    std::string error;   // why the check failed, when !ok
    std::string version; // e.g. "0.2.0" (the tag without its leading "v")
    std::string notes;   // the release description
    std::string pageUrl; // the release's web page
    std::string pkgUrl;  // download link of its .pkg installer, empty if there is none
};

// Latest published release of p_Repo ("owner/name"). Waits up to about ten seconds.
ReleaseInfo FetchLatestRelease(const std::string& p_Repo);

// Compares dotted version numbers: negative if p_A is older than p_B, 0 if equal, positive if newer.
int CompareVersions(const std::string& p_A, const std::string& p_B);

// Downloads p_Url into the user's Downloads folder; returns the file's path, or "" with p_Error set.
std::string DownloadToDownloads(const std::string& p_Url, std::string& p_Error);

// Opens a file or web address the way a double-click would (Installer for a .pkg, the browser for a link).
void OpenWithSystem(const std::string& p_PathOrUrl);
