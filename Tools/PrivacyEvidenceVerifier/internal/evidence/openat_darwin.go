//go:build darwin && cgo

package evidence

/*
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>

static int dropmesh_openat_nofollow(int dirfd, const char *name, int *error_out) {
	errno = 0;
	int fd = openat(dirfd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
	*error_out = errno;
	return fd;
}
*/
import "C"

import (
	"errors"
	"os"
	"runtime"
	"syscall"
	"unsafe"
)

func openAtNoFollow(root *os.File, name string) (*os.File, error) {
	if !allowedBundleName(name) {
		return nil, errors.New("unsafe-input")
	}
	cName := C.CString(name)
	defer C.free(unsafe.Pointer(cName))
	var errorNumber C.int
	fd := C.dropmesh_openat_nofollow(C.int(root.Fd()), cName, &errorNumber)
	runtime.KeepAlive(root)
	if fd < 0 {
		if errorNumber == 0 {
			return nil, errors.New("unsafe-input")
		}
		return nil, syscall.Errno(errorNumber)
	}
	return os.NewFile(uintptr(fd), name), nil
}
