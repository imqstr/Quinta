// Minimal API additions for the macOS Studio startup experiment.
// This does not make Studio usable: Qt startup still segfaults.
@class NSString;
NSString * const WKWebsiteDataTypeCookies = @"WKWebsiteDataTypeCookies";

extern int CGGetOnlineDisplayList(unsigned int, unsigned int *, unsigned int *);
unsigned int CGDisplayIsOnline(unsigned int display) {
    unsigned int displays[64], count = 0;
    if (CGGetOnlineDisplayList(64, displays, &count)) return 0;
    for (unsigned int i = 0; i < count && i < 64; ++i)
        if (displays[i] == display) return 1;
    return 0;
}
