#pragma once

#include <string>

// What the import registered for a clip number (tools/ingest.py register_clip), from
// ~/Library/Application Support/Insta360Stitch/clips/<number in hex>.json.
struct ClipFiles
{
    bool found = false;
    std::string info;   // the clip's .json: calibration and more
    std::string motion; // camera motion for stabilisation, "" if the clip has none
};

ClipFiles LookupClip(int p_ClipId);

// Value of a string field in a small JSON file written by the import tools, "" if absent.
std::string JsonString(const std::string& p_Path, const std::string& p_Key);
