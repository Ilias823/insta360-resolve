#pragma once

#include <cstdint>

// The clip tag the import puts in the unused corners of each clip; see tools/clip_tag.py, which
// writes it, for the layout. 32 cells: a 24-bit clip number and an 8-bit check.
namespace ClipTag
{
const int kBits = 32;
const int kGrid = 4;
const double kBlockStart = 0.02;
const double kBlockSize = 0.11;
const int kCheckXor = 0x5A;

// Centre of a bit's cell in a side-by-side frame, in pixels, y from the top.
inline void CellCentre(int p_Bit, int p_Width, int p_Height, int& p_X, int& p_Y)
{
    const int block = p_Bit / (kGrid * kGrid), cell = p_Bit % (kGrid * kGrid);
    const int row = cell / kGrid, col = cell % kGrid;
    const double step = kBlockSize / kGrid;
    const double tileW = p_Width / 2.0;
    const double top = block == 0 ? kBlockStart : 1.0 - kBlockStart - kBlockSize;
    p_X = int((kBlockStart + (col + 0.5) * step) * tileW);
    p_Y = int((top + (row + 0.5) * step) * p_Height);
}

inline int CheckByte(uint32_t p_Id)
{
    int crc = 0;
    for (int shift = 16; shift >= 0; shift -= 8)
    {
        crc ^= (p_Id >> shift) & 0xFF;
        for (int i = 0; i < 8; ++i)
        {
            crc = (crc & 0x80) ? ((crc << 1) ^ 0x07) & 0xFF : (crc << 1) & 0xFF;
        }
    }
    return crc ^ kCheckXor;
}

// Clip number from the 32 cell brightnesses (0..1), or -1 if they do not form a valid tag.
inline int Decode(const float p_Brightness[kBits])
{
    uint32_t value = 0;
    for (int bit = 0; bit < kBits; ++bit)
    {
        if (p_Brightness[bit] > 0.5f)
        {
            value |= 1u << bit;
        }
    }
    const uint32_t id = value & 0xFFFFFF;
    return int(value >> 24) == CheckByte(id) ? int(id) : -1;
}
}
