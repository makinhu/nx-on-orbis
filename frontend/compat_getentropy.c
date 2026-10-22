/* getentropy(): the SDK musl's implementation calls the raw Linux getrandom syscall,
 * which the PS4 kernel has no mapping for, and OpenSSL 3 takes its address with a weak
 * extern reference - an import create-fself cannot assign to a system module, so the
 * link refuses to produce an eboot.bin ("missing library for symbol (getentropy)"). This
 * executable provides the symbol and reads entropy the same way Eden's std::random_device
 * already does on the console: /dev/urandom via the POSIX open/read of the libc.prx. */
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>

int getentropy(void *buf, size_t len)
{
    const int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        errno = EIO;
        return -1;
    }
    size_t got = 0;
    while (got < len) {
        const ssize_t chunk = read(fd, (char *)buf + got, len - got);
        if (chunk <= 0) {
            close(fd);
            errno = chunk < 0 ? EIO : EIO;
            return -1;
        }
        got += (size_t)chunk;
    }
    close(fd);
    return 0;
}
