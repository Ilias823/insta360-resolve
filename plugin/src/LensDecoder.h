#pragma once

#include <memory>
#include <string>

// Full resolution lens pictures, decoded from the clip's own lens files (the .mov files the
// import copied out of the .insv) instead of taken from Resolve, which only hands an effect
// as many pixels as the timeline has.
//
// Each lens is kept as it is recorded, 4:2:0 YCbCr, in two mipmapped Metal textures (luma R8,
// chroma RG8; R16 and RG16 for 10-bit files); the kernel converts to RGB as it samples.
struct LensImages
{
    void* textures[4] = {}; // id<MTLTexture>: luma A, chroma A, luma B, chroma B
    int width = 0;          // size of one lens picture in pixels
    int height = 0;
    int bits = 8;           // bits per component in the file
    std::shared_ptr<void> owner; // keeps the textures alive; hand it to the GPU work that reads them
};

// Frame p_Frame of both lens files, ready on the GPU of p_CmdQ (an MTLCommandQueue). Recently
// used frames come from a cache. Returns false if a file cannot be read or has no such frame.
// Safe to call from several render threads at once.
bool AcquireLensImages(void* p_CmdQ, const std::string& p_LensA, const std::string& p_LensB, int p_Frame, LensImages& p_Images);
