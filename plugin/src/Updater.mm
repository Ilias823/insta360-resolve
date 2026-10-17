#import <Foundation/Foundation.h>

#include "Updater.h"

#include <sstream>
#include <spawn.h>
#include <sys/wait.h>
#include <vector>

static const NSTimeInterval kTimeout = 10.0;

// Runs a request and waits for it; the plugin is busy in a button press anyway.
static NSData* Fetch(NSURL* p_Url, std::string& p_Error, NSInteger* p_Status)
{
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:p_Url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:kTimeout];
    [request setValue:@"Insta360Stitch-plugin" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];

    __block NSData* body = nil;
    __block NSString* failure = nil;
    __block NSInteger status = 0;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSURLSessionDataTask* task = [NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
            body = data;
            failure = error.localizedDescription;
            status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse*)response).statusCode : 0;
            dispatch_semaphore_signal(done);
        }];
    [task resume];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, int64_t((kTimeout + 5.0) * NSEC_PER_SEC))) != 0)
    {
        [task cancel];
        p_Error = "no answer from GitHub";
        return nil;
    }
    if (failure)
    {
        p_Error = failure.UTF8String;
    }
    if (p_Status)
    {
        *p_Status = status;
    }
    return body;
}

ReleaseInfo FetchLatestRelease(const std::string& p_Repo)
{
    ReleaseInfo info;
    @autoreleasepool
    {
        NSString* address = [NSString stringWithFormat:@"https://api.github.com/repos/%s/releases/latest", p_Repo.c_str()];
        NSInteger status = 0;
        NSData* body = Fetch([NSURL URLWithString:address], info.error, &status);
        if (!body)
        {
            return info;
        }
        if (status == 404)
        {
            info.error = "no release has been published yet";
            return info;
        }
        if (status != 200)
        {
            info.error = "GitHub answered with status " + std::to_string(long(status));
            return info;
        }

        NSDictionary* json = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
        NSString* tag = [json isKindOfClass:NSDictionary.class] ? json[@"tag_name"] : nil;
        if (![tag isKindOfClass:NSString.class])
        {
            info.error = "GitHub's answer could not be read";
            return info;
        }
        if ([tag hasPrefix:@"v"] || [tag hasPrefix:@"V"])
        {
            tag = [tag substringFromIndex:1];
        }
        info.version = tag.UTF8String;
        NSString* notes = json[@"body"];
        info.notes = [notes isKindOfClass:NSString.class] ? notes.UTF8String : "";
        NSString* page = json[@"html_url"];
        info.pageUrl = [page isKindOfClass:NSString.class] ? page.UTF8String : "";
        for (NSDictionary* asset in json[@"assets"])
        {
            NSString* name = asset[@"name"];
            NSString* link = asset[@"browser_download_url"];
            if ([name isKindOfClass:NSString.class] && [link isKindOfClass:NSString.class] &&
                [name.lowercaseString hasSuffix:@".pkg"])
            {
                info.pkgUrl = link.UTF8String;
                break;
            }
        }
        info.ok = true;
    }
    return info;
}

int CompareVersions(const std::string& p_A, const std::string& p_B)
{
    auto parts = [](const std::string& v) {
        std::vector<long> out;
        std::stringstream ss(v);
        std::string piece;
        while (std::getline(ss, piece, '.'))
        {
            out.push_back(strtol(piece.c_str(), nullptr, 10));
        }
        return out;
    };
    const std::vector<long> a = parts(p_A), b = parts(p_B);
    for (size_t i = 0; i < std::max(a.size(), b.size()); ++i)
    {
        const long x = i < a.size() ? a[i] : 0, y = i < b.size() ? b[i] : 0;
        if (x != y)
        {
            return x < y ? -1 : 1;
        }
    }
    return 0;
}

std::string DownloadToDownloads(const std::string& p_Url, std::string& p_Error)
{
    @autoreleasepool
    {
        NSURL* url = [NSURL URLWithString:@(p_Url.c_str())];
        NSInteger status = 0;
        NSData* body = Fetch(url, p_Error, &status);
        if (!body || status != 200)
        {
            if (p_Error.empty())
            {
                p_Error = "download failed (status " + std::to_string(long(status)) + ")";
            }
            return "";
        }
        NSString* folder = [NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory, NSUserDomainMask, YES) firstObject]
                               ?: NSTemporaryDirectory();
        NSString* path = [folder stringByAppendingPathComponent:url.lastPathComponent];
        if (![body writeToFile:path atomically:YES])
        {
            p_Error = "could not save the download in " + std::string(folder.UTF8String);
            return "";
        }
        return path.UTF8String;
    }
}

void OpenWithSystem(const std::string& p_PathOrUrl)
{
    pid_t pid;
    char* argv[] = {const_cast<char*>("/usr/bin/open"), const_cast<char*>(p_PathOrUrl.c_str()), nullptr};
    char* env[] = {nullptr};
    if (posix_spawn(&pid, "/usr/bin/open", nullptr, nullptr, argv, env) == 0)
    {
        waitpid(pid, nullptr, 0);
    }
}
