// Private PTY test executable, compiled as "claude" in a temporary directory.
// Echoes bytes without launching a real agent, executing commands, or using a network.
#include <errno.h>
#include <unistd.h>

int main(void) {
    char buffer[4096];
    for (;;) {
        ssize_t count = read(STDIN_FILENO, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return count < 0;
        ssize_t sent = 0;
        while (sent < count) {
            ssize_t result = write(STDOUT_FILENO, buffer + sent, (size_t)(count - sent));
            if (result < 0 && errno == EINTR) continue;
            if (result <= 0) return 1;
            sent += result;
        }
    }
}
