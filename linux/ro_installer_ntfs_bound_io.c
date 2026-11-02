#define _GNU_SOURCE
#define _LARGEFILE64_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

/* Private, per-child Linux x86_64 adapter. Not write admission.
 * The alias cannot be a numeric procfd entry: ignoring this adapter fails closed.
 * Duplication preserves the original description and any existing exclusive claim.
 * Other paths retain normal system open/stat semantics. Never install globally.
 */
#if !defined(__linux__) || !defined(__x86_64__) || !defined(__GLIBC__)
#error "NTFS descriptor adapter requires Linux x86_64 glibc"
#endif
static const char target[] = "/proc/self/fd/ro-installer-ntfs-bound";
static bool bound(const char *path) { return path && strcmp(path, target) == 0; }
static int descriptor(void) {
    const char *value = getenv("RO_INSTALLER_NTFS_BOUND_FD");
    unsigned long number = 0;
    if (!value || !*value) { errno = EBADF; return -1; }
    for (; *value; value++) {
        if (*value < '0' || *value > '9' || number > (INT_MAX-9)/10) {
            errno = EBADF; return -1;
        }
        number = number*10 + (unsigned)(*value-'0');
    }
    struct stat s;
    int fd = (int)number;
    if (fd < 3 || fstat(fd,&s) || (!S_ISREG(s.st_mode) && !S_ISBLK(s.st_mode))) {
        errno = EBADF; return -1;
    }
    return fd;
}
static int duplicate(int flags) {
    int fd = descriptor();
    if (fd < 0) return -1;
    int source = fcntl(fd,F_GETFL);
    int allowed = O_ACCMODE|O_CLOEXEC|O_LARGEFILE|O_EXCL|O_NOFOLLOW|O_NONBLOCK;
    if (source < 0 || (source & (O_PATH|O_APPEND)) || (flags & ~allowed)
            || (flags & O_ACCMODE) == O_WRONLY
            || (flags & O_ACCMODE) != (source & O_ACCMODE)) {
        errno = EACCES; return -1;
    }
    return fcntl(fd,F_DUPFD_CLOEXEC,3);
}
static bool with_mode(int flags) { return (flags & O_CREAT) || (flags & O_TMPFILE) == O_TMPFILE; }
#define OPEN_FN(name) \
int name(const char *path,int flags,...) { \
    mode_t mode = 0; \
    if (with_mode(flags)) { va_list args; va_start(args,flags); mode = va_arg(args,mode_t); va_end(args); } \
    if (bound(path)) return duplicate(flags); \
    return (int)syscall(SYS_openat,AT_FDCWD,path,flags,mode); \
}
OPEN_FN(open)
OPEN_FN(open64)
#define OPENAT_FN(name) \
int name(int dirfd,const char *path,int flags,...) { \
    mode_t mode = 0; \
    if (with_mode(flags)) { va_list args; va_start(args,flags); mode = va_arg(args,mode_t); va_end(args); } \
    if (bound(path)) return duplicate(flags); \
    return (int)syscall(SYS_openat,dirfd,path,flags,mode); \
}
OPENAT_FN(openat)
OPENAT_FN(openat64)
static int checked_open(int d,const char *p,int f) {
    if(with_mode(f)){errno=EINVAL;return -1;}
    if(bound(p))return duplicate(f);
    return (int)syscall(SYS_openat,d,p,f,0);
}
int __open_2(const char *p,int f) {return checked_open(AT_FDCWD,p,f);}
int __open64_2(const char *p,int f) {return checked_open(AT_FDCWD,p,f);}
int __openat_2(int d,const char *p,int f) {return checked_open(d,p,f);}
int __openat64_2(int d,const char *p,int f) {return checked_open(d,p,f);}
int stat(const char *p,struct stat *s) {
    if(bound(p)){int fd=descriptor();return fd<0?-1:fstat(fd,s);}
    return (int)syscall(SYS_newfstatat,AT_FDCWD,p,s,0);
}
int lstat(const char *p,struct stat *s) {
    if(bound(p)){int fd=descriptor();return fd<0?-1:fstat(fd,s);}
    return (int)syscall(SYS_newfstatat,AT_FDCWD,p,s,AT_SYMLINK_NOFOLLOW);
}
int stat64(const char *p,struct stat64 *s) {
    if(bound(p)){int fd=descriptor();return fd<0?-1:fstat64(fd,s);}
    return (int)syscall(SYS_newfstatat,AT_FDCWD,p,s,0);
}
int lstat64(const char *p,struct stat64 *s) {
    if(bound(p)){int fd=descriptor();return fd<0?-1:fstat64(fd,s);}
    return (int)syscall(SYS_newfstatat,AT_FDCWD,p,s,AT_SYMLINK_NOFOLLOW);
}
char *realpath(const char *p,char *resolved) {
    if(bound(p)) {
        if(descriptor()<0)return NULL;
        if(!resolved)return strdup(target);
        memcpy(resolved,target,sizeof(target));return resolved;
    }
    char *(*next)(const char*,char*)=dlsym(RTLD_NEXT,"realpath");
    if(!next){errno=ENOSYS;return NULL;}
    return next(p,resolved);
}
