// Isolated native-terminal workload. No shell commands, network or user files.
// The executable basename selects echo (interactive), flood or ticker mode.
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

static int send_all(const char *bytes, size_t count) {
    while (count) {
        ssize_t sent = write(STDOUT_FILENO, bytes, count);
        if (sent < 0 && errno == EINTR) continue;
        if (sent <= 0) return 1;
        bytes += sent; count -= (size_t)sent;
    }
    return 0;
}
static void pause_ms(long ms) {
    struct timespec delay = { ms / 1000, (ms % 1000) * 1000000 };
    while (nanosleep(&delay, &delay) && errno == EINTR) {}
}
int main(int argc, char **argv) {
    (void)argc;
    struct termios settings;
    if (tcgetattr(STDIN_FILENO, &settings)) return 1;
    cfmakeraw(&settings);
    if (tcsetattr(STDIN_FILENO, TCSANOW, &settings)) return 1;
    const char *mode = strrchr(argv[0], '/'); mode = mode ? mode + 1 : argv[0];
    if (send_all("STRESS_READY\r\n", 14)) return 1;
    uint64_t sequence = 0;
    char line[160];
    if (!strcmp(mode, "interactive")) {
        char key;
        while (read(STDIN_FILENO, &key, 1) == 1) {
            int count = snprintf(line, sizeof(line), "\r\nINPUT:%08llu\r\n", (unsigned long long)++sequence);
            if (send_all(line, (size_t)count)) return 1;
        }
        return 0;
    }
    const int flood = !strcmp(mode, "flood");
    for (;;) {
        int count = snprintf(line, sizeof(line), "\033[36m%s:%010llu\033[0m Unicode: 日本語 🦀 — bounded output workload\r\n",
            flood ? "FLOOD" : "TICK", (unsigned long long)++sequence);
        int lines = flood ? 256 : 1;
        for (int i = 0; i < lines; ++i) if (send_all(line, (size_t)count)) return 1;
        pause_ms(flood ? 10 : 100);
    }
}
