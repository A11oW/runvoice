/* pastev.c — послать ⌘V кодом клавиши (независимо от раскладки).
   Код 9 = физическая клавиша "v" (ANSI). Нужно только Accessibility. */
#include <ApplicationServices/ApplicationServices.h>
#include <unistd.h>

int main(void) {
    const CGKeyCode V = 9; /* kVK_ANSI_V */
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, V, true);
    CGEventRef up   = CGEventCreateKeyboardEvent(NULL, V, false);
    if (!down || !up) return 1;
    CGEventSetFlags(down, kCGEventFlagMaskCommand);
    CGEventSetFlags(up,   kCGEventFlagMaskCommand);
    CGEventPost(kCGHIDEventTap, down);
    usleep(30000);
    CGEventPost(kCGHIDEventTap, up);
    CFRelease(down);
    CFRelease(up);
    return 0;
}
