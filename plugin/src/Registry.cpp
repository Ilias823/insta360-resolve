#include "Registry.h"

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>

static void AppendUtf8(std::string& p_Out, unsigned p_Code)
{
    if (p_Code < 0x80)
    {
        p_Out += char(p_Code);
    }
    else if (p_Code < 0x800)
    {
        p_Out += char(0xC0 | (p_Code >> 6));
        p_Out += char(0x80 | (p_Code & 0x3F));
    }
    else
    {
        p_Out += char(0xE0 | (p_Code >> 12));
        p_Out += char(0x80 | ((p_Code >> 6) & 0x3F));
        p_Out += char(0x80 | (p_Code & 0x3F));
    }
}

std::string JsonString(const std::string& p_Path, const std::string& p_Key)
{
    std::ifstream file(p_Path);
    if (!file)
    {
        return "";
    }
    std::stringstream buffer;
    buffer << file.rdbuf();
    const std::string text = buffer.str();

    size_t pos = text.find("\"" + p_Key + "\"");
    if (pos == std::string::npos || (pos = text.find(':', pos)) == std::string::npos ||
        (pos = text.find('"', pos)) == std::string::npos)
    {
        return "";
    }
    // Paths can hold escapes, such as ’ for the apostrophe in "Elias's MacBook".
    std::string out;
    for (size_t i = pos + 1; i < text.size() && text[i] != '"'; ++i)
    {
        if (text[i] != '\\' || i + 1 >= text.size())
        {
            out += text[i];
            continue;
        }
        const char c = text[++i];
        if (c == 'u' && i + 4 < text.size())
        {
            AppendUtf8(out, unsigned(strtoul(text.substr(i + 1, 4).c_str(), nullptr, 16)));
            i += 4;
        }
        else
        {
            out += c == 'n' ? '\n' : c == 't' ? '\t' : c;
        }
    }
    return out;
}

ClipFiles LookupClip(int p_ClipId)
{
    ClipFiles files;
    const char* home = getenv("HOME");
    if (!home || p_ClipId <= 0)
    {
        return files;
    }
    char name[16];
    snprintf(name, sizeof(name), "%06x", p_ClipId);
    const std::string path = std::string(home) + "/Library/Application Support/Insta360Stitch/clips/" + name + ".json";
    files.info = JsonString(path, "info");
    files.motion = JsonString(path, "motion");
    files.found = !files.info.empty();
    return files;
}
